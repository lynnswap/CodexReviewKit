import Foundation
import Testing
@testable import CodexReviewKit

@Suite("Review run core")
@MainActor
struct ReviewRunCoreTests {
    @Test func coreKeepsLifecycleAndSummaryOnly() {
        let succeeded = ReviewRunCore(
            lifecycle: .init(status: .succeeded),
            output: .init(summary: "Succeeded.")
        )
        #expect(succeeded.lifecycle.status == .succeeded)
        #expect(succeeded.output.summary == "Succeeded.")

        let failed = ReviewRunCore(
            lifecycle: .init(
                status: .failed,
                errorMessage: "Backend failed."
            ),
            output: .init(summary: "Failed.")
        )
        #expect(failed.lifecycle.status == .failed)
        #expect(failed.lifecycle.errorMessage == "Backend failed.")
        #expect(failed.output.summary == "Failed.")

        let cancelled = ReviewRunCore(
            lifecycle: .init(
                status: .cancelled,
                cancellation: .mcpClient(message: "Session closed.")
            ),
            output: .init(summary: "Cancelled.")
        )
        #expect(cancelled.lifecycle.status == .cancelled)
        #expect(cancelled.lifecycle.cancellation?.message == "Session closed.")
        #expect(cancelled.output.summary == "Cancelled.")
    }
}
