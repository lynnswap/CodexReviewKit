import Foundation
import Testing
@testable import CodexReview
import CodexReviewTesting

@Suite("review recovery admission")
struct ReviewRecoveryAdmissionTests {
    @Test func recoveryAckWaitsForInterruptedTerminalAndReturnsBarrier() async throws {
        let (admission, run) = try await makeActiveRecoveryAdmission()
        let requestStarted = AsyncGate()

        let recovery = Task {
            try await admission.beginRecovery(
                run,
                trigger: .recoverableNetworkLoss,
                request: { requestAdmission, reason in
                    #expect(requestAdmission.run == run)
                    #expect(reason.message == "Network unavailable; waiting to reconnect.")
                    await requestStarted.open()
                }
            )
        }
        await requestStarted.wait()
        await waitForRecoveryPhase(
            .recovering(
                run: run,
                trigger: .recoverableNetworkLoss,
                request: .acknowledged
            ),
            admission: admission
        )

        let oldTerminal = ReviewTerminalRecord.interrupted(
            .server(message: "Recovery interrupt completed")
        )
        try await admission.recordCanonicalTerminal(oldTerminal, for: run)

        guard case .replacement(let candidate) = try await recovery.value else {
            Issue.record("An interrupted recovery barrier did not create a candidate.")
            return
        }
        #expect(candidate.trigger == .recoverableNetworkLoss)
        #expect(candidate.resolved.run == run)
        #expect(candidate.resolved.terminal == .canonical(oldTerminal))
        #expect(candidate.resolved.requestFailure == nil)
        await admission.recordCancellation(.system(message: "Too late"))
        #expect(await admission.cancellationRequest() == nil)
        #expect(await admission.currentPhase() == .terminal(.recovery(
            .replacement(candidate)
        )))
    }

    @Test func recoveryOutcomeUnknownConnectionReturnsBarrierDiagnostic() async throws {
        let (admission, run) = try await makeActiveRecoveryAdmission()
        let requestFailed = AsyncGate()
        let requestFailure = ReviewInterruptRequestFailure(
            outcome: .outcomeUnknown(message: "Interrupt response was lost")
        )
        let streamFailure = ReviewAttemptStreamFailure.recoverableNetwork(
            .connection("Transport closed")
        )

        let recovery = Task {
            try await admission.beginRecovery(
                run,
                trigger: .recoverableNetworkLoss,
                request: { _, _ in
                    await requestFailed.open()
                    throw requestFailure
                }
            )
        }
        await requestFailed.wait()
        try await admission.recordStreamTerminal(streamFailure, for: run)

        guard case .replacement(let candidate) = try await recovery.value else {
            Issue.record("A recoverable connection terminal did not create a candidate.")
            return
        }
        #expect(candidate.resolved.terminal == .stream(streamFailure))
        #expect(candidate.resolved.requestFailure?.outcome == requestFailure.outcome)
        #expect(
            candidate.resolved.requestFailure?.secondaryBarrierDiagnostic
                == streamFailure.localizedDescription
        )
    }

    @Test(arguments: [
        ReviewTerminalRecord.completed,
        .interrupted(.requested(.system(message: "Already cancelled"))),
    ])
    func recoveryNaturalTerminalSupersedesReplacement(
        _ naturalTerminal: ReviewTerminalRecord
    ) async throws {
        let (admission, run) = try await makeActiveRecoveryAdmission()
        let requestStarted = AsyncGate()

        let recovery = Task {
            try await admission.beginRecovery(
                run,
                trigger: .sameAccountRestart,
                request: { _, _ in await requestStarted.open() }
            )
        }
        await requestStarted.wait()
        try await admission.recordCanonicalTerminal(naturalTerminal, for: run)

        guard case .productTerminal(let disposition) = try await recovery.value else {
            Issue.record("A natural completion was converted into a replacement.")
            return
        }
        #expect(disposition.resolved.terminal == .canonical(naturalTerminal))
        #expect(disposition.productTerminal == naturalTerminal)
    }

    @Test func joinedExplicitCancellationInstallsProductDispositionBeforeRecoveryPreparation() async throws {
        let (admission, run) = try await makeActiveRecoveryAdmission()
        let requestStarted = AsyncGate()
        let requestGate = AsyncGate()
        let requestCount = RecoveryRequestCounter()
        let cancellation = ReviewCancellation.mcpClient(message: "Stop recovery")

        let recovery = Task {
            try await admission.beginRecovery(
                run,
                trigger: .recoverableNetworkLoss,
                request: { _, _ in
                    await requestCount.record()
                    await requestStarted.open()
                    await requestGate.waitIgnoringCancellation()
                }
            )
        }
        await requestStarted.wait()
        let joinedCancellation = Task {
            try await admission.interrupt(
                run,
                cancellation: cancellation,
                request: { _, _ in
                    Issue.record("Joined cancellation dispatched a second request.")
                }
            )
        }
        await waitForCancellation(cancellation, admission: admission)
        await requestGate.open()
        await waitForRecoveryPhase(
            .recovering(
                run: run,
                trigger: .recoverableNetworkLoss,
                request: .acknowledged
            ),
            admission: admission
        )

        let oldTerminal = ReviewTerminalRecord.interrupted(
            .server(message: "Recovery interrupt completed")
        )
        try await admission.recordCanonicalTerminal(oldTerminal, for: run)

        guard case .productTerminal(let disposition) = try await recovery.value else {
            Issue.record("Joined cancellation allowed recovery preparation.")
            return
        }
        #expect(disposition.resolved.terminal == .canonical(oldTerminal))
        #expect(disposition.productTerminal == .interrupted(.requested(cancellation)))
        #expect(await requestCount.count() == 1)

        let cancellationResolution = try await joinedCancellation.value
        #expect(cancellationResolution.cancellation == cancellation)
        #expect(cancellationResolution.terminal == .canonical(oldTerminal))
    }

    @Test func terminalBeforeRecoveryAcknowledgementSuppressesReplacementWithoutRelabelingCause() async throws {
        let (admission, run) = try await makeActiveRecoveryAdmission()
        let requestStarted = AsyncGate()
        let requestGate = AsyncGate()
        let cancellation = ReviewCancellation.system(message: "Late stop")
        let oldTerminal = ReviewTerminalRecord.interrupted(
            .server(message: "Recovery terminal won first")
        )

        let recovery = Task {
            try await admission.beginRecovery(
                run,
                trigger: .recoverableNetworkLoss,
                request: { _, _ in
                    await requestStarted.open()
                    await requestGate.waitIgnoringCancellation()
                }
            )
        }
        await requestStarted.wait()
        try await admission.recordCanonicalTerminal(oldTerminal, for: run)

        let joinedCancellation = Task {
            try await admission.interrupt(
                run,
                cancellation: cancellation,
                request: { _, _ in
                    Issue.record("Late cancellation dispatched a second request.")
                }
            )
        }
        await waitForCancellation(cancellation, admission: admission)
        await requestGate.open()

        guard case .productTerminal(let disposition) = try await recovery.value else {
            Issue.record("Joined cancellation failed to suppress recovery preparation.")
            return
        }
        #expect(disposition.resolved.terminal == .canonical(oldTerminal))
        #expect(disposition.productTerminal == oldTerminal)
        let cancellationResolution = try await joinedCancellation.value
        #expect(cancellationResolution.terminal == .canonical(oldTerminal))
    }

    @Test func recoveryClassifiesTypedStreamFailureBeforeTokenization() async throws {
        let (admission, run) = try await makeActiveRecoveryAdmission()
        let requestStarted = AsyncGate()
        let contractFailure = ReviewAttemptContractFailure(
            message: "Malformed routed review notification"
        )
        let streamFailure = ReviewAttemptStreamFailure.protocolViolation(
            contractFailure
        )

        let recovery = Task {
            try await admission.beginRecovery(
                run,
                trigger: .recoverableNetworkLoss,
                request: { _, _ in await requestStarted.open() }
            )
        }
        await requestStarted.wait()
        await waitForRecoveryPhase(
            .recovering(
                run: run,
                trigger: .recoverableNetworkLoss,
                request: .acknowledged
            ),
            admission: admission
        )
        let cancellation = ReviewCancellation.system(message: "Stop after ACK")
        let joinedCancellation = Task {
            try await admission.interrupt(
                run,
                cancellation: cancellation,
                request: { _, _ in
                    Issue.record("Joined cancellation dispatched a second request.")
                }
            )
        }
        await waitForCancellation(cancellation, admission: admission)
        try await admission.recordStreamTerminal(streamFailure, for: run)

        guard case .productTerminal(let disposition) = try await recovery.value else {
            Issue.record("A protocol violation was exposed as a tokenizable candidate.")
            return
        }
        #expect(disposition.resolved.terminal == .stream(streamFailure))
        #expect(disposition.productTerminal == .failed(
            message: contractFailure.localizedDescription
        ))
        #expect(try await joinedCancellation.value.terminal == .stream(streamFailure))
    }

    @Test func preexistingRecoverableTerminalRequiresCanonicalPairBeforeCandidate() async throws {
        let (admission, run) = try await makeActiveRecoveryAdmission(turnID: nil)
        try await admission.recordStreamTerminal(
            .recoverableNetwork(.connection("Transport closed")),
            for: run
        )

        await #expect(throws: ReviewStartAdmissionContractFailure(
            violation: .interruptRequestRequiresCanonicalPair(run)
        )) {
            try await admission.beginRecovery(
                run,
                trigger: .recoverableNetworkLoss,
                request: { _, _ in Issue.record("Incomplete routing dispatched a request.") }
            )
        }
    }

    @Test func recoveryHandoffCopiesShareOneConsumptionOwner() async throws {
        let candidate = makeRecoveryCandidate()
        let token = CodexReviewBackendModel.Review.RecoveryToken(
            interruptedRun: candidate.resolved.run,
            rollbackThreadID: "review-thread"
        )
        let handoff = try await candidate.prepareHandoff(token: token)
        let copy = handoff

        async let first = consume(handoff)
        async let second = consume(copy)
        let results = await [first, second]

        #expect(results.filter { $0 == .consumed(token) }.count == 1)
        #expect(results.filter { $0 == .alreadyConsumed }.count == 1)
    }

    @Test func ownerCancellationRemainsATypedMailboxFailure() async {
        let mailbox = BackendReviewEventMailbox()
        await mailbox.fail(.ownerCancellation)

        do {
            _ = try await mailbox.next()
            Issue.record("Owner cancellation was delivered as normal completion.")
        } catch let error as BackendReviewEventMailboxError {
            #expect(error.failure == .ownerCancellation)
        } catch {
            Issue.record("Owner cancellation lost its typed failure: \(error)")
        }
    }

    @Test func duplicateLegacyConnectionIsIdempotentAfterRecoveryDisposition() async throws {
        let (admission, run) = try await makeActiveRecoveryAdmission()
        let connection = ReviewRuntimeCloseFailure.connection("Transport closed")
        try await admission.recordConnectionTerminal(connection, for: run)

        let disposition = try await admission.beginRecovery(
            run,
            trigger: .recoverableNetworkLoss,
            request: { _, _ in Issue.record("A resolved terminal dispatched recovery.") }
        )
        try await admission.recordConnectionTerminal(connection, for: run)

        #expect(await admission.currentPhase() == .terminal(.recovery(disposition)))
        #expect(disposition.resolved.terminal == .stream(
            .unexpectedConnection(connection)
        ))
    }

    @Test func rollbackIsOutcomeUnknownBeforeItsNonIdempotentSend() async throws {
        let admission = ReviewStartAdmission()
        let predecessor = makeRecoveryCandidate().resolved.run

        try await admission.admitRecoveryRollbackDispatch(for: predecessor)
        #expect(await admission.currentPhase() == .rollingBackRecovery(
            predecessorRun: predecessor
        ))

        try await admission.recordRecoveryRollbackAcknowledged(for: predecessor)
        #expect(await admission.currentPhase() == .preparingThread(.notSent))
    }
}

private enum HandoffConsumptionResult: Equatable, Sendable {
    case consumed(CodexReviewBackendModel.Review.RecoveryToken)
    case alreadyConsumed
    case otherFailure(String)
}

private func consume(
    _ handoff: ReviewRecoveryHandoff
) async -> HandoffConsumptionResult {
    do {
        return .consumed(try await handoff.consume().token)
    } catch is ReviewRecoveryHandoffAlreadyConsumed {
        return .alreadyConsumed
    } catch {
        return .otherFailure(error.localizedDescription)
    }
}

private func makeRecoveryCandidate() -> ReviewRecoveryCandidate {
    let run = CodexReviewBackendModel.Review.Run(
        attemptID: "handoff-attempt",
        threadID: "parent-thread",
        turnID: "turn-1",
        reviewThreadID: "review-thread",
        model: "gpt-5"
    )
    return .init(
        resolved: .init(
            run: run,
            terminal: .canonical(.interrupted(.server(message: "Recovered"))),
            requestFailure: nil
        ),
        trigger: .recoverableNetworkLoss
    )
}

private actor RecoveryRequestCounter {
    private var value = 0

    func record() {
        value += 1
    }

    func count() -> Int { value }
}

private func waitForRecoveryPhase(
    _ expected: ReviewStartAdmission.Phase,
    admission: ReviewStartAdmission
) async {
    for _ in 0..<1_000 {
        if await admission.currentPhase() == expected {
            return
        }
        await Task.yield()
    }
    Issue.record("Recovery admission did not reach \(String(describing: expected)).")
}

private func waitForCancellation(
    _ expected: ReviewCancellation,
    admission: ReviewStartAdmission
) async {
    for _ in 0..<1_000 {
        if await admission.cancellationRequest() == expected {
            return
        }
        await Task.yield()
    }
    Issue.record("Recovery admission did not join the explicit cancellation.")
}

private func makeActiveRecoveryAdmission(
    turnID: String? = "turn-1"
) async throws -> (
    admission: ReviewStartAdmission,
    run: CodexReviewBackendModel.Review.Run
) {
    let admission = ReviewStartAdmission()
    let provisionalRun = CodexReviewBackendModel.Review.Run(
        attemptID: "recovery-attempt",
        threadID: "parent-thread",
        reviewThreadID: "parent-thread",
        model: "gpt-5"
    )
    let run = CodexReviewBackendModel.Review.Run(
        attemptID: provisionalRun.attemptID,
        threadID: provisionalRun.threadID,
        turnID: turnID,
        reviewThreadID: "review-thread",
        model: provisionalRun.model
    )
    try await admission.admitThreadStartDispatch()
    try await admission.recordPreparedThread(provisionalRun)
    try await admission.admitReviewStartDispatch(for: provisionalRun)
    try await admission.recordActiveRun(run)
    return (admission, run)
}
