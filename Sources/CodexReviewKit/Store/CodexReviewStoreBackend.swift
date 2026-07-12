import Foundation

@MainActor
package struct CodexReviewStoreSeed {
    package var shouldAutoStartEmbeddedServer: Bool
    package var initialAccount: CodexReviewAccount?
    package var initialAccounts: [CodexReviewAccount]
    package var initialActiveAccountKey: String?
    package var initialSettingsSnapshot: CodexReviewSettings.Snapshot

    package init(
        shouldAutoStartEmbeddedServer: Bool = false,
        initialAccount: CodexReviewAccount? = nil,
        initialAccounts: [CodexReviewAccount] = [],
        initialActiveAccountKey: String? = nil,
        initialSettingsSnapshot: CodexReviewSettings.Snapshot = .init()
    ) {
        self.shouldAutoStartEmbeddedServer = shouldAutoStartEmbeddedServer
        self.initialAccount = initialAccount
        self.initialAccounts = initialAccounts
        self.initialActiveAccountKey = initialActiveAccountKey
        self.initialSettingsSnapshot = initialSettingsSnapshot
    }
}

@MainActor
package protocol CodexReviewStoreBackend: CodexReviewSettingsBackend {
    var seed: CodexReviewStoreSeed { get }
    var isActive: Bool { get }
    var invokesRuntimeStopReviewCleanupDuringStop: Bool { get }
    var reviewThreadRetentionCodexHomePath: String { get }
    var reviewThreadRetentionJournalURL: URL? { get }

    func attachStore(_ store: CodexReviewStore)
    func start(store: CodexReviewStore, forceRestartIfNeeded: Bool) async
    func stop(store: CodexReviewStore, purpose: CodexReviewRuntimeStopPurpose) async
    func waitUntilStopped() async
    func refreshAuth(auth: CodexReviewAuthModel) async
    func signIn(auth: CodexReviewAuthModel) async throws
    func addAccount(auth: CodexReviewAuthModel) async throws
    func cancelAuthentication(auth: CodexReviewAuthModel) async
    func switchAccount(auth: CodexReviewAuthModel, accountKey: String) async throws
    func removeAccount(auth: CodexReviewAuthModel, accountKey: String) async throws
    func reorderPersistedAccount(auth: CodexReviewAuthModel, accountKey: String, toIndex: Int) async throws
    func signOutActiveAccount(auth: CodexReviewAuthModel) async throws
    func refreshAccountRateLimits(auth: CodexReviewAuthModel, accountKey: String) async
    func requiresCurrentSessionRecovery(auth: CodexReviewAuthModel, accountKey: String) -> Bool

    func startReview(_ request: CodexReviewBackendModel.Review.Start) async throws -> BackendReviewAttempt
    func interruptReview(_ attempt: ReviewAttempt, reason: CodexReviewBackendModel.CancellationReason) async throws
    func prepareReviewRestart(_ attempt: ReviewAttempt) async throws -> CodexReviewBackendModel.Review.RestartToken
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

package enum CodexReviewRuntimeStopPurpose: Sendable {
    case runtimeRestartPreservingRuns
    case accountTransitionPreservingRuns
    case loginReconciliationPreservingRuns
    case finalStoreShutdownRetiringRuns

    package var retiresRuns: Bool {
        if case .finalStoreShutdownRetiringRuns = self {
            return true
        }
        return false
    }
}

package struct CodexReviewRuntimeStopReviewCleanupRequest: Sendable {
    package var reason: CodexReviewBackendModel.CancellationReason
    package var recoveryWaitingAttempts: [ReviewAttempt]

    package init(
        reason: CodexReviewBackendModel.CancellationReason,
        recoveryWaitingAttempts: [ReviewAttempt]
    ) {
        self.reason = reason
        self.recoveryWaitingAttempts = recoveryWaitingAttempts
    }
}

package struct CodexReviewRuntimeStopReviewCleanupResult: Sendable {
    package var didCompleteBackendCleanup: Bool
    package var didDrainReviewWorkers: Bool

    package var didComplete: Bool {
        didCompleteBackendCleanup && didDrainReviewWorkers
    }

    package init(
        didCompleteBackendCleanup: Bool,
        didDrainReviewWorkers: Bool
    ) {
        self.didCompleteBackendCleanup = didCompleteBackendCleanup
        self.didDrainReviewWorkers = didDrainReviewWorkers
    }
}

extension CodexReviewStoreBackend {
    package var invokesRuntimeStopReviewCleanupDuringStop: Bool {
        false
    }

    package var reviewThreadRetentionCodexHomePath: String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexReviewKit-volatile", isDirectory: true)
            .path
    }

    package var reviewThreadRetentionJournalURL: URL? {
        nil
    }
}
