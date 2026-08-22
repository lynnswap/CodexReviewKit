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
        try await performThrowingRegisteredStoreWork(
            kind: .reviewMutation("start")
        ) { @MainActor store in
            try await store.performStartReview(
                sessionID: sessionID,
                request: request,
                waitTimeout: nil
            )
        }
    }

    @discardableResult
    package func startReview(
        sessionID: String,
        request: CodexReviewAPI.Start.Request,
        waitTimeout: Duration
    ) async throws -> CodexReviewAPI.Read.Result {
        try await performThrowingRegisteredStoreWork(
            kind: .reviewMutation("start")
        ) { @MainActor store in
            try await store.performStartReview(
                sessionID: sessionID,
                request: request,
                waitTimeout: waitTimeout
            )
        }
    }

    private func performStartReview(
        sessionID: String,
        request: CodexReviewAPI.Start.Request,
        waitTimeout: Duration?
    ) async throws -> CodexReviewAPI.Read.Result {
        let jobID = try beginReview(sessionID: sessionID, request: request)
        guard let waitTimeout else {
            return try await withTaskCancellationHandler {
                _ = try await awaitReview(sessionID: sessionID, jobID: jobID)
                await reviewWorkerTasks[jobID]?.value
                return try readReview(sessionID: sessionID, jobID: jobID)
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.reviewWorkerTasks[jobID]?.cancel()
                }
            }
        }
        return try await awaitReview(
            sessionID: sessionID,
            jobID: jobID,
            timeout: waitTimeout
        )
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
        if isReviewResultFinalized(jobID: jobID) == false {
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
        guard let workerTask = makeReviewWorker(
            jobID: jobID,
            sessionID: sessionID,
            request: validatedRequest
        ) else {
            throw CodexReviewAPI.Error.io("Review Store work admission is closed.")
        }
        insertReviewJob(job)
        markReviewRunning(job, startedAt: createdAt)
        startingJobIDs.insert(jobID)
        reviewWorkerTasks[jobID]?.cancel()
        reviewWorkerTasks[jobID] = workerTask
        return jobID
    }

    private func makeReviewWorker(
        jobID: String,
        sessionID: String,
        request: CodexReviewAPI.Start.Request
    ) -> Task<Void, Never>? {
        startRegisteredStoreWork(
            kind: .reviewWorker(jobID: jobID),
            cancelledBeforeEntry: .runFinalizer { store in
                store.finishReviewWorkerCancelledBeforeStart(jobID: jobID)
            }
        ) { @MainActor store in
            await store.runReviewWorker(
                jobID: jobID,
                sessionID: sessionID,
                request: request
            )
        }
    }

    private func finishReviewWorkerCancelledBeforeStart(jobID: String) {
        startingJobIDs.remove(jobID)
        startupCancellations.removeValue(forKey: jobID)
        activeRuns.removeValue(forKey: jobID)
        reviewRecoveryWaitingJobIDs.remove(jobID)
        if let job = job(id: jobID), job.isTerminal == false {
            try? completeCancellationLocally(
                jobID: job.id,
                sessionID: job.sessionID,
                cancellation: job.core.lifecycle.cancellation ?? .system()
            )
        }
        reviewWorkerTasks.removeValue(forKey: jobID)
        resumeReviewWaiters(for: jobID)
    }

    private func runReviewWorker(
        jobID: String,
        sessionID: String,
        request validatedRequest: CodexReviewAPI.Start.Request
    ) async {
        guard let job = job(id: jobID) else {
            startingJobIDs.remove(jobID)
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
            let backendAttempt = try await backend.startReview(startRequest)
            let backendRun = backendAttempt.run
            startingJobIDs.remove(jobID)
            run = backendRun
            if Task.isCancelled {
                throw CancellationError()
            }
            applyBackendRun(backendRun, to: job)
            if let startupCancellation = startupCancellations.removeValue(forKey: jobID) {
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
                await cleanupReviewAndRetainFailure(backendRun, for: job)
                activeRuns.removeValue(forKey: jobID)
                reviewRecoveryWaitingJobIDs.remove(jobID)
            } else {
                let currentRun = try await consumeReviewEvents(
                    for: backendAttempt,
                    job: job,
                    startRequest: startRequest
                )
                run = currentRun
                await cleanupReviewAndRetainFailure(currentRun, for: job)
                activeRuns.removeValue(forKey: jobID)
                reviewRecoveryWaitingJobIDs.remove(jobID)
            }
        } catch let error where error is CancellationError || Task.isCancelled {
            startingJobIDs.remove(jobID)
            let startupCancellation = startupCancellations.removeValue(forKey: jobID)
            if let cleanupRun = activeRuns[jobID] ?? run {
                await interruptReviewAfterTaskCancellation(cleanupRun, job: job)
                await cleanupReviewAndRetainFailure(cleanupRun, for: job)
            } else if job.isTerminal == false || startupCancellation != nil {
                try? completeCancellationLocally(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    cancellation: startupCancellation ?? job.core.lifecycle.cancellation ?? .system()
                )
            }
            activeRuns.removeValue(forKey: jobID)
            reviewRecoveryWaitingJobIDs.remove(jobID)
        } catch {
            let primaryError = error
            startingJobIDs.remove(jobID)
            let startupCancellation = startupCancellations.removeValue(forKey: jobID)
            let cleanupFailure: ReviewRuntimeCloseFailure?
            if let cleanupRun = activeRuns[jobID] ?? run {
                cleanupFailure = await cleanupReviewFailure(cleanupRun)
            } else {
                cleanupFailure = nil
            }
            activeRuns.removeValue(forKey: jobID)
            reviewRecoveryWaitingJobIDs.remove(jobID)
            if job.isTerminal == false, let startupCancellation {
                try? completeCancellationLocally(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    cancellation: startupCancellation
                )
            } else if job.isTerminal == false,
                      let transportFailure = primaryError as? ReviewWorkerInputQueueError {
                markReviewInterrupted(
                    job,
                    cause: .transport(message: transportFailure.message)
                )
            } else if job.isTerminal == false {
                markReviewFailed(job, message: primaryError.localizedDescription)
            }
            if let cleanupFailure {
                retainCleanupFailure(cleanupFailure, for: job)
            }
        }
        reviewWorkerTasks.removeValue(forKey: jobID)
        runtimeStopDetachedReviewWorkerTasks.removeValue(forKey: jobID)
        if job.isTerminal {
            resumeReviewWaiters(for: jobID)
        }
    }

    private func cleanupReviewAndRetainFailure(
        _ run: CodexReviewBackendModel.Review.Run,
        for job: CodexReviewJob
    ) async {
        if let failure = await cleanupReviewFailure(run) {
            retainCleanupFailure(failure, for: job)
        }
    }

    private func cleanupReviewFailure(
        _ run: CodexReviewBackendModel.Review.Run
    ) async -> ReviewRuntimeCloseFailure? {
        do {
            try await backend.cleanupReview(run)
            return nil
        } catch let failure as ReviewRuntimeCloseFailure {
            return failure
        } catch {
            return .cleanup(error.localizedDescription)
        }
    }

    private func retainCleanupFailure(
        _ failure: ReviewRuntimeCloseFailure,
        for job: CodexReviewJob
    ) {
        job.appendLogEntry(.init(
            kind: .diagnostic,
            text: failure.localizedDescription,
            timestamp: clock.now()
        ))
        writeDiagnosticsIfNeeded()
    }

    private func interruptReviewAfterTaskCancellation(_ run: CodexReviewBackendModel.Review.Run, job: CodexReviewJob) async {
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
            if storeWorkRegistry.acceptsNewWork {
                try? recordCancellationFailure(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    message: error.localizedDescription
                )
            } else {
                markReviewFailed(
                    job,
                    message: error.localizedDescription
                )
            }
        }
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
        try await performThrowingRegisteredStoreWork(
            kind: .reviewMutation("cancel")
        ) { @MainActor store in
            guard let job = store.job(id: jobID), job.sessionID == sessionID else {
                throw CodexReviewAPI.Error.jobNotFound("Job \(jobID) was not found.")
            }
            return try await store.performCancelReview(
                jobID: jobID,
                cancellation: cancellation
            )
        }
    }

    @discardableResult
    package func cancelReview(
        jobID: String,
        cancellation: ReviewCancellation = .system()
    ) async throws -> CodexReviewAPI.Cancel.Outcome {
        try await performThrowingRegisteredStoreWork(
            kind: .reviewMutation("cancel")
        ) { @MainActor store in
            try await store.performCancelReview(
                jobID: jobID,
                cancellation: cancellation
            )
        }
    }

    private func performCancelReview(
        jobID: String,
        cancellation: ReviewCancellation
    ) async throws -> CodexReviewAPI.Cancel.Outcome {
        let job = try job(jobID: jobID)
        guard job.isTerminal == false else {
            return .init(jobID: job.id, cancelled: false, core: job.core)
        }

        recordCancellationRequest(cancellation, for: job)

        if job.core.lifecycle.status == .queued {
            try completeCancellationLocally(
                jobID: job.id,
                sessionID: job.sessionID,
                cancellation: cancellation
            )
            return .init(jobID: job.id, cancelled: true, core: job.core)
        }

        if reviewRecoveryWaitingJobIDs.contains(jobID) {
            try completeCancellationLocally(
                jobID: job.id,
                sessionID: job.sessionID,
                cancellation: cancellation
            )
            reviewWorkerTasks[jobID]?.cancel()
            return .init(jobID: job.id, cancelled: true, core: job.core)
        }

        if let run = activeRuns[jobID] {
            do {
                try await backend.interruptReview(
                    run,
                    reason: .init(message: cancellation.message)
                )
                if job.isTerminal == false {
                    try completeCancellationLocally(
                        jobID: job.id,
                        sessionID: job.sessionID,
                        cancellation: cancellation
                    )
                    reviewWorkerTasks[jobID]?.cancel()
                }
            } catch {
                guard job.isTerminal == false else {
                    return .init(
                        jobID: job.id,
                        cancelled: job.core.lifecycle.status == .cancelled,
                        core: job.core
                    )
                }
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
                if job.isTerminal == false {
                    try completeCancellationLocally(
                        jobID: job.id,
                        sessionID: job.sessionID,
                        cancellation: cancellation
                    )
                    reviewWorkerTasks[jobID]?.cancel()
                }
            } catch {
                guard job.isTerminal == false else {
                    return .init(
                        jobID: job.id,
                        cancelled: job.core.lifecycle.status == .cancelled,
                        core: job.core
                    )
                }
                try recordCancellationFailure(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    message: error.localizedDescription
                )
                throw error
            }
        } else if startingJobIDs.contains(jobID) {
            startupCancellations[jobID] = cancellation
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
        await performRegisteredStoreWork(
            kind: .reviewMutation("close-session")
        ) { @MainActor store in
            await store.performCloseSession(sessionID, reason: reason)
        }
    }

    private func performCloseSession(
        _ sessionID: String,
        reason: ReviewCancellation
    ) async {
        closedSessions.insert(sessionID)
        for jobID in activeJobIDs(for: sessionID) {
            _ = try? await performCancelReview(jobID: jobID, cancellation: reason)
        }
    }

    package func closeActiveReviewSessions(reason: ReviewCancellation) async {
        await performRegisteredStoreWork(
            kind: .reviewMutation("close-active-sessions")
        ) { @MainActor store in
            let jobIDs = store.orderedJobs
                .filter { $0.isTerminal == false }
                .map(\.id)
            for jobID in jobIDs {
                _ = try? await store.performCancelReview(
                    jobID: jobID,
                    cancellation: reason
                )
            }
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

    private func consumeReviewEvents(
        for initialAttempt: BackendReviewAttempt,
        job: CodexReviewJob,
        startRequest: CodexReviewBackendModel.Review.Start
    ) async throws -> CodexReviewBackendModel.Review.Run {
        let inputs = await reviewWorkerInputs(for: initialAttempt)
        do {
            let result = try await consumeReviewEvents(
                inputs: inputs,
                initialAttempt: initialAttempt,
                job: job,
                startRequest: startRequest
            )
            await inputs.cancelAndWait()
            return result
        } catch {
            await inputs.cancelAndWait()
            throw error
        }
    }

    private func consumeReviewEvents(
        inputs: ReviewWorkerInputs,
        initialAttempt: BackendReviewAttempt,
        job: CodexReviewJob,
        startRequest: CodexReviewBackendModel.Review.Start
    ) async throws -> CodexReviewBackendModel.Review.Run {
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
                    sourceRun: event.subscriptionRun,
                    currentRun: recoveryState.currentRun
                )
                if job.isTerminal {
                    return recoveryState.currentRun
                }
            case .reviewEventsFinished(let finishedRun):
                guard activeEventSubscriptionID == finishedRun.subscriptionID,
                      activeRuns[job.id] == finishedRun.run
                else {
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
                      recoveryState.shouldConsumeEvent(from: failedRun.run),
                      activeRuns[job.id] == failedRun.run
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
                    recoveryToken: recoveryState.recoveryToken
                ) {
                case .continueWaiting:
                    recoveryState.markWaitingForNetworkRecovery()
                    continue
                case .finished:
                    reviewRecoveryWaitingJobIDs.remove(job.id)
                    return recoveryState.currentRun
                case .recovered(let recoveredAttempt):
                    let recoveredRun = recoveredAttempt.run
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
            if completePendingCancellationIfNeeded(for: job) {
                return recoveryState.currentRun
            }
            markReviewFailed(
                job,
                message: ReviewIngestionError.streamEndedWithoutTerminal.localizedDescription
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
            markReviewFailed(
                job,
                message: ReviewIngestionError.streamEndedWithoutTerminal.localizedDescription
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
        recoveryToken: CodexReviewBackendModel.Review.RecoveryToken?
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
            await cleanupReviewAndRetainFailure(recoveredRun, for: job)
            throw CancellationError()
        }

        if job.isTerminal {
            if job.core.lifecycle.status == .cancelled {
                try? await backend.interruptReview(
                    recoveredRun,
                    reason: .init(message: job.core.lifecycle.cancellation?.message ?? "Cancellation requested.")
                )
            }
            await cleanupReviewAndRetainFailure(recoveredRun, for: job)
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
            let primaryError = error
            let cleanupFailure = await cleanupReviewFailure(recoveredRun)
            try? recordCancellationFailure(
                jobID: job.id,
                sessionID: job.sessionID,
                message: primaryError.localizedDescription
            )
            if let cleanupFailure {
                retainCleanupFailure(cleanupFailure, for: job)
            }
            throw primaryError
        }
        await cleanupReviewAndRetainFailure(recoveredRun, for: job)
        return true
    }

    func handleReviewEvent(
        _ event: CodexReviewBackendModel.Review.Event,
        job: CodexReviewJob,
        sourceRun: CodexReviewBackendModel.Review.Run,
        currentRun: CodexReviewBackendModel.Review.Run
    ) -> CodexReviewBackendModel.Review.Run {
        guard activeRuns[job.id] == sourceRun else {
            return currentRun
        }
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
            clearPendingCancellationProjection(for: job)
            completeReview(job, summary: summary, result: result)
        case .failed(let message):
            clearPendingCancellationProjection(for: job)
            markReviewFailed(job, message: message)
        case .cancelled(let message):
            if job.cancellationRequested,
               let cancellation = job.core.lifecycle.cancellation {
                try? completeCancellationLocally(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    cancellation: cancellation
                )
            } else {
                clearPendingCancellationProjection(for: job)
                markReviewInterrupted(
                    job,
                    cause: .server(message: message?.nilIfEmpty)
                )
            }
        }
        writeDiagnosticsIfNeeded()
        return updatedRun
    }

    private func clearPendingCancellationProjection(for job: CodexReviewJob) {
        job.cancellationRequested = false
        job.core.lifecycle.cancellation = nil
        job.core.lifecycle.errorMessage = nil
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
        guard isReviewResultFinalized(jobID: jobID) == false else {
            return
        }
        let waiterID = UUID()
        let timeoutTask = timeout.flatMap { duration in
            startRegisteredStoreWork(
                kind: .reviewWaiter(jobID: jobID)
            ) { @MainActor [weak self] _ in
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
                if isReviewResultFinalized(jobID: jobID) {
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
        guard isReviewResultFinalized(jobID: jobID) else {
            return
        }
        let waiters = reviewTerminalWaiters.removeValue(forKey: jobID) ?? []
        for waiter in waiters {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume()
        }
    }

    private func isReviewResultFinalized(jobID: String) -> Bool {
        guard let job = job(id: jobID) else {
            return true
        }
        guard job.isTerminal else {
            return false
        }
        // Terminal state is published before backend cleanup. The live worker remains the
        // result owner until cleanup and any secondary diagnostic are finalized. Runtime-stop
        // detachment is the explicit boundary that transfers only lifecycle cleanup ownership.
        return reviewWorkerTasks[jobID] == nil
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

private extension CodexReviewJob {
    var backendRun: CodexReviewBackendModel.Review.Run? {
        guard let threadID = core.run.threadID else {
            return nil
        }
        return .init(
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

    func cancelAndWait() async {
        networkTask.cancel()
        await eventSource.cancelAndWait()
        await signalCoordinator.cancelAndWait()
        await queue.finish()
        await networkTask.value
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

    func subscribe(to attempt: BackendReviewAttempt) async -> Int {
        subscriptionID += 1
        let subscriptionID = subscriptionID
        activeSubscriptionID = subscriptionID
        await cancelEventTasksAndWait()
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

    func cancelActiveSubscription() async {
        subscriptionID += 1
        activeSubscriptionID = nil
        await cancelEventTasksAndWait()
    }

    func cancelAndWait() async {
        subscriptionID += 1
        activeSubscriptionID = nil
        await cancelEventTasksAndWait()
    }

    private func cancelEventTasksAndWait() async {
        let tasks = eventTasks.sorted { $0.key < $1.key }.map(\.value)
        eventTasks.removeAll(keepingCapacity: true)
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
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
    private var admissionIsOpen = true
    private var nextTaskID = 0
    private var ownedTasks: [Int: Task<Void, Never>] = [:]
    private var outageTaskID: Int?
    private var outageGeneration = 0
    private var recoveryTaskID: Int?
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
        guard admissionIsOpen else {
            return
        }
        await tracker.update(snapshot)
        guard admissionIsOpen else {
            return
        }
        switch snapshot.status {
        case .satisfied:
            outageGeneration += 1
            cancelOwnedTask(outageTaskID)
            outageTaskID = nil
            recoveryGeneration += 1
            let recoveryGeneration = recoveryGeneration
            cancelOwnedTask(recoveryTaskID)
            recoveryTaskID = nil
            await queue.send(.networkSnapshot(snapshot, recoveryGeneration: recoveryGeneration))
            scheduleRecoveryConfirmationIfNeeded(generation: recoveryGeneration)
        case .unsatisfied, .requiresConnection:
            recoveryGeneration += 1
            let recoveryGeneration = recoveryGeneration
            cancelOwnedTask(recoveryTaskID)
            recoveryTaskID = nil
            await queue.send(.networkSnapshot(snapshot, recoveryGeneration: recoveryGeneration))
            scheduleOutageConfirmationIfNeeded()
        }
    }

    func cancelAndWait() async {
        admissionIsOpen = false
        outageGeneration += 1
        recoveryGeneration += 1
        outageTaskID = nil
        recoveryTaskID = nil
        let tasks = ownedTasks.sorted { $0.key < $1.key }.map(\.value)
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
        ownedTasks.removeAll(keepingCapacity: false)
    }

    private func scheduleOutageConfirmationIfNeeded() {
        guard admissionIsOpen, outageTaskID == nil else {
            return
        }
        let policy = policy
        outageGeneration += 1
        let generation = outageGeneration
        nextTaskID += 1
        let taskID = nextTaskID
        let task = Task {
            do {
                try await policy.sleep(policy.outageDebounce)
            } catch {
                self.finishOwnedTask(taskID)
                return
            }
            await self.confirmOutageIfCurrent(generation: generation)
            self.finishOwnedTask(taskID)
        }
        ownedTasks[taskID] = task
        outageTaskID = taskID
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
        guard admissionIsOpen, recoveryTaskID == nil else {
            return
        }
        let policy = policy
        nextTaskID += 1
        let taskID = nextTaskID
        let task = Task {
            do {
                try await policy.sleep(policy.recoverySettle)
            } catch {
                self.finishOwnedTask(taskID)
                return
            }
            await self.confirmRecoveryIfCurrent(generation: generation)
            self.finishOwnedTask(taskID)
        }
        ownedTasks[taskID] = task
        recoveryTaskID = taskID
    }

    private func confirmRecoveryIfCurrent(generation: Int) async {
        guard generation == recoveryGeneration else {
            return
        }
        let latest = await tracker.latestSnapshot()
        guard latest.status == .satisfied else {
            return
        }
        await queue.send(.networkRecoverySettled(recoveryGeneration: generation))
    }

    private func cancelOwnedTask(_ taskID: Int?) {
        guard let taskID else {
            return
        }
        ownedTasks[taskID]?.cancel()
    }

    private func finishOwnedTask(_ taskID: Int) {
        ownedTasks.removeValue(forKey: taskID)
        if outageTaskID == taskID {
            outageTaskID = nil
        }
        if recoveryTaskID == taskID {
            recoveryTaskID = nil
        }
    }
}
