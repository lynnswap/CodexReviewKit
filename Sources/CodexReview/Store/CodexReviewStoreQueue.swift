import Foundation

@MainActor
package final class QueuedReviewStart {
    package let ordinal: UInt64
    package let request: CodexReviewAPI.Start.Request
    package let model: String?
    package let admission: ReviewStartAdmission
    private enum Dispatch {
        case pending
        case finished(Task<Void, Never>?)
    }
    private var dispatch = Dispatch.pending
    private var dispatchWaiters: [CheckedContinuation<Void, Never>] = []

    package init(ordinal: UInt64, request: CodexReviewAPI.Start.Request, model: String?, admission: ReviewStartAdmission) {
        self.ordinal = ordinal
        self.request = request
        self.model = model
        self.admission = admission
    }

    package func finishDispatch(worker: Task<Void, Never>? = nil) {
        dispatch = .finished(worker)
        let waiters = dispatchWaiters
        dispatchWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    package func waitUntilFinished() async {
        if case .pending = dispatch {
            await withCheckedContinuation { dispatchWaiters.append($0) }
        }
        if case .finished(let worker) = dispatch {
            await worker?.value
        }
    }

}

extension CodexReviewStore {
    package func suspendReviewStarts() {
        reviewStartsAreSuspended = true
    }

    package func resumeReviewStarts() {
        reviewStartsAreSuspended = false
        scheduleQueuedReviewStarts()
    }

    private var nextQueuedReviewStart: (id: String, start: QueuedReviewStart)? {
        guard let next = queuedReviewStarts.min(by: { $0.value.ordinal < $1.value.ordinal }),
              historyStartReceipts.values.contains(where: { $0.ordinal < next.value.ordinal }) == false
        else { return nil }
        return (next.key, next.value)
    }

    package func scheduleQueuedReviewStarts() {
        guard reviewStartsAreSuspended == false,
              applicationShutdownRequested == false,
              queuedReviewDispatchTask == nil,
              nextQueuedReviewStart != nil else { return }
        queuedReviewDispatchTask = startRegisteredStoreWork(
            kind: .reviewMutation("dispatch-queued"),
            cancelledBeforeEntry: .runFinalizer { store in
                store.queuedReviewDispatchTask = nil
            }
        ) { store in
            await store.dispatchQueuedReviews()
        }
    }

    private func dispatchQueuedReviews() async {
        defer {
            queuedReviewDispatchTask = nil
            if Task.isCancelled == false { scheduleQueuedReviewStarts() }
        }
        while reviewStartsAreSuspended == false, applicationShutdownRequested == false,
              Task.isCancelled == false, let next = nextQueuedReviewStart {
            queuedReviewStarts.removeValue(forKey: next.id)
            var dispatchedWorker: Task<Void, Never>?
            defer { next.start.finishDispatch(worker: dispatchedWorker) }
            guard let job = job(id: next.id), job.isTerminal == false else { continue }
            let startedAt = clock.now()
            job.core.lifecycle.status = .running
            job.core.lifecycle.startedAt = startedAt
            job.core.output.summary = "Review started."
            do {
                try await persistReviewExecutionStart(id: next.id, at: startedAt)
                try Task.checkCancellation()
                guard job.isTerminal == false else {
                    removeStartingReviewOwnership(for: next.id, ifOwnedBy: next.start.admission)
                    continue
                }
                guard let worker = makeReviewWorker(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    request: next.start.request,
                    effectiveModel: next.start.model,
                    admission: next.start.admission
                ) else { throw CancellationError() }
                reviewWorkerTasks[job.id] = worker
                dispatchedWorker = worker
            } catch {
                if job.isTerminal == false {
                    if error is CancellationError || Task.isCancelled {
                        try? completeCancellationLocally(
                            jobID: job.id,
                            sessionID: job.sessionID,
                            cancellation: job.pendingCancellationRequest?.cancellation ?? .system()
                        )
                    } else {
                        markReviewFailed(job, message: error.localizedDescription)
                    }
                }
                removeStartingReviewOwnership(for: next.id, ifOwnedBy: next.start.admission)
                await waitForHistoryTerminalCommitIfNeeded(jobID: job.id)
                resumeReviewWaiters(for: job.id)
            }
        }
    }

    private func persistReviewExecutionStart(id: String, at date: Date) async throws {
        let persistence = historyPersistence
        guard let receipt = historyMutationCoordinator.enqueue(
            intent: id,
            prepare: { $0 },
            operation: { id in try await persistence.recordExecutionStarted(id: id, at: date) },
            apply: { [weak self] _, result in
                if case .failure(let error) = result {
                    self?.publishReviewHistoryFailure(error)
                }
            }
        ) else {
            throw CodexReviewAPI.Error.io("Review history mutation admission is closed.")
        }
        switch await receipt.wait() {
        case .success: return
        case .failure(let error): throw error
        }
    }
}
