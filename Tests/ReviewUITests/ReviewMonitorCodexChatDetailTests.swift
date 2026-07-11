import CodexAppServerKit
import CodexDataKit
import CodexAppServerKitTesting
import Foundation
import Testing
@_spi(Testing) @testable import CodexReviewKit
@testable import ReviewChatLogUI
@testable import ReviewUI

@Suite("ReviewMonitor selected Codex chat detail", .serialized)
@MainActor
struct ReviewMonitorCodexChatDetailTests {
    @Test func codexChatLogProjectionMapsEveryLegalTurnState() throws {
        let failedError = CodexTurnError(
            message: "Turn failed",
            info: .sandboxError,
            additionalDetails: "The command was denied."
        )
        let unknownError = CodexTurnError(message: "Future status error")
        let cases:
            [(
                name: String,
                state: CodexTurnSnapshot.State,
                status: CodexTurnStatus,
                error: CodexTurnError?
            )] = [
                ("in-progress", .inProgress, .inProgress, nil),
                ("completed", .completed, .completed, nil),
                ("interrupted", .interrupted, .interrupted, nil),
                ("failed", .failed(failedError), .failed, failedError),
                (
                    "future",
                    .unknown(rawValue: "future", error: unknownError),
                    .unknown(rawValue: "future"),
                    unknownError
                ),
            ]

        for testCase in cases {
            var projection = ReviewMonitorCodexChatLogProjection()
            let turn = CodexTurnSnapshot(
                id: CodexTurnID(rawValue: "turn-\(testCase.name)"),
                state: testCase.state,
                items: [
                    .init(
                        id: "command-\(testCase.name)",
                        kind: .commandExecution,
                        content: .command(.init(command: "/bin/echo \(testCase.name)"))
                    )
                ]
            )

            let rendered = projection.render(
                from: turn,
                chatCreatedAt: nil,
                chatUpdatedAt: nil
            )
            let document = try #require(rendered)
            let command = try #require(document.blocks.first { $0.kind == .command })

            #expect(turn.status == testCase.status)
            #expect(turn.error == testCase.error)
            #expect(command.metadata?.status == testCase.status.rawValue)
        }
    }

    @Test func logSnapshotBarrierReplacesAfterInitialBaseline() async throws {
        let turnID = CodexTurnID(rawValue: "turn-1")
        let thread = CodexThreadSnapshot(
            id: "thread-1",
            turns: [
                .init(
                    id: turnID,
                    state: .inProgress,
                    items: [
                        .init(
                            id: "log-1",
                            kind: .enteredReviewMode,
                            content: .log("Review started")
                        )
                    ]
                )
            ]
        )
        var projection = ReviewMonitorCodexChatLogSourceProjection()

        let initialChange = projection.apply(.init(
            generation: 1,
            sequence: 0,
            payload: .snapshot(.init(thread: thread, phase: .running(turnID: turnID)), reason: .initial)
        ))
        guard case .replaceAll = initialChange else {
            Issue.record("Expected initial snapshot to replace the empty log")
            return
        }

        let refreshedChange = projection.apply(.init(
            generation: 1,
            sequence: 1,
            payload: .snapshot(.init(thread: thread, phase: .running(turnID: turnID)), reason: .refresh)
        ))
        guard case .replaceAll = refreshedChange else {
            Issue.record("Expected a snapshot barrier to replace the existing projection")
            return
        }
        #expect(refreshedChange?.allowsIncrementalRender == false)
    }

    @Test func selectedReviewChatRendersInitialSnapshot() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let modelContext = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueThreadResume(.init(id: "review-thread"))
        try await runtime.transport.enqueueThreadRead(
            .init(
                id: "review-thread",
                turns: [
                    .init(
                        id: "turn-1",
                        state: .inProgress,
                        items: [
                            .init(
                                id: "message-1",
                                kind: .agentMessage,
                                content: .message(
                                    .init(
                                        id: "message-1",
                                        role: .assistant,
                                        phase: .finalAnswer,
                                        text: "Review snapshot"
                                    ))
                            )
                        ]
                    )
                ]
            ))

        let store = CodexReviewStore.makePreviewStore()
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let transport = ReviewMonitorTransportViewController(
            uiState: uiState,
            modelContext: modelContext
        )
        transport.loadViewIfNeeded()

        uiState.selection = .chat(CodexThreadID(rawValue: "review-thread"))

        _ = try await awaitTransportRender(
            transport,
            expectedSelection: .chat("review-thread")
        ) { snapshot in
            snapshot.log == "Review snapshot"
        }
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 1)
    }

    @Test func switchingSelectedChatKeepsPreviousLogUntilNextBaselineRenders() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let modelContext = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueThreadResume(.init(id: "first-thread"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "first-thread",
            turns: [
                .init(
                    id: "turn-first",
                    state: .completed,
                    items: [
                        .init(
                            id: "message-first",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-first",
                                role: .assistant,
                                text: "First chat log"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let store = CodexReviewStore.makePreviewStore()
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let transport = ReviewMonitorTransportViewController(
            uiState: uiState,
            modelContext: modelContext
        )
        transport.loadViewIfNeeded()

        selectChat(id: "first-thread", in: uiState)
        _ = try await awaitTransportRender(
            transport,
            expectedSelection: .chat("first-thread")
        ) { snapshot in
            snapshot.log == "First chat log"
        }

        let secondReadGate = CodexAppServerTestGate()
        await runtime.transport.holdNext(method: "thread/read", gate: secondReadGate)
        try await runtime.transport.enqueueThreadResume(.init(id: "second-thread"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "second-thread",
            turns: [
                .init(
                    id: "turn-second",
                    state: .completed,
                    items: [
                        .init(
                            id: "message-second",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-second",
                                role: .assistant,
                                text: "Second chat log"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        selectChat(id: "second-thread", in: uiState)
        await runtime.transport.waitForRequest(method: "thread/read", count: 2)
        try await waitForCondition {
            transport.renderedStateForTesting.selection == .chat("second-thread")
        }
        #expect(transport.displayedLogForTesting == "First chat log")

        await secondReadGate.open()
        _ = try await awaitTransportRender(
            transport,
            expectedSelection: .chat("second-thread")
        ) { snapshot in
            snapshot.log == "Second chat log"
        }
    }

    @Test func switchingSelectedChatToEmptyCurrentValueClearsAfterBaseline() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let modelContext = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueThreadResume(.init(id: "first-thread"))
        try await runtime.transport.enqueueThreadRead(.init(
            id: "first-thread",
            turns: [
                .init(
                    id: "turn-first",
                    state: .completed,
                    items: [
                        .init(
                            id: "message-first",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-first",
                                role: .assistant,
                                text: "First chat log"
                            ))
                        ),
                    ]
                ),
            ]
        ))
        try await runtime.transport.enqueueThreadResume(.init(id: "empty-thread"))
        try await runtime.transport.enqueueThreadRead(.init(id: "empty-thread", turns: []))

        let store = CodexReviewStore.makePreviewStore()
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let transport = ReviewMonitorTransportViewController(
            uiState: uiState,
            modelContext: modelContext
        )
        transport.loadViewIfNeeded()

        selectChat(id: "first-thread", in: uiState)
        _ = try await awaitTransportRender(
            transport,
            expectedSelection: .chat("first-thread")
        ) { snapshot in
            snapshot.log == "First chat log"
        }

        selectChat(id: "empty-thread", in: uiState)
        _ = try await awaitTransportRender(
            transport,
            expectedSelection: .chat("empty-thread")
        ) { snapshot in
            snapshot.log == ""
        }
    }

    @Test func clearingSelectionClearsDisplayedChatLog() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let modelContext = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueThreadResume(.init(id: "review-thread"))
        try await runtime.transport.enqueueThreadRead(.init(id: "review-thread"))

        let store = CodexReviewStore.makePreviewStore()
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let transport = ReviewMonitorTransportViewController(
            uiState: uiState,
            modelContext: modelContext
        )
        transport.loadViewIfNeeded()

        selectChat(id: "review-thread", in: uiState)
        _ = try await awaitTransportRender(
            transport,
            expectedSelection: .chat("review-thread")
        ) { snapshot in
            snapshot.log == ""
        }

        uiState.selection = nil
        try await waitForCondition {
            transport.renderedStateForTesting.selection == nil
                && transport.renderedStateForTesting.snapshot.isShowingEmptyState
        }
    }

    @Test func selectedReviewChatConnectsWhenModelSourceInstallsLater() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let modelSource = ReviewMonitorCodexModelSource()
        try await runtime.transport.enqueueThreadResume(.init(id: "review-thread"))
        try await runtime.transport.enqueueThreadRead(
            .init(
                id: "review-thread",
                turns: [
                    .init(
                        id: "turn-1",
                        state: .inProgress,
                        items: [
                            .init(
                                id: "message-1",
                                kind: .agentMessage,
                                content: .message(
                                    .init(
                                        id: "message-1",
                                        role: .assistant,
                                        phase: .finalAnswer,
                                        text: "Late source"
                                    ))
                            )
                        ]
                    )
                ]
            ))

        let store = CodexReviewStore.makePreviewStore()
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let transport = ReviewMonitorTransportViewController(
            uiState: uiState,
            codexModelSource: modelSource
        )
        transport.loadViewIfNeeded()
        selectChat(id: "review-thread", in: uiState)

        try await waitForCondition {
            transport.renderedStateForTesting.selection == .chat("review-thread")
        }
        #expect(transport.displayedLogForTesting == "")

        modelSource.install(container: CodexModelContainer(appServer: runtime.server))

        _ = try await awaitTransportRender(
            transport,
            expectedSelection: .chat("review-thread")
        ) { snapshot in
            snapshot.log == "Late source"
        }
    }

    @Test func selectedReviewChatRendersCodexChatTurnAndLiveUpdates() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let modelContext = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueThreadResume(.init(id: "review-thread"))
        try await runtime.transport.enqueueThreadRead(
            .init(
                id: "review-thread",
                turns: [
                    .init(
                        id: "turn-1",
                        state: .inProgress,
                        items: [
                            .init(
                                id: "message-1",
                                kind: .agentMessage,
                                content: .message(
                                    .init(
                                        id: "message-1",
                                        role: .assistant,
                                        phase: .finalAnswer,
                                        text: "Chat snapshot"
                                    ))
                            )
                        ]
                    )
                ]
            ))

        let store = CodexReviewStore.makePreviewStore()
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let transport = ReviewMonitorTransportViewController(
            uiState: uiState,
            modelContext: modelContext
        )
        transport.loadViewIfNeeded()

        selectChat(id: "review-thread", in: uiState)

        let initialSnapshot = try await awaitTransportRender(
            transport,
            expectedSelection: .chat("review-thread")
        ) { snapshot in
            snapshot.log.contains("Chat snapshot")
        }
        #expect(initialSnapshot.log.contains("Legacy fallback") == false)

        try await runtime.transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "review-thread",
                turnID: "turn-1",
                item: .init(
                    id: "message-1",
                    type: "agentMessage",
                    text: "Chat stream update",
                    phase: "final_answer"
                )
            )
        )

        let updatedSnapshot = try await awaitTransportRender(
            transport,
            expectedSelection: .chat("review-thread")
        ) { snapshot in
            snapshot.log.contains("Chat stream update")
        }
        #expect(updatedSnapshot.log.contains("Chat snapshot") == false)
        #expect(updatedSnapshot.log.contains("Log fallback") == false)
    }

    @Test func codexChatTextAppendUsesAppendPath() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let modelContext = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueThreadResume(.init(id: "review-thread"))
        try await runtime.transport.enqueueThreadRead(
            .init(
                id: "review-thread",
                turns: [
                    .init(
                        id: "turn-1",
                        state: .inProgress,
                        items: [
                            .init(
                                id: "message-1",
                                kind: .agentMessage,
                                content: .message(
                                    .init(
                                        id: "message-1",
                                        role: .assistant,
                                        phase: .finalAnswer,
                                        text: "Initial"
                                    ))
                            )
                        ]
                    )
                ]
            ))

        let store = CodexReviewStore.makePreviewStore()
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let transport = ReviewMonitorTransportViewController(
            uiState: uiState,
            modelContext: modelContext
        )
        transport.loadViewIfNeeded()

        selectChat(id: "review-thread", in: uiState)

        _ = try await awaitTransportRender(
            transport,
            expectedSelection: .chat("review-thread")
        ) { snapshot in
            snapshot.log == "Initial"
        }
        transport.setLogReduceMotionForTesting(false)
        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting

        try await runtime.transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "review-thread",
                turnID: "turn-1",
                item: .init(
                    id: "message-1",
                    type: "agentMessage",
                    text: "Initial log",
                    phase: "final_answer"
                )
            )
        )

        let updatedSnapshot = try await awaitTransportRender(
            transport,
            expectedSelection: .chat("review-thread")
        ) { snapshot in
            snapshot.log == "Initial log"
        }
        #expect(updatedSnapshot.log == "Initial log")
        #expect(transport.logAppendCountForTesting == appendCount + 1)
        #expect(transport.logReloadCountForTesting == reloadCount)
    }

    @Test func codexChatLogProjectionSkipsUserPromptWhenReviewModeLogExists() async throws {
        var projection = ReviewMonitorCodexChatLogProjection()
        let turnID = CodexTurnID(rawValue: "turn-review")
        let turn = CodexTurnSnapshot(
            id: turnID,
            state: .inProgress,
            items: [
                .init(
                    id: "user-message",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "user-message",
                        role: .user,
                        text: "Review the current code changes."
                    ))
                ),
                .init(
                    id: "entered-review",
                    kind: .enteredReviewMode,
                    content: .log("Review the current code changes.")
                ),
            ]
        )
        let document = projection.render(
            from: turn,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )

        #expect(document?.text == "Review the current code changes.")
    }

    @Test func codexChatLogProjectionDeduplicatesReviewOutputAgentMessage() async throws {
        var projection = ReviewMonitorCodexChatLogProjection()
        let finalReview = """
        Review comment:

        - [P2] Handle complete agent messages without appending them as deltas.
        """
        let turn = CodexTurnSnapshot(
            id: CodexTurnID(rawValue: "turn-review"),
            state: .completed,
            items: [
                .init(
                    id: "review-output",
                    kind: .exitedReviewMode,
                    content: .log(finalReview)
                ),
                .init(
                    id: "review-output-agent",
                    kind: .agentMessage,
                    content: .message(.init(
                        id: "review-output-agent",
                        role: .assistant,
                        text: finalReview
                    ))
                ),
            ]
        )
        let document = projection.render(
            from: turn,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )

        #expect(document?.text == finalReview)
        #expect(document?.blocks.count == 1)
    }

    @Test func codexChatLogProjectionKeepsMatchingReviewOutputsFromDifferentTurns() async throws {
        var projection = ReviewMonitorCodexChatLogProjection()
        let finalReview = "No issues found."
        let snapshot = makeCodexThreadSnapshotForTesting(
            chatID: CodexThreadID(rawValue: "review-thread"),
            turns: [
                .init(
                    id: CodexTurnID(rawValue: "turn-first"),
                    state: .completed,
                    items: [
                        .init(
                            id: "review-output-first",
                            kind: .exitedReviewMode,
                            content: .log(finalReview)
                        ),
                        .init(
                            id: "review-output-agent-first",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "review-output-agent-first",
                                role: .assistant,
                                text: finalReview
                            ))
                        ),
                    ]
                ),
                .init(
                    id: CodexTurnID(rawValue: "turn-second"),
                    state: .completed,
                    items: [
                        .init(
                            id: "review-output-second",
                            kind: .exitedReviewMode,
                            content: .log(finalReview)
                        ),
                        .init(
                            id: "review-output-agent-second",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "review-output-agent-second",
                                role: .assistant,
                                text: finalReview
                            ))
                        ),
                    ]
                ),
            ]
        )

        let projectedDocument = projection.render(
            from: snapshot,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )
        let document = try #require(projectedDocument)

        #expect(document.blocks.count == 2)
        let documentText = document.text as NSString
        let renderedText = document.blocks.map { block in
            documentText.substring(with: block.range)
        }
        #expect(renderedText == [finalReview, finalReview])
    }

    @Test func codexChatLogProjectionDeduplicatesSameTurnReasoningMirrorItems() async throws {
        var projection = ReviewMonitorCodexChatLogProjection()
        let reasoningText = """
        **Summarizing files with git**

        I need to summarize the files.
        """
        let turn = CodexTurnSnapshot(
            id: CodexTurnID(rawValue: "turn-review"),
            state: .inProgress,
            items: [
                .init(
                    id: "event-reasoning",
                    kind: .reasoning,
                    content: .reasoning(.init(summary: reasoningText)),
                    rawPayload: rawPayload(type: "agent_reasoning")
                ),
                .init(
                    id: "response-reasoning",
                    kind: .reasoning,
                    content: .reasoning(.init(summary: reasoningText)),
                    rawPayload: rawPayload(type: "reasoning")
                ),
            ]
        )

        let projectedDocument = projection.render(
            from: turn,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )
        let document = try #require(projectedDocument)

        #expect(document.blocks.count == 1)
        #expect(document.text == "Summarizing files with git\n\nI need to summarize the files.")
    }

    @Test func codexChatLogProjectionKeepsAdjacentMatchingReasoningWithoutMirrorPayloads() async throws {
        var projection = ReviewMonitorCodexChatLogProjection()
        let reasoningText = "Checking diff"
        let turn = CodexTurnSnapshot(
            id: CodexTurnID(rawValue: "turn-review"),
            state: .inProgress,
            items: [
                .init(
                    id: "reasoning-a",
                    kind: .reasoning,
                    content: .reasoning(.init(summary: reasoningText)),
                    rawPayload: rawPayload(type: "reasoning")
                ),
                .init(
                    id: "reasoning-b",
                    kind: .reasoning,
                    content: .reasoning(.init(summary: reasoningText)),
                    rawPayload: rawPayload(type: "reasoning")
                ),
            ]
        )

        let projectedDocument = projection.render(
            from: turn,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )
        let document = try #require(projectedDocument)

        #expect(document.blocks.count == 2)
        #expect(document.text == "\(reasoningText)\n\n\(reasoningText)")
    }

    @Test func codexChatLogProjectionKeepsMatchingReasoningSeparatedByCommandInSameTurn() async throws {
        var projection = ReviewMonitorCodexChatLogProjection()
        let reasoningText = "Checking diff"
        let turn = CodexTurnSnapshot(
            id: CodexTurnID(rawValue: "turn-review"),
            state: .inProgress,
            items: [
                .init(
                    id: "reasoning-a",
                    kind: .reasoning,
                    content: .reasoning(.init(summary: reasoningText)),
                    rawPayload: rawPayload(type: "reasoning")
                ),
                .init(
                    id: "command-a",
                    kind: .commandExecution,
                    content: .command(.init(command: "/bin/zsh -lc"))
                ),
                .init(
                    id: "reasoning-b",
                    kind: .reasoning,
                    content: .reasoning(.init(summary: reasoningText)),
                    rawPayload: rawPayload(type: "reasoning")
                ),
            ]
        )

        let projectedDocument = projection.render(
            from: turn,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )
        let document = try #require(projectedDocument)

        #expect(document.blocks.count == 3)
        #expect(document.text.contains("\(reasoningText)\n\n$ /bin/zsh -lc\n\n\(reasoningText)"))
    }

    @Test func codexChatLogProjectionKeepsMatchingReasoningAcrossTurns() async throws {
        var projection = ReviewMonitorCodexChatLogProjection()
        let reasoningText = "Checking diff"
        let snapshot = makeCodexThreadSnapshotForTesting(
            chatID: CodexThreadID(rawValue: "review-thread"),
            turns: [
                .init(
                    id: CodexTurnID(rawValue: "turn-first"),
                    state: .completed,
                    items: [
                        .init(
                            id: "reasoning-first",
                            kind: .reasoning,
                            content: .reasoning(.init(summary: reasoningText))
                        ),
                    ]
                ),
                .init(
                    id: CodexTurnID(rawValue: "turn-second"),
                    state: .completed,
                    items: [
                        .init(
                            id: "reasoning-second",
                            kind: .reasoning,
                            content: .reasoning(.init(summary: reasoningText))
                        ),
                    ]
                ),
            ]
        )

        let projectedDocument = projection.render(
            from: snapshot,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )
        let document = try #require(projectedDocument)

        #expect(document.blocks.count == 2)
        #expect(document.text == "\(reasoningText)\n\n\(reasoningText)")
    }

    @Test func codexChatLogProjectionIgnoresLateReasoningMirrorBeforeCommand() async throws {
        var projection = ReviewMonitorCodexChatLogProjection()
        let turnID = CodexTurnID(rawValue: "turn-review")
        let reasoningText = """
        **Summarizing files with git**

        I need to summarize the files.
        """
        let command = CodexThreadItem(
            id: "command",
            kind: .commandExecution,
            content: .command(.init(
                command: "/bin/zsh -lc",
                status: .inProgress,
                startedAt: Date(timeIntervalSince1970: 4_000)
            ))
        )
        let initial = CodexTurnSnapshot(
            id: turnID,
            state: .inProgress,
            items: [
                .init(
                    id: "event-reasoning",
                    kind: .reasoning,
                    content: .reasoning(.init(summary: reasoningText)),
                    rawPayload: rawPayload(type: "agent_reasoning")
                ),
                command,
            ]
        )
        let mirrored = CodexTurnSnapshot(
            id: turnID,
            state: .inProgress,
            items: [
                .init(
                    id: "event-reasoning",
                    kind: .reasoning,
                    content: .reasoning(.init(summary: reasoningText)),
                    rawPayload: rawPayload(type: "agent_reasoning")
                ),
                .init(
                    id: "response-reasoning",
                    kind: .reasoning,
                    content: .reasoning(.init(summary: reasoningText)),
                    rawPayload: rawPayload(type: "reasoning")
                ),
                command,
            ]
        )

        let projectedInitialDocument = projection.render(
            from: initial,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )
        let initialDocument = try #require(projectedInitialDocument)
        let projectedMirroredDocument = projection.render(
            from: mirrored,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )
        let mirroredDocument = try #require(projectedMirroredDocument)

        #expect(mirroredDocument.text == initialDocument.text)
        #expect(mirroredDocument.blocks == initialDocument.blocks)
        #expect(mirroredDocument.revision == initialDocument.revision)
    }

    @Test func codexChatLogProjectionDeduplicatesReasoningMirrorSeparatedByCommand() async throws {
        var projection = ReviewMonitorCodexChatLogProjection()
        let reasoningText = "Inspecting differences"
        let turn = CodexTurnSnapshot(
            id: CodexTurnID(rawValue: "turn-review"),
            state: .inProgress,
            items: [
                .init(
                    id: "event-reasoning",
                    kind: .reasoning,
                    content: .reasoning(.init(summary: reasoningText)),
                    rawPayload: rawPayload(type: "agent_reasoning")
                ),
                .init(
                    id: "command-a",
                    kind: .commandExecution,
                    content: .command(.init(command: "/bin/zsh -lc"))
                ),
                .init(
                    id: "response-reasoning",
                    kind: .reasoning,
                    content: .reasoning(.init(summary: reasoningText)),
                    rawPayload: rawPayload(type: "reasoning")
                ),
            ]
        )

        let projectedDocument = projection.render(
            from: turn,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )
        let document = try #require(projectedDocument)

        #expect(document.blocks.count == 2)
        #expect(document.text == "\(reasoningText)\n\n$ /bin/zsh -lc")
    }

    @Test func codexChatLogProjectionDeduplicatesReasoningMirrorWithWrappedItemPayload() async throws {
        var projection = ReviewMonitorCodexChatLogProjection()
        let reasoningText = "Inspecting differences"
        let turn = CodexTurnSnapshot(
            id: CodexTurnID(rawValue: "turn-review"),
            state: .inProgress,
            items: [
                .init(
                    id: "event-reasoning",
                    kind: .reasoning,
                    content: .reasoning(.init(summary: reasoningText)),
                    rawPayload: rawPayload(type: "agent_reasoning")
                ),
                .init(
                    id: "response-reasoning",
                    kind: .reasoning,
                    content: .reasoning(.init(summary: reasoningText)),
                    rawPayload: Data("{\"type\":\"item.completed\",\"item\":{\"type\":\"reasoning\"}}".utf8)
                ),
            ]
        )

        let projectedDocument = projection.render(
            from: turn,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )
        let document = try #require(projectedDocument)

        #expect(document.blocks.count == 1)
        #expect(document.text == reasoningText)
    }

    @Test func codexChatLogProjectionKeepsRepeatedReasoningAfterMirrorPairConsumed() async throws {
        var projection = ReviewMonitorCodexChatLogProjection()
        let reasoningText = "Inspecting differences"
        func reasoningItem(id: String, payloadType: String) -> CodexThreadItem {
            .init(
                id: id,
                kind: .reasoning,
                content: .reasoning(.init(summary: reasoningText)),
                rawPayload: rawPayload(type: payloadType)
            )
        }
        let turn = CodexTurnSnapshot(
            id: CodexTurnID(rawValue: "turn-review"),
            state: .inProgress,
            items: [
                reasoningItem(id: "event-reasoning-1", payloadType: "agent_reasoning"),
                reasoningItem(id: "response-reasoning-1", payloadType: "reasoning"),
                reasoningItem(id: "event-reasoning-2", payloadType: "agent_reasoning"),
                reasoningItem(id: "response-reasoning-2", payloadType: "reasoning"),
            ]
        )

        let projectedDocument = projection.render(
            from: turn,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )
        let document = try #require(projectedDocument)

        #expect(document.blocks.count == 2)
        #expect(document.text == "\(reasoningText)\n\n\(reasoningText)")
    }

    @Test func codexChatLogProjectionRendersUserMessageWithoutReviewModeLog() async throws {
        var projection = ReviewMonitorCodexChatLogProjection()
        let turn = CodexTurnSnapshot(
            id: CodexTurnID(rawValue: "turn-chat"),
            state: .inProgress,
            items: [
                .init(
                    id: "user-message",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "user-message",
                        role: .user,
                        text: "Explain the current diff."
                    ))
                ),
            ]
        )
        let document = projection.render(
            from: turn,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )

        #expect(document?.text == "Explain the current diff.")
    }

    @Test func codexChatLogProjectionUsesTerminalTurnStatusForRunningCommand() async throws {
        var projection = ReviewMonitorCodexChatLogProjection()
        let turn = CodexTurnSnapshot(
            id: CodexTurnID(rawValue: "turn-command"),
            state: .completed,
            items: [
                .init(
                    id: "command-running",
                    kind: .commandExecution,
                    content: .command(.init(
                        command: "/bin/zsh -lc",
                        output: "done",
                        status: .inProgress,
                        startedAt: Date(timeIntervalSince1970: 4_000)
                    ))
                ),
            ]
        )

        let renderedDocument = projection.render(
            from: turn,
            chatCreatedAt: nil,
            chatUpdatedAt: Date(timeIntervalSince1970: 4_005)
        )
        let sourceDocument = try #require(renderedDocument)
        let commandBlock = try #require(sourceDocument.blocks.first { $0.kind == ReviewMonitorLog.Kind.command })
        #expect(commandBlock.metadata?.status == CodexTurnStatus.completed.rawValue)
        #expect(commandBlock.metadata?.commandStatus == CodexTurnStatus.completed.rawValue)

        let displayDocument = ReviewMonitorCommandOutputDisplayDocument.make(
            from: sourceDocument,
            currentDate: Date(timeIntervalSince1970: 4_010)
        )
        let panel = try #require(displayDocument.commandOutputPanels.first)
        #expect(panel.isActive == false)
        #expect(panel.title.hasPrefix("Ran /bin/zsh -lc"))
        #expect(panel.exitText == "Success")
    }

    @Test func codexChatLogProjectionUsesCommandExitCodeOverTerminalTurnSuccess() async throws {
        var projection = ReviewMonitorCodexChatLogProjection()
        let turn = CodexTurnSnapshot(
            id: CodexTurnID(rawValue: "turn-command"),
            state: .completed,
            items: [
                .init(
                    id: "command-failed",
                    kind: .commandExecution,
                    content: .command(.init(
                        command: "/bin/zsh -lc",
                        output: "error",
                        exitCode: 1,
                        status: .inProgress,
                        startedAt: Date(timeIntervalSince1970: 4_000)
                    ))
                ),
            ]
        )

        let renderedDocument = projection.render(
            from: turn,
            chatCreatedAt: nil,
            chatUpdatedAt: Date(timeIntervalSince1970: 4_005)
        )
        let sourceDocument = try #require(renderedDocument)
        let commandBlock = try #require(sourceDocument.blocks.first { $0.kind == ReviewMonitorLog.Kind.command })
        #expect(commandBlock.metadata?.status == CodexTurnStatus.failed.rawValue)
        #expect(commandBlock.metadata?.commandStatus == CodexTurnStatus.failed.rawValue)

        let displayDocument = ReviewMonitorCommandOutputDisplayDocument.make(
            from: sourceDocument,
            currentDate: Date(timeIntervalSince1970: 4_010)
        )
        let panel = try #require(displayDocument.commandOutputPanels.first)
        #expect(panel.isActive == false)
        #expect(panel.exitText == "exit 1")
    }

    @Test func codexChatStatusOnlyChangesKeepIncrementalLogUpdates() async throws {
        var projection = ReviewMonitorCodexChatLogSourceProjection()
        let turnID = CodexTurnID(rawValue: "turn-review")
        let initialTurn = CodexTurnSnapshot(
                    id: turnID,
                    state: .inProgress,
                    items: [
                        .init(
                            id: "message-review",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-review",
                                role: .assistant,
                                text: "Running review"
                            ))
                        ),
                    ]
        )
        let thread = CodexThreadSnapshot(
            id: "thread-review",
            turns: [initialTurn]
        )

        let initialChange = projection.apply(.init(
            generation: 1,
            sequence: 0,
            payload: .snapshot(.init(thread: thread, phase: .running(turnID: turnID)), reason: .initial)
        ))
        var completedTurn = initialTurn
        completedTurn.state = .completed
        let statusChange = projection.apply(.init(
            generation: 1,
            sequence: 1,
            payload: .update(.turnUpdated(completedTurn, index: 0))
        ))

        #expect(initialChange?.allowsIncrementalRender == false)
        #expect(statusChange?.allowsIncrementalRender == true)
        #expect(statusChange?.sourceDocument?.text == "Running review")
    }

    @Test func codexChatTurnUpdatesIgnoreNonSemanticRawPayloadEncodingChanges() async throws {
        var projection = ReviewMonitorCodexChatLogSourceProjection()
        let turnID = CodexTurnID(rawValue: "turn-raw-payload")
        let item = CodexThreadItem(
            id: "message-raw-payload",
            kind: .agentMessage,
            content: .message(.init(
                id: "message-raw-payload",
                role: .assistant,
                text: "Stable message"
            )),
            rawPayload: Data(#"{"type":"agentMessage","text":"Stable message"}"#.utf8)
        )
        let initialTurn = CodexTurnSnapshot(
            id: turnID,
            state: .inProgress,
            items: [item]
        )
        _ = projection.apply(.init(
            generation: 1,
            sequence: 0,
            payload: .snapshot(.init(
                thread: .init(id: "thread-raw-payload", turns: [initialTurn]),
                phase: .running(turnID: turnID)
            ), reason: .initial)
        ))

        var reencodedItem = item
        reencodedItem.rawPayload = Data(
            #"{"text":"Stable message","type":"agentMessage"}"#.utf8
        )
        let updatedTurn = CodexTurnSnapshot(
            id: turnID,
            state: .completed,
            items: [reencodedItem]
        )
        let update = projection.apply(.init(
            generation: 1,
            sequence: 1,
            payload: .update(.turnUpdated(updatedTurn, index: 0))
        ))

        #expect(update?.allowsIncrementalRender == true)
        #expect(update?.sourceDocument?.text == "Stable message")
    }

    @Test func codexChatTurnUpdatesIgnoreReasoningFragmentBoundaryChanges() throws {
        var projection = ReviewMonitorCodexChatLogSourceProjection()
        let turnID = CodexTurnID(rawValue: "turn-reasoning-fragments")
        let item = CodexThreadItem(
            id: "reasoning-fragments",
            kind: .reasoning,
            content: .reasoning(.init(summary: ["First"], content: []))
        )
        let initialTurn = CodexTurnSnapshot(
            id: turnID,
            state: .inProgress,
            items: [item]
        )
        _ = projection.apply(.init(
            generation: 1,
            sequence: 0,
            payload: .snapshot(.init(
                thread: .init(id: "thread-reasoning-fragments", turns: [initialTurn]),
                phase: .running(turnID: turnID)
            ), reason: .initial)
        ))

        _ = projection.apply(.init(
            generation: 1,
            sequence: 1,
            payload: .update(.itemTextAppended(
                .init(item: item, turnID: turnID),
                delta: "\n\nSecond"
            ))
        ))

        var canonicalItem = item
        canonicalItem.content = .reasoning(.init(summary: ["First", "Second"], content: []))
        let canonicalTurn = CodexTurnSnapshot(
            id: turnID,
            state: .completed,
            items: [canonicalItem]
        )
        let update = projection.apply(.init(
            generation: 1,
            sequence: 2,
            payload: .update(.turnUpdated(canonicalTurn, index: 0))
        ))

        #expect(update?.allowsIncrementalRender == true)
        #expect(update?.sourceDocument?.text == "First\n\nSecond")
    }

    @Test func codexChatSourceProjectionKeepsTranscriptWhenNewTurnStartsWithoutRenderableText() async throws {
        var projection = ReviewMonitorCodexChatLogSourceProjection()
        let firstTurnID = CodexTurnID(rawValue: "turn-review")
        let secondTurnID = CodexTurnID(rawValue: "turn-reasoning")
        let initialThread = CodexThreadSnapshot(
            id: "thread-review",
            turns: [
                .init(
                    id: firstTurnID,
                    state: .inProgress,
                    items: [
                        .init(
                            id: "message-review",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "message-review",
                                role: .assistant,
                                text: "Existing review log"
                            ))
                        ),
                    ]
                ),
            ]
        )
        let insertedTurn = CodexTurnSnapshot(
            id: secondTurnID,
            state: .inProgress,
            items: [
                .init(
                    id: "reasoning-empty",
                    kind: .reasoning,
                    content: .reasoning(.empty)
                ),
            ]
        )

        let initialChange = projection.apply(.init(
            generation: 1,
            sequence: 0,
            payload: .snapshot(
                .init(thread: initialThread, phase: .running(turnID: firstTurnID)),
                reason: .initial
            )
        ))
        let updatedChange = projection.apply(.init(
            generation: 1,
            sequence: 1,
            payload: .update(.turnInserted(insertedTurn, index: 1))
        ))

        #expect(initialChange?.sourceDocument?.text == "Existing review log")
        guard case .update(let document) = updatedChange else {
            Issue.record("Expected the existing chat transcript to stay rendered while a new empty turn starts.")
            return
        }
        #expect(document.text == "Existing review log")
        #expect(updatedChange?.allowsIncrementalRender == true)
    }

    @Test func codexChatSourceProjectionAppliesTextDeltaWithoutReadingLiveGraph() throws {
        var projection = ReviewMonitorCodexChatLogSourceProjection()
        let turnID = CodexTurnID(rawValue: "turn-delta")
        let item = CodexThreadItem(
            id: "message-delta",
            kind: .agentMessage,
            content: .message(.init(
                id: "message-delta",
                role: .assistant,
                text: "Initial"
            ))
        )
        let thread = CodexThreadSnapshot(
            id: "thread-delta",
            turns: [.init(id: turnID, state: .inProgress, items: [item])]
        )
        _ = projection.apply(.init(
            generation: 1,
            sequence: 0,
            payload: .snapshot(
                .init(thread: thread, phase: .running(turnID: turnID)),
                reason: .initial
            )
        ))

        let change = projection.apply(.init(
            generation: 1,
            sequence: 1,
            payload: .update(.itemTextAppended(
                .init(item: item, turnID: turnID),
                delta: " log"
            ))
        ))

        #expect(change?.sourceDocument?.text == "Initial log")
        #expect(change?.allowsIncrementalRender == true)
    }

    @Test func codexChatItemLocatorDistinguishesReviewMarkersWithSameRawID() throws {
        var projection = ReviewMonitorCodexChatLogSourceProjection()
        let turnID = CodexTurnID(rawValue: "turn-marker-locator")
        let userItem = CodexThreadItem(
            id: "user",
            kind: .userMessage,
            content: .message(.init(id: "user", role: .user, text: "User prompt"))
        )
        let entered = CodexThreadItem(
            id: "shared-marker",
            kind: .enteredReviewMode,
            content: .log("Entered")
        )
        let exited = CodexThreadItem(
            id: "shared-marker",
            kind: .exitedReviewMode,
            content: .log("Exited")
        )
        let thread = CodexThreadSnapshot(
            id: "thread-marker-locator",
            turns: [.init(
                id: turnID,
                state: .completed,
                items: [userItem, entered, exited]
            )]
        )
        _ = projection.apply(.init(
            generation: 1,
            sequence: 0,
            payload: .snapshot(.init(
                thread: thread,
                phase: .terminal(turnID: turnID, disposition: .completed)
            ), reason: .initial)
        ))

        let afterEnteredRemoval = projection.apply(.init(
            generation: 1,
            sequence: 1,
            payload: .update(.itemRemoved(.init(item: entered, turnID: turnID)))
        ))
        #expect(afterEnteredRemoval?.sourceDocument?.text.contains("Exited") == true)
        #expect(afterEnteredRemoval?.sourceDocument?.text.contains("User prompt") == false)

        let afterExitedRemoval = projection.apply(.init(
            generation: 1,
            sequence: 2,
            payload: .update(.itemRemoved(.init(item: exited, turnID: turnID)))
        ))
        #expect(afterExitedRemoval?.sourceDocument?.text == "User prompt")
    }

    @Test func codexChatSourceProjectionAppliesAfterIndexesForUpdatedItemsAndTurns() throws {
        var projection = ReviewMonitorCodexChatLogSourceProjection()
        let firstTurnID = CodexTurnID(rawValue: "turn-first")
        let secondTurnID = CodexTurnID(rawValue: "turn-second")
        let firstItem = CodexThreadItem(
            id: "message-first",
            kind: .agentMessage,
            content: .message(.init(id: "message-first", role: .assistant, text: "First"))
        )
        let secondItem = CodexThreadItem(
            id: "message-second",
            kind: .agentMessage,
            content: .message(.init(id: "message-second", role: .assistant, text: "Second"))
        )
        let thirdItem = CodexThreadItem(
            id: "message-third",
            kind: .agentMessage,
            content: .message(.init(id: "message-third", role: .assistant, text: "Third"))
        )
        let firstTurn = CodexTurnSnapshot(
            id: firstTurnID,
            state: .completed,
            items: [firstItem, secondItem]
        )
        let secondTurn = CodexTurnSnapshot(
            id: secondTurnID,
            state: .completed,
            items: [thirdItem]
        )
        _ = projection.apply(.init(
            generation: 1,
            sequence: 0,
            payload: .snapshot(.init(
                thread: .init(id: "thread-reorder", turns: [firstTurn, secondTurn]),
                phase: .terminal(turnID: secondTurnID, disposition: .completed)
            ), reason: .initial)
        ))

        var updatedFirstItem = firstItem
        updatedFirstItem.content = .message(.init(
            id: "message-first",
            role: .assistant,
            text: "First updated"
        ))
        let itemMove = projection.apply(.init(
            generation: 1,
            sequence: 1,
            payload: .update(.itemUpdated(
                item: updatedFirstItem,
                turnID: firstTurnID,
                index: 1
            ))
        ))
        let itemMoveText = try #require(itemMove?.sourceDocument?.text)
        let secondRange = try #require(itemMoveText.range(of: "Second"))
        let updatedFirstRange = try #require(itemMoveText.range(of: "First updated"))
        #expect(secondRange.lowerBound < updatedFirstRange.lowerBound)

        var updatedFirstTurn = firstTurn
        updatedFirstTurn.items = [secondItem, updatedFirstItem]
        let turnMove = projection.apply(.init(
            generation: 1,
            sequence: 2,
            payload: .update(.turnUpdated(updatedFirstTurn, index: 1))
        ))
        let turnMoveText = try #require(turnMove?.sourceDocument?.text)
        let thirdRange = try #require(turnMoveText.range(of: "Third"))
        let movedSecondRange = try #require(turnMoveText.range(of: "Second"))
        #expect(thirdRange.lowerBound < movedSecondRange.lowerBound)
    }

    @Test func codexChatRendersThreadAndLiveUpdates() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let modelContext = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueThreadResume(.init(id: "chat-thread"))
        try await runtime.transport.enqueueThreadRead(
            .init(
                id: "chat-thread",
                turns: [
                    .init(
                        id: "turn-1",
                        state: .inProgress,
                        items: [
                            .init(
                                id: "message-1",
                                kind: .agentMessage,
                                content: .message(
                                    .init(
                                        id: "message-1",
                                        role: .assistant,
                                        phase: .finalAnswer,
                                        text: "Generic chat snapshot"
                                    ))
                            )
                        ]
                    )
                ]
            ))

        let store = CodexReviewStore.makePreviewStore()
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let transport = ReviewMonitorTransportViewController(
            uiState: uiState,
            modelContext: modelContext
        )
        transport.loadViewIfNeeded()

        uiState.selection = .chat(CodexThreadID(rawValue: "chat-thread"))

        _ = try await awaitTransportRender(
            transport,
            expectedSelection: .chat("chat-thread")
        ) { snapshot in
            snapshot.log.contains("Generic chat snapshot")
        }
        #expect(transport.renderedStateForTesting.selection == .chat("chat-thread"))

        try await runtime.transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "chat-thread",
                turnID: "turn-1",
                item: .init(
                    id: "message-1",
                    type: "agentMessage",
                    text: "Generic chat stream update",
                    phase: "final_answer"
                )
            )
        )

        let updatedSnapshot = try await awaitTransportRender(
            transport,
            expectedSelection: .chat("chat-thread")
        ) { snapshot in
            snapshot.log.contains("Generic chat stream update")
        }
        #expect(updatedSnapshot.log.contains("Generic chat snapshot") == false)
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 1)
    }

    private func selectChat(
        id: String,
        in uiState: ReviewMonitorUIState
    ) {
        let chatID = CodexThreadID(rawValue: id)
        uiState.selection = .chat(chatID)
    }

    private func makeProjectionChat(
        threadID: CodexThreadID = CodexThreadID(rawValue: "review-thread"),
        turns: [CodexTurnSnapshot]
    ) async throws -> CodexChat {
        let runtime = try await CodexAppServerTestRuntime.start()
        let modelContext = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueThreadResume(.init(id: threadID))
        try await runtime.transport.enqueueThreadRead(
            .init(
                id: threadID,
                turns: turns
            ))
        let chat = modelContext.model(for: threadID)
        try await modelContext.refresh(chat)
        return chat
    }

    private func rawPayload(type: String) -> Data {
        Data("{\"type\":\"\(type)\"}".utf8)
    }
}

private struct ThreadItemParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var item: Item
    var completedAtMs: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case item
        case completedAtMs
    }

    struct Item: Encodable, Sendable {
        var id: String
        var type: String
        var text: String?
        var phase: String?
    }
}
