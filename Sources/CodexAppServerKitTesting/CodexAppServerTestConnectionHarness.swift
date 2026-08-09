import CodexAppServerKit

package struct CodexAppServerTestConnectionHarness: Sendable {
    package let client: AppServerClient
    package let router: CodexAppServerNotificationRouter
    package let turnReplayStore: TurnReplayStore
    package let connection: AppServerConnection
    package let supervisor: ConnectionSupervisor
    package let lease: AppServerConnectionLease

    package static func start(
        transport: any JSONRPC.Transport,
        processTerminationToken: ProcessTerminationToken = .init(),
        clock: CodexAppServerClock = .init(),
        deadlines: CodexAppServer.Configuration.Deadlines = .init(),
        deadlineClock: CodexDeadlineClock = .continuous,
        handler: CodexAppServerRequestHandler? = nil,
        diagnosticHandler: @escaping ServerRequestRegistry.DiagnosticHandler = { _ in }
    ) async -> Self {
        let connectionCloseAction = ConnectionCloseAction()
        let client = AppServerClient(
            transport: transport,
            deadlines: deadlines,
            deadlineClock: deadlineClock,
            connectionCloseAction: connectionCloseAction
        )
        return await start(
            transport: transport,
            processTerminationToken: processTerminationToken,
            clock: clock,
            handler: handler,
            diagnosticHandler: diagnosticHandler,
            client: client,
            connectionCloseAction: connectionCloseAction,
            deadlineClock: deadlineClock
        )
    }

    package static func start(
        transport: any JSONRPC.Transport,
        processTerminationToken: ProcessTerminationToken = .init(),
        clock: CodexAppServerClock = .init(),
        deadlines: CodexAppServer.Configuration.Deadlines = .init(),
        deadlineClock: CodexDeadlineClock = .continuous,
        overloadRetryDelay: @escaping @Sendable (Int) -> Duration?,
        retrySleep: @escaping @Sendable (Duration) async throws -> Void,
        handler: CodexAppServerRequestHandler? = nil,
        diagnosticHandler: @escaping ServerRequestRegistry.DiagnosticHandler = { _ in }
    ) async -> Self {
        let connectionCloseAction = ConnectionCloseAction()
        let client = AppServerClient(
            transport: transport,
            deadlines: deadlines,
            deadlineClock: deadlineClock,
            connectionCloseAction: connectionCloseAction,
            overloadRetryDelay: overloadRetryDelay,
            retrySleep: retrySleep
        )
        return await start(
            transport: transport,
            processTerminationToken: processTerminationToken,
            clock: clock,
            handler: handler,
            diagnosticHandler: diagnosticHandler,
            client: client,
            connectionCloseAction: connectionCloseAction,
            deadlineClock: deadlineClock
        )
    }

    private static func start(
        transport: any JSONRPC.Transport,
        processTerminationToken: ProcessTerminationToken,
        clock: CodexAppServerClock,
        handler: CodexAppServerRequestHandler?,
        diagnosticHandler: @escaping ServerRequestRegistry.DiagnosticHandler,
        client: AppServerClient,
        connectionCloseAction: ConnectionCloseAction,
        deadlineClock: CodexDeadlineClock
    ) async -> Self {
        let turnReplayStore = TurnReplayStore()
        let threadEventHub = ThreadEventHub()
        let router = CodexAppServerNotificationRouter(
            client: client,
            turnReplayStore: turnReplayStore,
            threadEventHub: threadEventHub,
            loginRegistry: LoginRegistry(sleep: deadlineClock.sleep)
        )
        let connection = AppServerConnection(
            transport: transport,
            client: client,
            router: router,
            turnReplayStore: turnReplayStore,
            serverRequestHandler: handler
                ?? CodexAppServer.Configuration.defaultServerRequestHandler(clock: clock),
            serverRequestDiagnosticHandler: diagnosticHandler
        )
        let supervisor = ConnectionSupervisor(connection: connection)
        connectionCloseAction.bind(to: supervisor)
        let lease = AppServerConnectionLease(
            supervisor: supervisor,
            processTerminationToken: processTerminationToken
        )
        await supervisor.start()
        return .init(
            client: client,
            router: router,
            turnReplayStore: turnReplayStore,
            connection: connection,
            supervisor: supervisor,
            lease: lease
        )
    }

    package func close() async {
        await lease.closeConnection()
    }

    package var server: CodexAppServer {
        CodexAppServer(
            client: client,
            router: router,
            connectionLease: lease
        )
    }
}
