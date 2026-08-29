import Foundation

package struct ReviewHistoryRecord: Sendable, Hashable {
    package var id: String
    package var cwd: String
    package var workspaceSortOrder: Double
    package var sortOrder: Double
    package var target: CodexReviewAPI.Target
    package var core: ReviewJobCore

    package init(
        id: String,
        cwd: String,
        workspaceSortOrder: Double,
        sortOrder: Double,
        target: CodexReviewAPI.Target,
        core: ReviewJobCore
    ) {
        self.id = id
        self.cwd = cwd
        self.workspaceSortOrder = workspaceSortOrder
        self.sortOrder = sortOrder
        self.target = target
        self.core = core
    }

    @MainActor
    package init(
        job: CodexReviewJob,
        workspaceSortOrder: Double
    ) {
        self.init(
            id: job.id,
            cwd: job.cwd,
            workspaceSortOrder: workspaceSortOrder,
            sortOrder: job.sortOrder,
            target: job.target,
            core: Self.persistenceCore(from: job.core)
        )
    }

    package var isTerminal: Bool {
        core.isTerminal
    }

    @MainActor
    package func makeRestoredJob() throws -> CodexReviewJob {
        guard let timestamp = core.lifecycle.endedAt ?? core.lifecycle.startedAt else {
            throw ReviewHistoryOperationFailure(
                message: "Loaded review \(id) does not have its required start timestamp."
            )
        }
        return CodexReviewJob(
            id: id,
            sessionID: "history:\(id)",
            cwd: cwd,
            sortOrder: sortOrder,
            targetSummary: target.displaySummary,
            target: target,
            origin: .restored,
            core: core,
            logEntries: compactLogEntries(timestamp: timestamp)
        )
    }

    private static func persistenceCore(from core: ReviewJobCore) -> ReviewJobCore {
        let output: ReviewJobCore.Output
        if core.lifecycle.status == .succeeded,
           core.lifecycle.terminal == .completed,
           core.output.hasFinalReview,
           let finalReview = core.output.lastAgentMessage?.nilIfEmpty
        {
            output = .init(
                summary: core.output.summary,
                hasFinalReview: true,
                lastAgentMessage: finalReview,
                reviewResult: core.output.reviewResult
            )
        } else {
            output = .init(summary: core.output.summary)
        }
        return ReviewJobCore(
            run: core.run,
            lifecycle: core.lifecycle,
            output: output
        )
    }

    private func compactLogEntries(timestamp: Date) -> [ReviewLogEntry] {
        if core.output.hasFinalReview,
           let finalReview = core.output.lastAgentMessage?.nilIfEmpty
        {
            return [ReviewLogEntry(
                kind: .agentMessage,
                text: finalReview,
                metadata: .init(sourceType: "canonicalReviewResult"),
                timestamp: timestamp
            )]
        }

        let message = terminalMessage?.nilIfEmpty
            ?? core.lifecycle.errorMessage?.nilIfEmpty
            ?? core.output.summary.nilIfEmpty
        guard let message else {
            return []
        }

        return [ReviewLogEntry(
            kind: isRequestedCancellation ? .event : .error,
            text: message,
            metadata: .init(sourceType: "persistedReviewTerminal"),
            timestamp: timestamp
        )]
    }

    private var terminalMessage: String? {
        switch core.lifecycle.terminal {
        case .completed:
            nil
        case .interrupted(.requested(let cancellation)):
            cancellation.message
        case .interrupted(.server(let message)):
            message
        case .interrupted(.transport(let message)):
            message
        case .interrupted(.previousProcessExit):
            "The previous review process exited before completion."
        case .failed(let message):
            message
        case nil:
            nil
        }
    }

    private var isRequestedCancellation: Bool {
        guard case .interrupted(.requested) = core.lifecycle.terminal else {
            return false
        }
        return true
    }
}
