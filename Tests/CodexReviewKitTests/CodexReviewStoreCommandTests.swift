import Foundation
import Testing
@_spi(Testing) @testable import CodexReviewKit
import CodexReviewTesting

@Suite("Codex review store", .serialized)
@MainActor
struct CodexReviewStoreCommandTests {
    @Test func reviewStartPublishesCompletedRunAndRetainsResult() async throws {
        let backend = FakeCodexReviewBackend()
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
            await backend.yield(.log("started"))
            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            let read = try await result

            #expect(read.runID == "run-1")
            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.output.lastAgentMessage == "review text")
            #expect(store.listReviews(sessionID: nil).items.map(\.runID) == ["run-1"])

            let commands = await backend.recordedCommands()
            #expect(
                commands.contains(
                    .cleanupReview(
                        .init(
                            threadID: "thread-1",
                            turnID: "turn-1",
                            reviewThreadID: "review-thread-1"
                        ))))
        }
    }

    @Test func boundedReviewStartReturnsRunningSnapshotAndCanBeAwaitedLater() async throws {
        let backend = FakeCodexReviewBackend()
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

            #expect(running.runID == "run-1")
            #expect(running.core.lifecycle.status == .running)
            #expect(running.core.output.hasFinalReview == false)

            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            let final = try await store.awaitReview(
                sessionID: "session-1",
                runID: "run-1",
                timeout: .seconds(1)
            )

            #expect(final.core.lifecycle.status == .succeeded)
            #expect(final.core.output.lastAgentMessage == "review text")
        }
    }

    @Test func awaitReviewReturnsWhenRunningRunCompletes() async throws {
        let backend = FakeCodexReviewBackend()
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
                runID: "run-1",
                timeout: .seconds(1)
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            let final = try await awaited

            #expect(final.core.lifecycle.status == .succeeded)
            #expect(final.core.output.lastAgentMessage == "review text")
        }
    }

    @Test func awaitReviewReturnsWhenRunningRunIsCancelled() async throws {
        let backend = FakeCodexReviewBackend()
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
                runID: "run-1",
                timeout: .seconds(1)
            )
            _ = try await store.cancelReview(
                runID: "run-1",
                cancellation: .mcpClient(message: "Stop")
            )
            let final = try await awaited

            #expect(final.core.lifecycle.status == .cancelled)
            #expect(final.core.output.summary == "Stop")
        }
    }

    @Test func awaitReviewReturnsCurrentSnapshotOnTimeout() async throws {
        let backend = FakeCodexReviewBackend()
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
                runID: "run-1",
                timeout: .milliseconds(10)
            )

            #expect(snapshot.core.lifecycle.status == .running)
            #expect(snapshot.core.output.hasFinalReview == false)
        }
    }

    @Test func awaitReviewReturnsWhenLocalTerminationUpdatesRunOutput() async throws {
        let backend = FakeCodexReviewBackend()
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
                runID: "run-1",
                timeout: .seconds(1)
            )
            await Task.yield()
            store.terminateAllRunningReviewRunsLocally(
                failureMessage: "Review runtime stopped."
            )
            let final = try await awaited

            #expect(final.core.lifecycle.status == .failed)
            #expect(final.core.output.summary == "Failed to cancel review: Review runtime stopped.")
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
        let backend = FakeCodexReviewBackend()
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
            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
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

    @Test func reviewStartTracksAgentMessageDeltasByItemID() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.messageDelta("first", itemID: "message-1"))
            await backend.yield(.messageDelta("second", itemID: "message-2"))
            await backend.yield(.completed(summary: "Succeeded.", result: nil))
            let read = try await result

            #expect(read.core.output.lastAgentMessage == "second")
            #expect(read.core.reviewText == "second")
            #expect(store.reviewRun(id: "run-1")?.core.output.lastAgentMessage == "second")
        }
    }

    @Test func reviewStartParsesFinalReviewFindings() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(
                .completed(
                    summary: "Succeeded.",
                    result: """
                        Full review comments:
                        - [P2] Add parser tests — Sources/Parser.swift:12-15
                          The final review parser should be covered at the model layer.
                        """))
            let read = try await result

            #expect(read.core.output.hasFinalReview)
            #expect(read.core.output.reviewResult?.state == .hasFindings)
            #expect(read.core.output.reviewResult?.findingCount == 1)
            #expect(read.core.output.reviewResult?.findings.first?.title == "[P2] Add parser tests")
        }
    }

    @Test func newlyStartedWorkspaceAppearsBeforeExistingWorkspaces() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let first = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/old-project", target: .baseBranch("main"))
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "first"))
            _ = try await first
            await backend.finishEvents()

            async let second = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/new-project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "second"))
            _ = try await second

            #expect(store.orderedWorkspaces.map(\.cwd) == ["/tmp/new-project", "/tmp/old-project"])
        }
    }

    @Test func newlyStartedWorkspaceUsesSortOrderAboveCurrentMaximum() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            store.loadForTesting(
                serverState: .running,
                workspaces: [.init(cwd: "/tmp/old-project")]
            )
            store.workspace(cwd: "/tmp/old-project")?.sortOrder = 10

            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/new-project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "new"))
            _ = try await result

            #expect(store.orderedWorkspaces.map(\.cwd) == ["/tmp/new-project", "/tmp/old-project"])
        }
    }

    @Test func newlyStartedReviewAppearsBeforeExistingRunsInWorkspace() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let first = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "first"))
            _ = try await first
            await backend.finishEvents()

            async let second = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "second"))
            _ = try await second

            #expect(
                store.orderedReviewRuns(inWorkspace: "/tmp/project").map(\.targetSummary) == [
                    "Uncommitted changes",
                    "Base branch: main",
                ])
        }
    }

    @Test func runningReviewElapsedSecondsUsesInjectedClock() async throws {
        let backend = FakeCodexReviewBackend()
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

            #expect(try store.readReview(runID: "run-1").elapsedSeconds == 12)

            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            _ = try await result
        }
    }

    @Test func newlyStartedReviewUsesSortOrderAboveCurrentWorkspaceMaximum() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let existing = ReviewRunRecord.makeForTesting(
                id: "run-existing",
                cwd: "/tmp/project",
                targetSummary: "Existing",
                status: .succeeded,
                summary: "Done"
            )
            store.loadForTesting(
                serverState: .running,
                workspaces: [.init(cwd: "/tmp/project")],
                reviewRuns: [existing]
            )
            store.reviewRun(id: "run-existing")?.sortOrder = 10

            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "new"))
            _ = try await result

            #expect(store.orderedReviewRuns(inWorkspace: "/tmp/project").map(\.targetSummary).first == "Uncommitted changes")
        }
    }

    @Test func workspaceReorderBeforeAnchorMovesBlockAndReportsMutation() {
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        )
        let firstGroupedWorkspace = CodexReviewWorkspace(cwd: "/tmp/group-a-1")
        let secondWorkspace = CodexReviewWorkspace(cwd: "/tmp/workspace-b")
        let thirdWorkspace = CodexReviewWorkspace(cwd: "/tmp/workspace-c")
        let secondGroupedWorkspace = CodexReviewWorkspace(cwd: "/tmp/group-a-2")
        store.loadForTesting(
            serverState: .running,
            workspaces: [firstGroupedWorkspace, secondWorkspace, thirdWorkspace, secondGroupedWorkspace]
        )

        #expect(
            store.reorderWorkspaces(
                cwds: [firstGroupedWorkspace.cwd, secondGroupedWorkspace.cwd],
                beforeCWD: thirdWorkspace.cwd
            ))
        #expect(
            store.orderedWorkspaces.map(\.cwd) == [
                secondWorkspace.cwd,
                firstGroupedWorkspace.cwd,
                secondGroupedWorkspace.cwd,
                thirdWorkspace.cwd,
            ])
        #expect(
            store.reorderWorkspaces(cwds: [firstGroupedWorkspace.cwd], beforeCWD: firstGroupedWorkspace.cwd) == false)
        #expect(store.reorderWorkspaces(cwds: [firstGroupedWorkspace.cwd], beforeCWD: "/tmp/missing") == false)
    }

    @Test func runReorderBeforeAnchorMovesItemAndReportsMutation() {
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        )
        let workspace = CodexReviewWorkspace(cwd: "/tmp/project")
        let firstRun = ReviewRunRecord.makeForTesting(
            id: "run-first",
            cwd: workspace.cwd,
            targetSummary: "First",
            status: .running,
            summary: "Running"
        )
        let secondRun = ReviewRunRecord.makeForTesting(
            id: "run-second",
            cwd: workspace.cwd,
            targetSummary: "Second",
            status: .running,
            summary: "Running"
        )
        let thirdRun = ReviewRunRecord.makeForTesting(
            id: "run-third",
            cwd: workspace.cwd,
            targetSummary: "Third",
            status: .running,
            summary: "Running"
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            reviewRuns: [firstRun, secondRun, thirdRun]
        )

        #expect(store.reorderReviewRun(id: firstRun.id, inWorkspace: workspace.cwd, beforeRunID: thirdRun.id))
        #expect(store.orderedReviewRuns(in: workspace).map(\.id) == ["run-second", "run-first", "run-third"])
        #expect(store.reorderReviewRun(id: firstRun.id, inWorkspace: workspace.cwd, beforeRunID: firstRun.id) == false)
        #expect(store.reorderReviewRun(id: firstRun.id, inWorkspace: workspace.cwd, beforeRunID: "run-missing") == false)
    }

    @Test func cancelRunningReviewUsesBackendInterruptAndPublicState() async throws {
        let backend = FakeCodexReviewBackend()
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
                runID: "run-1",
                cancellation: .mcpClient(message: "Stop")
            )
            await backend.yield(.cancelled("Stop"))
            _ = try await result

            #expect(cancel.cancelled)
            #expect(try store.readReview(runID: "run-1").core.lifecycle.status == .cancelled)
            let commands = await backend.recordedCommands()
            #expect(
                commands.contains(
                    .interruptReview(
                        .init(threadID: "thread-1", turnID: "turn-1", reviewThreadID: "review-thread-1"),
                        .init(message: "Stop")
                    )))
        }
    }

    @Test func transientNetworkOutageDoesNotRecoverReview() async throws {
        let backend = FakeCodexReviewBackend()
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let debounceGate = AsyncGate()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(
                outageDebounce: .seconds(10),
                recoverySettle: .seconds(1),
                sleep: { _ in await debounceGate.wait() }
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

            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            let read = try await result
            #expect(read.core.lifecycle.status == .succeeded)
        }
    }

    @Test func sustainedNetworkOutageInterruptsForRecoveryWithoutTerminalRun() async throws {
        let backend = FakeCodexReviewBackend()
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForPrepareReviewRestart(timeout: .seconds(2))

            let running = try store.readReview(runID: "run-1")
            #expect(running.core.lifecycle.status == .running)
            #expect(running.core.output.summary == "Network unavailable; waiting to reconnect.")
            _ = try await store.cancelReview(runID: "run-1", cancellation: .mcpClient(message: "Stop"))
            await backend.yield(.cancelled("Stop"))
            _ = try await result
        }
    }

    @Test func networkRecoveryRepeatedSatisfiedSnapshotsRestartAfterLatestSettle() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
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
                sleep: { _ in await sleeper.sleep() }
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
                    store.reviewRun(id: "run-1")?.core.output.summary == "Network restored; restarting review."
                })
            networkMonitor.yield(.satisfied())
            await settleGate.open()
            try await backend.waitForRestartPreparedReview(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))

            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-2")
            #expect(read.core.output.lastAgentMessage == "recovered review")
        }
    }

    @Test func networkRecoveryUsesActualStartedTurn() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-response",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-recovered",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            await backend.yield(
                .started(
                    turnID: "turn-actual",
                    reviewThreadID: "review-thread-1",
                    model: "gpt-5"
                ), for: initialRun)
            #expect(
                await waitUntil {
                    store.reviewRun(id: "run-1")?.core.run.turnID == "turn-actual"
                })

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForPrepareReviewRestart(timeout: .seconds(2))
            let commandsAfterInterrupt = await backend.recordedCommands()
            let interruptedRuns = commandsAfterInterrupt.compactMap { command -> CodexReviewBackendModel.Review.Run? in
                if case .prepareReviewRestart(let run) = command {
                    return run
                }
                return nil
            }
            #expect(interruptedRuns.last?.turnID == "turn-actual")

            networkMonitor.yield(.satisfied())
            try await backend.waitForRestartPreparedReview(timeout: .seconds(2))
            let commandsAfterRecovery = await backend.recordedCommands()
            let recoveredFromRuns = commandsAfterRecovery.compactMap { command -> CodexReviewBackendModel.Review.Run? in
                if case .restartPreparedReview(let token, _) = command {
                    return token.interruptedRun
                }
                return nil
            }
            #expect(recoveredFromRuns.last?.turnID == "turn-actual")

            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))
            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-recovered")
        }
    }

    @Test func networkRecoveryIgnoresStaleCompletionAfterRecoveredSubscriptionStarts() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
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

            await backend.yield(.completed(summary: "Succeeded.", result: "stale review"), for: initialRun)
            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)

            let read = try await result
            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-2")
            #expect(read.core.output.lastAgentMessage == "recovered review")
        }
    }

    @Test func networkRecoveryIgnoresStaleTerminalQueuedWhileRestarting() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let recoverGate = AsyncGate()
        await backend.holdRestartPreparedReview(with: recoverGate)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
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

            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-2")
            #expect(read.core.output.lastAgentMessage == "recovered review")
        }
    }

    @Test func networkRecoveryResubscribesWhenInterruptedEventStreamFinished() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
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

            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-2")
            #expect(read.core.output.lastAgentMessage == "recovered review")
        }
    }

    @Test func cancellationWhileRecoveryRestartIsInFlightStopsRecoveredRun() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let recoverGate = AsyncGate()
        await backend.holdRestartPreparedReview(with: recoverGate)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
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

            let cancel = try await store.cancelReview(runID: "run-1", cancellation: .mcpClient(message: "Stop"))
            #expect(cancel.cancelled)
            await recoverGate.open()

            let read = try await result
            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.run.turnID == "turn-1")

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
        }
    }

    @Test func runtimeStopWhileRecoveryRestartIsInFlightDetachesAndStopsRecoveredRun() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let recoverGate = AsyncGate()
        await backend.holdRestartPreparedReview(with: recoverGate)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
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
                    reason: .system(message: "Review runtime stopped."),
                    workerDrainTimeout: .seconds(2)
                ) { request in
                    await recorder.record(request)
                    return true
                }
            }
            try #require(
                await waitUntil {
                    let state = store.runtimeReviewRunState(runID: "run-1")
                    return state.hasActiveWorker == false && state.activeRun == nil
                })
            await recoverGate.open()
            let cleanup = await cleanupTask.value
            let read = try await result
            let request = try #require(await recorder.onlyRequest())

            #expect(cleanup.didComplete)
            #expect(request.recoveryWaitingRuns == [initialRun])
            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.lifecycle.cancellation?.message == "Review runtime stopped.")
            #expect(read.core.run.turnID == "turn-1")
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
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
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

            let cancel = try await store.cancelReview(runID: "run-1", cancellation: .mcpClient(message: "Stop"))
            let cleanedUp = await waitUntil {
                let runtimeState = store.runtimeReviewRunState(runID: "run-1")
                return runtimeState.hasActiveWorker == false && runtimeState.activeRun == nil
            }
            let read = try store.readReview(runID: "run-1")

            #expect(cancel.cancelled)
            #expect(cleanedUp)
            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.lifecycle.cancellation?.message == "Stop")
        }
    }

    @Test func runtimeStopLocalCancellationDetachesWorker() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: run)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let running = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                waitTimeout: .milliseconds(20)
            )
            _ = try await running

            let locallyCancelledReviewRunIDs = store.cancelActiveReviewsLocallyForRuntimeStop(
                reason: .system(message: "Review runtime stopped."),
                cancelWorkers: false
            )
            let cancelled = try store.readReview(runID: "run-1")

            #expect(locallyCancelledReviewRunIDs == ["run-1"])
            #expect(cancelled.core.lifecycle.status == .cancelled)
            let runtimeStateBeforeDetach = store.runtimeReviewRunState(runID: "run-1")
            #expect(runtimeStateBeforeDetach.hasActiveWorker)
            #expect(runtimeStateBeforeDetach.activeRun == run)

            store.cancelAndDetachReviewWorkersForRuntimeStop(runIDs: locallyCancelledReviewRunIDs)

            let runtimeStateAfterDetach = store.runtimeReviewRunState(runID: "run-1")
            #expect(runtimeStateAfterDetach.hasActiveWorker == false)
            #expect(runtimeStateAfterDetach.activeRun == nil)
        }
    }

    @Test func stopInterruptsActiveReviewBeforeMarkingRunStopped() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: run)
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
            let inFlight = try store.readReview(runID: "run-1")

            #expect(inFlight.core.lifecycle.status == .running)
            await interruptGate.open()
            await stopTask.value

            let stopped = try store.readReview(runID: "run-1")
            let commands = await backend.recordedCommands()
            #expect(commands.contains(.interruptReview(run, .init(message: "Review runtime stopped."))))
            #expect(stopped.core.lifecycle.status == .cancelled)
            let runtimeState = store.runtimeReviewRunState(runID: "run-1")
            #expect(runtimeState.activeRun == nil)
            #expect(runtimeState.hasActiveWorker == false)
        }
    }

    @Test func runtimeStopDetachesNetworkRecoveryWaitingWorker() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: run)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
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

            let locallyCancelledReviewRunIDs = store.cancelActiveReviewsLocallyForRuntimeStop(
                reason: .system(message: "Review runtime stopped."),
                cancelWorkers: false
            )
            store.cancelAndDetachReviewWorkersForRuntimeStop(runIDs: locallyCancelledReviewRunIDs)

            let runtimeState = store.runtimeReviewRunState(runID: "run-1")
            #expect(runtimeState.hasActiveWorker == false)
            #expect(runtimeState.activeRun == nil)
            #expect(runtimeState.isWaitingForNetworkRecovery == false)
        }
    }

    @Test func runtimeStopCleanupHandsRecoveryWaitingRunsToBackendCleanup() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: run)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
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
                reason: .system(message: "Review runtime stopped."),
                workerDrainTimeout: .seconds(2)
            ) { request in
                await recorder.record(request)
                return true
            }
            let request = try #require(await recorder.onlyRequest())
            let read = try store.readReview(runID: "run-1")

            #expect(result.didComplete)
            #expect(request.reason.message == "Review runtime stopped.")
            #expect(request.recoveryWaitingRuns == [run])
            #expect(read.core.lifecycle.status == .cancelled)
            let runtimeState = store.runtimeReviewRunState(runID: "run-1")
            #expect(runtimeState.hasActiveWorker == false)
            #expect(runtimeState.activeRun == nil)
            #expect(runtimeState.isWaitingForNetworkRecovery == false)
        }
    }

    @Test func runtimeStopCanDrainDetachedWorkerCleanup() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: run)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let running = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                waitTimeout: .milliseconds(20)
            )
            _ = try await running

            let locallyCancelledReviewRunIDs = store.cancelActiveReviewsLocallyForRuntimeStop(
                reason: .system(message: "Review runtime stopped."),
                cancelWorkers: false
            )
            store.cancelAndDetachReviewWorkersForRuntimeStop(runIDs: locallyCancelledReviewRunIDs)

            #expect(await store.drainRuntimeStopDetachedReviewWorkers(timeout: .seconds(2)))
            #expect(store.runtimeReviewRunState(runID: "run-1").hasDetachedWorker == false)
            #expect(await backend.recordedCommands().contains(.cleanupReview(run)))
        }
    }

    @Test func runtimeStopDetachLetsStartReviewReturnWhenBackendStartIsStuck() async throws {
        let backend = FakeCodexReviewBackend()
        let startReviewGate = AsyncGate()
        await backend.holdStartReview(with: startReviewGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let running = Task { @MainActor in
                try await store.startReview(
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
                )
            }
            try await backend.waitForStartReview(timeout: .seconds(2))

            let locallyCancelledReviewRunIDs = store.cancelActiveReviewsLocallyForRuntimeStop(
                reason: .system(message: "Review runtime stopped."),
                cancelWorkers: false
            )
            store.cancelAndDetachReviewWorkersForRuntimeStop(runIDs: locallyCancelledReviewRunIDs)
            let resultBeforeStartReviewUnblocked = try await waitForTaskValue(running, timeout: .seconds(1))
            await startReviewGate.open()
            let result = try #require(resultBeforeStartReviewUnblocked)

            #expect(locallyCancelledReviewRunIDs == ["run-1"])
            #expect(result.core.lifecycle.status == .cancelled)
            let runtimeState = store.runtimeReviewRunState(runID: "run-1")
            #expect(runtimeState.hasActiveWorker == false)
            #expect(runtimeState.activeRun == nil)
        }
    }

    @Test func cancellationDuringNetworkRecoveryStopsWhenEventStreamFinishes() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForPrepareReviewRestart(timeout: .seconds(2))
            _ = try await store.cancelReview(runID: "run-1", cancellation: .mcpClient(message: "Stop"))
            await backend.finishEvents(for: initialRun)

            let read = try await result
            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.lifecycle.cancellation?.message == "Stop")
        }
    }

    @Test func userCancellationWinsOverPendingNetworkRecovery() async throws {
        let backend = FakeCodexReviewBackend()
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let debounceGate = AsyncGate()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in await debounceGate.wait() })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilRunStatus(.running, runID: "run-1") != nil)

            networkMonitor.yield(.init(status: .unsatisfied))
            _ = try await store.cancelReview(runID: "run-1", cancellation: .mcpClient(message: "Stop"))
            await debounceGate.open()
            await backend.yield(.cancelled("Stop"))
            let read = try await result

            #expect(read.core.lifecycle.status == .cancelled)
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
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            await #expect(throws: (any Error).self) {
                try await store.cancelReview(
                    runID: "run-1",
                    sessionID: "session-2",
                    cancellation: .mcpClient(message: "Stop")
                )
            }
            #expect(try store.readReview(runID: "run-1").cancellable)

            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
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
        let backend = FakeCodexReviewBackend()
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
                runID: "run-1",
                cancellation: .mcpClient(message: "Stop")
            )
            await backend.finishEvents(throwing: StreamClosedError())
            let read = try await result

            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.output.summary == "Stop")
        }
    }

    @Test func failedReviewPreservesBufferedEventsBeforeStreamError() async throws {
        let backend = FakeCodexReviewBackend()
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
            await backend.yield(.message("partial review"))
            await backend.finishEvents(throwing: StreamClosedError())
            let read = try await result

            #expect(read.core.lifecycle.status == .failed)
            #expect(read.core.output.lastAgentMessage == "partial review")
        }
    }

    @Test func pendingNetworkOutageDefersStreamFailureUntilRecovery() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
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
                sleep: { _ in
                    await outageSleepStarted.open()
                    await debounceGate.wait()
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
            await outageSleepStarted.wait()
            await backend.finishEvents(throwing: StreamClosedError(), for: initialRun)

            let failedBeforeOutageConfirmed =
                await StoreSnapshotProbe(store: store)
                .waitUntilRunStatus(.failed, runID: "run-1", timeout: .milliseconds(100)) != nil
            #expect(failedBeforeOutageConfirmed == false)

            await debounceGate.open()
            try await backend.waitForPrepareReviewRestart(timeout: .seconds(2))
            networkMonitor.yield(.satisfied())
            try await backend.waitForRestartPreparedReview(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))

            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.output.lastAgentMessage == "recovered review")
        }
    }

    @Test func reviewStartCancellationInterruptsBackendRun() async throws {
        let backend = FakeCodexReviewBackend()
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
            await backend.finishEvents(throwing: CancellationError())
            let read = try await result

            #expect(read.core.lifecycle.status == .cancelled)
            let commands = await backend.recordedCommands()
            #expect(
                commands.contains(
                    .interruptReview(
                        .init(threadID: "thread-1", turnID: "turn-1", reviewThreadID: "review-thread-1"),
                        .init(message: "Cancellation requested.")
                    )))
        }
    }

    @Test func reviewStartTaskCancellationInterruptsBackendRun() async throws {
        let backend = FakeCodexReviewBackend()
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

            #expect(read.core.lifecycle.status == .cancelled)
            let commands = await backend.recordedCommands()
            #expect(
                commands.contains(
                    .interruptReview(
                        .init(threadID: "thread-1", turnID: "turn-1", reviewThreadID: "review-thread-1"),
                        .init(message: "Cancellation requested.")
                    )))
        }
    }

    @Test func failedInterruptClearsCancellationRequestState() async throws {
        let backend = FakeCodexReviewBackend()
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
            await #expect(throws: FakeCodexReviewBackendError.self) {
                try await store.cancelReview(
                    runID: "run-1",
                    cancellation: .mcpClient(message: "Stop")
                )
            }
            let readAfterFailure = try store.readReview(runID: "run-1")

            #expect(readAfterFailure.cancellable)
            #expect(readAfterFailure.core.lifecycle.cancellation == nil)
            #expect(readAfterFailure.core.output.summary == "Failed to cancel review: Interrupt failed")

            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            _ = try await result
        }
    }

    @Test func cancelledReviewIgnoresBufferedTerminalEvents() async throws {
        let backend = FakeCodexReviewBackend()
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
                runID: "run-1",
                cancellation: .mcpClient(message: "Stop")
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "late result"))
            let read = try await result

            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.output.summary == "Stop")
            #expect(read.core.output.lastAgentMessage == nil)
        }
    }

    @Test func terminalEventDuringPendingCancellationKeepsCancelledState() async throws {
        let backend = FakeCodexReviewBackend()
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
            async let cancel = store.cancelReview(runID: "run-1", cancellation: .mcpClient(message: "Stop"))
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            await backend.yield(.completed(summary: "Reviewer failed to output a response.", result: nil))
            await interruptGate.open()
            _ = try await cancel
            let read = try await result

            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.output.summary == "Stop")
            #expect(read.core.output.hasFinalReview == false)
        }
    }

    @Test func cancelDuringReviewStartupInterruptsAfterRunBecomesAvailable() async throws {
        let backend = FakeCodexReviewBackend()
        let gate = AsyncGate()
        await backend.holdStartReview(with: gate)
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
            let cancel = try await store.cancelReview(runID: "run-1", cancellation: .mcpClient(message: "Stop"))
            let cancelledDuringStartup = try #require(store.reviewRuns.first)
            #expect(cancel.core.lifecycle.status == .cancelled)
            #expect(cancelledDuringStartup.core.lifecycle.status == .cancelled)
            await gate.open()
            let read = try await result

            #expect(cancel.cancelled)
            #expect(read.core.lifecycle.status == .cancelled)
            let commands = await backend.recordedCommands()
            #expect(
                commands.contains(
                    .interruptReview(
                        .init(threadID: "thread-1", turnID: "turn-1", reviewThreadID: "review-thread-1"),
                        .init(message: "Stop")
                    )))
            #expect(
                commands.contains(
                    .cleanupReview(
                        .init(
                            threadID: "thread-1",
                            turnID: "turn-1",
                            reviewThreadID: "review-thread-1"
                        ))))
        }
    }

    @Test func closedSessionRejectsNewReviews() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        await withStoreCommandTestCleanup(backend: backend, store: store) {
            await store.closeSession("session-1")

            await #expect(throws: (any Error).self) {
                try await store.startReview(
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                )
            }
        }
    }

    @Test func closeActiveReviewSessionsCancelsRunsWithoutClosingMCPServerSession() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let running = ReviewRunRecord.makeForTesting(
                id: "running-run",
                sessionID: "session-1",
                cwd: "/tmp/project",
                targetSummary: "Running",
                status: .running,
                summary: "Running"
            )
            store.loadForTesting(
                serverState: .running,
                workspaces: [.init(cwd: "/tmp/project")],
                reviewRuns: [running]
            )

            await store.closeActiveReviewSessions(reason: .system(message: "Account switched."))

            #expect(running.core.lifecycle.status == .cancelled)
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            let read = try await result

            #expect(read.runID == "run-1")
            #expect(read.core.lifecycle.status == .succeeded)
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
            persistedAccounts: [selectedAccount, otherAccount],
            workspaces: []
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

        store.loadForTesting(serverState: .stopped, authPhase: .signedOut, workspaces: [])
        #expect(store.canPerformPrimaryAuthenticationAction)

        store.loadForTesting(serverState: .failed("Runtime failed."), authPhase: .signedOut, workspaces: [])
        #expect(store.canPerformPrimaryAuthenticationAction)

        store.loadForTesting(serverState: .starting, authPhase: .signedOut, workspaces: [])
        #expect(store.canPerformPrimaryAuthenticationAction == false)

        store.loadForTesting(serverState: .running, authPhase: .signedOut, workspaces: [])
        #expect(store.canPerformPrimaryAuthenticationAction)

        store.auth.updatePhase(.signingIn(.init(title: "Sign in", detail: "Open browser.")))
        store.transitionToFailed("Runtime failed.")
        #expect(store.canPerformPrimaryAuthenticationAction)
    }

    @Test func primaryAuthenticationActionRestartsRecoverableRuntimeBeforeLogin() async {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        await withStoreCommandTestCleanup(backend: backend, store: store) {
            store.loadForTesting(serverState: .failed("Runtime failed."), authPhase: .signedOut, workspaces: [])

            await store.performPrimaryAuthenticationAction()

            #expect(store.serverState == .running)
            #expect(store.auth.isAuthenticating)
            let commands = await backend.recordedCommands()
            #expect(
                commands.contains { command in
                    if case .startLogin = command {
                        return true
                    }
                    return false
                })
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
    run: CodexReviewBackendModel.Review.Run,
    timeout: Duration = .seconds(2)
) async -> Bool {
    await StoreSnapshotProbe(store: store)
        .waitUntilRunAttempt(run.attemptID, timeout: timeout) != nil
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

    func onlyRequest() -> CodexReviewRuntimeStopReviewCleanupRequest? {
        requests.count == 1 ? requests[0] : nil
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
            await gate.wait()
        }
    }
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
