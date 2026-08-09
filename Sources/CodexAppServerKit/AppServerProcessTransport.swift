import Darwin
import Foundation
import OSLog
import Synchronization

private let logger = Logger(subsystem: "CodexAppServerKit", category: "app-server-transport")

package actor AppServerProcessTransport: JSONRPC.Transport {
    package nonisolated static let stdoutReadChunkByteCount = 64 * 1_024
    package nonisolated let connectionEventHub: ConnectionEventHub

    package struct Configuration: Sendable {
        package var executable: String
        package var arguments: [String]
        package var environment: [String: String]
        package var codexHomeURL: URL

        package init(
            executable: String? = nil,
            arguments: [String]? = nil,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            codexHomeURL: URL
        ) {
            let resolvedExecutable = executable.map {
                CodexAppServerExecutable.resolveExecutable($0, environment: environment)
            } ?? CodexAppServerExecutable.resolveExecutable(
                environment: environment
            )
            self.executable = resolvedExecutable
            self.arguments =
                arguments
                ?? CodexAppServerExecutable.appServerArguments()
            self.environment = AppServerCodexHome.environment(
                environment,
                codexHomeURL: codexHomeURL
            )
            self.codexHomeURL = codexHomeURL
        }
    }

    private let process: AppServerSpawnedProcess
    private let writer: AppServerJSONRPCWriter
    private let mailbox: JSONRPCInboundFrameMailbox
    private let terminationToken: ProcessTerminationToken
    private let stdoutReadMetrics: AppServerStdoutReadMetrics
    private let stdoutReaderTask: Task<Void, Never>
    private let stderrDrainTask: Task<Void, Never>
    private let processWaiterTask: Task<JSONRPC.ProcessExitObservation, Never>
    private var pending: [Int: JSONRPCResponseWaiter] = [:]
    private var acceptingOutbound = true
    private var closeStarted = false
    private var inboundTerminalObserved = false

    package nonisolated var processTerminationToken: ProcessTerminationToken {
        terminationToken
    }

    package init(
        configuration: Configuration,
        connectionEventHub: ConnectionEventHub,
        writerFactory: @Sendable (FileHandle) -> AppServerJSONRPCWriter = {
            AppServerJSONRPCWriter(fileHandle: $0)
        }
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: configuration.executable) else {
            throw CodexLaunchFailure.executableNotFound(
                command: configuration.executable,
                searchedPath: configuration.environment["PATH"]
            )
        }
        do {
            try AppServerCodexHome.ensureScaffold(at: configuration.codexHomeURL)
        } catch {
            throw CodexLaunchFailure.scaffold(
                path: configuration.codexHomeURL.path,
                message: error.localizedDescription
            )
        }
        let launch: AppServerProcessLaunch
        do {
            launch = try AppServerSpawnedProcess.launch(
                executable: configuration.executable,
                arguments: configuration.arguments,
                environment: configuration.environment
            )
        } catch {
            throw CodexLaunchFailure.spawn(
                executable: configuration.executable,
                errno: (error as? POSIXError)?.code.rawValue,
                message: error.localizedDescription
            )
        }
        let process = launch.process
        let stdin = launch.stdin
        let stdout = launch.stdout
        let stderr = launch.stderr
        self.process = process
        self.connectionEventHub = connectionEventHub
        let writer = writerFactory(stdin.fileHandleForWriting)
        self.writer = writer
        let mailbox = JSONRPCInboundFrameMailbox()
        self.mailbox = mailbox
        let stdoutReadMetrics = AppServerStdoutReadMetrics()
        self.stdoutReadMetrics = stdoutReadMetrics
        let terminationToken = ProcessTerminationToken(processGroupID: process.processIdentifier)
        self.terminationToken = terminationToken
        self.stdoutReaderTask = Task {
            await Self.readStdout(
                stdout.fileHandleForReading,
                into: mailbox,
                metrics: stdoutReadMetrics
            )
        }
        self.stderrDrainTask = Task {
            await Self.drainStderr(
                stderr.fileHandleForReading,
                connectionEventHub: connectionEventHub
            )
        }
        self.processWaiterTask = Task {
            await process.waitForExit(terminationToken: terminationToken)
        }
        logger.info(
            "Launching codex app-server: \(configuration.executable, privacy: .public) \(configuration.arguments.joined(separator: " "), privacy: .public)"
        )
        logger.info(
            "Using codex app-server home: \(configuration.codexHomeURL.path, privacy: .public)")
        logger.info(
            "codex app-server launched with pid \(process.processIdentifier, privacy: .public)")
    }

    package func send(
        _ request: JSONRPC.Request,
        acceptWrite: @Sendable () throws -> Void
    ) async throws -> Data {
        try Task.checkCancellation()
        try throwIfNotAcceptingOutbound()
        precondition(
            pending[request.id] == nil,
            "JSON-RPC request IDs must be unique while a response is pending."
        )
        let payload = try makeRequestPayload(request)
        try acceptWrite()

        let waiter = JSONRPCResponseWaiter()
        pending[request.id] = waiter
        do {
            try writer.write(payload)
        } catch {
            pending.removeValue(forKey: request.id)
            let failure = Self.transportFailure(from: error)
            await claimTerminal(failure)
            throw JSONRPC.OutboundWriteFailure(failure)
        }
        return try await waiter.wait()
    }

    package func notify(_ notification: JSONRPC.Notification) async throws {
        try Task.checkCancellation()
        try throwIfNotAcceptingOutbound()
        let payload = try makeNotificationPayload(notification)
        do {
            try writer.write(payload)
        } catch {
            let failure = Self.transportFailure(from: error)
            await claimTerminal(failure)
            throw failure
        }
    }

    package func nextInboundEvent() async throws -> JSONRPC.InboundEvent? {
        while true {
            let frame: Data
            do {
                guard let next = try await mailbox.next() else {
                    inboundTerminalObserved = true
                    return nil
                }
                frame = next
            } catch {
                let snapshot = await mailbox.snapshot()
                if snapshot.isTerminal, snapshot.acceptedFrameCount == 0 {
                    inboundTerminalObserved = true
                }
                throw error
            }

            switch try JSONRPC.decodeInboundEnvelope(frame) {
            case .response(let id, let result):
                guard let waiter = pending.removeValue(forKey: id) else {
                    if acceptingOutbound == false {
                        connectionEventHub.yield(.warning(
                            ConnectionDiagnosticFactory.lateResponse(requestID: id)
                        ))
                        logger.warning(
                            "Ignoring late JSON-RPC response \(id, privacy: .public) after outbound close"
                        )
                        continue
                    }
                    let failure = CodexTransportFailure.protocolViolation(
                        message: "Received a JSON-RPC response for unknown request id \(id).",
                        rawData: frame
                    )
                    await claimTerminal(failure)
                    throw failure
                }
                waiter.resolve(result)
            case .event(let event):
                return event
            }
        }
    }

    package func respond(
        to requestID: CodexServerRequestID,
        with response: CodexServerRequestResponse
    ) async throws {
        try throwIfNotAcceptingOutbound()
        do {
            try writer.write(Self.serverRequestResponsePayload(id: requestID, response: response))
        } catch {
            let failure = Self.transportFailure(from: error)
            await claimTerminal(failure)
            throw failure
        }
    }

    package func beginClose() async -> JSONRPC.ProcessExitObservation? {
        guard closeStarted == false else {
            return process.observedExitForCloseArbitration()
        }
        closeStarted = true
        acceptingOutbound = false
        let exitObservation = process.markTerminationStarted()
        writer.close()
        await mailbox.finish()
        logger.info(
            "Terminating codex app-server pid \(self.process.processIdentifier, privacy: .public)"
        )
        terminationToken.terminateOnce()
        return exitObservation
    }

    package func finishPendingResponsesAfterInboundDrain(
        _ failure: CodexTransportFailure
    ) {
        precondition(
            inboundTerminalObserved,
            "Pending responses can finish only after inbound terminal was observed."
        )
        let responseFailure: JSONRPC.Error
        switch failure {
        case .closed:
            responseFailure = .closed
        case .io, .framing, .protocolViolation, .contractViolation:
            responseFailure = .invalidMessage(failure.localizedDescription)
        }
        let waiters = pending.values
        pending.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resolve(.failure(responseFailure))
        }
    }

    package func waitForProcessExit() async -> JSONRPC.ProcessExitObservation {
        await processWaiterTask.value
    }

    package func waitUntilClosed() async {
        await stdoutReaderTask.value
        await stderrDrainTask.value
    }

    package func reapProcess() async {
        await process.reap()
    }

    package func processLifecycleSnapshotForTesting() -> AppServerProcessLifecycleSnapshot {
        process.lifecycleSnapshot()
    }

    package func inboundMailboxSnapshotForTesting() async -> JSONRPCInboundFrameMailbox.Snapshot {
        await mailbox.snapshot()
    }

    package func waitForInboundAdmissionWaiterCountForTesting(atLeast minimumCount: Int) async {
        await mailbox.waitForAdmissionWaiterCount(atLeast: minimumCount)
    }

    package func waitUntilInboundReceiverIsRegisteredForTesting() async {
        await mailbox.waitUntilReceiverIsRegistered()
    }

    package func stdoutReadSnapshotForTesting() -> AppServerStdoutReadSnapshot {
        stdoutReadMetrics.snapshot()
    }

    package static func responsePayloadData(from result: Any) throws -> Data {
        try JSONRPC.payloadData(from: result)
    }

    package static func serverRequestResponsePayload(
        id: CodexServerRequestID,
        response: CodexServerRequestResponse
    ) throws -> Data {
        let payload: [String: Any]
        switch response {
        case .result(let result):
            payload = [
                "id": id.jsonObject,
                "result": try JSONSerialization.jsonObject(
                    with: result,
                    options: [.fragmentsAllowed]
                ),
            ]
        case .error(let code, let message):
            payload = [
                "id": id.jsonObject,
                "error": [
                    "code": code,
                    "message": message,
                ],
            ]
        }
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        return data
    }

    private func throwIfNotAcceptingOutbound() throws {
        if acceptingOutbound == false {
            throw JSONRPC.Error.closed
        }
    }

    private func claimTerminal(_ failure: CodexTransportFailure) async {
        if acceptingOutbound {
            acceptingOutbound = false
            writer.close()
        }
        await mailbox.finish(throwing: failure)
    }

    private nonisolated static func transportFailure(from error: Error) -> CodexTransportFailure {
        if let failure = error as? CodexTransportFailure {
            return failure
        }
        if let error = error as? JSONRPC.Error, error == .closed {
            return .closed
        }
        return .io(
            errno: (error as? POSIXError)?.code.rawValue,
            message: error.localizedDescription
        )
    }

    private nonisolated static func readStdout(
        _ fileHandle: FileHandle,
        into mailbox: JSONRPCInboundFrameMailbox,
        metrics: AppServerStdoutReadMetrics
    ) async {
        var framer = JSONRPC.Framer()
        var currentChunkRemainderByteCount = 0
        let eventSource: AppServerPipeReadEventSource
        do {
            try makeNonblocking(fileHandle.fileDescriptor)
            eventSource = AppServerPipeReadEventSource(
                fileHandle: fileHandle,
                label: "app-server-stdout",
                onCancel: {
                    metrics.sourceCancellationCompleted()
                }
            )
        } catch {
            try? fileHandle.close()
            await mailbox.finish(throwing: .io(
                errno: (error as? POSIXError)?.code.rawValue,
                message: error.localizedDescription
            ))
            return
        }
        do {
            stdoutEvents: while true {
                try Task.checkCancellation()
                switch await eventSource.next() {
                case .ready:
                    readLoop: while true {
                        switch try readNonblockingChunk(
                            fileHandle.fileDescriptor,
                            maximumByteCount: stdoutReadChunkByteCount
                        ) {
                        case .data(let data):
                            metrics.beginChunk(byteCount: data.count)
                            currentChunkRemainderByteCount = data.count
                            for byte in data {
                                currentChunkRemainderByteCount -= 1
                                let frame = try framer.append(byte)
                                if let frame {
                                    metrics.updateRemainder(
                                        byteCount: currentChunkRemainderByteCount
                                    )
                                    try await mailbox.send(frame)
                                }
                            }
                            metrics.updateRemainder(byteCount: 0)
                        case .wouldBlock:
                            break readLoop
                        case .end:
                            if let frame = framer.finish() {
                                try await mailbox.send(frame)
                            }
                            await mailbox.finish()
                            break stdoutEvents
                        }
                    }
                case .cancelled:
                    throw CancellationError()
                }
            }
        } catch is CancellationError {
            metrics.dropRemainder(byteCount: currentChunkRemainderByteCount)
            await mailbox.finish(throwing: .closed)
        } catch let failure as CodexTransportFailure {
            metrics.dropRemainder(byteCount: currentChunkRemainderByteCount)
            await mailbox.finish(throwing: failure)
        } catch {
            metrics.dropRemainder(byteCount: currentChunkRemainderByteCount)
            await mailbox.finish(throwing: .io(
                errno: (error as? POSIXError)?.code.rawValue,
                message: error.localizedDescription
            ))
        }
        await eventSource.cancelAndWait()
    }

    private nonisolated static func drainStderr(
        _ fileHandle: FileHandle,
        connectionEventHub: ConnectionEventHub
    ) async {
        var filter = AppServerStderrLogFilter()
        let eventSource: AppServerPipeReadEventSource
        do {
            try makeNonblocking(fileHandle.fileDescriptor)
            eventSource = AppServerPipeReadEventSource(
                fileHandle: fileHandle,
                label: "app-server-stderr"
            )
        } catch {
            try? fileHandle.close()
            connectionEventHub.yield(.warning(
                ConnectionDiagnosticFactory.processStderrFailure(
                    .setup,
                    details: error.localizedDescription
                )
            ))
            logger.error(
                "codex app-server stderr setup failed: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        do {
            eventLoop: while true {
                try Task.checkCancellation()
                switch await eventSource.next() {
                case .ready:
                    readLoop: while true {
                        switch try readNonblockingChunk(fileHandle.fileDescriptor) {
                        case .data(let data):
                            for event in filter.append(data) {
                                logStderr(event, connectionEventHub: connectionEventHub)
                            }
                        case .wouldBlock:
                            break readLoop
                        case .end:
                            break eventLoop
                        }
                    }
                case .cancelled:
                    throw CancellationError()
                }
            }
        } catch is CancellationError {
        } catch {
            connectionEventHub.yield(.warning(
                ConnectionDiagnosticFactory.processStderrFailure(
                    .read,
                    details: error.localizedDescription
                )
            ))
            logger.error(
                "codex app-server stderr read failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        await eventSource.cancelAndWait()
        for event in filter.finish() {
            logStderr(event, connectionEventHub: connectionEventHub)
        }
    }

    private enum NonblockingChunkRead {
        case data(Data)
        case wouldBlock
        case end
    }

    private nonisolated static func makeNonblocking(_ fileDescriptor: Int32) throws {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private nonisolated static func readNonblockingChunk(
        _ fileDescriptor: Int32,
        maximumByteCount: Int = 16 * 1_024
    ) throws -> NonblockingChunkRead {
        precondition(maximumByteCount > 0)
        var bytes = [UInt8](repeating: 0, count: maximumByteCount)
        let count: Int
        while true {
            let result = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(fileDescriptor, buffer.baseAddress, buffer.count)
            }
            if result == -1, errno == EINTR {
                continue
            }
            count = result
            break
        }
        if count > 0 {
            return .data(Data(bytes.prefix(count)))
        }
        if count == 0 {
            return .end
        }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            return .wouldBlock
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private nonisolated static func logStderr(
        _ event: AppServerStderrLogFilter.Event,
        connectionEventHub: ConnectionEventHub
    ) {
        connectionEventHub.yield(.warning(
            ConnectionDiagnosticFactory.processStderr(event)
        ))
        switch event.level {
        case .error:
            logger.error("codex app-server stderr: \(event.message, privacy: .public)")
        case .warning:
            logger.warning("codex app-server stderr: \(event.message, privacy: .public)")
        }
    }
}

private enum AppServerReadEvent: Sendable {
    case ready
    case cancelled
}

private final class AppServerOneBitReadSignal: Sendable {
    private struct State {
        var hasPendingReadiness = false
        var isCancelled = false
        var waiter: AppServerReadEventWaiter?
    }

    private let state = Mutex(State())

    func next() async -> AppServerReadEvent {
        if Task.isCancelled {
            return .cancelled
        }
        let waiter = AppServerReadEventWaiter()
        let immediate = state.withLock { state -> AppServerReadEvent? in
            if state.hasPendingReadiness {
                state.hasPendingReadiness = false
                return .ready
            }
            if state.isCancelled {
                return .cancelled
            }
            precondition(state.waiter == nil, "Read signal supports one consumer.")
            state.waiter = waiter
            return nil
        }
        if let immediate {
            return immediate
        }
        let event = await waiter.wait()
        state.withLock { state in
            if state.waiter?.id == waiter.id {
                state.waiter = nil
            }
        }
        return event
    }

    func signalReadiness() {
        let waiter = state.withLock { state -> AppServerReadEventWaiter? in
            guard state.isCancelled == false else {
                return nil
            }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.hasPendingReadiness = true
            return nil
        }
        if let waiter, waiter.resolve(.ready) == false {
            state.withLock { state in
                if state.isCancelled == false {
                    state.hasPendingReadiness = true
                }
            }
        }
    }

    func cancel() {
        let waiter = state.withLock { state -> AppServerReadEventWaiter? in
            guard state.isCancelled == false else {
                return nil
            }
            state.isCancelled = true
            state.hasPendingReadiness = false
            defer { state.waiter = nil }
            return state.waiter
        }
        _ = waiter?.resolve(.cancelled)
    }
}

private final class AppServerReadEventWaiter: Sendable {
    private enum State {
        case pending(CheckedContinuation<AppServerReadEvent, Never>?)
        case resolved(AppServerReadEvent)
    }

    let id = UUID()
    private let state = Mutex<State>(.pending(nil))

    func wait() async -> AppServerReadEvent {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate = state.withLock { state -> AppServerReadEvent? in
                    switch state {
                    case .pending(nil):
                        state = .pending(continuation)
                        return nil
                    case .pending(.some):
                        preconditionFailure("Read waiter registered more than once.")
                    case .resolved(let event):
                        return event
                    }
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: {
            _ = self.resolve(.cancelled)
        }
    }

    @discardableResult
    func resolve(_ event: AppServerReadEvent) -> Bool {
        let result = state.withLock {
            state -> (Bool, CheckedContinuation<AppServerReadEvent, Never>?) in
            switch state {
            case .pending(let continuation):
                state = .resolved(event)
                return (true, continuation)
            case .resolved:
                return (false, nil)
            }
        }
        result.1?.resume(returning: event)
        return result.0
    }
}

private final class AppServerPipeReadEventSource: Sendable {
    private struct State {
        var source: DispatchSourceRead?
    }

    private let signal = AppServerOneBitReadSignal()
    private let cancellationCompletion = AppServerCancellationCompletion()
    private let state: Mutex<State>

    init(
        fileHandle: FileHandle,
        label: String,
        onCancel: @escaping @Sendable () -> Void = {}
    ) {
        let queue = DispatchQueue(label: "CodexAppServerKit.\(label)")
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fileHandle.fileDescriptor,
            queue: queue
        )
        self.state = Mutex(.init(source: source))
        let signal = signal
        source.setEventHandler {
            signal.signalReadiness()
        }
        let cancellationCompletion = cancellationCompletion
        source.setCancelHandler {
            try? fileHandle.close()
            onCancel()
            signal.cancel()
            cancellationCompletion.complete()
        }
        source.resume()
    }

    deinit {
        cancel()
    }

    func next() async -> AppServerReadEvent {
        await signal.next()
    }

    func cancel() {
        let source = state.withLock { state in
            defer { state.source = nil }
            return state.source
        }
        source?.cancel()
    }

    func cancelAndWait() async {
        cancel()
        await cancellationCompletion.wait()
    }
}

package struct AppServerStdoutReadSnapshot: Equatable, Sendable {
    package var successfulReadCount: Int
    package var maximumChunkByteCount: Int
    package var currentChunkRemainderByteCount: Int
    package var droppedRemainderByteCount: Int
    package var sourceCancellationCompleted: Bool
}

private final class AppServerStdoutReadMetrics: Sendable {
    private struct State {
        var successfulReadCount = 0
        var maximumChunkByteCount = 0
        var currentChunkRemainderByteCount = 0
        var droppedRemainderByteCount = 0
        var didCompleteSourceCancellation = false
    }

    private let state = Mutex(State())

    func beginChunk(byteCount: Int) {
        state.withLock { state in
            precondition(
                state.currentChunkRemainderByteCount == 0,
                "A new stdout chunk cannot be read before its predecessor is consumed."
            )
            state.successfulReadCount += 1
            state.maximumChunkByteCount = max(state.maximumChunkByteCount, byteCount)
            state.currentChunkRemainderByteCount = byteCount
        }
    }

    func updateRemainder(byteCount: Int) {
        state.withLock { state in
            precondition(byteCount >= 0)
            state.currentChunkRemainderByteCount = byteCount
        }
    }

    func dropRemainder(byteCount: Int) {
        state.withLock { state in
            precondition(byteCount >= 0)
            state.droppedRemainderByteCount += byteCount
            state.currentChunkRemainderByteCount = 0
        }
    }

    func sourceCancellationCompleted() {
        state.withLock { $0.didCompleteSourceCancellation = true }
    }

    func snapshot() -> AppServerStdoutReadSnapshot {
        state.withLock { state in
            .init(
                successfulReadCount: state.successfulReadCount,
                maximumChunkByteCount: state.maximumChunkByteCount,
                currentChunkRemainderByteCount: state.currentChunkRemainderByteCount,
                droppedRemainderByteCount: state.droppedRemainderByteCount,
                sourceCancellationCompleted: state.didCompleteSourceCancellation
            )
        }
    }
}

private final class AppServerProcessExitEventSource: Sendable {
    private struct State {
        var source: DispatchSourceProcess?
    }

    private let signal = AppServerOneBitReadSignal()
    private let cancellationCompletion = AppServerCancellationCompletion()
    private let state: Mutex<State>

    init(processIdentifier: pid_t) {
        let queue = DispatchQueue(label: "CodexAppServerKit.app-server-process-exit")
        let source = DispatchSource.makeProcessSource(
            identifier: processIdentifier,
            eventMask: .exit,
            queue: queue
        )
        self.state = Mutex(.init(source: source))
        let signal = signal
        source.setEventHandler {
            signal.signalReadiness()
        }
        let cancellationCompletion = cancellationCompletion
        source.setCancelHandler {
            signal.cancel()
            cancellationCompletion.complete()
        }
        source.resume()
    }

    deinit {
        cancel()
    }

    func next() async -> AppServerReadEvent {
        await signal.next()
    }

    func cancel() {
        let source = state.withLock { state in
            defer { state.source = nil }
            return state.source
        }
        source?.cancel()
    }

    func cancelAndWait() async {
        cancel()
        await cancellationCompletion.wait()
    }
}

private final class AppServerCancellationCompletion: Sendable {
    private enum State {
        case pending([CheckedContinuation<Void, Never>])
        case complete
    }

    private let state = Mutex<State>(.pending([]))

    func wait() async {
        await withCheckedContinuation { continuation in
            let isComplete = state.withLock { state in
                switch state {
                case .pending(var waiters):
                    waiters.append(continuation)
                    state = .pending(waiters)
                    return false
                case .complete:
                    return true
                }
            }
            if isComplete {
                continuation.resume()
            }
        }
    }

    func complete() {
        let waiters = state.withLock { state in
            switch state {
            case .pending(let waiters):
                state = .complete
                return waiters
            case .complete:
                return []
            }
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

package final class AppServerJSONRPCWriter: Sendable {
    private struct State {
        var fileHandle: FileHandle?
        var writeOverride: (@Sendable (Data) throws -> Void)?
    }

    private let state: Mutex<State>

    package init(fileHandle: FileHandle) {
        self.state = Mutex(.init(fileHandle: fileHandle, writeOverride: nil))
    }

    package init(
        fileHandle: FileHandle,
        writeOverride: @escaping @Sendable (Data) throws -> Void
    ) {
        self.state = Mutex(.init(
            fileHandle: fileHandle,
            writeOverride: writeOverride
        ))
    }

    package func write(_ data: Data) throws {
        try state.withLock { state in
            guard let fileHandle = state.fileHandle else {
                throw JSONRPC.Error.closed
            }
            if let writeOverride = state.writeOverride {
                try writeOverride(data)
                return
            }
            try fileHandle.write(contentsOf: data)
        }
    }

    package func close() {
        state.withLock { state in
            try? state.fileHandle?.close()
            state.fileHandle = nil
            state.writeOverride = nil
        }
    }
}

private struct AppServerProcessLaunch {
    var process: AppServerSpawnedProcess
    var stdin: Pipe
    var stdout: Pipe
    var stderr: Pipe
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
            return [
                .init(
                    level: .error,
                    message: "emitted \(data.count) undecodable bytes"
                )
            ]
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
                    bufferedText[nextIndex] == "\n"
                {
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
            of:
                #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\s+(?:ERROR|WARN|INFO|DEBUG|TRACE)\s+"#,
            options: .regularExpression
        ) != nil
    }

    private static func isTimeoutSummaryLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("command timed out after ") || trimmed.hasPrefix("Wall time: ")
            || trimmed.hasPrefix("Exit code: ")
    }

    private static func canBeFollowedByCommandOutput(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("codex_core::tools::router: error=")
            || trimmed.hasPrefix("Wall time: ") || trimmed.hasPrefix("Exit code: ")
    }
}

package struct AppServerProcessLifecycleSnapshot: Equatable, Sendable {
    package var observedExitStatus: Int32?
    package var didObserveExit: Bool
    package var didBeginTermination: Bool
    package var didReap: Bool
    package var reapSystemCallCount: Int
}

private final class AppServerSpawnedProcess: @unchecked Sendable {
    let processIdentifier: pid_t

    private struct ExitState {
        var observation: JSONRPC.ProcessExitObservation?
        var didBeginTermination = false
        var didReap = false
        var reapSystemCallCount = 0
    }
    private let exitState = Mutex(ExitState())

    private init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
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

        try check(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                stdin.fileHandleForReading.fileDescriptor,
                STDIN_FILENO
            ))
        try check(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                stdout.fileHandleForWriting.fileDescriptor,
                STDOUT_FILENO
            ))
        try check(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                stderr.fileHandleForWriting.fileDescriptor,
                STDERR_FILENO
            ))
        for fileDescriptor in AppServerProcessFileDescriptorPlan.childPipeDescriptorsToClose([
            stdin.fileHandleForReading.fileDescriptor,
            stdin.fileHandleForWriting.fileDescriptor,
            stdout.fileHandleForReading.fileDescriptor,
            stdout.fileHandleForWriting.fileDescriptor,
            stderr.fileHandleForReading.fileDescriptor,
            stderr.fileHandleForWriting.fileDescriptor,
        ]) {
            try check(posix_spawn_file_actions_addclose(&fileActions, fileDescriptor))
        }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))

        let argv = [executable] + arguments
        let envp =
            environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }

        var processIdentifier = pid_t()
        try executable.withCString { executablePointer in
            try withCStringArray(argv) { argvPointers in
                try withCStringArray(envp) { envPointers in
                    try check(
                        posix_spawn(
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

    func waitForExit(
        terminationToken: ProcessTerminationToken,
        graceDuration: Duration = .seconds(2)
    ) async -> JSONRPC.ProcessExitObservation {
        let exitSource = AppServerProcessExitEventSource(
            processIdentifier: processIdentifier
        )
        let observation: JSONRPC.ProcessExitObservation
        if let alreadyExited = observeExitIfAvailable() {
            if case .failed = alreadyExited {
                terminationToken.terminateOnce()
                await Self.ensureExitAfterWaitFailure(
                    exitSource: exitSource,
                    terminationToken: terminationToken,
                    graceDuration: graceDuration
                )
            }
            observation = alreadyExited
        } else {
            switch await Self.waitForExitOrTermination(
                exitSource: exitSource,
                terminationToken: terminationToken
            ) {
            case .exit:
                observation = waitForExitObservationAfterReadiness()
            case .termination:
                if terminationToken.didRequestKill == false {
                    let exitedDuringGrace = await Self.waitForExitDuringGrace(
                        exitSource: exitSource,
                        graceDuration: graceDuration
                    )
                    if exitedDuringGrace {
                        observation = waitForExitObservationAfterReadiness()
                        break
                    }
                    terminationToken.killOnce()
                }
                if case .ready = await exitSource.next() {
                    observation = waitForExitObservationAfterReadiness()
                } else {
                    observation = .failed(.closed)
                }
            case .cancelled:
                observation = .failed(.closed)
            case .graceExpired:
                preconditionFailure("Initial process wait cannot produce grace expiration.")
            }
        }
        await exitSource.cancelAndWait()
        return observation
    }

    func markTerminationStarted() -> JSONRPC.ProcessExitObservation? {
        exitState.withLock { state in
            if state.observation == nil {
                state.observation = Self.probeExit(
                    processIdentifier: processIdentifier,
                    didBeginTermination: state.didBeginTermination
                )
            }
            state.didBeginTermination = true
            return state.observation
        }
    }

    func observedExitForCloseArbitration() -> JSONRPC.ProcessExitObservation? {
        exitState.withLock { $0.observation }
    }

    func reap() async {
        reapAfterObservedExit()
    }

    func lifecycleSnapshot() -> AppServerProcessLifecycleSnapshot {
        exitState.withLock { state in
            let status: Int32?
            let didObserveExit: Bool
            if case .exited(let observedStatus, _) = state.observation {
                status = observedStatus
                didObserveExit = true
            } else {
                status = nil
                didObserveExit = false
            }
            return .init(
                observedExitStatus: status,
                didObserveExit: didObserveExit,
                didBeginTermination: state.didBeginTermination,
                didReap: state.didReap,
                reapSystemCallCount: state.reapSystemCallCount
            )
        }
    }

    private func observeExitIfAvailable() -> JSONRPC.ProcessExitObservation? {
        exitState.withLock { state in
            if let observation = state.observation {
                return observation
            }
            let observation = Self.probeExit(
                processIdentifier: processIdentifier,
                didBeginTermination: state.didBeginTermination
            )
            state.observation = observation
            return observation
        }
    }

    private func reapAfterObservedExit() {
        exitState.withLock { state in
            if state.didReap {
                return
            }
            var rawStatus: Int32 = 0
            let result: pid_t
            while true {
                let current = waitpid(processIdentifier, &rawStatus, 0)
                if current == -1, errno == EINTR {
                    continue
                }
                result = current
                break
            }
            if result == processIdentifier {
                state.didReap = true
                state.reapSystemCallCount += 1
                if case .exited(let observedStatus, _) = state.observation {
                    precondition(
                        observedStatus == Self.exitCode(from: rawStatus),
                        "waitid observation and waitpid reap status must agree."
                    )
                }
                return
            }
            if result == -1, errno == ECHILD {
                state.didReap = true
                logger.error(
                    "codex app-server pid \(self.processIdentifier, privacy: .public) was reaped outside its transport owner"
                )
                return
            }
            preconditionFailure(
                "waitpid failed while reaping app-server pid \(processIdentifier): \(Self.errnoMessage(errno))"
            )
        }
    }

    private enum WaitEvent: Equatable, Sendable {
        case exit
        case termination
        case graceExpired
        case cancelled
    }

    private static func waitForExitOrTermination(
        exitSource: AppServerProcessExitEventSource,
        terminationToken: ProcessTerminationToken
    ) async -> WaitEvent {
        await withTaskGroup(of: WaitEvent.self) { group in
            group.addTask {
                switch await exitSource.next() {
                case .ready: .exit
                case .cancelled: .cancelled
                }
            }
            group.addTask {
                switch await terminationToken.nextTerminationRequest() {
                case .ready: .termination
                case .cancelled: .cancelled
                }
            }
            guard let first = await group.next() else {
                preconditionFailure("Process wait race requires a winner.")
            }
            group.cancelAll()
            while await group.next() != nil {}
            return first
        }
    }

    private static func waitForExitDuringGrace(
        exitSource: AppServerProcessExitEventSource,
        graceDuration: Duration
    ) async -> Bool {
        await withTaskGroup(of: WaitEvent.self) { group in
            group.addTask {
                switch await exitSource.next() {
                case .ready: .exit
                case .cancelled: .cancelled
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: graceDuration)
                    return .graceExpired
                } catch {
                    return .cancelled
                }
            }
            guard let first = await group.next() else {
                preconditionFailure("Process grace race requires a winner.")
            }
            group.cancelAll()
            while await group.next() != nil {}
            return first == .exit
        }
    }

    private static func ensureExitAfterWaitFailure(
        exitSource: AppServerProcessExitEventSource,
        terminationToken: ProcessTerminationToken,
        graceDuration: Duration
    ) async {
        if terminationToken.didRequestKill == false {
            let exitedDuringGrace = await waitForExitDuringGrace(
                exitSource: exitSource,
                graceDuration: graceDuration
            )
            if exitedDuringGrace {
                return
            }
            terminationToken.killOnce()
        }
        _ = await exitSource.next()
    }

    private func waitForExitObservationAfterReadiness() -> JSONRPC.ProcessExitObservation {
        exitState.withLock { state in
            if let observation = state.observation {
                return observation
            }
            let observation = Self.waitForExitObservationAfterReadiness(
                processIdentifier: processIdentifier,
                didBeginTermination: state.didBeginTermination
            )
            state.observation = observation
            return observation
        }
    }

    private static func waitForExitObservationAfterReadiness(
        processIdentifier: pid_t,
        didBeginTermination: Bool
    ) -> JSONRPC.ProcessExitObservation {
        var info = siginfo_t()
        let result: Int32
        while true {
            let current = waitid(
                P_PID,
                id_t(processIdentifier),
                &info,
                WEXITED | WNOWAIT
            )
            if current == -1, errno == EINTR {
                continue
            }
            result = current
            break
        }
        guard result == 0, info.si_pid == processIdentifier else {
            let errorNumber = result == -1 ? errno : EPROTO
            return .failed(.io(
                errno: errorNumber,
                message: "waitid failed for ready app-server pid \(processIdentifier): \(errnoMessage(errorNumber))"
            ))
        }
        return terminalObservation(
            from: info,
            didBeginTermination: didBeginTermination
        )
    }

    private static func probeExit(
        processIdentifier: pid_t,
        didBeginTermination: Bool
    ) -> JSONRPC.ProcessExitObservation? {
        var info = siginfo_t()
        let result: Int32
        while true {
            let current = waitid(
                P_PID,
                id_t(processIdentifier),
                &info,
                WEXITED | WNOHANG | WNOWAIT
            )
            if current == -1, errno == EINTR {
                continue
            }
            result = current
            break
        }
        if result == 0, info.si_pid == 0 {
            return nil
        }
        if result == 0, info.si_pid == processIdentifier {
            return terminalObservation(
                from: info,
                didBeginTermination: didBeginTermination
            )
        }
        let errorNumber = result == -1 ? errno : EPROTO
        return .failed(.io(
            errno: errorNumber,
            message: "waitid failed for app-server pid \(processIdentifier): \(errnoMessage(errorNumber))"
        ))
    }

    private static func terminalObservation(
        from info: siginfo_t,
        didBeginTermination: Bool
    ) -> JSONRPC.ProcessExitObservation {
        let status: Int32
        switch info.si_code {
        case CLD_EXITED:
            status = info.si_status
        case CLD_KILLED, CLD_DUMPED:
            status = -info.si_status
        default:
            return .failed(.contractViolation(
                message: "waitid returned nonterminal child status code \(info.si_code)."
            ))
        }
        return .exited(
            status: status,
            observedBeforeTermination: didBeginTermination == false
        )
    }

    private static func exitCode(from waitStatus: Int32) -> Int32 {
        let terminationSignal = waitStatus & 0x7f
        if terminationSignal == 0 {
            return (waitStatus >> 8) & 0xff
        }
        if terminationSignal != 0x7f {
            return -terminationSignal
        }
        return waitStatus
    }

    private static func errnoMessage(_ errorNumber: Int32) -> String {
        String(cString: strerror(errorNumber))
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

package final class ProcessTerminationToken: Sendable {
    private struct State {
        var didRequestTermination = false
        var didRequestKill = false
    }

    private let processGroupID: pid_t?
    private let state = Mutex(State())
    private let terminationRequestSignal = AppServerOneBitReadSignal()

    package init(processGroupID: pid_t? = nil) {
        self.processGroupID = processGroupID
    }

    package var didRequestTermination: Bool {
        state.withLock { $0.didRequestTermination }
    }

    package var didRequestKill: Bool {
        state.withLock { $0.didRequestKill }
    }

    package func terminateOnce() {
        let shouldSignal = state.withLock { state in
            guard state.didRequestTermination == false else {
                return false
            }
            state.didRequestTermination = true
            return true
        }
        if shouldSignal, let processGroupID {
            _ = Darwin.kill(-processGroupID, SIGTERM)
        }
        if shouldSignal {
            terminationRequestSignal.signalReadiness()
        }
    }

    package func killOnce() {
        let shouldSignal = state.withLock { state in
            guard state.didRequestKill == false else {
                return false
            }
            state.didRequestKill = true
            return true
        }
        if shouldSignal, let processGroupID {
            _ = Darwin.kill(-processGroupID, SIGKILL)
        }
    }

    fileprivate func nextTerminationRequest() async -> AppServerReadEvent {
        await terminationRequestSignal.next()
    }
}

package enum AppServerProcessFileDescriptorPlan {
    package static func childPipeDescriptorsToClose(_ fileDescriptors: [Int32]) -> [Int32] {
        fileDescriptors.filter { fileDescriptor in
            fileDescriptor != STDIN_FILENO
                && fileDescriptor != STDOUT_FILENO
                && fileDescriptor != STDERR_FILENO
        }
    }
}

package enum AppServerCodexHome {
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

    package static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> Command
    {
        let executable = resolveExecutable(environment: environment)
        return .init(
            executable: executable,
            arguments: appServerArguments()
        )
    }

    package static func resolveExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let requestedCommand =
            [
                environment["CODEX_APP_SERVER_CODEX_EXECUTABLE"],
                environment["CODEX_REVIEW_CODEX_EXECUTABLE"],
                environment["CODEX_EXECUTABLE"],
            ].compactMap(\.self).first ?? "codex"

        return resolveExecutable(requestedCommand, environment: environment)
    }

    package static func resolveExecutable(
        _ requestedCommand: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let candidate = findExecutable(
            requestedCommand,
            environment: environment
        ) {
            return candidate
        }

        return requestedCommand
    }

    package static func appServerArguments() -> [String] {
        [
            "-c", fileBackedAuthConfiguration,
            "app-server",
            "--listen", "stdio://",
        ]
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
            return FileManager.default.isExecutableFile(atPath: trimmedCommand)
                ? trimmedCommand : nil
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

    package static func pathSearchDirectories(environment: [String: String]) -> [String] {
        let environmentDirectories = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        var knownDirectories: [String] = []
        if let homeDirectory = environment["HOME"]?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
           homeDirectory.isEmpty == false {
            // The standalone Codex installer defaults here even when a GUI app's PATH omits it.
            knownDirectories.append(
                URL(fileURLWithPath: homeDirectory, isDirectory: true)
                    .appendingPathComponent(".local/bin", isDirectory: true)
                    .path
            )
        }
        knownDirectories += [
            "/Applications/Codex.app/Contents/Resources",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        var directories: [String] = []
        for directory in environmentDirectories + knownDirectories
        where directories.contains(directory) == false {
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
