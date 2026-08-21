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
        _ = try await awaitReview(sessionID: sessionID, jobID: jobID)
        await reviewWorkerTasks[jobID]?.value
        return try readReview(sessionID: sessionID, jobID: jobID)
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
            ),
            logEntries: []
        )
        insertReviewJob(job)
        markReviewRunning(job, startedAt: createdAt)
        let admission = ReviewStartAdmission(closePolicy: reviewRuntimeClosePolicy)
        reviewStartAdmissions[jobID] = admission
        launchReviewWorker(
            jobID: jobID,
            sessionID: sessionID,
            request: validatedRequest,
            admission: admission
        )
        return jobID
    }

    private func launchReviewWorker(
        jobID: String,
        sessionID: String,
        request: CodexReviewAPI.Start.Request,
        admission: ReviewStartAdmission
    ) {
        reviewWorkerTasks[jobID]?.cancel()
        reviewWorkerTasks[jobID] = Task { [weak self] in
            await self?.runReviewWorker(
                jobID: jobID,
                sessionID: sessionID,
                request: request,
                admission: admission
            )
        }
    }

    private func runReviewWorker(
        jobID: String,
        sessionID: String,
        request validatedRequest: CodexReviewAPI.Start.Request,
        admission: ReviewStartAdmission
    ) async {
        guard let job = job(id: jobID) else {
            reviewStartAdmissions.removeValue(forKey: jobID)
            reviewWorkerTasks.removeValue(forKey: jobID)
            resumeReviewWaiters(for: jobID)
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
            let backend = self.backend
            let startTask = await admission.start { admission in
                try await backend.startReview(startRequest, admission: admission)
            }
            let backendAttempt = try await startTask.value
            let backendRun = backendAttempt.run
            run = backendRun
            applyBackendRun(backendRun, to: job)

            if job.isTerminal {
                do {
                    try await cleanupReview(backendRun, admission: admission)
                } catch {
                    retainCleanupFailure(error, for: jobID)
                }
                activeRuns.removeValue(forKey: jobID)
                reviewRecoveryWaitingJobIDs.remove(jobID)
            } else {
                let currentRun = try await consumeReviewEvents(
                    for: backendAttempt,
                    job: job,
                    startRequest: startRequest,
                    admission: admission
                )
                run = currentRun
                do {
                    try await cleanupReview(currentRun, admission: admission)
                } catch {
                    retainCleanupFailure(error, for: jobID)
                }
                activeRuns.removeValue(forKey: jobID)
                reviewRecoveryWaitingJobIDs.remove(jobID)
            }
        } catch let cancellation as ReviewStartCancelledBeforeDispatch {
            if job.isTerminal == false {
                try? completeCancellationLocally(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    cancellation: cancellation.cancellation
                )
            }
        } catch let error where error is CancellationError || Task.isCancelled {
            if let cleanupRun = activeRuns[jobID] ?? run {
                let failure = ReviewRuntimeCloseFailure.worker(
                    "Review worker was cancelled before a canonical terminal."
                )
                await admission.recordConnectionTerminal(failure)
                do {
                    try await cleanupReview(cleanupRun, admission: admission)
                } catch {
                    retainCleanupFailure(error, for: jobID)
                }
                if job.isTerminal == false {
                    markReviewInterrupted(job, cause: .transport(message: failure.localizedDescription))
                }
            } else if job.isTerminal == false {
                await markReviewWorkerFailure(
                    job,
                    fallbackMessage: error.localizedDescription,
                    admission: admission
                )
            }
            activeRuns.removeValue(forKey: jobID)
            reviewRecoveryWaitingJobIDs.remove(jobID)
        } catch {
            if let cleanupRun = activeRuns[jobID] ?? run {
                do {
                    try await cleanupReview(cleanupRun, admission: admission)
                } catch {
                    retainCleanupFailure(error, for: jobID)
                }
            }
            activeRuns.removeValue(forKey: jobID)
            reviewRecoveryWaitingJobIDs.remove(jobID)
            if job.isTerminal == false,
               let transportFailure = error as? ReviewWorkerInputQueueError {
                let failure = ReviewRuntimeCloseFailure.connection(transportFailure.message)
                await admission.recordConnectionTerminal(failure)
                markReviewInterrupted(
                    job,
                    cause: .transport(message: transportFailure.message)
                )
            } else if job.isTerminal == false {
                await markReviewWorkerFailure(
                    job,
                    fallbackMessage: error.localizedDescription,
                    admission: admission
                )
            }
        }
        reviewWorkerTasks.removeValue(forKey: jobID)
        runtimeStopDetachedReviewWorkerTasks.removeValue(forKey: jobID)
        if reviewCleanupFailures[jobID] == nil {
            reviewStartAdmissions.removeValue(forKey: jobID)
        }
        if job.isTerminal {
            resumeReviewWaiters(for: jobID)
        }
    }

    private func cleanupReview(
        _ run: CodexReviewBackendModel.Review.Run,
        admission: ReviewStartAdmission
    ) async throws {
        let backend = self.backend
        try await admission.cleanup(run: run) {
            try await backend.cleanupReview(run)
        }
    }

    private func retainCleanupFailure(_ error: any Error, for jobID: String) {
        guard reviewCleanupFailures[jobID] == nil else {
            return
        }
        if let failure = error as? ReviewRuntimeCloseFailure {
            reviewCleanupFailures[jobID] = failure
        } else {
            reviewCleanupFailures[jobID] = .cleanup(error.localizedDescription)
        }
        writeDiagnosticsIfNeeded()
    }

    private func applyBackendRun(_ backendRun: CodexReviewBackendModel.Review.Run, to job: CodexReviewJob) {
        activeRuns[job.id] = backendRun
        job.core.run = .init(
            reviewThreadID: backendRun.reviewThreadID,
            threadID: backendRun.threadID,
            turnID: backendRun.turnID,
            model: backendRun.model
        )
        writeDiagnosticsIfNeeded()
    }

    private func appendRecoveryProgress(_ message: String, to job: CodexReviewJob) {
        job.core.output.summary = message
        job.appendLogEntry(.init(kind: .progress, text: message, timestamp: clock.now()))
        job.applyReviewLogLimit()
        writeDiagnosticsIfNeeded()
    }

    private func markReviewWaitingForNetworkRecovery(_ job: CodexReviewJob) {
        let now = clock.now()
        job.closeActiveCommandLogEntries(status: "canceled", completedAt: now)
        job.resetReviewAttemptOutputForRecovery()
        appendRecoveryProgress(networkRecoveryUnavailableMessage, to: job)
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

    package func readReview(
        jobID: String,
        logFilter: CodexReviewAPI.Log.Filter = .defaultSetting,
        logPage: CodexReviewAPI.Log.PageRequest = .default
    ) throws -> CodexReviewAPI.Read.Result {
        try readReview(sessionID: nil, jobID: jobID, logFilter: logFilter, logPage: logPage)
    }

    package func readReview(
        sessionID: String?,
        jobID: String,
        logFilter: CodexReviewAPI.Log.Filter = .defaultSetting,
        logPage: CodexReviewAPI.Log.PageRequest = .default
    ) throws -> CodexReviewAPI.Read.Result {
        let job = try job(jobID: jobID)
        if let sessionID, job.sessionID != sessionID {
            throw CodexReviewAPI.Error.jobNotFound("Job \(jobID) was not found.")
        }
        let pageRequest = try logPage.validated()
        let filteredLogs = projectedLogsForReviewRead(job.logEntries).filter(logFilter.includes)
        let page = pageRequest.page(total: filteredLogs.count)
        return CodexReviewAPI.Read.Result(
            jobID: job.id,
            core: job.core,
            elapsedSeconds: elapsedSeconds(for: job),
            cancellable: job.isTerminal == false && job.cancellationRequested == false,
            logs: Array(filteredLogs[page.offset..<page.offset + page.returned]),
            logsPage: page,
            rawLogText: job.rawLogText
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

        recordCancellationRequest(cancellation, for: job)

        if reviewRecoveryWaitingJobIDs.contains(jobID) {
            try completeCancellationLocally(
                jobID: job.id,
                sessionID: job.sessionID,
                cancellation: cancellation
            )
            reviewWorkerTasks[jobID]?.cancel()
            return .init(jobID: job.id, cancelled: true, core: job.core)
        }

        guard let admission = reviewStartAdmissions[jobID] else {
            try completeCancellationLocally(
                jobID: job.id,
                sessionID: job.sessionID,
                cancellation: cancellation
            )
            return .init(jobID: job.id, cancelled: true, core: job.core)
        }

        let backend = self.backend
        do {
            let resolution = try await admission.cancel(
                cancellation,
                interrupt: { run, reason in
                    try await backend.interruptReview(run, reason: reason)
                },
                forceClose: {
                    try await backend.forceCloseReviewConnection()
                }
            )
            await reviewWorkerTasks[jobID]?.value
            if job.isTerminal == false,
               case .localCancellation = resolution.terminal {
                try completeCancellationLocally(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    cancellation: cancellation
                )
            }
            if let run = resolution.terminal.canonicalRun,
               let cleanupResult = await admission.recordedCleanupResult(for: run) {
                try cleanupResult.get()
            }
        } catch {
            let phase = await admission.currentPhase()
            if case .finishing = phase {
                await reviewWorkerTasks[jobID]?.value
            } else if case .terminal = phase {
                await reviewWorkerTasks[jobID]?.value
            }
            if job.isTerminal == false {
                try recordCancellationFailure(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    message: error.localizedDescription
                )
            }
            throw error
        }
        return .init(
            jobID: job.id,
            cancelled: job.core.lifecycle.status == .cancelled,
            core: job.core
        )
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
        let jobIDs = orderedJobs
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
        writeDiagnosticsIfNeeded()
    }

    private func markReviewFailed(
        _ job: CodexReviewJob,
        message: String?,
        terminal: ReviewTerminalRecord? = nil
    ) {
        guard job.isTerminal == false else {
            return
        }
        let displayMessage = message?.nilIfEmpty ?? "Review failed."
        let endedAt = clock.now()
        job.closeActiveCommandLogEntries(status: "failed", completedAt: endedAt)
        job.core.lifecycle.terminal = terminal ?? .failed(message: message?.nilIfEmpty)
        job.core.lifecycle.status = .failed
        job.core.lifecycle.endedAt = endedAt
        job.core.lifecycle.errorMessage = message?.nilIfEmpty
        job.core.output.summary = displayMessage
        job.appendLogEntry(.init(kind: .error, text: displayMessage, timestamp: endedAt))
        job.applyReviewLogLimit()
        writeDiagnosticsIfNeeded()
        resumeReviewWaiters(for: job.id)
    }

    private func markReviewInterrupted(
        _ job: CodexReviewJob,
        cause: ReviewInterruptionCause
    ) {
        let message: String? = switch cause {
        case .requested(let cancellation):
            cancellation.message
        case .server(let message):
            message
        case .transport(let message):
            message
        case .previousProcessExit:
            "The previous review process exited before completion."
        }
        markReviewFailed(
            job,
            message: message,
            terminal: .interrupted(cause)
        )
    }

    private func markReviewWorkerFailure(
        _ job: CodexReviewJob,
        fallbackMessage: String,
        admission: ReviewStartAdmission
    ) async {
        if let connectionFailure = await admission.recordedConnectionTerminal() {
            markReviewInterrupted(
                job,
                cause: .transport(message: connectionFailure.localizedDescription)
            )
        } else {
            markReviewFailed(job, message: fallbackMessage)
        }
    }

    private func consumeReviewEvents(
        for initialAttempt: BackendReviewAttempt,
        job: CodexReviewJob,
        startRequest: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
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
                if let terminal = reviewTerminalRecord(for: event.event, job: job) {
                    try await admission.recordCanonicalTerminal(
                        terminal,
                        for: recoveryState.currentRun
                    )
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
                if await handleReviewEventsFinished(
                    job: job,
                    isWaitingForNetworkRecovery: recoveryState.isWaitingForNetworkRecovery,
                    admission: admission
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
                guard recoveryState.shouldRestartReviewAfterRecoverySettle(
                    recoveryGeneration: recoveryGeneration
                ) else {
                    continue
                }
                switch try await restartReviewAfterNetworkRestore(
                    job: job,
                    startRequest: startRequest,
                    inputs: inputs,
                    recoveryToken: recoveryState.recoveryToken,
                    admission: admission
                ) {
                case .continueWaiting:
                    recoveryState.markWaitingForNetworkRecovery()
                    continue
                case .finished:
                    reviewRecoveryWaitingJobIDs.remove(job.id)
                    return recoveryState.currentRun
                case .recovered(let recoveredAttempt):
                    let recoveredRun = recoveredAttempt.run
                    await admission.recordActiveRun(recoveredRun)
                    applyBackendRun(recoveredRun, to: job)
                    recoveryState.markRecovered(with: recoveredRun)
                    reviewRecoveryWaitingJobIDs.remove(job.id)
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
                reviewRecoveryWaitingJobIDs.insert(job.id)
                activeEventSubscriptionID = nil
                await inputs.cancelActiveEventSubscription()
                let recoveryToken = try await backend.beginReviewRecovery(
                    recoveryState.currentRun,
                    reason: recoveryState.recoveryReason
                )
                recoveryState.markRecoveryToken(recoveryToken)
            }
        }

        if Task.isCancelled {
            throw CancellationError()
        }
        if job.isTerminal == false {
            let failure = ReviewRuntimeCloseFailure.connection(
                ReviewIngestionError.streamEndedWithoutTerminal.localizedDescription
            )
            await admission.recordConnectionTerminal(failure)
            markReviewInterrupted(job, cause: .transport(message: failure.localizedDescription))
        }
        return recoveryState.currentRun
    }

    private func handleReviewEventsFinished(
        job: CodexReviewJob,
        isWaitingForNetworkRecovery: Bool,
        admission: ReviewStartAdmission
    ) async -> Bool {
        if Task.isCancelled {
            return true
        }

        if isWaitingForNetworkRecovery {
            return job.isTerminal || completePendingCancellationIfNeeded(for: job)
        }

        if job.isTerminal == false {
            let failure = ReviewRuntimeCloseFailure.connection(
                ReviewIngestionError.streamEndedWithoutTerminal.localizedDescription
            )
            await admission.recordConnectionTerminal(failure)
            markReviewInterrupted(job, cause: .transport(message: failure.localizedDescription))
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
        recoveryToken: CodexReviewBackendModel.Review.RecoveryToken?,
        admission: ReviewStartAdmission
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
        guard let recoveryToken else {
            return .continueWaiting
        }
        let recoveredAttempt = try await backend.resumeReviewRecovery(
            recoveryToken,
            request: startRequest
        )
        let recoveredRun = recoveredAttempt.run
        await admission.recordActiveRun(recoveredRun)
        if try await stopRecoveredRunIfJobShouldNotResume(
            recoveredRun,
            job: job,
            admission: admission
        ) {
            return .finished
        }
        return .recovered(recoveredAttempt)
    }

    private func stopRecoveredRunIfJobShouldNotResume(
        _ recoveredRun: CodexReviewBackendModel.Review.Run,
        job: CodexReviewJob,
        admission: ReviewStartAdmission
    ) async throws -> Bool {
        if Task.isCancelled {
            try? await backend.interruptReview(
                recoveredRun,
                reason: .init(message: job.core.lifecycle.cancellation?.message ?? "Cancellation requested.")
            )
            try await cleanupReview(recoveredRun, admission: admission)
            throw CancellationError()
        }

        if job.isTerminal {
            if job.core.lifecycle.status == .cancelled {
                try? await backend.interruptReview(
                    recoveredRun,
                    reason: .init(message: job.core.lifecycle.cancellation?.message ?? "Cancellation requested.")
                )
            }
            try await cleanupReview(recoveredRun, admission: admission)
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
            try await cleanupReview(recoveredRun, admission: admission)
            try? recordCancellationFailure(
                jobID: job.id,
                sessionID: job.sessionID,
                message: error.localizedDescription
            )
            throw error
        }
        try await cleanupReview(recoveredRun, admission: admission)
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
        let updatedRun = currentRun
        switch event {
        case .started:
            job.core.output.summary = "Review started."
        case .message(let text):
            job.core.output.lastAgentMessage = text
            job.core.output.summary = text
            job.appendLogEntry(.init(kind: .agentMessage, text: text, timestamp: clock.now()))
        case .messageDelta(let text, let itemID):
            guard let updatedMessage = job.appendAgentMessageDelta(itemID: itemID, delta: text) else {
                return updatedRun
            }
            job.core.output.lastAgentMessage = updatedMessage
            job.core.output.summary = updatedMessage
            job.appendLogEntry(.init(
                kind: .agentMessage,
                groupID: itemID,
                text: text,
                timestamp: clock.now()
            ))
        case .log(let text):
            job.appendLogEntry(.init(kind: .progress, text: text, timestamp: clock.now()))
        case .logEntry(let kind, let text, let groupID, let replacesGroup, let metadata):
            if metadata?.sourceType == "suppressedFinalReviewCompanion",
               let groupID {
                job.replaceLogEntries(job.logEntries.filter {
                    !($0.kind == .agentMessage && $0.groupID == groupID)
                })
                job.agentMessagesByItemID.removeValue(forKey: groupID)
                job.completedAgentMessageItemIDs.remove(groupID)
                writeDiagnosticsIfNeeded()
                return updatedRun
            }
            if kind == .agentMessage {
                if let groupID, replacesGroup {
                    job.noteCompletedAgentMessage(itemID: groupID, text: text)
                }
                job.core.output.lastAgentMessage = text
                job.core.output.summary = text
            }
            job.appendLogEntry(.init(
                kind: kind,
                groupID: groupID,
                replacesGroup: replacesGroup,
                text: text,
                metadata: metadata,
                timestamp: clock.now()
            ))
        case .completed(let summary, let result):
            completeReview(job, summary: summary, result: result)
        case .failed(let message):
            markReviewFailed(job, message: message)
        case .cancelled(let message):
            if let cancellation = job.core.lifecycle.cancellation {
                try? completeCancellationLocally(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    cancellation: cancellation
                )
            } else {
                markReviewInterrupted(
                    job,
                    cause: .server(message: message?.nilIfEmpty)
                )
            }
        }
        writeDiagnosticsIfNeeded()
        return updatedRun
    }

    private func reviewTerminalRecord(
        for event: CodexReviewBackendModel.Review.Event,
        job: CodexReviewJob
    ) -> ReviewTerminalRecord? {
        switch event {
        case .completed:
            return .completed
        case .failed(let message):
            return .failed(message: message?.nilIfEmpty)
        case .cancelled(let message):
            if let cancellation = job.core.lifecycle.cancellation {
                return .interrupted(.requested(cancellation))
            }
            return .interrupted(.server(message: message?.nilIfEmpty))
        case .started, .message, .messageDelta, .log, .logEntry:
            return nil
        }
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
        let finalResult: ReviewFinalResult
        do {
            guard let result else {
                throw ReviewIngestionError.missingFinalReview
            }
            finalResult = try ReviewFinalResult(
                validating: result,
                source: .backendProvided
            )
        } catch {
            markReviewFailed(job, message: error.localizedDescription)
            return
        }
        let endedAt = clock.now()
        job.closeActiveCommandLogEntries(status: "completed", completedAt: endedAt)
        job.core.lifecycle.terminal = .completed
        job.core.lifecycle.status = .succeeded
        job.core.lifecycle.endedAt = endedAt
        job.core.output.summary = summary
        job.core.output.lastAgentMessage = finalResult.text
        job.core.output.hasFinalReview = true
        job.core.output.reviewResult = ParsedReviewResult.parse(finalReviewText: finalResult.text)
        let hasCanonicalResultRow = job.logEntries.contains { entry in
            guard entry.kind == .agentMessage else {
                return false
            }
            return entry.metadata?.sourceType == "exitedReviewMode"
                || entry.metadata?.sourceType == "canonicalReviewResult"
        }
        if hasCanonicalResultRow == false {
            job.appendLogEntry(.init(
                kind: .agentMessage,
                text: finalResult.text,
                metadata: .init(sourceType: "canonicalReviewResult"),
                timestamp: endedAt
            ))
        }
        job.applyReviewLogLimit()
        writeDiagnosticsIfNeeded()
        resumeReviewWaiters(for: job.id)
    }

    private func waitForReviewTerminal(jobID: String, timeout: Duration?) async {
        guard job(id: jobID)?.isTerminal == false else {
            return
        }
        let waiterID = UUID()
        let timeoutTask = timeout.map { duration in
            Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: duration)
                } catch {
                    return
                }
                self?.resumeReviewWaiter(jobID: jobID, waiterID: waiterID)
            }
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if job(id: jobID)?.isTerminal != false {
                    timeoutTask?.cancel()
                    continuation.resume()
                    return
                }
                reviewTerminalWaiters[jobID, default: []].append(.init(
                    id: waiterID,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                ))
            }
        } onCancel: {
            timeoutTask?.cancel()
            Task { @MainActor [weak self] in
                self?.resumeReviewWaiter(jobID: jobID, waiterID: waiterID)
            }
        }
        timeoutTask?.cancel()
    }

    package func resumeReviewWaiters(for jobID: String) {
        let waiters = reviewTerminalWaiters.removeValue(forKey: jobID) ?? []
        for waiter in waiters {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume()
        }
    }

    private func resumeReviewWaiter(jobID: String, waiterID: UUID) {
        guard var waiters = reviewTerminalWaiters[jobID],
              let index = waiters.firstIndex(where: { $0.id == waiterID })
        else {
            return
        }
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            reviewTerminalWaiters.removeValue(forKey: jobID)
        } else {
            reviewTerminalWaiters[jobID] = waiters
        }
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume()
    }

    private func nextJobSortOrder(inWorkspace cwd: String) -> Double {
        (jobs(inWorkspace: cwd).map(\.sortOrder).max() ?? -1) + 1
    }

    private func nextWorkspaceSortOrder() -> Double {
        (workspaces.map(\.sortOrder).max() ?? -1) + 1
    }
}

private struct ReviewReadLogGroupKey: Hashable {
    var kind: ReviewLogEntry.Kind
    var groupID: String
}

private func projectedLogsForReviewRead(_ entries: [ReviewLogEntry]) -> [ReviewLogEntry] {
    var projected: [ReviewLogEntry] = []
    var indexByGroup: [ReviewReadLogGroupKey: Int] = [:]

    for entry in entries {
        guard let key = reviewReadLogGroupKey(for: entry) else {
            projected.append(entry)
            continue
        }

        if let index = indexByGroup[key] {
            guard entry.replacesGroup || shouldAppendReviewReadLogDelta(for: entry.kind) else {
                projected.append(entry)
                continue
            }

            let existing = projected[index]
            let text = entry.replacesGroup ? entry.text : existing.text + entry.text
            let metadata = entry.replacesGroup ? entry.metadata : entry.metadata ?? existing.metadata
            projected[index] = ReviewLogEntry(
                id: entry.id,
                kind: entry.kind,
                groupID: entry.groupID,
                replacesGroup: false,
                text: text,
                metadata: metadata,
                timestamp: entry.timestamp
            )
            continue
        }

        if entry.replacesGroup || shouldAppendReviewReadLogDelta(for: entry.kind) {
            indexByGroup[key] = projected.count
        }
        projected.append(ReviewLogEntry(
            id: entry.id,
            kind: entry.kind,
            groupID: entry.groupID,
            replacesGroup: false,
            text: entry.text,
            metadata: entry.metadata,
            timestamp: entry.timestamp
        ))
    }

    return projected
}

private func reviewReadLogGroupKey(for entry: ReviewLogEntry) -> ReviewReadLogGroupKey? {
    guard let groupID = entry.groupID?.nilIfEmpty else {
        return nil
    }

    return ReviewReadLogGroupKey(kind: entry.kind, groupID: groupID)
}

private func shouldAppendReviewReadLogDelta(for kind: ReviewLogEntry.Kind) -> Bool {
    switch kind {
    case .agentMessage,
         .command,
         .commandOutput,
         .plan,
         .reasoning,
         .reasoningSummary,
         .rawReasoning,
         .contextCompaction:
        return true
    case .todoList,
         .toolCall,
         .diagnostic,
         .error,
         .progress,
         .event:
        return false
    }
}

private extension CodexReviewBackendModel.Review.Event {
    var completesReviewRun: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .started, .message, .messageDelta, .log, .logEntry:
            false
        }
    }
}

private extension CodexReviewJob {
    func appendAgentMessageDelta(itemID: String, delta: String) -> String? {
        guard completedAgentMessageItemIDs.contains(itemID) == false else {
            return nil
        }
        let updated = (agentMessagesByItemID[itemID] ?? "") + delta
        agentMessagesByItemID[itemID] = updated
        return updated
    }

    func noteCompletedAgentMessage(itemID: String, text: String) {
        agentMessagesByItemID[itemID] = text
        completedAgentMessageItemIDs.insert(itemID)
    }

    func resetReviewAttemptOutputForRecovery() {
        core.output.lastAgentMessage = nil
        core.output.hasFinalReview = false
        core.output.reviewResult = nil
        agentMessagesByItemID.removeAll(keepingCapacity: true)
        completedAgentMessageItemIDs.removeAll(keepingCapacity: true)
        replaceLogEntries(logEntries.filter { $0.kind != .agentMessage })
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
    private(set) var recoveryToken: CodexReviewBackendModel.Review.RecoveryToken?
    private var isSettlingForNetworkRecovery = false
    private var recoverySettleGeneration: Int?
    private var pendingOutageStreamFailure: ReviewWorkerEventStreamFailure?
    let recoveryReason = CodexReviewBackendModel.CancellationReason(message: networkRecoveryUnavailableMessage)

    init(currentRun: CodexReviewBackendModel.Review.Run) {
        self.currentRun = currentRun
    }

    mutating func markWaitingForNetworkRecovery() {
        isWaitingForNetworkRecovery = true
        isSettlingForNetworkRecovery = false
        recoverySettleGeneration = nil
        pendingOutageStreamFailure = nil
    }

    mutating func markRecoveryToken(_ token: CodexReviewBackendModel.Review.RecoveryToken) {
        recoveryToken = token
    }

    mutating func markRecovered(with run: CodexReviewBackendModel.Review.Run) {
        currentRun = run
        isWaitingForNetworkRecovery = false
        recoveryToken = nil
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
            && recoveryToken != nil
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
           let waiter = waiters.removeValue(forKey: waiterID) {
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
        await queue.send(.reviewEvent(.init(
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
        await queue.send(.reviewEventsFinished(.init(
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
        await queue.send(.reviewEventsFailed(.init(
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
