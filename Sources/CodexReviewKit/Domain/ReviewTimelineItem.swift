import Foundation
import Observation

@MainActor
@Observable
public final class ReviewTimelineItem: Identifiable, Hashable {
    public typealias ID = ReviewTimelineItemID

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

    public nonisolated let id: ID
    public private(set) var kind: ReviewItemKind
    public private(set) var family: ReviewItemFamily
    public private(set) var phase: ReviewItemPhase
    public private(set) var content: Content
    public private(set) var createdAt: Date
    public private(set) var updatedAt: Date
    public private(set) var startedAt: Date?
    public private(set) var completedAt: Date?
    public private(set) var durationMs: Int?

    public init(
        id: ID,
        kind: ReviewItemKind,
        family: ReviewItemFamily,
        phase: ReviewItemPhase,
        content: Content,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        durationMs: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.family = family
        self.phase = phase
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationMs = durationMs
    }

    public nonisolated static func == (lhs: ReviewTimelineItem, rhs: ReviewTimelineItem) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public func update(
        kind: ReviewItemKind? = nil,
        family: ReviewItemFamily? = nil,
        phase: ReviewItemPhase? = nil,
        content: Content? = nil,
        updatedAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        durationMs: Int? = nil
    ) {
        if let kind {
            self.kind = kind
        }
        if let family {
            self.family = family
        }
        if let phase {
            self.phase = phase
        }
        if let content {
            self.content = content
        }
        if let startedAt {
            self.startedAt = startedAt
        }
        if let completedAt {
            self.completedAt = completedAt
        }
        if let durationMs {
            self.durationMs = durationMs
        }
        self.updatedAt = updatedAt
    }

    public func appendText(_ delta: String, updatedAt: Date = Date()) {
        guard delta.isEmpty == false else {
            return
        }
        switch content {
        case .command(var command):
            command.output += delta
            content = .command(command)
        case .fileChange(var fileChange):
            fileChange.output += delta
            content = .fileChange(fileChange)
        case .message(var message):
            message.text += delta
            content = .message(message)
        case .plan(var plan):
            plan.markdown += delta
            content = .plan(plan)
        case .reasoning(var reasoning):
            reasoning.text += delta
            content = .reasoning(reasoning)
        case .diagnostic(var diagnostic):
            diagnostic.message += delta
            content = .diagnostic(diagnostic)
        case .toolCall(var toolCall):
            toolCall.progress = (toolCall.progress ?? "") + delta
            content = .toolCall(toolCall)
        case .approval, .contextCompaction, .search, .unknown:
            break
        }
        self.updatedAt = updatedAt
    }
}

extension ReviewTimelineItem.Content {
    func mergingTimelineUpdate(_ incoming: Self) -> Self {
        switch (self, incoming) {
        case (.approval(let current), .approval(let update)):
            return .approval(current.merging(update))
        case (.command(let current), .command(let update)):
            return .command(current.merging(update))
        case (.contextCompaction(let current), .contextCompaction(let update)):
            return .contextCompaction(current.merging(update))
        case (.diagnostic(let current), .diagnostic(let update)):
            return .diagnostic(current.merging(update))
        case (.fileChange(let current), .fileChange(let update)):
            return .fileChange(current.merging(update))
        case (.message(let current), .message(let update)):
            return .message(current.merging(update))
        case (.plan(let current), .plan(let update)):
            return .plan(current.merging(update))
        case (.reasoning(let current), .reasoning(let update)):
            return .reasoning(current.merging(update))
        case (.search(let current), .search(let update)):
            return .search(current.merging(update))
        case (.toolCall(let current), .toolCall(let update)):
            return .toolCall(current.merging(update))
        case (.unknown(let current), .unknown(let update)):
            return .unknown(current.merging(update))
        default:
            return incoming
        }
    }

    func closingActiveContent(phase: ReviewItemPhase) -> Self {
        switch self {
        case .command(var command):
            command.status = phase.commandStatus
            return .command(command)
        case .fileChange(var fileChange):
            fileChange.status = phase.fileChangeStatus
            return .fileChange(fileChange)
        case .toolCall(var toolCall):
            toolCall.status = phase.toolCallStatus
            return .toolCall(toolCall)
        case .approval(var approval):
            approval.status = phase == .cancelled ? .cancelled : approval.status
            return .approval(approval)
        case .contextCompaction(var contextCompaction):
            contextCompaction.status = phase.contextCompactionStatus
            return .contextCompaction(contextCompaction)
        case .diagnostic,
            .message,
            .plan,
            .reasoning,
            .search,
            .unknown:
            return self
        }
    }
}

private extension ReviewItemPhase {
    var commandStatus: ReviewCommandStatus? {
        switch self {
        case .completed:
            .completed
        case .failed, .incomplete:
            .failed
        case .cancelled, .skipped:
            .cancelled
        case .awaitingApproval, .queued, .running, .waitingForInput:
            nil
        }
    }

    var fileChangeStatus: ReviewFileChangeStatus? {
        switch self {
        case .completed:
            .completed
        case .failed, .incomplete:
            .failed
        case .cancelled, .skipped:
            nil
        case .awaitingApproval, .queued, .running, .waitingForInput:
            nil
        }
    }

    var toolCallStatus: ReviewToolCallStatus? {
        switch self {
        case .completed:
            .completed
        case .failed, .incomplete:
            .failed
        case .cancelled, .skipped:
            .cancelled
        case .awaitingApproval, .queued, .running, .waitingForInput:
            nil
        }
    }

    var contextCompactionStatus: ReviewContextCompactionStatus? {
        switch self {
        case .completed:
            .completed
        case .failed, .incomplete:
            .failed
        case .cancelled, .skipped:
            nil
        case .awaitingApproval, .queued, .running, .waitingForInput:
            nil
        }
    }
}

private extension ReviewTimelineItem.Approval {
    func merging(_ incoming: Self) -> Self {
        .init(
            title: merged(current: title, incoming: incoming.title),
            detail: merged(current: detail, incoming: incoming.detail),
            decision: incoming.decision ?? decision,
            scope: incoming.scope ?? scope,
            risk: incoming.risk ?? risk,
            status: incoming.status ?? status
        )
    }
}

private extension ReviewTimelineItem.Command {
    func merging(_ incoming: Self) -> Self {
        .init(
            command: merged(current: command, incoming: incoming.command),
            cwd: merged(current: cwd, incoming: incoming.cwd),
            output: merged(current: output, incoming: incoming.output),
            exitCode: incoming.exitCode ?? exitCode,
            status: incoming.status ?? status,
            source: incoming.source ?? source,
            processID: merged(current: processID, incoming: incoming.processID),
            actions: incoming.actions.isEmpty ? actions : incoming.actions,
            durationMs: incoming.durationMs ?? durationMs
        )
    }
}

private extension ReviewTimelineItem.ContextCompaction {
    func merging(_ incoming: Self) -> Self {
        .init(
            title: merged(current: title, incoming: incoming.title),
            status: incoming.status ?? status,
            inputTokens: incoming.inputTokens ?? inputTokens,
            outputTokens: incoming.outputTokens ?? outputTokens
        )
    }
}

private extension ReviewTimelineItem.Diagnostic {
    func merging(_ incoming: Self) -> Self {
        .init(
            message: merged(current: message, incoming: incoming.message),
            severity: incoming.severity ?? severity,
            retry: incoming.retry ?? retry
        )
    }
}

private extension ReviewTimelineItem.FileChange {
    func merging(_ incoming: Self) -> Self {
        .init(
            title: merged(current: title, incoming: incoming.title),
            output: merged(current: output, incoming: incoming.output),
            paths: incoming.paths.isEmpty ? paths : incoming.paths,
            patch: merged(current: patch, incoming: incoming.patch),
            status: incoming.status ?? status
        )
    }
}

private extension ReviewTimelineItem.Message {
    func merging(_ incoming: Self) -> Self {
        .init(text: merged(current: text, incoming: incoming.text))
    }
}

private extension ReviewTimelineItem.Plan {
    func merging(_ incoming: Self) -> Self {
        .init(markdown: merged(current: markdown, incoming: incoming.markdown))
    }
}

private extension ReviewTimelineItem.Reasoning {
    func merging(_ incoming: Self) -> Self {
        if incoming.text.isEmpty {
            return self
        }
        return incoming
    }
}

private extension ReviewTimelineItem.Search {
    func merging(_ incoming: Self) -> Self {
        .init(
            query: merged(current: query, incoming: incoming.query),
            result: merged(current: result, incoming: incoming.result),
            status: incoming.status ?? status,
            resultCount: incoming.resultCount ?? resultCount,
            durationMs: incoming.durationMs ?? durationMs
        )
    }
}

private extension ReviewTimelineItem.ToolCall {
    func merging(_ incoming: Self) -> Self {
        .init(
            namespace: merged(current: namespace, incoming: incoming.namespace),
            server: merged(current: server, incoming: incoming.server),
            tool: merged(current: tool, incoming: incoming.tool),
            arguments: merged(current: arguments, incoming: incoming.arguments),
            result: merged(current: result, incoming: incoming.result),
            error: merged(current: error, incoming: incoming.error),
            status: incoming.status ?? status,
            durationMs: incoming.durationMs ?? durationMs,
            appContext: incoming.appContext ?? appContext,
            pluginID: incoming.pluginID ?? pluginID,
            callID: incoming.callID ?? callID,
            progress: merged(current: progress, incoming: incoming.progress)
        )
    }
}

private extension ReviewTimelineItem.Unknown {
    func merging(_ incoming: Self) -> Self {
        .init(
            title: merged(current: title, incoming: incoming.title),
            detail: merged(current: detail, incoming: incoming.detail),
            rawKind: incoming.rawKind ?? rawKind,
            rawStatus: merged(current: rawStatus, incoming: incoming.rawStatus),
            references: incoming.references.isEmpty ? references : incoming.references
        )
    }
}

private func merged(current: String, incoming: String) -> String {
    incoming.isEmpty ? current : incoming
}

private func merged(current: String?, incoming: String?) -> String? {
    guard let incoming, incoming.isEmpty == false else {
        return current
    }
    return incoming
}
