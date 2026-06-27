import Foundation
import Testing
@testable import CodexReviewKit

@Suite("Codex review job")
@MainActor
struct CodexReviewJobTests {
    @Test func prebuiltTerminalJobsInitializeTimelineTerminalState() {
        let succeeded = CodexReviewJob.makeForTesting(
            id: "job-terminal-succeeded",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .succeeded,
            summary: "Succeeded.",
            hasFinalReview: true,
            lastAgentMessage: "No findings."
        )
        #expect(succeeded.timeline.terminalStatus == .succeeded)
        #expect(succeeded.timeline.terminalSummary == "Succeeded.")
        #expect(succeeded.timeline.terminalResult == "No findings.")

        let succeededWithoutFinalReview = CodexReviewJob.makeForTesting(
            id: "job-terminal-succeeded-no-review",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .succeeded,
            summary: "Succeeded.",
            hasFinalReview: false,
            lastAgentMessage: "Succeeded."
        )
        #expect(succeededWithoutFinalReview.timeline.terminalStatus == .succeeded)
        #expect(succeededWithoutFinalReview.timeline.terminalSummary == "Succeeded.")
        #expect(succeededWithoutFinalReview.timeline.terminalResult == nil)

        let failed = CodexReviewJob.makeForTesting(
            id: "job-terminal-failed",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .failed,
            summary: "Failed.",
            errorMessage: "Backend failed."
        )
        #expect(failed.timeline.terminalStatus == .failed)
        #expect(failed.timeline.terminalSummary == "Backend failed.")
        #expect(failed.timeline.terminalResult == nil)

        let cancelled = CodexReviewJob.makeForTesting(
            id: "job-terminal-cancelled",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .cancelled,
            cancellation: .mcpClient(message: "Session closed."),
            summary: "Cancelled."
        )
        #expect(cancelled.timeline.terminalStatus == .cancelled)
        #expect(cancelled.timeline.terminalSummary == "Session closed.")
        #expect(cancelled.timeline.terminalResult == nil)
    }
}
