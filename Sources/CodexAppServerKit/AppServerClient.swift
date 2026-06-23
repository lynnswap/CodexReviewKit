import Foundation
import OSLog

private let logger = Logger(subsystem: "CodexAppServerKit", category: "app-server-client")

package actor AppServerClient {
    private static let appServerOverloadedErrorCode = -32001
    private static let overloadRetryDelays: [Duration] = [
        .milliseconds(100),
        .milliseconds(250),
        .milliseconds(500),
    ]

    private let transport: any JSONRPC.Transport
    private let overloadRetryDelay: @Sendable (Int) -> Duration?
    private let retrySleep: @Sendable (Duration) async throws -> Void
    private let serializer = RequestSerializer()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var nextRequestID = 1
    private var initializationResponse: AppServerAPI.Initialize.Response?
    private var initializationTask: Task<AppServerAPI.Initialize.Response, Error>?

    package init(
        transport: any JSONRPC.Transport,
        overloadRetryDelay: @escaping @Sendable (Int) -> Duration? = AppServerClient
            .defaultOverloadRetryDelay,
        retrySleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.transport = transport
        self.overloadRetryDelay = overloadRetryDelay
        self.retrySleep = retrySleep
    }

    package func initialize(
        clientName: String = "CodexAppServerKit",
        clientVersion: String = "2"
    ) async throws -> AppServerAPI.Initialize.Response {
        if let initializationResponse {
            return initializationResponse
        }
        if let initializationTask {
            return try await initializationTask.value
        }
        let task = Task {
            try await self.performInitialize(clientName: clientName, clientVersion: clientVersion)
        }
        initializationTask = task
        do {
            let response = try await task.value
            initializationResponse = response
            initializationTask = nil
            return response
        } catch {
            initializationTask = nil
            throw error
        }
    }

    private func performInitialize(
        clientName: String,
        clientVersion: String
    ) async throws -> AppServerAPI.Initialize.Response {
        logger.info(
            "Initializing codex app-server connection as \(clientName, privacy: .public) \(clientVersion, privacy: .public)"
        )
        let response: AppServerAPI.Initialize.Response = try await send(
            AppServerAPI.Initialize.Request(
                params: .init(clientName: clientName, clientVersion: clientVersion)
            ))
        try await notify(method: "initialized", params: EmptyResponse())
        logger.info("codex app-server connection initialized")
        return response
    }

    package func send<Request: AppServerAPI.Request>(_ request: Request) async throws
        -> Request.Response
    {
        try await send(
            method: Request.method,
            params: request.params,
            responseType: Request.Response.self,
            scope: request.scope
        )
    }

    package func send<Params: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        params: Params,
        responseType: Response.Type,
        scope: AppServerAPI.RequestScope? = nil
    ) async throws -> Response {
        try await serializer.run(scope: scope) { [transport, encoder, decoder, self] in
            let encodedParams = try encoder.encode(params)
            var retryAttempt = 0
            while true {
                let requestID = await self.allocateRequestID()
                logger.debug(
                    "JSON-RPC request \(requestID, privacy: .public) -> \(method, privacy: .public)"
                )
                do {
                    let rawResponse = try await transport.send(
                        .init(
                            id: requestID,
                            method: method,
                            params: encodedParams
                        ))
                    let response = try decoder.decode(responseType, from: rawResponse)
                    logger.debug(
                        "JSON-RPC response \(requestID, privacy: .public) <- \(method, privacy: .public)"
                    )
                    return response
                } catch let error as JSONRPC.Error {
                    guard Self.isAppServerOverload(error),
                        let delay = overloadRetryDelay(retryAttempt)
                    else {
                        logger.error(
                            "JSON-RPC request \(requestID, privacy: .public) failed for \(method, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                        throw error
                    }
                    retryAttempt += 1
                    logger.warning(
                        "JSON-RPC request \(requestID, privacy: .public) overloaded for \(method, privacy: .public); retrying in \(String(describing: delay), privacy: .public)"
                    )
                    try await retrySleep(delay)
                } catch {
                    logger.error(
                        "JSON-RPC request \(requestID, privacy: .public) failed for \(method, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    throw error
                }
            }
        }
    }

    package func notify<Params: Encodable & Sendable>(
        method: String,
        params: Params
    ) async throws {
        let encodedParams = try encoder.encode(params)
        logger.debug("JSON-RPC notification -> \(method, privacy: .public)")
        try await transport.notify(
            .init(
                method: method,
                params: encodedParams
            ))
    }

    package func notificationStream() async -> AsyncThrowingStream<JSONRPC.Notification, Error> {
        await transport.notificationStream()
    }

    package func close() async {
        await transport.close()
    }

    private func allocateRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private nonisolated static func isAppServerOverload(_ error: JSONRPC.Error) -> Bool {
        if case .responseError(let code, _) = error {
            return code == appServerOverloadedErrorCode
        }
        return false
    }

    private nonisolated static func defaultOverloadRetryDelay(for retryAttempt: Int) -> Duration? {
        guard retryAttempt < overloadRetryDelays.count else {
            return nil
        }
        let base = overloadRetryDelays[retryAttempt]
        let jitter = Duration.milliseconds(Int.random(in: 0...50))
        return base + jitter
    }
}

package actor RequestSerializer {
    private var lanes: [AppServerAPI.RequestScope: SerialLane] = [:]

    package init() {}

    package func run<Output: Sendable>(
        scope: AppServerAPI.RequestScope?,
        operation: @Sendable () async throws -> Output
    ) async throws -> Output {
        guard let scope else {
            return try await operation()
        }
        let lane = lane(for: scope)
        await lane.enter()
        do {
            let output = try await operation()
            await lane.leave()
            return output
        } catch {
            await lane.leave()
            throw error
        }
    }

    private func lane(for scope: AppServerAPI.RequestScope) -> SerialLane {
        if let lane = lanes[scope] {
            return lane
        }
        let lane = SerialLane()
        lanes[scope] = lane
        return lane
    }
}

private actor SerialLane {
    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if isOccupied == false {
            isOccupied = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func leave() {
        if waiters.isEmpty {
            isOccupied = false
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}
