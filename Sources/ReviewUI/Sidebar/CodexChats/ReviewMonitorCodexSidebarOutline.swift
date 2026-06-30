import CodexKit
import CodexReviewKit
import Foundation

package struct ReviewMonitorCodexSidebarRowID: Hashable, Sendable, CustomStringConvertible {
    package var rawValue: String

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package static func workspaceGroup(_ id: CodexWorkspaceGroupID) -> Self {
        .init(rawValue: "workspaceGroup:\(id.rawValue)")
    }

    package static func section(_ id: CodexFetchSectionID) -> Self {
        switch id {
        case .default:
            .init(rawValue: "section:default")
        case .workspaceGroup(let id):
            .init(rawValue: "section:workspaceGroup:\(id.rawValue)")
        case .workspace(let id):
            .init(rawValue: "section:workspace:\(id.rawValue)")
        case .unknown(let rawValue):
            .init(rawValue: "section:unknown:\(rawValue)")
        }
    }

    package static func chat(_ id: CodexThreadID) -> Self {
        .init(rawValue: "chat:\(id.rawValue)")
    }

    package var description: String {
        rawValue
    }
}

@MainActor
extension CodexFetchSection where Model == CodexChat {
    package var sidebarWorkspaceGroupID: CodexWorkspaceGroupID? {
        workspaceGroupID
    }

    package var displayTitle: String {
        workspaceGroup?.name ?? title ?? "Unknown"
    }

    package var rowID: ReviewMonitorCodexSidebarRowID {
        if let sidebarWorkspaceGroupID {
            return .workspaceGroup(sidebarWorkspaceGroupID)
        }
        return .section(id)
    }

    package var rowIDs: [ReviewMonitorCodexSidebarRowID] {
        return [rowID] + items.map { .chat($0.id) }
    }
}

@MainActor
extension Array where Element == CodexFetchSection<CodexChat> {
    var rowIDs: [ReviewMonitorCodexSidebarRowID] {
        flatMap(\.rowIDs)
    }

    func chat(id: CodexThreadID) -> CodexChat? {
        for section in self {
            if let chat = section.chat(id: id) {
                return chat
            }
        }
        return nil
    }

    func filtered(by filter: SidebarReviewChatFilter) -> [CodexFetchSection<CodexChat>] {
        guard filter.isActive else {
            return self
        }

        return compactMap { section in
            let latestFinishedChatID =
                filter.contains(.latestFinished)
                ? Self.latestFinishedChat(in: section.items)?.id
                : nil
            let items = section.items.filter {
                Self.includes($0, filter: filter, latestFinishedChatID: latestFinishedChatID)
            }
            guard items.isEmpty == false else {
                return nil
            }
            return CodexFetchSection(
                id: section.id,
                title: section.title,
                items: items
            )
        }
    }

    private static func includes(
        _ chat: CodexChat,
        filter: SidebarReviewChatFilter,
        latestFinishedChatID: CodexThreadID?
    ) -> Bool {
        if filter.contains(.running), chat.status?.isActive == true {
            return true
        }
        if filter.contains(.latestFinished), chat.id == latestFinishedChatID {
            return true
        }
        return false
    }

    private static func latestFinishedChat(in chats: [CodexChat]) -> CodexChat? {
        var latestChat: CodexChat?
        var latestDate = Date.distantPast
        for chat in chats {
            guard chat.status.map({ $0.isActive == false }) ?? false else {
                continue
            }
            let finishedAt = chat.activityDate ?? .distantPast
            if latestChat == nil || finishedAt > latestDate {
                latestChat = chat
                latestDate = finishedAt
            }
        }
        return latestChat
    }
}

private extension CodexChat {
    var activityDate: Date? {
        recencyAt ?? updatedAt
    }
}

@MainActor
struct ReviewMonitorCodexSidebarPresentationOrder: Equatable {
    private var workspaceGroupIDs: [CodexWorkspaceGroupID] = []
    private var chatIDsByContainer: [ReviewMonitorCodexSidebarRowID: [CodexThreadID]] = [:]

    func applying(
        to sections: [CodexFetchSection<CodexChat>]
    ) -> [CodexFetchSection<CodexChat>] {
        orderedSections(sections).map { section in
            CodexFetchSection(
                id: section.id,
                title: section.title,
                items: ordered(
                    section.items,
                    by: chatIDsByContainer[section.rowID] ?? [],
                    id: \.id
                )
            )
        }
    }

    mutating func reorderWorkspaceGroup(id: CodexWorkspaceGroupID, before targetID: CodexWorkspaceGroupID?) -> Bool {
        Self.reorder(id: id, before: targetID, in: &workspaceGroupIDs)
    }

    mutating func reorderChat(
        id: CodexThreadID,
        in container: ReviewMonitorCodexSidebarRowID,
        currentOrder: [CodexThreadID],
        before targetID: CodexThreadID?
    ) -> Bool {
        var ids = mergedOrder(preferredIDs: chatIDsByContainer[container] ?? [], currentOrder: currentOrder)
        let didChange = Self.reorder(id: id, before: targetID, in: &ids)
        chatIDsByContainer[container] = ids
        return didChange
    }

    mutating func prune(to sections: [CodexFetchSection<CodexChat>]) {
        let activeWorkspaceGroupIDs = sections.compactMap(\.sidebarWorkspaceGroupID)
        workspaceGroupIDs = workspaceGroupIDs.filter { activeWorkspaceGroupIDs.contains($0) }

        var activeChatIDsByContainer: [ReviewMonitorCodexSidebarRowID: Set<CodexThreadID>] = [:]
        for section in sections {
            activeChatIDsByContainer[section.rowID] = Set(section.items.map(\.id))
        }
        let currentChatIDsByContainer = chatIDsByContainer
        chatIDsByContainer = currentChatIDsByContainer.reduce(into: [:]) { result, entry in
            guard let activeChatIDs = activeChatIDsByContainer[entry.key] else {
                return
            }
            let filteredIDs = entry.value.filter { activeChatIDs.contains($0) }
            guard filteredIDs.isEmpty == false else {
                return
            }
            result[entry.key] = filteredIDs
        }
    }

    private func orderedSections(
        _ sections: [CodexFetchSection<CodexChat>]
    ) -> [CodexFetchSection<CodexChat>] {
        guard workspaceGroupIDs.isEmpty == false else {
            return sections
        }

        var orderedSections: [CodexFetchSection<CodexChat>] = []
        var segment: [CodexFetchSection<CodexChat>] = []
        for section in sections {
            guard section.sidebarWorkspaceGroupID == nil else {
                segment.append(section)
                continue
            }
            orderedSections.append(contentsOf: orderedWorkspaceGroupSegment(segment))
            segment.removeAll(keepingCapacity: true)
            orderedSections.append(section)
        }
        orderedSections.append(contentsOf: orderedWorkspaceGroupSegment(segment))
        return orderedSections
    }

    private func orderedWorkspaceGroupSegment(
        _ segment: [CodexFetchSection<CodexChat>]
    ) -> [CodexFetchSection<CodexChat>] {
        guard segment.count > 1 else {
            return segment
        }
        let currentDomainIDs = segment.compactMap(\.sidebarWorkspaceGroupID)
        let orderedDomainIDs = mergedOrder(preferredIDs: workspaceGroupIDs, currentOrder: currentDomainIDs)
        let sectionsByDomainID = Dictionary(
            uniqueKeysWithValues: segment.compactMap { section in
                section.sidebarWorkspaceGroupID.map { ($0, section) }
            }
        )
        return orderedDomainIDs.compactMap { sectionsByDomainID[$0] }
    }

    private func ordered<Element, ID: Hashable>(
        _ elements: [Element],
        by preferredIDs: [ID],
        id: (Element) -> ID
    ) -> [Element] {
        guard preferredIDs.isEmpty == false else {
            return elements
        }
        let rankByID = Dictionary(uniqueKeysWithValues: preferredIDs.enumerated().map { ($0.element, $0.offset) })
        return elements.enumerated().sorted { lhs, rhs in
            let lhsRank = rankByID[id(lhs.element)] ?? Int.max
            let rhsRank = rankByID[id(rhs.element)] ?? Int.max
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private func mergedOrder<ID: Hashable>(preferredIDs: [ID], currentOrder: [ID]) -> [ID] {
        let activeIDs = Set(currentOrder)
        var merged = preferredIDs.filter { activeIDs.contains($0) }
        for id in currentOrder where merged.contains(id) == false {
            merged.append(id)
        }
        return merged
    }

    private static func reorder<ID: Hashable>(
        id: ID,
        before targetID: ID?,
        in ids: inout [ID]
    ) -> Bool {
        let originalIDs = ids
        ids.removeAll { $0 == id }
        let insertionIndex: Int
        if let targetID,
            let targetIndex = ids.firstIndex(of: targetID)
        {
            insertionIndex = targetIndex
        } else {
            insertionIndex = ids.count
        }
        ids.insert(id, at: insertionIndex)
        return ids != originalIDs
    }
}

@MainActor
package enum ReviewMonitorCodexSidebarOutlineItem: Equatable {
    case section(CodexFetchSectionID)
    case workspaceGroup(CodexWorkspaceGroupID)
    case chat(CodexThreadID)

    package var rowID: ReviewMonitorCodexSidebarRowID {
        switch self {
        case .section(let id):
            .section(id)
        case .workspaceGroup(let id):
            .workspaceGroup(id)
        case .chat(let id):
            .chat(id)
        }
    }

    var selectionID: ReviewMonitorSelectionID? {
        switch self {
        case .section:
            nil
        case .workspaceGroup(let id):
            .workspaceGroup(id)
        case .chat(let id):
            .chat(id)
        }
    }

    var workspaceGroupID: CodexWorkspaceGroupID? {
        switch self {
        case .workspaceGroup(let id):
            id
        case .section, .chat:
            nil
        }
    }

    var chatID: CodexThreadID? {
        switch self {
        case .chat(let id):
            id
        case .section, .workspaceGroup:
            nil
        }
    }

    var isChat: Bool {
        chatID != nil
    }
}

@MainActor
final class ReviewMonitorCodexSidebarOutlineTree {
    struct ApplyResult: Equatable {
        var topologyChanged: Bool
        var topologyChanges: [ReviewMonitorCodexSidebarOutlineTopologyChange]
    }

    private var nodesByRowID: [ReviewMonitorCodexSidebarRowID: ReviewMonitorCodexSidebarOutlineNode] = [:]
    private(set) var roots: [ReviewMonitorCodexSidebarOutlineNode] = []

    func apply(sections: [CodexFetchSection<CodexChat>]) -> ApplyResult {
        let oldTopology = topology
        var activeRowIDs: Set<ReviewMonitorCodexSidebarRowID> = []
        roots = sections.map { sectionNode(for: $0, activeRowIDs: &activeRowIDs) }
        nodesByRowID = nodesByRowID.filter { activeRowIDs.contains($0.key) }
        let newTopology = topology
        return ApplyResult(
            topologyChanged: newTopology != oldTopology,
            topologyChanges: Self.topologyChanges(from: oldTopology, to: newTopology)
        )
    }

    func node(rowID: ReviewMonitorCodexSidebarRowID) -> ReviewMonitorCodexSidebarOutlineNode? {
        nodesByRowID[rowID]
    }

    private var topology: ReviewMonitorCodexSidebarOutlineTopology {
        ReviewMonitorCodexSidebarOutlineTopology(
            roots: roots.map(\.rowID),
            childrenByRowID: nodesByRowID.mapValues { node in
                node.children.map(\.rowID)
            }
        )
    }

    private static func topologyChanges(
        from oldTopology: ReviewMonitorCodexSidebarOutlineTopology,
        to newTopology: ReviewMonitorCodexSidebarOutlineTopology
    ) -> [ReviewMonitorCodexSidebarOutlineTopologyChange] {
        var changes: [ReviewMonitorCodexSidebarOutlineTopologyChange] = []
        if oldTopology.roots != newTopology.roots {
            changes.append(
                ReviewMonitorCodexSidebarOutlineTopologyChange(
                    parentRowID: nil,
                    oldChildRowIDs: oldTopology.roots,
                    newChildRowIDs: newTopology.roots
                ))
        }

        let sharedParentRowIDs = Set(oldTopology.childrenByRowID.keys)
            .intersection(newTopology.childrenByRowID.keys)
            .sorted { $0.rawValue < $1.rawValue }
        for parentRowID in sharedParentRowIDs {
            let oldChildRowIDs = oldTopology.childrenByRowID[parentRowID] ?? []
            let newChildRowIDs = newTopology.childrenByRowID[parentRowID] ?? []
            guard oldChildRowIDs != newChildRowIDs else {
                continue
            }
            changes.append(
                ReviewMonitorCodexSidebarOutlineTopologyChange(
                    parentRowID: parentRowID,
                    oldChildRowIDs: oldChildRowIDs,
                    newChildRowIDs: newChildRowIDs
                ))
        }
        return changes
    }

    private func sectionNode(
        for section: CodexFetchSection<CodexChat>,
        activeRowIDs: inout Set<ReviewMonitorCodexSidebarRowID>
    ) -> ReviewMonitorCodexSidebarOutlineNode {
        let item: ReviewMonitorCodexSidebarOutlineItem =
            if let workspaceGroupID = section.sidebarWorkspaceGroupID {
                .workspaceGroup(workspaceGroupID)
            } else {
                .section(section.id)
            }
        let node = node(for: item, activeRowIDs: &activeRowIDs)
        let children = section.items.map { chat in
            self.node(for: .chat(chat.id), activeRowIDs: &activeRowIDs)
        }
        updateChildren(of: node, to: children)
        return node
    }

    private func node(
        for item: ReviewMonitorCodexSidebarOutlineItem,
        activeRowIDs: inout Set<ReviewMonitorCodexSidebarRowID>
    ) -> ReviewMonitorCodexSidebarOutlineNode {
        activeRowIDs.insert(item.rowID)
        let node = nodesByRowID[item.rowID] ?? ReviewMonitorCodexSidebarOutlineNode(item: item)
        nodesByRowID[item.rowID] = node
        if node.item != item {
            node.item = item
        }
        return node
    }

    private func updateChildren(
        of node: ReviewMonitorCodexSidebarOutlineNode,
        to children: [ReviewMonitorCodexSidebarOutlineNode]
    ) {
        if node.children.map(\.rowID) != children.map(\.rowID) {
            node.children = children
        }
    }
}

@MainActor
private struct ReviewMonitorCodexSidebarOutlineTopology: Equatable {
    var roots: [ReviewMonitorCodexSidebarRowID]
    var childrenByRowID: [ReviewMonitorCodexSidebarRowID: [ReviewMonitorCodexSidebarRowID]]
}

@MainActor
struct ReviewMonitorCodexSidebarOutlineTopologyChange: Equatable {
    var parentRowID: ReviewMonitorCodexSidebarRowID?
    var oldChildRowIDs: [ReviewMonitorCodexSidebarRowID]
    var newChildRowIDs: [ReviewMonitorCodexSidebarRowID]
}

@MainActor
final class ReviewMonitorCodexSidebarOutlineNode {
    fileprivate(set) var item: ReviewMonitorCodexSidebarOutlineItem
    fileprivate(set) var children: [ReviewMonitorCodexSidebarOutlineNode] = []

    init(item: ReviewMonitorCodexSidebarOutlineItem) {
        self.item = item
    }

    var rowID: ReviewMonitorCodexSidebarRowID {
        item.rowID
    }

    var selectionID: ReviewMonitorSelectionID? {
        item.selectionID
    }

    var workspaceGroupID: CodexWorkspaceGroupID? {
        item.workspaceGroupID
    }

    var isExpandable: Bool {
        children.isEmpty == false
    }
}
