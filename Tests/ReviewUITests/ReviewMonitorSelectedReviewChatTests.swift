import CodexAppServerKit
import CodexAppServerKitTesting
import CodexDataKit
import Testing
@_spi(Testing) @testable import CodexReviewKit
@testable import ReviewUI

@Suite("ReviewMonitor selected review chat", .serialized)
@MainActor
struct ReviewMonitorSelectedReviewChatTests {
    @Test func selectedReviewJobObservesActiveCodexChat() async throws {
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
            store: store,
            uiState: uiState,
            modelContext: modelContext
        )
        transport.loadViewIfNeeded()

        let job = makeRunningReviewJob(
            sourceThreadID: "source-thread",
            reviewThreadID: "review-thread",
            turnID: "turn-1"
        )
        uiState.selection = .job(job)

        try await waitForCondition {
            transport.selectedReviewChatIDForTesting == "review-thread"
                && transport.selectedReviewChatPhaseForTesting == .loaded
                && transport.selectedReviewChatItemTextsForTesting == ["Review snapshot"]
        }
        #expect(transport.selectedReviewChatLinkForTesting?.activeChatThreadID == "review-thread")
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == 1)
    }

    @Test func clearingSelectionDetachesSelectedReviewChat() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let modelContext = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueThreadResume(.init(id: "review-thread"))
        try await runtime.transport.enqueueThreadRead(.init(id: "review-thread"))

        let store = CodexReviewStore.makePreviewStore()
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let transport = ReviewMonitorTransportViewController(
            store: store,
            uiState: uiState,
            modelContext: modelContext
        )
        transport.loadViewIfNeeded()

        uiState.selection = .job(
            makeRunningReviewJob(
                sourceThreadID: "source-thread",
                reviewThreadID: "review-thread",
                turnID: "turn-1"
            ))
        try await waitForCondition {
            transport.selectedReviewChatIDForTesting == "review-thread"
                && transport.selectedReviewChatPhaseForTesting == .loaded
        }

        uiState.selection = nil
        try await waitForCondition {
            transport.selectedReviewChatIDForTesting == nil && transport.selectedReviewChatLinkForTesting == nil
                && transport.selectedReviewChatPhaseForTesting == .idle
        }
    }

    @Test func selectedReviewJobConnectsWhenModelSourceInstallsLater() async throws {
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
            store: store,
            uiState: uiState,
            codexModelSource: modelSource
        )
        transport.loadViewIfNeeded()
        uiState.selection = .job(
            makeRunningReviewJob(
                sourceThreadID: "source-thread",
                reviewThreadID: "review-thread",
                turnID: "turn-1"
            ))

        try await waitForCondition {
            transport.selectedReviewChatLinkForTesting?.activeChatThreadID == "review-thread"
        }
        #expect(transport.selectedReviewChatIDForTesting == nil)

        modelSource.install(container: CodexModelContainer(appServer: runtime.server))

        try await waitForCondition {
            transport.selectedReviewChatIDForTesting == "review-thread"
                && transport.selectedReviewChatPhaseForTesting == .loaded
                && transport.selectedReviewChatItemTextsForTesting == ["Late source"]
        }
    }

    @Test func selectedReviewJobConnectsWhenRunIdentifiersArriveAfterSelection() async throws {
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
                                        text: "Arrived after selection"
                                    ))
                            )
                        ]
                    )
                ]
            ))

        let store = CodexReviewStore.makePreviewStore()
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let transport = ReviewMonitorTransportViewController(
            store: store,
            uiState: uiState,
            modelContext: modelContext
        )
        transport.loadViewIfNeeded()
        let job = makeRunningReviewJob(
            sourceThreadID: nil,
            reviewThreadID: nil,
            turnID: nil
        )
        uiState.selection = .job(job)

        #expect(transport.selectedReviewChatLinkForTesting == nil)

        job.core.run.threadID = "source-thread"
        job.core.run.reviewThreadID = "review-thread"
        job.core.run.turnID = "turn-1"
        job.appendLogEntry(.init(kind: .agentMessage, text: "Legacy trigger"))

        try await waitForCondition {
            transport.selectedReviewChatIDForTesting == "review-thread"
                && transport.selectedReviewChatPhaseForTesting == .loaded
                && transport.selectedReviewChatItemTextsForTesting == ["Arrived after selection"]
        }
    }

    @Test func selectedReviewJobRendersCodexChatTurnAndLiveUpdates() async throws {
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
            store: store,
            uiState: uiState,
            modelContext: modelContext
        )
        transport.loadViewIfNeeded()

        let job = makeRunningReviewJob(
            sourceThreadID: "source-thread",
            reviewThreadID: "review-thread",
            turnID: "turn-1"
        )
        job.appendLogEntry(.init(kind: .agentMessage, text: "Legacy fallback"))
        uiState.selection = .job(job)

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
        #expect(updatedSnapshot.log.contains("Legacy fallback") == false)
    }

    private func makeRunningReviewJob(
        sourceThreadID: String?,
        reviewThreadID: String?,
        turnID: String?
    ) -> CodexReviewJob {
        let job = CodexReviewJob.makeForTesting(
            id: "job-1",
            sessionID: "session-1",
            cwd: "/tmp/project",
            targetSummary: "Uncommitted changes",
            threadID: sourceThreadID,
            turnID: turnID,
            status: .running,
            summary: "Running"
        )
        job.core.run.attemptID = "attempt-1"
        job.core.run.reviewThreadID = reviewThreadID
        return job
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
