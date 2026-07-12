import Foundation

package protocol CodexReviewBackend: Sendable {
    func readSettings() async throws -> CodexReviewBackendModel.Settings.Snapshot
    func applySettings(_ change: CodexReviewBackendModel.Settings.Change) async throws
        -> CodexReviewBackendModel.Settings.Snapshot

    func readAuth() async throws -> CodexReviewBackendModel.Auth.Snapshot
    func logout(_ account: CodexReviewBackendModel.Account.ID) async throws -> CodexReviewBackendModel.Auth.Snapshot

    func startReview(_ request: CodexReviewBackendModel.Review.Start) async throws -> BackendReviewAttempt
    func interruptReview(_ attempt: ReviewAttempt, reason: CodexReviewBackendModel.CancellationReason)
        async throws
    func prepareReviewRestart(_ attempt: ReviewAttempt) async throws
        -> CodexReviewBackendModel.Review.RestartToken
    func restartPreparedReview(
        _ token: CodexReviewBackendModel.Review.RestartToken,
        request: CodexReviewBackendModel.Review.Start
    ) async throws -> BackendReviewAttempt
    func discardPreparedReviewRestart(
        _ token: CodexReviewBackendModel.Review.RestartToken
    ) async -> [ReviewAttempt]
    func cleanupReview(_ attempt: ReviewAttempt) async
    func cleanupRetainedReviews(
        _ attempts: [ReviewAttempt],
        additionalThreadIDs: [ReviewThreadID]
    ) async -> ReviewRetainedThreadCleanupResult
}

package struct ReviewRetainedThreadCleanupFailure: Codable, Equatable, Sendable {
    package let threadID: ReviewThreadID
    package let message: String

    package init(threadID: ReviewThreadID, message: String) {
        self.threadID = threadID
        self.message = message
    }
}

package struct ReviewRetainedThreadCleanupResult: Codable, Equatable, Sendable {
    package let failures: [ReviewRetainedThreadCleanupFailure]

    package init(failures: [ReviewRetainedThreadCleanupFailure] = []) {
        self.failures = failures
    }

    package var succeeded: Bool {
        failures.isEmpty
    }

    package var failureMessage: String? {
        guard failures.isEmpty == false else {
            return nil
        }
        return failures
            .map { "\($0.threadID.rawValue): \($0.message)" }
            .joined(separator: "; ")
    }
}

package struct BackendReviewAttempt: Sendable {
    package let attempt: ReviewAttempt
    package let observeTerminal: @Sendable () async throws -> ReviewBackendObservedTerminal
    package let observedTerminalIfKnown: @Sendable () async -> ReviewBackendObservedTerminal?
    package let finalizeTerminal: @Sendable (ReviewBackendObservedTerminal) async -> ReviewBackendTerminal

    package init(
        attempt: ReviewAttempt,
        observeTerminal: @escaping @Sendable () async throws -> ReviewBackendObservedTerminal,
        observedTerminalIfKnown: @escaping @Sendable () async -> ReviewBackendObservedTerminal?,
        finalizeTerminal: @escaping @Sendable (ReviewBackendObservedTerminal) async -> ReviewBackendTerminal
    ) {
        self.attempt = attempt
        self.observeTerminal = observeTerminal
        self.observedTerminalIfKnown = observedTerminalIfKnown
        self.finalizeTerminal = finalizeTerminal
    }
}

package struct CodexReviewClock: Sendable {
    package var now: @Sendable () -> Date

    package init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }
}

package struct CodexReviewIDGenerator: Sendable {
    package var next: @Sendable () -> String

    package init(next: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.next = next
    }
}
