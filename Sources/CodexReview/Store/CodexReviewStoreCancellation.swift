import Foundation

package struct ReviewCloseCancellationOutcome {
    package let jobIDs: [String]
    package let failedJobIDs: Set<String>
}

extension CodexReviewStore {
    package func completeCancellationLocally(
        jobID: String,
        sessionID: String,
        cancellation: ReviewCancellation = .system()
    ) throws {
        guard let job = job(id: jobID)
        else {
            throw CodexReviewAPI.Error.jobNotFound("Job \(jobID) was not found.")
        }
        guard job.sessionID == sessionID
        else {
            throw CodexReviewAPI.Error.jobNotFound("Job \(jobID) was not found.")
        }
        guard job.isTerminal == false else {
            return
        }

        let endedAt = clock.now()
        job.closeActiveCommandLogEntries(status: "canceled", completedAt: endedAt)
        job.cancellationRequested = false
        job.core.lifecycle.cancellation = cancellation
        job.core.lifecycle.status = .cancelled
        job.core.output.summary = cancellation.message
        job.core.output.hasFinalReview = false
        job.core.lifecycle.errorMessage = cancellation.message.nilIfEmpty
            ?? job.core.lifecycle.errorMessage
        job.core.lifecycle.endedAt = endedAt
        job.applyReviewLogLimit()
        noteJobMutation()
        resumeReviewWaiters(for: job.id)
    }

    package func recordCancellationFailure(
        jobID: String,
        sessionID: String,
        message: String
    ) throws {
        guard let job = job(id: jobID)
        else {
            throw CodexReviewAPI.Error.jobNotFound("Job \(jobID) was not found.")
        }
        guard job.sessionID == sessionID
        else {
            throw CodexReviewAPI.Error.jobNotFound("Job \(jobID) was not found.")
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

    public func cancelAllRunningJobs(
        reason: String = "Cancellation requested."
    ) async throws {
        let cancellation = ReviewCancellation.system(
            message: reason.nilIfEmpty ?? "Cancellation requested."
        )
        let cancellableJobs = orderedJobs.filter { $0.isTerminal == false }
        var firstError: (any Error)?
        for job in cancellableJobs {
            do {
                _ = try await cancelReview(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    cancellation: cancellation
                )
            } catch {
                let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                try? recordCancellationFailure(
                    jobID: job.id,
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

    package func requestActiveReviewCancellationsForApplicationClose(
        reason: ReviewCancellation = .system(message: "Review Store closed."),
        failureLedger: ReviewCloseFailureLedger
    ) async -> ReviewCloseCancellationOutcome {
        let activeJobIDs = activeReviewJobIDsInRegistrationOrder
        var failedJobIDs: Set<String> = []
        for jobID in activeJobIDs {
            do {
                _ = try await cancelReview(jobID: jobID, cancellation: reason)
            } catch {
                failedJobIDs.insert(jobID)
                guard failureLedger.ownsForceCloseFailure(for: jobID) == false else {
                    continue
                }
                let failure = closePrimaryFailure(from: error)
                if case .attemptRuntime(let runtimeFailure) = failure,
                   reviewCleanupFailures[jobID] == runtimeFailure {
                    failureLedger.recordReviewCleanupFailure(
                        runtimeFailure,
                        jobID: jobID
                    )
                } else {
                    failureLedger.record(failure)
                }
            }
        }
        return .init(
            jobIDs: activeJobIDs,
            failedJobIDs: failedJobIDs
        )
    }

    private func closePrimaryFailure(
        from error: any Error
    ) -> ReviewClosePrimaryFailure {
        if let failure = error as? ReviewInterruptRequestFailure {
            return .interruptRequest(failure)
        }
        if let failure = error as? ReviewRuntimeCloseFailure {
            return .attemptRuntime(failure)
        }
        if let aggregate = error as? ReviewLifecycleResourceFailureAggregate {
            return .lifecycleResources(aggregate)
        }
        if let failure = error as? ReviewLifecycleResourceFailure {
            return .lifecycleResources(.init(first: failure))
        }
        return .attemptRuntime(.worker(error.localizedDescription))
    }

    @discardableResult
    package func cancelActiveReviewsLocallyForRuntimeStop(
        reason: ReviewCancellation = .system(message: "Review runtime stopped."),
        cancelWorkers: Bool = true
    ) -> [String] {
        let activeJobIDs = activeReviewJobIDsInRegistrationOrder
        guard activeJobIDs.isEmpty == false else {
            return []
        }

        for jobID in activeJobIDs {
            if let job = job(id: jobID), job.isTerminal == false {
                try? completeCancellationLocally(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    cancellation: reason
                )
            }
            if cancelWorkers {
                reviewWorkerTasks[jobID]?.cancel()
            }
        }
        return activeJobIDs
    }

    package func cancelAndAwaitReviewWorkersForRuntimeStop(
        jobIDs: [String]
    ) async {
        var seenJobIDs: Set<String> = []
        let orderedTasks = jobIDs.compactMap { jobID -> Task<Void, Never>? in
            guard seenJobIDs.insert(jobID).inserted else {
                return nil
            }
            return reviewWorkerTasks[jobID]
        }
        for task in orderedTasks {
            task.cancel()
        }
        for task in orderedTasks {
            await task.value
        }
    }

    package func awaitReviewWorkers(jobIDs: [String]) async {
        var seenJobIDs: Set<String> = []
        let orderedTasks = jobIDs.compactMap { jobID -> Task<Void, Never>? in
            guard seenJobIDs.insert(jobID).inserted else {
                return nil
            }
            return reviewWorkerTasks[jobID]
        }
        for task in orderedTasks {
            await task.value
        }
    }

    package func awaitAllReviewWorkers() async {
        let orderedJobIDs = reviewRegistrationOrder
        let remainingJobIDs = reviewWorkerTasks.keys
            .filter { orderedJobIDs.contains($0) == false }
            .sorted()
        await awaitReviewWorkers(jobIDs: orderedJobIDs + remainingJobIDs)
    }

    package func cancelAndAwaitAllReviewWorkers() async {
        let orderedJobIDs = reviewRegistrationOrder
        let remainingJobIDs = reviewWorkerTasks.keys
            .filter { orderedJobIDs.contains($0) == false }
            .sorted()
        await cancelAndAwaitReviewWorkersForRuntimeStop(
            jobIDs: orderedJobIDs + remainingJobIDs
        )
    }

    package func cancelAndAwaitAllReviewMutationTasks() async {
        let entries = reviewMutationTasks.sorted { $0.key < $1.key }
        for (_, task) in entries {
            task.cancel()
        }
        for (id, task) in entries {
            _ = await task.result
            reviewMutationTasks.removeValue(forKey: id)
        }
    }

    package func cancelAndAwaitOwnedStoreCommandTasks() async {
        let entries = storeCommandRegistry.ownedTaskSnapshot()
        for (_, task) in entries {
            task.cancel()
        }
        for (id, task) in entries {
            await task.value
            finishStoreCommand(id)
        }
    }

    package func terminateAllRunningJobsLocally(
        reason: String = "Cancellation requested.",
        failureMessage: String
    ) {
        let resolvedError = failureMessage.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        var terminatedJobIDs: [String] = []
        for job in orderedJobs where job.isTerminal == false {
            job.cancellationRequested = false
            job.core.lifecycle.cancellation = nil
            job.core.lifecycle.status = .failed
            if let resolvedError {
                job.core.output.summary = "Failed to cancel review: \(resolvedError)"
            } else {
                job.core.output.summary = "Failed to cancel review."
            }
            job.core.output.hasFinalReview = false
            job.core.lifecycle.errorMessage = resolvedError
                ?? reason.nilIfEmpty
                ?? job.core.lifecycle.errorMessage
            job.core.lifecycle.endedAt = clock.now()
            job.applyReviewLogLimit()
            terminatedJobIDs.append(job.id)
        }
        noteJobMutation()
        for jobID in terminatedJobIDs {
            resumeReviewWaiters(for: jobID)
        }
    }

    private var activeReviewJobIDsInRegistrationOrder: [String] {
        let registered = reviewRegistrationOrder.filter {
            job(id: $0)?.isTerminal == false
        }
        let registeredSet = Set(registered)
        let missing = orderedJobs
            .filter { $0.isTerminal == false && registeredSet.contains($0.id) == false }
            .map(\.id)
            .sorted()
        return registered + missing
    }
}
