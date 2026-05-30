import Testing
@_spi(Testing) @testable import CodexReview

@Suite("Codex review auth model")
@MainActor
struct CodexReviewAuthModelTests {
    @Test func persistedSnapshotReusesDetachedSelectedAccountWithSameKey() {
        let auth = CodexReviewAuthModel()
        let detachedAccount = CodexAccount(email: "new@example.com", planType: "pro")
        auth.updateCurrentAccount(detachedAccount)

        let persistedPayload = savedAccountPayload(from: CodexAccount(email: "new@example.com", planType: "team"))
        auth.applyPersistedAccountStates([persistedPayload])

        #expect(auth.persistedAccounts.count == 1)
        #expect(auth.persistedAccounts.first === detachedAccount)
        #expect(auth.selectedAccount === detachedAccount)
        #expect(auth.selectedAccount?.planType == "team")
    }
}
