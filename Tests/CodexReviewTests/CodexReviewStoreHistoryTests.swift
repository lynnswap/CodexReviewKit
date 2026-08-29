import Foundation
import Testing
@_spi(Testing) @testable import CodexReview
import CodexReviewTesting

@Suite("review history store", .serialized)
@MainActor
struct CodexReviewStoreHistoryTests {
    @Test func loadOnceRestoresCompactApplicationHistoryWithoutSessionAuthority() async throws {
        let startedAt = Date(timeIntervalSince1970: 100)
        let history = ReviewHistoryPersistenceProbe(records: [
            historyRecord(
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
        #expect(job.origin == .restored)
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
        #expect(startedRecord.core.lifecycle.status == .running)
        #expect(startedRecord.core.lifecycle.startedAt != nil)
        #expect(startedRecord.core.output.lastAgentMessage == nil)

        await backend.yield(.completed(summary: "Done", result: "No findings."))
        #expect(try await review.value.core.lifecycle.status == .succeeded)
        let terminalRecord = try #require(await history.terminalRecords().first)
        #expect(terminalRecord.core.output.hasFinalReview)
        #expect(terminalRecord.core.output.lastAgentMessage == "No findings.")
        #expect(terminalRecord.core.output.reviewResult?.state == .noFindings)
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
        #expect(terminal.core.lifecycle.status == .failed)
        #expect(terminal.core.output.summary == "review failed")
        #expect(terminal.core.output.hasFinalReview == false)
        #expect(terminal.core.output.lastAgentMessage == nil)
        #expect(terminal.core.output.reviewResult == nil)
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

    @Test func retentionResultReconcilesStoreMembership() async throws {
        let old = historyRecord(
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

    @Test func deleteAllRemovesTerminalHistoryButPreservesActiveLiveReview() async throws {
        let restored = historyRecord(
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

    @Test func shutdownSavesOrderingAndClosesPersistenceExactlyOnce() async {
        let record = historyRecord(
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

    @Test func workspaceReorderPersistsBeforeApplyingMemoryOrder() async {
        let first = historyRecord(
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
        let second = historyRecord(
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
            await store.reorderReviewHistoryWorkspaces(
                cwds: [first.cwd],
                toIndex: 0
            )
        }
        await entered.wait()
        #expect(store.orderedWorkspaces.map(\.cwd) == [second.cwd, first.cwd])

        await release.open()
        await reorder.value
        #expect(store.orderedWorkspaces.map(\.cwd) == [first.cwd, second.cwd])
        #expect(await history.orderings().count == 1)
    }

    @Test func jobReorderFailureKeepsMemoryOrderAndPublishesFailure() async {
        let first = historyRecord(
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
        let second = historyRecord(
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

        await store.reorderReviewHistoryJob(
            id: first.id,
            inWorkspace: first.cwd,
            toIndex: 0
        )

        #expect(store.orderedJobs(inWorkspace: first.cwd).map(\.id) == [second.id, first.id])
        #expect(store.historyAvailability == .failed("ordering failed"))
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
    ) -> ReviewHistoryRecord {
        ReviewHistoryRecord(
            id: id,
            cwd: cwd,
            workspaceSortOrder: workspaceSortOrder,
            sortOrder: sortOrder,
            target: target,
            core: .init(
                run: .init(model: "gpt-5"),
                lifecycle: lifecycle,
                output: output
            )
        )
    }
}

private struct ReviewHistoryPersistenceProbeError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}

private actor ReviewHistoryPersistenceProbe: ReviewHistoryPersistence {
    private var records: [ReviewHistoryRecord]
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
    private let terminalMutation: ReviewHistoryMutationResult
    private var loadCalls = 0
    private var started: [ReviewHistoryRecord] = []
    private var terminals: [ReviewHistoryRecord] = []
    private var savedOrderings: [ReviewHistoryOrdering] = []
    private var deleteAllCalls = 0
    private var closeCalls = 0

    init(
        records: [ReviewHistoryRecord] = [],
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
        terminalMutation: ReviewHistoryMutationResult = .init()
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
        self.terminalMutation = terminalMutation
    }

    func load() async throws -> [ReviewHistoryRecord] {
        loadCalls += 1
        await loadEntered?.open()
        await loadRelease?.waitIgnoringCancellation()
        if let loadFailure {
            throw ReviewHistoryPersistenceProbeError(message: loadFailure)
        }
        return records
    }

    func recordStarted(_ record: ReviewHistoryRecord) async throws {
        await startedWriteEntered?.open()
        await startedWriteRelease?.waitIgnoringCancellation()
        if let startedWriteFailure {
            throw ReviewHistoryPersistenceProbeError(message: startedWriteFailure)
        }
        started.append(record)
    }

    func recordTerminal(
        _ record: ReviewHistoryRecord,
        retentionPolicy _: ReviewHistoryRetentionPolicy
    ) async throws -> ReviewHistoryMutationResult {
        terminals.append(record)
        await terminalWriteEntered?.open()
        await terminalWriteRelease?.waitIgnoringCancellation()
        if let terminalWriteFailure {
            throw ReviewHistoryPersistenceProbeError(message: terminalWriteFailure)
        }
        return terminalMutation
    }

    func saveOrdering(_ ordering: ReviewHistoryOrdering) async throws {
        await orderingWriteEntered?.open()
        await orderingWriteRelease?.waitIgnoringCancellation()
        if let orderingWriteFailure {
            throw ReviewHistoryPersistenceProbeError(message: orderingWriteFailure)
        }
        savedOrderings.append(ordering)
    }

    func deleteReview(id: String) async throws {
        records.removeAll { $0.id == id }
        started.removeAll { $0.id == id }
        terminals.removeAll { $0.id == id }
    }

    func deleteAll() async throws {
        deleteAllCalls += 1
        records.removeAll()
        terminals.removeAll()
    }

    func close() async throws {
        closeCalls += 1
    }

    func loadCallCount() -> Int { loadCalls }
    func startedRecords() -> [ReviewHistoryRecord] { started }
    func terminalRecords() -> [ReviewHistoryRecord] { terminals }
    func orderings() -> [ReviewHistoryOrdering] { savedOrderings }
    func deleteAllCallCount() -> Int { deleteAllCalls }
    func closeCallCount() -> Int { closeCalls }
}
