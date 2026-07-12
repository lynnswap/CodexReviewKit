import Testing
@testable import CodexReviewKit
import CodexReviewTesting

@Suite("Fake review backend attempt planning", .serialized)
struct FakeCodexReviewBackendAttemptTests {
    @Test func startRejectsMissingAttemptPlanAndConsumesEachPlanOnce() async throws {
        let request = try makeStartRequest(runID: "run-initial")
        let backend = FakeCodexReviewBackend()

        await #expect(throws: FakeCodexReviewBackendError.self) {
            _ = try await backend.startReview(request)
        }

        let attempt = makeReviewAttemptForTesting(
            attemptID: "attempt-initial",
            sourceThreadID: "thread-initial",
            activeTurnThreadID: "review-thread-initial",
            turnID: "turn-initial"
        )
        await backend.planNextAttempt(attempt)
        let started = try await backend.startReview(request)
        #expect(started.attempt == attempt)

        await #expect(throws: FakeCodexReviewBackendError.self) {
            _ = try await backend.startReview(try makeStartRequest(runID: "run-unplanned"))
        }
        await backend.finishEventMailboxes()
    }

    @Test func restartRejectsMissingAttemptPlanWithoutFabricatingIdentity() async throws {
        let initialAttempt = makeReviewAttemptForTesting(
            attemptID: "attempt-initial",
            sourceThreadID: "thread-initial",
            activeTurnThreadID: "review-thread-initial",
            turnID: "turn-initial"
        )
        let recoveredAttempt = makeReviewAttemptForTesting(
            attemptID: "attempt-recovered",
            sourceThreadID: "thread-initial",
            activeTurnThreadID: "review-thread-initial",
            turnID: "turn-recovered"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: initialAttempt)
        let request = try makeStartRequest(runID: "run-restart")
        let started = try await backend.startReview(request)
        let token = try await backend.prepareReviewRestart(started.attempt)

        await #expect(throws: FakeCodexReviewBackendError.self) {
            _ = try await backend.restartPreparedReview(token, request: request)
        }

        await backend.planNextRecoveredAttempt(recoveredAttempt)
        let restarted = try await backend.restartPreparedReview(token, request: request)
        #expect(restarted.attempt == recoveredAttempt)
        await backend.finishEventMailboxes()
    }

    @Test func cancelledStartGateDoesNotConsumeItsAttemptPlan() async throws {
        let attempt = makeReviewAttemptForTesting(
            attemptID: "attempt-retry",
            sourceThreadID: "thread-retry",
            activeTurnThreadID: "review-thread-retry",
            turnID: "turn-retry"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let gate = AsyncGate()
        await backend.holdStartReview(with: gate)
        let request = try makeStartRequest(runID: "run-retry")
        let cancelledStart = Task {
            try await backend.startReview(request)
        }
        try await backend.waitForStartReview(timeout: .seconds(2))

        cancelledStart.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelledStart.value
        }

        await gate.open()
        let retried = try await backend.startReview(request)
        #expect(retried.attempt == attempt)
        await backend.finishEventMailboxes()
    }
}

private func makeStartRequest(
    runID: String
) throws -> CodexReviewBackendModel.Review.Start {
    try .init(
        runID: ReviewRunID(validating: runID),
        sessionID: "session-attempt-planning",
        request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
    )
}
