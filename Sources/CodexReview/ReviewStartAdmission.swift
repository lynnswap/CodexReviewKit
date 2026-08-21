import Foundation

package enum ReviewStartRequestFailure: LocalizedError, Equatable, Sendable {
    case rejected(code: Int?, message: String)
    case outcomeUnknown(message: String)

    package var errorDescription: String? {
        switch self {
        case .rejected(_, let message), .outcomeUnknown(let message):
            message
        }
    }
}

package struct ReviewStartCancelledBeforeDispatch: LocalizedError, Equatable, Sendable {
    package var cancellation: ReviewCancellation

    package init(cancellation: ReviewCancellation) {
        self.cancellation = cancellation
    }

    package var errorDescription: String? {
        cancellation.message
    }
}

package struct ReviewStartProtocolFailure: LocalizedError, Equatable, Sendable {
    package var message: String

    package init(message: String) {
        self.message = message
    }

    package var errorDescription: String? {
        message
    }
}

package enum ReviewStartAdmissionOperation: String, Equatable, Sendable {
    case admitThreadStartDispatch
    case recordThreadStartRejected
    case retryThreadStartDispatch
    case recordPreparedThread
    case admitReviewStartDispatch
    case recordReviewStartRejected
    case retryReviewStartDispatch
    case recordActiveRun
    case recordConnectionTerminal
    case recordProtocolTerminal
}

package enum ReviewStartAdmissionContractViolation: Equatable, Sendable {
    case wrongPhase(operation: ReviewStartAdmissionOperation)
    case staleRun(
        operation: ReviewStartAdmissionOperation,
        expected: CodexReviewBackendModel.Review.Run,
        received: CodexReviewBackendModel.Review.Run
    )
    case retryRequiresExplicitRejection(ReviewStartRequestFailure)
    case connectionTerminalRequiresConnectionFailure(ReviewRuntimeCloseFailure)
}

package struct ReviewStartAdmissionContractFailure: LocalizedError, Equatable, Sendable {
    package var violation: ReviewStartAdmissionContractViolation

    package init(violation: ReviewStartAdmissionContractViolation) {
        self.violation = violation
    }

    package var errorDescription: String? {
        switch violation {
        case .wrongPhase(let operation):
            "Review start admission rejected \(operation.rawValue) in the current phase."
        case .staleRun(let operation, let expected, let received):
            "Review start admission rejected \(operation.rawValue) for stale attempt "
                + "\(received.attemptID) on thread \(received.threadID); expected "
                + "\(expected.attemptID) on thread \(expected.threadID)."
        case .retryRequiresExplicitRejection(let failure):
            "Review start admission cannot retry an outcome-unknown request: "
                + failure.localizedDescription
        case .connectionTerminalRequiresConnectionFailure(let failure):
            "Review start admission requires a connection failure, not: "
                + failure.localizedDescription
        }
    }
}

/// Owns the two request-dispatch decisions that create one backend review run.
/// A dispatched request stays outcome-unknown until its response, an explicit
/// rejection, or a typed connection terminal resolves it.
package actor ReviewStartAdmission {
    package enum RequestDispatch: Equatable, Sendable {
        case notSent
        case outcomeUnknown
    }

    package enum Terminal: Equatable, Sendable {
        case cancelledBeforeDispatch(ReviewCancellation)
        case connection(ReviewRuntimeCloseFailure)
        case protocolFailure(ReviewStartProtocolFailure)
        case rejected(ReviewStartRequestFailure)
    }

    package enum Phase: Equatable, Sendable {
        case preparingThread(RequestDispatch)
        case startingReview(
            preparedRun: CodexReviewBackendModel.Review.Run,
            dispatch: RequestDispatch
        )
        case active(CodexReviewBackendModel.Review.Run)
        case terminal(Terminal)
    }

    package enum FailedReviewStartDisposition: Equatable, Sendable {
        case cleanup
        case preserveOutcomeUnknown
    }

    private let outcomeUnknownIsCallerOwned: Bool
    private var phase: Phase = .preparingThread(.notSent)
    private var requestedCancellation: ReviewCancellation?

    package init() {
        outcomeUnknownIsCallerOwned = true
    }

    private init(outcomeUnknownIsCallerOwned: Bool) {
        self.outcomeUnknownIsCallerOwned = outcomeUnknownIsCallerOwned
    }

    package static func compatibility() -> ReviewStartAdmission {
        .init(outcomeUnknownIsCallerOwned: false)
    }

    package func recordCancellation(_ cancellation: ReviewCancellation) {
        guard requestedCancellation == nil else {
            return
        }
        requestedCancellation = cancellation
        switch phase {
        case .preparingThread(.notSent), .startingReview(_, .notSent):
            phase = .terminal(.cancelledBeforeDispatch(cancellation))
        case .preparingThread(.outcomeUnknown), .startingReview(_, .outcomeUnknown),
             .active, .terminal:
            break
        }
    }

    package func admitThreadStartDispatch() throws {
        switch phase {
        case .preparingThread(.notSent):
            break
        case .terminal(.cancelledBeforeDispatch(let cancellation)):
            throw ReviewStartCancelledBeforeDispatch(cancellation: cancellation)
        case .preparingThread(.outcomeUnknown), .startingReview, .active, .terminal:
            throw contractFailure(.wrongPhase(operation: .admitThreadStartDispatch))
        }
        if let requestedCancellation {
            phase = .terminal(.cancelledBeforeDispatch(requestedCancellation))
            throw ReviewStartCancelledBeforeDispatch(cancellation: requestedCancellation)
        }
        phase = .preparingThread(.outcomeUnknown)
    }

    package func recordThreadStartRejectedForRetry(
        _ failure: ReviewStartRequestFailure
    ) throws {
        guard case .rejected = failure else {
            throw contractFailure(.retryRequiresExplicitRejection(failure))
        }
        guard case .preparingThread(.outcomeUnknown) = phase else {
            throw contractFailure(.wrongPhase(operation: .retryThreadStartDispatch))
        }
        if let requestedCancellation {
            phase = .terminal(.cancelledBeforeDispatch(requestedCancellation))
            throw ReviewStartCancelledBeforeDispatch(cancellation: requestedCancellation)
        }
        phase = .preparingThread(.notSent)
    }

    package func recordThreadStartRejected(
        _ failure: ReviewStartRequestFailure
    ) throws {
        guard case .rejected = failure else {
            throw contractFailure(.retryRequiresExplicitRejection(failure))
        }
        switch phase {
        case .preparingThread(.outcomeUnknown):
            phase = .terminal(.rejected(failure))
        case .terminal(.rejected(let currentFailure)) where currentFailure == failure:
            return
        case .terminal:
            return
        case .preparingThread(.notSent), .startingReview, .active:
            throw contractFailure(.wrongPhase(operation: .recordThreadStartRejected))
        }
    }

    package func recordPreparedThread(
        _ run: CodexReviewBackendModel.Review.Run
    ) throws {
        switch phase {
        case .preparingThread(.outcomeUnknown):
            phase = .startingReview(preparedRun: run, dispatch: .notSent)
        case .startingReview(let currentRun, .notSent):
            guard currentRun == run else {
                throw staleRunFailure(
                    operation: .recordPreparedThread,
                    expected: currentRun,
                    received: run
                )
            }
        case .startingReview(let currentRun, .outcomeUnknown):
            guard currentRun == run else {
                throw staleRunFailure(
                    operation: .recordPreparedThread,
                    expected: currentRun,
                    received: run
                )
            }
            throw contractFailure(.wrongPhase(operation: .recordPreparedThread))
        case .preparingThread(.notSent), .active, .terminal:
            throw contractFailure(.wrongPhase(operation: .recordPreparedThread))
        }
    }

    package func admitReviewStartDispatch(
        for preparedRun: CodexReviewBackendModel.Review.Run
    ) throws {
        let currentRun: CodexReviewBackendModel.Review.Run
        switch phase {
        case .startingReview(let run, .notSent):
            currentRun = run
        case .startingReview(let run, .outcomeUnknown):
            if run != preparedRun {
                throw staleRunFailure(
                    operation: .admitReviewStartDispatch,
                    expected: run,
                    received: preparedRun
                )
            }
            throw contractFailure(.wrongPhase(operation: .admitReviewStartDispatch))
        case .terminal(.cancelledBeforeDispatch(let cancellation)):
            throw ReviewStartCancelledBeforeDispatch(cancellation: cancellation)
        case .preparingThread, .active, .terminal:
            throw contractFailure(.wrongPhase(operation: .admitReviewStartDispatch))
        }
        guard currentRun == preparedRun else {
            throw staleRunFailure(
                operation: .admitReviewStartDispatch,
                expected: currentRun,
                received: preparedRun
            )
        }
        if let requestedCancellation {
            phase = .terminal(.cancelledBeforeDispatch(requestedCancellation))
            throw ReviewStartCancelledBeforeDispatch(cancellation: requestedCancellation)
        }
        phase = .startingReview(preparedRun: currentRun, dispatch: .outcomeUnknown)
    }

    package func recordReviewStartRejectedForRetry(
        _ failure: ReviewStartRequestFailure,
        for preparedRun: CodexReviewBackendModel.Review.Run
    ) throws {
        guard case .rejected = failure else {
            throw contractFailure(.retryRequiresExplicitRejection(failure))
        }
        guard case .startingReview(let currentRun, .outcomeUnknown) = phase else {
            throw contractFailure(.wrongPhase(operation: .retryReviewStartDispatch))
        }
        guard currentRun == preparedRun else {
            throw staleRunFailure(
                operation: .recordReviewStartRejected,
                expected: currentRun,
                received: preparedRun
            )
        }
        if let requestedCancellation {
            phase = .terminal(.cancelledBeforeDispatch(requestedCancellation))
            throw ReviewStartCancelledBeforeDispatch(cancellation: requestedCancellation)
        }
        phase = .startingReview(preparedRun: currentRun, dispatch: .notSent)
    }

    package func recordReviewStartRejected(
        _ failure: ReviewStartRequestFailure,
        for preparedRun: CodexReviewBackendModel.Review.Run
    ) throws {
        guard case .rejected = failure else {
            throw contractFailure(.retryRequiresExplicitRejection(failure))
        }
        switch phase {
        case .startingReview(let currentRun, .outcomeUnknown):
            guard currentRun == preparedRun else {
                throw staleRunFailure(
                    operation: .recordReviewStartRejected,
                    expected: currentRun,
                    received: preparedRun
                )
            }
            phase = .terminal(.rejected(failure))
        case .terminal(.rejected(let currentFailure)) where currentFailure == failure:
            return
        case .terminal:
            return
        case .preparingThread, .startingReview(_, .notSent), .active:
            throw contractFailure(.wrongPhase(operation: .recordReviewStartRejected))
        }
    }

    package func recordActiveRun(
        _ run: CodexReviewBackendModel.Review.Run
    ) throws {
        switch phase {
        case .startingReview(let preparedRun, .outcomeUnknown):
            guard Self.belongsToPreparedRun(run, preparedRun) else {
                throw staleRunFailure(
                    operation: .recordActiveRun,
                    expected: preparedRun,
                    received: run
                )
            }
            phase = .active(run)
        case .active(let currentRun) where currentRun == run:
            return
        case .active(let currentRun):
            throw staleRunFailure(
                operation: .recordActiveRun,
                expected: currentRun,
                received: run
            )
        case .preparingThread, .startingReview(_, .notSent), .terminal:
            throw contractFailure(.wrongPhase(operation: .recordActiveRun))
        }
    }

    package func recordConnectionTerminal(
        _ failure: ReviewRuntimeCloseFailure
    ) throws {
        guard case .connection = failure else {
            throw contractFailure(.connectionTerminalRequiresConnectionFailure(failure))
        }
        switch phase {
        case .preparingThread(.outcomeUnknown), .startingReview(_, .outcomeUnknown):
            phase = .terminal(.connection(failure))
        case .terminal(.connection(let currentFailure)) where currentFailure == failure:
            return
        case .preparingThread(.notSent), .startingReview(_, .notSent), .active, .terminal:
            throw contractFailure(.wrongPhase(operation: .recordConnectionTerminal))
        }
    }

    package func recordProtocolTerminal(
        _ failure: ReviewStartProtocolFailure
    ) throws {
        switch phase {
        case .preparingThread(.outcomeUnknown), .startingReview(_, .outcomeUnknown):
            phase = .terminal(.protocolFailure(failure))
        case .terminal(.protocolFailure(let currentFailure)) where currentFailure == failure:
            return
        case .terminal:
            return
        case .preparingThread(.notSent), .startingReview(_, .notSent), .active:
            throw contractFailure(.wrongPhase(operation: .recordProtocolTerminal))
        }
    }

    package func cancellationRequest() -> ReviewCancellation? {
        requestedCancellation
    }

    package func currentPhase() -> Phase {
        phase
    }

    package func failedReviewStartDisposition(
        for preparedRun: CodexReviewBackendModel.Review.Run
    ) -> FailedReviewStartDisposition {
        guard outcomeUnknownIsCallerOwned,
              case .startingReview(let currentRun, .outcomeUnknown) = phase,
              currentRun == preparedRun
        else {
            return .cleanup
        }
        return .preserveOutcomeUnknown
    }

    private func contractFailure(
        _ violation: ReviewStartAdmissionContractViolation
    ) -> ReviewStartAdmissionContractFailure {
        .init(violation: violation)
    }

    private func staleRunFailure(
        operation: ReviewStartAdmissionOperation,
        expected: CodexReviewBackendModel.Review.Run,
        received: CodexReviewBackendModel.Review.Run
    ) -> ReviewStartAdmissionContractFailure {
        contractFailure(.staleRun(
            operation: operation,
            expected: expected,
            received: received
        ))
    }

    private static func belongsToPreparedRun(
        _ run: CodexReviewBackendModel.Review.Run,
        _ preparedRun: CodexReviewBackendModel.Review.Run
    ) -> Bool {
        run.attemptID == preparedRun.attemptID
            && run.threadID == preparedRun.threadID
            && run.model == preparedRun.model
    }
}
