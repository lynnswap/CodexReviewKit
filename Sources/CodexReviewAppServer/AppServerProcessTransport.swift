import Darwin
import Foundation
import OSLog

private let logger = Logger(subsystem: "CodexReviewKit", category: "app-server-transport")

package actor AppServerProcessTransport: JSONRPC.Transport {
    private enum ReaderTask: Equatable {
        case stdout
        case stderr
    }

    package struct Configuration: Sendable {
        package var executableURL: URL
        package var arguments: [String]
        package var environment: [String: String]
        package var codexHomeURL: URL
        package var threadStartPermissionStrategy: AppServerAPI.Thread.Start.PermissionStrategy

        package init(
            executableURL: URL,
            arguments: [String]? = nil,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            codexHomeURL: URL? = nil
        ) {
            let resolvedCodexHomeURL = codexHomeURL ?? AppServerCodexHome.url(environment: environment)
            let supportsSessionSource: Bool
            if let arguments {
                supportsSessionSource = arguments.contains("--session-source")
            } else {
                supportsSessionSource = CodexAppServerExecutable.supportsAppServerSessionSource(
                    executableURL: executableURL,
                    environment: environment
                )
            }
            self.executableURL = executableURL
            self.arguments = arguments ?? CodexAppServerExecutable.appServerArguments(
                supportsSessionSource: supportsSessionSource
            )
            self.environment = AppServerCodexHome.environment(
                environment,
                codexHomeURL: resolvedCodexHomeURL
            )
            self.codexHomeURL = resolvedCodexHomeURL
            self.threadStartPermissionStrategy = supportsSessionSource
                ? .modernPermissions
                : .legacySandbox
        }
    }

    private struct PendingResponse {
        var continuation: CheckedContinuation<Data, Error>
    }

    private let process: AppServerSpawnedProcess
    private let stdin: Pipe
    private let stdout: Pipe
    private let stderr: Pipe
    private let stdoutEvents: AppServerPipeReadEventSource
    private let stderrEvents: AppServerPipeReadEventSource
    private let closeAdmissionForTesting: (@Sendable () async -> Void)?
    private let closeCompletionForTesting: (@Sendable () async throws -> Void)?
    private let closedRequestAdmissionForTesting: (@Sendable () async -> Void)?
    private var framer = JSONRPC.Framer()
    private var pending: [Int: PendingResponse] = [:]
    private var notificationContinuations: [UUID: AsyncThrowingStream<JSONRPC.Notification, Error>.Continuation] = [:]
    private var stderrLogFilter = AppServerStderrLogFilter()
    private var stdoutReaderTask: Task<Void, Never>? = nil
    private var stderrReaderTask: Task<Void, Never>? = nil
    private var closed = false
    private var closeTask: Task<Void, any Error>?
    private var terminalError: JSONRPC.Error?

    package init(
        configuration: Configuration,
        closeAdmissionForTesting: (@Sendable () async -> Void)? = nil,
        closeCompletionForTesting: (@Sendable () async throws -> Void)? = nil,
        closedRequestAdmissionForTesting: (@Sendable () async -> Void)? = nil
    ) throws {
        let executableURL = configuration.executableURL
        let fileManager = FileManager.default
        guard executableURL.isFileURL,
              executableURL.path.hasPrefix("/"),
              fileManager.isExecutableFile(atPath: executableURL.path),
              let attributes = try? fileManager.attributesOfItem(atPath: executableURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular
        else {
            throw AppServerProcessTransportError.invalidExecutable(path: executableURL.path)
        }
        try AppServerCodexHome.ensureScaffold(at: configuration.codexHomeURL)
        let launch = try AppServerSpawnedProcess.launch(
            executableURL: executableURL,
            arguments: configuration.arguments,
            environment: configuration.environment
        )
        let process = launch.process
        let stdin = launch.stdin
        let stdout = launch.stdout
        let stderr = launch.stderr
        self.process = process
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
        let stdoutEvents = AppServerPipeReadEventSource(
            fileHandle: stdout.fileHandleForReading,
            label: "com.lynnpd.CodexReviewKit.app-server.stdout"
        )
        let stderrEvents = AppServerPipeReadEventSource(
            fileHandle: stderr.fileHandleForReading,
            label: "com.lynnpd.CodexReviewKit.app-server.stderr"
        )
        self.stdoutEvents = stdoutEvents
        self.stderrEvents = stderrEvents
        self.closeAdmissionForTesting = closeAdmissionForTesting
        self.closeCompletionForTesting = closeCompletionForTesting
        self.closedRequestAdmissionForTesting = closedRequestAdmissionForTesting
        logger.info("Launching codex app-server: \(executableURL.path, privacy: .public) \(configuration.arguments.joined(separator: " "), privacy: .public)")
        logger.info("Using codex app-server home: \(configuration.codexHomeURL.path, privacy: .public)")
        logger.info("codex app-server launched with pid \(process.processIdentifier, privacy: .public)")
        stdoutEvents.start()
        stderrEvents.start()
    }

    package func send(_ request: JSONRPC.Request) async throws -> Data {
        ensureReaderTasksStarted()
        try await throwIfClosed()
        let payload = try makeRequestPayload(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[request.id] = .init(continuation: continuation)
                do {
                    try stdin.fileHandleForWriting.write(contentsOf: payload)
                } catch {
                    pending.removeValue(forKey: request.id)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task {
                await self.cancelPendingResponse(id: request.id)
            }
        }
    }

    package func notify(_ notification: JSONRPC.Notification) async throws {
        ensureReaderTasksStarted()
        try await throwIfClosed()
        let payload = try makeNotificationPayload(notification)
        try stdin.fileHandleForWriting.write(contentsOf: payload)
    }

    package func notificationStream() async -> AsyncThrowingStream<JSONRPC.Notification, Error> {
        ensureReaderTasksStarted()
        if let closeTask {
            _ = await closeTask.result
        }
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            if closed {
                continuation.finish(throwing: terminalError ?? JSONRPC.Error.closed)
                return
            }
            let id = UUID()
            notificationContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeNotificationContinuation(id: id) }
            }
        }
    }

    package func close() async throws {
        try await closeTransport(terminateProcess: true, readerTask: nil)
    }

    private func closeTransport(
        terminateProcess: Bool,
        readerTask: ReaderTask?
    ) async throws {
        try await closeTransport(
            terminateProcess: terminateProcess,
            error: JSONRPC.Error.transportTerminated(.ownerClose),
            readerTask: readerTask
        )
    }

    private func closeTransport(
        terminateProcess: Bool,
        error: JSONRPC.Error,
        readerTask: ReaderTask?
    ) async throws {
        let task: Task<Void, any Error>
        if let closeTask {
            task = closeTask
        } else {
            closed = true
            terminalError = error
            stdoutEvents.cancel()
            stderrEvents.cancel()
            try? stdin.fileHandleForWriting.close()
            let newTask = Task<Void, any Error> {
                try await self.performCloseTransport(
                    terminateProcess: terminateProcess,
                    error: error
                )
            }
            closeTask = newTask
            task = newTask
        }

        await closeAdmissionForTesting?()
        let result = await task.result
        await waitForReaderTasks(excluding: readerTask)
        try result.get()
    }

    private func performCloseTransport(
        terminateProcess: Bool,
        error: JSONRPC.Error
    ) async throws {
        var processCloseError: (any Error)?
        if terminateProcess {
            logger.info("Terminating codex app-server pid \(self.process.processIdentifier, privacy: .public)")
            do {
                try await process.terminateAndWait()
                try await closeCompletionForTesting?()
            } catch {
                processCloseError = error
            }
        }
        if let processCloseError {
            let typedError = JSONRPC.Error.transportTerminated(.processFailure(
                processCloseError.localizedDescription
            ))
            terminalError = typedError
            finishAll(throwing: typedError)
        } else {
            terminalError = error
            finishAll(throwing: error)
        }
        if let processCloseError {
            throw processCloseError
        }
    }

    private func receiveStdout(_ event: AppServerPipeReadEvent) async {
        switch event {
        case .data(let data):
            await receive(data)
        case .end:
            await finishReceiving()
        }
    }

    private func receive(_ data: Data) async {
        let messages = framer.append(data)
        for message in messages {
            do {
                try processMessage(message)
            } catch {
                logger.error("Closing codex app-server after invalid JSON-RPC framing: \(error.localizedDescription, privacy: .public)")
                do {
                    try await closeTransport(
                        terminateProcess: true,
                        error: error as? JSONRPC.Error
                            ?? .invalidMessage(error.localizedDescription),
                        readerTask: .stdout
                    )
                } catch {
                    logger.error("Failed to close codex app-server process: \(error.localizedDescription, privacy: .public)")
                }
                return
            }
        }
    }

    private func receiveStderr(_ event: AppServerPipeReadEvent) {
        let events: [AppServerStderrLogFilter.Event]
        switch event {
        case .data(let data):
            events = stderrLogFilter.append(data)
        case .end:
            events = stderrLogFilter.finish()
        }
        for event in events {
            switch event.level {
            case .error:
                logger.error("codex app-server stderr: \(event.message, privacy: .public)")
            case .warning:
                logger.warning("codex app-server stderr: \(event.message, privacy: .public)")
            }
        }
    }

    private func finishReceiving() async {
        guard closed == false else {
            return
        }
        logger.info("codex app-server stdout reached EOF")
        for message in framer.finish() {
            do {
                try processMessage(message)
            } catch {
                logger.error("Closing codex app-server after invalid trailing JSON-RPC framing: \(error.localizedDescription, privacy: .public)")
                do {
                    try await closeTransport(
                        terminateProcess: true,
                        error: error as? JSONRPC.Error
                            ?? .invalidMessage(error.localizedDescription),
                        readerTask: .stdout
                    )
                } catch {
                    logger.error("Failed to close codex app-server process: \(error.localizedDescription, privacy: .public)")
                }
                return
            }
        }
        do {
            try await closeTransport(
                terminateProcess: true,
                error: .transportTerminated(.processExit(
                    "Codex app-server process exited after stdout reached EOF."
                )),
                readerTask: .stdout
            )
        } catch {
            logger.error("Failed to close codex app-server process after stdout EOF: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func processMessage(_ data: Data) throws {
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw JSONRPC.Error.invalidMessage("app-server emitted invalid JSON")
        }
        guard let object = decoded as? [String: Any] else {
            throw JSONRPC.Error.invalidMessage("app-server message must be a JSON object")
        }
        if let method = object["method"] as? String {
            if object.keys.contains("id") {
                processServerRequest(method: method, object: object)
                return
            }
            try processNotification(method: method, object: object)
        } else if let id = object["id"] as? Int {
            processResponse(id: id, object: object)
        } else {
            throw JSONRPC.Error.invalidMessage("app-server message has neither a method nor an integer response id")
        }
    }

    private func processServerRequest(method: String, object: [String: Any]) {
        do {
            let response = try Self.unsupportedServerRequestPayload(
                id: object["id"] ?? NSNull(),
                method: method
            )
            try stdin.fileHandleForWriting.write(contentsOf: response)
        } catch {
            logger.error("Failed to reject unsupported app-server request \(method, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func processResponse(id: Int, object: [String: Any]) {
        guard let pendingResponse = pending.removeValue(forKey: id) else {
            return
        }
        if let errorObject = object["error"] as? [String: Any] {
            let code = errorObject["code"] as? Int ?? -1
            let message = errorObject["message"] as? String ?? "JSON-RPC request failed."
            pendingResponse.continuation.resume(throwing: JSONRPC.Error.responseError(
                code: code,
                message: message
            ))
            return
        }
        let result = object["result"] ?? [:]
        do {
            let data = try Self.responsePayloadData(from: result)
            pendingResponse.continuation.resume(returning: data)
        } catch {
            pendingResponse.continuation.resume(throwing: error)
        }
    }

    package static func responsePayloadData(from result: Any) throws -> Data {
        if result is NSNull {
            return Data("{}".utf8)
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
    }

    package static func unsupportedServerRequestPayload(id: Any, method: String) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "error": [
                "code": -32601,
                "message": "Unsupported app-server request: \(method)",
            ],
        ] as [String: Any])
        data.append(0x0A)
        return data
    }

    private func processNotification(method: String, object: [String: Any]) throws {
        let params = object["params"] ?? [:]
        let data = try JSONSerialization.data(
            withJSONObject: params,
            options: [.fragmentsAllowed]
        )
        let notification = JSONRPC.Notification(method: method, params: data)
        for continuation in notificationContinuations.values {
            continuation.yield(notification)
        }
    }

    private func cancelPendingResponse(id: Int) {
        pending.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    private func removeNotificationContinuation(id: UUID) {
        notificationContinuations.removeValue(forKey: id)
    }

    private func readerTaskFinished(_ task: ReaderTask) {
        switch task {
        case .stdout:
            stdoutReaderTask = nil
        case .stderr:
            stderrReaderTask = nil
        }
    }

    private func ensureReaderTasksStarted() {
        guard closed == false,
              stdoutReaderTask == nil,
              stderrReaderTask == nil
        else {
            return
        }
        let stdoutEvents = stdoutEvents.events
        let stderrEvents = stderrEvents.events
        stdoutReaderTask = Task { [weak self, stdoutEvents] in
            for await event in stdoutEvents {
                await self?.receiveStdout(event)
            }
            await self?.readerTaskFinished(.stdout)
        }
        stderrReaderTask = Task { [weak self, stderrEvents] in
            for await event in stderrEvents {
                await self?.receiveStderr(event)
            }
            await self?.readerTaskFinished(.stderr)
        }
    }

    private func waitForReaderTasks(excluding excluded: ReaderTask?) async {
        let stdoutTask = stdoutReaderTask
        let stderrTask = stderrReaderTask
        if excluded != .stdout {
            stdoutTask?.cancel()
            await stdoutTask?.value
        }
        if excluded != .stderr {
            stderrTask?.cancel()
            await stderrTask?.value
        }
    }

    private func finishAll(throwing error: Error) {
        let responses = pending.values
        pending.removeAll()
        for response in responses {
            response.continuation.resume(throwing: error)
        }
        let continuations = notificationContinuations.values
        notificationContinuations.removeAll()
        for continuation in continuations {
            continuation.finish(throwing: error)
        }
    }

    private func throwIfClosed() async throws {
        if let closeTask {
            await closedRequestAdmissionForTesting?()
            _ = await closeTask.result
        }
        if closed {
            throw terminalError ?? JSONRPC.Error.closed
        }
    }
}

private struct AppServerProcessLaunch {
    var process: AppServerSpawnedProcess
    var stdin: Pipe
    var stdout: Pipe
    var stderr: Pipe
}

private enum AppServerPipeReadEvent: Sendable {
    case data(Data)
    case end
}

package struct AppServerStderrLogFilter: Sendable {
    package struct Event: Equatable, Sendable {
        package enum Level: Equatable, Sendable {
            case error
            case warning
        }

        package var level: Level
        package var message: String
    }

    private var partialLine = ""
    private var isAwaitingToolErrorOutput = false
    private var suppressingCommandOutput = false
    private var suppressedCommandOutputLineCount = 0

    package init() {}

    package mutating func append(_ data: Data) -> [Event] {
        guard let text = String(data: data, encoding: .utf8) else {
            return [.init(
                level: .error,
                message: "emitted \(data.count) undecodable bytes"
            )]
        }
        return append(text)
    }

    package mutating func append(_ text: String) -> [Event] {
        guard text.isEmpty == false else {
            return []
        }

        let bufferedText = partialLine + text
        partialLine = ""

        var events: [Event] = []
        var lineStart = bufferedText.startIndex
        var index = bufferedText.startIndex
        while index < bufferedText.endIndex {
            if bufferedText[index].isNewline {
                let line = String(bufferedText[lineStart..<index])
                events.append(contentsOf: processLine(line))
                let nextIndex = bufferedText.index(after: index)
                if bufferedText[index] == "\r",
                   nextIndex < bufferedText.endIndex,
                   bufferedText[nextIndex] == "\n" {
                    lineStart = bufferedText.index(after: nextIndex)
                    index = lineStart
                } else {
                    lineStart = nextIndex
                    index = nextIndex
                }
            } else {
                index = bufferedText.index(after: index)
            }
        }

        if lineStart < bufferedText.endIndex {
            partialLine = String(bufferedText[lineStart...])
        }
        return events
    }

    package mutating func finish() -> [Event] {
        var events: [Event] = []
        if partialLine.isEmpty == false {
            events.append(contentsOf: processLine(partialLine))
            partialLine = ""
        }
        events.append(contentsOf: flushSuppressedCommandOutput())
        return events
    }

    private mutating func processLine(_ rawLine: String) -> [Event] {
        let line = Self.stripANSIEscapeSequences(rawLine)
        if suppressingCommandOutput {
            if Self.isStructuredLogLine(line) {
                var events = flushSuppressedCommandOutput()
                events.append(contentsOf: processLine(line))
                return events
            }
            if Self.isTimeoutSummaryLine(line) {
                return [.init(level: .warning, message: line)]
            }
            suppressedCommandOutputLineCount += 1
            return []
        }

        guard line.isEmpty == false else {
            return []
        }
        if isAwaitingToolErrorOutput, Self.isOutputStartLine(line) {
            isAwaitingToolErrorOutput = false
            suppressingCommandOutput = true
            suppressedCommandOutputLineCount = 0
            return [.init(level: .warning, message: "command output omitted after tool error")]
        }
        isAwaitingToolErrorOutput = Self.canBeFollowedByCommandOutput(line)
        return [.init(level: .error, message: line)]
    }

    private mutating func flushSuppressedCommandOutput() -> [Event] {
        guard suppressingCommandOutput else {
            return []
        }
        suppressingCommandOutput = false
        isAwaitingToolErrorOutput = false
        let lineCount = suppressedCommandOutputLineCount
        suppressedCommandOutputLineCount = 0
        guard lineCount > 0 else {
            return []
        }
        return [.init(level: .warning, message: "suppressed \(lineCount) command-output line(s)")]
    }

    private static func stripANSIEscapeSequences(_ line: String) -> String {
        line.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
    }

    private static func isOutputStartLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "Output:" || trimmed.hasSuffix(" Output:")
    }

    private static func isStructuredLogLine(_ line: String) -> Bool {
        line.range(
            of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\s+(?:ERROR|WARN|INFO|DEBUG|TRACE)\s+"#,
            options: .regularExpression
        ) != nil
    }

    private static func isTimeoutSummaryLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("command timed out after ") ||
            trimmed.hasPrefix("Wall time: ") ||
            trimmed.hasPrefix("Exit code: ")
    }

    private static func canBeFollowedByCommandOutput(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("codex_core::tools::router: error=") ||
            trimmed.hasPrefix("Wall time: ") ||
            trimmed.hasPrefix("Exit code: ")
    }
}

private final class AppServerPipeReadEventSource: @unchecked Sendable {
    let events: AsyncStream<AppServerPipeReadEvent>

    private let fileHandle: FileHandle
    private let queue: DispatchQueue
    private let continuationLock = NSLock()
    private var continuation: AsyncStream<AppServerPipeReadEvent>.Continuation?

    init(fileHandle: FileHandle, label: String) {
        self.fileHandle = fileHandle
        self.queue = DispatchQueue(label: label)
        var continuation: AsyncStream<AppServerPipeReadEvent>.Continuation?
        self.events = AsyncStream(bufferingPolicy: .unbounded) { streamContinuation in
            continuation = streamContinuation
        }
        self.continuation = continuation
    }

    func start() {
        fileHandle.readabilityHandler = { [weak self] handle in
            self?.queue.async { [weak self] in
                guard let self else {
                    return
                }
                let data = handle.availableData
                if data.isEmpty {
                    finish(with: .end)
                    return
                }
                yield(.data(data))
            }
        }
    }

    func cancel() {
        fileHandle.readabilityHandler = nil
        finish()
    }

    private func yield(_ event: AppServerPipeReadEvent) {
        continuationLock.lock()
        let continuation = continuation
        continuationLock.unlock()
        continuation?.yield(event)
    }

    private func finish(with finalEvent: AppServerPipeReadEvent? = nil) {
        continuationLock.lock()
        let continuation = continuation
        self.continuation = nil
        continuationLock.unlock()
        if let finalEvent {
            continuation?.yield(finalEvent)
        }
        continuation?.finish()
    }
}

private final class AppServerSpawnedProcess: @unchecked Sendable {
    private struct ProcessIdentity: Hashable {
        var processIdentifier: pid_t
        var startedAtSeconds: UInt64
        var startedAtMicroseconds: UInt64
    }

    private struct ProcessSnapshot {
        var identity: ProcessIdentity
        var parentProcessIdentifier: pid_t
        var processGroupIdentifier: pid_t
        var status: UInt32

        var isLive: Bool {
            // A non-child zombie is no longer executing and can only be reaped by its new parent.
            status != UInt32(SZOMB)
        }
    }

    let processIdentifier: pid_t

    private let processGroupID: pid_t
    private let stateLock = NSLock()
    private var didReap = false

    private init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
        self.processGroupID = processIdentifier
    }

    static func launch(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> AppServerProcessLaunch {
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&fileActions))
        try check(posix_spawnattr_init(&attributes))
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }

        try check(posix_spawn_file_actions_adddup2(
            &fileActions,
            stdin.fileHandleForReading.fileDescriptor,
            STDIN_FILENO
        ))
        try check(posix_spawn_file_actions_adddup2(
            &fileActions,
            stdout.fileHandleForWriting.fileDescriptor,
            STDOUT_FILENO
        ))
        try check(posix_spawn_file_actions_adddup2(
            &fileActions,
            stderr.fileHandleForWriting.fileDescriptor,
            STDERR_FILENO
        ))
        for fileDescriptor in [
            stdin.fileHandleForReading.fileDescriptor,
            stdin.fileHandleForWriting.fileDescriptor,
            stdout.fileHandleForReading.fileDescriptor,
            stdout.fileHandleForWriting.fileDescriptor,
            stderr.fileHandleForReading.fileDescriptor,
            stderr.fileHandleForWriting.fileDescriptor,
        ] {
            try check(posix_spawn_file_actions_addclose(&fileActions, fileDescriptor))
        }
        // posix_spawn preserves ignored dispositions and the caller's signal mask. The
        // transport owns SIGTERM delivery, so its child must always receive that signal.
        var defaultSignals = sigset_t()
        try checkErrno(sigemptyset(&defaultSignals))
        try checkErrno(sigaddset(&defaultSignals, SIGTERM))
        try check(posix_spawnattr_setsigdefault(&attributes, &defaultSignals))

        var signalMask = sigset_t()
        try checkErrno(sigemptyset(&signalMask))
        try check(posix_spawnattr_setsigmask(&attributes, &signalMask))

        let spawnFlags = POSIX_SPAWN_SETPGROUP
            | POSIX_SPAWN_SETSIGDEF
            | POSIX_SPAWN_SETSIGMASK
        try check(posix_spawnattr_setflags(&attributes, Int16(spawnFlags)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))

        let executablePath = executableURL.path
        let argv = [executablePath] + arguments
        let envp = environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }

        var processIdentifier = pid_t()
        try executablePath.withCString { executablePointer in
            try withCStringArray(argv) { argvPointers in
                try withCStringArray(envp) { envPointers in
                    try check(posix_spawn(
                        &processIdentifier,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        argvPointers,
                        envPointers
                    ))
                }
            }
        }

        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        return .init(
            process: .init(processIdentifier: processIdentifier),
            stdin: stdin,
            stdout: stdout,
            stderr: stderr
        )
    }

    func terminateAndWait(
        graceDuration: Duration = .seconds(2),
        killDuration: Duration = .seconds(1)
    ) async throws {
        let processIdentity = Self.processSnapshot(processIdentifier)?.identity
        let trackedProcesses = descendantProcesses()
        guard isFullyTerminated(trackedProcesses: trackedProcesses) == false else {
            return
        }
        signalProcessTree(
            SIGTERM,
            processIdentity: processIdentity,
            trackedProcesses: trackedProcesses
        )
        guard await waitUntilExit(timeout: graceDuration, trackedProcesses: trackedProcesses) == false else {
            return
        }
        signalProcessTree(
            SIGKILL,
            processIdentity: processIdentity,
            trackedProcesses: trackedProcesses
        )
        guard await waitUntilExit(timeout: killDuration, trackedProcesses: trackedProcesses) else {
            throw AppServerProcessTransportError.processDidNotTerminate(
                processIdentifier,
                liveProcessIdentifiers: liveProcessIdentifiers(trackedProcesses: trackedProcesses)
            )
        }
    }

    private func signalProcessTree(
        _ signal: Int32,
        processIdentity: ProcessIdentity?,
        trackedProcesses: Set<ProcessIdentity>
    ) {
        if Darwin.kill(-processGroupID, signal) == 0 {
            for process in trackedProcesses where Self.processIsLive(process) {
                _ = Darwin.kill(process.processIdentifier, signal)
            }
            return
        }
        for process in trackedProcesses where Self.processIsLive(process) {
            _ = Darwin.kill(process.processIdentifier, signal)
        }
        if let processIdentity, Self.processIsLive(processIdentity) {
            _ = Darwin.kill(processIdentifier, signal)
        }
    }

    private func waitUntilExit(timeout: Duration, trackedProcesses: Set<ProcessIdentity>) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while isFullyTerminated(trackedProcesses: trackedProcesses) == false {
            if clock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    private func isFullyTerminated(trackedProcesses: Set<ProcessIdentity>) -> Bool {
        let processHasExited = directProcessHasExited()
        return liveProcessIdentifiersInGroup(
            excludingDirectProcess: processHasExited
        )?.isEmpty == true
            && trackedProcesses.allSatisfy(Self.processHasTerminated)
            && processHasExited
            && reapIfExited()
    }

    private func liveProcessIdentifiers(trackedProcesses: Set<ProcessIdentity>) -> [pid_t] {
        var processIdentifiers = liveProcessIdentifiersInGroup(
            excludingDirectProcess: directProcessHasExited()
        ) ?? [processIdentifier]
        processIdentifiers.formUnion(
            trackedProcesses.lazy
                .filter { Self.processHasTerminated($0) == false }
                .map(\.processIdentifier)
        )
        return processIdentifiers.sorted()
    }

    private func liveProcessIdentifiersInGroup(
        excludingDirectProcess: Bool
    ) -> Set<pid_t>? {
        guard let processIdentifiers = Self.processIdentifiers(
            listType: UInt32(PROC_PGRP_ONLY),
            typeInfo: UInt32(processGroupID)
        ) else {
            return nil
        }
        if processIdentifiers.isEmpty {
            return []
        }
        return Set(processIdentifiers.filter { processIdentifier in
            if excludingDirectProcess, processIdentifier == self.processIdentifier {
                return false
            }
            guard let snapshot = Self.processSnapshot(processIdentifier) else {
                if Darwin.kill(processIdentifier, 0) == 0 {
                    return true
                }
                return errno != ESRCH
            }
            return snapshot.processGroupIdentifier == processGroupID && snapshot.isLive
        })
    }

    private func directProcessHasExited() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if didReap {
            return true
        }
        var info = siginfo_t()
        let result = waitid(
            P_PID,
            id_t(processIdentifier),
            &info,
            WEXITED | WNOHANG | WNOWAIT
        )
        if result == 0 {
            return info.si_pid == processIdentifier
        }
        return errno == ECHILD
    }

    private static func processHasTerminated(_ identity: ProcessIdentity) -> Bool {
        guard let snapshot = processSnapshot(identity.processIdentifier) else {
            if Darwin.kill(identity.processIdentifier, 0) == 0 {
                return false
            }
            return errno == ESRCH
        }
        guard snapshot.identity == identity else {
            return true
        }
        return snapshot.isLive == false
    }

    private static func processIsLive(_ identity: ProcessIdentity) -> Bool {
        guard let snapshot = processSnapshot(identity.processIdentifier) else {
            return false
        }
        return snapshot.identity == identity && snapshot.isLive
    }

    private func descendantProcesses() -> Set<ProcessIdentity> {
        let snapshots = Self.processSnapshots()
        var descendants = Set<ProcessIdentity>()
        var stack = [processIdentifier]
        while let parent = stack.popLast() {
            for snapshot in snapshots where snapshot.parentProcessIdentifier == parent {
                if descendants.insert(snapshot.identity).inserted {
                    stack.append(snapshot.identity.processIdentifier)
                }
            }
        }
        return descendants
    }

    private static func processSnapshots() -> [ProcessSnapshot] {
        guard let processIdentifiers = processIdentifiers(
            listType: UInt32(PROC_ALL_PIDS),
            typeInfo: 0
        ) else {
            return []
        }
        return processIdentifiers.compactMap(processSnapshot)
    }

    private static func processIdentifiers(listType: UInt32, typeInfo: UInt32) -> [pid_t]? {
        let bytesNeeded = proc_listpids(listType, typeInfo, nil, 0)
        guard bytesNeeded >= 0 else {
            return nil
        }
        guard bytesNeeded > 0 else {
            return []
        }
        let processIDSize = MemoryLayout<pid_t>.stride
        var processIDs = [pid_t](
            repeating: 0,
            count: Int(bytesNeeded) / processIDSize + 32
        )
        let bytesWritten = processIDs.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(
                listType,
                typeInfo,
                buffer.baseAddress,
                Int32(buffer.count * processIDSize)
            )
        }
        guard bytesWritten >= 0 else {
            return nil
        }
        guard bytesWritten > 0 else {
            return []
        }
        let count = min(Int(bytesWritten) / processIDSize, processIDs.count)
        return Array(processIDs.prefix(count).filter { $0 > 0 })
    }

    private static func processSnapshot(_ processIdentifier: pid_t) -> ProcessSnapshot? {
        var info = proc_bsdinfo()
        let infoSize = MemoryLayout<proc_bsdinfo>.stride
        let result = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(infoSize)
        )
        guard result == Int32(infoSize) else {
            return nil
        }
        return ProcessSnapshot(
            identity: .init(
                processIdentifier: processIdentifier,
                startedAtSeconds: info.pbi_start_tvsec,
                startedAtMicroseconds: info.pbi_start_tvusec
            ),
            parentProcessIdentifier: pid_t(info.pbi_ppid),
            processGroupIdentifier: pid_t(info.pbi_pgid),
            status: info.pbi_status
        )
    }

    private func reapIfExited() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if didReap {
            return true
        }
        var status: Int32 = 0
        let result = waitpid(processIdentifier, &status, WNOHANG)
        if result == processIdentifier {
            didReap = true
            return true
        }
        if result == -1, errno == ECHILD {
            didReap = true
            return true
        }
        return false
    }

    private static func check(_ result: Int32) throws {
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL)
        }
    }

    private static func checkErrno(_ result: Int32) throws {
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
    }

    private static func withCStringArray<R>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) throws -> R
    ) throws -> R {
        let cStrings = try strings.map { string -> UnsafeMutablePointer<CChar> in
            guard let pointer = strdup(string) else {
                throw POSIXError(.ENOMEM)
            }
            return pointer
        }
        defer {
            for pointer in cStrings {
                free(pointer)
            }
        }
        var pointers = cStrings.map(Optional.some)
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress)
        }
    }
}

private enum AppServerProcessTransportError: LocalizedError {
    case invalidExecutable(path: String)
    case processDidNotTerminate(pid_t, liveProcessIdentifiers: [pid_t])

    var errorDescription: String? {
        switch self {
        case .invalidExecutable(let path):
            return "Resolved Codex executable is not an executable regular file: \(path)"
        case .processDidNotTerminate(let processIdentifier, let liveProcessIdentifiers):
            return "Codex app-server process \(processIdentifier) did not terminate after SIGKILL; live process IDs: \(liveProcessIdentifiers)."
        }
    }
}

package enum AppServerCodexHome {
    package static func url(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryForCurrentUser: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           codexHome.isEmpty == false
        {
            return URL(fileURLWithPath: codexHome, isDirectory: true)
        }
        if let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           home.isEmpty == false
        {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".codex_review", isDirectory: true)
        }
        return homeDirectoryForCurrentUser
            .appendingPathComponent(".codex_review", isDirectory: true)
    }

    package static func environment(
        _ environment: [String: String],
        codexHomeURL: URL
    ) -> [String: String] {
        var effectiveEnvironment = environment
        effectiveEnvironment["CODEX_HOME"] = codexHomeURL.path
        effectiveEnvironment["CODEX_SQLITE_HOME"] = sqliteHomeURL(for: codexHomeURL).path
        return effectiveEnvironment
    }

    package static func sqliteHomeURL(for codexHomeURL: URL) -> URL {
        codexHomeURL.appendingPathComponent("sqlite", isDirectory: true)
    }

    package static func ensureScaffold(at codexHomeURL: URL) throws {
        try FileManager.default.createDirectory(
            at: codexHomeURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sqliteHomeURL(for: codexHomeURL),
            withIntermediateDirectories: true
        )
        try createEmptyFileIfMissing(at: codexHomeURL.appendingPathComponent("config.toml"))
        try createEmptyFileIfMissing(at: codexHomeURL.appendingPathComponent("AGENTS.md"))
    }

    private static func createEmptyFileIfMissing(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) == false else {
            return
        }
        try Data().write(to: url)
    }
}

package enum CodexAppServerExecutable {
    package static let fileBackedAuthConfiguration = #"cli_auth_credentials_store="file""#

    package static func appServerArguments(supportsSessionSource: Bool = false) -> [String] {
        var arguments = [
            "-c", fileBackedAuthConfiguration,
            "app-server",
            "--listen", "stdio://",
        ]
        if supportsSessionSource {
            arguments.append(contentsOf: ["--session-source", "app-server"])
        }
        return arguments
    }

    package static func supportsAppServerSessionSource(
        executableURL: URL,
        environment: [String: String]
    ) -> Bool {
        guard executableURL.isFileURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path)
        else {
            return false
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--help"]
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return false
        }

        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard process.isRunning == false else {
            process.terminate()
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let help = String(decoding: data, as: UTF8.self)
        // Deprecated compatibility: installed Codex builds can reject this newer app-server flag.
        // Remove the probe once the packaged Codex app-server consistently accepts --session-source.
        return help.contains("--session-source")
    }

}

private func makeRequestPayload(_ request: JSONRPC.Request) throws -> Data {
    let params = try JSONSerialization.jsonObject(with: request.params)
    let object: [String: Any] = [
        "id": request.id,
        "method": request.method,
        "params": params,
    ]
    var data = try JSONSerialization.data(withJSONObject: object)
    data.append(0x0A)
    return data
}

private func makeNotificationPayload(_ notification: JSONRPC.Notification) throws -> Data {
    let params = try JSONSerialization.jsonObject(with: notification.params)
    let object: [String: Any] = [
        "method": notification.method,
        "params": params,
    ]
    var data = try JSONSerialization.data(withJSONObject: object)
    data.append(0x0A)
    return data
}
