import CodexKit
@_spi(Testing) @testable import CodexReviewKit
@_spi(PreviewSupport) @testable import ReviewUI

extension CodexReviewJob {
    @MainActor
    var legacyReviewChatID: CodexThreadID? {
        if let reviewThreadID = nonEmptyReviewChatProjectionStringForTesting(core.run.reviewThreadID) {
            return CodexThreadID(rawValue: reviewThreadID)
        }
        if let threadID = nonEmptyReviewChatProjectionStringForTesting(core.run.threadID) {
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
            preview: nonEmptyReviewChatProjectionStringForTesting(core.output.lastAgentMessage)
                ?? nonEmptyReviewChatProjectionStringForTesting(core.output.summary),
            workspaceCWD: cwd,
            updatedAt: core.lifecycle.endedAt ?? core.lifecycle.startedAt,
            recencyAt: core.lifecycle.endedAt ?? core.lifecycle.startedAt,
            status: CodexThreadStatus(reviewJobStateForTesting: core.lifecycle.status)
        )
    }
}

private extension CodexThreadStatus {
    init(reviewJobStateForTesting jobState: ReviewJobState) {
        switch jobState {
        case .queued, .running:
            self = .active(activeFlags: [])
        case .succeeded, .failed, .cancelled:
            self = .idle
        }
    }
}

private func nonEmptyReviewChatProjectionStringForTesting(_ value: String?) -> String? {
    guard let value, value.isEmpty == false else {
        return nil
    }
    return value
}
