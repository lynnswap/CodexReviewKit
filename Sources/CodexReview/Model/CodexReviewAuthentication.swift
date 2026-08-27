import Foundation

package struct CodexReviewAPIKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    package enum ValidationError: Error, Equatable, LocalizedError, Sendable {
        case empty
        case surroundingWhitespace

        package var errorDescription: String? {
            switch self {
            case .empty:
                "Enter an API key."
            case .surroundingWhitespace:
                "API keys cannot begin or end with whitespace."
            }
        }
    }

    private let storage: String

    package init(validating value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw ValidationError.empty
        }
        guard trimmed == value else {
            throw ValidationError.surroundingWhitespace
        }
        storage = value
    }

    package func withValue<Result: Sendable>(
        _ operation: @Sendable (String) async throws -> Result
    ) async rethrows -> Result {
        try await operation(storage)
    }

    package var description: String { "<redacted>" }
    package var debugDescription: String { "CodexReviewAPIKey(<redacted>)" }
}

package enum CodexReviewAuthenticationMethod: Sendable {
    case chatGPT
    case apiKey(CodexReviewAPIKey)
}
