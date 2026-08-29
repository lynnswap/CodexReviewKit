import Foundation

package struct ReviewHistoryOperationFailure: LocalizedError, Sendable, Equatable {
    package let message: String

    package init(_ error: any Error) {
        message = error.localizedDescription
    }

    package init(message: String) {
        self.message = message
    }

    package var errorDescription: String? {
        message
    }
}

private enum DeleteReviewHistoryPlan: Sendable {
    case none
    case review(String)
    case allTerminal
}

extension CodexReviewStore {
    package func loadReviewHistoryIfNeeded() async {
        if historyLoadWasApplied {
            return
        }

        let loadTask: Task<Result<[RestoredReviewRecord], ReviewHistoryOperationFailure>, Never>
        if let existing = historyLoadTask {
            loadTask = existing
        } else {
            let persistence = historyPersistence
            let retentionPolicy = historyRetentionPolicy
            let task = Task<Result<[RestoredReviewRecord], ReviewHistoryOperationFailure>, Never> {
                do {
                    return .success(try await persistence.load(
                        retentionPolicy: retentionPolicy
                    ))
                } catch {
                    return .failure(.init(error))
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

    package func makeHistoryStartReceipt(
        sessionID: String,
        request: CodexReviewAPI.Start.Request,
        workAdmission: ReviewStoreWorkRegistry.Admission
    ) throws -> HistoryStartReceipt {
        guard nextHistoryStartOrdinal < UInt64.max else {
            preconditionFailure("Review history start receipt ordinal exhausted.")
        }
        nextHistoryStartOrdinal += 1
        let id = idGenerator.next()
        let model = settings.effectiveModel
        let workspaceSortOrder = historyWorkspaceSortOrder(cwd: request.cwd)
            ?? nextHistoryWorkspaceSortOrder()
        let record = try StartedReviewRecord(
            id: id,
            cwd: request.cwd,
            workspaceSortOrder: workspaceSortOrder,
            sortOrder: nextHistoryJobSortOrder(cwd: request.cwd),
            target: request.target,
            model: model,
            startedAt: clock.now()
        )
        let receipt = HistoryStartReceipt(
            ordinal: nextHistoryStartOrdinal,
            sessionID: sessionID,
            started: record,
            workAdmission: workAdmission
        )
        historyStartReceipts[id] = receipt
        return receipt
    }

    package func persistHistoryStart(
        _ receipt: HistoryStartReceipt
    ) async -> Result<Void, ReviewHistoryOperationFailure> {
        let persistence = historyPersistence
        guard let mutation = historyMutationCoordinator.enqueue(
            intent: receipt.started,
            prepare: { $0 },
            operation: { record in
                try await persistence.recordStarted(record)
            },
            apply: { [weak self] record, result in
                guard let self else {
                    return
                }
                switch result {
                case .success:
                    persistedStartedReviewIDs.insert(record.id)
                case .failure(let failure):
                    publishReviewHistoryFailure(failure)
                }
            }
        ) else {
            let failure = ReviewHistoryOperationFailure(
                message: "Review history mutation admission is closed."
            )
            publishReviewHistoryFailure(failure)
            return .failure(failure)
        }
        return await mutation.wait()
    }

    package func historyStartCancellationIfStale(
        _ receipt: HistoryStartReceipt
    ) -> ReviewCancellation? {
        if let cancellation = receipt.cancellation {
            return cancellation
        }
        if applicationShutdownRequested {
            return .system(message: "The review application is shutting down.")
        }
        if Task.isCancelled || storeWorkRegistry.accepts(receipt.workAdmission) == false {
            return .system(message: "Review start was cancelled before backend dispatch.")
        }
        if closedSessions.contains(receipt.sessionID) {
            return .sessionClosed()
        }
        return nil
    }

    package func terminalizeStaleHistoryStart(
        _ receipt: HistoryStartReceipt,
        cancellation: ReviewCancellation
    ) async {
        let terminal: TerminalReviewRecord
        let restored: RestoredReviewRecord
        do {
            terminal = try TerminalReviewRecord(
                id: receipt.started.id,
                model: receipt.started.model,
                terminal: .interrupted(.requested(cancellation)),
                endedAt: clock.now(),
                summary: cancellation.message,
                canonicalReview: nil,
                parsedResult: nil
            )
            restored = try RestoredReviewRecord(
                started: receipt.started,
                terminal: terminal
            )
        } catch {
            publishReviewHistoryFailure(error)
            return
        }

        let persistence = historyPersistence
        let retentionPolicy = historyRetentionPolicy
        guard let mutation = historyMutationCoordinator.enqueue(
            intent: restored,
            prepare: { $0 },
            operation: { restored in
                try await persistence.recordTerminal(
                    restored.terminal,
                    retentionPolicy: retentionPolicy
                )
            },
            apply: { [weak self] restored, result in
                guard let self else {
                    return
                }
                switch result {
                case .success(let mutation):
                    persistedStartedReviewIDs.remove(restored.started.id)
                    persistedTerminalReviewIDs.insert(restored.started.id)
                    insertRestoredHistoryJob(restored)
                    reconcileHistoryMutation(mutation)
                case .failure(let failure):
                    publishReviewHistoryFailure(failure)
                }
            }
        ) else {
            publishReviewHistoryFailure(ReviewHistoryOperationFailure(
                message: "Review history mutation admission is closed."
            ))
            return
        }
        _ = await mutation.wait()
    }

    package func finishHistoryStartReceipt(_ receipt: HistoryStartReceipt) {
        if historyStartReceipts[receipt.started.id] === receipt {
            historyStartReceipts.removeValue(forKey: receipt.started.id)
        }
        receipt.finish()
    }

    package func requestHistoryStartCancellations(
        sessionID: String? = nil,
        cancellation: ReviewCancellation
    ) -> [HistoryStartReceipt] {
        let receipts = historyStartReceipts.values
            .filter { sessionID == nil || $0.sessionID == sessionID }
            .sorted { $0.ordinal < $1.ordinal }
        for receipt in receipts {
            receipt.requestCancellation(cancellation)
        }
        return receipts
    }

    package func waitForHistoryStarts(_ receipts: [HistoryStartReceipt]) async {
        for receipt in receipts {
            await receipt.waitUntilFinished()
        }
    }

    package func waitForAllHistoryStarts() async {
        while historyStartReceipts.isEmpty == false {
            let receipts = historyStartReceipts.values.sorted { $0.ordinal < $1.ordinal }
            await waitForHistoryStarts(receipts)
        }
    }

    package func beginHistoryTerminalCommitIfNeeded(for job: CodexReviewJob) {
        guard job.isTerminal,
              persistedStartedReviewIDs.contains(job.id),
              persistedTerminalReviewIDs.contains(job.id) == false,
              historyTerminalReceipts[job.id] == nil
        else {
            return
        }

        let terminal: TerminalReviewRecord
        do {
            terminal = try makeTerminalReviewRecord(job)
        } catch {
            let failure = ReviewHistoryOperationFailure(error)
            publishReviewHistoryFailure(failure)
            let mutation = ReviewHistoryMutationReceipt<ReviewHistoryMutationResult>(
                ordinal: 0,
                result: .failure(failure)
            )
            historyTerminalReceipts[job.id] = HistoryTerminalReceipt(
                jobID: job.id,
                mutation: mutation
            )
            return
        }

        let persistence = historyPersistence
        let retentionPolicy = historyRetentionPolicy
        guard let mutation = historyMutationCoordinator.enqueue(
            intent: terminal,
            prepare: { $0 },
            operation: { terminal in
                try await persistence.recordTerminal(
                    terminal,
                    retentionPolicy: retentionPolicy
                )
            },
            apply: { [weak self] terminal, result in
                guard let self else {
                    return
                }
                switch result {
                case .success(let mutation):
                    persistedStartedReviewIDs.remove(terminal.id)
                    persistedTerminalReviewIDs.insert(terminal.id)
                    reconcileHistoryMutation(mutation)
                case .failure(let failure):
                    publishReviewHistoryFailure(failure)
                }
                resumeReviewWaiters(for: terminal.id)
            }
        ) else {
            let failure = ReviewHistoryOperationFailure(
                message: "Review history mutation admission is closed."
            )
            publishReviewHistoryFailure(failure)
            let mutation = ReviewHistoryMutationReceipt<ReviewHistoryMutationResult>(
                ordinal: 0,
                result: .failure(failure)
            )
            historyTerminalReceipts[job.id] = HistoryTerminalReceipt(
                jobID: job.id,
                mutation: mutation
            )
            return
        }
        historyTerminalReceipts[job.id] = HistoryTerminalReceipt(
            jobID: job.id,
            mutation: mutation
        )
    }

    package func waitForHistoryTerminalCommitIfNeeded(jobID: String) async {
        if let job = job(id: jobID), job.isTerminal {
            beginHistoryTerminalCommitIfNeeded(for: job)
        }
        await historyTerminalReceipts[jobID]?.waitUntilResolved()
    }

    package func historyTerminalCommitIsResolved(jobID: String) -> Bool {
        if persistedTerminalReviewIDs.contains(jobID) {
            return true
        }
        guard persistedStartedReviewIDs.contains(jobID) else {
            return true
        }
        return historyTerminalReceipts[jobID]?.isResolved == true
    }

    package func waitForAllHistoryTerminalCommits() async {
        for job in orderedJobs where job.isTerminal {
            beginHistoryTerminalCommitIfNeeded(for: job)
        }
        let receipts = historyTerminalReceipts.values.sorted { $0.jobID < $1.jobID }
        for receipt in receipts {
            await receipt.waitUntilResolved()
        }
    }

    package func acquireHistoryResultLease(jobID: String) -> HistoryResultLease {
        let lease = HistoryResultLease(jobID: jobID)
        historyResultLeaseIDs[jobID, default: []].insert(lease.id)
        return lease
    }

    package func releaseHistoryResultLease(_ lease: HistoryResultLease) {
        guard var leaseIDs = historyResultLeaseIDs[lease.jobID],
              leaseIDs.remove(lease.id) != nil
        else {
            return
        }
        if leaseIDs.isEmpty {
            historyResultLeaseIDs.removeValue(forKey: lease.jobID)
        } else {
            historyResultLeaseIDs[lease.jobID] = leaseIDs
        }
        applyDeferredHistoryRemovalIfFinalized(jobID: lease.jobID)
    }

    package func applyDeferredHistoryRemovalIfFinalized(jobID: String) {
        guard deferredHistoryRemovalIDs.contains(jobID),
              reviewWorkerTasks[jobID] == nil,
              runtimeStopDetachedReviewWorkerTasks[jobID] == nil,
              historyResultLeaseIDs[jobID]?.isEmpty != false
        else {
            return
        }
        removeHistoryJobs(ids: [jobID])
    }

    package func deleteReviewHistory(id: String) async {
        await loadReviewHistoryIfNeeded()
        guard historyAvailability == .available,
              applicationShutdownRequested == false
        else {
            return
        }
        let persistence = historyPersistence
        guard let receipt = historyMutationCoordinator.enqueue(
            intent: id,
            prepare: { [weak self] id -> DeleteReviewHistoryPlan in
                guard let self,
                      historyAvailability == .available,
                      let job = job(id: id),
                      job.isTerminal,
                      persistedTerminalReviewIDs.contains(id)
                else {
                    return .none
                }
                return .review(id)
            },
            operation: { (plan: DeleteReviewHistoryPlan) async throws -> ReviewHistoryMutationResult in
                switch plan {
                case .none, .allTerminal:
                    return ReviewHistoryMutationResult()
                case .review(let id):
                    return try await persistence.deleteTerminalReview(id: id)
                }
            },
            apply: { [weak self] _, result in
                guard let self else {
                    return
                }
                switch result {
                case .success(let mutation):
                    reconcileHistoryMutation(mutation)
                case .failure(let failure):
                    publishReviewHistoryFailure(failure)
                }
            }
        ) else {
            return
        }
        _ = await receipt.wait()
    }

    package func deleteAllReviewHistory() async {
        await loadReviewHistoryIfNeeded()
        guard historyAvailability == .available,
              applicationShutdownRequested == false
        else {
            return
        }
        let persistence = historyPersistence
        guard let receipt = historyMutationCoordinator.enqueue(
            intent: (),
            prepare: { [weak self] _ -> DeleteReviewHistoryPlan in
                guard let self,
                      historyAvailability == .available,
                      persistedTerminalReviewIDs.isEmpty == false
                else {
                    return .none
                }
                return .allTerminal
            },
            operation: { (plan: DeleteReviewHistoryPlan) async throws -> ReviewHistoryMutationResult in
                switch plan {
                case .none, .review:
                    return ReviewHistoryMutationResult()
                case .allTerminal:
                    return try await persistence.deleteAllTerminalReviews()
                }
            },
            apply: { [weak self] _, result in
                guard let self else {
                    return
                }
                switch result {
                case .success(let mutation):
                    reconcileHistoryMutation(mutation)
                case .failure(let failure):
                    publishReviewHistoryFailure(failure)
                }
            }
        ) else {
            return
        }
        _ = await receipt.wait()
    }

    public func shutdown() async {
        if let task = applicationShutdownTask {
            await task.value
            return
        }
        applicationShutdownRequested = true
        _ = requestHistoryStartCancellations(
            cancellation: .system(message: "The review application is shutting down.")
        )
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else {
                return
            }
            await performApplicationShutdown()
        }
        applicationShutdownTask = task
        await task.value
    }

    package func currentReviewHistoryOrdering(
        workspaceSortOrders: [String: Double] = [:],
        reviewSortOrders: [String: Double] = [:]
    ) -> ReviewHistoryOrdering {
        let durableJobs = jobs.filter {
            deferredHistoryRemovalIDs.contains($0.id) == false
        }
        let pendingStartedCWDs = Set(historyStartReceipts.values.compactMap { receipt in
            persistedStartedReviewIDs.contains(receipt.started.id)
                ? receipt.started.cwd
                : nil
        })
        let durableCWDs = Set(durableJobs.map(\.cwd)).union(pendingStartedCWDs)
        var resolvedWorkspaceSortOrders = Dictionary(uniqueKeysWithValues:
            workspaces.lazy
                .filter { durableCWDs.contains($0.cwd) }
                .map { ($0.cwd, workspaceSortOrders[$0.cwd] ?? $0.sortOrder) }
        )
        var resolvedReviewSortOrders = Dictionary(uniqueKeysWithValues:
            durableJobs.map { ($0.id, reviewSortOrders[$0.id] ?? $0.sortOrder) }
        )
        for receipt in historyStartReceipts.values
        where persistedStartedReviewIDs.contains(receipt.started.id) {
            if resolvedWorkspaceSortOrders[receipt.started.cwd] == nil {
                resolvedWorkspaceSortOrders[receipt.started.cwd] =
                    workspaceSortOrders[receipt.started.cwd]
                    ?? receipt.started.workspaceSortOrder
            }
            if resolvedReviewSortOrders[receipt.started.id] == nil {
                resolvedReviewSortOrders[receipt.started.id] =
                    reviewSortOrders[receipt.started.id]
                    ?? receipt.started.sortOrder
            }
        }
        return ReviewHistoryOrdering(
            workspaces: resolvedWorkspaceSortOrders.map {
                .init(cwd: $0.key, sortOrder: $0.value)
            },
            reviews: resolvedReviewSortOrders.map {
                .init(id: $0.key, sortOrder: $0.value)
            }
        )
    }

    package func publishReviewHistoryFailure(_ error: any Error) {
        guard historyAvailability != .closed else {
            return
        }
        transitionHistoryAvailability(to: .failed(error.localizedDescription))
    }

    package func reconcileHistoryMutation(_ result: ReviewHistoryMutationResult) {
        let removedIDs = result.removedReviewIDs
        guard removedIDs.isEmpty == false else {
            return
        }
        let removedActiveIDs = Set(jobs.compactMap { job in
            removedIDs.contains(job.id) && job.isTerminal == false ? job.id : nil
        }).union(removedIDs.intersection(persistedStartedReviewIDs))
        guard removedActiveIDs.isEmpty else {
            publishReviewHistoryFailure(ReviewHistoryOperationFailure(
                message: "Review history mutation removed active review IDs: \(removedActiveIDs.sorted())."
            ))
            return
        }
        let deferredIDs = Set(jobs.compactMap { job -> String? in
            guard removedIDs.contains(job.id), job.isTerminal else {
                return nil
            }
            guard case .live = job.origin else {
                return nil
            }
            let hasWorker = reviewWorkerTasks[job.id] != nil
                || runtimeStopDetachedReviewWorkerTasks[job.id] != nil
            let hasResultLease = historyResultLeaseIDs[job.id]?.isEmpty == false
            return hasWorker || hasResultLease ? job.id : nil
        })
        if deferredIDs.isEmpty == false {
            persistedTerminalReviewIDs.subtract(deferredIDs)
            deferredHistoryRemovalIDs.formUnion(deferredIDs)
        }
        removeHistoryJobs(ids: removedIDs.subtracting(deferredIDs))
    }

    private func performApplicationShutdown() async {
        if historyLoadTask != nil {
            await loadReviewHistoryIfNeeded()
        }

        await stop(intent: .explicitStop)
        _ = await closeRegisteredStoreWork(
            reason: .system(message: "The review application is shutting down.")
        )
        await waitForAllHistoryStarts()
        await waitForAllHistoryTerminalCommits()

        if historyLoadSucceeded {
            await persistCurrentHistoryOrderingForShutdown()
        }
        await historyMutationCoordinator.closeAdmissionAndWait()

        do {
            try await historyPersistence.close()
            transitionHistoryAvailability(to: .closed)
        } catch {
            publishReviewHistoryFailure(error)
        }
    }

    private func persistCurrentHistoryOrderingForShutdown() async {
        let persistence = historyPersistence
        guard let receipt = historyMutationCoordinator.enqueue(
            intent: (),
            prepare: { [weak self] _ in
                self?.currentReviewHistoryOrdering()
                    ?? ReviewHistoryOrdering(workspaces: [], reviews: [])
            },
            operation: { ordering in
                try await persistence.saveOrdering(ordering)
            },
            apply: { [weak self] _, result in
                if case .failure(let failure) = result {
                    self?.publishReviewHistoryFailure(failure)
                }
            }
        ) else {
            return
        }
        _ = await receipt.wait()
    }

    private func restoreReviewHistory(_ records: [RestoredReviewRecord]) throws {
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
            guard seenReviewIDs.insert(record.started.id).inserted else {
                throw ReviewHistoryOperationFailure(
                    message: "Loaded review history contains duplicate ID \(record.started.id)."
                )
            }
            if let existing = workspaceSortOrders[record.started.cwd],
               existing != record.started.workspaceSortOrder
            {
                throw ReviewHistoryOperationFailure(
                    message: "Loaded workspace \(record.started.cwd) has conflicting order values."
                )
            }
            workspaceSortOrders[record.started.cwd] = record.started.workspaceSortOrder
            restoredJobs.append(record.makeRestoredJob())
        }

        workspaces = Set(workspaceSortOrders.map { cwd, sortOrder in
            CodexReviewWorkspace(cwd: cwd, sortOrder: sortOrder)
        })
        jobs = Set(restoredJobs)
        persistedTerminalReviewIDs = seenReviewIDs
        historyLoadSucceeded = true
        writeDiagnosticsIfNeeded()
    }

    private func makeTerminalReviewRecord(
        _ job: CodexReviewJob
    ) throws -> TerminalReviewRecord {
        guard let terminal = job.core.lifecycle.terminal else {
            throw ReviewHistoryRecordError(
                "A terminal job requires its typed terminal before persistence."
            )
        }
        let canonicalReview: String?
        let parsedResult: PersistedParsedReviewResult?
        if terminal == .completed {
            canonicalReview = job.core.output.lastAgentMessage
            parsedResult = job.core.output.reviewResult.map(PersistedParsedReviewResult.init)
        } else {
            canonicalReview = nil
            parsedResult = nil
        }
        return try TerminalReviewRecord(
            id: job.id,
            model: job.core.run.model,
            terminal: terminal,
            endedAt: job.core.lifecycle.endedAt,
            summary: job.core.output.summary,
            canonicalReview: canonicalReview,
            parsedResult: parsedResult
        )
    }

    private func insertRestoredHistoryJob(_ restored: RestoredReviewRecord) {
        let job = restored.makeRestoredJob()
        if workspace(cwd: job.cwd) == nil {
            workspaces.insert(CodexReviewWorkspace(
                cwd: job.cwd,
                sortOrder: restored.started.workspaceSortOrder
            ))
        }
        jobs.insert(job)
        writeDiagnosticsIfNeeded()
    }

    private func historyWorkspaceSortOrder(cwd: String) -> Double? {
        if let workspace = workspace(cwd: cwd) {
            return workspace.sortOrder
        }
        return historyStartReceipts.values
            .first(where: { $0.started.cwd == cwd })?
            .started.workspaceSortOrder
    }

    private func nextHistoryJobSortOrder(cwd: String) -> Double {
        let liveOrders = jobs(inWorkspace: cwd).map(\.sortOrder)
        let pendingOrders = historyStartReceipts.values
            .filter { $0.started.cwd == cwd }
            .map { $0.started.sortOrder }
        return ((liveOrders + pendingOrders).max() ?? -1) + 1
    }

    private func nextHistoryWorkspaceSortOrder() -> Double {
        let liveOrders = workspaces.map(\.sortOrder)
        let pendingOrders = historyStartReceipts.values.map {
            $0.started.workspaceSortOrder
        }
        return ((liveOrders + pendingOrders).max() ?? -1) + 1
    }

    private func removeHistoryJobs(ids: Set<String>) {
        guard ids.isEmpty == false else {
            return
        }
        jobs = Set(jobs.filter { ids.contains($0.id) == false })
        persistedStartedReviewIDs.subtract(ids)
        persistedTerminalReviewIDs.subtract(ids)
        deferredHistoryRemovalIDs.subtract(ids)
        for id in ids {
            historyTerminalReceipts.removeValue(forKey: id)
            historyResultLeaseIDs.removeValue(forKey: id)
        }
        let retainedCWDs = Set(jobs.map(\.cwd))
            .union(historyStartReceipts.values.map { $0.started.cwd })
        workspaces = Set(workspaces.filter { retainedCWDs.contains($0.cwd) })
        writeDiagnosticsIfNeeded()
    }

    package func requireReviewHistoryAvailable() throws {
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
}
