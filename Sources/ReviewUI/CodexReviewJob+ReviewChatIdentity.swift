import CodexKit
import CodexReviewKit

extension CodexReviewJob {
    @MainActor
    var reviewChatIdentity: CodexReviewIdentity? {
        guard let sourceThreadID = core.run.threadID?.nilIfEmpty,
              let turnID = core.run.turnID?.nilIfEmpty
        else {
            return nil
        }
        return CodexReviewIdentity(
            threadID: CodexThreadID(rawValue: sourceThreadID),
            turnID: CodexTurnID(rawValue: turnID),
            reviewThreadID: core.run.reviewThreadID?.nilIfEmpty.map(CodexThreadID.init(rawValue:)),
            model: core.run.model?.nilIfEmpty
        )
    }

    @MainActor
    var reviewChatID: CodexThreadID? {
        if let reviewThreadID = core.run.reviewThreadID?.nilIfEmpty {
            return CodexThreadID(rawValue: reviewThreadID)
        }
        if let threadID = core.run.threadID?.nilIfEmpty {
            return CodexThreadID(rawValue: threadID)
        }
        return nil
    }

    @MainActor
    var reviewChatSelection: ReviewMonitorCodexSidebarSnapshot.Chat? {
        guard let chatID = reviewChatID else {
            return nil
        }
        return ReviewMonitorCodexSidebarSnapshot.Chat(
            rowID: .chat(chatID),
            id: chatID,
            title: displayTitle,
            preview: core.output.lastAgentMessage?.nilIfEmpty ?? core.output.summary.nilIfEmpty,
            workspaceCWD: cwd,
            updatedAt: core.lifecycle.endedAt ?? core.lifecycle.startedAt,
            reviewIdentity: reviewChatIdentity
        )
    }
}
