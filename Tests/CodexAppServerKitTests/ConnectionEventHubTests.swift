import Foundation
import Testing

import CodexAppServerKitTesting
@testable import CodexAppServerKit

@Suite("Connection termination arbitration")
struct ConnectionTerminationArbiterTests {
    @Test func acceptedCandidateRemainsProvisionalUntilCloseProbeCommitsIt() {
        var arbiter = ConnectionTerminationArbiter()
        let candidate = ConnectionTerminationArbiter.Candidate(.closedByCaller)

        #expect(arbiter.claim(candidate) == .accepted(candidate))
        #expect(arbiter.provisionalCandidate == candidate)
        #expect(arbiter.winner == nil)
        #expect(arbiter.commit(closeObservation: nil) == .closedByCaller)
        #expect(arbiter.provisionalCandidate == nil)
        #expect(arbiter.winner == .closedByCaller)
    }

    @Test func duplicateAndLateClaimsAreClassifiedBeforeAndAfterCommit() {
        var arbiter = ConnectionTerminationArbiter()
        let caller = ConnectionTerminationArbiter.Candidate(.closedByCaller)
        let exit = ConnectionTerminationArbiter.Candidate(
            .processExited(status: 9),
            observedBeforeTermination: true
        )

        #expect(arbiter.claim(caller) == .accepted(caller))
        #expect(arbiter.claim(caller) == .duplicate(caller))
        #expect(arbiter.claim(exit) == .late(winner: caller, candidate: exit))
        #expect(arbiter.commit(closeObservation: .exited(
            status: 9,
            observedBeforeTermination: true
        )) == .closedByCaller)
        #expect(arbiter.claim(caller) == .duplicate(caller))
        #expect(arbiter.claim(exit) == .late(winner: caller, candidate: exit))
    }

    @Test func explicitAndNonEOFFirstCandidatesCannotBeRefinedByCloseProbe() {
        let candidates: [ConnectionTerminationArbiter.Candidate] = [
            .init(.closedByCaller),
            .init(.transportFailure(.io(errno: 5, message: "read failed"))),
            .init(.processExited(status: 1), observedBeforeTermination: true),
        ]
        let observations: [ConnectionTerminationArbiter.CloseObservation?] = [
            .exited(status: 7, observedBeforeTermination: true),
            .failed(.contractViolation(message: "probe failed")),
        ]

        for candidate in candidates {
            for observation in observations {
                var arbiter = ConnectionTerminationArbiter()
                #expect(arbiter.claim(candidate) == .accepted(candidate))
                #expect(
                    arbiter.commit(closeObservation: observation) == candidate.termination
                )
                #expect(arbiter.winner == candidate.termination)
            }
        }
    }

    @Test func eofCommitsWhenCloseProbeHasNoMoreSpecificObservation() {
        for observation in [
            Optional<ConnectionTerminationArbiter.CloseObservation>.none,
            .some(.unavailable),
            .some(.exited(status: 9, observedBeforeTermination: false)),
            .some(.failed(.closed)),
        ] {
            var arbiter = ConnectionTerminationArbiter()
            let eof = ConnectionTerminationArbiter.Candidate(.transportFailure(.closed))
            #expect(arbiter.claim(eof) == .accepted(eof))
            #expect(
                arbiter.commit(closeObservation: observation) == .transportFailure(.closed)
            )
            #expect(arbiter.winner == .transportFailure(.closed))
        }
    }

    @Test func observedBeforeTerminationProcessExitRefinesProvisionalEOF() {
        var arbiter = ConnectionTerminationArbiter()
        let eof = ConnectionTerminationArbiter.Candidate(.transportFailure(.closed))
        let exit = ConnectionTerminationArbiter.Candidate(
            .processExited(status: 17),
            observedBeforeTermination: true
        )

        #expect(arbiter.claim(eof) == .accepted(eof))
        #expect(arbiter.claim(exit) == .refined(previous: eof, winner: exit))
        #expect(arbiter.provisionalCandidate == exit)
        #expect(arbiter.commit(closeObservation: nil) == .processExited(status: 17))
        #expect(arbiter.winner == .processExited(status: 17))
    }

    @Test func closeProbeProcessExitRefinesProvisionalEOFOnlyWhenObservedBeforeTermination() {
        var observedBefore = ConnectionTerminationArbiter()
        var observedAfter = ConnectionTerminationArbiter()
        let eof = ConnectionTerminationArbiter.Candidate(.transportFailure(.closed))
        #expect(observedBefore.claim(eof) == .accepted(eof))
        #expect(observedAfter.claim(eof) == .accepted(eof))

        #expect(observedBefore.commit(closeObservation: .exited(
            status: 23,
            observedBeforeTermination: true
        )) == .processExited(status: 23))
        #expect(observedAfter.commit(closeObservation: .exited(
            status: 23,
            observedBeforeTermination: false
        )) == .transportFailure(.closed))
    }

    @Test func beginCloseProbeFailureRefinesProvisionalEOF() {
        var arbiter = ConnectionTerminationArbiter()
        let eof = ConnectionTerminationArbiter.Candidate(.transportFailure(.closed))
        let probeFailure = CodexTransportFailure.io(errno: 10, message: "waitid failed")

        #expect(arbiter.claim(eof) == .accepted(eof))
        #expect(arbiter.commit(closeObservation: .failed(probeFailure)) ==
            .transportFailure(probeFailure))
        #expect(arbiter.winner == .transportFailure(probeFailure))
    }

    @Test func nonEOFSignalsCannotRefineProvisionalEOF() {
        var arbiter = ConnectionTerminationArbiter()
        let eof = ConnectionTerminationArbiter.Candidate(.transportFailure(.closed))
        let caller = ConnectionTerminationArbiter.Candidate(.closedByCaller)
        let io = ConnectionTerminationArbiter.Candidate(
            .transportFailure(.io(errno: 5, message: "read failed"))
        )
        let inducedExit = ConnectionTerminationArbiter.Candidate(
            .processExited(status: 9),
            observedBeforeTermination: false
        )

        #expect(arbiter.claim(eof) == .accepted(eof))
        #expect(arbiter.claim(caller) == .late(winner: eof, candidate: caller))
        #expect(arbiter.claim(io) == .late(winner: eof, candidate: io))
        #expect(arbiter.claim(inducedExit) == .late(winner: eof, candidate: inducedExit))
        #expect(arbiter.commit(closeObservation: nil) == .transportFailure(.closed))
    }

    @Test func eofAndObservedProcessExitConvergeAcrossSignalPermutations() {
        let eof = ConnectionTerminationArbiter.Candidate(.transportFailure(.closed))
        let exit = ConnectionTerminationArbiter.Candidate(
            .processExited(status: 31),
            observedBeforeTermination: true
        )

        var eofFirst = ConnectionTerminationArbiter()
        #expect(eofFirst.claim(eof) == .accepted(eof))
        #expect(eofFirst.claim(exit) == .refined(previous: eof, winner: exit))
        #expect(eofFirst.commit(closeObservation: nil) == .processExited(status: 31))

        var exitFirst = ConnectionTerminationArbiter()
        #expect(exitFirst.claim(exit) == .accepted(exit))
        #expect(exitFirst.claim(eof) == .late(winner: exit, candidate: eof))
        #expect(exitFirst.commit(closeObservation: nil) == .processExited(status: 31))
    }

    @Test func commitIsIdempotentAndCannotBeReopenedByASecondProbe() {
        var arbiter = ConnectionTerminationArbiter()
        let eof = ConnectionTerminationArbiter.Candidate(.transportFailure(.closed))
        #expect(arbiter.claim(eof) == .accepted(eof))
        #expect(arbiter.commit(closeObservation: .unavailable) == .transportFailure(.closed))
        #expect(arbiter.commit(closeObservation: .exited(
            status: 37,
            observedBeforeTermination: true
        )) == .transportFailure(.closed))
        #expect(arbiter.winner == .transportFailure(.closed))
    }
}

@Suite("Connection event hub")
struct ConnectionEventHubTests {
    @Test func publicDiagnosticValuesPreserveTheirFields() {
        let serverError = CodexServerError(code: -32_001, message: "busy")
        let warning = CodexDiagnostic(
            message: "configuration warning",
            method: "configWarning",
            details: "Use the new key."
        )
        let retry = CodexRetryDiagnostic(
            requestID: 7,
            method: "turn/start",
            attempt: 1,
            delay: .milliseconds(100),
            serverError: serverError
        )
        let deprecation = CodexDeprecationNotice(
            summary: "thread/rollback is deprecated",
            details: "Use the replacement when available."
        )

        #expect(warning.message == "configuration warning")
        #expect(warning.method == "configWarning")
        #expect(warning.details == "Use the new key.")
        #expect(retry.requestID == 7)
        #expect(retry.method == "turn/start")
        #expect(retry.attempt == 1)
        #expect(retry.delay == .milliseconds(100))
        #expect(retry.serverError == serverError)
        #expect(deprecation.summary == "thread/rollback is deprecated")
        #expect(deprecation.details == "Use the replacement when available.")
    }

    @Test func liveSubscriberReceivesEveryDiagnosticKindInOrder() async {
        let hub = ConnectionEventHub()
        let events = hub.events()
        let expected: [CodexConnectionEvent] = [
            .warning(.init(message: "warning", method: "warning")),
            .retrying(.init(
                requestID: 1,
                method: "thread/start",
                attempt: 1,
                delay: .milliseconds(100),
                serverError: .init(code: -32_001, message: "busy")
            )),
            .deprecation(.init(summary: "deprecated", details: "migration guidance")),
            .unknown(.init(method: "future/event", params: Data(#"{"value":1}"#.utf8))),
        ]

        for event in expected {
            hub.yield(event)
        }

        var iterator = events.makeAsyncIterator()
        for event in expected {
            #expect(await iterator.next() == event)
        }
        await events.cancel()
    }

    @Test func slowSubscriberKeepsOnlyNewestThirtyTwoDiagnostics() async {
        let hub = ConnectionEventHub()
        let events = hub.events()

        for index in 0..<40 {
            hub.yield(.warning(.init(message: "warning-\(index)")))
        }

        var iterator = events.makeAsyncIterator()
        var messages: [String] = []
        for _ in 0..<32 {
            guard case .warning(let diagnostic) = await iterator.next() else {
                Issue.record("Expected a warning diagnostic.")
                return
            }
            messages.append(diagnostic.message)
        }
        #expect(messages == (8..<40).map { "warning-\($0)" })
        await events.cancel()
    }

    @Test func nextCallOwnershipRejectsOverlapEvenWhenDiagnosticsAreBuffered() async {
        let hub = ConnectionEventHub()
        let events = hub.events()
        hub.yield(.warning(.init(message: "first")))
        hub.yield(.warning(.init(message: "second")))

        #expect(events.claimNextCallForTesting())
        #expect(events.claimNextCallForTesting() == false)
        events.endNextCallForTesting()

        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .warning(.init(message: "first")))
        #expect(await iterator.next() == .warning(.init(message: "second")))
        await events.cancel()
    }

    @Test func deliveredDiagnosticPrecedesLaterSynchronousTerminal() async {
        let hub = ConnectionEventHub()
        let events = hub.events()
        let first = Task {
            var iterator = events.makeAsyncIterator()
            return await iterator.next()
        }
        await events.waitUntilNextSuspendsForTesting()

        hub.yield(.warning(.init(message: "before terminal")))
        hub.finish(with: .closedByCaller)

        #expect(await first.value == .warning(.init(message: "before terminal")))
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .terminated(.closedByCaller))
        #expect(await iterator.next() == nil)
    }

    @Test func terminalSupersedesAFullDiagnosticBufferAndIsNeverDropped() async {
        let hub = ConnectionEventHub()
        let events = hub.events()
        for index in 0..<32 {
            hub.yield(.warning(.init(message: "warning-\(index)")))
        }

        hub.finish(with: .processExited(status: 17))

        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .terminated(.processExited(status: 17)))
        #expect(await iterator.next() == nil)
        #expect(await iterator.next() == nil)
    }

    @Test func terminalImmediatelyResumesAWaitingSubscriber() async {
        let hub = ConnectionEventHub()
        let events = hub.events()
        let waiter = Task {
            var iterator = events.makeAsyncIterator()
            return await iterator.next()
        }
        await events.waitUntilNextSuspendsForTesting()

        hub.finish(with: .transportFailure(.closed))

        #expect(await waiter.value == .terminated(.transportFailure(.closed)))
    }

    @Test func lateSubscriberReceivesOnlyTheCompactTerminal() async {
        let hub = ConnectionEventHub()
        let early = hub.events()
        hub.yield(.warning(.init(message: "old warning")))
        hub.finish(with: .closedByCaller)
        hub.finish(with: .closedByCaller)

        let late = hub.events()
        var earlyIterator = early.makeAsyncIterator()
        var lateIterator = late.makeAsyncIterator()
        #expect(await earlyIterator.next() == .terminated(.closedByCaller))
        #expect(await earlyIterator.next() == nil)
        #expect(await lateIterator.next() == .terminated(.closedByCaller))
        #expect(await lateIterator.next() == nil)
        #expect(hub.snapshotForTesting().subscriberCount == 0)
        #expect(hub.snapshotForTesting().terminal == .closedByCaller)
    }

    @Test func diagnosticsAfterTerminalCannotReplaceReplay() async {
        let hub = ConnectionEventHub()
        hub.finish(with: .closedByCaller)
        hub.yield(.warning(.init(message: "too late")))

        let events = hub.events()
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .terminated(.closedByCaller))
        #expect(await iterator.next() == nil)
    }

    @Test func explicitCancellationIsSynchronousIdempotentAndSubscriberLocal() async {
        let hub = ConnectionEventHub()
        let cancelled = hub.events()
        let remaining = hub.events()
        #expect(hub.snapshotForTesting().subscriberCount == 2)

        await cancelled.cancel()
        #expect(hub.snapshotForTesting().subscriberCount == 1)
        await cancelled.cancel()
        #expect(hub.snapshotForTesting().subscriberCount == 1)

        hub.yield(.warning(.init(message: "remaining")))
        var cancelledIterator = cancelled.makeAsyncIterator()
        var remainingIterator = remaining.makeAsyncIterator()
        #expect(await cancelledIterator.next() == nil)
        #expect(await remainingIterator.next() == .warning(.init(message: "remaining")))
        await remaining.cancel()
        #expect(hub.snapshotForTesting().subscriberCount == 0)
    }

    @Test func taskCancellationSynchronouslyReleasesOnlyItsSubscription() async {
        let hub = ConnectionEventHub()
        let cancelled = hub.events()
        let remaining = hub.events()
        let waiter = Task {
            var iterator = cancelled.makeAsyncIterator()
            return await iterator.next()
        }
        await cancelled.waitUntilNextSuspendsForTesting()

        waiter.cancel()

        #expect(await waiter.value == nil)
        #expect(hub.snapshotForTesting().subscriberCount == 1)
        hub.yield(.warning(.init(message: "still active")))
        var iterator = remaining.makeAsyncIterator()
        #expect(await iterator.next() == .warning(.init(message: "still active")))
        await remaining.cancel()
    }

    @Test func lastSequenceOrIteratorCopyReleaseUnsubscribesSynchronously() async {
        let hub = ConnectionEventHub()
        var events: CodexConnectionEvents? = hub.events()
        var copy = events
        var iterator: CodexConnectionEvents.Iterator? = copy?.makeAsyncIterator()
        #expect(hub.snapshotForTesting().subscriberCount == 1)

        events = nil
        copy = nil
        #expect(hub.snapshotForTesting().subscriberCount == 1)
        withExtendedLifetime(iterator) {}
        iterator = nil

        #expect(hub.snapshotForTesting().subscriberCount == 0)
    }

    @Test func subscriptionDoesNotRetainItsHubOrAConnectionOwner() async {
        let detached = makeEventsFromEphemeralHub()

        #expect(detached.hub.value == nil)
        var iterator = detached.events.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test func fastSubscriberIsUnaffectedBySlowSubscriberOverflow() async {
        let hub = ConnectionEventHub()
        let fast = hub.events()
        let slow = hub.events()
        var fastIterator = fast.makeAsyncIterator()

        for index in 0..<40 {
            let event = CodexConnectionEvent.warning(.init(message: "warning-\(index)"))
            hub.yield(event)
            #expect(await fastIterator.next() == event)
        }

        var slowIterator = slow.makeAsyncIterator()
        var slowMessages: [String] = []
        for _ in 0..<32 {
            guard case .warning(let diagnostic) = await slowIterator.next() else {
                Issue.record("Expected a warning diagnostic.")
                return
            }
            slowMessages.append(diagnostic.message)
        }
        #expect(slowMessages == (8..<40).map { "warning-\($0)" })
        await fast.cancel()
        await slow.cancel()
    }
}

@Suite("Connection event integration")
struct ConnectionEventIntegrationTests {
    @Test func stderrDiagnosticsPreserveFilterSeverityAndIOStage() {
        #expect(ConnectionDiagnosticFactory.processStderr(.init(
            level: .error,
            message: "plain stderr"
        )) == .init(
            message: "plain stderr",
            method: "process/stderr",
            details: "severity: error"
        ))
        #expect(ConnectionDiagnosticFactory.processStderr(.init(
            level: .warning,
            message: "command output omitted"
        )) == .init(
            message: "command output omitted",
            method: "process/stderr",
            details: "severity: warning"
        ))
        #expect(ConnectionDiagnosticFactory.processStderrFailure(
            .setup,
            details: "Bad file descriptor"
        ) == .init(
            message: "App-server stderr setup failed.",
            method: "process/stderr",
            details: "Bad file descriptor"
        ))
        #expect(ConnectionDiagnosticFactory.processStderrFailure(
            .read,
            details: "Input/output error"
        ) == .init(
            message: "App-server stderr read failed.",
            method: "process/stderr",
            details: "Input/output error"
        ))
    }

    @Test func publicStreamReceivesDecodedDiagnosticsAndTheCommittedTerminal() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let events = await runtime.server.connectionEvents()
        var iterator = events.makeAsyncIterator()

        try await runtime.transport.emitServerNotificationJSON(
            method: "warning",
            json: #"{"message":"wire warning"}"#
        )
        try await runtime.transport.emitServerNotificationJSON(
            method: "deprecationNotice",
            json: #"{"summary":"old API","details":"use new API"}"#
        )
        try await runtime.transport.emitServerNotificationJSON(
            method: "configWarning",
            json: #"{"summary":"bad key","details":"remove it","path":"config.toml","range":{"start":{"line":1,"column":2},"end":{"line":1,"column":5}}}"#
        )
        try await runtime.transport.emitServerNotificationJSON(
            method: "future/notification",
            json: #"{"threadId":"thread-1","turnId":"turn-1","value":1}"#
        )

        #expect(await iterator.next() == .warning(.init(
            message: "wire warning",
            method: "warning"
        )))
        #expect(await iterator.next() == .deprecation(.init(
            summary: "old API",
            details: "use new API"
        )))
        #expect(await iterator.next() == .warning(.init(
            message: "bad key",
            method: "configWarning",
            details: "remove it"
        )))
        guard case .unknown(let raw) = await iterator.next() else {
            Issue.record("Expected an unknown connection notification.")
            return
        }
        #expect(raw.method == "future/notification")
        #expect(raw.threadID == "thread-1")
        #expect(raw.turnID == "turn-1")

        await runtime.server.close()
        #expect(await iterator.next() == .terminated(.closedByCaller))
        #expect(await iterator.next() == nil)
    }

    @Test func latePublicSubscriberReplaysOnlyTheCommittedTerminal() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        await runtime.server.close()

        var iterator = await runtime.server.connectionEvents().makeAsyncIterator()
        #expect(await iterator.next() == .terminated(.closedByCaller))
        #expect(await iterator.next() == nil)
    }
}

private final class WeakReference<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}

private func makeEventsFromEphemeralHub() -> (
    events: CodexConnectionEvents,
    hub: WeakReference<ConnectionEventHub>
) {
    let hub = ConnectionEventHub()
    return (hub.events(), WeakReference(hub))
}
