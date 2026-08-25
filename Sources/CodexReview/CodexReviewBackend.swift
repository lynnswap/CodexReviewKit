import Foundation

package protocol CodexReviewBackend: Sendable {
    func readSettings() async throws -> CodexReviewBackendModel.Settings.Snapshot
    func applySettings(_ change: CodexReviewBackendModel.Settings.Change) async throws -> CodexReviewBackendModel.Settings.Snapshot

    func readAuth() async throws -> CodexReviewBackendModel.Auth.Snapshot
    func startLogin(_ request: CodexReviewBackendModel.Login.Request) async throws -> CodexReviewBackendModel.Login.Challenge
    func cancelLogin(_ challenge: CodexReviewBackendModel.Login.Challenge) async throws
    func completeLogin(_ response: CodexReviewBackendModel.Login.Response) async throws -> CodexReviewBackendModel.Auth.Snapshot
    func logout(_ account: CodexReviewBackendModel.Account.ID) async throws -> CodexReviewBackendModel.Auth.Snapshot

    func startReview(
        _ request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> BackendReviewAttempt
    func interruptReview(_ run: CodexReviewBackendModel.Review.Run, reason: CodexReviewBackendModel.CancellationReason) async throws
    func interruptReview(
        _ admission: ReviewInterruptRequestAdmission,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws
    func prepareReviewRecovery(
        _ candidate: ReviewRecoveryCandidate
    ) async throws -> ReviewRecoveryHandoff
    func resumeReviewRecovery(
        _ handoff: ReviewRecoveryHandoff,
        request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> BackendReviewAttempt
    func cleanupReview(_ run: CodexReviewBackendModel.Review.Run) async throws
}

package enum ReviewRuntimeCloseFailure: LocalizedError, Equatable, Sendable {
    case connection(String)
    case process(String)
    case worker(String)
    case cleanup(String)
    case mcpHandlerDrain(String)

    package var errorDescription: String? {
        switch self {
        case .connection(let message):
            "App-server connection close failed: \(message)"
        case .process(let message):
            "App-server process close failed: \(message)"
        case .worker(let message):
            "Review worker close failed: \(message)"
        case .cleanup(let message):
            "Review cleanup failed: \(message)"
        case .mcpHandlerDrain(let message):
            "MCP handler drain failed: \(message)"
        }
    }
}

package extension CodexReviewBackend {
    func startReview(
        _ request: CodexReviewBackendModel.Review.Start
    ) async throws -> BackendReviewAttempt {
        // Legacy callers cannot retain an unresolved admission after this call returns.
        // Remove this compatibility ownership once Store publishes one shared admission.
        try await startReview(request, admission: ReviewStartAdmission.compatibility())
    }

    func prepareReviewRecovery(
        _: ReviewRecoveryCandidate
    ) async throws -> ReviewRecoveryHandoff {
        throw ReviewAttemptContractFailure(
            message: "Typed review recovery preparation is not installed for this backend."
        )
    }

    func resumeReviewRecovery(
        _: ReviewRecoveryHandoff,
        request _: CodexReviewBackendModel.Review.Start,
        admission _: ReviewStartAdmission
    ) async throws -> BackendReviewAttempt {
        throw ReviewAttemptContractFailure(
            message: "Typed review recovery resume is not installed for this backend."
        )
    }
}

package struct BackendReviewAttempt: Sendable {
    package var run: CodexReviewBackendModel.Review.Run
    package var events: BackendReviewEventMailbox

    package init(run: CodexReviewBackendModel.Review.Run, events: BackendReviewEventMailbox = .init()) {
        self.run = run
        self.events = events
    }
}

package actor BackendReviewEventMailbox {
    private enum Terminal {
        case finished
        case cancelled
        case failed(ReviewAttemptStreamFailure)
    }

    private enum Delivery {
        case event(CodexReviewBackendModel.Review.Event)
        case finished
        case cancelled
        case failed(ReviewAttemptStreamFailure)
    }

    private var bufferedEvents: [CodexReviewBackendModel.Review.Event] = []
    private var terminal: Terminal?
    private var waiters: [UUID: CheckedContinuation<Delivery, Never>] = [:]

    package init() {}

    package func next() async throws -> CodexReviewBackendModel.Review.Event? {
        switch await nextDelivery() {
        case .event(let event):
            return event
        case .finished:
            return nil
        case .cancelled:
            throw CancellationError()
        case .failed(let failure):
            throw BackendReviewEventMailboxError(failure: failure)
        }
    }

    package func append(_ event: CodexReviewBackendModel.Review.Event) {
        guard terminal == nil else {
            return
        }
        if let waiterID = waiters.keys.first,
           let waiter = waiters.removeValue(forKey: waiterID) {
            waiter.resume(returning: .event(event))
        } else {
            bufferedEvents.append(event)
        }
        if Self.isTerminal(event) {
            terminal = .finished
            resumeWaitersForTerminal()
        }
    }

    package func append(contentsOf events: [CodexReviewBackendModel.Review.Event]) {
        for event in events {
            append(event)
        }
    }

    package func finish() {
        guard terminal == nil else {
            return
        }
        terminal = .finished
        resumeWaitersForTerminal()
    }

    package func fail(_ error: any Error) {
        if error is CancellationError {
            guard terminal == nil else {
                return
            }
            terminal = .cancelled
            resumeWaitersForTerminal()
            return
        }
        fail(
            error as? ReviewAttemptStreamFailure
                ?? .workerContract(.init(message: error.localizedDescription))
        )
    }

    package func fail(_ failure: ReviewAttemptStreamFailure) {
        guard terminal == nil else {
            return
        }
        terminal = .failed(failure)
        resumeWaitersForTerminal()
    }

    package func abandon() {
        guard terminal == nil else {
            return
        }
        terminal = .finished
        bufferedEvents.removeAll(keepingCapacity: false)
        resumeWaitersForTerminal()
    }

    package func isFinished() -> Bool {
        terminal != nil && bufferedEvents.isEmpty
    }

    private func nextDelivery() async -> Delivery {
        if bufferedEvents.isEmpty == false {
            let event = bufferedEvents.removeFirst()
            resumeWaitersForTerminal()
            return .event(event)
        }
        if let terminal {
            return delivery(for: terminal)
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if bufferedEvents.isEmpty == false {
                    let event = bufferedEvents.removeFirst()
                    resumeWaitersForTerminal()
                    continuation.resume(returning: .event(event))
                } else if let terminal {
                    continuation.resume(returning: delivery(for: terminal))
                } else {
                    waiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
    }

    private func cancelWaiter(id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: .finished)
    }

    private func resumeWaitersForTerminal() {
        guard bufferedEvents.isEmpty, let terminal else {
            return
        }
        let delivery = delivery(for: terminal)
        let waiters = Array(waiters.values)
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: delivery)
        }
    }

    private func delivery(for terminal: Terminal) -> Delivery {
        switch terminal {
        case .finished:
            return .finished
        case .cancelled:
            return .cancelled
        case .failed(let failure):
            return .failed(failure)
        }
    }

    private static func isTerminal(_ event: CodexReviewBackendModel.Review.Event) -> Bool {
        switch event {
        case .completed, .failed, .cancelled:
            return true
        case .started, .message, .messageDelta, .log, .logEntry:
            return false
        }
    }
}

package struct BackendReviewEventMailboxError: LocalizedError, Sendable {
    package var failure: ReviewAttemptStreamFailure

    package init(message: String) {
        self.failure = .workerContract(.init(message: message))
    }

    package init(failure: ReviewAttemptStreamFailure) {
        self.failure = failure
    }

    package var errorDescription: String? {
        failure.localizedDescription
    }
}

package struct CodexReviewClock: Sendable {
    package var now: @Sendable () -> Date

    package init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }
}

package struct CodexReviewIDGenerator: Sendable {
    package var next: @Sendable () -> String

    package init(next: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.next = next
    }
}
