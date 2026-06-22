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

public protocol ReviewOpenStringValue: ReviewStringIdentifier, CustomStringConvertible {}

public extension ReviewOpenStringValue {
    var description: String {
        rawValue
    }
}

public struct ReviewCommandStatus: ReviewOpenStringValue {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let inProgress: Self = "inProgress"
    public static let completed: Self = "completed"
    public static let failed: Self = "failed"
    public static let cancelled: Self = "cancelled"
}

public struct ReviewCommandSource: ReviewOpenStringValue {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ReviewCommandActionKind: ReviewOpenStringValue {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let read: Self = "read"
    public static let listFiles: Self = "listFiles"
    public static let search: Self = "search"
    public static let unknown: Self = "unknown"
}

public struct ReviewToolCallStatus: ReviewOpenStringValue {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let started: Self = "started"
    public static let inProgress: Self = "inProgress"
    public static let completed: Self = "completed"
    public static let failed: Self = "failed"
    public static let cancelled: Self = "cancelled"
}

public struct ReviewAppContext: ReviewOpenStringValue {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ReviewPluginID: ReviewOpenStringValue {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ReviewFileChangeStatus: ReviewOpenStringValue {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let started: Self = "started"
    public static let updated: Self = "updated"
    public static let completed: Self = "completed"
    public static let failed: Self = "failed"
}

public struct ReviewApprovalDecision: ReviewOpenStringValue {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let approved: Self = "approved"
    public static let denied: Self = "denied"
    public static let cancelled: Self = "cancelled"
}

public struct ReviewApprovalScope: ReviewOpenStringValue {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ReviewApprovalRisk: ReviewOpenStringValue {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let low: Self = "low"
    public static let medium: Self = "medium"
    public static let high: Self = "high"
}

public struct ReviewApprovalStatus: ReviewOpenStringValue {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let pending: Self = "pending"
    public static let decided: Self = "decided"
    public static let cancelled: Self = "cancelled"
}

public struct ReviewDiagnosticSeverity: ReviewOpenStringValue {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let info: Self = "info"
    public static let warning: Self = "warning"
    public static let error: Self = "error"
}

public struct ReviewDiagnosticRetryState: ReviewOpenStringValue {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let scheduled: Self = "scheduled"
    public static let retrying: Self = "retrying"
    public static let exhausted: Self = "exhausted"
}

public struct ReviewSearchStatus: ReviewOpenStringValue {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let started: Self = "started"
    public static let completed: Self = "completed"
    public static let failed: Self = "failed"
}

public struct ReviewContextCompactionStatus: ReviewOpenStringValue {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let inProgress: Self = "inProgress"
    public static let completed: Self = "completed"
    public static let failed: Self = "failed"
}

public struct ReviewRawReferenceKind: ReviewOpenStringValue {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
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
