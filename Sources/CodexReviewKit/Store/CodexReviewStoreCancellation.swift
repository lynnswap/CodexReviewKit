import Foundation

extension CodexReviewStore {
    package func completeCancellationLocally(
        runID: ReviewRunID,
        sessionID: String,
        cancellation: ReviewCancellation = .system()
    ) throws {
        guard let runRecord = reviewRun(id: runID)
        else {
            throw CodexReviewAPI.Error.runNotFound("Run \(runID.rawValue) was not found.")
        }
        guard runRecord.sessionID == sessionID
        else {
            throw CodexReviewAPI.Error.runNotFound("Run \(runID.rawValue) was not found.")
        }

        commitCancellationLocally(runRecord, cancellation: cancellation)
    }

    package func commitCancellationLocally(
        _ runRecord: ReviewRunRecord,
        cancellation: ReviewCancellation = .system()
    ) {
        guard let ownedRunRecord = reviewRun(id: runRecord.id) else {
            preconditionFailure("A review cancellation can only be committed for a store-owned run.")
        }
        precondition(
            ownedRunRecord === runRecord,
            "A review cancellation can only be committed to the store-owned run instance."
        )
        guard runRecord.isTerminal == false else {
            return
        }

        let endedAt = clock.now()
        runRecord.cancellationRequested = false
        runRecord.pendingCancellation = nil
        switch runRecord.core {
        case .queued:
            runRecord.core = .cancelledBeforeStart(
                endedAt: endedAt,
                cancellation: cancellation
            )
        case .running(let attempt, let startedAt):
            runRecord.core = .cancelled(
                attempt: attempt,
                startedAt: startedAt,
                endedAt: endedAt,
                cancellation: cancellation
            )
        case .startFailed, .cancelledBeforeStart, .succeeded, .failed, .cancelled:
            return
        }
        runRecord.executionPhase = nil
        noteReviewRunMutation()
    }

    package func recordCancellationFailure(
        runID: ReviewRunID,
        sessionID: String,
        message _: String
    ) throws {
        guard let runRecord = reviewRun(id: runID)
        else {
            throw CodexReviewAPI.Error.runNotFound("Run \(runID.rawValue) was not found.")
        }
        guard runRecord.sessionID == sessionID
        else {
            throw CodexReviewAPI.Error.runNotFound("Run \(runID.rawValue) was not found.")
        }

        commitCancellationFailure(runRecord)
    }

    package func commitCancellationFailure(_ runRecord: ReviewRunRecord) {
        guard let ownedRunRecord = reviewRun(id: runRecord.id) else {
            preconditionFailure("A cancellation failure can only be committed for a store-owned run.")
        }
        precondition(
            ownedRunRecord === runRecord,
            "A cancellation failure can only be committed to the store-owned run instance."
        )

        runRecord.cancellationRequested = false
        runRecord.pendingCancellation = nil
        switch runRecord.core {
        case .queued:
            runRecord.executionPhase = .starting
        case .running:
            runRecord.executionPhase = .running(attemptGeneration: 0)
        case .startFailed, .cancelledBeforeStart, .succeeded, .failed, .cancelled:
            runRecord.executionPhase = nil
        }
        writeDiagnosticsIfNeeded()
    }

    package func recordCancellationFailure(
        runID: ReviewRunID,
        message: String
    ) throws {
        guard let runRecord = reviewRun(id: runID)
        else {
            throw CodexReviewAPI.Error.runNotFound("Run \(runID.rawValue) was not found.")
        }
        try recordCancellationFailure(
            runID: runID,
            sessionID: runRecord.sessionID,
            message: message
        )
    }

    package func cancelAllRunningReviewRuns(
        reason: String = "Cancellation requested."
    ) async throws {
        let cancellation = ReviewCancellation.system(
            message: reason.nilIfEmpty ?? "Cancellation requested."
        )
        let cancellableReviewRuns = orderedReviewRuns.filter(isCancellableReviewRun)
        var firstError: (any Error)?
        for runRecord in cancellableReviewRuns {
            do {
                _ = try await cancelReview(
                    runID: runRecord.id,
                    sessionID: runRecord.sessionID,
                    cancellation: cancellation
                )
            } catch {
                commitCancellationFailure(runRecord)
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    package func cleanupActiveReviewsForRuntimeStop(
        reason: ReviewCancellation = .system(message: "Review runtime stopped."),
        cleanupBackendReviews:
            @escaping @Sendable (
                CodexReviewRuntimeStopReviewCleanupRequest
            ) async -> Bool
    ) async -> CodexReviewRuntimeStopReviewCleanupResult {
        let activeRunIDs = Set(
            orderedReviewRuns
                .filter { $0.isTerminal == false }
                .map(\.id)
        )
        markActiveReviewCancellationsPendingForRuntimeStop(reason: reason)
        let request = runtimeStopReviewCleanupRequest(reason: reason)
        let didCompleteInitialBackendCleanup = await cleanupBackendReviews(request)
        _ = cancelActiveReviewsLocallyForRuntimeStop(
            reason: reason,
            cancelWorkers: false
        )
        for runID in activeRunIDs {
            runtimeState.cancelActiveWorker(for: runID)
        }
        for task in runtimeState.ownedTasks(for: activeRunIDs) {
            await task.value
        }
        let didCompleteFinalBackendCleanup = await cleanupBackendReviews(request)
        let didDrainReviewWorkers = activeRunIDs.allSatisfy { runtimeState.isDrained($0) }
        return .init(
            didCompleteBackendCleanup:
                didCompleteInitialBackendCleanup && didCompleteFinalBackendCleanup,
            didDrainReviewWorkers: didDrainReviewWorkers
        )
    }

    package func runtimeStopReviewAttemptOwners() -> [ReviewRunID: ReviewAttempt] {
        Dictionary(uniqueKeysWithValues: orderedReviewRuns.compactMap { runRecord in
            guard let attempt = runRecord.core.attempt else {
                return nil
            }
            return (runRecord.id, attempt)
        })
    }

    package func retainPreparedRestartAttemptsForRuntimeStop(
        _ attemptsByRunID: [ReviewRunID: [ReviewAttempt]]
    ) async -> Bool {
        var didRetainAll = true
        for runID in attemptsByRunID.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            for attempt in attemptsByRunID[runID, default: []] {
                do {
                    try await claimReviewThreadOwnership(attempt, for: runID)
                } catch {
                    didRetainAll = false
                }
            }
        }
        return didRetainAll
    }

    private func markActiveReviewCancellationsPendingForRuntimeStop(
        reason: ReviewCancellation
    ) {
        for runRecord in orderedReviewRuns where runRecord.isTerminal == false {
            runRecord.cancellationRequested = true
            runRecord.pendingCancellation = reason
            runRecord.executionPhase = .cancelling(reason)
        }
    }

    private func runtimeStopReviewCleanupRequest(
        reason: ReviewCancellation
    ) -> CodexReviewRuntimeStopReviewCleanupRequest {
        return .init(
            reason: .init(message: reason.message),
            recoveryWaitingAttempts: runtimeState.recoveryWaitingAttempts()
        )
    }

    @discardableResult
    package func cancelActiveReviewsLocallyForRuntimeStop(
        reason: ReviewCancellation = .system(message: "Review runtime stopped."),
        cancelWorkers: Bool = true
    ) -> [ReviewRunID] {
        let activeReviewRunIDs =
            orderedReviewRuns
            .filter { $0.isTerminal == false }
            .map(\.id)
        guard activeReviewRunIDs.isEmpty == false else {
            return []
        }

        for runID in activeReviewRunIDs {
            if let runRecord = reviewRun(id: runID), runRecord.isTerminal == false {
                commitCancellationLocally(runRecord, cancellation: reason)
            }
            if cancelWorkers {
                runtimeState.cancelActiveWorker(for: runID)
            }
        }
        return activeReviewRunIDs
    }

    package func terminateAllRunningReviewRunsLocally(
        reason: String = "Cancellation requested.",
        failureMessage: String
    ) {
        let resolvedError = failureMessage.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        for runRecord in orderedReviewRuns where runRecord.isTerminal == false {
            runRecord.cancellationRequested = false
            runRecord.pendingCancellation = nil
            let failure = ReviewBackendFailure.connectionTerminated(
                .transport(
                    message: resolvedError ?? reason.nilIfEmpty ?? "Failed to cancel review."
                )
            )
            let endedAt = clock.now()
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
                break
            }
            runRecord.executionPhase = nil
        }
        noteReviewRunMutation()
    }
}
