import Foundation

package struct ReviewReadResult: Codable, Sendable, Hashable {
    package var jobID: String
    package var core: ReviewJobCore
    package var elapsedSeconds: Int?
    package var cancellable: Bool
    package var logs: [ReviewLogEntry]
    package var rawLogText: String

    package init(
        jobID: String,
        core: ReviewJobCore,
        elapsedSeconds: Int? = nil,
        cancellable: Bool,
        logs: [ReviewLogEntry],
        rawLogText: String
    ) {
        self.jobID = jobID
        self.core = core
        self.elapsedSeconds = elapsedSeconds
        self.cancellable = cancellable
        self.logs = logs
        self.rawLogText = rawLogText
    }
}

package enum ReviewLogFilter: String, Codable, Sendable, Hashable {
    case defaultSetting = "default"
    case all

    package func includes(_ entry: ReviewLogEntry) -> Bool {
        switch self {
        case .defaultSetting:
            entry.kind != .commandOutput
        case .all:
            true
        }
    }
}

package struct ReviewJobListItem: Codable, Sendable, Hashable {
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

package struct ReviewListResult: Codable, Sendable, Hashable {
    package var items: [ReviewJobListItem]

    package init(items: [ReviewJobListItem]) {
        self.items = items
    }
}

package struct ReviewJobSelector: Sendable, Hashable {
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

package enum ReviewJobSelectionError: Error, Sendable {
    case ambiguous([ReviewJobListItem])
}

extension ReviewJobSelectionError: LocalizedError {
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

package struct ReviewCancelOutcome: Codable, Sendable, Hashable {
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
