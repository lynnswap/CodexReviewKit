import Foundation
import OSLog

private let logger = Logger(subsystem: "CodexReviewKit", category: "app-server-client")

package enum AppServerOverloadRetryAdmissionEvent: Sendable {
    case rejected(JSONRPC.Error)
    case willDispatch
}

package struct AppServerStartRequestFailure: LocalizedError, Equatable, Sendable {
    package enum Stage: String, Equatable, Sendable {
        case transport
        case responseDecoding
    }

    package var stage: Stage
    package var underlyingDescription: String

    package init(stage: Stage, underlyingDescription: String) {
        self.stage = stage
        self.underlyingDescription = underlyingDescription
    }

    package var errorDescription: String? {
        "App-server start request failed during \(stage.rawValue): \(underlyingDescription)"
    }
}

package struct AppServerCleanupRequestFailure: LocalizedError, Equatable, Sendable {
    package enum Stage: String, Equatable, Sendable {
        case transport
        case responseDecoding
    }

    package var stage: Stage
    package var underlyingDescription: String

    package init(stage: Stage, underlyingDescription: String) {
        self.stage = stage
        self.underlyingDescription = underlyingDescription
    }

    package var errorDescription: String? {
        "App-server cleanup request failed during \(stage.rawValue): \(underlyingDescription)"
    }
}

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
    private let serializer: RequestSerializer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var nextRequestID = 1
    private var initializationResponse: AppServerAPI.Initialize.Response?
    private var initializationTask: Task<AppServerAPI.Initialize.Response, Error>?

    package init(
        transport: any JSONRPC.Transport,
        overloadRetryDelay: @escaping @Sendable (Int) -> Duration? = AppServerClient.defaultOverloadRetryDelay,
        retrySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        serializer: RequestSerializer = .init()
    ) {
        self.transport = transport
        self.overloadRetryDelay = overloadRetryDelay
        self.retrySleep = retrySleep
        self.serializer = serializer
    }

    package func initialize(
        clientName: String = "CodexReviewKit",
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
        logger.info("Initializing codex app-server connection as \(clientName, privacy: .public) \(clientVersion, privacy: .public)")
        let response: AppServerAPI.Initialize.Response = try await send(AppServerAPI.Initialize.Request(
            params: .init(clientName: clientName, clientVersion: clientVersion)
        ))
        try await notify(method: "initialized", params: EmptyResponse())
        logger.info("codex app-server connection initialized")
        return response
    }

    package func send<Request: AppServerAPI.Request>(_ request: Request) async throws -> Request.Response {
        try await send(
            method: Request.method,
            params: request.params,
            responseType: Request.Response.self,
            scope: request.scope
        )
    }

    package func sendStartRequest<Request: AppServerAPI.Request>(
        _ request: Request,
        overloadRetryAdmission: @escaping @Sendable (
            AppServerOverloadRetryAdmissionEvent
        ) async throws -> Void
    ) async throws -> Request.Response {
        try await performSend(
            method: Request.method,
            params: request.params,
            responseType: Request.Response.self,
            scope: request.scope,
            failureKind: .start,
            overloadRetryAdmission: overloadRetryAdmission
        )
    }

    package func sendCleanupRequest<Request: AppServerAPI.Request>(
        _ request: Request
    ) async throws -> Request.Response {
        try await performSend(
            method: Request.method,
            params: request.params,
            responseType: Request.Response.self,
            scope: request.scope,
            failureKind: .cleanup,
            overloadRetryAdmission: nil
        )
    }

    package func send<Params: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        params: Params,
        responseType: Response.Type,
        scope: AppServerAPI.RequestScope? = nil
    ) async throws -> Response {
        try await performSend(
            method: method,
            params: params,
            responseType: responseType,
            scope: scope,
            failureKind: .none,
            overloadRetryAdmission: nil
        )
    }

    private func performSend<Params: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        params: Params,
        responseType: Response.Type,
        scope: AppServerAPI.RequestScope?,
        failureKind: FailureKind,
        overloadRetryAdmission: (@Sendable (AppServerOverloadRetryAdmissionEvent) async throws -> Void)?
    ) async throws -> Response {
        try await serializer.run(scope: scope) { [transport, encoder, decoder, self] in
            let encodedParams = try encoder.encode(params)
            var retryAttempt = 0
            while true {
                let requestID = await self.allocateRequestID()
                // Request params can contain credentials, including account/login/start API keys.
                // Keep diagnostics to request identity and method rather than payload values.
                logger.debug("JSON-RPC request \(requestID, privacy: .public) -> \(method, privacy: .public)")
                do {
                    let rawResponse: Data
                    do {
                        rawResponse = try await transport.send(.init(
                            id: requestID,
                            method: method,
                            params: encodedParams
                        ))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as JSONRPC.Error {
                        throw error
                    } catch {
                        switch failureKind {
                        case .none:
                            throw error
                        case .start:
                            logger.error(
                                "JSON-RPC transport failed for request \(requestID, privacy: .public) -> \(method, privacy: .public): \(error.localizedDescription, privacy: .public)"
                            )
                            throw AppServerStartRequestFailure(
                                stage: .transport,
                                underlyingDescription: error.localizedDescription
                            )
                        case .cleanup:
                            throw AppServerCleanupRequestFailure(
                                stage: .transport,
                                underlyingDescription: error.localizedDescription
                            )
                        }
                    }
                    let response: Response
                    do {
                        response = try decoder.decode(responseType, from: rawResponse)
                    } catch {
                        switch failureKind {
                        case .none:
                            throw error
                        case .start:
                            throw AppServerStartRequestFailure(
                                stage: .responseDecoding,
                                underlyingDescription: error.localizedDescription
                            )
                        case .cleanup:
                            throw AppServerCleanupRequestFailure(
                                stage: .responseDecoding,
                                underlyingDescription: error.localizedDescription
                            )
                        }
                    }
                    logger.debug("JSON-RPC response \(requestID, privacy: .public) <- \(method, privacy: .public)")
                    return response
                } catch let error as JSONRPC.Error {
                    guard Self.isAppServerOverload(error),
                          let delay = overloadRetryDelay(retryAttempt)
                    else {
                        logger.error("JSON-RPC request \(requestID, privacy: .public) failed for \(method, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        throw error
                    }
                    if let overloadRetryAdmission {
                        try await overloadRetryAdmission(.rejected(error))
                    }
                    retryAttempt += 1
                    logger.warning("JSON-RPC request \(requestID, privacy: .public) overloaded for \(method, privacy: .public); retrying in \(String(describing: delay), privacy: .public)")
                    try await retrySleep(delay)
                    if let overloadRetryAdmission {
                        try await overloadRetryAdmission(.willDispatch)
                    }
                } catch {
                    logger.error("JSON-RPC request \(requestID, privacy: .public) failed for \(method, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    throw error
                }
            }
        }
    }

    private enum FailureKind: Sendable {
        case none
        case start
        case cleanup
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

    package func notificationStream() async -> AsyncThrowingStream<JSONRPC.ReceivedNotification, Error> {
        await transport.notificationStream()
    }

    package func notificationHighWatermark() async -> JSONRPC.NotificationReceipt {
        await transport.notificationHighWatermark()
    }

    package func close() async throws {
        try await transport.close()
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
    private let waiterQueued: (@Sendable () -> Void)?
    private let waiterGranted: (@Sendable () async -> Void)?
    private var lanes: [AppServerAPI.RequestScope: SerialLane] = [:]

    package init(
        waiterQueued: (@Sendable () -> Void)? = nil,
        waiterGranted: (@Sendable () async -> Void)? = nil
    ) {
        self.waiterQueued = waiterQueued
        self.waiterGranted = waiterGranted
    }

    package func run<Output: Sendable>(
        scope: AppServerAPI.RequestScope?,
        operation: @Sendable () async throws -> Output
    ) async throws -> Output {
        guard let scope else {
            return try await operation()
        }
        let lane = lane(for: scope)
        let waitedForAdmission = try await lane.enter()
        do {
            if waitedForAdmission {
                try Task.checkCancellation()
            }
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
        let lane = SerialLane(
            waiterQueued: waiterQueued,
            waiterGranted: waiterGranted
        )
        lanes[scope] = lane
        return lane
    }
}

private actor SerialLane {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var isOccupied = false
    private var waiters: [Waiter] = []
    private let waiterQueued: (@Sendable () -> Void)?
    private let waiterGranted: (@Sendable () async -> Void)?

    init(
        waiterQueued: (@Sendable () -> Void)?,
        waiterGranted: (@Sendable () async -> Void)?
    ) {
        self.waiterQueued = waiterQueued
        self.waiterGranted = waiterGranted
    }

    func enter() async throws -> Bool {
        if isOccupied == false {
            isOccupied = true
            return false
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if isOccupied {
                    waiters.append(.init(id: waiterID, continuation: continuation))
                    waiterQueued?()
                } else {
                    isOccupied = true
                    continuation.resume()
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
        await waiterGranted?()
        do {
            try Task.checkCancellation()
        } catch {
            leave()
            throw error
        }
        return true
    }

    func leave() {
        if waiters.isEmpty {
            isOccupied = false
        } else {
            let next = waiters.removeFirst()
            next.continuation.resume()
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
