import Foundation

private struct ReviewCancellationBatchResult: Sendable {
    let runID: ReviewRunID
    let failure: ReviewBackendFailure?
}

extension CodexReviewStore {
    package func activeReviewRunIDs(for sessionID: String) -> [ReviewRunID] {
        orderedReviewRuns
            .filter { $0.sessionID == sessionID && $0.isTerminal == false }
            .map(\.id)
    }

    @discardableResult
    package func startReview(
        sessionID: String,
        request: CodexReviewAPI.Start.Request
    ) async throws -> CodexReviewAPI.Read.Result {
        let runID = try await beginReview(sessionID: sessionID, request: request)
        guard let worker = runtimeState.workerTask(for: runID) else {
            preconditionFailure("A newly inserted review run must publish its worker synchronously.")
        }
        return try await withTaskCancellationHandler {
            _ = try await awaitReview(sessionID: sessionID, runID: runID)
            await worker.value
            return try readReview(sessionID: sessionID, runID: runID)
        } onCancel: {
            worker.cancel()
        }
    }

    @discardableResult
    package func startReview(
        sessionID: String,
        request: CodexReviewAPI.Start.Request,
        waitTimeout: Duration
    ) async throws -> CodexReviewAPI.Read.Result {
        let runID = try await beginReview(sessionID: sessionID, request: request)
        guard let worker = runtimeState.workerTask(for: runID) else {
            preconditionFailure("A newly inserted review run must publish its worker synchronously.")
        }
        // A timeout returns while the worker keeps running (clients re-await
        // by runId), but caller cancellation must cancel the worker like the
        // unbounded overload, or disconnected clients orphan the review.
        return try await withTaskCancellationHandler {
            try await awaitReview(sessionID: sessionID, runID: runID, timeout: waitTimeout)
        } onCancel: {
            worker.cancel()
        }
    }

    package func awaitReview(
        sessionID: String?,
        runID: ReviewRunID,
        timeout: Duration? = nil
    ) async throws -> CodexReviewAPI.Read.Result {
        let runRecord = try requireReviewRun(runID: runID)
        if let sessionID, runRecord.sessionID != sessionID {
            throw CodexReviewAPI.Error.runNotFound("Run \(runID.rawValue) was not found.")
        }
        if runRecord.isTerminal == false {
            await waitForReviewTerminal(runID: runID, timeout: timeout)
        }
        return try readReview(sessionID: sessionID, runID: runID)
    }

    @discardableResult
    package func beginReview(
        sessionID: String,
        request: CodexReviewAPI.Start.Request
    ) async throws -> ReviewRunID {
        try await requireReviewThreadRetentionAcceptance()
        guard closedSessions.contains(sessionID) == false else {
            throw CodexReviewAPI.Error.invalidArguments("Review session \(sessionID) is closed.")
        }

        let validatedRequest = try request.validated()
        let runID = try ReviewRunID(validating: idGenerator.next())
        let runRecord = ReviewRunRecord(
            id: runID,
            sessionID: sessionID,
            cwd: validatedRequest.cwd,
            sortOrder: nextReviewRunSortOrder(),
            targetSummary: validatedRequest.target.displaySummary,
            core: .queued,
            executionPhase: .starting
        )
        insertReviewRun(runRecord)
        runtimeState.markStarting(runID)
        _ = launchReviewWorker(
            runID: runID,
            sessionID: sessionID,
            request: validatedRequest
        )
        return runID
    }

    private func launchReviewWorker(
        runID: ReviewRunID,
        sessionID: String,
        request: CodexReviewAPI.Start.Request
    ) -> Task<Void, Never> {
        let generation = ReviewWorkerGeneration()
        let worker = ReviewStoreWorker(
            runID: runID,
            startRequest: .init(
                runID: runID,
                sessionID: sessionID,
                request: request,
                model: settings.effectiveModel
            ),
            backend: backend,
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: networkRecoveryPolicy,
            retentionRegistry: reviewThreadRetentionRegistry,
            retentionScope: currentReviewThreadRetentionScope,
            sink: ReviewStoreCommitSink(store: self),
            workerGeneration: generation
        )
        let task = Task { @MainActor in
            await worker.run()
        }
        return runtimeState.installWorker(
            for: runID,
            generation: generation,
            task: task
        )
    }

    package func readReview(runID: ReviewRunID) throws -> CodexReviewAPI.Read.Result {
        try readReview(sessionID: nil, runID: runID)
    }

    package func readReview(
        sessionID: String?,
        runID: ReviewRunID
    ) throws -> CodexReviewAPI.Read.Result {
        let runRecord = try requireReviewRun(runID: runID)
        if let sessionID, runRecord.sessionID != sessionID {
            throw CodexReviewAPI.Error.runNotFound("Run \(runID.rawValue) was not found.")
        }
        return CodexReviewAPI.Read.Result(
            runID: runRecord.id,
            core: runRecord.core,
            presentation: runRecord.presentation,
            elapsedSeconds: elapsedSeconds(for: runRecord)
        )
    }

    package func listReviews(
        cwd: String? = nil,
        statuses: [ReviewRunState]? = nil,
        limit: Int? = nil,
        allowedRunIDs: Set<ReviewRunID>? = nil
    ) -> CodexReviewAPI.List.Result {
        let filtered = filteredReviewRuns(
            cwd: cwd,
            statuses: statuses,
            allowedRunIDs: allowedRunIDs
        )
        let clampedLimit = min(max(limit ?? 20, 1), 100)
        return CodexReviewAPI.List.Result(items: Array(filtered.prefix(clampedLimit)).map(makeListItem))
    }

    package func listReviews(
        sessionID: String?,
        cwd: String? = nil,
        statuses: [ReviewRunState]? = nil,
        limit: Int? = nil,
        allowedRunIDs: Set<ReviewRunID>? = nil
    ) -> CodexReviewAPI.List.Result {
        let statusSet = statuses.map(Set.init)
        let filtered = orderedReviewRuns.filter { runRecord in
            if let sessionID, runRecord.sessionID != sessionID {
                return false
            }
            if let allowedRunIDs, allowedRunIDs.contains(runRecord.id) == false {
                return false
            }
            if let cwd, runRecord.cwd != cwd {
                return false
            }
            if let statusSet, statusSet.contains(runRecord.core.status) == false {
                return false
            }
            return true
        }
        let clampedLimit = min(max(limit ?? 20, 1), 100)
        return CodexReviewAPI.List.Result(items: Array(filtered.prefix(clampedLimit)).map(makeListItem))
    }

    package func resolveRun(
        selector: CodexReviewAPI.Run.Selector,
        allowedRunIDs: Set<ReviewRunID>? = nil
    ) throws -> ReviewRunRecord {
        try resolveRun(
            sessionID: nil,
            selector: selector,
            allowedRunIDs: allowedRunIDs
        )
    }

    package func resolveRun(
        sessionID: String?,
        selector: CodexReviewAPI.Run.Selector,
        allowedRunIDs: Set<ReviewRunID>? = nil
    ) throws -> ReviewRunRecord {
        let statusSet = selector.statuses.map(Set.init)
        let matches = orderedReviewRuns.filter { runRecord in
            if let sessionID, runRecord.sessionID != sessionID {
                return false
            }
            if let allowedRunIDs, allowedRunIDs.contains(runRecord.id) == false {
                return false
            }
            if let cwd = selector.cwd, runRecord.cwd != cwd {
                return false
            }
            if let statusSet, statusSet.contains(runRecord.core.status) == false {
                return false
            }
            if let runID = selector.runID, runID != runRecord.id {
                return false
            }
            return true
        }
        if let runRecord = matches.first, matches.count == 1 {
            return runRecord
        }
        if matches.isEmpty {
            throw CodexReviewAPI.Error.runNotFound("No review run matched the selector.")
        }
        throw CodexReviewAPI.Run.SelectionError.ambiguous(matches.map(makeListItem))
    }

    package func cancelReview(
        runID: ReviewRunID,
        sessionID: String,
        cancellation: ReviewCancellation = .system()
    ) async throws -> CodexReviewAPI.Cancel.Outcome {
        guard let runRecord = reviewRun(id: runID), runRecord.sessionID == sessionID else {
            throw CodexReviewAPI.Error.runNotFound("Run \(runID.rawValue) was not found.")
        }
        return try await cancelReview(runID: runID, cancellation: cancellation)
    }

    @discardableResult
    package func cancelReview(
        runID: ReviewRunID,
        cancellation: ReviewCancellation = .system()
    ) async throws -> CodexReviewAPI.Cancel.Outcome {
        let runRecord = try requireReviewRun(runID: runID)
        if let existing = runtimeState.existingCancellationOperation(for: runID) {
            try await existing.completion.wait()
            return try requireCancellationOutcome(runID: runID)
        }
        guard isCancellableReviewRun(runRecord) else {
            return .init(
                runID: runRecord.id,
                cancelled: false,
                core: runRecord.core,
                presentation: runRecord.presentation
            )
        }

        try Task.checkCancellation()

        let resumePhase = runRecord.executionPhase
            ?? .running(attemptGeneration: 0)

        runRecord.cancellationRequested = true
        runRecord.pendingCancellation = cancellation
        runRecord.executionPhase = .cancelling(cancellation)

        if runRecord.core.status == .queued {
            if runtimeState.isStarting(runID) {
                runtimeState.setStartupCancellation(cancellation, for: runID)
            }
            try completeCancellationLocally(
                runID: runRecord.id,
                sessionID: runRecord.sessionID,
                cancellation: cancellation
            )
            runtimeState.cancelActiveWorker(for: runID)
            return .init(
                runID: runRecord.id,
                cancelled: true,
                core: runRecord.core,
                presentation: runRecord.presentation
            )
        }

        guard let workerTask = runtimeState.workerTask(for: runID),
              let authority = runtimeState.cancellationAuthority(for: runID) else {
            preconditionFailure("A cancellable running review must have a worker and cancellation authority.")
        }
        let token = ReviewCancellationOperationToken()
        let completion = ReviewCancellationCompletion()
        let backend = self.backend
        let sink = ReviewStoreCommitSink(store: self)
        let task = Task { @MainActor in
            let result: ReviewCancellationOperationResult
            switch authority {
            case .interrupt(let attempt):
                do {
                    try await backend.interruptReview(
                        attempt,
                        reason: .init(message: cancellation.message)
                    )
                    sink.interruptSucceeded(runID: runID, cancellation: cancellation)
                    await workerTask.value
                    result = .completed
                } catch {
                    let failure = cancellationBackendFailure(error)
                    if sink.interruptFailed(runID: runID, resumePhase: resumePhase) {
                        await workerTask.value
                        result = .completed
                    } else {
                        result = .failed(failure)
                    }
                }
            case .workerCleanup:
                sink.cancelWorker(for: runID)
                await workerTask.value
                if sink.cancellationOutcome(runID: runID)?.presentation.status == .cancelled {
                    result = .completed
                } else {
                    result = .failed(.protocolViolation(
                        message: "Accepted review cancellation ended without a cancelled terminal."
                    ))
                }
            }
            completion.finish(result)
            sink.cancellationOperationFinished(runID: runID, token: token)
        }
        let join = ReviewCancellationJoin(
            token: token,
            task: task,
            completion: completion
        )
        runtimeState.installCancellationOperation(join, for: runID)
        try await completion.wait()
        return try requireCancellationOutcome(runID: runID)
    }

    @discardableResult
    package func cancelReview(
        chatID: String,
        cancellation: ReviewCancellation = .system()
    ) async throws -> CodexReviewAPI.Cancel.Outcome? {
        guard let runRecord = cancellableReviewRun(forChatID: chatID) else {
            return nil
        }
        return try await cancelReview(runID: runRecord.id, cancellation: cancellation)
    }

    package func closeSession(
        _ sessionID: String,
        reason: ReviewCancellation = .sessionClosed()
    ) async -> CodexReviewSessionCloseResult {
        closedSessions.insert(sessionID)
        let memberIDs = Set(
            orderedReviewRuns
                .filter { $0.sessionID == sessionID }
                .map(\.id)
        )
        var failedRunIDs = await cancelReviewRunsConcurrently(
            memberIDs.filter { reviewRun(id: $0)?.isTerminal == false },
            reason: reason
        )
        for task in runtimeState.ownedTasks(for: memberIDs) {
            await task.value
        }
        let terminalAndDrainedRunIDs = Set(memberIDs.filter { runID in
            reviewRun(id: runID)?.isTerminal == true
                && runtimeState.isDrained(runID)
                && failedRunIDs.contains(runID) == false
        })
        failedRunIDs.formUnion(memberIDs.subtracting(terminalAndDrainedRunIDs))
        return .init(
            terminalAndDrainedRunIDs: terminalAndDrainedRunIDs,
            failedRunIDs: failedRunIDs
        )
    }

    package func releaseClosedSession(_ sessionID: String) {
        precondition(
            closedSessions.contains(sessionID),
            "Only a logically closed review session can release its store tombstone."
        )
        let memberIDs = orderedReviewRuns
            .filter { $0.sessionID == sessionID }
            .map(\.id)
        precondition(
            memberIDs.allSatisfy { runID in
                reviewRun(id: runID)?.isTerminal == true
                    && runtimeState.isDrained(runID)
            },
            "A review session tombstone can only be released after every member is terminal and drained."
        )
        closedSessions.remove(sessionID)
    }

    @discardableResult
    package func closeActiveReviewSessions(
        reason: ReviewCancellation
    ) async -> Bool {
        let runIDs =
            orderedReviewRuns
            .filter { $0.isTerminal == false }
            .map(\.id)
        _ = await cancelReviewRunsConcurrently(runIDs, reason: reason)
        let ownedTasks = runtimeState.ownedTasks(for: Set(runIDs))
        for task in ownedTasks {
            await task.value
        }
        return runIDs.allSatisfy { runID in
            reviewRun(id: runID)?.isTerminal == true
                && runtimeState.isDrained(runID)
        }
    }

    private func cancelReviewRunsConcurrently<S: Sequence>(
        _ runIDs: S,
        reason: ReviewCancellation
    ) async -> Set<ReviewRunID> where S.Element == ReviewRunID {
        let runIDs = Array(runIDs)
        let sink = ReviewStoreCommitSink(store: self)
        let results = await withTaskGroup(
            of: ReviewCancellationBatchResult.self,
            returning: [ReviewCancellationBatchResult].self
        ) { group in
            for runID in runIDs {
                group.addTask { [sink] in
                    .init(
                        runID: runID,
                        failure: await sink.cancelReview(
                            runID: runID,
                            cancellation: reason
                        )
                    )
                }
            }
            var results: [ReviewCancellationBatchResult] = []
            while let result = await group.next() {
                results.append(result)
            }
            return results
        }

        var failedRunIDs: Set<ReviewRunID> = []
        for result in results {
            guard let failure = result.failure else {
                continue
            }
            failedRunIDs.insert(result.runID)
            sink.markWorkerFailure(failure, for: result.runID)
            runtimeState.cancelActiveWorker(for: result.runID)
        }
        return failedRunIDs
    }

    private func requireReviewRun(runID: ReviewRunID) throws -> ReviewRunRecord {
        guard let runRecord = reviewRun(id: runID) else {
            throw CodexReviewAPI.Error.runNotFound("Run \(runID.rawValue) was not found.")
        }
        return runRecord
    }

    private func requireCancellationOutcome(
        runID: ReviewRunID
    ) throws -> CodexReviewAPI.Cancel.Outcome {
        let runRecord = try requireReviewRun(runID: runID)
        return .init(
            runID: runID,
            cancelled: runRecord.presentation.status == .cancelled,
            core: runRecord.core,
            presentation: runRecord.presentation
        )
    }

    private func filteredReviewRuns(
        cwd: String?,
        statuses: [ReviewRunState]?,
        allowedRunIDs: Set<ReviewRunID>?
    ) -> [ReviewRunRecord] {
        let statusSet = statuses.map(Set.init)
        return orderedReviewRuns.filter { runRecord in
            if let allowedRunIDs, allowedRunIDs.contains(runRecord.id) == false {
                return false
            }
            if let cwd, runRecord.cwd != cwd {
                return false
            }
            if let statusSet, statusSet.contains(runRecord.core.status) == false {
                return false
            }
            return true
        }
    }

    private func makeListItem(_ runRecord: ReviewRunRecord) -> CodexReviewAPI.Run.ListItem {
        CodexReviewAPI.Run.ListItem(
            runID: runRecord.id,
            cwd: runRecord.cwd,
            targetSummary: runRecord.targetSummary,
            core: runRecord.core,
            presentation: runRecord.presentation,
            elapsedSeconds: elapsedSeconds(for: runRecord)
        )
    }

    private func elapsedSeconds(for runRecord: ReviewRunRecord) -> Int? {
        guard let startedAt = runRecord.core.startedAt else {
            return nil
        }
        let end = runRecord.core.endedAt ?? clock.now()
        return max(0, Int(end.timeIntervalSince(startedAt)))
    }

    private func insertReviewRun(_ runRecord: ReviewRunRecord) {
        reviewRuns.insert(runRecord)
        writeDiagnosticsIfNeeded()
    }

    private func waitForReviewTerminal(runID: ReviewRunID, timeout: Duration?) async {
        guard let runRecord = reviewRun(id: runID),
            runRecord.isTerminal == false
        else {
            return
        }
        _ = await ReviewObservationAwaiter.waitUntilTerminal(
            run: runRecord,
            timeout: timeout
        )
    }

    private func nextReviewRunSortOrder() -> Double {
        (reviewRuns.map(\.sortOrder).max() ?? -1) + 1
    }
}

func cancellationBackendFailure(_ error: any Error) -> ReviewBackendFailure {
    if let failure = error as? ReviewBackendFailure {
        return failure
    }
    return .protocolViolation(
        message: "Review backend interruptReview threw an unsupported error: \(error.localizedDescription)"
    )
}

extension ReviewBackendTerminal {
    var isConnectionTermination: Bool {
        guard case .failed(.connectionTerminated) = self else {
            return false
        }
        return true
    }
}
