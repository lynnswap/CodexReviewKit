import CodexKit
import CodexAppServerKitTesting
import Testing
@_spi(Testing) @testable import CodexReviewKit
@testable import ReviewUI

@Suite("ReviewMonitor selected Codex chat", .serialized)
@MainActor
struct ReviewMonitorSelectedCodexChatTests {
    @Test func selectedReviewChatObservesChatID() async throws {
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

        uiState.selection = .chat(
            .init(
                rowID: .chat(CodexThreadID(rawValue: "review-thread")),
                id: CodexThreadID(rawValue: "review-thread"),
                title: "Review",
                preview: nil,
                workspaceCWD: "/tmp/project",
                updatedAt: nil
            ))

        try await waitForCondition {
            transport.selectedCodexChatIDForTesting == "review-thread"
                && transport.selectedCodexChatPhaseForTesting == .loading
                && transport.selectedCodexChatItemTextsForTesting == ["Review snapshot"]
        }
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 1)
    }

    @Test func clearingSelectionDetachesSelectedCodexChat() async throws {
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
        try await waitForCondition {
            transport.selectedCodexChatIDForTesting == "review-thread"
                && transport.selectedCodexChatPhaseForTesting == .loaded
        }

        uiState.selection = nil
        try await waitForCondition {
            transport.selectedCodexChatIDForTesting == nil
                && transport.selectedCodexChatPhaseForTesting == .idle
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

        #expect(transport.selectedCodexChatIDForTesting == nil)

        modelSource.install(container: CodexModelContainer(appServer: runtime.server))

        try await waitForCondition {
            transport.selectedCodexChatIDForTesting == "review-thread"
                && transport.selectedCodexChatPhaseForTesting == .loading
                && transport.selectedCodexChatItemTextsForTesting == ["Late source"]
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

        let initialSnapshot = try await awaitTransportRender(transport) { snapshot in
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

        let updatedSnapshot = try await awaitTransportRender(transport) { snapshot in
            snapshot.log.contains("Chat stream update")
        }
        #expect(updatedSnapshot.log.contains("Chat snapshot") == false)
        #expect(updatedSnapshot.log.contains("Log fallback") == false)
    }

    @Test func selectedCodexChatTextAppendUsesAppendPath() async throws {
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

        _ = try await awaitTransportRender(transport) { snapshot in
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

        let updatedSnapshot = try await awaitTransportRender(transport) { snapshot in
            snapshot.log == "Initial log"
        }
        #expect(updatedSnapshot.log == "Initial log")
        #expect(transport.logAppendCountForTesting == appendCount + 1)
        #expect(transport.logReloadCountForTesting == reloadCount)
    }

    @Test func selectedCodexChatRendersThreadAndLiveUpdates() async throws {
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

        uiState.selection = .chat(
            .init(
                rowID: .chat(CodexThreadID(rawValue: "chat-thread")),
                id: CodexThreadID(rawValue: "chat-thread"),
                title: "Generic chat",
                preview: nil,
                workspaceCWD: "/tmp/project",
                updatedAt: nil
            ))

        _ = try await awaitTransportRender(transport) { snapshot in
            snapshot.log.contains("Generic chat snapshot")
        }
        #expect(transport.renderedStateForTesting.selection == .chat("chat-thread"))
        #expect(transport.selectedCodexChatIDForTesting == "chat-thread")

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

        let updatedSnapshot = try await awaitTransportRender(transport) { snapshot in
            snapshot.log.contains("Generic chat stream update")
        }
        #expect(updatedSnapshot.log.contains("Generic chat snapshot") == false)
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 1)
    }

    private func selectChat(
        id: String,
        title: String = "Review",
        in uiState: ReviewMonitorUIState
    ) {
        let chatID = CodexThreadID(rawValue: id)
        uiState.selection = .chat(.init(
            rowID: .chat(chatID),
            id: chatID,
            title: title,
            preview: nil,
            workspaceCWD: "/tmp/project",
            updatedAt: nil
        ))
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
