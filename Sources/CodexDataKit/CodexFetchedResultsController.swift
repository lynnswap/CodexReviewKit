import Foundation

public struct CodexFetchedResultsIndexPath: Sendable, Hashable {
    public var section: Int
    public var item: Int

    public init(section: Int, item: Int) {
        self.section = section
        self.item = item
    }
}

public struct CodexFetchedResultsSnapshot<ItemID: Hashable & Sendable>: Sendable, Hashable {
    public struct Section: Identifiable, Sendable, Hashable {
        public var id: CodexFetchSectionID
        public var title: String?
        public var itemIDs: [ItemID]

        public init(id: CodexFetchSectionID, title: String?, itemIDs: [ItemID]) {
            self.id = id
            self.title = title
            self.itemIDs = itemIDs
        }
    }

    public var sections: [Section]

    public init(sections: [Section] = []) {
        self.sections = sections
    }

    public var sectionIDs: [CodexFetchSectionID] {
        sections.map(\.id)
    }

    public var itemIDs: [ItemID] {
        sections.flatMap(\.itemIDs)
    }

    public func itemIDs(in sectionID: CodexFetchSectionID) -> [ItemID]? {
        sections.first { $0.id == sectionID }?.itemIDs
    }
}

extension CodexFetchedResultsSnapshot {
    init<Model: CodexPersistentModel>(
        sections: [CodexFetchSection<Model>]
    ) where Model.ID == ItemID {
        self.init(sections: sections.map { section in
            Section(
                id: section.id,
                title: section.title,
                itemIDs: section.items.map(\.id)
            )
        })
    }
}

public enum CodexFetchedResultsSectionChange: Sendable, Hashable {
    case insert(sectionID: CodexFetchSectionID, index: Int)
    case delete(sectionID: CodexFetchSectionID, index: Int)
    case move(sectionID: CodexFetchSectionID, from: Int, to: Int)
    case update(sectionID: CodexFetchSectionID, index: Int)
}

public enum CodexFetchedResultsItemChange<ItemID: Hashable & Sendable>: Sendable, Hashable {
    case insert(itemID: ItemID, indexPath: CodexFetchedResultsIndexPath)
    case delete(itemID: ItemID, indexPath: CodexFetchedResultsIndexPath)
    case move(
        itemID: ItemID,
        from: CodexFetchedResultsIndexPath,
        to: CodexFetchedResultsIndexPath
    )
    case update(itemID: ItemID, indexPath: CodexFetchedResultsIndexPath)
}

public enum CodexFetchedResultsTransactionReason: Sendable, Hashable {
    case initialFetch
    case refresh
    case pageAppend
    case insert
    case archive
    case remove
    case revalidate
}

public struct CodexFetchedResultsTransaction<Model: CodexPersistentModel>: Sendable, Hashable {
    public typealias ItemID = Model.ID

    public var reason: CodexFetchedResultsTransactionReason
    public var oldSnapshot: CodexFetchedResultsSnapshot<ItemID>
    public var newSnapshot: CodexFetchedResultsSnapshot<ItemID>
    public var sectionChanges: [CodexFetchedResultsSectionChange]
    public var itemChanges: [CodexFetchedResultsItemChange<ItemID>]

    public var isInitialFetch: Bool {
        reason == .initialFetch
    }

    public var hasChanges: Bool {
        sectionChanges.isEmpty == false || itemChanges.isEmpty == false
    }

    public init(
        reason: CodexFetchedResultsTransactionReason,
        oldSnapshot: CodexFetchedResultsSnapshot<ItemID>,
        newSnapshot: CodexFetchedResultsSnapshot<ItemID>,
        sectionChanges: [CodexFetchedResultsSectionChange],
        itemChanges: [CodexFetchedResultsItemChange<ItemID>]
    ) {
        self.reason = reason
        self.oldSnapshot = oldSnapshot
        self.newSnapshot = newSnapshot
        self.sectionChanges = sectionChanges
        self.itemChanges = itemChanges
    }

    init(
        reason: CodexFetchedResultsTransactionReason,
        oldSnapshot: CodexFetchedResultsSnapshot<ItemID>,
        newSnapshot: CodexFetchedResultsSnapshot<ItemID>,
        updatedItemIDs: Set<ItemID> = []
    ) {
        self.init(
            reason: reason,
            oldSnapshot: oldSnapshot,
            newSnapshot: newSnapshot,
            sectionChanges: Self.sectionChanges(from: oldSnapshot, to: newSnapshot),
            itemChanges: Self.itemChanges(
                from: oldSnapshot,
                to: newSnapshot,
                reason: reason,
                updatedItemIDs: updatedItemIDs
            )
        )
    }

    private static func sectionChanges(
        from oldSnapshot: CodexFetchedResultsSnapshot<ItemID>,
        to newSnapshot: CodexFetchedResultsSnapshot<ItemID>
    ) -> [CodexFetchedResultsSectionChange] {
        let oldIndexes = indexSections(oldSnapshot.sections)
        let newIndexes = indexSections(newSnapshot.sections)

        let deletes = oldSnapshot.sections.enumerated()
            .filter { _, section in newIndexes[section.id] == nil }
            .sorted { $0.offset > $1.offset }
            .map { index, section in
                CodexFetchedResultsSectionChange.delete(sectionID: section.id, index: index)
            }

        let inserts = newSnapshot.sections.enumerated()
            .filter { _, section in oldIndexes[section.id] == nil }
            .map { index, section in
                CodexFetchedResultsSectionChange.insert(sectionID: section.id, index: index)
            }

        let oldSurvivingSectionIDs = oldSnapshot.sections.map(\.id).filter {
            newIndexes[$0] != nil
        }
        let newSurvivingSectionIDs = newSnapshot.sections.map(\.id).filter {
            oldIndexes[$0] != nil
        }
        let oldSurvivingIndexes = indexSectionIDs(oldSurvivingSectionIDs)
        let newSurvivingIndexes = indexSectionIDs(newSurvivingSectionIDs)
        let moves = newSurvivingSectionIDs.compactMap {
            sectionID -> CodexFetchedResultsSectionChange? in
            guard oldSurvivingIndexes[sectionID] != newSurvivingIndexes[sectionID] else {
                return nil
            }
            guard let oldIndex = oldIndexes[sectionID], let newIndex = newIndexes[sectionID] else {
                return nil
            }
            guard oldIndex != newIndex else {
                return nil
            }
            return CodexFetchedResultsSectionChange.move(
                sectionID: sectionID,
                from: oldIndex,
                to: newIndex
            )
        }

        let updates = newSnapshot.sections.enumerated()
            .compactMap { newIndex, section -> CodexFetchedResultsSectionChange? in
                guard let oldIndex = oldIndexes[section.id] else {
                    return nil
                }
                guard oldSnapshot.sections[oldIndex].title != section.title else {
                    return nil
                }
                return CodexFetchedResultsSectionChange.update(sectionID: section.id, index: newIndex)
            }

        return deletes + inserts + moves + updates
    }

    private static func itemChanges(
        from oldSnapshot: CodexFetchedResultsSnapshot<ItemID>,
        to newSnapshot: CodexFetchedResultsSnapshot<ItemID>,
        reason: CodexFetchedResultsTransactionReason,
        updatedItemIDs: Set<ItemID>
    ) -> [CodexFetchedResultsItemChange<ItemID>] {
        let oldPositions = indexItems(oldSnapshot)
        let newPositions = indexItems(newSnapshot)
        let oldSectionIDs = Set(oldSnapshot.sectionIDs)
        let newSectionIDs = Set(newSnapshot.sectionIDs)
        let deleteInsertItemIDs = itemIDsForDeleteInsert(
            oldPositions: oldPositions,
            newPositions: newPositions,
            oldSectionIDs: oldSectionIDs,
            newSectionIDs: newSectionIDs
        )
        let oldRelativeIndexes = relativeIndexesByItemID(
            in: oldSnapshot,
            positions: oldPositions,
            otherPositions: newPositions
        )
        let newRelativeIndexes = relativeIndexesByItemID(
            in: newSnapshot,
            positions: newPositions,
            otherPositions: oldPositions
        )
        let reloadStableItems = reason == .refresh

        let deletes = oldPositions.values
            .filter { newPositions[$0.itemID] == nil || deleteInsertItemIDs.contains($0.itemID) }
            .sorted { lhs, rhs in
                if lhs.indexPath.section != rhs.indexPath.section {
                    return lhs.indexPath.section > rhs.indexPath.section
                }
                return lhs.indexPath.item > rhs.indexPath.item
            }
            .map {
                CodexFetchedResultsItemChange.delete(
                    itemID: $0.itemID,
                    indexPath: $0.indexPath
                )
            }

        let inserts = newPositions.values
            .filter { oldPositions[$0.itemID] == nil || deleteInsertItemIDs.contains($0.itemID) }
            .sorted { lhs, rhs in
                if lhs.indexPath.section != rhs.indexPath.section {
                    return lhs.indexPath.section < rhs.indexPath.section
                }
                return lhs.indexPath.item < rhs.indexPath.item
            }
            .map {
                CodexFetchedResultsItemChange.insert(
                    itemID: $0.itemID,
                    indexPath: $0.indexPath
                )
            }

        let moves = newPositions.values
            .compactMap { newPosition -> CodexFetchedResultsItemChange<ItemID>? in
                guard let oldPosition = oldPositions[newPosition.itemID] else {
                    return nil
                }
                guard deleteInsertItemIDs.contains(newPosition.itemID) == false else {
                    return nil
                }
                if oldPosition.sectionID != newPosition.sectionID {
                    return .move(
                        itemID: newPosition.itemID,
                        from: oldPosition.indexPath,
                        to: newPosition.indexPath
                    )
                }
                guard oldRelativeIndexes[newPosition.itemID]
                    != newRelativeIndexes[newPosition.itemID]
                else {
                    return nil
                }
                guard oldPosition.indexPath != newPosition.indexPath else {
                    return nil
                }
                return .move(
                    itemID: newPosition.itemID,
                    from: oldPosition.indexPath,
                    to: newPosition.indexPath
                )
            }
            .sorted { lhs, rhs in
                lhs.newIndexPathForOrdering < rhs.newIndexPathForOrdering
            }

        let updates = newPositions.values
            .compactMap { newPosition -> CodexFetchedResultsItemChange<ItemID>? in
                guard oldPositions[newPosition.itemID] != nil else {
                    return nil
                }
                guard deleteInsertItemIDs.contains(newPosition.itemID) == false else {
                    return nil
                }
                guard reloadStableItems || updatedItemIDs.contains(newPosition.itemID) else {
                    return nil
                }
                return .update(itemID: newPosition.itemID, indexPath: newPosition.indexPath)
            }
            .sorted { lhs, rhs in
                lhs.newIndexPathForOrdering < rhs.newIndexPathForOrdering
            }

        return deletes + inserts + moves + updates
    }

    private static func itemIDsForDeleteInsert(
        oldPositions: [ItemID: ItemPosition],
        newPositions: [ItemID: ItemPosition],
        oldSectionIDs: Set<CodexFetchSectionID>,
        newSectionIDs: Set<CodexFetchSectionID>
    ) -> Set<ItemID> {
        Set(newPositions.values.compactMap { newPosition in
            guard let oldPosition = oldPositions[newPosition.itemID],
                oldPosition.sectionID != newPosition.sectionID
            else {
                return nil
            }
            guard newSectionIDs.contains(oldPosition.sectionID) == false
                || oldSectionIDs.contains(newPosition.sectionID) == false
                || oldPosition.indexPath == newPosition.indexPath
            else {
                return nil
            }
            return newPosition.itemID
        })
    }

    private static func indexSections(
        _ sections: [CodexFetchedResultsSnapshot<ItemID>.Section]
    ) -> [CodexFetchSectionID: Int] {
        Dictionary(uniqueKeysWithValues: sections.enumerated().map { index, section in
            (section.id, index)
        })
    }

    private static func indexSectionIDs(
        _ sectionIDs: [CodexFetchSectionID]
    ) -> [CodexFetchSectionID: Int] {
        Dictionary(uniqueKeysWithValues: sectionIDs.enumerated().map { index, sectionID in
            (sectionID, index)
        })
    }

    private struct ItemPosition {
        var itemID: ItemID
        var sectionID: CodexFetchSectionID
        var indexPath: CodexFetchedResultsIndexPath
    }

    private static func indexItems(
        _ snapshot: CodexFetchedResultsSnapshot<ItemID>
    ) -> [ItemID: ItemPosition] {
        var positions: [ItemID: ItemPosition] = [:]
        for (sectionIndex, section) in snapshot.sections.enumerated() {
            for (itemIndex, itemID) in section.itemIDs.enumerated() where positions[itemID] == nil {
                positions[itemID] = ItemPosition(
                    itemID: itemID,
                    sectionID: section.id,
                    indexPath: CodexFetchedResultsIndexPath(
                        section: sectionIndex,
                        item: itemIndex
                    )
                )
            }
        }
        return positions
    }

    private static func relativeIndexesByItemID(
        in snapshot: CodexFetchedResultsSnapshot<ItemID>,
        positions: [ItemID: ItemPosition],
        otherPositions: [ItemID: ItemPosition]
    ) -> [ItemID: Int] {
        var indexes: [ItemID: Int] = [:]
        for section in snapshot.sections {
            var relativeIndex = 0
            for itemID in section.itemIDs {
                guard let position = positions[itemID],
                    let otherPosition = otherPositions[itemID],
                    position.sectionID == otherPosition.sectionID
                else {
                    continue
                }
                indexes[itemID] = relativeIndex
                relativeIndex += 1
            }
        }
        return indexes
    }
}

extension CodexFetchedResultsItemChange {
    fileprivate var newIndexPathForOrdering: CodexFetchedResultsIndexPath {
        switch self {
        case .insert(_, let indexPath), .update(_, let indexPath):
            indexPath
        case .delete(_, let indexPath):
            indexPath
        case .move(_, _, let indexPath):
            indexPath
        }
    }
}

extension CodexFetchedResultsIndexPath: Comparable {
    public static func < (
        lhs: CodexFetchedResultsIndexPath,
        rhs: CodexFetchedResultsIndexPath
    ) -> Bool {
        if lhs.section != rhs.section {
            return lhs.section < rhs.section
        }
        return lhs.item < rhs.item
    }
}
