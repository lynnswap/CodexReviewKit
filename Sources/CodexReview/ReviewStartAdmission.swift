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

package enum ReviewInterruptRequestOutcome: Equatable, Sendable {
    case rejected(code: Int?, message: String)
    case outcomeUnknown(message: String)
}

package struct ReviewInterruptRequestFailure: LocalizedError, Equatable, Sendable {
    package var outcome: ReviewInterruptRequestOutcome
    package var secondaryBarrierDiagnostic: String?

    package init(
        outcome: ReviewInterruptRequestOutcome,
        secondaryBarrierDiagnostic: String? = nil
    ) {
        self.outcome = outcome
        self.secondaryBarrierDiagnostic = secondaryBarrierDiagnostic
    }

    package var errorDescription: String? {
        switch outcome {
        case .rejected(_, let message), .outcomeUnknown(let message):
            message
        }
    }
}

package enum ReviewInterruptTerminal: Equatable, Sendable {
    case canonical(ReviewTerminalRecord)
    case connection(ReviewRuntimeCloseFailure)
    case stream(ReviewAttemptStreamFailure)
}

package struct ReviewInterruptResolution: Equatable, Sendable {
    package var run: CodexReviewBackendModel.Review.Run
    package var cancellation: ReviewCancellation?
    package var terminal: ReviewInterruptTerminal
    package var requestFailure: ReviewInterruptRequestFailure?

    package init(
        run: CodexReviewBackendModel.Review.Run,
        cancellation: ReviewCancellation?,
        terminal: ReviewInterruptTerminal,
        requestFailure: ReviewInterruptRequestFailure? = nil
    ) {
        self.run = run
        self.cancellation = cancellation
        self.terminal = terminal
        self.requestFailure = requestFailure
    }
}

package struct ReviewInterruptRequestAdmission: Equatable, Sendable {
    package let run: CodexReviewBackendModel.Review.Run
    package let threadID: String
    package let turnID: String

    fileprivate init(
        run: CodexReviewBackendModel.Review.Run,
        threadID: String,
        turnID: String
    ) {
        self.run = run
        self.threadID = threadID
        self.turnID = turnID
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
    case recordPreparedRecoveryRun
    case admitRecoveryRollbackDispatch
    case recordRecoveryRollbackAcknowledged
    case recordRecoveryRollbackRejected
    case interruptActiveRun
    case inspectRecordedActiveTerminal
    case recoverActiveRun
    case recordInterruptRequestAcknowledged
    case recordCanonicalTerminal
    case recordActiveConnectionTerminal
    case recordActiveStreamTerminal
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
    case interruptRequestRequiresCanonicalPair(CodexReviewBackendModel.Review.Run)
    case conflictingActiveTerminal(
        expected: ReviewInterruptTerminal,
        received: ReviewInterruptTerminal
    )
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
        case .interruptRequestRequiresCanonicalPair(let run):
            "Review start admission cannot interrupt attempt \(run.attemptID) without "
                + "its canonical review thread and turn identity."
        case .conflictingActiveTerminal(let expected, let received):
            "Review start admission received conflicting active terminals: expected "
                + "\(String(describing: expected)), received \(String(describing: received))."
        }
    }
}

/// Owns the request admissions that create and interrupt one backend review run.
/// A dispatched request stays outcome-unknown until its response, an explicit
/// rejection, or a typed terminal resolves it.
package actor ReviewStartAdmission {
    package enum RequestDispatch: Equatable, Sendable {
        case notSent
        case outcomeUnknown
    }

    package enum InterruptRequestDispatch: Equatable, Sendable {
        case notSent
        case outcomeUnknown
        case acknowledged
    }

    package enum Terminal: Equatable, Sendable {
        case cancelledBeforeDispatch(ReviewCancellation)
        case connection(ReviewRuntimeCloseFailure)
        case protocolFailure(ReviewStartProtocolFailure)
        case rejected(ReviewStartRequestFailure)
        case active(ReviewInterruptResolution)
        case recovery(ReviewRecoveryDisposition)
    }

    package enum Phase: Equatable, Sendable {
        case preparingThread(RequestDispatch)
        case startingReview(
            preparedRun: CodexReviewBackendModel.Review.Run,
            dispatch: RequestDispatch
        )
        /// `thread/rollback` may have been applied. This phase is entered
        /// immediately before the non-idempotent request is sent.
        case rollingBackRecovery(
            predecessorRun: CodexReviewBackendModel.Review.Run
        )
        case active(CodexReviewBackendModel.Review.Run)
        case interrupting(
            run: CodexReviewBackendModel.Review.Run,
            cancellation: ReviewCancellation,
            request: InterruptRequestDispatch
        )
        case finishing(
            run: CodexReviewBackendModel.Review.Run,
            cancellation: ReviewCancellation,
            terminal: ReviewInterruptTerminal,
            request: InterruptRequestDispatch
        )
        case recovering(
            run: CodexReviewBackendModel.Review.Run,
            trigger: ReviewAttemptRecoveryTrigger,
            request: InterruptRequestDispatch
        )
        case finishingRecovery(
            run: CodexReviewBackendModel.Review.Run,
            trigger: ReviewAttemptRecoveryTrigger,
            terminal: ReviewInterruptTerminal,
            request: InterruptRequestDispatch
        )
        case terminal(Terminal)
    }

    package enum FailedReviewStartDisposition: Equatable, Sendable {
        case cleanup
        case preserveOutcomeUnknown
    }

    private let outcomeUnknownIsCallerOwned: Bool
    private var phase: Phase = .preparingThread(.notSent)
    private var requestedCancellation: ReviewCancellation?
    private var interruptionTask: Task<ReviewInterruptResolution, any Error>?
    private var recoveryTask: Task<ReviewRecoveryDisposition, any Error>?
    private var activeTerminalWaiters: [CheckedContinuation<ReviewInterruptTerminal, Never>] = []

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
        switch phase {
        case .terminal:
            return
        case .preparingThread(.notSent), .startingReview(_, .notSent):
            requestedCancellation = cancellation
            phase = .terminal(.cancelledBeforeDispatch(cancellation))
        case .preparingThread(.outcomeUnknown), .startingReview(_, .outcomeUnknown),
             .rollingBackRecovery, .active, .interrupting, .finishing, .recovering,
             .finishingRecovery:
            requestedCancellation = cancellation
        }
    }

    package func admitThreadStartDispatch() throws {
        switch phase {
        case .preparingThread(.notSent):
            break
        case .terminal(.cancelledBeforeDispatch(let cancellation)):
            throw ReviewStartCancelledBeforeDispatch(cancellation: cancellation)
        case .preparingThread(.outcomeUnknown), .startingReview,
             .rollingBackRecovery, .active,
             .interrupting, .finishing, .recovering, .finishingRecovery,
             .terminal:
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
        case .preparingThread(.notSent), .startingReview, .rollingBackRecovery,
             .active,
             .interrupting, .finishing, .recovering, .finishingRecovery:
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
        case .preparingThread(.notSent), .rollingBackRecovery, .active,
             .interrupting, .finishing,
             .recovering, .finishingRecovery, .terminal:
            throw contractFailure(.wrongPhase(operation: .recordPreparedThread))
        }
    }

    /// Installs an already-existing source thread for a replacement attempt.
    /// Unlike `recordPreparedThread`, this transition proves that no new
    /// `thread/start` request is part of the replacement.
    package func recordPreparedRecoveryRun(
        _ run: CodexReviewBackendModel.Review.Run
    ) throws {
        switch phase {
        case .preparingThread(.notSent):
            if let requestedCancellation {
                phase = .terminal(.cancelledBeforeDispatch(requestedCancellation))
                throw ReviewStartCancelledBeforeDispatch(
                    cancellation: requestedCancellation
                )
            }
            phase = .startingReview(preparedRun: run, dispatch: .notSent)
        case .startingReview(let currentRun, .notSent) where currentRun == run:
            return
        case .preparingThread(.outcomeUnknown), .startingReview,
             .rollingBackRecovery, .active,
             .interrupting, .finishing, .recovering, .finishingRecovery,
             .terminal:
            throw contractFailure(.wrongPhase(
                operation: .recordPreparedRecoveryRun
            ))
        }
    }

    package func admitRecoveryRollbackDispatch(
        for predecessorRun: CodexReviewBackendModel.Review.Run
    ) throws {
        switch phase {
        case .preparingThread(.notSent):
            break
        case .terminal(.cancelledBeforeDispatch(let cancellation)):
            throw ReviewStartCancelledBeforeDispatch(cancellation: cancellation)
        case .preparingThread(.outcomeUnknown), .startingReview,
             .rollingBackRecovery, .active, .interrupting, .finishing,
             .recovering, .finishingRecovery, .terminal:
            throw contractFailure(.wrongPhase(
                operation: .admitRecoveryRollbackDispatch
            ))
        }
        if let requestedCancellation {
            phase = .terminal(.cancelledBeforeDispatch(requestedCancellation))
            throw ReviewStartCancelledBeforeDispatch(
                cancellation: requestedCancellation
            )
        }
        phase = .rollingBackRecovery(predecessorRun: predecessorRun)
    }

    package func recordRecoveryRollbackAcknowledged(
        for predecessorRun: CodexReviewBackendModel.Review.Run
    ) throws {
        guard case .rollingBackRecovery(let currentRun) = phase else {
            throw contractFailure(.wrongPhase(
                operation: .recordRecoveryRollbackAcknowledged
            ))
        }
        guard currentRun == predecessorRun else {
            throw staleRunFailure(
                operation: .recordRecoveryRollbackAcknowledged,
                expected: currentRun,
                received: predecessorRun
            )
        }
        if let requestedCancellation {
            phase = .terminal(.cancelledBeforeDispatch(requestedCancellation))
            throw ReviewStartCancelledBeforeDispatch(
                cancellation: requestedCancellation
            )
        }
        phase = .preparingThread(.notSent)
    }

    package func recordRecoveryRollbackRejected(
        _ failure: ReviewStartRequestFailure,
        for predecessorRun: CodexReviewBackendModel.Review.Run
    ) throws {
        guard case .rejected = failure else {
            throw contractFailure(.retryRequiresExplicitRejection(failure))
        }
        switch phase {
        case .rollingBackRecovery(let currentRun):
            guard currentRun == predecessorRun else {
                throw staleRunFailure(
                    operation: .recordRecoveryRollbackRejected,
                    expected: currentRun,
                    received: predecessorRun
                )
            }
            phase = .terminal(.rejected(failure))
        case .terminal(.rejected(let currentFailure)) where currentFailure == failure:
            return
        case .terminal:
            return
        case .preparingThread, .startingReview, .active, .interrupting,
             .finishing, .recovering,
             .finishingRecovery:
            throw contractFailure(.wrongPhase(
                operation: .recordRecoveryRollbackRejected
            ))
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
        case .preparingThread, .rollingBackRecovery, .active, .interrupting,
             .finishing, .recovering,
             .finishingRecovery, .terminal:
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
        case .preparingThread, .startingReview(_, .notSent),
             .rollingBackRecovery, .active,
             .interrupting, .finishing, .recovering, .finishingRecovery:
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
        case .preparingThread, .startingReview(_, .notSent),
             .rollingBackRecovery, .interrupting,
             .finishing, .recovering, .finishingRecovery, .terminal:
            throw contractFailure(.wrongPhase(operation: .recordActiveRun))
        }
    }

    package func interrupt(
        _ run: CodexReviewBackendModel.Review.Run,
        cancellation: ReviewCancellation,
        request: @escaping @Sendable (
            ReviewInterruptRequestAdmission,
            CodexReviewBackendModel.CancellationReason
        ) async throws -> Void
    ) async throws -> ReviewInterruptResolution {
        let currentRun = try requireActiveRun(
            run,
            operation: .interruptActiveRun
        )
        if let recoveryTask {
            recordJoinedCancellation(cancellation)
            return try checkedInterruptResolution(
                interruptResolution(
                    for: try await recoveryTask.value,
                    cancellation: requestedCancellation ?? cancellation
                )
            )
        }
        if case .terminal(.recovery(let disposition)) = phase {
            return try checkedInterruptResolution(
                interruptResolution(
                    for: disposition,
                    cancellation: requestedCancellation
                )
            )
        }
        if let interruptionTask {
            return try await interruptionTask.value
        }
        if case .terminal(.active(let resolution)) = phase {
            return try checkedInterruptResolution(resolution)
        }
        guard case .active = phase else {
            throw contractFailure(.wrongPhase(operation: .interruptActiveRun))
        }
        _ = try interruptRequestAdmission(for: currentRun)

        let acceptedCancellation = requestedCancellation ?? cancellation
        requestedCancellation = acceptedCancellation
        phase = .interrupting(
            run: currentRun,
            cancellation: acceptedCancellation,
            request: .notSent
        )
        let task = Task {
            try await self.performInterrupt(
                run: currentRun,
                cancellation: acceptedCancellation,
                request: request
            )
        }
        interruptionTask = task
        return try await task.value
    }

    package func beginRecovery(
        _ run: CodexReviewBackendModel.Review.Run,
        trigger: ReviewAttemptRecoveryTrigger,
        request: @escaping @Sendable (
            ReviewInterruptRequestAdmission,
            CodexReviewBackendModel.CancellationReason
        ) async throws -> Void
    ) async throws -> ReviewRecoveryDisposition {
        let currentRun = try requireActiveRun(
            run,
            operation: .recoverActiveRun
        )
        if let recoveryTask {
            return try await recoveryTask.value
        }
        if case .terminal(.recovery(let disposition)) = phase {
            return disposition
        }
        guard interruptionTask == nil else {
            throw ReviewAttemptContractFailure(
                message: "Recovery cannot replace an admitted terminal cancellation."
            )
        }
        if case .terminal(.active(let resolution)) = phase {
            let disposition = makeRecoveryDisposition(
                resolvedAttempt(from: resolution),
                trigger: trigger,
                requestWasAcknowledgedBeforeTerminal: false
            )
            if case .replacement = disposition {
                _ = try interruptRequestAdmission(for: currentRun)
            }
            phase = .terminal(.recovery(disposition))
            return disposition
        }
        guard case .active = phase else {
            throw contractFailure(.wrongPhase(operation: .recoverActiveRun))
        }
        _ = try interruptRequestAdmission(for: currentRun)
        phase = .recovering(
            run: currentRun,
            trigger: trigger,
            request: .notSent
        )
        let task = Task {
            try await self.performRecovery(
                run: currentRun,
                trigger: trigger,
                request: request
            )
        }
        recoveryTask = task
        return try await task.value
    }

    package func recordCanonicalTerminal(
        _ terminal: ReviewTerminalRecord,
        for run: CodexReviewBackendModel.Review.Run
    ) throws {
        _ = try requireActiveRun(run, operation: .recordCanonicalTerminal)
        let normalizedTerminal: ReviewTerminalRecord
        if case .interrupted = terminal,
           let cancellation = terminalInterruptionCancellation {
            normalizedTerminal = .interrupted(.requested(cancellation))
        } else {
            normalizedTerminal = terminal
        }
        try recordActiveTerminal(
            .canonical(normalizedTerminal),
            for: run,
            operation: .recordCanonicalTerminal
        )
    }

    package func recordConnectionTerminal(
        _ failure: ReviewRuntimeCloseFailure,
        for run: CodexReviewBackendModel.Review.Run
    ) throws {
        guard case .connection = failure else {
            throw contractFailure(.connectionTerminalRequiresConnectionFailure(failure))
        }
        _ = try requireActiveRun(run, operation: .recordActiveConnectionTerminal)
        try recordActiveTerminal(
            .connection(failure),
            for: run,
            operation: .recordActiveConnectionTerminal
        )
    }

    package func recordStreamTerminal(
        _ failure: ReviewAttemptStreamFailure,
        for run: CodexReviewBackendModel.Review.Run
    ) throws {
        _ = try requireActiveRun(run, operation: .recordActiveStreamTerminal)
        try recordActiveTerminal(
            .stream(failure),
            for: run,
            operation: .recordActiveStreamTerminal
        )
    }

    package func recordConnectionTerminal(
        _ failure: ReviewRuntimeCloseFailure
    ) throws {
        guard case .connection = failure else {
            throw contractFailure(.connectionTerminalRequiresConnectionFailure(failure))
        }
        switch phase {
        case .preparingThread(.outcomeUnknown), .startingReview(_, .outcomeUnknown),
             .rollingBackRecovery:
            phase = .terminal(.connection(failure))
        case .terminal:
            return
        case .preparingThread(.notSent), .startingReview(_, .notSent), .active,
             .interrupting, .finishing, .recovering, .finishingRecovery:
            throw contractFailure(.wrongPhase(operation: .recordConnectionTerminal))
        }
    }

    package func recordProtocolTerminal(
        _ failure: ReviewStartProtocolFailure
    ) throws {
        switch phase {
        case .preparingThread(.outcomeUnknown), .startingReview(_, .outcomeUnknown),
             .rollingBackRecovery:
            phase = .terminal(.protocolFailure(failure))
        case .terminal(.protocolFailure(let currentFailure)) where currentFailure == failure:
            return
        case .terminal:
            return
        case .preparingThread(.notSent), .startingReview(_, .notSent), .active,
             .interrupting, .finishing, .recovering, .finishingRecovery:
            throw contractFailure(.wrongPhase(operation: .recordProtocolTerminal))
        }
    }

    package func cancellationRequest() -> ReviewCancellation? {
        switch phase {
        case .interrupting(_, let cancellation, _),
             .finishing(_, let cancellation, _, _):
            cancellation
        case .terminal(.active(let resolution)):
            resolution.cancellation
        case .rollingBackRecovery, .recovering, .finishingRecovery:
            requestedCancellation
        case .terminal(.recovery):
            requestedCancellation
        case .preparingThread, .startingReview, .active, .terminal:
            requestedCancellation
        }
    }

    package func activeTerminalResolution() -> ReviewInterruptResolution? {
        switch phase {
        case .terminal(.active(let resolution)):
            return resolution
        case .terminal(.recovery(let disposition)):
            return interruptResolution(
                for: disposition,
                cancellation: requestedCancellation
            )
        case .preparingThread, .startingReview, .rollingBackRecovery, .active,
             .interrupting,
             .finishing, .recovering, .finishingRecovery, .terminal:
            return nil
        }
    }

    package func hasRecordedActiveTerminal(
        for run: CodexReviewBackendModel.Review.Run
    ) throws -> Bool {
        _ = try requireActiveRun(run, operation: .inspectRecordedActiveTerminal)
        return activeTerminalSource != nil
    }

    package func currentPhase() -> Phase {
        phase
    }

    package func permitsRecoveryPublication(
        of run: CodexReviewBackendModel.Review.Run
    ) -> Bool {
        requestedCancellation == nil && phase == .active(run)
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

    private func performInterrupt(
        run: CodexReviewBackendModel.Review.Run,
        cancellation: ReviewCancellation,
        request: @escaping @Sendable (
            ReviewInterruptRequestAdmission,
            CodexReviewBackendModel.CancellationReason
        ) async throws -> Void
    ) async throws -> ReviewInterruptResolution {
        let barrier = try await performInterruptionBarrier(
            run: run,
            reason: .init(message: cancellation.message),
            request: request
        )
        let resolution = ReviewInterruptResolution(
            run: run,
            cancellation: cancellation,
            terminal: barrier.terminal,
            requestFailure: barrier.requestFailure
        )
        phase = .terminal(.active(resolution))
        interruptionTask = nil
        return try checkedInterruptResolution(resolution)
    }

    private func performRecovery(
        run: CodexReviewBackendModel.Review.Run,
        trigger: ReviewAttemptRecoveryTrigger,
        request: @escaping @Sendable (
            ReviewInterruptRequestAdmission,
            CodexReviewBackendModel.CancellationReason
        ) async throws -> Void
    ) async throws -> ReviewRecoveryDisposition {
        do {
            let requestCancellation = requestedCancellation ?? trigger.cancellation
            let barrier = try await performInterruptionBarrier(
                run: run,
                reason: .init(message: requestCancellation.message),
                request: request
            )
            let resolved = ReviewResolvedAttemptTerminal(
                run: run,
                terminal: recoveryBarrierTerminal(from: barrier.terminal),
                requestFailure: barrier.requestFailure
            )
            let disposition = makeRecoveryDisposition(
                resolved,
                trigger: trigger,
                requestWasAcknowledgedBeforeTerminal:
                    recoveryRequestWasAcknowledgedBeforeTerminal
            )
            phase = .terminal(.recovery(disposition))
            recoveryTask = nil
            return disposition
        } catch {
            recoveryTask = nil
            throw error
        }
    }

    private func performInterruptionBarrier(
        run: CodexReviewBackendModel.Review.Run,
        reason: CodexReviewBackendModel.CancellationReason,
        request: @escaping @Sendable (
            ReviewInterruptRequestAdmission,
            CodexReviewBackendModel.CancellationReason
        ) async throws -> Void
    ) async throws -> (
        terminal: ReviewInterruptTerminal,
        requestFailure: ReviewInterruptRequestFailure?
    ) {
        let requestResult: Result<Void, ReviewInterruptRequestFailure>
        if let requestAdmission = try beginInterruptRequestDispatch(for: run) {
            do {
                try await request(requestAdmission, reason)
                requestResult = .success(())
            } catch let failure as ReviewInterruptRequestFailure {
                requestResult = .failure(failure)
            } catch {
                requestResult = .failure(.init(
                    outcome: .outcomeUnknown(message: error.localizedDescription)
                ))
            }
            if case .success = requestResult {
                try recordInterruptRequestAcknowledged(for: run)
            }
        } else {
            requestResult = .success(())
        }

        if case .failure(let failure) = requestResult,
           case .rejected = failure.outcome,
           activeTerminalSource == nil {
            switch phase {
            case .recovering:
                recoveryTask = nil
            case .interrupting:
                interruptionTask = nil
            case .preparingThread, .startingReview, .rollingBackRecovery,
                 .active, .finishing,
                 .finishingRecovery, .terminal:
                break
            }
            requestedCancellation = nil
            phase = .active(run)
            throw failure
        }

        let terminal: ReviewInterruptTerminal
        if let activeTerminalSource {
            terminal = activeTerminalSource
        } else {
            terminal = await waitForActiveTerminal()
        }

        var requestFailure: ReviewInterruptRequestFailure?
        if case .failure(let failure) = requestResult {
            if case .outcomeUnknown = failure.outcome,
               let barrierDiagnostic = barrierDiagnostic(for: terminal) {
                requestFailure = .init(
                    outcome: failure.outcome,
                    secondaryBarrierDiagnostic: barrierDiagnostic
                )
            } else {
                requestFailure = failure
            }
        }
        return (terminal, requestFailure)
    }

    private func recordActiveTerminal(
        _ terminal: ReviewInterruptTerminal,
        for run: CodexReviewBackendModel.Review.Run,
        operation: ReviewStartAdmissionOperation
    ) throws {
        switch phase {
        case .active:
            let resolution = ReviewInterruptResolution(
                run: run,
                cancellation: nil,
                terminal: terminal
            )
            phase = .terminal(.active(resolution))
        case .interrupting(_, let cancellation, let request):
            phase = .finishing(
                run: run,
                cancellation: cancellation,
                terminal: terminal,
                request: request
            )
            resumeActiveTerminalWaiters(returning: terminal)
        case .recovering(_, let trigger, let request):
            phase = .finishingRecovery(
                run: run,
                trigger: trigger,
                terminal: terminal,
                request: request
            )
            resumeActiveTerminalWaiters(returning: terminal)
        case .finishing(_, _, let currentTerminal, _):
            guard currentTerminal == terminal else {
                throw conflictingActiveTerminalFailure(
                    expected: currentTerminal,
                    received: terminal
                )
            }
        case .finishingRecovery(_, _, let currentTerminal, _):
            guard currentTerminal == terminal else {
                throw conflictingActiveTerminalFailure(
                    expected: currentTerminal,
                    received: terminal
                )
            }
        case .terminal(.active(let resolution)):
            guard resolution.terminal == terminal else {
                throw conflictingActiveTerminalFailure(
                    expected: resolution.terminal,
                    received: terminal
                )
            }
        case .terminal(.recovery(let disposition)):
            let currentTerminal = interruptTerminal(
                from: disposition.resolved.terminal
            )
            let normalizedReceived = interruptTerminal(
                from: recoveryBarrierTerminal(from: terminal)
            )
            guard currentTerminal == normalizedReceived else {
                throw conflictingActiveTerminalFailure(
                    expected: currentTerminal,
                    received: normalizedReceived
                )
            }
        case .preparingThread, .startingReview, .rollingBackRecovery, .terminal:
            throw contractFailure(.wrongPhase(operation: operation))
        }
    }

    private func beginInterruptRequestDispatch(
        for run: CodexReviewBackendModel.Review.Run
    ) throws -> ReviewInterruptRequestAdmission? {
        switch phase {
        case .interrupting(let currentRun, let cancellation, .notSent):
            guard currentRun == run else {
                throw staleRunFailure(
                    operation: .interruptActiveRun,
                    expected: currentRun,
                    received: run
                )
            }
            let requestAdmission = try interruptRequestAdmission(for: currentRun)
            phase = .interrupting(
                run: currentRun,
                cancellation: cancellation,
                request: .outcomeUnknown
            )
            return requestAdmission
        case .recovering(let currentRun, let trigger, .notSent):
            guard currentRun == run else {
                throw staleRunFailure(
                    operation: .recoverActiveRun,
                    expected: currentRun,
                    received: run
                )
            }
            let requestAdmission = try interruptRequestAdmission(for: currentRun)
            phase = .recovering(
                run: currentRun,
                trigger: trigger,
                request: .outcomeUnknown
            )
            return requestAdmission
        case .finishing(_, _, _, .notSent),
             .finishingRecovery(_, _, _, .notSent),
             .terminal(.active), .terminal(.recovery):
            return nil
        case .preparingThread, .startingReview, .rollingBackRecovery, .active,
             .interrupting,
             .finishing, .recovering, .finishingRecovery, .terminal:
            throw contractFailure(.wrongPhase(operation: .interruptActiveRun))
        }
    }

    private func recordInterruptRequestAcknowledged(
        for run: CodexReviewBackendModel.Review.Run
    ) throws {
        switch phase {
        case .interrupting(let currentRun, let cancellation, .outcomeUnknown):
            guard currentRun == run else {
                throw staleRunFailure(
                    operation: .recordInterruptRequestAcknowledged,
                    expected: currentRun,
                    received: run
                )
            }
            phase = .interrupting(
                run: run,
                cancellation: cancellation,
                request: .acknowledged
            )
        case .finishing(
            let currentRun,
            let cancellation,
            let terminal,
            .outcomeUnknown
        ):
            guard currentRun == run else {
                throw staleRunFailure(
                    operation: .recordInterruptRequestAcknowledged,
                    expected: currentRun,
                    received: run
                )
            }
            phase = .finishing(
                run: run,
                cancellation: cancellation,
                terminal: terminal,
                request: .acknowledged
            )
        case .recovering(let currentRun, let trigger, .outcomeUnknown):
            guard currentRun == run else {
                throw staleRunFailure(
                    operation: .recordInterruptRequestAcknowledged,
                    expected: currentRun,
                    received: run
                )
            }
            phase = .recovering(
                run: run,
                trigger: trigger,
                request: .acknowledged
            )
        case .finishingRecovery(
            let currentRun,
            _,
            _,
            .outcomeUnknown
        ):
            guard currentRun == run else {
                throw staleRunFailure(
                    operation: .recordInterruptRequestAcknowledged,
                    expected: currentRun,
                    received: run
                )
            }
            // Preserve the request state captured when the terminal won. A
            // late ACK drains the request but cannot move its linearization
            // ahead of that already-recorded terminal.
            return
        case .preparingThread, .startingReview, .rollingBackRecovery, .active,
             .interrupting,
             .finishing, .recovering, .finishingRecovery, .terminal:
            throw contractFailure(.wrongPhase(
                operation: .recordInterruptRequestAcknowledged
            ))
        }
    }

    private func waitForActiveTerminal() async -> ReviewInterruptTerminal {
        if let activeTerminalSource {
            return activeTerminalSource
        }
        return await withCheckedContinuation { continuation in
            if let activeTerminalSource {
                continuation.resume(returning: activeTerminalSource)
            } else {
                activeTerminalWaiters.append(continuation)
            }
        }
    }

    private func resumeActiveTerminalWaiters(
        returning terminal: ReviewInterruptTerminal
    ) {
        let waiters = activeTerminalWaiters
        activeTerminalWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: terminal)
        }
    }

    private func requireActiveRun(
        _ run: CodexReviewBackendModel.Review.Run,
        operation: ReviewStartAdmissionOperation
    ) throws -> CodexReviewBackendModel.Review.Run {
        guard let currentRun = activeRunIdentity else {
            throw contractFailure(.wrongPhase(operation: operation))
        }
        guard currentRun == run else {
            throw staleRunFailure(
                operation: operation,
                expected: currentRun,
                received: run
            )
        }
        return currentRun
    }

    private func checkedInterruptResolution(
        _ resolution: ReviewInterruptResolution
    ) throws -> ReviewInterruptResolution {
        if let requestFailure = resolution.requestFailure,
           case .outcomeUnknown = requestFailure.outcome,
           barrierDiagnostic(for: resolution.terminal) != nil {
            throw requestFailure
        }
        return resolution
    }

    private func recordJoinedCancellation(_ cancellation: ReviewCancellation) {
        if requestedCancellation == nil {
            requestedCancellation = cancellation
        }
    }

    private func resolvedAttempt(
        from resolution: ReviewInterruptResolution
    ) -> ReviewResolvedAttemptTerminal {
        .init(
            run: resolution.run,
            terminal: recoveryBarrierTerminal(from: resolution.terminal),
            requestFailure: resolution.requestFailure
        )
    }

    private func interruptResolution(
        for disposition: ReviewRecoveryDisposition,
        cancellation: ReviewCancellation?
    ) -> ReviewInterruptResolution {
        let resolved = disposition.resolved
        return .init(
            run: resolved.run,
            cancellation: cancellation,
            terminal: interruptTerminal(from: resolved.terminal),
            requestFailure: resolved.requestFailure
        )
    }

    private func makeRecoveryDisposition(
        _ resolved: ReviewResolvedAttemptTerminal,
        trigger: ReviewAttemptRecoveryTrigger,
        requestWasAcknowledgedBeforeTerminal: Bool
    ) -> ReviewRecoveryDisposition {
        switch resolved.terminal {
        case .canonical(let terminal):
            switch terminal {
            case .completed, .failed:
                return .productTerminal(.init(
                    resolved: resolved,
                    productTerminal: terminal
                ))
            case .interrupted(let cause):
                if case .requested = cause {
                    return .productTerminal(.init(
                        resolved: resolved,
                        productTerminal: terminal
                    ))
                }
                if let requestedCancellation {
                    let productTerminal: ReviewTerminalRecord =
                        requestWasAcknowledgedBeforeTerminal
                        ? .interrupted(.requested(requestedCancellation))
                        : terminal
                    return .productTerminal(.init(
                        resolved: resolved,
                        productTerminal: productTerminal
                    ))
                }
                return .replacement(.init(resolved: resolved, trigger: trigger))
            }
        case .stream(let failure):
            if let requestedCancellation {
                let resolvedProductTerminal: ReviewTerminalRecord
                if requestWasAcknowledgedBeforeTerminal {
                    switch failure {
                    case .recoverableNetwork, .ownerForcedConnectionClose,
                         .unexpectedConnection:
                        resolvedProductTerminal = .interrupted(
                            .requested(requestedCancellation)
                        )
                    case .process, .protocolViolation, .workerContract,
                         .ownerCancellation:
                        resolvedProductTerminal = productTerminal(for: failure)
                    }
                } else {
                    resolvedProductTerminal = productTerminal(for: failure)
                }
                return .productTerminal(.init(
                    resolved: resolved,
                    productTerminal: resolvedProductTerminal
                ))
            }
            if failure.permitsRecoveryReplacement {
                return .replacement(.init(resolved: resolved, trigger: trigger))
            }
            return .productTerminal(.init(
                resolved: resolved,
                productTerminal: productTerminal(for: failure)
            ))
        }
    }

    private func productTerminal(
        for failure: ReviewAttemptStreamFailure
    ) -> ReviewTerminalRecord {
        switch failure {
        case .process:
            .interrupted(.previousProcessExit)
        case .protocolViolation(let failure), .workerContract(let failure):
            .failed(message: failure.localizedDescription)
        case .ownerCancellation:
            .failed(message: failure.localizedDescription)
        case .recoverableNetwork, .ownerForcedConnectionClose,
             .unexpectedConnection:
            .interrupted(.transport(message: failure.localizedDescription))
        }
    }

    private func recoveryBarrierTerminal(
        from terminal: ReviewInterruptTerminal
    ) -> ReviewAttemptBarrierTerminal {
        switch terminal {
        case .canonical(let terminal):
            .canonical(terminal)
        case .connection(let failure):
            .stream(.unexpectedConnection(failure))
        case .stream(let failure):
            .stream(failure)
        }
    }

    private func interruptTerminal(
        from terminal: ReviewAttemptBarrierTerminal
    ) -> ReviewInterruptTerminal {
        switch terminal {
        case .canonical(let terminal):
            .canonical(terminal)
        case .stream(let failure):
            .stream(failure)
        }
    }

    private func barrierDiagnostic(
        for terminal: ReviewInterruptTerminal
    ) -> String? {
        switch terminal {
        case .canonical:
            nil
        case .connection(let failure):
            failure.localizedDescription
        case .stream(let failure):
            failure.localizedDescription
        }
    }

    private func interruptRequestAdmission(
        for run: CodexReviewBackendModel.Review.Run
    ) throws -> ReviewInterruptRequestAdmission {
        guard let threadID = run.reviewThreadID,
              threadID.isEmpty == false,
              let turnID = run.turnID,
              turnID.isEmpty == false
        else {
            throw contractFailure(.interruptRequestRequiresCanonicalPair(run))
        }
        return .init(run: run, threadID: threadID, turnID: turnID)
    }

    private func conflictingActiveTerminalFailure(
        expected: ReviewInterruptTerminal,
        received: ReviewInterruptTerminal
    ) -> ReviewStartAdmissionContractFailure {
        contractFailure(.conflictingActiveTerminal(
            expected: expected,
            received: received
        ))
    }

    private var activeRunIdentity: CodexReviewBackendModel.Review.Run? {
        switch phase {
        case .active(let run), .interrupting(let run, _, _),
             .finishing(let run, _, _, _), .recovering(let run, _, _),
             .finishingRecovery(let run, _, _, _):
            run
        case .terminal(.active(let resolution)):
            resolution.run
        case .terminal(.recovery(let disposition)):
            disposition.resolved.run
        case .preparingThread, .startingReview, .rollingBackRecovery, .terminal:
            nil
        }
    }

    private var terminalInterruptionCancellation: ReviewCancellation? {
        switch phase {
        case .interrupting(_, let cancellation, _),
             .finishing(_, let cancellation, _, _):
            cancellation
        case .terminal(.active(let resolution)):
            resolution.cancellation
        case .recovering, .finishingRecovery:
            nil
        case .preparingThread, .startingReview, .rollingBackRecovery,
             .active, .terminal:
            nil
        }
    }

    private var recoveryRequestWasAcknowledgedBeforeTerminal: Bool {
        guard case .finishingRecovery(_, _, _, let request) = phase else {
            return false
        }
        return request == .acknowledged
    }

    private var activeTerminalSource: ReviewInterruptTerminal? {
        switch phase {
        case .finishing(_, _, let terminal, _):
            terminal
        case .finishingRecovery(_, _, let terminal, _):
            terminal
        case .terminal(.active(let resolution)):
            resolution.terminal
        case .terminal(.recovery(let disposition)):
            interruptTerminal(from: disposition.resolved.terminal)
        case .preparingThread, .startingReview, .rollingBackRecovery, .active,
             .interrupting,
             .recovering, .terminal:
            nil
        }
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
