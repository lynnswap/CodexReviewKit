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

    package struct NotificationReceipt: Comparable, Hashable, Sendable {
        package static let beforeFirst = Self(sequence: 0)

        package let sequence: UInt64

        package init(sequence: UInt64) {
            self.sequence = sequence
        }

        package static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.sequence < rhs.sequence
        }
    }

    package struct ReceivedNotification: Equatable, Sendable {
        package let receipt: NotificationReceipt
        package let notification: Notification

        package var method: String { notification.method }
        package var params: Data { notification.params }

        package init(receipt: NotificationReceipt, notification: Notification) {
            self.receipt = receipt
            self.notification = notification
        }
    }

    package protocol Transport: Sendable {
        func send(_ request: Request) async throws -> Data
        func notify(_ notification: Notification) async throws
        func notificationStream() async -> AsyncThrowingStream<ReceivedNotification, Swift.Error>
        func notificationHighWatermark() async -> NotificationReceipt
        func close() async throws
    }

    package enum Error: Swift.Error, Equatable, Sendable, LocalizedError {
        case closed
        case invalidMessage(String)
        case responseError(code: Int, message: String)
        case transportTerminated(TransportTermination)

        package var errorDescription: String? {
            switch self {
            case .closed:
                "JSON-RPC transport is closed."
            case .invalidMessage(let message):
                "Invalid JSON-RPC message: \(message)"
            case .responseError(_, let message):
                message
            case .transportTerminated(let termination):
                termination.localizedDescription
            }
        }
    }

    package enum TransportTermination: Equatable, Sendable, LocalizedError {
        case ownerClose
        case processExit(String)
        case processFailure(String)

        package var errorDescription: String? {
            switch self {
            case .ownerClose:
                "JSON-RPC transport was closed by its owner."
            case .processExit(let message), .processFailure(let message):
                message
            }
        }
    }

    package struct Framer: Sendable {
        private var buffer = Data()

        package init() {}

        package mutating func append(_ data: Data) -> [Data] {
            buffer.append(data)
            return drainLines()
        }

        package mutating func finish() -> [Data] {
            guard buffer.isEmpty == false else {
                return []
            }
            defer { buffer.removeAll(keepingCapacity: false) }
            return [buffer]
        }

        private mutating func drainLines() -> [Data] {
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                if line.isEmpty == false {
                    lines.append(Data(line))
                }
            }
            return lines
        }
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
