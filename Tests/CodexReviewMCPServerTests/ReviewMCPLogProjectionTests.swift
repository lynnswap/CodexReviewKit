import Foundation
import Testing
import CodexKit
@testable import CodexReviewKit
@testable import CodexReviewMCPServer

@Suite("Review MCP log projection")
struct ReviewMCPLogProjectionTests {
    @Test func unavailableProjectionDoesNotRebuildLogFromRunOutput() throws {
        let projection = ReviewMCPLogProjection.unavailable(result: .init(
            runID: "run-1",
            core: .init(
                lifecycle: .init(status: .running),
                lifecycleMessage: "Review started."
            ),
            cancellable: true
        ))

        #expect(projection.orderedEntryIDs == [])
        #expect(projection.activeEntryIDs == [])
        #expect(projection.activeEntryCount == 0)
        #expect(projection.latestEntryID == nil)
        #expect(projection.items.isEmpty)
        #expect(projection.finalResult == nil)
    }

    @Test func unavailableTerminalProjectionKeepsSummaryButNoFinalResult() throws {
        let projection = ReviewMCPLogProjection.unavailable(result: .init(
            runID: "run-2",
            core: .init(
                lifecycle: .init(status: .succeeded, endedAt: Date(timeIntervalSince1970: 1_234)),
                lifecycleMessage: "Done."
            ),
            cancellable: false
        ))

        #expect(projection.activeEntryIDs == [])
        #expect(projection.activeEntryCount == 0)
        #expect(projection.finalLifecycleMessage == "Done.")
        #expect(projection.finalResult == nil)
        #expect(projection.items.isEmpty)
    }

    @Test func turnItemsProjectAsOrderedLogItems() throws {
        let projection = ReviewMCPLogProjection(
            result: .init(
                runID: "run-1",
                core: .init(
                    run: .init(threadID: "thread-1", turnID: "turn-1"),
                    lifecycle: .init(status: .running),
                    lifecycleMessage: "Running."
                ),
                cancellable: true
            ),
            turnID: "turn-1",
            threadItems: [
                .init(
                    id: "assistant-1",
                    kind: .agentMessage,
                    content: .message(.init(id: "assistant-1", role: .assistant, text: "Inspecting files."))
                ),
                .init(
                    id: "reasoning-1",
                    kind: .reasoning,
                    content: .reasoning(.init(summary: "Need focused tests."))
                ),
                .init(
                    id: "command-1",
                    kind: .commandExecution,
                    content: .command(.init(command: "swift test", output: "passed"))
                ),
            ]
        )

        #expect(projection.orderedEntryIDs == [
            "turn-1:assistant-1",
            "turn-1:reasoning-1",
            "turn-1:command-1",
        ])
        #expect(projection.activeEntryIDs == projection.orderedEntryIDs)
        #expect(projection.activeEntryCount == 3)
        #expect(projection.latestEntryID == "turn-1:command-1")
        #expect(projection.items.map { $0.kind } == ["agentMessage", "reasoning", "commandExecution"])
        #expect(projection.items.map { $0.content.type } == ["message", "reasoning", "command"])
    }

    @Test func terminalTurnItemsProvideFinalResultFromCodexChatOnly() throws {
        let projection = ReviewMCPLogProjection(
            result: .init(
                runID: "run-1",
                core: .init(
                    run: .init(threadID: "thread-1", turnID: "turn-1"),
                    lifecycle: .init(status: .succeeded, endedAt: Date(timeIntervalSince1970: 1_234)),
                    lifecycleMessage: "Done."
                ),
                cancellable: false
            ),
            turnID: "turn-1",
            threadItems: [
                .init(
                    id: "assistant-1",
                    kind: .agentMessage,
                    content: .message(.init(id: "assistant-1", role: .assistant, text: "CodexChat final"))
                ),
            ]
        )

        #expect(projection.finalLifecycleMessage == "Done.")
        #expect(projection.finalResult == "CodexChat final")
    }
}
