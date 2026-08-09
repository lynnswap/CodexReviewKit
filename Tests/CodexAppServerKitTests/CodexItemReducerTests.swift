import Foundation
import Testing

import CodexAppServerKitTesting
@testable import CodexAppServerKit

@Suite("CodexItemReducer")
struct CodexItemReducerTests {
    @Test func completionPreservesSemanticMetadataFromStartedItem() throws {
        var reducer = CodexItemReducer()
        let started = CodexThreadItem(
            id: "message-1",
            kind: .agentMessage,
            content: .message(.init(id: "message-1", role: .assistant, text: "partial")),
            origin: .reviewRolloutAssistant,
            semanticRelation: .companionOf(.exitedReviewMode)
        )

        _ = try reducer.apply(.started(started), turnID: "turn-1")
        let completed = try reducer.apply(
            .completed(.init(
                id: "message-1",
                kind: .agentMessage,
                content: .message(.init(id: "message-1", role: .assistant, text: "done"))
            )),
            turnID: "turn-1"
        )

        #expect(completed.origin == .reviewRolloutAssistant)
        #expect(completed.semanticRelation == .companionOf(.exitedReviewMode))
    }

    @Test func internalCurrentItemProjectionDoesNotChangeDeltaEquality() {
        let item = CodexThreadItem(
            id: "message-1",
            kind: .agentMessage,
            content: .message(.init(id: "message-1", role: .assistant, text: "Hello"))
        )
        #expect(CodexMessageDelta(
            text: "Hello",
            itemID: "message-1",
            phase: .finalAnswer
        ) == CodexMessageDelta(
            text: "Hello",
            itemID: "message-1",
            phase: .finalAnswer,
            currentItem: item
        ))

        let publicPart = CodexReasoningPart(itemID: "reasoning-1", kind: .summary, index: 0)
        let reducedPart = CodexReasoningPart(
            itemID: "reasoning-1",
            kind: .summary,
            index: 0,
            currentItem: .init(
                id: "reasoning-1",
                kind: .reasoning,
                content: .reasoning(.init(summary: "Checking"))
            )
        )
        #expect(publicPart == reducedPart)
        #expect(CodexReasoningDelta(part: publicPart, delta: "Checking")
            == CodexReasoningDelta(
                part: reducedPart,
                delta: "Checking",
                currentItem: item
            ))
    }

    @Test func turnDiagnosticsReduceToTypedNonterminalEventsWithoutCreatingItems() throws {
        var reducer = CodexItemReducer()
        let diagnostic = CodexTurnDiagnostic(
            error: .init(message: "retrying", info: .serverOverloaded),
            willRetry: true
        )

        #expect(try reducer.reduce(
            .turnDiagnostic(diagnostic),
            turnID: "turn-1"
        ) == .diagnostic(diagnostic))
        #expect(reducer.item(turnID: "turn-1", itemID: "diagnostic") == nil)
    }

    @Test func commandDeltasAppendAndCompletionPreservesStartedMetadata() throws {
        var reducer = CodexItemReducer()
        let startedAt = Date(timeIntervalSince1970: 100)
        let completedAt = Date(timeIntervalSince1970: 101)
        let action = CodexCommand.Action(
            kind: .read,
            command: "cat Sources/File.swift",
            name: "File.swift",
            path: "Sources/File.swift"
        )
        let started = CodexThreadItem(
            id: "command-1",
            kind: .commandExecution,
            content: .command(.init(
                command: "swift test",
                cwd: "/workspace",
                status: .inProgress,
                startedAt: startedAt,
                processID: "process-1",
                source: .agent,
                commandActions: [action]
            )),
            rawPayload: Data("started".utf8)
        )

        _ = try reducer.apply(.started(started), turnID: "turn-1")
        _ = try reducer.apply(
            .commandOutputDelta(itemID: "command-1", delta: "first\n"),
            turnID: "turn-1"
        )
        _ = try reducer.apply(
            .commandOutputDelta(itemID: "command-1", delta: "second\n"),
            turnID: "turn-1"
        )
        let completed = try reducer.apply(
            .completed(.init(
                id: "command-1",
                kind: .commandExecution,
                content: .command(.init(
                    command: "",
                    status: .completed,
                    completedAt: completedAt
                ))
            )),
            turnID: "turn-1"
        )

        guard case .command(let command) = completed.content else {
            Issue.record("Expected command item.")
            return
        }
        #expect(command.command == "swift test")
        #expect(command.cwd == "/workspace")
        #expect(command.output == "first\nsecond\n")
        #expect(command.status == .completed)
        #expect(command.startedAt == startedAt)
        #expect(command.completedAt == completedAt)
        #expect(command.processID == "process-1")
        #expect(command.source == .agent)
        #expect(command.commandActions == [action])
        #expect(completed.rawPayload == Data("started".utf8))
    }

    @Test func filePatchUsesLatestSnapshotAndPreservesFileMetadata() throws {
        var reducer = CodexItemReducer()
        _ = try reducer.apply(
            .started(.init(
                id: "file-1",
                kind: .fileChange,
                content: .fileChange(.init(
                    path: "Sources/File.swift",
                    output: "initial",
                    status: .inProgress
                ))
            )),
            turnID: "turn-1"
        )
        _ = try reducer.apply(
            .filePatchSnapshot(itemID: "file-1", output: "first snapshot"),
            turnID: "turn-1"
        )
        let latest = try reducer.apply(
            .filePatchSnapshot(itemID: "file-1", output: "replacement snapshot"),
            turnID: "turn-1"
        )

        guard case .fileChange(let fileChange) = latest.content else {
            Issue.record("Expected file change item.")
            return
        }
        #expect(fileChange.path == "Sources/File.swift")
        #expect(fileChange.output == "replacement snapshot")
        #expect(fileChange.status == .inProgress)
    }

    @Test func agentPlanReasoningAndMCPDeltasUpdateTheirBaseItems() throws {
        var reducer = CodexItemReducer()
        _ = try reducer.apply(
            .started(.init(
                id: "message-1",
                kind: .agentMessage,
                content: .message(.init(
                    id: "message-1",
                    role: .assistant,
                    phase: .finalAnswer,
                    text: "Hello"
                ))
            )),
            turnID: "turn-1"
        )
        let message = try reducer.apply(
            .agentMessageDelta(itemID: "message-1", delta: " world"),
            turnID: "turn-1"
        )
        #expect(message.message?.text == "Hello world")
        #expect(message.message?.phase == .finalAnswer)

        _ = try reducer.apply(
            .started(.init(id: "plan-1", kind: .plan, content: .plan("Step"))),
            turnID: "turn-1"
        )
        let plan = try reducer.apply(
            .planDelta(itemID: "plan-1", delta: " one"),
            turnID: "turn-1"
        )
        #expect(plan.content == .plan("Step one"))

        _ = try reducer.apply(
            .started(.init(
                id: "reasoning-1",
                kind: .reasoning,
                content: .reasoning(.empty)
            )),
            turnID: "turn-1"
        )
        _ = try reducer.apply(
            .reasoningSummaryPartAdded(itemID: "reasoning-1", index: 0),
            turnID: "turn-1"
        )
        _ = try reducer.apply(
            .reasoningSummaryDelta(itemID: "reasoning-1", index: 0, delta: "Summary"),
            turnID: "turn-1"
        )
        let reasoning = try reducer.apply(
            .reasoningTextDelta(itemID: "reasoning-1", index: 0, delta: "Trace"),
            turnID: "turn-1"
        )
        #expect(reasoning.content == .reasoning(.init(
            summary: ["Summary"],
            content: ["Trace"]
        )))

        _ = try reducer.apply(
            .started(.init(
                id: "mcp-1",
                kind: .mcpToolCall,
                content: .toolCall(.init(
                    server: "docs",
                    name: "search",
                    arguments: "CodexItemReducer",
                    status: .inProgress
                ))
            )),
            turnID: "turn-1"
        )
        let mcp = try reducer.apply(
            .mcpProgress(itemID: "mcp-1", message: "Reading"),
            turnID: "turn-1"
        )
        guard case .toolCall(let toolCall) = mcp.content else {
            Issue.record("Expected MCP tool call item.")
            return
        }
        #expect(toolCall.server == "docs")
        #expect(toolCall.name == "search")
        #expect(toolCall.arguments == "CodexItemReducer")
        #expect(toolCall.result == "Reading")
        #expect(toolCall.status == .inProgress)
    }

    @Test func missingBaseAndMissingIDAreContractErrors() throws {
        var reducer = CodexItemReducer()
        do {
            _ = try reducer.apply(
                .commandOutputDelta(itemID: "command-1", delta: "output"),
                turnID: "turn-1"
            )
            Issue.record("Expected missing-base failure.")
        } catch let error as CodexItemReducer.ContractError {
            #expect(error == .missingBaseItem(turnID: "turn-1", itemID: "command-1"))
        }

        do {
            _ = try reducer.apply(
                .started(.init(
                    id: "",
                    kind: .agentMessage,
                    content: .message(.init(id: "", role: .assistant, text: ""))
                )),
                turnID: "turn-1"
            )
            Issue.record("Expected missing-ID failure.")
        } catch let error as CodexItemReducer.ContractError {
            #expect(error == .missingItemID)
        }
    }

    @Test func staleSnapshotSeedDoesNotOverwriteLiveReduction() throws {
        var reducer = CodexItemReducer()
        let liveItem = CodexThreadItem(
            id: "message-1",
            kind: .agentMessage,
            content: .message(.init(id: "message-1", role: .assistant, text: "live"))
        )
        _ = try reducer.apply(.started(liveItem), turnID: "turn-1")
        _ = try reducer.apply(
            .agentMessageDelta(itemID: "message-1", delta: " update"),
            turnID: "turn-1"
        )

        let missingSnapshotItem = CodexThreadItem(
            id: "command-1",
            kind: .commandExecution,
            content: .command(.init(command: "swift test", status: .inProgress))
        )
        reducer.seed([.init(
            id: "turn-1",
            state: .inProgress,
            items: [
                .init(
                    id: "message-1",
                    kind: .agentMessage,
                    content: .message(.init(
                        id: "message-1",
                        role: .assistant,
                        text: "stale"
                    ))
                ),
                missingSnapshotItem,
            ]
        )])

        let updated = try reducer.apply(
            .agentMessageDelta(itemID: "message-1", delta: " retained"),
            turnID: "turn-1"
        )
        #expect(updated.message?.text == "live update retained")
        #expect(reducer.item(turnID: "turn-1", itemID: "command-1") == missingSnapshotItem)
    }

    @Test func reducerReleasesTurnAndConnectionState() throws {
        var reducer = CodexItemReducer()
        let item = CodexThreadItem(
            id: "message-1",
            kind: .agentMessage,
            content: .message(.init(id: "message-1", role: .assistant, text: ""))
        )
        _ = try reducer.apply(.started(item), turnID: "turn-1")
        _ = try reducer.apply(.started(item), turnID: "turn-2")

        reducer.release(turnID: "turn-1")
        #expect(reducer.item(turnID: "turn-1", itemID: "message-1") == nil)
        #expect(reducer.item(turnID: "turn-2", itemID: "message-1") != nil)

        reducer.releaseAll()
        #expect(reducer.item(turnID: "turn-2", itemID: "message-1") == nil)
    }

    @Test func routerDoesNotMutateItemForThreadStatusAndReleasesOnTerminalAndStop() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)

        let firstState = await harness.turnReplayStore.restoreGeneration(
            turnID: "turn-1",
            initialSnapshot: .init(id: "turn-1", state: .inProgress),
            connectionLease: harness.lease
        )
        let firstTurnEvents = try await harness.turnReplayStore.events(
            for: "turn-1",
            state: firstState
        )
        var firstTurnIterator = firstTurnEvents.makeAsyncIterator()
        guard case .snapshot? = try await firstTurnIterator.next() else {
            Issue.record("Expected the initial snapshot for turn-1.")
            return
        }
        try await transport.emitServerNotification(
            method: "item/started",
            params: ItemLifecycleParams(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    id: "command-1",
                    type: "commandExecution",
                    command: "swift test",
                    aggregatedOutput: "",
                    status: "inProgress"
                ),
                startedAtMS: 1_000
            )
        )
        guard case .itemStarted? = try await firstTurnIterator.next() else {
            Issue.record("Expected the item/started event for turn-1.")
            return
        }
        #expect(await router.itemSnapshotForTesting(
            turnID: "turn-1",
            itemID: "command-1"
        ) != nil)
        let beforeStatus = await router.itemSnapshotForTesting(
            turnID: "turn-1",
            itemID: "command-1"
        )

        let statusEvents = router.events(for: CodexThreadID(rawValue: "thread-1"))
        var statusIterator = statusEvents.makeAsyncIterator()
        try await transport.emitServerNotification(
            method: "thread/status/changed",
            params: ThreadStatusParams(threadID: "thread-1", status: .init(type: "idle"))
        )
        var receivedStatus = false
        while let event = try await statusIterator.next() {
            if case .statusChanged = event {
                receivedStatus = true
                break
            }
        }
        guard receivedStatus else {
            Issue.record("Expected the thread/status/changed event.")
            return
        }
        #expect(await router.itemSnapshotForTesting(
            turnID: "turn-1",
            itemID: "command-1"
        ) == beforeStatus)

        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnTerminalParams(turn: .init(id: "turn-1", status: "completed"))
        )
        var receivedTerminal = false
        while let event = try await firstTurnIterator.next() {
            if case .terminal = event {
                receivedTerminal = true
                break
            }
        }
        guard receivedTerminal else {
            Issue.record("Expected the terminal event for turn-1.")
            return
        }
        #expect(try await firstTurnIterator.next() == nil)
        #expect(await router.itemSnapshotForTesting(
            turnID: "turn-1",
            itemID: "command-1"
        ) == nil)

        let secondState = await harness.turnReplayStore.restoreGeneration(
            turnID: "turn-2",
            initialSnapshot: .init(id: "turn-2", state: .inProgress),
            connectionLease: harness.lease
        )
        let secondTurnEvents = try await harness.turnReplayStore.events(
            for: "turn-2",
            state: secondState
        )
        var secondTurnIterator = secondTurnEvents.makeAsyncIterator()
        guard case .snapshot? = try await secondTurnIterator.next() else {
            Issue.record("Expected the initial snapshot for turn-2.")
            return
        }
        try await transport.emitServerNotification(
            method: "item/started",
            params: ItemLifecycleParams(
                threadID: "thread-1",
                turnID: "turn-2",
                item: .init(id: "message-2", type: "agentMessage", text: ""),
                startedAtMS: 2_000
            )
        )
        guard case .itemStarted? = try await secondTurnIterator.next() else {
            Issue.record("Expected the item/started event for turn-2.")
            return
        }
        #expect(await router.itemSnapshotForTesting(
            turnID: "turn-2",
            itemID: "message-2"
        ) != nil)
        await harness.close()
        #expect(await router.itemSnapshotForTesting(turnID: "turn-2", itemID: "message-2") == nil)
    }
}

private struct ItemLifecycleParams: Encodable, Sendable {
    struct Item: Encodable, Sendable {
        var id: String
        var type: String
        var text: String?
        var command: String?
        var aggregatedOutput: String?
        var status: String?
        var cwd: String
        var commandActions: [String]

        init(
            id: String,
            type: String,
            text: String? = nil,
            command: String? = nil,
            aggregatedOutput: String? = nil,
            status: String? = nil
        ) {
            self.id = id
            self.type = type
            self.text = text
            self.command = command
            self.aggregatedOutput = aggregatedOutput
            self.status = status
            self.cwd = "/workspace"
            self.commandActions = []
        }
    }

    var threadID: String
    var turnID: String
    var item: Item
    var startedAtMS: Int64

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case item
        case startedAtMS = "startedAtMs"
    }
}

private struct ThreadStatusParams: Encodable, Sendable {
    struct Status: Encodable, Sendable {
        var type: String
    }

    var threadID: String
    var status: Status

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case status
    }
}

private struct TurnTerminalParams: Encodable, Sendable {
    var threadID: String = "thread-1"
    var turn: AppServerAPI.Turn.Payload

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
    }

    init(turn: AppServerAPI.Turn.Payload) {
        var turn = turn
        turn.items = turn.items ?? []
        self.turn = turn
    }
}
