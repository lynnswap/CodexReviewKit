import CodexKit
import CodexReviewKit
import Foundation

@MainActor
final class ReviewMonitorPreviewChatLogSource {
    let snapshot: ReviewMonitorCodexSidebarSnapshot
    let initialChat: ReviewMonitorCodexSidebarSnapshot.Chat?

    private let jobsByChatID: [CodexThreadID: CodexReviewJob]

    init(jobs: [CodexReviewJob]) {
        var sections: [ReviewMonitorCodexSidebarSnapshot.Section] = []
        var sectionIndexesByCWD: [String: Int] = [:]
        var jobsByChatID: [CodexThreadID: CodexReviewJob] = [:]
        var initialRunningChat: ReviewMonitorCodexSidebarSnapshot.Chat?
        var firstChat: ReviewMonitorCodexSidebarSnapshot.Chat?

        for job in jobs {
            guard let chat = job.reviewChatSelection else {
                continue
            }

            jobsByChatID[chat.id] = job
            firstChat = firstChat ?? chat
            if initialRunningChat == nil, job.core.lifecycle.status == .running {
                initialRunningChat = chat
            }

            if let sectionIndex = sectionIndexesByCWD[job.cwd] {
                sections[sectionIndex].uncategorizedChats.append(chat)
            } else {
                sectionIndexesByCWD[job.cwd] = sections.count
                sections.append(
                    ReviewMonitorCodexSidebarSnapshot.Section(
                        rowID: .section(job.cwd),
                        id: job.cwd,
                        title: URL(fileURLWithPath: job.cwd).lastPathComponent,
                        workspaces: [],
                        uncategorizedChats: [chat]
                    ))
            }
        }

        self.snapshot = ReviewMonitorCodexSidebarSnapshot(sections: sections)
        self.initialChat = initialRunningChat ?? firstChat
        self.jobsByChatID = jobsByChatID
    }

    func job(for chatID: CodexThreadID) -> CodexReviewJob? {
        jobsByChatID[chatID]
    }
}
