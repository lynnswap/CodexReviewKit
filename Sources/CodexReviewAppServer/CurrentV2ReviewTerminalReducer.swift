import CodexReview
import Foundation

struct CurrentV2ReviewAttemptIdentity: Equatable, Sendable {
    var threadID: String
    var turnID: String
}

enum CurrentV2ReviewAttemptIngestion: Equatable, Sendable {
    case accepted(CurrentV2ReviewTerminalResolution?)
    case duplicate
    case foreignIdentity

    var terminalResolution: CurrentV2ReviewTerminalResolution? {
        if case .accepted(let resolution) = self {
            return resolution
        }
        return nil
    }
}

struct CurrentV2ReviewTerminalResolution: Equatable, Sendable {
    let terminal: ReviewAttemptTerminal
    let ingestionError: ReviewIngestionError?

    init(
        terminal: ReviewAttemptTerminal,
        ingestionError: ReviewIngestionError? = nil
    ) {
        self.terminal = terminal
        self.ingestionError = ingestionError
    }
}

struct CurrentV2ReviewTerminalReducer: Sendable {
    private struct ReviewMarker: Sendable {
        var itemID: String
        var review: String
    }

    private struct TerminalPayload: Decodable, Sendable {
        struct Turn: Decodable, Sendable {
            struct ErrorPayload: Decodable, Sendable {
                var message: String?
            }

            enum ItemsView: String, Decodable, Sendable {
                case notLoaded
                case summary
                case full
            }

            var id: String
            var items: [TerminalItem]
            var itemsView: ItemsView
            var status: String
            var error: ErrorPayload?

            enum CodingKeys: String, CodingKey {
                case id
                case items
                case itemsView
                case status
                case error
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.id = try container.decode(String.self, forKey: .id)
                self.items = try container.decode([TerminalItem].self, forKey: .items)
                self.itemsView = try container.decodeIfPresent(ItemsView.self, forKey: .itemsView) ?? .full
                self.status = try container.decode(String.self, forKey: .status)
                self.error = try container.decodeIfPresent(ErrorPayload.self, forKey: .error)
            }
        }

        var threadID: String
        var turn: Turn

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
            case turn
        }
    }

    private struct ItemCompletedPayload: Decodable, Sendable {
        var threadID: String
        var turnID: String
        var item: TerminalItem

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
            case turnID = "turnId"
            case item
        }
    }

    private struct TerminalItem: Decodable, Sendable {
        var type: String
        var id: String
        var text: String?
        var review: String?
        var delivery: String?
        var phase: ReviewAgentMessagePhase?
    }

    private let identity: CurrentV2ReviewAttemptIdentity
    private let outputStrategy: ReviewTerminalOutputStrategy
    private var receipts: [ReviewStableLifecycleReceipt.Key: ReviewStableLifecycleReceipt.Fingerprint] = [:]
    private var reviewMarker: ReviewMarker?

    init(
        identity: CurrentV2ReviewAttemptIdentity,
        outputStrategy: ReviewTerminalOutputStrategy = .currentV2
    ) {
        self.identity = identity
        self.outputStrategy = outputStrategy
    }

    mutating func ingest(
        _ notification: CurrentV2ReviewNotificationEnvelope,
        agentMessagePhasesByItemID: [String: ReviewAgentMessagePhase] = [:]
    ) throws -> CurrentV2ReviewAttemptIngestion {
        guard notification.threadID == identity.threadID,
              notification.turnID == nil || notification.turnID == identity.turnID
        else {
            return .foreignIdentity
        }

        if let receipt = notification.stableReceipt {
            if let recorded = receipts[receipt.key] {
                guard recorded == receipt.fingerprint else {
                    throw ReviewIngestionError.conflictingStableEvent(
                        key: receipt.key.description
                    )
                }
                return .duplicate
            }
            receipts[receipt.key] = receipt.fingerprint
        }

        switch notification.method {
        case "item/completed":
            let payload = try decode(
                ItemCompletedPayload.self,
                from: notification,
                method: notification.method
            )
            if payload.item.type == "exitedReviewMode" {
                reviewMarker = .init(
                    itemID: payload.item.id,
                    review: payload.item.review ?? ""
                )
            }
            return .accepted(nil)
        case "turn/completed":
            let payload = try decode(
                TerminalPayload.self,
                from: notification,
                method: notification.method
            )
            let resolved = resolveTerminal(
                payload.turn,
                agentMessagePhasesByItemID: agentMessagePhasesByItemID
            )
            return .accepted(resolved)
        default:
            return .accepted(nil)
        }
    }

    private func resolveTerminal(
        _ turn: TerminalPayload.Turn,
        agentMessagePhasesByItemID: [String: ReviewAgentMessagePhase]
    ) -> CurrentV2ReviewTerminalResolution {
        switch turn.status {
        case "completed":
            do {
                return .init(terminal: .completed(try finalResult(
                    from: turn,
                    agentMessagePhasesByItemID: agentMessagePhasesByItemID
                )))
            } catch let error as ReviewIngestionError {
                return .init(
                    terminal: .failed(message: error.localizedDescription),
                    ingestionError: error
                )
            } catch {
                let ingestionError = ReviewIngestionError.malformedKnownEvent(
                    method: "turn/completed",
                    message: error.localizedDescription
                )
                return .init(
                    terminal: .failed(message: error.localizedDescription),
                    ingestionError: ingestionError
                )
            }
        case "interrupted":
            return .init(terminal: .interrupted(message: turn.error?.message))
        case "failed":
            return .init(terminal: .failed(message: turn.error?.message))
        case "inProgress":
            let error = ReviewIngestionError.invalidTerminalStatus(turn.status)
            return .init(
                terminal: .failed(message: error.localizedDescription),
                ingestionError: error
            )
        default:
            let error = ReviewIngestionError.invalidTerminalStatus(turn.status)
            return .init(
                terminal: .failed(message: error.localizedDescription),
                ingestionError: error
            )
        }
    }

    private func finalResult(
        from turn: TerminalPayload.Turn,
        agentMessagePhasesByItemID: [String: ReviewAgentMessagePhase]
    ) throws -> ReviewFinalResult {
        switch outputStrategy {
        case .currentV2:
            if let reviewMarker {
                let companionItemIDs: Set<String>
                if turn.itemsView == .summary,
                   turn.items.count == 1,
                   let item = turn.items.first,
                   item.type == "agentMessage",
                   item.delivery == nil,
                   effectivePhase(
                       for: item,
                       agentMessagePhasesByItemID: agentMessagePhasesByItemID
                   ) != .commentary,
                   item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    companionItemIDs = [item.id]
                } else {
                    companionItemIDs = []
                }
                return try ReviewFinalResult(
                    validating: reviewMarker.review,
                    source: .exitedReviewMode(itemID: reviewMarker.itemID),
                    suppressedAgentMessageItemIDs: companionItemIDs
                )
            }
            guard turn.itemsView == .summary,
                  turn.items.count == 1,
                  let item = turn.items.first,
                  item.type == "agentMessage",
                  item.delivery == nil,
                  effectivePhase(
                    for: item,
                    agentMessagePhasesByItemID: agentMessagePhasesByItemID
                  ) != .commentary,
                  let text = item.text
            else {
                throw ReviewIngestionError.missingFinalReview
            }
            return try ReviewFinalResult(
                validating: text,
                source: .turnSummary(itemID: item.id)
            )
        }
    }

    private func effectivePhase(
        for item: TerminalItem,
        agentMessagePhasesByItemID: [String: ReviewAgentMessagePhase]
    ) -> ReviewAgentMessagePhase? {
        item.phase ?? agentMessagePhasesByItemID[item.id]
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from notification: CurrentV2ReviewNotificationEnvelope,
        method: String
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: notification.params)
        } catch {
            throw ReviewIngestionError.malformedKnownEvent(
                method: method,
                message: error.localizedDescription
            )
        }
    }
}
