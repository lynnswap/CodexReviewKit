import Foundation

package struct ReviewRunCore: Codable, Sendable, Hashable {
    package struct Run: Codable, Sendable, Hashable {
        package var attemptID: String?
        package var reviewThreadID: String?
        package var threadID: String?
        package var turnID: String?
        package var model: String?

        package init(
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

    package struct Lifecycle: Codable, Sendable, Hashable {
        package var status: ReviewRunState
        package var exitCode: Int?
        package var startedAt: Date?
        package var endedAt: Date?
        package var cancellation: ReviewCancellation?
        package var errorMessage: String?

        package init(
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

    package var run: Run
    package var lifecycle: Lifecycle
    package var summary: String

    package init(
        run: Run = .init(),
        lifecycle: Lifecycle,
        summary: String
    ) {
        self.run = run
        self.lifecycle = lifecycle
        self.summary = summary
    }

    package var isTerminal: Bool {
        lifecycle.status.isTerminal
    }
}
