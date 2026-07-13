import Darwin
import Foundation
import MCP
import Synchronization
@preconcurrency import NIOCore
import Testing
@_spi(Testing) @testable import CodexReviewKit
import CodexReviewKit
@testable import CodexReviewMCPServer
import CodexReviewTesting

@Suite("MCP Streamable HTTP server")
@MainActor
struct CodexReviewMCPHTTPServerTests {
    @Test func streamableHTTPInitializesAndListsTools() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let response = try await postJSONRPC(
                endpoint: await server.url,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/list",
                ]
            )
            let toolNames = try #require(response.value(for: ["result", "tools"]) as? [[String: Any]])
                .compactMap { $0["name"] as? String }
            #expect(toolNames == ["review_start", "review_await", "review_read", "review_list", "review_cancel"])

            let tools = try #require(response.value(for: ["result", "tools"]) as? [[String: Any]])
            let reviewStart = try #require(tools.first { $0["name"] as? String == "review_start" })
            let schema = try #require(reviewStart["inputSchema"] as? [String: Any])
            let properties = try #require(schema["properties"] as? [String: Any])
            let target = try #require(properties["target"] as? [String: Any])
            let targetProperties = try #require(target["properties"] as? [String: Any])
            #expect(targetProperties.keys.contains("instructions"))

            let reviewRead = try #require(tools.first { $0["name"] as? String == "review_read" })
            let readSchema = try #require(reviewRead["inputSchema"] as? [String: Any])
            let readProperties = try #require(readSchema["properties"] as? [String: Any])
            #expect(readProperties["logOffset"] == nil)
            #expect(readProperties["logLimit"] == nil)
            #expect(readProperties["logFilter"] == nil)
            let reviewAwait = try #require(tools.first { $0["name"] as? String == "review_await" })
            let awaitSchema = try #require(reviewAwait["inputSchema"] as? [String: Any])
            let awaitProperties = try #require(awaitSchema["properties"] as? [String: Any])
            #expect(awaitProperties["runId"] != nil)
            #expect(awaitProperties["jobId"] != nil)
            #expect(awaitProperties["jobID"] != nil)
            #expect(awaitProperties["logOffset"] == nil)
            let awaitAnyOf = try #require(awaitSchema["anyOf"] as? [[String: Any]])
            let requiredAliases = awaitAnyOf.compactMap { $0["required"] as? [String] }
            #expect(requiredAliases.contains(["runId"]))
            #expect(requiredAliases.contains(["runID"]))
            #expect(requiredAliases.contains(["jobId"]))
            #expect(requiredAliases.contains(["jobID"]))
        }
    }

    @Test func streamableHTTPAllowsConfiguredHostDuringValidation() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let server = CodexReviewMCPHTTPServer(
            adapter: CodexReviewMCPServer(store: store),
            configuration: .init(host: "127.0.0.1", port: 0)
        )
        try await server.start()
        let port = try #require(await server.url.port)
        let initializeBody = try makeJSONBody([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-11-25",
                "capabilities": [:],
                "clientInfo": [
                    "name": "CodexReviewKitTests",
                    "version": "0.0.0",
                ],
            ],
        ])
        let response = await server.handleHTTPRequestForTesting(
            HTTPRequest(
                method: "POST",
                headers: [
                    HTTPHeaderName.host: "127.0.0.1:\(port)",
                    HTTPHeaderName.accept: "text/event-stream, application/json",
                    HTTPHeaderName.contentType: "application/json",
                ],
                body: initializeBody,
                path: "/mcp"
            ))
        let denied = await server.handleHTTPRequestForTesting(
            HTTPRequest(
                method: "POST",
                headers: [
                    HTTPHeaderName.host: "other.local:\(port)",
                    HTTPHeaderName.accept: "text/event-stream, application/json",
                    HTTPHeaderName.contentType: "application/json",
                ],
                body: initializeBody,
                path: "/mcp"
            ))

        #expect(response.statusCode == 200)
        #expect(response.headers[HTTPHeaderName.sessionID]?.isEmpty == false)
        #expect(denied.statusCode == 421)
        await server.stop()
        assertNoHTTPServerResources(await server.resourceSnapshotForTesting())
    }

    @Test func streamableHTTPRejectsRequestsUntilStagedServerIsActivated() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let server = CodexReviewMCPHTTPServer(
            adapter: CodexReviewMCPServer(store: store),
            configuration: .init(host: "127.0.0.1", port: 0)
        )
        let request = HTTPRequest(method: "GET", path: "/mcp")

        try await server.stage()
        let stagedResponse = await server.handleHTTPRequestForTesting(request)
        await server.activate()
        let acceptingResponse = await server.handleHTTPRequestForTesting(request)
        await server.stop()

        #expect(stagedResponse.statusCode == 503)
        #expect(acceptingResponse.statusCode == 400)
        assertNoHTTPServerResources(await server.resourceSnapshotForTesting())
    }

    @Test func streamableHTTPCloseDrainsInitializationBeforeLateProtocolServerBind() async throws {
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        )
        let protocolServerGate = AsyncGate()
        let (initializingSessionIDs, initializingSessionContinuation) =
            AsyncStream<String>.makeStream()
        let server = CodexReviewMCPHTTPServer(
            adapter: CodexReviewMCPServer(store: store),
            configuration: .init(host: "127.0.0.1", port: 0),
            protocolServerFactory: {
                adapter,
                sessionID,
                registry,
                clientSession,
                boundedReviewWaitDuration in
                let protocolServer = await makeMCPProtocolServer(
                    adapter: adapter,
                    sessionID: sessionID,
                    sessionRegistry: registry,
                    clientSession: clientSession,
                    boundedReviewWaitDuration: boundedReviewWaitDuration
                )
                initializingSessionContinuation.yield(sessionID)
                do {
                    try await protocolServerGate.wait()
                } catch {
                    preconditionFailure("The protocol-server test gate was cancelled: \(error)")
                }
                return protocolServer
            }
        )
        try await server.start()
        let port = try #require(await server.url.port)
        let initializeRequest = HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeaderName.host: "127.0.0.1:\(port)",
                HTTPHeaderName.accept: "text/event-stream, application/json",
                HTTPHeaderName.contentType: "application/json",
            ],
            body: try makeJSONBody([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "protocolVersion": "2025-11-25",
                    "capabilities": [:],
                    "clientInfo": [
                        "name": "CodexReviewKitTests",
                        "version": "0.0.0",
                    ],
                ],
            ]),
            path: "/mcp"
        )

        let initialization = Task {
            await server.handleHTTPRequestForTesting(initializeRequest)
        }
        var sessionIDIterator = initializingSessionIDs.makeAsyncIterator()
        let sessionID = try #require(await sessionIDIterator.next())
        let stop = Task {
            await server.stop()
        }
        let enteredClosing = await waitUntil(timeout: .seconds(2)) {
            await server.sessionIsClosingForTesting(sessionID: sessionID)
        }
        #expect(enteredClosing)

        await protocolServerGate.open()
        let response = await initialization.value
        await stop.value
        initializingSessionContinuation.finish()

        #expect(response.statusCode == 503)
        #expect(response.headers[HTTPHeaderName.sessionID] == nil)
        assertNoHTTPServerResources(await server.resourceSnapshotForTesting())
    }

    @Test func streamableHTTPConcurrentStopJoinsOneResourceDrain() async throws {
        let attempt = makeHTTPReviewAttempt(
            attemptID: "attempt-concurrent-stop",
            turnID: "turn-concurrent-stop"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-server-stop" })
        )
        let server = CodexReviewMCPHTTPServer(
            adapter: CodexReviewMCPServer(store: store),
            configuration: .init(host: "127.0.0.1", port: 0)
        )
        try await server.start()
        let sessionID = try await initializeSession(endpoint: await server.url)
        let running = try await beginRunningReview(store: store, sessionID: sessionID)
        try await server.registerSessionMemberForTesting(
            makeHTTPTestRunID("run-server-stop"),
            sessionID: sessionID
        )

        async let firstStop: Void = server.stop()
        async let secondStop: Void = server.stop()
        _ = await (firstStop, secondStop)

        #expect(running.presentation.status == .cancelled)
        assertNoHTTPServerResources(await server.resourceSnapshotForTesting())
    }

    @Test func streamableHTTPGlobalStopDrainsActivePostAndEventStreamWriter() async throws {
        let attempt = makeHTTPReviewAttempt(
            attemptID: "attempt-global-stop",
            turnID: "turn-global-stop"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let startGate = AsyncGate()
        await backend.holdStartReview(with: startGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-active-stop" })
        )
        let server = CodexReviewMCPHTTPServer(
            adapter: CodexReviewMCPServer(store: store),
            configuration: .init(
                host: "127.0.0.1",
                port: 0,
                streamHeartbeatInterval: .milliseconds(50)
            )
        )
        try await server.start()
        let endpoint = await server.url
        let sessionID = try await initializeSession(endpoint: endpoint)
        let requestBody = try makeJSONBody([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": [
                "name": "review_start",
                "arguments": [
                    "cwd": "/tmp/project",
                    "target": ["type": "uncommittedChanges"],
                ],
            ],
        ])
        let post = Task {
            try await postJSONRPCData(
                endpoint: endpoint,
                sessionID: sessionID,
                bodyData: requestBody
            )
        }
        await backend.waitForStartReview()
        let eventStreamOpened = AsyncGate()
        let eventStream = Task {
            try await openAndCloseRawEventStream(
                endpoint: endpoint,
                sessionID: sessionID,
                holdUntilServerCloses: true,
                opened: eventStreamOpened
            )
        }
        try await eventStreamOpened.wait()
        #expect(await server.sessionActiveRequestCountForTesting(sessionID: sessionID) == 2)
        #expect(await server.resourceSnapshotForTesting().activeRequestWorkCount == 2)

        await server.stop()
        _ = await post.result
        _ = await eventStream.result

        assertNoHTTPServerResources(await server.resourceSnapshotForTesting())
    }

    @Test func streamableHTTPClassifiesAddressInUseBindError() {
        let configuration = CodexReviewMCPHTTPServer.Configuration(
            host: "127.0.0.1",
            port: 54321
        )
        let error = IOError(errnoCode: EADDRINUSE, reason: "bind")

        let classified = CodexReviewMCPHTTPServer.Error.classifyStartError(
            error,
            configuration: configuration
        )

        #expect(
            (classified as? CodexReviewMCPHTTPServer.Error)
                == .addressInUse(
                    host: "127.0.0.1",
                    port: 54321
                ))
    }

    @Test func streamableHTTPStageFailureDrainsOwnedResources() async throws {
        let occupiedStore = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        )
        let occupiedServer = CodexReviewMCPHTTPServer(
            adapter: CodexReviewMCPServer(store: occupiedStore),
            configuration: .init(host: "127.0.0.1", port: 0)
        )
        try await occupiedServer.start()
        let occupiedPort = try #require(await occupiedServer.url.port)
        let blockedStore = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        )
        let blockedServer = CodexReviewMCPHTTPServer(
            adapter: CodexReviewMCPServer(store: blockedStore),
            configuration: .init(host: "127.0.0.1", port: occupiedPort)
        )

        do {
            try await blockedServer.stage()
            Issue.record("Expected the second MCP listener bind to fail.")
        } catch {
            #expect(
                (error as? CodexReviewMCPHTTPServer.Error)
                    == .addressInUse(host: "127.0.0.1", port: occupiedPort)
            )
        }

        await blockedServer.stop()
        assertNoHTTPServerResources(await blockedServer.resourceSnapshotForTesting())
        await occupiedServer.stop()
        assertNoHTTPServerResources(await occupiedServer.resourceSnapshotForTesting())
    }

    @Test func streamableHTTPCallsReviewStartWithCustomTarget() async throws {
        let attempt = makeHTTPReviewAttempt(
            attemptID: "attempt-custom-target",
            turnID: "turn-1"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )

        try await withHTTPServer(
            store: store,
            logProjectionProvider: { result in
                .available(ReviewMCPLogProjection(
                    result: result,
                    turnID: "turn-1",
                    threadItems: [
                        .init(
                            id: "command-1",
                            kind: .commandExecution,
                            content: .command(.init(command: "swift test", output: "passed"))
                        ),
                        .init(
                            id: "assistant-1",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "assistant-1",
                                role: .assistant,
                                text: "No issues found."
                            ))
                        ),
                    ],
                    reviewOutputText: "No issues found."
                ))
            }
        ) { server in
            let endpoint = await server.url
            let sessionID = try await initializeSession(endpoint: endpoint)
            let requestBody = try makeJSONBody([
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": [
                    "name": "review_start",
                    "arguments": [
                        "cwd": "/tmp/project",
                        "target": [
                            "type": "custom",
                            "instructions": "Focus on test coverage.",
                        ],
                    ],
                ],
            ])
            async let responseData = postJSONRPCData(
                endpoint: endpoint,
                sessionID: sessionID,
                bodyData: requestBody
            )
            await backend.yield(.completed(finalReview: "No issues found."), for: attempt)
            let resolved = try decodeSSEJSON(from: try await responseData)

            #expect(resolved.value(for: ["result", "isError"]) as? Bool == false)
            #expect(resolved.value(for: ["result", "structuredContent", "runId"]) as? String == "run-1")
            #expect(resolved.value(for: ["result", "structuredContent", "runID"]) == nil)
            #expect(resolved.value(for: ["result", "structuredContent", "logs"]) == nil)
            #expect(
                resolved.value(for: ["result", "structuredContent", "lifecycle", "status"]) as? String == "succeeded")
            #expect(
                resolved.value(for: ["result", "structuredContent", "lifecycle", "message"]) as? String
                    == "Review completed.")
            #expect(
                resolved.value(for: ["result", "structuredContent", "review", "hasFinalReview"]) as? Bool == true)
            #expect(
                resolved.value(for: ["result", "structuredContent", "review", "finalReview"]) as? String
                    == "No issues found.")
            #expect(
                resolved.value(for: ["result", "structuredContent", "review", "reviewResult", "state"]) as? String
                    == "noFindings")
            #expect(resolved.value(for: ["result", "structuredContent", "log"]) == nil)

            let read = try await postJSONRPC(
                endpoint: endpoint,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "tools/call",
                    "params": [
                        "name": "review_read",
                        "arguments": ["runId": "run-1"],
                    ],
                ]
            )
            let log = try #require(
                read.value(for: ["result", "structuredContent", "log"]) as? [String: Any]
            )
            #expect((log["items"] as? [[String: Any]])?.count == 2)
            let itemsPage = try #require(log["itemsPage"] as? [String: Any])
            #expect(itemsPage["total"] as? Int == 2)
            #expect(itemsPage["offset"] as? Int == 0)
            #expect(itemsPage["returned"] as? Int == 2)
            for removedField in [
                "revision",
                "orderedEntryIds",
                "activeEntryIds",
                "activeEntryCount",
                "latestEntryId",
                "finalLifecycleMessage",
                "finalResult",
                "truncatedFields",
            ] {
                #expect(log[removedField] == nil)
            }
            let commands = await backend.recordedCommands()
            #expect(
                commands.contains(
                    .startReview(
                        .init(
                            runID: makeHTTPTestRunID("run-1"),
                            sessionID: sessionID,
                            request: .init(
                                cwd: "/tmp/project", target: .custom(instructions: "Focus on test coverage."))
                        ))))
        }
    }

    @Test func streamableHTTPOmitsRawFindingTextFromReviewStartResult() async throws {
        let attempt = makeHTTPReviewAttempt(
            attemptID: "attempt-finding-result",
            turnID: "turn-1"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )

        let reviewOutput = """
            Review comment:

            - [P1] Pin CodexKit fallback — Package.swift:14-14
              Fresh clones can resolve a moving dependency and drift from the reviewed API.
            """
        try await withHTTPServer(
            store: store,
            logProjectionProvider: { result in
                .available(ReviewMCPLogProjection(
                    result: result,
                    turnID: "turn-1",
                    threadItems: [],
                    reviewOutputText: reviewOutput
                ))
            }
        ) { server in
            let endpoint = await server.url
            let sessionID = try await initializeSession(endpoint: endpoint)
            let requestBody = try makeJSONBody([
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": [
                    "name": "review_start",
                    "arguments": [
                        "cwd": "/tmp/project",
                        "target": ["type": "uncommittedChanges"],
                    ],
                ],
            ])
            async let responseData = postJSONRPCData(
                endpoint: endpoint,
                sessionID: sessionID,
                bodyData: requestBody
            )
            await backend.yield(.completed(finalReview: reviewOutput), for: attempt)
            let resolved = try decodeSSEJSON(from: try await responseData)

            #expect(
                resolved.value(for: ["result", "structuredContent", "review", "finalReview"]) as? String
                    != nil)
            let findings = try #require(
                resolved.value(for: ["result", "structuredContent", "review", "reviewResult", "findings"])
                    as? [[String: Any]])
            let finding = try #require(findings.first)
            #expect(finding["title"] as? String == "[P1] Pin CodexKit fallback")
            #expect(finding["body"] as? String == "Fresh clones can resolve a moving dependency and drift from the reviewed API.")
            #expect(finding["location"] != nil)
            #expect(finding["rawText"] == nil)
        }
    }

    @Test func streamableHTTPBoundsClaudeReviewStartAndContinuesWithReviewAwait() async throws {
        let attempt = makeHTTPReviewAttempt(
            attemptID: "attempt-bounded-start",
            turnID: "turn-1"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        let configuration = CodexReviewMCPHTTPServer.Configuration(
            port: 0,
            streamHeartbeatInterval: nil,
            boundedReviewWaitDuration: .milliseconds(50)
        )

        try await withHTTPServer(
            store: store,
            configuration: configuration,
            logProjectionProvider: { result in
                .available(ReviewMCPLogProjection(
                    result: result,
                    turnID: "turn-1",
                    threadItems: [
                        .init(
                            id: "command-1",
                            kind: .commandExecution,
                            content: .command(.init(command: "git diff", output: "diff"))
                        ),
                    ],
                    reviewOutputText: result.presentation.status == .succeeded
                        ? "No issues found."
                        : nil
                ))
            }
        ) { server in
            let endpoint = await server.url
            let sessionID = try await initializeSession(endpoint: endpoint, clientName: "Claude Code")
            let requestBody = try makeJSONBody([
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": [
                    "name": "review_start",
                    "arguments": [
                        "cwd": "/tmp/project",
                        "target": ["type": "uncommittedChanges"],
                    ],
                ],
            ])
            async let responseData = postJSONRPCData(
                endpoint: endpoint,
                sessionID: sessionID,
                bodyData: requestBody
            )
            let running = try decodeSSEJSON(from: try await responseData)

            #expect(running.value(for: ["result", "isError"]) as? Bool == false)
            #expect(running.value(for: ["result", "structuredContent", "runId"]) as? String == "run-1")
            #expect(running.value(for: ["result", "structuredContent", "lifecycle", "status"]) as? String == "running")
            #expect(running.value(for: ["result", "structuredContent", "logs"]) == nil)
            #expect(running.value(for: ["result", "structuredContent", "rawLogText"]) == nil)
            #expect(running.value(for: ["result", "structuredContent", "log"]) == nil)
            #expect(
                running.value(for: ["result", "structuredContent", "nextAction", "tool"]) as? String == "review_await")

            await backend.yield(.completed(finalReview: "No issues found."), for: attempt)
            let awaited = try await postJSONRPC(
                endpoint: endpoint,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "tools/call",
                    "params": [
                        "name": "review_await",
                        "arguments": [
                            "runId": "run-1"
                        ],
                    ],
                ]
            )

            #expect(awaited.value(for: ["result", "isError"]) as? Bool == false)
            #expect(
                awaited.value(for: ["result", "structuredContent", "lifecycle", "status"]) as? String == "succeeded")
            #expect(
                awaited.value(for: ["result", "structuredContent", "lifecycle", "message"]) as? String
                    == "Review completed.")
            #expect(
                awaited.value(for: ["result", "structuredContent", "review", "hasFinalReview"]) as? Bool == true)
            #expect(
                awaited.value(for: ["result", "structuredContent", "review", "finalReview"]) as? String
                    == "No issues found.")
            #expect(
                awaited.value(for: ["result", "structuredContent", "review", "reviewResult", "state"]) as? String
                    == "noFindings")
            #expect(awaited.value(for: ["result", "structuredContent", "log"]) == nil)
            #expect(awaited.value(for: ["result", "structuredContent", "logs"]) == nil)
        }
    }

    @Test func streamableHTTPBindsReviewStartToTransportSessionWhenArgumentIsOmitted() async throws {
        let attempt = makeHTTPReviewAttempt(
            attemptID: "attempt-session-binding",
            turnID: "turn-1"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )

        try await withHTTPServer(
            store: store,
            logProjectionProvider: { result in
                guard let attempt = result.core.attempt else {
                    return .unavailable
                }
                return .available(ReviewMCPLogProjection(
                    result: result,
                    turnID: .init(rawValue: attempt.turnID.rawValue),
                    threadItems: [],
                    reviewOutputText: result.presentation.status == .succeeded
                        ? "Done"
                        : nil
                ))
            }
        ) { server in
            let endpoint = await server.url
            let sessionID = try await initializeSession(endpoint: endpoint)
            let requestBody = try makeJSONBody([
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": [
                    "name": "review_start",
                    "arguments": [
                        "cwd": "/tmp/project",
                        "target": [
                            "type": "custom",
                            "instructions": "Focus on test coverage.",
                        ],
                    ],
                ],
            ])
            async let responseData = postJSONRPCData(
                endpoint: endpoint,
                sessionID: sessionID,
                bodyData: requestBody
            )
            await backend.yield(.completed(finalReview: "No issues found."), for: attempt)
            let resolved = try decodeSSEJSON(from: try await responseData)

            #expect(resolved.value(for: ["result", "structuredContent", "runId"]) as? String == "run-1")
            let commands = await backend.recordedCommands()
            #expect(
                commands.contains(
                    .startReview(
                        .init(
                            runID: makeHTTPTestRunID("run-1"),
                            sessionID: sessionID,
                            request: .init(
                                cwd: "/tmp/project", target: .custom(instructions: "Focus on test coverage."))
                        ))))
        }
    }

    @Test func streamableHTTPRejectsCallerSuppliedSessionSelector() async throws {
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let response = try await postJSONRPC(
                endpoint: await server.url,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/call",
                    "params": [
                        "name": "review_list",
                        "arguments": ["sessionID": "other-session"],
                    ],
                ]
            )

            #expect(response.value(for: ["result", "isError"]) as? Bool == true)
            let content = response.value(for: ["result", "content"]) as? [[String: Any]]
            #expect((content?.first?["text"] as? String)?.contains("active MCP transport session") == true)
        }
    }

    @Test func streamableHTTPReportsFailedReviewStartAsToolError() async throws {
        let attempt = makeHTTPReviewAttempt(
            attemptID: "attempt-failed-start",
            turnID: "turn-1"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )

        try await withHTTPServer(store: store) { server in
            let endpoint = await server.url
            let sessionID = try await initializeSession(endpoint: endpoint)
            let requestBody = try makeJSONBody([
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": [
                    "name": "review_start",
                    "arguments": [
                        "cwd": "/tmp/project",
                        "target": ["type": "uncommittedChanges"],
                    ],
                ],
            ])
            async let responseData = postJSONRPCData(
                endpoint: endpoint,
                sessionID: sessionID,
                bodyData: requestBody
            )
            await backend.yield(
                .failed(
                    .turnFailed(
                        .init(
                            message: "Backend failed",
                            code: .httpConnectionFailed(status: 503),
                            additionalDetails: "Retry later"
                        )
                    )
                ),
                for: attempt
            )
            let resolved = try decodeSSEJSON(from: try await responseData)

            #expect(resolved.value(for: ["result", "isError"]) as? Bool == true)
            #expect(resolved.value(for: ["result", "structuredContent", "runId"]) as? String == "run-1")
            #expect(resolved.value(for: ["result", "structuredContent", "lifecycle", "status"]) as? String == "failed")
            #expect(
                resolved.value(for: [
                    "result", "structuredContent", "lifecycle", "failure", "kind",
                ]) as? String == "turnFailed"
            )
            #expect(
                resolved.value(for: [
                    "result", "structuredContent", "lifecycle", "failure",
                    "turnFailure", "code", "name",
                ]) as? String == "httpConnectionFailed"
            )
            #expect(
                resolved.value(for: [
                    "result", "structuredContent", "lifecycle", "failure",
                    "turnFailure", "code", "status",
                ]) as? Int == 503
            )
            #expect(
                resolved.value(for: [
                    "result", "structuredContent", "lifecycle", "failure",
                    "turnFailure", "additionalDetails",
                ]) as? String == "Retry later"
            )
        }
    }

    @Test func streamableHTTPFiltersReviewListBySessionAndCWD() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let included = ReviewRunRecord.makeForTesting(
                id: "run-included",
                sessionID: sessionID,
                cwd: "/tmp/project",
                targetSummary: "Uncommitted changes",
                attemptID: "attempt-included",
                threadID: "thread-included",
                turnID: "turn-included",
                status: .succeeded,
                startedAt: Date(timeIntervalSince1970: 1_000),
                endedAt: Date(timeIntervalSince1970: 1_001),
                summary: "Done"
            )
            let otherSession = ReviewRunRecord.makeForTesting(
                id: "run-other-session",
                sessionID: "other-session",
                cwd: "/tmp/project",
                targetSummary: "Uncommitted changes",
                attemptID: "attempt-other-session",
                threadID: "thread-other-session",
                turnID: "turn-other-session",
                status: .succeeded,
                startedAt: Date(timeIntervalSince1970: 1_000),
                endedAt: Date(timeIntervalSince1970: 1_001),
                summary: "Done"
            )
            let otherWorkspace = ReviewRunRecord.makeForTesting(
                id: "run-other-workspace",
                sessionID: sessionID,
                cwd: "/tmp/other",
                targetSummary: "Uncommitted changes",
                attemptID: "attempt-other-workspace",
                threadID: "thread-other-workspace",
                turnID: "turn-other-workspace",
                status: .succeeded,
                startedAt: Date(timeIntervalSince1970: 1_000),
                endedAt: Date(timeIntervalSince1970: 1_001),
                summary: "Done"
            )
            store.loadForTesting(
                serverState: .running,
                reviewRuns: [included, otherSession, otherWorkspace]
            )
            try await server.registerSessionMemberForTesting(
                makeHTTPTestRunID("run-included"),
                sessionID: sessionID
            )
            try await server.registerSessionMemberForTesting(
                makeHTTPTestRunID("run-other-workspace"),
                sessionID: sessionID
            )
            let response = try await postJSONRPC(
                endpoint: await server.url,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/call",
                    "params": [
                        "name": "review_list",
                        "arguments": [
                            "cwd": "/tmp/project",
                            "statuses": ["succeeded"],
                        ],
                    ],
                ]
            )

            let items = try #require(response.value(for: ["result", "structuredContent", "items"]) as? [[String: Any]])
            #expect(items.compactMap { $0["runId"] as? String } == ["run-included"])
        }
    }

    @Test func streamableHTTPScopesReviewReadToTransportSession() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(
            store: store,
            logProjectionProvider: { result in
                guard let attempt = result.core.attempt else {
                    return .unavailable
                }
                return .available(ReviewMCPLogProjection(
                    result: result,
                    turnID: .init(rawValue: attempt.turnID.rawValue),
                    threadItems: [],
                    reviewOutputText: result.presentation.status == .succeeded
                        ? "Done"
                        : nil
                ))
            }
        ) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let includedRun = ReviewRunRecord.makeForTesting(
                id: "run-in-session",
                sessionID: sessionID,
                cwd: "/tmp/project",
                targetSummary: "Included",
                attemptID: "attempt-in-session",
                threadID: "thread-in-session",
                turnID: "turn-in-session",
                status: .succeeded,
                startedAt: Date(timeIntervalSince1970: 1_000),
                endedAt: Date(timeIntervalSince1970: 1_001),
                summary: "Done"
            )
            store.loadForTesting(
                serverState: .running,
                reviewRuns: [
                    includedRun,
                    ReviewRunRecord.makeForTesting(
                        id: "run-other-session",
                        sessionID: "other-session",
                        cwd: "/tmp/project",
                        targetSummary: "Other",
                        attemptID: "attempt-other-session",
                        threadID: "thread-other-session",
                        turnID: "turn-other-session",
                        status: .succeeded,
                        startedAt: Date(timeIntervalSince1970: 1_000),
                        endedAt: Date(timeIntervalSince1970: 1_001),
                        summary: "Done"
                    ),
                ]
            )
            try await server.registerSessionMemberForTesting(
                makeHTTPTestRunID("run-in-session"),
                sessionID: sessionID
            )

            let allowed = try await postJSONRPC(
                endpoint: await server.url,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/call",
                    "params": [
                        "name": "review_read",
                        "arguments": ["jobId": "run-in-session"],
                    ],
                ]
            )
            let denied = try await postJSONRPC(
                endpoint: await server.url,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "tools/call",
                    "params": [
                        "name": "review_read",
                        "arguments": ["jobID": "run-other-session"],
                    ],
                ]
            )
            #expect(allowed.value(for: ["result", "isError"]) as? Bool == false)
            #expect(allowed.value(for: ["result", "structuredContent", "runId"]) as? String == "run-in-session")
            #expect(allowed.value(for: ["result", "structuredContent", "logs"]) == nil)
            #expect(allowed.value(for: ["result", "structuredContent", "logsPage"]) == nil)
            let readText = (allowed.value(for: ["result", "content"]) as? [[String: Any]])?.first?["text"] as? String
            #expect(readText == "Done")
            #expect(readText?.contains("rawLogText") == false)
            #expect(denied.value(for: ["result", "isError"]) as? Bool == true)
            #expect(
                (denied.value(for: ["result", "content"]) as? [[String: Any]])?.first?["text"] as? String
                    == "Run run-other-session was not found.")
        }
    }

    @Test func streamableHTTPRejectsConflictingRunIdentifierAliases() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let response = try await postJSONRPC(
                endpoint: await server.url,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/call",
                    "params": [
                        "name": "review_read",
                        "arguments": [
                            "runId": "run-1",
                            "jobId": "run-2",
                        ],
                    ],
                ]
            )

            #expect(response.value(for: ["result", "isError"]) as? Bool == true)
            let errorText =
                (response.value(for: ["result", "content"]) as? [[String: Any]])?.first?["text"]
                    as? String
            #expect(errorText == "Conflicting run identifier arguments: runId and jobId.")
        }
    }

    @Test func streamableHTTPRejectsSucceededReviewWithoutChatProjection() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let runRecord = ReviewRunRecord.makeForTesting(
                id: "run-semantic",
                sessionID: sessionID,
                cwd: "/tmp/project",
                targetSummary: "Included",
                attemptID: "attempt-semantic",
                threadID: "thread-semantic",
                turnID: "turn-semantic",
                status: .succeeded,
                startedAt: Date(timeIntervalSince1970: 1_000),
                endedAt: Date(timeIntervalSince1970: 1_001),
                summary: "Done"
            )
            store.loadForTesting(
                serverState: .running,
                reviewRuns: [runRecord]
            )
            try await server.registerSessionMemberForTesting(
                makeHTTPTestRunID("run-semantic"),
                sessionID: sessionID
            )

            let defaultResponse = try await postJSONRPC(
                endpoint: await server.url,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/call",
                    "params": [
                        "name": "review_read",
                        "arguments": [
                            "runId": "run-semantic"
                        ],
                    ],
                ]
            )

            #expect(defaultResponse.value(for: ["result", "isError"]) as? Bool == true)
            #expect(defaultResponse.value(for: ["result", "structuredContent"]) == nil)
            let errorText = (defaultResponse.value(for: ["result", "content"]) as? [[String: Any]])?
                .first?["text"] as? String
            #expect(errorText == "Review output projection invariant failed for run run-semantic.")
        }
    }

    @Test func streamableHTTPReviewReadDoesNotProjectRunningSummaryAsLogContent() async throws {
        let attempt = makeHTTPReviewAttempt(
            attemptID: "attempt-running-summary",
            turnID: "turn-running-summary"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-tool-progress" })
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            _ = try await beginRunningReview(store: store, sessionID: sessionID)
            try await server.registerSessionMemberForTesting(
                makeHTTPTestRunID("run-tool-progress"),
                sessionID: sessionID
            )

            let response = try await postJSONRPC(
                endpoint: await server.url,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/call",
                    "params": [
                        "name": "review_read",
                        "arguments": [
                            "runId": "run-tool-progress"
                        ],
                    ],
                ]
            )

            let log = try #require(
                response.value(for: ["result", "structuredContent", "log"]) as? [String: Any])
            let items = try #require(log["items"] as? [[String: Any]])
            #expect(items.isEmpty)
            #expect(log["revision"] == nil)
            #expect(log["orderedEntryIds"] == nil)
            #expect(log["activeEntryIds"] == nil)
            #expect(log["activeEntryCount"] == nil)
        }
    }

    @Test func streamableHTTPCancelsReviewByTransportScopedSelector() async throws {
        let attempt = makeReviewAttemptForTesting(
            attemptID: "attempt-1",
            sourceThreadID: "thread-1",
            activeTurnThreadID: "thread-1",
            turnID: "turn-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let runIDs = Mutex(["run-running", "run-other-session"])
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: {
                runIDs.withLock { runIDs in
                    precondition(runIDs.isEmpty == false)
                    return runIDs.removeFirst()
                }
            })
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let running = try await beginRunningReview(store: store, sessionID: sessionID)
            let startGate = AsyncGate()
            await backend.holdStartReview(with: startGate)
            await backend.planNextAttempt(makeHTTPReviewAttempt(
                attemptID: "attempt-other-session",
                turnID: "turn-other-session"
            ))
            let otherRunID = try await store.beginReview(
                sessionID: "other-session",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            let otherSession = try #require(store.reviewRun(id: otherRunID))
            try await server.registerSessionMemberForTesting(
                makeHTTPTestRunID("run-running"),
                sessionID: sessionID
            )
            let response = try await postJSONRPC(
                endpoint: await server.url,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/call",
                    "params": [
                        "name": "review_cancel",
                        "arguments": [
                            "cwd": "/tmp/project",
                            "statuses": ["queued", "running"],
                            "reason": "Stop from MCP",
                        ],
                    ],
                ]
            )

            #expect(response.value(for: ["result", "structuredContent", "runId"]) as? String == "run-running")
            #expect(response.value(for: ["result", "structuredContent", "cancelled"]) as? Bool == true)
            #expect(running.presentation.status == .cancelled)
            #expect(running.core.cancellation?.message == "Stop from MCP")
            #expect(otherSession.cancellationRequested == false)
            let commands = await backend.recordedCommands()
            #expect(
                commands.contains(
                    .interruptReview(
                        makeReviewAttemptForTesting(
                            attemptID: "attempt-1",
                            sourceThreadID: "thread-1",
                            activeTurnThreadID: "thread-1",
                            turnID: "turn-1",
                            model: "gpt-5"
                        ),
                        .init(message: "Stop from MCP")
                    )))
            let closeResult = await store.closeSession("other-session")
            #expect(closeResult.terminalAndDrainedRunIDs == [otherRunID])
            store.releaseClosedSession("other-session")
        }
    }

    @Test func streamableHTTPCancelDefaultsSelectorToActiveRunsInTransportSession() async throws {
        let attempt = makeHTTPReviewAttempt(
            attemptID: "attempt-default-cancel-selector",
            turnID: "turn-default-cancel-selector"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-running" })
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let completed = ReviewRunRecord.makeForTesting(
                id: "run-completed",
                sessionID: sessionID,
                cwd: "/tmp/project",
                targetSummary: "Completed",
                attemptID: "attempt-completed",
                threadID: "thread-completed",
                turnID: "turn-completed",
                status: .succeeded,
                startedAt: Date(timeIntervalSince1970: 1_000),
                endedAt: Date(timeIntervalSince1970: 1_001),
                summary: "Done"
            )
            store.loadForTesting(
                serverState: .running,
                reviewRuns: [completed]
            )
            let running = try await beginRunningReview(store: store, sessionID: sessionID)
            try await server.registerSessionMemberForTesting(
                makeHTTPTestRunID("run-completed"),
                sessionID: sessionID
            )
            try await server.registerSessionMemberForTesting(
                makeHTTPTestRunID("run-running"),
                sessionID: sessionID
            )

            let response = try await postJSONRPC(
                endpoint: await server.url,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/call",
                    "params": [
                        "name": "review_cancel",
                        "arguments": [
                            "cwd": "/tmp/project",
                            "reason": "Stop from MCP",
                        ],
                    ],
                ]
            )

            #expect(response.value(for: ["result", "structuredContent", "runId"]) as? String == "run-running")
            #expect(response.value(for: ["result", "structuredContent", "cancelled"]) as? Bool == true)
            #expect(completed.presentation.status == .succeeded)
            #expect(running.presentation.status == .cancelled)
        }
    }

    @Test func streamableHTTPReportsAmbiguousCancelSelectorCandidates() async throws {
        let firstAttempt = makeHTTPReviewAttempt(
            attemptID: "attempt-ambiguous-first",
            turnID: "turn-ambiguous-first"
        )
        let secondAttempt = makeHTTPReviewAttempt(
            attemptID: "attempt-ambiguous-second",
            turnID: "turn-ambiguous-second"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: firstAttempt)
        let startGate = AsyncGate()
        await backend.holdStartReview(with: startGate)
        let runIDs = Mutex(["run-running-1", "run-running-2"])
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: {
                runIDs.withLock { runIDs in
                    precondition(runIDs.isEmpty == false)
                    return runIDs.removeFirst()
                }
            })
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let firstRunID = try await store.beginReview(
                sessionID: sessionID,
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.waitForStartReview()
            await backend.planNextAttempt(secondAttempt)
            let secondRunID = try await store.beginReview(
                sessionID: sessionID,
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            #expect(firstRunID.rawValue == "run-running-1")
            #expect(secondRunID.rawValue == "run-running-2")
            try await server.registerSessionMemberForTesting(
                makeHTTPTestRunID("run-running-1"),
                sessionID: sessionID
            )
            try await server.registerSessionMemberForTesting(
                makeHTTPTestRunID("run-running-2"),
                sessionID: sessionID
            )

            let response = try await postJSONRPC(
                endpoint: await server.url,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/call",
                    "params": [
                        "name": "review_cancel",
                        "arguments": [
                            "cwd": "/tmp/project",
                            "reason": "Stop from MCP",
                        ],
                    ],
                ]
            )
            let text = (response.value(for: ["result", "content"]) as? [[String: Any]])?.first?["text"] as? String

            #expect(response.value(for: ["result", "isError"]) as? Bool == true)
            #expect(text?.contains("matched multiple review runs") == true)
            #expect(text?.contains("run-running-1") == true)
            #expect(text?.contains("run-running-2") == true)
        }
    }

    @Test func streamableHTTPCancelsDocumentedRunId() async throws {
        let attempt = makeHTTPReviewAttempt(
            attemptID: "attempt-documented-run-id",
            turnID: "turn-documented-run-id"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-running" })
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let running = try await beginRunningReview(store: store, sessionID: sessionID)
            try await server.registerSessionMemberForTesting(
                makeHTTPTestRunID("run-running"),
                sessionID: sessionID
            )

            let response = try await postJSONRPC(
                endpoint: await server.url,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/call",
                    "params": [
                        "name": "review_cancel",
                        "arguments": [
                            "runId": "run-running",
                            "reason": "Stop from MCP",
                        ],
                    ],
                ]
            )

            #expect(response.value(for: ["result", "structuredContent", "runId"]) as? String == "run-running")
            #expect(running.presentation.status == .cancelled)
        }
    }

    @Test func streamableHTTPMeasuresIdleWindowWithInjectedMonotonicClock() async throws {
        let clock = ManualMCPHTTPServerClock()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        )

        try await withHTTPServer(
            store: store,
            configuration: .init(
                port: 0,
                sessionTimeout: .seconds(10),
                sessionCleanupInterval: .seconds(1),
                sessionClock: clock.clock
            )
        ) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)

            try await clock.waitForSleeperCount(1)
            clock.advance(by: .seconds(10))
            try await clock.waitForSleeperCount(1)
            #expect(await server.sessionActiveRequestCountForTesting(sessionID: sessionID) == 0)

            clock.advance(by: .seconds(1))
            try await clock.waitForSleeperCount(1)
            #expect(await server.sessionActiveRequestCountForTesting(sessionID: sessionID) == nil)
        }
    }

    @Test func streamableHTTPDoesNotExpireSessionWithActiveReviewRequest() async throws {
        let attempt = makeHTTPReviewAttempt(
            attemptID: "attempt-active-request",
            turnID: "turn-1"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let gate = AsyncGate()
        let clock = ManualMCPHTTPServerClock()
        await backend.holdStartReview(with: gate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )

        try await withHTTPServer(
            store: store,
            configuration: .init(
                port: 0,
                sessionTimeout: .seconds(1),
                sessionCleanupInterval: .seconds(1),
                sessionClock: clock.clock
            ),
            logProjectionProvider: { result in
                .available(ReviewMCPLogProjection(
                    result: result,
                    turnID: "turn-1",
                    threadItems: [],
                    reviewOutputText: result.presentation.status == .succeeded
                        ? "No issues found."
                        : nil
                ))
            }
        ) { server in
            let endpoint = await server.url
            let sessionID = try await initializeSession(endpoint: endpoint)
            let requestBody = try makeJSONBody([
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": [
                    "name": "review_start",
                    "arguments": [
                        "cwd": "/tmp/project",
                        "target": ["type": "uncommittedChanges"],
                    ],
                ],
            ])

            async let responseData = postJSONRPCData(
                endpoint: endpoint,
                sessionID: sessionID,
                bodyData: requestBody
            )
            await backend.waitForStartReview()
            try await clock.waitForSleeperCount(1)
            clock.advance(by: .seconds(2))
            try await clock.waitForSleeperCount(1)

            let runningList = try await postJSONRPC(
                endpoint: endpoint,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "tools/call",
                    "params": [
                        "name": "review_list",
                        "arguments": [
                            "cwd": "/tmp/project",
                            "statuses": ["queued", "running"],
                        ],
                    ],
                ]
            )
            let runningItems = try #require(
                runningList.value(for: ["result", "structuredContent", "items"])
                    as? [[String: Any]]
            )
            #expect(runningItems.compactMap { $0["runId"] as? String } == ["run-1"])

            await gate.open()
            await backend.yield(.completed(finalReview: "No issues found."), for: attempt)
            let resolved = try decodeSSEJSON(from: try await responseData)

            #expect(resolved.value(for: ["result", "structuredContent", "runId"]) as? String == "run-1")
            #expect(resolved.value(for: ["result", "structuredContent", "logs"]) == nil)
            #expect(resolved.value(for: ["result", "structuredContent", "rawLogText"]) == nil)
            let startText = (resolved.value(for: ["result", "content"]) as? [[String: Any]])?.first?["text"] as? String
            #expect(startText == "No issues found.")
            #expect(startText?.contains("rawLogText") == false)
            let tools = try await postJSONRPC(
                endpoint: endpoint,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 4,
                    "method": "tools/list",
                ]
            )
            #expect((tools.value(for: ["result", "tools"]) as? [[String: Any]])?.isEmpty == false)
        }
    }

    @Test func streamableHTTPDoesNotExpireSessionWithOpenEventStream() async throws {
        let backend = FakeCodexReviewBackend()
        let clock = ManualMCPHTTPServerClock()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(
            store: store,
            configuration: .init(
                port: 0,
                sessionTimeout: .seconds(1),
                sessionCleanupInterval: .seconds(1),
                sessionClock: clock.clock
            )
        ) { server in
            let endpoint = await server.url
            let sessionID = try await initializeSession(endpoint: endpoint)
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
            request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let httpResponse = try #require(response as? HTTPURLResponse)
            #expect(httpResponse.statusCode == 200)

            try await clock.waitForSleeperCount(1)
            clock.advance(by: .seconds(2))
            try await clock.waitForSleeperCount(1)

            let tools = try await postJSONRPC(
                endpoint: endpoint,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "tools/list",
                ]
            )
            #expect((tools.value(for: ["result", "tools"]) as? [[String: Any]])?.isEmpty == false)
            withExtendedLifetime(bytes) {}
        }
    }

    @Test func streamableHTTPExpiresSessionAfterEventStreamDisconnects() async throws {
        let backend = FakeCodexReviewBackend()
        let clock = ManualMCPHTTPServerClock()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(
            store: store,
            configuration: .init(
                host: "127.0.0.1",
                port: 0,
                sessionTimeout: .seconds(1),
                sessionCleanupInterval: .seconds(1),
                streamHeartbeatInterval: .milliseconds(50),
                sessionClock: clock.clock
            )
        ) { server in
            let endpoint = await server.url
            let sessionID = try await initializeSession(endpoint: endpoint)

            try await openAndCloseRawEventStream(endpoint: endpoint, sessionID: sessionID)
            let streamReleased = await waitUntil(timeout: .seconds(2)) {
                await server.sessionActiveRequestCountForTesting(sessionID: sessionID) == 0
            }
            #expect(streamReleased)

            try await clock.waitForSleeperCount(1)
            clock.advance(by: .seconds(2))
            try await clock.waitForSleeperCount(1)
            #expect(await server.sessionActiveRequestCountForTesting(sessionID: sessionID) == nil)
        }
    }

    @Test func streamableHTTPKeepsRunIDCancellationInTransportSession() async throws {
        let attempt = makeHTTPReviewAttempt(
            attemptID: "attempt-run-id-cancellation",
            turnID: "turn-run-id-cancellation"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-other-session" })
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let other = try await beginRunningReview(
                store: store,
                sessionID: "other-session"
            )

            let response = try await postJSONRPC(
                endpoint: await server.url,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/call",
                    "params": [
                        "name": "review_cancel",
                        "arguments": [
                            "runID": "run-other-session",
                            "reason": "Stop from MCP",
                        ],
                    ],
                ]
            )

            #expect(response.value(for: ["result", "isError"]) as? Bool == true)
            #expect(other.presentation.status == .running)
            let closeResult = await store.closeSession("other-session")
            #expect(closeResult.terminalAndDrainedRunIDs == [other.id])
            store.releaseClosedSession("other-session")
        }
    }

    @Test func streamableHTTPDeleteFinishesItsRequestBeforeClosingStoreSession() async throws {
        let attempt = makeHTTPReviewAttempt(
            attemptID: "attempt-delete-close",
            turnID: "turn-delete-close"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-running" })
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let running = try await beginRunningReview(store: store, sessionID: sessionID)
            try await server.registerSessionMemberForTesting(
                makeHTTPTestRunID("run-running"),
                sessionID: sessionID
            )

            let response = try await deleteSession(endpoint: await server.url, sessionID: sessionID)

            #expect(response.statusCode == 200)
            #expect(running.presentation.status == .cancelled)
            let staleSessionResponse = try await postJSONRPCStatus(
                endpoint: await server.url,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "tools/list",
                ]
            )
            #expect(staleSessionResponse.statusCode == 404)
        }
    }

    @Test func streamableHTTPListsAndReadsDiscoveryResources() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let listed = try await postJSONRPC(
                endpoint: await server.url,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "resources/list",
                ]
            )
            let resources = try #require(listed.value(for: ["result", "resources"]) as? [[String: Any]])
            #expect(resources.compactMap { $0["uri"] as? String }.contains("codex-review://help/targets/custom"))

            let read = try await postJSONRPC(
                endpoint: await server.url,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "resources/read",
                    "params": [
                        "uri": "codex-review://help/targets/custom"
                    ],
                ]
            )
            let contents = try #require(read.value(for: ["result", "contents"]) as? [[String: Any]])
            #expect((contents.first?["text"] as? String)?.contains("instructions") == true)
        }
    }

    @Test func streamableHTTPListsResourceTemplates() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let response = try await postJSONRPC(
                endpoint: await server.url,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "resources/templates/list",
                ]
            )
            let templates = try #require(response.value(for: ["result", "resourceTemplates"]) as? [[String: Any]])
            #expect(
                templates.compactMap { $0["uriTemplate"] as? String } == [
                    "codex-review://help/tools/{tool}",
                    "codex-review://help/targets/{target}",
                ])
        }
    }

    private func beginRunningReview(
        store: CodexReviewStore,
        sessionID: String,
        cwd: String = "/tmp/project"
    ) async throws -> ReviewRunRecord {
        let runID = try await store.beginReview(
            sessionID: sessionID,
            request: .init(cwd: cwd, target: .uncommittedChanges)
        )
        try #require(
            await StoreSnapshotProbe(store: store).waitUntilRunStatus(
                .running,
                runID: runID.rawValue
            ) != nil
        )
        return try #require(store.reviewRun(id: runID))
    }

    private func assertNoHTTPServerResources(
        _ snapshot: CodexReviewMCPHTTPServer.ResourceSnapshot,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(snapshot.listenerCount == 0, sourceLocation: sourceLocation)
        #expect(snapshot.eventLoopGroupCount == 0, sourceLocation: sourceLocation)
        #expect(snapshot.sessionCount == 0, sourceLocation: sourceLocation)
        #expect(snapshot.registrySessionCount == 0, sourceLocation: sourceLocation)
        #expect(snapshot.cleanupTaskCount == 0, sourceLocation: sourceLocation)
        #expect(snapshot.requestPumpTaskCount == 0, sourceLocation: sourceLocation)
        #expect(snapshot.activeRequestWorkCount == 0, sourceLocation: sourceLocation)
        #expect(snapshot.childChannelCount == 0, sourceLocation: sourceLocation)
    }

    private func withHTTPServer<T>(
        store: CodexReviewStore,
        configuration: CodexReviewMCPHTTPServer.Configuration = .init(port: 0),
        logProjectionProvider: ReviewMCPLogProjectionProvider? = nil,
        operation: (CodexReviewMCPHTTPServer) async throws -> T
    ) async throws -> T {
        let adapter = CodexReviewMCPServer(
            store: store,
            logProjectionProvider: logProjectionProvider
        )
        let server = CodexReviewMCPHTTPServer(
            adapter: adapter,
            configuration: configuration
        )

        try await server.start()
        do {
            let result = try await operation(server)
            await server.stop()
            assertNoHTTPServerResources(await server.resourceSnapshotForTesting())
            return result
        } catch {
            await server.stop()
            assertNoHTTPServerResources(await server.resourceSnapshotForTesting())
            throw error
        }
    }

    private func initializeSession(
        endpoint: URL,
        clientName: String = "CodexReviewKitTests"
    ) async throws -> String {
        let (_, response) = try await postJSONRPCResponse(
            endpoint: endpoint,
            sessionID: nil,
            body: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "protocolVersion": "2025-11-25",
                    "capabilities": [:],
                    "clientInfo": [
                        "name": clientName,
                        "version": "0.0.0",
                    ],
                ],
            ]
        )
        return try #require(response.value(forHTTPHeaderField: "MCP-Session-Id"))
    }

    private func postJSONRPC(
        endpoint: URL,
        sessionID: String?,
        body: [String: Any]
    ) async throws -> [String: Any] {
        let (data, _) = try await postJSONRPCResponse(
            endpoint: endpoint,
            sessionID: sessionID,
            body: body
        )
        return try decodeSSEJSON(from: data)
    }

    private func makeJSONBody(_ body: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: body)
    }

    private nonisolated func postJSONRPCData(
        endpoint: URL,
        sessionID: String?,
        bodyData: Data
    ) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
        }
        request.httpBody = bodyData
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)
        return data
    }

    private nonisolated func openAndCloseRawEventStream(
        endpoint: URL,
        sessionID: String,
        holdUntilServerCloses: Bool = false,
        opened: AsyncGate? = nil
    ) async throws {
        try await Task.detached {
            let components = try #require(URLComponents(url: endpoint, resolvingAgainstBaseURL: false))
            let host = try #require(components.host)
            let port = try #require(components.port)
            let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                throw currentPOSIXError()
            }
            defer {
                Darwin.close(descriptor)
            }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port).bigEndian
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
                throw testError("Unable to resolve IPv4 loopback host \(host)")
            }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else {
                throw currentPOSIXError()
            }

            let request = """
                GET \(endpoint.path) HTTP/1.1\r
                Host: \(host):\(port)\r
                Accept: text/event-stream, application/json\r
                MCP-Session-Id: \(sessionID)\r
                Connection: close\r
                \r

                """
            let bytes = Array(request.utf8)
            try bytes.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else {
                    throw testError("Empty HTTP request")
                }
                var sent = 0
                while sent < rawBuffer.count {
                    let count = Darwin.send(
                        descriptor,
                        baseAddress.advanced(by: sent),
                        rawBuffer.count - sent,
                        0
                    )
                    guard count > 0 else {
                        throw currentPOSIXError()
                    }
                    sent += count
                }
            }

            var response = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while String(decoding: response, as: UTF8.self).contains("\r\n\r\n") == false {
                let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
                guard count > 0 else {
                    throw currentPOSIXError()
                }
                response.append(contentsOf: buffer.prefix(count))
                guard response.count < 8192 else {
                    throw testError("HTTP response headers did not terminate")
                }
            }

            let responseText = String(decoding: response, as: UTF8.self)
            guard responseText.contains(" 200 ") else {
                throw testError("Unexpected HTTP response: \(responseText)")
            }
            await opened?.open()
            if holdUntilServerCloses {
                while true {
                    let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
                    if count == 0 {
                        return
                    }
                    if count < 0 {
                        guard errno == ECONNRESET else {
                            throw currentPOSIXError()
                        }
                        return
                    }
                }
            }
            Darwin.shutdown(descriptor, SHUT_RDWR)
        }.value
    }

    private func postJSONRPCResponse(
        endpoint: URL,
        sessionID: String?,
        body: [String: Any]
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)
        return (data, httpResponse)
    }

    private nonisolated func postJSONRPCStatus(
        endpoint: URL,
        sessionID: String,
        body: [String: Any]
    ) async throws -> HTTPURLResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        return try #require(response as? HTTPURLResponse)
    }

    private nonisolated func deleteSession(endpoint: URL, sessionID: String) async throws -> HTTPURLResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
        let (_, response) = try await URLSession.shared.data(for: request)
        return try #require(response as? HTTPURLResponse)
    }

    private func decodeSSEJSON(from data: Data) throws -> [String: Any] {
        let text = String(decoding: data, as: UTF8.self)
        let payload = try #require(
            text
                .split(separator: "\n")
                .compactMap { line -> String? in
                    guard line.hasPrefix("data: ") else {
                        return nil
                    }
                    let value = line.dropFirst("data: ".count)
                    return value.isEmpty ? nil : String(value)
                }
                .last)
        let jsonData = Data(payload.utf8)
        return try #require(JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
    }

    private func waitUntil(
        timeout: Duration,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while await condition() == false {
            if clock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }
}

private final class ManualMCPHTTPServerClock: Sendable {
    private struct Sleeper {
        let deadline: MCPHTTPServerClock.Instant
        let continuation:
            CheckedContinuation<Result<Void, CancellationError>, Never>
    }

    private struct SleeperCountWaiter {
        let count: Int
        let continuation:
            CheckedContinuation<Result<Void, CancellationError>, Never>
    }

    private struct State {
        var now = MCPHTTPServerClock.Instant.zero
        var sleepers: [UUID: Sleeper] = [:]
        var sleeperCountWaiters: [UUID: SleeperCountWaiter] = [:]
        var isClosed = false
    }

    private let state = Mutex(State())

    var clock: MCPHTTPServerClock {
        MCPHTTPServerClock(
            now: { [self] in
                state.withLock { $0.now }
            },
            sleep: { [self] (duration: Duration) async throws(CancellationError) -> Void in
                try await sleep(for: duration)
            }
        )
    }

    func advance(by duration: Duration) {
        precondition(duration >= .zero, "A monotonic clock cannot move backwards.")
        let continuations = state.withLock { state in
            precondition(state.isClosed == false, "A closed manual clock cannot advance.")
            state.now = state.now.advanced(by: duration)
            let dueIDs = state.sleepers.compactMap { id, sleeper in
                sleeper.deadline <= state.now ? id : nil
            }
            return dueIDs.compactMap { id in
                state.sleepers.removeValue(forKey: id)?.continuation
            }
        }
        for continuation in continuations {
            continuation.resume(returning: .success(()))
        }
    }

    func waitForSleeperCount(
        _ count: Int
    ) async throws(CancellationError) {
        precondition(count >= 0)
        let waiterID = UUID()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var immediateResult: Result<Void, CancellationError>?
                state.withLock { state in
                    if Task.isCancelled || state.isClosed {
                        immediateResult = .failure(CancellationError())
                    } else if state.sleepers.count >= count {
                        immediateResult = .success(())
                    } else {
                        state.sleeperCountWaiters[waiterID] = SleeperCountWaiter(
                            count: count,
                            continuation: continuation
                        )
                    }
                }
                if let immediateResult {
                    continuation.resume(returning: immediateResult)
                }
            }
        } onCancel: { [self] in
            let continuation = state.withLock { state in
                state.sleeperCountWaiters.removeValue(forKey: waiterID)?.continuation
            }
            continuation?.resume(returning: .failure(CancellationError()))
        }
        try result.get()
    }

    func close() {
        let continuations = state.withLock { state in
            guard state.isClosed == false else {
                return [CheckedContinuation<Result<Void, CancellationError>, Never>]()
            }
            state.isClosed = true
            let continuations = state.sleepers.values.map(\.continuation)
                + state.sleeperCountWaiters.values.map(\.continuation)
            state.sleepers.removeAll()
            state.sleeperCountWaiters.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.resume(returning: .failure(CancellationError()))
        }
    }

    private func sleep(
        for duration: Duration
    ) async throws(CancellationError) {
        guard duration > .zero else {
            return
        }
        let sleeperID = UUID()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var immediateResult: Result<Void, CancellationError>?
                var countWaiters:
                    [CheckedContinuation<Result<Void, CancellationError>, Never>] = []
                state.withLock { state in
                    if Task.isCancelled || state.isClosed {
                        immediateResult = .failure(CancellationError())
                    } else {
                        let deadline = state.now.advanced(by: duration)
                        if deadline <= state.now {
                            immediateResult = .success(())
                        } else {
                            state.sleepers[sleeperID] = Sleeper(
                                deadline: deadline,
                                continuation: continuation
                            )
                            let satisfiedWaiterIDs = state.sleeperCountWaiters.compactMap {
                                id,
                                waiter in
                                state.sleepers.count >= waiter.count ? id : nil
                            }
                            countWaiters = satisfiedWaiterIDs.compactMap { id in
                                state.sleeperCountWaiters.removeValue(forKey: id)?.continuation
                            }
                        }
                    }
                }
                for countWaiter in countWaiters {
                    countWaiter.resume(returning: .success(()))
                }
                if let immediateResult {
                    continuation.resume(returning: immediateResult)
                }
            }
        } onCancel: { [self] in
            let continuation = state.withLock { state in
                state.sleepers.removeValue(forKey: sleeperID)?.continuation
            }
            continuation?.resume(returning: .failure(CancellationError()))
        }
        try result.get()
    }
}

private nonisolated func currentPOSIXError() -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
}

private nonisolated func testError(_ message: String) -> NSError {
    NSError(
        domain: "CodexReviewMCPHTTPServerTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}

private func makeHTTPTestRunID(_ rawValue: String) -> ReviewRunID {
    do {
        return try ReviewRunID(validating: rawValue)
    } catch {
        preconditionFailure("Invalid explicit review run fixture: \(error)")
    }
}

private func makeHTTPReviewAttempt(attemptID: String, turnID: String) -> ReviewAttempt {
    makeReviewAttemptForTesting(
        attemptID: attemptID,
        sourceThreadID: "source-\(attemptID)",
        activeTurnThreadID: "active-\(attemptID)",
        turnID: turnID
    )
}

private extension [String: Any] {
    func value(for path: [String]) -> Any? {
        var current: Any? = self
        for component in path {
            current = (current as? [String: Any])?[component]
        }
        return current
    }
}
