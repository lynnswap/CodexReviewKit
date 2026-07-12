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

private struct HostRuntimeConsumerFailure: Error, LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}

private struct IsolatedLoginProductCommitCancelled: Error, Sendable {}

private struct IsolatedLoginProductCommitFailure: Error, LocalizedError, Sendable {
    let failure: CodexReviewAuthenticationFailure

    var errorDescription: String? {
        failure.localizedDescription
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
        if let appServerBackend = runtime?.backend {
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
        if let appServer = runtime?.appServer {
            let retainedRestartIdentities = await appServer.discardAllPreparedReviewRestarts()
            precondition(
                retainedRestartIdentities.values.allSatisfy(\.isEmpty),
                "Review workers must transfer every prepared-restart identity before runtime teardown."
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

@MainActor
private struct AppServerRuntime: Sendable {
    var appServer: CodexAppServer
    var modelContainer: CodexModelContainer
    var backend: AppServerCodexReviewBackend
}

private struct HostRuntimeStopResult: Sendable {
    var didReleaseResources: Bool
    var didRetireRuns: Bool
    var primaryAuthenticationHandoff: PrimaryAuthenticationReconciliationHandoff?
}

private enum RuntimeAccountObservation: Equatable, Sendable {
    case signedOut
    case account(
        accountKey: String,
        provider: ExpectedRuntimeAccount.Provider
    )
    case invalid

    var exactExpectation: ExpectedRuntimeAccount? {
        switch self {
        case .signedOut:
            .signedOut
        case .account(let accountKey, let provider):
            .observedAccount(accountKey: accountKey, provider: provider)
        case .invalid:
            nil
        }
    }
}

private struct RuntimeAccountObservationAuthorization: Equatable, Sendable {
    let generation: UInt64
    let revision: UInt64
    let observation: RuntimeAccountObservation
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
    private(set) var stopTask: Task<HostRuntimeStopResult, Never>?
    private(set) var shouldRetireRuns = false
    private(set) var accountObservation: RuntimeAccountObservation?
    private(set) var accountObservationRevision: UInt64?
    private(set) var accountInvalidationRevision: UInt64 = 0

    private let lifecycleHandler: CodexReviewAppServerLifecycleHandler?
    private let finalRetirementDidClaim: CodexReviewFinalRuntimeRetirementDidClaim?
    private var didPublishLifecycle = false
    private var admissionOpen = false
    private var stagingFailure: HostRuntimeConsumerFailure?
    private var didConsumePrimaryAuthenticationHandoff = false
    private var pendingPrimaryAuthenticationHandoff: PrimaryAuthenticationReconciliationHandoff?
    private var finalRetirementClaimTask: Task<Void, Never>?

    init(
        generation: UInt64,
        lifecycleHandler: CodexReviewAppServerLifecycleHandler?,
        finalRetirementDidClaim: CodexReviewFinalRuntimeRetirementDidClaim?
    ) {
        self.generation = generation
        self.lifecycleHandler = lifecycleHandler
        self.finalRetirementDidClaim = finalRetirementDidClaim
    }

    var activeRuntime: AppServerRuntime? {
        guard case .active = phase, admissionOpen else {
            return nil
        }
        return runtime
    }

    var activeMCPHTTPServer: (any CodexReviewMCPHTTPServing)? {
        guard case .active = phase, admissionOpen else {
            return nil
        }
        return mcpHTTPServer
    }

    var isActive: Bool {
        if case .active = phase, admissionOpen {
            return true
        }
        return false
    }

    var hasCurrentAccountObservation: Bool {
        isActive
            && accountObservation != nil
            && accountObservationRevision == accountInvalidationRevision
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

    func recordAccountObservation(
        _ observation: RuntimeAccountObservation,
        revision: UInt64
    ) {
        precondition(accountObservation == nil, "A Host runtime generation validates its account snapshot only once.")
        precondition(isStaging, "A runtime account observation belongs to staging validation.")
        precondition(
            revision == accountInvalidationRevision,
            "A staging runtime can publish only its latest account observation."
        )
        accountObservation = observation
        accountObservationRevision = revision
    }

    func updateAccountObservation(
        _ observation: RuntimeAccountObservation,
        revision: UInt64
    ) {
        precondition(isActive, "Only an active runtime can update its account observation.")
        precondition(
            revision == accountInvalidationRevision,
            "An active runtime can publish only its latest account observation."
        )
        accountObservation = observation
        accountObservationRevision = revision
    }

    func recordAccountInvalidation() {
        precondition(
            accountInvalidationRevision < .max,
            "A Host runtime account invalidation revision must not wrap."
        )
        accountInvalidationRevision += 1
    }

    func authorizeRateLimitObservation(
        for account: CodexReviewAccount
    ) -> RuntimeAccountObservationAuthorization? {
        guard isActive,
              let accountObservationRevision,
              accountObservationRevision == accountInvalidationRevision else {
            return nil
        }
        let expectedObservation = RuntimeAccountObservation.account(
            accountKey: account.accountKey,
            provider: .init(account.kind)
        )
        guard accountObservation == expectedObservation else {
            return nil
        }
        return .init(
            generation: generation,
            revision: accountObservationRevision,
            observation: expectedObservation
        )
    }

    func validatesRateLimitObservation(
        _ authorization: RuntimeAccountObservationAuthorization
    ) -> Bool {
        isActive
            && authorization.generation == generation
            && authorization.revision == accountInvalidationRevision
            && authorization.revision == accountObservationRevision
            && authorization.observation == accountObservation
    }

    func installConsumers(
        accountEvents: CodexAccountEvents,
        connectionEvents: CodexConnectionEvents,
        accountEventSink: @escaping @MainActor @Sendable (CodexAccountEvent) async -> Void,
        exitSink: @escaping @MainActor @Sendable (HostRuntimeConsumerFailure) async -> Void
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
                    await exitSink(.init(message: "The Codex account event stream ended unexpectedly."))
                }
            } catch is CancellationError {
            } catch {
                logger.error("Auth notification stream ended: \(error.localizedDescription, privacy: .public)")
                await exitSink(.init(message: error.localizedDescription))
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
                    await exitSink(.init(message: Self.failureMessage(for: termination)))
                    return
                }
            }
            if Task.isCancelled == false {
                await exitSink(.init(message: "The Codex connection event stream ended unexpectedly."))
            }
        }
    }

    func commit() {
        precondition(isStaging, "Only a staged Host runtime session can become active.")
        guard let modelContainer = runtime?.modelContainer else {
            preconditionFailure("A Host runtime session requires a model container before publication.")
        }
        phase = .active
        admissionOpen = true
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
        closeAdmission()
    }

    func closeAdmission() {
        admissionOpen = false
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

    func waitForStopCompletion() async -> HostRuntimeStopResult? {
        guard let stopTask else {
            return nil
        }
        return await stopTask.value
    }

    func waitForFinalRetirementClaim() async {
        await finalRetirementClaimTask?.value
    }

    func takePrimaryAuthenticationHandoff(
        from result: HostRuntimeStopResult
    ) -> PrimaryAuthenticationReconciliationHandoff? {
        guard didConsumePrimaryAuthenticationHandoff == false else {
            return nil
        }
        let handoff = pendingPrimaryAuthenticationHandoff ?? result.primaryAuthenticationHandoff
        guard let handoff else { return nil }
        didConsumePrimaryAuthenticationHandoff = true
        pendingPrimaryAuthenticationHandoff = nil
        return handoff
    }

    func retainPrimaryAuthenticationHandoffForStop(
        _ handoff: PrimaryAuthenticationReconciliationHandoff?
    ) {
        guard let handoff else { return }
        guard pendingPrimaryAuthenticationHandoff == nil else {
            preconditionFailure("A Host runtime session can retain only one primary authentication handoff.")
        }
        pendingPrimaryAuthenticationHandoff = handoff
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
            accountObservation = nil
            accountObservationRevision = nil
            phase = .stopped
        } else {
            phase = .stopIncomplete
        }
    }

    func requestStop(
        purpose: CodexReviewRuntimeStopPurpose,
        _ operation: @escaping @MainActor @Sendable (HostRuntimeSession) async -> HostRuntimeStopResult
    ) -> Task<HostRuntimeStopResult, Never>? {
        if purpose.retiresRuns, shouldRetireRuns == false {
            shouldRetireRuns = true
            let finalRetirementDidClaim = finalRetirementDidClaim
            finalRetirementClaimTask = Task { @MainActor in
                await finalRetirementDidClaim?()
            }
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
        let task: Task<HostRuntimeStopResult, Never> = Task { @MainActor [weak self] in
            guard let self else {
                return .init(
                    didReleaseResources: true,
                    didRetireRuns: false,
                    primaryAuthenticationHandoff: nil
                )
            }
            await self.finalRetirementClaimTask?.value
            let result = await operation(self)
            self.stopTask = nil
            self.finishStopping(didReleaseResources: result.didReleaseResources)
            return result
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

    struct AccountMutation: Sendable {
        let lease: MutationLease
        let before: Snapshot
    }

    struct PreparedMutation: Hashable, Sendable {
        fileprivate let id: UUID
    }

    enum PreparedAbortDisposition: Sendable {
        case restoredBefore(Snapshot)
        case forwardedDesired(Snapshot)
    }

    struct RuntimeCommitAuthorization: Sendable {
        fileprivate let generation: UInt64

        init(generation: UInt64) {
            self.generation = generation
        }
    }

    struct AuthenticationMutation: Sendable {
        let lease: MutationLease
        let purpose: LoginPurpose
        let previousActiveAccountKey: String?
    }

    enum TemporaryCodexHomeKind: Sendable {
        case authentication
        case rateLimits

        fileprivate var pathPrefix: String {
            switch self {
            case .authentication:
                "codex-review-auth-"
            case .rateLimits:
                "codex-review-rate-limits-"
            }
        }
    }

    private enum MutationKind: Equatable {
        case authentication
        case account
    }

    let codexHomeURL: URL
    private let authenticationMutationDidBegin: CodexReviewAuthenticationMutationDidBegin?
    private let authenticationCancellationDidRequest: CodexReviewAuthenticationCancellationDidRequest?
    private let authenticationProductCommitDidApply: CodexReviewAuthenticationProductCommitDidApply?
    private let registryDestinationDidReplace: CodexReviewRegistryDestinationDidReplace?
    private let directoryDurabilityDidSynchronize: (@Sendable (URL) throws -> Void)?
    private let loadDidBegin: CodexReviewAccountRegistryLoadDidBegin?
    private var activeMutation: (
        lease: MutationLease,
        kind: MutationKind,
        cancellationRequested: Bool,
        productCommitClaimed: Bool
    )?
    private var activeRuntimeGeneration: UInt64?

    init(
        codexHomeURL: URL,
        authenticationMutationDidBegin: CodexReviewAuthenticationMutationDidBegin? = nil,
        authenticationCancellationDidRequest: CodexReviewAuthenticationCancellationDidRequest? = nil,
        authenticationProductCommitDidApply: CodexReviewAuthenticationProductCommitDidApply? = nil,
        registryDestinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil,
        directoryDurabilityDidSynchronize: (@Sendable (URL) throws -> Void)? = nil,
        loadDidBegin: CodexReviewAccountRegistryLoadDidBegin? = nil
    ) {
        self.codexHomeURL = codexHomeURL
        self.authenticationMutationDidBegin = authenticationMutationDidBegin
        self.authenticationCancellationDidRequest = authenticationCancellationDidRequest
        self.authenticationProductCommitDidApply = authenticationProductCommitDidApply
        self.registryDestinationDidReplace = registryDestinationDidReplace
        self.directoryDurabilityDidSynchronize = directoryDurabilityDidSynchronize
        self.loadDidBegin = loadDidBegin
    }

    nonisolated static func loadInitialSnapshot(codexHomeURL: URL) throws -> Snapshot {
        try Disk.load(codexHomeURL: codexHomeURL)
    }

    func load() async throws -> Snapshot {
        await loadDidBegin?()
        return try Disk.load(codexHomeURL: codexHomeURL)
    }

    func openRuntimeAdmission(generation: UInt64) {
        guard activeRuntimeGeneration == nil || activeRuntimeGeneration == generation else {
            preconditionFailure("A new runtime generation cannot publish before the previous registry admission closes.")
        }
        activeRuntimeGeneration = generation
    }

    func closeRuntimeAdmission(generation: UInt64) {
        guard activeRuntimeGeneration == generation else {
            return
        }
        activeRuntimeGeneration = nil
    }

    func deactivateAccount(
        authorization: MutationLease?,
        runtimeAuthorization: RuntimeCommitAuthorization? = nil
    ) async throws -> Snapshot {
        try requireMutationAuthorization(authorization)
        try requireRuntimeAuthorization(runtimeAuthorization)
        try Disk.deactivateAccount(
            codexHomeURL: codexHomeURL,
            destinationDidReplace: registryDestinationDidReplace
        )
        return try Disk.loadSnapshotWithoutMaintenance(codexHomeURL: codexHomeURL)
    }

    func prepareAccountActivation(_ accountKey: String) throws -> PreparedMutation {
        try Disk.prepareAccountActivation(accountKey, codexHomeURL: codexHomeURL)
    }

    func updateCachedRateLimits(
        from account: CodexSavedAccountPayload,
        runtimeAuthorization: RuntimeCommitAuthorization? = nil
    ) async throws {
        try requireNoAccountMutationForBackgroundPersistence()
        try requireRuntimeAuthorization(runtimeAuthorization)
        try Disk.updateCachedRateLimits(
            from: account,
            codexHomeURL: codexHomeURL,
            destinationDidReplace: registryDestinationDidReplace
        )
    }

    func saveSharedAuth(
        from sourceCodexHomeURL: URL? = nil,
        for account: CodexSavedAccountPayload,
        runtimeAuthorization: RuntimeCommitAuthorization? = nil
    ) throws {
        try requireNoAccountMutationForBackgroundPersistence()
        try requireRuntimeAuthorization(runtimeAuthorization)
        try Disk.saveSharedAuth(
            from: sourceCodexHomeURL ?? codexHomeURL,
            for: account,
            codexHomeURL: codexHomeURL,
            destinationDidReplace: registryDestinationDidReplace
        )
    }

    func commitAuthenticatedAccount(
        _ authenticatedAccount: CodexSavedAccountPayload,
        activation: LoginActivation,
        authSourceCodexHomeURL: URL?,
        authorization: MutationLease?,
        runtimeAuthorization: RuntimeCommitAuthorization? = nil,
        isolatedProductCommitAuthorization: MutationLease? = nil
    ) async throws -> Snapshot {
        try requireMutationAuthorization(authorization)
        try requireRuntimeAuthorization(runtimeAuthorization)
        let didClaimIsolatedProductCommit: Bool
        if let isolatedProductCommitAuthorization,
           claimAuthenticationProductCommit(isolatedProductCommitAuthorization) == false {
            throw IsolatedLoginProductCommitCancelled()
        } else {
            didClaimIsolatedProductCommit = isolatedProductCommitAuthorization != nil
        }
        do {
            try Disk.commitAuthenticatedAccount(
                authenticatedAccount,
                activation: activation,
                authSourceCodexHomeURL: authSourceCodexHomeURL ?? codexHomeURL,
                codexHomeURL: codexHomeURL,
                destinationDidReplace: registryDestinationDidReplace
            )
            if didClaimIsolatedProductCommit {
                await authenticationProductCommitDidApply?()
            }
            return try Disk.loadSnapshotWithoutMaintenance(codexHomeURL: codexHomeURL)
        } catch {
            guard didClaimIsolatedProductCommit else {
                throw error
            }
            let failure = (error as? CodexReviewAuthenticationFailure)
                ?? CodexReviewAuthenticationFailure.accountCommit(message: error.localizedDescription)
            throw IsolatedLoginProductCommitFailure(failure: failure)
        }
    }

    func upsertAccount(
        _ account: CodexSavedAccountPayload,
        activation: LoginActivation,
        authorization: MutationLease?,
        runtimeAuthorization: RuntimeCommitAuthorization? = nil
    ) async throws -> Snapshot {
        try requireMutationAuthorization(authorization)
        try requireRuntimeAuthorization(runtimeAuthorization)
        try Disk.upsertAccount(
            account,
            activation: activation,
            codexHomeURL: codexHomeURL,
            destinationDidReplace: registryDestinationDidReplace
        )
        return try Disk.loadSnapshotWithoutMaintenance(codexHomeURL: codexHomeURL)
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
        return try Disk.loadSnapshotWithoutMaintenance(codexHomeURL: codexHomeURL)
    }

    func abortPreparedMutation(
        _ mutation: PreparedMutation
    ) throws -> PreparedAbortDisposition {
        try Disk.abortPreparedMutation(mutation, codexHomeURL: codexHomeURL)
    }

    func removeInactiveAccount(accountKey: String) throws -> Snapshot {
        try Disk.removeInactiveAccount(
            accountKey: accountKey,
            codexHomeURL: codexHomeURL,
            destinationDidReplace: registryDestinationDidReplace
        )
        return try Disk.loadSnapshotWithoutMaintenance(codexHomeURL: codexHomeURL)
    }

    func reorderAccount(accountKey: String, toIndex: Int) throws -> Snapshot {
        try Disk.reorderAccount(
            accountKey: accountKey,
            toIndex: toIndex,
            codexHomeURL: codexHomeURL,
            destinationDidReplace: registryDestinationDidReplace
        )
        return try Disk.loadSnapshotWithoutMaintenance(codexHomeURL: codexHomeURL)
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

    func recordReconciliationDebt(
        expectedAccount: ExpectedRuntimeAccount,
        message: String
    ) throws {
        try Disk.recordReconciliationDebt(
            expectedAccount: expectedAccount,
            message: message,
            codexHomeURL: codexHomeURL,
            directoryDurabilityDidSynchronize: directoryDurabilityDidSynchronize
        )
    }

    func reconciliationDebtExpectation() throws -> ExpectedRuntimeAccount? {
        try Disk.reconciliationDebtExpectation(codexHomeURL: codexHomeURL)
    }

    func clearReconciliationDebt() throws {
        try Disk.clearReconciliationDebt(codexHomeURL: codexHomeURL)
    }

    func reserveTemporaryCodexHome(kind: TemporaryCodexHomeKind) throws -> URL {
        try Disk.reserveTemporaryCodexHome(kind: kind, codexHomeURL: codexHomeURL)
    }

    func finishTemporaryCodexHome(_ url: URL) {
        do {
            try Disk.finishTemporaryCodexHome(
                url,
                codexHomeURL: codexHomeURL,
                directoryDurabilityDidSynchronize: directoryDurabilityDidSynchronize
            )
        } catch {
            preconditionFailure(
                "Credential-bearing temporary home cleanup debt must be durable: \(error.localizedDescription)"
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

    func beginAuthenticationMutation(request: LoginRequest) async throws -> AuthenticationMutation {
        if let activeMutation {
            switch activeMutation.kind {
            case .authentication:
                throw CodexReviewAuthenticationFailure.alreadyInProgress
            case .account:
                throw CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
            }
        }
        let snapshot = try Disk.loadSnapshotWithoutMaintenance(codexHomeURL: codexHomeURL)
        let purpose: LoginPurpose = switch request {
        case .signIn:
            .signIn
        case .addAccount:
            snapshot.activeAccountKey == nil ? .signIn : .addAccountPreservingActive
        }
        let mutation = AuthenticationMutation(
            lease: installMutation(kind: .authentication),
            purpose: purpose,
            previousActiveAccountKey: snapshot.activeAccountKey
        )
        await authenticationMutationDidBegin?()
        return mutation
    }

    func beginAccountMutation() async throws -> AccountMutation {
        guard activeMutation == nil else {
            throw CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
        }
        let lease = installMutation(kind: .account)
        await loadDidBegin?()
        do {
            let before = try Disk.loadSnapshotWithoutMaintenance(codexHomeURL: codexHomeURL)
            return .init(lease: lease, before: before)
        } catch {
            precondition(activeMutation?.lease == lease)
            activeMutation = nil
            throw error
        }
    }

    func finishMutation(_ lease: MutationLease) {
        precondition(activeMutation?.lease == lease, "Only the active account mutation owner can release its lease.")
        activeMutation = nil
    }

    func requestAuthenticationCancellation(_ lease: MutationLease) async {
        guard activeMutation?.lease == lease,
              activeMutation?.kind == .authentication else {
            return
        }
        if activeMutation?.productCommitClaimed == false {
            activeMutation?.cancellationRequested = true
        }
        await authenticationCancellationDidRequest?()
    }

    private func installMutation(kind: MutationKind) -> MutationLease {
        let lease = MutationLease(id: UUID())
        activeMutation = (
            lease: lease,
            kind: kind,
            cancellationRequested: false,
            productCommitClaimed: false
        )
        return lease
    }

    private func claimAuthenticationProductCommit(_ lease: MutationLease) -> Bool {
        guard activeMutation?.lease == lease,
              activeMutation?.kind == .authentication else {
            preconditionFailure("Only the active authentication lease can claim its product commit.")
        }
        guard activeMutation?.cancellationRequested == false else {
            return false
        }
        activeMutation?.productCommitClaimed = true
        return true
    }

    private func requireNoAccountMutationForBackgroundPersistence() throws {
        guard activeMutation == nil else {
            throw CodexReviewAuthenticationFailure.accountCommit(
                message: "Background account metadata persistence is blocked while an account mutation or authentication is in progress."
            )
        }
    }

    private func requireMutationAuthorization(
        _ authorization: MutationLease?
    ) throws {
        guard let activeMutation else {
            guard authorization == nil else {
                preconditionFailure("A released account mutation lease cannot authorize registry work.")
            }
            return
        }
        guard authorization == activeMutation.lease else {
            throw CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
        }
    }

    private func requireRuntimeAuthorization(
        _ authorization: RuntimeCommitAuthorization?
    ) throws {
        guard let authorization else {
            return
        }
        guard activeRuntimeGeneration == authorization.generation else {
            throw CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
        }
    }
}

private extension AccountRegistryStore.Snapshot {
    var expectedRuntimeAccount: ExpectedRuntimeAccount {
        guard let activeAccountKey else {
            return .signedOut
        }
        guard let account = accounts.first(where: {
            $0.accountKey == activeAccountKey
        }) else {
            preconditionFailure("An active account registry snapshot requires its account payload.")
        }
        return .observedAccount(
            accountKey: activeAccountKey,
            provider: .init(account.kind)
        )
    }
}

private typealias AppServerRuntimeFactory = @MainActor @Sendable (URL) async throws -> AppServerRuntime

private extension AccountRegistryStore {
enum Disk {
    private static let filesystemRootURL = URL(fileURLWithPath: "/", isDirectory: true)

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

    private struct ReconciliationDebt: Codable {
        enum Expectation: String, Codable {
            case signedOut
            case account
            case observedAccount
            case anyChatGPT
            case cancelOutcomeUnknown
            case reconcileCurrentRuntime
        }

        var expectation: Expectation
        var accountKey: String?
        var provider: ExpectedRuntimeAccount.Provider?
        var message: String
        var recordedAt: Date

        var expectedRuntimeAccount: ExpectedRuntimeAccount {
            switch expectation {
            case .signedOut:
                return .signedOut
            case .account:
                guard let accountKey else {
                    preconditionFailure("An account reconciliation debt requires its expected account key.")
                }
                return .account(accountKey)
            case .observedAccount:
                guard let accountKey, let provider else {
                    preconditionFailure("An observed account reconciliation debt requires identity and provider.")
                }
                return .observedAccount(accountKey: accountKey, provider: provider)
            case .anyChatGPT:
                return .anyChatGPT
            case .cancelOutcomeUnknown:
                return .cancelOutcomeUnknown(previousActiveAccountKey: accountKey)
            case .reconcileCurrentRuntime:
                return .reconcileCurrentRuntime
            }
        }
    }

    private struct TemporaryHomeCleanupDebt: Codable {
        var paths: [String]
    }

    static func reserveTemporaryCodexHome(
        kind: AccountRegistryStore.TemporaryCodexHomeKind,
        codexHomeURL: URL
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(kind.pathPrefix)\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try updateTemporaryHomeCleanupDebt(
            adding: url.path,
            codexHomeURL: codexHomeURL
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    static func finishTemporaryCodexHome(
        _ url: URL,
        codexHomeURL: URL,
        directoryDurabilityDidSynchronize: (@Sendable (URL) throws -> Void)? = nil
    ) throws {
        let standardizedURL = url.standardizedFileURL
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        let permittedName = standardizedURL.lastPathComponent.hasPrefix("codex-review-auth-")
            || standardizedURL.lastPathComponent.hasPrefix("codex-review-rate-limits-")
        precondition(
            standardizedURL.deletingLastPathComponent() == temporaryDirectory && permittedName,
            "Only owned CodexReview temporary homes can enter cleanup debt."
        )
        do {
            try removeDurably(
                at: standardizedURL,
                directoryDurabilityDidSynchronize: directoryDurabilityDidSynchronize
            )
            try updateTemporaryHomeCleanupDebt(
                removing: standardizedURL.path,
                codexHomeURL: codexHomeURL
            )
        } catch {
            try updateTemporaryHomeCleanupDebt(
                adding: standardizedURL.path,
                codexHomeURL: codexHomeURL
            )
            logger.error(
                "Credential-bearing temporary home cleanup remains pending: \(standardizedURL.path, privacy: .private(mask: .hash))"
            )
        }
    }

    private static func retryTemporaryHomeCleanup(codexHomeURL: URL) throws {
        let debtURL = temporaryHomeCleanupDebtURL(codexHomeURL: codexHomeURL)
        guard FileManager.default.fileExists(atPath: debtURL.path) else {
            return
        }
        let debt = try JSONDecoder().decode(
            TemporaryHomeCleanupDebt.self,
            from: Data(contentsOf: debtURL)
        )
        for path in debt.paths {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            try finishTemporaryCodexHome(url, codexHomeURL: codexHomeURL)
        }
    }

    private static func updateTemporaryHomeCleanupDebt(
        adding path: String? = nil,
        removing removedPath: String? = nil,
        codexHomeURL: URL
    ) throws {
        let url = temporaryHomeCleanupDebtURL(codexHomeURL: codexHomeURL)
        var paths: Set<String> = []
        if FileManager.default.fileExists(atPath: url.path) {
            paths = Set(try JSONDecoder().decode(
                TemporaryHomeCleanupDebt.self,
                from: Data(contentsOf: url)
            ).paths)
        }
        if let path {
            paths.insert(path)
        }
        if let removedPath {
            paths.remove(removedPath)
        }
        if paths.isEmpty {
            try removeDurably(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeAtomically(
            encoder.encode(TemporaryHomeCleanupDebt(paths: paths.sorted())),
            to: url,
            permissions: 0o600
        )
    }

    static func recordReconciliationDebt(
        expectedAccount: ExpectedRuntimeAccount,
        message: String,
        codexHomeURL: URL,
        directoryDurabilityDidSynchronize: (@Sendable (URL) throws -> Void)? = nil
    ) throws {
        let expectation: ReconciliationDebt.Expectation
        let accountKey: String?
        let provider: ExpectedRuntimeAccount.Provider?
        switch expectedAccount {
        case .signedOut:
            expectation = .signedOut
            accountKey = nil
            provider = nil
        case .account(let value):
            expectation = .account
            accountKey = CodexReviewAccount.normalizedEmail(value)
            provider = nil
        case .observedAccount(let value, let valueProvider):
            expectation = .observedAccount
            accountKey = CodexReviewAccount.normalizedEmail(value)
            provider = valueProvider
        case .anyChatGPT:
            expectation = .anyChatGPT
            accountKey = nil
            provider = nil
        case .cancelOutcomeUnknown(let previousActiveAccountKey):
            expectation = .cancelOutcomeUnknown
            accountKey = previousActiveAccountKey.map(CodexReviewAccount.normalizedEmail)
            provider = nil
        case .reconcileCurrentRuntime:
            expectation = .reconcileCurrentRuntime
            accountKey = nil
            provider = nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeAtomically(
            encoder.encode(ReconciliationDebt(
                expectation: expectation,
                accountKey: accountKey,
                provider: provider,
                message: message,
                recordedAt: Date()
            )),
            to: reconciliationDebtURL(codexHomeURL: codexHomeURL),
            permissions: 0o600,
            directoryDurabilityDidSynchronize: directoryDurabilityDidSynchronize
        )
    }

    static func reconciliationDebtExpectation(
        codexHomeURL: URL
    ) throws -> ExpectedRuntimeAccount? {
        let url = reconciliationDebtURL(codexHomeURL: codexHomeURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let debt = try JSONDecoder().decode(
                ReconciliationDebt.self,
                from: Data(contentsOf: url)
            )
            return debt.expectedRuntimeAccount
        } catch {
            throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                message: "The account reconciliation debt is inconsistent: \(error.localizedDescription)"
            )
        }
    }

    static func clearReconciliationDebt(codexHomeURL: URL) throws {
        let url = reconciliationDebtURL(codexHomeURL: codexHomeURL)
        try removeDurably(at: url)
    }

    static func load(codexHomeURL: URL) throws -> AccountRegistryStore.Snapshot {
        try retryTemporaryHomeCleanup(codexHomeURL: codexHomeURL)
        let registry = try loadRegistry(codexHomeURL: codexHomeURL)
        do {
            try garbageCollectOrphanedRevisions(
                referencedBy: registry,
                codexHomeURL: codexHomeURL
            )
        } catch {
            logger.error(
                "Account registry cleanup remains pending and will retry on the next load: \(error.localizedDescription, privacy: .public)"
            )
        }
        return snapshot(from: registry)
    }

    static func loadSnapshotWithoutMaintenance(
        codexHomeURL: URL
    ) throws -> AccountRegistryStore.Snapshot {
        snapshot(from: try loadRegistry(codexHomeURL: codexHomeURL))
    }

    private static func snapshot(
        from registry: Registry
    ) -> AccountRegistryStore.Snapshot {
        let accounts = registry.accounts.compactMap(makePayload(from:))
        let activeAccountKey = registry.activeAccountKey
            .map(CodexReviewAccount.normalizedEmail)
            .flatMap { activeAccountKey in
                accounts.contains(where: { $0.accountKey == activeAccountKey }) ? activeAccountKey : nil
            }
        logger.info("Loaded \(accounts.count, privacy: .public) persisted Codex review account(s)")
        return .init(accounts: accounts, activeAccountKey: activeAccountKey)
    }

    static func deactivateAccount(
        codexHomeURL: URL,
        destinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil
    ) throws {
        var registry = try loadRegistry(codexHomeURL: codexHomeURL)
        guard registry.activeAccountKey != nil else {
            return
        }
        registry.activeAccountKey = nil
        try saveRegistry(
            registry,
            codexHomeURL: codexHomeURL,
            destinationDidReplace: destinationDidReplace
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

    static func prepareAccountActivation(
        _ accountKey: String,
        codexHomeURL: URL
    ) throws -> AccountRegistryStore.PreparedMutation {
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
        let id = UUID()
        let journal = MutationJournal(
            id: id,
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
        return .init(id: id)
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
        do {
            try forwardPreparedJournal(&journal, codexHomeURL: codexHomeURL)
        } catch {
            let originalError = error
            do {
                let durableJournalURL = journalURL(codexHomeURL: codexHomeURL)
                if FileManager.default.fileExists(atPath: durableJournalURL.path) {
                    journal = try loadJournal(codexHomeURL: codexHomeURL)
                    guard journal.id == mutation.id else {
                        throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                            message: "The recovered account mutation token no longer matches its durable journal."
                        )
                    }
                    try forwardPreparedJournal(&journal, codexHomeURL: codexHomeURL)
                } else {
                    let registry = try loadRegistryWithoutRecovery(codexHomeURL: codexHomeURL)
                    guard sameRegistry(registry, journal.desiredRegistry) else {
                        throw originalError
                    }
                }
            } catch {
                throw CodexReviewAuthenticationFailure.accountCommit(
                    message: "The prepared account mutation could not forward-complete. "
                        + "Original failure: \(originalError.localizedDescription). "
                        + "Recovery failure: \(error.localizedDescription)"
                )
            }
        }
    }

    private static func forwardPreparedJournal(
        _ journal: inout MutationJournal,
        codexHomeURL: URL
    ) throws {
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
    ) throws -> AccountRegistryStore.PreparedAbortDisposition {
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
            return .restoredBefore(snapshot(from: journal.beforeRegistry))
        }
        try recoverJournal(journal, codexHomeURL: codexHomeURL)
        let recovered = try loadRegistryWithoutRecovery(codexHomeURL: codexHomeURL)
        if sameRegistry(recovered, journal.beforeRegistry) {
            return .restoredBefore(snapshot(from: recovered))
        }
        if sameRegistry(recovered, journal.desiredRegistry) {
            return .forwardedDesired(snapshot(from: recovered))
        }
        throw CodexReviewAuthenticationFailure.persistenceInconsistent(
            message: "The aborted account mutation resolved to neither its before nor desired registry."
        )
    }

    static func updateCachedRateLimits(
        from account: CodexSavedAccountPayload,
        codexHomeURL: URL,
        destinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil
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
        try saveRegistry(
            registry,
            codexHomeURL: codexHomeURL,
            destinationDidReplace: destinationDidReplace
        )
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
        codexHomeURL: URL,
        destinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil
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
        } else {
            revision = try writeImmutableRevision(
                sourceData,
                accountKey: authenticatedAccount.accountKey,
                codexHomeURL: codexHomeURL
            )
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
        let persistedDesired = try nextRegistry(from: desired)
        try persistRegistry(
            persistedDesired,
            codexHomeURL: codexHomeURL,
            destinationDidReplace: destinationDidReplace
        )
    }

    static func upsertAccount(
        _ account: CodexSavedAccountPayload,
        activation: LoginActivation,
        codexHomeURL: URL,
        destinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil
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
            codexHomeURL: codexHomeURL,
            destinationDidReplace: destinationDidReplace
        )
    }

    static func removeInactiveAccount(
        accountKey: String,
        codexHomeURL: URL,
        destinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil
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
        try saveRegistry(
            desired,
            codexHomeURL: codexHomeURL,
            destinationDidReplace: destinationDidReplace
        )
    }

    static func reorderAccount(
        accountKey: String,
        toIndex: Int,
        codexHomeURL: URL,
        destinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil
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
        try saveRegistry(
            registry,
            codexHomeURL: codexHomeURL,
            destinationDidReplace: destinationDidReplace
        )
    }

    static func saveSharedAuth(
        from sourceCodexHomeURL: URL,
        for account: CodexSavedAccountPayload,
        codexHomeURL: URL,
        destinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil
    ) throws {
        let sourceURL = sharedAuthURL(codexHomeURL: sourceCodexHomeURL)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return
        }
        let sourceData = try validatedAuthData(at: sourceURL)
        let previousRegistry = try loadRegistry(codexHomeURL: codexHomeURL)
        var desiredRegistry = previousRegistry
        guard let index = desiredRegistry.accounts.firstIndex(where: {
            normalizedAccountKey(from: $0) == account.accountKey
        }) else {
            throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                message: "Cannot attach authentication revision to missing account \(account.accountKey)."
            )
        }
        if let existingURL = immutableAuthURL(
            for: desiredRegistry.accounts[index],
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
        desiredRegistry.accounts[index].immutableRevision = revision
        let persistedDesired = try nextRegistry(from: desiredRegistry)
        try persistRegistry(
            persistedDesired,
            codexHomeURL: codexHomeURL,
            destinationDidReplace: destinationDidReplace
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
        codexHomeURL: URL,
        destinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil
    ) throws {
        try persistRegistry(
            nextRegistry(from: registry),
            codexHomeURL: codexHomeURL,
            destinationDidReplace: destinationDidReplace
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
        codexHomeURL: URL,
        destinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil
    ) throws {
        let url = registryURL(codexHomeURL: codexHomeURL)
        guard registry.schemaVersion == Registry.currentSchemaVersion,
              registry.contentHash == (try contentHash(for: registry)) else {
            throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                message: "Refusing to persist an account registry with an invalid content hash."
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(registry)
        do {
            try writeAtomically(
                data,
                to: url,
                permissions: 0o600,
                destinationDidReplace: destinationDidReplace
            )
        } catch let persistenceError {
            let observed: Registry
            do {
                observed = try loadRegistryWithoutRecovery(codexHomeURL: codexHomeURL)
            } catch {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "The account registry replacement outcome is unresolved. "
                        + "Write failure: \(persistenceError.localizedDescription). "
                        + "Reload failure: \(error.localizedDescription)"
                )
            }
            guard sameRegistry(observed, registry) else {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "The account registry replacement did not expose its desired durable state: "
                        + persistenceError.localizedDescription
                )
            }
            do {
                try synchronizeFile(at: url)
                try synchronizeDirectory(at: url.deletingLastPathComponent())
            } catch {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "The desired account registry is visible but its durability remains unresolved: "
                        + error.localizedDescription
                )
            }
        }
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
        try removeDurably(at: url)
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
        try writeAtomically(
            sourceData,
            to: destinationURL,
            permissions: 0o600
        )
        let destinationData = try validatedAuthData(at: destinationURL)
        guard fingerprint(destinationData) == fingerprint(sourceData) else {
            throw CodexReviewAuthenticationFailure.accountCommit(
                message: "Authentication copy fingerprint mismatch."
            )
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
        try createDirectoryHierarchy(
            at: directoryURL
        )
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try validatedAuthData(at: url)
            guard fingerprint(existing) == fingerprint(data) else {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "Immutable authentication revision \(revision) has conflicting content."
                )
            }
            try synchronizeFile(at: url)
            try synchronizeDirectory(at: directoryURL)
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
            let persisted = try validatedAuthData(at: url)
            guard fingerprint(persisted) == fingerprint(data) else {
                throw CodexReviewAuthenticationFailure.accountCommit(
                    message: "Immutable authentication revision fingerprint mismatch."
                )
            }
            return revision
        } catch {
            let originalError = error
            do {
                try removeDurably(at: url)
            } catch {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "Immutable authentication revision creation failed and its partial file could not be durably removed. "
                        + "Original failure: \(originalError.localizedDescription). "
                        + "Cleanup failure: \(error.localizedDescription)"
                )
            }
            throw originalError
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
        permissions: Int,
        directoryDurabilityDidSynchronize: (@Sendable (URL) throws -> Void)? = nil,
        destinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil
    ) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        try createDirectoryHierarchy(
            at: directoryURL,
            directoryDurabilityDidSynchronize: directoryDurabilityDidSynchronize
        )
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
        var didReplaceDestination = false
        do {
            let handle = try FileHandle(forWritingTo: replacementURL)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try renameAtomically(from: replacementURL, to: destinationURL)
            didReplaceDestination = true
            try destinationDidReplace?()
            try synchronizeFile(at: destinationURL)
            try synchronizeDirectory(at: directoryURL)
        } catch {
            if (try? Data(contentsOf: destinationURL)) == data {
                do {
                    try synchronizeFile(at: destinationURL)
                    try synchronizeDirectory(at: directoryURL)
                    if FileManager.default.fileExists(atPath: replacementURL.path) {
                        try removeDurably(at: replacementURL)
                    }
                    return
                } catch {
                    throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                        message: "The replacement at \(destinationURL.path) is visible but its durability remains unresolved: "
                            + error.localizedDescription
                    )
                }
            }
            if didReplaceDestination {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "The replacement outcome at \(destinationURL.path) is unresolved: "
                        + error.localizedDescription
                )
            }
            if FileManager.default.fileExists(atPath: replacementURL.path) {
                do {
                    try removeDurably(at: replacementURL)
                } catch {
                    throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                        message: "Atomic replacement failed before commit and its temporary file could not be removed: "
                            + error.localizedDescription
                    )
                }
            }
            throw error
        }
    }

    private static func createDirectoryHierarchy(
        at directoryURL: URL,
        directoryDurabilityDidSynchronize: (@Sendable (URL) throws -> Void)? = nil
    ) throws {
        let directoryURL = directoryURL.standardizedFileURL
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        var cursor = directoryURL
        while true {
            try synchronizeDirectory(at: cursor)
            try directoryDurabilityDidSynchronize?(cursor)
            guard cursor != filesystemRootURL else {
                return
            }
            let parent = cursor.deletingLastPathComponent()
            guard parent != cursor else {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "Directory durability escaped its owning ancestor at \(directoryURL.path)."
                )
            }
            cursor = parent
        }
    }

    private static func renameAtomically(from sourceURL: URL, to destinationURL: URL) throws {
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private static func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    private static func removeDurably(
        at url: URL,
        directoryDurabilityDidSynchronize: (@Sendable (URL) throws -> Void)? = nil
    ) throws {
        let directoryURL = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                guard FileManager.default.fileExists(atPath: url.path) == false else {
                    throw error
                }
            }
        }
        guard FileManager.default.fileExists(atPath: url.path) == false else {
            throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                message: "The durable removal left its destination visible at \(url.path)."
            )
        }
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return
        }
        do {
            try synchronizeDirectory(at: directoryURL)
            try directoryDurabilityDidSynchronize?(directoryURL)
        } catch {
            do {
                try synchronizeDirectory(at: directoryURL)
                try directoryDurabilityDidSynchronize?(directoryURL)
            } catch {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "The removal at \(url.path) is visible but its directory durability remains unresolved: "
                        + error.localizedDescription
                )
            }
        }
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

    private static func reconciliationDebtURL(codexHomeURL: URL) -> URL {
        accountsDirectoryURL(codexHomeURL: codexHomeURL)
            .appendingPathComponent("reconciliation-debt.json")
    }

    private static func temporaryHomeCleanupDebtURL(codexHomeURL: URL) -> URL {
        accountsDirectoryURL(codexHomeURL: codexHomeURL)
            .appendingPathComponent("temporary-home-cleanup-debt.json")
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
