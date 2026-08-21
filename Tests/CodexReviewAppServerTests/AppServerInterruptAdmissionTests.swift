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

    @Test func typedRecoveryPreparationRetainsTheBarrierWithoutAnotherInterrupt() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInterruptInitialize(transport)
        await transport.enqueueFailure(.closed, for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(
            client: .init(transport: transport)
        )
        let (admission, run) = try await makeAppServerInterruptAdmission()
        let streamFailure = ReviewAttemptStreamFailure.recoverableNetwork(
            .connection("Network transport ended")
        )

        let recovery = Task {
            try await admission.beginRecovery(
                run,
                trigger: .recoverableNetworkLoss,
                request: { requestAdmission, reason in
                    try await backend.interruptReview(
                        requestAdmission,
                        reason: reason
                    )
                }
            )
        }
        await transport.waitForRequestCount(2)
        try await admission.recordStreamTerminal(streamFailure, for: run)

        guard case .replacement(let candidate) = try await recovery.value else {
            Issue.record("A recoverable transport terminal was not tokenizable.")
            return
        }
        let handoff = try await backend.prepareReviewRecovery(candidate)

        #expect(handoff.candidate == candidate)
        #expect(handoff.token.interruptedRun == run)
        #expect(handoff.candidate.resolved.requestFailure?.outcome == .outcomeUnknown(
            message: JSONRPC.Error.closed.localizedDescription
        ))
        #expect(
            handoff.candidate.resolved.requestFailure?.secondaryBarrierDiagnostic
                == streamFailure.localizedDescription
        )
        #expect(
            await transport.recordedRequests().map(\.method)
                == ["initialize", "turn/interrupt"]
        )
    }

    @Test func notificationRouterRetainsTypedStreamFailureForAdmission() async throws {
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(
            client: .init(transport: transport)
        )
        let run = CodexReviewBackendModel.Review.Run(
            attemptID: "typed-stream-attempt",
            threadID: "parent-thread",
            turnID: "turn-1",
            reviewThreadID: "review-thread",
            model: "gpt-5"
        )
        let attempt = await backend.reviewAttemptForTesting(run)

        try await transport.emitServerNotification(
            method: "error",
            params: UnroutedRecoveryErrorNotification(
                message: "Routing failed",
                willRetry: false
            )
        )

        do {
            _ = try await attempt.events.next()
            Issue.record("A routing violation did not terminate the event mailbox.")
        } catch let failure as BackendReviewEventMailboxError {
            #expect(failure.failure == .protocolViolation(.init(
                message: ReviewIngestionError.missingRoutingIdentity(
                    method: "error"
                ).localizedDescription
            )))
        }
        await transport.close()
    }

    @Test func notificationRouterMapsProcessTerminationBeforeStoreConsumption() async throws {
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(
            client: .init(transport: transport)
        )
        let run = CodexReviewBackendModel.Review.Run(
            attemptID: "process-stream-attempt",
            threadID: "parent-thread",
            turnID: "turn-1",
            reviewThreadID: "review-thread",
            model: "gpt-5"
        )
        let attempt = await backend.reviewAttemptForTesting(run)
        let termination = JSONRPC.TransportTermination.processExit(
            "App-server exited with status 1"
        )

        await transport.finishNotificationStreams(
            throwing: JSONRPC.Error.transportTerminated(termination)
        )

        do {
            _ = try await attempt.events.next()
            Issue.record("A process exit did not terminate the event mailbox.")
        } catch let failure as BackendReviewEventMailboxError {
            #expect(failure.failure == .process(.process(
                termination.localizedDescription
            )))
        }
        await transport.close()
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

private struct UnroutedRecoveryErrorNotification: Encodable, Sendable {
    var message: String
    var willRetry: Bool

    enum CodingKeys: String, CodingKey {
        case error
        case willRetry
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            AppServerAPI.Turn.Error(message: message),
            forKey: .error
        )
        try container.encode(willRetry, forKey: .willRetry)
    }
}
