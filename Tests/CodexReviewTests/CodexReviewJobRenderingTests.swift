import Foundation
import Testing
@_spi(Testing) @testable import CodexReview

@Suite("Codex review job rendering")
@MainActor
struct CodexReviewJobRenderingTests {
    @Test func reviewMonitorLogTextOmitsCommandOutputButKeepsCommandEntry() {
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

        #expect(job.logText == """
        $ git diff --stat

        README.md | 1 +

        No correctness issues found.
        """)
        #expect(job.reviewMonitorLogText == """
        $ git diff --stat

        No correctness issues found.
        """)
        #expect(job.activityLogText == """
        $ git diff --stat

        README.md | 1 +
        """)
    }

    @Test func commandOutputAppendDoesNotAdvanceReviewMonitorRevision() {
        let job = CodexReviewJob.makeForTesting(
            id: "job-command-output",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .command, text: "$ git diff --stat"),
                .init(kind: .commandOutput, groupID: "cmd-1", text: "README.md | 1 +"),
            ]
        )
        let initialRevision = job.reviewMonitorRevision
        let initialMonitorLog = job.reviewMonitorLogText

        job.appendLogEntry(.init(kind: .commandOutput, groupID: "cmd-1", text: "\nSources/App.swift | 2 +"))

        #expect(job.reviewMonitorRevision == initialRevision)
        #expect(job.reviewMonitorLogText == initialMonitorLog)
        #expect(job.logText.contains("Sources/App.swift | 2 +"))
    }

    @Test func tailAgentMessageDeltaUsesAppendMonitorUpdate() {
        let job = CodexReviewJob.makeForTesting(
            id: "job-agent-delta",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .agentMessage, groupID: "msg-1", text: "Initial"),
            ]
        )

        job.appendLogEntry(.init(kind: .agentMessage, groupID: "msg-1", text: " log"))

        #expect(job.reviewMonitorLogText == "Initial log")
        #expect(job.lastMonitorUpdate == .append(" log"))
    }

    @Test func replacingGroupedPlanUsesReloadMonitorUpdate() {
        let job = CodexReviewJob.makeForTesting(
            id: "job-plan-reload",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .plan, groupID: "plan-1", text: "- original"),
            ]
        )

        job.appendLogEntry(.init(kind: .plan, groupID: "plan-1", replacesGroup: true, text: "- updated"))

        #expect(job.reviewMonitorLogText == "- updated")
        #expect(job.lastMonitorUpdate == .reload("- updated"))
    }

    @Test func cappedAgentMessageKeepsNewestText() {
        let text = "STALE BEGINNING\n" + String(repeating: "a", count: 270 * 1024) + "\nFINAL REVIEW TEXT"
        let job = CodexReviewJob.makeForTesting(
            id: "job-large-agent-message",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .agentMessage, groupID: "msg-1", text: text),
            ]
        )

        #expect(job.reviewMonitorLogText.contains("FINAL REVIEW TEXT"))
        #expect(job.reviewMonitorLogText.contains("STALE BEGINNING") == false)
    }
}
