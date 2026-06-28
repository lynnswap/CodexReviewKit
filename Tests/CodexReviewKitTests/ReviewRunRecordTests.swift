import Foundation
import Testing
@testable import CodexReviewKit

@Suite("Review run core")
@MainActor
struct ReviewRunCoreTests {
    @Test func coreKeepsLifecycleAndSummaryOnly() {
        let succeeded = ReviewRunCore(
            lifecycle: .init(status: .succeeded),
            summary: "Succeeded."
        )
        #expect(succeeded.lifecycle.status == .succeeded)
        #expect(succeeded.summary == "Succeeded.")

        let failed = ReviewRunCore(
            lifecycle: .init(
                status: .failed,
                errorMessage: "Backend failed."
            ),
            summary: "Failed."
        )
        #expect(failed.lifecycle.status == .failed)
        #expect(failed.lifecycle.errorMessage == "Backend failed.")
        #expect(failed.summary == "Failed.")

        let cancelled = ReviewRunCore(
            lifecycle: .init(
                status: .cancelled,
                cancellation: .mcpClient(message: "Session closed.")
            ),
            summary: "Cancelled."
        )
        #expect(cancelled.lifecycle.status == .cancelled)
        #expect(cancelled.lifecycle.cancellation?.message == "Session closed.")
        #expect(cancelled.summary == "Cancelled.")
    }
}
