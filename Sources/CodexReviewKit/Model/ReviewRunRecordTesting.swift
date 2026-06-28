import Foundation

extension ReviewRunRecord {
    package static func makeForTesting(
        id: String = UUID().uuidString,
        sessionID: String = "session-1",
        cwd: String = "/tmp/repo",
        targetSummary: String,
        model: String? = "gpt-5",
        threadID: String? = nil,
        turnID: String? = nil,
        status: ReviewRunState,
        cancellationRequested: Bool = false,
        cancellation: ReviewCancellation? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        summary: String,
        lastAgentMessage: String? = "",
        errorMessage: String? = nil,
        exitCode: Int? = nil
    ) -> ReviewRunRecord {
        ReviewRunRecord(
            id: id,
            sessionID: sessionID,
            cwd: cwd,
            targetSummary: targetSummary,
            core: ReviewRunCore(
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
                    lastAgentMessage: lastAgentMessage
                )
            ),
            cancellationRequested: cancellationRequested
        )
    }

    package func updateStateForTesting(
        targetSummary: String? = nil,
        status: ReviewRunState? = nil,
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
