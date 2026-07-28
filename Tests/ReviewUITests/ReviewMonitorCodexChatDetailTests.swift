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
        try await runtime.transport.enqueueThreadResume(try makeChatDetailStoredThread(id: "review-thread"))
        try await runtime.transport.enqueueThreadRead(
            try makeChatDetailStoredThread(
                id: "review-thread",
                turnID: "turn-1",
                state: .inProgress,
                messageID: "message-1",
                message: "Review snapshot",
                phase: .finalAnswer
            )
        )

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
        #expect(await runtime.transport.recordedRequests(for: .threadResume).count == 1)
    }

    @Test func switchingSelectedChatKeepsPreviousLogUntilNextBaselineRenders() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let modelContext = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueThreadResume(try makeChatDetailStoredThread(id: "first-thread"))
        try await runtime.transport.enqueueThreadRead(try makeChatDetailStoredThread(
            id: "first-thread",
            turnID: "turn-first",
            state: .completed,
            messageID: "message-first",
            message: "First chat log"
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
        await runtime.transport.holdNext(.threadRead, gate: secondReadGate)
        try await runtime.transport.enqueueThreadResume(try makeChatDetailStoredThread(id: "second-thread"))
        try await runtime.transport.enqueueThreadRead(try makeChatDetailStoredThread(
            id: "second-thread",
            turnID: "turn-second",
            state: .completed,
            messageID: "message-second",
            message: "Second chat log"
        ))

        selectChat(id: "second-thread", in: uiState)
        await runtime.transport.waitForRequest(.threadRead, count: 2)
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
        try await runtime.transport.enqueueThreadResume(try makeChatDetailStoredThread(id: "first-thread"))
        try await runtime.transport.enqueueThreadRead(try makeChatDetailStoredThread(
            id: "first-thread",
            turnID: "turn-first",
            state: .completed,
            messageID: "message-first",
            message: "First chat log"
        ))
        try await runtime.transport.enqueueThreadResume(try makeChatDetailStoredThread(id: "empty-thread"))
        try await runtime.transport.enqueueThreadRead(try makeChatDetailStoredThread(id: "empty-thread", turns: []))

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
        try await runtime.transport.enqueueThreadResume(try makeChatDetailStoredThread(id: "review-thread"))
        try await runtime.transport.enqueueThreadRead(try makeChatDetailStoredThread(id: "review-thread"))

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
        try await runtime.transport.enqueueThreadResume(try makeChatDetailStoredThread(id: "review-thread"))
        try await runtime.transport.enqueueThreadRead(
            try makeChatDetailStoredThread(
                id: "review-thread",
                turnID: "turn-1",
                state: .inProgress,
                messageID: "message-1",
                message: "Late source",
                phase: .finalAnswer
            )
        )

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
        try await runtime.transport.enqueueThreadResume(try makeChatDetailStoredThread(id: "review-thread"))
        try await runtime.transport.enqueueThreadRead(
            try makeChatDetailStoredThread(
                id: "review-thread",
                turnID: "turn-1",
                state: .inProgress,
                messageID: "message-1",
                message: "Chat snapshot",
                phase: .finalAnswer
            )
        )

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

        try await runtime.notificationEmitter.emitItemCompleted(
            threadID: "review-thread",
            turnID: "turn-1",
            item: .agentMessage(
                id: "message-1",
                text: "Chat stream update",
                phase: .finalAnswer
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
        try await runtime.transport.enqueueThreadResume(try makeChatDetailStoredThread(id: "review-thread"))
        try await runtime.transport.enqueueThreadRead(
            try makeChatDetailStoredThread(
                id: "review-thread",
                turnID: "turn-1",
                state: .inProgress,
                messageID: "message-1",
                message: "Initial",
                phase: .finalAnswer
            )
        )

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

        try await runtime.notificationEmitter.emitItemCompleted(
            threadID: "review-thread",
            turnID: "turn-1",
            item: .agentMessage(
                id: "message-1",
                text: "Initial log",
                phase: .finalAnswer
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

    @Test func codexChatLogProjectionOnlyHidesUserPromptInMarkedTurn() async throws {
        var projection = ReviewMonitorCodexChatLogProjection()
        let snapshot = makeCodexThreadSnapshotForTesting(
            chatID: CodexThreadID(rawValue: "review-thread"),
            turns: [
                .init(
                    id: CodexTurnID(rawValue: "review-turn"),
                    state: .completed,
                    items: [
                        .init(
                            id: "review-user",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "review-user",
                                role: .user,
                                text: "Review this change."
                            ))
                        ),
                        .init(
                            id: "entered-review",
                            kind: .enteredReviewMode,
                            content: .log("Review started")
                        ),
                    ]
                ),
                .init(
                    id: CodexTurnID(rawValue: "ordinary-turn"),
                    state: .completed,
                    items: [
                        .init(
                            id: "ordinary-user",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "ordinary-user",
                                role: .user,
                                text: "Keep this prompt visible."
                            ))
                        ),
                    ]
                ),
            ]
        )

        let document = projection.render(
            from: snapshot,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )

        #expect(document?.text.contains("Review this change.") == false)
        #expect(document?.text.contains("Review started") == true)
        #expect(document?.text.contains("Keep this prompt visible.") == true)
    }

    @Test func codexChatLogProjectionConsumesNormalizedReviewAcrossTurns()
        async throws
    {
        var projection = ReviewMonitorCodexChatLogProjection()
        let reviewPrompt = "Review the current code changes."
        let finalReview = "No actionable correctness issues were identified."
        let snapshot = CodexThreadSnapshot(
            id: CodexThreadID(rawValue: "review-thread"),
            sourceKind: .vscode,
            turns: [
                .init(
                    id: CodexTurnID(rawValue: "outer-review-turn"),
                    state: .completed,
                    items: [
                        .init(
                            id: "entered-review",
                            kind: .enteredReviewMode,
                            content: .log("current changes")
                        ),
                        .init(
                            id: "review-user-outer",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "review-user-outer",
                                role: .user,
                                text: reviewPrompt
                            ))
                        ),
                        .init(
                            id: "review-output",
                            kind: .exitedReviewMode,
                            content: .log(finalReview)
                        ),
                    ]
                ),
                .init(
                    id: CodexTurnID(rawValue: "internal-reviewer-turn"),
                    state: .completed,
                    items: [
                        .init(
                            id: "item-1",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "item-1",
                                role: .user,
                                text: reviewPrompt
                            ))
                        ),
                        .init(
                            id: "item-2",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "item-2",
                                role: .user,
                                text: reviewPrompt
                            ))
                        ),
                        .init(
                            id: "review_rollout_assistant",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "review_rollout_assistant",
                                role: .assistant,
                                text: finalReview
                            ))
                        ),
                    ]
                ),
            ]
        )

        let document = projection.render(
            from: snapshot,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )

        #expect(document?.text == "current changes\n\n\(finalReview)")
        #expect(document?.blocks.count == 2)
    }

    @Test func codexChatLogProjectionSuppressesEquivalentTypedReviewRolloutCompanion() async throws {
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
                    id: "review_rollout_assistant",
                    kind: .agentMessage,
                    content: .message(.init(
                        id: "review_rollout_assistant",
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

    @Test func codexChatLogProjectionConsumesNormalizedInterruptedReviewAcrossTurns()
        async throws
    {
        var projection = ReviewMonitorCodexChatLogProjection()
        let reviewPrompt =
            "Review the current code changes (staged, unstaged, and untracked files)."
        let snapshot = CodexThreadSnapshot(
            id: CodexThreadID(rawValue: "interrupted-review-thread"),
            sourceKind: .vscode,
            turns: [
                .init(
                    id: CodexTurnID(rawValue: "outer-interrupted-review-turn"),
                    state: .interrupted,
                    items: [
                        .init(
                            id: "entered-review",
                            kind: .enteredReviewMode,
                            content: .log("current changes")
                        ),
                        .init(
                            id: "review-output",
                            kind: .exitedReviewMode,
                            content: .log("Reviewer failed to output a response.")
                        ),
                    ]
                ),
                .init(
                    id: CodexTurnID(rawValue: "internal-interrupted-reviewer-turn"),
                    state: .interrupted,
                    items: [
                        .init(
                            id: "item-1",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "item-1",
                                role: .user,
                                text: reviewPrompt
                            ))
                        ),
                        .init(
                            id: "item-2",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "item-2",
                                role: .user,
                                text: reviewPrompt
                            ))
                        ),
                        .init(
                            id: "review_rollout_assistant",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "review_rollout_assistant",
                                role: .assistant,
                                text: "Review was interrupted. Please re-run /review."
                            ))
                        ),
                    ]
                ),
            ]
        )

        let document = projection.render(
            from: snapshot,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )

        #expect(document?.text == "current changes\n\nReviewer failed to output a response.")
        #expect(document?.blocks.count == 2)
    }

    @Test func codexChatLogProjectionKeepsGeneralAssistantWithMatchingReviewText() async throws {
        var projection = ReviewMonitorCodexChatLogProjection()
        let finalReview = "No issues found."
        let snapshot = makeCodexThreadSnapshotForTesting(
            chatID: CodexThreadID(rawValue: "review-thread"),
            turns: [
                .init(
                    id: CodexTurnID(rawValue: "turn-review"),
                    state: .completed,
                    items: [
                        .init(
                            id: "review-output",
                            kind: .exitedReviewMode,
                            content: .log(finalReview)
                        ),
                    ]
                ),
                .init(
                    id: CodexTurnID(rawValue: "ordinary-turn"),
                    state: .completed,
                    items: [
                        .init(
                            id: "ordinary-user",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "ordinary-user",
                                role: .user,
                                text: "Repeat the review result."
                            ))
                        ),
                        .init(
                            id: "ordinary-assistant",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "ordinary-assistant",
                                role: .assistant,
                                text: finalReview
                            ))
                        ),
                    ]
                ),
            ]
        )

        let document = projection.render(
            from: snapshot,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )

        #expect(document?.blocks.count == 3)
        #expect(
            document?.text
                == "\(finalReview)\n\nRepeat the review result.\n\n\(finalReview)"
        )
    }

    @Test func codexChatLogProjectionSuppressesTypedReviewRolloutCompanionWithDifferentText()
        async throws
    {
        var projection = ReviewMonitorCodexChatLogProjection()
        let turn = CodexTurnSnapshot(
            id: CodexTurnID(rawValue: "turn-review"),
            state: .completed,
            items: [
                .init(
                    id: "review-output",
                    kind: .exitedReviewMode,
                    content: .log("Review failed before producing findings.")
                ),
                .init(
                    id: "review_rollout_assistant",
                    kind: .agentMessage,
                    content: .message(.init(
                        id: "review_rollout_assistant",
                        role: .assistant,
                        text: "The review child was interrupted."
                    ))
                ),
            ]
        )

        let document = projection.render(
            from: turn,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )

        #expect(document?.blocks.count == 1)
        #expect(document?.text == "Review failed before producing findings.")
    }

    @Test func codexChatLogProjectionKeepsReviewRolloutCompanionWhenTargetIsMissing() async throws {
        var projection = ReviewMonitorCodexChatLogProjection()
        let turn = CodexTurnSnapshot(
            id: CodexTurnID(rawValue: "turn-review"),
            state: .completed,
            items: [
                .init(
                    id: "review_rollout_assistant",
                    kind: .agentMessage,
                    content: .message(.init(
                        id: "review_rollout_assistant",
                        role: .assistant,
                        text: "The review child was interrupted."
                    ))
                ),
            ]
        )

        let document = projection.render(
            from: turn,
            chatCreatedAt: nil,
            chatUpdatedAt: nil
        )

        #expect(document?.blocks.count == 1)
        #expect(document?.text == "The review child was interrupted.")

        let policyResult = ReviewRolloutPresentationPolicy().evaluate([
            .init(
                sourceID: "turn-review:agentMessage:review_rollout_assistant",
                turnID: CodexTurnID(rawValue: "turn-review"),
                kind: .agentMessage,
                origin: .reviewRolloutAssistant,
                semanticRelation: .companionOf(.exitedReviewMode),
                displayText: "The review child was interrupted."
            )
        ])
        #expect(
            policyResult.missingTargetSourceIDs
                == ["turn-review:agentMessage:review_rollout_assistant"]
        )
    }

    @Test func reviewRolloutPolicyDoesNotUseOutputFromAnEarlierReview() {
        let firstTurnID = CodexTurnID(rawValue: "first-review")
        let secondTurnID = CodexTurnID(rawValue: "second-review")
        let companionTurnID = CodexTurnID(rawValue: "second-review-companion")
        let companionSourceID = "second-review-companion:agentMessage:companion"
        let policyResult = ReviewRolloutPresentationPolicy().evaluate([
            .init(
                sourceID: "first-review:exitedReviewMode:output",
                turnID: firstTurnID,
                kind: .exitedReviewMode,
                origin: .currentV2Item,
                semanticRelation: nil,
                displayText: "No issues found."
            ),
            .init(
                sourceID: "second-review:enteredReviewMode:input",
                turnID: secondTurnID,
                kind: .enteredReviewMode,
                origin: .currentV2Item,
                semanticRelation: nil,
                displayText: "current changes"
            ),
            .init(
                sourceID: companionSourceID,
                turnID: companionTurnID,
                kind: .agentMessage,
                origin: .reviewRolloutAssistant,
                semanticRelation: .companionOf(.exitedReviewMode),
                displayText: "The second review was interrupted."
            ),
        ])

        #expect(policyResult.suppressedCompanionSourceIDs.isEmpty)
        #expect(policyResult.missingTargetSourceIDs == [companionSourceID])
        #expect(policyResult.hiddenUserMessageTurnIDs == [companionTurnID])
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
                            id: "review_rollout_assistant",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "review_rollout_assistant",
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
                            id: "review_rollout_assistant",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "review_rollout_assistant",
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

    @Test func codexChatLogProjectionKeepsDistinctReasoningItemsRegardlessOfRawPayload() async throws {
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

        #expect(document.blocks.count == 2)
        let renderedReasoning = "Summarizing files with git\n\nI need to summarize the files."
        #expect(document.text == "\(renderedReasoning)\n\n\(renderedReasoning)")
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

    @Test func codexChatLogProjectionKeepsLateDistinctReasoningBeforeCommand() async throws {
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

        #expect(mirroredDocument.blocks.count == initialDocument.blocks.count + 1)
        #expect(mirroredDocument.text != initialDocument.text)
        #expect(mirroredDocument.revision > initialDocument.revision)
    }

    @Test func codexChatLogProjectionKeepsDistinctReasoningSeparatedByCommand() async throws {
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

        #expect(document.blocks.count == 3)
        #expect(document.text == "\(reasoningText)\n\n$ /bin/zsh -lc\n\n\(reasoningText)")
    }

    @Test func codexChatLogProjectionDoesNotDecodeWrappedRawPayloadForReasoningIdentity() async throws {
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

        #expect(document.blocks.count == 2)
        #expect(document.text == "\(reasoningText)\n\n\(reasoningText)")
    }

    @Test func codexChatLogProjectionKeepsAllRepeatedReasoningItems() async throws {
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

        #expect(document.blocks.count == 4)
        #expect(document.text == Array(repeating: reasoningText, count: 4).joined(separator: "\n\n"))
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

    @Test func codexChatSourceProjectionTargetsMarkerAndRolloutPolicyChanges() throws {
        var projection = ReviewMonitorCodexChatLogSourceProjection()
        let turnID = CodexTurnID(rawValue: "turn-review-policy")
        let user = CodexThreadItem(
            id: "user-review-policy",
            kind: .userMessage,
            content: .message(.init(
                id: "user-review-policy",
                role: .user,
                text: "Review this change."
            ))
        )
        let companion = CodexThreadItem(
            id: "review_rollout_assistant",
            kind: .agentMessage,
            content: .message(.init(
                id: "review_rollout_assistant",
                role: .assistant,
                text: "No issues found."
            ))
        )
        let initialTurn = CodexTurnSnapshot(
            id: turnID,
            state: .inProgress,
            items: [user, companion]
        )
        let initial = projection.apply(.init(
            generation: 1,
            sequence: 0,
            payload: .snapshot(.init(
                thread: .init(id: "thread-review-policy", turns: [initialTurn]),
                phase: .running(turnID: turnID)
            ), reason: .initial)
        ))
        #expect(initial?.sourceDocument?.text == "Review this change.\n\nNo issues found.")

        let matchingTarget = CodexThreadItem(
            id: "review-output",
            kind: .exitedReviewMode,
            content: .log("No issues found.")
        )
        let matching = projection.apply(.init(
            generation: 1,
            sequence: 1,
            payload: .update(.itemInserted(
                item: matchingTarget,
                turnID: turnID,
                index: 1
            ))
        ))
        #expect(matching?.sourceDocument?.text == "No issues found.")
        #expect(matching?.sourceDocument?.blocks.count == 1)

        var differentTarget = matchingTarget
        differentTarget.content = .log("Review stopped before producing findings.")
        let different = projection.apply(.init(
            generation: 1,
            sequence: 2,
            payload: .update(.itemUpdated(
                item: differentTarget,
                turnID: turnID,
                index: 1
            ))
        ))
        #expect(
            different?.sourceDocument?.text == "Review stopped before producing findings."
        )

        let removed = projection.apply(.init(
            generation: 1,
            sequence: 3,
            payload: .update(.itemRemoved(.init(item: differentTarget, turnID: turnID)))
        ))
        #expect(removed?.sourceDocument?.text == "Review this change.\n\nNo issues found.")
    }

    @Test func codexChatSourceProjectionAppliesReviewThreadPolicyAcrossTurns() throws {
        var projection = ReviewMonitorCodexChatLogSourceProjection()
        let outerTurnID = CodexTurnID(rawValue: "outer-review-turn-stream")
        let innerTurnID = CodexTurnID(rawValue: "inner-review-turn-stream")
        let finalReview = "No actionable correctness issues were identified."
        let companion = CodexThreadItem(
            id: "review_rollout_assistant",
            kind: .agentMessage,
            content: .message(.init(
                id: "review_rollout_assistant",
                role: .assistant,
                text: finalReview
            ))
        )
        let thread = CodexThreadSnapshot(
            id: "review-thread-stream",
            sourceKind: .vscode,
            turns: [
                .init(
                    id: outerTurnID,
                    state: .inProgress,
                    items: [.init(
                        id: "entered-review-stream",
                        kind: .enteredReviewMode,
                        content: .log("current changes")
                    )]
                ),
                .init(
                    id: innerTurnID,
                    state: .completed,
                    items: [
                        .init(
                            id: "review-user-stream",
                            kind: .userMessage,
                            content: .message(.init(
                                id: "review-user-stream",
                                role: .user,
                                text: "Review the current code changes."
                            ))
                        ),
                        companion,
                    ]
                ),
            ]
        )
        let initial = projection.apply(.init(
            generation: 1,
            sequence: 0,
            payload: .snapshot(.init(
                thread: thread,
                phase: .running(turnID: outerTurnID)
            ), reason: .initial)
        ))
        #expect(initial?.sourceDocument?.text == "current changes\n\n\(finalReview)")

        let reviewOutput = CodexThreadItem(
            id: "review-output-stream",
            kind: .exitedReviewMode,
            content: .log(finalReview)
        )
        let completed = projection.apply(.init(
            generation: 1,
            sequence: 1,
            payload: .update(.itemInserted(
                item: reviewOutput,
                turnID: outerTurnID,
                index: 1
            ))
        ))

        let document = try #require(completed?.sourceDocument)
        #expect(document.text == "current changes\n\n\(finalReview)")
        #expect(document.blocks.count == 2)
        #expect(document.blocks.contains { $0.id.rawValue.contains("review-output-stream") })
        #expect(document.blocks.contains { $0.id.rawValue.contains("review_rollout_assistant") } == false)
    }

    @Test func codexChatSourceProjectionKeepsNormalizedCompanionSuppressedAfterTurnMove()
        throws
    {
        var projection = ReviewMonitorCodexChatLogSourceProjection()
        let outerTurnID = CodexTurnID(rawValue: "outer-review-turn-move")
        let interveningTurnID = CodexTurnID(rawValue: "intervening-turn-move")
        let companionTurnID = CodexTurnID(rawValue: "companion-turn-move")
        let reviewOutput = "No actionable issues were identified."
        let outerTurn = CodexTurnSnapshot(
            id: outerTurnID,
            state: .completed,
            items: [.init(
                id: "review-output-move",
                kind: .exitedReviewMode,
                content: .log(reviewOutput)
            )]
        )
        let interveningTurn = CodexTurnSnapshot(
            id: interveningTurnID,
            state: .completed,
            items: [.init(
                id: "intervening-message-move",
                kind: .agentMessage,
                content: .message(.init(
                    id: "intervening-message-move",
                    role: .assistant,
                    text: "Intervening output"
                ))
            )]
        )
        let companionTurn = CodexTurnSnapshot(
            id: companionTurnID,
            state: .completed,
            items: [
                .init(
                    id: "review-user-move-1",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "review-user-move-1",
                        role: .user,
                        text: "Review the current changes."
                    ))
                ),
                .init(
                    id: "review-user-move-2",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "review-user-move-2",
                        role: .user,
                        text: "Review the current changes."
                    ))
                ),
                .init(
                    id: "review_rollout_assistant",
                    kind: .agentMessage,
                    content: .message(.init(
                        id: "review_rollout_assistant",
                        role: .assistant,
                        text: "Review was interrupted."
                    ))
                ),
            ]
        )
        let initial = projection.apply(.init(
            generation: 1,
            sequence: 0,
            payload: .snapshot(.init(
                thread: .init(
                    id: "thread-review-turn-move",
                    turns: [outerTurn, interveningTurn, companionTurn]
                ),
                phase: .terminal(turnID: companionTurnID, disposition: .completed)
            ), reason: .initial)
        ))
        #expect(initial?.sourceDocument?.text == "\(reviewOutput)\n\nIntervening output")

        let moved = projection.apply(.init(
            generation: 1,
            sequence: 1,
            payload: .update(.turnUpdated(interveningTurn, index: 2))
        ))

        #expect(moved?.sourceDocument?.text == "\(reviewOutput)\n\nIntervening output")
    }

    @Test func codexChatSourceProjectionKeepsNormalizedCompanionSuppressedAcrossStructuralChanges()
        throws
    {
        var projection = ReviewMonitorCodexChatLogSourceProjection()
        let outerTurnID = CodexTurnID(rawValue: "outer-review-structural-change")
        let companionTurnID = CodexTurnID(rawValue: "companion-review-structural-change")
        let interveningTurnID = CodexTurnID(rawValue: "intervening-review-structural-change")
        let reviewOutput = "No actionable issues were identified."
        let outerTurn = CodexTurnSnapshot(
            id: outerTurnID,
            state: .completed,
            items: [.init(
                id: "review-output-structural-change",
                kind: .exitedReviewMode,
                content: .log(reviewOutput)
            )]
        )
        let companionTurn = CodexTurnSnapshot(
            id: companionTurnID,
            state: .completed,
            items: [
                .init(
                    id: "review-user-structural-change-1",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "review-user-structural-change-1",
                        role: .user,
                        text: "Review the current changes."
                    ))
                ),
                .init(
                    id: "review-user-structural-change-2",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "review-user-structural-change-2",
                        role: .user,
                        text: "Review the current changes."
                    ))
                ),
                .init(
                    id: "review_rollout_assistant",
                    kind: .agentMessage,
                    content: .message(.init(
                        id: "review_rollout_assistant",
                        role: .assistant,
                        text: "Review was interrupted."
                    ))
                ),
            ]
        )
        let initial = projection.apply(.init(
            generation: 1,
            sequence: 0,
            payload: .snapshot(.init(
                thread: .init(
                    id: "thread-review-structural-change",
                    turns: [outerTurn, companionTurn]
                ),
                phase: .terminal(turnID: companionTurnID, disposition: .completed)
            ), reason: .initial)
        ))
        #expect(initial?.sourceDocument?.text == reviewOutput)

        let interveningTurn = CodexTurnSnapshot(
            id: interveningTurnID,
            state: .completed,
            items: [.init(
                id: "command-structural-change",
                kind: .commandExecution,
                content: .command(.init(
                    command: "/usr/bin/true",
                    exitCode: 0,
                    status: .completed
                ))
            )]
        )
        let inserted = projection.apply(.init(
            generation: 1,
            sequence: 1,
            payload: .update(.turnInserted(interveningTurn, index: 1))
        ))
        #expect(inserted?.sourceDocument?.text == "\(reviewOutput)\n\n$ /usr/bin/true")

        let removed = projection.apply(.init(
            generation: 1,
            sequence: 2,
            payload: .update(.turnRemoved(id: interveningTurnID))
        ))
        #expect(removed?.sourceDocument?.text == reviewOutput)
    }

    @Test func codexChatSourceProjectionKeepsNormalizedCompanionSuppressedAfterTextAppend()
        throws
    {
        var projection = ReviewMonitorCodexChatLogSourceProjection()
        let outerTurnID = CodexTurnID(rawValue: "outer-review-text-append")
        let companionTurnID = CodexTurnID(rawValue: "companion-review-text-append")
        let reviewOutput = "No actionable issues were identified."
        let companion = CodexThreadItem(
            id: "review_rollout_assistant",
            kind: .agentMessage,
            content: .message(.init(
                id: "review_rollout_assistant",
                role: .assistant,
                text: "No actionable issues were"
            ))
        )
        let thread = CodexThreadSnapshot(
            id: "thread-review-text-append",
            turns: [
                .init(
                    id: outerTurnID,
                    state: .completed,
                    items: [.init(
                        id: "review-output-append",
                        kind: .exitedReviewMode,
                        content: .log(reviewOutput)
                    )]
                ),
                .init(
                    id: companionTurnID,
                    state: .inProgress,
                    items: [
                .init(
                    id: "review-user-append-1",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "review-user-append-1",
                        role: .user,
                        text: "Review the current changes."
                    ))
                ),
                .init(
                    id: "review-user-append-2",
                    kind: .userMessage,
                    content: .message(.init(
                        id: "review-user-append-2",
                        role: .user,
                        text: "Review the current changes."
                    ))
                        ),
                        companion,
                    ]
                ),
            ]
        )
        let initial = projection.apply(.init(
            generation: 1,
            sequence: 0,
            payload: .snapshot(.init(
                thread: thread,
                phase: .running(turnID: companionTurnID)
            ), reason: .initial)
        ))
        #expect(initial?.sourceDocument?.text == reviewOutput)
        #expect(initial?.sourceDocument?.blocks.count == 1)

        let completed = projection.apply(.init(
            generation: 1,
            sequence: 1,
            payload: .update(.itemTextAppended(
                .init(item: companion, turnID: companionTurnID),
                delta: " identified."
            ))
        ))

        #expect(completed?.sourceDocument?.text == reviewOutput)
        #expect(completed?.sourceDocument?.blocks.count == 1)
    }

    @Test func codexChatSourceProjectionAppliesPhaseOnlyToStatusDependentBlocks() throws {
        var projection = ReviewMonitorCodexChatLogSourceProjection()
        let turnID = CodexTurnID(rawValue: "turn-phase")
        let command = CodexThreadItem(
            id: "command-phase",
            kind: .commandExecution,
            content: .command(.init(command: "/usr/bin/true"))
        )
        let message = CodexThreadItem(
            id: "message-phase",
            kind: .agentMessage,
            content: .message(.init(
                id: "message-phase",
                role: .assistant,
                text: "Still visible"
            ))
        )
        let thread = CodexThreadSnapshot(
            id: "thread-phase",
            status: .active(activeFlags: []),
            turns: [.init(id: turnID, state: .inProgress, items: [command, message])]
        )
        _ = projection.apply(.init(
            generation: 1,
            sequence: 0,
            payload: .snapshot(.init(
                thread: thread,
                phase: .running(turnID: turnID)
            ), reason: .initial)
        ))

        let threadStatus = projection.apply(.init(
            generation: 1,
            sequence: 1,
            payload: .update(.statusChanged(.idle))
        ))
        let unchangedCommand = try #require(
            threadStatus?.sourceDocument?.blocks.first { $0.kind == .command }
        )
        #expect(unchangedCommand.metadata?.status == CodexTurnStatus.inProgress.rawValue)

        let terminalPhase = projection.apply(.init(
            generation: 1,
            sequence: 2,
            payload: .update(.phaseChanged(.terminal(
                turnID: turnID,
                disposition: .failed
            )))
        ))
        let failedCommand = try #require(
            terminalPhase?.sourceDocument?.blocks.first { $0.kind == .command }
        )
        #expect(failedCommand.metadata?.status == CodexTurnStatus.failed.rawValue)
        #expect(terminalPhase?.sourceDocument?.text.contains("Still visible") == true)
    }

    @Test func codexChatSourceProjectionTargetsInsertedAndRemovedTurns() throws {
        var projection = ReviewMonitorCodexChatLogSourceProjection()
        let firstTurnID = CodexTurnID(rawValue: "turn-first-targeted")
        let secondTurnID = CodexTurnID(rawValue: "turn-second-targeted")
        let first = CodexTurnSnapshot(
            id: firstTurnID,
            state: .completed,
            items: [.init(
                id: "first-targeted",
                kind: .agentMessage,
                content: .message(.init(
                    id: "first-targeted",
                    role: .assistant,
                    text: "First"
                ))
            )]
        )
        _ = projection.apply(.init(
            generation: 1,
            sequence: 0,
            payload: .snapshot(.init(
                thread: .init(id: "thread-targeted-turns", turns: [first]),
                phase: .terminal(turnID: firstTurnID, disposition: .completed)
            ), reason: .initial)
        ))

        let second = CodexTurnSnapshot(
            id: secondTurnID,
            state: .completed,
            items: [.init(
                id: "second-targeted",
                kind: .agentMessage,
                content: .message(.init(
                    id: "second-targeted",
                    role: .assistant,
                    text: "Second"
                ))
            )]
        )
        let inserted = projection.apply(.init(
            generation: 1,
            sequence: 1,
            payload: .update(.turnInserted(second, index: 1))
        ))
        #expect(inserted?.sourceDocument?.text == "First\n\nSecond")

        let removed = projection.apply(.init(
            generation: 1,
            sequence: 2,
            payload: .update(.turnRemoved(id: firstTurnID))
        ))
        #expect(removed?.sourceDocument?.text == "Second")
    }

    @Test func codexChatRendersThreadAndLiveUpdates() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let modelContext = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueThreadResume(try makeChatDetailStoredThread(id: "chat-thread"))
        try await runtime.transport.enqueueThreadRead(
            try makeChatDetailStoredThread(
                id: "chat-thread",
                turnID: "turn-1",
                state: .inProgress,
                messageID: "message-1",
                message: "Generic chat snapshot",
                phase: .finalAnswer
            )
        )

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

        try await runtime.notificationEmitter.emitItemCompleted(
            threadID: "chat-thread",
            turnID: "turn-1",
            item: .agentMessage(
                id: "message-1",
                text: "Generic chat stream update",
                phase: .finalAnswer
            )
        )

        let updatedSnapshot = try await awaitTransportRender(
            transport,
            expectedSelection: .chat("chat-thread")
        ) { snapshot in
            snapshot.log.contains("Generic chat stream update")
        }
        #expect(updatedSnapshot.log.contains("Generic chat snapshot") == false)
        #expect(await runtime.transport.recordedRequests(for: .threadResume).count == 1)
    }

    private func selectChat(
        id: String,
        in uiState: ReviewMonitorUIState
    ) {
        let chatID = CodexThreadID(rawValue: id)
        uiState.selection = .chat(chatID)
    }

    private func rawPayload(type: String) -> Data {
        Data("{\"type\":\"\(type)\"}".utf8)
    }
}

private func makeChatDetailStoredThread(
    id: CodexThreadID,
    turns: [CodexAppServerTestTurn] = []
) throws -> CodexAppServerTestStoredThread {
    let workspace = URL(
        fileURLWithPath: "/tmp/\(id.rawValue)",
        isDirectory: true
    )
    return try .init(
        snapshot: .init(
            id: id,
            workspace: workspace,
            preview: id.rawValue,
            modelProvider: "openai",
            sourceKind: .appServer,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            status: .idle,
            ephemeral: false,
            turns: turns.map(\.snapshot)
        ),
        turns: turns,
        metadata: .init(
            sessionID: "chat-detail-\(id.rawValue)",
            cliVersion: "review-ui-tests",
            source: .appServer
        ),
        runtimeMetadata: .init(
            model: "gpt-5",
            modelProvider: "openai",
            serviceTier: nil,
            cwd: workspace,
            runtimeWorkspaceRoots: [workspace],
            instructionSources: [],
            approvalPolicy: .never,
            approvalsReviewer: .user,
            sandbox: .dangerFullAccess,
            activePermissionProfile: nil,
            reasoningEffort: nil,
            multiAgentMode: .explicitRequestOnly
        ),
        isArchived: false
    )
}

private func makeChatDetailTurn(
    id: CodexTurnID,
    state: CodexTurnSnapshot.State,
    items: [CodexAppServerTestItem]
) throws -> CodexAppServerTestTurn {
    try .init(
        snapshot: .init(
            id: id,
            state: state,
            items: items.map(\.domainProjection)
        ),
        items: items
    )
}

private func makeChatDetailStoredThread(
    id: CodexThreadID,
    turnID: CodexTurnID,
    state: CodexTurnSnapshot.State,
    messageID: String,
    message: String,
    phase: CodexMessagePhase? = nil
) throws -> CodexAppServerTestStoredThread {
    let item = try CodexAppServerTestItem.agentMessage(
        id: messageID,
        text: message,
        phase: phase
    )
    let turn = try makeChatDetailTurn(
        id: turnID,
        state: state,
        items: [item]
    )
    return try makeChatDetailStoredThread(id: id, turns: [turn])
}
