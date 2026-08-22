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
        case responding
        case closing(TerminalCause)
        case closed(TerminalCause?)
    }

    package enum ResponseSourceKind: Equatable, Sendable {
        case finite
        case open
    }

    package enum ResponseWorkPhase: Equatable, Sendable {
        case notReserved
        case reserved
        case installed
        case running
        case completed
    }

    package enum ResponseEndPhase: Equatable, Sendable {
        case notExpected
        case pending
        case acknowledged
        case closed
    }

    package struct RequestSnapshot: Equatable, Sendable {
        package let id: UUID
        package let admissionOrdinal: UInt64
        package let phase: RequestWorkPhase
        package let responseSourceKind: ResponseSourceKind?
        package let responseSource: ResponseWorkPhase
        package let writer: ResponseWorkPhase
        package let responseEnd: ResponseEndPhase
        package let responseIsReady: Bool

        package var writerIsRunning: Bool {
            writer == .running
        }

        package var terminalCause: TerminalCause? {
            switch phase {
            case .closing(let cause), .closed(let cause?):
                cause
            case .reserved, .installed, .running, .responding, .closed:
                nil
            }
        }
    }

    package struct ConnectionSnapshot: Equatable, Sendable {
        package let id: UUID
        package let admissionOrdinal: UInt64
        package let phase: ConnectionPhase
        package let closeAcknowledged: Bool
        package let requests: [RequestSnapshot]
    }

    package struct Snapshot: Equatable, Sendable {
        package let revision: UInt64
        package let generationID: UInt64
        package let phase: GenerationPhase
        package let connections: [ConnectionSnapshot]

        package var isClosed: Bool {
            phase == .closed && connections.isEmpty
        }
    }

    fileprivate final class WorkSlot: @unchecked Sendable {
        private enum State {
            case reserved
            case installed(@Sendable () -> Void)
            case running(@Sendable () -> Void)
            case completed
        }

        let id = UUID()
        private weak var operation: RequestOperation?
        private let lock = NSLock()
        private var state: State = .reserved
        private var cancellationWasRequested = false
        private var startWasRequested = false
        private var startWaiter: CheckedContinuation<Bool, Never>?

        func attach(to operation: RequestOperation) {
            precondition(self.operation == nil)
            self.operation = operation
        }

        func makeLease() -> WorkLease {
            WorkLease(slot: self, id: id)
        }

        func requestCancellation() {
            var cancellation: (@Sendable () -> Void)?
            var waiter: CheckedContinuation<Bool, Never>?
            lock.lock()
            cancellationWasRequested = true
            switch state {
            case .installed(let cancel), .running(let cancel):
                cancellation = cancel
                waiter = startWaiter
                startWaiter = nil
            case .reserved, .completed:
                break
            }
            lock.unlock()
            cancellation?()
            waiter?.resume(returning: false)
        }

        func install(task: Task<Void, Never>, leaseID: UUID) {
            var shouldCancel = false
            var waiter: CheckedContinuation<Bool, Never>?
            lock.lock()
            precondition(id == leaseID, "A WorkLease belongs to exactly one response operation slot.")
            guard case .reserved = state else {
                lock.unlock()
                preconditionFailure("A WorkLease can be installed exactly once.")
            }
            let cancellation: @Sendable () -> Void = { task.cancel() }
            if startWasRequested {
                waiter = startWaiter
                startWaiter = nil
                if cancellationWasRequested == false {
                    state = .running(cancellation)
                } else {
                    state = .installed(cancellation)
                    shouldCancel = true
                }
            } else {
                state = .installed(cancellation)
                shouldCancel = cancellationWasRequested
            }
            lock.unlock()
            if shouldCancel {
                task.cancel()
            }
            waiter?.resume(returning: shouldCancel == false)
        }

        func waitUntilStartIsAllowed(leaseID: UUID) async -> Bool {
            await withCheckedContinuation { continuation in
                var cancellation: (@Sendable () -> Void)?
                lock.lock()
                precondition(id == leaseID, "A WorkLease belongs to exactly one response operation slot.")
                precondition(startWasRequested == false, "A WorkLease can start exactly once.")
                startWasRequested = true
                switch state {
                case .reserved:
                    startWaiter = continuation
                    lock.unlock()
                case .installed(let cancel):
                    if cancellationWasRequested == false {
                        state = .running(cancel)
                        lock.unlock()
                        continuation.resume(returning: true)
                    } else {
                        cancellation = cancel
                        lock.unlock()
                        cancellation?()
                        continuation.resume(returning: false)
                    }
                case .running, .completed:
                    lock.unlock()
                    preconditionFailure("A WorkLease can start exactly once.")
                }
            }
        }

        func acknowledgeCompletion(leaseID: UUID) {
            lock.lock()
            precondition(id == leaseID, "A WorkLease belongs to exactly one response operation slot.")
            guard case .completed = state else {
                state = .completed
                lock.unlock()
                operation?.workSlotDidComplete(self)
                return
            }
            lock.unlock()
        }

        var isCompleted: Bool {
            lock.lock()
            let result = if case .completed = state { true } else { false }
            lock.unlock()
            return result
        }

        var snapshot: ResponseWorkPhase {
            lock.lock()
            let snapshot: ResponseWorkPhase = switch state {
            case .reserved: .reserved
            case .installed: .installed
            case .running: .running
            case .completed: .completed
            }
            lock.unlock()
            return snapshot
        }
    }

    package final class WorkLease: @unchecked Sendable {
        fileprivate let id: UUID
        private let slot: WorkSlot

        fileprivate init(slot: WorkSlot, id: UUID) {
            self.id = id
            self.slot = slot
        }

        package func install(_ task: Task<Void, Never>) {
            slot.install(task: task, leaseID: id)
        }

        package func waitUntilStartIsAllowed() async -> Bool {
            await slot.waitUntilStartIsAllowed(leaseID: id)
        }

        package func acknowledgeCompletion() {
            slot.acknowledgeCompletion(leaseID: id)
        }
    }

    package final class RequestOperation: @unchecked Sendable {
        private enum Outcome {
            case open
            case responded
            case cancelled(TerminalCause)
        }

        private enum ResponseQueueState {
            case handling
            case ready(CheckedContinuation<Bool, Never>?)
            case turnGranted
        }

        package let id = UUID()
        package let admissionOrdinal: UInt64
        private weak var connection: Connection?
        private let lock = NSLock()
        private let handlerSlot = WorkSlot()
        private var sourceSlot: (kind: ResponseSourceKind, slot: WorkSlot)?
        private var writerSlot: WorkSlot?
        private var responseQueueState: ResponseQueueState = .handling
        private var responseEnd: ResponseEndPhase = .notExpected
        private var outcome: Outcome = .open
        private var didClose = false
        private var closeWaiters: [CheckedContinuation<TerminalCause?, Never>] = []

        fileprivate init(admissionOrdinal: UInt64, connection: Connection) {
            self.admissionOrdinal = admissionOrdinal
            self.connection = connection
            handlerSlot.attach(to: self)
        }

        fileprivate func makeLease() -> WorkLease {
            handlerSlot.makeLease()
        }

        func reserveResponseSource(_ kind: ResponseSourceKind) -> WorkLease? {
            lock.lock()
            guard case .open = outcome,
                  responseEnd == .notExpected,
                  sourceSlot == nil else {
                lock.unlock()
                return nil
            }
            let slot = WorkSlot()
            slot.attach(to: self)
            sourceSlot = (kind, slot)
            responseEnd = .pending
            lock.unlock()
            notifyChanged()
            return slot.makeLease()
        }

        func markResponseSourceNotRequired() -> Bool {
            lock.lock()
            guard case .open = outcome,
                  responseEnd == .notExpected,
                  sourceSlot == nil else {
                lock.unlock()
                return false
            }
            responseEnd = .pending
            lock.unlock()
            notifyChanged()
            return true
        }

        fileprivate func markResponseReady() -> Bool {
            lock.lock()
            guard case .open = outcome,
                  responseEnd == .pending,
                  case .handling = responseQueueState else {
                lock.unlock()
                return false
            }
            responseQueueState = .ready(nil)
            lock.unlock()
            notifyChanged()
            return true
        }

        fileprivate var isResponseReady: Bool {
            lock.lock()
            let result = if case .ready = responseQueueState { true } else { false }
            lock.unlock()
            return result
        }

        fileprivate func grantWriterTurn() -> Bool {
            let waiter: CheckedContinuation<Bool, Never>?
            lock.lock()
            guard case .open = outcome,
                  case .ready(let continuation) = responseQueueState else {
                lock.unlock()
                return false
            }
            waiter = continuation
            responseQueueState = .turnGranted
            lock.unlock()
            waiter?.resume(returning: true)
            notifyChanged()
            return true
        }

        fileprivate func waitForWriterTurn() async -> Bool {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard case .open = outcome else {
                    lock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                switch responseQueueState {
                case .turnGranted:
                    lock.unlock()
                    continuation.resume(returning: true)
                case .ready(nil):
                    responseQueueState = .ready(continuation)
                    lock.unlock()
                case .handling, .ready:
                    lock.unlock()
                    preconditionFailure("A response can wait for its FIFO writer turn exactly once.")
                }
            }
        }

        func reserveWriter() -> WorkLease? {
            lock.lock()
            guard case .open = outcome,
                  case .turnGranted = responseQueueState,
                  writerSlot == nil else {
                lock.unlock()
                return nil
            }
            let slot = WorkSlot()
            slot.attach(to: self)
            writerSlot = slot
            lock.unlock()
            notifyChanged()
            return slot.makeLease()
        }

        func acknowledgeResponseEnd() {
            lock.lock()
            guard case .open = outcome, responseEnd == .pending else {
                lock.unlock()
                return
            }
            responseEnd = .acknowledged
            outcome = .responded
            lock.unlock()
            notifyChanged()
            finishIfPossible()
        }

        fileprivate func beginClosing(_ cause: TerminalCause) {
            transitionToTerminal(.cancelled(cause))
        }

        package func waitUntilClosed() async -> TerminalCause? {
            await withCheckedContinuation { continuation in
                lock.lock()
                if didClose {
                    let cause = terminalCauseLocked
                    lock.unlock()
                    continuation.resume(returning: cause)
                } else {
                    closeWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        fileprivate func workSlotDidComplete(_ slot: WorkSlot) {
            lock.lock()
            if slot === handlerSlot,
               case .open = outcome,
               responseEnd == .notExpected {
                responseEnd = .acknowledged
                outcome = .responded
            }
            lock.unlock()
            notifyChanged()
            finishIfPossible()
        }

        fileprivate func snapshot() -> RequestSnapshot {
            lock.lock()
            let terminalCause = terminalCauseLocked
            let handlerPhase = handlerSlot.snapshot
            let phase: RequestWorkPhase
            if didClose {
                phase = .closed(terminalCause)
            } else if let terminalCause {
                phase = .closing(terminalCause)
            } else {
                phase = switch handlerPhase {
                case .reserved: .reserved
                case .installed: .installed
                case .running: .running
                case .completed, .notReserved: .responding
                }
            }
            let sourceKind = sourceSlot?.kind
            let sourcePhase = sourceSlot?.slot.snapshot ?? .notReserved
            let writerPhase = writerSlot?.snapshot ?? .notReserved
            let responseEnd = responseEnd
            let responseIsReady = switch responseQueueState {
            case .handling:
                false
            case .ready, .turnGranted:
                true
            }
            lock.unlock()
            return .init(
                id: id,
                admissionOrdinal: admissionOrdinal,
                phase: phase,
                responseSourceKind: sourceKind,
                responseSource: sourcePhase,
                writer: writerPhase,
                responseEnd: responseEnd,
                responseIsReady: responseIsReady
            )
        }

        private var terminalCauseLocked: TerminalCause? {
            if case .cancelled(let cause) = outcome {
                return cause
            }
            return nil
        }

        private func transitionToTerminal(_ requestedOutcome: Outcome) {
            let slots: [WorkSlot]
            let waiter: CheckedContinuation<Bool, Never>?
            lock.lock()
            if case .open = outcome {
                outcome = requestedOutcome
                if responseEnd == .pending || responseEnd == .notExpected {
                    responseEnd = .closed
                }
            }
            if case .ready(let continuation) = responseQueueState {
                waiter = continuation
                responseQueueState = .turnGranted
            } else {
                waiter = nil
            }
            slots = [handlerSlot, sourceSlot?.slot, writerSlot].compactMap { $0 }
            lock.unlock()
            waiter?.resume(returning: false)
            for slot in slots {
                slot.requestCancellation()
            }
            notifyChanged()
            finishIfPossible()
        }

        private func finishIfPossible() {
            let waiters: [CheckedContinuation<TerminalCause?, Never>]
            let cause: TerminalCause?
            lock.lock()
            guard didClose == false,
                  isTerminalLocked,
                  handlerSlot.isCompleted,
                  sourceSlot?.slot.isCompleted != false,
                  writerSlot?.isCompleted != false else {
                lock.unlock()
                return
            }
            didClose = true
            cause = terminalCauseLocked
            waiters = closeWaiters
            closeWaiters.removeAll(keepingCapacity: false)
            lock.unlock()
            for waiter in waiters {
                waiter.resume(returning: cause)
            }
            connection?.requestDidClose(self)
        }

        private var isTerminalLocked: Bool {
            if case .open = outcome {
                return false
            }
            return true
        }

        private func notifyChanged() {
            connection?.requestDidChange()
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
        private var requests: [RequestOperation] = []
        private var activeWriterRequestID: UUID?
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

        package func admitRequest() -> AdmittedRequest? {
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
            requests.append(operation)
            lock.unlock()
            owner?.changed()
            return .init(operation: operation, lease: lease)
        }

        package func supplyResponse(for operation: RequestOperation) async -> Bool {
            guard operation.markResponseReady() else {
                return false
            }
            pumpWriterQueue()
            return await operation.waitForWriterTurn()
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

        fileprivate func closeAdmission() {
            lock.lock()
            if phase == .accepting {
                phase = .admissionClosed
            }
            lock.unlock()
            owner?.changed()
        }

        fileprivate func beginClosing(_ cause: TerminalCause) {
            beginClosing(cause, signalResourceClose: true)
        }

        fileprivate func requestDidClose(_ operation: RequestOperation) {
            var didClose = false
            var waiters: [CheckedContinuation<Void, Never>] = []
            lock.lock()
            requests.removeAll { $0 === operation }
            if activeWriterRequestID == operation.id {
                activeWriterRequestID = nil
            }
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
            } else {
                pumpWriterQueue()
                owner?.changed()
            }
        }

        fileprivate func requestDidChange() {
            pumpWriterQueue()
            owner?.changed()
        }

        fileprivate func snapshot() -> ConnectionSnapshot {
            lock.lock()
            let phase = phase
            let closeAcknowledged = closeAcknowledged
            let requests = requests
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
                requests = self.requests
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
                requests = self.requests
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

        private func pumpWriterQueue() {
            let operation: RequestOperation?
            lock.lock()
            if activeWriterRequestID == nil,
               let head = requests.first,
               head.isResponseReady {
                activeWriterRequestID = head.id
                operation = head
            } else {
                operation = nil
            }
            lock.unlock()
            guard let operation else {
                return
            }
            if operation.grantWriterTurn() == false {
                lock.lock()
                if activeWriterRequestID == operation.id {
                    activeWriterRequestID = nil
                }
                lock.unlock()
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

    private struct SnapshotWaiter {
        let revision: UInt64
        let continuation: CheckedContinuation<Snapshot, Never>
    }

    package let generationID: UInt64
    private let lock = NSLock()
    private var state: State = .accepting(.init(connections: [:]))
    private var nextConnectionOrdinal: UInt64 = 0
    private var revision: UInt64 = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var snapshotWaiters: [SnapshotWaiter] = []

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
        changed()
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
        changed()
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
        changed()
        return ClosingGeneration(owner: self)
    }

    package func snapshot() -> Snapshot {
        lock.lock()
        let revision = revision
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
            revision: revision,
            generationID: generationID,
            phase: phase,
            connections: connections.sorted {
                $0.admissionOrdinal < $1.admissionOrdinal
            }.map { $0.snapshot() }
        )
    }

    package func nextSnapshot(after priorRevision: UInt64) async -> Snapshot {
        await withCheckedContinuation { continuation in
            lock.lock()
            if revision > priorRevision {
                lock.unlock()
                continuation.resume(returning: snapshot())
            } else {
                snapshotWaiters.append(.init(
                    revision: priorRevision,
                    continuation: continuation
                ))
                lock.unlock()
            }
        }
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
        changed()
    }

    fileprivate func changed() {
        let waiters: [CheckedContinuation<Snapshot, Never>]
        lock.lock()
        revision &+= 1
        let ready = snapshotWaiters.filter { revision > $0.revision }
        snapshotWaiters.removeAll { revision > $0.revision }
        waiters = ready.map(\.continuation)
        lock.unlock()
        guard waiters.isEmpty == false else {
            return
        }
        let current = snapshot()
        for waiter in waiters {
            waiter.resume(returning: current)
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
