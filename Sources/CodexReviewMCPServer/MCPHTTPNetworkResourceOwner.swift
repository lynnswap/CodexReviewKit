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
    package static let operationTokenHeaderName = "X-CodexReview-Request-Operation"

    package struct OperationToken: Hashable, Sendable {
        fileprivate let connectionID: UUID
        fileprivate let requestID: UUID

        package var headerValue: String {
            "\(connectionID.uuidString.lowercased()):\(requestID.uuidString.lowercased())"
        }

        package init?(headerValue: String) {
            let parts = headerValue.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let connectionID = UUID(uuidString: String(parts[0])),
                  let requestID = UUID(uuidString: String(parts[1])) else { return nil }
            self.connectionID = connectionID
            self.requestID = requestID
        }

        fileprivate init(connectionID: UUID, requestID: UUID) {
            self.connectionID = connectionID
            self.requestID = requestID
        }
    }

    package enum TerminalCause: Equatable, Sendable {
        case serverStop
        case peerClosed
        case responseComplete
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

    package enum ResponseEndPhase: Equatable, Sendable {
        case notExpected
        case pending
        case acknowledged
        case closed
    }

    package enum CloseWaiterRegistration: Equatable, Sendable {
        case registered
        case alreadyClosed
    }

    package struct RequestSnapshot: Equatable, Sendable {
        package let id: UUID
        package let admissionOrdinal: UInt64
        package let phase: RequestWorkPhase
        package let responseEnd: ResponseEndPhase
        package let pendingDomainWorkCount: Int

        package var terminalCause: TerminalCause? {
            switch phase {
            case .closing(let cause), .closed(let cause?):
                cause
            case .reserved, .installed, .running, .closed:
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

    private final class DomainWorkLease: @unchecked Sendable {
        fileprivate let id = UUID()
        private weak var operation: RequestOperation?

        fileprivate init(operation: RequestOperation) {
            self.operation = operation
        }

        func install<Success: Sendable, Failure: Error>(
            _ task: Task<Success, Failure>
        ) {
            operation?.installDomainWork(id: id) { task.cancel() }
        }

        func waitUntilStartIsAllowed() async -> Bool {
            guard let operation else { return false }
            return await operation.waitUntilDomainWorkCanStart(id: id)
        }

        func acknowledgeCompletion() {
            operation?.acknowledgeDomainWork(id: id)
        }
    }

    package final class RequestOperation: @unchecked Sendable {
        private enum WorkState {
            case reserved
            case installed(@Sendable () -> Void)
            case running(@Sendable () -> Void)
            case acknowledged
        }

        private enum SessionDomainPhase {
            case unbound
            case accepting(String)

            func belongs(to sessionID: String) -> Bool {
                switch self {
                case .unbound:
                    false
                case .accepting(let ownedSessionID):
                    ownedSessionID == sessionID
                }
            }
        }

        private struct DomainWorkState {
            var cancellation: (@Sendable () -> Void)?
            var cancellationWasRequested = false
            var startWasRequested = false
            var startWaiter: CheckedContinuation<Bool, Never>?
        }

        package let id: UUID
        package let token: OperationToken
        package let admissionOrdinal: UInt64
        private weak var connection: Connection?
        private let lock = NSLock()
        private let leaseID: UUID
        private var workState: WorkState = .reserved
        private var terminalCause: TerminalCause?
        private var responseEnd: ResponseEndPhase = .notExpected
        private var didClose = false
        private var startWasRequested = false
        private var startWaiter: CheckedContinuation<Bool, Never>?
        private var domainWork: [UUID: DomainWorkState] = [:]
        private var sessionDomainPhase: SessionDomainPhase = .unbound
        private var closeWaiters: [CheckedContinuation<TerminalCause?, Never>] = []

        fileprivate init(admissionOrdinal: UInt64, connection: Connection) {
            let id = UUID()
            self.id = id
            self.token = .init(connectionID: connection.id, requestID: id)
            self.admissionOrdinal = admissionOrdinal
            self.connection = connection
            let leaseID = UUID()
            self.leaseID = leaseID
        }

        fileprivate func makeLease() -> WorkLease {
            WorkLease(operation: self, id: leaseID)
        }

        fileprivate func beginClosing(_ cause: TerminalCause) {
            var cancellations: [@Sendable () -> Void] = []
            var waiters: [CheckedContinuation<Bool, Never>] = []
            lock.lock()
            for id in Array(domainWork.keys) {
                domainWork[id]?.cancellationWasRequested = true
                if let cancellation = domainWork[id]?.cancellation {
                    cancellations.append(cancellation)
                    if let waiter = domainWork[id]?.startWaiter {
                        waiters.append(waiter)
                        domainWork[id]?.startWaiter = nil
                    }
                }
            }
            if terminalCause == nil, responseEnd != .acknowledged {
                terminalCause = cause
                responseEnd = .closed
                switch workState {
                case .installed(let cancel), .running(let cancel):
                    cancellations.append(cancel)
                    if let startWaiter { waiters.append(startWaiter) }
                    startWaiter = nil
                case .reserved, .acknowledged:
                    break
                }
            }
            lock.unlock()
            cancellations.forEach { $0() }
            waiters.forEach { $0.resume(returning: false) }
            finishIfPossible()
        }

        package func startDomainWork<Success: Sendable>(
            _ work: @escaping @Sendable () async throws -> Success
        ) -> Task<Success, any Error>? {
            guard let connection else { return nil }
            return connection.startDomainWork(for: self, work)
        }

        package func bindSession(_ sessionID: String) -> Bool {
            guard let connection else { return false }
            return connection.bindSession(sessionID, to: self)
        }

        package func withActiveSessionRequest(
            for sessionID: String,
            _ body: () -> Void
        ) -> Bool {
            guard let connection else { return false }
            return connection.withActiveSessionRequest(
                for: self,
                sessionID: sessionID,
                body
            )
        }

        package var resourceOwner: MCPHTTPNetworkResourceOwner? {
            connection?.resourceOwner
        }

        fileprivate func startDomainWorkWhileAdmissionIsOpen<Success: Sendable>(
            _ work: @escaping @Sendable () async throws -> Success
        ) -> Task<Success, any Error>? {
            lock.lock()
            guard case .accepting = sessionDomainPhase,
                  terminalCause == nil,
                  didClose == false else {
                lock.unlock()
                return nil
            }
            let lease = DomainWorkLease(operation: self)
            domainWork[lease.id] = .init()
            lock.unlock()
            let task = Task<Success, any Error> {
                defer { lease.acknowledgeCompletion() }
                guard await lease.waitUntilStartIsAllowed() else {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                return try await work()
            }
            lease.install(task)
            return task
        }

        fileprivate func bindSessionWhileAdmissionIsOpen(_ sessionID: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard terminalCause == nil, didClose == false else { return false }
            switch sessionDomainPhase {
            case .unbound:
                sessionDomainPhase = .accepting(sessionID)
                return true
            case .accepting(let ownedSessionID):
                return ownedSessionID == sessionID
            }
        }

        fileprivate func performWhileSessionAdmissionIsOpen(
            sessionID: String,
            _ body: () -> Void
        ) -> Bool {
            lock.lock()
            guard case .accepting(let ownedSessionID) = sessionDomainPhase,
                  ownedSessionID == sessionID,
                  terminalCause == nil,
                  didClose == false else {
                lock.unlock()
                return false
            }
            body()
            lock.unlock()
            return true
        }
        package func beginResponse() -> Bool {
            lock.lock()
            guard terminalCause == nil,
                  didClose == false,
                  responseEnd == .notExpected else {
                lock.unlock()
                return false
            }
            responseEnd = .pending
            lock.unlock()
            return true
        }

        package func acknowledgeResponseEnd() {
            lock.lock()
            guard terminalCause == nil, responseEnd == .pending else {
                lock.unlock()
                return
            }
            responseEnd = .acknowledged
            lock.unlock()
            finishIfPossible()
        }

        package func waitUntilClosed() async -> TerminalCause? {
            await withCheckedContinuation { continuation in
                lock.lock()
                if didClose {
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
            lock.lock()
            precondition(self.leaseID == leaseID, "A request WorkLease belongs to exactly one admitted operation.")
            guard case .acknowledged = workState else {
                workState = .acknowledged
                if responseEnd == .notExpected, terminalCause == nil {
                    responseEnd = .acknowledged
                }
                lock.unlock()
                finishIfPossible()
                return
            }
            lock.unlock()
        }

        fileprivate func installDomainWork(
            id: UUID,
            cancellation: @escaping @Sendable () -> Void
        ) {
            var waiter: CheckedContinuation<Bool, Never>?
            var shouldCancel = false
            lock.lock()
            guard var work = domainWork[id], work.cancellation == nil else {
                lock.unlock()
                preconditionFailure("A domain WorkLease can be installed exactly once.")
            }
            work.cancellation = cancellation
            shouldCancel = terminalCause != nil || work.cancellationWasRequested
            if work.startWasRequested {
                waiter = work.startWaiter
                work.startWaiter = nil
            }
            domainWork[id] = work
            lock.unlock()
            if shouldCancel { cancellation() }
            waiter?.resume(returning: shouldCancel == false)
        }

        fileprivate func waitUntilDomainWorkCanStart(id: UUID) async -> Bool {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard var work = domainWork[id] else {
                    lock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                precondition(work.startWasRequested == false, "A domain WorkLease can start exactly once.")
                work.startWasRequested = true
                if let cancellation = work.cancellation {
                    let shouldCancel = terminalCause != nil || work.cancellationWasRequested
                    domainWork[id] = work
                    lock.unlock()
                    if shouldCancel { cancellation() }
                    continuation.resume(returning: shouldCancel == false)
                } else {
                    work.startWaiter = continuation
                    domainWork[id] = work
                    lock.unlock()
                }
            }
        }

        fileprivate func acknowledgeDomainWork(id: UUID) {
            lock.lock()
            guard domainWork.removeValue(forKey: id) != nil else {
                lock.unlock()
                preconditionFailure("A domain WorkLease is acknowledged exactly once by its task owner.")
            }
            lock.unlock()
            finishIfPossible()
        }

        fileprivate func belongs(to sessionID: String) -> Bool {
            lock.lock()
            let result = sessionDomainPhase.belongs(to: sessionID)
            lock.unlock()
            return result
        }

        fileprivate func snapshot() -> RequestSnapshot {
            lock.lock()
            let phase: RequestWorkPhase
            if didClose {
                phase = .closed(terminalCause)
            } else if let terminalCause {
                phase = .closing(terminalCause)
            } else {
                phase = switch workState {
                case .reserved: .reserved
                case .installed: .installed
                case .running, .acknowledged: .running
                }
            }
            let responseEnd = responseEnd
            let pendingDomainWorkCount = domainWork.count
            lock.unlock()
            return .init(
                id: id,
                admissionOrdinal: admissionOrdinal,
                phase: phase,
                responseEnd: responseEnd,
                pendingDomainWorkCount: pendingDomainWorkCount
            )
        }

        private func finishIfPossible() {
            let waiters: [CheckedContinuation<TerminalCause?, Never>]
            let cause: TerminalCause?
            lock.lock()
            guard didClose == false,
                  case .acknowledged = workState,
                  domainWork.isEmpty,
                  responseEnd == .acknowledged || responseEnd == .closed else {
                lock.unlock()
                return
            }
            didClose = true
            cause = terminalCause
            waiters = closeWaiters
            closeWaiters.removeAll(keepingCapacity: false)
            lock.unlock()
            for waiter in waiters {
                waiter.resume(returning: cause)
            }
            connection?.requestDidClose(self)
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
        private var domainAdmissionClosed = false
        private var closeAcknowledged = false
        private var closeAcknowledgementWaiters: [CheckedContinuation<Void, Never>] = []
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

        package func closeAfterResponse() async {
            beginClosing(.responseComplete, signalResourceClose: true)
            await withCheckedContinuation { continuation in
                lock.lock()
                if closeAcknowledged {
                    lock.unlock()
                    continuation.resume()
                } else {
                    closeAcknowledgementWaiters.append(continuation)
                    lock.unlock()
                }
            }
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

        fileprivate func startDomainWork<Success: Sendable>(
            for operation: RequestOperation,
            _ work: @escaping @Sendable () async throws -> Success
        ) -> Task<Success, any Error>? {
            guard let owner else { return nil }
            return owner.startDomainWork(on: self, for: operation, work)
        }

        fileprivate var resourceOwner: MCPHTTPNetworkResourceOwner? { owner }

        fileprivate func startDomainWorkWhileGenerationIsAccepting<Success: Sendable>(
            for operation: RequestOperation,
            _ work: @escaping @Sendable () async throws -> Success
        ) -> Task<Success, any Error>? {
            lock.lock()
            switch phase {
            case .accepting, .admissionClosed:
                break
            case .closing, .closed:
                lock.unlock()
                return nil
            }
            guard domainAdmissionClosed == false,
                  let ownedOperation = requests[operation.id],
                  ownedOperation === operation else {
                lock.unlock()
                return nil
            }
            let task = operation.startDomainWorkWhileAdmissionIsOpen(work)
            lock.unlock()
            return task
        }

        fileprivate func bindSession(
            _ sessionID: String,
            to operation: RequestOperation
        ) -> Bool {
            guard let owner else { return false }
            return owner.bindSession(sessionID, on: self, to: operation)
        }

        fileprivate func withActiveSessionRequest(
            for operation: RequestOperation,
            sessionID: String,
            _ body: () -> Void
        ) -> Bool {
            guard let owner else { return false }
            return owner.withActiveSessionRequest(
                on: self,
                for: operation,
                sessionID: sessionID,
                body
            )
        }

        fileprivate func bindSessionWhileDomainAdmissionIsOpen(
            _ sessionID: String,
            to operation: RequestOperation
        ) -> Bool {
            lock.lock()
            switch phase {
            case .accepting, .admissionClosed:
                break
            case .closing, .closed:
                lock.unlock()
                return false
            }
            guard domainAdmissionClosed == false,
                  let ownedOperation = requests[operation.id],
                  ownedOperation === operation else {
                lock.unlock()
                return false
            }
            let didBind = operation.bindSessionWhileAdmissionIsOpen(sessionID)
            lock.unlock()
            return didBind
        }

        fileprivate func performWhileDomainAdmissionIsOpen(
            for operation: RequestOperation,
            sessionID: String,
            _ body: () -> Void
        ) -> Bool {
            lock.lock()
            switch phase {
            case .accepting, .admissionClosed:
                break
            case .closing, .closed:
                lock.unlock()
                return false
            }
            guard domainAdmissionClosed == false,
                  let ownedOperation = requests[operation.id],
                  ownedOperation === operation else {
                lock.unlock()
                return false
            }
            let didPerform = operation.performWhileSessionAdmissionIsOpen(
                sessionID: sessionID,
                body
            )
            lock.unlock()
            return didPerform
        }
        package func closeAdmission() {
            lock.lock()
            domainAdmissionClosed = true
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

        fileprivate func resolve(requestID: UUID) -> RequestOperation? {
            lock.lock()
            let operation = requests[requestID]
            lock.unlock()
            return operation
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
            domainAdmissionClosed = true
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
            let acknowledgementWaiters: [CheckedContinuation<Void, Never>]
            lock.lock()
            domainAdmissionClosed = true
            closeAcknowledged = true
            acknowledgementWaiters = closeAcknowledgementWaiters
            closeAcknowledgementWaiters.removeAll(keepingCapacity: false)
            switch phase {
            case .accepting, .admissionClosed:
                phase = .closing(.peerClosed)
                requests = Array(self.requests.values)
            case .closing, .closed:
                requests = []
            }
            lock.unlock()
            for waiter in acknowledgementWaiters {
                waiter.resume()
            }
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
    private var didRegisterCloseWaiter = false
    private var closeWaiterRegistrationWaiters: [
        CheckedContinuation<CloseWaiterRegistration, Never>
    ] = []

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

    fileprivate func startDomainWork<Success: Sendable>(
        on connection: Connection,
        for operation: RequestOperation,
        _ work: @escaping @Sendable () async throws -> Success
    ) -> Task<Success, any Error>? {
        lock.lock()
        guard case .accepting(let current) = state,
              let ownedConnection = current.connections[connection.id],
              ownedConnection === connection else {
            lock.unlock()
            return nil
        }
        let task = connection.startDomainWorkWhileGenerationIsAccepting(
            for: operation,
            work
        )
        lock.unlock()
        return task
    }

    fileprivate func bindSession(
        _ sessionID: String,
        on connection: Connection,
        to operation: RequestOperation
    ) -> Bool {
        lock.lock()
        guard case .accepting(let current) = state,
              let ownedConnection = current.connections[connection.id],
              ownedConnection === connection else {
            lock.unlock()
            return false
        }
        let didBind = connection.bindSessionWhileDomainAdmissionIsOpen(
            sessionID,
            to: operation
        )
        lock.unlock()
        return didBind
    }

    fileprivate func withActiveSessionRequest(
        on connection: Connection,
        for operation: RequestOperation,
        sessionID: String,
        _ body: () -> Void
    ) -> Bool {
        lock.lock()
        guard case .accepting(let current) = state,
              let ownedConnection = current.connections[connection.id],
              ownedConnection === connection else {
            lock.unlock()
            return false
        }
        let didPerform = connection.performWhileDomainAdmissionIsOpen(
            for: operation,
            sessionID: sessionID,
            body
        )
        lock.unlock()
        return didPerform
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

    package func waitForCloseWaiterRegistrationForTesting() async -> CloseWaiterRegistration {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didRegisterCloseWaiter {
                lock.unlock()
                continuation.resume(returning: .registered)
            } else if case .closed = state {
                lock.unlock()
                continuation.resume(returning: .alreadyClosed)
            } else {
                closeWaiterRegistrationWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    package func resolve(_ token: OperationToken, sessionID: String) -> RequestOperation? {
        lock.lock()
        let connection: Connection?
        switch state {
        case .accepting(let state), .admissionClosed(let state), .closing(let state, _):
            connection = state.connections[token.connectionID]
        case .closed:
            connection = nil
        }
        lock.unlock()
        guard let operation = connection?.resolve(requestID: token.requestID),
              operation.belongs(to: sessionID) else { return nil }
        return operation
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
            let registration: CloseWaiterRegistration
            let registrationWaiters: [CheckedContinuation<CloseWaiterRegistration, Never>]
            lock.lock()
            if case .closed = state {
                registration = .alreadyClosed
                registrationWaiters = closeWaiterRegistrationWaiters
                closeWaiterRegistrationWaiters.removeAll(keepingCapacity: false)
                lock.unlock()
                for waiter in registrationWaiters {
                    waiter.resume(returning: registration)
                }
                continuation.resume()
            } else {
                closeWaiters.append(continuation)
                didRegisterCloseWaiter = true
                registration = .registered
                registrationWaiters = closeWaiterRegistrationWaiters
                closeWaiterRegistrationWaiters.removeAll(keepingCapacity: false)
                lock.unlock()
                for waiter in registrationWaiters {
                    waiter.resume(returning: registration)
                }
            }
        }
    }
}
