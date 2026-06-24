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

    @Test func outputOnlyCommandLogsDoNotSynthesizePlaceholderCommandLine() throws {
        let outputOnlyJob = CodexReviewJob.makeForTesting(
            id: "job-output-only-command",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(
                    kind: .commandOutput,
                    groupID: "cmd-output-only",
                    text: "Build complete\n",
                    metadata: .init(
                        sourceType: "commandExecution",
                        title: "Command output",
                        itemID: "cmd-output-only"
                    )
                ),
            ]
        )

        let outputOnlyItem = try #require(outputOnlyJob.timeline.item(for: "cmd-output-only"))
        guard case .command(let outputOnlyCommand) = outputOnlyItem.content else {
            Issue.record("Expected command timeline content.")
            return
        }
        #expect(outputOnlyCommand.command == "")
        #expect(outputOnlyJob.timelineLogEntries.map(\.kind) == [.commandOutput])
        #expect(outputOnlyJob.timelineLogEntries.map(\.text) == ["Build complete\n"])

        let mixedJob = CodexReviewJob.makeForTesting(
            id: "job-generic-command-title",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running"
        )
        mixedJob.timeline.apply(.itemCompleted(.init(
            id: "cmd-generic",
            kind: .commandExecution,
            family: .command,
            phase: .completed,
            content: .command(.init(command: "Command", output: "Build complete\n"))
        )))

        #expect(mixedJob.timelineLogEntries.map(\.kind) == [.commandOutput])
        #expect(mixedJob.timelineLogEntries.map(\.text) == ["Build complete\n"])
    }

    @Test func fileChangeCommandOutputChunksAccumulateInTimelineProjection() throws {
        let metadata = ReviewLogEntry.Metadata(
            sourceType: "fileChange",
            title: "Updated Sources/App.swift",
            status: "updated",
            itemID: "file-1"
        )
        let job = CodexReviewJob.makeForTesting(
            id: "job-file-change-output-chunks",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(
                    kind: .commandOutput,
                    groupID: "file-1",
                    text: "Sources/App.swift | 1 +\n",
                    metadata: metadata
                ),
                .init(
                    kind: .commandOutput,
                    groupID: "file-1",
                    text: "+ new line\n",
                    metadata: metadata
                ),
            ]
        )

        let item = try #require(job.timeline.item(for: "file-1"))
        guard case .fileChange(let fileChange) = item.content else {
            Issue.record("Expected file-change timeline content.")
            return
        }
        #expect(fileChange.output == "Sources/App.swift | 1 +\n+ new line\n")
    }

    @Test func metadataFreeCommandOutputAppendPreservesTerminalTimelineState() throws {
        let commandMetadata = ReviewLogEntry.Metadata(
            sourceType: "commandExecution",
            status: "completed",
            itemID: "cmd-1",
            command: "swift test",
            exitCode: 0,
            commandStatus: "completed"
        )
        let job = CodexReviewJob.makeForTesting(
            id: "job-command-output-after-completion",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .succeeded,
            summary: "Done",
            logEntries: [
                .init(
                    kind: .command,
                    groupID: "cmd-1",
                    replacesGroup: true,
                    text: "$ swift test",
                    metadata: commandMetadata
                ),
                .init(kind: .commandOutput, groupID: "cmd-1", text: "Tests passed"),
            ]
        )

        let item = try #require(job.timeline.item(for: "cmd-1"))
        guard case .command(let command) = item.content else {
            Issue.record("Expected command timeline content.")
            return
        }
        #expect(item.phase == .completed)
        #expect(job.timeline.activeItemIDs.contains("cmd-1") == false)
        #expect(command.output == "Tests passed")
        #expect(command.exitCode == 0)
    }

    @Test func failedToolCallLogDoesNotCopyErrorTextIntoTimelineResult() throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-failed-tool-call",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(
                    kind: .toolCall,
                    groupID: "tool-1",
                    text: "tool failed",
                    metadata: .init(
                        sourceType: "mcpToolCall",
                        itemID: "tool-1",
                        server: "codex_review",
                        tool: "review_start",
                        errorText: "tool failed"
                    )
                ),
            ]
        )

        let item = try #require(job.timeline.items.first { $0.family == .tool })
        guard case .toolCall(let toolCall) = item.content else {
            Issue.record("Expected tool-call timeline content.")
            return
        }
        #expect(toolCall.error == "tool failed")
        #expect(toolCall.result == nil)
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
