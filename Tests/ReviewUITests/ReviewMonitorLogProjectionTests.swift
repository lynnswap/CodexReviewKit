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

    @Test func contextCompactionMarkerUsesDedicatedProjectionStyle() {
        let metadata = ReviewLogEntry.Metadata(
            sourceType: "contextCompaction",
            status: "inProgress",
            itemID: "compact-1"
        )
        let job = CodexReviewJob.makeForTesting(
            id: "job-context-compaction",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(
                    kind: .contextCompaction,
                    groupID: "compact-1",
                    replacesGroup: true,
                    text: "Automatically compacting context",
                    metadata: metadata
                ),
            ]
        )
        let document = document(for: job)

        #expect(document.text == "Automatically compacting context")
        #expect(document.blocks.map(\.kind) == [.contextCompaction])
        #expect(document.styleRuns.first?.style == .contextCompaction)
        #expect(document.decorations.first?.style == .contextCompaction(
            label: "Automatically compacting context",
            isCompleted: false
        ))
    }

    @Test func contextCompactionCompletionReplacesStartedMarker() {
        let job = CodexReviewJob.makeForTesting(
            id: "job-context-compaction-replacement",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(
                    kind: .contextCompaction,
                    groupID: "compact-1",
                    replacesGroup: true,
                    text: "Automatically compacting context",
                    metadata: .init(
                        sourceType: "contextCompaction",
                        status: "inProgress",
                        itemID: "compact-1"
                    )
                ),
            ]
        )
        var projection = ReviewMonitorLogProjection()
        let initialDocument = projection.render(entries: job.logEntries)

        job.appendLogEntry(.init(
            kind: .contextCompaction,
            groupID: "compact-1",
            replacesGroup: true,
            text: "Context automatically compacted",
            metadata: .init(
                sourceType: "contextCompaction",
                status: "completed",
                itemID: "compact-1"
            )
        ))
        let updatedDocument = projection.render(entries: job.logEntries)

        #expect(updatedDocument.text == "Context automatically compacted")
        #expect(updatedDocument.blocks.count == 1)
        #expect(updatedDocument.blocks.first?.kind == .contextCompaction)
        #expect(updatedDocument.revision == initialDocument.revision &+ 1)
        #expect(updatedDocument.lastChange == .replace(.init(
            kind: .contextCompaction,
            blockID: ReviewMonitorLogBlockID("contextCompaction:compact-1"),
            range: NSRange(
                location: 0,
                length: ("Automatically compacting context" as NSString).length
            ),
            text: "Context automatically compacted"
        )))
        #expect(updatedDocument.decorations.first?.style == .contextCompaction(
            label: "Context automatically compacted",
            isCompleted: true
        ))
    }

    @Test func failedContextCompactionMarkerDoesNotUseCompletedDecoration() {
        let completedAt = Date(timeIntervalSince1970: 1_700_000_002)
        let job = CodexReviewJob.makeForTesting(
            id: "job-context-compaction-failed",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(
                    kind: .contextCompaction,
                    groupID: "compact-1",
                    replacesGroup: true,
                    text: "Context compaction failed",
                    metadata: .init(
                        sourceType: "contextCompaction",
                        status: "failed",
                        itemID: "compact-1",
                        completedAt: completedAt
                    )
                ),
            ]
        )

        let document = document(for: job)

        #expect(document.text == "Context compaction failed")
        #expect(document.decorations.first?.style == .contextCompaction(
            label: "Context compaction failed",
            isCompleted: false
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

        #expect(displayText == "Running swift test")
        #expect(displayDocument.text.contains("$ swift test") == false)
        #expect(displayDocument.decorations.isEmpty)
        #expect(displayDocument.commandOutputPanels.count == 1)
        #expect(displayDocument.commandOutputPanels.first?.blockID == ReviewMonitorLogBlockID("commandOutput:cmd-1"))
        #expect(displayDocument.commandOutputPanels.first?.commandText == "swift test")
        #expect(displayDocument.commandOutputPanels.first?.isActive == true)
    }

    @Test func duplicateStartedCommandsKeepUniquePanelIDs() {
        let job = CodexReviewJob.makeForTesting(
            id: "job-duplicate-command-started",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .command, groupID: "cmd-1", text: "$ swift test"),
                .init(kind: .command, groupID: "cmd-2", text: "$ swift test --filter ReviewUI"),
            ]
        )
        let sourceDocument = document(for: job)
        let displayDocument = ReviewMonitorCommandOutputDisplayDocument.make(
            from: sourceDocument,
            expandedBlockIDs: []
        )
        let blockIDs = displayDocument.commandOutputPanels.map(\.blockID)

        #expect(displayDocument.commandOutputPanels.count == 2)
        #expect(Set(blockIDs).count == blockIDs.count)
        #expect(blockIDs.first == ReviewMonitorLogBlockID("commandOutput:cmd-1"))
    }

    @Test func activeCommandLifecycleDisplaysRunningTitle() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let metadata = ReviewLogEntry.Metadata(
            sourceType: "commandExecution",
            status: "inProgress",
            itemID: "cmd-1",
            command: "swift test",
            startedAt: startedAt,
            commandStatus: "inProgress"
        )
        let job = CodexReviewJob.makeForTesting(
            id: "job-command-running",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .command, groupID: "cmd-1", text: "$ swift test", metadata: metadata),
            ]
        )

        let displayDocument = ReviewMonitorCommandOutputDisplayDocument.make(
            from: document(for: job),
            expandedBlockIDs: [],
            currentDate: Date(timeIntervalSince1970: 104)
        )
        let displayText = displayDocument.text.replacingOccurrences(
            of: ReviewMonitorCommandOutputDisplayDocument.toggleAttachmentCharacter,
            with: ""
        )

        #expect(displayText == "Running swift test")
        #expect(displayDocument.commandOutputPanels.first?.isActive == true)
        #expect(displayDocument.commandOutputPanels.first?.startedAt == startedAt)
    }

    @Test func completedCommandLifecycleDisplaysFixedDurationTitle() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let completedMetadata = ReviewLogEntry.Metadata(
            sourceType: "commandExecution",
            status: "completed",
            itemID: "cmd-1",
            command: "swift test",
            startedAt: startedAt,
            completedAt: Date(timeIntervalSince1970: 103.4),
            durationMs: 3_000,
            commandStatus: "completed"
        )
        let job = CodexReviewJob.makeForTesting(
            id: "job-command-completed",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .command, groupID: "cmd-1", text: "$ swift test"),
                .init(kind: .commandOutput, groupID: "cmd-1", text: "ok", metadata: completedMetadata),
            ]
        )
        let sourceDocument = document(for: job)
        let firstDisplayDocument = ReviewMonitorCommandOutputDisplayDocument.make(
            from: sourceDocument,
            expandedBlockIDs: [],
            currentDate: Date(timeIntervalSince1970: 120)
        )
        let laterDisplayDocument = ReviewMonitorCommandOutputDisplayDocument.make(
            from: sourceDocument,
            expandedBlockIDs: [],
            currentDate: Date(timeIntervalSince1970: 180)
        )

        #expect(firstDisplayDocument.text == laterDisplayDocument.text)
        #expect(firstDisplayDocument.text.replacingOccurrences(
            of: ReviewMonitorCommandOutputDisplayDocument.toggleAttachmentCharacter,
            with: ""
        ) == "Ran swift test for 3s")
        #expect(firstDisplayDocument.commandOutputPanels.first?.isActive == false)
    }

    @Test func statusOnlyCompletedCommandWithoutOutputDisplaysRanTitle() {
        let job = CodexReviewJob.makeForTesting(
            id: "job-command-completed-status-only",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(
                    kind: .command,
                    groupID: "cmd-1",
                    text: "$ swift test",
                    metadata: .init(sourceType: "commandExecution", status: "completed")
                ),
            ]
        )

        let displayDocument = ReviewMonitorCommandOutputDisplayDocument.make(
            from: document(for: job),
            expandedBlockIDs: []
        )
        let displayText = displayDocument.text.replacingOccurrences(
            of: ReviewMonitorCommandOutputDisplayDocument.toggleAttachmentCharacter,
            with: ""
        )

        #expect(displayText == "Ran swift test")
        #expect(displayDocument.commandOutputPanels.first?.isActive == false)
    }

    @Test func canceledCommandStatusIsInactive() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let job = CodexReviewJob.makeForTesting(
            id: "job-command-canceled",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(
                    kind: .command,
                    groupID: "cmd-1",
                    text: "$ swift test",
                    metadata: .init(
                        sourceType: "commandExecution",
                        status: "canceled",
                        command: "swift test",
                        startedAt: startedAt
                    )
                ),
            ]
        )

        let displayDocument = ReviewMonitorCommandOutputDisplayDocument.make(
            from: document(for: job),
            expandedBlockIDs: []
        )
        let displayText = displayDocument.text.replacingOccurrences(
            of: ReviewMonitorCommandOutputDisplayDocument.toggleAttachmentCharacter,
            with: ""
        )
        let attachmentCount = displayDocument.text.filter {
            String($0) == ReviewMonitorCommandOutputDisplayDocument.toggleAttachmentCharacter
        }.count

        #expect(displayText == "Ran swift test")
        #expect(displayDocument.commandOutputPanels.first?.isActive == false)
        #expect(attachmentCount == 1)
    }

    @Test func commandActionsDriveReadSearchAndListTitles() {
        let readJob = CodexReviewJob.makeForTesting(
            id: "job-command-read",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(
                    kind: .command,
                    groupID: "cmd-1",
                    text: "$ cat ThreadItem.ts",
                    metadata: .init(
                        sourceType: "commandExecution",
                        status: "inProgress",
                        itemID: "cmd-1",
                        command: "cat ThreadItem.ts",
                        commandActions: [
                            .init(kind: .read, command: "cat ThreadItem.ts", name: "ThreadItem.ts", path: "ThreadItem.ts")
                        ],
                        commandStatus: "inProgress"
                    )
                ),
            ]
        )
        let searchJob = CodexReviewJob.makeForTesting(
            id: "job-command-search",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .command, groupID: "cmd-2", text: "$ rg files"),
                .init(
                    kind: .commandOutput,
                    groupID: "cmd-2",
                    text: "ThreadItem.ts",
                    metadata: .init(
                        sourceType: "commandExecution",
                        status: "completed",
                        itemID: "cmd-2",
                        command: "rg files",
                        durationMs: 2_000,
                        commandActions: [
                            .init(kind: .search, command: "rg files", path: "/tmp/workspace", query: "files")
                        ],
                        commandStatus: "completed"
                    )
                ),
            ]
        )

        let readText = ReviewMonitorCommandOutputDisplayDocument.make(
            from: document(for: readJob),
            expandedBlockIDs: []
        ).text.replacingOccurrences(
            of: ReviewMonitorCommandOutputDisplayDocument.toggleAttachmentCharacter,
            with: ""
        )
        let searchText = ReviewMonitorCommandOutputDisplayDocument.make(
            from: document(for: searchJob),
            expandedBlockIDs: []
        ).text.replacingOccurrences(
            of: ReviewMonitorCommandOutputDisplayDocument.toggleAttachmentCharacter,
            with: ""
        )

        #expect(readText == "Reading ThreadItem.ts")
        #expect(searchText == "Searched files in workspace for 2s")
    }

    @Test func commandTimerAttachmentViewCountsUpFromStartDate() {
        let attachment = ReviewMonitorCommandOutputTimerAttachment(
            blockID: ReviewMonitorLogBlockID("commandOutput:cmd-1"),
            startedAt: Date(timeIntervalSince1970: 100),
            font: .systemFont(ofSize: 13)
        )
        let view = ReviewMonitorCommandOutputTimerAttachmentView(attachment: attachment)

        view.updateText(referenceDate: Date(timeIntervalSince1970: 103), animated: false)
        #expect(view.displayedTextForTesting == " for 3s")
        view.updateText(referenceDate: Date(timeIntervalSince1970: 164), animated: false)
        #expect(view.displayedTextForTesting == " for 1m 4s")
    }

    @Test func commandTimerAttachmentViewAnimatesChangedDigits() {
        let attachment = ReviewMonitorCommandOutputTimerAttachment(
            blockID: ReviewMonitorLogBlockID("commandOutput:cmd-1"),
            startedAt: Date(timeIntervalSince1970: 100),
            font: .systemFont(ofSize: 13)
        )
        let view = ReviewMonitorCommandOutputTimerAttachmentView(attachment: attachment)

        view.updateText(referenceDate: Date(timeIntervalSince1970: 103), animated: false)
        view.updateText(referenceDate: Date(timeIntervalSince1970: 104))

        #expect(view.displayedTextForTesting == " for 4s")
        #expect(view.activeNumericTransitionCountForTesting > 0)
        view.completeNumericTransitionsForTesting()
        #expect(view.activeNumericTransitionCountForTesting == 0)
    }

    @Test func commandTimerAttachmentViewKeepsWidthWhenDigitsGrow() {
        let attachment = ReviewMonitorCommandOutputTimerAttachment(
            blockID: ReviewMonitorLogBlockID("commandOutput:cmd-1"),
            startedAt: Date(timeIntervalSince1970: 100),
            font: .systemFont(ofSize: 13)
        )
        let view = ReviewMonitorCommandOutputTimerAttachmentView(attachment: attachment)
        let initialWidth = view.intrinsicContentSize.width

        view.updateText(referenceDate: Date(timeIntervalSince1970: 109), animated: false)
        view.updateText(referenceDate: Date(timeIntervalSince1970: 110))

        #expect(view.displayedTextForTesting == " for 10s")
        #expect(view.intrinsicContentSize.width == initialWidth)
    }

    @Test func commandTimerAttachmentViewDoesNotAnimateWhenDisabled() {
        let attachment = ReviewMonitorCommandOutputTimerAttachment(
            blockID: ReviewMonitorLogBlockID("commandOutput:cmd-1"),
            startedAt: Date(timeIntervalSince1970: 100),
            font: .systemFont(ofSize: 13),
            animatesNumericTransition: false
        )
        let view = ReviewMonitorCommandOutputTimerAttachmentView(attachment: attachment)

        view.updateText(referenceDate: Date(timeIntervalSince1970: 103), animated: false)
        view.updateText(referenceDate: Date(timeIntervalSince1970: 104))

        #expect(view.displayedTextForTesting == " for 4s")
        #expect(view.activeNumericTransitionCountForTesting == 0)
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

    @Test func commandOutputPanelResultUsesMergedCompletionMetadata() {
        let job = CodexReviewJob.makeForTesting(
            id: "job-command-output-merged-result",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(
                    kind: .command,
                    groupID: "cmd-1",
                    replacesGroup: true,
                    text: "$ swift test",
                    metadata: .init(
                        sourceType: "commandExecution",
                        status: "inProgress",
                        itemID: "cmd-1",
                        command: "swift test",
                        commandStatus: "inProgress"
                    )
                ),
                .init(
                    kind: .commandOutput,
                    groupID: "cmd-1",
                    text: "Tests passed",
                    metadata: .init(
                        sourceType: "commandExecution",
                        title: "Command output",
                        itemID: "cmd-1"
                    )
                ),
                .init(
                    kind: .command,
                    groupID: "cmd-1",
                    replacesGroup: true,
                    text: "$ swift test",
                    metadata: .init(
                        sourceType: "commandExecution",
                        status: "succeeded",
                        itemID: "cmd-1",
                        command: "swift test",
                        exitCode: 0,
                        commandStatus: "succeeded"
                    )
                ),
            ]
        )

        let displayDocument = ReviewMonitorCommandOutputDisplayDocument.make(
            from: document(for: job),
            expandedBlockIDs: [ReviewMonitorLogBlockID("commandOutput:cmd-1")]
        )

        #expect(displayDocument.commandOutputPanels.first?.outputText == "Tests passed")
        #expect(displayDocument.commandOutputPanels.first?.exitText == "Success")
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
