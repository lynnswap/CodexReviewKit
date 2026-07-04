import Foundation

package extension CodexReviewAPI.Read {
struct Result: Codable, Sendable, Hashable {
    package var runID: String
    package var core: ReviewRunCore
    package var elapsedSeconds: Int?
    package var cancellable: Bool

    package init(
        runID: String,
        core: ReviewRunCore,
        elapsedSeconds: Int? = nil,
        cancellable: Bool
    ) {
        self.runID = runID
        self.core = core
        self.elapsedSeconds = elapsedSeconds
        self.cancellable = cancellable
    }
}
}


package extension CodexReviewAPI.Run {
struct ListItem: Codable, Sendable, Hashable {
    package var runID: String
    package var cwd: String
    package var targetSummary: String
    package var core: ReviewRunCore
    package var elapsedSeconds: Int?
    package var cancellable: Bool

    package init(
        runID: String,
        cwd: String,
        targetSummary: String,
        core: ReviewRunCore,
        elapsedSeconds: Int?,
        cancellable: Bool
    ) {
        self.runID = runID
        self.cwd = cwd
        self.targetSummary = targetSummary
        self.core = core
        self.elapsedSeconds = elapsedSeconds
        self.cancellable = cancellable
    }
}
}


package extension CodexReviewAPI.List {
struct Result: Codable, Sendable, Hashable {
    package var items: [CodexReviewAPI.Run.ListItem]

    package init(items: [CodexReviewAPI.Run.ListItem]) {
        self.items = items
    }
}
}


package extension CodexReviewAPI.Run {
struct Selector: Sendable, Hashable {
    package var runID: String?
    package var cwd: String?
    package var statuses: [ReviewRunState]?

    package init(
        runID: String? = nil,
        cwd: String? = nil,
        statuses: [ReviewRunState]? = nil
    ) {
        self.runID = runID
        self.cwd = cwd?.nilIfEmpty
        self.statuses = statuses
    }
}
}


package extension CodexReviewAPI.Run {
enum SelectionError: Swift.Error, Sendable {
    case ambiguous([CodexReviewAPI.Run.ListItem])
}
}


extension CodexReviewAPI.Run.SelectionError: LocalizedError {
    package var errorDescription: String? {
        switch self {
        case .ambiguous(let reviewRuns):
            let candidates = reviewRuns
                .map { "- \($0.runID) [\($0.core.lifecycle.status.rawValue)] \($0.cwd) \($0.targetSummary)" }
                .joined(separator: "\n")
            return """
            Review run selector matched multiple review runs:
            \(candidates)
            Specify runID or narrow cwd/statuses.
            """
        }
    }
}


package extension CodexReviewAPI.Cancel {
struct Outcome: Codable, Sendable, Hashable {
    package var runID: String
    package var cancelled: Bool
    package var core: ReviewRunCore

    package init(
        runID: String,
        cancelled: Bool,
        core: ReviewRunCore
    ) {
        self.runID = runID
        self.cancelled = cancelled
        self.core = core
    }
}
}
