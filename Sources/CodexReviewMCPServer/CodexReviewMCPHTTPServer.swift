import Darwin
import Foundation
import MCP
import OSLog
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

private let logger = Logger(subsystem: "CodexReviewKit", category: "mcp-http")

private struct TrackedHTTPResponse {
    var response: HTTPResponse
    var streamCompletion: ActiveRequestCompletion? = nil
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

    private struct SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
        let createdAt: Date
        var lastAccessedAt: Date
        var activeRequestCount: Int
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
    private var sessions: [String: SessionContext] = [:]
    private let startCompletionGate = MCPHTTPLifecycleCompletionGate()
    private let joinedStartCompletionGate = MCPHTTPLifecycleCompletionGate()
    private let stopCompletionGate = MCPHTTPLifecycleCompletionGate()
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
                        maximumRequestBodyBytes: maximumRequestBodyBytes
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

    package func eventLoopGroupShutdownCountForTesting() -> Int {
        eventLoopGroupShutdownCount
    }

    package func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        await handleTrackedHTTPRequest(request).response
    }

    fileprivate func handleTrackedHTTPRequest(_ request: HTTPRequest) async -> TrackedHTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            session.activeRequestCount += 1
            sessions[sessionID] = session
            let response = await session.transport.handleRequest(request)
            let (trackedResponse, didFinishRequest) = trackActiveRequest(response, sessionID: sessionID)
            if didFinishRequest, request.method.uppercased() == "DELETE", trackedResponse.response.statusCode == 200 {
                await closeSession(sessionID)
            }
            return trackedResponse
        }

        if request.method.uppercased() == "POST",
           let body = request.body,
           Self.isInitializeRequest(body)
        {
            return await createSessionAndHandle(request)
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

    private func createSessionAndHandle(_ request: HTTPRequest) async -> TrackedHTTPResponse {
        let sessionID = UUID().uuidString
        let clientSession = MCPClientSessionState()
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            validationPipeline: makeValidationPipeline(),
            retryInterval: configuration.retryInterval
        )

        do {
            let server = await makeMCPProtocolServer(
                adapter: adapter,
                defaultSessionID: sessionID,
                clientSession: clientSession,
                boundedReviewWaitDuration: configuration.boundedReviewWaitDuration
            )
            try await server.start(transport: transport) { clientInfo, _ in
                await clientSession.update(clientInfo: clientInfo)
            }
            sessions[sessionID] = SessionContext(
                server: server,
                transport: transport,
                createdAt: Date(),
                lastAccessedAt: Date(),
                activeRequestCount: 1
            )

            let response = await transport.handleRequest(request)
            let (trackedResponse, didFinishRequest) = trackActiveRequest(response, sessionID: sessionID)
            if didFinishRequest, case .error = trackedResponse.response {
                sessions.removeValue(forKey: sessionID)
                await transport.disconnect()
            }
            return trackedResponse
        } catch {
            await transport.disconnect()
            return .init(
                response: .error(
                    statusCode: 500,
                    .internalError("Failed to create MCP session: \(error.localizedDescription)")
                )
            )
        }
    }

    private func closeSession(_ sessionID: String) async {
        guard let session = sessions.removeValue(forKey: sessionID) else {
            return
        }
        await session.transport.disconnect()
        await adapter.closeSession(sessionID)
        logger.info("Closed MCP HTTP session \(sessionID, privacy: .public)")
    }

    private func trackActiveRequest(
        _ response: HTTPResponse,
        sessionID: String
    ) -> (response: TrackedHTTPResponse, didFinishRequest: Bool) {
        switch response {
        case .stream(let stream, let headers):
            let completion = ActiveRequestCompletion {
                Task {
                    await self.finishActiveRequest(sessionID: sessionID)
                }
            }
            let trackedStream = AsyncThrowingStream<Data, Swift.Error>(bufferingPolicy: .unbounded) { continuation in
                let heartbeatTask = makeStreamHeartbeatTask(continuation: continuation)
                let task = Task {
                    defer {
                        heartbeatTask?.cancel()
                        completion.finish()
                    }
                    do {
                        for try await chunk in stream {
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in
                    heartbeatTask?.cancel()
                    task.cancel()
                    completion.finish()
                }
            }
            return (
                .init(response: .stream(trackedStream, headers: headers), streamCompletion: completion),
                false
            )

        default:
            finishActiveRequest(sessionID: sessionID)
            return (.init(response: response), true)
        }
    }

    private func finishActiveRequest(sessionID: String) {
        if var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            session.activeRequestCount = max(0, session.activeRequestCount - 1)
            sessions[sessionID] = session
        }
    }

    private func makeStreamHeartbeatTask(
        continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    ) -> Task<Void, Never>? {
        guard let interval = configuration.streamHeartbeatInterval else {
            return nil
        }
        return Task {
            while Task.isCancelled == false {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard Task.isCancelled == false else {
                    return
                }
                continuation.yield(Data(": keep-alive\n\n".utf8))
            }
        }
    }

    private func closeAllSessions() async {
        for sessionID in sessions.keys {
            await closeSession(sessionID)
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
        sessions[sessionID]?.activeRequestCount
    }

    private func closeExpiredSessions(now: Date) async {
        var expiredSessionIDs: [String] = []
        for (sessionID, context) in sessions {
            guard now.timeIntervalSince(context.lastAccessedAt) > configuration.sessionTimeout else {
                continue
            }
            if context.activeRequestCount > 0 {
                continue
            }
            if await adapter.hasActiveReviews(in: sessionID) {
                if var session = sessions[sessionID] {
                    session.lastAccessedAt = Date()
                    sessions[sessionID] = session
                }
                continue
            }
            if let current = sessions[sessionID],
               current.activeRequestCount == 0,
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

private final class ActiveRequestCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let onFinish: @Sendable () -> Void
    private var didFinish = false

    init(onFinish: @escaping @Sendable () -> Void) {
        self.onFinish = onFinish
    }

    func finish() {
        lock.lock()
        if didFinish {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()
        onFinish()
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
    private var requestState: RequestState?
    private var activeStreamTask: Task<Void, Never>?
    private var activeStreamID: UUID?
    private var activeStreamCompletion: ActiveRequestCompletion?

    init(
        server: CodexReviewMCPHTTPServer,
        connection: MCPHTTPNetworkResourceOwner.Connection,
        maximumRequestBodyBytes: Int
    ) {
        self.server = server
        self.connection = connection
        self.maximumRequestBodyBytes = maximumRequestBodyBytes
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
                await handleRequest(head: head, body: body, context: context)
            case .payloadTooLarge:
                await writeRequestRejection(
                    status: .payloadTooLarge,
                    version: head.version,
                    context: context
                )
            case .expectationFailed:
                await writeRequestRejection(
                    status: .expectationFailed,
                    version: head.version,
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
        finishActiveStream()
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            requestState?.bodyReceipt.reject(.cancelled)
            requestState = nil
            connection.peerClosed()
            finishActiveStream()
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        requestState?.bodyReceipt.reject(.cancelled)
        requestState = nil
        connection.transportFailed(error.localizedDescription)
        finishActiveStream()
        context.close(promise: nil)
    }

    private func finishActiveStream() {
        activeStreamTask?.cancel()
        activeStreamCompletion?.finish()
        activeStreamTask = nil
        activeStreamID = nil
        activeStreamCompletion = nil
    }

    private func handleRequest(
        head: HTTPRequestHead,
        body: Data?,
        context: ChannelHandlerContext
    ) async {
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        let endpoint = await server.endpoint
        guard path == endpoint else {
            await writeResponse(
                .init(response: .error(statusCode: 404, .invalidRequest("Not Found"))),
                version: head.version,
                context: context
            )
            return
        }

        let request = makeHTTPRequest(head: head, body: body)
        let response = await server.handleTrackedHTTPRequest(request)
        await writeResponse(response, version: head.version, context: context)
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
        } catch {
            logger.error("MCP request rejection write failed: \(error.localizedDescription, privacy: .public)")
        }
        eventLoop.execute {
            context.close(promise: nil)
        }
    }

    private func writeResponse(
        _ trackedResponse: TrackedHTTPResponse,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) async {
        nonisolated(unsafe) let context = context
        let eventLoop = context.eventLoop
        let response = trackedResponse.response
        let status = HTTPResponseStatus(statusCode: response.statusCode)
        let headers = response.headers

        switch response {
        case .stream(let stream, _):
            let streamID = UUID()
            let streamTask = Task {
                var head = HTTPResponseHead(version: version, status: status)
                for (name, value) in headers {
                    head.headers.add(name: name, value: value)
                }

                var iterator = stream.makeAsyncIterator()
                do {
                    try Task.checkCancellation()
                    try await writeResponsePart(.head(head), context: context, eventLoop: eventLoop)
                    while let chunk = try await iterator.next() {
                        try Task.checkCancellation()
                        try await writeResponseBody(chunk, context: context, eventLoop: eventLoop)
                    }
                } catch is CancellationError {
                    trackedResponse.streamCompletion?.finish()
                    return
                } catch {
                    trackedResponse.streamCompletion?.finish()
                    logger.error("MCP SSE stream failed: \(error.localizedDescription, privacy: .public)")
                }

                guard Task.isCancelled == false else {
                    return
                }
                try? await writeResponsePart(.end(nil), context: context, eventLoop: eventLoop)
            }
            eventLoop.execute {
                context.channel.closeFuture.whenComplete { _ in
                    trackedResponse.streamCompletion?.finish()
                    streamTask.cancel()
                }
                guard context.channel.isActive else {
                    trackedResponse.streamCompletion?.finish()
                    streamTask.cancel()
                    return
                }
                self.activeStreamTask?.cancel()
                self.activeStreamCompletion?.finish()
                self.activeStreamTask = streamTask
                self.activeStreamID = streamID
                self.activeStreamCompletion = trackedResponse.streamCompletion
                context.read()
            }
            await streamTask.value
            eventLoop.execute {
                if self.activeStreamID == streamID {
                    self.activeStreamTask = nil
                    self.activeStreamID = nil
                    self.activeStreamCompletion = nil
                }
            }

        default:
            let body = response.bodyData
            eventLoop.execute {
                var head = HTTPResponseHead(version: version, status: status)
                for (name, value) in headers {
                    head.headers.add(name: name, value: value)
                }
                if let body {
                    head.headers.add(name: "Content-Length", value: "\(body.count)")
                }
                context.write(self.wrapOutboundOut(.head(head)), promise: nil)
                if let body {
                    var buffer = context.channel.allocator.buffer(capacity: body.count)
                    buffer.writeBytes(body)
                    context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                }
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
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
