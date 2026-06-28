import Foundation

public struct ReviewRunCore: Codable, Sendable, Hashable {
    public struct Run: Codable, Sendable, Hashable {
        public internal(set) var attemptID: String?
        public internal(set) var reviewThreadID: String?
        public internal(set) var threadID: String?
        public internal(set) var turnID: String?
        public internal(set) var model: String?

        public init(
            attemptID: String? = nil,
            reviewThreadID: String? = nil,
            threadID: String? = nil,
            turnID: String? = nil,
            model: String? = nil
        ) {
            self.attemptID = attemptID
            self.reviewThreadID = reviewThreadID
            self.threadID = threadID
            self.turnID = turnID
            self.model = model
        }
    }

    public struct Lifecycle: Codable, Sendable, Hashable {
        public internal(set) var status: ReviewRunState
        public internal(set) var exitCode: Int?
        public internal(set) var startedAt: Date?
        public internal(set) var endedAt: Date?
        public internal(set) var cancellation: ReviewCancellation?
        public internal(set) var errorMessage: String?

        public init(
            status: ReviewRunState,
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

    public struct Output: Codable, Sendable, Hashable {
        public internal(set) var summary: String

        public init(summary: String) {
            self.summary = summary
        }
    }

    public internal(set) var run: Run
    public internal(set) var lifecycle: Lifecycle
    public internal(set) var output: Output

    public init(
        run: Run = .init(),
        lifecycle: Lifecycle,
        output: Output
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
            if let errorMessage = lifecycle.errorMessage?.nilIfEmpty {
                return errorMessage
            }
            return output.summary
        }
        if let errorMessage = lifecycle.errorMessage?.nilIfEmpty {
            return errorMessage
        }
        return output.summary
    }
}
