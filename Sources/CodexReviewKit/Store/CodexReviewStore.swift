import Foundation
import Observation

@MainActor
@Observable
public final class CodexReviewStore {
    public package(set) var serverState: CodexReviewServerState = .stopped
    public let auth: CodexReviewAuthModel
    package let settings: SettingsStore
    public package(set) var serverURL: URL?
    package var reviewRuns: Set<ReviewRunRecord> = []
    package var shouldAutoStartEmbeddedServer: Bool {
        backend.seed.shouldAutoStartEmbeddedServer
    }

    @ObservationIgnored package let diagnosticsURL: URL?
    @ObservationIgnored package let settingsService: CodexReviewSettingsService
    @ObservationIgnored package let backend: any CodexReviewStoreBackend
    @ObservationIgnored package let networkMonitor: any CodexReviewNetworkMonitoring
    @ObservationIgnored package let networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy
    @ObservationIgnored package var previewSupportRetainer: AnyObject?
    @ObservationIgnored package let clock: CodexReviewClock
    @ObservationIgnored package let idGenerator: CodexReviewIDGenerator
    @ObservationIgnored let runtimeState = CodexReviewStoreRuntimeState()
    @ObservationIgnored package var closedSessions: Set<String> = []
    @ObservationIgnored package var accountRateLimitAutoRefreshDriver: CodexReviewStoreRateLimitAutoRefreshDriver?

    package init(
        backend: any CodexReviewStoreBackend = PreviewCodexReviewStoreBackend(),
        settingsService: CodexReviewSettingsService? = nil,
        diagnosticsURL: URL? = nil,
        clock: CodexReviewClock = .init(),
        idGenerator: CodexReviewIDGenerator = .init(),
        networkMonitor: any CodexReviewNetworkMonitoring = SystemCodexReviewNetworkMonitor(),
        networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy = .default
    ) {
        self.backend = backend
        self.networkMonitor = networkMonitor
        self.networkRecoveryPolicy = networkRecoveryPolicy
        self.diagnosticsURL = diagnosticsURL
        self.clock = clock
        self.idGenerator = idGenerator
        self.auth = CodexReviewAuthModel()
        self.settings = SettingsStore(snapshot: backend.seed.initialSettingsSnapshot)
        self.settingsService = settingsService ?? CodexReviewSettingsService(
            initialSnapshot: backend.seed.initialSettingsSnapshot,
            backend: backend
        )
        self.settingsService.attach(settings: settings)
        auth.applyPersistedAccountStates(
            backend.seed.initialAccounts.map(savedAccountPayload(from:)),
            activeAccountKey: backend.seed.initialActiveAccountKey
        )
        if let initialAccount = backend.seed.initialAccount {
            if auth.persistedAccounts.contains(where: { $0.accountKey == initialAccount.accountKey }) {
                auth.selectPersistedAccount(initialAccount.id)
            } else {
                auth.updateCurrentAccount(initialAccount)
            }
        } else if let initialActiveAccountKey = backend.seed.initialActiveAccountKey {
            auth.selectPersistedAccount(initialActiveAccountKey)
        }
        backend.attachStore(self)
    }

    isolated deinit {
        accountRateLimitAutoRefreshDriver?.cancel()
        runtimeState.cancelAllWorkers()
    }

    public static func makePreviewStore(diagnosticsURL: URL? = nil) -> CodexReviewStore {
        makePreviewStore(seed: .init(), diagnosticsURL: diagnosticsURL)
    }

    package static func makePreviewStore(
        seed: CodexReviewStoreSeed,
        diagnosticsURL: URL? = nil
    ) -> CodexReviewStore {
        CodexReviewStore(
            backend: PreviewCodexReviewStoreBackend(seed: seed),
            diagnosticsURL: diagnosticsURL,
            networkMonitor: StaticCodexReviewNetworkMonitor()
        )
    }

    package static func makeTestingStore(
        backend: any CodexReviewStoreBackend,
        diagnosticsURL: URL? = nil,
        clock: CodexReviewClock = .init(),
        idGenerator: CodexReviewIDGenerator = .init(),
        networkMonitor: any CodexReviewNetworkMonitoring = StaticCodexReviewNetworkMonitor(),
        networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy = .default
    ) -> CodexReviewStore {
        CodexReviewStore(
            backend: backend,
            diagnosticsURL: diagnosticsURL,
            clock: clock,
            idGenerator: idGenerator,
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: networkRecoveryPolicy
        )
    }

    public func start(forceRestartIfNeeded: Bool = false) async {
        switch serverState {
        case .stopped, .failed:
            break
        case .starting:
            return
        case .running where forceRestartIfNeeded == false:
            return
        case .running:
            break
        }
        serverState = .starting
        serverURL = nil
        writeDiagnosticsIfNeeded()
        await backend.start(store: self, forceRestartIfNeeded: forceRestartIfNeeded)
        await settingsService.refreshIfRunning(serverState: serverState)
        startAccountRateLimitAutoRefresh()
    }

    public func stop() async {
        let locallyCancelledReviewRunIDs: [String]
        if backend.invokesRuntimeStopReviewCleanupDuringStop {
            locallyCancelledReviewRunIDs = []
        } else {
            locallyCancelledReviewRunIDs = await requestActiveReviewCancellationsForRuntimeStop()
        }
        await backend.stop(store: self)
        let remainingLocallyCancelledReviewRunIDs = cancelActiveReviewsLocallyForRuntimeStop(cancelWorkers: false)
        cancelAndDetachReviewWorkersForRuntimeStop(
            runIDs: Array(Set(locallyCancelledReviewRunIDs + remainingLocallyCancelledReviewRunIDs))
        )
        transitionToStopped()
    }

    public func restart() async {
        await stop()
        await start(forceRestartIfNeeded: true)
    }

    public func waitUntilStopped() async {
        await backend.waitUntilStopped()
    }

    public func refreshAuthentication() async {
        await backend.refreshAuth(auth: auth)
    }

    public func signIn() async {
        await backend.signIn(auth: auth)
    }

    public func addAccount() async {
        await backend.addAccount(auth: auth)
    }

    public func cancelAuthentication() async {
        await backend.cancelAuthentication(auth: auth)
    }

    package func performPrimaryAuthenticationAction() async {
        if auth.isAuthenticating {
            await cancelAuthentication()
            return
        }
        guard canPerformPrimaryAuthenticationAction else {
            return
        }
        if serverState.canRestartForAuthentication {
            await start(forceRestartIfNeeded: true)
        }
        guard case .running = serverState,
              canPerformPrimaryAuthenticationAction
        else {
            return
        }
        await signIn()
    }

    public func logout() async {
        if auth.isAuthenticating, auth.selectedAccount == nil {
            await cancelAuthentication()
            return
        }
        do {
            try await signOutActiveAccount()
        } catch {
            if auth.errorMessage == nil, auth.isAuthenticated {
                auth.updatePhase(.failed(message: error.localizedDescription))
            }
        }
    }

    public func signOutActiveAccount() async throws {
        try await backend.signOutActiveAccount(auth: auth)
    }

    package func switchAccount(_ account: CodexReviewAccount) async throws {
        guard canSwitchAccount(account) else {
            return
        }
        let targetAccount = auth.persistedAccounts.first(where: { $0.accountKey == account.accountKey })
        if auth.persistedAccounts.contains(where: { $0.isSwitching }) || auth.selectedAccount?.isSwitching == true {
            return
        }
        targetAccount?.updateIsSwitching(true)
        defer {
            targetAccount?.updateIsSwitching(false)
        }
        try await backend.switchAccount(auth: auth, accountKey: account.accountKey)
    }

    package func requestSwitchAccount(_ account: CodexReviewAccount, requiresConfirmation: Bool) {
        auth.requestSwitchAccount(account, requiresConfirmation: requiresConfirmation)
        guard requiresConfirmation == false else {
            return
        }
        confirmPendingAccountAction()
    }

    package func requestSwitchAccountFromUserAction(_ account: CodexReviewAccount) {
        requestSwitchAccount(
            account,
            requiresConfirmation: hasRunningReviewRuns
                && switchActionRequiresRunningReviewRunsConfirmation(for: account)
        )
    }

    package func requestSignOutActiveAccount(requiresConfirmation: Bool) {
        auth.requestSignOutActiveAccount(requiresConfirmation: requiresConfirmation)
        guard requiresConfirmation == false else {
            return
        }
        confirmPendingAccountAction()
    }

    package func requestRemoveAccount(_ account: CodexReviewAccount, requiresConfirmation: Bool) {
        auth.requestRemoveAccount(account, requiresConfirmation: requiresConfirmation)
        guard requiresConfirmation == false else {
            return
        }
        confirmPendingAccountAction()
    }

    package func confirmPendingAccountAction() {
        guard let action = auth.consumePendingAccountAction() else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                try await self.executePendingAccountAction(action)
                if let warningMessage = self.auth.warningMessage {
                    self.auth.presentAccountActionAlert(
                        title: "Account Updated With Warning",
                        message: warningMessage
                    )
                }
            } catch {
                self.auth.presentAccountActionAlert(
                    title: action.failureTitle,
                    message: error.localizedDescription
                )
            }
        }
    }

    package func cancelPendingAccountAction() {
        auth.cancelPendingAccountAction()
    }

    package func dismissAccountActionAlert() {
        auth.dismissAccountActionAlert()
    }

    package func removeAccount(accountKey: String) async throws {
        try await backend.removeAccount(auth: auth, accountKey: accountKey)
    }

    package func reorderPersistedAccount(accountKey: String, toIndex: Int) async throws {
        try await backend.reorderPersistedAccount(auth: auth, accountKey: accountKey, toIndex: toIndex)
    }

    package func refreshAccountRateLimits(accountKey: String) async {
        await backend.refreshAccountRateLimits(auth: auth, accountKey: accountKey)
    }

    package func startStartupAuthRefresh() {
        if auth.selectedAccount == nil {
            auth.updatePhase(.signedOut)
        }
    }

    package func cancelStartupAuthRefresh() {}

    package func reconcileAuthenticatedSession(serverIsRunning _: Bool, runtimeGeneration _: Int) async {}

    package func switchActionIsDisabled(for account: CodexReviewAccount) -> Bool {
        canSwitchAccount(account) == false
    }

    package func switchActionRequiresRunningReviewRunsConfirmation(for account: CodexReviewAccount) -> Bool {
        guard canSwitchAccount(account) else {
            return false
        }
        return true
    }

    package func refreshSettings() async {
        await settingsService.refresh()
    }

    package func updateSettingsModel(_ model: String) async {
        await settingsService.updateModel(model)
    }

    package func clearSettingsModelOverride() async {
        await settingsService.clearModelOverride()
    }

    package func updateSettingsReasoningEffort(_ reasoningEffort: CodexReviewSettings.ReasoningEffort?) async {
        await settingsService.updateReasoningEffort(reasoningEffort)
    }

    package func clearSettingsReasoningEffort() async {
        await updateSettingsReasoningEffort(nil)
    }

    package func updateSettingsServiceTier(_ serviceTier: CodexReviewSettings.ServiceTier?) async {
        await settingsService.updateServiceTier(serviceTier)
    }

    package func transitionToRunning(serverURL: URL?) {
        self.serverURL = serverURL
        serverState = .running
        writeDiagnosticsIfNeeded()
    }

    package func transitionToFailed(_ message: String, resetReviewRuns: Bool = false) {
        serverURL = nil
        if resetReviewRuns {
            resetReviews()
        }
        serverState = .failed(message)
        writeDiagnosticsIfNeeded()
    }

    package func transitionToStopped(resetReviewRuns: Bool = false) {
        serverURL = nil
        if resetReviewRuns {
            resetReviews()
        }
        serverState = .stopped
        writeDiagnosticsIfNeeded()
    }

    package func writeDiagnosticsIfNeeded() {
        guard let diagnosticsURL else {
            return
        }
        let reviewRuns: [CodexReviewStoreDiagnosticsSnapshot.Run] = orderedReviewRuns.map { runRecord in
            return CodexReviewStoreDiagnosticsSnapshot.Run(
                status: runRecord.core.lifecycle.status.rawValue,
                summary: runRecord.core.output.summary
            )
        }
        let snapshot = CodexReviewStoreDiagnosticsSnapshot(
            serverState: serverState.displayText,
            failureMessage: serverState.failureMessage,
            serverURL: serverURL?.absoluteString,
            childRuntimePath: nil,
            reviewRuns: reviewRuns
        )
        do {
            try FileManager.default.createDirectory(
                at: diagnosticsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: diagnosticsURL, options: Data.WritingOptions.atomic)
        } catch {}
    }

    package func noteReviewRunMutation() {
        writeDiagnosticsIfNeeded()
    }

    public var hasRunningReviewRuns: Bool {
        reviewRuns.contains(where: { $0.isTerminal == false })
    }

    public var runningReviewRunCount: Int {
        reviewRuns.filter { $0.isTerminal == false }.count
    }

    public var canPerformPrimaryAuthenticationAction: Bool {
        if auth.isAuthenticating {
            return true
        }
        guard auth.isAuthenticated == false else {
            return false
        }
        switch serverState {
        case .running, .stopped, .failed:
            return true
        case .starting:
            return false
        }
    }

    private func resetReviews() {
        reviewRuns = []
    }

    private func executePendingAccountAction(_ action: CodexReviewAuthModel.PendingAccountAction) async throws {
        switch action {
        case .switchAccount(let accountKey):
            guard let account = auth.persistedAccounts.first(where: { $0.accountKey == accountKey }) else {
                return
            }
            try await switchAccount(account)
        case .signOutActiveAccount:
            try await signOutActiveAccount()
        case .removeAccount(let accountKey):
            try await removeAccount(accountKey: accountKey)
        }
    }

    private func canSwitchAccount(_ account: CodexReviewAccount) -> Bool {
        auth.canRequestSwitchAccount(account)
    }

}

private extension CodexReviewServerState {
    var canRestartForAuthentication: Bool {
        switch self {
        case .stopped, .failed:
            true
        case .starting, .running:
            false
        }
    }
}
