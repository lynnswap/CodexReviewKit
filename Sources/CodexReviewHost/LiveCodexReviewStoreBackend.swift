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
    var authenticationSession: (any CodexReviewNativeAuthentication.WebSession)?

    var isEmpty: Bool {
        client == nil && codexHomeURL == nil && authenticationSession == nil
    }
}

private enum CodexExecutableDependency: Sendable {
    case resolvedForTesting(URL)
    case resolver(CodexExecutableResolver)
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
    func stop() async throws
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
        resolvedCodexExecutableURLForTesting: URL = URL(fileURLWithPath: "/usr/bin/true"),
        nativeAuthenticationConfiguration: CodexReviewNativeAuthentication.Configuration? = nil,
        webAuthenticationSessionFactory: @escaping CodexReviewNativeAuthentication.WebSessionFactory,
        externalURLOpener: @escaping @MainActor @Sendable (URL) -> Void = defaultExternalURLOpener,
        mcpPortOwnerResolver: CodexReviewMCPPortOwnerResolver? = nil,
        mcpHTTPServerBindChecker: CodexReviewMCPHTTPServerBindChecker? = nil,
        shutdownCleanupTimeout: Duration = .seconds(2),
        networkMonitor: any CodexReviewNetworkMonitoring = SystemCodexReviewNetworkMonitor(),
        networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy = .default,
        transport: any JSONRPC.Transport
    ) -> CodexReviewStore {
        makeLiveStoreForTesting(
            environment: environment,
            runtimePreferences: runtimePreferences,
            resolvedCodexExecutableURLForTesting: resolvedCodexExecutableURLForTesting,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory,
            externalURLOpener: externalURLOpener,
            mcpPortOwnerResolver: mcpPortOwnerResolver,
            mcpHTTPServerBindChecker: mcpHTTPServerBindChecker,
            shutdownCleanupTimeout: shutdownCleanupTimeout,
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: networkRecoveryPolicy,
            transportFactory: { _ in transport }
        )
    }

    package static func makeLiveStoreForTesting(
        environment: [String: String],
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        resolvedCodexExecutableURLForTesting: URL = URL(fileURLWithPath: "/usr/bin/true"),
        nativeAuthenticationConfiguration: CodexReviewNativeAuthentication.Configuration? = nil,
        webAuthenticationSessionFactory: @escaping CodexReviewNativeAuthentication.WebSessionFactory,
        externalURLOpener: @escaping @MainActor @Sendable (URL) -> Void = defaultExternalURLOpener,
        mcpHTTPServerFactory: (@MainActor @Sendable (
            CodexReviewStore,
            CodexReviewMCPHTTPServer.Configuration
        ) -> any CodexReviewMCPHTTPServing)? = nil,
        mcpPortOwnerResolver: CodexReviewMCPPortOwnerResolver? = nil,
        mcpHTTPServerBindChecker: CodexReviewMCPHTTPServerBindChecker? = nil,
        shutdownCleanupTimeout: Duration = .seconds(2),
        networkMonitor: any CodexReviewNetworkMonitoring = SystemCodexReviewNetworkMonitor(),
        networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy = .default,
        transportFactory: @escaping @MainActor @Sendable (URL) async throws -> any JSONRPC.Transport
    ) -> CodexReviewStore {
        makeLiveStoreForTesting(
            environment: environment,
            runtimePreferences: runtimePreferences,
            executableDependency: .resolvedForTesting(resolvedCodexExecutableURLForTesting),
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory,
            externalURLOpener: externalURLOpener,
            mcpHTTPServerFactory: mcpHTTPServerFactory,
            mcpPortOwnerResolver: mcpPortOwnerResolver,
            mcpHTTPServerBindChecker: mcpHTTPServerBindChecker,
            shutdownCleanupTimeout: shutdownCleanupTimeout,
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: networkRecoveryPolicy,
            resolvedTransportFactory: { codexHomeURL, _ in
                try await transportFactory(codexHomeURL)
            }
        )
    }

    package static func makeLiveStoreForTesting(
        environment: [String: String],
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        codexExecutableResolver: CodexExecutableResolver,
        nativeAuthenticationConfiguration: CodexReviewNativeAuthentication.Configuration? = nil,
        webAuthenticationSessionFactory: @escaping CodexReviewNativeAuthentication.WebSessionFactory,
        externalURLOpener: @escaping @MainActor @Sendable (URL) -> Void = defaultExternalURLOpener,
        mcpHTTPServerFactory: (@MainActor @Sendable (
            CodexReviewStore,
            CodexReviewMCPHTTPServer.Configuration
        ) -> any CodexReviewMCPHTTPServing)? = nil,
        mcpPortOwnerResolver: CodexReviewMCPPortOwnerResolver? = nil,
        mcpHTTPServerBindChecker: CodexReviewMCPHTTPServerBindChecker? = nil,
        shutdownCleanupTimeout: Duration = .seconds(2),
        networkMonitor: any CodexReviewNetworkMonitoring = SystemCodexReviewNetworkMonitor(),
        networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy = .default,
        resolvedTransportFactory: @escaping @MainActor @Sendable (
            URL,
            URL
        ) async throws -> any JSONRPC.Transport
    ) -> CodexReviewStore {
        makeLiveStoreForTesting(
            environment: environment,
            runtimePreferences: runtimePreferences,
            executableDependency: .resolver(codexExecutableResolver),
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory,
            externalURLOpener: externalURLOpener,
            mcpHTTPServerFactory: mcpHTTPServerFactory,
            mcpPortOwnerResolver: mcpPortOwnerResolver,
            mcpHTTPServerBindChecker: mcpHTTPServerBindChecker,
            shutdownCleanupTimeout: shutdownCleanupTimeout,
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: networkRecoveryPolicy,
            resolvedTransportFactory: resolvedTransportFactory
        )
    }

    private static func makeLiveStoreForTesting(
        environment: [String: String],
        runtimePreferences: CodexReviewRuntime.Preferences,
        executableDependency: CodexExecutableDependency,
        nativeAuthenticationConfiguration: CodexReviewNativeAuthentication.Configuration?,
        webAuthenticationSessionFactory: @escaping CodexReviewNativeAuthentication.WebSessionFactory,
        externalURLOpener: @escaping @MainActor @Sendable (URL) -> Void,
        mcpHTTPServerFactory: (@MainActor @Sendable (
            CodexReviewStore,
            CodexReviewMCPHTTPServer.Configuration
        ) -> any CodexReviewMCPHTTPServing)?,
        mcpPortOwnerResolver: CodexReviewMCPPortOwnerResolver?,
        mcpHTTPServerBindChecker: CodexReviewMCPHTTPServerBindChecker?,
        shutdownCleanupTimeout: Duration,
        networkMonitor: any CodexReviewNetworkMonitoring,
        networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy,
        resolvedTransportFactory: @escaping @MainActor @Sendable (
            URL,
            URL
        ) async throws -> any JSONRPC.Transport
    ) -> CodexReviewStore {
        CodexReviewStore(
            backend: LiveCodexReviewStoreBackend(
                environment: environment,
                runtimePreferences: runtimePreferences,
                codexExecutableDependencyForTesting: executableDependency,
                nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
                webAuthenticationSessionFactory: webAuthenticationSessionFactory,
                externalURLOpener: externalURLOpener,
                mcpHTTPServerFactory: mcpHTTPServerFactory,
                mcpPortOwnerResolver: mcpPortOwnerResolver,
                mcpHTTPServerBindChecker: mcpHTTPServerBindChecker,
                shutdownCleanupTimeout: shutdownCleanupTimeout,
                appServerRuntimeFactory: { codexHomeURL, executableURL in
                    let transport = try await resolvedTransportFactory(codexHomeURL, executableURL)
                    let client = AppServerClient(transport: transport)
                    return .init(
                        client: client,
                        backend: AppServerCodexReviewBackend(client: client)
                    )
                }
            ),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: networkRecoveryPolicy
        )
    }

    package var liveReviewAttemptRouteCountForTesting: Int? {
        (backend as? LiveCodexReviewStoreBackend)?.reviewAttemptRuntimeRouteCountForTesting
    }

    package var liveReviewRecoveryRouteCountForTesting: Int? {
        (backend as? LiveCodexReviewStoreBackend)?.reviewRecoveryRouteCountForTesting
    }
}

@MainActor
private final class LiveCodexReviewStoreBackend: CodexReviewStoreBackend, MCPServerLifecycleOwner {
    private struct ReviewAttemptRuntimeRouteRegistry {
        private enum Recovery {
            case preparing(ReviewRecoveryRouteReceipt)
            case prepared(PreparedReviewRecovery)
            case staging(
                PreparedReviewRecovery,
                LiveRuntimeLifecycleHandle,
                ReviewStartAdmission
            )
            case staged(StagedReviewRecovery, LiveRuntimeLifecycleHandle)
        }

        private struct Route {
            var run: CodexReviewBackendModel.Review.Run
            var runtime: LiveRuntimeLifecycleHandle
            var recovery: Recovery?
        }

        private var routes: [String: Route] = [:]

        var count: Int {
            routes.count
        }

        var recoveryCount: Int {
            routes.values.count { $0.recovery != nil }
        }

        mutating func bind(
            run: CodexReviewBackendModel.Review.Run,
            to runtime: LiveRuntimeLifecycleHandle
        ) throws {
            if let existing = routes[run.attemptID] {
                guard existing.runtime === runtime, existing.recovery == nil else {
                    throw ReviewAttemptContractFailure(
                        message: "Review attempt \(run.attemptID) is already routed to another runtime."
                    )
                }
                return
            }
            routes[run.attemptID] = .init(run: run, runtime: runtime)
        }

        func runtime(
            for attemptID: String,
            operation: String
        ) throws -> LiveRuntimeLifecycleHandle {
            guard let route = routes[attemptID], route.recovery == nil else {
                throw ReviewAttemptContractFailure(
                    message: "Review \(operation) requires a runtime route for attempt \(attemptID)."
                )
            }
            return route.runtime
        }

        func runtime(
            for run: CodexReviewBackendModel.Review.Run,
            operation: String
        ) throws -> LiveRuntimeLifecycleHandle {
            guard let route = routes[run.attemptID],
                  route.run == run,
                  route.recovery == nil else {
                throw ReviewAttemptContractFailure(
                    message: "Review \(operation) requires the exact runtime route for attempt \(run.attemptID)."
                )
            }
            return route.runtime
        }

        func contains(
            attemptID: String,
            runtime: LiveRuntimeLifecycleHandle
        ) -> Bool {
            guard let route = routes[attemptID] else { return false }
            return route.runtime === runtime && route.recovery == nil
        }

        mutating func move(
            sourceAttemptID: String,
            recoveredRun: CodexReviewBackendModel.Review.Run,
            runtime: LiveRuntimeLifecycleHandle
        ) throws {
            let recoveredAttemptID = recoveredRun.attemptID
            guard let source = routes[sourceAttemptID],
                  source.runtime === runtime,
                  source.recovery == nil
            else {
                throw ReviewAttemptContractFailure(
                    message: "Review recovery source route changed before attempt \(recoveredAttemptID) became active."
                )
            }
            guard sourceAttemptID != recoveredAttemptID else {
                return
            }
            if let existing = routes[recoveredAttemptID] {
                guard existing.runtime === runtime else {
                    throw ReviewAttemptContractFailure(
                        message: "Recovered review attempt \(recoveredAttemptID) is already routed to another runtime."
                    )
                }
                throw ReviewAttemptContractFailure(
                    message: "Recovered review attempt \(recoveredAttemptID) already has a runtime route."
                )
            }
            routes.removeValue(forKey: sourceAttemptID)
            var recovered = source
            recovered.run = recoveredRun
            routes[recoveredAttemptID] = recovered
        }

        mutating func take(
            attemptID: String,
            operation: String
        ) throws -> LiveRuntimeLifecycleHandle {
            guard let route = routes[attemptID], route.recovery == nil else {
                throw ReviewAttemptContractFailure(
                    message: "Review \(operation) requires a runtime route for attempt \(attemptID)."
                )
            }
            routes.removeValue(forKey: attemptID)
            return route.runtime
        }

        mutating func removeIfCurrent(
            attemptID: String,
            runtime: LiveRuntimeLifecycleHandle
        ) {
            guard let route = routes[attemptID],
                  route.runtime === runtime,
                  route.recovery == nil
            else {
                return
            }
            routes.removeValue(forKey: attemptID)
        }

        mutating func beginPreparation(
            _ candidate: ReviewRecoveryCandidate
        ) throws -> (ReviewRecoveryRouteReceipt, LiveRuntimeLifecycleHandle) {
            let run = candidate.resolved.run
            guard var route = routes[run.attemptID],
                  route.run == run,
                  route.recovery == nil
            else { throw routeFailure("preparation", attemptID: run.attemptID) }
            let receipt = ReviewRecoveryRouteReceipt(
                sourceRun: run,
                sourceGeneration: route.runtime.generation
            )
            route.recovery = .preparing(receipt)
            routes[run.attemptID] = route
            return (receipt, route.runtime)
        }

        mutating func finishPreparation(_ prepared: PreparedReviewRecovery) throws {
            let id = prepared.receipt.sourceRun.attemptID
            guard var route = routes[id],
                  case .preparing(let receipt) = route.recovery,
                  receipt === prepared.receipt
            else { throw routeFailure("preparation completion", attemptID: id) }
            route.recovery = .prepared(prepared)
            routes[id] = route
        }

        mutating func takePrepared(
            _ prepared: PreparedReviewRecovery
        ) throws -> LiveRuntimeLifecycleHandle {
            let id = prepared.receipt.sourceRun.attemptID
            guard let route = routes[id],
                  case .prepared(let current) = route.recovery,
                  current.receipt === prepared.receipt,
                  current.handoff == prepared.handoff
            else { throw routeFailure("prepared discard", attemptID: id) }
            routes.removeValue(forKey: id)
            return route.runtime
        }

        mutating func beginStaging(
            _ prepared: PreparedReviewRecovery,
            destination: LiveRuntimeLifecycleHandle,
            admission: ReviewStartAdmission
        ) throws {
            var route = try preparedRouteForStaging(prepared)
            let id = prepared.receipt.sourceRun.attemptID
            route.recovery = .staging(prepared, destination, admission)
            routes[id] = route
        }

        func validatePreparedForStaging(_ prepared: PreparedReviewRecovery) throws {
            _ = try preparedRouteForStaging(prepared)
        }

        mutating func finishStaging(_ staged: StagedReviewRecovery) throws {
            let id = staged.receipt.sourceRun.attemptID
            guard var route = routes[id],
                  case .staging(let prepared, let destination, let admission) = route.recovery,
                  prepared.receipt === staged.receipt,
                  destination.generation == staged.destinationGeneration,
                  admission === staged.admission
            else { throw routeFailure("staging completion", attemptID: id) }
            route.recovery = .staged(staged, destination)
            routes[id] = route
        }

        mutating func commit(
            _ staged: StagedReviewRecovery,
            activeRuntime: LiveRuntimeLifecycleHandle?
        ) throws {
            let sourceID = staged.receipt.sourceRun.attemptID
            let recoveredRun = staged.attempt.run
            guard sourceID != recoveredRun.attemptID,
                  routes[recoveredRun.attemptID] == nil,
                  let route = routes[sourceID],
                  case .staged(let current, let destination) = route.recovery,
                  current === staged,
                  destination === activeRuntime,
                  destination.generation == staged.destinationGeneration
            else { throw routeFailure("commit", attemptID: sourceID) }
            routes.removeValue(forKey: sourceID)
            routes[recoveredRun.attemptID] = .init(run: recoveredRun, runtime: destination)
        }

        mutating func takeStaged(
            _ staged: StagedReviewRecovery
        ) throws -> LiveRuntimeLifecycleHandle {
            let id = staged.receipt.sourceRun.attemptID
            guard let route = routes[id],
                  case .staged(let current, let destination) = route.recovery,
                  current === staged
            else { throw routeFailure("staged discard", attemptID: id) }
            routes.removeValue(forKey: id)
            return destination
        }

        mutating func takeInFlight(
            _ receipt: ReviewRecoveryRouteReceipt,
            admission: ReviewStartAdmission? = nil
        ) throws -> (CodexReviewBackendModel.Review.Run, LiveRuntimeLifecycleHandle) {
            let id = receipt.sourceRun.attemptID
            guard let route = routes[id] else { throw routeFailure("failure cleanup", attemptID: id) }
            switch route.recovery {
            case .preparing(let current) where current === receipt:
                routes.removeValue(forKey: id)
                return (route.run, route.runtime)
            case .staging(let prepared, _, let currentAdmission)
                where prepared.receipt === receipt && currentAdmission === admission:
                routes.removeValue(forKey: id)
                return (route.run, route.runtime)
            case .preparing, .prepared, .staging, .staged, nil:
                throw routeFailure("failure cleanup", attemptID: id)
            }
        }

        private func routeFailure(
            _ operation: String,
            attemptID: String
        ) -> ReviewAttemptContractFailure {
            .init(message: "Review recovery \(operation) requires its exact route for attempt \(attemptID).")
        }

        private func preparedRouteForStaging(
            _ prepared: PreparedReviewRecovery
        ) throws -> Route {
            let id = prepared.receipt.sourceRun.attemptID
            guard let route = routes[id],
                  case .prepared(let current) = route.recovery,
                  current.receipt === prepared.receipt,
                  current.handoff == prepared.handoff
            else { throw routeFailure("staging", attemptID: id) }
            return route
        }
    }

    typealias MCPHTTPServerFactory = @MainActor @Sendable (
        CodexReviewStore,
        CodexReviewMCPHTTPServer.Configuration
    ) -> any CodexReviewMCPHTTPServing

    let seed: CodexReviewStoreSeed

    private var client: AppServerClient?
    private var appServerBackend: AppServerCodexReviewBackend?
    private var activeRuntimeHandle: LiveRuntimeLifecycleHandle?
    private var reviewAttemptRuntimeRoutes = ReviewAttemptRuntimeRouteRegistry()
    fileprivate var reviewAttemptRuntimeRouteCountForTesting: Int {
        reviewAttemptRuntimeRoutes.count
    }
    fileprivate var reviewRecoveryRouteCountForTesting: Int {
        reviewAttemptRuntimeRoutes.recoveryCount
    }
    private var acceptsRuntimeRequests = false
    private var mcpHTTPServer: (any CodexReviewMCPHTTPServing)?
    private var loginChallenge: CodexReviewBackendModel.Login.Challenge?
    private var loginBackend: AppServerCodexReviewBackend?
    private var loginClient: AppServerClient?
    private var loginCodexHomeURL: URL?
    private var loginActivation: LoginActivation = .activateAuthenticatedAccount
    private var isWaitingForLoginAccountUpdate = false
    private var activeAuthenticationSession: (any CodexReviewNativeAuthentication.WebSession)?
    private var authenticationTask: Task<Void, Never>?
    private var authNotificationTask: Task<Void, Never>?
    private var loginNotificationTask: Task<Void, Never>?
    private var settingsSnapshot = CodexReviewSettings.Snapshot()
    private let codexHomeURL: URL
    private let mcpHTTPServerConfiguration: CodexReviewMCPHTTPServer.Configuration
    private let nativeAuthenticationConfiguration: CodexReviewNativeAuthentication.Configuration?
    private let webAuthenticationSessionFactory: CodexReviewNativeAuthentication.WebSessionFactory
    private let externalURLOpener: ExternalURLOpener
    private let mcpHTTPServerFactory: MCPHTTPServerFactory?
    private let mcpPortOwnerResolver: CodexReviewMCPPortOwnerResolver
    private let mcpHTTPServerBindChecker: CodexReviewMCPHTTPServerBindChecker
    private let appServerRuntimeFactory: AppServerRuntimeFactory
    private let shutdownCleanupTimeout: Duration
    private weak var attachedStore: CodexReviewStore?
    private var preparingMCPServer: PreparedMCPServer?
    private var preparedMCPServer: PreparedMCPServer?
    private var runningMCPServer: PreparedMCPServer?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        codexExecutableDependencyForTesting: CodexExecutableDependency? = nil,
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
        shutdownCleanupTimeout: Duration = .seconds(2),
        appServerRuntimeFactory: ResolvedAppServerRuntimeFactory? = nil
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
        let executableResolution: Result<URL, CodexExecutableResolutionError>
        switch codexExecutableDependencyForTesting {
        case .resolvedForTesting(let url):
            executableResolution = .success(url)
        case .resolver(let resolver):
            do {
                executableResolution = .success(try resolver.resolve(
                    configuredPath: runtimePreferences.codexExecutablePath,
                    environment: environment
                ))
            } catch {
                executableResolution = .failure(error)
            }
        case nil:
            do {
                executableResolution = .success(try CodexExecutableResolver(configuration: .live()).resolve(
                    configuredPath: runtimePreferences.codexExecutablePath,
                    environment: environment
                ))
            } catch {
                executableResolution = .failure(error)
            }
        }
        let resolvedFactory = appServerRuntimeFactory ?? Self.makeAppServerRuntimeFactory()
        self.appServerRuntimeFactory = { codexHomeURL in
            try await resolvedFactory(codexHomeURL, executableResolution.get())
        }
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
        acceptsRuntimeRequests
    }

    var mcpServerLifecycle: any MCPServerLifecycleOwner {
        self
    }

    var handlesActiveReviewStopCleanup: Bool {
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

    private static func makeAppServerRuntimeFactory() -> ResolvedAppServerRuntimeFactory {
        { codexHomeURL, executableURL in
            let processRuntime = try await Task.detached(priority: .userInitiated) {
                // The configuration probe can wait on `codex app-server --help`; keep it off the MainActor.
                let configuration = AppServerProcessTransport.Configuration(
                    executableURL: executableURL,
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

    func prepare() async throws -> PreparedMCPServer {
        guard mcpHTTPServer == nil,
              preparingMCPServer == nil,
              preparedMCPServer == nil,
              runningMCPServer == nil
        else {
            throw CancellationError()
        }
        let preparation = PreparedMCPServer()
        preparingMCPServer = preparation
        do {
            if mcpHTTPServerFactory != nil {
                try await mcpHTTPServerBindChecker(mcpHTTPServerConfiguration)
            }
            guard preparingMCPServer === preparation else {
                throw CancellationError()
            }
            if let mcpHTTPServerFactory {
                guard let attachedStore else {
                    throw CancellationError()
                }
                mcpHTTPServer = mcpHTTPServerFactory(
                    attachedStore,
                    mcpHTTPServerConfiguration
                )
            }
            preparingMCPServer = nil
            preparedMCPServer = preparation
            return preparation
        } catch {
            if preparingMCPServer === preparation {
                preparingMCPServer = nil
            }
            throw CodexReviewAPI.Error.io(await runtimeStartupFailureMessage(for: error))
        }
    }

    func activate(
        _ preparation: PreparedMCPServer
    ) async throws -> MCPServerPublicationSnapshot {
        guard preparedMCPServer === preparation else {
            throw CancellationError()
        }
        guard let server = mcpHTTPServer else {
            preparedMCPServer = nil
            runningMCPServer = preparation
            return .init(serverURL: nil)
        }
        do {
            try await server.start()
            guard mcpHTTPServer === server,
                  preparedMCPServer === preparation
            else {
                throw CancellationError()
            }
            let serverURL = await server.url
            guard mcpHTTPServer === server,
                  preparedMCPServer === preparation
            else {
                throw CancellationError()
            }
            preparedMCPServer = nil
            runningMCPServer = preparation
            return .init(serverURL: serverURL)
        } catch {
            if mcpHTTPServer === server {
                mcpHTTPServer = nil
                preparedMCPServer = nil
                try? await server.stop()
            }
            throw error
        }
    }

    func stop() async throws {
        preparingMCPServer = nil
        preparedMCPServer = nil
        runningMCPServer = nil
        guard let server = mcpHTTPServer else {
            return
        }
        mcpHTTPServer = nil
        try await server.stop()
    }

    func prepareRuntime(
        generation: ReviewRuntimeGeneration,
        purpose _: ReviewRuntimeTransitionPurpose
    ) async throws -> PreparedRuntime {
        logger.info("Preparing review runtime")
        let runtime = try await appServerRuntimeFactory(codexHomeURL)
        do {
            let authNotificationStream = await runtime.client.notificationStream()
            let authentication = try await runtime.backend.readAuth()
            let settings = try await Self.monitorSettings(from: runtime.backend.readSettings())
            let handle = LiveRuntimeLifecycleHandle(
                owner: self,
                generation: generation,
                client: runtime.client,
                backend: runtime.backend,
                authNotificationStream: authNotificationStream,
                snapshot: .init(
                    authentication: authentication,
                    settings: settings
                )
            )
            logger.info("Review runtime prepared")
            return .init(snapshot: handle.snapshot, handle: handle)
        } catch {
            await closeAppServerRuntime(
                backend: runtime.backend,
                fallbackClient: runtime.client,
                context: "runtime preparation cleanup"
            )
            throw error
        }
    }

    func commitRuntimePublication(
        _ snapshot: RuntimePublicationSnapshot,
        handle: any RuntimeLifecycleHandle,
        auth: CodexReviewAuthModel
    ) throws {
        guard let handle = handle as? LiveRuntimeLifecycleHandle,
              activeRuntimeHandle === handle,
              let attachedStore
        else {
            throw CancellationError()
        }
        applyRuntimeAuthenticationSnapshot(snapshot.authentication, to: auth)
        if let activeAccountID = snapshot.authentication.activeAccountID?.rawValue,
           let account = auth.persistedAccounts.first(where: {
               $0.accountKey == CodexAccount.normalizedEmail(activeAccountID)
           })
        {
            try? CodexReviewAccountRegistry.saveAccounts(
                auth.persistedAccounts,
                activeAccountKey: account.accountKey,
                codexHomeURL: codexHomeURL
            )
            try? CodexReviewAccountRegistry.saveSharedAuth(
                for: account,
                codexHomeURL: codexHomeURL
            )
        }
        acceptsRuntimeRequests = true
        observeAuthNotifications(
            stream: handle.authNotificationStream,
            backend: handle.backend,
            handle: handle,
            store: attachedStore
        )
        handle.initialRateLimitTask = Task { @MainActor [weak self, weak auth] in
            guard let self, let auth else {
                return
            }
            await self.refreshSelectedAccountRateLimits(
                auth: auth,
                expectedRuntimeHandle: handle
            )
        }
    }

    func waitForRuntimePublication(
        handle: any RuntimeLifecycleHandle
    ) async {
        guard let handle = handle as? LiveRuntimeLifecycleHandle else {
            return
        }
        await handle.initialRateLimitTask?.value
    }

    func activateRuntime(_ handle: LiveRuntimeLifecycleHandle) throws {
        guard activeRuntimeHandle == nil, attachedStore != nil else {
            throw CancellationError()
        }
        activeRuntimeHandle = handle
        acceptsRuntimeRequests = false
        client = handle.client
        appServerBackend = handle.backend
        settingsSnapshot = handle.snapshot.settings
    }

    func closeRuntimeAdmission(_ handle: LiveRuntimeLifecycleHandle) {
        guard activeRuntimeHandle === handle else {
            return
        }
        acceptsRuntimeRequests = false
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
        appServerBackend = nil
        let task = authNotificationTask
        authNotificationTask = nil
        task?.cancel()
        return task
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

    private func cancelActiveReviewsForRuntimeTeardown(
        store: CodexReviewStore,
        appServerBackend: AppServerCodexReviewBackend,
        reason: ReviewCancellation,
        timeoutWarning: String
    ) async {
        store.recordActiveReviewCancellationRequestsForRuntimeStop(reason: reason)
        let didInterrupt = await runRuntimeShutdownCleanup(timeout: shutdownCleanupTimeout) {
            await appServerBackend.interruptActiveReviewsForShutdown(reason: .init(message: reason.message))
        }
        let locallyCancelledJobIDs = store.cancelActiveReviewsLocallyForRuntimeStop(
            reason: reason,
            cancelWorkers: false
        )
        store.cancelAndDetachReviewWorkersForRuntimeStop(jobIDs: locallyCancelledJobIDs)
        let didDrainReviewWorkers = await store.drainReviewWorkersForRuntimeStop(
            timeout: shutdownCleanupTimeout
        )
        if didInterrupt == false || didDrainReviewWorkers == false {
            logger.warning("\(timeoutWarning, privacy: .public)")
        }
    }

    func stop(store: CodexReviewStore) async {
        await stop(store: store, intent: .explicitStop)
    }

    func stop(
        store: CodexReviewStore,
        intent: ReviewRuntimeTeardownIntent
    ) async {
        let appServerBackend = appServerBackend
        let loginCleanup = takeLoginRuntimeForCleanup()
        guard appServerBackend != nil || loginCleanup.isEmpty == false else {
            return
        }
        logger.info("Stopping review runtime semantic work for \(intent.diagnosticContext, privacy: .public)")
        if let appServerBackend {
            await cancelActiveReviewsForRuntimeTeardown(
                store: store,
                appServerBackend: appServerBackend,
                reason: intent.reviewCancellation,
                timeoutWarning: intent.cleanupTimeoutWarning
            )
        }
        await cleanupLoginRuntime(loginCleanup)
        logger.info("Review runtime semantic work stopped after \(intent.diagnosticContext, privacy: .public)")
    }

    func waitUntilStopped() async {}

    func refreshSettings() async throws -> CodexReviewSettings.Snapshot {
        guard activeRuntimeHandle != nil, let appServerBackend else {
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
        guard activeRuntimeHandle != nil, let appServerBackend else {
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
        guard activeRuntimeHandle != nil, let appServerBackend else {
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
        guard activeRuntimeHandle != nil, let appServerBackend else {
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
        guard acceptsRuntimeRequests,
              let expectedRuntimeHandle = activeRuntimeHandle
        else {
            return
        }
        do {
            guard let appServerBackend else {
                auth.updatePhase(.signedOut)
                return
            }
            let snapshot = try await appServerBackend.readAuth()
            guard activeRuntimeHandle === expectedRuntimeHandle,
                  acceptsRuntimeRequests
            else {
                return
            }
            applyAuthSnapshot(snapshot, to: auth)
        } catch {
            guard activeRuntimeHandle === expectedRuntimeHandle,
                  acceptsRuntimeRequests
            else {
                return
            }
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
        guard let attachedStore else {
            return
        }
        await attachedStore.closeActiveReviewSessions(reason: .system(message: "Account switched."))
        await attachedStore.recycleRuntimeAfterAccountChange()
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
            guard let attachedStore else {
                return
            }
            await attachedStore.closeActiveReviewSessions(reason: .system(message: "Account removed."))
            await attachedStore.recycleRuntimeAfterAccountChange()
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
        let shouldRecycleRuntime = attachedStore != nil
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
            await attachedStore.recycleRuntimeAfterAccountChange()
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
        let expectedRuntimeHandle = activeRuntimeHandle
        var isolatedLoginClient: AppServerClient?
        var isolatedLoginCodexHomeURL: URL?
        do {
            let runtime = try await loginRuntime(for: activation)
            let appServerBackend = runtime.backend
            let loginCodexHomeURL = runtime.codexHomeURL
            let loginClient = runtime.usesPrimaryRuntime ? nil : runtime.client
            isolatedLoginClient = loginClient
            isolatedLoginCodexHomeURL = loginCodexHomeURL
            guard isCurrentRuntime(expectedRuntimeHandle) else {
                await closeIsolatedLoginRuntime(client: loginClient, codexHomeURL: loginCodexHomeURL)
                return
            }
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
            guard let expectedRuntimeHandle,
                  activeRuntimeHandle === expectedRuntimeHandle,
                  acceptsRuntimeRequests
            else {
                try? await appServerBackend.cancelLogin(challenge)
                await closeIsolatedLoginRuntime(client: loginClient, codexHomeURL: loginCodexHomeURL)
                return
            }
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
            guard activeRuntimeHandle === expectedRuntimeHandle,
                  acceptsRuntimeRequests,
                  loginChallenge?.id == challenge.id
            else {
                await session.cancel()
                try? await appServerBackend.cancelLogin(challenge)
                await closeIsolatedLoginRuntime(client: loginClient, codexHomeURL: loginCodexHomeURL)
                return
            }
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

    private func isCurrentRuntime(
        _ expectedRuntimeHandle: LiveRuntimeLifecycleHandle?
    ) -> Bool {
        guard let expectedRuntimeHandle else {
            return activeRuntimeHandle == nil
        }
        return activeRuntimeHandle === expectedRuntimeHandle && acceptsRuntimeRequests
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
            guard acceptsRuntimeRequests, let client, let appServerBackend else {
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
        authenticationTask = nil
        loginNotificationTask?.cancel()
        loginNotificationTask = nil
        auth.updatePhase(.signedOut)
        await closeIsolatedLoginRuntime(client: loginClient, codexHomeURL: loginCodexHomeURL)
    }

    func startReview(
        _ request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> BackendReviewAttempt {
        guard acceptsRuntimeRequests, let runtime = activeRuntimeHandle else {
            throw CodexReviewAPI.Error.io("Review runtime is not running.")
        }
        let attempt: BackendReviewAttempt
        do {
            attempt = try await runtime.backend.startReview(
                request,
                admission: admission
            )
        } catch {
            if case .startingReview(let preparedRun, .outcomeUnknown) = await admission.currentPhase(),
               await admission.failedReviewStartDisposition(for: preparedRun) == .preserveOutcomeUnknown
            {
                do {
                    try reviewAttemptRuntimeRoutes.bind(
                        run: preparedRun,
                        to: runtime
                    )
                } catch let routeError {
                    throw await reviewRouteBindingFailure(
                        routeError,
                        startError: error,
                        cleanupRun: preparedRun,
                        runtime: runtime
                    )
                }
            }
            throw error
        }
        do {
            try reviewAttemptRuntimeRoutes.bind(
                run: attempt.run,
                to: runtime
            )
        } catch {
            throw await reviewRouteBindingFailure(
                error,
                startError: nil,
                cleanupRun: attempt.run,
                runtime: runtime
            )
        }
        return attempt
    }

    func interruptReview(_ run: CodexReviewBackendModel.Review.Run, reason: CodexReviewBackendModel.CancellationReason) async throws {
        let runtime = try reviewAttemptRuntimeRoutes.runtime(
            for: run.attemptID,
            operation: "interrupt"
        )
        try await runtime.backend.interruptReview(run, reason: reason)
    }

    func interruptReview(
        _ admission: ReviewInterruptRequestAdmission,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws {
        let runtime: LiveRuntimeLifecycleHandle
        do {
            runtime = try reviewAttemptRuntimeRoutes.runtime(
                for: admission.run,
                operation: "typed interrupt"
            )
        } catch {
            throw ReviewInterruptRequestFailure(outcome: .rejected(
                code: nil,
                message: error.localizedDescription
            ))
        }
        try await runtime.backend.interruptReview(admission, reason: reason)
    }

    func beginReviewRecovery(
        _ run: CodexReviewBackendModel.Review.Run,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws -> CodexReviewBackendModel.Review.RecoveryToken {
        let runtime = try reviewAttemptRuntimeRoutes.runtime(
            for: run.attemptID,
            operation: "recovery"
        )
        let token = try await runtime.backend.beginReviewRecovery(run, reason: reason)
        guard reviewAttemptRuntimeRoutes.contains(
            attemptID: run.attemptID,
            runtime: runtime
        ) else {
            throw ReviewAttemptContractFailure(
                message: "Review recovery source route changed before attempt \(run.attemptID) was prepared."
            )
        }
        return token
    }

    func resumeReviewRecovery(
        _ token: CodexReviewBackendModel.Review.RecoveryToken,
        request: CodexReviewBackendModel.Review.Start
    ) async throws -> BackendReviewAttempt {
        let sourceAttemptID = token.interruptedRun.attemptID
        let runtime = try reviewAttemptRuntimeRoutes.runtime(
            for: sourceAttemptID,
            operation: "recovery resume"
        )
        let attempt = try await runtime.backend.resumeReviewRecovery(
            token,
            request: request
        )
        do {
            try reviewAttemptRuntimeRoutes.move(
                sourceAttemptID: sourceAttemptID,
                recoveredRun: attempt.run,
                runtime: runtime
            )
        } catch {
            reviewAttemptRuntimeRoutes.removeIfCurrent(
                attemptID: sourceAttemptID,
                runtime: runtime
            )
            throw await reviewRouteBindingFailure(
                error,
                startError: nil,
                cleanupRun: attempt.run,
                runtime: runtime
            )
        }
        return attempt
    }

    func prepareReviewRecovery(
        _ candidate: ReviewRecoveryCandidate
    ) async throws -> PreparedReviewRecovery {
        let (receipt, runtime) = try reviewAttemptRuntimeRoutes.beginPreparation(candidate)
        do {
            let prepared = PreparedReviewRecovery(
                receipt: receipt,
                handoff: try await runtime.backend.prepareReviewRecovery(candidate)
            )
            try reviewAttemptRuntimeRoutes.finishPreparation(prepared)
            return prepared
        } catch {
            let cleanup = try reviewAttemptRuntimeRoutes.takeInFlight(receipt)
            throw await recoveryFailure(error, cleanup: cleanup)
        }
    }

    func stageReviewRecovery(
        _ prepared: PreparedReviewRecovery,
        destinationGeneration: ReviewRuntimeGeneration,
        request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws(ReviewRecoveryStagingFailure) -> StagedReviewRecovery {
        let destinationAdmissionPhase = await admission.currentPhase()
        do {
            try reviewAttemptRuntimeRoutes.validatePreparedForStaging(prepared)
        } catch {
            throw ReviewRecoveryStagingFailure.backendOwnsRecovery(
                message: error.localizedDescription
            )
        }
        guard destinationAdmissionPhase == .preparingThread(.notSent) else {
            throw ReviewRecoveryStagingFailure.callerRetainsPreparedRecovery(
                message: "Review recovery staging requires one fresh destination admission."
            )
        }
        if prepared.handoff.candidate.trigger == .sameAccountRestart,
           destinationGeneration == prepared.receipt.sourceGeneration {
            throw ReviewRecoveryStagingFailure.callerRetainsPreparedRecovery(
                message: "Same-account recovery requires a replacement runtime generation."
            )
        }
        guard acceptsRuntimeRequests,
              let destination = activeRuntimeHandle,
              destination.generation == destinationGeneration
        else {
            throw ReviewRecoveryStagingFailure.callerRetainsPreparedRecovery(
                message: "Review recovery destination generation \(destinationGeneration.rawValue) is not active."
            )
        }
        do {
            try reviewAttemptRuntimeRoutes.beginStaging(
                prepared,
                destination: destination,
                admission: admission
            )
        } catch {
            throw ReviewRecoveryStagingFailure.backendOwnsRecovery(
                message: error.localizedDescription
            )
        }
        do {
            let attempt = try await destination.backend.resumeReviewRecovery(
                prepared.handoff,
                request: request,
                admission: admission
            )
            guard attempt.run.attemptID != prepared.receipt.sourceRun.attemptID,
                  await admission.currentPhase() == .active(attempt.run)
            else {
                throw ReviewAttemptContractFailure(
                    message: "Review recovery destination did not return one fresh active attempt."
                )
            }
            let staged = StagedReviewRecovery(
                receipt: prepared.receipt,
                destinationGeneration: destinationGeneration,
                attempt: attempt,
                admission: admission
            )
            try reviewAttemptRuntimeRoutes.finishStaging(staged)
            return staged
        } catch {
            let stageFailure = error
            let primaryFailure: any Error
            do {
                try await prepared.handoff.discard()
                primaryFailure = stageFailure
            } catch is ReviewRecoveryHandoffAlreadyConsumed {
                primaryFailure = stageFailure
            } catch {
                primaryFailure = ReviewAttemptContractFailure(
                    message: "\(stageFailure.localizedDescription) Handoff invalidation also failed: \(error.localizedDescription)"
                )
            }
            let provisionalRun = await provisionalRecoveryRun(admission)
            do {
                _ = try reviewAttemptRuntimeRoutes.takeInFlight(
                    prepared.receipt,
                    admission: admission
                )
            } catch {
                throw ReviewRecoveryStagingFailure.backendOwnsRecovery(
                    message: "\(primaryFailure.localizedDescription) Exact recovery route cleanup also failed: \(error.localizedDescription)"
                )
            }
            let failure = await recoveryFailure(
                primaryFailure,
                cleanup: (provisionalRun ?? prepared.receipt.sourceRun, destination)
            )
            throw ReviewRecoveryStagingFailure.backendOwnsRecovery(
                message: failure.localizedDescription
            )
        }
    }

    func commitReviewRecovery(_ staged: StagedReviewRecovery) async throws {
        guard await staged.admission.permitsRecoveryPublication(
            of: staged.attempt.run
        ), acceptsRuntimeRequests else {
            throw ReviewAttemptContractFailure(
                message: "Review recovery commit lost its active admission."
            )
        }
        try reviewAttemptRuntimeRoutes.commit(staged, activeRuntime: activeRuntimeHandle)
    }

    func discardReviewRecovery(_ prepared: PreparedReviewRecovery) async throws {
        try await prepared.handoff.discard()
        let runtime = try reviewAttemptRuntimeRoutes.takePrepared(prepared)
        try await runtime.backend.cleanupReview(prepared.receipt.sourceRun)
    }

    func discardReviewRecovery(_ staged: StagedReviewRecovery) async throws {
        let runtime = try reviewAttemptRuntimeRoutes.takeStaged(staged)
        try await runtime.backend.cleanupReview(staged.attempt.run)
    }

    func cleanupReview(_ run: CodexReviewBackendModel.Review.Run) async throws {
        let runtime: LiveRuntimeLifecycleHandle
        do {
            // Cleanup is a terminal admission, not a retry boundary. AppServer cleanup
            // can partially delete multiple resources before reporting failure, so
            // restoring this route would permit duplicate cleanup side effects.
            runtime = try reviewAttemptRuntimeRoutes.take(
                attemptID: run.attemptID,
                operation: "cleanup"
            )
        } catch {
            throw ReviewRuntimeCloseFailure.cleanup(error.localizedDescription)
        }
        try await runtime.backend.cleanupReview(run)
    }

    private func reviewRouteBindingFailure(
        _ routeError: any Error,
        startError: (any Error)?,
        cleanupRun: CodexReviewBackendModel.Review.Run,
        runtime: LiveRuntimeLifecycleHandle
    ) async -> ReviewAttemptContractFailure {
        var message = routeError.localizedDescription
        if let startError {
            message += " Original review start failure: \(startError.localizedDescription)"
        }
        do {
            try await runtime.backend.cleanupReview(cleanupRun)
        } catch {
            message += " Exact cleanup also failed: \(error.localizedDescription)"
        }
        return ReviewAttemptContractFailure(message: message)
    }

    private func recoveryFailure(
        _ primary: any Error,
        cleanup: (CodexReviewBackendModel.Review.Run, LiveRuntimeLifecycleHandle)
    ) async -> any Error {
        do {
            try await cleanup.1.backend.cleanupReview(cleanup.0)
            return primary
        } catch {
            return ReviewAttemptContractFailure(
                message: "\(primary.localizedDescription) Exact recovery cleanup also failed: \(error.localizedDescription)"
            )
        }
    }

    private func provisionalRecoveryRun(
        _ admission: ReviewStartAdmission
    ) async -> CodexReviewBackendModel.Review.Run? {
        switch await admission.currentPhase() {
        case .startingReview(let run, _), .active(let run),
             .interrupting(let run, _, _), .finishing(let run, _, _, _),
             .recovering(let run, _, _), .finishingRecovery(let run, _, _, _):
            run
        case .terminal(.active(let resolution)):
            resolution.run
        case .preparingThread, .rollingBackRecovery, .terminal:
            nil
        }
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
        stream: AsyncThrowingStream<JSONRPC.Notification, Error>,
        backend: AppServerCodexReviewBackend,
        handle: LiveRuntimeLifecycleHandle,
        store: CodexReviewStore
    ) {
        authNotificationTask?.cancel()
        authNotificationTask = Task { @MainActor [weak self, weak store] in
            guard let self, let store else {
                return
            }
            do {
                for try await notification in stream {
                    guard self.activeRuntimeHandle === handle,
                          self.acceptsRuntimeRequests
                    else {
                        return
                    }
                    await self.handleAuthNotification(
                        notification,
                        backend: backend,
                        expectedRuntimeHandle: handle,
                        auth: store.auth
                    )
                }
            } catch is CancellationError {
            } catch {
                logger.error("Auth notification stream ended: \(error.localizedDescription, privacy: .public)")
                markRuntimeFailedAfterNotificationStreamError(
                    error,
                    handle: handle,
                    store: store
                )
            }
        }
    }

    private func markRuntimeFailedAfterNotificationStreamError(
        _ error: any Error,
        handle: LiveRuntimeLifecycleHandle,
        store: CodexReviewStore
    ) {
        guard activeRuntimeHandle === handle else {
            return
        }
        authNotificationTask = nil
        store.requestRuntimeFailure(
            handle: handle,
            cause: error.localizedDescription
        )
    }

    private func handleAuthNotification(
        _ notification: JSONRPC.Notification,
        backend: AppServerCodexReviewBackend,
        expectedRuntimeHandle: LiveRuntimeLifecycleHandle,
        auth: CodexReviewAuthModel
    ) async {
        guard activeRuntimeHandle === expectedRuntimeHandle,
              acceptsRuntimeRequests
        else {
            return
        }
        switch notification.method {
        case "account/login/completed":
            await handleLoginCompletedNotification(
                notification,
                backend: backend,
                expectedRuntimeHandle: expectedRuntimeHandle,
                auth: auth
            )
        case "account/updated":
            await handleAccountUpdatedNotification(
                backend: backend,
                expectedRuntimeHandle: expectedRuntimeHandle,
                auth: auth
            )
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
        expectedRuntimeHandle: LiveRuntimeLifecycleHandle? = nil,
        auth: CodexReviewAuthModel
    ) async {
        if let expectedRuntimeHandle {
            guard activeRuntimeHandle === expectedRuntimeHandle,
                  acceptsRuntimeRequests
            else {
                return
            }
        }
        guard notification.method == "account/login/completed" else {
            await handleAccountUpdatedNotification(
                backend: backend,
                expectedRuntimeHandle: expectedRuntimeHandle,
                auth: auth
            )
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
            if let expectedRuntimeHandle {
                guard activeRuntimeHandle === expectedRuntimeHandle,
                      acceptsRuntimeRequests
                else {
                    return
                }
            }
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
        expectedRuntimeHandle: LiveRuntimeLifecycleHandle? = nil,
        auth: CodexReviewAuthModel
    ) async {
        if let expectedRuntimeHandle {
            guard activeRuntimeHandle === expectedRuntimeHandle,
                  acceptsRuntimeRequests
            else {
                return
            }
        }
        guard isWaitingForLoginAccountUpdate else {
            await refreshAuthAfterAccountNotification(
                backend: backend,
                expectedRuntimeHandle: expectedRuntimeHandle,
                auth: auth
            )
            return
        }
        await finishCompletedLoginAfterAccountUpdate(
            backend: backend,
            expectedRuntimeHandle: expectedRuntimeHandle,
            auth: auth
        )
    }

    private func finishCompletedLoginAfterAccountUpdate(
        backend: AppServerCodexReviewBackend,
        expectedRuntimeHandle: LiveRuntimeLifecycleHandle? = nil,
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
            let snapshot = try await backend.readAuth()
            if let expectedRuntimeHandle {
                guard activeRuntimeHandle === expectedRuntimeHandle,
                      acceptsRuntimeRequests
                else {
                    return
                }
            }
            let account = applyAuthSnapshot(
                snapshot,
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
        expectedRuntimeHandle requestedRuntimeHandle: LiveRuntimeLifecycleHandle? = nil,
        auth: CodexReviewAuthModel
    ) async {
        let expectedRuntimeHandle = requestedRuntimeHandle ?? activeRuntimeHandle
        guard acceptsRuntimeRequests,
              let expectedRuntimeHandle,
              activeRuntimeHandle === expectedRuntimeHandle,
              expectedRuntimeHandle.backend === backend
        else {
            return
        }
        do {
            let snapshot = try await backend.readAuth()
            guard activeRuntimeHandle === expectedRuntimeHandle,
                  acceptsRuntimeRequests
            else {
                return
            }
            applyAuthSnapshot(snapshot, to: auth)
            await refreshSelectedAccountRateLimits(auth: auth)
        } catch {
            guard activeRuntimeHandle === expectedRuntimeHandle,
                  acceptsRuntimeRequests
            else {
                return
            }
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

    private func refreshSelectedAccountRateLimits(
        auth: CodexReviewAuthModel,
        expectedRuntimeHandle: LiveRuntimeLifecycleHandle? = nil
    ) async {
        guard let selectedAccount = auth.selectedAccount else {
            return
        }
        await refreshRateLimits(
            for: selectedAccount,
            auth: auth,
            expectedRuntimeHandle: expectedRuntimeHandle
        )
    }

    private func refreshRateLimits(
        for account: CodexAccount,
        auth: CodexReviewAuthModel,
        expectedRuntimeHandle requestedRuntimeHandle: LiveRuntimeLifecycleHandle? = nil
    ) async {
        guard account.capabilities.supportsRateLimitRefresh else {
            return
        }
        guard auth.persistedActiveAccountKey == account.accountKey else {
            await refreshSavedAccountRateLimits(for: account)
            return
        }
        let expectedRuntimeHandle = requestedRuntimeHandle ?? activeRuntimeHandle
        guard acceptsRuntimeRequests,
              let expectedRuntimeHandle,
              activeRuntimeHandle === expectedRuntimeHandle
        else {
            return
        }
        let didRefresh = await refreshRateLimits(
            for: account,
            using: appServerBackend,
            source: "active-runtime",
            expectedRuntimeHandle: expectedRuntimeHandle
        )
        guard activeRuntimeHandle === expectedRuntimeHandle,
              acceptsRuntimeRequests
        else {
            return
        }
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
        source: String,
        expectedRuntimeHandle: LiveRuntimeLifecycleHandle? = nil
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
            if let expectedRuntimeHandle {
                guard activeRuntimeHandle === expectedRuntimeHandle,
                      acceptsRuntimeRequests
                else {
                    return false
                }
            }
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
            if let expectedRuntimeHandle,
               (activeRuntimeHandle !== expectedRuntimeHandle || acceptsRuntimeRequests == false)
            {
                return false
            }
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
            await closeClientRecordingFailure(client, context: "login runtime cleanup")
            return
        }
        guard codexHomeURL != self.codexHomeURL else {
            return
        }
        await closeClientRecordingFailure(client, context: "isolated login runtime cleanup")
        try? FileManager.default.removeItem(at: codexHomeURL)
    }

    private func closeAppServerRuntime(
        backend: AppServerCodexReviewBackend?,
        fallbackClient: AppServerClient?,
        context: String
    ) async {
        guard let backend else {
            await closeClientRecordingFailure(fallbackClient, context: context)
            return
        }
        let lifecycle = backend.runtimeOwnerLifecycleHandle
        await lifecycle.closeAdmission()
        do {
            try await lifecycle.closeAndWait()
        } catch {
            logger.error(
                "Failed to close app-server during \(context, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func closeClientRecordingFailure(
        _ client: AppServerClient?,
        context: String
    ) async {
        guard let client else {
            return
        }
        do {
            try await client.close()
        } catch {
            logger.error(
                "Failed to close app-server client during \(context, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
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
    fileprivate let generation: ReviewRuntimeGeneration
    fileprivate let client: AppServerClient
    fileprivate let backend: AppServerCodexReviewBackend
    fileprivate let authNotificationStream: AsyncThrowingStream<JSONRPC.Notification, Error>
    fileprivate let snapshot: RuntimePublicationSnapshot
    fileprivate var initialRateLimitTask: Task<Void, Never>?

    private weak var owner: LiveCodexReviewStoreBackend?
    private var isActivated = false
    private var closeTask: Task<Result<Void, any Error>, Never>?

    init(
        owner: LiveCodexReviewStoreBackend,
        generation: ReviewRuntimeGeneration,
        client: AppServerClient,
        backend: AppServerCodexReviewBackend,
        authNotificationStream: AsyncThrowingStream<JSONRPC.Notification, Error>,
        snapshot: RuntimePublicationSnapshot
    ) {
        self.owner = owner
        self.generation = generation
        self.client = client
        self.backend = backend
        self.authNotificationStream = authNotificationStream
        self.snapshot = snapshot
    }

    func activate() async throws {
        guard isActivated == false, closeTask == nil, let owner else {
            throw CancellationError()
        }
        try owner.activateRuntime(self)
        isActivated = true
    }

    func closeAdmission() {
        owner?.closeRuntimeAdmission(self)
    }

    func close(purpose _: ReviewRuntimeTransitionPurpose) async throws {
        let task: Task<Result<Void, any Error>, Never>
        if let closeTask {
            task = closeTask
        } else {
            let authObservationTask = owner?.deactivateRuntime(self)
            let initialRateLimitTask = initialRateLimitTask
            self.initialRateLimitTask = nil
            let lifecycle = backend.runtimeOwnerLifecycleHandle
            let created = Task<Result<Void, any Error>, Never> { @MainActor in
                authObservationTask?.cancel()
                initialRateLimitTask?.cancel()
                let result: Result<Void, any Error>
                do {
                    await lifecycle.closeAdmission()
                    try await lifecycle.closeAndWait()
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
                await authObservationTask?.value
                await initialRateLimitTask?.value
                return result
            }
            closeTask = created
            task = created
        }
        try await task.value.get()
    }

    func waitUntilClosed() async throws {
        guard let closeTask else {
            throw CancellationError()
        }
        try await closeTask.value.get()
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
private typealias ResolvedAppServerRuntimeFactory = @MainActor @Sendable (
    URL,
    URL
) async throws -> AppServerRuntime

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
