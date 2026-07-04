import Foundation

package struct SidebarReviewChatFilter: OptionSet, Hashable, Sendable {
    package let rawValue: Int

    package static let all: SidebarReviewChatFilter = []
    package static let running = SidebarReviewChatFilter(rawValue: 1 << 0)
    package static let latestFinished = SidebarReviewChatFilter(rawValue: 1 << 1)
    package static let menuFilters: [SidebarReviewChatFilter] = [.running, .latestFinished]

    package init(rawValue: Int) {
        self.rawValue = rawValue
    }

    package var localized: LocalizedStringResource {
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

    package var isActive: Bool {
        isEmpty == false
    }

    package var allowsReviewChatReordering: Bool {
        self == .all || contains(.running)
    }

    package var persistedValue: String {
        guard isActive else {
            return "all"
        }
        return Self.menuFilters.compactMap { filter in
            contains(filter) ? filter.persistedSingleValue : nil
        }.joined(separator: ",")
    }

    package init?(persistedValue: String) {
        if persistedValue == "all" {
            self = .all
            return
        }

        var filters = SidebarReviewChatFilter(rawValue: 0)
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
