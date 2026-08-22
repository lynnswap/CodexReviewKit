import Foundation
import Testing
import CodexReview
import CodexReviewTesting

@Suite("store runtime lifecycle", .serialized)
@MainActor
struct CodexReviewStoreLifecycleTests {
    @Test func stopInvalidatesHeldRuntimePreparationAndClosesStaleHandleOnce() async throws {
        let preparationGate = AsyncGate()
        let mcpOwner = TestingMCPServerLifecycleOwner()
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        backend.holdRuntimePreparation(with: preparationGate)
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        let start = Task { @MainActor in await store.start() }
        await backend.waitForRuntimePreparation()
        let staleHandle = try #require(backend.lastPreparedRuntimeHandle)
        let stop = Task { @MainActor in await store.stop() }
        await backend.waitForRuntimePreparationCancellation()

        #expect(staleHandle.activateCallCount == 0)
        #expect(store.serverState == .starting)

        await preparationGate.open()
        await stop.value
        await start.value

        #expect(store.serverState == .stopped)
        #expect(staleHandle.activateCallCount == 0)
        #expect(staleHandle.closeAdmissionCallCount == 1)
        #expect(staleHandle.closePurposes == [.start])
        #expect(staleHandle.waitUntilClosedCallCount == 1)
        #expect(mcpOwner.stopCallCount == 1)
        #expect(backend.isActive == false)
        #expect(store.settings.lastErrorMessage == nil)
    }

    @Test func forceRestartDuringHeldInitialPreparationPublishesOnlyFreshRuntime() async throws {
        let preparationGate = AsyncGate()
        let mcpOwner = TestingMCPServerLifecycleOwner()
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        backend.holdRuntimePreparation(with: preparationGate)
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        let initialStart = Task { @MainActor in await store.start() }
        await backend.waitForRuntimePreparation()
        let staleHandle = try #require(backend.lastPreparedRuntimeHandle)
        let restart = Task { @MainActor in
            await store.start(forceRestartIfNeeded: true)
        }
        await backend.waitForRuntimePreparationCancellation()

        await preparationGate.open()
        await restart.value
        await initialStart.value

        let currentHandle = try #require(backend.lastPreparedRuntimeHandle)
        #expect(currentHandle !== staleHandle)
        #expect(staleHandle.activateCallCount == 0)
        #expect(staleHandle.closePurposes == [.start])
        #expect(currentHandle.activateCallCount == 1)
        #expect(store.serverState == .running)
        #expect(mcpOwner.preparedServers.count == 2)
        #expect(mcpOwner.activatedServers.count == 1)
        #expect(mcpOwner.stopCallCount == 1)
        #expect(store.settings.lastErrorMessage == nil)
        await store.stop()
    }

    @Test func acquisitionCancellationCatchConsumesCutoverWithoutError() async {
        let preparationGate = AsyncGate()
        let mcpOwner = TestingMCPServerLifecycleOwner()
        mcpOwner.holdPreparation(with: preparationGate)
        let store = CodexReviewStore.makeTestingStore(backend: TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        ))

        let start = Task { @MainActor in await store.start() }
        await mcpOwner.waitForPreparation()
        let stop = Task { @MainActor in await store.stop() }
        await mcpOwner.waitForPreparationCancellation()
        await preparationGate.open()
        await stop.value
        await start.value

        #expect(store.serverState == .stopped)
        #expect(store.settingsService.runtimeCutoverStatus == .awaitingRecovery)
        #expect(store.settings.isLoading == false)
        #expect(store.settings.lastErrorMessage == nil)
    }

    @Test func accountRecycleDuringHeldInitialPreparationStartsFreshListenerAndRuntime() async throws {
        let preparationGate = AsyncGate()
        let mcpOwner = TestingMCPServerLifecycleOwner()
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        backend.holdRuntimePreparation(with: preparationGate)
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        let initialStart = Task { @MainActor in await store.start() }
        await backend.waitForRuntimePreparation()
        let staleHandle = try #require(backend.lastPreparedRuntimeHandle)
        let recycle = Task { @MainActor in
            await store.recycleRuntimeAfterAccountChange()
        }
        await backend.waitForRuntimePreparationCancellation()

        await preparationGate.open()
        await recycle.value
        await initialStart.value

        let currentHandle = try #require(backend.lastPreparedRuntimeHandle)
        #expect(currentHandle !== staleHandle)
        #expect(staleHandle.activateCallCount == 0)
        #expect(currentHandle.activateCallCount == 1)
        #expect(mcpOwner.preparedServers.count == 2)
        #expect(mcpOwner.activatedServers.count == 1)
        #expect(mcpOwner.stopCallCount == 1)
        #expect(store.serverState == .running)
        #expect(store.settings.lastErrorMessage == nil)
        await store.stop()
    }

    @Test func stopAdmittedBeforeRecycleTaskEntryInheritsCleanupOwnership() async throws {
        let mcpOwner = TestingMCPServerLifecycleOwner()
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let retiringHandle = try #require(backend.lastPreparedRuntimeHandle)

        let recycle = try #require(store.admitRuntimeRecycleAfterAccountChange())
        #expect(retiringHandle.closeAdmissionCallCount == 1)
        store.requestRuntimeTeardown(intent: .explicitStop)
        await store.stop()
        await recycle.value

        #expect(store.serverState == .stopped)
        #expect(retiringHandle.closePurposes == [.stop])
        #expect(retiringHandle.waitUntilClosedCallCount == 1)
        #expect(mcpOwner.stopCallCount == 1)
        #expect(store.settings.lastErrorMessage == nil)
    }

    @Test func recycleSuccessorAdmittedBeforeTaskEntryInheritsCleanupOwnership() async throws {
        let mcpOwner = TestingMCPServerLifecycleOwner()
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let retiringHandle = try #require(backend.lastPreparedRuntimeHandle)

        let recycle = try #require(store.admitRuntimeRecycleAfterAccountChange())
        #expect(retiringHandle.closeAdmissionCallCount == 1)
        let successor = try #require(store.admitRuntimeRecycleAfterAccountChange())
        await successor.value
        await recycle.value

        let currentHandle = try #require(backend.lastPreparedRuntimeHandle)
        #expect(currentHandle !== retiringHandle)
        #expect(retiringHandle.closePurposes == [.stop])
        #expect(retiringHandle.waitUntilClosedCallCount == 1)
        #expect(mcpOwner.preparedServers.count == 2)
        #expect(mcpOwner.stopCallCount == 1)
        #expect(store.serverState == .running)
        #expect(store.settings.lastErrorMessage == nil)
        await store.stop()
    }

    @Test func explicitStopAdmissionClosesPublishedRuntimeBeforeTeardownTaskEntry() async throws {
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend()
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let handle = try #require(backend.lastPreparedRuntimeHandle)

        store.requestRuntimeTeardown(intent: .explicitStop)

        #expect(handle.closeAdmissionCallCount == 1)
        await store.stop()
        #expect(handle.closePurposes == [.stop])
        #expect(handle.waitUntilClosedCallCount == 1)
    }

    @Test func sameAccountRestartRetainsMCPListenerAndURL() async throws {
        let endpoint = try #require(URL(string: "http://127.0.0.1:19417/mcp"))
        let mcpOwner = TestingMCPServerLifecycleOwner(serverURL: endpoint)
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        await store.start()
        let firstHandle = try #require(backend.lastPreparedRuntimeHandle)
        let listener = try #require(mcpOwner.preparedServers.first)

        await store.restart()

        let secondHandle = try #require(backend.lastPreparedRuntimeHandle)
        #expect(secondHandle !== firstHandle)
        #expect(firstHandle.closePurposes == [.restartSameAccount])
        #expect(secondHandle.activateCallCount == 1)
        #expect(backend.startRequests == [false, true])
        #expect(store.serverState == .running)
        #expect(store.serverURL == endpoint)
        #expect(mcpOwner.preparedServers.count == 1)
        #expect(mcpOwner.preparedServers.first === listener)
        #expect(mcpOwner.activatedServers.first === listener)
        #expect(mcpOwner.stopCallCount == 0)
        await store.stop()
    }

    @Test func stopInvalidatesHeldReplacementBeforePublication() async throws {
        let endpoint = try #require(URL(string: "http://127.0.0.1:19422/mcp"))
        let mcpOwner = TestingMCPServerLifecycleOwner(serverURL: endpoint)
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let firstHandle = try #require(backend.lastPreparedRuntimeHandle)

        let preparationGate = AsyncGate()
        backend.holdRuntimePreparation(with: preparationGate)
        let restart = Task { @MainActor in await store.restart() }
        await backend.waitForRuntimePreparation()
        let staleReplacement = try #require(backend.lastPreparedRuntimeHandle)
        let stop = Task { @MainActor in await store.stop() }
        await backend.waitForRuntimePreparationCancellation()

        #expect(firstHandle.closePurposes == [.restartSameAccount])
        #expect(staleReplacement.activateCallCount == 0)
        #expect(store.serverURL == endpoint)

        await preparationGate.open()
        await stop.value
        await restart.value

        #expect(store.serverState == .stopped)
        #expect(store.serverURL == nil)
        #expect(staleReplacement.closeAdmissionCallCount == 1)
        #expect(staleReplacement.closePurposes == [.restartSameAccount])
        #expect(staleReplacement.waitUntilClosedCallCount == 1)
        #expect(mcpOwner.stopCallCount == 1)
        #expect(store.settings.lastErrorMessage == nil)
    }

    @Test func replacementCancellationCatchReplaysThroughFreshCutoverWithoutError() async throws {
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend()
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()

        let preparationGate = AsyncGate()
        backend.holdRuntimePreparation(with: preparationGate)
        backend.throwCancellationAfterHeldRuntimePreparation()
        let firstRestart = Task { @MainActor in await store.restart() }
        await backend.waitForRuntimePreparation()
        let secondRestart = Task { @MainActor in await store.restart() }
        await backend.waitForRuntimePreparationCancellation()
        await preparationGate.open()
        await secondRestart.value
        await firstRestart.value

        #expect(store.serverState == .running)
        #expect(store.settingsService.runtimeCutoverStatus == .active)
        #expect(store.settings.isLoading == false)
        #expect(store.settings.lastErrorMessage == nil)
        await store.stop()
    }

    @Test func callerCancellationStillConsumesCutoverByPublishingCurrentRuntime() async throws {
        let preparationGate = AsyncGate()
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend()
        )
        backend.holdRuntimePreparation(with: preparationGate)
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        let caller = Task { @MainActor in await store.start() }
        await backend.waitForRuntimePreparation()
        caller.cancel()
        await preparationGate.open()
        await caller.value

        #expect(store.serverState == .running)
        #expect(store.settingsService.runtimeCutoverStatus == .active)
        #expect(store.settings.isLoading == false)
        #expect(store.settings.lastErrorMessage == nil)
        await store.stop()
    }

    @Test func genuineRuntimePreparationFailureSurfacesSettingsError() async {
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend()
        )
        backend.failNextRuntimePreparation(message: "Injected preparation failure.")
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        await store.start()

        #expect(store.serverState == .failed("Injected preparation failure."))
        #expect(store.settingsService.runtimeCutoverStatus == .awaitingRecovery)
        #expect(store.settings.isLoading == false)
        #expect(store.settings.lastErrorMessage == "Injected preparation failure.")
    }

    @Test func serviceOwnedCommitFailureIsNotConsumedTwiceByStore() async throws {
        let reviewBackend = FakeCodexReviewBackend()
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()

        let preparationGate = AsyncGate()
        backend.holdRuntimePreparation(with: preparationGate)
        let restart = Task { @MainActor in await store.restart() }
        await backend.waitForRuntimePreparation()
        await store.updateSettingsModel("rejected-during-commit")
        await reviewBackend.failNextSettingsUpdate(message: "Commit replay failed.")
        await preparationGate.open()
        await restart.value

        #expect(store.serverState == .failed("Commit replay failed."))
        #expect(store.settingsService.runtimeCutoverStatus == .awaitingRecovery)
        #expect(store.settings.lastErrorMessage == "Commit replay failed.")
        await store.stop()
    }

    @Test func settingsCutoverDrainsOldWriteAndReplaysDeferredIntentOnce() async throws {
        let reviewBackend = FakeCodexReviewBackend(settings: .init(model: "initial-model"))
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let firstHandle = try #require(backend.lastPreparedRuntimeHandle)

        let writeGate = AsyncGate()
        await reviewBackend.holdNextSettingsUpdate(with: writeGate)
        let oldWrite = Task { @MainActor in
            await store.updateSettingsModel("old-runtime-edit")
        }
        await reviewBackend.waitForSettingsUpdate()

        let restart = Task { @MainActor in await store.restart() }
        try await waitForCutoverStatus(.draining, service: store.settingsService)
        #expect(firstHandle.closeAdmissionCallCount == 1)
        await store.updateSettingsModel("deferred-edit")
        #expect(backend.lastPreparedRuntimeHandle === firstHandle)
        #expect(await reviewBackend.recordedCommands().filter {
            if case .applySettings = $0 { true } else { false }
        }.count == 1)

        await writeGate.open()
        await oldWrite.value
        await restart.value

        #expect(store.settings.selectedModel == "deferred-edit")
        #expect(await reviewBackend.settingsSnapshot().model == "deferred-edit")
        #expect(await reviewBackend.recordedCommands().filter {
            if case .applySettings = $0 { true } else { false }
        }.count == 2)
        #expect(store.settings.lastErrorMessage == nil)
        await store.stop()
    }

    @Test func stopDuringServiceOwnedCommitDrainPreservesDeferredIntentWithoutError() async throws {
        let reviewBackend = FakeCodexReviewBackend(settings: .init(model: "initial-model"))
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()

        let preparationGate = AsyncGate()
        backend.holdRuntimePreparation(with: preparationGate)
        let restart = Task { @MainActor in await store.restart() }
        await backend.waitForRuntimePreparation()
        await store.updateSettingsModel("deferred-during-commit")

        let commitGate = AsyncGate()
        await reviewBackend.holdNextSettingsUpdateCheckingCancellationAfterGate(
            with: commitGate
        )
        await preparationGate.open()
        await reviewBackend.waitForSettingsUpdate()
        let stop = Task { @MainActor in await store.stop() }

        await commitGate.open()
        await stop.value
        await restart.value

        #expect(store.serverState == .stopped)
        #expect(store.settings.selectedModel == "deferred-during-commit")
        #expect(await reviewBackend.settingsSnapshot().model == "deferred-during-commit")
        #expect(await reviewBackend.recordedCommands().filter {
            if case .applySettings = $0 { true } else { false }
        }.count == 1)
        #expect(store.settings.lastErrorMessage == nil)
    }

    @Test func staleRuntimeFailureCannotTearDownFreshGeneration() async throws {
        let backend = TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let staleHandle = try #require(backend.lastPreparedRuntimeHandle)
        await store.restart()
        let currentHandle = try #require(backend.lastPreparedRuntimeHandle)

        store.requestRuntimeFailure(handle: staleHandle, cause: "Stale stream failure.")

        #expect(currentHandle !== staleHandle)
        #expect(store.serverState == .running)
        #expect(currentHandle.closePurposes.isEmpty)
        await store.stop()
    }

    @Test func explicitStopSupersedesFailurePresentationButRetainsCleanupCause() async throws {
        let backend = TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let handle = try #require(backend.lastPreparedRuntimeHandle)
        let closeGate = AsyncGate()
        handle.holdClose(with: closeGate)

        store.requestRuntimeFailure(handle: handle, cause: "Injected runtime failure.")
        #expect(handle.closeAdmissionCallCount == 1)
        await handle.waitForClose()
        let expected = "Review runtime stopped unexpectedly: Injected runtime failure."
        #expect(store.serverState == .failed(expected))

        let stop = Task { @MainActor in await store.stop() }
        try await waitForTeardownFinalState(.stopped, store: store)
        await closeGate.open()
        await stop.value

        #expect(store.serverState == .stopped)
        #expect(handle.closePurposes == [.runtimeFailure])
        #expect(handle.waitUntilClosedCallCount == 1)
    }
}

@MainActor
private func waitForCutoverStatus(
    _ expected: CodexReviewSettingsService.RuntimeCutoverStatus,
    service: CodexReviewSettingsService
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while service.runtimeCutoverStatus != expected {
        guard clock.now < deadline else {
            throw CancellationError()
        }
        await Task.yield()
    }
}

@MainActor
private func waitForTeardownFinalState(
    _ expected: ReviewRuntimeTeardownIntent.FinalState,
    store: CodexReviewStore
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while store.runtimeTeardownFinalState != expected {
        guard clock.now < deadline else {
            throw CancellationError()
        }
        await Task.yield()
    }
}
