import CodexKit

@MainActor
struct ReviewMonitorCodexSelectionTitlePresentation: Equatable, Sendable {
    var title: String
    var subtitle: String
}

@MainActor
final class ReviewMonitorCodexSelectionTitleResolver {
    private let modelContext: CodexModelContext
    private let fetchedChats: CodexFetchedResults<CodexChat>

    init(modelContext: CodexModelContext) {
        self.modelContext = modelContext
        self.fetchedChats = modelContext.fetchedResults(
            for: Self.codexReviewChatsDescriptor,
            sectionedBy: .workspaceGroup
        )
    }

    func refresh() async throws {
        try await fetchedChats.performFetch()
    }

    func titlePresentation(
        for selection: ReviewMonitorSelection?
    ) -> ReviewMonitorCodexSelectionTitlePresentation? {
        switch selection {
        case .workspaceGroup(let id):
            guard let workspaceGroup = modelContext.model(for: id) else {
                return nil
            }
            return Self.titlePresentation(for: workspaceGroup)

        case .workspace(let id):
            guard let workspace = modelContext.model(for: id) else {
                return nil
            }
            return Self.titlePresentation(for: workspace)

        case .chat(let id):
            guard let chat = loadedChat(id: id) else {
                return nil
            }
            return Self.titlePresentation(for: chat)

        case nil:
            return nil
        }
    }

    private func loadedChat(id: CodexThreadID) -> CodexChat? {
        fetchedChats.items.first { $0.id == id }
    }

    private static func titlePresentation(
        for workspaceGroup: CodexWorkspaceGroup
    ) -> ReviewMonitorCodexSelectionTitlePresentation? {
        let workspacePaths = workspaceGroup.workspaces.map(\.url.path)
        guard workspacePaths.isEmpty == false else {
            return nil
        }
        let subtitle =
            workspacePaths.count == 1
            ? (workspacePaths.first ?? "")
            : "\(workspacePaths.count) workspaces"
        return ReviewMonitorCodexSelectionTitlePresentation(
            title: workspaceGroup.name,
            subtitle: subtitle
        )
    }

    private static func titlePresentation(
        for workspace: CodexWorkspace
    ) -> ReviewMonitorCodexSelectionTitlePresentation {
        ReviewMonitorCodexSelectionTitlePresentation(
            title: workspace.name,
            subtitle: workspace.url.path
        )
    }

    private static func titlePresentation(
        for chat: CodexChat
    ) -> ReviewMonitorCodexSelectionTitlePresentation {
        ReviewMonitorCodexSelectionTitlePresentation(
            title: chat.title,
            subtitle: chat.workspace?.url.path ?? ""
        )
    }

    private static var codexReviewChatsDescriptor: CodexFetchDescriptor<CodexChat> {
        CodexFetchDescriptor<CodexChat>(
            predicate: .init(sourceKinds: [.subAgentReview]),
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        )
    }
}
