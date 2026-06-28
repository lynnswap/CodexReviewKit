import Foundation

private actor RuntimeStopDetachedReviewWorkerDrainRace {
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func finish(_ value: Bool) {
        guard result == nil else {
            return
        }
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }

    func wait() async -> Bool {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            if let result {
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
            }
        }
    }
}

extension CodexReviewStore {
    package func completeCancellationLocally(
        runID: String,
        sessionID: String,
        cancellation: ReviewCancellation = .system()
    ) throws {
        guard let job = reviewRun(id: runID)
        else {
            throw CodexReviewAPI.Error.runNotFound("Run \(runID) was not found.")
        }
        guard job.sessionID == sessionID
        else {
            throw CodexReviewAPI.Error.runNotFound("Run \(runID) was not found.")
        }
        guard job.isTerminal == false else {
            return
        }

        let endedAt = clock.now()
        job.cancellationRequested = false
        job.core.lifecycle.cancellation = cancellation
        job.core.lifecycle.status = .cancelled
        job.core.output.summary = cancellation.message
        job.core.output.hasFinalReview = false
        job.core.lifecycle.errorMessage =
            cancellation.message.nilIfEmpty
            ?? job.core.lifecycle.errorMessage
        job.core.lifecycle.endedAt = endedAt
        noteReviewRunMutation()
    }

    package func recordCancellationFailure(
        runID: String,
        sessionID: String,
        message: String
    ) throws {
        guard let job = reviewRun(id: runID)
        else {
            throw CodexReviewAPI.Error.runNotFound("Run \(runID) was not found.")
        }
        guard job.sessionID == sessionID
        else {
            throw CodexReviewAPI.Error.runNotFound("Run \(runID) was not found.")
        }

        job.cancellationRequested = false
        job.core.lifecycle.cancellation = nil
        if let message = message.nilIfEmpty {
            if message == "Failed to cancel review." {
                job.core.output.summary = message
            } else {
                job.core.output.summary = "Failed to cancel review: \(message)"
            }
            job.core.lifecycle.errorMessage = message
        } else {
            job.core.output.summary = "Failed to cancel review."
        }
        writeDiagnosticsIfNeeded()
    }

    package func recordCancellationFailure(
        runID: String,
        message: String
    ) throws {
        guard let runRecord = reviewRun(id: runID)
        else {
            throw CodexReviewAPI.Error.runNotFound("Run \(runID) was not found.")
        }
        try recordCancellationFailure(
            runID: runID,
            sessionID: runRecord.sessionID,
            message: message
        )
    }

    public func cancelAllRunningReviewRuns(
        reason: String = "Cancellation requested."
    ) async throws {
        let cancellation = ReviewCancellation.system(
            message: reason.nilIfEmpty ?? "Cancellation requested."
        )
        let cancellableReviewRuns = orderedReviewRuns.filter { $0.isTerminal == false }
        var firstError: (any Error)?
        for job in cancellableReviewRuns {
            do {
                _ = try await cancelReview(
                    runID: job.id,
                    sessionID: job.sessionID,
                    cancellation: cancellation
                )
            } catch {
                let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                try? recordCancellationFailure(
                    runID: job.id,
                    sessionID: job.sessionID,
                    message: message.isEmpty ? "Failed to cancel review." : message
                )
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    package func requestActiveReviewCancellationsForRuntimeStop(
        reason: ReviewCancellation = .system(message: "Review runtime stopped.")
    ) async -> [String] {
        let activeReviewRunIDs =
            orderedReviewRuns
            .filter { $0.isTerminal == false }
            .map(\.id)
        for runID in activeReviewRunIDs {
            _ = try? await cancelReview(runID: runID, cancellation: reason)
        }
        return activeReviewRunIDs
    }

    package func cleanupActiveReviewsForRuntimeStop(
        reason: ReviewCancellation = .system(message: "Review runtime stopped."),
        workerDrainTimeout: Duration,
        cleanupBackendReviews:
            @escaping @Sendable (
                CodexReviewRuntimeStopReviewCleanupRequest
            ) async -> Bool
    ) async -> CodexReviewRuntimeStopReviewCleanupResult {
        let request = runtimeStopReviewCleanupRequest(reason: reason)
        let didCompleteBackendCleanup = await cleanupBackendReviews(request)
        let locallyCancelledReviewRunIDs = cancelActiveReviewsLocallyForRuntimeStop(
            reason: reason,
            cancelWorkers: false
        )
        cancelAndDetachReviewWorkersForRuntimeStop(runIDs: locallyCancelledReviewRunIDs)
        let didDrainReviewWorkers = await drainReviewWorkersForRuntimeStop(
            timeout: workerDrainTimeout
        )
        return .init(
            didCompleteBackendCleanup: didCompleteBackendCleanup,
            didDrainReviewWorkers: didDrainReviewWorkers
        )
    }

    private func runtimeStopReviewCleanupRequest(
        reason: ReviewCancellation
    ) -> CodexReviewRuntimeStopReviewCleanupRequest {
        return .init(
            reason: .init(message: reason.message),
            recoveryWaitingRuns: runtimeState.recoveryWaitingRuns()
        )
    }

    @discardableResult
    package func cancelActiveReviewsLocallyForRuntimeStop(
        reason: ReviewCancellation = .system(message: "Review runtime stopped."),
        cancelWorkers: Bool = true
    ) -> [String] {
        let activeReviewRunIDs =
            orderedReviewRuns
            .filter { $0.isTerminal == false }
            .map(\.id)
        guard activeReviewRunIDs.isEmpty == false else {
            return []
        }

        for runID in activeReviewRunIDs {
            if let job = reviewRun(id: runID), job.isTerminal == false {
                try? completeCancellationLocally(
                    runID: job.id,
                    sessionID: job.sessionID,
                    cancellation: reason
                )
            }
            if cancelWorkers {
                runtimeState.cancelActiveWorker(for: runID)
            }
        }
        return activeReviewRunIDs
    }

    package func cancelAndDetachReviewWorkersForRuntimeStop(runIDs: [String]) {
        for runID in runIDs {
            runtimeState.cancelAndDetachActiveWorkerForRuntimeStop(runID: runID)
            runtimeState.clearRuntimeStopState(for: runID)
        }
    }

    package func drainRuntimeStopDetachedReviewWorkers(timeout: Duration) async -> Bool {
        let tasks = runtimeState.detachedWorkerTasks()
        return await drainReviewWorkerTasksForRuntimeStop(tasks, timeout: timeout)
    }

    package func drainReviewWorkersForRuntimeStop(timeout: Duration) async -> Bool {
        let tasks = runtimeState.allWorkerTasks()
        return await drainReviewWorkerTasksForRuntimeStop(tasks, timeout: timeout)
    }

    private func drainReviewWorkerTasksForRuntimeStop(
        _ tasks: [Task<Void, Never>],
        timeout: Duration
    ) async -> Bool {
        guard tasks.isEmpty == false else {
            return true
        }

        let race = RuntimeStopDetachedReviewWorkerDrainRace()
        let drainTask = Task {
            for task in tasks {
                await task.value
            }
            await race.finish(true)
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await race.finish(false)
        }

        let didDrain = await race.wait()
        if didDrain {
            timeoutTask.cancel()
        } else {
            drainTask.cancel()
        }
        return didDrain
    }

    package func terminateAllRunningReviewRunsLocally(
        reason: String = "Cancellation requested.",
        failureMessage: String
    ) {
        let resolvedError = failureMessage.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        for job in orderedReviewRuns where job.isTerminal == false {
            job.cancellationRequested = false
            job.core.lifecycle.cancellation = nil
            job.core.lifecycle.status = .failed
            if let resolvedError {
                job.core.output.summary = "Failed to cancel review: \(resolvedError)"
            } else {
                job.core.output.summary = "Failed to cancel review."
            }
            job.core.output.hasFinalReview = false
            job.core.lifecycle.errorMessage =
                resolvedError
                ?? reason.nilIfEmpty
                ?? job.core.lifecycle.errorMessage
            job.core.lifecycle.endedAt = clock.now()
        }
        noteReviewRunMutation()
    }
}
