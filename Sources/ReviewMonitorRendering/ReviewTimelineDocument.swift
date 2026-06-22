import Foundation
import CodexReviewDomain

public struct ReviewTimelineDocument: Codable, Equatable, Sendable {
    public struct Block: Identifiable, Codable, Equatable, Sendable {
        public struct ID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
            public var rawValue: String

            public init(rawValue: String) {
                self.rawValue = rawValue
            }

            public init(stringLiteral value: String) {
                self.init(rawValue: value)
            }

            public init(itemID: ReviewTimelineItem.ID) {
                self.init(rawValue: itemID.rawValue)
            }

            public var description: String {
                rawValue
            }
        }

        public var id: ID
        public var sourceItemID: ReviewTimelineItem.ID
        public var kind: ReviewItemKind
        public var family: ReviewItemFamily
        public var phase: ReviewItemPhase
        public var isActive: Bool
        public var primaryText: String
        public var rawTranscriptText: String
        public var content: Content
        public var createdAt: Date
        public var updatedAt: Date
        public var startedAt: Date?
        public var completedAt: Date?
        public var durationMs: Int?

        public init(
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

    public enum Content: Codable, Equatable, Sendable {
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
    }

    public struct Approval: Codable, Equatable, Sendable {
        public var title: String
        public var detail: String?
        public var decision: ReviewApprovalDecision?
        public var scope: ReviewApprovalScope?
        public var risk: ReviewApprovalRisk?
        public var status: ReviewApprovalStatus?

        public init(
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

    public struct Command: Codable, Equatable, Sendable {
        public struct Action: Codable, Equatable, Sendable {
            public var kind: ReviewCommandActionKind
            public var command: String?
            public var name: String?
            public var path: String?
            public var query: String?

            public init(
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

        public var title: String
        public var command: String
        public var cwd: String?
        public var output: String
        public var exitCode: Int?
        public var status: ReviewCommandStatus?
        public var source: ReviewCommandSource?
        public var processID: String?
        public var actions: [Action]
        public var durationMs: Int?

        public init(
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

    public struct ContextCompaction: Codable, Equatable, Sendable {
        public var title: String
        public var status: ReviewContextCompactionStatus?
        public var inputTokens: Int?
        public var outputTokens: Int?

        public init(
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

    public struct Diagnostic: Codable, Equatable, Sendable {
        public struct Retry: Codable, Equatable, Sendable {
            public var state: ReviewDiagnosticRetryState
            public var attempt: Int?
            public var maxAttempts: Int?
            public var delayMs: Int?

            public init(
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

        public var message: String
        public var severity: ReviewDiagnosticSeverity?
        public var retry: Retry?

        public init(
            message: String,
            severity: ReviewDiagnosticSeverity? = nil,
            retry: Retry? = nil
        ) {
            self.message = message
            self.severity = severity
            self.retry = retry
        }
    }

    public struct FileChange: Codable, Equatable, Sendable {
        public var title: String
        public var output: String
        public var paths: [String]
        public var patch: String?
        public var status: ReviewFileChangeStatus?

        public init(
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

    public struct Message: Codable, Equatable, Sendable {
        public var text: String

        public init(text: String) {
            self.text = text
        }
    }

    public struct Plan: Codable, Equatable, Sendable {
        public var markdown: String

        public init(markdown: String) {
            self.markdown = markdown
        }
    }

    public struct Reasoning: Codable, Equatable, Sendable {
        public var text: String
        public var style: ReviewTimelineItem.Reasoning.Style

        public init(text: String, style: ReviewTimelineItem.Reasoning.Style) {
            self.text = text
            self.style = style
        }
    }

    public struct Search: Codable, Equatable, Sendable {
        public var query: String
        public var result: String?
        public var status: ReviewSearchStatus?
        public var resultCount: Int?
        public var durationMs: Int?

        public init(
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

    public struct ToolCall: Codable, Equatable, Sendable {
        public var namespace: String?
        public var server: String?
        public var name: String?
        public var arguments: String?
        public var result: String?
        public var error: String?
        public var status: ReviewToolCallStatus?
        public var durationMs: Int?
        public var appContext: ReviewAppContext?
        public var pluginID: ReviewPluginID?
        public var callID: ReviewToolCall.ID?
        public var progress: String?

        public init(
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

    public struct Unknown: Codable, Equatable, Sendable {
        public struct RawReference: Codable, Equatable, Sendable {
            public var kind: ReviewRawReferenceKind
            public var value: String
            public var label: String?

            public init(kind: ReviewRawReferenceKind, value: String, label: String? = nil) {
                self.kind = kind
                self.value = value
                self.label = label
            }
        }

        public var title: String
        public var detail: String?
        public var rawKind: ReviewItemKind?
        public var rawStatus: String?
        public var references: [RawReference]

        public init(
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

    public var timelineRevision: ReviewTimeline.Revision
    public var orderedBlockIDs: [Block.ID]
    public var activeBlockIDs: [Block.ID]
    public var activeBlockCount: Int
    public var latestActivityBlockID: Block.ID?
    public var terminalStatus: ReviewLifecycleStatus?
    public var terminalSummary: String?
    public var terminalResult: String?
    public var blocks: [Block]

    public init(
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

    public var plainText: String {
        blocks.map(\.rawTranscriptText).filter { $0.isEmpty == false }.joined(separator: "\n\n")
    }
}
