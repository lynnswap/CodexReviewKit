import Foundation

package extension CodexReviewAPI.Read {
struct Result: Codable, Sendable, Hashable {
    package var jobID: String
    package var core: ReviewJobCore
    package var elapsedSeconds: Int?
    package var cancellable: Bool

    package init(
        jobID: String,
        core: ReviewJobCore,
        elapsedSeconds: Int? = nil,
        cancellable: Bool
    ) {
        self.jobID = jobID
        self.core = core
        self.elapsedSeconds = elapsedSeconds
        self.cancellable = cancellable
    }
}
}


package extension CodexReviewAPI.Job {
struct ListItem: Codable, Sendable, Hashable {
    package var jobID: String
    package var cwd: String
    package var targetSummary: String
    package var core: ReviewJobCore
    package var elapsedSeconds: Int?
    package var cancellable: Bool

    package init(
        jobID: String,
        cwd: String,
        targetSummary: String,
        core: ReviewJobCore,
        elapsedSeconds: Int?,
        cancellable: Bool
    ) {
        self.jobID = jobID
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
    package var items: [CodexReviewAPI.Job.ListItem]

    package init(items: [CodexReviewAPI.Job.ListItem]) {
        self.items = items
    }
}
}


package extension CodexReviewAPI.Job {
struct Selector: Sendable, Hashable {
    package var jobID: String?
    package var cwd: String?
    package var statuses: [ReviewJobState]?

    package init(
        jobID: String? = nil,
        cwd: String? = nil,
        statuses: [ReviewJobState]? = nil
    ) {
        self.jobID = jobID
        self.cwd = cwd?.nilIfEmpty
        self.statuses = statuses
    }
}
}


package extension CodexReviewAPI.Job {
enum SelectionError: Swift.Error, Sendable {
    case ambiguous([CodexReviewAPI.Job.ListItem])
}
}


extension CodexReviewAPI.Job.SelectionError: LocalizedError {
    package var errorDescription: String? {
        switch self {
        case .ambiguous(let jobs):
            let candidates = jobs
                .map { "- \($0.jobID) [\($0.core.lifecycle.status.rawValue)] \($0.cwd) \($0.targetSummary)" }
                .joined(separator: "\n")
            return """
            Review job selector matched multiple jobs:
            \(candidates)
            Specify jobID or narrow cwd/statuses.
            """
        }
    }
}


package extension CodexReviewAPI.Cancel {
struct Outcome: Codable, Sendable, Hashable {
    package var jobID: String
    package var cancelled: Bool
    package var core: ReviewJobCore

    package init(
        jobID: String,
        cancelled: Bool,
        core: ReviewJobCore
    ) {
        self.jobID = jobID
        self.cancelled = cancelled
        self.core = core
    }
}
}
