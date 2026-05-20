public enum ReviewCancellationSource: String, Codable, Sendable, Hashable {
    case userInterface
    case mcpClient
    case sessionClosed
    case system
}

public struct ReviewCancellation: Codable, Sendable, Hashable {
    public var source: ReviewCancellationSource
    public var message: String

    public init(source: ReviewCancellationSource, message: String) {
        self.source = source
        self.message = message
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
}
