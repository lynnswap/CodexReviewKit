import AppKit
import CryptoKit
import Darwin
import Foundation
import OSLog
import CodexAppServerKit
import CodexDataKit
import CodexReviewKit
import CodexReviewAppServer
import CodexReviewMCPServer

private let logger = Logger(subsystem: "CodexReviewKit", category: "live-store-backend")
package typealias ExternalURLOpener = @MainActor @Sendable (URL) async throws -> Void
public typealias CodexReviewAppServerLifecycleHandler = @MainActor @Sendable (CodexModelContainer?) -> Void

private let defaultExternalURLOpener: ExternalURLOpener = { url in
    try await withCheckedThrowingContinuation { continuation in
        NSWorkspace.shared.open(
            url,
            configuration: .init()
        ) { _, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
}

private enum RuntimeReviewCleanupMode {
    case connected
    case connectionTerminated
}

package struct CodexReviewMCPPortOwner: Equatable, Sendable {
    package var processIdentifier: Int32
    package var command: String?

    package init(processIdentifier: Int32, command: String? = nil) {
        self.processIdentifier = processIdentifier
        self.command = command
    }
}

package typealias CodexReviewMCPPortOwnerResolver = @MainActor @Sendable (
    CodexReviewMCPHTTPServer.Configuration
) async -> CodexReviewMCPPortOwner?

package typealias CodexReviewMCPHTTPServerBindChecker = @MainActor @Sendable (
    CodexReviewMCPHTTPServer.Configuration
) async throws -> Void

package protocol CodexReviewMCPHTTPServing: AnyObject, Sendable {
    var url: URL { get async }

    func start() async throws
    func stage() async throws
    func activate() async
    func stop() async
}

extension CodexReviewMCPHTTPServing {
    package func stage() async throws {
        try await start()
    }

    package func activate() async {}
}

extension CodexReviewMCPHTTPServer: CodexReviewMCPHTTPServing {}

@MainActor
public extension CodexReviewStore {
    static func makeLiveStore(
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        appServerLifecycleHandler: CodexReviewAppServerLifecycleHandler? = nil
    ) -> CodexReviewStore {
        CodexReviewStore(backend: LiveCodexReviewStoreBackend(
            runtimePreferences: runtimePreferences,
            appServerLifecycleHandler: appServerLifecycleHandler
        ))
    }

    package static func makeLiveStoreForTesting(
        environment: [String: String],
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        externalURLOpener: @escaping ExternalURLOpener = defaultExternalURLOpener,
        mcpPortOwnerResolver: CodexReviewMCPPortOwnerResolver? = nil,
        mcpHTTPServerBindChecker: CodexReviewMCPHTTPServerBindChecker? = nil,
        networkMonitor: any CodexReviewNetworkMonitoring = SystemCodexReviewNetworkMonitor(),
        networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy = .default,
        appServer: CodexAppServer,
        appServerLifecycleHandler: CodexReviewAppServerLifecycleHandler? = nil
    ) -> CodexReviewStore {
        makeLiveStoreForTesting(
            environment: environment,
            runtimePreferences: runtimePreferences,
            externalURLOpener: externalURLOpener,
            mcpPortOwnerResolver: mcpPortOwnerResolver,
            mcpHTTPServerBindChecker: mcpHTTPServerBindChecker,
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: networkRecoveryPolicy,
            appServerLifecycleHandler: appServerLifecycleHandler,
            appServerFactory: { _ in appServer }
        )
    }

    package static func makeLiveStoreForTesting(
        environment: [String: String],
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        externalURLOpener: @escaping ExternalURLOpener = defaultExternalURLOpener,
        mcpHTTPServerFactory: (@MainActor @Sendable (
            CodexReviewStore,
            CodexReviewMCPHTTPServer.Configuration,
            ReviewMCPLogProjectionProvider?
        ) -> any CodexReviewMCPHTTPServing)? = nil,
        mcpPortOwnerResolver: CodexReviewMCPPortOwnerResolver? = nil,
        mcpHTTPServerBindChecker: CodexReviewMCPHTTPServerBindChecker? = nil,
        networkMonitor: any CodexReviewNetworkMonitoring = SystemCodexReviewNetworkMonitor(),
        networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy = .default,
        appServerLifecycleHandler: CodexReviewAppServerLifecycleHandler? = nil,
        appServerFactory: @escaping @MainActor @Sendable (URL) async throws -> CodexAppServer
    ) -> CodexReviewStore {
        CodexReviewStore(
            backend: LiveCodexReviewStoreBackend(
                environment: environment,
                runtimePreferences: runtimePreferences,
                externalURLOpener: externalURLOpener,
                mcpHTTPServerFactory: mcpHTTPServerFactory,
                mcpPortOwnerResolver: mcpPortOwnerResolver,
                mcpHTTPServerBindChecker: mcpHTTPServerBindChecker,
                appServerLifecycleHandler: appServerLifecycleHandler,
                appServerRuntimeFactory: { codexHomeURL in
                    let appServer = try await appServerFactory(codexHomeURL)
                    let modelContainer = CodexModelContainer(appServer: appServer)
                    return .init(
                        appServer: appServer,
                        modelContainer: modelContainer,
                        backend: AppServerCodexReviewBackend(
                            modelContainer: modelContainer
                        )
                    )
                }
            ),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: networkRecoveryPolicy
        )
    }
}

@MainActor
private final class LiveCodexReviewStoreBackend: CodexReviewStoreBackend {
    typealias MCPHTTPServerFactory = @MainActor @Sendable (
        CodexReviewStore,
        CodexReviewMCPHTTPServer.Configuration,
        ReviewMCPLogProjectionProvider?
    ) -> any CodexReviewMCPHTTPServing

    let seed: CodexReviewStoreSeed

    private var appServer: CodexAppServer?
    private var appServerModelContainer: CodexModelContainer?
    private var appServerBackend: AppServerCodexReviewBackend?
    private var mcpHTTPServer: (any CodexReviewMCPHTTPServing)?
    private var loginSession: LoginSession?
    private var authNotificationTask: Task<Void, Never>?
    private var settingsSnapshot = CodexReviewSettings.Snapshot()
    private let codexHomeURL: URL
    private let mcpHTTPServerConfiguration: CodexReviewMCPHTTPServer.Configuration
    private let externalURLOpener: ExternalURLOpener
    private let mcpHTTPServerFactory: MCPHTTPServerFactory?
    private let mcpPortOwnerResolver: CodexReviewMCPPortOwnerResolver
    private let mcpHTTPServerBindChecker: CodexReviewMCPHTTPServerBindChecker
    private let appServerRuntimeFactory: AppServerRuntimeFactory
    private let accountRegistry: AccountRegistryStore
    private let accountRuntimeTransitionCoordinator: AccountRuntimeTransitionCoordinator
    private let registryLoadFailure: CodexReviewAuthenticationFailure?
    private let appServerLifecycleHandler: CodexReviewAppServerLifecycleHandler?
    private weak var attachedStore: CodexReviewStore?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        externalURLOpener: @escaping ExternalURLOpener = defaultExternalURLOpener,
        mcpHTTPServerFactory: MCPHTTPServerFactory? = { store, configuration, logProjectionProvider in
            CodexReviewMCPHTTPServer(
                adapter: CodexReviewMCPServer(
                    store: store,
                    logProjectionProvider: logProjectionProvider
                ),
                configuration: configuration
            )
        },
        mcpPortOwnerResolver: CodexReviewMCPPortOwnerResolver? = nil,
        mcpHTTPServerBindChecker: CodexReviewMCPHTTPServerBindChecker? = nil,
        appServerLifecycleHandler: CodexReviewAppServerLifecycleHandler? = nil,
        appServerRuntimeFactory: AppServerRuntimeFactory? = nil
    ) {
        let runtimePreferences = runtimePreferences.normalized
        codexHomeURL = Self.codexHomeURL(
            runtimePreferences: runtimePreferences,
            environment: environment
        )
        accountRegistry = AccountRegistryStore(codexHomeURL: codexHomeURL)
        accountRuntimeTransitionCoordinator = AccountRuntimeTransitionCoordinator()
        self.mcpHTTPServerConfiguration = .init(
            host: runtimePreferences.mcpHost,
            port: runtimePreferences.mcpPort,
            endpoint: runtimePreferences.mcpPath
        )
        self.externalURLOpener = externalURLOpener
        self.mcpHTTPServerFactory = mcpHTTPServerFactory
        self.mcpPortOwnerResolver = mcpPortOwnerResolver ?? Self.defaultMCPPortOwnerResolver
        self.mcpHTTPServerBindChecker = mcpHTTPServerBindChecker ?? Self.defaultMCPHTTPServerBindChecker
        self.appServerLifecycleHandler = appServerLifecycleHandler
        self.appServerRuntimeFactory = appServerRuntimeFactory ?? Self.makeAppServerRuntimeFactory(
            codexExecutablePath: runtimePreferences.codexExecutablePath
        )
        let registry: AccountRegistryStore.Snapshot
        do {
            registry = try AccountRegistryStore.loadInitialSnapshot(codexHomeURL: codexHomeURL)
            registryLoadFailure = nil
        } catch let failure as CodexReviewAuthenticationFailure {
            registry = .init(accounts: [], activeAccountKey: nil)
            registryLoadFailure = failure
        } catch {
            registry = .init(accounts: [], activeAccountKey: nil)
            registryLoadFailure = .persistenceInconsistent(message: error.localizedDescription)
        }
        seed = CodexReviewStoreSeed(
            shouldAutoStartEmbeddedServer: true,
            initialAccounts: registry.accounts.map(makeCodexReviewAccount(from:)),
            initialActiveAccountKey: registry.activeAccountKey
        )
    }

    var isActive: Bool {
        appServer != nil
    }

    var reviewThreadRetentionCodexHomePath: String {
        codexHomeURL.path
    }

    var reviewThreadRetentionJournalURL: URL? {
        codexHomeURL.appendingPathComponent("review-thread-retention.json", isDirectory: false)
    }

    var invokesRuntimeStopReviewCleanupDuringStop: Bool {
        true
    }

    var initialSettingsSnapshot: CodexReviewSettings.Snapshot {
        settingsSnapshot
    }

    private static func codexHomeURL(
        runtimePreferences: CodexReviewRuntime.Preferences,
        environment: [String: String]
    ) -> URL {
        if let codexHomePath = runtimePreferences.codexHomePath {
            return URL(fileURLWithPath: codexHomePath, isDirectory: true)
        }
        return defaultCodexReviewHomeURL(environment: environment)
    }

    private static func defaultCodexReviewHomeURL(
        environment: [String: String],
        homeDirectoryForCurrentUser: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    ) -> URL {
        if let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           codexHome.isEmpty == false {
            return URL(fileURLWithPath: codexHome, isDirectory: true)
        }
        if let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           home.isEmpty == false {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".codex_review", isDirectory: true)
        }
        if let applicationSupportDirectory {
            return applicationSupportDirectory
                .appendingPathComponent("CodexReviewMonitor", isDirectory: true)
        }
        return homeDirectoryForCurrentUser
            .appendingPathComponent(".codex_review", isDirectory: true)
    }

    private static func defaultMCPPortOwnerResolver(
        configuration: CodexReviewMCPHTTPServer.Configuration
    ) async -> CodexReviewMCPPortOwner? {
        await Task.detached(priority: .utility) {
            guard configuration.port > 0,
                  let lsofOutput = runProcess(
                    executable: "/usr/sbin/lsof",
                    arguments: [
                        "-nP",
                        "-iTCP:\(configuration.port)",
                        "-sTCP:LISTEN",
                        "-Fp",
                    ]
                  ),
                  let processIdentifier = parseLsofProcessIdentifier(from: lsofOutput)
            else {
                return nil
            }
            let command = runProcess(
                executable: "/bin/ps",
                arguments: [
                    "-p",
                    "\(processIdentifier)",
                    "-o",
                    "comm=",
                ]
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            return CodexReviewMCPPortOwner(
                processIdentifier: processIdentifier,
                command: command?.isEmpty == false ? command : nil
            )
        }.value
    }

    private nonisolated static func parseLsofProcessIdentifier(from output: String) -> Int32? {
        output.split(whereSeparator: \.isNewline).lazy.compactMap { line -> Int32? in
            guard line.first == "p" else {
                return nil
            }
            return Int32(String(line.dropFirst()))
        }.first
    }

    private nonisolated static func runProcess(executable: String, arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return nil
        }
        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errorOutput

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static func defaultMCPHTTPServerBindChecker(
        configuration: CodexReviewMCPHTTPServer.Configuration
    ) async throws {
        try await CodexReviewMCPHTTPServer.checkBind(configuration: configuration)
    }

    private static func makeAppServerRuntimeFactory(
        codexExecutablePath: String?
    ) -> AppServerRuntimeFactory {
        { codexHomeURL in
            let appServer = try await Task.detached(priority: .userInitiated) {
                // The configuration probe can wait on `codex app-server --help`; keep it off the MainActor.
                try await CodexAppServer(configuration: .init(
                    localProcess: .init(
                        executable: codexExecutablePath,
                        codexHomeURL: codexHomeURL
                    )
                ))
            }.value
            let modelContainer = CodexModelContainer(appServer: appServer)
            return .init(
                appServer: appServer,
                modelContainer: modelContainer,
                backend: AppServerCodexReviewBackend(
                    modelContainer: modelContainer
                )
            )
        }
    }

    func attachStore(_ store: CodexReviewStore) {
        attachedStore = store
    }

    func start(store: CodexReviewStore, forceRestartIfNeeded: Bool) async {
        logger.info("Starting review runtime; forceRestartIfNeeded=\(forceRestartIfNeeded, privacy: .public)")
        if let registryLoadFailure {
            store.auth.updatePhase(.failed(registryLoadFailure))
            store.transitionToFailed(registryLoadFailure.localizedDescription)
            return
        }
        if appServerBackend != nil, forceRestartIfNeeded == false {
            logger.info("Review runtime already has an app-server backend")
            store.transitionToRunning(serverURL: await mcpHTTPServer?.url)
            return
        }
        if forceRestartIfNeeded {
            await stop(store: store, purpose: .runtimeRestartPreservingRuns)
        }

        var startedAppServer: CodexAppServer?
        var startedHTTPServer: (any CodexReviewMCPHTTPServing)?
        do {
            if mcpHTTPServerFactory != nil {
                try await mcpHTTPServerBindChecker(mcpHTTPServerConfiguration)
            }
            let runtime = try await appServerRuntimeFactory(codexHomeURL)
            let appServer = runtime.appServer
            let backend = runtime.backend
            let modelContainer = runtime.modelContainer
            startedAppServer = appServer
            self.appServer = appServer
            self.appServerModelContainer = modelContainer
            self.appServerBackend = backend
            appServerLifecycleHandler?(modelContainer)
            await observeAuthNotifications(appServer: appServer, backend: backend, store: store)
            if let mcpHTTPServerFactory {
                let logProjectionProvider = CodexReviewMCPServer.chatLogProjectionProvider(
                    modelContext: modelContainer.mainContext
                )
                let mcpHTTPServer = mcpHTTPServerFactory(
                    store,
                    mcpHTTPServerConfiguration,
                    logProjectionProvider
                )
                try await mcpHTTPServer.stage()
                startedHTTPServer = mcpHTTPServer
                self.mcpHTTPServer = mcpHTTPServer
            }
            let authSnapshot = try await backend.readAuth()
            try await applyAuthSnapshotSerialized(authSnapshot, to: store.auth)
            switch await store.recoverOrphanedReviewThreads() {
            case .recovered, .cleanupIncomplete:
                break
            case .journalUnavailable(let message):
                throw ReviewBackendFailure.retentionJournal(message: message)
            }
            store.transitionToRunning(serverURL: await self.mcpHTTPServer?.url)
            await self.mcpHTTPServer?.activate()
            await refreshSelectedAccountRateLimits(auth: store.auth)
            logger.info("Review runtime started")
        } catch {
            let failureMessage = await runtimeStartupFailureMessage(for: error)
            logger.error("Review runtime failed to start: \(failureMessage, privacy: .public)")
            await startedHTTPServer?.stop()
            await startedAppServer?.close()
            self.appServer = nil
            clearAppServerModelContainer()
            self.appServerBackend = nil
            self.mcpHTTPServer = nil
            authNotificationTask?.cancel()
            authNotificationTask = nil
            store.transitionToFailed(failureMessage)
        }
    }

    private func runtimeStartupFailureMessage(for error: Error) async -> String {
        if let mcpHTTPServerError = error as? CodexReviewMCPHTTPServer.Error {
            switch mcpHTTPServerError {
            case .addressInUse:
                return await mcpAddressInUseMessage()
            }
        }
        return error.localizedDescription
    }

    private func mcpAddressInUseMessage() async -> String {
        let endpoint = mcpHTTPServerConfiguration.url()
        var message = "MCP endpoint \(endpoint.absoluteString) is already in use"
        if let owner = await mcpPortOwnerResolver(mcpHTTPServerConfiguration) {
            message += " by PID \(owner.processIdentifier)"
            if let command = owner.command?.trimmingCharacters(in: .whitespacesAndNewlines),
               command.isEmpty == false
            {
                message += " (\(command))"
            }
        }
        message += ". Quit that process or change the MCP port in Settings, then reset the server."
        return message
    }

    private func cleanupActiveReviewsForRuntimeTeardown(
        store: CodexReviewStore,
        appServerBackend: AppServerCodexReviewBackend,
        reason: ReviewCancellation,
        mode: RuntimeReviewCleanupMode
    ) async {
        let cleanupResult = await store.cleanupActiveReviewsForRuntimeStop(reason: reason) { request in
            switch mode {
            case .connected:
                await appServerBackend.cleanupActiveReviewsForShutdown(request)
                return true
            case .connectionTerminated:
                await appServerBackend.cleanupActiveReviewsAfterConnectionTermination(request)
                return true
            }
        }
        precondition(cleanupResult.didComplete, "Runtime teardown must drain backend cleanup and review workers.")
    }

    func stop(store: CodexReviewStore, purpose: CodexReviewRuntimeStopPurpose) async {
        let appServer = appServer
        let appServerBackend = appServerBackend
        let mcpHTTPServer = mcpHTTPServer
        let hasRuntimeState = appServer != nil || appServerBackend != nil || mcpHTTPServer != nil
        let loginSession = self.loginSession
        guard hasRuntimeState || loginSession != nil else {
            if purpose.retiresRuns {
                _ = await store.retireReviewRunsForFinalStoreStop()
            }
            return
        }
        logger.info("Stopping review runtime")
        await mcpHTTPServer?.stop()
        self.mcpHTTPServer = nil
        if let appServerBackend {
            let reason = ReviewCancellation.system(message: "Review runtime stopped.")
            await cleanupActiveReviewsForRuntimeTeardown(
                store: store,
                appServerBackend: appServerBackend,
                reason: reason,
                mode: .connected
            )
        }
        _ = await loginSession?.terminate(reason: .storeStop)
        if purpose.retiresRuns {
            guard await store.retireReviewRunsForFinalStoreStop() else {
                logger.error("Review runtime remains open because an unpersisted cleanup quarantine is unresolved")
                return
            }
        }
        self.appServer = nil
        clearAppServerModelContainer()
        authNotificationTask?.cancel()
        authNotificationTask = nil
        self.appServerBackend = nil
        await appServer?.close()
        logger.info("Review runtime stopped")
    }

    func waitUntilStopped() async {}

    func refreshSettings() async throws -> CodexReviewSettings.Snapshot {
        guard let appServerBackend else {
            return settingsSnapshot
        }
        settingsSnapshot = try await Self.monitorSettings(from: appServerBackend.readSettings())
        return settingsSnapshot
    }

    func updateSettingsModel(
        _ model: String?,
        reasoningEffort: CodexReviewSettings.ReasoningEffort?,
        persistReasoningEffort: Bool,
        serviceTier: CodexReviewSettings.ServiceTier?,
        persistServiceTier: Bool
    ) async throws {
        guard let appServerBackend else {
            return
        }
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
        settingsSnapshot = try await Self.monitorSettings(from: appServerBackend.applySettings(change))
    }

    func updateSettingsReasoningEffort(
        _ reasoningEffort: CodexReviewSettings.ReasoningEffort?
    ) async throws {
        guard let appServerBackend else {
            return
        }
        settingsSnapshot = try await Self.monitorSettings(
            from: appServerBackend.applySettings(.init(
                reasoningEffort: reasoningEffort?.rawValue,
                updatesReasoningEffort: true
            ))
        )
    }

    func updateSettingsServiceTier(
        _ serviceTier: CodexReviewSettings.ServiceTier?
    ) async throws {
        guard let appServerBackend else {
            return
        }
        settingsSnapshot = try await Self.monitorSettings(
            from: appServerBackend.applySettings(.init(
                serviceTier: serviceTier?.rawValue,
                updatesServiceTier: true
            ))
        )
    }

    func refreshAuth(auth: CodexReviewAuthModel) async {
        do {
            guard let appServerBackend else {
                auth.updatePhase(.signedOut)
                return
            }
            let snapshot = try await appServerBackend.readAuth()
            try await applyAuthSnapshot(snapshot, to: auth)
        } catch {
            auth.updatePhase(.failed(.runtime(message: error.localizedDescription)))
        }
    }

    func signIn(auth: CodexReviewAuthModel) async throws {
        try await attachedStore?.requireReviewThreadRetentionAcceptance()
        try await beginStockLogin(auth: auth, purpose: .signIn)
    }

    func addAccount(auth: CodexReviewAuthModel) async throws {
        try await attachedStore?.requireReviewThreadRetentionAcceptance()
        let activeAccountKey = auth.persistedActiveAccountKey ?? auth.selectedAccount?.accountKey
        try await beginStockLogin(
            auth: auth,
            purpose: activeAccountKey != nil
                ? .addAccountPreservingActive(activeAccountKey)
                : .signIn
        )
    }

    func cancelAuthentication(auth: CodexReviewAuthModel) async {
        guard let session = loginSession else {
            if auth.selectedAccount == nil {
                auth.updatePhase(.signedOut)
            }
            return
        }
        _ = await session.terminate(reason: .explicitCancellation)
    }

    func switchAccount(auth: CodexReviewAuthModel, accountKey: String) async throws {
        try await attachedStore?.requireReviewThreadRetentionAcceptance()
        try await withAccountMutation {
        guard auth.persistedAccounts.contains(where: { $0.accountKey == accountKey }) else {
            return
        }
        try await accountRegistry.activateAccount(
            accountKey,
            accounts: auth.persistedAccounts.map(savedAccountPayload(from:))
        )
        auth.applyPersistedAccountStates(
            auth.persistedAccounts.map(savedAccountPayload(from:)),
            activeAccountKey: accountKey
        )
        auth.selectPersistedAccount(auth.persistedAccounts.first(where: { $0.accountKey == accountKey })?.id)
        auth.updatePhase(.signedOut)
        guard let attachedStore, appServerBackend != nil else {
            return
        }
        await attachedStore.closeActiveReviewSessions(
            reason: .system(message: "Account switched.")
        )
        await stop(store: attachedStore, purpose: .accountTransitionPreservingRuns)
        await start(store: attachedStore, forceRestartIfNeeded: true)
        }
    }

    func removeAccount(auth: CodexReviewAuthModel, accountKey: String) async throws {
        try await attachedStore?.requireReviewThreadRetentionAcceptance()
        try await withAccountMutation {
        let removedActiveAccount = auth.selectedAccount?.accountKey == accountKey
            || auth.persistedActiveAccountKey == accountKey
        let remaining = auth.persistedAccounts.filter { $0.accountKey != accountKey }
        let activeAccountKey = auth.persistedActiveAccountKey == accountKey
            ? nil
            : auth.persistedActiveAccountKey
        if removedActiveAccount {
            let prepared = try await accountRegistry.prepareIrreversibleRemoval(
                accounts: remaining.map(savedAccountPayload(from:)),
                activeAccountKey: activeAccountKey
            )
            do {
                if let appServerBackend {
                    _ = try await appServerBackend.logout(.init(accountKey))
                }
                try await accountRegistry.commitPreparedMutation(prepared)
            } catch {
                try await abortPreparedAccountMutation(prepared, after: error)
            }
        } else {
            try await accountRegistry.saveAccounts(
                remaining.map(savedAccountPayload(from:)),
                activeAccountKey: activeAccountKey
            )
        }
        try await accountRegistry.removeSavedAccountDirectory(accountKey: accountKey)
        auth.applyPersistedAccountStates(
            remaining.map(savedAccountPayload(from:)),
            activeAccountKey: activeAccountKey
        )
        if removedActiveAccount {
            auth.selectPersistedAccount(nil)
            auth.updatePhase(.signedOut)
            guard let attachedStore, appServerBackend != nil else {
                return
            }
            await attachedStore.closeActiveReviewSessions(
                reason: .system(message: "Account removed.")
            )
            await stop(store: attachedStore, purpose: .accountTransitionPreservingRuns)
            await start(store: attachedStore, forceRestartIfNeeded: true)
        }
        }
    }

    func reorderPersistedAccount(
        auth: CodexReviewAuthModel,
        accountKey: String,
        toIndex: Int
    ) async throws {
        try await withAccountMutation {
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
        try await accountRegistry.saveAccounts(
            accounts.map(savedAccountPayload(from:)),
            activeAccountKey: auth.persistedActiveAccountKey
        )
        auth.applyPersistedAccountStates(accounts.map(savedAccountPayload(from:)))
        }
    }

    func signOutActiveAccount(auth: CodexReviewAuthModel) async throws {
        try await attachedStore?.requireReviewThreadRetentionAcceptance()
        try await withAccountMutation {
        guard let account = auth.selectedAccount else {
            auth.updatePhase(.signedOut)
            auth.selectPersistedAccount(nil)
            return
        }
        let shouldRecycleRuntime = attachedStore != nil && appServerBackend != nil
        if shouldRecycleRuntime {
            await attachedStore?.closeActiveReviewSessions(
                reason: .system(message: "Signed out.")
            )
        }
        let remaining = auth.persistedAccounts.filter { $0.accountKey != account.accountKey }
        let prepared = try await accountRegistry.prepareIrreversibleRemoval(
            accounts: remaining.map(savedAccountPayload(from:)),
            activeAccountKey: nil
        )
        do {
            if let appServerBackend {
                _ = try await appServerBackend.logout(.init(account.accountKey))
            }
            try await accountRegistry.commitPreparedMutation(prepared)
        } catch {
            try await abortPreparedAccountMutation(prepared, after: error)
        }
        try await accountRegistry.removeSavedAccountDirectory(accountKey: account.accountKey)
        auth.updatePhase(.signedOut)
        auth.selectPersistedAccount(nil)
        auth.applyPersistedAccountStates(remaining.map(savedAccountPayload(from:)), activeAccountKey: nil)
        if shouldRecycleRuntime, let attachedStore {
            await stop(store: attachedStore, purpose: .accountTransitionPreservingRuns)
            await start(store: attachedStore, forceRestartIfNeeded: true)
        }
        }
    }

    func refreshAccountRateLimits(auth: CodexReviewAuthModel, accountKey: String) async {
        guard let account = auth.accounts.first(where: { $0.accountKey == accountKey }) else {
            return
        }
        await refreshRateLimits(for: account, auth: auth)
    }

    func requiresCurrentSessionRecovery(auth _: CodexReviewAuthModel, accountKey _: String) -> Bool {
        false
    }

    private func withAccountMutation<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        try await accountRuntimeTransitionCoordinator.perform {
            let lease = try await accountRegistry.beginAccountMutation()
            do {
                let result = try await operation()
                await accountRegistry.finishMutation(lease)
                return result
            } catch {
                await accountRegistry.finishMutation(lease)
                throw error
            }
        }
    }

    private func abortPreparedAccountMutation(
        _ mutation: AccountRegistryStore.PreparedMutation,
        after originalError: any Error
    ) async throws -> Never {
        do {
            try await accountRegistry.abortPreparedMutation(mutation)
        } catch {
            throw CodexReviewAuthenticationFailure.accountCommit(
                message: "Account mutation failed and its durable journal could not be reconciled. "
                    + "Original failure: \(originalError.localizedDescription). "
                    + "Recovery failure: \(error.localizedDescription)"
            )
        }
        throw originalError
    }

    private func beginStockLogin(
        auth: CodexReviewAuthModel,
        purpose: LoginPurpose
    ) async throws {
        guard loginSession == nil else {
            throw CodexReviewAuthenticationFailure.alreadyInProgress
        }
        let mutationLease = try await accountRegistry.beginAuthenticationMutation()
        var runtimeRequiringCleanup: LoginRuntime?
        var mutationLeaseRequiringRelease: AccountRegistryStore.MutationLease? = mutationLease
        var sessionOwnsFailurePublication = false
        do {
            let runtime = try await loginRuntime(for: purpose)
            runtimeRequiringCleanup = runtime
            let handle = try await runtime.appServer.loginChatGPT(
                accountReadinessTimeout: .seconds(10)
            )
            let generationID = UUID()
            let session = LoginSession(
                generationID: generationID,
                purpose: purpose,
                handle: handle,
                runtime: runtime,
                mutationLease: mutationLease,
                rootOperation: { @MainActor [weak self] in
                    let observation: LoginRootObservation
                    do {
                        observation = .outcome(try await handle.result())
                    } catch is CancellationError {
                        observation = .waiterCancelled(message: nil)
                    } catch {
                        observation = .failure(
                            .runtime(message: error.localizedDescription)
                        )
                    }
                    self?.publishLoginRootObservation(
                        observation,
                        generationID: generationID,
                        handleID: handle.id
                    )
                    return observation
                },
                terminationHandler: { @MainActor [weak self, auth] session, reason, observation in
                    guard let self else {
                        return .stopped
                    }
                    return await self.finishLoginSession(
                        session,
                        reason: reason,
                        observation: observation,
                        auth: auth
                    )
                }
            )
            loginSession = session
            runtimeRequiringCleanup = nil
            mutationLeaseRequiringRelease = nil
            sessionOwnsFailurePublication = true
            auth.updatePhase(.signingIn(.init(
                title: "Sign in to Codex",
                detail: "Continue signing in with your browser.",
                browserURL: handle.authenticationURL.absoluteString,
                userCode: nil
            )))
            session.activate()
            do {
                try await externalURLOpener(handle.authenticationURL)
            } catch {
                let failure = CodexReviewAuthenticationFailure.urlOpen(handle.authenticationURL)
                let terminal = await session.terminate(reason: .urlOpenFailure(failure))
                switch terminal {
                case .succeeded:
                    return
                case .failed(let terminalFailure):
                    throw terminalFailure
                case .cancelled, .stopped:
                    return
                }
            }
        } catch {
            await closeLoginRuntime(runtimeRequiringCleanup)
            if let mutationLeaseRequiringRelease {
                await accountRegistry.finishMutation(mutationLeaseRequiringRelease)
            }
            let failure = (error as? CodexReviewAuthenticationFailure)
                ?? .runtime(message: error.localizedDescription)
            if sessionOwnsFailurePublication == false {
                auth.updatePhase(.failed(failure))
            }
            if case .addAccountPreservingActive = purpose {
                throw failure
            }
        }
    }

    private func publishLoginRootObservation(
        _ observation: LoginRootObservation,
        generationID: UUID,
        handleID: CodexLoginHandle.ID
    ) {
        guard let session = loginSession,
              session.generationID == generationID,
              session.handle.id == handleID else {
            return
        }
        session.publishRootObservation(observation)
    }

    private func finishLoginSession(
        _ session: LoginSession,
        reason: LoginTerminationReason,
        observation: LoginRootObservation,
        auth: CodexReviewAuthModel
    ) async -> LoginSessionTerminal {
        let terminal: LoginSessionTerminal
        switch observation {
        case .outcome(let outcome):
            terminal = await finishLoginOutcome(
                outcome,
                session: session,
                reason: reason,
                auth: auth
            )
        case .failure(let failure):
            auth.updatePhase(.failed(failure))
            terminal = .failed(failure)
        case .waiterCancelled(let message):
            terminal = finishCancelledLoginWaiter(
                session: session,
                reason: reason,
                message: message,
                auth: auth
            )
        }

        await closeLoginRuntimeIfNeeded(session)
        await releaseLoginMutationIfNeeded(session)
        clearLoginSessionIfCurrent(session)
        return terminal
    }

    private func finishLoginOutcome(
        _ outcome: CodexLoginOutcome,
        session: LoginSession,
        reason terminationReason: LoginTerminationReason,
        auth: CodexReviewAuthModel
    ) async -> LoginSessionTerminal {
        switch outcome {
        case .succeeded:
            return await finishSuccessfulLogin(session: session, auth: auth)
        case .failed(let message):
            let failure = CodexReviewAuthenticationFailure.login(
                message: message ?? "Authentication failed."
            )
            auth.updatePhase(.failed(failure))
            return .failed(failure)
        case .cancelled:
            return finishCancelledLoginOutcome(
                reason: terminationReason,
                auth: auth
            )
        case .authenticationCommittedNeedsConnectionReconciliation(let reconciliationReason):
            if case .signIn = session.purpose,
               sessionAllowsPrimaryReconciliation(terminationReason: terminationReason)
            {
                return await reconcilePrimaryAuthentication(
                    session: session,
                    reason: reconciliationReason,
                    auth: auth
                )
            }
            let failure = terminationFailure(
                for: terminationReason,
                fallback: .login(
                    message: "Authentication requires runtime reconciliation: \(String(describing: reconciliationReason))"
                )
            )
            if let failure {
                auth.updatePhase(.failed(failure))
                return .failed(failure)
            }
            if auth.selectedAccount == nil {
                auth.updatePhase(.signedOut)
            }
            return .stopped
        }
    }

    private func finishSuccessfulLogin(
        session: LoginSession,
        auth: CodexReviewAuthModel
    ) async -> LoginSessionTerminal {
        var stagingURLRequiringRemoval: URL?
        defer {
            if let stagingURLRequiringRemoval {
                try? FileManager.default.removeItem(at: stagingURLRequiringRemoval)
            }
        }
        do {
            let snapshot = try await session.runtime.backend.readAuth()
            let isolatedRateLimits: CodexRateLimits?
            if session.runtime.usesPrimaryRuntime == false {
                isolatedRateLimits = try? await session.runtime.backend.readRateLimits()
                guard let runtime = session.takeOwnedRuntimeForClose() else {
                    preconditionFailure("An isolated login runtime can be closed only once.")
                }
                await runtime.appServer.close()
                stagingURLRequiringRemoval = runtime.codexHomeURL
            } else {
                isolatedRateLimits = nil
            }
            let account = try await applyAuthSnapshot(
                snapshot,
                to: auth,
                activation: session.purpose.activation,
                authSourceCodexHomeURL: session.runtime.codexHomeURL
            )
            if session.runtime.usesPrimaryRuntime == false {
                if let account, let isolatedRateLimits {
                    applyRateLimits(isolatedRateLimits, to: account)
                    try await accountRegistry.updateCachedRateLimits(
                        from: savedAccountPayload(from: account)
                    )
                }
            } else {
                await refreshSelectedAccountRateLimits(auth: auth)
            }
            return .succeeded
        } catch let failure as CodexReviewAuthenticationFailure {
            auth.updatePhase(.failed(failure))
            return .failed(failure)
        } catch {
            let failure = CodexReviewAuthenticationFailure.login(
                message: error.localizedDescription
            )
            auth.updatePhase(.failed(failure))
            return .failed(failure)
        }
    }

    private func finishCancelledLoginOutcome(
        reason: LoginTerminationReason,
        auth: CodexReviewAuthModel
    ) -> LoginSessionTerminal {
        switch reason {
        case .urlOpenFailure(let failure), .runtimeFailure(let failure):
            auth.updatePhase(.failed(failure))
            return .failed(failure)
        case .storeStop:
            auth.updatePhase(.signedOut)
            return .stopped
        case .rootOutcome, .explicitCancellation:
            auth.updatePhase(.signedOut)
            return .cancelled
        }
    }

    private func finishCancelledLoginWaiter(
        session _: LoginSession,
        reason: LoginTerminationReason,
        message: String?,
        auth: CodexReviewAuthModel
    ) -> LoginSessionTerminal {
        finishLoginWaiterFailure(
            reason: reason,
            message: message ?? "Authentication cancellation failed.",
            auth: auth
        )
    }

    private func finishLoginWaiterFailure(
        reason: LoginTerminationReason,
        message: String,
        auth: CodexReviewAuthModel
    ) -> LoginSessionTerminal {
        switch reason {
        case .rootOutcome:
            let failure = CodexReviewAuthenticationFailure.login(message: message)
            auth.updatePhase(.failed(failure))
            return .failed(failure)
        case .explicitCancellation:
            let failure = CodexReviewAuthenticationFailure.runtime(message: message)
            auth.updatePhase(.failed(failure))
            return .failed(failure)
        case .urlOpenFailure(let failure), .runtimeFailure(let failure):
            auth.updatePhase(.failed(failure))
            return .failed(failure)
        case .storeStop:
            auth.updatePhase(.signedOut)
            return .stopped
        }
    }

    private func terminationFailure(
        for reason: LoginTerminationReason,
        fallback: CodexReviewAuthenticationFailure
    ) -> CodexReviewAuthenticationFailure? {
        switch reason {
        case .rootOutcome:
            return nil
        case .explicitCancellation:
            return fallback
        case .urlOpenFailure(let failure), .runtimeFailure(let failure):
            return failure
        case .storeStop:
            return nil
        }
    }

    private func sessionAllowsPrimaryReconciliation(
        terminationReason: LoginTerminationReason
    ) -> Bool {
        switch terminationReason {
        case .rootOutcome, .explicitCancellation, .urlOpenFailure:
            return true
        case .runtimeFailure, .storeStop:
            return false
        }
    }

    private func reconcilePrimaryAuthentication(
        session: LoginSession,
        reason: CodexLoginReconciliationReason,
        auth: CodexReviewAuthModel
    ) async -> LoginSessionTerminal {
        guard detachLoginSessionIfCurrent(session) else {
            return .stopped
        }
        do {
            try await accountRuntimeTransitionCoordinator.perform {
                guard let store = attachedStore else {
                    throw CodexReviewAuthenticationFailure.runtime(
                        message: "Authentication committed, but the review store is unavailable for reconciliation."
                    )
                }
                await stop(store: store, purpose: .loginReconciliationPreservingRuns)
                await start(store: store, forceRestartIfNeeded: true)
                guard let backend = appServerBackend else {
                    throw CodexReviewAuthenticationFailure.runtime(
                        message: "Authentication committed, but the replacement runtime failed to start."
                    )
                }
                let snapshot = try await backend.readAuth()
                guard let activeAccountID = snapshot.activeAccountID?.rawValue,
                      let backendAccount = snapshot.accounts.first(where: { $0.id.rawValue == activeAccountID }),
                      backendAccount.kind == .chatGPT
                else {
                    throw CodexReviewAuthenticationFailure.protocolViolation(
                        message: "Authentication committed, but the replacement runtime did not confirm a ChatGPT account."
                    )
                }
                _ = try await applyAuthSnapshotSerialized(snapshot, to: auth)
            }
            return .succeeded
        } catch let failure as CodexReviewAuthenticationFailure {
            auth.updatePhase(.failed(failure))
            logger.error(
                "Primary authentication reconciliation failed after \(String(describing: reason), privacy: .public): \(failure.localizedDescription, privacy: .public)"
            )
            return .failed(failure)
        } catch {
            let failure = CodexReviewAuthenticationFailure.runtime(message: error.localizedDescription)
            auth.updatePhase(.failed(failure))
            logger.error(
                "Primary authentication reconciliation failed after \(String(describing: reason), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return .failed(failure)
        }
    }

    private func clearLoginSessionIfCurrent(_ session: LoginSession) {
        guard loginSession === session,
              loginSession?.generationID == session.generationID else {
            return
        }
        loginSession = nil
    }

    @discardableResult
    private func detachLoginSessionIfCurrent(_ session: LoginSession) -> Bool {
        guard loginSession === session,
              loginSession?.generationID == session.generationID else {
            return false
        }
        loginSession = nil
        return true
    }

    private func closeLoginRuntime(_ runtime: LoginRuntime?) async {
        guard let runtime else {
            return
        }
        guard runtime.usesPrimaryRuntime == false else {
            return
        }
        await closeIsolatedLoginRuntime(
            appServer: runtime.appServer,
            codexHomeURL: runtime.codexHomeURL
        )
    }

    private func closeLoginRuntimeIfNeeded(_ session: LoginSession) async {
        guard let runtime = session.takeOwnedRuntimeForClose() else {
            return
        }
        await closeLoginRuntime(runtime)
    }

    private func releaseLoginMutationIfNeeded(_ session: LoginSession) async {
        guard let lease = session.takeMutationLeaseForRelease() else {
            return
        }
        await accountRegistry.finishMutation(lease)
    }

    private func loginRuntime(for purpose: LoginPurpose) async throws -> LoginRuntime {
        switch purpose {
        case .signIn:
            guard let appServer, let appServerBackend else {
                throw CodexReviewAPI.Error.io("Review runtime is not running.")
            }
            return .init(
                appServer: appServer,
                backend: appServerBackend,
                codexHomeURL: codexHomeURL,
                usesPrimaryRuntime: true
            )
        case .addAccountPreservingActive:
            let temporaryCodexHomeURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-review-auth-\(UUID().uuidString)", isDirectory: true)
            let runtime = try await appServerRuntimeFactory(temporaryCodexHomeURL)
            guard appServerBackend != nil else {
                await closeIsolatedLoginRuntime(
                    appServer: runtime.appServer,
                    codexHomeURL: temporaryCodexHomeURL
                )
                throw CodexReviewAPI.Error.io("Review runtime is not running.")
            }
            return .init(
                appServer: runtime.appServer,
                backend: runtime.backend,
                codexHomeURL: temporaryCodexHomeURL,
                usesPrimaryRuntime: false
            )
        }
    }

    func startReview(_ request: CodexReviewBackendModel.Review.Start) async throws -> BackendReviewAttempt {
        guard let appServerBackend else {
            throw CodexReviewAPI.Error.io("Review runtime is not running.")
        }
        return try await appServerBackend.startReview(request)
    }

    func interruptReview(_ attempt: ReviewAttempt, reason: CodexReviewBackendModel.CancellationReason) async throws {
        guard let appServerBackend else {
            throw CodexReviewAPI.Error.io("Review runtime is not running.")
        }
        try await appServerBackend.interruptReview(attempt, reason: reason)
    }

    func prepareReviewRestart(_ attempt: ReviewAttempt) async throws -> CodexReviewBackendModel.Review.RestartToken {
        guard let appServerBackend else {
            throw CodexReviewAPI.Error.io("Review runtime is not running.")
        }
        return try await appServerBackend.prepareReviewRestart(attempt)
    }

    func restartPreparedReview(
        _ token: CodexReviewBackendModel.Review.RestartToken,
        request: CodexReviewBackendModel.Review.Start
    ) async throws -> BackendReviewAttempt {
        guard let appServerBackend else {
            throw CodexReviewAPI.Error.io("Review runtime is not running.")
        }
        return try await appServerBackend.restartPreparedReview(token, request: request)
    }

    func discardPreparedReviewRestart(
        _ token: CodexReviewBackendModel.Review.RestartToken
    ) async -> [ReviewAttempt] {
        guard let appServerBackend else {
            preconditionFailure(
                "A prepared review restart must retain its matching app-server runtime until discard completes."
            )
        }
        return await appServerBackend.discardPreparedReviewRestart(token)
    }

    func cleanupReview(_ attempt: ReviewAttempt) async {
        guard let appServerBackend else {
            return
        }
        await appServerBackend.cleanupReview(attempt)
    }

    func cleanupRetainedReviews(
        _ attempts: [ReviewAttempt],
        additionalThreadIDs: [ReviewThreadID]
    ) async -> ReviewRetainedThreadCleanupResult {
        guard let appServerBackend else {
            let attemptFailures = attempts.flatMap { attempt -> [ReviewRetainedThreadCleanupFailure] in
                if attempt.threadIdentity.activeTurnThreadID == attempt.threadIdentity.sourceThreadID {
                    return [.init(
                        threadID: attempt.threadIdentity.sourceThreadID,
                        message: "The matching review runtime is not running."
                    )]
                }
                return [
                    .init(
                        threadID: attempt.threadIdentity.activeTurnThreadID,
                        message: "The matching review runtime is not running."
                    ),
                    .init(
                        threadID: attempt.threadIdentity.sourceThreadID,
                        message: "The matching review runtime is not running."
                    ),
                ]
            }
            return .init(failures: attemptFailures + additionalThreadIDs.map { threadID in
                .init(
                    threadID: threadID,
                    message: "The matching review runtime is not running."
                )
            })
        }
        return await appServerBackend.cleanupRetainedReviews(
            attempts,
            additionalThreadIDs: additionalThreadIDs
        )
    }

    @discardableResult
    private func applyAuthSnapshot(
        _ snapshot: CodexReviewBackendModel.Auth.Snapshot,
        to auth: CodexReviewAuthModel,
        activation: LoginActivation = .activateAuthenticatedAccount,
        authSourceCodexHomeURL: URL? = nil
    ) async throws -> CodexReviewAccount? {
        try await accountRuntimeTransitionCoordinator.performInternal {
            try await self.applyAuthSnapshotSerialized(
                snapshot,
                to: auth,
                activation: activation,
                authSourceCodexHomeURL: authSourceCodexHomeURL
            )
        }
    }

    @discardableResult
    private func applyAuthSnapshotSerialized(
        _ snapshot: CodexReviewBackendModel.Auth.Snapshot,
        to auth: CodexReviewAuthModel,
        activation: LoginActivation = .activateAuthenticatedAccount,
        authSourceCodexHomeURL: URL? = nil
    ) async throws -> CodexReviewAccount? {
        guard let activeAccountID = snapshot.activeAccountID?.rawValue,
              let backendAccount = snapshot.accounts.first(where: { $0.id.rawValue == activeAccountID }),
              let account = Self.monitorAccount(from: backendAccount)
        else {
            if case .activateAuthenticatedAccount = activation {
                try await accountRegistry.saveAccounts(
                    auth.persistedAccounts.map(savedAccountPayload(from:)),
                    activeAccountKey: nil
                )
                auth.selectPersistedAccount(nil)
                auth.updatePhase(.signedOut)
            } else {
                auth.updatePhase(.signedOut)
            }
            return nil
        }
        var persistedAccountPayloads = auth.persistedAccounts.map(savedAccountPayload(from:))
        let existingAccount = auth.persistedAccounts.first(where: { $0.accountKey == account.accountKey })
        var authenticatedAccountPayload = savedAccountPayload(from: account)
        if let existingAccount {
            let existingPayload = savedAccountPayload(from: existingAccount)
            authenticatedAccountPayload.rateLimits = existingPayload.rateLimits
            authenticatedAccountPayload.lastRateLimitFetchAt = existingPayload.lastRateLimitFetchAt
            authenticatedAccountPayload.lastRateLimitError = existingPayload.lastRateLimitError
        }
        if let index = persistedAccountPayloads.firstIndex(where: { $0.accountKey == account.accountKey }) {
            persistedAccountPayloads[index] = authenticatedAccountPayload
        } else {
            persistedAccountPayloads.insert(authenticatedAccountPayload, at: 0)
        }
        let activeAccountKey = activation.resolvedActiveAccountKey(
            authenticatedAccountKey: account.accountKey,
            persistedAccounts: auth.persistedAccounts + (existingAccount == nil ? [account] : [])
        )
        if authenticatedAccountPayload.kind == .chatGPT {
            try await accountRegistry.commitAuthenticatedAccount(
                authenticatedAccountPayload,
                accounts: persistedAccountPayloads,
                activeAccountKey: activeAccountKey,
                authSourceCodexHomeURL: authSourceCodexHomeURL
            )
        } else {
            try await accountRegistry.saveAccounts(
                persistedAccountPayloads,
                activeAccountKey: activeAccountKey
            )
        }
        let persistedAccount: CodexReviewAccount
        if let existingAccount {
            existingAccount.updateEmail(account.email)
            existingAccount.updateKind(account.kind, capabilities: account.capabilities)
            existingAccount.updatePlanType(account.planType)
            persistedAccount = existingAccount
        } else {
            persistedAccount = account
        }
        auth.applyPersistedAccountStates(
            persistedAccountPayloads,
            activeAccountKey: activeAccountKey
        )
        auth.selectPersistedAccount(activeAccountKey)
        auth.updatePhase(auth.selectedAccount == nil ? .signedOut : .signedOut)
        return auth.persistedAccounts.first(where: { $0.accountKey == persistedAccount.accountKey })
    }

    private func observeAuthNotifications(
        appServer: CodexAppServer,
        backend: AppServerCodexReviewBackend,
        store: CodexReviewStore
    ) async {
        authNotificationTask?.cancel()
        let stream = await appServer.accountEvents()
        authNotificationTask = Task { @MainActor [weak self, weak store] in
            guard let self, let store else {
                return
            }
            do {
                for try await event in stream {
                    await self.handleAuthNotification(
                        event,
                        backend: backend,
                        auth: store.auth
                    )
                }
            } catch is CancellationError {
            } catch {
                logger.error("Auth notification stream ended: \(error.localizedDescription, privacy: .public)")
                await markRuntimeFailedAfterNotificationStreamError(error, store: store)
            }
        }
    }

    // Dropping the container must always reach the lifecycle handler, or the
    // ReviewMonitor window keeps its model source pointed at a closed
    // app-server container.
    private func clearAppServerModelContainer() {
        appServerModelContainer = nil
        appServerLifecycleHandler?(nil)
    }

    private func markRuntimeFailedAfterNotificationStreamError(
        _ error: any Error,
        store: CodexReviewStore
    ) async {
        let loginSession = self.loginSession
        guard appServer != nil || appServerBackend != nil || mcpHTTPServer != nil || loginSession != nil else {
            return
        }
        let message = "Review runtime stopped unexpectedly: \(error.localizedDescription)"
        let failedAppServer = appServer
        let failedMCPHTTPServer = mcpHTTPServer
        await failedMCPHTTPServer?.stop()
        mcpHTTPServer = nil
        if let appServerBackend {
            let reason = ReviewCancellation.system(message: message)
            await cleanupActiveReviewsForRuntimeTeardown(
                store: store,
                appServerBackend: appServerBackend,
                reason: reason,
                mode: .connectionTerminated
            )
        }
        _ = await loginSession?.terminate(
            reason: .runtimeFailure(.runtime(message: message))
        )
        appServer = nil
        clearAppServerModelContainer()
        appServerBackend = nil
        authNotificationTask = nil
        store.transitionToFailed(message)
        await failedAppServer?.close()
    }

    private func handleAuthNotification(
        _ event: CodexAccountEvent,
        backend: AppServerCodexReviewBackend,
        auth: CodexReviewAuthModel
    ) async {
        switch event {
        case .accountUpdated:
            if loginSession != nil {
                return
            }
            await refreshAuthAfterAccountNotification(backend: backend, auth: auth)
        case .rateLimitsUpdated(let rateLimits):
            await applyRateLimitsUpdatedNotification(rateLimits, auth: auth)
        case .malformed(let method, let message):
            logger.error("Malformed account notification \(method, privacy: .public): \(message, privacy: .public)")
        case .unknown:
            return
        }
    }

    private func refreshAuthAfterAccountNotification(
        backend: AppServerCodexReviewBackend,
        auth: CodexReviewAuthModel
    ) async {
        do {
            try await applyAuthSnapshot(try await backend.readAuth(), to: auth)
            await refreshSelectedAccountRateLimits(auth: auth)
        } catch {
            auth.updatePhase(.failed(.runtime(message: error.localizedDescription)))
        }
    }

    private func applyRateLimitsUpdatedNotification(
        _ rateLimits: CodexRateLimits,
        auth: CodexReviewAuthModel
    ) async {
        guard let selectedAccount = auth.selectedAccount else {
            return
        }
        guard selectedAccount.capabilities.supportsRateLimitRefresh else {
            return
        }
        applyRateLimits(rateLimits, to: selectedAccount)
        _ = await persistRateLimitMetadata(for: selectedAccount)
    }

    private func refreshSelectedAccountRateLimits(auth: CodexReviewAuthModel) async {
        guard let selectedAccount = auth.selectedAccount else {
            return
        }
        await refreshRateLimits(for: selectedAccount, auth: auth)
    }

    private func refreshRateLimits(for account: CodexReviewAccount, auth: CodexReviewAuthModel) async {
        guard account.capabilities.supportsRateLimitRefresh else {
            return
        }
        guard auth.persistedActiveAccountKey == account.accountKey else {
            await refreshSavedAccountRateLimits(for: account)
            return
        }
        let didRefresh = await refreshRateLimits(for: account, using: appServerBackend, source: "active-runtime")
        if didRefresh {
            do {
                try await persistRefreshedSharedAuth(
                    from: codexHomeURL,
                    for: account
                )
            } catch {
                recordRateLimitRefreshFailure(error, account: account)
                _ = await persistRateLimitMetadata(for: account)
            }
        }
    }

    private func refreshSavedAccountRateLimits(for account: CodexReviewAccount) async {
        let temporaryCodexHomeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-review-rate-limits-\(UUID().uuidString)", isDirectory: true)
        do {
            guard try await accountRegistry.copySavedAuth(
                accountKey: account.accountKey,
                to: temporaryCodexHomeURL
            ) else {
                account.markRateLimitReauthenticationRequired(
                    fetchedAt: Date(),
                    error: "Saved account authentication is not available."
                )
                _ = await persistRateLimitMetadata(for: account)
                return
            }
            let runtime = try await appServerRuntimeFactory(temporaryCodexHomeURL)
            let didRefresh = await refreshRateLimits(for: account, using: runtime.backend, source: "saved-auth-isolated-runtime")
            do {
                if didRefresh {
                    try await accountRegistry.saveSharedAuth(
                        from: temporaryCodexHomeURL,
                        for: savedAccountPayload(from: account)
                    )
                }
            } catch {
                await closeIsolatedLoginRuntime(appServer: runtime.appServer, codexHomeURL: temporaryCodexHomeURL)
                throw error
            }
            await closeIsolatedLoginRuntime(appServer: runtime.appServer, codexHomeURL: temporaryCodexHomeURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryCodexHomeURL)
            account.updateRateLimitFetchMetadata(fetchedAt: Date(), error: error.localizedDescription)
            _ = await persistRateLimitMetadata(for: account)
        }
    }

    private func refreshRateLimits(
        for account: CodexReviewAccount,
        using backend: AppServerCodexReviewBackend?,
        source: String
    ) async -> Bool {
        do {
            guard let backend else {
                return false
            }
            if source == "saved-auth-isolated-runtime" {
                try await validateRateLimitBackendAccount(
                    account,
                    using: backend
                )
            }
            let response = try await backend.readRateLimits()
            applyRateLimits(response, to: account)
            return await persistRateLimitMetadata(for: account)
        } catch {
            recordRateLimitRefreshFailure(error, account: account)
            _ = await persistRateLimitMetadata(for: account)
            return false
        }
    }

    private func validateRateLimitBackendAccount(
        _ account: CodexReviewAccount,
        using backend: AppServerCodexReviewBackend
    ) async throws {
        let snapshot = try await backend.readAuth()
        guard let activeAccountID = snapshot.activeAccountID?.rawValue.nilIfEmpty else {
            throw CodexReviewAPI.Error.io("Saved authentication is missing for \(account.maskedEmail). Sign in again.")
        }
        let actualAccountKey = CodexReviewAccount.normalizedEmail(activeAccountID)
        guard actualAccountKey == account.accountKey else {
            let actualEmail = snapshot.accounts.first(where: { $0.id.rawValue == activeAccountID })?.label
                ?? activeAccountID
            let maskedActualEmail = self.maskedReviewAccountEmail(actualEmail)
            throw CodexReviewAPI.Error.io("Saved authentication is for \(maskedActualEmail), not \(account.maskedEmail). Sign in again.")
        }
    }

    private func recordRateLimitRefreshFailure(
        _ error: any Error,
        account: CodexReviewAccount
    ) {
        let message = error.localizedDescription
        if CodexReviewAccount.requiresReauthentication(errorMessage: message) {
            account.markRateLimitReauthenticationRequired(
                fetchedAt: Date(),
                error: message
            )
        } else {
            account.updateRateLimitFetchMetadata(fetchedAt: Date(), error: message)
        }
    }

    private func closeIsolatedLoginRuntime(appServer: CodexAppServer?, codexHomeURL: URL?) async {
        guard let codexHomeURL else {
            await appServer?.close()
            return
        }
        guard codexHomeURL != self.codexHomeURL else {
            return
        }
        await appServer?.close()
        try? FileManager.default.removeItem(at: codexHomeURL)
    }

    private func applyRateLimits(
        _ rateLimits: CodexRateLimits,
        to account: CodexReviewAccount
    ) {
        account.updateRateLimits(rateLimits.windows.map {
            (
                windowDurationMinutes: $0.windowDurationMinutes,
                usedPercent: $0.usedPercent,
                resetsAt: $0.resetsAt
            )
        })
        if let planType = rateLimits.planType {
            account.updatePlanType(planType)
        }
        account.updateRateLimitFetchMetadata(fetchedAt: Date(), error: nil)
    }

    private func persistRefreshedSharedAuth(
        from sourceCodexHomeURL: URL?,
        for account: CodexReviewAccount
    ) async throws {
        guard let sourceCodexHomeURL else {
            return
        }
        try await accountRegistry.saveSharedAuth(
            from: sourceCodexHomeURL,
            for: savedAccountPayload(from: account)
        )
    }

    @discardableResult
    private func persistRateLimitMetadata(for account: CodexReviewAccount) async -> Bool {
        do {
            try await accountRegistry.updateCachedRateLimits(
                from: savedAccountPayload(from: account)
            )
            return true
        } catch {
            let message = "Failed to persist account rate-limit metadata: \(error.localizedDescription)"
            account.updateRateLimitFetchMetadata(fetchedAt: Date(), error: message)
            logger.error("\(message, privacy: .public)")
            return false
        }
    }

    private func maskedReviewAccountEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].isEmpty == false,
              parts[1].isEmpty == false
        else {
            return maskedReviewAccountEmailSegment(email)
        }
        return "\(maskedReviewAccountEmailSegment(String(parts[0])))@\(parts[1])"
    }

    private func maskedReviewAccountEmailSegment(_ segment: String) -> String {
        let characters = Array(segment)
        switch characters.count {
        case 0:
            return segment
        case 1 ... 2:
            return String(characters.prefix(1)) + "..."
        case 3 ... 4:
            return String(characters.prefix(1)) + "..." + String(characters.suffix(1))
        default:
            return String(characters.prefix(2)) + "..." + String(characters.suffix(2))
        }
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

    private static func monitorAccount(from snapshot: CodexReviewBackendModel.Account.Snapshot) -> CodexReviewAccount? {
        let label = snapshot.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountKey = CodexReviewAccount.normalizedEmail(snapshot.id.rawValue)
        guard label.isEmpty == false, accountKey.isEmpty == false else {
            return nil
        }
        return CodexReviewAccount(
            accountKey: accountKey,
            email: label,
            planType: snapshot.planType,
            kind: snapshot.kind,
            capabilities: snapshot.capabilities
        )
    }

}

@MainActor
private struct AppServerRuntime: Sendable {
    var appServer: CodexAppServer
    var modelContainer: CodexModelContainer
    var backend: AppServerCodexReviewBackend
}

@MainActor
private struct LoginRuntime: Sendable {
    let appServer: CodexAppServer
    let backend: AppServerCodexReviewBackend
    let codexHomeURL: URL
    let usesPrimaryRuntime: Bool
}

private actor AccountRegistryStore {
    struct Snapshot: Sendable {
        let accounts: [CodexSavedAccountPayload]
        let activeAccountKey: String?
    }

    struct MutationLease: Hashable, Sendable {
        fileprivate let id: UUID
    }

    struct PreparedMutation: Hashable, Sendable {
        fileprivate let id: UUID
    }

    private enum MutationKind {
        case authentication
        case account
    }

    let codexHomeURL: URL
    private var activeMutation: (lease: MutationLease, kind: MutationKind)?

    init(codexHomeURL: URL) {
        self.codexHomeURL = codexHomeURL
    }

    nonisolated static func loadInitialSnapshot(codexHomeURL: URL) throws -> Snapshot {
        try Disk.load(codexHomeURL: codexHomeURL)
    }

    func load() throws -> Snapshot {
        try Disk.load(codexHomeURL: codexHomeURL)
    }

    func saveAccounts(
        _ accounts: [CodexSavedAccountPayload],
        activeAccountKey: String?
    ) throws {
        try Disk.saveAccounts(
            accounts,
            activeAccountKey: activeAccountKey,
            codexHomeURL: codexHomeURL
        )
    }

    func activateAccount(
        _ accountKey: String,
        accounts: [CodexSavedAccountPayload]
    ) throws {
        try Disk.activateAccount(
            accountKey,
            accounts: accounts,
            codexHomeURL: codexHomeURL
        )
    }

    func updateCachedRateLimits(from account: CodexSavedAccountPayload) throws {
        try requireNoAccountMutationForBackgroundPersistence()
        try Disk.updateCachedRateLimits(from: account, codexHomeURL: codexHomeURL)
    }

    func saveSharedAuth(
        from sourceCodexHomeURL: URL? = nil,
        for account: CodexSavedAccountPayload
    ) throws {
        try requireNoAccountMutationForBackgroundPersistence()
        try Disk.saveSharedAuth(
            from: sourceCodexHomeURL ?? codexHomeURL,
            for: account,
            codexHomeURL: codexHomeURL
        )
    }

    func commitAuthenticatedAccount(
        _ authenticatedAccount: CodexSavedAccountPayload,
        accounts: [CodexSavedAccountPayload],
        activeAccountKey: String?,
        authSourceCodexHomeURL: URL?
    ) throws {
        try Disk.commitAuthenticatedAccount(
            authenticatedAccount,
            accounts: accounts,
            activeAccountKey: activeAccountKey,
            authSourceCodexHomeURL: authSourceCodexHomeURL ?? codexHomeURL,
            codexHomeURL: codexHomeURL
        )
    }

    func prepareIrreversibleRemoval(
        accounts: [CodexSavedAccountPayload],
        activeAccountKey: String?
    ) throws -> PreparedMutation {
        try Disk.prepareIrreversibleRemoval(
            accounts: accounts,
            activeAccountKey: activeAccountKey,
            codexHomeURL: codexHomeURL
        )
    }

    func commitPreparedMutation(_ mutation: PreparedMutation) throws {
        try Disk.commitPreparedMutation(mutation, codexHomeURL: codexHomeURL)
    }

    func abortPreparedMutation(_ mutation: PreparedMutation) throws {
        try Disk.abortPreparedMutation(mutation, codexHomeURL: codexHomeURL)
    }

    func removeSavedAccountDirectory(accountKey: String) throws {
        try Disk.removeSavedAccountDirectory(
            accountKey: accountKey,
            codexHomeURL: codexHomeURL
        )
    }

    func copySavedAuth(accountKey: String, to destinationCodexHomeURL: URL) throws -> Bool {
        try requireNoAccountMutationForBackgroundPersistence()
        return try Disk.copySavedAuth(
            accountKey: accountKey,
            from: codexHomeURL,
            to: destinationCodexHomeURL
        )
    }

    func beginAuthenticationMutation() throws -> MutationLease {
        if let activeMutation {
            switch activeMutation.kind {
            case .authentication:
                throw CodexReviewAuthenticationFailure.alreadyInProgress
            case .account:
                throw CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
            }
        }
        return installMutation(kind: .authentication)
    }

    func beginAccountMutation() throws -> MutationLease {
        guard activeMutation == nil else {
            throw CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
        }
        return installMutation(kind: .account)
    }

    func finishMutation(_ lease: MutationLease) {
        precondition(activeMutation?.lease == lease, "Only the active account mutation owner can release its lease.")
        activeMutation = nil
    }

    private func installMutation(kind: MutationKind) -> MutationLease {
        let lease = MutationLease(id: UUID())
        activeMutation = (lease, kind)
        return lease
    }

    private func requireNoAccountMutationForBackgroundPersistence() throws {
        guard activeMutation?.kind != .account else {
            throw CodexReviewAuthenticationFailure.accountCommit(
                message: "Background account persistence is blocked while an account mutation is in progress."
            )
        }
    }
}

@MainActor
private final class AccountRuntimeTransitionCoordinator {
    private var isTransitioning = false
    private var transitionCompletionWaiters: [CheckedContinuation<Void, Never>] = []

    func perform<T>(_ operation: () async throws -> T) async throws -> T {
        guard isTransitioning == false else {
            throw CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
        }
        isTransitioning = true
        defer { finishTransition() }
        return try await operation()
    }

    func performInternal<T>(_ operation: () async throws -> T) async rethrows -> T {
        while isTransitioning {
            await withCheckedContinuation { continuation in
                transitionCompletionWaiters.append(continuation)
            }
        }
        isTransitioning = true
        defer { finishTransition() }
        return try await operation()
    }

    private func finishTransition() {
        precondition(isTransitioning)
        isTransitioning = false
        let waiters = transitionCompletionWaiters
        transitionCompletionWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }
}

@MainActor
private final class LoginSession {
    typealias RootOperation = @MainActor @Sendable () async -> LoginRootObservation
    typealias TerminationHandler = @MainActor @Sendable (
        LoginSession,
        LoginTerminationReason,
        LoginRootObservation
    ) async -> LoginSessionTerminal

    private enum State {
        case active
        case closing(
            reason: LoginTerminationReason,
            completion: Task<LoginSessionTerminal, Never>
        )
        case closed(LoginSessionTerminal)
    }

    let generationID: UUID
    let purpose: LoginPurpose
    let handle: CodexLoginHandle
    let runtime: LoginRuntime
    private let mutationLease: AccountRegistryStore.MutationLease
    private let rootOperation: RootOperation
    private let terminationHandler: TerminationHandler
    private var rootTask: Task<LoginRootObservation, Never>?
    private var state: State = .active
    private var didTakeOwnedRuntime = false
    private var didReleaseMutationLease = false

    init(
        generationID: UUID,
        purpose: LoginPurpose,
        handle: CodexLoginHandle,
        runtime: LoginRuntime,
        mutationLease: AccountRegistryStore.MutationLease,
        rootOperation: @escaping RootOperation,
        terminationHandler: @escaping TerminationHandler
    ) {
        self.generationID = generationID
        self.purpose = purpose
        self.handle = handle
        self.runtime = runtime
        self.mutationLease = mutationLease
        self.rootOperation = rootOperation
        self.terminationHandler = terminationHandler
    }

    func activate() {
        precondition(rootTask == nil, "A login session root task can be activated only once.")
        let rootOperation = rootOperation
        rootTask = Task { @MainActor in
            await rootOperation()
        }
    }

    func publishRootObservation(_: LoginRootObservation) {
        guard case .active = state else {
            return
        }
        _ = beginClosing(reason: .rootOutcome)
    }

    func terminate(reason: LoginTerminationReason) async -> LoginSessionTerminal {
        switch state {
        case .active:
            return await beginClosing(reason: reason).value
        case .closing(_, let completion):
            return await completion.value
        case .closed(let terminal):
            return terminal
        }
    }

    func takeOwnedRuntimeForClose() -> LoginRuntime? {
        guard runtime.usesPrimaryRuntime == false,
              didTakeOwnedRuntime == false else {
            return nil
        }
        didTakeOwnedRuntime = true
        return runtime
    }

    func takeMutationLeaseForRelease() -> AccountRegistryStore.MutationLease? {
        guard didReleaseMutationLease == false else {
            return nil
        }
        didReleaseMutationLease = true
        return mutationLease
    }

    private func beginClosing(
        reason: LoginTerminationReason
    ) -> Task<LoginSessionTerminal, Never> {
        guard case .active = state else {
            preconditionFailure("Only an active login session can begin termination.")
        }
        precondition(rootTask != nil, "A login session must be activated before termination.")
        let completion = Task { @MainActor [weak self] in
            guard let self else {
                return LoginSessionTerminal.stopped
            }
            return await self.performTermination(reason: reason)
        }
        state = .closing(reason: reason, completion: completion)
        return completion
    }

    private func performTermination(
        reason: LoginTerminationReason
    ) async -> LoginSessionTerminal {
        guard let rootTask else {
            preconditionFailure("A login session must own its root task through termination.")
        }
        var cancellationFailureMessage: String?
        if reason.requestsSDKCancellation {
            do {
                _ = try await handle.cancel()
            } catch {
                cancellationFailureMessage = error.localizedDescription
                rootTask.cancel()
            }
        }

        var observation = await rootTask.value
        if case .waiterCancelled = observation,
           let cancellationFailureMessage {
            observation = .waiterCancelled(message: cancellationFailureMessage)
        }
        let terminal = await terminationHandler(self, reason, observation)
        state = .closed(terminal)
        return terminal
    }

    isolated deinit {
        rootTask?.cancel()
    }
}

private enum LoginRootObservation: Sendable {
    case outcome(CodexLoginOutcome)
    case failure(CodexReviewAuthenticationFailure)
    case waiterCancelled(message: String?)
}

private enum LoginTerminationReason: Equatable, Sendable {
    case rootOutcome
    case explicitCancellation
    case urlOpenFailure(CodexReviewAuthenticationFailure)
    case runtimeFailure(CodexReviewAuthenticationFailure)
    case storeStop

    var requestsSDKCancellation: Bool {
        switch self {
        case .rootOutcome:
            return false
        case .explicitCancellation, .urlOpenFailure, .runtimeFailure, .storeStop:
            return true
        }
    }
}

private enum LoginSessionTerminal: Equatable, Sendable {
    case succeeded
    case failed(CodexReviewAuthenticationFailure)
    case cancelled
    case stopped
}

private enum LoginPurpose: Equatable, Sendable {
    case signIn
    case addAccountPreservingActive(String?)

    var activation: LoginActivation {
        switch self {
        case .signIn:
            return .activateAuthenticatedAccount
        case .addAccountPreservingActive(let activeAccountKey):
            return .preserveActiveAccount(activeAccountKey)
        }
    }
}

private enum LoginActivation: Equatable, Sendable {
    case activateAuthenticatedAccount
    case preserveActiveAccount(String?)

    func resolvedActiveAccountKey(
        authenticatedAccountKey: String,
        persistedAccounts: [CodexReviewAccount]
    ) -> String? {
        switch self {
        case .activateAuthenticatedAccount:
            return authenticatedAccountKey
        case .preserveActiveAccount(let activeAccountKey):
            return activeAccountKey.flatMap { activeAccountKey in
                persistedAccounts.contains(where: { $0.accountKey == activeAccountKey })
                    ? activeAccountKey
                    : nil
            }
        }
    }
}

private typealias AppServerRuntimeFactory = @MainActor @Sendable (URL) async throws -> AppServerRuntime

private extension AccountRegistryStore {
enum Disk {
    private struct Registry: Codable {
        static let currentSchemaVersion = 1

        var schemaVersion: Int
        var generation: UInt64
        var contentHash: String
        var activeAccountKey: String?
        var accounts: [Entry]

        enum CodingKeys: String, CodingKey {
            case schemaVersion
            case generation
            case contentHash
            case activeAccountKey
            case accounts
        }

        init(
            schemaVersion: Int = currentSchemaVersion,
            generation: UInt64 = 0,
            contentHash: String = "",
            activeAccountKey: String?,
            accounts: [Entry]
        ) {
            self.schemaVersion = schemaVersion
            self.generation = generation
            self.contentHash = contentHash
            self.activeAccountKey = activeAccountKey
            self.accounts = accounts
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
            generation = try container.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
            contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash) ?? ""
            activeAccountKey = try container.decodeIfPresent(String.self, forKey: .activeAccountKey)
            accounts = try container.decode([Entry].self, forKey: .accounts)
        }
    }

    private struct Entry: Codable {
        var accountKey: String?
        var immutableRevision: String?
        var kind: Kind
        var email: String
        var planType: String?
        var lastActivatedAt: Date?
        var lastRateLimitFetchAt: Date?
        var lastRateLimitError: String?
        var cachedRateLimits: [SavedRateLimitWindow]?

        enum CodingKeys: String, CodingKey {
            case accountKey
            case immutableRevision
            case kind
            case email
            case planType
            case lastActivatedAt
            case lastRateLimitFetchAt
            case lastRateLimitError
            case cachedRateLimits
        }

        init(
            accountKey: String?,
            immutableRevision: String? = nil,
            kind: Kind,
            email: String,
            planType: String?,
            lastActivatedAt: Date?,
            lastRateLimitFetchAt: Date?,
            lastRateLimitError: String?,
            cachedRateLimits: [SavedRateLimitWindow]?
        ) {
            self.accountKey = accountKey
            self.immutableRevision = immutableRevision
            self.kind = kind
            self.email = email
            self.planType = planType
            self.lastActivatedAt = lastActivatedAt
            self.lastRateLimitFetchAt = lastRateLimitFetchAt
            self.lastRateLimitError = lastRateLimitError
            self.cachedRateLimits = cachedRateLimits
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.accountKey = try container.decodeIfPresent(String.self, forKey: .accountKey)
            self.immutableRevision = try container.decodeIfPresent(String.self, forKey: .immutableRevision)
            self.email = try container.decode(String.self, forKey: .email)
            // Registries written before the kind field existed must keep
            // decoding; dropping them would empty the persisted account list.
            self.kind = try container.decodeIfPresent(Kind.self, forKey: .kind)
                ?? Kind.legacyDefault(accountKey: accountKey, email: email)
            self.planType = try container.decodeIfPresent(String.self, forKey: .planType)
            self.lastActivatedAt = try container.decodeIfPresent(Date.self, forKey: .lastActivatedAt)
            self.lastRateLimitFetchAt = try container.decodeIfPresent(Date.self, forKey: .lastRateLimitFetchAt)
            self.lastRateLimitError = try container.decodeIfPresent(String.self, forKey: .lastRateLimitError)
            self.cachedRateLimits = try container.decodeIfPresent(
                [SavedRateLimitWindow].self,
                forKey: .cachedRateLimits
            )
        }
    }

    private enum Kind: String, Codable {
        case chatGPT = "chatgpt"
        case apiKey
        case amazonBedrock

        static func legacyDefault(accountKey: String?, email: String) -> Self {
            let normalizedAccountKey = accountKey
                .map(CodexReviewAccount.normalizedEmail)
                .flatMap { $0.isEmpty ? nil : $0 }
            switch normalizedAccountKey ?? CodexReviewAccount.normalizedEmail(email) {
            case "api-key":
                return .apiKey
            case "amazon-bedrock":
                return .amazonBedrock
            default:
                return .chatGPT
            }
        }

        init(_ accountKind: CodexReviewBackendModel.Account.Kind) {
            switch accountKind {
            case .chatGPT:
                self = .chatGPT
            case .apiKey:
                self = .apiKey
            case .amazonBedrock:
                self = .amazonBedrock
            }
        }

        var accountKind: CodexReviewBackendModel.Account.Kind {
            switch self {
            case .chatGPT:
                .chatGPT
            case .apiKey:
                .apiKey
            case .amazonBedrock:
                .amazonBedrock
            }
        }

    }

    private struct SavedRateLimitWindow: Codable {
        var windowDurationMinutes: Int
        var usedPercent: Int
        var resetsAt: Date?

        var tuple: (windowDurationMinutes: Int, usedPercent: Int, resetsAt: Date?) {
            (windowDurationMinutes, usedPercent, resetsAt)
        }
    }

    private struct MutationJournal: Codable {
        enum Phase: String, Codable {
            case prepared
            case sharedAuthApplied
            case registryCommitted
        }

        enum SharedAuthAction: String, Codable {
            case replace
            case remove
        }

        var id: UUID
        var phase: Phase
        var beforeRegistry: Registry
        var desiredRegistry: Registry
        var beforeSharedAuthFingerprint: String?
        var desiredSharedAuthFingerprint: String?
        var sharedAuthAction: SharedAuthAction
        var replacementAccountKey: String?
        var replacementRevision: String?
        var mayApplyIrreversibleLogout: Bool
    }

    static func load(codexHomeURL: URL) throws -> AccountRegistryStore.Snapshot {
        let registry = try loadRegistry(codexHomeURL: codexHomeURL)
        try garbageCollectOrphanedRevisions(
            referencedBy: registry,
            codexHomeURL: codexHomeURL
        )
        let accounts = registry.accounts.compactMap(makePayload(from:))
        let activeAccountKey = registry.activeAccountKey
            .map(CodexReviewAccount.normalizedEmail)
            .flatMap { activeAccountKey in
                accounts.contains(where: { $0.accountKey == activeAccountKey }) ? activeAccountKey : nil
            }
        logger.info("Loaded \(accounts.count, privacy: .public) persisted Codex review account(s)")
        return .init(accounts: accounts, activeAccountKey: activeAccountKey)
    }

    static func saveAccounts(
        _ accounts: [CodexSavedAccountPayload],
        activeAccountKey: String?,
        codexHomeURL: URL
    ) throws {
        let existing = try loadRegistry(codexHomeURL: codexHomeURL)
        let normalizedActiveAccountKey = activeAccountKey
            .map(CodexReviewAccount.normalizedEmail)
            .flatMap { accountKey in
                accounts.contains(where: { $0.accountKey == accountKey }) ? accountKey : nil
            }
        try saveRegistry(
            .init(
                schemaVersion: existing.schemaVersion,
                generation: existing.generation,
                contentHash: existing.contentHash,
                activeAccountKey: normalizedActiveAccountKey,
                accounts: mergedEntries(
                    accounts,
                    activeAccountKey: normalizedActiveAccountKey,
                    existing: existing.accounts
                )
            ),
            codexHomeURL: codexHomeURL
        )
    }

    private static func mergedEntries(
        _ accounts: [CodexSavedAccountPayload],
        activeAccountKey: String?,
        existing: [Entry]
    ) -> [Entry] {
        let existingByAccountKey = Dictionary(uniqueKeysWithValues: existing.compactMap { entry in
            normalizedAccountKey(from: entry).map { ($0, entry) }
        })
        return accounts.map { account in
            var entry = existingByAccountKey[account.accountKey] ?? Entry(
                accountKey: account.accountKey,
                kind: .init(account.kind),
                email: account.email,
                planType: account.planType,
                lastActivatedAt: nil,
                lastRateLimitFetchAt: nil,
                lastRateLimitError: nil,
                cachedRateLimits: nil
            )
            entry.accountKey = account.accountKey
            entry.kind = .init(account.kind)
            entry.email = account.email
            entry.planType = account.planType
            entry.cachedRateLimits = account.rateLimits.map { window in
                .init(
                    windowDurationMinutes: window.windowDurationMinutes,
                    usedPercent: window.usedPercent,
                    resetsAt: window.resetsAt
                )
            }
            entry.lastRateLimitFetchAt = account.lastRateLimitFetchAt
            entry.lastRateLimitError = account.lastRateLimitError
            if account.accountKey == activeAccountKey {
                entry.lastActivatedAt = Date()
            }
            return entry
        }
    }

    static func activateAccount(
        _ accountKey: String,
        accounts: [CodexSavedAccountPayload],
        codexHomeURL: URL
    ) throws {
        let targetAccountKey = CodexReviewAccount.normalizedEmail(accountKey)
        let beforeRegistry = try loadRegistry(codexHomeURL: codexHomeURL)
        guard let entry = beforeRegistry.accounts.first(where: {
            normalizedAccountKey(from: $0) == targetAccountKey
        }), let revision = entry.immutableRevision,
              let savedAuthURL = immutableAuthURL(
                for: entry,
                accountKey: targetAccountKey,
                codexHomeURL: codexHomeURL
        ) else {
            throw CodexReviewAPI.Error.io("Saved authentication is missing for account \(targetAccountKey).")
        }
        let desiredAuthData = try validatedAuthData(at: savedAuthURL)
        var desiredRegistry = beforeRegistry
        desiredRegistry.activeAccountKey = targetAccountKey
        desiredRegistry.accounts = mergedEntries(
            accounts,
            activeAccountKey: targetAccountKey,
            existing: beforeRegistry.accounts
        )
        desiredRegistry = try nextRegistry(from: desiredRegistry)
        var journal = MutationJournal(
            id: UUID(),
            phase: .prepared,
            beforeRegistry: beforeRegistry,
            desiredRegistry: desiredRegistry,
            beforeSharedAuthFingerprint: try sharedAuthFingerprint(codexHomeURL: codexHomeURL),
            desiredSharedAuthFingerprint: fingerprint(desiredAuthData),
            sharedAuthAction: .replace,
            replacementAccountKey: targetAccountKey,
            replacementRevision: revision,
            mayApplyIrreversibleLogout: false
        )
        try writeJournal(journal, codexHomeURL: codexHomeURL)
        try copyAuth(from: savedAuthURL, to: sharedAuthURL(codexHomeURL: codexHomeURL))
        journal.phase = .sharedAuthApplied
        try writeJournal(journal, codexHomeURL: codexHomeURL)
        try persistRegistry(desiredRegistry, codexHomeURL: codexHomeURL)
        journal.phase = .registryCommitted
        try writeJournal(journal, codexHomeURL: codexHomeURL)
        try removeJournal(codexHomeURL: codexHomeURL)
    }

    static func prepareIrreversibleRemoval(
        accounts: [CodexSavedAccountPayload],
        activeAccountKey: String?,
        codexHomeURL: URL
    ) throws -> AccountRegistryStore.PreparedMutation {
        let beforeRegistry = try loadRegistry(codexHomeURL: codexHomeURL)
        let normalizedActiveAccountKey = activeAccountKey
            .map(CodexReviewAccount.normalizedEmail)
            .flatMap { key in accounts.contains(where: { $0.accountKey == key }) ? key : nil }
        var desiredRegistry = beforeRegistry
        desiredRegistry.activeAccountKey = normalizedActiveAccountKey
        desiredRegistry.accounts = mergedEntries(
            accounts,
            activeAccountKey: normalizedActiveAccountKey,
            existing: beforeRegistry.accounts
        )
        desiredRegistry = try nextRegistry(from: desiredRegistry)
        let id = UUID()
        try writeJournal(
            .init(
                id: id,
                phase: .prepared,
                beforeRegistry: beforeRegistry,
                desiredRegistry: desiredRegistry,
                beforeSharedAuthFingerprint: try sharedAuthFingerprint(codexHomeURL: codexHomeURL),
                desiredSharedAuthFingerprint: nil,
                sharedAuthAction: .remove,
                replacementAccountKey: nil,
                replacementRevision: nil,
                mayApplyIrreversibleLogout: true
            ),
            codexHomeURL: codexHomeURL
        )
        return .init(id: id)
    }

    static func commitPreparedMutation(
        _ mutation: AccountRegistryStore.PreparedMutation,
        codexHomeURL: URL
    ) throws {
        var journal = try loadJournal(codexHomeURL: codexHomeURL)
        guard journal.id == mutation.id else {
            throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                message: "The prepared account mutation token does not match the durable journal."
            )
        }
        try applySharedAuthAction(journal, codexHomeURL: codexHomeURL)
        journal.phase = .sharedAuthApplied
        try writeJournal(journal, codexHomeURL: codexHomeURL)
        try persistRegistry(journal.desiredRegistry, codexHomeURL: codexHomeURL)
        journal.phase = .registryCommitted
        try writeJournal(journal, codexHomeURL: codexHomeURL)
        try removeJournal(codexHomeURL: codexHomeURL)
    }

    static func abortPreparedMutation(
        _ mutation: AccountRegistryStore.PreparedMutation,
        codexHomeURL: URL
    ) throws {
        let journal = try loadJournal(codexHomeURL: codexHomeURL)
        guard journal.id == mutation.id else {
            throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                message: "The aborted account mutation token does not match the durable journal."
            )
        }
        let registry = try loadRegistryWithoutRecovery(codexHomeURL: codexHomeURL)
        let sharedFingerprint = try sharedAuthFingerprint(codexHomeURL: codexHomeURL)
        if sameRegistry(registry, journal.beforeRegistry),
           sharedFingerprint == journal.beforeSharedAuthFingerprint {
            try removeJournal(codexHomeURL: codexHomeURL)
            return
        }
        try recoverJournal(journal, codexHomeURL: codexHomeURL)
    }

    static func updateCachedRateLimits(
        from account: CodexSavedAccountPayload,
        codexHomeURL: URL
    ) throws {
        var registry = try loadRegistry(codexHomeURL: codexHomeURL)
        guard let index = registry.accounts.firstIndex(where: {
            normalizedAccountKey(from: $0) == account.accountKey
        }) else {
            return
        }
        registry.accounts[index].planType = account.planType
        registry.accounts[index].cachedRateLimits = account.rateLimits.map { window in
            .init(
                windowDurationMinutes: window.windowDurationMinutes,
                usedPercent: window.usedPercent,
                resetsAt: window.resetsAt
            )
        }
        registry.accounts[index].lastRateLimitFetchAt = account.lastRateLimitFetchAt
        registry.accounts[index].lastRateLimitError = account.lastRateLimitError
        try saveRegistry(registry, codexHomeURL: codexHomeURL)
    }

    static func saveSharedAuth(
        for account: CodexSavedAccountPayload,
        codexHomeURL: URL
    ) throws {
        try saveSharedAuth(
            from: codexHomeURL,
            for: account,
            codexHomeURL: codexHomeURL
        )
    }

    static func commitAuthenticatedAccount(
        _ authenticatedAccount: CodexSavedAccountPayload,
        accounts: [CodexSavedAccountPayload],
        activeAccountKey: String?,
        authSourceCodexHomeURL: URL,
        codexHomeURL: URL
    ) throws {
        let sourceData = try validatedAuthData(
            at: sharedAuthURL(codexHomeURL: authSourceCodexHomeURL)
        )
        let existing = try loadRegistry(codexHomeURL: codexHomeURL)
        let existingEntry = existing.accounts.first(where: {
            normalizedAccountKey(from: $0) == authenticatedAccount.accountKey
        })
        let sourceFingerprint = fingerprint(sourceData)
        let revision: String
        let createdRevision: String?
        if let existingURL = existingEntry.flatMap({ entry in
            immutableAuthURL(
                for: entry,
                accountKey: authenticatedAccount.accountKey,
                codexHomeURL: codexHomeURL
            )
        }), FileManager.default.fileExists(atPath: existingURL.path),
           fingerprint(try validatedAuthData(at: existingURL)) == sourceFingerprint,
           let immutableRevision = existingEntry?.immutableRevision {
            revision = immutableRevision
            createdRevision = nil
        } else {
            revision = try writeImmutableRevision(
                sourceData,
                accountKey: authenticatedAccount.accountKey,
                codexHomeURL: codexHomeURL
            )
            createdRevision = revision
        }
        let normalizedActiveAccountKey = activeAccountKey
            .map(CodexReviewAccount.normalizedEmail)
            .flatMap { key in accounts.contains(where: { $0.accountKey == key }) ? key : nil }
        var desired = existing
        desired.activeAccountKey = normalizedActiveAccountKey
        desired.accounts = mergedEntries(
            accounts,
            activeAccountKey: normalizedActiveAccountKey,
            existing: existing.accounts
        )
        guard let authenticatedIndex = desired.accounts.firstIndex(where: {
            normalizedAccountKey(from: $0) == authenticatedAccount.accountKey
        }) else {
            throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                message: "Authenticated account \(authenticatedAccount.accountKey) is missing from its commit payload."
            )
        }
        desired.accounts[authenticatedIndex].immutableRevision = revision
        do {
            try saveRegistry(desired, codexHomeURL: codexHomeURL)
        } catch {
            if let createdRevision {
                try? FileManager.default.removeItem(
                    at: immutableAuthURL(
                        accountKey: authenticatedAccount.accountKey,
                        revision: createdRevision,
                        codexHomeURL: codexHomeURL
                    )
                )
            }
            throw error
        }
    }

    static func saveSharedAuth(
        from sourceCodexHomeURL: URL,
        for account: CodexSavedAccountPayload,
        codexHomeURL: URL
    ) throws {
        let sourceURL = sharedAuthURL(codexHomeURL: sourceCodexHomeURL)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return
        }
        let sourceData = try validatedAuthData(at: sourceURL)
        var registry = try loadRegistry(codexHomeURL: codexHomeURL)
        guard let index = registry.accounts.firstIndex(where: {
            normalizedAccountKey(from: $0) == account.accountKey
        }) else {
            throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                message: "Cannot attach authentication revision to missing account \(account.accountKey)."
            )
        }
        if let existingURL = immutableAuthURL(
            for: registry.accounts[index],
            accountKey: account.accountKey,
            codexHomeURL: codexHomeURL
        ), FileManager.default.fileExists(atPath: existingURL.path) {
            let existingData = try validatedAuthData(at: existingURL)
            if fingerprint(existingData) == fingerprint(sourceData) {
                return
            }
        }
        let revision = try writeImmutableRevision(
            sourceData,
            accountKey: account.accountKey,
            codexHomeURL: codexHomeURL
        )
        registry.accounts[index].immutableRevision = revision
        do {
            try saveRegistry(registry, codexHomeURL: codexHomeURL)
        } catch {
            try? FileManager.default.removeItem(
                at: immutableAuthURL(
                    accountKey: account.accountKey,
                    revision: revision,
                    codexHomeURL: codexHomeURL
                )
            )
            throw error
        }
    }

    static func removeSharedAuth(codexHomeURL: URL) throws {
        let url = sharedAuthURL(codexHomeURL: codexHomeURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    static func removeSavedAccountDirectory(
        accountKey: String,
        codexHomeURL: URL
    ) throws {
        let directoryURL = savedAccountDirectoryURL(accountKey: accountKey, codexHomeURL: codexHomeURL)
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: directoryURL)
    }

    static func copySavedAuth(
        accountKey: String,
        from sourceCodexHomeURL: URL,
        to destinationCodexHomeURL: URL
    ) throws -> Bool {
        let targetAccountKey = CodexReviewAccount.normalizedEmail(accountKey)
        let registry = try loadRegistry(codexHomeURL: sourceCodexHomeURL)
        guard let entry = registry.accounts.first(where: {
            normalizedAccountKey(from: $0) == targetAccountKey
        }), let sourceURL = immutableAuthURL(
            for: entry,
            accountKey: targetAccountKey,
            codexHomeURL: sourceCodexHomeURL
        ) else {
            return false
        }
        _ = try validatedAuthData(at: sourceURL)
        try copyAuth(
            from: sourceURL,
            to: sharedAuthURL(codexHomeURL: destinationCodexHomeURL)
        )
        return true
    }

    private static func makePayload(from entry: Entry) -> CodexSavedAccountPayload? {
        let email = entry.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.isEmpty == false else {
            return nil
        }
        let normalizedEmail = CodexReviewAccount.normalizedEmail(email)
        let accountKey = entry.accountKey
            .map(CodexReviewAccount.normalizedEmail)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? normalizedEmail
        return CodexSavedAccountPayload(
            accountKey: accountKey,
            email: email,
            kind: entry.kind.accountKind,
            planType: entry.planType,
            capabilities: entry.kind.accountKind.capabilities,
            rateLimits: entry.cachedRateLimits?.map(\.tuple) ?? [],
            lastRateLimitFetchAt: entry.lastRateLimitFetchAt,
            lastRateLimitError: entry.lastRateLimitError
        )
    }

    private static func loadRegistry(codexHomeURL: URL) throws -> Registry {
        if FileManager.default.fileExists(atPath: journalURL(codexHomeURL: codexHomeURL).path) {
            let journal = try loadJournal(codexHomeURL: codexHomeURL)
            try recoverJournal(journal, codexHomeURL: codexHomeURL)
        }
        return try loadRegistryWithoutRecovery(codexHomeURL: codexHomeURL)
    }

    private static func loadRegistryWithoutRecovery(codexHomeURL: URL) throws -> Registry {
        let url = registryURL(codexHomeURL: codexHomeURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .init(activeAccountKey: nil, accounts: [])
        }
        do {
            let data = try Data(contentsOf: url)
            var registry = try JSONDecoder().decode(Registry.self, from: data)
            guard registry.schemaVersion == 0 || registry.schemaVersion == Registry.currentSchemaVersion else {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "Unsupported account registry schema version \(registry.schemaVersion)."
                )
            }
            if registry.schemaVersion == Registry.currentSchemaVersion {
                let expectedHash = try contentHash(for: registry)
                guard registry.contentHash == expectedHash else {
                    throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                        message: "The account registry content hash does not match its persisted content."
                    )
                }
            } else {
                registry = try migrateLegacyRegistry(registry, codexHomeURL: codexHomeURL)
                try saveRegistry(registry, codexHomeURL: codexHomeURL)
                registry = try JSONDecoder().decode(
                    Registry.self,
                    from: Data(contentsOf: url)
                )
            }
            try validateReferencedAuthRevisions(registry, codexHomeURL: codexHomeURL)
            return registry
        } catch let failure as CodexReviewAuthenticationFailure {
            throw failure
        } catch {
            throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                message: "The account registry is inconsistent: \(error.localizedDescription)"
            )
        }
    }

    private static func saveRegistry(
        _ registry: Registry,
        codexHomeURL: URL
    ) throws {
        try persistRegistry(
            nextRegistry(from: registry),
            codexHomeURL: codexHomeURL
        )
    }

    private static func nextRegistry(from registry: Registry) throws -> Registry {
        var registry = registry
        registry.schemaVersion = Registry.currentSchemaVersion
        registry.generation = registry.generation &+ 1
        registry.contentHash = try contentHash(for: registry)
        return registry
    }

    private static func persistRegistry(
        _ registry: Registry,
        codexHomeURL: URL
    ) throws {
        let url = registryURL(codexHomeURL: codexHomeURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard registry.schemaVersion == Registry.currentSchemaVersion,
              registry.contentHash == (try contentHash(for: registry)) else {
            throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                message: "Refusing to persist an account registry with an invalid content hash."
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeAtomically(
            encoder.encode(registry),
            to: url,
            permissions: 0o600
        )
    }

    private static func migrateLegacyRegistry(
        _ legacy: Registry,
        codexHomeURL: URL
    ) throws -> Registry {
        var migrated = legacy
        migrated.schemaVersion = Registry.currentSchemaVersion
        migrated.contentHash = ""
        for index in migrated.accounts.indices {
            guard migrated.accounts[index].immutableRevision == nil,
                  let accountKey = normalizedAccountKey(from: migrated.accounts[index])
            else {
                continue
            }
            let legacyURL = savedAccountAuthURL(
                accountKey: accountKey,
                codexHomeURL: codexHomeURL
            )
            guard FileManager.default.fileExists(atPath: legacyURL.path) else {
                continue
            }
            let data = try validatedAuthData(at: legacyURL)
            migrated.accounts[index].immutableRevision = try writeImmutableRevision(
                data,
                accountKey: accountKey,
                codexHomeURL: codexHomeURL,
                preferredRevision: "legacy-0-\(fingerprint(data).prefix(16))"
            )
        }
        return migrated
    }

    private static func validateReferencedAuthRevisions(
        _ registry: Registry,
        codexHomeURL: URL
    ) throws {
        for entry in registry.accounts {
            guard entry.immutableRevision != nil else {
                continue
            }
            guard let accountKey = normalizedAccountKey(from: entry),
                  let revisionURL = immutableAuthURL(
                    for: entry,
                    accountKey: accountKey,
                    codexHomeURL: codexHomeURL
                  ) else {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "An account registry revision has no valid account identity."
                )
            }
            _ = try validatedAuthData(at: revisionURL)
        }
    }

    private static func garbageCollectOrphanedRevisions(
        referencedBy registry: Registry,
        codexHomeURL: URL
    ) throws {
        let referencedPaths = Set(registry.accounts.compactMap { entry -> String? in
            guard let accountKey = normalizedAccountKey(from: entry),
                  let url = immutableAuthURL(
                    for: entry,
                    accountKey: accountKey,
                    codexHomeURL: codexHomeURL
                  ) else {
                return nil
            }
            return url.standardizedFileURL.path
        })
        let accountsURL = accountsDirectoryURL(codexHomeURL: codexHomeURL)
        guard FileManager.default.fileExists(atPath: accountsURL.path) else {
            return
        }
        let accountDirectories = try FileManager.default.contentsOfDirectory(
            at: accountsURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for accountDirectory in accountDirectories {
            let accountValues = try accountDirectory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard accountValues.isDirectory == true, accountValues.isSymbolicLink != true else {
                continue
            }
            let revisionsURL = accountDirectory.appendingPathComponent("revisions", isDirectory: true)
            guard FileManager.default.fileExists(atPath: revisionsURL.path) else {
                continue
            }
            let revisionValues = try revisionsURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard revisionValues.isDirectory == true, revisionValues.isSymbolicLink != true else {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "An authentication revisions path is not a regular directory."
                )
            }
            let revisions = try FileManager.default.contentsOfDirectory(
                at: revisionsURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            var removedRevision = false
            for revisionURL in revisions where revisionURL.pathExtension == "json" {
                let values = try revisionURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                        message: "An immutable authentication revision is not a regular file."
                    )
                }
                guard referencedPaths.contains(revisionURL.standardizedFileURL.path) == false else {
                    continue
                }
                try FileManager.default.removeItem(at: revisionURL)
                removedRevision = true
            }
            if removedRevision {
                try synchronizeDirectory(at: revisionsURL)
            }
        }
    }

    private struct RegistryContent: Encodable {
        let schemaVersion: Int
        let generation: UInt64
        let activeAccountKey: String?
        let accounts: [Entry]
    }

    private static func contentHash(for registry: Registry) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(RegistryContent(
            schemaVersion: Registry.currentSchemaVersion,
            generation: registry.generation,
            activeAccountKey: registry.activeAccountKey,
            accounts: registry.accounts
        ))
        return fingerprint(data)
    }

    private static func writeJournal(
        _ journal: MutationJournal,
        codexHomeURL: URL
    ) throws {
        guard journal.beforeRegistry.contentHash == (try contentHash(for: journal.beforeRegistry)),
              journal.desiredRegistry.contentHash == (try contentHash(for: journal.desiredRegistry)) else {
            throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                message: "Refusing to persist an account mutation journal with invalid registry hashes."
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: journalURL(codexHomeURL: codexHomeURL).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeAtomically(
            encoder.encode(journal),
            to: journalURL(codexHomeURL: codexHomeURL),
            permissions: 0o600
        )
    }

    private static func loadJournal(codexHomeURL: URL) throws -> MutationJournal {
        do {
            return try JSONDecoder().decode(
                MutationJournal.self,
                from: Data(contentsOf: journalURL(codexHomeURL: codexHomeURL))
            )
        } catch {
            throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                message: "The account mutation journal is inconsistent: \(error.localizedDescription)"
            )
        }
    }

    private static func removeJournal(codexHomeURL: URL) throws {
        let url = journalURL(codexHomeURL: codexHomeURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
        try synchronizeDirectory(at: url.deletingLastPathComponent())
    }

    private static func recoverJournal(
        _ journal: MutationJournal,
        codexHomeURL: URL
    ) throws {
        guard journal.beforeRegistry.contentHash == (try contentHash(for: journal.beforeRegistry)),
              journal.desiredRegistry.contentHash == (try contentHash(for: journal.desiredRegistry)) else {
            throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                message: "The account mutation journal contains invalid registry hashes."
            )
        }
        let currentRegistry = try loadRegistryWithoutRecovery(codexHomeURL: codexHomeURL)
        let currentSharedFingerprint = try sharedAuthFingerprint(codexHomeURL: codexHomeURL)
        let registryIsBefore = sameRegistry(currentRegistry, journal.beforeRegistry)
        let registryIsDesired = sameRegistry(currentRegistry, journal.desiredRegistry)
        guard registryIsBefore || registryIsDesired else {
            throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                message: "The account registry matches neither side of its durable mutation journal."
            )
        }
        let sharedIsBefore = currentSharedFingerprint == journal.beforeSharedAuthFingerprint
        let sharedIsDesired = currentSharedFingerprint == journal.desiredSharedAuthFingerprint
        guard sharedIsBefore || sharedIsDesired else {
            throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                message: "Shared authentication matches neither side of its durable mutation journal."
            )
        }
        let irreversibleEffectMayHaveApplied = journal.mayApplyIrreversibleLogout
            && (currentSharedFingerprint == nil || sharedIsBefore == false)
        let shouldForward = registryIsDesired || sharedIsDesired || irreversibleEffectMayHaveApplied
        guard shouldForward else {
            try removeJournal(codexHomeURL: codexHomeURL)
            return
        }
        if sharedIsDesired == false {
            try applySharedAuthAction(journal, codexHomeURL: codexHomeURL)
        }
        if registryIsDesired == false {
            try persistRegistry(journal.desiredRegistry, codexHomeURL: codexHomeURL)
        }
        try removeJournal(codexHomeURL: codexHomeURL)
    }

    private static func applySharedAuthAction(
        _ journal: MutationJournal,
        codexHomeURL: URL
    ) throws {
        switch journal.sharedAuthAction {
        case .remove:
            try removeSharedAuth(codexHomeURL: codexHomeURL)
            try synchronizeDirectory(at: codexHomeURL)
        case .replace:
            guard let accountKey = journal.replacementAccountKey,
                  let revision = journal.replacementRevision else {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "A replacement journal is missing its immutable revision reference."
                )
            }
            try copyAuth(
                from: immutableAuthURL(
                    accountKey: accountKey,
                    revision: revision,
                    codexHomeURL: codexHomeURL
                ),
                to: sharedAuthURL(codexHomeURL: codexHomeURL)
            )
        }
        let actualFingerprint = try sharedAuthFingerprint(codexHomeURL: codexHomeURL)
        guard actualFingerprint == journal.desiredSharedAuthFingerprint else {
            throw CodexReviewAuthenticationFailure.accountCommit(
                message: "Shared authentication did not reach the journaled desired fingerprint."
            )
        }
    }

    private static func sharedAuthFingerprint(codexHomeURL: URL) throws -> String? {
        let url = sharedAuthURL(codexHomeURL: codexHomeURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return fingerprint(try validatedAuthData(at: url))
    }

    private static func sameRegistry(_ lhs: Registry, _ rhs: Registry) -> Bool {
        lhs.generation == rhs.generation && lhs.contentHash == rhs.contentHash
    }

    private static func copyAuth(from sourceURL: URL, to destinationURL: URL) throws {
        let sourceData = try validatedAuthData(at: sourceURL)
        let destinationDirectoryURL = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: destinationDirectoryURL,
            withIntermediateDirectories: true
        )
        let replacementURL = destinationDirectoryURL
            .appendingPathComponent(".\(destinationURL.lastPathComponent).replacement-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: sourceURL, to: replacementURL)
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    destinationURL,
                    withItemAt: replacementURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try FileManager.default.moveItem(at: replacementURL, to: destinationURL)
            }
            try synchronizeFile(at: destinationURL)
            try synchronizeDirectory(at: destinationDirectoryURL)
            let destinationData = try validatedAuthData(at: destinationURL)
            guard fingerprint(destinationData) == fingerprint(sourceData) else {
                throw CodexReviewAuthenticationFailure.accountCommit(
                    message: "Authentication copy fingerprint mismatch."
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: replacementURL)
            throw error
        }
    }

    private static func writeImmutableRevision(
        _ data: Data,
        accountKey: String,
        codexHomeURL: URL,
        preferredRevision: String? = nil
    ) throws -> String {
        _ = try validatedAuthObject(data)
        let revision = preferredRevision ?? UUID().uuidString.lowercased()
        let url = immutableAuthURL(
            accountKey: accountKey,
            revision: revision,
            codexHomeURL: codexHomeURL
        )
        let directoryURL = url.deletingLastPathComponent()
        let accountDirectoryURL = directoryURL.deletingLastPathComponent()
        let accountsURL = accountDirectoryURL.deletingLastPathComponent()
        let codexHomeParentURL = codexHomeURL.deletingLastPathComponent()
        let directoryExisted = FileManager.default.fileExists(atPath: directoryURL.path)
        let accountDirectoryExisted = FileManager.default.fileExists(atPath: accountDirectoryURL.path)
        let accountsDirectoryExisted = FileManager.default.fileExists(atPath: accountsURL.path)
        let codexHomeExisted = FileManager.default.fileExists(atPath: codexHomeURL.path)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try validatedAuthData(at: url)
            guard fingerprint(existing) == fingerprint(data) else {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "Immutable authentication revision \(revision) has conflicting content."
                )
            }
            return revision
        }
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CodexReviewAuthenticationFailure.accountCommit(
                message: "Could not create immutable authentication revision \(revision)."
            )
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try synchronizeDirectory(at: directoryURL)
            if directoryExisted == false {
                try synchronizeDirectory(at: accountDirectoryURL)
            }
            if accountDirectoryExisted == false {
                try synchronizeDirectory(at: accountsURL)
            }
            if accountsDirectoryExisted == false {
                try synchronizeDirectory(at: codexHomeURL)
            }
            if codexHomeExisted == false {
                try synchronizeDirectory(at: codexHomeParentURL)
            }
            let persisted = try validatedAuthData(at: url)
            guard fingerprint(persisted) == fingerprint(data) else {
                throw CodexReviewAuthenticationFailure.accountCommit(
                    message: "Immutable authentication revision fingerprint mismatch."
                )
            }
            return revision
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func validatedAuthData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
            throw CodexReviewAuthenticationFailure.nonExportableCredentialStore
        }
        let data = try Data(contentsOf: url)
        _ = try validatedAuthObject(data)
        return data
    }

    private static func validatedAuthObject(_ data: Data) throws -> [String: Any] {
        guard data.isEmpty == false,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CodexReviewAuthenticationFailure.nonExportableCredentialStore
        }
        return object
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeAtomically(
        _ data: Data,
        to destinationURL: URL,
        permissions: Int
    ) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        let replacementURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).replacement-\(UUID().uuidString)"
        )
        guard FileManager.default.createFile(
            atPath: replacementURL.path,
            contents: nil,
            attributes: [.posixPermissions: permissions]
        ) else {
            throw CodexReviewAuthenticationFailure.accountCommit(
                message: "Could not create registry replacement file."
            )
        }
        do {
            let handle = try FileHandle(forWritingTo: replacementURL)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    destinationURL,
                    withItemAt: replacementURL
                )
            } else {
                try FileManager.default.moveItem(at: replacementURL, to: destinationURL)
            }
            try synchronizeFile(at: destinationURL)
            try synchronizeDirectory(at: directoryURL)
        } catch {
            try? FileManager.default.removeItem(at: replacementURL)
            throw error
        }
    }

    private static func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    private static func synchronizeDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private static func normalizedAccountKey(from entry: Entry) -> String? {
        let email = entry.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmail = CodexReviewAccount.normalizedEmail(email)
        return entry.accountKey
            .map(CodexReviewAccount.normalizedEmail)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? (normalizedEmail.isEmpty ? nil : normalizedEmail)
    }

    private static func registryURL(codexHomeURL: URL) -> URL {
        accountsDirectoryURL(codexHomeURL: codexHomeURL)
            .appendingPathComponent("registry.json")
    }

    private static func journalURL(codexHomeURL: URL) -> URL {
        accountsDirectoryURL(codexHomeURL: codexHomeURL)
            .appendingPathComponent("mutation-journal.json")
    }

    private static func sharedAuthURL(codexHomeURL: URL) -> URL {
        codexHomeURL.appendingPathComponent("auth.json")
    }

    private static func savedAccountAuthURL(accountKey: String, codexHomeURL: URL) -> URL {
        savedAccountDirectoryURL(accountKey: accountKey, codexHomeURL: codexHomeURL)
            .appendingPathComponent("auth.json")
    }

    private static func immutableAuthURL(
        for entry: Entry,
        accountKey: String,
        codexHomeURL: URL
    ) -> URL? {
        guard let revision = entry.immutableRevision else {
            return nil
        }
        return immutableAuthURL(
            accountKey: accountKey,
            revision: revision,
            codexHomeURL: codexHomeURL
        )
    }

    private static func immutableAuthURL(
        accountKey: String,
        revision: String,
        codexHomeURL: URL
    ) -> URL {
        savedAccountDirectoryURL(accountKey: accountKey, codexHomeURL: codexHomeURL)
            .appendingPathComponent("revisions", isDirectory: true)
            .appendingPathComponent("\(revision).json")
    }

    private static func savedAccountDirectoryURL(accountKey: String, codexHomeURL: URL) -> URL {
        accountsDirectoryURL(codexHomeURL: codexHomeURL)
            .appendingPathComponent(pathComponent(forAccountKey: accountKey), isDirectory: true)
    }

    private static func accountsDirectoryURL(codexHomeURL: URL) -> URL {
        codexHomeURL.appendingPathComponent("accounts", isDirectory: true)
    }

    private static func pathComponent(forAccountKey accountKey: String) -> String {
        let normalizedAccountKey = CodexReviewAccount.normalizedEmail(accountKey)
        switch normalizedAccountKey {
        case ".":
            return "%2E"
        case "..":
            return "%2E%2E"
        default:
            break
        }
        return normalizedAccountKey
            .addingPercentEncoding(withAllowedCharacters: accountDirectoryNameAllowedCharacters)
            ?? normalizedAccountKey
    }

    private static let accountDirectoryNameAllowedCharacters =
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
}
}
