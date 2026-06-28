import CodexKit
import CodexReviewKit

enum ReviewMonitorSelectionID: Hashable, Sendable {
    case workspaceSection(String)
    case workspace(CodexWorkspaceID)
    case chat(CodexThreadID)
}

@MainActor
enum ReviewMonitorSelection {
    case workspaceSection(ReviewMonitorWorkspaceSectionSelection)
    case workspace(ReviewMonitorCodexSidebarSnapshot.Workspace)
    case chat(CodexThreadID)

    var id: ReviewMonitorSelectionID {
        switch self {
        case .workspaceSection(let section):
            return .workspaceSection(section.id)
        case .workspace(let workspace):
            return .workspace(workspace.id)
        case .chat(let id):
            return .chat(id)
        }
    }
}
