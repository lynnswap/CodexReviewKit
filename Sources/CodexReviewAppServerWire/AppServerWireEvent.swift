import Foundation
import CodexReviewDomain

public struct AppServerWireEvent: Equatable, Sendable {
    public var kind: ReviewWireEventKind
    public var itemKind: ReviewItemKind?
    public var itemID: ReviewTimelineItem.ID?
    public var timestamp: Date?

    public init(
        kind: ReviewWireEventKind,
        itemKind: ReviewItemKind? = nil,
        itemID: ReviewTimelineItem.ID? = nil,
        timestamp: Date? = nil
    ) {
        self.kind = kind
        self.itemKind = itemKind
        self.itemID = itemID
        self.timestamp = timestamp
    }
}

public indirect enum AppServerWireJSONValue: Decodable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: AppServerWireJSONValue])
    case array([AppServerWireJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: AppServerWireJSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([AppServerWireJSONValue].self))
        }
    }

    public var objectValue: [String: AppServerWireJSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    public var nonNullText: String? {
        switch self {
        case .null:
            return nil
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        case .object, .array:
            return jsonString
        }
    }

    public var jsonString: String {
        let fallback: String
        switch self {
        case .object:
            fallback = "{}"
        case .array:
            fallback = "[]"
        case .string(let value):
            fallback = value
        case .int(let value):
            fallback = String(value)
        case .double(let value):
            fallback = String(value)
        case .bool(let value):
            fallback = String(value)
        case .null:
            fallback = "null"
        }
        return Self.jsonText(foundationObject, fallback: fallback)
    }

    private var foundationObject: Any {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues(\.foundationObject)
        case .array(let value):
            return value.map(\.foundationObject)
        case .null:
            return NSNull()
        }
    }

    private static func jsonText(_ object: Any, fallback: String) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.fragmentsAllowed, .sortedKeys]
        ),
              let text = String(data: data, encoding: .utf8)
        else {
            return fallback
        }
        return text
    }
}

public struct AppServerWireReviewNotification: Decodable, Equatable, Sendable {
    public var method: ReviewWireEventKind
    public var payload: Payload
    public var rawPayload: AppServerWireJSONValue?

    public var rawMethod: String {
        method.rawValue
    }

    public init(
        method: ReviewWireEventKind,
        payload: Payload = Payload(),
        rawPayload: AppServerWireJSONValue? = nil
    ) {
        self.method = method
        self.payload = payload
        self.rawPayload = rawPayload
    }

    public enum CodingKeys: String, CodingKey {
        case method
        case payload = "params"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawMethod = try container.decode(String.self, forKey: .method)
        self.method = ReviewWireEventKind(rawValue: rawMethod)
        self.payload = try container.decodeIfPresent(Payload.self, forKey: .payload) ?? Payload()
        self.rawPayload = try container.decodeIfPresent(AppServerWireJSONValue.self, forKey: .payload)
    }

    public func domainEvents(fallbackReviewThreadID: ReviewThread.ID? = nil) -> [ReviewDomainEvent] {
        switch method {
        case .turnStarted:
            return [.runStarted(
                turnID: ReviewTurn.ID(rawValue: payload.resolvedTurnID ?? ""),
                reviewThreadID: payload.reviewThreadID.map(ReviewThread.ID.init(rawValue:)) ?? fallbackReviewThreadID,
                model: payload.model
            )]
        case .turnCompleted:
            return payload.turnCompletedEvents()
        case .turnFailed:
            return [.reviewFailed(payload.terminalMessage ?? "")]
        case .turnCancelled, .turnAborted:
            return [.reviewCancelled(payload.terminalMessage ?? "")]
        case .itemStarted:
            guard let item = payload.item else {
                return []
            }
            return [.itemStarted(payload.seed(for: item, phase: item.phase(default: .running)))]
        case .itemUpdated:
            return payload.itemUpdateEvents(method: method)
        case .itemCompleted:
            guard let item = payload.item else {
                return []
            }
            return [.itemCompleted(payload.seed(for: item, phase: item.phase(default: .completed)))]
        case .agentMessageDelta:
            return payload.deltaDomainEvent(
                kind: .agentMessage,
                family: .message,
                content: .message(.init(text: ""))
            )
        case .planDelta:
            return payload.deltaDomainEvent(
                kind: .plan,
                family: .plan,
                content: .plan(.init(markdown: ""))
            )
        case .reasoningSummaryTextDelta:
            return payload.deltaDomainEvent(
                kind: .reasoning,
                family: .reasoning,
                content: .reasoning(.init(text: "", style: .summary))
            )
        case .reasoningTextDelta:
            return payload.deltaDomainEvent(
                kind: .reasoning,
                family: .reasoning,
                content: .reasoning(.init(text: "", style: .raw))
            )
        case .commandExecutionOutputDelta, .commandExecOutputDelta, .processOutputDelta:
            return payload.deltaDomainEvent(
                kind: .commandExecution,
                family: .command,
                content: .command(.init(command: payload.item?.command ?? "", cwd: payload.item?.cwd)),
                delta: payload.outputDelta
            )
        case .commandExecutionTerminalInteraction:
            return payload.deltaDomainEvent(
                kind: .commandExecution,
                family: .command,
                content: .command(.init(command: payload.item?.command ?? "", cwd: payload.item?.cwd)),
                delta: payload.stdin
            )
        case .fileChangeOutputDelta:
            return payload.deltaDomainEvent(
                kind: .fileChange,
                family: .fileChange,
                content: .fileChange(.init(title: payload.item?.path ?? "")),
                delta: payload.delta
            )
        case .mcpToolCallProgress:
            return payload.toolProgressEvent(method: method)
        case .fileChangePatchUpdated:
            return payload.fileChangeUpdateEvent(method: method)
        case .turnDiffUpdated:
            return payload.diffUpdateEvent(method: method)
        case .turnPlanUpdated:
            return payload.planUpdateEvent(method: method)
        case .threadCompacted:
            return payload.contextCompactionEvent(method: method)
        case .threadClosed:
            return [.reviewFailed(payload.terminalMessage ?? payload.status?.type ?? "")]
        case .threadStatusChanged:
            return payload.threadStatusEvents(method: method)
        case .error:
            return payload.errorEvents(method: method)
        case .warning, .guardianWarning, .deprecationNotice, .configWarning, .diagnostic:
            return payload.diagnosticEvents(method: method)
        case .agentMessage:
            return payload.messageEvent(method: method)
        case .log:
            return payload.diagnosticEvents(method: method)
        default:
            return payload.unknownEvent(method: method)
        }
    }
}

public extension AppServerWireReviewNotification {
    struct Payload: Decodable, Equatable, Sendable {
        public var threadID: String?
        public var turn: Turn?
        public var turnID: String?
        public var reviewThreadID: String?
        public var model: String?
        public var itemID: String?
        public var delta: String?
        public var deltaBase64: String?
        public var stdin: String?
        public var message: String?
        public var summary: String?
        public var details: String?
        public var diff: String?
        public var result: AppServerWireJSONValue?
        public var error: ErrorPayload?
        public var willRetry: Bool?
        public var status: Status?
        public var startedAtMs: Int64?
        public var completedAtMs: Int64?
        public var plan: [PlanStep]
        public var verifications: [String]
        public var item: Item?
        public var rawValue: AppServerWireJSONValue?

        public var rawFields: [String: AppServerWireJSONValue] {
            rawValue?.objectValue ?? [:]
        }

        public init(
            threadID: String? = nil,
            turn: Turn? = nil,
            turnID: String? = nil,
            reviewThreadID: String? = nil,
            model: String? = nil,
            itemID: String? = nil,
            delta: String? = nil,
            deltaBase64: String? = nil,
            stdin: String? = nil,
            message: String? = nil,
            summary: String? = nil,
            details: String? = nil,
            diff: String? = nil,
            result: AppServerWireJSONValue? = nil,
            error: ErrorPayload? = nil,
            willRetry: Bool? = nil,
            status: Status? = nil,
            startedAtMs: Int64? = nil,
            completedAtMs: Int64? = nil,
            plan: [PlanStep] = [],
            verifications: [String] = [],
            item: Item? = nil,
            rawValue: AppServerWireJSONValue? = nil
        ) {
            self.threadID = threadID
            self.turn = turn
            self.turnID = turnID
            self.reviewThreadID = reviewThreadID
            self.model = model
            self.itemID = itemID
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
            self.plan = plan
            self.verifications = verifications
            self.item = item
            self.rawValue = rawValue
        }

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
            case turn
            case turnID = "turnId"
            case reviewThreadID = "reviewThreadId"
            case model
            case itemID = "itemId"
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
            case plan
            case verifications
            case item
        }

        public init(from decoder: Decoder) throws {
            self.rawValue = try? AppServerWireJSONValue(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.threadID = try container.decodeStringIfPresent(forKey: .threadID)
            self.turn = try? container.decodeIfPresent(Turn.self, forKey: .turn)
            self.turnID = try container.decodeStringIfPresent(forKey: .turnID)
            self.reviewThreadID = try container.decodeStringIfPresent(forKey: .reviewThreadID)
            self.model = try container.decodeStringIfPresent(forKey: .model)
            self.itemID = try container.decodeStringIfPresent(forKey: .itemID)
            self.delta = try container.decodeStringIfPresent(forKey: .delta)
            self.deltaBase64 = try container.decodeStringIfPresent(forKey: .deltaBase64)
            self.stdin = try container.decodeStringIfPresent(forKey: .stdin)
            self.message = try container.decodeStringIfPresent(forKey: .message)
            self.summary = try container.decodeStringIfPresent(forKey: .summary)
            self.details = try container.decodeStringIfPresent(forKey: .details)
            self.diff = try container.decodeStringIfPresent(forKey: .diff)
            self.result = try? container.decodeIfPresent(AppServerWireJSONValue.self, forKey: .result)
            self.error = try? container.decodeIfPresent(ErrorPayload.self, forKey: .error)
            self.willRetry = try? container.decodeIfPresent(Bool.self, forKey: .willRetry)
            self.status = try? container.decodeIfPresent(Status.self, forKey: .status)
            self.startedAtMs = try? container.decodeIfPresent(Int64.self, forKey: .startedAtMs)
            self.completedAtMs = try? container.decodeIfPresent(Int64.self, forKey: .completedAtMs)
            self.plan = (try? container.decodeIfPresent([PlanStep].self, forKey: .plan)) ?? []
            self.verifications = (try? container.decodeIfPresent([String].self, forKey: .verifications)) ?? []
            self.item = try? container.decodeIfPresent(Item.self, forKey: .item)
        }

        var resolvedTurnID: String? {
            turn?.id.nilIfEmpty ?? turnID
        }

        var terminalMessage: String? {
            turn?.error?.message?.nilIfEmpty
                ?? error?.message?.nilIfEmpty
                ?? message?.nilIfEmpty
                ?? summary?.nilIfEmpty
        }

        var diagnosticMessage: String? {
            if let message = message?.nilIfEmpty {
                return message
            }
            if let error = error?.message?.nilIfEmpty {
                return error
            }
            if let summary = summary?.nilIfEmpty,
               let details = details?.nilIfEmpty {
                return "\(summary)\n\(details)"
            }
            return summary?.nilIfEmpty ?? details?.nilIfEmpty
        }

        var outputDelta: String? {
            delta?.nilIfEmpty ?? decodedBase64Output?.nilIfEmpty
        }

        var decodedBase64Output: String? {
            guard let deltaBase64,
                  let data = Data(base64Encoded: deltaBase64)
            else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }

        func turnCompletedEvents() -> [ReviewDomainEvent] {
            switch terminalDisposition {
            case .failed:
                return [.reviewFailed(terminalMessage ?? "")]
            case .cancelled:
                return [.reviewCancelled(terminalMessage ?? "")]
            case .completed:
                return [.reviewCompleted(summary: message ?? summary ?? "", result: result?.nonNullText)]
            }
        }

        func itemUpdateEvents(method: ReviewWireEventKind) -> [ReviewDomainEvent] {
            if let item {
                return [.itemUpdated(seed(for: item, phase: item.phase(default: .running)))]
            }
            return unknownEvent(method: method)
        }

        func deltaDomainEvent(
            kind: ReviewItemKind,
            family: ReviewItemFamily,
            content: ReviewTimelineItem.Content,
            delta explicitDelta: String? = nil
        ) -> [ReviewDomainEvent] {
            guard let delta = explicitDelta ?? delta,
                  delta.isEmpty == false
            else {
                return []
            }
            return [.textDelta(
                itemID: .init(rawValue: itemID ?? syntheticItemID(method: kind.rawValue)),
                kind: kind,
                family: family,
                content: content,
                delta: delta
            )]
        }

        func toolProgressEvent(method: ReviewWireEventKind) -> [ReviewDomainEvent] {
            guard let message = message?.nilIfEmpty else {
                return unknownEvent(method: method)
            }
            return [.itemUpdated(ReviewTimelineItemSeed(
                id: .init(rawValue: itemID ?? syntheticItemID(method: method.rawValue)),
                kind: .mcpToolCall,
                family: .tool,
                phase: .running,
                content: .toolCall(.init(result: message))
            ))]
        }

        func fileChangeUpdateEvent(method: ReviewWireEventKind) -> [ReviewDomainEvent] {
            let item = item ?? Item(id: itemID ?? syntheticItemID(method: method.rawValue), type: .fileChange)
            return [.itemUpdated(seed(
                for: item,
                phase: item.phase(default: .running),
                content: .fileChange(.init(title: item.path ?? "", output: message ?? delta ?? diff ?? ""))
            ))]
        }

        func diffUpdateEvent(method: ReviewWireEventKind) -> [ReviewDomainEvent] {
            guard let diff = diff?.nilIfEmpty else {
                return unknownEvent(method: method)
            }
            return [.itemUpdated(ReviewTimelineItemSeed(
                id: .init(rawValue: itemID ?? syntheticItemID(method: method.rawValue)),
                kind: .fileChange,
                family: .fileChange,
                phase: .running,
                content: .fileChange(.init(title: "", output: diff))
            ))]
        }

        func planUpdateEvent(method: ReviewWireEventKind) -> [ReviewDomainEvent] {
            let markdown = plan.compactMap { step -> String? in
                switch (step.status.nilIfEmpty, step.step.nilIfEmpty) {
                case let (status?, step?):
                    return "[\(status)] \(step)"
                case let (status?, nil):
                    return "[\(status)]"
                case let (nil, step?):
                    return step
                case (nil, nil):
                    return nil
                }
            }.joined(separator: "\n")
            guard markdown.isEmpty == false else {
                return unknownEvent(method: method)
            }
            return [.itemUpdated(ReviewTimelineItemSeed(
                id: .init(rawValue: itemID ?? syntheticItemID(method: method.rawValue)),
                kind: .plan,
                family: .plan,
                phase: .running,
                content: .plan(.init(markdown: markdown))
            ))]
        }

        func contextCompactionEvent(method: ReviewWireEventKind) -> [ReviewDomainEvent] {
            [.itemCompleted(ReviewTimelineItemSeed(
                id: .init(rawValue: itemID ?? resolvedTurnID.map { "contextCompaction:\($0)" } ?? syntheticItemID(method: method.rawValue)),
                kind: .contextCompaction,
                family: .contextCompaction,
                phase: .completed,
                content: .contextCompaction(.init(title: status?.type ?? ""))
            ))]
        }

        func threadStatusEvents(method: ReviewWireEventKind) -> [ReviewDomainEvent] {
            switch normalizedStatus(status?.type) {
            case "notloaded", "closed":
                return [.reviewFailed(terminalMessage ?? status?.type ?? "")]
            case "cancelled", "canceled", "interrupted", "aborted":
                return [.reviewCancelled(terminalMessage ?? status?.type ?? "")]
            case "systemerror":
                return [.itemUpdated(diagnosticSeed(
                    method: method,
                    message: terminalMessage ?? status?.type ?? "",
                    phase: .running
                ))]
            default:
                return unknownEvent(method: method)
            }
        }

        func errorEvents(method: ReviewWireEventKind) -> [ReviewDomainEvent] {
            guard let message = diagnosticMessage else {
                return [.reviewFailed("")]
            }
            let diagnostic = diagnosticSeed(method: method, message: message, phase: willRetry == true ? .running : .failed)
            if willRetry == true {
                return [.itemUpdated(diagnostic)]
            }
            return [.itemUpdated(diagnostic), .reviewFailed(message)]
        }

        func diagnosticEvents(method: ReviewWireEventKind) -> [ReviewDomainEvent] {
            guard let message = diagnosticMessage else {
                return unknownEvent(method: method)
            }
            return [.itemUpdated(diagnosticSeed(method: method, message: message, phase: .running))]
        }

        func messageEvent(method: ReviewWireEventKind) -> [ReviewDomainEvent] {
            guard let message = message?.nilIfEmpty else {
                return unknownEvent(method: method)
            }
            return [.itemUpdated(ReviewTimelineItemSeed(
                id: .init(rawValue: itemID ?? syntheticItemID(method: method.rawValue)),
                kind: .agentMessage,
                family: .message,
                phase: .completed,
                content: .message(.init(text: message))
            ))]
        }

        func unknownEvent(method: ReviewWireEventKind) -> [ReviewDomainEvent] {
            [.itemUpdated(ReviewTimelineItemSeed(
                id: .init(rawValue: itemID ?? resolvedTurnID ?? syntheticItemID(method: method.rawValue)),
                kind: ReviewItemKind(rawValue: method.rawValue),
                family: .unknown,
                phase: .running,
                content: .unknown(.init(title: method.rawValue, detail: rawValue?.jsonString))
            ))]
        }

        func seed(
            for item: Item,
            phase: ReviewItemPhase,
            content explicitContent: ReviewTimelineItem.Content? = nil
        ) -> ReviewTimelineItemSeed {
            ReviewTimelineItemSeed(
                id: .init(rawValue: item.id.nilIfEmpty ?? itemID ?? syntheticItemID(method: item.type.rawValue)),
                kind: item.type,
                family: item.family,
                phase: phase,
                content: explicitContent ?? item.content(fallbackDelta: delta),
                startedAt: startedAt,
                completedAt: completedAt,
                durationMs: item.durationMs
            )
        }

        private var terminalDisposition: TerminalDisposition {
            switch normalizedStatus(turn?.status ?? status?.type) {
            case "failed", "failure", "error", "errored":
                return .failed
            case "cancelled", "canceled", "interrupted", "aborted":
                return .cancelled
            default:
                return .completed
            }
        }

        private var startedAt: Date? {
            startedAtMs.map(Self.date(millisecondsSince1970:))
        }

        private var completedAt: Date? {
            completedAtMs.map(Self.date(millisecondsSince1970:))
        }

        private func diagnosticSeed(
            method: ReviewWireEventKind,
            message: String,
            phase: ReviewItemPhase
        ) -> ReviewTimelineItemSeed {
            ReviewTimelineItemSeed(
                id: .init(rawValue: itemID ?? resolvedTurnID ?? syntheticItemID(method: method.rawValue)),
                kind: ReviewItemKind(rawValue: method.rawValue),
                family: .diagnostic,
                phase: phase,
                content: .diagnostic(.init(message: message))
            )
        }

        private func syntheticItemID(method: String) -> String {
            [resolvedTurnID, method].compactMap(\.self).joined(separator: ":").nilIfEmpty ?? method
        }

        private static func date(millisecondsSince1970 milliseconds: Int64) -> Date {
            Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        }
    }

    struct Turn: Decodable, Equatable, Sendable {
        public var id: String
        public var status: String?
        public var error: ErrorPayload?
        public var rawValue: AppServerWireJSONValue?

        public var rawFields: [String: AppServerWireJSONValue] {
            rawValue?.objectValue ?? [:]
        }

        public init(id: String, status: String? = nil, error: ErrorPayload? = nil, rawValue: AppServerWireJSONValue? = nil) {
            self.id = id
            self.status = status
            self.error = error
            self.rawValue = rawValue
        }

        enum CodingKeys: String, CodingKey {
            case id
            case status
            case error
        }

        public init(from decoder: Decoder) throws {
            self.rawValue = try? AppServerWireJSONValue(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decodeStringIfPresent(forKey: .id) ?? ""
            self.status = try container.decodeStringIfPresent(forKey: .status)
            self.error = try? container.decodeIfPresent(ErrorPayload.self, forKey: .error)
        }
    }

    struct ErrorPayload: Decodable, Equatable, Sendable {
        public var message: String?
        public var rawValue: AppServerWireJSONValue?

        public init(message: String? = nil, rawValue: AppServerWireJSONValue? = nil) {
            self.message = message
            self.rawValue = rawValue
        }

        enum CodingKeys: String, CodingKey {
            case message
        }

        public init(from decoder: Decoder) throws {
            self.rawValue = try? AppServerWireJSONValue(from: decoder)
            let singleValue = try decoder.singleValueContainer()
            if singleValue.decodeNil() {
                self.message = nil
            } else if let value = try? singleValue.decode(String.self) {
                self.message = value
            } else if let container = try? decoder.container(keyedBy: CodingKeys.self) {
                self.message = try container.decodeStringIfPresent(forKey: .message)
            } else {
                self.message = nil
            }
        }
    }

    struct Status: Decodable, Equatable, Sendable {
        public var type: String
        public var rawValue: AppServerWireJSONValue?

        public init(type: String, rawValue: AppServerWireJSONValue? = nil) {
            self.type = type
            self.rawValue = rawValue
        }

        enum CodingKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            self.rawValue = try? AppServerWireJSONValue(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.type = try container.decodeStringIfPresent(forKey: .type) ?? ""
        }
    }

    struct PlanStep: Decodable, Equatable, Sendable {
        public var step: String
        public var status: String

        public init(step: String, status: String) {
            self.step = step
            self.status = status
        }
    }

    struct Item: Decodable, Equatable, Sendable {
        public var id: String
        public var type: ReviewItemKind
        public var text: String?
        public var command: String?
        public var cwd: String?
        public var processID: String?
        public var source: String?
        public var aggregatedOutput: String?
        public var exitCode: Int?
        public var durationMs: Int?
        public var status: String?
        public var server: String?
        public var tool: String?
        public var namespace: String?
        public var query: String?
        public var path: String?
        public var review: String?
        public var prompt: String?
        public var summary: [String]
        public var content: [String]
        public var arguments: AppServerWireJSONValue?
        public var input: AppServerWireJSONValue?
        public var result: AppServerWireJSONValue?
        public var error: AppServerWireJSONValue?
        public var success: Bool?
        public var rawValue: AppServerWireJSONValue?

        public var rawType: String {
            type.rawValue
        }

        public var rawFields: [String: AppServerWireJSONValue] {
            rawValue?.objectValue ?? [:]
        }

        public init(
            id: String,
            type: ReviewItemKind,
            text: String? = nil,
            command: String? = nil,
            cwd: String? = nil,
            processID: String? = nil,
            source: String? = nil,
            aggregatedOutput: String? = nil,
            exitCode: Int? = nil,
            durationMs: Int? = nil,
            status: String? = nil,
            server: String? = nil,
            tool: String? = nil,
            namespace: String? = nil,
            query: String? = nil,
            path: String? = nil,
            review: String? = nil,
            prompt: String? = nil,
            summary: [String] = [],
            content: [String] = [],
            arguments: AppServerWireJSONValue? = nil,
            input: AppServerWireJSONValue? = nil,
            result: AppServerWireJSONValue? = nil,
            error: AppServerWireJSONValue? = nil,
            success: Bool? = nil,
            rawValue: AppServerWireJSONValue? = nil
        ) {
            self.id = id
            self.type = type
            self.text = text
            self.command = command
            self.cwd = cwd
            self.processID = processID
            self.source = source
            self.aggregatedOutput = aggregatedOutput
            self.exitCode = exitCode
            self.durationMs = durationMs
            self.status = status
            self.server = server
            self.tool = tool
            self.namespace = namespace
            self.query = query
            self.path = path
            self.review = review
            self.prompt = prompt
            self.summary = summary
            self.content = content
            self.arguments = arguments
            self.input = input
            self.result = result
            self.error = error
            self.success = success
            self.rawValue = rawValue
        }

        enum CodingKeys: String, CodingKey {
            case id
            case type
            case text
            case command
            case cwd
            case processID = "processId"
            case source
            case aggregatedOutput
            case exitCode
            case durationMs
            case status
            case server
            case tool
            case namespace
            case query
            case path
            case review
            case prompt
            case summary
            case content
            case arguments
            case input
            case result
            case error
            case success
        }

        public init(from decoder: Decoder) throws {
            self.rawValue = try? AppServerWireJSONValue(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decodeStringIfPresent(forKey: .id) ?? ""
            self.type = ReviewItemKind(rawValue: try container.decodeStringIfPresent(forKey: .type) ?? "unknown")
            self.text = try container.decodeStringIfPresent(forKey: .text)
            self.command = try container.decodeStringIfPresent(forKey: .command)
            self.cwd = try container.decodeStringIfPresent(forKey: .cwd)
            self.processID = try container.decodeStringIfPresent(forKey: .processID)
            self.source = try container.decodeStringIfPresent(forKey: .source)
            self.aggregatedOutput = try container.decodeStringIfPresent(forKey: .aggregatedOutput)
            self.exitCode = try? container.decodeIfPresent(Int.self, forKey: .exitCode)
            self.durationMs = try? container.decodeIfPresent(Int.self, forKey: .durationMs)
            self.status = try container.decodeStringIfPresent(forKey: .status)
            self.server = try container.decodeStringIfPresent(forKey: .server)
            self.tool = try container.decodeStringIfPresent(forKey: .tool)
            self.namespace = try container.decodeStringIfPresent(forKey: .namespace)
            self.query = try container.decodeStringIfPresent(forKey: .query)
            self.path = try container.decodeStringIfPresent(forKey: .path)
            self.review = try container.decodeStringIfPresent(forKey: .review)
            self.prompt = try container.decodeStringIfPresent(forKey: .prompt)
            self.summary = (try? container.decodeIfPresent([String].self, forKey: .summary)) ?? []
            self.content = (try? container.decodeIfPresent([String].self, forKey: .content)) ?? []
            self.arguments = try? container.decodeIfPresent(AppServerWireJSONValue.self, forKey: .arguments)
            self.input = try? container.decodeIfPresent(AppServerWireJSONValue.self, forKey: .input)
            self.result = try? container.decodeIfPresent(AppServerWireJSONValue.self, forKey: .result)
            self.error = try? container.decodeIfPresent(AppServerWireJSONValue.self, forKey: .error)
            self.success = try? container.decodeIfPresent(Bool.self, forKey: .success)
        }

        var family: ReviewItemFamily {
            switch type.rawValue {
            case ReviewItemKind.agentMessage.rawValue,
                "userMessage",
                "exitedReviewMode":
                return .message
            case ReviewItemKind.commandExecution.rawValue:
                return .command
            case ReviewItemKind.fileChange.rawValue:
                return .fileChange
            case ReviewItemKind.plan.rawValue:
                return .plan
            case ReviewItemKind.reasoning.rawValue:
                return .reasoning
            case ReviewItemKind.contextCompaction.rawValue:
                return .contextCompaction
            case ReviewItemKind.webSearch.rawValue:
                return .search
            case ReviewItemKind.mcpToolCall.rawValue,
                ReviewItemKind.dynamicToolCall.rawValue,
                "collabAgentToolCall",
                ReviewItemKind.imageGeneration.rawValue,
                ReviewItemKind.imageView.rawValue:
                return .tool
            case "hookPrompt", "autoApprovalReview":
                return .approval
            case "enteredReviewMode":
                return .lifecycle
            case "diagnostic", "warning":
                return .diagnostic
            default:
                return .unknown
            }
        }

        func phase(default defaultPhase: ReviewItemPhase) -> ReviewItemPhase {
            if let status = normalizedStatus(status) {
                switch status {
                case "approved", "completed", "succeeded", "success":
                    return .completed
                case "cancelled", "canceled", "interrupted", "aborted":
                    return .cancelled
                case "failed", "failure", "error", "errored":
                    return .failed
                case "incomplete":
                    return .incomplete
                case "skipped":
                    return .skipped
                case "approval", "awaitingapproval", "pendingapproval":
                    return .awaitingApproval
                case "queued", "pending":
                    return .queued
                case "waiting", "waitingforinput", "inputrequired":
                    return .waitingForInput
                case "inprogress", "running", "started":
                    return .running
                default:
                    break
                }
            }
            if error?.nonNullText?.nilIfEmpty != nil || success == false {
                return .failed
            }
            if success == true {
                return .completed
            }
            return defaultPhase
        }

        func content(fallbackDelta: String?) -> ReviewTimelineItem.Content {
            switch family {
            case .message:
                return .message(.init(text: text ?? review ?? fallbackDelta ?? ""))
            case .command:
                return .command(.init(
                    command: command ?? "",
                    cwd: cwd,
                    output: aggregatedOutput ?? fallbackDelta ?? "",
                    exitCode: exitCode
                ))
            case .fileChange:
                return .fileChange(.init(title: path ?? "", output: aggregatedOutput ?? text ?? fallbackDelta ?? ""))
            case .plan:
                return .plan(.init(markdown: text ?? fallbackDelta ?? ""))
            case .reasoning:
                let summaryText = summary.joined(separator: "\n").nilIfEmpty
                let contentText = content.joined(separator: "\n").nilIfEmpty
                let style: ReviewTimelineItem.Reasoning.Style = summaryText == nil ? .raw : .summary
                return .reasoning(.init(text: text ?? summaryText ?? contentText ?? fallbackDelta ?? "", style: style))
            case .contextCompaction:
                return .contextCompaction(.init(title: status ?? text ?? ""))
            case .search:
                return .search(.init(query: query ?? text ?? "", result: result?.nonNullText))
            case .tool:
                return .toolCall(.init(
                    namespace: namespace,
                    server: server,
                    tool: tool,
                    arguments: arguments?.nonNullText ?? input?.nonNullText,
                    result: result?.nonNullText,
                    error: error?.nonNullText
                ))
            case .approval:
                return .approval(.init(title: prompt ?? text ?? "", detail: review))
            case .diagnostic:
                return .diagnostic(.init(message: text ?? error?.nonNullText ?? fallbackDelta ?? ""))
            case .lifecycle, .unknown:
                return .unknown(.init(title: type.rawValue, detail: rawValue?.jsonString))
            }
        }
    }
}

private enum TerminalDisposition {
    case completed
    case failed
    case cancelled
}

private extension ReviewWireEventKind {
    static let turnCompleted: Self = "turn/completed"
    static let turnFailed: Self = "turn/failed"
    static let turnCancelled: Self = "turn/cancelled"
    static let turnAborted: Self = "turn/aborted"
    static let turnDiffUpdated: Self = "turn/diff/updated"
    static let turnPlanUpdated: Self = "turn/plan/updated"
    static let itemUpdated: Self = "item/updated"
    static let commandExecOutputDelta: Self = "command/exec/outputDelta"
    static let processOutputDelta: Self = "process/outputDelta"
    static let commandExecutionTerminalInteraction: Self = "item/commandExecution/terminalInteraction"
    static let fileChangePatchUpdated: Self = "item/fileChange/patchUpdated"
    static let agentMessage: Self = "agent/message"
    static let log: Self = "log"
    static let error: Self = "error"
    static let warning: Self = "warning"
    static let guardianWarning: Self = "guardianWarning"
    static let deprecationNotice: Self = "deprecationNotice"
    static let configWarning: Self = "configWarning"
    static let diagnostic: Self = "diagnostic"
    static let threadCompacted: Self = "thread/compacted"
    static let threadClosed: Self = "thread/closed"
    static let threadStatusChanged: Self = "thread/status/changed"
}

private extension KeyedDecodingContainer {
    func decodeStringIfPresent(forKey key: Key) throws -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private func normalizedStatus(_ value: String?) -> String? {
    value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "_", with: "")
        .replacingOccurrences(of: "-", with: "")
        .nilIfEmpty
}
