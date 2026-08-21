import Darwin
import Foundation
import MCP
import OSLog
import CodexReview
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

private let logger = Logger(subsystem: "CodexReviewKit", category: "mcp-http")

package extension CodexReviewMCPHTTPServer {
    enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case addressInUse(host: String, port: Int)

        package static func classifyStartError(
            _ error: Swift.Error,
            configuration: CodexReviewMCPHTTPServer.Configuration
        ) -> Swift.Error {
            if let ioError = error as? IOError,
               ioError.errnoCode == EADDRINUSE
            {
                return Self.addressInUse(
                    host: configuration.host,
                    port: configuration.port
                )
            }
            return error
        }

        package var errorDescription: String? {
            switch self {
            case .addressInUse(let host, let port):
                "MCP HTTP server address \(host):\(port) is already in use."
            }
        }
    }
}

package extension CodexReviewMCPHTTPServer {
    struct Configuration: Sendable {
        package var host: String
        package var port: Int
        package var endpoint: String
        package var sessionTimeout: TimeInterval
        package var retryInterval: Int?
        package var streamHeartbeatInterval: Duration?
        package var boundedReviewWaitDuration: Duration

        package init(
            host: String = "localhost",
            port: Int = 9417,
            endpoint: String = "/mcp",
            sessionTimeout: TimeInterval = 3600,
            retryInterval: Int? = 1000
        ) {
            self.init(
                host: host,
                port: port,
                endpoint: endpoint,
                sessionTimeout: sessionTimeout,
                retryInterval: retryInterval,
                streamHeartbeatInterval: .seconds(30),
                boundedReviewWaitDuration: .seconds(540)
            )
        }

        package init(
            host: String = "localhost",
            port: Int = 9417,
            endpoint: String = "/mcp",
            sessionTimeout: TimeInterval = 3600,
            retryInterval: Int? = 1000,
            streamHeartbeatInterval: Duration?,
            boundedReviewWaitDuration: Duration = .seconds(540)
        ) {
            self.host = host
            self.port = port
            self.endpoint = endpoint.hasPrefix("/") ? endpoint : "/\(endpoint)"
            self.sessionTimeout = sessionTimeout
            self.retryInterval = retryInterval
            self.streamHeartbeatInterval = streamHeartbeatInterval
            self.boundedReviewWaitDuration = boundedReviewWaitDuration
        }

        package func url(boundPort: Int? = nil) -> URL {
            var components = URLComponents()
            components.scheme = "http"
            components.host = host
            components.port = boundPort ?? port
            components.path = endpoint
            return components.url!
        }
    }
}

private actor MCPHTTPHandlerEntryGate {
    private var shouldHoldNextEntry = false
    private var releaseWasRequested = false
    private var continuation: CheckedContinuation<Void, Never>?

    func holdNextEntry() {
        precondition(
            shouldHoldNextEntry == false && continuation == nil,
            "MCPHTTPHandlerEntryGate owns at most one held test entry."
        )
        shouldHoldNextEntry = true
        releaseWasRequested = false
    }

    func waitIfNeeded() async {
        guard shouldHoldNextEntry else {
            return
        }
        if releaseWasRequested {
            shouldHoldNextEntry = false
            releaseWasRequested = false
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        shouldHoldNextEntry = false
        releaseWasRequested = false
    }

    func release() {
        guard shouldHoldNextEntry else {
            return
        }
        if let continuation {
            self.continuation = nil
            continuation.resume()
        } else {
            releaseWasRequested = true
        }
    }
}

private final class MCPHTTPStartCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldHoldNextCompletion = false
    private var isHoldingCompletion = false
    private var releaseWasRequested = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []
    private var admissionClosed = false
    private var admissionCloseWaiters: [CheckedContinuation<Void, Never>] = []

    func holdNextCompletion() {
        lock.lock()
        precondition(
            shouldHoldNextCompletion == false && continuation == nil,
            "MCPHTTPStartCompletionGate owns at most one held start."
        )
        shouldHoldNextCompletion = true
        isHoldingCompletion = false
        releaseWasRequested = false
        admissionClosed = false
        lock.unlock()
    }

    func waitIfNeeded() async {
        await withCheckedContinuation { continuation in
            let waiters: [CheckedContinuation<Void, Never>]
            lock.lock()
            guard shouldHoldNextCompletion else {
                lock.unlock()
                continuation.resume()
                return
            }
            isHoldingCompletion = true
            waiters = holdWaiters
            holdWaiters.removeAll(keepingCapacity: false)
            if releaseWasRequested {
                resetLocked()
                lock.unlock()
                for waiter in waiters {
                    waiter.resume()
                }
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilHolding() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isHoldingCompletion {
                lock.unlock()
                continuation.resume()
            } else {
                holdWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        let continuation: CheckedContinuation<Void, Never>?
        lock.lock()
        guard shouldHoldNextCompletion else {
            lock.unlock()
            return
        }
        if let held = self.continuation {
            self.continuation = nil
            continuation = held
            resetLocked()
        } else {
            releaseWasRequested = true
            continuation = nil
        }
        lock.unlock()
        continuation?.resume()
    }

    func recordAdmissionClosed() {
        let waiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        admissionClosed = true
        waiters = admissionCloseWaiters
        admissionCloseWaiters.removeAll(keepingCapacity: false)
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilAdmissionClosed() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if admissionClosed {
                lock.unlock()
                continuation.resume()
            } else {
                admissionCloseWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func resetLocked() {
        shouldHoldNextCompletion = false
        isHoldingCompletion = false
        releaseWasRequested = false
    }
}


package actor CodexReviewMCPHTTPServer {
    private struct StartingGenerationFailure: Swift.Error, Sendable {
        let primary: any Swift.Error
        let cleanupFailures: [ReviewLifecycleResourceFailure]
    }

    private typealias StartingGenerationResult = Result<
        RunningGeneration,
        StartingGenerationFailure
    >

    private final class StartingGeneration {
        let id: UInt64
        let networkResources: MCPHTTPNetworkResourceOwner
        let task: Task<StartingGenerationResult, Never>
        var admissionClosed = false

        init(
            id: UInt64,
            networkResources: MCPHTTPNetworkResourceOwner,
            task: Task<StartingGenerationResult, Never>
        ) {
            self.id = id
            self.networkResources = networkResources
            self.task = task
        }
    }

    private final class RunningGeneration: @unchecked Sendable {
        let id: UInt64
        let listener: any Channel
        let eventLoopGroup: MultiThreadedEventLoopGroup
        let cleanupTask: Task<Void, Never>
        let boundURL: URL
        let networkResources: MCPHTTPNetworkResourceOwner
        var listenerCloseTask: Task<Result<Void, ReviewLifecycleResourceFailure>, Never>?

        init(
            id: UInt64,
            listener: any Channel,
            eventLoopGroup: MultiThreadedEventLoopGroup,
            cleanupTask: Task<Void, Never>,
            boundURL: URL,
            networkResources: MCPHTTPNetworkResourceOwner
        ) {
            self.id = id
            self.listener = listener
            self.eventLoopGroup = eventLoopGroup
            self.cleanupTask = cleanupTask
            self.boundURL = boundURL
            self.networkResources = networkResources
        }
    }

    private enum LifecycleState {
        case stopped([ReviewLifecycleResourceFailure])
        case starting(StartingGeneration)
        case running(RunningGeneration)
        case stopping(
            id: UInt64,
            resources: RunningGeneration?,
            task: Task<[ReviewLifecycleResourceFailure], Never>
        )
    }

    private final class SessionContext: @unchecked Sendable {
        let ordinal: UInt64
        var server: Server?
        let transport: StatefulHTTPServerTransport
        let foreignLifetimeWaiter: MCPProtocolServerForeignLifetimeWaiter
        let createdAt: Date
        var lastAccessedAt: Date
        var semanticCloseTask: Task<Void, Never>?

        init(
            ordinal: UInt64,
            server: Server,
            transport: StatefulHTTPServerTransport,
            foreignLifetimeWaiter: MCPProtocolServerForeignLifetimeWaiter,
            createdAt: Date,
            lastAccessedAt: Date
        ) {
            self.ordinal = ordinal
            self.server = server
            self.transport = transport
            self.foreignLifetimeWaiter = foreignLifetimeWaiter
            self.createdAt = createdAt
            self.lastAccessedAt = lastAccessedAt
            self.semanticCloseTask = nil
        }
    }

    private struct FixedSessionIDGenerator: SessionIDGenerator {
        let sessionID: String

        func generateSessionID() -> String {
            sessionID
        }
    }

    private let adapter: CodexReviewMCPServer
    private let configuration: CodexReviewMCPHTTPServer.Configuration
    private var lifecycleState = LifecycleState.stopped([])
    private var nextGenerationID: UInt64 = 0
    private var sessions: [String: SessionContext] = [:]
    private var nextSessionOrdinal: UInt64 = 0
    private var pendingCloseFailures: [ReviewLifecycleResourceFailure] = []
    private let handlerEntryGate = MCPHTTPHandlerEntryGate()
    private let startCompletionGate = MCPHTTPStartCompletionGate()
    private var admittedHandlerDrainDidBegin = false
    private var admittedHandlerDrainStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var eventLoopGroupShutdownCount = 0
    private var eventLoopGroupShutdownWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var nextStartListenerCleanupFailureForTesting: ReviewLifecycleResourceFailure?
    private var nextStartEventLoopGroupCleanupFailureForTesting: ReviewLifecycleResourceFailure?

    package init(
        adapter: CodexReviewMCPServer,
        configuration: CodexReviewMCPHTTPServer.Configuration = .init()
    ) {
        self.adapter = adapter
        self.configuration = configuration
    }

    package var url: URL {
        switch lifecycleState {
        case .running(let resources),
             .stopping(_, let resources?, _):
            resources.boundURL
        case .stopped, .starting, .stopping:
            configuration.url()
        }
    }

    package var endpoint: String {
        configuration.endpoint
    }

    package static func checkBind(
        configuration: CodexReviewMCPHTTPServer.Configuration
    ) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 1)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.close(mode: .all)
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)

        do {
            try Task.checkCancellation()
            let channel = try await bootstrap.bind(
                host: configuration.host,
                port: configuration.port
            ).get()
            try? await channel.close()
            try? await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw CodexReviewMCPHTTPServer.Error.classifyStartError(
                error,
                configuration: configuration
            )
        }
    }

    package func start() async throws {
        while true {
            switch lifecycleState {
            case .stopped(let failures):
                try throwLifecycleFailures(failures)
                nextGenerationID &+= 1
                let id = nextGenerationID
                let networkResources = MCPHTTPNetworkResourceOwner()
                let task = Task<StartingGenerationResult, Never> { [self] in
                    await performStartGeneration(
                        id: id,
                        networkResources: networkResources
                    )
                }
                let operation = StartingGeneration(
                    id: id,
                    networkResources: networkResources,
                    task: task
                )
                lifecycleState = .starting(operation)
                let result = await task.value
                try await publishStartResult(result, operation: operation)
                return

            case .starting(let operation):
                let result = await operation.task.value
                try await publishStartResult(result, operation: operation)
                return

            case .running:
                return

            case .stopping(let id, _, let task):
                let failures = await task.value
                finishStopIfCurrent(id: id, failures: failures)
                try throwLifecycleFailures(failures)
            }
        }
    }

    private func performStartGeneration(
        id: UInt64,
        networkResources: MCPHTTPNetworkResourceOwner
    ) async -> StartingGenerationResult {
        let handlerEntryGate = handlerEntryGate
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                guard let connection = networkResources.admitConnection(channel) else {
                    return channel.close(mode: .all)
                }
                return channel.pipeline.configureHTTPServerPipeline(
                    withPipeliningAssistance: false
                ).flatMap {
                    channel.pipeline.addHandler(CodexReviewMCPHTTPHandler(
                        server: self,
                        entryGate: handlerEntryGate,
                        networkResources: networkResources,
                        connection: connection
                    ))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)

        var listener: (any Channel)?
        do {
            try Task.checkCancellation()
            let channel = try await bootstrap.bind(
                host: configuration.host,
                port: configuration.port
            ).get()
            listener = channel
            await startCompletionGate.waitIfNeeded()
            try Task.checkCancellation()
            let actualPort = channel.localAddress?.port
            let cleanupTask = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.sessionCleanupLoop()
            }
            return .success(RunningGeneration(
                id: id,
                listener: channel,
                eventLoopGroup: group,
                cleanupTask: cleanupTask,
                boundURL: configuration.url(boundPort: actualPort),
                networkResources: networkResources
            ))
        } catch {
            networkResources.closeAdmission()
            var cleanupFailures: [ReviewLifecycleResourceFailure] = []
            if let listener {
                do {
                    try await listener.close()
                } catch {
                    cleanupFailures.append(.mcpServer(error.localizedDescription))
                }
                if let injected = nextStartListenerCleanupFailureForTesting {
                    nextStartListenerCleanupFailureForTesting = nil
                    cleanupFailures.append(injected)
                }
            }
            let closingGeneration = networkResources.beginClosing(.serverStop)
            await closingGeneration.waitUntilClosed()
            do {
                try await group.shutdownGracefully()
            } catch {
                cleanupFailures.append(.mcpServer(error.localizedDescription))
            }
            if let injected = nextStartEventLoopGroupCleanupFailureForTesting {
                nextStartEventLoopGroupCleanupFailureForTesting = nil
                cleanupFailures.append(injected)
            }
            return .failure(.init(
                primary: CodexReviewMCPHTTPServer.Error.classifyStartError(
                    error,
                    configuration: configuration
                ),
                cleanupFailures: cleanupFailures
            ))
        }
    }

    private func publishStartResult(
        _ result: StartingGenerationResult,
        operation: StartingGeneration
    ) async throws {
        switch result {
        case .success(let resources):
            if operation.admissionClosed {
                if case .starting(let current) = lifecycleState,
                   current === operation {
                    lifecycleState = .running(resources)
                }
                if let failure = await closeListener(resources) {
                    recordPendingListenerCloseFailureIfRunning(
                        failure,
                        resources: resources
                    )
                }
                throw CancellationError()
            }
            if case .running(let current) = lifecycleState,
               current === resources {
                return
            }
            guard case .starting(let current) = lifecycleState,
                  current === operation else {
                throw CancellationError()
            }
            pendingCloseFailures.removeAll(keepingCapacity: false)
            admittedHandlerDrainDidBegin = false
            lifecycleState = .running(resources)
            logger.info(
                "MCP Streamable HTTP server listening at \(resources.boundURL.absoluteString, privacy: .public)"
            )
        case .failure(let failure):
            if case .starting(let current) = lifecycleState,
               current === operation {
                lifecycleState = .stopped(failure.cleanupFailures)
            }
            throw failure.primary
        }
    }

    package func stop() async throws {
        let id: UInt64
        let task: Task<[ReviewLifecycleResourceFailure], Never>
        switch lifecycleState {
        case .stopped(let failures):
            try throwLifecycleFailures(failures)
            return
        case .stopping(let currentID, _, let currentTask):
            id = currentID
            task = currentTask
        case .running(let resources):
            id = resources.id
            resources.networkResources.closeAdmission()
            let newTask = Task<[ReviewLifecycleResourceFailure], Never> { [self] in
                await performStopGeneration(resources)
            }
            lifecycleState = .stopping(
                id: id,
                resources: resources,
                task: newTask
            )
            task = newTask
        case .starting(let operation):
            closeStartingAdmission(operation)
            id = operation.id
            let newTask = Task<[ReviewLifecycleResourceFailure], Never> { [self] in
                switch await operation.task.value {
                case .success(let resources):
                    return await performStopGeneration(resources)
                case .failure(let failure):
                    return failure.cleanupFailures
                }
            }
            lifecycleState = .stopping(id: id, resources: nil, task: newTask)
            task = newTask
        }

        let failures = await task.value
        finishStopIfCurrent(id: id, failures: failures)
        try throwLifecycleFailures(failures)
    }

    private func closeStartingAdmission(_ operation: StartingGeneration) {
        if operation.admissionClosed == false {
            operation.admissionClosed = true
            operation.networkResources.closeAdmission()
            startCompletionGate.recordAdmissionClosed()
        }
        operation.task.cancel()
    }

    private func performStopGeneration(
        _ resources: RunningGeneration
    ) async -> [ReviewLifecycleResourceFailure] {
        resources.networkResources.closeAdmission()
        var failures = pendingCloseFailures
        pendingCloseFailures.removeAll(keepingCapacity: false)
        let listenerCloseTask = listenerCloseTask(resources)
        resources.cleanupTask.cancel()

        let closingSessions = sessions
            .map { (id: $0.key, context: $0.value) }
            .sorted { $0.context.ordinal < $1.context.ordinal }
        sessions.removeAll(keepingCapacity: false)
        let disconnectTasks = closingSessions.map { session in
            Task<Void, Never> {
                await session.context.transport.disconnect()
            }
        }
        for task in disconnectTasks {
            await task.value
        }
        let closingGeneration = resources.networkResources.beginClosing(.serverStop)

        switch await listenerCloseTask.value {
        case .success:
            break
        case .failure(let failure):
            if failures.contains(failure) == false {
                failures.append(failure)
            }
        }
        await resources.cleanupTask.value
        await closingGeneration.waitUntilClosed()
        for session in closingSessions {
            await session.context.semanticCloseTask?.value
        }
        await stopProtocolServersAndReleaseForeignLifetimes(closingSessions)
        for session in closingSessions {
            await adapter.closeSession(session.id)
        }
        precondition(
            resources.networkResources.snapshot().isQuiescent,
            "The MCP network generation owner must be quiescent before EventLoopGroup shutdown."
        )
        eventLoopGroupShutdownCount += 1
        let shutdownWaiters = eventLoopGroupShutdownWaiters.filter {
            eventLoopGroupShutdownCount >= $0.count
        }
        eventLoopGroupShutdownWaiters.removeAll {
            eventLoopGroupShutdownCount >= $0.count
        }
        for waiter in shutdownWaiters {
            waiter.continuation.resume()
        }
        do {
            try await resources.eventLoopGroup.shutdownGracefully()
        } catch {
            failures.append(.mcpServer(error.localizedDescription))
        }
        logger.info("MCP Streamable HTTP server stopped")
        return failures
    }

    private func stopProtocolServersAndReleaseForeignLifetimes(
        _ sessions: [(id: String, context: SessionContext)]
    ) async {
        for session in sessions {
            var server = session.context.server
            if let current = server {
                await current.waitUntilCompleted()
                await current.stop()
            }
            session.context.server = nil
            server = nil
        }
        for session in sessions {
            await session.context.foreignLifetimeWaiter.wait()
        }
    }

    private func finishStopIfCurrent(
        id: UInt64,
        failures: [ReviewLifecycleResourceFailure]
    ) {
        guard case .stopping(let currentID, _, _) = lifecycleState,
              currentID == id else {
            return
        }
        lifecycleState = .stopped(failures)
    }

    private func throwLifecycleFailures(
        _ failures: [ReviewLifecycleResourceFailure]
    ) throws {
        guard let first = failures.first else {
            return
        }
        throw ReviewLifecycleResourceFailureAggregate(
            first: first,
            additionalInLifecycleOrder: Array(failures.dropFirst())
        )
    }

    package func closeAdmission() async {
        var resources: RunningGeneration?
        var startingOperation: StartingGeneration?
        switch lifecycleState {
        case .running(let running):
            running.networkResources.closeAdmission()
            resources = running
        case .stopping(_, let stopping, _):
            stopping?.networkResources.closeAdmission()
            resources = stopping
        case .starting(let operation):
            closeStartingAdmission(operation)
            startingOperation = operation
            resources = nil
        case .stopped:
            resources = nil
        }
        if let startingOperation {
            switch await startingOperation.task.value {
            case .success(let prepared):
                if case .starting(let current) = lifecycleState,
                   current === startingOperation {
                    lifecycleState = .running(prepared)
                }
                resources = prepared
            case .failure(let failure):
                if case .starting(let current) = lifecycleState,
                   current === startingOperation {
                    lifecycleState = .stopped(failure.cleanupFailures)
                }
                return
            }
        }
        guard let resources else {
            return
        }
        if let failure = await closeListener(resources) {
            recordPendingListenerCloseFailureIfRunning(
                failure,
                resources: resources
            )
        }
    }

    private func closeListener(
        _ resources: RunningGeneration
    ) async -> ReviewLifecycleResourceFailure? {
        let task = listenerCloseTask(resources)
        switch await task.value {
        case .success:
            return nil
        case .failure(let failure):
            return failure
        }
    }

    private func listenerCloseTask(
        _ resources: RunningGeneration
    ) -> Task<Result<Void, ReviewLifecycleResourceFailure>, Never> {
        if let existing = resources.listenerCloseTask {
            return existing
        }
        let listener = resources.listener
        let newTask = Task<Result<Void, ReviewLifecycleResourceFailure>, Never> {
            do {
                try await listener.close()
                return .success(())
            } catch {
                return .failure(.mcpServer(error.localizedDescription))
            }
        }
        resources.listenerCloseTask = newTask
        return newTask
    }

    private func recordPendingListenerCloseFailureIfRunning(
        _ failure: ReviewLifecycleResourceFailure,
        resources: RunningGeneration
    ) {
        guard case .running(let current) = lifecycleState,
              current === resources else {
            return
        }
        if pendingCloseFailures.contains(failure) == false {
            pendingCloseFailures.append(failure)
        }
    }

    package func waitForAdmittedHandlers() async {
        admittedHandlerDrainDidBegin = true
        let startWaiters = admittedHandlerDrainStartWaiters
        admittedHandlerDrainStartWaiters.removeAll(keepingCapacity: false)
        for waiter in startWaiters {
            waiter.resume()
        }
        let networkResources: MCPHTTPNetworkResourceOwner?
        switch lifecycleState {
        case .starting(let operation):
            networkResources = operation.networkResources
        case .running(let resources), .stopping(_, let resources?, _):
            networkResources = resources.networkResources
        case .stopped, .stopping:
            networkResources = nil
        }
        await networkResources?.waitForAdmittedHandlingWorkToDrain()
    }

    fileprivate func handleAdmittedHTTPRequest(
        _ request: HTTPRequest,
        operation: MCPHTTPNetworkResourceOwner.RequestOperation,
        networkResources: MCPHTTPNetworkResourceOwner
    ) async -> HTTPResponse {
        await performHTTPRequest(
            request,
            operation: operation,
            networkResources: networkResources
        )
    }

    private func performHTTPRequest(
        _ request: HTTPRequest,
        operation: MCPHTTPNetworkResourceOwner.RequestOperation,
        networkResources: MCPHTTPNetworkResourceOwner
    ) async -> HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        if let sessionID, let session = sessions[sessionID] {
            guard isCurrentGeneration(networkResources) else {
                operation.beginClosing(.serverStop)
                return .error(
                    statusCode: 503,
                    .internalError("MCP server is stopping.")
                )
            }
            operation.bindSession(sessionID)
            session.lastAccessedAt = Date()
            let response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE", response.statusCode == 200 {
                scheduleSessionClose(
                    sessionID,
                    after: operation,
                    expected: session
                )
            }
            return response
        }

        if request.method.uppercased() == "POST",
           let body = request.body,
           Self.isInitializeRequest(body)
        {
            return await createSessionAndHandle(
                request,
                operation: operation,
                networkResources: networkResources
            )
        }

        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired"))
        }
        return .error(
            statusCode: 400,
            .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header")
        )
    }

    private func createSessionAndHandle(
        _ request: HTTPRequest,
        operation: MCPHTTPNetworkResourceOwner.RequestOperation,
        networkResources: MCPHTTPNetworkResourceOwner
    ) async -> HTTPResponse {
        let sessionID = UUID().uuidString
        let clientSession = MCPClientSessionState()
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            validationPipeline: makeValidationPipeline(),
            retryInterval: configuration.retryInterval
        )
        let foreignLifetimeWaiter: MCPProtocolServerForeignLifetimeWaiter
        var foreignLifetimeLease: MCPProtocolServerForeignLifetimeWaiter.Lease?
        do {
            let pair = MCPProtocolServerForeignLifetimeWaiter.makePair()
            foreignLifetimeWaiter = pair.waiter
            foreignLifetimeLease = pair.lease
        }
        var protocolServer: Server?

        do {
            let server = await makeMCPProtocolServer(
                adapter: adapter,
                defaultSessionID: sessionID,
                clientSession: clientSession,
                boundedReviewWaitDuration: configuration.boundedReviewWaitDuration,
                networkResources: networkResources,
                foreignLifetimeLease: foreignLifetimeLease!
            )
            foreignLifetimeLease = nil
            protocolServer = server
            guard isCurrentGeneration(networkResources) else {
                throw CancellationError()
            }
            try await server.start(transport: transport) { clientInfo, _ in
                await clientSession.update(clientInfo: clientInfo)
            }
            guard isCurrentGeneration(networkResources) else {
                throw CancellationError()
            }
            operation.bindSession(sessionID)
            nextSessionOrdinal &+= 1
            sessions[sessionID] = SessionContext(
                ordinal: nextSessionOrdinal,
                server: server,
                transport: transport,
                foreignLifetimeWaiter: foreignLifetimeWaiter,
                createdAt: Date(),
                lastAccessedAt: Date()
            )

            let response = await transport.handleRequest(request)
            guard isCurrentGeneration(networkResources) else {
                if let session = sessions.removeValue(forKey: sessionID) {
                    await physicallyCloseSession(session)
                }
                operation.beginClosing(.serverStop)
                return .error(statusCode: 503, .internalError("MCP server is stopping."))
            }
            if case .error = response {
                sessions.removeValue(forKey: sessionID)
                await physicallyCloseSessionContext(
                    server: &protocolServer,
                    transport: transport,
                    foreignLifetimeWaiter: foreignLifetimeWaiter
                )
            }
            return response
        } catch {
            foreignLifetimeLease = nil
            await physicallyCloseSessionContext(
                server: &protocolServer,
                transport: transport,
                foreignLifetimeWaiter: foreignLifetimeWaiter
            )
            if error is CancellationError {
                operation.beginClosing(.serverStop)
                return .error(statusCode: 503, .internalError("MCP server is stopping."))
            }
            return .error(
                statusCode: 500,
                .internalError("Failed to create MCP session: \(error.localizedDescription)")
            )
        }
    }

    private func closeSession(_ sessionID: String) async {
        guard let session = sessions.removeValue(forKey: sessionID) else {
            return
        }
        let matchingOperations = currentNetworkResources()?.snapshot().connections
            .flatMap(\.operations)
            .filter { $0.boundSessionID == sessionID } ?? []
        await session.transport.disconnect()
        for snapshot in matchingOperations {
            currentNetworkResources()?.resolve(snapshot.token)?.beginClosing(.sessionClosed)
        }
        for snapshot in matchingOperations {
            _ = await currentNetworkResources()?.resolve(snapshot.token)?.waitUntilClosed()
        }
        await physicallyCloseSession(session)
        await adapter.closeSession(sessionID)
        logger.info("Closed MCP HTTP session \(sessionID, privacy: .public)")
    }

    private func scheduleSessionClose(
        _ sessionID: String,
        after operation: MCPHTTPNetworkResourceOwner.RequestOperation,
        expected session: SessionContext
    ) {
        guard session.semanticCloseTask == nil else { return }
        let sessionOrdinal = session.ordinal
        let task = Task { [weak self] in
            _ = await operation.waitUntilClosed()
            await self?.completeScheduledSessionClose(
                sessionID,
                expectedOrdinal: sessionOrdinal
            )
        }
        session.semanticCloseTask = task
    }

    private func completeScheduledSessionClose(
        _ sessionID: String,
        expectedOrdinal: UInt64
    ) async {
        guard sessions[sessionID]?.ordinal == expectedOrdinal else { return }
        await closeSession(sessionID)
    }

    fileprivate func requestOperationDidFinish(sessionID: String?) {
        if let sessionID, let session = sessions[sessionID] {
            session.lastAccessedAt = Date()
        }
    }

    fileprivate var responseHeartbeatInterval: Duration? {
        configuration.streamHeartbeatInterval
    }

    private func physicallyCloseSession(_ session: SessionContext) async {
        var server = session.server
        session.server = nil
        await physicallyCloseSessionContext(
            server: &server,
            transport: session.transport,
            foreignLifetimeWaiter: session.foreignLifetimeWaiter
        )
    }

    private func physicallyCloseSessionContext(
        server: inout Server?,
        transport: StatefulHTTPServerTransport,
        foreignLifetimeWaiter: MCPProtocolServerForeignLifetimeWaiter
    ) async {
        await transport.disconnect()
        if let current = server {
            await current.waitUntilCompleted()
            await current.stop()
        }
        server = nil
        await foreignLifetimeWaiter.wait()
    }

    private func isCurrentGeneration(
        _ networkResources: MCPHTTPNetworkResourceOwner
    ) -> Bool {
        guard case .running(let resources) = lifecycleState else { return false }
        return resources.networkResources === networkResources
    }

    private func currentNetworkResources() -> MCPHTTPNetworkResourceOwner? {
        switch lifecycleState {
        case .starting(let operation): operation.networkResources
        case .running(let resources), .stopping(_, let resources?, _): resources.networkResources
        case .stopped, .stopping: nil
        }
    }

    private func sessionCleanupLoop() async {
        while Task.isCancelled == false {
            try? await Task.sleep(for: .seconds(60))
            guard Task.isCancelled == false else {
                return
            }
            await closeExpiredSessions(now: Date())
        }
    }

    package func runSessionCleanupForTesting(now: Date) async {
        await closeExpiredSessions(now: now)
    }

    package func sessionActiveRequestCountForTesting(sessionID: String) -> Int? {
        guard sessions[sessionID] != nil else { return nil }
        return currentNetworkResources()?.liveOperationCount(boundTo: sessionID) ?? 0
    }

    package func listenerIsOpenForTesting() -> Bool {
        switch lifecycleState {
        case .running(let resources),
             .stopping(_, let resources?, _):
            resources.listenerCloseTask == nil && resources.listener.isActive
        case .stopped, .starting, .stopping:
            false
        }
    }

    package func holdNextNetworkHandlerEntryForTesting() async {
        await handlerEntryGate.holdNextEntry()
    }

    package func releaseNetworkHandlerEntryForTesting() async {
        await handlerEntryGate.release()
    }

    package func holdNextStartCompletionForTesting() async {
        startCompletionGate.holdNextCompletion()
    }

    package func waitForHeldStartCompletionForTesting() async {
        await startCompletionGate.waitUntilHolding()
    }

    package func releaseHeldStartCompletionForTesting() async {
        startCompletionGate.release()
    }

    package func waitForHeldStartAdmissionCloseForTesting() async {
        await startCompletionGate.waitUntilAdmissionClosed()
    }

    package func failNextStartCleanupForTesting(
        listener message: String,
        eventLoopGroup groupMessage: String
    ) {
        nextStartListenerCleanupFailureForTesting = .mcpServer(message)
        nextStartEventLoopGroupCleanupFailureForTesting = .mcpServer(groupMessage)
    }

    package func waitForAdmittedHandlerDrainToBeginForTesting() async {
        if admittedHandlerDrainDidBegin {
            return
        }
        await withCheckedContinuation { continuation in
            if admittedHandlerDrainDidBegin {
                continuation.resume()
            } else {
                admittedHandlerDrainStartWaiters.append(continuation)
            }
        }
    }

    func networkSnapshotForTesting() -> MCPHTTPNetworkResourceOwner.Snapshot {
        currentNetworkResources()?.snapshot()
            ?? .init(revision: 0, phase: .closed, connections: [])
    }

    func nextNetworkSnapshotForTesting(
        after revision: UInt64
    ) async -> MCPHTTPNetworkResourceOwner.Snapshot {
        guard let resources = currentNetworkResources() else {
            return .init(revision: revision &+ 1, phase: .closed, connections: [])
        }
        return await resources.nextSnapshot(after: revision)
    }

    package func eventLoopGroupShutdownCountForTesting() -> Int {
        eventLoopGroupShutdownCount
    }

    package func waitForEventLoopGroupShutdownCountForTesting(
        _ count: Int
    ) async {
        if eventLoopGroupShutdownCount >= count {
            return
        }
        await withCheckedContinuation { continuation in
            if eventLoopGroupShutdownCount >= count {
                continuation.resume()
            } else {
                eventLoopGroupShutdownWaiters.append((count, continuation))
            }
        }
    }

    private func closeExpiredSessions(now: Date) async {
        var expiredSessionIDs: [String] = []
        for (sessionID, context) in sessions {
            guard now.timeIntervalSince(context.lastAccessedAt) > configuration.sessionTimeout else {
                continue
            }
            if currentNetworkResources()?.liveOperationCount(boundTo: sessionID) ?? 0 > 0 {
                continue
            }
            if await adapter.hasActiveReviews(in: sessionID) {
                if let session = sessions[sessionID] {
                    session.lastAccessedAt = Date()
                }
                continue
            }
            if let current = sessions[sessionID],
               currentNetworkResources()?.liveOperationCount(boundTo: sessionID) ?? 0 == 0,
               now.timeIntervalSince(current.lastAccessedAt) > configuration.sessionTimeout
            {
                expiredSessionIDs.append(sessionID)
            }
        }
        for sessionID in expiredSessionIDs {
            await closeSession(sessionID)
        }
    }

    private static func isInitializeRequest(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["method"] as? String == "initialize" && json["id"] != nil
    }

    private func makeValidationPipeline() -> any HTTPRequestValidationPipeline {
        let resolvedPort = url.port ?? configuration.port
        let portPattern = resolvedPort > 0 ? String(resolvedPort) : "*"
        let allowedHosts = Self.allowedHostPatterns(
            host: configuration.host,
            portPattern: portPattern
        )

        return StandardValidationPipeline(validators: [
            OriginValidator(
                allowedHosts: allowedHosts,
                allowedOrigins: allowedHosts.map { "http://\($0)" }
            ),
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            SessionValidator(),
        ])
    }

    private static func allowedHostPatterns(host: String, portPattern: String) -> [String] {
        var hosts: [String] = []

        func append(_ host: String) {
            let normalized = normalizedHostForValidation(host)
            guard normalized.isEmpty == false else {
                return
            }
            let pattern = "\(normalized):\(portPattern)"
            if hosts.contains(pattern) == false {
                hosts.append(pattern)
            }
        }

        append(host)
        if acceptsLoopbackAliases(host) {
            append("127.0.0.1")
            append("localhost")
            append("[::1]")
        }
        return hosts
    }

    private static func normalizedHostForValidation(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return ""
        }
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            return trimmed
        }
        if trimmed.contains(":") {
            return "[\(trimmed)]"
        }
        return trimmed
    }

    private static func acceptsLoopbackAliases(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let unbracketed: String
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            unbracketed = String(trimmed.dropFirst().dropLast())
        } else {
            unbracketed = trimmed
        }
        return ["127.0.0.1", "localhost", "::1", "0.0.0.0", "::"].contains(unbracketed)
    }
}

private final class CodexReviewMCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private struct ResponsePartWriter: @unchecked Sendable {
        let handler: CodexReviewMCPHTTPHandler
        let context: ChannelHandlerContext

        func writeAndFlush(
            _ part: HTTPServerResponsePart,
            promise: EventLoopPromise<Void>
        ) {
            context.writeAndFlush(handler.wrapOutboundOut(part), promise: promise)
        }

        func writeBody(
            _ data: Data,
            promise: EventLoopPromise<Void>
        ) {
            var buffer = context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            context.writeAndFlush(handler.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
        }
    }

    private struct RequestState {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }

    private enum WriterEvent: Sendable {
        case body(Data)
        case heartbeat
        case sourceFinished
        case sourceFailed(String)
    }

    private let server: CodexReviewMCPHTTPServer
    private let entryGate: MCPHTTPHandlerEntryGate
    private let networkResources: MCPHTTPNetworkResourceOwner
    private let connection: MCPHTTPNetworkResourceOwner.Connection
    private var requestState: RequestState?

    init(
        server: CodexReviewMCPHTTPServer,
        entryGate: MCPHTTPHandlerEntryGate,
        networkResources: MCPHTTPNetworkResourceOwner,
        connection: MCPHTTPNetworkResourceOwner.Connection
    ) {
        self.server = server
        self.entryGate = entryGate
        self.networkResources = networkResources
        self.connection = connection
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestState = RequestState(
                head: head,
                bodyBuffer: context.channel.allocator.buffer(capacity: 0)
            )
        case .body(var buffer):
            requestState?.bodyBuffer.writeBuffer(&buffer)
        case .end:
            guard let state = requestState else {
                return
            }
            requestState = nil
            let metadata = makeRequestMetadata(from: state)
            guard let operation = connection.admitRequest(metadata: metadata),
                  let httpReservation = operation.beginHTTPHandling()
            else {
                writeAdmissionClosedResponse(
                    version: state.head.version,
                    context: context
                )
                return
            }
            nonisolated(unsafe) let context = context
            let task = Task {
                defer { httpReservation.acknowledge() }
                await entryGate.waitIfNeeded()
                guard Task.isCancelled == false else {
                    return
                }
                await handleRequest(
                    state: state,
                    operation: operation,
                    context: context
                )
            }
            httpReservation.install(task)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
        context.read()
    }

    func channelInactive(context: ChannelHandlerContext) {
        connection.beginClosing(.peerClosed)
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            connection.beginClosing(.peerClosed)
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        connection.beginClosing(.transportFailure(error.localizedDescription))
        context.close(promise: nil)
    }

    private func handleRequest(
        state: RequestState,
        operation: MCPHTTPNetworkResourceOwner.RequestOperation,
        context: ChannelHandlerContext
    ) async {
        let head = state.head
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        let endpoint = await server.endpoint
        let response: HTTPResponse
        guard path == endpoint else {
            response = .error(statusCode: 404, .invalidRequest("Not Found"))
            await prepareAndQueueResponse(
                response,
                operation: operation,
                version: head.version,
                context: context
            )
            return
        }

        let request = makeHTTPRequest(from: state, token: operation.token)
        response = await server.handleAdmittedHTTPRequest(
            request,
            operation: operation,
            networkResources: networkResources
        )
        await prepareAndQueueResponse(
            response,
            operation: operation,
            version: head.version,
            context: context
        )
    }

    private func writeAdmissionClosedResponse(
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) {
        let response = HTTPResponse.error(
            statusCode: 503,
            .internalError("MCP server is not accepting requests.")
        )
        var head = HTTPResponseHead(
            version: version,
            status: .serviceUnavailable
        )
        for (name, value) in response.headers {
            head.headers.add(name: name, value: value)
        }
        let body = response.bodyData
        if let body {
            head.headers.add(name: "Content-Length", value: "\(body.count)")
        }
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if let body {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(
                wrapOutboundOut(.body(.byteBuffer(buffer))),
                promise: nil
            )
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func makeHTTPRequest(
        from state: RequestState,
        token: MCPHTTPNetworkResourceOwner.OperationToken
    ) -> HTTPRequest {
        var headers: [String: String] = [:]
        for (name, value) in state.head.headers {
            guard name.caseInsensitiveCompare(
                MCPHTTPNetworkResourceOwner.operationTokenHeaderName
            ) != .orderedSame else {
                continue
            }
            if let existing = headers[name] {
                headers[name] = "\(existing), \(value)"
            } else {
                headers[name] = value
            }
        }

        let body: Data?
        if state.bodyBuffer.readableBytes > 0,
           let bytes = state.bodyBuffer.getBytes(at: 0, length: state.bodyBuffer.readableBytes)
        {
            body = Data(bytes)
        } else {
            body = nil
        }
        headers[MCPHTTPNetworkResourceOwner.operationTokenHeaderName] = token.headerValue

        let path = String(state.head.uri.split(separator: "?").first ?? Substring(state.head.uri))
        return HTTPRequest(
            method: state.head.method.rawValue,
            headers: headers,
            body: body,
            path: path
        )
    }

    private func makeRequestMetadata(
        from state: RequestState
    ) -> MCPHTTPNetworkResourceOwner.RequestMetadata {
        let path = String(state.head.uri.split(separator: "?").first ?? Substring(state.head.uri))
        let jsonRPCID: String?
        if state.bodyBuffer.readableBytes > 0,
           let bytes = state.bodyBuffer.getBytes(at: 0, length: state.bodyBuffer.readableBytes),
           let object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
           let id = object["id"]
        {
            if let string = id as? String {
                jsonRPCID = string
            } else if let number = id as? NSNumber {
                jsonRPCID = number.stringValue
            } else {
                jsonRPCID = nil
            }
        } else {
            jsonRPCID = nil
        }
        return .init(
            method: state.head.method.rawValue,
            path: path,
            jsonRPCID: jsonRPCID
        )
    }

    private func prepareAndQueueResponse(
        _ response: HTTPResponse,
        operation: MCPHTTPNetworkResourceOwner.RequestOperation,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) async {
        guard operation.beginResponding() else { return }
        let preparedResponse: HTTPResponse
        switch response {
        case .stream(let source, let headers):
            guard let sourceReservation = operation.bindResponseSource() else {
                operation.beginClosing(.transportFailure("Response source admission was closed."))
                return
            }
            let tracked = AsyncThrowingStream<Data, Swift.Error>(bufferingPolicy: .unbounded) { continuation in
                let sourceTask = Task {
                    do {
                        for try await chunk in source {
                            try Task.checkCancellation()
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                        sourceReservation.acknowledge()
                    } catch is CancellationError {
                        continuation.finish()
                        sourceReservation.acknowledge()
                    } catch {
                        continuation.finish(throwing: error)
                        sourceReservation.acknowledge(.failed(error.localizedDescription))
                    }
                }
                sourceReservation.install(sourceTask)
                continuation.onTermination = { _ in sourceTask.cancel() }
            }
            preparedResponse = .stream(tracked, headers: headers)
        default:
            operation.markResponseSourceNotRequired()
            preparedResponse = response
        }

        guard await connection.supplyResponse(for: operation),
              let writerReservation = operation.bindWriter()
        else { return }
        nonisolated(unsafe) let context = context
        let heartbeatInterval = await server.responseHeartbeatInterval
        let writerTask = Task {
            let completion = await self.writeResponse(
                preparedResponse,
                operation: operation,
                version: version,
                context: context,
                heartbeatInterval: heartbeatInterval
            )
            switch completion {
            case .responded:
                operation.acknowledgeResponseEnd()
                writerReservation.acknowledge()
            case .cancelled:
                writerReservation.acknowledge()
            case .failed(let message):
                writerReservation.acknowledge(.failed(message))
            }
            await self.server.requestOperationDidFinish(
                sessionID: operation.snapshot().boundSessionID
            )
        }
        writerReservation.install(writerTask)
    }

    private enum WriterCompletion {
        case responded
        case cancelled
        case failed(String)
    }

    private func writeResponse(
        _ response: HTTPResponse,
        operation: MCPHTTPNetworkResourceOwner.RequestOperation,
        version: HTTPVersion,
        context: ChannelHandlerContext,
        heartbeatInterval: Duration?
    ) async -> WriterCompletion {
        let eventLoop = context.eventLoop
        let status = HTTPResponseStatus(statusCode: response.statusCode)
        let headers = response.headers
        var head = HTTPResponseHead(version: version, status: status)
        for (name, value) in headers { head.headers.add(name: name, value: value) }

        switch response {
        case .stream(let stream, _):
            do {
                try await writeResponsePart(.head(head), context: context, eventLoop: eventLoop)
                let events = AsyncStream<WriterEvent>.makeStream(bufferingPolicy: .unbounded)
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        do {
                            for try await chunk in stream {
                                try Task.checkCancellation()
                                events.continuation.yield(.body(chunk))
                            }
                            events.continuation.yield(.sourceFinished)
                        } catch is CancellationError {
                            events.continuation.yield(.sourceFinished)
                        } catch {
                            events.continuation.yield(.sourceFailed(error.localizedDescription))
                        }
                    }
                    if let heartbeatInterval {
                        group.addTask {
                            while Task.isCancelled == false {
                                do { try await Task.sleep(for: heartbeatInterval) }
                                catch { return }
                                guard Task.isCancelled == false else { return }
                                events.continuation.yield(.heartbeat)
                            }
                        }
                    }

                    eventLoopLoop: for await event in events.stream {
                        switch event {
                        case .body(let data):
                            do { try await writeResponseBody(data, context: context, eventLoop: eventLoop) }
                            catch {
                                operation.beginClosing(.transportFailure(error.localizedDescription))
                                break eventLoopLoop
                            }
                        case .heartbeat:
                            do {
                                try await writeResponseBody(
                                    Data(": keep-alive\n\n".utf8),
                                    context: context,
                                    eventLoop: eventLoop
                                )
                            } catch {
                                operation.beginClosing(.transportFailure(error.localizedDescription))
                                break eventLoopLoop
                            }
                        case .sourceFinished:
                            break eventLoopLoop
                        case .sourceFailed(let message):
                            logger.error("MCP SSE stream failed: \(message, privacy: .public)")
                            operation.beginClosing(.transportFailure(message))
                            break eventLoopLoop
                        }
                    }
                    group.cancelAll()
                    events.continuation.finish()
                }
                try await writeResponsePart(.end(nil), context: context, eventLoop: eventLoop)
                return .responded
            } catch is CancellationError {
                do {
                    try await writeResponsePart(.end(nil), context: context, eventLoop: eventLoop)
                    return .responded
                } catch {
                    return .cancelled
                }
            } catch {
                return .failed(error.localizedDescription)
            }

        default:
            let body = response.bodyData
            if let body { head.headers.add(name: "Content-Length", value: "\(body.count)") }
            do {
                try await writeResponsePart(.head(head), context: context, eventLoop: eventLoop)
                if let body { try await writeResponseBody(body, context: context, eventLoop: eventLoop) }
                try await writeResponsePart(.end(nil), context: context, eventLoop: eventLoop)
                return .responded
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    private func writeResponsePart(
        _ part: HTTPServerResponsePart,
        context: ChannelHandlerContext,
        eventLoop: any EventLoop
    ) async throws {
        let writer = ResponsePartWriter(handler: self, context: context)
        let promise = eventLoop.makePromise(of: Void.self)
        eventLoop.execute {
            writer.writeAndFlush(part, promise: promise)
        }
        try await promise.futureResult.get()
    }

    private func writeResponseBody(
        _ data: Data,
        context: ChannelHandlerContext,
        eventLoop: any EventLoop
    ) async throws {
        let writer = ResponsePartWriter(handler: self, context: context)
        let promise = eventLoop.makePromise(of: Void.self)
        eventLoop.execute {
            writer.writeBody(data, promise: promise)
        }
        try await promise.futureResult.get()
    }
}
