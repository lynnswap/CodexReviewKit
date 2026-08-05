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

    package var description: String {
        "<redacted>"
    }

    package var debugDescription: String {
        "CodexReviewAPIKey(<redacted>)"
    }
}

package enum CodexReviewAuthenticationMethod: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case chatGPT
    case apiKey(CodexReviewAPIKey)

    package var description: String {
        switch self {
        case .chatGPT:
            "chatGPT"
        case .apiKey:
            "apiKey(<redacted>)"
        }
    }

    package var debugDescription: String {
        "CodexReviewAuthenticationMethod.\(description)"
    }
}

package enum CodexReviewAuthenticationRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case signIn(using: CodexReviewAuthenticationMethod)
    case addAccount(using: CodexReviewAuthenticationMethod)

    package var method: CodexReviewAuthenticationMethod {
        switch self {
        case .signIn(let method), .addAccount(let method):
            method
        }
    }

    package var description: String {
        switch self {
        case .signIn(let method):
            "signIn(using: \(method))"
        case .addAccount(let method):
            "addAccount(using: \(method))"
        }
    }

    package var debugDescription: String {
        "CodexReviewAuthenticationRequest.\(description)"
    }
}
