import AppKit
import Foundation
import OSLog
import CodexReview
import CodexReviewAppServer
import CodexReviewMCPServer

private let logger = Logger(subsystem: "CodexReviewKit", category: "live-store-backend")
private typealias ExternalURLOpener = @MainActor @Sendable (URL) -> Void

private let defaultExternalURLOpener: ExternalURLOpener = { url in
    _ = NSWorkspace.shared.open(url)
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

private struct PendingLoginRuntimeCleanup {
    var client: AppServerClient?
    var codexHomeURL: URL?
    var authenticationSession: (any CodexReviewWebAuthenticationSession)?

    var isEmpty: Bool {
        client == nil && codexHomeURL == nil && authenticationSession == nil
    }
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
    CodexReviewMCPHTTPServerConfiguration
) async -> CodexReviewMCPPortOwner?

package typealias CodexReviewMCPHTTPServerBindChecker = @MainActor @Sendable (
    CodexReviewMCPHTTPServerConfiguration
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
        runtimePreferences: CodexReviewRuntimePreferences = .defaults,
        nativeAuthenticationConfiguration: CodexReviewNativeAuthenticationConfiguration? = nil,
        webAuthenticationSessionFactory: @escaping CodexReviewWebAuthenticationSessionFactory = CodexReviewWebAuthenticationSessions.system
    ) -> CodexReviewStore {
        CodexReviewStore(backend: LiveCodexReviewStoreBackend(
            runtimePreferences: runtimePreferences,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory
        ))
    }

    package static func makeLiveStoreForTesting(
        environment: [String: String],
        runtimePreferences: CodexReviewRuntimePreferences = .defaults,
        nativeAuthenticationConfiguration: CodexReviewNativeAuthenticationConfiguration? = nil,
        webAuthenticationSessionFactory: @escaping CodexReviewWebAuthenticationSessionFactory,
        externalURLOpener: @escaping @MainActor @Sendable (URL) -> Void = defaultExternalURLOpener,
        mcpPortOwnerResolver: CodexReviewMCPPortOwnerResolver? = nil,
        mcpHTTPServerBindChecker: CodexReviewMCPHTTPServerBindChecker? = nil,
        shutdownCleanupTimeout: Duration = .seconds(2),
        transport: any JSONRPCTransport
    ) -> CodexReviewStore {
        makeLiveStoreForTesting(
            environment: environment,
            runtimePreferences: runtimePreferences,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory,
            externalURLOpener: externalURLOpener,
            mcpPortOwnerResolver: mcpPortOwnerResolver,
            mcpHTTPServerBindChecker: mcpHTTPServerBindChecker,
            shutdownCleanupTimeout: shutdownCleanupTimeout,
            transportFactory: { _ in transport }
        )
    }

    package static func makeLiveStoreForTesting(
        environment: [String: String],
        runtimePreferences: CodexReviewRuntimePreferences = .defaults,
        nativeAuthenticationConfiguration: CodexReviewNativeAuthenticationConfiguration? = nil,
        webAuthenticationSessionFactory: @escaping CodexReviewWebAuthenticationSessionFactory,
        externalURLOpener: @escaping @MainActor @Sendable (URL) -> Void = defaultExternalURLOpener,
        mcpHTTPServerFactory: (@MainActor @Sendable (
            CodexReviewStore,
            CodexReviewMCPHTTPServerConfiguration
        ) -> any CodexReviewMCPHTTPServing)? = nil,
        mcpPortOwnerResolver: CodexReviewMCPPortOwnerResolver? = nil,
        mcpHTTPServerBindChecker: CodexReviewMCPHTTPServerBindChecker? = nil,
        shutdownCleanupTimeout: Duration = .seconds(2),
        transportFactory: @escaping @MainActor @Sendable (URL) async throws -> any JSONRPCTransport
    ) -> CodexReviewStore {
        CodexReviewStore(backend: LiveCodexReviewStoreBackend(
            environment: environment,
            runtimePreferences: runtimePreferences,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory,
            externalURLOpener: externalURLOpener,
            mcpHTTPServerFactory: mcpHTTPServerFactory,
            mcpPortOwnerResolver: mcpPortOwnerResolver,
            mcpHTTPServerBindChecker: mcpHTTPServerBindChecker,
            shutdownCleanupTimeout: shutdownCleanupTimeout,
            appServerRuntimeFactory: { codexHomeURL in
                let client = AppServerClient(transport: try await transportFactory(codexHomeURL))
                return .init(
                    client: client,
                    backend: AppServerCodexReviewBackend(client: client)
                )
            }
        ))
    }
}

@MainActor
private final class LiveCodexReviewStoreBackend: CodexReviewStoreBackend {
    typealias MCPHTTPServerFactory = @MainActor @Sendable (
        CodexReviewStore,
        CodexReviewMCPHTTPServerConfiguration
    ) -> any CodexReviewMCPHTTPServing

    let seed: CodexReviewStoreSeed

    private var client: AppServerClient?
    private var appServerBackend: AppServerCodexReviewBackend?
    private var mcpHTTPServer: (any CodexReviewMCPHTTPServing)?
    private var loginChallenge: BackendLoginChallenge?
    private var loginBackend: AppServerCodexReviewBackend?
    private var loginClient: AppServerClient?
    private var loginCodexHomeURL: URL?
    private var loginActivation: LoginActivation = .activateAuthenticatedAccount
    private var isWaitingForLoginAccountUpdate = false
    private var activeAuthenticationSession: (any CodexReviewWebAuthenticationSession)?
    private var authenticationTask: Task<Void, Never>?
    private var authNotificationTask: Task<Void, Never>?
    private var loginNotificationTask: Task<Void, Never>?
    private var settingsSnapshot = CodexReviewSettingsSnapshot()
    private let codexHomeURL: URL
    private let mcpHTTPServerConfiguration: CodexReviewMCPHTTPServerConfiguration
    private let nativeAuthenticationConfiguration: CodexReviewNativeAuthenticationConfiguration?
    private let webAuthenticationSessionFactory: CodexReviewWebAuthenticationSessionFactory
    private let externalURLOpener: ExternalURLOpener
    private let mcpHTTPServerFactory: MCPHTTPServerFactory?
    private let mcpPortOwnerResolver: CodexReviewMCPPortOwnerResolver
    private let mcpHTTPServerBindChecker: CodexReviewMCPHTTPServerBindChecker
    private let appServerRuntimeFactory: AppServerRuntimeFactory
    private let shutdownCleanupTimeout: Duration
    private weak var attachedStore: CodexReviewStore?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runtimePreferences: CodexReviewRuntimePreferences = .defaults,
        nativeAuthenticationConfiguration: CodexReviewNativeAuthenticationConfiguration? = nil,
        webAuthenticationSessionFactory: @escaping CodexReviewWebAuthenticationSessionFactory = CodexReviewWebAuthenticationSessions.system,
        externalURLOpener: @escaping ExternalURLOpener = defaultExternalURLOpener,
        mcpHTTPServerFactory: MCPHTTPServerFactory? = { store, configuration in
            CodexReviewMCPHTTPServer(
                adapter: CodexReviewMCPServer(store: store),
                configuration: configuration
            )
        },
        mcpPortOwnerResolver: CodexReviewMCPPortOwnerResolver? = nil,
        mcpHTTPServerBindChecker: CodexReviewMCPHTTPServerBindChecker? = nil,
        shutdownCleanupTimeout: Duration = .seconds(2),
        appServerRuntimeFactory: AppServerRuntimeFactory? = nil
    ) {
        let runtimePreferences = runtimePreferences.normalized
        codexHomeURL = Self.codexHomeURL(
            runtimePreferences: runtimePreferences,
            environment: environment
        )
        self.mcpHTTPServerConfiguration = .init(
            host: runtimePreferences.mcpHost,
            port: runtimePreferences.mcpPort,
            endpoint: runtimePreferences.mcpPath
        )
        self.nativeAuthenticationConfiguration = nativeAuthenticationConfiguration
        self.webAuthenticationSessionFactory = webAuthenticationSessionFactory
        self.externalURLOpener = externalURLOpener
        self.mcpHTTPServerFactory = mcpHTTPServerFactory
        self.mcpPortOwnerResolver = mcpPortOwnerResolver ?? Self.defaultMCPPortOwnerResolver
        self.mcpHTTPServerBindChecker = mcpHTTPServerBindChecker ?? Self.defaultMCPHTTPServerBindChecker
        self.shutdownCleanupTimeout = shutdownCleanupTimeout
        self.appServerRuntimeFactory = appServerRuntimeFactory ?? Self.makeAppServerRuntimeFactory(
            codexExecutablePath: runtimePreferences.codexExecutablePath
        )
        let registry = CodexReviewAccountRegistry.load(
            codexHomeURL: codexHomeURL
        )
        seed = CodexReviewStoreSeed(
            shouldAutoStartEmbeddedServer: true,
            initialAccounts: registry.accounts,
            initialActiveAccountKey: registry.activeAccountKey
        )
    }

    var isActive: Bool {
        client != nil
    }

    var handlesActiveReviewStopCleanup: Bool {
        true
    }

    var initialSettingsSnapshot: CodexReviewSettingsSnapshot {
        settingsSnapshot
    }

    private static func codexHomeURL(
        runtimePreferences: CodexReviewRuntimePreferences,
        environment: [String: String]
    ) -> URL {
        if let codexHomePath = runtimePreferences.codexHomePath {
            return URL(fileURLWithPath: codexHomePath, isDirectory: true)
        }
        return AppServerCodexHome.url(environment: environment)
    }

    private static func defaultMCPPortOwnerResolver(
        configuration: CodexReviewMCPHTTPServerConfiguration
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
        configuration: CodexReviewMCPHTTPServerConfiguration
    ) async throws {
        try await CodexReviewMCPHTTPServer.checkBind(configuration: configuration)
    }

    private static func makeAppServerRuntimeFactory(
        codexExecutablePath: String?
    ) -> AppServerRuntimeFactory {
        { codexHomeURL in
            let processRuntime = try await Task.detached(priority: .userInitiated) {
                // The configuration probe can wait on `codex app-server --help`; keep it off the MainActor.
                let configuration = AppServerProcessTransport.Configuration(
                    executable: codexExecutablePath,
                    codexHomeURL: codexHomeURL
                )
                let transport = try AppServerProcessTransport(configuration: configuration)
                return AppServerProcessRuntime(
                    transport: transport,
                    threadStartPermissionStrategy: configuration.threadStartPermissionStrategy
                )
            }.value
            let client = AppServerClient(transport: processRuntime.transport)
            return .init(
                client: client,
                backend: AppServerCodexReviewBackend(
                    client: client,
                    threadStartPermissionStrategy: processRuntime.threadStartPermissionStrategy
                )
            )
        }
    }

    func attachStore(_ store: CodexReviewStore) {
        attachedStore = store
    }

    func start(store: CodexReviewStore, forceRestartIfNeeded: Bool) async {
        logger.info("Starting review runtime; forceRestartIfNeeded=\(forceRestartIfNeeded, privacy: .public)")
        if appServerBackend != nil, forceRestartIfNeeded == false {
            logger.info("Review runtime already has an app-server backend")
            store.transitionToRunning(serverURL: await mcpHTTPServer?.url)
            return
        }
        if forceRestartIfNeeded {
            await stop(store: store)
        }

        var startedClient: AppServerClient?
        var startedHTTPServer: (any CodexReviewMCPHTTPServing)?
        do {
            if mcpHTTPServerFactory != nil {
                try await mcpHTTPServerBindChecker(mcpHTTPServerConfiguration)
            }
            let runtime = try await appServerRuntimeFactory(codexHomeURL)
            let client = runtime.client
            let backend = runtime.backend
            startedClient = client
            self.client = client
            self.appServerBackend = backend
            observeAuthNotifications(client: client, backend: backend, store: store)
            if let mcpHTTPServerFactory {
                let mcpHTTPServer = mcpHTTPServerFactory(store, mcpHTTPServerConfiguration)
                try await mcpHTTPServer.start()
                startedHTTPServer = mcpHTTPServer
                self.mcpHTTPServer = mcpHTTPServer
            }
            store.transitionToRunning(serverURL: await self.mcpHTTPServer?.url)
            let authSnapshot = try await backend.readAuth()
            applyAuthSnapshot(authSnapshot, to: store.auth)
            await refreshSelectedAccountRateLimits(auth: store.auth)
            logger.info("Review runtime started")
        } catch {
            let failureMessage = await runtimeStartupFailureMessage(for: error)
            logger.error("Review runtime failed to start: \(failureMessage, privacy: .public)")
            await startedHTTPServer?.stop()
            await startedClient?.close()
            self.client = nil
            self.appServerBackend = nil
            self.mcpHTTPServer = nil
            authNotificationTask?.cancel()
            authNotificationTask = nil
            store.transitionToFailed(failureMessage)
        }
    }

    private func runtimeStartupFailureMessage(for error: Error) async -> String {
        if let mcpHTTPServerError = error as? CodexReviewMCPHTTPServerError {
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

    private func cancelActiveReviewsForRuntimeTeardown(
        store: CodexReviewStore,
        appServerBackend: AppServerCodexReviewBackend,
        reason: ReviewCancellation,
        timeoutWarning: String
    ) async {
        let locallyCancelledJobIDs = store.cancelActiveReviewsLocallyForRuntimeStop(
            reason: reason,
            cancelWorkers: false
        )
        store.cancelAndDetachReviewWorkersForRuntimeStop(jobIDs: locallyCancelledJobIDs)
        let didCleanUp = await runRuntimeShutdownCleanup(timeout: shutdownCleanupTimeout) {
            await appServerBackend.cleanupActiveReviewsForShutdown(reason: .init(message: reason.message))
        }
        if didCleanUp == false {
            logger.warning("\(timeoutWarning, privacy: .public)")
        }
    }

    func stop(store: CodexReviewStore) async {
        let client = client
        let appServerBackend = appServerBackend
        let mcpHTTPServer = mcpHTTPServer
        let hasRuntimeState = client != nil || appServerBackend != nil || mcpHTTPServer != nil
        let loginCleanup = takeLoginRuntimeForCleanup()
        guard hasRuntimeState || loginCleanup.isEmpty == false else {
            return
        }
        logger.info("Stopping review runtime")
        if let appServerBackend {
            let reason = ReviewCancellation.system(message: "Review runtime stopped.")
            await cancelActiveReviewsForRuntimeTeardown(
                store: store,
                appServerBackend: appServerBackend,
                reason: reason,
                timeoutWarning: "Timed out cleaning active reviews before stopping runtime"
            )
        }
        self.client = nil
        self.mcpHTTPServer = nil
        authNotificationTask?.cancel()
        authNotificationTask = nil
        await mcpHTTPServer?.stop()
        self.appServerBackend = nil
        await cleanupLoginRuntime(loginCleanup)
        await client?.close()
        logger.info("Review runtime stopped")
    }

    func waitUntilStopped() async {}

    func refreshSettings() async throws -> CodexReviewSettingsSnapshot {
        guard let appServerBackend else {
            return settingsSnapshot
        }
        settingsSnapshot = try await Self.monitorSettings(from: appServerBackend.readSettings())
        return settingsSnapshot
    }

    func updateSettingsModel(
        _ model: String?,
        reasoningEffort: CodexReviewReasoningEffort?,
        persistReasoningEffort: Bool,
        serviceTier: CodexReviewServiceTier?,
        persistServiceTier: Bool
    ) async throws {
        guard let appServerBackend else {
            return
        }
        var change = BackendSettingsChange(
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
        _ reasoningEffort: CodexReviewReasoningEffort?
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
        _ serviceTier: CodexReviewServiceTier?
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
            applyAuthSnapshot(snapshot, to: auth)
        } catch {
            auth.updatePhase(.failed(message: error.localizedDescription))
        }
    }

    func signIn(auth: CodexReviewAuthModel) async {
        await startLogin(auth: auth, activation: .activateAuthenticatedAccount)
    }

    func addAccount(auth: CodexReviewAuthModel) async {
        let activeAccountKey = auth.persistedActiveAccountKey ?? auth.selectedAccount?.accountKey
        await startLogin(
            auth: auth,
            activation: activeAccountKey != nil
                ? .preserveActiveAccount(activeAccountKey)
                : .activateAuthenticatedAccount
        )
    }

    func cancelAuthentication(auth: CodexReviewAuthModel) async {
        let activeAuthenticationSession = activeAuthenticationSession
        self.activeAuthenticationSession = nil
        authenticationTask?.cancel()
        authenticationTask = nil
        loginNotificationTask?.cancel()
        loginNotificationTask = nil
        let loginBackend = loginBackend
        self.loginBackend = nil
        isWaitingForLoginAccountUpdate = false
        let loginClient = loginClient
        self.loginClient = nil
        let loginCodexHomeURL = loginCodexHomeURL
        self.loginCodexHomeURL = nil
        defer {
            loginChallenge = nil
        }
        await activeAuthenticationSession?.cancel()
        guard let loginBackend, let loginChallenge else {
            if auth.selectedAccount == nil {
                auth.updatePhase(.signedOut)
            }
            await closeIsolatedLoginRuntime(client: loginClient, codexHomeURL: loginCodexHomeURL)
            return
        }
        do {
            try await loginBackend.cancelLogin(loginChallenge)
            auth.updatePhase(auth.selectedAccount == nil ? .signedOut : .signedOut)
        } catch {
            auth.updatePhase(.failed(message: error.localizedDescription))
        }
        await closeIsolatedLoginRuntime(client: loginClient, codexHomeURL: loginCodexHomeURL)
    }

    func switchAccount(auth: CodexReviewAuthModel, accountKey: String) async throws {
        guard auth.persistedAccounts.contains(where: { $0.accountKey == accountKey }) else {
            return
        }
        try CodexReviewAccountRegistry.activateAccount(
            accountKey,
            accounts: auth.persistedAccounts,
            codexHomeURL: codexHomeURL
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

    func removeAccount(auth: CodexReviewAuthModel, accountKey: String) async throws {
        let removedActiveAccount = auth.selectedAccount?.accountKey == accountKey
            || auth.persistedActiveAccountKey == accountKey
        if removedActiveAccount, let appServerBackend {
            _ = try? await appServerBackend.logout(.init(accountKey))
        }
        let remaining = auth.persistedAccounts.filter { $0.accountKey != accountKey }
        let activeAccountKey = auth.persistedActiveAccountKey == accountKey
            ? nil
            : auth.persistedActiveAccountKey
        try CodexReviewAccountRegistry.saveAccounts(
            remaining,
            activeAccountKey: activeAccountKey,
            codexHomeURL: codexHomeURL
        )
        try CodexReviewAccountRegistry.removeSavedAccountDirectory(
            accountKey: accountKey,
            codexHomeURL: codexHomeURL
        )
        if removedActiveAccount {
            try? CodexReviewAccountRegistry.removeSharedAuth(codexHomeURL: codexHomeURL)
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
        try CodexReviewAccountRegistry.saveAccounts(
            accounts,
            activeAccountKey: auth.persistedActiveAccountKey,
            codexHomeURL: codexHomeURL
        )
        auth.applyPersistedAccountStates(accounts.map(savedAccountPayload(from:)))
    }

    func signOutActiveAccount(auth: CodexReviewAuthModel) async throws {
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
        try CodexReviewAccountRegistry.saveAccounts(
            remaining,
            activeAccountKey: nil,
            codexHomeURL: codexHomeURL
        )
        try CodexReviewAccountRegistry.removeSavedAccountDirectory(
            accountKey: account.accountKey,
            codexHomeURL: codexHomeURL
        )
        try? CodexReviewAccountRegistry.removeSharedAuth(codexHomeURL: codexHomeURL)
        auth.updatePhase(.signedOut)
        auth.selectPersistedAccount(nil)
        auth.applyPersistedAccountStates(remaining.map(savedAccountPayload(from:)), activeAccountKey: nil)
        if shouldRecycleRuntime, let attachedStore {
            await stop(store: attachedStore)
            await start(store: attachedStore, forceRestartIfNeeded: true)
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

    private func startLogin(auth: CodexReviewAuthModel, activation: LoginActivation) async {
        var isolatedLoginClient: AppServerClient?
        var isolatedLoginCodexHomeURL: URL?
        do {
            let runtime = try await loginRuntime(for: activation)
            let appServerBackend = runtime.backend
            let loginCodexHomeURL = runtime.codexHomeURL
            let loginClient = runtime.usesPrimaryRuntime ? nil : runtime.client
            isolatedLoginClient = loginClient
            isolatedLoginCodexHomeURL = loginCodexHomeURL
            guard runtime.usesPrimaryRuntime || self.appServerBackend != nil else {
                logger.error("Cannot start login because review runtime is not running")
                updateAuthenticationFailure(
                    "Review runtime is not running.",
                    auth: auth,
                    activation: activation
                )
                await closeIsolatedLoginRuntime(client: loginClient, codexHomeURL: loginCodexHomeURL)
                return
            }
            logger.info("Starting ChatGPT login")
            let challenge = try await appServerBackend.startLogin(.init(
                nativeWebAuthenticationCallbackScheme: nativeAuthenticationConfiguration?.callbackScheme
            ))
            loginChallenge = challenge
            loginBackend = appServerBackend
            self.loginClient = loginClient
            self.loginCodexHomeURL = loginCodexHomeURL
            loginActivation = activation
            isWaitingForLoginAccountUpdate = false
            if let loginClient {
                observeLoginNotifications(client: loginClient, backend: appServerBackend, auth: auth)
            }
            logger.info("Received ChatGPT login challenge")
            let nativeCallbackScheme = challenge.nativeWebAuthenticationCallbackScheme
            let usesNativeAuthentication = nativeAuthenticationConfiguration != nil && challenge.verificationURL != nil
            auth.updatePhase(.signingIn(.init(
                title: "Sign in to Codex",
                detail: challenge.signInDetail(nativeAuthentication: usesNativeAuthentication),
                browserURL: challenge.verificationURL?.absoluteString,
                userCode: challenge.userCode
            )))
            guard let nativeAuthenticationConfiguration, challenge.verificationURL != nil else {
                if let verificationURL = challenge.verificationURL {
                    externalURLOpener(verificationURL)
                }
                return
            }
            let authURL = try Self.authenticationURL(from: challenge)
            let callbackScheme = nativeCallbackScheme ?? nativeAuthenticationConfiguration.callbackScheme
            guard callbackScheme == nativeAuthenticationConfiguration.callbackScheme else {
                try? await appServerBackend.cancelLogin(challenge)
                loginChallenge = nil
                loginBackend = nil
                self.loginClient = nil
                self.loginCodexHomeURL = nil
                updateAuthenticationFailure(
                    "Authentication callback is misconfigured.",
                    auth: auth,
                    activation: activation
                )
                await closeIsolatedLoginRuntime(client: loginClient, codexHomeURL: loginCodexHomeURL)
                return
            }
            let session = try await webAuthenticationSessionFactory(
                authURL,
                callbackScheme,
                nativeAuthenticationConfiguration.browserSessionPolicy,
                nativeAuthenticationConfiguration.presentationAnchorProvider
            )
            activeAuthenticationSession = session
            authenticationTask = Task { @MainActor [weak self, weak auth] in
                guard let self, let auth else {
                    return
                }
                await self.monitorAuthenticationSession(
                    challenge: challenge,
                    session: session,
                    completesLoginThroughCallback: nativeCallbackScheme != nil,
                    auth: auth
                )
            }
        } catch {
            logger.error("ChatGPT login failed to start: \(error.localizedDescription, privacy: .public)")
            let pendingLoginBackend = loginBackend
            let pendingLoginChallenge = loginChallenge
            loginChallenge = nil
            loginBackend = nil
            isWaitingForLoginAccountUpdate = false
            let loginClient = loginClient ?? isolatedLoginClient
            self.loginClient = nil
            let loginCodexHomeURL = loginCodexHomeURL ?? isolatedLoginCodexHomeURL
            self.loginCodexHomeURL = nil
            activeAuthenticationSession = nil
            authenticationTask?.cancel()
            authenticationTask = nil
            loginNotificationTask?.cancel()
            loginNotificationTask = nil
            if let pendingLoginBackend, let pendingLoginChallenge {
                try? await pendingLoginBackend.cancelLogin(pendingLoginChallenge)
            }
            await closeIsolatedLoginRuntime(client: loginClient, codexHomeURL: loginCodexHomeURL)
            updateAuthenticationFailure(
                error.localizedDescription,
                auth: auth,
                activation: activation
            )
        }
    }

    private func monitorAuthenticationSession(
        challenge: BackendLoginChallenge,
        session: any CodexReviewWebAuthenticationSession,
        completesLoginThroughCallback: Bool,
        auth: CodexReviewAuthModel
    ) async {
        do {
            let callbackURL = try await session.waitForCallbackURL()
            guard loginChallenge?.id == challenge.id else {
                return
            }
            guard completesLoginThroughCallback else {
                logger.info("Authentication session completed; waiting for app-server login completion notification")
                return
            }
            guard let loginBackend else {
                return
            }
            let snapshot = try await loginBackend.completeLogin(.init(
                challengeID: challenge.id,
                callbackURL: callbackURL.absoluteString
            ))
            let activation = loginActivation
            let loginClient = loginClient
            let loginCodexHomeURL = loginCodexHomeURL
            loginChallenge = nil
            self.loginBackend = nil
            isWaitingForLoginAccountUpdate = false
            self.loginClient = nil
            self.loginCodexHomeURL = nil
            activeAuthenticationSession = nil
            authenticationTask = nil
            loginNotificationTask?.cancel()
            loginNotificationTask = nil
            let account = applyAuthSnapshot(
                snapshot,
                to: auth,
                activation: activation,
                authSourceCodexHomeURL: loginCodexHomeURL
            )
            await refreshSelectedAccountRateLimits(auth: auth)
            if case .preserveActiveAccount = activation, let account {
                let didRefresh = await refreshRateLimits(for: account, using: loginBackend, source: "login-runtime")
                if didRefresh {
                    persistRefreshedSharedAuth(
                        from: loginCodexHomeURL,
                        for: account
                    )
                }
            }
            await closeIsolatedLoginRuntime(client: loginClient, codexHomeURL: loginCodexHomeURL)
        } catch is CancellationError {
            await handleAuthenticationSessionCancelled(challenge: challenge, auth: auth)
        } catch CodexReviewNativeAuthenticationError.cancelled {
            await handleAuthenticationSessionCancelled(challenge: challenge, auth: auth)
        } catch {
            guard loginChallenge?.id == challenge.id else {
                return
            }
            logger.error("ChatGPT login failed to complete: \(error.localizedDescription, privacy: .public)")
            let loginClient = loginClient
            let loginCodexHomeURL = loginCodexHomeURL
            loginChallenge = nil
            self.loginBackend = nil
            isWaitingForLoginAccountUpdate = false
            self.loginClient = nil
            self.loginCodexHomeURL = nil
            activeAuthenticationSession = nil
            authenticationTask = nil
            loginNotificationTask?.cancel()
            loginNotificationTask = nil
            await closeIsolatedLoginRuntime(client: loginClient, codexHomeURL: loginCodexHomeURL)
            updateAuthenticationFailure(
                error.localizedDescription,
                auth: auth,
                activation: loginActivation
            )
        }
    }

    private func updateAuthenticationFailure(
        _ message: String,
        auth: CodexReviewAuthModel,
        activation: LoginActivation
    ) {
        switch activation {
        case .activateAuthenticatedAccount:
            auth.updatePhase(.failed(message: message))
        case .preserveActiveAccount:
            auth.recordAuthenticationFailure(message: message)
        }
    }

    private func loginRuntime(for activation: LoginActivation) async throws -> LoginRuntime {
        switch activation {
        case .activateAuthenticatedAccount:
            guard let client, let appServerBackend else {
                throw ReviewError.io("Review runtime is not running.")
            }
            return .init(
                client: client,
                backend: appServerBackend,
                codexHomeURL: codexHomeURL,
                usesPrimaryRuntime: true
            )
        case .preserveActiveAccount:
            let temporaryCodexHomeURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-review-auth-\(UUID().uuidString)", isDirectory: true)
            let runtime = try await appServerRuntimeFactory(temporaryCodexHomeURL)
            return .init(
                client: runtime.client,
                backend: runtime.backend,
                codexHomeURL: temporaryCodexHomeURL,
                usesPrimaryRuntime: false
            )
        }
    }

    private func handleAuthenticationSessionCancelled(
        challenge: BackendLoginChallenge,
        auth: CodexReviewAuthModel
    ) async {
        guard loginChallenge?.id == challenge.id else {
            return
        }
        logger.info("ChatGPT login session was cancelled")
        let loginBackend = loginBackend
        let loginClient = loginClient
        let loginCodexHomeURL = loginCodexHomeURL
        if let loginBackend {
            do {
                try await loginBackend.cancelLogin(challenge)
            } catch {
                logger.error("Failed to cancel ChatGPT login after session close: \(error.localizedDescription, privacy: .public)")
            }
        }
        loginChallenge = nil
        self.loginBackend = nil
        isWaitingForLoginAccountUpdate = false
        self.loginClient = nil
        self.loginCodexHomeURL = nil
        activeAuthenticationSession = nil
        authenticationTask = nil
        loginNotificationTask?.cancel()
        loginNotificationTask = nil
        auth.updatePhase(.signedOut)
        await closeIsolatedLoginRuntime(client: loginClient, codexHomeURL: loginCodexHomeURL)
    }

    func startReview(_ request: BackendReviewStart) async throws -> BackendReviewRun {
        guard let appServerBackend else {
            throw ReviewError.io("Review runtime is not running.")
        }
        return try await appServerBackend.startReview(request)
    }

    func interruptReview(_ run: BackendReviewRun, reason: BackendCancellationReason) async throws {
        guard let appServerBackend else {
            throw ReviewError.io("Review runtime is not running.")
        }
        try await appServerBackend.interruptReview(run, reason: reason)
    }

    func beginReviewRecovery(
        _ run: BackendReviewRun,
        reason: BackendCancellationReason
    ) async throws -> BackendReviewRecoveryToken {
        guard let appServerBackend else {
            throw ReviewError.io("Review runtime is not running.")
        }
        return try await appServerBackend.beginReviewRecovery(run, reason: reason)
    }

    func resumeReviewRecovery(
        _ token: BackendReviewRecoveryToken,
        request: BackendReviewStart
    ) async throws -> BackendReviewRun {
        guard let appServerBackend else {
            throw ReviewError.io("Review runtime is not running.")
        }
        return try await appServerBackend.resumeReviewRecovery(token, request: request)
    }

    func cleanupReview(_ run: BackendReviewRun) async {
        guard let appServerBackend else {
            return
        }
        await appServerBackend.cleanupReview(run)
    }

    func events(for run: BackendReviewRun) async -> AsyncThrowingStream<BackendReviewEvent, Error> {
        guard let appServerBackend else {
            return AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }
        return await appServerBackend.events(for: run)
    }

    @discardableResult
    private func applyAuthSnapshot(
        _ snapshot: BackendAuthSnapshot,
        to auth: CodexReviewAuthModel,
        activation: LoginActivation = .activateAuthenticatedAccount,
        authSourceCodexHomeURL: URL? = nil
    ) -> CodexAccount? {
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
        let persistedAccount: CodexAccount
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
        try? CodexReviewAccountRegistry.saveAccounts(
            persistedAccounts,
            activeAccountKey: activeAccountKey,
            codexHomeURL: codexHomeURL
        )
        switch activation {
        case .activateAuthenticatedAccount:
            try? CodexReviewAccountRegistry.saveSharedAuth(
                for: account,
                codexHomeURL: codexHomeURL
            )
        case .preserveActiveAccount:
            if let authSourceCodexHomeURL {
                try? CodexReviewAccountRegistry.saveSharedAuth(
                    from: authSourceCodexHomeURL,
                    for: account,
                    codexHomeURL: codexHomeURL
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
        client: AppServerClient,
        backend: AppServerCodexReviewBackend,
        store: CodexReviewStore
    ) {
        authNotificationTask?.cancel()
        authNotificationTask = Task { @MainActor [weak self, weak store] in
            guard let self, let store else {
                return
            }
            let stream = await client.notificationStream()
            do {
                for try await notification in stream {
                    await self.handleAuthNotification(
                        notification,
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

    private func markRuntimeFailedAfterNotificationStreamError(
        _ error: any Error,
        store: CodexReviewStore
    ) async {
        let loginCleanup = takeLoginRuntimeForCleanup()
        guard client != nil || appServerBackend != nil || mcpHTTPServer != nil || loginCleanup.isEmpty == false else {
            return
        }
        let message = "Review runtime stopped unexpectedly: \(error.localizedDescription)"
        if let appServerBackend {
            let reason = ReviewCancellation.system(message: message)
            await cancelActiveReviewsForRuntimeTeardown(
                store: store,
                appServerBackend: appServerBackend,
                reason: reason,
                timeoutWarning: "Timed out cleaning active reviews after runtime failure"
            )
        }
        let failedClient = client
        let failedMCPHTTPServer = mcpHTTPServer
        client = nil
        appServerBackend = nil
        mcpHTTPServer = nil
        authNotificationTask = nil
        store.transitionToFailed(message)
        await failedMCPHTTPServer?.stop()
        await cleanupLoginRuntime(loginCleanup)
        await failedClient?.close()
    }

    private func handleAuthNotification(
        _ notification: JSONRPCNotification,
        backend: AppServerCodexReviewBackend,
        auth: CodexReviewAuthModel
    ) async {
        switch notification.method {
        case "account/login/completed":
            await handleLoginCompletedNotification(notification, backend: backend, auth: auth)
        case "account/updated":
            await handleAccountUpdatedNotification(backend: backend, auth: auth)
        case "account/rateLimits/updated":
            await applyRateLimitsUpdatedNotification(notification, auth: auth)
        default:
            return
        }
    }

    private func observeLoginNotifications(
        client: AppServerClient,
        backend: AppServerCodexReviewBackend,
        auth: CodexReviewAuthModel
    ) {
        loginNotificationTask?.cancel()
        loginNotificationTask = Task { @MainActor [weak self, weak auth] in
            guard let self, let auth else {
                return
            }
            let stream = await client.notificationStream()
            do {
                for try await notification in stream
                    where notification.method == "account/login/completed"
                        || notification.method == "account/updated"
                {
                    await self.handleLoginRuntimeNotification(notification, backend: backend, auth: auth)
                }
            } catch is CancellationError {
            } catch {
                logger.error("Login notification stream ended: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func handleLoginRuntimeNotification(
        _ notification: JSONRPCNotification,
        backend: AppServerCodexReviewBackend,
        auth: CodexReviewAuthModel
    ) async {
        switch notification.method {
        case "account/login/completed":
            await handleLoginCompletedNotification(notification, backend: backend, auth: auth)
        case "account/updated":
            guard loginBackend != nil, isWaitingForLoginAccountUpdate else {
                return
            }
            await finishCompletedLoginAfterAccountUpdate(backend: backend, auth: auth)
        default:
            return
        }
    }

    private func handleLoginCompletedNotification(
        _ notification: JSONRPCNotification,
        backend: AppServerCodexReviewBackend,
        auth: CodexReviewAuthModel
    ) async {
        guard notification.method == "account/login/completed" else {
            await handleAccountUpdatedNotification(backend: backend, auth: auth)
            return
        }
        do {
            let payload = try JSONDecoder().decode(AppServerAccountLoginCompletedNotification.self, from: notification.params)
            guard payload.loginID == nil || payload.loginID == loginChallenge?.id else {
                return
            }
            loginChallenge = nil
            let loginClient = loginClient
            let loginCodexHomeURL = loginCodexHomeURL
            let activeAuthenticationSession = activeAuthenticationSession
            self.activeAuthenticationSession = nil
            authenticationTask?.cancel()
            authenticationTask = nil
            await activeAuthenticationSession?.cancel()
            guard payload.success else {
                updateAuthenticationFailure(
                    payload.error ?? "Authentication failed.",
                    auth: auth,
                    activation: loginActivation
                )
                self.loginBackend = nil
                isWaitingForLoginAccountUpdate = false
                self.loginClient = nil
                self.loginCodexHomeURL = nil
                loginNotificationTask?.cancel()
                loginNotificationTask = nil
                await closeIsolatedLoginRuntime(client: loginClient, codexHomeURL: loginCodexHomeURL)
                return
            }
            isWaitingForLoginAccountUpdate = true
            logger.info("ChatGPT login completed; waiting for account update notification")
        } catch {
            logger.error("Failed to decode account login completion: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleAccountUpdatedNotification(
        backend: AppServerCodexReviewBackend,
        auth: CodexReviewAuthModel
    ) async {
        guard isWaitingForLoginAccountUpdate else {
            await refreshAuthAfterAccountNotification(backend: backend, auth: auth)
            return
        }
        await finishCompletedLoginAfterAccountUpdate(backend: backend, auth: auth)
    }

    private func finishCompletedLoginAfterAccountUpdate(
        backend: AppServerCodexReviewBackend,
        auth: CodexReviewAuthModel
    ) async {
        let activation = loginActivation
        let loginBackend = loginBackend
        let loginClient = loginClient
        let loginCodexHomeURL = loginCodexHomeURL
        let activeAuthenticationSession = activeAuthenticationSession
        do {
            loginChallenge = nil
            self.activeAuthenticationSession = nil
            authenticationTask?.cancel()
            authenticationTask = nil
            await activeAuthenticationSession?.cancel()
            let account = applyAuthSnapshot(
                try await backend.readAuth(),
                to: auth,
                activation: activation,
                authSourceCodexHomeURL: loginCodexHomeURL
            )
            if case .preserveActiveAccount = activation, let account, let loginBackend {
                let didRefresh = await refreshRateLimits(for: account, using: loginBackend, source: "login-runtime")
                if didRefresh {
                    persistRefreshedSharedAuth(
                        from: loginCodexHomeURL,
                        for: account
                    )
                }
            } else {
                await refreshSelectedAccountRateLimits(auth: auth)
            }
        } catch {
            updateAuthenticationFailure(
                error.localizedDescription,
                auth: auth,
                activation: activation
            )
        }
        self.loginBackend = nil
        self.loginClient = nil
        self.loginCodexHomeURL = nil
        isWaitingForLoginAccountUpdate = false
        loginNotificationTask?.cancel()
        loginNotificationTask = nil
        await closeIsolatedLoginRuntime(client: loginClient, codexHomeURL: loginCodexHomeURL)
    }

    private func refreshAuthAfterAccountNotification(
        backend: AppServerCodexReviewBackend,
        auth: CodexReviewAuthModel
    ) async {
        do {
            applyAuthSnapshot(try await backend.readAuth(), to: auth)
            await refreshSelectedAccountRateLimits(auth: auth)
        } catch {
            auth.updatePhase(.failed(message: error.localizedDescription))
        }
    }

    private func applyRateLimitsUpdatedNotification(
        _ notification: JSONRPCNotification,
        auth: CodexReviewAuthModel
    ) async {
        do {
            let payload = try JSONDecoder().decode(AppServerAccountRateLimitsUpdatedPayload.self, from: notification.params)
            guard let selectedAccount = auth.selectedAccount else {
                return
            }
            guard selectedAccount.capabilities.supportsRateLimitRefresh else {
                return
            }
            guard AppServerAccountRateLimitsResponse.isCodexRateLimit(payload.rateLimits.limitID) else {
                return
            }
            let response = AppServerAccountRateLimitsResponse(rateLimits: payload.rateLimits)
            applyRateLimits(
                windows: response.codexRateLimitWindows,
                planType: response.codexPlanType,
                to: selectedAccount
            )
            try? CodexReviewAccountRegistry.updateCachedRateLimits(
                from: selectedAccount,
                codexHomeURL: codexHomeURL
            )
        } catch {
            logger.error("Failed to decode account rate limit update: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshSelectedAccountRateLimits(auth: CodexReviewAuthModel) async {
        guard let selectedAccount = auth.selectedAccount else {
            return
        }
        await refreshRateLimits(for: selectedAccount, auth: auth)
    }

    private func refreshRateLimits(for account: CodexAccount, auth: CodexReviewAuthModel) async {
        guard account.capabilities.supportsRateLimitRefresh else {
            return
        }
        guard auth.persistedActiveAccountKey == account.accountKey else {
            await refreshSavedAccountRateLimits(for: account)
            return
        }
        let didRefresh = await refreshRateLimits(for: account, using: appServerBackend, source: "active-runtime")
        if didRefresh {
            persistRefreshedSharedAuth(
                from: codexHomeURL,
                for: account
            )
        }
    }

    private func refreshSavedAccountRateLimits(for account: CodexAccount) async {
        let temporaryCodexHomeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-review-rate-limits-\(UUID().uuidString)", isDirectory: true)
        do {
            guard try CodexReviewAccountRegistry.copySavedAuth(
                accountKey: account.accountKey,
                from: codexHomeURL,
                to: temporaryCodexHomeURL
            ) else {
                account.markRateLimitReauthenticationRequired(
                    fetchedAt: Date(),
                    error: "Saved account authentication is not available."
                )
                try? CodexReviewAccountRegistry.updateCachedRateLimits(
                    from: account,
                    codexHomeURL: codexHomeURL
                )
                return
            }
            let runtime = try await appServerRuntimeFactory(temporaryCodexHomeURL)
            let didRefresh = await refreshRateLimits(for: account, using: runtime.backend, source: "saved-auth-isolated-runtime")
            do {
                if didRefresh {
                    try CodexReviewAccountRegistry.saveSharedAuth(
                        from: temporaryCodexHomeURL,
                        for: account,
                        codexHomeURL: codexHomeURL
                    )
                }
            } catch {
                await closeIsolatedLoginRuntime(client: runtime.client, codexHomeURL: temporaryCodexHomeURL)
                throw error
            }
            await closeIsolatedLoginRuntime(client: runtime.client, codexHomeURL: temporaryCodexHomeURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryCodexHomeURL)
            account.updateRateLimitFetchMetadata(fetchedAt: Date(), error: error.localizedDescription)
            try? CodexReviewAccountRegistry.updateCachedRateLimits(
                from: account,
                codexHomeURL: codexHomeURL
            )
        }
    }

    private func refreshRateLimits(
        for account: CodexAccount,
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
            applyRateLimits(
                windows: response.codexRateLimitWindows,
                planType: response.codexPlanType,
                to: account
            )
            try? CodexReviewAccountRegistry.updateCachedRateLimits(
                from: account,
                codexHomeURL: codexHomeURL
            )
            return true
        } catch {
            recordRateLimitRefreshFailure(error, account: account)
            try? CodexReviewAccountRegistry.updateCachedRateLimits(
                from: account,
                codexHomeURL: codexHomeURL
            )
            return false
        }
    }

    private func validateRateLimitBackendAccount(
        _ account: CodexAccount,
        using backend: AppServerCodexReviewBackend
    ) async throws {
        let snapshot = try await backend.readAuth()
        guard let activeAccountID = snapshot.activeAccountID?.rawValue.nilIfEmpty else {
            throw ReviewError.io("Saved authentication is missing for \(account.maskedEmail). Sign in again.")
        }
        let actualAccountKey = normalizedReviewAccountEmail(email: activeAccountID)
        guard actualAccountKey == account.accountKey else {
            let actualEmail = snapshot.accounts.first(where: { $0.id.rawValue == activeAccountID })?.label
                ?? activeAccountID
            let maskedActualEmail = self.maskedReviewAccountEmail(actualEmail)
            throw ReviewError.io("Saved authentication is for \(maskedActualEmail), not \(account.maskedEmail). Sign in again.")
        }
    }

    private func recordRateLimitRefreshFailure(
        _ error: any Error,
        account: CodexAccount
    ) {
        let message = error.localizedDescription
        if CodexAccount.requiresReauthentication(errorMessage: message) {
            account.markRateLimitReauthenticationRequired(
                fetchedAt: Date(),
                error: message
            )
        } else {
            account.updateRateLimitFetchMetadata(fetchedAt: Date(), error: message)
        }
    }

    private func closeIsolatedLoginRuntime(client: AppServerClient?, codexHomeURL: URL?) async {
        guard let codexHomeURL else {
            await client?.close()
            return
        }
        guard codexHomeURL != self.codexHomeURL else {
            return
        }
        await client?.close()
        try? FileManager.default.removeItem(at: codexHomeURL)
    }

    private func takeLoginRuntimeForCleanup() -> PendingLoginRuntimeCleanup {
        loginChallenge = nil
        loginBackend = nil
        isWaitingForLoginAccountUpdate = false
        let loginClient = loginClient
        self.loginClient = nil
        let loginCodexHomeURL = loginCodexHomeURL
        self.loginCodexHomeURL = nil
        let activeAuthenticationSession = activeAuthenticationSession
        self.activeAuthenticationSession = nil
        authenticationTask?.cancel()
        authenticationTask = nil
        loginNotificationTask?.cancel()
        loginNotificationTask = nil
        return .init(
            client: loginClient,
            codexHomeURL: loginCodexHomeURL,
            authenticationSession: activeAuthenticationSession
        )
    }

    private func cleanupLoginRuntime(_ cleanup: PendingLoginRuntimeCleanup) async {
        await cleanup.authenticationSession?.cancel()
        await closeIsolatedLoginRuntime(client: cleanup.client, codexHomeURL: cleanup.codexHomeURL)
    }

    private func applyRateLimits(
        windows: [(windowDurationMinutes: Int, usedPercent: Int, resetsAt: Date?)],
        planType: String?,
        to account: CodexAccount
    ) {
        account.updateRateLimits(windows)
        if let planType {
            account.updatePlanType(planType)
        }
        account.updateRateLimitFetchMetadata(fetchedAt: Date(), error: nil)
    }

    private func persistRefreshedSharedAuth(
        from sourceCodexHomeURL: URL?,
        for account: CodexAccount
    ) {
        guard let sourceCodexHomeURL else {
            return
        }
        try? CodexReviewAccountRegistry.saveSharedAuth(
            from: sourceCodexHomeURL,
            for: account,
            codexHomeURL: codexHomeURL
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
        from snapshot: BackendSettingsSnapshot
    ) -> CodexReviewSettingsSnapshot {
        .init(
            model: snapshot.model,
            fallbackModel: snapshot.fallbackModel,
            reasoningEffort: snapshot.reasoningEffort.flatMap(CodexReviewReasoningEffort.init(rawValue:)),
            serviceTier: snapshot.serviceTier.flatMap(CodexReviewServiceTier.init(rawValue:)),
            models: snapshot.models
        )
    }

    private static func monitorAccount(from snapshot: BackendAccountSnapshot) -> CodexAccount? {
        let label = snapshot.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountKey = normalizedReviewAccountEmail(email: snapshot.id.rawValue)
        guard label.isEmpty == false, accountKey.isEmpty == false else {
            return nil
        }
        return CodexAccount(
            accountKey: accountKey,
            email: label,
            planType: snapshot.planType,
            kind: snapshot.kind,
            capabilities: snapshot.capabilities
        )
    }

    private static func authenticationURL(from challenge: BackendLoginChallenge) throws -> URL {
        guard let url = challenge.verificationURL else {
            throw ReviewError.io("Authentication did not provide a valid authorization URL.")
        }
        return url
    }
}

@MainActor
private struct AppServerRuntime: Sendable {
    var client: AppServerClient
    var backend: AppServerCodexReviewBackend
}

private struct AppServerProcessRuntime: Sendable {
    var transport: AppServerProcessTransport
    var threadStartPermissionStrategy: AppServerThreadStartPermissionStrategy
}

@MainActor
private struct LoginRuntime: Sendable {
    var client: AppServerClient
    var backend: AppServerCodexReviewBackend
    var codexHomeURL: URL
    var usesPrimaryRuntime: Bool
}

private enum LoginActivation: Equatable, Sendable {
    case activateAuthenticatedAccount
    case preserveActiveAccount(String?)

    func resolvedActiveAccountKey(
        authenticatedAccountKey: String,
        persistedAccounts: [CodexAccount]
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

private struct AppServerAccountLoginCompletedNotification: Decodable, Equatable, Sendable {
    var error: String?
    var loginID: String?
    var success: Bool

    enum CodingKeys: String, CodingKey {
        case error
        case loginID = "loginId"
        case success
    }
}

private struct AppServerAccountRateLimitsUpdatedPayload: Decodable, Equatable, Sendable {
    var rateLimits: AppServerRateLimitSnapshotPayload
}

@MainActor
private enum CodexReviewAccountRegistry {
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

        init(_ accountKind: BackendAccountKind) {
            switch accountKind {
            case .chatGPT:
                self = .chatGPT
            case .apiKey:
                self = .apiKey
            case .amazonBedrock:
                self = .amazonBedrock
            }
        }

        var accountKind: BackendAccountKind {
            switch self {
            case .chatGPT:
                .chatGPT
            case .apiKey:
                .apiKey
            case .amazonBedrock:
                .amazonBedrock
            }
        }

        static func legacyDefault(accountKey: String?, email: String) -> Self {
            let normalizedAccountKey = accountKey
                .map(normalizedReviewAccountEmail(email:))
                .flatMap { $0.isEmpty ? nil : $0 }
            switch normalizedAccountKey ?? normalizedReviewAccountEmail(email: email) {
            case "api-key":
                return .apiKey
            case "amazon-bedrock":
                return .amazonBedrock
            default:
                return .chatGPT
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

    static func load(codexHomeURL: URL) -> (accounts: [CodexAccount], activeAccountKey: String?) {
        let registry = loadRegistry(codexHomeURL: codexHomeURL)
        let accounts = registry.accounts.compactMap(makeAccount(from:))
        let activeAccountKey = registry.activeAccountKey
            .map(normalizedReviewAccountEmail(email:))
            .flatMap { activeAccountKey in
                accounts.contains(where: { $0.accountKey == activeAccountKey }) ? activeAccountKey : nil
            }
        logger.info("Loaded \(accounts.count, privacy: .public) persisted Codex review account(s)")
        return (accounts, activeAccountKey)
    }

    static func saveAccounts(
        _ accounts: [CodexAccount],
        activeAccountKey: String?,
        codexHomeURL: URL
    ) throws {
        let existing = loadRegistry(codexHomeURL: codexHomeURL)
        let existingByAccountKey = Dictionary(uniqueKeysWithValues: existing.accounts.compactMap { entry in
            normalizedAccountKey(from: entry).map { ($0, entry) }
        })
        let normalizedActiveAccountKey = activeAccountKey
            .map(normalizedReviewAccountEmail(email:))
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
        accounts: [CodexAccount],
        codexHomeURL: URL
    ) throws {
        let normalizedAccountKey = normalizedReviewAccountEmail(email: accountKey)
        let savedAuthURL = savedAccountAuthURL(
            accountKey: normalizedAccountKey,
            codexHomeURL: codexHomeURL
        )
        guard FileManager.default.fileExists(atPath: savedAuthURL.path) else {
            throw ReviewError.io("Saved authentication is missing for account \(normalizedAccountKey).")
        }
        try saveAccounts(
            accounts,
            activeAccountKey: normalizedAccountKey,
            codexHomeURL: codexHomeURL
        )
        try copyAuth(from: savedAuthURL, to: sharedAuthURL(codexHomeURL: codexHomeURL))
    }

    static func updateCachedRateLimits(
        from account: CodexAccount,
        codexHomeURL: URL
    ) throws {
        var registry = loadRegistry(codexHomeURL: codexHomeURL)
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
        for account: CodexAccount,
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
        for account: CodexAccount,
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
        let normalizedAccountKey = normalizedReviewAccountEmail(email: accountKey)
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

    private static func makeAccount(from entry: Entry) -> CodexAccount? {
        let email = entry.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.isEmpty == false else {
            return nil
        }
        let normalizedEmail = normalizedReviewAccountEmail(email: email)
        let accountKey = entry.accountKey
            .map(normalizedReviewAccountEmail(email:))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? normalizedEmail
        let account = CodexAccount(
            accountKey: accountKey,
            email: email,
            planType: entry.planType,
            kind: entry.kind.accountKind
        )
        account.updateRateLimits(entry.cachedRateLimits?.map(\.tuple) ?? [])
        account.updateRateLimitFetchMetadata(
            fetchedAt: entry.lastRateLimitFetchAt,
            error: entry.lastRateLimitError
        )
        return account
    }

    private static func loadRegistry(codexHomeURL: URL) -> Registry {
        let url = registryURL(codexHomeURL: codexHomeURL)
        guard let data = try? Data(contentsOf: url),
              let registry = try? JSONDecoder().decode(Registry.self, from: data)
        else {
            return .init(activeAccountKey: nil, accounts: [])
        }
        return registry
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
        let normalizedEmail = normalizedReviewAccountEmail(email: email)
        return entry.accountKey
            .map(normalizedReviewAccountEmail(email:))
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
        let normalizedAccountKey = normalizedReviewAccountEmail(email: accountKey)
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
