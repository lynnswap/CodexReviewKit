import CodexAppServerKit
import CodexAppServerKitTesting
import CodexDataKit
import Foundation
import Testing

@MainActor
struct CodexChatObservationMulticastTests {
    @Test("observation updates multicast to multiple consumers")
    func observationUpdatesMulticastToMultipleConsumers() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(
            try observationStoredThread(id: "thread-multicast")
        )
        try await runtime.transport.enqueueThreadRead(
            try observationStoredThread(id: "thread-multicast")
        )

        let chat = context.model(for: CodexThreadID(rawValue: "thread-multicast"))
        let observation = try await chat.observe()
        let secondObservation = try await chat.observe()
        defer {
            observation.cancel()
            secondObservation.cancel()
        }
        let firstRecorder = ObservationUpdateRecorder(stream: observation.updates)
        let secondRecorder = ObservationUpdateRecorder(stream: secondObservation.updates)
        await firstRecorder.waitUntilStarted()
        await secondRecorder.waitUntilStarted()

        try await runtime.notificationEmitter.emitItemStarted(
            threadID: .init(rawValue: "thread-multicast"),
            turnID: .init(rawValue: "turn-multicast"),
            item: .agentMessage(
                id: "message-multicast",
                text: "Multicast update"
            )
        )

        #expect(await firstRecorder.itemInserted(id: "message-multicast") != nil)
        #expect(await secondRecorder.itemInserted(id: "message-multicast") != nil)
    }

    @Test("typed notification emitter drives item lifecycle and text deltas")
    func typedNotificationEmitterDrivesItemLifecycleAndTextDeltas() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let threadID = CodexThreadID(rawValue: "thread-typed-emitter")
        let turnID = CodexTurnID(rawValue: "turn-typed-emitter")

        try await runtime.transport.enqueueThreadResume(
            try observationStoredThread(id: threadID)
        )
        try await runtime.transport.enqueueThreadRead(
            try observationStoredThread(id: threadID)
        )

        let chat = context.model(for: threadID)
        let observation = try await chat.observe()
        defer { observation.cancel() }
        let recorder = ObservationUpdateRecorder(stream: observation.updates)
        await recorder.waitUntilStarted()

        try await runtime.notificationEmitter.emitItemStarted(
            threadID: threadID,
            turnID: turnID,
            item: .agentMessage(
                id: "message-typed-emitter",
                text: "Hel",
                phase: .finalAnswer
            )
        )
        #expect(await observationEventually {
            guard let content = chat.items.first?.content,
                  case .message(let message) = content else {
                return false
            }
            return message.text == "Hel" && message.phase == .finalAnswer
        })

        try await runtime.notificationEmitter.emitAgentMessageDelta(
            threadID: threadID,
            turnID: turnID,
            itemID: "message-typed-emitter",
            delta: "lo"
        )
        #expect(await observationEventually {
            chat.items.first?.text == "Hello"
        })

        try await runtime.notificationEmitter.emitItemCompleted(
            threadID: threadID,
            turnID: turnID,
            item: .agentMessage(id: "message-typed-emitter", text: "Hello")
        )
        #expect(await observationEventually {
            chat.items.first?.text == "Hello"
        })

        try await runtime.notificationEmitter.emitItemStarted(
            threadID: threadID,
            turnID: turnID,
            item: .commandExecution(
                id: "command-typed-emitter",
                command: "swift test",
                cwd: URL(fileURLWithPath: "/tmp/workspace", isDirectory: true),
                status: .inProgress
            )
        )
        #expect(await observationEventually {
            guard let content = chat.items
                .first(where: { $0.itemID == "command-typed-emitter" })?.content,
                case .command(let command) = content else {
                return false
            }
            return command.status == .inProgress
        })
        #expect(await recorder.itemInserted(id: "command-typed-emitter") != nil)
        try await runtime.notificationEmitter.emitItemCompleted(
            threadID: threadID,
            turnID: turnID,
            item: .commandExecution(
                id: "command-typed-emitter",
                command: "swift test",
                cwd: URL(fileURLWithPath: "/tmp/workspace", isDirectory: true),
                status: .completed,
                aggregatedOutput: "passed",
                exitCode: 0
            )
        )
        #expect(await recorder.itemUpdated(id: "command-typed-emitter") != nil)
        #expect(await observationEventually {
            guard let content = chat.items
                .first(where: { $0.itemID == "command-typed-emitter" })?.content,
                case .command(let command) = content else {
                return false
            }
            return command.status == .completed && command.output == "passed"
        })
    }

    @Test("typed notification fixtures reject invalid required values")
    func typedNotificationFixturesRejectInvalidRequiredValues() async throws {
        #expect(throws: CodexAppServerTestError.self) {
            try CodexAppServerTestItem.agentMessage(id: "  ", text: "invalid")
        }
        #expect(throws: CodexAppServerTestError.self) {
            try CodexAppServerTestItem.commandExecution(
                id: "command-invalid",
                command: "swift test",
                cwd: try #require(URL(string: "https://example.com/workspace")),
                status: .inProgress
            )
        }
        let item = try CodexAppServerTestItem.agentMessage(id: "message-valid", text: "Valid")
        #expect(throws: CodexAppServerTestError.self) {
            try CodexAppServerTestTurn(
                snapshot: .init(id: "turn-mismatch", state: .completed, items: []),
                items: [item]
            )
        }
        #expect(throws: CodexAppServerTestError.self) {
            try CodexAppServerTestTurn(
                snapshot: .init(
                    id: "turn-in-progress-with-completion",
                    state: .inProgress,
                    items: [],
                    completedAt: Date(timeIntervalSince1970: 20)
                ),
                items: []
            )
        }
        let summaryTurn = try CodexAppServerTestTurn(
            snapshot: .init(
                id: "turn-summary",
                state: .completed,
                itemsLoadState: .summary,
                items: [item.domainProjection]
            ),
            items: [item]
        )
        guard case .object(let turnFields) = summaryTurn.wireValue else {
            Issue.record("Expected a canonical turn fixture payload.")
            return
        }
        #expect(turnFields["itemsView"] == .string("summary"))
    }

    @Test("typed notification emitter routes specialized current-v2 updates")
    func typedNotificationEmitterRoutesSpecializedCurrentV2Updates() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let threadID = CodexThreadID(rawValue: "thread-specialized-emitter")
        let turnID = CodexTurnID(rawValue: "turn-specialized-emitter")
        try await runtime.transport.enqueueThreadResume(
            try observationStoredThread(id: threadID)
        )
        try await runtime.transport.enqueueThreadRead(
            try observationStoredThread(id: threadID)
        )

        let chat = context.model(for: threadID)
        let observation = try await chat.observe()
        defer { observation.cancel() }
        let recorder = ObservationUpdateRecorder(stream: observation.updates)
        await recorder.waitUntilStarted()

        try await runtime.notificationEmitter.emitItemStarted(
            threadID: threadID,
            turnID: turnID,
            item: .reasoning(id: "reasoning-specialized", summary: ["First"])
        )
        try await runtime.notificationEmitter.emitReasoningSummaryPartAdded(
            threadID: threadID,
            turnID: turnID,
            itemID: "reasoning-specialized",
            summaryIndex: 1
        )
        try await runtime.notificationEmitter.emitReasoningSummaryTextDelta(
            threadID: threadID,
            turnID: turnID,
            itemID: "reasoning-specialized",
            summaryIndex: 1,
            delta: "Second"
        )
        #expect(
            await recorder.itemTextAppended(
                id: "reasoning-specialized",
                delta: "\n\nSecond"
            ) != nil
        )

        let fileChange = CodexFileUpdateChange(
            path: "/tmp/workspace/File.swift",
            kind: .update(movePath: "/tmp/workspace/Moved.swift"),
            diff: "@@ -1 +1 @@"
        )
        let movedFileFixture = try CodexAppServerTestItem.fileChange(
            id: "file-move-wire",
            changes: [fileChange],
            status: .inProgress
        )
        guard case .object(let fileFields) = movedFileFixture.wireValue,
              let changesValue = fileFields["changes"],
              case .array(let fileChanges) = changesValue,
              let firstValue = fileChanges.first,
              case .object(let firstChange) = firstValue,
              let kindValue = firstChange["kind"],
              case .object(let kindFields) = kindValue else {
            Issue.record("Expected a canonical moved-file fixture payload.")
            return
        }
        #expect(kindFields["move_path"] == .string("/tmp/workspace/Moved.swift"))
        #expect(kindFields["movePath"] == nil)
        try await runtime.notificationEmitter.emitItemStarted(
            threadID: threadID,
            turnID: turnID,
            item: .fileChange(
                id: "file-specialized",
                changes: [.init(
                    path: fileChange.path,
                    kind: fileChange.kind,
                    diff: ""
                )],
                status: .inProgress
            )
        )
        try await runtime.notificationEmitter.emitFileChangePatchUpdated(
            threadID: threadID,
            turnID: turnID,
            itemID: "file-specialized",
            changes: [fileChange]
        )

        try await runtime.notificationEmitter.emitItemStarted(
            threadID: threadID,
            turnID: turnID,
            item: .mcpToolCall(
                id: "mcp-specialized",
                server: "review",
                tool: "inspect",
                status: .inProgress
            )
        )
        try await runtime.notificationEmitter.emitMCPToolCallProgress(
            threadID: threadID,
            turnID: turnID,
            itemID: "mcp-specialized",
            message: "Reviewing"
        )

        #expect(await observationEventually {
            chat.items.first(where: { $0.itemID == "reasoning-specialized" })?.text == "First\n\nSecond"
                && chat.items.first(where: { $0.itemID == "file-specialized" })?.text == "@@ -1 +1 @@"
                && chat.items.first(where: { $0.itemID == "mcp-specialized" })?.text == "Reviewing"
        })
        let completedMCP = try CodexAppServerTestItem.mcpToolCall(
            id: "mcp-specialized",
            server: "review",
            tool: "inspect",
            status: .completed,
            resultContent: [.string("Done")],
            structuredContent: .object(["count": .int(1)]),
            resultMetadata: .object(["source": .string("fixture")])
        )
        try await runtime.notificationEmitter.emitItemCompleted(
            threadID: threadID,
            turnID: turnID,
            item: completedMCP
        )
        #expect(await observationEventually {
            guard let content = chat.items
                .first(where: { $0.itemID == "mcp-specialized" })?.content,
                case .toolCall(let actual) = content,
                case .toolCall(let expected) = completedMCP.domainProjection.content else {
                return false
            }
            return actual.result == expected.result && actual.status == .completed
        })
        try await runtime.notificationEmitter.emitThreadStatusChanged(
            threadID: threadID,
            status: .idle
        )
        #expect(await observationEventually { chat.status == .idle })
    }

    @Test("typed turn fixture emits terminal current-v2 snapshots")
    func typedTurnFixtureEmitsTerminalCurrentV2Snapshots() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let threadID = CodexThreadID(rawValue: "thread-terminal-emitter")
        let turnID = CodexTurnID(rawValue: "turn-terminal-emitter")
        try await runtime.transport.enqueueThreadResume(
            try observationStoredThread(id: threadID)
        )
        try await runtime.transport.enqueueThreadRead(
            try observationStoredThread(id: threadID)
        )

        let chat = context.model(for: threadID)
        let observation = try await chat.observe()
        defer { observation.cancel() }
        let item = try CodexAppServerTestItem.agentMessage(
            id: "message-terminal-emitter",
            text: "Done",
            phase: .finalAnswer
        )
        try await runtime.notificationEmitter.emitItemCompleted(
            threadID: threadID,
            turnID: turnID,
            item: item
        )
        let turn = try CodexAppServerTestTurn(
            snapshot: .init(
                id: turnID,
                state: .completed,
                items: [item.domainProjection]
            ),
            items: [item]
        )
        try await runtime.notificationEmitter.emitTurnCompleted(
            threadID: threadID,
            turn: turn
        )

        #expect(await observationEventually {
            guard let content = chat.items.first?.content,
                  case .message(let message) = content else {
                return false
            }
            return chat.phase == .terminal(turnID: turnID, disposition: .completed)
                && message.phase == .finalAnswer
        })
    }

    @Test("observed chat advances without update consumers")
    func observedChatAdvancesWithoutUpdateConsumers() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(
            try observationStoredThread(id: "thread-no-consumer")
        )
        try await runtime.transport.enqueueThreadRead(
            try observationStoredThread(id: "thread-no-consumer")
        )

        let chat = context.model(for: CodexThreadID(rawValue: "thread-no-consumer"))
        let observation = try await chat.observe()
        defer {
            observation.cancel()
        }

        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ObservationTestThreadItemParams(
                threadID: "thread-no-consumer",
                turnID: "turn-no-consumer",
                item: .init(
                    id: "message-no-consumer",
                    type: "agentMessage",
                    text: "Pump-owned mutation"
                )
            )
        )

        #expect(await observationEventually {
            chat.items.map(\.itemID) == ["message-no-consumer"]
                && chat.items.map(\.text) == ["Pump-owned mutation"]
        })
    }

    @Test("observation publishes mutations before fetched results revalidation suspends")
    func observationPublishesBeforeFetchedResultsRevalidation() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let threadID = CodexThreadID(rawValue: "thread-revalidation-order")
        let storedThread = try observationStoredThread(id: threadID)

        try await runtime.transport.enqueueUserVisibleThreadList(.init(threads: [storedThread]))
        let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>())
        try await results.performFetch()
        let chat = try #require(results.items.first)

        try await runtime.transport.enqueueThreadResume(storedThread)
        try await runtime.transport.enqueueThreadRead(storedThread)
        let observation = try await chat.observe()
        defer { observation.cancel() }
        let recorder = ObservationUpdateRecorder(stream: observation.updates)
        await recorder.waitUntilStarted()

        let revalidationGate = CodexAppServerTestGate()
        try await runtime.transport.enqueueUserVisibleThreadList(.init(threads: [storedThread]))
        await runtime.transport.holdNext(.threadList, gate: revalidationGate)

        try await runtime.notificationEmitter.emitItemStarted(
            threadID: threadID,
            turnID: .init(rawValue: "turn-revalidation-order"),
            item: .agentMessage(
                id: "message-revalidation-order",
                text: "Publish before await"
            )
        )
        await revalidationGate.waitUntilBlocked()

        #expect(await recorder.itemInserted(id: "message-revalidation-order") != nil)

        await revalidationGate.open()
    }

    @Test("multiple update consumers do not duplicate model mutation")
    func multipleUpdateConsumersDoNotDuplicateModelMutation() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(
            try observationStoredThread(id: "thread-no-duplicate")
        )
        try await runtime.transport.enqueueThreadRead(
            try observationStoredThread(id: "thread-no-duplicate")
        )

        let chat = context.model(for: CodexThreadID(rawValue: "thread-no-duplicate"))
        let observation = try await chat.observe()
        let secondObservation = try await chat.observe()
        defer {
            observation.cancel()
            secondObservation.cancel()
        }
        let firstRecorder = ObservationUpdateRecorder(stream: observation.updates)
        let secondRecorder = ObservationUpdateRecorder(stream: secondObservation.updates)
        await firstRecorder.waitUntilStarted()
        await secondRecorder.waitUntilStarted()

        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ObservationTestThreadItemParams(
                threadID: "thread-no-duplicate",
                turnID: "turn-no-duplicate",
                item: .init(
                    id: "message-no-duplicate",
                    type: "agentMessage",
                    text: "One model item"
                )
            )
        )

        #expect(await firstRecorder.itemInserted(id: "message-no-duplicate") != nil)
        #expect(await secondRecorder.itemInserted(id: "message-no-duplicate") != nil)
        #expect(chat.items.map(\.itemID) == ["message-no-duplicate"])
    }

    @Test("observation update relay finishes all consumers")
    func observationUpdateRelayFinishesAllConsumers() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(
            try observationStoredThread(id: "thread-finish-multicast")
        )
        try await runtime.transport.enqueueThreadRead(
            try observationStoredThread(id: "thread-finish-multicast")
        )

        let chat = context.model(for: CodexThreadID(rawValue: "thread-finish-multicast"))
        let observation = try await chat.observe()
        let secondObservation = try await chat.observe()
        defer {
            observation.cancel()
            secondObservation.cancel()
        }
        let firstRecorder = ObservationUpdateRecorder(stream: observation.updates)
        let secondRecorder = ObservationUpdateRecorder(stream: secondObservation.updates)
        await firstRecorder.waitUntilStarted()
        await secondRecorder.waitUntilStarted()

        try await runtime.transport.emitServerNotification(
            method: "thread/closed",
            params: ObservationTestThreadClosedParams(threadID: "thread-finish-multicast")
        )

        #expect(await firstRecorder.waitUntilFinished())
        #expect(await secondRecorder.waitUntilFinished())
    }

    @Test("non-last close releases one lease and last close joins the pump")
    func observationCloseHonorsLeaseOwnership() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadResume(
            try observationStoredThread(id: "thread-close-leases")
        )
        try await runtime.transport.enqueueThreadRead(
            try observationStoredThread(id: "thread-close-leases")
        )
        let chat = context.model(for: CodexThreadID(rawValue: "thread-close-leases"))
        let first = try await chat.observe()
        let second = try await chat.observe()
        let firstRecorder = ObservationUpdateRecorder(stream: first.updates)
        let secondRecorder = ObservationUpdateRecorder(stream: second.updates)
        await firstRecorder.waitUntilStarted()
        await secondRecorder.waitUntilStarted()

        await first.close()
        #expect(await firstRecorder.waitUntilFinished())
        #expect(await secondRecorder.waitUntilFinished(attempts: 1) == false)

        try await runtime.transport.emitServerNotification(
            method: "item/started",
            params: ObservationTestThreadItemParams(
                threadID: "thread-close-leases",
                turnID: "turn-close-leases",
                item: .init(id: "message-after-close", type: "agentMessage", text: "still live")
            )
        )
        #expect(await secondRecorder.itemInserted(id: "message-after-close") != nil)

        await second.close()
        #expect(await secondRecorder.waitUntilFinished())

        try await runtime.transport.enqueueThreadResume(
            try observationStoredThread(id: "thread-close-leases")
        )
        try await runtime.transport.enqueueThreadRead(
            try observationStoredThread(id: "thread-close-leases")
        )
        let restarted = try await chat.observe()
        var restartedEvents = restarted.updates.makeAsyncIterator()
        let initial = try #require(await restartedEvents.next())
        #expect(initial.generation == 2)
        guard case .snapshot(_, let reason) = initial.payload else {
            Issue.record("Expected restarted generation snapshot")
            return
        }
        #expect(reason == .generationRestart)
        await restarted.close()
    }

    @Test("failure before first render yields one complete failure snapshot then finishes")
    func setupFailureYieldsSnapshotThenFinishes() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "offline",
            for: "thread/resume"
        )
        let chat = context.model(for: CodexThreadID(rawValue: "thread-setup-failure"))

        let observation = try await chat.observe()
        var events = observation.updates.makeAsyncIterator()
        let failureEvent = try #require(await events.next())
        guard case .snapshot(let snapshot, let reason) = failureEvent.payload else {
            Issue.record("Expected failure snapshot")
            return
        }
        #expect(reason == .upstreamFailure)
        guard case .failed(.appServer) = snapshot.phase else {
            Issue.record("Expected typed app-server failure phase")
            return
        }
        #expect(await events.next() == nil)
        await observation.close()
    }

    @Test("iterator cancellation releases its lease before a new generation starts")
    func iteratorCancellationReleasesLease() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        try await runtime.transport.enqueueThreadResume(
            try observationStoredThread(id: "thread-iterator-cancel")
        )
        try await runtime.transport.enqueueThreadRead(
            try observationStoredThread(id: "thread-iterator-cancel")
        )
        let chat = context.model(for: CodexThreadID(rawValue: "thread-iterator-cancel"))
        let observation = try await chat.observe()
        let consumer = Task { @MainActor in
            for await _ in observation.updates {}
        }
        await Task.yield()
        consumer.cancel()
        await consumer.value
        await observation.close()

        try await runtime.transport.enqueueThreadResume(
            try observationStoredThread(id: "thread-iterator-cancel")
        )
        try await runtime.transport.enqueueThreadRead(
            try observationStoredThread(id: "thread-iterator-cancel")
        )
        let restarted = try await chat.observe()
        var events = restarted.updates.makeAsyncIterator()
        let initial = try #require(await events.next())
        #expect(initial.generation == 2)
        guard case .snapshot(_, let reason) = initial.payload else {
            Issue.record("Expected generation restart snapshot")
            return
        }
        #expect(reason == .generationRestart)
        await restarted.close()
    }
}

private func observationStoredThread(
    id: CodexThreadID
) throws -> CodexAppServerTestStoredThread {
    let workspace = URL(fileURLWithPath: "/tmp/codex-data-kit-observation", isDirectory: true)
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
            turns: []
        ),
        turns: [],
        metadata: .init(
            sessionID: "session-\(id.rawValue)",
            cliVersion: "codex-cli-test",
            source: .appServer
        ),
        runtimeMetadata: .init(
            model: "gpt-5",
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
        isArchived: false
    )
}

private struct ObservationTestThreadItemParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var startedAtMs: Int64 = 0
    var item: Item

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case startedAtMs
        case item
    }

    struct Item: Encodable, Sendable {
        var id: String
        var type: String
        var text: String
    }
}

private struct ObservationTestThreadClosedParams: Encodable, Sendable {
    var threadID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

@MainActor
private func observationEventually(
    attempts: Int = 50,
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@MainActor
private final class ObservationUpdateRecorder {
    private var changes: [CodexChatUpdate] = []
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var isStarted = false
    private var isFinished = false
    private var task: Task<Void, Never>?

    init(stream: CodexChatUpdates) {
        task = Task { @MainActor [weak self] in
            self?.markStarted()
            for await event in stream {
                if case .update(let change) = event.payload {
                    self?.append(change)
                }
            }
            self?.markFinished()
        }
    }

    deinit {
        task?.cancel()
    }

    func waitUntilStarted() async {
        if isStarted {
            return
        }
        await withCheckedContinuation { continuation in
            if isStarted {
                continuation.resume()
            } else {
                startedContinuations.append(continuation)
            }
        }
    }

    func itemInserted(id: String) async -> CodexChatUpdate? {
        await next { change in
            if case .itemInserted(let item, _, _) = change {
                return item.id == id
            }
            if case .turnInserted(let turn, _) = change {
                return turn.items.contains { $0.id == id }
            }
            return false
        }
    }

    func itemUpdated(id: String) async -> CodexChatUpdate? {
        await next { change in
            if case .itemUpdated(let item, _, _) = change {
                return item.id == id
            }
            return false
        }
    }

    func itemTextAppended(id: String, delta: String) async -> CodexChatUpdate? {
        await next { change in
            if case .itemTextAppended(let locator, let appendedDelta) = change {
                return locator.id == id && appendedDelta == delta
            }
            return false
        }
    }

    func waitUntilFinished(attempts: Int = 50) async -> Bool {
        if isFinished {
            return true
        }
        for _ in 0..<attempts {
            if isFinished {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return isFinished
    }

    private func append(_ change: CodexChatUpdate) {
        changes.append(change)
    }

    private func markStarted() {
        guard isStarted == false else {
            return
        }
        isStarted = true
        let continuations = startedContinuations
        startedContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func markFinished() {
        guard isFinished == false else {
            return
        }
        isFinished = true
    }

    private func popFirst(
        matching predicate: (CodexChatUpdate) -> Bool
    ) -> CodexChatUpdate? {
        guard let index = changes.firstIndex(where: predicate) else {
            return nil
        }
        return changes.remove(at: index)
    }

    private func next(
        matching predicate: (CodexChatUpdate) -> Bool
    ) async -> CodexChatUpdate? {
        for _ in 0..<50 {
            if let change = popFirst(matching: predicate) {
                return change
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return popFirst(matching: predicate)
    }
}
