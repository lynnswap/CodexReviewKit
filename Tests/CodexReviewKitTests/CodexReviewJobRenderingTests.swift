import Foundation
import Testing
@_spi(Testing) @testable import CodexReviewKit

@Suite("Codex review job rendering")
@MainActor
struct CodexReviewJobRenderingTests {
    @Test func renderedLogTextKeepsCommandOutputInSemanticProjection() {
        let job = CodexReviewJob.makeForTesting(
            id: "job-command-output",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .succeeded,
            summary: "Done",
            logEntries: [
                .init(kind: .command, text: "$ git diff --stat"),
                .init(kind: .commandOutput, groupID: "cmd-1", text: "README.md | 1 +"),
                .init(kind: .agentMessage, text: "No correctness issues found."),
            ]
        )

        #expect(
            job.logText == """
                $ git diff --stat

                README.md | 1 +

                No correctness issues found.
                """)
        #expect(
            job.activityLogText == """
                $ git diff --stat

                README.md | 1 +
                """)
    }

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

    @Test func tailAppendPublishesIncrementalLogMutation() {
        let job = CodexReviewJob.makeForTesting(
            id: "job-tail-append-mutation",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .agentMessage, groupID: "msg-1", text: "Initial")
            ]
        )

        let initialRevision = job.logRevision
        job.appendLogEntry(.init(kind: .agentMessage, groupID: "msg-1", text: " append"))

        #expect(job.logRevision == initialRevision + 1)
        #expect(job.lastLogMutation == .append)
        #expect(job.logText == "Initial append")
    }

    @Test func groupedReplacementPublishesReloadLogMutation() {
        let job = CodexReviewJob.makeForTesting(
            id: "job-grouped-replacement-mutation",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .plan, groupID: "plan-1", text: "- original")
            ]
        )

        let initialRevision = job.logRevision
        job.appendLogEntry(
            .init(
                kind: .plan,
                groupID: "plan-1",
                replacesGroup: true,
                text: "- updated"
            ))

        #expect(job.logRevision == initialRevision + 1)
        #expect(job.lastLogMutation == .reload)
        #expect(job.logEntries.count == 2)
        #expect(job.logText == "- updated")
    }

    @Test func runningRawReasoningOverLimitRemainsAppendOnly() {
        let initialText = String(repeating: "a", count: 250 * 1024)
        let delta = String(repeating: "b", count: 20 * 1024)
        let job = CodexReviewJob.makeForTesting(
            id: "job-live-raw-reasoning-limit",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .rawReasoning, groupID: "reasoning-1", text: initialText)
            ]
        )

        let initialRevision = job.logRevision
        job.appendLogEntry(.init(kind: .rawReasoning, groupID: "reasoning-1", text: delta))

        #expect(job.logRevision == initialRevision + 1)
        #expect(job.lastLogMutation == .append)
        #expect(job.logEntries.count == 2)
        #expect(job.logText.hasSuffix(delta))
        #expect(job.cappedLogBytes > 256 * 1024)
    }

    @Test func terminalRawReasoningTrimKeepsNewestTail() {
        let initialText = String(repeating: "a", count: 250 * 1024)
        let delta = String(repeating: "b", count: 20 * 1024)
        let job = CodexReviewJob.makeForTesting(
            id: "job-terminal-raw-reasoning-limit",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .succeeded,
            summary: "Done",
            logEntries: [
                .init(kind: .rawReasoning, groupID: "reasoning-1", text: initialText)
            ]
        )

        job.appendLogEntry(.init(kind: .rawReasoning, groupID: "reasoning-1", text: delta))

        #expect(job.lastLogMutation == .reload)
        #expect(job.logText.hasSuffix(delta))
        #expect(job.logEntries.last?.text == delta)
        #expect(job.cappedLogBytes <= 256 * 1024)
    }

    @Test func explicitReviewLogLimitApplicationPublishesReloadMutation() {
        let initialText = String(repeating: "a", count: 250 * 1024)
        let delta = String(repeating: "b", count: 20 * 1024)
        let job = CodexReviewJob.makeForTesting(
            id: "job-explicit-raw-reasoning-limit",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .rawReasoning, groupID: "reasoning-1", text: initialText)
            ]
        )
        job.appendLogEntry(.init(kind: .rawReasoning, groupID: "reasoning-1", text: delta))
        let appendRevision = job.logRevision

        #expect(job.applyReviewLogLimit())
        #expect(job.logRevision == appendRevision + 1)
        #expect(job.lastLogMutation == .reload)
        #expect(job.logText.hasSuffix(delta))
        #expect(job.cappedLogBytes <= 256 * 1024)
    }
}
