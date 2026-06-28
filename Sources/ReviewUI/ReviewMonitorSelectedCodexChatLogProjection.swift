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
struct ReviewMonitorSelectedCodexChatLogProjection {
    private var turnProjection = CodexChatTurnProjection()
    private var logProjection = ReviewMonitorCodexChatLogProjection()
    private var hasLogDocument = false

    mutating func reset() {
        turnProjection = CodexChatTurnProjection()
        logProjection.reset()
        hasLogDocument = false
    }

    mutating func apply(
        _ change: CodexChatChange,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?
    ) -> ReviewMonitorLogSourceChange? {
        let update = turnProjection.apply(change)
        guard update.affectsSelectedTurn else {
            return nil
        }
        guard let snapshot = update.snapshot else {
            return clearIfNeeded()
        }

        switch update.kind {
        case .snapshot,
            .turnUpdated,
            .phaseChanged:
            return renderSnapshot(
                from: snapshot,
                chatCreatedAt: chatCreatedAt,
                chatUpdatedAt: chatUpdatedAt,
                allowIncrementalUpdate: false
            )
        case .itemUpserted(let item):
            return renderSnapshot(
                from: snapshot,
                chatCreatedAt: chatCreatedAt,
                chatUpdatedAt: chatUpdatedAt,
                allowIncrementalUpdate: hasLogDocument && item.turnID == snapshot.turn.id
            )
        case .itemTextAppended(_, _, _, let item):
            return renderSnapshot(
                from: snapshot,
                chatCreatedAt: chatCreatedAt,
                chatUpdatedAt: chatUpdatedAt,
                allowIncrementalUpdate: hasLogDocument && item.turnID == snapshot.turn.id
            )
        case .itemRemoved:
            return renderSnapshot(
                from: snapshot,
                chatCreatedAt: chatCreatedAt,
                chatUpdatedAt: chatUpdatedAt,
                allowIncrementalUpdate: hasLogDocument
            )
        case .ignored:
            return nil
        }
    }

    private mutating func renderSnapshot(
        from snapshot: CodexChatProjectedTurnSnapshot,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?,
        allowIncrementalUpdate: Bool
    ) -> ReviewMonitorLogSourceChange? {
        guard
            let document = logProjection.render(
                from: snapshot,
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
