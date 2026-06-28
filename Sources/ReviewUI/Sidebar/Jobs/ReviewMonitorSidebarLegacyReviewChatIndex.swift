import CodexKit
import CodexReviewKit

@MainActor
final class ReviewMonitorSidebarLegacyReviewChatIndex {
    private var rowsByJobID: [String: ReviewMonitorSidebarReviewChatRow] = [:]

    func rows(for jobs: [CodexReviewJob]) -> [ReviewMonitorSidebarReviewChatRow] {
        jobs.map { job in
            if let row = rowsByJobID[job.id] {
                row.update(job: job)
                return row
            }
            let row = ReviewMonitorSidebarReviewChatRow(job: job)
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
              workspaces.contains(where: { $0.cwd == row.operation.cwd })
        else {
            return nil
        }
        return row.chat
    }
}

extension ReviewMonitorSidebarReviewChatRow {
    @MainActor
    convenience init(job: CodexReviewJob) {
        self.init(
            chat: job.reviewChatSelection,
            runtime: ReviewMonitorSidebarReviewChatRuntime(job: job)
        )
    }

    @MainActor
    func update(job: CodexReviewJob) {
        update(
            chat: job.reviewChatSelection,
            runtime: ReviewMonitorSidebarReviewChatRuntime(job: job)
        )
    }
}

extension ReviewMonitorSidebarReviewChatRuntime {
    @MainActor
    init(job: CodexReviewJob) {
        self.init(
            operation: .init(
                jobID: job.id,
                sessionID: job.sessionID,
                cwd: job.cwd
            ),
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
