import Foundation

package enum ReviewEventItem {
    public typealias ID = ReviewEventItemID

    public enum Content: Equatable, Codable, Sendable {
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
    }

    public struct RawReference: Equatable, Codable, Sendable {
        public var kind: ReviewRawReferenceKind
        public var value: String
        public var label: String?

        public init(kind: ReviewRawReferenceKind, value: String, label: String? = nil) {
            self.kind = kind
            self.value = value
            self.label = label
        }
    }

    public struct Approval: Equatable, Codable, Sendable {
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

    public struct CommandAction: Equatable, Codable, Sendable {
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

    public struct Command: Equatable, Codable, Sendable {
        public var command: String
        public var cwd: String?
        public var output: String
        public var exitCode: Int?
        public var status: ReviewCommandStatus?
        public var source: ReviewCommandSource?
        public var processID: String?
        public var actions: [CommandAction]
        public var durationMs: Int?

        public init(
            command: String,
            cwd: String? = nil,
            output: String = "",
            exitCode: Int? = nil,
            status: ReviewCommandStatus? = nil,
            source: ReviewCommandSource? = nil,
            processID: String? = nil,
            actions: [CommandAction] = [],
            durationMs: Int? = nil
        ) {
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

    public struct ContextCompaction: Equatable, Codable, Sendable {
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

    public struct Retry: Equatable, Codable, Sendable {
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

    public struct Diagnostic: Equatable, Codable, Sendable {
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

    public struct FileChange: Equatable, Codable, Sendable {
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

    public struct Message: Equatable, Codable, Sendable {
        public var text: String

        public init(text: String) {
            self.text = text
        }
    }

    public struct Plan: Equatable, Codable, Sendable {
        public var markdown: String

        public init(markdown: String) {
            self.markdown = markdown
        }
    }

    public struct Reasoning: Equatable, Codable, Sendable {
        public enum Style: String, Codable, Hashable, Sendable {
            case raw
            case summary
        }

        public var text: String
        public var style: Style

        public init(text: String, style: Style) {
            self.text = text
            self.style = style
        }
    }

    public struct Search: Equatable, Codable, Sendable {
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

    public struct ToolCall: Equatable, Codable, Sendable {
        public var namespace: String?
        public var server: String?
        public var tool: String?
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
            tool: String? = nil,
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
            self.tool = tool
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

    public struct Unknown: Equatable, Codable, Sendable {
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
}
