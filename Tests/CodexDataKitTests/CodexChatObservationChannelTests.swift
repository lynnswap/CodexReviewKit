import CodexAppServerKit
import CodexDataKit
import Foundation
import Testing

@Suite("Chat observation channel")
struct CodexChatObservationChannelTests {
    @Test("the 257th pending update compacts to a complete overflow snapshot")
    func twoHundredFiftySeventhUpdateCompactsToSnapshot() async throws {
        let channel = CodexChatObservationChannel()
        let updates = CodexChatUpdates(channel: channel)
        var iterator = updates.makeAsyncIterator()
        channel.seed(snapshotEvent(sequence: 0, reason: .initial))

        let initial = try #require(await iterator.next())
        #expect(initial.sequence == 0)

        for sequence in 1...257 {
            channel.yield(
                updateEvent(sequence: UInt64(sequence)),
                overflowSnapshot: snapshotEvent(
                    sequence: UInt64(sequence),
                    reason: .bufferOverflow
                )
            )
        }

        let compacted = try #require(await iterator.next())
        #expect(compacted.sequence == 257)
        guard case .snapshot(let snapshot, let reason) = compacted.payload else {
            Issue.record("Expected overflow snapshot")
            return
        }
        #expect(reason == .bufferOverflow)
        #expect(snapshot.thread.id == "thread-overflow")
        #expect(channel.overflowCountForTesting() == 1)
    }

    @Test("a fast subscriber is independent from a slow subscriber overflow")
    func fastSubscriberIsIndependentFromSlowOverflow() async throws {
        let fastChannel = CodexChatObservationChannel()
        let slowChannel = CodexChatObservationChannel()
        var fast = CodexChatUpdates(channel: fastChannel).makeAsyncIterator()
        var slow = CodexChatUpdates(channel: slowChannel).makeAsyncIterator()
        fastChannel.seed(snapshotEvent(sequence: 0, reason: .initial))
        slowChannel.seed(snapshotEvent(sequence: 0, reason: .initial))
        _ = await fast.next()
        _ = await slow.next()

        for sequence in 1...257 {
            let event = updateEvent(sequence: UInt64(sequence))
            let snapshot = snapshotEvent(
                sequence: UInt64(sequence),
                reason: .bufferOverflow
            )
            fastChannel.yield(event, overflowSnapshot: snapshot)
            slowChannel.yield(event, overflowSnapshot: snapshot)
            #expect(await fast.next()?.sequence == UInt64(sequence))
        }

        let slowCompaction = try #require(await slow.next())
        #expect(slowCompaction.sequence == 257)
        #expect(slowChannel.overflowCountForTesting() == 1)
        #expect(fastChannel.overflowCountForTesting() == 0)
    }

    @Test("a second full suffix supersedes the previous overflow snapshot")
    func secondOverflowSupersedesPreviousSnapshot() async throws {
        let channel = CodexChatObservationChannel()
        var iterator = CodexChatUpdates(channel: channel).makeAsyncIterator()
        channel.seed(snapshotEvent(sequence: 0, reason: .initial))
        _ = await iterator.next()

        for sequence in 1...513 {
            channel.yield(
                updateEvent(sequence: UInt64(sequence)),
                overflowSnapshot: snapshotEvent(
                    sequence: UInt64(sequence),
                    reason: .bufferOverflow
                )
            )
        }

        let compacted = try #require(await iterator.next())
        #expect(compacted.sequence == 513)
        guard case .snapshot(_, let reason) = compacted.payload else {
            Issue.record("Expected second overflow snapshot")
            return
        }
        #expect(reason == .bufferOverflow)
        #expect(channel.overflowCountForTesting() == 2)
    }

    @Test("a snapshot barrier replaces its prefix and preserves the later suffix")
    func snapshotBarrierReplacesPrefix() async throws {
        let channel = CodexChatObservationChannel()
        var iterator = CodexChatUpdates(channel: channel).makeAsyncIterator()
        channel.seed(snapshotEvent(sequence: 0, reason: .initial))
        _ = await iterator.next()
        for sequence in 1...3 {
            channel.yield(
                updateEvent(sequence: UInt64(sequence)),
                overflowSnapshot: snapshotEvent(
                    sequence: UInt64(sequence),
                    reason: .bufferOverflow
                )
            )
        }
        channel.yield(
            snapshotEvent(sequence: 4, reason: .refresh),
            overflowSnapshot: snapshotEvent(sequence: 4, reason: .refresh)
        )
        channel.yield(
            updateEvent(sequence: 5),
            overflowSnapshot: snapshotEvent(sequence: 5, reason: .bufferOverflow)
        )

        let barrier = try #require(await iterator.next())
        #expect(barrier.sequence == 4)
        guard case .snapshot(_, let reason) = barrier.payload else {
            Issue.record("Expected refresh snapshot barrier")
            return
        }
        #expect(reason == .refresh)
        #expect(await iterator.next()?.sequence == 5)
    }

    @Test("a generation restart discards all pending events from the old generation")
    func generationRestartDiscardsOldPendingEvents() async throws {
        let channel = CodexChatObservationChannel()
        var iterator = CodexChatUpdates(channel: channel).makeAsyncIterator()
        channel.seed(snapshotEvent(sequence: 0, reason: .initial))
        _ = await iterator.next()
        for sequence in 1...3 {
            channel.yield(
                updateEvent(sequence: UInt64(sequence)),
                overflowSnapshot: snapshotEvent(
                    sequence: UInt64(sequence),
                    reason: .bufferOverflow
                )
            )
        }
        channel.yield(
            snapshotEvent(generation: 2, sequence: 0, reason: .generationRestart),
            overflowSnapshot: snapshotEvent(
                generation: 2,
                sequence: 0,
                reason: .generationRestart
            )
        )
        channel.yield(
            updateEvent(generation: 2, sequence: 1),
            overflowSnapshot: snapshotEvent(
                generation: 2,
                sequence: 1,
                reason: .bufferOverflow
            )
        )

        let restart = try #require(await iterator.next())
        #expect(restart.generation == 2)
        #expect(restart.sequence == 0)
        #expect(await iterator.next()?.sequence == 1)
    }

    @Test("an upstream failure supersedes buffered events and then finishes")
    func upstreamFailureSupersedesBufferAndFinishes() async throws {
        let channel = CodexChatObservationChannel()
        var iterator = CodexChatUpdates(channel: channel).makeAsyncIterator()
        channel.seed(snapshotEvent(sequence: 0, reason: .initial))
        _ = await iterator.next()
        for sequence in 1...20 {
            channel.yield(
                updateEvent(sequence: UInt64(sequence)),
                overflowSnapshot: snapshotEvent(
                    sequence: UInt64(sequence),
                    reason: .bufferOverflow
                )
            )
        }
        channel.supersedeAndFinish(with: snapshotEvent(
            sequence: 21,
            reason: .upstreamFailure
        ))

        let failure = try #require(await iterator.next())
        #expect(failure.sequence == 21)
        guard case .snapshot(_, let reason) = failure.payload else {
            Issue.record("Expected upstream failure snapshot")
            return
        }
        #expect(reason == .upstreamFailure)
        #expect(await iterator.next() == nil)
    }

    @Test("release signal deduplicates close and deinit sends by lease ID")
    func releaseSignalDeduplicatesLease() async throws {
        let signal = ChatObservationReleaseSignal()
        let leaseID = UUID()
        let firstAcknowledgement = ChatObservationReleaseAcknowledgement()
        let duplicateAcknowledgement = ChatObservationReleaseAcknowledgement()

        signal.release(leaseID, acknowledgement: firstAcknowledgement)
        signal.release(leaseID, acknowledgement: duplicateAcknowledgement)

        #expect(signal.releasedLeaseCountForTesting() == 1)
        let release = try #require(await signal.next())
        #expect(release.leaseID == leaseID)
        #expect(duplicateAcknowledgement.isCompletedForTesting() == false)
        signal.acknowledge(leaseID)
        await firstAcknowledgement.wait()
        await duplicateAcknowledgement.wait()
        signal.terminate()
        #expect(await signal.next() == nil)
    }

    @Test("overflow in a mutation batch compacts through the batch's final cursor")
    func batchOverflowUsesFinalCursor() async throws {
        let channel = CodexChatObservationChannel()
        var iterator = CodexChatUpdates(channel: channel).makeAsyncIterator()
        channel.seed(snapshotEvent(sequence: 0, reason: .initial))
        _ = await iterator.next()
        for sequence in 1...255 {
            channel.yield(
                updateEvent(sequence: UInt64(sequence)),
                overflowSnapshot: snapshotEvent(
                    sequence: UInt64(sequence),
                    reason: .bufferOverflow
                )
            )
        }

        channel.yield(
            [updateEvent(sequence: 256), updateEvent(sequence: 257)],
            overflowSnapshot: snapshotEvent(sequence: 257, reason: .bufferOverflow)
        )
        channel.yield(
            updateEvent(sequence: 258),
            overflowSnapshot: snapshotEvent(sequence: 258, reason: .bufferOverflow)
        )

        let compacted = try #require(await iterator.next())
        #expect(compacted.sequence == 257)
        guard case .snapshot(_, let reason) = compacted.payload else {
            Issue.record("Expected final-cursor overflow snapshot")
            return
        }
        #expect(reason == .bufferOverflow)
        #expect(await iterator.next()?.sequence == 258)
    }

    @Test("signal termination does not acknowledge a lease before its owner joins")
    func terminationDefersAcknowledgementUntilOwnerCompletion() async throws {
        let signal = ChatObservationReleaseSignal()
        let leaseID = UUID()
        let acknowledgement = ChatObservationReleaseAcknowledgement()
        signal.release(leaseID, acknowledgement: acknowledgement)
        _ = try #require(await signal.next())

        signal.terminate()

        #expect(acknowledgement.isCompletedForTesting() == false)
        signal.completeAllAcknowledgements()
        await acknowledgement.wait()
    }

    private func updateEvent(
        generation: UInt64 = 1,
        sequence: UInt64
    ) -> CodexChatObservationEvent {
        .init(
            generation: generation,
            sequence: sequence,
            payload: .update(.statusChanged(.idle))
        )
    }

    private func snapshotEvent(
        generation: UInt64 = 1,
        sequence: UInt64,
        reason: CodexChatSnapshotReason
    ) -> CodexChatObservationEvent {
        .init(
            generation: generation,
            sequence: sequence,
            payload: .snapshot(
                .init(
                    thread: .init(id: "thread-overflow", status: .idle, turns: []),
                    phase: .idle
                ),
                reason: reason
            )
        )
    }
}
