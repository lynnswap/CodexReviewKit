import Foundation

enum ReviewStoreStartupDisposition: Sendable {
    case proceed
    case cleanupOnly(ReviewCancellation)
    case abandoned
}

struct ReviewStoreWorkerSnapshot: Sendable {
    let isTerminal: Bool
    let pendingCancellation: ReviewCancellation?
    let cancellation: ReviewCancellation?
}

@MainActor
final class ReviewStoreCommitSink {
    private weak var store: CodexReviewStore?

    init(store: CodexReviewStore) {
        self.store = store
    }

    func startupDisposition(for runID: ReviewRunID) -> ReviewStoreStartupDisposition {
        guard let store, let runRecord = store.reviewRun(id: runID) else {
            return .abandoned
        }
        if let cancellation = store.runtimeState.startupCancellation(for: runID)
            ?? runRecord.pendingCancellation
            ?? runRecord.core.cancellation
        {
            return .cleanupOnly(cancellation)
        }
        return runRecord.isTerminal ? .abandoned : .proceed
    }

    func publishAttempt(
        _ attempt: ReviewAttempt,
        runID: ReviewRunID,
        attemptGeneration: UInt64
    ) -> Bool {
        guard let store,
              let runRecord = store.reviewRun(id: runID),
              runRecord.isTerminal == false,
              store.runtimeState.startupCancellation(for: runID) == nil
        else {
            return false
        }
        let startedAt: Date
        switch runRecord.core {
        case .queued:
            startedAt = store.clock.now()
        case .running(_, let existingStartedAt):
            startedAt = existingStartedAt
        case .startFailed, .cancelledBeforeStart, .succeeded, .failed, .cancelled:
            return false
        }
        store.runtimeState.clearStarting(runID)
        _ = store.runtimeState.takeStartupCancellation(for: runID)
        store.runtimeState.setActiveAttempt(attempt, for: runID)
        store.runtimeState.setCancellationAuthority(.interrupt(attempt), for: runID)
        runRecord.core = .running(attempt: attempt, startedAt: startedAt)
        runRecord.executionPhase = .running(attemptGeneration: attemptGeneration)
        store.noteReviewRunMutation()
        return true
    }

    func workerSnapshot(for runID: ReviewRunID) -> ReviewStoreWorkerSnapshot? {
        guard let store, let runRecord = store.reviewRun(id: runID) else {
            return nil
        }
        return .init(
            isTerminal: runRecord.isTerminal,
            pendingCancellation: runRecord.pendingCancellation,
            cancellation: runRecord.pendingCancellation ?? runRecord.core.cancellation
        )
    }

    func setExecutionPhase(
        _ phase: ReviewExecutionPhase,
        cancellationAuthority: ReviewWorkerCancellationAuthority,
        for runID: ReviewRunID
    ) {
        guard let store,
              let runRecord = store.reviewRun(id: runID),
              runRecord.isTerminal == false else {
            return
        }
        runRecord.executionPhase = phase
        store.runtimeState.setCancellationAuthority(cancellationAuthority, for: runID)
        if case .waitingForNetwork = phase {
            store.runtimeState.markWaitingForNetworkRecovery(runID)
        } else {
            store.runtimeState.clearWaitingForNetworkRecovery(runID)
        }
        store.noteReviewRunMutation()
    }

    func setCancellationAuthority(
        _ authority: ReviewWorkerCancellationAuthority,
        for runID: ReviewRunID
    ) {
        guard let store,
              let runRecord = store.reviewRun(id: runID),
              runRecord.isTerminal == false else {
            return
        }
        store.runtimeState.setCancellationAuthority(authority, for: runID)
    }

    func commitTerminal(_ terminal: ReviewBackendTerminal, for runID: ReviewRunID) {
        guard let store,
              let runRecord = store.reviewRun(id: runID),
              runRecord.isTerminal == false else {
            return
        }
        if let cancellation = runRecord.pendingCancellation {
            store.commitCancellationLocally(runRecord, cancellation: cancellation)
            return
        }
        switch terminal {
        case .completed:
            guard case .running(let attempt, let startedAt) = runRecord.core else {
                preconditionFailure("Only a running review attempt can complete.")
            }
            runRecord.core = .succeeded(
                attempt: attempt,
                startedAt: startedAt,
                endedAt: store.clock.now()
            )
            runRecord.pendingCancellation = nil
            runRecord.cancellationRequested = false
            runRecord.executionPhase = nil
            store.noteReviewRunMutation()
        case .interrupted(let message):
            markFailure(
                .interruptedByBackend(message: message),
                runRecord: runRecord,
                store: store
            )
        case .failed(let failure):
            markFailure(failure, runRecord: runRecord, store: store)
        }
    }

    func commitWorkerCancellation(
        for runID: ReviewRunID,
        fallback: ReviewCancellation = .system()
    ) {
        guard let store,
              let runRecord = store.reviewRun(id: runID),
              runRecord.isTerminal == false else {
            return
        }
        store.commitCancellationLocally(
            runRecord,
            cancellation: runRecord.pendingCancellation
                ?? store.runtimeState.startupCancellation(for: runID)
                ?? fallback
        )
    }

    func markWorkerFailure(_ failure: ReviewBackendFailure, for runID: ReviewRunID) {
        guard let store,
              let runRecord = store.reviewRun(id: runID),
              runRecord.isTerminal == false else {
            return
        }
        if let cancellation = runRecord.pendingCancellation
            ?? store.runtimeState.startupCancellation(for: runID)
        {
            store.commitCancellationLocally(runRecord, cancellation: cancellation)
            return
        }
        markFailure(failure, runRecord: runRecord, store: store)
    }

    func interruptSucceeded(
        runID: ReviewRunID,
        cancellation: ReviewCancellation
    ) {
        guard let store, let runRecord = store.reviewRun(id: runID) else {
            return
        }
        if runRecord.isTerminal == false {
            store.commitCancellationLocally(
                runRecord,
                cancellation: runRecord.pendingCancellation ?? cancellation
            )
        }
        store.runtimeState.cancelActiveWorker(for: runID)
    }

    func cancelWorker(for runID: ReviewRunID) {
        store?.runtimeState.cancelActiveWorker(for: runID)
    }

    func cancelReview(
        runID: ReviewRunID,
        cancellation: ReviewCancellation
    ) async -> ReviewBackendFailure? {
        guard let store else {
            return .protocolViolation(
                message: "The review store was released before its accepted cancellation completed."
            )
        }
        do {
            _ = try await store.cancelReview(runID: runID, cancellation: cancellation)
            return nil
        } catch {
            return cancellationBackendFailure(error)
        }
    }

    func interruptFailed(
        runID: ReviewRunID,
        resumePhase: ReviewExecutionPhase
    ) -> Bool {
        guard let store, let runRecord = store.reviewRun(id: runID) else {
            return true
        }
        guard runRecord.isTerminal == false else {
            return true
        }
        runRecord.cancellationRequested = false
        runRecord.pendingCancellation = nil
        runRecord.executionPhase = resumePhase
        store.noteReviewRunMutation()
        return false
    }

    func cancellationOperationFinished(
        runID: ReviewRunID,
        token: ReviewCancellationOperationToken
    ) {
        store?.runtimeState.cancellationOperationFinished(for: runID, token: token)
    }

    func workerFinished(runID: ReviewRunID, generation: ReviewWorkerGeneration) {
        guard let store else {
            return
        }
        store.runtimeState.clearReviewRunState(for: runID)
        store.runtimeState.workerFinished(for: runID, generation: generation)
    }

    func cancellationOutcome(runID: ReviewRunID) -> CodexReviewAPI.Cancel.Outcome? {
        guard let store, let runRecord = store.reviewRun(id: runID) else {
            return nil
        }
        return .init(
            runID: runID,
            cancelled: runRecord.core.status == .cancelled,
            core: runRecord.core,
            presentation: runRecord.presentation
        )
    }

    private func markFailure(
        _ failure: ReviewBackendFailure,
        runRecord: ReviewRunRecord,
        store: CodexReviewStore
    ) {
        let endedAt = store.clock.now()
        switch runRecord.core {
        case .queued:
            runRecord.core = .startFailed(endedAt: endedAt, failure: failure)
        case .running(let attempt, let startedAt):
            runRecord.core = .failed(
                attempt: attempt,
                startedAt: startedAt,
                endedAt: endedAt,
                failure: failure
            )
        case .startFailed, .cancelledBeforeStart, .succeeded, .failed, .cancelled:
            return
        }
        runRecord.cancellationRequested = false
        runRecord.pendingCancellation = nil
        runRecord.executionPhase = nil
        store.noteReviewRunMutation()
    }
}
