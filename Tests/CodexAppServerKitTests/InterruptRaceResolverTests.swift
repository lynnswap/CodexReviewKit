import Testing
@testable import CodexAppServerKit
@testable import CodexAppServerKitTesting

@Suite("Interrupt race resolver")
struct InterruptRaceResolverTests {
    @Test func retriesOnlyThePinnedNoActiveMessageWithFixedBudget() {
        var resolver = InterruptRaceResolver(expectedTurnID: "turn-1")
        let failure = serverFailure("no active turn to interrupt")

        for _ in 0..<5 {
            guard case .retry(let delay) = resolver.decision(for: failure) else {
                Issue.record("Expected the pinned activation race to retry.")
                return
            }
            #expect(delay == .milliseconds(50))
        }
        guard case .fail = resolver.decision(for: failure) else {
            Issue.record("Expected the fixed retry budget to be exhausted.")
            return
        }
    }

    @Test func similarNoActiveMessagesAreNotClassifiedAsThePinnedRace() {
        for message in [
            "No active turn to interrupt",
            "no active turn available to interrupt",
            "no active turn to interrupt ",
        ] {
            var resolver = InterruptRaceResolver(expectedTurnID: "turn-1")
            guard case .fail = resolver.decision(for: serverFailure(message)) else {
                Issue.record("Unexpected retry for \(message.debugDescription).")
                continue
            }
        }
    }

    @Test func redirectsOnlyOneExactExpectedTurnMismatch() {
        var resolver = InterruptRaceResolver(expectedTurnID: "turn-old")
        let mismatch = serverFailure(
            "expected active turn id turn-old but found turn-new"
        )
        guard case .redirect(let turnID) = resolver.decision(for: mismatch) else {
            Issue.record("Expected an exact active-turn redirect.")
            return
        }
        #expect(turnID == "turn-new")

        guard case .fail = resolver.decision(for: mismatch) else {
            Issue.record("A second mismatch must not redirect again.")
            return
        }

        var wrongExpected = InterruptRaceResolver(expectedTurnID: "turn-other")
        guard case .fail = wrongExpected.decision(for: mismatch) else {
            Issue.record("A mismatch for another expected turn must remain an error.")
            return
        }

        var malformedActual = InterruptRaceResolver(expectedTurnID: "turn-old")
        guard case .fail = malformedActual.decision(for: serverFailure(
            "expected active turn id turn-old but found turn-new trailing"
        )) else {
            Issue.record("A non-exact active turn ID must remain an error.")
            return
        }
    }

    @Test func startupInterruptNeverParsesAnExpectedTurnMismatch() {
        var resolver = InterruptRaceResolver(expectedTurnID: nil)
        let impossibleForPinnedAppServer = serverFailure(
            "expected active turn id  but found turn-new"
        )

        guard case .fail = resolver.decision(for: impossibleForPinnedAppServer) else {
            Issue.record("An unguarded startup interrupt must not infer a turn identity.")
            return
        }
    }

    @Test func interruptRetryUsesTheInjectedMonotonicClock() async throws {
        let recorder = InterruptSleepRecorder()
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        await transport.enqueueFailure(
            code: -32602,
            message: "no active turn to interrupt",
            for: "turn/interrupt"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let harness = await CodexAppServerTestConnectionHarness.start(
            transport: transport,
            deadlineClock: .init { duration in
                await recorder.record(duration)
            }
        )
        let thread = CodexThread(
            id: "thread-1",
            client: harness.client,
            router: harness.router,
            connectionLease: harness.lease
        )

        let stream = try await thread.streamResponse(to: "Run checks.")
        _ = try await stream.cancel()

        #expect(await recorder.values() == [.milliseconds(50)])
    }
}

private actor InterruptSleepRecorder {
    private var recorded: [Duration] = []

    func record(_ duration: Duration) {
        recorded.append(duration)
    }

    func values() -> [Duration] {
        recorded
    }
}

private func serverFailure(_ message: String) -> CodexAppServerError {
    .request(.init(
        requestID: 1,
        method: "turn/interrupt",
        purpose: .operation("turn/interrupt"),
        kind: .server(.init(code: -32602, message: message))
    ))
}
