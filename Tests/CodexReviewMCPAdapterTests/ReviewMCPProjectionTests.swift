import Foundation
import Testing
@testable import CodexReviewMCPAdapter
import CodexReviewDomain

@MainActor
@Suite("review MCP projection")
struct ReviewMCPProjectionTests {
    @Test func capturesTimelineOrderActiveItemsAndLatestActivity() throws {
        let timeline = ReviewTimeline()
        let startedAt = Date(timeIntervalSince1970: 10)
        let updatedAt = Date(timeIntervalSince1970: 12)

        timeline.apply(.itemStarted(.init(
            id: "command-1",
            kind: .commandExecution,
            family: .command,
            phase: .running,
            content: .command(.init(command: "swift test", cwd: "/tmp/project")),
            startedAt: startedAt
        )), at: startedAt)
        timeline.apply(.itemStarted(.init(
            id: "tool-1",
            kind: .mcpToolCall,
            family: .tool,
            phase: .running,
            content: .toolCall(.init(server: "codex_review", tool: "review_read", arguments: "{\"jobId\":\"job-1\"}"))
        )), at: updatedAt)

        let projection = ReviewMCPProjection(timeline: timeline)

        #expect(projection.timelineRevision == timeline.revision)
        #expect(projection.orderedItemIDs.map(\.rawValue) == ["command-1", "tool-1"])
        #expect(projection.activeItemIDs.map(\.rawValue) == ["command-1", "tool-1"])
        #expect(projection.activeItemCount == 2)
        #expect(projection.latestActivityID?.rawValue == "tool-1")
        #expect(projection.items.map(\.id.rawValue) == ["command-1", "tool-1"])
        #expect(projection.items.map(\.isActive) == [true, true])

        let command = try #require(projection.items.first)
        #expect(command.kind == .commandExecution)
        #expect(command.family == .command)
        #expect(command.phase == .running)
        #expect(command.startedAt == startedAt)
        guard case .command(let commandContent) = command.content else {
            Issue.record("Expected command content")
            return
        }
        #expect(commandContent.command == "swift test")
        #expect(commandContent.cwd == "/tmp/project")

        let toolCall = try #require(projection.items.last)
        guard case .toolCall(let toolCallContent) = toolCall.content else {
            Issue.record("Expected tool call content")
            return
        }
        #expect(toolCallContent.server == "codex_review")
        #expect(toolCallContent.tool == "review_read")
        #expect(toolCallContent.arguments == "{\"jobId\":\"job-1\"}")
    }

    @Test func capturesToolCallProgress() throws {
        let timeline = ReviewTimeline()
        timeline.apply(.itemUpdated(.init(
            id: "tool-1:progress",
            kind: .mcpToolCall,
            family: .tool,
            phase: .running,
            content: .toolCall(.init(
                namespace: "mcp",
                server: "codex_review",
                tool: "review_read",
                progress: "Reading review job"
            ))
        )))

        let projection = ReviewMCPProjection(timeline: timeline)
        let item = try #require(projection.items.first)
        guard case .toolCall(let toolCall) = item.content else {
            Issue.record("Expected tool call content")
            return
        }

        #expect(toolCall.namespace == "mcp")
        #expect(toolCall.server == "codex_review")
        #expect(toolCall.tool == "review_read")
        #expect(toolCall.progress == "Reading review job")
    }

    @Test func capturesTerminalStateAndAllTimelineContentCases() throws {
        let timeline = ReviewTimeline()
        let contents: [(String, ReviewItemKind, ReviewItemFamily, ReviewTimelineItem.Content)] = [
            ("approval-1", "approval", .approval, .approval(.init(title: "Approve command", detail: "swift test"))),
            ("command-1", .commandExecution, .command, .command(.init(
                command: "swift test",
                cwd: "/tmp/project",
                output: "ok",
                exitCode: 0
            ))),
            ("context-1", .contextCompaction, .contextCompaction, .contextCompaction(.init(title: "Compacted context"))),
            ("diagnostic-1", "diagnostic", .diagnostic, .diagnostic(.init(message: "Network recovered"))),
            ("file-1", .fileChange, .fileChange, .fileChange(.init(title: "Sources/File.swift", output: "+ change"))),
            ("message-1", .agentMessage, .message, .message(.init(text: "Review complete"))),
            ("plan-1", .plan, .plan, .plan(.init(markdown: "- [x] Inspect"))),
            ("reasoning-1", .reasoning, .reasoning, .reasoning(.init(text: "Looks stable", style: .summary))),
            ("search-1", .webSearch, .search, .search(.init(query: "Swift MCP", result: "Result summary"))),
            ("tool-1", .mcpToolCall, .tool, .toolCall(.init(
                namespace: "mcp",
                server: "codex_review",
                tool: "review_read",
                result: "ok"
            ))),
            ("unknown-1", "custom", .unknown, .unknown(.init(title: "Custom item", detail: "Custom detail"))),
        ]

        for (offset, item) in contents.enumerated() {
            let completedAt = Date(timeIntervalSince1970: Double(100 + offset))
            timeline.apply(.itemCompleted(.init(
                id: .init(rawValue: item.0),
                kind: item.1,
                family: item.2,
                phase: .completed,
                content: item.3,
                completedAt: completedAt,
                durationMs: 25 + offset
            )), at: completedAt)
        }
        timeline.apply(.reviewCompleted(summary: "No findings.", result: "No correctness issues found."))

        let projection = ReviewMCPProjection(timeline: timeline)

        #expect(projection.orderedItemIDs.map(\.rawValue) == contents.map { $0.0 })
        #expect(projection.activeItemIDs.isEmpty)
        #expect(projection.activeItemCount == 0)
        #expect(projection.terminalSummary == "No findings.")
        #expect(projection.terminalResult == "No correctness issues found.")
        #expect(projection.items.map(\.content.type) == [
            "approval",
            "command",
            "contextCompaction",
            "diagnostic",
            "fileChange",
            "message",
            "plan",
            "reasoning",
            "search",
            "toolCall",
            "unknown",
        ])

        guard case .approval(let approval) = projection.items[0].content else {
            Issue.record("Expected approval content")
            return
        }
        #expect(approval.title == "Approve command")
        #expect(approval.detail == "swift test")

        guard case .fileChange(let fileChange) = projection.items[4].content else {
            Issue.record("Expected file change content")
            return
        }
        #expect(fileChange.title == "Sources/File.swift")
        #expect(fileChange.output == "+ change")

        guard case .search(let search) = projection.items[8].content else {
            Issue.record("Expected search content")
            return
        }
        #expect(search.query == "Swift MCP")
        #expect(search.result == "Result summary")
    }
}
