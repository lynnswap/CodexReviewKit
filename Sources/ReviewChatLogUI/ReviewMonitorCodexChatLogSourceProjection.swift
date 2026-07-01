import CodexKit
import Foundation

@MainActor
enum ReviewMonitorLogSourceChange: Equatable {
    case replaceAll(ReviewMonitorLog.Document)
    case update(ReviewMonitorLog.Document)
    case clear

    var sourceDocument: ReviewMonitorLog.Document? {
        switch self {
        case .replaceAll(let document),
            .update(let document):
            return document
        case .clear:
            return nil
        }
    }

    var allowsIncrementalRender: Bool {
        switch self {
        case .update:
            return true
        case .replaceAll,
            .clear:
            return false
        }
    }
}

@MainActor
struct ReviewMonitorCodexChatLogSourceProjection {
    private var logProjection = ReviewMonitorCodexChatLogProjection()
    private var hasLogDocument = false

    mutating func reset() {
        logProjection.reset()
        hasLogDocument = false
    }

    mutating func applyBaseline(
        from chat: CodexChat,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?
    ) -> ReviewMonitorLogSourceChange? {
        renderChat(
            from: chat,
            chatCreatedAt: chatCreatedAt,
            chatUpdatedAt: chatUpdatedAt,
            allowIncrementalUpdate: false
        ) ?? .clear
    }

    mutating func apply(
        _ update: CodexChatUpdate,
        in chat: CodexChat,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?
    ) -> ReviewMonitorLogSourceChange? {
        let allowsIncrementalUpdate: Bool
        switch update {
        case .resynchronized:
            allowsIncrementalUpdate = hasLogDocument
        case .turnInserted,
            .turnUpdated,
            .statusChanged,
            .phaseChanged,
            .itemInserted,
            .itemUpdated,
            .itemRemoved,
            .itemTextAppended:
            allowsIncrementalUpdate = hasLogDocument
        }
        return renderChat(
            from: chat,
            chatCreatedAt: chatCreatedAt,
            chatUpdatedAt: chatUpdatedAt,
            allowIncrementalUpdate: allowsIncrementalUpdate
        )
    }

    private mutating func renderChat(
        from chat: CodexChat,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?,
        allowIncrementalUpdate: Bool
    ) -> ReviewMonitorLogSourceChange? {
        guard
            let document = logProjection.render(
                from: chat,
                chatCreatedAt: chatCreatedAt,
                chatUpdatedAt: chatUpdatedAt
            )
        else {
            return clearIfNeeded()
        }
        defer {
            hasLogDocument = true
        }
        return allowIncrementalUpdate ? .update(document) : .replaceAll(document)
    }

    private mutating func clearIfNeeded() -> ReviewMonitorLogSourceChange? {
        guard hasLogDocument else {
            return nil
        }
        logProjection.reset()
        hasLogDocument = false
        return .clear
    }
}
