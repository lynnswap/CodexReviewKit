import Foundation

private let networkRecoveryUnavailableMessage = "Network unavailable; waiting to reconnect."
private let networkRecoveryRestoredMessage = "Network restored; restarting review."

extension CodexReviewStore {
    package func activeJobIDs(for sessionID: String) -> [String] {
        orderedJobs
            .filter { $0.sessionID == sessionID && $0.isTerminal == false }
            .map(\.id)
    }

    @discardableResult
    package func startReview(
        sessionID: String,
        request: CodexReviewAPI.Start.Request
    ) async throws -> CodexReviewAPI.Read.Result {
        let jobID = try beginReview(sessionID: sessionID, request: request)
        return try await withTaskCancellationHandler {
            _ = try await awaitReview(sessionID: sessionID, jobID: jobID)
            await runtimeState.awaitActiveWorker(for: jobID)
            return try readReview(sessionID: sessionID, jobID: jobID)
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.runtimeState.cancelActiveWorker(for: jobID)
            }
        }
    }

    @discardableResult
    package func startReview(
        sessionID: String,
        request: CodexReviewAPI.Start.Request,
        waitTimeout: Duration
    ) async throws -> CodexReviewAPI.Read.Result {
        let jobID = try beginReview(sessionID: sessionID, request: request)
        return try await awaitReview(sessionID: sessionID, jobID: jobID, timeout: waitTimeout)
    }

    package func awaitReview(
        sessionID: String?,
        jobID: String,
        timeout: Duration? = nil
    ) async throws -> CodexReviewAPI.Read.Result {
        let job = try job(jobID: jobID)
        if let sessionID, job.sessionID != sessionID {
            throw CodexReviewAPI.Error.jobNotFound("Job \(jobID) was not found.")
        }
        if job.isTerminal == false {
            await waitForReviewTerminal(jobID: jobID, timeout: timeout)
        }
        return try readReview(sessionID: sessionID, jobID: jobID)
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
        let jobID = idGenerator.next()
        let createdAt = clock.now()
        let job = CodexReviewJob(
            id: jobID,
            sessionID: sessionID,
            cwd: validatedRequest.cwd,
            sortOrder: nextJobSortOrder(inWorkspace: validatedRequest.cwd),
            targetSummary: validatedRequest.target.displaySummary,
            core: .init(
                lifecycle: .init(status: .queued),
                output: .init(summary: "Queued.")
            )
        )
        insertReviewJob(job)
        markReviewRunning(job, startedAt: createdAt)
        runtimeState.markStarting(jobID)
        launchReviewWorker(jobID: jobID, sessionID: sessionID, request: validatedRequest)
        return jobID
    }

    private func launchReviewWorker(
        jobID: String,
        sessionID: String,
        request: CodexReviewAPI.Start.Request
    ) {
        runtimeState.cancelActiveWorker(for: jobID)
        runtimeState.setActiveWorker(
            Task { [weak self] in
                await self?.runReviewWorker(jobID: jobID, sessionID: sessionID, request: request)
            }, for: jobID)
    }

    private func runReviewWorker(
        jobID: String,
        sessionID: String,
        request validatedRequest: CodexReviewAPI.Start.Request
    ) async {
        guard let job = job(id: jobID) else {
            runtimeState.clearStarting(jobID)
            runtimeState.removeActiveWorker(for: jobID)
            return
        }
        let startRequest = CodexReviewBackendModel.Review.Start(
            jobID: jobID,
            sessionID: sessionID,
            request: validatedRequest,
            model: settings.effectiveModel
        )
        var run: CodexReviewBackendModel.Review.Run?
        do {
            let backendAttempt = try await backend.startReview(startRequest)
            let backendRun = backendAttempt.run
            runtimeState.clearStarting(jobID)
            run = backendRun
            if Task.isCancelled {
                throw CancellationError()
            }
            applyBackendRun(backendRun, to: job)
            if let startupCancellation = runtimeState.takeStartupCancellation(for: jobID) {
                try? await backend.interruptReview(
                    backendRun,
                    reason: .init(message: startupCancellation.message)
                )
                if job.isTerminal == false {
                    try completeCancellationLocally(
                        jobID: job.id,
                        sessionID: job.sessionID,
                        cancellation: startupCancellation
                    )
                }
            } else if job.cancellationRequested {
                try await backend.interruptReview(
                    backendRun,
                    reason: .init(message: job.core.lifecycle.cancellation?.message ?? "Cancellation requested.")
                )
                try completeCancellationLocally(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    cancellation: job.core.lifecycle.cancellation ?? .system()
                )
            }

            if job.isTerminal {
                await backend.cleanupReview(backendRun)
                runtimeState.clearReviewRunState(for: jobID)
            } else {
                let currentRun = try await consumeReviewEvents(
                    for: backendAttempt,
                    job: job,
                    startRequest: startRequest
                )
                run = currentRun
                await backend.cleanupReview(currentRun)
                runtimeState.clearReviewRunState(for: jobID)
            }
        } catch let error where error is CancellationError || Task.isCancelled {
            runtimeState.clearStarting(jobID)
            let startupCancellation = runtimeState.takeStartupCancellation(for: jobID)
            if let cleanupRun = runtimeState.activeRun(for: jobID) ?? run {
                await interruptReviewAfterTaskCancellation(cleanupRun, job: job)
                await backend.cleanupReview(cleanupRun)
            } else if job.isTerminal == false || startupCancellation != nil {
                try? completeCancellationLocally(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    cancellation: startupCancellation ?? job.core.lifecycle.cancellation ?? .system()
                )
            }
            runtimeState.clearReviewRunState(for: jobID)
        } catch {
            runtimeState.clearStarting(jobID)
            let startupCancellation = runtimeState.takeStartupCancellation(for: jobID)
            if let cleanupRun = runtimeState.activeRun(for: jobID) ?? run {
                await backend.cleanupReview(cleanupRun)
            }
            runtimeState.clearReviewRunState(for: jobID)
            if job.isTerminal == false, let startupCancellation {
                try? completeCancellationLocally(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    cancellation: startupCancellation
                )
            } else if job.isTerminal == false {
                markReviewFailed(job, message: error.localizedDescription)
            }
        }
        runtimeState.removeActiveWorker(for: jobID)
        runtimeState.removeDetachedWorker(for: jobID)
    }

    private func interruptReviewAfterTaskCancellation(_ run: CodexReviewBackendModel.Review.Run, job: CodexReviewJob)
        async
    {
        guard job.isTerminal == false else {
            return
        }
        let cancellation = job.core.lifecycle.cancellation ?? .system()
        job.cancellationRequested = true
        job.core.lifecycle.cancellation = cancellation
        job.core.output.summary = cancellation.message
        job.core.lifecycle.errorMessage = cancellation.message
        do {
            try await backend.interruptReview(
                run,
                reason: .init(message: cancellation.message)
            )
            try completeCancellationLocally(
                jobID: job.id,
                sessionID: job.sessionID,
                cancellation: cancellation
            )
        } catch {
            try? recordCancellationFailure(
                jobID: job.id,
                sessionID: job.sessionID,
                message: error.localizedDescription
            )
        }
    }

    private func applyBackendRun(_ backendRun: CodexReviewBackendModel.Review.Run, to job: CodexReviewJob) {
        runtimeState.setActiveRun(backendRun, for: job.id)
        job.core.run = .init(
            attemptID: backendRun.attemptID,
            reviewThreadID: backendRun.reviewThreadID,
            threadID: backendRun.threadID,
            turnID: backendRun.turnID,
            model: backendRun.model
        )
        writeDiagnosticsIfNeeded()
    }

    private func appendRecoveryProgress(_ message: String, to job: CodexReviewJob) {
        let now = clock.now()
        job.core.output.summary = message
        appendDiagnostic(message, to: job, at: now)
        writeDiagnosticsIfNeeded()
    }

    private func markReviewWaitingForNetworkRecovery(_ job: CodexReviewJob) {
        job.resetReviewAttemptOutputForRecovery()
        appendRecoveryProgress(networkRecoveryUnavailableMessage, to: job)
    }

    private func applyDomainEvents(
        _ events: [ReviewDomainEvent],
        to job: CodexReviewJob,
        at timestamp: Date
    ) {
        for event in events {
            guard shouldApplyDomainEvent(event, to: job) else {
                continue
            }
            updateCoreOutput(from: event, for: job)
            job.timeline.apply(event, at: timestamp)
        }
    }

    private func shouldApplyDomainEvent(_ event: ReviewDomainEvent, to job: CodexReviewJob) -> Bool {
        switch event {
        case .textDelta(let itemID, _, let family, _, _)
        where family == .message && job.completedAgentMessageItemIDs.contains(itemID.rawValue):
            false
        default:
            true
        }
    }

    private func updateCoreOutput(from event: ReviewDomainEvent, for job: CodexReviewJob) {
        switch event {
        case .itemStarted(let seed),
            .itemUpdated(let seed):
            updateCoreOutput(from: seed, isCompleted: false, for: job)
        case .itemCompleted(let seed):
            updateCoreOutput(from: seed, isCompleted: true, for: job)
        case .textDelta(let itemID, _, let family, _, let delta) where family == .message:
            guard let updatedMessage = job.appendAgentMessageDelta(itemID: itemID.rawValue, delta: delta) else {
                return
            }
            job.core.output.lastAgentMessage = updatedMessage
            job.core.output.summary = updatedMessage
        case .runStarted,
            .textDelta,
            .reviewCompleted,
            .reviewFailed,
            .reviewCancelled:
            break
        }
    }

    private func updateCoreOutput(
        from seed: ReviewTimelineItemSeed,
        isCompleted: Bool,
        for job: CodexReviewJob
    ) {
        guard seed.family == .message,
            case .message(let message) = seed.content
        else {
            return
        }
        job.noteAgentMessageSnapshot(
            itemID: seed.id.rawValue,
            text: message.text,
            isCompleted: isCompleted
        )
        guard let text = message.text.nilIfEmpty else {
            return
        }
        job.core.output.lastAgentMessage = text
        job.core.output.summary = text
    }

    private func applyMessageSnapshot(
        _ text: String,
        itemID: String?,
        isCompleted: Bool,
        to job: CodexReviewJob,
        at timestamp: Date
    ) {
        let resolvedItemID =
            itemID?.nilIfEmpty.map(ReviewTimelineItem.ID.init(rawValue:))
            ?? job.nextSyntheticTimelineItemID(prefix: "message")
        let seed = ReviewTimelineItemSeed(
            id: resolvedItemID,
            kind: .agentMessage,
            family: .message,
            phase: isCompleted ? .completed : .running,
            content: .message(.init(text: text))
        )
        job.noteAgentMessageSnapshot(
            itemID: resolvedItemID.rawValue,
            text: text,
            isCompleted: isCompleted
        )
        job.timeline.apply(isCompleted ? .itemCompleted(seed) : .itemUpdated(seed), at: timestamp)
    }

    private func applyMessageDelta(
        _ text: String,
        itemID: String,
        to job: CodexReviewJob,
        at timestamp: Date
    ) {
        guard let updatedMessage = job.appendAgentMessageDelta(itemID: itemID, delta: text) else {
            return
        }
        job.core.output.lastAgentMessage = updatedMessage
        job.core.output.summary = updatedMessage
        job.timeline.apply(
            .textDelta(
                itemID: .init(rawValue: itemID),
                kind: .agentMessage,
                family: .message,
                content: .message(.init(text: "")),
                delta: text
            ), at: timestamp)
    }

    private func appendDiagnostic(
        _ message: String,
        to job: CodexReviewJob,
        at timestamp: Date,
        severity: ReviewDiagnosticSeverity? = nil
    ) {
        guard let message = message.nilIfEmpty else {
            return
        }
        let seed = ReviewTimelineItemSeed(
            id: job.nextSyntheticTimelineItemID(prefix: "diagnostic"),
            kind: .init(rawValue: "reviewDiagnostic"),
            family: .diagnostic,
            phase: .completed,
            content: .diagnostic(.init(message: message, severity: severity))
        )
        job.timeline.apply(.itemCompleted(seed), at: timestamp)
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

    package func readReview(jobID: String) throws -> CodexReviewAPI.Read.Result {
        try readReview(sessionID: nil, jobID: jobID)
    }

    package func readReview(
        sessionID: String?,
        jobID: String
    ) throws -> CodexReviewAPI.Read.Result {
        let job = try job(jobID: jobID)
        if let sessionID, job.sessionID != sessionID {
            throw CodexReviewAPI.Error.jobNotFound("Job \(jobID) was not found.")
        }
        return CodexReviewAPI.Read.Result(
            jobID: job.id,
            core: job.core,
            elapsedSeconds: elapsedSeconds(for: job),
            cancellable: job.isTerminal == false && job.cancellationRequested == false
        )
    }

    package func listReviews(
        cwd: String? = nil,
        statuses: [ReviewJobState]? = nil,
        limit: Int? = nil
    ) -> CodexReviewAPI.List.Result {
        let filtered = filteredJobs(cwd: cwd, statuses: statuses)
        let clampedLimit = min(max(limit ?? 20, 1), 100)
        return CodexReviewAPI.List.Result(items: Array(filtered.prefix(clampedLimit)).map(makeListItem))
    }

    package func listReviews(
        sessionID: String?,
        cwd: String? = nil,
        statuses: [ReviewJobState]? = nil,
        limit: Int? = nil
    ) -> CodexReviewAPI.List.Result {
        let statusSet = statuses.map(Set.init)
        let filtered = orderedJobs.filter { job in
            if let sessionID, job.sessionID != sessionID {
                return false
            }
            if let cwd, job.cwd != cwd {
                return false
            }
            if let statusSet, statusSet.contains(job.core.lifecycle.status) == false {
                return false
            }
            return true
        }
        let clampedLimit = min(max(limit ?? 20, 1), 100)
        return CodexReviewAPI.List.Result(items: Array(filtered.prefix(clampedLimit)).map(makeListItem))
    }

    package func resolveJob(selector: CodexReviewAPI.Job.Selector) throws -> CodexReviewJob {
        try resolveJob(sessionID: nil, selector: selector)
    }

    package func resolveJob(sessionID: String?, selector: CodexReviewAPI.Job.Selector) throws -> CodexReviewJob {
        let statusSet = selector.statuses.map(Set.init)
        let matches = orderedJobs.filter { job in
            if let sessionID, job.sessionID != sessionID {
                return false
            }
            if let cwd = selector.cwd, job.cwd != cwd {
                return false
            }
            if let statusSet, statusSet.contains(job.core.lifecycle.status) == false {
                return false
            }
            if let jobID = selector.jobID, jobID != job.id {
                return false
            }
            return true
        }
        if let job = matches.first, matches.count == 1 {
            return job
        }
        if matches.isEmpty {
            throw CodexReviewAPI.Error.jobNotFound("No review job matched the selector.")
        }
        throw CodexReviewAPI.Job.SelectionError.ambiguous(matches.map(makeListItem))
    }

    package func cancelReview(
        jobID: String,
        sessionID: String,
        cancellation: ReviewCancellation = .system()
    ) async throws -> CodexReviewAPI.Cancel.Outcome {
        guard let job = job(id: jobID), job.sessionID == sessionID else {
            throw CodexReviewAPI.Error.jobNotFound("Job \(jobID) was not found.")
        }
        return try await cancelReview(jobID: jobID, cancellation: cancellation)
    }

    @discardableResult
    package func cancelReview(
        jobID: String,
        cancellation: ReviewCancellation = .system()
    ) async throws -> CodexReviewAPI.Cancel.Outcome {
        let job = try job(jobID: jobID)
        guard job.isTerminal == false else {
            return .init(jobID: job.id, cancelled: false, core: job.core)
        }

        job.cancellationRequested = true
        job.core.lifecycle.cancellation = cancellation
        job.core.output.summary = cancellation.message
        job.core.lifecycle.errorMessage = cancellation.message

        if job.core.lifecycle.status == .queued {
            try completeCancellationLocally(
                jobID: job.id,
                sessionID: job.sessionID,
                cancellation: cancellation
            )
            return .init(jobID: job.id, cancelled: true, core: job.core)
        }

        if runtimeState.isWaitingForNetworkRecovery(jobID) {
            try completeCancellationLocally(
                jobID: job.id,
                sessionID: job.sessionID,
                cancellation: cancellation
            )
            runtimeState.cancelActiveWorker(for: jobID)
            return .init(jobID: job.id, cancelled: true, core: job.core)
        }

        if let run = runtimeState.activeRun(for: jobID) {
            do {
                try await backend.interruptReview(
                    run,
                    reason: .init(message: cancellation.message)
                )
                try completeCancellationLocally(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    cancellation: cancellation
                )
                runtimeState.cancelActiveWorker(for: jobID)
            } catch {
                try recordCancellationFailure(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    message: error.localizedDescription
                )
                throw error
            }
        } else if let run = job.backendRun {
            do {
                try await backend.interruptReview(
                    run,
                    reason: .init(message: cancellation.message)
                )
                try completeCancellationLocally(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    cancellation: cancellation
                )
                runtimeState.cancelActiveWorker(for: jobID)
            } catch {
                try recordCancellationFailure(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    message: error.localizedDescription
                )
                throw error
            }
        } else if runtimeState.isStarting(jobID) {
            runtimeState.setStartupCancellation(cancellation, for: jobID)
            try completeCancellationLocally(
                jobID: job.id,
                sessionID: job.sessionID,
                cancellation: cancellation
            )
            return .init(jobID: job.id, cancelled: true, core: job.core)
        } else {
            try completeCancellationLocally(
                jobID: job.id,
                sessionID: job.sessionID,
                cancellation: cancellation
            )
        }
        return .init(jobID: job.id, cancelled: true, core: job.core)
    }

    package func closeSession(
        _ sessionID: String,
        reason: ReviewCancellation = .sessionClosed()
    ) async {
        closedSessions.insert(sessionID)
        for jobID in activeJobIDs(for: sessionID) {
            _ = try? await cancelReview(jobID: jobID, cancellation: reason)
        }
    }

    package func closeActiveReviewSessions(reason: ReviewCancellation) async {
        let jobIDs =
            orderedJobs
            .filter { $0.isTerminal == false }
            .map(\.id)
        for jobID in jobIDs {
            _ = try? await cancelReview(jobID: jobID, cancellation: reason)
        }
    }

    private func job(jobID: String) throws -> CodexReviewJob {
        guard let job = job(id: jobID) else {
            throw CodexReviewAPI.Error.jobNotFound("Job \(jobID) was not found.")
        }
        return job
    }

    private func filteredJobs(cwd: String?, statuses: [ReviewJobState]?) -> [CodexReviewJob] {
        let statusSet = statuses.map(Set.init)
        return orderedJobs.filter { job in
            if let cwd, job.cwd != cwd {
                return false
            }
            if let statusSet, statusSet.contains(job.core.lifecycle.status) == false {
                return false
            }
            return true
        }
    }

    private func makeListItem(_ job: CodexReviewJob) -> CodexReviewAPI.Job.ListItem {
        CodexReviewAPI.Job.ListItem(
            jobID: job.id,
            cwd: job.cwd,
            targetSummary: job.targetSummary,
            core: job.core,
            elapsedSeconds: elapsedSeconds(for: job),
            cancellable: job.isTerminal == false && job.cancellationRequested == false
        )
    }

    private func elapsedSeconds(for job: CodexReviewJob) -> Int? {
        guard let startedAt = job.core.lifecycle.startedAt else {
            return nil
        }
        let end = job.core.lifecycle.endedAt ?? clock.now()
        return max(0, Int(end.timeIntervalSince(startedAt)))
    }

    private func insertReviewJob(_ job: CodexReviewJob) {
        if workspace(cwd: job.cwd) == nil {
            let workspace = CodexReviewWorkspace(
                cwd: job.cwd,
                sortOrder: nextWorkspaceSortOrder()
            )
            workspaces.insert(workspace)
        }
        jobs.insert(job)
        writeDiagnosticsIfNeeded()
    }

    private func markReviewRunning(_ job: CodexReviewJob, startedAt: Date) {
        job.core.lifecycle.status = .running
        job.core.lifecycle.startedAt = startedAt
        job.core.output.summary = "Review started."
        job.timeline.apply(
            .runStarted(
                turnID: .init(rawValue: job.core.run.turnID ?? job.id),
                reviewThreadID: job.core.run.reviewThreadID.map(ReviewThread.ID.init(rawValue:)),
                model: job.core.run.model
            ), at: startedAt)
        writeDiagnosticsIfNeeded()
    }

    private func markReviewFailed(_ job: CodexReviewJob, message: String) {
        guard job.isTerminal == false else {
            return
        }
        let endedAt = clock.now()
        job.timeline.closeActiveItems(family: .command, phase: .failed, timestamp: endedAt)
        job.core.lifecycle.status = .failed
        job.core.lifecycle.endedAt = endedAt
        job.core.lifecycle.errorMessage = message
        job.core.output.summary = message
        job.timeline.apply(.reviewFailed(message), at: endedAt)
        writeDiagnosticsIfNeeded()
    }

    private func consumeReviewEvents(
        for initialAttempt: BackendReviewAttempt,
        job: CodexReviewJob,
        startRequest: CodexReviewBackendModel.Review.Start
    ) async throws -> CodexReviewBackendModel.Review.Run {
        let inputs = await reviewWorkerInputs(for: initialAttempt)
        defer {
            inputs.cancel()
        }
        var recoveryState = ReviewNetworkRecoveryLoopState(currentRun: initialAttempt.run)
        var activeEventSubscriptionID: Int? = inputs.initialEventSubscriptionID
        while let input = await inputs.next() {
            if job.isTerminal {
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
                    job: job,
                    currentRun: recoveryState.currentRun
                )
                if job.isTerminal {
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
                    job: job,
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
                    appendRecoveryProgress(networkRecoveryRestoredMessage, to: job)
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
                    job: job,
                    startRequest: startRequest,
                    inputs: inputs,
                    preparedRestartToken: recoveryState.preparedRestartToken
                ) {
                case .continueWaiting:
                    recoveryState.markWaitingForNetworkRecovery()
                    continue
                case .finished:
                    runtimeState.clearWaitingForNetworkRecovery(job.id)
                    return recoveryState.currentRun
                case .recovered(let recoveredAttempt):
                    let recoveredRun = recoveredAttempt.run
                    applyBackendRun(recoveredRun, to: job)
                    recoveryState.markRecovered(with: recoveredRun)
                    runtimeState.clearWaitingForNetworkRecovery(job.id)
                    activeEventSubscriptionID = await inputs.subscribe(to: recoveredAttempt)
                }
            case .networkOutageConfirmed:
                guard recoveryState.isWaitingForNetworkRecovery == false,
                    job.isTerminal == false,
                    job.cancellationRequested == false,
                    await inputs.networkStatusTracker.currentStatus() != .satisfied
                else {
                    continue
                }
                recoveryState.markWaitingForNetworkRecovery()
                markReviewWaitingForNetworkRecovery(job)
                runtimeState.markWaitingForNetworkRecovery(job.id)
                activeEventSubscriptionID = nil
                await inputs.cancelActiveEventSubscription()
                let restartToken = try await backend.prepareReviewRestart(recoveryState.currentRun)
                recoveryState.markPreparedRestartToken(restartToken)
            }
        }

        if Task.isCancelled {
            throw CancellationError()
        }
        if job.isTerminal == false {
            if completePendingCancellationIfNeeded(for: job) {
                return recoveryState.currentRun
            }
            completeReview(
                job,
                summary: job.core.output.summary,
                result: job.core.output.lastAgentMessage
            )
        }
        return recoveryState.currentRun
    }

    private func handleReviewEventsFinished(
        job: CodexReviewJob,
        isWaitingForNetworkRecovery: Bool
    ) throws -> Bool {
        if Task.isCancelled {
            throw CancellationError()
        }

        if isWaitingForNetworkRecovery {
            return job.isTerminal || completePendingCancellationIfNeeded(for: job)
        }

        if job.isTerminal == false {
            if completePendingCancellationIfNeeded(for: job) {
                return true
            }
            completeReview(
                job,
                summary: job.core.output.summary,
                result: job.core.output.lastAgentMessage
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
        job: CodexReviewJob,
        startRequest: CodexReviewBackendModel.Review.Start,
        inputs: ReviewWorkerInputs,
        preparedRestartToken: CodexReviewBackendModel.Review.RestartToken?
    ) async throws -> NetworkRestoreRestartResult {
        if job.isTerminal || completePendingCancellationIfNeeded(for: job) {
            return .finished
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        if job.isTerminal || completePendingCancellationIfNeeded(for: job) {
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
        if try await stopRecoveredRunIfJobShouldNotResume(recoveredRun, job: job) {
            return .finished
        }
        return .recovered(recoveredAttempt)
    }

    private func stopRecoveredRunIfJobShouldNotResume(
        _ recoveredRun: CodexReviewBackendModel.Review.Run,
        job: CodexReviewJob
    ) async throws -> Bool {
        if Task.isCancelled {
            try? await backend.interruptReview(
                recoveredRun,
                reason: .init(message: job.core.lifecycle.cancellation?.message ?? "Cancellation requested.")
            )
            await backend.cleanupReview(recoveredRun)
            throw CancellationError()
        }

        if job.isTerminal {
            if job.core.lifecycle.status == .cancelled {
                try? await backend.interruptReview(
                    recoveredRun,
                    reason: .init(message: job.core.lifecycle.cancellation?.message ?? "Cancellation requested.")
                )
            }
            await backend.cleanupReview(recoveredRun)
            return true
        }

        guard job.cancellationRequested else {
            return false
        }

        let cancellation = job.core.lifecycle.cancellation ?? .system()
        do {
            try await backend.interruptReview(recoveredRun, reason: .init(message: cancellation.message))
            try completeCancellationLocally(
                jobID: job.id,
                sessionID: job.sessionID,
                cancellation: cancellation
            )
        } catch {
            await backend.cleanupReview(recoveredRun)
            try? recordCancellationFailure(
                jobID: job.id,
                sessionID: job.sessionID,
                message: error.localizedDescription
            )
            throw error
        }
        await backend.cleanupReview(recoveredRun)
        return true
    }

    private func handleReviewEvent(
        _ event: CodexReviewBackendModel.Review.Event,
        job: CodexReviewJob,
        currentRun: CodexReviewBackendModel.Review.Run
    ) -> CodexReviewBackendModel.Review.Run {
        guard job.isTerminal == false else {
            return currentRun
        }
        if event.completesReviewRun, completePendingCancellationIfNeeded(for: job) {
            writeDiagnosticsIfNeeded()
            return currentRun
        }
        var updatedRun = currentRun
        switch event {
        case .domainEvents(let events):
            applyDomainEvents(events, to: job, at: clock.now())
        case .started(let turnID, let reviewThreadID, let model):
            job.core.run.turnID = turnID
            job.core.run.reviewThreadID = reviewThreadID ?? job.core.run.reviewThreadID
            job.core.run.model = model ?? job.core.run.model
            updatedRun.turnID = turnID
            updatedRun.reviewThreadID = reviewThreadID ?? updatedRun.reviewThreadID
            updatedRun.model = model ?? updatedRun.model
            runtimeState.setActiveRun(updatedRun, for: job.id)
            job.core.output.summary = "Review started."
            job.timeline.apply(
                .runStarted(
                    turnID: .init(rawValue: turnID),
                    reviewThreadID: (reviewThreadID ?? job.core.run.reviewThreadID).map(
                        ReviewThread.ID.init(rawValue:)),
                    model: model ?? job.core.run.model
                ), at: clock.now())
        case .message(let text):
            let now = clock.now()
            job.core.output.lastAgentMessage = text
            job.core.output.summary = text
            applyMessageSnapshot(text, itemID: nil, isCompleted: true, to: job, at: now)
        case .messageDelta(let text, let itemID):
            applyMessageDelta(text, itemID: itemID, to: job, at: clock.now())
        case .log(let text):
            appendDiagnostic(text, to: job, at: clock.now())
        case .completed(let summary, let result):
            completeReview(job, summary: summary, result: result)
        case .failed(let message):
            markReviewFailed(job, message: message)
        case .cancelled(let message):
            let cancellation = job.core.lifecycle.cancellation ?? .system(message: message)
            try? completeCancellationLocally(
                jobID: job.id,
                sessionID: job.sessionID,
                cancellation: cancellation
            )
        }
        writeDiagnosticsIfNeeded()
        return updatedRun
    }

    private func completePendingCancellationIfNeeded(for job: CodexReviewJob) -> Bool {
        guard job.cancellationRequested else {
            return false
        }
        let cancellation = job.core.lifecycle.cancellation ?? .system()
        try? completeCancellationLocally(
            jobID: job.id,
            sessionID: job.sessionID,
            cancellation: cancellation
        )
        return true
    }

    private func completeReview(
        _ job: CodexReviewJob,
        summary: String,
        result: String?
    ) {
        guard job.isTerminal == false else {
            return
        }
        let endedAt = clock.now()
        let previousAgentMessage = job.core.output.lastAgentMessage?.nilIfEmpty
        let resultText = result?.nilIfEmpty
        let finalReviewText = resultText ?? previousAgentMessage
        job.timeline.closeActiveItems(family: .command, phase: .completed, timestamp: endedAt)
        job.core.lifecycle.status = .succeeded
        job.core.lifecycle.endedAt = endedAt
        job.core.output.summary = summary
        job.core.output.lastAgentMessage = finalReviewText ?? summary
        job.core.output.hasFinalReview = finalReviewText != nil
        job.core.output.reviewResult = ParsedReviewResult.parse(finalReviewText: finalReviewText)
        if let result = resultText,
            result != previousAgentMessage
        {
            applyMessageSnapshot(result, itemID: nil, isCompleted: true, to: job, at: endedAt)
        }
        job.timeline.apply(.reviewCompleted(summary: summary, result: finalReviewText), at: endedAt)
        writeDiagnosticsIfNeeded()
    }

    private func waitForReviewTerminal(jobID: String, timeout: Duration?) async {
        guard let job = job(id: jobID),
            job.isTerminal == false
        else {
            return
        }
        _ = await ReviewObservationAwaiter.waitUntilTerminal(
            job: job,
            timeout: timeout
        )
    }

    private func nextJobSortOrder(inWorkspace cwd: String) -> Double {
        (jobs(inWorkspace: cwd).map(\.sortOrder).max() ?? -1) + 1
    }

    private func nextWorkspaceSortOrder() -> Double {
        (workspaces.map(\.sortOrder).max() ?? -1) + 1
    }
}

private extension CodexReviewBackendModel.Review.Event {
    var completesReviewRun: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .domainEvents,
            .started,
            .message,
            .messageDelta,
            .log:
            false
        }
    }
}

private extension CodexReviewJob {
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

    func appendAgentMessageDelta(itemID: String, delta: String) -> String? {
        guard completedAgentMessageItemIDs.contains(itemID) == false else {
            return nil
        }
        let updated = (agentMessagesByItemID[itemID] ?? "") + delta
        agentMessagesByItemID[itemID] = updated
        return updated
    }

    func noteAgentMessageSnapshot(itemID: String, text: String, isCompleted: Bool) {
        agentMessagesByItemID[itemID] = text
        if isCompleted {
            completedAgentMessageItemIDs.insert(itemID)
        } else {
            completedAgentMessageItemIDs.remove(itemID)
        }
    }

    func resetReviewAttemptOutputForRecovery() {
        core.output.lastAgentMessage = nil
        core.output.hasFinalReview = false
        core.output.reviewResult = nil
        agentMessagesByItemID.removeAll(keepingCapacity: true)
        completedAgentMessageItemIDs.removeAll(keepingCapacity: true)
        timeline.reset(keepingTerminal: core.lifecycle.status.isTerminal)
        syncTimelineTerminalStateFromCore()
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
