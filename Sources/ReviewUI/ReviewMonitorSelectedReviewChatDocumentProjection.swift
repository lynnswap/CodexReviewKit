import CodexKit
import Foundation
import ReviewMonitorRendering

@MainActor
struct ReviewMonitorSelectedReviewChatDocumentProjection {
    private struct ItemKey: Hashable {
        var id: String
        var turnID: CodexTurnID?

        init(id: String, turnID: CodexTurnID?) {
            self.id = id
            self.turnID = turnID
        }

        init(_ item: CodexChatItemSnapshot) {
            self.id = item.id
            self.turnID = item.turnID
        }
    }

    private var turnsByID: [CodexTurnID: CodexChatTurnStateSnapshot] = [:]
    private var orderedTurnIDs: [CodexTurnID] = []
    private var itemsByKey: [ItemKey: CodexChatItemSnapshot] = [:]
    private var orderedItemKeys: [ItemKey] = []
    private var document: ReviewTimelineDocument?
    private var revision: UInt64 = 0

    mutating func reset() {
        turnsByID.removeAll(keepingCapacity: true)
        orderedTurnIDs.removeAll(keepingCapacity: true)
        itemsByKey.removeAll(keepingCapacity: true)
        orderedItemKeys.removeAll(keepingCapacity: true)
        document = nil
        revision = 0
    }

    mutating func apply(
        _ change: CodexChatChange,
        activeTurnID: CodexTurnID?,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?
    ) -> ReviewTimelineDocument? {
        switch change {
        case .snapshot(let snapshot):
            apply(snapshot)
            guard let effectiveTurnID = effectiveTurnID(activeTurnID: activeTurnID) else {
                document = nil
                return nil
            }
            return rebuildDocument(
                activeTurnID: effectiveTurnID,
                chatCreatedAt: chatCreatedAt,
                chatUpdatedAt: chatUpdatedAt
            )

        case .turnInserted(let turn), .turnUpdated(let turn):
            upsert(turn)
            guard let effectiveTurnID = effectiveTurnID(activeTurnID: activeTurnID),
                  turn.id == effectiveTurnID
            else {
                return document
            }
            return rebuildDocument(
                activeTurnID: effectiveTurnID,
                chatCreatedAt: chatCreatedAt,
                chatUpdatedAt: chatUpdatedAt
            )

        case .itemInserted(let item), .itemUpdated(let item):
            upsert(item)
            guard let effectiveTurnID = effectiveTurnID(
                activeTurnID: activeTurnID,
                preferredTurnID: item.turnID
            ),
                item.turnID == effectiveTurnID
            else {
                return document
            }
            return rebuildOrReplaceBlock(
                for: item,
                activeTurnID: effectiveTurnID,
                chatCreatedAt: chatCreatedAt,
                chatUpdatedAt: chatUpdatedAt
            )

        case .itemTextAppended(_, _, _, let item):
            upsert(item)
            guard let effectiveTurnID = effectiveTurnID(
                activeTurnID: activeTurnID,
                preferredTurnID: item.turnID
            ),
                item.turnID == effectiveTurnID
            else {
                return document
            }
            return replaceBlock(
                for: item,
                activeTurnID: effectiveTurnID,
                chatCreatedAt: chatCreatedAt,
                chatUpdatedAt: chatUpdatedAt
            )

        case .itemRemoved(let id, let turnID):
            removeItem(id: id, turnID: turnID)
            guard let effectiveTurnID = effectiveTurnID(
                activeTurnID: activeTurnID,
                preferredTurnID: turnID
            ),
                turnID == effectiveTurnID
            else {
                return document
            }
            return removeBlock(
                id: .init(rawValue: "\(effectiveTurnID.rawValue):\(id)"),
                activeTurnID: effectiveTurnID
            )

        case .phaseChanged:
            return document
        }
    }

    private mutating func apply(_ snapshot: CodexChatSnapshot) {
        turnsByID = Dictionary(uniqueKeysWithValues: snapshot.turns.map { ($0.id, $0) })
        orderedTurnIDs = snapshot.turns.map(\.id)
        itemsByKey.removeAll(keepingCapacity: true)
        orderedItemKeys.removeAll(keepingCapacity: true)
        for item in snapshot.items {
            upsert(item)
        }
    }

    private mutating func upsert(_ turn: CodexChatTurnStateSnapshot) {
        if turnsByID[turn.id] == nil {
            orderedTurnIDs.append(turn.id)
        }
        turnsByID[turn.id] = turn
    }

    private mutating func upsert(_ item: CodexChatItemSnapshot) {
        let key = ItemKey(item)
        if itemsByKey[key] == nil {
            orderedItemKeys.append(key)
        }
        itemsByKey[key] = item
    }

    private mutating func removeItem(id: String, turnID: CodexTurnID?) {
        let key = ItemKey(id: id, turnID: turnID)
        itemsByKey.removeValue(forKey: key)
        orderedItemKeys.removeAll { $0 == key }
    }

    private func effectiveTurnID(
        activeTurnID: CodexTurnID?,
        preferredTurnID: CodexTurnID? = nil
    ) -> CodexTurnID? {
        activeTurnID ?? orderedTurnIDs.last ?? preferredTurnID
    }

    private mutating func rebuildOrReplaceBlock(
        for item: CodexChatItemSnapshot,
        activeTurnID: CodexTurnID,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?
    ) -> ReviewTimelineDocument? {
        guard document != nil else {
            return rebuildDocument(
                activeTurnID: activeTurnID,
                chatCreatedAt: chatCreatedAt,
                chatUpdatedAt: chatUpdatedAt
            )
        }
        return replaceBlock(
            for: item,
            activeTurnID: activeTurnID,
            chatCreatedAt: chatCreatedAt,
            chatUpdatedAt: chatUpdatedAt
        )
    }

    private mutating func rebuildDocument(
        activeTurnID: CodexTurnID,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?
    ) -> ReviewTimelineDocument? {
        guard let turn = turnsByID[activeTurnID] else {
            document = nil
            return nil
        }
        let items = orderedItemKeys.compactMap { key -> CodexChatItemSnapshot? in
            guard key.turnID == activeTurnID else {
                return nil
            }
            return itemsByKey[key]
        }
        document = ReviewMonitorCodexChatTimelineProjection().document(
            from: turn,
            items: items,
            chatCreatedAt: chatCreatedAt,
            chatUpdatedAt: chatUpdatedAt,
            revision: nextRevision()
        )
        return document
    }

    private mutating func replaceBlock(
        for item: CodexChatItemSnapshot,
        activeTurnID: CodexTurnID,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?
    ) -> ReviewTimelineDocument? {
        guard let turn = turnsByID[activeTurnID] else {
            return rebuildDocument(
                activeTurnID: activeTurnID,
                chatCreatedAt: chatCreatedAt,
                chatUpdatedAt: chatUpdatedAt
            )
        }
        guard var document else {
            return rebuildDocument(
                activeTurnID: activeTurnID,
                chatCreatedAt: chatCreatedAt,
                chatUpdatedAt: chatUpdatedAt
            )
        }

        let projection = ReviewMonitorCodexChatTimelineProjection()
        let block = projection.block(
            from: item,
            turnSnapshot: turn,
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
            turn: turn,
            latestActivityBlockID: block.id,
            revision: nextRevision()
        )
        self.document = document
        return document
    }

    private mutating func removeBlock(
        id: ReviewTimelineDocument.Block.ID,
        activeTurnID: CodexTurnID
    ) -> ReviewTimelineDocument? {
        guard var document else {
            return nil
        }
        document.blocks.removeAll { $0.id == id }
        document.orderedBlockIDs.removeAll { $0 == id }
        let latestActivityBlockID = document.blocks.last?.id
        if let turn = turnsByID[activeTurnID] {
            refreshMetadata(
                in: &document,
                turn: turn,
                latestActivityBlockID: latestActivityBlockID,
                revision: nextRevision()
            )
        } else {
            document.timelineRevision = .init(rawValue: nextRevision())
            document.activeBlockIDs = document.blocks.filter(\.isActive).map(\.id)
            document.activeBlockCount = document.activeBlockIDs.count
            document.latestActivityBlockID = latestActivityBlockID
        }
        self.document = document.blocks.isEmpty ? nil : document
        return self.document
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
