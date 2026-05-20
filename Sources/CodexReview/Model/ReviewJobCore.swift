import Foundation

public struct ReviewRunMetadata: Codable, Sendable, Hashable {
    public var reviewThreadID: String?
    public var threadID: String?
    public var turnID: String?
    public var model: String?

    public init(
        reviewThreadID: String? = nil,
        threadID: String? = nil,
        turnID: String? = nil,
        model: String? = nil
    ) {
        self.reviewThreadID = reviewThreadID
        self.threadID = threadID
        self.turnID = turnID
        self.model = model
    }
}

public struct ReviewLifecycleState: Codable, Sendable, Hashable {
    public var status: ReviewJobState
    public var exitCode: Int?
    public var startedAt: Date?
    public var endedAt: Date?
    public var cancellation: ReviewCancellation?
    public var errorMessage: String?

    public init(
        status: ReviewJobState,
        exitCode: Int? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        cancellation: ReviewCancellation? = nil,
        errorMessage: String? = nil
    ) {
        self.status = status
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.cancellation = cancellation
        self.errorMessage = errorMessage
    }
}

public struct ReviewOutputState: Codable, Sendable, Hashable {
    public var summary: String
    public var hasFinalReview: Bool
    public var lastAgentMessage: String?
    public var reviewResult: ParsedReviewResult?

    public init(
        summary: String,
        hasFinalReview: Bool = false,
        lastAgentMessage: String? = nil,
        reviewResult: ParsedReviewResult? = nil
    ) {
        self.summary = summary
        self.hasFinalReview = hasFinalReview
        self.lastAgentMessage = lastAgentMessage
        self.reviewResult = reviewResult
    }
}

public struct ReviewJobCore: Codable, Sendable, Hashable {
    public var run: ReviewRunMetadata
    public var lifecycle: ReviewLifecycleState
    public var output: ReviewOutputState

    public init(
        run: ReviewRunMetadata = .init(),
        lifecycle: ReviewLifecycleState,
        output: ReviewOutputState
    ) {
        self.run = run
        self.lifecycle = lifecycle
        self.output = output
    }

    public var isTerminal: Bool {
        lifecycle.status.isTerminal
    }

    public var reviewText: String {
        if lifecycle.status == .cancelled {
            if output.hasFinalReview,
               let lastAgentMessage = output.lastAgentMessage?.nilIfEmpty
            {
                return lastAgentMessage
            }
            if let errorMessage = lifecycle.errorMessage?.nilIfEmpty {
                return errorMessage
            }
            return output.summary
        }
        if let lastAgentMessage = output.lastAgentMessage?.nilIfEmpty {
            return lastAgentMessage
        }
        if let errorMessage = lifecycle.errorMessage?.nilIfEmpty {
            return errorMessage
        }
        return output.summary
    }
}
