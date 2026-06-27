import CodexKit
import CodexReviewKit

@MainActor
final class ReviewMonitorSidebarReviewChatIndex {
    private var rowsByJobID: [String: ReviewMonitorSidebarReviewChatRow] = [:]

    func rows(for jobs: [CodexReviewJob]) -> [ReviewMonitorSidebarReviewChatRow] {
        jobs.map { job in
            if let row = rowsByJobID[job.id] {
                row.update(from: job)
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
              workspaces.contains(where: { $0.cwd == row.cwd })
        else {
            return nil
        }
        return row.chat
    }
}
