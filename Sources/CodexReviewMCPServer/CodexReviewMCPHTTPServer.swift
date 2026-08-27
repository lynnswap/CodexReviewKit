import Darwin
import Foundation
import MCP
import OSLog
import CodexReview
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

private let logger = Logger(subsystem: "CodexReviewKit", category: "mcp-http")

private enum MCPHTTPResponseSourceKind: Sendable {
    case finite
    case open
}

private struct TrackedHTTPResponse {
    struct StreamLifecycle: Sendable {
        let source: AsyncThrowingStream<Data, Swift.Error>
        let kind: MCPHTTPResponseSourceKind
    }

    var response: HTTPResponse
    var streamLifecycle: StreamLifecycle? = nil
}

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

    struct LifecycleError: Swift.Error, LocalizedError, Equatable, Sendable {
        package enum Resource: String, Equatable, Sendable {
            case listener
            case eventLoopGroup
        }

        package struct Failure: Equatable, Sendable {
            package let resource: Resource
            package let message: String

            package init(resource: Resource, message: String) {
                self.resource = resource
                self.message = message
            }
        }

        package let first: Failure
        package let additional: [Failure]

        package init(first: Failure, additional: [Failure] = []) {
            self.first = first
            self.additional = additional
        }

        package var failures: [Failure] {
            [first] + additional
        }

        package var errorDescription: String? {
            failures.map { "\($0.resource.rawValue): \($0.message)" }
                .joined(separator: "; ")
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
        package var maximumRequestBodyBytes: Int

        package init(
            host: String = "localhost",
            port: Int = 9417,
            endpoint: String = "/mcp",
            sessionTimeout: TimeInterval = 3600,
            retryInterval: Int? = 1000,
            maximumRequestBodyBytes: Int = 1_048_576
        ) {
            self.init(
                host: host,
                port: port,
                endpoint: endpoint,
                sessionTimeout: sessionTimeout,
                retryInterval: retryInterval,
                streamHeartbeatInterval: .seconds(30),
                boundedReviewWaitDuration: .seconds(540),
                maximumRequestBodyBytes: maximumRequestBodyBytes
            )
        }

        package init(
            host: String = "localhost",
            port: Int = 9417,
            endpoint: String = "/mcp",
            sessionTimeout: TimeInterval = 3600,
            retryInterval: Int? = 1000,
            streamHeartbeatInterval: Duration?,
            boundedReviewWaitDuration: Duration = .seconds(540),
            maximumRequestBodyBytes: Int = 1_048_576
        ) {
            precondition(
                maximumRequestBodyBytes >= 0,
                "MCP HTTP Configuration owns a nonnegative request-body byte limit."
            )
            self.host = host
            self.port = port
            self.endpoint = endpoint.hasPrefix("/") ? endpoint : "/\(endpoint)"
            self.sessionTimeout = sessionTimeout
            self.retryInterval = retryInterval
            self.streamHeartbeatInterval = streamHeartbeatInterval
            self.boundedReviewWaitDuration = boundedReviewWaitDuration
            self.maximumRequestBodyBytes = maximumRequestBodyBytes
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

private actor MCPHTTPLifecycleCompletionGate {
    private var shouldHoldNextCompletion = false
    private var releaseWasRequested = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []

    func holdNextCompletion() {
        precondition(
            shouldHoldNextCompletion == false && continuation == nil,
            "MCPHTTPLifecycleCompletionGate owns at most one held operation."
        )
        shouldHoldNextCompletion = true
        releaseWasRequested = false
    }

    func waitIfNeeded() async {
        guard shouldHoldNextCompletion else {
            return
        }
        let waiters = holdWaiters
        holdWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        if releaseWasRequested {
            reset()
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        reset()
    }

    func waitUntilHolding() async {
        if continuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            if self.continuation != nil {
                continuation.resume()
            } else {
                holdWaiters.append(continuation)
            }
        }
    }

    func release() {
        guard shouldHoldNextCompletion else {
            return
        }
        if let continuation {
            self.continuation = nil
            continuation.resume()
        } else {
            releaseWasRequested = true
        }
    }

    private func reset() {
        shouldHoldNextCompletion = false
        releaseWasRequested = false
    }
}

private actor MCPHTTPSessionCloseCompletionGate {
    private let completionGate = MCPHTTPLifecycleCompletionGate()
    private var storeReceipt: ReviewStoreSessionCloseReceipt?

    func holdNextCompletion() async {
        await completionGate.holdNextCompletion()
    }

    func waitIfNeeded(_ storeReceipt: ReviewStoreSessionCloseReceipt?) async {
        self.storeReceipt = storeReceipt
        await completionGate.waitIfNeeded()
        self.storeReceipt = nil
    }

    func waitUntilHolding() async -> ReviewStoreSessionCloseReceipt? {
        await completionGate.waitUntilHolding()
        return storeReceipt
    }

    func release() async {
        await completionGate.release()
    }
}

private actor MCPHTTPSessionRequestHandoffGate {
    private var isArmed = false
    private var releaseWasRequested = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []

    func holdNextHandoff() {
        precondition(
            isArmed == false && continuation == nil,
            "MCPHTTPSessionRequestHandoffGate owns at most one held handoff."
        )
        isArmed = true
        releaseWasRequested = false
    }

    func waitIfArmed() async {
        guard isArmed else {
            return
        }
        isArmed = false
        let waiters = holdWaiters
        holdWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        if releaseWasRequested {
            releaseWasRequested = false
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilHolding() async {
        if continuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            if self.continuation != nil {
                continuation.resume()
            } else {
                holdWaiters.append(continuation)
            }
        }
    }

    func release() {
        if let continuation {
            self.continuation = nil
            continuation.resume()
        } else if isArmed {
            releaseWasRequested = true
        }
    }
}

package actor CodexReviewMCPHTTPServer {
    private struct StartingGenerationFailure: Swift.Error, @unchecked Sendable {
        let primary: any Swift.Error
        let teardownResult: Result<Void, LifecycleError>
    }

    private typealias StartingGenerationResult = Result<RunningGeneration, StartingGenerationFailure>
    private typealias StoppingGenerationResult = Result<Void, LifecycleError>

    private final class StartingGeneration: @unchecked Sendable {
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
        var admissionClosed = false
        var listenerCloseTask: Task<StoppingGenerationResult, Never>?

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
        case stopped(StoppingGenerationResult)
        case starting(StartingGeneration)
        case running(RunningGeneration)
        case stopping(
            id: UInt64,
            resources: RunningGeneration?,
            task: Task<StoppingGenerationResult, Never>
        )
    }

    private struct StartingSessionFailure: Swift.Error, @unchecked Sendable {
        let primary: any Swift.Error
        let server: Server?
    }

    private typealias StartingSessionResult = Result<Server, StartingSessionFailure>

    private final class StartingSession: @unchecked Sendable {
        let id = UUID()
        let task: Task<StartingSessionResult, any Swift.Error>

        init(task: Task<StartingSessionResult, any Swift.Error>) {
            self.task = task
        }
    }

    private final class MCPSemanticSession: @unchecked Sendable {
        struct Identity: Hashable, Sendable {
            let generationID: UInt64
            let sessionID: String
            let ordinal: UInt64
        }

        struct Runtime: Sendable {
            let server: Server
            let transport: StatefulHTTPServerTransport
        }

        final class CloseReceipt: Sendable {
            let identity: Identity
            let task: Task<Void, Never>

            init(
                identity: Identity,
                operation: @escaping @Sendable (Identity) async -> Void
            ) {
                self.identity = identity
                self.task = Task {
                    await operation(identity)
                }
            }
        }

        enum Phase {
            case initializing(StartingSession)
            case active(Runtime)
        }

        enum RequestRole: Sendable {
            case initialize
            case regular
            case close
        }

        final class RequestLease: @unchecked Sendable {
            let operation: MCPHTTPNetworkResourceOwner.RequestOperation
            let role: RequestRole

            init(
                operation: MCPHTTPNetworkResourceOwner.RequestOperation,
                role: RequestRole
            ) {
                self.operation = operation
                self.role = role
            }
        }

        let identity: Identity
        let transport: StatefulHTTPServerTransport
        let createdAt: Date
        var phase: Phase
        var lastAccessedAt: Date
        let initialRequestLease: RequestLease
        private(set) var requestLeases: [UUID: RequestLease] = [:]
        var closeReceipt: CloseReceipt?

        init(
            identity: Identity,
            transport: StatefulHTTPServerTransport,
            starting: StartingSession,
            initialOperation: MCPHTTPNetworkResourceOwner.RequestOperation,
            now: Date
        ) {
            self.identity = identity
            self.transport = transport
            self.createdAt = now
            self.phase = .initializing(starting)
            self.lastAccessedAt = now
            let lease = RequestLease(operation: initialOperation, role: .initialize)
            self.initialRequestLease = lease
            requestLeases[initialOperation.id] = lease
        }

        func admitRequest(
            operation: MCPHTTPNetworkResourceOwner.RequestOperation,
            role: RequestRole,
            now: Date
        ) -> RequestLease? {
            guard case .active = phase else {
                return nil
            }
            if case .regular = role, closeReceipt != nil {
                return nil
            }
            let lease = RequestLease(operation: operation, role: role)
            requestLeases[operation.id] = lease
            lastAccessedAt = now
            return lease
        }

        func finishRequest(_ lease: RequestLease, now: Date) -> Bool {
            guard requestLeases[lease.operation.id] === lease else {
                return false
            }
            requestLeases.removeValue(forKey: lease.operation.id)
            lastAccessedAt = now
            return true
        }

        func owns(_ lease: RequestLease) -> Bool {
            requestLeases[lease.operation.id] === lease
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
    private var lifecycleState: LifecycleState = .stopped(.success(()))
    private var nextGenerationID: UInt64 = 0
    private var nextSessionOrdinal: UInt64 = 0
    private var sessions: [String: MCPSemanticSession] = [:]
    private var sessionRequestDrainWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private let startCompletionGate = MCPHTTPLifecycleCompletionGate()
    private let joinedStartCompletionGate = MCPHTTPLifecycleCompletionGate()
    private let stopCompletionGate = MCPHTTPLifecycleCompletionGate()
    private let finiteSourceCompletionGate = MCPHTTPLifecycleCompletionGate()
    private let writerFinalizationGate = MCPHTTPLifecycleCompletionGate()
    private let writerCompletionGate = MCPHTTPLifecycleCompletionGate()
    private let responseEndAcknowledgementGate = MCPHTTPLifecycleCompletionGate()
    private let responseEndWriteGate = MCPHTTPLifecycleCompletionGate()
    private let sessionStartCompletionGate = MCPHTTPLifecycleCompletionGate()
    private let sessionCloseCompletionGate = MCPHTTPSessionCloseCompletionGate()
    private let sessionRequestHandoffGate = MCPHTTPSessionRequestHandoffGate()
    private let sessionRequestRetirementGate = MCPHTTPLifecycleCompletionGate()
    private let responseBackpressureProbe = MCPHTTPResponseBackpressureProbe()
    private var eventLoopGroupShutdownCount = 0
    private var nextListenerCloseFailureForTesting: LifecycleError.Failure?
    private var nextEventLoopGroupShutdownFailureForTesting: LifecycleError.Failure?
    private var lastStartingAdmissionClosedGenerationID: UInt64?
    private var startingAdmissionCloseWaiters: [CheckedContinuation<Void, Never>] = []
    private var didStartJoinStoppingGeneration = false
    private var startStoppingJoinWaiters: [CheckedContinuation<Void, Never>] = []
    private var didStopJoinStoppingGeneration = false
    private var stopStoppingJoinWaiters: [CheckedContinuation<Void, Never>] = []
    private var didStartJoinStartingGeneration = false
    private var startStartingJoinWaiters: [CheckedContinuation<Void, Never>] = []
    private var didBeginClosingInitializingSession = false
    private var initializingSessionCloseWaiters: [CheckedContinuation<Void, Never>] = []
    private var sessionCloseJoinCount = 0

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
            case .stopped(let result):
                try result.get()
                nextGenerationID &+= 1
                let id = nextGenerationID
                let networkResources = MCPHTTPNetworkResourceOwner(generationID: id)
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
                try publishStartResult(result, operation: operation)
                return

            case .starting(let operation):
                recordStartJoinedStartingGenerationForTesting()
                await joinedStartCompletionGate.waitIfNeeded()
                let result = await operation.task.value
                try publishStartResult(result, operation: operation)
                return

            case .running(let resources):
                guard resources.admissionClosed == false else {
                    throw CancellationError()
                }
                return

            case .stopping(let id, _, let task):
                recordStartJoinedStoppingGenerationForTesting()
                let result = await task.value
                finishStopIfCurrent(id: id, result: result)
                try result.get()
            }
        }
    }

    private func performStartGeneration(
        id: UInt64,
        networkResources: MCPHTTPNetworkResourceOwner
    ) async -> StartingGenerationResult {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let maximumRequestBodyBytes = configuration.maximumRequestBodyBytes
        let responseBackpressureProbe = responseBackpressureProbe
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                guard let connection = networkResources.admitConnection(channel) else {
                    return channel.close(mode: .all)
                }
                return channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(CodexReviewMCPHTTPHandler(
                        server: self,
                        connection: connection,
                        maximumRequestBodyBytes: maximumRequestBodyBytes,
                        responseBackpressureProbe: responseBackpressureProbe
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
                await self?.sessionCleanupLoop()
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
            var failures: [LifecycleError.Failure] = []
            networkResources.closeAdmission()
            let closingNetworkResources = networkResources.beginClosing(.serverStop)
            if let listener {
                do {
                    try await listener.close()
                } catch {
                    failures.append(.init(
                        resource: .listener,
                        message: error.localizedDescription
                    ))
                }
                if let listenerFailure = consumeListenerCloseFailureForTesting() {
                    failures.append(listenerFailure)
                }
            }
            await closingNetworkResources.waitUntilClosed()
            do {
                try await group.shutdownGracefully()
            } catch {
                failures.append(.init(
                    resource: .eventLoopGroup,
                    message: error.localizedDescription
                ))
            }
            if let groupFailure = consumeEventLoopGroupShutdownFailureForTesting() {
                failures.append(groupFailure)
            }
            return .failure(.init(
                primary: CodexReviewMCPHTTPServer.Error.classifyStartError(
                    error,
                    configuration: configuration
                ),
                teardownResult: lifecycleResult(failures)
            ))
        }
    }

    private func publishStartResult(
        _ result: StartingGenerationResult,
        operation: StartingGeneration
    ) throws {
        switch result {
        case .success(let resources):
            if case .running(let current) = lifecycleState,
               current === resources {
                return
            }
            if case .stopping(_, let current?, _) = lifecycleState,
               current === resources {
                return
            }
            guard case .starting(let current) = lifecycleState,
                  current === operation,
                  operation.admissionClosed == false else {
                throw CancellationError()
            }
            lifecycleState = .running(resources)
            logger.info(
                "MCP Streamable HTTP server listening at \(resources.boundURL.absoluteString, privacy: .public)"
            )
        case .failure(let failure):
            if case .starting(let current) = lifecycleState,
               current === operation {
                lifecycleState = .stopped(failure.teardownResult)
            }
            throw failure.primary
        }
    }

    package func stop() async throws {
        let id: UInt64
        let task: Task<StoppingGenerationResult, Never>
        switch lifecycleState {
        case .stopped(let result):
            try result.get()
            return

        case .stopping(let currentID, _, let currentTask):
            recordStopJoinedStoppingGenerationForTesting()
            id = currentID
            task = currentTask

        case .running(let resources):
            resources.admissionClosed = true
            resources.networkResources.closeAdmission()
            let closingNetworkResources = resources.networkResources.beginClosing(.serverStop)
            id = resources.id
            let groupFailure = consumeEventLoopGroupShutdownFailureForTesting()
            let newTask = Task<StoppingGenerationResult, Never> { [self] in
                await performStopGeneration(
                    resources,
                    closingNetworkResources: closingNetworkResources,
                    injectedGroupFailure: groupFailure
                )
            }
            lifecycleState = .stopping(
                id: id,
                resources: resources,
                task: newTask
            )
            task = newTask

        case .starting(let operation):
            let closingNetworkResources = closeStartingAdmission(operation)
            id = operation.id
            let newTask = Task<StoppingGenerationResult, Never> { [self] in
                switch await operation.task.value {
                case .success(let resources):
                    resources.admissionClosed = true
                    return await performStopGeneration(
                        resources,
                        closingNetworkResources: closingNetworkResources,
                        injectedGroupFailure: consumeEventLoopGroupShutdownFailureForTesting()
                    )
                case .failure(let failure):
                    return failure.teardownResult
                }
            }
            lifecycleState = .stopping(id: id, resources: nil, task: newTask)
            task = newTask
        }

        let result = await task.value
        finishStopIfCurrent(id: id, result: result)
        try result.get()
    }

    package func closeAdmission() async {
        switch lifecycleState {
        case .stopped:
            return
        case .starting(let operation):
            let closingNetworkResources = closeStartingAdmission(operation)
            let id = operation.id
            let task = Task<StoppingGenerationResult, Never> { [self] in
                switch await operation.task.value {
                case .success(let resources):
                    resources.admissionClosed = true
                    return await performStopGeneration(
                        resources,
                        closingNetworkResources: closingNetworkResources,
                        injectedGroupFailure: consumeEventLoopGroupShutdownFailureForTesting()
                    )
                case .failure(let failure):
                    return failure.teardownResult
                }
            }
            lifecycleState = .stopping(id: id, resources: nil, task: task)
            let result = await task.value
            finishStopIfCurrent(id: id, result: result)
        case .running(let resources):
            resources.admissionClosed = true
            resources.networkResources.closeAdmission()
            _ = await listenerCloseTask(for: resources).value
        case .stopping(let id, _, let task):
            let result = await task.value
            finishStopIfCurrent(id: id, result: result)
        }
    }

    private func closeStartingAdmission(
        _ operation: StartingGeneration
    ) -> MCPHTTPNetworkResourceOwner.ClosingGeneration {
        if operation.admissionClosed == false {
            operation.admissionClosed = true
            operation.networkResources.closeAdmission()
            operation.task.cancel()
            lastStartingAdmissionClosedGenerationID = operation.id
            let waiters = startingAdmissionCloseWaiters
            startingAdmissionCloseWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
        }
        return operation.networkResources.beginClosing(.serverStop)
    }

    private func performStopGeneration(
        _ resources: RunningGeneration,
        closingNetworkResources: MCPHTTPNetworkResourceOwner.ClosingGeneration,
        injectedGroupFailure: LifecycleError.Failure?
    ) async -> StoppingGenerationResult {
        let listenerCloseTask = listenerCloseTask(for: resources)
        resources.cleanupTask.cancel()
        await closeAllSessions()
        let listenerResult = await listenerCloseTask.value
        await resources.cleanupTask.value
        await closingNetworkResources.waitUntilClosed()
        await stopCompletionGate.waitIfNeeded()

        var failures: [LifecycleError.Failure] = []
        if case .failure(let error) = listenerResult {
            failures.append(contentsOf: error.failures)
        }
        do {
            try await resources.eventLoopGroup.shutdownGracefully()
        } catch {
            failures.append(.init(
                resource: .eventLoopGroup,
                message: error.localizedDescription
            ))
        }
        if let injectedGroupFailure {
            failures.append(injectedGroupFailure)
        }
        eventLoopGroupShutdownCount += 1
        logger.info("MCP Streamable HTTP server stopped")
        return lifecycleResult(failures)
    }

    private func listenerCloseTask(
        for resources: RunningGeneration
    ) -> Task<StoppingGenerationResult, Never> {
        if let listenerCloseTask = resources.listenerCloseTask {
            return listenerCloseTask
        }
        let listener = resources.listener
        let injectedFailure = consumeListenerCloseFailureForTesting()
        let task = Task<StoppingGenerationResult, Never> {
            var failures: [LifecycleError.Failure] = []
            do {
                try await listener.close()
            } catch {
                failures.append(.init(
                    resource: .listener,
                    message: error.localizedDescription
                ))
            }
            if let injectedFailure {
                failures.append(injectedFailure)
            }
            guard let first = failures.first else {
                return .success(())
            }
            return .failure(.init(
                first: first,
                additional: Array(failures.dropFirst())
            ))
        }
        resources.listenerCloseTask = task
        return task
    }

    private func finishStopIfCurrent(
        id: UInt64,
        result: StoppingGenerationResult
    ) {
        guard case .stopping(let currentID, _, _) = lifecycleState,
              currentID == id else {
            return
        }
        lifecycleState = .stopped(result)
    }

    private func lifecycleResult(
        _ failures: [LifecycleError.Failure]
    ) -> StoppingGenerationResult {
        guard let first = failures.first else {
            return .success(())
        }
        return .failure(.init(
            first: first,
            additional: Array(failures.dropFirst())
        ))
    }

    private func consumeListenerCloseFailureForTesting() -> LifecycleError.Failure? {
        defer { nextListenerCloseFailureForTesting = nil }
        return nextListenerCloseFailureForTesting
    }

    private func consumeEventLoopGroupShutdownFailureForTesting() -> LifecycleError.Failure? {
        defer { nextEventLoopGroupShutdownFailureForTesting = nil }
        return nextEventLoopGroupShutdownFailureForTesting
    }

    private func recordStartJoinedStoppingGenerationForTesting() {
        didStartJoinStoppingGeneration = true
        let waiters = startStoppingJoinWaiters
        startStoppingJoinWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func recordStartJoinedStartingGenerationForTesting() {
        didStartJoinStartingGeneration = true
        let waiters = startStartingJoinWaiters
        startStartingJoinWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func recordStopJoinedStoppingGenerationForTesting() {
        didStopJoinStoppingGeneration = true
        let waiters = stopStoppingJoinWaiters
        stopStoppingJoinWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    package func holdNextStartCompletionForTesting() async {
        lastStartingAdmissionClosedGenerationID = nil
        didStartJoinStartingGeneration = false
        await startCompletionGate.holdNextCompletion()
    }

    package func waitUntilStartCompletionIsHeldForTesting() async {
        await startCompletionGate.waitUntilHolding()
    }

    package func releaseStartCompletionForTesting() async {
        await startCompletionGate.release()
    }

    package func holdNextSessionStartCompletionForTesting() async {
        didBeginClosingInitializingSession = false
        await sessionStartCompletionGate.holdNextCompletion()
    }

    package func waitUntilSessionStartCompletionIsHeldForTesting() async {
        await sessionStartCompletionGate.waitUntilHolding()
    }

    package func releaseSessionStartCompletionForTesting() async {
        await sessionStartCompletionGate.release()
    }

    package func holdNextSessionCloseCompletionForTesting() async {
        await sessionCloseCompletionGate.holdNextCompletion()
    }

    package func waitUntilSessionCloseCompletionIsHeldForTesting() async -> ReviewStoreSessionCloseReceipt? {
        await sessionCloseCompletionGate.waitUntilHolding()
    }

    package func releaseSessionCloseCompletionForTesting() async {
        await sessionCloseCompletionGate.release()
    }

    package func holdNextSessionRequestHandoffForTesting() async {
        await sessionRequestHandoffGate.holdNextHandoff()
    }

    package func waitUntilSessionRequestHandoffIsHeldForTesting() async {
        await sessionRequestHandoffGate.waitUntilHolding()
    }

    package func releaseSessionRequestHandoffForTesting() async {
        await sessionRequestHandoffGate.release()
    }

    package func holdNextSessionRequestRetirementForTesting() async {
        await sessionRequestRetirementGate.holdNextCompletion()
    }

    package func waitUntilSessionRequestRetirementIsHeldForTesting() async {
        await sessionRequestRetirementGate.waitUntilHolding()
    }

    package func releaseSessionRequestRetirementForTesting() async {
        await sessionRequestRetirementGate.release()
    }

    package func waitUntilInitializingSessionCloseBeginsForTesting() async {
        if didBeginClosingInitializingSession {
            return
        }
        await withCheckedContinuation { continuation in
            if didBeginClosingInitializingSession {
                continuation.resume()
            } else {
                initializingSessionCloseWaiters.append(continuation)
            }
        }
    }

    package func sessionCountForTesting() -> Int {
        sessions.count
    }

    package func sessionCloseReceiptIdentityForTesting(sessionID: String) -> ObjectIdentifier? {
        sessions[sessionID]?.closeReceipt.map(ObjectIdentifier.init)
    }

    package func sessionCloseJoinCountForTesting() -> Int {
        sessionCloseJoinCount
    }

    package func waitUntilStartingGenerationAdmissionIsClosedForTesting() async {
        if lastStartingAdmissionClosedGenerationID != nil {
            return
        }
        await withCheckedContinuation { continuation in
            if lastStartingAdmissionClosedGenerationID != nil {
                continuation.resume()
            } else {
                startingAdmissionCloseWaiters.append(continuation)
            }
        }
    }

    package func waitUntilStartJoinsStartingGenerationForTesting() async {
        if didStartJoinStartingGeneration {
            return
        }
        await withCheckedContinuation { continuation in
            if didStartJoinStartingGeneration {
                continuation.resume()
            } else {
                startStartingJoinWaiters.append(continuation)
            }
        }
    }

    package func holdNextJoinedStartCompletionForTesting() async {
        await joinedStartCompletionGate.holdNextCompletion()
    }

    package func waitUntilJoinedStartCompletionIsHeldForTesting() async {
        await joinedStartCompletionGate.waitUntilHolding()
    }

    package func releaseJoinedStartCompletionForTesting() async {
        await joinedStartCompletionGate.release()
    }

    package func holdNextStopCompletionForTesting() async {
        didStartJoinStoppingGeneration = false
        didStopJoinStoppingGeneration = false
        await stopCompletionGate.holdNextCompletion()
    }

    package func waitUntilStopCompletionIsHeldForTesting() async {
        await stopCompletionGate.waitUntilHolding()
    }

    package func releaseStopCompletionForTesting() async {
        await stopCompletionGate.release()
    }

    package func waitUntilStartJoinsStoppingGenerationForTesting() async {
        if didStartJoinStoppingGeneration {
            return
        }
        await withCheckedContinuation { continuation in
            if didStartJoinStoppingGeneration {
                continuation.resume()
            } else {
                startStoppingJoinWaiters.append(continuation)
            }
        }
    }

    package func waitUntilStopJoinsStoppingGenerationForTesting() async {
        if didStopJoinStoppingGeneration {
            return
        }
        await withCheckedContinuation { continuation in
            if didStopJoinStoppingGeneration {
                continuation.resume()
            } else {
                stopStoppingJoinWaiters.append(continuation)
            }
        }
    }

    package func injectNextListenerCloseFailureForTesting(_ message: String) {
        nextListenerCloseFailureForTesting = .init(
            resource: .listener,
            message: message
        )
    }

    package func injectNextEventLoopGroupShutdownFailureForTesting(_ message: String) {
        nextEventLoopGroupShutdownFailureForTesting = .init(
            resource: .eventLoopGroup,
            message: message
        )
    }

    package func currentGenerationIDForTesting() -> UInt64? {
        switch lifecycleState {
        case .starting(let operation):
            operation.id
        case .running(let resources):
            resources.id
        case .stopping(let id, _, _):
            id
        case .stopped:
            nil
        }
    }

    package func networkResourceSnapshotForTesting() -> MCPHTTPNetworkResourceOwner.Snapshot? {
        switch lifecycleState {
        case .starting(let operation):
            operation.networkResources.snapshot()
        case .running(let resources):
            resources.networkResources.snapshot()
        case .stopping(_, let resources?, _):
            resources.networkResources.snapshot()
        case .stopping, .stopped:
            nil
        }
    }

    package func waitUntilNetworkRequestTerminalForTesting(
        requestID: UUID
    ) async -> MCPHTTPNetworkResourceOwner.TerminalCause? {
        let networkResources: MCPHTTPNetworkResourceOwner?
        switch lifecycleState {
        case .starting(let operation):
            networkResources = operation.networkResources
        case .running(let resources):
            networkResources = resources.networkResources
        case .stopping(_, let resources?, _):
            networkResources = resources.networkResources
        case .stopping, .stopped:
            networkResources = nil
        }
        return await networkResources?.waitUntilRequestTerminalForTesting(requestID: requestID)
    }

    package func waitForNetworkCloseWaiterRegistrationForTesting()
        async -> MCPHTTPNetworkResourceOwner.CloseWaiterRegistration
    {
        let networkResources: MCPHTTPNetworkResourceOwner?
        switch lifecycleState {
        case .starting(let operation):
            networkResources = operation.networkResources
        case .running(let resources):
            networkResources = resources.networkResources
        case .stopping(_, let resources?, _):
            networkResources = resources.networkResources
        case .stopping, .stopped:
            networkResources = nil
        }
        guard let networkResources else {
            preconditionFailure("An active MCP generation owns the network close waiter.")
        }
        return await networkResources.waitForCloseWaiterRegistrationForTesting()
    }

    package func holdNextFiniteSourceCompletionForTesting() async {
        await finiteSourceCompletionGate.holdNextCompletion()
    }

    package func waitUntilFiniteSourceCompletionIsHeldForTesting() async {
        await finiteSourceCompletionGate.waitUntilHolding()
    }

    package func releaseFiniteSourceCompletionForTesting() async {
        await finiteSourceCompletionGate.release()
    }

    package func holdNextWriterCompletionForTesting() async {
        await writerCompletionGate.holdNextCompletion()
    }

    package func holdNextWriterFinalizationForTesting() async {
        await writerFinalizationGate.holdNextCompletion()
    }

    package func waitUntilWriterFinalizationIsHeldForTesting() async {
        await writerFinalizationGate.waitUntilHolding()
    }

    package func releaseWriterFinalizationForTesting() async {
        await writerFinalizationGate.release()
    }

    package func waitUntilWriterCompletionIsHeldForTesting() async {
        await writerCompletionGate.waitUntilHolding()
    }

    package func releaseWriterCompletionForTesting() async {
        await writerCompletionGate.release()
    }

    package func holdNextResponseEndAcknowledgementForTesting() async {
        await responseEndAcknowledgementGate.holdNextCompletion()
    }

    package func waitUntilResponseEndAcknowledgementIsHeldForTesting() async {
        await responseEndAcknowledgementGate.waitUntilHolding()
    }

    package func releaseResponseEndAcknowledgementForTesting() async {
        await responseEndAcknowledgementGate.release()
    }

    package func holdNextResponseEndWriteForTesting() async {
        await responseEndWriteGate.holdNextCompletion()
    }

    package func waitUntilResponseEndWriteIsHeldForTesting() async {
        await responseEndWriteGate.waitUntilHolding()
    }

    package func releaseResponseEndWriteForTesting() async {
        await responseEndWriteGate.release()
    }

    package func holdNextResponseBodyWriteForTesting() {
        responseBackpressureProbe.holdNextBodyWriteForTesting()
    }

    package func waitUntilResponseBodyWriteIsHeldForTesting() async {
        await responseBackpressureProbe.waitUntilBodyWriteIsHeldForTesting()
    }

    package func releaseResponseBodyWriteForTesting() {
        responseBackpressureProbe.releaseBodyWriteForTesting()
    }

    package func responseSourceReadCountForTesting() -> Int {
        responseBackpressureProbe.sourceReadCountForTesting()
    }

    package static func responseRendezvousPrioritizesBodyForTesting() async -> Bool {
        let events = MCPHTTPResponseEventChannel()
        let body = Data("body".utf8)
        let sender = Task { await events.sendBody(body) }
        await events.waitUntilBodyIsPendingForTesting()
        for _ in 0..<3 { events.offerHeartbeat() }
        guard case .body(let id, let received) = await events.receive() else {
            events.close()
            return false
        }
        events.acknowledgeBody(id: id, wasWritten: true)
        let wasAcknowledged = await sender.value
        guard case .heartbeat = await events.receive() else {
            events.close()
            return false
        }
        events.finishSource(.sourceFinished)
        guard case .sourceFinished = await events.receive() else {
            events.close()
            return false
        }
        events.close()
        return received == body && wasAcknowledged
    }

    fileprivate var responseHeartbeatInterval: Duration? {
        configuration.streamHeartbeatInterval
    }

    fileprivate func waitAfterFiniteSourceCompletionForTesting() async {
        await finiteSourceCompletionGate.waitIfNeeded()
    }

    fileprivate func waitAfterWriterCompletionForTesting() async {
        await writerCompletionGate.waitIfNeeded()
    }

    fileprivate func waitBeforeWriterFinalizationForTesting() async {
        await writerFinalizationGate.waitIfNeeded()
    }

    fileprivate func waitAfterResponseEndAcknowledgementForTesting() async {
        await responseEndAcknowledgementGate.waitIfNeeded()
    }

    fileprivate func waitBeforeResponseEndWriteForTesting() async {
        await responseEndWriteGate.waitIfNeeded()
    }

    package func eventLoopGroupShutdownCountForTesting() -> Int {
        eventLoopGroupShutdownCount
    }

    package func validationResponseForTesting(_ request: HTTPRequest) -> HTTPResponse? {
        makeValidationPipeline().validate(
            request,
            context: .init(
                httpMethod: request.method,
                sessionID: request.header(HTTPHeaderName.sessionID),
                isInitializationRequest: request.body.map(Self.isInitializeRequest) ?? false
            )
        )
    }

    fileprivate func handleTrackedHTTPRequest(
        _ request: HTTPRequest,
        operation: MCPHTTPNetworkResourceOwner.RequestOperation
    ) async -> TrackedHTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        if let sessionID, let session = sessions[sessionID] {
            guard case .active = session.phase else {
                return .init(response: .error(
                    statusCode: 404,
                    .invalidRequest("Not Found: Session not found or expired")
                ))
            }
            guard let request = Self.ownedRequest(
                request,
                operation: operation,
                sessionID: sessionID
            ) else {
                return .init(response: .error(
                    statusCode: 500,
                    .internalError("MCP request ownership conflict.")
                ))
            }
            let isCloseRequest = request.method.uppercased() == "DELETE"
            guard let lease = session.admitRequest(
                operation: operation,
                role: isCloseRequest ? .close : .regular,
                now: Date()
            ) else {
                return .init(response: .error(
                    statusCode: 404,
                    .invalidRequest("Not Found: Session not found or expired")
                ))
            }
            observeSessionRequest(lease, in: session)
            if isCloseRequest {
                if let validationFailure = makeValidationPipeline().validate(
                    request,
                    context: .init(httpMethod: request.method, sessionID: sessionID)
                ) {
                    return .init(response: validationFailure)
                }
                await closeSession(session)
                return .init(response: .ok(headers: [HTTPHeaderName.sessionID: sessionID]))
            }
            await sessionRequestHandoffGate.waitIfArmed()
            guard authorizeSDKHandoff(for: lease, in: session) else {
                return .init(response: .error(
                    statusCode: 503,
                    .internalError("MCP request was cancelled before SDK admission."),
                    sessionID: sessionID
                ))
            }
            let response = await session.transport.handleRequest(request)
            let trackedResponse = trackResponse(
                response,
                responseSourceKind: Self.responseSourceKind(for: request)
            ).response
            return trackedResponse
        }

        if request.method.uppercased() == "POST",
           let body = request.body,
           Self.isInitializeRequest(body)
        {
            return await createSessionAndHandle(request, operation: operation)
        }

        if sessionID != nil {
            return .init(response: .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired")))
        }
        return .init(
            response: .error(
                statusCode: 400,
                .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header")
            )
        )
    }

    private func createSessionAndHandle(
        _ request: HTTPRequest,
        operation: MCPHTTPNetworkResourceOwner.RequestOperation
    ) async -> TrackedHTTPResponse {
        let sessionID = UUID().uuidString
        guard let request = Self.ownedRequest(
            request,
            operation: operation,
            sessionID: sessionID
        ), let networkResources = operation.resourceOwner else {
            return .init(response: .error(
                statusCode: 500,
                .internalError("MCP request ownership conflict.")
            ))
        }
        guard case .running(let generation) = lifecycleState,
              generation.admissionClosed == false,
              generation.id == networkResources.generationID,
              generation.networkResources === networkResources else {
            return .init(response: .error(
                statusCode: 503,
                .internalError("MCP server generation is not accepting sessions.")
            ))
        }
        let clientSession = MCPClientSessionState()
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            validationPipeline: makeValidationPipeline(),
            retryInterval: configuration.retryInterval
        )
        let adapter = adapter
        let boundedReviewWaitDuration = configuration.boundedReviewWaitDuration
        let sessionStartCompletionGate = sessionStartCompletionGate
        guard let startTask = operation.startDomainWork({
            () async throws -> StartingSessionResult in
            let server = await makeMCPProtocolServer(
                adapter: adapter,
                defaultSessionID: sessionID,
                clientSession: clientSession,
                boundedReviewWaitDuration: boundedReviewWaitDuration,
                networkResources: networkResources
            )
            do {
                try Task.checkCancellation()
                try await server.start(transport: transport) { clientInfo, _ in
                    await clientSession.update(clientInfo: clientInfo)
                }
                await sessionStartCompletionGate.waitIfNeeded()
                try Task.checkCancellation()
                return .success(server)
            } catch {
                return .failure(.init(primary: error, server: server))
            }
        }) else {
            return .init(response: .error(
                statusCode: 503,
                .internalError("MCP session initialization was cancelled.")
            ))
        }
        let starting = StartingSession(task: startTask)
        nextSessionOrdinal &+= 1
        let session = MCPSemanticSession(
            identity: .init(
                generationID: generation.id,
                sessionID: sessionID,
                ordinal: nextSessionOrdinal
            ),
            transport: transport,
            starting: starting,
            initialOperation: operation,
            now: Date()
        )
        sessions[sessionID] = session
        observeSessionRequest(session.initialRequestLease, in: session)

        let startResult: StartingSessionResult
        do {
            startResult = try await startTask.value
        } catch {
            startResult = .failure(.init(primary: error, server: nil))
        }
        switch startResult {
        case .success(let server):
            guard publishSessionStart(
                server,
                session: session,
                starting: starting,
                generation: generation,
                operation: operation
            ) else {
                await closeSession(session)
                return .init(response: .error(
                    statusCode: 503,
                    .internalError("MCP session initialization was cancelled.")
                ))
            }
            guard authorizeSDKHandoff(
                for: session.initialRequestLease,
                in: session
            ) else {
                await closeSession(session)
                return .init(response: .error(
                    statusCode: 503,
                    .internalError("MCP session initialization was cancelled.")
                ))
            }
            let response = await transport.handleRequest(request)
            let (trackedResponse, didFinishRequest) = trackResponse(
                response,
                responseSourceKind: Self.responseSourceKind(for: request)
            )
            if didFinishRequest, case .error = trackedResponse.response {
                await closeSession(session)
            }
            return trackedResponse

        case .failure(let failure):
            await closeSession(session)
            return .init(
                response: .error(
                    statusCode: 500,
                    .internalError("Failed to create MCP session: \(failure.primary.localizedDescription)")
                )
            )
        }
    }

    private func publishSessionStart(
        _ server: Server,
        session: MCPSemanticSession,
        starting: StartingSession,
        generation: RunningGeneration,
        operation: MCPHTTPNetworkResourceOwner.RequestOperation
    ) -> Bool {
        guard sessions[session.identity.sessionID] === session,
              session.closeReceipt == nil,
              case .initializing(let currentStart) = session.phase,
              currentStart === starting,
              case .running(let currentGeneration) = lifecycleState,
              currentGeneration === generation,
              generation.admissionClosed == false,
              generation.networkResources.generationID == session.identity.generationID else {
            return false
        }
        return operation.withActiveSessionRequest(
            for: session.identity.sessionID
        ) {
            session.phase = .active(.init(server: server, transport: session.transport))
        }
    }

    private func authorizeSDKHandoff(
        for lease: MCPSemanticSession.RequestLease,
        in session: MCPSemanticSession
    ) -> Bool {
        var didAuthorize = false
        let hadNetworkAuthority = lease.operation.withActiveSessionRequest(
            for: session.identity.sessionID
        ) {
            didAuthorize = sessions[session.identity.sessionID] === session
                && session.owns(lease)
                && session.closeReceipt == nil
                && Task.isCancelled == false
        }
        return hadNetworkAuthority && didAuthorize
    }

    package static func ownedRequest(
        _ request: HTTPRequest,
        operation: MCPHTTPNetworkResourceOwner.RequestOperation,
        sessionID: String
    ) -> HTTPRequest? {
        guard operation.bindSession(sessionID) else { return nil }
        let internalName = MCPHTTPNetworkResourceOwner.operationTokenHeaderName.lowercased()
        var headers = request.headers.filter { $0.key.lowercased() != internalName }
        headers[MCPHTTPNetworkResourceOwner.operationTokenHeaderName] = operation.token.headerValue
        return HTTPRequest(
            method: request.method,
            headers: headers,
            body: request.body,
            path: request.path
        )
    }

    private func closeSession(_ session: MCPSemanticSession) async {
        let sessionID = session.identity.sessionID
        guard sessions[sessionID] === session else {
            return
        }
        if let receipt = session.closeReceipt {
            sessionCloseJoinCount += 1
            await receipt.task.value
            return
        }
        let receipt = MCPSemanticSession.CloseReceipt(
            identity: session.identity
        ) { [self, session] identity in
            await performSessionClose(session, identity: identity)
        }
        session.closeReceipt = receipt
        await receipt.task.value
    }

    private func performSessionClose(
        _ session: MCPSemanticSession,
        identity: MCPSemanticSession.Identity
    ) async {
        let sessionID = identity.sessionID
        let storeReceipt = await adapter.beginCloseSession(sessionID)
        await sessionCloseCompletionGate.waitIfNeeded(storeReceipt)
        let server: Server?
        switch session.phase {
        case .initializing(let starting):
            didBeginClosingInitializingSession = true
            let waiters = initializingSessionCloseWaiters
            initializingSessionCloseWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
            starting.task.cancel()
            await session.transport.disconnect()
            do {
                switch try await starting.task.value {
                case .success(let startedServer):
                    server = startedServer
                case .failure(let failure):
                    server = failure.server
                }
            } catch {
                server = nil
            }
        case .active(let runtime):
            await runtime.transport.disconnect()
            server = runtime.server
        }
        if let server {
            await server.waitUntilCompleted()
            await server.stop()
        }
        if let storeReceipt {
            await storeReceipt.waitUntilClosed()
        }
        guard session.identity == identity,
              sessions[sessionID] === session else {
            return
        }
        sessions.removeValue(forKey: sessionID)
        resumeSessionRequestDrainWaiters(sessionID: sessionID)
        logger.info("Closed MCP HTTP session \(sessionID, privacy: .public)")
    }

    private func trackResponse(
        _ response: HTTPResponse,
        responseSourceKind: MCPHTTPResponseSourceKind
    ) -> (response: TrackedHTTPResponse, didFinishRequest: Bool) {
        switch response {
        case .stream(let source, _):
            return (
                .init(
                    response: response,
                    streamLifecycle: .init(
                        source: source,
                        kind: responseSourceKind
                    )
                ),
                false
            )

        default:
            return (.init(response: response), true)
        }
    }

    private func observeSessionRequest(
        _ lease: MCPSemanticSession.RequestLease,
        in session: MCPSemanticSession
    ) {
        Task { [weak self, weak session] in
            let terminalCause = await lease.operation.waitUntilClosed()
            guard let self, let session else { return }
            await self.finishSessionRequest(
                lease,
                terminalCause: terminalCause,
                in: session
            )
        }
    }

    private func finishSessionRequest(
        _ lease: MCPSemanticSession.RequestLease,
        terminalCause: MCPHTTPNetworkResourceOwner.TerminalCause?,
        in session: MCPSemanticSession
    ) async {
        guard sessions[session.identity.sessionID] === session,
              session.finishRequest(lease, now: Date()) else {
            return
        }
        if session.requestLeases.isEmpty {
            resumeSessionRequestDrainWaiters(sessionID: session.identity.sessionID)
        }
        await sessionRequestRetirementGate.waitIfNeeded()
        if lease.role == .initialize, terminalCause != nil {
            await closeSession(session)
        }
    }

    private func closeAllSessions() async {
        for session in sessions.values.sorted(by: {
            $0.identity.ordinal < $1.identity.ordinal
        }) {
            await closeSession(session)
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

    package func sessionRequestLeaseCountForTesting(sessionID: String) -> Int? {
        sessions[sessionID]?.requestLeases.count
    }

    package func waitUntilSessionRequestsDrainForTesting(sessionID: String) async {
        guard let session = sessions[sessionID], session.requestLeases.isEmpty == false else {
            return
        }
        await withCheckedContinuation { continuation in
            guard sessions[sessionID] === session,
                  session.requestLeases.isEmpty == false else {
                continuation.resume()
                return
            }
            sessionRequestDrainWaiters[sessionID, default: []].append(continuation)
        }
    }

    private func resumeSessionRequestDrainWaiters(sessionID: String) {
        let waiters = sessionRequestDrainWaiters.removeValue(forKey: sessionID) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func closeExpiredSessions(now: Date) async {
        var expiredSessions: [MCPSemanticSession] = []
        for session in sessions.values {
            guard case .active = session.phase,
                  session.requestLeases.isEmpty,
                  now.timeIntervalSince(session.lastAccessedAt) > configuration.sessionTimeout else {
                continue
            }
            if await adapter.hasActiveReviews(in: session.identity.sessionID) {
                if sessions[session.identity.sessionID] === session {
                    session.lastAccessedAt = Date()
                }
                continue
            }
            if sessions[session.identity.sessionID] === session,
               case .active = session.phase,
               session.requestLeases.isEmpty,
               now.timeIntervalSince(session.lastAccessedAt) > configuration.sessionTimeout {
                expiredSessions.append(session)
            }
        }
        for session in expiredSessions {
            await closeSession(session)
        }
    }

    private static func isInitializeRequest(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["method"] as? String == "initialize" && json["id"] != nil
    }

    private static func responseSourceKind(for request: HTTPRequest) -> MCPHTTPResponseSourceKind {
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              json["method"] is String,
              json["id"] != nil,
              (json["id"] is NSNull) == false else {
            return .open
        }
        return .finite
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

private final class MCPHTTPResponseEventChannel: @unchecked Sendable {
    enum Event: Sendable {
        case body(id: UUID, data: Data)
        case heartbeat
        case sourceFinished
        case sourceFailed(String)
        case cancelled
    }

    private struct PendingBody {
        let id: UUID
        let data: Data
        let acknowledgement: CheckedContinuation<Bool, Never>
    }

    private let lock = NSLock()
    private var pendingBody: PendingBody?
    private var inFlightBody: PendingBody?
    private var heartbeatPending = false
    private var terminal: Event?
    private var receiver: CheckedContinuation<Event, Never>?
    private var pendingBodyWaiters: [CheckedContinuation<Void, Never>] = []
    private var isClosed = false

    func sendBody(_ data: Data) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { acknowledgement in
            let receiver: CheckedContinuation<Event, Never>?
            let waiters: [CheckedContinuation<Void, Never>]
            lock.lock()
            if isClosed || terminal != nil {
                lock.unlock()
                acknowledgement.resume(returning: false)
                return
            }
            precondition(
                pendingBody == nil && inFlightBody == nil,
                "The response source waits for each physical body-write acknowledgement."
            )
            let body = PendingBody(id: id, data: data, acknowledgement: acknowledgement)
            if let waitingReceiver = self.receiver {
                self.receiver = nil
                inFlightBody = body
                receiver = waitingReceiver
            } else {
                pendingBody = body
                receiver = nil
            }
            waiters = pendingBodyWaiters
            pendingBodyWaiters.removeAll(keepingCapacity: false)
            lock.unlock()
            for waiter in waiters { waiter.resume() }
            receiver?.resume(returning: .body(id: id, data: data))
        }
    }

    func receive() async -> Event {
        await withCheckedContinuation { continuation in
            let immediate: Event?
            lock.lock()
            if isClosed {
                immediate = .cancelled
            } else if let pendingBody {
                self.pendingBody = nil
                inFlightBody = pendingBody
                immediate = .body(id: pendingBody.id, data: pendingBody.data)
            } else if let terminal {
                immediate = terminal
            } else if heartbeatPending {
                heartbeatPending = false
                immediate = .heartbeat
            } else {
                precondition(receiver == nil, "One response writer owns the channel receiver.")
                receiver = continuation
                immediate = nil
            }
            lock.unlock()
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    func acknowledgeBody(id: UUID, wasWritten: Bool) {
        let acknowledgement: CheckedContinuation<Bool, Never>?
        lock.lock()
        if let inFlightBody, inFlightBody.id == id {
            self.inFlightBody = nil
            acknowledgement = inFlightBody.acknowledgement
        } else {
            acknowledgement = nil
        }
        lock.unlock()
        acknowledgement?.resume(returning: wasWritten)
    }

    func offerHeartbeat() {
        let receiver: CheckedContinuation<Event, Never>?
        lock.lock()
        guard isClosed == false, terminal == nil else {
            lock.unlock()
            return
        }
        if pendingBody == nil, inFlightBody == nil, let waitingReceiver = self.receiver {
            self.receiver = nil
            receiver = waitingReceiver
        } else {
            heartbeatPending = true
            receiver = nil
        }
        lock.unlock()
        receiver?.resume(returning: .heartbeat)
    }

    func finishSource(_ result: Event) {
        let receiver: CheckedContinuation<Event, Never>?
        lock.lock()
        guard isClosed == false, terminal == nil else {
            lock.unlock()
            return
        }
        terminal = result
        heartbeatPending = false
        if pendingBody == nil, inFlightBody == nil {
            receiver = self.receiver
            self.receiver = nil
        } else {
            receiver = nil
        }
        lock.unlock()
        receiver?.resume(returning: result)
    }

    func close() {
        let acknowledgements: [CheckedContinuation<Bool, Never>]
        let receiver: CheckedContinuation<Event, Never>?
        lock.lock()
        guard isClosed == false else {
            lock.unlock()
            return
        }
        isClosed = true
        acknowledgements = [pendingBody?.acknowledgement, inFlightBody?.acknowledgement]
            .compactMap { $0 }
        pendingBody = nil
        inFlightBody = nil
        receiver = self.receiver
        self.receiver = nil
        lock.unlock()
        for acknowledgement in acknowledgements {
            acknowledgement.resume(returning: false)
        }
        receiver?.resume(returning: .cancelled)
    }

    func waitUntilBodyIsPendingForTesting() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if pendingBody != nil || inFlightBody != nil {
                lock.unlock()
                continuation.resume()
            } else {
                pendingBodyWaiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private final class MCPHTTPResponseBackpressureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var sourceReadCount = 0
    private var holdNextBodyWrite = false
    private var releaseWasRequested = false
    private var bodyWriteContinuation: CheckedContinuation<Void, Never>?
    private var bodyWriteWaiters: [CheckedContinuation<Void, Never>] = []

    func holdNextBodyWriteForTesting() {
        lock.lock()
        precondition(holdNextBodyWrite == false && bodyWriteContinuation == nil)
        sourceReadCount = 0
        holdNextBodyWrite = true
        releaseWasRequested = false
        lock.unlock()
    }

    func recordSourceRead() {
        lock.lock()
        sourceReadCount += 1
        lock.unlock()
    }

    func waitBeforeBodyWriteIfNeeded() async {
        await withCheckedContinuation { continuation in
            let waiters: [CheckedContinuation<Void, Never>]
            lock.lock()
            guard holdNextBodyWrite else {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters = bodyWriteWaiters
            bodyWriteWaiters.removeAll(keepingCapacity: false)
            if releaseWasRequested {
                resetLocked()
                lock.unlock()
                for waiter in waiters { waiter.resume() }
                continuation.resume()
                return
            }
            bodyWriteContinuation = continuation
            lock.unlock()
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilBodyWriteIsHeldForTesting() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if bodyWriteContinuation != nil {
                lock.unlock()
                continuation.resume()
            } else {
                bodyWriteWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func releaseBodyWriteForTesting() {
        let continuation: CheckedContinuation<Void, Never>?
        lock.lock()
        guard holdNextBodyWrite else {
            lock.unlock()
            return
        }
        if let held = bodyWriteContinuation {
            bodyWriteContinuation = nil
            continuation = held
            resetLocked()
        } else {
            releaseWasRequested = true
            continuation = nil
        }
        lock.unlock()
        continuation?.resume()
    }

    func sourceReadCountForTesting() -> Int {
        lock.lock()
        let count = sourceReadCount
        lock.unlock()
        return count
    }

    private func resetLocked() {
        holdNextBodyWrite = false
        releaseWasRequested = false
    }
}

private final class CodexReviewMCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private enum RequestBodyResult: Sendable {
        case body(Data?)
        case payloadTooLarge
        case expectationFailed
        case cancelled
    }

    private final class RequestBodyReceipt: @unchecked Sendable {
        private let maximumByteCount: Int
        private let lock = NSLock()
        private var body = Data()
        private var result: RequestBodyResult?
        private var waiter: CheckedContinuation<RequestBodyResult, Never>?

        init(maximumByteCount: Int) {
            self.maximumByteCount = maximumByteCount
        }

        func receive(_ buffer: ByteBuffer) -> Bool {
            let readableByteCount = buffer.readableBytes
            guard readableByteCount > 0 else {
                return false
            }

            lock.lock()
            guard result == nil else {
                lock.unlock()
                return false
            }
            guard readableByteCount <= maximumByteCount - body.count else {
                lock.unlock()
                return true
            }
            body.append(contentsOf: buffer.readableBytesView)
            lock.unlock()
            return false
        }

        func finish() {
            let outcome: RequestBodyResult
            lock.lock()
            guard result == nil else {
                lock.unlock()
                return
            }
            outcome = .body(body.isEmpty ? nil : body)
            result = outcome
            body.removeAll(keepingCapacity: false)
            let continuation = waiter
            waiter = nil
            lock.unlock()
            continuation?.resume(returning: outcome)
        }

        func reject(_ outcome: RequestBodyResult) {
            let continuation: CheckedContinuation<RequestBodyResult, Never>?
            lock.lock()
            guard result == nil else {
                lock.unlock()
                return
            }
            result = outcome
            body.removeAll(keepingCapacity: false)
            continuation = waiter
            waiter = nil
            lock.unlock()
            continuation?.resume(returning: outcome)
        }

        func waitForResult() async -> RequestBodyResult {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    if let result {
                        lock.unlock()
                        continuation.resume(returning: result)
                    } else {
                        precondition(
                            waiter == nil,
                            "One request operation owns the body receipt waiter."
                        )
                        waiter = continuation
                        lock.unlock()
                    }
                }
            } onCancel: {
                self.reject(.cancelled)
            }
        }
    }

    private enum RequestExpectation: Equatable {
        case none
        case continueRequest
        case unsupported
    }

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
        var bodyReceipt: RequestBodyReceipt
    }

    private let server: CodexReviewMCPHTTPServer
    private let connection: MCPHTTPNetworkResourceOwner.Connection
    private let maximumRequestBodyBytes: Int
    private let responseBackpressureProbe: MCPHTTPResponseBackpressureProbe
    private var requestState: RequestState?

    init(
        server: CodexReviewMCPHTTPServer,
        connection: MCPHTTPNetworkResourceOwner.Connection,
        maximumRequestBodyBytes: Int,
        responseBackpressureProbe: MCPHTTPResponseBackpressureProbe
    ) {
        self.server = server
        self.connection = connection
        self.maximumRequestBodyBytes = maximumRequestBodyBytes
        self.responseBackpressureProbe = responseBackpressureProbe
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            receiveRequestHead(head, context: context)
        case .body(let buffer):
            if requestState?.bodyReceipt.receive(buffer) == true {
                connection.closeAdmission()
                requestState?.bodyReceipt.reject(.payloadTooLarge)
            }
        case .end:
            let receipt = requestState?.bodyReceipt
            requestState = nil
            receipt?.finish()
        }
    }

    private func receiveRequestHead(
        _ head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        let expectation = requestExpectation(for: head)
        let contentLengthExceedsLimit = contentLengthExceedsLimit(head)
        let rejection: RequestBodyResult?
        if contentLengthExceedsLimit {
            rejection = .payloadTooLarge
        } else if expectation == .unsupported {
            rejection = .expectationFailed
        } else {
            rejection = nil
        }
        let shouldSendContinue = expectation == .continueRequest && rejection == nil
        let finalForConnection = head.isKeepAlive == false || rejection != nil
        guard let admittedRequest = connection.admitRequest(
            finalForConnection: finalForConnection
        ) else {
            context.close(promise: nil)
            return
        }

        let bodyReceipt = RequestBodyReceipt(maximumByteCount: maximumRequestBodyBytes)
        requestState = .init(bodyReceipt: bodyReceipt)
        nonisolated(unsafe) let context = context
        let task = Task { [self] in
            defer {
                bodyReceipt.reject(.cancelled)
                admittedRequest.lease.acknowledgeCompletion()
            }
            guard await admittedRequest.lease.waitUntilStartIsAllowed() else {
                return
            }
            guard admittedRequest.operation.beginResponse() else {
                return
            }
            if shouldSendContinue {
                do {
                    let responseHead = HTTPResponseHead(version: head.version, status: .continue)
                    try await writeResponsePart(
                        .head(responseHead),
                        context: context,
                        eventLoop: context.eventLoop
                    )
                } catch {
                    connection.transportFailed(error.localizedDescription)
                    return
                }
            }
            let bodyResult = await bodyReceipt.waitForResult()
            guard Task.isCancelled == false else {
                return
            }
            switch bodyResult {
            case .body(let body):
                await handleRequest(
                    head: head,
                    body: body,
                    operation: admittedRequest.operation,
                    context: context
                )
            case .payloadTooLarge:
                await writeRequestRejection(
                    status: .payloadTooLarge,
                    version: head.version,
                    operation: admittedRequest.operation,
                    context: context
                )
            case .expectationFailed:
                await writeRequestRejection(
                    status: .expectationFailed,
                    version: head.version,
                    operation: admittedRequest.operation,
                    context: context
                )
            case .cancelled:
                return
            }
        }
        admittedRequest.lease.install(task)

        if let rejection {
            bodyReceipt.reject(rejection)
        }
    }

    private func contentLengthExceedsLimit(_ head: HTTPRequestHead) -> Bool {
        guard let rawValue = head.headers.first(name: "content-length") else {
            return false
        }
        guard let contentLength = UInt64(rawValue) else {
            return true
        }
        return contentLength > UInt64(maximumRequestBodyBytes)
    }

    private func requestExpectation(for head: HTTPRequestHead) -> RequestExpectation {
        guard head.version.major == 1, head.version.minor >= 1 else {
            return .none
        }
        let values = head.headers[canonicalForm: "expect"]
        guard values.isEmpty == false else {
            return .none
        }
        guard values.count == 1,
              String(values[0]).caseInsensitiveCompare("100-continue") == .orderedSame
        else {
            return .unsupported
        }
        return .continueRequest
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
        context.read()
    }

    func channelInactive(context: ChannelHandlerContext) {
        requestState?.bodyReceipt.reject(.cancelled)
        requestState = nil
        connection.peerClosed()
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            requestState?.bodyReceipt.reject(.cancelled)
            requestState = nil
            connection.peerClosed()
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        requestState?.bodyReceipt.reject(.cancelled)
        requestState = nil
        connection.transportFailed(error.localizedDescription)
        context.close(promise: nil)
    }

    private func handleRequest(
        head: HTTPRequestHead,
        body: Data?,
        operation: MCPHTTPNetworkResourceOwner.RequestOperation,
        context: ChannelHandlerContext
    ) async {
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        let endpoint = await server.endpoint
        guard path == endpoint else {
            await writeResponse(
                .init(response: .error(statusCode: 404, .invalidRequest("Not Found"))),
                version: head.version,
                operation: operation,
                closeAfterResponse: head.isKeepAlive == false,
                context: context
            )
            return
        }

        let request = makeHTTPRequest(head: head, body: body)
        let response = await server.handleTrackedHTTPRequest(request, operation: operation)
        await writeResponse(
            response,
            version: head.version,
            operation: operation,
            closeAfterResponse: head.isKeepAlive == false,
            context: context
        )
    }

    private func makeHTTPRequest(head: HTTPRequestHead, body: Data?) -> HTTPRequest {
        var headers: [String: String] = [:]
        for (name, value) in head.headers {
            if let existing = headers[name] {
                headers[name] = "\(existing), \(value)"
            } else {
                headers[name] = value
            }
        }

        let path = String(head.uri.split(separator: "?").first ?? Substring(head.uri))
        return HTTPRequest(
            method: head.method.rawValue,
            headers: headers,
            body: body,
            path: path
        )
    }

    private func writeRequestRejection(
        status: HTTPResponseStatus,
        version: HTTPVersion,
        operation: MCPHTTPNetworkResourceOwner.RequestOperation,
        context: ChannelHandlerContext
    ) async {
        nonisolated(unsafe) let context = context
        let eventLoop = context.eventLoop
        var head = HTTPResponseHead(version: version, status: status)
        head.headers.add(name: "Content-Length", value: "0")
        head.headers.add(name: "Connection", value: "close")
        do {
            try await writeResponsePart(.head(head), context: context, eventLoop: eventLoop)
            try await writeResponsePart(.end(nil), context: context, eventLoop: eventLoop)
            operation.acknowledgeResponseEnd()
            await connection.closeAfterResponse()
        } catch {
            logger.error("MCP request rejection write failed: \(error.localizedDescription, privacy: .public)")
            connection.transportFailed(error.localizedDescription)
        }
    }

    private func writeResponse(
        _ trackedResponse: TrackedHTTPResponse,
        version: HTTPVersion,
        operation: MCPHTTPNetworkResourceOwner.RequestOperation,
        closeAfterResponse: Bool,
        context: ChannelHandlerContext
    ) async {
        nonisolated(unsafe) let context = context
        let eventLoop = context.eventLoop
        let response = trackedResponse.response
        let status = HTTPResponseStatus(statusCode: response.statusCode)
        let headers = response.headers
        var head = HTTPResponseHead(version: version, status: status)
        for (name, value) in headers {
            head.headers.add(name: name, value: value)
        }
        if closeAfterResponse {
            head.headers.replaceOrAdd(name: "Connection", value: "close")
        }

        let result: WriterCompletion
        switch response {
        case .stream:
            if let lifecycle = trackedResponse.streamLifecycle {
                result = await writeStreamingResponse(
                    lifecycle,
                    head: head,
                    context: context,
                    eventLoop: eventLoop
                )
            } else {
                result = .transportFailed("Streaming response has no source lifecycle.")
            }

        default:
            result = await writeNonStreamingResponse(
                response,
                head: head,
                context: context,
                eventLoop: eventLoop
            )
        }

        switch result {
        case .responded, .cancelled:
            break
        case .sourceFailed(let message):
            logger.error("MCP SSE source failed: \(message, privacy: .public)")
            connection.transportFailed(message)
        case .transportFailed(let message):
            logger.error("MCP HTTP response failed: \(message, privacy: .public)")
            connection.transportFailed(message)
        }
        await server.waitBeforeWriterFinalizationForTesting()
        if case .responded = result {
            operation.acknowledgeResponseEnd()
            if closeAfterResponse {
                await connection.closeAfterResponse()
            }
            await server.waitAfterResponseEndAcknowledgementForTesting()
        }
        await server.waitAfterWriterCompletionForTesting()
    }

    private enum WriterCompletion: Sendable {
        case responded
        case cancelled
        case sourceFailed(String)
        case transportFailed(String)
    }

    private enum ResponseChildCompletion: Sendable {
        case source
        case heartbeat
        case writer(WriterCompletion)
    }

    private func writeStreamingResponse(
        _ lifecycle: TrackedHTTPResponse.StreamLifecycle,
        head: HTTPResponseHead,
        context: ChannelHandlerContext,
        eventLoop: any EventLoop
    ) async -> WriterCompletion {
        nonisolated(unsafe) let context = context
        let events = MCPHTTPResponseEventChannel()
        let heartbeatInterval = await server.responseHeartbeatInterval
        return await withTaskCancellationHandler {
            await withTaskGroup(of: ResponseChildCompletion.self) { group in
                group.addTask { [self] in
                    do {
                        for try await chunk in lifecycle.source {
                            try Task.checkCancellation()
#if DEBUG
                            responseBackpressureProbe.recordSourceRead()
#endif
                            guard await events.sendBody(chunk) else { break }
                        }
                        if lifecycle.kind == .finite {
                            await server.waitAfterFiniteSourceCompletionForTesting()
                        }
                        events.finishSource(Task.isCancelled ? .cancelled : .sourceFinished)
                    } catch let error as CancellationError {
                        if Task.isCancelled {
                            events.finishSource(.cancelled)
                        } else {
                            events.finishSource(.sourceFailed(error.localizedDescription))
                        }
                    } catch {
                        events.finishSource(.sourceFailed(error.localizedDescription))
                    }
                    return .source
                }
                if let heartbeatInterval {
                    group.addTask {
                        while Task.isCancelled == false {
                            do {
                                try await Task.sleep(for: heartbeatInterval)
                            } catch {
                                return .heartbeat
                            }
                            events.offerHeartbeat()
                        }
                        return .heartbeat
                    }
                }
                group.addTask { [self] in
                    .writer(await consumeResponseEvents(
                        events,
                        head: head,
                        context: context,
                        eventLoop: eventLoop
                    ))
                }

                var result = WriterCompletion.cancelled
                while let completion = await group.next() {
                    if case .writer(let writerResult) = completion {
                        result = writerResult
                        events.close()
                        group.cancelAll()
                        break
                    }
                }
                await group.waitForAll()
                return result
            }
        } onCancel: {
            events.close()
        }
    }

    private func consumeResponseEvents(
        _ events: MCPHTTPResponseEventChannel,
        head: HTTPResponseHead,
        context: ChannelHandlerContext,
        eventLoop: any EventLoop
    ) async -> WriterCompletion {
        do {
            try Task.checkCancellation()
            try await writeResponsePart(.head(head), context: context, eventLoop: eventLoop)
            while true {
                switch await events.receive() {
                case .body(let id, let data):
                    do {
#if DEBUG
                        await responseBackpressureProbe.waitBeforeBodyWriteIfNeeded()
#endif
                        try await writeResponseBody(data, context: context, eventLoop: eventLoop)
                        events.acknowledgeBody(id: id, wasWritten: true)
                    } catch {
                        events.acknowledgeBody(id: id, wasWritten: false)
                        return .transportFailed(error.localizedDescription)
                    }
                case .heartbeat:
                    try await writeResponseBody(
                        Data(": keep-alive\n\n".utf8),
                        context: context,
                        eventLoop: eventLoop
                    )
                case .sourceFinished:
                    await server.waitBeforeResponseEndWriteForTesting()
                    try Task.checkCancellation()
                    try await writeResponsePart(.end(nil), context: context, eventLoop: eventLoop)
                    return .responded
                case .sourceFailed(let message):
                    return .sourceFailed(message)
                case .cancelled:
                    return .cancelled
                }
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .transportFailed(error.localizedDescription)
        }
    }

    private func writeNonStreamingResponse(
        _ response: HTTPResponse,
        head: HTTPResponseHead,
        context: ChannelHandlerContext,
        eventLoop: any EventLoop
    ) async -> WriterCompletion {
        var head = head
        let body = response.bodyData
        if let body {
            head.headers.add(name: "Content-Length", value: "\(body.count)")
        }
        do {
            try Task.checkCancellation()
            try await writeResponsePart(.head(head), context: context, eventLoop: eventLoop)
            if let body {
                try await writeResponseBody(body, context: context, eventLoop: eventLoop)
            }
            await server.waitBeforeResponseEndWriteForTesting()
            try Task.checkCancellation()
            try await writeResponsePart(.end(nil), context: context, eventLoop: eventLoop)
            return .responded
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .transportFailed(error.localizedDescription)
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
