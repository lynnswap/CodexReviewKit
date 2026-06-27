import CodexKit
import Foundation
import ReviewMonitorRendering

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
    private var document: ReviewTimelineDocument?
    private var logProjection = ReviewMonitorTimelineLogProjection()
    private var revision: UInt64 = 0

    mutating func reset() {
        turnProjection = CodexChatTurnProjection()
        document = nil
        logProjection = ReviewMonitorTimelineLogProjection()
        revision = 0
    }

    mutating func apply(
        _ change: CodexChatChange,
        activeTurnID: CodexTurnID?,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?
    ) -> ReviewMonitorLogSourceChange? {
        turnProjection.selection = activeTurnID.map(CodexChatTurnSelection.turn) ?? .latest
        let update = turnProjection.apply(change)
        guard update.affectsSelectedTurn else {
            return nil
        }
        guard let snapshot = update.snapshot else {
            let hadDocument = document != nil
            document = nil
            logProjection = ReviewMonitorTimelineLogProjection()
            return hadDocument ? .clear : nil
        }

        switch update.kind {
        case .snapshot,
            .turnUpdated,
            .phaseChanged:
            return rebuildDocument(
                from: snapshot,
                chatCreatedAt: chatCreatedAt,
                chatUpdatedAt: chatUpdatedAt
            )
        case .itemUpserted(let item):
            return rebuildOrReplaceBlock(
                for: item,
                turnSnapshot: snapshot.turn,
                chatCreatedAt: chatCreatedAt,
                chatUpdatedAt: chatUpdatedAt
            )
        case .itemTextAppended(_, _, _, let item):
            return replaceBlock(
                for: item,
                turnSnapshot: snapshot.turn,
                chatCreatedAt: chatCreatedAt,
                chatUpdatedAt: chatUpdatedAt
            )
        case .itemRemoved(let id, let turnID):
            return removeBlock(
                id: .init(rawValue: "\(turnID?.rawValue ?? snapshot.turn.id.rawValue):\(id)"),
                turnSnapshot: snapshot.turn
            )
        case .ignored:
            return nil
        }
    }

    private mutating func rebuildDocument(
        from snapshot: CodexChatProjectedTurnSnapshot,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?
    ) -> ReviewMonitorLogSourceChange? {
        let hadDocument = document != nil
        guard let nextDocument = ReviewMonitorCodexChatTimelineProjection().document(
            from: snapshot.turn,
            items: snapshot.items,
            chatCreatedAt: chatCreatedAt,
            chatUpdatedAt: chatUpdatedAt,
            revision: nextRevision()
        ) else {
            document = nil
            logProjection = ReviewMonitorTimelineLogProjection()
            return hadDocument ? .clear : nil
        }
        document = nextDocument
        return .replaceAll(logProjection.render(timelineDocument: nextDocument))
    }

    private mutating func rebuildOrReplaceBlock(
        for item: CodexChatItemSnapshot,
        turnSnapshot: CodexChatTurnStateSnapshot,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?
    ) -> ReviewMonitorLogSourceChange? {
        guard document != nil else {
            guard let snapshot = turnProjection.snapshot else {
                return nil
            }
            return rebuildDocument(
                from: snapshot,
                chatCreatedAt: chatCreatedAt,
                chatUpdatedAt: chatUpdatedAt
            )
        }
        return replaceBlock(
            for: item,
            turnSnapshot: turnSnapshot,
            chatCreatedAt: chatCreatedAt,
            chatUpdatedAt: chatUpdatedAt
        )
    }

    private mutating func replaceBlock(
        for item: CodexChatItemSnapshot,
        turnSnapshot: CodexChatTurnStateSnapshot,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?
    ) -> ReviewMonitorLogSourceChange? {
        guard var document else {
            guard let snapshot = turnProjection.snapshot else {
                return nil
            }
            return rebuildDocument(
                from: snapshot,
                chatCreatedAt: chatCreatedAt,
                chatUpdatedAt: chatUpdatedAt
            )
        }

        let projection = ReviewMonitorCodexChatTimelineProjection()
        let block = projection.block(
            from: item,
            turnSnapshot: turnSnapshot,
            chatCreatedAt: chatCreatedAt,
            chatUpdatedAt: chatUpdatedAt
        )
        if let index = document.blocks.firstIndex(where: { $0.id == block.id }) {
            document.blocks[index] = block
        } else {
            document.blocks.append(block)
            document.orderedBlockIDs.append(block.id)
        }
        refreshMetadata(
            in: &document,
            turn: turnSnapshot,
            latestActivityBlockID: block.id,
            revision: nextRevision()
        )
        self.document = document
        return .update(logProjection.render(timelineDocument: document))
    }

    private mutating func removeBlock(
        id: ReviewTimelineDocument.Block.ID,
        turnSnapshot: CodexChatTurnStateSnapshot
    ) -> ReviewMonitorLogSourceChange? {
        guard var document else {
            return nil
        }
        document.blocks.removeAll { $0.id == id }
        document.orderedBlockIDs.removeAll { $0 == id }
        let latestActivityBlockID = document.blocks.last?.id
        refreshMetadata(
            in: &document,
            turn: turnSnapshot,
            latestActivityBlockID: latestActivityBlockID,
            revision: nextRevision()
        )
        self.document = document.blocks.isEmpty ? nil : document
        guard let document = self.document else {
            logProjection = ReviewMonitorTimelineLogProjection()
            return .clear
        }
        return .update(logProjection.render(timelineDocument: document))
    }

    private mutating func nextRevision() -> UInt64 {
        revision &+= 1
        return revision
    }

    private func refreshMetadata(
        in document: inout ReviewTimelineDocument,
        turn: CodexChatTurnStateSnapshot,
        latestActivityBlockID: ReviewTimelineDocument.Block.ID?,
        revision: UInt64
    ) {
        document.timelineRevision = .init(rawValue: revision)
        document.activeBlockIDs = document.blocks.filter(\.isActive).map(\.id)
        document.activeBlockCount = document.activeBlockIDs.count
        document.latestActivityBlockID = latestActivityBlockID
        document.terminalStatus = ReviewMonitorCodexChatTimelineProjection().terminalStatus(for: turn)
        document.terminalSummary = turn.errorDescription
    }
}
