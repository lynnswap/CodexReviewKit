import Foundation
import Synchronization

/// A connection-scoped diagnostic or terminal event emitted by Codex app-server.
public enum CodexConnectionEvent: Equatable, Sendable {
    case warning(CodexDiagnostic)
    case retrying(CodexRetryDiagnostic)
    case deprecation(CodexDeprecationNotice)
    case unknown(CodexRawNotification)
    case terminated(CodexConnectionTermination)
}

/// A user-visible warning associated with the app-server connection.
public struct CodexDiagnostic: Equatable, Sendable {
    public let message: String
    public let method: String?
    public let details: String?

    package init(message: String, method: String? = nil, details: String? = nil) {
        self.message = message
        self.method = method
        self.details = details
    }
}

/// A scheduled retry after an app-server overload response.
public struct CodexRetryDiagnostic: Equatable, Sendable {
    public let requestID: Int
    public let method: String
    public let attempt: Int
    public let delay: Duration
    public let serverError: CodexServerError

    package init(
        requestID: Int,
        method: String,
        attempt: Int,
        delay: Duration,
        serverError: CodexServerError
    ) {
        precondition(attempt > 0, "A retry attempt is one-based.")
        self.requestID = requestID
        self.method = method
        self.attempt = attempt
        self.delay = delay
        self.serverError = serverError
    }
}

/// A deprecation notice emitted by the pinned app-server protocol.
public struct CodexDeprecationNotice: Equatable, Sendable {
    public let summary: String
    public let details: String?

    package init(summary: String, details: String? = nil) {
        self.summary = summary
        self.details = details
    }
}

/// A root-bound, connection-scoped event subscription.
///
/// The subscription does not retain the connection, its supervisor, or a connection lease.
/// Cancelling iteration only releases this subscriber.
/// Each subscriber keeps the newest 32 pending diagnostics. A terminal event supersedes
/// pending diagnostics, is delivered exactly once, and is the only event replayed to a late
/// subscriber.
public struct CodexConnectionEvents: AsyncSequence, Sendable {
    public typealias Element = CodexConnectionEvent

    private let channel: ConnectionEventSubscriberChannel
    private let cancellation: ConnectionEventSubscriptionCancellation

    fileprivate init(
        channel: ConnectionEventSubscriberChannel,
        cancellation: ConnectionEventSubscriptionCancellation
    ) {
        self.channel = channel
        self.cancellation = cancellation
    }

    public func makeAsyncIterator() -> Iterator {
        .init(channel: channel, cancellation: cancellation)
    }

    public func cancel() async {
        cancellation.cancel()
    }

    package func waitUntilNextSuspendsForTesting() async {
        await channel.waitUntilNextSuspendsForTesting()
    }

    package func claimNextCallForTesting() -> Bool {
        channel.tryBeginNext()
    }

    package func endNextCallForTesting() {
        channel.endNext()
    }

    public struct Iterator: AsyncIteratorProtocol {
        private let channel: ConnectionEventSubscriberChannel
        private let cancellation: ConnectionEventSubscriptionCancellation

        fileprivate init(
            channel: ConnectionEventSubscriberChannel,
            cancellation: ConnectionEventSubscriptionCancellation
        ) {
            self.channel = channel
            self.cancellation = cancellation
        }

        public mutating func next() async -> CodexConnectionEvent? {
            await channel.next(cancellation: cancellation)
        }
    }
}

/// Owns connection diagnostic fan-out and compact terminal replay.
///
/// The termination winner is supplied by `ConnectionTerminationArbiter`; this hub never
/// arbitrates or replaces it.
package final class ConnectionEventHub: Sendable {
    package struct Snapshot: Equatable, Sendable {
        package var subscriberCount: Int
        package var terminal: CodexConnectionTermination?
    }

    private let subscriptionRegistry = ConnectionEventSubscriptionRegistry()

    package init() {}

    deinit {
        subscriptionRegistry.cancelAll()
    }

    package func events() -> CodexConnectionEvents {
        subscriptionRegistry.makeEvents()
    }

    package func yield(_ event: CodexConnectionEvent) {
        if case .terminated = event {
            preconditionFailure("Connection terminal delivery must use finish(with:).")
        }
        subscriptionRegistry.yield(event)
    }

    package func finish(with termination: CodexConnectionTermination) {
        subscriptionRegistry.finish(with: termination)
    }

    package func snapshotForTesting() -> Snapshot {
        subscriptionRegistry.snapshot()
    }
}

package enum ConnectionDiagnosticFactory {
    package enum ProcessStderrFailureStage {
        case setup
        case read
    }

    package static func routingFailure(
        message: String,
        method: String? = nil
    ) -> CodexDiagnostic {
        .init(message: message, method: method)
    }

    package static func droppedNotification(method: String) -> CodexDiagnostic {
        .init(
            message: "Dropped notification while draining responses after routing failure.",
            method: method
        )
    }

    package static func droppedServerRequest(
        id: CodexServerRequestID,
        method: String
    ) -> CodexDiagnostic {
        .init(
            message: "Dropped server request while draining responses after routing failure.",
            method: method,
            details: "requestId: \(requestIDDescription(id))"
        )
    }

    package static func lateResponse(requestID: Int) -> CodexDiagnostic {
        .init(
            message: "Ignored late JSON-RPC response after outbound close.",
            details: "requestId: \(requestID)"
        )
    }

    package static func processStderrFailure(
        _ stage: ProcessStderrFailureStage,
        details: String
    ) -> CodexDiagnostic {
        let message = switch stage {
        case .setup: "App-server stderr setup failed."
        case .read: "App-server stderr read failed."
        }
        return .init(message: message, method: "process/stderr", details: details)
    }

    package static func processStderr(_ event: AppServerStderrLogFilter.Event) -> CodexDiagnostic {
        let severity = switch event.level {
        case .error: "error"
        case .warning: "warning"
        }
        return .init(
            message: event.message,
            method: "process/stderr",
            details: "severity: \(severity)"
        )
    }

    package static func lateTermination(
        winner: CodexConnectionTermination,
        candidate: CodexConnectionTermination
    ) -> CodexDiagnostic {
        .init(
            message: "Ignored late connection termination.",
            details: "winner: \(String(describing: winner)); candidate: \(String(describing: candidate))"
        )
    }

    package static func serverRequestRegistry(
        _ diagnostic: ServerRequestRegistry.Diagnostic
    ) -> CodexDiagnostic {
        switch diagnostic {
        case .duplicateRequest(let id):
            .init(
                message: "Received a duplicate server-request identifier.",
                details: "requestId: \(requestIDDescription(id))"
            )
        case .rejectedWhileClosing(let id, let method):
            .init(
                message: "Rejected a server request while the connection was closing.",
                method: method,
                details: "requestId: \(requestIDDescription(id))"
            )
        case .decodeFailed(let id, let method, let message):
            .init(
                message: "Failed to decode a server request.",
                method: method,
                details: "requestId: \(requestIDDescription(id)); \(message)"
            )
        case .handlerFailed(let id, let method, let message):
            .init(
                message: "Server-request handler failed.",
                method: method,
                details: "requestId: \(requestIDDescription(id)); \(message)"
            )
        case .responseFailed(let id, let method, let message):
            .init(
                message: "Failed to write a server-request response.",
                method: method,
                details: "requestId: \(requestIDDescription(id)); \(message)"
            )
        case .ownedTaskRequestedClose(let id):
            .init(
                message: "A server-request handler requested connection close.",
                details: "requestId: \(requestIDDescription(id))"
            )
        }
    }

    private static func requestIDDescription(_ id: CodexServerRequestID) -> String {
        switch id {
        case .integer(let value): String(value)
        case .string(let value): value
        }
    }
}

private final class ConnectionEventSubscriberChannel: Sendable {
    private enum Phase {
        case open
        case terminalPending(CodexConnectionTermination)
        case finished(CodexConnectionTermination)
        case cancelled
    }

    private struct State {
        var pending: [CodexConnectionEvent] = []
        var waiter: CheckedContinuation<CodexConnectionEvent?, Never>?
        var suspensionObservers: [CheckedContinuation<Void, Never>] = []
        var nextIsActive = false
        var phase = Phase.open
    }

    private static let diagnosticCapacity = 32
    private let state = Mutex(State())

    func yield(_ event: CodexConnectionEvent) {
        let waiter = state.withLock { state -> CheckedContinuation<
            CodexConnectionEvent?, Never
        >? in
            guard case .open = state.phase else {
                return nil
            }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            if state.pending.count == Self.diagnosticCapacity {
                state.pending.removeFirst()
            }
            state.pending.append(event)
            return nil
        }
        waiter?.resume(returning: event)
    }

    func finish(with termination: CodexConnectionTermination) {
        let completion = state.withLock { state -> (
            CheckedContinuation<CodexConnectionEvent?, Never>?,
            [CheckedContinuation<Void, Never>]
        ) in
            switch state.phase {
            case .open:
                state.pending.removeAll(keepingCapacity: false)
                let waiter = state.waiter
                state.waiter = nil
                let observers = state.suspensionObservers
                state.suspensionObservers.removeAll(keepingCapacity: false)
                state.phase = waiter == nil ? .terminalPending(termination) : .finished(termination)
                return (waiter, observers)
            case .terminalPending(let existing), .finished(let existing):
                precondition(
                    existing == termination,
                    "A connection subscriber cannot receive conflicting terminal reasons."
                )
                return (nil, [])
            case .cancelled:
                return (nil, [])
            }
        }
        for observer in completion.1 {
            observer.resume()
        }
        completion.0?.resume(returning: .terminated(termination))
    }

    func cancel() {
        let completion = state.withLock { state -> (
            CheckedContinuation<CodexConnectionEvent?, Never>?,
            [CheckedContinuation<Void, Never>]
        ) in
            guard case .cancelled = state.phase else {
                if case .finished = state.phase {
                    return (nil, [])
                }
                state.phase = .cancelled
                state.pending.removeAll(keepingCapacity: false)
                let waiter = state.waiter
                state.waiter = nil
                let observers = state.suspensionObservers
                state.suspensionObservers.removeAll(keepingCapacity: false)
                return (waiter, observers)
            }
            return (nil, [])
        }
        for observer in completion.1 {
            observer.resume()
        }
        completion.0?.resume(returning: nil)
    }

    func next(
        cancellation: ConnectionEventSubscriptionCancellation
    ) async -> CodexConnectionEvent? {
        precondition(
            tryBeginNext(),
            "CodexConnectionEvents supports one in-flight next() call."
        )
        defer { endNext() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let registration = state.withLock { state -> (
                    CodexConnectionEvent??,
                    [CheckedContinuation<Void, Never>]
                ) in
                    if state.pending.isEmpty == false {
                        return (state.pending.removeFirst(), [])
                    }
                    switch state.phase {
                    case .open:
                        precondition(state.waiter == nil)
                        state.waiter = continuation
                        let observers = state.suspensionObservers
                        state.suspensionObservers.removeAll(keepingCapacity: false)
                        return (nil, observers)
                    case .terminalPending(let termination):
                        state.phase = .finished(termination)
                        return (.some(.terminated(termination)), [])
                    case .finished, .cancelled:
                        return (.some(nil), [])
                    }
                }
                for observer in registration.1 {
                    observer.resume()
                }
                if let immediate = registration.0 {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func tryBeginNext() -> Bool {
        state.withLock { state in
            guard state.nextIsActive == false else {
                return false
            }
            state.nextIsActive = true
            return true
        }
    }

    func endNext() {
        state.withLock { state in
            precondition(state.nextIsActive, "A next() call must own the channel before ending.")
            state.nextIsActive = false
        }
    }

    func waitUntilNextSuspendsForTesting() async {
        await withCheckedContinuation { continuation in
            let isAlreadySuspendedOrFinished = state.withLock { state in
                if state.waiter != nil {
                    return true
                }
                guard case .open = state.phase else {
                    return true
                }
                state.suspensionObservers.append(continuation)
                return false
            }
            if isAlreadySuspendedOrFinished {
                continuation.resume()
            }
        }
    }
}

private final class ConnectionEventSubscriptionCancellation: Sendable {
    private struct State {
        var isCancelled = false
    }

    private let state = Mutex(State())
    private let id: UUID
    private let registry: ConnectionEventSubscriptionRegistry

    init(id: UUID, registry: ConnectionEventSubscriptionRegistry) {
        self.id = id
        self.registry = registry
    }

    func cancel() {
        let shouldRemove = state.withLock { state in
            guard state.isCancelled == false else {
                return false
            }
            state.isCancelled = true
            return true
        }
        if shouldRemove {
            registry.remove(id)
        }
    }

    deinit {
        cancel()
    }
}

private final class ConnectionEventSubscriptionRegistry: Sendable {
    private struct State {
        var channels: [UUID: ConnectionEventSubscriberChannel] = [:]
        var terminal: CodexConnectionTermination?
    }

    private let state = Mutex(State())
    // `remove` and `cancelAll` must never acquire `delivery`: channel completion can wait on a
    // subscriber task-status lock while that lock runs its cancellation handler back into remove.
    private let delivery = Mutex(())

    func makeEvents() -> CodexConnectionEvents {
        let id = UUID()
        let channel = ConnectionEventSubscriberChannel()
        let cancellation = ConnectionEventSubscriptionCancellation(id: id, registry: self)
        delivery.withLock { _ in
            let terminal = state.withLock { state -> CodexConnectionTermination? in
                guard let terminal = state.terminal else {
                    state.channels[id] = channel
                    return nil
                }
                return terminal
            }
            if let terminal {
                channel.finish(with: terminal)
            }
        }
        return .init(channel: channel, cancellation: cancellation)
    }

    func yield(_ event: CodexConnectionEvent) {
        delivery.withLock { _ in
            let channels = state.withLock { state -> [ConnectionEventSubscriberChannel] in
                guard state.terminal == nil else {
                    return []
                }
                return Array(state.channels.values)
            }
            for channel in channels {
                channel.yield(event)
            }
        }
    }

    func remove(_ id: UUID) {
        let channel = state.withLock { $0.channels.removeValue(forKey: id) }
        channel?.cancel()
    }

    func finish(with termination: CodexConnectionTermination) {
        delivery.withLock { _ in
            let channels = state.withLock { state -> [ConnectionEventSubscriberChannel] in
                if let existing = state.terminal {
                    precondition(
                        existing == termination,
                        "ConnectionEventHub cannot replace its derived terminal replay."
                    )
                    return []
                }
                state.terminal = termination
                let channels = Array(state.channels.values)
                state.channels.removeAll(keepingCapacity: false)
                return channels
            }
            for channel in channels {
                channel.finish(with: termination)
            }
        }
    }

    func cancelAll() {
        let channels = state.withLock { state -> [ConnectionEventSubscriberChannel] in
            let channels = Array(state.channels.values)
            state.channels.removeAll(keepingCapacity: false)
            return channels
        }
        for channel in channels {
            channel.cancel()
        }
    }

    func snapshot() -> ConnectionEventHub.Snapshot {
        state.withLock { state in
            .init(subscriberCount: state.channels.count, terminal: state.terminal)
        }
    }
}
