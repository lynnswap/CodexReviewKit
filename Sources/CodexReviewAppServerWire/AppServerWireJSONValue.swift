import Foundation

public indirect enum AppServerWireJSONValue: Decodable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: AppServerWireJSONValue])
    case array([AppServerWireJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: AppServerWireJSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([AppServerWireJSONValue].self))
        }
    }

    public var objectValue: [String: AppServerWireJSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    public var nonNullText: String? {
        switch self {
        case .null:
            return nil
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        case .object, .array:
            return jsonString
        }
    }

    public var jsonString: String {
        let fallback: String
        switch self {
        case .object:
            fallback = "{}"
        case .array:
            fallback = "[]"
        case .string(let value):
            fallback = value
        case .int(let value):
            fallback = String(value)
        case .double(let value):
            fallback = String(value)
        case .bool(let value):
            fallback = String(value)
        case .null:
            fallback = "null"
        }
        return Self.jsonText(foundationObject, fallback: fallback)
    }

    private var foundationObject: Any {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues(\.foundationObject)
        case .array(let value):
            return value.map(\.foundationObject)
        case .null:
            return NSNull()
        }
    }

    private static func jsonText(_ object: Any, fallback: String) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.fragmentsAllowed, .sortedKeys]
        ),
              let text = String(data: data, encoding: .utf8)
        else {
            return fallback
        }
        return text
    }
}
