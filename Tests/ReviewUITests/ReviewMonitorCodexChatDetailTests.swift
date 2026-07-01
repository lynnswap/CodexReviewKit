import CodexKit
import CodexAppServerKitTesting
import Testing
@_spi(Testing) @testable import CodexReviewKit
@testable import ReviewChatLogUI
@testable import ReviewUI

@Suite("ReviewMonitor selected Codex chat detail", .serialized)
@MainActor
struct ReviewMonitorCodexChatDetailTests {
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

    @Test func codexChatLogProjectionSkipsUserPromptWhenReviewModeLogExists() {
        var projection = ReviewMonitorCodexChatLogProjection()
        let document = projection.render(
            from: .init(
                turn: .init(id: CodexTurnID(rawValue: "turn-review"), status: .running),
                items: [
                    .init(
                        id: "user-message",
                        turnID: CodexTurnID(rawValue: "turn-review"),
                        kind: .userMessage,
                        content: .message(.init(
                            id: "user-message",
                            role: .user,
                            text: "Review the current code changes."
                        ))
                    ),
                    .init(
                        id: "entered-review",
                        turnID: CodexTurnID(rawValue: "turn-review"),
                        kind: .enteredReviewMode,
                        content: .log("Review the current code changes.")
                    ),
                ]
            ),
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )

        #expect(document?.text == "Review the current code changes.")
    }

    @Test func codexChatLogProjectionRendersUserMessageWithoutReviewModeLog() {
        var projection = ReviewMonitorCodexChatLogProjection()
        let document = projection.render(
            from: .init(
                turn: .init(id: CodexTurnID(rawValue: "turn-chat"), status: .running),
                items: [
                    .init(
                        id: "user-message",
                        turnID: CodexTurnID(rawValue: "turn-chat"),
                        kind: .userMessage,
                        content: .message(.init(
                            id: "user-message",
                            role: .user,
                            text: "Explain the current diff."
                        ))
                    ),
                ]
            ),
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )

        #expect(document?.text == "Explain the current diff.")
    }

    @Test func codexChatStatusOnlyChangesKeepIncrementalLogUpdates() {
        var projection = ReviewMonitorCodexChatLogSourceProjection()
        let turnID = CodexTurnID(rawValue: "turn-review")
        let snapshot = CodexChatSnapshot(
            chatID: CodexThreadID(rawValue: "review-thread"),
            phase: .loading,
            turns: [.init(id: turnID, status: .running)],
            items: [
                .init(
                    id: "message-review",
                    turnID: turnID,
                    kind: .agentMessage,
                    content: .message(.init(
                        id: "message-review",
                        role: .assistant,
                        text: "Running review"
                    ))
                ),
            ]
        )

        let initialChange = projection.apply(snapshotChange(snapshot), chatCreatedAt: nil, chatUpdatedAt: nil)
        let statusChange = projection.apply(
            .turnUpdated(.init(id: turnID, status: .running)),
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )

        #expect(initialChange?.allowsIncrementalRender == false)
        #expect(statusChange?.allowsIncrementalRender == true)
        #expect(statusChange?.sourceDocument?.text == "Running review")
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

    private func snapshotChange(_ snapshot: CodexChatSnapshot) -> CodexChatChange {
        .snapshot(snapshot)
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
