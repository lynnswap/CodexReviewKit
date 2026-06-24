import Foundation
import CodexReviewKit

public struct AppServerWireReviewNotification: Decodable, Equatable, Sendable {
    public var method: AppServerReviewEventKind
    public var payload: Payload
    public var rawPayload: AppServerWireJSONValue?

    public var rawMethod: String {
        method.rawValue
    }

    public init(
        method: AppServerReviewEventKind,
        payload: Payload = Payload(),
        rawPayload: AppServerWireJSONValue? = nil
    ) {
        self.method = method
        self.payload = payload
        self.rawPayload = rawPayload
    }

    public init(method: String, paramsData: Data) throws {
        let paramsObject = try JSONSerialization.jsonObject(
            with: paramsData,
            options: [.fragmentsAllowed]
        )
        let envelope: [String: Any] = [
            "method": method,
            "params": paramsObject,
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    public enum CodingKeys: String, CodingKey {
        case method
        case payload = "params"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawMethod = try container.decode(String.self, forKey: .method)
        self.method = AppServerReviewEventKind(rawValue: rawMethod)
        self.rawPayload = container.contains(.payload)
            ? try container.decode(AppServerWireJSONValue.self, forKey: .payload)
            : nil
        if rawPayload?.objectValue != nil,
           let payload = try? container.decodeIfPresent(Payload.self, forKey: .payload) {
            self.payload = payload
        } else {
            self.payload = Payload(rawValue: rawPayload)
        }
    }

    public func domainEvents(fallbackReviewThreadID: ReviewThread.ID? = nil) -> [ReviewDomainEvent] {
        switch method {
        case .turnStarted:
            return [.runStarted(
                turnID: ReviewTurn.ID(rawValue: payload.resolvedTurnID ?? ""),
                reviewThreadID: (payload.reviewThreadID ?? payload.threadID).map(ReviewThread.ID.init(rawValue:)) ?? fallbackReviewThreadID,
                model: payload.model
            )]
        case .turnCompleted:
            return payload.turnCompletedEvents()
        case .turnFailed:
            return [.reviewFailed(payload.terminalMessage ?? "")]
        case .turnCancelled, .turnAborted:
            return [.reviewCancelled(payload.terminalMessage ?? "")]
        case .itemStarted:
            return payload.itemStartedEvents(method: method)
        case .itemUpdated:
            return payload.itemUpdateEvents(method: method)
        case .itemCompleted:
            return payload.itemCompletionEvents(method: method)
        case .agentMessageDelta:
            return payload.deltaDomainEvent(
                kind: .agentMessage,
                family: .message,
                content: .message(.init(text: ""))
            )
        case .planDelta:
            return payload.deltaDomainEvent(
                kind: .plan,
                family: .plan,
                content: .plan(.init(markdown: ""))
            )
        case .reasoningSummaryTextDelta:
            return payload.deltaDomainEvent(
                kind: .reasoning,
                family: .reasoning,
                content: .reasoning(.init(text: "", style: .summary)),
                itemID: payload.reasoningSummaryItemID
            )
        case .reasoningTextDelta:
            return payload.deltaDomainEvent(
                kind: .reasoning,
                family: .reasoning,
                content: .reasoning(.init(text: "", style: .raw)),
                itemID: payload.rawReasoningItemID
            )
        case .reasoningSummaryPartAdded:
            return []
        case .autoApprovalReviewStarted, .autoApprovalReviewCompleted:
            return []
        case .commandExecutionOutputDelta, .commandExecOutputDelta, .processOutputDelta:
            return payload.deltaDomainEvent(
                kind: .commandExecution,
                family: .command,
                content: .command(.init(command: payload.item?.command ?? "", cwd: payload.item?.cwd)),
                delta: payload.outputDelta,
                itemID: payload.outputItemID
            )
        case .commandExecutionTerminalInteraction:
            return payload.deltaDomainEvent(
                kind: .commandExecution,
                family: .command,
                content: .command(.init(command: payload.item?.command ?? "", cwd: payload.item?.cwd)),
                delta: payload.stdin
            )
        case .fileChangeOutputDelta:
            return payload.deltaDomainEvent(
                kind: .fileChange,
                family: .fileChange,
                content: .fileChange(.init(title: payload.item?.path ?? "")),
                delta: payload.delta
            )
        case .mcpToolCallProgress:
            return payload.toolProgressEvent(method: method)
        case .fileChangePatchUpdated:
            return payload.fileChangeUpdateEvent(method: method)
        case .turnDiffUpdated:
            return payload.diffUpdateEvent(method: method)
        case .turnPlanUpdated:
            return payload.planUpdateEvent(method: method)
        case .threadCompacted:
            return payload.contextCompactionEvent(method: method)
        case .threadClosed:
            return [.reviewFailed(payload.terminalMessage ?? payload.status?.type ?? "")]
        case .threadStatusChanged:
            return payload.threadStatusEvents(method: method)
        case .error:
            return payload.errorEvents(method: method)
        case .warning, .guardianWarning, .deprecationNotice, .configWarning, .diagnostic:
            return payload.diagnosticEvents(method: method)
        case .modelRerouted:
            return payload.modelReroutedEvents(method: method)
        case .modelVerification:
            return payload.modelVerificationEvents(method: method)
        case .agentMessage:
            return payload.messageEvent(method: method)
        case .log:
            return payload.diagnosticEvents(method: method)
        default:
            return payload.unknownEvent(method: method)
        }
    }
}

public extension AppServerReviewEventKind {
    var isReviewNotificationMethod: Bool {
        switch self {
        case .threadClosed,
             .threadStatusChanged,
             .turnStarted,
             .turnCompleted,
             .turnFailed,
             .turnCancelled,
             .turnAborted,
             .turnDiffUpdated,
             .turnPlanUpdated,
             .itemStarted,
             .itemUpdated,
             .itemCompleted,
             .autoApprovalReviewStarted,
             .autoApprovalReviewCompleted,
             .agentMessageDelta,
             .planDelta,
             .reasoningSummaryTextDelta,
             .reasoningSummaryPartAdded,
             .reasoningTextDelta,
             .commandExecutionOutputDelta,
             .commandExecutionTerminalInteraction,
             .commandExecOutputDelta,
             .processOutputDelta,
             .fileChangeOutputDelta,
             .fileChangePatchUpdated,
             .mcpToolCallProgress,
             .agentMessage,
             .log,
             .error,
             .modelRerouted,
             .modelVerification,
             .threadCompacted,
             .warning,
             .guardianWarning,
             .deprecationNotice,
             .configWarning,
             .diagnostic:
            true
        default:
            false
        }
    }

    var isThreadlessReviewBroadcast: Bool {
        switch self {
        case .warning, .deprecationNotice, .configWarning, .error:
            true
        default:
            false
        }
    }
}

public extension AppServerWireReviewNotification {
    var startsReviewMode: Bool {
        method == .itemStarted && payload.item?.type.rawValue == "enteredReviewMode"
    }

    var finishesReviewMode: Bool {
        method == .itemCompleted && payload.item?.type.rawValue == "exitedReviewMode"
    }
}
private extension AppServerReviewEventKind {
    static let turnCompleted: Self = "turn/completed"
    static let turnFailed: Self = "turn/failed"
    static let turnCancelled: Self = "turn/cancelled"
    static let turnAborted: Self = "turn/aborted"
    static let turnDiffUpdated: Self = "turn/diff/updated"
    static let turnPlanUpdated: Self = "turn/plan/updated"
    static let reasoningSummaryPartAdded: Self = "item/reasoning/summaryPartAdded"
    static let autoApprovalReviewStarted: Self = "item/autoApprovalReview/started"
    static let autoApprovalReviewCompleted: Self = "item/autoApprovalReview/completed"
    static let itemUpdated: Self = "item/updated"
    static let commandExecOutputDelta: Self = "command/exec/outputDelta"
    static let processOutputDelta: Self = "process/outputDelta"
    static let commandExecutionTerminalInteraction: Self = "item/commandExecution/terminalInteraction"
    static let fileChangePatchUpdated: Self = "item/fileChange/patchUpdated"
    static let agentMessage: Self = "agent/message"
    static let log: Self = "log"
    static let error: Self = "error"
    static let warning: Self = "warning"
    static let guardianWarning: Self = "guardianWarning"
    static let deprecationNotice: Self = "deprecationNotice"
    static let configWarning: Self = "configWarning"
    static let diagnostic: Self = "diagnostic"
    static let modelRerouted: Self = "model/rerouted"
    static let modelVerification: Self = "model/verification"
    static let threadCompacted: Self = "thread/compacted"
    static let threadClosed: Self = "thread/closed"
    static let threadStatusChanged: Self = "thread/status/changed"
}
