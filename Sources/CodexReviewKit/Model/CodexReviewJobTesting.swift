import Foundation

extension CodexReviewJob {
    package static func makeForTesting(
        id: String = UUID().uuidString,
        sessionID: String = "session-1",
        cwd: String = "/tmp/repo",
        targetSummary: String,
        model: String? = "gpt-5",
        threadID: String? = nil,
        turnID: String? = nil,
        status: ReviewJobState,
        cancellationRequested: Bool = false,
        cancellation: ReviewCancellation? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        summary: String,
        hasFinalReview: Bool = false,
        reviewResult: ParsedReviewResult? = nil,
        lastAgentMessage: String? = "",
        logEntries: [ReviewLogEntry] = [],
        errorMessage: String? = nil,
        exitCode: Int? = nil
    ) -> CodexReviewJob {
        CodexReviewJob(
            id: id,
            sessionID: sessionID,
            cwd: cwd,
            targetSummary: targetSummary,
            core: ReviewJobCore(
                run: .init(
                    reviewThreadID: threadID,
                    threadID: threadID,
                    turnID: turnID,
                    model: model
                ),
                lifecycle: .init(
                    status: status,
                    exitCode: exitCode,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    cancellation: cancellation,
                    errorMessage: errorMessage
                ),
                output: .init(
                    summary: summary,
                    hasFinalReview: hasFinalReview,
                    lastAgentMessage: lastAgentMessage,
                    reviewResult: reviewResult
                )
            ),
            cancellationRequested: cancellationRequested,
            logEntries: logEntries
        )
    }

    package func updateStateForTesting(
        targetSummary: String? = nil,
        status: ReviewJobState? = nil,
        endedAt: Date? = nil,
        clearEndedAt: Bool = false,
        summary: String? = nil
    ) {
        if let targetSummary {
            self.targetSummary = targetSummary
        }
        if let status {
            core.lifecycle.status = status
        }
        if let endedAt {
            core.lifecycle.endedAt = endedAt
        } else if clearEndedAt {
            core.lifecycle.endedAt = nil
        }
        if let summary {
            core.output.summary = summary
        }
    }
}
