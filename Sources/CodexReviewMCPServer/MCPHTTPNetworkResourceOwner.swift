import Foundation
@preconcurrency import NIOCore

package protocol MCPHTTPConnectionResource: AnyObject, Sendable {
    func signalClose()
    func installCloseAcknowledgement(_ acknowledgement: @escaping @Sendable () -> Void)
}

private final class NIOHTTPConnectionResource: MCPHTTPConnectionResource, @unchecked Sendable {
    private let channel: any Channel

    init(channel: any Channel) {
        self.channel = channel
    }

    func signalClose() {
        channel.close(mode: .all, promise: nil)
    }

    func installCloseAcknowledgement(_ acknowledgement: @escaping @Sendable () -> Void) {
        channel.closeFuture.whenComplete { _ in
            acknowledgement()
        }
    }
}

package final class MCPHTTPNetworkResourceOwner: @unchecked Sendable {
    package enum TerminalCause: Equatable, Sendable {
        case serverStop
        case peerClosed
        case transportFailure(String)
    }

    package enum GenerationPhase: Equatable, Sendable {
        case accepting
        case admissionClosed
        case closing(TerminalCause)
        case closed
    }

    package enum ConnectionPhase: Equatable, Sendable {
        case accepting
        case admissionClosed
        case closing(TerminalCause)
        case closed
    }

    package enum RequestWorkPhase: Equatable, Sendable {
        case reserved
        case installed
        case running
        case closing(TerminalCause)
        case closed(TerminalCause?)
    }

    package struct RequestSnapshot: Equatable, Sendable {
        package let id: UUID
        package let admissionOrdinal: UInt64
        package let phase: RequestWorkPhase
    }

    package struct ConnectionSnapshot: Equatable, Sendable {
        package let id: UUID
        package let admissionOrdinal: UInt64
        package let phase: ConnectionPhase
        package let closeAcknowledged: Bool
        package let requests: [RequestSnapshot]
    }

    package struct Snapshot: Equatable, Sendable {
        package let generationID: UInt64
        package let phase: GenerationPhase
        package let connections: [ConnectionSnapshot]

        package var isClosed: Bool {
            phase == .closed && connections.isEmpty
        }
    }

    package final class WorkLease: @unchecked Sendable {
        fileprivate let id: UUID
        private weak var operation: RequestOperation?

        fileprivate init(operation: RequestOperation, id: UUID) {
            self.id = id
            self.operation = operation
        }

        package func install(_ task: Task<Void, Never>) {
            operation?.install(task: task, leaseID: id)
        }

        package func waitUntilStartIsAllowed() async -> Bool {
            guard let operation else {
                return false
            }
            return await operation.waitUntilStartIsAllowed(leaseID: id)
        }

        package func acknowledgeCompletion() {
            operation?.acknowledgeCompletion(leaseID: id)
        }
    }

    package final class RequestOperation: @unchecked Sendable {
        private enum WorkState {
            case reserved
            case installed(@Sendable () -> Void)
            case running(@Sendable () -> Void)
            case acknowledged
        }

        package let id = UUID()
        package let admissionOrdinal: UInt64
        private weak var connection: Connection?
        private let lock = NSLock()
        private let leaseID: UUID
        private var workState: WorkState = .reserved
        private var terminalCause: TerminalCause?
        private var startWasRequested = false
        private var startWaiter: CheckedContinuation<Bool, Never>?
        private var closeWaiters: [CheckedContinuation<TerminalCause?, Never>] = []

        fileprivate init(admissionOrdinal: UInt64, connection: Connection) {
            self.admissionOrdinal = admissionOrdinal
            self.connection = connection
            let leaseID = UUID()
            self.leaseID = leaseID
        }

        fileprivate func makeLease() -> WorkLease {
            WorkLease(operation: self, id: leaseID)
        }

        fileprivate func beginClosing(_ cause: TerminalCause) {
            var cancellation: (@Sendable () -> Void)?
            var waiter: CheckedContinuation<Bool, Never>?
            lock.lock()
            if terminalCause == nil {
                terminalCause = cause
            }
            switch workState {
            case .installed(let cancel), .running(let cancel):
                cancellation = cancel
                waiter = startWaiter
                startWaiter = nil
            case .reserved, .acknowledged:
                break
            }
            lock.unlock()
            cancellation?()
            waiter?.resume(returning: false)
        }

        package func waitUntilClosed() async -> TerminalCause? {
            await withCheckedContinuation { continuation in
                lock.lock()
                if case .acknowledged = workState {
                    let cause = terminalCause
                    lock.unlock()
                    continuation.resume(returning: cause)
                } else {
                    closeWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        fileprivate func install(task: Task<Void, Never>, leaseID: UUID) {
            var shouldCancel = false
            var waiter: CheckedContinuation<Bool, Never>?
            lock.lock()
            precondition(self.leaseID == leaseID, "A request WorkLease belongs to exactly one admitted operation.")
            guard case .reserved = workState else {
                lock.unlock()
                preconditionFailure("A request WorkLease can be installed exactly once.")
            }
            let cancellation: @Sendable () -> Void = { task.cancel() }
            if startWasRequested {
                waiter = startWaiter
                startWaiter = nil
                if terminalCause == nil {
                    workState = .running(cancellation)
                } else {
                    workState = .installed(cancellation)
                    shouldCancel = true
                }
            } else {
                workState = .installed(cancellation)
                shouldCancel = terminalCause != nil
            }
            lock.unlock()
            if shouldCancel {
                task.cancel()
            }
            waiter?.resume(returning: shouldCancel == false)
        }

        fileprivate func waitUntilStartIsAllowed(leaseID: UUID) async -> Bool {
            await withCheckedContinuation { continuation in
                var cancellation: (@Sendable () -> Void)?
                lock.lock()
                precondition(self.leaseID == leaseID, "A request WorkLease belongs to exactly one admitted operation.")
                precondition(startWasRequested == false, "A request WorkLease can start exactly once.")
                startWasRequested = true
                switch workState {
                case .reserved:
                    startWaiter = continuation
                    lock.unlock()
                case .installed(let cancel):
                    if terminalCause == nil {
                        workState = .running(cancel)
                        lock.unlock()
                        continuation.resume(returning: true)
                    } else {
                        cancellation = cancel
                        lock.unlock()
                        cancellation?()
                        continuation.resume(returning: false)
                    }
                case .running, .acknowledged:
                    lock.unlock()
                    preconditionFailure("A request WorkLease can start exactly once.")
                }
            }
        }

        fileprivate func acknowledgeCompletion(leaseID: UUID) {
            let waiters: [CheckedContinuation<TerminalCause?, Never>]
            let cause: TerminalCause?
            lock.lock()
            precondition(self.leaseID == leaseID, "A request WorkLease belongs to exactly one admitted operation.")
            guard case .acknowledged = workState else {
                workState = .acknowledged
                cause = terminalCause
                waiters = closeWaiters
                closeWaiters.removeAll(keepingCapacity: false)
                lock.unlock()
                for waiter in waiters {
                    waiter.resume(returning: cause)
                }
                connection?.requestDidClose(self)
                return
            }
            lock.unlock()
        }

        fileprivate func snapshot() -> RequestSnapshot {
            lock.lock()
            let phase: RequestWorkPhase
            switch workState {
            case .reserved:
                phase = terminalCause.map(RequestWorkPhase.closing) ?? .reserved
            case .installed:
                phase = terminalCause.map(RequestWorkPhase.closing) ?? .installed
            case .running:
                phase = terminalCause.map(RequestWorkPhase.closing) ?? .running
            case .acknowledged:
                phase = .closed(terminalCause)
            }
            lock.unlock()
            return .init(id: id, admissionOrdinal: admissionOrdinal, phase: phase)
        }
    }

    package final class Connection: @unchecked Sendable {
        package struct AdmittedRequest: Sendable {
            package let operation: RequestOperation
            package let lease: WorkLease
        }

        package let id = UUID()
        package let admissionOrdinal: UInt64
        private weak var owner: MCPHTTPNetworkResourceOwner?
        private let resource: any MCPHTTPConnectionResource
        private let lock = NSLock()
        private var phase: ConnectionPhase = .accepting
        private var nextRequestOrdinal: UInt64 = 0
        private var requests: [UUID: RequestOperation] = [:]
        private var closeAcknowledged = false
        private var closeWaiters: [CheckedContinuation<Void, Never>] = []

        fileprivate init(
            admissionOrdinal: UInt64,
            resource: any MCPHTTPConnectionResource,
            owner: MCPHTTPNetworkResourceOwner
        ) {
            self.admissionOrdinal = admissionOrdinal
            self.resource = resource
            self.owner = owner
        }

        fileprivate func installCloseAcknowledgement() {
            resource.installCloseAcknowledgement { [weak self] in
                self?.acknowledgePeerClose()
            }
        }

        package func admitRequest(finalForConnection: Bool = false) -> AdmittedRequest? {
            lock.lock()
            guard phase == .accepting else {
                lock.unlock()
                return nil
            }
            nextRequestOrdinal &+= 1
            let operation = RequestOperation(
                admissionOrdinal: nextRequestOrdinal,
                connection: self
            )
            let lease = operation.makeLease()
            requests[operation.id] = operation
            if finalForConnection {
                phase = .admissionClosed
            }
            lock.unlock()
            return .init(operation: operation, lease: lease)
        }

        package func peerClosed() {
            beginClosing(.peerClosed, signalResourceClose: false)
        }

        package func transportFailed(_ message: String) {
            beginClosing(.transportFailure(message), signalResourceClose: true)
        }

        package func waitUntilClosed() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if phase == .closed {
                    lock.unlock()
                    continuation.resume()
                } else {
                    closeWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        package func closeAdmission() {
            lock.lock()
            if phase == .accepting {
                phase = .admissionClosed
            }
            lock.unlock()
        }

        fileprivate func beginClosing(_ cause: TerminalCause) {
            beginClosing(cause, signalResourceClose: true)
        }

        fileprivate func requestDidClose(_ operation: RequestOperation) {
            var didClose = false
            var waiters: [CheckedContinuation<Void, Never>] = []
            lock.lock()
            requests.removeValue(forKey: operation.id)
            if case .closing = phase, closeAcknowledged, requests.isEmpty {
                phase = .closed
                waiters = closeWaiters
                closeWaiters.removeAll(keepingCapacity: false)
                didClose = true
            }
            lock.unlock()
            for waiter in waiters {
                waiter.resume()
            }
            if didClose {
                owner?.connectionDidClose(self)
            }
        }

        fileprivate func snapshot() -> ConnectionSnapshot {
            lock.lock()
            let phase = phase
            let closeAcknowledged = closeAcknowledged
            let requests = requests.values.sorted {
                $0.admissionOrdinal < $1.admissionOrdinal
            }
            lock.unlock()
            return .init(
                id: id,
                admissionOrdinal: admissionOrdinal,
                phase: phase,
                closeAcknowledged: closeAcknowledged,
                requests: requests.map { $0.snapshot() }
            )
        }

        private func beginClosing(
            _ cause: TerminalCause,
            signalResourceClose: Bool
        ) {
            let requests: [RequestOperation]
            var shouldSignalClose = false
            lock.lock()
            switch phase {
            case .accepting, .admissionClosed:
                phase = .closing(cause)
                requests = Array(self.requests.values)
                shouldSignalClose = signalResourceClose
            case .closing, .closed:
                requests = []
            }
            lock.unlock()
            for request in requests {
                request.beginClosing(cause)
            }
            if shouldSignalClose {
                resource.signalClose()
            }
            finishIfQuiescent()
        }

        private func acknowledgePeerClose() {
            let requests: [RequestOperation]
            lock.lock()
            closeAcknowledged = true
            switch phase {
            case .accepting, .admissionClosed:
                phase = .closing(.peerClosed)
                requests = Array(self.requests.values)
            case .closing, .closed:
                requests = []
            }
            lock.unlock()
            for request in requests {
                request.beginClosing(.peerClosed)
            }
            finishIfQuiescent()
        }

        private func finishIfQuiescent() {
            var didClose = false
            var waiters: [CheckedContinuation<Void, Never>] = []
            lock.lock()
            if case .closing = phase, closeAcknowledged, requests.isEmpty {
                phase = .closed
                waiters = closeWaiters
                closeWaiters.removeAll(keepingCapacity: false)
                didClose = true
            }
            lock.unlock()
            for waiter in waiters {
                waiter.resume()
            }
            if didClose {
                owner?.connectionDidClose(self)
            }
        }
    }

    package final class ClosingGeneration: @unchecked Sendable {
        private weak var owner: MCPHTTPNetworkResourceOwner?

        fileprivate init(owner: MCPHTTPNetworkResourceOwner) {
            self.owner = owner
        }

        package func waitUntilClosed() async {
            await owner?.waitUntilClosed()
        }
    }

    private struct GenerationState {
        var connections: [UUID: Connection]
    }

    private enum State {
        case accepting(GenerationState)
        case admissionClosed(GenerationState)
        case closing(GenerationState, TerminalCause)
        case closed
    }

    package let generationID: UInt64
    private let lock = NSLock()
    private var state: State = .accepting(.init(connections: [:]))
    private var nextConnectionOrdinal: UInt64 = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    package init(generationID: UInt64) {
        self.generationID = generationID
    }

    func admitConnection(_ channel: any Channel) -> Connection? {
        admitConnection(NIOHTTPConnectionResource(channel: channel))
    }

    package func admitConnection(_ resource: any MCPHTTPConnectionResource) -> Connection? {
        lock.lock()
        guard case .accepting(var accepting) = state else {
            lock.unlock()
            resource.signalClose()
            return nil
        }
        nextConnectionOrdinal &+= 1
        let connection = Connection(
            admissionOrdinal: nextConnectionOrdinal,
            resource: resource,
            owner: self
        )
        accepting.connections[connection.id] = connection
        state = .accepting(accepting)
        lock.unlock()
        connection.installCloseAcknowledgement()
        return connection
    }

    package func closeAdmission() {
        let connections: [Connection]
        lock.lock()
        switch state {
        case .accepting(let accepting):
            state = .admissionClosed(accepting)
            connections = Array(accepting.connections.values)
        case .admissionClosed(let current), .closing(let current, _):
            connections = Array(current.connections.values)
        case .closed:
            connections = []
        }
        lock.unlock()
        for connection in connections {
            connection.closeAdmission()
        }
    }

    package func beginClosing(_ cause: TerminalCause) -> ClosingGeneration {
        let connections: [Connection]
        let effectiveCause: TerminalCause
        var waiters: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        switch state {
        case .accepting(let current), .admissionClosed(let current):
            effectiveCause = cause
            if current.connections.isEmpty {
                state = .closed
                connections = []
                waiters = closeWaiters
                closeWaiters.removeAll(keepingCapacity: false)
            } else {
                state = .closing(current, cause)
                connections = current.connections.values.sorted {
                    $0.admissionOrdinal < $1.admissionOrdinal
                }
            }
        case .closing(let current, let firstCause):
            effectiveCause = firstCause
            connections = current.connections.values.sorted {
                $0.admissionOrdinal < $1.admissionOrdinal
            }
        case .closed:
            effectiveCause = cause
            connections = []
        }
        lock.unlock()
        for connection in connections {
            connection.beginClosing(effectiveCause)
        }
        for waiter in waiters {
            waiter.resume()
        }
        return ClosingGeneration(owner: self)
    }

    package func snapshot() -> Snapshot {
        lock.lock()
        let phase: GenerationPhase
        let connections: [Connection]
        switch state {
        case .accepting(let current):
            phase = .accepting
            connections = Array(current.connections.values)
        case .admissionClosed(let current):
            phase = .admissionClosed
            connections = Array(current.connections.values)
        case .closing(let current, let cause):
            phase = .closing(cause)
            connections = Array(current.connections.values)
        case .closed:
            phase = .closed
            connections = []
        }
        lock.unlock()
        return .init(
            generationID: generationID,
            phase: phase,
            connections: connections.sorted {
                $0.admissionOrdinal < $1.admissionOrdinal
            }.map { $0.snapshot() }
        )
    }

    fileprivate func connectionDidClose(_ connection: Connection) {
        var waiters: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        switch state {
        case .accepting(var current):
            current.connections.removeValue(forKey: connection.id)
            state = .accepting(current)
        case .admissionClosed(var current):
            current.connections.removeValue(forKey: connection.id)
            state = .admissionClosed(current)
        case .closing(var current, let cause):
            current.connections.removeValue(forKey: connection.id)
            if current.connections.isEmpty {
                state = .closed
                waiters = closeWaiters
                closeWaiters.removeAll(keepingCapacity: false)
            } else {
                state = .closing(current, cause)
            }
        case .closed:
            break
        }
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitUntilClosed() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if case .closed = state {
                lock.unlock()
                continuation.resume()
            } else {
                closeWaiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
