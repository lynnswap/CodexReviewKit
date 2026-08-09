import Foundation
import Testing

@testable import CodexAppServerKit

@Suite("Thread event hub")
struct ThreadEventHubTests {
    @Test func adoptedGenerationDoesNotClaimIdentityOnlySnapshotCompleteness() async throws {
        let hub = ThreadEventHub()

        hub.beginGeneration(for: "thread-1", including: "turn-1")

        var iterator = hub.events(for: "thread-1").makeAsyncIterator()
        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-1",
            state: .inProgress,
            itemsLoadState: .notLoaded
        )))
    }

    @Test func seededCurrentSnapshotKeepsLaterItemUpdatesAsLiveEvents() async throws {
        let hub = ThreadEventHub()
        let initial = messageItem(id: "message", text: "Initial")
        let updated = messageItem(id: "message", text: "Updated")
        let events = hub.events(for: "thread-1")
        var iterator = events.makeAsyncIterator()

        hub.seedCurrentTurnSnapshot(.init(
            id: "turn-1",
            state: .completed,
            itemsLoadState: .full,
            items: [initial]
        ), for: "thread-1")
        try hub.route(
            .itemCompleted(updated, turnID: "turn-1"),
            for: "thread-1"
        )

        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-1",
            state: .completed,
            itemsLoadState: .full,
            items: [initial]
        )))
        #expect(try await iterator.next() == .itemCompleted(updated, turnID: "turn-1"))
        events.cancel()
    }

    @Test func historicalSnapshotYieldsToADifferentObservedTurn() async throws {
        let hub = ThreadEventHub()
        let historical = messageItem(id: "historical", text: "Historical")
        let live = messageItem(id: "live", text: "Live")
        let events = hub.events(for: "thread-1")
        var iterator = events.makeAsyncIterator()

        hub.seedCurrentTurnSnapshot(.init(
            id: "turn-history",
            state: .inProgress,
            itemsLoadState: .full,
            items: [historical]
        ), for: "thread-1")
        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-history",
            state: .inProgress,
            itemsLoadState: .full,
            items: [historical]
        )))

        try hub.route(.itemStarted(live, turnID: "turn-live"), for: "thread-1")

        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-live",
            state: .inProgress,
            itemsLoadState: .notLoaded,
            items: [live]
        )))
        events.cancel()
    }

    @Test func newerHistoricalSnapshotReplacesThePriorHistoricalGeneration() async throws {
        let hub = ThreadEventHub()
        let first = messageItem(id: "first", text: "First")
        let second = messageItem(id: "second", text: "Second")
        let events = hub.events(for: "thread-1")
        var iterator = events.makeAsyncIterator()

        hub.seedCurrentTurnSnapshot(.init(
            id: "turn-1",
            state: .inProgress,
            itemsLoadState: .full,
            items: [first]
        ), for: "thread-1")
        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-1",
            state: .inProgress,
            itemsLoadState: .full,
            items: [first]
        )))

        hub.seedCurrentTurnSnapshot(.init(
            id: "turn-2",
            state: .inProgress,
            itemsLoadState: .full,
            items: [second]
        ), for: "thread-1")

        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-2",
            state: .inProgress,
            itemsLoadState: .full,
            items: [second]
        )))
        events.cancel()
    }

    @Test func reviewStartDispositionKeepsDetachedSourceEventsOnTheirSource() throws {
        let hub = ThreadEventHub()
        let review = try hub.registerCheckpoint(
            for: "thread-source",
            operation: .reviewStart(delivery: .detached)
        )
        let resume = try hub.registerCheckpoint(for: "thread-resume")

        hub.activate(review)
        hub.activate(resume)

        #expect(hub.turnStartDisposition(for: "thread-source") == .route)
        #expect(hub.turnStartDisposition(for: "thread-detached") == .deferUntilOwned)
        #expect(hub.turnStartDisposition(for: "thread-resume") == .route)

        hub.discard(review)
        hub.discard(resume)
    }

    @Test func detachedReviewResponseMovesTheCheckpointWithoutResettingItsSourceThread() async throws {
        let hub = ThreadEventHub()
        hub.beginGeneration(for: "thread-source", including: "turn-source")
        let sourceEvents = hub.events(for: "thread-source")
        var sourceIterator = sourceEvents.makeAsyncIterator()
        let checkpoint = try hub.registerCheckpoint(
            for: "thread-source",
            operation: .reviewStart(delivery: .detached)
        )
        hub.activate(checkpoint)
        try hub.route(
            .statusChanged(.active(activeFlags: [.waitingOnApproval])),
            for: "thread-source"
        )

        try hub.resolveReviewStart(
            checkpoint,
            eventThreadID: "thread-review",
            responseSnapshot: .init(id: "turn-review", state: .inProgress)
        )

        let source = hub.snapshotForTesting(threadID: "thread-source")
        #expect(source.currentTurnID == "turn-source")
        #expect(source.hasActiveCheckpoint == false)
        let review = hub.snapshotForTesting(threadID: "thread-review")
        #expect(review.currentTurnID == "turn-review")
        #expect(review.hasActiveCheckpoint == false)
        #expect(review.pendingCheckpointCount == 0)
        #expect(try await sourceIterator.next() == .snapshot(.init(
            id: "turn-source",
            state: .inProgress,
            itemsLoadState: .notLoaded
        )))
        #expect(try await sourceIterator.next() == .statusChanged(
            .active(activeFlags: [.waitingOnApproval])
        ))
        sourceEvents.cancel()
    }

    @Test func detachedReviewResponseRequiresAPreviouslyUnseenEventThread() throws {
        let hub = ThreadEventHub()
        hub.beginGeneration(for: "thread-review", including: "turn-existing")
        let checkpoint = try hub.registerCheckpoint(
            for: "thread-source",
            operation: .reviewStart(delivery: .detached)
        )
        hub.activate(checkpoint)

        #expect(throws: CodexTransportFailure.contractViolation(
            message: "A detached review must use a previously unseen event thread."
        )) {
            try hub.resolveReviewStart(
                checkpoint,
                eventThreadID: "thread-review",
                responseSnapshot: .init(id: "turn-review", state: .inProgress)
            )
        }
        #expect(hub.snapshotForTesting(threadID: "thread-review").currentTurnID == "turn-existing")
        #expect(hub.snapshotForTesting(threadID: "thread-source").hasActiveCheckpoint)

        hub.discard(checkpoint)
    }

    @Test func concurrentDetachedReviewResponsesCannotClaimTheSameEventThread() throws {
        let hub = ThreadEventHub()
        let first = try hub.registerCheckpoint(
            for: "thread-source-first",
            operation: .reviewStart(delivery: .detached)
        )
        let second = try hub.registerCheckpoint(
            for: "thread-source-second",
            operation: .reviewStart(delivery: .detached)
        )
        hub.activate(first)
        hub.activate(second)

        try hub.resolveReviewStart(
            second,
            eventThreadID: "thread-review",
            responseSnapshot: .init(id: "turn-second", state: .inProgress)
        )
        #expect(throws: CodexTransportFailure.contractViolation(
            message: "A detached review must use a previously unseen event thread."
        )) {
            try hub.resolveReviewStart(
                first,
                eventThreadID: "thread-review",
                responseSnapshot: .init(id: "turn-first", state: .inProgress)
            )
        }
        #expect(hub.snapshotForTesting(threadID: "thread-review").currentTurnID == "turn-second")

        hub.discard(first)
    }

    @Test func laterPublicationCompactsAcrossAnOvertakenGenerationCommit() async throws {
        let hub = ThreadEventHub()
        let events = hub.events(for: "thread-1")
        var iterator = events.makeAsyncIterator()
        let checkpoint = try hub.registerCheckpoint(for: "thread-1")
        hub.activate(checkpoint)
        try hub.route(.turnStarted("turn-1"), for: "thread-1")
        let gate = PublicationGate()

        let commit = Task.detached {
            hub.commitForTesting(checkpoint) {
                gate.blockPublication()
            }
        }
        #expect(gate.waitUntilBlocked())
        try hub.route(.statusChanged(.active(activeFlags: [])), for: "thread-1")
        gate.releasePublication()
        await commit.value

        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-1",
            state: .inProgress
        )))
        #expect(try await iterator.next() == .statusChanged(.active(activeFlags: [])))
        #expect(hub.snapshotForTesting(threadID: "thread-1").overflowCount == 1)
        events.cancel()
    }

    @Test func snapshotDoesNotWaitForBlockedSubscriptionPreparation() async throws {
        let hub = ThreadEventHub()
        let gate = PublicationGate()
        let snapshotCompleted = DispatchSemaphore(value: 0)
        let subscription = Task.detached {
            hub.eventsForTesting(for: "thread-1") {
                gate.blockPublication()
            }
        }
        defer { gate.releasePublication() }
        try #require(gate.waitUntilBlocked())

        let snapshotTask = Task.detached {
            let snapshot = hub.snapshotForTesting(threadID: "thread-1")
            snapshotCompleted.signal()
            return snapshot
        }
        let completedWhilePreparationWasBlocked = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: snapshotCompleted.wait(timeout: .now() + 5) == .success
                )
            }
        }
        gate.releasePublication()

        let events = await subscription.value
        let snapshot = await snapshotTask.value
        #expect(completedWhilePreparationWasBlocked)
        #expect(snapshot.subscriberCount == 0)
        #expect(snapshot.threadStateCount == 0)
        events.cancel()
    }

    @Test func blockedSubscriptionPreparationDoesNotDelayConcurrentPublication() async throws {
        let hub = ThreadEventHub()
        hub.beginGeneration(for: "thread-1", including: "turn-1")
        let existing = CodexThreadEvent.unknown(.init(
            method: "thread/existing",
            params: Data()
        ))
        let concurrent = CodexThreadEvent.unknown(.init(
            method: "thread/concurrent",
            params: Data()
        ))
        try hub.route(existing, for: "thread-1")
        let gate = PublicationGate()
        let publicationCompleted = DispatchSemaphore(value: 0)
        let subscription = Task.detached {
            hub.eventsForTesting(for: "thread-1") {
                gate.blockPublication()
            }
        }
        defer { gate.releasePublication() }
        try #require(gate.waitUntilBlocked())

        let publication = Task.detached {
            defer { publicationCompleted.signal() }
            return try hub.route(concurrent, for: "thread-1")
        }
        let completedWhilePreparationWasBlocked = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: publicationCompleted.wait(timeout: .now() + 5) == .success
                )
            }
        }
        gate.releasePublication()

        let events = await subscription.value
        _ = try await publication.value
        #expect(completedWhilePreparationWasBlocked)
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-1",
            state: .inProgress,
            itemsLoadState: .notLoaded
        )))
        #expect(try await iterator.next() == existing)
        #expect(try await iterator.next() == concurrent)
        events.cancel()
    }

    @Test func serializerSchedulingKeepsOnlyTheAcceptedAttempt() async throws {
        let hub = ThreadEventHub()
        let events = hub.events(for: "thread-1")
        var iterator = events.makeAsyncIterator()
        let first = try hub.registerCheckpoint(for: "thread-1")
        let second = try hub.registerCheckpoint(for: "thread-1")

        hub.activate(first)
        hub.activate(first)
        try hub.route(.turnStarted("turn-rejected"), for: "thread-1")
        hub.reject(first)

        #expect(hub.snapshotForTesting(threadID: "thread-1").hasActiveCheckpoint == false)
        #expect(hub.snapshotForTesting(threadID: "thread-1").pendingCheckpointCount == 2)

        hub.activate(first)
        try hub.route(.turnStarted("turn-1"), for: "thread-1")
        hub.commit(first)
        hub.discard(first)

        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-1",
            state: .inProgress
        )))
        #expect(hub.snapshotForTesting(threadID: "thread-1").pendingCheckpointCount == 1)

        hub.activate(second)
        try hub.route(.turnStarted("turn-2"), for: "thread-1")
        hub.commit(second)
        hub.discard(second)

        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-2",
            state: .inProgress
        )))
        let snapshot = hub.snapshotForTesting(threadID: "thread-1")
        #expect(snapshot.pendingCheckpointCount == 0)
        #expect(snapshot.hasActiveCheckpoint == false)
        #expect(snapshot.currentTurnID == "turn-2")
        events.cancel()
    }

    @Test func responseSnapshotMergesAfterAnEarlyTerminal() async throws {
        let hub = ThreadEventHub()
        let checkpoint = try hub.registerCheckpoint(for: "thread-1")
        hub.activate(checkpoint)
        let outcome = CodexTurnOutcome.completed(.init(turnID: "turn-1"))
        try hub.route(.terminal(outcome), for: "thread-1")

        try hub.seed(
            .init(id: "turn-1", state: .inProgress),
            at: checkpoint
        )
        hub.commit(checkpoint)

        let events = hub.events(for: "thread-1")
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .snapshot(.init(id: "turn-1", state: .completed)))
        #expect(try await iterator.next() == .terminal(.completed(.init(
            turnID: "turn-1",
            transcript: .init(),
            transcriptItemsLoadState: .full
        ))))
        events.cancel()
    }

    @Test func provisionalResumeSnapshotAdoptsAnEarlierCanonicalEventIdentity() async throws {
        let hub = ThreadEventHub()
        let checkpoint = try hub.registerCheckpoint(for: "thread-1")
        hub.activate(checkpoint)
        try hub.route(
            .itemStarted(messageItem(id: "live-item", text: "Live"), turnID: "turn-live"),
            for: "thread-1"
        )

        hub.seedProvisionalResumeSnapshot(
            .init(
                id: "rollout-synthesized-turn",
                state: .inProgress,
                items: [messageItem(id: "response-item", text: "Response")]
            ),
            at: checkpoint
        )
        hub.commit(checkpoint)

        let events = hub.events(for: "thread-1")
        var iterator = events.makeAsyncIterator()
        let event = try #require(try await iterator.next())
        guard case .snapshot(let snapshot) = event else {
            Issue.record("Expected a compact snapshot.")
            return
        }
        #expect(snapshot.id == "turn-live")
        #expect(snapshot.items.map(\.id) == ["response-item", "live-item"])
        events.cancel()
    }

    @Test func provisionalResumeSnapshotWaitsForALaterCanonicalEventIdentity() async throws {
        let hub = ThreadEventHub()
        let checkpoint = try hub.registerCheckpoint(for: "thread-1")
        hub.activate(checkpoint)
        hub.seedProvisionalResumeSnapshot(
            .init(
                id: "rollout-synthesized-turn",
                state: .inProgress,
                items: [messageItem(id: "response-item", text: "Response")]
            ),
            at: checkpoint
        )
        hub.commit(checkpoint)

        let committed = hub.snapshotForTesting(threadID: "thread-1")
        #expect(committed.currentTurnID == nil)
        #expect(committed.currentEventCount == 0)

        let events = hub.events(for: "thread-1")
        var iterator = events.makeAsyncIterator()
        try hub.route(
            .itemStarted(messageItem(id: "live-item", text: "Live"), turnID: "turn-live"),
            for: "thread-1"
        )

        let event = try #require(try await iterator.next())
        guard case .snapshot(let snapshot) = event else {
            Issue.record("Expected a compact snapshot.")
            return
        }
        #expect(snapshot.id == "turn-live")
        #expect(snapshot.items.map(\.id) == ["response-item", "live-item"])
        events.cancel()
    }

    @Test func persistedReviewIdentityPromotesACommittedProvisionalResumeSnapshot() async throws {
        let hub = ThreadEventHub()
        let checkpoint = try hub.registerCheckpoint(for: "thread-1")
        hub.activate(checkpoint)
        hub.seedProvisionalResumeSnapshot(
            .init(
                id: "rollout-synthesized-turn",
                state: .inProgress,
                items: [messageItem(id: "response-item", text: "Response")]
            ),
            at: checkpoint
        )
        hub.commit(checkpoint)

        hub.beginGeneration(for: "thread-1", including: "turn-persisted")

        let committed = hub.snapshotForTesting(threadID: "thread-1")
        #expect(committed.currentTurnID == "turn-persisted")
        let events = hub.events(for: "thread-1")
        var iterator = events.makeAsyncIterator()
        let event = try #require(try await iterator.next())
        guard case .snapshot(let snapshot) = event else {
            Issue.record("Expected a compact snapshot.")
            return
        }
        #expect(snapshot.id == "turn-persisted")
        #expect(snapshot.items.map(\.id) == ["response-item"])
        events.cancel()
    }

    @Test func sparseTerminalPreservesPartialSnapshotCompletenessForLateSubscribers() async throws {
        let hub = ThreadEventHub()
        hub.beginGeneration(for: "thread-1", including: "turn-1")
        let seededItem = messageItem(id: "seeded", text: "Seeded summary")
        try hub.route(.snapshot(.init(
            id: "turn-1",
            state: .inProgress,
            itemsLoadState: .summary,
            items: [seededItem]
        )), for: "thread-1")
        let observedItem = messageItem(id: "observed", text: "Complete live item")
        try hub.route(
            .itemCompleted(observedItem, turnID: "turn-1"),
            for: "thread-1"
        )
        let terminalItem = messageItem(id: "observed", text: "Terminal summary")
        let outcome = CodexTurnOutcome.completed(.init(
            turnID: "turn-1",
            transcript: .init(items: [terminalItem]),
            transcriptItemsLoadState: .summary
        ))
        try hub.route(.terminal(outcome), for: "thread-1")

        let events = hub.events(for: "thread-1")
        var iterator = events.makeAsyncIterator()
        let event = try #require(try await iterator.next())
        guard case .snapshot(let snapshot) = event else {
            Issue.record("Expected a compact terminal snapshot.")
            return
        }
        #expect(snapshot.itemsLoadState == .summary)
        #expect(snapshot.items == [seededItem, observedItem])
        #expect(try await iterator.next() == .terminal(.completed(.init(
            turnID: "turn-1",
            transcript: .init(items: [seededItem, observedItem]),
            transcriptItemsLoadState: .summary
        ))))
        events.cancel()
    }

    @Test func sparseTerminalReconcilesCompositeItemIdentityForLateSubscribers() async throws {
        let hub = ThreadEventHub()
        hub.beginGeneration(for: "thread-1", including: "turn-1")
        let entered = CodexThreadItem(
            id: "review-marker",
            kind: .enteredReviewMode,
            content: .log("Entered")
        )
        let staleExit = CodexThreadItem(
            id: "review-marker",
            kind: .exitedReviewMode,
            content: .log("Stale")
        )
        try hub.route(.snapshot(.init(
            id: "turn-1",
            state: .inProgress,
            itemsLoadState: .summary,
            items: [entered, staleExit]
        )), for: "thread-1")
        let observedEntered = CodexThreadItem(
            id: "review-marker",
            kind: .enteredReviewMode,
            content: .log("Entered live")
        )
        try hub.route(
            .itemCompleted(observedEntered, turnID: "turn-1"),
            for: "thread-1"
        )
        let terminalExit = CodexThreadItem(
            id: "review-marker",
            kind: .exitedReviewMode,
            content: .log("Final review")
        )

        try hub.route(.terminal(.completed(.init(
            turnID: "turn-1",
            transcript: .init(items: [terminalExit]),
            transcriptItemsLoadState: .summary
        ))), for: "thread-1")

        var iterator = hub.events(for: "thread-1").makeAsyncIterator()
        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-1",
            state: .completed,
            itemsLoadState: .summary,
            items: [observedEntered, terminalExit]
        )))
        #expect(try await iterator.next() == .terminal(.completed(.init(
            turnID: "turn-1",
            transcript: .init(items: [observedEntered, terminalExit]),
            transcriptItemsLoadState: .summary
        ))))
    }

    @Test func terminalIsExactlyOnceNonDroppableAndDoesNotFinishTheThread() async throws {
        let hub = ThreadEventHub()
        hub.beginGeneration(for: "thread-1", including: "turn-1")
        let events = hub.events(for: "thread-1")
        var iterator = events.makeAsyncIterator()
        let outcome = CodexTurnOutcome.completed(.init(turnID: "turn-1"))

        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-1",
            state: .inProgress,
            itemsLoadState: .notLoaded
        )))
        try hub.route(.terminal(outcome), for: "thread-1")
        #expect(try hub.route(.terminal(outcome), for: "thread-1") == 0)

        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-1",
            state: .completed,
            itemsLoadState: .notLoaded
        )))
        #expect(try await iterator.next() == .terminal(outcome))

        try hub.route(.statusChanged(.idle), for: "thread-1")
        #expect(try await iterator.next() == .statusChanged(.idle))

        do {
            try hub.route(
                .terminal(.interrupted(.init(turnID: "turn-1"))),
                for: "thread-1"
            )
            Issue.record("Expected a conflicting terminal outcome to fail.")
        } catch let error as CodexTransportFailure {
            #expect(error == .contractViolation(
                message: "Turn turn-1 reported conflicting terminal outcomes."
            ))
        }

        try hub.route(.closed, for: "thread-1")
        var remaining: [CodexThreadEvent] = []
        while let event = try await iterator.next() {
            remaining.append(event)
        }
        #expect(remaining.contains(.terminal(outcome)) == false)
        #expect(remaining.last == .closed)

        var late = hub.events(for: "thread-1").makeAsyncIterator()
        var lateEvents: [CodexThreadEvent] = []
        while let event = try await late.next() {
            lateEvents.append(event)
        }
        #expect(lateEvents.first == .snapshot(.init(
            id: "turn-1",
            state: .completed,
            itemsLoadState: .notLoaded
        )))
        #expect(lateEvents.filter { $0 == .terminal(outcome) }.count == 1)
        #expect(lateEvents.last == .closed)
    }

    @Test func terminalReplayHasExactCausalOrderForSlowAndLateSubscribers() async throws {
        let hub = ThreadEventHub()
        hub.beginGeneration(for: "thread-1", including: "turn-1")
        let slow = hub.events(for: "thread-1")
        let usage = CodexTokenUsage(inputTokens: 1, outputTokens: 2, totalTokens: 3)
        let wireOutcome = CodexTurnOutcome.completed(.init(turnID: "turn-1"))
        let outcome = CodexTurnOutcome.completed(.init(
            turnID: "turn-1",
            usage: usage
        ))
        let postStatus = CodexThreadStatus.idle
        let postUnknown = CodexThreadEvent.unknown(.init(
            method: "post-terminal",
            params: Data(),
            threadID: "thread-1",
            turnID: "turn-1"
        ))

        try hub.route(.statusChanged(.active(activeFlags: [])), for: "thread-1")
        try hub.route(.unknown(.init(
            method: "pre-terminal",
            params: Data(),
            threadID: "thread-1",
            turnID: "turn-1"
        )), for: "thread-1")
        try hub.route(.tokenUsageUpdated(usage, turnID: "turn-1"), for: "thread-1")
        try hub.route(.terminal(wireOutcome), for: "thread-1")
        try hub.route(.statusChanged(postStatus), for: "thread-1")
        try hub.route(postUnknown, for: "thread-1")
        try hub.route(.closed, for: "thread-1")

        let expected: [CodexThreadEvent] = [
            .snapshot(.init(
                id: "turn-1",
                state: .completed,
                itemsLoadState: .notLoaded
            )),
            .terminal(outcome),
            .statusChanged(postStatus),
            postUnknown,
            .closed,
        ]
        #expect(try await collect(from: slow) == expected)
        #expect(try await collect(from: hub.events(for: "thread-1")) == expected)
    }

    @Test func overflowCompactsToSnapshotBeforeTheBoundedNewestSuffix() async throws {
        let hub = ThreadEventHub()
        hub.beginGeneration(for: "thread-1", including: "turn-1")
        let events = hub.events(for: "thread-1")
        var iterator = events.makeAsyncIterator()

        for index in 0...256 {
            try hub.route(
                .unknown(.init(
                    method: "probe/\(index)",
                    params: Data(),
                    threadID: "thread-1",
                    turnID: "turn-1"
                )),
                for: "thread-1"
            )
        }

        let snapshot = hub.snapshotForTesting(threadID: "thread-1")
        #expect(snapshot.overflowCount == 1)
        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-1",
            state: .inProgress,
            itemsLoadState: .notLoaded
        )))

        var methods: [String] = []
        for _ in 0..<253 {
            guard case .unknown(let raw) = try #require(try await iterator.next()) else {
                Issue.record("Expected compacted unknown diagnostic suffix.")
                break
            }
            methods.append(raw.method)
        }
        #expect(methods.first == "probe/4")
        #expect(methods.last == "probe/256")
        events.cancel()
    }

    @Test func detachedAdoptionUsesTheMatchingBoundedProvisionalGeneration() async throws {
        let hub = ThreadEventHub()
        let checkpoint = try hub.registerCheckpoint(for: "thread-1")
        hub.activate(checkpoint)
        try hub.route(.statusChanged(.active(activeFlags: [])), for: "thread-1")
        try hub.route(.turnStarted("turn-1"), for: "thread-1")

        hub.beginGeneration(for: "thread-1", including: "turn-1")
        hub.commit(checkpoint)

        var iterator = hub.events(for: "thread-1").makeAsyncIterator()
        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-1",
            state: .inProgress
        )))
        #expect(try await iterator.next() == .statusChanged(.active(activeFlags: [])))
        #expect(hub.snapshotForTesting(threadID: "thread-1").pendingCheckpointCount == 0)
    }

    @Test func lateSubscriberReplaysBoundedIncrementalsWithinTheCurrentGeneration() async throws {
        let hub = ThreadEventHub()
        hub.beginGeneration(for: "thread-1", including: "turn-1")
        let item = CodexThreadItem(
            id: "message-1",
            kind: .agentMessage,
            content: .message(.init(id: "message-1", role: .assistant, text: ""))
        )
        let first = CodexMessageDelta(text: "First", itemID: "message-1")
        let second = CodexMessageDelta(text: "Second", itemID: "message-1")
        try hub.route(.itemStarted(item, turnID: "turn-1"), for: "thread-1")
        try hub.route(.messageDelta(first, turnID: "turn-1"), for: "thread-1")
        try hub.route(.messageDelta(second, turnID: "turn-1"), for: "thread-1")

        let events = hub.events(for: "thread-1")
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-1",
            state: .inProgress,
            itemsLoadState: .notLoaded,
            items: [item]
        )))
        #expect(try await iterator.next() == .messageDelta(first, turnID: "turn-1"))
        #expect(try await iterator.next() == .messageDelta(second, turnID: "turn-1"))
        events.cancel()
    }

    @Test func detachedStatusBeforeTurnRollsPastAClosedPriorGeneration() async throws {
        let hub = ThreadEventHub()
        let oldOutcome = CodexTurnOutcome.completed(.init(turnID: "turn-old"))
        hub.beginGeneration(for: "thread-detached", including: "turn-old")
        try hub.route(.terminal(oldOutcome), for: "thread-detached")
        try hub.route(.closed, for: "thread-detached")

        try hub.route(.statusChanged(.active(activeFlags: [])), for: "thread-detached")
        try hub.route(.turnStarted("turn-new"), for: "thread-detached")
        hub.beginGeneration(for: "thread-detached", including: "turn-new")

        let events = hub.events(for: "thread-detached")
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-new",
            state: .inProgress
        )))
        #expect(try await iterator.next() == .statusChanged(.active(activeFlags: [])))
        #expect(hub.snapshotForTesting(threadID: "thread-detached").currentTurnID == "turn-new")
        events.cancel()
    }

    @Test func aSlowSubscriberCompactsIndependentlyAndNewSnapshotSupersedesItsOldSuffix() async throws {
        let hub = ThreadEventHub()
        hub.beginGeneration(for: "thread-1", including: "turn-1")
        let fast = hub.events(for: "thread-1")
        let slow = hub.events(for: "thread-1")
        var fastIterator = fast.makeAsyncIterator()
        var slowIterator = slow.makeAsyncIterator()

        #expect(try await fastIterator.next() == .snapshot(.init(
            id: "turn-1",
            state: .inProgress,
            itemsLoadState: .notLoaded
        )))
        for index in 0..<600 {
            if index == 300 {
                let snapshot = CodexTurnSnapshot(
                    id: "turn-1",
                    state: .inProgress,
                    startedAt: Date(timeIntervalSince1970: 300)
                )
                try hub.route(.snapshot(snapshot), for: "thread-1")
                #expect(try await fastIterator.next() == .snapshot(snapshot))
            }
            let event = CodexThreadEvent.unknown(.init(
                method: "probe/\(index)",
                params: Data(),
                threadID: "thread-1",
                turnID: "turn-1"
            ))
            try hub.route(event, for: "thread-1")
            #expect(try await fastIterator.next() == event)
        }

        let snapshot = hub.snapshotForTesting(threadID: "thread-1")
        #expect(snapshot.overflowCount >= 2)
        guard case .snapshot(let compactSnapshot) = try #require(try await slowIterator.next()) else {
            Issue.record("Expected the slow subscriber's compact baseline first.")
            fast.cancel()
            slow.cancel()
            return
        }
        #expect(compactSnapshot.startedAt == Date(timeIntervalSince1970: 300))
        #expect(snapshot.subscriberCount == 2)
        fast.cancel()
        slow.cancel()
    }

    @Test func discardingAFailedCheckpointPreservesThePriorCurrentGeneration() async throws {
        let hub = ThreadEventHub()
        hub.beginGeneration(for: "thread-1", including: "turn-current")
        let checkpoint = try hub.registerCheckpoint(for: "thread-1")
        hub.activate(checkpoint)
        try hub.route(.turnStarted("turn-rejected"), for: "thread-1")

        hub.discard(checkpoint)

        let snapshot = hub.snapshotForTesting(threadID: "thread-1")
        #expect(snapshot.currentTurnID == "turn-current")
        #expect(snapshot.pendingCheckpointCount == 0)
        var iterator = hub.events(for: "thread-1").makeAsyncIterator()
        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-current",
            state: .inProgress,
            itemsLoadState: .notLoaded
        )))
    }

    @Test func threadProjectionsReleaseDedupeStateAcrossGenerations() async throws {
        let hub = ThreadEventHub()
        hub.beginGeneration(for: "thread-1", including: "turn-1")
        let messages = CodexThreadMessageSequence(events: hub.events(for: "thread-1"))
        let logs = CodexThreadLogSequence(events: hub.events(for: "thread-1"))
        var messageIterator = messages.makeAsyncIterator()
        var logIterator = logs.makeAsyncIterator()
        let first = CodexThreadItem(
            id: "shared-id",
            kind: .agentMessage,
            content: .message(.init(id: "shared-id", role: .assistant, text: "First"))
        )

        try hub.route(.itemCompleted(first, turnID: "turn-1"), for: "thread-1")
        #expect(try await messageIterator.next()?.text == "First")
        #expect(try await logIterator.next()?.item?.text == "First")
        try hub.route(
            .terminal(.completed(.init(turnID: "turn-1"))),
            for: "thread-1"
        )

        try hub.route(.turnStarted("turn-2"), for: "thread-1")
        let second = CodexThreadItem(
            id: "shared-id",
            kind: .agentMessage,
            content: .message(.init(id: "shared-id", role: .assistant, text: "Second"))
        )
        try hub.route(.itemCompleted(second, turnID: "turn-2"), for: "thread-1")

        #expect(try await messageIterator.next()?.text == "Second")
        #expect(try await logIterator.next()?.item?.text == "Second")
    }

    @Test func discardedUniqueCheckpointsDoNotAccumulateEmptyThreadState() throws {
        let hub = ThreadEventHub()

        for index in 0..<100 {
            let checkpoint = try hub.registerCheckpoint(for: .init(rawValue: "thread-\(index)"))
            hub.discard(checkpoint)
        }

        let snapshot = hub.snapshotForTesting(threadID: "probe")
        #expect(snapshot.pendingCheckpointCount == 0)
        #expect(snapshot.threadStateCount == 0)
    }

    @Test func aDifferentTurnAtomicallySupersedesTheTerminalGeneration() async throws {
        let hub = ThreadEventHub()
        hub.beginGeneration(for: "thread-1", including: "turn-1")
        let events = hub.events(for: "thread-1")
        var iterator = events.makeAsyncIterator()
        try hub.route(
            .terminal(.completed(.init(turnID: "turn-1"))),
            for: "thread-1"
        )

        try hub.route(.turnStarted("turn-2"), for: "thread-1")

        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-2",
            state: .inProgress
        )))
        #expect(hub.snapshotForTesting(threadID: "thread-1").currentTurnID == "turn-2")
        events.cancel()
    }

    @Test func closedGenerationCanBeReplacedByAnExplicitRequestCheckpoint() async throws {
        let hub = ThreadEventHub()
        hub.beginGeneration(for: "thread-1", including: "turn-old")
        try hub.route(.closed, for: "thread-1")
        let checkpoint = try hub.registerCheckpoint(for: "thread-1")
        hub.activate(checkpoint)
        try hub.route(.turnStarted("turn-new"), for: "thread-1")
        hub.commit(checkpoint)

        var iterator = hub.events(for: "thread-1").makeAsyncIterator()
        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-new",
            state: .inProgress
        )))
        #expect(hub.snapshotForTesting(threadID: "thread-1").isClosed == false)
    }

    @Test func emptyCheckpointStillCreatesAnOpaqueGenerationBoundary() async throws {
        let hub = ThreadEventHub()
        hub.beginGeneration(for: "thread-1", including: "turn-old")
        let oldOutcome = CodexTurnOutcome.completed(.init(turnID: "turn-old"))
        try hub.route(.terminal(oldOutcome), for: "thread-1")
        let events = hub.events(for: "thread-1")
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-old",
            state: .completed,
            itemsLoadState: .notLoaded
        )))
        #expect(try await iterator.next() == .terminal(oldOutcome))

        let checkpoint = try hub.registerCheckpoint(for: "thread-1")
        hub.activate(checkpoint)
        hub.commit(checkpoint)
        try hub.route(.statusChanged(.active(activeFlags: [])), for: "thread-1")
        try hub.route(.turnStarted("turn-new"), for: "thread-1")

        #expect(try await iterator.next() == .snapshot(.init(
            id: "turn-new",
            state: .inProgress
        )))
        #expect(try await iterator.next() == .statusChanged(.active(activeFlags: [])))
        events.cancel()
    }

    @Test func connectionFailureClearsGenerationsAndFailsCurrentAndLateSubscribersIdentically() async {
        let hub = ThreadEventHub()
        hub.beginGeneration(for: "thread-1", including: "turn-1")
        let events = hub.events(for: "thread-1")
        var current = events.makeAsyncIterator()
        let error = CodexAppServerError.connectionTerminated(.processExited(status: 9))

        hub.finish(throwing: error)

        await expectFailure(error, from: &current)
        var late = hub.events(for: "thread-1").makeAsyncIterator()
        await expectFailure(error, from: &late)
        let snapshot = hub.snapshotForTesting(threadID: "thread-1")
        #expect(snapshot.hasCurrentGeneration == false)
        #expect(snapshot.subscriberCount == 0)
        #expect(snapshot.failure == error)
    }

    @Test func checkpointTransitionsAreHarmlessAfterConnectionTermination() throws {
        let error = CodexAppServerError.connectionTerminated(.processExited(status: 9))

        let activateHub = ThreadEventHub()
        let inactive = try activateHub.registerCheckpoint(for: "thread-activate")
        activateHub.finish(throwing: error)
        activateHub.activate(inactive)

        let rejectHub = ThreadEventHub()
        let rejected = try rejectHub.registerCheckpoint(for: "thread-reject")
        rejectHub.activate(rejected)
        rejectHub.finish(throwing: error)
        rejectHub.reject(rejected)

        let commitHub = ThreadEventHub()
        let committed = try commitHub.registerCheckpoint(for: "thread-commit")
        commitHub.activate(committed)
        commitHub.finish(throwing: error)
        commitHub.commit(committed)

        do {
            _ = try commitHub.registerCheckpoint(for: "thread-late")
            Issue.record("Expected registration after failure to throw.")
        } catch let thrown as CodexAppServerError {
            #expect(thrown == error)
        }
        commitHub.resetGeneration(for: "thread-commit")
        commitHub.beginGeneration(for: "thread-commit", including: "turn-late")
        do {
            try commitHub.route(.statusChanged(.idle), for: "thread-commit")
            Issue.record("Expected routing after failure to throw.")
        } catch let thrown as CodexAppServerError {
            #expect(thrown == error)
        }
    }

    @Test func cancellationAfterHubRemovalDiscardsClosedAndFailedDelivery() async throws {
        let closedHub = ThreadEventHub()
        closedHub.beginGeneration(for: "thread-closed", including: "turn-1")
        let closed = closedHub.events(for: "thread-closed")
        try closedHub.route(.closed, for: "thread-closed")
        #expect(closedHub.snapshotForTesting(threadID: "thread-closed").subscriberCount == 0)
        closed.cancel()
        var closedIterator = closed.makeAsyncIterator()
        #expect(try await closedIterator.next() == nil)

        let failedHub = ThreadEventHub()
        let failed = failedHub.events(for: "thread-failed")
        failedHub.finish(throwing: .connectionTerminated(.processExited(status: 9)))
        failed.cancel()
        var failedIterator = failed.makeAsyncIterator()
        #expect(try await failedIterator.next() == nil)
    }

    @Test func explicitTaskAndLastCopyCancellationRemoveOnlyTheirSubscriber() async throws {
        let hub = ThreadEventHub()
        let retained = hub.events(for: "thread-1")
        var explicit: CodexThreadEventSequence? = hub.events(for: "thread-1")
        #expect(hub.snapshotForTesting(threadID: "thread-1").subscriberCount == 2)

        explicit?.cancel()
        explicit = nil
        #expect(hub.snapshotForTesting(threadID: "thread-1").subscriberCount == 1)

        do {
            _ = hub.events(for: "thread-1")
        }
        #expect(hub.snapshotForTesting(threadID: "thread-1").subscriberCount == 1)

        let waiting = hub.events(for: "thread-1")
        let task = Task {
            var iterator = waiting.makeAsyncIterator()
            return try await iterator.next()
        }
        #expect(hub.snapshotForTesting(threadID: "thread-1").subscriberCount == 2)
        task.cancel()
        #expect(try await task.value == nil)
        #expect(hub.snapshotForTesting(threadID: "thread-1").subscriberCount == 1)

        retained.cancel()
        #expect(hub.snapshotForTesting(threadID: "thread-1").subscriberCount == 0)
    }
}

private final class PublicationGate: @unchecked Sendable {
    private let blocked = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func blockPublication() {
        blocked.signal()
        released.wait()
    }

    func waitUntilBlocked() -> Bool {
        blocked.wait(timeout: .now() + 5) == .success
    }

    func releasePublication() {
        released.signal()
    }
}

private func collect(
    from sequence: CodexThreadEventSequence
) async throws -> [CodexThreadEvent] {
    var iterator = sequence.makeAsyncIterator()
    var events: [CodexThreadEvent] = []
    while let event = try await iterator.next() {
        events.append(event)
    }
    return events
}

private func messageItem(id: String, text: String) -> CodexThreadItem {
    .init(
        id: id,
        kind: .agentMessage,
        content: .message(.init(id: id, role: .assistant, text: text))
    )
}

private func expectFailure(
    _ expected: CodexAppServerError,
    from iterator: inout CodexThreadEventSequence.Iterator
) async {
    do {
        _ = try await iterator.next()
        Issue.record("Expected thread events to fail.")
    } catch let error as CodexAppServerError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected thread event failure: \(error)")
    }
}
