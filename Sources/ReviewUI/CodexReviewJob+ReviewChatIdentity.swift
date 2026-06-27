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
}
