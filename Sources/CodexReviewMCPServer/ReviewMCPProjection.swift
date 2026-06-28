import Foundation
import CodexReviewKit

struct ReviewMCPProjection: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        var id: String
        var kind: String
        var content: Content
    }

    enum Content: Sendable, Equatable {
        case message(String)
        case diagnostic(String)

        var type: String {
            switch self {
            case .message:
                "message"
            case .diagnostic:
                "diagnostic"
            }
        }
    }

    var revision: String
    var orderedItemIDs: [String]
    var activeItemIDs: [String]
    var activeItemCount: Int
    var latestActivityID: String?
    var terminalSummary: String?
    var terminalResult: String?
    var items: [Item]

    init(result: CodexReviewAPI.Read.Result) {
        let lifecycle = result.core.lifecycle
        let output = result.core.output
        let status = lifecycle.status
        self.revision = [
            result.runID,
            status.rawValue,
            lifecycle.endedAt?.timeIntervalSince1970.description ?? "running",
            output.summary,
            output.lastAgentMessage ?? "",
        ].joined(separator: ":")

        var items: [Item] = []
        if let text = output.lastAgentMessage?.nilIfEmpty {
            items.append(.init(id: "\(result.runID):message", kind: "agentMessage", content: .message(text)))
        } else if let summary = output.summary.nilIfEmpty {
            items.append(.init(id: "\(result.runID):summary", kind: "diagnostic", content: .diagnostic(summary)))
        }

        self.items = items
        self.orderedItemIDs = items.map(\.id)
        self.activeItemIDs = status.isTerminal ? [] : items.map(\.id)
        self.activeItemCount = activeItemIDs.count
        self.latestActivityID = orderedItemIDs.last
        self.terminalSummary = status.isTerminal ? output.summary : nil
        self.terminalResult = status == .succeeded ? result.core.reviewText.nilIfEmpty : nil
    }
}
