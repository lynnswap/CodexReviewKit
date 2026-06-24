import CodexReviewKit

@MainActor
enum ReviewMonitorSelection {
    case workspaceSection(ReviewMonitorWorkspaceSectionSelection)
    case job(CodexReviewJob)
}
