import Foundation
import Testing
@_spi(Testing) @testable import CodexReview
@_spi(PreviewSupport) @testable import ReviewUI

@Suite("ReviewMonitor log projection")
@MainActor
struct ReviewMonitorLogProjectionTests {
    @Test func documentIncludesCommandOutputAndKeepsPlainTranscript() {
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
        let document = document(for: job)

        #expect(document.text == """
        $ git diff --stat

        README.md | 1 +

        No correctness issues found.
        """)
        #expect(document.blocks.map(\.kind) == [.command, .commandOutput, .agentMessage])
        #expect(document.blocks[0].range == NSRange(
            location: 0,
            length: ("$ git diff --stat" as NSString).length
        ))
        #expect(document.blocks[1].range == NSRange(
            location: ("$ git diff --stat\n\n" as NSString).length,
            length: ("README.md | 1 +" as NSString).length
        ))
        #expect(document.blocks[2].range == NSRange(
            location: ("$ git diff --stat\n\nREADME.md | 1 +\n\n" as NSString).length,
            length: ("No correctness issues found." as NSString).length
        ))
    }

    @Test func commandOutputAppendUsesAppendChange() {
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
        var projection = ReviewMonitorLogProjection()
        let initialDocument = projection.render(entries: job.logEntries)

        job.appendLogEntry(.init(kind: .commandOutput, groupID: "cmd-1", text: "\nSources/App.swift | 2 +"))
        let updatedDocument = projection.render(entries: job.logEntries)

        #expect(updatedDocument.text == """
        $ git diff --stat

        README.md | 1 +
        Sources/App.swift | 2 +
        """)
        #expect(updatedDocument.revision == initialDocument.revision &+ 1)
        #expect(updatedDocument.lastChange == .append(.init(
            kind: .commandOutput,
            blockID: ReviewMonitorLogBlockID("commandOutput:cmd-1"),
            range: NSRange(
                location: ("$ git diff --stat\n\nREADME.md | 1 +" as NSString).length,
                length: ("\nSources/App.swift | 2 +" as NSString).length
            ),
            text: "\nSources/App.swift | 2 +"
        )))
        #expect(job.logText.contains("Sources/App.swift | 2 +"))
    }

    @Test func commandDisplayUsesPanelBeforeOutputArrives() {
        let job = CodexReviewJob.makeForTesting(
            id: "job-command-started",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .command, groupID: "cmd-1", text: "$ swift test")
            ]
        )
        let sourceDocument = document(for: job)
        let displayDocument = ReviewMonitorCommandOutputDisplayDocument.make(
            from: sourceDocument,
            expandedBlockIDs: []
        )
        let displayText = displayDocument.text.replacingOccurrences(
            of: ReviewMonitorCommandOutputDisplayDocument.toggleAttachmentCharacter,
            with: ""
        )

        #expect(displayText == "Ran swift test")
        #expect(displayDocument.text.contains("$ swift test") == false)
        #expect(displayDocument.decorations.isEmpty)
        #expect(displayDocument.commandOutputPanels.count == 1)
        #expect(displayDocument.commandOutputPanels.first?.blockID == ReviewMonitorLogBlockID("commandOutput:cmd-1"))
        #expect(displayDocument.commandOutputPanels.first?.commandText == "swift test")
    }

    @Test func commandOutputDisplayKeepsCommandPanelBeforeInterleavedBlocks() {
        let job = CodexReviewJob.makeForTesting(
            id: "job-command-output-interleaved",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .command, groupID: "cmd-1", text: "$ swift test"),
                .init(kind: .toolCall, text: "MCP codex_review.review_read started."),
                .init(
                    kind: .commandOutput,
                    groupID: "cmd-1",
                    text: "Tests passed",
                    metadata: .init(sourceType: "command", title: "Ran command for 3s")
                ),
            ]
        )
        let sourceDocument = document(for: job)
        let displayDocument = ReviewMonitorCommandOutputDisplayDocument.make(
            from: sourceDocument,
            expandedBlockIDs: []
        )

        let displayText = displayDocument.text.replacingOccurrences(
            of: ReviewMonitorCommandOutputDisplayDocument.toggleAttachmentCharacter,
            with: ""
        )
        #expect(displayText.hasPrefix("Ran command for 3s\n\nMCP codex_review.review_read started."))
        #expect(displayDocument.text.contains("$ swift test") == false)
    }

    @Test func commandOutputDisplayLetsExitCodeOverrideCompletedStatus() {
        let job = CodexReviewJob.makeForTesting(
            id: "job-command-output-exit-code",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .command, groupID: "cmd-1", text: "$ swift test"),
                .init(
                    kind: .commandOutput,
                    groupID: "cmd-1",
                    text: "Tests failed",
                    metadata: .init(
                        sourceType: "command",
                        title: "Ran command for 10s",
                        status: "completed",
                        exitCode: 1
                    )
                ),
            ]
        )
        let sourceDocument = document(for: job)
        let displayDocument = ReviewMonitorCommandOutputDisplayDocument.make(
            from: sourceDocument,
            expandedBlockIDs: [ReviewMonitorLogBlockID("commandOutput:cmd-1")]
        )

        #expect(displayDocument.commandOutputPanels.first?.exitText == "exit 1")
    }

    @Test func metadataIsPreservedOnBlocks() {
        let metadata = ReviewLogEntry.Metadata(
            sourceType: "commandExecution",
            title: "Command",
            status: "started",
            command: "swift test",
            cwd: "/tmp/workspace",
            exitCode: 0
        )
        let job = CodexReviewJob.makeForTesting(
            id: "job-metadata",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .command, groupID: "cmd-1", text: "$ swift test", metadata: metadata),
            ]
        )
        let document = document(for: job)

        #expect(document.blocks.first?.metadata == metadata)
        #expect(document.decorations.first?.style == .command(tone: .success))
    }

    @Test func groupedReplacementCanClearMetadata() {
        let metadata = ReviewLogEntry.Metadata(
            sourceType: "commandExecution",
            title: "Command",
            status: "started",
            command: "swift test"
        )
        let job = CodexReviewJob.makeForTesting(
            id: "job-metadata-clear",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .commandOutput, groupID: "cmd-1", text: "running", metadata: metadata),
                .init(kind: .commandOutput, groupID: "cmd-1", replacesGroup: true, text: "finished"),
            ]
        )
        let document = document(for: job)

        #expect(document.text == "finished")
        #expect(document.blocks.first?.metadata == nil)
        #expect(document.decorations.first?.style == .terminal(tone: .neutral))
    }

    @Test func documentRendersMarkdownWithStandardParserAndKeepsSourceTranscript() {
        let text = """
        # Heading
        - `inline` item with **strong**, *emphasis*, [link](https://example.com), and ~~old~~
        > quote
        ```swift
        let value = 1
        ```
        """
        let job = CodexReviewJob.makeForTesting(
            id: "job-markdown-lite",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .succeeded,
            summary: "Done",
            logEntries: [
                .init(kind: .agentMessage, text: text),
            ]
        )
        let document = document(for: job)

        #expect(document.text == """
        Heading

        - inline item with strong, emphasis, link, and old

        quote

        let value = 1

        """)
        #expect(document.sourceText == text)
        #expect(document.styleRuns.contains { $0.style == .heading(level: 1) })
        #expect(document.styleRuns.contains { $0.style == .bullet })
        #expect(document.styleRuns.contains { $0.style == .inlineCode })
        #expect(document.styleRuns.contains { $0.style == .strong })
        #expect(document.styleRuns.contains { $0.style == .emphasis })
        #expect(document.styleRuns.contains { $0.style == .link })
        #expect(document.styleRuns.contains { $0.style == .strikethrough })
        #expect(document.styleRuns.contains { $0.style == .blockquote })
        #expect(document.styleRuns.contains { $0.style == .codeFence })
        #expect(document.decorations.contains { $0.style == .codeBlock })
    }

    @Test func plainMultilineAgentTextKeepsLineBreaks() {
        let text = "line 1\nline 2\nline 3"
        let job = CodexReviewJob.makeForTesting(
            id: "job-plain-lines",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .succeeded,
            summary: "Done",
            logEntries: [
                .init(kind: .agentMessage, text: text),
            ]
        )
        let document = document(for: job)

        #expect(document.text == text)
        #expect(document.sourceText == text)
    }

    @Test func planStatusStylesAreProjected() {
        let job = CodexReviewJob.makeForTesting(
            id: "job-plan-style",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .todoList, groupID: "plan-1", text: "[completed] Inspect\n[in_progress] Render\n[pending] Test"),
            ]
        )
        let document = document(for: job)

        #expect(document.text == """
        ✓ Inspect
        • Render
        □ Test
        """)
        #expect(document.sourceText == "[completed] Inspect\n[in_progress] Render\n[pending] Test")
        #expect(document.styleRuns.contains { $0.style == .plan(status: .completed) })
        #expect(document.styleRuns.contains { $0.style == .plan(status: .inProgress) })
        #expect(document.styleRuns.contains { $0.style == .plan(status: .pending) })
    }

    @Test func rawDiffEventRemainsMonospacedEventWithoutDiffParsing() {
        let diff = """
        diff --git a/A.swift b/A.swift
        +let value = 1
        """
        let job = CodexReviewJob.makeForTesting(
            id: "job-raw-diff",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .event, groupID: "turn-1", replacesGroup: true, text: diff),
            ]
        )
        let document = document(for: job)

        #expect(document.text == diff)
        #expect(document.styleRuns == [
            .init(range: NSRange(location: 0, length: (diff as NSString).length), style: .event)
        ])
        #expect(document.decorations.map(\.style) == [.event])
    }

    @Test func tailAgentMessageDeltaUsesAppendChangeWhenRenderedTextKeepsPrefix() {
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
        var projection = ReviewMonitorLogProjection()
        _ = projection.render(entries: job.logEntries)

        job.appendLogEntry(.init(kind: .agentMessage, groupID: "msg-1", text: " log"))
        let document = projection.render(entries: job.logEntries)

        #expect(document.text == "Initial log")
        #expect(document.blocks == [
            .init(
                id: ReviewMonitorLogBlockID("agentMessage:msg-1"),
                kind: .agentMessage,
                groupID: "msg-1",
                range: NSRange(location: 0, length: ("Initial log" as NSString).length)
            )
        ])
        #expect(document.lastChange == .append(.init(
            kind: .agentMessage,
            blockID: ReviewMonitorLogBlockID("agentMessage:msg-1"),
            range: NSRange(
                location: ("Initial" as NSString).length,
                length: (" log" as NSString).length
            ),
            text: " log"
        )))
    }

    @Test func tailAgentMessageDeltaRerendersMarkdownBlockWhenMarkupChangesPrefix() {
        let job = CodexReviewJob.makeForTesting(
            id: "job-agent-markdown-delta",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .agentMessage, groupID: "msg-1", text: "**bo"),
            ]
        )
        var projection = ReviewMonitorLogProjection()
        _ = projection.render(entries: job.logEntries)

        job.appendLogEntry(.init(kind: .agentMessage, groupID: "msg-1", text: "ld**"))
        let document = projection.render(entries: job.logEntries)

        #expect(document.text == "bold")
        #expect(document.sourceText == "**bold**")
        #expect(document.lastChange == .replace(.init(
            kind: .agentMessage,
            blockID: ReviewMonitorLogBlockID("agentMessage:msg-1"),
            range: NSRange(location: 0, length: ("**bo" as NSString).length),
            text: "bold"
        )))
        #expect(document.styleRuns.contains { $0.style == .strong })
    }

    @Test func incrementalAppendReplacesTailMarkdownBlockWithoutFullReload() {
        let firstEntry = ReviewLogEntry(kind: .agentMessage, groupID: "msg-1", text: "**bo")
        let appendedEntry = ReviewLogEntry(kind: .agentMessage, groupID: "msg-1", text: "ld**")
        var projection = ReviewMonitorLogProjection()
        _ = projection.render(entries: [firstEntry])

        let incrementalDocument = projection.append(entries: [appendedEntry], sourceRange: 1..<2)
        #expect(incrementalDocument?.text == "bold")
        #expect(incrementalDocument?.sourceText == "**bold**")
        #expect(incrementalDocument?.lastChange == .replace(.init(
            kind: .agentMessage,
            blockID: ReviewMonitorLogBlockID("agentMessage:msg-1"),
            range: NSRange(location: 0, length: ("**bo" as NSString).length),
            text: "bold"
        )))

        let document = projection.render(entries: [firstEntry, appendedEntry])
        #expect(document.text == "bold")
        #expect(document.sourceText == "**bold**")
        #expect(document.lastChange == .replace(.init(
            kind: .agentMessage,
            blockID: ReviewMonitorLogBlockID("agentMessage:msg-1"),
            range: NSRange(location: 0, length: ("**bo" as NSString).length),
            text: "bold"
        )))
    }

    @Test func replacingGroupedPlanUsesReplacementChange() {
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
        var projection = ReviewMonitorLogProjection()
        _ = projection.render(entries: job.logEntries)

        job.appendLogEntry(.init(kind: .plan, groupID: "plan-1", replacesGroup: true, text: "- updated"))
        let document = projection.render(entries: job.logEntries)

        #expect(document.text == "- updated")
        #expect(document.lastChange == .replace(.init(
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
        let document = document(for: job)

        #expect(document.text.contains("FINAL REVIEW TEXT"))
        #expect(document.text.contains("STALE BEGINNING") == false)
    }

    private func document(for job: CodexReviewJob) -> ReviewMonitorLogDocument {
        var projection = ReviewMonitorLogProjection()
        return projection.render(entries: job.logEntries)
    }
}
