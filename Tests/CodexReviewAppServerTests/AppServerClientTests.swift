import Darwin
import Foundation
import Testing
@testable import CodexReviewAppServer
import CodexReview
import CodexReviewTesting

private extension AppServerCodexReviewBackend {
    func resumeTypedReviewRecovery(
        _ run: CodexReviewBackendModel.Review.Run,
        request: CodexReviewBackendModel.Review.Start,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws -> BackendReviewAttempt {
        let handoff = try await prepareTypedReviewRecovery(
            run,
            reason: reason
        )
        return try await resumeReviewRecovery(
            handoff,
            request: request,
            admission: ReviewStartAdmission()
        )
    }

    func resumeTypedReviewRecovery(
        _ attempt: BackendReviewAttempt,
        request: CodexReviewBackendModel.Review.Start,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws -> BackendReviewAttempt {
        try await resumeTypedReviewRecovery(
            attempt.run,
            request: request,
            reason: reason
        )
    }

    func prepareTypedReviewRecovery(
        _ run: CodexReviewBackendModel.Review.Run,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws -> ReviewRecoveryHandoff {
        let admission = try await makeActiveRecoveryAdmission(for: run)
        let disposition = try await admission.beginRecovery(
            run,
            trigger: .recoverableNetworkLoss,
            request: { requestAdmission, requestedReason in
                guard requestedReason == reason else {
                    throw ReviewAttemptContractFailure(
                        message: "Typed test recovery changed its interrupt reason."
                    )
                }
                try await self.interruptReview(
                    requestAdmission,
                    reason: requestedReason
                )
                try await admission.recordCanonicalTerminal(
                    .interrupted(.server(message: requestedReason.message)),
                    for: run
                )
            }
        )
        guard case .replacement(let candidate) = disposition else {
            throw ReviewAttemptContractFailure(
                message: "Expected typed test recovery to produce a replacement."
            )
        }
        return try await prepareReviewRecovery(candidate)
    }

    func interruptReview(_ attempt: BackendReviewAttempt, reason: CodexReviewBackendModel.CancellationReason) async throws {
        try await interruptReview(attempt.run, reason: reason)
    }

    func cleanupReview(_ attempt: BackendReviewAttempt) async throws {
        try await cleanupReview(attempt.run)
    }
}

private func makeActiveRecoveryAdmission(
    for run: CodexReviewBackendModel.Review.Run
) async throws -> ReviewStartAdmission {
    let admission = ReviewStartAdmission()
    try await admission.admitThreadStartDispatch()
    try await admission.recordPreparedThread(run)
    try await admission.admitReviewStartDispatch(for: run)
    try await admission.recordActiveRun(run)
    return admission
}

private func makeResolvedRecoveryHandoffForTesting(
    _ backend: AppServerCodexReviewBackend,
    run: CodexReviewBackendModel.Review.Run
) async throws -> ReviewRecoveryHandoff {
    let admission = try await makeActiveRecoveryAdmission(for: run)
    try await admission.recordCanonicalTerminal(
        .interrupted(.server(message: "Test recovery")),
        for: run
    )
    guard case .replacement(let candidate) = try await admission.beginRecovery(
        run,
        trigger: .recoverableNetworkLoss,
        request: { _, _ in
            Issue.record("A terminal test recovery dispatched another interrupt.")
        }
    ) else {
        throw ReviewAttemptContractFailure(
            message: "Expected the test recovery terminal to produce a replacement."
        )
    }
    return try await backend.prepareReviewRecovery(candidate)
}

private extension BackendReviewAttempt {
    var attemptID: String { run.attemptID }
    var threadID: String { run.threadID }
    var turnID: String? { run.turnID }
    var reviewThreadID: String? { run.reviewThreadID }
    var model: String? { run.model }
}

private struct BackendReviewEventSequence: AsyncSequence {
    typealias Element = CodexReviewBackendModel.Review.Event

    struct AsyncIterator: AsyncIteratorProtocol {
        var mailbox: BackendReviewEventMailbox

        mutating func next() async throws -> CodexReviewBackendModel.Review.Event? {
            try await mailbox.next()
        }
    }

    var mailbox: BackendReviewEventMailbox

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(mailbox: mailbox)
    }
}

private func eventSequence(
    _ backend: AppServerCodexReviewBackend,
    _ attempt: BackendReviewAttempt
) async -> BackendReviewEventSequence {
    BackendReviewEventSequence(mailbox: attempt.events)
}

private func eventSequence(
    _ backend: AppServerCodexReviewBackend,
    _ run: CodexReviewBackendModel.Review.Run
) async -> BackendReviewEventSequence {
    let attempt = await backend.reviewAttemptForTesting(run)
    return BackendReviewEventSequence(mailbox: attempt.events)
}

private func makeProcessTransport(
    in directory: URL,
    script: String,
    closeAdmissionForTesting: (@Sendable () async -> Void)? = nil,
    closeCompletionForTesting: (@Sendable () async throws -> Void)? = nil
) throws -> AppServerProcessTransport {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appending(path: "app-server-stub.sh")
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return try AppServerProcessTransport(
        configuration: .init(
            executableURL: executable,
            arguments: [],
            environment: [
                "HOME": directory.path,
                "PATH": "/bin:/usr/bin",
            ]
        ),
        closeAdmissionForTesting: closeAdmissionForTesting,
        closeCompletionForTesting: closeCompletionForTesting
    )
}

private actor RequestBarrier {
    private let releaseGate = AsyncGate()
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        await releaseGate.waitIgnoringCancellation()
    }

    func waitUntilEntered() async {
        if entered {
            return
        }
        await withCheckedContinuation { continuation in
            if entered {
                continuation.resume()
            } else {
                entryWaiters.append(continuation)
            }
        }
    }

    func open() async {
        await releaseGate.open()
    }
}

private actor DeferredNotificationCloseTransport: JSONRPC.Transport {
    private let closeFailure: ReviewRuntimeCloseFailure?
    private var responses: [String: [Data]] = [:]
    private var requestBarriersByMethod: [String: [RequestBarrier]] = [:]
    private var notificationStreamGate: AsyncGate?
    private var notificationStreamRequested = false
    private var notificationStreamWaiters: [CheckedContinuation<Void, Never>] = []
    private var notificationContinuation: AsyncThrowingStream<JSONRPC.Notification, Error>.Continuation?
    private var closeCallCount = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var sendCallCount = 0

    init(closeFailure: ReviewRuntimeCloseFailure? = nil) {
        self.closeFailure = closeFailure
    }

    func enqueue<Response: Encodable & Sendable>(
        _ response: Response,
        for method: String
    ) throws {
        responses[method, default: []].append(try JSONEncoder().encode(response))
    }

    func holdNext(method: String, barrier: RequestBarrier) {
        requestBarriersByMethod[method, default: []].append(barrier)
    }

    func holdNotificationStream(on gate: AsyncGate) {
        notificationStreamGate = gate
    }

    func send(_ request: JSONRPC.Request) async throws -> Data {
        sendCallCount += 1
        if var barriers = requestBarriersByMethod[request.method],
           barriers.isEmpty == false {
            let barrier = barriers.removeFirst()
            requestBarriersByMethod[request.method] = barriers
            await barrier.enterAndWait()
        }
        guard var methodResponses = responses[request.method],
              methodResponses.isEmpty == false else {
            return try JSONEncoder().encode(EmptyResponse())
        }
        let response = methodResponses.removeFirst()
        responses[request.method] = methodResponses
        return response
    }

    func notify(_: JSONRPC.Notification) async throws {}

    func notificationStream() async -> AsyncThrowingStream<JSONRPC.Notification, Error> {
        notificationStreamRequested = true
        let waiters = notificationStreamWaiters
        notificationStreamWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        if let notificationStreamGate {
            await notificationStreamGate.waitIgnoringCancellation()
        }
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            notificationContinuation = continuation
        }
    }

    func close() async throws {
        closeCallCount += 1
        let waiters = closeWaiters
        closeWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        if let closeFailure {
            throw closeFailure
        }
    }

    func waitForCloseCall() async {
        if closeCallCount > 0 {
            return
        }
        await withCheckedContinuation { continuation in
            if closeCallCount > 0 {
                continuation.resume()
            } else {
                closeWaiters.append(continuation)
            }
        }
    }

    func waitForNotificationStreamRequest() async {
        if notificationStreamRequested {
            return
        }
        await withCheckedContinuation { continuation in
            if notificationStreamRequested {
                continuation.resume()
            } else {
                notificationStreamWaiters.append(continuation)
            }
        }
    }

    func emitServerNotification<Params: Encodable & Sendable>(
        method: String,
        params: Params
    ) throws {
        notificationContinuation?.yield(.init(
            method: method,
            params: try JSONEncoder().encode(params)
        ))
    }

    func finishNotificationStream(throwing error: any Error) {
        notificationContinuation?.finish(throwing: error)
        notificationContinuation = nil
    }

    func recordedSendCallCount() -> Int {
        sendCallCount
    }

    func recordedCloseCallCount() -> Int {
        closeCallCount
    }
}

private actor CompletionProbe {
    private var completed = false

    func recordCompletion() {
        completed = true
    }

    func hasCompleted() -> Bool {
        completed
    }
}

@Suite("app-server client")
struct AppServerClientTests {
    @Test func processTransportConfigurationUsesResolvedExecutableForSessionSourceProbe() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let codex = directory.appending(path: "codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "app-server" ] && [ "$2" = "--help" ]; then
          printf 'Usage: codex app-server --listen <URL> --session-source <SOURCE>\\n'
        fi
        """
        try Data(script.utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        let configuration = AppServerProcessTransport.Configuration(
            executableURL: codex,
            environment: ["PATH": directory.path, "HOME": "/tmp/review-home"]
        )

        #expect(configuration.executableURL == codex)
        #expect(configuration.arguments == [
            "-c", CodexAppServerExecutable.fileBackedAuthConfiguration,
            "app-server",
            "--listen", "stdio://",
            "--session-source", "app-server",
        ])
        #expect(configuration.arguments.contains(#"cli_auth_credentials_store="file""#))
        #expect(configuration.threadStartPermissionStrategy == .modernPermissions)
        let sessionSourceIndex = try #require(configuration.arguments.firstIndex(of: "--session-source"))
        #expect(configuration.arguments[sessionSourceIndex + 1] == "app-server")
    }

    @Test func processTransportConfigurationOmitsUnsupportedSessionSourceFlag() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let codex = directory.appending(path: "codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "app-server" ] && [ "$2" = "--help" ]; then
          printf 'Usage: codex app-server --listen <URL>\\n'
        fi
        """
        try Data(script.utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        let configuration = AppServerProcessTransport.Configuration(
            executableURL: codex,
            environment: ["PATH": directory.path, "HOME": "/tmp/review-home"]
        )

        #expect(configuration.executableURL == codex)
        #expect(configuration.arguments == CodexAppServerExecutable.appServerArguments())
        #expect(configuration.arguments.contains("--session-source") == false)
        #expect(configuration.threadStartPermissionStrategy == .legacySandbox)
    }

    @Test func processTransportConfigurationDoesNotProbeWhenArgumentsAreExplicit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let codex = directory.appending(path: "codex")
        let probed = directory.appending(path: "probed")
        let script = """
        #!/bin/sh
        touch "\(probed.path)"
        """
        try Data(script.utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        let configuration = AppServerProcessTransport.Configuration(
            executableURL: codex,
            arguments: ["custom", "argument"],
            environment: ["PATH": directory.path, "HOME": "/tmp/review-home"]
        )

        #expect(configuration.executableURL == codex)
        #expect(configuration.arguments == ["custom", "argument"])
        #expect(configuration.threadStartPermissionStrategy == .legacySandbox)
        #expect(FileManager.default.fileExists(atPath: probed.path) == false)
    }

    @Test func stderrLogFilterSuppressesCommandOutputAfterToolError() {
        var filter = AppServerStderrLogFilter()
        let stderr = """
        \u{001B}[31m2026-06-08T09:20:00.000Z ERROR codex_core::tools::router: error=Exit code: 124\u{001B}[0m
        Wall time: 20 seconds
        Output:
        command timed out after 20000 milliseconds
        README.md | 1 +
        func expensiveDump() {}
        2026-06-08T09:20:01.000Z ERROR codex_core::exec: next error

        """

        var events = filter.append(Data(stderr.utf8))
        events.append(contentsOf: filter.finish())

        #expect(events.map(\.level) == [.error, .error, .warning, .warning, .warning, .error])
        #expect(events.map(\.message) == [
            "2026-06-08T09:20:00.000Z ERROR codex_core::tools::router: error=Exit code: 124",
            "Wall time: 20 seconds",
            "command output omitted after tool error",
            "command timed out after 20000 milliseconds",
            "suppressed 2 command-output line(s)",
            "2026-06-08T09:20:01.000Z ERROR codex_core::exec: next error",
        ])
    }

    @Test func processTransportConfigurationUsesDedicatedCodexHome() throws {
        let configuration = AppServerProcessTransport.Configuration(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            environment: [
                "PATH": "/usr/bin",
                "HOME": "/tmp/review-home",
                "CODEX_SQLITE_HOME": "/tmp/main-codex-sqlite",
            ]
        )

        #expect(configuration.codexHomeURL.path == "/tmp/review-home/.codex_review")
        #expect(configuration.environment["CODEX_HOME"] == "/tmp/review-home/.codex_review")
        #expect(configuration.environment["CODEX_SQLITE_HOME"] == "/tmp/review-home/.codex_review/sqlite")
    }

    @Test func processTransportConfigurationUsesExplicitCodexHome() throws {
        let configuration = AppServerProcessTransport.Configuration(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            environment: [
                "PATH": "/usr/bin",
                "HOME": "/tmp/review-home",
                "CODEX_HOME": "/tmp/custom-codex-review",
                "CODEX_SQLITE_HOME": "/tmp/main-codex-sqlite",
            ]
        )

        #expect(configuration.codexHomeURL.path == "/tmp/custom-codex-review")
        #expect(configuration.environment["CODEX_HOME"] == "/tmp/custom-codex-review")
        #expect(configuration.environment["CODEX_SQLITE_HOME"] == "/tmp/custom-codex-review/sqlite")
    }

    @Test func processTransportScaffoldsDedicatedSqliteHome() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-review-home-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try AppServerCodexHome.ensureScaffold(at: directory)

        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "config.toml").path))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "AGENTS.md").path))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("sqlite", isDirectory: true).path
        ))
    }

    @Test func processTransportCloseTerminatesSpawnedProcessGroup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-process-group-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let executable = directory.appending(path: "app-server-stub.sh")
        let childPIDFile = directory.appending(path: "child.pid")
        let readyFile = directory.appending(path: "ready")
        let script = """
        #!/bin/sh
        child_pid_file="$1"
        ready_file="$2"
        (
          while true; do sleep 1; done
        ) &
        echo $! > "$child_pid_file"
        touch "$ready_file"
        while true; do sleep 1; done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let transport = try AppServerProcessTransport(configuration: .init(
            executableURL: executable,
            arguments: [childPIDFile.path, readyFile.path],
            environment: [
                "HOME": directory.path,
                "PATH": "/bin:/usr/bin",
            ]
        ))
        let becameReady = await waitUntil(timeout: .seconds(2)) {
            FileManager.default.fileExists(atPath: readyFile.path)
        }
        #expect(becameReady)

        let childPIDText = try String(contentsOf: childPIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try #require(pid_t(childPIDText))
        defer {
            _ = Darwin.kill(childPID, SIGKILL)
        }
        #expect(Darwin.kill(childPID, 0) == 0)

        try await transport.close()

        let childExited = await waitUntil(timeout: .seconds(2)) {
            Darwin.kill(childPID, 0) != 0 && errno == ESRCH
        }
        #expect(childExited)

        let notifications = await transport.notificationStream()
        var iterator = notifications.makeAsyncIterator()
        await #expect(throws: JSONRPC.Error.transportTerminated(.ownerClose)) {
            _ = try await iterator.next()
        }
    }

    @Test func concurrentProcessTransportCloseCallersJoinOneFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-concurrent-close-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let closeStarted = AsyncGate()
        let closeGate = AsyncGate()
        let secondCloseAdmitted = AsyncGate()
        let closeAdmissions = CallCounter()
        let closeCompletions = CallCounter()
        let failure = TransportCloseTestError.injected
        let transport = try AppServerProcessTransport(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: [],
                environment: [
                    "HOME": directory.path,
                    "PATH": "/bin:/usr/bin",
                ]
            ),
            closeAdmissionForTesting: {
                if await closeAdmissions.record() == 2 {
                    await secondCloseAdmitted.open()
                }
            },
            closeCompletionForTesting: {
                _ = await closeCompletions.record()
                await closeStarted.open()
                await closeGate.waitIgnoringCancellation()
                throw failure
            }
        )

        let first = Task { try await transport.close() }
        await closeStarted.wait()
        let second = Task { try await transport.close() }
        let terminalStream = Task { await transport.notificationStream() }
        await secondCloseAdmitted.wait()
        await closeGate.open()

        await #expect(throws: failure) {
            try await first.value
        }
        await #expect(throws: failure) {
            try await second.value
        }
        #expect(await closeCompletions.value() == 1)
        let stream = await terminalStream.value
        var iterator = stream.makeAsyncIterator()
        await #expect(throws: JSONRPC.Error.transportTerminated(.processFailure(
            failure.localizedDescription
        ))) {
            _ = try await iterator.next()
        }
    }

    @Test func repeatedProcessTransportCloseRethrowsRecordedFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-repeated-close-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let closeCompletions = CallCounter()
        let failure = TransportCloseTestError.injected
        let transport = try AppServerProcessTransport(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: [],
                environment: [
                    "HOME": directory.path,
                    "PATH": "/bin:/usr/bin",
                ]
            ),
            closeCompletionForTesting: {
                _ = await closeCompletions.record()
                throw failure
            }
        )

        await #expect(throws: failure) {
            try await transport.close()
        }
        await #expect(throws: failure) {
            try await transport.close()
        }
        #expect(await closeCompletions.value() == 1)
    }

    @Test func processTransportRejectsSendAndNotifyWithFinalCloseFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-close-request-race-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let closeStarted = AsyncGate()
        let closeGate = AsyncGate()
        let requestsAdmitted = AsyncGate()
        let requestAdmissions = CallCounter()
        let failure = TransportCloseTestError.injected
        let transport = try AppServerProcessTransport(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: [],
                environment: [
                    "HOME": directory.path,
                    "PATH": "/bin:/usr/bin",
                ]
            ),
            closeCompletionForTesting: {
                await closeStarted.open()
                await closeGate.waitIgnoringCancellation()
                throw failure
            },
            closedRequestAdmissionForTesting: {
                if await requestAdmissions.record() == 2 {
                    await requestsAdmitted.open()
                }
            }
        )
        let sendCompletion = CompletionProbe()
        let notifyCompletion = CompletionProbe()

        let close = Task { try await transport.close() }
        await closeStarted.wait()
        let send = Task {
            do {
                _ = try await transport.send(.init(
                    id: 1,
                    method: "test/request",
                    params: Data("{}".utf8)
                ))
                await sendCompletion.recordCompletion()
            } catch {
                await sendCompletion.recordCompletion()
                throw error
            }
        }
        let notify = Task {
            do {
                try await transport.notify(.init(
                    method: "test/notification",
                    params: Data("{}".utf8)
                ))
                await notifyCompletion.recordCompletion()
            } catch {
                await notifyCompletion.recordCompletion()
                throw error
            }
        }
        await requestsAdmitted.wait()
        #expect(await sendCompletion.hasCompleted() == false)
        #expect(await notifyCompletion.hasCompleted() == false)

        await closeGate.open()
        await #expect(throws: failure) {
            try await close.value
        }
        let expected = JSONRPC.Error.transportTerminated(.processFailure(
            failure.localizedDescription
        ))
        await #expect(throws: expected) {
            try await send.value
        }
        await #expect(throws: expected) {
            try await notify.value
        }
    }

    @Test func spontaneousProcessExitReplaysTypedCauseToLateSubscriber() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-process-exit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = try makeProcessTransport(
            in: directory,
            script: """
            #!/bin/sh
            exit 0
            """
        )

        let notifications = await transport.notificationStream()
        var iterator = notifications.makeAsyncIterator()
        let expected = JSONRPC.Error.transportTerminated(.processExit(
            "Codex app-server process exited after stdout reached EOF."
        ))

        await #expect(throws: expected) {
            _ = try await iterator.next()
        }

        let replay = await transport.notificationStream()
        var replayIterator = replay.makeAsyncIterator()
        await #expect(throws: expected) {
            _ = try await replayIterator.next()
        }
    }

    @Test func invalidFrameAndExplicitCloseShareOneTerminal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-invalid-close-race-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let closeStarted = AsyncGate()
        let closeGate = AsyncGate()
        let secondCloseAdmitted = AsyncGate()
        let closeAdmissions = CallCounter()
        let closeCompletions = CallCounter()
        let transport = try makeProcessTransport(
            in: directory,
            script: """
            #!/bin/sh
            printf 'not-json\\n'
            sleep 10
            """,
            closeAdmissionForTesting: {
                if await closeAdmissions.record() == 2 {
                    await secondCloseAdmitted.open()
                }
            },
            closeCompletionForTesting: {
                _ = await closeCompletions.record()
                await closeStarted.open()
                await closeGate.waitIgnoringCancellation()
            }
        )
        let notifications = await transport.notificationStream()
        var iterator = notifications.makeAsyncIterator()

        await closeStarted.wait()
        let explicitClose = Task { try await transport.close() }
        await secondCloseAdmitted.wait()
        await closeGate.open()

        try await explicitClose.value
        await #expect(throws: JSONRPC.Error.invalidMessage("app-server emitted invalid JSON")) {
            _ = try await iterator.next()
        }
        #expect(await closeCompletions.value() == 1)
    }

    @Test func stdoutEOFAndExplicitCloseShareOneTerminal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-eof-close-race-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let closeStarted = AsyncGate()
        let closeGate = AsyncGate()
        let secondCloseAdmitted = AsyncGate()
        let closeAdmissions = CallCounter()
        let closeCompletions = CallCounter()
        let transport = try makeProcessTransport(
            in: directory,
            script: """
            #!/bin/sh
            exit 0
            """,
            closeAdmissionForTesting: {
                if await closeAdmissions.record() == 2 {
                    await secondCloseAdmitted.open()
                }
            },
            closeCompletionForTesting: {
                _ = await closeCompletions.record()
                await closeStarted.open()
                await closeGate.waitIgnoringCancellation()
            }
        )
        let notifications = await transport.notificationStream()
        var iterator = notifications.makeAsyncIterator()

        await closeStarted.wait()
        let explicitClose = Task { try await transport.close() }
        await secondCloseAdmitted.wait()
        await closeGate.open()

        try await explicitClose.value
        await #expect(throws: JSONRPC.Error.transportTerminated(.processExit(
            "Codex app-server process exited after stdout reached EOF."
        ))) {
            _ = try await iterator.next()
        }
        #expect(await closeCompletions.value() == 1)
    }

    @Test func processTransportProcessesChunkedStdoutBeforeEOF() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-stdout-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let executable = directory.appending(path: "app-server-stub.sh")
        let script = """
        #!/bin/sh
        IFS= read -r request
        printf '{"id":1,"result":{"value":'
        sleep 0.05
        printf '"done"}}\\n'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let transport = try AppServerProcessTransport(configuration: .init(
            executableURL: executable,
            arguments: [],
            environment: [
                "HOME": directory.path,
                "PATH": "/bin:/usr/bin",
            ]
        ))

        let data = try await transport.send(JSONRPC.Request(
            id: 1,
            method: "test/request",
            params: Data("{}".utf8)
        ))
        try await transport.close()

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["value"] as? String == "done")
    }

    @Test func processTransportClosesConnectionOnInvalidJSONRPCFraming() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-invalid-framing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let executable = directory.appending(path: "app-server-stub.sh")
        let script = """
        #!/bin/sh
        printf 'not-json\\n'
        sleep 10
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let transport = try AppServerProcessTransport(configuration: .init(
            executableURL: executable,
            arguments: [],
            environment: [
                "HOME": directory.path,
                "PATH": "/bin:/usr/bin",
            ]
        ))
        let notifications = await transport.notificationStream()
        var iterator = notifications.makeAsyncIterator()

        do {
            _ = try await iterator.next()
            Issue.record("Expected invalid framing to terminate the connection")
        } catch let error as JSONRPC.Error {
            guard case .invalidMessage = error else {
                Issue.record("Expected invalidMessage, got \(error)")
                return
            }
        }
        await #expect(throws: JSONRPC.Error.invalidMessage(
            "app-server emitted invalid JSON"
        )) {
            try await transport.notify(.init(method: "initialized", params: Data("{}".utf8)))
        }
    }

    @Test func processTransportDeliversScalarNotificationParamsToTheDecoderBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-scalar-notification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let executable = directory.appending(path: "app-server-stub.sh")
        let script = """
        #!/bin/sh
        printf '{"method":"item/completed","params":1}\\n'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let transport = try AppServerProcessTransport(configuration: .init(
            executableURL: executable,
            arguments: [],
            environment: [
                "HOME": directory.path,
                "PATH": "/bin:/usr/bin",
            ]
        ))
        let notifications = await transport.notificationStream()
        var iterator = notifications.makeAsyncIterator()

        let notification = try #require(try await iterator.next())
        try await transport.close()

        #expect(notification.method == "item/completed")
        #expect(try JSONSerialization.jsonObject(
            with: notification.params,
            options: [.fragmentsAllowed]
        ) as? Int == 1)
    }

    @Test func processTransportWritesCodexJSONRPCLiteMessages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-jsonrpc-lite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let executable = directory.appending(path: "app-server-stub.sh")
        let requestFile = directory.appending(path: "request.json")
        let notificationFile = directory.appending(path: "notification.json")
        let script = """
        #!/bin/sh
        request_file="$1"
        notification_file="$2"
        IFS= read -r request
        printf '%s\\n' "$request" > "$request_file"
        printf '{"id":7,"result":{}}\\n'
        IFS= read -r notification
        printf '%s\\n' "$notification" > "$notification_file"
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let transport = try AppServerProcessTransport(configuration: .init(
            executableURL: executable,
            arguments: [requestFile.path, notificationFile.path],
            environment: [
                "HOME": directory.path,
                "PATH": "/bin:/usr/bin",
            ]
        ))

        _ = try await transport.send(JSONRPC.Request(
            id: 7,
            method: "test/request",
            params: Data(#"{"value":true}"#.utf8)
        ))
        try await transport.notify(JSONRPC.Notification(
            method: "initialized",
            params: Data("{}".utf8)
        ))
        let notificationWritten = await waitUntil(timeout: .seconds(2)) {
            FileManager.default.fileExists(atPath: notificationFile.path)
        }
        try await transport.close()

        #expect(notificationWritten)
        let request = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: requestFile)
        ) as? [String: Any])
        let notification = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: notificationFile)
        ) as? [String: Any])
        #expect(request["jsonrpc"] == nil)
        #expect(request["id"] as? Int == 7)
        #expect(request["method"] as? String == "test/request")
        #expect(notification["jsonrpc"] == nil)
        #expect(notification["method"] as? String == "initialized")
    }

    @Test func processTransportMapsNullJSONRPCResultToEmptyPayload() throws {
        let data = try AppServerProcessTransport.responsePayloadData(from: NSNull())

        #expect(String(decoding: data, as: UTF8.self) == "{}")
        #expect(try JSONDecoder().decode(EmptyResponse.self, from: data) == EmptyResponse())
    }

    @Test func appServerTurnErrorRequiresMessage() throws {
        let valid = Data(#"{"id":"turn-1","error":{"message":"cancelled"}}"#.utf8)
        let turn = try JSONDecoder().decode(AppServerAPI.Turn.Payload.self, from: valid)
        #expect(turn.error?.message == "cancelled")

        let missingMessage = Data(#"{"id":"turn-1","error":{}}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AppServerAPI.Turn.Payload.self, from: missingMessage)
        }
    }

    @Test func processTransportBuildsErrorResponseForUnsupportedServerRequests() throws {
        let data = try AppServerProcessTransport.unsupportedServerRequestPayload(
            id: 42,
            method: "approval/request"
        )
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])

        #expect(object["jsonrpc"] == nil)
        #expect(object["id"] as? Int == 42)
        #expect(error["code"] as? Int == -32601)
        #expect(error["message"] as? String == "Unsupported app-server request: approval/request")
        #expect(String(decoding: data, as: UTF8.self).hasSuffix("\n"))
    }

    @Test func sameThreadReviewRequestsDoNotOverlap() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1"), for: "review/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-2"), for: "review/start")
        let gate = AsyncGate()
        await transport.hold(method: "review/start", gate: gate)
        let client = AppServerClient(transport: transport)

        async let first: AppServerAPI.Review.Start.Response = client.send(AppServerAPI.Review.Start.Request(
            params: .init(threadID: "thread-1", target: .uncommittedChanges)
        ))
        async let second: AppServerAPI.Review.Start.Response = client.send(AppServerAPI.Review.Start.Request(
            params: .init(threadID: "thread-1", target: .uncommittedChanges)
        ))
        await transport.waitForRequestCount(1)
        await gate.open()
        _ = try await (first, second)

        #expect(await transport.maxActiveCount(for: "review/start") == 1)
    }

    @Test func differentThreadReviewRequestsCanOverlap() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1"), for: "review/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-2"), for: "review/start")
        let gate = AsyncGate()
        await transport.hold(method: "review/start", gate: gate)
        let client = AppServerClient(transport: transport)

        async let first: AppServerAPI.Review.Start.Response = client.send(AppServerAPI.Review.Start.Request(
            params: .init(threadID: "thread-1", target: .uncommittedChanges)
        ))
        async let second: AppServerAPI.Review.Start.Response = client.send(AppServerAPI.Review.Start.Request(
            params: .init(threadID: "thread-2", target: .uncommittedChanges)
        ))
        await transport.waitForRequestCount(2)
        await gate.open()
        _ = try await (first, second)

        #expect(await transport.maxActiveCount(for: "review/start") == 2)
    }

    @Test func sendRetriesAppServerOverloadWithFreshRequestID() async throws {
        let transport = FakeJSONRPCTransport()
        await transport.enqueueFailure(
            .responseError(code: -32001, message: "Server overloaded; retry later."),
            for: "test/request"
        )
        let client = AppServerClient(
            transport: transport,
            overloadRetryDelay: { _ in .milliseconds(100) },
            retrySleep: { _ in }
        )

        let response: EmptyResponse = try await client.send(
            method: "test/request",
            params: EmptyResponse(),
            responseType: EmptyResponse.self
        )

        #expect(response == EmptyResponse())
        let requests = await transport.recordedRequests()
        #expect(requests.map(\.method) == ["test/request", "test/request"])
        #expect(requests[0].id != requests[1].id)
    }

    @Test func sendDoesNotRetryNonOverloadAppServerErrors() async throws {
        let transport = FakeJSONRPCTransport()
        await transport.enqueueFailure(
            .responseError(code: -32602, message: "invalid target"),
            for: "test/request"
        )
        let client = AppServerClient(transport: transport)

        await #expect(throws: JSONRPC.Error.responseError(code: -32602, message: "invalid target")) {
            let _: EmptyResponse = try await client.send(
                method: "test/request",
                params: EmptyResponse(),
                responseType: EmptyResponse.self
            )
        }
        #expect(await transport.recordedRequests().map(\.method) == ["test/request"])
    }

    @Test func sendPreservesResponseDecodingErrorOutsideStartAdmission() async throws {
        let transport = FakeJSONRPCTransport()
        await transport.enqueueRawResponse(Data("not-json".utf8), for: "test/request")
        let client = AppServerClient(transport: transport)

        await #expect(throws: DecodingError.self) {
            let _: EmptyResponse = try await client.send(
                method: "test/request",
                params: EmptyResponse(),
                responseType: EmptyResponse.self
            )
        }
    }

    @Test func sendPreservesTransportErrorOutsideStartAdmission() async throws {
        let transport = FakeJSONRPCTransport()
        await transport.enqueueTransportFailure(message: "Broken pipe", for: "test/request")
        let client = AppServerClient(transport: transport)

        do {
            let _: EmptyResponse = try await client.send(
                method: "test/request",
                params: EmptyResponse(),
                responseType: EmptyResponse.self
            )
            Issue.record("Generic transport error was replaced or swallowed.")
        } catch let error as FakeCodexReviewBackendError {
            #expect(error.message == "Broken pipe")
        }
    }

    @Test func startupInterruptAcceptanceUsesEmptyTurnIDAndAbsorbsLatePhase() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let client = AppServerClient(transport: transport)
        let control = AppServerReviewControl(client: client)

        control.recordThreadStarted(threadID: "thread-1")
        let interruption = try await control.interrupt()
        #expect(interruption == .init(threadID: "thread-1", turnID: ""))
        control.recordReviewStarted(turnThreadID: "thread-1", turnID: "turn-late")
        #expect(try await control.interruptOutcome() == .superseded)

        let requests = await transport.recordedRequests()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "turn/interrupt")
        let params = try JSONDecoder().decode(AppServerAPI.Turn.Interrupt.Params.self, from: request.params)
        #expect(params.threadID == "thread-1")
        #expect(params.turnID == "")
    }

    @Test func runningInterruptUsesActualTurnIDAndSuppressesDuplicateAfterAcceptance() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let client = AppServerClient(transport: transport)
        let control = AppServerReviewControl(client: client)

        control.recordReviewStarted(turnThreadID: "thread-1", turnID: "turn-1")
        let interruption = try await control.interrupt()
        #expect(interruption == .init(threadID: "thread-1", turnID: "turn-1"))
        #expect(try await control.interruptOutcome() == .superseded)

        let requests = await transport.recordedRequests()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        let params = try JSONDecoder().decode(AppServerAPI.Turn.Interrupt.Params.self, from: request.params)
        #expect(params.turnID == "turn-1")
    }

    @Test func finishedControlAbsorbsLaterReviewPhases() async throws {
        let transport = FakeJSONRPCTransport()
        let control = AppServerReviewControl(client: .init(transport: transport))

        control.recordReviewStarted(turnThreadID: "thread-1", turnID: "turn-1")
        control.finish()
        control.recordReviewStarted(turnThreadID: "thread-2", turnID: "turn-2")
        control.recordTurnStarted(turnThreadID: "thread-3", turnID: "turn-3")

        #expect(try await control.interrupt() == nil)
        #expect(await transport.recordedRequests().isEmpty)
    }

    @Test func finishedControlRejectsRetryFromSuspendedInterrupt() async throws {
        let transport = FakeJSONRPCTransport()
        await transport.enqueueFailure(
            .responseError(
                code: -32602,
                message: "expected active turn id turn-old but found turn-new"
            ),
            for: "turn/interrupt"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let firstRequest = RequestBarrier()
        await transport.beforeReturningNextResponse(method: "turn/interrupt") {
            await firstRequest.enterAndWait()
        }
        let control = AppServerReviewControl(client: .init(transport: transport))
        control.recordReviewStarted(turnThreadID: "thread-1", turnID: "turn-old")

        let interrupt = Task {
            try await control.interruptOutcome()
        }
        await firstRequest.waitUntilEntered()
        control.finish()
        await firstRequest.open()

        let outcome = try await interrupt.value
        #expect(outcome == .superseded)
        #expect(outcome.interruption == nil)
        #expect(await transport.recordedRequests().count == 1)
    }

    @Test func identicalPhaseDoesNotInvalidateReservedInterruptRetry() async throws {
        let transport = FakeJSONRPCTransport()
        await transport.enqueueFailure(
            .responseError(
                code: -32602,
                message: "expected active turn id turn-old but found turn-new"
            ),
            for: "turn/interrupt"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let firstRequest = RequestBarrier()
        await transport.beforeReturningNextResponse(method: "turn/interrupt") {
            await firstRequest.enterAndWait()
        }
        let control = AppServerReviewControl(client: .init(transport: transport))
        control.recordReviewStarted(turnThreadID: "thread-1", turnID: "turn-old")

        let interrupt = Task {
            try await control.interruptOutcome()
        }
        await firstRequest.waitUntilEntered()
        control.recordTurnStarted(turnThreadID: "thread-1", turnID: "turn-old")
        await firstRequest.open()

        #expect(try await interrupt.value == .sent(.init(
            threadID: "thread-1",
            turnID: "turn-new"
        )))
        #expect(await transport.recordedRequests().count == 2)
    }

    @Test func currentReportedPhaseAuthorizesReservedInterruptRetry() async throws {
        let transport = FakeJSONRPCTransport()
        await transport.enqueueFailure(
            .responseError(
                code: -32602,
                message: "expected active turn id turn-old but found turn-new"
            ),
            for: "turn/interrupt"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let firstRequest = RequestBarrier()
        await transport.beforeReturningNextResponse(method: "turn/interrupt") {
            await firstRequest.enterAndWait()
        }
        let control = AppServerReviewControl(client: .init(transport: transport))
        control.recordReviewStarted(turnThreadID: "thread-1", turnID: "turn-old")

        let interrupt = Task {
            try await control.interruptOutcome()
        }
        await firstRequest.waitUntilEntered()
        control.recordTurnStarted(turnThreadID: "thread-1", turnID: "turn-new")
        await firstRequest.open()

        #expect(try await interrupt.value == .sent(.init(
            threadID: "thread-1",
            turnID: "turn-new"
        )))
        #expect(await transport.recordedRequests().count == 2)
    }

    @Test func successfulInterruptRedispatchesNewerActiveTurnBeforeReturning() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let firstRequest = RequestBarrier()
        await transport.beforeReturningNextResponse(method: "turn/interrupt") {
            await firstRequest.enterAndWait()
        }
        let control = AppServerReviewControl(client: .init(transport: transport))
        control.recordReviewStarted(turnThreadID: "thread-1", turnID: "turn-old")

        let interrupt = Task {
            try await control.interruptOutcome()
        }
        await firstRequest.waitUntilEntered()
        control.recordTurnStarted(turnThreadID: "thread-1", turnID: "turn-newer")
        await firstRequest.open()

        #expect(try await interrupt.value == .sent(.init(
            threadID: "thread-1",
            turnID: "turn-newer"
        )))
        #expect(try await control.interruptOutcome() == .superseded)
        let requests = await transport.recordedRequests()
        let turns = try requests.map {
            try JSONDecoder().decode(
                AppServerAPI.Turn.Interrupt.Params.self,
                from: $0.params
            ).turnID
        }
        #expect(turns == ["turn-old", "turn-newer"])
    }

    @Test func successfulMismatchRetryRedispatchesNewerActiveTurnBeforeReturning() async throws {
        let transport = FakeJSONRPCTransport()
        await transport.enqueueFailure(
            .responseError(
                code: -32602,
                message: "expected active turn id turn-old but found turn-new"
            ),
            for: "turn/interrupt"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let retryRequest = RequestBarrier()
        await transport.beforeReturningNextResponse(method: "turn/interrupt") {}
        await transport.beforeReturningNextResponse(method: "turn/interrupt") {
            await retryRequest.enterAndWait()
        }
        let control = AppServerReviewControl(client: .init(transport: transport))
        control.recordReviewStarted(turnThreadID: "thread-1", turnID: "turn-old")

        let interrupt = Task {
            try await control.interruptOutcome()
        }
        await retryRequest.waitUntilEntered()
        control.recordTurnStarted(turnThreadID: "thread-1", turnID: "turn-newer")
        await retryRequest.open()

        #expect(try await interrupt.value == .sent(.init(
            threadID: "thread-1",
            turnID: "turn-newer"
        )))
        #expect(try await control.interruptOutcome() == .superseded)
        let requests = await transport.recordedRequests()
        let turns = try requests.map {
            try JSONDecoder().decode(
                AppServerAPI.Turn.Interrupt.Params.self,
                from: $0.params
            ).turnID
        }
        #expect(turns == ["turn-old", "turn-new", "turn-newer"])
    }

    @Test func backendDoesNotFallbackAfterRegisteredControlFinishes() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-1",
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1"
        )
        var events = await eventSequence(backend, run).makeAsyncIterator()
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "thread-1",
                turn: .init(id: "turn-1", status: "failed")
            )
        )
        await backend.waitForReviewNotificationCompletionForTesting(1)
        #expect(try await events.next() == .failed(nil))

        try await backend.interruptReview(run, reason: .init(message: "Stop"))

        #expect(await transport.recordedRequests().map(\.method) == ["initialize"])
    }

    @Test func rejectedLateStartedDoesNotAdvanceControlOrMetrics() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let provisionalRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-1",
            threadID: "thread-1",
            reviewThreadID: "thread-1"
        )
        let activeRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-1",
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1"
        )
        let attempt = await backend.reviewAttemptForTesting(provisionalRun)
        _ = await backend.reviewAttemptForTesting(activeRun)
        await attempt.events.abandon()

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    type: "commandExecution",
                    id: "command-1",
                    command: "git diff",
                    cwd: "/tmp/project"
                )
            )
        )
        await backend.waitForReviewNotificationCompletionForTesting(1)
        let beforeInterrupt = try #require(
            await backend.reviewEventSessionMetricsForTesting(threadID: "thread-1")
        )
        #expect(beforeInterrupt.emitted == 0)

        try await backend.interruptReview(activeRun, reason: .init(message: "Stop"))

        let requests = await transport.recordedRequests()
        #expect(requests.map(\.method) == ["initialize", "turn/interrupt"])
        let interrupt = try JSONDecoder().decode(
            AppServerAPI.Turn.Interrupt.Params.self,
            from: requests[1].params
        )
        #expect(interrupt.turnID.isEmpty)
        let afterInterrupt = try #require(
            await backend.reviewEventSessionMetricsForTesting(threadID: "thread-1")
        )
        #expect(afterInterrupt.emitted == 0)
    }

    @Test func runningInterruptRetriesWithCurrentActiveTurnID() async throws {
        let transport = FakeJSONRPCTransport()
        await transport.enqueueFailure(
            .responseError(
                code: -32602,
                message: "expected active turn id turn-old but found turn-new"
            ),
            for: "turn/interrupt"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let client = AppServerClient(transport: transport)
        let control = AppServerReviewControl(client: client)

        control.recordReviewStarted(turnThreadID: "thread-1", turnID: "turn-old")
        let interruption = try await control.interrupt()
        #expect(interruption == .init(threadID: "thread-1", turnID: "turn-new"))
        #expect(try await control.interruptOutcome() == .superseded)

        let requests = await transport.recordedRequests()
        #expect(requests.map(\.method) == ["turn/interrupt", "turn/interrupt"])
        let first = try JSONDecoder().decode(AppServerAPI.Turn.Interrupt.Params.self, from: requests[0].params)
        let second = try JSONDecoder().decode(AppServerAPI.Turn.Interrupt.Params.self, from: requests[1].params)
        #expect(first.turnID == "turn-old")
        #expect(second.turnID == "turn-new")
    }

    @Test func initializeSendsInitializedNotificationOnce() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(codexHome: "/tmp/codex"), for: "initialize")
        let client = AppServerClient(transport: transport)

        let response = try await client.initialize()
        _ = try await client.initialize()

        #expect(response.codexHome == "/tmp/codex")
        #expect(await transport.recordedRequests().map(\.method) == ["initialize"])
        #expect(await transport.recordedNotifications().map(\.method) == ["initialized"])
        let request = try #require(await transport.recordedRequests().first)
        let params = try #require(JSONSerialization.jsonObject(with: request.params) as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])
        #expect(clientInfo["name"] as? String == "CodexReviewKit")
        #expect(clientInfo["version"] as? String == "2")
        let capabilities = try #require(params["capabilities"] as? [String: Any])
        #expect(capabilities["experimentalApi"] as? Bool == true)
    }

    @Test func concurrentInitializeCallsShareSingleHandshake() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(codexHome: "/tmp/codex"), for: "initialize")
        let gate = AsyncGate()
        await transport.hold(method: "initialize", gate: gate)
        let client = AppServerClient(transport: transport)

        async let first = client.initialize()
        async let second = client.initialize()
        await transport.waitForRequestCount(1)
        await gate.open()
        let responses = try await (first, second)

        #expect(responses.0.codexHome == "/tmp/codex")
        #expect(responses.1.codexHome == "/tmp/codex")
        #expect(await transport.recordedRequests().map(\.method) == ["initialize"])
        #expect(await transport.recordedNotifications().map(\.method) == ["initialized"])
    }

    @Test func accountReadResponseDecodesChatGPTAccountAuthRequirement() throws {
        let data = Data("""
        {"account":{"type":"chatgpt","email":"review@example.com","planType":"pro"},"requiresOpenaiAuth":true}
        """.utf8)
        let response = try JSONDecoder().decode(AppServerAPI.Account.Read.Response.self, from: data)

        #expect(response.requiresOpenAIAuth)
        #expect(response.account?.id == .init("review@example.com"))
        #expect(response.account?.kind == .chatGPT)
        #expect(response.account?.label == "review@example.com")
        #expect(response.account?.planType == "pro")
        #expect(response.account?.capabilities.supportsRateLimitRefresh == true)
    }

    @Test func accountReadResponseNormalizesProviderAccountCapabilities() throws {
        let apiKeyData = Data("""
        {"account":{"type":"apiKey"},"requiresOpenaiAuth":false}
        """.utf8)
        let bedrockData = Data("""
        {"account":{"type":"amazonBedrock"},"requiresOpenaiAuth":false}
        """.utf8)

        let apiKeyResponse = try JSONDecoder().decode(AppServerAPI.Account.Read.Response.self, from: apiKeyData)
        let bedrockResponse = try JSONDecoder().decode(AppServerAPI.Account.Read.Response.self, from: bedrockData)

        #expect(apiKeyResponse.account?.id == .init("api-key"))
        #expect(apiKeyResponse.account?.kind == .apiKey)
        #expect(apiKeyResponse.account?.label == "API Key")
        #expect(apiKeyResponse.account?.capabilities.supportsRateLimitRefresh == false)
        #expect(bedrockResponse.account?.id == .init("amazon-bedrock"))
        #expect(bedrockResponse.account?.kind == .amazonBedrock)
        #expect(bedrockResponse.account?.label == "Amazon Bedrock")
        #expect(bedrockResponse.account?.capabilities.supportsRateLimitRefresh == false)
    }

    @Test func accountRateLimitsResponseResolvesCodexLimitWindows() throws {
        let data = Data("""
        {
          "rateLimits": {
            "limitId": "codex_bengalfox",
            "primary": {"usedPercent": 0, "windowDurationMins": 300, "resetsAt": 1779183121},
            "secondary": {"usedPercent": 0, "windowDurationMins": 10080, "resetsAt": 1779769921},
            "planType": "pro"
          },
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": {"usedPercent": 0, "windowDurationMins": 300, "resetsAt": 1779176539},
              "secondary": {"usedPercent": 11, "windowDurationMins": 10080, "resetsAt": 1779571734},
              "planType": "pro"
            }
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(AppServerAPI.Account.RateLimits.Response.self, from: data)

        #expect(response.codexPlanType == "pro")
        #expect(response.codexRateLimitWindows.map(\.windowDurationMinutes) == [300, 10080])
        #expect(response.codexRateLimitWindows.map(\.usedPercent) == [0, 11])
        #expect(response.codexRateLimitWindows.first?.resetsAt == Date(timeIntervalSince1970: 1_779_176_539))
    }

    @Test func accountRateLimitsResponseFallsBackToCodexPrefixedTopLevelLimit() throws {
        let data = Data("""
        {
          "rateLimits": {
            "limitId": "codex_bengalfox",
            "primary": {"usedPercent": 17, "windowDurationMins": 300},
            "planType": "pro"
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(AppServerAPI.Account.RateLimits.Response.self, from: data)

        #expect(response.codexPlanType == "pro")
        #expect(response.codexRateLimitWindows.map(\.windowDurationMinutes) == [300])
        #expect(response.codexRateLimitWindows.map(\.usedPercent) == [17])
    }

    @Test func loginStartRequestsNativeAuthenticationWhenConfigured() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            AppServerAPI.Account.Login.Response.chatgpt(
                loginID: "login-1",
                authURL: "https://example.com/auth",
                nativeWebAuthentication: .init(callbackURLScheme: "lynnpd.CodexReviewMonitor.auth")
            ),
            for: "account/login/start"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let challenge = try await backend.startLogin(.init(
            nativeWebAuthenticationCallbackScheme: "lynnpd.CodexReviewMonitor.auth"
        ))

        #expect(challenge.id == "login-1")
        #expect(challenge.verificationURL == URL(string: "https://example.com/auth"))
        #expect(challenge.nativeWebAuthenticationCallbackScheme == "lynnpd.CodexReviewMonitor.auth")
        let request = try #require(await transport.recordedRequests().last)
        #expect(request.method == "account/login/start")
        let params = try JSONDecoder().decode(AppServerAPI.Account.Login.Params.self, from: request.params)
        #expect(params.nativeWebAuthentication?.callbackURLScheme == "lynnpd.CodexReviewMonitor.auth")
    }

    @Test func loginStartPreservesDeviceCodeUserCode() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            AppServerAPI.Account.Login.Response.chatgptDeviceCode(
                loginID: "login-1",
                verificationURL: "https://example.com/device",
                userCode: "ABCD-EFGH"
            ),
            for: "account/login/start"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let challenge = try await backend.startLogin(.init())

        #expect(challenge.id == "login-1")
        #expect(challenge.verificationURL == URL(string: "https://example.com/device"))
        #expect(challenge.userCode == "ABCD-EFGH")
    }

    @Test func loginStartRejectsInvalidAuthenticationURL() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            AppServerAPI.Account.Login.Response.chatgpt(
                loginID: "login-1",
                authURL: "file:///tmp/auth",
                nativeWebAuthentication: nil
            ),
            for: "account/login/start"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        await #expect(throws: (any Error).self) {
            _ = try await backend.startLogin(.init())
        }
    }

    @Test func settingsReadLoadsConfigAndModelCatalog() async throws {
        let modelList = Data("""
        {
          "data": [
            {
              "id": "gpt-5.5",
              "model": "gpt-5.5",
              "displayName": "GPT-5.5",
              "hidden": false,
              "supportedReasoningEfforts": [
                {"reasoningEffort": "medium", "description": "Balanced"},
                {"reasoningEffort": "xhigh", "description": "Extra high"}
              ],
              "defaultReasoningEffort": "xhigh",
              "serviceTiers": [{"id": "fast"}, {"id": "flex"}],
              "isDefault": true
            }
          ]
        }
        """.utf8)
        let transport = FakeJSONRPCTransport(responses: [
            "model/list": [modelList],
        ])
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(
                model: "gpt-5",
                reviewModel: "gpt-5.5",
                modelReasoningEffort: "medium",
                serviceTier: "flex"
            )),
            for: "config/read"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let settings = try await backend.readSettings()

        #expect(settings.model == "gpt-5.5")
        #expect(settings.fallbackModel == "gpt-5")
        #expect(settings.reasoningEffort == "medium")
        #expect(settings.serviceTier == "flex")
        #expect(settings.models.map(\.model) == ["gpt-5.5"])
        #expect(settings.models.first?.supportedServiceTiers == [.fast, .flex])
        #expect(settings.models.first?.isDefault == true)
    }

    @Test func settingsReadUsesGlobalModelAsFallbackWhenReviewModelIsUnset() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5", reviewModel: nil)),
            for: "config/read"
        )
        try await transport.enqueue(
            AppServerAPI.Model.List.Response(data: [makeModelCatalogItem(model: "default-model", isDefault: true)]),
            for: "model/list"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let settings = try await backend.readSettings()

        #expect(settings.model == nil)
        #expect(settings.fallbackModel == "gpt-5")
    }

    @Test func settingsReadPagesThroughModelCatalog() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: nil, reviewModel: nil)),
            for: "config/read"
        )
        try await transport.enqueue(
            AppServerAPI.Model.List.Response(
                data: [makeModelCatalogItem(model: "first-model")],
                nextCursor: "page-2"
            ),
            for: "model/list"
        )
        try await transport.enqueue(
            AppServerAPI.Model.List.Response(
                data: [makeModelCatalogItem(model: "default-model", isDefault: true)]
            ),
            for: "model/list"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let settings = try await backend.readSettings()

        #expect(settings.fallbackModel == "default-model")
        #expect(settings.models.map(\.model) == ["first-model", "default-model"])
        let modelRequests = await transport.recordedRequests().filter { $0.method == "model/list" }
        #expect(modelRequests.count == 2)
        let firstParams = try JSONDecoder().decode(AppServerAPI.Model.List.Params.self, from: modelRequests[0].params)
        let secondParams = try JSONDecoder().decode(AppServerAPI.Model.List.Params.self, from: modelRequests[1].params)
        #expect(firstParams.cursor == nil)
        #expect(firstParams.includeHidden == true)
        #expect(secondParams.cursor == "page-2")
        #expect(secondParams.includeHidden == true)
    }

    @Test func reviewTargetEncodesAppServerTaggedShape() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1"), for: "review/start")
        let client = AppServerClient(transport: transport)

        let _: AppServerAPI.Review.Start.Response = try await client.send(AppServerAPI.Review.Start.Request(
            params: .init(threadID: "thread-1", target: .baseBranch("main"))
        ))

        let request = try #require(await transport.recordedRequests().last)
        let object = try #require(JSONSerialization.jsonObject(with: request.params) as? [String: Any])
        let target = try #require(object["target"] as? [String: Any])
        #expect(target["type"] as? String == "baseBranch")
        #expect(target["branch"] as? String == "main")
        #expect(target["_0"] == nil)
        #expect(object["delivery"] as? String == "inline")
    }

    @Test func backendStartsPersistentReviewThreads() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        _ = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))

        let threadStart = try #require(await transport.recordedRequests().first { $0.method == "thread/start" })
        let params = try JSONDecoder().decode(AppServerAPI.Thread.Start.Params.self, from: threadStart.params)
        let object = try #require(JSONSerialization.jsonObject(with: threadStart.params) as? [String: Any])
        #expect(params.ephemeral == false)
        #expect(params.approvalPolicy == "never")
        #expect(params.permissions == .profileID(":danger-full-access"))
        #expect(params.sessionStartSource == .startup)
        #expect(params.threadSource == .user)
        #expect(params.sandbox == nil)
        #expect(object["permissions"] as? String == ":danger-full-access")
        #expect(object["sessionStartSource"] as? String == "startup")
        #expect(object["threadSource"] as? String == "user")
        #expect(object["sandbox"] == nil)
    }

    @Test func backendDoesNotWriteThreadStartAfterQueuedCancellation() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let admission = ReviewStartAdmission()
        let cancellation = ReviewCancellation.mcpClient(message: "Stop before start")
        await admission.recordCancellation(cancellation)

        await #expect(throws: ReviewStartCancelledBeforeDispatch(cancellation: cancellation)) {
            try await backend.startReview(
                .init(
                    jobID: "job-1",
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                ),
                admission: admission
            )
        }

        #expect(await transport.recordedRequests().map(\.method) == ["initialize"])
    }

    @Test func backendDoesNotWriteThreadStartWhenCancellationWinsInitializationRace() async throws {
        let transport = FakeJSONRPCTransport()
        let initializeGate = AsyncGate()
        try await enqueueInitialize(transport)
        await transport.holdNextIgnoringCancellation(method: "initialize", gate: initializeGate)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let admission = ReviewStartAdmission()
        let cancellation = ReviewCancellation.system(message: "Runtime stopped")
        let start = Task {
            try await backend.startReview(
                .init(
                    jobID: "job-1",
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                ),
                admission: admission
            )
        }
        await transport.waitForRequestCount(1)

        await admission.recordCancellation(cancellation)
        await initializeGate.open()

        await #expect(throws: ReviewStartCancelledBeforeDispatch(cancellation: cancellation)) {
            try await start.value
        }
        #expect(await transport.recordedRequests().map(\.method) == ["initialize"])
    }

    @Test func backendDoesNotWriteReviewStartWhenCancellationArrivesDuringThreadStart() async throws {
        let transport = FakeJSONRPCTransport()
        let threadStartGate = AsyncGate()
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"),
            for: "thread/start"
        )
        await transport.holdNextIgnoringCancellation(method: "thread/start", gate: threadStartGate)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let admission = ReviewStartAdmission()
        let cancellation = ReviewCancellation.system(message: "Runtime stopped")
        let start = Task {
            try await backend.startReview(
                .init(
                    jobID: "job-1",
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                ),
                admission: admission
            )
        }
        await transport.waitForRequestCount(2)

        await admission.recordCancellation(cancellation)
        await threadStartGate.open()

        await #expect(throws: ReviewStartCancelledBeforeDispatch(cancellation: cancellation)) {
            try await start.value
        }
        let methods = await transport.recordedRequests().map(\.method)
        #expect(methods.contains("thread/start"))
        #expect(methods.contains("review/start") == false)
    }

    @Test func backendRecordsThreadStartConnectionFailureAsTypedTerminal() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        await transport.enqueueFailure(.closed, for: "thread/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let admission = ReviewStartAdmission()

        await #expect(throws: JSONRPC.Error.closed) {
            try await backend.startReview(
                .init(
                    jobID: "job-1",
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                ),
                admission: admission
            )
        }

        #expect(await admission.currentPhase() == .terminal(.connection(
            .connection(JSONRPC.Error.closed.localizedDescription)
        )))
    }

    @Test func backendRecordsReviewStartConnectionFailureAsTypedTerminal() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"),
            for: "thread/start"
        )
        await transport.enqueueFailure(.closed, for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let admission = ReviewStartAdmission()

        await #expect(throws: JSONRPC.Error.closed) {
            try await backend.startReview(
                .init(
                    jobID: "job-1",
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                ),
                admission: admission
            )
        }

        #expect(await admission.currentPhase() == .terminal(.connection(
            .connection(JSONRPC.Error.closed.localizedDescription)
        )))
        let methods = await transport.recordedRequests().map(\.method)
        #expect(methods.filter { $0 == "thread/start" }.count == 1)
        #expect(methods.filter { $0 == "review/start" }.count == 1)
    }

    @Test func backendPreservesWinningConnectionTerminalAndOriginalRequestFailure() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-1"),
            for: "thread/start"
        )
        await transport.enqueueFailure(.closed, for: "review/start")
        let admission = ReviewStartAdmission()
        let winningTerminal = ReviewRuntimeCloseFailure.connection("Process exited")
        await transport.beforeReturningNextResponse(method: "review/start") {
            do {
                try await admission.recordConnectionTerminal(winningTerminal)
            } catch {
                Issue.record("Could not install the winning connection terminal: \(error)")
            }
        }
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        await #expect(throws: JSONRPC.Error.closed) {
            try await backend.startReview(
                .init(
                    jobID: "job-1",
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                ),
                admission: admission
            )
        }

        #expect(await admission.currentPhase() == .terminal(.connection(winningTerminal)))
        let methods = await transport.recordedRequests().map(\.method)
        #expect(methods.contains("thread/backgroundTerminals/clean"))
        #expect(methods.contains("thread/unsubscribe"))
        #expect(methods.contains("thread/delete"))
    }

    @Test func backendRechecksThreadStartAdmissionBeforeAnOverloadRetry() async throws {
        let transport = FakeJSONRPCTransport()
        let retryStarted = AsyncGate()
        let retryGate = AsyncGate()
        try await enqueueInitialize(transport)
        await transport.enqueueFailure(
            .responseError(code: -32001, message: "Server overloaded"),
            for: "thread/start"
        )
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-1"),
            for: "thread/start"
        )
        let client = AppServerClient(
            transport: transport,
            overloadRetryDelay: { _ in .milliseconds(1) },
            retrySleep: { _ in
                await retryStarted.open()
                await retryGate.waitIgnoringCancellation()
            }
        )
        let backend = AppServerCodexReviewBackend(client: client)
        let admission = ReviewStartAdmission()
        let cancellation = ReviewCancellation.system(message: "Runtime stopped")
        let start = Task {
            try await backend.startReview(
                .init(
                    jobID: "job-1",
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                ),
                admission: admission
            )
        }
        await retryStarted.wait()

        await admission.recordCancellation(cancellation)
        await retryGate.open()

        await #expect(throws: ReviewStartCancelledBeforeDispatch(cancellation: cancellation)) {
            try await start.value
        }
        let methods = await transport.recordedRequests().map(\.method)
        #expect(methods.filter { $0 == "thread/start" }.count == 1)
        #expect(methods.contains("review/start") == false)
    }

    @Test func backendRechecksReviewStartAdmissionBeforeAnOverloadRetry() async throws {
        let transport = FakeJSONRPCTransport()
        let retryStarted = AsyncGate()
        let retryGate = AsyncGate()
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-1"),
            for: "thread/start"
        )
        await transport.enqueueFailure(
            .responseError(code: -32001, message: "Server overloaded"),
            for: "review/start"
        )
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(turnID: "turn-1"),
            for: "review/start"
        )
        let client = AppServerClient(
            transport: transport,
            overloadRetryDelay: { _ in .milliseconds(1) },
            retrySleep: { _ in
                await retryStarted.open()
                await retryGate.waitIgnoringCancellation()
            }
        )
        let backend = AppServerCodexReviewBackend(client: client)
        let admission = ReviewStartAdmission()
        let cancellation = ReviewCancellation.system(message: "Runtime stopped")
        let start = Task {
            try await backend.startReview(
                .init(
                    jobID: "job-1",
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                ),
                admission: admission
            )
        }
        await retryStarted.wait()

        await admission.recordCancellation(cancellation)
        await retryGate.open()

        await #expect(throws: ReviewStartCancelledBeforeDispatch(cancellation: cancellation)) {
            try await start.value
        }
        let methods = await transport.recordedRequests().map(\.method)
        #expect(methods.filter { $0 == "review/start" }.count == 1)
    }

    @Test func backendDoesNotCleanupAnOutcomeUnknownReviewStart() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-1"),
            for: "thread/start"
        )
        await transport.enqueueCancellation(for: "review/start")
        try await transport.enqueue(
            AppServerAPI.Thread.Unsubscribe.Response(status: .unsubscribed),
            for: "thread/unsubscribe"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let admission = ReviewStartAdmission()

        await #expect(throws: CancellationError.self) {
            try await backend.startReview(
                .init(
                    jobID: "job-1",
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                ),
                admission: admission
            )
        }

        guard case .startingReview(let provisionalRun, .outcomeUnknown) = await admission.currentPhase() else {
            Issue.record("Outcome-unknown review/start did not retain its dispatch state.")
            return
        }
        let methods = await transport.recordedRequests().map(\.method)
        #expect(methods.contains("thread/backgroundTerminals/clean") == false)
        #expect(methods.contains("thread/unsubscribe") == false)
        #expect(methods.contains("thread/delete") == false)
        #expect(await backend.reviewStartRoutingReservationCountForTesting() == 1)

        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(
                threadID: "detached-review-thread",
                turn: .init(id: "detached-turn")
            )
        )
        let buffered = await waitUntil {
            await backend.notificationRouterMetricsForTesting().buffered == 1
        }
        #expect(buffered)
        #expect(await backend.unmatchedReviewNotificationCountForTesting() == 1)

        try await backend.cleanupReview(provisionalRun)
        #expect(await backend.reviewStartRoutingReservationCountForTesting() == 0)
        #expect(await backend.unmatchedReviewNotificationCountForTesting() == 0)
    }

    @Test func compatibilityStartCleansOutcomeUnknownBecauseItCannotPublishTheAdmission() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-1"),
            for: "thread/start"
        )
        await transport.enqueueCancellation(for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        await #expect(throws: CancellationError.self) {
            try await backend.startReview(.init(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            ))
        }

        let methods = await transport.recordedRequests().map(\.method)
        #expect(methods.contains("thread/backgroundTerminals/clean"))
        #expect(methods.contains("thread/unsubscribe"))
        #expect(methods.contains("thread/delete"))
    }

    @Test func backendTreatsMalformedReviewStartResponseAsProtocolTerminal() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-1"),
            for: "thread/start"
        )
        await transport.enqueueRawResponse(Data("not-json".utf8), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let admission = ReviewStartAdmission()
        var receivedError: AppServerStartRequestFailure?

        do {
            _ = try await backend.startReview(
                .init(
                    jobID: "job-1",
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                ),
                admission: admission
            )
            Issue.record("Malformed review/start response was accepted.")
        } catch let error as AppServerStartRequestFailure {
            receivedError = error
            #expect(error.stage == .responseDecoding)
        }

        let error = try #require(receivedError)
        #expect(await admission.currentPhase() == .terminal(.protocolFailure(
            .init(message: error.localizedDescription)
        )))
        #expect(await transport.recordedRequests().map(\.method).contains("thread/delete"))
    }

    @Test func backendTreatsTransportWriteFailureAsConnectionTerminal() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-1"),
            for: "thread/start"
        )
        await transport.enqueueTransportFailure(
            message: "Broken pipe",
            for: "review/start"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let admission = ReviewStartAdmission()

        do {
            _ = try await backend.startReview(
                .init(
                    jobID: "job-1",
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                ),
                admission: admission
            )
            Issue.record("Transport failure was not surfaced.")
        } catch let error as AppServerStartRequestFailure {
            #expect(error.stage == .transport)
            #expect(error.underlyingDescription == "Broken pipe")
        }

        #expect(await admission.currentPhase() == .terminal(.connection(
            .connection(AppServerStartRequestFailure(
                stage: .transport,
                underlyingDescription: "Broken pipe"
            ).localizedDescription)
        )))
        #expect(await transport.recordedRequests().map(\.method).contains("thread/delete"))
    }

    @Test func backendCleansReturnedReviewThreadWhenConnectionTerminalWinsActivation() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-1"),
            for: "thread/start"
        )
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "turn-1",
                reviewThreadID: "detached-review-thread"
            ),
            for: "review/start"
        )
        let admission = ReviewStartAdmission()
        let connection = ReviewRuntimeCloseFailure.connection("Connection ended")
        await transport.beforeReturningNextResponse(method: "review/start") {
            do {
                try await admission.recordConnectionTerminal(connection)
            } catch {
                Issue.record("Could not install the competing connection terminal: \(error)")
            }
        }
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        await #expect(throws: ReviewStartAdmissionContractFailure.self) {
            try await backend.startReview(
                .init(
                    jobID: "job-1",
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                ),
                admission: admission
            )
        }

        #expect(await admission.currentPhase() == .terminal(.connection(connection)))
        let methods = await transport.recordedRequests().map(\.method)
        #expect(methods.contains("thread/backgroundTerminals/clean"))
        #expect(methods.contains("thread/unsubscribe"))
        #expect(methods.contains("thread/delete"))
        let deletedThreadIDs = try await transport.recordedRequests()
            .filter { $0.method == "thread/delete" }
            .map {
                try JSONDecoder().decode(
                    AppServerAPI.Thread.Delete.Params.self,
                    from: $0.params
                ).threadID
            }
        #expect(Set(deletedThreadIDs) == ["thread-1", "detached-review-thread"])
    }

    @Test func backendCleansStartedThreadWhenConnectionTerminalWinsPreparation() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-1"),
            for: "thread/start"
        )
        let admission = ReviewStartAdmission()
        let connection = ReviewRuntimeCloseFailure.connection("Connection ended")
        await transport.beforeReturningNextResponse(method: "thread/start") {
            do {
                try await admission.recordConnectionTerminal(connection)
            } catch {
                Issue.record("Could not install the competing connection terminal: \(error)")
            }
        }
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        await #expect(throws: ReviewStartAdmissionContractFailure.self) {
            try await backend.startReview(
                .init(
                    jobID: "job-1",
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                ),
                admission: admission
            )
        }

        #expect(await admission.currentPhase() == .terminal(.connection(connection)))
        let methods = await transport.recordedRequests().map(\.method)
        #expect(methods.contains("thread/backgroundTerminals/clean"))
        #expect(methods.contains("thread/unsubscribe"))
        #expect(methods.contains("thread/delete"))
        #expect(methods.contains("review/start") == false)
    }

    @Test func backendUsesLegacySandboxWhenProcessDoesNotSupportModernSessionSource() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(
            client: .init(transport: transport),
            threadStartPermissionStrategy: .legacySandbox
        )

        _ = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))

        let threadStarts = await transport.recordedRequests().filter { $0.method == "thread/start" }
        #expect(threadStarts.count == 1)
        let request = try #require(threadStarts.first)
        let params = try #require(JSONSerialization.jsonObject(with: request.params) as? [String: Any])
        #expect(params["ephemeral"] as? Bool == false)
        #expect(params["sandbox"] as? String == "danger-full-access")
        #expect(params["permissions"] == nil)
        #expect(params["sessionStartSource"] as? String == "startup")
        #expect(params["threadSource"] as? String == "user")
    }

    @Test func backendRetriesThreadStartWithObjectPermissionsForInstalledCodex() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        await transport.enqueueFailure(
            .responseError(
                code: -32602,
                message: #"Invalid request: invalid type: string ":danger-full-access", expected internally tagged enum PermissionProfileSelectionParams"#
            ),
            for: "thread/start"
        )
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        _ = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))

        let threadStarts = await transport.recordedRequests().filter { $0.method == "thread/start" }
        #expect(threadStarts.count == 2)

        let firstRequest = try #require(threadStarts.first)
        let secondRequest = try #require(threadStarts.last)
        let first = try #require(JSONSerialization.jsonObject(
            with: firstRequest.params
        ) as? [String: Any])
        let second = try #require(JSONSerialization.jsonObject(
            with: secondRequest.params
        ) as? [String: Any])
        let permissions = try #require(second["permissions"] as? [String: Any])

        #expect(first["permissions"] as? String == ":danger-full-access")
        #expect(first["sandbox"] == nil)
        #expect(first["sessionStartSource"] as? String == "startup")
        #expect(first["threadSource"] as? String == "user")
        #expect(permissions["type"] as? String == "profile")
        #expect(permissions["id"] as? String == ":danger-full-access")
        #expect(second["sandbox"] == nil)
        #expect(second["sessionStartSource"] as? String == "startup")
        #expect(second["threadSource"] as? String == "user")
    }

    @Test func backendFallsBackToLegacySandboxWhenInstalledCodexLacksDangerProfile() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        await transport.enqueueFailure(
            .responseError(
                code: -32602,
                message: #"Invalid request: invalid type: string ":danger-full-access", expected internally tagged enum PermissionProfileSelectionParams"#
            ),
            for: "thread/start"
        )
        await transport.enqueueFailure(
            .responseError(
                code: -32602,
                message: "failed to load configuration: default_permissions refers to unknown built-in profile `:danger-full-access`"
            ),
            for: "thread/start"
        )
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        _ = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))

        let threadStarts = await transport.recordedRequests().filter { $0.method == "thread/start" }
        #expect(threadStarts.count == 3)

        let fallbackRequest = try #require(threadStarts.last)
        let fallback = try #require(JSONSerialization.jsonObject(
            with: fallbackRequest.params
        ) as? [String: Any])
        #expect(fallback["sandbox"] as? String == "danger-full-access")
        #expect(fallback["permissions"] == nil)
        #expect(fallback["sessionStartSource"] as? String == "startup")
        #expect(fallback["threadSource"] as? String == "user")
    }

    @Test func backendFallsBackToLegacySandboxWhenProfileIDPermissionsAreUnknown() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        await transport.enqueueFailure(
            .responseError(
                code: -32602,
                message: "failed to load configuration: default_permissions refers to unknown built-in profile `:danger-full-access`"
            ),
            for: "thread/start"
        )
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        _ = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))

        let threadStarts = await transport.recordedRequests().filter { $0.method == "thread/start" }
        #expect(threadStarts.count == 2)

        let firstRequest = try #require(threadStarts.first)
        let fallbackRequest = try #require(threadStarts.last)
        let first = try #require(JSONSerialization.jsonObject(
            with: firstRequest.params
        ) as? [String: Any])
        let fallback = try #require(JSONSerialization.jsonObject(
            with: fallbackRequest.params
        ) as? [String: Any])
        #expect(first["permissions"] as? String == ":danger-full-access")
        #expect(first["sandbox"] == nil)
        #expect(fallback["sandbox"] as? String == "danger-full-access")
        #expect(fallback["permissions"] == nil)
        #expect(fallback["sessionStartSource"] as? String == "startup")
        #expect(fallback["threadSource"] as? String == "user")
    }

    @Test func backendAppliesRequestedReviewModelToThreadStartAndRunMetadata() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            model: "gpt-5.5"
        ))

        let threadStart = try #require(await transport.recordedRequests().first { $0.method == "thread/start" })
        let params = try JSONDecoder().decode(AppServerAPI.Thread.Start.Params.self, from: threadStart.params)
        #expect(params.model == "gpt-5.5")
        #expect(run.model == "gpt-5.5")
    }

    @Test func appServerStartupResponsesDecodeNestedThreadAndTurnObjects() async throws {
        let threadStart = """
        {"thread":{"id":"thread-1"},"model":"gpt-5","modelProvider":"openai","serviceTier":null}
        """
        let reviewStart = """
        {"turn":{"id":"turn-1","items":[],"itemsView":"notLoaded","status":"inProgress","error":null,"startedAt":null,"completedAt":null,"durationMs":null},"reviewThreadId":"thread-1"}
        """
        let transport = FakeJSONRPCTransport(responses: [
            "initialize": [try JSONEncoder().encode(AppServerAPI.Initialize.Response())],
            "thread/start": [Data(threadStart.utf8)],
            "review/start": [Data(reviewStart.utf8)],
        ])
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))

        #expect(run.threadID == "thread-1")
        #expect(run.turnID == "turn-1")
        #expect(run.model == "gpt-5")
    }

    @Test func threadUnsubscribeResponseDecodesStatus() throws {
        let data = Data(#"{"status":"unsubscribed"}"#.utf8)
        let response = try JSONDecoder().decode(AppServerAPI.Thread.Unsubscribe.Response.self, from: data)

        #expect(response.status == .unsubscribed)
    }

    @Test func backendKeepsParentThreadIDForDetachedReviewThread() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "parent-thread", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-old", reviewThreadID: "review-thread"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await eventSequence(backend, run)

        #expect(run.threadID == "parent-thread")
        #expect(run.reviewThreadID == "review-thread")

        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(
                threadID: "review-thread",
                turn: .init(id: "turn-old"),
                reviewThreadID: "review-thread"
            )
        )
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-old", reviewThreadID: "review-thread", model: nil))

        try await backend.interruptReview(run, reason: .init())

        let request = try #require(await transport.recordedRequests().last)
        let params = try JSONDecoder().decode(AppServerAPI.Turn.Interrupt.Params.self, from: request.params)
        #expect(params.threadID == "review-thread")
        #expect(params.turnID == "turn-old")
    }

    @Test func backendInterruptUsesDetachedReviewThreadBeforeStartedNotification() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "parent-thread", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-old", reviewThreadID: "review-thread"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        try await backend.interruptReview(run, reason: .init(message: "Stop"))

        let request = try #require(await transport.recordedRequests().last)
        #expect(request.method == "turn/interrupt")
        let params = try JSONDecoder().decode(AppServerAPI.Turn.Interrupt.Params.self, from: request.params)
        #expect(params.threadID == "review-thread")
        #expect(params.turnID == "turn-old")
    }

    @Test func backendPreservesDetachedReviewThreadIDWhenReviewItemOmitsIt() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "parent-thread", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-old", reviewThreadID: "review-thread"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "review-thread",
                turnID: "turn-old",
                item: .init(type: "enteredReviewMode", id: "review-item-1", review: "current changes")
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-old", reviewThreadID: "review-thread", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .progress,
            text: "Reviewing current changes",
            groupID: "review-item-1",
            replacesGroup: true
        ))
    }

    @Test func backendRoutesDetachedReviewThreadNotificationsToParentSession() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "parent-thread", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-old", reviewThreadID: "review-thread"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        var iterator = await eventSequence(backend, run).makeAsyncIterator()

        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(
                threadID: "review-thread",
                turn: .init(id: "turn-old"),
                reviewThreadID: "review-thread"
            )
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TestDeltaNotification(
                threadID: "review-thread",
                turnID: "turn-old",
                itemID: "message-1",
                delta: "review text"
            )
        )

        #expect(try await iterator.next() == .started(turnID: "turn-old", reviewThreadID: "review-thread", model: nil))
        #expect(try await iterator.next() == .messageDelta("review text", itemID: "message-1"))
        #expect(await backend.reviewEventSessionMetricsForTesting(threadID: "review-thread")?.routed == 2)

        try await backend.interruptReview(run, reason: .init(message: "Stop"))
        let interruptRequest = try #require(await transport.recordedRequests().last)
        #expect(interruptRequest.method == "turn/interrupt")
        let interruptParams = try JSONDecoder().decode(AppServerAPI.Turn.Interrupt.Params.self, from: interruptRequest.params)
        #expect(interruptParams.threadID == "review-thread")
        #expect(interruptParams.turnID == "turn-old")
    }

    @Test func backendBuffersNotificationsBeforeAttemptMailboxRead() async throws {
        let run = CodexReviewBackendModel.Review.Run(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "message-1",
                delta: "review text"
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .messageDelta("review text", itemID: "message-1"))
    }

    @Test func backendLifecycleCloseJoinsOwnedRouterAndEventSessions() async throws {
        let transport = DeferredNotificationCloseTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let lifecycle = backend.runtimeOwnerLifecycleHandle
        let run = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-1",
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1"
        )
        var iterator = await eventSequence(backend, run).makeAsyncIterator()

        async let firstClose: Void = lifecycle.closeAndWait()
        async let secondClose: Void = lifecycle.closeAndWait()
        await backend.waitForRuntimeOwnerCloseCallersForTesting(2)
        await transport.waitForCloseCall()
        await backend.waitForClientCloseResultBeforeRouterWaitForTesting()

        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "message-1",
                delta: "delivered while lifecycle close waits"
            )
        )
        #expect(try await iterator.next() == .started(
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: nil
        ))
        #expect(try await iterator.next() == .messageDelta(
            "delivered while lifecycle close waits",
            itemID: "message-1"
        ))

        await transport.finishNotificationStream(throwing: JSONRPC.Error.closed)
        try await firstClose
        try await secondClose
        try await lifecycle.closeAndWait()

        #expect(await transport.recordedCloseCallCount() == 1)
        #expect(await backend.notificationRouterIsRunningForTesting() == false)
        await #expect(throws: BackendReviewEventMailboxError.self) {
            _ = try await iterator.next()
        }
        await #expect(throws: JSONRPC.Error.closed) {
            _ = try await backend.startReview(
                .init(
                    jobID: "job-2",
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                ),
                admission: ReviewStartAdmission()
            )
        }
        #expect(await transport.recordedSendCallCount() == 0)
    }

    @Test func backendLifecycleCloseJoinsOwnedTasksBeforeReplayingClientCloseFailure() async throws {
        let closeFailure = ReviewRuntimeCloseFailure.connection("close failed")
        let transport = DeferredNotificationCloseTransport(closeFailure: closeFailure)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let lifecycle = backend.runtimeOwnerLifecycleHandle
        let run = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-1",
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1"
        )
        var iterator = await eventSequence(backend, run).makeAsyncIterator()
        let completion = CompletionProbe()

        let close = Task {
            do {
                try await lifecycle.closeAndWait()
                await completion.recordCompletion()
            } catch {
                await completion.recordCompletion()
                throw error
            }
        }
        await backend.waitForRuntimeOwnerCloseCallersForTesting(1)
        await transport.waitForCloseCall()
        await backend.waitForClientCloseResultBeforeRouterWaitForTesting()
        #expect(await completion.hasCompleted() == false)
        await transport.finishNotificationStream(throwing: JSONRPC.Error.closed)

        await #expect(throws: closeFailure) {
            try await close.value
        }
        await #expect(throws: closeFailure) {
            try await lifecycle.closeAndWait()
        }
        #expect(await transport.recordedCloseCallCount() == 1)
        #expect(await backend.notificationRouterIsRunningForTesting() == false)
        await #expect(throws: BackendReviewEventMailboxError.self) {
            _ = try await iterator.next()
        }
    }

    @Test func backendLifecycleCloseJoinsInFlightRouterStart() async throws {
        let transport = DeferredNotificationCloseTransport()
        let notificationStreamGate = AsyncGate()
        await transport.holdNotificationStream(on: notificationStreamGate)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let lifecycle = backend.runtimeOwnerLifecycleHandle
        let run = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-1",
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1"
        )
        let operationCompletion = CompletionProbe()
        let closeCompletion = CompletionProbe()

        let operation = Task {
            let attempt = await backend.reviewAttemptForTesting(run)
            await operationCompletion.recordCompletion()
            return attempt
        }
        await transport.waitForNotificationStreamRequest()
        let close = Task {
            do {
                try await lifecycle.closeAndWait()
                await closeCompletion.recordCompletion()
            } catch {
                await closeCompletion.recordCompletion()
                throw error
            }
        }
        await backend.waitForRuntimeOwnerCloseCallersForTesting(1)
        await transport.waitForCloseCall()
        #expect(await operationCompletion.hasCompleted() == false)
        #expect(await closeCompletion.hasCompleted() == false)

        await notificationStreamGate.open()
        let attempt = await operation.value
        await backend.waitForClientCloseResultBeforeRouterWaitForTesting()
        #expect(await operationCompletion.hasCompleted())
        #expect(await closeCompletion.hasCompleted() == false)

        await transport.finishNotificationStream(throwing: JSONRPC.Error.closed)
        try await close.value
        #expect(await closeCompletion.hasCompleted())
        #expect(await backend.notificationRouterIsRunningForTesting() == false)

        var iterator = BackendReviewEventSequence(mailbox: attempt.events).makeAsyncIterator()
        await #expect(throws: BackendReviewEventMailboxError.self) {
            _ = try await iterator.next()
        }
    }

    @Test func backendLifecycleCloseJoinsAdmittedThreadStartBeforeSessionSnapshot() async throws {
        let transport = DeferredNotificationCloseTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"),
            for: "thread/start"
        )
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"),
            for: "review/start"
        )
        let threadStartBarrier = RequestBarrier()
        await transport.holdNext(method: "thread/start", barrier: threadStartBarrier)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let lifecycle = backend.runtimeOwnerLifecycleHandle
        let startCompletion = CompletionProbe()
        let closeCompletion = CompletionProbe()

        let start = Task {
            let attempt = try await backend.startReview(
                .init(
                    jobID: "job-1",
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                ),
                admission: ReviewStartAdmission()
            )
            await startCompletion.recordCompletion()
            return attempt
        }
        await threadStartBarrier.waitUntilEntered()
        let close = Task {
            try await lifecycle.closeAndWait()
            await closeCompletion.recordCompletion()
        }
        await backend.waitForRuntimeOwnerCloseCallersForTesting(1)
        await transport.waitForCloseCall()
        #expect(await startCompletion.hasCompleted() == false)
        #expect(await closeCompletion.hasCompleted() == false)

        await threadStartBarrier.open()
        let attempt = try await start.value
        await backend.waitForClientCloseResultBeforeRouterWaitForTesting()
        #expect(await startCompletion.hasCompleted())
        #expect(await closeCompletion.hasCompleted() == false)

        await transport.finishNotificationStream(throwing: JSONRPC.Error.closed)
        try await close.value
        #expect(await closeCompletion.hasCompleted())
        var iterator = BackendReviewEventSequence(mailbox: attempt.events).makeAsyncIterator()
        await #expect(throws: BackendReviewEventMailboxError.self) {
            _ = try await iterator.next()
        }
    }

    @Test func backendLifecycleCloseJoinsAdmittedRecoveryAcrossRollbackAndReviewStart() async throws {
        let transport = DeferredNotificationCloseTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(turnID: "turn-2", reviewThreadID: "thread-1"),
            for: "review/start"
        )
        let rollbackBarrier = RequestBarrier()
        let reviewStartBarrier = RequestBarrier()
        await transport.holdNext(method: "thread/rollback", barrier: rollbackBarrier)
        await transport.holdNext(method: "review/start", barrier: reviewStartBarrier)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let lifecycle = backend.runtimeOwnerLifecycleHandle
        let interruptedRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-1",
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: "gpt-5"
        )
        let handoff = try await makeResolvedRecoveryHandoffForTesting(
            backend,
            run: interruptedRun
        )
        let recoveryCompletion = CompletionProbe()
        let closeCompletion = CompletionProbe()

        let recovery = Task {
            let attempt = try await backend.resumeReviewRecovery(
                handoff,
                request: .init(
                    jobID: "job-1",
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                ),
                admission: ReviewStartAdmission()
            )
            await recoveryCompletion.recordCompletion()
            return attempt
        }
        await rollbackBarrier.waitUntilEntered()
        let close = Task {
            try await lifecycle.closeAndWait()
            await closeCompletion.recordCompletion()
        }
        await backend.waitForRuntimeOwnerCloseCallersForTesting(1)
        await transport.waitForCloseCall()

        await rollbackBarrier.open()
        await reviewStartBarrier.waitUntilEntered()
        await transport.finishNotificationStream(throwing: JSONRPC.Error.closed)
        #expect(await recoveryCompletion.hasCompleted() == false)
        #expect(await closeCompletion.hasCompleted() == false)

        await reviewStartBarrier.open()
        let recoveredAttempt = try await recovery.value
        try await close.value
        #expect(await closeCompletion.hasCompleted())
        var iterator = BackendReviewEventSequence(mailbox: recoveredAttempt.events).makeAsyncIterator()
        await #expect(throws: BackendReviewEventMailboxError.self) {
            _ = try await iterator.next()
        }
    }

    @Test func backendLifecycleCloseJoinsAdmittedInterrupt() async throws {
        let transport = DeferredNotificationCloseTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let interruptBarrier = RequestBarrier()
        await transport.holdNext(method: "turn/interrupt", barrier: interruptBarrier)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let lifecycle = backend.runtimeOwnerLifecycleHandle
        let run = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-1",
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1"
        )
        _ = await eventSequence(backend, run)
        let interruptCompletion = CompletionProbe()
        let closeCompletion = CompletionProbe()

        let interrupt = Task {
            try await backend.interruptReview(run, reason: .init(message: "Stop"))
            await interruptCompletion.recordCompletion()
        }
        await interruptBarrier.waitUntilEntered()
        let close = Task {
            try await lifecycle.closeAndWait()
            await closeCompletion.recordCompletion()
        }
        await backend.waitForRuntimeOwnerCloseCallersForTesting(1)
        await transport.waitForCloseCall()
        await transport.finishNotificationStream(throwing: JSONRPC.Error.closed)
        #expect(await interruptCompletion.hasCompleted() == false)
        #expect(await closeCompletion.hasCompleted() == false)

        await interruptBarrier.open()
        try await interrupt.value
        try await close.value
        #expect(await closeCompletion.hasCompleted())
    }

    @Test func backendLifecycleCloseJoinsAdmittedCleanupReview() async throws {
        let transport = DeferredNotificationCloseTransport()
        try await transport.enqueue(EmptyResponse(), for: "thread/backgroundTerminals/clean")
        try await transport.enqueue(
            AppServerAPI.Thread.Unsubscribe.Response(status: .unsubscribed),
            for: "thread/unsubscribe"
        )
        try await transport.enqueue(EmptyResponse(), for: "thread/delete")
        let cleanupBarrier = RequestBarrier()
        await transport.holdNext(
            method: "thread/backgroundTerminals/clean",
            barrier: cleanupBarrier
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let lifecycle = backend.runtimeOwnerLifecycleHandle
        let run = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-1",
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1"
        )
        let closeCompletion = CompletionProbe()

        let cleanup = Task {
            try await backend.cleanupReview(run)
        }
        await cleanupBarrier.waitUntilEntered()
        let close = Task {
            try await lifecycle.closeAndWait()
            await closeCompletion.recordCompletion()
        }
        await backend.waitForRuntimeOwnerCloseCallersForTesting(1)
        await transport.waitForCloseCall()
        await backend.waitForAdmittedReviewOperationDrainForTesting()
        #expect(await closeCompletion.hasCompleted() == false)

        await cleanupBarrier.open()
        try await cleanup.value
        try await close.value
        #expect(await closeCompletion.hasCompleted())
        #expect(await transport.recordedCloseCallCount() == 1)
    }

    @Test func backendPreservesNotificationStreamErrorForLateEventStreamSubscriber() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        #expect(await transport.notificationStreamCount() == 1)

        await transport.finishNotificationStreams(throwing: JSONRPC.Error.closed)
        let routerStopped = await waitUntil {
            await backend.notificationRouterIsRunningForTesting() == false
        }
        #expect(routerStopped)

        var iterator = await eventSequence(backend, run).makeAsyncIterator()
        await #expect(throws: BackendReviewEventMailboxError.self) {
            _ = try await iterator.next()
        }
        await transport.close()
    }

    @Test func backendPreservesBufferedEventsBeforeNotificationStreamError() async throws {
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = CodexReviewBackendModel.Review.Run(threadID: "thread-1", turnID: "turn-1")
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "message-1",
                delta: "partial review"
            )
        )
        await transport.finishNotificationStreams(throwing: JSONRPC.Error.closed)

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .messageDelta("partial review", itemID: "message-1"))
        await #expect(throws: BackendReviewEventMailboxError.self) {
            _ = try await iterator.next()
        }
    }

    @Test func backendTracksSyntheticDetachedReviewThreadStartsForInterrupt() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "parent-thread",
            turnID: "turn-new",
            reviewThreadID: "review-thread"
        )
        var iterator = await eventSequence(backend, run).makeAsyncIterator()

        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TestDeltaNotification(
                threadID: "review-thread",
                turnID: "turn-new",
                itemID: "message-1",
                delta: "review text"
            )
        )

        #expect(try await iterator.next() == .started(turnID: "turn-new", reviewThreadID: "review-thread", model: nil))
        #expect(try await iterator.next() == .messageDelta("review text", itemID: "message-1"))

        try await backend.interruptReview(run, reason: .init(message: "Stop"))
        let interruptRequest = try #require(await transport.recordedRequests().last)
        #expect(interruptRequest.method == "turn/interrupt")
        let interruptParams = try JSONDecoder().decode(AppServerAPI.Turn.Interrupt.Params.self, from: interruptRequest.params)
        #expect(interruptParams.threadID == "review-thread")
        #expect(interruptParams.turnID == "turn-new")
    }

    @Test func backendBuffersDetachedReviewThreadNotificationsDuringReviewStart() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "parent-thread", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-old", reviewThreadID: "review-thread"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let gate = AsyncGate()
        await transport.hold(method: "review/start", gate: gate)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        async let started = backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        await transport.waitForRequestCount(3)
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(
                threadID: "review-thread",
                turn: .init(id: "turn-old"),
                reviewThreadID: "review-thread"
            )
        )
        let bufferedDetachedNotification = await waitUntil {
            await backend.notificationRouterMetricsForTesting().buffered == 1
        }
        #expect(bufferedDetachedNotification)

        await gate.open()
        let run = try await started
        var iterator = await eventSequence(backend, run).makeAsyncIterator()

        #expect(try await iterator.next() == .started(turnID: "turn-old", reviewThreadID: "review-thread", model: nil))
        #expect(await backend.reviewEventSessionMetricsForTesting(threadID: "review-thread")?.routed == 1)
        try await backend.interruptReview(run, reason: .init(message: "Stop"))
        let interruptRequest = try #require(await transport.recordedRequests().last)
        #expect(interruptRequest.method == "turn/interrupt")
        let interruptParams = try JSONDecoder().decode(AppServerAPI.Turn.Interrupt.Params.self, from: interruptRequest.params)
        #expect(interruptParams.threadID == "review-thread")
        #expect(interruptParams.turnID == "turn-old")
    }

    @Test func backendBuffersParentThreadNotificationsDuringReviewStartUntilRunIsFinalized() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-response", reviewThreadID: "thread-1"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let gate = AsyncGate()
        await transport.hold(method: "review/start", gate: gate)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        async let started = backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        await transport.waitForRequestCount(3)
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(
                threadID: "thread-1",
                turn: .init(id: "turn-response"),
                reviewThreadID: "thread-1"
            )
        )
        let bufferedParentNotification = await waitUntil {
            await backend.reviewEventSessionMetricsForTesting(threadID: "thread-1")?.buffered == 1
        }
        #expect(bufferedParentNotification)

        await gate.open()
        let run = try await started
        var iterator = await eventSequence(backend, run).makeAsyncIterator()

        #expect(try await iterator.next() == .started(turnID: "turn-response", reviewThreadID: "thread-1", model: nil))
        try await backend.interruptReview(run, reason: .init(message: "Stop"))
        let interruptRequest = try #require(await transport.recordedRequests().last)
        #expect(interruptRequest.method == "turn/interrupt")
        let interruptParams = try JSONDecoder().decode(AppServerAPI.Turn.Interrupt.Params.self, from: interruptRequest.params)
        #expect(interruptParams.threadID == "thread-1")
        #expect(interruptParams.turnID == "turn-response")
    }

    @Test func backendUsesSingleNotificationRouterForConcurrentReviews() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-2", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-2", reviewThreadID: "thread-2"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        async let first = backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project-1", target: .uncommittedChanges)
        ))
        async let second = backend.startReview(.init(
            jobID: "job-2",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project-2", target: .uncommittedChanges)
        ))
        _ = try await (first, second)
        await transport.waitForNotificationStreamCount(1)

        #expect(await transport.notificationStreamCount() == 1)
    }

    @Test func backendRoutesInterleavedNotificationsToMatchingReviewSessions() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-2", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-2", reviewThreadID: "thread-2"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let firstRun = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project-1", target: .uncommittedChanges)
        ))
        let secondRun = try await backend.startReview(.init(
            jobID: "job-2",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project-2", target: .uncommittedChanges)
        ))
        let firstEvents = await eventSequence(backend, firstRun)
        let secondEvents = await eventSequence(backend, secondRun)
        var firstIterator = firstEvents.makeAsyncIterator()
        var secondIterator = secondEvents.makeAsyncIterator()

        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-2", turn: .init(id: "turn-2"))
        )
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-1"))
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TestDeltaNotification(threadID: "thread-2", turnID: "turn-2", itemID: "msg-2", delta: "Second")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TestDeltaNotification(threadID: "thread-1", turnID: "turn-1", itemID: "msg-1", delta: "First")
        )

        #expect(try await firstIterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await firstIterator.next() == .messageDelta("First", itemID: "msg-1"))
        #expect(try await secondIterator.next() == .started(turnID: "turn-2", reviewThreadID: "thread-2", model: nil))
        #expect(try await secondIterator.next() == .messageDelta("Second", itemID: "msg-2"))
    }

    @Test func backendBroadcastsGlobalDiagnosticsToActiveReviewSessions() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-2", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-2", reviewThreadID: "thread-2"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let firstRun = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project-1", target: .uncommittedChanges)
        ))
        let secondRun = try await backend.startReview(.init(
            jobID: "job-2",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project-2", target: .uncommittedChanges)
        ))
        var firstIterator = await eventSequence(backend, firstRun).makeAsyncIterator()
        var secondIterator = await eventSequence(backend, secondRun).makeAsyncIterator()

        try await transport.emitServerNotification(
            method: "warning",
            params: TestGlobalMessageNotification(message: "Global warning")
        )

        let expected = CodexReviewBackendModel.Review.Event.logEntry(
            kind: .diagnostic,
            text: "Global warning",
            groupID: nil,
            replacesGroup: false
        )
        #expect(try await firstIterator.next() == expected)
        #expect(try await secondIterator.next() == expected)
        #expect(await backend.notificationRouterMetricsForTesting().decoded == 1)
        #expect(await backend.notificationRouterMetricsForTesting().routed == 2)
    }

    @Test func backendMissingErrorIdentityClosesConnectionAndFailsActiveReviews() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-2", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-2", reviewThreadID: "thread-2"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let firstRun = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project-1", target: .uncommittedChanges)
        ))
        let secondRun = try await backend.startReview(.init(
            jobID: "job-2",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project-2", target: .uncommittedChanges)
        ))
        var firstIterator = await eventSequence(backend, firstRun).makeAsyncIterator()
        var secondIterator = await eventSequence(backend, secondRun).makeAsyncIterator()

        try await transport.emitServerNotification(
            method: "error",
            params: TestErrorNotification(message: "App-server failed.", willRetry: false)
        )

        await #expect(throws: BackendReviewEventMailboxError.self) {
            _ = try await firstIterator.next()
        }
        await #expect(throws: BackendReviewEventMailboxError.self) {
            _ = try await secondIterator.next()
        }
        #expect(await backend.notificationRouterMetricsForTesting().connectionFailures == 1)
        #expect(await transport.isClosedForTesting())
    }

    @Test func backendBuffersTerminalNotificationEmittedDuringReviewStart() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let gate = AsyncGate()
        await transport.hold(method: "review/start", gate: gate)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        async let started = backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        await transport.waitForRequestCount(3)
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-1", status: "completed"))
        )
        await gate.open()
        let run = try await started

        var iterator = await eventSequence(backend, run).makeAsyncIterator()
        #expect(try await iterator.next() == .failed(
            ReviewIngestionError.missingFinalReview.localizedDescription
        ))
    }

    @Test func backendBuffersCancellationBeforeEventStreamRegistration() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))

        try await backend.interruptReview(run, reason: .init(message: "Stop"))

        var iterator = await eventSequence(backend, run).makeAsyncIterator()
        #expect(try await iterator.next() == .cancelled("Stop"))
        #expect(try await iterator.next() == nil)
    }

    @Test func backendRecoverReviewRollsBackAndRestartsSameThread() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-2", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: "gpt-5"
        )

        let recovered = try await backend.resumeTypedReviewRecovery(
            run,
            request: .init(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                model: "gpt-5"
            ),
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )

        #expect(recovered.threadID == "thread-1")
        #expect(recovered.turnID == "turn-2")
        let requests = await transport.recordedRequests()
        #expect(requests.map(\.method) == [
            "initialize",
            "turn/interrupt",
            "thread/rollback",
            "review/start",
        ])
        let interrupt = try #require(requests.first { $0.method == "turn/interrupt" })
        let interruptParams = try JSONDecoder().decode(AppServerAPI.Turn.Interrupt.Params.self, from: interrupt.params)
        #expect(interruptParams.threadID == "thread-1")
        #expect(interruptParams.turnID == "turn-1")
        let rollback = try #require(requests.first { $0.method == "thread/rollback" })
        let rollbackParams = try JSONDecoder().decode(AppServerAPI.Thread.Rollback.Params.self, from: rollback.params)
        #expect(rollbackParams.threadID == "thread-1")
        #expect(rollbackParams.numTurns == 1)
        let restart = try #require(requests.first { $0.method == "review/start" })
        let restartParams = try JSONDecoder().decode(AppServerAPI.Review.Start.Params.self, from: restart.params)
        #expect(restartParams.threadID == "thread-1")
        #expect(restartParams.target == .baseBranch("main"))
    }

    @Test func recoveredAttemptUsesFreshControlForTypedCancellation() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"),
            for: "thread/start"
        )
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "turn-1",
                reviewThreadID: "thread-1"
            ),
            for: "review/start"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "turn-2",
                reviewThreadID: "thread-1"
            ),
            for: "review/start"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let started = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let recoveryReason = CodexReviewBackendModel.CancellationReason(
            message: "Network unavailable; waiting to reconnect."
        )
        let handoff = try await backend.prepareTypedReviewRecovery(
            started.run,
            reason: recoveryReason
        )
        let recoveryAdmission = ReviewStartAdmission()
        let recovered = try await backend.resumeReviewRecovery(
            handoff,
            request: .init(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                model: "gpt-5"
            ),
            admission: recoveryAdmission
        )
        let cancellation = ReviewCancellation.mcpClient(message: "Stop replacement")

        let interruption = Task {
            try await recoveryAdmission.interrupt(
                recovered.run,
                cancellation: cancellation,
                request: { requestAdmission, reason in
                    try await backend.interruptReview(
                        requestAdmission,
                        reason: reason
                    )
                }
            )
        }
        await transport.waitForRequestCount(7)
        try await recoveryAdmission.recordCanonicalTerminal(
            .interrupted(.server(message: cancellation.message)),
            for: recovered.run
        )
        let resolution = try await interruption.value

        #expect(resolution.run == recovered.run)
        #expect(resolution.terminal == .canonical(
            .interrupted(.requested(cancellation))
        ))
        let interruptions = try await transport.recordedRequests()
            .filter { $0.method == "turn/interrupt" }
            .map {
                try JSONDecoder().decode(
                    AppServerAPI.Turn.Interrupt.Params.self,
                    from: $0.params
                )
            }
        #expect(interruptions == [
            .init(threadID: "thread-1", turnID: "turn-1"),
            .init(threadID: "thread-1", turnID: "turn-2"),
        ])
    }

    @Test func backendRecoverReviewUsesDetachedReviewThreadBeforeStartedNotification() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "parent-thread", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-old", reviewThreadID: "review-thread"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-2", reviewThreadID: "review-thread"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))

        let recovered = try await backend.resumeTypedReviewRecovery(
            run,
            request: .init(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                model: "gpt-5"
            ),
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )

        #expect(recovered.threadID == "parent-thread")
        #expect(recovered.turnID == "turn-2")
        #expect(recovered.reviewThreadID == "review-thread")
        let requests = await transport.recordedRequests()
        let interrupt = try #require(requests.first { $0.method == "turn/interrupt" })
        let interruptParams = try JSONDecoder().decode(AppServerAPI.Turn.Interrupt.Params.self, from: interrupt.params)
        #expect(interruptParams.threadID == "review-thread")
        #expect(interruptParams.turnID == "turn-old")
        let rollback = try #require(requests.first { $0.method == "thread/rollback" })
        let rollbackParams = try JSONDecoder().decode(AppServerAPI.Thread.Rollback.Params.self, from: rollback.params)
        #expect(rollbackParams.threadID == "review-thread")
        #expect(rollbackParams.numTurns == 1)
        let restart = try #require(requests.last { $0.method == "review/start" })
        let restartParams = try JSONDecoder().decode(AppServerAPI.Review.Start.Params.self, from: restart.params)
        #expect(restartParams.threadID == "parent-thread")
        #expect(restartParams.target == .baseBranch("main"))
    }

    @Test func backendRecoverReviewRollsBackCanonicalDetachedReviewThread() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "parent-thread", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-old", reviewThreadID: "review-thread"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-2", reviewThreadID: "review-thread"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let startedRun = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        var iterator = await eventSequence(backend, startedRun).makeAsyncIterator()
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(
                threadID: "review-thread",
                turn: .init(id: "turn-old"),
                reviewThreadID: "review-thread"
            )
        )
        #expect(try await iterator.next() == .started(
            turnID: "turn-old",
            reviewThreadID: "review-thread",
            model: nil
        ))
        let currentRun = startedRun.run
        let reason = CodexReviewBackendModel.CancellationReason(message: "Network unavailable; waiting to reconnect.")

        let handoff = try await backend.prepareTypedReviewRecovery(
            currentRun,
            reason: reason
        )
        let recovered = try await backend.resumeReviewRecovery(
            handoff,
            request: .init(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                model: "gpt-5"
            ),
            admission: ReviewStartAdmission()
        )

        #expect(recovered.threadID == "parent-thread")
        #expect(recovered.turnID == "turn-2")
        #expect(recovered.reviewThreadID == "review-thread")
        let requests = await transport.recordedRequests()
        let interruptParams = try requests
            .filter { $0.method == "turn/interrupt" }
            .map { try JSONDecoder().decode(AppServerAPI.Turn.Interrupt.Params.self, from: $0.params) }
        #expect(interruptParams == [
            .init(threadID: "review-thread", turnID: "turn-old"),
        ])
        let rollback = try #require(requests.first { $0.method == "thread/rollback" })
        let rollbackParams = try JSONDecoder().decode(AppServerAPI.Thread.Rollback.Params.self, from: rollback.params)
        #expect(rollbackParams.threadID == "review-thread")
        #expect(rollbackParams.numTurns == 1)
        let restart = try #require(requests.last { $0.method == "review/start" })
        let restartParams = try JSONDecoder().decode(AppServerAPI.Review.Start.Params.self, from: restart.params)
        #expect(restartParams.threadID == "parent-thread")
        #expect(restartParams.target == .baseBranch("main"))
    }

    @Test func backendRecoverReviewDefaultsMissingReviewThreadToActiveThread() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-2"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )

        let recovered = try await backend.resumeTypedReviewRecovery(
            run,
            request: .init(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                model: "gpt-5"
            ),
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )

        #expect(recovered.threadID == "thread-1")
        #expect(recovered.turnID == "turn-2")
        #expect(recovered.reviewThreadID == "thread-1")
    }

    @Test func backendSuppressesRecoveryInterruptTerminalEvent() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-2", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: "gpt-5"
        )
        let initialEvents = await eventSequence(backend, run)
        defer { withExtendedLifetime(initialEvents) {} }

        let recoveredRun = try await backend.resumeTypedReviewRecovery(
            run,
            request: .init(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                model: "gpt-5"
            ),
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "thread-1",
                turn: .init(id: "turn-1", status: "interrupted", error: .init(message: "Network unavailable"))
            )
        )
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-2"))
        )

        let recoveredEvents = await eventSequence(backend, recoveredRun)
        var iterator = recoveredEvents.makeAsyncIterator()
        #expect(try await iterator.next() == .started(
            turnID: "turn-2",
            reviewThreadID: "thread-1",
            model: nil
        ))
    }

    @Test func backendRecoverReviewDoesNotReinterruptPreviouslyInterruptedTurn() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-2", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: "gpt-5"
        )
        let initialEvents = await eventSequence(backend, run)
        defer { withExtendedLifetime(initialEvents) {} }

        let handoff = try await backend.prepareTypedReviewRecovery(
            run,
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "thread-1",
                turn: .init(id: "turn-1", status: "interrupted", error: .init(message: "Network unavailable"))
            )
        )
        let ignoredInterruptedTurn = await waitUntil {
            await backend.notificationRouterMetricsForTesting().ignored == 1
        }
        #expect(ignoredInterruptedTurn)

        let recovered = try await backend.resumeReviewRecovery(
            handoff,
            request: .init(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                model: "gpt-5"
            ),
            admission: ReviewStartAdmission()
        )

        #expect(recovered.turnID == "turn-2")
        let requests = await transport.recordedRequests()
        #expect(requests.map(\.method) == [
            "initialize",
            "turn/interrupt",
            "thread/rollback",
            "review/start",
        ])
        let recoveredEvents = await eventSequence(backend, recovered)
        var iterator = recoveredEvents.makeAsyncIterator()
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-2"))
        )
        #expect(try await iterator.next() == .started(
            turnID: "turn-2",
            reviewThreadID: "thread-1",
            model: nil
        ))
    }

    @Test func backendIgnoresCompletedAbandonedRecoveryTurn() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: "gpt-5"
        )
        let events = await eventSequence(backend, run)
        var iterator = events.makeAsyncIterator()

        let handoff = try await backend.prepareTypedReviewRecovery(
            run,
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "thread-1",
                turn: .init(id: "turn-1", status: "completed")
            )
        )

        #expect(try await iterator.next() == nil)
        let ignoredCompletedTurn = await waitUntil {
            await backend.notificationRouterMetricsForTesting().ignored == 1
        }
        #expect(ignoredCompletedTurn)
        try await handoff.discard()
    }

    @Test func backendRecoveryBuffersFastTerminalNotificationUntilRecoveredRunIsTracked() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-2", reviewThreadID: "thread-1"), for: "review/start")
        let reviewStartGate = AsyncGate()
        await transport.hold(method: "review/start", gate: reviewStartGate)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: "gpt-5"
        )
        let initialEvents = await eventSequence(backend, run)
        defer { withExtendedLifetime(initialEvents) {} }

        async let recovered = backend.resumeTypedReviewRecovery(
            run,
            request: CodexReviewBackendModel.Review.Start(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                model: "gpt-5"
            ),
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )
        await transport.waitForRequestCount(4)
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-2", status: "completed"))
        )
        await reviewStartGate.open()
        let recoveredRun = try await recovered

        #expect(recoveredRun.turnID == "turn-2")
        let recoveredEvents = await eventSequence(backend, recoveredRun)
        var iterator = recoveredEvents.makeAsyncIterator()
        #expect(try await iterator.next() == .failed(
            ReviewIngestionError.missingFinalReview.localizedDescription
        ))
    }

    @Test func backendIgnoresStaleInterruptedTurnNotificationsWhileRollbackIsInFlight() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-2", reviewThreadID: "thread-1"), for: "review/start")
        let rollbackGate = AsyncGate()
        await transport.holdNext(method: "thread/rollback", gate: rollbackGate)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: "gpt-5"
        )
        let initialEvents = await eventSequence(backend, run)
        defer { withExtendedLifetime(initialEvents) {} }

        async let recovered = backend.resumeTypedReviewRecovery(
            run,
            request: CodexReviewBackendModel.Review.Start(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                model: "gpt-5"
            ),
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )
        let rollbackRequested = await waitUntil {
            await transport.recordedRequests().contains { $0.method == "thread/rollback" }
        }
        #expect(rollbackRequested)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "swift test")
            )
        )
        let ignoredStaleNotification = await waitUntil {
            await backend.notificationRouterMetricsForTesting().ignored == 1
        }
        #expect(ignoredStaleNotification)

        await rollbackGate.open()
        let recoveredRun = try await recovered
        #expect(recoveredRun.turnID == "turn-2")
        let recoveredEvents = await eventSequence(backend, recoveredRun)
        var iterator = recoveredEvents.makeAsyncIterator()

        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-2"))
        )
        #expect(try await iterator.next() == .started(
            turnID: "turn-2",
            reviewThreadID: "thread-1",
            model: nil
        ))
    }

    @Test func backendRecoveryClearsInterruptedCommandStateBeforeReplayingRecoveredTurn() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-2", reviewThreadID: "thread-1"), for: "review/start")
        let reviewStartGate = AsyncGate()
        await transport.hold(method: "review/start", gate: reviewStartGate)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: "gpt-5"
        )
        let events = await eventSequence(backend, run)
        var iterator = events.makeAsyncIterator()

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "swift test")
            )
        )
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ swift test",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-1",
                command: "swift test",
                startedAt: Date(timeIntervalSince1970: 0),
                commandStatus: "inProgress"
            )
        ))
        try await transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "cmd-1",
                delta: "old output"
            )
        )

        async let recovered = backend.resumeTypedReviewRecovery(
            run,
            request: CodexReviewBackendModel.Review.Start(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                model: "gpt-5"
            ),
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )
        await transport.waitForRequestCount(4)
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "enteredReviewMode", id: "stale-review", review: "stale changes")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-2"))
        )

        await reviewStartGate.open()
        let recoveredRun = try await recovered

        #expect(recoveredRun.turnID == "turn-2")
        let recoveredEvents = await eventSequence(backend, recoveredRun)
        var recoveredIterator = recoveredEvents.makeAsyncIterator()
        #expect(try await recoveredIterator.next() == .started(
            turnID: "turn-2",
            reviewThreadID: "thread-1",
            model: nil
        ))
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-2", status: "completed"))
        )
        #expect(try await recoveredIterator.next() == .failed(
            ReviewIngestionError.missingFinalReview.localizedDescription
        ))
    }

    @Test func backendCleanupDeletesAllRecoveryReviewThreads() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-2", reviewThreadID: "review-thread-2"), for: "review/start")
        try await transport.enqueue(
            AppServerAPI.Thread.Unsubscribe.Response(status: .unsubscribed),
            for: "thread/unsubscribe"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )

        let recovered = try await backend.resumeTypedReviewRecovery(
            run,
            request: .init(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                model: "gpt-5"
            ),
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )
        try await backend.cleanupReview(recovered)

        let deleteThreadIDs = try await transport.recordedRequests()
            .filter { $0.method == "thread/delete" }
            .map { request in
                try JSONDecoder().decode(AppServerAPI.Thread.Delete.Params.self, from: request.params).threadID
            }
        #expect(deleteThreadIDs == [
            "review-thread-1",
            "review-thread-2",
            "thread-1",
        ])
    }

    @Test func backendStreamsItemsForCanonicalResponseTurn() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-new", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-new",
                item: .init(type: "enteredReviewMode", id: "review-item-1", review: "current changes")
            )
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TestDeltaNotification(threadID: "thread-1", turnID: "turn-new", itemID: "message-1", delta: " hello")
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-new",
                item: .init(type: "exitedReviewMode", id: "review-item-1", review: "final review text")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-new", status: "completed"))
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-new", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .progress,
            text: "Reviewing current changes",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .messageDelta(" hello", itemID: "message-1"))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "final review text",
            groupID: "review-item-1",
            replacesGroup: true,
            metadata: .init(sourceType: "exitedReviewMode")
        ))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "final review text"))
    }

    @Test func backendIgnoresTerminalNotificationFromStaleObservedTurn() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-new", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-new",
                item: .init(type: "enteredReviewMode", id: "review-item-1", review: "current changes")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "thread-1",
                turn: .init(id: "turn-stale", status: "failed", error: .init(message: "Old turn failed"))
            )
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TestDeltaNotification(threadID: "thread-1", turnID: "turn-new", itemID: "message-1", delta: " current")
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-new",
                item: .init(type: "exitedReviewMode", id: "review-item-1", review: "final review text")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-new", status: "completed"))
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-new", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .progress,
            text: "Reviewing current changes",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .messageDelta(" current", itemID: "message-1"))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "final review text",
            groupID: "review-item-1",
            replacesGroup: true,
            metadata: .init(sourceType: "exitedReviewMode")
        ))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "final review text"))
    }

    @Test func backendIgnoresNonTerminalNotificationFromStaleObservedTurn() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-new", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-new",
                item: .init(type: "enteredReviewMode", id: "review-item-1", review: "current changes")
            )
        )
        try await transport.emitServerNotification(
            method: "error",
            params: TestErrorNotification(
                threadID: "thread-1",
                turnID: "turn-stale",
                message: "Retrying stale turn",
                willRetry: true
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-new",
                item: .init(type: "exitedReviewMode", id: "review-item-1", review: "final review text")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-new", status: "completed"))
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-new", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .progress,
            text: "Reviewing current changes",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "final review text",
            groupID: "review-item-1",
            replacesGroup: true,
            metadata: .init(sourceType: "exitedReviewMode")
        ))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "final review text"))
    }

    @Test func backendDoesNotCloseIgnoredTurnCommandLifecycleOnTrackedCompletion() async throws {
        let run = CodexReviewBackendModel.Review.Run(threadID: "thread-1", turnID: "turn-current")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-ignored",
                item: .init(type: "commandExecution", id: "cmd-ignored", command: "git diff")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-current", status: "completed"))
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .failed(
            ReviewIngestionError.missingFinalReview.localizedDescription
        ))
        #expect(try await iterator.next() == nil)
    }

    @Test func backendWaitsForTurnCompletedAfterReviewThreadBecomesNotLoaded() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "thread/status/changed",
            params: TestThreadStatusNotification(threadID: "thread-1", status: .init(type: "notLoaded"))
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "exitedReviewMode", id: "review-item-1", review: "final review text")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-1", status: "completed"))
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .logEntry(
            kind: .diagnostic,
            text: "Review thread is no longer loaded.",
            groupID: "thread-1",
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .started(
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: nil
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "final review text",
            groupID: "review-item-1",
            replacesGroup: true,
            metadata: .init(sourceType: "exitedReviewMode")
        ))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "final review text"))
        #expect(try await iterator.next() == nil)
    }

    @Test func backendWaitsForTurnCompletedAfterDetailedError() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "thread/status/changed",
            params: TestThreadStatusNotification(threadID: "thread-1", status: .init(type: "systemError"))
        )
        try await transport.emitServerNotification(
            method: "error",
            params: TestErrorNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                message: "Detailed failure",
                willRetry: false
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "thread-1",
                turn: .init(
                    id: "turn-1",
                    status: "failed",
                    error: .init(message: "Detailed failure")
                )
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .logEntry(
            kind: .diagnostic,
            text: "Review thread entered a system error state.",
            groupID: "thread-1",
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .started(
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: nil
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .error,
            text: "Detailed failure",
            groupID: "turn-1",
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .failed("Detailed failure"))
        #expect(try await iterator.next() == nil)
    }

    @Test func backendWaitsForTurnCompletedAfterReviewThreadCloses() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "thread/closed",
            params: TestThreadClosedNotification(threadID: "thread-1")
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "exitedReviewMode", id: "review-item-1", review: "final review text")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-1", status: "completed"))
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .logEntry(
            kind: .diagnostic,
            text: "Review thread closed.",
            groupID: "thread-1",
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .started(
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: nil
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "final review text",
            groupID: "review-item-1",
            replacesGroup: true,
            metadata: .init(sourceType: "exitedReviewMode")
        ))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "final review text"))
        #expect(try await iterator.next() == nil)
    }

    @Test func backendInterruptFinishesReviewEventStream() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await eventSequence(backend, run)
        var iterator = events.makeAsyncIterator()
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-1"))
        )

        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))

        try await backend.interruptReview(run, reason: .init(message: "Stop"))

        #expect(try await iterator.next() == .cancelled("Stop"))
        #expect(try await iterator.next() == nil)
    }

    @Test func backendInterruptClosesActiveCommandLifecycle() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await eventSequence(backend, run)
        var iterator = events.makeAsyncIterator()
        let startedAtMs: Int64 = 1_700_000_000_000
        let startedAt = Date(timeIntervalSince1970: TimeInterval(startedAtMs) / 1_000)
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "git diff"),
                startedAtMs: startedAtMs
            )
        )

        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ git diff",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-1",
                command: "git diff",
                startedAt: startedAt,
                commandStatus: "inProgress"
            )
        ))

        try await backend.interruptReview(run, reason: .init(message: "Stop"))

        guard case .logEntry(let kind, let text, let groupID, let replacesGroup, let metadata) = try await iterator.next()
        else {
            Issue.record("Expected active command to be closed before cancellation.")
            return
        }
        #expect(kind == .command)
        #expect(text == "$ git diff")
        #expect(groupID == "cmd-1")
        #expect(replacesGroup == true)
        #expect(metadata?.sourceType == "commandExecution")
        #expect(metadata?.status == "canceled")
        #expect(metadata?.itemID == "cmd-1")
        #expect(metadata?.command == "git diff")
        #expect(metadata?.startedAt == startedAt)
        #expect(metadata?.completedAt != nil)
        #expect(metadata?.durationMs != nil)
        #expect(metadata?.commandStatus == "canceled")
        #expect(try await iterator.next() == .cancelled("Stop"))
        #expect(try await iterator.next() == nil)
    }

    @Test func backendInterruptClosesActiveCommandOutputLifecycle() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await eventSequence(backend, run)
        var iterator = events.makeAsyncIterator()
        let startedAtMs: Int64 = 1_700_000_000_000
        let startedAt = Date(timeIntervalSince1970: TimeInterval(startedAtMs) / 1_000)
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "git status"),
                startedAtMs: startedAtMs
            )
        )
        try await transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "cmd-1",
                delta: " M README.md\n"
            )
        )
        try await transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "cmd-1",
                delta: "?? Sources/New.swift\n"
            )
        )

        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        _ = try await iterator.next()

        let routedOutput = await waitUntil {
            await backend.reviewEventSessionMetricsForTesting(threadID: "thread-1")?.routed ?? 0 >= 3
        }
        #expect(routedOutput)

        try await backend.interruptReview(run, reason: .init(message: "Stop"))

        var sawClosedOutput = false
        while let event = try await iterator.next() {
            if case .cancelled("Stop") = event {
                break
            }
            guard case .logEntry(let kind, let text, let groupID, let replacesGroup, let metadata) = event,
                  kind == .commandOutput,
                  replacesGroup
            else {
                continue
            }
            sawClosedOutput = true
            #expect(text == " M README.md\n?? Sources/New.swift\n")
            #expect(groupID == "cmd-1")
            #expect(metadata?.sourceType == "commandExecution")
            #expect(metadata?.status == "canceled")
            #expect(metadata?.itemID == "cmd-1")
            #expect(metadata?.command == "git status")
            #expect(metadata?.startedAt == startedAt)
            #expect(metadata?.completedAt != nil)
            #expect(metadata?.durationMs != nil)
            #expect(metadata?.commandStatus == "canceled")
        }
        #expect(sawClosedOutput)
        #expect(try await iterator.next() == nil)
    }

    @Test func backendCoalescesReasoningSummaryDeltasBeforeNextEvent() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await eventSequence(backend, run)
        try await transport.emitServerNotification(
            method: "item/reasoning/summaryTextDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "reasoning-1",
                delta: "Need to "
            )
        )
        try await transport.emitServerNotification(
            method: "item/reasoning/summaryTextDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "reasoning-1",
                delta: "inspect logs."
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "agentMessage", id: "message-1", text: "Continuing.")
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .reasoningSummary,
            text: "Need to inspect logs.",
            groupID: "reasoning-1:summary:0",
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "Continuing.",
            groupID: "message-1",
            replacesGroup: true
        ))
    }

    @Test func backendIgnoresAuxiliaryTurnAndInterruptsCanonicalTurn() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-old", reviewThreadID: "thread-1"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-old"))
        )
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-new",
                item: .init(type: "enteredReviewMode", id: "review-item-1", review: "current changes")
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-old", reviewThreadID: "thread-1", model: nil))

        try await backend.interruptReview(run, reason: .init())

        let request = try #require(await transport.recordedRequests().last)
        let params = try JSONDecoder().decode(AppServerAPI.Turn.Interrupt.Params.self, from: request.params)
        #expect(params.turnID == "turn-old")
    }

    @Test func backendKeepsCanonicalReviewCompletionWhenAuxiliaryTurnStarts() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-old", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-old",
                item: .init(type: "enteredReviewMode", id: "review-item-1", review: "current changes")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-new"))
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-old",
                item: .init(type: "exitedReviewMode", id: "review-item-1", review: "final review text")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-old", status: "completed"))
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-old", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .progress,
            text: "Reviewing current changes",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "final review text",
            groupID: "review-item-1",
            replacesGroup: true,
            metadata: .init(sourceType: "exitedReviewMode")
        ))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "final review text"))
    }

    @Test func backendUsesCanonicalResponseTurnWhenStartedNotificationIsMissing() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-old", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-old",
                item: .init(type: "enteredReviewMode", id: "review-item-1", review: "current changes")
            )
        )
        try await transport.emitServerNotification(
            method: "item/reasoning/summaryTextDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-old",
                itemID: "reasoning-1",
                delta: " Checking diff"
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-old",
                item: .init(type: "exitedReviewMode", id: "review-item-1", review: "final review text")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-old", status: "completed"))
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-old", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .progress,
            text: "Reviewing current changes",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .reasoningSummary,
            text: " Checking diff",
            groupID: "reasoning-1:summary:0",
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "final review text",
            groupID: "review-item-1",
            replacesGroup: true,
            metadata: .init(sourceType: "exitedReviewMode")
        ))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "final review text"))
    }

    @Test func backendKeepsCanonicalReviewIdentityWhileInterruptingActiveTurn() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "review-turn", reviewThreadID: "thread-1"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "review-turn",
                item: .init(type: "enteredReviewMode", id: "review-item-1", review: "current changes")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "active-turn"))
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "review-turn",
                itemID: "message-1",
                delta: "review output"
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "review-turn", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .progress,
            text: "Reviewing current changes",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .messageDelta("review output", itemID: "message-1"))

        try await backend.interruptReview(run, reason: .init())

        let params = try JSONDecoder().decode(
            AppServerAPI.Turn.Interrupt.Params.self,
            from: try #require(await transport.recordedRequests().last?.params)
        )
        #expect(params.turnID == "active-turn")
    }

    @Test func backendMapsReviewItemAndDiagnosticNotificationsToLogEntries() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "turn/plan/updated",
            params: TestPlanNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                plan: [
                    .init(step: "Inspect diff", status: "inProgress"),
                    .init(step: "Write findings", status: "pending"),
                ]
            )
        )
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "swift test")
            )
        )
        try await transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: TestDeltaNotification(threadID: "thread-1", turnID: "turn-1", itemID: "cmd-1", delta: "Tests")
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", aggregatedOutput: "Tests passed")
            )
        )
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-2", command: "pwd")
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-2", command: "pwd")
            )
        )
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "mcpToolCall", id: "tool-1", status: "inProgress", server: "codex_review", tool: "review_read")
            )
        )
        try await transport.emitServerNotification(
            method: "item/mcpToolCall/progress",
            params: TestMessageNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "tool-1",
                message: "Reading review job"
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    type: "mcpToolCall",
                    id: "tool-1",
                    status: "completed",
                    server: "codex_review",
                    tool: "review_read",
                    result: "ok"
                )
            )
        )
        try await transport.emitServerNotification(
            method: "item/reasoning/summaryTextDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "reasoning-1",
                delta: "summary",
                summaryIndex: 1
            )
        )
        try await transport.emitServerNotification(
            method: "item/reasoning/textDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "reasoning-1",
                delta: "raw chain",
                contentIndex: 2
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    type: "reasoning",
                    id: "reasoning-1",
                    summary: ["first final", "summary replacement"],
                    content: ["raw final", "other raw", "raw chain plus final"]
                )
            )
        )
        try await transport.emitServerNotification(
            method: "warning",
            params: TestMessageNotification(threadID: "thread-1", turnID: "turn-1", message: "Model warning")
        )
        try await transport.emitServerNotification(
            method: "deprecationNotice",
            params: TestDiagnosticNotification(summary: "Deprecated thing", details: "Use newer thing.")
        )
        try await transport.emitServerNotification(
            method: "model/rerouted",
            params: TestModelReroutedNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                fromModel: "gpt-5.4",
                toModel: "gpt-5.5",
                reason: "highRiskCyberActivity"
            )
        )
        try await transport.emitServerNotification(
            method: "turn/diff/updated",
            params: TestDiffNotification(threadID: "thread-1", turnID: "turn-1", diff: "diff --git")
        )
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "contextCompaction", id: "compact-1")
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "contextCompaction", id: "compact-1")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-1", status: "completed"))
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .todoList,
            text: "[inProgress] Inspect diff\n[pending] Write findings",
            groupID: "turn-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ swift test",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-1",
                command: "swift test",
                startedAt: Date(timeIntervalSince1970: 0),
                commandStatus: "inProgress"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .commandOutput,
            text: "Tests",
            groupID: "cmd-1",
            replacesGroup: false,
            metadata: .init(sourceType: "commandExecution", title: "Command output", itemID: "cmd-1")
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ swift test",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "completed",
                itemID: "cmd-1",
                command: "swift test",
                startedAt: Date(timeIntervalSince1970: 0),
                completedAt: Date(timeIntervalSince1970: 0),
                durationMs: 0,
                commandStatus: "completed"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .commandOutput,
            text: "Tests passed",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "completed",
                itemID: "cmd-1",
                command: "swift test",
                startedAt: Date(timeIntervalSince1970: 0),
                completedAt: Date(timeIntervalSince1970: 0),
                durationMs: 0,
                commandStatus: "completed"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ pwd",
            groupID: "cmd-2",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-2",
                command: "pwd",
                startedAt: Date(timeIntervalSince1970: 0),
                commandStatus: "inProgress"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ pwd",
            groupID: "cmd-2",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "completed",
                itemID: "cmd-2",
                command: "pwd",
                startedAt: Date(timeIntervalSince1970: 0),
                completedAt: Date(timeIntervalSince1970: 0),
                durationMs: 0,
                commandStatus: "completed"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .toolCall,
            text: "MCP codex_review.review_read started.",
            groupID: "tool-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "mcpToolCall",
                title: "codex_review.review_read",
                status: "started",
                server: "codex_review",
                tool: "review_read"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .toolCall,
            text: "Reading review job",
            groupID: "tool-1",
            replacesGroup: false,
            metadata: .init(sourceType: "mcpToolCall", title: "Tool progress")
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .toolCall,
            text: "codex_review.review_read completed. Result: ok",
            groupID: "tool-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "mcpToolCall",
                title: "codex_review.review_read",
                status: "completed",
                server: "codex_review",
                tool: "review_read",
                resultText: "ok"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .reasoningSummary,
            text: "summary",
            groupID: "reasoning-1:summary:1",
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .rawReasoning,
            text: "raw chain",
            groupID: "reasoning-1:2",
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .reasoningSummary,
            text: "first final",
            groupID: "reasoning-1:summary:0",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .reasoningSummary,
            text: "summary replacement",
            groupID: "reasoning-1:summary:1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .rawReasoning,
            text: "raw final",
            groupID: "reasoning-1:0",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .rawReasoning,
            text: "other raw",
            groupID: "reasoning-1:1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .rawReasoning,
            text: "raw chain plus final",
            groupID: "reasoning-1:2",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .diagnostic,
            text: "Model warning",
            groupID: "turn-1",
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .diagnostic,
            text: "Deprecated thing\nUse newer thing.",
            groupID: nil,
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .event,
            text: "Model rerouted: gpt-5.4 -> gpt-5.5 (highRiskCyberActivity).",
            groupID: "turn-1",
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .event,
            text: "diff --git",
            groupID: "turn-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .contextCompaction,
            text: "Automatically compacting context",
            groupID: "compact-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "contextCompaction",
                status: "inProgress",
                itemID: "compact-1",
                startedAt: Date(timeIntervalSince1970: 0)
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .contextCompaction,
            text: "Context automatically compacted",
            groupID: "compact-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "contextCompaction",
                status: "completed",
                itemID: "compact-1",
                completedAt: Date(timeIntervalSince1970: 0)
            )
        ))
        #expect(try await iterator.next() == .failed(
            ReviewIngestionError.missingFinalReview.localizedDescription
        ))
    }

    @Test func backendMapsExitedReviewModeItemToFinalAgentMessage() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "exitedReviewMode", id: "review-item-1", review: "final review text")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-1", status: "completed"))
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "final review text",
            groupID: "review-item-1",
            replacesGroup: true,
            metadata: .init(sourceType: "exitedReviewMode")
        ))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "final review text"))
    }

    @Test func backendCompletedAgentMessageReplacesPartialStateAndPreservesNonFinalMessage() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"),
            for: "thread/start"
        )
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"),
            for: "review/start"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        var iterator = await eventSequence(backend, run).makeAsyncIterator()

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "agentMessage", id: "non-final", text: "")
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "agentMessage", id: "non-final", text: "Complete non-final message")
            )
        )
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "agentMessage", id: "final", text: "Partial final")
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "agentMessage", id: "final", text: "Complete final")
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "exitedReviewMode", id: "review-result", review: "Canonical review")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "thread-1",
                turn: .init(id: "turn-1", status: "completed"),
                items: [.init(type: "agentMessage", id: "final", text: "Complete final")],
                itemsView: "summary"
            )
        )

        #expect(try await iterator.next() == .started(
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: nil
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "Complete non-final message",
            groupID: "non-final",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "Partial final",
            groupID: "final",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "Complete final",
            groupID: "final",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "Canonical review",
            groupID: "review-result",
            replacesGroup: true,
            metadata: .init(sourceType: "exitedReviewMode")
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "",
            groupID: "final",
            replacesGroup: true,
            metadata: .init(sourceType: "suppressedFinalReviewCompanion")
        ))
        #expect(try await iterator.next() == .completed(
            summary: "Succeeded.",
            result: "Canonical review"
        ))
    }

    @Test func backendPreservesCommandLifecycleMetadata() async throws {
        let run = CodexReviewBackendModel.Review.Run(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await eventSequence(backend, run)
        let startedAtMs: Int64 = 1_700_000_000_000
        let completedAtMs: Int64 = startedAtMs + 3_456

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    type: "commandExecution",
                    id: "cmd-1",
                    command: "cat Sources/ThreadItem.ts",
                    commandActions: [
                        .read(command: "cat Sources/ThreadItem.ts", name: "ThreadItem.ts", path: "Sources/ThreadItem.ts")
                    ],
                    status: "inProgress"
                ),
                startedAtMs: startedAtMs
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    type: "commandExecution",
                    id: "cmd-1",
                    aggregatedOutput: "file contents",
                    exitCode: 0,
                    durationMs: 3_000
                ),
                completedAtMs: completedAtMs
            )
        )

        let startedAt = Date(timeIntervalSince1970: TimeInterval(startedAtMs) / 1_000)
        let completedAt = Date(timeIntervalSince1970: TimeInterval(completedAtMs) / 1_000)
        let action = ReviewLogEntry.Metadata.CommandAction(
            kind: .read,
            command: "cat Sources/ThreadItem.ts",
            name: "ThreadItem.ts",
            path: "Sources/ThreadItem.ts"
        )
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ cat Sources/ThreadItem.ts",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-1",
                command: "cat Sources/ThreadItem.ts",
                startedAt: startedAt,
                commandActions: [action],
                commandStatus: "inProgress"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ cat Sources/ThreadItem.ts",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "completed",
                itemID: "cmd-1",
                command: "cat Sources/ThreadItem.ts",
                exitCode: 0,
                startedAt: startedAt,
                completedAt: completedAt,
                durationMs: 3_000,
                commandActions: [action],
                commandStatus: "completed"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .commandOutput,
            text: "file contents",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "completed",
                itemID: "cmd-1",
                command: "cat Sources/ThreadItem.ts",
                exitCode: 0,
                startedAt: startedAt,
                completedAt: completedAt,
                durationMs: 3_000,
                commandActions: [action],
                commandStatus: "completed"
            )
        ))
    }

    @Test func backendDerivesFailedCommandDurationWhenCompletedItemReportsZero() async throws {
        let run = CodexReviewBackendModel.Review.Run(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await eventSequence(backend, run)
        let startedAtMs: Int64 = 1_700_000_000_000
        let completedAtMs: Int64 = startedAtMs + 10_007

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    type: "commandExecution",
                    id: "cmd-failed",
                    command: "git diff -- Sources/CodexReview"
                ),
                startedAtMs: startedAtMs
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    type: "commandExecution",
                    id: "cmd-failed",
                    command: "git diff -- Sources/CodexReview",
                    aggregatedOutput: "execution error: No such process",
                    exitCode: -1,
                    durationMs: 0,
                    status: "failed"
                ),
                completedAtMs: completedAtMs
            )
        )

        let startedAt = Date(timeIntervalSince1970: TimeInterval(startedAtMs) / 1_000)
        let completedAt = Date(timeIntervalSince1970: TimeInterval(completedAtMs) / 1_000)
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ git diff -- Sources/CodexReview",
            groupID: "cmd-failed",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-failed",
                command: "git diff -- Sources/CodexReview",
                startedAt: startedAt,
                commandStatus: "inProgress"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ git diff -- Sources/CodexReview",
            groupID: "cmd-failed",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "failed",
                itemID: "cmd-failed",
                command: "git diff -- Sources/CodexReview",
                exitCode: -1,
                startedAt: startedAt,
                completedAt: completedAt,
                durationMs: 10_007,
                commandStatus: "failed"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .commandOutput,
            text: "execution error: No such process",
            groupID: "cmd-failed",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "failed",
                itemID: "cmd-failed",
                command: "git diff -- Sources/CodexReview",
                exitCode: -1,
                startedAt: startedAt,
                completedAt: completedAt,
                durationMs: 10_007,
                commandStatus: "failed"
            )
        ))
    }

    @Test func backendPreservesContextCompactionLifecycleMetadata() async throws {
        let run = CodexReviewBackendModel.Review.Run(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await eventSequence(backend, run)
        let startedAtMs: Int64 = 1_700_000_000_000
        let completedAtMs: Int64 = startedAtMs + 2_000

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "contextCompaction", id: "compact-1"),
                startedAtMs: startedAtMs
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "contextCompaction", id: "compact-1"),
                completedAtMs: completedAtMs
            )
        )

        let startedAt = Date(timeIntervalSince1970: TimeInterval(startedAtMs) / 1_000)
        let completedAt = Date(timeIntervalSince1970: TimeInterval(completedAtMs) / 1_000)
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .contextCompaction,
            text: "Automatically compacting context",
            groupID: "compact-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "contextCompaction",
                status: "inProgress",
                itemID: "compact-1",
                startedAt: startedAt
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .contextCompaction,
            text: "Context automatically compacted",
            groupID: "compact-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "contextCompaction",
                status: "completed",
                itemID: "compact-1",
                completedAt: completedAt
            )
        ))
    }

    @Test func backendPreservesFailedContextCompactionCompletionStatus() async throws {
        let run = CodexReviewBackendModel.Review.Run(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await eventSequence(backend, run)
        let completedAtMs: Int64 = 1_700_000_002_000

        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    type: "contextCompaction",
                    id: "compact-1",
                    status: "failed",
                    error: "compaction failed"
                ),
                completedAtMs: completedAtMs
            )
        )

        let completedAt = Date(timeIntervalSince1970: TimeInterval(completedAtMs) / 1_000)
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .contextCompaction,
            text: "Context compaction failed",
            groupID: "compact-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "contextCompaction",
                status: "failed",
                itemID: "compact-1",
                completedAt: completedAt,
                errorText: "compaction failed"
            )
        ))
    }

    @Test func backendMapsDeprecatedThreadCompactedToCompletedContextCompactionMarker() async throws {
        let run = CodexReviewBackendModel.Review.Run(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "thread/compacted",
            params: TestContextCompactedNotification(threadID: "thread-1", turnID: "turn-1")
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .contextCompaction,
            text: "Context automatically compacted",
            groupID: "contextCompaction:turn-1",
            replacesGroup: true,
            metadata: .init(sourceType: "contextCompaction", status: "completed")
        ))
    }

    @Test func backendFallsBackCommandDurationToLifecycleDates() async throws {
        let run = CodexReviewBackendModel.Review.Run(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "swift test"),
                startedAtMs: 2_000
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "swift test"),
                completedAtMs: 5_250
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ swift test",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-1",
                command: "swift test",
                startedAt: Date(timeIntervalSince1970: 2),
                commandStatus: "inProgress"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ swift test",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "completed",
                itemID: "cmd-1",
                command: "swift test",
                startedAt: Date(timeIntervalSince1970: 2),
                completedAt: Date(timeIntervalSince1970: 5.25),
                durationMs: 3_250,
                commandStatus: "completed"
            )
        ))
    }

    @Test func backendCompletesStreamedCommandOutputWhenCompletionHasNoAggregatedOutput() async throws {
        let run = CodexReviewBackendModel.Review.Run(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "swift test"),
                startedAtMs: 2_000
            )
        )
        try await transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "cmd-1",
                delta: " Tests passed\n"
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "swift test", exitCode: 0),
                completedAtMs: 5_250
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ swift test",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-1",
                command: "swift test",
                startedAt: Date(timeIntervalSince1970: 2),
                commandStatus: "inProgress"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .commandOutput,
            text: " Tests passed\n",
            groupID: "cmd-1",
            replacesGroup: false,
            metadata: .init(sourceType: "commandExecution", title: "Command output", itemID: "cmd-1")
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ swift test",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "completed",
                itemID: "cmd-1",
                command: "swift test",
                exitCode: 0,
                startedAt: Date(timeIntervalSince1970: 2),
                completedAt: Date(timeIntervalSince1970: 5.25),
                durationMs: 3_250,
                commandStatus: "completed"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .commandOutput,
            text: " Tests passed\n",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "completed",
                itemID: "cmd-1",
                command: "swift test",
                exitCode: 0,
                startedAt: Date(timeIntervalSince1970: 2),
                completedAt: Date(timeIntervalSince1970: 5.25),
                durationMs: 3_250,
                commandStatus: "completed"
            )
        ))
    }

    @Test func backendFlushesPendingStreamedCommandOutputBeforeNotificationStreamFinishes() async throws {
        let run = CodexReviewBackendModel.Review.Run(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "swift test"),
                startedAtMs: 2_000
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ swift test",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-1",
                command: "swift test",
                startedAt: Date(timeIntervalSince1970: 2),
                commandStatus: "inProgress"
            )
        ))

        try await transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "cmd-1",
                delta: "tail output\n"
            )
        )
        await transport.close()

        #expect(try await iterator.next() == .logEntry(
            kind: .commandOutput,
            text: "tail output\n",
            groupID: "cmd-1",
            replacesGroup: false,
            metadata: .init(sourceType: "commandExecution", title: "Command output", itemID: "cmd-1")
        ))
        #expect(try await iterator.next() == nil)
    }

    @Test func backendReviewExitCompletesMissingCommandCompletion() async throws {
        let run = CodexReviewBackendModel.Review.Run(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await eventSequence(backend, run)

        let startedAtMs: Int64 = 2_000
        let startedAt = Date(timeIntervalSince1970: 2)
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "enteredReviewMode", id: "review-item-1", review: "current changes")
            )
        )
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "git diff"),
                startedAtMs: startedAtMs
            )
        )
        try await transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "cmd-1",
                delta: " M README.md\n"
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "exitedReviewMode", id: "review-item-1", review: "final review text")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "thread-1",
                turn: .init(id: "turn-1", status: "completed")
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .progress,
            text: "Reviewing current changes",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ git diff",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-1",
                command: "git diff",
                startedAt: startedAt,
                commandStatus: "inProgress"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .commandOutput,
            text: " M README.md\n",
            groupID: "cmd-1",
            replacesGroup: false,
            metadata: .init(sourceType: "commandExecution", title: "Command output", itemID: "cmd-1")
        ))
        guard case .logEntry(let kind, let text, let groupID, let replacesGroup, let metadata) = try await iterator.next()
        else {
            Issue.record("Expected review exit to close the active command execution.")
            return
        }
        #expect(kind == .command)
        #expect(text == "$ git diff")
        #expect(groupID == "cmd-1")
        #expect(replacesGroup == true)
        #expect(metadata?.sourceType == "commandExecution")
        #expect(metadata?.status == "completed")
        #expect(metadata?.itemID == "cmd-1")
        #expect(metadata?.command == "git diff")
        #expect(metadata?.startedAt == startedAt)
        #expect(metadata?.completedAt != nil)
        #expect(metadata?.durationMs != nil)
        #expect(metadata?.commandStatus == "completed")
        guard case .logEntry(let outputKind, let outputText, let outputGroupID, let outputReplacesGroup, let outputMetadata) = try await iterator.next()
        else {
            Issue.record("Expected review exit to close the active command output.")
            return
        }
        #expect(outputKind == .commandOutput)
        #expect(outputText == " M README.md\n")
        #expect(outputGroupID == "cmd-1")
        #expect(outputReplacesGroup == true)
        #expect(outputMetadata?.sourceType == "commandExecution")
        #expect(outputMetadata?.status == "completed")
        #expect(outputMetadata?.itemID == "cmd-1")
        #expect(outputMetadata?.command == "git diff")
        #expect(outputMetadata?.startedAt == startedAt)
        #expect(outputMetadata?.completedAt != nil)
        #expect(outputMetadata?.durationMs != nil)
        #expect(outputMetadata?.commandStatus == "completed")
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "final review text",
            groupID: "review-item-1",
            replacesGroup: true,
            metadata: .init(sourceType: "exitedReviewMode")
        ))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "final review text"))
        #expect(try await iterator.next() == nil)
    }

    @Test func backendClosesMissingCommandCompletionBeforeFollowingReasoning() async throws {
        let run = CodexReviewBackendModel.Review.Run(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await eventSequence(backend, run)

        let startedAt = Date(timeIntervalSince1970: 2)
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "git diff"),
                startedAtMs: 2_000
            )
        )
        try await transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "cmd-1",
                delta: "diff output\n"
            )
        )
        try await transport.emitServerNotification(
            method: "item/reasoning/summaryTextDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "reasoning-1",
                delta: "Inspecting diffs"
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "exitedReviewMode", id: "review-item-1", review: "final review text")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "thread-1",
                turn: .init(id: "turn-1", status: "completed")
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ git diff",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-1",
                command: "git diff",
                startedAt: startedAt,
                commandStatus: "inProgress"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .commandOutput,
            text: "diff output\n",
            groupID: "cmd-1",
            replacesGroup: false,
            metadata: .init(sourceType: "commandExecution", title: "Command output", itemID: "cmd-1")
        ))
        guard case .logEntry(let commandKind, _, let commandGroupID, let commandReplacesGroup, let commandMetadata) = try await iterator.next()
        else {
            Issue.record("Expected following reasoning to close the active command execution.")
            return
        }
        #expect(commandKind == .command)
        #expect(commandGroupID == "cmd-1")
        #expect(commandReplacesGroup == true)
        #expect(commandMetadata?.status == "completed")
        #expect(commandMetadata?.itemID == "cmd-1")
        #expect(commandMetadata?.startedAt == startedAt)
        #expect(commandMetadata?.completedAt != nil)
        guard case .logEntry(let outputKind, let outputText, let outputGroupID, let outputReplacesGroup, let outputMetadata) = try await iterator.next()
        else {
            Issue.record("Expected following reasoning to close the active command output.")
            return
        }
        #expect(outputKind == .commandOutput)
        #expect(outputText == "diff output\n")
        #expect(outputGroupID == "cmd-1")
        #expect(outputReplacesGroup == true)
        #expect(outputMetadata?.status == "completed")
        #expect(outputMetadata?.itemID == "cmd-1")
        #expect(outputMetadata?.completedAt != nil)
        #expect(try await iterator.next() == .logEntry(
            kind: .reasoningSummary,
            text: "Inspecting diffs",
            groupID: "reasoning-1:summary:0",
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "final review text",
            groupID: "review-item-1",
            replacesGroup: true,
            metadata: .init(sourceType: "exitedReviewMode")
        ))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "final review text"))
        #expect(try await iterator.next() == nil)
    }

    @Test func backendIgnoresEmptyCommandTerminalInteractionPolls() async throws {
        let run = CodexReviewBackendModel.Review.Run(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "git diff")
            )
        )
        try await transport.emitServerNotification(
            method: "item/commandExecution/terminalInteraction",
            params: TestTerminalInteractionNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "cmd-1",
                processID: "123",
                stdin: ""
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "git diff")
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ git diff",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-1",
                command: "git diff",
                startedAt: Date(timeIntervalSince1970: 0),
                commandStatus: "inProgress"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ git diff",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "completed",
                itemID: "cmd-1",
                command: "git diff",
                startedAt: Date(timeIntervalSince1970: 0),
                completedAt: Date(timeIntervalSince1970: 0),
                durationMs: 0,
                commandStatus: "completed"
            )
        ))
    }

    @Test func backendCarriesRichToolAndFileMetadata() async throws {
        let run = CodexReviewBackendModel.Review.Run(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "webSearch", id: "web-1", query: "TextKit 2 markdown")
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "imageView", id: "image-1", status: "completed", path: "/tmp/screenshot.png")
            )
        )
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "fileChange", id: "file-1", path: "Sources/App.swift")
            )
        )
        try await transport.emitServerNotification(
            method: "item/fileChange/patchUpdated",
            params: TestMessageNotification(threadID: "thread-1", turnID: "turn-1", itemID: "file-1", message: "patch")
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "hookPrompt", id: "hook-1", status: "completed", prompt: "Allow command?")
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .toolCall,
            text: "Web search: TextKit 2 markdown",
            groupID: "web-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "webSearch",
                title: "Web search",
                status: "started",
                query: "TextKit 2 markdown"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .toolCall,
            text: "Image viewed: /tmp/screenshot.png.",
            groupID: "image-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "imageView",
                title: "Image view",
                status: "completed",
                path: "/tmp/screenshot.png"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .toolCall,
            text: "Applying file changes.",
            groupID: "file-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "fileChange",
                title: "File changes",
                status: "started",
                path: "Sources/App.swift"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .toolCall,
            text: "File changes updated.",
            groupID: "file-1",
            replacesGroup: false,
            metadata: .init(sourceType: "fileChange", title: "File changes", status: "updated")
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .event,
            text: "Hook prompt completed.",
            groupID: "hook-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "hookPrompt",
                title: "Hook prompt",
                status: "completed",
                detail: "Allow command?"
            )
        ))
    }

    @Test func backendMarksErroredToolCompletionsAsFailedMetadata() async throws {
        let run = CodexReviewBackendModel.Review.Run(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    type: "mcpToolCall",
                    id: "tool-error",
                    status: "failed",
                    server: "codex_review",
                    tool: "review_read",
                    error: "denied"
                )
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    type: "dynamicToolCall",
                    id: "tool-success-false",
                    status: "failed",
                    namespace: "web",
                    tool: "search",
                    result: "no matches",
                    success: false
                )
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .toolCall,
            text: "codex_review.review_read failed. Error: denied",
            groupID: "tool-error",
            replacesGroup: true,
            metadata: .init(
                sourceType: "mcpToolCall",
                title: "codex_review.review_read",
                status: "failed",
                server: "codex_review",
                tool: "review_read",
                errorText: "denied"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .toolCall,
            text: "Dynamic tool web.search failed. Result: no matches",
            groupID: "tool-success-false",
            replacesGroup: true,
            metadata: .init(
                sourceType: "dynamicToolCall",
                title: "web.search",
                status: "failed",
                namespace: "web",
                tool: "search",
                resultText: "no matches"
            )
        ))
    }

    @Test func backendRejectsObsoleteTerminalBeforeFinalMarkerOrdering() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "enteredReviewMode", id: "review-item-1", review: "current changes")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-1", status: "completed"))
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "exitedReviewMode", id: "review-item-1", review: "final review text")
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .progress,
            text: "Reviewing current changes",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .failed(
            ReviewIngestionError.missingFinalReview.localizedDescription
        ))
    }

    @Test func backendReplaysBufferedReviewLifecycleNotifications() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                lifecycle: .started,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "enteredReviewMode", id: "review-item-1", review: "current changes")
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                lifecycle: .completed,
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "exitedReviewMode", id: "review-item-1", review: "final review text")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-1", status: "completed"))
        )

        let events = await eventSequence(backend, run)
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .progress,
            text: "Reviewing current changes",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "final review text",
            groupID: "review-item-1",
            replacesGroup: true,
            metadata: .init(sourceType: "exitedReviewMode")
        ))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "final review text"))
        #expect(try await iterator.next() == nil)
    }

    @Test func backendMapsTerminalFailureAndCancellationNotifications() async throws {
        let failedRun = CodexReviewBackendModel.Review.Run(threadID: "thread-1", turnID: "turn-1")
        let failedTransport = FakeJSONRPCTransport()
        let failedBackend = AppServerCodexReviewBackend(client: .init(transport: failedTransport))
        let failedEvents = await eventSequence(failedBackend, failedRun)

        try await failedTransport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "thread-1",
                turn: .init(id: "turn-1", status: "failed", error: .init(message: "Review failed"))
            )
        )

        var failedIterator = failedEvents.makeAsyncIterator()
        #expect(try await failedIterator.next() == .failed("Review failed"))

        let cancelledRun = CodexReviewBackendModel.Review.Run(threadID: "thread-2", turnID: "turn-2")
        let cancelledTransport = FakeJSONRPCTransport()
        let cancelledBackend = AppServerCodexReviewBackend(client: .init(transport: cancelledTransport))
        let cancelledEvents = await eventSequence(cancelledBackend, cancelledRun)

        try await cancelledTransport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "thread-2",
                turn: .init(id: "turn-2", status: "interrupted", error: .init(message: "Stopped"))
            )
        )

        var cancelledIterator = cancelledEvents.makeAsyncIterator()
        #expect(try await cancelledIterator.next() == .cancelled("Stopped"))

        let failedWithoutMessageRun = CodexReviewBackendModel.Review.Run(threadID: "thread-4", turnID: "turn-4")
        let failedWithoutMessageTransport = FakeJSONRPCTransport()
        let failedWithoutMessageBackend = AppServerCodexReviewBackend(client: .init(transport: failedWithoutMessageTransport))
        let failedWithoutMessageEvents = await eventSequence(failedWithoutMessageBackend, failedWithoutMessageRun)

        try await failedWithoutMessageTransport.emitServerNotification(
            method: "turn/completed",
            params: TestPartialTurnNotification(
                threadID: "thread-4",
                turn: .init(id: "turn-4", status: "failed", error: .init())
            )
        )

        var failedWithoutMessageIterator = failedWithoutMessageEvents.makeAsyncIterator()
        #expect(try await failedWithoutMessageIterator.next() == .failed(nil))

        let cancelledWithoutMessageRun = CodexReviewBackendModel.Review.Run(threadID: "thread-5", turnID: "turn-5")
        let cancelledWithoutMessageTransport = FakeJSONRPCTransport()
        let cancelledWithoutMessageBackend = AppServerCodexReviewBackend(client: .init(transport: cancelledWithoutMessageTransport))
        let cancelledWithoutMessageEvents = await eventSequence(cancelledWithoutMessageBackend, cancelledWithoutMessageRun)

        try await cancelledWithoutMessageTransport.emitServerNotification(
            method: "turn/completed",
            params: TestPartialTurnNotification(
                threadID: "thread-5",
                turn: .init(id: "turn-5", status: "interrupted", error: .init())
            )
        )

        var cancelledWithoutMessageIterator = cancelledWithoutMessageEvents.makeAsyncIterator()
        #expect(try await cancelledWithoutMessageIterator.next() == .cancelled(nil))

        let retryingRun = CodexReviewBackendModel.Review.Run(threadID: "thread-3", turnID: "turn-3")
        let retryingTransport = FakeJSONRPCTransport()
        let retryingBackend = AppServerCodexReviewBackend(client: .init(transport: retryingTransport))
        let retryingEvents = await eventSequence(retryingBackend, retryingRun)

        try await retryingTransport.emitServerNotification(
            method: "error",
            params: TestErrorNotification(threadID: "thread-3", turnID: "turn-3", message: "Retrying request", willRetry: true)
        )
        try await retryingTransport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-3", turn: .init(id: "turn-3", status: "completed"))
        )

        var retryingIterator = retryingEvents.makeAsyncIterator()
        #expect(try await retryingIterator.next() == .started(turnID: "turn-3", reviewThreadID: "thread-3", model: nil))
        #expect(try await retryingIterator.next() == .logEntry(
            kind: .progress,
            text: "Retrying request",
            groupID: "turn-3",
            replacesGroup: false
        ))
        #expect(try await retryingIterator.next() == .failed(
            ReviewIngestionError.missingFinalReview.localizedDescription
        ))
    }

    @Test func backendIgnoresUnrelatedNotificationsBeforeReviewPayloadDecode() async throws {
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = CodexReviewBackendModel.Review.Run(threadID: "thread-1", turnID: "turn-1")
        let events = await eventSequence(backend, run)

        try await transport.emitServerNotification(
            method: "account/updated",
            params: ["accountID": "account-1"]
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-1", status: "completed"))
        )

        var iterator = events.makeAsyncIterator()
        let event = try await iterator.next()
        #expect(event == .failed(ReviewIngestionError.missingFinalReview.localizedDescription))
    }

    @Test func backendCleansThreadWhenReviewStartFailsAfterThreadStart() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1"), for: "thread/start")
        await transport.enqueueFailure(.responseError(code: -32602, message: "invalid target"), for: "review/start")
        await transport.enqueueFailure(.responseError(code: -32000, message: "clean failed"), for: "thread/backgroundTerminals/clean")
        await transport.enqueueFailure(.responseError(code: -32000, message: "unsubscribe failed"), for: "thread/unsubscribe")
        await transport.enqueueFailure(.responseError(code: -32000, message: "delete failed"), for: "thread/delete")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let admission = ReviewStartAdmission()

        await #expect(throws: JSONRPC.Error.responseError(code: -32602, message: "invalid target")) {
            try await backend.startReview(
                .init(
                    jobID: "job-1",
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                ),
                admission: admission
            )
        }

        #expect(await admission.currentPhase() == .terminal(.rejected(
            .rejected(code: -32602, message: "invalid target")
        )))

        let methods = await transport.recordedRequests().map(\.method)
        #expect(methods == [
            "initialize",
            "thread/start",
            "review/start",
            "thread/backgroundTerminals/clean",
            "thread/unsubscribe",
            "thread/delete",
        ])
    }

    @Test func backendCleanupAttemptsEveryStepAndAggregatesFailuresInOrder() async throws {
        let transport = FakeJSONRPCTransport()
        await transport.enqueueFailure(
            .responseError(code: -32000, message: "clean failed"),
            for: "thread/backgroundTerminals/clean"
        )
        await transport.enqueueFailure(
            .responseError(code: -32000, message: "unsubscribe failed"),
            for: "thread/unsubscribe"
        )
        await transport.enqueueFailure(
            .responseError(code: -32000, message: "review delete failed"),
            for: "thread/delete"
        )
        await transport.enqueueFailure(
            .responseError(code: -32000, message: "canonical delete failed"),
            for: "thread/delete"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )

        await #expect(throws: ReviewRuntimeCloseFailure.cleanup(
            "thread/backgroundTerminals/clean for thread-1: clean failed; "
                + "thread/unsubscribe for thread-1: unsubscribe failed; "
                + "thread/delete for review-thread-1: review delete failed; "
                + "thread/delete for thread-1: canonical delete failed"
        )) {
            try await backend.cleanupReview(run)
        }

        let requests = await transport.recordedRequests()
        #expect(requests.map(\.method) == [
            "thread/backgroundTerminals/clean",
            "thread/unsubscribe",
            "thread/delete",
            "thread/delete",
        ])
        let deletedThreadIDs = try requests
            .filter { $0.method == "thread/delete" }
            .map { request in
                try JSONDecoder().decode(AppServerAPI.Thread.Delete.Params.self, from: request.params).threadID
            }
        #expect(deletedThreadIDs == ["review-thread-1", "thread-1"])
    }

    @Test @MainActor
    func storeRetainsCleanupFailureAsSecondaryDiagnosticWithoutMaskingPrimary() async throws {
        let backend = FakeCodexReviewBackend()
        let cleanupGate = AsyncGate()
        await backend.holdCleanupReview(with: cleanupGate)
        await backend.failCleanup(message: "cleanup failed")
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )

        let initial = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .zero
        )
        #expect(initial.core.lifecycle.status == .running)
        await backend.yield(.failed("primary review failed"))
        let cleanupStarted = await waitUntilOnMainActor {
            await backend.recordedCommands().contains(.cleanupReview(.init(
                threadID: "thread-1",
                turnID: "turn-1",
                reviewThreadID: "review-thread-1"
            )))
        }
        #expect(cleanupStarted)
        #expect(try store.readReview(jobID: "job-1").core.lifecycle.status == .failed)
        let result = Task { @MainActor in
            try await store.awaitReview(
                sessionID: "session-1",
                jobID: "job-1",
                timeout: .seconds(5)
            )
        }
        let waiterRegistered = await waitUntilOnMainActor {
            store.reviewTerminalWaiters["job-1"]?.count == 1
        }
        #expect(waiterRegistered)
        #expect(store.reviewTerminalWaiters["job-1"]?.count == 1)

        await cleanupGate.open()
        let read = try await result.value

        #expect(read.core.lifecycle.status == .failed)
        #expect(read.core.lifecycle.errorMessage == "primary review failed")
        #expect(read.logs.allSatisfy { $0.audience == .product })
        let allRead = try store.readReview(jobID: "job-1", logFilter: .all)
        let cleanupEntry = try #require(allRead.logs.first { $0.audience == .developer })
        #expect(cleanupEntry.kind == .diagnostic)
        #expect(cleanupEntry.text == "Review cleanup failed: cleanup failed")
        let job = try #require(store.job(id: "job-1"))
        #expect(job.logEntries.contains(cleanupEntry))
        #expect(job.rawLogText == cleanupEntry.text)
        #expect(job.diagnosticText.hasSuffix(cleanupEntry.text))
        await backend.finishEventMailboxes()
        await store.cancelAndDrainReviewWorkersForTesting()
    }

    @Test @MainActor
    func storeRuntimeStopDetachmentFinalizesResultWithoutWaitingForDetachedWorker() async throws {
        let backend = FakeCodexReviewBackend()
        let startGate = AsyncGate()
        await backend.holdStartReviewIgnoringCancellation(with: startGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        let result = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        try await backend.waitForStartReview(timeout: .seconds(2))
        let waiterRegistered = await waitUntilOnMainActor {
            store.reviewTerminalWaiters["job-1"]?.count == 1
        }
        #expect(waiterRegistered)

        let jobIDs = store.cancelActiveReviewsLocallyForRuntimeStop(
            reason: .system(message: "Review runtime stopped.")
        )
        #expect(store.reviewTerminalWaiters["job-1"]?.count == 1)
        await store.cancelAndDetachReviewWorkersForRuntimeStop(
            jobIDs: jobIDs,
            reason: .system(message: "Review runtime stopped.")
        )

        #expect(store.reviewTerminalWaiters["job-1"] == nil)
        #expect(store.runtimeStopDetachedReviewWorkerTasks["job-1"] != nil)
        #expect(try await result.value.core.lifecycle.status == .cancelled)

        await startGate.open()
        #expect(await store.drainRuntimeStopDetachedReviewWorkers(timeout: .seconds(2)))
        await backend.finishEventMailboxes()
        await store.cancelAndDrainReviewWorkersForTesting()
    }

    private func waitUntil(timeout: Duration = .seconds(2), condition: () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while await condition() == false {
            if clock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    @MainActor
    private func waitUntilOnMainActor(
        timeout: Duration = .seconds(2),
        condition: @MainActor () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while await condition() == false {
            if clock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func waitUntil(timeout: Duration, condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while condition() == false {
            if clock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }
}

private func enqueueInitialize(_ transport: FakeJSONRPCTransport) async throws {
    try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
}

private func makeModelCatalogItem(
    model: String,
    isDefault: Bool = false
) -> CodexReviewSettings.ModelCatalogItem {
    .init(
        id: model,
        model: model,
        displayName: model,
        hidden: false,
        supportedReasoningEfforts: [.init(reasoningEffort: .medium, description: "Balanced")],
        defaultReasoningEffort: .medium,
        supportedServiceTiers: [.fast],
        isDefault: isDefault
    )
}

private struct TestTurnNotification: Encodable, Sendable {
    var threadID: String
    var turn: AppServerAPI.Turn.Payload
    var reviewThreadID: String? = nil
    var items: [TestItem] = []
    var itemsView: String = "notLoaded"

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
        case reviewThreadID = "reviewThreadId"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(threadID, forKey: .threadID)
        try container.encode(CurrentTurn(
            id: turn.id,
            items: items,
            itemsView: itemsView,
            status: turn.status ?? "inProgress",
            error: turn.error
        ), forKey: .turn)
        try container.encodeIfPresent(reviewThreadID, forKey: .reviewThreadID)
    }

    private struct CurrentTurn: Encodable {
        var id: String
        var items: [TestItem]
        var itemsView: String
        var status: String
        var error: AppServerAPI.Turn.Error?
    }
}

private struct TestPartialTurnNotification: Encodable, Sendable {
    var threadID: String
    var turn: TestPartialTurn

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
    }
}

private struct TestPartialTurn: Encodable, Sendable {
    var id: String
    var status: String
    var error: TestPartialTurnError
    var items: [TestItem] = []
    var itemsView: String = "notLoaded"
}

private struct TestPartialTurnError: Encodable, Sendable {}

private struct TestThreadStatusNotification: Encodable, Sendable {
    var threadID: String
    var status: TestThreadStatus

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case status
    }
}

private struct TestThreadStatus: Encodable, Sendable {
    var type: String
}

private struct TestThreadClosedNotification: Encodable, Sendable {
    var threadID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

private struct TestContextCompactedNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
    }
}

private struct TestDeltaNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var delta: String
    var summaryIndex: Int? = 0
    var contentIndex: Int? = 0

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case delta
        case summaryIndex
        case contentIndex
    }
}

private struct TestTerminalInteractionNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var processID: String
    var stdin: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case processID = "processId"
        case stdin
    }
}

private struct TestPlanNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var plan: [Step]

    struct Step: Encodable, Sendable {
        var step: String
        var status: String
    }

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case plan
    }
}

private struct TestItemNotification: Encodable, Sendable {
    enum Lifecycle: Equatable, Sendable {
        case started
        case completed
    }

    var threadID: String
    var turnID: String
    var item: TestItem
    var startedAtMs: Int64?
    var completedAtMs: Int64?

    init(
        lifecycle: Lifecycle,
        threadID: String,
        turnID: String,
        item: TestItem,
        startedAtMs: Int64? = nil,
        completedAtMs: Int64? = nil
    ) {
        self.threadID = threadID
        self.turnID = turnID
        var item = item
        item.applySchemaDefaults(for: lifecycle)
        self.item = item
        switch lifecycle {
        case .started:
            self.startedAtMs = startedAtMs ?? 0
            self.completedAtMs = completedAtMs
        case .completed:
            self.startedAtMs = startedAtMs
            self.completedAtMs = completedAtMs ?? 0
        }
    }

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case item
        case startedAtMs
        case completedAtMs
    }
}

private struct TestItem: Encodable, Sendable {
    var type: String
    var id: String
    var text: String?
    var review: String?
    var command: String?
    var cwd: String?
    var processID: String?
    var source: String?
    var aggregatedOutput: String?
    var exitCode: Int?
    var durationMs: Int?
    var commandActions: [TestCommandAction]?
    var status: String?
    var namespace: String?
    var server: String?
    var tool: String?
    var query: String?
    var path: String?
    var result: String?
    var error: String?
    var success: Bool?
    var prompt: String?
    var summary: [String]?
    var content: [String]?
    var fragments: [String]?
    var changes: [String]?
    var arguments: String?

    init(
        type: String,
        id: String,
        text: String? = nil,
        review: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        processID: String? = nil,
        source: String? = nil,
        aggregatedOutput: String? = nil,
        exitCode: Int? = nil,
        durationMs: Int? = nil,
        commandActions: [TestCommandAction]? = nil,
        status: String? = nil,
        namespace: String? = nil,
        server: String? = nil,
        tool: String? = nil,
        query: String? = nil,
        path: String? = nil,
        result: String? = nil,
        error: String? = nil,
        success: Bool? = nil,
        prompt: String? = nil,
        summary: [String]? = nil,
        content: [String]? = nil
    ) {
        self.type = type
        self.id = id
        self.text = text ?? (type == "agentMessage" || type == "plan" ? "" : nil)
        self.review = review
        self.command = command
        self.cwd = cwd
        self.processID = processID
        self.source = source
        self.aggregatedOutput = aggregatedOutput
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.commandActions = commandActions
        self.status = status
        self.namespace = namespace
        self.server = server ?? (type == "mcpToolCall" ? "" : nil)
        self.tool = tool ?? (["mcpToolCall", "dynamicToolCall"].contains(type) ? "" : nil)
        self.query = query ?? (type == "webSearch" ? "" : nil)
        self.path = path ?? (type == "imageView" ? "" : nil)
        self.result = result ?? (type == "imageGeneration" ? "" : nil)
        self.error = error
        self.success = success
        self.prompt = prompt
        self.summary = summary
        self.content = content ?? (type == "userMessage" ? [] : nil)
        self.fragments = type == "hookPrompt" ? [] : nil
        self.changes = type == "fileChange" ? [] : nil
        self.arguments = ["mcpToolCall", "dynamicToolCall"].contains(type) ? "" : nil
    }

    mutating func applySchemaDefaults(for lifecycle: TestItemNotification.Lifecycle) {
        let lifecycleStatus = lifecycle == .started ? "inProgress" : "completed"
        switch type {
        case "commandExecution":
            command = command ?? ""
            cwd = cwd ?? ""
            commandActions = commandActions ?? []
            source = source ?? "agent"
            status = status ?? lifecycleStatus
        case "fileChange", "mcpToolCall", "dynamicToolCall":
            status = status ?? lifecycleStatus
        case "reasoning":
            summary = summary ?? []
            content = content ?? []
        default:
            break
        }
    }
}

private struct TestCommandAction: Encodable, Sendable {
    var type: String
    var command: String
    var name: String?
    var path: String?
    var query: String?

    init(
        type: String,
        command: String,
        name: String? = nil,
        path: String? = nil,
        query: String? = nil
    ) {
        self.type = type
        self.command = command
        self.name = name
        self.path = path
        self.query = query
    }

    static func read(command: String, name: String, path: String) -> Self {
        .init(type: "read", command: command, name: name, path: path)
    }

    static func search(command: String, query: String?, path: String?) -> Self {
        .init(type: "search", command: command, path: path, query: query)
    }
}

private struct TestDiagnosticNotification: Encodable, Sendable {
    var summary: String
    var details: String?
}

private struct TestModelReroutedNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var fromModel: String
    var toModel: String
    var reason: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case fromModel
        case toModel
        case reason
    }
}

private struct TestDiffNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var diff: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case diff
    }
}

private struct TestMessageNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String? = nil
    var message: String
    var changes: [String] = []

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case message
        case changes
    }
}

private struct TestGlobalMessageNotification: Encodable, Sendable {
    var message: String
}

private struct TestErrorNotification: Encodable, Sendable {
    var threadID: String? = nil
    var turnID: String? = nil
    var message: String
    var willRetry: Bool

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case error
        case willRetry
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(threadID, forKey: .threadID)
        try container.encodeIfPresent(turnID, forKey: .turnID)
        try container.encode(AppServerAPI.Turn.Error(message: message), forKey: .error)
        try container.encode(willRetry, forKey: .willRetry)
    }
}

private enum TransportCloseTestError: Error, Equatable, Sendable {
    case injected
}

private actor CallCounter {
    private var count = 0

    func record() -> Int {
        count += 1
        return count
    }

    func value() -> Int {
        count
    }
}
