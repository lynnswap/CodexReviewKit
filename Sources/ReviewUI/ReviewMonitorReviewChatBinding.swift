import CodexKit
import CodexReviewKit

@MainActor
struct ReviewMonitorReviewChatBinding: Equatable {
    var identity: CodexReviewIdentity

    init?(job: CodexReviewJob) {
        guard let sourceThreadID = job.core.run.threadID?.nilIfEmpty,
              let turnID = job.core.run.turnID?.nilIfEmpty
        else {
            return nil
        }
        self.identity = CodexReviewIdentity(
            threadID: CodexThreadID(rawValue: sourceThreadID),
            turnID: CodexTurnID(rawValue: turnID),
            reviewThreadID: job.core.run.reviewThreadID?.nilIfEmpty.map(CodexThreadID.init(rawValue:)),
            model: job.core.run.model?.nilIfEmpty
        )
    }
}
