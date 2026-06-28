import Foundation
import Testing
@testable import CodexReviewKit

@Suite("Review run core")
@MainActor
struct ReviewRunCoreTests {
    @Test func coreKeepsLifecycleMessageOnly() {
        let succeeded = ReviewRunCore(
            lifecycle: .init(status: .succeeded),
            lifecycleMessage: "Succeeded."
        )
        #expect(succeeded.lifecycle.status == .succeeded)
        #expect(succeeded.lifecycleMessage == "Succeeded.")

        let failed = ReviewRunCore(
            lifecycle: .init(
                status: .failed,
                errorMessage: "Backend failed."
            ),
            lifecycleMessage: "Failed."
        )
        #expect(failed.lifecycle.status == .failed)
        #expect(failed.lifecycle.errorMessage == "Backend failed.")
        #expect(failed.lifecycleMessage == "Failed.")

        let cancelled = ReviewRunCore(
            lifecycle: .init(
                status: .cancelled,
                cancellation: .mcpClient(message: "Session closed.")
            ),
            lifecycleMessage: "Cancelled."
        )
        #expect(cancelled.lifecycle.status == .cancelled)
        #expect(cancelled.lifecycle.cancellation?.message == "Session closed.")
        #expect(cancelled.lifecycleMessage == "Cancelled.")
    }
}
