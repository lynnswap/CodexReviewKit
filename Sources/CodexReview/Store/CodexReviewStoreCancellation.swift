import Foundation

extension CodexReviewStore {
    package func completeCancellationLocally(
        jobID: String,
        sessionID: String,
        cancellation: ReviewCancellation = .system()
    ) throws {
        guard let job = job(id: jobID)
        else {
            throw ReviewError.jobNotFound("Job \(jobID) was not found.")
        }
        guard job.sessionID == sessionID
        else {
            throw ReviewError.jobNotFound("Job \(jobID) was not found.")
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
            throw ReviewError.jobNotFound("Job \(jobID) was not found.")
        }
        guard job.sessionID == sessionID
        else {
            throw ReviewError.jobNotFound("Job \(jobID) was not found.")
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

    package func cancelActiveReviewsForRuntimeStop(
        reason: ReviewCancellation = .system(message: "Review runtime stopped.")
    ) async {
        let activeJobIDs = orderedJobs
            .filter { $0.isTerminal == false }
            .map(\.id)
        guard activeJobIDs.isEmpty == false else {
            return
        }

        for jobID in activeJobIDs {
            do {
                _ = try await cancelReview(jobID: jobID, cancellation: reason)
            } catch {
                if let job = job(id: jobID) {
                    try? recordCancellationFailure(
                        jobID: job.id,
                        sessionID: job.sessionID,
                        message: error.localizedDescription
                    )
                }
            }
            reviewWorkerTasks[jobID]?.cancel()
        }

        let tasks = activeJobIDs.compactMap { reviewWorkerTasks[$0] }
        for task in tasks {
            await task.value
        }

        for jobID in activeJobIDs {
            guard let job = job(id: jobID), job.isTerminal == false else {
                continue
            }
            try? completeCancellationLocally(
                jobID: job.id,
                sessionID: job.sessionID,
                cancellation: reason
            )
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
}
