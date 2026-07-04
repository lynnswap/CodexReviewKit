import CodexKit
import CodexReviewKit

enum ReviewMonitorSelectionID: Hashable, Sendable {
    case workspaceGroup(CodexWorkspaceGroupID)
    case chat(CodexThreadID)
}

@MainActor
enum ReviewMonitorSelection: Hashable, Sendable {
    case workspaceGroup(CodexWorkspaceGroupID)
    case chat(CodexThreadID)

    var id: ReviewMonitorSelectionID {
        switch self {
        case .workspaceGroup(let id):
            return .workspaceGroup(id)
        case .chat(let id):
            return .chat(id)
        }
    }
}
