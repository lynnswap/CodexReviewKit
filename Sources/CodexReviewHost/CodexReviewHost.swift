import Foundation
import CodexReview
import CodexReviewAppServer
import CodexReviewMCPServer

@MainActor
package final class CodexReviewHost {
    package let store: CodexReviewStore
    package let mcpServer: CodexReviewMCPServer
    private let directBackend: DirectCodexReviewStoreBackend
    private let shutdown: @Sendable () async throws -> Void
    private var endpoint: URL?

    package init(
        backend: any CodexReviewBackend,
        clock: CodexReviewClock = .init(),
        idGenerator: CodexReviewIDGenerator = .init(),
        endpoint: URL? = nil,
        shutdown: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.endpoint = endpoint
        let directBackend = DirectCodexReviewStoreBackend(
            backend: backend,
            endpoint: endpoint
        )
        self.directBackend = directBackend
        self.shutdown = shutdown
        let store = CodexReviewStore(
            backend: directBackend,
            clock: clock,
            idGenerator: idGenerator
        )
        self.store = store
        self.mcpServer = CodexReviewMCPServer(store: store)
    }

    package convenience init(
        appServerTransport: any JSONRPC.Transport,
        endpoint: URL? = nil
    ) {
        let client = AppServerClient(transport: appServerTransport)
        let backend = AppServerCodexReviewBackend(client: client)
        self.init(
            backend: backend,
            endpoint: endpoint,
            shutdown: {
                try await backend.runtimeOwnerLifecycleHandle.closeAndWait()
            }
        )
    }

    package func start(endpoint: URL? = nil) async {
        let endpointChanged = endpoint != nil && endpoint != self.endpoint
        if let endpoint {
            self.endpoint = endpoint
        }
        directBackend.updateEndpoint(self.endpoint)
        if endpointChanged {
            await store.stop()
        }
        await store.start()
    }

    package func stop() async throws {
        await store.stop()
        try await shutdown()
    }
}

@MainActor
private final class DirectCodexReviewStoreBackend: CodexReviewStoreBackend {
    let seed = CodexReviewStoreSeed()
    let mcpServerLifecycle: any MCPServerLifecycleOwner
    private let backend: any CodexReviewBackend
    private let mcpLifecycleOwner: NoMCPServerLifecycleOwner
    private var currentSettingsSnapshot = CodexReviewSettings.Snapshot()
    private var loginChallenge: CodexReviewBackendModel.Login.Challenge?
    private var active = false

    var isActive: Bool {
        active
    }

    var initialSettingsSnapshot: CodexReviewSettings.Snapshot {
        currentSettingsSnapshot
    }

    init(backend: any CodexReviewBackend, endpoint: URL?) {
        self.backend = backend
        let mcpLifecycleOwner = NoMCPServerLifecycleOwner(serverURL: endpoint)
        self.mcpLifecycleOwner = mcpLifecycleOwner
        self.mcpServerLifecycle = mcpLifecycleOwner
    }

    func attachStore(_: CodexReviewStore) {}

    func updateEndpoint(_ endpoint: URL?) {
        mcpLifecycleOwner.updateServerURL(endpoint)
    }

    func prepareRuntime(
        generation _: ReviewRuntimeGeneration,
        purpose _: ReviewRuntimeTransitionPurpose
    ) async throws -> PreparedRuntime {
        let settings = try await Self.monitorSettings(from: backend.readSettings())
        let authentication = try await backend.readAuth()
        return PreparedRuntime(
            snapshot: .init(authentication: authentication, settings: settings),
            handle: DirectRuntimeLifecycleHandle(
                onActivate: { [weak self] in self?.active = true },
                onCloseAdmission: { [weak self] in self?.active = false },
                onClose: { [weak self] in self?.active = false }
            )
        )
    }

    func stop(store _: CodexReviewStore) async {
        active = false
    }

    func waitUntilStopped() async {}

    func refreshSettings() async throws -> CodexReviewSettings.Snapshot {
        guard active else { return currentSettingsSnapshot }
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
        guard active else { return }
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
        guard active else { return }
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
        guard active else { return }
        currentSettingsSnapshot = try await Self.monitorSettings(
            from: backend.applySettings(.init(
                serviceTier: serviceTier?.rawValue,
                updatesServiceTier: true
            ))
        )
    }

    func refreshAuth(auth: CodexReviewAuthModel) async {
        guard active else { return }
        do {
            Self.applyAuthSnapshot(try await backend.readAuth(), to: auth)
        } catch {
            auth.updatePhase(.failed(message: error.localizedDescription))
        }
    }

    func signIn(auth: CodexReviewAuthModel) async -> CodexReviewAuthenticationSessionReceipt {
        guard active else { return .completed(.cancelled) }
        do {
            let challenge = try await backend.startLogin(.init())
            loginChallenge = challenge
            auth.updatePhase(.signingIn(.init(
                title: "Sign in to Codex",
                detail: challenge.signInDetail(nativeAuthentication: false),
                browserURL: challenge.verificationURL?.absoluteString,
                userCode: challenge.userCode
            )))
            return .completed(.succeeded)
        } catch {
            auth.updatePhase(.failed(message: error.localizedDescription))
            return .completed(.failed(error.localizedDescription))
        }
    }

    func addAccount(auth: CodexReviewAuthModel) async -> CodexReviewAuthenticationSessionReceipt {
        guard active else { return .completed(.cancelled) }
        return await signIn(auth: auth)
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

    func startReview(
        _ request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> BackendReviewAttempt {
        guard active else {
            throw CodexReviewAPI.Error.io("Review runtime is not running.")
        }
        return try await backend.startReview(request, admission: admission)
    }

    func interruptReview(
        _ run: CodexReviewBackendModel.Review.Run,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws {
        try await backend.interruptReview(run, reason: reason)
    }

    func interruptReview(
        _ admission: ReviewInterruptRequestAdmission,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws {
        try await backend.interruptReview(admission, reason: reason)
    }

    func cleanupReview(_ run: CodexReviewBackendModel.Review.Run) async throws {
        try await backend.cleanupReview(run)
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
        let accounts = snapshot.accounts.compactMap { account -> CodexAccount? in
            let label = account.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let accountKey = CodexAccount.normalizedEmail(account.id.rawValue)
            guard label.isEmpty == false, accountKey.isEmpty == false else {
                return nil
            }
            return CodexAccount(
                accountKey: accountKey,
                email: label,
                planType: account.planType,
                kind: account.kind,
                capabilities: account.capabilities
            )
        }
        let activeAccountKey = snapshot.activeAccountID
            .map { CodexAccount.normalizedEmail($0.rawValue) }
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

@MainActor
private final class DirectRuntimeLifecycleHandle: RuntimeLifecycleHandle {
    private let onActivate: @MainActor @Sendable () -> Void
    private let onCloseAdmission: @MainActor @Sendable () -> Void
    private let onClose: @MainActor @Sendable () -> Void
    private var isActivated = false
    private var didClose = false

    init(
        onActivate: @escaping @MainActor @Sendable () -> Void,
        onCloseAdmission: @escaping @MainActor @Sendable () -> Void,
        onClose: @escaping @MainActor @Sendable () -> Void
    ) {
        self.onActivate = onActivate
        self.onCloseAdmission = onCloseAdmission
        self.onClose = onClose
    }

    func activate() async throws {
        guard isActivated == false, didClose == false else {
            throw CancellationError()
        }
        isActivated = true
        onActivate()
    }

    func closeAdmission() {
        onCloseAdmission()
    }

    func close(purpose _: ReviewRuntimeTransitionPurpose) async throws {
        guard didClose == false else {
            return
        }
        didClose = true
        onClose()
    }

    func waitUntilClosed() async throws {
        guard didClose else {
            throw CancellationError()
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
