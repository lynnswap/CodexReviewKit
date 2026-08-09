import Foundation
import Testing

@testable import CodexAppServerKit
import CodexAppServerKitTesting

@Suite("Terminal lifecycle proof")
struct TerminalLifecycleProofTests {
    @Test func concurrentPublicHandleDoubleCloseJoinsOneFullClose() async {
        let transport = CloseCountingTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let server = harness.server
        let thread = makeThread(harness: harness, id: "thread-close")
        let review = await makeReview(
            thread: thread,
            turnID: "turn-close"
        )
        let barrier = CloseCallerBarrier(count: 6)

        async let firstRootClose = closeAndSnapshot(
            barrier: barrier,
            transport: transport
        ) {
            await server.close()
        }
        async let secondRootClose = closeAndSnapshot(
            barrier: barrier,
            transport: transport
        ) {
            await server.close()
        }
        async let firstThreadClose = closeAndSnapshot(
            barrier: barrier,
            transport: transport
        ) {
            await thread.closeConnection()
        }
        async let secondThreadClose = closeAndSnapshot(
            barrier: barrier,
            transport: transport
        ) {
            await thread.closeConnection()
        }
        async let firstReviewClose = closeAndSnapshot(
            barrier: barrier,
            transport: transport
        ) {
            await review.closeConnection()
        }
        async let secondReviewClose = closeAndSnapshot(
            barrier: barrier,
            transport: transport
        ) {
            await review.closeConnection()
        }

        await transport.waitUntilCloseStarts()
        #expect(await transport.snapshot().beginCloseCount == 1)
        await transport.releaseClose()

        let returnedSnapshots = await (
            firstRootClose,
            secondRootClose,
            firstThreadClose,
            secondThreadClose,
            firstReviewClose,
            secondReviewClose
        )
        for snapshot in [
            returnedSnapshots.0,
            returnedSnapshots.1,
            returnedSnapshots.2,
            returnedSnapshots.3,
            returnedSnapshots.4,
            returnedSnapshots.5,
        ] {
            #expect(snapshot.reapProcessCount == 1)
        }

        let snapshot = await transport.snapshot()
        #expect(snapshot.beginCloseCount == 1)
        #expect(snapshot.finishPendingResponsesCount == 1)
        #expect(snapshot.waitForProcessExitCount == 1)
        #expect(snapshot.waitUntilClosedCount == 1)
        #expect(snapshot.reapProcessCount == 1)
        #expect(await harness.supervisor.terminationForTesting() == .closedByCaller)
    }

    @Test func lastTerminalReviewHandleDropReleasesGenerationState() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let thread = makeThread(harness: harness, id: "thread-drop")
        var first: CodexReviewSession? = await makeReview(
            thread: thread,
            turnID: "turn-drop"
        )
        var last = first
        let weakState = WeakReference(first?.response.turn.state)
        let outcome = CodexTurnOutcome.completed(.init(turnID: "turn-drop"))

        await harness.turnReplayStore.finish(outcome)

        #expect(try await first?.collect() == outcome)
        #expect(await harness.turnReplayStore.snapshotForTesting().activeGenerationCount == 0)
        first = nil
        #expect(weakState.value != nil)
        #expect(try await last?.collect() == outcome)
        last = nil
        #expect(weakState.value == nil)

        await harness.close()
    }

    @Test func terminalReviewAndResponseHandlesReplayRepeatedLateCollects() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let thread = makeThread(harness: harness, id: "thread-late-collect")
        let review = await makeReview(
            thread: thread,
            turnID: "turn-late-collect"
        )
        let outcome = CodexTurnOutcome.completed(.init(turnID: "turn-late-collect"))

        await harness.turnReplayStore.finish(outcome)

        #expect(try await review.collect() == outcome)
        #expect(try await review.collect() == outcome)
        #expect(try await review.response.collect() == outcome)
        #expect(try await review.response.collect() == outcome)

        await harness.close()
    }

    @Test func reviewSessionReadsOnlyAnAlreadyCommittedTerminalOutcome() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let thread = makeThread(harness: harness, id: "thread-known-terminal")
        let review = await makeReview(
            thread: thread,
            turnID: "turn-known-terminal"
        )

        #expect(try await review.terminalOutcomeIfKnown() == nil)

        let outcome = CodexTurnOutcome.completed(.init(turnID: "turn-known-terminal"))
        await harness.turnReplayStore.finish(outcome)

        #expect(try await review.terminalOutcomeIfKnown() == outcome)
        #expect(try await review.terminalOutcomeIfKnown() == outcome)

        await harness.close()
    }

    @Test func knownTerminalReadSurfacesConnectionTerminationWithoutSynthesizingOutcome() async {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let thread = makeThread(harness: harness, id: "thread-known-termination")
        let review = await makeReview(
            thread: thread,
            turnID: "turn-known-termination"
        )

        await harness.close()

        do {
            _ = try await review.terminalOutcomeIfKnown()
            Issue.record("Expected the committed connection termination.")
        } catch let error as CodexAppServerError {
            #expect(error == .connectionTerminated(.closedByCaller))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func nonterminalAndHistoricalTerminalStatusesRemainTypedInvalidOutcomes() async throws {
        let aliases = ["success", "succeeded", "cancelled", "aborted", "started", "running"]
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        await transport.waitForNotificationStreamCount(1)

        for alias in aliases {
            let turnID = CodexTurnID(rawValue: "turn-alias-\(alias)")
            let state = await harness.turnReplayStore.restoreGeneration(
                turnID: turnID,
                initialSnapshot: .init(id: turnID, state: .inProgress),
                connectionLease: harness.lease
            )
            let turn = CodexTurn(
                id: turnID,
                threadID: "thread-alias",
                client: harness.client,
                router: harness.router,
                turnReplayStore: harness.turnReplayStore,
                state: state
            )

            try await transport.emitServerNotificationJSON(
                method: "turn/completed",
                json: #"{"threadId":"thread-alias","turn":{"id":"\#(turnID.rawValue)","status":"\#(alias)","items":[]}}"#
            )

            guard case .invalidTerminalStatus(let rawStatus, let error, let response) =
                try await turn.result()
            else {
                Issue.record("Expected \(alias) to remain an invalid terminal status.")
                continue
            }
            let expectedRawStatus = ["started", "running"].contains(alias) ? "inProgress" : alias
            #expect(rawStatus == expectedRawStatus)
            #expect(error == nil)
            #expect(response.turnID == turnID)
        }

        await harness.close()
    }

    private func makeThread(
        harness: CodexAppServerTestConnectionHarness,
        id: CodexThreadID
    ) -> CodexThread {
        CodexThread(
            id: id,
            client: harness.client,
            router: harness.router,
            connectionLease: harness.lease
        )
    }

    private func makeReview(
        thread: CodexThread,
        turnID: CodexTurnID
    ) async -> CodexReviewSession {
        await thread.reviewSession(
            .init(threadID: thread.id, turnID: turnID),
            initialTurn: .init(
                id: turnID,
                state: .inProgress,
                itemsLoadState: .notLoaded
            )
        )
    }
}

private func closeAndSnapshot(
    barrier: CloseCallerBarrier,
    transport: CloseCountingTransport,
    operation: @escaping @Sendable () async -> Void
) async -> CloseCountingTransport.Snapshot {
    await barrier.arriveAndWait()
    await operation()
    return await transport.snapshot()
}

private actor CloseCallerBarrier {
    private let target: Int
    private var arrivalCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) {
        precondition(count > 0)
        self.target = count
    }

    func arriveAndWait() async {
        arrivalCount += 1
        if arrivalCount == target {
            let waiters = waiters
            self.waiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
            return
        }
        precondition(arrivalCount < target)
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor CloseCountingTransport: JSONRPC.Transport {
    struct Snapshot: Equatable, Sendable {
        var beginCloseCount = 0
        var finishPendingResponsesCount = 0
        var waitForProcessExitCount = 0
        var waitUntilClosedCount = 0
        var reapProcessCount = 0
    }

    nonisolated let connectionEventHub = ConnectionEventHub()
    private let inboundClose = CodexAppServerTestGate()
    private let closeStarted = CodexAppServerTestGate()
    private let closeRelease = CodexAppServerTestGate()
    private var counts = Snapshot()

    func send(
        _ request: JSONRPC.Request,
        acceptWrite: @Sendable () throws -> Void
    ) async throws -> Data {
        throw JSONRPC.Error.closed
    }

    func notify(_ notification: JSONRPC.Notification) async throws {
        throw JSONRPC.Error.closed
    }

    func nextInboundEvent() async throws -> JSONRPC.InboundEvent? {
        await inboundClose.waitIgnoringCancellation()
        return nil
    }

    func respond(
        to requestID: CodexServerRequestID,
        with response: CodexServerRequestResponse
    ) async throws {
        throw JSONRPC.Error.closed
    }

    func beginClose() async -> JSONRPC.ProcessExitObservation? {
        counts.beginCloseCount += 1
        await closeStarted.open()
        await closeRelease.waitIgnoringCancellation()
        await inboundClose.open()
        return nil
    }

    func finishPendingResponsesAfterInboundDrain(_ failure: CodexTransportFailure) async {
        counts.finishPendingResponsesCount += 1
    }

    func waitForProcessExit() async -> JSONRPC.ProcessExitObservation {
        counts.waitForProcessExitCount += 1
        return .unavailable
    }

    func waitUntilClosed() async {
        counts.waitUntilClosedCount += 1
    }

    func reapProcess() async {
        counts.reapProcessCount += 1
    }

    func waitUntilCloseStarts() async {
        await closeStarted.waitIgnoringCancellation()
    }

    func releaseClose() async {
        await closeRelease.open()
    }

    func snapshot() -> Snapshot {
        counts
    }
}

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}
