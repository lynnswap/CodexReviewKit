import Foundation

@MainActor
package struct CodexReviewStoreSeed {
    package var shouldAutoStartEmbeddedServer: Bool
    package var initialAccount: CodexAccount?
    package var initialAccounts: [CodexAccount]
    package var initialActiveAccountKey: String?
    package var initialSettingsSnapshot: CodexReviewSettingsSnapshot

    package init(
        shouldAutoStartEmbeddedServer: Bool = false,
        initialAccount: CodexAccount? = nil,
        initialAccounts: [CodexAccount] = [],
        initialActiveAccountKey: String? = nil,
        initialSettingsSnapshot: CodexReviewSettingsSnapshot = .init()
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
    var handlesActiveReviewStopCleanup: Bool { get }

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

    func startReview(_ request: BackendReviewStart) async throws -> BackendReviewRun
    func interruptReview(_ run: BackendReviewRun, reason: BackendCancellationReason) async throws
    func beginReviewRecovery(
        _ run: BackendReviewRun,
        reason: BackendCancellationReason
    ) async throws -> BackendReviewRecoveryToken
    func resumeReviewRecovery(
        _ token: BackendReviewRecoveryToken,
        request: BackendReviewStart
    ) async throws -> BackendReviewRun
    func cleanupReview(_ run: BackendReviewRun) async
    func events(for run: BackendReviewRun) async -> AsyncThrowingStream<BackendReviewEvent, Error>
}

extension CodexReviewStoreBackend {
    package var handlesActiveReviewStopCleanup: Bool {
        false
    }
}
