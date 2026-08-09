import Foundation
import OSLog

private let logger = Logger(subsystem: "CodexAppServerKit", category: "app-server-client")

package actor AppServerClient {
    private struct InitializationContract: Equatable {
        var clientName: String
        var clientVersion: String
    }

    private enum InitializationState {
        case idle
        case inFlight(
            contract: InitializationContract,
            waiters: [CheckedContinuation<AppServerAPI.Initialize.Response, any Error>]
        )
        case complete(AppServerAPI.Initialize.Response)
    }

    private static let appServerOverloadedErrorCode = -32001
    private static let overloadRetryDelays: [Duration] = [
        .milliseconds(100),
        .milliseconds(250),
        .milliseconds(500),
    ]

    private let transport: any JSONRPC.Transport
    package nonisolated let connectionEventHub: ConnectionEventHub
    private let overloadRetryDelay: @Sendable (Int) -> Duration?
    private let retrySleep: @Sendable (Duration) async throws -> Void
    private let deadlines: CodexAppServer.Configuration.Deadlines
    private let deadlineClock: CodexDeadlineClock
    private let connectionCloseAction: ConnectionCloseAction
    private let serializer = RequestSerializer()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var nextRequestID = 1
    private var initializationState = InitializationState.idle

    package init(
        transport: any JSONRPC.Transport,
        deadlines: CodexAppServer.Configuration.Deadlines = .init(),
        deadlineClock: CodexDeadlineClock = .continuous,
        connectionCloseAction: ConnectionCloseAction,
        overloadRetryDelay: @escaping @Sendable (Int) -> Duration? = AppServerClient
            .defaultOverloadRetryDelay,
        retrySleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.transport = transport
        self.connectionEventHub = transport.connectionEventHub
        self.deadlines = deadlines
        self.deadlineClock = deadlineClock
        self.connectionCloseAction = connectionCloseAction
        self.overloadRetryDelay = overloadRetryDelay
        self.retrySleep = retrySleep
    }

    package func initialize(
        clientName: String = "CodexAppServerKit",
        clientVersion: String = "2"
    ) async throws -> AppServerAPI.Initialize.Response {
        let contract = InitializationContract(
            clientName: clientName,
            clientVersion: clientVersion
        )
        switch initializationState {
        case .complete(let response):
            return response
        case .inFlight(let existingContract, var waiters):
            precondition(
                existingContract == contract,
                "Concurrent initialization must use the same client name and version."
            )
            return try await withCheckedThrowingContinuation { continuation in
                waiters.append(continuation)
                initializationState = .inFlight(
                    contract: existingContract,
                    waiters: waiters
                )
            }
        case .idle:
            initializationState = .inFlight(contract: contract, waiters: [])
        }

        do {
            let response = try await performInitialize(
                clientName: clientName,
                clientVersion: clientVersion
            )
            finishInitialization(with: .success(response))
            return response
        } catch {
            finishInitialization(with: .failure(error))
            throw error
        }
    }

    package func sleepForInterruptRace(_ duration: Duration) async throws {
        try await deadlineClock.sleep(duration)
    }

    package func initializationWaiterCountForTesting() -> Int {
        guard case .inFlight(_, let waiters) = initializationState else {
            return 0
        }
        return waiters.count
    }

    private func finishInitialization(
        with result: Result<AppServerAPI.Initialize.Response, any Error>
    ) {
        guard case .inFlight(_, let waiters) = initializationState else {
            preconditionFailure("Initialization completed without an in-flight owner.")
        }
        switch result {
        case .success(let response):
            initializationState = .complete(response)
        case .failure:
            initializationState = .idle
        }
        for waiter in waiters {
            waiter.resume(with: result)
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
            ),
            purpose: .handshake,
            deadline: deadlines.handshake ?? deadlines.request,
            afterResponse: { [transport, encoder] _ in
                let params = try encoder.encode(EmptyResponse())
                try await transport.notify(.init(method: "initialized", params: params))
            }
        )
        logger.info("codex app-server connection initialized")
        return response
    }

    package func send<Request: AppServerAPI.Request>(
        _ request: Request,
        reconcileResponse: @escaping @Sendable (Request.Response) async throws -> Void = { _ in },
        onWriteAccepted: @escaping @Sendable () -> Void = {},
        onResponseRejected: @escaping @Sendable () async throws -> Void = {},
        onResponseAccepted: @escaping @Sendable () -> Void = {},
        retriesOverloadResponses: Bool = true,
        postWriteCallerCancellationPolicy: RequestOperationState
            .PostWriteCallerCancellationPolicy = .performCleanup,
        onPostWriteCancellation: @escaping @Sendable (Request.Response) async throws -> Void = { _ in }
    ) async throws -> Request.Response {
        try await send(
            method: Request.method,
            params: request.params,
            responseType: Request.Response.self,
            scope: request.scope,
            purpose: .operation(Request.method),
            deadline: deadlines.request,
            reconcileResponse: reconcileResponse,
            onWriteAccepted: onWriteAccepted,
            onResponseRejected: onResponseRejected,
            onResponseAccepted: onResponseAccepted,
            retriesOverloadResponses: retriesOverloadResponses,
            postWriteCallerCancellationPolicy: postWriteCallerCancellationPolicy,
            onPostWriteCancellation: onPostWriteCancellation
        )
    }

    private func send<Request: AppServerAPI.Request>(
        _ request: Request,
        purpose: CodexRequestPurpose,
        deadline: Duration?,
        afterResponse: @escaping @Sendable (Request.Response) async throws -> Void
    ) async throws -> Request.Response {
        try await send(
            method: Request.method,
            params: request.params,
            responseType: Request.Response.self,
            scope: request.scope,
            purpose: purpose,
            deadline: deadline,
            afterResponse: afterResponse
        )
    }

    package func send<Params: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        params: Params,
        responseType: Response.Type,
        scope: AppServerAPI.RequestScope? = nil,
        purpose: CodexRequestPurpose? = nil,
        deadline: Duration? = nil,
        reconcileResponse: @escaping @Sendable (Response) async throws -> Void = { _ in },
        afterResponse: @escaping @Sendable (Response) async throws -> Void = { _ in },
        onWriteAccepted: @escaping @Sendable () -> Void = {},
        onResponseRejected: @escaping @Sendable () async throws -> Void = {},
        onResponseAccepted: @escaping @Sendable () -> Void = {},
        retriesOverloadResponses: Bool = true,
        postWriteCallerCancellationPolicy: RequestOperationState
            .PostWriteCallerCancellationPolicy = .performCleanup,
        onPostWriteCancellation: @escaping @Sendable (Response) async throws -> Void = { _ in }
    ) async throws -> Response {
        try await serializer.run(scope: scope) { [encoder, self] laneToken in
            let requestID = await self.allocateRequestID()
            let requestPurpose = purpose ?? .operation(method)
            let encodedParams: Data
            do {
                encodedParams = try encoder.encode(params)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CodexAppServerError.request(.init(
                    requestID: requestID,
                    method: method,
                    purpose: requestPurpose,
                    kind: .encode(message: error.localizedDescription)
                ))
            }
            let initialRequestID = requestID
            let state = RequestOperationState()
            let operation = { @Sendable [self] in
                let response = try await performRequestWithRetries(
                    initialRequestID: initialRequestID,
                    method: method,
                    encodedParams: encodedParams,
                    responseType: responseType,
                    purpose: requestPurpose,
                    reconcileResponse: reconcileResponse,
                    afterResponse: afterResponse,
                    onWriteAccepted: onWriteAccepted,
                    onResponseRejected: onResponseRejected,
                    onResponseAccepted: onResponseAccepted,
                    retriesOverloadResponses: retriesOverloadResponses,
                    operationState: state
                )
                state.markResponseBound()
                switch state.resolveResponse(
                    postWriteCallerCancellationPolicy: postWriteCallerCancellationPolicy
                ) {
                case .returnResponse:
                    return response
                case .performCleanup(let abandonment):
                    try await serializer.runCleanup(using: laneToken) {
                        try await onPostWriteCancellation(response)
                    }
                    state.markCleanupComplete()
                    throw abandonment
                }
            }
            return try await withTaskCancellationHandler {
                let operationTask = Task {
                    do {
                        guard let deadline else {
                            return try await operation()
                        }
                        do {
                            return try await self.runRequestWithDeadline(
                                deadline,
                                operationState: state,
                                operation: operation
                            )
                        } catch is RequestDeadlineExpired {
                            throw CodexAppServerError.request(.init(
                                requestID: initialRequestID,
                                method: method,
                                purpose: requestPurpose,
                                kind: .deadlineExceeded(deadline)
                            ))
                        }
                    } catch RequestOperationAbandonment.callerCancellation {
                        throw CancellationError()
                    } catch RequestOperationAbandonment.deadline {
                        throw RequestDeadlineExpired()
                    } catch {
                        if state.preWriteCancellationShouldWin() {
                            throw CancellationError()
                        }
                        throw error
                    }
                }
                return try await operationTask.value
            } onCancel: {
                state.requestCancellation()
            }
        }
    }

    private func performRequestWithRetries<Response: Decodable & Sendable>(
        initialRequestID: Int,
        method: String,
        encodedParams: Data,
        responseType: Response.Type,
        purpose: CodexRequestPurpose,
        reconcileResponse: @escaping @Sendable (Response) async throws -> Void,
        afterResponse: @escaping @Sendable (Response) async throws -> Void,
        onWriteAccepted: @escaping @Sendable () -> Void,
        onResponseRejected: @escaping @Sendable () async throws -> Void,
        onResponseAccepted: @escaping @Sendable () -> Void,
        retriesOverloadResponses: Bool,
        operationState: RequestOperationState
    ) async throws -> Response {
        var requestID = initialRequestID
        var retryAttempt = 0
        while true {
            let attemptRequestID = requestID
            logger.debug(
                "JSON-RPC request \(attemptRequestID, privacy: .public) -> \(method, privacy: .public)"
            )
            do {
                let rawResponse: Data
                do {
                    rawResponse = try await transport.send(
                        .init(
                            id: attemptRequestID,
                            method: method,
                            params: encodedParams
                        ),
                        acceptWrite: {
                            try operationState.acceptWrite()
                            onWriteAccepted()
                        }
                    )
                } catch let abandonment as RequestOperationAbandonment {
                    throw abandonment
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as JSONRPC.Error {
                    throw error
                } catch let error as JSONRPC.OutboundWriteFailure {
                    throw CodexAppServerError.request(.init(
                        requestID: attemptRequestID,
                        method: method,
                        purpose: purpose,
                        kind: .write(error.failure)
                    ))
                } catch {
                    throw CodexAppServerError.request(.init(
                        requestID: attemptRequestID,
                        method: method,
                        purpose: purpose,
                        kind: .transport(Self.transportFailure(from: error))
                    ))
                }
                let response: Response
                do {
                    response = try decoder.decode(responseType, from: rawResponse)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try await reconcileRejectedResponse(using: onResponseRejected)
                    throw CodexAppServerError.request(.init(
                        requestID: attemptRequestID,
                        method: method,
                        purpose: purpose,
                        kind: .invalidResponse(
                            expectedType: String(reflecting: responseType),
                            message: error.localizedDescription,
                            rawData: rawResponse
                        )
                    ))
                }
                do {
                    try await reconcileResponse(response)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as CodexAppServerError {
                    if case .connectionTerminated = error {
                        throw error
                    }
                    let failure = CodexTransportFailure.protocolViolation(
                        message: "Response reconciliation failed: \(error.localizedDescription)",
                        rawData: rawResponse
                    )
                    await connectionCloseAction.failConnection(with: failure)
                    throw CodexAppServerError.connectionTerminated(.transportFailure(failure))
                } catch {
                    let failure = (error as? CodexTransportFailure) ?? .protocolViolation(
                        message: "Response reconciliation failed: \(error.localizedDescription)",
                        rawData: rawResponse
                    )
                    await connectionCloseAction.failConnection(with: failure)
                    throw CodexAppServerError.connectionTerminated(.transportFailure(failure))
                }
                do {
                    try await afterResponse(response)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try await reconcileRejectedResponse(using: onResponseRejected)
                    throw CodexAppServerError.request(.init(
                        requestID: attemptRequestID,
                        method: method,
                        purpose: purpose,
                        kind: .write(Self.transportFailure(from: error))
                    ))
                }
                onResponseAccepted()
                logger.debug(
                    "JSON-RPC response \(attemptRequestID, privacy: .public) <- \(method, privacy: .public)"
                )
                return response
            } catch is CancellationError {
                throw CancellationError()
            } catch let abandonment as RequestOperationAbandonment {
                throw abandonment
            } catch let error as JSONRPC.Error {
                if case .responseError = error {
                    try await reconcileRejectedResponse(using: onResponseRejected)
                }
                if case .responseError(let serverError) = error,
                   serverError.code == Self.appServerOverloadedErrorCode,
                   retriesOverloadResponses {
                    guard let delay = overloadRetryDelay(retryAttempt) else {
                        throw CodexAppServerError.request(.init(
                            requestID: attemptRequestID,
                            method: method,
                            purpose: purpose,
                            kind: .overloadRetryExhausted(
                                last: serverError,
                                attempts: retryAttempt + 1
                            )
                        ))
                    }
                    retryAttempt += 1
                    connectionEventHub.yield(.retrying(.init(
                        requestID: attemptRequestID,
                        method: method,
                        attempt: retryAttempt,
                        delay: delay,
                        serverError: serverError
                    )))
                    logger.warning(
                        "JSON-RPC request \(attemptRequestID, privacy: .public) overloaded for \(method, privacy: .public); retrying in \(String(describing: delay), privacy: .public)"
                    )
                    try await waitForRetryDelay(
                        delay,
                        operationState: operationState
                    )
                    requestID = allocateRequestID()
                    continue
                }
                switch error {
                case .responseError(let serverError):
                    throw CodexAppServerError.request(.init(
                        requestID: attemptRequestID,
                        method: method,
                        purpose: purpose,
                        kind: .server(serverError)
                    ))
                case .closed:
                    throw CodexAppServerError.connectionTerminated(.transportFailure(.closed))
                case .invalidMessage(let message):
                    throw CodexAppServerError.connectionTerminated(.transportFailure(
                        .protocolViolation(message: message, rawData: nil)
                    ))
                }
            } catch let error as CodexAppServerError {
                throw error
            } catch {
                throw CodexAppServerError.request(.init(
                    requestID: attemptRequestID,
                    method: method,
                    purpose: purpose,
                    kind: .transport(Self.transportFailure(from: error))
                ))
            }
        }
    }

    private func reconcileRejectedResponse(
        using action: @escaping @Sendable () async throws -> Void
    ) async throws {
        do {
            try await action()
        } catch let error as CodexAppServerError {
            if case .connectionTerminated = error {
                throw error
            }
            let failure = CodexTransportFailure.protocolViolation(
                message: "Response rejection reconciliation failed: \(error.localizedDescription)",
                rawData: nil
            )
            await connectionCloseAction.failConnection(with: failure)
            throw CodexAppServerError.connectionTerminated(.transportFailure(failure))
        } catch {
            let failure = CodexTransportFailure.protocolViolation(
                message: "Response rejection reconciliation failed: \(error.localizedDescription)",
                rawData: nil
            )
            await connectionCloseAction.failConnection(with: failure)
            throw CodexAppServerError.connectionTerminated(.transportFailure(failure))
        }
    }

    package func requestLaneCountForTesting() async -> Int {
        await serializer.laneCountForTesting()
    }

    package func queuedRequestCountForTesting(
        scope: AppServerAPI.RequestScope
    ) async -> Int {
        await serializer.queuedWaiterCountForTesting(scope: scope)
    }

    package func waitForQueuedRequestCountForTesting(
        scope: AppServerAPI.RequestScope,
        atLeast minimumCount: Int
    ) async throws {
        try await serializer.waitForQueuedWaiterCountForTesting(
            scope: scope,
            atLeast: minimumCount
        )
    }
    package func runTurnWithDeadline<Output: Sendable>(
        turnID: CodexTurnID,
        duration: Duration,
        operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        do {
            return try await runWithDeadline(duration, operation: operation)
        } catch is RequestDeadlineExpired {
            throw CodexAppServerError.turnDeadlineExceeded(
                turnID: turnID,
                duration: duration
            )
        }
    }

    private func allocateRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func runWithDeadline<Output: Sendable>(
        _ deadline: Duration,
        operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        try await withThrowingTaskGroup(of: DeadlineRace<Output>.self) { group in
            group.addTask { .value(try await operation()) }
            group.addTask { [deadlineClock] in
                try await deadlineClock.sleep(deadline)
                return .expired
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                preconditionFailure("Deadline race must have a winner.")
            }
            switch result {
            case .value(let value):
                return value
            case .expired:
                throw RequestDeadlineExpired()
            }
        }
    }

    private func runRequestWithDeadline<Output: Sendable>(
        _ deadline: Duration,
        operationState: RequestOperationState,
        operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        try await withThrowingTaskGroup(of: DeadlineRace<Output>.self) { group in
            group.addTask { .value(try await operation()) }
            group.addTask { [deadlineClock] in
                try await deadlineClock.sleep(deadline)
                return .expired
            }
            var deadlineWon = false
            while true {
                let result: DeadlineRace<Output>
                do {
                    guard let next = try await group.next() else {
                        preconditionFailure("Deadline race must have a winner.")
                    }
                    result = next
                } catch {
                    if deadlineWon {
                        throw RequestDeadlineExpired()
                    }
                    throw error
                }
                switch result {
                case .value(let value):
                    group.cancelAll()
                    return value
                case .expired:
                    switch operationState.requestDeadline() {
                    case .ignored:
                        continue
                    case .awaitPreWriteExit:
                        deadlineWon = true
                    case .closeConnection:
                        deadlineWon = true
                        await connectionCloseAction.closeConnection()
                    }
                }
            }
        }
    }

    private func waitForRetryDelay(
        _ delay: Duration,
        operationState: RequestOperationState
    ) async throws {
        try operationState.beginRetryWait()
        let retrySleep = self.retrySleep
        try await withThrowingTaskGroup(of: RetryDelayRace.self) { group in
            group.addTask {
                try await retrySleep(delay)
                return .delayElapsed
            }
            group.addTask {
                if let abandonment = await operationState.waitForAbandonment() {
                    return .abandoned(abandonment)
                }
                return .waiterCancelled
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                preconditionFailure("A retry delay race must have a winner.")
            }
            switch result {
            case .delayElapsed:
                break
            case .abandoned(let abandonment):
                throw abandonment
            case .waiterCancelled:
                try Task.checkCancellation()
                preconditionFailure("An active retry abandonment waiter cannot end without a signal.")
            }
        }
        try operationState.finishRetryWait()
    }

    private nonisolated static func transportFailure(from error: Error) -> CodexTransportFailure {
        if let failure = error as? CodexTransportFailure {
            return failure
        }
        if let posixError = error as? POSIXError {
            return .io(errno: posixError.code.rawValue, message: posixError.localizedDescription)
        }
        return .io(errno: nil, message: error.localizedDescription)
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

private enum DeadlineRace<Value: Sendable>: Sendable {
    case value(Value)
    case expired
}

private enum RetryDelayRace: Sendable {
    case delayElapsed
    case abandoned(RequestOperationAbandonment)
    case waiterCancelled
}

private struct RequestDeadlineExpired: Error, Sendable {}
