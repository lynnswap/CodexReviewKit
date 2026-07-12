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
    private let markedTurnIDs: Set<CodexTurnID>

    init(items: [ReviewItemPresentationFacts]) {
        markedTurnIDs = Set(items.compactMap { item in
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
        return markedTurnIDs.contains(turnID)
    }
}

struct ReviewRolloutPresentationPolicy: Sendable {
    struct Result: Equatable, Sendable {
        var suppressedCompanionSourceIDs: Set<String>
        var missingTargetSourceIDs: Set<String>
    }

    func evaluate(_ items: [ReviewItemPresentationFacts]) -> Result {
        let targetTextsByTurnID = Dictionary(grouping: items.compactMap { item -> Target? in
            guard item.kind == .exitedReviewMode, let turnID = item.turnID else {
                return nil
            }
            return Target(turnID: turnID, normalizedText: normalized(item.displayText))
        }, by: \.turnID)

        var suppressed: Set<String> = []
        var missingTargets: Set<String> = []
        for item in items where isReviewRolloutCompanion(item) {
            guard let turnID = item.turnID,
                  let targets = targetTextsByTurnID[turnID],
                  targets.isEmpty == false
            else {
                missingTargets.insert(item.sourceID)
                continue
            }
            guard let companionText = normalized(item.displayText) else {
                continue
            }
            if targets.contains(where: { $0.normalizedText == companionText }) {
                suppressed.insert(item.sourceID)
            }
        }
        return .init(
            suppressedCompanionSourceIDs: suppressed,
            missingTargetSourceIDs: missingTargets
        )
    }

    private func isReviewRolloutCompanion(_ item: ReviewItemPresentationFacts) -> Bool {
        item.kind == .agentMessage
            && item.origin == .reviewRolloutAssistant
            && item.semanticRelation == .companionOf(.exitedReviewMode)
    }

    private func normalized(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false
        else {
            return nil
        }
        return value
    }

    private struct Target: Sendable {
        var turnID: CodexTurnID
        var normalizedText: String?
    }
}
