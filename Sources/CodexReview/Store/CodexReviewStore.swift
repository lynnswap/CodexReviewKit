import Foundation
import Observation

@MainActor
@Observable
public final class CodexReviewStore {
    public package(set) var serverState: CodexReviewServerState = .stopped
    public let auth: CodexReviewAuthModel
    package let settings: SettingsStore
    public package(set) var serverURL: URL?
    public package(set) var workspaces: Set<CodexReviewWorkspace> = []
    public package(set) var jobs: Set<CodexReviewJob> = []
    package var shouldAutoStartEmbeddedServer: Bool {
        backend.seed.shouldAutoStartEmbeddedServer
    }

    @ObservationIgnored package let diagnosticsURL: URL?
    @ObservationIgnored package let settingsService: CodexReviewSettingsService
    @ObservationIgnored package let backend: any CodexReviewStoreBackend
    @ObservationIgnored package var previewSupportRetainer: AnyObject?
    @ObservationIgnored package let clock: CodexReviewClock
    @ObservationIgnored package let idGenerator: CodexReviewIDGenerator
    @ObservationIgnored package var activeRuns: [String: BackendReviewRun] = [:]
    @ObservationIgnored package var startingJobIDs: Set<String> = []
    @ObservationIgnored package var startupCancellations: [String: ReviewCancellation] = [:]
    @ObservationIgnored package var closedSessions: Set<String> = []

    package init(
        backend: any CodexReviewStoreBackend = PreviewCodexReviewStoreBackend(),
        settingsService: CodexReviewSettingsService? = nil,
        diagnosticsURL: URL? = nil,
        clock: CodexReviewClock = .init(),
        idGenerator: CodexReviewIDGenerator = .init()
    ) {
        self.backend = backend
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

    public static func makePreviewStore(diagnosticsURL: URL? = nil) -> CodexReviewStore {
        makePreviewStore(seed: .init(), diagnosticsURL: diagnosticsURL)
    }

    package static func makePreviewStore(
        seed: CodexReviewStoreSeed,
        diagnosticsURL: URL? = nil
    ) -> CodexReviewStore {
        CodexReviewStore(
            backend: PreviewCodexReviewStoreBackend(seed: seed),
            diagnosticsURL: diagnosticsURL
        )
    }

    package static func makeTestingStore(
        backend: any CodexReviewStoreBackend,
        diagnosticsURL: URL? = nil,
        clock: CodexReviewClock = .init(),
        idGenerator: CodexReviewIDGenerator = .init()
    ) -> CodexReviewStore {
        CodexReviewStore(
            backend: backend,
            diagnosticsURL: diagnosticsURL,
            clock: clock,
            idGenerator: idGenerator
        )
    }

    public func start(forceRestartIfNeeded: Bool = false) async {
        switch serverState {
        case .stopped, .failed:
            break
        case .starting, .running:
            return
        }
        serverState = .starting
        serverURL = nil
        writeDiagnosticsIfNeeded()
        await backend.start(store: self, forceRestartIfNeeded: forceRestartIfNeeded)
        await settingsService.refreshIfRunning(serverState: serverState)
    }

    public func stop() async {
        await backend.stop(store: self)
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

    package func switchAccount(_ account: CodexAccount) async throws {
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

    package func requestSwitchAccount(_ account: CodexAccount, requiresConfirmation: Bool) {
        auth.requestSwitchAccount(account, requiresConfirmation: requiresConfirmation)
        guard requiresConfirmation == false else {
            return
        }
        confirmPendingAccountAction()
    }

    package func requestSwitchAccountFromUserAction(_ account: CodexAccount) {
        requestSwitchAccount(
            account,
            requiresConfirmation: hasRunningJobs
                && switchActionRequiresRunningJobsConfirmation(for: account)
        )
    }

    package func requestSignOutActiveAccount(requiresConfirmation: Bool) {
        auth.requestSignOutActiveAccount(requiresConfirmation: requiresConfirmation)
        guard requiresConfirmation == false else {
            return
        }
        confirmPendingAccountAction()
    }

    package func requestRemoveAccount(_ account: CodexAccount, requiresConfirmation: Bool) {
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

    package func switchActionIsDisabled(for account: CodexAccount) -> Bool {
        canSwitchAccount(account) == false
    }

    package func switchActionRequiresRunningJobsConfirmation(for account: CodexAccount) -> Bool {
        if account.accountKey != auth.selectedAccount?.accountKey {
            return true
        }
        return backend.requiresCurrentSessionRecovery(auth: auth, accountKey: account.accountKey)
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

    package func updateSettingsReasoningEffort(_ reasoningEffort: CodexReviewReasoningEffort?) async {
        await settingsService.updateReasoningEffort(reasoningEffort)
    }

    package func clearSettingsReasoningEffort() async {
        await updateSettingsReasoningEffort(nil)
    }

    package func updateSettingsServiceTier(_ serviceTier: CodexReviewServiceTier?) async {
        await settingsService.updateServiceTier(serviceTier)
    }

    package func transitionToRunning(serverURL: URL?) {
        self.serverURL = serverURL
        serverState = .running
        writeDiagnosticsIfNeeded()
    }

    package func transitionToFailed(_ message: String, resetJobs: Bool = false) {
        serverURL = nil
        if resetJobs {
            resetReviews()
        }
        serverState = .failed(message)
        writeDiagnosticsIfNeeded()
    }

    package func transitionToStopped(resetJobs: Bool = false) {
        serverURL = nil
        if resetJobs {
            resetReviews()
        }
        serverState = .stopped
        writeDiagnosticsIfNeeded()
    }

    package func writeDiagnosticsIfNeeded() {
        guard let diagnosticsURL else {
            return
        }
        let jobs = orderedJobs.map { job in
            CodexReviewStoreDiagnosticsSnapshot.Job(
                status: job.core.lifecycle.status.rawValue,
                summary: job.core.output.summary,
                logText: job.logText,
                rawLogText: job.rawLogText
            )
        }
        let snapshot = CodexReviewStoreDiagnosticsSnapshot(
            serverState: serverState.displayText,
            failureMessage: serverState.failureMessage,
            serverURL: serverURL?.absoluteString,
            childRuntimePath: nil,
            jobs: jobs
        )
        do {
            try FileManager.default.createDirectory(
                at: diagnosticsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: diagnosticsURL, options: .atomic)
        } catch {}
    }

    package func noteJobMutation() {
        writeDiagnosticsIfNeeded()
    }

    public var hasRunningJobs: Bool {
        jobs.contains(where: { $0.isTerminal == false })
    }

    public var runningJobCount: Int {
        jobs.filter { $0.isTerminal == false }.count
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
        workspaces = []
        jobs = []
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

    private func canSwitchAccount(_ account: CodexAccount) -> Bool {
        auth.persistedAccounts.contains(where: { $0.accountKey == account.accountKey })
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
