import Foundation

private let networkRecoveryUnavailableMessage = "Network unavailable; waiting to reconnect."
private let networkRecoveryRestoredMessage = "Network restored; restarting review."

extension CodexReviewStore {
    package func activeReviewRunIDs(for sessionID: String) -> [String] {
        orderedReviewRuns
            .filter { $0.sessionID == sessionID && $0.isTerminal == false }
            .map(\.id)
    }

    @discardableResult
    package func startReview(
        sessionID: String,
        request: CodexReviewAPI.Start.Request
    ) async throws -> CodexReviewAPI.Read.Result {
        let runID = try beginReview(sessionID: sessionID, request: request)
        return try await withTaskCancellationHandler {
            _ = try await awaitReview(sessionID: sessionID, runID: runID)
            await runtimeState.awaitActiveWorker(for: runID)
            return try readReview(sessionID: sessionID, runID: runID)
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.runtimeState.cancelActiveWorker(for: runID)
            }
        }
    }

    @discardableResult
    package func startReview(
        sessionID: String,
        request: CodexReviewAPI.Start.Request,
        waitTimeout: Duration
    ) async throws -> CodexReviewAPI.Read.Result {
        let runID = try beginReview(sessionID: sessionID, request: request)
        return try await awaitReview(sessionID: sessionID, runID: runID, timeout: waitTimeout)
    }

    package func awaitReview(
        sessionID: String?,
        runID: String,
        timeout: Duration? = nil
    ) async throws -> CodexReviewAPI.Read.Result {
        let runRecord = try requireReviewRun(runID: runID)
        if let sessionID, runRecord.sessionID != sessionID {
            throw CodexReviewAPI.Error.runNotFound("Run \(runID) was not found.")
        }
        if runRecord.isTerminal == false {
            await waitForReviewTerminal(runID: runID, timeout: timeout)
        }
        return try readReview(sessionID: sessionID, runID: runID)
    }

    @discardableResult
    private func beginReview(
        sessionID: String,
        request: CodexReviewAPI.Start.Request
    ) throws -> String {
        guard closedSessions.contains(sessionID) == false else {
            throw CodexReviewAPI.Error.invalidArguments("Review session \(sessionID) is closed.")
        }

        let validatedRequest = try request.validated()
        let runID = idGenerator.next()
        let createdAt = clock.now()
        let runRecord = ReviewRunRecord(
            id: runID,
            sessionID: sessionID,
            cwd: validatedRequest.cwd,
            sortOrder: nextReviewRunSortOrder(),
            targetSummary: validatedRequest.target.displaySummary,
            core: .init(
                lifecycle: .init(status: .queued),
                output: .init(summary: "Queued.")
            )
        )
        insertReviewRun(runRecord)
        markReviewRunning(runRecord, startedAt: createdAt)
        runtimeState.markStarting(runID)
        launchReviewWorker(runID: runID, sessionID: sessionID, request: validatedRequest)
        return runID
    }

    private func launchReviewWorker(
        runID: String,
        sessionID: String,
        request: CodexReviewAPI.Start.Request
    ) {
        runtimeState.cancelActiveWorker(for: runID)
        runtimeState.setActiveWorker(
            Task { [weak self] in
                await self?.runReviewWorker(runID: runID, sessionID: sessionID, request: request)
            }, for: runID)
    }

    private func runReviewWorker(
        runID: String,
        sessionID: String,
        request validatedRequest: CodexReviewAPI.Start.Request
    ) async {
        guard let runRecord = reviewRun(id: runID) else {
            runtimeState.clearStarting(runID)
            runtimeState.removeActiveWorker(for: runID)
            return
        }
        let startRequest = CodexReviewBackendModel.Review.Start(
            runID: runID,
            sessionID: sessionID,
            request: validatedRequest,
            model: settings.effectiveModel
        )
        var run: CodexReviewBackendModel.Review.Run?
        do {
            let backendAttempt = try await backend.startReview(startRequest)
            let backendRun = backendAttempt.run
            runtimeState.clearStarting(runID)
            run = backendRun
            if Task.isCancelled {
                throw CancellationError()
            }
            applyBackendRun(backendRun, to: runRecord)
            if let startupCancellation = runtimeState.takeStartupCancellation(for: runID) {
                try? await backend.interruptReview(
                    backendRun,
                    reason: .init(message: startupCancellation.message)
                )
                if runRecord.isTerminal == false {
                    try completeCancellationLocally(
                        runID: runRecord.id,
                        sessionID: runRecord.sessionID,
                        cancellation: startupCancellation
                    )
                }
            } else if runRecord.cancellationRequested {
                try await backend.interruptReview(
                    backendRun,
                    reason: .init(message: runRecord.core.lifecycle.cancellation?.message ?? "Cancellation requested.")
                )
                try completeCancellationLocally(
                    runID: runRecord.id,
                    sessionID: runRecord.sessionID,
                    cancellation: runRecord.core.lifecycle.cancellation ?? .system()
                )
            }

            if runRecord.isTerminal {
                await backend.cleanupReview(backendRun)
                runtimeState.clearReviewRunState(for: runID)
            } else {
                let currentRun = try await consumeReviewEvents(
                    for: backendAttempt,
                    runRecord: runRecord,
                    startRequest: startRequest
                )
                run = currentRun
                await backend.cleanupReview(currentRun)
                runtimeState.clearReviewRunState(for: runID)
            }
        } catch let error where error is CancellationError || Task.isCancelled {
            runtimeState.clearStarting(runID)
            let startupCancellation = runtimeState.takeStartupCancellation(for: runID)
            if let cleanupRun = runtimeState.activeRun(for: runID) ?? run {
                await interruptReviewAfterTaskCancellation(cleanupRun, runRecord: runRecord)
                await backend.cleanupReview(cleanupRun)
            } else if runRecord.isTerminal == false || startupCancellation != nil {
                try? completeCancellationLocally(
                    runID: runRecord.id,
                    sessionID: runRecord.sessionID,
                    cancellation: startupCancellation ?? runRecord.core.lifecycle.cancellation ?? .system()
                )
            }
            runtimeState.clearReviewRunState(for: runID)
        } catch {
            runtimeState.clearStarting(runID)
            let startupCancellation = runtimeState.takeStartupCancellation(for: runID)
            if let cleanupRun = runtimeState.activeRun(for: runID) ?? run {
                await backend.cleanupReview(cleanupRun)
            }
            runtimeState.clearReviewRunState(for: runID)
            if runRecord.isTerminal == false, let startupCancellation {
                try? completeCancellationLocally(
                    runID: runRecord.id,
                    sessionID: runRecord.sessionID,
                    cancellation: startupCancellation
                )
            } else if runRecord.isTerminal == false {
                markReviewFailed(runRecord, message: error.localizedDescription)
            }
        }
        runtimeState.removeActiveWorker(for: runID)
        runtimeState.removeDetachedWorker(for: runID)
    }

    private func interruptReviewAfterTaskCancellation(_ run: CodexReviewBackendModel.Review.Run, runRecord: ReviewRunRecord)
        async
    {
        guard runRecord.isTerminal == false else {
            return
        }
        let cancellation = runRecord.core.lifecycle.cancellation ?? .system()
        runRecord.cancellationRequested = true
        runRecord.core.lifecycle.cancellation = cancellation
        runRecord.core.output.summary = cancellation.message
        runRecord.core.lifecycle.errorMessage = cancellation.message
        do {
            try await backend.interruptReview(
                run,
                reason: .init(message: cancellation.message)
            )
            try completeCancellationLocally(
                runID: runRecord.id,
                sessionID: runRecord.sessionID,
                cancellation: cancellation
            )
        } catch {
            try? recordCancellationFailure(
                runID: runRecord.id,
                sessionID: runRecord.sessionID,
                message: error.localizedDescription
            )
        }
    }

    private func applyBackendRun(_ backendRun: CodexReviewBackendModel.Review.Run, to runRecord: ReviewRunRecord) {
        runtimeState.setActiveRun(backendRun, for: runRecord.id)
        runRecord.core.run = .init(
            attemptID: backendRun.attemptID,
            reviewThreadID: backendRun.reviewThreadID,
            threadID: backendRun.threadID,
            turnID: backendRun.turnID,
            model: backendRun.model
        )
        writeDiagnosticsIfNeeded()
    }

    private func appendRecoveryProgress(_ message: String, to runRecord: ReviewRunRecord) {
        runRecord.core.output.summary = message
        writeDiagnosticsIfNeeded()
    }

    private func markReviewWaitingForNetworkRecovery(_ runRecord: ReviewRunRecord) {
        runRecord.resetReviewAttemptOutputForRecovery()
        appendRecoveryProgress(networkRecoveryUnavailableMessage, to: runRecord)
    }

    private func applyMessageSnapshot(
        _ text: String,
        itemID: String?,
        isCompleted: Bool,
        to runRecord: ReviewRunRecord,
        at timestamp: Date
    ) {
        let resolvedItemID =
            itemID?.nilIfEmpty
            ?? runRecord.nextSyntheticMessageItemID(prefix: "message")
        runRecord.noteAgentMessageSnapshot(
            itemID: resolvedItemID,
            text: text,
            isCompleted: isCompleted
        )
    }

    private func applyMessageDelta(
        _ text: String,
        itemID: String,
        to runRecord: ReviewRunRecord,
        at timestamp: Date
    ) {
        _ = runRecord.appendAgentMessageDelta(itemID: itemID, delta: text)
    }

    private func reviewWorkerInputs(for attempt: BackendReviewAttempt) async -> ReviewWorkerInputs {
        let networkMonitor = self.networkMonitor
        let policy = self.networkRecoveryPolicy
        let snapshots = networkMonitor.snapshots()
        let tracker = ReviewNetworkStatusTracker()
        let queue = ReviewWorkerInputQueue()
        let signalCoordinator = ReviewNetworkSignalCoordinator(
            policy: policy,
            tracker: tracker,
            queue: queue
        )
        let eventSource = ReviewWorkerEventSource(queue: queue)
        let networkTask = Task {
            for await snapshot in snapshots {
                await signalCoordinator.observe(snapshot)
            }
        }
        let initialEventSubscriptionID = await eventSource.subscribe(to: attempt)
        return .init(
            queue: queue,
            networkStatusTracker: tracker,
            eventSource: eventSource,
            initialEventSubscriptionID: initialEventSubscriptionID,
            networkTask: networkTask,
            signalCoordinator: signalCoordinator
        )
    }

    package func readReview(runID: String) throws -> CodexReviewAPI.Read.Result {
        try readReview(sessionID: nil, runID: runID)
    }

    package func readReview(
        sessionID: String?,
        runID: String
    ) throws -> CodexReviewAPI.Read.Result {
        let runRecord = try requireReviewRun(runID: runID)
        if let sessionID, runRecord.sessionID != sessionID {
            throw CodexReviewAPI.Error.runNotFound("Run \(runID) was not found.")
        }
        return CodexReviewAPI.Read.Result(
            runID: runRecord.id,
            core: runRecord.core,
            elapsedSeconds: elapsedSeconds(for: runRecord),
            cancellable: runRecord.isTerminal == false && runRecord.cancellationRequested == false
        )
    }

    package func listReviews(
        cwd: String? = nil,
        statuses: [ReviewRunState]? = nil,
        limit: Int? = nil
    ) -> CodexReviewAPI.List.Result {
        let filtered = filteredReviewRuns(cwd: cwd, statuses: statuses)
        let clampedLimit = min(max(limit ?? 20, 1), 100)
        return CodexReviewAPI.List.Result(items: Array(filtered.prefix(clampedLimit)).map(makeListItem))
    }

    package func listReviews(
        sessionID: String?,
        cwd: String? = nil,
        statuses: [ReviewRunState]? = nil,
        limit: Int? = nil
    ) -> CodexReviewAPI.List.Result {
        let statusSet = statuses.map(Set.init)
        let filtered = orderedReviewRuns.filter { runRecord in
            if let sessionID, runRecord.sessionID != sessionID {
                return false
            }
            if let cwd, runRecord.cwd != cwd {
                return false
            }
            if let statusSet, statusSet.contains(runRecord.core.lifecycle.status) == false {
                return false
            }
            return true
        }
        let clampedLimit = min(max(limit ?? 20, 1), 100)
        return CodexReviewAPI.List.Result(items: Array(filtered.prefix(clampedLimit)).map(makeListItem))
    }

    package func resolveRun(selector: CodexReviewAPI.Run.Selector) throws -> ReviewRunRecord {
        try resolveRun(sessionID: nil, selector: selector)
    }

    package func resolveRun(sessionID: String?, selector: CodexReviewAPI.Run.Selector) throws -> ReviewRunRecord {
        let statusSet = selector.statuses.map(Set.init)
        let matches = orderedReviewRuns.filter { runRecord in
            if let sessionID, runRecord.sessionID != sessionID {
                return false
            }
            if let cwd = selector.cwd, runRecord.cwd != cwd {
                return false
            }
            if let statusSet, statusSet.contains(runRecord.core.lifecycle.status) == false {
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
        runID: String,
        sessionID: String,
        cancellation: ReviewCancellation = .system()
    ) async throws -> CodexReviewAPI.Cancel.Outcome {
        guard let runRecord = reviewRun(id: runID), runRecord.sessionID == sessionID else {
            throw CodexReviewAPI.Error.runNotFound("Run \(runID) was not found.")
        }
        return try await cancelReview(runID: runID, cancellation: cancellation)
    }

    @discardableResult
    package func cancelReview(
        runID: String,
        cancellation: ReviewCancellation = .system()
    ) async throws -> CodexReviewAPI.Cancel.Outcome {
        let runRecord = try requireReviewRun(runID: runID)
        guard runRecord.isTerminal == false else {
            return .init(runID: runRecord.id, cancelled: false, core: runRecord.core)
        }

        runRecord.cancellationRequested = true
        runRecord.core.lifecycle.cancellation = cancellation
        runRecord.core.output.summary = cancellation.message
        runRecord.core.lifecycle.errorMessage = cancellation.message

        if runRecord.core.lifecycle.status == .queued {
            try completeCancellationLocally(
                runID: runRecord.id,
                sessionID: runRecord.sessionID,
                cancellation: cancellation
            )
            return .init(runID: runRecord.id, cancelled: true, core: runRecord.core)
        }

        if runtimeState.isWaitingForNetworkRecovery(runID) {
            try completeCancellationLocally(
                runID: runRecord.id,
                sessionID: runRecord.sessionID,
                cancellation: cancellation
            )
            runtimeState.cancelActiveWorker(for: runID)
            return .init(runID: runRecord.id, cancelled: true, core: runRecord.core)
        }

        if let run = runtimeState.activeRun(for: runID) {
            do {
                try await backend.interruptReview(
                    run,
                    reason: .init(message: cancellation.message)
                )
                try completeCancellationLocally(
                    runID: runRecord.id,
                    sessionID: runRecord.sessionID,
                    cancellation: cancellation
                )
                runtimeState.cancelActiveWorker(for: runID)
            } catch {
                try recordCancellationFailure(
                    runID: runRecord.id,
                    sessionID: runRecord.sessionID,
                    message: error.localizedDescription
                )
                throw error
            }
        } else if let run = runRecord.backendRun {
            do {
                try await backend.interruptReview(
                    run,
                    reason: .init(message: cancellation.message)
                )
                try completeCancellationLocally(
                    runID: runRecord.id,
                    sessionID: runRecord.sessionID,
                    cancellation: cancellation
                )
                runtimeState.cancelActiveWorker(for: runID)
            } catch {
                try recordCancellationFailure(
                    runID: runRecord.id,
                    sessionID: runRecord.sessionID,
                    message: error.localizedDescription
                )
                throw error
            }
        } else if runtimeState.isStarting(runID) {
            runtimeState.setStartupCancellation(cancellation, for: runID)
            try completeCancellationLocally(
                runID: runRecord.id,
                sessionID: runRecord.sessionID,
                cancellation: cancellation
            )
            return .init(runID: runRecord.id, cancelled: true, core: runRecord.core)
        } else {
            try completeCancellationLocally(
                runID: runRecord.id,
                sessionID: runRecord.sessionID,
                cancellation: cancellation
            )
        }
        return .init(runID: runRecord.id, cancelled: true, core: runRecord.core)
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
    ) async {
        closedSessions.insert(sessionID)
        for runID in activeReviewRunIDs(for: sessionID) {
            _ = try? await cancelReview(runID: runID, cancellation: reason)
        }
    }

    package func closeActiveReviewSessions(reason: ReviewCancellation) async {
        let runIDs =
            orderedReviewRuns
            .filter { $0.isTerminal == false }
            .map(\.id)
        for runID in runIDs {
            _ = try? await cancelReview(runID: runID, cancellation: reason)
        }
    }

    private func requireReviewRun(runID: String) throws -> ReviewRunRecord {
        guard let runRecord = reviewRun(id: runID) else {
            throw CodexReviewAPI.Error.runNotFound("Run \(runID) was not found.")
        }
        return runRecord
    }

    private func filteredReviewRuns(cwd: String?, statuses: [ReviewRunState]?) -> [ReviewRunRecord] {
        let statusSet = statuses.map(Set.init)
        return orderedReviewRuns.filter { runRecord in
            if let cwd, runRecord.cwd != cwd {
                return false
            }
            if let statusSet, statusSet.contains(runRecord.core.lifecycle.status) == false {
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
            elapsedSeconds: elapsedSeconds(for: runRecord),
            cancellable: runRecord.isTerminal == false && runRecord.cancellationRequested == false
        )
    }

    private func elapsedSeconds(for runRecord: ReviewRunRecord) -> Int? {
        guard let startedAt = runRecord.core.lifecycle.startedAt else {
            return nil
        }
        let end = runRecord.core.lifecycle.endedAt ?? clock.now()
        return max(0, Int(end.timeIntervalSince(startedAt)))
    }

    private func insertReviewRun(_ runRecord: ReviewRunRecord) {
        reviewRuns.insert(runRecord)
        writeDiagnosticsIfNeeded()
    }

    private func markReviewRunning(_ runRecord: ReviewRunRecord, startedAt: Date) {
        runRecord.core.lifecycle.status = .running
        runRecord.core.lifecycle.startedAt = startedAt
        runRecord.core.output.summary = "Review started."
        writeDiagnosticsIfNeeded()
    }

    private func markReviewFailed(_ runRecord: ReviewRunRecord, message: String) {
        guard runRecord.isTerminal == false else {
            return
        }
        let endedAt = clock.now()
        runRecord.core.lifecycle.status = .failed
        runRecord.core.lifecycle.endedAt = endedAt
        runRecord.core.lifecycle.errorMessage = message
        runRecord.core.output.summary = message
        writeDiagnosticsIfNeeded()
    }

    private func consumeReviewEvents(
        for initialAttempt: BackendReviewAttempt,
        runRecord: ReviewRunRecord,
        startRequest: CodexReviewBackendModel.Review.Start
    ) async throws -> CodexReviewBackendModel.Review.Run {
        let inputs = await reviewWorkerInputs(for: initialAttempt)
        defer {
            inputs.cancel()
        }
        var recoveryState = ReviewNetworkRecoveryLoopState(currentRun: initialAttempt.run)
        var activeEventSubscriptionID: Int? = inputs.initialEventSubscriptionID
        while let input = await inputs.next() {
            if runRecord.isTerminal {
                return recoveryState.currentRun
            }
            switch input {
            case .reviewEvent(let event):
                guard activeEventSubscriptionID == event.subscriptionID,
                    recoveryState.shouldConsumeEvent(from: event.subscriptionRun)
                else {
                    continue
                }
                recoveryState.currentRun = handleReviewEvent(
                    event.event,
                    runRecord: runRecord,
                    currentRun: recoveryState.currentRun
                )
                if runRecord.isTerminal {
                    return recoveryState.currentRun
                }
            case .reviewEventsFinished(let finishedRun):
                guard activeEventSubscriptionID == finishedRun.subscriptionID else {
                    continue
                }
                if recoveryState.shouldIgnoreFinishedEvent(for: finishedRun.run) {
                    continue
                }
                if try handleReviewEventsFinished(
                    runRecord: runRecord,
                    isWaitingForNetworkRecovery: recoveryState.isWaitingForNetworkRecovery
                ) {
                    return recoveryState.currentRun
                }
            case .reviewEventsFailed(let failedRun):
                guard activeEventSubscriptionID == failedRun.subscriptionID,
                    recoveryState.shouldConsumeEvent(from: failedRun.run)
                else {
                    continue
                }
                if failedRun.failure.isCancellation {
                    throw CancellationError()
                }
                if await inputs.networkStatusTracker.currentStatus() != .satisfied {
                    recoveryState.recordPendingOutageStreamFailure(failedRun.failure)
                    activeEventSubscriptionID = nil
                    await inputs.cancelActiveEventSubscription()
                    continue
                }
                try throwReviewEventStreamFailure(failedRun.failure)
            case .networkSnapshot(let snapshot, let recoveryGeneration):
                if let pendingFailure = recoveryState.takePendingOutageStreamFailureAfterTransientRecovery(
                    snapshot
                ) {
                    try throwReviewEventStreamFailure(pendingFailure)
                }
                switch recoveryState.networkSnapshotEffect(snapshot, recoveryGeneration: recoveryGeneration) {
                case .none:
                    continue
                case .restartSettling:
                    appendRecoveryProgress(networkRecoveryRestoredMessage, to: runRecord)
                }
            case .networkRecoverySettled(let recoveryGeneration):
                guard
                    recoveryState.shouldRestartReviewAfterRecoverySettle(
                        recoveryGeneration: recoveryGeneration
                    )
                else {
                    continue
                }
                switch try await restartReviewAfterNetworkRestore(
                    runRecord: runRecord,
                    startRequest: startRequest,
                    inputs: inputs,
                    preparedRestartToken: recoveryState.preparedRestartToken
                ) {
                case .continueWaiting:
                    recoveryState.markWaitingForNetworkRecovery()
                    continue
                case .finished:
                    runtimeState.clearWaitingForNetworkRecovery(runRecord.id)
                    return recoveryState.currentRun
                case .recovered(let recoveredAttempt):
                    let recoveredRun = recoveredAttempt.run
                    applyBackendRun(recoveredRun, to: runRecord)
                    recoveryState.markRecovered(with: recoveredRun)
                    runtimeState.clearWaitingForNetworkRecovery(runRecord.id)
                    activeEventSubscriptionID = await inputs.subscribe(to: recoveredAttempt)
                }
            case .networkOutageConfirmed:
                guard recoveryState.isWaitingForNetworkRecovery == false,
                    runRecord.isTerminal == false,
                    runRecord.cancellationRequested == false,
                    await inputs.networkStatusTracker.currentStatus() != .satisfied
                else {
                    continue
                }
                recoveryState.markWaitingForNetworkRecovery()
                markReviewWaitingForNetworkRecovery(runRecord)
                runtimeState.markWaitingForNetworkRecovery(runRecord.id)
                activeEventSubscriptionID = nil
                await inputs.cancelActiveEventSubscription()
                let restartToken = try await backend.prepareReviewRestart(recoveryState.currentRun)
                recoveryState.markPreparedRestartToken(restartToken)
            }
        }

        if Task.isCancelled {
            throw CancellationError()
        }
        if runRecord.isTerminal == false {
            if completePendingCancellationIfNeeded(for: runRecord) {
                return recoveryState.currentRun
            }
            completeReview(
                runRecord,
                summary: runRecord.core.output.summary,
                result: runRecord.latestBufferedAgentMessage
            )
        }
        return recoveryState.currentRun
    }

    private func handleReviewEventsFinished(
        runRecord: ReviewRunRecord,
        isWaitingForNetworkRecovery: Bool
    ) throws -> Bool {
        if Task.isCancelled {
            throw CancellationError()
        }

        if isWaitingForNetworkRecovery {
            return runRecord.isTerminal || completePendingCancellationIfNeeded(for: runRecord)
        }

        if runRecord.isTerminal == false {
            if completePendingCancellationIfNeeded(for: runRecord) {
                return true
            }
            completeReview(
                runRecord,
                summary: runRecord.core.output.summary,
                result: runRecord.latestBufferedAgentMessage
            )
        }
        return true
    }

    private func throwReviewEventStreamFailure(_ failure: ReviewWorkerEventStreamFailure) throws -> Never {
        switch failure {
        case .cancelled:
            throw CancellationError()
        case .failed(let message):
            throw ReviewWorkerInputQueueError(message: message)
        }
    }

    private func restartReviewAfterNetworkRestore(
        runRecord: ReviewRunRecord,
        startRequest: CodexReviewBackendModel.Review.Start,
        inputs: ReviewWorkerInputs,
        preparedRestartToken: CodexReviewBackendModel.Review.RestartToken?
    ) async throws -> NetworkRestoreRestartResult {
        if runRecord.isTerminal || completePendingCancellationIfNeeded(for: runRecord) {
            return .finished
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        if runRecord.isTerminal || completePendingCancellationIfNeeded(for: runRecord) {
            return .finished
        }
        guard await inputs.networkStatusTracker.currentStatus() == .satisfied else {
            return .continueWaiting
        }
        guard let preparedRestartToken else {
            return .continueWaiting
        }
        let recoveredAttempt = try await backend.restartPreparedReview(
            preparedRestartToken,
            request: startRequest
        )
        let recoveredRun = recoveredAttempt.run
        if try await stopRecoveredRunIfReviewShouldNotResume(recoveredRun, runRecord: runRecord) {
            return .finished
        }
        return .recovered(recoveredAttempt)
    }

    private func stopRecoveredRunIfReviewShouldNotResume(
        _ recoveredRun: CodexReviewBackendModel.Review.Run,
        runRecord: ReviewRunRecord
    ) async throws -> Bool {
        if Task.isCancelled {
            try? await backend.interruptReview(
                recoveredRun,
                reason: .init(message: runRecord.core.lifecycle.cancellation?.message ?? "Cancellation requested.")
            )
            await backend.cleanupReview(recoveredRun)
            throw CancellationError()
        }

        if runRecord.isTerminal {
            if runRecord.core.lifecycle.status == .cancelled {
                try? await backend.interruptReview(
                    recoveredRun,
                    reason: .init(message: runRecord.core.lifecycle.cancellation?.message ?? "Cancellation requested.")
                )
            }
            await backend.cleanupReview(recoveredRun)
            return true
        }

        guard runRecord.cancellationRequested else {
            return false
        }

        let cancellation = runRecord.core.lifecycle.cancellation ?? .system()
        do {
            try await backend.interruptReview(recoveredRun, reason: .init(message: cancellation.message))
            try completeCancellationLocally(
                runID: runRecord.id,
                sessionID: runRecord.sessionID,
                cancellation: cancellation
            )
        } catch {
            await backend.cleanupReview(recoveredRun)
            try? recordCancellationFailure(
                runID: runRecord.id,
                sessionID: runRecord.sessionID,
                message: error.localizedDescription
            )
            throw error
        }
        await backend.cleanupReview(recoveredRun)
        return true
    }

    private func handleReviewEvent(
        _ event: CodexReviewBackendModel.Review.Event,
        runRecord: ReviewRunRecord,
        currentRun: CodexReviewBackendModel.Review.Run
    ) -> CodexReviewBackendModel.Review.Run {
        guard runRecord.isTerminal == false else {
            return currentRun
        }
        if event.completesReviewRun, completePendingCancellationIfNeeded(for: runRecord) {
            writeDiagnosticsIfNeeded()
            return currentRun
        }
        var updatedRun = currentRun
        switch event {
        case .started(let turnID, let reviewThreadID, let model):
            runRecord.core.run.turnID = turnID
            runRecord.core.run.reviewThreadID = reviewThreadID ?? runRecord.core.run.reviewThreadID
            runRecord.core.run.model = model ?? runRecord.core.run.model
            updatedRun.turnID = turnID
            updatedRun.reviewThreadID = reviewThreadID ?? updatedRun.reviewThreadID
            updatedRun.model = model ?? updatedRun.model
            runtimeState.setActiveRun(updatedRun, for: runRecord.id)
            runRecord.core.output.summary = "Review started."
        case .message(let text):
            let now = clock.now()
            applyMessageSnapshot(text, itemID: nil, isCompleted: true, to: runRecord, at: now)
        case .messageDelta(let text, let itemID):
            applyMessageDelta(text, itemID: itemID, to: runRecord, at: clock.now())
        case .log(let text):
            if runRecord.core.output.summary.isEmpty || runRecord.core.output.summary == "Review started." {
                runRecord.core.output.summary = text
            }
        case .completed(let summary, let result):
            completeReview(runRecord, summary: summary, result: result)
        case .failed(let message):
            markReviewFailed(runRecord, message: message)
        case .cancelled(let message):
            let cancellation = runRecord.core.lifecycle.cancellation ?? .system(message: message)
            try? completeCancellationLocally(
                runID: runRecord.id,
                sessionID: runRecord.sessionID,
                cancellation: cancellation
            )
        }
        writeDiagnosticsIfNeeded()
        return updatedRun
    }

    private func completePendingCancellationIfNeeded(for runRecord: ReviewRunRecord) -> Bool {
        guard runRecord.cancellationRequested else {
            return false
        }
        let cancellation = runRecord.core.lifecycle.cancellation ?? .system()
        try? completeCancellationLocally(
            runID: runRecord.id,
            sessionID: runRecord.sessionID,
            cancellation: cancellation
        )
        return true
    }

    private func completeReview(
        _ runRecord: ReviewRunRecord,
        summary: String,
        result: String?
    ) {
        guard runRecord.isTerminal == false else {
            return
        }
        let endedAt = clock.now()
        let previousAgentMessage = runRecord.latestBufferedAgentMessage
        let resultText = result?.nilIfEmpty
        let finalReviewText = resultText ?? previousAgentMessage
        runRecord.core.lifecycle.status = .succeeded
        runRecord.core.lifecycle.endedAt = endedAt
        runRecord.core.output.summary = summary
        runRecord.core.output.lastAgentMessage = finalReviewText ?? summary
        if let result = resultText,
            result != previousAgentMessage
        {
            runRecord.noteAgentMessageSnapshot(
                itemID: runRecord.nextSyntheticMessageItemID(prefix: "message"),
                text: result,
                isCompleted: true
            )
        }
        writeDiagnosticsIfNeeded()
    }

    private func waitForReviewTerminal(runID: String, timeout: Duration?) async {
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

private extension CodexReviewBackendModel.Review.Event {
    var completesReviewRun: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .started,
            .message,
            .messageDelta,
            .log:
            false
        }
    }
}

private extension ReviewRunRecord {
    var backendRun: CodexReviewBackendModel.Review.Run? {
        guard let threadID = core.run.threadID else {
            return nil
        }
        return .init(
            attemptID: core.run.attemptID ?? "attempt-1",
            threadID: threadID,
            turnID: core.run.turnID,
            reviewThreadID: core.run.reviewThreadID,
            model: core.run.model
        )
    }

    var latestBufferedAgentMessage: String? {
        guard let latestAgentMessageItemID,
            let latestMessage = agentMessagesByItemID[latestAgentMessageItemID]?.nilIfEmpty
        else {
            return nil
        }
        return latestMessage
    }

    func appendAgentMessageDelta(itemID: String, delta: String) -> String? {
        guard completedAgentMessageItemIDs.contains(itemID) == false else {
            return nil
        }
        let updated = (agentMessagesByItemID[itemID] ?? "") + delta
        agentMessagesByItemID[itemID] = updated
        latestAgentMessageItemID = itemID
        return updated
    }

    func noteAgentMessageSnapshot(itemID: String, text: String, isCompleted: Bool) {
        agentMessagesByItemID[itemID] = text
        latestAgentMessageItemID = itemID
        if isCompleted {
            completedAgentMessageItemIDs.insert(itemID)
        } else {
            completedAgentMessageItemIDs.remove(itemID)
        }
    }

    func resetReviewAttemptOutputForRecovery() {
        core.output.lastAgentMessage = nil
        agentMessagesByItemID.removeAll(keepingCapacity: true)
        latestAgentMessageItemID = nil
        completedAgentMessageItemIDs.removeAll(keepingCapacity: true)
    }
}

private struct ReviewWorkerReviewEvent: Sendable {
    var subscriptionID: Int
    var subscriptionRun: CodexReviewBackendModel.Review.Run
    var event: CodexReviewBackendModel.Review.Event
}

private struct ReviewWorkerEventStreamFinished: Sendable {
    var subscriptionID: Int
    var run: CodexReviewBackendModel.Review.Run
}

private struct ReviewWorkerEventStreamFailed: Sendable {
    var subscriptionID: Int
    var run: CodexReviewBackendModel.Review.Run
    var failure: ReviewWorkerEventStreamFailure
}

private enum ReviewWorkerEventStreamFailure: Sendable {
    case cancelled
    case failed(String)

    var isCancellation: Bool {
        switch self {
        case .cancelled:
            true
        case .failed:
            false
        }
    }
}

private enum ReviewWorkerInput: Sendable {
    case reviewEvent(ReviewWorkerReviewEvent)
    case reviewEventsFinished(ReviewWorkerEventStreamFinished)
    case reviewEventsFailed(ReviewWorkerEventStreamFailed)
    case networkSnapshot(CodexReviewNetworkSnapshot, recoveryGeneration: Int)
    case networkOutageConfirmed
    case networkRecoverySettled(recoveryGeneration: Int)
}

private enum NetworkRestoreRestartResult {
    case continueWaiting
    case finished
    case recovered(BackendReviewAttempt)
}

private enum ReviewNetworkSnapshotEffect {
    case none
    case restartSettling
}

private struct ReviewNetworkRecoveryLoopState {
    var currentRun: CodexReviewBackendModel.Review.Run
    private(set) var isWaitingForNetworkRecovery = false
    private(set) var preparedRestartToken: CodexReviewBackendModel.Review.RestartToken?
    private var isSettlingForNetworkRecovery = false
    private var recoverySettleGeneration: Int?
    private var pendingOutageStreamFailure: ReviewWorkerEventStreamFailure?
    init(currentRun: CodexReviewBackendModel.Review.Run) {
        self.currentRun = currentRun
    }

    mutating func markWaitingForNetworkRecovery() {
        isWaitingForNetworkRecovery = true
        isSettlingForNetworkRecovery = false
        recoverySettleGeneration = nil
        pendingOutageStreamFailure = nil
    }

    mutating func markPreparedRestartToken(_ token: CodexReviewBackendModel.Review.RestartToken) {
        preparedRestartToken = token
    }

    mutating func markRecovered(with run: CodexReviewBackendModel.Review.Run) {
        currentRun = run
        isWaitingForNetworkRecovery = false
        preparedRestartToken = nil
        isSettlingForNetworkRecovery = false
        recoverySettleGeneration = nil
        pendingOutageStreamFailure = nil
    }

    mutating func recordPendingOutageStreamFailure(_ failure: ReviewWorkerEventStreamFailure) {
        pendingOutageStreamFailure = failure
    }

    mutating func takePendingOutageStreamFailureAfterTransientRecovery(
        _ snapshot: CodexReviewNetworkSnapshot
    ) -> ReviewWorkerEventStreamFailure? {
        guard snapshot.status == .satisfied,
            isWaitingForNetworkRecovery == false
        else {
            return nil
        }
        defer {
            pendingOutageStreamFailure = nil
        }
        return pendingOutageStreamFailure
    }

    func shouldIgnoreFinishedEvent(for run: CodexReviewBackendModel.Review.Run) -> Bool {
        isWaitingForNetworkRecovery || run.attemptID != currentRun.attemptID
    }

    func shouldRestartReviewAfterRecoverySettle(recoveryGeneration: Int) -> Bool {
        isWaitingForNetworkRecovery
            && isSettlingForNetworkRecovery
            && recoverySettleGeneration == recoveryGeneration
            && preparedRestartToken != nil
    }

    func shouldConsumeEvent(from run: CodexReviewBackendModel.Review.Run) -> Bool {
        isWaitingForNetworkRecovery == false && run.attemptID == currentRun.attemptID
    }

    mutating func networkSnapshotEffect(
        _ snapshot: CodexReviewNetworkSnapshot,
        recoveryGeneration: Int
    ) -> ReviewNetworkSnapshotEffect {
        guard isWaitingForNetworkRecovery else {
            return .none
        }
        guard snapshot.status == .satisfied else {
            isSettlingForNetworkRecovery = false
            recoverySettleGeneration = nil
            return .none
        }
        guard isSettlingForNetworkRecovery == false else {
            recoverySettleGeneration = recoveryGeneration
            return .none
        }
        isSettlingForNetworkRecovery = true
        recoverySettleGeneration = recoveryGeneration
        return .restartSettling
    }
}

private struct ReviewWorkerInputs {
    var queue: ReviewWorkerInputQueue
    var networkStatusTracker: ReviewNetworkStatusTracker
    var eventSource: ReviewWorkerEventSource
    var initialEventSubscriptionID: Int
    var networkTask: Task<Void, Never>
    var signalCoordinator: ReviewNetworkSignalCoordinator

    func next() async -> ReviewWorkerInput? {
        await queue.next()
    }

    func subscribe(to attempt: BackendReviewAttempt) async -> Int {
        await eventSource.subscribe(to: attempt)
    }

    func cancelActiveEventSubscription() async {
        await eventSource.cancelActiveSubscription()
    }

    func cancel() {
        networkTask.cancel()
        Task {
            await eventSource.cancel()
            await signalCoordinator.cancel()
            await queue.finish()
        }
    }
}

private actor ReviewWorkerInputQueue {
    private enum Delivery {
        case input(ReviewWorkerInput)
        case finished
    }

    private var bufferedInputs: [ReviewWorkerInput] = []
    private var isFinished = false
    private var waiters: [UUID: CheckedContinuation<Delivery, Never>] = [:]

    func next() async -> ReviewWorkerInput? {
        switch await nextDelivery() {
        case .input(let input):
            return input
        case .finished:
            return nil
        }
    }

    func send(_ input: ReviewWorkerInput) {
        guard isFinished == false else {
            return
        }
        if let waiterID = waiters.keys.first,
            let waiter = waiters.removeValue(forKey: waiterID)
        {
            waiter.resume(returning: .input(input))
        } else {
            bufferedInputs.append(input)
        }
    }

    func finish() {
        guard isFinished == false else {
            return
        }
        isFinished = true
        resumeWaitersForFinishIfReady()
    }

    private func nextDelivery() async -> Delivery {
        if bufferedInputs.isEmpty == false {
            let input = bufferedInputs.removeFirst()
            resumeWaitersForFinishIfReady()
            return .input(input)
        }
        if isFinished {
            return .finished
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if bufferedInputs.isEmpty == false {
                    let input = bufferedInputs.removeFirst()
                    resumeWaitersForFinishIfReady()
                    continuation.resume(returning: .input(input))
                } else if isFinished {
                    continuation.resume(returning: .finished)
                } else {
                    waiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
    }

    private func cancelWaiter(id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: .finished)
    }

    private func resumeWaitersForFinishIfReady() {
        guard bufferedInputs.isEmpty, isFinished else {
            return
        }
        let waiters = Array(waiters.values)
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: .finished)
        }
    }
}

private struct ReviewWorkerInputQueueError: LocalizedError, Sendable {
    var message: String

    var errorDescription: String? {
        message
    }
}

private actor ReviewWorkerEventSource {
    private let queue: ReviewWorkerInputQueue
    private var eventTasks: [Int: Task<Void, Never>] = [:]
    private var subscriptionID = 0
    private var activeSubscriptionID: Int?

    init(queue: ReviewWorkerInputQueue) {
        self.queue = queue
    }

    func subscribe(to attempt: BackendReviewAttempt) -> Int {
        subscriptionID += 1
        let subscriptionID = subscriptionID
        activeSubscriptionID = subscriptionID
        cancelEventTasks()
        let run = attempt.run
        let events = attempt.events
        eventTasks[subscriptionID] = Task {
            do {
                while let event = try await events.next() {
                    guard Task.isCancelled == false else {
                        return
                    }
                    await self.yieldReviewEvent(event, run: run, subscriptionID: subscriptionID)
                }
                await self.yieldEventsFinished(run: run, subscriptionID: subscriptionID)
            } catch {
                await self.yieldEventsFailed(error, run: run, subscriptionID: subscriptionID)
            }
        }
        return subscriptionID
    }

    func cancelActiveSubscription() {
        subscriptionID += 1
        activeSubscriptionID = nil
        cancelEventTasks()
    }

    func cancel() {
        subscriptionID += 1
        activeSubscriptionID = nil
        cancelEventTasks()
    }

    private func cancelEventTasks() {
        for task in eventTasks.values {
            task.cancel()
        }
        eventTasks.removeAll(keepingCapacity: true)
    }

    private func yieldReviewEvent(
        _ event: CodexReviewBackendModel.Review.Event,
        run: CodexReviewBackendModel.Review.Run,
        subscriptionID: Int
    ) async {
        guard activeSubscriptionID == subscriptionID,
            eventTasks[subscriptionID] != nil
        else {
            return
        }
        await queue.send(
            .reviewEvent(
                .init(
                    subscriptionID: subscriptionID,
                    subscriptionRun: run,
                    event: event
                )))
    }

    private func yieldEventsFinished(run: CodexReviewBackendModel.Review.Run, subscriptionID: Int) async {
        guard activeSubscriptionID == subscriptionID,
            eventTasks.removeValue(forKey: subscriptionID) != nil
        else {
            return
        }
        await queue.send(
            .reviewEventsFinished(
                .init(
                    subscriptionID: subscriptionID,
                    run: run
                )))
    }

    private func yieldEventsFailed(
        _ error: any Error,
        run: CodexReviewBackendModel.Review.Run,
        subscriptionID: Int
    ) async {
        guard eventTasks.removeValue(forKey: subscriptionID) != nil else {
            return
        }
        guard activeSubscriptionID == subscriptionID else {
            return
        }
        await queue.send(
            .reviewEventsFailed(
                .init(
                    subscriptionID: subscriptionID,
                    run: run,
                    failure: error is CancellationError ? .cancelled : .failed(error.localizedDescription)
                )))
    }
}

private actor ReviewNetworkStatusTracker {
    private var latest: CodexReviewNetworkSnapshot = .satisfied()

    func update(_ snapshot: CodexReviewNetworkSnapshot) {
        latest = snapshot
    }

    func currentStatus() -> CodexReviewNetworkStatus {
        latest.status
    }

    func latestSnapshot() -> CodexReviewNetworkSnapshot {
        latest
    }
}

private actor ReviewNetworkSignalCoordinator {
    private let policy: CodexReviewNetworkRecoveryPolicy
    private let tracker: ReviewNetworkStatusTracker
    private let queue: ReviewWorkerInputQueue
    private var outageTask: Task<Void, Never>?
    private var outageGeneration = 0
    private var recoveryTask: Task<Void, Never>?
    private var recoveryGeneration = 0

    init(
        policy: CodexReviewNetworkRecoveryPolicy,
        tracker: ReviewNetworkStatusTracker,
        queue: ReviewWorkerInputQueue
    ) {
        self.policy = policy
        self.tracker = tracker
        self.queue = queue
    }

    func observe(_ snapshot: CodexReviewNetworkSnapshot) async {
        await tracker.update(snapshot)
        switch snapshot.status {
        case .satisfied:
            outageGeneration += 1
            outageTask?.cancel()
            outageTask = nil
            recoveryGeneration += 1
            let recoveryGeneration = recoveryGeneration
            recoveryTask?.cancel()
            recoveryTask = nil
            await queue.send(.networkSnapshot(snapshot, recoveryGeneration: recoveryGeneration))
            scheduleRecoveryConfirmationIfNeeded(generation: recoveryGeneration)
        case .unsatisfied, .requiresConnection:
            recoveryGeneration += 1
            let recoveryGeneration = recoveryGeneration
            recoveryTask?.cancel()
            recoveryTask = nil
            await queue.send(.networkSnapshot(snapshot, recoveryGeneration: recoveryGeneration))
            scheduleOutageConfirmationIfNeeded()
        }
    }

    func cancel() {
        outageTask?.cancel()
        outageTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    private func scheduleOutageConfirmationIfNeeded() {
        guard outageTask == nil else {
            return
        }
        let policy = policy
        outageGeneration += 1
        let generation = outageGeneration
        outageTask = Task {
            do {
                try await policy.sleep(policy.outageDebounce)
            } catch {
                return
            }
            await self.confirmOutageIfCurrent(generation: generation)
        }
    }

    private func confirmOutageIfCurrent(generation: Int) async {
        guard generation == outageGeneration else {
            return
        }
        let latest = await tracker.latestSnapshot()
        guard latest.status != .satisfied else {
            return
        }
        await queue.send(.networkOutageConfirmed)
    }

    private func scheduleRecoveryConfirmationIfNeeded(generation: Int) {
        guard recoveryTask == nil else {
            return
        }
        let policy = policy
        recoveryTask = Task {
            do {
                try await policy.sleep(policy.recoverySettle)
            } catch {
                return
            }
            await self.confirmRecoveryIfCurrent(generation: generation)
        }
    }

    private func confirmRecoveryIfCurrent(generation: Int) async {
        guard generation == recoveryGeneration else {
            return
        }
        recoveryTask = nil
        let latest = await tracker.latestSnapshot()
        guard latest.status == .satisfied else {
            return
        }
        await queue.send(.networkRecoverySettled(recoveryGeneration: generation))
    }
}
