import Foundation
import CodexReviewDomain

public struct AppServerReviewEventKind: ReviewStringIdentifier, CustomStringConvertible {
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
