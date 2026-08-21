import Foundation
@preconcurrency import NIOCore

final class MCPHTTPNetworkResourceOwner: @unchecked Sendable {
    static let operationTokenHeaderName = "X-CodexReview-Request-Operation"

    struct OperationToken: Hashable, Sendable {
        fileprivate let connectionID: UUID
        fileprivate let operationID: UUID

        var headerValue: String {
            "\(connectionID.uuidString.lowercased()):\(operationID.uuidString.lowercased())"
        }

        init?(headerValue: String) {
            let parts = headerValue.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let connectionID = UUID(uuidString: String(parts[0])),
                  let operationID = UUID(uuidString: String(parts[1]))
            else {
                return nil
            }
            self.connectionID = connectionID
            self.operationID = operationID
        }

        fileprivate init(connectionID: UUID, operationID: UUID) {
            self.connectionID = connectionID
            self.operationID = operationID
        }
    }

    struct RequestMetadata: Equatable, Sendable {
        let method: String
        let path: String
        let jsonRPCID: String?
    }

    enum CloseCause: Equatable, Sendable {
        case sdkCancellation
        case peerClosed
        case sessionClosed
        case serverStop
        case transportFailure(String)
    }

    enum OperationResult: Equatable, Sendable {
        case responded
        case cancelled(CloseCause)
        case failed(String)
    }

    enum WorkKind: CaseIterable, Sendable {
        case httpHandler
        case domain
        case source
        case writer
    }

    enum WorkCompletion: Sendable {
        case succeeded
        case failed(String)
    }

    enum WorkStateSnapshot: Equatable, Sendable {
        case notAdmitted
        case responseReady
        case turnGranted
        case reserved
        case running
        case completed
        case closed
    }

    enum OperationPhaseSnapshot: Equatable, Sendable {
        case admitted
        case handling
        case responding
        case closing(CloseCause?, OperationResult)
        case closed(OperationResult)
    }

    struct OperationSnapshot: Equatable, Sendable {
        let token: OperationToken
        let admissionOrdinal: UInt64
        let metadata: RequestMetadata
        let phase: OperationPhaseSnapshot
        let boundSessionID: String?
        let httpHandler: WorkStateSnapshot
        let domain: WorkStateSnapshot
        let source: WorkStateSnapshot
        let writer: WorkStateSnapshot

        var responseIsReady: Bool {
            switch writer {
            case .responseReady, .turnGranted, .reserved, .running, .completed:
                true
            case .notAdmitted, .closed:
                false
            }
        }

        var writerIsRunning: Bool { writer == .running }

        var domainWorkIsPending: Bool {
            domain == .reserved || domain == .running
        }

        var terminalCause: CloseCause? {
            switch phase {
            case .closing(let cause, _):
                cause
            case .closed(.cancelled(let cause)):
                cause
            case .admitted, .handling, .responding, .closed:
                nil
            }
        }
    }

    enum ConnectionPhaseSnapshot: Equatable, Sendable {
        case accepting
        case admissionClosed
        case closing
        case closed
    }

    struct ConnectionSnapshot: Equatable, Sendable {
        let id: UUID
        let ordinal: UInt64
        let phase: ConnectionPhaseSnapshot
        let operations: [OperationSnapshot]
    }

    enum GenerationPhaseSnapshot: Equatable, Sendable {
        case accepting
        case admissionClosed
        case closing
        case closed
    }

    struct Snapshot: Equatable, Sendable {
        let revision: UInt64
        let phase: GenerationPhaseSnapshot
        let connections: [ConnectionSnapshot]

        var isQuiescent: Bool {
            phase == .closed && connections.isEmpty
        }
    }

    final class WorkReservation: @unchecked Sendable {
        fileprivate let id = UUID()
        fileprivate let kind: WorkKind
        private weak var operation: RequestOperation?

        fileprivate init(kind: WorkKind, operation: RequestOperation) {
            self.kind = kind
            self.operation = operation
        }

        func install<Success: Sendable, Failure: Error>(
            _ task: Task<Success, Failure>
        ) {
            operation?.installCancellation({ task.cancel() }, for: self)
        }

        func acknowledge(_ completion: WorkCompletion = .succeeded) {
            operation?.acknowledge(self, completion)
        }
    }

    final class RequestOperation: @unchecked Sendable {
        private struct Common {
            let metadata: RequestMetadata
            var boundSessionID: String?
        }

        private enum WorkSlot {
            case notAdmitted
            case responseReady(CheckedContinuation<Bool, Never>?)
            case turnGranted
            case reserved(UUID)
            case running(UUID, @Sendable () -> Void)
            case completed
            case closed

            var snapshot: WorkStateSnapshot {
                switch self {
                case .notAdmitted: .notAdmitted
                case .responseReady: .responseReady
                case .turnGranted: .turnGranted
                case .reserved: .reserved
                case .running: .running
                case .completed: .completed
                case .closed: .closed
                }
            }

            var isPending: Bool {
                switch self {
                case .reserved, .running:
                    true
                case .notAdmitted, .responseReady, .turnGranted, .completed, .closed:
                    false
                }
            }
        }

        private struct Slots {
            var httpHandler: WorkSlot = .notAdmitted
            var domain: WorkSlot = .notAdmitted
            var source: WorkSlot = .notAdmitted
            var writer: WorkSlot = .notAdmitted

            subscript(kind: WorkKind) -> WorkSlot {
                get {
                    switch kind {
                    case .httpHandler: httpHandler
                    case .domain: domain
                    case .source: source
                    case .writer: writer
                    }
                }
                set {
                    switch kind {
                    case .httpHandler: httpHandler = newValue
                    case .domain: domain = newValue
                    case .source: source = newValue
                    case .writer: writer = newValue
                    }
                }
            }

            var handlingIsPending: Bool {
                httpHandler.isPending || domain.isPending
            }
        }

        private struct Admitted {
            var common: Common
            var slots: Slots
        }

        private struct Handling {
            var common: Common
            var slots: Slots
        }

        private struct Responding {
            var common: Common
            var slots: Slots
        }

        private struct Closing {
            var common: Common
            var slots: Slots
            let cause: CloseCause?
            var pending: Set<WorkKind>
            let terminalResult: OperationResult
        }

        private enum State {
            case admitted(Admitted)
            case handling(Handling)
            case responding(Responding)
            case closing(Closing)
            case closed(Common, OperationResult, Slots)
        }

        let token: OperationToken
        let admissionOrdinal: UInt64
        let metadata: RequestMetadata
        private weak var connection: Connection?
        private let lock = NSLock()
        private var state: State
        private var closeWaiters: [CheckedContinuation<OperationResult, Never>] = []
        private var handlingWaiters: [CheckedContinuation<Void, Never>] = []

        fileprivate init(
            token: OperationToken,
            admissionOrdinal: UInt64,
            metadata: RequestMetadata,
            connection: Connection
        ) {
            self.token = token
            self.admissionOrdinal = admissionOrdinal
            self.metadata = metadata
            self.connection = connection
            state = .admitted(.init(common: .init(metadata: metadata), slots: .init()))
        }

        func beginHTTPHandling() -> WorkReservation? {
            lock.lock()
            guard case .admitted(var admitted) = state,
                  case .notAdmitted = admitted.slots.httpHandler
            else {
                lock.unlock()
                return nil
            }
            let reservation = WorkReservation(kind: .httpHandler, operation: self)
            admitted.slots.httpHandler = .reserved(reservation.id)
            state = .handling(.init(common: admitted.common, slots: admitted.slots))
            lock.unlock()
            notifyChanged()
            return reservation
        }

        func admitDomainWork() -> WorkReservation? {
            let reservation: WorkReservation
            lock.lock()
            switch state {
            case .handling(var handling):
                guard case .notAdmitted = handling.slots.domain else {
                    lock.unlock()
                    return nil
                }
                reservation = WorkReservation(kind: .domain, operation: self)
                handling.slots.domain = .reserved(reservation.id)
                state = .handling(handling)
            case .responding(var responding):
                guard case .notAdmitted = responding.slots.domain else {
                    lock.unlock()
                    return nil
                }
                reservation = WorkReservation(kind: .domain, operation: self)
                responding.slots.domain = .reserved(reservation.id)
                state = .responding(responding)
            case .admitted, .closing, .closed:
                lock.unlock()
                return nil
            }
            lock.unlock()
            notifyChanged()
            return reservation
        }

        func beginResponding() -> Bool {
            lock.lock()
            guard case .handling(let handling) = state else {
                lock.unlock()
                return false
            }
            state = .responding(.init(common: handling.common, slots: handling.slots))
            lock.unlock()
            notifyChanged()
            return true
        }

        func bindResponseSource() -> WorkReservation? {
            reserve(.source)
        }

        func markResponseSourceNotRequired() {
            lock.lock()
            guard case .responding(var responding) = state,
                  case .notAdmitted = responding.slots.source
            else {
                lock.unlock()
                return
            }
            responding.slots.source = .closed
            state = .responding(responding)
            lock.unlock()
            notifyChanged()
        }

        fileprivate func markResponseReady() -> Bool {
            lock.lock()
            guard case .responding(var responding) = state,
                  case .notAdmitted = responding.slots.writer
            else {
                lock.unlock()
                return false
            }
            responding.slots.writer = .responseReady(nil)
            state = .responding(responding)
            lock.unlock()
            notifyChanged()
            return true
        }

        fileprivate func waitForWriterTurn() async -> Bool {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard case .responding(var responding) = state else {
                    lock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                switch responding.slots.writer {
                case .turnGranted:
                    lock.unlock()
                    continuation.resume(returning: true)
                case .responseReady(nil):
                    responding.slots.writer = .responseReady(continuation)
                    state = .responding(responding)
                    lock.unlock()
                default:
                    lock.unlock()
                    continuation.resume(returning: false)
                }
            }
        }

        fileprivate func grantWriterTurn() -> Bool {
            let waiter: CheckedContinuation<Bool, Never>?
            lock.lock()
            guard case .responding(var responding) = state else {
                lock.unlock()
                return false
            }
            switch responding.slots.writer {
            case .responseReady(let continuation):
                waiter = continuation
                responding.slots.writer = .turnGranted
                state = .responding(responding)
                lock.unlock()
                waiter?.resume(returning: true)
                notifyChanged()
                return true
            default:
                lock.unlock()
                return false
            }
        }

        fileprivate var isResponseReady: Bool {
            lock.lock()
            let result: Bool
            if case .responding(let responding) = state {
                switch responding.slots.writer {
                case .responseReady, .turnGranted, .reserved, .running:
                    result = true
                case .notAdmitted, .completed, .closed:
                    result = false
                }
            } else {
                result = false
            }
            lock.unlock()
            return result
        }

        func bindWriter() -> WorkReservation? {
            lock.lock()
            guard case .responding(var responding) = state,
                  case .turnGranted = responding.slots.writer
            else {
                lock.unlock()
                return nil
            }
            let reservation = WorkReservation(kind: .writer, operation: self)
            responding.slots.writer = .reserved(reservation.id)
            state = .responding(responding)
            lock.unlock()
            notifyChanged()
            return reservation
        }

        func bindSession(_ sessionID: String) {
            lock.lock()
            switch state {
            case .admitted(var admitted):
                if admitted.common.boundSessionID == nil {
                    admitted.common.boundSessionID = sessionID
                    state = .admitted(admitted)
                }
            case .handling(var handling):
                if handling.common.boundSessionID == nil {
                    handling.common.boundSessionID = sessionID
                    state = .handling(handling)
                }
            case .responding(var responding):
                if responding.common.boundSessionID == nil {
                    responding.common.boundSessionID = sessionID
                    state = .responding(responding)
                }
            case .closing(var closing):
                if closing.common.boundSessionID == nil {
                    closing.common.boundSessionID = sessionID
                    state = .closing(closing)
                }
            case .closed:
                break
            }
            lock.unlock()
            notifyChanged()
        }

        func beginClosing(_ cause: CloseCause) {
            transitionToClosing(cause: cause, result: .cancelled(cause), cancelPending: true)
        }

        func acknowledgeResponseEnd() {
            transitionToClosing(cause: nil, result: .responded, cancelPending: false)
        }

        func waitUntilClosed() async -> OperationResult {
            await withCheckedContinuation { continuation in
                lock.lock()
                if case .closed(_, let result, _) = state {
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    closeWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        fileprivate func waitForHandlingWorkToDrain() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if handlingIsPendingLocked() == false {
                    lock.unlock()
                    continuation.resume()
                } else {
                    handlingWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        fileprivate func closeDomainAdmission() {
            var waiters: [CheckedContinuation<Void, Never>] = []
            lock.lock()
            switch state {
            case .handling(var handling):
                if case .notAdmitted = handling.slots.domain {
                    handling.slots.domain = .closed
                    state = .handling(handling)
                }
            case .responding(var responding):
                if case .notAdmitted = responding.slots.domain {
                    responding.slots.domain = .closed
                    state = .responding(responding)
                }
            case .admitted, .closing, .closed:
                break
            }
            if handlingIsPendingLocked() == false {
                waiters = handlingWaiters
                handlingWaiters.removeAll(keepingCapacity: false)
            }
            lock.unlock()
            for waiter in waiters { waiter.resume() }
            notifyChanged()
        }

        fileprivate func installCancellation(
            _ cancellation: @escaping @Sendable () -> Void,
            for reservation: WorkReservation
        ) {
            var shouldCancel = false
            lock.lock()
            switch state {
            case .handling(var handling):
                _ = Self.install(cancellation, reservation: reservation, slots: &handling.slots)
                state = .handling(handling)
            case .responding(var responding):
                _ = Self.install(cancellation, reservation: reservation, slots: &responding.slots)
                state = .responding(responding)
            case .closing(var closing):
                if Self.install(cancellation, reservation: reservation, slots: &closing.slots) {
                    shouldCancel = true
                }
                state = .closing(closing)
            case .admitted, .closed:
                break
            }
            lock.unlock()
            if shouldCancel { cancellation() }
            notifyChanged()
        }

        fileprivate func acknowledge(
            _ reservation: WorkReservation,
            _ completion: WorkCompletion
        ) {
            var closed: (OperationResult, [CheckedContinuation<OperationResult, Never>])?
            var handlingWaitersToResume: [CheckedContinuation<Void, Never>] = []
            var failure: String?
            lock.lock()
            switch state {
            case .handling(var handling):
                if Self.complete(reservation, slots: &handling.slots) {
                    state = .handling(handling)
                    if case .failed(let message) = completion,
                       reservation.kind == .source || reservation.kind == .writer
                    { failure = message }
                }
            case .responding(var responding):
                if Self.complete(reservation, slots: &responding.slots) {
                    state = .responding(responding)
                    if case .failed(let message) = completion,
                       reservation.kind == .source || reservation.kind == .writer
                    { failure = message }
                }
            case .closing(var closing):
                if Self.complete(reservation, slots: &closing.slots) {
                    closing.pending.remove(reservation.kind)
                    if closing.pending.isEmpty {
                        let result = closing.terminalResult
                        let waiters = closeWaiters
                        closeWaiters.removeAll(keepingCapacity: false)
                        state = .closed(closing.common, result, closing.slots)
                        closed = (result, waiters)
                    } else {
                        state = .closing(closing)
                    }
                }
            case .admitted, .closed:
                break
            }
            if handlingIsPendingLocked() == false {
                handlingWaitersToResume = handlingWaiters
                handlingWaiters.removeAll(keepingCapacity: false)
            }
            lock.unlock()
            for waiter in handlingWaitersToResume { waiter.resume() }
            if let failure {
                transitionToClosing(cause: nil, result: .failed(failure), cancelPending: true)
                return
            }
            finishClosed(closed)
            notifyChanged()
        }

        func snapshot() -> OperationSnapshot {
            lock.lock()
            let common: Common
            let slots: Slots
            let phase: OperationPhaseSnapshot
            switch state {
            case .admitted(let admitted):
                common = admitted.common; slots = admitted.slots; phase = .admitted
            case .handling(let handling):
                common = handling.common; slots = handling.slots; phase = .handling
            case .responding(let responding):
                common = responding.common; slots = responding.slots; phase = .responding
            case .closing(let closing):
                common = closing.common; slots = closing.slots
                phase = .closing(closing.cause, closing.terminalResult)
            case .closed(let closedCommon, let result, let closedSlots):
                common = closedCommon; slots = closedSlots; phase = .closed(result)
            }
            let result = OperationSnapshot(
                token: token,
                admissionOrdinal: admissionOrdinal,
                metadata: common.metadata,
                phase: phase,
                boundSessionID: common.boundSessionID,
                httpHandler: slots.httpHandler.snapshot,
                domain: slots.domain.snapshot,
                source: slots.source.snapshot,
                writer: slots.writer.snapshot
            )
            lock.unlock()
            return result
        }

        private func reserve(_ kind: WorkKind) -> WorkReservation? {
            lock.lock()
            guard case .responding(var responding) = state,
                  case .notAdmitted = responding.slots[kind]
            else {
                lock.unlock()
                return nil
            }
            let reservation = WorkReservation(kind: kind, operation: self)
            responding.slots[kind] = .reserved(reservation.id)
            state = .responding(responding)
            lock.unlock()
            notifyChanged()
            return reservation
        }

        private func transitionToClosing(
            cause: CloseCause?,
            result: OperationResult,
            cancelPending: Bool
        ) {
            var cancellations: [@Sendable () -> Void] = []
            var writerWaiter: CheckedContinuation<Bool, Never>?
            var closed: (OperationResult, [CheckedContinuation<OperationResult, Never>])?
            var handlingWaitersToResume: [CheckedContinuation<Void, Never>] = []
            lock.lock()
            let common: Common
            var slots: Slots
            switch state {
            case .admitted(let admitted): common = admitted.common; slots = admitted.slots
            case .handling(let handling): common = handling.common; slots = handling.slots
            case .responding(let responding): common = responding.common; slots = responding.slots
            case .closing, .closed:
                lock.unlock()
                return
            }
            if case .responseReady(let waiter) = slots.writer { writerWaiter = waiter }
            var pending: Set<WorkKind> = []
            for kind in WorkKind.allCases {
                switch slots[kind] {
                case .reserved:
                    pending.insert(kind)
                case .running(_, let cancel):
                    pending.insert(kind)
                    if cancelPending { cancellations.append(cancel) }
                case .notAdmitted, .responseReady, .turnGranted:
                    slots[kind] = .closed
                case .completed, .closed:
                    break
                }
            }
            if pending.isEmpty {
                let waiters = closeWaiters
                closeWaiters.removeAll(keepingCapacity: false)
                state = .closed(common, result, slots)
                closed = (result, waiters)
            } else {
                state = .closing(.init(
                    common: common,
                    slots: slots,
                    cause: cause,
                    pending: pending,
                    terminalResult: result
                ))
            }
            handlingWaitersToResume = handlingWaiters
            handlingWaiters.removeAll(keepingCapacity: false)
            lock.unlock()
            writerWaiter?.resume(returning: false)
            for cancellation in cancellations { cancellation() }
            for waiter in handlingWaitersToResume { waiter.resume() }
            finishClosed(closed)
            notifyChanged()
        }

        private func finishClosed(
            _ closed: (OperationResult, [CheckedContinuation<OperationResult, Never>])?
        ) {
            guard let (result, waiters) = closed else { return }
            for waiter in waiters { waiter.resume(returning: result) }
            connection?.operationDidClose(self)
        }

        private func notifyChanged() {
            connection?.operationDidChange()
        }

        private func handlingIsPendingLocked() -> Bool {
            switch state {
            case .admitted(let admitted): admitted.slots.handlingIsPending
            case .handling(let handling): handling.slots.handlingIsPending
            case .responding(let responding): responding.slots.handlingIsPending
            case .closing(let closing):
                closing.pending.contains(.httpHandler) || closing.pending.contains(.domain)
            case .closed: false
            }
        }

        private static func install(
            _ cancellation: @escaping @Sendable () -> Void,
            reservation: WorkReservation,
            slots: inout Slots
        ) -> Bool {
            guard case .reserved(let id) = slots[reservation.kind], id == reservation.id else {
                return false
            }
            slots[reservation.kind] = .running(reservation.id, cancellation)
            return true
        }

        private static func complete(
            _ reservation: WorkReservation,
            slots: inout Slots
        ) -> Bool {
            switch slots[reservation.kind] {
            case .reserved(let id), .running(let id, _):
                guard id == reservation.id else { return false }
                slots[reservation.kind] = .completed
                return true
            case .notAdmitted, .responseReady, .turnGranted, .completed, .closed:
                return false
            }
        }
    }

    final class Connection: @unchecked Sendable {
        private struct OpenState {
            var queue: [RequestOperation]
            var writerOperationID: UUID?
        }

        private struct ClosingState {
            var queue: [RequestOperation]
            var writerOperationID: UUID?
            var closeAcknowledged: Bool
        }

        private enum State {
            case accepting(OpenState)
            case admissionClosed(OpenState)
            case closing(ClosingState)
            case closed
        }

        let id = UUID()
        let ordinal: UInt64
        private weak var owner: MCPHTTPNetworkResourceOwner?
        private let channel: any Channel
        private let lock = NSLock()
        private var state = State.accepting(.init(queue: [], writerOperationID: nil))
        private var nextOperationOrdinal: UInt64 = 0
        private var closeWaiters: [CheckedContinuation<Void, Never>] = []

        fileprivate init(
            ordinal: UInt64,
            channel: any Channel,
            owner: MCPHTTPNetworkResourceOwner
        ) {
            self.ordinal = ordinal
            self.channel = channel
            self.owner = owner
            channel.closeFuture.whenComplete { [weak self] _ in
                self?.acknowledgeChannelClose()
            }
        }

        func admitRequest(metadata: RequestMetadata) -> RequestOperation? {
            lock.lock()
            guard case .accepting(var open) = state else {
                lock.unlock()
                return nil
            }
            nextOperationOrdinal &+= 1
            let operationID = UUID()
            let operation = RequestOperation(
                token: .init(connectionID: id, operationID: operationID),
                admissionOrdinal: nextOperationOrdinal,
                metadata: metadata,
                connection: self
            )
            open.queue.append(operation)
            state = .accepting(open)
            lock.unlock()
            owner?.changed()
            return operation
        }

        func supplyResponse(for operation: RequestOperation) async -> Bool {
            guard operation.markResponseReady() else { return false }
            pump()
            return await operation.waitForWriterTurn()
        }

        func beginClosing(_ cause: CloseCause) {
            let operations: [RequestOperation]
            var shouldCloseChannel = false
            lock.lock()
            switch state {
            case .accepting(let open), .admissionClosed(let open):
                operations = open.queue
                state = .closing(.init(
                    queue: open.queue,
                    writerOperationID: open.writerOperationID,
                    closeAcknowledged: false
                ))
                shouldCloseChannel = true
            case .closing, .closed:
                operations = []
            }
            lock.unlock()
            for operation in operations { operation.beginClosing(cause) }
            if shouldCloseChannel { channel.close(mode: .all, promise: nil) }
            owner?.changed()
        }

        func waitUntilClosed() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if case .closed = state {
                    lock.unlock(); continuation.resume()
                } else {
                    closeWaiters.append(continuation); lock.unlock()
                }
            }
        }

        fileprivate func closeAdmission() {
            let operations: [RequestOperation]
            lock.lock()
            switch state {
            case .accepting(let open): state = .admissionClosed(open); operations = open.queue
            case .admissionClosed(let open): operations = open.queue
            case .closing(let closing): operations = closing.queue
            case .closed: operations = []
            }
            lock.unlock()
            for operation in operations { operation.closeDomainAdmission() }
            owner?.changed()
        }

        fileprivate func resolve(operationID: UUID) -> RequestOperation? {
            lock.lock()
            let operation: RequestOperation?
            switch state {
            case .accepting(let open), .admissionClosed(let open):
                operation = open.queue.first { $0.token.operationID == operationID }
            case .closing(let closing):
                operation = closing.queue.first { $0.token.operationID == operationID }
            case .closed: operation = nil
            }
            lock.unlock()
            return operation
        }

        fileprivate func operationsSnapshot() -> [RequestOperation] {
            lock.lock()
            let operations: [RequestOperation]
            switch state {
            case .accepting(let open), .admissionClosed(let open): operations = open.queue
            case .closing(let closing): operations = closing.queue
            case .closed: operations = []
            }
            lock.unlock()
            return operations
        }

        fileprivate func operationDidChange() {
            pump()
            owner?.changed()
        }

        fileprivate func operationDidClose(_ operation: RequestOperation) {
            var didClose = false
            var waiters: [CheckedContinuation<Void, Never>] = []
            lock.lock()
            switch state {
            case .accepting(var open):
                open.queue.removeAll { $0 === operation }
                if open.writerOperationID == operation.token.operationID { open.writerOperationID = nil }
                state = .accepting(open)
            case .admissionClosed(var open):
                open.queue.removeAll { $0 === operation }
                if open.writerOperationID == operation.token.operationID { open.writerOperationID = nil }
                state = .admissionClosed(open)
            case .closing(var closing):
                closing.queue.removeAll { $0 === operation }
                if closing.writerOperationID == operation.token.operationID { closing.writerOperationID = nil }
                if closing.queue.isEmpty, closing.closeAcknowledged {
                    state = .closed
                    waiters = closeWaiters
                    closeWaiters.removeAll(keepingCapacity: false)
                    didClose = true
                } else {
                    state = .closing(closing)
                }
            case .closed: break
            }
            lock.unlock()
            for waiter in waiters { waiter.resume() }
            if didClose { owner?.connectionDidClose(self) }
            else { pump(); owner?.changed() }
        }

        fileprivate func snapshot() -> ConnectionSnapshot {
            let phase: ConnectionPhaseSnapshot
            let operations: [RequestOperation]
            lock.lock()
            switch state {
            case .accepting(let open): phase = .accepting; operations = open.queue
            case .admissionClosed(let open): phase = .admissionClosed; operations = open.queue
            case .closing(let closing): phase = .closing; operations = closing.queue
            case .closed: phase = .closed; operations = []
            }
            lock.unlock()
            return .init(
                id: id,
                ordinal: ordinal,
                phase: phase,
                operations: operations.map { $0.snapshot() }
            )
        }

        private func pump() {
            var operation: RequestOperation?
            lock.lock()
            switch state {
            case .accepting(var open):
                if open.writerOperationID == nil, let head = open.queue.first, head.isResponseReady {
                    open.writerOperationID = head.token.operationID; operation = head
                }
                state = .accepting(open)
            case .admissionClosed(var open):
                if open.writerOperationID == nil, let head = open.queue.first, head.isResponseReady {
                    open.writerOperationID = head.token.operationID; operation = head
                }
                state = .admissionClosed(open)
            case .closing, .closed: break
            }
            lock.unlock()
            guard let operation else { return }
            if operation.grantWriterTurn() == false {
                lock.lock()
                switch state {
                case .accepting(var open):
                    if open.writerOperationID == operation.token.operationID { open.writerOperationID = nil }
                    state = .accepting(open)
                case .admissionClosed(var open):
                    if open.writerOperationID == operation.token.operationID { open.writerOperationID = nil }
                    state = .admissionClosed(open)
                case .closing, .closed: break
                }
                lock.unlock()
            }
        }

        private func acknowledgeChannelClose() {
            var operationsToClose: [RequestOperation] = []
            var didClose = false
            var waiters: [CheckedContinuation<Void, Never>] = []
            lock.lock()
            switch state {
            case .accepting(let open), .admissionClosed(let open):
                operationsToClose = open.queue
                state = .closing(.init(
                    queue: open.queue,
                    writerOperationID: open.writerOperationID,
                    closeAcknowledged: true
                ))
                if open.queue.isEmpty {
                    state = .closed; didClose = true
                    waiters = closeWaiters; closeWaiters.removeAll(keepingCapacity: false)
                }
            case .closing(var closing):
                closing.closeAcknowledged = true
                if closing.queue.isEmpty {
                    state = .closed; didClose = true
                    waiters = closeWaiters; closeWaiters.removeAll(keepingCapacity: false)
                } else { state = .closing(closing) }
            case .closed: break
            }
            lock.unlock()
            for operation in operationsToClose { operation.beginClosing(.peerClosed) }
            for waiter in waiters { waiter.resume() }
            if didClose { owner?.connectionDidClose(self) } else { owner?.changed() }
        }
    }

    final class ClosingGeneration: @unchecked Sendable {
        private weak var owner: MCPHTTPNetworkResourceOwner?
        fileprivate init(owner: MCPHTTPNetworkResourceOwner) { self.owner = owner }
        func waitUntilClosed() async { await owner?.waitUntilClosed() }
    }

    private struct GenerationState { var connections: [UUID: Connection] }
    private enum State {
        case accepting(GenerationState)
        case admissionClosed(GenerationState)
        case closing(GenerationState)
        case closed
    }
    private struct SnapshotWaiter {
        let revision: UInt64
        let continuation: CheckedContinuation<Snapshot, Never>
    }

    private let lock = NSLock()
    private var state = State.accepting(.init(connections: [:]))
    private var nextConnectionOrdinal: UInt64 = 0
    private var revision: UInt64 = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var snapshotWaiters: [SnapshotWaiter] = []

    func admitConnection(_ channel: any Channel) -> Connection? {
        lock.lock()
        guard case .accepting(var accepting) = state else { lock.unlock(); return nil }
        nextConnectionOrdinal &+= 1
        let connection = Connection(ordinal: nextConnectionOrdinal, channel: channel, owner: self)
        accepting.connections[connection.id] = connection
        state = .accepting(accepting)
        lock.unlock()
        changed()
        return connection
    }

    func resolve(_ token: OperationToken) -> RequestOperation? {
        lock.lock()
        let connection: Connection?
        switch state {
        case .accepting(let current), .admissionClosed(let current), .closing(let current):
            connection = current.connections[token.connectionID]
        case .closed: connection = nil
        }
        lock.unlock()
        return connection?.resolve(operationID: token.operationID)
    }

    func closeAdmission() {
        let connections: [Connection]
        lock.lock()
        switch state {
        case .accepting(let accepting):
            state = .admissionClosed(accepting); connections = Array(accepting.connections.values)
        case .admissionClosed(let current), .closing(let current):
            connections = Array(current.connections.values)
        case .closed: connections = []
        }
        lock.unlock()
        for connection in connections { connection.closeAdmission() }
        changed()
    }

    func beginClosing(_ cause: CloseCause) -> ClosingGeneration {
        let connections: [Connection]
        var waiters: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        switch state {
        case .accepting(let current), .admissionClosed(let current):
            if current.connections.isEmpty {
                state = .closed; connections = []
                waiters = closeWaiters; closeWaiters.removeAll(keepingCapacity: false)
            } else {
                state = .closing(current)
                connections = current.connections.values.sorted { $0.ordinal < $1.ordinal }
            }
        case .closing(let current):
            connections = current.connections.values.sorted { $0.ordinal < $1.ordinal }
        case .closed: connections = []
        }
        lock.unlock()
        for connection in connections { connection.beginClosing(cause) }
        for waiter in waiters { waiter.resume() }
        changed()
        return ClosingGeneration(owner: self)
    }

    func waitForAdmittedHandlingWorkToDrain() async {
        let operations = connectionsSnapshot().flatMap { $0.operationsSnapshot() }
        for operation in operations { await operation.waitForHandlingWorkToDrain() }
    }

    func liveOperationCount(boundTo sessionID: String) -> Int {
        connectionsSnapshot()
            .flatMap { $0.operationsSnapshot() }
            .map { $0.snapshot() }
            .filter { $0.boundSessionID == sessionID }
            .count
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let currentRevision = revision
        let phase: GenerationPhaseSnapshot
        let connections: [Connection]
        switch state {
        case .accepting(let current): phase = .accepting; connections = Array(current.connections.values)
        case .admissionClosed(let current): phase = .admissionClosed; connections = Array(current.connections.values)
        case .closing(let current): phase = .closing; connections = Array(current.connections.values)
        case .closed: phase = .closed; connections = []
        }
        lock.unlock()
        return .init(
            revision: currentRevision,
            phase: phase,
            connections: connections.sorted { $0.ordinal < $1.ordinal }.map { $0.snapshot() }
        )
    }

    func nextSnapshot(after priorRevision: UInt64) async -> Snapshot {
        await withCheckedContinuation { continuation in
            lock.lock()
            if revision > priorRevision {
                lock.unlock(); continuation.resume(returning: snapshot())
            } else {
                snapshotWaiters.append(.init(revision: priorRevision, continuation: continuation))
                lock.unlock()
            }
        }
    }

    fileprivate func connectionDidClose(_ connection: Connection) {
        var waiters: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        switch state {
        case .accepting(var current):
            current.connections.removeValue(forKey: connection.id); state = .accepting(current)
        case .admissionClosed(var current):
            current.connections.removeValue(forKey: connection.id); state = .admissionClosed(current)
        case .closing(var current):
            current.connections.removeValue(forKey: connection.id)
            if current.connections.isEmpty {
                state = .closed; waiters = closeWaiters; closeWaiters.removeAll(keepingCapacity: false)
            } else { state = .closing(current) }
        case .closed: break
        }
        lock.unlock()
        for waiter in waiters { waiter.resume() }
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
        guard waiters.isEmpty == false else { return }
        let current = snapshot()
        for waiter in waiters { waiter.resume(returning: current) }
    }

    private func waitUntilClosed() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if case .closed = state { lock.unlock(); continuation.resume() }
            else { closeWaiters.append(continuation); lock.unlock() }
        }
    }

    private func connectionsSnapshot() -> [Connection] {
        lock.lock()
        let connections: [Connection]
        switch state {
        case .accepting(let current), .admissionClosed(let current), .closing(let current):
            connections = current.connections.values.sorted { $0.ordinal < $1.ordinal }
        case .closed: connections = []
        }
        lock.unlock()
        return connections
    }
}
