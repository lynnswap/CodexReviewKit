import Foundation
import Testing
import CodexDataKit
@testable import CodexReviewKit
@testable import CodexReviewMCPServer

@Suite("Review MCP log projection")
struct ReviewMCPLogProjectionTests {
    @Test func unavailableProjectionDoesNotRebuildLogFromRunLifecycle() throws {
        let core = ReviewRunCore.running(
            attempt: try makeAttempt(attemptID: "attempt-1", turnID: "turn-1"),
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        let projection = ReviewMCPLogProjection.unavailable(result: .init(
            runID: try makeRunID("run-1"),
            core: core,
            presentation: .init(core: core, executionPhase: .running(attemptGeneration: 0))
        ))

        #expect(projection.orderedEntryIDs == [])
        #expect(projection.activeEntryIDs == [])
        #expect(projection.activeEntryCount == 0)
        #expect(projection.latestEntryID == nil)
        #expect(projection.items.isEmpty)
        #expect(projection.finalResult == nil)
    }

    @Test func unavailableTerminalProjectionDoesNotMirrorLifecycleAsLog() throws {
        let core = ReviewRunCore.succeeded(
            attempt: try makeAttempt(attemptID: "attempt-2", turnID: "turn-2"),
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_234)
        )
        let projection = ReviewMCPLogProjection.unavailable(result: .init(
            runID: try makeRunID("run-2"),
            core: core,
            presentation: .init(core: core, executionPhase: nil)
        ))

        #expect(projection.activeEntryIDs == [])
        #expect(projection.activeEntryCount == 0)
        #expect(projection.finalLifecycleMessage == nil)
        #expect(projection.finalResult == nil)
        #expect(projection.items.isEmpty)
    }

    @Test func turnItemsProjectAsOrderedLogItems() throws {
        let core = ReviewRunCore.running(
            attempt: try makeAttempt(attemptID: "attempt-1", turnID: "turn-1"),
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        let projection = ReviewMCPLogProjection(
            result: .init(
                runID: try makeRunID("run-1"),
                core: core,
                presentation: .init(core: core, executionPhase: .running(attemptGeneration: 0))
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
            ],
            reviewOutputText: nil
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
        let core = ReviewRunCore.succeeded(
            attempt: try makeAttempt(attemptID: "attempt-1", turnID: "turn-1"),
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_234)
        )
        let projection = ReviewMCPLogProjection(
            result: .init(
                runID: try makeRunID("run-1"),
                core: core,
                presentation: .init(core: core, executionPhase: nil)
            ),
            turnID: "turn-1",
            threadItems: [
                .init(
                    id: "assistant-1",
                    kind: .agentMessage,
                    content: .message(.init(
                        id: "assistant-1",
                        role: .assistant,
                        text: "Assistant fallback must not win."
                    ))
                ),
            ],
            reviewOutputText: "CodexChat final"
        )

        #expect(projection.finalLifecycleMessage == "Review completed.")
        #expect(projection.finalResult == "CodexChat final")
    }
}

private func makeAttempt(
    attemptID: String,
    turnID: String,
    threadID: String = "thread-1"
) throws -> ReviewAttempt {
    try ReviewAttempt(
        validatingAttemptID: attemptID,
        sourceThreadID: threadID,
        activeTurnThreadID: threadID,
        turnID: turnID
    )
}

private func makeRunID(_ rawValue: String) throws -> ReviewRunID {
    try ReviewRunID(validating: rawValue)
}
