import Foundation
import Testing
@_spi(Testing) @testable import CodexReview
import CodexReviewTesting

@Suite("Codex review store")
@MainActor
struct CodexReviewStoreCommandTests {
    @Test func reviewStartPublishesCompletedJobAndRetainsResult() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            clock: .init(now: { Date(timeIntervalSince1970: 1) }),
            idGenerator: .init(next: { "job-1" })
        )

        async let result = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await backend.waitForEventStream()
        await backend.yield(.log("started"))
        await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
        let read = try await result

        #expect(read.jobID == "job-1")
        #expect(read.core.lifecycle.status == .succeeded)
        #expect(read.core.output.lastAgentMessage == "review text")
        #expect(store.listReviews(sessionID: nil).items.map(\.jobID) == ["job-1"])

        let commands = await backend.recordedCommands()
        #expect(commands.contains(.cleanupReview(.init(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        ))))
    }

    @Test func forceStartWhileRunningInvokesBackendRestartPath() async {
        let backend = TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        await store.start()
        await store.start()
        await store.start(forceRestartIfNeeded: true)

        #expect(backend.startRequests == [false, true])
    }

    @Test func reviewStartPassesEffectiveSettingsModelToBackend() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(
                reviewBackend: backend,
                seed: .init(initialSettingsSnapshot: .init(fallbackModel: "gpt-5.5"))
            ),
            idGenerator: .init(next: { "job-1" })
        )

        async let result = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await backend.waitForEventStream()
        await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
        _ = try await result

        let commands = await backend.recordedCommands()
        let starts = commands.compactMap { command -> BackendReviewStart? in
            if case .startReview(let request) = command {
                return request
            }
            return nil
        }
        #expect(starts.first?.model == "gpt-5.5")
    }

    @Test func reviewStartAppliesStartedTurnAndMergesAgentMessageDeltas() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )

        async let result = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await backend.waitForEventStream()
        await backend.yield(.started(turnID: "turn-actual", reviewThreadID: "review-thread-1", model: "gpt-5.5"))
        await backend.yield(.messageDelta("hello", itemID: "message-1"))
        await backend.yield(.messageDelta(" world", itemID: "message-1"))
        await backend.yield(.logEntry(
            kind: .reasoningSummary,
            text: " with space",
            groupID: "reasoning-1",
            replacesGroup: false
        ))
        await backend.yield(.completed(summary: "Succeeded.", result: nil))
        let read = try await result

        #expect(read.core.run.turnID == "turn-actual")
        #expect(read.core.output.lastAgentMessage == "hello world")
        #expect(read.rawLogText.isEmpty)
        #expect(try store.readReview(jobID: "job-1").logs.map(\.text) == [
            "Turn started: turn-actual",
            "hello",
            " world",
            " with space",
        ])
        #expect(try #require(store.job(id: "job-1")).reviewOutputText == "hello world\n\n with space")
        #expect(try store.readReview(jobID: "job-1").core.run.model == "gpt-5.5")
    }

    @Test func reviewStartTracksAgentMessageDeltasByItemID() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )

        async let result = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await backend.waitForEventStream()
        await backend.yield(.messageDelta("first", itemID: "message-1"))
        await backend.yield(.messageDelta("second", itemID: "message-2"))
        await backend.yield(.completed(summary: "Succeeded.", result: nil))
        let read = try await result

        #expect(read.core.output.lastAgentMessage == "second")
        #expect(read.core.reviewText == "second")
        #expect(try store.readReview(jobID: "job-1").logs.map(\.text) == ["first", "second"])
    }

    @Test func readReviewDefaultsToCommandOutputFilteredLogs() throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let job = CodexReviewJob.makeForTesting(
            id: "job-1",
            cwd: "/tmp/project",
            targetSummary: "Uncommitted changes",
            status: .succeeded,
            summary: "Done",
            logEntries: [
                .init(kind: .event, text: "Turn started: turn-1"),
                .init(kind: .progress, text: "Reviewing current changes"),
                .init(kind: .command, groupID: "cmd-1", text: "$ swift test"),
                .init(kind: .commandOutput, groupID: "cmd-1", text: "Tests passed"),
                .init(kind: .plan, groupID: "plan-1", text: "Plan text"),
                .init(kind: .todoList, groupID: "turn-1", text: "[inProgress] Inspect diff"),
                .init(kind: .reasoningSummary, groupID: "reasoning-1:summary:0", text: "Reasoning summary"),
                .init(kind: .rawReasoning, groupID: "reasoning-1:0", text: "Raw reasoning"),
                .init(kind: .toolCall, groupID: "tool-1", text: "MCP tool started"),
                .init(kind: .diagnostic, text: "Warning"),
                .init(kind: .error, text: "Recoverable error"),
                .init(kind: .agentMessage, text: "No correctness issues found."),
            ]
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [.init(cwd: "/tmp/project")],
            jobs: [job]
        )

        #expect(try store.readReview(jobID: "job-1").logs.map(\.kind) == [
            .event,
            .progress,
            .command,
            .plan,
            .todoList,
            .reasoningSummary,
            .rawReasoning,
            .toolCall,
            .diagnostic,
            .error,
            .agentMessage,
        ])
        #expect(try store.readReview(jobID: "job-1", logFilter: .all).logs.map(\.kind) == [
            .event,
            .progress,
            .command,
            .commandOutput,
            .plan,
            .todoList,
            .reasoningSummary,
            .rawReasoning,
            .toolCall,
            .diagnostic,
            .error,
            .agentMessage,
        ])
    }

    @Test func reviewStartParsesFinalReviewFindings() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )

        async let result = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await backend.waitForEventStream()
        await backend.yield(.completed(summary: "Succeeded.", result: """
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

    @Test func newlyStartedWorkspaceAppearsBeforeExistingWorkspaces() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        async let first = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/old-project", target: .baseBranch("main"))
        )
        await backend.waitForEventStream()
        await backend.yield(.completed(summary: "Succeeded.", result: "first"))
        _ = try await first
        await backend.finishEvents()

        async let second = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/new-project", target: .uncommittedChanges)
        )
        await backend.waitForEventStream()
        await backend.yield(.completed(summary: "Succeeded.", result: "second"))
        _ = try await second

        #expect(store.orderedWorkspaces.map(\.cwd) == ["/tmp/new-project", "/tmp/old-project"])
    }

    @Test func newlyStartedWorkspaceUsesSortOrderAboveCurrentMaximum() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [.init(cwd: "/tmp/old-project")]
        )
        store.workspace(cwd: "/tmp/old-project")?.sortOrder = 10

        async let result = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/new-project", target: .uncommittedChanges)
        )
        await backend.waitForEventStream()
        await backend.yield(.completed(summary: "Succeeded.", result: "new"))
        _ = try await result

        #expect(store.orderedWorkspaces.map(\.cwd) == ["/tmp/new-project", "/tmp/old-project"])
    }

    @Test func newlyStartedReviewAppearsBeforeExistingJobsInWorkspace() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        async let first = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
        )
        await backend.waitForEventStream()
        await backend.yield(.completed(summary: "Succeeded.", result: "first"))
        _ = try await first
        await backend.finishEvents()

        async let second = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await backend.waitForEventStream()
        await backend.yield(.completed(summary: "Succeeded.", result: "second"))
        _ = try await second

        #expect(store.orderedJobs(inWorkspace: "/tmp/project").map(\.targetSummary) == [
            "Uncommitted changes",
            "Base branch: main",
        ])
    }

    @Test func runningReviewElapsedSecondsUsesInjectedClock() async throws {
        let backend = FakeCodexReviewBackend()
        let clock = MutableTestClock(Date(timeIntervalSince1970: 1))
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            clock: .init(now: { clock.now() }),
            idGenerator: .init(next: { "job-1" })
        )

        async let result = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await backend.waitForEventStream()
        clock.current = Date(timeIntervalSince1970: 13)

        #expect(try store.readReview(jobID: "job-1").elapsedSeconds == 12)

        await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
        _ = try await result
    }

    @Test func newlyStartedReviewUsesSortOrderAboveCurrentWorkspaceMaximum() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let existing = CodexReviewJob.makeForTesting(
            id: "job-existing",
            cwd: "/tmp/project",
            targetSummary: "Existing",
            status: .succeeded,
            summary: "Done"
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [.init(cwd: "/tmp/project")],
            jobs: [existing]
        )
        store.job(id: "job-existing")?.sortOrder = 10

        async let result = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await backend.waitForEventStream()
        await backend.yield(.completed(summary: "Succeeded.", result: "new"))
        _ = try await result

        #expect(store.orderedJobs(inWorkspace: "/tmp/project").map(\.targetSummary).first == "Uncommitted changes")
    }

    @Test func cancelRunningReviewUsesBackendInterruptAndPublicState() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )

        async let result = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
        )
        await backend.waitForEventStream()
        let cancel = try await store.cancelReview(
            jobID: "job-1",
            cancellation: .mcpClient(message: "Stop")
        )
        await backend.yield(.cancelled("Stop"))
        _ = try await result

        #expect(cancel.cancelled)
        #expect(try store.readReview(jobID: "job-1").core.lifecycle.status == .cancelled)
        let commands = await backend.recordedCommands()
        #expect(commands.contains(.interruptReview(
            .init(threadID: "thread-1", turnID: "turn-1", reviewThreadID: "review-thread-1"),
            .init(message: "Stop")
        )))
    }

    @Test func sessionScopedCancelRejectsJobFromDifferentSession() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )

        async let result = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
        )
        await backend.waitForEventStream()

        await #expect(throws: (any Error).self) {
            try await store.cancelReview(
                jobID: "job-1",
                sessionID: "session-2",
                cancellation: .mcpClient(message: "Stop")
            )
        }
        #expect(try store.readReview(jobID: "job-1").cancellable)

        await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
        _ = try await result

        let commands = await backend.recordedCommands()
        #expect(commands.contains {
            if case .interruptReview = $0 {
                return true
            }
            return false
        } == false)
    }

    @Test func cancelledReviewStaysCancelledWhenStreamClosesWithError() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )

        async let result = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
        )
        await backend.waitForEventStream()
        _ = try await store.cancelReview(
            jobID: "job-1",
            cancellation: .mcpClient(message: "Stop")
        )
        await backend.finishEvents(throwing: StreamClosedError())
        let read = try await result

        #expect(read.core.lifecycle.status == .cancelled)
        #expect(read.core.output.summary == "Stop")
    }

    @Test func reviewStartCancellationInterruptsBackendRun() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )

        async let result = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
        )
        await backend.waitForEventStream()
        await backend.finishEvents(throwing: CancellationError())
        let read = try await result

        #expect(read.core.lifecycle.status == .cancelled)
        let commands = await backend.recordedCommands()
        #expect(commands.contains(.interruptReview(
            .init(threadID: "thread-1", turnID: "turn-1", reviewThreadID: "review-thread-1"),
            .init(message: "Cancellation requested.")
        )))
    }

    @Test func failedInterruptClearsCancellationRequestState() async throws {
        let backend = FakeCodexReviewBackend()
        await backend.failInterrupts(message: "Interrupt failed")
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )

        async let result = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
        )
        await backend.waitForEventStream()
        await #expect(throws: FakeCodexReviewBackendError.self) {
            try await store.cancelReview(
                jobID: "job-1",
                cancellation: .mcpClient(message: "Stop")
            )
        }
        let readAfterFailure = try store.readReview(jobID: "job-1")

        #expect(readAfterFailure.cancellable)
        #expect(readAfterFailure.core.lifecycle.cancellation == nil)
        #expect(readAfterFailure.core.output.summary == "Failed to cancel review: Interrupt failed")

        await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
        _ = try await result
    }

    @Test func cancelledReviewIgnoresBufferedTerminalEvents() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )

        async let result = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
        )
        await backend.waitForEventStream()
        _ = try await store.cancelReview(
            jobID: "job-1",
            cancellation: .mcpClient(message: "Stop")
        )
        await backend.yield(.completed(summary: "Succeeded.", result: "late result"))
        let read = try await result

        #expect(read.core.lifecycle.status == .cancelled)
        #expect(read.core.output.summary == "Stop")
        #expect(read.core.output.lastAgentMessage == nil)
    }

    @Test func terminalEventDuringPendingCancellationKeepsCancelledState() async throws {
        let backend = FakeCodexReviewBackend()
        let interruptGate = AsyncGate()
        await backend.holdInterruptReview(with: interruptGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )

        async let result = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await backend.waitForEventStream()
        async let cancel = store.cancelReview(jobID: "job-1", cancellation: .mcpClient(message: "Stop"))
        await backend.waitForInterruptReview()
        await backend.yield(.completed(summary: "Reviewer failed to output a response.", result: nil))
        await interruptGate.open()
        _ = try await cancel
        let read = try await result

        #expect(read.core.lifecycle.status == .cancelled)
        #expect(read.core.output.summary == "Stop")
        #expect(read.core.output.hasFinalReview == false)
    }

    @Test func cancelDuringReviewStartupInterruptsAfterRunBecomesAvailable() async throws {
        let backend = FakeCodexReviewBackend()
        let gate = AsyncGate()
        await backend.holdStartReview(with: gate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )

        async let result = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await backend.waitForStartReview()
        let cancel = try await store.cancelReview(jobID: "job-1", cancellation: .mcpClient(message: "Stop"))
        let cancelledDuringStartup = try #require(store.jobs.first)
        #expect(cancel.core.lifecycle.status == .cancelled)
        #expect(cancelledDuringStartup.core.lifecycle.status == .cancelled)
        await gate.open()
        let read = try await result

        #expect(cancel.cancelled)
        #expect(read.core.lifecycle.status == .cancelled)
        let commands = await backend.recordedCommands()
        #expect(commands.contains(.interruptReview(
            .init(threadID: "thread-1", turnID: "turn-1", reviewThreadID: "review-thread-1"),
            .init(message: "Stop")
        )))
    }

    @Test func closedSessionRejectsNewReviews() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        await store.closeSession("session-1")

        await #expect(throws: (any Error).self) {
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
    }

    @Test func closeActiveReviewSessionsCancelsJobsWithoutClosingMCPServerSession() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        let running = CodexReviewJob.makeForTesting(
            id: "running-job",
            sessionID: "session-1",
            cwd: "/tmp/project",
            targetSummary: "Running",
            status: .running,
            summary: "Running"
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [.init(cwd: "/tmp/project")],
            jobs: [running]
        )

        await store.closeActiveReviewSessions(reason: .system(message: "Account switched."))

        #expect(running.core.lifecycle.status == .cancelled)
        async let result = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await backend.waitForEventStream()
        await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
        let read = try await result

        #expect(read.jobID == "job-1")
        #expect(read.core.lifecycle.status == .succeeded)
    }

    @Test func authAndSettingsUseSingleBackendContract() async throws {
        let backend = FakeCodexReviewBackend(settings: .init(model: "gpt-5"))
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        await store.refreshSettings()

        #expect(store.settings.effectiveModel == "gpt-5")
    }

    @Test func initialActiveAccountKeySelectsPersistedAccount() {
        let active = CodexAccount(email: "active@example.com")
        let inactive = CodexAccount(email: "inactive@example.com")
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

        #expect(store.auth.persistedAccounts.map(\.accountKey) == [
            inactive.accountKey,
            active.accountKey,
        ])
        #expect(store.auth.persistedActiveAccountKey == active.accountKey)
        #expect(store.auth.selectedAccount?.accountKey == active.accountKey)
    }

    @Test func fakeBackendPreservesSettingsCatalogWhenApplyingOverrides() async throws {
        let model = CodexReviewModelCatalogItem(
            id: "gpt-5.5",
            model: "gpt-5.5",
            displayName: "GPT-5.5",
            hidden: false,
            supportedReasoningEfforts: [
                .init(reasoningEffort: .medium, description: "Balanced"),
            ],
            defaultReasoningEffort: .medium,
            supportedServiceTiers: [.fast],
            isDefault: true
        )
        let backend = FakeCodexReviewBackend(settings: .init(
            fallbackModel: "gpt-5.5",
            models: [model]
        ))
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        await store.refreshSettings()
        await store.updateSettingsReasoningEffort(.medium)

        #expect(store.settings.effectiveModel == "gpt-5.5")
        #expect(store.settings.models == [model])
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
        store.loadForTesting(serverState: .failed("Runtime failed."), authPhase: .signedOut, workspaces: [])

        await store.performPrimaryAuthenticationAction()

        #expect(store.serverState == .running)
        #expect(store.auth.isAuthenticating)
        let commands = await backend.recordedCommands()
        #expect(commands.contains { command in
            if case .startLogin = command {
                return true
            }
            return false
        })
    }
}

private struct StreamClosedError: Error {}

private final class MutableTestClock: @unchecked Sendable {
    var current: Date

    init(_ current: Date) {
        self.current = current
    }

    func now() -> Date {
        current
    }
}
