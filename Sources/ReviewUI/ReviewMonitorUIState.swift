import Observation
import CodexReview
import Foundation
import SwiftUI

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

    var contentKind: ReviewMonitorContentKind {
        if auth.selectedAccount != nil || auth.hasAccounts {
            return .contentView
        }
        return .signInView
    }
}

@MainActor
enum ReviewMonitorSelection {
    case workspaceSection(ReviewMonitorWorkspaceSectionSelection)
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

struct SidebarJobFilter: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let all: SidebarJobFilter = []
    static let running = SidebarJobFilter(rawValue: 1 << 0)
    static let latestFinished = SidebarJobFilter(rawValue: 1 << 1)
    static let menuFilters: [SidebarJobFilter] = [.running, .latestFinished]

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    var localized: LocalizedStringResource {
        if self == .all {
            "All Items"
        } else if self == .running {
            "Running"
        } else if self == .latestFinished {
            "Latest Finished"
        } else {
            "Custom"
        }
    }

    var isActive: Bool {
        isEmpty == false
    }

    var allowsJobReordering: Bool {
        contains(.latestFinished) == false
    }

    var persistedValue: String {
        guard isActive else {
            return "all"
        }
        return Self.menuFilters.compactMap { filter in
            contains(filter) ? filter.persistedSingleValue : nil
        }.joined(separator: ",")
    }

    init?(persistedValue: String) {
        if persistedValue == "all" {
            self = .all
            return
        }

        var filters = SidebarJobFilter(rawValue: 0)
        for component in persistedValue.split(separator: ",") {
            switch component.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "running":
                filters.insert(.running)
            case "latestFinished":
                filters.insert(.latestFinished)
            default:
                return nil
            }
        }
        guard filters.isActive else {
            return nil
        }
        self = filters
    }

    private var persistedSingleValue: String? {
        if self == .running {
            return "running"
        }
        if self == .latestFinished {
            return "latestFinished"
        }
        return nil
    }
}
