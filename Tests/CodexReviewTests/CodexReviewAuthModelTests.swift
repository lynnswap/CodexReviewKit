import Foundation
import Testing
@_spi(Testing) @testable import CodexReview

@Suite("Codex review auth model")
@MainActor
struct CodexReviewAuthModelTests {
    @Test func observedAuthenticationMetadataPreservesSupportedRateLimitState() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let persistedAccount = CodexAccount(
            accountKey: "review@example.com",
            email: "Old Label",
            planType: "plus"
        )
        persistedAccount.updateRateLimits([
            (
                windowDurationMinutes: 300,
                usedPercent: 40,
                resetsAt: fetchedAt.addingTimeInterval(300)
            ),
        ])
        persistedAccount.updateRateLimitFetchMetadata(
            fetchedAt: fetchedAt,
            error: "Cached rate-limit failure."
        )

        let preparedAccount = try #require(preparedCodexAccount(
            from: .init(
                id: .init("review@example.com"),
                label: "Updated Label",
                planType: "pro"
            ),
            preservingRateLimitStateFrom: [persistedAccount]
        ))

        #expect(preparedAccount !== persistedAccount)
        #expect(preparedAccount.email == "Updated Label")
        #expect(preparedAccount.planType == "pro")
        #expect(preparedAccount.rateLimits.first?.usedPercent == 40)
        #expect(preparedAccount.lastRateLimitFetchAt == fetchedAt)
        #expect(preparedAccount.lastRateLimitError == "Cached rate-limit failure.")
    }

    @Test func apiKeyKindTransitionClearsAllRateLimitState() {
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let account = CodexAccount(
            accountKey: "api-key",
            email: "API Key",
            kind: .chatGPT
        )
        account.updateRateLimits([
            (
                windowDurationMinutes: 300,
                usedPercent: 40,
                resetsAt: fetchedAt.addingTimeInterval(300)
            ),
        ])
        account.updateRateLimitFetchMetadata(
            fetchedAt: fetchedAt,
            error: "Stale ChatGPT rate-limit failure."
        )

        account.updateKind(.apiKey, capabilities: .noCodexRateLimits)

        #expect(account.kind == .apiKey)
        #expect(account.capabilities.supportsRateLimitRefresh == false)
        #expect(account.rateLimits.isEmpty)
        #expect(account.lastRateLimitFetchAt == nil)
        #expect(account.lastRateLimitError == nil)
    }

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
