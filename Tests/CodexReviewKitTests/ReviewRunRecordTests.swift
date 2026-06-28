import Foundation
import Testing
@testable import CodexReviewKit

@Suite("Review run core")
@MainActor
struct ReviewRunCoreTests {
    @Test func reviewTextReflectsTerminalCoreState() {
        let succeeded = ReviewRunCore(
            lifecycle: .init(status: .succeeded),
            output: .init(
                summary: "Succeeded.",
                lastAgentMessage: "No findings."
            )
        )
        #expect(succeeded.lifecycle.status == .succeeded)
        #expect(succeeded.output.summary == "Succeeded.")
        #expect(succeeded.reviewText == "No findings.")

        let succeededWithoutFinalReview = ReviewRunCore(
            lifecycle: .init(status: .succeeded),
            output: .init(
                summary: "Succeeded.",
                lastAgentMessage: "Succeeded."
            )
        )
        #expect(succeededWithoutFinalReview.lifecycle.status == .succeeded)
        #expect(succeededWithoutFinalReview.output.summary == "Succeeded.")
        #expect(succeededWithoutFinalReview.reviewText == "Succeeded.")

        let failed = ReviewRunCore(
            lifecycle: .init(
                status: .failed,
                errorMessage: "Backend failed."
            ),
            output: .init(summary: "Failed.")
        )
        #expect(failed.lifecycle.status == .failed)
        #expect(failed.lifecycle.errorMessage == "Backend failed.")
        #expect(failed.reviewText == "Backend failed.")

        let cancelled = ReviewRunCore(
            lifecycle: .init(
                status: .cancelled,
                cancellation: .mcpClient(message: "Session closed.")
            ),
            output: .init(summary: "Cancelled.")
        )
        #expect(cancelled.lifecycle.status == .cancelled)
        #expect(cancelled.lifecycle.cancellation?.message == "Session closed.")
        #expect(cancelled.reviewText == "Cancelled.")
    }
}
