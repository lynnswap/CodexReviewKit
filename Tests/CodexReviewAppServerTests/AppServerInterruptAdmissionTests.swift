import Foundation
import Testing
@testable import CodexReviewAppServer
import CodexReview
import CodexReviewTesting

@Suite("app-server interrupt admission")
struct AppServerInterruptAdmissionTests {
    @Test func admissionAwareInterruptUsesStartedChildTurnAndWaitsForCanonicalTerminal() async throws {
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
        try await transport.emitServerNotification(
            method: "turn/started",
            params: InterruptTurnNotification(
                threadID: "review-thread",
                turnID: "child-turn"
            )
        )
        await backend.waitForReviewNotificationCompletionForTesting(1)

        let interruption = Task {
            try await admission.interrupt(
                run,
                cancellation: cancellation,
                request: { requestAdmission, reason in
                    try await backend.interruptReview(
                        requestAdmission,
                        reason: reason
                    )
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
        #expect(resolution.run == run)
        #expect(await attempt.events.isFinished() == false)
        let requests = await transport.recordedRequests()
        #expect(requests.map(\.method) == [
            "initialize",
            "thread/start",
            "review/start",
            "turn/interrupt",
        ])
        let interruptions = try requests
            .filter { $0.method == "turn/interrupt" }
            .map {
                try JSONDecoder().decode(
                    AppServerAPI.Turn.Interrupt.Params.self,
                    from: $0.params
                )
            }
        #expect(interruptions.map(\.threadID) == ["review-thread"])
        #expect(interruptions.map(\.turnID) == ["child-turn"])
    }

    @Test func admissionAwareInterruptRetriesReportedActiveTurnWhenStartedNotificationIsMissing() async throws {
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
        await transport.enqueueFailure(
            .responseError(
                code: -32_602,
                message: "expected active turn id turn-1 but found child-turn"
            ),
            for: "turn/interrupt"
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
        await transport.waitForRequestCount(5)
        try await admission.recordCanonicalTerminal(
            .interrupted(.server(message: "Stopped")),
            for: run
        )
        let resolution = try await interruption.value

        #expect(resolution.run == run)
        #expect(resolution.terminal == .canonical(
            .interrupted(.requested(cancellation))
        ))
        let interruptions = try await transport.recordedRequests()
            .filter { $0.method == "turn/interrupt" }
            .map {
                try JSONDecoder().decode(
                    AppServerAPI.Turn.Interrupt.Params.self,
                    from: $0.params
                )
            }
        #expect(interruptions.map(\.threadID) == ["review-thread", "review-thread"])
        #expect(interruptions.map(\.turnID) == ["turn-1", "child-turn"])
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
        let interruptRequests = await transport.recordedRequests()
            .filter { $0.method == "turn/interrupt" }
        #expect(interruptRequests.count == 1)
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
        let consumedHandoff = try await handoff.consume()

        #expect(handoff.candidate == candidate)
        #expect(consumedHandoff.candidate == candidate)
        #expect(consumedHandoff.token.interruptedRun == run)
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

    @Test(arguments: [
        (
            JSONRPC.Error.transportTerminated(.ownerClose),
            ReviewAttemptStreamFailure.ownerForcedConnectionClose(.connection(
                JSONRPC.TransportTermination.ownerClose.localizedDescription
            ))
        ),
        (
            JSONRPC.Error.closed,
            ReviewAttemptStreamFailure.unexpectedConnection(.connection(
                JSONRPC.Error.closed.localizedDescription
            ))
        ),
    ])
    func notificationRouterPreservesConnectionTerminationSource(
        termination: JSONRPC.Error,
        expected: ReviewAttemptStreamFailure
    ) async throws {
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(
            client: .init(transport: transport)
        )
        let run = CodexReviewBackendModel.Review.Run(
            attemptID: "connection-source-attempt",
            threadID: "parent-thread",
            turnID: "turn-1",
            reviewThreadID: "review-thread",
            model: "gpt-5"
        )
        let attempt = await backend.reviewAttemptForTesting(run)

        await transport.finishNotificationStreams(throwing: termination)

        do {
            _ = try await attempt.events.next()
            Issue.record("A connection termination did not end the event mailbox.")
        } catch let failure as BackendReviewEventMailboxError {
            #expect(failure.failure == expected)
        }
        await transport.close()
    }

    @Test func concurrentRecoveryPreparationClaimsTheCandidateOnce() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInterruptInitialize(transport)
        await transport.enqueueFailure(.closed, for: "thread/rollback")
        await transport.enqueueFailure(.closed, for: "thread/rollback")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let (candidate, _) = try await makeAppServerRecoveryCandidate()
        let alias = candidate

        async let first = prepareRecovery(backend, candidate: candidate)
        async let second = prepareRecovery(backend, candidate: alias)
        let results = await [first, second]
        let handoffs = results.compactMap { result -> ReviewRecoveryHandoff? in
            guard case .prepared(let handoff) = result else { return nil }
            return handoff
        }

        #expect(handoffs.count == 1)
        #expect(results.filter { $0 == .alreadyPrepared }.count == 1)
        for handoff in handoffs {
            await #expect(throws: JSONRPC.Error.closed) {
                try await backend.resumeReviewRecovery(
                    handoff,
                    request: makeRecoveryStartRequest(),
                    admission: ReviewStartAdmission()
                )
            }
        }
        let rollbackCount = await transport.recordedRequests()
            .filter { $0.method == "thread/rollback" }
            .count
        #expect(rollbackCount == 1)
        await transport.close()
    }

    @Test func typedRecoveryRollbackTransportFailureConsumesHandoffWithoutRetry() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInterruptInitialize(transport)
        await transport.enqueueFailure(.closed, for: "thread/rollback")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let (handoff, predecessor) = try await makePreparedRecoveryHandoff(backend)
        let admission = ReviewStartAdmission()

        await #expect(throws: JSONRPC.Error.closed) {
            try await backend.resumeReviewRecovery(
                handoff,
                request: makeRecoveryStartRequest(),
                admission: admission
            )
        }
        #expect(await admission.currentPhase() == .rollingBackRecovery(
            predecessorRun: predecessor
        ))

        await #expect(throws: ReviewRecoveryHandoffAlreadyConsumed()) {
            try await backend.resumeReviewRecovery(
                handoff,
                request: makeRecoveryStartRequest(),
                admission: ReviewStartAdmission()
            )
        }
        let methods = await transport.recordedRequests().map(\.method)
        #expect(methods.filter { $0 == "thread/rollback" }.count == 1)
        #expect(methods.contains("review/start") == false)
        await transport.close()
    }

    @Test func typedRecoveryResumeRejectsNonFreshAdmissionBeforeRollbackSend() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInterruptInitialize(transport)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let (handoff, _) = try await makePreparedRecoveryHandoff(backend)
        let (nonFreshAdmission, _) = try await makeAppServerInterruptAdmission()

        await #expect(throws: ReviewStartAdmissionContractFailure.self) {
            try await backend.resumeReviewRecovery(
                handoff,
                request: makeRecoveryStartRequest(),
                admission: nonFreshAdmission
            )
        }
        #expect(await transport.recordedRequests().map(\.method) == ["initialize"])
        await transport.close()
    }

    @Test func typedRecoveryResumeUsesFreshAdmissionWithoutThreadStart() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInterruptInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "replacement-turn",
                reviewThreadID: "review-thread"
            ),
            for: "review/start"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let (handoff, _) = try await makePreparedRecoveryHandoff(backend)
        let admission = ReviewStartAdmission()

        let attempt = try await backend.resumeReviewRecovery(
            handoff,
            request: makeRecoveryStartRequest(),
            admission: admission
        )

        #expect(await admission.currentPhase() == .active(attempt.run))
        #expect(await transport.recordedRequests().map(\.method) == [
            "initialize",
            "thread/rollback",
            "review/start",
        ])
        await transport.close()
    }

    @Test func typedRecoveryResumeIsJoinedByRuntimeOwnerClose() async throws {
        let transport = FakeJSONRPCTransport()
        let rollbackGate = AsyncGate()
        try await enqueueInterruptInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        await transport.hold(method: "thread/rollback", gate: rollbackGate)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let (handoff, _) = try await makePreparedRecoveryHandoff(backend)
        let resume = Task {
            try await backend.resumeReviewRecovery(
                handoff,
                request: makeRecoveryStartRequest(),
                admission: ReviewStartAdmission()
            )
        }
        await transport.waitForRequestCount(2)

        let closeCompletion = CloseCompletionProbe()
        let close = Task {
            try await backend.runtimeOwnerLifecycleHandle.closeAndWait()
            await closeCompletion.record()
        }
        await backend.waitForAdmittedReviewOperationDrainForTesting()
        #expect(await closeCompletion.count() == 0)

        await rollbackGate.open()
        await #expect(throws: (any Error).self) {
            try await resume.value
        }
        try await close.value
        #expect(await closeCompletion.count() == 1)
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

private func makePreparedRecoveryHandoff(
    _ backend: AppServerCodexReviewBackend
) async throws -> (
    handoff: ReviewRecoveryHandoff,
    predecessor: CodexReviewBackendModel.Review.Run
) {
    let (candidate, run) = try await makeAppServerRecoveryCandidate()
    return (try await backend.prepareReviewRecovery(candidate), run)
}

private func makeAppServerRecoveryCandidate() async throws -> (
    candidate: ReviewRecoveryCandidate,
    predecessor: CodexReviewBackendModel.Review.Run
) {
    let (admission, run) = try await makeAppServerInterruptAdmission()
    try await admission.recordCanonicalTerminal(
        .interrupted(.server(message: "Recover")),
        for: run
    )
    guard case .replacement(let candidate) = try await admission.beginRecovery(
        run,
        trigger: .recoverableNetworkLoss,
        request: { _, _ in Issue.record("Resolved attempt dispatched an interrupt.") }
    ) else {
        throw ReviewAttemptContractFailure(message: "Expected recovery candidate.")
    }
    return (candidate, run)
}

private func makeRecoveryStartRequest() -> CodexReviewBackendModel.Review.Start {
    .init(
        jobID: "replacement-job",
        sessionID: "replacement-session",
        request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
        model: "gpt-5"
    )
}

private enum RecoveryPreparationResult: Equatable, Sendable {
    case prepared(ReviewRecoveryHandoff)
    case alreadyPrepared
    case otherFailure(String)
}

private func prepareRecovery(
    _ backend: AppServerCodexReviewBackend,
    candidate: ReviewRecoveryCandidate
) async -> RecoveryPreparationResult {
    do {
        return .prepared(try await backend.prepareReviewRecovery(candidate))
    } catch is ReviewRecoveryCandidateAlreadyPrepared {
        return .alreadyPrepared
    } catch {
        return .otherFailure(error.localizedDescription)
    }
}

private actor CloseCompletionProbe {
    private var value = 0

    func record() {
        value += 1
    }

    func count() -> Int { value }
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

private struct InterruptTurnNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(threadID, forKey: .threadID)
        try container.encode(Turn(id: turnID), forKey: .turn)
    }

    private struct Turn: Encodable {
        var id: String
        var items: [String] = []
        var itemsView = "notLoaded"
        var status = "inProgress"
    }
}
