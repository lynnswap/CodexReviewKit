import Foundation
import CodexKit
import CodexReviewKit

package struct ReviewMCPLogProjection: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        var id: String
        var kind: String
        var content: Content
    }

    enum Content: Sendable, Equatable {
        case message(String)
        case diagnostic(String)
        case entry(type: String, text: String)

        var type: String {
            switch self {
            case .message:
                "message"
            case .diagnostic:
                "diagnostic"
            case .entry(let type, _):
                type
            }
        }
    }

    var revision: String
    var orderedEntryIDs: [String]
    var activeEntryIDs: [String]
    var activeEntryCount: Int
    var latestEntryID: String?
    var finalSummary: String?
    var finalResult: String?
    var items: [Item]

    static func unavailable(result: CodexReviewAPI.Read.Result) -> Self {
        Self(result: result)
    }

    private init(result: CodexReviewAPI.Read.Result) {
        let lifecycle = result.core.lifecycle
        let summary = result.core.summary
        let status = lifecycle.status
        self.revision = [
            result.runID,
            status.rawValue,
            lifecycle.endedAt?.timeIntervalSince1970.description ?? "running",
            summary,
        ].joined(separator: ":")

        self.items = []
        self.orderedEntryIDs = []
        self.activeEntryIDs = []
        self.activeEntryCount = activeEntryIDs.count
        self.latestEntryID = orderedEntryIDs.last
        self.finalSummary = status.isTerminal ? summary : nil
        self.finalResult = nil
    }

    @MainActor
    init(result: CodexReviewAPI.Read.Result, turnSnapshot: CodexChatTurnSnapshot) {
        self.init(
            result: result,
            turnID: turnSnapshot.turnID,
            threadItems: turnSnapshot.threadItems
        )
    }

    init(
        result: CodexReviewAPI.Read.Result,
        turnID: CodexTurnID,
        threadItems: [CodexThreadItem]
    ) {
        let lifecycle = result.core.lifecycle
        let summary = result.core.summary
        let status = lifecycle.status
        let projectedItems = threadItems.compactMap { item -> Item? in
            guard let content = Content(threadItem: item) else {
                return nil
            }
            return .init(
                id: "\(turnID.rawValue):\(item.id)",
                kind: item.kind.rawValue,
                content: content
            )
        }
        let itemRevision = threadItems
            .map { item in
                "\(item.id):\(item.kind.rawValue):\(item.text?.count ?? 0)"
            }
            .joined(separator: "|")
        self.revision = [
            result.runID,
            status.rawValue,
            lifecycle.endedAt?.timeIntervalSince1970.description ?? "running",
            turnID.rawValue,
            itemRevision,
        ].joined(separator: ":")
        self.items = projectedItems
        self.orderedEntryIDs = projectedItems.map(\.id)
        self.activeEntryIDs = status.isTerminal ? [] : projectedItems.map(\.id)
        self.activeEntryCount = activeEntryIDs.count
        self.latestEntryID = orderedEntryIDs.last
        self.finalSummary = status.isTerminal ? summary : nil
        self.finalResult =
            status == .succeeded
            ? projectedItems.lastAssistantMessageText
            : nil
    }
}

private extension [ReviewMCPLogProjection.Item] {
    var lastAssistantMessageText: String? {
        reversed().compactMap { $0.content.messageText }.first
    }
}

private extension ReviewMCPLogProjection.Content {
    var messageText: String? {
        guard case .message(let text) = self else {
            return nil
        }
        return text.nilIfEmpty
    }

    init?(threadItem item: CodexThreadItem) {
        switch item.content {
        case .message(let message):
            guard let text = message.text.nilIfEmpty else {
                return nil
            }
            self = .message(text)
        case .diagnostic(let message), .log(let message):
            guard let message = message.nilIfEmpty else {
                return nil
            }
            self = .diagnostic(message)
        case .reasoning(let reasoning):
            guard let text = reasoning.text.nilIfEmpty else {
                return nil
            }
            self = .entry(type: "reasoning", text: text)
        case .command(let command):
            guard let text = command.output?.nilIfEmpty ?? command.command.nilIfEmpty else {
                return nil
            }
            self = .entry(type: "command", text: text)
        case .fileChange(let fileChange):
            guard let text = fileChange.output?.nilIfEmpty ?? fileChange.path?.nilIfEmpty else {
                return nil
            }
            self = .entry(type: "fileChange", text: text)
        case .toolCall(let toolCall):
            guard let text = toolCall.result?.nilIfEmpty
                ?? toolCall.error?.nilIfEmpty
                ?? toolCall.name?.nilIfEmpty
            else {
                return nil
            }
            self = .entry(type: "toolCall", text: text)
        case .plan(let text):
            guard let text = text.nilIfEmpty else {
                return nil
            }
            self = .entry(type: "plan", text: text)
        case .contextCompaction(let message):
            self = .diagnostic(message?.nilIfEmpty ?? "Context automatically compacted.")
        case .unknown:
            guard let text = item.text?.nilIfEmpty else {
                return nil
            }
            self = .entry(type: item.kind.rawValue, text: text)
        }
    }
}
