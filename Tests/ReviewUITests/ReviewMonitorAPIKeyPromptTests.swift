import AppKit
import Testing
import CodexReview
@testable import ReviewUI

@Suite("API key prompt")
@MainActor
struct ReviewMonitorAPIKeyPromptTests {
    @Test func consumeClearsValidInputAndReturnsARedactedKey() throws {
        let field = NSSecureTextField()
        let sentinel = "sk-secure-field-sentinel"
        field.stringValue = sentinel

        let apiKey = try ReviewMonitorAPIKeyPrompt.consume(field)

        #expect(field.stringValue.isEmpty)
        #expect(apiKey.description == "<redacted>")
        #expect(apiKey.description.contains(sentinel) == false)
    }

    @Test func consumeClearsInvalidInputBeforeReportingValidation() {
        let field = NSSecureTextField()
        field.stringValue = " invalid "

        #expect(throws: CodexReviewAPIKey.ValidationError.surroundingWhitespace) {
            try ReviewMonitorAPIKeyPrompt.consume(field)
        }
        #expect(field.stringValue.isEmpty)
    }
}
