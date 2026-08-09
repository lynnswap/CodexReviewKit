import Foundation
import Testing

@testable import CodexAppServerKit

@Suite("Turn replay core")
struct TurnReplayCoreTests {
    @Test func pendingTokensAreUniqueAndOperationKindsPreserveRoutingIdentity() {
        let first = TurnReplayPendingToken()
        let second = TurnReplayPendingToken()

        #expect(first != second)
        #expect(
            TurnReplayPendingOperationKind.turn(threadID: "thread-1") ==
                .turn(threadID: "thread-1")
        )
        #expect(
            TurnReplayPendingOperationKind.review(
                sourceThreadID: "thread-1",
                delivery: .detached
            ) == .review(sourceThreadID: "thread-1", delivery: .detached)
        )
    }

    @Test func compactSnapshotReplaysFinalSnapshotThenTerminal() {
        let compact = makeCompactSnapshot()

        #expect(compact.replayEvents == [
            .snapshot(compact.snapshot),
            .terminal(compact.outcome),
        ])
    }

    @Test func twoHundredFiftySeventhIncrementalAtomicallyCompactsToCurrentSnapshot() async throws {
        let relay = TurnReplayRelay()
        let events = relay.events()
        var iterator = events.makeAsyncIterator()
        let snapshot = CodexTurnSnapshot(
            id: "turn-1",
            state: .inProgress,
            items: [makeItem(id: "item-current")]
        )

        for index in 0..<256 {
            #expect(relay.yield(
                .unknown(.init(method: "event/\(index)", params: Data())),
                accumulatedSnapshot: snapshot
            ) == 0)
        }
        #expect(relay.yield(
            .unknown(.init(method: "event/256", params: Data())),
            accumulatedSnapshot: snapshot
        ) == 1)
        relay.yield(.started("turn-1"), accumulatedSnapshot: snapshot)

        #expect(try await iterator.next() == .snapshot(snapshot))
        #expect(try await iterator.next() == .started("turn-1"))
        events.cancel()
    }

    @Test func secondOverflowSupersedesEarlierSnapshotAndSuffix() async throws {
        let relay = TurnReplayRelay()
        let events = relay.events()
        var iterator = events.makeAsyncIterator()
        let firstSnapshot = CodexTurnSnapshot(id: "turn-1", state: .inProgress)
        let secondSnapshot = CodexTurnSnapshot(
            id: "turn-1",
            state: .inProgress,
            items: [makeItem(id: "newest")]
        )

        for index in 0..<257 {
            _ = relay.yield(
                .unknown(.init(method: "first/\(index)", params: Data())),
                accumulatedSnapshot: firstSnapshot
            )
        }
        for index in 0..<257 {
            _ = relay.yield(
                .unknown(.init(method: "second/\(index)", params: Data())),
                accumulatedSnapshot: secondSnapshot
            )
        }

        #expect(try await iterator.next() == .snapshot(secondSnapshot))
        events.cancel()
    }

    @Test func terminalUsesReservedSlotAndSupersedesPendingIncrementals() async throws {
        let relay = TurnReplayRelay()
        let events = relay.events()
        var iterator = events.makeAsyncIterator()
        let compact = makeCompactSnapshot()

        for index in 0..<32 {
            relay.yield(
                .unknown(.init(method: "event/\(index)", params: Data())),
                accumulatedSnapshot: compact.snapshot
            )
        }
        relay.finish(with: compact)

        #expect(try await iterator.next() == .snapshot(compact.snapshot))
        #expect(try await iterator.next() == .terminal(compact.outcome))
        #expect(try await iterator.next() == nil)
    }

    @Test func lateSequencesReplayOnlyCompactTerminalState() async throws {
        let compact = makeCompactSnapshot()
        let events = TurnReplayEvents.replaying(compact)
        let progress = TurnReplayProgressEvents.replaying(compact)
        var eventIterator = events.makeAsyncIterator()
        var progressIterator = progress.makeAsyncIterator()

        #expect(try await eventIterator.next() == .snapshot(compact.snapshot))
        #expect(try await eventIterator.next() == .terminal(compact.outcome))
        #expect(try await eventIterator.next() == nil)
        #expect(try await progressIterator.next() == .terminal(compact.outcome))
        #expect(try await progressIterator.next() == nil)
    }

    @Test func fastSubscriberDoesNotWaitForSlowSubscriberCompaction() async throws {
        let relay = TurnReplayRelay()
        let fastEvents = relay.events()
        let slowEvents = relay.events()
        var fastIterator = fastEvents.makeAsyncIterator()
        var slowIterator = slowEvents.makeAsyncIterator()
        let snapshot = CodexTurnSnapshot(id: "turn-1", state: .inProgress)

        for index in 0..<257 {
            let event = CodexTurnEvent.unknown(.init(
                method: "event/\(index)",
                params: Data()
            ))
            _ = relay.yield(event, accumulatedSnapshot: snapshot)
            #expect(try await fastIterator.next() == event)
        }

        #expect(try await slowIterator.next() == .snapshot(snapshot))
        fastEvents.cancel()
        slowEvents.cancel()
    }

    @Test func eventSeedAndPublicationAreAtomicWithConcurrentYield() async throws {
        let relay = TurnReplayRelay()
        let publicationEntered = DispatchSemaphore(value: 0)
        let releasePublication = DispatchSemaphore(value: 0)
        let producerStarted = DispatchSemaphore(value: 0)
        let snapshot = CodexTurnSnapshot(id: "turn-1", state: .inProgress)
        let event = CodexTurnEvent.started("turn-1")
        let subscription = Task {
            await performOnGlobalQueue {
                relay.eventsForTesting(initialSnapshot: snapshot) {
                    publicationEntered.signal()
                    releasePublication.wait()
                }
            }
        }
        await waitForSemaphore(publicationEntered)
        let producer = Task {
            await performOnGlobalQueue {
                producerStarted.signal()
                return relay.yield(event, accumulatedSnapshot: snapshot)
            }
        }
        await waitForSemaphore(producerStarted)
        releasePublication.signal()

        let events = await subscription.value
        _ = await producer.value
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .snapshot(snapshot))
        #expect(try await iterator.next() == event)
        events.cancel()
    }

    @Test func snapshotDoesNotWaitForBlockedInitialPublication() async throws {
        let relay = TurnReplayRelay()
        let publicationEntered = DispatchSemaphore(value: 0)
        let releasePublication = DispatchSemaphore(value: 0)
        let snapshotCompleted = DispatchSemaphore(value: 0)
        let snapshot = CodexTurnSnapshot(id: "turn-1", state: .inProgress)
        let subscription = Task {
            await performOnGlobalQueue {
                relay.eventsForTesting(initialSnapshot: snapshot) {
                    publicationEntered.signal()
                    releasePublication.wait()
                }
            }
        }
        defer { releasePublication.signal() }
        let publicationDidEnter = await performOnGlobalQueue {
            publicationEntered.wait(timeout: .now() + 5) == .success
        }
        try #require(publicationDidEnter)

        let snapshotTask = Task.detached {
            let captured = relay.snapshotForTesting()
            snapshotCompleted.signal()
            return captured
        }
        let completedWhilePublicationWasBlocked = await performOnGlobalQueue {
            snapshotCompleted.wait(timeout: .now() + 5) == .success
        }
        releasePublication.signal()

        let events = await subscription.value
        let captured = await snapshotTask.value
        #expect(completedWhilePublicationWasBlocked)
        #expect(captured == .init(subscriberCount: 0, overflowCount: 0, isFinished: false))
        events.cancel()
    }

    @Test func progressKeepsNewestRunningValueAndReservedTerminal() async throws {
        let relay = TurnReplayRelay()
        let events = relay.progressEvents()
        var iterator = events.makeAsyncIterator()
        let older = CodexReviewProgress.running(
            transcript: .init(items: [makeItem(id: "older")]),
            usage: nil
        )
        let newest = CodexReviewProgress.running(
            transcript: .init(items: [makeItem(id: "newest")]),
            usage: nil
        )
        let compact = makeCompactSnapshot()

        relay.yieldProgress(older)
        relay.yieldProgress(newest)
        relay.finish(with: compact)

        #expect(try await iterator.next() == newest)
        #expect(try await iterator.next() == .terminal(compact.outcome))
        #expect(try await iterator.next() == nil)
    }

    @Test func progressSeedAndPublicationAreAtomicWithConcurrentYield() async throws {
        let relay = TurnReplayRelay()
        let publicationEntered = DispatchSemaphore(value: 0)
        let releasePublication = DispatchSemaphore(value: 0)
        let producerStarted = DispatchSemaphore(value: 0)
        let initial = CodexReviewProgress.running(transcript: .init(), usage: nil)
        let newest = CodexReviewProgress.running(
            transcript: .init(items: [makeItem(id: "newest")]),
            usage: nil
        )
        let subscription = Task {
            await performOnGlobalQueue {
                relay.progressEventsForTesting(initialProgress: initial) {
                    publicationEntered.signal()
                    releasePublication.wait()
                }
            }
        }
        await waitForSemaphore(publicationEntered)
        let producer = Task {
            await performOnGlobalQueue {
                producerStarted.signal()
                relay.yieldProgress(newest)
            }
        }
        await waitForSemaphore(producerStarted)
        releasePublication.signal()

        let events = await subscription.value
        _ = await producer.value
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == newest)
        events.cancel()
    }

    @Test func explicitCancellationSynchronouslyRemovesOnlyThatSubscriber() async throws {
        let relay = TurnReplayRelay()
        let cancelled = relay.events()
        let retained = relay.events()
        var cancelledIterator = cancelled.makeAsyncIterator()

        #expect(relay.snapshotForTesting().subscriberCount == 2)
        cancelled.cancel()
        #expect(relay.snapshotForTesting().subscriberCount == 1)
        #expect(try await cancelledIterator.next() == nil)
        #expect(relay.snapshotForTesting().subscriberCount == 1)
        retained.cancel()
        #expect(relay.snapshotForTesting().subscriberCount == 0)
    }

    @Test func connectionFailureTerminatesEventAndProgressSubscribersWithTypedError() async {
        let relay = TurnReplayRelay()
        let events = relay.events()
        let progress = relay.progressEvents()
        var eventIterator = events.makeAsyncIterator()
        var progressIterator = progress.makeAsyncIterator()
        let failure = CodexAppServerError.connectionTerminated(
            .transportFailure(.io(errno: 5, message: "read failed"))
        )

        relay.finish(throwing: failure)

        do {
            _ = try await eventIterator.next()
            Issue.record("Expected the event subscriber to fail.")
        } catch let error as CodexAppServerError {
            #expect(error == failure)
        } catch {
            Issue.record("Unexpected event error: \(error)")
        }

        do {
            _ = try await progressIterator.next()
            Issue.record("Expected the progress subscriber to fail.")
        } catch let error as CodexAppServerError {
            #expect(error == failure)
        } catch {
            Issue.record("Unexpected progress error: \(error)")
        }
    }

    private func makeCompactSnapshot() -> CompactTurnSnapshot {
        let response = CodexResponse(
            turnID: "turn-1",
            transcript: .init(items: [makeItem(id: "terminal")])
        )
        return .init(
            snapshot: .init(
                id: "turn-1",
                state: .completed,
                items: response.transcript.items
            ),
            outcome: .completed(response)
        )
    }

    private func makeItem(id: String) -> CodexThreadItem {
        .init(
            id: id,
            kind: .agentMessage,
            content: .message(.init(id: id, role: .assistant, text: id))
        )
    }
}

private func waitForSemaphore(_ semaphore: DispatchSemaphore) async {
    await performOnGlobalQueue {
        semaphore.wait()
    }
}

private func performOnGlobalQueue<Result: Sendable>(
    _ operation: @escaping @Sendable () -> Result
) async -> Result {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: operation())
        }
    }
}
