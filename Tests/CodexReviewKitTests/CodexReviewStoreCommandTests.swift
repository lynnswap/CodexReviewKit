import Foundation
import Testing
@_spi(Testing) @testable import CodexReviewKit
import CodexReviewTesting

@Suite("Codex review store", .serialized)
@MainActor
struct CodexReviewStoreCommandTests {
    @Test func reviewStartRejectsEmptyGeneratedRunIDBeforeInsertion() async {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { " \n\t " })
        )

        await #expect(throws: ReviewIdentityValidationError.empty(field: "runID")) {
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        #expect(store.reviewRuns.isEmpty)
        #expect(await backend.recordedCommands().isEmpty)
    }

    @Test func reviewStartPublishesCompletedRunLifecycle() async throws {
        let attempt = makeAttempt(
            attemptID: "attempt-1",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "review-thread-1"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            clock: .init(now: { Date(timeIntervalSince1970: 1) }),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(finalReview: "No issues found."), for: attempt)
            let read = try await result

            #expect(read.runID.rawValue == "run-1")
            #expect(read.presentation.status == .succeeded)
            #expect(store.listReviews(sessionID: nil).items.map(\.runID.rawValue) == ["run-1"])

            let commands = await backend.recordedCommands()
            #expect(
                commands.contains(
                    .cleanupReview(
                        makeAttempt(
                            attemptID: "attempt-1",
                            sourceThreadID: "thread-1",
                            turnID: "turn-1",
                            activeTurnThreadID: "review-thread-1"
                        ))))
            #expect(commands.contains { command in
                if case .cleanupRetainedReviews = command { true } else { false }
            } == false)
            let retained = try #require(
                try await store.reviewThreadRetentionRegistry
                    .snapshotForTesting().entries.first
            )
            #expect(retained.runID == makeRunID("run-1"))
            #expect(retained.attempts.map(\.attemptID.rawValue) == ["attempt-1"])
        }
    }

    @Test func boundedReviewStartReturnsRunningSnapshotAndCanBeAwaitedLater() async throws {
        let attempt = makeAttempt(fixtureID: "bounded-start")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            let running = try await result

            #expect(running.runID.rawValue == "run-1")
            #expect(running.presentation.status == .running)

            await backend.yield(.completed(finalReview: "No issues found."), for: attempt)
            let final = try await store.awaitReview(
                sessionID: "session-1",
                runID: makeRunID("run-1"),
                timeout: .seconds(1)
            )

            #expect(final.presentation.status == .succeeded)
        }
    }

    @Test func awaitReviewReturnsWhenRunningRunCompletes() async throws {
        let attempt = makeAttempt(fixtureID: "await-completion")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let start = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await start

            async let awaited = store.awaitReview(
                sessionID: "session-1",
                runID: makeRunID("run-1"),
                timeout: .seconds(1)
            )
            await backend.yield(.completed(finalReview: "No issues found."), for: attempt)
            let final = try await awaited

            #expect(final.presentation.status == .succeeded)
        }
    }

    @Test func awaitReviewReturnsWhenRunningRunIsCancelled() async throws {
        let attempt = makeAttempt(fixtureID: "await-cancellation")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let start = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await start

            async let awaited = store.awaitReview(
                sessionID: "session-1",
                runID: makeRunID("run-1"),
                timeout: .seconds(1)
            )
            _ = try await store.cancelReview(
                runID: makeRunID("run-1"),
                cancellation: .mcpClient(message: "Stop")
            )
            let final = try await awaited

            #expect(final.presentation.status == .cancelled)
            #expect(final.presentation.lifecycle.message == "Stop")
        }
    }

    @Test func awaitReviewReturnsCurrentSnapshotOnTimeout() async throws {
        let attempt = makeAttempt(fixtureID: "await-timeout")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let start = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await start

            let snapshot = try await store.awaitReview(
                sessionID: "session-1",
                runID: makeRunID("run-1"),
                timeout: .milliseconds(10)
            )

            #expect(snapshot.presentation.status == .running)
        }
    }

    @Test func awaitReviewReturnsWhenLocalTerminationUpdatesRunLifecycle() async throws {
        let attempt = makeAttempt(fixtureID: "local-termination")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let start = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await start

            async let awaited = store.awaitReview(
                sessionID: "session-1",
                runID: makeRunID("run-1"),
                timeout: .seconds(1)
            )
            await Task.yield()
            store.terminateAllRunningReviewRunsLocally(
                failureMessage: "Review runtime stopped."
            )
            let final = try await awaited

            #expect(final.presentation.status == .failed)
            #expect(final.presentation.lifecycle.message == "Review runtime stopped.")
        }
    }

    @Test func forceStartWhileRunningInvokesBackendRestartPath() async {
        let reviewBackend = FakeCodexReviewBackend()
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await withStoreCommandTestCleanup(backend: reviewBackend, store: store) {
            await store.start()
            await store.start()
            await store.start(forceRestartIfNeeded: true)

            #expect(backend.startRequests == [false, true])
        }
    }

    @Test func reviewStartPassesEffectiveSettingsModelToBackend() async throws {
        let attempt = makeAttempt(fixtureID: "effective-model")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(
                reviewBackend: backend,
                seed: .init(initialSettingsSnapshot: .init(fallbackModel: "gpt-5.5"))
            ),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(finalReview: "No issues found."), for: attempt)
            _ = try await result

            let commands = await backend.recordedCommands()
            let starts = commands.compactMap { command -> CodexReviewBackendModel.Review.Start? in
                if case .startReview(let request) = command {
                    return request
                }
                return nil
            }
            #expect(starts.first?.model == "gpt-5.5")
        }
    }

    @Test func reviewStartDoesNotNeedProgressEventsForLifecycle() async throws {
        let attempt = makeAttempt(fixtureID: "no-progress")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            let probe = StoreSnapshotProbe(store: store)
            let runningSnapshot = try #require(await probe.waitUntilRunStatus(.running, runID: "run-1"))
            #expect(runningSnapshot.run("run-1")?.summary == "Review started.")

            await backend.yield(.completed(finalReview: "No issues found."), for: attempt)
            let read = try await result
            #expect(read.presentation.lifecycle.message == "Review completed.")
        }
    }

    @Test func newlyStartedReviewAppearsBeforeExistingRunsAcrossWorkspaces() async throws {
        let firstAttempt = makeAttempt(fixtureID: "workspace-order-first")
        let secondAttempt = makeAttempt(fixtureID: "workspace-order-second")
        let backend = FakeCodexReviewBackend(plannedAttempt: firstAttempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let first = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/old-project", target: .baseBranch("main"))
            )
            await backend.yield(.completed(finalReview: "No issues found."), for: firstAttempt)
            _ = try await first
            await backend.finishEvents(for: firstAttempt)
            await backend.planNextAttempt(secondAttempt)

            async let second = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/new-project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(finalReview: "No issues found."), for: secondAttempt)
            _ = try await second

            #expect(store.orderedReviewRuns.map(\.cwd) == ["/tmp/new-project", "/tmp/old-project"])
        }
    }

    @Test func newlyStartedReviewAppearsBeforeExistingRunsInWorkspace() async throws {
        let firstAttempt = makeAttempt(fixtureID: "same-workspace-order-first")
        let secondAttempt = makeAttempt(fixtureID: "same-workspace-order-second")
        let backend = FakeCodexReviewBackend(plannedAttempt: firstAttempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let first = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            await backend.yield(.completed(finalReview: "No issues found."), for: firstAttempt)
            _ = try await first
            await backend.finishEvents(for: firstAttempt)
            await backend.planNextAttempt(secondAttempt)

            async let second = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(finalReview: "No issues found."), for: secondAttempt)
            _ = try await second

            #expect(
                store.listReviews(cwd: "/tmp/project").items.map(\.targetSummary) == [
                    "Uncommitted changes",
                    "Base branch: main",
                ])
        }
    }

    @Test func runningReviewElapsedSecondsUsesInjectedClock() async throws {
        let attempt = makeAttempt(fixtureID: "elapsed-seconds")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let clock = MutableTestClock(Date(timeIntervalSince1970: 1))
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            clock: .init(now: { clock.now() }),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilRunStatus(.running, runID: "run-1") != nil)
            clock.current = Date(timeIntervalSince1970: 13)

            #expect(try store.readReview(runID: makeRunID("run-1")).elapsedSeconds == 12)

            await backend.yield(.completed(finalReview: "No issues found."), for: attempt)
            _ = try await result
        }
    }

    @Test func allowedRunIDsIntersectListAndSelectorBeforeLimit() throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let first = ReviewRunRecord.makeForTesting(
            id: "run-1",
            sessionID: "session-1",
            cwd: "/tmp/project",
            targetSummary: "First",
            attemptID: "attempt-1",
            threadID: "thread-1",
            reviewThreadID: "review-thread-1",
            turnID: "turn-1",
            status: .succeeded,
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2),
            summary: "Done"
        )
        let second = ReviewRunRecord.makeForTesting(
            id: "run-2",
            sessionID: "session-1",
            cwd: "/tmp/project",
            targetSummary: "Second",
            attemptID: "attempt-2",
            threadID: "thread-2",
            reviewThreadID: "review-thread-2",
            turnID: "turn-2",
            status: .succeeded,
            startedAt: Date(timeIntervalSince1970: 3),
            endedAt: Date(timeIntervalSince1970: 4),
            summary: "Done"
        )
        store.loadForTesting(
            serverState: .running,
            reviewRuns: [first, second]
        )
        let allowed = Set([makeRunID("run-1")])

        let listed = store.listReviews(
            sessionID: "session-1",
            cwd: "/tmp/project",
            limit: 1,
            allowedRunIDs: allowed
        )
        let selected = try store.resolveRun(
            sessionID: "session-1",
            selector: .init(cwd: "/tmp/project"),
            allowedRunIDs: allowed
        )

        #expect(listed.items.map(\.runID) == [makeRunID("run-1")])
        #expect(selected.id == makeRunID("run-1"))
    }

    @Test func newlyStartedReviewUsesSortOrderAboveCurrentMaximum() async throws {
        let attempt = makeAttempt(fixtureID: "sort-order")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let existing = ReviewRunRecord.makeForTesting(
                id: "run-existing",
                cwd: "/tmp/project",
                targetSummary: "Existing",
                attemptID: "attempt-existing",
                threadID: "thread-existing",
                reviewThreadID: "review-thread-existing",
                turnID: "turn-existing",
                status: .succeeded,
                startedAt: Date(timeIntervalSince1970: 1),
                endedAt: Date(timeIntervalSince1970: 2),
                summary: "Done"
            )
            store.loadForTesting(
                serverState: .running,
                reviewRuns: [existing]
            )
            store.reviewRun(id: makeRunID("run-existing"))?.sortOrder = 10

            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(finalReview: "No issues found."), for: attempt)
            _ = try await result

            #expect(store.listReviews(cwd: "/tmp/project").items.map(\.targetSummary).first == "Uncommitted changes")
        }
    }

    @Test func cancelRunningReviewUsesBackendInterruptAndPublicState() async throws {
        let attempt = makeAttempt(
            attemptID: "attempt-1",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "review-thread-1"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilRunStatus(.running, runID: "run-1") != nil)
            let cancel = try await store.cancelReview(
                runID: makeRunID("run-1"),
                cancellation: .mcpClient(message: "Stop")
            )
            await backend.yield(.cancelled("Stop"), for: attempt)
            _ = try await result

            #expect(cancel.cancelled)
            #expect(try store.readReview(runID: makeRunID("run-1")).presentation.status == .cancelled)
            let commands = await backend.recordedCommands()
            #expect(
                commands.contains(
                    .interruptReview(
                        makeAttempt(
                            attemptID: "attempt-1",
                            sourceThreadID: "thread-1",
                            turnID: "turn-1",
                            activeTurnThreadID: "review-thread-1"
                        ),
                        .init(message: "Stop")
                    )))
        }
    }

    @Test func pendingCancellationIsNoLongerCancellable() async throws {
        let attempt = makeAttempt(fixtureID: "pending-cancellation")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let interruptGate = AsyncGate()
        await backend.holdInterruptReview(with: interruptGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilRunStatus(.running, runID: "run-1") != nil)

            async let cancellation = store.cancelReview(
                runID: makeRunID("run-1"),
                cancellation: .mcpClient(message: "Stop")
            )
            try await backend.waitForInterruptReview(timeout: .seconds(2))

            #expect(try store.readReview(runID: makeRunID("run-1")).cancellable == false)
            #expect(store.listReviews().items.first?.cancellable == false)
            #expect(store.hasCancellableReview(forChatID: "thread-1") == false)

            async let duplicate = store.cancelReview(
                runID: makeRunID("run-1"),
                cancellation: .mcpClient(message: "Stop again")
            )

            await interruptGate.open()
            _ = try await cancellation
            let joined = try await duplicate
            let read = try await result
            #expect(joined.cancelled)
            #expect(joined.core.cancellation?.message == "Stop")
            #expect(read.presentation.status == .cancelled)
            #expect(read.core.cancellation?.message == "Stop")
        }
    }

    @Test func workerConnectivitySnapshotUsesInjectedMonotonicClock() {
        let presentationDate = Date(timeIntervalSince1970: 42)
        let instant = ContinuousClock().now.advanced(by: .seconds(5))
        let snapshot = ReviewWorkerConnectivitySnapshot(
            .init(
                status: .requiresConnection,
                observedAt: presentationDate
            ),
            clock: .init(
                now: { instant },
                sleep: { _ in }
            )
        )

        switch snapshot.connectivity {
        case .outage:
            break
        case .satisfied:
            Issue.record("A requires-connection snapshot must normalize to a worker outage.")
        }
        #expect(snapshot.observedAt == instant)
        #expect(snapshot.presentationDate == presentationDate)
    }

    @Test func transientNetworkOutageDoesNotRecoverReview() async throws {
        let attempt = makeAttempt(fixtureID: "transient-outage")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let debounceGate = AsyncGate()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(
                outageDebounce: .seconds(10),
                recoverySettle: .seconds(1),
                clock: testReviewWorkerClock { _ in
                    try? await debounceGate.wait()
                }
            )
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            networkMonitor.yield(.satisfied())
            await debounceGate.open()

            let attemptedRecovery = await waitUntil(timeout: .milliseconds(100)) {
                let commands = await backend.recordedCommands()
                return commands.contains { command in
                    if case .prepareReviewRestart = command {
                        true
                    } else {
                        false
                    }
                }
            }
            #expect(attemptedRecovery == false)
            let commands = await backend.recordedCommands()
            #expect(
                commands.contains { command in
                    if case .prepareReviewRestart = command {
                        true
                    } else {
                        false
                    }
                } == false)

            await backend.yield(.completed(finalReview: "No issues found."), for: attempt)
            let read = try await result
            #expect(read.presentation.status == .succeeded)
        }
    }

    @Test func sustainedNetworkOutageInterruptsForRecoveryWithoutTerminalRun() async throws {
        let attempt = makeAttempt(fixtureID: "sustained-outage")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(clock: testReviewWorkerClock { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForPrepareReviewRestart(timeout: .seconds(2))

            let running = try store.readReview(runID: makeRunID("run-1"))
            #expect(running.presentation.status == .running)
            #expect(running.presentation.lifecycle == .preparingRestart)
            _ = try await store.cancelReview(
                runID: makeRunID("run-1"),
                cancellation: .mcpClient(message: "Stop")
            )
            await backend.yield(.cancelled("Stop"), for: attempt)
            _ = try await result
        }
    }

    @Test func networkRecoveryRepeatedSatisfiedSnapshotsRestartAfterLatestSettle() async throws {
        let initialRun = makeAttempt(
            attemptID: "attempt-initial",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = makeAttempt(
            attemptID: "attempt-recovered",
            sourceThreadID: "thread-1",
            turnID: "turn-2",
            activeTurnThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: initialRun)
        await backend.planNextRecoveredAttempt(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let settleGate = AsyncGate()
        let sleeper = ControlledTestSleeper(gate: settleGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(
                outageDebounce: .seconds(10),
                recoverySettle: .seconds(1),
                clock: testReviewWorkerClock { _ in await sleeper.sleep() }
            )
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForPrepareReviewRestart(timeout: .seconds(2))
            await sleeper.blockFutureSleeps()
            networkMonitor.yield(.satisfied())
            #expect(
                await waitUntil {
                    guard let lifecycle = store.reviewRun(id: makeRunID("run-1"))?
                        .presentation.lifecycle else {
                        return false
                    }
                    if case .waitingForNetwork = lifecycle {
                        return true
                    }
                    return false
                })
            networkMonitor.yield(.satisfied())
            await settleGate.open()
            try await backend.waitForRestartPreparedReview(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))

            await backend.yield(.completed(finalReview: "No issues found."), for: recoveredRun)
            let read = try await result

            #expect(read.presentation.status == .succeeded)
            #expect(read.core.attempt?.turnID.rawValue == "turn-2")
        }
    }

    @Test func networkRecoveryUsesAuthoritativeStartAttempt() async throws {
        let initialRun = makeAttempt(
            attemptID: "attempt-initial",
            sourceThreadID: "thread-1",
            turnID: "turn-actual",
            activeTurnThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = makeAttempt(
            attemptID: "attempt-recovered",
            sourceThreadID: "thread-1",
            turnID: "turn-recovered",
            activeTurnThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: initialRun)
        await backend.planNextRecoveredAttempt(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(clock: testReviewWorkerClock { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            try #require(await waitForRunAttemptActivation(store: store, run: initialRun))

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForPrepareReviewRestart(timeout: .seconds(2))
            let commandsAfterInterrupt = await backend.recordedCommands()
            let interruptedRuns = commandsAfterInterrupt.compactMap { command -> ReviewAttempt? in
                if case .prepareReviewRestart(let run) = command {
                    return run
                }
                return nil
            }
            #expect(interruptedRuns.last?.turnID.rawValue == "turn-actual")

            networkMonitor.yield(.satisfied())
            try await backend.waitForRestartPreparedReview(timeout: .seconds(2))
            let commandsAfterRecovery = await backend.recordedCommands()
            let recoveredFromRuns = commandsAfterRecovery.compactMap { command -> ReviewAttempt? in
                if case .restartPreparedReview(let token, _) = command {
                    return token.interruptedAttempt
                }
                return nil
            }
            #expect(recoveredFromRuns.last?.turnID.rawValue == "turn-actual")

            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))
            await backend.yield(.completed(finalReview: "No issues found."), for: recoveredRun)
            let read = try await result

            #expect(read.presentation.status == .succeeded)
            #expect(read.core.attempt?.turnID.rawValue == "turn-recovered")
        }
    }

    @Test func networkRecoveryIgnoresStaleCompletionAfterRecoveredSubscriptionStarts() async throws {
        let initialRun = makeAttempt(
            attemptID: "attempt-initial",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = makeAttempt(
            attemptID: "attempt-recovered",
            sourceThreadID: "thread-1",
            turnID: "turn-2",
            activeTurnThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: initialRun)
        await backend.planNextRecoveredAttempt(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(clock: testReviewWorkerClock { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForPrepareReviewRestart(timeout: .seconds(2))
            networkMonitor.yield(.satisfied())
            try await backend.waitForRestartPreparedReview(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))

            await backend.yield(.completed(finalReview: "No issues found."), for: initialRun)
            await backend.yield(.completed(finalReview: "No issues found."), for: recoveredRun)

            let read = try await result
            #expect(read.presentation.status == .succeeded)
            #expect(read.core.attempt?.turnID.rawValue == "turn-2")
        }
    }

    @Test func networkRecoveryIgnoresStaleTerminalQueuedWhileRestarting() async throws {
        let initialRun = makeAttempt(
            attemptID: "attempt-initial",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = makeAttempt(
            attemptID: "attempt-recovered",
            sourceThreadID: "thread-1",
            turnID: "turn-2",
            activeTurnThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: initialRun)
        await backend.planNextRecoveredAttempt(recoveredRun)
        let recoverGate = AsyncGate()
        await backend.holdRestartPreparedReview(with: recoverGate)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(clock: testReviewWorkerClock { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForPrepareReviewRestart(timeout: .seconds(2))
            networkMonitor.yield(.satisfied())
            try await backend.waitForRestartPreparedReview(timeout: .seconds(2))
            await backend.yield(.cancelled("Network lost"), for: initialRun)
            await recoverGate.open()
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))

            await backend.yield(.completed(finalReview: "No issues found."), for: recoveredRun)
            let read = try await result

            #expect(read.presentation.status == .succeeded)
            #expect(read.core.attempt?.turnID.rawValue == "turn-2")
        }
    }

    @Test func networkRecoveryResubscribesWhenInterruptedEventStreamFinished() async throws {
        let initialRun = makeAttempt(
            attemptID: "attempt-initial",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = makeAttempt(
            attemptID: "attempt-recovered",
            sourceThreadID: "thread-1",
            turnID: "turn-2",
            activeTurnThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: initialRun)
        await backend.planNextRecoveredAttempt(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(clock: testReviewWorkerClock { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForPrepareReviewRestart(timeout: .seconds(2))
            await backend.finishEvents(for: initialRun)
            networkMonitor.yield(.satisfied())
            try await backend.waitForRestartPreparedReview(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))

            await backend.yield(.completed(finalReview: "No issues found."), for: recoveredRun)
            let read = try await result

            #expect(read.presentation.status == .succeeded)
            #expect(read.core.attempt?.turnID.rawValue == "turn-2")
        }
    }

    @Test func cancellationWhileRecoveryRestartIsInFlightStopsRecoveredRun() async throws {
        let initialRun = makeAttempt(
            attemptID: "attempt-initial",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = makeAttempt(
            attemptID: "attempt-recovered",
            sourceThreadID: "thread-1",
            turnID: "turn-2",
            activeTurnThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: initialRun)
        await backend.planNextRecoveredAttempt(recoveredRun)
        await backend.setDiscardedRestartAttempts([initialRun, recoveredRun])
        let recoverGate = AsyncGate()
        await backend.holdRestartPreparedReview(with: recoverGate)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(clock: testReviewWorkerClock { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForPrepareReviewRestart(timeout: .seconds(2))
            networkMonitor.yield(.satisfied())
            try await backend.waitForRestartPreparedReview(timeout: .seconds(2))

            let cancel = try await store.cancelReview(
                runID: makeRunID("run-1"),
                cancellation: .mcpClient(message: "Stop")
            )
            #expect(cancel.cancelled)
            await recoverGate.open()

            let read = try await result
            #expect(read.presentation.status == .cancelled)
            #expect(read.core.attempt?.turnID.rawValue == "turn-1")

            let commands = await backend.recordedCommands()
            #expect(
                commands.contains(
                    .interruptReview(
                        initialRun,
                        .init(message: "Stop")
                    )) == false)
            #expect(
                commands.contains(
                    .interruptReview(
                        recoveredRun,
                        .init(message: "Stop")
                    )))
            #expect(commands.contains(.cleanupReview(recoveredRun)))
            #expect(commands.filter { $0 == .cleanupReview(initialRun) }.count == 1)
        }
    }

    @Test func runtimeStopJoinsInFlightRestartAndCleansLateRecoveredRun() async throws {
        let initialRun = makeAttempt(
            attemptID: "attempt-initial",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = makeAttempt(
            attemptID: "attempt-recovered",
            sourceThreadID: "thread-1",
            turnID: "turn-2",
            activeTurnThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: initialRun)
        await backend.planNextRecoveredAttempt(recoveredRun)
        let recoverGate = AsyncGate()
        await backend.holdRestartPreparedReviewIgnoringCancellation(with: recoverGate)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(clock: testReviewWorkerClock { _ in })
        )
        let recorder = RuntimeStopCleanupRequestRecorder()
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForPrepareReviewRestart(timeout: .seconds(2))
            networkMonitor.yield(.satisfied())
            try await backend.waitForRestartPreparedReview(timeout: .seconds(2))

            let cleanupTask = Task { @MainActor in
                await store.cleanupActiveReviewsForRuntimeStop(
                    reason: .system(message: "Review runtime stopped.")
                ) { request in
                    await recorder.record(request)
                    return true
                }
            }
            try #require(
                await StoreSnapshotProbe(store: store)
                    .waitUntilRunStatus(.cancelled, runID: "run-1") != nil
            )
            #expect(store.runtimeReviewRunState(runID: makeRunID("run-1")).hasActiveWorker)
            await recoverGate.open()
            let cleanup = await cleanupTask.value
            let read = try await result
            let requests = await recorder.recordedRequests()

            #expect(cleanup.didComplete)
            #expect(requests.count == 2)
            #expect(requests.allSatisfy { $0.recoveryWaitingAttempts.isEmpty })
            #expect(read.presentation.status == .cancelled)
            #expect(read.core.cancellation?.message == "Review runtime stopped.")
            #expect(read.core.attempt?.turnID.rawValue == "turn-1")
            #expect(store.runtimeReviewRunState(runID: makeRunID("run-1")).hasActiveWorker == false)
            let commands = await backend.recordedCommands()
            #expect(
                commands.contains(
                    .interruptReview(
                        recoveredRun,
                        .init(message: "Review runtime stopped.")
                    )))
            #expect(commands.contains(.cleanupReview(recoveredRun)))
        }
    }

    @Test func cancellationAfterRecoveryEventStreamFinishesWakesWorker() async throws {
        let initialRun = makeAttempt(
            attemptID: "attempt-1",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: initialRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(clock: testReviewWorkerClock { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let running = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                waitTimeout: .milliseconds(20)
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForPrepareReviewRestart(timeout: .seconds(2))
            _ = try await running
            await backend.finishEvents(for: initialRun)

            let cancel = try await store.cancelReview(
                runID: makeRunID("run-1"),
                cancellation: .mcpClient(message: "Stop")
            )
            let cleanedUp = await waitUntil {
                let runtimeState = store.runtimeReviewRunState(runID: makeRunID("run-1"))
                return runtimeState.hasActiveWorker == false && runtimeState.activeAttempt == nil
            }
            let read = try store.readReview(runID: makeRunID("run-1"))

            #expect(cancel.cancelled)
            #expect(cleanedUp)
            #expect(read.presentation.status == .cancelled)
            #expect(read.core.cancellation?.message == "Stop")
        }
    }

    @Test func stopInterruptsActiveReviewBeforeMarkingRunStopped() async throws {
        let run = makeAttempt(
            attemptID: "attempt-1",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: run)
        let interruptGate = AsyncGate()
        await backend.holdInterruptReview(with: interruptGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            await store.start()
            async let running = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                waitTimeout: .milliseconds(20)
            )
            _ = try await running

            let stopTask = Task { @MainActor in
                await store.stop()
            }
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            let inFlight = try store.readReview(runID: makeRunID("run-1"))

            #expect(inFlight.presentation.status == .running)
            await interruptGate.open()
            await stopTask.value

            let commands = await backend.recordedCommands()
            #expect(commands.contains(.interruptReview(run, .init(message: "Review runtime stopped."))))
            #expect(store.reviewRun(id: makeRunID("run-1")) == nil)
            let runtimeState = store.runtimeReviewRunState(runID: makeRunID("run-1"))
            #expect(runtimeState.activeAttempt == nil)
            #expect(runtimeState.hasActiveWorker == false)
        }
    }

    @Test func runtimeStopCleanupHandsRecoveryWaitingRunsToBackendCleanup() async throws {
        let run = makeAttempt(
            attemptID: "attempt-1",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: run)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(clock: testReviewWorkerClock { _ in })
        )
        let recorder = RuntimeStopCleanupRequestRecorder()
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let running = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                waitTimeout: .milliseconds(20)
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForPrepareReviewRestart(timeout: .seconds(2))
            _ = try await running

            let result = await store.cleanupActiveReviewsForRuntimeStop(
                reason: .system(message: "Review runtime stopped.")
            ) { request in
                await recorder.record(request)
                return true
            }
            let requests = await recorder.recordedRequests()
            let read = try store.readReview(runID: makeRunID("run-1"))

            #expect(result.didComplete)
            #expect(requests.count == 2)
            #expect(requests.allSatisfy { $0.reason.message == "Review runtime stopped." })
            #expect(requests.allSatisfy { $0.recoveryWaitingAttempts == [run] })
            #expect(read.presentation.status == .cancelled)
            let runtimeState = store.runtimeReviewRunState(runID: makeRunID("run-1"))
            #expect(runtimeState.hasActiveWorker == false)
            #expect(runtimeState.activeAttempt == nil)
            #expect(runtimeState.isWaitingForNetworkRecovery == false)
        }
    }

    @Test func cancellationDuringNetworkRecoveryStopsWhenEventStreamFinishes() async throws {
        let initialRun = makeAttempt(
            attemptID: "attempt-1",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: initialRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(clock: testReviewWorkerClock { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForPrepareReviewRestart(timeout: .seconds(2))
            _ = try await store.cancelReview(
                runID: makeRunID("run-1"),
                cancellation: .mcpClient(message: "Stop")
            )
            await backend.finishEvents(for: initialRun)

            let read = try await result
            #expect(read.presentation.status == .cancelled)
            #expect(read.core.cancellation?.message == "Stop")
        }
    }

    @Test func userCancellationWinsOverPendingNetworkRecovery() async throws {
        let attempt = makeAttempt(fixtureID: "cancel-pending-recovery")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let debounceGate = AsyncGate()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(
                clock: testReviewWorkerClock { _ in
                    try? await debounceGate.wait()
                }
            )
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilRunStatus(.running, runID: "run-1") != nil)

            networkMonitor.yield(.init(status: .unsatisfied))
            _ = try await store.cancelReview(
                runID: makeRunID("run-1"),
                cancellation: .mcpClient(message: "Stop")
            )
            await debounceGate.open()
            await backend.yield(.cancelled("Stop"), for: attempt)
            let read = try await result

            #expect(read.presentation.status == .cancelled)
            let commands = await backend.recordedCommands()
            #expect(
                commands.contains { command in
                    if case .prepareReviewRestart = command {
                        true
                    } else {
                        false
                    }
                } == false)
            #expect(
                commands.contains { command in
                    if case .restartPreparedReview = command {
                        true
                    } else {
                        false
                    }
                } == false)
        }
    }

    @Test func sessionScopedCancelRejectsRunFromDifferentSession() async throws {
        let attempt = makeAttempt(fixtureID: "session-scoped-cancel")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(
                await StoreSnapshotProbe(store: store)
                    .waitUntilRunStatus(.running, runID: "run-1") != nil
            )

            await #expect(throws: (any Error).self) {
                try await store.cancelReview(
                    runID: makeRunID("run-1"),
                    sessionID: "session-2",
                    cancellation: .mcpClient(message: "Stop")
                )
            }
            #expect(try store.readReview(runID: makeRunID("run-1")).cancellable)

            await backend.yield(.completed(finalReview: "No issues found."), for: attempt)
            _ = try await result

            let commands = await backend.recordedCommands()
            #expect(
                commands.contains {
                    if case .interruptReview = $0 {
                        return true
                    }
                    return false
                } == false)
        }
    }

    @Test func cancelledReviewStaysCancelledWhenStreamClosesWithError() async throws {
        let attempt = makeAttempt(fixtureID: "cancelled-stream-close")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilRunStatus(.running, runID: "run-1") != nil)
            _ = try await store.cancelReview(
                runID: makeRunID("run-1"),
                cancellation: .mcpClient(message: "Stop")
            )
            await backend.finishEvents(throwing: StreamClosedError(), for: attempt)
            let read = try await result

            #expect(read.presentation.status == .cancelled)
            #expect(read.presentation.lifecycle.message == "Stop")
        }
    }

    @Test func failedReviewDoesNotRequireReviewText() async throws {
        let attempt = makeAttempt(fixtureID: "failed-no-output")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilRunStatus(.running, runID: "run-1") != nil)
            await backend.finishEvents(throwing: StreamClosedError(), for: attempt)
            let read = try await result

            #expect(read.presentation.status == .failed)
        }
    }

    @Test func serverInterruptionWithoutPendingCancellationFailsReview() async throws {
        let attempt = makeAttempt(fixtureID: "backend-interruption")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(
                await StoreSnapshotProbe(store: store)
                    .waitUntilRunStatus(.running, runID: "run-1") != nil
            )

            await backend.yield(.interrupted(message: nil), for: attempt)
            let read = try await result

            #expect(read.presentation.status == .failed)
            #expect(read.core.failure?.message == "Review was interrupted by the backend.")
            #expect(read.core.failure == .interruptedByBackend(message: nil))
        }
    }

    @Test func typedTerminalFailureSurvivesStoreCommit() async throws {
        let attempt = makeAttempt(fixtureID: "typed-terminal-failure")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        let failure = ReviewBackendFailure.invalidTerminalStatus(
            rawStatus: "future-terminal",
            turnID: makeTurnID("turn-1"),
            turnFailure: .init(
                message: "Future terminal failure",
                code: .unknown(rawValue: "future_code"),
                additionalDetails: "Preserve this detail"
            )
        )

        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(
                await StoreSnapshotProbe(store: store)
                    .waitUntilRunStatus(.running, runID: "run-1") != nil
            )

            await backend.yield(.failed(failure), for: attempt)
            let read = try await result

            #expect(read.presentation.status == .failed)
            #expect(read.core.failure == failure)
            #expect(
                read.core.failure?.message
                    == "Review ended with invalid terminal status future-terminal."
            )
        }
    }

    @Test func pendingNetworkOutageDefersStreamFailureUntilRecovery() async throws {
        let initialRun = makeAttempt(
            attemptID: "attempt-initial",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = makeAttempt(
            attemptID: "attempt-recovered",
            sourceThreadID: "thread-1",
            turnID: "turn-2",
            activeTurnThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: initialRun)
        await backend.planNextRecoveredAttempt(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let outageSleepStarted = AsyncGate()
        let debounceGate = AsyncGate()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(
                outageDebounce: .seconds(10),
                recoverySettle: .seconds(1),
                clock: testReviewWorkerClock { _ in
                    await outageSleepStarted.open()
                    try? await debounceGate.wait()
                }
            )
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilRunStatus(.running, runID: "run-1") != nil)

            networkMonitor.yield(.init(status: .unsatisfied))
            try? await outageSleepStarted.wait()
            await backend.yield(
                .failed(.connectionTerminated(.closed)),
                for: initialRun
            )

            let failedBeforeOutageConfirmed =
                await StoreSnapshotProbe(store: store)
                .waitUntilRunStatus(.failed, runID: "run-1", timeout: .milliseconds(100)) != nil
            #expect(failedBeforeOutageConfirmed == false)

            await debounceGate.open()
            try await backend.waitForPrepareReviewRestart(timeout: .seconds(2))
            networkMonitor.yield(.satisfied())
            try await backend.waitForRestartPreparedReview(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))

            await backend.yield(.completed(finalReview: "No issues found."), for: recoveredRun)
            let read = try await result

            #expect(read.presentation.status == .succeeded)
        }
    }

    @Test func terminalObservationCancellationWithoutParentFailsLoud() async throws {
        let attempt = makeAttempt(
            attemptID: "attempt-1",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "review-thread-1"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilRunStatus(.running, runID: "run-1") != nil)
            await backend.finishEvents(throwing: CancellationError(), for: attempt)
            let read = try await result

            #expect(read.presentation.status == .failed)
            #expect(
                read.core.failure == .protocolViolation(
                    message: "Review terminal observation was cancelled without parent cancellation."
                )
            )
            let commands = await backend.recordedCommands()
            #expect(
                commands.contains(
                    .interruptReview(
                        makeAttempt(
                            attemptID: "attempt-1",
                            sourceThreadID: "thread-1",
                            turnID: "turn-1",
                            activeTurnThreadID: "review-thread-1"
                        ),
                        .init(message: "Cancellation requested.")
                    )) == false)
        }
    }

    @Test func reviewStartTaskCancellationInterruptsBackendRun() async throws {
        let attempt = makeAttempt(
            attemptID: "attempt-1",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "review-thread-1"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let task = Task { @MainActor in
                try await store.startReview(
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
                )
            }
            task.cancel()
            let read = try await task.value

            #expect(read.presentation.status == .cancelled)
            let commands = await backend.recordedCommands()
            #expect(
                commands.contains(
                    .interruptReview(
                        makeAttempt(
                            attemptID: "attempt-1",
                            sourceThreadID: "thread-1",
                            turnID: "turn-1",
                            activeTurnThreadID: "review-thread-1"
                        ),
                        .init(message: "Cancellation requested.")
                    )))
        }
    }

    @Test func failedInterruptClearsCancellationRequestState() async throws {
        let attempt = makeAttempt(fixtureID: "failed-interrupt")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        await backend.failInterrupts(message: "Interrupt failed")
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilRunStatus(.running, runID: "run-1") != nil)
            await #expect(throws: ReviewBackendFailure.self) {
                try await store.cancelReview(
                    runID: makeRunID("run-1"),
                    cancellation: .mcpClient(message: "Stop")
                )
            }
            let readAfterFailure = try store.readReview(runID: makeRunID("run-1"))

            #expect(readAfterFailure.cancellable)
            #expect(readAfterFailure.core.cancellation == nil)
            #expect(readAfterFailure.presentation.lifecycle.message == "Review started.")

            await backend.yield(.completed(finalReview: "No issues found."), for: attempt)
            _ = try await result
        }
    }

    @Test func concurrentCancellationCallersJoinOneAcceptedOperation() async throws {
        let attempt = makeAttempt(fixtureID: "concurrent-cancellation")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let interruptGate = AsyncGate()
        await backend.holdInterruptReview(with: interruptGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let start = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            try #require(
                await StoreSnapshotProbe(store: store)
                    .waitUntilRunStatus(.running, runID: "run-1") != nil
            )

            async let first = store.cancelReview(
                runID: makeRunID("run-1"),
                cancellation: .mcpClient(message: "Stop")
            )
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            async let second = store.cancelReview(
                runID: makeRunID("run-1"),
                cancellation: .mcpClient(message: "Stop again")
            )
            await interruptGate.open()

            let firstOutcome = try await first
            let secondOutcome = try await second
            let final = try await start
            let interrupts = await backend.recordedCommands().filter {
                if case .interruptReview = $0 { true } else { false }
            }

            #expect(interrupts.count == 1)
            #expect(firstOutcome.presentation.status == .cancelled)
            #expect(secondOutcome.presentation.status == .cancelled)
            #expect(final.core.cancellation?.message == "Stop")
        }
    }

    @Test func cancellationCallerCanLeaveWithoutCancellingAcceptedOperation() async throws {
        let attempt = makeAttempt(fixtureID: "departing-cancellation-caller")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let interruptGate = AsyncGate()
        await backend.holdInterruptReview(with: interruptGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let start = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            try #require(
                await StoreSnapshotProbe(store: store)
                    .waitUntilRunStatus(.running, runID: "run-1") != nil
            )

            let firstCaller = Task { @MainActor in
                try await store.cancelReview(
                    runID: makeRunID("run-1"),
                    cancellation: .mcpClient(message: "Stop")
                )
            }
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            firstCaller.cancel()
            await #expect(throws: CancellationError.self) {
                try await firstCaller.value
            }

            async let joiningCaller = store.cancelReview(
                runID: makeRunID("run-1"),
                cancellation: .mcpClient(message: "Ignored replacement")
            )
            await interruptGate.open()
            let joined = try await joiningCaller
            let final = try await start
            let interrupts = await backend.recordedCommands().filter {
                if case .interruptReview = $0 { true } else { false }
            }

            #expect(interrupts.count == 1)
            #expect(joined.presentation.status == .cancelled)
            #expect(final.core.cancellation?.message == "Stop")
        }
    }

    @Test func terminalCancellationWinnerIgnoresLateInterruptFailure() async throws {
        let attempt = makeAttempt(fixtureID: "terminal-cancellation-winner")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let interruptGate = AsyncGate()
        await backend.holdInterruptReview(with: interruptGate)
        await backend.failInterrupts(message: "Late interrupt failure")
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let start = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            try #require(
                await StoreSnapshotProbe(store: store)
                    .waitUntilRunStatus(.running, runID: "run-1") != nil
            )
            async let cancel = store.cancelReview(
                runID: makeRunID("run-1"),
                cancellation: .mcpClient(message: "Stop")
            )
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            await backend.yield(.completed(finalReview: "Terminal won"), for: attempt)
            try #require(
                await StoreSnapshotProbe(store: store)
                    .waitUntilRunStatus(.cancelled, runID: "run-1") != nil
            )
            await interruptGate.open()

            let outcome = try await cancel
            let final = try await start
            #expect(outcome.presentation.status == .cancelled)
            #expect(final.presentation.status == .cancelled)
            #expect(final.core.cancellation?.message == "Stop")
        }
    }

    @Test func cancelledReviewIgnoresBufferedTerminalEvents() async throws {
        let attempt = makeAttempt(fixtureID: "cancelled-buffered-terminal")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilRunStatus(.running, runID: "run-1") != nil)
            _ = try await store.cancelReview(
                runID: makeRunID("run-1"),
                cancellation: .mcpClient(message: "Stop")
            )
            await backend.yield(.completed(finalReview: "No issues found."), for: attempt)
            let read = try await result

            #expect(read.presentation.status == .cancelled)
            #expect(read.presentation.lifecycle.message == "Stop")
        }
    }

    @Test func terminalEventDuringPendingCancellationKeepsCancelledState() async throws {
        let attempt = makeAttempt(fixtureID: "terminal-during-cancellation")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let interruptGate = AsyncGate()
        await backend.holdInterruptReview(with: interruptGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            try #require(
                await StoreSnapshotProbe(store: store)
                    .waitUntilRunStatus(.running, runID: "run-1") != nil
            )
            async let cancel = store.cancelReview(
                runID: makeRunID("run-1"),
                cancellation: .mcpClient(message: "Stop")
            )
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            await backend.yield(.interrupted(message: nil), for: attempt)
            await interruptGate.open()
            _ = try await cancel
            let read = try await result

            #expect(read.presentation.status == .cancelled)
            #expect(read.presentation.lifecycle.message == "Stop")
        }
    }

    @Test func cancelDuringReviewStartupInterruptsAfterRunBecomesAvailable() async throws {
        let attempt = makeAttempt(
            attemptID: "attempt-1",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "review-thread-1"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let gate = AsyncGate()
        await backend.holdStartReviewIgnoringCancellation(with: gate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            try await backend.waitForStartReview(timeout: .seconds(2))
            let cancel = try await store.cancelReview(
                runID: makeRunID("run-1"),
                cancellation: .mcpClient(message: "Stop")
            )
            let cancelledDuringStartup = try #require(store.reviewRuns.first)
            #expect(cancel.presentation.status == .cancelled)
            #expect(cancelledDuringStartup.presentation.status == .cancelled)
            await gate.open()
            let read = try await result

            #expect(cancel.cancelled)
            #expect(read.presentation.status == .cancelled)
            let commands = await backend.recordedCommands()
            #expect(
                commands.contains(
                    .interruptReview(
                        makeAttempt(
                            attemptID: "attempt-1",
                            sourceThreadID: "thread-1",
                            turnID: "turn-1",
                            activeTurnThreadID: "review-thread-1"
                        ),
                        .init(message: "Stop")
                    )))
            #expect(
                commands.contains(
                    .cleanupReview(
                        makeAttempt(
                            attemptID: "attempt-1",
                            sourceThreadID: "thread-1",
                            turnID: "turn-1",
                            activeTurnThreadID: "review-thread-1"
                        ))))
            #expect(
                commands.contains(
                    .cleanupRetainedReviews([
                        makeAttempt(
                            attemptID: "attempt-1",
                            sourceThreadID: "thread-1",
                            turnID: "turn-1",
                            activeTurnThreadID: "review-thread-1"
                        )
                    ])))
            #expect(
                try await store.reviewThreadRetentionRegistry
                    .snapshotForTesting().entries.isEmpty
            )
        }
    }

    @Test func cancelDuringReviewStartupRetainsFailedUnpublishedCleanup() async throws {
        let attempt = makeAttempt(
            attemptID: "attempt-1",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "review-thread-1"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let gate = AsyncGate()
        await backend.holdStartReviewIgnoringCancellation(with: gate)
        await backend.failRetainedCleanup(message: "Delete failed")
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            try await backend.waitForStartReview(timeout: .seconds(2))
            _ = try await store.cancelReview(
                runID: makeRunID("run-1"),
                cancellation: .mcpClient(message: "Stop")
            )

            await gate.open()
            let read = try await result
            let entries = try await store.reviewThreadRetentionRegistry
                .snapshotForTesting().entries

            #expect(read.presentation.status == .cancelled)
            #expect(entries.count == 1)
            #expect(entries.first?.runID == makeRunID("run-1"))
            #expect(entries.first?.attempts == [attempt])
        }
    }

    @Test func closedSessionRejectsNewReviews() async {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        await withStoreCommandTestCleanup(backend: backend, store: store) {
            _ = await store.closeSession("session-1")

            await #expect(throws: (any Error).self) {
                try await store.startReview(
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                )
            }
        }
    }

    @Test func closeSessionJoinsLateStartupCleanupBeforeReturningEvidence() async throws {
        let attempt = makeAttempt(
            attemptID: "attempt-1",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "review-thread-1"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let startGate = AsyncGate()
        await backend.holdStartReviewIgnoringCancellation(with: startGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let started = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            try await backend.waitForStartReview(timeout: .seconds(2))

            async let close = store.closeSession("session-1")
            try #require(
                await StoreSnapshotProbe(store: store)
                    .waitUntilRunStatus(.cancelled, runID: "run-1") != nil
            )
            await startGate.open()

            let evidence = await close
            let final = try await started
            #expect(evidence.terminalAndDrainedRunIDs == [makeRunID("run-1")])
            #expect(evidence.failedRunIDs.isEmpty)
            #expect(final.presentation.status == .cancelled)
            #expect(store.runtimeReviewRunState(runID: makeRunID("run-1")).hasActiveWorker == false)
            #expect(await backend.recordedCommands().contains(.cleanupReview(attempt)))

            #expect(store.closedSessions.contains("session-1"))
            store.releaseClosedSession("session-1")
            #expect(store.closedSessions.contains("session-1") == false)
        }
    }

    @Test func closeSessionStartsEveryMemberCancellationBeforeJoiningInterrupts() async throws {
        let firstAttempt = makeAttempt(
            attemptID: "attempt-1",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "review-thread-1"
        )
        let secondAttempt = makeAttempt(
            attemptID: "attempt-2",
            sourceThreadID: "thread-2",
            turnID: "turn-2",
            activeTurnThreadID: "review-thread-2"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: firstAttempt)
        let interruptGate = AsyncGate()
        await backend.holdInterruptReview(with: interruptGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let first = try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project-1", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            await backend.planNextAttempt(secondAttempt)
            let second = try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project-2", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )

            let close = Task { @MainActor in
                await store.closeSession("session-1")
            }
            try await backend.waitForInterruptReviews(count: 2, timeout: .seconds(2))

            let commands = await backend.recordedCommands()
            let interrupts = commands.filter {
                if case .interruptReview = $0 { true } else { false }
            }
            #expect(interrupts.count == 2)

            await interruptGate.open()
            let evidence = await close.value
            #expect(evidence.terminalAndDrainedRunIDs == [first.runID, second.runID])
            #expect(evidence.failedRunIDs.isEmpty)
        }
    }

    @Test func runningWorkerDoesNotRetainDroppedStore() async throws {
        let attempt = makeAttempt(
            attemptID: "attempt-1",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "review-thread-1"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        weak var weakStore: CodexReviewStore?
        var store: CodexReviewStore? = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        _ = try await store?.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .milliseconds(20)
        )
        weakStore = store

        store = nil

        #expect(weakStore == nil)
        try await backend.waitForCleanupReview(attempt, timeout: .seconds(2))
        await backend.finishEventMailboxes()
    }

    @Test func closeActiveReviewSessionsCancelsRunsWithoutClosingMCPServerSession() async throws {
        let attempt = makeAttempt(fixtureID: "close-active-sessions")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let started = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await started

            let didDrain = await store.closeActiveReviewSessions(
                reason: .system(message: "Account switched.")
            )

            #expect(didDrain)
            #expect(try store.readReview(runID: makeRunID("run-1")).presentation.status == .cancelled)
            #expect(store.closedSessions.contains("session-1") == false)
        }
    }

    @Test func closeActiveReviewSessionsJoinsCancelledStartupWorker() async throws {
        let attempt = makeAttempt(fixtureID: "close-startup-worker")
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let startGate = AsyncGate()
        await backend.holdStartReview(with: startGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let running = Task { @MainActor in
                try await store.startReview(
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                )
            }
            try await backend.waitForStartReview(timeout: .seconds(2))
            let didDrain = await store.closeActiveReviewSessions(
                reason: .system(message: "Account switched.")
            )

            #expect(didDrain)
            await startGate.open()
            let result = try await running.value
            #expect(result.presentation.status == .cancelled)
        }
    }

    @Test func authAndSettingsUseSingleBackendContract() async throws {
        let backend = FakeCodexReviewBackend(settings: .init(model: "gpt-5"))
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        await withStoreCommandTestCleanup(backend: backend, store: store) {
            await store.refreshSettings()

            #expect(store.settings.effectiveModel == "gpt-5")
        }
    }

    @Test func initialActiveAccountKeySelectsPersistedAccount() {
        let active = CodexReviewAccount(email: "active@example.com")
        let inactive = CodexReviewAccount(email: "inactive@example.com")
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(
                reviewBackend: backend,
                seed: .init(
                    initialAccounts: [inactive, active],
                    initialActiveAccountKey: active.accountKey
                )
            )
        )

        #expect(
            store.auth.persistedAccounts.map(\.accountKey) == [
                inactive.accountKey,
                active.accountKey,
            ])
        #expect(store.auth.persistedActiveAccountKey == active.accountKey)
        #expect(store.auth.selectedAccount?.accountKey == active.accountKey)
    }

    @Test func switchActionsAreUnavailableForSelectedAccount() async throws {
        let selectedAccount = CodexReviewAccount(email: "selected@example.com", planType: "pro")
        let otherAccount = CodexReviewAccount(email: "other@example.com", planType: "plus")
        let backend = SwitchRecordingBackend()
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        store.loadForTesting(
            serverState: .running,
            account: selectedAccount,
            persistedAccounts: [selectedAccount, otherAccount]
        )
        let displayedSelectedAccount = try #require(store.auth.selectedAccount)
        let displayedOtherAccount = try #require(
            store.auth.persistedAccounts.first { $0.accountKey == otherAccount.accountKey }
        )

        #expect(store.switchActionIsDisabled(for: displayedSelectedAccount))
        #expect(store.switchActionRequiresRunningReviewRunsConfirmation(for: displayedSelectedAccount) == false)
        #expect(store.switchActionIsDisabled(for: displayedOtherAccount) == false)
        #expect(store.switchActionRequiresRunningReviewRunsConfirmation(for: displayedOtherAccount))

        store.requestSwitchAccountFromUserAction(displayedSelectedAccount)
        await Task.yield()
        #expect(backend.switchRequests.isEmpty)

        try await store.switchAccount(displayedSelectedAccount)
        #expect(backend.switchRequests.isEmpty)

        try await store.switchAccount(displayedOtherAccount)
        #expect(backend.switchRequests == [displayedOtherAccount.accountKey])
    }

    @Test func fakeBackendPreservesSettingsCatalogWhenApplyingOverrides() async throws {
        let model = CodexReviewSettings.ModelCatalogItem(
            id: "gpt-5.5",
            model: "gpt-5.5",
            displayName: "GPT-5.5",
            hidden: false,
            supportedReasoningEfforts: [
                .init(reasoningEffort: .medium, description: "Balanced")
            ],
            defaultReasoningEffort: .medium,
            supportedServiceTiers: [.fast],
            isDefault: true
        )
        let backend = FakeCodexReviewBackend(
            settings: .init(
                fallbackModel: "gpt-5.5",
                models: [model]
            ))
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        await withStoreCommandTestCleanup(backend: backend, store: store) {
            await store.refreshSettings()
            await store.updateSettingsReasoningEffort(.medium)

            #expect(store.settings.effectiveModel == "gpt-5.5")
            #expect(store.settings.models == [model])
        }
    }

    @Test func primaryAuthenticationActionIsAvailableWhenRuntimeCanRecoverOrStartLogin() {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        store.loadForTesting(serverState: .stopped, authPhase: .signedOut)
        #expect(store.canPerformPrimaryAuthenticationAction)

        store.loadForTesting(serverState: .failed("Runtime failed."), authPhase: .signedOut)
        #expect(store.canPerformPrimaryAuthenticationAction)

        store.loadForTesting(serverState: .starting, authPhase: .signedOut)
        #expect(store.canPerformPrimaryAuthenticationAction == false)

        store.loadForTesting(serverState: .running, authPhase: .signedOut)
        #expect(store.canPerformPrimaryAuthenticationAction)

        store.auth.updatePhase(.signingIn(.init(title: "Sign in", detail: "Open browser.")))
        store.transitionToFailed("Runtime failed.")
        #expect(store.canPerformPrimaryAuthenticationAction)
    }

    @Test func primaryAuthenticationActionRestartsRecoverableRuntimeBeforeLogin() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            store.loadForTesting(serverState: .failed("Runtime failed."), authPhase: .signedOut)

            try await store.performPrimaryAuthenticationAction()

            #expect(store.serverState == .running)
            #expect(store.auth.isAuthenticating)
        }
    }
}

@MainActor
private final class SwitchRecordingBackend: PreviewCodexReviewStoreBackend {
    private(set) var switchRequests: [String] = []

    override func switchAccount(
        auth _: CodexReviewAuthModel,
        accountKey: String
    ) async throws {
        switchRequests.append(accountKey)
    }

    override func requiresCurrentSessionRecovery(
        auth _: CodexReviewAuthModel,
        accountKey _: String
    ) -> Bool {
        true
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while await condition() == false {
        if clock.now >= deadline {
            return false
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

@MainActor
private func waitForRunAttemptActivation(
    store: CodexReviewStore,
    run: ReviewAttempt,
    timeout: Duration = .seconds(2)
) async -> Bool {
    await StoreSnapshotProbe(store: store)
        .waitUntilRunAttempt(run.attemptID.rawValue, timeout: timeout) != nil
}

private func makeAttempt(
    attemptID: String,
    sourceThreadID: String,
    turnID: String,
    activeTurnThreadID: String,
    model: String? = nil
) -> ReviewAttempt {
    makeReviewAttemptForTesting(
        attemptID: attemptID,
        sourceThreadID: sourceThreadID,
        activeTurnThreadID: activeTurnThreadID,
        turnID: turnID,
        model: model
    )
}

private func makeAttempt(fixtureID: String) -> ReviewAttempt {
    makeReviewAttemptForTesting(
        attemptID: "attempt-\(fixtureID)",
        sourceThreadID: "source-\(fixtureID)",
        activeTurnThreadID: "active-\(fixtureID)",
        turnID: "turn-\(fixtureID)"
    )
}

private func makeTurnID(_ rawValue: String) -> ReviewTurnID {
    do {
        return try ReviewTurnID(validating: rawValue)
    } catch {
        preconditionFailure("Invalid explicit review turn fixture: \(error)")
    }
}

private func makeRunID(_ rawValue: String) -> ReviewRunID {
    do {
        return try ReviewRunID(validating: rawValue)
    } catch {
        preconditionFailure("Invalid explicit review run fixture: \(error)")
    }
}

private func makeThreadID(_ rawValue: String) -> ReviewThreadID {
    do {
        return try ReviewThreadID(validating: rawValue)
    } catch {
        preconditionFailure("Invalid explicit review thread fixture: \(error)")
    }
}

private func waitForTaskValue<T: Sendable>(
    _ task: Task<T, any Error>,
    timeout: Duration
) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask {
            try await task.value
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        let result = try await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

@MainActor
private func withStoreCommandTestCleanup(
    backend: FakeCodexReviewBackend,
    store: CodexReviewStore,
    operation: () async throws -> Void
) async rethrows {
    do {
        try await operation()
    } catch {
        await cleanupStoreCommandTest(backend: backend, store: store)
        throw error
    }
    await cleanupStoreCommandTest(backend: backend, store: store)
}

@MainActor
private func cleanupStoreCommandTest(
    backend: FakeCodexReviewBackend,
    store: CodexReviewStore
) async {
    await backend.finishEventMailboxes()
    await store.cancelAndDrainReviewWorkersForTesting()
    await backend.finishEventMailboxes()
}

private struct StreamClosedError: Error {}

private actor RuntimeStopCleanupRequestRecorder {
    private var requests: [CodexReviewRuntimeStopReviewCleanupRequest] = []

    func record(_ request: CodexReviewRuntimeStopReviewCleanupRequest) {
        requests.append(request)
    }

    func recordedRequests() -> [CodexReviewRuntimeStopReviewCleanupRequest] {
        requests
    }
}

private actor ControlledTestSleeper {
    private let gate: AsyncGate
    private var shouldBlock = false

    init(gate: AsyncGate) {
        self.gate = gate
    }

    func blockFutureSleeps() {
        shouldBlock = true
    }

    func sleep() async {
        if shouldBlock {
            try? await gate.wait()
        }
    }
}

private func testReviewWorkerClock(
    sleep: @escaping @Sendable (Duration) async throws -> Void
) -> ReviewWorkerClock {
    let now = ContinuousClock().now
    return .init(
        now: { now },
        sleep: sleep
    )
}

private final class MutableTestClock: @unchecked Sendable {
    var current: Date

    init(_ current: Date) {
        self.current = current
    }

    func now() -> Date {
        current
    }
}
