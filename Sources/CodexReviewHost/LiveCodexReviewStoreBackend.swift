import AppKit
import Foundation
import OSLog
import CodexReview
import CodexReviewAppServer
import CodexReviewMCPServer
import CodexReviewPersistence

private let logger = Logger(subsystem: "CodexReviewKit", category: "live-store-backend")
private typealias ExternalURLOpener = @MainActor @Sendable (URL) -> Void
private typealias LoginActivation = LiveAuthenticationOperation.Activation

private let defaultExternalURLOpener: ExternalURLOpener = { url in
    _ = NSWorkspace.shared.open(url)
}

private enum RuntimeShutdownCleanupOutcome<Value: Sendable>: Sendable {
    case completed(Value)
    case timedOut
}

private actor RuntimeShutdownCleanupRace<Value: Sendable> {
    private var result: RuntimeShutdownCleanupOutcome<Value>?
    private var continuation: CheckedContinuation<RuntimeShutdownCleanupOutcome<Value>, Never>?

    func finish(_ value: RuntimeShutdownCleanupOutcome<Value>) {
        guard result == nil else {
            return
        }
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }

    func wait() async -> RuntimeShutdownCleanupOutcome<Value> {
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

private func runRuntimeShutdownCleanup<Value: Sendable>(
    timeout: Duration,
    operation: @escaping @Sendable () async -> Value
) async -> RuntimeShutdownCleanupOutcome<Value> {
    let race = RuntimeShutdownCleanupRace<Value>()
    let operationTask = Task {
        let value = await operation()
        await race.finish(.completed(value))
    }
    let timeoutTask = Task {
        do {
            try await Task.sleep(for: timeout)
        } catch {
            return
        }
        await race.finish(.timedOut)
    }
    let result = await race.wait()
    switch result {
    case .completed:
        timeoutTask.cancel()
    case .timedOut:
        operationTask.cancel()
    }
    return result
}

private struct PendingAuthenticationResources {
    private(set) var isOwned = true
    var backend: AppServerCodexReviewBackend?
    var challenge: CodexReviewBackendModel.Login.Challenge?
    var client: AppServerClient?
    var codexHomeURL: URL?

    mutating func takeForCleanup() -> Self? {
        guard isOwned else {
            return nil
        }
        let resources = self
        isOwned = false
        backend = nil
        challenge = nil
        client = nil
        codexHomeURL = nil
        return resources
    }

    @MainActor
    mutating func consume(
        into operation: LiveAuthenticationOperation
    ) -> LiveAuthenticationOperation.ResourceScope? {
        guard operation.resourceScope == nil else { return nil }
        guard let resources = takeForCleanup() else {
            return nil
        }
        return operation.installResources(.init(
            challenge: resources.challenge,
            backend: resources.backend,
            client: resources.client,
            codexHomeURL: resources.codexHomeURL
        ))
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
        makeLiveStore(
            runtimePreferences: runtimePreferences,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory,
            diagnosticsURL: nil,
            historyPersistence: makeLiveReviewHistoryPersistence()
        )
    }

    @_spi(ApplicationHostSupport)
    static func makeUnavailableReviewMonitorStore(
        diagnosticsURL: URL?,
        reviewHistoryFailureMessage: String
    ) -> CodexReviewStore {
        let store = CodexReviewStore(
            backend: PreviewCodexReviewStoreBackend(),
            diagnosticsURL: diagnosticsURL,
            historyPersistence: UnavailableReviewHistoryPersistence(
                message: reviewHistoryFailureMessage
            )
        )
        store.publishReviewHistoryFailure(ReviewHistoryOperationFailure(
            message: reviewHistoryFailureMessage
        ))
        return store
    }

    @_spi(ApplicationHostSupport)
    static func makeLiveStore(
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        nativeAuthenticationConfiguration: CodexReviewNativeAuthentication.Configuration? = nil,
        webAuthenticationSessionFactory: @escaping CodexReviewNativeAuthentication.WebSessionFactory = CodexReviewNativeAuthentication.WebSessions.system,
        diagnosticsURL: URL?,
        reviewHistoryDatabaseURL: URL
    ) -> CodexReviewStore {
        makeLiveStore(
            runtimePreferences: runtimePreferences,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory,
            diagnosticsURL: diagnosticsURL,
            historyPersistence: makeExplicitReviewHistoryPersistence(
                databaseURL: reviewHistoryDatabaseURL
            )
        )
    }

    private static func makeLiveStore(
        runtimePreferences: CodexReviewRuntime.Preferences,
        nativeAuthenticationConfiguration: CodexReviewNativeAuthentication.Configuration?,
        webAuthenticationSessionFactory: @escaping CodexReviewNativeAuthentication.WebSessionFactory,
        diagnosticsURL: URL?,
        historyPersistence: any ReviewHistoryPersistence
    ) -> CodexReviewStore {
        CodexReviewStore(
            backend: LiveCodexReviewStoreBackend(
                runtimePreferences: runtimePreferences,
                nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
                webAuthenticationSessionFactory: webAuthenticationSessionFactory
            ),
            diagnosticsURL: diagnosticsURL,
            historyPersistence: historyPersistence
        )
    }

    private static func makeExplicitReviewHistoryPersistence(
        databaseURL: URL
    ) -> any ReviewHistoryPersistence {
        guard databaseURL.isFileURL,
              databaseURL.path.hasPrefix("/"),
              databaseURL.host == nil || databaseURL.host == ""
        else {
            return UnavailableReviewHistoryPersistence(
                DirectoryCapabilityError.invalidRequest(
                    "The explicit review history database requires an absolute local file URL."
                )
            )
        }
        return ReviewHistoryDatabase(databaseURL: databaseURL)
    }

    private static func makeLiveReviewHistoryPersistence() -> any ReviewHistoryPersistence {
        do {
            let location = try ReviewHistoryLocation.prepareProduction()
            do {
                return OwnedReviewHistoryPersistence(
                    location: location,
                    databaseURL: try location.databaseURL()
                )
            } catch {
                try? location.close()
                throw error
            }
        } catch {
            return UnavailableReviewHistoryPersistence(error)
        }
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

    package func waitForLiveAuthNotificationCompletionForTesting(
        _ receipt: JSONRPC.NotificationReceipt
    ) async {
        guard let backend = backend as? LiveCodexReviewStoreBackend else { return }
        await backend.waitForPrimaryAuthNotificationCompletionForTesting(receipt)
    }
}

@MainActor
private final class LiveCodexReviewStoreBackend: CodexReviewStoreBackend, MCPServerLifecycleOwner {
    private enum AuthenticationRollbackAuthority {
        case captured(accountKey: String?)
        case current(fallbackAccountKey: String?)

        @MainActor
        func resolveAccountKey(auth: CodexReviewAuthModel?) -> String? {
            switch self {
            case .captured(let accountKey):
                accountKey
            case .current(let fallbackAccountKey):
                auth?.persistedActiveAccountKey
                    ?? auth?.selectedAccount?.accountKey
                    ?? fallbackAccountKey
            }
        }
    }

    private enum PreparedAuthenticationAccount {
        case metadata(CodexAccount)
        case metadataAndRateLimits(CodexAccount)

        var account: CodexAccount {
            switch self {
            case .metadata(let account), .metadataAndRateLimits(let account):
                account
            }
        }

        var includesRateLimitState: Bool {
            if case .metadataAndRateLimits = self {
                return true
            }
            return false
        }

        func includingRateLimitState() -> Self {
            .metadataAndRateLimits(account)
        }
    }

    private struct RetiredPrimaryAuthenticationRoute {
        let runtime: LiveRuntimeLifecycleHandle
        let afterReceipt: JSONRPC.NotificationReceipt
        let throughReceipt: JSONRPC.NotificationReceipt
        let loginID: String?
        let rollbackAccountKey: String?
        let requiresRollbackAfterRuntimeClose: Bool
        var awaitsLateLoginCompletion: Bool

        func contains(_ receipt: JSONRPC.NotificationReceipt) -> Bool {
            receipt > afterReceipt && receipt <= throughReceipt
        }
    }

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
    private var activeAuthenticationOperation: LiveAuthenticationOperation?
    private var primaryAuthenticationLifecycleGeneration: UInt64 = 0
    private var retiredPrimaryAuthenticationRoutes: [RetiredPrimaryAuthenticationRoute] = []
    private var completedPrimaryAuthNotificationReceipt = JSONRPC.NotificationReceipt.beforeFirst
    private var primaryAuthNotificationCompletionWaiters: [(
        JSONRPC.NotificationReceipt,
        CheckedContinuation<Void, Never>
    )] = []
    private var authNotificationTask: Task<Void, Never>?
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
        resetPrimaryAuthNotificationRouting()
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
        handle.requiresAuthenticationRollbackAfterClose =
            handle.requiresAuthenticationRollbackAfterClose
            || activeAuthenticationOperation.map {
                $0.primaryNotificationRouteGeneration != nil
                    && $0.terminalPublicationOwner != .notification
            } == true
            || retiredPrimaryAuthenticationRoutes.contains {
                $0.runtime === handle && $0.requiresRollbackAfterRuntimeClose
            }
        activeRuntimeHandle = nil
        acceptsRuntimeRequests = false
        client = nil
        appServerBackend = nil
        resetPrimaryAuthNotificationRouting()
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
        let workerJobIDs = store.reviewWorkerJobIDsForRuntimeStop
        let cancellationCleanup = await runRuntimeShutdownCleanup(
            timeout: shutdownCleanupTimeout
        ) {
            await store.requestActiveReviewCancellationsForRuntimeStop(reason: reason)
        }
        let cancellationJobIDs: [String]
        let didRequestCancellation: Bool
        let cancellationTimedOut: Bool
        switch cancellationCleanup {
        case .completed(let outcome):
            cancellationJobIDs = outcome.jobIDs
            didRequestCancellation = outcome.firstFailure == nil
            cancellationTimedOut = false
            if let failure = outcome.firstFailure {
                logger.error(
                    "Failed to request active review cancellation before runtime teardown: \(failure.localizedDescription, privacy: .public)"
                )
            }
        case .timedOut:
            cancellationJobIDs = []
            didRequestCancellation = false
            cancellationTimedOut = true
        }
        if didRequestCancellation == false {
            let lifecycle = appServerBackend.runtimeOwnerLifecycleHandle
            await lifecycle.closeAdmission()
            do {
                try await lifecycle.closeAndWait()
            } catch {
                logger.error(
                    "Failed to force-close app-server during review cancellation fallback: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        let locallyCancelledJobIDs = store.cancelActiveReviewsLocallyForRuntimeStop(
            reason: reason
        )
        let currentWorkerJobIDs = store.reviewWorkerJobIDsForRuntimeStop
        await store.cancelAndDetachReviewWorkersForRuntimeStop(
            jobIDs: Array(Set(
                workerJobIDs
                    + cancellationJobIDs
                    + locallyCancelledJobIDs
                    + currentWorkerJobIDs
            )),
            reason: reason
        )
        let didDrainReviewWorkers = await store.drainReviewWorkersForRuntimeStop(
            timeout: shutdownCleanupTimeout
        )
        if cancellationTimedOut || didDrainReviewWorkers == false {
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
        let operation = activeAuthenticationOperation
        operation?.beginCancellation()
        if await waitForAuthenticationSetup(operation) == false {
            logger.warning("Authentication setup did not stop before runtime teardown continued")
        }
        let loginCleanup = takeLoginRuntimeForCleanup(operation)
        guard appServerBackend != nil || loginCleanup.isEmpty == false else {
            await removeActiveAuthenticationOperation(operation)
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
        await removeActiveAuthenticationOperation(operation)
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
              let expectedRuntimeHandle = activeRuntimeHandle,
              activeAuthenticationOperation?.primaryNotificationRouteGeneration == nil
        else {
            return
        }
        let expectedAuthenticationGeneration = primaryAuthenticationLifecycleGeneration
        do {
            guard let appServerBackend else {
                auth.updatePhase(.signedOut)
                return
            }
            let snapshot = try await appServerBackend.readAuth()
            guard activeRuntimeHandle === expectedRuntimeHandle,
                  acceptsRuntimeRequests,
                  primaryAuthenticationLifecycleGeneration == expectedAuthenticationGeneration,
                  activeAuthenticationOperation?.primaryNotificationRouteGeneration == nil
            else {
                return
            }
            applyAuthSnapshot(snapshot, to: auth)
        } catch {
            guard activeRuntimeHandle === expectedRuntimeHandle,
                  acceptsRuntimeRequests,
                  primaryAuthenticationLifecycleGeneration == expectedAuthenticationGeneration,
                  activeAuthenticationOperation?.primaryNotificationRouteGeneration == nil
            else {
                return
            }
            auth.updatePhase(.failed(message: error.localizedDescription))
        }
    }

    func signIn(auth: CodexReviewAuthModel, using method: CodexReviewAuthenticationMethod) async {
        await startOrJoinAuthenticationOperation(
            auth: auth,
            activation: .activateAuthenticatedAccount,
            method: method
        )
    }

    func addAccount(auth: CodexReviewAuthModel, using method: CodexReviewAuthenticationMethod) async {
        let activeAccountKey = auth.persistedActiveAccountKey ?? auth.selectedAccount?.accountKey
        await startOrJoinAuthenticationOperation(
            auth: auth,
            activation: activeAccountKey != nil
                ? .preserveActiveAccount(activeAccountKey)
                : .activateAuthenticatedAccount,
            method: method
        )
    }

    func cancelAuthentication(auth: CodexReviewAuthModel) async {
        let operation = activeAuthenticationOperation
        operation?.beginCancellation()
        let didStopSetup = await waitForAuthenticationSetup(operation)
        if didStopSetup == false,
           operation?.hasAdmittedAPIKeyRequest == true,
           let activeRuntimeHandle
        {
            _ = attachedStore?.requestRuntimeFailure(
                handle: activeRuntimeHandle,
                cause: "API key authentication did not stop after cancellation."
            )
        }
        let scope = operation?.resourceScope
        let cleanup = takeLoginRuntimeForCleanup(operation)
        await cleanup.authenticationSession?.cancel()
        if operation?.phase == .terminalSuccessCommitted {
            await closeIsolatedLoginRuntime(
                client: cleanup.client,
                codexHomeURL: cleanup.codexHomeURL
            )
            await removeActiveAuthenticationOperation(operation)
            return
        }
        guard let loginBackend = cleanup.backend, let loginChallenge = cleanup.challenge else {
            if isActiveAuthenticationOperation(operation),
               operation == nil || operation?.terminalPublicationOwner == .userCancellation
            {
                auth.updatePhase(.signedOut)
            }
            await closeIsolatedLoginRuntime(client: cleanup.client, codexHomeURL: cleanup.codexHomeURL)
            await removeActiveAuthenticationOperation(operation)
            return
        }
        do {
            try await loginBackend.cancelLogin(loginChallenge)
            if isActiveAuthenticationOperation(operation),
               operation?.isCurrent(scope) != false,
               operation?.terminalPublicationOwner == .userCancellation
            {
                auth.updatePhase(.signedOut)
            }
        } catch {
            if isActiveAuthenticationOperation(operation),
               operation?.isCurrent(scope) != false,
               operation?.terminalPublicationOwner == .userCancellation
            {
                auth.updatePhase(.failed(message: error.localizedDescription))
            }
        }
        await closeIsolatedLoginRuntime(client: cleanup.client, codexHomeURL: cleanup.codexHomeURL)
        await removeActiveAuthenticationOperation(operation)
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
        guard activeAuthenticationOperation?.primaryNotificationRouteGeneration == nil,
              let account = auth.accounts.first(where: { $0.accountKey == accountKey })
        else {
            return
        }
        await refreshRateLimits(
            for: account,
            auth: auth,
            expectedAuthenticationGeneration: primaryAuthenticationLifecycleGeneration
        )
    }

    func requiresCurrentSessionRecovery(auth _: CodexReviewAuthModel, accountKey _: String) -> Bool {
        false
    }

    private func startOrJoinAuthenticationOperation(
        auth: CodexReviewAuthModel,
        activation: LoginActivation,
        method: CodexReviewAuthenticationMethod
    ) async {
        if let activeAuthenticationOperation {
            await activeAuthenticationOperation.waitForSetup()
            return
        }
        let operation = LiveAuthenticationOperation(
            activation: activation,
            method: method,
            rollbackAccountKey: auth.persistedActiveAccountKey ?? auth.selectedAccount?.accountKey
        )
        activeAuthenticationOperation = operation
        let setupTask = Task { @MainActor [weak self, weak auth, operation] in
            guard let self, let auth else { return }
            await self.runAuthenticationSetup(operation: operation, auth: auth)
        }
        operation.install(setupTask: setupTask)
        await operation.waitForSetup()
    }

    private func runAuthenticationSetup(
        operation: LiveAuthenticationOperation,
        auth: CodexReviewAuthModel
    ) async {
        let activation = operation.activation
        if case .apiKey = operation.method,
           auth.persistedAccounts.contains(where: { $0.kind == .apiKey })
        {
            updateAuthenticationFailure(
                "An API key account is already added.",
                auth: auth,
                activation: activation
            )
            await removeActiveAuthenticationOperation(operation)
            return
        }
        if case .apiKey = operation.method {
            auth.updatePhase(.signingIn(.init(
                title: "Sign in with API key",
                detail: "Signing in with API key."
            )))
        }
        var pendingResources = PendingAuthenticationResources()
        var admittedScope: LiveAuthenticationOperation.ResourceScope?
        let expectedRuntimeHandle = activeRuntimeHandle
        do {
            let runtime = try await loginRuntime(for: activation)
            let appServerBackend = runtime.backend
            let loginCodexHomeURL = runtime.codexHomeURL
            let loginClient = runtime.usesPrimaryRuntime ? nil : runtime.client
            pendingResources.backend = appServerBackend
            pendingResources.client = loginClient
            pendingResources.codexHomeURL = loginCodexHomeURL
            let primaryNotificationRouteStartReceipt: JSONRPC.NotificationReceipt?
            if runtime.usesPrimaryRuntime {
                primaryAuthenticationLifecycleGeneration += 1
                operation.installPrimaryNotificationRoute(
                    generation: primaryAuthenticationLifecycleGeneration,
                    completedReceipt: completedPrimaryAuthNotificationReceipt
                )
                primaryNotificationRouteStartReceipt = await appServerBackend.notificationHighWatermark()
            } else {
                primaryNotificationRouteStartReceipt = nil
            }
            guard activeAuthenticationOperation === operation,
                  Task.isCancelled == false,
                  isCurrentRuntime(expectedRuntimeHandle)
            else {
                if Task.isCancelled, activeAuthenticationOperation === operation {
                    _ = pendingResources.consume(into: operation)
                    return
                }
                await cleanupPendingAuthenticationResources(pendingResources.takeForCleanup())
                if Task.isCancelled == false {
                    await removeActiveAuthenticationOperation(operation)
                }
                return
            }
            if let primaryNotificationRouteStartReceipt {
                operation.installPrimaryNotificationRoute(after: primaryNotificationRouteStartReceipt)
            }
            guard runtime.usesPrimaryRuntime || self.appServerBackend != nil else {
                logger.error("Cannot start login because review runtime is not running")
                updateAuthenticationFailure(
                    "Review runtime is not running.",
                    auth: auth,
                    activation: activation
                )
                await cleanupPendingAuthenticationResources(pendingResources.takeForCleanup())
                if Task.isCancelled == false {
                    await removeActiveAuthenticationOperation(operation)
                }
                return
            }
            if case .apiKey(let apiKey) = operation.method {
                guard let scope = pendingResources.consume(into: operation) else {
                    await cleanupPendingAuthenticationResources(pendingResources.takeForCleanup())
                    if Task.isCancelled == false {
                        await removeActiveAuthenticationOperation(operation)
                    }
                    return
                }
                admittedScope = scope
                await runAPIKeyAuthenticationSetup(
                    operation: operation,
                    scope: scope,
                    apiKey: apiKey,
                    backend: appServerBackend,
                    usesPrimaryRuntime: runtime.usesPrimaryRuntime,
                    expectedRuntimeHandle: expectedRuntimeHandle,
                    auth: auth
                )
                return
            }
            logger.info("Starting ChatGPT login")
            if runtime.usesPrimaryRuntime {
                operation.beginPrimaryChatGPTLoginStart()
            }
            let challenge: CodexReviewBackendModel.Login.Challenge
            do {
                challenge = try await appServerBackend.startLogin(.init(
                    nativeWebAuthenticationCallbackScheme: nativeAuthenticationConfiguration?.callbackScheme
                ))
            } catch {
                if runtime.usesPrimaryRuntime {
                    if Self.loginStartOutcomeMayBeUnknown(error) {
                        operation.markPrimaryChatGPTLoginStartOutcomeUnknown()
                    } else {
                        operation.rejectPrimaryChatGPTLoginStart()
                    }
                }
                throw error
            }
            pendingResources.challenge = challenge
            let primaryNotificationReplay = runtime.usesPrimaryRuntime
                ? operation.receivePrimaryChatGPTLoginChallenge(loginID: challenge.id)
                : nil
            if Task.isCancelled,
               let primaryNotificationReplay,
               primaryNotificationReplay.success == false
            {
                let didCommitFailure = operation.beginTerminalFailure(
                    publicationOwner: primaryNotificationReplay.terminalPublicationOwner
                )
                if didCommitFailure,
                   primaryNotificationReplay.terminalPublicationOwner == .notification,
                   activeAuthenticationOperation === operation,
                   let expectedRuntimeHandle,
                   activeRuntimeHandle === expectedRuntimeHandle,
                   acceptsRuntimeRequests
                {
                    updateAuthenticationFailure(
                        primaryNotificationReplay.error ?? "Authentication failed.",
                        auth: auth,
                        activation: activation
                    )
                }
            }
            guard activeAuthenticationOperation === operation,
                  Task.isCancelled == false,
                  let expectedRuntimeHandle,
                  activeRuntimeHandle === expectedRuntimeHandle,
                  acceptsRuntimeRequests
            else {
                if Task.isCancelled, activeAuthenticationOperation === operation {
                    _ = pendingResources.consume(into: operation)
                    return
                }
                await cleanupPendingAuthenticationResources(pendingResources.takeForCleanup())
                if Task.isCancelled == false {
                    await removeActiveAuthenticationOperation(operation)
                }
                return
            }
            guard let scope = pendingResources.consume(into: operation) else {
                await cleanupPendingAuthenticationResources(pendingResources.takeForCleanup())
                if Task.isCancelled == false {
                    await removeActiveAuthenticationOperation(operation)
                }
                return
            }
            admittedScope = scope
            if let loginClient {
                observeLoginNotifications(
                    operation: operation,
                    scope: scope,
                    client: loginClient,
                    backend: appServerBackend,
                    auth: auth
                )
            }
            if let primaryNotificationReplay {
                await handleLoginCompletedNotification(
                    primaryNotificationReplay.completion,
                    operation: operation,
                    scope: scope,
                    backend: appServerBackend,
                    expectedRuntimeHandle: expectedRuntimeHandle,
                    auth: auth
                )
                if primaryNotificationReplay.includesAccountUpdate,
                   activeAuthenticationOperation === operation,
                   operation.authorizesSharedStateCommit(from: scope),
                   operation.phase == .waitingForAccountUpdate,
                   scope.isOpen
                {
                    await handleAccountUpdatedNotification(
                        operation: operation,
                        scope: scope,
                        backend: appServerBackend,
                        expectedRuntimeHandle: expectedRuntimeHandle,
                        auth: auth
                    )
                }
                return
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
                operation.beginTerminalAbort()
                guard let cleanup = scope.takeForCleanup() else { return }
                cleanup.notificationTask?.cancel()
                if let backend = cleanup.backend, let challenge = cleanup.challenge {
                    try? await backend.cancelLogin(challenge)
                }
                if activeAuthenticationOperation === operation,
                   operation.isCurrent(scope),
                   Task.isCancelled == false
                {
                    updateAuthenticationFailure(
                        "Authentication callback is misconfigured.",
                        auth: auth,
                        activation: activation
                    )
                }
                await closeIsolatedLoginRuntime(client: cleanup.client, codexHomeURL: cleanup.codexHomeURL)
                if Task.isCancelled == false {
                    await removeActiveAuthenticationOperation(operation)
                }
                return
            }
            let session = try await webAuthenticationSessionFactory(
                authURL,
                callbackScheme,
                nativeAuthenticationConfiguration.browserSessionPolicy,
                nativeAuthenticationConfiguration.presentationAnchorProvider
            )
            guard activeAuthenticationOperation === operation,
                  Task.isCancelled == false,
                  activeRuntimeHandle === expectedRuntimeHandle,
                  acceptsRuntimeRequests,
                  operation.isCurrent(scope),
                  scope.isOpen
            else {
                if Task.isCancelled, activeAuthenticationOperation === operation, scope.isOpen {
                    scope.install(session: session)
                    return
                }
                operation.beginTerminalAbort()
                let cleanup = scope.takeForCleanup()
                cleanup?.notificationTask?.cancel()
                await session.cancel()
                try? await appServerBackend.cancelLogin(challenge)
                await closeIsolatedLoginRuntime(client: cleanup?.client, codexHomeURL: cleanup?.codexHomeURL)
                if Task.isCancelled == false {
                    await removeActiveAuthenticationOperation(operation)
                }
                return
            }
            let monitorTask = Task { @MainActor [weak self, weak auth, weak operation, weak scope] in
                guard let self, let auth, let operation, let scope else {
                    return
                }
                await self.monitorAuthenticationSession(
                    operation: operation,
                    scope: scope,
                    challenge: challenge,
                    session: session,
                    completesLoginThroughCallback: nativeCallbackScheme != nil,
                    auth: auth
                )
            }
            scope.install(session: session, monitorTask: monitorTask)
        } catch {
            if let pendingCleanup = pendingResources.takeForCleanup() {
                await cleanupPendingAuthenticationResources(pendingCleanup)
                guard activeAuthenticationOperation === operation,
                      Task.isCancelled == false else { return }
                logger.error("ChatGPT login failed to start: \(error.localizedDescription, privacy: .public)")
                updateAuthenticationFailure(
                    error.localizedDescription,
                    auth: auth,
                    activation: activation
                )
                await removeActiveAuthenticationOperation(operation)
                return
            }
            guard let admittedScope else { return }
            operation.beginTerminalAbort()
            let cleanup = admittedScope.takeForCleanup()
            cleanup?.notificationTask?.cancel()
            if cleanup != nil,
               activeAuthenticationOperation === operation,
               operation.isCurrent(admittedScope),
               Task.isCancelled == false
            {
                operation.beginResourceCleanup()
            }
            cleanup?.monitorTask?.cancel()
            if let pendingLoginBackend = cleanup?.backend, let pendingLoginChallenge = cleanup?.challenge {
                try? await pendingLoginBackend.cancelLogin(pendingLoginChallenge)
            }
            await closeIsolatedLoginRuntime(client: cleanup?.client, codexHomeURL: cleanup?.codexHomeURL)
            guard cleanup != nil,
                  activeAuthenticationOperation === operation,
                  operation.isCurrent(admittedScope),
                  Task.isCancelled == false else { return }
            logger.error("ChatGPT login failed to start: \(error.localizedDescription, privacy: .public)")
            updateAuthenticationFailure(
                error.localizedDescription,
                auth: auth,
                activation: activation
            )
            await removeActiveAuthenticationOperation(operation)
        }
    }

    private func runAPIKeyAuthenticationSetup(
        operation: LiveAuthenticationOperation,
        scope: LiveAuthenticationOperation.ResourceScope,
        apiKey: CodexReviewAPIKey,
        backend: AppServerCodexReviewBackend,
        usesPrimaryRuntime: Bool,
        expectedRuntimeHandle: LiveRuntimeLifecycleHandle?,
        auth: CodexReviewAuthModel
    ) async {
        guard operation.admitAPIKeyRequest() else {
            let cleanup = scope.takeForCleanup()
            await closeIsolatedLoginRuntime(
                client: cleanup?.client,
                codexHomeURL: cleanup?.codexHomeURL
            )
            if activeAuthenticationOperation === operation,
               operation.authorizesSharedStateCommit(from: scope)
            {
                auth.updatePhase(.signedOut)
                await removeActiveAuthenticationOperation(operation)
            }
            return
        }

        logger.info("Starting API key login")
        var requestFailed = false
        do {
            try await backend.login(apiKey: apiKey)
        } catch {
            requestFailed = true
            // The app-server owns the credential payload. Do not surface an upstream error that
            // could echo it; reconcile the write outcome from the same runtime instead.
            logger.error("API key login request failed; reconciling account state")
        }

        let snapshot: CodexReviewBackendModel.Auth.Snapshot
        do {
            snapshot = try await backend.readAuth()
        } catch {
            if usesPrimaryRuntime, let expectedRuntimeHandle {
                _ = attachedStore?.requestRuntimeFailure(
                    handle: expectedRuntimeHandle,
                    cause: "API key authentication outcome could not be reconciled."
                )
            }
            await finishAPIKeyAuthenticationFailure(
                operation: operation,
                scope: scope,
                auth: auth,
                message: "API key sign-in could not be confirmed."
            )
            return
        }
        guard Self.isAPIKeyAuthentication(snapshot) else {
            await finishAPIKeyAuthenticationFailure(
                operation: operation,
                scope: scope,
                auth: auth,
                message: requestFailed
                    ? "API key sign-in could not be confirmed."
                    : "API key sign-in did not produce an API key account."
            )
            return
        }
        guard activeAuthenticationOperation === operation,
              operation.authorizesSharedStateCommit(from: scope),
              isCurrentRuntime(expectedRuntimeHandle),
              let cleanup = scope.takeForCleanup()
        else {
            let cleanup = scope.takeForCleanup()
            await closeIsolatedLoginRuntime(
                client: cleanup?.client,
                codexHomeURL: cleanup?.codexHomeURL
            )
            await removeActiveAuthenticationOperation(operation)
            return
        }

        let loginCodexHomeURL = cleanup.codexHomeURL
        let account = applyAuthSnapshot(
            snapshot,
            to: auth,
            activation: operation.activation,
            authSourceCodexHomeURL: loginCodexHomeURL
        )
        await closeIsolatedLoginRuntime(
            client: cleanup.client,
            codexHomeURL: loginCodexHomeURL
        )
        guard account?.kind == .apiKey,
              activeAuthenticationOperation === operation,
              operation.authorizesSharedStateCommit(from: scope)
        else {
            updateAuthenticationFailure(
                "API key sign-in did not produce an API key account.",
                auth: auth,
                activation: operation.activation
            )
            await removeActiveAuthenticationOperation(operation)
            return
        }
        await removeActiveAuthenticationOperation(operation)
    }

    private func finishAPIKeyAuthenticationFailure(
        operation: LiveAuthenticationOperation,
        scope: LiveAuthenticationOperation.ResourceScope,
        auth: CodexReviewAuthModel,
        message: String
    ) async {
        let cleanup = scope.takeForCleanup()
        await closeIsolatedLoginRuntime(
            client: cleanup?.client,
            codexHomeURL: cleanup?.codexHomeURL
        )
        guard activeAuthenticationOperation === operation,
              operation.authorizesSharedStateCommit(from: scope)
        else {
            return
        }
        updateAuthenticationFailure(
            message,
            auth: auth,
            activation: operation.activation
        )
        await removeActiveAuthenticationOperation(operation)
    }

    private static func isAPIKeyAuthentication(
        _ snapshot: CodexReviewBackendModel.Auth.Snapshot
    ) -> Bool {
        guard let activeAccountID = snapshot.activeAccountID else {
            return false
        }
        return snapshot.accounts.contains {
            $0.id == activeAccountID && $0.kind == .apiKey
        }
    }

    private static func loginStartOutcomeMayBeUnknown(_ error: any Error) -> Bool {
        guard let jsonRPCError = error as? JSONRPC.Error else { return true }
        if case .responseError = jsonRPCError {
            return false
        }
        return true
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
        operation: LiveAuthenticationOperation,
        scope: LiveAuthenticationOperation.ResourceScope,
        challenge: CodexReviewBackendModel.Login.Challenge,
        session: any CodexReviewNativeAuthentication.WebSession,
        completesLoginThroughCallback: Bool,
        auth: CodexReviewAuthModel
    ) async {
        do {
            let callbackURL = try await session.waitForCallbackURL()
            guard activeAuthenticationOperation === operation,
                  operation.authorizesSharedStateCommit(from: scope),
                  scope.isOpen
            else {
                let cleanup = scope.takeForCleanup()
                if let backend = cleanup?.backend, let challenge = cleanup?.challenge { try? await backend.cancelLogin(challenge) }
                await closeIsolatedLoginRuntime(client: cleanup?.client, codexHomeURL: cleanup?.codexHomeURL)
                return
            }
            guard completesLoginThroughCallback else {
                logger.info("Authentication session completed; waiting for app-server login completion notification")
                return
            }
            guard let loginBackend = scope.backend else {
                return
            }
            let activation = operation.activation
            let expectedRuntimeHandle = activeRuntimeHandle.flatMap { runtime in
                scope.matchesOriginatingBackend(runtime.backend) ? runtime : nil
            }
            let snapshot = try await loginBackend.completeLogin(.init(
                challengeID: challenge.id,
                callbackURL: callbackURL.absoluteString
            ))
            if let expectedRuntimeHandle,
               (activeRuntimeHandle !== expectedRuntimeHandle || acceptsRuntimeRequests == false)
            {
                await cleanupAuthenticationScope(scope)
                return
            }
            guard activeAuthenticationOperation === operation,
                  operation.authorizesSharedStateCommit(from: scope),
                  scope.isOpen
            else {
                await cleanupAuthenticationScope(scope)
                return
            }
            guard let preparedAccount = Self.prepareActiveAccount(
                from: snapshot,
                persistedAccounts: auth.persistedAccounts
            ) else {
                if let expectedRuntimeHandle {
                    invalidatePrimaryRuntime(
                        expectedRuntimeHandle,
                        rollbackAuthority: .captured(
                            accountKey: operation.rollbackAccountKey
                        ),
                        reason: "A ChatGPT login completed without an active account"
                    )
                    await cleanupAuthenticationScope(scope)
                    return
                }
                throw CodexReviewAPI.Error.io(
                    "Authentication completed without an active account."
                )
            }
            guard operation.commitAuthenticationSuccess(
                from: .callback,
                from: scope
            ) else {
                return
            }
            let account = applyAuthSnapshot(
                snapshot,
                to: auth,
                activation: activation,
                authSourceCodexHomeURL: scope.codexHomeURL,
                preparedAccount: preparedAccount
            )
            await refreshCommittedAuthenticationRateLimits(
                account: account,
                activation: activation,
                operation: operation,
                scope: scope,
                backend: loginBackend,
                expectedRuntimeHandle: expectedRuntimeHandle,
                auth: auth
            )
            let cleanup = scope.takeForCleanup()
            cleanup?.notificationTask?.cancel()
            await closeIsolatedLoginRuntime(
                client: cleanup?.client,
                codexHomeURL: cleanup?.codexHomeURL
            )
            await removeActiveAuthenticationOperation(operation)
        } catch is CancellationError {
            await handleAuthenticationSessionCancelled(operation: operation, scope: scope, auth: auth)
        } catch CodexReviewNativeAuthenticationError.cancelled {
            await handleAuthenticationSessionCancelled(operation: operation, scope: scope, auth: auth)
        } catch {
            guard activeAuthenticationOperation === operation, scope.isOpen else {
                return
            }
            operation.beginTerminalAbort()
            let activation = operation.activation
            logger.error("ChatGPT login failed to complete: \(error.localizedDescription, privacy: .public)")
            let cleanup = scope.takeForCleanup()
            cleanup?.notificationTask?.cancel()
            if cleanup != nil,
               activeAuthenticationOperation === operation,
               operation.isCurrent(scope)
            {
                operation.beginResourceCleanup()
            }
            await closeIsolatedLoginRuntime(client: cleanup?.client, codexHomeURL: cleanup?.codexHomeURL)
            guard cleanup != nil,
                  activeAuthenticationOperation === operation,
                  operation.isCurrent(scope) else { return }
            updateAuthenticationFailure(
                error.localizedDescription,
                auth: auth,
                activation: activation
            )
            await removeActiveAuthenticationOperation(operation)
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
        operation: LiveAuthenticationOperation,
        scope: LiveAuthenticationOperation.ResourceScope,
        auth: CodexReviewAuthModel
    ) async {
        guard scope.challenge != nil, let cleanup = scope.takeForCleanup() else {
            return
        }
        operation.beginUserCancellation()
        logger.info("ChatGPT login session was cancelled")
        cleanup.notificationTask?.cancel()
        if let loginBackend = cleanup.backend, let challenge = cleanup.challenge {
            do {
                try await loginBackend.cancelLogin(challenge)
            } catch {
                logger.error("Failed to cancel ChatGPT login after session close: \(error.localizedDescription, privacy: .public)")
            }
        }
        if activeAuthenticationOperation === operation, operation.isCurrent(scope) {
            operation.beginResourceCleanup()
        }
        if activeAuthenticationOperation === operation,
           operation.isCurrent(scope) {
            auth.updatePhase(.signedOut)
        }
        await closeIsolatedLoginRuntime(client: cleanup.client, codexHomeURL: cleanup.codexHomeURL)
        await removeActiveAuthenticationOperation(operation)
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
        try await cleanupReview(prepared.receipt.sourceRun, using: runtime)
    }

    func discardReviewRecovery(_ staged: StagedReviewRecovery) async throws {
        let runtime = try reviewAttemptRuntimeRoutes.takeStaged(staged)
        try await cleanupReview(staged.attempt.run, using: runtime)
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
        try await cleanupReview(run, using: runtime)
    }

    private func cleanupReview(
        _ run: CodexReviewBackendModel.Review.Run,
        using runtime: LiveRuntimeLifecycleHandle
    ) async throws {
        do {
            try await runtime.backend.cleanupReview(run)
        } catch let invalidation as AppServerCleanupTransportInvalidation {
            invalidateRuntimeAfterCleanupFailure(
                runtime,
                cause: invalidation.failure.localizedDescription
            )
            if invalidation.callerWasCancelled {
                throw CancellationError()
            }
            throw invalidation.failure
        } catch let failure as ReviewRuntimeCloseFailure {
            if case .connection = failure {
                invalidateRuntimeAfterCleanupFailure(
                    runtime,
                    cause: failure.localizedDescription
                )
            }
            throw failure
        }
    }

    private func invalidateRuntimeAfterCleanupFailure(
        _ handle: LiveRuntimeLifecycleHandle,
        cause: String
    ) {
        guard let store = attachedStore else {
            return
        }
        _ = store.requestRuntimeCleanupRecovery(
            sourceHandle: handle,
            sourceGeneration: handle.generation,
            cause: cause
        )
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
            try await cleanupReview(cleanupRun, using: runtime)
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
            try await cleanupReview(cleanup.0, using: cleanup.1)
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
        authSourceCodexHomeURL: URL? = nil,
        preparedAccount: PreparedAuthenticationAccount? = nil
    ) -> CodexAccount? {
        guard let preparedAccount = preparedAccount ?? Self.prepareActiveAccount(
            from: snapshot,
            persistedAccounts: auth.persistedAccounts
        )
        else {
            if case .activateAuthenticatedAccount = activation {
                auth.selectPersistedAccount(nil)
                auth.updatePhase(.signedOut)
            } else {
                auth.updatePhase(.signedOut)
            }
            return nil
        }
        let account = preparedAccount.account
        var persistedAccounts = auth.persistedAccounts
        let persistedAccount: CodexAccount
        if let index = persistedAccounts.firstIndex(where: { $0.accountKey == account.accountKey }) {
            let currentAccount = persistedAccounts[index]
            currentAccount.updateEmail(account.email)
            currentAccount.updateKind(
                account.kind,
                capabilities: account.capabilities
            )
            currentAccount.updatePlanType(account.planType)
            if preparedAccount.includesRateLimitState {
                let payload = savedAccountPayload(from: account)
                currentAccount.updateRateLimits(payload.rateLimits)
                currentAccount.updateRateLimitFetchMetadata(
                    fetchedAt: payload.lastRateLimitFetchAt,
                    error: payload.lastRateLimitError
                )
            }
            persistedAccount = currentAccount
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
        stream: AsyncThrowingStream<JSONRPC.ReceivedNotification, Error>,
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
                for try await received in stream {
                    guard self.activeRuntimeHandle === handle,
                          self.acceptsRuntimeRequests
                    else {
                        return
                    }
                    await self.handleAuthNotification(
                        received,
                        backend: backend,
                        expectedRuntimeHandle: handle,
                        auth: store.auth
                    )
                    self.recordPrimaryAuthNotificationCompletion(
                        received.receipt,
                        runtime: handle
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
        _ received: JSONRPC.ReceivedNotification,
        backend: AppServerCodexReviewBackend,
        expectedRuntimeHandle: LiveRuntimeLifecycleHandle,
        auth: CodexReviewAuthModel
    ) async {
        guard activeRuntimeHandle === expectedRuntimeHandle,
              acceptsRuntimeRequests
        else {
            return
        }
        let notification = received.notification
        switch notification.method {
        case "account/login/completed":
            do {
                let payload = try JSONDecoder().decode(
                    AppServerAccountLoginCompletedNotification.self,
                    from: notification.params
                )
                if consumeRetiredPrimaryLoginCompletion(
                    payload,
                    receipt: received.receipt,
                    runtime: expectedRuntimeHandle
                ) {
                    return
                }
                if let loginID = payload.loginID,
                   let operation = activeAuthenticationOperation,
                   operation.stagePrimaryLoginCompletion(
                       notification,
                       loginID: loginID,
                       success: payload.success,
                       error: payload.error,
                       receipt: received.receipt
                   )
                {
                    return
                }
                guard let (operation, scope) = currentPrimaryAuthenticationRoute(
                    receipt: received.receipt,
                    backend: backend
                ),
                let loginID = payload.loginID,
                scope.matchesOriginatingChallenge(loginID) else {
                    return
                }
                await handleLoginCompletedNotification(
                    notification,
                    operation: operation,
                    scope: scope,
                    backend: backend,
                    expectedRuntimeHandle: expectedRuntimeHandle,
                    auth: auth
                )
            } catch {
                logger.error("Failed to decode account login completion: \(error.localizedDescription, privacy: .public)")
            }
        case "account/updated":
            if isRetiredPrimaryNotification(
                receipt: received.receipt,
                runtime: expectedRuntimeHandle
            ) {
                return
            }
            if let operation = activeAuthenticationOperation,
               operation.stagePrimaryAccountUpdate(receipt: received.receipt)
            {
                return
            }
            if let operation = activeAuthenticationOperation,
               operation.usesAPIKey,
               let startReceipt = operation.primaryNotificationRouteStartReceipt,
               received.receipt > startReceipt
            {
                // API-key login is synchronous; its setup task owns the authoritative account/read
                // and commit. The notification is only an edge, not a second commit owner.
                return
            }
            if let (operation, scope) = currentPrimaryAuthenticationRoute(
                receipt: received.receipt,
                backend: backend
            ) {
                await handleAccountUpdatedNotification(
                    operation: operation,
                    scope: scope,
                    backend: backend,
                    expectedRuntimeHandle: expectedRuntimeHandle,
                    auth: auth
                )
                return
            }
            if activeAuthenticationOperation?.primaryNotificationRouteGeneration != nil {
                return
            }
            await refreshAuthAfterAccountNotification(
                backend: backend,
                expectedRuntimeHandle: expectedRuntimeHandle,
                expectedAuthenticationGeneration: primaryAuthenticationLifecycleGeneration,
                auth: auth
            )
        case "account/rateLimits/updated":
            if isRetiredPrimaryNotification(
                receipt: received.receipt,
                runtime: expectedRuntimeHandle
            ) || activeAuthenticationOperation?.primaryNotificationRouteGeneration != nil {
                return
            }
            await applyRateLimitsUpdatedNotification(notification, auth: auth)
        default:
            return
        }
    }

    private func currentPrimaryAuthenticationRoute(
        receipt: JSONRPC.NotificationReceipt,
        backend: AppServerCodexReviewBackend
    ) -> (LiveAuthenticationOperation, LiveAuthenticationOperation.ResourceScope)? {
        guard let operation = activeAuthenticationOperation,
              let scope = operation.resourceScope,
              operation.primaryNotificationRouteGeneration == primaryAuthenticationLifecycleGeneration,
              let startReceipt = operation.primaryNotificationRouteStartReceipt,
              receipt > startReceipt,
              scope.matchesOriginatingBackend(backend)
        else {
            return nil
        }
        return (operation, scope)
    }

    private func consumeRetiredPrimaryLoginCompletion(
        _ payload: AppServerAccountLoginCompletedNotification,
        receipt: JSONRPC.NotificationReceipt,
        runtime: LiveRuntimeLifecycleHandle
    ) -> Bool {
        if let index = retiredPrimaryAuthenticationRouteIndex(
            containing: receipt,
            runtime: runtime
        ) {
            if let loginID = payload.loginID,
               retiredPrimaryAuthenticationRoutes[index].loginID == loginID,
               retiredPrimaryAuthenticationRoutes[index].awaitsLateLoginCompletion
            {
                recordRetiredLoginCompletion(payload, at: index, runtime: runtime)
            }
            return true
        }
        guard let loginID = payload.loginID,
              let index = retiredPrimaryAuthenticationRoutes.firstIndex(where: {
                  $0.runtime === runtime
                      && $0.loginID == loginID
                      && $0.awaitsLateLoginCompletion
              })
        else {
            return false
        }
        recordRetiredLoginCompletion(payload, at: index, runtime: runtime)
        return true
    }

    private func recordRetiredLoginCompletion(
        _ payload: AppServerAccountLoginCompletedNotification,
        at index: Int,
        runtime: LiveRuntimeLifecycleHandle
    ) {
        retiredPrimaryAuthenticationRoutes[index].awaitsLateLoginCompletion = false
        if payload.success {
            invalidatePrimaryRuntimeAfterCancelledLoginSuccess(
                runtime,
                rollbackAuthority: .current(
                    fallbackAccountKey: retiredPrimaryAuthenticationRoutes[index].rollbackAccountKey
                )
            )
        }
    }

    private func invalidatePrimaryRuntimeAfterCancelledLoginSuccess(
        _ runtime: LiveRuntimeLifecycleHandle,
        rollbackAuthority: AuthenticationRollbackAuthority
    ) {
        invalidatePrimaryRuntime(
            runtime,
            rollbackAuthority: rollbackAuthority,
            reason: "A cancelled ChatGPT login completed successfully"
        )
    }

    private func invalidatePrimaryRuntime(
        _ runtime: LiveRuntimeLifecycleHandle,
        rollbackAuthority: AuthenticationRollbackAuthority,
        reason: String
    ) {
        guard activeRuntimeHandle === runtime else { return }
        runtime.requiresAuthenticationRollbackAfterClose = true
        let rollbackFailure = restoreAuthorizedAuthentication(rollbackAuthority)
        activeAuthenticationOperation?.revokeSharedStateCommits()
        primaryAuthenticationLifecycleGeneration += 1
        acceptsRuntimeRequests = false
        logger.error("\(reason, privacy: .public); invalidating the primary runtime")
        let cause = if let rollbackFailure {
            "\(reason), and prior authentication could not be restored: \(rollbackFailure)"
        } else {
            "\(reason). Reset the server before continuing."
        }
        _ = attachedStore?.requestRuntimeFailure(
            handle: runtime,
            cause: cause
        )
    }

    private func restoreAuthorizedAuthentication(
        _ authority: AuthenticationRollbackAuthority
    ) -> String? {
        let currentAuth = attachedStore?.auth
        let resolvedAccountKey = authority.resolveAccountKey(auth: currentAuth)
        if let resolvedAccountKey, let currentAuth {
            do {
                try CodexReviewAccountRegistry.activateAccount(
                    resolvedAccountKey,
                    accounts: currentAuth.persistedAccounts,
                    codexHomeURL: codexHomeURL
                )
                currentAuth.applyPersistedAccountStates(
                    currentAuth.persistedAccounts.map(savedAccountPayload(from:)),
                    activeAccountKey: resolvedAccountKey
                )
                currentAuth.selectPersistedAccount(
                    currentAuth.persistedAccounts.first {
                        $0.accountKey == resolvedAccountKey
                    }?.id
                )
                currentAuth.updatePhase(.signedOut)
                return nil
            } catch {
                try? CodexReviewAccountRegistry.removeSharedAuth(codexHomeURL: codexHomeURL)
                return error.localizedDescription
            }
        }
        do {
            if let currentAuth {
                try CodexReviewAccountRegistry.saveAccounts(
                    currentAuth.persistedAccounts,
                    activeAccountKey: nil,
                    codexHomeURL: codexHomeURL
                )
            }
            try CodexReviewAccountRegistry.removeSharedAuth(codexHomeURL: codexHomeURL)
            currentAuth?.applyPersistedAccountStates(
                currentAuth?.persistedAccounts.map(savedAccountPayload(from:)) ?? [],
                activeAccountKey: nil
            )
            currentAuth?.selectPersistedAccount(nil)
            currentAuth?.updatePhase(.signedOut)
            return resolvedAccountKey == nil
                ? nil
                : "The authentication store was unavailable."
        } catch {
            return error.localizedDescription
        }
    }

    fileprivate func restoreAuthenticationAfterRuntimeClose(
        _ runtime: LiveRuntimeLifecycleHandle
    ) {
        guard runtime.requiresAuthenticationRollbackAfterClose else { return }
        if let failure = restoreAuthorizedAuthentication(
            .current(fallbackAccountKey: nil)
        ) {
            logger.error(
                "Failed to restore authentication after revoked login runtime close: \(failure, privacy: .public)"
            )
        }
    }

    private func isRetiredPrimaryNotification(
        receipt: JSONRPC.NotificationReceipt,
        runtime: LiveRuntimeLifecycleHandle
    ) -> Bool {
        if retiredPrimaryAuthenticationRouteIndex(
            containing: receipt,
            runtime: runtime
        ) != nil {
            return true
        }
        return false
    }

    private func retiredPrimaryAuthenticationRouteIndex(
        containing receipt: JSONRPC.NotificationReceipt,
        runtime: LiveRuntimeLifecycleHandle
    ) -> Int? {
        retiredPrimaryAuthenticationRoutes.indices
            .filter {
                retiredPrimaryAuthenticationRoutes[$0].runtime === runtime
                    && retiredPrimaryAuthenticationRoutes[$0].contains(receipt)
            }
            .min {
                retiredPrimaryAuthenticationRoutes[$0].throughReceipt
                    < retiredPrimaryAuthenticationRoutes[$1].throughReceipt
            }
    }

    private func recordPrimaryAuthNotificationCompletion(
        _ receipt: JSONRPC.NotificationReceipt,
        runtime: LiveRuntimeLifecycleHandle
    ) {
        guard activeRuntimeHandle === runtime else { return }
        completedPrimaryAuthNotificationReceipt = max(
            completedPrimaryAuthNotificationReceipt,
            receipt
        )
        retiredPrimaryAuthenticationRoutes.removeAll {
            $0.runtime === runtime
                && $0.throughReceipt <= completedPrimaryAuthNotificationReceipt
                && $0.awaitsLateLoginCompletion == false
        }
        let ready = primaryAuthNotificationCompletionWaiters.filter {
            completedPrimaryAuthNotificationReceipt >= $0.0
        }
        primaryAuthNotificationCompletionWaiters.removeAll {
            completedPrimaryAuthNotificationReceipt >= $0.0
        }
        for (_, continuation) in ready {
            continuation.resume()
        }
    }

    fileprivate func waitForPrimaryAuthNotificationCompletionForTesting(
        _ receipt: JSONRPC.NotificationReceipt
    ) async {
        guard completedPrimaryAuthNotificationReceipt < receipt else { return }
        await withCheckedContinuation { continuation in
            if completedPrimaryAuthNotificationReceipt >= receipt {
                continuation.resume()
            } else {
                primaryAuthNotificationCompletionWaiters.append((receipt, continuation))
            }
        }
    }

    private func resetPrimaryAuthNotificationRouting() {
        retiredPrimaryAuthenticationRoutes.removeAll(keepingCapacity: false)
        completedPrimaryAuthNotificationReceipt = .beforeFirst
        let waiters = primaryAuthNotificationCompletionWaiters
        primaryAuthNotificationCompletionWaiters.removeAll(keepingCapacity: false)
        for (_, continuation) in waiters {
            continuation.resume()
        }
    }

    private func observeLoginNotifications(
        operation: LiveAuthenticationOperation,
        scope: LiveAuthenticationOperation.ResourceScope,
        client: AppServerClient,
        backend: AppServerCodexReviewBackend,
        auth: CodexReviewAuthModel
    ) {
        let task = Task { @MainActor [weak self, weak auth] in
            guard let self, let auth else {
                return
            }
            let stream = await client.notificationStream()
            do {
                for try await received in stream
                    where received.method == "account/login/completed"
                        || received.method == "account/updated"
                {
                    await self.handleLoginRuntimeNotification(
                        received.notification,
                        operation: operation,
                        scope: scope,
                        backend: backend,
                        auth: auth
                    )
                }
            } catch is CancellationError {
            } catch {
                logger.error("Login notification stream ended: \(error.localizedDescription, privacy: .public)")
            }
        }
        scope.install(notificationTask: task)
    }

    private func handleLoginRuntimeNotification(
        _ notification: JSONRPC.Notification,
        operation: LiveAuthenticationOperation,
        scope: LiveAuthenticationOperation.ResourceScope,
        backend: AppServerCodexReviewBackend,
        auth: CodexReviewAuthModel
    ) async {
        guard activeAuthenticationOperation === operation,
              operation.authorizesSharedStateCommit(from: scope),
              scope.isOpen,
              scope.backend === backend else { return }
        switch notification.method {
        case "account/login/completed":
            await handleLoginCompletedNotification(
                notification,
                operation: operation,
                scope: scope,
                backend: backend,
                auth: auth
            )
        case "account/updated":
            guard scope.backend != nil,
                  operation.phase == .waitingForAccountUpdate else {
                return
            }
            await finishCompletedLoginAfterAccountUpdate(
                operation: operation,
                scope: scope,
                backend: backend,
                auth: auth
            )
        default:
            return
        }
    }

    private func handleLoginCompletedNotification(
        _ notification: JSONRPC.Notification,
        operation: LiveAuthenticationOperation,
        scope: LiveAuthenticationOperation.ResourceScope,
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
                operation: operation,
                scope: scope,
                backend: backend,
                expectedRuntimeHandle: expectedRuntimeHandle,
                auth: auth
            )
            return
        }
        do {
            let payload = try JSONDecoder().decode(AppServerAccountLoginCompletedNotification.self, from: notification.params)
            guard payload.loginID == nil || payload.loginID.map(scope.matchesOriginatingChallenge) == true else {
                return
            }
            guard activeAuthenticationOperation === operation,
                  operation.isCurrent(scope) else {
                await cleanupAuthenticationScope(scope)
                return
            }
            guard scope.isOpen else {
                guard operation.authorizesSharedStateCommit(from: scope) == false else {
                    return
                }
                if payload.success, let expectedRuntimeHandle {
                    invalidatePrimaryRuntimeAfterCancelledLoginSuccess(
                        expectedRuntimeHandle,
                        rollbackAuthority: .captured(
                            accountKey: operation.rollbackAccountKey
                        )
                    )
                } else if payload.success == false {
                    operation.beginTerminalFailure()
                }
                return
            }
            let terminalPublicationOwner = operation.terminalPublicationOwner
            let activation = operation.activation
            if payload.success {
                guard operation.authorizesSharedStateCommit(from: scope) else {
                    if let expectedRuntimeHandle {
                        invalidatePrimaryRuntimeAfterCancelledLoginSuccess(
                            expectedRuntimeHandle,
                            rollbackAuthority: .captured(
                                accountKey: operation.rollbackAccountKey
                            )
                        )
                    }
                    await cleanupAuthenticationScope(scope)
                    await removeActiveAuthenticationOperation(operation)
                    return
                }
                guard operation.beginAuthenticationCommitPreparation(from: scope) else {
                    return
                }
            } else {
                guard operation.beginTerminalFailure() else {
                    return
                }
                switch terminalPublicationOwner {
                case .notification:
                    updateAuthenticationFailure(
                        payload.error ?? "Authentication failed.",
                        auth: auth,
                        activation: activation
                    )
                case .userCancellation:
                    auth.updatePhase(.signedOut)
                case .hostFailure:
                    return
                }
            }
            let presentation = scope.takePresentation()
            presentation.monitorTask?.cancel()
            await presentation.session?.cancel()
            if let expectedRuntimeHandle,
               (activeRuntimeHandle !== expectedRuntimeHandle || acceptsRuntimeRequests == false)
            {
                await cleanupAuthenticationScope(scope)
                return
            }
            guard activeAuthenticationOperation === operation,
                  operation.isCurrent(scope),
                  scope.isOpen else {
                await cleanupAuthenticationScope(scope)
                return
            }
            guard payload.success else {
                let cleanup = scope.takeForCleanup()
                cleanup?.notificationTask?.cancel()
                await closeIsolatedLoginRuntime(client: cleanup?.client, codexHomeURL: cleanup?.codexHomeURL)
                await removeActiveAuthenticationOperation(operation)
                return
            }
            guard operation.authorizesSharedStateCommit(from: scope) else {
                await cleanupAuthenticationScope(scope)
                await removeActiveAuthenticationOperation(operation)
                return
            }
            logger.info("ChatGPT login completed; waiting for account update notification")
        } catch {
            logger.error("Failed to decode account login completion: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleAccountUpdatedNotification(
        operation: LiveAuthenticationOperation,
        scope: LiveAuthenticationOperation.ResourceScope,
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
        guard activeAuthenticationOperation === operation,
              operation.isCurrent(scope) else {
            await refreshAuthAfterAccountNotification(
                backend: backend,
                expectedRuntimeHandle: expectedRuntimeHandle,
                authenticationScope: scope,
                auth: auth
            )
            return
        }
        guard operation.authorizesSharedStateCommit(from: scope) else {
            return
        }
        switch operation.phase {
        case .waitingForCompletion:
            await refreshAuthAfterAccountNotification(
                backend: backend,
                expectedRuntimeHandle: expectedRuntimeHandle,
                authenticationScope: scope,
                auth: auth
            )
        case .waitingForAccountUpdate:
            await finishCompletedLoginAfterAccountUpdate(
                operation: operation,
                scope: scope,
                backend: backend,
                expectedRuntimeHandle: expectedRuntimeHandle,
                auth: auth
            )
        case .terminalFailureObserved, .terminalSuccessCommitted:
            return
        }
    }

    private func commitAuthenticationSnapshot(
        _ snapshot: CodexReviewBackendModel.Auth.Snapshot,
        operation: LiveAuthenticationOperation,
        scope: LiveAuthenticationOperation.ResourceScope,
        expectedRuntimeHandle: LiveRuntimeLifecycleHandle? = nil,
        auth: CodexReviewAuthModel
    ) throws -> CodexAccount? {
        if let expectedRuntimeHandle,
           (activeRuntimeHandle !== expectedRuntimeHandle || acceptsRuntimeRequests == false)
        {
            return nil
        }
        guard activeAuthenticationOperation === operation,
              operation.authorizesSharedStateCommit(from: scope),
              operation.phase == .waitingForAccountUpdate,
              scope.isOpen else {
            return nil
        }
        let activation = operation.activation
        let loginCodexHomeURL = scope.codexHomeURL
        guard let preparedAccount = Self.prepareActiveAccount(
            from: snapshot,
            persistedAccounts: auth.persistedAccounts
        ) else {
            if let expectedRuntimeHandle {
                invalidatePrimaryRuntime(
                    expectedRuntimeHandle,
                    rollbackAuthority: .captured(
                        accountKey: operation.rollbackAccountKey
                    ),
                    reason: "A ChatGPT login completed without an active account"
                )
                return nil
            }
            throw CodexReviewAPI.Error.io(
                "Authentication completed without an active account."
            )
        }
        guard activeAuthenticationOperation === operation,
              operation.authorizesSharedStateCommit(from: scope),
              scope.isOpen,
              operation.commitAuthenticationSuccess(
                  from: .notification,
                  from: scope
              )
        else {
            return nil
        }
        return applyAuthSnapshot(
            snapshot,
            to: auth,
            activation: activation,
            authSourceCodexHomeURL: loginCodexHomeURL,
            preparedAccount: preparedAccount
        )
    }

    private func refreshCommittedAuthenticationRateLimits(
        account: CodexAccount?,
        activation: LoginActivation,
        operation: LiveAuthenticationOperation,
        scope: LiveAuthenticationOperation.ResourceScope,
        backend: AppServerCodexReviewBackend,
        expectedRuntimeHandle: LiveRuntimeLifecycleHandle? = nil,
        auth: CodexReviewAuthModel
    ) async {
        switch activation {
        case .activateAuthenticatedAccount:
            await refreshSelectedAccountRateLimits(
                auth: auth,
                expectedRuntimeHandle: expectedRuntimeHandle,
                authenticationScope: scope
            )
        case .preserveActiveAccount:
            guard let account else { return }
            let didRefresh = await refreshRateLimits(
                for: account,
                using: backend,
                source: "login-runtime",
                authenticationScope: scope
            )
            if didRefresh,
               activeAuthenticationOperation === operation,
               authorizesAuthenticationSharedStateCommit(scope)
            {
                persistRefreshedSharedAuth(
                    from: scope.codexHomeURL,
                    for: account
                )
            }
        }
    }

    private func finishCompletedLoginAfterAccountUpdate(
        operation: LiveAuthenticationOperation,
        scope: LiveAuthenticationOperation.ResourceScope,
        backend: AppServerCodexReviewBackend,
        expectedRuntimeHandle: LiveRuntimeLifecycleHandle? = nil,
        auth: CodexReviewAuthModel
    ) async {
        let activation = operation.activation
        let presentation = scope.takePresentation()
        do {
            presentation.monitorTask?.cancel()
            await presentation.session?.cancel()
            guard activeAuthenticationOperation === operation,
                  operation.authorizesSharedStateCommit(from: scope),
                  scope.isOpen else {
                await cleanupAuthenticationScope(scope)
                return
            }
            if let expectedRuntimeHandle,
               (activeRuntimeHandle !== expectedRuntimeHandle || acceptsRuntimeRequests == false)
            {
                await cleanupAuthenticationScope(scope)
                return
            }
            let snapshot = try await backend.readAuth()
            guard let account = try commitAuthenticationSnapshot(
                snapshot,
                operation: operation,
                scope: scope,
                expectedRuntimeHandle: expectedRuntimeHandle,
                auth: auth
            ) else {
                if operation.phase != .terminalSuccessCommitted {
                    await cleanupAuthenticationScope(scope)
                }
                return
            }
            await refreshCommittedAuthenticationRateLimits(
                account: account,
                activation: activation,
                operation: operation,
                scope: scope,
                backend: backend,
                expectedRuntimeHandle: expectedRuntimeHandle,
                auth: auth
            )
        } catch {
            if operation.phase == .terminalSuccessCommitted {
                return
            }
            let runtimeIsCurrent = expectedRuntimeHandle.map {
                activeRuntimeHandle === $0 && acceptsRuntimeRequests
            } ?? true
            if runtimeIsCurrent,
               activeAuthenticationOperation === operation,
               operation.authorizesSharedStateCommit(from: scope),
               operation.phase == .waitingForAccountUpdate,
               scope.isOpen
            {
                if let expectedRuntimeHandle {
                    invalidatePrimaryRuntime(
                        expectedRuntimeHandle,
                        rollbackAuthority: .captured(
                            accountKey: operation.rollbackAccountKey
                        ),
                        reason: "A completed ChatGPT login could not read its account state: \(error.localizedDescription)"
                    )
                } else {
                    updateAuthenticationFailure(
                        error.localizedDescription,
                        auth: auth,
                        activation: activation
                    )
                }
            }
        }
        let cleanup = scope.takeForCleanup()
        if cleanup != nil,
           activeAuthenticationOperation === operation,
           operation.isCurrent(scope),
           operation.phase != .terminalFailureObserved,
           operation.phase != .terminalSuccessCommitted
        {
            operation.beginResourceCleanup()
        }
        cleanup?.notificationTask?.cancel()
        await closeIsolatedLoginRuntime(client: cleanup?.client, codexHomeURL: cleanup?.codexHomeURL)
        await removeActiveAuthenticationOperation(operation)
    }

    private func refreshAuthAfterAccountNotification(
        backend: AppServerCodexReviewBackend,
        expectedRuntimeHandle requestedRuntimeHandle: LiveRuntimeLifecycleHandle? = nil,
        expectedAuthenticationGeneration requestedAuthenticationGeneration: UInt64? = nil,
        authenticationScope: LiveAuthenticationOperation.ResourceScope? = nil,
        auth: CodexReviewAuthModel
    ) async {
        let expectedRuntimeHandle = requestedRuntimeHandle ?? activeRuntimeHandle
        let expectedAuthenticationGeneration = requestedAuthenticationGeneration
            ?? primaryAuthenticationLifecycleGeneration
        guard acceptsRuntimeRequests,
              let expectedRuntimeHandle,
              activeRuntimeHandle === expectedRuntimeHandle,
              primaryAuthenticationLifecycleGeneration == expectedAuthenticationGeneration,
              expectedRuntimeHandle.backend === backend
        else {
            return
        }
        if let authenticationScope,
           authorizesGenericAuthenticationRefresh(authenticationScope) == false
        {
            return
        }
        do {
            let snapshot = try await backend.readAuth()
            guard activeRuntimeHandle === expectedRuntimeHandle,
                  acceptsRuntimeRequests,
                  primaryAuthenticationLifecycleGeneration == expectedAuthenticationGeneration
            else {
                return
            }
            if let authenticationScope,
               authorizesGenericAuthenticationRefresh(authenticationScope) == false
            {
                return
            }
            let preparedAccount = Self.prepareActiveAccount(
                from: snapshot,
                persistedAccounts: auth.persistedAccounts
            )
            var accountForCommit = preparedAccount
            if let preparedAccount,
               preparedAccount.account.capabilities.supportsRateLimitRefresh
            {
                _ = await refreshRateLimits(
                    for: preparedAccount.account,
                    using: backend,
                    source: "account-notification",
                    expectedRuntimeHandle: expectedRuntimeHandle,
                    expectedAuthenticationGeneration: expectedAuthenticationGeneration,
                    authenticationScope: authenticationScope,
                    persistsResult: false
                )
                accountForCommit = preparedAccount.includingRateLimitState()
            }
            guard activeRuntimeHandle === expectedRuntimeHandle,
                  acceptsRuntimeRequests,
                  primaryAuthenticationLifecycleGeneration == expectedAuthenticationGeneration
            else {
                return
            }
            if let authenticationScope,
               authorizesGenericAuthenticationRefresh(authenticationScope) == false
            {
                return
            }
            applyAuthSnapshot(
                snapshot,
                to: auth,
                preparedAccount: accountForCommit
            )
        } catch {
            guard activeRuntimeHandle === expectedRuntimeHandle,
                  acceptsRuntimeRequests,
                  primaryAuthenticationLifecycleGeneration == expectedAuthenticationGeneration
            else {
                return
            }
            if let authenticationScope,
               authorizesGenericAuthenticationRefresh(authenticationScope) == false
            {
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
        expectedRuntimeHandle: LiveRuntimeLifecycleHandle? = nil,
        expectedAuthenticationGeneration: UInt64? = nil,
        authenticationScope: LiveAuthenticationOperation.ResourceScope? = nil
    ) async {
        if let expectedAuthenticationGeneration,
           primaryAuthenticationLifecycleGeneration != expectedAuthenticationGeneration
        {
            return
        }
        guard let selectedAccount = auth.selectedAccount else {
            return
        }
        await refreshRateLimits(
            for: selectedAccount,
            auth: auth,
            expectedRuntimeHandle: expectedRuntimeHandle,
            expectedAuthenticationGeneration: expectedAuthenticationGeneration,
            authenticationScope: authenticationScope
        )
    }

    private func refreshRateLimits(
        for account: CodexAccount,
        auth: CodexReviewAuthModel,
        expectedRuntimeHandle requestedRuntimeHandle: LiveRuntimeLifecycleHandle? = nil,
        expectedAuthenticationGeneration: UInt64? = nil,
        authenticationScope: LiveAuthenticationOperation.ResourceScope? = nil
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
              activeRuntimeHandle === expectedRuntimeHandle,
              isCurrentPrimaryAuthenticationGeneration(expectedAuthenticationGeneration)
        else {
            return
        }
        let didRefresh = await refreshRateLimits(
            for: account,
            using: appServerBackend,
            source: "active-runtime",
            expectedRuntimeHandle: expectedRuntimeHandle,
            expectedAuthenticationGeneration: expectedAuthenticationGeneration,
            authenticationScope: authenticationScope
        )
        guard activeRuntimeHandle === expectedRuntimeHandle,
              acceptsRuntimeRequests,
              isCurrentPrimaryAuthenticationGeneration(expectedAuthenticationGeneration)
        else {
            return
        }
        if let authenticationScope,
           authorizesAuthenticationSharedStateCommit(authenticationScope) == false
        {
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
            let didRefresh = await refreshRateLimits(
                for: account,
                using: runtime.backend,
                source: "saved-auth-isolated-runtime"
            )
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
        expectedRuntimeHandle: LiveRuntimeLifecycleHandle? = nil,
        expectedAuthenticationGeneration: UInt64? = nil,
        authenticationScope: LiveAuthenticationOperation.ResourceScope? = nil,
        persistsResult: Bool = true
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
            if let expectedAuthenticationGeneration,
               primaryAuthenticationLifecycleGeneration != expectedAuthenticationGeneration
            {
                return false
            }
            if let authenticationScope,
               authorizesAuthenticationSharedStateCommit(authenticationScope) == false
            {
                return false
            }
            applyRateLimits(
                windows: response.codexRateLimitWindows,
                planType: response.codexPlanType,
                to: account
            )
            if persistsResult {
                try? CodexReviewAccountRegistry.updateCachedRateLimits(
                    from: account,
                    codexHomeURL: codexHomeURL
                )
            }
            return true
        } catch {
            if let expectedRuntimeHandle,
               (activeRuntimeHandle !== expectedRuntimeHandle || acceptsRuntimeRequests == false)
            {
                return false
            }
            if let expectedAuthenticationGeneration,
               primaryAuthenticationLifecycleGeneration != expectedAuthenticationGeneration
            {
                return false
            }
            if let authenticationScope,
               authorizesAuthenticationSharedStateCommit(authenticationScope) == false
            {
                return false
            }
            recordRateLimitRefreshFailure(error, account: account)
            if persistsResult {
                try? CodexReviewAccountRegistry.updateCachedRateLimits(
                    from: account,
                    codexHomeURL: codexHomeURL
                )
            }
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

    private func cleanupPendingAuthenticationResources(
        _ resources: PendingAuthenticationResources?
    ) async {
        guard let resources else {
            return
        }
        if let backend = resources.backend, let challenge = resources.challenge {
            try? await backend.cancelLogin(challenge)
        }
        await closeIsolatedLoginRuntime(client: resources.client, codexHomeURL: resources.codexHomeURL)
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

    private func isActiveAuthenticationOperation(_ operation: LiveAuthenticationOperation?) -> Bool {
        guard let operation else { return activeAuthenticationOperation == nil }
        return activeAuthenticationOperation === operation
    }

    private func authorizesAuthenticationSharedStateCommit(
        _ scope: LiveAuthenticationOperation.ResourceScope
    ) -> Bool {
        scope.isOpen
            && activeAuthenticationOperation?.authorizesSharedStateCommit(from: scope) == true
    }

    private func authorizesGenericAuthenticationRefresh(
        _ scope: LiveAuthenticationOperation.ResourceScope
    ) -> Bool {
        authorizesAuthenticationSharedStateCommit(scope)
            && activeAuthenticationOperation?.phase == .waitingForCompletion
    }

    private func isCurrentPrimaryAuthenticationGeneration(_ expected: UInt64?) -> Bool {
        expected.map { primaryAuthenticationLifecycleGeneration == $0 } ?? true
    }

    private func removeActiveAuthenticationOperation(_ operation: LiveAuthenticationOperation?) async {
        guard let operation, activeAuthenticationOperation === operation else { return }
        operation.revokeSharedStateCommits()
        await retirePrimaryAuthenticationRoute(operation)
        guard activeAuthenticationOperation === operation else { return }
        if operation.primaryNotificationRouteGeneration == primaryAuthenticationLifecycleGeneration {
            primaryAuthenticationLifecycleGeneration += 1
        }
        activeAuthenticationOperation = nil
    }

    private func retirePrimaryAuthenticationRoute(
        _ operation: LiveAuthenticationOperation
    ) async {
        guard let runtime = activeRuntimeHandle,
              let completedReceiptAtAdmission = operation.primaryNotificationCompletedReceiptAtAdmission,
              operation.retiresPrimaryNotificationRoute || operation.usesAPIKey
        else {
            return
        }
        if let invalidationReason = operation.primaryRuntimeInvalidationReason {
            let reason = switch invalidationReason {
            case .cancelledAfterLoginSuccess:
                "A cancelled ChatGPT login completed successfully"
            case .loginStartOutcomeUnknown:
                "A ChatGPT login start ended before its server challenge could be recovered"
            }
            invalidatePrimaryRuntime(
                runtime,
                rollbackAuthority: .captured(
                    accountKey: operation.rollbackAccountKey
                ),
                reason: reason
            )
            return
        }
        guard let scope = operation.resourceScope,
              scope.matchesOriginatingBackend(runtime.backend)
        else {
            return
        }
        let throughReceipt = await runtime.backend.notificationHighWatermark()
        guard activeAuthenticationOperation === operation,
              activeRuntimeHandle === runtime
        else {
            return
        }
        let awaitsLateLoginCompletion = operation.quarantinesLatePrimaryLoginCompletion
            && scope.stableChallengeID != nil
        let hasUnprocessedReceiptInterval = throughReceipt > completedReceiptAtAdmission
            && throughReceipt > completedPrimaryAuthNotificationReceipt
        guard hasUnprocessedReceiptInterval || awaitsLateLoginCompletion else {
            return
        }
        retiredPrimaryAuthenticationRoutes.append(.init(
            runtime: runtime,
            afterReceipt: completedReceiptAtAdmission,
            throughReceipt: throughReceipt,
            loginID: scope.stableChallengeID,
            rollbackAccountKey: operation.rollbackAccountKey,
            requiresRollbackAfterRuntimeClose: operation.terminalPublicationOwner != .notification,
            awaitsLateLoginCompletion: awaitsLateLoginCompletion
        ))
    }

    private func takeLoginRuntimeForCleanup(
        _ operation: LiveAuthenticationOperation?
    ) -> LiveAuthenticationOperation.ResourceCleanup {
        let cleanup = operation?.resourceScope?.takeForCleanup() ?? .init()
        if isActiveAuthenticationOperation(operation),
           operation?.phase != .terminalFailureObserved,
           operation?.phase != .terminalSuccessCommitted
        {
            operation?.phase = .waitingForCompletion
        }
        cleanup.monitorTask?.cancel()
        cleanup.notificationTask?.cancel()
        return cleanup
    }

    private func waitForAuthenticationSetup(
        _ operation: LiveAuthenticationOperation?
    ) async -> Bool {
        guard let operation else {
            return true
        }
        switch await runRuntimeShutdownCleanup(
            timeout: shutdownCleanupTimeout,
            operation: { @MainActor in await operation.waitForSetup() }
        ) {
        case .completed:
            return true
        case .timedOut:
            return false
        }
    }

    private func cleanupAuthenticationScope(_ scope: LiveAuthenticationOperation.ResourceScope) async {
        let cleanup = scope.takeForCleanup()
        cleanup?.notificationTask?.cancel()
        await closeIsolatedLoginRuntime(client: cleanup?.client, codexHomeURL: cleanup?.codexHomeURL)
    }

    private func cleanupLoginRuntime(_ cleanup: LiveAuthenticationOperation.ResourceCleanup) async {
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

    private static func prepareActiveAccount(
        from snapshot: CodexReviewBackendModel.Auth.Snapshot,
        persistedAccounts: [CodexAccount]
    ) -> PreparedAuthenticationAccount? {
        guard let activeAccountID = snapshot.activeAccountID,
              let accountSnapshot = snapshot.accounts.first(where: {
                  $0.id == activeAccountID
              }),
              let account = preparedCodexAccount(
                  from: accountSnapshot,
                  preservingRateLimitStateFrom: persistedAccounts
              )
        else {
            return nil
        }
        return .metadata(account)
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
    fileprivate let authNotificationStream: AsyncThrowingStream<JSONRPC.ReceivedNotification, Error>
    fileprivate let snapshot: RuntimePublicationSnapshot
    fileprivate var initialRateLimitTask: Task<Void, Never>?
    fileprivate var requiresAuthenticationRollbackAfterClose = false

    private weak var owner: LiveCodexReviewStoreBackend?
    private var isActivated = false
    private var closeTask: Task<Result<Void, any Error>, Never>?

    init(
        owner: LiveCodexReviewStoreBackend,
        generation: ReviewRuntimeGeneration,
        client: AppServerClient,
        backend: AppServerCodexReviewBackend,
        authNotificationStream: AsyncThrowingStream<JSONRPC.ReceivedNotification, Error>,
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
            let owner = owner
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
                owner?.restoreAuthenticationAfterRuntimeClose(self)
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
