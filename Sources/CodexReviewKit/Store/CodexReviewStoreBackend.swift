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

    func attachStore(_ store: CodexReviewStore)
    func start(store: CodexReviewStore, forceRestartIfNeeded: Bool) async
    func stop(store: CodexReviewStore) async
    func waitUntilStopped() async
    func refreshAuth(auth: CodexReviewAuthModel) async
    func signIn(auth: CodexReviewAuthModel) async
    func addAccount(auth: CodexReviewAuthModel) async
    func cancelAuthentication(auth: CodexReviewAuthModel) async
    func switchAccount(auth: CodexReviewAuthModel, accountKey: String) async throws
    func removeAccount(auth: CodexReviewAuthModel, accountKey: String) async throws
    func reorderPersistedAccount(auth: CodexReviewAuthModel, accountKey: String, toIndex: Int) async throws
    func signOutActiveAccount(auth: CodexReviewAuthModel) async throws
    func refreshAccountRateLimits(auth: CodexReviewAuthModel, accountKey: String) async
    func requiresCurrentSessionRecovery(auth: CodexReviewAuthModel, accountKey: String) -> Bool

    func startReview(_ request: CodexReviewBackendModel.Review.Start) async throws -> BackendReviewAttempt
    func interruptReview(_ run: CodexReviewBackendModel.Review.Run, reason: CodexReviewBackendModel.CancellationReason) async throws
    func prepareReviewRestart(_ run: CodexReviewBackendModel.Review.Run) async throws -> CodexReviewBackendModel.Review.RestartToken
    func restartPreparedReview(
        _ token: CodexReviewBackendModel.Review.RestartToken,
        request: CodexReviewBackendModel.Review.Start
    ) async throws -> BackendReviewAttempt
    func cleanupReview(_ run: CodexReviewBackendModel.Review.Run) async
}

package struct CodexReviewRuntimeStopReviewCleanupRequest: Sendable {
    package var reason: CodexReviewBackendModel.CancellationReason
    package var recoveryWaitingRuns: [CodexReviewBackendModel.Review.Run]

    package init(
        reason: CodexReviewBackendModel.CancellationReason,
        recoveryWaitingRuns: [CodexReviewBackendModel.Review.Run]
    ) {
        self.reason = reason
        self.recoveryWaitingRuns = recoveryWaitingRuns
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
}
