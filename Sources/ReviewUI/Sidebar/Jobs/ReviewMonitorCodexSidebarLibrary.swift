import CodexKit
import Foundation

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
}
