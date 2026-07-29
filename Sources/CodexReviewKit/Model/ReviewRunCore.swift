import Foundation

package enum ReviewRunCore: Codable, Sendable, Hashable {
    case queued
    case startFailed(
        endedAt: Date,
        failure: ReviewBackendFailure
    )
    case cancelledBeforeStart(
        endedAt: Date,
        cancellation: ReviewCancellation
    )
    case running(
        attempt: ReviewAttempt,
        startedAt: Date
    )
    case succeeded(
        attempt: ReviewAttempt,
        startedAt: Date,
        endedAt: Date
    )
    case failed(
        attempt: ReviewAttempt,
        startedAt: Date,
        endedAt: Date,
        failure: ReviewBackendFailure
    )
    case cancelled(
        attempt: ReviewAttempt,
        startedAt: Date,
        endedAt: Date,
        cancellation: ReviewCancellation
    )

    package var status: ReviewRunState {
        switch self {
        case .queued:
            .queued
        case .startFailed, .failed:
            .failed
        case .cancelledBeforeStart, .cancelled:
            .cancelled
        case .running:
            .running
        case .succeeded:
            .succeeded
        }
    }

    package var attempt: ReviewAttempt? {
        switch self {
        case .queued, .startFailed, .cancelledBeforeStart:
            nil
        case .running(let attempt, _),
            .succeeded(let attempt, _, _),
            .failed(let attempt, _, _, _),
            .cancelled(let attempt, _, _, _):
            attempt
        }
    }

    package var startedAt: Date? {
        switch self {
        case .queued, .startFailed, .cancelledBeforeStart:
            nil
        case .running(_, let startedAt),
            .succeeded(_, let startedAt, _),
            .failed(_, let startedAt, _, _),
            .cancelled(_, let startedAt, _, _):
            startedAt
        }
    }

    package var endedAt: Date? {
        switch self {
        case .queued, .running:
            nil
        case .startFailed(let endedAt, _),
            .cancelledBeforeStart(let endedAt, _),
            .succeeded(_, _, let endedAt),
            .failed(_, _, let endedAt, _),
            .cancelled(_, _, let endedAt, _):
            endedAt
        }
    }

    package var failure: ReviewBackendFailure? {
        switch self {
        case .startFailed(_, let failure), .failed(_, _, _, let failure):
            failure
        case .queued, .cancelledBeforeStart, .running, .succeeded, .cancelled:
            nil
        }
    }

    package var cancellation: ReviewCancellation? {
        switch self {
        case .cancelledBeforeStart(_, let cancellation), .cancelled(_, _, _, let cancellation):
            cancellation
        case .queued, .startFailed, .running, .succeeded, .failed:
            nil
        }
    }

    package var isTerminal: Bool {
        status.isTerminal
    }
}
