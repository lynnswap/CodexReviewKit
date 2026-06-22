import Foundation
import Testing
import CodexReviewDomain
@testable import ReviewMonitorRendering

@MainActor
@Suite("review timeline document renderer")
struct ReviewTimelineDocumentRendererTests {
    @Test func documentUsesTimelineOrderingStableBlockIDsAndActiveState() throws {
        let timeline = ReviewTimeline()

        timeline.apply(.itemStarted(.init(
            id: "cmd-1",
            kind: .commandExecution,
            family: .command,
            phase: .running,
            content: .command(.init(command: "swift test", status: .inProgress))
        )))
        timeline.apply(.itemCompleted(.init(
            id: "msg-1",
            kind: .agentMessage,
            family: .message,
            phase: .completed,
            content: .message(.init(text: "done"))
        )))

        let document = ReviewTimelineDocumentRenderer().document(from: timeline)

        #expect(document.blocks.map(\.sourceItemID) == [itemID("cmd-1"), itemID("msg-1")])
        #expect(document.orderedBlockIDs == [blockID("cmd-1"), blockID("msg-1")])
        #expect(document.activeBlockIDs == [blockID("cmd-1")])
        #expect(document.activeBlockCount == 1)
        #expect(document.latestActivityBlockID == blockID("msg-1"))

        let commandBlock = try requireBlock(document, id: "cmd-1")
        #expect(commandBlock.id == blockID("cmd-1"))
        #expect(commandBlock.kind == .commandExecution)
        #expect(commandBlock.family == .command)
        #expect(commandBlock.phase == .running)
        #expect(commandBlock.isActive)

        let messageBlock = try requireBlock(document, id: "msg-1")
        #expect(messageBlock.phase == .completed)
        #expect(messageBlock.isActive == false)
    }

    @Test func documentPreservesSemanticPayloadsForTimelineFamilies() throws {
        let timeline = ReviewTimeline()

        start(
            timeline,
            id: "approval-1",
            kind: "approvalRequest",
            family: .approval,
            phase: .awaitingApproval,
            content: .approval(.init(
                title: "Run command?",
                detail: "swift test",
                decision: .approved,
                scope: "command",
                risk: .medium,
                status: .decided
            ))
        )
        complete(
            timeline,
            id: "cmd-1",
            kind: .commandExecution,
            family: .command,
            content: .command(.init(
                command: "swift test",
                cwd: "/repo",
                output: "ok",
                exitCode: 0,
                status: .completed,
                source: "appServer",
                processID: "pid-1",
                actions: [
                    .init(kind: .read, path: "Sources/App.swift"),
                    .init(kind: .search, command: "rg ReviewTimeline", query: "ReviewTimeline"),
                ],
                durationMs: 1_500
            )),
            durationMs: 1_500
        )
        complete(
            timeline,
            id: "tool-1",
            kind: .mcpToolCall,
            family: .tool,
            content: .toolCall(.init(
                namespace: "mcp",
                server: "codex_review",
                tool: "review_start",
                arguments: #"{"target":"baseBranch"}"#,
                result: "No findings.",
                error: nil,
                status: .completed,
                durationMs: 2_000,
                appContext: "reviewMonitor",
                pluginID: "codex-review",
                callID: "call-1",
                progress: "awaiting backend"
            )),
            durationMs: 2_000
        )
        complete(
            timeline,
            id: "file-1",
            kind: .fileChange,
            family: .fileChange,
            content: .fileChange(.init(
                title: "Sources/App.swift",
                output: "modified",
                paths: ["Sources/App.swift"],
                patch: "@@ patch",
                status: .updated
            ))
        )
        complete(
            timeline,
            id: "search-1",
            kind: .webSearch,
            family: .search,
            content: .search(.init(
                query: "ReviewTimeline",
                result: "2 results",
                status: .completed,
                resultCount: 2,
                durationMs: 300
            ))
        )
        start(
            timeline,
            id: "diagnostic-1",
            kind: "backendDiagnostic",
            family: .diagnostic,
            phase: .running,
            content: .diagnostic(.init(
                message: "Backend overloaded",
                severity: .warning,
                retry: .init(state: .scheduled, attempt: 1, maxAttempts: 3, delayMs: 500)
            ))
        )
        complete(
            timeline,
            id: "context-1",
            kind: .contextCompaction,
            family: .contextCompaction,
            content: .contextCompaction(.init(
                title: "Compacting context",
                status: .completed,
                inputTokens: 10_000,
                outputTokens: 2_500
            ))
        )
        complete(
            timeline,
            id: "message-1",
            kind: .agentMessage,
            family: .message,
            content: .message(.init(text: "Agent says hi"))
        )
        complete(
            timeline,
            id: "plan-1",
            kind: .plan,
            family: .plan,
            content: .plan(.init(markdown: "- [ ] Task"))
        )
        complete(
            timeline,
            id: "reasoning-1",
            kind: .reasoning,
            family: .reasoning,
            content: .reasoning(.init(text: "Thinking", style: .summary))
        )
        complete(
            timeline,
            id: "unknown-1",
            kind: "futureItem",
            family: .unknown,
            content: .unknown(.init(
                title: "Future item",
                detail: "raw detail",
                rawKind: "futureAppServerItem",
                rawStatus: "needsExternalDecision",
                references: [
                    .init(kind: "wirePayload", value: "payload-1", label: "Wire payload"),
                ]
            ))
        )

        let document = ReviewTimelineDocumentRenderer().document(from: timeline)

        let approval = try requireApproval(document, id: "approval-1")
        #expect(approval.decision == .approved)
        #expect(approval.scope == "command")
        #expect(approval.risk == .medium)
        #expect(approval.status == .decided)

        let commandBlock = try requireBlock(document, id: "cmd-1")
        let command = try requireCommand(commandBlock)
        #expect(command.title == "swift test")
        #expect(command.command == "swift test")
        #expect(command.cwd == "/repo")
        #expect(command.output == "ok")
        #expect(command.exitCode == 0)
        #expect(command.status == .completed)
        #expect(command.source == "appServer")
        #expect(command.processID == "pid-1")
        #expect(command.actions.map(\.kind) == [.read, .search])
        #expect(command.actions[0].path == "Sources/App.swift")
        #expect(command.actions[1].query == "ReviewTimeline")
        #expect(command.durationMs == 1_500)
        #expect(commandBlock.durationMs == 1_500)

        let tool = try requireToolCall(document, id: "tool-1")
        #expect(tool.namespace == "mcp")
        #expect(tool.server == "codex_review")
        #expect(tool.name == "review_start")
        #expect(tool.arguments == #"{"target":"baseBranch"}"#)
        #expect(tool.result == "No findings.")
        #expect(tool.error == nil)
        #expect(tool.status == .completed)
        #expect(tool.durationMs == 2_000)
        #expect(tool.appContext == "reviewMonitor")
        #expect(tool.pluginID == "codex-review")
        #expect(tool.callID == "call-1")
        #expect(tool.progress == "awaiting backend")

        let fileChange = try requireFileChange(document, id: "file-1")
        #expect(fileChange.paths == ["Sources/App.swift"])
        #expect(fileChange.patch == "@@ patch")
        #expect(fileChange.status == .updated)
        #expect(fileChange.output == "modified")

        let search = try requireSearch(document, id: "search-1")
        #expect(search.query == "ReviewTimeline")
        #expect(search.result == "2 results")
        #expect(search.status == .completed)
        #expect(search.resultCount == 2)
        #expect(search.durationMs == 300)

        let diagnostic = try requireDiagnostic(document, id: "diagnostic-1")
        #expect(diagnostic.severity == .warning)
        #expect(diagnostic.retry?.state == .scheduled)
        #expect(diagnostic.retry?.attempt == 1)
        #expect(diagnostic.retry?.maxAttempts == 3)
        #expect(diagnostic.retry?.delayMs == 500)

        let contextCompaction = try requireContextCompaction(document, id: "context-1")
        #expect(contextCompaction.status == .completed)
        #expect(contextCompaction.inputTokens == 10_000)
        #expect(contextCompaction.outputTokens == 2_500)

        let message = try requireMessage(document, id: "message-1")
        #expect(message.text == "Agent says hi")

        let plan = try requirePlan(document, id: "plan-1")
        #expect(plan.markdown == "- [ ] Task")

        let reasoning = try requireReasoning(document, id: "reasoning-1")
        #expect(reasoning.text == "Thinking")
        #expect(reasoning.style == .summary)

        let unknown = try requireUnknown(document, id: "unknown-1")
        #expect(unknown.rawKind == "futureAppServerItem")
        #expect(unknown.rawStatus == "needsExternalDecision")
        #expect(unknown.references == [
            .init(kind: "wirePayload", value: "payload-1", label: "Wire payload"),
        ])
    }

    @Test func plainTextIsDerivedFromDocumentAndMatchesLegacyText() throws {
        let timeline = ReviewTimeline()

        complete(
            timeline,
            id: "approval-1",
            kind: "approvalRequest",
            family: .approval,
            content: .approval(.init(title: "Run command?", detail: "swift test"))
        )
        complete(
            timeline,
            id: "cmd-1",
            kind: .commandExecution,
            family: .command,
            content: .command(.init(command: "swift test", output: "ok"))
        )
        complete(
            timeline,
            id: "context-1",
            kind: .contextCompaction,
            family: .contextCompaction,
            content: .contextCompaction(.init(title: "Compacting context"))
        )
        complete(
            timeline,
            id: "diagnostic-1",
            kind: "backendDiagnostic",
            family: .diagnostic,
            content: .diagnostic(.init(message: "Backend overloaded"))
        )
        complete(
            timeline,
            id: "file-1",
            kind: .fileChange,
            family: .fileChange,
            content: .fileChange(.init(title: "Sources/App.swift", output: "modified"))
        )
        complete(
            timeline,
            id: "message-1",
            kind: .agentMessage,
            family: .message,
            content: .message(.init(text: "Agent says hi"))
        )
        complete(
            timeline,
            id: "plan-1",
            kind: .plan,
            family: .plan,
            content: .plan(.init(markdown: "- [ ] Task"))
        )
        complete(
            timeline,
            id: "reasoning-1",
            kind: .reasoning,
            family: .reasoning,
            content: .reasoning(.init(text: "Thinking", style: .raw))
        )
        complete(
            timeline,
            id: "search-1",
            kind: .webSearch,
            family: .search,
            content: .search(.init(query: "ReviewTimeline", result: "2 results"))
        )
        complete(
            timeline,
            id: "tool-1",
            kind: .mcpToolCall,
            family: .tool,
            content: .toolCall(.init(namespace: "mcp", server: "codex_review", tool: "review_start"))
        )
        complete(
            timeline,
            id: "unknown-1",
            kind: "futureItem",
            family: .unknown,
            content: .unknown(.init(title: "Future item", detail: "raw detail"))
        )

        let renderer = ReviewTimelineDocumentRenderer()
        let document = renderer.document(from: timeline)

        #expect(renderer.plainText(from: timeline) == document.plainText)
        #expect(document.blocks.map(\.primaryText) == [
            "Run command?",
            "swift test",
            "Compacting context",
            "Backend overloaded",
            "Sources/App.swift",
            "Agent says hi",
            "- [ ] Task",
            "Thinking",
            "ReviewTimeline",
            "mcp.codex_review.review_start",
            "Future item",
        ])
        #expect(renderer.plainText(from: timeline) == """
        Run command?
        swift test

        $ swift test
        ok

        Compacting context

        Backend overloaded

        Sources/App.swift
        modified

        Agent says hi

        - [ ] Task

        Thinking

        ReviewTimeline
        2 results

        mcp.codex_review.review_start

        Future item
        raw detail
        """)
    }
}

@MainActor
private func start(
    _ timeline: ReviewTimeline,
    id: ReviewTimelineItem.ID,
    kind: ReviewItemKind,
    family: ReviewItemFamily,
    phase: ReviewItemPhase = .running,
    content: ReviewTimelineItem.Content,
    durationMs: Int? = nil
) {
    timeline.apply(.itemStarted(.init(
        id: id,
        kind: kind,
        family: family,
        phase: phase,
        content: content,
        durationMs: durationMs
    )))
}

@MainActor
private func complete(
    _ timeline: ReviewTimeline,
    id: ReviewTimelineItem.ID,
    kind: ReviewItemKind,
    family: ReviewItemFamily,
    phase: ReviewItemPhase = .completed,
    content: ReviewTimelineItem.Content,
    durationMs: Int? = nil
) {
    timeline.apply(.itemCompleted(.init(
        id: id,
        kind: kind,
        family: family,
        phase: phase,
        content: content,
        durationMs: durationMs
    )))
}

private func itemID(_ rawValue: String) -> ReviewTimelineItem.ID {
    .init(rawValue: rawValue)
}

private func blockID(_ rawValue: String) -> ReviewTimelineDocument.Block.ID {
    .init(rawValue: rawValue)
}

private func requireBlock(
    _ document: ReviewTimelineDocument,
    id: ReviewTimelineItem.ID
) throws -> ReviewTimelineDocument.Block {
    try #require(document.blocks.first { $0.sourceItemID == id })
}

private func requireApproval(
    _ document: ReviewTimelineDocument,
    id: ReviewTimelineItem.ID
) throws -> ReviewTimelineDocument.Approval {
    guard case .approval(let approval) = try requireBlock(document, id: id).content else {
        Issue.record("expected approval content")
        throw TestFailure()
    }
    return approval
}

private func requireCommand(
    _ block: ReviewTimelineDocument.Block
) throws -> ReviewTimelineDocument.Command {
    guard case .command(let command) = block.content else {
        Issue.record("expected command content")
        throw TestFailure()
    }
    return command
}

private func requireToolCall(
    _ document: ReviewTimelineDocument,
    id: ReviewTimelineItem.ID
) throws -> ReviewTimelineDocument.ToolCall {
    guard case .toolCall(let toolCall) = try requireBlock(document, id: id).content else {
        Issue.record("expected tool call content")
        throw TestFailure()
    }
    return toolCall
}

private func requireFileChange(
    _ document: ReviewTimelineDocument,
    id: ReviewTimelineItem.ID
) throws -> ReviewTimelineDocument.FileChange {
    guard case .fileChange(let fileChange) = try requireBlock(document, id: id).content else {
        Issue.record("expected file change content")
        throw TestFailure()
    }
    return fileChange
}

private func requireSearch(
    _ document: ReviewTimelineDocument,
    id: ReviewTimelineItem.ID
) throws -> ReviewTimelineDocument.Search {
    guard case .search(let search) = try requireBlock(document, id: id).content else {
        Issue.record("expected search content")
        throw TestFailure()
    }
    return search
}

private func requireDiagnostic(
    _ document: ReviewTimelineDocument,
    id: ReviewTimelineItem.ID
) throws -> ReviewTimelineDocument.Diagnostic {
    guard case .diagnostic(let diagnostic) = try requireBlock(document, id: id).content else {
        Issue.record("expected diagnostic content")
        throw TestFailure()
    }
    return diagnostic
}

private func requireContextCompaction(
    _ document: ReviewTimelineDocument,
    id: ReviewTimelineItem.ID
) throws -> ReviewTimelineDocument.ContextCompaction {
    guard case .contextCompaction(let contextCompaction) = try requireBlock(document, id: id).content else {
        Issue.record("expected context compaction content")
        throw TestFailure()
    }
    return contextCompaction
}

private func requireMessage(
    _ document: ReviewTimelineDocument,
    id: ReviewTimelineItem.ID
) throws -> ReviewTimelineDocument.Message {
    guard case .message(let message) = try requireBlock(document, id: id).content else {
        Issue.record("expected message content")
        throw TestFailure()
    }
    return message
}

private func requirePlan(
    _ document: ReviewTimelineDocument,
    id: ReviewTimelineItem.ID
) throws -> ReviewTimelineDocument.Plan {
    guard case .plan(let plan) = try requireBlock(document, id: id).content else {
        Issue.record("expected plan content")
        throw TestFailure()
    }
    return plan
}

private func requireReasoning(
    _ document: ReviewTimelineDocument,
    id: ReviewTimelineItem.ID
) throws -> ReviewTimelineDocument.Reasoning {
    guard case .reasoning(let reasoning) = try requireBlock(document, id: id).content else {
        Issue.record("expected reasoning content")
        throw TestFailure()
    }
    return reasoning
}

private func requireUnknown(
    _ document: ReviewTimelineDocument,
    id: ReviewTimelineItem.ID
) throws -> ReviewTimelineDocument.Unknown {
    guard case .unknown(let unknown) = try requireBlock(document, id: id).content else {
        Issue.record("expected unknown content")
        throw TestFailure()
    }
    return unknown
}

private struct TestFailure: Error {}
