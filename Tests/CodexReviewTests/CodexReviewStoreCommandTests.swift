import Foundation
import Testing
@_spi(Testing) @testable import CodexReview
import CodexReviewTesting

@Suite("Codex review store", .serialized)
@MainActor
struct CodexReviewStoreCommandTests {
    @Test func storeBackendForwardsExplicitAdmission() async throws {
        let reviewBackend = FakeCodexReviewBackend()
        let storeBackend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let request = CodexReviewBackendModel.Review.Start(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        let admission = ReviewStartAdmission()

        let explicitAttempt = try await storeBackend.startReview(request, admission: admission)
        #expect(await reviewBackend.receivedStartAdmission(admission))
        #expect(await admission.currentPhase() == .active(explicitAttempt.run))
        let commands = await reviewBackend.recordedCommands()
        #expect(commands.contains(.startReview(request)))
    }

    @Test func failedExplicitInitialStartCleansItsExactProvisionalRun() async throws {
        let provisionalRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-provisional",
            threadID: "thread-provisional",
            reviewThreadID: "thread-provisional",
            model: "gpt-5"
        )
        let backend = OutcomeUnknownStartStoreBackend(provisionalRun: provisionalRun)
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )

        let result = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )

        #expect(result.core.lifecycle.status == .cancelled)
        #expect(backend.cleanedRuns == [provisionalRun])
        #expect(store.reviewAttemptOwnerships["job-1"] == nil)
    }

    @Test func failedInitialPublicationCleansOnlyItsReturnedAttempt() async throws {
        let returnedRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-shared",
            threadID: "thread-shared",
            turnID: "turn-returned",
            reviewThreadID: "review-returned",
            model: "gpt-5"
        )
        let admittedRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-shared",
            threadID: "thread-shared",
            turnID: "turn-admitted",
            reviewThreadID: "review-admitted",
            model: "gpt-5"
        )
        let backend = MismatchedReturnedAttemptStoreBackend(
            returnedRun: returnedRun,
            admittedRun: admittedRun
        )
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            idGenerator: .init(next: { "job-1" })
        )

        let result = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )

        #expect(result.core.lifecycle.status == .failed)
        #expect(backend.cleanedRuns == [returnedRun])
        #expect(backend.cleanedRuns.contains(admittedRun) == false)
        #expect(store.reviewAttemptOwnerships["job-1"] == nil)
        #expect(store.reviewWorkerTasks["job-1"] == nil)
    }

    @Test func reviewStartPublishesCompletedJobAndRetainsResult() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            clock: .init(now: { Date(timeIntervalSince1970: 1) }),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.log("started"))
            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            let read = try await result

            #expect(read.jobID == "job-1")
            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.output.lastAgentMessage == "review text")
            #expect(store.listReviews(sessionID: nil).items.map(\.jobID) == ["job-1"])

            let commands = await backend.recordedCommands()
            #expect(commands.contains(.cleanupReview(.init(
                threadID: "thread-1",
                turnID: "turn-1",
                reviewThreadID: "review-thread-1"
            ))))
        }
    }

    @Test func boundedReviewStartReturnsRunningSnapshotAndCanBeAwaitedLater() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            let running = try await result

            #expect(running.jobID == "job-1")
            #expect(running.core.lifecycle.status == .running)
            #expect(running.core.output.hasFinalReview == false)

            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            let final = try await store.awaitReview(
                sessionID: "session-1",
                jobID: "job-1",
                timeout: .seconds(1)
            )

            #expect(final.core.lifecycle.status == .succeeded)
            #expect(final.core.output.lastAgentMessage == "review text")
        }
    }

    @Test func awaitReviewReturnsWhenRunningJobCompletes() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let start = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await start

            async let awaited = store.awaitReview(
                sessionID: "session-1",
                jobID: "job-1",
                timeout: .seconds(1)
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            let final = try await awaited

            #expect(final.core.lifecycle.status == .succeeded)
            #expect(final.core.output.lastAgentMessage == "review text")
        }
    }

    @Test func awaitReviewReturnsWhenRunningJobIsCancelled() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let start = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await start

            async let awaited = store.awaitReview(
                sessionID: "session-1",
                jobID: "job-1",
                timeout: .seconds(1)
            )
            async let cancel = store.cancelReview(
                jobID: "job-1",
                cancellation: .mcpClient(message: "Stop")
            )
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            await backend.yield(.cancelled("Stop"))
            _ = try await cancel
            let final = try await awaited

            #expect(final.core.lifecycle.status == .cancelled)
            #expect(final.core.output.summary == "Stop")
        }
    }

    @Test func forceStartWhileRunningInvokesBackendRestartPath() async {
        let reviewBackend = FakeCodexReviewBackend()
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await withStoreCommandTestCleanup(backend: reviewBackend, store: store) {
            await store.start()
            await store.start()
            await store.start(forceRestartIfNeeded: true)

            #expect(backend.startRequests == [false, true])
        }
    }

    @Test func reviewStartPassesEffectiveSettingsModelToBackend() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(
                reviewBackend: backend,
                seed: .init(initialSettingsSnapshot: .init(fallbackModel: "gpt-5.5"))
            ),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            _ = try await result

            let commands = await backend.recordedCommands()
            let starts = commands.compactMap { command -> CodexReviewBackendModel.Review.Start? in
                if case .startReview(let request) = command {
                    return request
                }
                return nil
            }
            #expect(starts.first?.model == "gpt-5.5")
        }
    }

    @Test func reviewStartPreservesCanonicalResponseTurnAndMergesAgentMessageDeltas() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.started(turnID: "turn-actual", reviewThreadID: "review-thread-1", model: "gpt-5.5"))
            await backend.yield(.messageDelta("hello", itemID: "message-1"))
            await backend.yield(.messageDelta(" world", itemID: "message-1"))
            await backend.yield(.logEntry(
                kind: .reasoningSummary,
                text: " with space",
                groupID: "reasoning-1",
                replacesGroup: false
            ))
            await backend.yield(.completed(summary: "Succeeded.", result: "hello world"))
            let read = try await result

            #expect(read.core.run.turnID == "turn-1")
            #expect(read.core.output.lastAgentMessage == "hello world")
            #expect(read.rawLogText.isEmpty)
            #expect(try store.readReview(jobID: "job-1").logs.map(\.text) == [
                "hello world",
                " with space",
                "hello world",
            ])
            #expect(try #require(store.job(id: "job-1")).reviewOutputText == "hello world\n\n with space\n\nhello world")
            #expect(try store.readReview(jobID: "job-1").core.run.model == nil)
        }
    }

    @Test func reviewStartTracksAgentMessageDeltasByItemID() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.messageDelta("first", itemID: "message-1"))
            await backend.yield(.messageDelta("second", itemID: "message-2"))
            await backend.yield(.logEntry(
                kind: .agentMessage,
                text: "second",
                groupID: "message-2",
                replacesGroup: true,
                metadata: .init(sourceType: "canonicalReviewResult")
            ))
            await backend.yield(.completed(summary: "Succeeded.", result: "second"))
            let read = try await result

            #expect(read.core.output.lastAgentMessage == "second")
            #expect(read.core.reviewText == "second")
            #expect(try store.readReview(jobID: "job-1").logs.map(\.text) == ["first", "second"])
        }
    }

    @Test func reviewCompletionDoesNotDuplicateAlreadyLoggedFinalMessage() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.logEntry(
                kind: .agentMessage,
                text: "final review text",
                groupID: "review-item-1",
                replacesGroup: true,
                metadata: .init(sourceType: "exitedReviewMode")
            ))
            await backend.yield(.completed(summary: "Succeeded.", result: "final review text"))
            let read = try await result

            #expect(read.core.output.lastAgentMessage == "final review text")
            #expect(read.core.reviewText == "final review text")
            #expect(try store.readReview(jobID: "job-1").logs.map(\.text) == ["final review text"])
        }
    }

    @Test func reviewCompletionEnforcesLogLimitWithCanonicalFinalResult() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let initialText = String(repeating: "a", count: 250 * 1024)
            let delta = String(repeating: "b", count: 20 * 1024)

            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.logEntry(
                kind: .rawReasoning,
                text: initialText,
                groupID: "reasoning-1",
                replacesGroup: false
            ))
            await backend.yield(.logEntry(
                kind: .rawReasoning,
                text: delta,
                groupID: "reasoning-1",
                replacesGroup: false
            ))
            await backend.yield(.completed(summary: "Succeeded.", result: "Review completed."))
            let read = try await result
            let job = try #require(store.job(id: "job-1"))

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(job.cappedLogBytes <= 256 * 1024)
            #expect(job.logText.contains(delta))
            #expect(job.logText.hasSuffix("Review completed."))
            #expect(job.lastLogMutation == .reload)
        }
    }

    @Test func readReviewDefaultsToCommandOutputFilteredLogs() throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let job = CodexReviewJob.makeForTesting(
            id: "job-1",
            cwd: "/tmp/project",
            targetSummary: "Uncommitted changes",
            status: .succeeded,
            summary: "Done",
            logEntries: [
                .init(kind: .event, text: "Turn started: turn-1"),
                .init(kind: .progress, text: "Reviewing current changes"),
                .init(kind: .command, groupID: "cmd-1", text: "$ swift test"),
                .init(kind: .commandOutput, groupID: "cmd-1", text: "Tests passed"),
                .init(kind: .plan, groupID: "plan-1", text: "Plan text"),
                .init(kind: .todoList, groupID: "turn-1", text: "[inProgress] Inspect diff"),
                .init(kind: .reasoningSummary, groupID: "reasoning-1:summary:0", text: "Reasoning summary"),
                .init(kind: .rawReasoning, groupID: "reasoning-1:0", text: "Raw reasoning"),
                .init(kind: .toolCall, groupID: "tool-1", text: "MCP tool started"),
                .init(kind: .diagnostic, text: "Warning"),
                .init(kind: .error, text: "Recoverable error"),
                .init(kind: .agentMessage, text: "No correctness issues found."),
            ]
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [.init(cwd: "/tmp/project")],
            jobs: [job]
        )

        #expect(try store.readReview(jobID: "job-1").logs.map(\.kind) == [
            .event,
            .progress,
            .command,
            .plan,
            .todoList,
            .reasoningSummary,
            .rawReasoning,
            .toolCall,
            .diagnostic,
            .error,
            .agentMessage,
        ])
        #expect(try store.readReview(jobID: "job-1", logFilter: .all).logs.map(\.kind) == [
            .event,
            .progress,
            .command,
            .commandOutput,
            .plan,
            .todoList,
            .reasoningSummary,
            .rawReasoning,
            .toolCall,
            .diagnostic,
            .error,
            .agentMessage,
        ])
    }

    @Test func readReviewDefaultsToLatestPagedLogs() throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let entries = (0..<125).map { index in
            ReviewLogEntry(kind: .progress, text: "line-\(index)")
        }
        let job = CodexReviewJob.makeForTesting(
            id: "job-1",
            cwd: "/tmp/project",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: entries
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [.init(cwd: "/tmp/project")],
            jobs: [job]
        )

        let read = try store.readReview(jobID: "job-1")

        #expect(read.logs.map(\.text).first == "line-25")
        #expect(read.logs.map(\.text).last == "line-124")
        #expect(read.logsPage == CodexReviewAPI.Log.Page(
            total: 125,
            offset: 25,
            limit: 100,
            returned: 100,
            hasMoreBefore: true,
            hasMoreAfter: false,
            previousOffset: 0,
            nextOffset: nil
        ))
    }

    @Test func readReviewReturnsRequestedLogPage() throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let entries = (0..<12).map { index in
            ReviewLogEntry(kind: .progress, text: "line-\(index)")
        }
        let job = CodexReviewJob.makeForTesting(
            id: "job-1",
            cwd: "/tmp/project",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: entries
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [.init(cwd: "/tmp/project")],
            jobs: [job]
        )

        let read = try store.readReview(
            jobID: "job-1",
            logPage: .init(offset: 5, limit: 4)
        )

        #expect(read.logs.map(\.text) == ["line-5", "line-6", "line-7", "line-8"])
        #expect(read.logsPage == CodexReviewAPI.Log.Page(
            total: 12,
            offset: 5,
            limit: 4,
            returned: 4,
            hasMoreBefore: true,
            hasMoreAfter: true,
            previousOffset: 1,
            nextOffset: 9
        ))
    }

    @Test func readReviewRejectsInvalidLogPageRequests() throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let job = CodexReviewJob.makeForTesting(
            id: "job-1",
            cwd: "/tmp/project",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running"
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [.init(cwd: "/tmp/project")],
            jobs: [job]
        )

        #expect(throws: (any Error).self) {
            try store.readReview(jobID: "job-1", logPage: .init(offset: -1))
        }
        #expect(throws: (any Error).self) {
            try store.readReview(jobID: "job-1", logPage: .init(limit: -1))
        }
        #expect(throws: (any Error).self) {
            try store.readReview(jobID: "job-1", logPage: .init(limit: CodexReviewAPI.Log.PageRequest.maxLimit + 1))
        }
    }

    @Test func readReviewProjectsGroupedLogEntriesBeforeFilteringAndPaging() throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let job = CodexReviewJob.makeForTesting(
            id: "job-1",
            cwd: "/tmp/project",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .reasoningSummary, groupID: "reasoning-1", text: "first"),
                .init(kind: .reasoningSummary, groupID: "reasoning-1", text: " + second"),
                .init(
                    kind: .plan,
                    groupID: "plan-1",
                    text: "- old",
                    metadata: .init(sourceType: "plan", status: "inProgress")
                ),
                .init(kind: .plan, groupID: "plan-1", replacesGroup: true, text: "- new"),
                .init(kind: .command, groupID: "cmd-1", text: "$ swift test"),
                .init(kind: .commandOutput, groupID: "cmd-1", text: "output"),
                .init(kind: .agentMessage, text: "Done"),
            ]
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [.init(cwd: "/tmp/project")],
            jobs: [job]
        )

        let defaultRead = try store.readReview(jobID: "job-1")
        let allRead = try store.readReview(jobID: "job-1", logFilter: .all)

        #expect(defaultRead.logs.map(\.text) == [
            "first + second",
            "- new",
            "$ swift test",
            "Done",
        ])
        #expect(defaultRead.logs.allSatisfy { $0.replacesGroup == false })
        #expect(defaultRead.logs.first { $0.groupID == "plan-1" }?.metadata == nil)
        #expect(defaultRead.logsPage.total == 4)
        #expect(allRead.logs.map(\.text) == [
            "first + second",
            "- new",
            "$ swift test",
            "output",
            "Done",
        ])
        #expect(allRead.logsPage.total == 5)
    }

    @Test func readReviewFoldsReplacementOnlyGroupedKindsBeforePaging() throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let job = CodexReviewJob.makeForTesting(
            id: "job-1",
            cwd: "/tmp/project",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .progress, groupID: "progress-1", replacesGroup: true, text: "Reviewing started"),
                .init(kind: .progress, groupID: "progress-1", replacesGroup: true, text: "Reviewing completed"),
                .init(kind: .toolCall, groupID: "tool-1", replacesGroup: true, text: "MCP tool started"),
                .init(kind: .toolCall, groupID: "tool-1", replacesGroup: true, text: "MCP tool completed"),
                .init(kind: .todoList, groupID: "turn-1", replacesGroup: true, text: "[inProgress] Inspect"),
                .init(kind: .todoList, groupID: "turn-1", replacesGroup: true, text: "[completed] Inspect"),
                .init(kind: .event, groupID: "turn-1", replacesGroup: true, text: "old diff"),
                .init(kind: .event, groupID: "turn-1", replacesGroup: true, text: "new diff"),
                .init(kind: .progress, groupID: "progress-2", text: "first progress"),
                .init(kind: .progress, groupID: "progress-2", text: "second progress"),
                .init(kind: .toolCall, groupID: "tool-2", replacesGroup: true, text: "Tool 2 started"),
                .init(kind: .toolCall, groupID: "tool-2", text: "Tool 2 progress"),
                .init(kind: .toolCall, groupID: "tool-2", replacesGroup: true, text: "Tool 2 completed"),
            ]
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [.init(cwd: "/tmp/project")],
            jobs: [job]
        )

        let read = try store.readReview(jobID: "job-1", logPage: .init(limit: 10))

        #expect(read.logs.map(\.text) == [
            "Reviewing completed",
            "MCP tool completed",
            "[completed] Inspect",
            "new diff",
            "first progress",
            "second progress",
            "Tool 2 completed",
            "Tool 2 progress",
        ])
        #expect(read.logs.allSatisfy { $0.replacesGroup == false })
        #expect(read.logsPage.total == 8)
    }

    @Test func reviewStartParsesFinalReviewFindings() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(summary: "Succeeded.", result: """
            Full review comments:
            - [P2] Add parser tests — Sources/Parser.swift:12-15
              The final review parser should be covered at the model layer.
            """))
            let read = try await result

            #expect(read.core.output.hasFinalReview)
            #expect(read.core.output.reviewResult?.state == .hasFindings)
            #expect(read.core.output.reviewResult?.findingCount == 1)
            #expect(read.core.output.reviewResult?.findings.first?.title == "[P2] Add parser tests")
        }
    }

    @Test func newlyStartedWorkspaceAppearsBeforeExistingWorkspaces() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let first = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/old-project", target: .baseBranch("main"))
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "first"))
            _ = try await first
            await backend.finishEvents()

            async let second = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/new-project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "second"))
            _ = try await second

            #expect(store.orderedWorkspaces.map(\.cwd) == ["/tmp/new-project", "/tmp/old-project"])
        }
    }

    @Test func newlyStartedWorkspaceUsesSortOrderAboveCurrentMaximum() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            store.loadForTesting(
                serverState: .running,
                workspaces: [.init(cwd: "/tmp/old-project")]
            )
            store.workspace(cwd: "/tmp/old-project")?.sortOrder = 10

            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/new-project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "new"))
            _ = try await result

            #expect(store.orderedWorkspaces.map(\.cwd) == ["/tmp/new-project", "/tmp/old-project"])
        }
    }

    @Test func newlyStartedReviewAppearsBeforeExistingJobsInWorkspace() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let first = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "first"))
            _ = try await first
            await backend.finishEvents()

            async let second = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "second"))
            _ = try await second

            #expect(store.orderedJobs(inWorkspace: "/tmp/project").map(\.targetSummary) == [
                "Uncommitted changes",
                "Base branch: main",
            ])
        }
    }

    @Test func runningReviewElapsedSecondsUsesInjectedClock() async throws {
        let backend = FakeCodexReviewBackend()
        let clock = MutableTestClock(Date(timeIntervalSince1970: 1))
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            clock: .init(now: { clock.now() }),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilJobStatus(.running, jobID: "job-1") != nil)
            clock.current = Date(timeIntervalSince1970: 13)

            #expect(try store.readReview(jobID: "job-1").elapsedSeconds == 12)

            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            _ = try await result
        }
    }

    @Test func newlyStartedReviewUsesSortOrderAboveCurrentWorkspaceMaximum() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let existing = CodexReviewJob.makeForTesting(
                id: "job-existing",
                cwd: "/tmp/project",
                targetSummary: "Existing",
                status: .succeeded,
                summary: "Done"
            )
            store.loadForTesting(
                serverState: .running,
                workspaces: [.init(cwd: "/tmp/project")],
                jobs: [existing]
            )
            store.job(id: "job-existing")?.sortOrder = 10

            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "new"))
            _ = try await result

            #expect(store.orderedJobs(inWorkspace: "/tmp/project").map(\.targetSummary).first == "Uncommitted changes")
        }
    }

    @Test func cancelRunningReviewUsesBackendInterruptAndPublicState() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilRunAttempt("attempt-1", jobID: "job-1") != nil)
            async let cancellation = store.cancelReview(
                jobID: "job-1",
                cancellation: .mcpClient(message: "Stop")
            )
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            await backend.yield(.cancelled("Stop"))
            let cancel = try await cancellation
            _ = try await result

            #expect(cancel.cancelled)
            #expect(try store.readReview(jobID: "job-1").core.lifecycle.status == .cancelled)
            let commands = await backend.recordedCommands()
            #expect(commands.contains { if case .interruptReviewAdmission(_, let reason) = $0 { reason.message == "Stop" } else { false } })
        }
    }

    @Test func cancellationEnforcesLogLimitWithoutPostTerminalAppend() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let initialText = String(repeating: "a", count: 250 * 1024)
            let delta = String(repeating: "b", count: 20 * 1024)

            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            await backend.yield(.logEntry(
                kind: .rawReasoning,
                text: initialText,
                groupID: "reasoning-1",
                replacesGroup: false
            ))
            await backend.yield(.logEntry(
                kind: .rawReasoning,
                text: delta,
                groupID: "reasoning-1",
                replacesGroup: false
            ))
            #expect(await waitUntil {
                store.job(id: "job-1")?.logText.hasSuffix(delta) == true
            })
            async let cancellation = store.cancelReview(
                jobID: "job-1",
                cancellation: .mcpClient(message: "Stop")
            )
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            await backend.yield(.cancelled("Stop"))
            _ = try await cancellation
            let read = try await result
            let job = try #require(store.job(id: "job-1"))

            #expect(read.core.lifecycle.status == .cancelled)
            #expect(job.cappedLogBytes <= 256 * 1024)
            #expect(job.logText.hasSuffix(delta))
            #expect(job.lastLogMutation == .reload)
        }
    }

    @Test func transientNetworkOutageDoesNotRecoverReview() async throws {
        let backend = FakeCodexReviewBackend()
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let debounceGate = AsyncGate()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(
                outageDebounce: .seconds(10),
                recoverySettle: .seconds(1),
                sleep: { _ in await debounceGate.wait() }
            )
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            networkMonitor.yield(.satisfied())
            await debounceGate.open()

            let attemptedRecovery = await waitUntil(timeout: .milliseconds(100)) {
                await backend.recordedCommands().contains { command in
                    if case .prepareReviewRecovery = command { true } else { false }
                }
            }
            #expect(attemptedRecovery == false)

            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            let read = try await result
            #expect(read.core.lifecycle.status == .succeeded)
        }
    }

    @Test func sustainedNetworkOutageInterruptsForRecoveryWithoutTerminalJob() async throws {
        let backend = FakeCodexReviewBackend()
        let interruptGate = AsyncGate()
        await backend.holdInterruptReview(with: interruptGate)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            let becameActive = await waitUntil(timeout: .seconds(2)) {
                if case .active = store.reviewAttemptOwnerships["job-1"] { true } else { false }
            }
            try #require(becameActive)
            try await scriptRecoveryRoute(in: store)
            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            guard case .recovering(let receipt) = store.reviewAttemptOwnerships["job-1"] else {
                Issue.record("Store did not publish the recovery receipt.")
                return
            }
            await backend.yield(.cancelled("Network recovery"), for: receipt.source.run)
            let terminalWasRecorded = await waitUntil(timeout: .seconds(2)) {
                if case .finishingRecovery = await receipt.source.admission.currentPhase() {
                    true
                } else {
                    false
                }
            }
            await interruptGate.open()
            try #require(terminalWasRecorded)
            try await backend.waitForPrepareReviewRecovery(timeout: .seconds(2))

            let running = try store.readReview(jobID: "job-1")
            #expect(running.core.lifecycle.status == .running)
            #expect(running.core.output.summary == "Network unavailable; waiting to reconnect.")
            #expect(await backend.recordedCommands().filter {
                if case .prepareReviewRecovery = $0 { true } else { false }
            }.count == 1)
            async let cancellation = store.cancelReview(
                jobID: "job-1",
                cancellation: .mcpClient(message: "Stop")
            )
            await backend.yield(.cancelled("Stop"))
            _ = try await cancellation
            _ = try await result
        }
    }

    @Test func rejectedRecoveryInterruptWakesWorkerWithoutSourceTerminal() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: run)
        await backend.rejectInterrupts(message: "Recovery interrupt rejected.")
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let review = Task { @MainActor in
                try await store.startReview(
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                )
            }
            try #require(await StoreSnapshotProbe(store: store).waitUntilRunAttempt(
                run.attemptID,
                jobID: "job-1"
            ) != nil)

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            try #require(await StoreSnapshotProbe(store: store).waitUntilJobStatus(
                .failed,
                jobID: "job-1"
            ) != nil)
            let result = try await review.value
            let commands = await backend.recordedCommands()

            #expect(result.core.lifecycle.status == .failed)
            #expect(commands.filter { if case .interruptReviewAdmission = $0 { true } else { false } }.count == 1)
            #expect(commands.contains(.cleanupReview(run)))
            #expect(commands.contains { if case .prepareReviewRecovery = $0 { true } else { false } } == false)
            #expect(store.reviewAttemptOwnerships["job-1"] == nil)
            #expect(store.reviewWorkerTasks["job-1"] == nil)
        }
    }

    @Test func networkRecoveryWaitDiscardsOldAttemptCompletion() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let running = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                waitTimeout: .milliseconds(20)
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await resolveTypedRecoveryDisposition(backend: backend, store: store)
            _ = try await running

            await backend.yield(.message("completed review text"), for: initialRun)
            await backend.yield(.completed(summary: "Succeeded.", result: nil), for: initialRun)
            networkMonitor.yield(.satisfied())
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))
            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let final = try await store.awaitReview(sessionID: "session-1", jobID: "job-1", timeout: .seconds(1))

            #expect(final.core.lifecycle.status == .succeeded)
            #expect(final.core.run.turnID == "turn-2")
            #expect(final.core.output.lastAgentMessage == "recovered review")
            let logText = try store.readReview(jobID: "job-1").logs.map(\.text).joined(separator: "\n")
            #expect(logText.contains("completed review text") == false)
        }
    }

    @Test func networkRecoveryDiscardsOldAttemptEventsDuringRecoverySettle() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let settleGate = AsyncGate()
        let sleeper = ControlledTestSleeper(gate: settleGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(
                outageDebounce: .seconds(10),
                recoverySettle: .seconds(1),
                sleep: { _ in await sleeper.sleep() }
            )
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await resolveTypedRecoveryDisposition(backend: backend, store: store)
            await sleeper.blockFutureSleeps()
            networkMonitor.yield(.satisfied())
            #expect(await waitUntil {
                store.job(id: "job-1")?.core.output.summary == "Network restored; restarting review."
            })

            await backend.yield(.message("completed during settle"), for: initialRun)
            await backend.yield(.completed(summary: "Succeeded.", result: nil), for: initialRun)
            await settleGate.open()
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))
            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-2")
            #expect(read.core.output.lastAgentMessage == "recovered review")
            let logText = try store.readReview(jobID: "job-1").logs.map(\.text).joined(separator: "\n")
            #expect(logText.contains("completed during settle") == false)
        }
    }

    @Test func networkRecoveryRepeatedSatisfiedSnapshotsRestartAfterLatestSettle() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let settleGate = AsyncGate()
        let sleeper = ControlledTestSleeper(gate: settleGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(
                outageDebounce: .seconds(10),
                recoverySettle: .seconds(1),
                sleep: { _ in await sleeper.sleep() }
            )
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await resolveTypedRecoveryDisposition(backend: backend, store: store)
            await sleeper.blockFutureSleeps()
            networkMonitor.yield(.satisfied())
            #expect(await waitUntil {
                store.job(id: "job-1")?.core.output.summary == "Network restored; restarting review."
            })
            networkMonitor.yield(.satisfied())
            await settleGate.open()
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))

            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-2")
            #expect(read.core.output.lastAgentMessage == "recovered review")
        }
    }

    @Test func networkRecoveryClosesActiveCommandsAsCanceled() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let running = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                waitTimeout: .milliseconds(20)
            )
            await backend.yield(.logEntry(
                kind: .command,
                text: "$ git diff",
                groupID: "cmd-1",
                replacesGroup: true,
                metadata: .init(
                    sourceType: "commandExecution",
                    status: "inProgress",
                    itemID: "cmd-1",
                    command: "git diff",
                    startedAt: Date(timeIntervalSince1970: 1),
                    commandStatus: "inProgress"
                )
            ), for: initialRun)
            try #require(await StoreSnapshotProbe(store: store).waitUntilLogs(
                jobID: "job-1"
            ) { logs in
                logs.contains {
                    $0.kind == .command
                        && $0.groupID == "cmd-1"
                        && $0.metadata?.commandStatus == "inProgress"
                }
            } != nil)

            networkMonitor.yield(.init(status: .unsatisfied))
            try await resolveTypedRecoveryDisposition(backend: backend, store: store)
            _ = try await running
            networkMonitor.yield(.satisfied())
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))
            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)

            let final = try await store.awaitReview(sessionID: "session-1", jobID: "job-1", timeout: .seconds(1))
            let commandLogs = try #require(store.job(id: "job-1"))
                .logEntries
                .filter { $0.kind == .command && $0.groupID == "cmd-1" }
            let closed = try #require(commandLogs.last)

            #expect(final.core.lifecycle.status == .succeeded)
            #expect(commandLogs.count == 2)
            #expect(closed.metadata?.status == "canceled")
            #expect(closed.metadata?.commandStatus == "canceled")
        }
    }

    @Test func networkRecoveryUsesCanonicalResponseTurn() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-response",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-recovered",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            await backend.yield(.started(
                turnID: "turn-actual",
                reviewThreadID: "review-thread-1",
                model: "gpt-5"
            ), for: initialRun)
            #expect(await waitUntil {
                store.job(id: "job-1")?.core.run.turnID == "turn-response"
            })

            networkMonitor.yield(.init(status: .unsatisfied))
            try await resolveTypedRecoveryDisposition(backend: backend, store: store)
            let commandsAfterInterrupt = await backend.recordedCommands()
            let interruptedRuns = commandsAfterInterrupt.compactMap { command -> CodexReviewBackendModel.Review.Run? in
                if case .interruptReviewAdmission(let admission, _) = command { admission.run } else { nil }
            }
            #expect(interruptedRuns.last?.turnID == "turn-response")

            networkMonitor.yield(.satisfied())
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))

            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))
            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-recovered")
        }
    }

    @Test func networkRecoveryRestartsReviewOnSameJobAndSucceeds() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await resolveTypedRecoveryDisposition(backend: backend, store: store)
            await backend.yield(.message("stale aborted output"), for: initialRun)
            await backend.yield(.cancelled("Network lost"), for: initialRun)
            networkMonitor.yield(.satisfied())
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            #expect(await waitUntil {
                guard let read = try? store.readReview(jobID: "job-1") else {
                    return false
                }
                return read.core.run.turnID == "turn-2"
            })
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))

            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-2")
            #expect(read.core.run.threadID == "thread-1")
            #expect(read.core.output.lastAgentMessage == "recovered review")
            let logText = try store.readReview(jobID: "job-1").logs.map(\.text).joined(separator: "\n")
            #expect(logText.contains("Network unavailable; waiting to reconnect."))
            #expect(logText.contains("Network restored; restarting review."))
            #expect(logText.contains("stale aborted output") == false)
        }
    }

    @Test func networkRecoveryClearsAbandonedAttemptOutputBeforeRecoveredCompletion() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilJobStatus(.running, jobID: "job-1") != nil)

            await backend.yield(.messageDelta("stale ", itemID: "message-1"), for: initialRun)
            await backend.yield(.messageDelta("output", itemID: "message-1"), for: initialRun)
            try #require(await StoreSnapshotProbe(store: store).waitUntil(timeout: .seconds(2)) {
                $0.job("job-1")?.lastAgentMessage == "stale output"
            } != nil)

            networkMonitor.yield(.init(status: .unsatisfied))
            try await resolveTypedRecoveryDisposition(backend: backend, store: store)
            networkMonitor.yield(.satisfied())
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))

            await backend.yield(.messageDelta("fresh review", itemID: "message-1"), for: recoveredRun)
            await backend.yield(.completed(summary: "Succeeded.", result: "fresh review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-2")
            #expect(read.core.output.lastAgentMessage == "fresh review")
            #expect(read.core.output.hasFinalReview)
            let logText = try store.readReview(jobID: "job-1").logs.map(\.text).joined(separator: "\n")
            #expect(logText.contains("stale output") == false)
            #expect(logText.contains("fresh review"))
        }
    }

    @Test func networkRecoveryIgnoresStaleCompletionAfterRecoveredSubscriptionStarts() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await resolveTypedRecoveryDisposition(backend: backend, store: store)
            networkMonitor.yield(.satisfied())
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))

            await backend.yield(.completed(summary: "Succeeded.", result: "stale review"), for: initialRun)
            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)

            let read = try await result
            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-2")
            #expect(read.core.output.lastAgentMessage == "recovered review")
        }
    }

    @Test func networkRecoveryIgnoresStaleTerminalQueuedWhileRestarting() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let recoverGate = AsyncGate()
        await backend.holdResumeReviewRecovery(with: recoverGate)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await resolveTypedRecoveryDisposition(backend: backend, store: store)
            networkMonitor.yield(.satisfied())
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            await backend.yield(.cancelled("Network lost"), for: initialRun)
            await recoverGate.open()
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))

            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-2")
            #expect(read.core.output.lastAgentMessage == "recovered review")
        }
    }

    @Test func networkRecoveryResubscribesWhenInterruptedEventStreamFinished() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await resolveTypedRecoveryDisposition(backend: backend, store: store)
            await backend.finishEvents(for: initialRun)
            networkMonitor.yield(.satisfied())
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))

            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-2")
            #expect(read.core.output.lastAgentMessage == "recovered review")
        }
    }

    @Test func cancellationWhileRecoveryRestartIsInFlightStopsRecoveredRun() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let recoverGate = AsyncGate()
        await backend.holdResumeReviewRecovery(with: recoverGate)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await resolveTypedRecoveryDisposition(backend: backend, store: store)
            networkMonitor.yield(.satisfied())
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))

            let cancel = try await store.cancelReview(jobID: "job-1", cancellation: .mcpClient(message: "Stop"))
            #expect(cancel.cancelled)
            await recoverGate.open()

            let read = try await result
            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.run.turnID == "turn-1")

            let commands = await backend.recordedCommands()
            #expect(commands.contains(.cleanupReview(initialRun)))
        }
    }

    @Test func cancellationAfterRecoveryEventStreamFinishesWakesWorker() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let running = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                waitTimeout: .milliseconds(20)
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await resolveTypedRecoveryDisposition(backend: backend, store: store)
            _ = try await running
            await backend.finishEvents(for: initialRun)

            let cancel = try await store.cancelReview(jobID: "job-1", cancellation: .mcpClient(message: "Stop"))
            let cleanedUp = await waitUntil {
                store.reviewWorkerTasks["job-1"] == nil && store.reviewAttemptOwnerships["job-1"] == nil
            }
            let read = try store.readReview(jobID: "job-1")

            #expect(cancel.cancelled)
            #expect(cleanedUp)
            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.lifecycle.cancellation?.message == "Stop")
        }
    }

    @Test func registeredCloseCancelsHeldRecoveryStageBeforePublication() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: initialRun)
        await reviewBackend.setNextRecoveredRun(recoveredRun)
        let storeBackend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let stageGate = AsyncGate()
        storeBackend.holdReviewRecoveryStage(with: stageGate)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: storeBackend,
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: reviewBackend, store: store) {
            let review = Task { @MainActor in
                try await store.startReview(
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                )
            }
            networkMonitor.yield(.init(status: .unsatisfied))
            try await resolveTypedRecoveryDisposition(backend: reviewBackend, store: store)
            networkMonitor.yield(.satisfied())
            await storeBackend.waitForReviewRecoveryStage()
            let reason = ReviewCancellation.system(message: "Store work owner closed.")
            let close = Task { @MainActor in
                await store.closeRegisteredStoreWork(reason: reason)
            }
            try #require(await waitUntil { store.storeWorkRegistryStatus == .closing })
            let stageAdmission = try #require(storeBackend.reviewRecoveryCommands.compactMap { command in
                if case .stage(_, _, let admission) = command { admission } else { nil }
            }.last)

            #expect(await stageAdmission.cancellationRequest() == reason)
            await stageGate.open()
            #expect(await close.value == .success)
            let result = try await review.value

            #expect(result.core.lifecycle.status == .cancelled)
            #expect(storeBackend.reviewRecoveryCommands.contains {
                if case .commit = $0 { true } else { false }
            } == false)
            #expect(store.reviewAttemptOwnerships["job-1"] == nil)
        }
    }

    @Test func registeredClosePromotesLinearizedCommitThenCleansDestination() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: initialRun)
        await reviewBackend.setNextRecoveredRun(recoveredRun)
        let storeBackend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let commitGate = AsyncGate()
        storeBackend.holdReviewRecoveryCommit(with: commitGate)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: storeBackend,
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: reviewBackend, store: store) {
            let review = Task { @MainActor in
                try await store.startReview(
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                )
            }
            networkMonitor.yield(.init(status: .unsatisfied))
            try await resolveTypedRecoveryDisposition(backend: reviewBackend, store: store)
            networkMonitor.yield(.satisfied())
            await storeBackend.waitForReviewRecoveryCommit()
            let reason = ReviewCancellation.system(message: "Store work owner closed.")
            let close = Task { @MainActor in
                await store.closeRegisteredStoreWork(reason: reason)
            }
            try #require(await waitUntil { store.storeWorkRegistryStatus == .closing })
            let committedAdmission = try #require(storeBackend.reviewRecoveryCommands.compactMap { command in
                if case .commit(let staged) = command { staged.admission } else { nil }
            }.last)

            #expect(await committedAdmission.cancellationRequest() == reason)
            await commitGate.open()
            #expect(await close.value == .success)
            let result = try await review.value

            #expect(result.core.lifecycle.status == .cancelled)
            #expect(await reviewBackend.recordedCommands().contains(.cleanupReview(recoveredRun)))
            #expect(store.reviewAttemptOwnerships["job-1"] == nil)
        }
    }

    @Test func runtimeDetachCancelsPreparedRecoveryBeforeLateSettle() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: initialRun)
        let storeBackend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let settleStarted = AsyncGate()
        let settleGate = AsyncGate()
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: storeBackend,
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(
                outageDebounce: .zero,
                recoverySettle: .seconds(10),
                sleep: { duration in
                    guard duration == .seconds(10) else { return }
                    await settleStarted.open()
                    await settleGate.waitIgnoringCancellation()
                }
            )
        )
        try await withStoreCommandTestCleanup(backend: reviewBackend, store: store) {
            async let running = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            networkMonitor.yield(.init(status: .unsatisfied))
            try await resolveTypedRecoveryDisposition(backend: reviewBackend, store: store)
            _ = try await running
            networkMonitor.yield(.satisfied())
            await settleStarted.wait()
            let reason = ReviewCancellation.system(message: "Review runtime stopped.")
            let jobIDs = store.cancelActiveReviewsLocallyForRuntimeStop(reason: reason)
            await store.cancelAndDetachReviewWorkersForRuntimeStop(jobIDs: jobIDs, reason: reason)
            await settleGate.open()

            #expect(await store.drainReviewWorkersForRuntimeStop(timeout: .seconds(2)))
            #expect(storeBackend.reviewRecoveryCommands.contains {
                if case .stage = $0 { true } else { false }
            } == false)
            #expect(store.reviewAttemptOwnerships["job-1"] == nil)
        }
    }

    @Test func runtimeStopLocalCancellationDetachesWorker() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: run)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let running = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                waitTimeout: .milliseconds(20)
            )
            _ = try await running

            let locallyCancelledJobIDs = store.cancelActiveReviewsLocallyForRuntimeStop(
                reason: .system(message: "Review runtime stopped.")
            )
            let cancelled = try store.readReview(jobID: "job-1")

            #expect(locallyCancelledJobIDs == ["job-1"])
            #expect(cancelled.core.lifecycle.status == .cancelled)
            #expect(store.reviewWorkerTasks["job-1"] != nil)
            #expect(store.reviewAttemptOwnerships["job-1"]?.run == run)

            await store.cancelAndDetachReviewWorkersForRuntimeStop(
                jobIDs: locallyCancelledJobIDs,
                reason: .system(message: "Review runtime stopped.")
            )

            #expect(store.reviewWorkerTasks["job-1"] == nil)
            #expect(await store.drainRuntimeStopDetachedReviewWorkers(timeout: .seconds(2)))
            #expect(store.reviewAttemptOwnerships["job-1"] == nil)
        }
    }

    @Test func stopInterruptsActiveReviewBeforeMarkingJobStopped() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: run)
        let interruptGate = AsyncGate()
        await backend.holdInterruptReview(with: interruptGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            await store.start()
            async let running = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                waitTimeout: .milliseconds(20)
            )
            _ = try await running

            let stopTask = Task { @MainActor in
                await store.stop()
            }
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            let inFlight = try store.readReview(jobID: "job-1")

            #expect(inFlight.core.lifecycle.status == .running)
            await interruptGate.open()
            await backend.yield(.cancelled("Review runtime stopped."), for: run)
            await stopTask.value

            let stopped = try store.readReview(jobID: "job-1")
            let commands = await backend.recordedCommands()
            #expect(commands.contains { isTypedInterruptCommand($0, run: run, message: "Review runtime stopped.") })
            #expect(stopped.core.lifecycle.status == .cancelled)
            #expect(store.reviewAttemptOwnerships["job-1"] == nil)
            #expect(store.reviewWorkerTasks["job-1"] == nil)
        }
    }

    @Test func registeredWorkCloseFinalizesTypedInterruptFailureBeforeWorkerExit() async throws {
        let backend = FakeCodexReviewBackend()
        let interruptGate = AsyncGate()
        await backend.holdInterruptReview(with: interruptGate)
        await backend.rejectInterrupts(message: "Interrupt failed.")
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        let review = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        try #require(await StoreSnapshotProbe(store: store).waitUntilRunAttempt(
            "attempt-1",
            jobID: "job-1"
        ) != nil)
        let reason = ReviewCancellation.system(message: "Store work owner closed.")
        let closeCompletion = StoreCommandTaskCompletion()
        let close = Task { @MainActor in
            let result = await store.closeRegisteredStoreWork(reason: reason)
            await closeCompletion.complete()
            return result
        }
        try #require(await waitUntil { store.storeWorkRegistryStatus == .closing })
        #expect(store.reviewWorkerTasks["job-1"]?.isCancelled == true)
        try await backend.waitForInterruptReview(timeout: .seconds(2))

        #expect(try store.readReview(jobID: "job-1").core.lifecycle.cancellation == reason)
        #expect(await closeCompletion.isComplete() == false)
        await interruptGate.open()
        #expect(await close.value == .success)
        let final = try await review.value

        #expect(final.core.lifecycle.status == .cancelled)
        #expect(final.core.lifecycle.cancellation == reason)
        #expect(store.job(id: "job-1")?.logEntries.contains {
            $0.kind == .diagnostic && $0.text == "Review cleanup failed: Interrupt failed."
        } == true)
        #expect(store.reviewWorkerTasks["job-1"] == nil)
        #expect(store.storeWorkRegistry.activeOrdinals.isEmpty)
        #expect(await closeCompletion.isComplete())
    }

    @Test func registeredWorkCloseJoinsInterruptWithRecordedTerminal() async throws {
        let backend = FakeCodexReviewBackend()
        let interruptGate = AsyncGate()
        await backend.holdInterruptReview(with: interruptGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        let review = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        try #require(await StoreSnapshotProbe(store: store).waitUntilRunAttempt(
            "attempt-1",
            jobID: "job-1"
        ) != nil)
        guard case .active(let active) = store.reviewAttemptOwnerships["job-1"] else {
            Issue.record("Review did not publish its exact active attempt.")
            return
        }
        let cancellation = Task { @MainActor in
            try await store.cancelReview(
                jobID: "job-1",
                cancellation: .mcpClient(message: "User cancellation.")
            )
        }
        try await backend.waitForInterruptReview(timeout: .seconds(2))
        await backend.yield(.cancelled("User cancellation."), for: active.run)
        try #require(await waitUntil {
            if case .finishing = await active.admission.currentPhase() { true } else { false }
        })
        let closeReason = ReviewCancellation.system(message: "Store work owner closed.")
        let close = Task { @MainActor in
            await store.closeRegisteredStoreWork(reason: closeReason)
        }
        try #require(await waitUntil {
            store.storeWorkRegistryStatus == .closing
        })

        #expect(store.reviewWorkerTasks["job-1"]?.isCancelled == true)
        await interruptGate.open()
        let outcome = try await cancellation.value
        #expect(await close.value == .success)
        let final = try await review.value

        #expect(outcome.core.lifecycle.cancellation?.message == "User cancellation.")
        #expect(final.core.lifecycle.status == .cancelled)
        #expect(final.core.lifecycle.cancellation?.message == "User cancellation.")
        #expect(await backend.recordedCommands().filter {
            if case .interruptReviewAdmission = $0 { true } else { false }
        }.count == 1)
        #expect(store.job(id: "job-1")?.logEntries.contains {
            $0.kind == .diagnostic && $0.text.contains("conflicting active terminals")
        } == false)
        #expect(store.reviewAttemptOwnerships["job-1"] == nil)
        #expect(store.reviewWorkerTasks["job-1"] == nil)
        #expect(store.storeWorkRegistry.activeOrdinals.isEmpty)
    }

    @Test func registeredWorkCloseDrainsWholeBulkCancellation() async throws {
        let firstRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-1",
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let secondRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-2",
            threadID: "thread-2",
            turnID: "turn-2",
            reviewThreadID: "review-thread-2"
        )
        let backend = FakeCodexReviewBackend(nextRun: firstRun)
        let interruptGate = AsyncGate()
        await backend.holdInterruptReview(with: interruptGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let first = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .milliseconds(20)
        )
        try #require(await StoreSnapshotProbe(store: store).waitUntilRunAttempt(
            firstRun.attemptID,
            jobID: first.jobID
        ) != nil)
        await backend.setNextRun(secondRun)
        let second = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
            waitTimeout: .milliseconds(20)
        )
        try #require(await StoreSnapshotProbe(store: store).waitUntilRunAttempt(
            secondRun.attemptID,
            jobID: second.jobID
        ) != nil)
        let cancellation = Task { @MainActor in
            try await store.cancelAllRunningJobs(reason: "User cancelled all reviews.")
        }
        try await backend.waitForInterruptReview(timeout: .seconds(2))
        let closeReason = ReviewCancellation.system(message: "Store work owner closed.")
        let close = Task { @MainActor in
            await store.closeRegisteredStoreWork(reason: closeReason)
        }
        try #require(await waitUntil {
            store.storeWorkRegistryStatus == .closing
        })

        #expect(try store.readReview(jobID: first.jobID).core.lifecycle.cancellation == closeReason)
        #expect(try store.readReview(jobID: second.jobID).core.lifecycle.cancellation == closeReason)
        await interruptGate.open()
        _ = try await cancellation.value
        #expect(await close.value == .success)

        #expect(try store.readReview(jobID: first.jobID).core.lifecycle.status == .cancelled)
        #expect(try store.readReview(jobID: second.jobID).core.lifecycle.status == .cancelled)
        #expect(store.reviewWorkerTasks[first.jobID] == nil)
        #expect(store.reviewWorkerTasks[second.jobID] == nil)
        #expect(store.storeWorkRegistry.activeOrdinals.isEmpty)
    }

    @Test func runtimeStopDetachesNetworkRecoveryWaitingWorker() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: run)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let running = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                waitTimeout: .milliseconds(20)
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await resolveTypedRecoveryDisposition(backend: backend, store: store)
            _ = try await running

            let locallyCancelledJobIDs = store.cancelActiveReviewsLocallyForRuntimeStop(
                reason: .system(message: "Review runtime stopped.")
            )
            await store.cancelAndDetachReviewWorkersForRuntimeStop(
                jobIDs: locallyCancelledJobIDs,
                reason: .system(message: "Review runtime stopped.")
            )

            #expect(store.reviewWorkerTasks["job-1"] == nil)
            guard case .recovering = store.reviewAttemptOwnerships["job-1"] else {
                Issue.record("Runtime stop removed recovery ownership before worker cleanup."); return
            }
            #expect(await store.drainRuntimeStopDetachedReviewWorkers(timeout: .seconds(2)))
            #expect(store.reviewAttemptOwnerships["job-1"] == nil)
        }
    }

    @Test func runtimeStopCanDrainDetachedWorkerCleanup() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: run)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let running = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                waitTimeout: .milliseconds(20)
            )
            _ = try await running

            let locallyCancelledJobIDs = store.cancelActiveReviewsLocallyForRuntimeStop(
                reason: .system(message: "Review runtime stopped.")
            )
            await store.cancelAndDetachReviewWorkersForRuntimeStop(
                jobIDs: locallyCancelledJobIDs,
                reason: .system(message: "Review runtime stopped.")
            )

            #expect(await store.drainRuntimeStopDetachedReviewWorkers(timeout: .seconds(2)))
            #expect(store.runtimeStopDetachedReviewWorkerTasks["job-1"] == nil)
            let commands = await backend.recordedCommands()
            let interruptIndex = try #require(commands.firstIndex { command in
                if case .interruptReviewAdmission(_, let reason) = command {
                    reason.message == "Review runtime stopped."
                } else { false }
            })
            let cleanupIndex = try #require(commands.firstIndex(of: .cleanupReview(run)))
            #expect(interruptIndex < cleanupIndex)
        }
    }

    @Test func runtimeStopBoundedDrainReturnsWhileBackendStartIsStuck() async throws {
        let backend = FakeCodexReviewBackend()
        let startReviewGate = AsyncGate()
        await backend.holdStartReviewIgnoringCancellation(with: startReviewGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let running = Task { @MainActor in
                try await store.startReview(
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
                )
            }
            try await backend.waitForStartReview(timeout: .seconds(2))
            let admission = try #require(startingAdmission(in: store, jobID: "job-1"))

            let locallyCancelledJobIDs = store.cancelActiveReviewsLocallyForRuntimeStop(
                reason: .system(message: "Review runtime stopped.")
            )
            await store.cancelAndDetachReviewWorkersForRuntimeStop(
                jobIDs: locallyCancelledJobIDs,
                reason: .system(message: "Review runtime stopped.")
            )
            let didDrain = await store.drainReviewWorkersForRuntimeStop(
                timeout: .milliseconds(20)
            )
            let resultBeforeStartReviewUnblocked = try await waitForTaskValue(
                running,
                timeout: .seconds(1)
            )
            #expect(startingAdmission(in: store, jobID: "job-1") === admission)
            guard case .startingReview(_, .outcomeUnknown) = await admission.currentPhase() else {
                Issue.record("Detached worker did not retain its exact in-flight admission.")
                return
            }
            await startReviewGate.open()
            await store.cancelAndDrainReviewWorkersForTesting()
            let result = try #require(resultBeforeStartReviewUnblocked)

            #expect(locallyCancelledJobIDs == ["job-1"])
            #expect(didDrain == false)
            #expect(result.core.lifecycle.status == .cancelled)
            #expect(store.reviewWorkerTasks["job-1"] == nil)
            #expect(store.reviewAttemptOwnerships["job-1"] == nil)
            #expect(await backend.recordedCommands().contains(.cleanupReview(.init(
                threadID: "thread-1",
                turnID: "turn-1",
                reviewThreadID: "review-thread-1"
            ))))
        }
    }

    @Test func registeredWorkCloseAwaitsCurrentAndRetiringNetworkDebounceTasks() async throws {
        let backend = FakeCodexReviewBackend()
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let sleepGate = AsyncGate()
        let sleepProbe = StoreCommandSleepProbe()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(
                outageDebounce: .seconds(1),
                recoverySettle: .seconds(1),
                sleep: { _ in
                    await sleepProbe.sleepIgnoringCancellation(on: sleepGate)
                }
            )
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let review = Task { @MainActor in
                try await store.startReview(
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
                )
            }
            try #require(await StoreSnapshotProbe(store: store)
                .waitUntilJobStatus(.running, jobID: "job-1") != nil)

            await sleepProbe.waitForCount(1)
            networkMonitor.yield(.init(status: .unsatisfied))
            await sleepProbe.waitForCount(2)
            networkMonitor.yield(.satisfied())
            await sleepProbe.waitForCount(3)

            let closeCompletion = StoreCommandTaskCompletion()
            let close = Task { @MainActor in
                let result = await store.closeRegisteredStoreWork(
                    reason: .system(message: "Store work closed.")
                )
                await closeCompletion.complete()
                return result
            }
            let workerCancellationStarted = await waitUntil {
                store.reviewWorkerTasks["job-1"]?.isCancelled == true
            }

            #expect(workerCancellationStarted)
            #expect(await closeCompletion.isComplete() == false)
            await sleepGate.open()
            #expect(await close.value == .success)
            #expect(try await review.value.core.lifecycle.status == .cancelled)
            #expect(await closeCompletion.isComplete())
            let finalSleepCount = await sleepProbe.count
            #expect(finalSleepCount == 3)
        }
    }

    @Test func cancellationDuringNetworkRecoveryStopsWhenEventStreamFinishes() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await resolveTypedRecoveryDisposition(backend: backend, store: store)
            _ = try await store.cancelReview(jobID: "job-1", cancellation: .mcpClient(message: "Stop"))
            await backend.finishEvents(for: initialRun)

            let read = try await result
            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.lifecycle.cancellation?.message == "Stop")
        }
    }

    @Test func networkRecoveryIgnoresOldAttemptEventsAfterRecoveryBegins() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await resolveTypedRecoveryDisposition(backend: backend, store: store)
            await backend.yield(.message("stale old attempt output"), for: initialRun)
            await backend.yield(.completed(summary: "Succeeded.", result: nil), for: initialRun)

            networkMonitor.yield(.satisfied())
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))
            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-2")
            #expect(read.core.output.lastAgentMessage == "recovered review")
            let logText = try store.readReview(jobID: "job-1").logs.map(\.text).joined(separator: "\n")
            #expect(logText.contains("stale old attempt output") == false)
        }
    }

    @Test func userCancellationWakesPendingOutageStreamTerminal() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: run)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let outageSleepStarted = AsyncGate()
        let debounceGate = AsyncGate()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in
                await outageSleepStarted.open()
                await debounceGate.wait()
            })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilJobStatus(.running, jobID: "job-1") != nil)

            networkMonitor.yield(.init(status: .unsatisfied))
            await outageSleepStarted.wait()
            await backend.finishEvents(
                throwing: ReviewAttemptStreamFailure.recoverableNetwork(.connection("Network closed")),
                for: run
            )
            guard case .active(let active) = store.reviewAttemptOwnerships["job-1"] else {
                Issue.record("Pending outage did not retain its exact active attempt.")
                return
            }
            try #require(await waitUntil(timeout: .seconds(2)) {
                await active.admission.activeTerminalResolution() != nil
            })
            #expect(try store.readReview(jobID: "job-1").core.lifecycle.status == .running)

            async let cancel = store.cancelReview(
                jobID: "job-1", cancellation: .mcpClient(message: "Stop")
            )
            _ = try await cancel
            let read = try await result
            await debounceGate.open()

            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.lifecycle.cancellation?.message == "Stop")
            #expect(store.reviewAttemptOwnerships["job-1"] == nil)
            #expect(store.reviewWorkerTasks["job-1"] == nil)
            #expect(await backend.recordedCommands().contains {
                if case .interruptReviewAdmission = $0 { true } else { false }
            } == false)
        }
    }

    @Test func recoveryFailureFailsReviewAndLogsError() async throws {
        let backend = FakeCodexReviewBackend()
        await backend.failRecovery(message: "Rollback failed")
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .requiresConnection))
            try await resolveTypedRecoveryDisposition(backend: backend, store: store)
            networkMonitor.yield(.satisfied())
            let read = try await result

            #expect(read.core.lifecycle.status == .failed)
            #expect(read.core.lifecycle.errorMessage == "Rollback failed")
            #expect(read.logs.contains { $0.kind == .error && $0.text == "Rollback failed" })
        }
    }

    @Test func cancelRunningReviewClosesActiveCommandLog() async throws {
        let backend = FakeCodexReviewBackend()
        let completedAt = Date(timeIntervalSince1970: 10)
        let startedAt = Date(timeIntervalSince1970: 6)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            clock: .init(now: { completedAt }),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let review = Task { @MainActor in
                try await store.startReview(
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                )
            }
            try #require(await StoreSnapshotProbe(store: store).waitUntilRunAttempt(
                "attempt-1",
                jobID: "job-1"
            ) != nil)
            let running = try #require(store.job(id: "job-1"))
            running.appendLogEntry(.init(
                kind: .command,
                groupID: "cmd-1",
                replacesGroup: true,
                text: "$ git diff",
                metadata: .init(
                    sourceType: "commandExecution",
                    status: "inProgress",
                    itemID: "cmd-1",
                    command: "git diff",
                    startedAt: startedAt,
                    commandStatus: "inProgress"
                ),
                timestamp: startedAt
            ))

            async let cancellation = store.cancelReview(
                jobID: "job-1",
                cancellation: .mcpClient(message: "Stop")
            )
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            await backend.yield(.cancelled("Stop"))
            let cancel = try await cancellation
            _ = try await review.value
            let read = try store.readReview(jobID: "job-1", logFilter: .all)
            let commandLogs = try #require(store.job(id: "job-1"))
                .logEntries
                .filter { $0.kind == .command && $0.groupID == "cmd-1" }
            let closed = try #require(commandLogs.last)

            #expect(cancel.cancelled)
            #expect(read.core.lifecycle.status == .cancelled)
            #expect(commandLogs.count == 2)
            #expect(closed.replacesGroup)
            #expect(closed.metadata?.status == "canceled")
            #expect(closed.metadata?.commandStatus == "canceled")
            #expect(closed.metadata?.command == "git diff")
            #expect(closed.metadata?.startedAt == startedAt)
            #expect(closed.metadata?.completedAt == completedAt)
            #expect(closed.metadata?.durationMs == 4_000)
            #expect(await backend.recordedCommands().contains {
                isTypedInterruptCommand($0, run: .init(
                    threadID: "thread-1",
                    turnID: "turn-1",
                    reviewThreadID: "review-thread-1"
                ), message: "Stop")
            })
        }
    }

    @Test func sessionScopedCancelRejectsJobFromDifferentSession() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            await #expect(throws: (any Error).self) {
                try await store.cancelReview(
                    jobID: "job-1",
                    sessionID: "session-2",
                    cancellation: .mcpClient(message: "Stop")
                )
            }
            #expect(try store.readReview(jobID: "job-1").cancellable)

            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            _ = try await result

            let commands = await backend.recordedCommands()
            #expect(commands.contains {
                if case .interruptReview = $0 {
                    return true
                }
                return false
            } == false)
        }
    }

    @Test func nonterminalCancellationWithoutAttemptOwnerFailsFast() async throws {
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        )
        let job = CodexReviewJob.makeForTesting(
            id: "job-ownerless",
            cwd: "/tmp/project",
            targetSummary: "Ownerless",
            status: .running,
            summary: "Running"
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [.init(cwd: "/tmp/project")],
            jobs: [job]
        )

        await #expect(throws: ReviewAttemptContractFailure.self) {
            try await store.cancelReview(jobID: job.id, cancellation: .mcpClient(message: "Stop"))
        }
        #expect(job.core.lifecycle.status == .running)
        #expect(job.core.lifecycle.cancellation == nil)
        #expect(job.cancellationRequested == false)
    }

    @Test func cancelledReviewStaysCancelledWhenStreamClosesWithError() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilRunAttempt("attempt-1", jobID: "job-1") != nil)
            async let cancellation = store.cancelReview(
                jobID: "job-1",
                cancellation: .mcpClient(message: "Stop")
            )
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            await backend.finishEvents(throwing: StreamClosedError())
            _ = try await cancellation
            let read = try await result

            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.output.summary == "Stop")
        }
    }

    @Test func failedReviewPreservesBufferedEventsBeforeStreamError() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilJobStatus(.running, jobID: "job-1") != nil)
            await backend.yield(.message("partial review"))
            await backend.finishEvents(throwing: StreamClosedError())
            let read = try await result

            #expect(read.core.lifecycle.status == .failed)
            #expect(read.core.output.lastAgentMessage == "partial review")
            #expect(read.logs.map(\.text).contains("partial review"))
        }
    }

    @Test func pendingNetworkOutageDefersStreamFailureUntilRecovery() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let outageSleepStarted = AsyncGate()
        let debounceGate = AsyncGate()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(
                outageDebounce: .seconds(10),
                recoverySettle: .seconds(1),
                sleep: { _ in
                    await outageSleepStarted.open()
                    await debounceGate.wait()
                }
            )
        )
        try await scriptRecoveryRoute(in: store)
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilJobStatus(.running, jobID: "job-1") != nil)

            networkMonitor.yield(.init(status: .unsatisfied))
            await outageSleepStarted.wait()
            await backend.finishEvents(
                throwing: ReviewAttemptStreamFailure.recoverableNetwork(.connection("Network closed")),
                for: initialRun
            )

            let failedBeforeOutageConfirmed = await StoreSnapshotProbe(store: store)
                .waitUntilJobStatus(.failed, jobID: "job-1", timeout: .milliseconds(100)) != nil
            #expect(failedBeforeOutageConfirmed == false)

            await debounceGate.open()
            try await backend.waitForPrepareReviewRecovery(timeout: .seconds(2))
            networkMonitor.yield(.satisfied())
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))

            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.output.lastAgentMessage == "recovered review")
        }
    }

    @Test func recoveryProductTerminalClearsStalePendingCancellation() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        let interruptGate = AsyncGate()
        await backend.holdInterruptReview(with: interruptGate)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilRunAttempt(
                initialRun.attemptID,
                jobID: "job-1"
            ) != nil)

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            guard case .recovering(let receipt) = store.reviewAttemptOwnerships["job-1"] else {
                Issue.record("Review did not publish its exact recovery receipt.")
                return
            }
            let job = try #require(store.job(id: "job-1"))
            store.recordCancellationRequest(.mcpClient(message: "Stop"), for: job)
            await backend.finishEvents(
                throwing: ReviewAttemptStreamFailure.process(.process("Process exited.")),
                for: initialRun
            )
            try #require(await waitUntil {
                if case .finishingRecovery = await receipt.source.admission.currentPhase() {
                    true
                } else {
                    false
                }
            })
            await interruptGate.open()
            let read = try await result

            #expect(read.core.lifecycle.status == .failed)
            #expect(read.core.lifecycle.terminal == .interrupted(.previousProcessExit))
            #expect(read.core.lifecycle.cancellation == nil)
            #expect(job.cancellationRequested == false)
        }
    }

    @Test func reviewStreamCancellationCleansBackendRunWithoutInterruptingAgain() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilJobStatus(.running, jobID: "job-1") != nil)
            await backend.finishEvents(throwing: CancellationError())
            let read = try await result

            #expect(read.core.lifecycle.status == .cancelled)
            let commands = await backend.recordedCommands()
            #expect(commands.contains { if case .cleanupReview = $0 { true } else { false } })
            #expect(commands.contains { if case .interruptReviewAdmission = $0 { true } else { false } } == false)
        }
    }

    @Test func reviewStartTaskCancellationInterruptsBackendRun() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let task = Task { @MainActor in
                try await store.startReview(
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
                )
            }
            try await backend.waitForStartReview(timeout: .seconds(2))
            task.cancel()
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            await backend.yield(.cancelled("Cancellation requested."))
            let read = try await task.value

            #expect(read.core.lifecycle.status == .cancelled)
            let commands = await backend.recordedCommands()
            #expect(commands.contains { isTypedInterruptCommand($0, run: .init(threadID: "thread-1", turnID: "turn-1", reviewThreadID: "review-thread-1"), message: "Cancellation requested.") })
        }
    }

    @Test func reviewStartTaskCancellationPreservesActiveInterruptRejection() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let backend = FakeCodexReviewBackend(nextRun: run)
        await backend.rejectInterrupts(message: "Interrupt failed")
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let review = Task { @MainActor in
                try await store.startReview(
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                )
            }
            try #require(await StoreSnapshotProbe(store: store).waitUntilRunAttempt(
                run.attemptID,
                jobID: "job-1"
            ) != nil)

            review.cancel()
            await #expect(throws: ReviewInterruptRequestFailure.self) {
                try await review.value
            }
            let running = try store.readReview(jobID: "job-1")

            #expect(running.core.lifecycle.status == .running)
            #expect(running.core.lifecycle.cancellation == nil)
            #expect(running.core.output.summary == "Failed to cancel review: Interrupt failed")
            #expect(running.cancellable)
            #expect(store.reviewAttemptOwnerships["job-1"]?.run == run)
            #expect(store.reviewWorkerTasks["job-1"] != nil)

            await backend.yield(
                .completed(summary: "Succeeded.", result: "natural review"),
                for: run
            )
            let final = try await store.awaitReview(
                sessionID: "session-1",
                jobID: "job-1",
                timeout: .seconds(1)
            )
            #expect(final.core.lifecycle.status == .succeeded)
        }
    }

    @Test func reviewStartTaskCancellationCancelsHeldTypedRecoveryStage() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1"
        )
        let reviewBackend = FakeCodexReviewBackend(nextRun: initialRun)
        await reviewBackend.setNextRecoveredRun(recoveredRun)
        let storeBackend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let stageGate = AsyncGate()
        storeBackend.holdReviewRecoveryStage(with: stageGate)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: storeBackend,
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: reviewBackend, store: store) {
            let review = Task { @MainActor in
                try await store.startReview(
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                )
            }
            networkMonitor.yield(.init(status: .unsatisfied))
            try await resolveTypedRecoveryDisposition(backend: reviewBackend, store: store)
            networkMonitor.yield(.satisfied())
            await storeBackend.waitForReviewRecoveryStage()
            let stageAdmission = try #require(storeBackend.reviewRecoveryCommands.compactMap { command in
                if case .stage(_, _, let admission) = command { admission } else { nil }
            }.last)

            review.cancel()
            let cancellationWasPublished = await waitUntil {
                store.job(id: "job-1")?.cancellationRequested == true
            }
            let cancellationReachedReceipt = await waitUntil {
                await stageAdmission.cancellationRequest() == .system()
            }
            await stageGate.open()
            #expect(cancellationWasPublished)
            #expect(cancellationReachedReceipt)
            let result = try await review.value

            #expect(result.core.lifecycle.status == .cancelled)
            #expect(result.core.lifecycle.cancellation == .system())
            #expect(storeBackend.reviewRecoveryCommands.contains {
                if case .commit = $0 { true } else { false }
            } == false)
            #expect(store.reviewAttemptOwnerships["job-1"] == nil)
            #expect(store.reviewWorkerTasks["job-1"] == nil)
        }
    }

    @Test func failedInterruptClearsCancellationRequestState() async throws {
        let backend = FakeCodexReviewBackend()
        await backend.rejectInterrupts(message: "Interrupt failed")
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilRunAttempt("attempt-1", jobID: "job-1") != nil)
            await #expect(throws: ReviewInterruptRequestFailure.self) {
                try await store.cancelReview(
                    jobID: "job-1",
                    cancellation: .mcpClient(message: "Stop")
                )
            }
            let readAfterFailure = try store.readReview(jobID: "job-1")

            #expect(readAfterFailure.cancellable)
            #expect(readAfterFailure.core.lifecycle.cancellation == nil)
            #expect(readAfterFailure.core.output.summary == "Failed to cancel review: Interrupt failed")

            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            _ = try await result
        }
    }

    @Test func canonicalCompletionWinsPendingCancellationAndClearsRequestState() async throws {
        let backend = FakeCodexReviewBackend()
        let interruptGate = AsyncGate()
        await backend.holdInterruptReview(with: interruptGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilRunAttempt(
                "attempt-1",
                jobID: "job-1"
            ) != nil)
            async let cancel = store.cancelReview(jobID: "job-1", cancellation: .mcpClient(message: "Stop"))
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            await backend.yield(.completed(summary: "Succeeded.", result: "natural review"))
            try #require(await StoreSnapshotProbe(store: store).waitUntilJobStatus(
                .succeeded,
                jobID: "job-1"
            ) != nil)
            await interruptGate.open()
            let cancellation = try await cancel
            let read = try await result

            #expect(cancellation.cancelled == false)
            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.lifecycle.terminal == .completed)
            #expect(read.core.lifecycle.cancellation == nil)
            #expect(read.core.lifecycle.errorMessage == nil)
            #expect(read.core.output.lastAgentMessage == "natural review")
            #expect(try #require(store.job(id: "job-1")).cancellationRequested == false)
        }
    }

    @Test func canonicalFailureWinsPendingCancellationAndClearsRequestState() async throws {
        let backend = FakeCodexReviewBackend()
        let interruptGate = AsyncGate()
        await backend.holdInterruptReview(with: interruptGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilRunAttempt(
                "attempt-1",
                jobID: "job-1"
            ) != nil)
            async let cancel = store.cancelReview(jobID: "job-1", cancellation: .mcpClient(message: "Stop"))
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            await backend.yield(.failed("Canonical failure"))
            try #require(await StoreSnapshotProbe(store: store).waitUntilJobStatus(
                .failed,
                jobID: "job-1"
            ) != nil)
            await interruptGate.open()
            let cancellation = try await cancel
            let read = try await result

            #expect(cancellation.cancelled == false)
            #expect(read.core.lifecycle.status == .failed)
            #expect(read.core.lifecycle.terminal == .failed(message: "Canonical failure"))
            #expect(read.core.lifecycle.cancellation == nil)
            #expect(read.core.lifecycle.errorMessage == "Canonical failure")
            #expect(read.core.output.summary == "Canonical failure")
            #expect(try #require(store.job(id: "job-1")).cancellationRequested == false)
        }
    }

    @Test func canonicalServerInterruptionProjectsOnce() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.cancelled("Server stopped"))
            await backend.yield(.completed(summary: "Late success", result: "late review"))
            let read = try await result

            #expect(read.core.lifecycle.status == .failed)
            #expect(read.core.lifecycle.terminal == .interrupted(.server(message: "Server stopped")))
            #expect(read.core.lifecycle.cancellation == nil)
            #expect(read.core.lifecycle.errorMessage == "Server stopped")
            #expect(read.core.output.lastAgentMessage == nil)
        }
    }

    @Test func terminalFromWrongCurrentRunCannotFinishReview() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-1",
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let backend = FakeCodexReviewBackend(nextRun: run)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let reviewTask = Task { @MainActor in
                try await store.startReview(
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                )
            }
            try #require(await StoreSnapshotProbe(store: store).waitUntilRunAttempt(
                run.attemptID,
                jobID: "job-1"
            ) != nil)
            let job = try #require(store.job(id: "job-1"))
            var wrongRun = run
            wrongRun.turnID = "wrong-turn"

            _ = store.handleReviewEvent(
                .completed(summary: "Wrong", result: "wrong review"),
                job: job,
                sourceRun: wrongRun,
                currentRun: run
            )
            #expect(job.core.lifecycle.status == .running)
            #expect(job.core.lifecycle.terminal == nil)

            await backend.yield(.completed(summary: "Succeeded.", result: "canonical review"), for: run)
            let read = try await reviewTask.value
            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.output.lastAgentMessage == "canonical review")
        }
    }

    @Test func cancelDuringReviewStartupInterruptsAfterRunBecomesAvailable() async throws {
        let backend = FakeCodexReviewBackend()
        let startGate = AsyncGate()
        let interruptGate = AsyncGate()
        await backend.holdStartReview(with: startGate)
        await backend.holdInterruptReview(with: interruptGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            try await backend.waitForStartReview(timeout: .seconds(2))
            let admission = try #require(startingAdmission(in: store, jobID: "job-1"))
            #expect(await backend.receivedStartAdmission(admission))

            let cancel = try await store.cancelReview(jobID: "job-1", cancellation: .mcpClient(message: "Stop"))
            let laterCancel = try await store.cancelReview(
                jobID: "job-1",
                cancellation: .system(message: "Later cancellation")
            )
            let cancelledDuringStartup = try #require(store.jobs.first)
            #expect(cancel.core.lifecycle.status == .cancelled)
            #expect(laterCancel.cancelled == false)
            #expect(cancelledDuringStartup.core.lifecycle.status == .cancelled)
            #expect(await admission.cancellationRequest() == .mcpClient(message: "Stop"))

            await startGate.open()
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            let activeRun = CodexReviewBackendModel.Review.Run(
                threadID: "thread-1",
                turnID: "turn-1",
                reviewThreadID: "review-thread-1"
            )
            #expect(startingAdmission(in: store, jobID: "job-1") == nil)
            #expect(store.reviewAttemptOwnerships["job-1"]?.run == activeRun)
            #expect(cancelledDuringStartup.core.run.threadID == activeRun.threadID)
            #expect(cancelledDuringStartup.core.run.turnID == activeRun.turnID)

            await interruptGate.open()
            await backend.yield(.cancelled("Stop"), for: activeRun)
            let read = try await result

            #expect(cancel.cancelled)
            #expect(read.core.lifecycle.status == .cancelled)
            let commands = await backend.recordedCommands()
            #expect(commands.contains { isTypedInterruptCommand($0, run: activeRun, message: "Stop") })
            #expect(commands.contains(.cleanupReview(activeRun)))
        }
    }

    @Test func lateInitialStartCannotPublishOverAnotherAdmissionForTheSameJobID() async throws {
        let backend = FakeCodexReviewBackend()
        let startGate = AsyncGate()
        await backend.holdStartReviewIgnoringCancellation(with: startGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let result = Task { @MainActor in
                try await store.startReview(
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                )
            }
            try await backend.waitForStartReview(timeout: .seconds(2))
            let original = try #require(startingAdmission(in: store, jobID: "job-1"))
            let replacement = ReviewStartAdmission()
            store.reviewAttemptOwnerships["job-1"] = .starting(replacement)

            await startGate.open()
            let read = try await result.value

            #expect(read.core.lifecycle.status == .failed)
            #expect(read.core.lifecycle.errorMessage ==
                "Initial review start completed after its Store ownership changed.")
            #expect(startingAdmission(in: store, jobID: "job-1") === replacement)
            #expect(startingAdmission(in: store, jobID: "job-1") !== original)
            #expect(await backend.recordedCommands().contains(.cleanupReview(.init(
                threadID: "thread-1",
                turnID: "turn-1",
                reviewThreadID: "review-thread-1"
            ))))
        }
    }

    @Test func closedSessionRejectsNewReviews() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        await withStoreCommandTestCleanup(backend: backend, store: store) {
            await store.closeSession("session-1")

            await #expect(throws: (any Error).self) {
                try await store.startReview(
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                )
            }
        }
    }

    @Test func closeActiveReviewSessionsCancelsJobsWithoutClosingMCPServerSession() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let firstReview = Task { @MainActor in
                try await store.startReview(
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                )
            }
            try #require(await StoreSnapshotProbe(store: store).waitUntilRunAttempt("attempt-1") != nil)
            let firstJobID = try #require(store.jobs.first?.id)
            let close = Task { @MainActor in
                await store.closeActiveReviewSessions(reason: .system(message: "Account switched."))
            }
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            await backend.yield(.cancelled("Account switched."))
            await close.value
            let first = try await firstReview.value

            #expect(first.core.lifecycle.status == .cancelled)
            #expect(store.reviewWorkerTasks[firstJobID] == nil)
            let secondRun = CodexReviewBackendModel.Review.Run(
                attemptID: "attempt-2",
                threadID: "thread-2",
                turnID: "turn-2",
                reviewThreadID: "review-thread-2"
            )
            await backend.setNextRun(secondRun)
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "review text"), for: secondRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
        }
    }

    @Test func authAndSettingsUseSingleBackendContract() async throws {
        let backend = FakeCodexReviewBackend(settings: .init(model: "gpt-5"))
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        await withStoreCommandTestCleanup(backend: backend, store: store) {
            await store.refreshSettings()

            #expect(store.settings.effectiveModel == "gpt-5")
        }
    }

    @Test func initialActiveAccountKeySelectsPersistedAccount() {
        let active = CodexAccount(email: "active@example.com")
        let inactive = CodexAccount(email: "inactive@example.com")
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(
                reviewBackend: backend,
                seed: .init(
                    initialAccounts: [inactive, active],
                    initialActiveAccountKey: active.accountKey
                )
            )
        )

        #expect(store.auth.persistedAccounts.map(\.accountKey) == [
            inactive.accountKey,
            active.accountKey,
        ])
        #expect(store.auth.persistedActiveAccountKey == active.accountKey)
        #expect(store.auth.selectedAccount?.accountKey == active.accountKey)
    }

    @Test func switchActionsAreUnavailableForSelectedAccount() async throws {
        let selectedAccount = CodexAccount(email: "selected@example.com", planType: "pro")
        let otherAccount = CodexAccount(email: "other@example.com", planType: "plus")
        let backend = SwitchRecordingBackend()
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        store.loadForTesting(
            serverState: .running,
            account: selectedAccount,
            persistedAccounts: [selectedAccount, otherAccount],
            workspaces: []
        )
        let displayedSelectedAccount = try #require(store.auth.selectedAccount)
        let displayedOtherAccount = try #require(
            store.auth.persistedAccounts.first { $0.accountKey == otherAccount.accountKey }
        )

        #expect(store.switchActionIsDisabled(for: displayedSelectedAccount))
        #expect(store.switchActionRequiresRunningJobsConfirmation(for: displayedSelectedAccount) == false)
        #expect(store.switchActionIsDisabled(for: displayedOtherAccount) == false)
        #expect(store.switchActionRequiresRunningJobsConfirmation(for: displayedOtherAccount))

        store.requestSwitchAccountFromUserAction(displayedSelectedAccount)
        await Task.yield()
        #expect(backend.switchRequests.isEmpty)

        try await store.switchAccount(displayedSelectedAccount)
        #expect(backend.switchRequests.isEmpty)

        try await store.switchAccount(displayedOtherAccount)
        #expect(backend.switchRequests == [displayedOtherAccount.accountKey])
    }

    @Test func registeredWorkCloseSkipsAccountActionCancelledBeforeEntry() async throws {
        let selectedAccount = CodexAccount(email: "selected@example.com", planType: "pro")
        let otherAccount = CodexAccount(email: "other@example.com", planType: "plus")
        let backend = SwitchRecordingBackend()
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        store.loadForTesting(
            serverState: .running,
            account: selectedAccount,
            persistedAccounts: [selectedAccount, otherAccount],
            workspaces: []
        )
        let displayedOtherAccount = try #require(
            store.auth.persistedAccounts.first { $0.accountKey == otherAccount.accountKey }
        )

        store.requestSwitchAccountFromUserAction(displayedOtherAccount)
        let closeOperation = store.storeWorkRegistry.beginClosing(onAdmissionClosed: {})
        let result = await closeOperation.task.value
        store.storeWorkRegistry.completeClosing(closeOperation, result: result)

        #expect(result == .success)
        #expect(backend.switchRequests.isEmpty)
        #expect(store.auth.selectedAccount?.accountKey == selectedAccount.accountKey)
    }

    @Test func fakeBackendPreservesSettingsCatalogWhenApplyingOverrides() async throws {
        let model = CodexReviewSettings.ModelCatalogItem(
            id: "gpt-5.5",
            model: "gpt-5.5",
            displayName: "GPT-5.5",
            hidden: false,
            supportedReasoningEfforts: [
                .init(reasoningEffort: .medium, description: "Balanced"),
            ],
            defaultReasoningEffort: .medium,
            supportedServiceTiers: [.fast],
            isDefault: true
        )
        let backend = FakeCodexReviewBackend(settings: .init(
            fallbackModel: "gpt-5.5",
            models: [model]
        ))
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        await withStoreCommandTestCleanup(backend: backend, store: store) {
            await store.refreshSettings()
            await store.updateSettingsReasoningEffort(.medium)

            #expect(store.settings.effectiveModel == "gpt-5.5")
            #expect(store.settings.models == [model])
        }
    }

    @Test func primaryAuthenticationActionIsAvailableWhenRuntimeCanRecoverOrStartLogin() {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        store.loadForTesting(serverState: .stopped, authPhase: .signedOut, workspaces: [])
        #expect(store.canPerformPrimaryAuthenticationAction)

        store.loadForTesting(serverState: .failed("Runtime failed."), authPhase: .signedOut, workspaces: [])
        #expect(store.canPerformPrimaryAuthenticationAction)

        store.loadForTesting(serverState: .starting, authPhase: .signedOut, workspaces: [])
        #expect(store.canPerformPrimaryAuthenticationAction == false)

        store.loadForTesting(serverState: .running, authPhase: .signedOut, workspaces: [])
        #expect(store.canPerformPrimaryAuthenticationAction)

        store.auth.updatePhase(.signingIn(.init(title: "Sign in", detail: "Open browser.")))
        store.transitionToFailed("Runtime failed.")
        #expect(store.canPerformPrimaryAuthenticationAction)
    }

    @Test func primaryAuthenticationActionRestartsRecoverableRuntimeBeforeLogin() async {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        await withStoreCommandTestCleanup(backend: backend, store: store) {
            store.loadForTesting(serverState: .failed("Runtime failed."), authPhase: .signedOut, workspaces: [])

            await store.performPrimaryAuthenticationAction()

            #expect(store.serverState == .running)
            #expect(store.auth.isAuthenticating)
            let commands = await backend.recordedCommands()
            #expect(commands.contains { command in
                if case .startLogin = command {
                    return true
                }
                return false
            })
        }
    }
}

@MainActor
private final class SwitchRecordingBackend: PreviewCodexReviewStoreBackend {
    private(set) var switchRequests: [String] = []

    override func switchAccount(
        auth _: CodexReviewAuthModel,
        accountKey: String
    ) async throws {
        switchRequests.append(accountKey)
    }

    override func requiresCurrentSessionRecovery(
        auth _: CodexReviewAuthModel,
        accountKey _: String
    ) -> Bool {
        true
    }
}

@MainActor
private final class OutcomeUnknownStartStoreBackend: PreviewCodexReviewStoreBackend {
    private let provisionalRun: CodexReviewBackendModel.Review.Run
    private(set) var cleanedRuns: [CodexReviewBackendModel.Review.Run] = []

    init(provisionalRun: CodexReviewBackendModel.Review.Run) {
        self.provisionalRun = provisionalRun
        super.init()
    }

    override func startReview(
        _: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> BackendReviewAttempt {
        try await admission.admitThreadStartDispatch()
        try await admission.recordPreparedThread(provisionalRun)
        try await admission.admitReviewStartDispatch(for: provisionalRun)
        throw CancellationError()
    }

    override func cleanupReview(
        _ run: CodexReviewBackendModel.Review.Run
    ) async {
        cleanedRuns.append(run)
    }
}

@MainActor
private final class MismatchedReturnedAttemptStoreBackend: PreviewCodexReviewStoreBackend {
    private let returnedRun: CodexReviewBackendModel.Review.Run
    private let admittedRun: CodexReviewBackendModel.Review.Run
    private(set) var cleanedRuns: [CodexReviewBackendModel.Review.Run] = []

    init(
        returnedRun: CodexReviewBackendModel.Review.Run,
        admittedRun: CodexReviewBackendModel.Review.Run
    ) {
        self.returnedRun = returnedRun
        self.admittedRun = admittedRun
        super.init()
    }

    override func startReview(
        _: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> BackendReviewAttempt {
        try await admission.admitThreadStartDispatch()
        let preparedRun = CodexReviewBackendModel.Review.Run(
            attemptID: admittedRun.attemptID,
            threadID: admittedRun.threadID,
            reviewThreadID: admittedRun.threadID,
            model: admittedRun.model
        )
        try await admission.recordPreparedThread(preparedRun)
        try await admission.admitReviewStartDispatch(for: preparedRun)
        try await admission.recordActiveRun(admittedRun)
        return .init(run: returnedRun)
    }

    override func cleanupReview(_ run: CodexReviewBackendModel.Review.Run) async {
        cleanedRuns.append(run)
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while await condition() == false {
        if clock.now >= deadline {
            return false
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

@MainActor
private func waitForRunAttemptActivation(
    store: CodexReviewStore,
    run: CodexReviewBackendModel.Review.Run,
    timeout: Duration = .seconds(2)
) async -> Bool {
    await StoreSnapshotProbe(store: store)
        .waitUntilRunAttempt(run.attemptID, timeout: timeout) != nil
}

private func waitForTaskValue<T: Sendable>(
    _ task: Task<T, any Error>,
    timeout: Duration
) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask {
            try await task.value
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        let result = try await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

private actor StoreCommandTaskCompletion {
    private var completed = false

    func complete() {
        completed = true
    }

    func isComplete() -> Bool {
        completed
    }
}

private actor StoreCommandSleepProbe {
    private var sleepCount = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var count: Int {
        sleepCount
    }

    func sleepIgnoringCancellation(on gate: AsyncGate) async {
        sleepCount += 1
        let ready = waiters.filter { sleepCount >= $0.0 }
        waiters.removeAll { sleepCount >= $0.0 }
        for (_, waiter) in ready {
            waiter.resume()
        }
        await gate.waitIgnoringCancellation()
    }

    func waitForCount(_ count: Int) async {
        if sleepCount >= count {
            return
        }
        await withCheckedContinuation { continuation in
            if sleepCount >= count {
                continuation.resume()
            } else {
                waiters.append((count, continuation))
            }
        }
    }
}

@MainActor
private func startingAdmission(
    in store: CodexReviewStore,
    jobID: String
) -> ReviewStartAdmission? {
    guard case .starting(let admission) = store.reviewAttemptOwnerships[jobID] else { return nil }
    return admission
}

private func isTypedInterruptCommand(_ command: FakeCodexReviewBackend.Command, run: CodexReviewBackendModel.Review.Run, message: String) -> Bool {
    if case .interruptReviewAdmission(let admission, let reason) = command { admission.run == run && reason.message == message } else { false }
}

@MainActor
private func scriptRecoveryRoute(in store: CodexReviewStore) async throws {
    await store.start()
    let backend = try #require(store.backend as? TestingCodexReviewStoreBackend)
    let generation = ReviewRuntimeGeneration(rawValue: store.runtimeLifecycleAdmissionGeneration)
    try backend.scriptReviewRecoveryRoute(
        sourceGeneration: generation, destinationGeneration: generation
    )
}

@MainActor
private func resolveTypedRecoveryDisposition(
    backend: FakeCodexReviewBackend,
    store: CodexReviewStore
) async throws {
    try await scriptRecoveryRoute(in: store)
    try await backend.waitForInterruptReview(timeout: .seconds(2))
    guard case .recovering(let receipt) = store.reviewAttemptOwnerships["job-1"] else {
        Issue.record("Store did not publish the recovery receipt."); return
    }
    await backend.yield(.cancelled("Network recovery"), for: receipt.source.run)
    try await backend.waitForPrepareReviewRecovery(timeout: .seconds(2))
}

@MainActor
private func withStoreCommandTestCleanup(
    backend: FakeCodexReviewBackend,
    store: CodexReviewStore,
    operation: () async throws -> Void
) async rethrows {
    do {
        try await operation()
    } catch {
        await cleanupStoreCommandTest(backend: backend, store: store)
        throw error
    }
    await cleanupStoreCommandTest(backend: backend, store: store)
}

@MainActor
private func cleanupStoreCommandTest(
    backend: FakeCodexReviewBackend,
    store: CodexReviewStore
) async {
    await backend.finishEventMailboxes()
    await store.cancelAndDrainReviewWorkersForTesting()
    await backend.finishEventMailboxes()
}

private struct StreamClosedError: Error {}

private actor ControlledTestSleeper {
    private let gate: AsyncGate
    private var shouldBlock = false

    init(gate: AsyncGate) {
        self.gate = gate
    }

    func blockFutureSleeps() {
        shouldBlock = true
    }

    func sleep() async {
        if shouldBlock {
            await gate.wait()
        }
    }
}

private final class MutableTestClock: @unchecked Sendable {
    var current: Date

    init(_ current: Date) {
        self.current = current
    }

    func now() -> Date {
        current
    }
}
