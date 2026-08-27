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
        guard case .replacing(let replacement, _) = store.runtimeState else {
            Issue.record("Expected an admitted runtime replacement.")
            return
        }
        var replacementOutcomes = replacement.outcomes().makeAsyncIterator()
        let staleReplacement = try #require(backend.lastPreparedRuntimeHandle)
        store.requestRuntimeTeardown(intent: .explicitStop)
        #expect(await replacementOutcomes.next() == .superseded(.stop))
        await backend.waitForRuntimePreparationCancellation()

        #expect(firstHandle.closePurposes == [.restartSameAccount])
        #expect(staleReplacement.activateCallCount == 0)
        #expect(store.serverURL == endpoint)

        await preparationGate.open()
        await store.stop()
        _ = await restart.value

        #expect(store.serverState == .stopped)
        #expect(store.serverURL == nil)
        #expect(staleReplacement.closeAdmissionCallCount == 1)
        #expect(staleReplacement.closePurposes == [.restartSameAccount])
        #expect(staleReplacement.waitUntilClosedCallCount == 1)
        #expect(mcpOwner.stopCallCount == 1)
        #expect(store.settings.lastErrorMessage == nil)
    }

    @Test func accountRecycleSupersedesHeldReplacementAndClosesStaleRuntimeOnce() async throws {
        let endpoint = try #require(URL(string: "http://127.0.0.1:19432/mcp"))
        let mcpOwner = TestingMCPServerLifecycleOwner(serverURL: endpoint)
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let sourceHandle = try #require(backend.lastPreparedRuntimeHandle)

        let preparationGate = AsyncGate()
        backend.holdRuntimePreparation(with: preparationGate)
        let restart = Task { @MainActor in await store.restart() }
        await backend.waitForRuntimePreparation()
        guard case .replacing(let replacement, _) = store.runtimeState else {
            Issue.record("Expected an admitted runtime replacement.")
            return
        }
        var replacementOutcomes = replacement.outcomes().makeAsyncIterator()
        let staleReplacement = try #require(backend.lastPreparedRuntimeHandle)

        let recycle = Task { @MainActor in
            await store.recycleRuntimeAfterAccountChange()
        }
        #expect(await replacementOutcomes.next() == .superseded(.start))
        await backend.waitForRuntimePreparationCancellation()
        await preparationGate.open()
        _ = await recycle.value
        _ = await restart.value

        let currentHandle = try #require(backend.lastPreparedRuntimeHandle)
        #expect(currentHandle !== sourceHandle)
        #expect(currentHandle !== staleReplacement)
        #expect(sourceHandle.closePurposes == [.restartSameAccount])
        #expect(sourceHandle.waitUntilClosedCallCount == 1)
        #expect(staleReplacement.closePurposes == [.restartSameAccount])
        #expect(staleReplacement.waitUntilClosedCallCount == 1)
        #expect(backend.startRequests == [false, true, false])
        #expect(mcpOwner.stopCallCount == 1)
        #expect(store.serverState == .running)
        #expect(store.serverURL == endpoint)
        await store.stop()
    }

    @Test func runtimeFailureSupersedesHeldReplacementBeforeCancellation() async throws {
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend()
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()

        let preparationGate = AsyncGate()
        backend.holdRuntimePreparation(with: preparationGate)
        let restart = Task { @MainActor in await store.restart() }
        await backend.waitForRuntimePreparation()
        guard case .replacing(let replacement, _) = store.runtimeState else {
            Issue.record("Expected an admitted runtime replacement.")
            return
        }
        var replacementOutcomes = replacement.outcomes().makeAsyncIterator()
        let staleReplacement = try #require(backend.lastPreparedRuntimeHandle)

        store.requestRuntimeTeardown(intent: .unexpectedFailure("Injected failure."))
        #expect(await replacementOutcomes.next() == .superseded(.runtimeFailure))
        await backend.waitForRuntimePreparationCancellation()
        await preparationGate.open()
        await store.waitUntilStopped()
        _ = await restart.value

        #expect(staleReplacement.closePurposes == [.restartSameAccount])
        #expect(staleReplacement.waitUntilClosedCallCount == 1)
        #expect(store.serverState == .failed(
            "Review runtime stopped unexpectedly: Injected failure."
        ))
        await store.stop()
    }

    @Test func concurrentManualRestartsJoinOneReplacementFactoryAndGeneration() async throws {
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend()
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let sourceGeneration = store.runtimeLifecycleAdmissionGeneration

        let preparationGate = AsyncGate()
        backend.holdRuntimePreparation(with: preparationGate)
        let firstRestart = Task { @MainActor in await store.restart() }
        await backend.waitForRuntimePreparation()
        guard case .replacing(let firstReplacement, _) = store.runtimeState else {
            Issue.record("Expected the first runtime replacement admission.")
            return
        }
        let replacementGeneration = store.runtimeLifecycleAdmissionGeneration
        let secondCallerEntered = AsyncGate()
        let secondRestart = Task { @MainActor in
            await secondCallerEntered.open()
            await store.restart()
        }
        await secondCallerEntered.wait()

        #expect(replacementGeneration == sourceGeneration + 1)
        #expect(store.runtimeLifecycleAdmissionGeneration == replacementGeneration)
        #expect(backend.startRequests == [false, true])
        await preparationGate.open()
        _ = await secondRestart.value
        _ = await firstRestart.value

        #expect(store.serverState == .running)
        guard case .running(let currentGeneration, _, _) = store.runtimeState else {
            Issue.record("Expected one published replacement runtime.")
            return
        }
        #expect(firstReplacement.replacementGeneration == currentGeneration)
        #expect(store.runtimeLifecycleAdmissionGeneration == replacementGeneration)
        #expect(backend.startRequests == [false, true])
        #expect(store.settingsService.runtimeCutoverStatus == .active)
        #expect(store.settings.isLoading == false)
        #expect(store.settings.lastErrorMessage == nil)
        await store.stop()
    }

    @Test func cancellingOuterRestartCallerCannotCancelOwnedReplacement() async throws {
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend()
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()

        let preparationGate = AsyncGate()
        backend.holdRuntimePreparation(with: preparationGate)
        let caller = Task { @MainActor in await store.restart() }
        await backend.waitForRuntimePreparation()
        guard case .replacing(let replacement, _) = store.runtimeState else {
            Issue.record("Expected an owned runtime replacement.")
            return
        }
        var outcomes = replacement.outcomes().makeAsyncIterator()

        caller.cancel()
        await preparationGate.open()
        await caller.value

        #expect(await outcomes.next() == .running(replacement.replacementGeneration))
        #expect(store.serverState == .running)
        #expect(backend.startRequests == [false, true])

        await store.restart()

        #expect(store.serverState == .running)
        #expect(
            store.runtimeLifecycleAdmissionGeneration
                == replacement.replacementGeneration.successor().rawValue
        )
        #expect(backend.startRequests == [false, true, true])
        await store.stop()
    }

    @Test func sourceCloseFailureReplaysAndConsumesOnceWhileReplacementPublishes() async throws {
        let expectedFailure = ReviewRuntimeCloseFailure.connection("Injected source close failure.")
        let newerSettingsError = "Newer settings failure."
        let reviewBackend = FakeCodexReviewBackend()
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let sourceHandle = try #require(backend.lastPreparedRuntimeHandle)
        sourceHandle.failClose(with: expectedFailure)
        await reviewBackend.failNextSettingsUpdate(message: newerSettingsError)
        backend.runOnNextRuntimePublication { [store] in
            await store.updateSettingsModel("newer-model")
        }

        let preparationGate = AsyncGate()
        backend.holdRuntimePreparation(with: preparationGate)
        let caller = Task { @MainActor in await store.restart() }
        await backend.waitForRuntimePreparation()
        guard case .replacing(let replacement, _) = store.runtimeState else {
            Issue.record("Expected a replacement after source close.")
            return
        }
        var firstReceipt = replacement.sourceCloseResults().makeAsyncIterator()
        var replayedReceipt = replacement.sourceCloseResults().makeAsyncIterator()

        #expect(await firstReceipt.next() == .failed(expectedFailure))
        #expect(await replayedReceipt.next() == .failed(expectedFailure))
        #expect(sourceHandle.closeAdmissionCallCount == 1)
        #expect(sourceHandle.closePurposes == [.restartSameAccount])
        #expect(sourceHandle.waitUntilClosedCallCount == 1)

        await preparationGate.open()
        await caller.value

        #expect(store.serverState == .running)
        #expect(backend.startRequests == [false, true])
        #expect(store.settings.lastErrorMessage == newerSettingsError)
        #expect(replacement.consumeSourceCloseFailure() == nil)
        await store.stop()
    }

    @Test func cancelledRestartWaitsForSupersedingSourceCloseReceipt() async throws {
        let expectedFailure = ReviewRuntimeCloseFailure.connection("Injected superseding close failure.")
        let reviewBackend = FakeCodexReviewBackend(settings: .init(model: "initial-model"))
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let sourceHandle = try #require(backend.lastPreparedRuntimeHandle)
        sourceHandle.failClose(with: expectedFailure)

        let writeGate = AsyncGate()
        await reviewBackend.holdNextSettingsUpdate(with: writeGate)
        let oldWrite = Task { @MainActor in await store.updateSettingsModel("held-before-replacement") }
        await reviewBackend.waitForSettingsUpdate()

        let restart = Task { @MainActor in await store.restart() }
        try await waitForCutoverStatus(.draining, service: store.settingsService)
        restart.cancel()
        let stop = Task { @MainActor in await store.stop() }

        await writeGate.open()
        await oldWrite.value
        await restart.value
        await stop.value

        #expect(sourceHandle.closePurposes == [.restartSameAccount])
        #expect(sourceHandle.waitUntilClosedCallCount == 1)
        #expect(store.settings.lastErrorMessage == nil)
    }

    @Test func stopJoinsPostPublicationReplacementWithoutLatePublication() async throws {
        let endpoint = try #require(URL(string: "http://127.0.0.1:19433/mcp"))
        let mcpOwner = TestingMCPServerLifecycleOwner(serverURL: endpoint)
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()

        backend.holdRuntimePublication()
        let firstRestart = Task { @MainActor in await store.restart() }
        await backend.waitForRuntimePublicationEntry()
        let publishedHandle = try #require(backend.lastPreparedRuntimeHandle)
        guard case .replacing(let replacement, _) = store.runtimeState else {
            Issue.record("Expected replacement ownership through publication completion.")
            return
        }
        var outcomes = replacement.outcomes().makeAsyncIterator()
        let secondCallerEntered = AsyncGate()
        let secondRestart = Task { @MainActor in
            await secondCallerEntered.open()
            await store.restart()
        }
        await secondCallerEntered.wait()

        let stop = Task { @MainActor in await store.stop() }
        await publishedHandle.waitForClose()
        #expect(await outcomes.next() == .superseded(.stop))
        await stop.value
        await firstRestart.value
        await secondRestart.value

        #expect(store.serverState == .stopped)
        #expect(store.serverURL == nil)
        #expect(backend.startRequests == [false, true])
        #expect(publishedHandle.activateCallCount == 1)
        #expect(publishedHandle.closeAdmissionCallCount == 1)
        #expect(publishedHandle.closePurposes == [.stop])
        #expect(publishedHandle.waitUntilClosedCallCount == 1)
        #expect(mcpOwner.stopCallCount == 1)
    }

    @Test func runtimeFailureRecognizesPostPublicationReplacementHandle() async throws {
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend()
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()

        backend.holdRuntimePublication()
        let restart = Task { @MainActor in await store.restart() }
        await backend.waitForRuntimePublicationEntry()
        let publishedHandle = try #require(backend.lastPreparedRuntimeHandle)

        store.requestRuntimeFailure(
            handle: publishedHandle,
            cause: "Injected post-publication failure."
        )
        await publishedHandle.waitForClose()
        await store.waitUntilStopped()
        await restart.value

        #expect(store.serverState == .failed(
            "Review runtime stopped unexpectedly: Injected post-publication failure."
        ))
        #expect(store.serverURL == nil)
        #expect(backend.startRequests == [false, true])
        #expect(publishedHandle.closeAdmissionCallCount == 1)
        #expect(publishedHandle.closePurposes == [.runtimeFailure])
        #expect(publishedHandle.waitUntilClosedCallCount == 1)
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

    @Test func registeredWorkCloseJoinsOneTaskAndReplaysOneResult() async throws {
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(
                reviewBackend: FakeCodexReviewBackend()
            )
        )
        let entered = AsyncGate()
        let release = AsyncGate()
        let work = Task { @MainActor in
            await store.performRegisteredStoreWork(
                kind: .testing("held work")
            ) { _ in
                await entered.open()
                await release.waitIgnoringCancellation()
            }
        }
        await entered.wait()

        let reason = ReviewCancellation.system(message: "Store work closed.")
        let firstClose = Task { @MainActor in
            await store.closeRegisteredStoreWork(reason: reason)
        }
        try await waitForStoreWorkStatus(.closing, store: store)
        let secondClose = Task { @MainActor in
            await store.closeRegisteredStoreWork(reason: reason)
        }

        #expect(store.storeWorkRegistry.closeTaskCreationCount == 1)
        #expect(store.storeWorkRegistry.activeOrdinals == [1])
        #expect(store.startRegisteredStoreWork(
            kind: .testing("rejected"),
            operation: { _ in }
        ) == nil)

        await release.open()
        await work.value
        let firstResult = await firstClose.value
        let secondResult = await secondClose.value
        let replayedResult = await store.closeRegisteredStoreWork(reason: reason)

        #expect(firstResult == .success)
        #expect(secondResult == firstResult)
        #expect(replayedResult == firstResult)
        #expect(store.storeWorkRegistryStatus == .closed)
        #expect(store.storeWorkRegistry.closeTaskCreationCount == 1)
        #expect(store.storeWorkRegistry.activeOrdinals.isEmpty)
        await #expect(throws: CodexReviewAPI.Error.self) {
            _ = try await store.startReview(
                sessionID: "closed-session",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
    }

    @Test func registeredWorkCloseJoinsCancelledSettingsMutationAndRejectsLaterWrite() async throws {
        let reviewBackend = FakeCodexReviewBackend(settings: .init(model: "initial-model"))
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        )
        let updateGate = AsyncGate()
        await reviewBackend.holdNextSettingsUpdate(with: updateGate)
        let update = Task { @MainActor in
            await store.updateSettingsModel("admitted-model")
        }
        await reviewBackend.waitForSettingsUpdate()
        update.cancel()

        let closeCompletion = StoreWorkCompletion()
        let close = Task { @MainActor in
            let result = await store.closeRegisteredStoreWork(
                reason: .system(message: "Store work owner closed.")
            )
            await closeCompletion.complete()
            return result
        }
        try await waitForStoreWorkStatus(.closing, store: store)

        #expect(store.storeWorkRegistry.activeOrdinals == [1])
        #expect(await closeCompletion.isComplete() == false)
        await updateGate.open()
        await update.value
        #expect(await close.value == .success)

        let admittedWriteCount = await reviewBackend.recordedCommands().filter {
            if case .applySettings = $0 { true } else { false }
        }.count
        await store.updateSettingsModel("rejected-model")
        let finalWriteCount = await reviewBackend.recordedCommands().filter {
            if case .applySettings = $0 { true } else { false }
        }.count

        #expect(admittedWriteCount == 1)
        #expect(finalWriteCount == admittedWriteCount)
        #expect(store.storeWorkRegistry.activeOrdinals.isEmpty)
    }

    @Test func registeredWorkCloseJoinsAuthenticationMutationAndRejectsLaterRefresh() async throws {
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend()
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        let refreshGate = AsyncGate()
        backend.holdAuthRefresh(with: refreshGate)
        let refresh = Task { @MainActor in
            await store.refreshAuthentication()
        }
        await backend.waitForAuthRefresh()

        let closeCompletion = StoreWorkCompletion()
        let close = Task { @MainActor in
            let result = await store.closeRegisteredStoreWork(
                reason: .system(message: "Store work owner closed.")
            )
            await closeCompletion.complete()
            return result
        }
        try await waitForStoreWorkStatus(.closing, store: store)

        #expect(store.storeWorkRegistry.activeOrdinals == [1])
        #expect(await closeCompletion.isComplete() == false)
        await refreshGate.open()
        await refresh.value
        #expect(await close.value == .success)
        #expect(backend.authRefreshCallCount == 1)

        await store.refreshAuthentication()
        await #expect(throws: CodexReviewAPI.Error.self) {
            try await store.signOutActiveAccount()
        }

        #expect(backend.authRefreshCallCount == 1)
        #expect(store.storeWorkRegistry.activeOrdinals.isEmpty)
    }

    @Test func registeredWorkFailuresStayInAdmissionOrder() async throws {
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(
                reviewBackend: FakeCodexReviewBackend()
            )
        )
        let firstEntered = AsyncGate()
        let firstRelease = AsyncGate()
        let secondEntered = AsyncGate()
        let secondRelease = AsyncGate()
        let first = Task { @MainActor in
            try? await store.performThrowingRegisteredStoreWork(
                kind: .testing("first work")
            ) { _ in
                await firstEntered.open()
                await firstRelease.waitIgnoringCancellation()
                throw StoreWorkTestFailure.first
            }
        }
        await firstEntered.wait()
        let second = Task { @MainActor in
            try? await store.performThrowingRegisteredStoreWork(
                kind: .testing("second work")
            ) { _ in
                await secondEntered.open()
                await secondRelease.waitIgnoringCancellation()
                throw StoreWorkTestFailure.second
            }
        }
        await secondEntered.wait()

        let close = Task { @MainActor in
            await store.closeRegisteredStoreWork(
                reason: .system(message: "Store work closed.")
            )
        }
        try await waitForStoreWorkStatus(.closing, store: store)
        await secondRelease.open()
        await firstRelease.open()
        await first.value
        await second.value
        let result = await close.value
        let failures = try #require(result.failures)

        #expect(failures.first.ordinal == 1)
        #expect(failures.first.kind == .testing("first work"))
        #expect(failures.first.cause == .operation("first work failed"))
        #expect(failures.additionalInOrdinalOrder.count == 1)
        #expect(failures.additionalInOrdinalOrder[0].ordinal == 2)
        #expect(failures.additionalInOrdinalOrder[0].kind == .testing("second work"))
        #expect(failures.additionalInOrdinalOrder[0].cause == .operation("second work failed"))
        #expect(await store.closeRegisteredStoreWork(
            reason: .system(message: "ignored replay reason")
        ) == result)
    }

    @Test func registeredWorkCloseAwaitsReviewWorkerWithExactReason() async throws {
        let backend = FakeCodexReviewBackend()
        let startGate = AsyncGate()
        await backend.holdStartReviewIgnoringCancellation(with: startGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        await store.start()
        let review = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        try await backend.waitForStartReview(timeout: .seconds(2))
        let awaitCompletion = StoreWorkCompletion()
        let awaiter = Task { @MainActor in
            let result = try await store.awaitReview(
                sessionID: "session-1",
                jobID: "job-1"
            )
            await awaitCompletion.complete()
            return result
        }
        try await waitForReviewWaiterCount(2, jobID: "job-1", store: store)
        let reason = ReviewCancellation.system(message: "Store work owner closed.")

        let close = Task { @MainActor in
            await store.closeRegisteredStoreWork(reason: reason)
        }
        try await waitForStoreWorkStatus(.closing, store: store)
        try await waitForReviewWorkerCancellation(jobID: "job-1", store: store)
        #expect(store.reviewWorkerTasks["job-1"]?.isCancelled == true)
        #expect(store.storeWorkRegistry.activeOrdinals.isEmpty == false)
        #expect(await awaitCompletion.isComplete() == false)

        await startGate.open()
        try await backend.waitForInterruptReview(timeout: .seconds(2))
        await backend.yield(.cancelled(reason.message))
        #expect(await close.value == .success)
        let result = try await review.value
        let awaitedResult = try await awaiter.value

        #expect(result.core.lifecycle.status == .cancelled)
        #expect(awaitedResult.core.lifecycle.status == .cancelled)
        #expect(result.core.lifecycle.cancellation == reason)
        #expect(store.reviewWorkerTasks["job-1"] == nil)
        #expect(store.storeWorkRegistry.activeOrdinals.isEmpty)
        await store.stop()
    }

    @Test func registeredWorkCloseDoesNotReturnTimedStartBeforeWorkerFinalization() async throws {
        let backend = FakeCodexReviewBackend()
        let startGate = AsyncGate()
        await backend.holdStartReviewIgnoringCancellation(with: startGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        await store.start()
        let reviewCompletion = StoreWorkCompletion()
        let review = Task { @MainActor in
            let result = try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .seconds(30)
            )
            await reviewCompletion.complete()
            return result
        }
        try await backend.waitForStartReview(timeout: .seconds(2))
        try await waitForReviewWaiterCount(1, jobID: "job-1", store: store)
        let reason = ReviewCancellation.system(message: "Store work owner closed.")

        let close = Task { @MainActor in
            await store.closeRegisteredStoreWork(reason: reason)
        }
        try await waitForStoreWorkStatus(.closing, store: store)
        try await waitForReviewWorkerCancellation(jobID: "job-1", store: store)
        let returnedBeforeWorkerFinalization = await waitForStoreWorkCompletion(
            reviewCompletion,
            timeout: .milliseconds(500)
        )

        #expect(returnedBeforeWorkerFinalization == false)
        await startGate.open()
        try await backend.waitForInterruptReview(timeout: .seconds(2))
        await backend.yield(.cancelled(reason.message))
        #expect(await close.value == .success)
        let result = try await review.value

        #expect(result.core.lifecycle.status == .cancelled)
        #expect(result.core.lifecycle.cancellation == reason)
        #expect(store.reviewWorkerTasks["job-1"] == nil)
        #expect(store.storeWorkRegistry.activeOrdinals.isEmpty)
        await store.stop()
    }

    @Test func registeredWorkCloseAppliesPreEntryCancellationPolicy() async throws {
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(
                reviewBackend: FakeCodexReviewBackend()
            )
        )
        var skippedOperationRan = false
        var finalizerRan = false
        var finalizedOperationRan = false
        let skippedTask = try #require(store.startRegisteredStoreWork(
            kind: .testing("skip before entry")
        ) { _ in
            skippedOperationRan = true
        })
        let finalizedTask = try #require(store.startRegisteredStoreWork(
            kind: .testing("finalize before entry"),
            cancelledBeforeEntry: .runFinalizer { _ in
                finalizerRan = true
            }
        ) { _ in
            finalizedOperationRan = true
        })
        let closeOperation = store.storeWorkRegistry.beginClosing(onAdmissionClosed: {})
        let result = await closeOperation.task.value
        store.storeWorkRegistry.completeClosing(closeOperation, result: result)
        await skippedTask.value
        await finalizedTask.value

        #expect(result == .success)
        #expect(skippedOperationRan == false)
        #expect(finalizerRan)
        #expect(finalizedOperationRan == false)
        #expect(store.storeWorkRegistry.activeOrdinals.isEmpty)
    }

    @Test func individualCancellationAppliesRegisteredWorkPreEntryPolicy() async {
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(
                reviewBackend: FakeCodexReviewBackend()
            )
        )
        var skippedOperationRan = false
        var finalizerRunCount = 0
        var finalizedOperationRan = false
        let skippedTask = store.startRegisteredStoreWork(
            kind: .testing("individually cancelled skip")
        ) { _ in
            skippedOperationRan = true
        }
        let finalizedTask = store.startRegisteredStoreWork(
            kind: .testing("individually cancelled finalizer"),
            cancelledBeforeEntry: .runFinalizer { _ in
                finalizerRunCount += 1
            }
        ) { _ in
            finalizedOperationRan = true
        }
        skippedTask?.cancel()
        finalizedTask?.cancel()

        await skippedTask?.value
        await finalizedTask?.value

        #expect(skippedOperationRan == false)
        #expect(finalizerRunCount == 1)
        #expect(finalizedOperationRan == false)
        #expect(store.storeWorkRegistryStatus == .open)
        #expect(store.storeWorkRegistry.activeOrdinals.isEmpty)

        var throwingOperationRan = false
        let throwingTask = Task { @MainActor in
            try await store.performThrowingRegisteredStoreWork(
                kind: .testing("individually cancelled throwing work")
            ) { _ in
                throwingOperationRan = true
            }
        }
        throwingTask.cancel()

        await #expect(throws: CancellationError.self) {
            try await throwingTask.value
        }
        #expect(throwingOperationRan == false)
        #expect(store.storeWorkRegistryStatus == .open)
        #expect(store.storeWorkRegistry.activeOrdinals.isEmpty)
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

    @Test func cleanupRecoveryClaimsHeldUnexpectedTeardownOnceAndConcurrentCallerJoins() async throws {
        let backend = TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let sourceHandle = try #require(backend.lastPreparedRuntimeHandle)
        let sourceGeneration = ReviewRuntimeGeneration(
            rawValue: store.runtimeLifecycleAdmissionGeneration
        )
        let closeGate = AsyncGate()
        sourceHandle.holdClose(with: closeGate)
        let successorPreparationGate = AsyncGate()
        backend.holdRuntimePreparation(with: successorPreparationGate)

        #expect(store.requestRuntimeFailure(
            handle: sourceHandle,
            cause: "Notification stream closed."
        ))
        await sourceHandle.waitForClose()

        let admitted = store.requestRuntimeCleanupRecovery(
            sourceHandle: sourceHandle,
            sourceGeneration: sourceGeneration,
            cause: "Cleanup closed the transport."
        )
        let joined = store.requestRuntimeCleanupRecovery(
            sourceHandle: sourceHandle,
            sourceGeneration: sourceGeneration,
            cause: "Concurrent cleanup closed the transport."
        )
        let successorGeneration = sourceGeneration.successor().successor()
        #expect(admitted == .admitted(
            sourceGeneration: sourceGeneration,
            successorGeneration: successorGeneration
        ))
        #expect(joined == .joined(
            sourceGeneration: sourceGeneration,
            successorGeneration: successorGeneration
        ))
        #expect(backend.startRequests == [false])
        guard case .acquiring(let generation, _, let successorTask) = store.runtimeState else {
            Issue.record("Expected one admitted cleanup-recovery acquisition.")
            return
        }
        #expect(generation == successorGeneration)

        await closeGate.open()
        await backend.waitForRuntimePreparation()
        #expect(backend.startRequests == [false, false])
        await successorPreparationGate.open()
        await successorTask.value

        #expect(store.serverState == .running)
        #expect(backend.startRequests == [false, false])
        await store.stop()
    }

    @Test func cleanupRecoveryCanClaimCompletedUnexpectedTeardown() async throws {
        let backend = TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let sourceHandle = try #require(backend.lastPreparedRuntimeHandle)
        let sourceGeneration = ReviewRuntimeGeneration(
            rawValue: store.runtimeLifecycleAdmissionGeneration
        )

        #expect(store.requestRuntimeFailure(
            handle: sourceHandle,
            cause: "Notification stream closed."
        ))
        await store.waitUntilStopped()
        #expect(store.serverState == .failed(
            "Review runtime stopped unexpectedly: Notification stream closed."
        ))
        let successorPreparationGate = AsyncGate()
        backend.holdRuntimePreparation(with: successorPreparationGate)

        let admission = store.requestRuntimeCleanupRecovery(
            sourceHandle: sourceHandle,
            sourceGeneration: sourceGeneration,
            cause: "Cleanup closed the transport."
        )
        let successorGeneration = sourceGeneration.successor().successor()
        #expect(admission == .admitted(
            sourceGeneration: sourceGeneration,
            successorGeneration: successorGeneration
        ))
        guard case .acquiring(let generation, _, let successorTask) = store.runtimeState else {
            Issue.record("Expected late cleanup recovery to acquire one successor.")
            return
        }
        #expect(generation == successorGeneration)

        await backend.waitForRuntimePreparation()
        await successorPreparationGate.open()
        await successorTask.value

        #expect(store.serverState == .running)
        #expect(backend.startRequests == [false, false])
        await store.stop()
    }

    @Test func explicitStopSuppressesCleanupRecoveryForItsExactSource() async throws {
        let backend = TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let sourceHandle = try #require(backend.lastPreparedRuntimeHandle)
        let sourceGeneration = ReviewRuntimeGeneration(
            rawValue: store.runtimeLifecycleAdmissionGeneration
        )
        let closeGate = AsyncGate()
        sourceHandle.holdClose(with: closeGate)

        store.requestRuntimeTeardown(intent: .explicitStop)
        await sourceHandle.waitForClose()

        #expect(store.requestRuntimeCleanupRecovery(
            sourceHandle: sourceHandle,
            sourceGeneration: sourceGeneration,
            cause: "Cleanup closed the transport."
        ) == .suppressed(.explicitStop))
        #expect(backend.startRequests == [false])

        await closeGate.open()
        await store.waitUntilStopped()
        #expect(store.serverState == .stopped)
        #expect(backend.startRequests == [false])
    }

    @Test func cleanupRecoveryRejectsSourceFromReplacedGeneration() async throws {
        let backend = TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let staleHandle = try #require(backend.lastPreparedRuntimeHandle)
        let staleGeneration = ReviewRuntimeGeneration(
            rawValue: store.runtimeLifecycleAdmissionGeneration
        )
        await store.restart()
        let currentHandle = try #require(backend.lastPreparedRuntimeHandle)

        #expect(store.requestRuntimeCleanupRecovery(
            sourceHandle: staleHandle,
            sourceGeneration: staleGeneration,
            cause: "Late cleanup failure."
        ) == .suppressed(.staleSource))
        #expect(currentHandle !== staleHandle)
        #expect(store.serverState == .running)
        #expect(backend.startRequests == [false, true])
        await store.stop()
    }

    @Test func failedCleanupRecoverySuccessorCannotBeRetriedByLateSourceFailure() async throws {
        let backend = TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let sourceHandle = try #require(backend.lastPreparedRuntimeHandle)
        let sourceGeneration = ReviewRuntimeGeneration(
            rawValue: store.runtimeLifecycleAdmissionGeneration
        )
        let preparationGate = AsyncGate()
        backend.holdRuntimePreparation(with: preparationGate)
        backend.failNextRuntimePreparation(message: "Replacement preparation failed.")

        let admission = store.requestRuntimeCleanupRecovery(
            sourceHandle: sourceHandle,
            sourceGeneration: sourceGeneration,
            cause: "Cleanup closed the transport."
        )
        let successorGeneration = sourceGeneration.successor().successor()
        #expect(admission == .admitted(
            sourceGeneration: sourceGeneration,
            successorGeneration: successorGeneration
        ))
        guard case .acquiring(_, _, let successorTask) = store.runtimeState else {
            Issue.record("Expected cleanup recovery successor acquisition.")
            return
        }
        await backend.waitForRuntimePreparation()
        await preparationGate.open()
        await successorTask.value

        #expect(store.serverState == .failed("Replacement preparation failed."))
        #expect(store.requestRuntimeCleanupRecovery(
            sourceHandle: sourceHandle,
            sourceGeneration: sourceGeneration,
            cause: "Late cleanup failure."
        ) == .suppressed(.successorAlreadyFinished))
        #expect(backend.startRequests == [false, false])
        await store.stop()
    }

    @Test func cleanupRecoveryJoinsReplacementOfItsAdmittedSuccessor() async throws {
        let backend = TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let sourceHandle = try #require(backend.lastPreparedRuntimeHandle)
        let sourceGeneration = ReviewRuntimeGeneration(
            rawValue: store.runtimeLifecycleAdmissionGeneration
        )
        let preparationGate = AsyncGate()
        backend.holdRuntimePreparation(with: preparationGate)

        let admitted = store.requestRuntimeCleanupRecovery(
            sourceHandle: sourceHandle,
            sourceGeneration: sourceGeneration,
            cause: "Cleanup closed the transport."
        )
        let firstSuccessorGeneration = sourceGeneration.successor().successor()
        #expect(admitted == .admitted(
            sourceGeneration: sourceGeneration,
            successorGeneration: firstSuccessorGeneration
        ))
        await backend.waitForRuntimePreparation()

        let restart = Task { @MainActor in
            await store.restart()
        }
        let replacementGeneration = firstSuccessorGeneration.successor()
        try #require(await waitForRuntimeGeneration(
            replacementGeneration,
            store: store
        ))
        #expect(store.requestRuntimeCleanupRecovery(
            sourceHandle: sourceHandle,
            sourceGeneration: sourceGeneration,
            cause: "Concurrent late cleanup failure."
        ) == .joined(
            sourceGeneration: sourceGeneration,
            successorGeneration: replacementGeneration
        ))

        await preparationGate.open()
        await restart.value

        #expect(store.serverState == .running)
        #expect(store.runtimeLifecycleAdmissionGeneration == replacementGeneration.rawValue)
        await store.stop()
    }

    @Test func cleanupRecoveryJoinsAccountRecycleReplacementGeneration() async throws {
        let backend = TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let sourceHandle = try #require(backend.lastPreparedRuntimeHandle)
        let sourceGeneration = ReviewRuntimeGeneration(
            rawValue: store.runtimeLifecycleAdmissionGeneration
        )
        let preparationGate = AsyncGate()
        backend.holdRuntimePreparation(with: preparationGate)

        _ = store.requestRuntimeCleanupRecovery(
            sourceHandle: sourceHandle,
            sourceGeneration: sourceGeneration,
            cause: "Cleanup closed the transport."
        )
        await backend.waitForRuntimePreparation()

        let recycle = Task { @MainActor in
            await store.recycleRuntimeAfterAccountChange()
        }
        let recycledGeneration = sourceGeneration.successor().successor().successor()
        try #require(await waitForRuntimeGeneration(
            recycledGeneration,
            store: store
        ))
        #expect(store.requestRuntimeCleanupRecovery(
            sourceHandle: sourceHandle,
            sourceGeneration: sourceGeneration,
            cause: "Concurrent late cleanup failure."
        ) == .joined(
            sourceGeneration: sourceGeneration,
            successorGeneration: recycledGeneration
        ))

        await preparationGate.open()
        await recycle.value

        #expect(store.serverState == .running)
        #expect(store.runtimeLifecycleAdmissionGeneration == recycledGeneration.rawValue)
        await store.stop()
    }
}

private enum StoreWorkTestFailure: LocalizedError, Sendable {
    case first
    case second

    var errorDescription: String? {
        switch self {
        case .first:
            "first work failed"
        case .second:
            "second work failed"
        }
    }
}

private actor StoreWorkCompletion {
    private var completed = false

    func complete() {
        completed = true
    }

    func isComplete() -> Bool {
        completed
    }
}

@MainActor
private func waitForStoreWorkCompletion(
    _ completion: StoreWorkCompletion,
    timeout: Duration
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while await completion.isComplete() == false {
        guard clock.now < deadline else {
            return false
        }
        await Task.yield()
    }
    return true
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

@MainActor
private func waitForRuntimeGeneration(
    _ expected: ReviewRuntimeGeneration,
    store: CodexReviewStore
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while store.runtimeLifecycleAdmissionGeneration != expected.rawValue {
        guard clock.now < deadline else {
            return false
        }
        await Task.yield()
    }
    return true
}

@MainActor
private func waitForStoreWorkStatus(
    _ expected: ReviewStoreWorkRegistryStatus,
    store: CodexReviewStore
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while store.storeWorkRegistryStatus != expected {
        guard clock.now < deadline else {
            throw CancellationError()
        }
        await Task.yield()
    }
}

@MainActor
private func waitForReviewWorkerCancellation(
    jobID: String,
    store: CodexReviewStore
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while store.reviewWorkerTasks[jobID]?.isCancelled != true {
        guard clock.now < deadline else {
            throw CancellationError()
        }
        await Task.yield()
    }
}

@MainActor
private func waitForReviewWaiterCount(
    _ count: Int,
    jobID: String,
    store: CodexReviewStore
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while store.reviewTerminalWaiters[jobID]?.count != count {
        guard clock.now < deadline else {
            throw CancellationError()
        }
        await Task.yield()
    }
}
