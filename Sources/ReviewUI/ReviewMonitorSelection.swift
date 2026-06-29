import CodexKit
import CodexReviewKit

enum ReviewMonitorSelectionID: Hashable, Sendable {
    case workspaceGroup(CodexWorkspaceGroupID)
    case workspace(CodexWorkspaceID)
    case chat(CodexThreadID)
}

@MainActor
enum ReviewMonitorSelection: Hashable, Sendable {
    case workspaceGroup(CodexWorkspaceGroupID)
    case workspace(CodexWorkspaceID)
    case chat(CodexThreadID)

    var id: ReviewMonitorSelectionID {
        switch self {
        case .workspaceGroup(let id):
            return .workspaceGroup(id)
        case .workspace(let id):
            return .workspace(id)
        case .chat(let id):
            return .chat(id)
        }
    }
}
