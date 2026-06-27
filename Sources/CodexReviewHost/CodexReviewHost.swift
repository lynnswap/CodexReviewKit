import Foundation
import CodexReviewKit
import CodexReviewMCPServer

@MainActor
package final class CodexReviewHost {
    package let store: CodexReviewStore
    package let mcpServer: CodexReviewMCPServer
    private let shutdown: @Sendable () async -> Void
    private var endpoint: URL?

    package init(
        backend: any CodexReviewBackend,
        clock: CodexReviewClock = .init(),
        idGenerator: CodexReviewIDGenerator = .init(),
        endpoint: URL? = nil,
        shutdown: @escaping @Sendable () async -> Void = {}
    ) {
        self.shutdown = shutdown
        self.endpoint = endpoint
        let store = CodexReviewStore(
            backend: DirectCodexReviewStoreBackend(backend: backend),
            clock: clock,
            idGenerator: idGenerator
        )
        self.store = store
        self.mcpServer = CodexReviewMCPServer(store: store)
    }

    package func start(endpoint: URL? = nil) async {
        if let endpoint {
            self.endpoint = endpoint
        }
        store.transitionToRunning(serverURL: self.endpoint)
        await store.refreshSettings()
    }

    package func stop() async {
        await store.stop()
        await shutdown()
    }
}

@MainActor
private final class DirectCodexReviewStoreBackend: CodexReviewStoreBackend {
    let seed = CodexReviewStoreSeed()
    private let backend: any CodexReviewBackend
    private var currentSettingsSnapshot = CodexReviewSettings.Snapshot()
    private var loginChallenge: CodexReviewBackendModel.Login.Challenge?
    private var active = false

    var isActive: Bool {
        active
    }

    var initialSettingsSnapshot: CodexReviewSettings.Snapshot {
        currentSettingsSnapshot
    }

    init(backend: any CodexReviewBackend) {
        self.backend = backend
    }

    func attachStore(_: CodexReviewStore) {}

    func start(store _: CodexReviewStore, forceRestartIfNeeded _: Bool) async {
        active = true
    }

    func stop(store _: CodexReviewStore) async {
        active = false
    }

    func waitUntilStopped() async {}

    func refreshSettings() async throws -> CodexReviewSettings.Snapshot {
        currentSettingsSnapshot = try await Self.monitorSettings(from: backend.readSettings())
        return currentSettingsSnapshot
    }

    func updateSettingsModel(
        _ model: String?,
        reasoningEffort: CodexReviewSettings.ReasoningEffort?,
        persistReasoningEffort: Bool,
        serviceTier: CodexReviewSettings.ServiceTier?,
        persistServiceTier: Bool
    ) async throws {
        var change = CodexReviewBackendModel.Settings.Change(
            model: model,
            updatesModel: true
        )
        if persistReasoningEffort {
            change.reasoningEffort = reasoningEffort?.rawValue
            change.updatesReasoningEffort = true
        }
        if persistServiceTier {
            change.serviceTier = serviceTier?.rawValue
            change.updatesServiceTier = true
        }
        currentSettingsSnapshot = try await Self.monitorSettings(from: backend.applySettings(change))
    }

    func updateSettingsReasoningEffort(
        _ reasoningEffort: CodexReviewSettings.ReasoningEffort?
    ) async throws {
        currentSettingsSnapshot = try await Self.monitorSettings(
            from: backend.applySettings(.init(
                reasoningEffort: reasoningEffort?.rawValue,
                updatesReasoningEffort: true
            ))
        )
    }

    func updateSettingsServiceTier(
        _ serviceTier: CodexReviewSettings.ServiceTier?
    ) async throws {
        currentSettingsSnapshot = try await Self.monitorSettings(
            from: backend.applySettings(.init(
                serviceTier: serviceTier?.rawValue,
                updatesServiceTier: true
            ))
        )
    }

    func refreshAuth(auth: CodexReviewAuthModel) async {
        do {
            Self.applyAuthSnapshot(try await backend.readAuth(), to: auth)
        } catch {
            auth.updatePhase(.failed(message: error.localizedDescription))
        }
    }

    func signIn(auth: CodexReviewAuthModel) async {
        do {
            let challenge = try await backend.startLogin(.init())
            loginChallenge = challenge
            auth.updatePhase(.signingIn(.init(
                title: "Sign in to Codex",
                detail: challenge.signInDetail(nativeAuthentication: false),
                browserURL: challenge.verificationURL?.absoluteString,
                userCode: challenge.userCode
            )))
        } catch {
            auth.updatePhase(.failed(message: error.localizedDescription))
        }
    }

    func addAccount(auth: CodexReviewAuthModel) async {
        await signIn(auth: auth)
    }

    func cancelAuthentication(auth: CodexReviewAuthModel) async {
        defer { loginChallenge = nil }
        guard let loginChallenge else {
            auth.updatePhase(auth.selectedAccount == nil ? .signedOut : .signedOut)
            return
        }
        do {
            try await backend.cancelLogin(loginChallenge)
            auth.updatePhase(auth.selectedAccount == nil ? .signedOut : .signedOut)
        } catch {
            auth.updatePhase(.failed(message: error.localizedDescription))
        }
    }

    func switchAccount(auth: CodexReviewAuthModel, accountKey: String) async throws {
        guard auth.persistedAccounts.contains(where: { $0.accountKey == accountKey }) else {
            return
        }
        auth.applyPersistedAccountStates(
            auth.persistedAccounts.map(savedAccountPayload(from:)),
            activeAccountKey: accountKey
        )
        auth.selectPersistedAccount(auth.persistedAccounts.first(where: { $0.accountKey == accountKey })?.id)
        auth.updatePhase(.signedOut)
    }

    func removeAccount(auth: CodexReviewAuthModel, accountKey: String) async throws {
        let remaining = auth.persistedAccounts.filter { $0.accountKey != accountKey }
        auth.applyPersistedAccountStates(remaining.map(savedAccountPayload(from:)))
        if auth.selectedAccount?.accountKey == accountKey {
            auth.selectPersistedAccount(nil)
            auth.updatePhase(.signedOut)
        }
    }

    func reorderPersistedAccount(
        auth: CodexReviewAuthModel,
        accountKey: String,
        toIndex: Int
    ) async throws {
        var accounts = auth.persistedAccounts
        guard let sourceIndex = accounts.firstIndex(where: { $0.accountKey == accountKey }) else {
            return
        }
        let destinationIndex = max(0, min(toIndex, accounts.count - 1))
        guard sourceIndex != destinationIndex else {
            return
        }
        let account = accounts.remove(at: sourceIndex)
        accounts.insert(account, at: destinationIndex)
        auth.applyPersistedAccountStates(accounts.map(savedAccountPayload(from:)))
    }

    func signOutActiveAccount(auth: CodexReviewAuthModel) async throws {
        if let account = auth.selectedAccount {
            _ = try await backend.logout(.init(account.accountKey))
        }
        auth.updatePhase(.signedOut)
        auth.selectPersistedAccount(nil)
        auth.applyPersistedAccountStates([])
    }

    func refreshAccountRateLimits(auth _: CodexReviewAuthModel, accountKey _: String) async {}

    func requiresCurrentSessionRecovery(auth _: CodexReviewAuthModel, accountKey _: String) -> Bool {
        false
    }

    func startReview(_ request: CodexReviewBackendModel.Review.Start) async throws -> BackendReviewAttempt {
        try await backend.startReview(request)
    }

    func interruptReview(
        _ run: CodexReviewBackendModel.Review.Run,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws {
        try await backend.interruptReview(run, reason: reason)
    }

    func prepareReviewRestart(_ run: CodexReviewBackendModel.Review.Run) async throws -> CodexReviewBackendModel.Review.RestartToken {
        try await backend.prepareReviewRestart(run)
    }

    func restartPreparedReview(
        _ token: CodexReviewBackendModel.Review.RestartToken,
        request: CodexReviewBackendModel.Review.Start
    ) async throws -> BackendReviewAttempt {
        try await backend.restartPreparedReview(token, request: request)
    }

    func cleanupReview(_ run: CodexReviewBackendModel.Review.Run) async {
        await backend.cleanupReview(run)
    }

    private static func monitorSettings(
        from snapshot: CodexReviewBackendModel.Settings.Snapshot
    ) -> CodexReviewSettings.Snapshot {
        .init(
            model: snapshot.model,
            fallbackModel: snapshot.fallbackModel,
            reasoningEffort: snapshot.reasoningEffort.flatMap(CodexReviewSettings.ReasoningEffort.init(rawValue:)),
            serviceTier: snapshot.serviceTier.flatMap(CodexReviewSettings.ServiceTier.init(rawValue:)),
            models: snapshot.models
        )
    }

    private static func applyAuthSnapshot(
        _ snapshot: CodexReviewBackendModel.Auth.Snapshot,
        to auth: CodexReviewAuthModel
    ) {
        let accounts = snapshot.accounts.compactMap { account -> CodexReviewAccount? in
            let label = account.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let accountKey = CodexReviewAccount.normalizedEmail(account.id.rawValue)
            guard label.isEmpty == false, accountKey.isEmpty == false else {
                return nil
            }
            return CodexReviewAccount(
                accountKey: accountKey,
                email: label,
                planType: account.planType,
                kind: account.kind,
                capabilities: account.capabilities
            )
        }
        let activeAccountKey = snapshot.activeAccountID
            .map { CodexReviewAccount.normalizedEmail($0.rawValue) }
        auth.applyPersistedAccountStates(
            accounts.map(savedAccountPayload(from:)),
            activeAccountKey: activeAccountKey
        )
        if let activeAccountKey,
           let account = accounts.first(where: { $0.accountKey == activeAccountKey })
        {
            auth.selectPersistedAccount(account.id)
            auth.updatePhase(.signedOut)
        } else {
            auth.selectPersistedAccount(nil)
            auth.updatePhase(.signedOut)
        }
    }
}

extension CodexReviewBackendModel.Login.Challenge {
    func signInDetail(nativeAuthentication: Bool) -> String {
        if let userCode = userCode?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return "Enter code \(userCode) in your browser, then return to ReviewMonitor."
        }
        return nativeAuthentication
            ? "Complete sign in in the authentication window."
            : "Complete sign in in your browser, then return to ReviewMonitor."
    }
}
