import Darwin
import Foundation
import MCP
import OSLog
import CodexReview
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

private let logger = Logger(subsystem: "CodexReviewKit", category: "mcp-http")

private struct TrackedHTTPResponse {
    var response: HTTPResponse
    var streamCompletion: ActiveRequestCompletion? = nil
    var isFiniteResponseStream = false
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

private final class MCPHTTPAdmissionRegistry: @unchecked Sendable {
    struct Admission: Sendable {
        fileprivate let id: UUID
    }

    private struct AdmissionCountWaiter {
        let targetCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var acceptsRequests = false
    private var admittedRequestIDs: Set<UUID> = []
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var totalAdmissionCount = 0
    private var admissionCountWaiters: [UUID: AdmissionCountWaiter] = [:]

    func open() {
        lock.lock()
        precondition(
            admittedRequestIDs.isEmpty,
            "MCPHTTPAdmissionRegistry must drain one listener generation before reopening."
        )
        acceptsRequests = true
        lock.unlock()
    }

    func close() {
        lock.lock()
        acceptsRequests = false
        lock.unlock()
    }

    func admit() -> Admission? {
        let waiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        guard acceptsRequests else {
            lock.unlock()
            return nil
        }
        let admission = Admission(id: UUID())
        admittedRequestIDs.insert(admission.id)
        totalAdmissionCount += 1
        let completedWaiterIDs = admissionCountWaiters.compactMap { id, waiter in
            totalAdmissionCount >= waiter.targetCount ? id : nil
        }
        waiters = completedWaiterIDs.compactMap {
            admissionCountWaiters.removeValue(forKey: $0)?.continuation
        }
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
        return admission
    }

    func finish(_ admission: Admission) {
        let waiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        precondition(
            admittedRequestIDs.remove(admission.id) != nil,
            "MCPHTTPAdmissionRegistry owns exactly one completion per admitted request."
        )
        if admittedRequestIDs.isEmpty {
            waiters = drainWaiters
            drainWaiters.removeAll(keepingCapacity: false)
        } else {
            waiters = []
        }
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilDrained() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if admittedRequestIDs.isEmpty {
                lock.unlock()
                continuation.resume()
            } else {
                drainWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func admissionCount() -> Int {
        lock.lock()
        let count = totalAdmissionCount
        lock.unlock()
        return count
    }

    func waitForAdmissionCount(_ targetCount: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if totalAdmissionCount >= targetCount {
                lock.unlock()
                continuation.resume()
            } else {
                admissionCountWaiters[UUID()] = .init(
                    targetCount: targetCount,
                    continuation: continuation
                )
                lock.unlock()
            }
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
        let task: Task<StartingGenerationResult, Never>
        var admissionClosed = false

        init(
            id: UInt64,
            task: Task<StartingGenerationResult, Never>
        ) {
            self.id = id
            self.task = task
        }
    }

    private final class RunningGeneration: @unchecked Sendable {
        let id: UInt64
        let listener: any Channel
        let eventLoopGroup: MultiThreadedEventLoopGroup
        let cleanupTask: Task<Void, Never>
        let boundURL: URL
        var listenerCloseTask: Task<Result<Void, ReviewLifecycleResourceFailure>, Never>?

        init(
            id: UInt64,
            listener: any Channel,
            eventLoopGroup: MultiThreadedEventLoopGroup,
            cleanupTask: Task<Void, Never>,
            boundURL: URL
        ) {
            self.id = id
            self.listener = listener
            self.eventLoopGroup = eventLoopGroup
            self.cleanupTask = cleanupTask
            self.boundURL = boundURL
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
    private var lifecycleState = LifecycleState.stopped([])
    private var nextGenerationID: UInt64 = 0
    private var sessions: [String: SessionContext] = [:]
    private var pendingCloseFailures: [ReviewLifecycleResourceFailure] = []
    private let admissionRegistry = MCPHTTPAdmissionRegistry()
    private let handlerEntryGate = MCPHTTPHandlerEntryGate()
    private let startCompletionGate = MCPHTTPStartCompletionGate()
    private let networkResources = MCPHTTPNetworkResourceOwner()
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
                networkResources.open()
                let task = Task<StartingGenerationResult, Never> { [self] in
                    await performStartGeneration(id: id)
                }
                let operation = StartingGeneration(id: id, task: task)
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

    private func performStartGeneration(id: UInt64) async -> StartingGenerationResult {
        let admissionRegistry = admissionRegistry
        let handlerEntryGate = handlerEntryGate
        let networkResources = networkResources
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                guard let childRegistration = networkResources.registerChild(channel) else {
                    return channel.close(mode: .all)
                }
                return channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(CodexReviewMCPHTTPHandler(
                        server: self,
                        admissionRegistry: admissionRegistry,
                        entryGate: handlerEntryGate,
                        networkResources: networkResources,
                        childRegistration: childRegistration
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
                boundURL: configuration.url(boundPort: actualPort)
            ))
        } catch {
            networkResources.closeChildAdmission()
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
            await networkResources.closeAndDrainChildren()
            await networkResources.closeTaskAdmissionCancelAndDrain()
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
            admissionRegistry.open()
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
        admissionRegistry.close()
        networkResources.closeChildAdmission()
        networkResources.closeTaskAdmission(kind: .domainHandler)
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
            startCompletionGate.recordAdmissionClosed()
        }
        operation.task.cancel()
    }

    private func performStopGeneration(
        _ resources: RunningGeneration
    ) async -> [ReviewLifecycleResourceFailure] {
        admissionRegistry.close()
        networkResources.closeChildAdmission()
        networkResources.closeTaskAdmission(kind: .domainHandler)
        var failures = pendingCloseFailures
        pendingCloseFailures.removeAll(keepingCapacity: false)
        if let listenerFailure = await closeListener(resources) {
            if failures.contains(listenerFailure) == false {
                failures.append(listenerFailure)
            }
        }
        resources.cleanupTask.cancel()
        await waitForAdmittedHandlers()
        await resources.cleanupTask.value
        await networkResources.waitForTasksDrained(kind: .domainHandler)
        await networkResources.waitForTasksDrained(kind: .finiteResponseSource)
        await networkResources.waitForTasksDrained(kind: .finiteResponseWriter)
        await closeAllSessions()
        await networkResources.closeAndDrainChildren()
        await networkResources.closeTaskAdmissionCancelAndDrain()
        let resourceCounts = networkResources.resourceCountsForTesting()
        precondition(
            resourceCounts.children == 0 && resourceCounts.tasks == 0,
            "MCPHTTPNetworkResourceOwner must drain children and Tasks before EventLoopGroup shutdown."
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
        admissionRegistry.close()
        networkResources.closeChildAdmission()
        networkResources.closeTaskAdmission(kind: .domainHandler)
        var resources: RunningGeneration?
        var startingOperation: StartingGeneration?
        switch lifecycleState {
        case .running(let running):
            resources = running
        case .stopping(_, let stopping, _):
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
        let task: Task<Result<Void, ReviewLifecycleResourceFailure>, Never>
        if let existing = resources.listenerCloseTask {
            task = existing
        } else {
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
            task = newTask
        }
        switch await task.value {
        case .success:
            return nil
        case .failure(let failure):
            return failure
        }
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
        await admissionRegistry.waitUntilDrained()
    }

    package func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        guard let admission = admissionRegistry.admit() else {
            return .error(
                statusCode: 503,
                .internalError("MCP server is not accepting requests.")
            )
        }
        let response = await performTrackedHTTPRequest(request).response
        admissionRegistry.finish(admission)
        return response
    }

    fileprivate func handleAdmittedHTTPRequest(
        _ request: HTTPRequest
    ) async -> TrackedHTTPResponse {
        await performTrackedHTTPRequest(request)
    }

    private func performTrackedHTTPRequest(_ request: HTTPRequest) async -> TrackedHTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            session.activeRequestCount += 1
            sessions[sessionID] = session
            let response = await session.transport.handleRequest(request)
            let (trackedResponse, didFinishRequest) = trackActiveRequest(
                response,
                sessionID: sessionID,
                method: request.method
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
                boundedReviewWaitDuration: configuration.boundedReviewWaitDuration,
                networkResources: networkResources
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
                method: request.method
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
        await session.server.waitUntilCompleted()
        await session.server.stop()
        await adapter.closeSession(sessionID)
        logger.info("Closed MCP HTTP session \(sessionID, privacy: .public)")
    }

    private func trackActiveRequest(
        _ response: HTTPResponse,
        sessionID: String,
        method: String
    ) -> (response: TrackedHTTPResponse, didFinishRequest: Bool) {
        switch response {
        case .stream(let stream, let headers):
            let networkResources = networkResources
            let isFiniteResponseStream = method.uppercased() == "POST"
            let completion = ActiveRequestCompletion {
                guard let receipt = networkResources.registerTask(
                    kind: .streamCompletion
                ) else {
                    return
                }
                let task = Task {
                    await self.finishActiveRequest(sessionID: sessionID)
                    receipt.finish()
                }
                receipt.install(task)
            }
            let trackedStream = AsyncThrowingStream<Data, Swift.Error>(bufferingPolicy: .unbounded) { continuation in
                let heartbeatTask = makeStreamHeartbeatTask(continuation: continuation)
                guard let receipt = networkResources.registerTask(
                    kind: isFiniteResponseStream ? .finiteResponseSource : .streamBridge
                ) else {
                    heartbeatTask?.cancel()
                    completion.finish()
                    continuation.finish()
                    return
                }
                let task = Task {
                    defer {
                        heartbeatTask?.cancel()
                        completion.finish()
                        receipt.finish()
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
                receipt.install(task)
                continuation.onTermination = { _ in
                    heartbeatTask?.cancel()
                    if isFiniteResponseStream == false {
                        task.cancel()
                        completion.finish()
                    }
                }
            }
            return (
                .init(
                    response: .stream(trackedStream, headers: headers),
                    streamCompletion: isFiniteResponseStream ? nil : completion,
                    isFiniteResponseStream: isFiniteResponseStream
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

    private func makeStreamHeartbeatTask(
        continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    ) -> Task<Void, Never>? {
        guard let interval = configuration.streamHeartbeatInterval else {
            return nil
        }
        guard let receipt = networkResources.registerTask(
            kind: .streamHeartbeat
        ) else {
            return nil
        }
        let task = Task {
            defer { receipt.finish() }
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
        receipt.install(task)
        return task
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

    package func listenerIsOpenForTesting() -> Bool {
        switch lifecycleState {
        case .running(let resources),
             .stopping(_, let resources?, _):
            resources.listenerCloseTask == nil && resources.listener.isActive
        case .stopped, .starting, .stopping:
            false
        }
    }

    package func admittedNetworkRequestCountForTesting() -> Int {
        admissionRegistry.admissionCount()
    }

    package func waitForAdmittedNetworkRequestCountForTesting(
        _ count: Int
    ) async {
        await admissionRegistry.waitForAdmissionCount(count)
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

    package func networkResourceCountsForTesting() -> (children: Int, tasks: Int) {
        networkResources.resourceCountsForTesting()
    }

    package func networkTaskRegistrationCountForTesting(
        streamWriter: Bool
    ) -> Int {
        networkResources.taskCountForTesting(
            kind: streamWriter ? .streamWriter : .response
        )
    }

    package func waitForNetworkTaskRegistrationCountForTesting(
        streamWriter: Bool,
        count: Int
    ) async {
        await networkResources.waitForTaskCountForTesting(
            kind: streamWriter ? .streamWriter : .response,
            count: count
        )
    }

    package func holdNextNetworkTaskCompletionForTesting(
        streamWriter: Bool
    ) {
        networkResources.holdNextTaskCompletionForTesting(
            kind: streamWriter ? .streamWriter : .response
        )
    }

    package func holdNextFiniteResponseSourceCompletionForTesting() {
        networkResources.holdNextTaskCompletionForTesting(
            kind: .finiteResponseSource
        )
    }

    package func finiteResponseSourceCompletionIsHeldForTesting() -> Bool {
        networkResources.hasHeldTaskCompletionForTesting()
    }

    package func waitForHeldNetworkTaskCompletionForTesting() async {
        await networkResources.waitForHeldTaskCompletionForTesting()
    }

    package func releaseHeldNetworkTaskCompletionForTesting() {
        networkResources.releaseHeldTaskCompletionForTesting()
    }

    package func childChannelRegistrationCountForTesting() -> Int {
        networkResources.childCountForTesting()
    }

    package func waitForChildChannelRegistrationCountForTesting(
        _ count: Int
    ) async {
        await networkResources.waitForChildCountForTesting(count)
    }

    package func holdNextChildCloseAcknowledgementForTesting() {
        networkResources.holdNextChildCloseAcknowledgementForTesting()
    }

    package func waitForHeldChildCloseAcknowledgementForTesting() async {
        await networkResources.waitForHeldChildCloseAcknowledgementForTesting()
    }

    package func releaseHeldChildCloseAcknowledgementForTesting() {
        networkResources.releaseHeldChildCloseAcknowledgementForTesting()
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

private final class MCPHTTPStreamOwnership: @unchecked Sendable {
    private enum TerminationOwner {
        case active
        case channel
        case task
    }

    let id = UUID()
    let receipt: MCPHTTPNetworkResourceOwner.TaskReceipt
    let completion: ActiveRequestCompletion?
    private let lock = NSLock()
    private var terminationOwner = TerminationOwner.active

    init(
        receipt: MCPHTTPNetworkResourceOwner.TaskReceipt,
        completion: ActiveRequestCompletion?
    ) {
        self.receipt = receipt
        self.completion = completion
    }

    func install(_ task: Task<Void, Never>) {
        receipt.install(task)
    }

    func terminateFromChannel() {
        lock.lock()
        guard terminationOwner == .active else {
            lock.unlock()
            return
        }
        terminationOwner = .channel
        lock.unlock()
        completion?.finish()
        receipt.cancel()
    }

    func claimTaskTermination() -> Bool {
        lock.lock()
        guard terminationOwner == .active else {
            lock.unlock()
            return false
        }
        terminationOwner = .task
        lock.unlock()
        return true
    }

    func finishTask() {
        receipt.finish()
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

    private let server: CodexReviewMCPHTTPServer
    private let admissionRegistry: MCPHTTPAdmissionRegistry
    private let entryGate: MCPHTTPHandlerEntryGate
    private let networkResources: MCPHTTPNetworkResourceOwner
    private let childRegistration: MCPHTTPNetworkResourceOwner.ChildRegistration
    private var requestState: RequestState?
    private var activeStreamOwnership: MCPHTTPStreamOwnership?

    init(
        server: CodexReviewMCPHTTPServer,
        admissionRegistry: MCPHTTPAdmissionRegistry,
        entryGate: MCPHTTPHandlerEntryGate,
        networkResources: MCPHTTPNetworkResourceOwner,
        childRegistration: MCPHTTPNetworkResourceOwner.ChildRegistration
    ) {
        self.server = server
        self.admissionRegistry = admissionRegistry
        self.entryGate = entryGate
        self.networkResources = networkResources
        self.childRegistration = childRegistration
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
            guard let admission = admissionRegistry.admit() else {
                writeAdmissionClosedResponse(
                    version: state.head.version,
                    context: context
                )
                return
            }
            guard let taskReceipt = networkResources.registerTask(
                kind: .response,
                child: childRegistration
            ) else {
                admissionRegistry.finish(admission)
                writeAdmissionClosedResponse(
                    version: state.head.version,
                    context: context
                )
                return
            }
            nonisolated(unsafe) let context = context
            let task = Task {
                defer {
                    admissionRegistry.finish(admission)
                    taskReceipt.finish()
                }
                await entryGate.waitIfNeeded()
                guard Task.isCancelled == false else {
                    return
                }
                await handleRequest(
                    state: state,
                    context: context
                )
            }
            taskReceipt.install(task)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
        context.read()
    }

    func channelInactive(context: ChannelHandlerContext) {
        finishActiveStream()
        networkResources.cancelTasks(for: childRegistration)
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            finishActiveStream()
            networkResources.cancelTasks(for: childRegistration)
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        finishActiveStream()
        networkResources.cancelTasks(for: childRegistration)
        context.close(promise: nil)
    }

    private func finishActiveStream() {
        activeStreamOwnership?.terminateFromChannel()
        activeStreamOwnership = nil
    }

    private func handleRequest(
        state: RequestState,
        context: ChannelHandlerContext
    ) async {
        let head = state.head
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

        let request = makeHTTPRequest(from: state)
        let response = await server.handleAdmittedHTTPRequest(request)
        await writeResponse(response, version: head.version, context: context)
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

    private func makeHTTPRequest(from state: RequestState) -> HTTPRequest {
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
            guard let streamReceipt = networkResources.registerTask(
                kind: trackedResponse.isFiniteResponseStream
                    ? .finiteResponseWriter
                    : .streamWriter,
                child: childRegistration
            ) else {
                trackedResponse.streamCompletion?.finish()
                return
            }
            let ownership = MCPHTTPStreamOwnership(
                receipt: streamReceipt,
                completion: trackedResponse.streamCompletion
            )
            let registration = eventLoop.makePromise(of: Void.self)
            eventLoop.execute {
                guard context.channel.isActive else {
                    trackedResponse.streamCompletion?.finish()
                    streamReceipt.finish()
                    registration.succeed(())
                    return
                }
                let streamTask = Task {
                    var head = HTTPResponseHead(version: version, status: status)
                    for (name, value) in headers {
                        head.headers.add(name: name, value: value)
                    }

                    var iterator = stream.makeAsyncIterator()
                    do {
                        try Task.checkCancellation()
                        try await self.writeResponsePart(
                            .head(head),
                            context: context,
                            eventLoop: eventLoop
                        )
                        while let chunk = try await iterator.next() {
                            try Task.checkCancellation()
                            try await self.writeResponseBody(
                                chunk,
                                context: context,
                                eventLoop: eventLoop
                            )
                        }
                    } catch is CancellationError {
                    } catch {
                        logger.error("MCP SSE stream failed: \(error.localizedDescription, privacy: .public)")
                    }

                    if Task.isCancelled == false {
                        try? await self.writeResponsePart(
                            .end(nil),
                            context: context,
                            eventLoop: eventLoop
                        )
                    }
                    await self.finishStreamTask(
                        ownership,
                        context: context,
                        eventLoop: eventLoop
                    )
                }
                context.channel.closeFuture.whenComplete { _ in
                    ownership.terminateFromChannel()
                }
                self.activeStreamOwnership?.terminateFromChannel()
                self.activeStreamOwnership = ownership
                ownership.install(streamTask)
                context.read()
                registration.succeed(())
            }
            try? await registration.futureResult.get()

        default:
            let body = response.bodyData
            var head = HTTPResponseHead(version: version, status: status)
            for (name, value) in headers {
                head.headers.add(name: name, value: value)
            }
            if let body {
                head.headers.add(name: "Content-Length", value: "\(body.count)")
            }
            do {
                try await writeResponsePart(
                    .head(head),
                    context: context,
                    eventLoop: eventLoop
                )
                if let body {
                    try await writeResponseBody(
                        body,
                        context: context,
                        eventLoop: eventLoop
                    )
                }
                try await writeResponsePart(
                    .end(nil),
                    context: context,
                    eventLoop: eventLoop
                )
            } catch {
                logger.debug(
                    "MCP HTTP response ended during connection shutdown: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func finishStreamTask(
        _ ownership: MCPHTTPStreamOwnership,
        context: ChannelHandlerContext,
        eventLoop: any EventLoop
    ) async {
        if ownership.claimTaskTermination() {
            let completion = eventLoop.makePromise(of: Void.self)
            eventLoop.execute {
                if self.activeStreamOwnership === ownership {
                    self.activeStreamOwnership = nil
                }
                ownership.completion?.finish()
                completion.succeed(())
            }
            try? await completion.futureResult.get()
        }
        ownership.finishTask()
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
