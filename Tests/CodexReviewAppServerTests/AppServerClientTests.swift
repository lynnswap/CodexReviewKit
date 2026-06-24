import Darwin
import Foundation
import Testing
import CodexAppServerKit
import CodexAppServerKitTesting
@testable import CodexReviewAppServer
import CodexReviewKit
import CodexReviewTesting

private extension AppServerCodexReviewBackend {
    func resumeReviewRecovery(
        _ run: CodexReviewBackendModel.Review.Run,
        request: CodexReviewBackendModel.Review.Start,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws -> BackendReviewAttempt {
        let token = try await beginReviewRecovery(run, reason: reason)
        return try await resumeReviewRecovery(token, request: request)
    }

    func resumeReviewRecovery(
        _ attempt: BackendReviewAttempt,
        request: CodexReviewBackendModel.Review.Start,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws -> BackendReviewAttempt {
        try await resumeReviewRecovery(attempt.run, request: request, reason: reason)
    }

    func interruptReview(_ attempt: BackendReviewAttempt, reason: CodexReviewBackendModel.CancellationReason) async throws {
        try await interruptReview(attempt.run, reason: reason)
    }

    func beginReviewRecovery(
        _ attempt: BackendReviewAttempt,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws -> CodexReviewBackendModel.Review.RecoveryToken {
        try await beginReviewRecovery(attempt.run, reason: reason)
    }

    func cleanupReview(_ attempt: BackendReviewAttempt) async {
        await cleanupReview(attempt.run)
    }
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
        var includesDomainEvents: Bool

        mutating func next() async throws -> CodexReviewBackendModel.Review.Event? {
            while let event = try await mailbox.next() {
                if includesDomainEvents {
                    return event
                }
                if case .domainEvents = event {
                    continue
                }
                if case .suppressNextLegacyTimelineProjection = event {
                    continue
                }
                if case .suppressNextTerminalFailureLogTimelineProjection = event {
                    continue
                }
                return event
            }
            return nil
        }
    }

    var mailbox: BackendReviewEventMailbox
    var includesDomainEvents: Bool

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(mailbox: mailbox, includesDomainEvents: includesDomainEvents)
    }
}

private func eventSequence(
    _ backend: AppServerCodexReviewBackend,
    _ attempt: BackendReviewAttempt,
    includingDomainEvents: Bool = false
) async -> BackendReviewEventSequence {
    BackendReviewEventSequence(mailbox: attempt.events, includesDomainEvents: includingDomainEvents)
}

private func eventSequence(
    _ backend: AppServerCodexReviewBackend,
    _ run: CodexReviewBackendModel.Review.Run,
    includingDomainEvents: Bool = false
) async -> BackendReviewEventSequence {
    let attempt = await backend.reviewAttemptForTesting(run)
    return BackendReviewEventSequence(mailbox: attempt.events, includesDomainEvents: includingDomainEvents)
}

private func makeBackend(
    transport: FakeJSONRPCTransport,
    threadStartPermissionStrategy: AppServerAPI.Thread.Start.PermissionStrategy = .modernPermissions
) async throws -> AppServerCodexReviewBackend {
    let appServer = try await CodexAppServer.testing(
        transport: transport,
        threadStartPermissionStrategy: threadStartPermissionStrategy
    )
    return AppServerCodexReviewBackend(appServer: appServer)
}

@Suite("app-server client")
struct AppServerClientTests {
    @Test func processTransportConfigurationResolvesCodexFromProvidedPath() throws {
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
            environment: ["PATH": directory.path, "HOME": "/tmp/review-home"],
            codexHomeURL: directory.appendingPathComponent("codex-home", isDirectory: true)
        )

        #expect(configuration.executable == codex.path)
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

    @Test func processTransportConfigurationUsesExplicitExecutableWithoutPathSearch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-explicit-executable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let codex = directory.appending(path: "custom-codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "app-server" ] && [ "$2" = "--help" ]; then
          printf 'Usage: custom codex app-server --listen <URL>\\n'
        fi
        """
        try Data(script.utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        let configuration = AppServerProcessTransport.Configuration(
            executable: codex.path,
            environment: [
                "PATH": "/tmp/not-used",
                "HOME": "/tmp/review-home",
            ],
            codexHomeURL: directory.appendingPathComponent("codex-home", isDirectory: true)
        )

        #expect(configuration.executable == codex.path)
        #expect(configuration.arguments == CodexAppServerExecutable.appServerArguments())
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
            environment: ["PATH": directory.path, "HOME": "/tmp/review-home"],
            codexHomeURL: directory.appendingPathComponent("codex-home", isDirectory: true)
        )

        #expect(configuration.executable == codex.path)
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
            executable: codex.path,
            arguments: ["custom", "argument"],
            environment: ["PATH": directory.path, "HOME": "/tmp/review-home"],
            codexHomeURL: directory.appendingPathComponent("codex-home", isDirectory: true)
        )

        #expect(configuration.executable == codex.path)
        #expect(configuration.arguments == ["custom", "argument"])
        #expect(configuration.threadStartPermissionStrategy == .legacySandbox)
        #expect(FileManager.default.fileExists(atPath: probed.path) == false)
    }

    @Test func processTransportSearchesCodexAppBundleResourcesFallback() throws {
        let directories = CodexAppServerExecutable.pathSearchDirectories(
            environment: ["PATH": "/tmp/codex-bin:/usr/bin"]
        )

        #expect(directories.contains("/Applications/Codex.app/Contents/Resources"))
        #expect(directories.filter { $0 == "/usr/bin" }.count == 1)
        let appBundleIndex = try #require(directories.firstIndex(of: "/Applications/Codex.app/Contents/Resources"))
        let homebrewIndex = try #require(directories.firstIndex(of: "/opt/homebrew/bin"))
        #expect(appBundleIndex < homebrewIndex)
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

    @Test func processTransportConfigurationUsesConfiguredCodexHome() throws {
        let codexHomeURL = URL(fileURLWithPath: "/tmp/app-server-home", isDirectory: true)
        let configuration = AppServerProcessTransport.Configuration(
            environment: [
                "PATH": "/usr/bin",
                "HOME": "/tmp/review-home",
                "CODEX_SQLITE_HOME": "/tmp/main-codex-sqlite",
            ],
            codexHomeURL: codexHomeURL
        )

        #expect(configuration.codexHomeURL == codexHomeURL)
        #expect(configuration.environment["CODEX_HOME"] == "/tmp/app-server-home")
        #expect(configuration.environment["CODEX_SQLITE_HOME"] == "/tmp/app-server-home/sqlite")
    }

    @Test func processTransportConfigurationOverridesCodexHomeEnvironment() throws {
        let codexHomeURL = URL(fileURLWithPath: "/tmp/configured-codex-home", isDirectory: true)
        let configuration = AppServerProcessTransport.Configuration(
            environment: [
                "PATH": "/usr/bin",
                "HOME": "/tmp/review-home",
                "CODEX_HOME": "/tmp/custom-codex-review",
                "CODEX_SQLITE_HOME": "/tmp/main-codex-sqlite",
            ],
            codexHomeURL: codexHomeURL
        )

        #expect(configuration.codexHomeURL == codexHomeURL)
        #expect(configuration.environment["CODEX_HOME"] == "/tmp/configured-codex-home")
        #expect(configuration.environment["CODEX_SQLITE_HOME"] == "/tmp/configured-codex-home/sqlite")
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
            executable: executable.path,
            arguments: [childPIDFile.path, readyFile.path],
            environment: [
                "HOME": directory.path,
                "PATH": "/bin:/usr/bin",
            ],
            codexHomeURL: directory.appendingPathComponent("codex-home", isDirectory: true)
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

        await transport.close()

        let childExited = await waitUntil(timeout: .seconds(2)) {
            Darwin.kill(childPID, 0) != 0 && errno == ESRCH
        }
        #expect(childExited)

        let notifications = await transport.notificationStream()
        var iterator = notifications.makeAsyncIterator()
        await #expect(throws: (any Error).self) {
            _ = try await iterator.next()
        }
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
            executable: executable.path,
            arguments: [],
            environment: [
                "HOME": directory.path,
                "PATH": "/bin:/usr/bin",
            ],
            codexHomeURL: directory.appendingPathComponent("codex-home", isDirectory: true)
        ))

        let data = try await transport.send(JSONRPC.Request(
            id: 1,
            method: "test/request",
            params: Data("{}".utf8)
        ))
        await transport.close()

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["value"] as? String == "done")
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
            executable: executable.path,
            arguments: [requestFile.path, notificationFile.path],
            environment: [
                "HOME": directory.path,
                "PATH": "/bin:/usr/bin",
            ],
            codexHomeURL: directory.appendingPathComponent("codex-home", isDirectory: true)
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
        await transport.close()

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

    @Test func startupInterruptUsesEmptyTurnID() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let client = AppServerClient(transport: transport)
        let control = AppServerReviewControl(client: client)

        control.recordThreadStarted(threadID: "thread-1")
        let interruption = try await control.interrupt()
        #expect(interruption == .init(threadID: "thread-1", turnID: ""))

        let request = try #require(await transport.recordedRequests().last)
        #expect(request.method == "turn/interrupt")
        let params = try JSONDecoder().decode(AppServerAPI.Turn.Interrupt.Params.self, from: request.params)
        #expect(params.threadID == "thread-1")
        #expect(params.turnID == "")
    }

    @Test func runningInterruptUsesActualTurnID() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let client = AppServerClient(transport: transport)
        let control = AppServerReviewControl(client: client)

        control.recordReviewStarted(turnThreadID: "thread-1", turnID: "turn-1")
        let interruption = try await control.interrupt()
        #expect(interruption == .init(threadID: "thread-1", turnID: "turn-1"))

        let request = try #require(await transport.recordedRequests().last)
        let params = try JSONDecoder().decode(AppServerAPI.Turn.Interrupt.Params.self, from: request.params)
        #expect(params.turnID == "turn-1")
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
        #expect(clientInfo["name"] as? String == "CodexAppServerKit")
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
        #expect(bedrockResponse.account?.id == .init("amazon-bedrock"))
        #expect(bedrockResponse.account?.kind == .amazonBedrock)
        #expect(bedrockResponse.account?.label == "Amazon Bedrock")
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
        let backend = try await makeBackend(transport: transport)

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
        let backend = try await makeBackend(transport: transport)

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
        let backend = try await makeBackend(transport: transport)

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
        let backend = try await makeBackend(transport: transport)

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
        let backend = try await makeBackend(transport: transport)

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
        let backend = try await makeBackend(transport: transport)

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
        let backend = try await makeBackend(transport: transport)

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

    @Test func appServerBackendConsumesTypedReviewSessionStream() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "review-thread")
        await runtime.transport.waitForNotificationStreamCount(1)
        let backend = AppServerCodexReviewBackend(appServer: runtime.server)

        let attempt = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
            model: "gpt-5"
        ))

        #expect(attempt.threadID == "thread-1")
        #expect(attempt.turnID == "turn-1")
        #expect(attempt.reviewThreadID == "review-thread")
        let storedAttempt = await backend.reviewAttemptForTesting(attempt.run)
        #expect(storedAttempt.threadID == "thread-1")
        #expect(storedAttempt.turnID == "turn-1")
        #expect(storedAttempt.reviewThreadID == "review-thread")

        let requests = await runtime.transport.recordedRequests()
        #expect(requests.map(\.method) == ["initialize", "thread/start", "review/start"])
        let threadStart = try #require(requests.first { $0.method == "thread/start" })
        let threadParams = try threadStart.decodeParams(AppServerAPI.Thread.Start.Params.self)
        #expect(threadParams.cwd == "/tmp/project")
        #expect(threadParams.model == "gpt-5")
        #expect(threadParams.approvalPolicy == "never")
        #expect(threadParams.permissions == .profileID(":danger-full-access"))
        #expect(threadParams.sessionStartSource == .startup)
        #expect(threadParams.threadSource == .user)

        let reviewStart = try #require(requests.first { $0.method == "review/start" })
        let reviewParams = try reviewStart.decodeParams(AppServerAPI.Review.Start.Params.self)
        #expect(reviewParams.threadID == "thread-1")
        #expect(reviewParams.target == .baseBranch("main"))

        try await runtime.transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "review-thread",
                turnID: "turn-1",
                item: .init(
                    type: "commandExecution",
                    id: "cmd-1",
                    command: "swift test",
                    aggregatedOutput: "passed",
                    status: "completed"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TestDeltaNotification(
                threadID: "review-thread",
                turnID: "turn-1",
                itemID: "msg-1",
                delta: "Looks good."
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "review-thread",
                turn: .init(id: "turn-1", status: "completed")
            )
        )

        var iterator = await eventSequence(backend, attempt, includingDomainEvents: true).makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "review-thread", model: "gpt-5"))
        guard case .domainEvents(let commandDomainEvents, let commandSuppressionCount) = try await iterator.next() else {
            Issue.record("expected typed command domain event")
            return
        }
        #expect(commandSuppressionCount == 2)
        guard case .itemCompleted(let commandSeed) = try #require(commandDomainEvents.first) else {
            Issue.record("expected completed command seed")
            return
        }
        #expect(commandSeed.id.rawValue == "cmd-1")
        guard case .command(let command) = commandSeed.content else {
            Issue.record("expected command content")
            return
        }
        #expect(command.command == "swift test")
        #expect(command.output == "passed")

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
                commandStatus: "completed"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .commandOutput,
            text: "passed",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "completed",
                itemID: "cmd-1",
                command: "swift test",
                commandStatus: "completed"
            )
        ))
        guard case .domainEvents(let messageDomainEvents, let messageSuppressionCount) = try await iterator.next() else {
            Issue.record("expected typed message delta domain event")
            return
        }
        #expect(messageSuppressionCount == 1)
        guard case .textDelta(let itemID, _, let family, _, let delta) = try #require(messageDomainEvents.first) else {
            Issue.record("expected message text delta")
            return
        }
        #expect(itemID.rawValue == "msg-1")
        #expect(family == .message)
        #expect(delta == "Looks good.")
        #expect(try await iterator.next() == .messageDelta("Looks good.", itemID: "msg-1"))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "Looks good."))
    }

    @Test func appServerBackendInterruptUsesTypedSession() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "review-thread")
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
        await runtime.transport.waitForNotificationStreamCount(1)
        let backend = AppServerCodexReviewBackend(appServer: runtime.server)

        let attempt = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
            model: "gpt-5"
        ))
        try await backend.interruptReview(attempt, reason: .init(message: "Stop"))

        let interrupt = try #require(await runtime.transport.recordedRequests().last)
        #expect(interrupt.method == "turn/interrupt")
        let params = try interrupt.decodeParams(AppServerAPI.Turn.Interrupt.Params.self)
        #expect(params.threadID == "review-thread")
        #expect(params.turnID == "turn-1")
    }

    @Test func backendUsesLegacySandboxWhenProcessDoesNotSupportModernSessionSource() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = try await makeBackend(
            transport: transport,
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
        let backend = try await makeBackend(transport: transport)

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
        let backend = try await makeBackend(transport: transport)

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
        let backend = try await makeBackend(transport: transport)

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
        let backend = try await makeBackend(transport: transport)

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
        let backend = try await makeBackend(transport: transport)

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

    @Test func backendInterruptUsesDetachedReviewThreadBeforeStartedEvent() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "parent-thread", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-old", reviewThreadID: "review-thread"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = try await makeBackend(transport: transport)

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

    @Test func appServerUsesSingleNotificationStreamForConcurrentReviews() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-2", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-2", reviewThreadID: "thread-2"), for: "review/start")
        let backend = try await makeBackend(transport: transport)

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

    @Test func backendRecoverReviewRollsBackAndRestartsSameThread() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-2", reviewThreadID: "thread-1"), for: "review/start")
        let backend = try await makeBackend(transport: transport)
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: "gpt-5"
        )

        let recovered = try await backend.resumeReviewRecovery(
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

    @Test func backendRecoverReviewUsesDetachedReviewThreadBeforeStartedEvent() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "parent-thread", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-old", reviewThreadID: "review-thread"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-2", reviewThreadID: "review-thread"), for: "review/start")
        let backend = try await makeBackend(transport: transport)
        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))

        let recovered = try await backend.resumeReviewRecovery(
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

    @Test func backendCleanupDeletesAllRecoveryReviewThreads() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-2", reviewThreadID: "review-thread-2"), for: "review/start")
        let backend = try await makeBackend(transport: transport)
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )

        let recovered = try await backend.resumeReviewRecovery(
            run,
            request: .init(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                model: "gpt-5"
            ),
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )
        await backend.cleanupReview(recovered)

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

    @Test func backendCleansThreadWhenReviewStartFailsAfterThreadStart() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1"), for: "thread/start")
        await transport.enqueueFailure(.responseError(code: -32602, message: "invalid target"), for: "review/start")
        let backend = try await makeBackend(transport: transport)

        await #expect(throws: JSONRPC.Error.responseError(code: -32602, message: "invalid target")) {
            try await backend.startReview(.init(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            ))
        }

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
) -> CodexModel {
    .init(
        id: model,
        model: model,
        displayName: model,
        hidden: false,
        supportedReasoningEfforts: [.init(reasoningEffort: .medium, description: "Balanced")],
        defaultReasoningEffort: .medium,
        supportedServiceTiers: ["fast"],
        isDefault: isDefault
    )
}

private struct TestTurnNotification: Encodable, Sendable {
    var threadID: String
    var turn: AppServerAPI.Turn.Payload
    var reviewThreadID: String? = nil
    var result: String? = nil

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
        case reviewThreadID = "reviewThreadId"
        case result
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
    var summaryIndex: Int? = nil
    var contentIndex: Int? = nil

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case delta
        case summaryIndex
        case contentIndex
    }
}

private struct TestBase64OutputNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String?
    var processID: String?
    var processHandle: String?
    var deltaBase64: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case processID = "processId"
        case processHandle
        case deltaBase64
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
    var threadID: String
    var turnID: String
    var itemID: String?
    var item: TestItem
    var startedAtMs: Int64?
    var completedAtMs: Int64?

    init(
        threadID: String,
        turnID: String,
        itemID: String? = nil,
        item: TestItem,
        startedAtMs: Int64? = nil,
        completedAtMs: Int64? = nil
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.item = item
        self.startedAtMs = startedAtMs
        self.completedAtMs = completedAtMs
    }

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case item
        case startedAtMs
        case completedAtMs
    }
}

private struct TestCommandExecutionItemNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var item: Item
    var startedAtMs: Int64?
    var completedAtMs: Int64?

    struct Item: Encodable, Sendable {
        var type = "commandExecution"
        var id: String
        var command: String
        var processID: String?
        var exitCode: Int?

        enum CodingKeys: String, CodingKey {
            case type
            case id
            case command
            case processID = "processId"
            case exitCode
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
        self.text = text
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
        self.server = server
        self.tool = tool
        self.query = query
        self.path = path
        self.result = result
        self.error = error
        self.success = success
        self.prompt = prompt
        self.summary = summary
        self.content = content
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

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case message
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
        case message
        case willRetry
    }
}
