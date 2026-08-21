import Foundation
import Testing
@testable import CodexReview

@Suite("review start admission")
struct ReviewStartAdmissionTests {
    @Test func cancellationBeforeThreadDispatchRejectsTheWriteWithTheOriginalReason() async throws {
        let admission = ReviewStartAdmission()
        let cancellation = ReviewCancellation.mcpClient(message: "Stop before start")

        await admission.recordCancellation(cancellation)

        await #expect(throws: ReviewStartCancelledBeforeDispatch(cancellation: cancellation)) {
            try await admission.admitThreadStartDispatch()
        }
        #expect(await admission.currentPhase() == .terminal(.cancelledBeforeDispatch(cancellation)))
    }

    @Test func dispatchedThreadRequestRemainsOutcomeUnknownUntilExplicitlyResolved() async throws {
        let admission = ReviewStartAdmission()

        try await admission.admitThreadStartDispatch()
        await #expect(throws: ReviewStartAdmissionContractFailure.self) {
            try await admission.recordThreadStartRejectedForRetry(
                .outcomeUnknown(message: "Connection ended before a response")
            )
        }

        #expect(await admission.currentPhase() == .preparingThread(.outcomeUnknown))
    }

    @Test func explicitThreadStartRejectionAllowsExactlyOneRetryDispatch() async throws {
        let admission = ReviewStartAdmission()

        try await admission.admitThreadStartDispatch()
        try await admission.recordThreadStartRejectedForRetry(
            .rejected(code: -32602, message: "Unsupported permissions")
        )
        #expect(await admission.currentPhase() == .preparingThread(.notSent))
        try await admission.admitThreadStartDispatch()

        await #expect(throws: ReviewStartAdmissionContractFailure.self) {
            try await admission.admitThreadStartDispatch()
        }
        #expect(await admission.currentPhase() == .preparingThread(.outcomeUnknown))
    }

    @Test func finalExplicitThreadStartRejectionIsTerminal() async throws {
        let admission = ReviewStartAdmission()
        let failure = ReviewStartRequestFailure.rejected(
            code: -32602,
            message: "Invalid request"
        )
        try await admission.admitThreadStartDispatch()

        try await admission.recordThreadStartRejected(failure)

        #expect(await admission.currentPhase() == .terminal(.rejected(failure)))
    }

    @Test func cancellationAfterThreadDispatchRejectsReviewDispatchAfterTheResponse() async throws {
        let admission = ReviewStartAdmission()
        let cancellation = ReviewCancellation.system(message: "Runtime stopped")

        try await admission.admitThreadStartDispatch()
        await admission.recordCancellation(cancellation)
        #expect(await admission.currentPhase() == .preparingThread(.outcomeUnknown))
        try await admission.recordPreparedThread(provisionalRun)

        await #expect(throws: ReviewStartCancelledBeforeDispatch(cancellation: cancellation)) {
            try await admission.admitReviewStartDispatch(for: provisionalRun)
        }
        #expect(await admission.currentPhase() == .terminal(.cancelledBeforeDispatch(cancellation)))
    }

    @Test func stalePreparedRunCannotAdmitReviewDispatch() async throws {
        let admission = ReviewStartAdmission()
        try await admission.admitThreadStartDispatch()
        try await admission.recordPreparedThread(provisionalRun)
        var staleRun = provisionalRun
        staleRun.attemptID = "attempt-stale"

        do {
            try await admission.admitReviewStartDispatch(for: staleRun)
            Issue.record("A stale provisional run admitted review/start.")
        } catch let failure as ReviewStartAdmissionContractFailure {
            #expect(failure.violation == .staleRun(
                operation: .admitReviewStartDispatch,
                expected: provisionalRun,
                received: staleRun
            ))
        }

        #expect(await admission.currentPhase() == .startingReview(
            preparedRun: provisionalRun,
            dispatch: .notSent
        ))
    }

    @Test func activeRunRequiresThePreparedIdentityAndExactDuplicateIsIdempotent() async throws {
        let admission = ReviewStartAdmission()
        try await admission.admitThreadStartDispatch()
        try await admission.recordPreparedThread(provisionalRun)
        try await admission.admitReviewStartDispatch(for: provisionalRun)
        var staleRun = activeRun
        staleRun.attemptID = "attempt-stale"

        await #expect(throws: ReviewStartAdmissionContractFailure.self) {
            try await admission.recordActiveRun(staleRun)
        }
        try await admission.recordActiveRun(activeRun)
        try await admission.recordActiveRun(activeRun)

        #expect(await admission.currentPhase() == .active(activeRun))
    }

    @Test func connectionFailureTerminatesAnOutcomeUnknownStartup() async throws {
        let admission = ReviewStartAdmission()
        let failure = ReviewRuntimeCloseFailure.connection("Process exited")
        try await admission.admitThreadStartDispatch()

        try await admission.recordConnectionTerminal(failure)
        try await admission.recordConnectionTerminal(.connection("Transport closed"))

        #expect(await admission.currentPhase() == .terminal(.connection(failure)))
    }

    @Test func delayedCancellationAndRejectionCannotReplaceAConnectionTerminal() async throws {
        let admission = ReviewStartAdmission()
        let connection = ReviewRuntimeCloseFailure.connection("Transport closed")
        try await admission.admitThreadStartDispatch()
        try await admission.recordConnectionTerminal(connection)

        await admission.recordCancellation(.system(message: "Stop"))
        try await admission.recordThreadStartRejected(
            .rejected(code: -32602, message: "Late rejection")
        )

        #expect(await admission.currentPhase() == .terminal(.connection(connection)))
        await #expect(throws: ReviewStartAdmissionContractFailure.self) {
            try await admission.recordThreadStartRejectedForRetry(
                .rejected(code: -32602, message: "Late retry")
            )
        }
        #expect(await admission.currentPhase() == .terminal(.connection(connection)))
    }

    @Test func cleanupFailureCannotMasqueradeAsAConnectionTerminal() async throws {
        let admission = ReviewStartAdmission()
        try await admission.admitThreadStartDispatch()

        await #expect(throws: ReviewStartAdmissionContractFailure(
            violation: .connectionTerminalRequiresConnectionFailure(.cleanup("Cleanup failed"))
        )) {
            try await admission.recordConnectionTerminal(.cleanup("Cleanup failed"))
        }

        #expect(await admission.currentPhase() == .preparingThread(.outcomeUnknown))
    }

    @Test func failedStartDispositionAtomicallyCombinesOwnershipAndCurrentPhase() async throws {
        let shared = ReviewStartAdmission()
        try await shared.admitThreadStartDispatch()
        try await shared.recordPreparedThread(provisionalRun)
        try await shared.admitReviewStartDispatch(for: provisionalRun)
        #expect(await shared.failedReviewStartDisposition(for: provisionalRun) == .preserveOutcomeUnknown)

        try await shared.recordConnectionTerminal(.connection("Connection ended"))
        #expect(await shared.failedReviewStartDisposition(for: provisionalRun) == .cleanup)

        let compatibility = ReviewStartAdmission.compatibility()
        try await compatibility.admitThreadStartDispatch()
        try await compatibility.recordPreparedThread(provisionalRun)
        try await compatibility.admitReviewStartDispatch(for: provisionalRun)
        #expect(await compatibility.failedReviewStartDisposition(for: provisionalRun) == .cleanup)
    }
}

private let provisionalRun = CodexReviewBackendModel.Review.Run(
    attemptID: "attempt-1",
    threadID: "thread-1",
    reviewThreadID: "thread-1",
    model: "gpt-5"
)

private let activeRun = CodexReviewBackendModel.Review.Run(
    attemptID: "attempt-1",
    threadID: "thread-1",
    turnID: "turn-1",
    reviewThreadID: "review-thread-1",
    model: "gpt-5"
)
