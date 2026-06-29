import CodexKit
import CodexReviewKit
import Foundation
import Observation

package struct ReviewMonitorCodexSidebarRowID: Hashable, Sendable, CustomStringConvertible {
    package var rawValue: String

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package static func workspaceGroup(_ id: CodexWorkspaceGroupID) -> Self {
        .init(rawValue: "workspaceGroup:\(id.rawValue)")
    }

    package static func workspace(_ id: CodexWorkspaceID) -> Self {
        .init(rawValue: "workspace:\(id.rawValue)")
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
    package var workspaceGroupID: CodexWorkspaceGroupID {
        switch id {
        case .workspaceGroup(let id):
            id
        default:
            CodexWorkspaceGroupID(rawValue: id.description)
        }
    }

    package var displayTitle: String {
        workspaceGroup?.name ?? title ?? "Unknown"
    }

    package var rowID: ReviewMonitorCodexSidebarRowID {
        .workspaceGroup(workspaceGroupID)
    }

    package var workspaceGroup: CodexWorkspaceGroup? {
        items.lazy.compactMap { $0.workspace?.workspaceGroup }.first { $0.id == workspaceGroupID }
            ?? items.lazy.compactMap { $0.workspace?.workspaceGroup }.first
    }

    package var workspaces: [CodexWorkspace] {
        var workspaces: [CodexWorkspace] = []
        var workspaceIDs = Set<CodexWorkspaceID>()
        for chat in items {
            guard let workspace = chat.workspace,
                workspaceIDs.contains(workspace.id) == false
            else {
                continue
            }
            workspaceIDs.insert(workspace.id)
            workspaces.append(workspace)
        }
        return workspaces
    }

    package var chats: [CodexChat] {
        items
    }

    package var uncategorizedChats: [CodexChat] {
        items.filter { $0.workspace == nil }
    }

    package var displaysWorkspaceNodes: Bool {
        workspaces.count > 1 || (workspaces.isEmpty == false && uncategorizedChats.isEmpty == false)
    }

    package var rowIDs: [ReviewMonitorCodexSidebarRowID] {
        if displaysWorkspaceNodes {
            return [rowID]
                + workspaces.flatMap { workspace in
                    [ReviewMonitorCodexSidebarRowID.workspace(workspace.id)]
                        + chats(in: workspace.id).map { .chat($0.id) }
                }
                + uncategorizedChats.map { .chat($0.id) }
        }
        return [rowID] + items.map { .chat($0.id) }
    }

    package func chats(in workspaceID: CodexWorkspaceID) -> [CodexChat] {
        items.filter { $0.workspace?.id == workspaceID }
    }

    package func chat(id: CodexThreadID) -> CodexChat? {
        items.first { $0.id == id }
    }

    package func hasSameIdentity(as other: Self) -> Bool {
        workspaceGroupID == other.workspaceGroupID
            && workspaceGroup === other.workspaceGroup
            && displayTitle == other.displayTitle
            && items.elementsEqual(other.items) { $0 === $1 }
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

        return map { section in
            let latestFinishedChatID =
                filter.contains(.latestFinished)
                ? Self.latestFinishedChat(in: section.chats)?.id
                : nil
            return CodexFetchSection(
                id: section.id,
                title: section.title,
                items: section.items.filter {
                    Self.includes($0, filter: filter, latestFinishedChatID: latestFinishedChatID)
                }
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
        ordered(sections, by: workspaceGroupIDs, id: \.workspaceGroupID).map { section in
            if section.displaysWorkspaceNodes == false {
                return CodexFetchSection(
                    id: section.id,
                    title: section.title,
                    items: ordered(
                        section.items,
                        by: chatIDsByContainer[section.rowID] ?? [],
                        id: \.id
                    )
                )
            }

            var items: [CodexChat] = []
            for workspace in section.workspaces {
                let container = ReviewMonitorCodexSidebarRowID.workspace(workspace.id)
                items.append(
                    contentsOf: ordered(
                        section.chats(in: workspace.id),
                        by: chatIDsByContainer[container] ?? [],
                        id: \.id
                    ))
            }
            items.append(
                contentsOf: ordered(
                    section.uncategorizedChats,
                    by: chatIDsByContainer[section.rowID] ?? [],
                    id: \.id
                ))
            return CodexFetchSection(id: section.id, title: section.title, items: items)
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
        let activeWorkspaceGroupIDs = sections.map(\.workspaceGroupID)
        workspaceGroupIDs = workspaceGroupIDs.filter { activeWorkspaceGroupIDs.contains($0) }

        var activeChatIDsByContainer: [ReviewMonitorCodexSidebarRowID: Set<CodexThreadID>] = [:]
        for section in sections {
            if section.displaysWorkspaceNodes {
                activeChatIDsByContainer[section.rowID] = Set(section.uncategorizedChats.map(\.id))
                for workspace in section.workspaces {
                    activeChatIDsByContainer[.workspace(workspace.id)] = Set(section.chats(in: workspace.id).map(\.id))
                }
            } else {
                activeChatIDsByContainer[section.rowID] = Set(section.items.map(\.id))
            }
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
package enum ReviewMonitorCodexSidebarOutlineItem {
    case workspaceGroup(CodexWorkspaceGroup)
    case fallbackWorkspaceGroup(id: CodexWorkspaceGroupID, title: String)
    case workspace(CodexWorkspace)
    case chat(CodexChat)

    package var rowID: ReviewMonitorCodexSidebarRowID {
        switch self {
        case .workspaceGroup(let workspaceGroup):
            .workspaceGroup(workspaceGroup.id)
        case .fallbackWorkspaceGroup(let id, _):
            .workspaceGroup(id)
        case .workspace(let workspace):
            .workspace(workspace.id)
        case .chat(let chat):
            .chat(chat.id)
        }
    }

    package var title: String {
        switch self {
        case .workspaceGroup(let workspaceGroup):
            workspaceGroup.name
        case .fallbackWorkspaceGroup(_, let title):
            title
        case .workspace(let workspace):
            workspace.name
        case .chat(let chat):
            chat.title
        }
    }

    var selectionID: ReviewMonitorSelectionID {
        switch self {
        case .workspaceGroup(let workspaceGroup):
            .workspaceGroup(workspaceGroup.id)
        case .fallbackWorkspaceGroup(let id, _):
            .workspaceGroup(id)
        case .workspace(let workspace):
            .workspace(workspace.id)
        case .chat(let chat):
            .chat(chat.id)
        }
    }

    package func hasSameIdentity(as other: Self) -> Bool {
        switch (self, other) {
        case (.workspaceGroup(let lhs), .workspaceGroup(let rhs)):
            lhs === rhs
        case (.fallbackWorkspaceGroup(let lhsID, let lhsTitle), .fallbackWorkspaceGroup(let rhsID, let rhsTitle)):
            lhsID == rhsID && lhsTitle == rhsTitle
        case (.workspace(let lhs), .workspace(let rhs)):
            lhs === rhs
        case (.chat(let lhs), .chat(let rhs)):
            lhs === rhs
        default:
            false
        }
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
            if let workspaceGroup = section.workspaceGroup {
                .workspaceGroup(workspaceGroup)
            } else {
                .fallbackWorkspaceGroup(id: section.workspaceGroupID, title: section.displayTitle)
            }
        let node = node(for: item, activeRowIDs: &activeRowIDs)
        let children: [ReviewMonitorCodexSidebarOutlineNode]
        if section.displaysWorkspaceNodes {
            children =
                section.workspaces.map { workspace in
                    workspaceNode(
                        for: workspace,
                        chats: section.chats(in: workspace.id),
                        activeRowIDs: &activeRowIDs
                    )
                }
                + section.uncategorizedChats.map { chat in
                    self.node(for: .chat(chat), activeRowIDs: &activeRowIDs)
                }
        } else {
            children = section.items.map { chat in
                self.node(for: .chat(chat), activeRowIDs: &activeRowIDs)
            }
        }
        updateChildren(of: node, to: children)
        return node
    }

    private func workspaceNode(
        for workspace: CodexWorkspace,
        chats: [CodexChat],
        activeRowIDs: inout Set<ReviewMonitorCodexSidebarRowID>
    ) -> ReviewMonitorCodexSidebarOutlineNode {
        let node = node(for: .workspace(workspace), activeRowIDs: &activeRowIDs)
        let children = chats.map { child in
            self.node(for: .chat(child), activeRowIDs: &activeRowIDs)
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
        if node.item.hasSameIdentity(as: item) == false {
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
@Observable
final class ReviewMonitorCodexSidebarOutlineNode {
    fileprivate(set) var item: ReviewMonitorCodexSidebarOutlineItem
    fileprivate(set) var children: [ReviewMonitorCodexSidebarOutlineNode] = []

    init(item: ReviewMonitorCodexSidebarOutlineItem) {
        self.item = item
    }

    var rowID: ReviewMonitorCodexSidebarRowID {
        item.rowID
    }

    var title: String {
        item.title
    }

    var selectionID: ReviewMonitorSelectionID {
        item.selectionID
    }

    var workspaceGroupID: CodexWorkspaceGroupID? {
        switch item {
        case .workspaceGroup(let workspaceGroup):
            workspaceGroup.id
        case .fallbackWorkspaceGroup(let id, _):
            id
        case .workspace, .chat:
            nil
        }
    }

    var isExpandable: Bool {
        children.isEmpty == false
    }
}

@MainActor
package final class ReviewMonitorCodexSidebarLibrary {
    package static var defaultDescriptor: CodexFetchDescriptor<CodexChat> {
        CodexFetchDescriptor<CodexChat>(
            predicate: .init(sourceKinds: [.subAgentReview]),
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        )
    }

    private let fetchedResults: CodexFetchedResults<CodexChat>

    package init(
        modelContext: CodexModelContext,
        descriptor: CodexFetchDescriptor<CodexChat> =
            ReviewMonitorCodexSidebarLibrary.defaultDescriptor
    ) {
        self.fetchedResults = modelContext.fetchedResults(
            for: descriptor,
            sectionedBy: .workspaceGroup
        )
    }

    package var phase: CodexDataPhase {
        fetchedResults.phase
    }

    package var lastErrorDescription: String? {
        fetchedResults.lastErrorDescription
    }

    package var nextCursor: String? {
        fetchedResults.nextCursor
    }

    package var sections: [CodexFetchSection<CodexChat>] {
        fetchedResults.sections
    }

    package func performFetch() async throws {
        try await fetchedResults.performFetch()
    }

    package func refresh() async throws {
        try await fetchedResults.refresh()
    }

    package func loadNextPage() async throws {
        try await fetchedResults.loadNextPage()
    }

    package func chat(id: CodexThreadID) -> CodexChat? {
        fetchedResults.items.first { $0.id == id }
    }

}
