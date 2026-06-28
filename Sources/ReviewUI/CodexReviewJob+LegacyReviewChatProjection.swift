import CodexKit
import CodexReviewKit

extension CodexReviewJob {
    @MainActor
    var legacyReviewChatID: CodexThreadID? {
        if let reviewThreadID = core.run.reviewThreadID?.nilIfEmpty {
            return CodexThreadID(rawValue: reviewThreadID)
        }
        if let threadID = core.run.threadID?.nilIfEmpty {
            return CodexThreadID(rawValue: threadID)
        }
        return nil
    }

    @MainActor
    var legacyReviewChatSelection: ReviewMonitorCodexSidebarSnapshot.Chat? {
        guard let chatID = legacyReviewChatID else {
            return nil
        }
        return ReviewMonitorCodexSidebarSnapshot.Chat(
            rowID: .chat(chatID),
            id: chatID,
            title: displayTitle,
            preview: core.output.lastAgentMessage?.nilIfEmpty ?? core.output.summary.nilIfEmpty,
            workspaceCWD: cwd,
            updatedAt: core.lifecycle.endedAt ?? core.lifecycle.startedAt
        )
    }
}
