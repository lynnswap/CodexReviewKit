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
        try receipt.start(.disposition) {
            await release.waitIgnoringCancellation()
            return .disposition(.success(.replacement(candidate)))
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
        try receipt.start(.preparation) { .prepared(.success(prepared)) }
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
        try preparedReceipt.start(.disposition) { .disposition(.success(.replacement(candidate))) }
        _ = try await preparedReceipt.joinOwnedOperation().value
        try preparedReceipt.start(.preparation) { .prepared(.success(invalidPrepared)) }
        await #expect(throws: ReviewAttemptContractFailure.self) {
            try await preparedReceipt.joinOwnedOperation().value
        }
        guard case .prepared(let exactPrepared) = try preparedReceipt.suppress() else {
            Issue.record("Prepared discard target was lost."); return
        }
        #expect(exactPrepared.receipt === invalidPrepared.receipt)
        let inactive = StagedReviewRecovery(
            receipt: prepared.receipt, destinationGeneration: .init(rawValue: 2),
            attempt: .init(run: .init(attemptID: "inactive", threadID: run.threadID)),
            admission: ReviewStartAdmission()
        )
        let rejected = StoreReviewRecoveryReceipt(source: source)
        try await advance(rejected, candidate: candidate, prepared: prepared)
        try rejected.start(.staging(inactive.admission)) { .staged(.success(inactive)) }
        await #expect(throws: ReviewAttemptContractFailure.self) {
            try await rejected.joinOwnedOperation().value
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
        try finishing.start(.staging(admission)) {
            await stageGate.waitIgnoringCancellation()
            return .staged(.success(staged))
        }
        let promotion = try finishing.joinOwnedOperation()
        await staged.attempt.events.append(.message("mailbox continuity"))
        await stageGate.open()
        _ = try await promotion.value
        let active = try finishing.finish(staged)
        #expect(active.matches(.init(attempt: staged.attempt, admission: admission)))
        #expect(active.matches(.init(attempt: .init(run: recoveredRun), admission: admission)) == false)
        #expect(try await active.attempt.events.next() == .message("mailbox continuity"))
        #expect(throws: ReviewAttemptContractFailure.self) { try finishing.finish(staged) }

        let cancellationRun = CodexReviewBackendModel.Review.Run(
            attemptID: "cancelled-destination", threadID: run.threadID
        )
        let cancellationAdmission = try await activeAdmission(for: cancellationRun)
        let cancelledStage = StagedReviewRecovery(
            receipt: prepared.receipt, destinationGeneration: .init(rawValue: 2),
            attempt: .init(run: cancellationRun), admission: cancellationAdmission
        )
        let cancelledDestination = StoreReviewRecoveryReceipt(source: source)
        try await advance(cancelledDestination, candidate: candidate, prepared: prepared)
        try cancelledDestination.start(.staging(cancellationAdmission)) { .staged(.success(cancelledStage)) }
        _ = try await cancelledDestination.joinOwnedOperation().value
        await cancelledDestination.cancelOwnedOperation(.mcpClient(message: "Stop")).value
        #expect(await cancellationAdmission.permitsRecoveryPublication(of: cancellationRun) == false)
        guard case .staged(let cancelledTarget) = try cancelledDestination.suppress() else {
            Issue.record("Cancelled destination discard target was lost."); return
        }
        #expect(cancelledTarget === cancelledStage)

        let inFlightAdmission = try await activeAdmission(for: cancellationRun)
        let inFlightStage = StagedReviewRecovery(
            receipt: prepared.receipt, destinationGeneration: .init(rawValue: 2),
            attempt: .init(run: cancellationRun), admission: inFlightAdmission
        )
        let inFlight = StoreReviewRecoveryReceipt(source: source)
        try await advance(inFlight, candidate: candidate, prepared: prepared)
        let inFlightGate = AsyncGate()
        try inFlight.start(.staging(inFlightAdmission)) {
            await inFlightGate.waitIgnoringCancellation()
            return .staged(.success(inFlightStage))
        }
        let inFlightJoin = try inFlight.joinOwnedOperation()
        await inFlight.cancelOwnedOperation(.mcpClient(message: "Stop")).value
        await inFlightGate.open()
        await #expect(throws: ReviewAttemptContractFailure.self) { try await inFlightJoin.value }
        guard case .staged(let inFlightTarget) = try inFlight.suppress() else {
            Issue.record("In-flight destination discard target was lost."); return
        }
        #expect(inFlightTarget === inFlightStage)

        var cancelled: StoreReviewRecoveryReceipt? = .init(source: source)
        weak let released = cancelled
        try cancelled?.start(.disposition) {
            .disposition(.success(.replacement(candidate)))
        }
        _ = try await cancelled?.joinOwnedOperation().value
        let gate = AsyncGate()
        try cancelled?.start(.preparation) {
            await gate.waitIgnoringCancellation()
            return .prepared(.success(prepared))
        }
        var cancellationJoin = try cancelled?.joinOwnedOperation()
        await cancelled?.cancelOwnedOperation(.mcpClient(message: "Stop")).value
        await gate.open()
        await #expect(throws: CancellationError.self) { try await cancellationJoin?.value }
        cancellationJoin = nil
        #expect(throws: ReviewAttemptContractFailure.self) {
            try cancelled?.start(.staging(inactive.admission)) { .staged(.success(inactive)) }
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
        try receipt.start(.disposition) { .disposition(.success(.replacement(candidate))) }
        _ = try await receipt.joinOwnedOperation().value
        try receipt.start(.preparation) { .prepared(.success(prepared)) }
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
