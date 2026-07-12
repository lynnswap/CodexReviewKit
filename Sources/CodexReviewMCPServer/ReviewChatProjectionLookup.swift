import Foundation
import CodexDataKit
import CodexReviewKit

package enum ReviewChatProjectionLookup: Sendable, Equatable {
    case available(ReviewMCPLogProjection)
    case unavailable
    case refreshFailed(CodexFetchFailure)
}

package enum ReviewMCPError: Error, Sendable, Equatable {
    case projectionInvariantViolation(runID: ReviewRunID)
    case projectionRefreshFailed(runID: ReviewRunID, failure: CodexFetchFailure)
}

extension ReviewMCPError: LocalizedError {
    package var errorDescription: String? {
        switch self {
        case .projectionInvariantViolation(let runID):
            "Review output projection invariant failed for run \(runID.rawValue)."
        case .projectionRefreshFailed(let runID, let failure):
            "Review output projection refresh failed for run \(runID.rawValue): \(failure.localizedDescription)"
        }
    }
}
