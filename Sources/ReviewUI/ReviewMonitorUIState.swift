import Observation
import CodexReview
import SwiftUI

@MainActor
@Observable
final class ReviewMonitorUIState {
    let auth: CodexReviewAuthModel
    var selection: ReviewMonitorSelection?
    var sidebarSelection = SidebarPickerSelection.workspace

    init(auth: CodexReviewAuthModel) {
        self.auth = auth
    }

    var selectedJobEntry: CodexReviewJob? {
        get {
            guard case .job(let job) = selection else {
                return nil
            }
            return job
        }
        set {
            selection = newValue.map(ReviewMonitorSelection.job)
        }
    }

    var selectedWorkspaceEntry: CodexReviewWorkspace? {
        get {
            guard case .workspace(let workspace) = selection else {
                return nil
            }
            return workspace
        }
        set {
            selection = newValue.map(ReviewMonitorSelection.workspace)
        }
    }

    var contentKind: ReviewMonitorContentKind {
        if auth.selectedAccount != nil || auth.hasAccounts {
            return .contentView
        }
        return .signInView
    }
}

@MainActor
enum ReviewMonitorSelection {
    case workspace(CodexReviewWorkspace)
    case job(CodexReviewJob)
}

enum ReviewMonitorContentKind: Equatable ,CaseIterable{
    case contentView
    case signInView
}

enum SidebarPickerSelection: CaseIterable, Hashable {
    case workspace
    case account

    var localized: LocalizedStringResource {
        switch self {
        case .workspace:
            "Workspace"
        case .account:
            "Account"
        }
    }

    var systemImage: String {
        switch self {
        case .workspace:
            "list.bullet"
        case .account:
            "person"
        }
    }
}
