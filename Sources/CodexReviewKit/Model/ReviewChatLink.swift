import Foundation

public struct ReviewChatLink: Codable, Sendable, Hashable {
    public let jobID: String
    public let sessionID: String
    public let cwd: String
    public let attemptID: String?
    public let sourceThreadID: String
    public let activeChatThreadID: String
    public let reviewThreadID: String?
    public let turnID: String
    public let model: String?

    private enum CodingKeys: String, CodingKey {
        case jobID
        case sessionID
        case cwd
        case attemptID
        case sourceThreadID
        case activeChatThreadID
        case reviewThreadID
        case turnID
        case model
    }

    public init?(
        jobID: String,
        sessionID: String,
        cwd: String,
        attemptID: String? = nil,
        sourceThreadID: String?,
        reviewThreadID: String? = nil,
        turnID: String?,
        model: String? = nil
    ) {
        guard let sourceThreadID = Self.normalize(sourceThreadID),
            let turnID = Self.normalize(turnID)
        else {
            return nil
        }
        let reviewThreadID = Self.normalize(reviewThreadID)

        self.jobID = jobID
        self.sessionID = sessionID
        self.cwd = cwd
        self.attemptID = Self.normalize(attemptID)
        self.sourceThreadID = sourceThreadID
        self.activeChatThreadID = reviewThreadID ?? sourceThreadID
        self.reviewThreadID = reviewThreadID
        self.turnID = turnID
        self.model = Self.normalize(model)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let jobID = try container.decode(String.self, forKey: .jobID)
        let sessionID = try container.decode(String.self, forKey: .sessionID)
        let cwd = try container.decode(String.self, forKey: .cwd)
        let attemptID = try container.decodeIfPresent(String.self, forKey: .attemptID)
        let sourceThreadID = try container.decode(String.self, forKey: .sourceThreadID)
        let reviewThreadID = try container.decodeIfPresent(String.self, forKey: .reviewThreadID)
        let turnID = try container.decode(String.self, forKey: .turnID)
        let model = try container.decodeIfPresent(String.self, forKey: .model)

        guard
            let link = Self(
                jobID: jobID,
                sessionID: sessionID,
                cwd: cwd,
                attemptID: attemptID,
                sourceThreadID: sourceThreadID,
                reviewThreadID: reviewThreadID,
                turnID: turnID,
                model: model
            )
        else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "ReviewChatLink requires non-empty sourceThreadID and turnID."
                ))
        }

        self = link
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jobID, forKey: .jobID)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(cwd, forKey: .cwd)
        try container.encodeIfPresent(attemptID, forKey: .attemptID)
        try container.encode(sourceThreadID, forKey: .sourceThreadID)
        try container.encode(activeChatThreadID, forKey: .activeChatThreadID)
        try container.encodeIfPresent(reviewThreadID, forKey: .reviewThreadID)
        try container.encode(turnID, forKey: .turnID)
        try container.encodeIfPresent(model, forKey: .model)
    }

    private static func normalize(_ value: String?) -> String? {
        value.flatMap(\.nilIfEmpty)
    }
}

public extension CodexReviewJob {
    var reviewChatLink: ReviewChatLink? {
        ReviewChatLink(
            jobID: id,
            sessionID: sessionID,
            cwd: cwd,
            attemptID: core.run.attemptID,
            sourceThreadID: core.run.threadID,
            reviewThreadID: core.run.reviewThreadID,
            turnID: core.run.turnID,
            model: core.run.model
        )
    }
}
