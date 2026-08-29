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

    package var isTerminal: Bool {
        core.isTerminal
    }

    @MainActor
    package func makeRestoredJob() -> CodexReviewJob {
        CodexReviewJob(
            id: id,
            sessionID: "history:\(id)",
            cwd: cwd,
            sortOrder: sortOrder,
            targetSummary: target.displaySummary,
            core: core,
            logEntries: compactLogEntries
        )
    }

    private var compactLogEntries: [ReviewLogEntry] {
        let timestamp = core.lifecycle.endedAt
            ?? core.lifecycle.startedAt
            ?? .distantPast

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
            "The previous ReviewMonitor process exited before this review completed."
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
