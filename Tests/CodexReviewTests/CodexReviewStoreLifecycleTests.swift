import Foundation
import Testing
import CodexReview
import CodexReviewTesting

@Suite("store runtime lifecycle")
@MainActor
struct CodexReviewStoreLifecycleTests {
    @Test func invalidatedGenerationBeforeAcquisitionEntryPerformsNoMCPWork() async {
        let mcpOwner = TestingMCPServerLifecycleOwner()
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        let generation = ReviewRuntimeGeneration(rawValue: 1)
        let transitionTask = Task<Void, Never> { @MainActor in }
        store.runtimeState = .transitioning(
            generation: generation.successor(),
            purpose: .stop,
            task: transitionTask,
            record: ReviewRuntimeTransitionRecord(),
            sourceRuntime: nil
        )

        await store.performRuntimeAcquisitionForTesting(
            generation: generation,
            purpose: .stop
        )

        #expect(mcpOwner.prepareCallCount == 0)
        #expect(mcpOwner.activateCallCount == 0)
        #expect(backend.lastPreparedRuntimeHandle == nil)
        #expect(backend.startRequests.isEmpty)
    }

    @Test func stopInvalidatesHeldRuntimePreparationAndClosesStaleHandleOnce() async throws {
        let preparationGate = AsyncGate()
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend()
        )
        backend.holdRuntimePreparation(with: preparationGate)
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        let startTask = Task { @MainActor in
            await store.start()
        }
        await backend.waitForRuntimePreparation()
        let handle = try #require(backend.lastPreparedRuntimeHandle)

        let stopTask = Task { @MainActor in
            await store.stop()
        }
        await backend.waitForRuntimePreparationCancellation()

        #expect(handle.activateCallCount == 0)
        #expect(handle.closeAdmissionCallCount == 0)
        #expect(handle.closeCallCount == 0)
        #expect(store.serverState == .starting)

        await preparationGate.open()
        await stopTask.value
        await startTask.value

        #expect(store.serverState == .stopped)
        #expect(store.serverURL == nil)
        #expect(handle.activateCallCount == 0)
        #expect(handle.closeAdmissionCallCount == 1)
        #expect(handle.closeCallCount == 1)
        #expect(handle.waitUntilClosedCallCount == 1)
        #expect(backend.isActive == false)
    }

    @Test func stoppedStoreCanPrepareAndPublishANewRuntimeGeneration() async throws {
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend()
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        await store.start()
        let firstHandle = try #require(backend.lastPreparedRuntimeHandle)
        #expect(store.serverState == .running)
        #expect(store.serverURL == nil)
        #expect(firstHandle.activateCallCount == 1)

        await store.stop()
        #expect(store.serverState == .stopped)
        #expect(firstHandle.closeCallCount == 1)

        await store.start()
        let secondHandle = try #require(backend.lastPreparedRuntimeHandle)
        #expect(secondHandle !== firstHandle)
        #expect(secondHandle.activateCallCount == 1)
        #expect(store.serverState == .running)
        #expect(store.serverURL == nil)
    }

    @Test func staleMCPPreparationDoesNotAcquireAnAppServerRuntime() async throws {
        let preparationGate = AsyncGate()
        let mcpOwner = TestingMCPServerLifecycleOwner()
        mcpOwner.holdPreparation(with: preparationGate)
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        let startTask = Task { @MainActor in
            await store.start()
        }
        await mcpOwner.waitForPreparation()
        let stopTask = Task { @MainActor in
            await store.stop()
        }
        await mcpOwner.waitForPreparationCancellation()

        #expect(backend.lastPreparedRuntimeHandle == nil)
        #expect(backend.startRequests.isEmpty)

        await preparationGate.open()
        await stopTask.value
        await startTask.value

        #expect(store.serverState == .stopped)
        #expect(backend.lastPreparedRuntimeHandle == nil)
        #expect(mcpOwner.stopCallCount == 1)
        #expect(mcpOwner.waitUntilStoppedCallCount == 1)
        #expect(mcpOwner.activateCallCount == 0)
    }

    @Test func sameAccountRestartRetainsOneMCPGenerationAndReplacesOnlyAppServer() async throws {
        let endpoint = try #require(URL(string: "http://127.0.0.1:19417/mcp"))
        let mcpOwner = TestingMCPServerLifecycleOwner(serverURL: endpoint)
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        await store.start()
        let firstHandle = try #require(backend.lastPreparedRuntimeHandle)
        let firstMCPGeneration = try #require(mcpOwner.preparedGenerations.first)
        #expect(store.serverURL == endpoint)

        let replacementGate = AsyncGate()
        backend.holdRuntimePreparation(with: replacementGate)
        let restartTask = Task { @MainActor in
            await store.restart()
        }
        await backend.waitForRuntimePreparation()

        let ownsReplacementTask: Bool
        if case .transitioning(_, .restartSameAccount, _, _, _) = store.runtimeState {
            ownsReplacementTask = true
        } else {
            ownsReplacementTask = false
        }
        #expect(ownsReplacementTask)
        #expect(store.serverURL == endpoint)
        #expect(mcpOwner.prepareCallCount == 1)
        #expect(mcpOwner.activateCallCount == 1)
        #expect(mcpOwner.stopCallCount == 0)
        #expect(mcpOwner.waitUntilStoppedCallCount == 0)
        #expect(firstHandle.closePurposes == [.restartSameAccount])

        await replacementGate.open()
        await restartTask.value

        let secondHandle = try #require(backend.lastPreparedRuntimeHandle)
        #expect(secondHandle !== firstHandle)
        #expect(secondHandle.activateCallCount == 1)
        #expect(backend.startRequests == [false, true])
        #expect(store.serverState == .running)
        #expect(store.serverURL == endpoint)
        #expect(mcpOwner.preparedGenerations == [firstMCPGeneration])
        #expect(mcpOwner.activatedGenerations == [firstMCPGeneration])
        #expect(mcpOwner.stopCallCount == 0)

        guard case .running(_, _, let retainedMCPGeneration) = store.runtimeState else {
            Issue.record("Replacement must publish the new AppServer runtime.")
            return
        }
        #expect(retainedMCPGeneration == firstMCPGeneration)

        await store.stop()
    }

    @Test func stopInvalidatesHeldRestartBeforeReplacementCanPublish() async throws {
        let endpoint = try #require(URL(string: "http://127.0.0.1:19422/mcp"))
        let mcpOwner = TestingMCPServerLifecycleOwner(serverURL: endpoint)
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let firstHandle = try #require(backend.lastPreparedRuntimeHandle)

        let replacementGate = AsyncGate()
        backend.holdRuntimePreparation(with: replacementGate)
        let restartTask = Task { @MainActor in
            await store.restart()
        }
        await backend.waitForRuntimePreparation()
        let staleReplacement = try #require(backend.lastPreparedRuntimeHandle)
        let stopTask = Task { @MainActor in
            await store.stop()
        }
        await backend.waitForRuntimePreparationCancellation()

        #expect(firstHandle.closePurposes == [.restartSameAccount])
        #expect(staleReplacement !== firstHandle)
        #expect(staleReplacement.activateCallCount == 0)
        #expect(store.serverURL == endpoint)

        await replacementGate.open()
        await stopTask.value
        await restartTask.value

        #expect(store.serverState == .stopped)
        #expect(store.serverURL == nil)
        #expect(staleReplacement.activateCallCount == 0)
        #expect(staleReplacement.closeAdmissionCallCount == 1)
        #expect(staleReplacement.closeCallCount == 1)
        #expect(staleReplacement.waitUntilClosedCallCount == 1)
        #expect(mcpOwner.prepareCallCount == 1)
        #expect(mcpOwner.activateCallCount == 1)
        #expect(mcpOwner.stopCallCount == 1)
        #expect(mcpOwner.waitUntilStoppedCallCount == 1)
    }

    @Test func concurrentAndRepeatedCloseJoinOneRecordedResultAndRejectLaterMutation() async throws {
        let mcpOwner = TestingMCPServerLifecycleOwner()
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)
        let runtimeCloseGate = AsyncGate()
        runtime.holdClose(with: runtimeCloseGate)

        let firstClose = Task { @MainActor in
            try await store.close()
        }
        await runtime.waitForClose()
        let secondClose = Task { @MainActor in
            try await store.close()
        }
        await store.waitForCloseCallersForTesting(2)

        #expect(runtime.closeCallCount == 1)
        #expect(runtime.waitUntilClosedCallCount == 0)
        #expect(mcpOwner.closeAdmissionCallCount == 1)
        #expect(mcpOwner.drainAdmittedHandlersCallCount == 1)
        #expect(mcpOwner.closeCallCount == 1)
        #expect(mcpOwner.waitUntilClosedCallCount == 1)

        await runtimeCloseGate.open()
        try await firstClose.value
        try await secondClose.value
        try await store.close()

        #expect(runtime.closeCallCount == 1)
        #expect(runtime.waitUntilClosedCallCount == 1)
        #expect(runtime.closePurposes == [.applicationClose])
        guard case .closed(.success) = store.lifetimeState else {
            Issue.record("Store close must record one successful result.")
            return
        }

        let startRequests = backend.startRequests
        await store.start()
        await store.restart()
        await store.stop()
        #expect(backend.startRequests == startRequests)
        await #expect(throws: CodexReviewAPI.Error.self) {
            _ = try await store.startReview(
                sessionID: "session-after-close",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
    }

    @Test func closeWaitsForAdmittedMCPHandlerBeforeRuntimePhysicalClose() async throws {
        let mcpOwner = TestingMCPServerLifecycleOwner()
        let handlerGate = AsyncGate()
        mcpOwner.holdHandlerDrain(with: handlerGate)
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)

        let closeTask = Task { @MainActor in
            try await store.close()
        }
        await mcpOwner.waitForHandlerDrain()

        #expect(mcpOwner.closeAdmissionCallCount == 1)
        #expect(mcpOwner.closeCallCount == 0)
        #expect(runtime.closeCallCount == 0)

        await handlerGate.open()
        try await closeTask.value

        #expect(mcpOwner.closeCallCount == 1)
        #expect(mcpOwner.waitUntilClosedCallCount == 1)
        #expect(runtime.closeCallCount == 1)
    }

    @Test func closeInvalidatesHeldRuntimePreparationAndNeverPublishesIt() async throws {
        let preparationGate = AsyncGate()
        let mcpOwner = TestingMCPServerLifecycleOwner()
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        backend.holdRuntimePreparation(with: preparationGate)
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        let startTask = Task { @MainActor in
            await store.start()
        }
        await backend.waitForRuntimePreparation()
        let staleRuntime = try #require(backend.lastPreparedRuntimeHandle)
        let closeTask = Task { @MainActor in
            try await store.close()
        }
        await backend.waitForRuntimePreparationCancellation()

        #expect(staleRuntime.activateCallCount == 0)
        #expect(store.serverState == .starting)

        await preparationGate.open()
        try await closeTask.value
        await startTask.value

        #expect(staleRuntime.activateCallCount == 0)
        #expect(staleRuntime.closeAdmissionCallCount == 1)
        #expect(staleRuntime.closeCallCount == 1)
        #expect(staleRuntime.waitUntilClosedCallCount == 1)
        #expect(store.serverState == .stopped)
        #expect(store.serverURL == nil)
    }

    @Test func closeAggregatesLifecycleFailuresOnceAndReplaysThem() async throws {
        let mcpOwner = TestingMCPServerLifecycleOwner()
        mcpOwner.failHandlerDrain(with: .mcpHandlerDrain("handler drain failed"))
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)
        runtime.failClose(with: .init(first: .client("runtime close failed")))

        let firstError = await capturedCloseError(from: store)
        let secondError = await capturedCloseError(from: store)

        #expect(firstError?.localizedDescription == secondError?.localizedDescription)
        #expect(runtime.closeCallCount == 1)
        #expect(runtime.waitUntilClosedCallCount == 1)
        #expect(mcpOwner.drainAdmittedHandlersCallCount == 1)
        let failures = try #require(firstError).failures
        guard case .lifecycleResources(let firstLifecycle) = failures.first else {
            Issue.record("MCP handler drain must be the first close lifecycle failure.")
            return
        }
        #expect(firstLifecycle.first == .mcpHandlerDrain("handler drain failed"))
        guard case .lifecycleResources(let secondLifecycle) = failures.additionalInLifecycleOrder.first else {
            Issue.record("Runtime close must follow MCP lifecycle failures.")
            return
        }
        #expect(secondLifecycle.first == .client("runtime close failed"))
        #expect(failures.additionalInLifecycleOrder.count == 1)
    }

    @Test func cancellationFailureUsesRuntimeTerminalBeforeJoiningWorker() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: run)
        await reviewBackend.failInterrupts(message: "interrupt rejected")
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        backend.setRuntimeCloseOperation {
            try? await reviewBackend.forceCloseReviewConnection()
        }
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)
        let runtimeCloseGate = AsyncGate()
        runtime.holdClose(with: runtimeCloseGate)
        let initial = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .milliseconds(20)
        )
        #expect(initial.core.lifecycle.status == .running)

        let closeTask = Task { @MainActor in
            await capturedCloseError(from: store)
        }
        await runtime.waitForClose()

        let beforeRuntimeClose = try store.readReview(jobID: "job-1")
        #expect(beforeRuntimeClose.core.lifecycle.status == .running)
        #expect(store.reviewWorkerTasks["job-1"] != nil)

        await runtimeCloseGate.open()
        let closeError = try #require(await closeTask.value)

        let terminal = try store.readReview(jobID: "job-1")
        #expect(terminal.core.lifecycle.status == .failed)
        #expect(terminal.core.lifecycle.cancellation == nil)
        #expect(store.reviewWorkerTasks["job-1"] == nil)
        guard case .interruptRequest(let failure) = closeError.failures.first else {
            Issue.record("Interrupt failure must remain first in the close aggregate.")
            return
        }
        #expect(failure.outcome == .rejected(code: nil, message: "interrupt rejected"))
    }

    @Test func successfulCancellationCleanupFinishesBeforeAppServerAdmissionCloses() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: run)
        let cleanupGate = AsyncGate()
        await reviewBackend.holdCleanupReview(with: cleanupGate)
        let mcpOwner = TestingMCPServerLifecycleOwner()
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: reviewBackend,
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)
        _ = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .milliseconds(20)
        )

        let closeTask = Task { @MainActor in
            try await store.close()
        }
        await reviewBackend.waitForInterruptReview()
        await reviewBackend.yield(
            .cancelled("Review Store closed."),
            for: run
        )
        await reviewBackend.waitForCleanupReview()

        #expect(runtime.closeAdmissionCallCount == 0)
        #expect(runtime.closeCallCount == 0)
        #expect(mcpOwner.drainAdmittedHandlersCallCount == 0)

        await cleanupGate.open()
        try await closeTask.value

        #expect(runtime.closeAdmissionCallCount == 1)
        #expect(runtime.closeCallCount == 1)
        #expect(store.reviewWorkerTasks["job-1"] == nil)
    }

    @Test func closeAwaitsPrePublicationReviewMutationAndPreventsBackendWrite() async throws {
        let reviewBackend = FakeCodexReviewBackend()
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let mutationEntered = AsyncGate()
        let mutationRelease = AsyncGate()
        store.setReviewMutationPreparationForTesting {
            await mutationEntered.open()
            await mutationRelease.waitIgnoringCancellation()
        }
        let startTask = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await mutationEntered.wait()
        let closeCompletion = StoreCloseCompletion()
        let closeTask = Task { @MainActor in
            try await store.close()
            await closeCompletion.complete()
        }
        await store.waitForCloseCallersForTesting(1)

        let commandsBeforeRelease = await reviewBackend.recordedCommands()
        #expect(await closeCompletion.isComplete() == false)
        #expect(store.reviewMutationTasks.count == 1)
        #expect(commandsBeforeRelease.contains { command in
            if case .startReview = command { true } else { false }
        } == false)

        await mutationRelease.open()
        await #expect(throws: CodexReviewAPI.Error.self) {
            _ = try await startTask.value
        }
        try await closeTask.value

        #expect(await closeCompletion.isComplete())
        #expect(store.reviewMutationTasks.isEmpty)
        #expect(store.jobs.isEmpty)
    }

    @Test func closeAwaitsAdmittedAuthenticationMutationAndRejectsLaterMutation() async throws {
        let authRefreshGate = AsyncGate()
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend()
        )
        backend.holdAuthRefresh(with: authRefreshGate)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)

        let refreshTask = Task { @MainActor in
            await store.refreshAuthentication()
        }
        await backend.waitForAuthRefresh()
        let closeCompletion = StoreCloseCompletion()
        let closeTask = Task { @MainActor in
            try await store.close()
            await closeCompletion.complete()
        }
        await store.waitForCloseCallersForTesting(1)

        #expect(await closeCompletion.isComplete() == false)
        #expect(runtime.closeCallCount == 0)
        #expect(backend.authRefreshCallCount == 1)

        await authRefreshGate.open()
        await refreshTask.value
        try await closeTask.value

        #expect(await closeCompletion.isComplete())
        #expect(runtime.closeCallCount == 1)
        await store.refreshAuthentication()
        #expect(backend.authRefreshCallCount == 1)
    }

    @Test func closeReplaysFailureFromACompletedRuntimeTransition() async throws {
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend()
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)
        runtime.failClose(with: .init(first: .client("stop close failed")))

        await store.stop()
        let firstError = try #require(await capturedCloseError(from: store))
        let secondError = try #require(await capturedCloseError(from: store))

        #expect(firstError.localizedDescription == secondError.localizedDescription)
        guard case .lifecycleResources(let lifecycle) = firstError.failures.first else {
            Issue.record("The completed transition failure must remain owned by Store close.")
            return
        }
        #expect(lifecycle.first == .client("stop close failed"))
        #expect(runtime.closeCallCount == 1)
        #expect(runtime.waitUntilClosedCallCount == 1)
    }

    @Test func closePreservesInterruptFailureFromCompletedStopTransition() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: run)
        await reviewBackend.failInterrupts(message: "stop interrupt rejected")
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )
        await store.start()
        _ = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .milliseconds(20)
        )

        await store.stop()
        let closeError = try #require(await capturedCloseError(from: store))

        guard case .interruptRequest(let failure) = closeError.failures.first else {
            Issue.record("The completed stop transition must retain its interrupt failure.")
            return
        }
        #expect(failure.outcome == .rejected(code: nil, message: "stop interrupt rejected"))
    }

    @Test func applicationGraceCloseConsumesRuntimeFailureExactlyOnce() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: run)
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { "job-1" }),
            reviewRuntimeClosePolicy: .init(
                terminalGrace: .seconds(10),
                sleep: { _ in }
            )
        )
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)
        runtime.failClose(with: .init(first: .client("forced runtime close failed")))
        _ = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .milliseconds(20)
        )

        let closeError = try #require(await capturedCloseError(from: store))

        #expect(closeError.failures.additionalInLifecycleOrder.isEmpty)
        guard case .lifecycleResources(let lifecycle) = closeError.failures.first else {
            Issue.record("Forced runtime close must retain its lifecycle failure.")
            return
        }
        #expect(lifecycle.first == .client("forced runtime close failed"))
        #expect(runtime.closeCallCount == 1)
        #expect(runtime.waitUntilClosedCallCount == 1)
    }

    @Test func closeImportsPriorGraceFailureReceiptBeforeRecancellingActiveJob() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: run)
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { "job-1" }),
            reviewRuntimeClosePolicy: .init(
                terminalGrace: .seconds(10),
                sleep: { _ in }
            )
        )
        let terminalPublicationEntered = AsyncGate()
        let terminalPublicationRelease = AsyncGate()
        let forceCloseReceiptRecorded = AsyncGate()
        store.setReviewTerminalPublicationPreparationForTesting {
            await terminalPublicationEntered.open()
            await terminalPublicationRelease.waitIgnoringCancellation()
        }
        store.setRuntimeForceCloseReceiptRecordedForTesting {
            await forceCloseReceiptRecorded.open()
        }
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)
        runtime.failClose(with: .init(first: .client("prior forced close failed")))
        _ = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .milliseconds(20)
        )

        let cancellationTask = Task { @MainActor in
            try await store.cancelReview(
                jobID: "job-1",
                cancellation: .mcpClient(message: "Stop")
            )
        }
        await forceCloseReceiptRecorded.wait()
        await terminalPublicationEntered.wait()
        #expect(try store.readReview(jobID: "job-1").core.lifecycle.status == .running)

        let closeTask = Task { @MainActor in
            await capturedCloseError(from: store)
        }
        await store.waitForCloseCallersForTesting(1)
        await terminalPublicationRelease.open()
        _ = await cancellationTask.result
        let closeError = try #require(await closeTask.value)

        #expect(closeError.failures.additionalInLifecycleOrder.isEmpty)
        guard case .lifecycleResources(let lifecycle) = closeError.failures.first else {
            Issue.record("The prior force-close receipt must retain lifecycle ownership.")
            return
        }
        #expect(lifecycle.first == .client("prior forced close failed"))
        #expect(runtime.closeCallCount == 1)
        #expect(runtime.waitUntilClosedCallCount == 1)
    }

    @Test func closeDoesNotRepeatCleanupFailureConsumedByCompletedStop() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: run)
        await reviewBackend.failCleanup(message: "stop cleanup failed")
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )
        await store.start()
        _ = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .milliseconds(20)
        )
        let stopTask = Task { @MainActor in
            await store.stop()
        }
        await reviewBackend.waitForInterruptReview()
        await reviewBackend.yield(.cancelled("Review runtime stopped."), for: run)
        await stopTask.value

        let closeError = try #require(await capturedCloseError(from: store))

        #expect(closeError.failures.additionalInLifecycleOrder.isEmpty)
        guard case .attemptRuntime(let failure) = closeError.failures.first else {
            Issue.record("Stop cleanup failure must remain an attempt-runtime failure.")
            return
        }
        #expect(failure == .cleanup("stop cleanup failed"))
    }

    @Test func naturallyTerminalWorkerFinishesCleanupBeforeRuntimePhysicalClose() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: run)
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )
        let cleanupEntered = AsyncGate()
        let cleanupRelease = AsyncGate()
        store.setReviewCleanupPreparationForTesting {
            await cleanupEntered.open()
            await cleanupRelease.waitIgnoringCancellation()
        }
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)
        _ = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .milliseconds(20)
        )
        await reviewBackend.yield(
            .completed(summary: "Done", result: "review text"),
            for: run
        )
        await cleanupEntered.wait()
        #expect(try store.readReview(jobID: "job-1").core.lifecycle.status == .succeeded)

        let closeTask = Task { @MainActor in
            try await store.close()
        }
        await runtime.waitForCloseAdmission()

        #expect(runtime.closeCallCount == 0)
        #expect(await reviewBackend.recordedCommands().contains(.cleanupReview(run)) == false)

        await cleanupRelease.open()
        try await closeTask.value

        #expect(await reviewBackend.recordedCommands().contains(.cleanupReview(run)))
        #expect(runtime.closeCallCount == 1)
        #expect(runtime.waitUntilClosedCallCount == 1)
    }
}

@MainActor
private func capturedCloseError(from store: CodexReviewStore) async -> ReviewCloseError? {
    do {
        try await store.close()
        return nil
    } catch let error as ReviewCloseError {
        return error
    } catch {
        Issue.record("Unexpected close error: \(error)")
        return nil
    }
}

private actor StoreCloseCompletion {
    private var completeValue = false

    func complete() {
        completeValue = true
    }

    func isComplete() -> Bool {
        completeValue
    }
}
