import Foundation
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

        let startTask = Task { @MainActor in await store.start() }
        await backend.waitForRuntimePreparation()
        let handle = try #require(backend.lastPreparedRuntimeHandle)
        let stopTask = Task { @MainActor in await store.stop() }
        await backend.waitForRuntimePreparationCancellation()

        #expect(handle.activateCallCount == 0)
        #expect(store.serverState == .starting)

        await preparationGate.open()
        await stopTask.value
        await startTask.value

        #expect(store.serverState == .stopped)
        #expect(handle.activateCallCount == 0)
        #expect(handle.closeAdmissionCallCount == 1)
        #expect(handle.closePurposes == [.start])
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
        #expect(firstHandle.activateCallCount == 1)

        await store.stop()
        #expect(firstHandle.closePurposes == [.stop])

        await store.start()
        let secondHandle = try #require(backend.lastPreparedRuntimeHandle)
        #expect(secondHandle !== firstHandle)
        #expect(secondHandle.activateCallCount == 1)
        #expect(store.serverState == .running)
    }
    @Test func restartInvalidatesHeldAcquisitionAndStartsAFreshGeneration() async throws {
        let preparationGate = AsyncGate()
        let mcpOwner = TestingMCPServerLifecycleOwner()
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        backend.holdRuntimePreparation(with: preparationGate)
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        let startTask = Task { @MainActor in await store.start() }
        await backend.waitForRuntimePreparation()
        let staleHandle = try #require(backend.lastPreparedRuntimeHandle)
        let restartTask = Task { @MainActor in await store.restart() }
        await backend.waitForRuntimePreparationCancellation()

        await preparationGate.open()
        await restartTask.value
        await startTask.value

        let currentHandle = try #require(backend.lastPreparedRuntimeHandle)
        #expect(currentHandle !== staleHandle)
        #expect(staleHandle.activateCallCount == 0)
        #expect(staleHandle.closePurposes == [.start])
        #expect(currentHandle.activateCallCount == 1)
        #expect(store.serverState == .running)
        #expect(mcpOwner.preparedGenerations.count == 2)
        #expect(mcpOwner.activatedGenerations.count == 1)
        #expect(mcpOwner.stopCallCount == 1)
        await store.stop()
    }
    @Test func staleMCPPreparationDoesNotAcquireAnAppServerRuntime() async {
        let preparationGate = AsyncGate()
        let mcpOwner = TestingMCPServerLifecycleOwner()
        mcpOwner.holdPreparation(with: preparationGate)
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        let startTask = Task { @MainActor in await store.start() }
        await mcpOwner.waitForPreparation()
        let stopTask = Task { @MainActor in await store.stop() }
        await mcpOwner.waitForPreparationCancellation()
        await preparationGate.open()
        await stopTask.value
        await startTask.value

        #expect(store.serverState == .stopped)
        #expect(backend.lastPreparedRuntimeHandle == nil)
        #expect(mcpOwner.stopCallCount == 1)
        #expect(mcpOwner.activatedGenerations.isEmpty)
    }
    @Test func explicitStopWinsWhileFailedAcquisitionIsDrainingMCP() async {
        let stopGate = AsyncGate()
        let mcpOwner = TestingMCPServerLifecycleOwner()
        mcpOwner.holdStop(with: stopGate)
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        backend.failNextRuntimePreparation(message: "Injected preparation failure.")
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        let startTask = Task { @MainActor in await store.start() }
        await mcpOwner.waitForStop()
        let stopTask = Task { @MainActor in await store.stop() }
        await mcpOwner.waitForSecondStop()
        await stopGate.open()
        await stopTask.value
        await startTask.value

        #expect(store.serverState == .stopped)
        #expect(store.serverURL == nil)
        #expect(mcpOwner.stopCallCount == 1)
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

        let replacementGate = AsyncGate()
        backend.holdRuntimePreparation(with: replacementGate)
        let restartTask = Task { @MainActor in await store.restart() }
        await backend.waitForRuntimePreparation()

        #expect(store.serverURL == endpoint)
        #expect(firstHandle.closePurposes == [.restartSameAccount])
        #expect(mcpOwner.preparedGenerations == [firstMCPGeneration])
        #expect(mcpOwner.activatedGenerations == [firstMCPGeneration])
        #expect(mcpOwner.stopCallCount == 0)

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

        guard case .running(_, _, let retainedGeneration) = store.runtimeState else {
            Issue.record("Replacement must publish the new AppServer runtime.")
            return
        }
        #expect(retainedGeneration == firstMCPGeneration)
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
        let restartTask = Task { @MainActor in await store.restart() }
        await backend.waitForRuntimePreparation()
        let staleReplacement = try #require(backend.lastPreparedRuntimeHandle)
        let stopTask = Task { @MainActor in await store.stop() }
        await backend.waitForRuntimePreparationCancellation()

        #expect(firstHandle.closePurposes == [.restartSameAccount])
        #expect(staleReplacement.activateCallCount == 0)
        #expect(store.serverURL == endpoint)

        await replacementGate.open()
        await stopTask.value
        await restartTask.value

        #expect(store.serverState == .stopped)
        #expect(store.serverURL == nil)
        #expect(staleReplacement.activateCallCount == 0)
        #expect(staleReplacement.closeAdmissionCallCount == 1)
        #expect(staleReplacement.closePurposes == [.restartSameAccount])
        #expect(staleReplacement.waitUntilClosedCallCount == 1)
        #expect(mcpOwner.stopCallCount == 1)
    }

    @Test func failedSettingsEditRollsBackToPublishedRuntimeSnapshot() async {
        let updateGate = AsyncGate()
        let reviewBackend = FakeCodexReviewBackend(settings: .init(
            model: "runtime-model",
            reasoningEffort: "high",
            serviceTier: "fast"
        ))
        let store = CodexReviewStore.makeTestingStore(backend: TestingCodexReviewStoreBackend(
            reviewBackend: reviewBackend,
            seed: .init(initialSettingsSnapshot: .init(model: "seed-model"))
        ))
        await store.start()
        await reviewBackend.holdNextSettingsUpdate(with: updateGate)
        await reviewBackend.failNextSettingsUpdate(message: "Injected settings failure.")
        let updateTask = Task { @MainActor in
            await store.updateSettingsModel("edited-model")
        }
        await reviewBackend.waitForSettingsUpdate()
        await reviewBackend.setSettingsSnapshot(.init(
            model: "fresh-runtime-model",
            reasoningEffort: "medium",
            serviceTier: "flex"
        ))
        await store.restart()

        await updateGate.open()
        await updateTask.value

        #expect(store.settings.selectedModel == "fresh-runtime-model")
        #expect(store.settings.selectedReasoningEffort == .medium)
        #expect(store.settings.selectedServiceTier == .flex)
        #expect(store.settings.lastErrorMessage == nil)
    }

    @Test func modelEditDoesNotRepersistPublishedRuntimeReasoningAndTier() async throws {
        let updateGate = AsyncGate()
        let reviewBackend = FakeCodexReviewBackend(settings: .init(
            model: "runtime-model",
            reasoningEffort: "high",
            serviceTier: "fast"
        ))
        let store = CodexReviewStore.makeTestingStore(backend: TestingCodexReviewStoreBackend(
            reviewBackend: reviewBackend,
            seed: .init(initialSettingsSnapshot: .init(
                model: "seed-model",
                reasoningEffort: .low
            ))
        ))
        await store.start()
        await reviewBackend.holdNextSettingsUpdate(with: updateGate)
        let staleUpdateTask = Task { @MainActor in
            await store.updateSettingsModel("stale-model")
        }
        await reviewBackend.waitForSettingsUpdate()
        await store.updateSettingsModel("queued-stale-model")
        await store.refreshSettings()
        let freshSnapshot = CodexReviewBackendModel.Settings.Snapshot(
            model: "fresh-runtime-model",
            reasoningEffort: "medium",
            serviceTier: "flex"
        )
        await reviewBackend.setSettingsSnapshot(freshSnapshot)
        await store.restart()
        let commandCountAfterRestart = await reviewBackend.recordedCommands().count

        await updateGate.open()
        await staleUpdateTask.value
        #expect(store.settings.selectedModel == "fresh-runtime-model")
        #expect(store.settings.selectedReasoningEffort == .medium)
        #expect(store.settings.selectedServiceTier == .flex)
        #expect(await reviewBackend.recordedCommands().count == commandCountAfterRestart)

        await reviewBackend.setSettingsSnapshot(freshSnapshot)
        await store.updateSettingsModel("edited-model")

        let command = try #require(await reviewBackend.recordedCommands().last)
        guard case .applySettings(let change) = command else {
            Issue.record("Expected a settings update.")
            return
        }
        #expect(change.updatesReasoningEffort == false)
        #expect(change.updatesServiceTier == false)
    }

    @Test func explicitStopSuppressesJoinedRuntimeFailurePublication() async throws {
        let closeGate = AsyncGate()
        let backend = TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let handle = try #require(backend.lastPreparedRuntimeHandle)
        handle.holdClose(with: closeGate)

        let failureTask = Task { @MainActor in
            await store.failRuntime(handle: handle, message: "Injected runtime failure.")
        }
        await handle.waitForClose()
        let stopTask = Task { @MainActor in await store.stop() }
        for _ in 0..<1_000 {
            if case .transitioning(_, .stop, _) = store.runtimeState {
                break
            }
            await Task.yield()
        }
        guard case .transitioning(_, .stop, _) = store.runtimeState else {
            Issue.record("Explicit stop did not supersede runtime failure.")
            await closeGate.open()
            await stopTask.value
            await failureTask.value
            return
        }

        await closeGate.open()
        await stopTask.value
        await failureTask.value

        #expect(store.serverState == .stopped)
        #expect(handle.closePurposes == [.runtimeFailure])
    }
}
