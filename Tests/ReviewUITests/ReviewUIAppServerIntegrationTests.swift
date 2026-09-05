import AppKit
import Foundation
import Synchronization
import Testing
@_spi(Testing) @testable import CodexReview
@testable import CodexReviewAppServer
import CodexReviewTesting
@_spi(PreviewSupport) @testable import ReviewUI

@MainActor
extension ReviewUITests {
    @Test func unsupportedAppServerItemsStayOutOfRenderedReview() async throws {
        let transport = FakeJSONRPCTransport()
        let diagnostics = ReviewUIIngestionDiagnosticCapture()
        try await transport.enqueue(
            AppServerAPI.Initialize.Response(codexHome: "/tmp/codex"),
            for: "initialize"
        )
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-review", model: "gpt-5"),
            for: "thread/start"
        )
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turnID: "turn-review"),
            for: "turn/start"
        )
        try await transport.enqueue(
            AppServerAPI.Thread.Unsubscribe.Response(status: .unsubscribed),
            for: "thread/unsubscribe"
        )
        let backend = AppServerCodexReviewBackend(
            client: .init(transport: transport),
            ingestionDiagnosticRecorder: diagnostics
        )
        let store = CodexReviewStore.makeTestingStore(
            backend: ReviewUIAppServerStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        let review = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        try await withReviewUIAppServerCleanup(
            store: store,
            backend: backend,
            transport: transport,
            reviewTask: review
        ) {
            try #require(await StoreSnapshotProbe(store: store).waitUntil { snapshot in
                snapshot.job("job-1")?.activeRun?.turnID == "turn-review"
            } != nil)
            let job = try #require(store.job(id: "job-1"))
            let harness = makeWindowHarness(store: store)
            defer { harness.window.close() }
            let contentPane = harness.viewController.transportViewControllerForTesting
            harness.viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
            _ = try await awaitTransportRender(contentPane)

            let unsupportedNotifications = [
                ReviewUIAppServerNotification(
                    method: "item/started",
                    params: .init(
                        threadID: "thread-review",
                        turnID: "turn-review",
                        item: .init(type: "futureItem", id: "future-1")
                    )
                ),
                ReviewUIAppServerNotification(
                    method: "item/completed",
                    params: .init(
                        threadID: "thread-review",
                        turnID: "turn-review",
                        item: .init(type: "futureItem", id: "future-1")
                    )
                ),
            ]
            for notification in unsupportedNotifications {
                try await transport.emitServerNotification(
                    method: notification.method,
                    params: notification.params
                )
            }
            try await transport.emitServerNotification(
                method: "item/started",
                params: ReviewUIV2ItemNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    item: .command(id: "command-1", status: "inProgress")
                )
            )
            try await transport.emitServerNotification(
                method: "item/commandExecution/outputDelta",
                params: ReviewUIV2DeltaNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    itemID: "command-1",
                    delta: "ordinary command output"
                )
            )
            try await transport.emitServerNotification(
                method: "item/completed",
                params: ReviewUIV2ItemNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    item: .command(id: "command-1", status: "completed", exitCode: 0)
                )
            )
            try await transport.emitServerNotification(
                method: "item/completed",
                params: ReviewUIV2ItemNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    item: .init(
                        type: "agentMessage",
                        id: "ordinary-log",
                        text: "Ordinary log after unsupported items."
                    )
                )
            )
            for method in ["item/started", "item/completed"] {
                try await transport.emitServerNotification(
                    method: method,
                    params: ReviewUIV2ItemNotification(
                        threadID: "thread-review",
                        turnID: "turn-review",
                        item: .init(
                            type: "exitedReviewMode",
                            id: "review-result",
                            review: "Final review"
                        )
                    )
                )
            }
            try await transport.emitServerNotification(
                method: "turn/completed",
                params: ReviewUIV2TurnNotification(
                    threadID: "thread-review",
                    turn: .init(
                        id: "turn-review",
                        items: [],
                        itemsView: "notLoaded",
                        status: "completed"
                    )
                )
            )

            let result = try await review.value
            let rendered = try await awaitTransportRender(contentPane) { snapshot in
                snapshot.log.contains("Ordinary log after unsupported items.")
                    && snapshot.log.contains("Final review")
            }

            #expect(result.core.lifecycle.status == .succeeded)
            #expect(result.core.lifecycle.terminal == .completed)
            #expect(result.core.output.hasFinalReview)
            #expect(result.core.output.lastAgentMessage == "Final review")
            #expect(job.logEntries.contains { $0.kind == .error } == false)
            #expect(job.logEntries.contains { $0.text.contains("ordinary command output") })
            #expect(rendered.log.contains("Ran swift test"))
            #expect(rendered.log.contains("Ordinary log after unsupported items."))
            #expect(rendered.log.contains("Final review"))
            #expect(rendered.log.contains("Unsupported app-server") == false)
            #expect(rendered.log.contains("Malformed app-server notification") == false)
            #expect(contentPane.logCommandOutputPanelCountForTesting == 1)
            #expect(contentPane.clickFirstLogCommandOutputPanelHeaderForTesting())
            await awaitNativeLayoutTurn()
            #expect(contentPane.logCommandOutputPanelTerminalTextForTesting?
                .contains("ordinary command output") == true)

            let capturedDiagnostics = diagnostics.snapshot()
            #expect(capturedDiagnostics.count == unsupportedNotifications.count)
            for (diagnostic, notification) in zip(capturedDiagnostics, unsupportedNotifications) {
                #expect(diagnostic.method == notification.method)
                #expect(diagnostic.threadID == "thread-review")
                #expect(diagnostic.turnID == "turn-review")
                #expect(diagnostic.itemType == "futureItem")
                #expect(diagnostic.disposition == .ignored)
                #expect(try canonicalJSON(diagnostic.rawParams) == canonicalJSON(
                    JSONEncoder().encode(notification.params)
                ))
            }
            let requestMethods = await transport.recordedRequests().map(\.method)
            #expect(requestMethods.contains("thread/backgroundTerminals/clean"))
            #expect(requestMethods.contains("thread/unsubscribe"))
            #expect(requestMethods.contains("thread/delete"))
        }
        #expect(await transport.isClosedForTesting())
        #expect(await backend.reviewEventSessionCountForTesting() == 0)
        #expect(await backend.notificationRouterIsRunningForTesting() == false)
    }

    @Test func normalReviewTurnRendersCommentaryCommandsAndFinalAnswer() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(
            AppServerAPI.Initialize.Response(codexHome: "/tmp/Codex Review #1 (QA)"),
            for: "initialize"
        )
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-review", model: "gpt-5"),
            for: "thread/start"
        )
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turnID: "turn-review"),
            for: "turn/start"
        )
        try await transport.enqueue(
            AppServerAPI.Thread.Unsubscribe.Response(status: .unsubscribed),
            for: "thread/unsubscribe"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let store = CodexReviewStore.makeTestingStore(
            backend: ReviewUIAppServerStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        let review = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }

        try await withReviewUIAppServerCleanup(
            store: store,
            backend: backend,
            transport: transport,
            reviewTask: review
        ) {
            try #require(await StoreSnapshotProbe(store: store).waitUntil { snapshot in
                snapshot.job("job-1")?.activeRun?.turnID == "turn-review"
            } != nil)
            let job = try #require(store.job(id: "job-1"))
            let harness = makeWindowHarness(
                store: store,
                contentSize: NSSize(width: 860, height: 900)
            )
            defer { harness.window.close() }
            let contentPane = harness.viewController.transportViewControllerForTesting
            harness.viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
            _ = try await awaitTransportRender(contentPane)
            contentPane.setLogReduceMotionForTesting(false)

            try await transport.emitServerNotification(
                method: "item/started",
                params: ReviewUIV2ItemNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    item: .init(
                        type: "agentMessage",
                        id: "commentary",
                        text: "",
                        phase: "commentary"
                    )
                )
            )
            try await transport.emitServerNotification(
                method: "item/agentMessage/delta",
                params: ReviewUIV2DeltaNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    itemID: "commentary",
                    delta: "Inspecting repository "
                )
            )
            try await transport.emitServerNotification(
                method: "item/agentMessage/delta",
                params: ReviewUIV2DeltaNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    itemID: "commentary",
                    delta: "instructions and diff."
                )
            )
            let streamedCommentary = try await awaitTransportRender(contentPane) { snapshot in
                snapshot.log.contains("Inspecting repository instructions and diff.")
            }
            #expect(streamedCommentary.log.contains(
                "Inspecting repository instructions and diff."
            ))
            #expect(job.core.output.lastAgentMessage ==
                "Inspecting repository instructions and diff.")
            try await transport.emitServerNotification(
                method: "item/completed",
                params: ReviewUIV2ItemNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    item: .init(
                        type: "agentMessage",
                        id: "commentary",
                        text: "Inspecting repository instructions and diff.",
                        phase: "commentary"
                    )
                )
            )
            try await transport.emitServerNotification(
                method: "item/started",
                params: ReviewUIV2ItemNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    item: .init(
                        type: "reasoning",
                        id: "reasoning-1",
                        summary: [],
                        content: []
                    )
                )
            )
            try await transport.emitServerNotification(
                method: "item/reasoning/summaryTextDelta",
                params: ReviewUIV2DeltaNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    itemID: "reasoning-1",
                    delta: "Analyzing review ",
                    summaryIndex: 0
                )
            )
            try await transport.emitServerNotification(
                method: "item/completed",
                params: ReviewUIV2ItemNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    item: .init(
                        type: "reasoning",
                        id: "reasoning-1",
                        summary: ["Analyzing review contracts."],
                        content: []
                    )
                )
            )
            let streamedReasoning = try await awaitTransportRender(contentPane) { snapshot in
                snapshot.log.contains("Analyzing review contracts.")
            }
            #expect(streamedReasoning.log.contains("Analyzing review contracts."))
            #expect(contentPane.logWordGlowCountForTesting > 0)
            let completionSuffixRange = (streamedReasoning.log as NSString).range(
                of: "contracts."
            )
            #expect(completionSuffixRange.location != NSNotFound)
            #expect(contentPane.logWordGlowRangesForTesting.contains {
                NSIntersectionRange($0, completionSuffixRange).length
                    == completionSuffixRange.length
            })
            contentPane.completeLogWordGlowAnimationsForTesting()
            #expect(contentPane.logWordGlowCountForTesting == 0)
            try await transport.emitServerNotification(
                method: "item/started",
                params: ReviewUIV2ItemNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    item: .command(
                        id: "command-1",
                        status: "inProgress",
                        commandActions: [
                            ["type": "read", "command": "cat Sources/App.swift", "name": "App.swift", "path": "Sources/App.swift"],
                            ["type": "search", "command": "rg lifecycle", "query": "lifecycle", "path": "Sources"],
                            ["type": "listFiles", "command": "rg --files Sources", "path": "Sources"],
                            ["type": "unknown", "command": "swift test"],
                        ]
                    )
                )
            )
            try await transport.emitServerNotification(
                method: "item/started",
                params: ReviewUIV2ItemNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    item: .init(
                        type: "mcpToolCall",
                        id: "tool-1",
                        status: "inProgress",
                        arguments: [:],
                        server: "codex_review",
                        tool: "review_read"
                    )
                )
            )
            try await transport.emitServerNotification(
                method: "item/started",
                params: ReviewUIV2ItemNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    item: .command(
                        id: "command-2",
                        status: "inProgress",
                        command: "git diff"
                    )
                )
            )
            try await transport.emitServerNotification(
                method: "item/mcpToolCall/progress",
                params: ReviewUIV2MessageNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    itemID: "tool-1",
                    message: "Reading review job."
                )
            )
            try await transport.emitServerNotification(
                method: "item/commandExecution/outputDelta",
                params: ReviewUIV2DeltaNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    itemID: "command-1",
                    delta: "All tests passed."
                )
            )
            try await transport.emitServerNotification(
                method: "item/completed",
                params: ReviewUIV2ItemNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    item: .init(
                        type: "mcpToolCall",
                        id: "tool-1",
                        status: "completed",
                        arguments: [:],
                        server: "codex_review",
                        tool: "review_read",
                        result: "Review state loaded."
                    )
                )
            )
            try await transport.emitServerNotification(
                method: "item/commandExecution/outputDelta",
                params: ReviewUIV2DeltaNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    itemID: "command-2",
                    delta: "README.md | 1 +"
                )
            )
            try await transport.emitServerNotification(
                method: "item/completed",
                params: ReviewUIV2ItemNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    item: .command(
                        id: "command-2",
                        status: "failed",
                        command: "git diff",
                        exitCode: 1
                    )
                )
            )
            try await transport.emitServerNotification(
                method: "item/completed",
                params: ReviewUIV2ItemNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    item: .command(id: "command-1", status: "completed", exitCode: 0)
                )
            )
            _ = try await awaitTransportRender(contentPane) { snapshot in
                snapshot.log.contains("codex_review.review_read completed.")
                    && snapshot.log.contains("Ran git diff")
            }
            contentPane.completeLogWordGlowAnimationsForTesting()
            let wordFadeInvalidationCountBeforeFinalAnswer =
                contentPane.logWordFadeDisplayInvalidationCountForTesting
            for method in ["item/started", "item/completed"] {
                try await transport.emitServerNotification(
                    method: method,
                    params: ReviewUIV2ItemNotification(
                        threadID: "thread-review",
                        turnID: "turn-review",
                        item: .init(
                            type: "agentMessage",
                            id: "final",
                            text: "No findings.",
                            phase: "final_answer"
                        )
                    )
                )
            }
            let renderedFinalAnswer = try await awaitTransportRender(contentPane) { snapshot in
                snapshot.log.contains("No findings.")
            }
            let finalAnswerRange = (renderedFinalAnswer.log as NSString).range(of: "No findings.")
            #expect(finalAnswerRange.location != NSNotFound)
            #expect(contentPane.logWordFadeDisplayInvalidationCountForTesting
                > wordFadeInvalidationCountBeforeFinalAnswer)
            contentPane.completeLogWordGlowAnimationsForTesting()
            try await transport.emitServerNotification(
                method: "turn/completed",
                params: ReviewUIV2TurnNotification(
                    threadID: "thread-review",
                    turn: .init(
                        id: "turn-review",
                        items: [.init(
                            type: "agentMessage",
                            id: "final",
                            text: "No findings.",
                            phase: "final_answer"
                        )],
                        itemsView: "summary",
                        status: "completed"
                    )
                )
            )

            let result = try await review.value
            let rendered = try await awaitTransportRender(contentPane)

            #expect(result.core.lifecycle.status == .succeeded)
            #expect(result.core.output.lastAgentMessage == "No findings.")
            #expect(rendered.log.contains("Inspecting repository instructions and diff."))
            #expect(rendered.log.contains("Analyzing review contracts."))
            #expect(rendered.log.contains("Explored"))
            #expect(rendered.log.contains("Ran git diff"))
            #expect(rendered.log.contains("codex_review.review_read completed."))
            #expect(rendered.log.contains("codex_review.review_read started.") == false)
            #expect(rendered.log.contains("No findings."))
            #expect(job.logEntries.contains {
                $0.kind == .commandOutput && $0.text.contains("All tests passed.")
            })
            #expect(job.logEntries.contains {
                $0.text == "Inspecting repository instructions and diff."
                    && $0.metadata?.agentMessagePhase == .commentary
            })
            #expect(job.logEntries.contains {
                $0.text == "No findings."
                    && $0.metadata?.sourceType == "canonicalReviewResult"
                    && $0.metadata?.agentMessagePhase == .finalAnswer
            })
            #expect(job.logEntries.filter {
                $0.groupID == "final"
                    && $0.metadata?.sourceType == "canonicalReviewResult"
            }.count == 1)

            let turnStart = try #require(
                await transport.recordedRequests().first { $0.method == "turn/start" }
            )
            let turnStartParams = try JSONDecoder().decode(
                AppServerAPI.Turn.Start.Params.self,
                from: turnStart.params
            )
            #expect(turnStartParams.cwd == "/tmp/project")
            #expect(turnStartParams.input == [
                .skill(
                    name: "review-agent",
                    path: "/tmp/Codex Review #1 (QA)/skills/.system/review-agent/SKILL.md"
                ),
                .text(
                    "Review the current code changes (staged, unstaged, and untracked files)."
                ),
            ])

            #expect(contentPane.logCommandOutputPanelCountForTesting == 2)
            let firstCommandID = ReviewMonitorLog.BlockID("commandOutput:command-1")
            let secondCommandID = ReviewMonitorLog.BlockID("commandOutput:command-2")
            #expect(contentPane.clickLogCommandOutputPanelHeaderForTesting(blockID: firstCommandID))
            #expect(contentPane.clickLogCommandOutputPanelHeaderForTesting(blockID: secondCommandID))
            await awaitNativeLayoutTurn()
            #expect(contentPane.logCommandOutputPanelTerminalTextForTesting(blockID: firstCommandID)?
                .contains("All tests passed.") == true)
            #expect(contentPane.logCommandOutputPanelTerminalTextForTesting(blockID: firstCommandID)?
                .contains("README.md | 1 +") == false)
            #expect(contentPane.logCommandOutputPanelTerminalTextForTesting(blockID: secondCommandID)?
                .contains("README.md | 1 +") == true)
            #expect(contentPane.logCommandOutputPanelTerminalTextForTesting(blockID: secondCommandID)?
                .contains("All tests passed.") == false)
            let expandedLog = contentPane.displayedLogForTesting
            for child in [
                "Read App.swift",
                "Searched lifecycle in Sources",
                "Listed Sources",
                "Ran swift test",
            ] {
                #expect(expandedLog.contains(child))
                #expect(contentPane.logAccessibilityValueForTesting?.contains(child) == true)
                #expect(contentPane.logFindStringForTesting.contains(child))
            }
            let childSelection = (contentPane.logFindStringForTesting as NSString)
                .range(of: "Read App.swift")
            try #require(childSelection.location != NSNotFound)
            contentPane.setSelectedLogRangeForTesting(childSelection)
            #expect(contentPane.logSelectedTextForTesting == "Read App.swift")
            #expect(contentPane.logWordGlowCountForTesting == 0)
        }
        #expect(await transport.isClosedForTesting())
        #expect(await backend.reviewEventSessionCountForTesting() == 0)
    }

    @Test func appServerUIHarnessCleansUpAfterThrownTestBody() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(
            AppServerAPI.Initialize.Response(codexHome: "/tmp/codex"),
            for: "initialize"
        )
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-review", model: "gpt-5"),
            for: "thread/start"
        )
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turnID: "turn-review"),
            for: "turn/start"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(
            AppServerAPI.Thread.Unsubscribe.Response(status: .unsubscribed),
            for: "thread/unsubscribe"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let store = CodexReviewStore.makeTestingStore(
            backend: ReviewUIAppServerStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        let review = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }

        do {
            try await withReviewUIAppServerCleanup(
                store: store,
                backend: backend,
                transport: transport,
                reviewTask: review
            ) {
                try #require(await StoreSnapshotProbe(store: store).waitUntil { snapshot in
                    snapshot.job("job-1")?.activeRun?.turnID == "turn-review"
                } != nil)
                throw ReviewUIAppServerIntegrationError.injected
            }
            Issue.record("Expected the injected test-body failure.")
        } catch ReviewUIAppServerIntegrationError.injected {}

        let requestMethods = await transport.recordedRequests().map(\.method)
        #expect(requestMethods.contains("thread/backgroundTerminals/clean"))
        #expect(requestMethods.contains("thread/unsubscribe"))
        #expect(requestMethods.contains("thread/delete"))
        let interruptRequest = try #require(
            await transport.recordedRequests().first { $0.method == "turn/interrupt" }
        )
        let interruptParams = try JSONDecoder().decode(
            AppServerAPI.Turn.Interrupt.Params.self,
            from: interruptRequest.params
        )
        #expect(interruptParams.threadID == "thread-review")
        #expect(interruptParams.turnID == "turn-review")
        #expect(await transport.isClosedForTesting())
        #expect(store.reviewWorkerTasks["job-1"] == nil)
        #expect(await backend.reviewEventSessionCountForTesting() == 0)
        #expect(await backend.notificationRouterIsRunningForTesting() == false)
    }

    @Test func sidebarCancellationHidesCompletedUpstreamArtifactsAndRendersTerminalState() async throws {
        let transport = FakeJSONRPCTransport()
        let interruptResponseGate = AsyncGate()
        try await transport.enqueue(
            AppServerAPI.Initialize.Response(codexHome: "/tmp/codex"),
            for: "initialize"
        )
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-review", model: "gpt-5"),
            for: "thread/start"
        )
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turnID: "turn-review"),
            for: "turn/start"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        await transport.hold(method: "turn/interrupt", gate: interruptResponseGate)
        try await transport.enqueue(
            AppServerAPI.Thread.Unsubscribe.Response(status: .unsubscribed),
            for: "thread/unsubscribe"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let store = CodexReviewStore.makeTestingStore(
            backend: ReviewUIAppServerStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        let review = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }

        try await withReviewUIAppServerCleanup(
            store: store,
            backend: backend,
            transport: transport,
            reviewTask: review
        ) {
            try #require(await StoreSnapshotProbe(store: store).waitUntil { snapshot in
                snapshot.job("job-1")?.activeRun?.turnID == "turn-review"
            } != nil)
            let job = try #require(store.job(id: "job-1"))
            guard case .active(let activeAttempt) = store.reviewAttemptOwnerships[job.id] else {
                Issue.record("Expected an active review attempt")
                return
            }
            let admission = activeAttempt.admission
            let harness = makeWindowHarness(store: store)
            defer { harness.window.close() }
            let sidebar = harness.viewController.sidebarViewControllerForTesting
            let contentPane = harness.viewController.transportViewControllerForTesting
            sidebar.selectJobForTesting(job)
            _ = try await awaitTransportRender(contentPane)

            try await transport.emitServerNotification(
                method: "item/completed",
                params: ReviewUIV2ItemNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    item: .init(
                        type: "agentMessage",
                        id: "partial-review",
                        text: "Partial review before cancellation."
                    )
                )
            )
            _ = try await awaitTransportRender(contentPane) { snapshot in
                snapshot.log.contains("Partial review before cancellation.")
            }
            try await transport.emitServerNotification(
                method: "item/started",
                params: ReviewUIV2ItemNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    item: .command(id: "active-command", status: "inProgress")
                )
            )
            _ = try await awaitTransportRender(contentPane) { snapshot in
                snapshot.log.contains("swift test")
            }

            var cancellationActionWasAvailable = false
            var cancellationActionWasSent = false
            sidebar.presentContextMenuForTesting(for: job) { menu in
                guard let item = menu.items.first,
                      item.title == "Cancel",
                      item.isEnabled,
                      let action = item.action
                else {
                    return
                }
                cancellationActionWasAvailable = true
                cancellationActionWasSent = NSApplication.shared.sendAction(
                    action,
                    to: item.target,
                    from: item
                )
            }
            #expect(cancellationActionWasAvailable)
            #expect(cancellationActionWasSent)

            try await withTestTimeout {
                while await transport.recordedRequests().contains(where: {
                    $0.method == "turn/interrupt"
                }) == false {
                    try Task.checkCancellation()
                    await Task.yield()
                }
            }
            let interruptRequest = try #require(
                await transport.recordedRequests().first { $0.method == "turn/interrupt" }
            )
            let interruptParams = try JSONDecoder().decode(
                AppServerAPI.Turn.Interrupt.Params.self,
                from: interruptRequest.params
            )
            #expect(interruptParams.threadID == "thread-review")
            #expect(interruptParams.turnID == "turn-review")
            await interruptResponseGate.open()
            try await withTestTimeout {
                while true {
                    if case .interrupting(_, _, .acknowledged) = await admission.currentPhase() {
                        return
                    }
                    try Task.checkCancellation()
                    await Task.yield()
                }
            }

            let reviewExitArtifact = "Reviewer failed to output a response."
            let companionArtifact =
                "Review was interrupted. Please re-run /review and wait for it to complete."
            for method in ["item/started", "item/completed"] {
                try await transport.emitServerNotification(
                    method: method,
                    params: ReviewUIV2ItemNotification(
                        threadID: "thread-review",
                        turnID: "turn-review",
                        item: .init(
                            type: "exitedReviewMode",
                            id: "review-exit",
                            review: reviewExitArtifact
                        )
                    )
                )
            }
            for method in ["item/started", "item/completed"] {
                try await transport.emitServerNotification(
                    method: method,
                    params: ReviewUIV2ItemNotification(
                        threadID: "thread-review",
                        turnID: "turn-review",
                        item: .init(
                            type: "agentMessage",
                            id: "cancellation-companion",
                            text: companionArtifact
                        )
                    )
                )
            }
            let interleavedStatus = "Review thread is no longer loaded."
            try await transport.emitServerNotification(
                method: "thread/status/changed",
                params: ReviewUIV2ThreadStatusNotification(
                    threadID: "thread-review",
                    status: .init(type: "notLoaded")
                )
            )
            try await transport.emitServerNotification(
                method: "turn/completed",
                params: ReviewUIV2TurnNotification(
                    threadID: "thread-review",
                    turn: .init(
                        id: "turn-review",
                        items: [],
                        itemsView: "notLoaded",
                        status: "completed"
                    )
                )
            )

            let result = try await review.value
            let rendered = try await awaitTransportRender(contentPane)
            let expectedCancellation = ReviewCancellation.userInterface()
            #expect(result.core.lifecycle.status == .cancelled)
            #expect(result.core.lifecycle.terminal == .interrupted(
                .requested(expectedCancellation)
            ))
            #expect(result.core.lifecycle.cancellation == expectedCancellation)
            #expect(result.core.output.summary == expectedCancellation.message)
            #expect(job.core.lifecycle.status == .cancelled)
            #expect(job.core.lifecycle.errorMessage == expectedCancellation.message)
            #expect(job.logEntries.contains { $0.kind == .error } == false)
            #expect(rendered.log.contains("Partial review before cancellation."))
            #expect(rendered.log.contains(interleavedStatus))
            #expect(rendered.log.contains("Ran swift test"))
            #expect(rendered.log.components(separatedBy: expectedCancellation.message).count == 2)
            let partialRange = try #require(
                rendered.log.range(of: "Partial review before cancellation.")
            )
            let cancellationRange = try #require(
                rendered.log.range(of: expectedCancellation.message)
            )
            let commandRange = try #require(rendered.log.range(of: "Ran swift test"))
            #expect(partialRange.lowerBound < cancellationRange.lowerBound)
            #expect(commandRange.lowerBound < cancellationRange.lowerBound)
            #expect(contentPane.logTerminalDecorationRectCountForTesting == 1)
            #expect(job.logEntries.contains {
                $0.groupID == "active-command"
                    && $0.metadata?.status == "canceled"
            })
            #expect(rendered.log.contains(reviewExitArtifact) == false)
            #expect(rendered.log.contains(companionArtifact) == false)

            let defaultRead = try store.readReview(jobID: job.id)
            let allRead = try store.readReview(jobID: job.id, logFilter: .all)
            let developerDiagnostics = allRead.logs.filter {
                $0.audience == .developer
            }
            #expect(defaultRead.logs.allSatisfy { $0.audience == .product })
            #expect(defaultRead.logs.contains { $0.text == reviewExitArtifact } == false)
            #expect(defaultRead.logs.contains { $0.text == companionArtifact } == false)
            #expect(defaultRead.logs.contains { $0.text == expectedCancellation.message } == false)
            #expect(defaultRead.logs.contains { $0.text == interleavedStatus })
            #expect(developerDiagnostics.map(\.kind) == [.diagnostic, .diagnostic])
            #expect(developerDiagnostics.map(\.groupID) == [
                "review-exit",
                "cancellation-companion",
            ])
            #expect(developerDiagnostics.map(\.text) == [
                reviewExitArtifact,
                companionArtifact,
            ])
            #expect(job.rawLogText.contains(reviewExitArtifact))
            #expect(job.rawLogText.contains(companionArtifact))
            #expect(allRead.rawLogText == job.rawLogText)
            try await waitForCondition {
                store.reviewWorkerTasks["job-1"] == nil
            }
            #expect(await backend.reviewEventSessionCountForTesting() == 0)

            var terminalHistoryItemDeletes = false
            sidebar.presentContextMenuForTesting(for: job) { menu in
                terminalHistoryItemDeletes = menu.items.first.map {
                    $0.title == "Delete from History" && $0.isEnabled
                } ?? false
            }
            #expect(terminalHistoryItemDeletes)

            let requestMethods = await transport.recordedRequests().map(\.method)
            #expect(requestMethods.filter { $0 == "turn/interrupt" }.count == 1)
            #expect(requestMethods.contains("thread/backgroundTerminals/clean"))
            #expect(requestMethods.contains("thread/unsubscribe"))
            #expect(requestMethods.contains("thread/delete"))
        }
        #expect(await transport.isClosedForTesting())
        #expect(store.reviewWorkerTasks["job-1"] == nil)
        #expect(await backend.reviewEventSessionCountForTesting() == 0)
        #expect(await backend.notificationRouterIsRunningForTesting() == false)
    }
}

private enum ReviewUIAppServerIntegrationError: Error {
    case injected
}

@MainActor
private func withReviewUIAppServerCleanup<Value>(
    store: CodexReviewStore,
    backend: AppServerCodexReviewBackend,
    transport: FakeJSONRPCTransport,
    reviewTask: Task<CodexReviewAPI.Read.Result, any Error>,
    operation: () async throws -> Value
) async throws -> Value {
    let value: Value
    do {
        value = try await operation()
    } catch {
        let operationError = error
        do {
            try await finishReviewForCleanup(
                store: store,
                transport: transport,
                reviewTask: reviewTask
            )
        } catch {
            Issue.record("Review cleanup terminal also failed: \(error.localizedDescription)")
        }
        _ = await reviewTask.result
        do {
            try await backend.runtimeOwnerLifecycleHandle.closeAndWait()
        } catch {
            Issue.record("AppServer cleanup also failed: \(error.localizedDescription)")
        }
        throw operationError
    }
    try await finishReviewForCleanup(
        store: store,
        transport: transport,
        reviewTask: reviewTask
    )
    _ = await reviewTask.result
    try await backend.runtimeOwnerLifecycleHandle.closeAndWait()
    return value
}

@MainActor
private func finishReviewForCleanup(
    store: CodexReviewStore,
    transport: FakeJSONRPCTransport,
    reviewTask: Task<CodexReviewAPI.Read.Result, any Error>
) async throws {
    reviewTask.cancel()
    if let job = store.orderedJobs.first(where: { $0.isTerminal == false }),
       let threadID = job.core.run.reviewThreadID,
       let turnID = job.core.run.turnID {
        try await withTestTimeout {
            while await transport.recordedRequests().contains(where: {
                $0.method == "turn/interrupt"
            }) == false {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: ReviewUIV2TurnNotification(
                threadID: threadID,
                turn: .init(
                    id: turnID,
                    items: [],
                    itemsView: "notLoaded",
                    status: "interrupted"
                )
            )
        )
    }
    await store.cancelAndDrainReviewWorkersForTesting()
}

@MainActor
private final class ReviewUIAppServerStoreBackend: PreviewCodexReviewStoreBackend {
    private let reviewBackend: AppServerCodexReviewBackend

    init(reviewBackend: AppServerCodexReviewBackend) {
        self.reviewBackend = reviewBackend
        super.init()
    }

    override func startReview(
        _ request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> BackendReviewAttempt {
        try await reviewBackend.startReview(request, admission: admission)
    }

    override func interruptReview(
        _ run: CodexReviewBackendModel.Review.Run,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws {
        try await reviewBackend.interruptReview(run, reason: reason)
    }

    override func interruptReview(
        _ admission: ReviewInterruptRequestAdmission,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws {
        try await reviewBackend.interruptReview(admission, reason: reason)
    }

    override func cleanupReview(_ run: CodexReviewBackendModel.Review.Run) async {
        do {
            try await reviewBackend.cleanupReview(run)
        } catch {
            Issue.record("AppServer review cleanup failed: \(error.localizedDescription)")
        }
    }
}

private final class ReviewUIIngestionDiagnosticCapture: ReviewIngestionDiagnosticRecording {
    private let diagnostics = Mutex<[ReviewIngestionDiagnosticRecord]>([])

    func record(_ diagnostic: ReviewIngestionDiagnosticRecord) {
        diagnostics.withLock { $0.append(diagnostic) }
    }

    func snapshot() -> [ReviewIngestionDiagnosticRecord] {
        diagnostics.withLock { $0 }
    }
}

private struct ReviewUIAppServerNotification: Sendable {
    var method: String
    var params: ReviewUIV2ItemNotification
}

private struct ReviewUIV2ItemNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var item: Item
    var startedAtMs: Int64 = 1
    var completedAtMs: Int64 = 2

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case item
        case startedAtMs
        case completedAtMs
    }

    struct Item: Encodable, Sendable {
        var type: String
        var id: String
        var text: String?
        var review: String?
        var command: String?
        var cwd: String?
        var source: String?
        var status: String?
        var commandActions: [[String: String]]?
        var aggregatedOutput: String?
        var exitCode: Int?
        var arguments: [String: String]?
        var server: String?
        var namespace: String?
        var tool: String?
        var result: String?
        var error: String?
        var phase: String?
        var summary: [String]?
        var content: [String]?

        init(
            type: String,
            id: String,
            text: String? = nil,
            review: String? = nil,
            command: String? = nil,
            cwd: String? = nil,
            source: String? = nil,
            status: String? = nil,
            commandActions: [[String: String]]? = nil,
            aggregatedOutput: String? = nil,
            exitCode: Int? = nil,
            arguments: [String: String]? = nil,
            server: String? = nil,
            namespace: String? = nil,
            tool: String? = nil,
            result: String? = nil,
            error: String? = nil,
            phase: String? = nil,
            summary: [String]? = nil,
            content: [String]? = nil
        ) {
            self.type = type
            self.id = id
            self.text = text
            self.review = review
            self.command = command
            self.cwd = cwd
            self.source = source
            self.status = status
            self.commandActions = commandActions
            self.aggregatedOutput = aggregatedOutput
            self.exitCode = exitCode
            self.arguments = arguments
            self.server = server
            self.namespace = namespace
            self.tool = tool
            self.result = result
            self.error = error
            self.phase = phase
            self.summary = summary
            self.content = content
        }

        static func command(
            id: String,
            status: String,
            command: String = "swift test",
            commandActions: [[String: String]] = [],
            exitCode: Int? = nil
        ) -> Self {
            .init(
                type: "commandExecution",
                id: id,
                command: command,
                cwd: "/tmp/project",
                source: "agent",
                status: status,
                commandActions: commandActions,
                aggregatedOutput: "",
                exitCode: exitCode
            )
        }
    }
}

private struct ReviewUIV2DeltaNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var delta: String
    var summaryIndex: Int?
    var contentIndex: Int?

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case delta
        case summaryIndex
        case contentIndex
    }
}

private struct ReviewUIV2MessageNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var message: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case message
    }
}

private struct ReviewUIV2TurnNotification: Encodable, Sendable {
    struct Turn: Encodable, Sendable {
        var id: String
        var items: [ReviewUIV2ItemNotification.Item]
        var itemsView: String
        var status: String
    }

    var threadID: String
    var turn: Turn

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
    }
}

private struct ReviewUIV2ThreadStatusNotification: Encodable, Sendable {
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

private func canonicalJSON(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return try JSONSerialization.data(
        withJSONObject: object,
        options: [.fragmentsAllowed, .sortedKeys]
    )
}
