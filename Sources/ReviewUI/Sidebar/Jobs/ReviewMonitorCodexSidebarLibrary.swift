import CodexKit
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
            ReviewMonitorWorkspaceSectionSelection(
                id: id,
                title: title,
                workspaceCWDs: workspaces.map(\.cwd)
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
        package var workspaceCWD: String?
        package var updatedAt: Date?
        package var reviewIdentity: CodexReviewIdentity?

        package init(
            rowID: ReviewMonitorCodexSidebarRowID,
            id: CodexThreadID,
            title: String,
            preview: String?,
            workspaceCWD: String?,
            updatedAt: Date?,
            reviewIdentity: CodexReviewIdentity? = nil
        ) {
            self.rowID = rowID
            self.id = id
            self.title = title
            self.preview = preview
            self.workspaceCWD = workspaceCWD
            self.updatedAt = updatedAt
            self.reviewIdentity = reviewIdentity
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
            workspaceCWD: chat.workspace?.url.path,
            updatedAt: chat.updatedAt
        )
    }
}
