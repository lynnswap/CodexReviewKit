import Testing
import CodexReview
import CodexReviewTesting

@Suite("store runtime lifecycle")
@MainActor
struct CodexReviewStoreLifecycleTests {
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
}
