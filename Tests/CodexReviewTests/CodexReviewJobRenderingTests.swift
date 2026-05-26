import Foundation
import Testing
@_spi(Testing) @testable import CodexReview

@Suite("Codex review job rendering")
@MainActor
struct CodexReviewJobRenderingTests {
    @Test func reviewMonitorLogDocumentOmitsCommandOutputButKeepsCommandEntry() {
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
        #expect(job.reviewMonitorLogDocument.text == """
        $ git diff --stat

        No correctness issues found.
        """)
        #expect(job.reviewMonitorLogDocument.blocks.map(\.kind) == [.command, .agentMessage])
        #expect(job.reviewMonitorLogDocument.blocks[0].range == NSRange(
            location: 0,
            length: ("$ git diff --stat" as NSString).length
        ))
        #expect(job.reviewMonitorLogDocument.blocks[1].range == NSRange(
            location: ("$ git diff --stat\n\n" as NSString).length,
            length: ("No correctness issues found." as NSString).length
        ))
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
        let initialMonitorDocument = job.reviewMonitorLogDocument

        job.appendLogEntry(.init(kind: .commandOutput, groupID: "cmd-1", text: "\nSources/App.swift | 2 +"))

        #expect(job.reviewMonitorRevision == initialRevision)
        #expect(job.reviewMonitorLogDocument == initialMonitorDocument)
        #expect(job.logText.contains("Sources/App.swift | 2 +"))
    }

    @Test func tailAgentMessageDeltaUsesAppendMonitorChange() {
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

        #expect(job.reviewMonitorLogDocument.text == "Initial log")
        #expect(job.reviewMonitorLogDocument.blocks == [
            .init(
                id: ReviewMonitorLogBlockID("agentMessage:msg-1"),
                kind: .agentMessage,
                groupID: "msg-1",
                range: NSRange(location: 0, length: ("Initial log" as NSString).length)
            )
        ])
        #expect(job.reviewMonitorLogDocument.lastChange == .append(.init(
            kind: .agentMessage,
            blockID: ReviewMonitorLogBlockID("agentMessage:msg-1"),
            range: NSRange(
                location: ("Initial" as NSString).length,
                length: (" log" as NSString).length
            ),
            text: " log"
        )))
    }

    @Test func replacingGroupedPlanUsesReplacementMonitorChange() {
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

        #expect(job.reviewMonitorLogDocument.text == "- updated")
        #expect(job.reviewMonitorLogDocument.lastChange == .replace(.init(
            kind: .plan,
            blockID: ReviewMonitorLogBlockID("plan:plan-1"),
            range: NSRange(location: 0, length: ("- original" as NSString).length),
            text: "- updated"
        )))
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

        #expect(job.reviewMonitorLogDocument.text.contains("FINAL REVIEW TEXT"))
        #expect(job.reviewMonitorLogDocument.text.contains("STALE BEGINNING") == false)
    }
}
