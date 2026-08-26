import Foundation
import Testing
@testable import CodexReview
import CodexReviewTesting

@Suite("review interrupt admission")
struct ReviewInterruptAdmissionTests {
    @Test func interruptAcknowledgementWaitsForCanonicalTerminal() async throws {
        let (admission, run) = try await makeActiveInterruptAdmission()
        let requestStarted = AsyncGate()
        let cancellation = ReviewCancellation.mcpClient(message: "Stop")

        let interruption = Task {
            try await admission.interrupt(
                run,
                cancellation: cancellation,
                request: { _, reason in
                    #expect(reason.message == cancellation.message)
                    await requestStarted.open()
                }
            )
        }
        await requestStarted.wait()

        guard case .interrupting(let phaseRun, let phaseCancellation, _) =
            await admission.currentPhase()
        else {
            Issue.record("Interrupt ACK incorrectly completed the attempt.")
            return
        }
        #expect(phaseRun == run)
        #expect(phaseCancellation == cancellation)
        try await admission.recordCanonicalTerminal(
            .interrupted(.server(message: "Stopped")),
            for: run
        )

        let resolution = try await interruption.value
        #expect(resolution == .init(
            run: run,
            cancellation: cancellation,
            terminal: .canonical(.interrupted(.requested(cancellation)))
        ))
        #expect(await admission.currentPhase() == .terminal(.active(resolution)))
    }

    @Test func terminalBeforeAcknowledgementDrainsTheSingleRequestOperation() async throws {
        let (admission, run) = try await makeActiveInterruptAdmission()
        let requestStarted = AsyncGate()
        let requestGate = AsyncGate()
        let requestFinished = InterruptInvocationCounter()
        let cancellation = ReviewCancellation.system(message: "Stop runtime")
        let receipt = ReviewCancellationRequestReceipt(
            id: .init(jobID: "job-1", ordinal: 1),
            cancellation: cancellation,
            rejectionDisposition: .preserveRuntimeStopIntent
        )

        let interruption = Task {
            try await admission.interrupt(
                run,
                cancellationRequest: receipt,
                request: { _, _ in
                    await requestStarted.open()
                    await requestGate.waitIgnoringCancellation()
                    await requestFinished.record()
                }
            )
        }
        await requestStarted.wait()
        try await admission.recordCanonicalTerminal(.completed, for: run)

        #expect(await admission.currentPhase() == .finishing(
            run: run,
            cancellation: cancellation,
            terminal: .canonical(.completed),
            request: .outcomeUnknown
        ))
        #expect(await requestFinished.count() == 0)

        await requestGate.open()
        let resolution = try await interruption.value

        #expect(await requestFinished.count() == 1)
        #expect(resolution.terminal == .canonical(.completed))
        #expect(resolution.cancellationRequestReceipt?.id == receipt.id)
    }

    @Test func joinedReportCallersUseLatestReceiptAndOneRequest() async throws {
        let (admission, run) = try await makeActiveInterruptAdmission()
        let requestStarted = AsyncGate()
        let requestGate = AsyncGate()
        let requestCount = InterruptInvocationCounter()
        let cancellation = ReviewCancellation.mcpClient(message: "Same cancellation")
        let firstReceipt = ReviewCancellationRequestReceipt(
            id: .init(jobID: "job-1", ordinal: 1),
            cancellation: cancellation,
            rejectionDisposition: .reportFailure
        )
        let successorReceipt = ReviewCancellationRequestReceipt(
            id: .init(jobID: "job-1", ordinal: 2),
            cancellation: cancellation,
            rejectionDisposition: .reportFailure
        )
        let rejection = ReviewInterruptRequestFailure(
            outcome: .rejected(code: nil, message: "Rejected")
        )

        let first = Task {
            try await admission.interrupt(
                run,
                cancellationRequest: firstReceipt,
                request: { _, _ in
                    await requestCount.record()
                    await requestStarted.open()
                    await requestGate.waitIgnoringCancellation()
                    throw rejection
                }
            )
        }
        await requestStarted.wait()
        let successor = Task {
            try await admission.interrupt(
                run,
                cancellationRequest: successorReceipt,
                request: { _, _ in
                    Issue.record("A joined report receipt dispatched a second request.")
                }
            )
        }
        for _ in 0..<1_000 {
            if await admission.cancellationRequestReceipt()?.id == successorReceipt.id {
                break
            }
            await Task.yield()
        }
        #expect(await admission.cancellationRequestReceipt()?.id == successorReceipt.id)
        await requestGate.open()

        await #expect(throws: rejection) { try await first.value }
        await #expect(throws: rejection) { try await successor.value }
        #expect(await requestCount.count() == 1)
        #expect(await admission.cancellationRequestReceipt() == nil)
    }

    @Test func explicitRejectionReturnsToActiveAndAllowsAReasonedRetry() async throws {
        let (admission, run) = try await makeActiveInterruptAdmission()
        let rejection = ReviewInterruptRequestFailure(
            outcome: .rejected(code: -32_000, message: "No active turn")
        )
        let firstReceipt = ReviewCancellationRequestReceipt(
            id: .init(jobID: "job-1", ordinal: 1),
            cancellation: .mcpClient(message: "First stop"),
            rejectionDisposition: .reportFailure
        )

        await #expect(throws: rejection) {
            try await admission.interrupt(
                run,
                cancellationRequest: firstReceipt,
                request: { _, _ in throw rejection }
            )
        }
        #expect(await admission.currentPhase() == .active(run))
        #expect(await admission.cancellationRequest() == nil)
        #expect(await admission.cancellationRequestReceipt() == nil)

        let retryStarted = AsyncGate()
        let retryCancellation = ReviewCancellation.system(message: "Retry stop")
        let retry = Task {
            try await admission.interrupt(
                run,
                cancellation: retryCancellation,
                request: { _, _ in await retryStarted.open() }
            )
        }
        await retryStarted.wait()
        try await admission.recordCanonicalTerminal(
            .interrupted(.server(message: "Stopped")),
            for: run
        )

        #expect(try await retry.value.terminal == .canonical(
            .interrupted(.requested(retryCancellation))
        ))
    }

    @Test func canonicalCompletionAndFailureOutrankAnAcceptedCancellation() async throws {
        let completed = try await resolveCanonicalTerminal(.completed)
        #expect(completed.terminal == .canonical(.completed))

        let failed = try await resolveCanonicalTerminal(.failed(message: "Review failed"))
        #expect(failed.terminal == .canonical(.failed(message: "Review failed")))
    }

    @Test func spontaneousInterruptionKeepsItsCanonicalCause() async throws {
        let (admission, run) = try await makeActiveInterruptAdmission()
        let terminal = ReviewTerminalRecord.interrupted(.server(message: "Server stopped"))

        try await admission.recordCanonicalTerminal(terminal, for: run)

        let resolution = try #require(await admission.activeTerminalResolution())
        #expect(resolution == .init(
            run: run,
            cancellation: nil,
            terminal: .canonical(terminal)
        ))
    }

    @Test func outcomeUnknownConnectionRetainsRequestAndTransportDiagnostics() async throws {
        let (admission, run) = try await makeActiveInterruptAdmission()
        let requestFailed = AsyncGate()
        let requestFailure = ReviewInterruptRequestFailure(
            outcome: .outcomeUnknown(message: "Interrupt response was lost")
        )
        let connection = ReviewRuntimeCloseFailure.connection("Transport closed")

        let interruption = Task {
            try await admission.interrupt(
                run,
                cancellation: .mcpClient(message: "Stop"),
                request: { _, _ in
                    await requestFailed.open()
                    throw requestFailure
                }
            )
        }
        await requestFailed.wait()
        try await admission.recordConnectionTerminal(connection, for: run)

        do {
            _ = try await interruption.value
            Issue.record("An outcome-unknown connection terminal was accepted as success.")
        } catch let received as ReviewInterruptRequestFailure {
            #expect(received.outcome == requestFailure.outcome)
            #expect(received.secondaryBarrierDiagnostic == connection.localizedDescription)
        }

        let resolution = try #require(await admission.activeTerminalResolution())
        #expect(resolution.terminal == .connection(connection))
        #expect(resolution.requestFailure?.outcome == requestFailure.outcome)
        #expect(
            resolution.requestFailure?.secondaryBarrierDiagnostic
                == connection.localizedDescription
        )
    }

    @Test func interruptRequestRequiresTheExactCanonicalRoutingPair() async throws {
        let admission = ReviewStartAdmission()
        try await admission.admitThreadStartDispatch()
        try await admission.recordPreparedThread(interruptProvisionalRun)
        try await admission.admitReviewStartDispatch(for: interruptProvisionalRun)
        var incompleteRun = interruptActiveRun
        incompleteRun.turnID = nil
        try await admission.recordActiveRun(incompleteRun)

        await #expect(throws: ReviewStartAdmissionContractFailure(
            violation: .interruptRequestRequiresCanonicalPair(incompleteRun)
        )) {
            try await admission.interrupt(
                incompleteRun,
                cancellation: .system(),
                request: { _, _ in
                    Issue.record("An incomplete canonical pair dispatched an interrupt.")
                }
            )
        }

        #expect(await admission.currentPhase() == .active(incompleteRun))
        #expect(await admission.cancellationRequest() == nil)
    }

    @Test func staleRunAndConflictingTerminalAreTypedContractFailures() async throws {
        let (admission, run) = try await makeActiveInterruptAdmission()
        var staleRun = run
        staleRun.turnID = "turn-stale"

        await #expect(throws: ReviewStartAdmissionContractFailure(
            violation: .staleRun(
                operation: .interruptActiveRun,
                expected: run,
                received: staleRun
            )
        )) {
            try await admission.interrupt(
                staleRun,
                cancellation: .system(),
                request: { _, _ in }
            )
        }
        await #expect(throws: ReviewStartAdmissionContractFailure(
            violation: .staleRun(
                operation: .recordCanonicalTerminal,
                expected: run,
                received: staleRun
            )
        )) {
            try await admission.recordCanonicalTerminal(.completed, for: staleRun)
        }
        await #expect(throws: ReviewStartAdmissionContractFailure(
            violation: .staleRun(
                operation: .inspectRecordedActiveTerminal,
                expected: run,
                received: staleRun
            )
        )) {
            try await admission.hasRecordedActiveTerminal(for: staleRun)
        }

        #expect(try await admission.hasRecordedActiveTerminal(for: run) == false)
        try await admission.recordCanonicalTerminal(.completed, for: run)
        #expect(try await admission.hasRecordedActiveTerminal(for: run))
        try await admission.recordCanonicalTerminal(.completed, for: run)
        await #expect(throws: ReviewStartAdmissionContractFailure(
            violation: .conflictingActiveTerminal(
                expected: .canonical(.completed),
                received: .canonical(.failed(message: "conflict"))
            )
        )) {
            try await admission.recordCanonicalTerminal(
                .failed(message: "conflict"),
                for: run
            )
        }
        #expect(await admission.activeTerminalResolution()?.terminal == .canonical(.completed))
    }

    private func resolveCanonicalTerminal(
        _ terminal: ReviewTerminalRecord
    ) async throws -> ReviewInterruptResolution {
        let (admission, run) = try await makeActiveInterruptAdmission()
        let requestStarted = AsyncGate()
        let interruption = Task {
            try await admission.interrupt(
                run,
                cancellation: .system(message: "Stop"),
                request: { _, _ in await requestStarted.open() }
            )
        }
        await requestStarted.wait()
        try await admission.recordCanonicalTerminal(terminal, for: run)
        return try await interruption.value
    }
}

private actor InterruptInvocationCounter {
    private var value = 0

    func record() {
        value += 1
    }

    func count() -> Int {
        value
    }
}

private func makeActiveInterruptAdmission() async throws -> (
    admission: ReviewStartAdmission,
    run: CodexReviewBackendModel.Review.Run
) {
    let admission = ReviewStartAdmission()
    try await admission.admitThreadStartDispatch()
    try await admission.recordPreparedThread(interruptProvisionalRun)
    try await admission.admitReviewStartDispatch(for: interruptProvisionalRun)
    try await admission.recordActiveRun(interruptActiveRun)
    return (admission, interruptActiveRun)
}

private let interruptProvisionalRun = CodexReviewBackendModel.Review.Run(
    attemptID: "interrupt-attempt",
    threadID: "interrupt-thread",
    reviewThreadID: "interrupt-thread",
    model: "gpt-5"
)

private let interruptActiveRun = CodexReviewBackendModel.Review.Run(
    attemptID: "interrupt-attempt",
    threadID: "interrupt-thread",
    turnID: "interrupt-turn",
    reviewThreadID: "interrupt-review-thread",
    model: "gpt-5"
)
