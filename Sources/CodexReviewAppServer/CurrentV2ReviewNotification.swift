import CodexReview
import CoreFoundation
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
    var isGlobalDiagnostic = false

    var requiresConnectionContainment: Bool {
        if case .missingRoutingIdentity = error {
            return true
        }
        return false
    }
}

enum CurrentV2ReviewNotificationDecodeResult: Sendable {
    case review(CurrentV2ReviewNotificationEnvelope)
    case globalDiagnostic(CurrentV2ReviewNotificationEnvelope)
    case standaloneTraffic
    case unrelated
    case failure(CurrentV2ReviewNotificationDecodeFailure)
}

enum CurrentV2ReviewNotificationDecoder {
    private enum IdentityRequirement: Equatable {
        case unscoped
        case optionalThread
        case thread
        case threadAndTurn
    }

    static func decode(
        _ notification: JSONRPC.Notification
    ) -> CurrentV2ReviewNotificationDecodeResult {
        if standaloneMethods.contains(notification.method) {
            return .standaloneTraffic
        }
        guard let identityRequirement = identityRequirements[notification.method] else {
            return .unrelated
        }
        return decodeKnown(
            notification,
            identityRequirement: identityRequirement
        )
    }

    private static func decodeKnown(
        _ notification: JSONRPC.Notification,
        identityRequirement: IdentityRequirement
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
                ),
                isGlobalDiagnostic: identityRequirement == .unscoped
                    || identityRequirement == .optionalThread
            ))
        }

        let threadID = nonemptyString(object["threadId"])
        let turnID = routedTurnID(method: notification.method, object: object)
        do {
            try validateIdentity(
                identityRequirement,
                method: notification.method,
                threadID: threadID,
                turnID: turnID
            )
            try validate(
                method: notification.method,
                object: object
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
            if identityRequirement == .unscoped
                || (identityRequirement == .optionalThread && threadID == nil) {
                return .globalDiagnostic(envelope)
            }
            return .review(envelope)
        } catch let error as ReviewIngestionError {
            return .failure(.init(
                method: notification.method,
                routedThreadID: threadID,
                routedTurnID: turnID,
                error: error,
                isGlobalDiagnostic: isGlobalDiagnostic(
                    identityRequirement: identityRequirement,
                    threadID: threadID,
                    error: error
                )
            ))
        } catch {
            return .failure(.init(
                method: notification.method,
                routedThreadID: threadID,
                routedTurnID: turnID,
                error: .malformedKnownEvent(
                    method: notification.method,
                    message: error.localizedDescription
                ),
                isGlobalDiagnostic: identityRequirement == .unscoped
                    || (identityRequirement == .optionalThread && threadID == nil)
            ))
        }
    }

    private static func isGlobalDiagnostic(
        identityRequirement: IdentityRequirement,
        threadID: String?,
        error: ReviewIngestionError
    ) -> Bool {
        if case .missingRoutingIdentity = error {
            return false
        }
        return identityRequirement == .unscoped
            || (identityRequirement == .optionalThread && threadID == nil)
    }

    private static func validateIdentity(
        _ requirement: IdentityRequirement,
        method: String,
        threadID: String?,
        turnID: String?
    ) throws {
        switch requirement {
        case .unscoped:
            break
        case .optionalThread:
            if threadID == nil, turnID != nil {
                throw ReviewIngestionError.missingRoutingIdentity(method: method)
            }
        case .thread:
            guard threadID != nil else {
                throw ReviewIngestionError.missingRoutingIdentity(method: method)
            }
        case .threadAndTurn:
            guard threadID != nil, turnID != nil else {
                throw ReviewIngestionError.missingRoutingIdentity(method: method)
            }
        }
    }

    private static func validate(
        method: String,
        object: [String: Any]
    ) throws {
        switch method {
        case "warning", "guardianWarning":
            _ = try requiredString("message", in: object)
        case "deprecationNotice", "configWarning":
            _ = try requiredString("summary", in: object)
        case "error":
            let error = try requiredObject("error", in: object)
            _ = try requiredString("message", in: error)
            _ = try requiredBool("willRetry", in: object)
        case "thread/closed", "thread/compacted":
            break
        case "thread/status/changed":
            try validateThreadStatus(try requiredObject("status", in: object))
        case "turn/started", "turn/completed":
            try validateTurn(try requiredObject("turn", in: object), method: method)
        case "turn/diff/updated":
            _ = try requiredString("diff", in: object)
        case "turn/plan/updated":
            try validatePlan(try requiredObjectArray("plan", in: object))
        case "item/started":
            _ = try requiredInteger("startedAtMs", in: object)
            try validateItem(try requiredObject("item", in: object), method: method)
        case "item/completed":
            _ = try requiredInteger("completedAtMs", in: object)
            try validateItem(try requiredObject("item", in: object), method: method)
        case "item/autoApprovalReview/started":
            try validateApprovalReview(object, completed: false)
        case "item/autoApprovalReview/completed":
            try validateApprovalReview(object, completed: true)
        case "item/agentMessage/delta",
            "item/plan/delta",
            "item/commandExecution/outputDelta",
            "item/fileChange/outputDelta":
            _ = try requiredNonemptyString("itemId", in: object)
            _ = try requiredString("delta", in: object)
        case "item/reasoning/summaryTextDelta":
            _ = try requiredNonemptyString("itemId", in: object)
            _ = try requiredString("delta", in: object)
            _ = try requiredInteger("summaryIndex", in: object)
        case "item/reasoning/summaryPartAdded":
            _ = try requiredNonemptyString("itemId", in: object)
            _ = try requiredInteger("summaryIndex", in: object)
        case "item/reasoning/textDelta":
            _ = try requiredNonemptyString("itemId", in: object)
            _ = try requiredString("delta", in: object)
            _ = try requiredInteger("contentIndex", in: object)
        case "item/commandExecution/terminalInteraction":
            _ = try requiredNonemptyString("itemId", in: object)
            _ = try requiredString("processId", in: object)
            _ = try requiredString("stdin", in: object)
        case "item/fileChange/patchUpdated":
            _ = try requiredNonemptyString("itemId", in: object)
            try validateFileChanges(try requiredObjectArray("changes", in: object))
        case "item/mcpToolCall/progress":
            _ = try requiredNonemptyString("itemId", in: object)
            _ = try requiredString("message", in: object)
        case "model/rerouted":
            _ = try requiredString("fromModel", in: object)
            _ = try requiredString("toModel", in: object)
            _ = try requiredEnum("reason", in: object, allowed: modelRerouteReasons)
        case "model/verification":
            let values = try requiredStringArray("verifications", in: object)
            try validateValues(values, key: "verifications", allowed: modelVerifications)
        default:
            break
        }
    }

    private static func validateTurn(
        _ turn: [String: Any],
        method: String
    ) throws {
        _ = try requiredNonemptyString("id", in: turn)
        _ = try requiredEnum("status", in: turn, allowed: turnStatuses)
        if turn.keys.contains("itemsView") {
            _ = try requiredEnum("itemsView", in: turn, allowed: turnItemsViews)
        }
        for item in try requiredObjectArray("items", in: turn) {
            try validateItem(item, method: method)
        }
    }

    private static func validateThreadStatus(_ status: [String: Any]) throws {
        let type = try requiredEnum("type", in: status, allowed: threadStatusTypes)
        if type == "active" {
            let flags = try requiredStringArray("activeFlags", in: status)
            try validateValues(flags, key: "activeFlags", allowed: threadActiveFlags)
        }
    }

    private static func validatePlan(_ steps: [[String: Any]]) throws {
        for step in steps {
            _ = try requiredString("step", in: step)
            _ = try requiredEnum("status", in: step, allowed: planStepStatuses)
        }
    }

    private static func validateApprovalReview(
        _ object: [String: Any],
        completed: Bool
    ) throws {
        _ = try requiredInteger("startedAtMs", in: object)
        if completed {
            _ = try requiredInteger("completedAtMs", in: object)
            _ = try requiredEnum("decisionSource", in: object, allowed: approvalDecisionSources)
        }
        _ = try requiredNonemptyString("reviewId", in: object)
        try validateOptionalNullableString("targetItemId", in: object)
        try validateApprovalReviewPayload(try requiredObject("review", in: object))
        try validateApprovalAction(try requiredObject("action", in: object))
    }

    private static func validateApprovalReviewPayload(_ review: [String: Any]) throws {
        _ = try requiredEnum("status", in: review, allowed: approvalReviewStatuses)
        try validateOptionalNullableEnum("riskLevel", in: review, allowed: approvalRiskLevels)
        try validateOptionalNullableEnum(
            "userAuthorization",
            in: review,
            allowed: approvalUserAuthorizations
        )
        try validateOptionalNullableString("rationale", in: review)
    }

    private static func validateApprovalAction(_ action: [String: Any]) throws {
        let type = try requiredEnum("type", in: action, allowed: approvalActionTypes)
        switch type {
        case "command":
            _ = try requiredString("command", in: action)
            _ = try requiredString("cwd", in: action)
            _ = try requiredEnum("source", in: action, allowed: approvalCommandSources)
        case "execve":
            _ = try requiredStringArray("argv", in: action)
            _ = try requiredString("cwd", in: action)
            _ = try requiredString("program", in: action)
            _ = try requiredEnum("source", in: action, allowed: approvalCommandSources)
        case "applyPatch":
            _ = try requiredString("cwd", in: action)
            _ = try requiredStringArray("files", in: action)
        case "networkAccess":
            _ = try requiredString("host", in: action)
            _ = try requiredInteger("port", in: action)
            _ = try requiredEnum("protocol", in: action, allowed: approvalNetworkProtocols)
            _ = try requiredString("target", in: action)
        case "mcpToolCall":
            _ = try requiredString("server", in: action)
            _ = try requiredString("toolName", in: action)
        case "requestPermissions":
            _ = try requiredObject("permissions", in: action)
        default:
            break
        }
    }

    private static func validateItem(_ item: [String: Any], method: String) throws {
        let type = try requiredNonemptyString("type", in: item)
        guard supportedItemTypes.contains(type) else {
            throw ReviewIngestionError.unsupportedItemType(
                method: method,
                type: type
            )
        }
        _ = try requiredNonemptyString("id", in: item)
        switch type {
        case "userMessage":
            try validateUserInputs(try requiredObjectArray("content", in: item))
        case "hookPrompt":
            try validateHookPromptFragments(try requiredObjectArray("fragments", in: item))
        case "agentMessage":
            _ = try requiredString("text", in: item)
            try validateOptionalNullableEnum("delivery", in: item, allowed: agentMessageDeliveries)
        case "plan":
            _ = try requiredString("text", in: item)
        case "reasoning":
            _ = try requiredStringArray("summary", in: item)
            _ = try requiredStringArray("content", in: item)
        case "commandExecution":
            _ = try requiredString("command", in: item)
            try validateCommandActions(try requiredObjectArray("commandActions", in: item))
            _ = try requiredString("cwd", in: item)
            _ = try requiredEnum("status", in: item, allowed: commandStatuses)
            _ = try requiredEnum("source", in: item, allowed: commandSources)
        case "fileChange":
            try validateFileChanges(try requiredObjectArray("changes", in: item))
            _ = try requiredEnum("status", in: item, allowed: commandStatuses)
        case "mcpToolCall":
            try requirePresent("arguments", in: item)
            _ = try requiredString("server", in: item)
            _ = try requiredEnum("status", in: item, allowed: toolStatuses)
            _ = try requiredString("tool", in: item)
        case "dynamicToolCall":
            try requirePresent("arguments", in: item)
            _ = try requiredEnum("status", in: item, allowed: toolStatuses)
            _ = try requiredString("tool", in: item)
        case "collabAgentToolCall":
            try validateCollabAgentStates(try requiredObject("agentsStates", in: item))
            _ = try requiredStringArray("receiverThreadIds", in: item)
            _ = try requiredString("senderThreadId", in: item)
            _ = try requiredEnum("status", in: item, allowed: toolStatuses)
            _ = try requiredEnum("tool", in: item, allowed: collabAgentTools)
        case "subAgentActivity":
            _ = try requiredString("agentPath", in: item)
            _ = try requiredString("agentThreadId", in: item)
            _ = try requiredEnum("kind", in: item, allowed: subAgentActivityKinds)
        case "webSearch":
            _ = try requiredString("query", in: item)
        case "imageView":
            _ = try requiredString("path", in: item)
        case "sleep":
            _ = try requiredInteger("durationMs", in: item)
        case "imageGeneration":
            _ = try requiredString("result", in: item)
            _ = try requiredString("status", in: item)
        case "enteredReviewMode", "exitedReviewMode":
            _ = try requiredString("review", in: item)
        case "contextCompaction":
            break
        default:
            break
        }
    }

    private static func validateUserInputs(_ inputs: [[String: Any]]) throws {
        for input in inputs {
            let type = try requiredEnum("type", in: input, allowed: userInputTypes)
            switch type {
            case "text":
                _ = try requiredString("text", in: input)
                _ = try requiredArray("text_elements", in: input)
            case "image", "audio":
                _ = try requiredString("url", in: input)
            case "localImage", "localAudio":
                _ = try requiredString("path", in: input)
            case "skill", "mention":
                _ = try requiredString("name", in: input)
                _ = try requiredString("path", in: input)
            default:
                break
            }
        }
    }

    private static func validateHookPromptFragments(_ fragments: [[String: Any]]) throws {
        for fragment in fragments {
            _ = try requiredString("hookRunId", in: fragment)
            _ = try requiredString("text", in: fragment)
        }
    }

    private static func validateCommandActions(_ actions: [[String: Any]]) throws {
        for action in actions {
            let type = try requiredEnum("type", in: action, allowed: commandActionTypes)
            _ = try requiredString("command", in: action)
            if type == "read" {
                _ = try requiredString("name", in: action)
                _ = try requiredString("path", in: action)
            }
        }
    }

    private static func validateFileChanges(_ changes: [[String: Any]]) throws {
        for change in changes {
            _ = try requiredString("diff", in: change)
            _ = try requiredString("path", in: change)
            let kind = try requiredObject("kind", in: change)
            _ = try requiredEnum("type", in: kind, allowed: patchChangeKinds)
        }
    }

    private static func validateCollabAgentStates(_ states: [String: Any]) throws {
        for (threadID, value) in states {
            guard let state = value as? [String: Any] else {
                throw PayloadError("agentsStates.\(threadID) must be an object")
            }
            _ = try requiredEnum("status", in: state, allowed: collabAgentStatuses)
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
        case "item/autoApprovalReview/started", "item/autoApprovalReview/completed":
            itemID = nonemptyString(object["reviewId"])
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

    private static func requiredArray(
        _ key: String,
        in object: [String: Any]
    ) throws -> [Any] {
        guard let value = object[key] as? [Any] else {
            throw PayloadError("\(key) must be an array")
        }
        return value
    }

    private static func requiredString(
        _ key: String,
        in object: [String: Any]
    ) throws -> String {
        guard let value = object[key] as? String else {
            throw PayloadError("\(key) must be a string")
        }
        return value
    }

    private static func requiredNonemptyString(
        _ key: String,
        in object: [String: Any]
    ) throws -> String {
        guard let value = nonemptyString(object[key]) else {
            throw PayloadError("\(key) must be a nonempty string")
        }
        return value
    }

    private static func requiredStringArray(
        _ key: String,
        in object: [String: Any]
    ) throws -> [String] {
        guard let value = object[key] as? [String] else {
            throw PayloadError("\(key) must be a string array")
        }
        return value
    }

    private static func requiredEnum(
        _ key: String,
        in object: [String: Any],
        allowed: Set<String>
    ) throws -> String {
        let value = try requiredString(key, in: object)
        guard allowed.contains(value) else {
            throw PayloadError("\(key) has unsupported value \(value)")
        }
        return value
    }

    private static func validateValues(
        _ values: [String],
        key: String,
        allowed: Set<String>
    ) throws {
        if let unsupported = values.first(where: { allowed.contains($0) == false }) {
            throw PayloadError("\(key) contains unsupported value \(unsupported)")
        }
    }

    private static func requiredBool(
        _ key: String,
        in object: [String: Any]
    ) throws -> Bool {
        guard let value = object[key] as? Bool else {
            throw PayloadError("\(key) must be a boolean")
        }
        return value
    }

    private static func requiredInteger(
        _ key: String,
        in object: [String: Any]
    ) throws -> NSNumber {
        guard let value = object[key] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite,
              value.doubleValue.rounded(.towardZero) == value.doubleValue
        else {
            throw PayloadError("\(key) must be an integer")
        }
        return value
    }

    private static func requirePresent(
        _ key: String,
        in object: [String: Any]
    ) throws {
        guard object.keys.contains(key) else {
            throw PayloadError("\(key) must be present")
        }
    }

    private static func validateOptionalNullableString(
        _ key: String,
        in object: [String: Any]
    ) throws {
        guard let value = object[key] else {
            return
        }
        guard value is NSNull || value is String else {
            throw PayloadError("\(key) must be a string or null")
        }
    }

    private static func validateOptionalNullableEnum(
        _ key: String,
        in object: [String: Any],
        allowed: Set<String>
    ) throws {
        guard let value = object[key], value is NSNull == false else {
            return
        }
        guard let string = value as? String else {
            throw PayloadError("\(key) must be a string or null")
        }
        guard allowed.contains(string) else {
            throw PayloadError("\(key) has unsupported value \(string)")
        }
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

    private static let identityRequirements: [String: IdentityRequirement] = [
        "warning": .optionalThread,
        "guardianWarning": .thread,
        "deprecationNotice": .unscoped,
        "configWarning": .unscoped,
        "error": .threadAndTurn,
        "thread/closed": .thread,
        "thread/status/changed": .thread,
        "thread/compacted": .threadAndTurn,
        "turn/started": .threadAndTurn,
        "turn/completed": .threadAndTurn,
        "turn/diff/updated": .threadAndTurn,
        "turn/plan/updated": .threadAndTurn,
        "item/started": .threadAndTurn,
        "item/completed": .threadAndTurn,
        "item/autoApprovalReview/started": .threadAndTurn,
        "item/autoApprovalReview/completed": .threadAndTurn,
        "item/agentMessage/delta": .threadAndTurn,
        "item/plan/delta": .threadAndTurn,
        "item/reasoning/summaryTextDelta": .threadAndTurn,
        "item/reasoning/summaryPartAdded": .threadAndTurn,
        "item/reasoning/textDelta": .threadAndTurn,
        "item/commandExecution/outputDelta": .threadAndTurn,
        "item/commandExecution/terminalInteraction": .threadAndTurn,
        "item/fileChange/outputDelta": .threadAndTurn,
        "item/fileChange/patchUpdated": .threadAndTurn,
        "item/mcpToolCall/progress": .threadAndTurn,
        "model/rerouted": .threadAndTurn,
        "model/verification": .threadAndTurn,
    ]

    private static let supportedItemTypes: Set<String> = [
        "userMessage",
        "hookPrompt",
        "agentMessage",
        "plan",
        "reasoning",
        "commandExecution",
        "fileChange",
        "mcpToolCall",
        "dynamicToolCall",
        "collabAgentToolCall",
        "subAgentActivity",
        "webSearch",
        "imageView",
        "sleep",
        "imageGeneration",
        "enteredReviewMode",
        "exitedReviewMode",
        "contextCompaction",
    ]

    private static let turnStatuses: Set<String> = [
        "completed", "interrupted", "failed", "inProgress",
    ]
    private static let turnItemsViews: Set<String> = ["notLoaded", "summary", "full"]
    private static let threadStatusTypes: Set<String> = [
        "notLoaded", "idle", "systemError", "active",
    ]
    private static let threadActiveFlags: Set<String> = [
        "waitingOnApproval", "waitingOnUserInput",
    ]
    private static let planStepStatuses: Set<String> = ["pending", "inProgress", "completed"]
    private static let modelRerouteReasons: Set<String> = ["highRiskCyberActivity"]
    private static let modelVerifications: Set<String> = ["trustedAccessForCyber"]
    private static let approvalDecisionSources: Set<String> = ["agent"]
    private static let approvalReviewStatuses: Set<String> = [
        "inProgress", "approved", "denied", "timedOut", "aborted",
    ]
    private static let approvalRiskLevels: Set<String> = ["low", "medium", "high", "critical"]
    private static let approvalUserAuthorizations: Set<String> = ["unknown", "low", "medium", "high"]
    private static let approvalActionTypes: Set<String> = [
        "command", "execve", "applyPatch", "networkAccess", "mcpToolCall", "requestPermissions",
    ]
    private static let approvalCommandSources: Set<String> = ["shell", "unifiedExec"]
    private static let approvalNetworkProtocols: Set<String> = [
        "http", "https", "socks5Tcp", "socks5Udp",
    ]
    private static let agentMessageDeliveries: Set<String> = ["async"]
    private static let commandStatuses: Set<String> = [
        "inProgress", "completed", "failed", "declined",
    ]
    private static let toolStatuses: Set<String> = ["inProgress", "completed", "failed"]
    private static let commandSources: Set<String> = [
        "agent", "userShell", "unifiedExecStartup", "unifiedExecInteraction",
    ]
    private static let commandActionTypes: Set<String> = ["read", "listFiles", "search", "unknown"]
    private static let patchChangeKinds: Set<String> = ["add", "delete", "update"]
    private static let collabAgentTools: Set<String> = [
        "spawnAgent", "sendInput", "resumeAgent", "wait", "closeAgent",
    ]
    private static let collabAgentStatuses: Set<String> = [
        "pendingInit", "running", "interrupted", "completed", "errored", "shutdown", "notFound",
    ]
    private static let subAgentActivityKinds: Set<String> = ["started", "interacted", "interrupted"]
    private static let userInputTypes: Set<String> = [
        "text", "image", "localImage", "audio", "localAudio", "skill", "mention",
    ]
}
