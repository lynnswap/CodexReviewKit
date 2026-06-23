import Foundation
import Testing

import CodexAppServerKitTesting
@testable import CodexAppServerKit

@Suite("CodexAppServerKit")
struct CodexAppServerKitTests {
    @Test func localProcessConfigurationOwnsDefaultCodexHome() {
        let fromHome = CodexAppServer.Configuration.LocalProcess(environment: [
            "HOME": "/tmp/user-home",
        ])
        #expect(fromHome.codexHomeURL.path == "/tmp/user-home/.codex")

        let fromCodexHome = CodexAppServer.Configuration.LocalProcess(environment: [
            "CODEX_HOME": "/tmp/codex-home",
            "HOME": "/tmp/user-home",
        ])
        #expect(fromCodexHome.codexHomeURL.path == "/tmp/codex-home")

        let appSupport = URL(fileURLWithPath: "/tmp/app-support", isDirectory: true)
        let containerDefault = CodexAppServer.Configuration.LocalProcess.defaultCodexHomeURL(
            environment: [:],
            homeDirectoryForCurrentUser: URL(fileURLWithPath: "/tmp/home", isDirectory: true),
            applicationSupportDirectory: appSupport
        )
        #expect(containerDefault.path == "/tmp/app-support/Codex")

        let homeFallback = CodexAppServer.Configuration.LocalProcess.defaultCodexHomeURL(
            environment: [:],
            homeDirectoryForCurrentUser: URL(fileURLWithPath: "/tmp/home", isDirectory: true),
            applicationSupportDirectory: nil
        )
        #expect(homeFallback.path == "/tmp/home/Library/Application Support/Codex")
    }

    @Test func testRuntimeStartsAppServerWithoutLaunchingProcess() async throws {
        let runtime = try await CodexAppServerTestRuntime.start(codexHome: "/tmp/codex")
        try await runtime.transport.enqueueThreadStart(threadID: "thread-test", model: "gpt-5")

        let thread = try await runtime.server.startThread(
            in: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            options: .init(model: "gpt-5")
        )

        #expect(thread.id == "thread-test")
        #expect(await runtime.transport.recordedRequests().map(\.method) == [
            "initialize",
            "thread/start",
        ])
        #expect(await runtime.transport.recordedNotifications().map(\.method) == [
            "initialized"
        ])
    }

    @Test func testTransportHoldsRequestsAtExplicitGate() async throws {
        let transport = CodexAppServerTestTransport()
        let gate = CodexAppServerTestGate()
        await transport.holdNext(method: "ping", gate: gate)
        let client = AppServerClient(transport: transport)

        let task = Task {
            let _: EmptyResponse = try await client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: EmptyResponse.self
            )
        }

        await transport.waitForRequest(method: "ping")
        #expect(await transport.maxActiveCount(for: "ping") == 1)

        await gate.open()
        try await task.value
    }

    @Test func initializeSendsHandshakeAndInitializedNotification() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Initialize.Response(codexHome: "/tmp/codex"), for: "initialize")
        let client = AppServerClient(transport: transport)

        let response = try await client.initialize(clientName: "TestClient", clientVersion: "1")

        #expect(response.codexHome == "/tmp/codex")
        #expect(await transport.recordedRequests().map(\.method) == ["initialize"])
        #expect(await transport.recordedNotifications().map(\.method) == ["initialized"])
        let params = try #require(await transport.recordedRequests().first?.params)
        let decoded = try JSONDecoder().decode(AppServerAPI.Initialize.Params.self, from: params)
        #expect(decoded.clientInfo.name == "TestClient")
        #expect(decoded.clientInfo.version == "1")
    }

    @Test func appServerStartThreadSerializesDomainOptions() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"),
            for: "thread/start"
        )
        let client = AppServerClient(transport: transport)
        let server = CodexAppServer(
            client: client,
            router: CodexAppServerNotificationRouter(client: client)
        )
        let workspace = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

        let thread = try await server.startThread(
            in: workspace,
            instructions: .init(base: "Base", developer: "Developer"),
            options: .init(
                model: "gpt-5",
                sandbox: .workspaceWrite,
                ephemeral: true,
                config: ["experimental": .bool(true)],
                personality: .pragmatic,
                serviceName: "review-monitor",
                sessionStartSource: .startup,
                threadSource: "automation"
            )
        )

        #expect(thread.id == "thread-1")
        let request = try #require(await transport.recordedRequests().first)
        #expect(request.method == "thread/start")
        let params = try JSONDecoder().decode(
            AppServerAPI.Thread.Start.Params.self, from: request.params)
        #expect(params.cwd == workspace.path)
        #expect(params.model == "gpt-5")
        #expect(params.ephemeral == true)
        #expect(params.baseInstructions == "Base")
        #expect(params.developerInstructions == "Developer")
        #expect(params.approvalPolicy == "on-request")
        #expect(params.approvalsReviewer == "auto_review")
        #expect(params.sandbox == "workspace-write")
        #expect(params.config == ["experimental": .bool(true)])
        #expect(params.personality == "pragmatic")
        #expect(params.serviceName == "review-monitor")
        #expect(params.sessionStartSource == .startup)
        #expect(params.threadSource?.rawValue == "automation")
    }

    @Test func appServerListThreadsSerializesQueryOptions() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Thread.List.Response(data: [], nextCursor: "next"),
            for: "thread/list"
        )
        let client = AppServerClient(transport: transport)
        let server = CodexAppServer(
            client: client,
            router: CodexAppServerNotificationRouter(client: client)
        )
        let workspace = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

        let page = try await server.listThreads(.init(
            archived: false,
            cursor: "cursor",
            workspace: workspace,
            limit: 10,
            searchTerm: "review",
            modelProviders: ["openai"],
            sortDirection: .descending,
            sortKey: .recencyAt,
            sourceKinds: [.appServer, .subAgentReview],
            useStateDBOnly: true
        ))

        #expect(page.nextCursor == "next")
        let request = try #require(await transport.recordedRequests().first)
        #expect(request.method == "thread/list")
        let params = try JSONDecoder().decode(
            AppServerAPI.Thread.List.Params.self,
            from: request.params
        )
        #expect(params.archived == false)
        #expect(params.cursor == "cursor")
        #expect(params.cwd == .path(workspace.path))
        #expect(params.limit == 10)
        #expect(params.searchTerm == "review")
        #expect(params.modelProviders == ["openai"])
        #expect(params.sortDirection == "desc")
        #expect(params.sortKey == "recency_at")
        #expect(params.sourceKinds == ["appServer", "subAgentReview"])
        #expect(params.useStateDbOnly == true)
    }

    @Test func threadStartReviewSerializesTargetAndStreamsReviewThreadLogs() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "turn-review",
                reviewThreadID: "thread-review"
            ),
            for: "review/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router)

        let review = try await thread.startReview(
            target: .baseBranch("main"),
            delivery: .detached
        )

        #expect(review.threadID == "thread-1")
        #expect(review.turnID == "turn-review")
        #expect(review.reviewThreadID == "thread-review")

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.method == "review/start")
        let params = try JSONDecoder().decode(
            AppServerAPI.Review.Start.Params.self,
            from: request.params
        )
        #expect(params.threadID == "thread-1")
        #expect(params.target == .baseBranch("main"))
        #expect(params.delivery == .detached)

        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(
                    id: "command-1",
                    type: "commandExecution",
                    command: "swift test",
                    aggregatedOutput: "passed",
                    status: "completed"
                )
            )
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-review")
        )

        let logs = try await collect(review.logEntries)
        #expect(logs.count == 1)
        #expect(logs.first?.turnID == "turn-review")
        #expect(logs.first?.item?.kind == .commandExecution)
        #expect(logs.first?.item?.text == "passed")
    }

    @Test func promptPartsEncodeToAppServerInputItems() {
        let prompt = CodexPrompt(parts: [
            .text("Describe these files."),
            .imageURL(URL(string: "https://example.test/diagram.png")!),
            .localImage(URL(fileURLWithPath: "/tmp/screenshot.png")),
            .skill(name: "checks", path: URL(fileURLWithPath: "/tmp/skills/checks")),
            .mention(name: "repo", path: URL(fileURLWithPath: "/tmp/repo")),
        ])

        #expect(
            prompt.appServerInput == [
                .text("Describe these files."),
                .image(url: "https://example.test/diagram.png"),
                .localImage(path: "/tmp/screenshot.png"),
                .skill(name: "checks", path: "/tmp/skills/checks"),
                .mention(name: "repo", path: "/tmp/repo"),
            ])
    }

    @Test func clientRetriesOverloadedRequestsThenSucceeds() async throws {
        let transport = CodexAppServerTestTransport()
        await transport.enqueueFailure(code: -32001, message: "server busy", for: "ping")
        try await transport.enqueue(EmptyResponse(), for: "ping")
        let client = AppServerClient(
            transport: transport,
            overloadRetryDelay: { $0 == 0 ? .zero : nil },
            retrySleep: { _ in }
        )

        let _: EmptyResponse = try await client.send(
            method: "ping",
            params: EmptyResponse(),
            responseType: EmptyResponse.self
        )

        #expect(await transport.recordedRequests().map(\.method) == ["ping", "ping"])
    }

    @Test func turnResultReplaysEarlyNotificationsAndKeepsUnknownEvents() async throws {
        let transport = CodexAppServerTestTransport()
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        try await transport.emitServerNotification(
            method: "future/notification",
            params: TurnIDParams(turnID: "turn-1")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(turnID: "turn-1", delta: "Done")
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "completed"))
        )
        let turn = CodexTurn(
            id: "turn-1",
            threadID: "thread-1",
            client: client,
            router: router
        )

        let events = try await collect(turn.events)
        #expect(
            events.contains {
                if case .unknown(let raw) = $0 {
                    raw.method == "future/notification"
                } else {
                    false
                }
            })
        let result = try await CodexResponseCollector.collect(
            from: .init {
                AsyncThrowingStream { continuation in
                    for event in events {
                        continuation.yield(event)
                    }
                    continuation.finish()
                }
            })
        #expect(result.turnID == "turn-1")
        #expect(result.status == .completed)
        #expect(result.finalAnswer == "Done")
    }

    @Test func threadStreamsReplayMessagesTranscriptLogsAndUsage() async throws {
        let transport = CodexAppServerTestTransport()
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    id: "message-1",
                    type: "agentMessage",
                    text: "Interim",
                    phase: "commentary"
                )
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    id: "message-2",
                    type: "agentMessage",
                    text: "Final",
                    phase: "final_answer"
                )
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    id: "command-1",
                    type: "commandExecution",
                    command: "swift test",
                    aggregatedOutput: "passed",
                    status: "completed"
                )
            )
        )
        try await transport.emitServerNotification(
            method: "thread/tokenUsage/updated",
            params: TokenUsageParams(
                threadID: "thread-1",
                turnID: "turn-1",
                tokenUsage: .init(
                    total: .init(inputTokens: 1, outputTokens: 2, totalTokens: 3)
                )
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "completed"))
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router
        )

        let messages = try await collect(thread.messages)
        #expect(messages.map(\.text) == ["Interim", "Final"])
        #expect(messages.last?.phase == .finalAnswer)

        let transcripts = try await collect(thread.transcriptUpdates)
        #expect(transcripts.last?.finalAnswer == "Final")
        #expect(transcripts.last?.items.count == 3)

        let logs = try await collect(thread.logEntries)
        #expect(logs.contains { $0.item?.kind == .commandExecution })
        #expect(logs.contains { $0.item?.text == "Final" })

        let events = try await collect(thread.events)
        #expect(
            events.contains {
                if case .tokenUsageUpdated(let usage, let turnID) = $0 {
                    turnID == "turn-1" && usage.totalTokens == 3
                } else {
                    false
                }
            })
    }

    @Test func responseStreamYieldsSnapshotsAndCollectsFinalResponse() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router
        )

        let stream = try await thread.streamResponse {
            "Summarize this."
            CodexPrompt.Part.mention(name: "repo", path: URL(fileURLWithPath: "/tmp/repo"))
        }

        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(turnID: "turn-1", delta: "Final")
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "completed"))
        )

        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first?.turnID == "turn-1")
        #expect(first?.content == "Final")

        let response = try await stream.collect()
        #expect(response.turnID == "turn-1")
        #expect(response.finalAnswer == "Final")

        let request = try #require(await transport.recordedRequests().first)
        let params = try JSONDecoder().decode(
            AppServerAPI.Turn.Start.Params.self, from: request.params)
        #expect(
            params.input == [
                .text("Summarize this."),
                .mention(name: "repo", path: "/tmp/repo"),
            ])
    }

    @Test func responseStreamFailureCarriesPartialResponse() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router)

        let stream = try await thread.streamResponse(to: "Try this.")
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(turnID: "turn-1", delta: "Partial")
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(
                id: "turn-1",
                status: "failed",
                error: .init(message: "Tool failed."),
                startedAt: 1_700_000_000,
                completedAt: 1_700_000_001,
                durationMS: 1_000
            ))
        )

        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first?.content == "Partial")
        let terminal = try await iterator.next()
        #expect(terminal?.response?.status == .failed)
        #expect(terminal?.response?.errorMessage == "Tool failed.")
        #expect(terminal?.response?.transcript.responseText == "Partial")
        #expect(terminal?.response?.startedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(terminal?.response?.duration == .milliseconds(1_000))
        do {
            _ = try await iterator.next()
            Issue.record("Expected failed stream to throw after terminal snapshot.")
        } catch let error as CodexAppServerError {
            #expect(error.response?.status == .failed)
            #expect(error.response?.transcript.responseText == "Partial")
        }

        do {
            _ = try await stream.collect()
            Issue.record("Expected collect() to throw for failed turn.")
        } catch let error as CodexAppServerError {
            #expect(error.response?.status == .failed)
            #expect(error.response?.transcript.responseText == "Partial")
        }
    }

    @Test func responseStreamSerializesReasoningOptions() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        let thread = CodexThread(id: "thread-1", client: client, router: router)

        _ = try await thread.streamResponse(
            to: "Explain the patch.",
            options: .init(
                effort: .high,
                summary: .detailed,
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["summary": .object(["type": .string("string")])]),
                ]),
                personality: .pragmatic,
                clientUserMessageID: "client-message-1"
            )
        )

        let request = try #require(await transport.recordedRequests().first)
        let params = try JSONDecoder().decode(
            AppServerAPI.Turn.Start.Params.self,
            from: request.params
        )
        #expect(params.effort == "high")
        #expect(params.summary == "detailed")
        #expect(params.outputSchema == .object([
            "type": .string("object"),
            "properties": .object(["summary": .object(["type": .string("string")])]),
        ]))
        #expect(params.personality == "pragmatic")
        #expect(params.clientUserMessageID == "client-message-1")
    }

    @Test func messageDeltaLogEntriesUseUniqueEntryIDs() async throws {
        let transport = CodexAppServerTestTransport()
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(threadID: "thread-1", turnID: "turn-1", delta: "First")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(threadID: "thread-1", turnID: "turn-1", delta: "Second")
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )

        let thread = CodexThread(id: "thread-1", client: client, router: router)
        let logs = try await collect(thread.logEntries)
        #expect(logs.map(\.id) == ["agent-message-delta:0", "agent-message-delta:1"])
        #expect(logs.compactMap(\.messageDelta).map(\.text) == ["First", "Second"])
    }

    @Test func reasoningNotificationsRouteAsTypedEventsLogsAndTranscript() async throws {
        let transport = CodexAppServerTestTransport()
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)

        try await transport.emitServerNotification(
            method: "item/reasoning/summaryPartAdded",
            params: ReasoningSummaryPartParams(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "reasoning-1",
                summaryIndex: 0
            )
        )
        try await transport.emitServerNotification(
            method: "item/reasoning/summaryTextDelta",
            params: ReasoningSummaryDeltaParams(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "reasoning-1",
                summaryIndex: 0,
                delta: "Checking"
            )
        )
        try await transport.emitServerNotification(
            method: "item/reasoning/textDelta",
            params: ReasoningTextDeltaParams(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "reasoning-1",
                contentIndex: 1,
                delta: "Raw trace"
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    id: "reasoning-1",
                    type: "reasoning",
                    summary: ["Final summary"],
                    content: ["Final raw"]
                )
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "completed"))
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )

        let thread = CodexThread(id: "thread-1", client: client, router: router)
        let events = try await collect(thread.events)
        #expect(
            events.contains {
                if case .reasoningSummaryPartAdded(let part, let turnID) = $0 {
                    part.id == "reasoning-1:summary:0" && turnID == "turn-1"
                } else {
                    false
                }
            })
        #expect(
            events.contains {
                if case .reasoningDelta(let delta, let turnID) = $0 {
                    delta.id == "reasoning-1:content:1"
                        && delta.delta == "Raw trace"
                        && turnID == "turn-1"
                } else {
                    false
                }
            })

        let logs = try await collect(thread.logEntries)
        #expect(logs.contains { $0.id == "reasoning-1:summary:0" && $0.phase == .started })
        #expect(
            logs.contains {
                $0.reasoningDelta?.id == "reasoning-1:summary:0"
                    && $0.reasoningDelta?.delta == "Checking"
            })
        #expect(
            logs.contains {
                $0.reasoningDelta?.id == "reasoning-1:content:1"
                    && $0.reasoningDelta?.delta == "Raw trace"
            })

        let transcripts = try await collect(thread.transcriptUpdates)
        let finalTranscript = try #require(transcripts.last)
        #expect(finalTranscript.items.map(\.id) == ["reasoning-1"])
        #expect(finalTranscript.items.first?.content == .reasoning(
            .init(summary: ["Final summary"], content: ["Final raw"])
        ))
    }

    @Test func modelAndConfigurationDecodeReasoningTypes() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(
            """
            {
              "data": [
                {
                  "id": "gpt-5-codex",
                  "model": "gpt-5-codex",
                  "displayName": "GPT-5 Codex",
                  "hidden": false,
                  "supportedReasoningEfforts": [
                    {"reasoningEffort": "medium", "description": "Balanced"},
                    {"reasoningEffort": "xhigh", "description": "Maximum"}
                  ],
                  "defaultReasoningEffort": "xhigh",
                  "additionalSpeedTiers": [],
                  "isDefault": true
                }
              ],
              "nextCursor": null
            }
            """,
            for: "model/list"
        )
        try await transport.enqueueJSON(
            """
            {
              "config": {
                "model": "gpt-5-codex",
                "model_reasoning_effort": "high",
                "service_tier": "flex"
              }
            }
            """,
            for: "config/read"
        )
        let client = AppServerClient(transport: transport)
        let server = CodexAppServer(
            client: client,
            router: CodexAppServerNotificationRouter(client: client)
        )

        let models = try await server.models()
        let reasoningEfforts = models.first?.supportedReasoningEfforts.map(\.reasoningEffort)
        #expect(reasoningEfforts == [.medium, .xhigh])
        #expect(models.first?.defaultReasoningEffort == .xhigh)

        let configuration = try await server.configuration()
        #expect(configuration.reasoningEffort == .high)
    }

    @Test func responseStreamInterruptSendsTurnInterrupt() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router
        )

        let stream = try await thread.streamResponse(to: "Run the slow checks.")
        try await stream.interrupt()

        #expect(
            await transport.recordedRequests().map(\.method) == [
                "turn/start",
                "turn/interrupt",
            ])
        let request = try #require(await transport.recordedRequests().last)
        let params = try JSONDecoder().decode(
            AppServerAPI.Turn.Interrupt.Params.self, from: request.params)
        #expect(params.threadID == "thread-1")
        #expect(params.turnID == "turn-1")
    }

    @Test func responseStreamSteerSubmitsInputToCurrentTurn() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        try await transport.enqueue(
            AppServerAPI.Turn.Steer.Response(turnID: "turn-1"),
            for: "turn/steer"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router
        )

        let stream = try await thread.streamResponse(to: "Run the slow checks.")
        try await stream.steer(with: "Prefer the smallest fix.")

        #expect(
            await transport.recordedRequests().map(\.method) == [
                "turn/start",
                "turn/steer",
            ])
        let request = try #require(await transport.recordedRequests().last)
        let params = try JSONDecoder().decode(
            AppServerAPI.Turn.Steer.Params.self, from: request.params)
        #expect(params.threadID == "thread-1")
        #expect(params.expectedTurnID == "turn-1")
        #expect(params.input == [.text("Prefer the smallest fix.")])
    }

    @Test func responseStreamQueueStartsFollowUpAfterCurrentResponse() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-2", status: "running")),
            for: "turn/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router
        )

        let stream = try await thread.streamResponse(to: "First request.")
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "completed"))
        )

        _ = try await stream.submit(
            "Second request.",
            mode: .queueAfterCurrentResponse,
            options: .init(model: "gpt-5")
        )

        #expect(
            await transport.recordedRequests().map(\.method) == [
                "turn/start",
                "turn/start",
            ])
        let request = try #require(await transport.recordedRequests().last)
        let params = try JSONDecoder().decode(
            AppServerAPI.Turn.Start.Params.self, from: request.params)
        #expect(params.threadID == "thread-1")
        #expect(params.input == [.text("Second request.")])
        #expect(params.model == "gpt-5")
    }

    @Test func responseStreamInterruptStartsFollowUpAfterServerTerminalEvent() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-2", status: "running")),
            for: "turn/start"
        )
        let client = AppServerClient(transport: transport)
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router
        )

        let stream = try await thread.streamResponse(to: "Long request.")
        let followUpTask = Task {
            try await stream.submit(
                "Use the shorter path.",
                mode: .interruptCurrentResponse
            )
        }
        await transport.waitForRequestCount(2)
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "interrupted"))
        )
        _ = try await followUpTask.value

        #expect(
            await transport.recordedRequests().map(\.method) == [
                "turn/start",
                "turn/interrupt",
                "turn/start",
            ])
        let interruptRequest = try #require(await transport.recordedRequests().dropLast().last)
        let interruptParams = try JSONDecoder().decode(
            AppServerAPI.Turn.Interrupt.Params.self, from: interruptRequest.params)
        #expect(interruptParams.threadID == "thread-1")
        #expect(interruptParams.turnID == "turn-1")

        let followUpRequest = try #require(await transport.recordedRequests().last)
        let followUpParams = try JSONDecoder().decode(
            AppServerAPI.Turn.Start.Params.self, from: followUpRequest.params)
        #expect(followUpParams.threadID == "thread-1")
        #expect(followUpParams.input == [.text("Use the shorter path.")])
    }
}

private func collect<Sequence: AsyncSequence>(
    _ sequence: Sequence
) async throws -> [Sequence.Element] {
    var elements: [Sequence.Element] = []
    for try await element in sequence {
        elements.append(element)
    }
    return elements
}

private struct TurnIDParams: Encodable, Sendable {
    var turnID: String

    enum CodingKeys: String, CodingKey {
        case turnID = "turnId"
    }
}

private struct ThreadIDParams: Encodable, Sendable {
    var threadID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

private struct TurnDeltaParams: Encodable, Sendable {
    var threadID: String? = nil
    var turnID: String
    var delta: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case delta
    }
}

private struct TurnCompletedParams: Encodable, Sendable {
    var turn: AppServerAPI.Turn.Payload
}

private struct ThreadItemParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var item: Item

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case item
    }

    struct Item: Encodable, Sendable {
        var id: String
        var type: String
        var text: String?
        var phase: String?
        var command: String?
        var aggregatedOutput: String?
        var status: String?
        var summary: [String]?
        var content: [String]?

        init(
            id: String,
            type: String,
            text: String? = nil,
            phase: String? = nil,
            command: String? = nil,
            aggregatedOutput: String? = nil,
            status: String? = nil,
            summary: [String]? = nil,
            content: [String]? = nil
        ) {
            self.id = id
            self.type = type
            self.text = text
            self.phase = phase
            self.command = command
            self.aggregatedOutput = aggregatedOutput
            self.status = status
            self.summary = summary
            self.content = content
        }
    }
}

private struct ReasoningSummaryPartParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var summaryIndex: Int

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case summaryIndex
    }
}

private struct ReasoningSummaryDeltaParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var summaryIndex: Int
    var delta: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case summaryIndex
        case delta
    }
}

private struct ReasoningTextDeltaParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var contentIndex: Int
    var delta: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case contentIndex
        case delta
    }
}

private struct TokenUsageParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var tokenUsage: TokenUsage

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case tokenUsage
    }

    struct TokenUsage: Encodable, Sendable {
        var total: Breakdown
        var modelContextWindow: Int?
    }

    struct Breakdown: Encodable, Sendable {
        var cachedInputTokens: Int = 0
        var inputTokens: Int
        var outputTokens: Int
        var reasoningOutputTokens: Int = 0
        var totalTokens: Int
    }
}
