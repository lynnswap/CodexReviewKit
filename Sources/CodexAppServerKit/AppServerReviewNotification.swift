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
        package var turn: Turn?
        package var turnID: String?
        package var reviewThreadID: String?
        package var model: String?
        package var fromModel: String?
        package var toModel: String?
        package var reason: String?
        package var itemID: String?
        package var processID: String?
        package var processHandle: String?
        package var delta: String?
        package var deltaBase64: String?
        package var stdin: String?
        package var message: String?
        package var summary: String?
        package var details: String?
        package var diff: String?
        package var result: AppServerJSONValue?
        package var error: ErrorPayload?
        package var willRetry: Bool?
        package var status: Status?
        package var startedAtMs: Int64?
        package var completedAtMs: Int64?
        package var summaryIndex: Int?
        package var contentIndex: Int?
        package var plan: [PlanStep]
        package var verifications: [String]
        package var changes: [FileChange]
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
            turn: Turn? = nil,
            turnID: String? = nil,
            reviewThreadID: String? = nil,
            model: String? = nil,
            fromModel: String? = nil,
            toModel: String? = nil,
            reason: String? = nil,
            itemID: String? = nil,
            processID: String? = nil,
            processHandle: String? = nil,
            delta: String? = nil,
            deltaBase64: String? = nil,
            stdin: String? = nil,
            message: String? = nil,
            summary: String? = nil,
            details: String? = nil,
            diff: String? = nil,
            result: AppServerJSONValue? = nil,
            error: ErrorPayload? = nil,
            willRetry: Bool? = nil,
            status: Status? = nil,
            startedAtMs: Int64? = nil,
            completedAtMs: Int64? = nil,
            summaryIndex: Int? = nil,
            contentIndex: Int? = nil,
            plan: [PlanStep] = [],
            verifications: [String] = [],
            changes: [FileChange] = [],
            item: Item? = nil,
            rawValue: AppServerJSONValue? = nil
        ) {
            self.threadID = threadID
            self.turn = turn
            self.turnID = turnID
            self.reviewThreadID = reviewThreadID
            self.model = model
            self.fromModel = fromModel
            self.toModel = toModel
            self.reason = reason
            self.itemID = itemID
            self.processID = processID
            self.processHandle = processHandle
            self.delta = delta
            self.deltaBase64 = deltaBase64
            self.stdin = stdin
            self.message = message
            self.summary = summary
            self.details = details
            self.diff = diff
            self.result = result
            self.error = error
            self.willRetry = willRetry
            self.status = status
            self.startedAtMs = startedAtMs
            self.completedAtMs = completedAtMs
            self.summaryIndex = summaryIndex
            self.contentIndex = contentIndex
            self.plan = plan
            self.verifications = verifications
            self.changes = changes
            self.item = item
            self.rawValue = rawValue
        }

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
            case turn
            case turnID = "turnId"
            case reviewThreadID = "reviewThreadId"
            case model
            case fromModel
            case toModel
            case reason
            case itemID = "itemId"
            case processID = "processId"
            case processHandle
            case delta
            case deltaBase64
            case stdin
            case message
            case summary
            case details
            case diff
            case result
            case error
            case willRetry
            case status
            case startedAtMs
            case completedAtMs
            case summaryIndex
            case contentIndex
            case plan
            case verifications
            case changes
            case item
        }

        package init(from decoder: Decoder) throws {
            let rawValue = try? AppServerJSONValue(from: decoder)
            guard case .object? = rawValue else {
                self.threadID = nil
                self.turn = nil
                self.turnID = nil
                self.reviewThreadID = nil
                self.model = nil
                self.fromModel = nil
                self.toModel = nil
                self.reason = nil
                self.itemID = nil
                self.processID = nil
                self.processHandle = nil
                self.delta = nil
                self.deltaBase64 = nil
                self.stdin = nil
                self.message = nil
                self.summary = nil
                self.details = nil
                self.diff = nil
                self.result = nil
                self.error = nil
                self.willRetry = nil
                self.status = nil
                self.startedAtMs = nil
                self.completedAtMs = nil
                self.summaryIndex = nil
                self.contentIndex = nil
                self.plan = []
                self.verifications = []
                self.changes = []
                self.item = nil
                self.rawValue = rawValue
                return
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.threadID = container.decodeReviewStringIfPresent(forKey: .threadID)
            self.turn = try? container.decodeIfPresent(Turn.self, forKey: .turn)
            self.turnID = container.decodeReviewStringIfPresent(forKey: .turnID)
            self.reviewThreadID = container.decodeReviewStringIfPresent(forKey: .reviewThreadID)
            self.model = container.decodeReviewStringIfPresent(forKey: .model)
            self.fromModel = container.decodeReviewStringIfPresent(forKey: .fromModel)
            self.toModel = container.decodeReviewStringIfPresent(forKey: .toModel)
            self.reason = container.decodeReviewStringIfPresent(forKey: .reason)
            self.itemID = container.decodeReviewStringIfPresent(forKey: .itemID)
            self.processID = container.decodeReviewStringIfPresent(forKey: .processID)
            self.processHandle = container.decodeReviewStringIfPresent(forKey: .processHandle)
            self.delta = container.decodeReviewStringIfPresent(forKey: .delta)
            self.deltaBase64 = container.decodeReviewStringIfPresent(forKey: .deltaBase64)
            self.stdin = container.decodeReviewStringIfPresent(forKey: .stdin)
            self.message = container.decodeReviewStringIfPresent(forKey: .message)
            self.summary = container.decodeReviewStringIfPresent(forKey: .summary)
            self.details = container.decodeReviewStringIfPresent(forKey: .details)
            self.diff = container.decodeReviewStringIfPresent(forKey: .diff)
            self.result = try? container.decodeIfPresent(AppServerJSONValue.self, forKey: .result)
            self.error = try? container.decodeIfPresent(ErrorPayload.self, forKey: .error)
            self.willRetry = try? container.decodeIfPresent(Bool.self, forKey: .willRetry)
            self.status = try? container.decodeIfPresent(Status.self, forKey: .status)
            self.startedAtMs = try? container.decodeIfPresent(Int64.self, forKey: .startedAtMs)
            self.completedAtMs = try? container.decodeIfPresent(Int64.self, forKey: .completedAtMs)
            self.summaryIndex = try? container.decodeIfPresent(Int.self, forKey: .summaryIndex)
            self.contentIndex = try? container.decodeIfPresent(Int.self, forKey: .contentIndex)
            self.plan = (try? container.decodeIfPresent([PlanStep].self, forKey: .plan)) ?? []
            self.verifications = (try? container.decodeIfPresent([String].self, forKey: .verifications)) ?? []
            self.changes = (try? container.decodeIfPresent([FileChange].self, forKey: .changes)) ?? []
            self.item = try? container.decodeIfPresent(Item.self, forKey: .item)
            self.rawValue = rawValue
        }

        package struct ErrorPayload: Decodable, Equatable, Sendable {
            package var message: String?
            package var rawValue: AppServerJSONValue?

            enum CodingKeys: String, CodingKey {
                case message
            }

            package init(message: String? = nil, rawValue: AppServerJSONValue? = nil) {
                self.message = message
                self.rawValue = rawValue
            }

            package init(from decoder: Decoder) throws {
                rawValue = try? AppServerJSONValue(from: decoder)
                let singleValue = try decoder.singleValueContainer()
                if singleValue.decodeNil() {
                    message = nil
                } else if let value = try? singleValue.decode(String.self) {
                    message = value
                } else if let container = try? decoder.container(keyedBy: CodingKeys.self) {
                    message = container.decodeReviewStringIfPresent(forKey: .message)
                } else {
                    message = nil
                }
            }
        }

        package struct Turn: Decodable, Equatable, Sendable {
            package var id: String
            package var status: String?
            package var error: ErrorPayload?
            package var rawValue: AppServerJSONValue?

            enum CodingKeys: String, CodingKey {
                case id
                case status
                case error
            }

            package init(
                id: String,
                status: String? = nil,
                error: ErrorPayload? = nil,
                rawValue: AppServerJSONValue? = nil
            ) {
                self.id = id
                self.status = status
                self.error = error
                self.rawValue = rawValue
            }

            package init(from decoder: Decoder) throws {
                rawValue = try? AppServerJSONValue(from: decoder)
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = container.decodeReviewStringIfPresent(forKey: .id) ?? ""
                status = container.decodeReviewStringIfPresent(forKey: .status)
                error = try? container.decodeIfPresent(ErrorPayload.self, forKey: .error)
            }
        }

        package struct Status: Decodable, Equatable, Sendable {
            package var type: String
            package var rawValue: AppServerJSONValue?

            enum CodingKeys: String, CodingKey {
                case type
            }

            package init(type: String, rawValue: AppServerJSONValue? = nil) {
                self.type = type
                self.rawValue = rawValue
            }

            package init(from decoder: Decoder) throws {
                rawValue = try? AppServerJSONValue(from: decoder)
                let container = try decoder.container(keyedBy: CodingKeys.self)
                type = container.decodeReviewStringIfPresent(forKey: .type) ?? ""
            }
        }

        package struct PlanStep: Decodable, Equatable, Sendable {
            package var step: String
            package var status: String

            package init(step: String, status: String) {
                self.step = step
                self.status = status
            }
        }

        package struct FileChange: Decodable, Equatable, Sendable {
            package var path: String?
            package var kind: String?
            package var diff: String?

            package var summaryText: String {
                [kind, path, diff].compactMap { $0?.nilIfEmpty }.joined(separator: "\n")
            }

            enum CodingKeys: String, CodingKey {
                case path
                case kind
                case diff
            }

            package init(path: String? = nil, kind: String? = nil, diff: String? = nil) {
                self.path = path
                self.kind = kind
                self.diff = diff
            }

            package init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                path = container.decodeReviewStringIfPresent(forKey: .path)
                kind = container.decodeReviewStringIfPresent(forKey: .kind)
                diff = container.decodeReviewStringIfPresent(forKey: .diff)
            }
        }
    }
}

extension AppServerReviewNotification.Payload {
    package struct Item: Decodable, Equatable, Sendable {
        package var id: String
        package var type: String?
        package var kind: String?
        package var text: String?
        package var review: String?
        package var phase: String?
        package var command: String?
        package var cwd: String?
        package var processID: String?
        package var source: String?
        package var aggregatedOutput: String?
        package var hasAggregatedOutputField: Bool
        package var output: String?
        package var exitCode: Int?
        package var durationMs: Int?
        package var commandActions: [CommandAction]
        package var status: String?
        package var path: String?
        package var namespace: String?
        package var server: String?
        package var tool: String?
        package var name: String?
        package var query: String?
        package var prompt: String?
        package var summary: [String]
        package var summaryFragments: [TextFragment]
        package var content: [String]
        package var contentFragments: [TextFragment]
        package var fragments: [TextFragment]
        package var arguments: AppServerJSONValue?
        package var input: AppServerJSONValue?
        package var result: AppServerJSONValue?
        package var error: AppServerJSONValue?
        package var success: Bool?
        package var rawValue: AppServerJSONValue?

        package var resolvedType: String? {
            type ?? kind
        }

        package var rawType: String {
            resolvedType ?? "unknown"
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
            case processID = "processId"
            case source
            case aggregatedOutput
            case output
            case exitCode
            case durationMs
            case commandActions
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
            case fragments
            case arguments
            case input
            case result
            case error
            case success
        }

        package init(from decoder: Decoder) throws {
            rawValue = try? AppServerJSONValue(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = container.decodeReviewStringIfPresent(forKey: .id) ?? ""
            type = container.decodeReviewStringIfPresent(forKey: .type)
            kind = container.decodeReviewStringIfPresent(forKey: .kind)
            text = container.decodeReviewStringIfPresent(forKey: .text)
            review = container.decodeReviewStringIfPresent(forKey: .review)
            phase = container.decodeReviewStringIfPresent(forKey: .phase)
            command = container.decodeReviewStringIfPresent(forKey: .command)
            cwd = container.decodeReviewStringIfPresent(forKey: .cwd)
            processID = container.decodeReviewStringIfPresent(forKey: .processID)
            source = container.decodeReviewStringIfPresent(forKey: .source)
            hasAggregatedOutputField = container.contains(.aggregatedOutput)
            aggregatedOutput = container.decodeReviewStringIfPresent(forKey: .aggregatedOutput)?.nilIfEmpty
            output = container.decodeReviewStringIfPresent(forKey: .output)
            exitCode = try? container.decodeIfPresent(Int.self, forKey: .exitCode)
            durationMs = try? container.decodeIfPresent(Int.self, forKey: .durationMs)
            commandActions = (try? container.decodeIfPresent([CommandAction].self, forKey: .commandActions)) ?? []
            status = container.decodeReviewStringIfPresent(forKey: .status)
            path = container.decodeReviewStringIfPresent(forKey: .path)
            namespace = container.decodeReviewStringIfPresent(forKey: .namespace)
            server = container.decodeReviewStringIfPresent(forKey: .server)
            tool = container.decodeReviewStringIfPresent(forKey: .tool)
            name = container.decodeReviewStringIfPresent(forKey: .name)
            query = container.decodeReviewStringIfPresent(forKey: .query)
            prompt = container.decodeReviewStringIfPresent(forKey: .prompt)
            summary = (try? container.decodeIfPresent([String].self, forKey: .summary)) ?? []
            summaryFragments = (try? container.decodeIfPresent([TextFragment].self, forKey: .summary)) ?? []
            content = (try? container.decodeIfPresent([String].self, forKey: .content)) ?? []
            contentFragments = (try? container.decodeIfPresent([TextFragment].self, forKey: .content)) ?? []
            fragments = (try? container.decodeIfPresent([TextFragment].self, forKey: .fragments)) ?? []
            arguments = try? container.decodeIfPresent(AppServerJSONValue.self, forKey: .arguments)
            input = try? container.decodeIfPresent(AppServerJSONValue.self, forKey: .input)
            result = try? container.decodeIfPresent(AppServerJSONValue.self, forKey: .result)
            error = try? container.decodeIfPresent(AppServerJSONValue.self, forKey: .error)
            success = try? container.decodeIfPresent(Bool.self, forKey: .success)
        }

        package struct CommandAction: Decodable, Equatable, Sendable {
            package var kind: String
            package var command: String?
            package var name: String?
            package var path: String?
            package var query: String?

            enum CodingKeys: String, CodingKey {
                case type
                case kind
                case command
                case name
                case path
                case query
            }

            package init(
                kind: String,
                command: String? = nil,
                name: String? = nil,
                path: String? = nil,
                query: String? = nil
            ) {
                self.kind = kind
                self.command = command
                self.name = name
                self.path = path
                self.query = query
            }

            package init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                kind = container.decodeReviewStringIfPresent(forKey: .type)
                    ?? container.decodeReviewStringIfPresent(forKey: .kind)
                    ?? "unknown"
                command = container.decodeReviewStringIfPresent(forKey: .command)
                name = container.decodeReviewStringIfPresent(forKey: .name)
                path = container.decodeReviewStringIfPresent(forKey: .path)
                query = container.decodeReviewStringIfPresent(forKey: .query)
            }
        }

        package struct TextFragment: Decodable, Equatable, Sendable {
            package var text: String?

            enum CodingKeys: String, CodingKey {
                case text
            }

            package init(text: String? = nil) {
                self.text = text
            }

            package init(from decoder: Decoder) throws {
                let singleValueContainer = try decoder.singleValueContainer()
                if singleValueContainer.decodeNil() {
                    text = nil
                    return
                }
                if let text = try? singleValueContainer.decode(String.self) {
                    self.text = text
                    return
                }
                let container = try decoder.container(keyedBy: CodingKeys.self)
                text = container.decodeReviewStringIfPresent(forKey: .text)
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
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
