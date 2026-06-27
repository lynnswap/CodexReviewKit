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
            guard let chatID = Self.chatID(for: job) else {
                continue
            }

            let chat = Self.chat(from: job, chatID: chatID)
            jobsByChatID[chatID] = job
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

    private static func chat(from job: CodexReviewJob, chatID: CodexThreadID) -> ReviewMonitorCodexSidebarSnapshot.Chat {
        ReviewMonitorCodexSidebarSnapshot.Chat(
            rowID: .chat(chatID),
            id: chatID,
            title: job.displayTitle,
            preview: nonEmpty(job.core.output.lastAgentMessage) ?? nonEmpty(job.core.output.summary),
            workspaceCWD: job.cwd,
            updatedAt: job.core.lifecycle.endedAt ?? job.core.lifecycle.startedAt
        )
    }

    private static func chatID(for job: CodexReviewJob) -> CodexThreadID? {
        if let reviewThreadID = nonEmpty(job.core.run.reviewThreadID) {
            return CodexThreadID(rawValue: reviewThreadID)
        }
        if let threadID = nonEmpty(job.core.run.threadID) {
            return CodexThreadID(rawValue: threadID)
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, value.isEmpty == false else {
            return nil
        }
        return value
    }
}
