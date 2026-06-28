import Foundation
import Testing
@testable import CodexReviewKit

@Suite("Review run record")
@MainActor
struct ReviewRunRecordTests {
    @Test func prebuiltTerminalRunsKeepCoreTerminalState() {
        let succeeded = ReviewRunRecord.makeForTesting(
            id: "run-terminal-succeeded",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .succeeded,
            summary: "Succeeded.",
            hasFinalReview: true,
            lastAgentMessage: "No findings."
        )
        #expect(succeeded.core.lifecycle.status == .succeeded)
        #expect(succeeded.core.output.summary == "Succeeded.")
        #expect(succeeded.core.reviewText == "No findings.")

        let succeededWithoutFinalReview = ReviewRunRecord.makeForTesting(
            id: "run-terminal-succeeded-no-review",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .succeeded,
            summary: "Succeeded.",
            hasFinalReview: false,
            lastAgentMessage: "Succeeded."
        )
        #expect(succeededWithoutFinalReview.core.lifecycle.status == .succeeded)
        #expect(succeededWithoutFinalReview.core.output.summary == "Succeeded.")
        #expect(succeededWithoutFinalReview.core.reviewText == "Succeeded.")

        let failed = ReviewRunRecord.makeForTesting(
            id: "run-terminal-failed",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .failed,
            summary: "Failed.",
            errorMessage: "Backend failed."
        )
        #expect(failed.core.lifecycle.status == .failed)
        #expect(failed.core.lifecycle.errorMessage == "Backend failed.")
        #expect(failed.core.reviewText == "Backend failed.")

        let cancelled = ReviewRunRecord.makeForTesting(
            id: "run-terminal-cancelled",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .cancelled,
            cancellation: .mcpClient(message: "Session closed."),
            summary: "Cancelled."
        )
        #expect(cancelled.core.lifecycle.status == .cancelled)
        #expect(cancelled.core.lifecycle.cancellation?.message == "Session closed.")
        #expect(cancelled.core.reviewText == "Cancelled.")
    }
}
