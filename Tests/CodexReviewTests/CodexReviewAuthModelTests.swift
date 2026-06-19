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

    @Test func switchRequestRequiresDifferentPersistedAccount() {
        let auth = CodexReviewAuthModel()
        let selectedAccount = CodexAccount(email: "selected@example.com", planType: "pro")
        let otherAccount = CodexAccount(email: "other@example.com", planType: "plus")
        let detachedAccount = CodexAccount(email: "detached@example.com", planType: "team")
        auth.applyPersistedAccountStates([
            savedAccountPayload(from: selectedAccount),
            savedAccountPayload(from: otherAccount),
        ])
        auth.selectPersistedAccount(selectedAccount.accountKey)

        #expect(auth.canRequestSwitchAccount(selectedAccount) == false)
        auth.requestSwitchAccount(selectedAccount, requiresConfirmation: false)
        #expect(auth.consumePendingAccountAction() == nil)

        #expect(auth.canRequestSwitchAccount(otherAccount))
        auth.requestSwitchAccount(otherAccount, requiresConfirmation: false)
        #expect(auth.consumePendingAccountAction() == .switchAccount(accountKey: otherAccount.accountKey))

        #expect(auth.canRequestSwitchAccount(detachedAccount) == false)
        auth.updateCurrentAccount(detachedAccount)
        #expect(auth.canRequestSwitchAccount(detachedAccount) == false)
        auth.requestSwitchAccount(detachedAccount, requiresConfirmation: false)
        #expect(auth.consumePendingAccountAction() == nil)
    }
}
