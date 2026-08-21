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
        let jobID = try await beginReview(sessionID: sessionID, request: request)
        // Caller Task cancellation is not a review-cancellation command: only the
        // attempt admission can distinguish not-sent from outcome-unknown dispatch.
        // Session owners must use cancelReview/closeSession so the canonical barrier drains.
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
        let jobID = try await beginReview(sessionID: sessionID, request: request)
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
    ) async throws -> String {
        guard case .open = lifetimeState else {
            throw CodexReviewAPI.Error.io("Review Store is closed.")
        }
        nextReviewMutationID &+= 1
        let mutationID = nextReviewMutationID
        let runtimeGeneration = runtimeState.generation
        let task = Task<String, any Error> { @MainActor [weak self] in
            guard let self else {
                throw CodexReviewAPI.Error.io("Review Store was released.")
            }
            return try await self.performBeginReview(
                sessionID: sessionID,
                request: request,
                runtimeGeneration: runtimeGeneration
            )
        }
        reviewMutationTasks[mutationID] = task
        defer {
            reviewMutationTasks.removeValue(forKey: mutationID)
        }
        return try await task.value
    }

    private func performBeginReview(
        sessionID: String,
        request: CodexReviewAPI.Start.Request,
        runtimeGeneration: ReviewRuntimeGeneration
    ) async throws -> String {
        guard case .open = lifetimeState else {
            throw CodexReviewAPI.Error.io("Review Store is closed.")
        }
        switch runtimeState {
        case .acquiring, .transitioning:
            throw CodexReviewAPI.Error.io(
                "Review runtime transition is in progress."
            )
        case .failed:
            throw CodexReviewAPI.Error.io("Review runtime is not running.")
        case .stopped, .running:
            break
        }
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
        let admission = ReviewStartAdmission(closePolicy: reviewRuntimeClosePolicy)
        let startRequest = CodexReviewBackendModel.Review.Start(
            jobID: jobID,
            sessionID: sessionID,
            request: validatedRequest,
            model: settings.effectiveModel
        )
        let backend = self.backend
        await reviewMutationPreparationForTesting?()
        let registered = try await admission.registerStart { admission in
            try await backend.startReview(startRequest, admission: admission)
        }
        guard isReviewMutationCurrent(runtimeGeneration) else {
            _ = try? await cancel(
                admission: admission,
                cancellation: .system(message: "Review Store closed."),
                jobID: jobID
            )
            _ = await registered.task.result
            throw CodexReviewAPI.Error.io(
                "Review runtime changed before review publication."
            )
        }
        insertReviewJob(job)
        markReviewRunning(job, startedAt: createdAt)
        reviewAttemptOwnerships[jobID] = .initialStart(registered)
        launchReviewWorker(
            jobID: jobID,
            startRequest: startRequest,
            registeredStart: registered,
            runtimeGeneration: runtimeGeneration
        )
        return jobID
    }

    private func isReviewMutationCurrent(
        _ generation: ReviewRuntimeGeneration
    ) -> Bool {
        guard case .open = lifetimeState else {
            return false
        }
        switch runtimeState {
        case .stopped(let currentGeneration),
             .running(let currentGeneration, _, _):
            return currentGeneration == generation
        case .acquiring, .transitioning, .failed:
            return false
        }
    }

    private func launchReviewWorker(
        jobID: String,
        startRequest: CodexReviewBackendModel.Review.Start,
        registeredStart: ReviewRegisteredStart,
        runtimeGeneration: ReviewRuntimeGeneration
    ) {
        reviewWorkerTasks[jobID]?.cancel()
        reviewWorkerTasks[jobID] = Task { [weak self] in
            await self?.runReviewWorker(
                jobID: jobID,
                startRequest: startRequest,
                registeredStart: registeredStart,
                runtimeGeneration: runtimeGeneration
            )
        }
    }

    private func runReviewWorker(
        jobID: String,
        startRequest: CodexReviewBackendModel.Review.Start,
        registeredStart: ReviewRegisteredStart,
        runtimeGeneration: ReviewRuntimeGeneration
    ) async {
        guard let job = job(id: jobID) else {
            reviewAttemptOwnerships.removeValue(forKey: jobID)
            reviewWorkerTasks.removeValue(forKey: jobID)
            resumeReviewWaiters(for: jobID)
            return
        }
        var cleanupAttempt: ReviewActiveAttempt?
        do {
            try await registeredStart.admission.activateStart(registeredStart.id)
            let backendAttempt = try await registeredStart.task.value
            guard case .initialStart(let currentStart) = reviewAttemptOwnerships[jobID],
                  currentStart.id == registeredStart.id
            else {
                throw ReviewAttemptContractFailure(
                    message: "Initial review start completed after its ownership changed."
                )
            }
            let active = ReviewActiveAttempt(
                run: backendAttempt.run,
                admission: registeredStart.admission
            )
            reviewAttemptOwnerships[jobID] = .active(active)
            cleanupAttempt = active
            applyBackendRun(backendAttempt.run, to: job)

            if job.isTerminal == false {
                let completion = try await consumeReviewEvents(
                    for: backendAttempt,
                    job: job,
                    startRequest: startRequest,
                    runtimeGeneration: runtimeGeneration
                )
                cleanupAttempt = completion.cleanupAttempt
            }
        } catch let cancellation as ReviewStartCancelledBeforeDispatch {
            if job.isTerminal == false {
                do {
                    try completeCancellationLocally(
                        jobID: job.id,
                        sessionID: job.sessionID,
                        cancellation: cancellation.cancellation
                    )
                } catch {
                    markReviewFailed(job, message: error.localizedDescription)
                }
            }
        } catch let error where error is CancellationError || Task.isCancelled {
            if let active = activeAttemptForCleanup(jobID: jobID) ?? cleanupAttempt {
                cleanupAttempt = active
                let failure = ReviewRuntimeCloseFailure.worker(
                    "Review worker was cancelled before a canonical terminal."
                )
                if job.isTerminal == false {
                    retainCleanupFailure(failure, for: jobID)
                }
                do {
                    try await active.admission.recordStreamTerminal(.ownerCancellation)
                } catch {
                    markReviewFailed(job, message: error.localizedDescription)
                }
                if job.isTerminal == false {
                    markReviewInterrupted(job, cause: .transport(message: failure.localizedDescription))
                }
            } else if job.isTerminal == false {
                markReviewFailed(job, message: error.localizedDescription)
            }
        } catch {
            if let active = activeAttemptForCleanup(jobID: jobID) ?? cleanupAttempt {
                cleanupAttempt = active
            }
            if job.isTerminal == false,
               let streamFailure = error as? ReviewAttemptStreamFailure {
                if let cleanupAttempt {
                    do {
                        try await cleanupAttempt.admission.recordStreamTerminal(streamFailure)
                    } catch {
                        markReviewFailed(job, message: error.localizedDescription)
                    }
                }
                await reviewTerminalPublicationPreparationForTesting?()
                await applyStreamProductTerminal(streamFailure, to: job)
            } else if job.isTerminal == false {
                markReviewFailed(job, message: error.localizedDescription)
            }
        }

        reviewAttemptOwnerships[jobID] = .terminal
        if let cleanupAttempt {
            await reviewCleanupPreparationForTesting?()
            do {
                try await cleanupReview(
                    cleanupAttempt.run,
                    admission: cleanupAttempt.admission
                )
            } catch {
                retainCleanupFailure(error, for: jobID)
            }
        }
        reviewWorkerTasks.removeValue(forKey: jobID)
        if case .terminal = reviewAttemptOwnerships[jobID] {
            reviewAttemptOwnerships.removeValue(forKey: jobID)
        }
        if job.isTerminal {
            resumeReviewWaiters(for: jobID)
        }
    }

    private func activeAttemptForCleanup(jobID: String) -> ReviewActiveAttempt? {
        switch reviewAttemptOwnerships[jobID] {
        case .active(let active), .resolvingRecovery(let active):
            active
        case .initialStart, .recoveryDisposition, .preparingRecovery,
             .waitingForRecovery, .replacementStart, .terminal, nil:
            nil
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

    private func reviewWorkerInputs(
        for attempt: BackendReviewAttempt,
        owner: ReviewActiveAttempt,
        jobID: String,
        runtimeGeneration: ReviewRuntimeGeneration
    ) async -> ReviewWorkerInputs {
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
        let recoveryInterruptionSource = ReviewWorkerRecoveryInterruptionSource(queue: queue)
        let runtimeWorkerRegistrationID = runtimeWorkerRegistry.register(
            jobID: jobID,
            attemptID: owner.run.attemptID,
            runtimeGeneration: runtimeGeneration,
            recoverySource: recoveryInterruptionSource
        )
        let networkTask = Task {
            for await snapshot in snapshots {
                await signalCoordinator.observe(snapshot)
            }
        }
        let initialEventSubscriptionID = await eventSource.subscribe(
            to: attempt,
            owner: owner
        )
        return .init(
            queue: queue,
            networkStatusTracker: tracker,
            eventSource: eventSource,
            recoveryInterruptionSource: recoveryInterruptionSource,
            runtimeWorkerRegistry: runtimeWorkerRegistry,
            runtimeWorkerRegistrationID: runtimeWorkerRegistrationID,
            jobID: jobID,
            initialRuntimeGeneration: runtimeGeneration,
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

        job.cancellationRequested = true
        job.core.lifecycle.cancellation = cancellation
        job.core.output.summary = cancellation.message
        job.core.lifecycle.errorMessage = cancellation.message
        do {
            try await cancelOwnedReviewAttempt(
                job: job,
                cancellation: cancellation
            )
        } catch {
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

    private func cancelOwnedReviewAttempt(
        job: CodexReviewJob,
        cancellation: ReviewCancellation
    ) async throws {
        let jobID = job.id
        guard let ownership = reviewAttemptOwnerships[jobID] else {
            throw ReviewAttemptContractFailure(
                message: "Nonterminal review \(jobID) has no attempt ownership."
            )
        }
        switch ownership {
        case .initialStart(let start):
            let resolution = try await cancel(
                admission: start.admission,
                cancellation: cancellation,
                jobID: jobID
            )
            if case .localCancellation = resolution.terminal,
               job.isTerminal == false {
                try finishOwnedCancellation(job: job, cancellation: cancellation)
            }
            _ = await start.task.result
            await reviewWorkerTasks[jobID]?.value
            removeTerminalOwnershipWithoutWorker(jobID: jobID)
            try await rethrowCleanupFailureIfPresent(
                admission: start.admission,
                run: job.backendRun
            )
        case .active(let active):
            let resolution = try await cancel(
                admission: active.admission,
                cancellation: cancellation,
                jobID: jobID
            )
            try commitAcknowledgedForcedCancellationIfNeeded(
                resolution,
                job: job,
                cancellation: cancellation
            )
            await reviewWorkerTasks[jobID]?.value
            try await rethrowCleanupFailureIfPresent(
                admission: active.admission,
                run: active.run
            )
        case .resolvingRecovery(let active):
            _ = try await cancel(
                admission: active.admission,
                cancellation: cancellation,
                jobID: jobID
            )
            if case .resolvingRecovery(let current) = reviewAttemptOwnerships[jobID],
               sameAttempt(current, active),
               let disposition = await active.admission.recoveryDispositionIfInstalled() {
                if disposition.isNaturalCanonicalProductTerminal {
                    await reviewWorkerTasks[jobID]?.value
                    return
                }
                reviewAttemptOwnerships[jobID] = .recoveryDisposition(disposition)
            }
            try await suppressRecoverySuccessor(
                job: job,
                cancellation: cancellation
            )
            await reviewWorkerTasks[jobID]?.value
        case .recoveryDisposition(let disposition):
            try finishRecoveryDispositionForCancellation(
                disposition,
                job: job,
                cancellation: cancellation
            )
            reviewWorkerTasks[jobID]?.cancel()
            await reviewWorkerTasks[jobID]?.value
        case .preparingRecovery, .waitingForRecovery:
            try await suppressRecoverySuccessor(
                job: job,
                cancellation: cancellation
            )
            await reviewWorkerTasks[jobID]?.value
            if let cleanupFailure = reviewCleanupFailures[jobID] {
                throw cleanupFailure
            }
        case .replacementStart(_, let start):
            let resolution = try await cancel(
                admission: start.admission,
                cancellation: cancellation,
                jobID: jobID
            )
            if case .localCancellation = resolution.terminal,
               job.isTerminal == false {
                try finishOwnedCancellation(job: job, cancellation: cancellation)
            }
            _ = await start.task.result
            await reviewWorkerTasks[jobID]?.value
            removeTerminalOwnershipWithoutWorker(jobID: jobID)
        case .terminal:
            guard job.isTerminal else {
                throw ReviewAttemptContractFailure(
                    message: "Terminal attempt ownership has a nonterminal product review."
                )
            }
        }
    }

    private func cancel(
        admission: ReviewStartAdmission,
        cancellation: ReviewCancellation,
        jobID: String
    ) async throws -> ReviewAttemptCancellationResolution {
        let backend = self.backend
        return try await admission.cancel(
            cancellation,
            interrupt: { run, reason in
                try await backend.interruptReview(
                    run,
                    admission: admission,
                    reason: reason
                )
            },
            forceClose: { @MainActor [weak self] in
                guard let self else {
                    throw ReviewRuntimeCloseFailure.connection(
                        "Review Store was released before runtime force-close."
                    )
                }
                try await self.forceCloseCurrentRuntimeForAttempt(
                    jobID: jobID,
                    trigger: .explicitCancellation(targetJobID: jobID)
                )
            }
        )
    }

    package func makeRuntimeRecoveryReplacement(
        sourceGeneration: ReviewRuntimeGeneration,
        replacementGeneration: ReviewRuntimeGeneration,
        sourceRuntime: PreparedRuntime?,
        retainedMCPGeneration: MCPServerGeneration,
        retainedServerURL: URL?,
        trigger: ReviewRuntimeRecoveryReplacement.Trigger
    ) -> ReviewRuntimeRecoveryReplacement {
        let participants: [ReviewRuntimeReplacementParticipant] = reviewRegistrationOrder.compactMap { jobID in
            guard jobID != trigger.targetJobID,
                  let job = job(id: jobID),
                  job.isTerminal == false,
                  job.cancellationRequested == false
            else {
                return nil
            }
            let active: ReviewActiveAttempt
            switch reviewAttemptOwnerships[jobID] {
            case .active(let current):
                active = current
            case .resolvingRecovery(let current):
                guard case .recoverableNetwork(let initiatingJobID) = trigger,
                      initiatingJobID == jobID
                else {
                    return nil
                }
                active = current
            case .initialStart, .recoveryDisposition, .preparingRecovery,
                 .waitingForRecovery, .replacementStart, .terminal, nil:
                return nil
            }
            return runtimeWorkerRegistry.participant(
                jobID: jobID,
                attemptID: active.run.attemptID,
                sourceGeneration: sourceGeneration
            )
        }
        let replacement = ReviewRuntimeRecoveryReplacement(
            sourceGeneration: sourceGeneration,
            replacementGeneration: replacementGeneration,
            sourceRuntime: sourceRuntime,
            retainedMCPGeneration: retainedMCPGeneration,
            retainedServerURL: retainedServerURL,
            trigger: trigger,
            participants: participants
        )
        return replacement
    }

    package func enrollRuntimeReplacementParticipants(
        _ replacement: ReviewRuntimeRecoveryReplacement
    ) async {
        let backend = self.backend
        for participant in replacement.participants {
            guard let job = job(id: participant.jobID),
                  job.isTerminal == false,
                  job.cancellationRequested == false
            else {
                runtimeWorkerRegistry.suppressParticipant(
                    participant,
                    in: replacement
                )
                continue
            }
            let active: ReviewActiveAttempt
            switch reviewAttemptOwnerships[participant.jobID] {
            case .active(let current) where current.run.attemptID == participant.attemptID:
                active = current
                reviewAttemptOwnerships[participant.jobID] = .resolvingRecovery(current)
            case .resolvingRecovery(let current) where current.run.attemptID == participant.attemptID:
                active = current
            default:
                runtimeWorkerRegistry.suppressParticipant(
                    participant,
                    in: replacement
                )
                continue
            }
            let recoveryTrigger: ReviewAttemptRecoveryTrigger = if case .recoverableNetwork(
                let initiatingJobID
            ) = replacement.trigger, initiatingJobID == participant.jobID {
                .recoverableNetworkLoss
            } else {
                .sameAccountRestart
            }
            let didInstall = await runtimeWorkerRegistry.beginRecovery(
                replacement: replacement,
                participant: participant,
                owner: active,
                trigger: recoveryTrigger,
                interrupt: { run, reason in
                    try await backend.interruptReview(
                        run,
                        admission: active.admission,
                        reason: reason
                    )
                },
                forceClose: {
                    try await replacement.waitForSourceClose().get()
                }
            )
            if didInstall == false {
                if case .resolvingRecovery(let current) = reviewAttemptOwnerships[participant.jobID],
                   sameAttempt(current, active) {
                    reviewAttemptOwnerships[participant.jobID] = .active(active)
                }
                runtimeWorkerRegistry.suppressParticipant(
                    participant,
                    in: replacement
                )
            }
        }
    }

    private func forceCloseCurrentRuntimeForAttempt(
        jobID: String,
        trigger: ReviewRuntimeRecoveryReplacement.Trigger
    ) async throws {
        if case .open = lifetimeState,
           case .running(
            let generation,
            let runtime,
            let mcpGeneration
           ) = runtimeState {
            serverState = .starting
            writeDiagnosticsIfNeeded()
            let (replacement, _) = installRuntimeReplacement(
                previousGeneration: generation,
                sourceRuntime: runtime,
                retainedMCPGeneration: mcpGeneration,
                retainedServerURL: serverURL,
                trigger: trigger,
                purpose: .recoveryReplacement
            )
            let sourceCloseResult = await replacement.waitForSourceClose()
            await runtimeForceCloseReceiptRecordedForTesting?()
            try sourceCloseResult.get()
            return
        }

        if case .transitioning(
            _,
            let purpose,
            _,
            _,
            _,
            let replacement?
        ) = runtimeState,
           purpose == .recoveryReplacement || purpose == .restartSameAccount {
            if case .explicitCancellation = trigger {
                runtimeWorkerRegistry.suppressParticipant(
                    jobID: jobID,
                    in: replacement
                )
            }
            let sourceCloseResult = await replacement.waitForSourceClose()
            await runtimeForceCloseReceiptRecordedForTesting?()
            try sourceCloseResult.get()
            return
        }

        let runtime: PreparedRuntime
        let record: ReviewRuntimeTransitionRecord
        switch runtimeState {
        case .running(_, let runningRuntime, _):
            runtime = runningRuntime
            record = ReviewRuntimeTransitionRecord()
        case .transitioning(_, _, _, let transitionRecord, let sourceRuntime?, _):
            runtime = sourceRuntime
            record = transitionRecord
        case .stopped, .acquiring, .failed, .transitioning:
            throw ReviewRuntimeCloseFailure.connection(
                "Review runtime is not running."
            )
        }
        await runtime.handle.closeAdmission()
        let closeResult = await runtime.closeRecord.closeAndWait(
            handle: runtime.handle,
            purpose: .recoveryReplacement
        )
        let consumedFailures = runtime.closeRecord.consumeFailures()
        if let applicationCloseFailureLedger {
            applicationCloseFailureLedger.recordForceCloseFailures(
                consumedFailures,
                jobID: jobID
            )
        } else {
            record.recordForceCloseFailures(consumedFailures, jobID: jobID)
        }
        await runtimeForceCloseReceiptRecordedForTesting?()
        if let firstFailure = closeResult.failures.first {
            switch firstFailure {
            case .attemptRuntime(let failure):
                throw failure
            case .lifecycleResources(let failure):
                throw failure
            case .interruptRequest(let failure):
                throw ReviewRuntimeCloseFailure.connection(failure.localizedDescription)
            case .persistence(let failure):
                throw ReviewRuntimeCloseFailure.connection(failure.localizedDescription)
            }
        }
    }

    private func suppressRecoverySuccessor(
        job: CodexReviewJob,
        cancellation: ReviewCancellation
    ) async throws {
        switch reviewAttemptOwnerships[job.id] {
        case .resolvingRecovery:
            throw ReviewAttemptContractFailure(
                message: "Recovery cancellation completed before disposition installation."
            )
        case .recoveryDisposition(let disposition):
            try finishRecoveryDispositionForCancellation(
                disposition,
                job: job,
                cancellation: cancellation
            )
            reviewWorkerTasks[job.id]?.cancel()
        case .preparingRecovery(_, let task):
            try finishOwnedCancellation(job: job, cancellation: cancellation)
            task.cancel()
            _ = await task.result
            reviewWorkerTasks[job.id]?.cancel()
        case .waitingForRecovery:
            try finishOwnedCancellation(job: job, cancellation: cancellation)
            reviewWorkerTasks[job.id]?.cancel()
        case .replacementStart(_, let start):
            let resolution = try await cancel(
                admission: start.admission,
                cancellation: cancellation,
                jobID: job.id
            )
            if case .localCancellation = resolution.terminal,
               job.isTerminal == false {
                try finishOwnedCancellation(job: job, cancellation: cancellation)
            }
            _ = await start.task.result
            await reviewWorkerTasks[job.id]?.value
        case .active(let active):
            let resolution = try await cancel(
                admission: active.admission,
                cancellation: cancellation,
                jobID: job.id
            )
            try commitAcknowledgedForcedCancellationIfNeeded(
                resolution,
                job: job,
                cancellation: cancellation
            )
            await reviewWorkerTasks[job.id]?.value
        case .initialStart(let start):
            let resolution = try await cancel(
                admission: start.admission,
                cancellation: cancellation,
                jobID: job.id
            )
            if case .localCancellation = resolution.terminal,
               job.isTerminal == false {
                try finishOwnedCancellation(job: job, cancellation: cancellation)
            }
            _ = await start.task.result
            await reviewWorkerTasks[job.id]?.value
        case .terminal:
            return
        case nil:
            throw ReviewAttemptContractFailure(
                message: "Recovery cancellation lost attempt ownership."
            )
        }
    }

    private func finishOwnedCancellation(
        job: CodexReviewJob,
        cancellation: ReviewCancellation
    ) throws {
        try completeCancellationLocally(
            jobID: job.id,
            sessionID: job.sessionID,
            cancellation: cancellation
        )
        reviewAttemptOwnerships[job.id] = .terminal
    }

    private func commitAcknowledgedForcedCancellationIfNeeded(
        _ resolution: ReviewAttemptCancellationResolution,
        job: CodexReviewJob,
        cancellation: ReviewCancellation
    ) throws {
        guard job.isTerminal == false,
              resolution.requestFailure == nil,
              case .stream(.ownerForcedConnectionClose) = resolution.terminal
        else {
            return
        }
        try finishOwnedCancellation(job: job, cancellation: cancellation)
    }

    private func finishRecoveryDispositionForCancellation(
        _ disposition: ReviewRecoveryDisposition,
        job: CodexReviewJob,
        cancellation: ReviewCancellation
    ) throws {
        switch disposition {
        case .productTerminal(let product):
            try applyRecoveryProductTerminal(product.productTerminal, to: job)
            reviewAttemptOwnerships[job.id] = .terminal
        case .replacement:
            try finishOwnedCancellation(job: job, cancellation: cancellation)
        }
    }

    private func rethrowCleanupFailureIfPresent(
        admission: ReviewStartAdmission,
        run: CodexReviewBackendModel.Review.Run?
    ) async throws {
        guard let run,
              let cleanupResult = await admission.recordedCleanupResult(for: run)
        else {
            return
        }
        try cleanupResult.get()
    }

    private func removeTerminalOwnershipWithoutWorker(jobID: String) {
        guard reviewWorkerTasks[jobID] == nil,
              case .terminal = reviewAttemptOwnerships[jobID]
        else {
            return
        }
        reviewAttemptOwnerships.removeValue(forKey: jobID)
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

    package func closeActiveReviewSessions(reason: ReviewCancellation) async throws {
        let jobIDs = orderedJobs
            .filter { $0.isTerminal == false }
            .map(\.id)
        var firstError: (any Error)?
        for jobID in jobIDs {
            do {
                _ = try await cancelReview(jobID: jobID, cancellation: reason)
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
        if reviewRegistrationOrder.contains(job.id) == false {
            reviewRegistrationOrder.append(job.id)
        }
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
        startRequest: CodexReviewBackendModel.Review.Start,
        runtimeGeneration: ReviewRuntimeGeneration
    ) async throws -> ReviewWorkerAttemptCompletion {
        guard case .active(let initialActive) = reviewAttemptOwnerships[job.id],
              sameAttempt(initialActive, run: initialAttempt.run)
        else {
            throw ReviewAttemptContractFailure(
                message: "Initial event subscription requires the published active attempt."
            )
        }
        let inputs = await reviewWorkerInputs(
            for: initialAttempt,
            owner: initialActive,
            jobID: job.id,
            runtimeGeneration: runtimeGeneration
        )
        guard case .active(let revalidatedActive) = reviewAttemptOwnerships[job.id],
              sameAttempt(revalidatedActive, initialActive)
        else {
            await inputs.cancel()
            throw ReviewAttemptContractFailure(
                message: "Initial event subscription became stale before publication completed."
            )
        }
        do {
            let completion = try await consumeReviewEventLoop(
                job: job,
                startRequest: startRequest,
                inputs: inputs,
                initialCleanupAttempt: initialActive
            )
            await inputs.cancel()
            return completion
        } catch {
            if error is CancellationError || Task.isCancelled {
                if let active = activeAttemptForCleanup(jobID: job.id) {
                    try await active.admission.recordStreamTerminal(.ownerCancellation)
                }
            }
            await inputs.cancel()
            throw error
        }
    }

    private func consumeReviewEventLoop(
        job: CodexReviewJob,
        startRequest: CodexReviewBackendModel.Review.Start,
        inputs: ReviewWorkerInputs,
        initialCleanupAttempt: ReviewActiveAttempt
    ) async throws -> ReviewWorkerAttemptCompletion {
        var recoverySignals = ReviewNetworkRecoverySignals()
        var activeEventSubscriptionID: Int? = inputs.initialEventSubscriptionID
        var cleanupAttempt = initialCleanupAttempt
        var activeRuntimeGeneration = inputs.initialRuntimeGeneration
        while let input = await inputs.next() {
            if job.isTerminal {
                return .init(cleanupAttempt: cleanupAttempt)
            }
            switch input {
            case .reviewEvent(let event):
                guard activeEventSubscriptionID == event.subscriptionID,
                      let routed = routedAttempt(
                        jobID: job.id,
                        owner: event.owner
                      )
                else {
                    continue
                }
                if let terminal = reviewTerminalRecord(for: event.event, job: job) {
                    try await routed.active.admission.recordCanonicalTerminal(
                        terminal,
                        for: event.owner.run
                    )
                }
                if routed.isResolvingRecovery {
                    guard event.event.supersedesNetworkRecovery else {
                        continue
                    }
                }
                _ = handleReviewEvent(
                    event.event,
                    job: job,
                    currentRun: routed.active.run
                )
                if job.isTerminal {
                    return .init(cleanupAttempt: routed.active)
                }
            case .reviewEventsFinished(let finishedRun):
                guard activeEventSubscriptionID == finishedRun.subscriptionID,
                      let routed = routedAttempt(jobID: job.id, owner: finishedRun.owner)
                else {
                    continue
                }
                let failure = ReviewAttemptStreamFailure.workerContract(.init(
                    message: ReviewIngestionError.streamEndedWithoutTerminal.localizedDescription
                ))
                try await routed.active.admission.recordStreamTerminal(failure)
                if routed.isResolvingRecovery {
                    activeEventSubscriptionID = nil
                    continue
                }
                await reviewTerminalPublicationPreparationForTesting?()
                if let productTerminal = await routed.active.admission
                    .terminalCancellationProductTerminal(for: failure) {
                    try applyRecoveryProductTerminal(productTerminal, to: job)
                } else {
                    await applyStreamProductTerminal(failure, to: job)
                }
                return .init(cleanupAttempt: routed.active)
            case .reviewEventsFailed(let failedRun):
                guard activeEventSubscriptionID == failedRun.subscriptionID,
                      let routed = routedAttempt(jobID: job.id, owner: failedRun.owner)
                else {
                    continue
                }
                if routed.isResolvingRecovery {
                    try await routed.active.admission.recordStreamTerminal(failedRun.failure)
                    activeEventSubscriptionID = nil
                    continue
                }
                if case .recoverableNetwork = failedRun.failure,
                   await inputs.networkStatusTracker.currentStatus() != .satisfied {
                    recoverySignals.recordPendingOutageStreamFailure(
                        failedRun.failure,
                        attemptID: routed.active.run.attemptID
                    )
                    activeEventSubscriptionID = nil
                    await inputs.cancelActiveEventSubscription()
                    continue
                }
                try await routed.active.admission.recordStreamTerminal(failedRun.failure)
                await reviewTerminalPublicationPreparationForTesting?()
                if let productTerminal = await routed.active.admission
                    .terminalCancellationProductTerminal(for: failedRun.failure) {
                    try applyRecoveryProductTerminal(productTerminal, to: job)
                } else {
                    await applyStreamProductTerminal(failedRun.failure, to: job)
                }
                return .init(cleanupAttempt: routed.active)
            case .recoveryBarrierResolved(let resolution):
                guard case .resolvingRecovery(let resolving) = reviewAttemptOwnerships[job.id],
                      sameAttempt(resolving, resolution.owner)
                else {
                    continue
                }
                switch resolution.result {
                case .failure(let failure):
                    throw failure.underlying
                case .success(let disposition):
                    reviewAttemptOwnerships[job.id] = .recoveryDisposition(disposition)
                    let candidate: ReviewRecoveryCandidate
                    switch disposition {
                    case .productTerminal(let product):
                        try applyRecoveryProductTerminal(product.productTerminal, to: job)
                        return .init(cleanupAttempt: resolving)
                    case .replacement(let replacement):
                        candidate = replacement
                    }
                    let backend = self.backend
                    let preparationTask = Task {
                        try await backend.prepareReviewRecovery(candidate)
                    }
                    reviewAttemptOwnerships[job.id] = .preparingRecovery(
                        candidate: candidate,
                        preparationTask: preparationTask
                    )
                    let preparationResult = await preparationTask.result
                    guard case .preparingRecovery(let currentCandidate, _) = reviewAttemptOwnerships[job.id],
                          currentCandidate == candidate
                    else {
                        if job.isTerminal {
                            return .init(cleanupAttempt: cleanupAttempt)
                        }
                        throw ReviewAttemptContractFailure(
                            message: "Recovery preparation completed after its ownership changed."
                        )
                    }
                    let handoff = try preparationResult.get()
                    reviewAttemptOwnerships[job.id] = .waitingForRecovery(handoff)
                    markReviewWaitingForNetworkRecovery(job)
                    activeEventSubscriptionID = nil
                    await inputs.cancelActiveEventSubscription()
                    guard case .waitingForRecovery(let currentHandoff) = reviewAttemptOwnerships[job.id],
                          currentHandoff == handoff
                    else {
                        if job.isTerminal {
                            return .init(cleanupAttempt: cleanupAttempt)
                        }
                        throw ReviewAttemptContractFailure(
                            message: "Recovery handoff changed while detaching the old subscription."
                        )
                    }
                    if candidate.trigger == .sameAccountRestart {
                        switch try await restartReviewAfterRuntimeRecovery(
                            job: job,
                            startRequest: startRequest,
                            inputs: inputs,
                            handoff: handoff,
                            sourceRuntimeGeneration: activeRuntimeGeneration
                        ) {
                        case .continueWaiting:
                            throw ReviewAttemptContractFailure(
                                message: "Same-account recovery unexpectedly waited for network restoration."
                            )
                        case .finished:
                            return .init(cleanupAttempt: cleanupAttempt)
                        case .recovered(
                            let recoveredAttempt,
                            let active,
                            let runtimeGeneration
                        ):
                            cleanupAttempt = active
                            let subscriptionID = await inputs.subscribe(
                                to: recoveredAttempt,
                                owner: active
                            )
                            guard case .active(let current) = reviewAttemptOwnerships[job.id],
                                  sameAttempt(current, active)
                            else {
                                await inputs.cancelActiveEventSubscription()
                                if job.isTerminal {
                                    return .init(cleanupAttempt: cleanupAttempt)
                                }
                                throw ReviewAttemptContractFailure(
                                    message: "Recovered subscription completed after its active attempt changed."
                                )
                            }
                            activeEventSubscriptionID = subscriptionID
                            activeRuntimeGeneration = runtimeGeneration
                            recoverySignals.markRecovered()
                        }
                    }
                }
            case .networkSnapshot(let snapshot, let recoveryGeneration):
                if let pendingFailure = recoverySignals
                    .takePendingOutageStreamFailureAfterTransientRecovery(snapshot),
                   case .active(let active) = reviewAttemptOwnerships[job.id],
                   active.run.attemptID == pendingFailure.attemptID {
                    throw pendingFailure.failure
                }
                let waitingHandoff: ReviewRecoveryHandoff? = if case .waitingForRecovery(let handoff) = reviewAttemptOwnerships[job.id] {
                    handoff
                } else {
                    nil
                }
                switch recoverySignals.networkSnapshotEffect(
                    snapshot,
                    recoveryGeneration: recoveryGeneration,
                    waitingHandoff: waitingHandoff
                ) {
                case .none:
                    continue
                case .restartSettling:
                    appendRecoveryProgress(networkRecoveryRestoredMessage, to: job)
                }
            case .networkRecoverySettled(let recoveryGeneration):
                guard case .waitingForRecovery(let handoff) = reviewAttemptOwnerships[job.id],
                      recoverySignals.shouldRestartReviewAfterRecoverySettle(
                        recoveryGeneration: recoveryGeneration,
                        handoff: handoff
                      ) else {
                    continue
                }
                runtimeWorkerRegistry.recordNetworkRestoration(
                    registrationID: inputs.runtimeWorkerRegistrationID,
                    jobID: job.id
                )
                switch try await restartReviewAfterRuntimeRecovery(
                    job: job,
                    startRequest: startRequest,
                    inputs: inputs,
                    handoff: handoff,
                    sourceRuntimeGeneration: activeRuntimeGeneration
                ) {
                case .continueWaiting:
                    continue
                case .finished:
                    return .init(cleanupAttempt: cleanupAttempt)
                case .recovered(
                    let recoveredAttempt,
                    let active,
                    let runtimeGeneration
                ):
                    cleanupAttempt = active
                    let subscriptionID = await inputs.subscribe(
                        to: recoveredAttempt,
                        owner: active
                    )
                    guard case .active(let current) = reviewAttemptOwnerships[job.id],
                          sameAttempt(current, active)
                    else {
                        await inputs.cancelActiveEventSubscription()
                        if job.isTerminal {
                            return .init(cleanupAttempt: cleanupAttempt)
                        }
                        throw ReviewAttemptContractFailure(
                            message: "Recovered subscription completed after its active attempt changed."
                        )
                    }
                    activeEventSubscriptionID = subscriptionID
                    activeRuntimeGeneration = runtimeGeneration
                    recoverySignals.markRecovered()
                }
            case .networkOutageConfirmed:
                guard case .active(let active) = reviewAttemptOwnerships[job.id],
                      job.isTerminal == false,
                      job.cancellationRequested == false,
                      await inputs.networkStatusTracker.currentStatus() != .satisfied
                else {
                    continue
                }
                reviewAttemptOwnerships[job.id] = .resolvingRecovery(active)
                let pendingFailure = recoverySignals
                    .takePendingOutageStreamFailureForConfirmedRecovery(
                        attemptID: active.run.attemptID
                    )
                let backend = self.backend
                await inputs.beginRecoveryInterruption(for: active) { [self] in
                    try await active.admission.beginRecovery(
                        trigger: .recoverableNetworkLoss,
                        interrupt: { run, reason in
                            try await backend.interruptReview(
                                run,
                                admission: active.admission,
                                reason: reason
                            )
                        },
                        forceClose: { @MainActor [weak self] in
                            guard let self else {
                                throw ReviewRuntimeCloseFailure.connection(
                                    "Review Store was released before network runtime replacement."
                                )
                            }
                            try await self.forceCloseCurrentRuntimeForAttempt(
                                jobID: job.id,
                                trigger: .recoverableNetwork(initiatingJobID: job.id)
                            )
                        }
                    )
                }
                if let pendingFailure {
                    _ = await active.admission.waitForInterruptionAdmission()
                    guard case .resolvingRecovery(let current) = reviewAttemptOwnerships[job.id],
                          sameAttempt(current, active)
                    else {
                        continue
                    }
                    try await active.admission.recordStreamTerminal(pendingFailure.failure)
                }
            }
        }

        if Task.isCancelled {
            throw CancellationError()
        }
        if job.isTerminal == false,
           case .active(let active) = reviewAttemptOwnerships[job.id] {
            let failure = ReviewAttemptStreamFailure.workerContract(.init(
                message: ReviewIngestionError.streamEndedWithoutTerminal.localizedDescription
            ))
            try await active.admission.recordStreamTerminal(failure)
            await reviewTerminalPublicationPreparationForTesting?()
            if let productTerminal = await active.admission
                .terminalCancellationProductTerminal(for: failure) {
                try applyRecoveryProductTerminal(productTerminal, to: job)
            } else {
                await applyStreamProductTerminal(failure, to: job)
            }
            return .init(cleanupAttempt: active)
        }
        if job.isTerminal {
            return .init(cleanupAttempt: cleanupAttempt)
        }
        throw ReviewAttemptContractFailure(
            message: "Review input queue finished without terminal attempt ownership."
        )
    }

    private func applyRecoveryProductTerminal(
        _ terminal: ReviewTerminalRecord,
        to job: CodexReviewJob
    ) throws {
        switch terminal {
        case .completed:
            if job.isTerminal == false {
                markReviewFailed(
                    job,
                    message: "Canonical completion was not reduced before recovery disposition."
                )
            }
        case .failed(let message):
            markReviewFailed(job, message: message, terminal: terminal)
        case .interrupted(.requested(let cancellation)):
            try completeCancellationLocally(
                jobID: job.id,
                sessionID: job.sessionID,
                cancellation: cancellation
            )
        case .interrupted(let cause):
            markReviewInterrupted(job, cause: cause)
        }
    }

    private func applyStreamProductTerminal(
        _ failure: ReviewAttemptStreamFailure,
        to job: CodexReviewJob
    ) async {
        switch failure {
        case .process:
            markReviewInterrupted(job, cause: .previousProcessExit)
        case .protocolViolation(let failure), .workerContract(let failure):
            markReviewFailed(job, message: failure.localizedDescription)
        case .ownerCancellation:
            markReviewFailed(job, message: failure.localizedDescription)
        case .recoverableNetwork, .ownerForcedConnectionClose,
             .unexpectedConnection:
            markReviewInterrupted(
                job,
                cause: .transport(message: failure.localizedDescription)
            )
        }
    }

    private func routedAttempt(
        jobID: String,
        owner: ReviewActiveAttempt
    ) -> RoutedReviewAttempt? {
        switch reviewAttemptOwnerships[jobID] {
        case .active(let active):
            guard sameAttempt(active, owner) else { return nil }
            return .init(active: active, isResolvingRecovery: false)
        case .resolvingRecovery(let active):
            guard sameAttempt(active, owner) else { return nil }
            return .init(active: active, isResolvingRecovery: true)
        case .initialStart, .recoveryDisposition, .preparingRecovery,
             .waitingForRecovery, .replacementStart, .terminal, nil:
            return nil
        }
    }

    private func sameAttempt(
        _ active: ReviewActiveAttempt,
        run: CodexReviewBackendModel.Review.Run
    ) -> Bool {
        active.run.attemptID == run.attemptID
    }

    private func sameAttempt(
        _ lhs: ReviewActiveAttempt,
        _ rhs: ReviewActiveAttempt
    ) -> Bool {
        lhs.run.attemptID == rhs.run.attemptID
            && lhs.admission === rhs.admission
    }

    private func restartReviewAfterRuntimeRecovery(
        job: CodexReviewJob,
        startRequest: CodexReviewBackendModel.Review.Start,
        inputs: ReviewWorkerInputs,
        handoff: ReviewRecoveryHandoff,
        sourceRuntimeGeneration: ReviewRuntimeGeneration
    ) async throws -> NetworkRestoreRestartResult {
        guard case .waitingForRecovery(let currentHandoff) = reviewAttemptOwnerships[job.id],
              currentHandoff == handoff
        else {
            if job.isTerminal {
                return .finished
            }
            throw ReviewAttemptContractFailure(
                message: "Recovery restart requires its exact waiting handoff."
            )
        }
        if Task.isCancelled || job.isTerminal {
            return .finished
        }
        if handoff.candidate.trigger == .recoverableNetworkLoss,
           await inputs.networkStatusTracker.currentStatus() != .satisfied {
            return .continueWaiting
        }
        let replacement = inputs.runtimeWorkerRegistry.replacement(
            registrationID: inputs.runtimeWorkerRegistrationID,
            jobID: job.id
        )
        let destinationRuntimeGeneration: ReviewRuntimeGeneration
        if let replacement {
            var outcomes = replacement.replacementOutcomes().makeAsyncIterator()
            guard let outcome = await outcomes.next() else {
                return .finished
            }
            switch outcome {
            case .running(let generation):
                destinationRuntimeGeneration = generation
            case .failed(let failure):
                markReviewFailed(job, message: failure.localizedDescription)
                reviewAttemptOwnerships[job.id] = .terminal
                inputs.runtimeWorkerRegistry.finishParticipant(
                    registrationID: inputs.runtimeWorkerRegistrationID,
                    jobID: job.id,
                    replacement: replacement
                )
                return .finished
            case .superseded:
                inputs.runtimeWorkerRegistry.finishParticipant(
                    registrationID: inputs.runtimeWorkerRegistrationID,
                    jobID: job.id,
                    replacement: replacement
                )
                throw CancellationError()
            }
        } else {
            guard handoff.candidate.trigger == .recoverableNetworkLoss else {
                throw ReviewAttemptContractFailure(
                    message: "Same-account recovery lost its runtime replacement owner."
                )
            }
            destinationRuntimeGeneration = sourceRuntimeGeneration
        }
        let recoveredAdmission = ReviewStartAdmission(closePolicy: reviewRuntimeClosePolicy)
        let backend = self.backend
        let registered = try await recoveredAdmission.registerStart { admission in
            try await backend.resumeReviewRecovery(
                handoff,
                request: startRequest,
                admission: admission
            )
        }
        guard case .waitingForRecovery(let revalidatedHandoff) = reviewAttemptOwnerships[job.id],
              revalidatedHandoff == handoff
        else {
            _ = try await cancel(
                admission: recoveredAdmission,
                cancellation: job.core.lifecycle.cancellation ?? .system(),
                jobID: job.id
            )
            _ = await registered.task.result
            return .finished
        }
        reviewAttemptOwnerships[job.id] = .replacementStart(
            handoff: handoff,
            start: registered
        )
        try await recoveredAdmission.activateStart(registered.id)
        let result = await registered.task.result
        let recoveredAttempt = try result.get()
        guard case .replacementStart(let currentHandoff, let currentStart) = reviewAttemptOwnerships[job.id],
              currentHandoff == handoff,
              currentStart.id == registered.id
        else {
            do {
                try await backend.discardResumedReviewRecovery(
                    handoff,
                    recoveredRun: recoveredAttempt.run
                )
            } catch {
                retainCleanupFailure(error, for: job.id)
                throw error
            }
            if job.isTerminal {
                return .finished
            }
            throw ReviewAttemptContractFailure(
                message: "Replacement start completed after its ownership changed."
            )
        }
        guard isReviewMutationCurrent(destinationRuntimeGeneration) else {
            let ownerCancellation = ReviewAttemptStreamFailure.ownerForcedConnectionClose(
                .connection("Recovered review was superseded before Store publication.")
            )
            var terminalizationError: (any Error)?
            do {
                try await recoveredAdmission.recordStreamTerminal(ownerCancellation)
                if let terminal = await recoveredAdmission
                    .terminalCancellationProductTerminal(for: ownerCancellation) {
                    try applyRecoveryProductTerminal(terminal, to: job)
                } else {
                    await applyStreamProductTerminal(ownerCancellation, to: job)
                }
            } catch {
                terminalizationError = error
            }
            do {
                try await backend.discardResumedReviewRecovery(
                    handoff,
                    recoveredRun: recoveredAttempt.run
                )
            } catch {
                retainCleanupFailure(error, for: job.id)
                if terminalizationError == nil {
                    terminalizationError = error
                }
            }
            if let terminalizationError {
                throw terminalizationError
            }
            return .finished
        }
        do {
            try backend.commitResumedReviewRecovery(
                handoff,
                recoveredRun: recoveredAttempt.run
            )
        } catch {
            do {
                try await backend.discardResumedReviewRecovery(
                    handoff,
                    recoveredRun: recoveredAttempt.run
                )
            } catch {
                retainCleanupFailure(error, for: job.id)
            }
            throw error
        }
        let active = ReviewActiveAttempt(
            run: recoveredAttempt.run,
            admission: recoveredAdmission
        )
        reviewAttemptOwnerships[job.id] = .active(active)
        applyBackendRun(recoveredAttempt.run, to: job)
        if let replacement {
            inputs.runtimeWorkerRegistry.finishParticipant(
                registrationID: inputs.runtimeWorkerRegistrationID,
                jobID: job.id,
                replacement: replacement
            )
        }
        inputs.runtimeWorkerRegistry.update(
            registrationID: inputs.runtimeWorkerRegistrationID,
            jobID: job.id,
            attemptID: recoveredAttempt.run.attemptID,
            runtimeGeneration: destinationRuntimeGeneration
        )
        return .recovered(
            recoveredAttempt,
            active,
            destinationRuntimeGeneration
        )
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

    package func finishAllReviewWaitersForStoreClose() async {
        let waiters = reviewTerminalWaiters.values.flatMap { $0 }
        reviewTerminalWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume()
        }
        for waiter in waiters {
            await waiter.timeoutTask?.value
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

    var supersedesNetworkRecovery: Bool {
        switch self {
        case .completed, .failed:
            true
        case .cancelled, .started, .message, .messageDelta, .log, .logEntry:
            false
        }
    }
}

private extension ReviewRecoveryDisposition {
    var isNaturalCanonicalProductTerminal: Bool {
        guard case .productTerminal(let product) = self,
              case .canonical(let terminal) = product.resolved.terminal
        else {
            return false
        }
        switch terminal {
        case .completed, .failed:
            return true
        case .interrupted:
            return false
        }
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
    var owner: ReviewActiveAttempt
    var event: CodexReviewBackendModel.Review.Event
}

private struct RoutedReviewAttempt: Sendable {
    var active: ReviewActiveAttempt
    var isResolvingRecovery: Bool
}

private struct ReviewWorkerEventStreamFinished: Sendable {
    var subscriptionID: Int
    var owner: ReviewActiveAttempt
}

private struct ReviewWorkerEventStreamFailed: Sendable {
    var subscriptionID: Int
    var owner: ReviewActiveAttempt
    var failure: ReviewAttemptStreamFailure
}

private enum ReviewWorkerInput: Sendable {
    case reviewEvent(ReviewWorkerReviewEvent)
    case reviewEventsFinished(ReviewWorkerEventStreamFinished)
    case reviewEventsFailed(ReviewWorkerEventStreamFailed)
    case recoveryBarrierResolved(ReviewWorkerRecoveryBarrierResolution)
    case networkSnapshot(CodexReviewNetworkSnapshot, recoveryGeneration: Int)
    case networkOutageConfirmed
    case networkRecoverySettled(recoveryGeneration: Int)
}

private struct ReviewWorkerRecoveryBarrierResolution: Sendable {
    var owner: ReviewActiveAttempt
    var result: Result<ReviewRecoveryDisposition, ReviewWorkerRecoveryFailure>
}

private struct ReviewWorkerAttemptCompletion: Sendable {
    var cleanupAttempt: ReviewActiveAttempt
}

private struct ReviewWorkerRecoveryFailure: LocalizedError, @unchecked Sendable {
    var underlying: any Error

    var errorDescription: String? {
        underlying.localizedDescription
    }
}

private enum NetworkRestoreRestartResult {
    case continueWaiting
    case finished
    case recovered(
        BackendReviewAttempt,
        ReviewActiveAttempt,
        ReviewRuntimeGeneration
    )
}

private enum ReviewNetworkSnapshotEffect {
    case none
    case restartSettling
}

private struct PendingOutageStreamFailure {
    var attemptID: String
    var failure: ReviewAttemptStreamFailure
}

private struct ReviewNetworkRecoverySignals {
    private var isSettlingForNetworkRecovery = false
    private var recoverySettleGeneration: Int?
    private var recoverySettleHandoff: ReviewRecoveryHandoff?
    private var pendingOutageStreamFailure: PendingOutageStreamFailure?

    mutating func markRecovered() {
        isSettlingForNetworkRecovery = false
        recoverySettleGeneration = nil
        recoverySettleHandoff = nil
        pendingOutageStreamFailure = nil
    }

    mutating func recordPendingOutageStreamFailure(
        _ failure: ReviewAttemptStreamFailure,
        attemptID: String
    ) {
        pendingOutageStreamFailure = .init(attemptID: attemptID, failure: failure)
    }

    mutating func takePendingOutageStreamFailureForConfirmedRecovery(
        attemptID: String
    ) -> PendingOutageStreamFailure? {
        guard pendingOutageStreamFailure?.attemptID == attemptID else {
            return nil
        }
        defer {
            pendingOutageStreamFailure = nil
        }
        return pendingOutageStreamFailure
    }

    mutating func takePendingOutageStreamFailureAfterTransientRecovery(
        _ snapshot: CodexReviewNetworkSnapshot
    ) -> PendingOutageStreamFailure? {
        guard snapshot.status == .satisfied else {
            return nil
        }
        defer {
            pendingOutageStreamFailure = nil
        }
        return pendingOutageStreamFailure
    }

    func shouldRestartReviewAfterRecoverySettle(
        recoveryGeneration: Int,
        handoff: ReviewRecoveryHandoff
    ) -> Bool {
        isSettlingForNetworkRecovery
            && recoverySettleGeneration == recoveryGeneration
            && recoverySettleHandoff == handoff
    }

    mutating func networkSnapshotEffect(
        _ snapshot: CodexReviewNetworkSnapshot,
        recoveryGeneration: Int,
        waitingHandoff: ReviewRecoveryHandoff?
    ) -> ReviewNetworkSnapshotEffect {
        guard let waitingHandoff else {
            isSettlingForNetworkRecovery = false
            recoverySettleGeneration = nil
            recoverySettleHandoff = nil
            return .none
        }
        guard snapshot.status == .satisfied else {
            isSettlingForNetworkRecovery = false
            recoverySettleGeneration = nil
            recoverySettleHandoff = nil
            return .none
        }
        guard isSettlingForNetworkRecovery == false else {
            recoverySettleGeneration = recoveryGeneration
            recoverySettleHandoff = waitingHandoff
            return .none
        }
        isSettlingForNetworkRecovery = true
        recoverySettleGeneration = recoveryGeneration
        recoverySettleHandoff = waitingHandoff
        return .restartSettling
    }
}

private struct ReviewWorkerInputs {
    var queue: ReviewWorkerInputQueue
    var networkStatusTracker: ReviewNetworkStatusTracker
    var eventSource: ReviewWorkerEventSource
    var recoveryInterruptionSource: ReviewWorkerRecoveryInterruptionSource
    var runtimeWorkerRegistry: ReviewRuntimeWorkerRegistry
    var runtimeWorkerRegistrationID: UUID
    var jobID: String
    var initialRuntimeGeneration: ReviewRuntimeGeneration
    var initialEventSubscriptionID: Int
    var networkTask: Task<Void, Never>
    var signalCoordinator: ReviewNetworkSignalCoordinator

    func next() async -> ReviewWorkerInput? {
        await queue.next()
    }

    func subscribe(
        to attempt: BackendReviewAttempt,
        owner: ReviewActiveAttempt
    ) async -> Int {
        await eventSource.subscribe(to: attempt, owner: owner)
    }

    func cancelActiveEventSubscription() async {
        await eventSource.cancelActiveSubscription()
    }

    func beginRecoveryInterruption(
        for owner: ReviewActiveAttempt,
        operation: @escaping @Sendable () async throws -> ReviewRecoveryDisposition
    ) async {
        await recoveryInterruptionSource.start(for: owner, operation: operation)
    }

    func cancel() async {
        networkTask.cancel()
        await recoveryInterruptionSource.cancel()
        await eventSource.cancel()
        await signalCoordinator.cancel()
        await networkTask.value
        await queue.finish()
        await runtimeWorkerRegistry.finishRegisteredParticipant(
            registrationID: runtimeWorkerRegistrationID,
            jobID: jobID
        )
        await runtimeWorkerRegistry.unregister(
            registrationID: runtimeWorkerRegistrationID,
            jobID: jobID
        )
    }
}

private actor ReviewWorkerRecoveryInterruptionSource {
    private let queue: ReviewWorkerInputQueue
    private var task: Task<Void, Never>?

    init(queue: ReviewWorkerInputQueue) {
        self.queue = queue
    }

    func start(
        for owner: ReviewActiveAttempt,
        operation: @escaping @Sendable () async throws -> ReviewRecoveryDisposition
    ) {
        guard task == nil else {
            return
        }
        task = Task {
            let result: Result<ReviewRecoveryDisposition, ReviewWorkerRecoveryFailure>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(.init(underlying: error))
            }
            await queue.send(.recoveryBarrierResolved(.init(owner: owner, result: result)))
            self.finish()
        }
    }

    func cancel() async {
        let task = task
        task?.cancel()
        await task?.value
        self.task = nil
    }

    private func finish() {
        task = nil
    }
}

@MainActor
package final class ReviewRuntimeWorkerRegistry {
    private struct RegistrationWaiter {
        let attemptID: String
        let continuation: CheckedContinuation<Void, Never>
    }

    private final class WorkerRegistration {
        let id: UUID
        let jobID: String
        var attemptID: String
        var runtimeGeneration: ReviewRuntimeGeneration
        let recoverySource: ReviewWorkerRecoveryInterruptionSource
        var replacement: ReviewRuntimeRecoveryReplacement?

        init(
            id: UUID,
            jobID: String,
            attemptID: String,
            runtimeGeneration: ReviewRuntimeGeneration,
            recoverySource: ReviewWorkerRecoveryInterruptionSource
        ) {
            self.id = id
            self.jobID = jobID
            self.attemptID = attemptID
            self.runtimeGeneration = runtimeGeneration
            self.recoverySource = recoverySource
        }
    }

    private var workerRegistrationsByJobID: [String: WorkerRegistration] = [:]
    private var registrationWaitersByJobID: [String: [RegistrationWaiter]] = [:]
    private var anyRegistrationWaitersByJobID: [
        String: [CheckedContinuation<String, Never>]
    ] = [:]

    package init() {}

    fileprivate func register(
        jobID: String,
        attemptID: String,
        runtimeGeneration: ReviewRuntimeGeneration,
        recoverySource: ReviewWorkerRecoveryInterruptionSource
    ) -> UUID {
        let registration = WorkerRegistration(
            id: UUID(),
            jobID: jobID,
            attemptID: attemptID,
            runtimeGeneration: runtimeGeneration,
            recoverySource: recoverySource
        )
        workerRegistrationsByJobID[jobID] = registration
        let anyWaiters = anyRegistrationWaitersByJobID.removeValue(forKey: jobID) ?? []
        for waiter in anyWaiters {
            waiter.resume(returning: attemptID)
        }
        let waiters = registrationWaitersByJobID.removeValue(forKey: jobID) ?? []
        for waiter in waiters {
            if waiter.attemptID == attemptID {
                waiter.continuation.resume()
            } else {
                registrationWaitersByJobID[jobID, default: []].append(waiter)
            }
        }
        return registration.id
    }

    package func waitForRegistrationForTesting(
        jobID: String,
        attemptID: String
    ) async {
        if let registration = workerRegistrationsByJobID[jobID],
           registration.attemptID == attemptID {
            return
        }
        await withCheckedContinuation { continuation in
            if let registration = workerRegistrationsByJobID[jobID],
               registration.attemptID == attemptID {
                continuation.resume()
            } else {
                registrationWaitersByJobID[jobID, default: []].append(.init(
                    attemptID: attemptID,
                    continuation: continuation
                ))
            }
        }
    }

    package func waitForRegistrationForTesting(jobID: String) async -> String {
        if let registration = workerRegistrationsByJobID[jobID] {
            return registration.attemptID
        }
        return await withCheckedContinuation { continuation in
            if let registration = workerRegistrationsByJobID[jobID] {
                continuation.resume(returning: registration.attemptID)
            } else {
                anyRegistrationWaitersByJobID[jobID, default: []].append(continuation)
            }
        }
    }

    fileprivate func update(
        registrationID: UUID,
        jobID: String,
        attemptID: String,
        runtimeGeneration: ReviewRuntimeGeneration
    ) {
        guard let registration = workerRegistrationsByJobID[jobID],
              registration.id == registrationID
        else {
            return
        }
        registration.attemptID = attemptID
        registration.runtimeGeneration = runtimeGeneration
    }

    fileprivate func unregister(registrationID: UUID, jobID: String) {
        guard let registration = workerRegistrationsByJobID[jobID],
              registration.id == registrationID
        else {
            return
        }
        if let replacement = registration.replacement {
            replacement.finishParticipant(
                jobID: jobID,
                registrationID: registrationID
            )
            registration.replacement = nil
        }
        workerRegistrationsByJobID.removeValue(forKey: jobID)
    }

    fileprivate func participant(
        jobID: String,
        attemptID: String,
        sourceGeneration: ReviewRuntimeGeneration
    ) -> ReviewRuntimeReplacementParticipant? {
        guard let registration = workerRegistrationsByJobID[jobID],
              registration.attemptID == attemptID,
              registration.runtimeGeneration == sourceGeneration
        else {
            return nil
        }
        return .init(
            jobID: jobID,
            attemptID: attemptID,
            registrationID: registration.id
        )
    }

    fileprivate func replacement(
        registrationID: UUID,
        jobID: String
    ) -> ReviewRuntimeRecoveryReplacement? {
        guard let registration = workerRegistrationsByJobID[jobID],
              registration.id == registrationID
        else {
            return nil
        }
        return registration.replacement
    }

    fileprivate func beginRecovery(
        replacement: ReviewRuntimeRecoveryReplacement,
        participant: ReviewRuntimeReplacementParticipant,
        owner: ReviewActiveAttempt,
        trigger: ReviewAttemptRecoveryTrigger,
        interrupt: @escaping @Sendable (
            CodexReviewBackendModel.Review.Run,
            CodexReviewBackendModel.CancellationReason
        ) async throws -> Void,
        forceClose: @escaping @Sendable () async throws -> Void
    ) async -> Bool {
        guard let registration = workerRegistrationsByJobID[participant.jobID],
              registration.id == participant.registrationID,
              registration.attemptID == participant.attemptID,
              replacement.beginParticipantRecovery(
                jobID: participant.jobID,
                registrationID: participant.registrationID
              )
        else {
            return false
        }
        registration.replacement = replacement
        await registration.recoverySource.start(for: owner) {
            try await owner.admission.beginRecovery(
                trigger: trigger,
                interrupt: interrupt,
                forceClose: forceClose
            )
        }
        return await owner.admission.waitForInterruptionAdmission()
            == .recoverableTransition(trigger)
    }

    fileprivate func recordNetworkRestoration(
        registrationID: UUID,
        jobID: String
    ) {
        replacement(registrationID: registrationID, jobID: jobID)?
            .recordNetworkRestoration()
    }

    fileprivate func suppressParticipant(
        _ participant: ReviewRuntimeReplacementParticipant,
        in replacement: ReviewRuntimeRecoveryReplacement
    ) {
        replacement.suppressParticipant(
            jobID: participant.jobID,
            registrationID: participant.registrationID
        )
        guard let registration = workerRegistrationsByJobID[participant.jobID],
              registration.id == participant.registrationID,
              registration.replacement === replacement
        else {
            return
        }
        registration.replacement = nil
    }

    fileprivate func suppressParticipant(
        jobID: String,
        in replacement: ReviewRuntimeRecoveryReplacement
    ) {
        guard let participant = replacement.participants.first(where: {
            $0.jobID == jobID
                && ($0.phase == .eligible || $0.phase == .recovering)
        }) else {
            return
        }
        suppressParticipant(participant, in: replacement)
    }

    fileprivate func finishParticipant(
        registrationID: UUID,
        jobID: String,
        replacement: ReviewRuntimeRecoveryReplacement
    ) {
        replacement.finishParticipant(
            jobID: jobID,
            registrationID: registrationID
        )
        guard let registration = workerRegistrationsByJobID[jobID],
              registration.id == registrationID,
              registration.replacement === replacement
        else {
            return
        }
        registration.replacement = nil
    }

    fileprivate func finishRegisteredParticipant(
        registrationID: UUID,
        jobID: String
    ) {
        guard let registration = workerRegistrationsByJobID[jobID],
              registration.id == registrationID
        else {
            return
        }
        if let replacement = registration.replacement {
            finishParticipant(
                registrationID: registrationID,
                jobID: jobID,
                replacement: replacement
            )
        }
    }

    package var activeReplacementReceiptCountForTesting: Int {
        workerRegistrationsByJobID.values.reduce(into: 0) { count, registration in
            if registration.replacement != nil {
                count += 1
            }
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

private actor ReviewWorkerEventSource {
    private let queue: ReviewWorkerInputQueue
    private var eventTasks: [Int: Task<Void, Never>] = [:]
    private var subscriptionID = 0
    private var activeSubscriptionID: Int?

    init(queue: ReviewWorkerInputQueue) {
        self.queue = queue
    }

    func subscribe(
        to attempt: BackendReviewAttempt,
        owner: ReviewActiveAttempt
    ) -> Int {
        subscriptionID += 1
        let subscriptionID = subscriptionID
        activeSubscriptionID = subscriptionID
        cancelEventTasks()
        let events = attempt.events
        eventTasks[subscriptionID] = Task {
            do {
                while let event = try await events.next() {
                    guard Task.isCancelled == false else {
                        return
                    }
                    await self.yieldReviewEvent(
                        event,
                        owner: owner,
                        subscriptionID: subscriptionID
                    )
                    if event.completesReviewRun {
                        self.finishTerminalDelivery(subscriptionID: subscriptionID)
                        return
                    }
                }
                await self.yieldEventsFinished(owner: owner, subscriptionID: subscriptionID)
            } catch {
                let failure: ReviewAttemptStreamFailure
                if let typed = error as? ReviewAttemptStreamFailure {
                    failure = typed
                } else if error is CancellationError {
                    failure = .ownerCancellation
                } else {
                    failure = .workerContract(.init(message: error.localizedDescription))
                }
                await self.yieldEventsFailed(
                    failure,
                    owner: owner,
                    subscriptionID: subscriptionID
                )
            }
        }
        return subscriptionID
    }

    func cancelActiveSubscription() async {
        subscriptionID += 1
        activeSubscriptionID = nil
        let tasks = cancelEventTasks()
        for task in tasks {
            await task.value
        }
    }

    func cancel() async {
        subscriptionID += 1
        activeSubscriptionID = nil
        let tasks = cancelEventTasks()
        for task in tasks {
            await task.value
        }
    }

    @discardableResult
    private func cancelEventTasks() -> [Task<Void, Never>] {
        let tasks = Array(eventTasks.values)
        for task in tasks {
            task.cancel()
        }
        eventTasks.removeAll(keepingCapacity: true)
        return tasks
    }

    private func yieldReviewEvent(
        _ event: CodexReviewBackendModel.Review.Event,
        owner: ReviewActiveAttempt,
        subscriptionID: Int
    ) async {
        guard activeSubscriptionID == subscriptionID,
              eventTasks[subscriptionID] != nil
        else {
            return
        }
        await queue.send(.reviewEvent(.init(
            subscriptionID: subscriptionID,
            owner: owner,
            event: event
        )))
    }

    private func yieldEventsFinished(
        owner: ReviewActiveAttempt,
        subscriptionID: Int
    ) async {
        guard activeSubscriptionID == subscriptionID,
              eventTasks.removeValue(forKey: subscriptionID) != nil
        else {
            return
        }
        await queue.send(.reviewEventsFinished(.init(
            subscriptionID: subscriptionID,
            owner: owner
        )))
    }

    private func finishTerminalDelivery(subscriptionID: Int) {
        guard activeSubscriptionID == subscriptionID else {
            return
        }
        eventTasks.removeValue(forKey: subscriptionID)
    }

    private func yieldEventsFailed(
        _ failure: ReviewAttemptStreamFailure,
        owner: ReviewActiveAttempt,
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
            owner: owner,
            failure: failure
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

    func cancel() async {
        let pendingOutageTask = outageTask
        let pendingRecoveryTask = recoveryTask
        pendingOutageTask?.cancel()
        outageTask = nil
        pendingRecoveryTask?.cancel()
        recoveryTask = nil
        await pendingOutageTask?.value
        await pendingRecoveryTask?.value
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
