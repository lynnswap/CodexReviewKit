import Observation
import CodexReviewKit

@MainActor
@Observable
final class ReviewMonitorUIState {
    let auth: CodexReviewAuthModel
    private let persistSidebarJobFilter: (SidebarJobFilter) -> Void
    var selection: ReviewMonitorSelection?
    var sidebarSelection = SidebarPickerSelection.workspace
    var sidebarJobFilter: SidebarJobFilter {
        didSet {
            guard sidebarJobFilter != oldValue else {
                return
            }
            persistSidebarJobFilter(sidebarJobFilter)
        }
    }

    init(
        auth: CodexReviewAuthModel,
        sidebarJobFilter: SidebarJobFilter = .all,
        persistSidebarJobFilter: @escaping (SidebarJobFilter) -> Void = { _ in }
    ) {
        self.auth = auth
        self.sidebarJobFilter = sidebarJobFilter
        self.persistSidebarJobFilter = persistSidebarJobFilter
    }

    var selectedWorkspaceSectionEntry: ReviewMonitorWorkspaceSectionSelection? {
        get {
            guard case .workspaceSection(let section) = selection else {
                return nil
            }
            return section
        }
        set {
            selection = newValue.map(ReviewMonitorSelection.workspaceSection)
        }
    }

    var selectionID: ReviewMonitorSelectionID? {
        selection?.id
    }

    var contentKind: ReviewMonitorContentKind {
        if auth.selectedAccount != nil || auth.hasAccounts {
            return .contentView
        }
        return .signInView
    }
}
