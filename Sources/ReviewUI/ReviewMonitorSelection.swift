import CodexKit
import CodexReviewKit

enum ReviewMonitorSelectionID: Hashable, Sendable {
    case workspaceSection(String)
    case workspace(CodexWorkspaceID)
    case chat(CodexThreadID)
    case job(String)
}

@MainActor
enum ReviewMonitorSelection {
    case workspaceSection(ReviewMonitorWorkspaceSectionSelection)
    case job(CodexReviewJob)

    var id: ReviewMonitorSelectionID {
        switch self {
        case .workspaceSection(let section):
            return .workspaceSection(section.id)
        case .job(let job):
            return .job(job.id)
        }
    }
}
