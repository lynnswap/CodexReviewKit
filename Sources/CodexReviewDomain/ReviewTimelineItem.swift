import Foundation
import Observation

@MainActor
@Observable
public final class ReviewTimelineItem: Identifiable, Hashable {
    public typealias ID = ReviewTimelineItemID

    public enum Content: Equatable, Sendable {
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

    public struct Approval: Equatable, Sendable {
        public var title: String
        public var detail: String?

        public init(title: String, detail: String? = nil) {
            self.title = title
            self.detail = detail
        }
    }

    public struct Command: Equatable, Sendable {
        public var command: String
        public var cwd: String?
        public var output: String
        public var exitCode: Int?

        public init(command: String, cwd: String? = nil, output: String = "", exitCode: Int? = nil) {
            self.command = command
            self.cwd = cwd
            self.output = output
            self.exitCode = exitCode
        }
    }

    public struct ContextCompaction: Equatable, Sendable {
        public var title: String

        public init(title: String) {
            self.title = title
        }
    }

    public struct Diagnostic: Equatable, Sendable {
        public var message: String

        public init(message: String) {
            self.message = message
        }
    }

    public struct FileChange: Equatable, Sendable {
        public var title: String
        public var output: String

        public init(title: String, output: String = "") {
            self.title = title
            self.output = output
        }
    }

    public struct Message: Equatable, Sendable {
        public var text: String

        public init(text: String) {
            self.text = text
        }
    }

    public struct Plan: Equatable, Sendable {
        public var markdown: String

        public init(markdown: String) {
            self.markdown = markdown
        }
    }

    public struct Reasoning: Equatable, Sendable {
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

    public struct Search: Equatable, Sendable {
        public var query: String
        public var result: String?

        public init(query: String, result: String? = nil) {
            self.query = query
            self.result = result
        }
    }

    public struct ToolCall: Equatable, Sendable {
        public var namespace: String?
        public var server: String?
        public var tool: String?
        public var arguments: String?
        public var result: String?
        public var error: String?

        public init(
            namespace: String? = nil,
            server: String? = nil,
            tool: String? = nil,
            arguments: String? = nil,
            result: String? = nil,
            error: String? = nil
        ) {
            self.namespace = namespace
            self.server = server
            self.tool = tool
            self.arguments = arguments
            self.result = result
            self.error = error
        }
    }

    public struct Unknown: Equatable, Sendable {
        public var title: String
        public var detail: String?

        public init(title: String, detail: String? = nil) {
            self.title = title
            self.detail = detail
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
        case .approval, .contextCompaction, .search, .toolCall, .unknown:
            break
        }
        self.updatedAt = updatedAt
    }
}
