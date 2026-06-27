import CodexKit
import CodexReviewKit

@MainActor
final class ReviewMonitorSidebarReviewChatIndex {
    private var rowsByJobID: [String: ReviewMonitorSidebarReviewChatRow] = [:]

    func rows(for jobs: [CodexReviewJob]) -> [ReviewMonitorSidebarReviewChatRow] {
        jobs.map { job in
            let chat = job.reviewChatSelection
            let runtime = ReviewMonitorSidebarReviewChatRuntime(job: job)
            if let row = rowsByJobID[job.id] {
                row.update(chat: chat, runtime: runtime)
                return row
            }
            let row = ReviewMonitorSidebarReviewChatRow(chat: chat, runtime: runtime)
            rowsByJobID[job.id] = row
            return row
        }
    }

    func prune(keeping activeJobIDs: Set<String>) {
        rowsByJobID = rowsByJobID.filter { activeJobIDs.contains($0.key) }
    }

    func row(jobID: String) -> ReviewMonitorSidebarReviewChatRow? {
        rowsByJobID[jobID]
    }

    func row(chatID: CodexThreadID) -> ReviewMonitorSidebarReviewChatRow? {
        rowsByJobID.values.first { $0.chat?.id == chatID }
    }

    func chat(
        id: CodexThreadID,
        in workspaces: [CodexReviewWorkspace]
    ) -> ReviewMonitorCodexSidebarSnapshot.Chat? {
        guard let row = row(chatID: id),
              workspaces.contains(where: { $0.cwd == row.cwd })
        else {
            return nil
        }
        return row.chat
    }
}

extension ReviewMonitorSidebarReviewChatRuntime {
    @MainActor
    init(job: CodexReviewJob) {
        self.init(
            jobID: job.id,
            sessionID: job.sessionID,
            cwd: job.cwd,
            fallbackTitle: job.displayTitle,
            fallbackSubtitle: Self.subtitleText(for: job),
            model: job.core.run.model,
            startedAt: job.core.lifecycle.startedAt,
            endedAt: job.core.lifecycle.endedAt,
            isRunning: job.core.lifecycle.status == .running,
            isTerminal: job.isTerminal,
            cancellationRequested: job.cancellationRequested
        )
    }

    @MainActor
    private static func subtitleText(for job: CodexReviewJob) -> String? {
        if job.core.output.hasFinalReview,
           let finalReview = job.core.output.lastAgentMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           finalReview.isEmpty == false
        {
            return finalReview
        }
        if job.core.lifecycle.status == .cancelled {
            let reviewText = job.reviewText.trimmingCharacters(in: .whitespacesAndNewlines)
            return reviewText.isEmpty ? nil : reviewText
        }
        if let errorMessage = job.core.lifecycle.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           errorMessage.isEmpty == false
        {
            let summary = job.core.output.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return summary.isEmpty ? errorMessage : summary
        }
        guard let lastAgentMessage = job.core.output.lastAgentMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              lastAgentMessage.isEmpty == false
        else {
            return nil
        }
        return lastAgentMessage
    }
}
