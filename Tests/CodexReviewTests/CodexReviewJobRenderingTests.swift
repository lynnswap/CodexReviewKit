import Foundation
import Testing
@_spi(Testing) @testable import CodexReview

@Suite("Codex review job rendering")
@MainActor
struct CodexReviewJobRenderingTests {
    @Test func logEntryDecodesLegacyPayloadWithoutContentBlocks() throws {
        let data = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "kind": "agentMessage",
          "groupID": "message-1",
          "replacesGroup": false,
          "text": "Legacy log entry",
          "metadata": null,
          "timestamp": "2026-06-08T08:00:00Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(ReviewLogEntry.self, from: data)

        #expect(entry.id == UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        #expect(entry.kind == .agentMessage)
        #expect(entry.groupID == "message-1")
        #expect(entry.text == "Legacy log entry")
        #expect(entry.contentBlocks.isEmpty)
    }

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

        #expect(job.logText == """
        $ git diff --stat

        README.md | 1 +

        No correctness issues found.
        """)
        #expect(job.activityLogText == """
        $ git diff --stat

        README.md | 1 +
        """)
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
        job.appendLogEntry(.init(
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
}
