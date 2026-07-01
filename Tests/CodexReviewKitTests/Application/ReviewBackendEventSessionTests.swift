import Foundation
import Testing
@testable import CodexReviewKit

@Suite("review backend event session")
struct ReviewBackendEventSessionTests {
    @Test func emitsEventsAndRecordsLifecycleCallbacks() async throws {
        let recorder = ReviewBackendEventSessionRecorder()
        let session = ReviewBackendEventSession(
            run: makeRun(),
            callbacks: .init(
                recordTurnStarted: { turnID in
                    await recorder.recordTurnStarted(turnID)
                },
                recordFinished: { run, metrics in
                    await recorder.recordFinished(run: run, metrics: metrics)
                }
            )
        )
        let attempt = await session.attempt()

        await session.receive(
            [
                .started(turnID: "turn-1", reviewThreadID: "review-thread", model: "gpt-5"),
                .completed(finalReview: "No issues found."),
            ], controlThreadID: "review-thread")

        #expect(
            try await nextEvent(from: attempt.events)
                == .started(
                    turnID: "turn-1",
                    reviewThreadID: "review-thread",
                    model: "gpt-5"
                ))
        #expect(
            try await nextEvent(from: attempt.events)
                == .completed(finalReview: "No issues found."))
        #expect(await recorder.startedTurnIDs() == ["turn-1"])
        #expect(await recorder.finishedRun() == makeRun())

        let metrics = await session.metricsSnapshot()
        #expect(metrics.routed == 1)
        #expect(metrics.decoded == 1)
        #expect(metrics.emitted == 2)
        #expect(metrics.ignored == 0)
        #expect(metrics.firstEventLatencyMs != nil)
        #expect(metrics.terminalLatencyMs != nil)
        #expect(await recorder.finishedMetrics() == metrics)
    }
}

private actor ReviewBackendEventSessionRecorder {
    private var turnIDs: [String] = []
    private var completedRun: CodexReviewBackendModel.Review.Run?
    private var completedMetrics: ReviewBackendEventSessionMetrics?

    func recordTurnStarted(_ turnID: String) {
        turnIDs.append(turnID)
    }

    func recordFinished(
        run: CodexReviewBackendModel.Review.Run,
        metrics: ReviewBackendEventSessionMetrics
    ) {
        completedRun = run
        completedMetrics = metrics
    }

    func startedTurnIDs() -> [String] {
        turnIDs
    }

    func finishedRun() -> CodexReviewBackendModel.Review.Run? {
        completedRun
    }

    func finishedMetrics() -> ReviewBackendEventSessionMetrics? {
        completedMetrics
    }
}

private enum ReviewBackendEventSessionTestTimeout: Error {
    case timedOut
}

private func nextEvent(
    from mailbox: BackendReviewEventMailbox,
    timeout: Duration = .seconds(1)
) async throws -> CodexReviewBackendModel.Review.Event? {
    try await withThrowingTaskGroup(of: CodexReviewBackendModel.Review.Event?.self) { group in
        group.addTask {
            try await mailbox.next()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ReviewBackendEventSessionTestTimeout.timedOut
        }
        let event = try await group.next()
        group.cancelAll()
        return event ?? nil
    }
}

private func makeRun() -> CodexReviewBackendModel.Review.Run {
    .init(
        attemptID: "attempt-1",
        threadID: "thread-1",
        turnID: "turn-1",
        reviewThreadID: "review-thread",
        model: "gpt-5"
    )
}
