import CodexReview
import Foundation

struct CurrentV2ReviewNotificationEnvelope: Sendable {
    var method: String
    var params: Data
    var threadID: String?
    var turnID: String?
    var stableReceipt: ReviewStableLifecycleReceipt?
}

struct ReviewStableLifecycleReceipt: Sendable {
    struct Key: Hashable, Sendable, CustomStringConvertible {
        var method: String
        var threadID: String
        var turnID: String?
        var itemID: String?

        var description: String {
            [method, threadID, turnID, itemID]
                .compactMap { $0 }
                .joined(separator: ":")
        }
    }

    struct Fingerprint: Equatable, Sendable {
        var canonicalJSON: Data
    }

    var key: Key
    var fingerprint: Fingerprint
}

struct CurrentV2ReviewNotificationDecodeFailure: Error, Sendable {
    var method: String
    var routedThreadID: String?
    var routedTurnID: String?
    var error: ReviewIngestionError
}

enum CurrentV2ReviewNotificationDecodeResult: Sendable {
    case review(CurrentV2ReviewNotificationEnvelope)
    case globalDiagnostic(CurrentV2ReviewNotificationEnvelope)
    case standaloneTraffic
    case unrelated
    case failure(CurrentV2ReviewNotificationDecodeFailure)
}

enum CurrentV2ReviewNotificationDecoder {
    static func decode(
        _ notification: JSONRPC.Notification
    ) -> CurrentV2ReviewNotificationDecodeResult {
        if standaloneMethods.contains(notification.method) {
            return .standaloneTraffic
        }
        if globalDiagnosticMethods.contains(notification.method) {
            return decodeKnown(notification, permitsMissingThreadID: true)
        }
        guard reviewMethods.contains(notification.method) else {
            return .unrelated
        }
        return decodeKnown(notification, permitsMissingThreadID: false)
    }

    private static func decodeKnown(
        _ notification: JSONRPC.Notification,
        permitsMissingThreadID: Bool
    ) -> CurrentV2ReviewNotificationDecodeResult {
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(
                with: notification.params,
                options: [.fragmentsAllowed]
            ) as? [String: Any] else {
                throw PayloadError("params must be a JSON object")
            }
            object = decoded
        } catch {
            return .failure(.init(
                method: notification.method,
                routedThreadID: nil,
                routedTurnID: nil,
                error: .malformedKnownEvent(
                    method: notification.method,
                    message: error.localizedDescription
                )
            ))
        }

        let threadID = nonemptyString(object["threadId"])
        let turnID = routedTurnID(method: notification.method, object: object)
        do {
            if permitsMissingThreadID == false, threadID == nil {
                throw ReviewIngestionError.missingRoutingIdentity(method: notification.method)
            }
            try validate(
                method: notification.method,
                object: object,
                threadID: threadID,
                turnID: turnID
            )
            let receipt = try stableReceipt(
                method: notification.method,
                object: object,
                threadID: threadID,
                turnID: turnID
            )
            let envelope = CurrentV2ReviewNotificationEnvelope(
                method: notification.method,
                params: notification.params,
                threadID: threadID,
                turnID: turnID,
                stableReceipt: receipt
            )
            if permitsMissingThreadID, threadID == nil {
                return .globalDiagnostic(envelope)
            }
            return .review(envelope)
        } catch let error as ReviewIngestionError {
            return .failure(.init(
                method: notification.method,
                routedThreadID: threadID,
                routedTurnID: turnID,
                error: error
            ))
        } catch {
            return .failure(.init(
                method: notification.method,
                routedThreadID: threadID,
                routedTurnID: turnID,
                error: .malformedKnownEvent(
                    method: notification.method,
                    message: error.localizedDescription
                )
            ))
        }
    }

    private static func validate(
        method: String,
        object: [String: Any],
        threadID: String?,
        turnID: String?
    ) throws {
        switch method {
        case "turn/started":
            guard turnID != nil else {
                throw ReviewIngestionError.missingRoutingIdentity(method: method)
            }
            _ = try requiredObject("turn", in: object)
        case "turn/completed":
            guard turnID != nil else {
                throw ReviewIngestionError.missingRoutingIdentity(method: method)
            }
            let turn = try requiredObject("turn", in: object)
            _ = try requiredString("status", in: turn)
            _ = try requiredString("itemsView", in: turn)
            let items = try requiredObjectArray("items", in: turn)
            for item in items {
                try validateItem(item, method: method)
            }
        case "item/started", "item/completed":
            guard threadID != nil, turnID != nil else {
                throw ReviewIngestionError.missingRoutingIdentity(method: method)
            }
            try validateItem(try requiredObject("item", in: object), method: method)
        case "item/agentMessage/delta",
            "item/plan/delta",
            "item/reasoning/summaryTextDelta",
            "item/reasoning/summaryPartAdded",
            "item/reasoning/textDelta",
            "item/commandExecution/outputDelta",
            "item/fileChange/outputDelta",
            "item/fileChange/patchUpdated",
            "item/mcpToolCall/progress",
            "item/commandExecution/terminalInteraction",
            "item/autoApprovalReview/started",
            "item/autoApprovalReview/completed":
            guard threadID != nil, turnID != nil else {
                throw ReviewIngestionError.missingRoutingIdentity(method: method)
            }
            _ = try requiredString("itemId", in: object)
            if deltaMethods.contains(method) {
                _ = try requiredStringAllowingEmpty("delta", in: object)
            }
        case "turn/diff/updated", "turn/plan/updated", "model/rerouted", "model/verification":
            guard threadID != nil, turnID != nil else {
                throw ReviewIngestionError.missingRoutingIdentity(method: method)
            }
        case "thread/closed", "thread/status/changed", "thread/compacted":
            guard threadID != nil else {
                throw ReviewIngestionError.missingRoutingIdentity(method: method)
            }
        case "agent/message", "log", "error", "turn/failed", "turn/cancelled",
            "warning", "guardianWarning", "deprecationNotice", "configWarning":
            break
        default:
            break
        }
    }

    private static func validateItem(_ item: [String: Any], method: String) throws {
        let type = try requiredString("type", in: item)
        _ = try requiredString("id", in: item)
        if type == "agentMessage" {
            _ = try requiredStringAllowingEmpty("text", in: item)
            if let delivery = item["delivery"], delivery is NSNull == false,
               delivery is String == false {
                throw ReviewIngestionError.malformedKnownEvent(
                    method: method,
                    message: "agentMessage.delivery must be a string or null"
                )
            }
        }
        if type == "exitedReviewMode" {
            _ = try requiredStringAllowingEmpty("review", in: item)
        }
    }

    private static func stableReceipt(
        method: String,
        object: [String: Any],
        threadID: String?,
        turnID: String?
    ) throws -> ReviewStableLifecycleReceipt? {
        let itemID: String?
        switch method {
        case "item/started", "item/completed":
            itemID = nonemptyString((object["item"] as? [String: Any])?["id"])
        case "turn/started", "turn/completed":
            itemID = nil
        default:
            return nil
        }
        guard let threadID else {
            return nil
        }
        let canonicalJSON = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        return .init(
            key: .init(
                method: method,
                threadID: threadID,
                turnID: turnID,
                itemID: itemID
            ),
            fingerprint: .init(canonicalJSON: canonicalJSON)
        )
    }

    private static func routedTurnID(method: String, object: [String: Any]) -> String? {
        switch method {
        case "turn/started", "turn/completed":
            return nonemptyString((object["turn"] as? [String: Any])?["id"])
        default:
            return nonemptyString(object["turnId"])
        }
    }

    private static func requiredObject(
        _ key: String,
        in object: [String: Any]
    ) throws -> [String: Any] {
        guard let value = object[key] as? [String: Any] else {
            throw PayloadError("\(key) must be an object")
        }
        return value
    }

    private static func requiredObjectArray(
        _ key: String,
        in object: [String: Any]
    ) throws -> [[String: Any]] {
        guard let value = object[key] as? [[String: Any]] else {
            throw PayloadError("\(key) must be an object array")
        }
        return value
    }

    private static func requiredString(
        _ key: String,
        in object: [String: Any]
    ) throws -> String {
        guard let value = nonemptyString(object[key]) else {
            throw PayloadError("\(key) must be a nonempty string")
        }
        return value
    }

    private static func requiredStringAllowingEmpty(
        _ key: String,
        in object: [String: Any]
    ) throws -> String {
        guard let value = object[key] as? String else {
            throw PayloadError("\(key) must be a string")
        }
        return value
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private struct PayloadError: LocalizedError {
        var message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? { message }
    }

    private static let standaloneMethods: Set<String> = [
        "command/exec/outputDelta",
        "process/outputDelta",
    ]

    private static let globalDiagnosticMethods: Set<String> = [
        "warning",
        "guardianWarning",
        "deprecationNotice",
        "configWarning",
        "error",
    ]

    private static let deltaMethods: Set<String> = [
        "item/agentMessage/delta",
        "item/plan/delta",
        "item/reasoning/summaryTextDelta",
        "item/reasoning/textDelta",
        "item/commandExecution/outputDelta",
        "item/fileChange/outputDelta",
    ]

    private static let reviewMethods: Set<String> = [
        "thread/closed",
        "thread/status/changed",
        "thread/compacted",
        "turn/started",
        "turn/completed",
        "turn/failed",
        "turn/cancelled",
        "turn/diff/updated",
        "turn/plan/updated",
        "item/started",
        "item/completed",
        "item/autoApprovalReview/started",
        "item/autoApprovalReview/completed",
        "item/agentMessage/delta",
        "item/plan/delta",
        "item/reasoning/summaryTextDelta",
        "item/reasoning/summaryPartAdded",
        "item/reasoning/textDelta",
        "item/commandExecution/outputDelta",
        "item/commandExecution/terminalInteraction",
        "item/fileChange/outputDelta",
        "item/fileChange/patchUpdated",
        "item/mcpToolCall/progress",
        "agent/message",
        "log",
        "model/rerouted",
        "model/verification",
    ]
}
