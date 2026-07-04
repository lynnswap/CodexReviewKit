import Observation
import CodexKit
import CodexReviewKit

@MainActor
@Observable
public final class ReviewMonitorUIState {
    let auth: CodexReviewAuthModel
    private let persistSidebarReviewChatFilter: (SidebarReviewChatFilter) -> Void
    var selection: ReviewMonitorSelection?
    var sidebarSelection = SidebarPickerSelection.workspace
    var sidebarReviewChatFilter: SidebarReviewChatFilter {
        didSet {
            guard sidebarReviewChatFilter != oldValue else {
                return
            }
            persistSidebarReviewChatFilter(sidebarReviewChatFilter)
        }
    }

    package init(
        auth: CodexReviewAuthModel,
        sidebarReviewChatFilter: SidebarReviewChatFilter = .all,
        persistSidebarReviewChatFilter: @escaping (SidebarReviewChatFilter) -> Void = { _ in }
    ) {
        self.auth = auth
        self.sidebarReviewChatFilter = sidebarReviewChatFilter
        self.persistSidebarReviewChatFilter = persistSidebarReviewChatFilter
    }

    package func selectChat(id: CodexThreadID?) {
        selection = id.map(ReviewMonitorSelection.chat)
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
