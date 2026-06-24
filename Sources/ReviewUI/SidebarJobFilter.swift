import Foundation

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
        self == .all || contains(.running)
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
