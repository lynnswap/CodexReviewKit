import Foundation
import Testing
@testable import CodexReviewDomain

@MainActor
@Suite("review timeline")
struct ReviewTimelineTests {
    @Test func typedIDsPreserveRawValue() throws {
        let id: ReviewTimelineItem.ID = "item-1"
        #expect(id.rawValue == "item-1")
        #expect(ReviewItemKind(rawValue: "futureItem").rawValue == "futureItem")
        #expect(ReviewWireEventKind(rawValue: "future/event").rawValue == "future/event")

        let encodedID = try JSONEncoder().encode(id)
        #expect(String(data: encodedID, encoding: .utf8) == #""item-1""#)
        #expect(try JSONDecoder().decode(ReviewTimelineItem.ID.self, from: encodedID) == id)

        let actionKind = ReviewCommandActionKind(rawValue: "futureAction")
        let encodedActionKind = try JSONEncoder().encode(actionKind)
        #expect(try JSONDecoder().decode(ReviewCommandActionKind.self, from: encodedActionKind) == actionKind)
    }

    @Test func contentCodingRetainsUnknownRawValues() throws {
        let content = ReviewTimelineItem.Content.unknown(.init(
            title: "Future item",
            detail: "raw detail",
            rawKind: .init(rawValue: "futureAppServerItem"),
            rawStatus: "needsExternalDecision",
            references: [
                .init(kind: .init(rawValue: "wirePayload"), value: "payload-1", label: "Wire payload"),
            ]
        ))

        let encoded = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(ReviewTimelineItem.Content.self, from: encoded)

        #expect(decoded == content)
    }

    @Test func semanticContentCarriesLifecycleFields() throws {
        let content = ReviewTimelineItem.Content.toolCall(.init(
            namespace: "mcp",
            server: "codex_review",
            tool: "review_start",
            arguments: #"{"target":"baseBranch"}"#,
            result: "No findings.",
            error: nil,
            status: .completed,
            durationMs: 1_250,
            appContext: .init(rawValue: "reviewMonitor"),
            pluginID: .init(rawValue: "codex-review"),
            callID: "tool-call-1",
            progress: "awaiting backend"
        ))

        let encoded = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(ReviewTimelineItem.Content.self, from: encoded)

        #expect(decoded == content)

        let command = ReviewTimelineItem.Command(
            command: "rg ReviewTimeline",
            cwd: "/repo",
            status: .inProgress,
            source: .init(rawValue: "appServer"),
            processID: "pid-1",
            actions: [
                .init(kind: .search, command: "rg ReviewTimeline", query: "ReviewTimeline"),
            ],
            durationMs: 42
        )
        #expect(command.actions.first?.kind == .search)

        let fileChange = ReviewTimelineItem.FileChange(
            title: "Sources/App.swift",
            paths: ["Sources/App.swift"],
            patch: "@@ patch",
            status: .updated
        )
        #expect(fileChange.paths == ["Sources/App.swift"])
        #expect(fileChange.status == .updated)

        let approval = ReviewTimelineItem.Approval(
            title: "Run command?",
            decision: .approved,
            scope: .init(rawValue: "command"),
            risk: .medium,
            status: .decided
        )
        #expect(approval.decision == .approved)

        let diagnostic = ReviewTimelineItem.Diagnostic(
            message: "Backend overloaded",
            severity: .warning,
            retry: .init(state: .scheduled, attempt: 1, maxAttempts: 3, delayMs: 500)
        )
        #expect(diagnostic.retry?.state == .scheduled)
    }

    @Test func commandOutputAggregatesIntoSameItemInstance() throws {
        let timeline = ReviewTimeline()
        let itemID: ReviewTimelineItem.ID = "cmd-1"

        timeline.apply(.itemStarted(.init(
            id: itemID,
            kind: .commandExecution,
            family: .command,
            phase: .running,
            content: .command(.init(command: "swift test", status: .inProgress))
        )))
        let item = try #require(timeline.item(for: itemID))
        let identity = ObjectIdentifier(item)

        timeline.apply(.textDelta(
            itemID: itemID,
            kind: .commandExecution,
            family: .command,
            content: .command(.init(command: "swift test")),
            delta: "first\n"
        ))
        timeline.apply(.textDelta(
            itemID: itemID,
            kind: .commandExecution,
            family: .command,
            content: .command(.init(command: "swift test")),
            delta: "second\n"
        ))
        timeline.apply(.itemCompleted(.init(
            id: itemID,
            kind: .commandExecution,
            family: .command,
            phase: .completed,
            content: .command(.init(
                command: "swift test",
                exitCode: 0,
                status: .completed,
                durationMs: 1_500
            )),
            durationMs: 1_500
        )))

        let updated = try #require(timeline.item(for: itemID))
        #expect(ObjectIdentifier(updated) == identity)
        #expect(updated.phase == .completed)
        #expect(updated.durationMs == 1_500)
        #expect(timeline.activeItemIDs.isEmpty)
        if case .command(let command) = updated.content {
            #expect(command.output == "first\nsecond\n")
            #expect(command.exitCode == 0)
            #expect(command.status == .completed)
            #expect(command.durationMs == 1_500)
        } else {
            Issue.record("expected command content")
        }
    }

    @Test func deltaBeforeSnapshotMergesIntoStartedItem() throws {
        let timeline = ReviewTimeline()
        let itemID: ReviewTimelineItem.ID = "cmd-placeholder"

        timeline.apply(.textDelta(
            itemID: itemID,
            kind: .commandExecution,
            family: .command,
            content: .command(.init(command: "Command")),
            delta: "early output\n"
        ))
        let placeholder = try #require(timeline.item(for: itemID))
        let identity = ObjectIdentifier(placeholder)

        timeline.apply(.itemStarted(.init(
            id: itemID,
            kind: .commandExecution,
            family: .command,
            phase: .running,
            content: .command(.init(
                command: "git diff",
                cwd: "/repo",
                status: .inProgress,
                actions: [.init(kind: .read, path: "Sources/App.swift")]
            ))
        )))

        let updated = try #require(timeline.item(for: itemID))
        #expect(ObjectIdentifier(updated) == identity)
        if case .command(let command) = updated.content {
            #expect(command.command == "git diff")
            #expect(command.cwd == "/repo")
            #expect(command.output == "early output\n")
            #expect(command.status == .inProgress)
            #expect(command.actions == [.init(kind: .read, path: "Sources/App.swift")])
        } else {
            Issue.record("expected command content")
        }
    }

    @Test func itemStatusTransitionsDoNotEraseSemanticSnapshot() throws {
        let timeline = ReviewTimeline()
        let itemID: ReviewTimelineItem.ID = "tool-2"

        timeline.apply(.itemStarted(.init(
            id: itemID,
            kind: .mcpToolCall,
            family: .tool,
            phase: .running,
            content: .toolCall(.init(
                namespace: "mcp",
                server: "codex_review",
                tool: "review_start",
                status: .started,
                progress: "queued"
            ))
        )))

        timeline.apply(.itemUpdated(.init(
            id: itemID,
            kind: .mcpToolCall,
            family: .tool,
            phase: .running,
            content: .toolCall(.init(
                result: "partial",
                status: .inProgress,
                durationMs: 100
            ))
        )))

        timeline.apply(.itemCompleted(.init(
            id: itemID,
            kind: .mcpToolCall,
            family: .tool,
            phase: .failed,
            content: .toolCall(.init(
                error: "tool failed",
                status: .failed,
                durationMs: 200
            )),
            durationMs: 200
        )))

        let item = try #require(timeline.item(for: itemID))
        #expect(item.phase == .failed)
        #expect(item.durationMs == 200)
        #expect(timeline.activeItemIDs.isEmpty)
        if case .toolCall(let toolCall) = item.content {
            #expect(toolCall.namespace == "mcp")
            #expect(toolCall.server == "codex_review")
            #expect(toolCall.tool == "review_start")
            #expect(toolCall.result == "partial")
            #expect(toolCall.error == "tool failed")
            #expect(toolCall.status == .failed)
            #expect(toolCall.durationMs == 200)
            #expect(toolCall.progress == "queued")
        } else {
            Issue.record("expected tool call content")
        }
    }

    @Test func terminalEventClearsActiveItems() throws {
        let timeline = ReviewTimeline()
        timeline.apply(.itemStarted(.init(
            id: "tool-1",
            kind: .mcpToolCall,
            family: .tool,
            phase: .running,
            content: .toolCall(.init(server: "server", tool: "tool"))
        )))
        #expect(timeline.activeItemIDs == ["tool-1"])

        timeline.apply(.reviewFailed("failed"))

        #expect(timeline.activeItemIDs.isEmpty)
        #expect(timeline.terminalStatus == .failed)
        #expect(timeline.terminalSummary == "failed")
    }

    @Test func terminalStatusIsSeparateFromSummaryAndResult() throws {
        let timeline = ReviewTimeline()

        timeline.apply(.reviewCompleted(summary: "clean", result: "No findings"))
        #expect(timeline.isTerminal)
        #expect(timeline.terminalStatus == .succeeded)
        #expect(timeline.terminalSummary == "clean")
        #expect(timeline.terminalResult == "No findings")

        timeline.apply(.runStarted(turnID: "turn-2", reviewThreadID: "review-thread", model: "gpt"))
        #expect(timeline.isTerminal == false)
        #expect(timeline.terminalStatus == nil)
        #expect(timeline.terminalSummary == nil)
        #expect(timeline.terminalResult == nil)

        timeline.apply(.reviewCancelled("cancelled by user"))
        #expect(timeline.isTerminal)
        #expect(timeline.terminalStatus == .cancelled)
        #expect(timeline.terminalSummary == "cancelled by user")
        #expect(timeline.terminalResult == nil)
    }
}
