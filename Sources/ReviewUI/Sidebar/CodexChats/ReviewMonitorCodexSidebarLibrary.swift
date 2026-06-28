import CodexKit
import CodexReviewKit
import Foundation
import Observation

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

@MainActor
package struct ReviewMonitorCodexSidebarSnapshot: Equatable {
    @MainActor
    package struct Section: Equatable {
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

    @MainActor
    package struct Workspace: Equatable {
        private struct Fixture: Equatable {
            var cwd: String
            var title: String
        }

        private enum Source: Equatable {
            case codex(CodexWorkspace)
            case fixture(Fixture)

            static func == (lhs: Source, rhs: Source) -> Bool {
                switch (lhs, rhs) {
                case (.codex(let lhs), .codex(let rhs)):
                    lhs === rhs
                case (.fixture(let lhs), .fixture(let rhs)):
                    lhs == rhs
                default:
                    false
                }
            }
        }

        package var rowID: ReviewMonitorCodexSidebarRowID
        package var id: CodexWorkspaceID
        package var chats: [Chat]
        private var source: Source

        package var rowIDs: [ReviewMonitorCodexSidebarRowID] {
            [rowID] + chats.map(\.rowID)
        }

        package var codexWorkspace: CodexWorkspace? {
            switch source {
            case .codex(let workspace):
                workspace
            case .fixture:
                nil
            }
        }

        package var cwd: String {
            switch source {
            case .codex(let workspace):
                workspace.url.path
            case .fixture(let fixture):
                fixture.cwd
            }
        }

        package var title: String {
            switch source {
            case .codex(let workspace):
                workspace.name
            case .fixture(let fixture):
                fixture.title
            }
        }

        func replacingChats(_ chats: [Chat]) -> Self {
            var copy = self
            copy.chats = chats
            return copy
        }

        package init(
            rowID: ReviewMonitorCodexSidebarRowID,
            id: CodexWorkspaceID,
            cwd: String,
            title: String,
            chats: [Chat]
        ) {
            self.rowID = rowID
            self.id = id
            self.chats = chats
            self.source = .fixture(Fixture(cwd: cwd, title: title))
        }

        package init(
            workspace: CodexWorkspace,
            chats: [Chat]
        ) {
            self.rowID = .workspace(workspace.id)
            self.id = workspace.id
            self.chats = chats
            self.source = .codex(workspace)
        }
    }

    @MainActor
    package struct Chat: Equatable {
        private struct Fixture: Equatable {
            var title: String
            var preview: String?
            var model: String?
            var workspaceCWD: String?
            var updatedAt: Date?
            var recencyAt: Date?
            var status: CodexThreadStatus?
        }

        private enum Source: Equatable {
            case codex(CodexChat)
            case fixture(Fixture)

            static func == (lhs: Source, rhs: Source) -> Bool {
                switch (lhs, rhs) {
                case (.codex(let lhs), .codex(let rhs)):
                    lhs === rhs
                case (.fixture(let lhs), .fixture(let rhs)):
                    lhs == rhs
                default:
                    false
                }
            }
        }

        package var rowID: ReviewMonitorCodexSidebarRowID
        package var id: CodexThreadID
        private var source: Source

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
            self.source = .fixture(
                Fixture(
                    title: title,
                    preview: preview,
                    model: model,
                    workspaceCWD: workspaceCWD,
                    updatedAt: updatedAt,
                    recencyAt: recencyAt,
                    status: status
                ))
        }

        package init(chat: CodexChat) {
            self.rowID = .chat(chat.id)
            self.id = chat.id
            self.source = .codex(chat)
        }

        package var codexChat: CodexChat? {
            switch source {
            case .codex(let chat):
                chat
            case .fixture:
                nil
            }
        }

        package var title: String {
            switch source {
            case .codex(let chat):
                chat.title
            case .fixture(let fixture):
                fixture.title
            }
        }

        package var preview: String? {
            switch source {
            case .codex(let chat):
                chat.preview
            case .fixture(let fixture):
                fixture.preview
            }
        }

        package var model: String? {
            switch source {
            case .codex(let chat):
                chat.modelProvider
            case .fixture(let fixture):
                fixture.model
            }
        }

        package var workspaceCWD: String? {
            switch source {
            case .codex(let chat):
                chat.workspace?.url.path
            case .fixture(let fixture):
                fixture.workspaceCWD
            }
        }

        package var updatedAt: Date? {
            switch source {
            case .codex(let chat):
                chat.updatedAt
            case .fixture(let fixture):
                fixture.updatedAt
            }
        }

        package var recencyAt: Date? {
            switch source {
            case .codex(let chat):
                chat.recencyAt
            case .fixture(let fixture):
                fixture.recencyAt
            }
        }

        package var status: CodexThreadStatus? {
            switch source {
            case .codex(let chat):
                chat.status
            case .fixture(let fixture):
                fixture.status
            }
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
                let latestFinishedChatID =
                    filter.contains(.latestFinished)
                    ? Self.latestFinishedChat(in: section.allChats)?.id
                    : nil
                var filteredSection = section
                filteredSection.workspaces = section.workspaces.map { workspace in
                    workspace.replacingChats(
                        workspace.chats.filter {
                            Self.includes($0, filter: filter, latestFinishedChatID: latestFinishedChatID)
                        }
                    )
                }
                filteredSection.uncategorizedChats = section.uncategorizedChats.filter {
                    Self.includes($0, filter: filter, latestFinishedChatID: latestFinishedChatID)
                }
                return filteredSection
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

@MainActor
struct ReviewMonitorCodexSidebarPresentationOrder: Equatable {
    private var sectionIDs: [String] = []
    private var chatIDsByContainer: [ReviewMonitorCodexSidebarRowID: [CodexThreadID]] = [:]

    func applying(to snapshot: ReviewMonitorCodexSidebarSnapshot) -> ReviewMonitorCodexSidebarSnapshot {
        ReviewMonitorCodexSidebarSnapshot(
            sections: ordered(snapshot.sections, by: sectionIDs, id: \.id).map { section in
                var orderedSection = section
                orderedSection.workspaces = section.workspaces.map { workspace in
                    workspace.replacingChats(
                        ordered(
                            workspace.chats,
                            by: chatIDsByContainer[workspace.rowID] ?? [],
                            id: \.id
                        )
                    )
                }
                orderedSection.uncategorizedChats = ordered(
                    section.uncategorizedChats,
                    by: chatIDsByContainer[section.rowID] ?? [],
                    id: \.id
                )
                return orderedSection
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

@MainActor
package enum ReviewMonitorCodexSidebarOutlineItem: Equatable {
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
    struct ApplyResult: Equatable {
        var topologyChanged: Bool
        var topologyChanges: [ReviewMonitorCodexSidebarOutlineTopologyChange]
    }

    private var nodesByRowID: [ReviewMonitorCodexSidebarRowID: ReviewMonitorCodexSidebarOutlineNode] = [:]
    private(set) var roots: [ReviewMonitorCodexSidebarOutlineNode] = []

    func apply(snapshot: ReviewMonitorCodexSidebarSnapshot) -> ApplyResult {
        let oldTopology = topology
        var activeRowIDs: Set<ReviewMonitorCodexSidebarRowID> = []
        roots = snapshot.outlineItems.map { node(for: $0, activeRowIDs: &activeRowIDs) }
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
        let children = item.children.map { child in
            self.node(for: child, activeRowIDs: &activeRowIDs)
        }
        if node.children.map(\.rowID) != children.map(\.rowID) {
            node.children = children
        }
        return node
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
                    workspaces.append(
                        ReviewMonitorCodexSidebarWorkspace(
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
                            workspace: workspace.workspace,
                            chats: workspace.chats.map(Self.snapshotChat(_:))
                        )
                    },
                    uncategorizedChats: section.uncategorizedChats.map(Self.snapshotChat(_:))
                )
            }
        )
    }

    private static func snapshotChat(_ chat: CodexChat) -> ReviewMonitorCodexSidebarSnapshot.Chat {
        ReviewMonitorCodexSidebarSnapshot.Chat(chat: chat)
    }
}
