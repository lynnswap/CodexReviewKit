import Foundation

package struct NonEmptyReviewOutput: Codable, Hashable, Sendable {
    package let rawValue: String

    package init(validating rawValue: String) throws {
        guard rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ReviewIdentityValidationError.empty(field: "finalReview")
        }
        self.rawValue = rawValue
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(validating: container.decode(String.self))
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

package struct ReviewCompletion: Equatable, Sendable {
    package let finalReview: NonEmptyReviewOutput

    package init(finalReview: NonEmptyReviewOutput) {
        self.finalReview = finalReview
    }
}

package struct ReviewCompletionCandidate: Equatable, Sendable {
    package let turnID: ReviewTurnID
    package let expectedOutput: NonEmptyReviewOutput

    package init(turnID: ReviewTurnID, expectedOutput: NonEmptyReviewOutput) {
        self.turnID = turnID
        self.expectedOutput = expectedOutput
    }
}

package enum ReviewBackendObservedTerminal: Equatable, Sendable {
    case completed(ReviewCompletionCandidate)
    case interrupted(message: String?)
    case failed(ReviewBackendFailure)
}

package enum ReviewBackendTerminal: Equatable, Sendable {
    case completed(ReviewCompletion)
    case interrupted(message: String?)
    case failed(ReviewBackendFailure)
}

package enum ReviewOutputPublicationFailure: Error, Codable, Hashable, Sendable {
    case refreshFailed(turnID: ReviewTurnID, message: String)
    case unavailable(turnID: ReviewTurnID)
    case empty(turnID: ReviewTurnID)
    case mismatched(turnID: ReviewTurnID)
}

package extension ReviewOutputPublicationFailure {
    var message: String {
        switch self {
        case .refreshFailed(_, let message):
            "Review output refresh failed: \(message)"
        case .unavailable:
            "Review output projection is unavailable."
        case .empty:
            "Review output projection is empty."
        case .mismatched:
            "Review output projection does not match the backend output."
        }
    }
}
