import Foundation
import Observation

@MainActor
@Observable
public final class CodexReviewStore {
    private struct RuntimeTeardownOperation {
        let id: UUID
        let cleanupIntent: ReviewRuntimeTeardownIntent
        var finalIntent: ReviewRuntimeTeardownIntent
        let task: Task<Void, Never>
    }

    package struct ReviewTerminalWaiter {
        package var id: UUID
        package var continuation: CheckedContinuation<Void, Never>
        package var timeoutTask: Task<Void, Never>?
    }

    public package(set) var serverState: CodexReviewServerState = .stopped
    public let auth: CodexReviewAuthModel
    package let settings: SettingsStore
    public package(set) var serverURL: URL?
    public package(set) var workspaces: Set<CodexReviewWorkspace> = []
    public package(set) var jobs: Set<CodexReviewJob> = []
    package var shouldAutoStartEmbeddedServer: Bool {
        backend.seed.shouldAutoStartEmbeddedServer
    }
    package var runtimeTeardownFinalState: ReviewRuntimeTeardownIntent.FinalState? {
        runtimeTeardownOperation?.finalIntent.finalState
    }
    package var runtimeLifecycleAdmissionGeneration: UInt64 {
        runtimeLifecycleGeneration
    }

    @ObservationIgnored package let diagnosticsURL: URL?
    @ObservationIgnored package let settingsService: CodexReviewSettingsService
    @ObservationIgnored package let backend: any CodexReviewStoreBackend
    @ObservationIgnored package let networkMonitor: any CodexReviewNetworkMonitoring
    @ObservationIgnored package let networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy
    @ObservationIgnored package var previewSupportRetainer: AnyObject?
    @ObservationIgnored package let clock: CodexReviewClock
    @ObservationIgnored package let idGenerator: CodexReviewIDGenerator
    @ObservationIgnored package var activeRuns: [String: CodexReviewBackendModel.Review.Run] = [:]
    @ObservationIgnored package var reviewRecoveryWaitingJobIDs: Set<String> = []
    @ObservationIgnored package var startingJobIDs: Set<String> = []
    @ObservationIgnored package var startupCancellations: [String: ReviewCancellation] = [:]
    @ObservationIgnored package var reviewWorkerTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored package var runtimeStopDetachedReviewWorkerTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored package var reviewTerminalWaiters: [String: [ReviewTerminalWaiter]] = [:]
    @ObservationIgnored package var closedSessions: Set<String> = []
    @ObservationIgnored package var accountRateLimitAutoRefreshDriver: CodexReviewStoreRateLimitAutoRefreshDriver?
    @ObservationIgnored private var runtimeTeardownOperation: RuntimeTeardownOperation?
    @ObservationIgnored private var runtimeLifecycleGeneration: UInt64 = 0

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
        runtimeTeardownOperation?.task.cancel()
        for task in reviewWorkerTasks.values {
            task.cancel()
        }
        for task in runtimeStopDetachedReviewWorkerTasks.values {
            task.cancel()
        }
        for waiters in reviewTerminalWaiters.values {
            for waiter in waiters {
                waiter.timeoutTask?.cancel()
                waiter.continuation.resume()
            }
        }
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
        let admissionGeneration = admitRuntimeLifecycleRequest()
        await start(
            forceRestartIfNeeded: forceRestartIfNeeded,
            admissionGeneration: admissionGeneration
        )
    }

    private func start(
        forceRestartIfNeeded: Bool,
        admissionGeneration: UInt64
    ) async {
        if let teardownTask = runtimeTeardownOperation?.task {
            await teardownTask.value
            guard admissionGeneration == runtimeLifecycleGeneration else {
                return
            }
        }
        let shouldRestartRunningRuntime: Bool
        switch serverState {
        case .stopped, .failed:
            shouldRestartRunningRuntime = false
        case .starting:
            return
        case .running where forceRestartIfNeeded == false:
            return
        case .running:
            shouldRestartRunningRuntime = true
        }
        if shouldRestartRunningRuntime {
            let teardownTask = admitRuntimeTeardown(intent: .explicitStop)
            await teardownTask.value
            guard admissionGeneration == runtimeLifecycleGeneration else {
                return
            }
        }
        serverState = .starting
        serverURL = nil
        writeDiagnosticsIfNeeded()
        await backend.start(store: self, forceRestartIfNeeded: forceRestartIfNeeded)
        await settingsService.refreshIfRunning(serverState: serverState)
        startAccountRateLimitAutoRefresh()
    }

    public func stop() async {
        await stop(intent: .explicitStop)
    }

    package func stop(intent: ReviewRuntimeTeardownIntent) async {
        _ = admitRuntimeLifecycleRequest()
        let task = admitRuntimeTeardown(intent: intent)
        await task.value
    }

    package func requestRuntimeTeardown(
        intent: ReviewRuntimeTeardownIntent
    ) {
        _ = admitRuntimeLifecycleRequest()
        _ = admitRuntimeTeardown(intent: intent)
    }

    private func admitRuntimeLifecycleRequest() -> UInt64 {
        runtimeLifecycleGeneration += 1
        return runtimeLifecycleGeneration
    }

    private func admitRuntimeTeardown(
        intent: ReviewRuntimeTeardownIntent
    ) -> Task<Void, Never> {
        if var operation = runtimeTeardownOperation {
            if intent.supersedesConcurrentFinalState {
                operation.finalIntent = intent
                runtimeTeardownOperation = operation
            }
            return operation.task
        }

        let operationID = UUID()
        if case .failed(let message) = intent.finalState {
            transitionToFailed(message)
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.performRuntimeTeardown(intent: intent)
            self.finishRuntimeTeardown(operationID: operationID)
        }
        runtimeTeardownOperation = .init(
            id: operationID,
            cleanupIntent: intent,
            finalIntent: intent,
            task: task
        )
        return task
    }

    private func performRuntimeTeardown(
        intent: ReviewRuntimeTeardownIntent
    ) async {
        let locallyCancelledJobIDs: [String]
        if backend.handlesActiveReviewStopCleanup {
            locallyCancelledJobIDs = []
        } else {
            locallyCancelledJobIDs = await requestActiveReviewCancellationsForRuntimeStop(
                reason: intent.reviewCancellation
            )
        }
        await backend.stop(store: self, intent: intent)
        let remainingLocallyCancelledJobIDs = cancelActiveReviewsLocallyForRuntimeStop(
            reason: intent.reviewCancellation,
            cancelWorkers: false
        )
        cancelAndDetachReviewWorkersForRuntimeStop(
            jobIDs: Array(Set(locallyCancelledJobIDs + remainingLocallyCancelledJobIDs))
        )
    }

    private func finishRuntimeTeardown(operationID: UUID) {
        guard let operation = runtimeTeardownOperation,
              operation.id == operationID
        else {
            return
        }
        runtimeTeardownOperation = nil
        switch operation.finalIntent.finalState {
        case .stopped:
            transitionToStopped()
        case .failed(let message):
            transitionToFailed(message)
        }
    }

    public func restart() async {
        let admissionGeneration = admitRuntimeLifecycleRequest()
        let teardownTask = admitRuntimeTeardown(intent: .explicitStop)
        await teardownTask.value
        guard admissionGeneration == runtimeLifecycleGeneration else {
            return
        }
        await start(
            forceRestartIfNeeded: true,
            admissionGeneration: admissionGeneration
        )
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
