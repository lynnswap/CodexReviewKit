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
    var responseSourceKind: MCPHTTPNetworkResourceOwner.ResponseSourceKind? = nil
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
    private let finiteSourceCompletionGate = MCPHTTPLifecycleCompletionGate()
    private let writerCompletionGate = MCPHTTPLifecycleCompletionGate()
    private let responseEndAcknowledgementGate = MCPHTTPLifecycleCompletionGate()
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
        let responseBackpressureProbe = responseBackpressureProbe
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
                        responseBackpressureProbe: responseBackpressureProbe,
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

    package func eventLoopGroupShutdownCountForTesting() -> Int {
        eventLoopGroupShutdownCount
    }

    package func networkSnapshotForTesting() -> MCPHTTPNetworkResourceOwner.Snapshot {
        if let networkResources = currentNetworkResources() {
            return networkResources.snapshot()
        }
        return .init(
            revision: 0,
            generationID: nextGenerationID,
            phase: .closed,
            connections: []
        )
    }

    package func nextNetworkSnapshotForTesting(
        after revision: UInt64
    ) async -> MCPHTTPNetworkResourceOwner.Snapshot {
        guard let networkResources = currentNetworkResources() else {
            return networkSnapshotForTesting()
        }
        return await networkResources.nextSnapshot(after: revision)
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

    fileprivate var responseHeartbeatInterval: Duration? {
        configuration.streamHeartbeatInterval
    }

    fileprivate func waitAfterFiniteSourceCompletionForTesting() async {
        await finiteSourceCompletionGate.waitIfNeeded()
    }

    fileprivate func waitAfterWriterCompletionForTesting() async {
        await writerCompletionGate.waitIfNeeded()
    }

    fileprivate func waitAfterResponseEndAcknowledgementForTesting() async {
        await responseEndAcknowledgementGate.waitIfNeeded()
    }

    private func currentNetworkResources() -> MCPHTTPNetworkResourceOwner? {
        switch lifecycleState {
        case .starting(let operation):
            operation.networkResources
        case .running(let resources), .stopping(_, let resources?, _):
            resources.networkResources
        case .stopped, .stopping:
            nil
        }
    }

    package func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        directResponse(from: await handleTrackedHTTPRequest(request))
    }

    private func directResponse(from trackedResponse: TrackedHTTPResponse) -> HTTPResponse {
        guard case .stream(let source, let headers) = trackedResponse.response,
              let completion = trackedResponse.streamCompletion else {
            return trackedResponse.response
        }
        let heartbeatInterval = configuration.streamHeartbeatInterval
        let stream = AsyncThrowingStream<Data, Swift.Error>(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        do {
                            for try await chunk in source {
                                try Task.checkCancellation()
                                continuation.yield(chunk)
                            }
                            await completion.finishAndWait()
                            continuation.finish()
                        } catch is CancellationError {
                            await completion.finishAndWait()
                            continuation.finish()
                        } catch {
                            await completion.finishAndWait()
                            continuation.finish(throwing: error)
                        }
                    }
                    if let heartbeatInterval {
                        group.addTask {
                            while Task.isCancelled == false {
                                do {
                                    try await Task.sleep(for: heartbeatInterval)
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
                    _ = await group.next()
                    group.cancelAll()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                completion.finish()
            }
        }
        return .stream(stream, headers: headers)
    }

    fileprivate func handleTrackedHTTPRequest(_ request: HTTPRequest) async -> TrackedHTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            session.activeRequestCount += 1
            sessions[sessionID] = session
            let response = await session.transport.handleRequest(request)
            let (trackedResponse, didFinishRequest) = trackActiveRequest(
                response,
                sessionID: sessionID,
                responseSourceKind: Self.responseSourceKind(for: request)
            )
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
            let (trackedResponse, didFinishRequest) = trackActiveRequest(
                response,
                sessionID: sessionID,
                responseSourceKind: Self.responseSourceKind(for: request)
            )
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
        sessionID: String,
        responseSourceKind: MCPHTTPNetworkResourceOwner.ResponseSourceKind
    ) -> (response: TrackedHTTPResponse, didFinishRequest: Bool) {
        switch response {
        case .stream:
            let completion = ActiveRequestCompletion {
                await self.finishActiveRequest(sessionID: sessionID)
            }
            return (
                .init(
                    response: response,
                    streamCompletion: completion,
                    responseSourceKind: responseSourceKind
                ),
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

    private static func responseSourceKind(
        for request: HTTPRequest
    ) -> MCPHTTPNetworkResourceOwner.ResponseSourceKind {
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

private final class ActiveRequestCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let onFinish: @Sendable () async -> Void
    private var didFinish = false

    init(onFinish: @escaping @Sendable () async -> Void) {
        self.onFinish = onFinish
    }

    func finish() {
        guard claim() else {
            return
        }
        Task {
            await onFinish()
        }
    }

    func finishAndWait() async {
        guard claim() else {
            return
        }
        await onFinish()
    }

    private func claim() -> Bool {
        lock.lock()
        if didFinish {
            lock.unlock()
            return false
        }
        didFinish = true
        lock.unlock()
        return true
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
    private var isClosed = false

    func sendBody(_ data: Data) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { acknowledgement in
            var receiver: CheckedContinuation<Event, Never>?
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
            let body = PendingBody(
                id: id,
                data: data,
                acknowledgement: acknowledgement
            )
            if let waitingReceiver = self.receiver {
                self.receiver = nil
                inFlightBody = body
                receiver = waitingReceiver
            } else {
                pendingBody = body
            }
            lock.unlock()
            receiver?.resume(returning: .body(id: id, data: data))
        }
    }

    func receive() async -> Event {
        await withCheckedContinuation { continuation in
            let immediate: Event?
            lock.lock()
            if isClosed {
                immediate = .cancelled
            } else if let terminal {
                immediate = terminal
            } else if heartbeatPending {
                heartbeatPending = false
                immediate = .heartbeat
            } else if let pendingBody {
                self.pendingBody = nil
                inFlightBody = pendingBody
                immediate = .body(id: pendingBody.id, data: pendingBody.data)
            } else {
                precondition(receiver == nil, "One response writer owns the channel receiver.")
                receiver = continuation
                immediate = nil
            }
            lock.unlock()
            if let immediate {
                continuation.resume(returning: immediate)
            }
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
        var receiver: CheckedContinuation<Event, Never>?
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
        }
        lock.unlock()
        receiver?.resume(returning: .heartbeat)
    }

    func finishSource(_ result: Event) {
        precondition({
            switch result {
            case .sourceFinished, .sourceFailed, .cancelled:
                true
            case .body, .heartbeat:
                false
            }
        }())
        var receiver: CheckedContinuation<Event, Never>?
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

private final class MCPHTTPRequestBodyReceipt<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case waiting
        case suspended(CheckedContinuation<Value?, Never>)
        case completed(Value?)
    }

    private let lock = NSLock()
    private var state: State = .waiting

    func wait() async -> Value? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                switch state {
                case .waiting:
                    state = .suspended(continuation)
                    lock.unlock()
                case .completed(let value):
                    lock.unlock()
                    continuation.resume(returning: value)
                case .suspended:
                    lock.unlock()
                    preconditionFailure("One request handler owns the body receipt.")
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func complete(_ value: Value) {
        finish(value)
    }

    func cancel() {
        finish(nil)
    }

    private func finish(_ value: Value?) {
        let continuation: CheckedContinuation<Value?, Never>?
        lock.lock()
        switch state {
        case .waiting:
            state = .completed(value)
            continuation = nil
        case .suspended(let suspended):
            state = .completed(value)
            continuation = suspended
        case .completed:
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: value)
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

    private struct CompletedRequestState: @unchecked Sendable {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }

    private struct RequestState {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
        let bodyReceipt: MCPHTTPRequestBodyReceipt<CompletedRequestState>
    }

    private let server: CodexReviewMCPHTTPServer
    private let responseBackpressureProbe: MCPHTTPResponseBackpressureProbe
    private let connection: MCPHTTPNetworkResourceOwner.Connection
    private var requestState: RequestState?

    init(
        server: CodexReviewMCPHTTPServer,
        responseBackpressureProbe: MCPHTTPResponseBackpressureProbe,
        connection: MCPHTTPNetworkResourceOwner.Connection
    ) {
        self.server = server
        self.responseBackpressureProbe = responseBackpressureProbe
        self.connection = connection
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            precondition(requestState == nil, "HTTP decoding serializes request bodies on one connection.")
            let sendsContinue: Bool
            if let expectation = head.headers.first(name: "Expect") {
                let isContinue = expectation.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("100-continue") == .orderedSame
                guard isContinue else {
                    admitUnsupportedExpectation(
                        expectation,
                        version: head.version,
                        context: context
                    )
                    return
                }
                if head.version.major == 1, head.version.minor == 0 {
                    sendsContinue = false
                } else if head.version.major == 1, head.version.minor >= 1 {
                    sendsContinue = true
                } else {
                    admitUnsupportedExpectation(
                        expectation,
                        version: head.version,
                        context: context
                    )
                    return
                }
            } else {
                sendsContinue = false
            }
            guard let admittedRequest = connection.admitRequest() else {
                context.close(promise: nil)
                return
            }
            let bodyReceipt = MCPHTTPRequestBodyReceipt<CompletedRequestState>()
            requestState = RequestState(
                head: head,
                bodyBuffer: context.channel.allocator.buffer(capacity: 0),
                bodyReceipt: bodyReceipt
            )
            startRequestHandler(
                admittedRequest,
                bodyReceipt: bodyReceipt,
                sendsContinue: sendsContinue,
                version: head.version,
                context: context
            )
        case .body(var buffer):
            requestState?.bodyBuffer.writeBuffer(&buffer)
        case .end:
            guard let state = requestState else {
                return
            }
            requestState = nil
            state.bodyReceipt.complete(.init(
                head: state.head,
                bodyBuffer: state.bodyBuffer
            ))
        }
    }

    private func startRequestHandler(
        _ admittedRequest: MCPHTTPNetworkResourceOwner.Connection.AdmittedRequest,
        bodyReceipt: MCPHTTPRequestBodyReceipt<CompletedRequestState>,
        sendsContinue: Bool,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) {
        nonisolated(unsafe) let context = context
        let task = Task { [self] in
            defer { admittedRequest.lease.acknowledgeCompletion() }
            guard await admittedRequest.lease.waitUntilStartIsAllowed() else {
                bodyReceipt.cancel()
                return
            }
            if sendsContinue {
                guard await connection.supplyExpectation(for: admittedRequest.operation),
                      await writeContinue(version: version, context: context) else {
                    bodyReceipt.cancel()
                    return
                }
            }
            guard let state = await bodyReceipt.wait(), Task.isCancelled == false else {
                return
            }
            await handleRequest(
                state: state,
                operation: admittedRequest.operation,
                context: context
            )
        }
        admittedRequest.lease.install(task)
    }

    private func writeContinue(
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) async -> Bool {
        do {
            try await writeResponsePart(
                .head(.init(version: version, status: .continue)),
                context: context,
                eventLoop: context.eventLoop
            )
            return true
        } catch {
            connection.transportFailed(error.localizedDescription)
            return false
        }
    }

    private func admitUnsupportedExpectation(
        _ expectation: String,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) {
        guard let admittedRequest = connection.admitRequest() else {
            context.close(promise: nil)
            return
        }
        nonisolated(unsafe) let context = context
        let task = Task { [self] in
            defer { admittedRequest.lease.acknowledgeCompletion() }
            guard await admittedRequest.lease.waitUntilStartIsAllowed() else { return }
            await prepareAndQueueResponse(
                .init(response: .error(
                    statusCode: Int(HTTPResponseStatus.expectationFailed.code),
                    .invalidRequest("Unsupported HTTP expectation: \(expectation)")
                )),
                operation: admittedRequest.operation,
                version: version,
                closeAfterResponse: true,
                context: context
            )
        }
        admittedRequest.lease.install(task)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
        context.read()
    }

    func channelInactive(context: ChannelHandlerContext) {
        requestState?.bodyReceipt.cancel()
        requestState = nil
        connection.peerClosed()
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            requestState?.bodyReceipt.cancel()
            requestState = nil
            connection.peerClosed()
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        requestState?.bodyReceipt.cancel()
        requestState = nil
        connection.transportFailed(error.localizedDescription)
        context.close(promise: nil)
    }

    private func handleRequest(
        state: CompletedRequestState,
        operation: MCPHTTPNetworkResourceOwner.RequestOperation,
        context: ChannelHandlerContext
    ) async {
        let head = state.head
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        let endpoint = await server.endpoint
        guard path == endpoint else {
            await prepareAndQueueResponse(
                .init(response: .error(statusCode: 404, .invalidRequest("Not Found"))),
                operation: operation,
                version: head.version,
                closeAfterResponse: head.isKeepAlive == false,
                context: context
            )
            return
        }

        let request = makeHTTPRequest(from: state)
        let response = await server.handleTrackedHTTPRequest(request)
        await prepareAndQueueResponse(
            response,
            operation: operation,
            version: head.version,
            closeAfterResponse: head.isKeepAlive == false,
            context: context
        )
    }

    private func makeHTTPRequest(from state: CompletedRequestState) -> HTTPRequest {
        var headers: [String: String] = [:]
        for (name, value) in state.head.headers {
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

        let path = String(state.head.uri.split(separator: "?").first ?? Substring(state.head.uri))
        return HTTPRequest(
            method: state.head.method.rawValue,
            headers: headers,
            body: body,
            path: path
        )
    }

    private func prepareAndQueueResponse(
        _ trackedResponse: TrackedHTTPResponse,
        operation: MCPHTTPNetworkResourceOwner.RequestOperation,
        version: HTTPVersion,
        closeAfterResponse: Bool,
        context: ChannelHandlerContext
    ) async {
        let response = trackedResponse.response

        switch response {
        case .stream:
            guard let kind = trackedResponse.responseSourceKind else {
                await trackedResponse.streamCompletion?.finishAndWait()
                connection.transportFailed("Streaming response has no source lifetime contract.")
                return
            }
            guard operation.declareResponseSource(kind) else {
                await trackedResponse.streamCompletion?.finishAndWait()
                return
            }

        default:
            guard operation.markResponseSourceNotRequired() else {
                return
            }
        }

        guard await connection.supplyResponse(for: operation) else {
            await trackedResponse.streamCompletion?.finishAndWait()
            return
        }
        guard let writerLease = operation.reserveWriter() else {
            await trackedResponse.streamCompletion?.finishAndWait()
            return
        }

        let preparedResponse: HTTPResponse
        let responseEvents: MCPHTTPResponseEventChannel?
        var admittedSource: (lease: MCPHTTPNetworkResourceOwner.WorkLease, task: Task<Void, Never>)?
        switch response {
        case .stream(let source, _):
            guard let kind = trackedResponse.responseSourceKind,
                  let sourceLease = operation.reserveResponseSource() else {
                await trackedResponse.streamCompletion?.finishAndWait()
                writerLease.acknowledgeCompletion()
                return
            }
            let events = MCPHTTPResponseEventChannel()
            let sourceTask = Task {
                let started = await sourceLease.waitUntilStartIsAllowed()
                if started {
                    do {
                        for try await chunk in source {
                            try Task.checkCancellation()
#if DEBUG
                            self.responseBackpressureProbe.recordSourceRead()
#endif
                            guard await events.sendBody(chunk) else {
                                break
                            }
                        }
                        if kind == .finite {
                            await self.server.waitAfterFiniteSourceCompletionForTesting()
                        }
                        events.finishSource(.sourceFinished)
                    } catch is CancellationError {
                        events.finishSource(.cancelled)
                    } catch {
                        events.finishSource(.sourceFailed(error.localizedDescription))
                        self.connection.transportFailed(error.localizedDescription)
                    }
                } else {
                    events.finishSource(.cancelled)
                }
                await trackedResponse.streamCompletion?.finishAndWait()
                sourceLease.acknowledgeCompletion()
            }
            admittedSource = (sourceLease, sourceTask)
            preparedResponse = response
            responseEvents = events

        default:
            admittedSource = nil
            preparedResponse = response
            responseEvents = nil
        }

        nonisolated(unsafe) let context = context
        let heartbeatInterval = await server.responseHeartbeatInterval
        let writerTask = Task {
            let result: WriterCompletion? = await withTaskCancellationHandler {
                guard await writerLease.waitUntilStartIsAllowed() else {
                    return nil
                }
                return await self.writeResponse(
                    preparedResponse,
                    responseEvents: responseEvents,
                    version: version,
                    context: context,
                    heartbeatInterval: heartbeatInterval
                )
            } onCancel: {
                responseEvents?.close()
            }
            guard let result else {
                writerLease.acknowledgeCompletion()
                return
            }
            switch result {
            case .responded:
                operation.acknowledgeResponseEnd()
                if closeAfterResponse {
                    self.connection.closeAfterResponse()
                }
                await self.server.waitAfterResponseEndAcknowledgementForTesting()
            case .cancelled:
                break
            case .sourceFailed(let message):
                logger.error("MCP SSE source failed: \(message, privacy: .public)")
                self.connection.transportFailed(message)
            case .transportFailed(let message):
                logger.error("MCP HTTP response failed: \(message, privacy: .public)")
                self.connection.transportFailed(message)
            }
            await self.server.waitAfterWriterCompletionForTesting()
            writerLease.acknowledgeCompletion()
        }
        writerLease.install(writerTask)
        if let admittedSource {
            admittedSource.lease.install(admittedSource.task)
        }
    }

    private enum WriterCompletion {
        case responded
        case cancelled
        case sourceFailed(String)
        case transportFailed(String)
    }

    private func writeResponse(
        _ response: HTTPResponse,
        responseEvents: MCPHTTPResponseEventChannel?,
        version: HTTPVersion,
        context: ChannelHandlerContext,
        heartbeatInterval: Duration?
    ) async -> WriterCompletion {
        let eventLoop = context.eventLoop
        let status = HTTPResponseStatus(statusCode: response.statusCode)
        let headers = response.headers
        var head = HTTPResponseHead(version: version, status: status)
        for (name, value) in headers {
            head.headers.add(name: name, value: value)
        }

        switch response {
        case .stream:
            guard let responseEvents else {
                return .transportFailed("Streaming response has no bounded event channel.")
            }
            defer { responseEvents.close() }
            do {
                try Task.checkCancellation()
                try await writeResponsePart(.head(head), context: context, eventLoop: eventLoop)
                let sourceResult = await withTaskGroup(
                    of: Void.self,
                    returning: WriterCompletion.self
                ) { group in
                    if let heartbeatInterval {
                        group.addTask {
                            while Task.isCancelled == false {
                                do {
                                    try await Task.sleep(for: heartbeatInterval)
                                } catch {
                                    return
                                }
                                guard Task.isCancelled == false else {
                                    return
                                }
                                responseEvents.offerHeartbeat()
                            }
                        }
                    }

                    var result: WriterCompletion = .cancelled
                    eventLoopLoop: while true {
                        let event = await responseEvents.receive()
                        if Task.isCancelled {
                            result = .cancelled
                            break eventLoopLoop
                        }
                        switch event {
                        case .body(let id, let data):
                            do {
                                try await writeResponseBody(
                                    data,
                                    context: context,
                                    eventLoop: eventLoop
                                )
                                responseEvents.acknowledgeBody(id: id, wasWritten: true)
                            } catch {
                                responseEvents.acknowledgeBody(id: id, wasWritten: false)
                                result = .transportFailed(error.localizedDescription)
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
                                result = .transportFailed(error.localizedDescription)
                                break eventLoopLoop
                            }
                        case .sourceFinished:
                            result = .responded
                            break eventLoopLoop
                        case .sourceFailed(let message):
                            result = .sourceFailed(message)
                            break eventLoopLoop
                        case .cancelled:
                            result = .cancelled
                            break eventLoopLoop
                        }
                    }
                    group.cancelAll()
                    return result
                }
                switch sourceResult {
                case .responded:
                    try Task.checkCancellation()
                    try await writeResponsePart(.end(nil), context: context, eventLoop: eventLoop)
                    return .responded
                case .cancelled, .sourceFailed(_), .transportFailed(_):
                    return sourceResult
                }
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .transportFailed(error.localizedDescription)
            }

        default:
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
                try Task.checkCancellation()
                try await writeResponsePart(.end(nil), context: context, eventLoop: eventLoop)
                return .responded
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .transportFailed(error.localizedDescription)
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
#if DEBUG
        await responseBackpressureProbe.waitBeforeBodyWriteIfNeeded()
#endif
        let writer = ResponsePartWriter(handler: self, context: context)
        let promise = eventLoop.makePromise(of: Void.self)
        eventLoop.execute {
            writer.writeBody(data, promise: promise)
        }
        try await promise.futureResult.get()
    }
}
