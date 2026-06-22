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

public struct AppServerWireReviewNotification: Decodable, Equatable, Sendable {
    public var method: ReviewWireEventKind
    public var payload: Payload

    public init(method: ReviewWireEventKind, payload: Payload = Payload()) {
        self.method = method
        self.payload = payload
    }

    public enum CodingKeys: String, CodingKey {
        case method
        case payload = "params"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.method = ReviewWireEventKind(rawValue: try container.decode(String.self, forKey: .method))
        self.payload = try container.decodeIfPresent(Payload.self, forKey: .payload) ?? Payload()
    }

    public func domainEvents(fallbackReviewThreadID: ReviewThread.ID? = nil) -> [ReviewDomainEvent] {
        switch method {
        case .turnStarted:
            return [.runStarted(
                turnID: ReviewTurn.ID(rawValue: payload.turnID ?? ""),
                reviewThreadID: payload.reviewThreadID.map(ReviewThread.ID.init(rawValue:)) ?? fallbackReviewThreadID,
                model: payload.model
            )]
        case .itemStarted:
            guard let item = payload.item else {
                return []
            }
            return [.itemStarted(item.seed(phase: .running, fallbackDelta: payload.delta))]
        case .itemCompleted:
            guard let item = payload.item else {
                return []
            }
            return [.itemCompleted(item.seed(
                phase: ReviewItemPhase.normalized(item.status),
                fallbackDelta: payload.delta
            ))]
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
        case .commandExecutionOutputDelta:
            return payload.deltaDomainEvent(
                kind: .commandExecution,
                family: .command,
                content: .command(.init(command: payload.item?.command ?? "Command"))
            )
        case .fileChangeOutputDelta:
            return payload.deltaDomainEvent(
                kind: .fileChange,
                family: .fileChange,
                content: .fileChange(.init(title: "File changes"))
            )
        default:
            return []
        }
    }
}

public extension AppServerWireReviewNotification {
    struct Payload: Decodable, Equatable, Sendable {
        public var turnID: String?
        public var reviewThreadID: String?
        public var model: String?
        public var itemID: String?
        public var delta: String?
        public var item: Item?

        public init(
            turnID: String? = nil,
            reviewThreadID: String? = nil,
            model: String? = nil,
            itemID: String? = nil,
            delta: String? = nil,
            item: Item? = nil
        ) {
            self.turnID = turnID
            self.reviewThreadID = reviewThreadID
            self.model = model
            self.itemID = itemID
            self.delta = delta
            self.item = item
        }

        enum CodingKeys: String, CodingKey {
            case turnID = "turnId"
            case reviewThreadID = "reviewThreadId"
            case model
            case itemID = "itemId"
            case delta
            case item
        }

        func deltaDomainEvent(
            kind: ReviewItemKind,
            family: ReviewItemFamily,
            content: ReviewTimelineItem.Content
        ) -> [ReviewDomainEvent] {
            guard let itemID,
                  let delta,
                  delta.isEmpty == false
            else {
                return []
            }
            return [.textDelta(
                itemID: .init(rawValue: itemID),
                kind: kind,
                family: family,
                content: content,
                delta: delta
            )]
        }
    }

    struct Item: Decodable, Equatable, Sendable {
        public var id: String
        public var type: ReviewItemKind
        public var text: String?
        public var command: String?
        public var status: String?
        public var server: String?
        public var tool: String?
        public var namespace: String?
        public var query: String?

        public init(
            id: String,
            type: ReviewItemKind,
            text: String? = nil,
            command: String? = nil,
            status: String? = nil,
            server: String? = nil,
            tool: String? = nil,
            namespace: String? = nil,
            query: String? = nil
        ) {
            self.id = id
            self.type = type
            self.text = text
            self.command = command
            self.status = status
            self.server = server
            self.tool = tool
            self.namespace = namespace
            self.query = query
        }

        enum CodingKeys: String, CodingKey {
            case id
            case type
            case text
            case command
            case status
            case server
            case tool
            case namespace
            case query
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            self.type = ReviewItemKind(rawValue: try container.decodeIfPresent(String.self, forKey: .type) ?? "unknown")
            self.text = try container.decodeIfPresent(String.self, forKey: .text)
            self.command = try container.decodeIfPresent(String.self, forKey: .command)
            self.status = try container.decodeIfPresent(String.self, forKey: .status)
            self.server = try container.decodeIfPresent(String.self, forKey: .server)
            self.tool = try container.decodeIfPresent(String.self, forKey: .tool)
            self.namespace = try container.decodeIfPresent(String.self, forKey: .namespace)
            self.query = try container.decodeIfPresent(String.self, forKey: .query)
        }

        func seed(phase: ReviewItemPhase, fallbackDelta: String?) -> ReviewTimelineItemSeed {
            ReviewTimelineItemSeed(
                id: .init(rawValue: id),
                kind: type,
                family: family,
                phase: phase,
                content: content(fallbackDelta: fallbackDelta)
            )
        }

        private var family: ReviewItemFamily {
            switch type.rawValue {
            case ReviewItemKind.agentMessage.rawValue:
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
                ReviewItemKind.dynamicToolCall.rawValue:
                return .tool
            default:
                return .unknown
            }
        }

        private func content(fallbackDelta: String?) -> ReviewTimelineItem.Content {
            switch family {
            case .message:
                return .message(.init(text: text ?? fallbackDelta ?? ""))
            case .command:
                return .command(.init(command: command ?? "Command"))
            case .fileChange:
                return .fileChange(.init(title: "File changes", output: fallbackDelta ?? ""))
            case .plan:
                return .plan(.init(markdown: text ?? fallbackDelta ?? ""))
            case .reasoning:
                return .reasoning(.init(text: text ?? fallbackDelta ?? "", style: .summary))
            case .contextCompaction:
                return .contextCompaction(.init(title: text ?? "Context compaction"))
            case .search:
                return .search(.init(query: query ?? text ?? "Search"))
            case .tool:
                return .toolCall(.init(namespace: namespace, server: server, tool: tool))
            case .approval, .diagnostic, .lifecycle, .unknown:
                return .unknown(.init(title: type.rawValue, detail: text))
            }
        }
    }
}
