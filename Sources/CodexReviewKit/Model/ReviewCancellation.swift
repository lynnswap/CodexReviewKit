package struct ReviewCancellation: Codable, Sendable, Hashable {
    package enum Source: String, Codable, Sendable, Hashable {
        case userInterface
        case mcpClient
        case sessionClosed
        case system
    }

    package var source: Source
    package var message: String

    package init(source: Source, message: String) {
        self.source = source
        self.message = message
    }

    package static func userInterface(
        message: String = "Cancelled by user from Review Monitor."
    ) -> ReviewCancellation {
        ReviewCancellation(source: .userInterface, message: message)
    }

    package static func mcpClient(
        message: String = "Cancellation requested by MCP client."
    ) -> ReviewCancellation {
        ReviewCancellation(source: .mcpClient, message: message)
    }

    package static func sessionClosed(
        message: String = "Cancellation requested because the MCP session closed."
    ) -> ReviewCancellation {
        ReviewCancellation(source: .sessionClosed, message: message)
    }

    package static func system(
        message: String = "Cancellation requested."
    ) -> ReviewCancellation {
        ReviewCancellation(source: .system, message: message)
    }
}
