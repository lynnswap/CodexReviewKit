import Foundation

package extension CodexReviewAPI.Read {
struct Result: Codable, Sendable, Hashable {
    package var jobID: String
    package var core: ReviewJobCore
    package var elapsedSeconds: Int?
    package var cancellable: Bool
    package var logs: [ReviewLogEntry]
    package var logsPage: CodexReviewAPI.Log.Page
    package var rawLogText: String

    package init(
        jobID: String,
        core: ReviewJobCore,
        elapsedSeconds: Int? = nil,
        cancellable: Bool,
        logs: [ReviewLogEntry],
        logsPage: CodexReviewAPI.Log.Page,
        rawLogText: String
    ) {
        self.jobID = jobID
        self.core = core
        self.elapsedSeconds = elapsedSeconds
        self.cancellable = cancellable
        self.logs = logs
        self.logsPage = logsPage
        self.rawLogText = rawLogText
    }
}
}


package extension CodexReviewAPI.Log {
struct PageRequest: Codable, Sendable, Hashable {
    package static let defaultLimit = 100
    package static let maxLimit = 500
    package static let `default` = CodexReviewAPI.Log.PageRequest()

    package var offset: Int?
    package var limit: Int

    package init(offset: Int? = nil, limit: Int = Self.defaultLimit) {
        self.offset = offset
        self.limit = limit
    }

    package func validated() throws -> CodexReviewAPI.Log.PageRequest {
        if let offset, offset < 0 {
            throw CodexReviewAPI.Error.invalidArguments("logOffset must be greater than or equal to 0.")
        }
        guard (1...Self.maxLimit).contains(limit) else {
            throw CodexReviewAPI.Error.invalidArguments("logLimit must be between 1 and \(Self.maxLimit).")
        }
        return self
    }

    package func page(total: Int) -> CodexReviewAPI.Log.Page {
        let resolvedOffset = if let offset {
            min(offset, total)
        } else {
            max(0, total - limit)
        }
        let returned = min(limit, max(0, total - resolvedOffset))
        let hasMoreBefore = resolvedOffset > 0
        let hasMoreAfter = resolvedOffset + returned < total
        return CodexReviewAPI.Log.Page(
            total: total,
            offset: resolvedOffset,
            limit: limit,
            returned: returned,
            hasMoreBefore: hasMoreBefore,
            hasMoreAfter: hasMoreAfter,
            previousOffset: hasMoreBefore ? max(0, resolvedOffset - limit) : nil,
            nextOffset: hasMoreAfter ? resolvedOffset + returned : nil
        )
    }
}
}


package extension CodexReviewAPI.Log {
struct Page: Codable, Sendable, Hashable {
    package var total: Int
    package var offset: Int
    package var limit: Int
    package var returned: Int
    package var hasMoreBefore: Bool
    package var hasMoreAfter: Bool
    package var previousOffset: Int?
    package var nextOffset: Int?

    package init(
        total: Int,
        offset: Int,
        limit: Int,
        returned: Int,
        hasMoreBefore: Bool,
        hasMoreAfter: Bool,
        previousOffset: Int?,
        nextOffset: Int?
    ) {
        self.total = total
        self.offset = offset
        self.limit = limit
        self.returned = returned
        self.hasMoreBefore = hasMoreBefore
        self.hasMoreAfter = hasMoreAfter
        self.previousOffset = previousOffset
        self.nextOffset = nextOffset
    }
}
}


package extension CodexReviewAPI.Log {
enum Filter: String, Codable, Sendable, Hashable {
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
