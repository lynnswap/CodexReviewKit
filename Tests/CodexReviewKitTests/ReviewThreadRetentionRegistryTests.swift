import Foundation
import Testing
@_spi(Testing) @testable import CodexReviewKit
import CodexReviewTesting

@Suite("Review thread retention", .serialized)
@MainActor
struct ReviewThreadRetentionRegistryTests {
    @Test func claimPersistsAndMergesRestartIdentityBeforePublication() async throws {
        let journal = ControlledReviewThreadRetentionJournal()
        let registry = ReviewThreadRetentionRegistry(journal: journal)
        let runID = try ReviewRunID(validating: "run-1")
        let scope = ReviewThreadRetentionScope(
            codexHomePath: "/tmp/codex-home",
            accountKey: "account@example.com"
        )
        let initial = makeReviewAttemptForTesting(
            attemptID: "attempt-1",
            sourceThreadID: "source-thread",
            activeTurnThreadID: "review-thread-1",
            turnID: "turn-1"
        )
        let restarted = makeReviewAttemptForTesting(
            attemptID: "attempt-2",
            sourceThreadID: "source-thread",
            activeTurnThreadID: "review-thread-2",
            turnID: "turn-2"
        )

        try await registry.claim(initial, for: runID, scope: scope)
        try await registry.claim(restarted, for: runID, scope: scope)

        let snapshot = try await registry.snapshotForTesting()
        let entry = try #require(snapshot.entries.first)
        #expect(snapshot.entries.count == 1)
        #expect(entry.runID == runID)
        #expect(entry.scope == scope)
        #expect(entry.attempts == [initial, restarted])
        #expect(await registry.acceptance() == .accepting)
    }

    @Test func repeatedDurableClaimDoesNotRequireAnotherJournalWrite() async throws {
        let journal = ControlledReviewThreadRetentionJournal()
        let registry = ReviewThreadRetentionRegistry(journal: journal)
        let runID = try ReviewRunID(validating: "run-1")
        let scope = ReviewThreadRetentionScope(
            codexHomePath: "/tmp/codex-home",
            accountKey: "account@example.com"
        )
        let attempt = makeReviewAttemptForTesting(
            attemptID: "attempt-1",
            sourceThreadID: "source-thread",
            activeTurnThreadID: "review-thread",
            turnID: "turn-1"
        )

        try await registry.claim(attempt, for: runID, scope: scope)
        await journal.failReplacements("disk unavailable")

        try await registry.claim(attempt, for: runID, scope: scope)

        #expect(await registry.acceptance() == .accepting)
        #expect(try await registry.snapshotForTesting().entries.first?.attempts == [attempt])
    }

    @Test func failedJournalAndCleanupRemainTypedQuarantineUntilDurableRetry() async throws {
        let journal = ControlledReviewThreadRetentionJournal()
        await journal.failReplacements("disk unavailable")
        let registry = ReviewThreadRetentionRegistry(journal: journal)
        let runID = try ReviewRunID(validating: "run-1")
        let attempt = makeReviewAttemptForTesting(
            attemptID: "attempt-1",
            sourceThreadID: "source-thread",
            activeTurnThreadID: "review-thread",
            turnID: "turn-1"
        )

        await #expect(throws: ReviewThreadRetentionRegistryError.self) {
            try await registry.claim(
                attempt,
                for: runID,
                scope: .init(codexHomePath: "/tmp/codex-home", accountKey: nil)
            )
        }
        await registry.recordFailedClaimCleanup(
            runID: runID,
            journalFailure: "disk unavailable",
            failedThreadIDs: [attempt.threadIdentity.activeTurnThreadID],
            cleanupFailure: "thread delete failed"
        )

        let quarantined = try #require(await registry.acceptance().quarantines)
        #expect(quarantined.count == 1)
        #expect(quarantined[0].entry.attempts == [attempt])
        #expect(quarantined[0].journalFailure == "disk unavailable")
        #expect(quarantined[0].cleanupFailure == "thread delete failed")

        await journal.failReplacements(nil)
        #expect(await registry.retryQuarantinedJournalCommits() == .accepting)
        #expect(try await registry.snapshotForTesting().entries.first?.attempts == [attempt])
    }

    @Test func fileJournalRejectsMalformedEntryWithoutInvokingRuntimePreconditions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-retention-malformed-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("journal.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let malformed: [String: Any] = [
            "version": 1,
            "entries": [[
                "runID": "run-1",
                "scope": ["codexHomePath": "/tmp/codex-home"],
                "attempts": [],
            ]],
        ]
        try JSONSerialization.data(withJSONObject: malformed).write(to: fileURL)
        let journal = FileReviewThreadRetentionJournal(fileURL: fileURL)

        await #expect(throws: DecodingError.self) {
            _ = try await journal.load()
        }
    }

    @Test func fileJournalRejectsConflictingDuplicateAttemptIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-retention-conflict-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("journal.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let attempt: (String) -> [String: Any] = { turnID in
            [
                "attemptID": "attempt-1",
                "threadIdentity": [
                    "sourceThreadID": "source-thread",
                    "activeTurnThreadID": "review-thread",
                ],
                "turnID": turnID,
            ]
        }
        let malformed: [String: Any] = [
            "version": 1,
            "entries": [[
                "runID": "run-1",
                "scope": ["codexHomePath": "/tmp/codex-home"],
                "attempts": [attempt("turn-1"), attempt("turn-2")],
            ]],
        ]
        try JSONSerialization.data(withJSONObject: malformed).write(to: fileURL)
        let journal = FileReviewThreadRetentionJournal(fileURL: fileURL)

        await #expect(throws: DecodingError.self) {
            _ = try await journal.load()
        }
    }

    @Test func journalRemovalFailureKeepsDurableTombstoneForRetry() async throws {
        let journal = ControlledReviewThreadRetentionJournal()
        let registry = ReviewThreadRetentionRegistry(journal: journal)
        let runID = try ReviewRunID(validating: "run-1")
        let attempt = makeReviewAttemptForTesting(
            attemptID: "attempt-1",
            sourceThreadID: "source-thread",
            activeTurnThreadID: "review-thread",
            turnID: "turn-1"
        )
        try await registry.claim(
            attempt,
            for: runID,
            scope: .init(codexHomePath: "/tmp/codex-home", accountKey: nil)
        )

        await journal.failReplacements("remove failed")
        await registry.recordCleanupSucceeded(for: runID)
        #expect(try await registry.snapshotForTesting().entries.map(\.runID) == [runID])
        #expect(try await journal.load().entries.map(\.runID) == [runID])

        await journal.failReplacements(nil)
        await registry.recordCleanupSucceeded(for: runID)
        #expect(try await registry.snapshotForTesting().entries.isEmpty)
        #expect(try await journal.load().entries.isEmpty)
    }

    @Test func startupOrphanCleanupRemovesJournalWithoutRestoringVisibleRun() async throws {
        let entry = makeRetentionEntry(runID: "orphan-run")
        let journal = ControlledReviewThreadRetentionJournal(
            snapshot: .init(entries: [entry])
        )
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            reviewThreadRetentionJournal: journal
        )

        #expect(await store.recoverOrphanedReviewThreads() == .recovered)
        #expect(store.reviewRuns.isEmpty)
        #expect(try await journal.load().entries.isEmpty)
        #expect(await backend.recordedCommands().contains(.cleanupRetainedReviews(entry.attempts)))
    }

    @Test func startupOrphanCleanupFailureKeepsTombstoneWithoutVisibleRun() async throws {
        let entry = makeRetentionEntry(runID: "orphan-run")
        let journal = ControlledReviewThreadRetentionJournal(
            snapshot: .init(entries: [entry])
        )
        let backend = FakeCodexReviewBackend()
        await backend.failRetainedCleanup(message: "delete failed")
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            reviewThreadRetentionJournal: journal
        )

        #expect(await store.recoverOrphanedReviewThreads() == .cleanupIncomplete)
        #expect(store.reviewRuns.isEmpty)
        let retained = try #require(try await journal.load().entries.first)
        #expect(retained.runID == entry.runID)
        #expect(retained.scope == entry.scope)
        #expect(retained.attempts == entry.attempts)
        #expect(
            retained.additionalCleanupThreadIDs
                == [entry.attempts[0].threadIdentity.activeTurnThreadID]
        )
    }

    @Test func startupJournalLoadFailureIsTypedAndDoesNotPublishRuntimeRecovery() async {
        let journal = ControlledReviewThreadRetentionJournal()
        await journal.failLoads("journal corrupt")
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            reviewThreadRetentionJournal: journal
        )

        #expect(
            await store.recoverOrphanedReviewThreads()
                == .journalUnavailable(message: "journal corrupt")
        )
        #expect(store.reviewRuns.isEmpty)
    }

    @Test func journalLoadFailureRejectsReviewBeforeStartingBackendWork() async throws {
        let journal = ControlledReviewThreadRetentionJournal()
        await journal.failLoads("journal corrupt")
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            reviewThreadRetentionJournal: journal
        )

        do {
            _ = try await store.beginReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            Issue.record("A review must not start while its retention journal is unavailable.")
        } catch let failure as ReviewBackendFailure {
            #expect(failure.isRetentionJournalFailure)
        }

        #expect(store.reviewRuns.isEmpty)
        #expect(await backend.recordedCommands().isEmpty)
        #expect(
            await store.reviewThreadRetentionRegistry.acceptance()
                == .journalUnavailable(message: "journal corrupt")
        )
    }

    @Test func storeDoesNotPublishAttemptWhoseJournalCommitFailed() async throws {
        let journal = ControlledReviewThreadRetentionJournal()
        await journal.failReplacements("disk unavailable")
        let attempt = makeRetentionAttempt(runID: "run-1")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            reviewThreadRetentionJournal: journal
        )
        try await withRetentionStoreCleanup(backend: backend, store: store) {
            let result = try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )

            #expect(result.presentation.status == .failed)
            #expect(result.core.attempt == nil)
            #expect(result.core.failure?.isRetentionJournalFailure == true)
            let commands = await backend.recordedCommands()
            #expect(commands.contains { command in
                if case .cleanupRetainedReviews = command { true } else { false }
            })
            #expect(await store.reviewThreadRetentionRegistry.acceptance() == .accepting)
        }
    }

    @Test func doubleFailureClosesAcceptanceGateUntilCleanupRecovery() async throws {
        let journal = ControlledReviewThreadRetentionJournal()
        await journal.failReplacements("disk unavailable")
        let attempt = makeRetentionAttempt(runID: "run-1")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        await backend.failRetainedCleanup(message: "delete failed")
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            reviewThreadRetentionJournal: journal
        )
        try await withRetentionStoreCleanup(backend: backend, store: store) {
            let failed = try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            #expect(failed.core.failure?.isRetentionJournalFailure == true)
            #expect(await store.reviewThreadRetentionRegistry.acceptance().isAccepting == false)

            await #expect(throws: ReviewBackendFailure.self) {
                try await store.startReview(
                    sessionID: "session-2",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                )
            }

            await backend.failRetainedCleanup(message: nil)
            #expect(await store.retireReviewRunsForFinalStoreStop())
            #expect(store.reviewRuns.isEmpty)
            #expect(await store.reviewThreadRetentionRegistry.acceptance() == .accepting)
        }
    }

    @Test func preservingRestartKeepsThreadsAndFinalStopRetiresThem() async throws {
        let journal = ControlledReviewThreadRetentionJournal()
        let attempt = makeRetentionAttempt(runID: "run-1")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            reviewThreadRetentionJournal: journal
        )
        try await withRetentionStoreCleanup(backend: backend, store: store) {
            await store.start()
            async let started = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(finalReview: "No issues found."), for: attempt)
            _ = try await started

            await store.restart()
            #expect(store.reviewRuns.count == 1)
            #expect(await backend.recordedCommands().contains { command in
                if case .cleanupRetainedReviews = command { true } else { false }
            } == false)

            let cleanupGate = AsyncGate()
            await backend.holdRetainedCleanup(with: cleanupGate)
            let stop = Task { @MainActor in
                await store.stop()
            }
            try await backend.waitForRetainedCleanup(timeout: .seconds(2))
            #expect(store.reviewRuns.isEmpty)
            await cleanupGate.open()
            await stop.value
            #expect(await backend.recordedCommands().contains { command in
                if case .cleanupRetainedReviews = command { true } else { false }
            })
            #expect(try await journal.load().entries.isEmpty)
        }
    }

    @Test func finalCleanupFailureRetiresResolverButKeepsDurableTombstone() async throws {
        let journal = ControlledReviewThreadRetentionJournal()
        let attempt = makeRetentionAttempt(runID: "run-1")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        await backend.failRetainedCleanup(message: "delete failed")
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            reviewThreadRetentionJournal: journal
        )
        try await withRetentionStoreCleanup(backend: backend, store: store) {
            await store.start()
            async let started = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(finalReview: "No issues found."), for: attempt)
            _ = try await started

            await store.stop()

            #expect(store.reviewRuns.isEmpty)
            #expect(store.serverState == .stopped)
            #expect(try await journal.load().entries.map(\.runID.rawValue) == ["run-1"])
        }
    }

    @Test func finalRetryDoesNotCleanPersistedQuarantineTwice() async throws {
        let journal = ControlledReviewThreadRetentionJournal()
        let attempt = makeRetentionAttempt(runID: "run-1")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            reviewThreadRetentionJournal: journal
        )
        try await withRetentionStoreCleanup(backend: backend, store: store) {
            async let started = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(finalReview: "No issues found."), for: attempt)
            _ = try await started

            await backend.failRetainedCleanup(message: "delete failed")
            await journal.failReplacements("disk unavailable")
            #expect(await store.retireReviewRunsForFinalStoreStop() == false)

            await backend.failRetainedCleanup(message: nil)
            #expect(await store.retireReviewRunsForFinalStoreStop())

            let retainedCleanups = await backend.recordedCommands().filter { command in
                if case .cleanupRetainedReviews = command { true } else { false }
            }
            #expect(retainedCleanups.count == 2)
        }
    }
}

private func makeRetentionAttempt(runID: String) -> ReviewAttempt {
    makeReviewAttemptForTesting(
        attemptID: "attempt-\(runID)",
        sourceThreadID: "thread-\(runID)",
        activeTurnThreadID: "review-thread-\(runID)",
        turnID: "turn-\(runID)"
    )
}

private actor ControlledReviewThreadRetentionJournal: ReviewThreadRetentionJournaling {
    private var snapshot: ReviewThreadRetentionJournalSnapshot
    private var replacementFailure: String?
    private var loadFailure: String?

    init(snapshot: ReviewThreadRetentionJournalSnapshot = .init()) {
        self.snapshot = snapshot
    }

    func failReplacements(_ message: String?) {
        replacementFailure = message
    }

    func failLoads(_ message: String?) {
        loadFailure = message
    }

    func load() throws -> ReviewThreadRetentionJournalSnapshot {
        if let loadFailure {
            throw ControlledJournalError(message: loadFailure)
        }
        return snapshot
    }

    func replace(with snapshot: ReviewThreadRetentionJournalSnapshot) throws {
        if let replacementFailure {
            throw ControlledJournalError(message: replacementFailure)
        }
        self.snapshot = snapshot
    }
}

private func makeRetentionEntry(runID: String) -> ReviewThreadRetentionEntry {
    guard let validatedRunID = try? ReviewRunID(validating: runID) else {
        preconditionFailure("The retention test fixture requires a nonempty run ID.")
    }
    return ReviewThreadRetentionEntry(
        runID: validatedRunID,
        scope: .init(
            codexHomePath: FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexReviewKit-volatile", isDirectory: true)
                .path,
            accountKey: nil
        ),
        attempts: [makeReviewAttemptForTesting(
            attemptID: "attempt-\(runID)",
            sourceThreadID: "source-\(runID)",
            activeTurnThreadID: "review-\(runID)",
            turnID: "turn-\(runID)"
        )]
    )
}

private struct ControlledJournalError: LocalizedError {
    var message: String

    var errorDescription: String? {
        message
    }
}

private extension ReviewThreadRetentionAcceptance {
    var quarantines: [ReviewThreadRetentionQuarantine]? {
        guard case .quarantined(let quarantines) = self else {
            return nil
        }
        return quarantines
    }
}

private extension ReviewBackendFailure {
    var isRetentionJournalFailure: Bool {
        if case .retentionJournal = self {
            return true
        }
        return false
    }
}

@MainActor
private func withRetentionStoreCleanup<T>(
    backend: FakeCodexReviewBackend,
    store: CodexReviewStore,
    operation: () async throws -> T
) async rethrows -> T {
    do {
        let value = try await operation()
        await backend.finishEventMailboxes()
        await store.cancelAndDrainReviewWorkersForTesting()
        return value
    } catch {
        await backend.finishEventMailboxes()
        await store.cancelAndDrainReviewWorkersForTesting()
        throw error
    }
}
