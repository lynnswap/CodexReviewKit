import Foundation
import Synchronization

/// A live connection to a Codex app-server process.
///
/// `CodexAppServer` owns the app-server transport, performs the initial
/// JSON-RPC handshake, and routes server notifications to thread, turn, and
/// login domain objects.
public actor CodexAppServer {
    /// Options for creating a Codex app-server container.
    public struct Configuration: Sendable {
        public struct Deadlines: Equatable, Sendable {
            public var handshake: Duration?
            public var request: Duration?

            public init(
                handshake: Duration? = nil,
                request: Duration? = nil
            ) {
                self.handshake = handshake
                self.request = request
            }
        }

        /// Options for launching a local `codex app-server` process.
        public struct LocalProcess: Sendable {
            /// The `codex` executable path or command name.
            ///
            /// Set this when the executable is not available through the process
            /// environment. When `nil`, the default transport command is used.
            public var executable: String?

            /// Command-line arguments passed to the app-server executable.
            ///
            /// When `nil`, the transport uses the default arguments for starting
            /// `codex app-server`.
            public var arguments: [String]?

            /// Environment variables supplied to the app-server process.
            public var environment: [String: String]

            /// The Codex home directory used by the app-server process.
            public var codexHomeURL: URL

            /// Creates a configuration for launching a local app-server process.
            ///
            /// - Parameters:
            ///   - executable: The `codex` executable path or command name.
            ///   - arguments: Command-line arguments for the app-server process.
            ///   - environment: Environment variables for the app-server process.
            ///   - codexHomeURL: Codex home directory, or `nil` to use the local-process default.
            public init(
                executable: String? = nil,
                arguments: [String]? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                codexHomeURL: URL? = nil
            ) {
                self.executable = executable
                self.arguments = arguments
                self.environment = environment
                self.codexHomeURL = codexHomeURL ?? Self.defaultCodexHomeURL(environment: environment)
            }

            /// Returns the default Codex home for a local app-server process.
            ///
            /// The value honors `CODEX_HOME` first. On macOS command-line runs,
            /// it then matches the Codex CLI convention of `~/.codex`. Other
            /// Apple platform environments prefer Application Support so the
            /// default stays inside the app container when this API is compiled
            /// for a non-command-line host.
            public static func defaultCodexHomeURL(
                environment: [String: String] = ProcessInfo.processInfo.environment,
                homeDirectoryForCurrentUser: URL = FileManager.default.homeDirectoryForCurrentUser,
                applicationSupportDirectory: URL? = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first
            ) -> URL {
                if let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                   codexHome.isEmpty == false {
                    return URL(fileURLWithPath: codexHome, isDirectory: true)
                }
#if os(macOS)
                if let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   home.isEmpty == false {
                    return URL(fileURLWithPath: home, isDirectory: true)
                        .appendingPathComponent(".codex", isDirectory: true)
                }
#endif
                if let applicationSupportDirectory {
                    return applicationSupportDirectory
                        .appendingPathComponent("Codex", isDirectory: true)
                }
                return homeDirectoryForCurrentUser
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Application Support", isDirectory: true)
                    .appendingPathComponent("Codex", isDirectory: true)
            }
        }

        /// Local process launch settings for the app-server runtime.
        public var localProcess: LocalProcess

        /// The client name sent in the app-server `initialize` request.
        public var clientName: String

        /// The client version sent in the app-server `initialize` request.
        public var clientVersion: String

        /// Monotonic request and handshake deadlines. `nil` disables the
        /// corresponding deadline.
        public var deadlines: Deadlines

        package var deadlineClock: CodexDeadlineClock
        package var clock: CodexAppServerClock
        /// Handles typed requests initiated by the app-server.
        ///
        /// A `nil` handler uses the built-in policy, which declines approvals,
        /// cancels interactive requests, and rejects unsupported providers.
        public var serverRequestHandler: CodexAppServerRequestHandler?

        /// Creates a configuration for a Codex app-server container.
        ///
        /// - Parameters:
        ///   - localProcess: Local process launch settings.
        ///   - clientName: Client name sent during app-server initialization.
        ///   - clientVersion: Client version sent during app-server initialization.
        ///   - deadlines: Monotonic request and handshake deadlines.
        ///   - serverRequestHandler: Optional host policy for app-server-initiated requests.
        public init(
            localProcess: LocalProcess = .init(),
            clientName: String = "CodexAppServerKit",
            clientVersion: String = "1",
            deadlines: Deadlines = .init(),
            serverRequestHandler: CodexAppServerRequestHandler? = nil
        ) {
            self.localProcess = localProcess
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.deadlines = deadlines
            self.deadlineClock = .continuous
            self.clock = .init()
            self.serverRequestHandler = serverRequestHandler
        }

        package init(
            localProcess: LocalProcess = .init(),
            clientName: String = "CodexAppServerKit",
            clientVersion: String = "1",
            deadlines: Deadlines = .init(),
            deadlineClock: CodexDeadlineClock,
            clock: CodexAppServerClock = .init(),
            serverRequestHandler: CodexAppServerRequestHandler? = nil
        ) {
            self.localProcess = localProcess
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.deadlines = deadlines
            self.deadlineClock = deadlineClock
            self.clock = clock
            self.serverRequestHandler = serverRequestHandler
        }

        /// Applies CodexAppServerKit's built-in policy to a server request.
        ///
        /// Custom handlers can call this for requests they do not override.
        public static func defaultServerRequestHandler(
            request: CodexAppServerRequest
        ) async throws -> CodexAppServerRequestResolution {
            CodexAppServerRequestCodec.builtInResolution(
                for: request,
                clock: .init()
            )
        }

        package static func defaultServerRequestHandler(
            clock: CodexAppServerClock
        ) -> CodexAppServerRequestHandler {
            { request in
                CodexAppServerRequestCodec.builtInResolution(for: request, clock: clock)
            }
        }
    }

    private let client: AppServerClient
    private let router: CodexAppServerNotificationRouter
    private let turnReplayStore: TurnReplayStore
    private let connectionEventHub: ConnectionEventHub
    private let connectionLease: AppServerConnectionLease
    private let loginRegistry: LoginRegistry
    private let reviewRestartCoordinator: ReviewRestartCoordinator

    package nonisolated var appServerClient: AppServerClient {
        client
    }

    /// Starts a Codex app-server process and initializes the client session.
    ///
    /// The initializer completes after the app-server has accepted the
    /// `initialize` request and notification routing is ready.
    ///
    /// - Parameter configuration: Container and local-process configuration.
    /// - Throws: A transport, JSON-RPC, or app-server initialization error.
    public init(configuration: Configuration = .init()) async throws {
        let transportConfiguration = AppServerProcessTransport.Configuration(
            executable: configuration.localProcess.executable,
            arguments: configuration.localProcess.arguments,
            environment: configuration.localProcess.environment,
            codexHomeURL: configuration.localProcess.codexHomeURL
        )
        let transport: AppServerProcessTransport
        let connectionEventHub = ConnectionEventHub()
        do {
            transport = try AppServerProcessTransport(
                configuration: transportConfiguration,
                connectionEventHub: connectionEventHub
            )
        } catch let failure as CodexLaunchFailure {
            throw CodexAppServerError.launch(failure)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexAppServerError.launch(.spawn(
                executable: transportConfiguration.executable,
                errno: (error as? POSIXError)?.code.rawValue,
                message: error.localizedDescription
            ))
        }
        let connectionCloseAction = ConnectionCloseAction()
        let client = AppServerClient(
            transport: transport,
            deadlines: configuration.deadlines,
            deadlineClock: configuration.deadlineClock,
            connectionCloseAction: connectionCloseAction
        )
        let turnReplayStore = TurnReplayStore()
        let threadEventHub = ThreadEventHub()
        let loginRegistry = LoginRegistry(sleep: configuration.deadlineClock.sleep)
        let router = CodexAppServerNotificationRouter(
            client: client,
            turnReplayStore: turnReplayStore,
            threadEventHub: threadEventHub,
            loginRegistry: loginRegistry
        )
        let connection = AppServerConnection(
            transport: transport,
            client: client,
            router: router,
            turnReplayStore: turnReplayStore,
            serverRequestHandler: configuration.serverRequestHandler
                ?? Configuration.defaultServerRequestHandler(clock: configuration.clock)
        )
        let supervisor = ConnectionSupervisor(connection: connection)
        connectionCloseAction.bind(to: supervisor)
        let connectionLease = AppServerConnectionLease(
            supervisor: supervisor,
            processTerminationToken: transport.processTerminationToken
        )
        await supervisor.start()
        do {
            _ = try await client.initialize(
                clientName: configuration.clientName,
                clientVersion: configuration.clientVersion
            )
        } catch {
            await supervisor.closeConnection()
            throw error
        }
        self.client = client
        self.router = router
        self.turnReplayStore = turnReplayStore
        self.connectionEventHub = client.connectionEventHub
        self.connectionLease = connectionLease
        self.loginRegistry = loginRegistry
        self.reviewRestartCoordinator = ReviewRestartCoordinator()
    }

    package init(
        transport: any JSONRPC.Transport
    ) async throws {
        let connectionCloseAction = ConnectionCloseAction()
        let client = AppServerClient(
            transport: transport,
            connectionCloseAction: connectionCloseAction
        )
        let configuration = Configuration()
        let turnReplayStore = TurnReplayStore()
        let threadEventHub = ThreadEventHub()
        let loginRegistry = LoginRegistry(sleep: configuration.deadlineClock.sleep)
        let router = CodexAppServerNotificationRouter(
            client: client,
            turnReplayStore: turnReplayStore,
            threadEventHub: threadEventHub,
            loginRegistry: loginRegistry
        )
        let connection = AppServerConnection(
            transport: transport,
            client: client,
            router: router,
            turnReplayStore: turnReplayStore,
            serverRequestHandler: Configuration.defaultServerRequestHandler(
                clock: configuration.clock
            )
        )
        let supervisor = ConnectionSupervisor(connection: connection)
        connectionCloseAction.bind(to: supervisor)
        let connectionLease = AppServerConnectionLease(
            supervisor: supervisor,
            processTerminationToken: ProcessTerminationToken()
        )
        await supervisor.start()
        do {
            _ = try await client.initialize(
                clientName: configuration.clientName,
                clientVersion: configuration.clientVersion
            )
        } catch {
            await supervisor.closeConnection()
            throw error
        }
        self.client = client
        self.router = router
        self.turnReplayStore = turnReplayStore
        self.connectionEventHub = client.connectionEventHub
        self.connectionLease = connectionLease
        self.loginRegistry = loginRegistry
        self.reviewRestartCoordinator = ReviewRestartCoordinator()
    }

    package init(
        client: AppServerClient,
        router: CodexAppServerNotificationRouter,
        connectionLease: AppServerConnectionLease
    ) {
        self.client = client
        self.router = router
        self.turnReplayStore = router.turnReplayStore
        self.connectionEventHub = client.connectionEventHub
        self.connectionLease = connectionLease
        self.loginRegistry = router.loginRegistry
        self.reviewRestartCoordinator = ReviewRestartCoordinator()
    }

    package static func testing(
        transport: any JSONRPC.Transport
    ) async throws -> CodexAppServer {
        try await CodexAppServer(transport: transport)
    }

    /// Closes the app-server connection and stops notification routing.
    ///
    /// Call this when the container is no longer needed. Closing is idempotent
    /// from the perspective of public callers.
    public func close() async {
        _ = await reviewRestartCoordinator.invalidateAllAndWait()
        await connectionLease.closeConnection()
    }

    /// Returns connection-scoped diagnostics and the compact terminal event.
    ///
    /// This subscription does not retain the app-server connection or its lease.
    /// Call ``CodexConnectionEvents/cancel()`` to release only this subscriber.
    public func connectionEvents() -> CodexConnectionEvents {
        connectionEventHub.events()
    }

    /// Returns account-related app-server notifications as typed domain events.
    ///
    /// A malformed known current-v2 notification terminates connection-wide routing, including
    /// this sequence and active thread or turn sequences, with a typed
    /// ``CodexAppServerError/connectionTerminated(_:)`` protocol violation. Call
    /// ``CodexAccountEvents/cancel()``
    /// to release only this subscription without closing other routing.
    public func accountEvents() async -> CodexAccountEvents {
        await router.accountEvents()
    }

    /// Creates a new Codex thread in a workspace.
    ///
    /// - Parameters:
    ///   - workspace: The workspace directory for the thread.
    ///   - instructions: Optional base and developer instructions.
    ///   - options: Thread creation options, including model, approval, and sandbox settings.
    /// - Returns: A domain handle for the created thread.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func startThread(
        in workspace: URL,
        instructions: CodexInstructions? = nil,
        options: CodexThread.Options = .init()
    ) async throws -> CodexThread {
        let approvalMode = options.approvalMode ?? .autoReview
        let response = try await client.send(
            AppServerAPI.Thread.Start.Request(
                params: .init(
                    cwd: workspace.path,
                    model: options.model,
                    modelProvider: options.modelProvider,
                    ephemeral: options.ephemeral,
                    baseInstructions: instructions?.base,
                    developerInstructions: instructions?.developer,
                    approvalPolicy: approvalMode.approvalPolicy,
                    approvalsReviewer: approvalMode.approvalsReviewer,
                    sandbox: options.sandbox?.threadSandboxValue,
                    serviceName: options.serviceName,
                    serviceTier: options.serviceTier,
                    personality: options.personality?.rawValue,
                    config: options.config?.mapValues(\.appServerJSONValue),
                    permissions: options.permissions?.appServerPermissions,
                    sessionStartSource: options.sessionStartSource?.appServerSource,
                    threadSource: options.threadSource?.appServerSource
                )
            ),
            onPostWriteCancellation: { [client] response in
                let _: EmptyResponse = try await client.send(
                    AppServerAPI.Thread.Delete.Request(
                        params: .init(threadID: response.threadID)
                    )
                )
            }
        )
        return CodexThread(
            id: .init(rawValue: response.threadID),
            workspace: workspace,
            model: response.model ?? options.model,
            client: client,
            router: router,
            connectionLease: connectionLease
        )
    }

    /// Starts a Codex code review in a workspace.
    ///
    /// This creates a source thread for `workspace` and starts the app-server
    /// review lifecycle from that thread, so callers do not need to manually
    /// sequence `startThread` and `CodexThread.startReview`.
    ///
    /// - Parameters:
    ///   - workspace: The workspace directory to review.
    ///   - target: The repository changes or custom instructions to review.
    ///   - instructions: Optional base and developer instructions for the source thread.
    ///   - options: Thread creation options, including model, approval, and sandbox settings.
    ///   - delivery: Whether the app-server should run the review inline or in a detached review thread.
    /// - Returns: A live review session.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func startReview(
        in workspace: URL,
        target: CodexReviewTarget,
        instructions: CodexInstructions? = nil,
        options: CodexThread.Options = .init(),
        delivery: CodexReviewDelivery = .inline
    ) async throws -> CodexReviewSession {
        try Task.checkCancellation()
        let thread = try await startThread(
            in: workspace,
            instructions: instructions,
            options: options
        )
        do {
            try Task.checkCancellation()
        } catch {
            await deleteThreadIgnoringCallerCancellation(thread.id)
            throw error
        }

        let review: CodexReviewSession
        do {
            review = try await thread.startReview(
                target: target,
                delivery: delivery
            )
        } catch {
            await deleteThreadIgnoringCallerCancellation(thread.id)
            throw error
        }

        do {
            try Task.checkCancellation()
            return review
        } catch {
            await cleanupReviewIgnoringCallerCancellation(review.identity)
            throw error
        }
    }

    package func reviewEventThread(
        for review: CodexReviewSession,
        workspace: URL
    ) -> CodexThread {
        CodexThread(
            id: review.activeTurnThreadID,
            workspace: workspace,
            model: review.model,
            client: client,
            router: router,
            connectionLease: connectionLease
        )
    }

    /// Resumes an existing Codex thread.
    ///
    /// - Parameters:
    ///   - id: The thread identifier to resume.
    ///   - options: Resume options that may override the stored thread context.
    /// - Returns: A domain handle for the resumed thread.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func resumeThread(
        _ id: CodexThreadID,
        options: CodexThread.ResumeOptions = .init()
    ) async throws -> CodexThread {
        let response: AppServerAPI.Thread.Resume.Response = try await withThreadEventGeneration(
            id,
            router: router
        ) { generation in
            try await client.send(
                AppServerAPI.Thread.Resume.Request(
                    threadID: id.rawValue,
                    params: threadStartParams(options: options)
                ),
                reconcileResponse: { response in
                    if let latestTurn = response.thread.turns?.last {
                        let snapshot = Self.turnSnapshots(from: [latestTurn])[0]
                        if snapshot.state == .inProgress {
                            generation.seedProvisionalResumeSnapshot(snapshot)
                        }
                    }
                },
                onWriteAccepted: generation.acceptWrite,
                onResponseRejected: generation.rejectResponse,
                onResponseAccepted: generation.acceptResponse
            )
        }
        return await thread(from: response.thread, model: response.model ?? options.model)
    }

    /// Restores a persisted app-server review run as a live review session handle.
    ///
    /// The restored session can consume review events and cancel the active
    /// review turn. The active turn thread is resumed first so app-server has
    /// the stored thread context loaded before the review handle is rebuilt.
    ///
    /// - Parameters:
    ///   - identity: Persisted review run identity.
    ///   - threadOptions: Resume options for the active turn thread. When `model` is
    ///     `nil`, `identity.model` is used.
    /// - Returns: A live review session handle for the persisted run.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func resumeReview(
        _ identity: CodexReviewIdentity,
        threadOptions: CodexThread.ResumeOptions = .init()
    ) async throws -> CodexReviewSession {
        var threadOptions = threadOptions
        if threadOptions.model == nil {
            threadOptions.model = identity.model
        }
        let activeTurnThreadID = identity.activeTurnThreadID
        let initialTurn = CodexTurnSnapshot(
            id: identity.turnID,
            state: .inProgress,
            itemsLoadState: .notLoaded
        )
        let reservation = await turnReplayStore.reserveRestoredGeneration(
            turnID: identity.turnID,
            initialSnapshot: initialTurn,
            connectionLease: connectionLease
        )
        let state = reservation.state
        await router.seedTurn(identity.turnID, threadID: activeTurnThreadID)
        do {
            let activeThread = try await resumeThread(
                activeTurnThreadID,
                options: threadOptions
            )
            await turnReplayStore.commitRestoredGeneration(reservation)
            if await state.snapshot() != .live {
                await router.discardTurnAssociation(
                    identity.turnID,
                    threadID: activeTurnThreadID
                )
            }
            return await activeThread.reviewSession(
                identity,
                model: activeThread.model ?? identity.model,
                initialTurn: initialTurn,
                state: state
            )
        } catch {
            let removedGeneration = await turnReplayStore.discardRestoredGeneration(reservation)
            if removedGeneration {
                await router.discardTurnAssociation(
                    identity.turnID,
                    threadID: activeTurnThreadID
                )
            }
            throw error
        }
    }

    /// Cancels a running review and prepares it for a later restart.
    ///
    /// The returned token is process-local to this ``CodexAppServer`` instance.
    /// Cleanup ownership for the interrupted review is retained internally until
    /// ``cleanupReview(_:additionalCleanupThreadIDs:)`` is called for the same
    /// source thread.
    ///
    /// - Parameters:
    ///   - identity: Persisted review run identity to interrupt.
    ///   - threadOptions: Resume options for the active turn thread. When `model` is
    ///     `nil`, `identity.model` is used.
    /// - Returns: A token that can be passed to ``restartPreparedReview(_:target:delivery:threadOptions:)``.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func prepareReviewRestart(
        _ identity: CodexReviewIdentity,
        threadOptions: CodexThread.ResumeOptions = .init()
    ) async throws -> CodexReviewRestartToken {
        try await reviewRestartCoordinator.prepare(
            identity,
            operations: .init { [self] identities in
                identities.record(identity)
                let review = try await resumeReview(
                    identity,
                    threadOptions: threadOptions
                )
                let acknowledgement = try await review
                    .interruptAndAwaitTerminalAcknowledgement {
                    retryCancellation in
                    if retryCancellation.turnID != Optional(identity.turnID) {
                        identities.record(Self.reviewCleanupIdentity(
                            for: retryCancellation,
                            sourceIdentity: identity,
                            model: review.model
                        ))
                    }
                }
                guard case .interrupted = acknowledgement.outcome else {
                    throw CodexTransportFailure.contractViolation(
                        message: "Preparing a review restart requires an interrupted terminal acknowledgement."
                    )
                }
                let cancellation = acknowledgement.cancellation
                identities.record(Self.reviewCleanupIdentity(
                    for: cancellation,
                    sourceIdentity: identity,
                    model: review.model
                ))
                return .init(
                    rollbackThreadID: cancellation.threadID,
                    rollbackModel: review.model
                )
            }
        )
    }

    /// Restarts a review that was previously prepared by ``prepareReviewRestart(_:threadOptions:)``.
    ///
    /// The restart first reloads and rolls back the thread that owned the
    /// interrupted active turn, then reloads the source thread and starts a new
    /// review from that source.
    ///
    /// - Parameters:
    ///   - token: Token returned by ``prepareReviewRestart(_:threadOptions:)``.
    ///   - target: The repository changes or custom instructions to review.
    ///   - delivery: Whether the app-server should run the review inline or in a detached review thread.
    ///   - threadOptions: Resume options for the source thread. For inline
    ///     reviews, `token.interruptedIdentity.model` is used when `model` is
    ///     `nil`; detached review restarts leave source-thread model selection
    ///     to app-server unless the caller supplies an explicit model.
    /// - Returns: A live review session for the restarted review.
    /// - Throws: ``CodexAppServerError/reviewRestartUnavailable(_:)`` when the token is stale.
    public func restartPreparedReview(
        _ token: CodexReviewRestartToken,
        target: CodexReviewTarget,
        delivery: CodexReviewDelivery = .inline,
        threadOptions: CodexThread.ResumeOptions = .init()
    ) async throws -> CodexReviewSession {
        let signature = ReviewRestartCoordinator.RestartInvocationSignature(
            target: target,
            delivery: delivery,
            threadOptions: threadOptions
        )
        return try await reviewRestartCoordinator.restart(
            token,
            signature: signature,
            operations: .init(
                loadRollbackThread: { [self] context in
                    try await resumeThread(
                        context.rollbackThreadID,
                        options: .init(model: context.rollbackModel)
                    )
                },
                rollback: { thread in
                    try await thread.rollback(turnCount: 1)
                },
                loadSourceThread: { [self] context in
                    var sourceThreadOptions = threadOptions
                    if sourceThreadOptions.model == nil,
                       context.interruptedIdentity.activeTurnThreadID
                        == context.interruptedIdentity.sourceThreadID {
                        sourceThreadOptions.model = context.interruptedIdentity.model
                    }
                    return try await resumeThread(
                        context.interruptedIdentity.sourceThreadID,
                        options: sourceThreadOptions
                    )
                },
                startReview: { sourceThread, identities in
                    try await sourceThread.startReview(
                        target: target,
                        delivery: delivery,
                        onPostWriteCancellation: { review in
                            identities.record(review.identity)
                            try await Self.interruptLateReviewSession(review)
                        }
                    )
                },
                cleanupLateSession: Self.interruptLateReviewSession
            )
        )
    }

    /// Invalidates one prepared restart and returns every review identity whose
    /// cleanup ownership was retained for its source thread.
    ///
    /// If preparation or restart is in flight, this operation cancels and
    /// awaits it. A replacement session that arrives after invalidation is
    /// interrupted before its identity is returned.
    public func discardPreparedReviewRestart(
        _ token: CodexReviewRestartToken
    ) async -> [CodexReviewIdentity] {
        await reviewRestartCoordinator.invalidate(token)
    }

    /// Invalidates all prepared restarts and transfers their retained cleanup
    /// identities grouped by source thread.
    ///
    /// This terminally closes restart preparation for this app-server instance.
    /// Call it while stopping the owning runtime, before ``close()``.
    public func discardAllPreparedReviewRestarts()
        async -> [CodexThreadID: [CodexReviewIdentity]] {
        await reviewRestartCoordinator.invalidateAllAndWait()
    }

    package func waitForReviewRestartWaiterCountForTesting(
        tokenID: CodexReviewRestartToken.ID,
        atLeast minimumCount: Int
    ) async {
        await reviewRestartCoordinator.waitForRestartWaiterCountForTesting(
            tokenID: tokenID,
            atLeast: minimumCount
        )
    }

    package func waitForReviewRestartInvalidationRequestForTesting(
        tokenID: CodexReviewRestartToken.ID
    ) async {
        await reviewRestartCoordinator.waitForInvalidationRequestForTesting(
            tokenID: tokenID
        )
    }

    /// Deletes all app-server threads owned by a review lifecycle and reports
    /// each failed deletion in source-last attempt order.
    ///
    /// Retained cleanup identities from prepared restarts are included, duplicate
    /// thread identifiers are removed, and the source thread is deleted last.
    /// Retained restart identities remain registered when any deletion fails so
    /// the caller can retry without losing thread identities known only to this
    /// app-server generation.
    ///
    /// - Parameters:
    ///   - identity: Review identity whose source thread owns the lifecycle.
    ///   - additionalCleanupThreadIDs: Extra cleanup ID sequences, in preferred
    ///     per-sequence order, to merge with retained review cleanup IDs.
    @discardableResult
    public func cleanupReview(
        _ identity: CodexReviewIdentity,
        additionalCleanupThreadIDs: [[CodexThreadID]] = []
    ) async -> CodexReviewCleanupResult {
        let sourceThreadID = identity.sourceThreadID
        let retainedIdentities = await reviewRestartCoordinator
            .invalidateAndTakeRetainedIdentities(sourceThreadID: sourceThreadID)

        let cleanupThreadIDs = Self.orderedReviewCleanupThreadIDs(
            sourceThreadID: sourceThreadID,
            sequences: retainedIdentities.map(\.cleanupThreadIDs)
                + [identity.cleanupThreadIDs]
                + additionalCleanupThreadIDs
        )
        var failures: [CodexReviewCleanupFailure] = []
        for threadID in cleanupThreadIDs {
            do {
                try await deleteThread(threadID)
            } catch {
                failures.append(.init(
                    threadID: threadID,
                    message: error.localizedDescription
                ))
            }
        }
        if failures.isEmpty == false {
            await reviewRestartCoordinator.restoreRetainedIdentities(
                retainedIdentities
            )
        }
        return .init(
            attemptedThreadIDs: cleanupThreadIDs,
            failures: failures
        )
    }

    /// Forks an existing Codex thread into a new thread.
    ///
    /// - Parameters:
    ///   - id: The source thread identifier.
    ///   - options: Options for the forked thread.
    /// - Returns: A domain handle for the forked thread.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func forkThread(
        _ id: CodexThreadID,
        options: CodexThread.Options = .init()
    ) async throws -> CodexThread {
        let response = try await client.send(
            AppServerAPI.Thread.Fork.Request(
                threadID: id.rawValue,
                params: threadStartParams(options: options)
            ),
            onPostWriteCancellation: { [client] response in
                let _: EmptyResponse = try await client.send(
                    AppServerAPI.Thread.Delete.Request(
                        params: .init(threadID: response.thread.id)
                    )
                )
            }
        )
        return await thread(from: response.thread)
    }

    /// Restores an archived Codex thread.
    ///
    /// - Parameter id: The archived thread identifier.
    /// - Returns: A domain handle for the restored thread.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func unarchiveThread(_ id: CodexThreadID) async throws -> CodexThread {
        let response = try await sendUnarchiveThread(id)
        return await thread(from: response.thread)
    }

    package func unarchiveThreadSnapshot(_ id: CodexThreadID) async throws -> CodexThreadSnapshot {
        let response = try await sendUnarchiveThread(id)
        let snapshot = Self.threadSnapshot(from: response.thread, includesTurns: false)
        await router.seedTurns(snapshot.turns, threadID: id)
        return snapshot
    }

    private func sendUnarchiveThread(
        _ id: CodexThreadID
    ) async throws -> AppServerAPI.Thread.Unarchive.Response {
        try await client.send(
            AppServerAPI.Thread.Unarchive.Request(
                params: .init(threadID: id.rawValue)
            ))
    }

    /// Archives a Codex thread.
    ///
    /// - Parameter id: The thread identifier to archive.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func archiveThread(_ id: CodexThreadID) async throws {
        let _: EmptyResponse = try await client.send(
            AppServerAPI.Thread.Archive.Request(
                params: .init(threadID: id.rawValue)
            ))
    }

    /// Permanently deletes a Codex thread.
    ///
    /// - Parameter id: The thread identifier to delete.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func deleteThread(_ id: CodexThreadID) async throws {
        let _: EmptyResponse = try await client.send(
            AppServerAPI.Thread.Delete.Request(
                params: .init(threadID: id.rawValue)
            ))
    }

    /// Lists Codex threads visible to the app-server account.
    ///
    /// - Parameter query: Paging and filtering options.
    /// - Returns: A page of thread snapshots.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func listThreads(_ query: CodexThreadQuery = .init()) async throws -> CodexThreadPage {
        let response = try await client.send(
            AppServerAPI.Thread.List.Request(
                params: .init(
                    archived: query.archived,
                    cursor: query.cursor,
                    cwd: query.workspaces.map { .paths($0.map(\.path)) },
                    limit: query.limit,
                    modelProviders: query.modelProviders,
                    searchTerm: query.searchTerm,
                    sortDirection: query.sortDirection?.rawValue,
                    sortKey: query.sortKey?.rawValue,
                    sourceKinds: query.sourceKinds?.map(\.rawValue),
                    useStateDbOnly: query.useStateDBOnly
                )))
        let snapshots = response.data.map { Self.threadSnapshot(from: $0, includesTurns: false) }
        for snapshot in snapshots {
            await router.seedTurns(snapshot.turns, threadID: snapshot.id)
        }
        return .init(
            threads: snapshots,
            nextCursor: response.nextCursor,
            backwardsCursor: response.backwardsCursor
        )
    }

    /// Lists available Codex models.
    ///
    /// - Parameter includeHidden: Whether hidden models should be included.
    /// - Returns: The complete model list across all app-server result pages.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func models(includeHidden: Bool = false) async throws -> [CodexModel] {
        var cursor: String?
        var models: [CodexModel] = []
        repeat {
            let response = try await client.send(
                AppServerAPI.Model.List.Request(
                    params: .init(cursor: cursor, includeHidden: includeHidden)
                ))
            models.append(contentsOf: response.data)
            cursor = response.nextCursor
        } while cursor != nil
        return models
    }

    /// Reads the active Codex account.
    ///
    /// - Parameter refreshToken: Whether the app-server should refresh token state before returning.
    /// - Returns: The active account, or `nil` when no account is signed in.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func account(refreshToken: Bool = false) async throws -> CodexAccount? {
        let response = try await client.send(
            AppServerAPI.Account.Read.Request(params: .init(refreshToken: refreshToken))
        )
        return response.account.map(Self.account)
    }

    /// Reads the app-server configuration visible to Codex clients.
    ///
    /// - Returns: Model, reasoning, review model, and service-tier settings.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func configuration() async throws -> CodexConfiguration {
        let response = try await client.send(AppServerAPI.Config.Read.Request())
        let reasoningEffort = response.config.modelReasoningEffort.map {
            CodexReasoningEffort(rawValue: $0)
        }
        return .init(
            model: response.config.model,
            reviewModel: response.config.reviewModel,
            reasoningEffort: reasoningEffort,
            serviceTier: response.config.serviceTier
        )
    }

    /// Applies a partial update to the app-server configuration.
    ///
    /// Fields left unchanged in the patch are not sent. Fields explicitly set
    /// to `nil` are cleared in the app-server configuration.
    ///
    /// - Parameter patch: The configuration fields to update.
    /// - Throws: A transport, JSON-RPC, or app-server configuration error.
    public func updateConfiguration(_ patch: CodexConfigurationPatch) async throws {
        var edits: [AppServerAPI.Config.Edit] = []
        if patch.updatesReviewModel {
            edits.append(.init(
                keyPath: "review_model",
                value: patch.reviewModel.map(AppServerAPI.Config.Value.string) ?? .null
            ))
        }
        if patch.updatesReasoningEffort {
            edits.append(.init(
                keyPath: "model_reasoning_effort",
                value: patch.reasoningEffort.map { .string($0.rawValue) } ?? .null
            ))
        }
        if patch.updatesServiceTier {
            edits.append(.init(
                keyPath: "service_tier",
                value: patch.serviceTier.map(AppServerAPI.Config.Value.string) ?? .null
            ))
        }
        guard edits.isEmpty == false else {
            return
        }
        let _: AppServerAPI.Config.BatchWrite.Response = try await client.send(
            AppServerAPI.Config.BatchWrite.Request(params: .init(edits: edits))
        )
    }

    /// Reads Codex account rate-limit information.
    ///
    /// - Returns: Current plan type and rate-limit windows reported by the app-server.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func rateLimits() async throws -> CodexRateLimits {
        let response = try await client.send(AppServerAPI.Account.RateLimits.Read.Request())
        await router.replaceRateLimits(with: response)
        return .init(appServer: response)
    }

    /// Starts a ChatGPT browser login flow.
    ///
    /// - Returns: A login handle containing the browser authentication URL.
    /// - Throws: A transport, JSON-RPC, or app-server login error.
    public func loginChatGPT(
        accountReadinessTimeout: Duration? = nil
    ) async throws -> CodexLoginHandle {
        let state = try await loginRegistry.reserve(
            readinessTimeout: accountReadinessTimeout,
            cancel: { [client] id, deadline in
                let response: AppServerAPI.Account.Login.Cancel.Response = try await client.send(
                    method: AppServerAPI.Account.Login.Cancel.Request.method,
                    params: AppServerAPI.Account.Login.Cancel.Params(loginID: id.rawValue),
                    responseType: AppServerAPI.Account.Login.Cancel.Response.self,
                    purpose: .operation(AppServerAPI.Account.Login.Cancel.Request.method),
                    deadline: deadline
                )
                switch response.status {
                case "canceled", "notFound":
                    return .cancelled
                default:
                    throw CodexAppServerError.malformedNotification(.init(
                        method: "account/login/cancel response",
                        message: "Unknown cancel status \(response.status).",
                        rawData: nil
                    ))
                }
            },
            closeConnection: { [connectionLease] in
                await connectionLease.closeConnection()
            }
        )
        do {
            let response = try await client.send(
                AppServerAPI.Account.Login.Start.Request(params: .chatGPT()),
                onPostWriteCancellation: { [loginRegistry] response in
                    let (id, url) = try Self.chatGPTLoginIdentity(from: response)
                    let handle = try await loginRegistry.bind(
                        state,
                        id: id,
                        authenticationURL: url
                    )
                    _ = try await handle.cancel()
                }
            )
            let (id, url) = try Self.chatGPTLoginIdentity(from: response)
            return try await loginRegistry.bind(state, id: id, authenticationURL: url)
        } catch {
            await loginRegistry.abandon(state)
            throw error
        }
    }

    /// Replaces the active credentials with an API key.
    ///
    /// A successful return means the app-server stored and reloaded the key in
    /// its configured Codex home. It does not prove that a remote API request
    /// will accept the key.
    ///
    /// - Parameter apiKey: A nonempty API key without leading or trailing whitespace.
    /// - Throws: An input, transport, JSON-RPC, or app-server authentication error.
    public func login(apiKey: String) async throws {
        try Self.validate(apiKey: apiKey)

        let acceptedWriteHasUnknownOutcome = Mutex(false)
        let response: AppServerAPI.Account.Login.Response
        do {
            response = try await client.send(
                AppServerAPI.Account.Login.Start.Request(params: .apiKey(apiKey)),
                onWriteAccepted: {
                    acceptedWriteHasUnknownOutcome.withLock { $0 = true }
                },
                retriesOverloadResponses: false,
                postWriteCallerCancellationPolicy: .returnResponse
            )
        } catch is CancellationError {
            guard acceptedWriteHasUnknownOutcome.withLock({ $0 }) else {
                throw CancellationError()
            }
            throw CodexAppServerError.authenticationOutcomeUnknown(.transportEnded)
        } catch let error as CodexAppServerError {
            throw Self.apiKeyLoginError(
                from: error,
                acceptedWriteHasUnknownOutcome: acceptedWriteHasUnknownOutcome.withLock { $0 }
            )
        }

        guard response == .apiKey else {
            throw CodexAppServerError.authenticationOutcomeUnknown(.unexpectedResponse)
        }
    }

    /// Logs out of the active Codex account.
    ///
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func logout() async throws {
        let _: EmptyResponse = try await client.send(AppServerAPI.Account.Logout.Request())
    }

    private func threadStartParams(options: CodexThread.Options) -> AppServerAPI.Thread.Start.Params {
        .init(
            model: options.model,
            modelProvider: options.modelProvider,
            ephemeral: options.ephemeral,
            approvalPolicy: options.approvalMode?.approvalPolicy,
            approvalsReviewer: options.approvalMode?.approvalsReviewer,
            sandbox: options.sandbox?.threadSandboxValue,
            serviceName: options.serviceName,
            serviceTier: options.serviceTier,
            personality: options.personality?.rawValue,
            config: options.config?.mapValues(\.appServerJSONValue),
            permissions: options.permissions?.appServerPermissions,
            sessionStartSource: options.sessionStartSource?.appServerSource,
            threadSource: options.threadSource?.appServerSource
        )
    }

    private func thread(
        from snapshot: AppServerAPI.Thread.Snapshot,
        model: String? = nil
    ) async -> CodexThread {
        let threadID = CodexThreadID(rawValue: snapshot.id)
        await router.seedTurns(
            snapshot.turns.map(Self.turnSnapshots(from:)),
            threadID: threadID
        )
        return CodexThread(
            id: threadID,
            workspace: snapshot.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) },
            model: model,
            client: client,
            router: router,
            connectionLease: connectionLease
        )
    }

    private func deleteThreadIgnoringCallerCancellation(_ id: CodexThreadID) async {
        await Task { [self] in
            try? await deleteThread(id)
        }.value
    }

    private func cleanupReviewIgnoringCallerCancellation(_ identity: CodexReviewIdentity) async {
        _ = await Task { [self] in
            await cleanupReview(identity)
        }.value
    }

    private nonisolated static func reviewCleanupIdentity(
        for cancellation: CodexTurnCancellation,
        sourceIdentity: CodexReviewIdentity,
        model: String?
    ) -> CodexReviewIdentity {
        CodexReviewIdentity(
            threadID: sourceIdentity.sourceThreadID,
            turnID: cancellation.turnID ?? sourceIdentity.turnID,
            reviewThreadID: cancellation.threadID == sourceIdentity.sourceThreadID ? nil : cancellation.threadID,
            model: model ?? sourceIdentity.model
        )
    }

    private nonisolated static func interruptLateReviewSession(
        _ review: CodexReviewSession
    ) async throws {
        _ = try await review.interruptAndAwaitTerminalAcknowledgement()
    }

    private nonisolated static func orderedReviewCleanupThreadIDs(
        sourceThreadID: CodexThreadID,
        sequences: [[CodexThreadID]]
    ) -> [CodexThreadID] {
        var seen: Set<CodexThreadID> = []
        var threadIDs: [CodexThreadID] = []
        for sequence in sequences {
            for threadID in sequence where threadID != sourceThreadID && seen.insert(threadID).inserted {
                threadIDs.append(threadID)
            }
        }
        if seen.insert(sourceThreadID).inserted {
            threadIDs.append(sourceThreadID)
        }
        return threadIDs
    }

    package nonisolated static func threadSnapshot(
        from snapshot: AppServerAPI.Thread.Snapshot,
        includesTurns: Bool
    ) -> CodexThreadSnapshot {
        let turns = turnSnapshots(from: snapshot.turns, includesTurns: includesTurns)
        return .init(
            id: .init(rawValue: snapshot.id),
            workspace: snapshot.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) },
            name: snapshot.name,
            preview: snapshot.preview,
            modelProvider: snapshot.modelProvider,
            sessionID: snapshot.sessionID,
            parentThreadID: snapshot.parentThreadID.map { .init(rawValue: $0) },
            source: snapshot.source.map(threadSessionSource(from:)),
            gitInfo: snapshot.gitInfo.map {
                CodexThreadGitInfo(
                    sha: $0.sha,
                    branch: $0.branch,
                    originURL: $0.originURL
                )
            },
            createdAt: snapshot.createdAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            updatedAt: snapshot.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            recencyAt: snapshot.recencyAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            status: snapshot.status.map {
                CodexThreadStatus(type: $0.type, activeFlags: $0.activeFlags)
            },
            ephemeral: snapshot.ephemeral,
            turns: turns,
            turnItemsAreAuthoritative: includesTurns,
            presentFields: threadSnapshotPresentFields(from: snapshot, turns: turns)
        )
    }

    private nonisolated static func threadSnapshotPresentFields(
        from snapshot: AppServerAPI.Thread.Snapshot,
        turns: [CodexTurnSnapshot]?
    ) -> Set<CodexThreadSnapshot.Field> {
        var fields: Set<CodexThreadSnapshot.Field> = []
        for field in snapshot.presentFields {
            switch field {
            case .sessionID:
                fields.insert(.sessionID)
            case .parentThreadID:
                fields.insert(.parentThreadID)
            case .cwd:
                fields.insert(.workspace)
            case .name:
                fields.insert(.name)
            case .preview:
                fields.insert(.preview)
            case .modelProvider:
                fields.insert(.modelProvider)
            case .source:
                fields.insert(.source)
            case .gitInfo:
                fields.insert(.gitInfo)
            case .createdAt:
                fields.insert(.createdAt)
            case .updatedAt:
                fields.insert(.updatedAt)
            case .recencyAt:
                fields.insert(.recencyAt)
            case .status:
                fields.insert(.status)
            case .ephemeral:
                fields.insert(.ephemeral)
            case .turns:
                if turns != nil {
                    fields.insert(.turns)
                }
            }
        }
        if turns != nil {
            fields.insert(.turns)
        }
        return fields
    }

    private nonisolated static func threadSessionSource(
        from source: AppServerAPI.Thread.SessionSource
    ) -> CodexThreadSessionSource {
        switch source {
        case .cli:
            .cli
        case .vscode:
            .vscode
        case .exec:
            .exec
        case .appServer:
            .appServer
        case .custom(let value):
            .custom(value)
        case .subAgent(let source):
            .subAgent(threadSubAgentSource(from: source))
        case .unknown:
            .unknown
        }
    }

    private nonisolated static func threadSubAgentSource(
        from source: AppServerAPI.Thread.SessionSource.SubAgent
    ) -> CodexThreadSessionSource.SubAgent {
        switch source {
        case .review:
            .review
        case .compact:
            .compact
        case .threadSpawn(let spawn):
            .threadSpawn(.init(
                parentThreadID: .init(rawValue: spawn.parentThreadID),
                depth: spawn.depth,
                agentPath: spawn.agentPath,
                agentNickname: spawn.agentNickname,
                agentRole: spawn.agentRole
            ))
        case .memoryConsolidation:
            .memoryConsolidation
        case .other(let value):
            .other(value)
        }
    }

    package nonisolated static func turnSnapshots(
        from turns: [AppServerAPI.Turn.Payload]
    ) -> [CodexTurnSnapshot] {
        turns.map {
            let status = CodexTurnStatus(rawValue: $0.status)
            let state: CodexTurnSnapshot.State = switch status {
            case .inProgress:
                .inProgress
            case .completed:
                .completed
            case .interrupted:
                .interrupted
            case .failed:
                .failed(Self.requiredTurnError(from: $0))
            case .unknown(let rawValue):
                .unknown(rawValue: rawValue, error: $0.error.map(Self.turnError(from:)))
            }
            return CodexTurnSnapshot(
                id: .init(rawValue: $0.id),
                state: state,
                itemsLoadState: $0.itemsLoadState ?? ($0.items == nil ? .notLoaded : .full),
                items: AppServerThreadItemMapping.threadItems(from: $0.items),
                startedAt: $0.startedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                completedAt: $0.completedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                duration: $0.durationMS.map { .milliseconds(Int64($0)) }
            )
        }
    }

    private nonisolated static func requiredTurnError(
        from turn: AppServerAPI.Turn.Payload
    ) -> CodexTurnError {
        guard let error = turn.error else {
            preconditionFailure("Strict Turn.Payload decoding requires failed turns to carry an error.")
        }
        return turnError(from: error)
    }

    package nonisolated static func turnError(
        from error: AppServerAPI.Turn.Error
    ) -> CodexTurnError {
        .init(
            message: error.message,
            info: error.codexErrorInfo.map(Self.errorInfo(from:)),
            additionalDetails: error.additionalDetails
        )
    }

    private nonisolated static func errorInfo(
        from info: AppServerAPI.CodexErrorInfo
    ) -> CodexErrorInfo {
        switch info {
        case .contextWindowExceeded: .contextWindowExceeded
        case .sessionBudgetExceeded: .sessionBudgetExceeded
        case .usageLimitExceeded: .usageLimitExceeded
        case .serverOverloaded: .serverOverloaded
        case .cyberPolicy: .cyberPolicy
        case .httpConnectionFailed(let status): .httpConnectionFailed(httpStatusCode: status)
        case .responseStreamConnectionFailed(let status):
            .responseStreamConnectionFailed(httpStatusCode: status)
        case .internalServerError: .internalServerError
        case .unauthorized: .unauthorized
        case .badRequest: .badRequest
        case .threadRollbackFailed: .threadRollbackFailed
        case .sandboxError: .sandboxError
        case .responseStreamDisconnected(let status):
            .responseStreamDisconnected(httpStatusCode: status)
        case .responseTooManyFailedAttempts(let status):
            .responseTooManyFailedAttempts(httpStatusCode: status)
        case .activeTurnNotSteerable(let kind): .activeTurnNotSteerable(turnKind: kind)
        case .other: .other
        case .unknown(let rawValue): .unknown(rawValue: rawValue)
        }
    }

    private nonisolated static func turnSnapshots(
        from turns: [AppServerAPI.Turn.Payload]?,
        includesTurns: Bool
    ) -> [CodexTurnSnapshot]? {
        guard let turns else {
            return includesTurns ? [] : nil
        }
        guard includesTurns || turns.isEmpty == false else {
            return nil
        }
        return turnSnapshots(from: turns)
    }

    package nonisolated static func account(
        from snapshot: AppServerAPI.Account.Snapshot
    ) -> CodexAccount {
        .init(
            id: snapshot.id,
            kind: .init(rawValue: snapshot.kind.rawValue) ?? .chatGPT,
            label: snapshot.label,
            planType: snapshot.planType
        )
    }

    private nonisolated static func chatGPTLoginIdentity(
        from response: AppServerAPI.Account.Login.Response
    ) throws -> (CodexLoginHandle.ID, URL) {
        guard case .chatgpt(let loginID, let authURL) = response else {
            throw CodexAppServerError.malformedNotification(.init(
                method: "account/login/start response",
                message: "Expected ChatGPT login response.",
                rawData: nil
            ))
        }
        guard let url = URL(string: authURL) else {
            throw CodexAppServerError.malformedNotification(.init(
                method: "account/login/start response",
                message: "Invalid ChatGPT authentication URL.",
                rawData: nil
            ))
        }
        return (.init(rawValue: loginID), url)
    }

    private nonisolated static func validate(apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw CodexAppServerError.invalidAPIKey(.empty)
        }
        guard trimmed == apiKey else {
            throw CodexAppServerError.invalidAPIKey(.surroundingWhitespace)
        }
    }

    private nonisolated static func apiKeyLoginError(
        from error: CodexAppServerError,
        acceptedWriteHasUnknownOutcome: Bool
    ) -> CodexAppServerError {
        if case .request(let failure) = error {
            switch failure.kind {
            case .server, .overloadRetryExhausted:
                return .request(sanitizedAPIKeyLoginRequestFailure(failure))
            case .deadlineExceeded(let duration) where acceptedWriteHasUnknownOutcome:
                return .authenticationOutcomeUnknown(.deadlineExceeded(duration))
            case .invalidResponse where acceptedWriteHasUnknownOutcome:
                return .authenticationOutcomeUnknown(.invalidResponse)
            case .write where acceptedWriteHasUnknownOutcome,
                 .transport where acceptedWriteHasUnknownOutcome:
                return .authenticationOutcomeUnknown(.transportEnded)
            case .encode, .write, .transport, .invalidResponse, .deadlineExceeded:
                return .request(sanitizedAPIKeyLoginRequestFailure(failure))
            }
        }
        if case .connectionTerminated = error, acceptedWriteHasUnknownOutcome {
            return .authenticationOutcomeUnknown(.connectionTerminated)
        }
        if case .connectionTerminated(let termination) = error {
            return .connectionTerminated(sanitizedAPIKeyLoginTermination(termination))
        }
        return error
    }

    private nonisolated static func sanitizedAPIKeyLoginRequestFailure(
        _ failure: CodexRequestFailure
    ) -> CodexRequestFailure {
        let kind: CodexRequestFailure.Kind = switch failure.kind {
        case .encode:
            .encode(message: "API-key login request encoding failed.")
        case .write(let transportFailure):
            .write(sanitizedAPIKeyLoginTransportFailure(transportFailure))
        case .transport(let transportFailure):
            .transport(sanitizedAPIKeyLoginTransportFailure(transportFailure))
        case .server(let serverError):
            .server(.init(
                code: serverError.code,
                message: "API-key login was rejected by the app-server."
            ))
        case .invalidResponse(let expectedType, _, _):
            .invalidResponse(
                expectedType: expectedType,
                message: "The app-server returned an invalid API-key login response.",
                rawData: nil
            )
        case .deadlineExceeded(let duration):
            .deadlineExceeded(duration)
        case .overloadRetryExhausted(let serverError, let attempts):
            .overloadRetryExhausted(
                last: .init(
                    code: serverError.code,
                    message: "The app-server remained overloaded."
                ),
                attempts: attempts
            )
        }
        return .init(
            requestID: failure.requestID,
            method: failure.method,
            purpose: failure.purpose,
            kind: kind
        )
    }

    private nonisolated static func sanitizedAPIKeyLoginTermination(
        _ termination: CodexConnectionTermination
    ) -> CodexConnectionTermination {
        switch termination {
        case .closedByCaller:
            .closedByCaller
        case .processExited(let status):
            .processExited(status: status)
        case .transportFailure(let failure):
            .transportFailure(sanitizedAPIKeyLoginTransportFailure(failure))
        }
    }

    private nonisolated static func sanitizedAPIKeyLoginTransportFailure(
        _ failure: CodexTransportFailure
    ) -> CodexTransportFailure {
        switch failure {
        case .closed:
            .closed
        case .io(let errno, _):
            .io(errno: errno, message: "The API-key login transport failed.")
        case .framing:
            .framing(message: "The API-key login transport returned an invalid frame.", rawData: nil)
        case .protocolViolation:
            .protocolViolation(
                message: "The API-key login transport violated the app-server protocol.",
                rawData: nil
            )
        case .contractViolation:
            .contractViolation(message: "The API-key login transport contract was violated.")
        }
    }

}
