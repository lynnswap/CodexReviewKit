import Foundation
import Testing
@_spi(Testing) @testable import CodexReviewKit
import CodexReviewTesting

@Suite("Codex review authentication")
@MainActor
struct CodexReviewAuthenticationTests {
    @Test func apiKeyRejectsEmptyAndWhitespace() {
        #expect(throws: CodexReviewAPIKey.ValidationError.empty) {
            try CodexReviewAPIKey(validating: "")
        }
        for value in [" key", "key ", "\tkey", "key\n", "key\u{00a0}"] {
            #expect(throws: CodexReviewAPIKey.ValidationError.surroundingWhitespace) {
                try CodexReviewAPIKey(validating: value)
            }
        }
        #expect(throws: Never.self) {
            try CodexReviewAPIKey(validating: "key value")
        }
    }

    @Test func apiKeyDoesNotRequireAProviderPrefixAndRedactsDescriptions() async throws {
        let sentinel = "test-secret-without-provider-prefix"
        let apiKey = try CodexReviewAPIKey(validating: sentinel)

        #expect(String(describing: apiKey) == "<redacted>")
        #expect(String(reflecting: apiKey) == "CodexReviewAPIKey(<redacted>)")
        #expect(String(describing: CodexReviewAuthenticationMethod.apiKey(apiKey)).contains(sentinel) == false)
        #expect(String(reflecting: CodexReviewAuthenticationMethod.apiKey(apiKey)).contains(sentinel) == false)
        #expect(String(describing: CodexReviewAuthenticationRequest.signIn(using: .apiKey(apiKey))).contains(sentinel) == false)

        let observed = await apiKey.withValue { value in
            value == sentinel
        }
        #expect(observed)
    }

    @Test func storeForwardsAuthenticationPurposeAndProviderWithoutRecordingSecret() async throws {
        let sentinel = "test-secret-store-forwarding"
        let apiKey = try CodexReviewAPIKey(validating: sentinel)
        let backend = TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        try await store.signIn(using: .apiKey(apiKey))
        #expect(backend.authenticationCommands == [.signInWithAPIKey])
        #expect(store.auth.progress?.detail == "Authenticating with API key.")
        #expect(String(describing: store.auth.phase).contains(sentinel) == false)

        await store.cancelAuthentication()
        try await store.addAccount(using: .apiKey(apiKey))
        #expect(backend.authenticationCommands == [.signInWithAPIKey, .addAPIKeyAccount])
        #expect(String(describing: backend.authenticationCommands).contains(sentinel) == false)
    }
}
