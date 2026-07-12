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

private struct HostRuntimeConsumerFailure: Error, LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
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

    private var runtimeSession: HostRuntimeSession?
    private var nextRuntimeGeneration: UInt64 = 1
    private var loginSession: LoginSession?
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

    private var appServer: CodexAppServer? {
        runtimeSession?.activeRuntime?.appServer
    }

    private var appServerBackend: AppServerCodexReviewBackend? {
        runtimeSession?.activeRuntime?.backend
    }

    private var teardownAppServerBackend: AppServerCodexReviewBackend? {
        runtimeSession?.runtime?.backend
    }

    private var mcpHTTPServer: (any CodexReviewMCPHTTPServing)? {
        runtimeSession?.activeMCPHTTPServer
    }

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
        if let session = runtimeSession,
           session.isActive,
           forceRestartIfNeeded == false {
            logger.info("Review runtime already has an app-server backend")
            store.transitionToRunning(serverURL: await mcpHTTPServer?.url)
            return
        }
        if let session = runtimeSession {
            if case .stopIncomplete = session.phase {
                store.transitionToFailed(
                    "Review thread retention recovery is quarantined; the previous runtime cannot be replaced."
                )
                return
            }
            await stop(store: store, purpose: .runtimeRestartPreservingRuns)
            guard runtimeSession == nil else {
                store.transitionToFailed("The previous review runtime did not finish stopping.")
                return
            }
        }

        precondition(nextRuntimeGeneration < .max, "Host runtime generations must not wrap.")
        let session = HostRuntimeSession(
            generation: nextRuntimeGeneration,
            lifecycleHandler: appServerLifecycleHandler
        )
        nextRuntimeGeneration += 1
        runtimeSession = session
        do {
            let runtime = try await appServerRuntimeFactory(codexHomeURL)
            guard runtimeSession === session else {
                await runtime.appServer.close()
                return
            }
            do {
                try session.requireHealthyStaging()
            } catch {
                await runtime.appServer.close()
                return
            }
            session.installRuntime(runtime)
            let appServer = runtime.appServer
            let backend = runtime.backend
            let modelContainer = runtime.modelContainer
            try await installRuntimeConsumers(
                session: session,
                appServer: appServer,
                store: store
            )
            let authSnapshot = try await backend.readAuth()
            try requireCurrentStagingSession(session)
            try await applyAuthSnapshotSerialized(authSnapshot, to: store.auth)
            try requireCurrentStagingSession(session)
            switch await store.recoverOrphanedReviewThreads() {
            case .recovered, .cleanupIncomplete:
                break
            case .journalUnavailable(let message):
                throw ReviewBackendFailure.retentionJournal(message: message)
            }
            try requireCurrentStagingSession(session)
            if let mcpHTTPServerFactory {
                try await mcpHTTPServerBindChecker(mcpHTTPServerConfiguration)
                try requireCurrentStagingSession(session)
                let logProjectionProvider = CodexReviewMCPServer.chatLogProjectionProvider(
                    modelContext: modelContainer.mainContext
                )
                let mcpHTTPServer = mcpHTTPServerFactory(
                    store,
                    mcpHTTPServerConfiguration,
                    logProjectionProvider
                )
                session.installMCPHTTPServer(mcpHTTPServer)
                try await mcpHTTPServer.stage()
            }
            try requireCurrentStagingSession(session)
            let serverURL = await session.mcpHTTPServer?.url
            try requireCurrentStagingSession(session)
            store.transitionToRunning(serverURL: serverURL)
            session.commit()
            await session.mcpHTTPServer?.activate()
            guard runtimeSession === session, session.isActive else {
                return
            }
            await refreshSelectedAccountRateLimits(auth: store.auth)
            logger.info("Review runtime started")
        } catch {
            let ownsStagingFailure = runtimeSession === session && session.isStaging
            guard ownsStagingFailure else {
                _ = await session.waitForStopCompletion()
                logger.debug("Ignoring a late startup result from a stopped or superseded Host runtime generation")
                return
            }
            let failureMessage = await runtimeStartupFailureMessage(for: error)
            guard runtimeSession === session, session.isStaging else {
                _ = await session.waitForStopCompletion()
                logger.debug("Ignoring a late startup failure from a stopped Host runtime generation")
                return
            }
            logger.error("Review runtime failed to start: \(failureMessage, privacy: .public)")
            let stopTask = session.requestStop(purpose: .runtimeRestartPreservingRuns) { session in
                await self.performRuntimeStop(
                    session: session,
                    store: store,
                    reviewCleanupMode: .connected,
                    reviewCancellation: .system(message: "Review runtime staging failed."),
                    loginTerminationReason: .runtimeFailure(.runtime(message: failureMessage))
                )
            }
            if let stopTask, await stopTask.value == false {
                return
            }
            if runtimeSession === session {
                runtimeSession = nil
                store.transitionToFailed(failureMessage)
            }
        }
    }

    private func requireCurrentStagingSession(_ session: HostRuntimeSession) throws {
        guard runtimeSession === session else {
            throw HostRuntimeConsumerFailure(message: "The Host runtime staging generation was superseded.")
        }
        try session.requireHealthyStaging()
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
        let session = runtimeSession
        let loginSession = self.loginSession
        guard let session else {
            _ = await loginSession?.terminate(reason: .storeStop)
            if purpose.retiresRuns {
                _ = await store.retireReviewRunsForFinalStoreStop()
            }
            return
        }
        logger.info("Stopping review runtime")
        let task = session.requestStop(purpose: purpose) { session in
            await self.performRuntimeStop(
                session: session,
                store: store,
                reviewCleanupMode: .connected,
                reviewCancellation: .system(message: "Review runtime stopped."),
                loginTerminationReason: .storeStop
            )
        }
        if let task {
            let didReleaseResources = await task.value
            if didReleaseResources, runtimeSession === session {
                runtimeSession = nil
            }
        }
    }

    private func performRuntimeStop(
        session: HostRuntimeSession,
        store: CodexReviewStore,
        reviewCleanupMode: RuntimeReviewCleanupMode,
        reviewCancellation: ReviewCancellation,
        loginTerminationReason: LoginTerminationReason
    ) async -> Bool {
        let runtime = session.runtime
        await session.mcpHTTPServer?.stop()
        if let appServerBackend = runtime?.backend {
            await cleanupActiveReviewsForRuntimeTeardown(
                store: store,
                appServerBackend: appServerBackend,
                reason: reviewCancellation,
                mode: reviewCleanupMode
            )
        }
        _ = await loginSession?.terminate(reason: loginTerminationReason)
        if let appServer = runtime?.appServer {
            let retainedRestartIdentities = await appServer.discardAllPreparedReviewRestarts()
            precondition(
                retainedRestartIdentities.values.allSatisfy(\.isEmpty),
                "Review workers must transfer every prepared-restart identity before runtime teardown."
            )
        }
        if session.shouldRetireRuns {
            guard await store.retireReviewRunsForFinalStoreStop() else {
                logger.error("Review runtime remains open because an unpersisted cleanup quarantine is unresolved")
                return false
            }
        }
        await session.cancelConsumersAndWait()
        await runtime?.appServer.close()
        logger.info("Review runtime stopped")
        return true
    }

    func waitUntilStopped() async {
        if let task = runtimeSession?.stopTask {
            _ = await task.value
        }
    }

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
        try await beginStockLogin(auth: auth, request: .signIn)
    }

    func addAccount(auth: CodexReviewAuthModel) async throws {
        try await attachedStore?.requireReviewThreadRetentionAcceptance()
        try await beginStockLogin(auth: auth, request: .addAccount)
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
        let persisted = try await accountRegistry.activateAccount(accountKey)
        applyAccountRegistrySnapshot(persisted, to: auth)
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
        let before = try await accountRegistry.load()
        let normalizedAccountKey = CodexReviewAccount.normalizedEmail(accountKey)
        guard before.accounts.contains(where: { $0.accountKey == normalizedAccountKey }) else {
            return
        }
        let removedActiveAccount = before.activeAccountKey == normalizedAccountKey
        let persisted: AccountRegistryStore.Snapshot
        if removedActiveAccount {
            let prepared = try await accountRegistry.prepareIrreversibleRemoval(
                accountKey: normalizedAccountKey
            )
            do {
                if let appServerBackend {
                    _ = try await appServerBackend.logout(.init(normalizedAccountKey))
                }
                persisted = try await accountRegistry.commitPreparedMutation(prepared)
            } catch {
                try await abortPreparedAccountMutation(prepared, after: error)
            }
        } else {
            persisted = try await accountRegistry.removeInactiveAccount(
                accountKey: normalizedAccountKey
            )
        }
        await accountRegistry.cleanupRemovedAccountDirectory(accountKey: normalizedAccountKey)
        applyAccountRegistrySnapshot(persisted, to: auth)
        if removedActiveAccount {
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
        let persisted = try await accountRegistry.reorderAccount(
            accountKey: accountKey,
            toIndex: toIndex
        )
        applyAccountRegistrySnapshot(persisted, to: auth)
        }
    }

    func signOutActiveAccount(auth: CodexReviewAuthModel) async throws {
        try await attachedStore?.requireReviewThreadRetentionAcceptance()
        try await withAccountMutation {
        let before = try await accountRegistry.load()
        guard let accountKey = before.activeAccountKey else {
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
        let prepared = try await accountRegistry.prepareIrreversibleRemoval(
            accountKey: accountKey
        )
        let persisted: AccountRegistryStore.Snapshot
        do {
            if let appServerBackend {
                _ = try await appServerBackend.logout(.init(accountKey))
            }
            persisted = try await accountRegistry.commitPreparedMutation(prepared)
        } catch {
            try await abortPreparedAccountMutation(prepared, after: error)
        }
        await accountRegistry.cleanupRemovedAccountDirectory(accountKey: accountKey)
        applyAccountRegistrySnapshot(persisted, to: auth)
        auth.updatePhase(.signedOut)
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
        request: LoginRequest
    ) async throws {
        guard loginSession == nil else {
            throw CodexReviewAuthenticationFailure.alreadyInProgress
        }
        let authenticationMutation = try await accountRegistry.beginAuthenticationMutation(
            request: request
        )
        let mutationLease = authenticationMutation.lease
        let purpose = authenticationMutation.purpose
        let generationID = UUID()
        let runtimeProvider: @MainActor @Sendable (LoginPurpose) async throws -> LoginRuntime = {
            [weak self] purpose in
            guard let self else {
                throw CodexReviewAuthenticationFailure.runtime(
                    message: "The review store was released while authentication was starting."
                )
            }
            return try await self.loginRuntime(for: purpose)
        }
        let urlOpener = externalURLOpener
        let session = LoginSession(
            generationID: generationID,
            purpose: purpose,
            mutationLease: mutationLease,
            cancellationTimeout: .seconds(5),
            rootOperation: { @MainActor [weak self, weak auth] operationState, startCompletion in
                let finish: @MainActor (LoginRootObservation) -> LoginRootObservation = { observation in
                    self?.publishLoginRootObservation(
                        observation,
                        generationID: generationID
                    )
                    return observation
                }
                let runtime: LoginRuntime
                do {
                    runtime = try await runtimeProvider(purpose)
                } catch {
                    let failure = (error as? CodexReviewAuthenticationFailure)
                        ?? .runtime(message: error.localizedDescription)
                    await startCompletion.resolve(.failure(failure))
                    return finish(.failure(failure))
                }
                guard case .proceed = await operationState.bind(runtime: runtime) else {
                    await startCompletion.resolve(.success(()))
                    return finish(.outcome(.cancelled))
                }

                let handle: CodexLoginHandle
                do {
                    handle = try await runtime.appServer.loginChatGPT(
                        accountReadinessTimeout: .seconds(5)
                    )
                } catch {
                    let failure = (error as? CodexReviewAuthenticationFailure)
                        ?? .runtime(message: error.localizedDescription)
                    await startCompletion.resolve(.failure(failure))
                    return finish(.failure(failure))
                }

                let handleDisposition = await operationState.bind(
                    handle: handle,
                    runtime: runtime
                )
                auth?.updatePhase(.signingIn(.init(
                    title: "Sign in to Codex",
                    detail: "Continue signing in with your browser.",
                    browserURL: handle.authenticationURL.absoluteString,
                    userCode: nil
                )))

                if case .cancel = handleDisposition {
                    await startCompletion.resolve(.success(()))
                    do {
                        return finish(.outcome(try await handle.cancel(
                            acknowledgementTimeout: .seconds(5)
                        )))
                    } catch is CancellationError {
                        return finish(.waiterCancelled(message: nil))
                    } catch {
                        return finish(.waiterCancelled(message: error.localizedDescription))
                    }
                }

                do {
                    try await urlOpener(handle.authenticationURL)
                    await startCompletion.resolve(.success(()))
                } catch {
                    let failure = CodexReviewAuthenticationFailure.urlOpen(handle.authenticationURL)
                    await startCompletion.resolve(.failure(failure))
                    do {
                        switch try await handle.cancel(acknowledgementTimeout: .seconds(5)) {
                        case .succeeded,
                             .authenticationCommittedNeedsConnectionReconciliation:
                            return finish(.outcome(try await handle.result()))
                        case .failed(let message):
                            return finish(.outcome(.failed(message: message)))
                        case .cancelled:
                            return finish(.failure(failure))
                        }
                    } catch {
                        return finish(.failure(failure))
                    }
                }

                do {
                    return finish(.outcome(try await handle.result()))
                } catch is CancellationError {
                    return finish(.waiterCancelled(message: nil))
                } catch {
                    return finish(.failure(.runtime(message: error.localizedDescription)))
                }
            },
            terminationHandler: { @MainActor [weak self, weak auth] session, reason, observation in
                guard let self, let auth else {
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
        // The session owns the mutation lease and cancellation intent before either
        // runtime acquisition or account/login/start can suspend.
        loginSession = session
        let startResult = await session.activate()
        if case .failure(let failure) = startResult {
            _ = await session.terminate(reason: .rootOutcome)
            if case .addAccountPreservingActive = purpose {
                throw failure
            }
        }
    }

    private func publishLoginRootObservation(
        _ observation: LoginRootObservation,
        generationID: UUID
    ) {
        guard let session = loginSession,
              session.generationID == generationID else {
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
        guard let loginRuntime = await session.runtime() else {
            let failure = CodexReviewAuthenticationFailure.protocolViolation(
                message: "Authentication completed without a bound login runtime."
            )
            auth.updatePhase(.failed(failure))
            return .failed(failure)
        }
        var stagingURLRequiringRemoval: URL?
        defer {
            if let stagingURLRequiringRemoval {
                try? FileManager.default.removeItem(at: stagingURLRequiringRemoval)
            }
        }
        do {
            let snapshot = try await loginRuntime.backend.readAuth()
            let isolatedRateLimits: CodexRateLimits?
            if loginRuntime.usesPrimaryRuntime == false {
                isolatedRateLimits = try? await loginRuntime.backend.readRateLimits()
                guard let runtime = await session.takeOwnedRuntimeForClose() else {
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
                authSourceCodexHomeURL: loginRuntime.codexHomeURL
            )
            if loginRuntime.usesPrimaryRuntime == false {
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
        guard let runtime = await session.takeOwnedRuntimeForClose() else {
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
        guard let appServerBackend = teardownAppServerBackend else {
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
        guard let appServerBackend = teardownAppServerBackend else {
            preconditionFailure(
                "A prepared review restart must retain its matching app-server runtime until discard completes."
            )
        }
        return await appServerBackend.discardPreparedReviewRestart(token)
    }

    func cleanupReview(_ attempt: ReviewAttempt) async {
        guard let appServerBackend = teardownAppServerBackend else {
            return
        }
        await appServerBackend.cleanupReview(attempt)
    }

    func cleanupRetainedReviews(
        _ attempts: [ReviewAttempt],
        additionalThreadIDs: [ReviewThreadID]
    ) async -> ReviewRetainedThreadCleanupResult {
        guard let appServerBackend = teardownAppServerBackend else {
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

    private func applyAccountRegistrySnapshot(
        _ snapshot: AccountRegistryStore.Snapshot,
        to auth: CodexReviewAuthModel
    ) {
        auth.applyPersistedAccountStates(
            snapshot.accounts,
            activeAccountKey: snapshot.activeAccountKey
        )
        auth.selectPersistedAccount(snapshot.activeAccountKey)
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
            guard case .activateAuthenticatedAccount = activation else {
                throw CodexReviewAuthenticationFailure.protocolViolation(
                    message: "An isolated successful login did not expose its authenticated account."
                )
            }
            let persisted = try await accountRegistry.deactivateAccount()
            auth.applyPersistedAccountStates(
                persisted.accounts,
                activeAccountKey: persisted.activeAccountKey
            )
            auth.selectPersistedAccount(nil)
            auth.updatePhase(.signedOut)
            return nil
        }
        let accountPayload = savedAccountPayload(from: account)
        let persisted: AccountRegistryStore.Snapshot
        if accountPayload.kind == .chatGPT {
            persisted = try await accountRegistry.commitAuthenticatedAccount(
                accountPayload,
                activation: activation,
                authSourceCodexHomeURL: authSourceCodexHomeURL
            )
        } else {
            persisted = try await accountRegistry.upsertAccount(
                accountPayload,
                activation: activation
            )
        }
        auth.applyPersistedAccountStates(
            persisted.accounts,
            activeAccountKey: persisted.activeAccountKey
        )
        auth.selectPersistedAccount(persisted.activeAccountKey)
        auth.updatePhase(.signedOut)
        return auth.persistedAccounts.first(where: { $0.accountKey == account.accountKey })
    }

    private func installRuntimeConsumers(
        session: HostRuntimeSession,
        appServer: CodexAppServer,
        store: CodexReviewStore
    ) async throws {
        let generation = session.generation
        let connectionEvents = await appServer.connectionEvents()
        do {
            try requireCurrentStagingSession(session)
        } catch {
            await connectionEvents.cancel()
            throw error
        }
        let accountEvents = await appServer.accountEvents()
        do {
            try requireCurrentStagingSession(session)
        } catch {
            await accountEvents.cancel()
            await connectionEvents.cancel()
            throw error
        }
        session.installConsumers(
            accountEvents: accountEvents,
            connectionEvents: connectionEvents,
            accountEventSink: { @MainActor [weak self, weak store] event in
                guard let self, let store else {
                    return
                }
                await self.handleRuntimeAccountEvent(
                    event,
                    generation: generation,
                    store: store
                )
            },
            exitSink: { @MainActor [weak self, weak store] failure in
                guard let self, let store else {
                    return
                }
                self.runtimeConsumerDidExit(
                    generation: generation,
                    failure: failure,
                    store: store
                )
            }
        )
    }

    private func handleRuntimeAccountEvent(
        _ event: CodexAccountEvent,
        generation: UInt64,
        store: CodexReviewStore
    ) async {
        guard let session = runtimeSession,
              session.generation == generation,
              let backend = session.activeRuntime?.backend else {
            return
        }
        await handleAuthNotification(
            event,
            generation: generation,
            backend: backend,
            store: store
        )
    }

    private func runtimeConsumerDidExit(
        generation: UInt64,
        failure: HostRuntimeConsumerFailure,
        store: CodexReviewStore
    ) {
        guard let session = runtimeSession,
              session.generation == generation else {
            return
        }
        switch session.phase {
        case .staging:
            session.recordStagingFailure(failure)
        case .active:
            let message = "Review runtime stopped unexpectedly: \(failure.message)"
            store.transitionToFailed(message)
            _ = session.requestStop(purpose: .runtimeRestartPreservingRuns) { session in
                let didReleaseResources = await self.performRuntimeStop(
                    session: session,
                    store: store,
                    reviewCleanupMode: .connectionTerminated,
                    reviewCancellation: .system(message: message),
                    loginTerminationReason: .runtimeFailure(.runtime(message: message))
                )
                if didReleaseResources, self.runtimeSession === session {
                    self.runtimeSession = nil
                }
                return didReleaseResources
            }
        case .stopping, .stopIncomplete, .stopped:
            return
        }
    }

    private func handleAuthNotification(
        _ event: CodexAccountEvent,
        generation: UInt64,
        backend: AppServerCodexReviewBackend,
        store: CodexReviewStore
    ) async {
        switch event {
        case .accountUpdated:
            if loginSession != nil {
                return
            }
            await refreshAuthAfterAccountNotification(
                generation: generation,
                backend: backend,
                store: store
            )
        case .rateLimitsUpdated(let rateLimits):
            guard acceptsRuntimeEvent(generation: generation) else {
                return
            }
            await applyRateLimitsUpdatedNotification(rateLimits, auth: store.auth)
        case .malformed(let method, let message):
            logger.error("Malformed account notification \(method, privacy: .public): \(message, privacy: .public)")
        case .unknown:
            return
        }
    }

    private func refreshAuthAfterAccountNotification(
        generation: UInt64,
        backend: AppServerCodexReviewBackend,
        store: CodexReviewStore
    ) async {
        do {
            let snapshot = try await backend.readAuth()
            guard acceptsRuntimeEvent(generation: generation) else {
                return
            }
            do {
                try await accountRuntimeTransitionCoordinator.perform {
                    guard self.acceptsRuntimeEvent(generation: generation) else {
                        return
                    }
                    try await self.applyAuthSnapshotSerialized(snapshot, to: store.auth)
                }
            } catch CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication {
                logger.debug("Dropping an account notification while an account transition owns publication")
                return
            }
            guard acceptsRuntimeEvent(generation: generation) else {
                return
            }
            await refreshSelectedAccountRateLimits(auth: store.auth)
        } catch {
            guard acceptsRuntimeEvent(generation: generation) else {
                return
            }
            store.auth.updatePhase(.failed(.runtime(message: error.localizedDescription)))
        }
    }

    private func acceptsRuntimeEvent(generation: UInt64) -> Bool {
        guard let session = runtimeSession,
              session.generation == generation else {
            return false
        }
        return session.isActive
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
private final class HostRuntimeSession {
    enum Phase {
        case staging
        case active
        case stopping
        case stopIncomplete
        case stopped
    }

    let generation: UInt64

    private(set) var phase: Phase = .staging
    private(set) var runtime: AppServerRuntime?
    private(set) var mcpHTTPServer: (any CodexReviewMCPHTTPServing)?
    private(set) var accountEvents: CodexAccountEvents?
    private(set) var accountConsumerTask: Task<Void, Never>?
    private(set) var connectionEvents: CodexConnectionEvents?
    private(set) var connectionConsumerTask: Task<Void, Never>?
    private(set) var stopTask: Task<Bool, Never>?
    private(set) var shouldRetireRuns = false

    private let lifecycleHandler: CodexReviewAppServerLifecycleHandler?
    private var didPublishLifecycle = false
    private var stagingFailure: HostRuntimeConsumerFailure?

    init(
        generation: UInt64,
        lifecycleHandler: CodexReviewAppServerLifecycleHandler?
    ) {
        self.generation = generation
        self.lifecycleHandler = lifecycleHandler
    }

    var activeRuntime: AppServerRuntime? {
        guard case .active = phase else {
            return nil
        }
        return runtime
    }

    var activeMCPHTTPServer: (any CodexReviewMCPHTTPServing)? {
        guard case .active = phase else {
            return nil
        }
        return mcpHTTPServer
    }

    var isActive: Bool {
        if case .active = phase {
            return true
        }
        return false
    }

    func installRuntime(_ runtime: AppServerRuntime) {
        precondition(self.runtime == nil, "A Host runtime session can install its app-server runtime only once.")
        precondition(isStaging, "An app-server runtime can be installed only while staging.")
        self.runtime = runtime
    }

    func installMCPHTTPServer(_ server: any CodexReviewMCPHTTPServing) {
        precondition(mcpHTTPServer == nil, "A Host runtime session can install its MCP server only once.")
        precondition(isStaging, "An MCP server can be installed only while staging.")
        mcpHTTPServer = server
    }

    func installConsumers(
        accountEvents: CodexAccountEvents,
        connectionEvents: CodexConnectionEvents,
        accountEventSink: @escaping @MainActor @Sendable (CodexAccountEvent) async -> Void,
        exitSink: @escaping @MainActor @Sendable (HostRuntimeConsumerFailure) -> Void
    ) {
        precondition(
            self.accountEvents == nil && accountConsumerTask == nil
                && self.connectionEvents == nil && connectionConsumerTask == nil,
            "A Host runtime session can install its event consumers only once."
        )
        precondition(isStaging, "Runtime consumers can be installed only while staging.")
        self.accountEvents = accountEvents
        accountConsumerTask = Task { @MainActor in
            do {
                for try await event in accountEvents {
                    await accountEventSink(event)
                }
                if Task.isCancelled == false {
                    exitSink(.init(message: "The Codex account event stream ended unexpectedly."))
                }
            } catch is CancellationError {
            } catch {
                logger.error("Auth notification stream ended: \(error.localizedDescription, privacy: .public)")
                exitSink(.init(message: error.localizedDescription))
            }
        }
        self.connectionEvents = connectionEvents
        connectionConsumerTask = Task { @MainActor in
            for await event in connectionEvents {
                switch event {
                case .warning(let diagnostic):
                    logger.warning("App-server warning: \(diagnostic.message, privacy: .public)")
                case .retrying(let diagnostic):
                    logger.warning("App-server retrying \(diagnostic.method, privacy: .public) attempt \(diagnostic.attempt, privacy: .public)")
                case .deprecation(let notice):
                    logger.warning("App-server deprecation: \(notice.summary, privacy: .public)")
                case .unknown:
                    logger.debug("Unknown app-server notification")
                case .terminated(let termination):
                    exitSink(.init(message: Self.failureMessage(for: termination)))
                    return
                }
            }
            if Task.isCancelled == false {
                exitSink(.init(message: "The Codex connection event stream ended unexpectedly."))
            }
        }
    }

    func commit() {
        precondition(isStaging, "Only a staged Host runtime session can become active.")
        guard let modelContainer = runtime?.modelContainer else {
            preconditionFailure("A Host runtime session requires a model container before publication.")
        }
        phase = .active
        didPublishLifecycle = true
        lifecycleHandler?(modelContainer)
    }

    func recordStagingFailure(_ failure: HostRuntimeConsumerFailure) {
        guard isStaging, stagingFailure == nil else {
            return
        }
        stagingFailure = failure
    }

    func requireHealthyStaging() throws {
        guard isStaging else {
            throw HostRuntimeConsumerFailure(message: "The Host runtime staging generation was superseded.")
        }
        if let stagingFailure {
            throw stagingFailure
        }
    }

    func beginStopping() {
        switch phase {
        case .staging, .active, .stopIncomplete:
            phase = .stopping
        case .stopping, .stopped:
            return
        }
        if didPublishLifecycle {
            didPublishLifecycle = false
            lifecycleHandler?(nil)
        }
    }

    func cancelConsumersAndWait() async {
        await connectionEvents?.cancel()
        await accountEvents?.cancel()
        connectionConsumerTask?.cancel()
        accountConsumerTask?.cancel()
        await connectionConsumerTask?.value
        await accountConsumerTask?.value
        connectionEvents = nil
        connectionConsumerTask = nil
        accountEvents = nil
        accountConsumerTask = nil
    }

    func waitForStopCompletion() async -> Bool? {
        guard let stopTask else {
            return nil
        }
        return await stopTask.value
    }

    func finishStopping(didReleaseResources: Bool) {
        precondition(stopTask == nil, "The shared stop task must clear itself before stop completion is published.")
        if didReleaseResources {
            runtime = nil
            mcpHTTPServer = nil
            accountEvents = nil
            accountConsumerTask = nil
            connectionEvents = nil
            connectionConsumerTask = nil
            phase = .stopped
        } else {
            phase = .stopIncomplete
        }
    }

    func requestStop(
        purpose: CodexReviewRuntimeStopPurpose,
        _ operation: @escaping @MainActor @Sendable (HostRuntimeSession) async -> Bool
    ) -> Task<Bool, Never>? {
        if purpose.retiresRuns {
            shouldRetireRuns = true
        }
        if let stopTask {
            return stopTask
        }
        switch phase {
        case .stopped:
            return nil
        case .stopping:
            preconditionFailure("A stopping Host runtime session must retain its shared stop completion.")
        case .staging, .active, .stopIncomplete:
            break
        }
        beginStopping()
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return true
            }
            let didReleaseResources = await operation(self)
            self.stopTask = nil
            self.finishStopping(didReleaseResources: didReleaseResources)
            return didReleaseResources
        }
        stopTask = task
        return task
    }

    var isStaging: Bool {
        if case .staging = phase {
            return true
        }
        return false
    }

    private nonisolated static func failureMessage(
        for termination: CodexConnectionTermination
    ) -> String {
        switch termination {
        case .closedByCaller:
            "The Codex app-server connection was closed by the caller."
        case .transportFailure(let failure):
            failure.localizedDescription
        case .processExited(let status):
            if let status {
                "The Codex app-server process exited with status \(status)."
            } else {
                "The Codex app-server process exited."
            }
        }
    }
}

actor AccountRegistryStore {
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

    struct AuthenticationMutation: Sendable {
        let lease: MutationLease
        let purpose: LoginPurpose
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

    func deactivateAccount() throws -> Snapshot {
        try Disk.deactivateAccount(codexHomeURL: codexHomeURL)
        return try Disk.load(codexHomeURL: codexHomeURL)
    }

    func activateAccount(_ accountKey: String) throws -> Snapshot {
        try Disk.activateAccount(accountKey, codexHomeURL: codexHomeURL)
        return try Disk.load(codexHomeURL: codexHomeURL)
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
        activation: LoginActivation,
        authSourceCodexHomeURL: URL?
    ) throws -> Snapshot {
        try Disk.commitAuthenticatedAccount(
            authenticatedAccount,
            activation: activation,
            authSourceCodexHomeURL: authSourceCodexHomeURL ?? codexHomeURL,
            codexHomeURL: codexHomeURL
        )
        return try Disk.load(codexHomeURL: codexHomeURL)
    }

    func upsertAccount(
        _ account: CodexSavedAccountPayload,
        activation: LoginActivation
    ) throws -> Snapshot {
        try Disk.upsertAccount(
            account,
            activation: activation,
            codexHomeURL: codexHomeURL
        )
        return try Disk.load(codexHomeURL: codexHomeURL)
    }

    func prepareIrreversibleRemoval(
        accountKey: String
    ) throws -> PreparedMutation {
        try Disk.prepareIrreversibleRemoval(
            accountKey: accountKey,
            codexHomeURL: codexHomeURL
        )
    }

    func commitPreparedMutation(_ mutation: PreparedMutation) throws -> Snapshot {
        try Disk.commitPreparedMutation(mutation, codexHomeURL: codexHomeURL)
        return try Disk.load(codexHomeURL: codexHomeURL)
    }

    func abortPreparedMutation(_ mutation: PreparedMutation) throws {
        try Disk.abortPreparedMutation(mutation, codexHomeURL: codexHomeURL)
    }

    func removeInactiveAccount(accountKey: String) throws -> Snapshot {
        try Disk.removeInactiveAccount(accountKey: accountKey, codexHomeURL: codexHomeURL)
        return try Disk.load(codexHomeURL: codexHomeURL)
    }

    func reorderAccount(accountKey: String, toIndex: Int) throws -> Snapshot {
        try Disk.reorderAccount(
            accountKey: accountKey,
            toIndex: toIndex,
            codexHomeURL: codexHomeURL
        )
        return try Disk.load(codexHomeURL: codexHomeURL)
    }

    func cleanupRemovedAccountDirectory(accountKey: String) {
        do {
            try Disk.removeSavedAccountDirectory(
                accountKey: accountKey,
                codexHomeURL: codexHomeURL
            )
        } catch {
            // The registry replace is the product commit. A stale account directory
            // is unreferenced data and is collected by the next load; it cannot roll
            // a committed account selection back into the UI.
            logger.error(
                "Committed account removal left cleanup debt for \(accountKey, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func copySavedAuth(accountKey: String, to destinationCodexHomeURL: URL) throws -> Bool {
        try requireNoAccountMutationForBackgroundPersistence()
        return try Disk.copySavedAuth(
            accountKey: accountKey,
            from: codexHomeURL,
            to: destinationCodexHomeURL
        )
    }

    func beginAuthenticationMutation(request: LoginRequest) throws -> AuthenticationMutation {
        if let activeMutation {
            switch activeMutation.kind {
            case .authentication:
                throw CodexReviewAuthenticationFailure.alreadyInProgress
            case .account:
                throw CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
            }
        }
        let snapshot = try Disk.load(codexHomeURL: codexHomeURL)
        let purpose: LoginPurpose = switch request {
        case .signIn:
            .signIn
        case .addAccount:
            snapshot.activeAccountKey == nil ? .signIn : .addAccountPreservingActive
        }
        return .init(
            lease: installMutation(kind: .authentication),
            purpose: purpose
        )
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
        guard activeMutation == nil else {
            throw CodexReviewAuthenticationFailure.accountCommit(
                message: "Background account metadata persistence is blocked while an account mutation or authentication is in progress."
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

    static func deactivateAccount(codexHomeURL: URL) throws {
        var registry = try loadRegistry(codexHomeURL: codexHomeURL)
        guard registry.activeAccountKey != nil else {
            return
        }
        registry.activeAccountKey = nil
        try saveRegistry(registry, codexHomeURL: codexHomeURL)
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
        if let index = desiredRegistry.accounts.firstIndex(where: {
            normalizedAccountKey(from: $0) == targetAccountKey
        }) {
            desiredRegistry.accounts[index].lastActivatedAt = Date()
        }
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
        accountKey: String,
        codexHomeURL: URL
    ) throws -> AccountRegistryStore.PreparedMutation {
        let beforeRegistry = try loadRegistry(codexHomeURL: codexHomeURL)
        let normalizedAccountKey = CodexReviewAccount.normalizedEmail(accountKey)
        guard beforeRegistry.accounts.contains(where: {
            self.normalizedAccountKey(from: $0) == normalizedAccountKey
        }) else {
            throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                message: "Cannot prepare removal for missing account \(normalizedAccountKey)."
            )
        }
        var desiredRegistry = beforeRegistry
        desiredRegistry.accounts.removeAll {
            self.normalizedAccountKey(from: $0) == normalizedAccountKey
        }
        if desiredRegistry.activeAccountKey.map(CodexReviewAccount.normalizedEmail) == normalizedAccountKey {
            desiredRegistry.activeAccountKey = nil
        }
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
        activation: LoginActivation,
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
        var authenticatedAccount = authenticatedAccount
        if let existingPayload = existingEntry.flatMap(makePayload(from:)) {
            authenticatedAccount.rateLimits = existingPayload.rateLimits
            authenticatedAccount.lastRateLimitFetchAt = existingPayload.lastRateLimitFetchAt
            authenticatedAccount.lastRateLimitError = existingPayload.lastRateLimitError
        }
        var accounts = existing.accounts.compactMap(makePayload(from:))
        if let index = accounts.firstIndex(where: { $0.accountKey == authenticatedAccount.accountKey }) {
            accounts[index] = authenticatedAccount
        } else {
            accounts.insert(authenticatedAccount, at: 0)
        }
        let normalizedActiveAccountKey: String? = switch activation {
        case .activateAuthenticatedAccount:
            authenticatedAccount.accountKey
        case .preserveActiveAccount:
            existing.activeAccountKey
        }
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

    static func upsertAccount(
        _ account: CodexSavedAccountPayload,
        activation: LoginActivation,
        codexHomeURL: URL
    ) throws {
        let existing = try loadRegistry(codexHomeURL: codexHomeURL)
        var account = account
        if let existingEntry = existing.accounts.first(where: {
            normalizedAccountKey(from: $0) == account.accountKey
        }), let existingPayload = makePayload(from: existingEntry) {
            account.rateLimits = existingPayload.rateLimits
            account.lastRateLimitFetchAt = existingPayload.lastRateLimitFetchAt
            account.lastRateLimitError = existingPayload.lastRateLimitError
        }
        var accounts = existing.accounts.compactMap(makePayload(from:))
        if let index = accounts.firstIndex(where: { $0.accountKey == account.accountKey }) {
            accounts[index] = account
        } else {
            accounts.insert(account, at: 0)
        }
        let activeAccountKey: String? = switch activation {
        case .activateAuthenticatedAccount:
            account.accountKey
        case .preserveActiveAccount:
            existing.activeAccountKey
        }
        try saveRegistry(
            .init(
                schemaVersion: existing.schemaVersion,
                generation: existing.generation,
                contentHash: existing.contentHash,
                activeAccountKey: activeAccountKey,
                accounts: mergedEntries(
                    accounts,
                    activeAccountKey: activeAccountKey,
                    existing: existing.accounts
                )
            ),
            codexHomeURL: codexHomeURL
        )
    }

    static func removeInactiveAccount(
        accountKey: String,
        codexHomeURL: URL
    ) throws {
        let normalizedAccountKey = CodexReviewAccount.normalizedEmail(accountKey)
        let existing = try loadRegistry(codexHomeURL: codexHomeURL)
        precondition(
            existing.activeAccountKey.map(CodexReviewAccount.normalizedEmail) != normalizedAccountKey,
            "An active account removal requires the irreversible mutation journal."
        )
        var desired = existing
        desired.accounts.removeAll {
            self.normalizedAccountKey(from: $0) == normalizedAccountKey
        }
        try saveRegistry(desired, codexHomeURL: codexHomeURL)
    }

    static func reorderAccount(
        accountKey: String,
        toIndex: Int,
        codexHomeURL: URL
    ) throws {
        let normalizedAccountKey = CodexReviewAccount.normalizedEmail(accountKey)
        var registry = try loadRegistry(codexHomeURL: codexHomeURL)
        guard let sourceIndex = registry.accounts.firstIndex(where: {
            self.normalizedAccountKey(from: $0) == normalizedAccountKey
        }), registry.accounts.count > 1 else {
            return
        }
        let destinationIndex = max(0, min(toIndex, registry.accounts.count - 1))
        guard sourceIndex != destinationIndex else {
            return
        }
        let entry = registry.accounts.remove(at: sourceIndex)
        registry.accounts.insert(entry, at: destinationIndex)
        try saveRegistry(registry, codexHomeURL: codexHomeURL)
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
            let remainingRevisionURLs = try FileManager.default.contentsOfDirectory(
                at: revisionsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
            let accountDirectoryPrefix = accountDirectory.standardizedFileURL.path + "/"
            let isReferencedAccountDirectory = referencedPaths.contains {
                $0.hasPrefix(accountDirectoryPrefix)
            }
            if remainingRevisionURLs.isEmpty, isReferencedAccountDirectory == false {
                try FileManager.default.removeItem(at: accountDirectory)
                try synchronizeDirectory(at: accountsURL)
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
