import Foundation

package extension CodexReviewAPI.Read {
struct Result: Codable, Sendable, Hashable {
    package var runID: ReviewRunID
    package var core: ReviewRunCore
    package var presentation: ReviewRunPresentation
    package var elapsedSeconds: Int?

    package var cancellable: Bool {
        presentation.isCancellable
    }

    package init(
        runID: ReviewRunID,
        core: ReviewRunCore,
        presentation: ReviewRunPresentation,
        elapsedSeconds: Int? = nil
    ) {
        self.runID = runID
        self.core = core
        self.presentation = presentation
        self.elapsedSeconds = elapsedSeconds
    }
}
}


package extension CodexReviewAPI.Run {
struct ListItem: Codable, Sendable, Hashable {
    package var runID: ReviewRunID
    package var cwd: String
    package var targetSummary: String
    package var core: ReviewRunCore
    package var presentation: ReviewRunPresentation
    package var elapsedSeconds: Int?

    package var cancellable: Bool {
        presentation.isCancellable
    }

    package init(
        runID: ReviewRunID,
        cwd: String,
        targetSummary: String,
        core: ReviewRunCore,
        presentation: ReviewRunPresentation,
        elapsedSeconds: Int?
    ) {
        self.runID = runID
        self.cwd = cwd
        self.targetSummary = targetSummary
        self.core = core
        self.presentation = presentation
        self.elapsedSeconds = elapsedSeconds
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
    package var runID: ReviewRunID?
    package var cwd: String?
    package var statuses: [ReviewRunState]?

    package init(
        runID: ReviewRunID? = nil,
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
                .map { "- \($0.runID.rawValue) [\($0.core.status.rawValue)] \($0.cwd) \($0.targetSummary)" }
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
    package var runID: ReviewRunID
    package var cancelled: Bool
    package var core: ReviewRunCore
    package var presentation: ReviewRunPresentation

    package init(
        runID: ReviewRunID,
        cancelled: Bool,
        core: ReviewRunCore,
        presentation: ReviewRunPresentation
    ) {
        self.runID = runID
        self.cancelled = cancelled
        self.core = core
        self.presentation = presentation
    }
}
}
