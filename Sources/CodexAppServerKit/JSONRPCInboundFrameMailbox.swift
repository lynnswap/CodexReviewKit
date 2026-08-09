import Foundation
import Synchronization

package actor JSONRPCInboundFrameMailbox {
    package struct Snapshot: Equatable, Sendable {
        package var readyFrameCount: Int
        package var hasOverflowFrame: Bool
        package var admissionWaiterCount: Int
        package var isTerminal: Bool

        package var acceptedFrameCount: Int {
            readyFrameCount + (hasOverflowFrame ? 1 : 0)
        }
    }

    private enum Phase {
        case open
        case terminal(CodexTransportFailure?)
    }

    private enum AdmissionOutcome: Sendable {
        case granted
        case cancelled
        case closed
    }

    private enum ReceiveOutcome: Sendable {
        case frame(Data)
        case end
        case failure(CodexTransportFailure)
        case cancelled
    }

    private let readyCapacity: Int
    private var phase: Phase = .open
    private var readyFrames: [Data] = []
    private var overflowFrame: Data?
    private var admissionWaiters: [MailboxWaiter<AdmissionOutcome>] = []
    private var admissionWaiterCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var grantedAdmissionID: UUID?
    private var receiver: MailboxWaiter<ReceiveOutcome>?
    private var receiverRegistrationWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminalDelivered = false

    package init(readyCapacity: Int = 16) {
        precondition(readyCapacity > 0)
        self.readyCapacity = readyCapacity
        self.readyFrames.reserveCapacity(readyCapacity)
    }

    package func send(_ frame: Data) async throws {
        try Task.checkCancellation()
        guard case .open = phase else {
            throw CodexTransportFailure.closed
        }

        if grantedAdmissionID == nil, hasAvailableAcceptedSlot {
            accept(frame)
            return
        }

        let waiter = MailboxWaiter<AdmissionOutcome>(cancellationValue: .cancelled)
        admissionWaiters.append(waiter)
        resumeAdmissionWaiterCountWaiters()
        let outcome = await waiter.wait()
        admissionWaiters.removeAll { $0.id == waiter.id }

        switch outcome {
        case .granted:
            guard grantedAdmissionID == waiter.id else {
                if case .terminal = phase {
                    throw CodexTransportFailure.closed
                }
                preconditionFailure("Mailbox granted an admission token it does not own.")
            }
            grantedAdmissionID = nil
            guard case .open = phase else {
                grantNextAdmissionIfPossible()
                throw CodexTransportFailure.closed
            }
            guard Task.isCancelled == false else {
                grantNextAdmissionIfPossible()
                throw CancellationError()
            }
            guard hasAvailableAcceptedSlot else {
                preconditionFailure("Granted mailbox admission has no reserved capacity.")
            }
            accept(frame)
        case .cancelled:
            throw CancellationError()
        case .closed:
            throw CodexTransportFailure.closed
        }
    }

    package func next() async throws -> Data? {
        try Task.checkCancellation()
        if let frame = takeReadyFrame() {
            return frame
        }
        if let terminal = terminalOutcomeIfDrained() {
            return try terminal.get()
        }
        precondition(receiver == nil, "JSON-RPC inbound mailbox supports one consumer.")

        let waiter = MailboxWaiter<ReceiveOutcome>(cancellationValue: .cancelled)
        receiver = waiter
        let receiverRegistrationWaiters = receiverRegistrationWaiters
        self.receiverRegistrationWaiters.removeAll(keepingCapacity: false)
        for continuation in receiverRegistrationWaiters {
            continuation.resume()
        }
        let outcome = await waiter.wait()
        if receiver?.id == waiter.id {
            receiver = nil
        }
        switch outcome {
        case .frame(let frame):
            return frame
        case .end:
            return nil
        case .failure(let failure):
            throw failure
        case .cancelled:
            throw CancellationError()
        }
    }

    package func finish(throwing failure: CodexTransportFailure? = nil) {
        guard case .open = phase else {
            return
        }
        phase = .terminal(failure)
        for waiter in admissionWaiters {
            _ = waiter.resolve(.closed)
        }
        admissionWaiters.removeAll(keepingCapacity: false)
        grantedAdmissionID = nil
        resumeReceiverIfPossible()
    }

    package func snapshot() -> Snapshot {
        Snapshot(
            readyFrameCount: readyFrames.count,
            hasOverflowFrame: overflowFrame != nil,
            admissionWaiterCount: admissionWaiters.count,
            isTerminal: {
                if case .terminal = phase {
                    return true
                }
                return false
            }()
        )
    }

    package func waitForAdmissionWaiterCount(atLeast minimumCount: Int) async {
        guard admissionWaiters.count < minimumCount else {
            return
        }
        await withCheckedContinuation { continuation in
            admissionWaiterCountWaiters.append((minimumCount, continuation))
        }
    }

    package func waitUntilReceiverIsRegistered() async {
        guard receiver == nil else {
            return
        }
        await withCheckedContinuation { continuation in
            receiverRegistrationWaiters.append(continuation)
        }
    }

    private var hasAvailableAcceptedSlot: Bool {
        readyFrames.count < readyCapacity || overflowFrame == nil
    }

    private func accept(_ frame: Data) {
        guard readyFrames.count < readyCapacity || overflowFrame == nil else {
            preconditionFailure("JSON-RPC inbound mailbox exceeded its accepted capacity.")
        }
        if readyFrames.count < readyCapacity {
            readyFrames.append(frame)
        } else {
            overflowFrame = frame
        }
        resumeReceiverIfPossible()
    }

    private func takeReadyFrame() -> Data? {
        promoteOverflowIfPossible()
        guard readyFrames.isEmpty == false else {
            return nil
        }
        let frame = readyFrames.removeFirst()
        promoteOverflowIfPossible()
        grantNextAdmissionIfPossible()
        resumeReceiverIfPossible()
        return frame
    }

    private func promoteOverflowIfPossible() {
        guard readyFrames.count < readyCapacity, let overflowFrame else {
            return
        }
        readyFrames.append(overflowFrame)
        self.overflowFrame = nil
    }

    private func grantNextAdmissionIfPossible() {
        guard case .open = phase,
              grantedAdmissionID == nil,
              hasAvailableAcceptedSlot else {
            return
        }
        while admissionWaiters.isEmpty == false {
            let waiter = admissionWaiters.removeFirst()
            if waiter.resolve(.granted) {
                grantedAdmissionID = waiter.id
                return
            }
        }
    }

    private func resumeAdmissionWaiterCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in admissionWaiterCountWaiters {
            if admissionWaiters.count >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        admissionWaiterCountWaiters = remaining
    }

    private func resumeReceiverIfPossible() {
        guard let receiver else {
            return
        }
        promoteOverflowIfPossible()
        if let frame = readyFrames.first {
            guard receiver.resolve(.frame(frame)) else {
                self.receiver = nil
                return
            }
            self.receiver = nil
            readyFrames.removeFirst()
            promoteOverflowIfPossible()
            grantNextAdmissionIfPossible()
            return
        }
        guard case .terminal(let failure) = phase else {
            return
        }
        let didResolve: Bool
        if let failure {
            didResolve = receiver.resolve(.failure(failure))
        } else {
            didResolve = receiver.resolve(.end)
        }
        self.receiver = nil
        if didResolve {
            terminalDelivered = true
        }
    }

    private func terminalOutcomeIfDrained() -> Result<Data?, CodexTransportFailure>? {
        promoteOverflowIfPossible()
        guard readyFrames.isEmpty, overflowFrame == nil,
              case .terminal(let failure) = phase else {
            return nil
        }
        guard terminalDelivered == false else {
            return .success(nil)
        }
        terminalDelivered = true
        if let failure {
            return .failure(failure)
        }
        return .success(nil)
    }
}

private final class MailboxWaiter<Value: Sendable>: Sendable {
    private enum State {
        case pending(CheckedContinuation<Value, Never>?)
        case resolved(Value)
    }

    let id = UUID()
    private let cancellationValue: Value
    private let state = Mutex<State>(.pending(nil))

    init(cancellationValue: Value) {
        self.cancellationValue = cancellationValue
    }

    func wait() async -> Value {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resolved = state.withLock { state -> Value? in
                    switch state {
                    case .pending(nil):
                        state = .pending(continuation)
                        return nil
                    case .pending(.some):
                        preconditionFailure("Mailbox waiter registered more than once.")
                    case .resolved(let value):
                        return value
                    }
                }
                if let resolved {
                    continuation.resume(returning: resolved)
                }
            }
        } onCancel: {
            _ = self.resolve(self.cancellationValue)
        }
    }

    @discardableResult
    func resolve(_ value: Value) -> Bool {
        let resolution = state.withLock {
            state -> (Bool, CheckedContinuation<Value, Never>?) in
            switch state {
            case .pending(let continuation):
                state = .resolved(value)
                return (true, continuation)
            case .resolved:
                return (false, nil)
            }
        }
        resolution.1?.resume(returning: value)
        return resolution.0
    }
}
