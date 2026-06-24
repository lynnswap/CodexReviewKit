import Foundation

package struct AppServerReviewNotification: Decodable, Equatable, Sendable {
    package var method: Method
    package var payload: Payload
    package var rawPayload: AppServerJSONValue?
    package var rawNotification: CodexRawNotification

    package var rawMethod: String {
        method.rawValue
    }

    package init(method: String, paramsData: Data) throws {
        let rawPayload = try JSONDecoder().decode(AppServerJSONValue.self, from: paramsData)
        let payload: Payload
        if case .object = rawPayload,
           let decodedPayload = try? JSONDecoder().decode(Payload.self, from: paramsData) {
            payload = decodedPayload
        } else {
            payload = Payload(rawValue: rawPayload)
        }

        self.method = Method(rawValue: method)
        self.payload = payload
        self.rawPayload = rawPayload
        self.rawNotification = CodexRawNotification(
            method: method,
            params: paramsData,
            threadID: payload.threadID.map(CodexThreadID.init(rawValue:)),
            turnID: payload.resolvedTurnID.map(CodexTurnID.init(rawValue:))
        )
    }

    enum CodingKeys: String, CodingKey {
        case method
        case payload = "params"
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawMethod = try container.decode(String.self, forKey: .method)
        let rawPayload = container.contains(.payload)
            ? try container.decode(AppServerJSONValue.self, forKey: .payload)
            : nil
        let payload: Payload
        if case .object? = rawPayload,
           let decodedPayload = try? container.decodeIfPresent(Payload.self, forKey: .payload) {
            payload = decodedPayload
        } else {
            payload = Payload(rawValue: rawPayload)
        }

        self.method = Method(rawValue: rawMethod)
        self.payload = payload
        self.rawPayload = rawPayload
        self.rawNotification = CodexRawNotification(
            method: rawMethod,
            params: rawPayload.flatMap { try? JSONEncoder().encode($0) } ?? Data("null".utf8),
            threadID: payload.threadID.map(CodexThreadID.init(rawValue:)),
            turnID: payload.resolvedTurnID.map(CodexTurnID.init(rawValue:))
        )
    }

    package var startsReviewMode: Bool {
        method == .itemStarted && payload.item?.resolvedType == "enteredReviewMode"
    }

    package var finishesReviewMode: Bool {
        method == .itemCompleted && payload.item?.resolvedType == "exitedReviewMode"
    }
}

extension AppServerReviewNotification {
    package struct Method: RawRepresentable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible, Sendable {
        package var rawValue: String

        package init(rawValue: String) {
            self.rawValue = rawValue
        }

        package init(stringLiteral value: String) {
            self.rawValue = value
        }

        package var description: String {
            rawValue
        }

        package static let turnStarted: Self = "turn/started"
        package static let turnCompleted: Self = "turn/completed"
        package static let turnFailed: Self = "turn/failed"
        package static let turnCancelled: Self = "turn/cancelled"
        package static let turnAborted: Self = "turn/aborted"
        package static let turnDiffUpdated: Self = "turn/diff/updated"
        package static let turnPlanUpdated: Self = "turn/plan/updated"
        package static let itemStarted: Self = "item/started"
        package static let itemUpdated: Self = "item/updated"
        package static let itemCompleted: Self = "item/completed"
        package static let agentMessageDelta: Self = "item/agentMessage/delta"
        package static let planDelta: Self = "item/plan/delta"
        package static let reasoningSummaryTextDelta: Self = "item/reasoning/summaryTextDelta"
        package static let reasoningSummaryPartAdded: Self = "item/reasoning/summaryPartAdded"
        package static let reasoningTextDelta: Self = "item/reasoning/textDelta"
        package static let commandExecutionOutputDelta: Self = "item/commandExecution/outputDelta"
        package static let commandExecOutputDelta: Self = "command/exec/outputDelta"
        package static let processOutputDelta: Self = "process/outputDelta"
        package static let commandExecutionTerminalInteraction: Self =
            "item/commandExecution/terminalInteraction"
        package static let fileChangeOutputDelta: Self = "item/fileChange/outputDelta"
        package static let fileChangePatchUpdated: Self = "item/fileChange/patchUpdated"
        package static let mcpToolCallProgress: Self = "item/mcpToolCall/progress"
        package static let autoApprovalReviewStarted: Self = "item/autoApprovalReview/started"
        package static let autoApprovalReviewCompleted: Self = "item/autoApprovalReview/completed"
        package static let agentMessage: Self = "agent/message"
        package static let log: Self = "log"
        package static let error: Self = "error"
        package static let warning: Self = "warning"
        package static let guardianWarning: Self = "guardianWarning"
        package static let deprecationNotice: Self = "deprecationNotice"
        package static let configWarning: Self = "configWarning"
        package static let diagnostic: Self = "diagnostic"
        package static let modelRerouted: Self = "model/rerouted"
        package static let modelVerification: Self = "model/verification"
        package static let threadCompacted: Self = "thread/compacted"
        package static let threadClosed: Self = "thread/closed"
        package static let threadStatusChanged: Self = "thread/status/changed"

        package var isReviewNotificationMethod: Bool {
            switch self {
            case .threadClosed,
                 .threadStatusChanged,
                 .turnStarted,
                 .turnCompleted,
                 .turnFailed,
                 .turnCancelled,
                 .turnAborted,
                 .turnDiffUpdated,
                 .turnPlanUpdated,
                 .itemStarted,
                 .itemUpdated,
                 .itemCompleted,
                 .autoApprovalReviewStarted,
                 .autoApprovalReviewCompleted,
                 .agentMessageDelta,
                 .planDelta,
                 .reasoningSummaryTextDelta,
                 .reasoningSummaryPartAdded,
                 .reasoningTextDelta,
                 .commandExecutionOutputDelta,
                 .commandExecutionTerminalInteraction,
                 .commandExecOutputDelta,
                 .processOutputDelta,
                 .fileChangeOutputDelta,
                 .fileChangePatchUpdated,
                 .mcpToolCallProgress,
                 .agentMessage,
                 .log,
                 .error,
                 .modelRerouted,
                 .modelVerification,
                 .threadCompacted,
                 .warning,
                 .guardianWarning,
                 .deprecationNotice,
                 .configWarning,
                 .diagnostic:
                true
            default:
                false
            }
        }

        package var isThreadlessReviewBroadcast: Bool {
            switch self {
            case .warning, .deprecationNotice, .configWarning, .error:
                true
            default:
                false
            }
        }
    }
}

extension AppServerReviewNotification {
    package struct Payload: Decodable, Equatable, Sendable {
        package var threadID: String?
        package var turn: AppServerAPI.Turn.Payload?
        package var turnID: String?
        package var reviewThreadID: String?
        package var itemID: String?
        package var item: Item?
        package var rawValue: AppServerJSONValue?

        package var rawFields: [String: AppServerJSONValue] {
            if case .object(let value) = rawValue {
                return value
            }
            return [:]
        }

        package var resolvedTurnID: String? {
            guard let turnID = turn?.id, turnID.isEmpty == false else {
                return self.turnID
            }
            return turnID
        }

        package init(
            threadID: String? = nil,
            turn: AppServerAPI.Turn.Payload? = nil,
            turnID: String? = nil,
            reviewThreadID: String? = nil,
            itemID: String? = nil,
            item: Item? = nil,
            rawValue: AppServerJSONValue? = nil
        ) {
            self.threadID = threadID
            self.turn = turn
            self.turnID = turnID
            self.reviewThreadID = reviewThreadID
            self.itemID = itemID
            self.item = item
            self.rawValue = rawValue
        }

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
            case turn
            case turnID = "turnId"
            case reviewThreadID = "reviewThreadId"
            case itemID = "itemId"
            case item
        }

        package init(from decoder: Decoder) throws {
            let rawValue = try? AppServerJSONValue(from: decoder)
            guard case .object? = rawValue else {
                self.threadID = nil
                self.turn = nil
                self.turnID = nil
                self.reviewThreadID = nil
                self.itemID = nil
                self.item = nil
                self.rawValue = rawValue
                return
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.threadID = container.decodeReviewStringIfPresent(forKey: .threadID)
            self.turn = try? container.decodeIfPresent(AppServerAPI.Turn.Payload.self, forKey: .turn)
            self.turnID = container.decodeReviewStringIfPresent(forKey: .turnID)
            self.reviewThreadID = container.decodeReviewStringIfPresent(forKey: .reviewThreadID)
            self.itemID = container.decodeReviewStringIfPresent(forKey: .itemID)
            self.item = try? container.decodeIfPresent(Item.self, forKey: .item)
            self.rawValue = rawValue
        }
    }
}

extension AppServerReviewNotification.Payload {
    package struct Item: Decodable, Equatable, Sendable {
        package var id: String?
        package var type: String?
        package var kind: String?
        package var text: String?
        package var review: String?
        package var phase: String?
        package var command: String?
        package var cwd: String?
        package var aggregatedOutput: String?
        package var output: String?
        package var exitCode: Int?
        package var status: String?
        package var path: String?
        package var namespace: String?
        package var server: String?
        package var tool: String?
        package var name: String?
        package var query: String?
        package var prompt: String?
        package var summary: [String]?
        package var content: [String]?
        package var arguments: AppServerJSONValue?
        package var input: AppServerJSONValue?
        package var result: AppServerJSONValue?
        package var error: AppServerJSONValue?
        package var rawValue: AppServerJSONValue?

        package var resolvedType: String? {
            type ?? kind
        }

        enum CodingKeys: String, CodingKey {
            case id
            case type
            case kind
            case text
            case review
            case phase
            case command
            case cwd
            case aggregatedOutput
            case output
            case exitCode
            case status
            case path
            case namespace
            case server
            case tool
            case name
            case query
            case prompt
            case summary
            case content
            case arguments
            case input
            case result
            case error
        }

        package init(from decoder: Decoder) throws {
            rawValue = try? AppServerJSONValue(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = container.decodeReviewStringIfPresent(forKey: .id)
            type = container.decodeReviewStringIfPresent(forKey: .type)
            kind = container.decodeReviewStringIfPresent(forKey: .kind)
            text = container.decodeReviewStringIfPresent(forKey: .text)
            review = container.decodeReviewStringIfPresent(forKey: .review)
            phase = container.decodeReviewStringIfPresent(forKey: .phase)
            command = container.decodeReviewStringIfPresent(forKey: .command)
            cwd = container.decodeReviewStringIfPresent(forKey: .cwd)
            aggregatedOutput = container.decodeReviewStringIfPresent(forKey: .aggregatedOutput)
            output = container.decodeReviewStringIfPresent(forKey: .output)
            exitCode = try? container.decodeIfPresent(Int.self, forKey: .exitCode)
            status = container.decodeReviewStringIfPresent(forKey: .status)
            path = container.decodeReviewStringIfPresent(forKey: .path)
            namespace = container.decodeReviewStringIfPresent(forKey: .namespace)
            server = container.decodeReviewStringIfPresent(forKey: .server)
            tool = container.decodeReviewStringIfPresent(forKey: .tool)
            name = container.decodeReviewStringIfPresent(forKey: .name)
            query = container.decodeReviewStringIfPresent(forKey: .query)
            prompt = container.decodeReviewStringIfPresent(forKey: .prompt)
            summary = try? container.decodeIfPresent([String].self, forKey: .summary)
            content = try? container.decodeIfPresent([String].self, forKey: .content)
            arguments = try? container.decodeIfPresent(AppServerJSONValue.self, forKey: .arguments)
            input = try? container.decodeIfPresent(AppServerJSONValue.self, forKey: .input)
            result = try? container.decodeIfPresent(AppServerJSONValue.self, forKey: .result)
            error = try? container.decodeIfPresent(AppServerJSONValue.self, forKey: .error)
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeReviewStringIfPresent(forKey key: Key) -> String? {
        if let string = try? decode(String.self, forKey: key) {
            return string
        }
        if let int = try? decode(Int.self, forKey: key) {
            return String(int)
        }
        if let double = try? decode(Double.self, forKey: key) {
            return String(double)
        }
        if let bool = try? decode(Bool.self, forKey: key) {
            return bool ? "true" : "false"
        }
        return nil
    }
}
