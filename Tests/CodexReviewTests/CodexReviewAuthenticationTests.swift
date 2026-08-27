import Testing
@testable import CodexReview

@Suite("Codex review authentication")
struct CodexReviewAuthenticationTests {
    @Test func apiKeyValidatesAndRedactsItsDescription() async throws {
        let sentinel = "sk-sensitive-sentinel"
        let apiKey = try CodexReviewAPIKey(validating: sentinel)

        #expect(apiKey.description == "<redacted>")
        #expect(apiKey.debugDescription == "CodexReviewAPIKey(<redacted>)")
        #expect(apiKey.description.contains(sentinel) == false)
        #expect(apiKey.debugDescription.contains(sentinel) == false)
        #expect(await apiKey.withValue { $0 } == sentinel)
    }

    @Test func apiKeyRejectsEmptyAndSurroundingWhitespace() {
        #expect(throws: CodexReviewAPIKey.ValidationError.empty) {
            try CodexReviewAPIKey(validating: " \n")
        }
        #expect(throws: CodexReviewAPIKey.ValidationError.surroundingWhitespace) {
            try CodexReviewAPIKey(validating: " sk-test ")
        }
    }
}
