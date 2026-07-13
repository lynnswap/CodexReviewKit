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
        let targets = items.compactMap { item -> Target? in
            guard item.kind == .exitedReviewMode, let turnID = item.turnID else {
                return nil
            }
            return Target(turnID: turnID, normalizedText: normalized(item.displayText))
        }
        let persistedCompanionTurnIDs = persistedCompanionTurnIDs(
            in: items,
            targetTurnIDs: Set(targets.map(\.turnID))
        )
        let hasReviewMarker = items.contains {
            $0.kind == .enteredReviewMode || $0.kind == .exitedReviewMode
        }

        var suppressed: Set<String> = Set(items.compactMap { item -> String? in
            guard item.kind == .agentMessage,
                  let turnID = item.turnID,
                  persistedCompanionTurnIDs.contains(turnID)
            else {
                return nil
            }
            return item.sourceID
        })
        var hiddenUserMessageTurnIDs = persistedCompanionTurnIDs
        var missingTargets: Set<String> = []
        for item in items where item.kind == .agentMessage {
            let isTypedCompanion = isReviewRolloutCompanion(item)
            let isPersistedCompanionCandidate = item.turnID.map {
                persistedCompanionTurnIDs.contains($0)
            } ?? false
            guard isTypedCompanion || isPersistedCompanionCandidate else {
                continue
            }

            if isTypedCompanion, hasReviewMarker, let turnID = item.turnID {
                hiddenUserMessageTurnIDs.insert(turnID)
            }
            guard targets.isEmpty == false else {
                if isTypedCompanion {
                    missingTargets.insert(item.sourceID)
                }
                continue
            }
            guard let companionText = normalized(item.displayText) else {
                continue
            }
            let matchingTarget = targets.first { target in
                guard target.normalizedText == companionText else {
                    return false
                }
                return isTypedCompanion || target.turnID != item.turnID
            }
            if matchingTarget != nil {
                suppressed.insert(item.sourceID)
                if let turnID = item.turnID {
                    hiddenUserMessageTurnIDs.insert(turnID)
                }
            }
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

    private func persistedCompanionTurnIDs(
        in items: [ReviewItemPresentationFacts],
        targetTurnIDs: Set<CodexTurnID>
    ) -> Set<CodexTurnID> {
        var orderedTurnIDs: [CodexTurnID] = []
        var seenTurnIDs: Set<CodexTurnID> = []
        for turnID in items.compactMap(\.turnID) where seenTurnIDs.insert(turnID).inserted {
            orderedTurnIDs.append(turnID)
        }
        let itemsByTurnID = Dictionary(grouping: items, by: \.turnID)

        var result: Set<CodexTurnID> = []
        for targetTurnID in targetTurnIDs {
            guard let targetIndex = orderedTurnIDs.firstIndex(of: targetTurnID),
                  orderedTurnIDs.indices.contains(targetIndex + 1)
            else {
                continue
            }
            let candidateTurnID = orderedTurnIDs[targetIndex + 1]
            let candidateItems = itemsByTurnID[candidateTurnID] ?? []
            let userTexts = candidateItems.compactMap { item -> String? in
                guard item.kind == .userMessage else {
                    return nil
                }
                return normalized(item.displayText)
            }
            let hasRepeatedUserPrompt = Dictionary(grouping: userTexts, by: { $0 })
                .values
                .contains { $0.count > 1 }
            let agentMessageCount = candidateItems.count { $0.kind == .agentMessage }
            if hasRepeatedUserPrompt && agentMessageCount == 1 {
                result.insert(candidateTurnID)
            }
        }
        return result
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
