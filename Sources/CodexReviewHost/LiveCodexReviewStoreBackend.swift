import AppKit
import Foundation
import OSLog
import CodexAppServerKit
import CodexDataKit
import CodexReviewKit
import CodexReviewAppServer
import CodexReviewMCPServer

private let logger = Logger(subsystem: "CodexReviewKit", category: "live-store-backend")
package typealias ExternalURLOpener = @MainActor @Sendable (URL) throws -> Void
public typealias CodexReviewAppServerLifecycleHandler = @MainActor @Sendable (CodexModelContainer?) -> Void

private let defaultExternalURLOpener: ExternalURLOpener = { url in
    guard NSWorkspace.shared.open(url) else {
        throw CodexReviewAuthenticationFailure.urlOpen(url)
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

package typealias CodexReviewAuthenticationMutationDidBegin = @Sendable () async -> Void
package typealias CodexReviewAuthenticationCancellationDidRequest = @Sendable () async -> Void
package typealias CodexReviewAuthenticationProductCommitDidApply = @Sendable () async -> Void
package typealias CodexReviewAuthenticationHandleDidBind = @Sendable () async -> Void
package typealias CodexReviewAccountRegistryLoadDidBegin = @Sendable () async -> Void
package typealias CodexReviewAppServerCloser = @MainActor @Sendable (CodexAppServer) async -> Void
package typealias CodexReviewFinalRuntimeRetirementDidClaim = @MainActor @Sendable () async -> Void
package typealias CodexReviewFinalShutdownDidRequest = @MainActor @Sendable () async -> Void
package typealias CodexReviewReconciliationDebtDidClear = @MainActor @Sendable (CodexAppServer) async -> Void
package typealias CodexReviewRegistryDestinationDidReplace = @Sendable () throws -> Void

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
        appServerLifecycleHandler: CodexReviewAppServerLifecycleHandler? = nil,
        authenticationMutationDidBegin: CodexReviewAuthenticationMutationDidBegin? = nil,
        authenticationCancellationDidRequest: CodexReviewAuthenticationCancellationDidRequest? = nil,
        authenticationProductCommitDidApply: CodexReviewAuthenticationProductCommitDidApply? = nil,
        authenticationHandleDidBind: CodexReviewAuthenticationHandleDidBind? = nil,
        accountRegistryLoadDidBegin: CodexReviewAccountRegistryLoadDidBegin? = nil,
        finalRuntimeRetirementDidClaim: CodexReviewFinalRuntimeRetirementDidClaim? = nil,
        finalShutdownDidRequest: CodexReviewFinalShutdownDidRequest? = nil,
        reconciliationDebtDidClear: CodexReviewReconciliationDebtDidClear? = nil,
        registryDestinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil,
        appServerCloser: @escaping CodexReviewAppServerCloser = { await $0.close() }
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
            authenticationMutationDidBegin: authenticationMutationDidBegin,
            authenticationCancellationDidRequest: authenticationCancellationDidRequest,
            authenticationProductCommitDidApply: authenticationProductCommitDidApply,
            authenticationHandleDidBind: authenticationHandleDidBind,
            accountRegistryLoadDidBegin: accountRegistryLoadDidBegin,
            finalRuntimeRetirementDidClaim: finalRuntimeRetirementDidClaim,
            finalShutdownDidRequest: finalShutdownDidRequest,
            reconciliationDebtDidClear: reconciliationDebtDidClear,
            registryDestinationDidReplace: registryDestinationDidReplace,
            appServerCloser: appServerCloser,
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
        authenticationMutationDidBegin: CodexReviewAuthenticationMutationDidBegin? = nil,
        authenticationCancellationDidRequest: CodexReviewAuthenticationCancellationDidRequest? = nil,
        authenticationProductCommitDidApply: CodexReviewAuthenticationProductCommitDidApply? = nil,
        authenticationHandleDidBind: CodexReviewAuthenticationHandleDidBind? = nil,
        accountRegistryLoadDidBegin: CodexReviewAccountRegistryLoadDidBegin? = nil,
        finalRuntimeRetirementDidClaim: CodexReviewFinalRuntimeRetirementDidClaim? = nil,
        finalShutdownDidRequest: CodexReviewFinalShutdownDidRequest? = nil,
        reconciliationDebtDidClear: CodexReviewReconciliationDebtDidClear? = nil,
        registryDestinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil,
        appServerCloser: @escaping CodexReviewAppServerCloser = { await $0.close() },
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
                authenticationMutationDidBegin: authenticationMutationDidBegin,
                authenticationCancellationDidRequest: authenticationCancellationDidRequest,
                authenticationProductCommitDidApply: authenticationProductCommitDidApply,
                authenticationHandleDidBind: authenticationHandleDidBind,
                accountRegistryLoadDidBegin: accountRegistryLoadDidBegin,
                finalRuntimeRetirementDidClaim: finalRuntimeRetirementDidClaim,
                finalShutdownDidRequest: finalShutdownDidRequest,
                reconciliationDebtDidClear: reconciliationDebtDidClear,
                registryDestinationDidReplace: registryDestinationDidReplace,
                appServerCloser: appServerCloser,
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

    private enum RuntimePublicationOwner {
        case explicit(AccountRuntimeTransitionCoordinator.ExplicitRuntimeStart)
        case account(AccountRuntimeTransitionCoordinator.AccountTransition)
        case primary(AccountRuntimeTransitionCoordinator.PrimaryReconciliationReservation)
    }

    private enum RuntimeStartMode {
        case published(owner: RuntimePublicationOwner)
        case quiescentReconciliation

        var explicitStart: AccountRuntimeTransitionCoordinator.ExplicitRuntimeStart? {
            guard case .published(.explicit(let explicitStart)) = self else {
                return nil
            }
            return explicitStart
        }

        var requestsPublication: Bool {
            if case .published = self {
                return true
            }
            return false
        }
    }

    private enum RuntimeAuthReconciliationCause {
        case manualRefresh
        case accountUpdated
    }

    private enum ActiveRateLimitRefreshFailure: Error {
        case staleAccountIdentity
    }

    @MainActor
    private final class AccountMutationContext {
        let lease: AccountRegistryStore.MutationLease
        let before: AccountRegistryStore.Snapshot
        private(set) var recoveryExpectation: ExpectedRuntimeAccount
        private let admittedRuntimeGeneration: UInt64?
        private let admittedRuntimeInvalidationRevision: UInt64?
        private var recoversAdmittedRuntime = true

        init(
            _ mutation: AccountRegistryStore.AccountMutation,
            admittedRuntimeGeneration: UInt64?,
            admittedRuntimeInvalidationRevision: UInt64?
        ) {
            lease = mutation.lease
            before = mutation.before
            recoveryExpectation = mutation.before.expectedRuntimeAccount
            self.admittedRuntimeGeneration = admittedRuntimeGeneration
            self.admittedRuntimeInvalidationRevision = admittedRuntimeInvalidationRevision
        }

        func expectRecovery(_ expectation: ExpectedRuntimeAccount) {
            recoveryExpectation = expectation
            recoversAdmittedRuntime = false
        }

        func expectBeforeRecovery() {
            recoveryExpectation = before.expectedRuntimeAccount
            recoversAdmittedRuntime = true
        }

        func expectationForUnconfirmedMutation(
            currentRuntimeSession: HostRuntimeSession?
        ) -> ExpectedRuntimeAccount {
            guard recoversAdmittedRuntime,
                  let admittedRuntimeGeneration,
                  let admittedRuntimeInvalidationRevision else {
                return recoveryExpectation
            }
            guard currentRuntimeSession?.generation == admittedRuntimeGeneration,
                  currentRuntimeSession?.accountInvalidationRevision
                    == admittedRuntimeInvalidationRevision else {
                return .reconcileCurrentRuntime
            }
            return recoveryExpectation
        }
    }

    let seed: CodexReviewStoreSeed

    private var runtimeSession: HostRuntimeSession?
    private var nextRuntimeGeneration: UInt64 = 1
    private var loginSession: LoginSession?
    private var primaryLoginAdmission: (
        generationID: UUID,
        admission: AccountRuntimeTransitionCoordinator.LoginAdmission
    )?
    private var activePrimaryAuthenticationReconciliation: (
        loginGenerationID: UUID,
        finalResult: LoginFinalResultCompletion
    )?
    private var pendingRuntimeRestart: (
        admission: CodexReviewRuntimeRestartAdmission,
        start: AccountRuntimeTransitionCoordinator.ExplicitRuntimeStart
    )?
    private var pendingRuntimeAuthDrainTask: Task<Void, Never>?
    private var pendingRuntimeAuthDrainRequestRevision: UInt64 = 0
    private var runtimeStopFollowups: [UInt64: Task<Void, Never>] = [:]
    private var settingsSnapshot = CodexReviewSettings.Snapshot()
    private let codexHomeURL: URL
    private let mcpHTTPServerConfiguration: CodexReviewMCPHTTPServer.Configuration
    private let externalURLOpener: ExternalURLOpener
    private let mcpHTTPServerFactory: MCPHTTPServerFactory?
    private let mcpPortOwnerResolver: CodexReviewMCPPortOwnerResolver
    private let mcpHTTPServerBindChecker: CodexReviewMCPHTTPServerBindChecker
    private let appServerRuntimeFactory: AppServerRuntimeFactory
    private let appServerCloser: CodexReviewAppServerCloser
    private let authenticationHandleDidBind: CodexReviewAuthenticationHandleDidBind?
    private let finalRuntimeRetirementDidClaim: CodexReviewFinalRuntimeRetirementDidClaim?
    private let reconciliationDebtDidClear: CodexReviewReconciliationDebtDidClear?
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

    private func quiesceRuntimeAdmissionForAccountTransition() async {
        guard let session = runtimeSession else {
            return
        }
        session.closeAdmission()
        await accountRegistry.closeRuntimeAdmission(generation: session.generation)
        await session.mcpHTTPServer?.stop()
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
        authenticationMutationDidBegin: CodexReviewAuthenticationMutationDidBegin? = nil,
        authenticationCancellationDidRequest: CodexReviewAuthenticationCancellationDidRequest? = nil,
        authenticationProductCommitDidApply: CodexReviewAuthenticationProductCommitDidApply? = nil,
        authenticationHandleDidBind: CodexReviewAuthenticationHandleDidBind? = nil,
        accountRegistryLoadDidBegin: CodexReviewAccountRegistryLoadDidBegin? = nil,
        finalRuntimeRetirementDidClaim: CodexReviewFinalRuntimeRetirementDidClaim? = nil,
        finalShutdownDidRequest: CodexReviewFinalShutdownDidRequest? = nil,
        reconciliationDebtDidClear: CodexReviewReconciliationDebtDidClear? = nil,
        registryDestinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil,
        appServerCloser: @escaping CodexReviewAppServerCloser = { await $0.close() },
        appServerRuntimeFactory: AppServerRuntimeFactory? = nil
    ) {
        let runtimePreferences = runtimePreferences.normalized
        codexHomeURL = Self.codexHomeURL(
            runtimePreferences: runtimePreferences,
            environment: environment
        )
        accountRegistry = AccountRegistryStore(
            codexHomeURL: codexHomeURL,
            authenticationMutationDidBegin: authenticationMutationDidBegin,
            authenticationCancellationDidRequest: authenticationCancellationDidRequest,
            authenticationProductCommitDidApply: authenticationProductCommitDidApply,
            registryDestinationDidReplace: registryDestinationDidReplace,
            loadDidBegin: accountRegistryLoadDidBegin
        )
        accountRuntimeTransitionCoordinator = AccountRuntimeTransitionCoordinator(
            finalShutdownDidRequest: finalShutdownDidRequest
        )
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
        self.appServerCloser = appServerCloser
        self.authenticationHandleDidBind = authenticationHandleDidBind
        self.finalRuntimeRetirementDidClaim = finalRuntimeRetirementDidClaim
        self.reconciliationDebtDidClear = reconciliationDebtDidClear
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
        accountRuntimeTransitionCoordinator.installDidBecomeIdle { [weak self] in
            self?.schedulePendingRuntimeAuthDrain()
        }
    }

    var isActive: Bool {
        appServer != nil
    }

    var acceptsNewReviewOperations: Bool {
        isActive
            && runtimeSession?.hasCurrentAccountObservation == true
            && accountRuntimeTransitionCoordinator.acceptsNewOperations
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

    func beginRuntimeRestart() -> CodexReviewRuntimeRestartAdmission? {
        guard loginSession == nil,
              pendingRuntimeRestart == nil,
              let start = accountRuntimeTransitionCoordinator.prepareForExplicitRuntimeStart() else {
            return nil
        }
        let admission = CodexReviewRuntimeRestartAdmission()
        pendingRuntimeRestart = (admission, start)
        return admission
    }

    func resumeRuntimeRestart(
        store: CodexReviewStore,
        admission: CodexReviewRuntimeRestartAdmission
    ) async {
        guard let pendingRuntimeRestart,
              pendingRuntimeRestart.admission == admission else {
            return
        }
        self.pendingRuntimeRestart = nil
        await start(
            store: store,
            forceRestartIfNeeded: true,
            explicitStart: pendingRuntimeRestart.start
        )
    }

    func claimRuntimeRestart(_ admission: CodexReviewRuntimeRestartAdmission) -> Bool {
        guard let pendingRuntimeRestart,
              pendingRuntimeRestart.admission == admission else {
            return false
        }
        guard accountRuntimeTransitionCoordinator.shouldStageExplicitRuntimeStart(
            pendingRuntimeRestart.start
        ) else {
            self.pendingRuntimeRestart = nil
            accountRuntimeTransitionCoordinator.finishExplicitRuntimeStart(
                pendingRuntimeRestart.start,
                didCommitActiveRuntime: false
            )
            return false
        }
        return true
    }

    func start(store: CodexReviewStore, forceRestartIfNeeded: Bool) async {
        guard loginSession == nil,
              pendingRuntimeRestart == nil else {
            logger.info("Rejecting a Host runtime start while authentication owns the active runtime")
            if let session = runtimeSession, session.isActive {
                store.transitionToRunning(serverURL: await session.activeMCPHTTPServer?.url)
            } else {
                store.transitionToFailed("Authentication is already in progress.")
            }
            return
        }
        guard let explicitStart = accountRuntimeTransitionCoordinator.prepareForExplicitRuntimeStart() else {
            if accountRuntimeTransitionCoordinator.isFinalShutdownRequested == false,
               let session = runtimeSession,
               session.isActive {
                store.transitionToRunning(serverURL: await session.activeMCPHTTPServer?.url)
            } else {
                store.transitionToFailed("The previous final shutdown has not completed.")
            }
            return
        }
        await start(
            store: store,
            forceRestartIfNeeded: forceRestartIfNeeded,
            explicitStart: explicitStart
        )
    }

    private func start(
        store: CodexReviewStore,
        forceRestartIfNeeded: Bool,
        explicitStart: AccountRuntimeTransitionCoordinator.ExplicitRuntimeStart
    ) async {
        let didStart = await startRuntime(
            store: store,
            forceRestartIfNeeded: forceRestartIfNeeded,
            expectedAccount: nil,
            mode: .published(owner: .explicit(explicitStart)),
            registryAuthorization: nil,
            accountSnapshotForPublication: nil
        )
        let didCommitActiveRuntime = didStart && runtimeSession?.isActive == true
        if didStart == false {
            do {
                if try await accountRegistry.reconciliationDebtExpectation() != nil {
                    _ = accountRuntimeTransitionCoordinator.commitExplicitRuntimeStartFailure(explicitStart)
                }
            } catch {
                let failure = (error as? CodexReviewAuthenticationFailure)
                    ?? .persistenceInconsistent(message: error.localizedDescription)
                if accountRuntimeTransitionCoordinator.commitExplicitRuntimeStartFailure(explicitStart) {
                    store.auth.updatePhase(.failed(failure))
                    store.transitionToFailed(failure.localizedDescription)
                }
            }
        }
        accountRuntimeTransitionCoordinator.finishExplicitRuntimeStart(
            explicitStart,
            didCommitActiveRuntime: didCommitActiveRuntime
        )
    }

    private func startRuntime(
        store: CodexReviewStore,
        forceRestartIfNeeded: Bool,
        expectedAccount: ExpectedRuntimeAccount?,
        mode: RuntimeStartMode,
        registryAuthorization: AccountRegistryStore.MutationLease?,
        accountSnapshotForPublication: AccountRegistryStore.Snapshot?
    ) async -> Bool {
        logger.info("Starting review runtime; forceRestartIfNeeded=\(forceRestartIfNeeded, privacy: .public)")
        if let registryLoadFailure {
            if shouldPublishRuntimeState(mode: mode) {
                store.auth.updatePhase(.failed(registryLoadFailure))
                store.transitionToFailed(registryLoadFailure.localizedDescription)
            }
            return false
        }
        if let session = runtimeSession,
           session.isActive,
           forceRestartIfNeeded == false,
           mode.explicitStart.map({
               accountRuntimeTransitionCoordinator.explicitRuntimeStartRequiresRepair($0)
           }) != true {
            guard claimRuntimePublicationCommit(mode: mode) else {
                return false
            }
            logger.info("Review runtime already has an app-server backend")
            if shouldPublishRuntimeState(mode: mode) {
                store.transitionToRunning(serverURL: await mcpHTTPServer?.url)
            }
            return true
        }
        if let session = runtimeSession {
            if case .stopIncomplete = session.phase {
                if shouldPublishRuntimeState(mode: mode) {
                    store.transitionToFailed(
                        "Review thread retention recovery is quarantined; the previous runtime cannot be replaced."
                    )
                }
                return false
            }
            await stop(store: store, purpose: .runtimeRestartPreservingRuns)
            guard runtimeSession == nil else {
                if shouldPublishRuntimeState(mode: mode) {
                    store.transitionToFailed("The previous review runtime did not finish stopping.")
                }
                return false
            }
        }
        if mode.explicitStart != nil,
           shouldStageRuntimePublication(mode: mode) == false {
            logger.info("Skipping a superseded runtime start before creating replacement resources")
            return false
        }

        precondition(nextRuntimeGeneration < .max, "Host runtime generations must not wrap.")
        let session = HostRuntimeSession(
            generation: nextRuntimeGeneration,
            lifecycleHandler: appServerLifecycleHandler,
            finalRetirementDidClaim: finalRuntimeRetirementDidClaim
        )
        nextRuntimeGeneration += 1
        runtimeSession = session
        var clearedDebtExpectation: ExpectedRuntimeAccount?
        do {
            let persistedDebtExpectation = try await accountRegistry.reconciliationDebtExpectation()
            let validationExpectation = expectedAccount ?? persistedDebtExpectation
            let runtime = try await appServerRuntimeFactory(codexHomeURL)
            guard runtimeSession === session else {
                await appServerCloser(runtime.appServer)
                return false
            }
            do {
                try session.requireHealthyStaging()
            } catch {
                await appServerCloser(runtime.appServer)
                return false
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
            switch await store.recoverOrphanedReviewThreads() {
            case .recovered, .cleanupIncomplete:
                break
            case .journalUnavailable(let message):
                throw ReviewBackendFailure.retentionJournal(message: message)
            }
            try requireCurrentStagingSession(session)
            if shouldStageRuntimePublication(mode: mode),
               let mcpHTTPServerFactory {
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
            var pendingDebtExpectation = persistedDebtExpectation
            while true {
                let authResolution = try await reconcileStagingRuntimeAuthentication(
                    session: session,
                    backend: backend,
                    validationExpectation: validationExpectation,
                    registryAuthorization: registryAuthorization,
                    accountSnapshotForPublication: accountSnapshotForPublication
                )
                if let debtExpectation = pendingDebtExpectation {
                    clearedDebtExpectation = debtExpectation
                    try await accountRegistry.clearReconciliationDebt()
                    await reconciliationDebtDidClear?(appServer)
                    try requireCurrentStagingSession(session)
                    pendingDebtExpectation = nil
                }
                try requireCurrentStagingSession(session)
                guard session.accountInvalidationRevision == authResolution.revision else {
                    continue
                }
                guard mode.requestsPublication else {
                    session.recordAccountObservation(
                        authResolution.observation,
                        revision: authResolution.revision
                    )
                    logger.info("Review runtime staged for final account-transition cleanup")
                    return true
                }
                guard shouldStageRuntimePublication(mode: mode) else {
                    session.recordAccountObservation(
                        authResolution.observation,
                        revision: authResolution.revision
                    )
                    logger.info("Review runtime publication was superseded after debt reconciliation")
                    if mode.explicitStart != nil {
                        await discardStagingRuntime(session, store: store)
                        return false
                    }
                    return true
                }
                await accountRegistry.openRuntimeAdmission(generation: session.generation)
                do {
                    try requireCurrentStagingSession(session)
                } catch {
                    await accountRegistry.closeRuntimeAdmission(generation: session.generation)
                    throw error
                }
                guard session.accountInvalidationRevision == authResolution.revision else {
                    await accountRegistry.closeRuntimeAdmission(generation: session.generation)
                    continue
                }
                session.recordAccountObservation(
                    authResolution.observation,
                    revision: authResolution.revision
                )
                guard claimRuntimePublicationCommit(mode: mode) else {
                    await accountRegistry.closeRuntimeAdmission(generation: session.generation)
                    logger.info("Review runtime publication was superseded at its commit point")
                    if mode.explicitStart != nil {
                        await discardStagingRuntime(session, store: store)
                        return false
                    }
                    return true
                }
                session.commit()
                if shouldPublishRuntimeState(mode: mode),
                   let reconciledAccountSnapshot = authResolution.persisted {
                    applyAccountRegistrySnapshot(reconciledAccountSnapshot, to: store.auth)
                    store.auth.updatePhase(.signedOut)
                }
                store.transitionToRunning(serverURL: serverURL)
                await session.mcpHTTPServer?.activate()
                guard runtimeSession === session, session.isActive else {
                    return false
                }
                await refreshSelectedAccountRateLimits(auth: store.auth)
                logger.info("Review runtime started")
                return true
            }
        } catch {
            if let clearedDebtExpectation {
                do {
                    try await accountRegistry.recordReconciliationDebt(
                        expectedAccount: clearedDebtExpectation,
                        message: "Runtime validation failed after reconciliation debt was cleared: \(error.localizedDescription)"
                    )
                } catch {
                    preconditionFailure(
                        "A failed debt-repair runtime must durably restore reconciliation debt: \(error.localizedDescription)"
                    )
                }
            }
            let ownsStagingFailure = runtimeSession === session && session.isStaging
            guard ownsStagingFailure else {
                _ = await session.waitForStopCompletion()
                logger.debug("Ignoring a late startup result from a stopped or superseded Host runtime generation")
                return false
            }
            let failureMessage = await runtimeStartupFailureMessage(for: error)
            guard runtimeSession === session, session.isStaging else {
                _ = await session.waitForStopCompletion()
                logger.debug("Ignoring a late startup failure from a stopped Host runtime generation")
                return false
            }
            logger.error("Review runtime failed to start: \(failureMessage, privacy: .public)")
            let stopTask = session.requestStop(purpose: .runtimeRestartPreservingRuns) { session in
                await self.accountRegistry.closeRuntimeAdmission(generation: session.generation)
                return await self.performRuntimeStop(
                    session: session,
                    store: store,
                    reviewCleanupMode: .connected,
                    reviewCancellation: .system(message: "Review runtime staging failed."),
                    loginTerminationReason: .runtimeFailure(.runtime(message: failureMessage))
                )
            }
            if let stopTask, await stopTask.value.didReleaseResources == false {
                return false
            }
            if runtimeSession === session {
                runtimeSession = nil
                if shouldPublishRuntimeState(mode: mode) {
                    store.transitionToFailed(failureMessage)
                }
            }
            return false
        }
    }

    private func requireCurrentStagingSession(_ session: HostRuntimeSession) throws {
        guard runtimeSession === session else {
            throw HostRuntimeConsumerFailure(message: "The Host runtime staging generation was superseded.")
        }
        try session.requireHealthyStaging()
    }

    private func reconcileStagingRuntimeAuthentication(
        session: HostRuntimeSession,
        backend: AppServerCodexReviewBackend,
        validationExpectation: ExpectedRuntimeAccount?,
        registryAuthorization: AccountRegistryStore.MutationLease?,
        accountSnapshotForPublication: AccountRegistryStore.Snapshot?
    ) async throws -> (
        revision: UInt64,
        observation: RuntimeAccountObservation,
        persisted: AccountRegistryStore.Snapshot?
    ) {
        while true {
            try requireCurrentStagingSession(session)
            let revision = session.accountInvalidationRevision
            let authSnapshot = try await backend.readAuth()
            try requireCurrentStagingSession(session)
            guard session.accountInvalidationRevision == revision else {
                continue
            }
            let observation = runtimeAccountObservation(from: authSnapshot)
            if let validationExpectation {
                try validateRuntimeAccount(authSnapshot, expected: validationExpectation)
            }
            let persisted: AccountRegistryStore.Snapshot?
            if let accountSnapshotForPublication {
                persisted = accountSnapshotForPublication
            } else if shouldReconcileRuntimeAuthSnapshot(
                expectation: validationExpectation,
                observation: observation
            ) {
                persisted = try await reconcileAuthSnapshotSerialized(
                    authSnapshot,
                    authorization: registryAuthorization
                ).persisted
            } else {
                persisted = try await accountRegistry.load()
            }
            try requireCurrentStagingSession(session)
            guard session.accountInvalidationRevision == revision else {
                continue
            }
            return (revision, observation, persisted)
        }
    }

    private func discardStagingRuntime(
        _ session: HostRuntimeSession,
        store: CodexReviewStore
    ) async {
        guard runtimeSession === session, session.isStaging else {
            return
        }
        let stopTask = session.requestStop(purpose: .runtimeRestartPreservingRuns) { session in
            await self.accountRegistry.closeRuntimeAdmission(generation: session.generation)
            return await self.performRuntimeStop(
                session: session,
                store: store,
                reviewCleanupMode: .connected,
                reviewCancellation: .system(message: "Review runtime publication was superseded."),
                loginTerminationReason: .storeStop
            )
        }
        let didReleaseResources = if let stopTask {
            await stopTask.value.didReleaseResources
        } else {
            session.phase == .stopped
        }
        if didReleaseResources, runtimeSession === session {
            runtimeSession = nil
        }
    }

    private func shouldStageRuntimePublication(mode: RuntimeStartMode) -> Bool {
        guard case .published(let owner) = mode else {
            return false
        }
        switch owner {
        case .explicit(let explicitStart):
            return accountRuntimeTransitionCoordinator.shouldStageExplicitRuntimeStart(explicitStart)
        case .account(let transition):
            return accountRuntimeTransitionCoordinator.shouldStageRuntimePublication(transition)
        case .primary(let reservation):
            return accountRuntimeTransitionCoordinator.shouldStageRuntimePublication(reservation)
        }
    }

    private func claimRuntimePublicationCommit(mode: RuntimeStartMode) -> Bool {
        guard case .published(let owner) = mode else {
            return false
        }
        switch owner {
        case .explicit(let explicitStart):
            return accountRuntimeTransitionCoordinator.claimExplicitRuntimeStartCommit(explicitStart)
        case .account(let transition):
            return accountRuntimeTransitionCoordinator.claimRuntimePublication(transition)
        case .primary(let reservation):
            return accountRuntimeTransitionCoordinator.claimRuntimePublication(reservation)
        }
    }

    private func shouldPublishRuntimeState(mode: RuntimeStartMode) -> Bool {
        mode.requestsPublication && shouldStageRuntimePublication(mode: mode)
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
        if purpose.retiresRuns {
            _ = await accountRuntimeTransitionCoordinator.performFinalShutdown { [weak self, weak store] in
                guard let self, let store else {
                    return true
                }
                await self.stopRuntime(store: store, purpose: purpose)
                return self.runtimeSession == nil
            }
            return
        }
        await stopRuntime(store: store, purpose: purpose)
    }

    private func stopRuntime(
        store: CodexReviewStore,
        purpose: CodexReviewRuntimeStopPurpose
    ) async {
        let session = runtimeSession
        let loginSession = self.loginSession
        guard let session else {
            _ = await loginSession?.terminate(reason: .storeStop)
            if purpose.retiresRuns,
               store.reviewRuns.isEmpty == false,
               await startRuntime(
                    store: store,
                    forceRestartIfNeeded: true,
                    expectedAccount: nil,
                    mode: .quiescentReconciliation,
                    registryAuthorization: nil,
                    accountSnapshotForPublication: nil
               ) {
                await stopRuntime(store: store, purpose: purpose)
                return
            }
            if purpose.retiresRuns {
                _ = await store.retireReviewRunsForFinalStoreStop()
            }
            return
        }
        logger.info("Stopping review runtime")
        session.closeAdmission()
        let task = session.requestStop(purpose: purpose) { session in
            await self.accountRegistry.closeRuntimeAdmission(generation: session.generation)
            return await self.performRuntimeStop(
                session: session,
                store: store,
                reviewCleanupMode: .connected,
                reviewCancellation: .system(message: "Review runtime stopped."),
                loginTerminationReason: .storeStop
            )
        }
        if let task {
            await installRuntimeStopFollowup(
                stopTask: task,
                session: session,
                store: store
            ).value
            await session.waitForFinalRetirementClaim()
        } else if let runtimeStopFollowup = runtimeStopFollowups[session.generation] {
            await runtimeStopFollowup.value
            await session.waitForFinalRetirementClaim()
        }
    }

    private func installRuntimeStopFollowup(
        stopTask: Task<HostRuntimeStopResult, Never>,
        session: HostRuntimeSession,
        store: CodexReviewStore
    ) -> Task<Void, Never> {
        if let runtimeStopFollowup = runtimeStopFollowups[session.generation] {
            return runtimeStopFollowup
        }
        let generation = session.generation
        let followupTask = Task { @MainActor [weak self, weak store] in
            let result = await stopTask.value
            await session.waitForFinalRetirementClaim()
            guard let self else {
                return
            }
            defer { self.runtimeStopFollowups.removeValue(forKey: generation) }
            guard let store else {
                return
            }
            if result.didReleaseResources, self.runtimeSession === session {
                self.runtimeSession = nil
            }
            let handoff = result.didReleaseResources
                ? session.takePrimaryAuthenticationHandoff(from: result)
                : nil
            guard result.didReleaseResources else {
                return
            }
            await self.consumePrimaryAuthenticationHandoff(
                handoff,
                stoppedSession: session,
                store: store
            )
            if handoff == nil,
               result.didRetireRuns == false,
               self.accountRuntimeTransitionCoordinator.isFinalShutdownRequested,
               await self.startRuntime(
                    store: store,
                    forceRestartIfNeeded: true,
                    expectedAccount: nil,
                    mode: .quiescentReconciliation,
                    registryAuthorization: nil,
                    accountSnapshotForPublication: nil
               ) {
                await self.stopRuntime(
                    store: store,
                    purpose: .finalStoreShutdownRetiringRuns
                )
            }
        }
        runtimeStopFollowups[generation] = followupTask
        return followupTask
    }

    private func consumePrimaryAuthenticationHandoff(
        _ handoff: PrimaryAuthenticationReconciliationHandoff?,
        stoppedSession: HostRuntimeSession,
        store: CodexReviewStore
    ) async {
        guard let handoff else {
            return
        }
        if loginSession?.generationID == handoff.loginGenerationID {
            loginSession = nil
        }
        precondition(
            runtimeSession !== stoppedSession,
            "A primary authentication handoff can start replacement work only after the old runtime is detached."
        )
        await accountRuntimeTransitionCoordinator.performStoppedPrimaryReconciliation {
            [weak self, weak store] reservation in
            guard let self, let store else {
                return
            }
            await self.performPrimaryAuthenticationReconciliation(
                handoff,
                reservation: reservation,
                auth: store.auth,
                oldRuntimeAlreadyStopped: true
            )
        }
        if accountRuntimeTransitionCoordinator.isFinalShutdownRequested,
           runtimeSession != nil {
            await stopRuntime(
                store: store,
                purpose: .finalStoreShutdownRetiringRuns
            )
        }
    }

    private func performRuntimeStop(
        session: HostRuntimeSession,
        store: CodexReviewStore,
        reviewCleanupMode: RuntimeReviewCleanupMode,
        reviewCancellation: ReviewCancellation,
        loginTerminationReason: LoginTerminationReason
    ) async -> HostRuntimeStopResult {
        let runtime = session.runtime
        await session.mcpHTTPServer?.stop()
        var didRetainPreparedRestarts = true
        if let appServerBackend = runtime?.backend {
            let retainedAttemptsByRunID = await appServerBackend.discardAllPreparedReviewRestarts(
                ownedAttemptsByRunID: store.runtimeStopReviewAttemptOwners()
            )
            didRetainPreparedRestarts = await store.retainPreparedRestartAttemptsForRuntimeStop(
                retainedAttemptsByRunID
            )
            await cleanupActiveReviewsForRuntimeTeardown(
                store: store,
                appServerBackend: appServerBackend,
                reason: reviewCancellation,
                mode: reviewCleanupMode
            )
        }
        let stoppingLoginSession = loginSession
        await stoppingLoginSession?.recordCancellationIntent()
        if let stoppingLoginSession,
           let lease = stoppingLoginSession.mutationLeaseForCancellation() {
            await accountRegistry.requestAuthenticationCancellation(lease)
        }
        let loginTerminal = await stoppingLoginSession?.terminate(reason: loginTerminationReason)
        let primaryAuthenticationHandoff = loginTerminal.flatMap { terminal in
            stoppingLoginSession?.takePrimaryAuthenticationHandoffForRuntimeStop(from: terminal)
        }
        if let primaryAuthenticationHandoff {
            installActivePrimaryAuthenticationReconciliation(primaryAuthenticationHandoff)
            if let stoppingLoginSession {
                clearLoginSessionIfCurrent(stoppingLoginSession)
            }
        }
        session.retainPrimaryAuthenticationHandoffForStop(primaryAuthenticationHandoff)
        guard didRetainPreparedRestarts else {
            logger.error("Review runtime remains open because prepared-restart cleanup ownership could not be persisted")
            return .init(
                didReleaseResources: false,
                didRetireRuns: false,
                primaryAuthenticationHandoff: primaryAuthenticationHandoff
            )
        }
        var didRetireRuns = false
        if session.shouldRetireRuns
            || accountRuntimeTransitionCoordinator.isFinalShutdownRequested {
            guard await store.retireReviewRunsForFinalStoreStop() else {
                logger.error("Review runtime remains open because an unpersisted cleanup quarantine is unresolved")
                return .init(
                    didReleaseResources: false,
                    didRetireRuns: false,
                    primaryAuthenticationHandoff: primaryAuthenticationHandoff
                )
            }
            didRetireRuns = true
        }
        await session.cancelConsumersAndWait()
        if didRetireRuns == false,
           session.shouldRetireRuns
            || accountRuntimeTransitionCoordinator.isFinalShutdownRequested {
            guard await store.retireReviewRunsForFinalStoreStop() else {
                logger.error("Review runtime remains open because a late final shutdown upgrade could not retire its runs")
                return .init(
                    didReleaseResources: false,
                    didRetireRuns: false,
                    primaryAuthenticationHandoff: primaryAuthenticationHandoff
                )
            }
            didRetireRuns = true
        }
        if let appServer = runtime?.appServer {
            await appServerCloser(appServer)
        }
        logger.info("Review runtime stopped")
        return .init(
            didReleaseResources: true,
            didRetireRuns: didRetireRuns,
            primaryAuthenticationHandoff: primaryAuthenticationHandoff
        )
    }

    func waitUntilStopped() async {
        await accountRuntimeTransitionCoordinator.waitForFinalShutdownCompletionIfRequested()
        while true {
            if let task = runtimeSession?.stopTask {
                _ = await task.value
                continue
            }
            let followups = Array(runtimeStopFollowups.values)
            if followups.isEmpty == false {
                for task in followups {
                    await task.value
                }
                continue
            }
            if let pendingRuntimeAuthDrainTask {
                await pendingRuntimeAuthDrainTask.value
                continue
            }
            return
        }
    }

    func refreshSettings() async throws -> CodexReviewSettings.Snapshot {
        let admitted = try requireAdmittedRuntimeBackend()
        let refreshed = try await Self.monitorSettings(from: admitted.backend.readSettings())
        try requireRuntimeCommitAdmission(generation: admitted.generation)
        settingsSnapshot = refreshed
        return settingsSnapshot
    }

    func updateSettingsModel(
        _ model: String?,
        reasoningEffort: CodexReviewSettings.ReasoningEffort?,
        persistReasoningEffort: Bool,
        serviceTier: CodexReviewSettings.ServiceTier?,
        persistServiceTier: Bool
    ) async throws {
        let admitted = try requireAdmittedRuntimeBackend()
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
        let updated = try await Self.monitorSettings(from: admitted.backend.applySettings(change))
        try requireRuntimeCommitAdmission(generation: admitted.generation)
        settingsSnapshot = updated
    }

    func updateSettingsReasoningEffort(
        _ reasoningEffort: CodexReviewSettings.ReasoningEffort?
    ) async throws {
        let admitted = try requireAdmittedRuntimeBackend()
        let updated = try await Self.monitorSettings(
            from: admitted.backend.applySettings(.init(
                reasoningEffort: reasoningEffort?.rawValue,
                updatesReasoningEffort: true
            ))
        )
        try requireRuntimeCommitAdmission(generation: admitted.generation)
        settingsSnapshot = updated
    }

    func updateSettingsServiceTier(
        _ serviceTier: CodexReviewSettings.ServiceTier?
    ) async throws {
        let admitted = try requireAdmittedRuntimeBackend()
        let updated = try await Self.monitorSettings(
            from: admitted.backend.applySettings(.init(
                serviceTier: serviceTier?.rawValue,
                updatesServiceTier: true
            ))
        )
        try requireRuntimeCommitAdmission(generation: admitted.generation)
        settingsSnapshot = updated
    }

    func refreshAuth(auth: CodexReviewAuthModel) async {
        guard loginSession == nil, acceptsNewReviewOperations else {
            logger.debug("Dropping an authentication refresh while runtime admission is closed")
            return
        }
        guard let session = runtimeSession,
              let appServerBackend = session.activeRuntime?.backend else {
            auth.updatePhase(.signedOut)
            return
        }
        guard let reservation = accountRuntimeTransitionCoordinator.reserveRuntimeAuthReconciliation(
            generation: session.generation
        ) else {
            logger.debug("Dropping an authentication refresh while runtime admission is closed")
            return
        }
        _ = await performRuntimeAuthReconciliation(
            reservation: reservation,
            generation: session.generation,
            backend: appServerBackend,
            auth: auth,
            cause: .manualRefresh
        )
    }

    func signIn(auth: CodexReviewAuthModel) async throws {
        try await beginStockLogin(auth: auth, request: .signIn)
    }

    func addAccount(auth: CodexReviewAuthModel) async throws {
        try await beginStockLogin(auth: auth, request: .addAccount)
    }

    func cancelAuthentication(auth _: CodexReviewAuthModel) async {
        guard let session = loginSession else {
            if let activePrimaryAuthenticationReconciliation {
                _ = await activePrimaryAuthenticationReconciliation.finalResult.wait()
            }
            return
        }
        await session.recordCancellationIntent()
        if let lease = session.mutationLeaseForCancellation() {
            await accountRegistry.requestAuthenticationCancellation(lease)
        }
        let terminal = await session.terminate(reason: .explicitCancellation)
        if case .primaryRuntimeReconciliation = terminal {
            _ = await session.waitForPrimaryAuthenticationFinalResult()
        }
    }

    func switchAccount(auth: CodexReviewAuthModel, accountKey: String) async throws {
        try await attachedStore?.requireReviewThreadRetentionAcceptance()
        try await withAccountMutation { transition, mutation in
        let before = mutation.before
        guard let attachedStore, appServerBackend != nil else {
            let prepared = try await accountRegistry.prepareAccountActivation(accountKey)
            guard case .apply = accountRuntimeTransitionCoordinator.claimEffect(transition) else {
                _ = try await accountRegistry.abortPreparedMutation(prepared)
                throw CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
            }
            mutation.expectRecovery(.account(accountKey))
            let persisted = try await commitPreparedAccountMutation(
                prepared,
                expectedAccount: .account(accountKey),
                transition: transition
            )
            accountRuntimeTransitionCoordinator.recordRegistryCommit(transition)
            if case .published = accountRuntimeTransitionCoordinator.claimPublication(transition) {
                applyAccountRegistrySnapshot(persisted, to: auth)
                auth.updatePhase(.signedOut)
            }
            return
        }
        await quiesceRuntimeAdmissionForAccountTransition()
        await attachedStore.closeActiveReviewSessions(
            reason: .system(message: "Account switched.")
        )
        let prepared: AccountRegistryStore.PreparedMutation
        do {
            prepared = try await accountRegistry.prepareAccountActivation(accountKey)
        } catch {
            try await recoverQuiescedPreEffectRuntime(
                before: before,
                store: attachedStore,
                transition: transition,
                originalError: error
            )
        }
        guard case .apply = accountRuntimeTransitionCoordinator.claimEffect(transition) else {
            _ = try await accountRegistry.abortPreparedMutation(prepared)
            try await recoverQuiescedPreEffectRuntime(
                before: before,
                store: attachedStore,
                transition: transition,
                originalError: CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
            )
        }
        await stop(store: attachedStore, purpose: .accountTransitionPreservingRuns)
        mutation.expectRecovery(.account(accountKey))
        let persisted = try await commitPreparedAccountMutation(
            prepared,
            expectedAccount: .account(accountKey),
            transition: transition
        )
        try await finishCommittedAccountTransition(
            expectedAccount: .account(accountKey),
            persisted: persisted,
            transition: transition,
            auth: auth,
            store: attachedStore
        )
        }
    }

    func removeAccount(auth: CodexReviewAuthModel, accountKey: String) async throws {
        try await attachedStore?.requireReviewThreadRetentionAcceptance()
        try await withAccountMutation { transition, mutation in
        let before = mutation.before
        let normalizedAccountKey = CodexReviewAccount.normalizedEmail(accountKey)
        guard before.accounts.contains(where: { $0.accountKey == normalizedAccountKey }) else {
            return
        }
        let removedActiveAccount = before.activeAccountKey == normalizedAccountKey
        let transitionBackend = removedActiveAccount ? teardownAppServerBackend : nil
        let transitionStore = removedActiveAccount
            ? attachedStore.flatMap { transitionBackend == nil ? nil : $0 }
            : nil
        let persisted: AccountRegistryStore.Snapshot
        if removedActiveAccount {
            if let transitionStore {
                await quiesceRuntimeAdmissionForAccountTransition()
                await transitionStore.closeActiveReviewSessions(
                    reason: .system(message: "Account removed.")
                )
            }
            let prepared: AccountRegistryStore.PreparedMutation
            do {
                prepared = try await accountRegistry.prepareIrreversibleRemoval(
                    accountKey: normalizedAccountKey
                )
            } catch {
                if let transitionStore {
                    try await recoverQuiescedPreEffectRuntime(
                        before: before,
                        store: transitionStore,
                        transition: transition,
                        originalError: error
                    )
                }
                throw error
            }
            guard case .apply = accountRuntimeTransitionCoordinator.claimEffect(transition) else {
                _ = try await accountRegistry.abortPreparedMutation(prepared)
                if let transitionStore {
                    try await recoverQuiescedPreEffectRuntime(
                        before: before,
                        store: transitionStore,
                        transition: transition,
                        originalError: CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
                    )
                }
                throw CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
            }
            var forwardRecoveredSnapshot: AccountRegistryStore.Snapshot?
            do {
                if let transitionBackend {
                    _ = try await transitionBackend.logout(.init(normalizedAccountKey))
                }
            } catch {
                let originalError = error
                mutation.expectRecovery(.reconcileCurrentRuntime)
                let disposition = try await abortPreparedMutationBeforeEffect(
                    prepared,
                    after: originalError
                )
                switch disposition {
                case .restoredBefore:
                    mutation.expectBeforeRecovery()
                    accountRuntimeTransitionCoordinator.recordEffectAborted(transition)
                    if let transitionStore {
                        try await recoverQuiescedPreEffectRuntime(
                            before: before,
                            store: transitionStore,
                            transition: transition,
                            originalError: originalError
                        )
                    }
                    throw originalError
                case .forwardedDesired(let snapshot):
                    mutation.expectRecovery(.signedOut)
                    forwardRecoveredSnapshot = snapshot
                }
            }
            mutation.expectRecovery(.signedOut)
            accountRuntimeTransitionCoordinator.recordEffectApplied(transition)
            if let transitionStore {
                await stop(
                    store: transitionStore,
                    purpose: .accountTransitionPreservingRuns
                )
            }
            if let forwardRecoveredSnapshot {
                persisted = forwardRecoveredSnapshot
            } else {
                persisted = try await commitPreparedAccountMutation(
                    prepared,
                    expectedAccount: .signedOut,
                    transition: transition
                )
            }
        } else {
            guard case .apply = accountRuntimeTransitionCoordinator.claimEffect(transition) else {
                throw CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
            }
            persisted = try await accountRegistry.removeInactiveAccount(
                accountKey: normalizedAccountKey
            )
        }
        await accountRegistry.cleanupRemovedAccountDirectory(accountKey: normalizedAccountKey)
        if removedActiveAccount {
            guard let transitionStore else {
                accountRuntimeTransitionCoordinator.recordRegistryCommit(transition)
                if case .published = accountRuntimeTransitionCoordinator.claimPublication(transition) {
                    applyAccountRegistrySnapshot(persisted, to: auth)
                    auth.updatePhase(.signedOut)
                }
                return
            }
            try await finishCommittedAccountTransition(
                expectedAccount: .signedOut,
                persisted: persisted,
                transition: transition,
                auth: auth,
                store: transitionStore
            )
        } else {
            accountRuntimeTransitionCoordinator.recordRegistryCommit(transition)
            if case .published = accountRuntimeTransitionCoordinator.claimPublication(transition) {
                applyAccountRegistrySnapshot(persisted, to: auth)
            }
        }
        }
    }

    func reorderPersistedAccount(
        auth: CodexReviewAuthModel,
        accountKey: String,
        toIndex: Int
    ) async throws {
        try await withAccountMutation { transition, _ in
        guard case .apply = accountRuntimeTransitionCoordinator.claimEffect(transition) else {
            throw CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
        }
        let persisted = try await accountRegistry.reorderAccount(
            accountKey: accountKey,
            toIndex: toIndex
        )
        accountRuntimeTransitionCoordinator.recordRegistryCommit(transition)
        if case .published = accountRuntimeTransitionCoordinator.claimPublication(transition) {
            applyAccountRegistrySnapshot(persisted, to: auth)
        }
        }
    }

    func signOutActiveAccount(auth: CodexReviewAuthModel) async throws {
        try await attachedStore?.requireReviewThreadRetentionAcceptance()
        try await withAccountMutation { transition, mutation in
        let before = mutation.before
        guard let accountKey = before.activeAccountKey else {
            return
        }
        let transitionBackend = teardownAppServerBackend
        let shouldRecycleRuntime = attachedStore != nil && transitionBackend != nil
        if shouldRecycleRuntime, let attachedStore {
            await quiesceRuntimeAdmissionForAccountTransition()
            await attachedStore.closeActiveReviewSessions(
                reason: .system(message: "Signed out.")
            )
        }
        let prepared: AccountRegistryStore.PreparedMutation
        do {
            prepared = try await accountRegistry.prepareIrreversibleRemoval(
                accountKey: accountKey
            )
        } catch {
            if shouldRecycleRuntime, let attachedStore {
                try await recoverQuiescedPreEffectRuntime(
                    before: before,
                    store: attachedStore,
                    transition: transition,
                    originalError: error
                )
            }
            throw error
        }
        guard case .apply = accountRuntimeTransitionCoordinator.claimEffect(transition) else {
            _ = try await accountRegistry.abortPreparedMutation(prepared)
            if shouldRecycleRuntime, let attachedStore {
                try await recoverQuiescedPreEffectRuntime(
                    before: before,
                    store: attachedStore,
                    transition: transition,
                    originalError: CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
                )
            }
            throw CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
        }
        var forwardRecoveredSnapshot: AccountRegistryStore.Snapshot?
        do {
            if let transitionBackend {
                _ = try await transitionBackend.logout(.init(accountKey))
            }
        } catch {
            let originalError = error
            mutation.expectRecovery(.reconcileCurrentRuntime)
            let disposition = try await abortPreparedMutationBeforeEffect(
                prepared,
                after: originalError
            )
            switch disposition {
            case .restoredBefore:
                mutation.expectBeforeRecovery()
                accountRuntimeTransitionCoordinator.recordEffectAborted(transition)
                if shouldRecycleRuntime, let attachedStore {
                    try await recoverQuiescedPreEffectRuntime(
                        before: before,
                        store: attachedStore,
                        transition: transition,
                        originalError: originalError
                    )
                }
                throw originalError
            case .forwardedDesired(let snapshot):
                mutation.expectRecovery(.signedOut)
                forwardRecoveredSnapshot = snapshot
            }
        }
        mutation.expectRecovery(.signedOut)
        accountRuntimeTransitionCoordinator.recordEffectApplied(transition)
        if shouldRecycleRuntime, let attachedStore {
            await stop(
                store: attachedStore,
                purpose: .accountTransitionPreservingRuns
            )
        }
        let persisted: AccountRegistryStore.Snapshot
        if let forwardRecoveredSnapshot {
            persisted = forwardRecoveredSnapshot
        } else {
            persisted = try await commitPreparedAccountMutation(
                prepared,
                expectedAccount: .signedOut,
                transition: transition
            )
        }
        await accountRegistry.cleanupRemovedAccountDirectory(accountKey: accountKey)
        if shouldRecycleRuntime, let attachedStore {
            try await finishCommittedAccountTransition(
                expectedAccount: .signedOut,
                persisted: persisted,
                transition: transition,
                auth: auth,
                store: attachedStore
            )
        } else {
            accountRuntimeTransitionCoordinator.recordRegistryCommit(transition)
            if case .published = accountRuntimeTransitionCoordinator.claimPublication(transition) {
                applyAccountRegistrySnapshot(persisted, to: auth)
                auth.updatePhase(.signedOut)
            }
        }
        }
    }

    func refreshAccountRateLimits(auth: CodexReviewAuthModel, accountKey: String) async {
        guard acceptsNewReviewOperations else {
            return
        }
        guard let account = auth.accounts.first(where: { $0.accountKey == accountKey }) else {
            return
        }
        await refreshRateLimits(for: account, auth: auth)
    }

    func requiresCurrentSessionRecovery(auth _: CodexReviewAuthModel, accountKey _: String) -> Bool {
        false
    }

    private func withAccountMutation<T>(
        _ operation: (
            AccountRuntimeTransitionCoordinator.AccountTransition,
            AccountMutationContext
        ) async throws -> T
    ) async throws -> T {
        guard runtimeSession == nil
                || runtimeSession?.hasCurrentAccountObservation == true else {
            throw CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
        }
        return try await accountRuntimeTransitionCoordinator.perform { transition in
            let admittedRuntimeGeneration = runtimeSession?.generation
            let admittedRuntimeInvalidationRevision = runtimeSession?.accountInvalidationRevision
            let mutation = AccountMutationContext(
                try await accountRegistry.beginAccountMutation(),
                admittedRuntimeGeneration: admittedRuntimeGeneration,
                admittedRuntimeInvalidationRevision: admittedRuntimeInvalidationRevision
            )
            do {
                let result = try await operation(transition, mutation)
                await accountRegistry.finishMutation(mutation.lease)
                return result
            } catch {
                if let failure = error as? CodexReviewAuthenticationFailure,
                   case .persistenceInconsistent = failure {
                    await recordUnconfirmedDirectRegistryMutation(
                        failure,
                        expectedAccount: mutation.expectationForUnconfirmedMutation(
                            currentRuntimeSession: runtimeSession
                        ),
                        transition: transition
                    )
                }
                await accountRegistry.finishMutation(mutation.lease)
                throw error
            }
        }
    }

    private func recordUnconfirmedDirectRegistryMutation(
        _ failure: CodexReviewAuthenticationFailure,
        expectedAccount: ExpectedRuntimeAccount,
        transition: AccountRuntimeTransitionCoordinator.AccountTransition
    ) async {
        let message = "The account registry mutation has an unresolved durable outcome: "
            + failure.localizedDescription
        do {
            try await accountRegistry.recordReconciliationDebt(
                expectedAccount: expectedAccount,
                message: message
            )
        } catch {
            preconditionFailure(
                "An unresolved account registry mutation must durably record reconciliation debt: \(error.localizedDescription)"
            )
        }
        if accountRuntimeTransitionCoordinator.commitAccountReconciliationFailure(transition) {
            attachedStore?.transitionToFailed(message)
            attachedStore?.auth.updatePhase(.failed(.accountCommit(message: message)))
        }
    }

    private func finishCommittedAccountTransition(
        expectedAccount: ExpectedRuntimeAccount,
        persisted: AccountRegistryStore.Snapshot,
        transition: AccountRuntimeTransitionCoordinator.AccountTransition,
        auth: CodexReviewAuthModel,
        store: CodexReviewStore
    ) async throws {
        accountRuntimeTransitionCoordinator.recordRegistryCommit(transition)
        let publication = accountRuntimeTransitionCoordinator.claimPublication(transition)
        let didStart = await startRuntime(
            store: store,
            forceRestartIfNeeded: true,
            expectedAccount: expectedAccount,
            mode: publication == .published
                ? .published(owner: .account(transition))
                : .quiescentReconciliation,
            registryAuthorization: nil,
            accountSnapshotForPublication: publication == .published ? persisted : nil
        )
        guard didStart else {
            let message = "The committed account transition could not start and validate its replacement runtime."
            do {
                try await accountRegistry.recordReconciliationDebt(
                    expectedAccount: expectedAccount,
                    message: message
                )
            } catch {
                preconditionFailure(
                    "A committed account transition must durably record reconciliation debt: \(error.localizedDescription)"
                )
            }
            if accountRuntimeTransitionCoordinator.commitAccountReconciliationFailure(transition) {
                store.transitionToFailed(message)
            }
            throw CodexReviewAuthenticationFailure.accountCommit(message: message)
        }
    }

    private func commitPreparedAccountMutation(
        _ mutation: AccountRegistryStore.PreparedMutation,
        expectedAccount: ExpectedRuntimeAccount,
        transition: AccountRuntimeTransitionCoordinator.AccountTransition
    ) async throws -> AccountRegistryStore.Snapshot {
        do {
            return try await accountRegistry.commitPreparedMutation(mutation)
        } catch {
            let message = "The account mutation effect was accepted, but its durable desired state could not be confirmed: "
                + error.localizedDescription
            do {
                try await accountRegistry.recordReconciliationDebt(
                    expectedAccount: expectedAccount,
                    message: message
                )
            } catch {
                preconditionFailure(
                    "An unconfirmed account mutation must durably record reconciliation debt: \(error.localizedDescription)"
                )
            }
            if accountRuntimeTransitionCoordinator.commitAccountReconciliationFailure(transition) {
                attachedStore?.transitionToFailed(message)
            }
            throw CodexReviewAuthenticationFailure.accountCommit(message: message)
        }
    }

    private func recoverQuiescedPreEffectRuntime(
        before: AccountRegistryStore.Snapshot,
        store: CodexReviewStore,
        transition: AccountRuntimeTransitionCoordinator.AccountTransition,
        originalError: any Error
    ) async throws -> Never {
        await stop(store: store, purpose: .accountTransitionPreservingRuns)
        let expectation = before.expectedRuntimeAccount
        let publication = accountRuntimeTransitionCoordinator.claimPreEffectRecovery(transition)
        let didStart = await startRuntime(
            store: store,
            forceRestartIfNeeded: true,
            expectedAccount: expectation,
            mode: publication == .published
                ? .published(owner: .account(transition))
                : .quiescentReconciliation,
            registryAuthorization: nil,
            accountSnapshotForPublication: publication == .published ? before : nil
        )
        guard didStart else {
            let message = "The account transition failed before its external effect, and the previous runtime could not be restored: "
                + originalError.localizedDescription
            do {
                try await accountRegistry.recordReconciliationDebt(
                    expectedAccount: expectation,
                    message: message
                )
            } catch {
                preconditionFailure(
                    "A failed pre-effect runtime recovery must durably record reconciliation debt: \(error.localizedDescription)"
                )
            }
            if accountRuntimeTransitionCoordinator.commitAccountReconciliationFailure(transition) {
                store.transitionToFailed(message)
            }
            throw CodexReviewAuthenticationFailure.accountCommit(message: message)
        }
        throw originalError
    }

    private func abortPreparedMutationBeforeEffect(
        _ mutation: AccountRegistryStore.PreparedMutation,
        after originalError: any Error
    ) async throws -> AccountRegistryStore.PreparedAbortDisposition {
        do {
            return try await accountRegistry.abortPreparedMutation(mutation)
        } catch let failure as CodexReviewAuthenticationFailure {
            if case .persistenceInconsistent = failure {
                throw failure
            }
            throw CodexReviewAuthenticationFailure.accountCommit(
                message: "Account mutation failed and its durable journal could not be reconciled. "
                    + "Original failure: \(originalError.localizedDescription). "
                    + "Recovery failure: \(failure.localizedDescription)"
            )
        } catch {
            throw CodexReviewAuthenticationFailure.accountCommit(
                message: "Account mutation failed and its durable journal could not be reconciled. "
                    + "Original failure: \(originalError.localizedDescription). "
                    + "Recovery failure: \(error.localizedDescription)"
            )
        }
    }

    private func beginStockLogin(
        auth: CodexReviewAuthModel,
        request: LoginRequest
    ) async throws {
        guard loginSession == nil else {
            throw CodexReviewAuthenticationFailure.alreadyInProgress
        }
        guard accountRuntimeTransitionCoordinator.hasActiveLoginTransition == false else {
            throw CodexReviewAuthenticationFailure.alreadyInProgress
        }
        try requireOperationAdmission()
        let loginAdmission = try accountRuntimeTransitionCoordinator.reserveLoginAdmission()
        let authenticationMutation: AccountRegistryStore.AuthenticationMutation
        do {
            try await attachedStore?.requireReviewThreadRetentionAcceptance()
            guard accountRuntimeTransitionCoordinator.canCommitLoginAdmission(loginAdmission) else {
                throw CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
            }
            authenticationMutation = try await accountRegistry.beginAuthenticationMutation(
                request: request
            )
        } catch {
            accountRuntimeTransitionCoordinator.finishLoginAdmission(loginAdmission)
            throw error
        }
        let mutationLease = authenticationMutation.lease
        guard accountRuntimeTransitionCoordinator.canCommitLoginAdmission(loginAdmission),
              loginSession == nil else {
            await accountRegistry.finishMutation(mutationLease)
            accountRuntimeTransitionCoordinator.finishLoginAdmission(loginAdmission)
            throw CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
        }
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
            previousActiveAccountKey: authenticationMutation.previousActiveAccountKey,
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
                    let failureDisposition = await operationState.claimPreCommitFailure()
                    if case .cancel = failureDisposition {
                        await startCompletion.resolve(.success(()))
                        return finish(.outcome(.cancelled))
                    } else {
                        await startCompletion.resolve(.failure(failure))
                        return finish(.failure(failure))
                    }
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
                    let failureDisposition = await operationState.claimPreCommitFailure()
                    if case .cancel = failureDisposition {
                        await startCompletion.resolve(.success(()))
                        return finish(.outcome(.cancelled))
                    } else {
                        await startCompletion.resolve(.failure(failure))
                        return finish(.failure(failure))
                    }
                }

                let handleDisposition = await operationState.bind(
                    handle: handle,
                    runtime: runtime
                )
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

                await self?.authenticationHandleDidBind?()
                if case .cancel = await operationState.claimURLPresentation(handle: handle) {
                    await startCompletion.resolve(.success(()))
                    do {
                        return finish(.outcome(try await handle.result()))
                    } catch is CancellationError {
                        return finish(.waiterCancelled(message: nil))
                    } catch {
                        return finish(.waiterCancelled(message: error.localizedDescription))
                    }
                }

                auth?.updatePhase(.signingIn(.init(
                    title: "Sign in to Codex",
                    detail: "Continue signing in with your browser.",
                    browserURL: handle.authenticationURL.absoluteString,
                    userCode: nil
                )))

                do {
                    try urlOpener(handle.authenticationURL)
                    await startCompletion.resolve(.success(()))
                } catch {
                    let failure = CodexReviewAuthenticationFailure.urlOpen(handle.authenticationURL)
                    do {
                        switch try await handle.cancel(acknowledgementTimeout: .seconds(5)) {
                        case .succeeded,
                             .authenticationCommittedNeedsConnectionReconciliation:
                            await startCompletion.resolve(.success(()))
                            return finish(.outcome(try await handle.result()))
                        case .failed(let message):
                            let loginFailure = CodexReviewAuthenticationFailure.login(
                                message: message ?? "Authentication failed."
                            )
                            await startCompletion.resolve(.failure(loginFailure))
                            return finish(.outcome(.failed(message: message)))
                        case .cancelled:
                            await startCompletion.resolve(.failure(failure))
                            return finish(.failure(failure))
                        }
                    } catch {
                        await startCompletion.resolve(.failure(failure))
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
        if case .signIn = purpose {
            accountRuntimeTransitionCoordinator.retainPrimaryLoginAdmission(loginAdmission)
            primaryLoginAdmission = (generationID, loginAdmission)
        } else {
            accountRuntimeTransitionCoordinator.finishLoginAdmission(loginAdmission)
        }
        let startResult = await session.activate()
        if case .failure(let failure) = startResult {
            let terminal = await session.terminate(reason: .rootOutcome)
            if case .addAccountPreservingActive = purpose,
               case .failed(let terminalFailure) = terminal {
                throw terminalFailure
            }
            _ = failure
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
        if case .primaryRuntimeReconciliation(let handoff) = terminal {
            let requiresRuntimeStopHandoff: Bool = switch reason {
            case .runtimeFailure, .storeStop:
                true
            case .rootOutcome, .explicitCancellation, .urlOpenFailure:
                false
            }
            if requiresRuntimeStopHandoff {
                finishPrimaryLoginAdmissionIfCurrent(session)
                return terminal
            } else {
                guard let primaryAdmission = takePrimaryLoginAdmissionIfCurrent(session) else {
                    preconditionFailure("A direct primary reconciliation requires retained login ownership.")
                }
                let disposition = accountRuntimeTransitionCoordinator
                    .handoffPrimaryLoginToReconciliation(
                    primaryAdmission
                ) {
                    [weak self, weak auth] reservation in
                    guard let self, let auth else {
                        return
                    }
                    await self.performPrimaryAuthenticationReconciliation(
                        handoff,
                        reservation: reservation,
                        auth: auth,
                        oldRuntimeAlreadyStopped: false
                    )
                }
                switch disposition {
                case .handedOff:
                    session.claimPrimaryAuthenticationHandoffForDirectReconciliation(handoff)
                    installActivePrimaryAuthenticationReconciliation(handoff)
                    clearLoginSessionIfCurrent(session)
                case .deferUntilRuntimeStop:
                    accountRuntimeTransitionCoordinator.finishPrimaryLoginAdmission(
                        primaryAdmission
                    )
                    return terminal
                }
            }
        } else {
            await releaseLoginMutationIfNeeded(session)
            clearLoginSessionIfCurrent(session)
            finishPrimaryLoginAdmissionIfCurrent(session)
            await reconcilePendingRuntimeAuthInvalidation(auth: auth)
            if case .succeeded = terminal,
               case .signIn = session.purpose {
                await refreshSelectedAccountRateLimits(auth: auth)
            }
        }
        return terminal
    }

    private func reconcilePendingRuntimeAuthInvalidation(
        auth: CodexReviewAuthModel
    ) async {
        guard loginSession == nil,
              let store = attachedStore,
              let session = runtimeSession,
              session.isActive,
              session.hasCurrentAccountObservation == false,
              let backend = session.activeRuntime?.backend else {
            return
        }
        await refreshAuthAfterAccountNotification(
            generation: session.generation,
            backend: backend,
            store: store
        )
    }

    private func schedulePendingRuntimeAuthDrain() {
        precondition(
            pendingRuntimeAuthDrainRequestRevision < .max,
            "A pending runtime-auth drain request revision must not wrap."
        )
        pendingRuntimeAuthDrainRequestRevision += 1
        startPendingRuntimeAuthDrainIfNeeded()
    }

    private func startPendingRuntimeAuthDrainIfNeeded() {
        guard pendingRuntimeAuthDrainTask == nil else { return }
        let requestRevision = pendingRuntimeAuthDrainRequestRevision
        pendingRuntimeAuthDrainTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            if let auth = self.attachedStore?.auth {
                await self.reconcilePendingRuntimeAuthInvalidation(auth: auth)
            }
            self.pendingRuntimeAuthDrainTask = nil
            if self.pendingRuntimeAuthDrainRequestRevision != requestRevision {
                self.startPendingRuntimeAuthDrainIfNeeded()
            }
        }
    }

    private func finishPrimaryLoginAdmissionIfCurrent(_ session: LoginSession) {
        guard let admission = takePrimaryLoginAdmissionIfCurrent(session) else {
            return
        }
        accountRuntimeTransitionCoordinator.finishPrimaryLoginAdmission(
            admission
        )
    }

    private func takePrimaryLoginAdmissionIfCurrent(
        _ session: LoginSession
    ) -> AccountRuntimeTransitionCoordinator.LoginAdmission? {
        guard let primaryLoginAdmission,
              primaryLoginAdmission.generationID == session.generationID else {
            return nil
        }
        self.primaryLoginAdmission = nil
        return primaryLoginAdmission.admission
    }

    private func claimLoginResultPublication(
        for session: LoginSession,
        usesPrimaryRuntime: Bool
    ) -> Bool {
        guard usesPrimaryRuntime else {
            return accountRuntimeTransitionCoordinator.commitLoginResultPublication()
        }
        guard let primaryLoginAdmission,
              primaryLoginAdmission.generationID == session.generationID else {
            return false
        }
        return accountRuntimeTransitionCoordinator.claimPrimaryLoginResultPublication(
            primaryLoginAdmission.admission
        )
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
            if case .cancelOutcomeUnknown = reconciliationReason {
                guard case .signIn = session.purpose else {
                    return finishCancelledLoginOutcome(
                        reason: terminationReason,
                        auth: auth
                    )
                }
                return .primaryRuntimeReconciliation(
                    session.takePrimaryAuthenticationReconciliationHandoff(
                        cause: .cancelOutcomeUnknown(
                            previousActiveAccountKey: session.previousActiveAccountKey
                        )
                    )
                )
            }
            guard case .signIn = session.purpose else {
                let failure = CodexReviewAuthenticationFailure.protocolViolation(
                    message: "An isolated add-account login cannot hand off primary authentication reconciliation."
                )
                auth.updatePhase(.failed(failure))
                return .failed(failure)
            }
            return .primaryRuntimeReconciliation(
                session.takePrimaryAuthenticationReconciliationHandoff(
                    cause: .committed(reconciliationReason)
                )
            )
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
        var deferredPrimaryExpectation: ExpectedRuntimeAccount = .anyChatGPT
        var primaryObservationPublication: (
            session: HostRuntimeSession,
            observation: RuntimeAccountObservation,
            revision: UInt64
        )?
        do {
            let mutationLease = session.mutationLeaseForOwnedOperation()
            let reconciliation: (
                persisted: AccountRegistryStore.Snapshot,
                account: CodexReviewAccount?
            )
            if loginRuntime.usesPrimaryRuntime {
                while true {
                    guard let primaryRuntimeSession = runtimeSession,
                          primaryRuntimeSession.isActive else {
                        throw CodexReviewAuthenticationFailure.runtime(
                            message: "The primary login runtime stopped before authentication reconciliation."
                        )
                    }
                    let revision = primaryRuntimeSession.accountInvalidationRevision
                    let snapshot: CodexReviewBackendModel.Auth.Snapshot
                    do {
                        snapshot = try await loginRuntime.backend.readAuth()
                    } catch {
                        if runtimeSession !== primaryRuntimeSession
                            || primaryRuntimeSession.accountInvalidationRevision != revision {
                            deferredPrimaryExpectation = .reconcileCurrentRuntime
                        }
                        throw error
                    }
                    guard runtimeSession === primaryRuntimeSession,
                          primaryRuntimeSession.isActive else {
                        throw CodexReviewAuthenticationFailure.runtime(
                            message: "The primary login runtime stopped during authentication reconciliation."
                        )
                    }
                    if primaryRuntimeSession.accountInvalidationRevision != revision {
                        deferredPrimaryExpectation = .reconcileCurrentRuntime
                        continue
                    }
                    let account = try successfulLoginAccount(
                        from: snapshot,
                        previousActiveAccountKey: session.previousActiveAccountKey
                    )
                    deferredPrimaryExpectation = .observedAccount(
                        accountKey: account.accountKey,
                        provider: .chatGPT
                    )
                    let candidate: (
                        persisted: AccountRegistryStore.Snapshot,
                        account: CodexReviewAccount?
                    )
                    do {
                        candidate = try await reconcileAuthSnapshotSerialized(
                            snapshot,
                            activation: session.purpose.activation,
                            authSourceCodexHomeURL: loginRuntime.codexHomeURL,
                            authenticatedRateLimits: nil,
                            authorization: mutationLease
                        )
                    } catch {
                        if runtimeSession !== primaryRuntimeSession
                            || primaryRuntimeSession.accountInvalidationRevision != revision {
                            deferredPrimaryExpectation = .reconcileCurrentRuntime
                        }
                        throw error
                    }
                    guard runtimeSession === primaryRuntimeSession,
                          primaryRuntimeSession.isActive else {
                        throw CodexReviewAuthenticationFailure.runtime(
                            message: "The primary login runtime stopped after authentication reconciliation."
                        )
                    }
                    guard primaryRuntimeSession.accountInvalidationRevision == revision else {
                        deferredPrimaryExpectation = .reconcileCurrentRuntime
                        continue
                    }
                    primaryObservationPublication = (
                        primaryRuntimeSession,
                        .account(accountKey: account.accountKey, provider: .chatGPT),
                        revision
                    )
                    reconciliation = candidate
                    break
                }
            } else {
                let snapshot = try await loginRuntime.backend.readAuth()
                _ = try successfulLoginAccount(
                    from: snapshot,
                    previousActiveAccountKey: session.previousActiveAccountKey
                )
                let isolatedRateLimits = try? await loginRuntime.backend.readRateLimits()
                guard let runtime = await session.takeOwnedRuntimeForClose() else {
                    preconditionFailure("An isolated login runtime can be closed only once.")
                }
                await appServerCloser(runtime.appServer)
                stagingURLRequiringRemoval = runtime.codexHomeURL
                reconciliation = try await reconcileAuthSnapshotSerialized(
                    snapshot,
                    activation: session.purpose.activation,
                    authSourceCodexHomeURL: loginRuntime.codexHomeURL,
                    authenticatedRateLimits: isolatedRateLimits,
                    authorization: mutationLease,
                    isolatedProductCommitAuthorization: mutationLease
                )
            }
            if claimLoginResultPublication(
                for: session,
                usesPrimaryRuntime: loginRuntime.usesPrimaryRuntime
            ) {
                if let primaryObservationPublication {
                    primaryObservationPublication.session.updateAccountObservation(
                        primaryObservationPublication.observation,
                        revision: primaryObservationPublication.revision
                    )
                }
                applyAccountRegistrySnapshot(reconciliation.persisted, to: auth)
                auth.updatePhase(.signedOut)
            }
            if let stagingURLRequiringRemoval {
                await accountRegistry.finishTemporaryCodexHome(stagingURLRequiringRemoval)
            }
            return .succeeded
        } catch {
            if let stagingURLRequiringRemoval {
                await accountRegistry.finishTemporaryCodexHome(stagingURLRequiringRemoval)
            }
            if error is IsolatedLoginProductCommitCancelled {
                auth.updatePhase(.signedOut)
                return .cancelled
            }
            if let productCommitFailure = error as? IsolatedLoginProductCommitFailure {
                auth.updatePhase(.failed(productCommitFailure.failure))
                return .failed(productCommitFailure.failure)
            }
            if loginRuntime.usesPrimaryRuntime {
                return await finishPrimaryLoginWithDeferredRegistryReconciliation(
                    session: session,
                    expectedAccount: deferredPrimaryExpectation,
                    underlyingError: error,
                    auth: auth
                )
            }
            let failure = (error as? CodexReviewAuthenticationFailure)
                ?? CodexReviewAuthenticationFailure.login(message: error.localizedDescription)
            switch await session.claimPreCommitFailure() {
            case .cancel:
                auth.updatePhase(.signedOut)
                return .cancelled
            case .fail:
                auth.updatePhase(.failed(failure))
                return .failed(failure)
            }
        }
    }

    private func successfulLoginAccount(
        from snapshot: CodexReviewBackendModel.Auth.Snapshot,
        previousActiveAccountKey: String?
    ) throws -> CodexReviewAccount {
        guard let activeAccountID = snapshot.activeAccountID,
              let backendAccount = snapshot.accounts.first(where: { $0.id == activeAccountID }),
              let account = Self.monitorAccount(from: backendAccount),
              account.kind == .chatGPT,
              account.accountKey != previousActiveAccountKey else {
            throw CodexReviewAuthenticationFailure.protocolViolation(
                message: "A successful login must expose a new active ChatGPT account."
            )
        }
        return account
    }

    private func finishPrimaryLoginWithDeferredRegistryReconciliation(
        session: LoginSession,
        expectedAccount: ExpectedRuntimeAccount,
        underlyingError: any Error,
        auth: CodexReviewAuthModel
    ) async -> LoginSessionTerminal {
        let message = "Authentication succeeded, but account registry reconciliation remains pending: "
            + underlyingError.localizedDescription
        do {
            try await accountRegistry.recordReconciliationDebt(
                expectedAccount: expectedAccount,
                message: message
            )
        } catch {
            preconditionFailure(
                "Committed primary authentication must durably record reconciliation debt: \(error.localizedDescription)"
            )
        }
        if commitPrimaryLoginReconciliationFailure(for: session) {
            auth.updatePhase(.failed(.accountCommit(message: message)))
            attachedStore?.transitionToFailed(message)
        }
        logger.error("\(message, privacy: .public)")
        return .committedNeedsRuntimeReconciliation(message: message)
    }

    private func commitPrimaryLoginReconciliationFailure(
        for session: LoginSession
    ) -> Bool {
        guard let primaryLoginAdmission,
              primaryLoginAdmission.generationID == session.generationID else {
            return accountRuntimeTransitionCoordinator.commitUnownedReconciliationFailure()
        }
        return accountRuntimeTransitionCoordinator.commitPrimaryLoginReconciliationFailure(
            primaryLoginAdmission.admission
        )
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

    private func performPrimaryAuthenticationReconciliation(
        _ handoff: PrimaryAuthenticationReconciliationHandoff,
        reservation: AccountRuntimeTransitionCoordinator.PrimaryReconciliationReservation,
        auth: CodexReviewAuthModel,
        oldRuntimeAlreadyStopped: Bool
    ) async {
        let finalResult: PrimaryAuthenticationReconciliationResult
        let expectedAccount: ExpectedRuntimeAccount = switch handoff.cause {
        case .committed:
            .anyChatGPT
        case .cancelOutcomeUnknown(let previousActiveAccountKey):
            .cancelOutcomeUnknown(previousActiveAccountKey: previousActiveAccountKey)
        }
        do {
            guard let store = attachedStore else {
                throw CodexReviewAuthenticationFailure.runtime(
                    message: "Authentication committed, but the review store is unavailable for reconciliation."
                )
            }
            if oldRuntimeAlreadyStopped == false {
                await stop(store: store, purpose: .loginReconciliationPreservingRuns)
            }
            guard await startRuntime(
                store: store,
                forceRestartIfNeeded: true,
                expectedAccount: expectedAccount,
                mode: accountRuntimeTransitionCoordinator.primaryPublicationClaim(reservation) == .published
                    ? .published(owner: .primary(reservation))
                    : .quiescentReconciliation,
                registryAuthorization: handoff.mutationLease,
                accountSnapshotForPublication: nil
            ) else {
                throw CodexReviewAuthenticationFailure.runtime(
                    message: "Authentication committed, but the replacement runtime failed validation."
                )
            }
            guard let accountObservation = runtimeSession?.accountObservation else {
                throw CodexReviewAuthenticationFailure.runtime(
                    message: "Authentication reconciliation completed without a validated account observation."
                )
            }
            switch (handoff.cause, accountObservation) {
            case (.committed, .account(let accountKey, .chatGPT)):
                finalResult = .authenticated(accountKey: accountKey)
            case (.cancelOutcomeUnknown(let previousActiveAccountKey), .account(let accountKey, .chatGPT))
                where accountKey != previousActiveAccountKey:
                finalResult = .authenticated(accountKey: accountKey)
            case (.cancelOutcomeUnknown, .signedOut):
                finalResult = .cancelled
            case (.cancelOutcomeUnknown(let previousActiveAccountKey), .account(let accountKey, .chatGPT))
                where accountKey == previousActiveAccountKey:
                finalResult = .cancelled
            case (.committed, .signedOut),
                 (_, .invalid),
                 (_, .account(_, .apiKey)),
                 (_, .account(_, .amazonBedrock)),
                 (.cancelOutcomeUnknown, .account(_, .chatGPT)):
                throw CodexReviewAuthenticationFailure.protocolViolation(
                    message: "Authentication reconciliation produced an invalid account observation."
                )
            }
        } catch {
            let message = "Authentication was committed, but runtime reconciliation remains pending: \(error.localizedDescription)"
            do {
                try await accountRegistry.recordReconciliationDebt(
                    expectedAccount: expectedAccount,
                    message: message
                )
            } catch {
                preconditionFailure(
                    "Committed primary authentication must durably record reconciliation debt: \(error.localizedDescription)"
                )
            }
            if accountRuntimeTransitionCoordinator.commitPrimaryReconciliationFailure(reservation) {
                attachedStore?.transitionToFailed(message)
                auth.updatePhase(.failed(.accountCommit(message: message)))
            }
            logger.error(
                "Primary authentication reconciliation deferred after \(String(describing: handoff.cause), privacy: .public): \(message, privacy: .public)"
            )
            finalResult = .committedNeedsRuntimeReconciliation(message: message)
        }
        if accountRuntimeTransitionCoordinator.isFinalShutdownRequested {
            auth.updatePhase(.signedOut)
        }
        await accountRegistry.finishMutation(handoff.mutationLease)
        let didResolve = handoff.finalResult.resolve(finalResult)
        precondition(
            didResolve,
            "A primary authentication reconciliation resolver can complete only once."
        )
        clearActivePrimaryAuthenticationReconciliation(handoff)
    }

    private func installActivePrimaryAuthenticationReconciliation(
        _ handoff: PrimaryAuthenticationReconciliationHandoff
    ) {
        precondition(
            activePrimaryAuthenticationReconciliation == nil,
            "Only one primary authentication reconciliation can own the active final-result slot."
        )
        activePrimaryAuthenticationReconciliation = (
            loginGenerationID: handoff.loginGenerationID,
            finalResult: handoff.finalResult
        )
    }

    private func clearActivePrimaryAuthenticationReconciliation(
        _ handoff: PrimaryAuthenticationReconciliationHandoff
    ) {
        guard let activePrimaryAuthenticationReconciliation else {
            preconditionFailure("A primary authentication reconciliation must resolve its active final-result slot.")
        }
        precondition(
            activePrimaryAuthenticationReconciliation.loginGenerationID == handoff.loginGenerationID
                && activePrimaryAuthenticationReconciliation.finalResult === handoff.finalResult,
            "Only the active primary authentication reconciliation can clear its final-result slot."
        )
        self.activePrimaryAuthenticationReconciliation = nil
    }

    private func clearLoginSessionIfCurrent(_ session: LoginSession) {
        guard loginSession === session,
              loginSession?.generationID == session.generationID else {
            return
        }
        loginSession = nil
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
            let temporaryCodexHomeURL = try await accountRegistry.reserveTemporaryCodexHome(
                kind: .authentication
            )
            let runtime: AppServerRuntime
            do {
                runtime = try await appServerRuntimeFactory(temporaryCodexHomeURL)
            } catch {
                await accountRegistry.finishTemporaryCodexHome(temporaryCodexHomeURL)
                throw error
            }
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
        try requireOperationAdmission()
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
        try requireOperationAdmission()
        guard let appServerBackend else {
            throw CodexReviewAPI.Error.io("Review runtime is not running.")
        }
        return try await appServerBackend.prepareReviewRestart(attempt)
    }

    func restartPreparedReview(
        _ token: CodexReviewBackendModel.Review.RestartToken,
        request: CodexReviewBackendModel.Review.Start
    ) async throws -> BackendReviewAttempt {
        try requireOperationAdmission()
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

    private func reconcileAuthSnapshotSerialized(
        _ snapshot: CodexReviewBackendModel.Auth.Snapshot,
        activation: LoginActivation = .activateAuthenticatedAccount,
        authSourceCodexHomeURL: URL? = nil,
        authenticatedRateLimits: CodexRateLimits? = nil,
        authorization: AccountRegistryStore.MutationLease? = nil,
        runtimeAuthorization: AccountRegistryStore.RuntimeCommitAuthorization? = nil,
        isolatedProductCommitAuthorization: AccountRegistryStore.MutationLease? = nil
    ) async throws -> (
        persisted: AccountRegistryStore.Snapshot,
        account: CodexReviewAccount?
    ) {
        guard let activeAccountID = snapshot.activeAccountID?.rawValue.nilIfEmpty else {
            guard case .activateAuthenticatedAccount = activation else {
                throw CodexReviewAuthenticationFailure.protocolViolation(
                    message: "An isolated successful login did not expose its authenticated account."
                )
            }
            let persisted = try await accountRegistry.deactivateAccount(
                authorization: authorization,
                runtimeAuthorization: runtimeAuthorization
            )
            return (persisted, nil)
        }
        guard let backendAccount = snapshot.accounts.first(where: {
            $0.id.rawValue == activeAccountID
        }) else {
            throw CodexReviewAuthenticationFailure.protocolViolation(
                message: "The active runtime account identifier is missing from the account snapshot."
            )
        }
        guard let account = Self.monitorAccount(from: backendAccount) else {
            throw CodexReviewAuthenticationFailure.protocolViolation(
                message: "The active runtime account snapshot is invalid."
            )
        }
        if let authenticatedRateLimits {
            applyRateLimits(authenticatedRateLimits, to: account)
        }
        let accountPayload = savedAccountPayload(from: account)
        let persisted: AccountRegistryStore.Snapshot
        if accountPayload.kind == .chatGPT {
            persisted = try await accountRegistry.commitAuthenticatedAccount(
                accountPayload,
                activation: activation,
                authSourceCodexHomeURL: authSourceCodexHomeURL,
                authorization: authorization,
                runtimeAuthorization: runtimeAuthorization,
                isolatedProductCommitAuthorization: isolatedProductCommitAuthorization
            )
        } else {
            persisted = try await accountRegistry.upsertAccount(
                accountPayload,
                activation: activation,
                authorization: authorization,
                runtimeAuthorization: runtimeAuthorization
            )
        }
        return (persisted, account)
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
                await self.runtimeConsumerDidExit(
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
              session.generation == generation else {
            return
        }
        if case .accountUpdated = event {
            session.recordAccountInvalidation()
        }
        guard let backend = session.activeRuntime?.backend else {
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
    ) async {
        guard let session = runtimeSession,
              session.generation == generation else {
            return
        }
        switch session.phase {
        case .staging:
            session.recordStagingFailure(failure)
        case .active:
            guard session.isActive else {
                logger.debug("Ignoring a runtime consumer exit after its generation admission closed")
                return
            }
            let message = "Review runtime stopped unexpectedly: \(failure.message)"
            store.transitionToFailed(message)
            session.closeAdmission()
            let requestedStopTask = session.requestStop(purpose: .runtimeRestartPreservingRuns) { session in
                await self.accountRegistry.closeRuntimeAdmission(generation: generation)
                return await self.performRuntimeStop(
                    session: session,
                    store: store,
                    reviewCleanupMode: .connectionTerminated,
                    reviewCancellation: .system(message: message),
                    loginTerminationReason: .runtimeFailure(.runtime(message: message))
                )
            }
            guard let stopTask = requestedStopTask else {
                return
            }
            _ = installRuntimeStopFollowup(
                stopTask: stopTask,
                session: session,
                store: store
            )
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
            schedulePendingRuntimeAuthDrain()
        case .rateLimitsUpdated(let rateLimits):
            guard acceptsRuntimeEvent(generation: generation) else {
                return
            }
            await applyRateLimitsUpdatedNotification(
                rateLimits,
                generation: generation,
                auth: store.auth
            )
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
        guard let reservation = accountRuntimeTransitionCoordinator.reserveRuntimeAuthReconciliation(
            generation: generation
        ) else {
            return
        }
        let didReconcile = await performRuntimeAuthReconciliation(
            reservation: reservation,
            generation: generation,
            backend: backend,
            auth: store.auth,
            cause: .accountUpdated
        )
        if didReconcile {
            await refreshSelectedAccountRateLimits(auth: store.auth)
        }
    }

    private func performRuntimeAuthReconciliation(
        reservation: AccountRuntimeTransitionCoordinator.RuntimeAuthReconciliation,
        generation: UInt64,
        backend: AppServerCodexReviewBackend,
        auth: CodexReviewAuthModel,
        cause: RuntimeAuthReconciliationCause
    ) async -> Bool {
        defer {
            accountRuntimeTransitionCoordinator.finishRuntimeAuthReconciliation(reservation)
        }
        var requiresAuthoritativeRefresh = cause == .accountUpdated
        while true {
            guard let session = currentActiveRuntimeSession(generation: generation) else {
                return false
            }
            let readRevision = session.accountInvalidationRevision
            let snapshot: CodexReviewBackendModel.Auth.Snapshot
            do {
                snapshot = try await backend.readAuth()
            } catch {
                guard let currentSession = currentActiveRuntimeSession(generation: generation) else {
                    return false
                }
                if currentSession.accountInvalidationRevision != readRevision {
                    requiresAuthoritativeRefresh = true
                    continue
                }
                let failure = (error as? CodexReviewAuthenticationFailure)
                    ?? CodexReviewAuthenticationFailure.runtime(message: error.localizedDescription)
                if requiresAuthoritativeRefresh == false {
                    if accountRuntimeTransitionCoordinator.canPublishRuntimeAuthReadResult(reservation) {
                        auth.updatePhase(.failed(failure))
                    }
                } else {
                    if accountRuntimeTransitionCoordinator.commitRuntimeAuthReconciliationFailure(reservation) {
                        attachedStore?.transitionToFailed(failure.localizedDescription)
                        auth.updatePhase(.failed(failure))
                    }
                }
                return false
            }

            guard let currentSession = currentActiveRuntimeSession(generation: generation) else {
                return false
            }
            if currentSession.accountInvalidationRevision != readRevision {
                requiresAuthoritativeRefresh = true
                continue
            }
            let observation = runtimeAccountObservation(from: snapshot)
            guard let expectedAccount = observation.exactExpectation else {
                let failure = CodexReviewAuthenticationFailure.protocolViolation(
                    message: "The active runtime authentication snapshot has an invalid account reference."
                )
                if accountRuntimeTransitionCoordinator.commitRuntimeAuthReconciliationFailure(reservation) {
                    attachedStore?.transitionToFailed(failure.localizedDescription)
                    auth.updatePhase(.failed(failure))
                }
                return false
            }
            guard accountRuntimeTransitionCoordinator.claimRuntimeAuthRegistryEffect(reservation) else {
                return false
            }

            let reconciliation: (
                persisted: AccountRegistryStore.Snapshot,
                account: CodexReviewAccount?
            )
            do {
                reconciliation = try await reconcileAuthSnapshotSerialized(
                    snapshot,
                    runtimeAuthorization: runtimeCommitAuthorization(generation: generation)
                )
            } catch {
                let message = "Runtime authentication changed, but its account registry reconciliation remains pending: "
                    + error.localizedDescription
                let recoveryExpectation: ExpectedRuntimeAccount
                if let currentSession = currentActiveRuntimeSession(generation: generation),
                   currentSession.accountInvalidationRevision == readRevision {
                    recoveryExpectation = expectedAccount
                } else {
                    recoveryExpectation = .reconcileCurrentRuntime
                }
                do {
                    try await accountRegistry.recordReconciliationDebt(
                        expectedAccount: recoveryExpectation,
                        message: message
                    )
                } catch {
                    preconditionFailure(
                        "An unresolved runtime authentication change must durably record reconciliation debt: \(error.localizedDescription)"
                    )
                }
                if accountRuntimeTransitionCoordinator.commitRuntimeAuthReconciliationFailure(reservation) {
                    attachedStore?.transitionToFailed(message)
                    auth.updatePhase(.failed(.accountCommit(message: message)))
                }
                return false
            }

            guard let committedSession = currentActiveRuntimeSession(generation: generation) else {
                return false
            }
            guard committedSession.accountInvalidationRevision == readRevision else {
                requiresAuthoritativeRefresh = true
                guard accountRuntimeTransitionCoordinator
                    .continueRuntimeAuthReadingAfterRegistryCommit(reservation) else {
                    return false
                }
                continue
            }
            guard case .published = accountRuntimeTransitionCoordinator
                .claimRuntimeAuthReconciliationPublication(reservation) else {
                return false
            }
            committedSession.updateAccountObservation(
                observation,
                revision: readRevision
            )
            applyAccountRegistrySnapshot(reconciliation.persisted, to: auth)
            auth.updatePhase(.signedOut)
            return true
        }
    }

    private func currentActiveRuntimeSession(
        generation: UInt64
    ) -> HostRuntimeSession? {
        guard let session = runtimeSession,
              session.generation == generation,
              session.isActive else {
            return nil
        }
        return session
    }

    private func isCurrentActiveRuntimeGeneration(_ generation: UInt64) -> Bool {
        guard let session = runtimeSession,
              session.generation == generation else {
            return false
        }
        return session.isActive
    }

    private func acceptsRuntimeEvent(generation: UInt64) -> Bool {
        guard let session = runtimeSession,
              session.generation == generation else {
            return false
        }
        return session.isActive && accountRuntimeTransitionCoordinator.acceptsNewOperations
    }

    private func requireOperationAdmission() throws {
        guard acceptsNewReviewOperations else {
            throw CodexReviewAPI.Error.io("The review runtime is changing accounts or stopping.")
        }
    }

    private func requireAdmittedRuntimeBackend() throws -> (
        generation: UInt64,
        backend: AppServerCodexReviewBackend
    ) {
        try requireOperationAdmission()
        guard let session = runtimeSession,
              let backend = session.activeRuntime?.backend else {
            throw CodexReviewAPI.Error.io("Review runtime is not running.")
        }
        return (session.generation, backend)
    }

    private func requireRuntimeCommitAdmission(generation: UInt64) throws {
        guard acceptsRuntimeEvent(generation: generation) else {
            throw CodexReviewAPI.Error.io(
                "The runtime generation that accepted this operation is no longer active."
            )
        }
    }

    private func runtimeCommitAuthorization(
        generation: UInt64
    ) -> AccountRegistryStore.RuntimeCommitAuthorization {
        .init(generation: generation)
    }

    private func applyRateLimitsUpdatedNotification(
        _ rateLimits: CodexRateLimits,
        generation: UInt64,
        auth: CodexReviewAuthModel
    ) async {
        guard let selectedAccount = auth.selectedAccount else {
            return
        }
        guard selectedAccount.capabilities.supportsRateLimitRefresh else {
            return
        }
        guard let session = runtimeSession,
              session.generation == generation,
              session.authorizeRateLimitObservation(for: selectedAccount) != nil else {
            logger.debug("Dropping a sparse rate-limit notification without a matching runtime account observation")
            return
        }
        applyRateLimits(rateLimits, to: selectedAccount)
        _ = await persistRateLimitMetadata(
            for: selectedAccount,
            runtimeAuthorization: runtimeCommitAuthorization(generation: generation)
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
        await refreshActiveAccountRateLimits(for: account, auth: auth)
    }

    private func refreshActiveAccountRateLimits(
        for account: CodexReviewAccount,
        auth: CodexReviewAuthModel
    ) async {
        guard let admitted = try? requireAdmittedRuntimeBackend() else {
            return
        }
        guard let session = runtimeSession,
              session.generation == admitted.generation,
              let observationAuthorization = session.authorizeRateLimitObservation(
                  for: account
              ) else {
            logger.debug("Dropping a rate-limit refresh without an exact runtime account observation")
            return
        }
        let authorization = runtimeCommitAuthorization(generation: admitted.generation)
        do {
            let beforeAuth = try await admitted.backend.readAuth()
            try requireActiveRateLimitCommitAdmission(
                authorization: observationAuthorization,
                account: account,
                auth: auth
            )
            try requireRateLimitRuntimeIdentity(
                beforeAuth,
                authorization: observationAuthorization
            )
            let response = try await admitted.backend.readRateLimits()
            let afterAuth = try await admitted.backend.readAuth()
            try requireActiveRateLimitCommitAdmission(
                authorization: observationAuthorization,
                account: account,
                auth: auth
            )
            try requireRateLimitRuntimeIdentity(
                afterAuth,
                authorization: observationAuthorization
            )
            applyRateLimits(response, to: account)
            guard await persistRateLimitMetadata(
                for: account,
                runtimeAuthorization: authorization
            ) else {
                return
            }
            try requireActiveRateLimitCommitAdmission(
                authorization: observationAuthorization,
                account: account,
                auth: auth
            )
        } catch ActiveRateLimitRefreshFailure.staleAccountIdentity {
            logger.debug("Dropping a rate-limit refresh whose runtime account identity changed")
        } catch {
            guard (try? requireActiveRateLimitCommitAdmission(
                authorization: observationAuthorization,
                account: account,
                auth: auth
            )) != nil else {
                logger.debug("Dropping a completed rate-limit refresh from a retired runtime generation")
                return
            }
            recordRateLimitRefreshFailure(error, account: account)
            _ = await persistRateLimitMetadata(
                for: account,
                runtimeAuthorization: authorization
            )
        }
    }

    private func requireActiveRateLimitCommitAdmission(
        authorization: RuntimeAccountObservationAuthorization,
        account: CodexReviewAccount,
        auth: CodexReviewAuthModel
    ) throws {
        try requireRuntimeCommitAdmission(generation: authorization.generation)
        guard let session = runtimeSession,
              session.validatesRateLimitObservation(authorization) else {
            throw ActiveRateLimitRefreshFailure.staleAccountIdentity
        }
        guard auth.persistedActiveAccountKey == account.accountKey,
              auth.selectedAccount === account else {
            throw ActiveRateLimitRefreshFailure.staleAccountIdentity
        }
    }

    private func requireRateLimitRuntimeIdentity(
        _ snapshot: CodexReviewBackendModel.Auth.Snapshot,
        authorization: RuntimeAccountObservationAuthorization
    ) throws {
        guard runtimeAccountObservation(from: snapshot) == authorization.observation else {
            throw ActiveRateLimitRefreshFailure.staleAccountIdentity
        }
    }

    private func refreshSavedAccountRateLimits(for account: CodexReviewAccount) async {
        let temporaryCodexHomeURL: URL
        do {
            temporaryCodexHomeURL = try await accountRegistry.reserveTemporaryCodexHome(
                kind: .rateLimits
            )
        } catch {
            account.updateRateLimitFetchMetadata(fetchedAt: Date(), error: error.localizedDescription)
            _ = await persistRateLimitMetadata(for: account)
            return
        }
        var isolatedAppServer: CodexAppServer?
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
                await accountRegistry.finishTemporaryCodexHome(temporaryCodexHomeURL)
                return
            }
            let runtime = try await appServerRuntimeFactory(temporaryCodexHomeURL)
            isolatedAppServer = runtime.appServer
            let didRefresh = await refreshRateLimits(
                for: account,
                using: runtime.backend,
                validatesBackendAccount: true
            )
            if didRefresh {
                try await accountRegistry.saveSharedAuth(
                    from: temporaryCodexHomeURL,
                    for: savedAccountPayload(from: account)
                )
            }
            await closeIsolatedLoginRuntime(appServer: runtime.appServer, codexHomeURL: temporaryCodexHomeURL)
        } catch {
            await closeIsolatedLoginRuntime(
                appServer: isolatedAppServer,
                codexHomeURL: temporaryCodexHomeURL
            )
            account.updateRateLimitFetchMetadata(fetchedAt: Date(), error: error.localizedDescription)
            _ = await persistRateLimitMetadata(for: account)
        }
    }

    private func refreshRateLimits(
        for account: CodexReviewAccount,
        using backend: AppServerCodexReviewBackend?,
        validatesBackendAccount: Bool
    ) async -> Bool {
        do {
            guard let backend else {
                return false
            }
            if validatesBackendAccount {
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
            if let appServer {
                await appServerCloser(appServer)
            }
            return
        }
        guard codexHomeURL != self.codexHomeURL else {
            return
        }
        if let appServer {
            await appServerCloser(appServer)
        }
        await accountRegistry.finishTemporaryCodexHome(codexHomeURL)
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
        for account: CodexReviewAccount,
        runtimeAuthorization: AccountRegistryStore.RuntimeCommitAuthorization? = nil
    ) async throws {
        guard let sourceCodexHomeURL else {
            return
        }
        try await accountRegistry.saveSharedAuth(
            from: sourceCodexHomeURL,
            for: savedAccountPayload(from: account),
            runtimeAuthorization: runtimeAuthorization
        )
    }

    @discardableResult
    private func persistRateLimitMetadata(
        for account: CodexReviewAccount,
        runtimeAuthorization: AccountRegistryStore.RuntimeCommitAuthorization? = nil
    ) async -> Bool {
        do {
            try await accountRegistry.updateCachedRateLimits(
                from: savedAccountPayload(from: account),
                runtimeAuthorization: runtimeAuthorization
            )
            return true
        } catch {
            if let runtimeAuthorization,
               (try? requireRuntimeCommitAdmission(
                   generation: runtimeAuthorization.generation
               )) == nil {
                logger.debug("Dropping rate-limit persistence from a retired runtime generation")
                return false
            }
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

    private func validateRuntimeAccount(
        _ snapshot: CodexReviewBackendModel.Auth.Snapshot,
        expected: ExpectedRuntimeAccount
    ) throws {
        let activeAccount = snapshot.activeAccountID.flatMap { activeID in
            snapshot.accounts.first { $0.id == activeID }
        }
        switch expected {
        case .signedOut:
            guard activeAccount == nil else {
                throw CodexReviewAuthenticationFailure.protocolViolation(
                    message: "The replacement runtime remained authenticated after a signed-out account transition."
                )
            }
        case .account(let expectedAccountKey):
            guard let activeAccount,
                  activeAccount.kind == .chatGPT,
                  CodexReviewAccount.normalizedEmail(activeAccount.id.rawValue)
                    == CodexReviewAccount.normalizedEmail(expectedAccountKey) else {
                throw CodexReviewAuthenticationFailure.protocolViolation(
                    message: "The replacement runtime did not authenticate the expected account \(expectedAccountKey)."
                )
            }
        case .observedAccount(let expectedAccountKey, let provider):
            guard let activeAccount,
                  activeAccount.kind == provider.accountKind,
                  CodexReviewAccount.normalizedEmail(activeAccount.id.rawValue)
                    == CodexReviewAccount.normalizedEmail(expectedAccountKey) else {
                throw CodexReviewAuthenticationFailure.protocolViolation(
                    message: "The replacement runtime did not authenticate the observed account \(expectedAccountKey)."
                )
            }
        case .anyChatGPT:
            guard activeAccount?.kind == .chatGPT else {
                throw CodexReviewAuthenticationFailure.protocolViolation(
                    message: "The replacement runtime did not confirm the committed ChatGPT authentication."
                )
            }
        case .cancelOutcomeUnknown:
            guard snapshot.activeAccountID == nil || activeAccount?.kind == .chatGPT else {
                throw CodexReviewAuthenticationFailure.protocolViolation(
                    message: "An unknown login cancellation outcome resolved to an unsupported authentication provider."
                )
            }
        case .reconcileCurrentRuntime:
            break
        }
    }

    private func runtimeAccountObservation(
        from snapshot: CodexReviewBackendModel.Auth.Snapshot
    ) -> RuntimeAccountObservation {
        guard let activeAccountID = snapshot.activeAccountID else {
            return .signedOut
        }
        guard let backendAccount = snapshot.accounts.first(where: { $0.id == activeAccountID }),
              let account = Self.monitorAccount(from: backendAccount) else {
            return .invalid
        }
        return .account(
            accountKey: account.accountKey,
            provider: .init(account.kind)
        )
    }

    private func shouldReconcileRuntimeAuthSnapshot(
        expectation: ExpectedRuntimeAccount?,
        observation: RuntimeAccountObservation
    ) -> Bool {
        guard case .cancelOutcomeUnknown(let previousActiveAccountKey) = expectation else {
            return true
        }
        switch observation {
        case .signedOut:
            return previousActiveAccountKey != nil
        case .account:
            return true
        case .invalid:
            return true
        }
    }
}

private typealias AppServerRuntimeFactory = @MainActor @Sendable (URL) async throws -> AppServerRuntime
