import Foundation
import CodexReviewKit

// Test-only bridge for legacy ReviewTimeline fixtures. Production detail rendering
// uses CodexChatChange streams through ReviewMonitorSelectedCodexChat.
struct ReviewTimelineDocument: Codable, Equatable, Sendable {
    struct Block: Identifiable, Codable, Equatable, Sendable {
        struct ID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
            var rawValue: String

            init(rawValue: String) {
                self.rawValue = rawValue
            }

            init(stringLiteral value: String) {
                self.init(rawValue: value)
            }

            init(itemID: ReviewTimelineItem.ID) {
                self.init(rawValue: itemID.rawValue)
            }

            var description: String {
                rawValue
            }
        }

        var id: ID
        var sourceItemID: ReviewTimelineItem.ID
        var kind: ReviewItemKind
        var family: ReviewItemFamily
        var phase: ReviewItemPhase
        var isActive: Bool
        var primaryText: String
        var rawTranscriptText: String
        var content: Content
        var createdAt: Date
        var updatedAt: Date
        var startedAt: Date?
        var completedAt: Date?
        var durationMs: Int?

        init(
            id: ID,
            sourceItemID: ReviewTimelineItem.ID,
            kind: ReviewItemKind,
            family: ReviewItemFamily,
            phase: ReviewItemPhase,
            isActive: Bool,
            primaryText: String,
            rawTranscriptText: String,
            content: Content,
            createdAt: Date,
            updatedAt: Date,
            startedAt: Date? = nil,
            completedAt: Date? = nil,
            durationMs: Int? = nil
        ) {
            self.id = id
            self.sourceItemID = sourceItemID
            self.kind = kind
            self.family = family
            self.phase = phase
            self.isActive = isActive
            self.primaryText = primaryText
            self.rawTranscriptText = rawTranscriptText
            self.content = content
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.durationMs = durationMs
        }
    }

    enum Content: Codable, Equatable, Sendable {
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
    }

    struct Approval: Codable, Equatable, Sendable {
        var title: String
        var detail: String?
        var decision: ReviewApprovalDecision?
        var scope: ReviewApprovalScope?
        var risk: ReviewApprovalRisk?
        var status: ReviewApprovalStatus?

        init(
            title: String,
            detail: String? = nil,
            decision: ReviewApprovalDecision? = nil,
            scope: ReviewApprovalScope? = nil,
            risk: ReviewApprovalRisk? = nil,
            status: ReviewApprovalStatus? = nil
        ) {
            self.title = title
            self.detail = detail
            self.decision = decision
            self.scope = scope
            self.risk = risk
            self.status = status
        }
    }

    struct Command: Codable, Equatable, Sendable {
        struct Action: Codable, Equatable, Sendable {
            var kind: ReviewCommandActionKind
            var command: String?
            var name: String?
            var path: String?
            var query: String?

            init(
                kind: ReviewCommandActionKind,
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
        }

        var title: String
        var command: String
        var cwd: String?
        var output: String
        var exitCode: Int?
        var status: ReviewCommandStatus?
        var source: ReviewCommandSource?
        var processID: String?
        var actions: [Action]
        var durationMs: Int?

        init(
            title: String,
            command: String,
            cwd: String? = nil,
            output: String = "",
            exitCode: Int? = nil,
            status: ReviewCommandStatus? = nil,
            source: ReviewCommandSource? = nil,
            processID: String? = nil,
            actions: [Action] = [],
            durationMs: Int? = nil
        ) {
            self.title = title
            self.command = command
            self.cwd = cwd
            self.output = output
            self.exitCode = exitCode
            self.status = status
            self.source = source
            self.processID = processID
            self.actions = actions
            self.durationMs = durationMs
        }
    }

    struct ContextCompaction: Codable, Equatable, Sendable {
        var title: String
        var status: ReviewContextCompactionStatus?
        var inputTokens: Int?
        var outputTokens: Int?

        init(
            title: String,
            status: ReviewContextCompactionStatus? = nil,
            inputTokens: Int? = nil,
            outputTokens: Int? = nil
        ) {
            self.title = title
            self.status = status
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
        }
    }

    struct Diagnostic: Codable, Equatable, Sendable {
        struct Retry: Codable, Equatable, Sendable {
            var state: ReviewDiagnosticRetryState
            var attempt: Int?
            var maxAttempts: Int?
            var delayMs: Int?

            init(
                state: ReviewDiagnosticRetryState,
                attempt: Int? = nil,
                maxAttempts: Int? = nil,
                delayMs: Int? = nil
            ) {
                self.state = state
                self.attempt = attempt
                self.maxAttempts = maxAttempts
                self.delayMs = delayMs
            }
        }

        var message: String
        var severity: ReviewDiagnosticSeverity?
        var retry: Retry?

        init(
            message: String,
            severity: ReviewDiagnosticSeverity? = nil,
            retry: Retry? = nil
        ) {
            self.message = message
            self.severity = severity
            self.retry = retry
        }
    }

    struct FileChange: Codable, Equatable, Sendable {
        var title: String
        var output: String
        var paths: [String]
        var patch: String?
        var status: ReviewFileChangeStatus?

        init(
            title: String,
            output: String = "",
            paths: [String] = [],
            patch: String? = nil,
            status: ReviewFileChangeStatus? = nil
        ) {
            self.title = title
            self.output = output
            self.paths = paths
            self.patch = patch
            self.status = status
        }
    }

    struct Message: Codable, Equatable, Sendable {
        var text: String

        init(text: String) {
            self.text = text
        }
    }

    struct Plan: Codable, Equatable, Sendable {
        var markdown: String

        init(markdown: String) {
            self.markdown = markdown
        }
    }

    struct Reasoning: Codable, Equatable, Sendable {
        var text: String
        var style: ReviewTimelineItem.Reasoning.Style

        init(text: String, style: ReviewTimelineItem.Reasoning.Style) {
            self.text = text
            self.style = style
        }
    }

    struct Search: Codable, Equatable, Sendable {
        var query: String
        var result: String?
        var status: ReviewSearchStatus?
        var resultCount: Int?
        var durationMs: Int?

        init(
            query: String,
            result: String? = nil,
            status: ReviewSearchStatus? = nil,
            resultCount: Int? = nil,
            durationMs: Int? = nil
        ) {
            self.query = query
            self.result = result
            self.status = status
            self.resultCount = resultCount
            self.durationMs = durationMs
        }
    }

    struct ToolCall: Codable, Equatable, Sendable {
        var namespace: String?
        var server: String?
        var name: String?
        var arguments: String?
        var result: String?
        var error: String?
        var status: ReviewToolCallStatus?
        var durationMs: Int?
        var appContext: ReviewAppContext?
        var pluginID: ReviewPluginID?
        var callID: ReviewToolCall.ID?
        var progress: String?

        init(
            namespace: String? = nil,
            server: String? = nil,
            name: String? = nil,
            arguments: String? = nil,
            result: String? = nil,
            error: String? = nil,
            status: ReviewToolCallStatus? = nil,
            durationMs: Int? = nil,
            appContext: ReviewAppContext? = nil,
            pluginID: ReviewPluginID? = nil,
            callID: ReviewToolCall.ID? = nil,
            progress: String? = nil
        ) {
            self.namespace = namespace
            self.server = server
            self.name = name
            self.arguments = arguments
            self.result = result
            self.error = error
            self.status = status
            self.durationMs = durationMs
            self.appContext = appContext
            self.pluginID = pluginID
            self.callID = callID
            self.progress = progress
        }
    }

    struct Unknown: Codable, Equatable, Sendable {
        struct RawReference: Codable, Equatable, Sendable {
            var kind: ReviewRawReferenceKind
            var value: String
            var label: String?

            init(kind: ReviewRawReferenceKind, value: String, label: String? = nil) {
                self.kind = kind
                self.value = value
                self.label = label
            }
        }

        var title: String
        var detail: String?
        var rawKind: ReviewItemKind?
        var rawStatus: String?
        var references: [RawReference]

        init(
            title: String,
            detail: String? = nil,
            rawKind: ReviewItemKind? = nil,
            rawStatus: String? = nil,
            references: [RawReference] = []
        ) {
            self.title = title
            self.detail = detail
            self.rawKind = rawKind
            self.rawStatus = rawStatus
            self.references = references
        }
    }

    var timelineRevision: ReviewTimeline.Revision
    var orderedBlockIDs: [Block.ID]
    var activeBlockIDs: [Block.ID]
    var activeBlockCount: Int
    var latestActivityBlockID: Block.ID?
    var terminalStatus: ReviewLifecycleStatus?
    var terminalSummary: String?
    var terminalResult: String?
    var blocks: [Block]

    init(
        timelineRevision: ReviewTimeline.Revision,
        orderedBlockIDs: [Block.ID],
        activeBlockIDs: [Block.ID],
        activeBlockCount: Int,
        latestActivityBlockID: Block.ID?,
        terminalStatus: ReviewLifecycleStatus?,
        terminalSummary: String?,
        terminalResult: String?,
        blocks: [Block]
    ) {
        self.timelineRevision = timelineRevision
        self.orderedBlockIDs = orderedBlockIDs
        self.activeBlockIDs = activeBlockIDs
        self.activeBlockCount = activeBlockCount
        self.latestActivityBlockID = latestActivityBlockID
        self.terminalStatus = terminalStatus
        self.terminalSummary = terminalSummary
        self.terminalResult = terminalResult
        self.blocks = blocks
    }

    var plainText: String {
        blocks.map(\.rawTranscriptText).filter { $0.isEmpty == false }.joined(separator: "\n\n")
    }
}
