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

        await session.receive([
            .started(turnID: "turn-1", reviewThreadID: "review-thread", model: "gpt-5"),
            .completed(summary: "Succeeded.", result: "Looks good."),
        ], controlThreadID: "review-thread")

        #expect(try await nextEvent(from: attempt.events) == .started(
            turnID: "turn-1",
            reviewThreadID: "review-thread",
            model: "gpt-5"
        ))
        #expect(try await nextEvent(from: attempt.events) == .completed(
            summary: "Succeeded.",
            result: "Looks good."
        ))
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

    @Test func coalescesStreamedLogEntriesWithoutDelayingDomainEvents() async throws {
        let session = ReviewBackendEventSession(run: makeRun())
        let attempt = await session.attempt()

        await session.receive([
            commandDomainEvent(output: "first"),
            commandOutputDeltaLogEntry(text: "first"),
        ], controlThreadID: "review-thread")
        await session.receive([
            commandDomainEvent(output: "firstsecond"),
            commandOutputDeltaLogEntry(text: "second"),
        ], controlThreadID: "review-thread")
        await session.finish(throwing: nil)

        guard case .domainEvents(let firstDomainEvents, _) = try await nextEvent(from: attempt.events),
              case .itemUpdated(let firstSeed) = try #require(firstDomainEvents.first),
              case .command(let firstCommand) = firstSeed.content
        else {
            Issue.record("expected first domain event")
            return
        }
        #expect(firstCommand.output == "first")

        guard case .domainEvents(let secondDomainEvents, _) = try await nextEvent(from: attempt.events),
              case .itemUpdated(let secondSeed) = try #require(secondDomainEvents.first),
              case .command(let secondCommand) = secondSeed.content
        else {
            Issue.record("expected second domain event")
            return
        }
        #expect(secondCommand.output == "firstsecond")

        #expect(try await nextEvent(from: attempt.events) == .logEntry(
            kind: .commandOutput,
            text: "firstsecond",
            groupID: "cmd-1",
            replacesGroup: false,
            metadata: commandOutputMetadata()
        ))
        #expect(try await nextEvent(from: attempt.events) == nil)
    }

    @Test func fillsCompletionResultFromStreamedMessageText() async throws {
        let session = ReviewBackendEventSession(run: makeRun())
        let attempt = await session.attempt()

        await session.receive([.messageDelta("Looks ", itemID: "msg-1")])
        await session.receive([.messageDelta("good.", itemID: "msg-1")])
        await session.receive([.completed(summary: "Succeeded.", result: nil)])

        #expect(try await nextEvent(from: attempt.events) == .messageDelta("Looks ", itemID: "msg-1"))
        #expect(try await nextEvent(from: attempt.events) == .messageDelta("good.", itemID: "msg-1"))
        #expect(try await nextEvent(from: attempt.events) == .completed(
            summary: "Succeeded.",
            result: "Looks good."
        ))
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

private func commandDomainEvent(output: String) -> CodexReviewBackendModel.Review.Event {
    .domainEvents([
        .itemUpdated(.init(
            id: "cmd-1",
            kind: .commandExecution,
            family: .command,
            phase: .running,
            content: .command(.init(command: "swift test", output: output))
        )),
    ], logProjectionSuppressionCount: 1)
}

private func commandOutputDeltaLogEntry(text: String) -> CodexReviewBackendModel.Review.Event {
    .logEntry(
        kind: .commandOutput,
        text: text,
        groupID: "cmd-1",
        replacesGroup: false,
        metadata: commandOutputMetadata()
    )
}

private func commandOutputMetadata() -> ReviewLogEntry.Metadata {
    .init(
        sourceType: "commandExecution",
        title: "Command output",
        itemID: "cmd-1"
    )
}
