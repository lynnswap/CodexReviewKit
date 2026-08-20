import Darwin
import Foundation
import OSLog

private let logger = Logger(subsystem: "CodexReviewKit", category: "app-server-transport")

package actor AppServerProcessTransport: JSONRPC.Transport {
    package struct Configuration: Sendable {
        package var executable: String
        package var arguments: [String]
        package var environment: [String: String]
        package var codexHomeURL: URL
        package var threadStartPermissionStrategy: AppServerAPI.Thread.Start.PermissionStrategy

        package init(
            executable: String? = nil,
            arguments: [String]? = nil,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            codexHomeURL: URL? = nil
        ) {
            let resolvedCodexHomeURL = codexHomeURL ?? AppServerCodexHome.url(environment: environment)
            let resolvedExecutable = executable ?? CodexAppServerExecutable.resolveExecutable(
                environment: environment
            )
            let supportsSessionSource: Bool
            if let arguments {
                supportsSessionSource = arguments.contains("--session-source")
            } else {
                supportsSessionSource = CodexAppServerExecutable.supportsAppServerSessionSource(
                    executable: resolvedExecutable,
                    environment: environment
                )
            }
            self.executable = resolvedExecutable
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
    private var framer = JSONRPC.Framer()
    private var pending: [Int: PendingResponse] = [:]
    private var notificationContinuations: [UUID: AsyncThrowingStream<JSONRPC.Notification, Error>.Continuation] = [:]
    private var stderrLogFilter = AppServerStderrLogFilter()
    private var closed = false

    package init(configuration: Configuration = .init()) throws {
        guard FileManager.default.isExecutableFile(atPath: configuration.executable) else {
            throw AppServerProcessTransportError.executableNotFound(
                command: configuration.executable,
                path: configuration.environment["PATH"]
            )
        }
        try AppServerCodexHome.ensureScaffold(at: configuration.codexHomeURL)
        let launch = try AppServerSpawnedProcess.launch(
            executable: configuration.executable,
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
        logger.info("Launching codex app-server: \(configuration.executable, privacy: .public) \(configuration.arguments.joined(separator: " "), privacy: .public)")
        logger.info("Using codex app-server home: \(configuration.codexHomeURL.path, privacy: .public)")
        logger.info("codex app-server launched with pid \(process.processIdentifier, privacy: .public)")
        Task { [weak self, events = stdoutEvents.events] in
            for await event in events {
                await self?.receiveStdout(event)
            }
        }
        Task { [weak self, events = stderrEvents.events] in
            for await event in events {
                await self?.receiveStderr(event)
            }
        }
        stdoutEvents.start()
        stderrEvents.start()
    }

    package func send(_ request: JSONRPC.Request) async throws -> Data {
        try throwIfClosed()
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
        try throwIfClosed()
        let payload = try makeNotificationPayload(notification)
        try stdin.fileHandleForWriting.write(contentsOf: payload)
    }

    package func notificationStream() -> AsyncThrowingStream<JSONRPC.Notification, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            if closed {
                continuation.finish(throwing: JSONRPC.Error.closed)
                return
            }
            let id = UUID()
            notificationContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeNotificationContinuation(id: id) }
            }
        }
    }

    package func close() async {
        await closeTransport(terminateProcess: true)
    }

    private func closeTransport(terminateProcess: Bool) async {
        guard closed == false else {
            return
        }
        closed = true
        stdoutEvents.cancel()
        stderrEvents.cancel()
        try? stdin.fileHandleForWriting.close()
        if terminateProcess {
            logger.info("Terminating codex app-server pid \(self.process.processIdentifier, privacy: .public)")
            await process.terminateAndWait()
        }
        finishAll(throwing: JSONRPC.Error.closed)
    }

    private func receiveStdout(_ event: AppServerPipeReadEvent) async {
        switch event {
        case .data(let data):
            receive(data)
        case .end:
            await finishReceiving()
        }
    }

    private func receive(_ data: Data) {
        let messages = framer.append(data)
        for message in messages {
            processMessage(message)
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
            processMessage(message)
        }
        await closeTransport(terminateProcess: true)
    }

    private func processMessage(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let method = object["method"] as? String {
            if object.keys.contains("id") {
                processServerRequest(method: method, object: object)
                return
            }
            processNotification(method: method, object: object)
        } else if let id = object["id"] as? Int {
            processResponse(id: id, object: object)
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

    private func processNotification(method: String, object: [String: Any]) {
        let params = object["params"] ?? [:]
        guard let data = try? JSONSerialization.data(withJSONObject: params) else {
            return
        }
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

    private func throwIfClosed() throws {
        if closed {
            throw JSONRPC.Error.closed
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
    let processIdentifier: pid_t

    private let processGroupID: pid_t
    private let stateLock = NSLock()
    private var didReap = false

    private init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
        self.processGroupID = processIdentifier
    }

    static func launch(
        executable: String,
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
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))

        let argv = [executable] + arguments
        let envp = environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }

        var processIdentifier = pid_t()
        try executable.withCString { executablePointer in
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
    ) async {
        let trackedProcessIDs = descendantProcessIDs()
        guard isFullyTerminated(trackedProcessIDs: trackedProcessIDs) == false else {
            return
        }
        signalProcessTree(SIGTERM, trackedProcessIDs: trackedProcessIDs)
        guard await waitUntilExit(timeout: graceDuration, trackedProcessIDs: trackedProcessIDs) == false else {
            return
        }
        signalProcessTree(SIGKILL, trackedProcessIDs: trackedProcessIDs)
        _ = await waitUntilExit(timeout: killDuration, trackedProcessIDs: trackedProcessIDs)
    }

    private func signalProcessTree(_ signal: Int32, trackedProcessIDs: Set<pid_t>) {
        if Darwin.kill(-processGroupID, signal) == 0 {
            for processID in trackedProcessIDs {
                _ = Darwin.kill(processID, signal)
            }
            return
        }
        for processID in trackedProcessIDs {
            _ = Darwin.kill(processID, signal)
        }
        _ = Darwin.kill(processIdentifier, signal)
    }

    private func waitUntilExit(timeout: Duration, trackedProcessIDs: Set<pid_t>) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while isFullyTerminated(trackedProcessIDs: trackedProcessIDs) == false {
            if clock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    private func isFullyTerminated(trackedProcessIDs: Set<pid_t>) -> Bool {
        reapIfExited()
            && processGroupIsEmpty()
            && trackedProcessIDs.allSatisfy(Self.processIsGone)
    }

    private func processGroupIsEmpty() -> Bool {
        if Darwin.kill(-processGroupID, 0) == 0 {
            return false
        }
        return errno == ESRCH
    }

    private static func processIsGone(_ processID: pid_t) -> Bool {
        if Darwin.kill(processID, 0) == 0 {
            return false
        }
        return errno == ESRCH
    }

    private func descendantProcessIDs() -> Set<pid_t> {
        let parentByProcessID = Self.parentProcessMap()
        var descendants = Set<pid_t>()
        var stack = [processIdentifier]
        while let parent = stack.popLast() {
            for (processID, parentProcessID) in parentByProcessID where parentProcessID == parent {
                if descendants.insert(processID).inserted {
                    stack.append(processID)
                }
            }
        }
        return descendants
    }

    private static func parentProcessMap() -> [pid_t: pid_t] {
        let bytesNeeded = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytesNeeded > 0 else {
            return [:]
        }
        let processIDSize = MemoryLayout<pid_t>.stride
        var processIDs = [pid_t](repeating: 0, count: Int(bytesNeeded) / processIDSize)
        let bytesWritten = processIDs.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                buffer.baseAddress,
                Int32(buffer.count * processIDSize)
            )
        }
        guard bytesWritten > 0 else {
            return [:]
        }
        let count = min(Int(bytesWritten) / processIDSize, processIDs.count)
        var parentByProcessID: [pid_t: pid_t] = [:]
        for processID in processIDs.prefix(count) where processID > 0 {
            var info = proc_bsdinfo()
            let infoSize = MemoryLayout<proc_bsdinfo>.stride
            let result = proc_pidinfo(
                processID,
                PROC_PIDTBSDINFO,
                0,
                &info,
                Int32(infoSize)
            )
            if result == Int32(infoSize) {
                parentByProcessID[processID] = pid_t(info.pbi_ppid)
            }
        }
        return parentByProcessID
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
    case executableNotFound(command: String, path: String?)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let command, let path):
            let resolvedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let resolvedPath, resolvedPath.isEmpty == false {
                return "Unable to locate \(command) executable in PATH: \(resolvedPath)"
            }
            return "Unable to locate \(command) executable. Set PATH so codex can be found."
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
    package struct Command {
        package var executable: String
        package var arguments: [String]
    }

    package static let fileBackedAuthConfiguration = #"cli_auth_credentials_store="file""#

    package static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Command {
        let executable = resolveExecutable(environment: environment)
        return .init(
            executable: executable,
            arguments: appServerArguments(for: executable, environment: environment)
        )
    }

    package static func resolveExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let requestedCommand = [
            environment["CODEX_REVIEW_CODEX_EXECUTABLE"],
            environment["CODEX_EXECUTABLE"],
        ].compactMap(\.self).first ?? "codex"

        if let candidate = findExecutable(
            requestedCommand,
            environment: environment
        ) {
            return candidate
        }

        return requestedCommand
    }

    package static func appServerArguments(
        for executable: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        appServerArguments(
            supportsSessionSource: supportsAppServerSessionSource(
                executable: executable,
                environment: environment
            )
        )
    }

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

    private static func findExecutable(
        _ requestedCommand: String,
        environment: [String: String]
    ) -> String? {
        let trimmedCommand = requestedCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCommand.isEmpty == false else {
            return nil
        }
        if trimmedCommand.contains("/") {
            return FileManager.default.isExecutableFile(atPath: trimmedCommand) ? trimmedCommand : nil
        }
        for directory in pathSearchDirectories(environment: environment) {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(trimmedCommand)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    package static func supportsAppServerSessionSource(
        executable: String,
        environment: [String: String]
    ) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
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

    package static func pathSearchDirectories(environment: [String: String]) -> [String] {
        let environmentDirectories = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        var directories: [String] = []
        for directory in environmentDirectories + [
            "/Applications/Codex.app/Contents/Resources",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ] where directories.contains(directory) == false {
            directories.append(directory)
        }
        return directories
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
