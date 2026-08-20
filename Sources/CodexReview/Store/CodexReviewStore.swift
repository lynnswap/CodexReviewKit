import Foundation
import Observation

@MainActor
@Observable
public final class CodexReviewStore {
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

    @ObservationIgnored package let diagnosticsURL: URL?
    @ObservationIgnored package let settingsService: CodexReviewSettingsService
    @ObservationIgnored package let backend: any CodexReviewStoreBackend
    @ObservationIgnored package let networkMonitor: any CodexReviewNetworkMonitoring
    @ObservationIgnored package let networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy
    @ObservationIgnored package let reviewRuntimeClosePolicy: ReviewRuntimeClosePolicy
    @ObservationIgnored package var previewSupportRetainer: AnyObject?
    @ObservationIgnored package let clock: CodexReviewClock
    @ObservationIgnored package let idGenerator: CodexReviewIDGenerator
    @ObservationIgnored package var reviewAttemptOwnerships: [String: ReviewAttemptOwnership] = [:]
    @ObservationIgnored package var reviewCleanupFailures: [String: ReviewRuntimeCloseFailure] = [:]
    @ObservationIgnored package var reviewWorkerTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored package var runtimeStopDetachedReviewWorkerTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored package var reviewTerminalWaiters: [String: [ReviewTerminalWaiter]] = [:]
    @ObservationIgnored package var closedSessions: Set<String> = []
    @ObservationIgnored package var accountRateLimitAutoRefreshDriver: CodexReviewStoreRateLimitAutoRefreshDriver?
    @ObservationIgnored package var runtimeState: ReviewStoreRuntimeState = .stopped(
        .init(rawValue: 0)
    )

    package init(
        backend: any CodexReviewStoreBackend = PreviewCodexReviewStoreBackend(),
        settingsService: CodexReviewSettingsService? = nil,
        diagnosticsURL: URL? = nil,
        clock: CodexReviewClock = .init(),
        idGenerator: CodexReviewIDGenerator = .init(),
        networkMonitor: any CodexReviewNetworkMonitoring = SystemCodexReviewNetworkMonitor(),
        networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy = .default,
        reviewRuntimeClosePolicy: ReviewRuntimeClosePolicy = .production
    ) {
        self.backend = backend
        self.networkMonitor = networkMonitor
        self.networkRecoveryPolicy = networkRecoveryPolicy
        self.reviewRuntimeClosePolicy = reviewRuntimeClosePolicy
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
        switch runtimeState {
        case .acquiring(_, let task), .transitioning(_, _, let task):
            task.cancel()
        case .stopped, .running, .failed:
            break
        }
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
        networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy = .default,
        reviewRuntimeClosePolicy: ReviewRuntimeClosePolicy = .production
    ) -> CodexReviewStore {
        CodexReviewStore(
            backend: backend,
            diagnosticsURL: diagnosticsURL,
            clock: clock,
            idGenerator: idGenerator,
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: networkRecoveryPolicy,
            reviewRuntimeClosePolicy: reviewRuntimeClosePolicy
        )
    }

    public func start(forceRestartIfNeeded: Bool = false) async {
        switch runtimeState {
        case .acquiring:
            return
        case .transitioning(_, _, let task):
            await task.value
            return
        case .running where forceRestartIfNeeded == false:
            return
        case .running(let generation, let runtime, let mcpGeneration):
            await startRuntimeReplacement(
                previousGeneration: generation,
                previousRuntime: runtime,
                retainedMCPGeneration: mcpGeneration,
                retainedServerURL: serverURL
            )
            return
        case .failed(let generation, let mcpGeneration, let retainedServerURL):
            await startRuntimeReplacement(
                previousGeneration: generation,
                previousRuntime: nil,
                retainedMCPGeneration: mcpGeneration,
                retainedServerURL: retainedServerURL
            )
            return
        case .stopped:
            break
        }
        let purpose: ReviewRuntimeTransitionPurpose = forceRestartIfNeeded
            ? .restartSameAccount
            : .stop
        await startRuntime(purpose: purpose)
    }

    private func startRuntime(purpose: ReviewRuntimeTransitionPurpose) async {
        guard case .stopped(let previousGeneration) = runtimeState else {
            return
        }
        let generation = previousGeneration.successor()
        serverState = .starting
        serverURL = nil
        writeDiagnosticsIfNeeded()
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performRuntimeAcquisition(
                generation: generation,
                purpose: purpose
            )
        }
        runtimeState = .acquiring(generation: generation, task: task)
        await task.value
    }

    private func startRuntimeReplacement(
        previousGeneration: ReviewRuntimeGeneration,
        previousRuntime: PreparedRuntime?,
        retainedMCPGeneration: MCPServerGeneration,
        retainedServerURL: URL?
    ) async {
        let generation = previousGeneration.successor()
        serverState = .starting
        writeDiagnosticsIfNeeded()
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performRuntimeReplacement(
                generation: generation,
                previousRuntime: previousRuntime,
                retainedMCPGeneration: retainedMCPGeneration,
                retainedServerURL: retainedServerURL
            )
        }
        runtimeState = .transitioning(
            generation: generation,
            purpose: .restartSameAccount,
            task: task
        )
        await task.value
    }

    public func stop() async {
        let previousState = runtimeState
        switch previousState {
        case .stopped:
            transitionToStopped()
            return
        case .transitioning(_, .stop, let task):
            await task.value
            return
        case .acquiring, .running, .transitioning, .failed:
            break
        }
        let invalidatedGeneration = previousState.generation.successor()
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performRuntimeStop(
                previousState: previousState,
                invalidatedGeneration: invalidatedGeneration
            )
        }
        runtimeState = .transitioning(
            generation: invalidatedGeneration,
            purpose: .stop,
            task: task
        )
        await task.value
    }

    private func performRuntimeStop(
        previousState: ReviewStoreRuntimeState,
        invalidatedGeneration: ReviewRuntimeGeneration
    ) async {
        switch previousState {
        case .acquiring(_, let task):
            task.cancel()
            await stopPreparedMCPServer()
            await task.value
        case .running(_, let runtime, _):
            await stopPublishedRuntime(runtime)
        case .transitioning(_, _, let task):
            task.cancel()
            await task.value
            await stopPreparedMCPServer()
        case .failed:
            await stopPreparedMCPServer()
        case .stopped:
            break
        }
        guard case .transitioning(let currentGeneration, .stop, _) = runtimeState,
              currentGeneration == invalidatedGeneration
        else {
            return
        }
        runtimeState = .stopped(invalidatedGeneration)
        transitionToStopped()
    }

    private func stopPublishedRuntime(_ runtime: PreparedRuntime) async {
        await performPublishedRuntimeSemanticStop()
        await runtime.handle.closeAdmission()
        await stopPreparedMCPServer()
        await closeAppServerRuntime(runtime, purpose: .stop)
    }

    private func performPublishedRuntimeSemanticStop() async {
        let locallyCancelledJobIDs: [String]
        if backend.handlesActiveReviewStopCleanup {
            locallyCancelledJobIDs = []
        } else {
            do {
                locallyCancelledJobIDs = try await requestActiveReviewCancellationsForRuntimeStop()
            } catch {
                locallyCancelledJobIDs = []
            }
        }
        await backend.stop(store: self)
        let remainingLocallyCancelledJobIDs = cancelActiveReviewsLocallyForRuntimeStop(cancelWorkers: false)
        cancelAndDetachReviewWorkersForRuntimeStop(
            jobIDs: Array(Set(locallyCancelledJobIDs + remainingLocallyCancelledJobIDs))
        )
    }

    private func closeAppServerRuntime(
        _ runtime: PreparedRuntime,
        purpose: ReviewRuntimeTransitionPurpose
    ) async {
        do {
            try await runtime.handle.close(purpose: purpose)
        } catch {
            writeDiagnosticsIfNeeded()
        }
        do {
            try await runtime.handle.waitUntilClosed()
        } catch {
            writeDiagnosticsIfNeeded()
        }
    }

    public func restart() async {
        await start(forceRestartIfNeeded: true)
    }

    public func waitUntilStopped() async {
        if case .transitioning(_, _, let task) = runtimeState {
            await task.value
        }
        await backend.waitUntilStopped()
        try? await backend.mcpServerLifecycle.waitUntilStopped()
    }

    private func performRuntimeAcquisition(
        generation: ReviewRuntimeGeneration,
        purpose: ReviewRuntimeTransitionPurpose
    ) async {
        guard isCurrentAcquisition(generation) else {
            return
        }
        var preparedMCPServer: PreparedMCPServer?
        var preparedRuntime: PreparedRuntime?
        do {
            let mcpServer = try await backend.mcpServerLifecycle.prepare()
            preparedMCPServer = mcpServer
            guard isCurrentAcquisition(generation) else {
                if currentTransitionOwnsMCPStop == false {
                    await stopPreparedMCPServer()
                }
                return
            }

            let runtime = try await backend.prepareRuntime(
                generation: generation,
                purpose: purpose
            )
            preparedRuntime = runtime
            guard isCurrentAcquisition(generation) else {
                await closeStaleRuntime(
                    runtime,
                    mcpServerWasPrepared: true,
                    purpose: purpose
                )
                return
            }

            try await runtime.handle.activate()
            guard isCurrentAcquisition(generation) else {
                await closeStaleRuntime(
                    runtime,
                    mcpServerWasPrepared: true,
                    purpose: purpose
                )
                return
            }
            publishRuntimeSnapshot(runtime.snapshot)

            let mcpSnapshot = try await backend.mcpServerLifecycle.activate(
                mcpServer.generation
            )
            guard isCurrentAcquisition(generation) else {
                await closeStaleRuntime(
                    runtime,
                    mcpServerWasPrepared: true,
                    purpose: purpose
                )
                return
            }

            runtimeState = .running(
                generation: generation,
                runtime: runtime,
                mcpGeneration: mcpServer.generation
            )
            publishMCPServer(serverURL: mcpSnapshot.serverURL)
        } catch {
            if let preparedRuntime {
                await closeStaleRuntime(
                    preparedRuntime,
                    mcpServerWasPrepared: preparedMCPServer != nil,
                    purpose: purpose
                )
            } else if preparedMCPServer != nil,
                      currentTransitionOwnsMCPStop == false {
                await stopPreparedMCPServer()
            }
            guard isCurrentAcquisition(generation) else {
                return
            }
            runtimeState = .stopped(generation)
            transitionToFailed(error.localizedDescription)
        }
    }

    package func performRuntimeAcquisitionForTesting(
        generation: ReviewRuntimeGeneration,
        purpose: ReviewRuntimeTransitionPurpose
    ) async {
        await performRuntimeAcquisition(
            generation: generation,
            purpose: purpose
        )
    }

    private func performRuntimeReplacement(
        generation: ReviewRuntimeGeneration,
        previousRuntime: PreparedRuntime?,
        retainedMCPGeneration: MCPServerGeneration,
        retainedServerURL: URL?
    ) async {
        var preparedRuntime: PreparedRuntime?
        if let previousRuntime {
            await performPublishedRuntimeSemanticStop()
            await previousRuntime.handle.closeAdmission()
            await closeAppServerRuntime(
                previousRuntime,
                purpose: .restartSameAccount
            )
        }
        guard isCurrentTransition(generation, purpose: .restartSameAccount) else {
            return
        }
        do {
            let runtime = try await backend.prepareRuntime(
                generation: generation,
                purpose: .restartSameAccount
            )
            preparedRuntime = runtime
            guard isCurrentTransition(generation, purpose: .restartSameAccount) else {
                await closeStaleRuntime(
                    runtime,
                    mcpServerWasPrepared: false,
                    purpose: .restartSameAccount
                )
                return
            }

            try await runtime.handle.activate()
            guard isCurrentTransition(generation, purpose: .restartSameAccount) else {
                await closeStaleRuntime(
                    runtime,
                    mcpServerWasPrepared: false,
                    purpose: .restartSameAccount
                )
                return
            }

            publishRuntimeSnapshot(runtime.snapshot)
            runtimeState = .running(
                generation: generation,
                runtime: runtime,
                mcpGeneration: retainedMCPGeneration
            )
            publishMCPServer(serverURL: retainedServerURL)
        } catch {
            if let preparedRuntime {
                await closeStaleRuntime(
                    preparedRuntime,
                    mcpServerWasPrepared: false,
                    purpose: .restartSameAccount
                )
            }
            guard isCurrentTransition(generation, purpose: .restartSameAccount) else {
                return
            }
            runtimeState = .failed(
                generation: generation,
                retainedMCPGeneration: retainedMCPGeneration,
                serverURL: retainedServerURL
            )
            serverURL = retainedServerURL
            serverState = .failed(error.localizedDescription)
            writeDiagnosticsIfNeeded()
        }
    }

    private func isCurrentAcquisition(
        _ generation: ReviewRuntimeGeneration
    ) -> Bool {
        guard case .acquiring(let currentGeneration, _) = runtimeState else {
            return false
        }
        return currentGeneration == generation
    }

    private func isCurrentTransition(
        _ generation: ReviewRuntimeGeneration,
        purpose: ReviewRuntimeTransitionPurpose
    ) -> Bool {
        guard case .transitioning(
            let currentGeneration,
            let currentPurpose,
            _
        ) = runtimeState else {
            return false
        }
        return currentGeneration == generation && currentPurpose == purpose
    }

    private var currentTransitionOwnsMCPStop: Bool {
        guard case .transitioning(_, let purpose, _) = runtimeState else {
            return false
        }
        return purpose == .stop || purpose == .applicationClose
    }

    private func closeStaleRuntime(
        _ runtime: PreparedRuntime,
        mcpServerWasPrepared: Bool,
        purpose: ReviewRuntimeTransitionPurpose
    ) async {
        await runtime.handle.closeAdmission()
        do {
            try await runtime.handle.close(purpose: purpose)
        } catch {
            writeDiagnosticsIfNeeded()
        }
        do {
            try await runtime.handle.waitUntilClosed()
        } catch {
            writeDiagnosticsIfNeeded()
        }
        if mcpServerWasPrepared, currentTransitionOwnsMCPStop == false {
            await stopPreparedMCPServer()
        }
    }

    private func stopPreparedMCPServer() async {
        do {
            try await backend.mcpServerLifecycle.stop()
        } catch {
            writeDiagnosticsIfNeeded()
        }
        do {
            try await backend.mcpServerLifecycle.waitUntilStopped()
        } catch {
            writeDiagnosticsIfNeeded()
        }
    }

    private func publishRuntimeSnapshot(_ snapshot: RuntimePublicationSnapshot) {
        settings.apply(snapshot: snapshot.settings)
        applyRuntimeAuthenticationSnapshot(snapshot.authentication)
    }

    private func publishMCPServer(serverURL: URL?) {
        transitionToRunning(serverURL: serverURL)
        startAccountRateLimitAutoRefresh()
    }

    private func applyRuntimeAuthenticationSnapshot(
        _ snapshot: CodexReviewBackendModel.Auth.Snapshot
    ) {
        let observedAccounts = snapshot.accounts.compactMap { account -> CodexAccount? in
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
        let activeAccountKey = snapshot.activeAccountID.map {
            CodexAccount.normalizedEmail($0.rawValue)
        }
        var accounts = auth.persistedAccounts
        for observedAccount in observedAccounts {
            if let index = accounts.firstIndex(where: {
                $0.accountKey == observedAccount.accountKey
            }) {
                accounts[index].updateEmail(observedAccount.email)
                accounts[index].updateKind(
                    observedAccount.kind,
                    capabilities: observedAccount.capabilities
                )
                accounts[index].updatePlanType(observedAccount.planType)
            } else {
                accounts.insert(observedAccount, at: 0)
            }
        }
        auth.applyPersistedAccountStates(
            accounts.map(savedAccountPayload(from:)),
            activeAccountKey: activeAccountKey
        )
        auth.selectPersistedAccount(activeAccountKey)
        auth.updatePhase(.signedOut)
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
