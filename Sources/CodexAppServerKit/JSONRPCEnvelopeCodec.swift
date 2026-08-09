import CoreFoundation
import Foundation
import Synchronization

package extension JSONRPC {
    enum RawInboundEnvelope: Sendable {
        case response(id: Int, Result<Data, JSONRPC.Error>)
        case event(InboundEvent)
    }

    static func decodeInboundEnvelope(_ data: Data) throws -> RawInboundEnvelope {
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CodexTransportFailure.protocolViolation(
                    message: "JSON-RPC envelope must be an object.",
                    rawData: data
                )
            }
            object = decoded
        } catch let failure as CodexTransportFailure {
            throw failure
        } catch {
            throw CodexTransportFailure.protocolViolation(
                message: "Invalid JSON-RPC envelope: \(error.localizedDescription)",
                rawData: data
            )
        }

        if let method = object["method"] as? String {
            let params = try payloadData(from: object["params"] ?? [:])
            if object.keys.contains("id") {
                guard let id = CodexServerRequestID(jsonObject: object["id"]) else {
                    throw CodexTransportFailure.protocolViolation(
                        message: "Server request \(method) has an invalid id.",
                        rawData: data
                    )
                }
                return .event(.serverRequest(id: id, method: method, params: params))
            }
            return .event(.notification(.init(method: method, params: params)))
        }

        guard let id = exactInteger(object["id"]) else {
            throw CodexTransportFailure.protocolViolation(
                message: "JSON-RPC response has no integer id.",
                rawData: data
            )
        }
        let hasResult = object.keys.contains("result")
        let hasError = object.keys.contains("error")
        guard hasResult != hasError else {
            throw CodexTransportFailure.protocolViolation(
                message: "JSON-RPC response must contain exactly one of result or error.",
                rawData: data
            )
        }
        if hasError {
            guard let errorObject = object["error"] as? [String: Any] else {
                throw CodexTransportFailure.protocolViolation(
                    message: "JSON-RPC response error must be an object.",
                    rawData: data
                )
            }
            guard let code = exactInteger(errorObject["code"]) else {
                throw CodexTransportFailure.protocolViolation(
                    message: "JSON-RPC response error code must be an integer.",
                    rawData: data
                )
            }
            guard let message = errorObject["message"] as? String else {
                throw CodexTransportFailure.protocolViolation(
                    message: "JSON-RPC response error message must be a string.",
                    rawData: data
                )
            }
            let rawData = try errorObject["data"].map(payloadData(from:))
            let turnError = rawData
                .flatMap { try? JSONDecoder().decode(AppServerAPI.Turn.Error.self, from: $0) }
                .map(CodexAppServer.turnError(from:))
            return .response(
                id: id,
                .failure(.responseError(.init(
                    code: code,
                    message: message,
                    data: rawData,
                    turnError: turnError
                )))
            )
        }
        let result = try payloadData(from: object["result"]!)
        return .response(id: id, .success(result))
    }

    static func responseFrame(
        id: Int,
        result: Result<Data, JSONRPC.Error>
    ) throws -> Data {
        let object: [String: Any]
        switch result {
        case .success(let data):
            object = [
                "id": id,
                "result": try JSONSerialization.jsonObject(
                    with: data,
                    options: [.fragmentsAllowed]
                ),
            ]
        case .failure(.responseError(let error)):
            var errorObject: [String: Any] = [
                "code": error.code,
                "message": error.message,
            ]
            if let data = error.data {
                errorObject["data"] = try JSONSerialization.jsonObject(
                    with: data,
                    options: [.fragmentsAllowed]
                )
            }
            object = ["id": id, "error": errorObject]
        case .failure(.closed):
            throw CodexTransportFailure.closed
        case .failure(.invalidMessage(let message)):
            throw CodexTransportFailure.protocolViolation(message: message, rawData: nil)
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func notificationFrame(_ notification: Notification) throws -> Data {
        let params = try JSONSerialization.jsonObject(
            with: notification.params,
            options: [.fragmentsAllowed]
        )
        return try JSONSerialization.data(withJSONObject: [
            "method": notification.method,
            "params": params,
        ])
    }

    static func serverRequestFrame(
        id: CodexServerRequestID,
        method: String,
        params: Data
    ) throws -> Data {
        let paramsObject = try JSONSerialization.jsonObject(
            with: params,
            options: [.fragmentsAllowed]
        )
        return try JSONSerialization.data(withJSONObject: [
            "id": id.jsonObject,
            "method": method,
            "params": paramsObject,
        ])
    }

    static func payloadData(from value: Any) throws -> Data {
        return try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }

    private static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let integer = number.int64Value
        guard number.doubleValue.isFinite,
              number.doubleValue == Double(integer) else {
            return nil
        }
        return Int(exactly: integer)
    }
}

package final class JSONRPCResponseWaiter: Sendable {
    private enum State {
        case pending(CheckedContinuation<Result<Data, JSONRPC.Error>, Never>?)
        case resolved(Result<Data, JSONRPC.Error>)
    }

    private let state = Mutex<State>(.pending(nil))

    package init() {}

    package func wait() async throws -> Data {
        let result = await withCheckedContinuation { continuation in
            let resolved = state.withLock {
                state -> Result<Data, JSONRPC.Error>? in
                switch state {
                case .pending(nil):
                    state = .pending(continuation)
                    return nil
                case .pending(.some):
                    preconditionFailure("JSON-RPC response waiter registered twice.")
                case .resolved(let result):
                    return result
                }
            }
            if let resolved {
                continuation.resume(returning: resolved)
            }
        }
        return try result.get()
    }

    @discardableResult
    package func resolve(_ result: Result<Data, JSONRPC.Error>) -> Bool {
        let resolution = state.withLock {
            state -> (Bool, CheckedContinuation<Result<Data, JSONRPC.Error>, Never>?) in
            switch state {
            case .pending(let continuation):
                state = .resolved(result)
                return (true, continuation)
            case .resolved:
                return (false, nil)
            }
        }
        resolution.1?.resume(returning: result)
        return resolution.0
    }
}
