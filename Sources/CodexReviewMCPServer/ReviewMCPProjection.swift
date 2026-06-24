import Foundation
import CodexReviewKit

struct ReviewMCPProjection: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        var id: ReviewTimelineItem.ID
        var kind: ReviewItemKind
        var family: ReviewItemFamily
        var phase: ReviewItemPhase
        var isActive: Bool
        var content: Content
        var createdAt: Date
        var updatedAt: Date
        var startedAt: Date?
        var completedAt: Date?
        var durationMs: Int?

        @MainActor
        init(item: ReviewTimelineItem, isActive: Bool) {
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

    enum Content: Sendable, Equatable {
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

        var type: String {
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

        init(_ content: ReviewTimelineItem.Content) {
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
                    progress: toolCall.progress,
                    result: toolCall.result,
                    error: toolCall.error
                ))
            case .unknown(let unknown):
                self = .unknown(.init(title: unknown.title, detail: unknown.detail))
            }
        }
    }

    struct Approval: Sendable, Equatable {
        var title: String
        var detail: String?
    }

    struct Command: Sendable, Equatable {
        var command: String
        var cwd: String?
        var output: String
        var exitCode: Int?
    }

    struct ContextCompaction: Sendable, Equatable {
        var title: String
    }

    struct Diagnostic: Sendable, Equatable {
        var message: String
    }

    struct FileChange: Sendable, Equatable {
        var title: String
        var output: String
    }

    struct Message: Sendable, Equatable {
        var text: String
    }

    struct Plan: Sendable, Equatable {
        var markdown: String
    }

    struct Reasoning: Sendable, Equatable {
        var text: String
        var style: ReviewTimelineItem.Reasoning.Style
    }

    struct Search: Sendable, Equatable {
        var query: String
        var result: String?
    }

    struct ToolCall: Sendable, Equatable {
        var namespace: String?
        var server: String?
        var tool: String?
        var arguments: String?
        var progress: String?
        var result: String?
        var error: String?
    }

    struct Unknown: Sendable, Equatable {
        var title: String
        var detail: String?
    }

    var timelineRevision: ReviewTimeline.Revision
    var orderedItemIDs: [ReviewTimelineItem.ID]
    var activeItemIDs: [ReviewTimelineItem.ID]
    var activeItemCount: Int
    var latestActivityID: ReviewTimelineItem.ID?
    var terminalSummary: String?
    var terminalResult: String?
    var items: [Item]

    @MainActor
    init(timeline: ReviewTimeline) {
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
