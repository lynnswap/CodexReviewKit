import CodexKit
import CodexAppServerKitTesting
import Testing
@_spi(Testing) @testable import CodexReviewKit
@testable import ReviewChatLogUI
@testable import ReviewUI

@Suite("ReviewMonitor selected Codex chat detail", .serialized)
@MainActor
struct ReviewMonitorCodexChatDetailTests {
    @Test func logResynchronizationCanUpdateAfterInitialBaseline() async throws {
        let turnID = CodexTurnID(rawValue: "turn-1")
        let chat = try await makeProjectionChat(
            turns: [
                .init(
                    id: turnID,
                    status: .running,
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

        let initialChange = projection.applyBaseline(
            from: chat,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )
        guard case .replaceAll = initialChange else {
            Issue.record("Expected initial snapshot to replace the empty log")
            return
        }

        let resynchronizedChange = projection.apply(
            .resynchronized(reason: .refresh),
            in: chat,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )
        guard case .update = resynchronizedChange else {
            Issue.record("Expected resynchronization to update the existing log incrementally")
            return
        }
        #expect(resynchronizedChange?.allowsIncrementalRender == true)
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
                        status: .running,
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
                    status: .completed,
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
                    status: .completed,
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
                    status: .completed,
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
                        status: .running,
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
                        status: .running,
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
            method: "item/updated",
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
                        status: .running,
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
            method: "item/updated",
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
            status: .running,
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

    @Test func codexChatLogProjectionRendersUserMessageWithoutReviewModeLog() async throws {
        var projection = ReviewMonitorCodexChatLogProjection()
        let turn = CodexTurnSnapshot(
            id: CodexTurnID(rawValue: "turn-chat"),
            status: .running,
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

    @Test func codexChatStatusOnlyChangesKeepIncrementalLogUpdates() async throws {
        var projection = ReviewMonitorCodexChatLogSourceProjection()
        let turnID = CodexTurnID(rawValue: "turn-review")
        let chat = try await makeProjectionChat(
            turns: [
                .init(
                    id: turnID,
                    status: .running,
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
                ),
            ]
        )

        let initialChange = projection.applyBaseline(from: chat, chatCreatedAt: nil, chatUpdatedAt: nil)
        let statusChange = projection.apply(
            .turnUpdated(id: turnID),
            in: chat,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )

        #expect(initialChange?.allowsIncrementalRender == false)
        #expect(statusChange?.allowsIncrementalRender == true)
        #expect(statusChange?.sourceDocument?.text == "Running review")
    }

    @Test func codexChatSourceProjectionKeepsTranscriptWhenNewTurnStartsWithoutRenderableText() async throws {
        var projection = ReviewMonitorCodexChatLogSourceProjection()
        let firstTurnID = CodexTurnID(rawValue: "turn-review")
        let secondTurnID = CodexTurnID(rawValue: "turn-reasoning")
        let initialChat = try await makeProjectionChat(
            turns: [
                .init(
                    id: firstTurnID,
                    status: .running,
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
        let updatedChat = try await makeProjectionChat(
            turns: [
                .init(
                    id: firstTurnID,
                    status: .running,
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
                .init(
                    id: secondTurnID,
                    status: .running,
                    items: [
                        .init(
                            id: "reasoning-empty",
                            kind: .reasoning,
                            content: .reasoning(.empty)
                        ),
                    ]
                ),
            ]
        )

        let initialChange = projection.applyBaseline(
            from: initialChat,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )
        let updatedChange = projection.apply(
            .itemInserted(id: "reasoning-empty", turnID: secondTurnID),
            in: updatedChat,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )

        #expect(initialChange?.sourceDocument?.text == "Existing review log")
        guard case .update(let document) = updatedChange else {
            Issue.record("Expected the existing chat transcript to stay rendered while a new empty turn starts.")
            return
        }
        #expect(document.text == "Existing review log")
        #expect(updatedChange?.allowsIncrementalRender == true)
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
                        status: .running,
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
            method: "item/updated",
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
}

private struct ThreadItemParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var item: Item

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case item
    }

    struct Item: Encodable, Sendable {
        var id: String
        var type: String
        var text: String?
        var phase: String?
    }
}
