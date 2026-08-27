import Testing
@testable import CodexReview
import CodexReviewTesting
@Suite("Store recovery receipt")
@MainActor
struct StoreReviewRecoveryReceiptTests {
    @Test func reentrantJoinCannotClearTheSuccessorPhase() async throws {
        let (_, source, candidate, prepared) = try await fixture()
        let receipt = StoreReviewRecoveryReceipt(source: source)
        let release = AsyncGate()
        try receipt.startDisposition {
            await release.waitIgnoringCancellation()
            return .replacement(candidate)
        }
        let first = try receipt.joinOwnedOperation()
        #expect(throws: ReviewAttemptContractFailure.self) {
            _ = try receipt.joinOwnedOperation()
        }
        await release.open()
        guard case .disposition = try await first.value,
              case .disposition = try await first.value else {
            Issue.record("A completed join did not replay its result."); return
        }
        try receipt.startPreparation { prepared }
        guard case .prepared(let owned) = try await receipt.joinOwnedOperation().value else {
            Issue.record("Successor phase was not joinable."); return
        }
        #expect(owned.receipt === prepared.receipt)
    }

    @Test func exactReceiptRegistersBeforeCurrentPreparationCancellation() async throws {
        let (_, source, candidate, prepared) = try await fixture()
        let receipt = StoreReviewRecoveryReceipt(source: source)
        try receipt.startDisposition { .replacement(candidate) }
        _ = try await receipt.joinOwnedOperation().value
        let preparationStarted = AsyncGate()
        let preparationGate = AsyncGate()
        let preparationCancelled = AsyncGate()
        try receipt.startPreparation {
            await preparationStarted.open()
            await preparationGate.wait()
            if Task.isCancelled {
                await preparationCancelled.open()
                await preparationGate.waitIgnoringCancellation()
            }
            return prepared
        }
        let preparationJoin = try receipt.joinOwnedOperation()
        await preparationStarted.wait()
        let cancellation = ReviewCancellation.system(message: "Runtime stopped")
        let cancellationRequest = ReviewCancellationRequestReceipt(
            id: .init(jobID: "job-1", ordinal: 1),
            cancellation: cancellation,
            rejectionDisposition: .preserveRuntimeStopIntent,
            registeredWorkAdmission: nil
        )

        let cancel = Task { @MainActor in
            await receipt.cancelOwnedOperation(cancellationRequest: cancellationRequest)
        }
        await preparationCancelled.wait()
        let registration = await cancel.value

        #expect(registration.receipt == cancellationRequest)
        #expect(registration.disposition == .adopted)
        #expect(await source.admission.cancellationRequest() == cancellation)
        await preparationGate.open()
        await #expect(throws: CancellationError.self) {
            try await preparationJoin.value
        }
    }

    @Test func ownsDiscardPromotionCancellationAndRelease() async throws {
        let (run, source, candidate, prepared) = try await fixture()
        let invalidPrepared = PreparedReviewRecovery(
            receipt: .init(
                sourceRun: .init(attemptID: "wrong-source", threadID: run.threadID),
                sourceGeneration: .init(rawValue: 1)
            ),
            handoff: prepared.handoff
        )
        let preparedReceipt = StoreReviewRecoveryReceipt(source: source)
        try preparedReceipt.startDisposition { .replacement(candidate) }
        _ = try await preparedReceipt.joinOwnedOperation().value
        try preparedReceipt.startPreparation { invalidPrepared }
        await #expect(throws: ReviewAttemptContractFailure.self) {
            try await preparedReceipt.joinOwnedOperation().value
        }
        #expect(throws: ReviewAttemptContractFailure.self) {
            try preparedReceipt.startStaging(admission: ReviewStartAdmission()) {
                _ async throws(ReviewRecoveryStagingFailure) -> StagedReviewRecovery in
                throw ReviewRecoveryStagingFailure.callerRetainsPreparedRecovery(
                    message: "Must not run"
                )
            }
        }
        guard case .prepared(let exactPrepared) = try preparedReceipt.suppress() else {
            Issue.record("Prepared discard target was lost."); return
        }
        #expect(exactPrepared.receipt === invalidPrepared.receipt)

        let callerRetained = StoreReviewRecoveryReceipt(source: source)
        try await advance(callerRetained, candidate: candidate, prepared: prepared)
        let callerRetainedFailure = ReviewRecoveryStagingFailure
            .callerRetainsPreparedRecovery(message: "Destination is not ready")
        try callerRetained.startStaging(admission: ReviewStartAdmission()) {
            _ async throws(ReviewRecoveryStagingFailure) -> StagedReviewRecovery in
            throw callerRetainedFailure
        }
        await #expect(throws: callerRetainedFailure) {
            try await callerRetained.joinOwnedOperation().value
        }
        guard case .prepared(let callerRetainedTarget) = try callerRetained.suppress() else {
            Issue.record("Caller-retained staging failure lost the prepared target."); return
        }
        #expect(callerRetainedTarget.receipt === prepared.receipt)

        let backendOwned = StoreReviewRecoveryReceipt(source: source)
        try await advance(backendOwned, candidate: candidate, prepared: prepared)
        let backendOwnedFailure = ReviewRecoveryStagingFailure
            .backendOwnsRecovery(message: "Backend consumed the recovery route")
        try backendOwned.startStaging(admission: ReviewStartAdmission()) {
            _ async throws(ReviewRecoveryStagingFailure) -> StagedReviewRecovery in
            throw backendOwnedFailure
        }
        await #expect(throws: backendOwnedFailure) {
            try await backendOwned.joinOwnedOperation().value
        }
        #expect(try backendOwned.suppress() == nil)

        let inactive = StagedReviewRecovery(
            receipt: prepared.receipt, destinationGeneration: .init(rawValue: 2),
            attempt: .init(run: .init(attemptID: "inactive", threadID: run.threadID)),
            admission: ReviewStartAdmission()
        )
        let rejected = StoreReviewRecoveryReceipt(source: source)
        try await advance(rejected, candidate: candidate, prepared: prepared)
        try rejected.startStaging(admission: inactive.admission) { _ in inactive }
        await #expect(throws: ReviewAttemptContractFailure.self) {
            try await rejected.joinOwnedOperation().value
        }
        #expect(throws: ReviewAttemptContractFailure.self) {
            try rejected.startCommit { _ in
                Issue.record("A rejected staged recovery reached commit.")
            }
        }
        guard case .staged(let exactStaged) = try rejected.suppress() else {
            Issue.record("Rejected staged target was lost."); return
        }
        #expect(exactStaged === inactive)
        let recoveredRun = CodexReviewBackendModel.Review.Run(attemptID: "recovered", threadID: run.threadID)
        let admission = try await activeAdmission(for: recoveredRun)
        let staged = StagedReviewRecovery(
            receipt: prepared.receipt, destinationGeneration: .init(rawValue: 2),
            attempt: .init(run: recoveredRun), admission: admission
        )
        let finishing = StoreReviewRecoveryReceipt(source: source)
        try await advance(finishing, candidate: candidate, prepared: prepared)
        let stageGate = AsyncGate()
        try finishing.startStaging(admission: admission) { _ in
            await stageGate.waitIgnoringCancellation()
            return staged
        }
        let promotion = try finishing.joinOwnedOperation()
        await staged.attempt.events.append(.message("mailbox continuity"))
        await stageGate.open()
        _ = try await promotion.value
        #expect(throws: ReviewAttemptContractFailure.self) { try finishing.finishCommitted() }
        try finishing.startCommit { exactStaged in
            #expect(exactStaged === staged)
        }
        guard case .committed(let committed) = try await finishing.joinOwnedOperation().value else {
            Issue.record("Commit completion was not retained."); return
        }
        #expect(committed === staged)
        let active = try finishing.finishCommitted()
        #expect(active.matches(.init(
            attempt: staged.attempt,
            admission: admission,
            workerAdmission: source.workerAdmission
        )))
        #expect(active.matches(.init(
            attempt: .init(run: recoveredRun),
            admission: admission,
            workerAdmission: source.workerAdmission
        )) == false)
        #expect(try await active.attempt.events.next() == .message("mailbox continuity"))
        #expect(throws: ReviewAttemptContractFailure.self) { try finishing.finishCommitted() }

        let cancellationRun = CodexReviewBackendModel.Review.Run(
            attemptID: "cancelled-destination", threadID: run.threadID
        )
        let failedCommitAdmission = try await activeAdmission(for: cancellationRun)
        let failedCommitStage = StagedReviewRecovery(
            receipt: prepared.receipt, destinationGeneration: .init(rawValue: 2),
            attempt: .init(run: cancellationRun), admission: failedCommitAdmission
        )
        let failedCommit = StoreReviewRecoveryReceipt(source: source)
        try await advance(failedCommit, candidate: candidate, prepared: prepared)
        try failedCommit.startStaging(admission: failedCommitAdmission) { _ in failedCommitStage }
        _ = try await failedCommit.joinOwnedOperation().value
        try failedCommit.startCommit { exactStaged in
            #expect(exactStaged === failedCommitStage)
            throw ReviewAttemptContractFailure(message: "commit failed")
        }
        await #expect(throws: ReviewAttemptContractFailure.self) {
            try await failedCommit.joinOwnedOperation().value
        }
        guard case .staged(let failedCommitTarget) = try failedCommit.suppress() else {
            Issue.record("Failed commit discard target was lost."); return
        }
        #expect(failedCommitTarget === failedCommitStage)

        let inFlightAdmission = try await activeAdmission(for: cancellationRun)
        let inFlightStage = StagedReviewRecovery(
            receipt: prepared.receipt, destinationGeneration: .init(rawValue: 2),
            attempt: .init(run: cancellationRun), admission: inFlightAdmission
        )
        let inFlight = StoreReviewRecoveryReceipt(source: source)
        try await advance(inFlight, candidate: candidate, prepared: prepared)
        let inFlightGate = AsyncGate()
        try inFlight.startStaging(admission: inFlightAdmission) { _ in
            await inFlightGate.waitIgnoringCancellation()
            return inFlightStage
        }
        let inFlightJoin = try inFlight.joinOwnedOperation()
        let firstCancellation = ReviewCancellation.mcpClient(message: "First stop")
        await inFlight.cancelOwnedOperation(firstCancellation)
        await inFlight.cancelOwnedOperation(.system(message: "Second stop"))
        #expect(await inFlightAdmission.cancellationRequest() == firstCancellation)
        await inFlightGate.open()
        await #expect(throws: CancellationError.self) { try await inFlightJoin.value }
        guard case .staged(let inFlightTarget) = try inFlight.suppress() else {
            Issue.record("In-flight destination discard target was lost."); return
        }
        #expect(inFlightTarget === inFlightStage)

        let committedRun = CodexReviewBackendModel.Review.Run(
            attemptID: "committed-after-cancel", threadID: run.threadID
        )
        let committedAdmission = try await activeAdmission(for: committedRun)
        let committedStage = StagedReviewRecovery(
            receipt: prepared.receipt, destinationGeneration: .init(rawValue: 2),
            attempt: .init(run: committedRun), admission: committedAdmission
        )
        let committedReceipt = StoreReviewRecoveryReceipt(source: source)
        try await advance(committedReceipt, candidate: candidate, prepared: prepared)
        try committedReceipt.startStaging(admission: committedAdmission) { _ in committedStage }
        _ = try await committedReceipt.joinOwnedOperation().value
        let commitLinearized = AsyncGate()
        let releaseCommit = AsyncGate()
        try committedReceipt.startCommit { exactStaged in
            #expect(exactStaged === committedStage)
            await commitLinearized.open()
            await releaseCommit.waitIgnoringCancellation()
        }
        let commitJoin = try committedReceipt.joinOwnedOperation()
        await commitLinearized.wait()
        let afterCommitCancellation = ReviewCancellation.system(message: "Stop after commit")
        await committedReceipt.cancelOwnedOperation(afterCommitCancellation)
        await releaseCommit.open()
        guard case .committed(let exactCommitted) = try await commitJoin.value else {
            Issue.record("Linearized commit was not retained."); return
        }
        #expect(exactCommitted === committedStage)
        let committedActive = try committedReceipt.finishCommitted()
        #expect(committedActive.matches(.init(
            attempt: committedStage.attempt,
            admission: committedAdmission,
            workerAdmission: source.workerAdmission
        )))
        #expect(await committedAdmission.cancellationRequest() == afterCommitCancellation)

        var cancelled: StoreReviewRecoveryReceipt? = .init(source: source)
        weak let released = cancelled
        try cancelled?.startDisposition { .replacement(candidate) }
        _ = try await cancelled?.joinOwnedOperation().value
        let gate = AsyncGate()
        try cancelled?.startPreparation {
            await gate.waitIgnoringCancellation()
            return prepared
        }
        var cancellationJoin = try cancelled?.joinOwnedOperation()
        await cancelled?.cancelOwnedOperation(.mcpClient(message: "Stop"))
        await gate.open()
        await #expect(throws: CancellationError.self) { try await cancellationJoin?.value }
        cancellationJoin = nil
        #expect(throws: CancellationError.self) {
            try cancelled?.startStaging(admission: inactive.admission) { _ in inactive }
        }
        guard case .prepared(let cancelledTarget) = try cancelled?.suppress() else {
            Issue.record("Cancelled prepared target was lost."); return
        }
        #expect(cancelledTarget.receipt === prepared.receipt)
        cancelled = nil
        #expect(released == nil)
    }
    @Test func testingBackendRecordsExactRecoveryScript() async throws {
        let fake = FakeCodexReviewBackend()
        let backend = TestingCodexReviewStoreBackend(reviewBackend: fake)
        let sourceGeneration = ReviewRuntimeGeneration(rawValue: 3)
        let destinationGeneration = ReviewRuntimeGeneration(rawValue: 4)
        let run1 = CodexReviewBackendModel.Review.Run(attemptID: "source-1", threadID: "thread-1")
        let candidate1 = recoveryCandidate(for: run1)
        await #expect(throws: ReviewAttemptContractFailure.self) {
            try await backend.prepareReviewRecovery(candidate1)
        }
        #expect(throws: ReviewAttemptContractFailure.self) {
            try backend.scriptReviewRecoveryRoute(
                sourceGeneration: .init(rawValue: 0), destinationGeneration: destinationGeneration
            )
        }
        try script(backend, source: sourceGeneration, destination: destinationGeneration)
        let prepared1 = try await backend.prepareReviewRecovery(candidate1)
        try await backend.discardReviewRecovery(prepared1)

        let run2 = CodexReviewBackendModel.Review.Run(attemptID: "source-2", threadID: "thread-2")
        let candidate2 = recoveryCandidate(for: run2)
        try script(backend, source: sourceGeneration, destination: destinationGeneration)
        let prepared2 = try await backend.prepareReviewRecovery(candidate2)
        let recovered2 = CodexReviewBackendModel.Review.Run(attemptID: "destination-2", threadID: run2.threadID)
        await fake.setNextRecoveredRun(recovered2)
        let admission2 = ReviewStartAdmission()
        let generationFailure = ReviewRecoveryStagingFailure.callerRetainsPreparedRecovery(
            message: "Testing recovery destination generation was not scripted exactly."
        )
        await #expect(throws: generationFailure) {
            try await backend.stageReviewRecovery(
                prepared2, destinationGeneration: .init(rawValue: 5),
                request: reviewRequest(), admission: admission2
            )
        }
        let nonfreshAdmission = try await activeAdmission(for: recovered2)
        let admissionFailure = ReviewRecoveryStagingFailure.callerRetainsPreparedRecovery(
            message: "Testing recovery staging requires one fresh destination admission."
        )
        await #expect(throws: admissionFailure) {
            try await backend.stageReviewRecovery(
                prepared2, destinationGeneration: destinationGeneration,
                request: reviewRequest(), admission: nonfreshAdmission
            )
        }
        let staged2 = try await backend.stageReviewRecovery(
            prepared2, destinationGeneration: destinationGeneration,
            request: reviewRequest(), admission: admission2
        )
        let staleRouteFailure = ReviewRecoveryStagingFailure.backendOwnsRecovery(
            message: "Testing recovery staging lost its exact scripted prepared route."
        )
        await #expect(throws: staleRouteFailure) {
            try await backend.stageReviewRecovery(
                prepared2, destinationGeneration: destinationGeneration,
                request: reviewRequest(), admission: ReviewStartAdmission()
            )
        }
        try await backend.commitReviewRecovery(staged2)
        await #expect(throws: ReviewAttemptContractFailure.self) {
            try await backend.discardReviewRecovery(staged2)
        }

        let run3 = CodexReviewBackendModel.Review.Run(attemptID: "source-3", threadID: "thread-3")
        try script(backend, source: destinationGeneration, destination: destinationGeneration)
        let prepared3 = try await backend.prepareReviewRecovery(recoveryCandidate(for: run3))
        let recovered3 = CodexReviewBackendModel.Review.Run(attemptID: "destination-3", threadID: run3.threadID)
        await fake.setNextRecoveredRun(recovered3)
        let staged3 = try await backend.stageReviewRecovery(
            prepared3, destinationGeneration: destinationGeneration,
            request: reviewRequest(), admission: ReviewStartAdmission()
        )
        try await backend.discardReviewRecovery(staged3)

        let run4 = CodexReviewBackendModel.Review.Run(attemptID: "source-4", threadID: "thread-4")
        try script(backend, source: destinationGeneration, destination: .init(rawValue: 5))
        let prepared4 = try await backend.prepareReviewRecovery(recoveryCandidate(for: run4))
        await fake.failRecovery(message: "stage failed")
        await #expect(throws: ReviewRecoveryStagingFailure.backendOwnsRecovery(
            message: "stage failed"
        )) {
            try await backend.stageReviewRecovery(
                prepared4, destinationGeneration: .init(rawValue: 5),
                request: reviewRequest(), admission: ReviewStartAdmission()
            )
        }

        let commands = backend.reviewRecoveryCommands
        guard commands.count == 10,
              case .prepare(let loggedCandidate, let loggedSource) = commands[0],
              case .discardPrepared(let loggedPrepared) = commands[1],
              case .stage(let loggedStage, let loggedDestination, let loggedAdmission) = commands[3],
              case .commit(let loggedCommit) = commands[4],
              case .discardStaged(let loggedDiscard) = commands[7] else {
            Issue.record("Testing recovery command script was incomplete."); return
        }
        #expect(loggedCandidate == candidate1 && loggedSource == sourceGeneration)
        #expect(loggedPrepared.receipt === prepared1.receipt)
        #expect(loggedStage.receipt === prepared2.receipt && loggedDestination == destinationGeneration)
        #expect(loggedAdmission === admission2 && loggedCommit === staged2 && loggedDiscard === staged3)
        guard case .cleanupReview(let rollbackRun) = await fake.recordedCommands().last else {
            Issue.record("Failed staging did not record exact rollback cleanup."); return
        }
        #expect(rollbackRun == run4)
    }
    private func advance(
        _ receipt: StoreReviewRecoveryReceipt, candidate: ReviewRecoveryCandidate,
        prepared: PreparedReviewRecovery
    ) async throws {
        try receipt.startDisposition { .replacement(candidate) }
        _ = try await receipt.joinOwnedOperation().value
        try receipt.startPreparation { prepared }
        _ = try await receipt.joinOwnedOperation().value
    }
    private func fixture() async throws -> (
        CodexReviewBackendModel.Review.Run, StoreReviewActiveAttempt,
        ReviewRecoveryCandidate, PreparedReviewRecovery
    ) {
        let run = CodexReviewBackendModel.Review.Run(threadID: "thread", turnID: "turn", reviewThreadID: "review")
        let source = StoreReviewActiveAttempt(attempt: .init(run: run), admission: ReviewStartAdmission())
        let candidate = recoveryCandidate(for: run)
        let prepared = PreparedReviewRecovery(
            receipt: .init(sourceRun: run, sourceGeneration: .init(rawValue: 1)),
            handoff: try await candidate.prepareHandoff(token: .init(
                interruptedRun: run, rollbackThreadID: run.threadID
            ))
        )
        return (run, source, candidate, prepared)
    }
    private func recoveryCandidate(for run: CodexReviewBackendModel.Review.Run) -> ReviewRecoveryCandidate {
        .init(
            resolved: .init(
                run: run,
                terminal: .stream(.recoverableNetwork(.connection("offline"))),
                requestFailure: nil
            ),
            trigger: .recoverableNetworkLoss
        )
    }
    private func activeAdmission(for run: CodexReviewBackendModel.Review.Run) async throws -> ReviewStartAdmission {
        let admission = ReviewStartAdmission()
        try await admission.recordPreparedRecoveryRun(run)
        try await admission.admitReviewStartDispatch(for: run)
        try await admission.recordActiveRun(run)
        return admission
    }
    private func script(
        _ backend: TestingCodexReviewStoreBackend,
        source: ReviewRuntimeGeneration,
        destination: ReviewRuntimeGeneration
    ) throws {
        try backend.scriptReviewRecoveryRoute(
            sourceGeneration: source,
            destinationGeneration: destination
        )
    }
    private func reviewRequest() -> CodexReviewBackendModel.Review.Start {
        .init(
            jobID: "job", sessionID: "session",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges), model: "gpt-5"
        )
    }
}
