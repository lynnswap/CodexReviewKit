import Foundation
import Testing
import CodexAppServerKit
import CodexAppServerKitTesting
import CodexDataKit
@testable import CodexReviewAppServer
import CodexReviewKit

@Suite("AppServerClientTests")
struct AppServerClientTests {
    @Test func backendStartsReviewThroughExternalCodexKit() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "thread-1")
        let backend = await makeBackend(appServer: runtime.server)

        let attempt = try await backend.startReview(makeReviewStart(target: .uncommittedChanges))

        #expect(attempt.attempt.threadIdentity.sourceThreadID.rawValue == "thread-1")
        #expect(attempt.attempt.turnID.rawValue == "turn-1")
        #expect(attempt.attempt.threadIdentity.activeTurnThreadID.rawValue == "thread-1")

        let requests = await runtime.transport.recordedRequests()
        #expect(requests.map(\.request.operation) == [
            .initialize,
            .threadStart,
            .reviewStart,
        ])

        let threadStart = try #require(requests.compactMap { request
            -> (URL, CodexInstructions?, CodexThread.Options)? in
            guard case .threadStart(let workspace, let instructions, let options) = request.request
            else { return nil }
            return (workspace, instructions, options)
        }.first)
        #expect(threadStart.0.path == "/tmp/project")
        #expect(threadStart.1 == nil)
        #expect(threadStart.2.model == "gpt-5")
        #expect(threadStart.2.ephemeral == false)
        #expect(threadStart.2.approvalMode == .denyAll)
        #expect(threadStart.2.permissions == .profile(id: ":danger-full-access"))
        #expect(threadStart.2.sessionStartSource == .startup)
        #expect(threadStart.2.threadSource == .user)
        #expect(threadStart.2.sandbox == nil)

        let reviewStart = try #require(requests.compactMap { request
            -> (CodexThreadID, CodexReviewTarget, CodexReviewDelivery)? in
            guard case .reviewStart(let threadID, let target, let delivery) = request.request
            else { return nil }
            return (threadID, target, delivery)
        }.first)
        #expect(reviewStart.0 == "thread-1")
        #expect(reviewStart.1 == .uncommittedChanges)
        #expect(reviewStart.2 == .inline)
    }

    @Test func backendConsumesTypedReviewSessionStream() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "thread-1")
        await runtime.transport.waitForNotificationStreamCount(1)
        let backend = await makeBackend(appServer: runtime.server)

        let attempt = try await backend.startReview(makeReviewStart(target: .baseBranch("main")))

        try await runtime.notificationEmitter.emitItemCompleted(
            threadID: "thread-1",
            turnID: "turn-1",
            item: .commandExecution(
                id: "cmd-1",
                command: "swift test",
                cwd: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
                status: .completed,
                aggregatedOutput: "passed"
            )
        )
        try await emitTurn(
            on: runtime,
            threadID: "thread-1",
            turnID: "turn-1",
            state: .completed,
            items: [
                .exitedReviewMode(id: "review-output", review: "Looks good."),
            ]
        )

        let observed = try await withTimeout {
            try await attempt.observeTerminal()
        }
        let turnID = try makeTurnID("turn-1")
        #expect(
            observed == .completed(.init(
                turnID: turnID,
                expectedOutput: try NonEmptyReviewOutput(validating: "Looks good.")
            ))
        )
        #expect(await runtime.transport.recordedRequests(for: .threadRead).isEmpty)

        try await enqueueReviewProjection(
            transport: runtime.transport,
            threadID: "thread-1",
            turnID: "turn-1",
            output: "Looks good."
        )
        #expect(
            await attempt.finalizeTerminal(observed)
                == .completed(.init(
                    finalReview: try NonEmptyReviewOutput(validating: "Looks good.")
                ))
        )
        #expect(await runtime.transport.recordedRequests(for: .threadRead).count == 1)
    }

    @Test func completionPublicationFinishesAfterFinalizerCallerCancellation() async throws {
        let fixture = try await makeCompletedReviewFixture(output: "Looks good.")
        try await enqueueReviewProjection(
            transport: fixture.runtime.transport,
            threadID: "thread-1",
            turnID: "turn-1",
            output: "Looks good."
        )
        let refreshGate = CodexAppServerTestGate()
        await fixture.runtime.transport.holdNextIgnoringCancellation(
            .threadRead,
            gate: refreshGate
        )

        let finalization = Task {
            await fixture.attempt.finalizeTerminal(fixture.observed)
        }
        await fixture.runtime.transport.waitForRequest(.threadRead)
        await refreshGate.waitUntilBlocked()
        finalization.cancel()
        await refreshGate.open()

        #expect(
            await finalization.value
                == .completed(.init(
                    finalReview: try NonEmptyReviewOutput(validating: "Looks good.")
                ))
        )
        #expect(
            await fixture.runtime.transport.recordedRequests(for: .threadRead).count == 1
        )
    }

    @Test(arguments: ReviewPublicationFailureScenario.allCases)
    func completionPublicationMapsTypedFailure(
        _ scenario: ReviewPublicationFailureScenario
    ) async throws {
        let fixture = try await makeCompletedReviewFixture(output: "Expected output")
        switch scenario {
        case .turnUnavailable:
            try await enqueueReviewProjection(
                transport: fixture.runtime.transport,
                threadID: "thread-1",
                turnID: nil,
                output: nil
            )
        case .outputMissing:
            try await enqueueReviewProjection(
                transport: fixture.runtime.transport,
                threadID: "thread-1",
                turnID: "turn-1",
                output: nil
            )
        case .outputEmpty:
            try await enqueueReviewProjection(
                transport: fixture.runtime.transport,
                threadID: "thread-1",
                turnID: "turn-1",
                output: "   "
            )
        case .outputMismatch:
            try await enqueueReviewProjection(
                transport: fixture.runtime.transport,
                threadID: "thread-1",
                turnID: "turn-1",
                output: "Different output"
            )
        case .refreshFailure:
            try await fixture.runtime.transport.enqueueFailure(
                .response(code: -32_000, message: "projection unavailable"),
                for: .threadRead
            )
        }

        let terminal = await fixture.attempt.finalizeTerminal(fixture.observed)
        guard case .failed(.outputPublication(let failure)) = terminal else {
            Issue.record("Expected a typed output-publication failure, got \(terminal).")
            return
        }
        let turnID = try makeTurnID("turn-1")
        switch (scenario, failure) {
        case (.turnUnavailable, .unavailable(let actualTurnID)):
            #expect(actualTurnID == turnID)
        case (.outputMissing, .empty(let actualTurnID)),
            (.outputEmpty, .empty(let actualTurnID)):
            #expect(actualTurnID == turnID)
        case (.outputMismatch, .mismatched(let actualTurnID)):
            #expect(actualTurnID == turnID)
        case (.refreshFailure, .refreshFailed(let actualTurnID, let message)):
            #expect(actualTurnID == turnID)
            #expect(message.contains("projection unavailable"))
        default:
            Issue.record("Unexpected publication mapping \(failure) for \(scenario).")
        }
        #expect(
            await fixture.runtime.transport.recordedRequests(for: .threadRead).count == 1
        )
    }

    @Test func backendCompletesReviewFromExitedReviewModeWhenTerminalPayloadIsSparse() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "thread-1")
        await runtime.transport.waitForNotificationStreamCount(1)
        let backend = await makeBackend(appServer: runtime.server)

        let attempt = try await backend.startReview(makeReviewStart(target: .baseBranch("main")))

        try await runtime.notificationEmitter.emitItemCompleted(
            threadID: "thread-1",
            turnID: "turn-1",
            item: .exitedReviewMode(id: "review-output", review: "No issues found.")
        )
        try await emitTurn(
            on: runtime,
            threadID: "thread-1",
            turnID: "turn-1",
            state: .completed,
            itemsLoadState: .notLoaded
        )

        #expect(
            try await attempt.observeTerminal()
                == .completed(.init(
                    turnID: makeTurnID("turn-1"),
                    expectedOutput: try NonEmptyReviewOutput(validating: "No issues found.")
                ))
        )
    }

    @Test func backendSurfacesTransportContractViolationAsConnectionTermination() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "thread-1")
        await runtime.transport.waitForNotificationStreamCount(1)
        let backend = await makeBackend(appServer: runtime.server)

        let attempt = try await backend.startReview(makeReviewStart(target: .baseBranch("main")))

        await runtime.transport.failConnection(.contractViolation(
            message: "Current-v2 notification is missing required field turnId."
        ))
        let observed = try await attempt.observeTerminal()
        guard case .failed(.connectionTerminated(.transport(let message))) = observed else {
            Issue.record(
                "Expected a typed connection termination for the malformed stream, got \(observed)."
            )
            return
        }
        #expect(message.contains("Current-v2 notification is missing required field turnId."))
    }

    @Test func backendDoesNotPromoteAgentMessageToInlineReview() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "thread-1")
        await runtime.transport.waitForNotificationStreamCount(1)
        let backend = await makeBackend(appServer: runtime.server)

        let attempt = try await backend.startReview(makeReviewStart(target: .baseBranch("main")))

        try await runtime.notificationEmitter.emitItemCompleted(
            threadID: "thread-1",
            turnID: "turn-1",
            item: .agentMessage(id: "message-1", text: "Looks good.")
        )
        try await emitTurn(
            on: runtime,
            threadID: "thread-1",
            turnID: "turn-1",
            state: .completed
        )

        #expect(
            try await attempt.observeTerminal()
                == .failed(.missingReviewOutput(turnID: makeTurnID("turn-1"))))
    }

    @Test func backendFailsCompletedReviewWithoutReviewOutput() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "thread-1")
        await runtime.transport.waitForNotificationStreamCount(1)
        let backend = await makeBackend(appServer: runtime.server)

        let attempt = try await backend.startReview(makeReviewStart(target: .baseBranch("main")))

        try await emitTurn(
            on: runtime,
            threadID: "thread-1",
            turnID: "turn-1",
            state: .completed
        )

        #expect(
            try await attempt.observeTerminal()
                == .failed(.missingReviewOutput(turnID: makeTurnID("turn-1"))))
    }

    @Test func backendPreservesTypedTurnFailure() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "thread-1")
        await runtime.transport.waitForNotificationStreamCount(1)
        let backend = await makeBackend(appServer: runtime.server)

        let attempt = try await backend.startReview(makeReviewStart())

        try await emitTurn(
            on: runtime,
            threadID: "thread-1",
            turnID: "turn-1",
            state: .failed(.init(
                message: "Capacity exhausted.",
                info: .serverOverloaded,
                additionalDetails: "retry after the maintenance window"
            ))
        )

        #expect(
            try await attempt.observeTerminal()
                == .failed(
                    .turnFailed(
                        .init(
                            message: "Capacity exhausted.",
                            code: .serverOverloaded,
                            additionalDetails: "retry after the maintenance window"
                        )
                    )
                )
        )
    }

    @Test func backendKeepsServerInterruptionDistinctFromCallerCancellation() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "thread-1")
        await runtime.transport.waitForNotificationStreamCount(1)
        let backend = await makeBackend(appServer: runtime.server)

        let attempt = try await backend.startReview(makeReviewStart())

        try await emitTurn(
            on: runtime,
            threadID: "thread-1",
            turnID: "turn-1",
            state: .interrupted
        )

        #expect(try await attempt.observeTerminal() == .interrupted(message: nil))
    }

    @Test func terminalMapperPreservesUnknownTerminalStatusError() throws {
        let attempt = try makeReviewAttempt(
            attemptID: "attempt-1",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "thread-1"
        )
        let outcome = CodexTurnOutcome.invalidTerminalStatus(
            rawStatus: "pausedByFutureServer",
            error: .init(
                message: "Future terminal detail.",
                info: .unknown(rawValue: "futureErrorCode"),
                additionalDetails: "future additional detail"
            ),
            response: .init(turnID: "turn-1")
        )
        let expectedTurnID = try makeTurnID("turn-1")

        #expect(
            AppServerReviewTerminalMapper.observed(
                outcome,
                expectedAttempt: attempt
            )
                == .failed(
                    .invalidTerminalStatus(
                        rawStatus: "pausedByFutureServer",
                        turnID: expectedTurnID,
                        turnFailure: .init(
                            message: "Future terminal detail.",
                            code: .unknown(rawValue: "futureErrorCode"),
                            additionalDetails: "future additional detail"
                        )
                    )
                )
        )
    }

    @Test func terminalMapperRejectsTurnMismatchForEveryOutcome() throws {
        let expectedAttempt = try makeReviewAttempt(
            attemptID: "attempt-1",
            sourceThreadID: "thread-1",
            turnID: "turn-expected",
            activeTurnThreadID: "thread-1"
        )
        let response = CodexResponse(turnID: "turn-actual")
        let outcomes: [CodexTurnOutcome] = [
            .completed(response),
            .interrupted(response),
            CodexAppServerTestTurnOutcome.failed(
                response: response,
                error: .init(message: "failed")
            ),
            .invalidTerminalStatus(
                rawStatus: "future",
                error: .init(message: "future"),
                response: response
            ),
        ]

        for outcome in outcomes {
            #expect(
                AppServerReviewTerminalMapper.observed(
                    outcome,
                    expectedAttempt: expectedAttempt
                ) == .failed(.protocolViolation(
                    message: "Review terminal turn does not match its attempt."
                ))
            )
        }
    }

    @Test func backendIgnoresAgentMessageDeltasInLifecycleStream() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "thread-1")
        await runtime.transport.waitForNotificationStreamCount(1)
        let backend = await makeBackend(appServer: runtime.server)

        let firstAttempt = try await backend.startReview(makeReviewStart(runID: "run-1", sessionID: "session-1"))
        try await runtime.transport.enqueueThreadStart(threadID: "thread-2", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-2", reviewThreadID: "thread-2")
        let secondAttempt = try await backend.startReview(makeReviewStart(runID: "run-2", sessionID: "session-2"))

        try await runtime.notificationEmitter.emitItemStarted(
            threadID: "thread-1",
            turnID: "turn-1",
            item: .agentMessage(id: "msg-1", text: "")
        )
        try await runtime.notificationEmitter.emitAgentMessageDelta(
            threadID: "thread-1",
            turnID: "turn-1",
            itemID: "msg-1",
            delta: "first"
        )
        try await runtime.notificationEmitter.emitItemStarted(
            threadID: "thread-2",
            turnID: "turn-2",
            item: .agentMessage(id: "msg-1", text: "")
        )
        try await runtime.notificationEmitter.emitAgentMessageDelta(
            threadID: "thread-2",
            turnID: "turn-2",
            itemID: "msg-1",
            delta: "second"
        )
        try await emitTurn(
            on: runtime,
            threadID: "thread-1",
            turnID: "turn-1",
            state: .completed,
            items: [.exitedReviewMode(id: "review-output-1", review: "first")]
        )
        try await emitTurn(
            on: runtime,
            threadID: "thread-2",
            turnID: "turn-2",
            state: .completed,
            items: [.exitedReviewMode(id: "review-output-2", review: "second")]
        )

        #expect(
            try await firstAttempt.observeTerminal()
                == .completed(.init(
                    turnID: makeTurnID("turn-1"),
                    expectedOutput: try NonEmptyReviewOutput(validating: "first")
                ))
        )

        #expect(
            try await secondAttempt.observeTerminal()
                == .completed(.init(
                    turnID: makeTurnID("turn-2"),
                    expectedOutput: try NonEmptyReviewOutput(validating: "second")
                ))
        )
    }

    @Test func backendKeepsCommandOutputDeltasInCodexChat() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "thread-1")
        await runtime.transport.waitForNotificationStreamCount(1)
        let backend = await makeBackend(appServer: runtime.server)

        let attempt = try await backend.startReview(makeReviewStart())

        try await runtime.notificationEmitter.emitItemStarted(
            threadID: "thread-1",
            turnID: "turn-1",
            item: .commandExecution(
                id: "cmd-1",
                command: "swift test",
                cwd: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
                status: .inProgress,
                aggregatedOutput: ""
            )
        )
        try await runtime.notificationEmitter.emitCommandExecutionOutputDelta(
            threadID: "thread-1",
            turnID: "turn-1",
            itemID: "cmd-1",
            delta: "first"
        )
        try await runtime.notificationEmitter.emitCommandExecutionOutputDelta(
            threadID: "thread-1",
            turnID: "turn-1",
            itemID: "cmd-1",
            delta: "second"
        )
        try await emitTurn(
            on: runtime,
            threadID: "thread-1",
            turnID: "turn-1",
            state: .completed,
            items: [.exitedReviewMode(id: "review-output", review: "No issues found.")]
        )

        #expect(
            try await attempt.observeTerminal()
                == .completed(.init(
                    turnID: makeTurnID("turn-1"),
                    expectedOutput: try NonEmptyReviewOutput(validating: "No issues found.")
                ))
        )
    }

    @Test func cleanupReleasesLiveSessionAndRetentionOwnerDeletesThread() async throws {
        let threadStore = try CodexAppServerTestThreadStore(
            plannedStarts: [makeStoredThread(id: "thread-1")]
        )
        let runtime = try await CodexAppServerTestRuntime.start(threadStore: threadStore)
        try await runtime.transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "thread-1")
        let backend = await makeBackend(appServer: runtime.server)

        let attempt = try await backend.startReview(makeReviewStart())
        await backend.cleanupReview(attempt.attempt)

        // Attempt finalization releases only the live SDK session. The CRK
        // retention owner decides when the persisted chat is retired.
        #expect(await runtime.transport.recordedRequests(for: .threadDelete).isEmpty)

        await backend.cleanupActiveReviewsForShutdown(
            .init(reason: .init(message: "Review runtime stopped."), recoveryWaitingAttempts: [])
        )
        #expect(await runtime.transport.recordedRequests(for: .threadDelete).isEmpty)

        let cleanup = await backend.cleanupRetainedReviews(
            [attempt.attempt],
            additionalThreadIDs: []
        )

        let deleteRequests = await runtime.transport.recordedRequests(for: .threadDelete)
        #expect(cleanup.succeeded)
        #expect(deleteRequests.count == 1)
        let deletedIDs = deleteRequests.compactMap { request -> CodexThreadID? in
            guard case .threadDelete(let id) = request.request else { return nil }
            return id
        }
        #expect(deletedIDs == ["thread-1"])
    }

    @Test func connectionTerminationCleanupDoesNotStartRemoteWork() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "thread-1")
        let backend = await makeBackend(appServer: runtime.server)
        let attempt = try await backend.startReview(makeReviewStart())
        let request = CodexReviewRuntimeStopReviewCleanupRequest(
            reason: .init(message: "Connection terminated."),
            recoveryWaitingAttempts: []
        )
        let methodsBeforeCleanup = await runtime.transport.recordedRequests().map(\.request.operation)

        await backend.cleanupActiveReviewsAfterConnectionTermination(request)
        await backend.cleanupReview(attempt.attempt)
        await backend.cleanupActiveReviewsAfterConnectionTermination(request)
        await backend.cleanupActiveReviewsForShutdown(request)

        #expect(await runtime.transport.recordedRequests().map(\.request.operation) == methodsBeforeCleanup)
    }

    @Test func shutdownCleanupReleasesRecoveryWaitingRunsWithoutDeletingThreads() async throws {
        let runtime = try await CodexAppServerTestRuntime.start(
            threads: [
                makeStoredThread(id: "thread-1"),
                makeStoredThread(id: "review-thread"),
            ]
        )
        let backend = await makeBackend(appServer: runtime.server)
        let attempt = try makeReviewAttempt(
            attemptID: "attempt-recovery",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "review-thread",
            model: "gpt-5"
        )
        let request = CodexReviewRuntimeStopReviewCleanupRequest(
            reason: .init(message: "Review runtime stopped."),
            recoveryWaitingAttempts: [attempt]
        )

        await backend.cleanupActiveReviewsForShutdown(request)

        let requests = await runtime.transport.recordedRequests()
        #expect(requests.map(\.request.operation).contains(.turnInterrupt) == false)
        #expect(requests.contains { $0.request.operation == .threadDelete } == false)

        let cleanup = await backend.cleanupRetainedReviews(
            [attempt],
            additionalThreadIDs: []
        )
        let deleteRequests = await runtime.transport.recordedRequests(for: .threadDelete)
        #expect(cleanup.succeeded)
        #expect(deleteRequests.count == 2)
        let deletedIDs = deleteRequests.compactMap { request -> CodexThreadID? in
            guard case .threadDelete(let id) = request.request else { return nil }
            return id
        }
        #expect(Set(deletedIDs) == ["review-thread", "thread-1"])
    }

    @Test func interruptReviewRejectsAttemptWithoutRegisteredSDKSession() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let backend = await makeBackend(appServer: runtime.server)
        let attempt = try makeReviewAttempt(
            attemptID: "attempt-1",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "thread-1",
            model: "gpt-5"
        )

        do {
            try await backend.interruptReview(attempt, reason: .init(message: "Stop"))
            Issue.record("Expected an unregistered attempt to fail without remote work.")
        } catch let failure as ReviewBackendFailure {
            #expect(
                failure == .protocolViolation(
                    message: "Interrupt requires the active SDK review session for its attempt."
                )
            )
        }

        let requests = await runtime.transport.recordedRequests()
        #expect(requests.map(\.request.operation) == [.initialize])
    }

    @Test func interruptReviewUsesRegisteredSDKSessionWithoutResume() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-1",
            reviewThreadID: "thread-1"
        )
        try await runtime.transport.handleTurnInterrupt { _ in }
        let backend = await makeBackend(appServer: runtime.server)
        let attempt = try await backend.startReview(makeReviewStart())

        let interruptTask = Task {
            try await backend.interruptReview(attempt.attempt, reason: .init(message: "Stop"))
        }
        defer {
            interruptTask.cancel()
        }
        await runtime.transport.waitForRequest(.turnInterrupt)
        try await emitTurn(
            on: runtime,
            threadID: "thread-1",
            turnID: "turn-1",
            state: .interrupted
        )
        try await withTimeout {
            try await interruptTask.value
        }

        let requests = await runtime.transport.recordedRequests()
        #expect(requests.map(\.request.operation) == [
            .initialize,
            .threadStart,
            .reviewStart,
            .turnInterrupt,
        ])
        #expect(requests.contains { $0.request.operation == .threadResume } == false)
        let interrupt = try #require(requests.compactMap { request
            -> (CodexThreadID, CodexTurnID)? in
            guard case .turnInterrupt(let threadID, let turnID) = request.request else {
                return nil
            }
            return (threadID, turnID)
        }.first)
        #expect(interrupt.0 == "thread-1")
        #expect(interrupt.1 == "turn-1")
    }

    @Test func interruptReviewCompletesTerminalWaitAfterCallerCancellation() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-1",
            reviewThreadID: "thread-1"
        )
        try await runtime.transport.handleTurnInterrupt { _ in }
        let backend = await makeBackend(appServer: runtime.server)
        let attempt = try await backend.startReview(makeReviewStart())

        let interruptTask = Task {
            try await backend.interruptReview(attempt.attempt, reason: .init(message: "Stop"))
        }
        await runtime.transport.waitForRequest(.turnInterrupt)
        interruptTask.cancel()
        try await emitTurn(
            on: runtime,
            threadID: "thread-1",
            turnID: "turn-1",
            state: .interrupted
        )

        try await withTimeout {
            try await interruptTask.value
        }
    }

    @Test func startReviewMapsRequestFailureToTypedOperation() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueFailure(
            .response(code: -32_000, message: "start unavailable"),
            for: .threadStart
        )
        let backend = await makeBackend(appServer: runtime.server)

        do {
            _ = try await backend.startReview(makeReviewStart())
            Issue.record("Expected startReview to preserve its typed operation failure.")
        } catch {
            try expectServerRequestFailure(
                error,
                operation: .startReview,
                method: "thread/start",
                code: -32_000
            )
        }
    }

    @Test func interruptReviewMapsRequestFailureToTypedOperation() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-1",
            reviewThreadID: "thread-1"
        )
        let backend = await makeBackend(appServer: runtime.server)
        let attempt = try await backend.startReview(makeReviewStart())
        try await runtime.transport.enqueueFailure(
            .response(code: -32_011, message: "interrupt unavailable"),
            for: .turnInterrupt
        )

        let interruptTask = Task {
            try await backend.interruptReview(
                attempt.attempt,
                reason: .init(message: "Stop")
            )
        }
        await runtime.transport.waitForRequest(.turnInterrupt)
        try await emitTurn(
            on: runtime,
            threadID: "thread-1",
            turnID: "turn-1",
            state: .interrupted
        )

        do {
            try await interruptTask.value
            Issue.record("Expected interruptReview to preserve its typed operation failure.")
        } catch {
            try expectServerRequestFailure(
                error,
                operation: .interruptReview,
                method: "turn/interrupt",
                code: -32_011
            )
        }
        #expect(await runtime.transport.recordedRequests(for: .threadResume).isEmpty)
    }

    @Test func interruptFailureRetainsTerminalBarrier() async throws {
        let terminalGate = CodexAppServerTestGate()
        let interruption = Task<Void, any Error> {
            try await AppServerCodexReviewBackend.interruptAndAwaitTerminal(
                interrupt: { () async throws -> Void in
                    throw AppServerClientTestInterruptionError.rejected
                },
                awaitTerminal: {
                    await terminalGate.waitIgnoringCancellation()
                }
            )
        }

        await terminalGate.waitUntilBlocked()
        await terminalGate.open()

        do {
            try await interruption.value
            Issue.record("Expected the interrupt failure after the terminal barrier opened.")
        } catch {
            #expect(error as? AppServerClientTestInterruptionError == .rejected)
        }
    }

    @Test func prepareRestartMapsRequestFailureToTypedOperation() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-1",
            reviewThreadID: "thread-1"
        )
        let backend = await makeBackend(appServer: runtime.server)
        let attempt = try await backend.startReview(makeReviewStart())
        try await runtime.transport.enqueueFailure(
            .response(code: -32_002, message: "resume unavailable"),
            for: .threadResume
        )

        do {
            _ = try await backend.prepareReviewRestart(attempt.attempt)
            Issue.record("Expected prepareRestart to preserve its typed operation failure.")
        } catch {
            try expectServerRequestFailure(
                error,
                operation: .prepareRestart,
                method: "thread/resume",
                code: -32_002
            )
        }

        let runID = try ReviewRunID(validating: "run-1")
        let retained = await backend.discardAllPreparedReviewRestarts(
            ownedAttemptsByRunID: [runID: attempt.attempt]
        )
        #expect(retained == [runID: [attempt.attempt]])
    }

    @Test func restartReviewMapsUnavailableTokenToTypedOperation() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let backend = await makeBackend(appServer: runtime.server)
        let interruptedAttempt = try makeReviewAttempt(
            attemptID: "attempt-1",
            sourceThreadID: "thread-1",
            turnID: "turn-1",
            activeTurnThreadID: "thread-1",
            model: "gpt-5"
        )
        let token = CodexReviewBackendModel.Review.RestartToken(
            id: "missing-token",
            interruptedAttempt: interruptedAttempt
        )

        do {
            _ = try await backend.restartPreparedReview(token, request: makeReviewStart())
            Issue.record("Expected restartReview to preserve its typed operation failure.")
        } catch let failure as ReviewBackendFailure {
            let operationFailure = try #require(failure.operationFailure)
            #expect(operationFailure.operation == .restartReview)
            #expect(operationFailure.reason == .reviewRestartUnavailable)
        }
    }

    @Test func preparedReviewRestartCancelsRollsBackAndRestartsOnSameThread() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-old", reviewThreadID: "thread-1")
        await runtime.transport.waitForNotificationStreamCount(1)
        let backend = await makeBackend(appServer: runtime.server)
        let attempt = try await backend.startReview(makeReviewStart())
        try await runtime.transport.enqueueThreadResume(
            makeStoredThread(id: "thread-1")
        )
        try await runtime.transport.enqueueFailure(
            .response(
                code: -32602,
                message: "expected active turn id turn-old but found turn-new"
            ),
            for: .turnInterrupt
        )
        try await runtime.transport.handleTurnInterrupt { _ in }
        try await runtime.transport.enqueueThreadResume(
            makeStoredThread(id: "thread-1")
        )
        try await runtime.transport.enqueueThreadRollback(
            makeStoredThread(id: "thread-1")
        )
        try await runtime.transport.enqueueThreadResume(
            makeStoredThread(id: "thread-1")
        )
        try await runtime.transport.enqueueReviewStart(turnID: "turn-restarted", reviewThreadID: "thread-1")

        let prepareTask = Task {
            try await backend.prepareReviewRestart(attempt.attempt)
        }
        defer {
            prepareTask.cancel()
        }
        await runtime.transport.waitForRequest(.turnInterrupt, count: 2)
        try await emitTurn(
            on: runtime,
            threadID: "thread-review-child",
            turnID: "turn-new",
            state: .interrupted
        )
        try await runtime.notificationEmitter.emitItemCompleted(
            threadID: "thread-1",
            turnID: "turn-old",
            item: .agentMessage(id: "review-output", text: "Review interrupted")
        )
        try await emitTurn(
            on: runtime,
            threadID: "thread-1",
            turnID: "turn-old",
            state: .interrupted
        )
        let token = try await withTimeout {
            try await prepareTask.value
        }
        let restartedAttempt = try await backend.restartPreparedReview(token, request: makeReviewStart())

        #expect(token.interruptedAttempt == attempt.attempt)
        #expect(restartedAttempt.attempt.threadIdentity.sourceThreadID.rawValue == "thread-1")
        #expect(restartedAttempt.attempt.turnID.rawValue == "turn-restarted")
        #expect(restartedAttempt.attempt.threadIdentity.activeTurnThreadID.rawValue == "thread-1")
        let requests = await runtime.transport.recordedRequests()
        #expect(
            requests.map(\.request.operation) == [
                .initialize,
                .threadStart,
                .reviewStart,
                .threadResume,
                .turnInterrupt,
                .turnInterrupt,
                .threadResume,
                .threadRollback,
                .threadResume,
                .reviewStart,
            ])
        let resumeRequests = requests.compactMap { request -> (CodexThreadID, CodexThread.Options)? in
            guard case .threadResume(let id, let options) = request.request else { return nil }
            return (id, options)
        }
        let resumeThreadIDs = resumeRequests.map(\.0.rawValue)
        #expect(resumeThreadIDs == ["thread-1", "thread-1", "thread-1"])
        let resumeModels = resumeRequests.map(\.1.model)
        #expect(resumeModels == ["gpt-5", "gpt-5", "gpt-5"])
        // Restarted reviews keep the review thread profile instead of default
        // Codex settings.
        let resumeApprovalModes = resumeRequests.map(\.1.approvalMode)
        #expect(resumeApprovalModes.last == .denyAll)
        let interruptTurnIDs = requests.compactMap { request -> CodexTurnID? in
            guard case .turnInterrupt(_, let turnID) = request.request else { return nil }
            return turnID
        }
        #expect(interruptTurnIDs == ["turn-old", "turn-new"])
        let rollback = try #require(requests.compactMap { request
            -> (CodexThreadID, Int)? in
            guard case .threadRollback(let id, let numberOfTurns) = request.request else {
                return nil
            }
            return (id, numberOfTurns)
        }.first)
        #expect(rollback.0 == "thread-1")
        #expect(rollback.1 == 1)
        let reviewStarts = requests.compactMap { request -> CodexThreadID? in
            guard case .reviewStart(let threadID, _, _) = request.request else { return nil }
            return threadID
        }
        #expect(reviewStarts.last == "thread-1")
    }

    @Test func discardPreparedRestartTransfersRetentionWithoutDeletingThreads() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-old",
            reviewThreadID: "thread-1"
        )
        await runtime.transport.waitForNotificationStreamCount(1)
        let backend = await makeBackend(appServer: runtime.server)
        let attempt = try await backend.startReview(makeReviewStart())
        try await runtime.transport.enqueueThreadResume(makeStoredThread(id: "thread-1"))
        try await runtime.transport.handleTurnInterrupt { _ in }

        let prepare = Task {
            try await backend.prepareReviewRestart(attempt.attempt)
        }
        defer {
            prepare.cancel()
        }
        await runtime.transport.waitForRequest(.turnInterrupt)
        try await emitTurn(
            on: runtime,
            threadID: "thread-1",
            turnID: "turn-old",
            state: .interrupted
        )
        let token = try await prepare.value

        let retained = await backend.discardPreparedReviewRestart(token)

        #expect(retained == [attempt.attempt])
        #expect(await runtime.transport.recordedRequests(for: .threadDelete).isEmpty)
    }

    @Test func shutdownCleanupDoesNotDeleteProvisionalRestartSourceThread() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-old", reviewThreadID: "thread-1")
        await runtime.transport.waitForNotificationStreamCount(1)
        let backend = await makeBackend(appServer: runtime.server)
        let attempt = try await backend.startReview(makeReviewStart())
        try await runtime.transport.enqueueThreadResume(
            makeStoredThread(id: "thread-1")
        )
        try await runtime.transport.handleTurnInterrupt { _ in }
        let prepareTask = Task {
            try await backend.prepareReviewRestart(attempt.attempt)
        }
        defer {
            prepareTask.cancel()
        }
        await runtime.transport.waitForRequest(.turnInterrupt)
        try await emitTurn(
            on: runtime,
            threadID: "thread-1",
            turnID: "turn-old",
            state: .interrupted
        )
        let token = try await withTimeout {
            try await prepareTask.value
        }

        let reviewStartGate = CodexAppServerTestGate()
        try await runtime.transport.enqueueThreadResume(
            makeStoredThread(id: "thread-1")
        )
        try await runtime.transport.enqueueThreadRollback(
            makeStoredThread(id: "thread-1")
        )
        try await runtime.transport.enqueueThreadResume(
            makeStoredThread(id: "thread-1")
        )
        try await runtime.transport.enqueueReviewStart(turnID: "turn-restarted", reviewThreadID: "thread-1")
        await runtime.transport.holdNextIgnoringCancellation(
            .reviewStart,
            gate: reviewStartGate
        )
        let restartTask = Task {
            try await backend.restartPreparedReview(token, request: makeReviewStart())
        }
        defer {
            restartTask.cancel()
        }
        await runtime.transport.waitForRequest(.reviewStart, count: 2)

        await backend.cleanupActiveReviewsForShutdown(
            .init(
                reason: .init(message: "Review runtime stopped."),
                recoveryWaitingAttempts: [attempt.attempt]
            ))

        #expect(await runtime.transport.recordedRequests(for: .threadDelete).isEmpty)
        await reviewStartGate.open()
        let restartedAttempt = try await withTimeout {
            try await restartTask.value
        }
        #expect(restartedAttempt.attempt.threadIdentity.sourceThreadID.rawValue == "thread-1")
        #expect(restartedAttempt.attempt.turnID.rawValue == "turn-restarted")
    }
}

@MainActor
private func makeBackend(appServer: CodexAppServer) -> AppServerCodexReviewBackend {
    let modelContainer = CodexModelContainer(appServer: appServer)
    return AppServerCodexReviewBackend(modelContainer: modelContainer)
}

private struct CompletedReviewFixture: Sendable {
    let runtime: CodexAppServerTestRuntime
    let attempt: BackendReviewAttempt
    let observed: ReviewBackendObservedTerminal
}

private func makeCompletedReviewFixture(
    output: String
) async throws -> CompletedReviewFixture {
    let runtime = try await CodexAppServerTestRuntime.start()
    try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
    try await runtime.transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "thread-1")
    await runtime.transport.waitForNotificationStreamCount(1)
    let backend = await makeBackend(appServer: runtime.server)
    let attempt = try await backend.startReview(makeReviewStart())
    try await emitTurn(
        on: runtime,
        threadID: "thread-1",
        turnID: "turn-1",
        state: .completed,
        items: [.exitedReviewMode(id: "review-output", review: output)]
    )
    return CompletedReviewFixture(
        runtime: runtime,
        attempt: attempt,
        observed: try await attempt.observeTerminal()
    )
}

enum ReviewPublicationFailureScenario: CaseIterable, Sendable {
    case turnUnavailable
    case outputMissing
    case outputEmpty
    case outputMismatch
    case refreshFailure
}

private func makeReviewAttempt(
    attemptID: String,
    sourceThreadID: String,
    turnID: String,
    activeTurnThreadID: String,
    model: String? = nil
) throws -> ReviewAttempt {
    try ReviewAttempt(
        validatingAttemptID: attemptID,
        sourceThreadID: sourceThreadID,
        activeTurnThreadID: activeTurnThreadID,
        turnID: turnID,
        model: model
    )
}

private func makeTurnID(_ rawValue: String) throws -> ReviewTurnID {
    try ReviewTurnID(validating: rawValue)
}

private func makeThreadID(_ rawValue: String) throws -> ReviewThreadID {
    try ReviewThreadID(validating: rawValue)
}

private enum AppServerClientTestTimeout: Error {
    case timedOut
}

private enum AppServerClientTestInterruptionError: Error, Equatable {
    case rejected
}

private extension ReviewBackendFailure {
    var operationFailure: ReviewBackendOperationFailure? {
        guard case .operation(let failure) = self else {
            return nil
        }
        return failure
    }
}

private func expectServerRequestFailure(
    _ error: any Error,
    operation: ReviewBackendOperationFailure.Operation,
    method: String,
    code: Int
) throws {
    let backendFailure = try #require(error as? ReviewBackendFailure)
    let operationFailure = try #require(backendFailure.operationFailure)
    #expect(operationFailure.operation == operation)
    guard case .request(
        requestID: _,
        method: let actualMethod,
        kind: .server(code: let actualCode, turnFailure: let turnFailure)
    ) = operationFailure.reason else {
        Issue.record("Expected a typed server request failure, got \(operationFailure.reason).")
        return
    }
    #expect(actualMethod == method)
    #expect(actualCode == code)
    #expect(turnFailure == nil)
}

private func withTimeout<T: Sendable>(
    timeout: Duration = .seconds(1),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw AppServerClientTestTimeout.timedOut
        }
        let result = try #require(await group.next())
        group.cancelAll()
        return result
    }
}

private func enqueueReviewProjection(
    transport: CodexAppServerTestTransport,
    threadID: String,
    turnID: String?,
    output: String?
) async throws {
    let items = try output.map {
        [try CodexAppServerTestItem.exitedReviewMode(id: "review-output", review: $0)]
    } ?? []
    let turns = try turnID.map {
        [try CodexAppServerTestTurn(
            snapshot: .init(
                id: .init(rawValue: $0),
                state: .completed,
                items: items.map(\.domainProjection)
            ),
            items: items
        )]
    } ?? []
    try await transport.enqueueThreadRead(
        makeStoredThread(
            id: .init(rawValue: threadID),
            turns: turns
        )
    )
}

private extension CodexAppServerTestTransport {
    func enqueueThreadStart(
        threadID: String,
        model: String? = nil
    ) throws {
        try enqueueThreadStart(
            makeStoredThread(
                id: .init(rawValue: threadID),
                model: model ?? "gpt-5"
            )
        )
    }

    func enqueueReviewStart(
        turnID: String,
        reviewThreadID: String
    ) throws {
        try enqueueReviewStart(
            makeTestTurn(id: .init(rawValue: turnID), state: .inProgress),
            reviewThreadID: .init(rawValue: reviewThreadID)
        )
    }
}

private func makeTestTurn(
    id: CodexTurnID,
    state: CodexTurnSnapshot.State = .completed,
    itemsLoadState: CodexTurnItemsLoadState = .full,
    items: [CodexAppServerTestItem] = []
) throws -> CodexAppServerTestTurn {
    try .init(
        snapshot: .init(
            id: id,
            state: state,
            itemsLoadState: itemsLoadState,
            items: items.map(\.domainProjection)
        ),
        items: items
    )
}

private func emitTurn(
    on runtime: CodexAppServerTestRuntime,
    threadID: CodexThreadID,
    turnID: CodexTurnID,
    state: CodexTurnSnapshot.State,
    itemsLoadState: CodexTurnItemsLoadState = .full,
    items: [CodexAppServerTestItem] = []
) async throws {
    try await runtime.notificationEmitter.emitTurnCompleted(
        threadID: threadID,
        turn: makeTestTurn(
            id: turnID,
            state: state,
            itemsLoadState: itemsLoadState,
            items: items
        )
    )
}

private func makeStoredThread(
    id: CodexThreadID,
    model: String = "gpt-5",
    turns: [CodexAppServerTestTurn] = [],
    isArchived: Bool = false
) throws -> CodexAppServerTestStoredThread {
    let workspace = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
    return try .init(
        snapshot: .init(
            id: id,
            workspace: workspace,
            preview: id.rawValue,
            modelProvider: "openai",
            sourceKind: .appServer,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            status: .idle,
            ephemeral: false,
            turns: turns.map(\.snapshot)
        ),
        turns: turns,
        metadata: .init(
            sessionID: "session-\(id.rawValue)",
            cliVersion: "codex-cli-test",
            source: .appServer
        ),
        runtimeMetadata: .init(
            model: model,
            modelProvider: "openai",
            serviceTier: nil,
            cwd: workspace,
            runtimeWorkspaceRoots: [workspace],
            instructionSources: [],
            approvalPolicy: .never,
            approvalsReviewer: .user,
            sandbox: .dangerFullAccess,
            activePermissionProfile: nil,
            reasoningEffort: nil,
            multiAgentMode: .explicitRequestOnly
        ),
        isArchived: isArchived
    )
}

private func makeReviewStart(
    runID: String = "run-1",
    sessionID: String = "session-1",
    target: CodexReviewAPI.Target = .uncommittedChanges
) -> CodexReviewBackendModel.Review.Start {
    do {
        return .init(
            runID: try ReviewRunID(validating: runID),
            sessionID: sessionID,
            request: .init(cwd: "/tmp/project", target: target),
            model: "gpt-5"
        )
    } catch {
        preconditionFailure("Invalid explicit review run fixture: \(error)")
    }
}
