import Foundation

package enum ReviewIdentityValidationError: Error, Equatable, Sendable {
    case empty(field: String)
}

package struct ReviewRunID: Codable, Hashable, Sendable {
    package let rawValue: String

    package init(validating rawValue: String) throws {
        self.rawValue = try validatedReviewIdentity(rawValue, field: "runID")
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

package struct ReviewAttemptID: Codable, Hashable, Sendable {
    package let rawValue: String

    package init(validating rawValue: String) throws {
        self.rawValue = try validatedReviewIdentity(rawValue, field: "attemptID")
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

package struct ReviewThreadID: Codable, Hashable, Sendable {
    package let rawValue: String

    package init(validating rawValue: String) throws {
        self.rawValue = try validatedReviewIdentity(rawValue, field: "threadID")
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

package struct ReviewTurnID: Codable, Hashable, Sendable {
    package let rawValue: String

    package init(validating rawValue: String) throws {
        self.rawValue = try validatedReviewIdentity(rawValue, field: "turnID")
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

package struct ReviewThreadIdentity: Codable, Hashable, Sendable {
    package let sourceThreadID: ReviewThreadID
    package let activeTurnThreadID: ReviewThreadID

    package init(
        sourceThreadID: ReviewThreadID,
        activeTurnThreadID: ReviewThreadID
    ) {
        self.sourceThreadID = sourceThreadID
        self.activeTurnThreadID = activeTurnThreadID
    }
}

package struct ReviewAttempt: Codable, Hashable, Sendable {
    package let attemptID: ReviewAttemptID
    package let threadIdentity: ReviewThreadIdentity
    package let turnID: ReviewTurnID
    package let model: String?

    package init(
        attemptID: ReviewAttemptID,
        threadIdentity: ReviewThreadIdentity,
        turnID: ReviewTurnID,
        model: String?
    ) {
        self.attemptID = attemptID
        self.threadIdentity = threadIdentity
        self.turnID = turnID
        self.model = model
    }

    package init(
        validatingAttemptID attemptID: String,
        sourceThreadID: String,
        activeTurnThreadID: String,
        turnID: String,
        model: String? = nil
    ) throws {
        self.init(
            attemptID: try ReviewAttemptID(validating: attemptID),
            threadIdentity: .init(
                sourceThreadID: try ReviewThreadID(validating: sourceThreadID),
                activeTurnThreadID: try ReviewThreadID(validating: activeTurnThreadID)
            ),
            turnID: try ReviewTurnID(validating: turnID),
            model: model
        )
    }
}

private func validatedReviewIdentity(_ rawValue: String, field: String) throws -> String {
    guard rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        throw ReviewIdentityValidationError.empty(field: field)
    }
    return rawValue
}
