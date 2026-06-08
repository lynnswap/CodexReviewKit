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

    package func terminateAllRunningJobsLocally(
        reason: String = "Cancellation requested.",
        failureMessage: String
    ) {
        let resolvedError = failureMessage.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
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
        }
        noteJobMutation()
    }
}
