import Foundation

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

        var run: BackendReviewRun?
        do {
            startingJobIDs.insert(jobID)
            let backendRun = try await backend.startReview(.init(
                jobID: jobID,
                sessionID: sessionID,
                request: validatedRequest,
                model: settings.effectiveModel
            ))
            startingJobIDs.remove(jobID)
            run = backendRun
            activeRuns[jobID] = backendRun
            job.core.run = .init(
                reviewThreadID: backendRun.reviewThreadID,
                threadID: backendRun.threadID,
                turnID: backendRun.turnID,
                model: backendRun.model
            )
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

            if job.isTerminal == false {
                try await consumeReviewEvents(for: backendRun, job: job)
            }
            await backend.cleanupReview(backendRun)
            activeRuns.removeValue(forKey: jobID)
            return try readReview(jobID: jobID)
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
            return try readReview(jobID: jobID)
        } catch {
            startingJobIDs.remove(jobID)
            let startupCancellation = startupCancellations.removeValue(forKey: jobID)
            if let run {
                await backend.cleanupReview(run)
            }
            activeRuns.removeValue(forKey: jobID)
            if job.isTerminal {
                return try readReview(jobID: jobID)
            }
            if let startupCancellation {
                try? completeCancellationLocally(
                    jobID: job.id,
                    sessionID: job.sessionID,
                    cancellation: startupCancellation
                )
                return try readReview(jobID: jobID)
            }
            markReviewFailed(job, message: error.localizedDescription)
            return try readReview(jobID: jobID)
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

    package func readReview(
        jobID: String,
        logFilter: ReviewLogFilter = .defaultSetting
    ) throws -> ReviewReadResult {
        try readReview(sessionID: nil, jobID: jobID, logFilter: logFilter)
    }

    package func readReview(
        sessionID: String?,
        jobID: String,
        logFilter: ReviewLogFilter = .defaultSetting
    ) throws -> ReviewReadResult {
        let job = try job(jobID: jobID)
        if let sessionID, job.sessionID != sessionID {
            throw ReviewError.jobNotFound("Job \(jobID) was not found.")
        }
        return ReviewReadResult(
            jobID: job.id,
            core: job.core,
            elapsedSeconds: elapsedSeconds(for: job),
            cancellable: job.isTerminal == false && job.cancellationRequested == false,
            logs: job.logEntries.filter(logFilter.includes),
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
        writeDiagnosticsIfNeeded()
    }

    private func consumeReviewEvents(
        for run: BackendReviewRun,
        job: CodexReviewJob
    ) async throws {
        let events = await backend.events(for: run)
        for try await event in events {
            if job.isTerminal {
                return
            }
            handleReviewEvent(event, job: job)
            if job.isTerminal {
                return
            }
        }

        if job.isTerminal == false {
            if completePendingCancellationIfNeeded(for: job) {
                return
            }
            completeReview(
                job,
                summary: job.core.output.summary,
                result: job.core.output.lastAgentMessage
            )
        }
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
        let previousAgentMessage = job.core.output.lastAgentMessage
        let finalReviewText = result?.nilIfEmpty ?? previousAgentMessage?.nilIfEmpty
        job.closeActiveCommandLogEntries(status: "completed", completedAt: endedAt)
        job.core.lifecycle.status = .succeeded
        job.core.lifecycle.endedAt = endedAt
        job.core.output.summary = summary
        job.core.output.lastAgentMessage = finalReviewText ?? summary
        job.core.output.hasFinalReview = finalReviewText != nil
        job.core.output.reviewResult = ParsedReviewResult.parse(finalReviewText: finalReviewText)
        if let result = result?.nilIfEmpty {
            job.appendLogEntry(.init(kind: .agentMessage, text: result, timestamp: endedAt))
        }
        writeDiagnosticsIfNeeded()
    }

    private func nextJobSortOrder(inWorkspace cwd: String) -> Double {
        (jobs(inWorkspace: cwd).map(\.sortOrder).max() ?? -1) + 1
    }

    private func nextWorkspaceSortOrder() -> Double {
        (workspaces.map(\.sortOrder).max() ?? -1) + 1
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
