import Foundation

package enum ServerRequestTaskContext {
    package struct Value: Equatable, Sendable {
        package var requestID: CodexServerRequestID
        package var token: UUID
    }

    @TaskLocal package static var value: Value?
}

package actor ServerRequestRegistry {
    package enum Diagnostic: Equatable, Sendable {
        case duplicateRequest(CodexServerRequestID)
        case rejectedWhileClosing(CodexServerRequestID, method: String)
        case decodeFailed(CodexServerRequestID, method: String, message: String)
        case handlerFailed(CodexServerRequestID, method: String, message: String)
        case responseFailed(CodexServerRequestID, method: String, message: String)
        case ownedTaskRequestedClose(CodexServerRequestID)
    }

    package typealias Responder =
        @Sendable (CodexServerRequestID, CodexServerRequestResponse) async throws -> Void
    package typealias DiagnosticHandler = @Sendable (Diagnostic) -> Void

    private enum Phase: Equatable {
        case open
        case closing
        case closed
    }

    private struct Entry {
        var token: UUID
        var task: Task<Void, Never>
        var suppressesResponse: Bool
        var hasCommittedResponse: Bool
    }

    private let codec: CodexAppServerRequestCodec
    private let connectionEventHub: ConnectionEventHub
    private let handler: CodexAppServerRequestHandler
    private let responder: Responder
    private let diagnosticHandler: DiagnosticHandler
    private var phase: Phase = .open
    private var entries: [CodexServerRequestID: Entry] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var receivedEventCount = 0
    private var receiveCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    package init(
        codec: CodexAppServerRequestCodec = .init(),
        connectionEventHub: ConnectionEventHub,
        handler: @escaping CodexAppServerRequestHandler,
        responder: @escaping Responder,
        diagnosticHandler: @escaping DiagnosticHandler = { _ in }
    ) {
        self.codec = codec
        self.connectionEventHub = connectionEventHub
        self.handler = handler
        self.responder = responder
        self.diagnosticHandler = diagnosticHandler
    }

    package func receive(
        id: CodexServerRequestID,
        method: String,
        params: Data
    ) async {
        receivedEventCount += 1
        resumeReceiveCountWaiters()
        guard phase == .open else {
            emitDiagnostic(.rejectedWhileClosing(id, method: method))
            return
        }
        guard entries[id] == nil else {
            emitDiagnostic(.duplicateRequest(id))
            return
        }

        let token = UUID()
        let context = ServerRequestTaskContext.Value(requestID: id, token: token)
        let task = Task { [weak self, params] in
            await ServerRequestTaskContext.$value.withValue(context) {
                guard let self else {
                    return
                }
                await self.runRequest(
                    id: id,
                    token: token,
                    method: method,
                    params: params
                )
            }
        }
        entries[id] = .init(
            token: token,
            task: task,
            suppressesResponse: false,
            hasCommittedResponse: false
        )
    }

    package func resolve(_ id: CodexServerRequestID) async {
        guard var entry = entries[id] else {
            return
        }
        if entry.hasCommittedResponse == false {
            entry.suppressesResponse = true
        }
        entries[id] = entry
        entry.task.cancel()
        await entry.task.value
        removeEntryIfMatching(id: id, token: entry.token)
    }

    package func cancelAllAndWait() async {
        if phase == .open {
            phase = .closing
        }
        guard phase != .closed else {
            return
        }

        let snapshot = entries
        for (id, var entry) in snapshot {
            if entry.hasCommittedResponse == false {
                entry.suppressesResponse = true
            }
            entries[id] = entry
            entry.task.cancel()
        }

        for (id, entry) in snapshot {
            await entry.task.value
            removeEntryIfMatching(id: id, token: entry.token)
        }

        entries.removeAll(keepingCapacity: false)
        phase = .closed
        resumeIdleWaitersIfNeeded()
    }

    package func beginClosing() {
        if phase == .open {
            phase = .closing
        }
    }

    package func signalCloseIfOwned(by context: ServerRequestTaskContext.Value) -> Bool {
        guard let ownedEntry = entries[context.requestID],
              ownedEntry.token == context.token else {
            return false
        }

        if phase == .open {
            phase = .closing
        }
        guard phase != .closed else {
            return false
        }

        for (id, var entry) in entries {
            if entry.hasCommittedResponse == false {
                entry.suppressesResponse = true
            }
            entries[id] = entry
            entry.task.cancel()
        }
        emitDiagnostic(.ownedTaskRequestedClose(context.requestID))
        return true
    }

    package func childCount() -> Int {
        entries.count
    }

    package func waitUntilIdle() async {
        guard entries.isEmpty == false else {
            return
        }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    package func waitForReceivedEventCount(atLeast minimumCount: Int) async {
        guard receivedEventCount < minimumCount else {
            return
        }
        await withCheckedContinuation { continuation in
            receiveCountWaiters.append((minimumCount, continuation))
        }
    }

    private func runRequest(
        id: CodexServerRequestID,
        token: UUID,
        method: String,
        params: Data
    ) async {
        guard Task.isCancelled == false else {
            finishSuppressed(id: id, token: token)
            return
        }

        let request: CodexAppServerRequest
        do {
            request = try codec.decode(method: method, params: params)
        } catch {
            guard Task.isCancelled == false else {
                finishSuppressed(id: id, token: token)
                return
            }
            emitDiagnostic(.decodeFailed(
                id,
                method: method,
                message: error.localizedDescription
            ))
            await complete(
                id: id,
                token: token,
                method: method,
                response: CodexAppServerRequestCodec.internalError(
                    "Failed to decode \(method): \(error.localizedDescription)"
                )
            )
            return
        }

        let response: CodexServerRequestResponse
        do {
            let resolution = try await handler(request)
            guard Task.isCancelled == false else {
                finishSuppressed(id: id, token: token)
                return
            }
            response = codec.response(to: request, resolution: resolution)
        } catch {
            guard Task.isCancelled == false else {
                finishSuppressed(id: id, token: token)
                return
            }
            emitDiagnostic(.handlerFailed(
                id,
                method: method,
                message: error.localizedDescription
            ))
            response = CodexAppServerRequestCodec.internalError(
                "Handler failed for \(method): \(error.localizedDescription)"
            )
        }

        await complete(id: id, token: token, method: method, response: response)
    }

    private func complete(
        id: CodexServerRequestID,
        token: UUID,
        method: String,
        response: CodexServerRequestResponse
    ) async {
        guard phase == .open,
              var entry = entries[id],
              entry.token == token,
              entry.suppressesResponse == false else {
            finishSuppressed(id: id, token: token)
            return
        }
        entry.hasCommittedResponse = true
        entries[id] = entry
        await writeResponse(id: id, method: method, response: response)
        removeEntryIfMatching(id: id, token: token)
        resumeIdleWaitersIfNeeded()
    }

    private func finishSuppressed(id: CodexServerRequestID, token: UUID) {
        removeEntryIfMatching(id: id, token: token)
    }

    private func removeEntryIfMatching(id: CodexServerRequestID, token: UUID) {
        guard entries[id]?.token == token else {
            return
        }
        entries.removeValue(forKey: id)
        if phase == .closing, entries.isEmpty {
            phase = .closed
        }
        resumeIdleWaitersIfNeeded()
    }

    private func writeResponse(
        id: CodexServerRequestID,
        method: String,
        response: CodexServerRequestResponse
    ) async {
        do {
            try await responder(id, response)
        } catch {
            emitDiagnostic(.responseFailed(
                id,
                method: method,
                message: error.localizedDescription
            ))
        }
    }

    private func resumeIdleWaitersIfNeeded() {
        guard entries.isEmpty else {
            return
        }
        let waiters = idleWaiters
        idleWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func emitDiagnostic(_ diagnostic: Diagnostic) {
        connectionEventHub.yield(.warning(
            ConnectionDiagnosticFactory.serverRequestRegistry(diagnostic)
        ))
        diagnosticHandler(diagnostic)
    }

    private func resumeReceiveCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in receiveCountWaiters {
            if receivedEventCount >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        receiveCountWaiters = remaining
    }
}

package struct CodexServerRequestResolvedNotification: Decodable, Sendable {
    package var threadID: String
    package var requestID: CodexServerRequestID

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case requestID = "requestId"
    }
}
