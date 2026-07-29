import Darwin
import Foundation
import MCP
import OSLog
import Synchronization
import CodexReviewKit
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

private let logger = Logger(subsystem: "CodexReviewKit", category: "mcp-http")

package typealias MCPHTTPServerLifetime = CodexReviewMCPHTTPServer

package typealias MCPProtocolServerFactory = @MainActor @Sendable (
    CodexReviewMCPServer,
    String,
    MCPReviewSessionRegistry,
    MCPClientSessionState,
    Duration
) async -> Server

package struct MCPHTTPServerClock: Sendable {
    package struct Instant: Comparable, Sendable {
        package static let zero = Self(elapsed: .zero)

        fileprivate let elapsed: Duration

        package func advanced(by duration: Duration) -> Self {
            Self(elapsed: elapsed + duration)
        }

        package func duration(to other: Self) -> Duration {
            other.elapsed - elapsed
        }

        package static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.elapsed < rhs.elapsed
        }
    }

    private let readNow: @Sendable () -> Instant
    private let sleepForDuration:
        @Sendable (Duration) async throws(CancellationError) -> Void

    package init(
        now: @escaping @Sendable () -> Instant,
        sleep: @escaping @Sendable (Duration) async throws(CancellationError) -> Void
    ) {
        self.readNow = now
        self.sleepForDuration = sleep
    }

    package static func continuous() -> Self {
        let clock = ContinuousClock()
        let origin = clock.now
        return Self(
            now: {
                Instant(elapsed: origin.duration(to: clock.now))
            },
            sleep: { (duration: Duration) async throws(CancellationError) -> Void in
                try await Self.sleep(using: clock, for: duration)
            }
        )
    }

    package var now: Instant {
        readNow()
    }

    package func sleep(for duration: Duration) async throws(CancellationError) {
        try await sleepForDuration(duration)
    }

    private static func sleep(
        using clock: ContinuousClock,
        for duration: Duration
    ) async throws(CancellationError) {
        do {
            try await clock.sleep(for: duration)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            preconditionFailure("ContinuousClock.sleep failed outside task cancellation: \(error)")
        }
    }
}

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
}

package extension CodexReviewMCPHTTPServer {
    struct Configuration: Sendable {
        package var host: String
        package var port: Int
        package var endpoint: String
        package var sessionTimeout: Duration
        package var sessionCleanupInterval: Duration
        package var retryInterval: Int?
        package var streamHeartbeatInterval: Duration?
        package var boundedReviewWaitDuration: Duration
        package var sessionClock: MCPHTTPServerClock

        package init(
            host: String = "localhost",
            port: Int = 9417,
            endpoint: String = "/mcp",
            sessionTimeout: Duration = .seconds(3600),
            sessionCleanupInterval: Duration = .seconds(60),
            retryInterval: Int? = 1000,
            sessionClock: MCPHTTPServerClock = .continuous()
        ) {
            self.init(
                host: host,
                port: port,
                endpoint: endpoint,
                sessionTimeout: sessionTimeout,
                sessionCleanupInterval: sessionCleanupInterval,
                retryInterval: retryInterval,
                streamHeartbeatInterval: .seconds(30),
                boundedReviewWaitDuration: .seconds(540),
                sessionClock: sessionClock
            )
        }

        package init(
            host: String = "localhost",
            port: Int = 9417,
            endpoint: String = "/mcp",
            sessionTimeout: Duration = .seconds(3600),
            sessionCleanupInterval: Duration = .seconds(60),
            retryInterval: Int? = 1000,
            streamHeartbeatInterval: Duration?,
            boundedReviewWaitDuration: Duration = .seconds(540),
            sessionClock: MCPHTTPServerClock = .continuous()
        ) {
            precondition(sessionTimeout >= .zero, "The MCP session timeout cannot be negative.")
            precondition(
                sessionCleanupInterval > .zero,
                "The MCP session cleanup interval must be positive."
            )
            self.host = host
            self.port = port
            self.endpoint = endpoint.hasPrefix("/") ? endpoint : "/\(endpoint)"
            self.sessionTimeout = sessionTimeout
            self.sessionCleanupInterval = sessionCleanupInterval
            self.retryInterval = retryInterval
            self.streamHeartbeatInterval = streamHeartbeatInterval
            self.boundedReviewWaitDuration = boundedReviewWaitDuration
            self.sessionClock = sessionClock
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

    struct ResourceSnapshot: Equatable, Sendable {
        package var listenerCount: Int
        package var eventLoopGroupCount: Int
        package var sessionCount: Int
        package var registrySessionCount: Int
        package var cleanupTaskCount: Int
        package var requestPumpTaskCount: Int
        package var activeRequestWorkCount: Int
        package var childChannelCount: Int
    }
}

package actor CodexReviewMCPHTTPServer {
    private enum Phase {
        case idle
        case staging
        case staged
        case accepting
        case stopping(Task<Void, Never>)
        case stopped
    }

    private struct SessionContext {
        enum Phase {
            case initializing
            case open
            case closing(
                reason: MCPReviewSessionCloseReason,
                completion: Task<Void, Never>
            )
        }

        var phase: Phase
        var server: Server?
        let transport: StatefulHTTPServerTransport
        var idleSince: MCPHTTPServerClock.Instant?
        var activeRequestCount: Int
        var registryOpened: Bool
        var creationCompleted: Bool
        var initializationResponseReady: Bool
    }

    private struct FixedSessionIDGenerator: SessionIDGenerator {
        let sessionID: String

        func generateSessionID() -> String {
            sessionID
        }
    }

    private let adapter: CodexReviewMCPServer
    private let sessionRegistry: MCPReviewSessionRegistry
    private let protocolServerFactory: MCPProtocolServerFactory
    private let configuration: CodexReviewMCPHTTPServer.Configuration
    private var channel: Channel?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var sessions: [String: SessionContext] = [:]
    private var stagingWaiters: [CheckedContinuation<Void, Never>] = []
    private var creationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var requestDrainWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var cleanupTask: Task<Void, Never>?
    private let requestEventSink = MCPHTTPRequestEventSink()
    private var requestPumpTask: Task<Void, Never>?
    private var activeRequestWorkCount = 0
    private let childChannels = MCPHTTPChannelRegistry()
    private var boundURL: URL?
    private var phase: Phase = .idle

    package init(
        adapter: CodexReviewMCPServer,
        configuration: CodexReviewMCPHTTPServer.Configuration = .init(),
        protocolServerFactory: @escaping MCPProtocolServerFactory = {
            adapter,
            sessionID,
            sessionRegistry,
            clientSession,
            boundedReviewWaitDuration in
            await makeMCPProtocolServer(
                adapter: adapter,
                sessionID: sessionID,
                sessionRegistry: sessionRegistry,
                clientSession: clientSession,
                boundedReviewWaitDuration: boundedReviewWaitDuration
            )
        }
    ) {
        self.adapter = adapter
        self.sessionRegistry = MCPReviewSessionRegistry(
            closeStoreSession: { sessionID in
                await adapter.closeSession(sessionID)
            },
            releaseStoreSession: { sessionID in
                adapter.releaseClosedSession(sessionID)
            }
        )
        self.protocolServerFactory = protocolServerFactory
        self.configuration = configuration
    }

    package var url: URL {
        boundURL ?? configuration.url()
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
        try await stage()
        switch phase {
        case .staged:
            phase = .accepting
        case .stopping(let completion):
            await completion.value
        case .stopped:
            return
        case .idle, .staging, .accepting:
            preconditionFailure("MCP HTTP staging must complete before activation.")
        }
    }

    package func stage() async throws {
        guard case .idle = phase else {
            preconditionFailure("The MCP HTTP server lifetime can only be started once.")
        }
        phase = .staging

        requestPumpTask = Task { [self] in
            await runRequestPump()
        }
        let endpoint = configuration.endpoint
        let heartbeatInterval = configuration.streamHeartbeatInterval
        let eventSink = requestEventSink
        let childChannels = childChannels
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                childChannels.insert(channel)
                channel.closeFuture.whenComplete { _ in
                    childChannels.remove(channel)
                }
                return channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(CodexReviewMCPHTTPHandler(
                        server: self,
                        endpoint: endpoint,
                        heartbeatInterval: heartbeatInterval,
                        eventSink: eventSink
                    ))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)

        do {
            let channel = try await bootstrap.bind(
                host: configuration.host,
                port: configuration.port
            ).get()
            self.eventLoopGroup = group
            self.channel = channel
            let actualPort = channel.localAddress?.port
            boundURL = configuration.url(boundPort: actualPort)
            phase = .staged
            let clock = configuration.sessionClock
            let cleanupInterval = configuration.sessionCleanupInterval
            cleanupTask = Task { [weak self] in
                while Task.isCancelled == false {
                    do {
                        try await clock.sleep(for: cleanupInterval)
                    } catch {
                        return
                    }
                    guard Task.isCancelled == false else {
                        return
                    }
                    await self?.runScheduledSessionCleanup()
                }
            }
            finishStaging()
            logger.info("MCP Streamable HTTP server listening at \(self.url.absoluteString, privacy: .public)")
        } catch {
            requestEventSink.finish()
            await requestPumpTask?.value
            requestPumpTask = nil
            try? await group.shutdownGracefully()
            phase = .stopped
            finishStaging()
            throw CodexReviewMCPHTTPServer.Error.classifyStartError(
                error,
                configuration: configuration
            )
        }
    }

    package func activate() {
        guard case .staged = phase else {
            preconditionFailure("Only a staged MCP HTTP server can begin accepting requests.")
        }
        phase = .accepting
    }

    package func stop() async {
        let completion: Task<Void, Never>
        switch phase {
        case .idle:
            phase = .stopped
            return
        case .staging:
            await waitForStaging()
            await stop()
            return
        case .staged, .accepting:
            let task = Task { [self] in
                await performStop()
            }
            phase = .stopping(task)
            completion = task
        case .stopping(let task):
            completion = task
        case .stopped:
            return
        }
        await completion.value
    }

    private func waitForStaging() async {
        guard case .staging = phase else {
            return
        }
        await withCheckedContinuation { continuation in
            stagingWaiters.append(continuation)
        }
    }

    private func finishStaging() {
        let waiters = stagingWaiters
        stagingWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func performStop() async {
        let cleanup = cleanupTask
        cleanupTask = nil
        cleanup?.cancel()

        if let channel {
            try? await channel.close()
        }
        channel = nil
        await cleanup?.value

        await closeAllSessions(reason: .serverStop)

        requestEventSink.finish()
        let requestPump = requestPumpTask
        requestPumpTask = nil
        await requestPump?.value

        let openChildChannels = childChannels.snapshot()
        for childChannel in openChildChannels {
            try? await childChannel.close()
        }

        if let eventLoopGroup {
            try? await eventLoopGroup.shutdownGracefully()
        }
        eventLoopGroup = nil
        boundURL = nil
        phase = .stopped
        logger.info("MCP Streamable HTTP server stopped")
    }

    private func runRequestPump() async {
        await withTaskGroup(of: Void.self) { group in
            for await work in requestEventSink.events {
                activeRequestWorkCount += 1
                group.addTask {
                    await work.run()
                    await self.requestWorkFinished()
                }
            }
            while await group.next() != nil {}
        }
    }

    private func requestWorkFinished() {
        precondition(activeRequestWorkCount > 0)
        activeRequestWorkCount -= 1
    }

    package func handleHTTPRequestForTesting(_ request: HTTPRequest) async -> HTTPResponse {
        let trackedResponse = await handleTrackedHTTPRequest(request)
        trackedResponse.streamCompletion?.finish()
        return trackedResponse.response
    }

    fileprivate func handleTrackedHTTPRequest(_ request: HTTPRequest) async -> TrackedHTTPResponse {
        guard case .accepting = phase else {
            return .init(
                response: .error(
                    statusCode: 503,
                    .internalError("MCP HTTP server is stopping")
                )
            )
        }
        let sessionID = request.header(HTTPHeaderName.sessionID)

        if let sessionID, var session = sessions[sessionID] {
            switch session.phase {
            case .initializing:
                return .init(
                    response: .error(
                        statusCode: 409,
                        .invalidRequest("Conflict: MCP session initialization is not complete")
                    )
                )
            case .closing:
                return .init(
                    response: .error(
                        statusCode: 404,
                        .invalidRequest("Not Found: Session not found or expired")
                    )
                )
            case .open:
                break
            }
            session.idleSince = nil
            session.activeRequestCount += 1
            sessions[sessionID] = session
            let response = await session.transport.handleRequest(request)
            let (trackedResponse, didFinishRequest) = trackActiveRequest(response, sessionID: sessionID)
            if didFinishRequest, request.method.uppercased() == "DELETE", trackedResponse.response.statusCode == 200 {
                await closeSession(sessionID, reason: .delete)
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
        sessions[sessionID] = SessionContext(
            phase: .initializing,
            server: nil,
            transport: transport,
            idleSince: nil,
            activeRequestCount: 1,
            registryOpened: false,
            creationCompleted: false,
            initializationResponseReady: false
        )
        defer {
            finishSessionCreation(sessionID)
        }

        do {
            await sessionRegistry.openSession(sessionID)
            updateSession(sessionID) { context in
                context.registryOpened = true
            }
            guard isSessionInitializing(sessionID) else {
                await transport.disconnect()
                finishActiveRequest(sessionID: sessionID)
                return sessionClosedDuringInitializationResponse()
            }

            let server = await protocolServerFactory(
                adapter,
                sessionID,
                sessionRegistry,
                clientSession,
                configuration.boundedReviewWaitDuration
            )
            updateSession(sessionID) { context in
                context.server = server
            }
            guard isSessionInitializing(sessionID) else {
                await server.stop()
                await transport.disconnect()
                finishActiveRequest(sessionID: sessionID)
                return sessionClosedDuringInitializationResponse()
            }

            try await server.start(transport: transport) { clientInfo, _ in
                await clientSession.update(clientInfo: clientInfo)
            }
            guard isSessionInitializing(sessionID) else {
                await server.stop()
                await transport.disconnect()
                finishActiveRequest(sessionID: sessionID)
                return sessionClosedDuringInitializationResponse()
            }

            let response = await transport.handleRequest(request)
            guard isSessionInitializing(sessionID) else {
                finishActiveRequest(sessionID: sessionID)
                return sessionClosedDuringInitializationResponse()
            }
            let (trackedResponse, didFinishRequest) = trackActiveRequest(response, sessionID: sessionID)
            if didFinishRequest, case .error = trackedResponse.response {
                _ = beginCloseSession(sessionID, reason: .initializationFailure)
            } else {
                updateSession(sessionID) { context in
                    context.initializationResponseReady = true
                }
            }
            return trackedResponse
        } catch {
            finishActiveRequest(sessionID: sessionID)
            _ = beginCloseSession(sessionID, reason: .initializationFailure)
            return .init(
                response: .error(
                    statusCode: 500,
                    .internalError("Failed to create MCP session: \(error.localizedDescription)")
                )
            )
        }
    }

    private func closeSession(
        _ sessionID: String,
        reason: MCPReviewSessionCloseReason
    ) async {
        guard let completion = beginCloseSession(sessionID, reason: reason) else {
            return
        }
        await completion.value
    }

    private func beginCloseSession(
        _ sessionID: String,
        reason: MCPReviewSessionCloseReason
    ) -> Task<Void, Never>? {
        guard var context = sessions[sessionID] else {
            return nil
        }
        switch context.phase {
        case .initializing, .open:
            let completion = Task { [self] in
                await driveSessionClose(sessionID: sessionID, reason: reason)
            }
            context.phase = .closing(reason: reason, completion: completion)
            sessions[sessionID] = context
            return completion
        case .closing(_, let completion):
            return completion
        }
    }

    private func driveSessionClose(
        sessionID: String,
        reason: MCPReviewSessionCloseReason
    ) async {
        guard let initialContext = sessions[sessionID] else {
            return
        }

        var registryClose: Task<MCPReviewSessionCloseReport, Never>?
        if initialContext.registryOpened {
            registryClose = await sessionRegistry.beginClose(sessionID, reason: reason)
        }

        if let server = initialContext.server {
            await server.stop()
        }
        await initialContext.transport.disconnect()
        await waitForSessionCreation(sessionID)

        // Initialization can publish a Server or registry session immediately
        // before observing the close phase. Drain those late resources too.
        if let finalContext = sessions[sessionID] {
            if registryClose == nil, finalContext.registryOpened {
                registryClose = await sessionRegistry.beginClose(sessionID, reason: reason)
            }
            if let server = finalContext.server, initialContext.server == nil {
                await server.stop()
            }
            await finalContext.transport.disconnect()
        }

        await waitForSessionRequests(sessionID)
        if let registryClose {
            let report = await registryClose.value
            if report.cancellationFailed.isEmpty == false {
                let runIDs = report.cancellationFailed
                    .map(\.rawValue)
                    .sorted()
                    .joined(separator: ",")
                logger.error(
                    "MCP session \(sessionID, privacy: .public) closed with undrained runs \(runIDs, privacy: .public)"
                )
            }
        }

        let didOpenRegistry = sessions[sessionID]?.registryOpened == true
        sessions.removeValue(forKey: sessionID)
        creationWaiters.removeValue(forKey: sessionID)
        requestDrainWaiters.removeValue(forKey: sessionID)
        if didOpenRegistry {
            await sessionRegistry.removeClosedSession(sessionID)
        }
        logger.info("Closed MCP HTTP session \(sessionID, privacy: .public)")
    }

    private func waitForSessionCreation(_ sessionID: String) async {
        guard sessions[sessionID]?.creationCompleted == false else {
            return
        }
        await withCheckedContinuation { continuation in
            creationWaiters[sessionID, default: []].append(continuation)
        }
    }

    private func waitForSessionRequests(_ sessionID: String) async {
        guard let context = sessions[sessionID], context.activeRequestCount > 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            requestDrainWaiters[sessionID, default: []].append(continuation)
        }
    }

    private func finishSessionCreation(_ sessionID: String) {
        guard var context = sessions[sessionID] else {
            return
        }
        context.creationCompleted = true
        if case .initializing = context.phase,
           context.initializationResponseReady,
           context.activeRequestCount == 0 {
            context.phase = .open
            context.idleSince = configuration.sessionClock.now
        }
        sessions[sessionID] = context
        let waiters = creationWaiters.removeValue(forKey: sessionID) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func isSessionInitializing(_ sessionID: String) -> Bool {
        guard let context = sessions[sessionID], case .initializing = context.phase else {
            return false
        }
        return true
    }

    private func updateSession(
        _ sessionID: String,
        update: (inout SessionContext) -> Void
    ) {
        guard var context = sessions[sessionID] else {
            return
        }
        update(&context)
        sessions[sessionID] = context
    }

    private func sessionClosedDuringInitializationResponse() -> TrackedHTTPResponse {
        .init(
            response: .error(
                statusCode: 503,
                .internalError("MCP session closed during initialization")
            )
        )
    }

    private func trackActiveRequest(
        _ response: HTTPResponse,
        sessionID: String
    ) -> (response: TrackedHTTPResponse, didFinishRequest: Bool) {
        switch response {
        case .stream(let stream, let headers):
            let eventSink = requestEventSink
            let completion = ActiveRequestCompletion { [self] in
                let didSubmit = eventSink.send(MCPHTTPRequestWork {
                    await self.finishActiveRequest(sessionID: sessionID)
                })
                precondition(
                    didSubmit,
                    "The HTTP request pump must outlive every tracked MCP response stream."
                )
            }
            return (
                .init(response: .stream(stream, headers: headers), streamCompletion: completion),
                false
            )

        default:
            finishActiveRequest(sessionID: sessionID)
            return (.init(response: response), true)
        }
    }

    private func finishActiveRequest(sessionID: String) {
        guard var session = sessions[sessionID] else {
            preconditionFailure("An active MCP HTTP request must retain its session context.")
        }
        precondition(
            session.activeRequestCount > 0,
            "An MCP HTTP request can only finish once."
        )
        session.activeRequestCount -= 1
        if case .initializing = session.phase,
           session.initializationResponseReady,
           session.creationCompleted,
           session.activeRequestCount == 0 {
            session.phase = .open
        }
        if session.activeRequestCount == 0 {
            session.idleSince = configuration.sessionClock.now
        }
        sessions[sessionID] = session
        if session.activeRequestCount == 0 {
            let waiters = requestDrainWaiters.removeValue(forKey: sessionID) ?? []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    private func closeAllSessions(reason: MCPReviewSessionCloseReason) async {
        let sessionIDs = Array(sessions.keys)
        let completions = sessionIDs.compactMap { sessionID in
            beginCloseSession(sessionID, reason: reason)
        }
        for completion in completions {
            await completion.value
        }
    }

    private func runScheduledSessionCleanup() async {
        await closeExpiredSessions(now: configuration.sessionClock.now)
    }

    package func sessionActiveRequestCountForTesting(sessionID: String) -> Int? {
        sessions[sessionID]?.activeRequestCount
    }

    package func sessionIsClosingForTesting(sessionID: String) -> Bool {
        guard let context = sessions[sessionID], case .closing = context.phase else {
            return false
        }
        return true
    }

    package func registerSessionMemberForTesting(
        _ runID: ReviewRunID,
        sessionID: String
    ) async throws {
        try await sessionRegistry.registerMemberForTesting(runID, in: sessionID)
    }

    package func resourceSnapshotForTesting() async -> ResourceSnapshot {
        let registrySessionCount = await sessionRegistry.sessionCountForTesting()
        return ResourceSnapshot(
            listenerCount: channel == nil ? 0 : 1,
            eventLoopGroupCount: eventLoopGroup == nil ? 0 : 1,
            sessionCount: sessions.count,
            registrySessionCount: registrySessionCount,
            cleanupTaskCount: cleanupTask == nil ? 0 : 1,
            requestPumpTaskCount: requestPumpTask == nil ? 0 : 1,
            activeRequestWorkCount: activeRequestWorkCount,
            childChannelCount: childChannels.count
        )
    }

    private func closeExpiredSessions(now: MCPHTTPServerClock.Instant) async {
        var closeCompletions: [Task<Void, Never>] = []
        let sessionSnapshot = Array(sessions)
        for (sessionID, context) in sessionSnapshot {
            guard case .open = context.phase else {
                continue
            }
            if context.activeRequestCount > 0 {
                updateSession(sessionID) { context in
                    context.idleSince = nil
                }
                continue
            }
            let hasPendingRegistryWork = await sessionRegistry.hasPendingWork(in: sessionID)
            let hasActiveReviews = await adapter.hasActiveReviews(in: sessionID)
            if hasPendingRegistryWork || hasActiveReviews {
                updateSession(sessionID) { context in
                    context.idleSince = nil
                }
                continue
            }
            guard let currentContext = sessions[sessionID],
                  case .open = currentContext.phase,
                  currentContext.activeRequestCount == 0,
                  currentContext.idleSince == context.idleSince else {
                continue
            }
            guard let idleSince = currentContext.idleSince else {
                updateSession(sessionID) { context in
                    context.idleSince = now
                }
                continue
            }
            if idleSince.duration(to: now) > configuration.sessionTimeout {
                if let completion = beginCloseSession(sessionID, reason: .timeout) {
                    closeCompletions.append(completion)
                }
            }
        }
        for completion in closeCompletions {
            await completion.value
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

private struct MCPHTTPRequestWork: Sendable {
    let run: @Sendable () async -> Void
}

private final class MCPHTTPRequestEventSink: Sendable {
    private struct State {
        var isOpen = true
        let continuation: AsyncStream<MCPHTTPRequestWork>.Continuation
    }

    let events: AsyncStream<MCPHTTPRequestWork>
    private let state: Mutex<State>

    init() {
        let (events, continuation) = AsyncStream<MCPHTTPRequestWork>.makeStream()
        self.events = events
        self.state = Mutex(State(continuation: continuation))
    }

    @discardableResult
    func send(_ work: MCPHTTPRequestWork) -> Bool {
        state.withLock { state in
            guard state.isOpen else {
                return false
            }
            state.continuation.yield(work)
            return true
        }
    }

    func finish() {
        state.withLock { state in
            guard state.isOpen else {
                return
            }
            state.isOpen = false
            state.continuation.finish()
        }
    }
}

private final class MCPHTTPChannelCancellation: Sendable {
    private struct State {
        var isCancelled = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = Mutex(State())

    func wait() async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResume = state.withLock { state in
                    if state.isCancelled || Task.isCancelled {
                        return true
                    }
                    state.waiters[waiterID] = continuation
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: { [self] in
            let continuation = state.withLock { state in
                state.waiters.removeValue(forKey: waiterID)
            }
            continuation?.resume()
        }
    }

    func cancel() {
        let waiters = state.withLock { state in
            guard state.isCancelled == false else {
                return [CheckedContinuation<Void, Never>]()
            }
            state.isCancelled = true
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private final class MCPHTTPChannelRegistry: Sendable {
    private let channels = Mutex<[ObjectIdentifier: any Channel]>([:])

    func insert(_ channel: any Channel) {
        channels.withLock { channels in
            channels[ObjectIdentifier(channel)] = channel
        }
    }

    func remove(_ channel: any Channel) {
        channels.withLock { channels in
            _ = channels.removeValue(forKey: ObjectIdentifier(channel))
        }
    }

    func snapshot() -> [any Channel] {
        channels.withLock { channels in
            Array(channels.values)
        }
    }

    var count: Int {
        channels.withLock { $0.count }
    }
}

private final class ActiveRequestCompletion: Sendable {
    private let didFinish = Mutex(false)
    private let onFinish: @Sendable () -> Void

    init(onFinish: @escaping @Sendable () -> Void) {
        self.onFinish = onFinish
    }

    func finish() {
        let shouldFinish = didFinish.withLock { didFinish in
            if didFinish {
                return false
            }
            didFinish = true
            return true
        }
        guard shouldFinish else { return }
        onFinish()
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

        func writeResponse(
            head: HTTPResponseHead,
            body: Data?,
            promise: EventLoopPromise<Void>
        ) {
            context.write(handler.wrapOutboundOut(.head(head)), promise: nil)
            if let body {
                var buffer = context.channel.allocator.buffer(capacity: body.count)
                buffer.writeBytes(body)
                context.write(handler.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            }
            context.writeAndFlush(handler.wrapOutboundOut(.end(nil)), promise: promise)
        }
    }

    private struct RequestState {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }

    private enum StreamWriterOutcome: Sendable {
        case completed
        case channelClosed
        case stopped
        case failed(String)
    }

    private let server: CodexReviewMCPHTTPServer
    private let endpoint: String
    private let heartbeatInterval: Duration?
    private let eventSink: MCPHTTPRequestEventSink
    private let channelCancellation = MCPHTTPChannelCancellation()
    private var requestState: RequestState?

    init(
        server: CodexReviewMCPHTTPServer,
        endpoint: String,
        heartbeatInterval: Duration?,
        eventSink: MCPHTTPRequestEventSink
    ) {
        self.server = server
        self.endpoint = endpoint
        self.heartbeatInterval = heartbeatInterval
        self.eventSink = eventSink
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
            nonisolated(unsafe) let context = context
            let didSubmit = eventSink.send(MCPHTTPRequestWork { [self] in
                await handleRequest(state: state, context: context)
            })
            if didSubmit == false {
                context.close(promise: nil)
            }
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
        context.read()
    }

    func channelInactive(context: ChannelHandlerContext) {
        channelCancellation.cancel()
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            channelCancellation.cancel()
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        channelCancellation.cancel()
        context.close(promise: nil)
    }

    private func handleRequest(
        state: RequestState,
        context: ChannelHandlerContext
    ) async {
        let head = state.head
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        guard path == endpoint else {
            await writeResponse(
                .init(response: .error(statusCode: 404, .invalidRequest("Not Found"))),
                version: head.version,
                context: context
            )
            return
        }

        let request = makeHTTPRequest(from: state)
        let response = await server.handleTrackedHTTPRequest(request)
        await writeResponse(response, version: head.version, context: context)
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
            defer {
                trackedResponse.streamCompletion?.finish()
            }
            let responseHead = makeResponseHead(
                version: version,
                status: status,
                headers: headers
            )
            eventLoop.execute {
                context.read()
            }

            let outcome = await withTaskGroup(
                of: StreamWriterOutcome.self,
                returning: StreamWriterOutcome.self
            ) { group in
                group.addTask { [self] in
                    do {
                        try Task.checkCancellation()
                        try await writeResponsePart(
                            .head(responseHead),
                            context: context,
                            eventLoop: eventLoop
                        )
                        for try await chunk in stream {
                            try Task.checkCancellation()
                            try await writeResponseBody(chunk, context: context, eventLoop: eventLoop)
                        }
                        return .completed
                    } catch is CancellationError {
                        return .stopped
                    } catch {
                        return .failed(error.localizedDescription)
                    }
                }
                group.addTask { [channelCancellation] in
                    await channelCancellation.wait()
                    return Task.isCancelled ? .stopped : .channelClosed
                }
                if let heartbeatInterval {
                    group.addTask { [self] in
                        do {
                            while Task.isCancelled == false {
                                try await Task.sleep(for: heartbeatInterval)
                                try Task.checkCancellation()
                                try await writeResponseBody(
                                    Data(": keep-alive\n\n".utf8),
                                    context: context,
                                    eventLoop: eventLoop
                                )
                            }
                            return .stopped
                        } catch is CancellationError {
                            return .stopped
                        } catch {
                            return .failed(error.localizedDescription)
                        }
                    }
                }

                let first = await group.next() ?? .stopped
                group.cancelAll()
                while await group.next() != nil {}
                return first
            }

            switch outcome {
            case .completed:
                try? await writeResponsePart(.end(nil), context: context, eventLoop: eventLoop)
            case .failed(let message):
                logger.error("MCP SSE stream failed: \(message, privacy: .public)")
            case .channelClosed, .stopped:
                break
            }

        default:
            let body = response.bodyData
            var head = makeResponseHead(
                version: version,
                status: status,
                headers: headers
            )
            if let body {
                head.headers.add(name: "Content-Length", value: "\(body.count)")
            }
            let responseHead = head
            let writer = ResponsePartWriter(handler: self, context: context)
            let promise = eventLoop.makePromise(of: Void.self)
            eventLoop.execute {
                writer.writeResponse(
                    head: responseHead,
                    body: body,
                    promise: promise
                )
            }
            do {
                try await promise.futureResult.get()
            } catch {
                logger.error("MCP HTTP response write failed: \(error.localizedDescription, privacy: .public)")
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

    private func makeResponseHead(
        version: HTTPVersion,
        status: HTTPResponseStatus,
        headers: [String: String]
    ) -> HTTPResponseHead {
        var head = HTTPResponseHead(version: version, status: status)
        for (name, value) in headers {
            head.headers.add(name: name, value: value)
        }
        return head
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
