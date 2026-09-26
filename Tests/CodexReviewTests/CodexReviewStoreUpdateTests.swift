import Foundation
import Testing
@_spi(ApplicationHostSupport) @testable import CodexReview
import CodexReviewTesting

@Suite("Codex runtime updates", .serialized)
@MainActor
struct CodexReviewStoreUpdateTests {
    @Test func deferredUpdateWaitsForCleanupAndRetainsQueuedCalls() async throws {
        let reviews = FakeCodexReviewBackend()
        let mcp = TestingMCPServerLifecycleOwner()
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviews, mcpServerLifecycle: mcp)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let originalRuntime = try #require(backend.lastPreparedRuntimeHandle)
        let cleanup = AsyncGate()
        await reviews.holdCleanupReview(with: cleanup)
        let first = Task { try await store.startReview(sessionID: "client", request: request("first")) }
        try await reviews.waitForStartReview(timeout: .seconds(2))
        var installations = 0
        let installing = AsyncGate()
        let releaseInstall = AsyncGate()
        let update = Task {
            try await store.updateCodex(when: .afterCurrentReviews) {
                installations += 1
                #expect(originalRuntime.waitUntilClosedCallCount == 1)
                await installing.open()
                await releaseInstall.wait()
            }
        }
        try #require(await waitUntil { store.codexUpdateState == .waitingForReviews })
        var queuedReturned = false
        let queued = Task {
            defer { queuedReturned = true }
            return try await store.startReview(sessionID: "client", request: request("queued"))
        }
        try #require(await waitUntil { store.jobs.contains { $0.cwd == "/tmp/queued" } })
        let queuedID = try #require(store.jobs.first { $0.cwd == "/tmp/queued" }?.id)
        await reviews.yield(.completed(summary: "Done", result: "No findings."))
        await reviews.waitForCleanupReview()
        #expect(installations == 0)
        #expect(originalRuntime.closePurposes.isEmpty)
        await cleanup.open()
        #expect(try await first.value.core.lifecycle.status == .succeeded)
        await installing.wait()
        #expect(queuedReturned == false)
        #expect(try store.readReview(sessionID: "client", jobID: queuedID).core.lifecycle.status == .queued)
        #expect(mcp.stopCallCount == 0)
        let duplicate = Task {
            try await store.updateCodex(when: .immediately) { installations += 100 }
        }
        await releaseInstall.open()
        try await update.value
        try await duplicate.value
        #expect(installations == 1)
        #expect(backend.startRequests == [false, true])
        #expect(mcp.preparedServers.count == 1)
        #expect(mcp.activatedServers.count == 1)
        try #require(await waitUntil { store.job(id: queuedID)?.core.run.threadID != nil })
        await reviews.yield(.completed(summary: "Done", result: "No findings."))
        #expect(try await queued.value.jobID == queuedID)
        #expect(store.codexUpdateState == .idle)
        await store.stop()
    }

    @Test func failedInstallRestartsRuntimeAndResumesQueueButKeepsError() async throws {
        let reviews = FakeCodexReviewBackend()
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviews)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        var queuedID: String?
        do {
            try await store.updateCodex(when: .afterCurrentReviews) {
                queuedID = try await store.startReview(sessionID: "client", request: request("queued"), waitTimeout: .zero).jobID
                throw UpdateTestError.install
            }
            Issue.record("Expected installation failure")
        } catch { #expect(error.localizedDescription.contains("install failed")) }
        #expect(store.serverState == .running)
        #expect(store.codexUpdateState == .failed("install failed"))
        let id = try #require(queuedID)
        try #require(await waitUntil { store.job(id: id)?.core.run.threadID != nil })
        await reviews.yield(.completed(summary: "Done", result: "No findings."))
        #expect(try await store.awaitReview(sessionID: "client", jobID: id).core.lifecycle.status == .succeeded)
        await store.stop()
    }

    @Test func failedRestartRetainsQueueAndRetryDoesNotInstallAgain() async throws {
        let reviews = FakeCodexReviewBackend()
        let mcp = TestingMCPServerLifecycleOwner()
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviews, mcpServerLifecycle: mcp)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        backend.failNextRuntimePreparation(message: "restart failed")
        var queuedID: String?
        var installs = 0
        do {
            try await store.updateCodex(when: .afterCurrentReviews) {
                installs += 1
                queuedID = try await store.startReview(sessionID: "client", request: request("queued"), waitTimeout: .zero).jobID
            }
            Issue.record("Expected restart failure")
        } catch { #expect(error.localizedDescription.contains("restart failed")) }
        let id = try #require(queuedID)
        #expect(try store.readReview(sessionID: "client", jobID: id).core.lifecycle.status == .queued)
        #expect(mcp.stopCallCount == 0)
        await store.restart()
        #expect(store.serverState == .running)
        #expect(installs == 1)
        try #require(await waitUntil { store.job(id: id)?.core.run.threadID != nil })
        await reviews.yield(.completed(summary: "Done", result: "No findings."))
        #expect(try await store.awaitReview(sessionID: "client", jobID: id).core.lifecycle.status == .succeeded)
        await store.stop()
    }

    @Test func failedSourceClosePreventsInstallationAndKeepsRecoverableRuntime() async throws {
        let backend = TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)
        runtime.failClose(with: .process("close failed"))
        var installs = 0
        do {
            try await store.updateCodex(when: .afterCurrentReviews) { installs += 1 }
            Issue.record("Expected close failure")
        } catch { #expect(error.localizedDescription.contains("close failed")) }
        #expect(installs == 0)
        #expect(store.unclosedCodexUpdateRuntime?.handle === runtime)
        #expect(backend.startRequests == [false])
        await store.restart()
        #expect(store.serverState == .running)
        #expect(store.unclosedCodexUpdateRuntime == nil)
        #expect(installs == 0)
        await store.stop()
    }

    @Test func shutdownWaitsForInstallationThenCancelsQueuedJobs() async throws {
        let backend = TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let entered = AsyncGate()
        let release = AsyncGate()
        let update = Task {
            try await store.updateCodex(when: .immediately) {
                await entered.open()
                await release.wait()
            }
        }
        await entered.wait()
        let queued = try await store.startReview(sessionID: "client", request: request("queued"), waitTimeout: .zero)
        var stopped = false
        let shutdown = Task { await store.shutdown(); stopped = true }
        try #require(await waitUntil { store.applicationShutdownRequested })
        #expect(stopped == false)
        await release.open()
        try await update.value
        await shutdown.value
        #expect(store.serverState == .stopped)
        #expect(store.job(id: queued.jobID)?.core.lifecycle.status == .cancelled)
    }

    @Test func immediateUpdateCancelsExecutingReviewButKeepsQueuedReview() async throws {
        let reviews = FakeCodexReviewBackend()
        await reviews.holdStartReview(with: AsyncGate())
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviews)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let active = Task { try await store.startReview(sessionID: "owner", request: request("active")) }
        try await reviews.waitForStartReview(timeout: .seconds(2))
        var queuedID: String?
        try await store.updateCodex(when: .immediately) {
            queuedID = try await store.startReview(sessionID: "owner", request: request("queued"), waitTimeout: .zero).jobID
            #expect(try await active.value.core.lifecycle.status == .cancelled)
        }
        let id = try #require(queuedID)
        #expect(store.job(id: id)?.isTerminal == false)
        await store.stop()
    }

    @Test func shutdownCancelsDeferredUpdateWithoutWaitingForReviewCompletion() async throws {
        let reviews = FakeCodexReviewBackend()
        await reviews.holdStartReview(with: AsyncGate())
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviews)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let active = Task { try await store.startReview(sessionID: "owner", request: request("active")) }
        try await reviews.waitForStartReview(timeout: .seconds(2))
        var installs = 0
        let update = Task { try await store.updateCodex(when: .afterCurrentReviews) { installs += 1 } }
        try #require(await waitUntil { store.codexUpdateState == .waitingForReviews })
        await store.shutdown()
        do { try await update.value; Issue.record("Expected update cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(installs == 0)
        #expect(try await active.value.core.lifecycle.status == .cancelled)
    }

    @Test func manualRestartJoinsInstallationInsteadOfReplacingAgain() async throws {
        let backend = TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let entered = AsyncGate()
        let release = AsyncGate()
        let update = Task { try await store.updateCodex(when: .immediately) {
            await entered.open()
            await release.wait()
        } }
        await entered.wait()
        var restartReturned = false
        let restart = Task { await store.restart(); restartReturned = true }
        await Task.yield()
        #expect(restartReturned == false)
        await release.open()
        try await update.value
        await restart.value
        #expect(backend.startRequests == [false, true])
        await store.stop()
    }

    @Test func accountChangesAndUpdateExecuteInOrderWithoutDispatchingQueueBetweenThem() async throws {
        let backend = TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let firstEntered = AsyncGate()
        let firstRelease = AsyncGate()
        var events: [String] = []
        let first = Task { try await store.performRuntimeAccountChange { _ in
            events.append("first")
            await firstEntered.open()
            await firstRelease.wait()
        } }
        await firstEntered.wait()
        let installEntered = AsyncGate()
        let installRelease = AsyncGate()
        let update = Task { try await store.updateCodex(when: .immediately) {
            events.append("install")
            await installEntered.open()
            await installRelease.wait()
        } }
        try #require(await waitUntil { store.codexUpdateTask != nil })
        #expect(events == ["first"])
        await firstRelease.open()
        try await first.value
        await installEntered.wait()
        let queued = try await store.startReview(sessionID: "owner", request: request("queued"), waitTimeout: .zero)
        let second = Task { try await store.performRuntimeAccountChange { store in
            events.append("second")
            #expect(store.job(id: queued.jobID)?.core.lifecycle.status == .queued)
            await store.closeActiveReviewSessions(reason: .system(message: "Account switched."))
        } }
        try #require(await waitUntil { store.runtimeAccountOperations.isEmpty == false })
        await installRelease.open()
        try await update.value
        try await second.value
        #expect(events == ["first", "install", "second"])
        #expect(store.job(id: queued.jobID)?.core.lifecycle.status == .cancelled)
        await store.stop()
    }

    @Test func failedRuntimeDuringDeferredUpdateDoesNotDiscardQueuedJobs() async throws {
        let reviews = FakeCodexReviewBackend()
        let mcp = TestingMCPServerLifecycleOwner()
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviews, mcpServerLifecycle: mcp)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)
        let active = Task { try await store.startReview(sessionID: "owner", request: request("active")) }
        try await reviews.waitForStartReview(timeout: .seconds(2))
        var installs = 0
        let update = Task { try await store.updateCodex(when: .afterCurrentReviews) { installs += 1 } }
        try #require(await waitUntil { store.codexUpdateState == .waitingForReviews })
        let queued = try await store.startReview(sessionID: "owner", request: request("queued"), waitTimeout: .zero)
        #expect(store.requestRuntimeFailure(handle: runtime, cause: "process exited"))
        await reviews.finishEvents(throwing: UpdateTestError.install)
        try await update.value
        #expect(installs == 1)
        #expect(try await active.value.core.lifecycle.terminal == .interrupted(.transport(message: "process exited")))
        #expect(store.job(id: queued.jobID)?.isTerminal == false)
        #expect(mcp.stopCallCount == 0)
        await store.stop()
    }

    @Test func publicationFailureRetainsQueueAndCanBeRetried() async throws {
        let backend = TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        backend.runOnNextRuntimePublication {
            if let handle = backend.lastPreparedRuntimeHandle {
                #expect(store.requestRuntimeFailure(handle: handle, cause: "publication failed"))
            }
        }
        var queuedID: String?
        do {
            try await store.updateCodex(when: .immediately) {
                queuedID = try await store.startReview(sessionID: "owner", request: request("queued"), waitTimeout: .zero).jobID
            }
            Issue.record("Expected publication failure")
        } catch { #expect(error.localizedDescription.contains("publication failed")) }
        let id = try #require(queuedID)
        #expect(store.job(id: id)?.core.lifecycle.status == .queued)
        #expect(store.serverState == .failed("publication failed"))
        backend.runOnNextRuntimePublication {
            if let handle = backend.lastPreparedRuntimeHandle {
                #expect(store.requestRuntimeFailure(handle: handle, cause: "retry publication failed"))
            }
        }
        await store.restart()
        await store.waitUntilStopped()
        #expect(store.serverState == .failed("retry publication failed"))
        #expect(store.job(id: id)?.core.lifecycle.status == .queued)
        await store.restart()
        #expect(store.serverState == .running)
        await store.stop()
    }

    @Test func updateFromStoppedRuntimeRetainsQueueWhenPublicationFails() async throws {
        let backend = TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        backend.runOnNextRuntimePublication {
            if let handle = backend.lastPreparedRuntimeHandle {
                #expect(store.requestRuntimeFailure(handle: handle, cause: "initial publication failed"))
            }
        }
        var queuedID: String?
        do {
            try await store.updateCodex(when: .immediately) {
                queuedID = try await store.startReview(sessionID: "owner", request: request("queued"), waitTimeout: .zero).jobID
            }
            Issue.record("Expected initial publication failure")
        } catch { #expect(error.localizedDescription.contains("initial publication failed")) }
        let id = try #require(queuedID)
        #expect(store.job(id: id)?.core.lifecycle.status == .queued)
        #expect(store.serverState == .failed("initial publication failed"))
        await store.start()
        #expect(store.serverState == .running)
        await store.stop()
    }

    @Test(arguments: [false, true])
    func stopCancelsQueuedCallsAfterUpdateMCPStartupFails(failActivation: Bool) async throws {
        let mcp = FailingUpdateMCPServer(failActivation: failActivation)
        let backend = TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend(), mcpServerLifecycle: mcp)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        var requestTask: Task<CodexReviewAPI.Read.Result, any Error>?
        do {
            try await store.updateCodex(when: .immediately) {
                requestTask = Task { try await store.startReview(sessionID: "owner", request: request("queued")) }
                try #require(await waitUntil { store.jobs.isEmpty == false })
            }
            Issue.record("Expected MCP startup failure")
        } catch { #expect(error.localizedDescription.contains("MCP startup failed")) }
        let accepted = try #require(store.jobs.first)
        #expect(accepted.core.lifecycle.status == .queued)
        await store.stop()
        #expect(accepted.core.lifecycle.status == .cancelled)
        #expect(try await requestTask?.value.core.lifecycle.status == .cancelled)
        #expect(store.queuedReviewStarts.isEmpty)
    }

    @Test(arguments: [false, true])
    func stopOwnsQueueBeforeRuntimePublication(starting: Bool) async throws {
        let backend = TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        let release = AsyncGate()
        backend.holdRuntimePreparation(with: release)
        let start: Task<Void, Never>? = starting ? Task { await store.start() } : nil
        if starting { await backend.waitForRuntimePreparation() }
        store.suspendReviewStarts()
        let queued = Task { try await store.startReview(sessionID: "owner", request: request("queued")) }
        try #require(await waitUntil { store.jobs.isEmpty == false })
        let stop = Task { await store.stop() }
        try #require(await waitUntil { store.queuedReviewStarts.isEmpty })
        await release.open()
        await start?.value
        await stop.value
        #expect(try await queued.value.core.lifecycle.status == .cancelled)
    }

    @Test func stopCancelsUpdateJoinWhileEarlierAccountOperationRemainsPending() async throws {
        let backend = TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let accountEntered = AsyncGate()
        let accountRelease = AsyncGate()
        let account = Task { try await store.performRuntimeAccountChange { _ in
            await accountEntered.open()
            await accountRelease.wait()
        } }
        await accountEntered.wait()
        var installs = 0
        let update = Task { try await store.updateCodex(when: .afterCurrentReviews) { installs += 1 } }
        #expect(await waitUntil { store.codexUpdateState == .waitingForReviews })
        var stopped = false
        let stop = Task { await store.stop(); stopped = true }
        let stoppedBeforeAccountFinished = await waitUntil { stopped }
        await accountRelease.open()
        try await account.value
        await stop.value
        do { try await update.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(stoppedBeforeAccountFinished)
        #expect(installs == 0)
    }

    @Test func cancelledUpdateCanLeaveItsPrecedingRuntimeTaskWithItsOwner() async throws {
        let backend = TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        let release = AsyncGate()
        backend.holdRuntimePreparation(with: release)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        let startup = Task { await store.start() }
        await backend.waitForRuntimePreparation()
        var updateReturned = false
        let update = Task {
            defer { updateReturned = true }
            try await store.updateCodex(when: .afterCurrentReviews) { Issue.record("Unexpected install") }
        }
        #expect(await waitUntil { store.codexUpdateTask != nil })
        store.codexUpdateTask?.cancel()
        let returnedBeforeRuntimeStarted = await waitUntil { updateReturned }
        await release.open()
        await startup.value
        do { try await update.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(returnedBeforeRuntimeStarted)
        await store.stop()
    }

    @Test func pendingStopPreventsQueueDispatchAfterInstallation() async throws {
        let reviews = FakeCodexReviewBackend()
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviews)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let entered = AsyncGate()
        let release = AsyncGate()
        let update = Task { try await store.updateCodex(when: .immediately) {
            await entered.open()
            await release.wait()
        } }
        await entered.wait()
        let queued = try await store.startReview(sessionID: "owner", request: request("queued"), waitTimeout: .zero)
        var stopRequested = false
        let stop = Task { stopRequested = true; await store.stop() }
        #expect(await waitUntil { stopRequested })
        await release.open()
        try await update.value
        await stop.value
        #expect(store.job(id: queued.jobID)?.core.lifecycle.status == .cancelled)
        #expect(store.job(id: queued.jobID)?.core.lifecycle.startedAt == nil)
        #expect(await reviews.recordedCommands().contains { if case .startReview = $0 { true } else { false } } == false)
    }

    @Test func recoveryRequestsCloseForFailureAfterRuntimePublication() async throws {
        let reviews = FakeCodexReviewBackend()
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviews)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let accountEntered = AsyncGate()
        let accountRelease = AsyncGate()
        var account: Task<Void, any Error>?
        var queuedID: String?
        do {
            try await store.updateCodex(when: .immediately) {
                queuedID = try await store.startReview(sessionID: "owner", request: request("queued"), waitTimeout: .zero).jobID
                account = Task { try await store.performRuntimeAccountChange { _ in
                    await accountEntered.open()
                    await accountRelease.wait()
                } }
                #expect(await waitUntil { store.runtimeAccountOperations.isEmpty == false })
                throw UpdateTestError.install
            }
            Issue.record("Expected install failure")
        } catch { #expect(error.localizedDescription.contains("install failed")) }
        await accountEntered.wait()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)
        #expect(runtime.closePurposes.isEmpty)
        #expect(store.requestRuntimeFailure(handle: runtime, cause: "late runtime failure"))
        await accountRelease.open()
        try await account?.value
        let id = try #require(queuedID)
        #expect(store.job(id: id)?.core.lifecycle.status == .queued)
        await store.restart()
        #expect(store.serverState == .running)
        #expect(runtime.closePurposes == [.restartSameAccount])
        try await reviews.waitForStartReview(timeout: .seconds(2))
        await reviews.yield(.completed(summary: "Done", result: "No findings."))
        #expect(try await store.awaitReview(sessionID: "owner", jobID: id).core.lifecycle.status == .succeeded)
        await store.stop()
    }

    private func request(_ name: String) -> CodexReviewAPI.Start.Request {
        .init(cwd: "/tmp/\(name)", target: .uncommittedChanges)
    }
}

private enum UpdateTestError: LocalizedError {
    case install
    var errorDescription: String? { "install failed" }
}

@MainActor
private func waitUntil(condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while condition() == false {
        if clock.now >= deadline { return false }
        await Task.yield()
    }
    return true
}

@MainActor
private final class FailingUpdateMCPServer: MCPServerLifecycleOwner {
    private let failActivation: Bool
    private let owner = TestingMCPServerLifecycleOwner()

    init(failActivation: Bool) { self.failActivation = failActivation }

    func prepare() async throws -> PreparedMCPServer {
        if failActivation == false { throw CodexReviewAPI.Error.io("MCP startup failed") }
        return try await owner.prepare()
    }

    func activate(_ preparation: PreparedMCPServer) async throws -> MCPServerPublicationSnapshot {
        throw CodexReviewAPI.Error.io("MCP startup failed")
    }

    func stop() async throws { try await owner.stop() }
}
