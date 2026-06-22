import Foundation

public struct ReviewItemKind: ReviewStringIdentifier, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }

    public static let agentMessage: Self = "agentMessage"
    public static let commandExecution: Self = "commandExecution"
    public static let contextCompaction: Self = "contextCompaction"
    public static let dynamicToolCall: Self = "dynamicToolCall"
    public static let fileChange: Self = "fileChange"
    public static let imageGeneration: Self = "imageGeneration"
    public static let imageView: Self = "imageView"
    public static let mcpToolCall: Self = "mcpToolCall"
    public static let plan: Self = "plan"
    public static let reasoning: Self = "reasoning"
    public static let webSearch: Self = "webSearch"
}

public struct ReviewWireEventKind: ReviewStringIdentifier, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }

    public static let turnStarted: Self = "turn/started"
    public static let itemStarted: Self = "item/started"
    public static let itemCompleted: Self = "item/completed"
    public static let agentMessageDelta: Self = "item/agentMessage/delta"
    public static let planDelta: Self = "item/plan/delta"
    public static let reasoningSummaryTextDelta: Self = "item/reasoning/summaryTextDelta"
    public static let reasoningTextDelta: Self = "item/reasoning/textDelta"
    public static let commandExecutionOutputDelta: Self = "item/commandExecution/outputDelta"
    public static let fileChangeOutputDelta: Self = "item/fileChange/outputDelta"
    public static let mcpToolCallProgress: Self = "item/mcpToolCall/progress"
}

public enum ReviewItemFamily: String, Codable, Hashable, Sendable {
    case approval
    case command
    case contextCompaction
    case diagnostic
    case fileChange
    case lifecycle
    case message
    case plan
    case reasoning
    case search
    case tool
    case unknown
}

public enum ReviewItemPhase: String, Codable, Hashable, Sendable {
    case awaitingApproval
    case cancelled
    case completed
    case failed
    case incomplete
    case queued
    case running
    case skipped
    case waitingForInput

    public var isTerminal: Bool {
        switch self {
        case .cancelled, .completed, .failed, .incomplete, .skipped:
            return true
        case .awaitingApproval, .queued, .running, .waitingForInput:
            return false
        }
    }

    public static func normalized(_ rawValue: String?) -> Self {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "approved", "completed", "succeeded", "success":
            return .completed
        case "cancelled", "canceled":
            return .cancelled
        case "failed", "failure", "error":
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
            return .running
        }
    }
}
