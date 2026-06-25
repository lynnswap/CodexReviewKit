import Foundation
import Testing
import CodexAppServerKit
import CodexAppServerKitTesting
@testable import CodexReviewAppServer
import CodexReviewKit

private struct BackendReviewEventSequence: AsyncSequence {
    struct AsyncIterator: AsyncIteratorProtocol {
        var mailbox: BackendReviewEventMailbox
        var includesDomainEvents: Bool

        mutating func next() async throws -> CodexReviewBackendModel.Review.Event? {
            while let event = try await mailbox.next() {
                if includesDomainEvents == false {
                    switch event {
                    case .domainEvents,
                         .suppressNextLegacyTimelineProjection,
                         .suppressNextTerminalFailureLogTimelineProjection:
                        continue
                    case .started,
                         .message,
                         .messageDelta,
                         .log,
                         .logEntry,
                         .completed,
                         .failed,
                         .cancelled:
                        break
                    }
                }
                if case .suppressNextTerminalFailureLogTimelineProjection = event {
                    continue
                }
                return event
            }
            return nil
        }
    }

    var mailbox: BackendReviewEventMailbox
    var includesDomainEvents: Bool

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(mailbox: mailbox, includesDomainEvents: includesDomainEvents)
    }
}

@Suite("AppServerClientTests")
struct AppServerClientTests {
    @Test func backendStartsReviewThroughExternalCodexKit() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "thread-1")
        let backend = AppServerCodexReviewBackend(appServer: runtime.server)

        let attempt = try await backend.startReview(makeReviewStart(target: .uncommittedChanges))

        #expect(attempt.run.threadID == "thread-1")
        #expect(attempt.run.turnID == "turn-1")
        #expect(attempt.run.reviewThreadID == "thread-1")

        let requests = await runtime.transport.recordedRequests()
        #expect(requests.map(\.method) == ["initialize", "thread/start", "review/start"])

        let threadStart = try #require(requests.first { $0.method == "thread/start" })
        let threadParams = try jsonObject(from: threadStart.params)
        #expect(threadParams["cwd"] as? String == "/tmp/project")
        #expect(threadParams["model"] as? String == "gpt-5")
        #expect(threadParams["ephemeral"] as? Bool == false)
        #expect(threadParams["approvalPolicy"] as? String == "never")
        #expect(threadParams["permissions"] as? String == ":danger-full-access")
        #expect(threadParams["sessionStartSource"] as? String == "startup")
        #expect(threadParams["threadSource"] as? String == "user")
        #expect(threadParams["sandbox"] == nil)

        let reviewStart = try #require(requests.first { $0.method == "review/start" })
        let reviewParams = try jsonObject(from: reviewStart.params)
        #expect(reviewParams["threadId"] as? String == "thread-1")
        let target = try #require(reviewParams["target"] as? [String: Any])
        #expect(target["type"] as? String == "uncommittedChanges")
    }

    @Test func backendConsumesTypedReviewSessionStream() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "review-thread")
        await runtime.transport.waitForNotificationStreamCount(1)
        let backend = AppServerCodexReviewBackend(appServer: runtime.server)

        let attempt = try await backend.startReview(makeReviewStart(target: .baseBranch("main")))
        var iterator = eventSequence(attempt, includingDomainEvents: true).makeAsyncIterator()

        try await runtime.transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "review-thread",
                turnID: "turn-1",
                item: .init(
                    type: "commandExecution",
                    id: "cmd-1",
                    command: "swift test",
                    aggregatedOutput: "passed",
                    status: "completed"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TestDeltaNotification(
                threadID: "review-thread",
                turnID: "turn-1",
                itemID: "msg-1",
                delta: "Looks good."
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "review-thread",
                turn: .init(id: "turn-1", status: "completed")
            )
        )

        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "review-thread", model: "gpt-5"))
        guard case .domainEvents(let commandDomainEvents, let commandSuppressionCount) = try await iterator.next() else {
            Issue.record("expected typed command domain event")
            return
        }
        #expect(commandSuppressionCount == 2)
        guard case .itemCompleted(let commandSeed) = try #require(commandDomainEvents.first) else {
            Issue.record("expected completed command seed")
            return
        }
        #expect(commandSeed.id.rawValue == "cmd-1")
        guard case .command(let command) = commandSeed.content else {
            Issue.record("expected command content")
            return
        }
        #expect(command.command == "swift test")
        #expect(command.output == "passed")
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ swift test",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "completed",
                itemID: "cmd-1",
                command: "swift test",
                commandStatus: "completed"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .commandOutput,
            text: "passed",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "completed",
                itemID: "cmd-1",
                command: "swift test",
                commandStatus: "completed"
            )
        ))
        guard case .domainEvents(let messageDomainEvents, let messageSuppressionCount) = try await iterator.next() else {
            Issue.record("expected typed message delta domain event")
            return
        }
        #expect(messageSuppressionCount == 1)
        guard case .textDelta(let itemID, _, let family, _, let delta) = try #require(messageDomainEvents.first) else {
            Issue.record("expected message text delta")
            return
        }
        #expect(itemID.rawValue == "msg-1")
        #expect(family == .message)
        #expect(delta == "Looks good.")
        #expect(try await iterator.next() == .messageDelta("Looks good.", itemID: "msg-1"))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "Looks good."))
    }

    @Test func backendScopesCommandOutputDeltasByReviewThread() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "review-thread-1")
        await runtime.transport.waitForNotificationStreamCount(1)
        let backend = AppServerCodexReviewBackend(appServer: runtime.server)

        let firstAttempt = try await backend.startReview(makeReviewStart(jobID: "job-1", sessionID: "session-1"))
        try await runtime.transport.enqueueThreadStart(threadID: "thread-2", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-2", reviewThreadID: "review-thread-2")
        let secondAttempt = try await backend.startReview(makeReviewStart(jobID: "job-2", sessionID: "session-2"))

        try await runtime.transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: TestDeltaNotification(
                threadID: "review-thread-1",
                turnID: "turn-1",
                itemID: "cmd-1",
                delta: "first"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: TestDeltaNotification(
                threadID: "review-thread-2",
                turnID: "turn-2",
                itemID: "cmd-1",
                delta: "second"
            )
        )

        var firstIterator = eventSequence(firstAttempt, includingDomainEvents: true).makeAsyncIterator()
        #expect(try await firstIterator.next() == .started(turnID: "turn-1", reviewThreadID: "review-thread-1", model: "gpt-5"))
        guard case .domainEvents(let firstDomainEvents, _) = try await firstIterator.next(),
              case .itemUpdated(let firstSeed) = try #require(firstDomainEvents.first),
              case .command(let firstCommand) = firstSeed.content
        else {
            Issue.record("expected first command output domain event")
            return
        }
        #expect(firstCommand.output == "first")

        var secondIterator = eventSequence(secondAttempt, includingDomainEvents: true).makeAsyncIterator()
        #expect(try await secondIterator.next() == .started(turnID: "turn-2", reviewThreadID: "review-thread-2", model: "gpt-5"))
        guard case .domainEvents(let secondDomainEvents, _) = try await secondIterator.next(),
              case .itemUpdated(let secondSeed) = try #require(secondDomainEvents.first),
              case .command(let secondCommand) = secondSeed.content
        else {
            Issue.record("expected second command output domain event")
            return
        }
        #expect(secondCommand.output == "second")
    }

    @Test func backendCoalescesTypedCommandOutputDeltas() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "review-thread")
        await runtime.transport.waitForNotificationStreamCount(1)
        let backend = AppServerCodexReviewBackend(appServer: runtime.server)

        let attempt = try await backend.startReview(makeReviewStart())
        #expect(try await nextEvent(from: attempt.events) == .started(
            turnID: "turn-1",
            reviewThreadID: "review-thread",
            model: "gpt-5"
        ))

        try await runtime.transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: TestDeltaNotification(
                threadID: "review-thread",
                turnID: "turn-1",
                itemID: "cmd-1",
                delta: "first"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: TestDeltaNotification(
                threadID: "review-thread",
                turnID: "turn-1",
                itemID: "cmd-1",
                delta: "second"
            )
        )

        guard case .domainEvents = try await nextEvent(from: attempt.events),
              case .domainEvents = try await nextEvent(from: attempt.events)
        else {
            Issue.record("expected direct timeline updates before coalesced legacy log")
            return
        }
        guard case .logEntry(.commandOutput, let text, let groupID, let replacesGroup, let metadata) =
            try await nextEvent(from: attempt.events)
        else {
            Issue.record("expected coalesced command output log")
            return
        }
        #expect(text == "firstsecond")
        #expect(groupID == "cmd-1")
        #expect(replacesGroup == false)
        #expect(metadata?.sourceType == "commandExecution")
        #expect(metadata?.title == "Command output")
        #expect(metadata?.itemID == "cmd-1")
    }

    @Test func cleanupDeletesReviewThreadsThroughCodexThreadHandles() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "review-thread")
        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        let backend = AppServerCodexReviewBackend(appServer: runtime.server)

        let attempt = try await backend.startReview(makeReviewStart())
        await backend.cleanupReview(attempt.run)

        let deleteRequests = await runtime.transport.recordedRequests(method: "thread/delete")
        #expect(deleteRequests.count == 2)
        let deletedIDs = try deleteRequests.map { try jsonObject(from: $0.params)["threadId"] as? String }
        #expect(Set(deletedIDs.compactMap { $0 }) == ["review-thread", "thread-1"])
    }

    @Test func shutdownCleanupDeletesRecoveryWaitingRunsWithoutInterrupt() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        let backend = AppServerCodexReviewBackend(appServer: runtime.server)
        let run = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovery",
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread",
            model: "gpt-5"
        )
        let request = CodexReviewRuntimeStopReviewCleanupRequest(
            reason: .init(message: "Review runtime stopped."),
            recoveryWaitingRuns: [run]
        )

        await backend.cleanupActiveReviewsForShutdown(request)

        let requests = await runtime.transport.recordedRequests()
        #expect(requests.map(\.method).contains("turn/interrupt") == false)
        let deleteRequests = requests.filter { $0.method == "thread/delete" }
        #expect(deleteRequests.count == 2)
        let deletedIDs = try deleteRequests.map { try jsonObject(from: $0.params)["threadId"] as? String }
        #expect(Set(deletedIDs.compactMap { $0 }) == ["review-thread", "thread-1"])
    }

    @Test func interruptReviewCancelsReconstructedRunThroughResumedThread() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueJSON(
            #"{"thread":{"id":"thread-1"},"model":"gpt-5"}"#,
            for: "thread/resume"
        )
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(appServer: runtime.server)
        let run = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-1",
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: "gpt-5"
        )

        try await backend.interruptReview(run, reason: .init(message: "Stop"))

        let requests = await runtime.transport.recordedRequests()
        #expect(requests.map(\.method) == ["initialize", "thread/resume", "turn/interrupt"])
        let resume = try #require(requests.first { $0.method == "thread/resume" })
        let resumeParams = try jsonObject(from: resume.params)
        #expect(resumeParams["threadId"] as? String == "thread-1")
        #expect(resumeParams["model"] as? String == "gpt-5")
        let interrupt = try #require(requests.first { $0.method == "turn/interrupt" })
        let interruptParams = try jsonObject(from: interrupt.params)
        #expect(interruptParams["threadId"] as? String == "thread-1")
        #expect(interruptParams["turnId"] as? String == "turn-1")
    }

    @Test func interruptReviewCancelsDetachedReconstructedRunThroughReviewThread() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueJSON(
            #"{"thread":{"id":"review-thread"},"model":"gpt-5"}"#,
            for: "thread/resume"
        )
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(appServer: runtime.server)
        let run = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-1",
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread",
            model: "gpt-5"
        )

        try await backend.interruptReview(run, reason: .init(message: "Stop"))

        let requests = await runtime.transport.recordedRequests()
        #expect(requests.map(\.method) == ["initialize", "thread/resume", "turn/interrupt"])
        let resume = try #require(requests.first { $0.method == "thread/resume" })
        let resumeParams = try jsonObject(from: resume.params)
        #expect(resumeParams["threadId"] as? String == "review-thread")
        #expect(resumeParams["model"] as? String == "gpt-5")
        let interrupt = try #require(requests.first { $0.method == "turn/interrupt" })
        let interruptParams = try jsonObject(from: interrupt.params)
        #expect(interruptParams["threadId"] as? String == "review-thread")
        #expect(interruptParams["turnId"] as? String == "turn-1")
    }

    @Test func preparedReviewRestartCancelsRollsBackAndRestartsOnSameThread() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-old", reviewThreadID: "review-thread")
        await runtime.transport.waitForNotificationStreamCount(1)
        let backend = AppServerCodexReviewBackend(appServer: runtime.server)
        let attempt = try await backend.startReview(makeReviewStart())
        try await runtime.transport.enqueueJSON(
            #"{"thread":{"id":"review-thread"},"model":"gpt-5"}"#,
            for: "thread/resume"
        )
        await runtime.transport.enqueueFailure(
            code: -32602,
            message: "expected active turn id turn-old but found turn-new",
            for: "turn/interrupt"
        )
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
        try await runtime.transport.enqueueJSON(
            #"{"thread":{"id":"review-thread"},"model":"gpt-5"}"#,
            for: "thread/resume"
        )
        try await runtime.transport.enqueueEmpty(for: "thread/rollback")
        try await runtime.transport.enqueueJSON(
            #"{"thread":{"id":"thread-1"},"model":"gpt-5"}"#,
            for: "thread/resume"
        )
        try await runtime.transport.enqueueReviewStart(turnID: "turn-restarted", reviewThreadID: "review-thread")

        let prepareTask = Task {
            try await backend.prepareReviewRestart(attempt.run)
        }
        defer {
            prepareTask.cancel()
        }
        await runtime.transport.waitForRequest(method: "turn/interrupt", count: 2)
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "review-thread",
                turn: .init(id: "turn-new", status: "interrupted")
            )
        )
        let token = try await withTimeout {
            try await prepareTask.value
        }
        let restartedAttempt = try await backend.restartPreparedReview(token, request: makeReviewStart())

        #expect(token.interruptedRun == attempt.run)
        #expect(restartedAttempt.run.threadID == "thread-1")
        #expect(restartedAttempt.run.turnID == "turn-restarted")
        #expect(restartedAttempt.run.reviewThreadID == "review-thread")
        let requests = await runtime.transport.recordedRequests()
        #expect(requests.map(\.method) == [
            "initialize",
            "thread/start",
            "review/start",
            "thread/resume",
            "turn/interrupt",
            "turn/interrupt",
            "thread/resume",
            "thread/rollback",
            "thread/resume",
            "review/start",
        ])
        let resumeThreadIDs = try requests.filter { $0.method == "thread/resume" }.map {
            try jsonObject(from: $0.params)["threadId"] as? String
        }
        #expect(resumeThreadIDs == ["review-thread", "review-thread", "thread-1"])
        let resumeModels = try requests.filter { $0.method == "thread/resume" }.map {
            try jsonObject(from: $0.params)["model"] as? String
        }
        #expect(resumeModels == ["gpt-5", "gpt-5", "gpt-5"])
        let interruptTurnIDs = try requests.filter { $0.method == "turn/interrupt" }.map {
            try jsonObject(from: $0.params)["turnId"] as? String
        }
        #expect(interruptTurnIDs == ["turn-old", "turn-new"])
        let rollback = try #require(requests.first { $0.method == "thread/rollback" })
        let rollbackParams = try jsonObject(from: rollback.params)
        #expect(rollbackParams["threadId"] as? String == "review-thread")
        #expect(rollbackParams["numTurns"] as? Int == 1)
        let reviewStarts = requests.filter { $0.method == "review/start" }
        let restart = try #require(reviewStarts.last)
        let restartParams = try jsonObject(from: restart.params)
        #expect(restartParams["threadId"] as? String == "thread-1")
    }

    @Test func shutdownCleanupDoesNotDeleteProvisionalRestartSourceThread() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(turnID: "turn-old", reviewThreadID: "thread-1")
        await runtime.transport.waitForNotificationStreamCount(1)
        let backend = AppServerCodexReviewBackend(appServer: runtime.server)
        let attempt = try await backend.startReview(makeReviewStart())
        try await runtime.transport.enqueueJSON(
            #"{"thread":{"id":"thread-1"},"model":"gpt-5"}"#,
            for: "thread/resume"
        )
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
        let prepareTask = Task {
            try await backend.prepareReviewRestart(attempt.run)
        }
        defer {
            prepareTask.cancel()
        }
        await runtime.transport.waitForRequest(method: "turn/interrupt")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "thread-1",
                turn: .init(id: "turn-old", status: "interrupted")
            )
        )
        let token = try await withTimeout {
            try await prepareTask.value
        }

        let reviewStartGate = CodexAppServerTestGate()
        try await runtime.transport.enqueueJSON(
            #"{"thread":{"id":"thread-1"},"model":"gpt-5"}"#,
            for: "thread/resume"
        )
        try await runtime.transport.enqueueEmpty(for: "thread/rollback")
        try await runtime.transport.enqueueJSON(
            #"{"thread":{"id":"thread-1"},"model":"gpt-5"}"#,
            for: "thread/resume"
        )
        try await runtime.transport.enqueueReviewStart(turnID: "turn-restarted", reviewThreadID: "thread-1")
        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        await runtime.transport.holdNextIgnoringCancellation(
            method: "review/start",
            gate: reviewStartGate
        )
        let restartTask = Task {
            try await backend.restartPreparedReview(token, request: makeReviewStart())
        }
        defer {
            restartTask.cancel()
        }
        await runtime.transport.waitForRequest(method: "review/start", count: 2)

        await backend.cleanupActiveReviewsForShutdown(.init(
            reason: .init(message: "Review runtime stopped."),
            recoveryWaitingRuns: [attempt.run]
        ))

        #expect(await runtime.transport.recordedRequests(method: "thread/delete").isEmpty)
        await reviewStartGate.open()
        let restartedAttempt = try await withTimeout {
            try await restartTask.value
        }
        #expect(restartedAttempt.run.threadID == "thread-1")
        #expect(restartedAttempt.run.turnID == "turn-restarted")
    }
}

private enum AppServerClientTestTimeout: Error {
    case timedOut
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

private func nextEvent(
    from mailbox: BackendReviewEventMailbox,
    timeout: Duration = .seconds(1)
) async throws -> CodexReviewBackendModel.Review.Event? {
    try await withThrowingTaskGroup(of: CodexReviewBackendModel.Review.Event?.self) { group in
        group.addTask {
            try await mailbox.next()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw AppServerClientTestTimeout.timedOut
        }
        let event = try await group.next()
        group.cancelAll()
        return event ?? nil
    }
}

private func eventSequence(
    _ attempt: BackendReviewAttempt,
    includingDomainEvents: Bool = false
) -> BackendReviewEventSequence {
    BackendReviewEventSequence(mailbox: attempt.events, includesDomainEvents: includingDomainEvents)
}

private func makeReviewStart(
    jobID: String = "job-1",
    sessionID: String = "session-1",
    target: CodexReviewAPI.Target = .uncommittedChanges
) -> CodexReviewBackendModel.Review.Start {
    .init(
        jobID: jobID,
        sessionID: sessionID,
        request: .init(cwd: "/tmp/project", target: target),
        model: "gpt-5"
    )
}

private func jsonObject(from data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private struct TestTurnNotification: Encodable, Sendable {
    var threadID: String
    var turn: TestTurn

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
    }
}

private struct TestTurn: Encodable, Sendable {
    var id: String
    var status: String
}

private struct TestDeltaNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var delta: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case delta
    }
}

private struct TestItemNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var item: TestItem

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case item
    }
}

private struct TestItem: Encodable, Sendable {
    var type: String
    var id: String
    var text: String?
    var review: String?
    var command: String?
    var cwd: String?
    var aggregatedOutput: String?
    var exitCode: Int?
    var status: String?

    init(
        type: String,
        id: String,
        text: String? = nil,
        review: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        aggregatedOutput: String? = nil,
        exitCode: Int? = nil,
        status: String? = nil
    ) {
        self.type = type
        self.id = id
        self.text = text
        self.review = review
        self.command = command
        self.cwd = cwd
        self.aggregatedOutput = aggregatedOutput
        self.exitCode = exitCode
        self.status = status
    }
}
