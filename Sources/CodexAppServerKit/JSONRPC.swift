import Foundation

package enum JSONRPC {
    package struct Request: Equatable, Sendable {
        package var id: Int
        package var method: String
        package var params: Data

        package init(id: Int, method: String, params: Data) {
            self.id = id
            self.method = method
            self.params = params
        }
    }

    package struct Notification: Equatable, Sendable {
        package var method: String
        package var params: Data

        package init(method: String, params: Data) {
            self.method = method
            self.params = params
        }
    }

    package enum InboundEvent: Equatable, Sendable {
        case notification(Notification)
        case serverRequest(
            id: CodexServerRequestID,
            method: String,
            params: Data
        )
    }

    package enum ProcessExitObservation: Equatable, Sendable {
        case unavailable
        case exited(status: Int32?, observedBeforeTermination: Bool)
        case failed(CodexTransportFailure)
    }

    package protocol Transport: Sendable {
        var connectionEventHub: ConnectionEventHub { get }
        func send(
            _ request: Request,
            acceptWrite: @Sendable () throws -> Void
        ) async throws -> Data
        func notify(_ notification: Notification) async throws
        func nextInboundEvent() async throws -> InboundEvent?
        func respond(
            to requestID: CodexServerRequestID,
            with response: CodexServerRequestResponse
        ) async throws
        func beginClose() async -> ProcessExitObservation?
        func finishPendingResponsesAfterInboundDrain(
            _ failure: CodexTransportFailure
        ) async
        func waitForProcessExit() async -> ProcessExitObservation
        func waitUntilClosed() async
        func reapProcess() async
    }

    package enum Error: Swift.Error, Equatable, Sendable, LocalizedError {
        case closed
        case invalidMessage(String)
        case responseError(CodexServerError)

        package var errorDescription: String? {
            switch self {
            case .closed:
                "JSON-RPC transport is closed."
            case .invalidMessage(let message):
                "Invalid JSON-RPC message: \(message)"
            case .responseError(let error):
                error.message
            }
        }
    }

    package struct OutboundWriteFailure: Swift.Error, Equatable, Sendable {
        package var failure: CodexTransportFailure

        package init(_ failure: CodexTransportFailure) {
            self.failure = failure
        }
    }

    package struct Framer: Sendable {
        package static let maximumFrameByteCount = 16 * 1_024 * 1_024

        private var buffer = Data()
        private let maximumFrameByteCount: Int

        package init(maximumFrameByteCount: Int = Self.maximumFrameByteCount) {
            precondition(maximumFrameByteCount > 0)
            self.maximumFrameByteCount = maximumFrameByteCount
        }

        package mutating func append(_ byte: UInt8) throws -> Data? {
            if byte == 0x0A {
                guard buffer.isEmpty == false else {
                    return nil
                }
                let frame = buffer
                buffer.removeAll(keepingCapacity: true)
                return frame
            }
            guard buffer.count < maximumFrameByteCount else {
                buffer.removeAll(keepingCapacity: false)
                throw CodexTransportFailure.framing(
                    message: "JSON-RPC frame exceeds \(maximumFrameByteCount) bytes.",
                    rawData: nil
                )
            }
            buffer.append(byte)
            return nil
        }

        package mutating func finish() -> Data? {
            guard buffer.isEmpty == false else {
                return nil
            }
            defer { buffer.removeAll(keepingCapacity: false) }
            return buffer
        }
    }
}

package extension JSONRPC.Transport {
    func send(_ request: JSONRPC.Request) async throws -> Data {
        try await send(request, acceptWrite: {})
    }
}

package struct AnyEncodable: Encodable {
    private let encodeValue: @Sendable (Encoder) throws -> Void

    package init<Value: Encodable & Sendable>(_ value: Value) {
        self.encodeValue = { encoder in
            try value.encode(to: encoder)
        }
    }

    package func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

package struct EmptyResponse: Codable, Equatable, Sendable {
    package init() {}
}
