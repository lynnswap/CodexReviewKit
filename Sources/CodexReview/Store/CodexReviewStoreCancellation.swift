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

package struct ReviewRuntimeCancellationRequestOutcome: Sendable {
    package let jobIDs: [String]
    package let firstFailure: ReviewRuntimeCloseFailure?
}
@MainActor
package final class ReviewRuntimeSemanticStopContext {
    package typealias Interrupt = @MainActor @Sendable (ReviewInterruptRequestAdmission, CodexReviewBackendModel.CancellationReason) async throws -> Void
    package typealias CleanupRecovery = @MainActor @Sendable (StoreReviewRecoveryReceipt.DiscardTarget) async throws -> Void
    package struct Entry {
        let job: CodexReviewJob?
        let ownership: StoreReviewAttemptOwnership?
        let cancellationRequest: ReviewCancellationRequestReceipt?
        let workerTask: Task<Void, Never>?
        var waiters: [CodexReviewStore.ReviewTerminalWaiter]
    }
    private var entries: [String: Entry]
    private let interruptReview: Interrupt
    private let cleanupRecovery: CleanupRecovery
    private let now: @MainActor @Sendable () -> Date
    private let writeDiagnostics: @MainActor @Sendable () -> Void
    package init(
        entries: [String: Entry],
        interruptReview: @escaping Interrupt,
        cleanupRecovery: @escaping CleanupRecovery,
        now: @escaping @MainActor @Sendable () -> Date,
        writeDiagnostics: @escaping @MainActor @Sendable () -> Void
    ) {
        self.entries = entries
        self.interruptReview = interruptReview
        self.cleanupRecovery = cleanupRecovery
        self.now = now
        self.writeDiagnostics = writeDiagnostics
    }
    isolated deinit { cancelTransferredWorkers() }
    package var workerJobIDs: [String] { entries.compactMap { $0.value.workerTask == nil ? nil : $0.key }.sorted() }
    package func requestCancellations() async -> ReviewRuntimeCancellationRequestOutcome {
        var firstFailure: ReviewRuntimeCloseFailure?
        let jobIDs = entries.compactMap { id, entry in
            entry.cancellationRequest == nil ? nil : id
        }.sorted()
        for jobID in jobIDs {
            guard let entry = entries[jobID],
                  let ownership = entry.ownership,
                  let request = entry.cancellationRequest else {
                firstFailure = firstFailure ?? .cleanup("Runtime semantic stop lost the exact review cancellation owner.")
                continue
            }
            do {
                switch ownership {
                case .starting(let admission):
                    await admission.registerCancellationRequest(request)
                    completeLocally(entry.job, cancellation: request.cancellation)
                    entry.workerTask?.cancel()
                case .active(let active):
                    let resolution = try await active.admission.interrupt(
                        active.run,
                        cancellationRequest: request,
                        request: interruptReview
                    )
                    applyInterruptResolution(resolution, request: request, to: entry.job)
                    entry.workerTask?.cancel()
                    await entry.workerTask?.value
                case .recovering(let receipt):
                    await receipt.cancelOwnedOperation(cancellationRequest: request)
                    entry.workerTask?.cancel()
                    await entry.workerTask?.value
                }
            } catch {
                firstFailure = firstFailure ?? (error as? ReviewRuntimeCloseFailure) ?? .cleanup(error.localizedDescription)
            }
        }
        return .init(jobIDs: jobIDs, firstFailure: firstFailure)
    }
    package func stopUsingDefaultPolicy(intent: ReviewRuntimeTeardownIntent) async {
        let requested = await requestCancellations().jobIDs
        let projected = completeCancellationsLocally(reason: intent.reviewCancellation)
        await cancelWorkers(jobIDs: Array(Set(requested + projected + workerJobIDs)), reason: intent.reviewCancellation)
    }
    package func completeCancellationsLocally(reason: ReviewCancellation) -> [String] {
        let jobIDs: [String] = entries.compactMap { id, entry -> String? in
            guard entry.job?.isTerminal == false else { return nil }
            completeLocally(entry.job, cancellation: reason)
            return id
        }.sorted()
        writeDiagnostics()
        return jobIDs
    }
    package func cancelWorkers(jobIDs: [String], reason: ReviewCancellation) async {
        for jobID in Set(jobIDs) {
            guard let entry = entries[jobID] else { continue }
            switch entry.ownership {
            case .starting(let admission):
                if let request = entry.cancellationRequest {
                    await admission.registerCancellationRequest(request)
                }
            case .recovering(let receipt):
                await receipt.cancelOwnedOperation(reason)
                if let join = try? receipt.joinOwnedOperationIfPresent() { _ = try? await join.value }
                if let target = try? receipt.suppress() {
                    switch target {
                    case .source where entry.workerTask != nil: break
                    default: try? await cleanupRecovery(target)
                    }
                }
            case .active, nil: break
            }
            entry.workerTask?.cancel()
            resumeWaiters(for: jobID)
        }
    }
    package func drainWorkers(timeout: Duration) async -> Bool {
        let tasks = entries.values.compactMap(\.workerTask)
        guard tasks.isEmpty == false else { return true }
        let race = RuntimeStopDetachedReviewWorkerDrainRace()
        let drainTask = Task {
            await waitForWorkers()
            await race.finish(true)
        }
        let timeoutTask = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            await race.finish(false)
        }
        let didDrain = await race.wait()
        if didDrain { timeoutTask.cancel() } else { drainTask.cancel() }
        return didDrain
    }
    package func waitForWorkers() async {
        for task in entries.values.compactMap(\.workerTask) { await task.value }
    }
    package func cancelTransferredWorkers() { entries.forEach { $0.value.workerTask?.cancel(); resumeWaiters(for: $0.key) } }
    private func completeLocally(
        _ job: CodexReviewJob?,
        cancellation: ReviewCancellation
    ) {
        guard let job, job.isTerminal == false else { return }
        let endedAt = now()
        job.closeActiveCommandLogEntries(status: "canceled", completedAt: endedAt)
        job.pendingCancellationRequest = nil
        job.core.lifecycle.cancellation = cancellation
        job.core.lifecycle.status = .cancelled
        job.core.output.summary = cancellation.message
        job.core.output.hasFinalReview = false
        job.core.lifecycle.errorMessage = cancellation.message.nilIfEmpty
            ?? job.core.lifecycle.errorMessage
        job.core.lifecycle.endedAt = endedAt
        job.applyReviewLogLimit()
    }
    private func applyInterruptResolution(
        _ resolution: ReviewInterruptResolution,
        request: ReviewCancellationRequestReceipt,
        to job: CodexReviewJob?
    ) {
        guard let job, job.isTerminal == false else { return }
        switch resolution.terminal {
        case .canonical(.completed):
            markFailed(job, message: ReviewIngestionError.missingFinalReview.localizedDescription)
        case .canonical(.failed(let message)):
            markFailed(job, message: message)
        case .canonical(.interrupted(let cause)):
            if case .requested(let cancellation) = cause {
                completeLocally(job, cancellation: cancellation)
            } else {
                markInterrupted(job, cause: cause)
            }
        case .connection(let failure):
            applyStreamFailure(.unexpectedConnection(failure), resolution: resolution, request: request, to: job)
        case .stream(let failure):
            applyStreamFailure(failure, resolution: resolution, request: request, to: job)
        }
        writeDiagnostics()
        resumeWaiters(for: job.id)
    }
    private func applyStreamFailure(
        _ failure: ReviewAttemptStreamFailure,
        resolution: ReviewInterruptResolution,
        request: ReviewCancellationRequestReceipt,
        to job: CodexReviewJob
    ) {
        if resolution.cancellationRequestReceipt?.id == request.id,
           let cancellation = resolution.cancellation {
            completeLocally(job, cancellation: cancellation)
            return
        }
        switch failure {
        case .protocolViolation, .workerContract:
            markFailed(job, message: failure.localizedDescription)
        case .recoverableNetwork, .ownerForcedConnectionClose, .unexpectedConnection, .process:
            markInterrupted(job, cause: .transport(message: failure.localizedDescription))
        case .ownerCancellation:
            completeLocally(job, cancellation: request.cancellation)
        }
    }
    private func markInterrupted(_ job: CodexReviewJob, cause: ReviewInterruptionCause) {
        let message: String? = switch cause {
        case .requested(let cancellation): cancellation.message
        case .server(let message): message
        case .transport(let message): message
        case .previousProcessExit: "The previous review process exited before completion."
        }
        markFailed(job, message: message, terminal: .interrupted(cause))
    }
    private func markFailed(
        _ job: CodexReviewJob,
        message: String?,
        terminal: ReviewTerminalRecord? = nil
    ) {
        guard job.isTerminal == false else { return }
        let endedAt = now()
        let displayMessage = message?.nilIfEmpty ?? "Review failed."
        job.pendingCancellationRequest = nil
        job.core.lifecycle.cancellation = nil
        job.closeActiveCommandLogEntries(status: "failed", completedAt: endedAt)
        job.core.lifecycle.terminal = terminal ?? .failed(message: message?.nilIfEmpty)
        job.core.lifecycle.status = .failed
        job.core.lifecycle.endedAt = endedAt
        job.core.lifecycle.errorMessage = message?.nilIfEmpty
        job.core.output.summary = displayMessage
        job.appendLogEntry(.init(kind: .error, text: displayMessage, timestamp: endedAt))
        job.applyReviewLogLimit()
    }
    private func resumeWaiters(for jobID: String) {
        guard var entry = entries[jobID] else { return }
        let waiters = entry.waiters
        entry.waiters.removeAll(keepingCapacity: false)
        entries[jobID] = entry
        for waiter in waiters { waiter.timeoutTask?.cancel(); waiter.continuation.resume() }
    }
}
extension CodexReviewStore {
    @discardableResult
    package func recordCancellationRequest(
        _ cancellation: ReviewCancellation,
        rejectionDisposition: ReviewCancellationRequestReceipt.RejectionDisposition = .reportFailure,
        workAdmission: ReviewStoreWorkRegistry.Admission? = nil,
        for job: CodexReviewJob
    ) -> ReviewCancellationRequestReceipt? {
        guard job.isTerminal == false else {
            return nil
        }
        if let current = job.pendingCancellationRequest,
           current.rejectionDisposition == .preserveRuntimeStopIntent {
            return current
        }
        guard nextCancellationRequestOrdinal < UInt64.max else {
            preconditionFailure("CodexReviewStore cancellation request ordinal exhausted.")
        }
        nextCancellationRequestOrdinal += 1
        let receipt = ReviewCancellationRequestReceipt(
            id: .init(jobID: job.id, ordinal: nextCancellationRequestOrdinal),
            cancellation: cancellation,
            rejectionDisposition: rejectionDisposition,
            registeredWorkAdmission: workAdmission
        )
        job.pendingCancellationRequest = receipt
        job.core.lifecycle.cancellation = cancellation
        job.core.output.summary = cancellation.message
        job.core.lifecycle.errorMessage = cancellation.message
        return receipt
    }

    @discardableResult
    package func recordActiveReviewCancellationRequestsForRuntimeStop(
        reason: ReviewCancellation = .system(message: "Review runtime stopped.")
    ) -> [String] {
        let jobs = orderedJobs.filter { $0.isTerminal == false }
        for job in jobs {
            recordCancellationRequest(
                reason,
                rejectionDisposition: .preserveRuntimeStopIntent,
                for: job
            )
        }
        return jobs.map(\.id)
    }

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
        job.pendingCancellationRequest = nil
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
        receipt: ReviewCancellationRequestReceipt,
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
        guard job.isTerminal == false,
              job.pendingCancellationRequest?.id == receipt.id
        else {
            return
        }

        job.pendingCancellationRequest = nil
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
        try await performThrowingRegisteredStoreWork(
            kind: .reviewMutation("cancel-all")
        ) { @MainActor store, workAdmission in
            try await store.performCancelAllRunningJobs(
                cancellation: cancellation,
                workAdmission: workAdmission
            )
        }
    }

    private func performCancelAllRunningJobs(
        cancellation: ReviewCancellation,
        workAdmission: ReviewStoreWorkRegistry.Admission
    ) async throws {
        let cancellableJobs = orderedJobs.filter { $0.isTerminal == false }
        var firstError: (any Error)?
        for job in cancellableJobs {
            do {
                _ = try await performCancelReview(
                    jobID: job.id,
                    cancellation: cancellation,
                    workAdmission: workAdmission
                )
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    package func detachRuntimeSemanticStopContext(
        intent: ReviewRuntimeTeardownIntent
    ) -> ReviewRuntimeSemanticStopContext {
        let activeJobs = orderedJobs.filter { $0.isTerminal == false }
        let jobIDs = Set(activeJobs.map(\.id))
            .union(reviewWorkerTasks.keys)
        var entries: [String: ReviewRuntimeSemanticStopContext.Entry] = [:]
        for jobID in jobIDs {
            let job = job(id: jobID)
            let request = job.flatMap {
                recordCancellationRequest(
                    intent.reviewCancellation,
                    rejectionDisposition: .preserveRuntimeStopIntent,
                    for: $0
                )
            }
            entries[jobID] = .init(
                job: job,
                ownership: reviewAttemptOwnerships.removeValue(forKey: jobID),
                cancellationRequest: request,
                workerTask: reviewWorkerTasks.removeValue(forKey: jobID),
                waiters: reviewTerminalWaiters.removeValue(forKey: jobID) ?? []
            )
        }
        let backend = backend
        let clock = clock
        return ReviewRuntimeSemanticStopContext(
            entries: entries,
            interruptReview: { admission, reason in
                try await backend.interruptReview(admission, reason: reason)
            },
            cleanupRecovery: { target in
                switch target {
                case .source(let active): try await backend.cleanupReview(active.run)
                case .prepared(let prepared): try await backend.discardReviewRecovery(prepared)
                case .staged(let staged): try await backend.discardReviewRecovery(staged)
                }
            },
            now: { clock.now() },
            writeDiagnostics: { [weak self] in self?.writeDiagnosticsIfNeeded() }
        )
    }

    package func terminateAllRunningJobsLocally(
        reason: String = "Cancellation requested.",
        failureMessage: String
    ) {
        let resolvedError = failureMessage.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        var terminatedJobIDs: [String] = []
        for job in orderedJobs where job.isTerminal == false {
            job.pendingCancellationRequest = nil
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
