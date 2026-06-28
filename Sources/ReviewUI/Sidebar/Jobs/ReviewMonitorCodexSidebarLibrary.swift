import CodexKit
import CodexReviewKit
import Foundation

package struct ReviewMonitorCodexSidebarRowID: Hashable, Sendable, CustomStringConvertible {
    package var rawValue: String

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package static func section(_ id: String) -> Self {
        .init(rawValue: "section:\(id)")
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

package struct ReviewMonitorCodexSidebarSnapshot: Equatable, Sendable {
    package struct Section: Equatable, Sendable {
        package var rowID: ReviewMonitorCodexSidebarRowID
        package var id: String
        package var title: String
        package var workspaces: [Workspace]
        package var uncategorizedChats: [Chat]

        package var rowIDs: [ReviewMonitorCodexSidebarRowID] {
            [rowID] + workspaces.flatMap(\.rowIDs) + uncategorizedChats.map(\.rowID)
        }

        var selection: ReviewMonitorWorkspaceSectionSelection {
            var workspaceCWDs = workspaces.map(\.cwd)
            for chat in uncategorizedChats {
                guard let cwd = chat.workspaceCWD,
                      workspaceCWDs.contains(cwd) == false
                else {
                    continue
                }
                workspaceCWDs.append(cwd)
            }
            return ReviewMonitorWorkspaceSectionSelection(
                id: id,
                title: title,
                workspaceCWDs: workspaceCWDs
            )
        }
    }

    package struct Workspace: Equatable, Sendable {
        package var rowID: ReviewMonitorCodexSidebarRowID
        package var id: CodexWorkspaceID
        package var cwd: String
        package var title: String
        package var chats: [Chat]

        package var rowIDs: [ReviewMonitorCodexSidebarRowID] {
            [rowID] + chats.map(\.rowID)
        }
    }

    package struct Chat: Equatable, Sendable {
        package var rowID: ReviewMonitorCodexSidebarRowID
        package var id: CodexThreadID
        package var title: String
        package var preview: String?
        package var model: String?
        package var workspaceCWD: String?
        package var updatedAt: Date?
        package var recencyAt: Date?
        package var status: CodexThreadStatus?

        package init(
            rowID: ReviewMonitorCodexSidebarRowID,
            id: CodexThreadID,
            title: String,
            preview: String?,
            model: String? = nil,
            workspaceCWD: String?,
            updatedAt: Date?,
            recencyAt: Date? = nil,
            status: CodexThreadStatus? = nil
        ) {
            self.rowID = rowID
            self.id = id
            self.title = title
            self.preview = preview
            self.model = model
            self.workspaceCWD = workspaceCWD
            self.updatedAt = updatedAt
            self.recencyAt = recencyAt
            self.status = status
        }

        var activityDate: Date? {
            recencyAt ?? updatedAt
        }

        var isRunning: Bool {
            status?.isActive == true
        }

        var isFinished: Bool {
            status.map { $0.isActive == false } ?? false
        }
    }

    package var sections: [Section]

    package var rowIDs: [ReviewMonitorCodexSidebarRowID] {
        sections.flatMap(\.rowIDs)
    }

    package var outlineItems: [ReviewMonitorCodexSidebarOutlineItem] {
        sections.map(ReviewMonitorCodexSidebarOutlineItem.section)
    }

    package func chat(id: CodexThreadID) -> Chat? {
        for section in sections {
            for workspace in section.workspaces {
                if let chat = workspace.chats.first(where: { $0.id == id }) {
                    return chat
                }
            }
            if let chat = section.uncategorizedChats.first(where: { $0.id == id }) {
                return chat
            }
        }
        return nil
    }

    package func outlineItem(rowID: ReviewMonitorCodexSidebarRowID) -> ReviewMonitorCodexSidebarOutlineItem? {
        for section in sections {
            if section.rowID == rowID {
                return .section(section)
            }
            for workspace in section.workspaces {
                if workspace.rowID == rowID {
                    return .workspace(workspace)
                }
                if let chat = workspace.chats.first(where: { $0.rowID == rowID }) {
                    return .chat(chat)
                }
            }
            if let chat = section.uncategorizedChats.first(where: { $0.rowID == rowID }) {
                return .chat(chat)
            }
        }
        return nil
    }

    func filtered(by filter: SidebarReviewChatFilter) -> ReviewMonitorCodexSidebarSnapshot {
        guard filter.isActive else {
            return self
        }

        return ReviewMonitorCodexSidebarSnapshot(
            sections: sections.map { section in
                let latestFinishedChatID = filter.contains(.latestFinished)
                    ? Self.latestFinishedChat(in: section.allChats)?.id
                    : nil
                return Section(
                    rowID: section.rowID,
                    id: section.id,
                    title: section.title,
                    workspaces: section.workspaces.map { workspace in
                        Workspace(
                            rowID: workspace.rowID,
                            id: workspace.id,
                            cwd: workspace.cwd,
                            title: workspace.title,
                            chats: workspace.chats.filter {
                                Self.includes($0, filter: filter, latestFinishedChatID: latestFinishedChatID)
                            }
                        )
                    },
                    uncategorizedChats: section.uncategorizedChats.filter {
                        Self.includes($0, filter: filter, latestFinishedChatID: latestFinishedChatID)
                    }
                )
            }
        )
    }

    private static func includes(
        _ chat: Chat,
        filter: SidebarReviewChatFilter,
        latestFinishedChatID: CodexThreadID?
    ) -> Bool {
        if filter.contains(.running), chat.isRunning {
            return true
        }
        if filter.contains(.latestFinished), chat.id == latestFinishedChatID {
            return true
        }
        return false
    }

    private static func latestFinishedChat(in chats: [Chat]) -> Chat? {
        var latestChat: Chat?
        var latestDate = Date.distantPast
        for chat in chats {
            guard chat.isFinished else {
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

private extension ReviewMonitorCodexSidebarSnapshot.Section {
    var allChats: [ReviewMonitorCodexSidebarSnapshot.Chat] {
        workspaces.flatMap(\.chats) + uncategorizedChats
    }
}

struct ReviewMonitorCodexSidebarPresentationOrder: Equatable, Sendable {
    private var sectionIDs: [String] = []
    private var chatIDsByContainer: [ReviewMonitorCodexSidebarRowID: [CodexThreadID]] = [:]

    func applying(to snapshot: ReviewMonitorCodexSidebarSnapshot) -> ReviewMonitorCodexSidebarSnapshot {
        ReviewMonitorCodexSidebarSnapshot(
            sections: ordered(snapshot.sections, by: sectionIDs, id: \.id).map { section in
                ReviewMonitorCodexSidebarSnapshot.Section(
                    rowID: section.rowID,
                    id: section.id,
                    title: section.title,
                    workspaces: section.workspaces.map { workspace in
                        ReviewMonitorCodexSidebarSnapshot.Workspace(
                            rowID: workspace.rowID,
                            id: workspace.id,
                            cwd: workspace.cwd,
                            title: workspace.title,
                            chats: ordered(
                                workspace.chats,
                                by: chatIDsByContainer[workspace.rowID] ?? [],
                                id: \.id
                            )
                        )
                    },
                    uncategorizedChats: ordered(
                        section.uncategorizedChats,
                        by: chatIDsByContainer[section.rowID] ?? [],
                        id: \.id
                    )
                )
            }
        )
    }

    mutating func reorderSection(id: String, before targetID: String?) -> Bool {
        Self.reorder(id: id, before: targetID, in: &sectionIDs)
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

    mutating func prune(to snapshot: ReviewMonitorCodexSidebarSnapshot) {
        let activeSectionIDs = snapshot.sections.map(\.id)
        sectionIDs = sectionIDs.filter { activeSectionIDs.contains($0) }

        var activeChatIDsByContainer: [ReviewMonitorCodexSidebarRowID: Set<CodexThreadID>] = [:]
        for section in snapshot.sections {
            activeChatIDsByContainer[section.rowID] = Set(section.uncategorizedChats.map(\.id))
            for workspace in section.workspaces {
                activeChatIDsByContainer[workspace.rowID] = Set(workspace.chats.map(\.id))
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

extension CodexThreadStatus {
    init(reviewJobState: ReviewJobState) {
        switch reviewJobState {
        case .queued, .running:
            self = .active(activeFlags: [])
        case .succeeded, .failed, .cancelled:
            self = .idle
        }
    }
}

package enum ReviewMonitorCodexSidebarOutlineItem: Equatable, Sendable {
    case section(ReviewMonitorCodexSidebarSnapshot.Section)
    case workspace(ReviewMonitorCodexSidebarSnapshot.Workspace)
    case chat(ReviewMonitorCodexSidebarSnapshot.Chat)

    package var rowID: ReviewMonitorCodexSidebarRowID {
        switch self {
        case .section(let section):
            section.rowID
        case .workspace(let workspace):
            workspace.rowID
        case .chat(let chat):
            chat.rowID
        }
    }

    package var title: String {
        switch self {
        case .section(let section):
            section.title
        case .workspace(let workspace):
            workspace.title
        case .chat(let chat):
            chat.title
        }
    }

    var selectionID: ReviewMonitorSelectionID {
        switch self {
        case .section(let section):
            .workspaceSection(section.id)
        case .workspace(let workspace):
            .workspace(workspace.id)
        case .chat(let chat):
            .chat(chat.id)
        }
    }

    package var children: [ReviewMonitorCodexSidebarOutlineItem] {
        switch self {
        case .section(let section):
            section.workspaces.map(ReviewMonitorCodexSidebarOutlineItem.workspace)
                + section.uncategorizedChats.map(ReviewMonitorCodexSidebarOutlineItem.chat)
        case .workspace(let workspace):
            workspace.chats.map(ReviewMonitorCodexSidebarOutlineItem.chat)
        case .chat:
            []
        }
    }

    package var isExpandable: Bool {
        children.isEmpty == false
    }
}

@MainActor
final class ReviewMonitorCodexSidebarOutlineTree {
    private var nodesByRowID: [ReviewMonitorCodexSidebarRowID: ReviewMonitorCodexSidebarOutlineNode] = [:]
    private(set) var roots: [ReviewMonitorCodexSidebarOutlineNode] = []

    func apply(snapshot: ReviewMonitorCodexSidebarSnapshot) {
        var activeRowIDs: Set<ReviewMonitorCodexSidebarRowID> = []
        roots = snapshot.outlineItems.map { node(for: $0, activeRowIDs: &activeRowIDs) }
        nodesByRowID = nodesByRowID.filter { activeRowIDs.contains($0.key) }
    }

    func node(rowID: ReviewMonitorCodexSidebarRowID) -> ReviewMonitorCodexSidebarOutlineNode? {
        nodesByRowID[rowID]
    }

    private func node(
        for item: ReviewMonitorCodexSidebarOutlineItem,
        activeRowIDs: inout Set<ReviewMonitorCodexSidebarRowID>
    ) -> ReviewMonitorCodexSidebarOutlineNode {
        activeRowIDs.insert(item.rowID)
        let node = nodesByRowID[item.rowID] ?? ReviewMonitorCodexSidebarOutlineNode(item: item)
        nodesByRowID[item.rowID] = node
        node.item = item
        node.children = item.children.map { child in
            self.node(for: child, activeRowIDs: &activeRowIDs)
        }
        return node
    }
}

@MainActor
final class ReviewMonitorCodexSidebarOutlineNode {
    fileprivate(set) var item: ReviewMonitorCodexSidebarOutlineItem
    fileprivate(set) var children: [ReviewMonitorCodexSidebarOutlineNode] = []

    fileprivate init(item: ReviewMonitorCodexSidebarOutlineItem) {
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

    var isExpandable: Bool {
        children.isEmpty == false
    }
}

@MainActor
package struct ReviewMonitorCodexSidebarWorkspace {
    package var workspace: CodexWorkspace
    package var chats: [CodexChat]

    package var id: CodexWorkspaceID {
        workspace.id
    }

    package var cwd: String {
        workspace.url.path
    }

    package var title: String {
        workspace.name
    }
}

@MainActor
package struct ReviewMonitorCodexSidebarSection {
    package var id: String
    package var title: String
    package var workspaces: [ReviewMonitorCodexSidebarWorkspace]
    package var uncategorizedChats: [CodexChat]

    package var chats: [CodexChat] {
        workspaces.flatMap(\.chats) + uncategorizedChats
    }

    var selection: ReviewMonitorWorkspaceSectionSelection {
        ReviewMonitorWorkspaceSectionSelection(
            id: id,
            title: title,
            workspaceCWDs: workspaces.map(\.cwd)
        )
    }
}

@MainActor
package final class ReviewMonitorCodexSidebarLibrary {
    package static var defaultRequest: CodexFetchRequest<CodexChat> {
        CodexFetchRequest<CodexChat>(
            filter: .init(sourceKinds: [.subAgentReview]),
            sortDescriptors: [.updatedAt(.reverse)],
            sectionDescriptor: .workspaceGroup
        )
    }

    private let fetchedResults: CodexFetchedResults<CodexChat>

    package init(
        modelContext: CodexModelContext,
        request: CodexFetchRequest<CodexChat> = ReviewMonitorCodexSidebarLibrary.defaultRequest
    ) {
        self.fetchedResults = modelContext.fetchedResults(for: request)
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

    package var sections: [ReviewMonitorCodexSidebarSection] {
        Self.sidebarSections(from: fetchedResults.sections)
    }

    package var snapshot: ReviewMonitorCodexSidebarSnapshot {
        Self.sidebarSnapshot(from: sections)
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

    private static func sidebarSections(
        from fetchSections: [CodexFetchSection<CodexChat>]
    ) -> [ReviewMonitorCodexSidebarSection] {
        fetchSections.map { fetchSection in
            var workspaces: [ReviewMonitorCodexSidebarWorkspace] = []
            var workspaceIndexesByID: [CodexWorkspaceID: Int] = [:]
            var uncategorizedChats: [CodexChat] = []

            for chat in fetchSection.items {
                guard let workspace = chat.workspace else {
                    uncategorizedChats.append(chat)
                    continue
                }

                if let index = workspaceIndexesByID[workspace.id] {
                    workspaces[index].chats.append(chat)
                } else {
                    workspaceIndexesByID[workspace.id] = workspaces.count
                    workspaces.append(ReviewMonitorCodexSidebarWorkspace(
                        workspace: workspace,
                        chats: [chat]
                    ))
                }
            }

            return ReviewMonitorCodexSidebarSection(
                id: fetchSection.id,
                title: fetchSection.title ?? "Unknown",
                workspaces: workspaces,
                uncategorizedChats: uncategorizedChats
            )
        }
    }

    private static func sidebarSnapshot(
        from sections: [ReviewMonitorCodexSidebarSection]
    ) -> ReviewMonitorCodexSidebarSnapshot {
        ReviewMonitorCodexSidebarSnapshot(
            sections: sections.map { section in
                ReviewMonitorCodexSidebarSnapshot.Section(
                    rowID: .section(section.id),
                    id: section.id,
                    title: section.title,
                    workspaces: section.workspaces.map { workspace in
                        ReviewMonitorCodexSidebarSnapshot.Workspace(
                            rowID: .workspace(workspace.id),
                            id: workspace.id,
                            cwd: workspace.cwd,
                            title: workspace.title,
                            chats: workspace.chats.map(Self.snapshotChat(_:))
                        )
                    },
                    uncategorizedChats: section.uncategorizedChats.map(Self.snapshotChat(_:))
                )
            }
        )
    }

    private static func snapshotChat(_ chat: CodexChat) -> ReviewMonitorCodexSidebarSnapshot.Chat {
        ReviewMonitorCodexSidebarSnapshot.Chat(
            rowID: .chat(chat.id),
            id: chat.id,
            title: chat.title,
            preview: chat.preview,
            model: chat.modelProvider,
            workspaceCWD: chat.workspace?.url.path,
            updatedAt: chat.updatedAt,
            recencyAt: chat.recencyAt,
            status: chat.status
        )
    }
}
