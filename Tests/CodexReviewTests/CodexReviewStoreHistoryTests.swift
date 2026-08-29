import Foundation
import Testing
@_spi(Testing) @testable import CodexReview
@_spi(ApplicationHostSupport) import CodexReview
import CodexReviewTesting

@Suite("review history store", .serialized)
@MainActor
struct CodexReviewStoreHistoryTests {
    @Test func loadOnceRestoresCompactApplicationHistoryWithoutSessionAuthority() async throws {
        let startedAt = Date(timeIntervalSince1970: 100)
        let history = ReviewHistoryPersistenceProbe(records: [
            try historyRecord(
                id: "old-review",
                cwd: "/tmp/project",
                workspaceSortOrder: 4,
                sortOrder: 7,
                target: .baseBranch("main"),
                lifecycle: .init(
                    status: .failed,
                    startedAt: startedAt,
                    terminal: .interrupted(.previousProcessExit)
                ),
                output: .init(summary: "Interrupted by previous process.")
            ),
        ])
        let store = makeStore(history: history)

        await store.loadReviewHistoryIfNeeded()
        await store.loadReviewHistoryIfNeeded()

        #expect(store.historyAvailability == .available)
        #expect(await history.loadCallCount() == 1)
        let job = try #require(store.job(id: "old-review"))
        #expect(job.origin == .restoredHistory)
        #expect(job.target == .baseBranch("main"))
        #expect(job.logEntries.count == 1)
        #expect(job.logEntries[0].timestamp == startedAt)
        #expect(try store.readReview(jobID: job.id).elapsedSeconds == nil)
        #expect(store.listReviews(sessionID: "history:old-review").items.isEmpty)
        #expect(throws: CodexReviewAPI.Error.self) {
            try store.readReview(
                sessionID: "history:old-review",
                jobID: job.id
            )
        }
    }

    @Test func startHeaderCompletesBeforeBackendDispatch() async throws {
        let entered = AsyncGate()
        let release = AsyncGate()
        let history = ReviewHistoryPersistenceProbe(
            startedWriteEntered: entered,
            startedWriteRelease: release
        )
        let backend = FakeCodexReviewBackend()
        let store = makeStore(
            history: history,
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )

        let review = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .commit(
                    sha: "abc123",
                    title: "Persist me"
                ))
            )
        }
        await entered.wait()

        #expect(store.jobs.isEmpty)
        #expect(await backend.recordedCommands().contains {
            if case .startReview = $0 { true } else { false }
        } == false)

        await release.open()
        await backend.waitForStartReview()
        let startedRecord = try #require(await history.startedRecords().first)
        #expect(startedRecord.target == .commit(sha: "abc123", title: "Persist me"))
        #expect(startedRecord.startedAt.timeIntervalSince1970 > 0)

        await backend.yield(.completed(summary: "Done", result: "No findings."))
        #expect(try await review.value.core.lifecycle.status == .succeeded)
        let terminalRecord = try #require(await history.terminalRecords().first)
        #expect(terminalRecord.canonicalReview == "No findings.")
        #expect(terminalRecord.parsedResult?.state == .noFindings)
    }

    @Test func loadFailureKeepsRuntimeAvailableButBlocksReviewAdmission() async {
        let history = ReviewHistoryPersistenceProbe(loadFailure: "cannot open history")
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend()
        )
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            historyPersistence: history
        )

        await store.start()

        #expect(store.serverState == .running)
        #expect(store.historyAvailability == .failed("cannot open history"))
        await #expect(throws: CodexReviewAPI.Error.self) {
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await store.shutdown()
    }

    @Test func secondBlockedStartReservesDistinctOrderBeforeEitherDispatches() async throws {
        let historyEntered = AsyncGate()
        let historyRelease = AsyncGate()
        let history = ReviewHistoryPersistenceProbe(
            startedWriteEntered: historyEntered,
            startedWriteRelease: historyRelease
        )
        let backend = FakeCodexReviewBackend()
        let ids = SequentialHistoryTestIDs(["job-1", "job-2"])
        let store = makeStore(
            history: history,
            backend: backend,
            idGenerator: .init(next: { ids.next() })
        )

        let first = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .zero
            )
        }
        await historyEntered.wait()
        let second = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                waitTimeout: .zero
            )
        }
        try #require(await waitForHistoryTestCondition {
            store.historyStartReceipts.count == 2
        })
        let reserved = store.historyStartReceipts.values
            .map(\.started)
            .sorted { $0.sortOrder < $1.sortOrder }
        #expect(reserved.map(\.id) == ["job-1", "job-2"])
        #expect(reserved.map(\.sortOrder) == [0, 1])
        #expect(Set(reserved.map(\.workspaceSortOrder)) == Set([0.0]))

        let close = Task { @MainActor in await store.closeSession("session-1") }
        await historyRelease.open()
        await close.value
        _ = await first.result
        _ = await second.result
        #expect(await backend.recordedCommands().contains {
            if case .startReview = $0 { true } else { false }
        } == false)
    }

    @Test func sessionCloseDuringStartWriteDurablyInterruptsWithoutDispatch() async throws {
        let entered = AsyncGate()
        let release = AsyncGate()
        let history = ReviewHistoryPersistenceProbe(
            startedWriteEntered: entered,
            startedWriteRelease: release
        )
        let backend = FakeCodexReviewBackend()
        let store = makeStore(
            history: history,
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )
        let start = Task { @MainActor in
            do {
                return Result<CodexReviewAPI.Read.Result, any Error>.success(try await store.startReview(
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                ))
            } catch {
                return Result<CodexReviewAPI.Read.Result, any Error>.failure(error)
            }
        }
        await entered.wait()
        let close = Task { @MainActor in
            await store.closeSession("session-1")
        }

        await release.open()
        await close.value
        #expect(await start.value.isFailure)
        #expect(await backend.recordedCommands().contains {
            if case .startReview = $0 { true } else { false }
        } == false)
        let terminal = try #require(await history.terminalRecords().first)
        guard case .interrupted(.requested(let cancellation)) = terminal.terminal else {
            Issue.record("Expected requested interruption")
            return
        }
        #expect(cancellation.source == .sessionClosed)
        #expect(store.job(id: "job-1")?.origin == .restoredHistory)
    }

    @Test func runtimeStopDuringStartWriteJoinsDurableInterruption() async throws {
        let entered = AsyncGate()
        let release = AsyncGate()
        let history = ReviewHistoryPersistenceProbe(
            startedWriteEntered: entered,
            startedWriteRelease: release
        )
        let backend = FakeCodexReviewBackend()
        let store = makeStore(
            history: history,
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )
        await store.start()
        let start = Task { @MainActor in
            try? await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await entered.wait()
        let stop = Task { @MainActor in await store.stop() }

        await release.open()
        await stop.value
        _ = await start.value
        #expect(store.serverState == .stopped)
        #expect(await backend.recordedCommands().contains {
            if case .startReview = $0 { true } else { false }
        } == false)
        #expect(await history.terminalRecords().count == 1)
    }

    @Test func modelChangeDuringStartWriteDispatchesCapturedModel() async throws {
        let entered = AsyncGate()
        let release = AsyncGate()
        let history = ReviewHistoryPersistenceProbe(
            startedWriteEntered: entered,
            startedWriteRelease: release
        )
        let backend = FakeCodexReviewBackend()
        let store = makeStore(
            history: history,
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )
        let start = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .zero
            )
        }
        await entered.wait()
        let startReceipt = try #require(store.historyStartReceipts["job-1"])
        let capturedModel = startReceipt.started.model
        await store.updateSettingsModel("changed-model")
        await release.open()
        let running = try await start.value
        await backend.waitForStartReview()

        let dispatchedRequests = await backend.recordedCommands().compactMap { command in
            if case .startReview(let request) = command {
                return request
            }
            return nil
        }
        #expect(dispatchedRequests.map(\.model) == [capturedModel])

        await backend.yield(.completed(summary: "Done", result: "No findings."))
        _ = try await store.awaitReview(
            sessionID: "session-1",
            jobID: running.jobID
        )
    }

    @Test func startWriteFailureRejectsWithoutPublishingOrDispatching() async {
        let history = ReviewHistoryPersistenceProbe(startedWriteFailure: "disk full")
        let backend = FakeCodexReviewBackend()
        let store = makeStore(history: history, backend: backend)

        await #expect(throws: CodexReviewAPI.Error.self) {
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }

        #expect(store.jobs.isEmpty)
        #expect(store.workspaces.isEmpty)
        #expect(store.historyAvailability == .failed("disk full"))
        #expect(await backend.recordedCommands().contains {
            if case .startReview = $0 { true } else { false }
        } == false)

        await #expect(throws: CodexReviewAPI.Error.self) {
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        #expect(await history.startedRecords().count == 0)
    }

    @Test func unrelatedReorderAndDeleteDuringStartWriteDoNotCancelDispatch() async throws {
        let first = try historyRecord(
            id: "old-1",
            cwd: "/tmp/old-1",
            workspaceSortOrder: 0,
            lifecycle: .init(
                status: .failed,
                startedAt: Date(timeIntervalSince1970: 1),
                endedAt: Date(timeIntervalSince1970: 2),
                terminal: .failed(message: "old")
            ),
            output: .init(summary: "old")
        )
        let second = try historyRecord(
            id: "old-2",
            cwd: "/tmp/old-2",
            workspaceSortOrder: 1,
            lifecycle: .init(
                status: .failed,
                startedAt: Date(timeIntervalSince1970: 1),
                endedAt: Date(timeIntervalSince1970: 2),
                terminal: .failed(message: "old")
            ),
            output: .init(summary: "old")
        )
        let entered = AsyncGate()
        let release = AsyncGate()
        let history = ReviewHistoryPersistenceProbe(
            records: [first, second],
            startedWriteEntered: entered,
            startedWriteRelease: release
        )
        let backend = FakeCodexReviewBackend()
        let store = makeStore(
            history: history,
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )
        await store.loadReviewHistoryIfNeeded()
        let start = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/new", target: .uncommittedChanges),
                waitTimeout: .zero
            )
        }
        await entered.wait()
        let reorder = Task { @MainActor in
            await store.reorderWorkspaces(cwds: [first.cwd], toIndex: 0)
        }
        let deletion = Task { @MainActor in
            await store.deleteReviewHistory(id: second.id)
        }

        await release.open()
        let running = try await start.value
        _ = await reorder.value
        await deletion.value
        await backend.waitForStartReview()
        #expect(await backend.recordedCommands().contains {
            if case .startReview = $0 { true } else { false }
        })

        await backend.yield(.completed(summary: "Done", result: "No findings."))
        _ = try await store.awaitReview(
            sessionID: "session-1",
            jobID: running.jobID
        )
    }

    @Test func terminalWriteSanitizesPartialOutputAndBlocksWorkerFinalization() async throws {
        let entered = AsyncGate()
        let release = AsyncGate()
        let history = ReviewHistoryPersistenceProbe(
            terminalWriteEntered: entered,
            terminalWriteRelease: release
        )
        let backend = FakeCodexReviewBackend()
        let store = makeStore(
            history: history,
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )

        let review = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await backend.waitForStartReview()
        await backend.yield(.message("partial assistant output"))
        await backend.yield(.failed("review failed"))
        await entered.wait()

        let terminal = try #require(await history.terminalRecords().first)
        #expect(terminal.terminal == .failed(message: "review failed"))
        #expect(terminal.summary == "review failed")
        #expect(terminal.canonicalReview == nil)
        #expect(terminal.parsedResult == nil)
        #expect(store.reviewWorkerTasks["job-1"] != nil)

        await release.open()
        let result = try await review.value
        #expect(result.core.lifecycle.status == .failed)
        #expect(store.reviewWorkerTasks["job-1"] == nil)
    }

    @Test func terminalFailureKeepsRealResultAndBlocksLaterStarts() async throws {
        let history = ReviewHistoryPersistenceProbe(terminalWriteFailure: "write failed")
        let backend = FakeCodexReviewBackend()
        let store = makeStore(
            history: history,
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )

        let review = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await backend.waitForStartReview()
        await backend.yield(.completed(summary: "Done", result: "No findings."))

        let result = try await review.value
        #expect(result.core.lifecycle.status == .succeeded)
        #expect(result.core.reviewText == "No findings.")
        #expect(store.historyAvailability == .failed("write failed"))
        await #expect(throws: CodexReviewAPI.Error.self) {
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
    }

    @Test func cancelResponseWaitsForTerminalHistoryReceipt() async throws {
        let entered = AsyncGate()
        let release = AsyncGate()
        let completion = HistoryTestCompletion()
        let history = ReviewHistoryPersistenceProbe(
            terminalWriteEntered: entered,
            terminalWriteRelease: release
        )
        let backend = FakeCodexReviewBackend()
        let store = makeStore(
            history: history,
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )
        let running = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .zero
        )
        await backend.waitForStartReview()

        let cancel = Task { @MainActor in
            let result = try await store.cancelReview(
                jobID: running.jobID,
                sessionID: "session-1",
                cancellation: .mcpClient(message: "Stop")
            )
            await completion.complete()
            return result
        }
        try await backend.waitForInterruptReview(timeout: .seconds(2))
        await backend.yield(.cancelled("Stop"))
        await entered.wait()

        #expect(await completion.isComplete() == false)
        await release.open()
        #expect(try await cancel.value.cancelled)
        #expect(await completion.isComplete())
    }

    @Test func awaitReviewWaitsForTerminalHistoryReceipt() async throws {
        let entered = AsyncGate()
        let release = AsyncGate()
        let completion = HistoryTestCompletion()
        let history = ReviewHistoryPersistenceProbe(
            terminalWriteEntered: entered,
            terminalWriteRelease: release
        )
        let backend = FakeCodexReviewBackend()
        let store = makeStore(
            history: history,
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )
        let running = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .zero
        )
        await backend.waitForStartReview()
        let awaiting = Task { @MainActor in
            let result = try await store.awaitReview(
                sessionID: "session-1",
                jobID: running.jobID
            )
            await completion.complete()
            return result
        }

        await backend.yield(.completed(summary: "Done", result: "No findings."))
        await entered.wait()
        #expect(await completion.isComplete() == false)

        await release.open()
        #expect(try await awaiting.value.core.lifecycle.status == .succeeded)
        #expect(await completion.isComplete())
    }

    @Test func boundedAwaitKeepsTerminalResultBehindHistoryReceipt() async throws {
        let entered = AsyncGate()
        let release = AsyncGate()
        let completion = HistoryTestCompletion()
        let history = ReviewHistoryPersistenceProbe(
            terminalWriteEntered: entered,
            terminalWriteRelease: release
        )
        let backend = FakeCodexReviewBackend()
        let store = makeStore(
            history: history,
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )
        let running = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .zero
        )
        await backend.waitForStartReview()
        await backend.yield(.completed(summary: "Done", result: "No findings."))
        await entered.wait()

        let awaiting = Task { @MainActor in
            let result = try await store.awaitReview(
                sessionID: "session-1",
                jobID: running.jobID,
                timeout: .zero
            )
            await completion.complete()
            return result
        }
        try #require(await waitForHistoryTestCondition {
            store.reviewTerminalWaiters[running.jobID]?.count == 1
        })
        let timeoutTask = try #require(
            store.reviewTerminalWaiters[running.jobID]?.first?.timeoutTask
        )
        await timeoutTask.value

        #expect(await completion.isComplete() == false)
        #expect(store.reviewTerminalWaiters[running.jobID]?.count == 1)
        await release.open()
        #expect(try await awaiting.value.core.lifecycle.status == .succeeded)
        #expect(await completion.isComplete())
    }

    @Test func cancelledAwaitKeepsTerminalResultBehindHistoryFinality() async throws {
        let terminalWriteEntered = AsyncGate()
        let terminalWriteRelease = AsyncGate()
        let cleanupRelease = AsyncGate()
        let completion = HistoryTestCompletion()
        let history = ReviewHistoryPersistenceProbe(
            terminalWriteEntered: terminalWriteEntered,
            terminalWriteRelease: terminalWriteRelease
        )
        let backend = FakeCodexReviewBackend()
        await backend.holdCleanupReview(with: cleanupRelease)
        let store = makeStore(
            history: history,
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )
        let running = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .zero
        )
        await backend.waitForStartReview()

        let awaiting = Task { @MainActor in
            let result = try await store.awaitReview(
                sessionID: "session-1",
                jobID: running.jobID,
                timeout: .seconds(30)
            )
            await completion.complete()
            return result
        }
        try #require(await waitForHistoryTestCondition {
            store.reviewTerminalWaiters[running.jobID]?.count == 1
        })
        let timeoutTask = try #require(
            store.reviewTerminalWaiters[running.jobID]?.first?.timeoutTask
        )

        await backend.yield(.completed(summary: "Done", result: "No findings."))
        await terminalWriteEntered.wait()
        await backend.waitForCleanupReview()
        awaiting.cancel()
        try #require(await waitForHistoryTestCondition {
            timeoutTask.isCancelled
        })

        await terminalWriteRelease.open()
        try #require(await waitForHistoryTestCondition {
            store.persistedTerminalReviewIDs.contains(running.jobID)
        })
        #expect(await completion.isComplete() == false)
        #expect(store.reviewTerminalWaiters[running.jobID]?.count == 1)
        #expect(store.reviewWorkerTasks[running.jobID] != nil)

        await cleanupRelease.open()
        #expect(try await awaiting.value.core.lifecycle.status == .succeeded)
        #expect(await completion.isComplete())
        #expect(store.reviewTerminalWaiters[running.jobID] == nil)
        #expect(store.historyResultLeaseIDs[running.jobID] == nil)
        #expect(store.reviewWorkerTasks[running.jobID] == nil)
    }

    @Test func cancelledAwaitStillReturnsANonterminalSnapshot() async throws {
        let history = ReviewHistoryPersistenceProbe()
        let backend = FakeCodexReviewBackend()
        let store = makeStore(
            history: history,
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )
        let running = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .zero
        )
        await backend.waitForStartReview()

        let awaiting = Task { @MainActor in
            try await store.awaitReview(
                sessionID: "session-1",
                jobID: running.jobID,
                timeout: .seconds(30)
            )
        }
        try #require(await waitForHistoryTestCondition {
            store.reviewTerminalWaiters[running.jobID]?.count == 1
        })
        let timeoutTask = try #require(
            store.reviewTerminalWaiters[running.jobID]?.first?.timeoutTask
        )

        awaiting.cancel()
        let cancelledSnapshot = try await awaiting.value
        #expect(timeoutTask.isCancelled)
        #expect(cancelledSnapshot.core.lifecycle.status == .running)
        #expect(store.reviewTerminalWaiters[running.jobID] == nil)

        await backend.yield(.completed(summary: "Done", result: "No findings."))
        _ = try await store.awaitReview(
            sessionID: "session-1",
            jobID: running.jobID
        )
    }

    @Test func runtimeDetachWaitsForTerminalHistoryReceipt() async throws {
        let entered = AsyncGate()
        let release = AsyncGate()
        let history = ReviewHistoryPersistenceProbe(
            terminalWriteEntered: entered,
            terminalWriteRelease: release
        )
        let backend = FakeCodexReviewBackend()
        let store = makeStore(
            history: history,
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )
        let running = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .zero
        )
        await backend.waitForStartReview()
        await backend.yield(.completed(summary: "Done", result: "No findings."))
        await entered.wait()

        let detach = Task { @MainActor in
            await store.cancelAndDetachReviewWorkersForRuntimeStop(
                jobIDs: [running.jobID],
                reason: .system(message: "Runtime stopped")
            )
        }
        await Task.yield()
        #expect(store.reviewWorkerTasks[running.jobID] != nil)

        await release.open()
        await detach.value
        #expect(store.reviewWorkerTasks[running.jobID] == nil)
    }

    @Test func retentionResultReconcilesStoreMembership() async throws {
        let old = try historyRecord(
            id: "old-review",
            cwd: "/tmp/project",
            lifecycle: .init(
                status: .succeeded,
                startedAt: Date(timeIntervalSince1970: 1),
                endedAt: Date(timeIntervalSince1970: 2),
                terminal: .completed
            ),
            output: .init(
                summary: "Old",
                hasFinalReview: true,
                lastAgentMessage: "Old result",
                reviewResult: .parse(finalReviewText: "Old result")
            )
        )
        let history = ReviewHistoryPersistenceProbe(
            records: [old],
            terminalMutation: .init(removedReviewIDs: [old.id])
        )
        let backend = FakeCodexReviewBackend()
        let store = makeStore(
            history: history,
            backend: backend,
            idGenerator: .init(next: { "new-review" })
        )

        let review = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await backend.waitForStartReview()
        await backend.yield(.completed(summary: "New", result: "New result"))
        _ = try await review.value

        #expect(store.job(id: old.id) == nil)
        #expect(store.job(id: "new-review") != nil)
        #expect(store.jobs.count == 1)
    }

    @Test func retentionDefersLiveTerminalRemovalUntilWorkerAndAwaitResponseFinish() async throws {
        let cleanupRelease = AsyncGate()
        let history = ReviewHistoryPersistenceProbe(
            terminalMutations: [
                .init(),
                .init(removedReviewIDs: ["job-1"]),
            ]
        )
        let backend = FakeCodexReviewBackend()
        await backend.holdCleanupReview(with: cleanupRelease)
        let ids = SequentialHistoryTestIDs(["job-1", "job-2"])
        let store = makeStore(
            history: history,
            backend: backend,
            idGenerator: .init(next: { ids.next() })
        )

        let first = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/first", target: .uncommittedChanges),
            waitTimeout: .zero
        )
        await backend.waitForStartReview()
        let firstRun = try #require(store.reviewAttemptOwnerships[first.jobID]?.run)
        await backend.yield(
            .completed(summary: "First", result: "First result"),
            for: firstRun
        )
        try #require(await waitForHistoryTestCondition {
            store.persistedTerminalReviewIDs.contains(first.jobID)
        })

        let firstAwaitCompletion = HistoryTestCompletion()
        let firstAwait = Task { @MainActor in
            let result = try await store.awaitReview(
                sessionID: "session-1",
                jobID: first.jobID
            )
            await firstAwaitCompletion.complete()
            return result
        }

        let secondRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-2",
            threadID: "thread-2",
            turnID: "turn-2",
            reviewThreadID: "review-thread-2"
        )
        await backend.setNextRun(secondRun)
        let second = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/second", target: .uncommittedChanges),
            waitTimeout: .zero
        )
        try #require(await waitForHistoryTestCondition {
            store.reviewAttemptOwnerships[second.jobID]?.run == secondRun
        })
        await backend.yield(
            .completed(summary: "Second", result: "Second result"),
            for: secondRun
        )
        try #require(await waitForHistoryTestCondition {
            store.deferredHistoryRemovalIDs.contains(first.jobID)
        })

        #expect(try store.readReview(jobID: first.jobID).core.reviewText == "First result")
        #expect(store.job(id: first.jobID) != nil)
        #expect(await firstAwaitCompletion.isComplete() == false)

        await cleanupRelease.open()
        #expect(try await firstAwait.value.core.reviewText == "First result")
        try #require(await waitForHistoryTestCondition {
            store.job(id: first.jobID) == nil
        })
        _ = try await store.awaitReview(
            sessionID: "session-1",
            jobID: second.jobID
        )
    }

    @Test func deleteAllRemovesTerminalHistoryButPreservesActiveLiveReview() async throws {
        let restored = try historyRecord(
            id: "old-review",
            cwd: "/tmp/old",
            lifecycle: .init(
                status: .failed,
                startedAt: Date(timeIntervalSince1970: 1),
                endedAt: Date(timeIntervalSince1970: 2),
                terminal: .failed(message: "failed")
            ),
            output: .init(summary: "failed")
        )
        let history = ReviewHistoryPersistenceProbe(records: [restored])
        let backend = FakeCodexReviewBackend()
        let store = makeStore(
            history: history,
            backend: backend,
            idGenerator: .init(next: { "live-review" })
        )
        await store.loadReviewHistoryIfNeeded()

        let running = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/live", target: .uncommittedChanges),
            waitTimeout: .zero
        )
        await backend.waitForStartReview()
        await store.deleteAllReviewHistory()

        #expect(store.job(id: restored.id) == nil)
        #expect(store.job(id: running.jobID)?.isTerminal == false)
        #expect(await history.deleteAllCallCount() == 1)

        await backend.yield(.completed(summary: "Done", result: "No findings."))
        _ = try await store.awaitReview(
            sessionID: "session-1",
            jobID: running.jobID
        )
    }

    @Test func shutdownSavesOrderingAndClosesPersistenceExactlyOnce() async throws {
        let record = try historyRecord(
            id: "old-review",
            cwd: "/tmp/project",
            workspaceSortOrder: 3,
            sortOrder: 5,
            lifecycle: .init(
                status: .failed,
                startedAt: Date(timeIntervalSince1970: 1),
                endedAt: Date(timeIntervalSince1970: 2),
                terminal: .failed(message: "failed")
            ),
            output: .init(summary: "failed")
        )
        let history = ReviewHistoryPersistenceProbe(records: [record])
        let store = makeStore(history: history)
        await store.loadReviewHistoryIfNeeded()

        await store.shutdown()
        await store.shutdown()

        #expect(store.historyAvailability == .closed)
        #expect(await history.orderings().count == 1)
        #expect(await history.closeCallCount() == 1)
    }

    @Test func shutdownAbandonsDurableInvalidatedReviewWork() async throws {
        let startGate = AsyncGate()
        let history = ReviewHistoryPersistenceProbe()
        let backend = FakeCodexReviewBackend()
        await backend.holdStartReviewIgnoringCancellation(with: startGate)
        let store = makeStore(
            history: history,
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )
        await store.start()

        let reviewCompletion = HistoryTestCompletion()
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

        let shutdownCompletion = HistoryTestCompletion()
        let shutdown = Task { @MainActor in
            await store.shutdown()
            await shutdownCompletion.complete()
        }
        let completedBeforeWorkerReleased = await waitForHistoryTestCondition(
            timeout: .seconds(1)
        ) {
            await shutdownCompletion.isComplete()
        }

        #expect(completedBeforeWorkerReleased)
        #expect(await reviewCompletion.isComplete() == false)
        #expect(store.historyAvailability == .closed)
        #expect(store.reviewWorkerTasks["job-1"] == nil)
        #expect(store.runtimeStopDetachedReviewWorkerTasks["job-1"] != nil)
        #expect(await history.closeCallCount() == 1)
        #expect(await history.terminalRecords().count == 1)
        #expect(await history.mutationOperations() == ["started", "terminal", "ordering"])

        await startGate.open()
        try await backend.waitForInterruptReview(timeout: .seconds(2))
        await backend.yield(.cancelled("Review runtime stopped."))
        await shutdown.value
        let result = try await review.value

        #expect(result.core.lifecycle.status == .cancelled)
        #expect(store.runtimeStopDetachedReviewWorkerTasks["job-1"] == nil)
        #expect(await history.closeCallCount() == 1)
        #expect(await history.terminalRecords().count == 1)
        #expect(await history.mutationOperations() == ["started", "terminal", "ordering"])
    }

    @Test func workspaceReorderPersistsBeforeApplyingMemoryOrder() async throws {
        let first = try historyRecord(
            id: "first",
            cwd: "/tmp/first",
            workspaceSortOrder: 0,
            lifecycle: .init(
                status: .failed,
                startedAt: Date(timeIntervalSince1970: 1),
                terminal: .interrupted(.previousProcessExit)
            ),
            output: .init(summary: "first")
        )
        let second = try historyRecord(
            id: "second",
            cwd: "/tmp/second",
            workspaceSortOrder: 1,
            lifecycle: .init(
                status: .failed,
                startedAt: Date(timeIntervalSince1970: 1),
                terminal: .interrupted(.previousProcessExit)
            ),
            output: .init(summary: "second")
        )
        let entered = AsyncGate()
        let release = AsyncGate()
        let history = ReviewHistoryPersistenceProbe(
            records: [first, second],
            orderingWriteEntered: entered,
            orderingWriteRelease: release
        )
        let store = makeStore(history: history)
        await store.loadReviewHistoryIfNeeded()

        let reorder = Task { @MainActor in
            await store.reorderWorkspaces(
                cwds: [first.cwd],
                toIndex: 0
            )
        }
        await entered.wait()
        #expect(store.orderedWorkspaces.map(\.cwd) == [second.cwd, first.cwd])

        await release.open()
        _ = await reorder.value
        #expect(store.orderedWorkspaces.map(\.cwd) == [first.cwd, second.cwd])
        #expect(await history.orderings().count == 1)
    }

    @Test func jobReorderFailureKeepsMemoryOrderAndPublishesFailure() async throws {
        let first = try historyRecord(
            id: "first",
            cwd: "/tmp/project",
            sortOrder: 0,
            lifecycle: .init(
                status: .failed,
                startedAt: Date(timeIntervalSince1970: 1),
                terminal: .interrupted(.previousProcessExit)
            ),
            output: .init(summary: "first")
        )
        let second = try historyRecord(
            id: "second",
            cwd: "/tmp/project",
            sortOrder: 1,
            lifecycle: .init(
                status: .failed,
                startedAt: Date(timeIntervalSince1970: 1),
                terminal: .interrupted(.previousProcessExit)
            ),
            output: .init(summary: "second")
        )
        let history = ReviewHistoryPersistenceProbe(
            records: [first, second],
            orderingWriteFailure: "ordering failed"
        )
        let store = makeStore(history: history)
        await store.loadReviewHistoryIfNeeded()

        #expect(await store.reorderJob(
            id: first.id,
            inWorkspace: first.cwd,
            toIndex: 0
        ) == false)

        #expect(store.orderedJobs(inWorkspace: first.cwd).map(\.id) == [second.id, first.id])
        #expect(store.historyAvailability == .failed("ordering failed"))
    }

    @Test func mutationLaneOrdersReorderTerminalPruneAndDeleteApply() async throws {
        let old = try historyRecord(
            id: "old-review",
            cwd: "/tmp/old",
            workspaceSortOrder: 0,
            lifecycle: .init(
                status: .failed,
                startedAt: Date(timeIntervalSince1970: 1),
                endedAt: Date(timeIntervalSince1970: 2),
                terminal: .failed(message: "old")
            ),
            output: .init(summary: "old")
        )
        let orderingEntered = AsyncGate()
        let orderingRelease = AsyncGate()
        let history = ReviewHistoryPersistenceProbe(
            records: [old],
            orderingWriteEntered: orderingEntered,
            orderingWriteRelease: orderingRelease,
            terminalMutation: .init(removedReviewIDs: [old.id])
        )
        let backend = FakeCodexReviewBackend()
        let store = makeStore(
            history: history,
            backend: backend,
            idGenerator: .init(next: { "live-review" })
        )
        await store.loadReviewHistoryIfNeeded()
        let live = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/live", target: .uncommittedChanges),
            waitTimeout: .zero
        )
        await backend.waitForStartReview()

        let reorder = Task { @MainActor in
            await store.reorderWorkspaces(cwds: [old.cwd], toIndex: 0)
        }
        await orderingEntered.wait()
        await backend.yield(.completed(summary: "Done", result: "No findings."))
        try #require(await waitForHistoryTestCondition {
            store.historyTerminalReceipts[live.jobID] != nil
        })
        let deletion = Task { @MainActor in
            await store.deleteReviewHistory(id: old.id)
        }

        await orderingRelease.open()
        _ = await reorder.value
        _ = try await store.awaitReview(sessionID: "session-1", jobID: live.jobID)
        await deletion.value

        let operations = await history.mutationOperations().filter {
            $0 != "started"
        }
        #expect(operations == ["ordering", "terminal"])
        #expect(store.jobs.map(\.id) == [live.jobID])
        #expect(await history.durableTerminalIDs() == Set([live.jobID]))
    }

    @Test func cancelledLaunchDoesNotStartRuntimeAfterHistoryLoadResumes() async {
        let entered = AsyncGate()
        let release = AsyncGate()
        let history = ReviewHistoryPersistenceProbe(
            loadEntered: entered,
            loadRelease: release
        )
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend()
        )
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            historyPersistence: history
        )

        let launch = Task { @MainActor in
            await store.start(forceRestartIfNeeded: true)
        }
        await entered.wait()
        launch.cancel()
        await release.open()
        await launch.value

        #expect(store.serverState == .stopped)
        #expect(backend.isActive == false)
        await store.shutdown()
    }

    @Test func shutdownIsTerminalAndConcurrentRestartCannotAcquireRuntime() async {
        let history = ReviewHistoryPersistenceProbe()
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend()
        )
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            historyPersistence: history
        )
        await store.start()
        let initialHandle = backend.lastPreparedRuntimeHandle

        let shutdown = Task { @MainActor in await store.shutdown() }
        while store.applicationShutdownRequested == false {
            await Task.yield()
        }
        await store.restart()
        await shutdown.value
        await store.start(forceRestartIfNeeded: true)

        #expect(store.serverState == .stopped)
        #expect(backend.lastPreparedRuntimeHandle === initialHandle)
        #expect(await history.closeCallCount() == 1)
    }

    @Test func startAfterShutdownDoesNotLoadClosedPersistence() async {
        let history = ReviewHistoryPersistenceProbe()
        let store = makeStore(history: history)

        await store.shutdown()
        await store.start(forceRestartIfNeeded: true)

        #expect(await history.loadCallCount() == 0)
        #expect(await history.closeCallCount() == 1)
        #expect(store.serverState == .stopped)
    }

    @Test func suspendedMutationDoesNotRetainCoordinatorAndDeinitCancelsTask() async throws {
        let entered = AsyncGate()
        let release = AsyncGate()
        let cancellation = HistoryTestCompletion()
        var coordinator: ReviewHistoryMutationCoordinator? = .init()
        weak let weakCoordinator = coordinator
        guard let receipt = coordinator?.enqueue(
            intent: (),
            prepare: { $0 },
            operation: { _ in
                await entered.open()
                await release.wait()
                if Task.isCancelled {
                    await cancellation.complete()
                }
            },
            apply: { _, _ in }
        ) else {
            Issue.record("Expected mutation receipt")
            return
        }
        await entered.wait()

        coordinator = nil

        #expect(weakCoordinator == nil)
        try #require(await waitForHistoryTestCondition {
            await cancellation.isComplete()
        })
        _ = await receipt.wait()
    }

    private func makeStore(
        history: ReviewHistoryPersistenceProbe,
        backend: FakeCodexReviewBackend = FakeCodexReviewBackend(),
        idGenerator: CodexReviewIDGenerator = .init()
    ) -> CodexReviewStore {
        CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: idGenerator,
            historyPersistence: history
        )
    }

    private func historyRecord(
        id: String,
        cwd: String,
        workspaceSortOrder: Double = 0,
        sortOrder: Double = 0,
        target: CodexReviewAPI.Target = .uncommittedChanges,
        lifecycle: ReviewJobCore.Lifecycle,
        output: ReviewJobCore.Output
    ) throws -> RestoredReviewRecord {
        guard let terminal = lifecycle.terminal,
              let startedAt = lifecycle.startedAt
        else {
            throw ReviewHistoryRecordError("History test fixture requires a terminal and start time.")
        }
        let started = try StartedReviewRecord(
            id: id,
            cwd: cwd,
            workspaceSortOrder: workspaceSortOrder,
            sortOrder: sortOrder,
            target: target,
            model: "gpt-5",
            startedAt: startedAt
        )
        let completed = terminal == .completed
        let terminalRecord = try TerminalReviewRecord(
            id: id,
            model: "gpt-5",
            terminal: terminal,
            endedAt: lifecycle.endedAt,
            summary: output.summary,
            canonicalReview: completed ? output.lastAgentMessage : nil,
            parsedResult: completed ? output.reviewResult.map(PersistedParsedReviewResult.init) : nil
        )
        return try RestoredReviewRecord(started: started, terminal: terminalRecord)
    }
}

private struct ReviewHistoryPersistenceProbeError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}

private actor HistoryTestCompletion {
    private var completed = false

    func complete() { completed = true }
    func isComplete() -> Bool { completed }
}

@MainActor
private func waitForHistoryTestCondition(
    timeout: Duration = .seconds(2),
    condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while await condition() == false {
        if clock.now >= deadline { return false }
        await Task.yield()
    }
    return true
}

private final class SequentialHistoryTestIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String]

    init(_ ids: [String]) {
        self.ids = ids
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        return ids.removeFirst()
    }
}

private extension RestoredReviewRecord {
    var id: String { started.id }
    var cwd: String { started.cwd }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

private actor ReviewHistoryPersistenceProbe: ReviewHistoryPersistence {
    private var records: [RestoredReviewRecord]
    private let loadEntered: AsyncGate?
    private let loadRelease: AsyncGate?
    private let startedWriteEntered: AsyncGate?
    private let startedWriteRelease: AsyncGate?
    private let terminalWriteEntered: AsyncGate?
    private let terminalWriteRelease: AsyncGate?
    private let orderingWriteEntered: AsyncGate?
    private let orderingWriteRelease: AsyncGate?
    private let loadFailure: String?
    private let startedWriteFailure: String?
    private let terminalWriteFailure: String?
    private let orderingWriteFailure: String?
    private var terminalMutations: [ReviewHistoryMutationResult]
    private var loadCalls = 0
    private var started: [StartedReviewRecord] = []
    private var terminals: [TerminalReviewRecord] = []
    private var savedOrderings: [ReviewHistoryOrdering] = []
    private var mutationOperationLog: [String] = []
    private var deleteAllCalls = 0
    private var closeCalls = 0

    init(
        records: [RestoredReviewRecord] = [],
        loadEntered: AsyncGate? = nil,
        loadRelease: AsyncGate? = nil,
        startedWriteEntered: AsyncGate? = nil,
        startedWriteRelease: AsyncGate? = nil,
        terminalWriteEntered: AsyncGate? = nil,
        terminalWriteRelease: AsyncGate? = nil,
        orderingWriteEntered: AsyncGate? = nil,
        orderingWriteRelease: AsyncGate? = nil,
        loadFailure: String? = nil,
        startedWriteFailure: String? = nil,
        terminalWriteFailure: String? = nil,
        orderingWriteFailure: String? = nil,
        terminalMutation: ReviewHistoryMutationResult = .init(),
        terminalMutations: [ReviewHistoryMutationResult]? = nil
    ) {
        self.records = records
        self.loadEntered = loadEntered
        self.loadRelease = loadRelease
        self.startedWriteEntered = startedWriteEntered
        self.startedWriteRelease = startedWriteRelease
        self.terminalWriteEntered = terminalWriteEntered
        self.terminalWriteRelease = terminalWriteRelease
        self.orderingWriteEntered = orderingWriteEntered
        self.orderingWriteRelease = orderingWriteRelease
        self.loadFailure = loadFailure
        self.startedWriteFailure = startedWriteFailure
        self.terminalWriteFailure = terminalWriteFailure
        self.orderingWriteFailure = orderingWriteFailure
        self.terminalMutations = terminalMutations ?? [terminalMutation]
    }

    func load(
        retentionPolicy _: ReviewHistoryRetentionPolicy
    ) async throws -> [RestoredReviewRecord] {
        loadCalls += 1
        await loadEntered?.open()
        await loadRelease?.waitIgnoringCancellation()
        if let loadFailure {
            throw ReviewHistoryPersistenceProbeError(message: loadFailure)
        }
        return records
    }

    func recordStarted(_ record: StartedReviewRecord) async throws {
        await startedWriteEntered?.open()
        await startedWriteRelease?.waitIgnoringCancellation()
        if let startedWriteFailure {
            throw ReviewHistoryPersistenceProbeError(message: startedWriteFailure)
        }
        mutationOperationLog.append("started")
        started.append(record)
    }

    func recordTerminal(
        _ record: TerminalReviewRecord,
        retentionPolicy _: ReviewHistoryRetentionPolicy
    ) async throws -> ReviewHistoryMutationResult {
        mutationOperationLog.append("terminal")
        terminals.append(record)
        await terminalWriteEntered?.open()
        await terminalWriteRelease?.waitIgnoringCancellation()
        if let terminalWriteFailure {
            throw ReviewHistoryPersistenceProbeError(message: terminalWriteFailure)
        }
        let mutation = terminalMutations.isEmpty
            ? ReviewHistoryMutationResult()
            : terminalMutations.removeFirst()
        records.removeAll { mutation.removedReviewIDs.contains($0.started.id) }
        terminals.removeAll {
            mutation.removedReviewIDs.contains($0.id) && $0.id != record.id
        }
        return mutation
    }

    func saveOrdering(_ ordering: ReviewHistoryOrdering) async throws {
        mutationOperationLog.append("ordering")
        await orderingWriteEntered?.open()
        await orderingWriteRelease?.waitIgnoringCancellation()
        if let orderingWriteFailure {
            throw ReviewHistoryPersistenceProbeError(message: orderingWriteFailure)
        }
        savedOrderings.append(ordering)
    }

    func deleteTerminalReview(
        id: String
    ) async throws -> ReviewHistoryMutationResult {
        mutationOperationLog.append("delete")
        let hadRecord = records.contains { $0.started.id == id }
            || terminals.contains { $0.id == id }
        records.removeAll { $0.started.id == id }
        started.removeAll { $0.id == id }
        terminals.removeAll { $0.id == id }
        return .init(removedReviewIDs: hadRecord ? [id] : [])
    }

    func deleteAllTerminalReviews() async throws -> ReviewHistoryMutationResult {
        mutationOperationLog.append("delete-all")
        deleteAllCalls += 1
        let ids = Set(records.map { $0.started.id } + terminals.map(\.id))
        records.removeAll()
        terminals.removeAll()
        return .init(removedReviewIDs: ids)
    }

    func close() async throws {
        closeCalls += 1
    }

    func loadCallCount() -> Int { loadCalls }
    func startedRecords() -> [StartedReviewRecord] { started }
    func terminalRecords() -> [TerminalReviewRecord] { terminals }
    func orderings() -> [ReviewHistoryOrdering] { savedOrderings }
    func deleteAllCallCount() -> Int { deleteAllCalls }
    func closeCallCount() -> Int { closeCalls }
    func mutationOperations() -> [String] { mutationOperationLog }
    func durableTerminalIDs() -> Set<String> {
        Set(records.map { $0.started.id } + terminals.map(\.id))
    }
}
