import Foundation
import Testing
@_spi(Testing) @testable import CodexReview
import CodexReviewTesting

@Suite("Codex review store", .serialized)
@MainActor
struct CodexReviewStoreCommandTests {
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
            try await backend.waitForEventStream(timeout: .seconds(2))
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
            try await backend.waitForEventStream(timeout: .seconds(2))
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
            try await backend.waitForEventStream(timeout: .seconds(2))
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
            try await backend.waitForEventStream(timeout: .seconds(2))
            _ = try await start

            async let awaited = store.awaitReview(
                sessionID: "session-1",
                jobID: "job-1",
                timeout: .seconds(1)
            )
            _ = try await store.cancelReview(
                jobID: "job-1",
                cancellation: .mcpClient(message: "Stop")
            )
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
            try await backend.waitForEventStream(timeout: .seconds(2))
            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            _ = try await result

            let commands = await backend.recordedCommands()
            let starts = commands.compactMap { command -> BackendReviewStart? in
                if case .startReview(let request) = command {
                    return request
                }
                return nil
            }
            #expect(starts.first?.model == "gpt-5.5")
        }
    }

    @Test func reviewStartAppliesStartedTurnAndMergesAgentMessageDeltas() async throws {
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
            try await backend.waitForEventStream(timeout: .seconds(2))
            await backend.yield(.started(turnID: "turn-actual", reviewThreadID: "review-thread-1", model: "gpt-5.5"))
            await backend.yield(.messageDelta("hello", itemID: "message-1"))
            await backend.yield(.messageDelta(" world", itemID: "message-1"))
            await backend.yield(.logEntry(
                kind: .reasoningSummary,
                text: " with space",
                groupID: "reasoning-1",
                replacesGroup: false
            ))
            await backend.yield(.completed(summary: "Succeeded.", result: nil))
            let read = try await result

            #expect(read.core.run.turnID == "turn-actual")
            #expect(read.core.output.lastAgentMessage == "hello world")
            #expect(read.rawLogText.isEmpty)
            #expect(try store.readReview(jobID: "job-1").logs.map(\.text) == [
                "hello world",
                " with space",
            ])
            #expect(try #require(store.job(id: "job-1")).reviewOutputText == "hello world\n\n with space")
            #expect(try store.readReview(jobID: "job-1").core.run.model == "gpt-5.5")
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
            try await backend.waitForEventStream(timeout: .seconds(2))
            await backend.yield(.messageDelta("first", itemID: "message-1"))
            await backend.yield(.messageDelta("second", itemID: "message-2"))
            await backend.yield(.completed(summary: "Succeeded.", result: nil))
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
            try await backend.waitForEventStream(timeout: .seconds(2))
            await backend.yield(.logEntry(
                kind: .agentMessage,
                text: "final review text",
                groupID: "review-item-1",
                replacesGroup: true
            ))
            await backend.yield(.completed(summary: "Succeeded.", result: "final review text"))
            let read = try await result

            #expect(read.core.output.lastAgentMessage == "final review text")
            #expect(read.core.reviewText == "final review text")
            #expect(try store.readReview(jobID: "job-1").logs.map(\.text) == ["final review text"])
        }
    }

    @Test func reviewCompletionEnforcesLogLimitWithoutFinalAppend() async throws {
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
            try await backend.waitForEventStream(timeout: .seconds(2))
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
            await backend.yield(.completed(summary: "Succeeded.", result: nil))
            let read = try await result
            let job = try #require(store.job(id: "job-1"))

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(job.cappedLogBytes <= 256 * 1024)
            #expect(job.logText.hasSuffix(delta))
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
        #expect(read.logsPage == ReviewLogPage(
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
        #expect(read.logsPage == ReviewLogPage(
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
            try store.readReview(jobID: "job-1", logPage: .init(limit: ReviewLogPageRequest.maxLimit + 1))
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
            try await backend.waitForEventStream(timeout: .seconds(2))
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
            try await backend.waitForEventStream(timeout: .seconds(2))
            await backend.yield(.completed(summary: "Succeeded.", result: "first"))
            _ = try await first
            await backend.finishEvents()

            async let second = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/new-project", target: .uncommittedChanges)
            )
            try await backend.waitForEventStream(timeout: .seconds(2))
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
            try await backend.waitForEventStream(timeout: .seconds(2))
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
            try await backend.waitForEventStream(timeout: .seconds(2))
            await backend.yield(.completed(summary: "Succeeded.", result: "first"))
            _ = try await first
            await backend.finishEvents()

            async let second = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            try await backend.waitForEventStream(timeout: .seconds(2))
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
            try await backend.waitForEventStream(timeout: .seconds(2))
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
            try await backend.waitForEventStream(timeout: .seconds(2))
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
            try await backend.waitForEventStream(timeout: .seconds(2))
            let cancel = try await store.cancelReview(
                jobID: "job-1",
                cancellation: .mcpClient(message: "Stop")
            )
            await backend.yield(.cancelled("Stop"))
            _ = try await result

            #expect(cancel.cancelled)
            #expect(try store.readReview(jobID: "job-1").core.lifecycle.status == .cancelled)
            let commands = await backend.recordedCommands()
            #expect(commands.contains(.interruptReview(
                .init(threadID: "thread-1", turnID: "turn-1", reviewThreadID: "review-thread-1"),
                .init(message: "Stop")
            )))
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
            try await backend.waitForEventStream(timeout: .seconds(2))
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
            _ = try await store.cancelReview(
                jobID: "job-1",
                cancellation: .mcpClient(message: "Stop")
            )
            await backend.yield(.cancelled("Stop"))
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
            try await backend.waitForEventStream(timeout: .seconds(2))

            networkMonitor.yield(.init(status: .unsatisfied))
            networkMonitor.yield(.satisfied())
            await debounceGate.open()
            await Task.yield()

            let commands = await backend.recordedCommands()
            #expect(commands.contains { command in
                if case .interruptReviewForRecovery = command {
                    true
                } else {
                    false
                }
            } == false)

            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            let read = try await result
            #expect(read.core.lifecycle.status == .succeeded)
        }
    }

    @Test func sustainedNetworkOutageInterruptsForRecoveryWithoutTerminalJob() async throws {
        let backend = FakeCodexReviewBackend()
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
            try await backend.waitForEventStream(timeout: .seconds(2))

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForInterruptReviewForRecovery(timeout: .seconds(2))

            let running = try store.readReview(jobID: "job-1")
            #expect(running.core.lifecycle.status == .running)
            #expect(running.core.output.summary == "Network unavailable; waiting to reconnect.")
            _ = try await store.cancelReview(jobID: "job-1", cancellation: .mcpClient(message: "Stop"))
            await backend.yield(.cancelled("Stop"))
            _ = try await result
        }
    }

    @Test func networkRecoveryUsesActualStartedTurn() async throws {
        let initialRun = BackendReviewRun(
            threadID: "thread-1",
            turnID: "turn-response",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = BackendReviewRun(
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
            try await backend.waitForEventStream(timeout: .seconds(2))

            await backend.yield(.started(
                turnID: "turn-actual",
                reviewThreadID: "review-thread-1",
                model: "gpt-5"
            ), for: initialRun)
            #expect(await waitUntil {
                store.job(id: "job-1")?.core.run.turnID == "turn-actual"
            })

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForInterruptReviewForRecovery(timeout: .seconds(2))
            let commandsAfterInterrupt = await backend.recordedCommands()
            let interruptedRuns = commandsAfterInterrupt.compactMap { command -> BackendReviewRun? in
                if case .interruptReviewForRecovery(let run, _) = command {
                    return run
                }
                return nil
            }
            #expect(interruptedRuns.last?.turnID == "turn-actual")

            networkMonitor.yield(.satisfied())
            try await backend.waitForRecoverReview(timeout: .seconds(2))
            let commandsAfterRecovery = await backend.recordedCommands()
            let recoveredFromRuns = commandsAfterRecovery.compactMap { command -> BackendReviewRun? in
                if case .recoverReview(let run, _, _) = command {
                    return run
                }
                return nil
            }
            #expect(recoveredFromRuns.last?.turnID == "turn-actual")

            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-recovered")
        }
    }

    @Test func networkRecoveryRestartsReviewOnSameJobAndSucceeds() async throws {
        let initialRun = BackendReviewRun(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = BackendReviewRun(
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
            try await backend.waitForEventStream(timeout: .seconds(2))

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForInterruptReviewForRecovery(timeout: .seconds(2))
            await backend.yield(.message("stale aborted output"), for: initialRun)
            await backend.yield(.cancelled("Network lost"), for: initialRun)
            networkMonitor.yield(.satisfied())
            try await backend.waitForRecoverReview(timeout: .seconds(2))
            #expect(await waitUntil {
                guard let read = try? store.readReview(jobID: "job-1") else {
                    return false
                }
                return read.core.run.turnID == "turn-2"
            })

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

    @Test func networkRecoveryPreservesEventsEmittedWhileRestarting() async throws {
        let initialRun = BackendReviewRun(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = BackendReviewRun(
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let recoverGate = AsyncGate()
        await backend.holdRecoverReview(with: recoverGate)
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
            try await backend.waitForEventStream(timeout: .seconds(2))

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForInterruptReviewForRecovery(timeout: .seconds(2))
            networkMonitor.yield(.satisfied())
            try await backend.waitForRecoverReview(timeout: .seconds(2))
            await backend.yield(.completed(summary: "Succeeded.", result: "queued recovered review"), for: recoveredRun)
            await recoverGate.open()

            let read = try await result
            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-2")
            #expect(read.core.output.lastAgentMessage == "queued recovered review")
        }
    }

    @Test func cancellationWhileRecoveryRestartIsInFlightStopsRecoveredRun() async throws {
        let initialRun = BackendReviewRun(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = BackendReviewRun(
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let recoverGate = AsyncGate()
        await backend.holdRecoverReview(with: recoverGate)
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
            try await backend.waitForEventStream(timeout: .seconds(2))

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForInterruptReviewForRecovery(timeout: .seconds(2))
            networkMonitor.yield(.satisfied())
            try await backend.waitForRecoverReview(timeout: .seconds(2))

            let cancel = try await store.cancelReview(jobID: "job-1", cancellation: .mcpClient(message: "Stop"))
            #expect(cancel.cancelled)
            await recoverGate.open()

            let read = try await result
            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.run.turnID == "turn-1")

            let commands = await backend.recordedCommands()
            #expect(commands.contains(.interruptReview(
                initialRun,
                .init(message: "Stop")
            )))
            #expect(commands.contains(.interruptReview(
                recoveredRun,
                .init(message: "Stop")
            )))
            #expect(commands.contains(.cleanupReview(recoveredRun)))
        }
    }

    @Test func cancellationDuringNetworkRecoveryStopsWhenEventStreamFinishes() async throws {
        let initialRun = BackendReviewRun(
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
            try await backend.waitForEventStream(timeout: .seconds(2))

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForInterruptReviewForRecovery(timeout: .seconds(2))
            _ = try await store.cancelReview(jobID: "job-1", cancellation: .mcpClient(message: "Stop"))
            await backend.finishEvents(for: initialRun)

            let read = try await result
            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.lifecycle.cancellation?.message == "Stop")
        }
    }

    @Test func userCancellationWinsOverPendingNetworkRecovery() async throws {
        let backend = FakeCodexReviewBackend()
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let debounceGate = AsyncGate()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in await debounceGate.wait() })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try await backend.waitForEventStream(timeout: .seconds(2))

            networkMonitor.yield(.init(status: .unsatisfied))
            _ = try await store.cancelReview(jobID: "job-1", cancellation: .mcpClient(message: "Stop"))
            await debounceGate.open()
            await backend.yield(.cancelled("Stop"))
            let read = try await result

            #expect(read.core.lifecycle.status == .cancelled)
            let commands = await backend.recordedCommands()
            #expect(commands.contains { command in
                if case .interruptReviewForRecovery = command {
                    true
                } else {
                    false
                }
            } == false)
            #expect(commands.contains { command in
                if case .recoverReview = command {
                    true
                } else {
                    false
                }
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
            try await backend.waitForEventStream(timeout: .seconds(2))

            networkMonitor.yield(.init(status: .requiresConnection))
            try await backend.waitForInterruptReviewForRecovery(timeout: .seconds(2))
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
            clock: .init(now: { completedAt })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let running = CodexReviewJob.makeForTesting(
                id: "job-1",
                cwd: "/tmp/project",
                targetSummary: "Uncommitted changes",
                threadID: "thread-1",
                turnID: "turn-1",
                status: .running,
                startedAt: startedAt,
                summary: "Running",
                logEntries: [
                    .init(
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
                    )
                ]
            )
            store.loadForTesting(
                serverState: .running,
                workspaces: [.init(cwd: "/tmp/project")],
                jobs: [running]
            )

            let cancel = try await store.cancelReview(
                jobID: "job-1",
                cancellation: .mcpClient(message: "Stop")
            )
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
            try await backend.waitForEventStream(timeout: .seconds(2))

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
            try await backend.waitForEventStream(timeout: .seconds(2))
            _ = try await store.cancelReview(
                jobID: "job-1",
                cancellation: .mcpClient(message: "Stop")
            )
            await backend.finishEvents(throwing: StreamClosedError())
            let read = try await result

            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.output.summary == "Stop")
        }
    }

    @Test func reviewStartCancellationInterruptsBackendRun() async throws {
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
            try await backend.waitForEventStream(timeout: .seconds(2))
            await backend.finishEvents(throwing: CancellationError())
            let read = try await result

            #expect(read.core.lifecycle.status == .cancelled)
            let commands = await backend.recordedCommands()
            #expect(commands.contains(.interruptReview(
                .init(threadID: "thread-1", turnID: "turn-1", reviewThreadID: "review-thread-1"),
                .init(message: "Cancellation requested.")
            )))
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
            try await backend.waitForEventStream(timeout: .seconds(2))
            task.cancel()
            let read = try await task.value

            #expect(read.core.lifecycle.status == .cancelled)
            let commands = await backend.recordedCommands()
            #expect(commands.contains(.interruptReview(
                .init(threadID: "thread-1", turnID: "turn-1", reviewThreadID: "review-thread-1"),
                .init(message: "Cancellation requested.")
            )))
        }
    }

    @Test func failedInterruptClearsCancellationRequestState() async throws {
        let backend = FakeCodexReviewBackend()
        await backend.failInterrupts(message: "Interrupt failed")
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try await backend.waitForEventStream(timeout: .seconds(2))
            await #expect(throws: FakeCodexReviewBackendError.self) {
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

    @Test func cancelledReviewIgnoresBufferedTerminalEvents() async throws {
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
            try await backend.waitForEventStream(timeout: .seconds(2))
            _ = try await store.cancelReview(
                jobID: "job-1",
                cancellation: .mcpClient(message: "Stop")
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "late result"))
            let read = try await result

            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.output.summary == "Stop")
            #expect(read.core.output.lastAgentMessage == nil)
        }
    }

    @Test func terminalEventDuringPendingCancellationKeepsCancelledState() async throws {
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
            try await backend.waitForEventStream(timeout: .seconds(2))
            async let cancel = store.cancelReview(jobID: "job-1", cancellation: .mcpClient(message: "Stop"))
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            await backend.yield(.completed(summary: "Reviewer failed to output a response.", result: nil))
            await interruptGate.open()
            _ = try await cancel
            let read = try await result

            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.output.summary == "Stop")
            #expect(read.core.output.hasFinalReview == false)
        }
    }

    @Test func cancelDuringReviewStartupInterruptsAfterRunBecomesAvailable() async throws {
        let backend = FakeCodexReviewBackend()
        let gate = AsyncGate()
        await backend.holdStartReview(with: gate)
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
            let cancel = try await store.cancelReview(jobID: "job-1", cancellation: .mcpClient(message: "Stop"))
            let cancelledDuringStartup = try #require(store.jobs.first)
            #expect(cancel.core.lifecycle.status == .cancelled)
            #expect(cancelledDuringStartup.core.lifecycle.status == .cancelled)
            await gate.open()
            let read = try await result

            #expect(cancel.cancelled)
            #expect(read.core.lifecycle.status == .cancelled)
            let commands = await backend.recordedCommands()
            #expect(commands.contains(.interruptReview(
                .init(threadID: "thread-1", turnID: "turn-1", reviewThreadID: "review-thread-1"),
                .init(message: "Stop")
            )))
            #expect(commands.contains(.cleanupReview(.init(
                threadID: "thread-1",
                turnID: "turn-1",
                reviewThreadID: "review-thread-1"
            ))))
            #expect(commands.contains {
                if case .events = $0 {
                    return true
                }
                return false
            } == false)
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
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let running = CodexReviewJob.makeForTesting(
                id: "running-job",
                sessionID: "session-1",
                cwd: "/tmp/project",
                targetSummary: "Running",
                status: .running,
                summary: "Running"
            )
            store.loadForTesting(
                serverState: .running,
                workspaces: [.init(cwd: "/tmp/project")],
                jobs: [running]
            )

            await store.closeActiveReviewSessions(reason: .system(message: "Account switched."))

            #expect(running.core.lifecycle.status == .cancelled)
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            try await backend.waitForEventStream(timeout: .seconds(2))
            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            let read = try await result

            #expect(read.jobID == "job-1")
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

    @Test func fakeBackendPreservesSettingsCatalogWhenApplyingOverrides() async throws {
        let model = CodexReviewModelCatalogItem(
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
    await backend.finishAllEvents()
    await store.cancelAndDrainReviewWorkersForTesting()
}

private struct StreamClosedError: Error {}

private final class MutableTestClock: @unchecked Sendable {
    var current: Date

    init(_ current: Date) {
        self.current = current
    }

    func now() -> Date {
        current
    }
}
