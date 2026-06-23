import Foundation
import Testing

@testable import CodexAppServerKit

@Suite("CodexAppServerKit")
struct CodexAppServerKitTests {
    @Test func initializeSendsHandshakeAndInitializedNotification() async throws {
        let transport = FakeJSONRPCTransport()
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
        let transport = FakeJSONRPCTransport()
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
            options: .init(model: "gpt-5", sandbox: .workspaceWrite, ephemeral: true)
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
        let transport = FakeJSONRPCTransport()
        await transport.enqueueFailure(
            .responseError(code: -32001, message: "server busy"), for: "ping")
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
        let transport = FakeJSONRPCTransport()
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
        let transport = FakeJSONRPCTransport()
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
        let transport = FakeJSONRPCTransport()
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

    @Test func responseStreamInterruptSendsTurnInterrupt() async throws {
        let transport = FakeJSONRPCTransport()
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
        let transport = FakeJSONRPCTransport()
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
        let transport = FakeJSONRPCTransport()
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
        let transport = FakeJSONRPCTransport()
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

private actor FakeJSONRPCTransport: JSONRPC.Transport {
    private enum QueuedResponse: Sendable {
        case success(Data)
        case failure(JSONRPC.Error)
    }

    private var responses: [String: [QueuedResponse]] = [:]
    private var requests: [JSONRPC.Request] = []
    private var notifications: [JSONRPC.Notification] = []
    private var notificationContinuations:
        [AsyncThrowingStream<JSONRPC.Notification, Error>.Continuation] = []
    private var notificationStreamCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var requestCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var closed = false

    func enqueue<Response: Encodable & Sendable>(_ response: Response, for method: String) throws {
        responses[method, default: []].append(.success(try JSONEncoder().encode(response)))
    }

    func enqueueFailure(_ error: JSONRPC.Error, for method: String) {
        responses[method, default: []].append(.failure(error))
    }

    func send(_ request: JSONRPC.Request) async throws -> Data {
        guard closed == false else {
            throw JSONRPC.Error.closed
        }
        requests.append(request)
        resumeRequestCountWaiters()
        let queued =
            responses[request.method, default: []].isEmpty
            ? nil
            : responses[request.method, default: []].removeFirst()
        switch queued {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        case nil:
            return try JSONEncoder().encode(EmptyResponse())
        }
    }

    func notify(_ notification: JSONRPC.Notification) async throws {
        notifications.append(notification)
    }

    func notificationStream() -> AsyncThrowingStream<JSONRPC.Notification, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            notificationContinuations.append(continuation)
            resumeNotificationStreamCountWaiters()
        }
    }

    func close() async {
        closed = true
        for continuation in notificationContinuations {
            continuation.finish()
        }
        notificationContinuations.removeAll()
    }

    func recordedRequests() -> [JSONRPC.Request] {
        requests
    }

    func recordedNotifications() -> [JSONRPC.Notification] {
        notifications
    }

    func waitForRequestCount(_ count: Int) async {
        if requests.count >= count {
            return
        }
        await withCheckedContinuation { continuation in
            if requests.count >= count {
                continuation.resume()
            } else {
                requestCountWaiters.append((count, continuation))
            }
        }
    }

    func waitForNotificationStreamCount(_ count: Int) async {
        if notificationContinuations.count >= count {
            return
        }
        await withCheckedContinuation { continuation in
            if notificationContinuations.count >= count {
                continuation.resume()
            } else {
                notificationStreamCountWaiters.append((count, continuation))
            }
        }
    }

    func emitServerNotification<Params: Encodable & Sendable>(
        method: String,
        params: Params
    ) throws {
        let notification = JSONRPC.Notification(
            method: method,
            params: try JSONEncoder().encode(params)
        )
        for continuation in notificationContinuations {
            continuation.yield(notification)
        }
    }

    private func resumeNotificationStreamCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in notificationStreamCountWaiters {
            if notificationContinuations.count >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        notificationStreamCountWaiters = remaining
    }

    private func resumeRequestCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in requestCountWaiters {
            if requests.count >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        requestCountWaiters = remaining
    }
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
    var turnID: String
    var delta: String

    enum CodingKeys: String, CodingKey {
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

        init(
            id: String,
            type: String,
            text: String? = nil,
            phase: String? = nil,
            command: String? = nil,
            aggregatedOutput: String? = nil,
            status: String? = nil
        ) {
            self.id = id
            self.type = type
            self.text = text
            self.phase = phase
            self.command = command
            self.aggregatedOutput = aggregatedOutput
            self.status = status
        }
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
