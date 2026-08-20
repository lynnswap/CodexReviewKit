import Foundation
import Testing
@testable import CodexReview
import CodexReviewTesting

@Suite("Review attempt processor")
struct ReviewAttemptProcessorTests {
    @Test func interruptAckBeforeTerminalRemainsInterrupting() async throws {
        let (admission, run) = try await makeActiveAdmission()
        let requestReturned = InvocationProbe()

        let cancellation = Task {
            try await admission.cancel(
                .mcpClient(message: "Stop"),
                interrupt: { _, _ in await requestReturned.record() },
                forceClose: {}
            )
        }
        await requestReturned.waitForInvocation()

        #expect(await admission.currentPhase() == .interrupting(run))
        try await admission.recordCanonicalTerminal(
            .interrupted(.requested(.mcpClient(message: "Stop"))),
            for: run
        )
        let resolution = try await cancellation.value

        #expect(resolution.terminal == .canonical(
            .interrupted(.requested(.mcpClient(message: "Stop")))
        ))
        #expect(await admission.currentPhase() == .terminal(resolution.terminal))
    }

    @Test func terminalBeforeInterruptAckRetainsAndDrainsRequestTask() async throws {
        let (admission, run) = try await makeActiveAdmission()
        let requestStarted = InvocationProbe()
        let requestGate = AsyncGate()

        let cancellation = Task {
            try await admission.cancel(
                .mcpClient(message: "Stop"),
                interrupt: { _, _ in
                    await requestStarted.record()
                    await requestGate.waitIgnoringCancellation()
                },
                forceClose: {}
            )
        }
        await requestStarted.waitForInvocation()
        try await admission.recordCanonicalTerminal(.completed, for: run)

        #expect(await admission.currentPhase() == .finishing(.canonical(.completed)))
        await requestGate.open()
        let resolution = try await cancellation.value

        #expect(resolution.terminal == .canonical(.completed))
    }

    @Test func explicitRejectionReturnsAttemptToActive() async throws {
        let (admission, run) = try await makeActiveAdmission()
        let rejection = ReviewInterruptRequestFailure(
            outcome: .rejected(code: -32_000, message: "Not active")
        )

        await #expect(throws: rejection) {
            try await admission.cancel(
                .mcpClient(message: "Stop"),
                interrupt: { _, _ in throw rejection },
                forceClose: {}
            )
        }

        #expect(await admission.currentPhase() == .active(run))
        #expect(await admission.cancellationRequest() == nil)

        let retryRequested = InvocationProbe()
        let retry = Task {
            try await admission.cancel(
                .mcpClient(message: "Stop again"),
                interrupt: { _, _ in await retryRequested.record() },
                forceClose: {}
            )
        }
        await retryRequested.waitForInvocation()
        try await admission.recordCanonicalTerminal(
            .interrupted(.requested(.mcpClient(message: "Stop again"))),
            for: run
        )

        #expect(try await retry.value.terminal == .canonical(
            .interrupted(.requested(.mcpClient(message: "Stop again")))
        ))
    }

    @Test func rejectionAfterTerminalCannotRewriteTerminal() async throws {
        let (admission, run) = try await makeActiveAdmission()
        let requestStarted = InvocationProbe()
        let requestGate = AsyncGate()
        let rejection = ReviewInterruptRequestFailure(
            outcome: .rejected(code: -32_000, message: "Already finished")
        )

        let cancellation = Task {
            try await admission.cancel(
                .mcpClient(message: "Stop"),
                interrupt: { _, _ in
                    await requestStarted.record()
                    await requestGate.waitIgnoringCancellation()
                    throw rejection
                },
                forceClose: {}
            )
        }
        await requestStarted.waitForInvocation()
        try await admission.recordCanonicalTerminal(.completed, for: run)
        await requestGate.open()
        let resolution = try await cancellation.value

        #expect(resolution.terminal == .canonical(.completed))
        #expect(resolution.requestFailure == rejection)
    }

    @Test func outcomeUnknownFollowedByCanonicalTerminalReturnsTerminal() async throws {
        let (admission, run) = try await makeActiveAdmission()
        let requestFailed = InvocationProbe()
        let failure = ReviewInterruptRequestFailure(
            outcome: .outcomeUnknown(message: "Response lost")
        )

        let cancellation = Task {
            try await admission.cancel(
                .mcpClient(message: "Stop"),
                interrupt: { _, _ in
                    await requestFailed.record()
                    throw failure
                },
                forceClose: {}
            )
        }
        await requestFailed.waitForInvocation()
        try await admission.recordCanonicalTerminal(
            .interrupted(.requested(.mcpClient(message: "Stop"))),
            for: run
        )
        let resolution = try await cancellation.value

        #expect(resolution.requestFailure == failure)
        #expect(resolution.terminal == .canonical(
            .interrupted(.requested(.mcpClient(message: "Stop")))
        ))
    }

    @Test func outcomeUnknownFollowedByConnectionTerminalPreservesBothDiagnostics() async throws {
        let (admission, _) = try await makeActiveAdmission()
        let requestFailed = InvocationProbe()
        let failure = ReviewInterruptRequestFailure(
            outcome: .outcomeUnknown(message: "Response lost")
        )
        let connection = ReviewRuntimeCloseFailure.connection("Connection ended")

        let cancellation = Task {
            try await admission.cancel(
                .mcpClient(message: "Stop"),
                interrupt: { _, _ in
                    await requestFailed.record()
                    throw failure
                },
                forceClose: {}
            )
        }
        await requestFailed.waitForInvocation()
        try await admission.recordStreamTerminal(.unexpectedConnection(connection))

        do {
            _ = try await cancellation.value
            Issue.record("Expected outcome-unknown cancellation failure.")
        } catch let received as ReviewInterruptRequestFailure {
            #expect(received.outcome == failure.outcome)
            #expect(received.secondaryBarrierDiagnostic == connection.localizedDescription)
        }
        #expect(await admission.currentPhase() == .terminal(.stream(.unexpectedConnection(connection))))
    }

    @Test func recoveryAckWaitsForInterruptedTerminalAndReturnsBarrier() async throws {
        let (admission, run) = try await makeActiveAdmission()
        let requestAccepted = InvocationProbe()
        let recovery = Task {
            try await admission.beginRecovery(
                trigger: .recoverableNetworkLoss,
                interrupt: { _, _ in await requestAccepted.record() },
                forceClose: {}
            )
        }
        await requestAccepted.waitForInvocation()
        #expect(await admission.currentPhase() == .interrupting(run))
        try await admission.recordCanonicalTerminal(
            .interrupted(.server(message: "network recovery")),
            for: run
        )

        guard case .replacement(let candidate) = try await recovery.value else {
            Issue.record("Interrupted recovery terminal must create a replacement candidate.")
            return
        }
        #expect(candidate.resolved.run == run)
        #expect(candidate.resolved.terminal == .canonical(
            .interrupted(.server(message: "network recovery"))
        ))
    }

    @Test func recoveryOutcomeUnknownConnectionReturnsBarrierDiagnostic() async throws {
        let (admission, run) = try await makeActiveAdmission()
        let requestFailed = InvocationProbe()
        let requestFailure = ReviewInterruptRequestFailure(
            outcome: .outcomeUnknown(message: "Response lost")
        )
        let connection = ReviewRuntimeCloseFailure.connection("Connection ended")

        let recovery = Task {
            try await admission.beginRecovery(
                trigger: .recoverableNetworkLoss,
                interrupt: { _, _ in
                    await requestFailed.record()
                    throw requestFailure
                },
                forceClose: {}
            )
        }
        await requestFailed.waitForInvocation()
        try await admission.recordStreamTerminal(.recoverableNetwork(connection))

        guard case .replacement(let candidate) = try await recovery.value else {
            Issue.record("Recoverable connection terminal must create a replacement candidate.")
            return
        }
        #expect(candidate.resolved.run == run)
        #expect(candidate.resolved.terminal == .stream(.recoverableNetwork(connection)))
        #expect(candidate.resolved.requestFailure?.outcome == requestFailure.outcome)
        #expect(candidate.resolved.requestFailure?.secondaryBarrierDiagnostic == connection.localizedDescription)
    }

    @Test func recoveryNaturalTerminalSupersedesReplacement() async throws {
        let (admission, run) = try await makeActiveAdmission()
        let requestAccepted = InvocationProbe()
        let recovery = Task {
            try await admission.beginRecovery(
                trigger: .recoverableNetworkLoss,
                interrupt: { _, _ in await requestAccepted.record() },
                forceClose: {}
            )
        }
        await requestAccepted.waitForInvocation()
        try await admission.recordCanonicalTerminal(.completed, for: run)

        guard case .productTerminal(let product) = try await recovery.value else {
            Issue.record("Natural terminal must supersede replacement.")
            return
        }
        #expect(product.resolved.run == run)
        #expect(product.resolved.terminal == .canonical(.completed))
        #expect(product.productTerminal == .completed)
    }

    @Test func recoveryRejectionReturnsAttemptToActive() async throws {
        let (admission, run) = try await makeActiveAdmission()
        let rejection = ReviewInterruptRequestFailure(
            outcome: .rejected(code: -32_000, message: "Not active")
        )

        await #expect(throws: rejection) {
            try await admission.beginRecovery(
                trigger: .recoverableNetworkLoss,
                interrupt: { _, _ in throw rejection },
                forceClose: {}
            )
        }
        #expect(await admission.currentPhase() == .active(run))
    }

    @Test func graceExpiryForceClosesOnceAndAwaitsConnectionAndRequestCompletion() async throws {
        let graceGate = AsyncGate()
        let (admission, _) = try await makeActiveAdmission(
            closePolicy: controlledClosePolicy(gate: graceGate)
        )
        let requestStarted = InvocationProbe()
        let requestGate = AsyncGate()
        let forceClose = InvocationProbe()
        let connection = ReviewRuntimeCloseFailure.connection("Forced close")

        let cancellation = Task {
            try await admission.cancel(
                .system(message: "Stop"),
                interrupt: { _, _ in
                    await requestStarted.record()
                    await requestGate.waitIgnoringCancellation()
                    throw ReviewInterruptRequestFailure(
                        outcome: .outcomeUnknown(message: "Connection closed before response")
                    )
                },
                forceClose: {
                    await forceClose.record()
                    try await admission.recordStreamTerminal(
                        .ownerForcedConnectionClose(connection)
                    )
                    await requestGate.open()
                }
            )
        }
        await requestStarted.waitForInvocation()
        await graceGate.open()
        await forceClose.waitForInvocation()

        await #expect(throws: ReviewInterruptRequestFailure.self) {
            try await cancellation.value
        }
        #expect(await forceClose.invocationCount() == 1)
        #expect(await admission.currentPhase() == .terminal(
            .stream(.ownerForcedConnectionClose(connection))
        ))
    }

    @Test func forceCloseFailureRemainsTypedAfterOutcomeUnknownRequestCompletes() async throws {
        let graceGate = AsyncGate()
        let (admission, _) = try await makeActiveAdmission(
            closePolicy: controlledClosePolicy(gate: graceGate)
        )
        let requestFailed = InvocationProbe()
        let forceFailure = ReviewRuntimeCloseFailure.process("Process remained alive")

        let cancellation = Task {
            try await admission.cancel(
                .system(message: "Stop"),
                interrupt: { _, _ in
                    await requestFailed.record()
                    throw ReviewInterruptRequestFailure(
                        outcome: .outcomeUnknown(message: "Response lost")
                    )
                },
                forceClose: {
                    throw forceFailure
                }
            )
        }
        await requestFailed.waitForInvocation()
        await graceGate.open()

        await #expect(throws: forceFailure) {
            try await cancellation.value
        }
    }

    @Test func terminalFirstForceCloseFailureCancelsPendingRequestAndPreservesTerminal() async throws {
        let graceGate = AsyncGate()
        let (admission, run) = try await makeActiveAdmission(
            closePolicy: controlledClosePolicy(gate: graceGate)
        )
        let requestStarted = InvocationProbe()
        let requestGate = AsyncGate()
        let requestCancelled = InvocationProbe()
        let forceCloseStarted = InvocationProbe()
        let forceFailure = ReviewRuntimeCloseFailure.process("Process remained alive")

        let cancellation = Task {
            try await admission.cancel(
                .system(message: "Stop"),
                interrupt: { _, _ in
                    await requestStarted.record()
                    do {
                        await requestGate.wait()
                        try Task.checkCancellation()
                    } catch {
                        if error is CancellationError {
                            await requestCancelled.record()
                        }
                        throw error
                    }
                },
                forceClose: {
                    await forceCloseStarted.record()
                    throw forceFailure
                }
            )
        }
        await requestStarted.waitForInvocation()
        try await admission.recordCanonicalTerminal(.completed, for: run)
        await graceGate.open()
        await forceCloseStarted.waitForInvocation()

        await #expect(throws: forceFailure) {
            try await cancellation.value
        }
        #expect(await requestCancelled.invocationCount() == 1)
        #expect(await admission.currentPhase() == .terminal(.canonical(.completed)))
    }

    @Test func duplicateCancellationCallersJoinOneRequest() async throws {
        let (admission, run) = try await makeActiveAdmission()
        let requestStarted = InvocationProbe()
        let requestGate = AsyncGate()

        let first = Task {
            try await admission.cancel(
                .mcpClient(message: "Stop"),
                interrupt: { _, _ in
                    await requestStarted.record()
                    await requestGate.waitIgnoringCancellation()
                },
                forceClose: {}
            )
        }
        await requestStarted.waitForInvocation()
        let second = Task {
            try await admission.cancel(
                .mcpClient(message: "Stop"),
                interrupt: { _, _ in
                    Issue.record("Duplicate caller installed a second interrupt operation.")
                },
                forceClose: {}
            )
        }
        try await admission.recordCanonicalTerminal(
            .interrupted(.requested(.mcpClient(message: "Stop"))),
            for: run
        )
        await requestGate.open()

        #expect(try await first.value == second.value)
        #expect(await requestStarted.invocationCount() == 1)
    }

    @Test func staleAndCrossTurnTerminalsCannotSatisfyBarrier() async throws {
        let (admission, run) = try await makeActiveAdmission()
        let requestReturned = InvocationProbe()
        let cancellation = Task {
            try await admission.cancel(
                .mcpClient(message: "Stop"),
                interrupt: { _, _ in await requestReturned.record() },
                forceClose: {}
            )
        }
        await requestReturned.waitForInvocation()

        var stale = run
        stale.attemptID = "attempt-stale"
        try await admission.recordCanonicalTerminal(.completed, for: stale)
        var child = run
        child.reviewThreadID = "review-child"
        try await admission.recordCanonicalTerminal(.completed, for: child)
        var crossTurn = run
        crossTurn.turnID = "turn-other"
        try await admission.recordCanonicalTerminal(.completed, for: crossTurn)

        #expect(await admission.currentPhase() == .interrupting(run))
        try await admission.recordCanonicalTerminal(.completed, for: run)
        #expect(try await cancellation.value.terminal == .canonical(.completed))
    }

    @Test func conflictingDuplicateTerminalFailsWithoutRewrite() async throws {
        let (admission, run) = try await makeActiveAdmission()
        try await admission.recordCanonicalTerminal(.completed, for: run)

        await #expect(throws: ReviewAttemptContractFailure.self) {
            try await admission.recordCanonicalTerminal(
                .failed(message: "conflict"),
                for: run
            )
        }
        #expect(await admission.currentPhase() == .terminal(.canonical(.completed)))
    }

    @Test func queuedCancellationCompletesLocallyWithoutDispatch() async throws {
        let admission = ReviewStartAdmission(closePolicy: controlledClosePolicy(gate: AsyncGate()))

        let resolution = try await admission.cancel(
            .mcpClient(message: "Stop"),
            interrupt: { _, _ in Issue.record("Queued cancellation dispatched interrupt.") },
            forceClose: { Issue.record("Queued cancellation force-closed connection.") }
        )

        #expect(resolution.terminal == .localCancellation(.mcpClient(message: "Stop")))
    }

    @Test func registeredStartIsBackendInertUntilExactActivation() async throws {
        let admission = ReviewStartAdmission(closePolicy: controlledClosePolicy(gate: AsyncGate()))
        let backendWrite = InvocationProbe()
        let registered = try await admission.registerStart { _ in
            await backendWrite.record()
            return .init(run: canonicalRun)
        }

        await Task.yield()
        #expect(await backendWrite.invocationCount() == 0)
        #expect(await admission.currentPhase() == .registeredStart(registered.id))

        try await admission.activateStart(registered.id)
        _ = try await registered.task.value
        #expect(await backendWrite.invocationCount() == 1)
    }

    @Test func cancellationBetweenRegistrationAndActivationCompletesTaskWithoutWrite() async throws {
        let admission = ReviewStartAdmission(closePolicy: controlledClosePolicy(gate: AsyncGate()))
        let backendWrite = InvocationProbe()
        let cancellation = ReviewCancellation.mcpClient(message: "Stop")
        let registered = try await admission.registerStart { _ in
            await backendWrite.record()
            return .init(run: canonicalRun)
        }

        let resolution = try await admission.cancel(
            cancellation,
            interrupt: { _, _ in Issue.record("Unactivated start dispatched interrupt.") },
            forceClose: { Issue.record("Unactivated start force-closed a connection.") }
        )

        #expect(resolution.terminal == .localCancellation(cancellation))
        await #expect(throws: ReviewStartCancelledBeforeDispatch(cancellation: cancellation)) {
            try await registered.task.value
        }
        #expect(await backendWrite.invocationCount() == 0)
    }

    @Test func cancellationBeforeRegistrationSurvivesRegistrationWithoutWrite() async throws {
        let admission = ReviewStartAdmission(closePolicy: controlledClosePolicy(gate: AsyncGate()))
        let cancellation = ReviewCancellation.mcpClient(message: "Stop")
        _ = try await admission.cancel(
            cancellation,
            interrupt: { _, _ in Issue.record("Queued cancellation dispatched interrupt.") },
            forceClose: {}
        )
        let backendWrite = InvocationProbe()

        let registered = try await admission.registerStart { _ in
            await backendWrite.record()
            return .init(run: canonicalRun)
        }

        await #expect(throws: ReviewStartCancelledBeforeDispatch(cancellation: cancellation)) {
            try await registered.task.value
        }
        #expect(await backendWrite.invocationCount() == 0)
    }

    @Test func streamTerminalBeforeRegistrationSurvivesRegistrationWithoutWrite() async throws {
        let admission = ReviewStartAdmission(closePolicy: controlledClosePolicy(gate: AsyncGate()))
        let failure = ReviewAttemptStreamFailure.unexpectedConnection(
            .connection("Connection ended")
        )
        try await admission.recordStreamTerminal(failure)
        let backendWrite = InvocationProbe()

        let registered = try await admission.registerStart { _ in
            await backendWrite.record()
            return .init(run: canonicalRun)
        }

        await #expect(throws: failure) {
            _ = try await registered.task.value
        }
        #expect(await backendWrite.invocationCount() == 0)
    }

    @Test func activationIsIdempotentForLiveHandleAndRejectsWrongHandle() async throws {
        let admission = ReviewStartAdmission(closePolicy: controlledClosePolicy(gate: AsyncGate()))
        let operationGate = AsyncGate()
        let registered = try await admission.registerStart { _ in
            await operationGate.waitIgnoringCancellation()
            return .init(run: canonicalRun)
        }
        let wrong = ReviewStartHandleID(generation: registered.id.generation + 1)

        await #expect(throws: ReviewAttemptContractFailure.self) {
            try await admission.activateStart(wrong)
        }
        try await admission.activateStart(registered.id)
        try await admission.activateStart(registered.id)
        await operationGate.open()
        _ = try await registered.task.value
        await #expect(throws: ReviewAttemptContractFailure.self) {
            try await admission.activateStart(registered.id)
        }
    }

    @Test func joinedExplicitCancellationInstallsProductDispositionBeforeRecoveryPreparation() async throws {
        let (admission, run) = try await makeActiveAdmission()
        let requestGate = AsyncGate()
        let requestStarted = InvocationProbe()
        let recovery = Task {
            try await admission.beginRecovery(
                trigger: .recoverableNetworkLoss,
                interrupt: { _, _ in
                    await requestStarted.record()
                    await requestGate.waitIgnoringCancellation()
                },
                forceClose: {}
            )
        }
        await requestStarted.waitForInvocation()
        let cancellation = Task {
            try await admission.cancel(
                .mcpClient(message: "Stop"),
                interrupt: { _, _ in Issue.record("Joined cancellation sent a second request.") },
                forceClose: {}
            )
        }
        #expect(await admission.waitForCancellationAdmission() == .mcpClient(message: "Stop"))
        try await admission.recordCanonicalTerminal(
            .interrupted(.server(message: "network recovery")),
            for: run
        )
        await requestGate.open()

        let disposition = try await recovery.value
        guard case .productTerminal(let product) = disposition else {
            Issue.record("Joined explicit cancellation must suppress replacement.")
            return
        }
        #expect(product.resolved.run == run)
        #expect(product.productTerminal == .interrupted(.requested(.mcpClient(message: "Stop"))))
        _ = try await cancellation.value
        #expect(await requestStarted.invocationCount() == 1)
    }

    @Test func joinedCancellationOutcomeUnknownConnectionRetainsTransportProduct() async throws {
        let (admission, run) = try await makeActiveAdmission()
        let requestFailed = InvocationProbe()
        let requestFailure = ReviewInterruptRequestFailure(
            outcome: .outcomeUnknown(message: "Response lost")
        )
        let connection = ReviewRuntimeCloseFailure.connection("Connection ended")
        let recovery = Task {
            try await admission.beginRecovery(
                trigger: .recoverableNetworkLoss,
                interrupt: { _, _ in
                    await requestFailed.record()
                    throw requestFailure
                },
                forceClose: {}
            )
        }
        await requestFailed.waitForInvocation()
        let cancellation = Task {
            try await admission.cancel(
                .mcpClient(message: "Stop"),
                interrupt: { _, _ in Issue.record("Joined cancellation sent a second request.") },
                forceClose: {}
            )
        }
        #expect(await admission.waitForCancellationAdmission() == .mcpClient(message: "Stop"))
        try await admission.recordStreamTerminal(.recoverableNetwork(connection))

        guard case .productTerminal(let product) = try await recovery.value else {
            Issue.record("Outcome-unknown connection plus joined cancel must terminalize product.")
            return
        }
        #expect(product.resolved.run == run)
        #expect(product.resolved.requestFailure?.outcome == requestFailure.outcome)
        #expect(product.productTerminal == .interrupted(.transport(
            message: connection.localizedDescription
        )))
        await #expect(throws: ReviewInterruptRequestFailure.self) {
            _ = try await cancellation.value
        }
    }

    @Test func recoveryClassifiesTypedStreamFailureBeforeTokenization() async throws {
        let (recoverableAdmission, recoverableRun) = try await makeActiveAdmission()
        let recoverableRequest = InvocationProbe()
        let recoverable = Task {
            try await recoverableAdmission.beginRecovery(
                trigger: .recoverableNetworkLoss,
                interrupt: { _, _ in await recoverableRequest.record() },
                forceClose: {}
            )
        }
        await recoverableRequest.waitForInvocation()
        try await recoverableAdmission.recordStreamTerminal(
            .recoverableNetwork(.connection("offline"))
        )
        guard case .replacement(let candidate) = try await recoverable.value else {
            Issue.record("Verified network failure must produce a replacement candidate.")
            return
        }
        #expect(candidate.resolved.run == recoverableRun)

        let (protocolAdmission, protocolRun) = try await makeActiveAdmission()
        let protocolFailure = ReviewAttemptContractFailure(message: "invalid notification")
        let protocolRequest = InvocationProbe()
        let nonrecoverable = Task {
            try await protocolAdmission.beginRecovery(
                trigger: .recoverableNetworkLoss,
                interrupt: { _, _ in await protocolRequest.record() },
                forceClose: {}
            )
        }
        await protocolRequest.waitForInvocation()
        try await protocolAdmission.recordStreamTerminal(.protocolViolation(protocolFailure))
        guard case .productTerminal(let product) = try await nonrecoverable.value else {
            Issue.record("Protocol failure must terminalize the product.")
            return
        }
        #expect(product.resolved.run == protocolRun)
        #expect(product.resolved.terminal == .stream(.protocolViolation(protocolFailure)))
        #expect(product.productTerminal == .failed(message: protocolFailure.message))
    }

    @Test func threadStartDispatchAdmissionRejectsDirectDuplicate() async throws {
        let admission = ReviewStartAdmission(closePolicy: controlledClosePolicy(gate: AsyncGate()))
        let startGate = AsyncGate()
        let startTask = try await registerAndActivateStart(admission) { _ in
            await startGate.waitIgnoringCancellation()
            return .init(run: canonicalRun)
        }

        #expect(await admission.admitThreadStartDispatch())
        #expect(await admission.admitThreadStartDispatch() == false)

        await startGate.open()
        _ = try await startTask.value
    }

    @Test func threadStartDispatchAdmissionAllowsVerifiedRejectionRetry() async throws {
        let admission = ReviewStartAdmission(closePolicy: controlledClosePolicy(gate: AsyncGate()))
        let startGate = AsyncGate()
        let startTask = try await registerAndActivateStart(admission) { _ in
            await startGate.waitIgnoringCancellation()
            return .init(run: canonicalRun)
        }

        #expect(await admission.admitThreadStartDispatch())
        try await admission.recordThreadStartRejectedForRetry()
        #expect(await admission.admitThreadStartDispatch())
        #expect(await admission.admitThreadStartDispatch() == false)

        await startGate.open()
        _ = try await startTask.value
    }

    @Test func reviewStartDispatchAdmissionRejectsDirectDuplicate() async throws {
        let admission = ReviewStartAdmission(closePolicy: controlledClosePolicy(gate: AsyncGate()))
        let startGate = AsyncGate()
        let startTask = try await registerAndActivateStart(admission) { _ in
            await startGate.waitIgnoringCancellation()
            return .init(run: canonicalRun)
        }
        #expect(await admission.admitThreadStartDispatch())
        await admission.recordPreparedThread(provisionalRun)

        #expect(await admission.admitReviewStartDispatch(for: provisionalRun))
        #expect(await admission.admitReviewStartDispatch(for: provisionalRun) == false)

        await startGate.open()
        _ = try await startTask.value
    }

    @Test func generalStartFailureEndsAdmissionWaiters() async throws {
        let failure = ReviewAttemptContractFailure(message: "Start failed")
        let admission = ReviewStartAdmission(closePolicy: controlledClosePolicy(gate: AsyncGate()))
        let startTask = try await registerAndActivateStart(admission) { _ in
            throw failure
        }

        await #expect(throws: failure) {
            try await startTask.value
        }
        #expect(await admission.waitForActiveRun() == nil)
        #expect(await admission.waitForCancellationAdmission() == nil)
    }

    @Test func cancellationBeforeThreadDispatchRefusesWrite() async throws {
        let admission = ReviewStartAdmission(closePolicy: controlledClosePolicy(gate: AsyncGate()))
        let entered = InvocationProbe()
        let dispatchGate = AsyncGate()
        let startTask = try await registerAndActivateStart(admission) { admission in
            await entered.record()
            await dispatchGate.wait()
            try Task.checkCancellation()
            guard await admission.admitThreadStartDispatch() else {
                throw ReviewStartCancelledBeforeDispatch(
                    cancellation: await admission.cancellationRequest() ?? .system()
                )
            }
            Issue.record("Thread request was dispatched after cancellation.")
            return .init(run: canonicalRun)
        }
        await entered.waitForInvocation()

        let resolution = try await admission.cancel(
            .mcpClient(message: "Stop"),
            interrupt: { _, _ in Issue.record("Pre-dispatch cancellation interrupted a turn.") },
            forceClose: {}
        )

        #expect(resolution.terminal == .localCancellation(.mcpClient(message: "Stop")))
        await #expect(throws: CancellationError.self) {
            try await startTask.value
        }
    }

    @Test func cancellationAfterThreadDispatchRefusesReviewDispatchAfterResponse() async throws {
        let graceGate = AsyncGate()
        let admission = ReviewStartAdmission(closePolicy: controlledClosePolicy(gate: graceGate))
        let threadDispatched = InvocationProbe()
        let threadResponseGate = AsyncGate()
        let startTask = try await registerAndActivateStart(admission) { admission in
            #expect(await admission.admitThreadStartDispatch())
            await threadDispatched.record()
            await threadResponseGate.waitIgnoringCancellation()
            let provisional = provisionalRun
            await admission.recordPreparedThread(provisional)
            guard await admission.admitReviewStartDispatch(for: provisional) else {
                throw ReviewStartCancelledBeforeDispatch(
                    cancellation: await admission.cancellationRequest() ?? .system()
                )
            }
            Issue.record("Review request was dispatched after cancellation.")
            return .init(run: canonicalRun)
        }
        await threadDispatched.waitForInvocation()

        let cancellation = Task {
            try await admission.cancel(
                .mcpClient(message: "Stop"),
                interrupt: { _, _ in Issue.record("Thread-only attempt interrupted an empty turn.") },
                forceClose: {}
            )
        }
        #expect(await admission.waitForCancellationAdmission() == .mcpClient(message: "Stop"))
        await threadResponseGate.open()

        #expect(try await cancellation.value.terminal == .localCancellation(.mcpClient(message: "Stop")))
        await #expect(throws: ReviewStartCancelledBeforeDispatch.self) {
            try await startTask.value
        }
    }

    @Test func cancellationAfterOutcomeUnknownThreadDispatchDrainsThroughForcedConnectionTerminal() async throws {
        let graceGate = AsyncGate()
        let admission = ReviewStartAdmission(closePolicy: controlledClosePolicy(gate: graceGate))
        let threadDispatched = InvocationProbe()
        let threadResponseGate = AsyncGate()
        let forceClose = InvocationProbe()
        let connection = ReviewRuntimeCloseFailure.connection("Forced close")
        let startTask = try await registerAndActivateStart(admission) { admission in
            #expect(await admission.admitThreadStartDispatch())
            await threadDispatched.record()
            await threadResponseGate.wait()
            try Task.checkCancellation()
            Issue.record("Thread request outlived its typed connection terminal.")
            return .init(run: canonicalRun)
        }
        await threadDispatched.waitForInvocation()

        let cancellation = Task {
            try await admission.cancel(
                .system(message: "Stop"),
                interrupt: { _, _ in Issue.record("Thread-only attempt interrupted a turn.") },
                forceClose: {
                    await forceClose.record()
                    try await admission.recordStreamTerminal(
                        .ownerForcedConnectionClose(connection)
                    )
                }
            )
        }
        #expect(await admission.waitForCancellationAdmission() == .system(message: "Stop"))
        await graceGate.open()
        await forceClose.waitForInvocation()

        #expect(try await cancellation.value.terminal == .stream(
            .ownerForcedConnectionClose(connection)
        ))
        await #expect(throws: CancellationError.self) {
            try await startTask.value
        }
    }

    @Test func cancellationAfterThreadResponseRefusesNotSentReviewDispatch() async throws {
        let admission = ReviewStartAdmission(closePolicy: controlledClosePolicy(gate: AsyncGate()))
        let prepared = InvocationProbe()
        let reviewDispatchGate = AsyncGate()
        let startTask = try await registerAndActivateStart(admission) { admission in
            #expect(await admission.admitThreadStartDispatch())
            await admission.recordPreparedThread(provisionalRun)
            await prepared.record()
            await reviewDispatchGate.waitIgnoringCancellation()
            guard await admission.admitReviewStartDispatch(for: provisionalRun) else {
                throw ReviewStartCancelledBeforeDispatch(
                    cancellation: await admission.cancellationRequest() ?? .system()
                )
            }
            Issue.record("Review request was dispatched after cancellation.")
            return .init(run: canonicalRun)
        }
        await prepared.waitForInvocation()

        let cancellation = Task {
            try await admission.cancel(
                .mcpClient(message: "Stop"),
                interrupt: { _, _ in Issue.record("Not-sent review was interrupted.") },
                forceClose: {}
            )
        }
        #expect(await admission.waitForCancellationAdmission() == .mcpClient(message: "Stop"))
        await reviewDispatchGate.open()

        #expect(try await cancellation.value.terminal == .localCancellation(.mcpClient(message: "Stop")))
        await #expect(throws: ReviewStartCancelledBeforeDispatch.self) {
            try await startTask.value
        }
    }

    @Test func cancellationAfterReviewDispatchJoinsResponseThenInterruptsCanonicalRun() async throws {
        let graceGate = AsyncGate()
        let admission = ReviewStartAdmission(closePolicy: controlledClosePolicy(gate: graceGate))
        let reviewDispatched = InvocationProbe()
        let reviewResponseGate = AsyncGate()
        let interruptCalled = InvocationProbe()
        let startTask = try await registerAndActivateStart(admission) { admission in
            #expect(await admission.admitThreadStartDispatch())
            await admission.recordPreparedThread(provisionalRun)
            #expect(await admission.admitReviewStartDispatch(for: provisionalRun))
            await reviewDispatched.record()
            await reviewResponseGate.waitIgnoringCancellation()
            await admission.recordActiveRun(canonicalRun)
            return .init(run: canonicalRun)
        }
        await reviewDispatched.waitForInvocation()

        let cancellation = Task {
            try await admission.cancel(
                .mcpClient(message: "Stop"),
                interrupt: { run, _ in
                    #expect(run == canonicalRun)
                    await interruptCalled.record()
                },
                forceClose: {}
            )
        }
        await reviewResponseGate.open()
        _ = try await startTask.value
        await interruptCalled.waitForInvocation()
        try await admission.recordCanonicalTerminal(
            .interrupted(.requested(.mcpClient(message: "Stop"))),
            for: canonicalRun
        )

        #expect(try await cancellation.value.terminal == .canonical(
            .interrupted(.requested(.mcpClient(message: "Stop")))
        ))
    }

    @Test func cancellationAfterOutcomeUnknownReviewDispatchDrainsThroughForcedConnectionTerminal() async throws {
        let graceGate = AsyncGate()
        let admission = ReviewStartAdmission(closePolicy: controlledClosePolicy(gate: graceGate))
        let reviewDispatched = InvocationProbe()
        let reviewResponseGate = AsyncGate()
        let forceClose = InvocationProbe()
        let connection = ReviewRuntimeCloseFailure.connection("Forced close")
        let startTask = try await registerAndActivateStart(admission) { admission in
            #expect(await admission.admitThreadStartDispatch())
            await admission.recordPreparedThread(provisionalRun)
            #expect(await admission.admitReviewStartDispatch(for: provisionalRun))
            await reviewDispatched.record()
            await reviewResponseGate.wait()
            try Task.checkCancellation()
            Issue.record("Review request outlived its typed connection terminal.")
            return .init(run: canonicalRun)
        }
        await reviewDispatched.waitForInvocation()

        let cancellation = Task {
            try await admission.cancel(
                .system(message: "Stop"),
                interrupt: { _, _ in Issue.record("Unresolved review request interrupted a turn.") },
                forceClose: {
                    await forceClose.record()
                    try await admission.recordStreamTerminal(
                        .ownerForcedConnectionClose(connection)
                    )
                }
            )
        }
        #expect(await admission.waitForCancellationAdmission() == .system(message: "Stop"))
        await graceGate.open()
        await forceClose.waitForInvocation()

        #expect(try await cancellation.value.terminal == .stream(
            .ownerForcedConnectionClose(connection)
        ))
        await #expect(throws: CancellationError.self) {
            try await startTask.value
        }
    }

    @Test func duplicateCleanupCallersJoinOneOwnedTask() async throws {
        let (admission, run) = try await makeActiveAdmission()
        let cleanupStarted = InvocationProbe()
        let cleanupGate = AsyncGate()

        let first = Task {
            try await admission.cleanup(run: run) {
                await cleanupStarted.record()
                await cleanupGate.waitIgnoringCancellation()
            }
        }
        await cleanupStarted.waitForInvocation()
        let second = Task {
            try await admission.cleanup(run: run) {
                Issue.record("Duplicate cleanup caller installed a second cleanup Task.")
            }
        }
        await cleanupGate.open()
        _ = try await (first.value, second.value)

        #expect(await cleanupStarted.invocationCount() == 1)
    }
}

private let canonicalRun = CodexReviewBackendModel.Review.Run(
    attemptID: "attempt-1",
    threadID: "thread-1",
    turnID: "turn-1",
    reviewThreadID: "review-thread-1",
    model: "gpt-5"
)

private let provisionalRun = CodexReviewBackendModel.Review.Run(
    attemptID: "attempt-1",
    threadID: "thread-1",
    reviewThreadID: "thread-1",
    model: "gpt-5"
)

private func makeActiveAdmission(
    closePolicy: ReviewRuntimeClosePolicy? = nil
) async throws -> (ReviewStartAdmission, CodexReviewBackendModel.Review.Run) {
    let admission = ReviewStartAdmission(
        closePolicy: closePolicy ?? controlledClosePolicy(gate: AsyncGate())
    )
    let startTask = try await registerAndActivateStart(admission) { admission in
        #expect(await admission.admitThreadStartDispatch())
        await admission.recordPreparedThread(provisionalRun)
        #expect(await admission.admitReviewStartDispatch(for: provisionalRun))
        await admission.recordActiveRun(canonicalRun)
        return .init(run: canonicalRun)
    }
    _ = try await startTask.value
    return (admission, canonicalRun)
}

private func registerAndActivateStart(
    _ admission: ReviewStartAdmission,
    operation: @escaping @Sendable (ReviewStartAdmission) async throws -> BackendReviewAttempt
) async throws -> Task<BackendReviewAttempt, any Error> {
    let registered = try await admission.registerStart(operation)
    try await admission.activateStart(registered.id)
    return registered.task
}

private func controlledClosePolicy(gate: AsyncGate) -> ReviewRuntimeClosePolicy {
    ReviewRuntimeClosePolicy(terminalGrace: .seconds(10)) { _ in
        await gate.wait()
        try Task.checkCancellation()
    }
}

private actor InvocationProbe {
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record() {
        count += 1
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForInvocation() async {
        if count > 0 {
            return
        }
        await withCheckedContinuation { continuation in
            if count > 0 {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func invocationCount() -> Int { count }
}
