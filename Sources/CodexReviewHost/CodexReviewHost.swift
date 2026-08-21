import Foundation
import CodexReview
import CodexReviewAppServer
import CodexReviewMCPServer

@MainActor
package final class CodexReviewHost {
    package let store: CodexReviewStore
    package let mcpServer: CodexReviewMCPServer
    private var endpoint: URL?

    package init(
        backend: any CodexReviewBackend,
        clock: CodexReviewClock = .init(),
        idGenerator: CodexReviewIDGenerator = .init(),
        endpoint: URL? = nil,
        closeAdmission: @escaping @MainActor @Sendable () async -> Void = {},
        shutdown: @escaping @MainActor @Sendable () async throws -> Void = {}
    ) {
        self.endpoint = endpoint
        let store = CodexReviewStore(
            backend: DirectCodexReviewStoreBackend(
                backend: backend,
                closeAdmission: closeAdmission,
                shutdown: shutdown
            ),
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
            closeAdmission: {
                await backend.runtimeOwnerLifecycleHandle.closeAdmission()
            },
            shutdown: {
                try await backend.runtimeOwnerLifecycleHandle.closeAndWait()
            }
        )
    }

    package func start(endpoint: URL? = nil) async {
        if let endpoint {
            self.endpoint = endpoint
        }
        await store.start()
        guard case .open = store.lifetimeState,
              case .running = store.runtimeState
        else {
            return
        }
        store.transitionToRunning(serverURL: self.endpoint)
        await store.refreshSettings()
    }

    package func stop() async throws {
        await store.stop()
    }
}

@MainActor
private final class DirectCodexReviewStoreBackend: CodexReviewStoreBackend {
    let seed = CodexReviewStoreSeed()
    let mcpServerLifecycle: any MCPServerLifecycleOwner = NoMCPServerLifecycleOwner()
    private let backend: any CodexReviewBackend
    private let closeAdmission: @MainActor @Sendable () async -> Void
    private let shutdown: @MainActor @Sendable () async throws -> Void
    private var currentSettingsSnapshot = CodexReviewSettings.Snapshot()
    private var loginChallenge: CodexReviewBackendModel.Login.Challenge?
    private var active = false

    var isActive: Bool {
        active
    }

    var initialSettingsSnapshot: CodexReviewSettings.Snapshot {
        currentSettingsSnapshot
    }

    init(
        backend: any CodexReviewBackend,
        closeAdmission: @escaping @MainActor @Sendable () async -> Void,
        shutdown: @escaping @MainActor @Sendable () async throws -> Void
    ) {
        self.backend = backend
        self.closeAdmission = closeAdmission
        self.shutdown = shutdown
    }

    func attachStore(_: CodexReviewStore) {}

    func prepareRuntime(
        generation _: ReviewRuntimeGeneration,
        purpose _: ReviewRuntimeTransitionPurpose
    ) async throws -> PreparedRuntime {
        let shutdown = shutdown
        let handle = DirectRuntimeLifecycleHandle(
            onActivate: { [weak self] in self?.active = true },
            onCloseAdmission: closeAdmission,
            onClose: { [weak self] in
                defer { self?.active = false }
                try await shutdown()
            }
        )
        let closeRecord = RuntimeCloseRecord()
        do {
            let authentication = try await backend.readAuth()
            let settings = try await Self.monitorSettings(from: backend.readSettings())
            return .init(
                snapshot: .init(
                    authentication: authentication,
                    settings: settings
                ),
                handle: handle,
                closeRecord: closeRecord
            )
        } catch {
            await handle.closeAdmission()
            _ = await closeRecord.closeAndWait(
                handle: handle,
                purpose: .stop
            )
            let cleanupFailures = closeRecord.consumeFailures().flatMap {
                failure -> [ReviewLifecycleResourceFailure] in
                switch failure {
                case .lifecycleResources(let aggregate):
                    return [aggregate.first] + aggregate.additionalInLifecycleOrder
                case .attemptRuntime(let failure):
                    return [.client(failure.localizedDescription)]
                case .interruptRequest(let failure):
                    return [.client(failure.localizedDescription)]
                case .persistence(let failure):
                    return [.client(failure.localizedDescription)]
                }
            }
            if let first = cleanupFailures.first {
                throw ReviewRuntimePreparationFailure(
                    preparationError: error,
                    cleanupFailures: .init(
                        first: first,
                        additionalInLifecycleOrder: Array(cleanupFailures.dropFirst())
                    )
                )
            }
            throw error
        }
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

    func startReview(
        _ request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> BackendReviewAttempt {
        try await backend.startReview(request, admission: admission)
    }

    func interruptReview(
        _ run: CodexReviewBackendModel.Review.Run,
        admission _: ReviewStartAdmission,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws {
        try await backend.interruptReview(run, reason: reason)
    }

    func forceCloseReviewConnection() async throws {
        try await backend.forceCloseReviewConnection()
    }

    func prepareReviewRecovery(
        _ candidate: ReviewRecoveryCandidate
    ) async throws -> ReviewRecoveryHandoff {
        try await backend.prepareReviewRecovery(candidate)
    }

    func resumeReviewRecovery(
        _ handoff: ReviewRecoveryHandoff,
        request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> BackendReviewAttempt {
        try await backend.resumeReviewRecovery(handoff, request: request, admission: admission)
    }

    func commitResumedReviewRecovery(
        _: ReviewRecoveryHandoff,
        recoveredRun _: CodexReviewBackendModel.Review.Run
    ) throws {}

    func discardResumedReviewRecovery(
        _: ReviewRecoveryHandoff,
        recoveredRun: CodexReviewBackendModel.Review.Run
    ) async throws {
        try await backend.cleanupReview(recoveredRun)
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
    private let onCloseAdmission: @MainActor @Sendable () async -> Void
    private let onClose: @MainActor @Sendable () async throws -> Void
    private var closeTask: Task<Result<Void, ReviewLifecycleResourceFailureAggregate>, Never>?

    init(
        onActivate: @escaping @MainActor @Sendable () -> Void,
        onCloseAdmission: @escaping @MainActor @Sendable () async -> Void,
        onClose: @escaping @MainActor @Sendable () async throws -> Void
    ) {
        self.onActivate = onActivate
        self.onCloseAdmission = onCloseAdmission
        self.onClose = onClose
    }

    func activate() async throws {
        onActivate()
    }

    func closeAdmission() async {
        await onCloseAdmission()
    }

    func close(purpose _: ReviewRuntimeTransitionPurpose) async throws {
        let task: Task<Result<Void, ReviewLifecycleResourceFailureAggregate>, Never>
        if let closeTask {
            task = closeTask
        } else {
            let onClose = onClose
            let newTask = Task<Result<Void, ReviewLifecycleResourceFailureAggregate>, Never> { @MainActor in
                do {
                    try await onClose()
                    return .success(())
                } catch let aggregate as ReviewLifecycleResourceFailureAggregate {
                    return .failure(aggregate)
                } catch let failure as ReviewLifecycleResourceFailure {
                    return .failure(.init(first: failure))
                } catch {
                    return .failure(.init(first: .client(error.localizedDescription)))
                }
            }
            closeTask = newTask
            task = newTask
        }
        try await task.value.get()
    }

    func waitUntilClosed() async throws {
        guard let closeTask else {
            throw ReviewLifecycleResourceFailure.client(
                "Direct runtime wait began before close."
            )
        }
        try await closeTask.value.get()
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
