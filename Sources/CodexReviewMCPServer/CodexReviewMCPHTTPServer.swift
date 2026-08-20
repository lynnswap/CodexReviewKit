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

package actor CodexReviewMCPHTTPServer {
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
    private var channel: Channel?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var sessions: [String: SessionContext] = [:]
    private var cleanupTask: Task<Void, Never>?
    private var boundURL: URL?
    private var pendingCloseFailures: [ReviewLifecycleResourceFailure] = []
    private var listenerCloseTask: Task<Result<Void, ReviewLifecycleResourceFailure>, Never>?
    private let admissionRegistry = MCPHTTPAdmissionRegistry()
    private let handlerEntryGate = MCPHTTPHandlerEntryGate()
    private var admittedHandlerDrainDidBegin = false
    private var admittedHandlerDrainStartWaiters: [CheckedContinuation<Void, Never>] = []

    package init(
        adapter: CodexReviewMCPServer,
        configuration: CodexReviewMCPHTTPServer.Configuration = .init()
    ) {
        self.adapter = adapter
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
        guard channel == nil else {
            return
        }

        let admissionRegistry = admissionRegistry
        let handlerEntryGate = handlerEntryGate
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(CodexReviewMCPHTTPHandler(
                        server: self,
                        admissionRegistry: admissionRegistry,
                        entryGate: handlerEntryGate
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
            guard Task.isCancelled == false else {
                try? await channel.close()
                try? await group.shutdownGracefully()
                throw CancellationError()
            }
            self.eventLoopGroup = group
            self.channel = channel
            pendingCloseFailures.removeAll(keepingCapacity: false)
            listenerCloseTask = nil
            admissionRegistry.open()
            admittedHandlerDrainDidBegin = false
            let actualPort = channel.localAddress?.port
            boundURL = configuration.url(boundPort: actualPort)
            cleanupTask = Task { [weak self] in
                await self?.sessionCleanupLoop()
            }
            logger.info("MCP Streamable HTTP server listening at \(self.url.absoluteString, privacy: .public)")
        } catch {
            try? await group.shutdownGracefully()
            throw CodexReviewMCPHTTPServer.Error.classifyStartError(
                error,
                configuration: configuration
            )
        }
    }

    package func stop() async throws {
        await closeAdmission()
        cleanupTask?.cancel()
        let cleanupTask = cleanupTask
        self.cleanupTask = nil
        await waitForAdmittedHandlers()
        await cleanupTask?.value
        await closeAllSessions()
        if let eventLoopGroup {
            do {
                try await eventLoopGroup.shutdownGracefully()
            } catch {
                pendingCloseFailures.append(.mcpServer(error.localizedDescription))
            }
        }
        eventLoopGroup = nil
        boundURL = nil
        logger.info("MCP Streamable HTTP server stopped")
        if let first = pendingCloseFailures.first {
            let aggregate = ReviewLifecycleResourceFailureAggregate(
                first: first,
                additionalInLifecycleOrder: Array(pendingCloseFailures.dropFirst())
            )
            pendingCloseFailures.removeAll(keepingCapacity: false)
            throw aggregate
        }
    }

    package func closeAdmission() async {
        admissionRegistry.close()
        guard let channel else {
            return
        }
        let task: Task<Result<Void, ReviewLifecycleResourceFailure>, Never>
        if let listenerCloseTask {
            task = listenerCloseTask
        } else {
            let newTask = Task<Result<Void, ReviewLifecycleResourceFailure>, Never> {
                do {
                    try await channel.close()
                    return .success(())
                } catch {
                    return .failure(.mcpServer(error.localizedDescription))
                }
            }
            listenerCloseTask = newTask
            task = newTask
        }
        switch await task.value {
        case .success:
            self.channel = nil
        case .failure(let failure):
            if pendingCloseFailures.contains(failure) == false {
                pendingCloseFailures.append(failure)
            }
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

    package func listenerIsOpenForTesting() -> Bool {
        channel != nil
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
    private var requestState: RequestState?
    private var activeStreamTask: Task<Void, Never>?
    private var activeStreamID: UUID?
    private var activeStreamCompletion: ActiveRequestCompletion?

    init(
        server: CodexReviewMCPHTTPServer,
        admissionRegistry: MCPHTTPAdmissionRegistry,
        entryGate: MCPHTTPHandlerEntryGate
    ) {
        self.server = server
        self.admissionRegistry = admissionRegistry
        self.entryGate = entryGate
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
            nonisolated(unsafe) let context = context
            Task {
                await entryGate.waitIfNeeded()
                await handleRequest(
                    state: state,
                    admission: admission,
                    context: context
                )
            }
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
        context.read()
    }

    func channelInactive(context: ChannelHandlerContext) {
        finishActiveStream()
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            finishActiveStream()
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
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
        state: RequestState,
        admission: MCPHTTPAdmissionRegistry.Admission,
        context: ChannelHandlerContext
    ) async {
        defer { admissionRegistry.finish(admission) }
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
            let streamID = UUID()
            let registration = eventLoop.makePromise(of: Void.self)
            eventLoop.execute {
                guard context.channel.isActive else {
                    trackedResponse.streamCompletion?.finish()
                    registration.succeed(())
                    return
                }
                let streamTask = Task {
                    defer {
                        eventLoop.execute {
                            if self.activeStreamID == streamID {
                                self.activeStreamTask = nil
                                self.activeStreamID = nil
                                self.activeStreamCompletion = nil
                            }
                        }
                    }
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
                        trackedResponse.streamCompletion?.finish()
                        return
                    } catch {
                        trackedResponse.streamCompletion?.finish()
                        logger.error("MCP SSE stream failed: \(error.localizedDescription, privacy: .public)")
                    }

                    guard Task.isCancelled == false else {
                        return
                    }
                    try? await self.writeResponsePart(
                        .end(nil),
                        context: context,
                        eventLoop: eventLoop
                    )
                }
                context.channel.closeFuture.whenComplete { _ in
                    trackedResponse.streamCompletion?.finish()
                    streamTask.cancel()
                }
                self.activeStreamTask?.cancel()
                self.activeStreamCompletion?.finish()
                self.activeStreamTask = streamTask
                self.activeStreamID = streamID
                self.activeStreamCompletion = trackedResponse.streamCompletion
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
