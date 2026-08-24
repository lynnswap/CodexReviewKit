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
                () async throws(ReviewRecoveryStagingFailure) -> StagedReviewRecovery in
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
            () async throws(ReviewRecoveryStagingFailure) -> StagedReviewRecovery in
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
            () async throws(ReviewRecoveryStagingFailure) -> StagedReviewRecovery in
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
        try rejected.startStaging(admission: inactive.admission) { inactive }
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
        try finishing.startStaging(admission: admission) {
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
        #expect(active.matches(.init(attempt: staged.attempt, admission: admission)))
        #expect(active.matches(.init(attempt: .init(run: recoveredRun), admission: admission)) == false)
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
        try failedCommit.startStaging(admission: failedCommitAdmission) { failedCommitStage }
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
        try inFlight.startStaging(admission: inFlightAdmission) {
            await inFlightGate.waitIgnoringCancellation()
            return inFlightStage
        }
        let inFlightJoin = try inFlight.joinOwnedOperation()
        let firstCancellation = ReviewCancellation.mcpClient(message: "First stop")
        await inFlight.cancelOwnedOperation(firstCancellation).value
        await inFlight.cancelOwnedOperation(.system(message: "Second stop")).value
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
        try committedReceipt.startStaging(admission: committedAdmission) { committedStage }
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
        await committedReceipt.cancelOwnedOperation(afterCommitCancellation).value
        await releaseCommit.open()
        guard case .committed(let exactCommitted) = try await commitJoin.value else {
            Issue.record("Linearized commit was not retained."); return
        }
        #expect(exactCommitted === committedStage)
        let committedActive = try committedReceipt.finishCommitted()
        #expect(committedActive.matches(.init(
            attempt: committedStage.attempt,
            admission: committedAdmission
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
        await cancelled?.cancelOwnedOperation(.mcpClient(message: "Stop")).value
        await gate.open()
        await #expect(throws: CancellationError.self) { try await cancellationJoin?.value }
        cancellationJoin = nil
        #expect(throws: CancellationError.self) {
            try cancelled?.startStaging(admission: inactive.admission) { inactive }
        }
        guard case .prepared(let cancelledTarget) = try cancelled?.suppress() else {
            Issue.record("Cancelled prepared target was lost."); return
        }
        #expect(cancelledTarget.receipt === prepared.receipt)
        cancelled = nil
        #expect(released == nil)
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
}
