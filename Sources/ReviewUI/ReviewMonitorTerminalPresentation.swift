import CodexReview

struct ReviewMonitorTerminalPresentation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case requested(ReviewCancellation.Source)
        case server
        case transport
        case previousProcessExit
        case failed
    }

    var kind: Kind
    var text: String

    init?(
        terminal: ReviewTerminalRecord?,
        fallbackSummary: String? = nil
    ) {
        let fallbackSummary = fallbackSummary?.nilIfEmpty
        switch terminal {
        case .completed, nil:
            return nil
        case .interrupted(.requested(let cancellation)):
            kind = .requested(cancellation.source)
            text = cancellation.message.nilIfEmpty
                ?? fallbackSummary
                ?? Self.defaultCancellationMessage(for: cancellation.source)
        case .interrupted(.server(let message)):
            kind = .server
            text = message?.nilIfEmpty
                ?? fallbackSummary
                ?? "The review server stopped the review."
        case .interrupted(.transport(let message)):
            kind = .transport
            text = message.nilIfEmpty
                ?? fallbackSummary
                ?? "The review transport disconnected."
        case .interrupted(.previousProcessExit):
            kind = .previousProcessExit
            text = "The previous review process exited before completion."
        case .failed(let message):
            kind = .failed
            text = message?.nilIfEmpty
                ?? fallbackSummary
                ?? "Review failed."
        }
    }

    var requestedCancellationSource: ReviewCancellation.Source? {
        guard case .requested(let source) = kind else {
            return nil
        }
        return source
    }

    private static func defaultCancellationMessage(
        for source: ReviewCancellation.Source
    ) -> String {
        switch source {
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
