import Foundation
import Testing
import CodexReview
import CodexReviewTesting

@Suite("store runtime lifecycle")
@MainActor
struct CodexReviewStoreLifecycleTests {
    @Test func invalidatedGenerationBeforeAcquisitionEntryPerformsNoMCPWork() async {
        let mcpOwner = TestingMCPServerLifecycleOwner()
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        let generation = ReviewRuntimeGeneration(rawValue: 1)
        let transitionTask = Task<Void, Never> { @MainActor in }
        store.runtimeState = .transitioning(
            generation: generation.successor(),
            purpose: .stop,
            task: transitionTask,
            record: ReviewRuntimeTransitionRecord(),
            sourceRuntime: nil,
            recoveryReplacement: nil
        )

        await store.performRuntimeAcquisitionForTesting(
            generation: generation,
            purpose: .stop
        )

        #expect(mcpOwner.prepareCallCount == 0)
        #expect(mcpOwner.activateCallCount == 0)
        #expect(backend.lastPreparedRuntimeHandle == nil)
        #expect(backend.startRequests.isEmpty)
    }

    @Test func stopInvalidatesHeldRuntimePreparationAndClosesStaleHandleOnce() async throws {
        let preparationGate = AsyncGate()
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend()
        )
        backend.holdRuntimePreparation(with: preparationGate)
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        let startTask = Task { @MainActor in
            await store.start()
        }
        await backend.waitForRuntimePreparation()
        let handle = try #require(backend.lastPreparedRuntimeHandle)

        let stopTask = Task { @MainActor in
            await store.stop()
        }
        await backend.waitForRuntimePreparationCancellation()

        #expect(handle.activateCallCount == 0)
        #expect(handle.closeAdmissionCallCount == 0)
        #expect(handle.closeCallCount == 0)
        #expect(store.serverState == .starting)

        await preparationGate.open()
        await stopTask.value
        await startTask.value

        #expect(store.serverState == .stopped)
        #expect(store.serverURL == nil)
        #expect(handle.activateCallCount == 0)
        #expect(handle.closeAdmissionCallCount == 1)
        #expect(handle.closeCallCount == 1)
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
        #expect(store.serverURL == nil)
        #expect(firstHandle.activateCallCount == 1)

        await store.stop()
        #expect(store.serverState == .stopped)
        #expect(firstHandle.closeCallCount == 1)

        await store.start()
        let secondHandle = try #require(backend.lastPreparedRuntimeHandle)
        #expect(secondHandle !== firstHandle)
        #expect(secondHandle.activateCallCount == 1)
        #expect(store.serverState == .running)
        #expect(store.serverURL == nil)
    }

    @Test func staleMCPPreparationDoesNotAcquireAnAppServerRuntime() async throws {
        let preparationGate = AsyncGate()
        let mcpOwner = TestingMCPServerLifecycleOwner()
        mcpOwner.holdPreparation(with: preparationGate)
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        let startTask = Task { @MainActor in
            await store.start()
        }
        await mcpOwner.waitForPreparation()
        let stopTask = Task { @MainActor in
            await store.stop()
        }
        await mcpOwner.waitForPreparationCancellation()

        #expect(backend.lastPreparedRuntimeHandle == nil)
        #expect(backend.startRequests.isEmpty)

        await preparationGate.open()
        await stopTask.value
        await startTask.value

        #expect(store.serverState == .stopped)
        #expect(backend.lastPreparedRuntimeHandle == nil)
        #expect(mcpOwner.stopCallCount == 1)
        #expect(mcpOwner.waitUntilStoppedCallCount == 1)
        #expect(mcpOwner.activateCallCount == 0)
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
        #expect(store.serverURL == endpoint)

        let replacementGate = AsyncGate()
        backend.holdRuntimePreparation(with: replacementGate)
        let restartTask = Task { @MainActor in
            await store.restart()
        }
        await backend.waitForRuntimePreparation()

        let ownsReplacementTask: Bool
        if case .transitioning(_, .restartSameAccount, _, _, _, _) = store.runtimeState {
            ownsReplacementTask = true
        } else {
            ownsReplacementTask = false
        }
        #expect(ownsReplacementTask)
        #expect(store.serverURL == endpoint)
        #expect(mcpOwner.prepareCallCount == 1)
        #expect(mcpOwner.activateCallCount == 1)
        #expect(mcpOwner.stopCallCount == 0)
        #expect(mcpOwner.waitUntilStoppedCallCount == 0)
        #expect(firstHandle.closePurposes == [.restartSameAccount])

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
        #expect(mcpOwner.stopCallCount == 0)

        guard case .running(_, _, let retainedMCPGeneration) = store.runtimeState else {
            Issue.record("Replacement must publish the new AppServer runtime.")
            return
        }
        #expect(retainedMCPGeneration == firstMCPGeneration)

        await store.stop()
    }

    @Test func graceForceCloseCancelsTargetAndResumesSiblingOnOneReplacement() async throws {
        let targetRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-target",
            threadID: "thread-target",
            turnID: "turn-target",
            reviewThreadID: "review-target"
        )
        let siblingRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-sibling",
            threadID: "thread-sibling",
            turnID: "turn-sibling",
            reviewThreadID: "review-sibling"
        )
        let recoveredSiblingRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-sibling-recovered",
            threadID: "thread-sibling",
            turnID: "turn-sibling-recovered",
            reviewThreadID: "review-sibling"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: targetRun)
        await reviewBackend.enqueueRun(siblingRun)
        await reviewBackend.enqueueRecoveredRun(recoveredSiblingRun)
        let mcpOwner = TestingMCPServerLifecycleOwner(
            serverURL: URL(string: "http://127.0.0.1:19431/mcp")
        )
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: reviewBackend,
            mcpServerLifecycle: mcpOwner
        )
        let jobIDs = SequentialJobIDs(["job-target", "job-sibling"])
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { jobIDs.next() }),
            reviewRuntimeClosePolicy: .init(
                terminalGrace: .seconds(10),
                sleep: { _ in }
            )
        )
        await store.start()
        let sourceRuntime = try #require(backend.lastPreparedRuntimeHandle)
        _ = try await store.startReview(
            sessionID: "session-target",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .milliseconds(20)
        )
        _ = try await store.startReview(
            sessionID: "session-sibling",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .milliseconds(20)
        )

        let cancellation = Task { @MainActor in
            try await store.cancelReview(
                jobID: "job-target",
                cancellation: .mcpClient(message: "Stop target")
            )
        }
        await reviewBackend.waitForResumeReviewRecovery()
        await reviewBackend.yield(
            .completed(summary: "Done", result: "sibling result"),
            for: recoveredSiblingRun
        )
        let targetCancellation = try await cancellation.value
        let sibling = try await store.awaitReview(
            sessionID: "session-sibling",
            jobID: "job-sibling"
        )

        #expect(targetCancellation.cancelled)
        #expect(try store.readReview(jobID: "job-target").core.lifecycle.terminal == .interrupted(
            .requested(.mcpClient(message: "Stop target"))
        ))
        #expect(sibling.core.lifecycle.status == .succeeded)
        #expect(sibling.core.run.turnID == "turn-sibling-recovered")
        #expect(sourceRuntime.closeCallCount == 1)
        #expect(sourceRuntime.waitUntilClosedCallCount == 1)
        #expect(sourceRuntime.closePurposes == [.recoveryReplacement])
        #expect(backend.startRequests == [false, false])
        #expect(mcpOwner.prepareCallCount == 1)
        #expect(mcpOwner.activateCallCount == 1)
        #expect(mcpOwner.stopCallCount == 0)
        let commands = await reviewBackend.recordedCommands()
        #expect(commands.filter { if case .forceCloseReviewConnection = $0 { true } else { false } }.count == 1)
        #expect(commands.filter { if case .prepareReviewRecovery = $0 { true } else { false } }.count == 1)
        #expect(commands.filter { if case .resumeReviewRecovery = $0 { true } else { false } }.count == 1)

        await store.stop()
    }

    @Test func manualRestartRecoversActiveReviewThroughTheSharedCoordinator() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-active",
            threadID: "thread-active",
            turnID: "turn-active",
            reviewThreadID: "review-active"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-active-recovered",
            threadID: "thread-active",
            turnID: "turn-active-recovered",
            reviewThreadID: "review-active"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: initialRun)
        await reviewBackend.enqueueRecoveredRun(recoveredRun)
        let endpoint = try #require(URL(string: "http://127.0.0.1:19435/mcp"))
        let mcpOwner = TestingMCPServerLifecycleOwner(serverURL: endpoint)
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: reviewBackend,
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { "job-active" })
        )
        await store.start()
        let sourceRuntime = try #require(backend.lastPreparedRuntimeHandle)
        let reviewTask = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-active",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await store.waitForRuntimeReplacementRegistrationForTesting(
            jobID: "job-active",
            attemptID: initialRun.attemptID
        )

        let restartTask = Task { @MainActor in
            await store.restart()
        }
        await reviewBackend.waitForResumeReviewRecovery()
        await reviewBackend.yield(
            .completed(summary: "Done", result: "manual restart recovered"),
            for: recoveredRun
        )
        await restartTask.value
        let review = try await reviewTask.value

        #expect(review.core.lifecycle.status == .succeeded)
        #expect(review.core.run.turnID == recoveredRun.turnID)
        #expect(sourceRuntime.closeCallCount == 1)
        #expect(sourceRuntime.closePurposes == [.restartSameAccount])
        #expect(backend.startRequests == [false, true])
        #expect(store.serverURL == endpoint)
        #expect(mcpOwner.prepareCallCount == 1)
        #expect(mcpOwner.activateCallCount == 1)
        #expect(mcpOwner.stopCallCount == 0)
        let commands = await reviewBackend.recordedCommands()
        #expect(commands.filter { if case .prepareReviewRecovery = $0 { true } else { false } }.count == 1)
        #expect(commands.filter { if case .resumeReviewRecovery = $0 { true } else { false } }.count == 1)

        await store.stop()
    }

    @Test func graceForceCloseWithNoSiblingStillPublishesOneReplacementRuntime() async throws {
        let targetRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-target",
            threadID: "thread-target",
            turnID: "turn-target",
            reviewThreadID: "review-target"
        )
        let nextRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-next",
            threadID: "thread-next",
            turnID: "turn-next",
            reviewThreadID: "review-next"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: targetRun)
        await reviewBackend.enqueueRun(nextRun)
        let endpoint = try #require(URL(string: "http://127.0.0.1:19432/mcp"))
        let mcpOwner = TestingMCPServerLifecycleOwner(serverURL: endpoint)
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: reviewBackend,
            mcpServerLifecycle: mcpOwner
        )
        let jobIDs = SequentialJobIDs(["job-target", "job-next"])
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { jobIDs.next() }),
            reviewRuntimeClosePolicy: .init(
                terminalGrace: .seconds(10),
                sleep: { _ in }
            )
        )
        await store.start()
        let sourceRuntime = try #require(backend.lastPreparedRuntimeHandle)
        let targetTask = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-target",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await store.waitForRuntimeReplacementRegistrationForTesting(
            jobID: "job-target",
            attemptID: targetRun.attemptID
        )

        let replacementGate = AsyncGate()
        backend.holdRuntimePreparation(with: replacementGate)
        let cancellation = Task { @MainActor in
            try await store.cancelReview(
                jobID: "job-target",
                cancellation: .mcpClient(message: "Stop target")
            )
        }
        await backend.waitForRuntimePreparation()
        let replacementRuntime = try #require(backend.lastPreparedRuntimeHandle)

        #expect(sourceRuntime.closeCallCount == 1)
        #expect(sourceRuntime.closePurposes == [.recoveryReplacement])
        #expect(replacementRuntime !== sourceRuntime)
        #expect(replacementRuntime.activateCallCount == 0)
        #expect(backend.startRequests == [false, false])
        #expect(store.serverURL == endpoint)
        #expect(mcpOwner.prepareCallCount == 1)
        #expect(mcpOwner.activateCallCount == 1)
        #expect(mcpOwner.stopCallCount == 0)

        await replacementGate.open()
        await store.start()
        let cancelled = try await cancellation.value
        _ = try await targetTask.value

        #expect(cancelled.cancelled)
        #expect(replacementRuntime.activateCallCount == 1)
        #expect(store.serverState == .running)
        #expect(store.serverURL == endpoint)
        #expect(store.activeRuntimeReplacementReceiptCountForTesting == 0)

        let nextTask = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-next",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await store.waitForRuntimeReplacementRegistrationForTesting(
            jobID: "job-next",
            attemptID: nextRun.attemptID
        )
        await reviewBackend.yield(
            .completed(summary: "Done", result: "replacement runtime usable"),
            for: nextRun
        )
        let next = try await nextTask.value
        #expect(next.core.lifecycle.status == .succeeded)
        #expect(next.core.run.turnID == nextRun.turnID)

        await store.stop()
    }

    @Test func siblingCanonicalCompletionBeforeEnrollmentSuppressesItsRecoverySuccessor() async throws {
        let targetRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-target",
            threadID: "thread-target",
            turnID: "turn-target",
            reviewThreadID: "review-target"
        )
        let siblingRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-sibling",
            threadID: "thread-sibling",
            turnID: "turn-sibling",
            reviewThreadID: "review-sibling"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: targetRun)
        await reviewBackend.enqueueRun(siblingRun)
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let jobIDs = SequentialJobIDs(["job-target", "job-sibling"])
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { jobIDs.next() }),
            reviewRuntimeClosePolicy: .init(
                terminalGrace: .seconds(10),
                sleep: { _ in }
            )
        )
        await store.start()
        let enrollmentEntered = AsyncGate()
        let enrollmentRelease = AsyncGate()
        store.setRuntimeReplacementEnrollmentPreparationForTesting {
            await enrollmentEntered.open()
            await enrollmentRelease.waitIgnoringCancellation()
        }
        let targetTask = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-target",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await store.waitForRuntimeReplacementRegistrationForTesting(
            jobID: "job-target",
            attemptID: targetRun.attemptID
        )
        let siblingTask = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-sibling",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await store.waitForRuntimeReplacementRegistrationForTesting(
            jobID: "job-sibling",
            attemptID: siblingRun.attemptID
        )

        let cancellation = Task { @MainActor in
            try await store.cancelReview(
                jobID: "job-target",
                cancellation: .mcpClient(message: "Stop target")
            )
        }
        await enrollmentEntered.wait()
        await reviewBackend.yield(
            .completed(summary: "Done", result: "natural sibling result"),
            for: siblingRun
        )
        let sibling = try await siblingTask.value

        await enrollmentRelease.open()
        store.setRuntimeReplacementEnrollmentPreparationForTesting(nil)
        let cancelled = try await cancellation.value
        _ = try await targetTask.value
        await store.start()

        #expect(cancelled.cancelled)
        #expect(sibling.core.lifecycle.status == .succeeded)
        #expect(sibling.core.run.turnID == siblingRun.turnID)
        #expect(backend.startRequests == [false, false])
        #expect(store.activeRuntimeReplacementReceiptCountForTesting == 0)
        let commands = await reviewBackend.recordedCommands()
        #expect(commands.filter { if case .prepareReviewRecovery = $0 { true } else { false } }.isEmpty)
        #expect(commands.filter { if case .resumeReviewRecovery = $0 { true } else { false } }.isEmpty)

        await store.stop()
    }

    @Test func replacementPreparationFailureFailsAllEligibleSiblingsAndRetainsMCP() async throws {
        let targetRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-target",
            threadID: "thread-target",
            turnID: "turn-target",
            reviewThreadID: "review-target"
        )
        let firstSiblingRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-sibling-1",
            threadID: "thread-sibling-1",
            turnID: "turn-sibling-1",
            reviewThreadID: "review-sibling-1"
        )
        let secondSiblingRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-sibling-2",
            threadID: "thread-sibling-2",
            turnID: "turn-sibling-2",
            reviewThreadID: "review-sibling-2"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: targetRun)
        await reviewBackend.enqueueRun(firstSiblingRun)
        await reviewBackend.enqueueRun(secondSiblingRun)
        let endpoint = try #require(URL(string: "http://127.0.0.1:19433/mcp"))
        let mcpOwner = TestingMCPServerLifecycleOwner(serverURL: endpoint)
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: reviewBackend,
            mcpServerLifecycle: mcpOwner
        )
        let jobIDs = SequentialJobIDs(["job-target", "job-sibling-1", "job-sibling-2"])
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { jobIDs.next() }),
            reviewRuntimeClosePolicy: .init(
                terminalGrace: .seconds(10),
                sleep: { _ in }
            )
        )
        await store.start()
        let targetTask = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-target",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await store.waitForRuntimeReplacementRegistrationForTesting(
            jobID: "job-target",
            attemptID: targetRun.attemptID
        )
        let firstSiblingTask = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-sibling-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await store.waitForRuntimeReplacementRegistrationForTesting(
            jobID: "job-sibling-1",
            attemptID: firstSiblingRun.attemptID
        )
        let secondSiblingTask = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-sibling-2",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await store.waitForRuntimeReplacementRegistrationForTesting(
            jobID: "job-sibling-2",
            attemptID: secondSiblingRun.attemptID
        )
        await reviewBackend.failAuthRead(message: "Replacement authentication unavailable.")

        let cancellation = Task { @MainActor in
            try await store.cancelReview(
                jobID: "job-target",
                cancellation: .mcpClient(message: "Stop target")
            )
        }
        let cancelled = try await cancellation.value
        let target = try await targetTask.value
        let firstSibling = try await firstSiblingTask.value
        let secondSibling = try await secondSiblingTask.value

        #expect(cancelled.cancelled)
        #expect(target.core.lifecycle.terminal == .interrupted(
            .requested(.mcpClient(message: "Stop target"))
        ))
        guard case .failed(let firstMessage) = firstSibling.core.lifecycle.terminal,
              case .failed(let secondMessage) = secondSibling.core.lifecycle.terminal
        else {
            Issue.record("Replacement failure must terminalize every eligible sibling.")
            await store.stop()
            return
        }
        #expect(firstMessage == secondMessage)
        #expect(firstMessage?.contains("Replacement authentication unavailable.") == true)
        guard case .failed = store.serverState else {
            Issue.record("Replacement preparation failure must fail the Store runtime.")
            await store.stop()
            return
        }
        #expect(store.serverURL == endpoint)
        #expect(backend.startRequests == [false, false])
        #expect(mcpOwner.prepareCallCount == 1)
        #expect(mcpOwner.activateCallCount == 1)
        #expect(mcpOwner.stopCallCount == 0)
        await #expect(throws: CodexReviewAPI.Error.self) {
            _ = try await store.startReview(
                sessionID: "session-after-failure",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }

        await store.stop()
    }

    @Test func siblingCancellationDuringHeldHandoffSuppressesResume() async throws {
        let targetRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-target",
            threadID: "thread-target",
            turnID: "turn-target",
            reviewThreadID: "review-target"
        )
        let siblingRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-sibling",
            threadID: "thread-sibling",
            turnID: "turn-sibling",
            reviewThreadID: "review-sibling"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: targetRun)
        await reviewBackend.enqueueRun(siblingRun)
        let handoffGate = AsyncGate()
        await reviewBackend.holdPrepareReviewRecovery(with: handoffGate)
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let jobIDs = SequentialJobIDs(["job-target", "job-sibling"])
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { jobIDs.next() }),
            reviewRuntimeClosePolicy: .init(
                terminalGrace: .seconds(10),
                sleep: { _ in }
            )
        )
        await store.start()
        let targetTask = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-target",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await store.waitForRuntimeReplacementRegistrationForTesting(
            jobID: "job-target",
            attemptID: targetRun.attemptID
        )
        let siblingTask = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-sibling",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await store.waitForRuntimeReplacementRegistrationForTesting(
            jobID: "job-sibling",
            attemptID: siblingRun.attemptID
        )

        let targetCancellation = Task { @MainActor in
            try await store.cancelReview(
                jobID: "job-target",
                cancellation: .mcpClient(message: "Stop target")
            )
        }
        await reviewBackend.waitForPrepareReviewRecovery()
        let siblingCancellation = Task { @MainActor in
            try await store.cancelReview(
                jobID: "job-sibling",
                cancellation: .system(message: "Stop sibling during handoff")
            )
        }
        let siblingCancelled = try await siblingCancellation.value
        await handoffGate.open()
        let targetCancelled = try await targetCancellation.value
        let target = try await targetTask.value
        let sibling = try await siblingTask.value
        await store.start()

        #expect(targetCancelled.cancelled)
        #expect(siblingCancelled.cancelled)
        #expect(target.core.lifecycle.terminal == .interrupted(
            .requested(.mcpClient(message: "Stop target"))
        ))
        #expect(sibling.core.lifecycle.terminal == .interrupted(
            .requested(.system(message: "Stop sibling during handoff"))
        ))
        let commands = await reviewBackend.recordedCommands()
        #expect(commands.filter { if case .prepareReviewRecovery = $0 { true } else { false } }.count == 1)
        #expect(commands.filter { if case .resumeReviewRecovery = $0 { true } else { false } }.isEmpty)
        #expect(backend.startRequests == [false, false])

        await store.stop()
    }

    @Test func applicationCloseSupersedesHeldRecoveryReplacementWithoutLatePublication() async throws {
        let targetRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-target",
            threadID: "thread-target",
            turnID: "turn-target",
            reviewThreadID: "review-target"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: targetRun)
        let mcpOwner = TestingMCPServerLifecycleOwner()
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: reviewBackend,
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { "job-target" }),
            reviewRuntimeClosePolicy: .init(
                terminalGrace: .seconds(10),
                sleep: { _ in }
            )
        )
        await store.start()
        let sourceRuntime = try #require(backend.lastPreparedRuntimeHandle)
        let targetTask = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-target",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await store.waitForRuntimeReplacementRegistrationForTesting(
            jobID: "job-target",
            attemptID: targetRun.attemptID
        )

        let replacementGate = AsyncGate()
        backend.holdRuntimePreparation(with: replacementGate)
        let cancellation = Task { @MainActor in
            try await store.cancelReview(
                jobID: "job-target",
                cancellation: .mcpClient(message: "Stop target")
            )
        }
        await backend.waitForRuntimePreparation()
        let staleReplacement = try #require(backend.lastPreparedRuntimeHandle)
        let closeTask = Task { @MainActor in
            try await store.close()
        }
        await backend.waitForRuntimePreparationCancellation()

        #expect(sourceRuntime.closeCallCount == 1)
        #expect(sourceRuntime.closePurposes == [.recoveryReplacement])
        #expect(staleReplacement.activateCallCount == 0)
        #expect(mcpOwner.closeAdmissionCallCount == 1)

        await replacementGate.open()
        try await closeTask.value
        _ = try await cancellation.value
        _ = try await targetTask.value

        #expect(staleReplacement.activateCallCount == 0)
        #expect(staleReplacement.closeCallCount == 1)
        #expect(staleReplacement.waitUntilClosedCallCount == 1)
        #expect(sourceRuntime.closeCallCount == 1)
        #expect(sourceRuntime.waitUntilClosedCallCount == 1)
        #expect(mcpOwner.closeCallCount == 1)
        #expect(mcpOwner.waitUntilClosedCallCount == 1)
        #expect(store.serverState == .stopped)
        #expect(store.serverURL == nil)
    }

    @Test func stopSupersedingHeldReplacementCancelsAndJoinsEligibleSibling() async throws {
        let targetRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-target",
            threadID: "thread-target",
            turnID: "turn-target",
            reviewThreadID: "review-target"
        )
        let siblingRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-sibling",
            threadID: "thread-sibling",
            turnID: "turn-sibling",
            reviewThreadID: "review-sibling"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: targetRun)
        await reviewBackend.enqueueRun(siblingRun)
        let mcpOwner = TestingMCPServerLifecycleOwner()
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: reviewBackend,
            mcpServerLifecycle: mcpOwner
        )
        let jobIDs = SequentialJobIDs(["job-target", "job-sibling"])
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { jobIDs.next() }),
            reviewRuntimeClosePolicy: .init(
                terminalGrace: .seconds(10),
                sleep: { _ in }
            )
        )
        await store.start()
        let targetTask = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-target",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await store.waitForRuntimeReplacementRegistrationForTesting(
            jobID: "job-target",
            attemptID: targetRun.attemptID
        )
        let siblingTask = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-sibling",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await store.waitForRuntimeReplacementRegistrationForTesting(
            jobID: "job-sibling",
            attemptID: siblingRun.attemptID
        )

        let replacementGate = AsyncGate()
        backend.holdRuntimePreparation(with: replacementGate)
        let targetCancellation = Task { @MainActor in
            try await store.cancelReview(
                jobID: "job-target",
                cancellation: .mcpClient(message: "Stop target")
            )
        }
        await backend.waitForRuntimePreparation()
        let stopTask = Task { @MainActor in
            await store.stop()
        }
        await backend.waitForRuntimePreparationCancellation()
        await replacementGate.open()
        await stopTask.value
        let target = try await targetTask.value
        let sibling = try await siblingTask.value
        _ = try await targetCancellation.value

        #expect(target.core.lifecycle.terminal == .interrupted(
            .requested(.mcpClient(message: "Stop target"))
        ))
        #expect(sibling.core.lifecycle.terminal == .interrupted(
            .requested(.system(message: "Review runtime stopped."))
        ))
        #expect(store.reviewWorkerTasks.isEmpty)
        #expect(store.activeRuntimeReplacementReceiptCountForTesting == 0)
        #expect(store.serverState == .stopped)
        #expect(mcpOwner.stopCallCount == 1)
        #expect(mcpOwner.waitUntilStoppedCallCount == 1)
    }

    @Test func recoverableNetworkForceCloseWaitsForRestorationAndResumesOnReplacement() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-network",
            threadID: "thread-network",
            turnID: "turn-network",
            reviewThreadID: "review-network"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-network-recovered",
            threadID: "thread-network",
            turnID: "turn-network-recovered",
            reviewThreadID: "review-network"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: initialRun)
        await reviewBackend.enqueueRecoveredRun(recoveredRun)
        let endpoint = try #require(URL(string: "http://127.0.0.1:19434/mcp"))
        let mcpOwner = TestingMCPServerLifecycleOwner(serverURL: endpoint)
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: reviewBackend,
            mcpServerLifecycle: mcpOwner
        )
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { "job-network" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in }),
            reviewRuntimeClosePolicy: .init(
                terminalGrace: .seconds(10),
                sleep: { _ in }
            )
        )
        await store.start()
        let sourceRuntime = try #require(backend.lastPreparedRuntimeHandle)
        let reviewTask = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-network",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await store.waitForRuntimeReplacementRegistrationForTesting(
            jobID: "job-network",
            attemptID: initialRun.attemptID
        )

        let replacementGate = AsyncGate()
        backend.holdRuntimePreparation(with: replacementGate)
        networkMonitor.yield(.init(status: .unsatisfied))
        await reviewBackend.waitForInterruptReview(
            run: initialRun,
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )
        await sourceRuntime.waitForClose()
        await reviewBackend.waitForPrepareReviewRecovery()

        #expect(sourceRuntime.closeCallCount == 1)
        #expect(sourceRuntime.closePurposes == [.recoveryReplacement])
        #expect(backend.startRequests == [false])
        #expect(store.serverURL == endpoint)
        #expect(mcpOwner.prepareCallCount == 1)
        #expect(mcpOwner.activateCallCount == 1)
        #expect(mcpOwner.stopCallCount == 0)

        networkMonitor.yield(.satisfied())
        await backend.waitForRuntimePreparation()
        let replacementRuntime = try #require(backend.lastPreparedRuntimeHandle)
        #expect(replacementRuntime !== sourceRuntime)
        #expect(replacementRuntime.activateCallCount == 0)
        #expect(backend.startRequests == [false, false])

        await replacementGate.open()
        await reviewBackend.waitForResumeReviewRecovery()
        await reviewBackend.yield(
            .completed(summary: "Done", result: "network recovered"),
            for: recoveredRun
        )
        let review = try await reviewTask.value

        #expect(review.core.lifecycle.status == .succeeded)
        #expect(review.core.run.turnID == recoveredRun.turnID)
        #expect(replacementRuntime.activateCallCount == 1)
        #expect(store.serverState == .running)
        #expect(store.serverURL == endpoint)
        #expect(mcpOwner.prepareCallCount == 1)
        #expect(mcpOwner.activateCallCount == 1)
        #expect(mcpOwner.stopCallCount == 0)

        await store.stop()
    }

    @Test func networkForceCloseFailureHasOneApplicationCloseReceipt() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-network",
            threadID: "thread-network",
            turnID: "turn-network",
            reviewThreadID: "review-network"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: initialRun)
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { "job-network" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in }),
            reviewRuntimeClosePolicy: .init(
                terminalGrace: .seconds(10),
                sleep: { _ in }
            )
        )
        let forceReceiptRecorded = AsyncGate()
        store.setRuntimeForceCloseReceiptRecordedForTesting {
            await forceReceiptRecorded.open()
        }
        await store.start()
        let sourceRuntime = try #require(backend.lastPreparedRuntimeHandle)
        sourceRuntime.failClose(with: .init(first: .client("network source close failed")))
        let reviewTask = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-network",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await store.waitForRuntimeReplacementRegistrationForTesting(
            jobID: "job-network",
            attemptID: initialRun.attemptID
        )

        networkMonitor.yield(.init(status: .unsatisfied))
        await forceReceiptRecorded.wait()
        let review = try await reviewTask.value
        let closeError = try #require(await capturedCloseError(from: store))

        #expect(review.core.lifecycle.status == .failed)
        #expect(sourceRuntime.closeCallCount == 1)
        #expect(sourceRuntime.waitUntilClosedCallCount == 1)
        #expect(closeError.failures.additionalInLifecycleOrder.isEmpty)
        guard case .lifecycleResources(let lifecycle) = closeError.failures.first else {
            Issue.record("Network force close failure must retain lifecycle ownership.")
            return
        }
        #expect(lifecycle.first == .client("network source close failed"))
    }

    @Test func sameGenerationNetworkResumeIsDiscardedWhenStopWins() async throws {
        try await exerciseSameGenerationNetworkResumeDiscard(applicationClose: false)
    }

    @Test func sameGenerationNetworkResumeIsDiscardedWhenCloseWins() async throws {
        try await exerciseSameGenerationNetworkResumeDiscard(applicationClose: true)
    }

    @Test func staleNetworkResumeTerminalizesBeforeCloseCancellationAdmission() async throws {
        try await exerciseSameGenerationNetworkResumeDiscard(
            applicationClose: true,
            terminalBeforeCancellationAdmission: true
        )
    }

    private func exerciseSameGenerationNetworkResumeDiscard(
        applicationClose: Bool,
        terminalBeforeCancellationAdmission: Bool = false
    ) async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-network",
            threadID: "thread-network",
            turnID: "turn-network",
            reviewThreadID: "review-network"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-network-recovered",
            threadID: "thread-network",
            turnID: "turn-network-recovered",
            reviewThreadID: "review-network"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: initialRun)
        await reviewBackend.enqueueRecoveredRun(recoveredRun)
        let resumeGate = AsyncGate()
        await reviewBackend.holdResumeReviewRecoveryIgnoringCancellation(
            with: resumeGate
        )
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { "job-network" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)
        let reviewTask = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-network",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await store.waitForRuntimeReplacementRegistrationForTesting(
            jobID: "job-network",
            attemptID: initialRun.attemptID
        )

        let reason = CodexReviewBackendModel.CancellationReason(
            message: "Network unavailable; waiting to reconnect."
        )
        networkMonitor.yield(.init(status: .unsatisfied))
        await reviewBackend.waitForInterruptReview(run: initialRun, reason: reason)
        await reviewBackend.yield(.cancelled(reason.message), for: initialRun)
        await reviewBackend.waitForPrepareReviewRecovery()
        networkMonitor.yield(.satisfied())
        await reviewBackend.waitForResumeReviewRecovery()

        let cancellationBarrierEntered = AsyncGate()
        let cancellationBarrierRelease = AsyncGate()
        store.setReviewCancellationBarrierPreparationForTesting {
            await cancellationBarrierEntered.open()
            if terminalBeforeCancellationAdmission {
                await cancellationBarrierRelease.waitIgnoringCancellation()
            }
        }
        let shutdownTask = Task { @MainActor in
            do {
                if applicationClose {
                    try await store.close()
                } else {
                    await store.stop()
                }
                return Result<Void, any Error>.success(())
            } catch {
                return Result<Void, any Error>.failure(error)
            }
        }
        await cancellationBarrierEntered.wait()
        await resumeGate.open()
        if terminalBeforeCancellationAdmission {
            await reviewBackend.waitForCleanupReview()
            await cancellationBarrierRelease.open()
        }
        try await shutdownTask.value.get()
        let review = try await reviewTask.value

        if terminalBeforeCancellationAdmission {
            #expect(review.core.lifecycle.status == .failed)
            #expect(review.core.lifecycle.terminal?.kind == .interrupted)
            #expect(review.core.lifecycle.cancellation == nil)
        } else {
            let expectedCancellation: ReviewCancellation = applicationClose
                ? .system(message: "Review Store closed.")
                : .system(message: "Review runtime stopped.")
            #expect(review.core.lifecycle.terminal == .interrupted(
                .requested(expectedCancellation)
            ))
        }
        #expect(review.core.run.turnID == initialRun.turnID)
        #expect(store.reviewWorkerTasks.isEmpty)
        #expect(store.activeRuntimeReplacementReceiptCountForTesting == 0)
        #expect(runtime.closeCallCount == 1)
        let commands = await reviewBackend.recordedCommands()
        #expect(commands.contains(.cleanupReview(recoveredRun)))
        #expect(commands.contains(.cleanupReview(initialRun)))
        #expect(store.serverState == .stopped)
        #expect(store.serverURL == nil)
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
        let restartTask = Task { @MainActor in
            await store.restart()
        }
        await backend.waitForRuntimePreparation()
        let staleReplacement = try #require(backend.lastPreparedRuntimeHandle)
        let stopTask = Task { @MainActor in
            await store.stop()
        }
        await backend.waitForRuntimePreparationCancellation()

        #expect(firstHandle.closePurposes == [.restartSameAccount])
        #expect(staleReplacement !== firstHandle)
        #expect(staleReplacement.activateCallCount == 0)
        #expect(store.serverURL == endpoint)

        await replacementGate.open()
        await stopTask.value
        await restartTask.value

        #expect(store.serverState == .stopped)
        #expect(store.serverURL == nil)
        #expect(staleReplacement.activateCallCount == 0)
        #expect(staleReplacement.closeAdmissionCallCount == 1)
        #expect(staleReplacement.closeCallCount == 1)
        #expect(staleReplacement.waitUntilClosedCallCount == 1)
        #expect(mcpOwner.prepareCallCount == 1)
        #expect(mcpOwner.activateCallCount == 1)
        #expect(mcpOwner.stopCallCount == 1)
        #expect(mcpOwner.waitUntilStoppedCallCount == 1)
    }

    @Test func concurrentAndRepeatedCloseJoinOneRecordedResultAndRejectLaterMutation() async throws {
        let mcpOwner = TestingMCPServerLifecycleOwner()
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)
        let runtimeCloseGate = AsyncGate()
        runtime.holdClose(with: runtimeCloseGate)

        let firstClose = Task { @MainActor in
            try await store.close()
        }
        await runtime.waitForClose()
        let secondClose = Task { @MainActor in
            try await store.close()
        }
        await store.waitForCloseCallersForTesting(2)

        #expect(runtime.closeCallCount == 1)
        #expect(runtime.waitUntilClosedCallCount == 0)
        #expect(mcpOwner.closeAdmissionCallCount == 1)
        #expect(mcpOwner.drainAdmittedHandlersCallCount == 1)
        #expect(mcpOwner.closeCallCount == 1)
        #expect(mcpOwner.waitUntilClosedCallCount == 1)

        await runtimeCloseGate.open()
        try await firstClose.value
        try await secondClose.value
        try await store.close()

        #expect(runtime.closeCallCount == 1)
        #expect(runtime.waitUntilClosedCallCount == 1)
        #expect(runtime.closePurposes == [.applicationClose])
        guard case .closed(.success) = store.lifetimeState else {
            Issue.record("Store close must record one successful result.")
            return
        }

        let startRequests = backend.startRequests
        await store.start()
        await store.restart()
        await store.stop()
        #expect(backend.startRequests == startRequests)
        await #expect(throws: CodexReviewAPI.Error.self) {
            _ = try await store.startReview(
                sessionID: "session-after-close",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
    }

    @Test func closeWaitsForAdmittedMCPHandlerBeforeRuntimePhysicalClose() async throws {
        let mcpOwner = TestingMCPServerLifecycleOwner()
        let handlerGate = AsyncGate()
        mcpOwner.holdHandlerDrain(with: handlerGate)
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)

        let closeTask = Task { @MainActor in
            try await store.close()
        }
        await mcpOwner.waitForHandlerDrain()

        #expect(mcpOwner.closeAdmissionCallCount == 1)
        #expect(mcpOwner.closeCallCount == 0)
        #expect(runtime.closeCallCount == 0)

        await handlerGate.open()
        try await closeTask.value

        #expect(mcpOwner.closeCallCount == 1)
        #expect(mcpOwner.waitUntilClosedCallCount == 1)
        #expect(runtime.closeCallCount == 1)
    }

    @Test func closeInvalidatesHeldRuntimePreparationAndNeverPublishesIt() async throws {
        let preparationGate = AsyncGate()
        let mcpOwner = TestingMCPServerLifecycleOwner()
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        backend.holdRuntimePreparation(with: preparationGate)
        let store = CodexReviewStore.makeTestingStore(backend: backend)

        let startTask = Task { @MainActor in
            await store.start()
        }
        await backend.waitForRuntimePreparation()
        let staleRuntime = try #require(backend.lastPreparedRuntimeHandle)
        let closeTask = Task { @MainActor in
            try await store.close()
        }
        await backend.waitForRuntimePreparationCancellation()

        #expect(staleRuntime.activateCallCount == 0)
        #expect(store.serverState == .starting)

        await preparationGate.open()
        try await closeTask.value
        await startTask.value

        #expect(staleRuntime.activateCallCount == 0)
        #expect(staleRuntime.closeAdmissionCallCount == 1)
        #expect(staleRuntime.closeCallCount == 1)
        #expect(staleRuntime.waitUntilClosedCallCount == 1)
        #expect(store.serverState == .stopped)
        #expect(store.serverURL == nil)
    }

    @Test func closeAggregatesLifecycleFailuresOnceAndReplaysThem() async throws {
        let mcpOwner = TestingMCPServerLifecycleOwner()
        mcpOwner.failHandlerDrain(with: .mcpHandlerDrain("handler drain failed"))
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend(),
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)
        runtime.failClose(with: .init(first: .client("runtime close failed")))

        let firstError = await capturedCloseError(from: store)
        let secondError = await capturedCloseError(from: store)

        #expect(firstError?.localizedDescription == secondError?.localizedDescription)
        #expect(runtime.closeCallCount == 1)
        #expect(runtime.waitUntilClosedCallCount == 1)
        #expect(mcpOwner.drainAdmittedHandlersCallCount == 1)
        let failures = try #require(firstError).failures
        guard case .lifecycleResources(let firstLifecycle) = failures.first else {
            Issue.record("MCP handler drain must be the first close lifecycle failure.")
            return
        }
        #expect(firstLifecycle.first == .mcpHandlerDrain("handler drain failed"))
        guard case .lifecycleResources(let secondLifecycle) = failures.additionalInLifecycleOrder.first else {
            Issue.record("Runtime close must follow MCP lifecycle failures.")
            return
        }
        #expect(secondLifecycle.first == .client("runtime close failed"))
        #expect(failures.additionalInLifecycleOrder.count == 1)
    }

    @Test func cancellationFailureUsesRuntimeTerminalBeforeJoiningWorker() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: run)
        await reviewBackend.failInterrupts(message: "interrupt rejected")
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        backend.setRuntimeCloseOperation {
            try? await reviewBackend.forceCloseReviewConnection()
        }
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)
        let runtimeCloseGate = AsyncGate()
        runtime.holdClose(with: runtimeCloseGate)
        let initial = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .milliseconds(20)
        )
        #expect(initial.core.lifecycle.status == .running)

        let closeTask = Task { @MainActor in
            await capturedCloseError(from: store)
        }
        await runtime.waitForClose()

        let beforeRuntimeClose = try store.readReview(jobID: "job-1")
        #expect(beforeRuntimeClose.core.lifecycle.status == .running)
        #expect(store.reviewWorkerTasks["job-1"] != nil)

        await runtimeCloseGate.open()
        let closeError = try #require(await closeTask.value)

        let terminal = try store.readReview(jobID: "job-1")
        #expect(terminal.core.lifecycle.status == .failed)
        #expect(terminal.core.lifecycle.cancellation == nil)
        #expect(store.reviewWorkerTasks["job-1"] == nil)
        guard case .interruptRequest(let failure) = closeError.failures.first else {
            Issue.record("Interrupt failure must remain first in the close aggregate.")
            return
        }
        #expect(failure.outcome == .rejected(code: nil, message: "interrupt rejected"))
    }

    @Test func successfulCancellationCleanupFinishesBeforeAppServerAdmissionCloses() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: run)
        let cleanupGate = AsyncGate()
        await reviewBackend.holdCleanupReview(with: cleanupGate)
        let mcpOwner = TestingMCPServerLifecycleOwner()
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: reviewBackend,
            mcpServerLifecycle: mcpOwner
        )
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)
        _ = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .milliseconds(20)
        )

        let closeTask = Task { @MainActor in
            try await store.close()
        }
        await reviewBackend.waitForInterruptReview()
        await reviewBackend.yield(
            .cancelled("Review Store closed."),
            for: run
        )
        await reviewBackend.waitForCleanupReview()

        #expect(runtime.closeAdmissionCallCount == 0)
        #expect(runtime.closeCallCount == 0)
        #expect(mcpOwner.drainAdmittedHandlersCallCount == 0)

        await cleanupGate.open()
        try await closeTask.value

        #expect(runtime.closeAdmissionCallCount == 1)
        #expect(runtime.closeCallCount == 1)
        #expect(store.reviewWorkerTasks["job-1"] == nil)
    }

    @Test func closeAwaitsPrePublicationReviewMutationAndPreventsBackendWrite() async throws {
        let reviewBackend = FakeCodexReviewBackend()
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let mutationEntered = AsyncGate()
        let mutationRelease = AsyncGate()
        store.setReviewMutationPreparationForTesting {
            await mutationEntered.open()
            await mutationRelease.waitIgnoringCancellation()
        }
        let startTask = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await mutationEntered.wait()
        let closeCompletion = StoreCloseCompletion()
        let closeTask = Task { @MainActor in
            try await store.close()
            await closeCompletion.complete()
        }
        await store.waitForCloseCallersForTesting(1)

        let commandsBeforeRelease = await reviewBackend.recordedCommands()
        #expect(await closeCompletion.isComplete() == false)
        #expect(store.reviewMutationTasks.count == 1)
        #expect(commandsBeforeRelease.contains { command in
            if case .startReview = command { true } else { false }
        } == false)

        await mutationRelease.open()
        await #expect(throws: CodexReviewAPI.Error.self) {
            _ = try await startTask.value
        }
        try await closeTask.value

        #expect(await closeCompletion.isComplete())
        #expect(store.reviewMutationTasks.isEmpty)
        #expect(store.jobs.isEmpty)
    }

    @Test func closeAwaitsAdmittedAuthenticationMutationAndRejectsLaterMutation() async throws {
        let authRefreshGate = AsyncGate()
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend()
        )
        backend.holdAuthRefresh(with: authRefreshGate)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)

        let refreshTask = Task { @MainActor in
            await store.refreshAuthentication()
        }
        await backend.waitForAuthRefresh()
        let closeCompletion = StoreCloseCompletion()
        let closeTask = Task { @MainActor in
            try await store.close()
            await closeCompletion.complete()
        }
        await store.waitForCloseCallersForTesting(1)

        #expect(await closeCompletion.isComplete() == false)
        #expect(runtime.closeCallCount == 0)
        #expect(backend.authRefreshCallCount == 1)

        await authRefreshGate.open()
        await refreshTask.value
        try await closeTask.value

        #expect(await closeCompletion.isComplete())
        #expect(runtime.closeCallCount == 1)
        await store.refreshAuthentication()
        #expect(backend.authRefreshCallCount == 1)
    }

    @Test func closeReplaysFailureFromACompletedRuntimeTransition() async throws {
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend()
        )
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)
        runtime.failClose(with: .init(first: .client("stop close failed")))

        await store.stop()
        let firstError = try #require(await capturedCloseError(from: store))
        let secondError = try #require(await capturedCloseError(from: store))

        #expect(firstError.localizedDescription == secondError.localizedDescription)
        guard case .lifecycleResources(let lifecycle) = firstError.failures.first else {
            Issue.record("The completed transition failure must remain owned by Store close.")
            return
        }
        #expect(lifecycle.first == .client("stop close failed"))
        #expect(runtime.closeCallCount == 1)
        #expect(runtime.waitUntilClosedCallCount == 1)
    }

    @Test func closePreservesInterruptFailureFromCompletedStopTransition() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: run)
        await reviewBackend.failInterrupts(message: "stop interrupt rejected")
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )
        await store.start()
        _ = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .milliseconds(20)
        )

        await store.stop()
        let closeError = try #require(await capturedCloseError(from: store))

        guard case .interruptRequest(let failure) = closeError.failures.first else {
            Issue.record("The completed stop transition must retain its interrupt failure.")
            return
        }
        #expect(failure.outcome == .rejected(code: nil, message: "stop interrupt rejected"))
    }

    @Test func applicationGraceCloseConsumesRuntimeFailureExactlyOnce() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: run)
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { "job-1" }),
            reviewRuntimeClosePolicy: .init(
                terminalGrace: .seconds(10),
                sleep: { _ in }
            )
        )
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)
        runtime.failClose(with: .init(first: .client("forced runtime close failed")))
        _ = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .milliseconds(20)
        )

        let closeError = try #require(await capturedCloseError(from: store))

        #expect(closeError.failures.additionalInLifecycleOrder.isEmpty)
        guard case .lifecycleResources(let lifecycle) = closeError.failures.first else {
            Issue.record("Forced runtime close must retain its lifecycle failure.")
            return
        }
        #expect(lifecycle.first == .client("forced runtime close failed"))
        #expect(runtime.closeCallCount == 1)
        #expect(runtime.waitUntilClosedCallCount == 1)
    }

    @Test func closeImportsPriorGraceFailureReceiptBeforeRecancellingActiveJob() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: run)
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { "job-1" }),
            reviewRuntimeClosePolicy: .init(
                terminalGrace: .seconds(10),
                sleep: { _ in }
            )
        )
        let terminalPublicationEntered = AsyncGate()
        let terminalPublicationRelease = AsyncGate()
        let forceCloseReceiptRecorded = AsyncGate()
        store.setReviewTerminalPublicationPreparationForTesting {
            await terminalPublicationEntered.open()
            await terminalPublicationRelease.waitIgnoringCancellation()
        }
        store.setRuntimeForceCloseReceiptRecordedForTesting {
            await forceCloseReceiptRecorded.open()
        }
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)
        runtime.failClose(with: .init(first: .client("prior forced close failed")))
        let sourceCloseGate = AsyncGate()
        runtime.holdClose(with: sourceCloseGate)
        _ = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .milliseconds(20)
        )

        let cancellationTask = Task { @MainActor in
            try await store.cancelReview(
                jobID: "job-1",
                cancellation: .mcpClient(message: "Stop")
            )
        }
        await runtime.waitForClose()
        #expect(try store.readReview(jobID: "job-1").core.lifecycle.status == .running)

        let closeTask = Task { @MainActor in
            await capturedCloseError(from: store)
        }
        await store.waitForCloseCallersForTesting(1)
        await sourceCloseGate.open()
        await forceCloseReceiptRecorded.wait()
        await terminalPublicationEntered.wait()
        await terminalPublicationRelease.open()
        _ = await cancellationTask.result
        let closeError = try #require(await closeTask.value)

        #expect(closeError.failures.additionalInLifecycleOrder.isEmpty)
        guard case .lifecycleResources(let lifecycle) = closeError.failures.first else {
            Issue.record("The prior force-close receipt must retain lifecycle ownership.")
            return
        }
        #expect(lifecycle.first == .client("prior forced close failed"))
        #expect(runtime.closeCallCount == 1)
        #expect(runtime.waitUntilClosedCallCount == 1)
    }

    @Test func closeDoesNotRepeatCleanupFailureConsumedByCompletedStop() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: run)
        await reviewBackend.failCleanup(message: "stop cleanup failed")
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )
        await store.start()
        _ = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .milliseconds(20)
        )
        let stopTask = Task { @MainActor in
            await store.stop()
        }
        await reviewBackend.waitForInterruptReview()
        await reviewBackend.yield(.cancelled("Review runtime stopped."), for: run)
        await stopTask.value

        let closeError = try #require(await capturedCloseError(from: store))

        #expect(closeError.failures.additionalInLifecycleOrder.isEmpty)
        guard case .attemptRuntime(let failure) = closeError.failures.first else {
            Issue.record("Stop cleanup failure must remain an attempt-runtime failure.")
            return
        }
        #expect(failure == .cleanup("stop cleanup failed"))
    }

    @Test func naturallyTerminalWorkerFinishesCleanupBeforeRuntimePhysicalClose() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: run)
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )
        let cleanupEntered = AsyncGate()
        let cleanupRelease = AsyncGate()
        store.setReviewCleanupPreparationForTesting {
            await cleanupEntered.open()
            await cleanupRelease.waitIgnoringCancellation()
        }
        await store.start()
        let runtime = try #require(backend.lastPreparedRuntimeHandle)
        _ = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .milliseconds(20)
        )
        await reviewBackend.yield(
            .completed(summary: "Done", result: "review text"),
            for: run
        )
        await cleanupEntered.wait()
        #expect(try store.readReview(jobID: "job-1").core.lifecycle.status == .succeeded)

        let closeTask = Task { @MainActor in
            try await store.close()
        }
        await runtime.waitForCloseAdmission()

        #expect(runtime.closeCallCount == 0)
        #expect(await reviewBackend.recordedCommands().contains(.cleanupReview(run)) == false)

        await cleanupRelease.open()
        try await closeTask.value

        #expect(await reviewBackend.recordedCommands().contains(.cleanupReview(run)))
        #expect(runtime.closeCallCount == 1)
        #expect(runtime.waitUntilClosedCallCount == 1)
    }
}

@MainActor
private func capturedCloseError(from store: CodexReviewStore) async -> ReviewCloseError? {
    do {
        try await store.close()
        return nil
    } catch let error as ReviewCloseError {
        return error
    } catch {
        Issue.record("Unexpected close error: \(error)")
        return nil
    }
}

private actor StoreCloseCompletion {
    private var completeValue = false

    func complete() {
        completeValue = true
    }

    func isComplete() -> Bool {
        completeValue
    }
}

private final class SequentialJobIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        lock.withLock {
            values.removeFirst()
        }
    }
}
