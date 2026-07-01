import Darwin
import Foundation
import MCP
import OSLog
import Synchronization
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

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(CodexReviewMCPHTTPHandler(server: self))
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

    package func stop() async {
        cleanupTask?.cancel()
        cleanupTask = nil
        await closeAllSessions()
        try? await channel?.close()
        channel = nil
        if let eventLoopGroup {
            try? await eventLoopGroup.shutdownGracefully()
        }
        eventLoopGroup = nil
        boundURL = nil
        logger.info("MCP Streamable HTTP server stopped")
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
    }

    private struct RequestState {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }

    private let server: CodexReviewMCPHTTPServer
    private var requestState: RequestState?
    private var activeStreamTask: Task<Void, Never>?
    private var activeStreamID: UUID?
    private var activeStreamCompletion: ActiveRequestCompletion?

    init(server: CodexReviewMCPHTTPServer) {
        self.server = server
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
            Task {
                await handleRequest(state: state, context: context)
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
