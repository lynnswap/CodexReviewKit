import AppKit
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

private actor RuntimeShutdownCleanupRace {
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func finish(_ value: Bool) {
        guard result == nil else {
            return
        }
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }

    func wait() async -> Bool {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            if let result {
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
            }
        }
    }
}

private func runRuntimeShutdownCleanup(
    timeout: Duration,
    operation: @escaping @Sendable () async -> Void
) async -> Bool {
    let race = RuntimeShutdownCleanupRace()
    let operationTask = Task {
        await operation()
        await race.finish(true)
    }
    let timeoutTask = Task {
        do {
            try await Task.sleep(for: timeout)
        } catch {
            return
        }
        await race.finish(false)
    }
    let result = await race.wait()
    if result {
        timeoutTask.cancel()
    } else {
        operationTask.cancel()
    }
    return result
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
    func stop() async
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
        shutdownCleanupTimeout: Duration = .seconds(2),
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
            shutdownCleanupTimeout: shutdownCleanupTimeout,
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
        shutdownCleanupTimeout: Duration = .seconds(2),
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
                shutdownCleanupTimeout: shutdownCleanupTimeout,
                appServerLifecycleHandler: appServerLifecycleHandler,
                appServerRuntimeFactory: { codexHomeURL in
                    let appServer = try await appServerFactory(codexHomeURL)
                    let modelContainer = CodexModelContainer(appServer: appServer)
                    return .init(
                        appServer: appServer,
                        modelContainer: modelContainer,
                        backend: AppServerCodexReviewBackend(
                            appServer: appServer,
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
    private let shutdownCleanupTimeout: Duration
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
        shutdownCleanupTimeout: Duration = .seconds(2),
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
        self.shutdownCleanupTimeout = shutdownCleanupTimeout
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
                    appServer: appServer,
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
            await stop(store: store)
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
                try await mcpHTTPServer.start()
                startedHTTPServer = mcpHTTPServer
                self.mcpHTTPServer = mcpHTTPServer
            }
            store.transitionToRunning(serverURL: await self.mcpHTTPServer?.url)
            let authSnapshot = try await backend.readAuth()
            await applyAuthSnapshotSerialized(authSnapshot, to: store.auth)
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
        timeoutWarning: String
    ) async {
        let shutdownCleanupTimeout = shutdownCleanupTimeout
        let cleanupResult = await store.cleanupActiveReviewsForRuntimeStop(
            reason: reason,
            workerDrainTimeout: shutdownCleanupTimeout
        ) { request in
            await runRuntimeShutdownCleanup(timeout: shutdownCleanupTimeout) {
                await appServerBackend.cleanupActiveReviewsForShutdown(request)
            }
        }
        if cleanupResult.didComplete == false {
            logger.warning("\(timeoutWarning, privacy: .public)")
        }
    }

    func stop(store: CodexReviewStore) async {
        let appServer = appServer
        let appServerBackend = appServerBackend
        let mcpHTTPServer = mcpHTTPServer
        let hasRuntimeState = appServer != nil || appServerBackend != nil || mcpHTTPServer != nil
        let loginSession = self.loginSession
        self.loginSession = nil
        guard hasRuntimeState || loginSession != nil else {
            return
        }
        logger.info("Stopping review runtime")
        if let appServerBackend {
            let reason = ReviewCancellation.system(message: "Review runtime stopped.")
            await cleanupActiveReviewsForRuntimeTeardown(
                store: store,
                appServerBackend: appServerBackend,
                reason: reason,
                timeoutWarning: "Timed out cleaning active reviews before stopping runtime"
            )
        }
        self.appServer = nil
        clearAppServerModelContainer()
        self.mcpHTTPServer = nil
        authNotificationTask?.cancel()
        authNotificationTask = nil
        await mcpHTTPServer?.stop()
        self.appServerBackend = nil
        await terminateLoginSession(loginSession)
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
            await applyAuthSnapshot(snapshot, to: auth)
        } catch {
            auth.updatePhase(.failed(.runtime(message: error.localizedDescription)))
        }
    }

    func signIn(auth: CodexReviewAuthModel) async throws {
        try await beginStockLogin(auth: auth, activation: .activateAuthenticatedAccount)
    }

    func addAccount(auth: CodexReviewAuthModel) async throws {
        let activeAccountKey = auth.persistedActiveAccountKey ?? auth.selectedAccount?.accountKey
        try await beginStockLogin(
            auth: auth,
            activation: activeAccountKey != nil
                ? .preserveActiveAccount(activeAccountKey)
                : .activateAuthenticatedAccount
        )
    }

    func cancelAuthentication(auth: CodexReviewAuthModel) async {
        guard let session = loginSession else {
            if auth.selectedAccount == nil {
                auth.updatePhase(.signedOut)
            }
            return
        }
        let resultTask = session.takeResultTask()
        resultTask?.cancel()
        do {
            let outcome = try await session.handle.cancel()
            await resultTask?.value
            if case .authenticationCommittedNeedsConnectionReconciliation(let reason) = outcome,
               case .activateAuthenticatedAccount = session.activation
            {
                await reconcilePrimaryAuthentication(
                    session: session,
                    reason: reason,
                    auth: auth
                )
                return
            }
            loginSession = nil
            switch outcome {
            case .cancelled:
                auth.updatePhase(.signedOut)
            case .failed(let message):
                updateAuthenticationFailure(
                    message ?? "Authentication cancellation failed.",
                    auth: auth,
                    activation: session.activation
                )
            case .succeeded, .authenticationCommittedNeedsConnectionReconciliation:
                updateAuthenticationFailure(
                    "Authentication could not be safely committed after cancellation.",
                    auth: auth,
                    activation: session.activation
                )
            }
        } catch {
            loginSession = nil
            auth.updatePhase(.failed(.runtime(message: error.localizedDescription)))
        }
        await resultTask?.value
        await closeLoginRuntimeIfNeeded(session)
        await releaseLoginMutationIfNeeded(session)
    }

    func switchAccount(auth: CodexReviewAuthModel, accountKey: String) async throws {
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
        await attachedStore.closeActiveReviewSessions(reason: .system(message: "Account switched."))
        await stop(store: attachedStore)
        await start(store: attachedStore, forceRestartIfNeeded: true)
        }
    }

    func removeAccount(auth: CodexReviewAuthModel, accountKey: String) async throws {
        try await withAccountMutation {
        let removedActiveAccount = auth.selectedAccount?.accountKey == accountKey
            || auth.persistedActiveAccountKey == accountKey
        if removedActiveAccount, let appServerBackend {
            _ = try? await appServerBackend.logout(.init(accountKey))
        }
        let remaining = auth.persistedAccounts.filter { $0.accountKey != accountKey }
        let activeAccountKey = auth.persistedActiveAccountKey == accountKey
            ? nil
            : auth.persistedActiveAccountKey
        try await accountRegistry.saveAccounts(
            remaining.map(savedAccountPayload(from:)),
            activeAccountKey: activeAccountKey
        )
        try await accountRegistry.removeSavedAccountDirectory(accountKey: accountKey)
        if removedActiveAccount {
            try? await accountRegistry.removeSharedAuth()
        }
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
            await attachedStore.closeActiveReviewSessions(reason: .system(message: "Account removed."))
            await stop(store: attachedStore)
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
        try await withAccountMutation {
        guard let account = auth.selectedAccount else {
            auth.updatePhase(.signedOut)
            auth.selectPersistedAccount(nil)
            return
        }
        let shouldRecycleRuntime = attachedStore != nil && appServerBackend != nil
        if shouldRecycleRuntime {
            await attachedStore?.closeActiveReviewSessions(reason: .system(message: "Signed out."))
        }
        if let appServerBackend {
            _ = try await appServerBackend.logout(.init(account.accountKey))
        }
        let remaining = auth.persistedAccounts.filter { $0.accountKey != account.accountKey }
        try await accountRegistry.saveAccounts(
            remaining.map(savedAccountPayload(from:)),
            activeAccountKey: nil
        )
        try await accountRegistry.removeSavedAccountDirectory(accountKey: account.accountKey)
        try? await accountRegistry.removeSharedAuth()
        auth.updatePhase(.signedOut)
        auth.selectPersistedAccount(nil)
        auth.applyPersistedAccountStates(remaining.map(savedAccountPayload(from:)), activeAccountKey: nil)
        if shouldRecycleRuntime, let attachedStore {
            await stop(store: attachedStore)
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

    private func beginStockLogin(
        auth: CodexReviewAuthModel,
        activation: LoginActivation
    ) async throws {
        guard loginSession == nil else {
            throw CodexReviewAuthenticationFailure.alreadyInProgress
        }
        let mutationLease = try await accountRegistry.beginAuthenticationMutation()
        var runtimeRequiringCleanup: LoginRuntime?
        do {
            let runtime = try await loginRuntime(for: activation)
            runtimeRequiringCleanup = runtime
            let handle = try await runtime.appServer.loginChatGPT(
                accountReadinessTimeout: .seconds(10)
            )
            let session = LoginSession(
                handle: handle,
                runtime: runtime,
                activation: activation,
                mutationLease: mutationLease
            )
            loginSession = session
            auth.updatePhase(.signingIn(.init(
                title: "Sign in to Codex",
                detail: "Continue signing in with your browser.",
                browserURL: handle.authenticationURL.absoluteString,
                userCode: nil
            )))
            do {
                try await externalURLOpener(handle.authenticationURL)
            } catch {
                loginSession = nil
                _ = try? await handle.cancel()
                throw CodexReviewAuthenticationFailure.urlOpen(handle.authenticationURL)
            }
            let sessionID = session.id
            session.installResultTask(Task { @MainActor [weak self, weak auth] in
                guard let self, let auth else {
                    return
                }
                do {
                    let outcome = try await handle.result()
                    await self.finishStockLogin(
                        sessionID: sessionID,
                        outcome: outcome,
                        auth: auth
                    )
                } catch is CancellationError {
                } catch {
                    await self.finishStockLogin(
                        sessionID: sessionID,
                        failure: error,
                        auth: auth
                    )
                }
            })
            runtimeRequiringCleanup = nil
        } catch {
            await closeLoginRuntime(runtimeRequiringCleanup)
            await accountRegistry.finishMutation(mutationLease)
            let failure = (error as? CodexReviewAuthenticationFailure)
                ?? .runtime(message: error.localizedDescription)
            updateAuthenticationFailure(
                failure.localizedDescription,
                auth: auth,
                activation: activation
            )
            if case .preserveActiveAccount = activation {
                throw failure
            }
        }
    }

    private func finishStockLogin(
        sessionID: UUID,
        outcome: CodexLoginOutcome,
        auth: CodexReviewAuthModel
    ) async {
        guard let session = loginSession, session.id == sessionID else {
            return
        }
        switch outcome {
        case .succeeded:
            do {
                let snapshot = try await session.runtime.backend.readAuth()
                let isolatedRateLimits: CodexRateLimits?
                if session.runtime.usesPrimaryRuntime == false {
                    isolatedRateLimits = try? await session.runtime.backend.readRateLimits()
                    await session.runtime.appServer.close()
                    session.markOwnedRuntimeClosed()
                } else {
                    isolatedRateLimits = nil
                }
                let account = await applyAuthSnapshot(
                    snapshot,
                    to: auth,
                    activation: session.activation,
                    authSourceCodexHomeURL: session.runtime.codexHomeURL
                )
                if session.runtime.usesPrimaryRuntime == false {
                    if let account, let isolatedRateLimits {
                        applyRateLimits(isolatedRateLimits, to: account)
                        try? await accountRegistry.updateCachedRateLimits(
                            from: savedAccountPayload(from: account)
                        )
                    }
                    try? FileManager.default.removeItem(at: session.runtime.codexHomeURL)
                } else {
                    await refreshSelectedAccountRateLimits(auth: auth)
                }
            } catch {
                updateAuthenticationFailure(
                    error.localizedDescription,
                    auth: auth,
                    activation: session.activation
                )
            }
            session.markResultCompleted()
            guard session.isReadyForCleanup else {
                return
            }
        case .failed(let message):
            updateAuthenticationFailure(
                message ?? "Authentication failed.",
                auth: auth,
                activation: session.activation
            )
        case .cancelled:
            auth.updatePhase(.signedOut)
        case .authenticationCommittedNeedsConnectionReconciliation(let reason):
            if case .activateAuthenticatedAccount = session.activation {
                await reconcilePrimaryAuthentication(
                    session: session,
                    reason: reason,
                    auth: auth
                )
                return
            }
            updateAuthenticationFailure(
                "Authentication requires runtime reconciliation: \(String(describing: reason))",
                auth: auth,
                activation: session.activation
            )
        }
        await finishLoginSessionCleanup(session)
    }

    private func reconcilePrimaryAuthentication(
        session: LoginSession,
        reason: CodexLoginReconciliationReason,
        auth: CodexReviewAuthModel
    ) async {
        guard loginSession === session else {
            return
        }
        loginSession = nil
        session.takeResultTask()
        do {
            try await accountRuntimeTransitionCoordinator.perform {
                guard let store = attachedStore else {
                    throw CodexReviewAuthenticationFailure.runtime(
                        message: "Authentication committed, but the review store is unavailable for reconciliation."
                    )
                }
                await stop(store: store)
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
                _ = await applyAuthSnapshotSerialized(snapshot, to: auth)
            }
        } catch let failure as CodexReviewAuthenticationFailure {
            auth.updatePhase(.failed(failure))
            logger.error(
                "Primary authentication reconciliation failed after \(String(describing: reason), privacy: .public): \(failure.localizedDescription, privacy: .public)"
            )
        } catch {
            let failure = CodexReviewAuthenticationFailure.runtime(message: error.localizedDescription)
            auth.updatePhase(.failed(failure))
            logger.error(
                "Primary authentication reconciliation failed after \(String(describing: reason), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
        await releaseLoginMutationIfNeeded(session)
    }

    private func finishStockLogin(
        sessionID: UUID,
        failure: any Error,
        auth: CodexReviewAuthModel
    ) async {
        guard let session = loginSession, session.id == sessionID else {
            return
        }
        updateAuthenticationFailure(
            failure.localizedDescription,
            auth: auth,
            activation: session.activation
        )
        await finishLoginSessionCleanup(session)
    }

    private func finishLoginSessionCleanup(_ session: LoginSession) async {
        guard loginSession === session else {
            return
        }
        loginSession = nil
        session.takeResultTask()
        await closeLoginRuntimeIfNeeded(session)
        await releaseLoginMutationIfNeeded(session)
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
        guard session.ownedRuntimeNeedsClose else {
            return
        }
        await closeLoginRuntime(session.runtime)
        session.markOwnedRuntimeClosed()
    }

    private func releaseLoginMutationIfNeeded(_ session: LoginSession) async {
        guard let lease = session.takeMutationLeaseForRelease() else {
            return
        }
        await accountRegistry.finishMutation(lease)
    }

    private func updateAuthenticationFailure(
        _ message: String,
        auth: CodexReviewAuthModel,
        activation: LoginActivation
    ) {
        switch activation {
        case .activateAuthenticatedAccount:
            auth.updatePhase(.failed(.login(message: message)))
        case .preserveActiveAccount:
            auth.updatePhase(.failed(.login(message: message)))
        }
    }

    private func loginRuntime(for activation: LoginActivation) async throws -> LoginRuntime {
        switch activation {
        case .activateAuthenticatedAccount:
            guard let appServer, let appServerBackend else {
                throw CodexReviewAPI.Error.io("Review runtime is not running.")
            }
            return .init(
                appServer: appServer,
                backend: appServerBackend,
                codexHomeURL: codexHomeURL,
                usesPrimaryRuntime: true
            )
        case .preserveActiveAccount:
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

    func interruptReview(_ run: CodexReviewBackendModel.Review.Run, reason: CodexReviewBackendModel.CancellationReason) async throws {
        guard let appServerBackend else {
            throw CodexReviewAPI.Error.io("Review runtime is not running.")
        }
        try await appServerBackend.interruptReview(run, reason: reason)
    }

    func prepareReviewRestart(_ run: CodexReviewBackendModel.Review.Run) async throws -> CodexReviewBackendModel.Review.RestartToken {
        guard let appServerBackend else {
            throw CodexReviewAPI.Error.io("Review runtime is not running.")
        }
        return try await appServerBackend.prepareReviewRestart(run)
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

    func cleanupReview(_ run: CodexReviewBackendModel.Review.Run) async {
        guard let appServerBackend else {
            return
        }
        await appServerBackend.cleanupReview(run)
    }

    @discardableResult
    private func applyAuthSnapshot(
        _ snapshot: CodexReviewBackendModel.Auth.Snapshot,
        to auth: CodexReviewAuthModel,
        activation: LoginActivation = .activateAuthenticatedAccount,
        authSourceCodexHomeURL: URL? = nil
    ) async -> CodexReviewAccount? {
        await accountRuntimeTransitionCoordinator.performInternal {
            await self.applyAuthSnapshotSerialized(
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
    ) async -> CodexReviewAccount? {
        guard let activeAccountID = snapshot.activeAccountID?.rawValue,
              let backendAccount = snapshot.accounts.first(where: { $0.id.rawValue == activeAccountID }),
              let account = Self.monitorAccount(from: backendAccount)
        else {
            if case .activateAuthenticatedAccount = activation {
                auth.selectPersistedAccount(nil)
                auth.updatePhase(.signedOut)
            } else {
                auth.updatePhase(.signedOut)
            }
            return nil
        }
        var persistedAccounts = auth.persistedAccounts
        let persistedAccount: CodexReviewAccount
        if let index = persistedAccounts.firstIndex(where: { $0.accountKey == account.accountKey }) {
            persistedAccounts[index].updateEmail(account.email)
            persistedAccounts[index].updateKind(account.kind, capabilities: account.capabilities)
            persistedAccounts[index].updatePlanType(account.planType)
            persistedAccount = persistedAccounts[index]
        } else {
            persistedAccounts.insert(account, at: 0)
            persistedAccount = account
        }
        let activeAccountKey = activation.resolvedActiveAccountKey(
            authenticatedAccountKey: account.accountKey,
            persistedAccounts: persistedAccounts
        )
        try? await accountRegistry.saveAccounts(
            persistedAccounts.map(savedAccountPayload(from:)),
            activeAccountKey: activeAccountKey
        )
        switch activation {
        case .activateAuthenticatedAccount:
            try? await accountRegistry.saveSharedAuth(for: savedAccountPayload(from: account))
        case .preserveActiveAccount:
            if let authSourceCodexHomeURL {
                try? await accountRegistry.saveSharedAuth(
                    from: authSourceCodexHomeURL,
                    for: savedAccountPayload(from: account)
                )
            }
        }
        auth.applyPersistedAccountStates(
            persistedAccounts.map(savedAccountPayload(from:)),
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
        self.loginSession = nil
        guard appServer != nil || appServerBackend != nil || mcpHTTPServer != nil || loginSession != nil else {
            return
        }
        let message = "Review runtime stopped unexpectedly: \(error.localizedDescription)"
        if let appServerBackend {
            let reason = ReviewCancellation.system(message: message)
            await cleanupActiveReviewsForRuntimeTeardown(
                store: store,
                appServerBackend: appServerBackend,
                reason: reason,
                timeoutWarning: "Timed out cleaning active reviews after runtime failure"
            )
        }
        let failedAppServer = appServer
        let failedMCPHTTPServer = mcpHTTPServer
        appServer = nil
        clearAppServerModelContainer()
        appServerBackend = nil
        mcpHTTPServer = nil
        authNotificationTask = nil
        store.transitionToFailed(message)
        await failedMCPHTTPServer?.stop()
        await terminateLoginSession(loginSession)
        await failedAppServer?.close()
    }

    private func handleAuthNotification(
        _ event: CodexAccountEvent,
        backend: AppServerCodexReviewBackend,
        auth: CodexReviewAuthModel
    ) async {
        switch event {
        case .accountUpdated:
            if let loginSession {
                loginSession.markAccountUpdateConsumed()
                if loginSession.isReadyForCleanup {
                    await finishLoginSessionCleanup(loginSession)
                }
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
            await applyAuthSnapshot(try await backend.readAuth(), to: auth)
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
        try? await accountRegistry.updateCachedRateLimits(
            from: savedAccountPayload(from: selectedAccount)
        )
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
            await persistRefreshedSharedAuth(
                from: codexHomeURL,
                for: account
            )
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
                try? await accountRegistry.updateCachedRateLimits(
                    from: savedAccountPayload(from: account)
                )
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
            try? await accountRegistry.updateCachedRateLimits(
                from: savedAccountPayload(from: account)
            )
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
            try? await accountRegistry.updateCachedRateLimits(
                from: savedAccountPayload(from: account)
            )
            return true
        } catch {
            recordRateLimitRefreshFailure(error, account: account)
            try? await accountRegistry.updateCachedRateLimits(
                from: savedAccountPayload(from: account)
            )
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

    private func terminateLoginSession(_ session: LoginSession?) async {
        guard let session else {
            return
        }
        let resultTask = session.takeResultTask()
        resultTask?.cancel()
        do {
            _ = try await session.handle.cancel()
        } catch {
            logger.error("Failed to cancel login during teardown: \(error.localizedDescription, privacy: .public)")
        }
        await resultTask?.value
        await closeLoginRuntimeIfNeeded(session)
        await releaseLoginMutationIfNeeded(session)
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
    ) async {
        guard let sourceCodexHomeURL else {
            return
        }
        try? await accountRegistry.saveSharedAuth(
            from: sourceCodexHomeURL,
            for: savedAccountPayload(from: account)
        )
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
    var appServer: CodexAppServer
    var backend: AppServerCodexReviewBackend
    var codexHomeURL: URL
    var usesPrimaryRuntime: Bool
}

private actor AccountRegistryStore {
    struct Snapshot: Sendable {
        let accounts: [CodexSavedAccountPayload]
        let activeAccountKey: String?
    }

    struct MutationLease: Hashable, Sendable {
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
        try Disk.updateCachedRateLimits(from: account, codexHomeURL: codexHomeURL)
    }

    func saveSharedAuth(
        from sourceCodexHomeURL: URL? = nil,
        for account: CodexSavedAccountPayload
    ) throws {
        try Disk.saveSharedAuth(
            from: sourceCodexHomeURL ?? codexHomeURL,
            for: account,
            codexHomeURL: codexHomeURL
        )
    }

    func removeSharedAuth() throws {
        try Disk.removeSharedAuth(codexHomeURL: codexHomeURL)
    }

    func removeSavedAccountDirectory(accountKey: String) throws {
        try Disk.removeSavedAccountDirectory(
            accountKey: accountKey,
            codexHomeURL: codexHomeURL
        )
    }

    func copySavedAuth(accountKey: String, to destinationCodexHomeURL: URL) throws -> Bool {
        try Disk.copySavedAuth(
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

    func performInternal<T>(_ operation: () async -> T) async -> T {
        while isTransitioning {
            await withCheckedContinuation { continuation in
                transitionCompletionWaiters.append(continuation)
            }
        }
        isTransitioning = true
        defer { finishTransition() }
        return await operation()
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
    let id = UUID()
    let handle: CodexLoginHandle
    let runtime: LoginRuntime
    let activation: LoginActivation
    let mutationLease: AccountRegistryStore.MutationLease
    private var resultTask: Task<Void, Never>?
    private var didCompleteResult = false
    private var didConsumeAccountUpdate: Bool
    private var didCloseOwnedRuntime = false
    private var didReleaseMutationLease = false

    init(
        handle: CodexLoginHandle,
        runtime: LoginRuntime,
        activation: LoginActivation,
        mutationLease: AccountRegistryStore.MutationLease
    ) {
        self.handle = handle
        self.runtime = runtime
        self.activation = activation
        self.mutationLease = mutationLease
        self.didConsumeAccountUpdate = runtime.usesPrimaryRuntime == false
    }

    func installResultTask(_ task: Task<Void, Never>) {
        precondition(resultTask == nil, "A login session owns exactly one result task.")
        resultTask = task
    }

    func markResultCompleted() {
        didCompleteResult = true
    }

    func markAccountUpdateConsumed() {
        didConsumeAccountUpdate = true
    }

    var isReadyForCleanup: Bool {
        didCompleteResult && didConsumeAccountUpdate
    }

    var ownedRuntimeNeedsClose: Bool {
        runtime.usesPrimaryRuntime == false && didCloseOwnedRuntime == false
    }

    func markOwnedRuntimeClosed() {
        precondition(runtime.usesPrimaryRuntime == false)
        didCloseOwnedRuntime = true
    }

    func takeMutationLeaseForRelease() -> AccountRegistryStore.MutationLease? {
        guard didReleaseMutationLease == false else {
            return nil
        }
        didReleaseMutationLease = true
        return mutationLease
    }

    @discardableResult
    func takeResultTask() -> Task<Void, Never>? {
        defer { resultTask = nil }
        return resultTask
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
        var activeAccountKey: String?
        var accounts: [Entry]
    }

    private struct Entry: Codable {
        var accountKey: String?
        var kind: Kind
        var email: String
        var planType: String?
        var lastActivatedAt: Date?
        var lastRateLimitFetchAt: Date?
        var lastRateLimitError: String?
        var cachedRateLimits: [SavedRateLimitWindow]?

        enum CodingKeys: String, CodingKey {
            case accountKey
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
            kind: Kind,
            email: String,
            planType: String?,
            lastActivatedAt: Date?,
            lastRateLimitFetchAt: Date?,
            lastRateLimitError: String?,
            cachedRateLimits: [SavedRateLimitWindow]?
        ) {
            self.accountKey = accountKey
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

    static func load(codexHomeURL: URL) throws -> AccountRegistryStore.Snapshot {
        let registry = try loadRegistry(codexHomeURL: codexHomeURL)
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
        let existingByAccountKey = Dictionary(uniqueKeysWithValues: existing.accounts.compactMap { entry in
            normalizedAccountKey(from: entry).map { ($0, entry) }
        })
        let normalizedActiveAccountKey = activeAccountKey
            .map(CodexReviewAccount.normalizedEmail)
            .flatMap { accountKey in
                accounts.contains(where: { $0.accountKey == accountKey }) ? accountKey : nil
            }
        let records = accounts.map { account in
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
            if account.accountKey == normalizedActiveAccountKey {
                entry.lastActivatedAt = Date()
            }
            return entry
        }
        try saveRegistry(
            .init(activeAccountKey: normalizedActiveAccountKey, accounts: records),
            codexHomeURL: codexHomeURL
        )
    }

    static func activateAccount(
        _ accountKey: String,
        accounts: [CodexSavedAccountPayload],
        codexHomeURL: URL
    ) throws {
        let normalizedAccountKey = CodexReviewAccount.normalizedEmail(accountKey)
        let savedAuthURL = savedAccountAuthURL(
            accountKey: normalizedAccountKey,
            codexHomeURL: codexHomeURL
        )
        guard FileManager.default.fileExists(atPath: savedAuthURL.path) else {
            throw CodexReviewAPI.Error.io("Saved authentication is missing for account \(normalizedAccountKey).")
        }
        try saveAccounts(
            accounts,
            activeAccountKey: normalizedAccountKey,
            codexHomeURL: codexHomeURL
        )
        try copyAuth(from: savedAuthURL, to: sharedAuthURL(codexHomeURL: codexHomeURL))
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

    static func saveSharedAuth(
        from sourceCodexHomeURL: URL,
        for account: CodexSavedAccountPayload,
        codexHomeURL: URL
    ) throws {
        let sourceURL = sharedAuthURL(codexHomeURL: sourceCodexHomeURL)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return
        }
        try copyAuth(
            from: sourceURL,
            to: savedAccountAuthURL(accountKey: account.accountKey, codexHomeURL: codexHomeURL)
        )
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
        let normalizedAccountKey = CodexReviewAccount.normalizedEmail(accountKey)
        let sourceURL = savedAccountAuthURL(
            accountKey: normalizedAccountKey,
            codexHomeURL: sourceCodexHomeURL
        )
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return false
        }
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
        let url = registryURL(codexHomeURL: codexHomeURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .init(activeAccountKey: nil, accounts: [])
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Registry.self, from: data)
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
        let url = registryURL(codexHomeURL: codexHomeURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(registry).write(to: url, options: .atomic)
    }

    private static func copyAuth(from sourceURL: URL, to destinationURL: URL) throws {
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
        } catch {
            try? FileManager.default.removeItem(at: replacementURL)
            throw error
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

    private static func sharedAuthURL(codexHomeURL: URL) -> URL {
        codexHomeURL.appendingPathComponent("auth.json")
    }

    private static func savedAccountAuthURL(accountKey: String, codexHomeURL: URL) -> URL {
        savedAccountDirectoryURL(accountKey: accountKey, codexHomeURL: codexHomeURL)
            .appendingPathComponent("auth.json")
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
