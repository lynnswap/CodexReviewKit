import Foundation

package struct ReviewHistoryOperationFailure: LocalizedError, Sendable, Equatable {
    package let message: String

    package init(_ error: any Error) {
        self.message = error.localizedDescription
    }

    package init(message: String) {
        self.message = message
    }

    package var errorDescription: String? {
        message
    }
}

extension CodexReviewStore {
    package func loadReviewHistoryIfNeeded() async {
        if historyLoadWasApplied {
            return
        }

        let loadTask: Task<Result<[ReviewHistoryRecord], ReviewHistoryOperationFailure>, Never>
        if let existing = historyLoadTask {
            loadTask = existing
        } else {
            let persistence = historyPersistence
            let task = Task<Result<[ReviewHistoryRecord], ReviewHistoryOperationFailure>, Never> {
                do {
                    return .success(try await persistence.load())
                } catch {
                    return .failure(ReviewHistoryOperationFailure(error))
                }
            }
            historyLoadTask = task
            loadTask = task
        }

        let result = await loadTask.value
        guard historyLoadWasApplied == false else {
            return
        }
        historyLoadWasApplied = true

        switch result {
        case .success(let records):
            do {
                try restoreReviewHistory(records)
                transitionHistoryAvailability(to: .available)
            } catch {
                publishReviewHistoryFailure(error)
            }
        case .failure(let failure):
            publishReviewHistoryFailure(failure)
        }
    }

    package func deleteReviewHistory(id: String) async {
        await loadReviewHistoryIfNeeded()
        guard historyAvailability == .available,
              applicationShutdownRequested == false,
              let job = job(id: id),
              job.isTerminal,
              persistedTerminalReviewIDs.contains(id)
        else {
            return
        }

        do {
            try await historyPersistence.deleteReview(id: id)
        } catch {
            publishReviewHistoryFailure(error)
            return
        }

        guard let current = self.job(id: id), current === job, current.isTerminal else {
            return
        }
        removeHistoryJobs(ids: [id])
    }

    package func deleteAllReviewHistory() async {
        await loadReviewHistoryIfNeeded()
        guard historyAvailability == .available,
              applicationShutdownRequested == false
        else {
            return
        }

        let terminalIDs = Set(jobs.lazy.filter(\.isTerminal).map(\.id))
        guard terminalIDs.isEmpty == false else {
            return
        }
        do {
            try await historyPersistence.deleteAll()
        } catch {
            publishReviewHistoryFailure(error)
            return
        }
        removeHistoryJobs(ids: terminalIDs)
    }

    package func shutdown() async {
        if let task = applicationShutdownTask {
            await task.value
            return
        }
        applicationShutdownRequested = true
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.performApplicationShutdown()
        }
        applicationShutdownTask = task
        await task.value
    }

    package func persistReviewHistoryOrdering(
        _ ordering: ReviewHistoryOrdering
    ) async -> Bool {
        await loadReviewHistoryIfNeeded()
        guard historyAvailability == .available,
              applicationShutdownRequested == false
        else {
            return false
        }
        do {
            try await historyPersistence.saveOrdering(ordering)
            return true
        } catch {
            publishReviewHistoryFailure(error)
            return false
        }
    }

    package func currentReviewHistoryOrdering(
        workspaceSortOrders: [String: Double] = [:],
        reviewSortOrders: [String: Double] = [:]
    ) -> ReviewHistoryOrdering {
        ReviewHistoryOrdering(
            workspaces: workspaces.map { workspace in
                .init(
                    cwd: workspace.cwd,
                    sortOrder: workspaceSortOrders[workspace.cwd] ?? workspace.sortOrder
                )
            },
            reviews: jobs.map { job in
                .init(
                    id: job.id,
                    sortOrder: reviewSortOrders[job.id] ?? job.sortOrder
                )
            }
        )
    }

    package func noteHistoryMembershipOrOrderingMutation() {
        guard historyMutationRevision < UInt64.max else {
            preconditionFailure("CodexReviewStore history mutation revision exhausted.")
        }
        historyMutationRevision += 1
    }

    package func persistTerminalReviewIfNeeded(_ job: CodexReviewJob) async {
        guard job.isTerminal,
              persistedTerminalReviewIDs.contains(job.id) == false,
              persistedStartedReviewIDs.contains(job.id),
              let workspace = workspace(cwd: job.cwd)
        else {
            return
        }
        let record = ReviewHistoryRecord(
            job: job,
            workspaceSortOrder: workspace.sortOrder
        )
        do {
            let result = try await historyPersistence.recordTerminal(
                record,
                retentionPolicy: historyRetentionPolicy
            )
            persistedStartedReviewIDs.remove(job.id)
            persistedTerminalReviewIDs.insert(job.id)
            reconcileHistoryRetention(result)
        } catch {
            publishReviewHistoryFailure(error)
        }
    }

    package func persistStartedReview(_ record: ReviewHistoryRecord) async throws {
        await loadReviewHistoryIfNeeded()
        try requireReviewHistoryAvailable()
        do {
            try await historyPersistence.recordStarted(record)
            persistedStartedReviewIDs.insert(record.id)
        } catch {
            publishReviewHistoryFailure(error)
            throw CodexReviewAPI.Error.io(
                "Review history start could not be saved: \(error.localizedDescription)"
            )
        }
    }

    package func discardPersistedStartedReview(id: String) async {
        guard persistedStartedReviewIDs.contains(id) else {
            return
        }
        do {
            try await historyPersistence.deleteReview(id: id)
            persistedStartedReviewIDs.remove(id)
        } catch {
            publishReviewHistoryFailure(error)
        }
    }

    private func performApplicationShutdown() async {
        if historyLoadTask != nil {
            await loadReviewHistoryIfNeeded()
        }

        await stop(intent: .explicitStop)
        _ = await closeRegisteredStoreWork(
            reason: .system(message: "The review application is shutting down.")
        )

        if historyLoadSucceeded {
            let terminalJobs = orderedJobs.filter {
                $0.isTerminal && persistedTerminalReviewIDs.contains($0.id) == false
            }
            for job in terminalJobs {
                await persistTerminalReviewIfNeeded(job)
            }
            do {
                try await historyPersistence.saveOrdering(currentReviewHistoryOrdering())
            } catch {
                publishReviewHistoryFailure(error)
            }
        }

        do {
            try await historyPersistence.close()
            transitionHistoryAvailability(to: .closed)
        } catch {
            publishReviewHistoryFailure(error)
        }
    }

    private func restoreReviewHistory(_ records: [ReviewHistoryRecord]) throws {
        guard records.isEmpty == false else {
            historyLoadSucceeded = true
            return
        }
        guard jobs.isEmpty, workspaces.isEmpty else {
            throw ReviewHistoryOperationFailure(
                message: "Review history must load before process-local review membership is created."
            )
        }

        var seenReviewIDs: Set<String> = []
        var workspaceSortOrders: [String: Double] = [:]
        var restoredJobs: [CodexReviewJob] = []
        restoredJobs.reserveCapacity(records.count)

        for record in records {
            guard record.isTerminal else {
                throw ReviewHistoryOperationFailure(
                    message: "Loaded review \(record.id) was not finalized for process restoration."
                )
            }
            guard seenReviewIDs.insert(record.id).inserted else {
                throw ReviewHistoryOperationFailure(
                    message: "Loaded review history contains duplicate ID \(record.id)."
                )
            }
            if let existing = workspaceSortOrders[record.cwd],
               existing != record.workspaceSortOrder
            {
                throw ReviewHistoryOperationFailure(
                    message: "Loaded workspace \(record.cwd) has conflicting order values."
                )
            }
            workspaceSortOrders[record.cwd] = record.workspaceSortOrder
            restoredJobs.append(try record.makeRestoredJob())
        }

        workspaces = Set(workspaceSortOrders.map { cwd, sortOrder in
            CodexReviewWorkspace(cwd: cwd, sortOrder: sortOrder)
        })
        jobs = Set(restoredJobs)
        persistedTerminalReviewIDs = seenReviewIDs
        historyLoadSucceeded = true
        noteHistoryMembershipOrOrderingMutation()
        writeDiagnosticsIfNeeded()
    }

    private func requireReviewHistoryAvailable() throws {
        guard applicationShutdownRequested == false else {
            throw CodexReviewAPI.Error.io("Review history is closing.")
        }
        switch historyAvailability {
        case .available:
            return
        case .loading:
            throw CodexReviewAPI.Error.io("Review history is still loading.")
        case .failed(let message):
            throw CodexReviewAPI.Error.io("Review history is unavailable: \(message)")
        case .closed:
            throw CodexReviewAPI.Error.io("Review history is closed.")
        }
    }

    private func reconcileHistoryRetention(_ result: ReviewHistoryMutationResult) {
        let removedIDs = result.removedReviewIDs
        guard removedIDs.isEmpty == false else {
            return
        }
        let removedNonterminal = jobs.filter {
            removedIDs.contains($0.id) && $0.isTerminal == false
        }
        guard removedNonterminal.isEmpty else {
            publishReviewHistoryFailure(ReviewHistoryOperationFailure(
                message: "Review history retention removed an active review."
            ))
            return
        }
        removeHistoryJobs(ids: removedIDs)
    }

    private func removeHistoryJobs(ids: Set<String>) {
        guard ids.isEmpty == false else {
            return
        }
        jobs = Set(jobs.filter { ids.contains($0.id) == false })
        persistedStartedReviewIDs.subtract(ids)
        persistedTerminalReviewIDs.subtract(ids)
        let retainedCWDs = Set(jobs.map(\.cwd))
        workspaces = Set(workspaces.filter { retainedCWDs.contains($0.cwd) })
        noteHistoryMembershipOrOrderingMutation()
        writeDiagnosticsIfNeeded()
    }

    private func publishReviewHistoryFailure(_ error: any Error) {
        guard historyAvailability != .closed else {
            return
        }
        transitionHistoryAvailability(to: .failed(error.localizedDescription))
    }
}
