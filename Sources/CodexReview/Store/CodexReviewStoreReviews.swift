import Foundation
import OSLog

private let reviewCleanupLogger = Logger(
    subsystem: "CodexReviewKit",
    category: "review-cleanup"
)

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
            _ = try await awaitReview(sessionID: sessionID, jobID: jobID)
            if Task.isCancelled, storeWorkRegistry.acceptsNewWork {
                _ = try await performCancelReview(
                    jobID: jobID,
                    cancellation: .system()
                )
            }
            await reviewWorkerTasks[jobID]?.value
            return try readReview(sessionID: sessionID, jobID: jobID)
        }
        let workerTask = reviewWorkerTasks[jobID]
        _ = try await awaitReview(
            sessionID: sessionID,
            jobID: jobID,
            timeout: waitTimeout
        )
        if storeWorkRegistry.acceptsNewWork == false {
            await workerTask?.value
        }
        return try readReview(sessionID: sessionID, jobID: jobID)
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
        let admission = ReviewStartAdmission()
        guard let workerTask = makeReviewWorker(
            jobID: jobID,
            sessionID: sessionID,
            request: validatedRequest,
            admission: admission
        ) else {
            throw CodexReviewAPI.Error.io("Review Store work admission is closed.")
        }
        insertReviewJob(job)
        markReviewRunning(job, startedAt: createdAt)
        reviewAttemptOwnerships[jobID] = .starting(admission)
        reviewWorkerTasks[jobID]?.cancel()
        reviewWorkerTasks[jobID] = workerTask
        return jobID
    }

    private func makeReviewWorker(
        jobID: String,
        sessionID: String,
        request: CodexReviewAPI.Start.Request,
        admission: ReviewStartAdmission
    ) -> Task<Void, Never>? {
        startRegisteredStoreWork(
            kind: .reviewWorker(jobID: jobID),
            cancelledBeforeEntry: .runFinalizer { store in
                store.finishReviewWorkerCancelledBeforeStart(
                    jobID: jobID,
                    admission: admission
                )
            }
        ) { @MainActor store in
            await store.runReviewWorker(
                jobID: jobID,
                sessionID: sessionID,
                request: request,
                admission: admission
            )
        }
    }

    private func finishReviewWorkerCancelledBeforeStart(
        jobID: String,
        admission: ReviewStartAdmission
    ) {
        guard removeStartingReviewOwnership(
            for: jobID,
            ifOwnedBy: admission
        ) else {
            return
        }
        if let job = job(id: jobID), job.isTerminal == false {
            try? completeCancellationLocally(
                jobID: job.id,
                sessionID: job.sessionID,
                cancellation: job.pendingCancellationRequest?.cancellation ?? .system()
            )
        }
        reviewWorkerTasks.removeValue(forKey: jobID)
        resumeReviewWaiters(for: jobID)
    }

    private func runReviewWorker(
        jobID: String,
        sessionID: String,
        request validatedRequest: CodexReviewAPI.Start.Request,
        admission: ReviewStartAdmission
    ) async {
        guard let job = job(id: jobID) else {
            removeStartingReviewOwnership(for: jobID, ifOwnedBy: admission)
            reviewWorkerTasks.removeValue(forKey: jobID)
            runtimeStopDetachedReviewWorkerTasks.removeValue(forKey: jobID)
            resumeReviewWaiters(for: jobID)
            return
        }
        let startRequest = CodexReviewBackendModel.Review.Start(
            jobID: jobID,
            sessionID: sessionID,
            request: validatedRequest,
            model: settings.effectiveModel
        )
        var inputs: ReviewWorkerInputs?
        var unpublishedAttempt: StoreReviewActiveAttempt?
        var cleanupCancellationRequest: ReviewCancellationRequestReceipt?
        do {
            let backendAttempt = try await backend.startReview(
                startRequest,
                admission: admission
            )
            let active = StoreReviewActiveAttempt(
                attempt: backendAttempt,
                admission: admission
            )
            unpublishedAttempt = active
            let workerInputs = await reviewWorkerInputs(for: active)
            inputs = workerInputs
            try await publishInitialReviewStart(
                active,
                for: job,
                admission: admission
            )
            unpublishedAttempt = nil
            if Task.isCancelled { throw CancellationError() }
            if let startupCancellation = await admission.cancellationRequest()
                ?? job.pendingCancellationRequest?.cancellation {
                recordCancellationRequest(startupCancellation, for: job)
                throw CancellationError()
            } else if job.isTerminal == false {
                try await consumeReviewEvents(
                    inputs: workerInputs,
                    job: job,
                    startRequest: startRequest
                )
            }
        } catch let cancellation as ReviewStartCancelledBeforeDispatch {
            if job.isTerminal == false {
                try? completeCancellationAfterRegisteredWorkSuspension(
                    for: job,
                    requested: cancellation.cancellation
                )
            }
        } catch let inputFailure as ReviewWorkerInputQueueError {
            applyReviewWorkerInputFailure(inputFailure.failure, to: job)
        } catch let error where error is CancellationError || Task.isCancelled {
            cleanupCancellationRequest = job.pendingCancellationRequest
            if reviewAttemptOwnsTerminalBarrier(
                jobID: jobID,
                workerAdmission: admission
            ) == false {
                let cancellation = await admission.cancellationRequest()
                if job.isTerminal == false || cancellation != nil {
                    try? completeCancellationAfterRegisteredWorkSuspension(
                        for: job,
                        requested: cancellation ?? job.pendingCancellationRequest?.cancellation ?? .system()
                    )
                }
            }
        } catch {
            let startupCancellation = await admission.cancellationRequest()
            if job.isTerminal == false, let startupCancellation {
                try? completeCancellationAfterRegisteredWorkSuspension(
                    for: job,
                    requested: startupCancellation
                )
            } else if job.isTerminal == false {
                markReviewFailed(job, message: error.localizedDescription)
            }
        }
        // Cleanup RPCs remain owned by a fresh task so a worker cancelled to wake
        // a pending-outage wait cannot carry cancellation into backend cleanup.
        let workerWasCancelled = Task.isCancelled
        let cleanupTask = Task { @MainActor [self] in
            await self.cleanupReviewAttemptOwnership(
                jobID: jobID,
                job: job,
                workerAdmission: admission,
                unpublishedAttempt: unpublishedAttempt,
                cancellationRequest: cleanupCancellationRequest,
                inputs: inputs,
                workerWasCancelled: workerWasCancelled
            )
        }
        if let cleanupFailure = await cleanupTask.value {
            retainCleanupFailure(cleanupFailure, for: job)
        }
        await inputs?.cancelAndWait()
        removeStartingReviewOwnership(for: jobID, ifOwnedBy: admission)
        reviewWorkerTasks.removeValue(forKey: jobID)
        runtimeStopDetachedReviewWorkerTasks.removeValue(forKey: jobID)
        if job.isTerminal {
            resumeReviewWaiters(for: jobID)
        }
    }

    private func publishInitialReviewStart(
        _ active: StoreReviewActiveAttempt,
        for job: CodexReviewJob,
        admission: ReviewStartAdmission
    ) async throws {
        let run = active.run
        let admissionPhase = await admission.currentPhase()
        let terminalResolution = await admission.activeTerminalResolution()
        let admissionOwnsRun = admissionPhase == .active(run) || terminalResolution?.run == run
        guard admissionOwnsRun else {
            throw ReviewAttemptContractFailure(
                message: "Initial review start returned before its exact run became active."
            )
        }
        guard case .starting(let currentAdmission) = reviewAttemptOwnerships[job.id],
              currentAdmission === admission else {
            throw ReviewAttemptContractFailure(
                message: "Initial review start completed after its Store ownership changed."
            )
        }
        reviewAttemptOwnerships[job.id] = .active(active)
        applyBackendRun(run, to: job)
    }

    @discardableResult
    private func removeStartingReviewOwnership(
        for jobID: String,
        ifOwnedBy admission: ReviewStartAdmission
    ) -> Bool {
        guard case .starting(let currentAdmission) = reviewAttemptOwnerships[jobID],
              currentAdmission === admission else {
            return false
        }
        reviewAttemptOwnerships.removeValue(forKey: jobID)
        return true
    }

    private func provisionalInitialReviewStartRun(
        admission: ReviewStartAdmission
    ) async -> CodexReviewBackendModel.Review.Run? {
        guard case .startingReview(let preparedRun, .outcomeUnknown) = await admission.currentPhase(),
              await admission.failedReviewStartDisposition(for: preparedRun) == .preserveOutcomeUnknown
        else {
            return nil
        }
        return preparedRun
    }

    private func initialReviewStartCleanupRun(
        admission: ReviewStartAdmission
    ) async -> CodexReviewBackendModel.Review.Run? {
        if let provisional = await provisionalInitialReviewStartRun(admission: admission) {
            return provisional
        }
        if case .active(let run) = await admission.currentPhase() {
            return run
        }
        return await admission.activeTerminalResolution()?.run
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
            audience: .developer,
            timestamp: clock.now()
        ))
        reviewCleanupLogger.error(
            "Review cleanup failed for job \(job.id, privacy: .public): \(failure.localizedDescription, privacy: .public)"
        )
        writeDiagnosticsIfNeeded()
    }

    private func authoritativeCancellation(
        for job: CodexReviewJob,
        requested: ReviewCancellation
    ) -> ReviewCancellation {
        guard storeWorkRegistry.acceptsNewWork == false else {
            return requested
        }
        return job.pendingCancellationRequest?.cancellation ?? requested
    }

    private func completeCancellationAfterRegisteredWorkSuspension(
        for job: CodexReviewJob,
        requested: ReviewCancellation
    ) throws {
        try completeCancellationLocally(
            jobID: job.id,
            sessionID: job.sessionID,
            cancellation: authoritativeCancellation(for: job, requested: requested)
        )
    }

    private func recordCancellationFailureAfterRegisteredWorkSuspension(
        for job: CodexReviewJob,
        receipt: ReviewCancellationRequestReceipt,
        message: String
    ) throws {
        guard job.isTerminal == false,
              job.pendingCancellationRequest?.id == receipt.id
        else {
            return
        }
        if storeWorkRegistry.acceptsNewWork {
            try recordCancellationFailure(
                jobID: job.id,
                sessionID: job.sessionID,
                receipt: receipt,
                message: message
            )
        } else {
            markReviewFailed(job, message: message)
        }
    }

    private enum ActiveAttemptCancellation {
        case semantic(ReviewCancellation)
        case receipt(ReviewCancellationRequestReceipt)

        var requestReceipt: ReviewCancellationRequestReceipt? { switch self { case .semantic: nil; case .receipt(let receipt): receipt } }

    }

    private func interruptActiveAttempt(
        _ active: StoreReviewActiveAttempt,
        cancellation: ActiveAttemptCancellation
    ) async throws -> ReviewInterruptResolution {
        switch cancellation {
        case .semantic(let cancellation):
            try await active.admission.interrupt(active.run, cancellation: cancellation) { [backend] requestAdmission, reason in
                try await backend.interruptReview(requestAdmission, reason: reason)
            }
        case .receipt(let receipt):
            try await active.admission.interrupt(
                active.run,
                cancellationRequest: receipt
            ) { [backend] requestAdmission, reason in
                try await backend.interruptReview(requestAdmission, reason: reason)
            }
        }
    }

    private func interruptActiveAttemptAndRecordTerminal(
        _ active: StoreReviewActiveAttempt,
        cancellation: ActiveAttemptCancellation,
        inputs: ReviewWorkerInputs?,
        job: CodexReviewJob
    ) async throws -> ReviewInterruptResolution {
        guard let inputs else { throw recoveryOwnershipFailure("drain active cancellation") }
        let interrupt = Task<Result<ReviewInterruptResolution, any Error>, Never> { @MainActor in
            do {
                return .success(try await interruptActiveAttempt(active, cancellation: cancellation))
            } catch {
                await inputs.queue.send(.cleanupInterruptFailed(error.localizedDescription))
                return .failure(error)
            }
        }
        if try await active.admission.hasRecordedActiveTerminal(for: active.run) == false {
            do {
                try await recordNextTerminal(
                    for: active,
                    cancellationRequest: cancellation.requestReceipt,
                    inputs: inputs,
                    drainCancellation: false,
                    job: job
                )
            } catch {
                switch await interrupt.value {
                case .failure(let interruptFailure):
                    throw interruptFailure
                case .success:
                    throw error
                }
            }
        }
        let resolution = try await interrupt.value.get()
        if job.isTerminal == false {
            applyRecordedInterruptTerminal(resolution, to: job)
        }
        return resolution
    }

    private func cleanupFailure(
        from requestFailure: ReviewInterruptRequestFailure?
    ) -> ReviewRuntimeCloseFailure? {
        requestFailure.map { .cleanup($0.localizedDescription) }
    }

    private func recordNextTerminal(
        for active: StoreReviewActiveAttempt,
        cancellationRequest: ReviewCancellationRequestReceipt?,
        inputs: ReviewWorkerInputs,
        drainCancellation: Bool,
        job: CodexReviewJob? = nil
    ) async throws {
        while true {
            let input: ReviewWorkerInput?
            if drainCancellation || Task.isCancelled {
                input = await inputs.nextBuffered()
                if input == nil {
                    throw CancellationError()
                }
            } else {
                input = await inputs.next()
            }
            guard let input else {
                throw ReviewWorkerInputQueueError(failure: .workerContract(.init(
                    message: "Review input closed before cancellation terminal."
                )))
            }
            switch input {
            case .reviewEvent(let event) where active.matches(event.source):
                guard let terminal = reviewTerminalRecord(for: event.event) else { continue }
                let resolution = try await active.admission.recordCanonicalTerminal(
                    terminal,
                    for: active.run,
                    cancellationRequest: cancellationRequest
                )
                if let job {
                    _ = handleReviewEvent(
                        event.event,
                        job: job,
                        sourceRun: active.run,
                        currentRun: active.run,
                        recordedTerminal: resolution
                    )
                }
                return
            case .reviewStreamTerminal(let stream) where active.matches(stream.source):
                let failure: ReviewAttemptStreamFailure = switch stream.kind {
                case .finished: .workerContract(.init(
                    message: ReviewIngestionError.streamEndedWithoutTerminal.localizedDescription
                ))
                case .failed(let failure): failure
                }
                let resolution = try await active.admission.recordStreamTerminal(
                    failure,
                    for: active.run,
                    cancellationRequest: cancellationRequest
                )
                if let job {
                    applyRecordedStreamTerminal(
                        failure,
                        resolution: resolution,
                        to: job
                    )
                }
                return
            case .cleanupInterruptFailed(let message):
                throw ReviewWorkerInputQueueError(failure: .workerContract(.init(message: message)))
            case .reviewEvent, .reviewStreamTerminal, .networkSnapshot,
                 .networkOutageConfirmed, .networkRecoverySettled,
                 .recoveryDispositionCompleted:
                continue
            }
        }
    }

    private func reviewAttemptOwnsTerminalBarrier(
        jobID: String,
        workerAdmission: ReviewStartAdmission
    ) -> Bool {
        guard let ownership = reviewAttemptOwnerships[jobID],
              ownership.workerAdmission === workerAdmission else {
            return false
        }
        switch ownership {
        case .active:
            return true
        case .starting, .recovering:
            return false
        }
    }

    private func applyRecordedInterruptTerminal(
        _ resolution: ReviewInterruptResolution,
        to job: CodexReviewJob
    ) {
        switch resolution.terminal {
        case .canonical(let terminal):
            applyRecoveryProductTerminal(terminal, to: job)
        case .connection(let failure):
            applyRecordedStreamTerminal(
                .unexpectedConnection(failure),
                resolution: resolution,
                to: job
            )
        case .stream(let failure):
            applyRecordedStreamTerminal(
                failure,
                resolution: resolution,
                to: job
            )
        }
    }

    private func applyRecordedStreamTerminal(
        _ failure: ReviewAttemptStreamFailure,
        resolution: ReviewInterruptResolution,
        to job: CodexReviewJob
    ) {
        if let cancellation = recordedStreamCancellation(
            resolution,
            failure: failure,
            pendingRequest: job.pendingCancellationRequest
        ) {
            try? completeCancellationLocally(
                jobID: job.id,
                sessionID: job.sessionID,
                cancellation: cancellation
            )
        } else {
            applyReviewWorkerInputFailure(failure, to: job)
        }
    }

    private func cleanupReviewAttemptOwnership(
        jobID: String,
        job: CodexReviewJob,
        workerAdmission: ReviewStartAdmission,
        unpublishedAttempt: StoreReviewActiveAttempt?,
        cancellationRequest capturedCancellationRequest: ReviewCancellationRequestReceipt?,
        inputs: ReviewWorkerInputs?,
        workerWasCancelled: Bool
    ) async -> ReviewRuntimeCloseFailure? {
        let cancellationRequest = latestCleanupCancellationRequest(capturedCancellationRequest, job.pendingCancellationRequest)
        if let unpublishedAttempt {
            let failure = await cleanupReviewFailure(unpublishedAttempt.run)
            let starting = StoreReviewAttemptOwnership.starting(workerAdmission)
            if reviewAttemptOwnerships[jobID]?.matches(starting) == true {
                reviewAttemptOwnerships.removeValue(forKey: jobID)
            }
            return failure
        }
        guard let ownership = reviewAttemptOwnerships[jobID],
              ownership.workerAdmission === workerAdmission else {
            guard let run = await initialReviewStartCleanupRun(admission: workerAdmission) else {
                return nil
            }
            return await cleanupReviewFailure(run)
        }
        var failure: ReviewRuntimeCloseFailure?
        switch ownership {
        case .starting:
            if let run = await provisionalInitialReviewStartRun(admission: workerAdmission) {
                failure = await cleanupReviewFailure(run)
            }
        case .active(let active):
            let cancellation = cancellationRequest.map(ActiveAttemptCancellation.receipt)
                ?? (job.core.lifecycle.cancellation ?? (workerWasCancelled ? .system() : nil)).map(ActiveAttemptCancellation.semantic)
            if let cancellation {
                do {
                    let resolution = try await interruptActiveAttemptAndRecordTerminal(
                        active,
                        cancellation: cancellation,
                        inputs: inputs,
                        job: job
                    )
                    failure = cleanupFailure(from: resolution.requestFailure)
                } catch {
                    failure = .cleanup(error.localizedDescription)
                }
            }
            if let cleanup = await cleanupReviewFailure(active.run) {
                failure = failure ?? cleanup
            }
        case .recovering(let receipt):
            if let cancellation = cancellationRequest?.cancellation
                ?? job.core.lifecycle.cancellation
                ?? (workerWasCancelled ? .system() : nil) {
                await receipt.cancelOwnedOperation(cancellation)
            }
            do {
                let dispositionJoin = try receipt.reserveDispositionJoinIfPresent()
                if dispositionJoin != nil,
                   await receipt.source.admission.activeTerminalResolution() == nil {
                    guard let inputs else { throw recoveryOwnershipFailure("drain recovery cancellation") }
                    try await recordNextTerminal(
                        for: receipt.source,
                        cancellationRequest: cancellationRequest,
                        inputs: inputs,
                        drainCancellation: workerWasCancelled
                    )
                }
                let join = try dispositionJoin ?? receipt.joinOwnedOperationIfPresent()
                if let join {
                    let completion = try await join.value
                    if case .disposition(let disposition) = completion {
                        failure = failure ?? cleanupFailure(
                            from: disposition.resolved.requestFailure
                        )
                    }
                }
            } catch is CancellationError {
            } catch {
                failure = .cleanup(error.localizedDescription)
            }
            do {
                switch try receipt.suppress() {
                case .source(let source):
                    if let cleanup = await cleanupReviewFailure(source.run) {
                        failure = failure ?? cleanup
                    }
                case .prepared(let prepared):
                    try await backend.discardReviewRecovery(prepared)
                case .staged(let staged):
                    try await backend.discardReviewRecovery(staged)
                case nil:
                    break
                }
            } catch {
                let cleanup = ReviewRuntimeCloseFailure.cleanup(error.localizedDescription)
                failure = failure ?? cleanup
            }
        }
        if reviewAttemptOwnerships[jobID]?.matches(ownership) == true {
            reviewAttemptOwnerships.removeValue(forKey: jobID)
        }
        return failure
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
        for active: StoreReviewActiveAttempt
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
        let networkTask = Task {
            for await snapshot in snapshots {
                await signalCoordinator.observe(snapshot)
            }
        }
        let initialEventSubscriptionID = await eventSource.subscribe(
            to: active
        )
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

    func performCancelReview(
        jobID: String,
        cancellation: ReviewCancellation,
        rejectionDisposition: ReviewCancellationRequestReceipt.RejectionDisposition = .reportFailure
    ) async throws -> CodexReviewAPI.Cancel.Outcome {
        let job = try job(jobID: jobID)
        guard job.isTerminal == false else {
            return .init(jobID: job.id, cancelled: false, core: job.core)
        }
        guard let ownership = reviewAttemptOwnerships[jobID] else {
            throw ReviewAttemptContractFailure(
                message: "Review cancellation requires its exact Store attempt owner."
            )
        }

        let requestedCancellation = authoritativeCancellation(
            for: job,
            requested: cancellation
        )
        guard let requestReceipt = recordCancellationRequest(
            requestedCancellation,
            rejectionDisposition: rejectionDisposition,
            for: job
        ) else {
            return .init(jobID: job.id, cancelled: false, core: job.core)
        }
        let admittedCancellation = requestReceipt.cancellation

        switch ownership {
        case .recovering(let receipt):
            await receipt.cancelOwnedOperation(admittedCancellation)
            reviewWorkerTasks[jobID]?.cancel()
            await reviewWorkerTasks[jobID]?.value
        case .active(let active):
            do {
                _ = try await interruptActiveAttempt(
                    active,
                    cancellation: .receipt(requestReceipt)
                )
                reviewWorkerTasks[jobID]?.cancel()
                await reviewWorkerTasks[jobID]?.value
            } catch {
                if let requestFailure = error as? ReviewInterruptRequestFailure,
                   case .outcomeUnknown = requestFailure.outcome {
                    throw requestFailure
                }
                guard job.isTerminal == false else {
                    return .init(
                        jobID: job.id,
                        cancelled: job.core.lifecycle.status == .cancelled,
                        core: job.core
                    )
                }
                if requestReceipt.rejectionDisposition == .reportFailure {
                    try recordCancellationFailureAfterRegisteredWorkSuspension(
                        for: job,
                        receipt: requestReceipt,
                        message: error.localizedDescription
                    )
                }
                throw error
            }
        case .starting(let admission):
            await admission.recordCancellation(admittedCancellation)
            let startupCancellation = await admission.cancellationRequest()
                ?? admittedCancellation
            try completeCancellationAfterRegisteredWorkSuspension(
                for: job,
                requested: startupCancellation
            )
            reviewWorkerTasks[jobID]?.cancel()
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
        clearPendingCancellationProjection(for: job)
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

    private func applyReviewWorkerInputFailure(
        _ failure: ReviewAttemptStreamFailure,
        to job: CodexReviewJob
    ) {
        guard job.isTerminal == false else { return }
        switch failure {
        case .protocolViolation, .workerContract:
            markReviewFailed(job, message: failure.localizedDescription)
        case .recoverableNetwork, .ownerForcedConnectionClose, .unexpectedConnection, .process:
            markReviewInterrupted(job, cause: .transport(message: failure.localizedDescription))
        case .ownerCancellation:
            try? completeCancellationLocally(
                jobID: job.id,
                sessionID: job.sessionID,
                cancellation: job.pendingCancellationRequest?.cancellation ?? .system()
            )
        }
    }

    private func recordedStreamCancellation(_ terminal: ReviewInterruptResolution,
        failure: ReviewAttemptStreamFailure,
        pendingRequest: ReviewCancellationRequestReceipt? = nil
    ) -> ReviewCancellation? {
        guard let cancellation = terminal.cancellation else {
            guard case .recoverableNetwork = failure else { return nil }
            return pendingRequest?.cancellation
        }
        guard terminal.cancellationRequestReceipt?.rejectionDisposition == .preserveRuntimeStopIntent else { return cancellation }
        guard terminal.cancellationRequestReceipt?.id == pendingRequest?.id else { return nil }
        return cancellation
    }

    private func consumeReviewEvents(
        inputs: ReviewWorkerInputs,
        job: CodexReviewJob,
        startRequest: CodexReviewBackendModel.Review.Start
    ) async throws {
        var recoveryState = ReviewNetworkRecoveryLoopState()
        var activeEventSubscriptionID: Int? = inputs.initialEventSubscriptionID
        while let input = await inputs.next() {
            if Task.isCancelled { throw CancellationError() }
            if job.isTerminal {
                return
            }
            switch input {
            case .reviewEvent(let event):
                guard activeEventSubscriptionID == event.subscriptionID else { continue }
                let terminal = reviewTerminalRecord(for: event.event)
                let terminalCancellationRequest = terminal == nil
                    ? nil
                    : job.pendingCancellationRequest
                let terminalResolution: ReviewInterruptResolution?
                if let terminal {
                    do {
                        terminalResolution = try await event.source.admission.recordCanonicalTerminal(
                            terminal,
                            for: event.source.run,
                            cancellationRequest: terminalCancellationRequest
                        )
                    } catch {
                        try await throwTerminalRecordFailure(
                            error,
                            source: event.source,
                            jobID: job.id
                        )
                    }
                } else {
                    terminalResolution = nil
                }
                switch reviewAttemptOwnerships[job.id] {
                case .active(let active) where active.matches(event.source):
                    _ = handleReviewEvent(
                        event.event,
                        job: job,
                        sourceRun: event.source.run,
                        currentRun: active.run,
                        recordedTerminal: terminalResolution
                    )
                    if job.isTerminal { return }
                case .recovering(let receipt) where receipt.source.matches(event.source):
                    guard terminal != nil,
                          let dispositionJoin = try receipt.reserveDispositionJoinIfPresent()
                    else { continue }
                    activeEventSubscriptionID = nil
                    let effect = try await finishRecoveryDisposition(
                        receipt,
                        dispositionJoin: dispositionJoin,
                        terminalEvent: event.event,
                        terminalResolution: terminalResolution,
                        job: job,
                        inputs: inputs
                    )
                    if effect == .finished { return }
                    if recoveryState.isReadyToStageRecovery,
                       let subscriptionID = try await stagePreparedRecovery(
                           receipt,
                           job: job,
                           startRequest: startRequest,
                           inputs: inputs,
                           recoveryState: &recoveryState
                       ) {
                        activeEventSubscriptionID = subscriptionID
                    }
                case .starting, .active, .recovering, nil:
                    continue
                }
            case .reviewStreamTerminal(let streamTerminal):
                guard activeEventSubscriptionID == streamTerminal.subscriptionID else { continue }
                let failure: ReviewAttemptStreamFailure = switch streamTerminal.kind {
                case .finished:
                    .workerContract(.init(
                        message: ReviewIngestionError.streamEndedWithoutTerminal.localizedDescription
                    ))
                case .failed(let failure): failure
                }
                let terminalCancellationRequest: ReviewCancellationRequestReceipt? = switch failure {
                case .ownerForcedConnectionClose:
                    job.pendingCancellationRequest
                case .recoverableNetwork, .unexpectedConnection, .process,
                     .protocolViolation, .workerContract, .ownerCancellation:
                    nil
                }
                let terminalResolution: ReviewInterruptResolution
                do {
                    terminalResolution = try await streamTerminal.source.admission.recordStreamTerminal(
                        failure,
                        for: streamTerminal.source.run,
                        cancellationRequest: terminalCancellationRequest
                    )
                } catch {
                    try await throwTerminalRecordFailure(
                        error,
                        source: streamTerminal.source,
                        jobID: job.id
                    )
                }
                switch reviewAttemptOwnerships[job.id] {
                case .active(let active) where active.matches(streamTerminal.source):
                    if let cancellation = recordedStreamCancellation(
                        terminalResolution,
                        failure: failure,
                        pendingRequest: job.pendingCancellationRequest
                    ) {
                        try? completeCancellationLocally(
                            jobID: job.id,
                            sessionID: job.sessionID,
                            cancellation: cancellation
                        )
                        return
                    }
                    if await inputs.networkStatusTracker.currentStatus() != .satisfied,
                       failure != .ownerCancellation {
                        recoveryState.recordPendingOutageStreamFailure(failure)
                        activeEventSubscriptionID = nil
                        continue
                    }
                    try throwReviewEventStreamFailure(failure)
                case .recovering(let receipt) where receipt.source.matches(streamTerminal.source):
                    guard let dispositionJoin = try receipt.reserveDispositionJoinIfPresent() else { continue }
                    activeEventSubscriptionID = nil
                    let effect = try await finishRecoveryDisposition(
                        receipt,
                        dispositionJoin: dispositionJoin,
                        terminalEvent: nil,
                        terminalResolution: terminalResolution,
                        job: job,
                        inputs: inputs
                    )
                    if effect == .finished { return }
                case .starting, .active, .recovering, nil:
                    continue
                }
            case .networkSnapshot(let snapshot, let recoveryGeneration):
                if let pendingFailure = recoveryState.takePendingOutageStreamFailureAfterTransientRecovery(
                    snapshot
                ) {
                    try throwReviewEventStreamFailure(pendingFailure)
                }
                guard case .recovering = reviewAttemptOwnerships[job.id] else { continue }
                switch recoveryState.networkSnapshotEffect(snapshot, recoveryGeneration: recoveryGeneration) {
                case .none:
                    continue
                case .restartSettling:
                    appendRecoveryProgress(networkRecoveryRestoredMessage, to: job)
                }
            case .networkRecoverySettled(let recoveryGeneration):
                guard recoveryState.markRecoverySettled(
                    recoveryGeneration: recoveryGeneration
                ), case .recovering(let receipt) = reviewAttemptOwnerships[job.id],
                      receipt.isPreparedForStaging else { continue }
                if let subscriptionID = try await stagePreparedRecovery(
                    receipt,
                    job: job,
                    startRequest: startRequest,
                    inputs: inputs,
                    recoveryState: &recoveryState
                ) {
                    activeEventSubscriptionID = subscriptionID
                }
            case .networkOutageConfirmed:
                guard job.isTerminal == false,
                      job.cancellationRequested == false,
                      await inputs.networkStatusTracker.currentStatus() != .satisfied,
                      case .active(let active) = reviewAttemptOwnerships[job.id]
                else {
                    continue
                }
                let hadPendingTerminal = recoveryState.resetForRecoveryStart()
                let receipt = StoreReviewRecoveryReceipt(source: active)
                reviewAttemptOwnerships[job.id] = .recovering(receipt)
                markReviewWaitingForNetworkRecovery(job)
                try receipt.startDisposition { [backend = self.backend] in
                    do {
                        let disposition = try await active.admission.beginRecovery(
                            active.run,
                            trigger: .recoverableNetworkLoss
                        ) { requestAdmission, reason in
                            try await backend.interruptReview(requestAdmission, reason: reason)
                        }
                        await inputs.queue.send(.recoveryDispositionCompleted(receipt))
                        return disposition
                    } catch {
                        await inputs.queue.send(.recoveryDispositionCompleted(receipt))
                        throw error
                    }
                }
                if hadPendingTerminal {
                    guard let dispositionJoin = try receipt.reserveDispositionJoinIfPresent() else {
                        throw recoveryOwnershipFailure("reserve pending disposition")
                    }
                    let effect = try await finishRecoveryDisposition(
                        receipt,
                        dispositionJoin: dispositionJoin,
                        terminalEvent: nil,
                        terminalResolution: nil,
                        job: job,
                        inputs: inputs
                    )
                    activeEventSubscriptionID = nil
                    if effect == .finished { return }
                }
            case .recoveryDispositionCompleted(let receipt):
                guard case .recovering(let current) = reviewAttemptOwnerships[job.id],
                      current === receipt,
                      let dispositionJoin = try receipt.reserveDispositionJoinIfPresent()
                else { continue }
                let effect = try await finishRecoveryDisposition(
                    receipt,
                    dispositionJoin: dispositionJoin,
                    terminalEvent: nil,
                    terminalResolution: nil,
                    job: job,
                    inputs: inputs
                )
                activeEventSubscriptionID = nil
                if effect == .finished { return }
                if recoveryState.isReadyToStageRecovery,
                   let subscriptionID = try await stagePreparedRecovery(
                       receipt,
                       job: job,
                       startRequest: startRequest,
                       inputs: inputs,
                       recoveryState: &recoveryState
                   ) {
                    activeEventSubscriptionID = subscriptionID
                }
            case .cleanupInterruptFailed(let message):
                throw ReviewWorkerInputQueueError(failure: .workerContract(.init(message: message)))
            }
        }

        if Task.isCancelled { throw CancellationError() }
        if job.isTerminal == false {
            if completePendingCancellationIfNeeded(for: job) { return }
            markReviewFailed(
                job,
                message: ReviewIngestionError.streamEndedWithoutTerminal.localizedDescription
            )
        }
    }

    private func throwReviewEventStreamFailure(_ failure: ReviewAttemptStreamFailure) throws -> Never {
        throw ReviewWorkerInputQueueError(failure: failure)
    }

    private func throwTerminalRecordFailure(
        _ error: any Error,
        source: StoreReviewActiveAttempt,
        jobID: String
    ) async throws -> Never {
        if case .recovering(let receipt) = reviewAttemptOwnerships[jobID],
           receipt.source.matches(source) {
            await receipt.cancelOwnedOperation(.system(message: error.localizedDescription))
        }
        throw ReviewWorkerInputQueueError(failure: .workerContract(.init(
            message: error.localizedDescription
        )))
    }

    private func finishRecoveryDisposition(
        _ receipt: StoreReviewRecoveryReceipt,
        dispositionJoin: Task<StoreReviewRecoveryReceipt.Completion, any Error>,
        terminalEvent: CodexReviewBackendModel.Review.Event?,
        terminalResolution: ReviewInterruptResolution?,
        job: CodexReviewJob,
        inputs: ReviewWorkerInputs
    ) async throws -> RecoveryDispositionEffect {
        try requireRecoveryReceipt(receipt, jobID: job.id, operation: "join disposition")
        guard case .disposition(let disposition) = try await dispositionJoin.value else {
            throw recoveryOwnershipFailure("receive disposition")
        }
        try requireRecoveryReceipt(receipt, jobID: job.id, operation: "publish disposition")
        await inputs.cancelActiveEventSubscription()
        switch disposition {
        case .productTerminal(let productTerminal):
            if let terminalEvent {
                _ = handleReviewEvent(
                    terminalEvent,
                    job: job,
                    sourceRun: receipt.source.run,
                    currentRun: receipt.source.run,
                    recordedTerminal: productTerminalResolution(
                        productTerminal,
                        source: terminalResolution
                    )
                )
            } else {
                applyRecoveryProductTerminal(productTerminal.productTerminal, to: job)
            }
            return .finished
        case .replacement(let candidate):
            try receipt.startPreparation { [backend] in
                try await backend.prepareReviewRecovery(candidate)
            }
            guard case .prepared = try await receipt.joinOwnedOperation().value else {
                throw recoveryOwnershipFailure("receive preparation")
            }
            try requireRecoveryReceipt(receipt, jobID: job.id, operation: "publish preparation")
            return .prepared
        }
    }

    private func productTerminalResolution(
        _ disposition: ReviewProductTerminalDisposition,
        source: ReviewInterruptResolution?
    ) -> ReviewInterruptResolution {
        let cancellation: ReviewCancellation? = switch disposition.productTerminal {
        case .interrupted(.requested(let cancellation)):
            cancellation
        case .completed, .failed, .interrupted:
            nil
        }
        let receipt = source?.cancellationRequestReceipt.flatMap {
            $0.cancellation == cancellation ? $0 : nil
        }
        return .init(
            run: disposition.resolved.run,
            cancellation: cancellation,
            cancellationRequestReceipt: receipt,
            terminal: .canonical(disposition.productTerminal),
            requestFailure: disposition.resolved.requestFailure
        )
    }

    private func stagePreparedRecovery(
        _ receipt: StoreReviewRecoveryReceipt,
        job: CodexReviewJob,
        startRequest: CodexReviewBackendModel.Review.Start,
        inputs: ReviewWorkerInputs,
        recoveryState: inout ReviewNetworkRecoveryLoopState
    ) async throws -> Int? {
        guard recoveryState.isReadyToStageRecovery,
              await inputs.networkStatusTracker.currentStatus() == .satisfied,
              case .running(let destinationGeneration, _, _) = runtimeState else { return nil }
        try requireRecoveryMutation(receipt, job: job, operation: "start staging")
        let admission = ReviewStartAdmission()
        try receipt.startStaging(admission: admission) {
            [backend] prepared async throws(ReviewRecoveryStagingFailure) -> StagedReviewRecovery in
            try await backend.stageReviewRecovery(
                prepared,
                destinationGeneration: destinationGeneration,
                request: startRequest,
                admission: admission
            )
        }
        guard case .staged = try await receipt.joinOwnedOperation().value else {
            throw recoveryOwnershipFailure("receive staging")
        }
        try requireRecoveryMutation(receipt, job: job, operation: "start commit")
        try receipt.startCommit { [backend] staged in
            try await backend.commitReviewRecovery(staged)
        }
        guard case .committed(let committed) = try await receipt.joinOwnedOperation().value else {
            throw recoveryOwnershipFailure("receive commit")
        }
        try requireRecoveryReceipt(receipt, jobID: job.id, operation: "publish commit")
        let destination = StoreReviewActiveAttempt(
            attempt: committed.attempt,
            admission: committed.admission,
            workerAdmission: receipt.source.workerAdmission
        )
        let subscriptionID = await inputs.subscribe(to: destination)
        try requireRecoveryReceipt(receipt, jobID: job.id, operation: "promote committed attempt")
        let active = try receipt.finishCommitted()
        guard active.matches(destination) else {
            throw recoveryOwnershipFailure("promote committed attempt")
        }
        reviewAttemptOwnerships[job.id] = .active(active)
        applyBackendRun(active.run, to: job)
        recoveryState.markRecovered()
        if Task.isCancelled || job.isTerminal || job.cancellationRequested {
            throw CancellationError()
        }
        return subscriptionID
    }

    private func applyRecoveryProductTerminal(
        _ terminal: ReviewTerminalRecord,
        to job: CodexReviewJob
    ) {
        switch terminal {
        case .completed:
            markReviewFailed(job, message: ReviewIngestionError.missingFinalReview.localizedDescription)
        case .failed(let message):
            markReviewFailed(job, message: message)
        case .interrupted(let cause):
            if case .requested(let cancellation) = cause {
                try? completeCancellationLocally(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    cancellation: cancellation
                )
            } else {
                markReviewInterrupted(job, cause: cause)
            }
        }
    }

    private func recoveryOwnershipFailure(_ operation: String) -> ReviewAttemptContractFailure {
        .init(message: "Store recovery cannot \(operation) without its exact receipt owner.")
    }

    private func requireRecoveryReceipt(
        _ receipt: StoreReviewRecoveryReceipt,
        jobID: String,
        operation: String
    ) throws {
        guard case .recovering(let current) = reviewAttemptOwnerships[jobID],
              current === receipt else { throw recoveryOwnershipFailure(operation) }
    }

    private func requireRecoveryMutation(
        _ receipt: StoreReviewRecoveryReceipt,
        job: CodexReviewJob,
        operation: String
    ) throws {
        try requireRecoveryReceipt(receipt, jobID: job.id, operation: operation)
        if Task.isCancelled || job.isTerminal || job.cancellationRequested {
            throw CancellationError()
        }
    }

    func handleReviewEvent(
        _ event: CodexReviewBackendModel.Review.Event,
        job: CodexReviewJob,
        sourceRun: CodexReviewBackendModel.Review.Run,
        currentRun: CodexReviewBackendModel.Review.Run,
        recordedTerminal: ReviewInterruptResolution? = nil
    ) -> CodexReviewBackendModel.Review.Run {
        let ownsSourceRun: Bool = switch reviewAttemptOwnerships[job.id] {
        case .active(let active): active.run == sourceRun
        case .recovering(let receipt): receipt.source.run == sourceRun
        case .starting, nil: false
        }
        guard ownsSourceRun else { return currentRun }
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
        case .logEntry(let kind, let text, let groupID, let replacesGroup, let metadata, let audience):
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
                audience: audience,
                timestamp: clock.now()
            ))
        case .completed(let summary, let result):
            clearPendingCancellationProjection(for: job)
            completeReview(job, summary: summary, result: result)
        case .failed(let message):
            markReviewFailed(job, message: message)
        case .cancelled(let message):
            if let cancellation = recordedTerminal?.cancellation {
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

    private func clearPendingCancellationProjection(for job: CodexReviewJob) {
        job.pendingCancellationRequest = nil
        job.core.lifecycle.cancellation = nil
        job.core.lifecycle.errorMessage = nil
    }

    private func completePendingCancellationIfNeeded(for job: CodexReviewJob) -> Bool {
        guard let receipt = job.pendingCancellationRequest else {
            return false
        }
        try? completeCancellationLocally(
            jobID: job.id,
            sessionID: job.sessionID,
            cancellation: receipt.cancellation
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

package func latestCleanupCancellationRequest(_ captured: ReviewCancellationRequestReceipt?, _ current: ReviewCancellationRequestReceipt?) -> ReviewCancellationRequestReceipt? {
    guard let current else { return captured }
    guard let captured else { return current }
    guard captured.id.jobID == current.id.jobID, current.id.ordinal > captured.id.ordinal,
          captured.rejectionDisposition == .reportFailure else { return captured }
    return current
}

private struct ReviewReadLogGroupKey: Hashable {
    var kind: ReviewLogEntry.Kind
    var audience: ReviewLogEntry.Audience
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
                audience: entry.audience,
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
            audience: entry.audience,
            timestamp: entry.timestamp
        ))
    }

    return projected
}

private func reviewReadLogGroupKey(for entry: ReviewLogEntry) -> ReviewReadLogGroupKey? {
    guard let groupID = entry.groupID?.nilIfEmpty else {
        return nil
    }

    return ReviewReadLogGroupKey(
        kind: entry.kind,
        audience: entry.audience,
        groupID: groupID
    )
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
    var source: StoreReviewActiveAttempt
    var event: CodexReviewBackendModel.Review.Event
}

private struct ReviewWorkerStreamTerminal: Sendable {
    enum Kind: Sendable {
        case finished
        case failed(ReviewAttemptStreamFailure)
    }
    var subscriptionID: Int
    var source: StoreReviewActiveAttempt
    var kind: Kind
}

private enum ReviewWorkerInput: Sendable {
    case reviewEvent(ReviewWorkerReviewEvent)
    case reviewStreamTerminal(ReviewWorkerStreamTerminal)
    case networkSnapshot(CodexReviewNetworkSnapshot, recoveryGeneration: Int)
    case networkOutageConfirmed
    case networkRecoverySettled(recoveryGeneration: Int)
    case recoveryDispositionCompleted(StoreReviewRecoveryReceipt)
    case cleanupInterruptFailed(String)
}

private enum ReviewNetworkSnapshotEffect {
    case none
    case restartSettling
}

private enum RecoveryDispositionEffect {
    case finished
    case prepared
}

private struct ReviewNetworkRecoveryLoopState {
    private(set) var isReadyToStageRecovery = false
    private var isSettlingForNetworkRecovery = false
    private var recoverySettleGeneration: Int?
    private var pendingOutageStreamFailure: ReviewAttemptStreamFailure?

    mutating func resetForRecoveryStart() -> Bool {
        let hadPendingTerminal = pendingOutageStreamFailure != nil
        isReadyToStageRecovery = false
        isSettlingForNetworkRecovery = false
        recoverySettleGeneration = nil
        pendingOutageStreamFailure = nil
        return hadPendingTerminal
    }

    mutating func markRecovered() {
        isReadyToStageRecovery = false
        isSettlingForNetworkRecovery = false
        recoverySettleGeneration = nil
        pendingOutageStreamFailure = nil
    }

    mutating func recordPendingOutageStreamFailure(_ failure: ReviewAttemptStreamFailure) {
        pendingOutageStreamFailure = failure
    }

    mutating func takePendingOutageStreamFailureAfterTransientRecovery(
        _ snapshot: CodexReviewNetworkSnapshot
    ) -> ReviewAttemptStreamFailure? {
        guard snapshot.status == .satisfied else { return nil }
        defer { pendingOutageStreamFailure = nil }
        return pendingOutageStreamFailure
    }

    mutating func markRecoverySettled(recoveryGeneration: Int) -> Bool {
        guard isSettlingForNetworkRecovery,
              recoverySettleGeneration == recoveryGeneration else { return false }
        isReadyToStageRecovery = true
        return true
    }

    mutating func networkSnapshotEffect(
        _ snapshot: CodexReviewNetworkSnapshot,
        recoveryGeneration: Int
    ) -> ReviewNetworkSnapshotEffect {
        guard snapshot.status == .satisfied else {
            isReadyToStageRecovery = false
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

    func nextIgnoringCancellation() async -> ReviewWorkerInput? {
        await queue.nextIgnoringCancellation()
    }

    func nextBuffered() async -> ReviewWorkerInput? {
        await queue.takeBufferedInput()
    }

    func subscribe(
        to source: StoreReviewActiveAttempt
    ) async -> Int {
        await eventSource.subscribe(to: source)
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

    func nextIgnoringCancellation() async -> ReviewWorkerInput? {
        switch await nextDeliveryIgnoringCancellation() {
        case .input(let input): input
        case .finished: nil
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

    func takeBufferedInput() -> ReviewWorkerInput? {
        guard bufferedInputs.isEmpty == false else { return nil }
        return bufferedInputs.removeFirst()
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

    private func nextDeliveryIgnoringCancellation() async -> Delivery {
        if bufferedInputs.isEmpty == false {
            return .input(bufferedInputs.removeFirst())
        }
        if isFinished { return .finished }
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            if bufferedInputs.isEmpty == false {
                continuation.resume(returning: .input(bufferedInputs.removeFirst()))
            } else if isFinished {
                continuation.resume(returning: .finished)
            } else {
                waiters[waiterID] = continuation
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
    var failure: ReviewAttemptStreamFailure

    var errorDescription: String? {
        failure.localizedDescription
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
        to source: StoreReviewActiveAttempt
    ) async -> Int {
        subscriptionID += 1
        let subscriptionID = subscriptionID
        activeSubscriptionID = subscriptionID
        await cancelEventTasksAndWait()
        let events = source.attempt.events
        eventTasks[subscriptionID] = Task {
            do {
                while let event = try await events.next() {
                    guard Task.isCancelled == false else {
                        return
                    }
                    await self.yieldReviewEvent(event, source: source, subscriptionID: subscriptionID)
                }
                await self.yieldStreamTerminal(
                    .finished,
                    source: source,
                    subscriptionID: subscriptionID
                )
            } catch {
                await self.yieldStreamTerminal(
                    .failed(reviewAttemptStreamFailure(from: error)),
                    source: source,
                    subscriptionID: subscriptionID
                )
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
        source: StoreReviewActiveAttempt,
        subscriptionID: Int
    ) async {
        guard activeSubscriptionID == subscriptionID,
              eventTasks[subscriptionID] != nil
        else {
            return
        }
        await queue.send(.reviewEvent(.init(
            subscriptionID: subscriptionID,
            source: source,
            event: event
        )))
    }

    private func yieldStreamTerminal(
        _ kind: ReviewWorkerStreamTerminal.Kind,
        source: StoreReviewActiveAttempt,
        subscriptionID: Int
    ) async {
        guard eventTasks.removeValue(forKey: subscriptionID) != nil else {
            return
        }
        guard activeSubscriptionID == subscriptionID else {
            return
        }
        await queue.send(.reviewStreamTerminal(.init(
            subscriptionID: subscriptionID,
            source: source,
            kind: kind
        )))
    }
}

private func reviewTerminalRecord(
    for event: CodexReviewBackendModel.Review.Event
) -> ReviewTerminalRecord? {
    switch event {
    case .completed: .completed
    case .failed(let message): .failed(message: message)
    case .cancelled(let message): .interrupted(.server(message: message?.nilIfEmpty))
    case .started, .message, .messageDelta, .log, .logEntry: nil
    }
}

private func reviewAttemptStreamFailure(from error: any Error) -> ReviewAttemptStreamFailure {
    if let failure = (error as? BackendReviewEventMailboxError)?.failure {
        return failure
    }
    if error is CancellationError {
        return .ownerCancellation
    }
    return .workerContract(.init(message: error.localizedDescription))
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
