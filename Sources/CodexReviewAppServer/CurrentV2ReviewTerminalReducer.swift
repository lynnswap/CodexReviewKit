import CodexReview
import Foundation

struct CurrentV2ReviewAttemptIdentity: Equatable, Sendable {
    var threadID: String
    var turnID: String
}

enum CurrentV2ReviewAttemptIngestion: Equatable, Sendable {
    case accepted(ReviewAttemptTerminal?)
    case duplicate
    case foreignIdentity
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
    }

    private let identity: CurrentV2ReviewAttemptIdentity
    private let outputStrategy: ReviewTerminalOutputStrategy
    private var receipts: [ReviewStableLifecycleReceipt.Key: ReviewStableLifecycleReceipt.Fingerprint] = [:]
    private var reviewMarker: ReviewMarker?
    private var terminal: ReviewAttemptTerminal?

    init(
        identity: CurrentV2ReviewAttemptIdentity,
        outputStrategy: ReviewTerminalOutputStrategy = .currentV2
    ) {
        self.identity = identity
        self.outputStrategy = outputStrategy
    }

    mutating func ingest(
        _ notification: CurrentV2ReviewNotificationEnvelope
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
            let resolved = resolveTerminal(payload.turn)
            terminal = resolved
            return .accepted(resolved)
        default:
            return .accepted(nil)
        }
    }

    private func resolveTerminal(_ turn: TerminalPayload.Turn) -> ReviewAttemptTerminal {
        switch turn.status {
        case "completed":
            do {
                return .completed(try finalResult(from: turn))
            } catch let error as ReviewIngestionError {
                return .failed(message: error.localizedDescription)
            } catch {
                return .failed(message: error.localizedDescription)
            }
        case "interrupted":
            return .interrupted(message: turn.error?.message)
        case "failed":
            return .failed(message: turn.error?.message)
        case "inProgress":
            return .failed(
                message: ReviewIngestionError.invalidTerminalStatus(turn.status).localizedDescription
            )
        default:
            return .failed(
                message: ReviewIngestionError.invalidTerminalStatus(turn.status).localizedDescription
            )
        }
    }

    private func finalResult(from turn: TerminalPayload.Turn) throws -> ReviewFinalResult {
        switch outputStrategy {
        case .currentV2:
            if let reviewMarker {
                let companionItemIDs = Set(
                    turn.items.compactMap { item -> String? in
                        guard item.type == "agentMessage",
                              item.delivery == nil,
                              item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        else {
                            return nil
                        }
                        return item.id
                    }
                )
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
