import Foundation

package struct ReviewReadResult: Codable, Sendable, Hashable {
    package var jobID: String
    package var core: ReviewJobCore
    package var elapsedSeconds: Int?
    package var cancellable: Bool
    package var logs: [ReviewLogEntry]
    package var logsPage: ReviewLogPage
    package var rawLogText: String

    package init(
        jobID: String,
        core: ReviewJobCore,
        elapsedSeconds: Int? = nil,
        cancellable: Bool,
        logs: [ReviewLogEntry],
        logsPage: ReviewLogPage,
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

package struct ReviewLogPageRequest: Codable, Sendable, Hashable {
    package static let defaultLimit = 100
    package static let maxLimit = 500
    package static let `default` = ReviewLogPageRequest()

    package var offset: Int?
    package var limit: Int

    package init(offset: Int? = nil, limit: Int = Self.defaultLimit) {
        self.offset = offset
        self.limit = limit
    }

    package func validated() throws -> ReviewLogPageRequest {
        if let offset, offset < 0 {
            throw ReviewError.invalidArguments("logOffset must be greater than or equal to 0.")
        }
        guard (1...Self.maxLimit).contains(limit) else {
            throw ReviewError.invalidArguments("logLimit must be between 1 and \(Self.maxLimit).")
        }
        return self
    }

    package func page(total: Int) -> ReviewLogPage {
        let resolvedOffset = if let offset {
            min(offset, total)
        } else {
            max(0, total - limit)
        }
        let returned = min(limit, max(0, total - resolvedOffset))
        let hasMoreBefore = resolvedOffset > 0
        let hasMoreAfter = resolvedOffset + returned < total
        return ReviewLogPage(
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

package struct ReviewLogPage: Codable, Sendable, Hashable {
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
