import Foundation

package struct JSONRPCRequest: Equatable, Sendable {
    package var id: Int
    package var method: String
    package var params: Data

    package init(id: Int, method: String, params: Data) {
        self.id = id
        self.method = method
        self.params = params
    }
}

package struct JSONRPCNotification: Equatable, Sendable {
    package var method: String
    package var params: Data

    package init(method: String, params: Data) {
        self.method = method
        self.params = params
    }
}

package protocol JSONRPCTransport: Sendable {
    func send(_ request: JSONRPCRequest) async throws -> Data
    func notify(_ notification: JSONRPCNotification) async throws
    func notificationStream() async -> AsyncThrowingStream<JSONRPCNotification, Error>
    func close() async
}

package enum JSONRPCError: Error, Equatable, Sendable, LocalizedError {
    case closed
    case invalidMessage(String)
    case responseError(code: Int, message: String)

    package var errorDescription: String? {
        switch self {
        case .closed:
            "JSON-RPC transport is closed."
        case .invalidMessage(let message):
            "Invalid JSON-RPC message: \(message)"
        case .responseError(_, let message):
            message
        }
    }
}

package struct JSONRPCFramer: Sendable {
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
