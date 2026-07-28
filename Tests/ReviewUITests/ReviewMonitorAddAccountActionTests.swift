import Foundation
import Testing
@testable import CodexReviewKit
@testable import ReviewUI

@Suite("ReviewMonitor add account action")
@MainActor
struct ReviewMonitorAddAccountActionTests {
    @Test func operationFailureUsesTheAccountActionAlertFlow() async throws {
        let store = CodexReviewStore.makePreviewStore()

        await ReviewMonitorAddAccountAction.perform(store: store) {
            throw CodexReviewAPI.Error.io("Review runtime operations are closed.")
        }

        let alert = try #require(store.auth.accountActionAlert)
        #expect(String(localized: alert.title) == "Failed to Add Account")
        #expect(alert.message == "Review runtime operations are closed.")
    }
}
