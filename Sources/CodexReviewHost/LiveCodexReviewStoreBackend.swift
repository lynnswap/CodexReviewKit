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

private struct PendingLoginRuntimeCleanup {
    var client: AppServerClient?
    var lifecycle: AppServerRuntimeOwnerLifecycleHandle?
    var codexHomeURL: URL?
    var authenticationSession: (any CodexReviewNativeAuthentication.WebSession)?
    var authenticationTask: Task<Void, Never>?
    var notificationTask: Task<Void, Never>?

    var isEmpty: Bool {
        client == nil && lifecycle == nil && codexHomeURL == nil
            && authenticationSession == nil && authenticationTask == nil
            && notificationTask == nil
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
    CodexReviewMCPHTTPServer.Configuration
) async -> CodexReviewMCPPortOwner?

package typealias CodexReviewMCPHTTPServerBindChecker = @MainActor @Sendable (
    CodexReviewMCPHTTPServer.Configuration
) async throws -> Void

package enum CodexReviewMCPLifecycleCall: Hashable, Sendable {
    case stop
    case close
}

package typealias CodexReviewMCPLifecycleCallObserver = @MainActor @Sendable (
    CodexReviewMCPLifecycleCall,
    Int
) -> Void

package protocol CodexReviewMCPHTTPServing: AnyObject, Sendable {
    var url: URL { get async }

    func start() async throws
    func closeAdmission() async
    func waitForAdmittedHandlers() async
    func stop() async throws
}

extension CodexReviewMCPHTTPServing {
    package func closeAdmission() async {}
    package func waitForAdmittedHandlers() async {}
}

extension CodexReviewMCPHTTPServer: CodexReviewMCPHTTPServing {}

@MainActor
public extension CodexReviewStore {
    static func makeLiveStore(
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        nativeAuthenticationConfiguration: CodexReviewNativeAuthentication.Configuration? = nil,
        webAuthenticationSessionFactory: @escaping CodexReviewNativeAuthentication.WebSessionFactory = CodexReviewNativeAuthentication.WebSessions.system
    ) -> CodexReviewStore {
        CodexReviewStore(backend: LiveCodexReviewStoreBackend(
            runtimePreferences: runtimePreferences,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory
        ))
    }

    package static func makeLiveStoreForTesting(
        environment: [String: String],
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        nativeAuthenticationConfiguration: CodexReviewNativeAuthentication.Configuration? = nil,
        webAuthenticationSessionFactory: @escaping CodexReviewNativeAuthentication.WebSessionFactory,
        externalURLOpener: @escaping @MainActor @Sendable (URL) -> Void = defaultExternalURLOpener,
        mcpPortOwnerResolver: CodexReviewMCPPortOwnerResolver? = nil,
        mcpHTTPServerBindChecker: CodexReviewMCPHTTPServerBindChecker? = nil,
        mcpLifecycleCallObserver: CodexReviewMCPLifecycleCallObserver? = nil,
        networkMonitor: any CodexReviewNetworkMonitoring = SystemCodexReviewNetworkMonitor(),
        networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy = .default,
        reviewRuntimeClosePolicy: ReviewRuntimeClosePolicy = .production,
        transport: any JSONRPC.Transport
    ) -> CodexReviewStore {
        makeLiveStoreForTesting(
            environment: environment,
            runtimePreferences: runtimePreferences,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory,
            externalURLOpener: externalURLOpener,
            mcpPortOwnerResolver: mcpPortOwnerResolver,
            mcpHTTPServerBindChecker: mcpHTTPServerBindChecker,
            mcpLifecycleCallObserver: mcpLifecycleCallObserver,
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: networkRecoveryPolicy,
            reviewRuntimeClosePolicy: reviewRuntimeClosePolicy,
            transportFactory: { _ in transport }
        )
    }

    package static func makeLiveStoreForTesting(
        environment: [String: String],
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        nativeAuthenticationConfiguration: CodexReviewNativeAuthentication.Configuration? = nil,
        webAuthenticationSessionFactory: @escaping CodexReviewNativeAuthentication.WebSessionFactory,
        externalURLOpener: @escaping @MainActor @Sendable (URL) -> Void = defaultExternalURLOpener,
        mcpHTTPServerFactory: (@MainActor @Sendable (
            CodexReviewStore,
            CodexReviewMCPHTTPServer.Configuration
        ) -> any CodexReviewMCPHTTPServing)? = nil,
        mcpPortOwnerResolver: CodexReviewMCPPortOwnerResolver? = nil,
        mcpHTTPServerBindChecker: CodexReviewMCPHTTPServerBindChecker? = nil,
        mcpLifecycleCallObserver: CodexReviewMCPLifecycleCallObserver? = nil,
        networkMonitor: any CodexReviewNetworkMonitoring = SystemCodexReviewNetworkMonitor(),
        networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy = .default,
        reviewRuntimeClosePolicy: ReviewRuntimeClosePolicy = .production,
        transportFactory: @escaping @MainActor @Sendable (URL) async throws -> any JSONRPC.Transport
    ) -> CodexReviewStore {
        CodexReviewStore(
            backend: LiveCodexReviewStoreBackend(
                environment: environment,
                runtimePreferences: runtimePreferences,
                nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
                webAuthenticationSessionFactory: webAuthenticationSessionFactory,
                externalURLOpener: externalURLOpener,
                mcpHTTPServerFactory: mcpHTTPServerFactory,
                mcpPortOwnerResolver: mcpPortOwnerResolver,
                mcpHTTPServerBindChecker: mcpHTTPServerBindChecker,
                mcpLifecycleCallObserver: mcpLifecycleCallObserver,
                appServerRuntimeFactory: { codexHomeURL in
                    let client = AppServerClient(transport: try await transportFactory(codexHomeURL))
                    return .init(
                        client: client,
                        backend: AppServerCodexReviewBackend(client: client)
                    )
                }
            ),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: networkRecoveryPolicy,
            reviewRuntimeClosePolicy: reviewRuntimeClosePolicy
        )
    }
}

@MainActor
private final class LiveCodexReviewStoreBackend: CodexReviewStoreBackend {
    typealias MCPHTTPServerFactory = @MainActor @Sendable (
        CodexReviewStore,
        CodexReviewMCPHTTPServer.Configuration
    ) -> any CodexReviewMCPHTTPServing

    let seed: CodexReviewStoreSeed

    private var client: AppServerClient?
    private var appServerBackend: AppServerCodexReviewBackend?
    private var activeRuntimeHandle: LiveRuntimeLifecycleHandle?
    private var acceptsRuntimeRequests = false
    private var loginChallenge: CodexReviewBackendModel.Login.Challenge?
    private var loginBackend: AppServerCodexReviewBackend?
    private var loginClient: AppServerClient?
    private var loginCodexHomeURL: URL?
    private var loginActivation: LoginActivation = .activateAuthenticatedAccount
    private var isWaitingForLoginAccountUpdate = false
    private var activeAuthenticationSession: (any CodexReviewNativeAuthentication.WebSession)?
    private var authenticationTask: Task<Void, Never>?
    private var authenticationTaskID: UInt64?
    private var nextAuthenticationTaskID: UInt64 = 0
    private var retiredAuthenticationTasks: [Task<Void, Never>] = []
    private var authNotificationTask: Task<Void, Never>?
    private var retiredAuthNotificationTasks: [Task<Void, Never>] = []
    private var pendingLifecycleFailures: [ReviewLifecycleResourceFailure] = []
    private var loginNotificationTask: Task<Void, Never>?
    private var retiredLoginNotificationTasks: [Task<Void, Never>] = []
    private var settingsSnapshot = CodexReviewSettings.Snapshot()
    private let codexHomeURL: URL
    private let nativeAuthenticationConfiguration: CodexReviewNativeAuthentication.Configuration?
    private let webAuthenticationSessionFactory: CodexReviewNativeAuthentication.WebSessionFactory
    private let externalURLOpener: ExternalURLOpener
    private let mcpLifecycleOwner: LiveMCPServerLifecycleOwner
    private let appServerRuntimeFactory: AppServerRuntimeFactory
    private weak var attachedStore: CodexReviewStore?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        nativeAuthenticationConfiguration: CodexReviewNativeAuthentication.Configuration? = nil,
        webAuthenticationSessionFactory: @escaping CodexReviewNativeAuthentication.WebSessionFactory = CodexReviewNativeAuthentication.WebSessions.system,
        externalURLOpener: @escaping ExternalURLOpener = defaultExternalURLOpener,
        mcpHTTPServerFactory: MCPHTTPServerFactory? = { store, configuration in
            CodexReviewMCPHTTPServer(
                adapter: CodexReviewMCPServer(store: store),
                configuration: configuration
            )
        },
        mcpPortOwnerResolver: CodexReviewMCPPortOwnerResolver? = nil,
        mcpHTTPServerBindChecker: CodexReviewMCPHTTPServerBindChecker? = nil,
        mcpLifecycleCallObserver: CodexReviewMCPLifecycleCallObserver? = nil,
        appServerRuntimeFactory: AppServerRuntimeFactory? = nil
    ) {
        let runtimePreferences = runtimePreferences.normalized
        codexHomeURL = Self.codexHomeURL(
            runtimePreferences: runtimePreferences,
            environment: environment
        )
        let mcpHTTPServerConfiguration = CodexReviewMCPHTTPServer.Configuration(
            host: runtimePreferences.mcpHost,
            port: runtimePreferences.mcpPort,
            endpoint: runtimePreferences.mcpPath
        )
        self.nativeAuthenticationConfiguration = nativeAuthenticationConfiguration
        self.webAuthenticationSessionFactory = webAuthenticationSessionFactory
        self.externalURLOpener = externalURLOpener
        let resolvedPortOwnerResolver = mcpPortOwnerResolver ?? Self.defaultMCPPortOwnerResolver
        let resolvedBindChecker = mcpHTTPServerBindChecker ?? Self.defaultMCPHTTPServerBindChecker
        self.mcpLifecycleOwner = LiveMCPServerLifecycleOwner(
            configuration: mcpHTTPServerConfiguration,
            factory: mcpHTTPServerFactory,
            portOwnerResolver: resolvedPortOwnerResolver,
            bindChecker: resolvedBindChecker,
            lifecycleCallObserver: mcpLifecycleCallObserver
        )
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

    var mcpServerLifecycle: any MCPServerLifecycleOwner {
        mcpLifecycleOwner
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
        return AppServerCodexHome.url(environment: environment)
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
        mcpLifecycleOwner.attachStore(store)
    }

    func prepareRuntime(
        generation _: ReviewRuntimeGeneration,
        purpose _: ReviewRuntimeTransitionPurpose
    ) async throws -> PreparedRuntime {
        logger.info("Preparing review runtime")
        let runtime = try await appServerRuntimeFactory(codexHomeURL)
        do {
            let authentication = try await runtime.backend.readAuth()
            let settings = try await Self.monitorSettings(from: runtime.backend.readSettings())
            let handle = LiveRuntimeLifecycleHandle(
                owner: self,
                client: runtime.client,
                backend: runtime.backend,
                snapshot: .init(
                    authentication: authentication,
                    settings: settings
                )
            )
            logger.info("Review runtime prepared")
            return PreparedRuntime(snapshot: handle.snapshot, handle: handle)
        } catch {
            let lifecycle = runtime.backend.runtimeOwnerLifecycleHandle
            await lifecycle.closeAdmission()
            do {
                try await lifecycle.closeAndWait()
            } catch let cleanupFailures as ReviewLifecycleResourceFailureAggregate {
                throw ReviewRuntimePreparationFailure(
                    preparationError: error,
                    cleanupFailures: cleanupFailures
                )
            } catch let cleanupFailure as ReviewLifecycleResourceFailure {
                throw ReviewRuntimePreparationFailure(
                    preparationError: error,
                    cleanupFailures: .init(first: cleanupFailure)
                )
            } catch {
                throw ReviewRuntimePreparationFailure(
                    preparationError: error,
                    cleanupFailures: .init(first: .client(error.localizedDescription))
                )
            }
            throw error
        }
    }

    func activateRuntime(_ handle: LiveRuntimeLifecycleHandle) throws {
        guard activeRuntimeHandle == nil else {
            throw ReviewLifecycleResourceFailure.client(
                "A review runtime is already active."
            )
        }
        guard let store = attachedStore else {
            throw ReviewLifecycleResourceFailure.client(
                "Review runtime activation requires its attached Store."
            )
        }
        activeRuntimeHandle = handle
        acceptsRuntimeRequests = true
        client = handle.client
        appServerBackend = handle.backend
        settingsSnapshot = handle.snapshot.settings
        observeAuthNotifications(
            client: handle.client,
            backend: handle.backend,
            store: store
        )
    }

    func deactivateRuntime(
        _ handle: LiveRuntimeLifecycleHandle
    ) -> Task<Void, Never>? {
        guard activeRuntimeHandle === handle else {
            return nil
        }
        activeRuntimeHandle = nil
        acceptsRuntimeRequests = false
        client = nil
        let task = authNotificationTask
        authNotificationTask = nil
        task?.cancel()
        return task
    }

    func closeRuntimeAdmission(_ handle: LiveRuntimeLifecycleHandle) {
        guard activeRuntimeHandle === handle else {
            return
        }
        acceptsRuntimeRequests = false
    }

    func stop(store: CodexReviewStore) async throws {
        let appServerBackend = appServerBackend
        let hasRuntimeState = client != nil || appServerBackend != nil
        let loginCleanup = takeLoginRuntimeForCleanup()
        var failures = takePendingLifecycleFailures()
        guard hasRuntimeState || loginCleanup.isEmpty == false
                || retiredAuthenticationTasks.isEmpty == false
                || retiredLoginNotificationTasks.isEmpty == false
                || retiredAuthNotificationTasks.isEmpty == false
                || failures.isEmpty == false
        else {
            return
        }
        logger.info("Stopping review runtime")
        await cleanupLoginRuntime(loginCleanup)
        failures.append(contentsOf: takePendingLifecycleFailures())
        let retiredLoginNotificationTasks = retiredLoginNotificationTasks
        self.retiredLoginNotificationTasks.removeAll(keepingCapacity: false)
        for task in retiredLoginNotificationTasks {
            await task.value
        }
        let retiredAuthenticationTasks = retiredAuthenticationTasks
        self.retiredAuthenticationTasks.removeAll(keepingCapacity: false)
        for task in retiredAuthenticationTasks {
            await task.value
        }
        let retiredAuthNotificationTasks = retiredAuthNotificationTasks
        self.retiredAuthNotificationTasks.removeAll(keepingCapacity: false)
        for task in retiredAuthNotificationTasks {
            await task.value
        }
        failures.append(contentsOf: takePendingLifecycleFailures())
        logger.info("Review runtime semantic work stopped")
        if let first = failures.first {
            throw ReviewLifecycleResourceFailureAggregate(
                first: first,
                additionalInLifecycleOrder: Array(failures.dropFirst())
            )
        }
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
        let loginBackend = loginBackend
        let loginChallenge = loginChallenge
        let cleanup = takeLoginRuntimeForCleanup()
        await cleanup.authenticationSession?.cancel()
        guard let loginBackend, let loginChallenge else {
            if auth.selectedAccount == nil {
                auth.updatePhase(.signedOut)
            }
            await cleanupLoginRuntime(cleanup)
            return
        }
        do {
            try await loginBackend.cancelLogin(loginChallenge)
            auth.updatePhase(auth.selectedAccount == nil ? .signedOut : .signedOut)
        } catch {
            auth.updatePhase(.failed(message: error.localizedDescription))
        }
        await cleanupLoginRuntime(cleanup)
    }

    func switchAccount(auth: CodexReviewAuthModel, accountKey: String) async throws {
        guard auth.persistedAccounts.contains(where: { $0.accountKey == accountKey }) else {
            return
        }
        let runtimeStore = appServerBackend == nil ? nil : attachedStore
        if let runtimeStore {
            try await runtimeStore.closeActiveReviewSessions(
                reason: .system(message: "Account switched.")
            )
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
        guard let runtimeStore else {
            return
        }
        await runtimeStore.restart()
    }

    func removeAccount(auth: CodexReviewAuthModel, accountKey: String) async throws {
        let removedActiveAccount = auth.selectedAccount?.accountKey == accountKey
            || auth.persistedActiveAccountKey == accountKey
        let runtimeStore = removedActiveAccount && appServerBackend != nil ? attachedStore : nil
        if let runtimeStore {
            try await runtimeStore.closeActiveReviewSessions(
                reason: .system(message: "Account removed.")
            )
        }
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
            guard let runtimeStore else {
                return
            }
            await runtimeStore.restart()
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
            try await attachedStore?.closeActiveReviewSessions(reason: .system(message: "Signed out."))
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
            await attachedStore.restart()
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
            nextAuthenticationTaskID &+= 1
            let taskID = nextAuthenticationTaskID
            authenticationTaskID = taskID
            authenticationTask = Task { @MainActor [weak self, weak auth] in
                guard let self else {
                    return
                }
                defer { self.finishAuthenticationTask(taskID) }
                guard let auth else { return }
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
            retireAuthenticationTask()
            retireLoginNotificationTask()
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
        challenge: CodexReviewBackendModel.Login.Challenge,
        session: any CodexReviewNativeAuthentication.WebSession,
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
            retireLoginNotificationTask()
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
            retireLoginNotificationTask()
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
                throw CodexReviewAPI.Error.io("Review runtime is not running.")
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
        challenge: CodexReviewBackendModel.Login.Challenge,
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
        retireLoginNotificationTask()
        auth.updatePhase(.signedOut)
        await closeIsolatedLoginRuntime(client: loginClient, codexHomeURL: loginCodexHomeURL)
    }

    func startReview(
        _ request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> BackendReviewAttempt {
        guard acceptsRuntimeRequests, let appServerBackend else {
            throw CodexReviewAPI.Error.io("Review runtime is not running.")
        }
        return try await appServerBackend.startReview(request, admission: admission)
    }

    func interruptReview(_ run: CodexReviewBackendModel.Review.Run, reason: CodexReviewBackendModel.CancellationReason) async throws {
        guard acceptsRuntimeRequests, let appServerBackend else {
            throw CodexReviewAPI.Error.io("Review runtime is not running.")
        }
        try await appServerBackend.interruptReview(run, reason: reason)
    }

    func forceCloseReviewConnection() async throws {
        guard acceptsRuntimeRequests, let appServerBackend else {
            throw ReviewRuntimeCloseFailure.connection("Review runtime is not running.")
        }
        try await appServerBackend.forceCloseReviewConnection()
    }

    func prepareReviewRecovery(
        _ candidate: ReviewRecoveryCandidate
    ) async throws -> ReviewRecoveryHandoff {
        guard let appServerBackend else {
            throw CodexReviewAPI.Error.io("Review runtime is not running.")
        }
        return try await appServerBackend.prepareReviewRecovery(candidate)
    }

    func resumeReviewRecovery(
        _ handoff: ReviewRecoveryHandoff,
        request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> BackendReviewAttempt {
        guard acceptsRuntimeRequests, let appServerBackend else {
            throw CodexReviewAPI.Error.io("Review runtime is not running.")
        }
        return try await appServerBackend.resumeReviewRecovery(
            handoff,
            request: request,
            admission: admission
        )
    }

    func cleanupReview(_ run: CodexReviewBackendModel.Review.Run) async throws {
        guard let appServerBackend else {
            throw ReviewRuntimeCloseFailure.cleanup("Review runtime is not running.")
        }
        try await appServerBackend.cleanupReview(run)
    }

    @discardableResult
    private func applyAuthSnapshot(
        _ snapshot: CodexReviewBackendModel.Auth.Snapshot,
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
        guard client != nil || appServerBackend != nil || loginCleanup.isEmpty == false else {
            return
        }
        let message = "Review runtime stopped unexpectedly: \(error.localizedDescription)"
        let failedClient = client
        acceptsRuntimeRequests = false
        if let authNotificationTask {
            retiredAuthNotificationTasks.append(authNotificationTask)
        }
        authNotificationTask = nil
        store.transitionToFailed(message)
        await cleanupLoginRuntime(loginCleanup)
        await closeClientAfterFailure(failedClient)
    }

    private func handleAuthNotification(
        _ notification: JSONRPC.Notification,
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
        retireLoginNotificationTask()
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
        _ notification: JSONRPC.Notification,
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
        _ notification: JSONRPC.Notification,
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
            retireAuthenticationTask()
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
                retireLoginNotificationTask()
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
            retireAuthenticationTask()
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
        retireLoginNotificationTask()
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
        _ notification: JSONRPC.Notification,
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
            guard AppServerAPI.Account.RateLimits.Response.isCodexRateLimit(payload.rateLimits.limitID) else {
                return
            }
            let response = AppServerAPI.Account.RateLimits.Response(rateLimits: payload.rateLimits)
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
            throw CodexReviewAPI.Error.io("Saved authentication is missing for \(account.maskedEmail). Sign in again.")
        }
        let actualAccountKey = CodexAccount.normalizedEmail(activeAccountID)
        guard actualAccountKey == account.accountKey else {
            let actualEmail = snapshot.accounts.first(where: { $0.id.rawValue == activeAccountID })?.label
                ?? activeAccountID
            let maskedActualEmail = self.maskedReviewAccountEmail(actualEmail)
            throw CodexReviewAPI.Error.io("Saved authentication is for \(maskedActualEmail), not \(account.maskedEmail). Sign in again.")
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
            await closeClientAfterFailure(client)
            return
        }
        guard codexHomeURL != self.codexHomeURL else {
            return
        }
        await closeClientAfterFailure(client)
        try? FileManager.default.removeItem(at: codexHomeURL)
    }

    private func closeClientAfterFailure(_ client: AppServerClient?) async {
        guard let client else {
            return
        }
        do {
            try await client.close()
        } catch {
            logger.error("Failed to close app-server client: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func takeLoginRuntimeForCleanup() -> PendingLoginRuntimeCleanup {
        loginChallenge = nil
        let loginClient = loginClient
        let loginLifecycle = loginClient == nil
            ? nil
            : loginBackend?.runtimeOwnerLifecycleHandle
        loginBackend = nil
        isWaitingForLoginAccountUpdate = false
        self.loginClient = nil
        let loginCodexHomeURL = loginCodexHomeURL
        self.loginCodexHomeURL = nil
        let activeAuthenticationSession = activeAuthenticationSession
        self.activeAuthenticationSession = nil
        let authenticationTask = authenticationTask
        authenticationTask?.cancel()
        self.authenticationTask = nil
        authenticationTaskID = nil
        let loginNotificationTask = loginNotificationTask
        loginNotificationTask?.cancel()
        self.loginNotificationTask = nil
        return .init(
            client: loginClient,
            lifecycle: loginLifecycle,
            codexHomeURL: loginCodexHomeURL,
            authenticationSession: activeAuthenticationSession,
            authenticationTask: authenticationTask,
            notificationTask: loginNotificationTask
        )
    }

    private func cleanupLoginRuntime(
        _ cleanup: PendingLoginRuntimeCleanup
    ) async {
        var failures: [ReviewLifecycleResourceFailure] = []
        await cleanup.authenticationSession?.cancel()
        await cleanup.notificationTask?.value
        await cleanup.authenticationTask?.value
        if let lifecycle = cleanup.lifecycle {
            do {
                await lifecycle.closeAdmission()
                try await lifecycle.closeAndWait()
            } catch let aggregate as ReviewLifecycleResourceFailureAggregate {
                failures.append(aggregate.first)
                failures.append(contentsOf: aggregate.additionalInLifecycleOrder)
            } catch let failure as ReviewLifecycleResourceFailure {
                failures.append(failure)
            } catch {
                failures.append(.client(error.localizedDescription))
            }
            if let codexHomeURL = cleanup.codexHomeURL {
                try? FileManager.default.removeItem(at: codexHomeURL)
            }
        } else {
            await closeIsolatedLoginRuntime(
                client: cleanup.client,
                codexHomeURL: cleanup.codexHomeURL
            )
        }
        pendingLifecycleFailures.append(contentsOf: failures)
    }

    private func takePendingLifecycleFailures() -> [ReviewLifecycleResourceFailure] {
        let failures = pendingLifecycleFailures
        pendingLifecycleFailures.removeAll(keepingCapacity: false)
        return failures
    }

    private func retireAuthenticationTask() {
        guard let authenticationTask else {
            return
        }
        authenticationTask.cancel()
        retiredAuthenticationTasks.append(authenticationTask)
        self.authenticationTask = nil
        authenticationTaskID = nil
    }

    private func retireLoginNotificationTask() {
        guard let loginNotificationTask else {
            return
        }
        loginNotificationTask.cancel()
        retiredLoginNotificationTasks.append(loginNotificationTask)
        self.loginNotificationTask = nil
    }

    private func finishAuthenticationTask(_ taskID: UInt64) {
        guard authenticationTaskID == taskID else {
            return
        }
        authenticationTask = nil
        authenticationTaskID = nil
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

    private static func monitorAccount(from snapshot: CodexReviewBackendModel.Account.Snapshot) -> CodexAccount? {
        let label = snapshot.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountKey = CodexAccount.normalizedEmail(snapshot.id.rawValue)
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

    private static func authenticationURL(from challenge: CodexReviewBackendModel.Login.Challenge) throws -> URL {
        guard let url = challenge.verificationURL else {
            throw CodexReviewAPI.Error.io("Authentication did not provide a valid authorization URL.")
        }
        return url
    }
}

@MainActor
private final class LiveRuntimeLifecycleHandle: RuntimeLifecycleHandle {
    fileprivate let client: AppServerClient
    fileprivate let backend: AppServerCodexReviewBackend
    fileprivate let snapshot: RuntimePublicationSnapshot

    private weak var owner: LiveCodexReviewStoreBackend?
    private var isActivated = false
    private var closeTask: Task<Result<Void, ReviewLifecycleResourceFailureAggregate>, Never>?

    init(
        owner: LiveCodexReviewStoreBackend,
        client: AppServerClient,
        backend: AppServerCodexReviewBackend,
        snapshot: RuntimePublicationSnapshot
    ) {
        self.owner = owner
        self.client = client
        self.backend = backend
        self.snapshot = snapshot
    }

    func activate() async throws {
        guard isActivated == false, closeTask == nil else {
            throw ReviewLifecycleResourceFailure.client(
                "Runtime activation requires one inert open handle."
            )
        }
        guard let owner else {
            throw ReviewLifecycleResourceFailure.client(
                "Runtime activation lost its Host owner."
            )
        }
        try owner.activateRuntime(self)
        isActivated = true
    }

    func closeAdmission() async {
        owner?.closeRuntimeAdmission(self)
        await backend.runtimeOwnerLifecycleHandle.closeAdmission()
    }

    func close(purpose: ReviewRuntimeTransitionPurpose) async throws {
        let task: Task<Result<Void, ReviewLifecycleResourceFailureAggregate>, Never>
        if let closeTask {
            task = closeTask
        } else {
            let appServerLifecycle = backend.runtimeOwnerLifecycleHandle
            let authObservationTask = owner?.deactivateRuntime(self)
            let newTask = Task<Result<Void, ReviewLifecycleResourceFailureAggregate>, Never> { @MainActor in
                var failures: [ReviewLifecycleResourceFailure] = []
                authObservationTask?.cancel()
                do {
                    try await appServerLifecycle.closeAndWait(purpose: purpose)
                } catch {
                    if let aggregate = error as? ReviewLifecycleResourceFailureAggregate {
                        failures.append(aggregate.first)
                        failures.append(contentsOf: aggregate.additionalInLifecycleOrder)
                    } else if let failure = error as? ReviewLifecycleResourceFailure {
                        failures.append(failure)
                    } else if let failure = error as? ReviewRuntimeCloseFailure,
                              case .process(let message) = failure {
                        failures.append(.process(message))
                    } else {
                        failures.append(.client(error.localizedDescription))
                    }
                }
                await authObservationTask?.value
                if let first = failures.first {
                    return Result.failure(.init(
                        first: first,
                        additionalInLifecycleOrder: Array(failures.dropFirst())
                    ))
                }
                return Result.success(())
            }
            closeTask = newTask
            task = newTask
        }
        try await task.value.get()
    }

    func waitUntilClosed() async throws {
        guard let closeTask else {
            throw ReviewLifecycleResourceFailure.client(
                "Runtime completion wait began before close."
            )
        }
        try await closeTask.value.get()
    }
}

@MainActor
private final class LiveMCPServerLifecycleOwner: MCPServerLifecycleOwner {
    typealias Factory = LiveCodexReviewStoreBackend.MCPHTTPServerFactory

    private struct Lease: Sendable {
        let generation: MCPServerGeneration
        let server: (any CodexReviewMCPHTTPServing)?
    }

    private struct Activation: Sendable {
        let lease: Lease
        let snapshot: MCPServerPublicationSnapshot
    }

    private typealias PreparationResult = Result<Lease, ReviewLifecycleResourceFailure>
    private typealias ActivationResult = Result<Activation, ReviewLifecycleResourceFailure>
    private typealias LifecycleResult = Result<Void, ReviewLifecycleResourceFailureAggregate>

    private enum State {
        case stopped
        case preparing(
            operationID: UInt64,
            generation: MCPServerGeneration,
            task: Task<PreparationResult, Never>
        )
        case prepared(Lease)
        case activating(
            operationID: UInt64,
            lease: Lease,
            task: Task<ActivationResult, Never>
        )
        case running(Lease, MCPServerPublicationSnapshot)
        case stopping(
            operationID: UInt64,
            task: Task<LifecycleResult, Never>
        )
        case closing(
            operationID: UInt64,
            task: Task<LifecycleResult, Never>
        )
        case closed(LifecycleResult)
    }

    private let configuration: CodexReviewMCPHTTPServer.Configuration
    private let factory: Factory?
    private let portOwnerResolver: CodexReviewMCPPortOwnerResolver
    private let bindChecker: CodexReviewMCPHTTPServerBindChecker
    private let lifecycleCallObserver: CodexReviewMCPLifecycleCallObserver?
    private weak var store: CodexReviewStore?
    private var state: State = .stopped
    private var nextGeneration: UInt64 = 0
    private var nextOperationID: UInt64 = 0
    private var stopCallerCount = 0
    private var closeCallerCount = 0

    init(
        configuration: CodexReviewMCPHTTPServer.Configuration,
        factory: Factory?,
        portOwnerResolver: @escaping CodexReviewMCPPortOwnerResolver,
        bindChecker: @escaping CodexReviewMCPHTTPServerBindChecker,
        lifecycleCallObserver: CodexReviewMCPLifecycleCallObserver?
    ) {
        self.configuration = configuration
        self.factory = factory
        self.portOwnerResolver = portOwnerResolver
        self.bindChecker = bindChecker
        self.lifecycleCallObserver = lifecycleCallObserver
    }

    func attachStore(_ store: CodexReviewStore) {
        self.store = store
    }

    func prepare() async throws -> PreparedMCPServer {
        let operationID: UInt64
        let generation: MCPServerGeneration
        let task: Task<PreparationResult, Never>
        switch state {
        case .stopped:
            nextGeneration &+= 1
            generation = MCPServerGeneration(rawValue: nextGeneration)
            operationID = makeOperationID()
            task = makePreparationTask(generation: generation)
            state = .preparing(
                operationID: operationID,
                generation: generation,
                task: task
            )
        case .preparing(let currentOperationID, let currentGeneration, let currentTask):
            operationID = currentOperationID
            generation = currentGeneration
            task = currentTask
        case .prepared(let lease):
            return .init(generation: lease.generation)
        case .activating, .running, .stopping:
            throw ReviewLifecycleResourceFailure.mcpServer(
                "MCP preparation requires stopped state."
            )
        case .closing, .closed:
            throw ReviewLifecycleResourceFailure.mcpServer(
                "MCP owner is closing or closed."
            )
        }

        let result = await task.value
        switch result {
        case .failure(let failure):
            if case .preparing(let currentOperationID, let currentGeneration, _) = state,
               currentOperationID == operationID,
               currentGeneration == generation {
                state = .stopped
            }
            throw failure
        case .success(let lease):
            switch state {
            case .preparing(let currentOperationID, let currentGeneration, _)
                where currentOperationID == operationID && currentGeneration == generation:
                state = .prepared(lease)
                return .init(generation: generation)
            case .prepared(let currentLease) where currentLease.generation == generation:
                return .init(generation: generation)
            default:
                throw supersededFailure("preparation", generation: generation)
            }
        }
    }

    func activate(
        _ generation: MCPServerGeneration
    ) async throws -> MCPServerPublicationSnapshot {
        let operationID: UInt64
        let lease: Lease
        let task: Task<ActivationResult, Never>
        switch state {
        case .prepared(let preparedLease) where preparedLease.generation == generation:
            lease = preparedLease
            operationID = makeOperationID()
            task = makeActivationTask(lease: lease)
            state = .activating(
                operationID: operationID,
                lease: lease,
                task: task
            )
        case .activating(let currentOperationID, let currentLease, let currentTask)
            where currentLease.generation == generation:
            operationID = currentOperationID
            lease = currentLease
            task = currentTask
        case .running(let currentLease, let snapshot)
            where currentLease.generation == generation:
            return snapshot
        default:
            throw ReviewLifecycleResourceFailure.mcpServer(
                "MCP activation requires its exact prepared generation."
            )
        }

        let result = await task.value
        switch result {
        case .success(let activation):
            switch state {
            case .activating(let currentOperationID, let currentLease, _)
                where currentOperationID == operationID && currentLease.generation == generation:
                state = .running(activation.lease, activation.snapshot)
                return activation.snapshot
            case .running(let currentLease, let snapshot)
                where currentLease.generation == generation:
                return snapshot
            default:
                throw supersededFailure("activation", generation: generation)
            }
        case .failure(let failure):
            let cleanupTask = activationFailureCleanupTask(
                operationID: operationID,
                lease: lease
            )
            if let cleanupTask {
                let cleanupResult = await cleanupTask.task.value
                finishStoppingIfCurrent(
                    cleanupTask.operationID,
                    result: cleanupResult
                )
            }
            throw failure
        }
    }

    func closeAdmission() async {
        switch state {
        case .prepared(let lease), .running(let lease, _):
            await lease.server?.closeAdmission()
        case .activating(_, let lease, _):
            await lease.server?.closeAdmission()
        case .stopped, .preparing, .stopping, .closing, .closed:
            return
        }
    }

    func drainAdmittedHandlers() async throws {
        switch state {
        case .running(let lease, _):
            await lease.server?.waitForAdmittedHandlers()
        case .stopped, .preparing, .prepared, .activating, .stopping, .closing, .closed:
            return
        }
    }

    func stop() async throws {
        stopCallerCount += 1
        lifecycleCallObserver?(.stop, stopCallerCount)
        let operationID: UInt64
        let task: Task<LifecycleResult, Never>
        switch state {
        case .stopped:
            return
        case .preparing(_, _, let preparationTask):
            operationID = makeOperationID()
            task = makeLifecycleTask(preparationTask: preparationTask)
            state = .stopping(operationID: operationID, task: task)
        case .prepared(let lease), .running(let lease, _):
            operationID = makeOperationID()
            task = makeLifecycleTask(lease: lease)
            state = .stopping(operationID: operationID, task: task)
        case .activating(_, let lease, let activationTask):
            operationID = makeOperationID()
            task = makeLifecycleTask(
                activationTask: activationTask,
                lease: lease
            )
            state = .stopping(operationID: operationID, task: task)
        case .stopping(let currentOperationID, let currentTask):
            operationID = currentOperationID
            task = currentTask
        case .closing(_, let closeTask):
            try await closeTask.value.get()
            return
        case .closed(let result):
            try result.get()
            return
        }

        let result = await task.value
        finishStoppingIfCurrent(operationID, result: result)
        try result.get()
    }

    func waitUntilStopped() async throws {
        switch state {
        case .stopped:
            return
        case .stopping(let operationID, let task):
            let result = await task.value
            finishStoppingIfCurrent(operationID, result: result)
            try result.get()
        case .closing(_, let task):
            try await task.value.get()
        case .closed(let result):
            try result.get()
        case .preparing, .prepared, .activating, .running:
            throw ReviewLifecycleResourceFailure.mcpServer(
                "MCP owner did not stop."
            )
        }
    }

    func close() async throws {
        closeCallerCount += 1
        lifecycleCallObserver?(.close, closeCallerCount)
        let operationID: UInt64
        let task: Task<LifecycleResult, Never>
        switch state {
        case .stopped:
            operationID = makeOperationID()
            task = makeLifecycleTask()
            state = .closing(operationID: operationID, task: task)
        case .preparing(_, _, let preparationTask):
            operationID = makeOperationID()
            task = makeLifecycleTask(preparationTask: preparationTask)
            state = .closing(operationID: operationID, task: task)
        case .prepared(let lease), .running(let lease, _):
            operationID = makeOperationID()
            task = makeLifecycleTask(lease: lease)
            state = .closing(operationID: operationID, task: task)
        case .activating(_, let lease, let activationTask):
            operationID = makeOperationID()
            task = makeLifecycleTask(
                activationTask: activationTask,
                lease: lease
            )
            state = .closing(operationID: operationID, task: task)
        case .stopping(_, let stopTask):
            operationID = makeOperationID()
            task = makeLifecycleTask(lifecycleTask: stopTask)
            state = .closing(operationID: operationID, task: task)
        case .closing(let currentOperationID, let currentTask):
            operationID = currentOperationID
            task = currentTask
        case .closed(let result):
            try result.get()
            return
        }

        let result = await task.value
        finishClosingIfCurrent(operationID, result: result)
        try result.get()
    }

    func waitUntilClosed() async throws {
        switch state {
        case .closing(let operationID, let task):
            let result = await task.value
            finishClosingIfCurrent(operationID, result: result)
            try result.get()
        case .closed(let result):
            try result.get()
        case .stopped, .preparing, .prepared, .activating, .running, .stopping:
            throw ReviewLifecycleResourceFailure.mcpServer(
                "MCP owner did not close."
            )
        }
    }

    private func makeOperationID() -> UInt64 {
        nextOperationID &+= 1
        return nextOperationID
    }

    private func makePreparationTask(
        generation: MCPServerGeneration
    ) -> Task<PreparationResult, Never> {
        let configuration = configuration
        let bindChecker = bindChecker
        let factory = factory
        let store = store
        return Task { @MainActor [weak self] in
            guard let factory else {
                return .success(.init(generation: generation, server: nil))
            }
            guard let store else {
                return .failure(.mcpServer(
                    "MCP preparation requires its attached Store."
                ))
            }
            do {
                try await bindChecker(configuration)
                try Task.checkCancellation()
                return .success(.init(
                    generation: generation,
                    server: factory(store, configuration)
                ))
            } catch {
                guard let self else {
                    return .failure(.mcpServer(error.localizedDescription))
                }
                return .failure(await self.mappedPreparationFailure(error))
            }
        }
    }

    private func makeActivationTask(
        lease: Lease
    ) -> Task<ActivationResult, Never> {
        Task { @MainActor in
            guard let server = lease.server else {
                return .success(.init(
                    lease: lease,
                    snapshot: .init(serverURL: nil)
                ))
            }
            do {
                try await server.start()
                try Task.checkCancellation()
                return .success(.init(
                    lease: lease,
                    snapshot: .init(serverURL: await server.url)
                ))
            } catch {
                return .failure(.mcpServer(error.localizedDescription))
            }
        }
    }

    private func makeLifecycleTask(
        preparationTask: Task<PreparationResult, Never>? = nil,
        activationTask: Task<ActivationResult, Never>? = nil,
        lifecycleTask: Task<LifecycleResult, Never>? = nil,
        lease initialLease: Lease? = nil
    ) -> Task<LifecycleResult, Never> {
        Task { @MainActor in
            preparationTask?.cancel()
            activationTask?.cancel()
            var lease = initialLease
            if let lease {
                await lease.server?.closeAdmission()
            }
            if let preparationTask,
               case .success(let preparedLease) = await preparationTask.value {
                lease = preparedLease
                await preparedLease.server?.closeAdmission()
            }
            if let activationTask {
                _ = await activationTask.value
            }
            if let lifecycleTask {
                return await lifecycleTask.value
            }
            do {
                try await lease?.server?.stop()
            } catch let aggregate as ReviewLifecycleResourceFailureAggregate {
                return .failure(aggregate)
            } catch let failure as ReviewLifecycleResourceFailure {
                return .failure(.init(first: failure))
            } catch {
                return .failure(.init(first: .mcpServer(error.localizedDescription)))
            }
            return .success(())
        }
    }

    private func activationFailureCleanupTask(
        operationID: UInt64,
        lease: Lease
    ) -> (operationID: UInt64, task: Task<LifecycleResult, Never>)? {
        switch state {
        case .activating(let currentOperationID, let currentLease, _)
            where currentOperationID == operationID
                && currentLease.generation == lease.generation:
            let cleanupOperationID = makeOperationID()
            let task = makeLifecycleTask(lease: lease)
            state = .stopping(operationID: cleanupOperationID, task: task)
            return (cleanupOperationID, task)
        case .stopping(let currentOperationID, let task):
            return (currentOperationID, task)
        case .closing(let currentOperationID, let task):
            return (currentOperationID, task)
        case .stopped, .preparing, .prepared, .activating, .running, .closed:
            return nil
        }
    }

    private func finishStoppingIfCurrent(
        _ operationID: UInt64,
        result: LifecycleResult
    ) {
        guard case .stopping(let currentOperationID, _) = state,
              currentOperationID == operationID
        else {
            return
        }
        switch result {
        case .success:
            state = .stopped
        case .failure:
            state = .stopped
        }
    }

    private func finishClosingIfCurrent(
        _ operationID: UInt64,
        result: LifecycleResult
    ) {
        guard case .closing(let currentOperationID, _) = state,
              currentOperationID == operationID
        else {
            return
        }
        state = .closed(result)
    }

    private func supersededFailure(
        _ operation: String,
        generation: MCPServerGeneration
    ) -> ReviewLifecycleResourceFailure {
        .mcpServer(
            "MCP \(operation) for generation \(generation.rawValue) was superseded by a lifecycle transition."
        )
    }

    private func mappedPreparationFailure(
        _ error: any Error
    ) async -> ReviewLifecycleResourceFailure {
        guard let mcpError = error as? CodexReviewMCPHTTPServer.Error,
              case .addressInUse = mcpError
        else {
            return .mcpServer(error.localizedDescription)
        }
        let endpoint = configuration.url()
        var message = "MCP endpoint \(endpoint.absoluteString) is already in use"
        if let owner = await portOwnerResolver(configuration) {
            message += " by PID \(owner.processIdentifier)"
            if let command = owner.command?.trimmingCharacters(in: .whitespacesAndNewlines),
               command.isEmpty == false {
                message += " (\(command))"
            }
        }
        message += ". Quit that process or change the MCP port in Settings, then reset the server."
        return .mcpServer(message)
    }
}

@MainActor
private struct AppServerRuntime: Sendable {
    var client: AppServerClient
    var backend: AppServerCodexReviewBackend
}

private struct AppServerProcessRuntime: Sendable {
    var transport: AppServerProcessTransport
    var threadStartPermissionStrategy: AppServerAPI.Thread.Start.PermissionStrategy
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
    var rateLimits: AppServerAPI.Account.RateLimits.Snapshot
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

        static func legacyDefault(accountKey: String?, email: String) -> Self {
            let normalizedAccountKey = accountKey
                .map(CodexAccount.normalizedEmail)
                .flatMap { $0.isEmpty ? nil : $0 }
            switch normalizedAccountKey ?? CodexAccount.normalizedEmail(email) {
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
            .map(CodexAccount.normalizedEmail)
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
            .map(CodexAccount.normalizedEmail)
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
        let normalizedAccountKey = CodexAccount.normalizedEmail(accountKey)
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
        let normalizedAccountKey = CodexAccount.normalizedEmail(accountKey)
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
        let normalizedEmail = CodexAccount.normalizedEmail(email)
        let accountKey = entry.accountKey
            .map(CodexAccount.normalizedEmail)
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
        let normalizedEmail = CodexAccount.normalizedEmail(email)
        return entry.accountKey
            .map(CodexAccount.normalizedEmail)
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
        let normalizedAccountKey = CodexAccount.normalizedEmail(accountKey)
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
