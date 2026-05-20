import Foundation

package protocol CodexReviewBackend: Sendable {
    func readSettings() async throws -> BackendSettingsSnapshot
    func applySettings(_ change: BackendSettingsChange) async throws -> BackendSettingsSnapshot

    func readAuth() async throws -> BackendAuthSnapshot
    func startLogin(_ request: BackendLoginRequest) async throws -> BackendLoginChallenge
    func cancelLogin(_ challenge: BackendLoginChallenge) async throws
    func completeLogin(_ response: BackendLoginResponse) async throws -> BackendAuthSnapshot
    func logout(_ account: BackendAccountID) async throws -> BackendAuthSnapshot

    func startReview(_ request: BackendReviewStart) async throws -> BackendReviewRun
    func interruptReview(_ run: BackendReviewRun, reason: BackendCancellationReason) async throws
    func cleanupReview(_ run: BackendReviewRun) async
    func events(for run: BackendReviewRun) async -> AsyncThrowingStream<BackendReviewEvent, Error>
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
