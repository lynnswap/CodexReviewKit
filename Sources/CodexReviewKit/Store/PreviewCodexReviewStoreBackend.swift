import Foundation

@MainActor
package class PreviewCodexReviewStoreBackend: CodexReviewStoreBackend {
    package let seed: CodexReviewStoreSeed
    package var isActive = false
    package var currentSettingsSnapshot: CodexReviewSettings.Snapshot

    package init(seed: CodexReviewStoreSeed = .init()) {
        self.seed = seed
        currentSettingsSnapshot = seed.initialSettingsSnapshot
    }

    package var initialSettingsSnapshot: CodexReviewSettings.Snapshot {
        currentSettingsSnapshot
    }

    package func attachStore(_: CodexReviewStore) {}

    package func start(store: CodexReviewStore, forceRestartIfNeeded _: Bool) async {
        isActive = true
        store.transitionToFailed(Self.previewUnavailableMessage)
    }

    package func stop(store _: CodexReviewStore) async {
        isActive = false
    }

    package func waitUntilStopped() async {}

    package func refreshSettings() async throws -> CodexReviewSettings.Snapshot {
        currentSettingsSnapshot
    }

    package func updateSettingsModel(
        _ model: String?,
        reasoningEffort: CodexReviewSettings.ReasoningEffort?,
        persistReasoningEffort: Bool,
        serviceTier: CodexReviewSettings.ServiceTier?,
        persistServiceTier: Bool
    ) async throws {
        currentSettingsSnapshot.model = model
        if persistReasoningEffort {
            currentSettingsSnapshot.reasoningEffort = reasoningEffort
        }
        if persistServiceTier {
            currentSettingsSnapshot.serviceTier = serviceTier
        }
    }

    package func updateSettingsReasoningEffort(
        _ reasoningEffort: CodexReviewSettings.ReasoningEffort?
    ) async throws {
        currentSettingsSnapshot.reasoningEffort = reasoningEffort
    }

    package func updateSettingsServiceTier(
        _ serviceTier: CodexReviewSettings.ServiceTier?
    ) async throws {
        currentSettingsSnapshot.serviceTier = serviceTier
    }

    package func refreshAuth(auth: CodexReviewAuthModel) async {
        if auth.selectedAccount == nil {
            auth.updatePhase(.signedOut)
        }
    }

    package func signIn(auth: CodexReviewAuthModel) async {
        auth.updatePhase(.failed(message: Self.previewAuthenticationFailureMessage))
    }

    package func addAccount(auth: CodexReviewAuthModel) async {
        auth.updatePhase(.failed(message: Self.previewAuthenticationFailureMessage))
    }

    package func cancelAuthentication(auth: CodexReviewAuthModel) async {
        if auth.selectedAccount == nil {
            auth.updatePhase(.signedOut)
        }
    }

    package func switchAccount(auth: CodexReviewAuthModel, accountKey: String) async throws {
        guard auth.persistedAccounts.contains(where: { $0.accountKey == accountKey }) else {
            return
        }
        auth.applyPersistedAccountStates(
            auth.persistedAccounts.map(savedAccountPayload(from:)),
            activeAccountKey: accountKey
        )
        auth.selectPersistedAccount(
            auth.persistedAccounts.first(where: { $0.accountKey == accountKey })?.id
        )
        auth.updatePhase(.signedOut)
    }

    package func removeAccount(auth: CodexReviewAuthModel, accountKey: String) async throws {
        let filteredAccounts = auth.persistedAccounts.filter { $0.accountKey != accountKey }
        auth.applyPersistedAccountStates(filteredAccounts.map(savedAccountPayload(from:)))
        if auth.selectedAccount?.accountKey == accountKey {
            auth.selectPersistedAccount(nil)
            auth.updatePhase(.signedOut)
        }
    }

    package func reorderPersistedAccount(
        auth: CodexReviewAuthModel,
        accountKey: String,
        toIndex: Int
    ) async throws {
        var reorderedAccounts = auth.persistedAccounts
        guard let sourceIndex = reorderedAccounts.firstIndex(where: { $0.accountKey == accountKey }) else {
            return
        }
        let destinationIndex = max(0, min(toIndex, reorderedAccounts.count - 1))
        guard sourceIndex != destinationIndex else {
            return
        }
        let account = reorderedAccounts.remove(at: sourceIndex)
        reorderedAccounts.insert(account, at: destinationIndex)
        auth.applyPersistedAccountStates(reorderedAccounts.map(savedAccountPayload(from:)))
    }

    package func signOutActiveAccount(auth: CodexReviewAuthModel) async throws {
        auth.updatePhase(.signedOut)
        auth.selectPersistedAccount(nil)
        auth.applyPersistedAccountStates([])
    }

    package func refreshAccountRateLimits(auth _: CodexReviewAuthModel, accountKey _: String) async {}

    package func requiresCurrentSessionRecovery(auth _: CodexReviewAuthModel, accountKey _: String) -> Bool {
        false
    }

    package func startReview(_: CodexReviewBackendModel.Review.Start) async throws -> BackendReviewAttempt {
        throw CodexReviewAPI.Error.io(Self.previewUnavailableMessage)
    }

    package func interruptReview(_: CodexReviewBackendModel.Review.Run, reason _: CodexReviewBackendModel.CancellationReason) async throws {}

    package func prepareReviewRestart(_: CodexReviewBackendModel.Review.Run) async throws -> CodexReviewBackendModel.Review.RestartToken {
        throw CodexReviewAPI.Error.io(Self.previewUnavailableMessage)
    }

    package func restartPreparedReview(
        _: CodexReviewBackendModel.Review.RestartToken,
        request _: CodexReviewBackendModel.Review.Start
    ) async throws -> BackendReviewAttempt {
        throw CodexReviewAPI.Error.io(Self.previewUnavailableMessage)
    }

    package func cleanupReview(_: CodexReviewBackendModel.Review.Run) async {}

    fileprivate static let previewUnavailableMessage = "Embedded server is unavailable in preview mode."
    fileprivate static let previewAuthenticationFailureMessage = "Authentication is unavailable in preview mode."
}
