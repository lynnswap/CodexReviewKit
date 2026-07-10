import Foundation
import CodexAppServerKit
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
    var finalLifecycleMessage: String?
    var finalResult: String?
    var items: [Item]

    static func unavailable(result: CodexReviewAPI.Read.Result) -> Self {
        Self(result: result)
    }

    private init(result: CodexReviewAPI.Read.Result) {
        self.revision = "\(result.runID):unavailable"
        self.items = []
        self.orderedEntryIDs = []
        self.activeEntryIDs = []
        self.activeEntryCount = activeEntryIDs.count
        self.latestEntryID = orderedEntryIDs.last
        self.finalLifecycleMessage = nil
        self.finalResult = nil
    }

    init(
        result: CodexReviewAPI.Read.Result,
        turnID: CodexTurnID,
        threadItems: [CodexThreadItem]
    ) {
        let lifecycle = result.core.lifecycle
        let lifecycleMessage = result.core.lifecycleMessage
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
                // Digest the content, not just its length, so same-length
                // edits still advance the revision clients compare.
                "\(item.id):\(item.kind.rawValue):\(item.text?.stableLogDigest ?? "0")"
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
        self.finalLifecycleMessage = status.isTerminal ? lifecycleMessage : nil
        self.finalResult =
            status == .succeeded
            ? result.core.finalReview ?? projectedItems.lastAssistantMessageText
            : nil
    }
}

private extension [ReviewMCPLogProjection.Item] {
    // Only agent messages qualify as the final result; a trailing user
    // prompt in the transcript must never replace the review findings.
    var lastAssistantMessageText: String? {
        reversed()
            .filter { $0.kind == CodexThreadItem.Kind.agentMessage.rawValue }
            .compactMap { $0.content.messageText }
            .first
    }
}

private extension String {
    // Process-stable FNV-1a digest; revisions are only compared against
    // other revisions produced by the same server instance.
    var stableLogDigest: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
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
