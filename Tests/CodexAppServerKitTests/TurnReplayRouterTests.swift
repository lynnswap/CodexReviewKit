import Testing

@testable import CodexAppServerKit
import CodexAppServerKitTesting

@Suite("Turn replay router integration")
struct TurnReplayRouterTests {
    @Test func duplicateExplicitThreadTerminalsPublishOnce() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        await transport.waitForNotificationStreamCount(1)
        let completed = TurnCompletedParams(
            threadID: "thread-1",
            turn: .init(id: "turn-external", status: "completed")
        )
        let events = harness.router.events(for: "thread-1")
        var eventIterator = events.makeAsyncIterator()

        try await transport.emitServerNotification(method: "turn/completed", params: completed)
        try await transport.emitServerNotification(method: "turn/completed", params: completed)
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadClosedParams(threadID: "thread-1")
        )

        var terminals: [CodexTurnOutcome] = []
        while let event = try await eventIterator.next() {
            if case .terminal(let outcome) = event {
                terminals.append(outcome)
            }
        }
        await harness.close()
        #expect(terminals == [.completed(.init(turnID: "turn-external"))])
    }

    @Test func conflictingExplicitThreadTerminalClosesConnectionWithContractViolation() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        await transport.waitForNotificationStreamCount(1)
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-1",
                turn: .init(id: "turn-external", status: "completed")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-1",
                turn: .init(id: "turn-external", status: "interrupted")
            )
        )

        let termination = await harness.supervisor.waitForTerminationForTesting()
        if case .transportFailure(.contractViolation(let message)) = termination {
            #expect(message.contains("turn-external"))
        } else {
            Issue.record("Expected a typed thread-terminal contract violation, got \(termination).")
        }
        await harness.close()
    }

    @Test func resumedReviewCapturesTerminalBeforeResumeResponse() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let gate = CodexAppServerTestGate()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        await runtime.transport.holdNext(method: "thread/resume", gate: gate)
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )
        let resume = Task {
            try await runtime.server.resumeReview(identity)
        }

        await runtime.transport.waitForRequest(method: "thread/resume")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-review",
                turn: .init(id: "turn-review", status: "completed")
            )
        )
        await gate.open()

        let review = try await resume.value
        let outcome = try await review.collect(timeout: .seconds(1))
        #expect(outcome == .completed(.init(turnID: "turn-review")))
        await runtime.close()
    }

    @Test func terminalCommitsRouterStateBeforeReplayPublication() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        await transport.waitForNotificationStreamCount(1)
        let publicationGate = CodexAppServerTestGate()
        await harness.router.setTerminalReplayPublicationPauseForTesting {
            await publicationGate.waitIgnoringCancellation()
        }
        await harness.router.seedTurns(
            [
                .init(
                    id: "turn-terminal-order",
                    state: .inProgress,
                    items: [
                        .init(
                            id: "message-terminal-order",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-terminal-order",
                                role: .assistant,
                                text: "Pending"
                            ))
                        ),
                    ]
                ),
            ],
            threadID: "thread-terminal-order"
        )

        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-terminal-order",
                turn: .init(id: "turn-terminal-order", status: "completed")
            )
        )
        await publicationGate.waitUntilBlocked()

        #expect(await harness.router.turnAssociationForTesting("turn-terminal-order") == nil)
        #expect(await harness.router.itemSnapshotForTesting(
            turnID: "turn-terminal-order",
            itemID: "message-terminal-order"
        ) == nil)

        await publicationGate.open()
        await harness.close()
    }

    @Test func conflictingNotificationTurnAssociationTerminatesConnection() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        await transport.waitForNotificationStreamCount(1)
        await harness.router.seedTurn("turn-associated", threadID: "thread-owner")

        try await transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-other",
                turnID: "turn-associated"
            )
        )

        let termination = await harness.supervisor.waitForTerminationForTesting()
        if case .transportFailure(.contractViolation(let message)) = termination {
            #expect(message.contains("turn-associated"))
            #expect(message.contains("thread-owner"))
            #expect(message.contains("thread-other"))
        } else {
            Issue.record("Expected a typed turn-association contract violation, got \(termination).")
        }
        await harness.close()
    }
}

private struct TurnCompletedParams: Encodable, Sendable {
    var threadID: String
    var turn: TurnPayload

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
    }
}

private struct TurnPayload: Encodable, Sendable {
    var id: String
    var status: String
    var items: [TurnItem] = []
}

private struct TurnStartedParams: Encodable, Sendable {
    var threadID: String
    var turn: Turn

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
    }

    init(threadID: String, turnID: String) {
        self.threadID = threadID
        self.turn = .init(id: turnID)
    }

    struct Turn: Encodable, Sendable {
        var id: String
        var status = "inProgress"
        var items: [String] = []
    }
}

private struct ThreadClosedParams: Encodable, Sendable {
    var threadID: String

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

private struct TurnItem: Encodable, Sendable {}
