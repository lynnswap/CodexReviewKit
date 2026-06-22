import Foundation
import CodexReviewDomain

public struct ReviewMCPProjection: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public var id: ReviewTimelineItem.ID
        public var kind: ReviewItemKind
        public var family: ReviewItemFamily
        public var phase: ReviewItemPhase
        public var isActive: Bool
        public var content: Content
        public var createdAt: Date
        public var updatedAt: Date
        public var startedAt: Date?
        public var completedAt: Date?
        public var durationMs: Int?

        @MainActor
        public init(item: ReviewTimelineItem, isActive: Bool) {
            self.id = item.id
            self.kind = item.kind
            self.family = item.family
            self.phase = item.phase
            self.isActive = isActive
            self.content = Content(item.content)
            self.createdAt = item.createdAt
            self.updatedAt = item.updatedAt
            self.startedAt = item.startedAt
            self.completedAt = item.completedAt
            self.durationMs = item.durationMs
        }
    }

    public enum Content: Sendable, Equatable {
        case approval(Approval)
        case command(Command)
        case contextCompaction(ContextCompaction)
        case diagnostic(Diagnostic)
        case fileChange(FileChange)
        case message(Message)
        case plan(Plan)
        case reasoning(Reasoning)
        case search(Search)
        case toolCall(ToolCall)
        case unknown(Unknown)

        public var type: String {
            switch self {
            case .approval:
                "approval"
            case .command:
                "command"
            case .contextCompaction:
                "contextCompaction"
            case .diagnostic:
                "diagnostic"
            case .fileChange:
                "fileChange"
            case .message:
                "message"
            case .plan:
                "plan"
            case .reasoning:
                "reasoning"
            case .search:
                "search"
            case .toolCall:
                "toolCall"
            case .unknown:
                "unknown"
            }
        }

        public init(_ content: ReviewTimelineItem.Content) {
            switch content {
            case .approval(let approval):
                self = .approval(.init(title: approval.title, detail: approval.detail))
            case .command(let command):
                self = .command(.init(
                    command: command.command,
                    cwd: command.cwd,
                    output: command.output,
                    exitCode: command.exitCode
                ))
            case .contextCompaction(let contextCompaction):
                self = .contextCompaction(.init(title: contextCompaction.title))
            case .diagnostic(let diagnostic):
                self = .diagnostic(.init(message: diagnostic.message))
            case .fileChange(let fileChange):
                self = .fileChange(.init(title: fileChange.title, output: fileChange.output))
            case .message(let message):
                self = .message(.init(text: message.text))
            case .plan(let plan):
                self = .plan(.init(markdown: plan.markdown))
            case .reasoning(let reasoning):
                self = .reasoning(.init(text: reasoning.text, style: reasoning.style))
            case .search(let search):
                self = .search(.init(query: search.query, result: search.result))
            case .toolCall(let toolCall):
                self = .toolCall(.init(
                    namespace: toolCall.namespace,
                    server: toolCall.server,
                    tool: toolCall.tool,
                    arguments: toolCall.arguments,
                    result: toolCall.result,
                    error: toolCall.error
                ))
            case .unknown(let unknown):
                self = .unknown(.init(title: unknown.title, detail: unknown.detail))
            }
        }
    }

    public struct Approval: Sendable, Equatable {
        public var title: String
        public var detail: String?
    }

    public struct Command: Sendable, Equatable {
        public var command: String
        public var cwd: String?
        public var output: String
        public var exitCode: Int?
    }

    public struct ContextCompaction: Sendable, Equatable {
        public var title: String
    }

    public struct Diagnostic: Sendable, Equatable {
        public var message: String
    }

    public struct FileChange: Sendable, Equatable {
        public var title: String
        public var output: String
    }

    public struct Message: Sendable, Equatable {
        public var text: String
    }

    public struct Plan: Sendable, Equatable {
        public var markdown: String
    }

    public struct Reasoning: Sendable, Equatable {
        public var text: String
        public var style: ReviewTimelineItem.Reasoning.Style
    }

    public struct Search: Sendable, Equatable {
        public var query: String
        public var result: String?
    }

    public struct ToolCall: Sendable, Equatable {
        public var namespace: String?
        public var server: String?
        public var tool: String?
        public var arguments: String?
        public var result: String?
        public var error: String?
    }

    public struct Unknown: Sendable, Equatable {
        public var title: String
        public var detail: String?
    }

    public var timelineRevision: ReviewTimeline.Revision
    public var orderedItemIDs: [ReviewTimelineItem.ID]
    public var activeItemIDs: [ReviewTimelineItem.ID]
    public var activeItemCount: Int
    public var latestActivityID: ReviewTimelineItem.ID?
    public var terminalSummary: String?
    public var terminalResult: String?
    public var items: [Item]

    @MainActor
    public init(timeline: ReviewTimeline) {
        let activeItemIDs = timeline.orderedItemIDs.filter { timeline.activeItemIDs.contains($0) }
        self.timelineRevision = timeline.revision
        self.orderedItemIDs = timeline.orderedItemIDs
        self.activeItemIDs = activeItemIDs
        self.activeItemCount = activeItemIDs.count
        self.latestActivityID = timeline.latestActivity
        self.terminalSummary = timeline.terminalSummary
        self.terminalResult = timeline.terminalResult
        self.items = timeline.items.map { item in
            Item(item: item, isActive: timeline.activeItemIDs.contains(item.id))
        }
    }
}
