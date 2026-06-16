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
        request: ReviewStartRequest
    ) async throws -> ReviewReadResult {
        let jobID = try beginReview(sessionID: sessionID, request: request)
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

    @discardableResult
    package func startReview(
        sessionID: String,
        request: ReviewStartRequest,
        waitTimeout: Duration
    ) async throws -> ReviewReadResult {
        let jobID = try beginReview(sessionID: sessionID, request: request)
        return try await awaitReview(sessionID: sessionID, jobID: jobID, timeout: waitTimeout)
    }

    package func awaitReview(
        sessionID: String?,
        jobID: String,
        timeout: Duration? = nil
    ) async throws -> ReviewReadResult {
        let job = try job(jobID: jobID)
        if let sessionID, job.sessionID != sessionID {
            throw ReviewError.jobNotFound("Job \(jobID) was not found.")
        }
        if job.isTerminal == false {
            await waitForReviewTerminal(jobID: jobID, timeout: timeout)
        }
        return try readReview(sessionID: sessionID, jobID: jobID)
    }

    @discardableResult
    private func beginReview(
        sessionID: String,
        request: ReviewStartRequest
    ) throws -> String {
        guard closedSessions.contains(sessionID) == false else {
            throw ReviewError.invalidArguments("Review session \(sessionID) is closed.")
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
        startingJobIDs.insert(jobID)
        launchReviewWorker(jobID: jobID, sessionID: sessionID, request: validatedRequest)
        return jobID
    }

    private func launchReviewWorker(
        jobID: String,
        sessionID: String,
        request: ReviewStartRequest
    ) {
        reviewWorkerTasks[jobID]?.cancel()
        reviewWorkerTasks[jobID] = Task { [weak self] in
            await self?.runReviewWorker(jobID: jobID, sessionID: sessionID, request: request)
        }
    }

    private func runReviewWorker(
        jobID: String,
        sessionID: String,
        request validatedRequest: ReviewStartRequest
    ) async {
        guard let job = job(id: jobID) else {
            startingJobIDs.remove(jobID)
            reviewWorkerTasks.removeValue(forKey: jobID)
            resumeReviewWaiters(for: jobID)
            return
        }
        let startRequest = BackendReviewStart(
            jobID: jobID,
            sessionID: sessionID,
            request: validatedRequest,
            model: settings.effectiveModel
        )
        var run: BackendReviewRun?
        do {
            let backendRun = try await backend.startReview(startRequest)
            startingJobIDs.remove(jobID)
            run = backendRun
            applyBackendRun(backendRun, to: job)
            if Task.isCancelled {
                throw CancellationError()
            }
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

            var currentRun = backendRun
            while job.isTerminal == false {
                switch try await consumeReviewEvents(
                    for: currentRun,
                    job: job,
                    startRequest: startRequest
                ) {
                case .finished:
                    break
                case .recovered(let recoveredRun):
                    currentRun = recoveredRun
                    run = recoveredRun
                    continue
                }
                break
            }
            await backend.cleanupReview(currentRun)
            activeRuns.removeValue(forKey: jobID)
        } catch let error where error is CancellationError || Task.isCancelled {
            startingJobIDs.remove(jobID)
            let startupCancellation = startupCancellations.removeValue(forKey: jobID)
            if let run {
                await interruptReviewAfterTaskCancellation(run, job: job)
                await backend.cleanupReview(run)
            } else if job.isTerminal == false || startupCancellation != nil {
                try? completeCancellationLocally(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    cancellation: startupCancellation ?? job.core.lifecycle.cancellation ?? .system()
                )
            }
            activeRuns.removeValue(forKey: jobID)
        } catch {
            startingJobIDs.remove(jobID)
            let startupCancellation = startupCancellations.removeValue(forKey: jobID)
            if let run {
                await backend.cleanupReview(run)
            }
            activeRuns.removeValue(forKey: jobID)
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
        reviewWorkerTasks.removeValue(forKey: jobID)
        if job.isTerminal {
            resumeReviewWaiters(for: jobID)
        }
    }

    private func interruptReviewAfterTaskCancellation(_ run: BackendReviewRun, job: CodexReviewJob) async {
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

    private func applyBackendRun(_ backendRun: BackendReviewRun, to job: CodexReviewJob) {
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

    private func reviewWorkerInputs(for run: BackendReviewRun) async -> ReviewWorkerInputs {
        let backend = self.backend
        let networkMonitor = self.networkMonitor
        let policy = self.networkRecoveryPolicy
        let events = await backend.events(for: run)
        let snapshots = networkMonitor.snapshots()
        let tracker = ReviewNetworkStatusTracker()
        let stream = AsyncThrowingStream<ReviewWorkerInput, Error>(bufferingPolicy: .unbounded) { continuation in
            let signalCoordinator = ReviewNetworkSignalCoordinator(
                policy: policy,
                tracker: tracker,
                continuation: continuation
            )
            let eventTask = Task {
                do {
                    for try await event in events {
                        continuation.yield(.reviewEvent(event))
                    }
                    continuation.yield(.reviewEventsFinished)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let networkTask = Task {
                for await snapshot in snapshots {
                    await signalCoordinator.observe(snapshot)
                }
            }
            continuation.onTermination = { @Sendable _ in
                eventTask.cancel()
                networkTask.cancel()
                Task {
                    await signalCoordinator.cancel()
                }
            }
        }
        return .init(stream: stream, networkStatusTracker: tracker)
    }

    package func readReview(
        jobID: String,
        logFilter: ReviewLogFilter = .defaultSetting,
        logPage: ReviewLogPageRequest = .default
    ) throws -> ReviewReadResult {
        try readReview(sessionID: nil, jobID: jobID, logFilter: logFilter, logPage: logPage)
    }

    package func readReview(
        sessionID: String?,
        jobID: String,
        logFilter: ReviewLogFilter = .defaultSetting,
        logPage: ReviewLogPageRequest = .default
    ) throws -> ReviewReadResult {
        let job = try job(jobID: jobID)
        if let sessionID, job.sessionID != sessionID {
            throw ReviewError.jobNotFound("Job \(jobID) was not found.")
        }
        let pageRequest = try logPage.validated()
        let filteredLogs = projectedLogsForReviewRead(job.logEntries).filter(logFilter.includes)
        let page = pageRequest.page(total: filteredLogs.count)
        return ReviewReadResult(
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
    ) -> ReviewListResult {
        let filtered = filteredJobs(cwd: cwd, statuses: statuses)
        let clampedLimit = min(max(limit ?? 20, 1), 100)
        return ReviewListResult(items: Array(filtered.prefix(clampedLimit)).map(makeListItem))
    }

    package func listReviews(
        sessionID: String?,
        cwd: String? = nil,
        statuses: [ReviewJobState]? = nil,
        limit: Int? = nil
    ) -> ReviewListResult {
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
        return ReviewListResult(items: Array(filtered.prefix(clampedLimit)).map(makeListItem))
    }

    package func resolveJob(selector: ReviewJobSelector) throws -> CodexReviewJob {
        try resolveJob(sessionID: nil, selector: selector)
    }

    package func resolveJob(sessionID: String?, selector: ReviewJobSelector) throws -> CodexReviewJob {
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
            throw ReviewError.jobNotFound("No review job matched the selector.")
        }
        throw ReviewJobSelectionError.ambiguous(matches.map(makeListItem))
    }

    package func cancelReview(
        jobID: String,
        sessionID: String,
        cancellation: ReviewCancellation = .system()
    ) async throws -> ReviewCancelOutcome {
        guard let job = job(id: jobID), job.sessionID == sessionID else {
            throw ReviewError.jobNotFound("Job \(jobID) was not found.")
        }
        return try await cancelReview(jobID: jobID, cancellation: cancellation)
    }

    @discardableResult
    package func cancelReview(
        jobID: String,
        cancellation: ReviewCancellation = .system()
    ) async throws -> ReviewCancelOutcome {
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

        if let run = activeRuns[jobID] {
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
            } catch {
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
        let jobIDs = orderedJobs
            .filter { $0.isTerminal == false }
            .map(\.id)
        for jobID in jobIDs {
            _ = try? await cancelReview(jobID: jobID, cancellation: reason)
        }
    }

    private func job(jobID: String) throws -> CodexReviewJob {
        guard let job = job(id: jobID) else {
            throw ReviewError.jobNotFound("Job \(jobID) was not found.")
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

    private func makeListItem(_ job: CodexReviewJob) -> ReviewJobListItem {
        ReviewJobListItem(
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

    private func markReviewFailed(_ job: CodexReviewJob, message: String) {
        guard job.isTerminal == false else {
            return
        }
        let endedAt = clock.now()
        job.closeActiveCommandLogEntries(status: "failed", completedAt: endedAt)
        job.core.lifecycle.status = .failed
        job.core.lifecycle.endedAt = endedAt
        job.core.lifecycle.errorMessage = message
        job.core.output.summary = message
        job.appendLogEntry(.init(kind: .error, text: message, timestamp: endedAt))
        job.applyReviewLogLimit()
        writeDiagnosticsIfNeeded()
        resumeReviewWaiters(for: job.id)
    }

    private func consumeReviewEvents(
        for run: BackendReviewRun,
        job: CodexReviewJob,
        startRequest: BackendReviewStart
    ) async throws -> ReviewAttemptOutcome {
        let inputs = await reviewWorkerInputs(for: run)
        var waitingForNetworkRecovery = false
        let recoveryReason = BackendCancellationReason(message: networkRecoveryUnavailableMessage)
        for try await input in inputs.stream {
            if job.isTerminal {
                return .finished
            }
            switch input {
            case .reviewEvent(let event):
                if waitingForNetworkRecovery, event.completesReviewRun {
                    continue
                }
                handleReviewEvent(event, job: job)
                if job.isTerminal {
                    return .finished
                }
            case .reviewEventsFinished:
                if waitingForNetworkRecovery {
                    continue
                }
                if Task.isCancelled {
                    throw CancellationError()
                }
                if job.isTerminal == false {
                    if completePendingCancellationIfNeeded(for: job) {
                        return .finished
                    }
                    completeReview(
                        job,
                        summary: job.core.output.summary,
                        result: job.core.output.lastAgentMessage
                    )
                }
                return .finished
            case .networkSnapshot(let snapshot):
                guard waitingForNetworkRecovery,
                      snapshot.status == .satisfied,
                      job.cancellationRequested == false
                else {
                    continue
                }
                appendRecoveryProgress(networkRecoveryRestoredMessage, to: job)
                try await networkRecoveryPolicy.sleep(networkRecoveryPolicy.recoverySettle)
                guard job.isTerminal == false,
                      job.cancellationRequested == false,
                      await inputs.networkStatusTracker.currentStatus() == .satisfied
                else {
                    continue
                }
                let recoveredRun = try await backend.recoverReview(
                    run,
                    request: startRequest,
                    reason: recoveryReason
                )
                applyBackendRun(recoveredRun, to: job)
                return .recovered(recoveredRun)
            case .networkOutageConfirmed:
                guard waitingForNetworkRecovery == false,
                      job.isTerminal == false,
                      job.cancellationRequested == false
                else {
                    continue
                }
                waitingForNetworkRecovery = true
                appendRecoveryProgress(networkRecoveryUnavailableMessage, to: job)
                try await backend.interruptReviewForRecovery(run, reason: recoveryReason)
            }
        }

        if Task.isCancelled {
            throw CancellationError()
        }
        if job.isTerminal == false {
            if completePendingCancellationIfNeeded(for: job) {
                return .finished
            }
            completeReview(
                job,
                summary: job.core.output.summary,
                result: job.core.output.lastAgentMessage
            )
        }
        return .finished
    }

    private func handleReviewEvent(_ event: BackendReviewEvent, job: CodexReviewJob) {
        guard job.isTerminal == false else {
            return
        }
        if event.completesReviewRun, completePendingCancellationIfNeeded(for: job) {
            writeDiagnosticsIfNeeded()
            return
        }
        switch event {
        case .started(let turnID, let reviewThreadID, let model):
            job.core.run.turnID = turnID
            job.core.run.reviewThreadID = reviewThreadID ?? job.core.run.reviewThreadID
            job.core.run.model = model ?? job.core.run.model
            if var activeRun = activeRuns[job.id] {
                activeRun.turnID = turnID
                activeRun.reviewThreadID = reviewThreadID ?? activeRun.reviewThreadID
                activeRun.model = model ?? activeRun.model
                activeRuns[job.id] = activeRun
            }
            job.core.output.summary = "Review started."
        case .message(let text):
            job.core.output.lastAgentMessage = text
            job.core.output.summary = text
            job.appendLogEntry(.init(kind: .agentMessage, text: text, timestamp: clock.now()))
        case .messageDelta(let text, let itemID):
            guard let updatedMessage = job.appendAgentMessageDelta(itemID: itemID, delta: text) else {
                return
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
            let cancellation = job.core.lifecycle.cancellation ?? .system(message: message)
            try? completeCancellationLocally(
                jobID: job.id,
                sessionID: job.sessionID,
                cancellation: cancellation
            )
        }
        writeDiagnosticsIfNeeded()
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
        job.closeActiveCommandLogEntries(status: "completed", completedAt: endedAt)
        job.core.lifecycle.status = .succeeded
        job.core.lifecycle.endedAt = endedAt
        job.core.output.summary = summary
        job.core.output.lastAgentMessage = finalReviewText ?? summary
        job.core.output.hasFinalReview = finalReviewText != nil
        job.core.output.reviewResult = ParsedReviewResult.parse(finalReviewText: finalReviewText)
        if let result = resultText,
           result != previousAgentMessage {
            job.appendLogEntry(.init(kind: .agentMessage, text: result, timestamp: endedAt))
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

private extension BackendReviewEvent {
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
    var backendRun: BackendReviewRun? {
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
}

private enum ReviewAttemptOutcome {
    case finished
    case recovered(BackendReviewRun)
}

private enum ReviewWorkerInput {
    case reviewEvent(BackendReviewEvent)
    case reviewEventsFinished
    case networkSnapshot(CodexReviewNetworkSnapshot)
    case networkOutageConfirmed(CodexReviewNetworkSnapshot)
}

private struct ReviewWorkerInputs {
    var stream: AsyncThrowingStream<ReviewWorkerInput, Error>
    var networkStatusTracker: ReviewNetworkStatusTracker
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
    private let continuation: AsyncThrowingStream<ReviewWorkerInput, Error>.Continuation
    private var outageTask: Task<Void, Never>?

    init(
        policy: CodexReviewNetworkRecoveryPolicy,
        tracker: ReviewNetworkStatusTracker,
        continuation: AsyncThrowingStream<ReviewWorkerInput, Error>.Continuation
    ) {
        self.policy = policy
        self.tracker = tracker
        self.continuation = continuation
    }

    func observe(_ snapshot: CodexReviewNetworkSnapshot) async {
        await tracker.update(snapshot)
        continuation.yield(.networkSnapshot(snapshot))
        switch snapshot.status {
        case .satisfied:
            outageTask?.cancel()
            outageTask = nil
        case .unsatisfied, .requiresConnection:
            scheduleOutageConfirmationIfNeeded()
        }
    }

    func cancel() {
        outageTask?.cancel()
        outageTask = nil
    }

    private func scheduleOutageConfirmationIfNeeded() {
        guard outageTask == nil else {
            return
        }
        let policy = policy
        let tracker = tracker
        let continuation = continuation
        outageTask = Task {
            do {
                try await policy.sleep(policy.outageDebounce)
            } catch {
                return
            }
            let latest = await tracker.latestSnapshot()
            guard latest.status != .satisfied else {
                return
            }
            continuation.yield(.networkOutageConfirmed(latest))
        }
    }
}
