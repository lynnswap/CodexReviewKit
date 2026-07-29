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

    var turnID: CodexTurnID?
    var finalResult: String?
    var items: [Item]

    static func unavailable(result _: CodexReviewAPI.Read.Result) -> Self {
        Self()
    }

    private init() {
        self.items = []
        self.turnID = nil
        self.finalResult = nil
    }

    init(
        result: CodexReviewAPI.Read.Result,
        turnID: CodexTurnID,
        threadItems: [CodexThreadItem],
        reviewOutputText: String?
    ) {
        let status = result.presentation.status
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
        self.items = projectedItems
        self.turnID = turnID
        self.finalResult =
            status == .succeeded
            ? reviewOutputText.flatMap(Self.nonEmptyReviewOutput)
            : nil
    }

    private static func nonEmptyReviewOutput(_ value: String) -> String? {
        guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return value
    }
}

private extension ReviewMCPLogProjection.Content {
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
