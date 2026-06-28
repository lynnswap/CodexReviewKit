import Darwin
import Foundation
import MCP
@preconcurrency import NIOCore
import Testing
@_spi(Testing) @testable import CodexReviewKit
import CodexReviewKit
import CodexReviewMCPServer
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
            #expect(awaitProperties["logOffset"] == nil)
            let awaitAnyOf = try #require(awaitSchema["anyOf"] as? [[String: Any]])
            let requiredAliases = awaitAnyOf.compactMap { $0["required"] as? [String] }
            #expect(requiredAliases.contains(["runId"]))
            #expect(requiredAliases.contains(["runID"]))
        }
    }

    @Test func streamableHTTPAllowsConfiguredHostDuringValidation() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let server = CodexReviewMCPHTTPServer(
            adapter: CodexReviewMCPServer(store: store),
            configuration: .init(host: "review.local", port: 9417)
        )
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
        let response = await server.handleHTTPRequest(
            HTTPRequest(
                method: "POST",
                headers: [
                    HTTPHeaderName.host: "review.local:9417",
                    HTTPHeaderName.accept: "text/event-stream, application/json",
                    HTTPHeaderName.contentType: "application/json",
                ],
                body: initializeBody,
                path: "/mcp"
            ))
        let denied = await server.handleHTTPRequest(
            HTTPRequest(
                method: "POST",
                headers: [
                    HTTPHeaderName.host: "other.local:9417",
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

    @Test func streamableHTTPCallsReviewStartWithCustomTarget() async throws {
        let backend = FakeCodexReviewBackend()
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
                        "sessionID": "session-1",
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
            await backend.yield(.completed(summary: "Done", result: "review text"))
            let resolved = try decodeSSEJSON(from: try await responseData)

            #expect(resolved.value(for: ["result", "isError"]) as? Bool == false)
            #expect(resolved.value(for: ["result", "structuredContent", "runId"]) as? String == "run-1")
            #expect(resolved.value(for: ["result", "structuredContent", "runID"]) == nil)
            #expect(resolved.value(for: ["result", "structuredContent", "logs"]) == nil)
            #expect(
                resolved.value(for: ["result", "structuredContent", "lifecycle", "status"]) as? String == "succeeded")
            #expect(
                resolved.value(for: ["result", "structuredContent", "lifecycle", "message"]) as? String == "Done")
            #expect(
                resolved.value(for: ["result", "structuredContent", "review", "hasFinalReview"]) as? Bool == false)
            #expect(resolved.value(for: ["result", "structuredContent", "review", "finalReview"]) is NSNull)
            let commands = await backend.recordedCommands()
            #expect(
                commands.contains(
                    .startReview(
                        .init(
                            runID: "run-1",
                            sessionID: sessionID,
                            request: .init(
                                cwd: "/tmp/project", target: .custom(instructions: "Focus on test coverage."))
                        ))))
        }
    }

    @Test func streamableHTTPBoundsClaudeReviewStartAndContinuesWithReviewAwait() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        let configuration = CodexReviewMCPHTTPServer.Configuration(
            port: 0,
            streamHeartbeatInterval: nil,
            boundedReviewWaitDuration: .milliseconds(50)
        )

        try await withHTTPServer(store: store, configuration: configuration) { server in
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
            #expect(
                running.value(for: ["result", "structuredContent", "nextAction", "tool"]) as? String == "review_await")

            await backend.yield(.completed(summary: "Done", result: "review text"))
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
                awaited.value(for: ["result", "structuredContent", "lifecycle", "message"]) as? String == "Done")
            #expect(
                awaited.value(for: ["result", "structuredContent", "review", "hasFinalReview"]) as? Bool == false)
            #expect(awaited.value(for: ["result", "structuredContent", "review", "finalReview"]) is NSNull)
            #expect(
                awaited.value(for: ["result", "structuredContent", "log", "finalLifecycleMessage"]) as? String
                    == "Done")
            #expect(awaited.value(for: ["result", "structuredContent", "log", "finalResult"]) is NSNull)
            #expect(awaited.value(for: ["result", "structuredContent", "logs"]) == nil)
        }
    }

    @Test func streamableHTTPBindsReviewStartToTransportSessionWhenArgumentIsOmitted() async throws {
        let backend = FakeCodexReviewBackend()
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
            await backend.yield(.completed(summary: "Done", result: "review text"))
            let resolved = try decodeSSEJSON(from: try await responseData)

            #expect(resolved.value(for: ["result", "structuredContent", "runId"]) as? String == "run-1")
            let commands = await backend.recordedCommands()
            #expect(
                commands.contains(
                    .startReview(
                        .init(
                            runID: "run-1",
                            sessionID: sessionID,
                            request: .init(
                                cwd: "/tmp/project", target: .custom(instructions: "Focus on test coverage."))
                        ))))
        }
    }

    @Test func streamableHTTPReportsFailedReviewStartAsToolError() async throws {
        let backend = FakeCodexReviewBackend()
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
            await backend.yield(.failed("Backend failed"))
            let resolved = try decodeSSEJSON(from: try await responseData)

            #expect(resolved.value(for: ["result", "isError"]) as? Bool == true)
            #expect(resolved.value(for: ["result", "structuredContent", "runId"]) as? String == "run-1")
            #expect(resolved.value(for: ["result", "structuredContent", "lifecycle", "status"]) as? String == "failed")
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
                status: .succeeded,
                summary: "Done"
            )
            let otherSession = ReviewRunRecord.makeForTesting(
                id: "run-other-session",
                sessionID: "other-session",
                cwd: "/tmp/project",
                targetSummary: "Uncommitted changes",
                status: .succeeded,
                summary: "Done"
            )
            let otherWorkspace = ReviewRunRecord.makeForTesting(
                id: "run-other-workspace",
                sessionID: sessionID,
                cwd: "/tmp/other",
                targetSummary: "Uncommitted changes",
                status: .succeeded,
                summary: "Done"
            )
            store.loadForTesting(
                serverState: .running,
                reviewRuns: [included, otherSession, otherWorkspace]
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
                            "sessionID": "other-session",
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

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let includedRun = ReviewRunRecord.makeForTesting(
                id: "run-in-session",
                sessionID: sessionID,
                cwd: "/tmp/project",
                targetSummary: "Included",
                status: .succeeded,
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
                        status: .succeeded,
                        summary: "Done"
                    ),
                ]
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
                        "arguments": ["runId": "run-in-session"],
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
                        "arguments": ["runID": "run-other-session"],
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

    @Test func streamableHTTPReviewReadLeavesLogEmptyWithoutChatProvider() async throws {
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
                status: .succeeded,
                summary: "Done"
            )
            store.loadForTesting(
                serverState: .running,
                reviewRuns: [runRecord]
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

            #expect(defaultResponse.value(for: ["result", "structuredContent", "runId"]) as? String == "run-semantic")
            #expect(defaultResponse.value(for: ["result", "structuredContent", "run"]) != nil)
            #expect(
                defaultResponse.value(for: ["result", "structuredContent", "lifecycle", "status"]) as? String
                    == "succeeded")
            #expect(
                defaultResponse.value(for: ["result", "structuredContent", "lifecycle", "message"]) as? String
                    == "Done")
            #expect(
                defaultResponse.value(for: ["result", "structuredContent", "review", "hasFinalReview"]) as? Bool
                    == false)
            #expect(defaultResponse.value(for: ["result", "structuredContent", "review", "finalReview"]) is NSNull)
            #expect(defaultResponse.value(for: ["result", "structuredContent", "logs"]) == nil)
            #expect(defaultResponse.value(for: ["result", "structuredContent", "logsPage"]) == nil)
            #expect(defaultResponse.value(for: ["result", "structuredContent", "rawLogText"]) == nil)

            let log = try #require(
                defaultResponse.value(for: ["result", "structuredContent", "log"]) as? [String: Any])
            #expect(log["orderedEntryIds"] as? [String] == [])
            #expect(log["activeEntryIds"] as? [String] == [])
            #expect(log["activeEntryCount"] as? Int == 0)
            #expect(log["latestEntryId"] is NSNull)
            let itemsPage = try #require(log["itemsPage"] as? [String: Any])
            #expect(itemsPage["total"] as? Int == 0)
            #expect(itemsPage["limit"] as? Int == 0)
            #expect(itemsPage["returned"] as? Int == 0)
            let items = try #require(log["items"] as? [[String: Any]])
            #expect(items.isEmpty)
        }
    }

    @Test func streamableHTTPReviewReadDoesNotProjectRunningSummaryAsLogContent() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let runRecord = ReviewRunRecord.makeForTesting(
                id: "run-tool-progress",
                sessionID: sessionID,
                cwd: "/tmp/project",
                targetSummary: "Included",
                status: .running,
                summary: "Running"
            )
            store.loadForTesting(
                serverState: .running,
                reviewRuns: [runRecord]
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
            #expect(log["activeEntryIds"] as? [String] == [])
            #expect(log["activeEntryCount"] as? Int == 0)
            let items = try #require(log["items"] as? [[String: Any]])
            #expect(items.isEmpty)
        }
    }

    @Test func streamableHTTPCancelsReviewByTransportScopedSelector() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let running = ReviewRunRecord.makeForTesting(
                id: "run-running",
                sessionID: sessionID,
                cwd: "/tmp/project",
                targetSummary: "Uncommitted changes",
                threadID: "thread-1",
                turnID: "turn-1",
                status: .running,
                summary: "Running"
            )
            let otherSession = ReviewRunRecord.makeForTesting(
                id: "run-other-session",
                sessionID: "other-session",
                cwd: "/tmp/project",
                targetSummary: "Uncommitted changes",
                threadID: "thread-2",
                turnID: "turn-2",
                status: .running,
                summary: "Running"
            )
            store.loadForTesting(
                serverState: .running,
                reviewRuns: [running, otherSession]
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
                            "sessionID": "other-session",
                            "cwd": "/tmp/project",
                            "statuses": ["running"],
                            "reason": "Stop from MCP",
                        ],
                    ],
                ]
            )

            #expect(response.value(for: ["result", "structuredContent", "runId"]) as? String == "run-running")
            #expect(response.value(for: ["result", "structuredContent", "cancelled"]) as? Bool == true)
            #expect(running.core.lifecycle.status == .cancelled)
            #expect(running.core.lifecycle.cancellation?.message == "Stop from MCP")
            #expect(otherSession.cancellationRequested == false)
            let commands = await backend.recordedCommands()
            #expect(
                commands.contains(
                    .interruptReview(
                        .init(threadID: "thread-1", turnID: "turn-1", reviewThreadID: "thread-1", model: "gpt-5"),
                        .init(message: "Stop from MCP")
                    )))
        }
    }

    @Test func streamableHTTPCancelDefaultsSelectorToActiveRunsInTransportSession() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let completed = ReviewRunRecord.makeForTesting(
                id: "run-completed",
                sessionID: sessionID,
                cwd: "/tmp/project",
                targetSummary: "Completed",
                threadID: "thread-completed",
                turnID: "turn-completed",
                status: .succeeded,
                summary: "Done"
            )
            let running = ReviewRunRecord.makeForTesting(
                id: "run-running",
                sessionID: sessionID,
                cwd: "/tmp/project",
                targetSummary: "Running",
                threadID: "thread-running",
                turnID: "turn-running",
                status: .running,
                summary: "Running"
            )
            store.loadForTesting(
                serverState: .running,
                reviewRuns: [completed, running]
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
            #expect(completed.core.lifecycle.status == .succeeded)
            #expect(running.core.lifecycle.status == .cancelled)
        }
    }

    @Test func streamableHTTPReportsAmbiguousCancelSelectorCandidates() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            store.loadForTesting(
                serverState: .running,
                reviewRuns: [
                    ReviewRunRecord.makeForTesting(
                        id: "run-running-1",
                        sessionID: sessionID,
                        cwd: "/tmp/project",
                        targetSummary: "First",
                        threadID: "thread-1",
                        turnID: "turn-1",
                        status: .running,
                        summary: "Running"
                    ),
                    ReviewRunRecord.makeForTesting(
                        id: "run-running-2",
                        sessionID: sessionID,
                        cwd: "/tmp/project",
                        targetSummary: "Second",
                        threadID: "thread-2",
                        turnID: "turn-2",
                        status: .running,
                        summary: "Running"
                    ),
                ]
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
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let running = ReviewRunRecord.makeForTesting(
                id: "run-running",
                sessionID: sessionID,
                cwd: "/tmp/project",
                targetSummary: "Running",
                threadID: "thread-running",
                turnID: "turn-running",
                status: .running,
                summary: "Running"
            )
            store.loadForTesting(
                serverState: .running,
                reviewRuns: [running]
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
            #expect(running.core.lifecycle.status == .cancelled)
        }
    }

    @Test func streamableHTTPDoesNotExpireSessionWithActiveReviewRequest() async throws {
        let backend = FakeCodexReviewBackend()
        let gate = AsyncGate()
        await backend.holdStartReview(with: gate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )

        try await withHTTPServer(
            store: store,
            configuration: .init(port: 0, sessionTimeout: 1)
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
            await server.runSessionCleanupForTesting(now: .distantFuture)
            await gate.open()
            await backend.yield(.completed(summary: "Done", result: "review text"))
            let resolved = try decodeSSEJSON(from: try await responseData)

            #expect(resolved.value(for: ["result", "structuredContent", "runId"]) as? String == "run-1")
            #expect(resolved.value(for: ["result", "structuredContent", "logs"]) == nil)
            #expect(resolved.value(for: ["result", "structuredContent", "rawLogText"]) == nil)
            let startText = (resolved.value(for: ["result", "content"]) as? [[String: Any]])?.first?["text"] as? String
            #expect(startText == "Done")
            #expect(startText?.contains("rawLogText") == false)
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
        }
    }

    @Test func streamableHTTPDoesNotExpireSessionWithOpenEventStream() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(
            store: store,
            configuration: .init(port: 0, sessionTimeout: 1)
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

            await server.runSessionCleanupForTesting(now: .distantFuture)

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
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(
            store: store,
            configuration: .init(
                host: "127.0.0.1",
                port: 0,
                sessionTimeout: 1,
                streamHeartbeatInterval: .milliseconds(50)
            )
        ) { server in
            let endpoint = await server.url
            let sessionID = try await initializeSession(endpoint: endpoint)

            try await openAndCloseRawEventStream(endpoint: endpoint, sessionID: sessionID)
            let streamReleased = await waitUntil(timeout: .seconds(2)) {
                await server.sessionActiveRequestCountForTesting(sessionID: sessionID) == 0
            }
            #expect(streamReleased)

            await server.runSessionCleanupForTesting(now: .distantFuture)
            #expect(await server.sessionActiveRequestCountForTesting(sessionID: sessionID) == nil)
        }
    }

    @Test func streamableHTTPKeepsRunIDCancellationInTransportSession() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let other = ReviewRunRecord.makeForTesting(
                id: "run-other-session",
                sessionID: "other-session",
                cwd: "/tmp/project",
                targetSummary: "Other",
                threadID: "thread-other",
                turnID: "turn-other",
                status: .running,
                summary: "Running"
            )
            store.loadForTesting(
                serverState: .running,
                reviewRuns: [other]
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
            #expect(other.core.lifecycle.status == .running)
        }
    }

    @Test func streamableHTTPDeleteClosesStoreSession() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let running = ReviewRunRecord.makeForTesting(
                id: "run-running",
                sessionID: sessionID,
                cwd: "/tmp/project",
                targetSummary: "Running",
                threadID: "thread-running",
                turnID: "turn-running",
                status: .running,
                summary: "Running"
            )
            store.loadForTesting(
                serverState: .running,
                reviewRuns: [running]
            )

            let response = try await deleteSession(endpoint: await server.url, sessionID: sessionID)

            #expect(response.statusCode == 200)
            #expect(running.core.lifecycle.status == .cancelled)
            await #expect(throws: (any Error).self) {
                try await store.startReview(
                    sessionID: sessionID,
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                )
            }
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

    private func withHTTPServer<T>(
        store: CodexReviewStore,
        configuration: CodexReviewMCPHTTPServer.Configuration = .init(port: 0),
        operation: (CodexReviewMCPHTTPServer) async throws -> T
    ) async throws -> T {
        let adapter = CodexReviewMCPServer(store: store)
        let server = CodexReviewMCPHTTPServer(
            adapter: adapter,
            configuration: configuration
        )

        try await server.start()
        do {
            let result = try await operation(server)
            await server.stop()
            return result
        } catch {
            await server.stop()
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

    private nonisolated func openAndCloseRawEventStream(endpoint: URL, sessionID: String) async throws {
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

private extension [String: Any] {
    func value(for path: [String]) -> Any? {
        var current: Any? = self
        for component in path {
            current = (current as? [String: Any])?[component]
        }
        return current
    }
}
