import Foundation
import OSLog

private let logger = Logger(subsystem: "CodexReviewKit", category: "app-server-client")

package actor AppServerClient {
    private let transport: any JSONRPCTransport
    private let serializer = RequestSerializer()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var nextRequestID = 1
    private var initializationResponse: InitializeResponse?
    private var initializationTask: Task<InitializeResponse, Error>?

    package init(transport: any JSONRPCTransport) {
        self.transport = transport
    }

    package func initialize(
        clientName: String = "CodexReviewKit",
        clientVersion: String = "2"
    ) async throws -> InitializeResponse {
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
    ) async throws -> InitializeResponse {
        logger.info("Initializing codex app-server connection as \(clientName, privacy: .public) \(clientVersion, privacy: .public)")
        let response: InitializeResponse = try await send(InitializeRequest(
            params: .init(clientName: clientName, clientVersion: clientVersion)
        ))
        try await notify(method: "initialized", params: EmptyResponse())
        logger.info("codex app-server connection initialized")
        return response
    }

    package func send<Request: AppServerRequest>(_ request: Request) async throws -> Request.Response {
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
        scope: AppServerRequestScope? = nil
    ) async throws -> Response {
        let requestID = allocateRequestID()
        logger.debug("JSON-RPC request \(requestID, privacy: .public) -> \(method, privacy: .public)")
        return try await serializer.run(scope: scope) { [transport, encoder, decoder] in
            let encodedParams = try encoder.encode(params)
            do {
                let rawResponse = try await transport.send(.init(
                    id: requestID,
                    method: method,
                    params: encodedParams
                ))
                let response = try decoder.decode(responseType, from: rawResponse)
                logger.debug("JSON-RPC response \(requestID, privacy: .public) <- \(method, privacy: .public)")
                return response
            } catch {
                logger.error("JSON-RPC request \(requestID, privacy: .public) failed for \(method, privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
    }

    package func notify<Params: Encodable & Sendable>(
        method: String,
        params: Params
    ) async throws {
        let encodedParams = try encoder.encode(params)
        logger.debug("JSON-RPC notification -> \(method, privacy: .public)")
        try await transport.notify(.init(
            method: method,
            params: encodedParams
        ))
    }

    package func notificationStream() async -> AsyncThrowingStream<JSONRPCNotification, Error> {
        await transport.notificationStream()
    }

    package func close() async {
        await transport.close()
    }

    private func allocateRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }
}

package actor RequestSerializer {
    private var lanes: [AppServerRequestScope: SerialLane] = [:]

    package init() {}

    package func run<Output: Sendable>(
        scope: AppServerRequestScope?,
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

    private func lane(for scope: AppServerRequestScope) -> SerialLane {
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
