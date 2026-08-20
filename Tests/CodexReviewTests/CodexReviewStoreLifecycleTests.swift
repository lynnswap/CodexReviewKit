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
            task: transitionTask
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
        if case .transitioning(_, .restartSameAccount, _) = store.runtimeState {
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
}
