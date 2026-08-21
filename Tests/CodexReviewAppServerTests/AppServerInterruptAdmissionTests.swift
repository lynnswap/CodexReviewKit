import Foundation
import Testing
@testable import CodexReviewAppServer
import CodexReview
import CodexReviewTesting

@Suite("app-server interrupt admission")
struct AppServerInterruptAdmissionTests {
    @Test func admissionAwareInterruptSendsOnlyTheRequestAndWaitsForCanonicalTerminal() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInterruptInitialize(transport)
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "parent-thread", model: "gpt-5"),
            for: "thread/start"
        )
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "turn-1",
                reviewThreadID: "review-thread"
            ),
            for: "review/start"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let admission = ReviewStartAdmission()
        let attempt = try await backend.startReview(
            .init(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                model: "gpt-5"
            ),
            admission: admission
        )
        let run = attempt.run
        let cancellation = ReviewCancellation.mcpClient(message: "Stop")

        let interruption = Task {
            try await admission.interrupt(
                run,
                cancellation: cancellation,
                request: { requestAdmission, reason in
                    try await backend.interruptReview(
                        requestAdmission,
                        reason: reason
                    )
                }
            )
        }
        await transport.waitForRequestCount(4)

        guard case .interrupting(let phaseRun, let phaseCancellation, _) =
            await admission.currentPhase()
        else {
            Issue.record("Interrupt ACK incorrectly completed the attempt.")
            return
        }
        #expect(phaseRun == run)
        #expect(phaseCancellation == cancellation)
        #expect(await attempt.events.isFinished() == false)
        try await admission.recordCanonicalTerminal(
            .interrupted(.server(message: "Stopped")),
            for: run
        )
        let resolution = try await interruption.value

        #expect(resolution.terminal == .canonical(
            .interrupted(.requested(cancellation))
        ))
        #expect(await attempt.events.isFinished() == false)
        let requests = await transport.recordedRequests()
        #expect(requests.map(\.method) == [
            "initialize",
            "thread/start",
            "review/start",
            "turn/interrupt",
        ])
        let interrupt = try #require(requests.last)
        let params = try JSONDecoder().decode(
            AppServerAPI.Turn.Interrupt.Params.self,
            from: interrupt.params
        )
        #expect(params.threadID == run.reviewThreadID)
        #expect(params.turnID == run.turnID)
    }

    @Test func admissionAwareInterruptRecordsExplicitRejectionForRetry() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInterruptInitialize(transport)
        await transport.enqueueFailure(
            .responseError(code: -32_000, message: "No active turn"),
            for: "turn/interrupt"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let (admission, run) = try await makeAppServerInterruptAdmission()

        do {
            _ = try await admission.interrupt(
                run,
                cancellation: .mcpClient(message: "Stop"),
                request: { requestAdmission, reason in
                    try await backend.interruptReview(
                        requestAdmission,
                        reason: reason
                    )
                }
            )
            Issue.record("An explicit interrupt rejection was accepted.")
        } catch let failure as ReviewInterruptRequestFailure {
            #expect(failure.outcome == .rejected(
                code: -32_000,
                message: "No active turn"
            ))
        }

        #expect(await admission.currentPhase() == .active(run))
        #expect(await admission.cancellationRequest() == nil)
    }

    @Test func admissionAwareInterruptRecordsOutcomeUnknownUntilConnectionTerminal() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInterruptInitialize(transport)
        await transport.enqueueFailure(.closed, for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let (admission, run) = try await makeAppServerInterruptAdmission()
        let connection = ReviewRuntimeCloseFailure.connection("Transport ended")

        let interruption = Task {
            try await admission.interrupt(
                run,
                cancellation: .system(message: "Stop"),
                request: { requestAdmission, reason in
                    try await backend.interruptReview(
                        requestAdmission,
                        reason: reason
                    )
                }
            )
        }
        await transport.waitForRequestCount(2)
        try await admission.recordConnectionTerminal(connection, for: run)

        do {
            _ = try await interruption.value
            Issue.record("An outcome-unknown interrupt was accepted without diagnostics.")
        } catch let failure as ReviewInterruptRequestFailure {
            #expect(failure.outcome == .outcomeUnknown(
                message: JSONRPC.Error.closed.localizedDescription
            ))
            #expect(failure.secondaryBarrierDiagnostic == connection.localizedDescription)
        }
    }

    @Test func admissionAwareInterruptDoesNotRetargetFromResponseText() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInterruptInitialize(transport)
        await transport.enqueueFailure(
            .responseError(
                code: -32_602,
                message: "expected active turn id turn-1 but found turn-other"
            ),
            for: "turn/interrupt"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let (admission, run) = try await makeAppServerInterruptAdmission()

        await #expect(throws: ReviewInterruptRequestFailure.self) {
            try await admission.interrupt(
                run,
                cancellation: .system(message: "Stop"),
                request: { requestAdmission, reason in
                    try await backend.interruptReview(
                        requestAdmission,
                        reason: reason
                    )
                }
            )
        }

        let interruptRequests = await transport.recordedRequests()
            .filter { $0.method == "turn/interrupt" }
        #expect(interruptRequests.count == 1)
        let request = try #require(interruptRequests.first)
        let params = try JSONDecoder().decode(
            AppServerAPI.Turn.Interrupt.Params.self,
            from: request.params
        )
        #expect(params.turnID == run.turnID)
        #expect(await admission.currentPhase() == .active(run))
    }
}

private func makeAppServerInterruptAdmission() async throws -> (
    admission: ReviewStartAdmission,
    run: CodexReviewBackendModel.Review.Run
) {
    let admission = ReviewStartAdmission()
    let provisionalRun = CodexReviewBackendModel.Review.Run(
        attemptID: "app-server-interrupt-attempt",
        threadID: "parent-thread",
        reviewThreadID: "parent-thread",
        model: "gpt-5"
    )
    let run = CodexReviewBackendModel.Review.Run(
        attemptID: provisionalRun.attemptID,
        threadID: provisionalRun.threadID,
        turnID: "turn-1",
        reviewThreadID: "review-thread",
        model: provisionalRun.model
    )
    try await admission.admitThreadStartDispatch()
    try await admission.recordPreparedThread(provisionalRun)
    try await admission.admitReviewStartDispatch(for: provisionalRun)
    try await admission.recordActiveRun(run)
    return (admission, run)
}

private func enqueueInterruptInitialize(_ transport: FakeJSONRPCTransport) async throws {
    try await transport.enqueue(
        AppServerAPI.Initialize.Response(codexHome: "/tmp/codex"),
        for: "initialize"
    )
}
