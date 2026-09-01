public struct ReviewCancellation: Codable, Sendable, Hashable {
    public enum Source: String, Codable, Sendable, Hashable {
        case userInterface
        case mcpClient
        case sessionClosed
        case system
    }

    public var source: Source
    private var storedMessage: String
    public var message: String {
        get { storedMessage }
        set { storedMessage = Self.normalizedMessage(newValue, source: source) }
    }

    public init(source: Source, message: String) {
        self.source = source
        self.storedMessage = Self.normalizedMessage(message, source: source)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            source: try container.decode(Source.self, forKey: .source),
            message: try container.decode(String.self, forKey: .message)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(message, forKey: .message)
    }

    public static func userInterface(
        message: String = "Cancelled by user from Review Monitor."
    ) -> ReviewCancellation {
        ReviewCancellation(source: .userInterface, message: message)
    }

    public static func mcpClient(
        message: String = "Cancellation requested by MCP client."
    ) -> ReviewCancellation {
        ReviewCancellation(source: .mcpClient, message: message)
    }

    public static func sessionClosed(
        message: String = "Cancellation requested because the MCP session closed."
    ) -> ReviewCancellation {
        ReviewCancellation(source: .sessionClosed, message: message)
    }

    public static func system(
        message: String = "Cancellation requested."
    ) -> ReviewCancellation {
        ReviewCancellation(source: .system, message: message)
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case message
    }

    private static func normalizedMessage(
        _ message: String,
        source: Source
    ) -> String {
        guard message.allSatisfy(\.isWhitespace) else {
            return message
        }
        return switch source {
        case .userInterface:
            "Cancelled by user from Review Monitor."
        case .mcpClient:
            "Cancellation requested by MCP client."
        case .sessionClosed:
            "Cancellation requested because the MCP session closed."
        case .system:
            "Cancellation requested."
        }
    }
}
