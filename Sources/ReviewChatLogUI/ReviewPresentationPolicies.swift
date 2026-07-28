import CodexAppServerKit
import CodexDataKit
import Foundation

struct ReviewItemPresentationFacts: Equatable, Sendable {
    var sourceID: String
    var turnID: CodexTurnID?
    var kind: CodexThreadItem.Kind
    var origin: CodexThreadItem.Origin
    var semanticRelation: CodexThreadItem.SemanticRelation?
    var displayText: String?
}

struct ReviewTurnPresentationPolicy: Sendable {
    private let hiddenUserMessageTurnIDs: Set<CodexTurnID>

    init(
        items: [ReviewItemPresentationFacts],
        additionalHiddenTurnIDs: Set<CodexTurnID> = []
    ) {
        hiddenUserMessageTurnIDs = additionalHiddenTurnIDs.union(items.compactMap { item in
            guard item.kind == .enteredReviewMode || item.kind == .exitedReviewMode else {
                return nil
            }
            return item.turnID
        })
    }

    func hidesUserMessage(in turnID: CodexTurnID?) -> Bool {
        guard let turnID else {
            return false
        }
        return hiddenUserMessageTurnIDs.contains(turnID)
    }
}

struct ReviewRolloutPresentationPolicy: Sendable {
    struct Result: Equatable, Sendable {
        var suppressedCompanionSourceIDs: Set<String>
        var hiddenUserMessageTurnIDs: Set<CodexTurnID>
        var missingTargetSourceIDs: Set<String>
    }

    func evaluate(_ items: [ReviewItemPresentationFacts]) -> Result {
        var suppressed: Set<String> = []
        var hiddenUserMessageTurnIDs: Set<CodexTurnID> = []
        var missingTargets: Set<String> = []
        for (index, item) in items.enumerated() where isReviewRolloutCompanion(item) {
            let target = items[..<index].last {
                $0.kind == .enteredReviewMode || $0.kind == .exitedReviewMode
            }
            if target != nil, let turnID = item.turnID {
                hiddenUserMessageTurnIDs.insert(turnID)
            }
            guard target?.kind == .exitedReviewMode else {
                missingTargets.insert(item.sourceID)
                continue
            }
            suppressed.insert(item.sourceID)
        }
        return .init(
            suppressedCompanionSourceIDs: suppressed,
            hiddenUserMessageTurnIDs: hiddenUserMessageTurnIDs,
            missingTargetSourceIDs: missingTargets
        )
    }

    private func isReviewRolloutCompanion(_ item: ReviewItemPresentationFacts) -> Bool {
        item.kind == .agentMessage
            && item.origin == .reviewRolloutAssistant
            && item.semanticRelation == .companionOf(.exitedReviewMode)
    }
}
