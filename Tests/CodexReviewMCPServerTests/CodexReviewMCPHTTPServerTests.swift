import Darwin
import Foundation
import MCP
@preconcurrency import NIOCore
import Testing
@_spi(Testing) @testable import CodexReview
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
            #expect(readProperties["logOffset"] != nil)
            #expect(readProperties["logLimit"] != nil)
            let reviewAwait = try #require(tools.first { $0["name"] as? String == "review_await" })
            let awaitSchema = try #require(reviewAwait["inputSchema"] as? [String: Any])
            let awaitProperties = try #require(awaitSchema["properties"] as? [String: Any])
            #expect(awaitProperties["jobId"] != nil)
            #expect(awaitProperties["logOffset"] == nil)
            let awaitAnyOf = try #require(awaitSchema["anyOf"] as? [[String: Any]])
            let requiredAliases = awaitAnyOf.compactMap { $0["required"] as? [String] }
            #expect(requiredAliases.contains(["jobId"]))
            #expect(requiredAliases.contains(["jobID"]))
        }
    }

    @Test func toolsListMatchesPublishedV062Golden() async throws {
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
            let actualTools = try #require(response.value(for: ["result", "tools"]) as? [[String: Any]])
            let goldenURL = try #require(Bundle.module.url(
                forResource: "tools-list-v0.6.2",
                withExtension: "json"
            ))
            let goldenTools = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: goldenURL)) as? [[String: Any]]
            )
            let publishedNames = [
                "review_start",
                "review_await",
                "review_read",
                "review_list",
                "review_cancel",
            ]

            #expect(goldenTools.compactMap { $0["name"] as? String } == publishedNames)
            #expect(actualTools.compactMap { $0["name"] as? String } == publishedNames)
            #expect(try canonicalJSON(actualTools) == canonicalJSON(goldenTools))
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
        let response = await server.validationResponseForTesting(HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeaderName.host: "review.local:9417",
                HTTPHeaderName.accept: "text/event-stream, application/json",
                HTTPHeaderName.contentType: "application/json",
            ],
            body: initializeBody,
            path: "/mcp"
        ))
        let denied = await server.validationResponseForTesting(HTTPRequest(
            method: "POST",
            headers: [
                HTTPHeaderName.host: "other.local:9417",
                HTTPHeaderName.accept: "text/event-stream, application/json",
                HTTPHeaderName.contentType: "application/json",
            ],
            body: initializeBody,
            path: "/mcp"
        ))

        #expect(response == nil)
        #expect(denied?.statusCode == 421)
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

        #expect((classified as? CodexReviewMCPHTTPServer.Error) == .addressInUse(
            host: "127.0.0.1",
            port: 54321
        ))
    }

    @Test func startingGenerationAdmissionCloseCannotBeReopened() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let server = CodexReviewMCPHTTPServer(
            adapter: CodexReviewMCPServer(store: store),
            configuration: .init(host: "127.0.0.1", port: 0)
        )
        await server.holdNextStartCompletionForTesting()

        let startTask = Task {
            try await server.start()
        }
        await server.waitUntilStartCompletionIsHeldForTesting()
        let closeAdmissionTask = Task {
            await server.closeAdmission()
        }
        await server.waitUntilStartingGenerationAdmissionIsClosedForTesting()

        #expect(await server.url.port == 0)
        await server.releaseStartCompletionForTesting()
        await #expect(throws: CancellationError.self) {
            try await startTask.value
        }
        await closeAdmissionTask.value
        #expect(await server.currentGenerationIDForTesting() == nil)
        #expect(await server.url.port == 0)

        try await server.start()
        #expect(await server.currentGenerationIDForTesting() == 2)
        #expect(await server.url.port != 0)
        try await server.stop()
    }

    @Test func listenerGenerationConcurrentStopAndRestartJoinOneTeardown() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let server = CodexReviewMCPHTTPServer(
            adapter: CodexReviewMCPServer(store: store),
            configuration: .init(host: "127.0.0.1", port: 0)
        )
        await server.holdNextStartCompletionForTesting()
        let firstStart = Task {
            try await server.start()
        }
        await server.waitUntilStartCompletionIsHeldForTesting()
        await server.holdNextJoinedStartCompletionForTesting()
        let joinedStart = Task {
            try await server.start()
        }
        await server.waitUntilJoinedStartCompletionIsHeldForTesting()
        await server.releaseStartCompletionForTesting()
        try await firstStart.value
        let firstURL = await server.url
        let firstGeneration = await server.currentGenerationIDForTesting()
        await server.holdNextStopCompletionForTesting()

        let firstStop = Task {
            try await server.stop()
        }
        await server.waitUntilStopCompletionIsHeldForTesting()
        await server.releaseJoinedStartCompletionForTesting()
        try await joinedStart.value
        let secondStop = Task {
            try await server.stop()
        }
        let restart = Task {
            try await server.start()
        }
        await server.waitUntilStopJoinsStoppingGenerationForTesting()
        await server.waitUntilStartJoinsStoppingGenerationForTesting()

        #expect(await server.url == firstURL)
        await server.releaseStopCompletionForTesting()
        try await firstStop.value
        try await secondStop.value
        try await restart.value

        #expect(firstGeneration == 1)
        #expect(await server.currentGenerationIDForTesting() == 2)
        #expect(await server.url.port != 0)
        #expect(await server.eventLoopGroupShutdownCountForTesting() == 1)
        try await server.stop()
        #expect(await server.eventLoopGroupShutdownCountForTesting() == 2)
    }

    @Test func listenerGenerationStopFailureIsRetainedAndReplayed() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let server = CodexReviewMCPHTTPServer(
            adapter: CodexReviewMCPServer(store: store),
            configuration: .init(host: "127.0.0.1", port: 0)
        )
        try await server.start()
        await server.injectNextListenerCloseFailureForTesting("injected listener close failure")
        await server.injectNextEventLoopGroupShutdownFailureForTesting("injected group shutdown failure")

        let firstError = try #require(await lifecycleError {
            try await server.stop()
        })
        let replayedError = try #require(await lifecycleError {
            try await server.stop()
        })

        #expect(firstError == .init(
            first: .init(resource: .listener, message: "injected listener close failure"),
            additional: [
                .init(resource: .eventLoopGroup, message: "injected group shutdown failure"),
            ]
        ))
        #expect(replayedError == firstError)
        #expect(await server.eventLoopGroupShutdownCountForTesting() == 1)
        await #expect(throws: CodexReviewMCPHTTPServer.LifecycleError.self) {
            try await server.start()
        }
    }

    @Test func concurrentStopsJoinTheSameListenerFailureResult() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let server = CodexReviewMCPHTTPServer(
            adapter: CodexReviewMCPServer(store: store),
            configuration: .init(host: "127.0.0.1", port: 0)
        )
        try await server.start()
        await server.holdNextStopCompletionForTesting()
        await server.injectNextListenerCloseFailureForTesting("joined listener failure")

        let firstStop = Task {
            await lifecycleError {
                try await server.stop()
            }
        }
        await server.waitUntilStopCompletionIsHeldForTesting()
        let joinedStop = Task {
            await lifecycleError {
                try await server.stop()
            }
        }
        await server.waitUntilStopJoinsStoppingGenerationForTesting()
        await server.releaseStopCompletionForTesting()

        let expected = CodexReviewMCPHTTPServer.LifecycleError(
            first: .init(resource: .listener, message: "joined listener failure")
        )
        #expect(await firstStop.value == expected)
        #expect(await joinedStop.value == expected)
        #expect(await server.eventLoopGroupShutdownCountForTesting() == 1)
    }

    @Test func runningGenerationAdmissionCloseIsRetainedByStop() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let server = CodexReviewMCPHTTPServer(
            adapter: CodexReviewMCPServer(store: store),
            configuration: .init(host: "127.0.0.1", port: 0)
        )
        try await server.start()
        let runningURL = await server.url
        await server.injectNextListenerCloseFailureForTesting("injected admission close failure")

        await server.closeAdmission()

        #expect(await server.url == runningURL)
        await #expect(throws: CancellationError.self) {
            try await server.start()
        }
        let firstError = try #require(await lifecycleError {
            try await server.stop()
        })
        let replayedError = try #require(await lifecycleError {
            try await server.stop()
        })
        #expect(firstError == .init(
            first: .init(resource: .listener, message: "injected admission close failure")
        ))
        #expect(replayedError == firstError)
        #expect(await server.eventLoopGroupShutdownCountForTesting() == 1)
    }

    @Test func portZeroPublishesOneStableActualURLPerListenerGeneration() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let server = CodexReviewMCPHTTPServer(
            adapter: CodexReviewMCPServer(store: store),
            configuration: .init(host: "127.0.0.1", port: 0)
        )

        #expect(await server.url.port == 0)
        await server.holdNextStartCompletionForTesting()
        let firstStart = Task {
            try await server.start()
        }
        await server.waitUntilStartCompletionIsHeldForTesting()
        let joinedStart = Task {
            try await server.start()
        }
        await server.waitUntilStartJoinsStartingGenerationForTesting()
        await server.releaseStartCompletionForTesting()
        try await firstStart.value
        try await joinedStart.value
        let firstURL = await server.url
        #expect(firstURL.port != 0)
        #expect(await server.url == firstURL)
        #expect(await server.currentGenerationIDForTesting() == 1)
        try await server.stop()
        #expect(await server.url.port == 0)

        try await server.start()
        let secondURL = await server.url
        #expect(secondURL.port != 0)
        #expect(await server.url == secondURL)
        #expect(await server.currentGenerationIDForTesting() == 2)
        try await server.stop()
    }

    @Test func slowFirstPOSTKeepsPipelinedSecondMutationOutsideAdmission() async throws {
        let backend = FakeCodexReviewBackend()
        let startGate = AsyncGate()
        await backend.holdStartReview(with: startGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )

        try await withHTTPServer(store: store) { server in
            let endpoint = await server.url
            let sessionID = try await initializeSession(endpoint: endpoint)
            let connection = try await RawHTTPConnection.connect(to: endpoint)
            defer { connection.close() }
            let first = try makeReviewStartBody(id: 2)
            let second = try makeReviewStartBody(id: 3)

            try await connection.send(
                rawHTTPRequest(endpoint: endpoint, sessionID: sessionID, body: first)
                    + rawHTTPRequest(endpoint: endpoint, sessionID: sessionID, body: second)
            )
            try await backend.waitForStartReview(timeout: .seconds(2))

            let snapshot = try #require(await server.networkResourceSnapshotForTesting())
            #expect(snapshot.connections.flatMap(\.requests).count == 1)
            #expect(await backend.recordedCommands().filter {
                if case .startReview = $0 { true } else { false }
            }.count == 1)

            connection.close()
            await startGate.open()
        }
    }

    @Test func openGETKeepsSameConnectionPOSTOutsideAdmission() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let endpoint = await server.url
            let sessionID = try await initializeSession(endpoint: endpoint)
            let connection = try await RawHTTPConnection.connect(to: endpoint)
            defer { connection.close() }
            let get = try rawHTTPRequest(
                endpoint: endpoint,
                method: "GET",
                sessionID: sessionID,
                headers: [("Accept", "text/event-stream, application/json")]
            )
            let post = try rawHTTPRequest(
                endpoint: endpoint,
                sessionID: sessionID,
                body: makeReviewStartBody(id: 2)
            )

            try await connection.send(get + post)
            #expect(try await connection.readResponseHead().contains(" 200 "))

            let snapshot = try #require(await server.networkResourceSnapshotForTesting())
            #expect(snapshot.connections.flatMap(\.requests).count == 1)
            #expect(await backend.recordedCommands().isEmpty)
        }
    }

    @Test func sameSessionDifferentConnectionsRemainParallel() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )

        try await withHTTPServer(store: store) { server in
            let endpoint = await server.url
            let sessionID = try await initializeSession(endpoint: endpoint)
            let streamConnection = try await RawHTTPConnection.connect(to: endpoint)
            defer { streamConnection.close() }
            try await streamConnection.send(rawHTTPRequest(
                endpoint: endpoint,
                method: "GET",
                sessionID: sessionID,
                headers: [("Accept", "text/event-stream, application/json")]
            ))
            #expect(try await streamConnection.readResponseHead().contains(" 200 "))

            async let response = postJSONRPCData(
                endpoint: endpoint,
                sessionID: sessionID,
                bodyData: makeReviewStartBody(id: 2)
            )
            try await backend.waitForStartReview(timeout: .seconds(2))
            await backend.yield(.completed(summary: "Done", result: "review text"))
            _ = try await response

            #expect(await backend.recordedCommands().contains {
                if case .startReview = $0 { true } else { false }
            })
        }
    }

    @Test func nonKeepAliveRequestRejectsPipelinedMutationBeforeDomainAdmission() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )

        try await withHTTPServer(store: store) { server in
            let endpoint = await server.url
            let sessionID = try await initializeSession(endpoint: endpoint)
            let connection = try await RawHTTPConnection.connect(to: endpoint)
            defer { connection.close() }
            let first = try rawHTTPRequest(
                endpoint: endpoint,
                sessionID: sessionID,
                headers: [("Connection", "close")],
                body: makeToolsListBody(id: 2)
            )
            let mutation = try rawHTTPRequest(
                endpoint: endpoint,
                sessionID: sessionID,
                body: makeReviewStartBody(id: 3)
            )

            try await connection.send(first + mutation)
            #expect(try await connection.readResponseHead().contains(" 200 "))
            _ = try await connection.readUntilEOF()

            #expect(await backend.recordedCommands().isEmpty)
        }
    }

    @Test func oneConnectionOwnsOnlyOneOfManyPipelinedRequests() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let endpoint = await server.url
            let sessionID = try await initializeSession(endpoint: endpoint)
            let connection = try await RawHTTPConnection.connect(to: endpoint)
            defer { connection.close() }
            var requests = try rawHTTPRequest(
                endpoint: endpoint,
                method: "GET",
                sessionID: sessionID,
                headers: [("Accept", "text/event-stream, application/json")]
            )
            for id in 2..<34 {
                requests += try rawHTTPRequest(
                    endpoint: endpoint,
                    sessionID: sessionID,
                    body: makeToolsListBody(id: id)
                )
            }

            try await connection.send(requests)
            #expect(try await connection.readResponseHead().contains(" 200 "))

            let snapshot = try #require(await server.networkResourceSnapshotForTesting())
            #expect(snapshot.connections.flatMap(\.requests).count == 1)
        }
    }

    @Test func requestBodyLimitAcceptsNAndRejectsKnownAndChunkedNPlusOne() async throws {
        let limit = 512
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let configuration = CodexReviewMCPHTTPServer.Configuration(
            host: "127.0.0.1",
            port: 0,
            maximumRequestBodyBytes: limit
        )

        try await withHTTPServer(store: store, configuration: configuration) { server in
            let endpoint = await server.url
            let sessionID = try await initializeSession(endpoint: endpoint)
            var exactBody = try makeToolsListBody(id: 2)
            exactBody.append(Data(repeating: 0x20, count: limit - exactBody.count))

            let exact = try await RawHTTPConnection.connect(to: endpoint)
            try await exact.send(rawHTTPRequest(
                endpoint: endpoint,
                sessionID: sessionID,
                body: exactBody
            ))
            #expect(try await exact.readResponseHead().contains(" 200 "))
            exact.close()

            let knownTooLarge = try await RawHTTPConnection.connect(to: endpoint)
            try await knownTooLarge.send(rawHTTPRequest(
                endpoint: endpoint,
                sessionID: sessionID,
                headers: [
                    ("Content-Length", "\(limit + 1)"),
                    ("Expect", "100-continue"),
                ]
            ))
            let knownHead = try await knownTooLarge.readResponseHead()
            #expect(knownHead.contains(" 413 "))
            #expect(knownHead.lowercased().contains("connection: close"))
            _ = try await knownTooLarge.readUntilEOF()
            knownTooLarge.close()

            let largerThanInt = try await RawHTTPConnection.connect(to: endpoint)
            try await largerThanInt.send(rawHTTPRequest(
                endpoint: endpoint,
                sessionID: sessionID,
                headers: [("Content-Length", "9223372036854775808")]
            ))
            #expect(try await largerThanInt.readResponseHead().contains(" 413 "))
            _ = try await largerThanInt.readUntilEOF()
            largerThanInt.close()

            let chunked = try await RawHTTPConnection.connect(to: endpoint)
            var chunkedBody = Data("\(String(limit, radix: 16))\r\n".utf8)
            chunkedBody.append(Data(repeating: 0x61, count: limit))
            chunkedBody.append(Data("\r\n1\r\nb\r\n".utf8))
            try await chunked.send(rawHTTPRequest(
                endpoint: endpoint,
                sessionID: sessionID,
                headers: [("Transfer-Encoding", "chunked")],
                body: chunkedBody
            ))
            let chunkedHead = try await chunked.readResponseHead()
            #expect(chunkedHead.contains(" 413 "))
            #expect(chunkedHead.lowercased().contains("connection: close"))
            _ = try await chunked.readUntilEOF()
            chunked.close()
        }
    }

    @Test func expectContinueUsesTheStandardPipelineBeforeReadingTheBody() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let endpoint = await server.url
            let sessionID = try await initializeSession(endpoint: endpoint)
            let body = try makeToolsListBody(id: 2)
            let connection = try await RawHTTPConnection.connect(to: endpoint)
            defer { connection.close() }
            try await connection.send(rawHTTPRequest(
                endpoint: endpoint,
                sessionID: sessionID,
                headers: [
                    ("Content-Length", "\(body.count)"),
                    ("Expect", "100-continue"),
                ]
            ))

            #expect(try await connection.readResponseHead().contains(" 100 "))
            try await connection.send(body)
            #expect(try await connection.readResponseHead().contains(" 200 "))

            let unsupported = try await RawHTTPConnection.connect(to: endpoint)
            try await unsupported.send(rawHTTPRequest(
                endpoint: endpoint,
                sessionID: sessionID,
                headers: [
                    ("Content-Length", "\(body.count)"),
                    ("Expect", "custom-expectation"),
                ]
            ))
            #expect(try await unsupported.readResponseHead().contains(" 417 "))
            _ = try await unsupported.readUntilEOF()
            unsupported.close()

            let http10 = try await RawHTTPConnection.connect(to: endpoint)
            try await http10.send(rawHTTPRequest(
                endpoint: endpoint,
                version: "HTTP/1.0",
                sessionID: sessionID,
                headers: [
                    ("Content-Length", "\(body.count)"),
                    ("Expect", "100-continue"),
                ],
                body: body
            ))
            let http10Head = try await http10.readResponseHead()
            #expect(http10Head.contains(" 200 "))
            #expect(http10Head.contains(" 100 ") == false)
            http10.close()
        }
    }

    @Test func stopCancelsAHeadAdmittedBodyReceipt() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let endpoint = await server.url
            let sessionID = try await initializeSession(endpoint: endpoint)
            let body = try makeToolsListBody(id: 2)
            let connection = try await RawHTTPConnection.connect(to: endpoint)
            defer { connection.close() }
            try await connection.send(rawHTTPRequest(
                endpoint: endpoint,
                sessionID: sessionID,
                headers: [
                    ("Content-Length", "\(body.count)"),
                    ("Expect", "100-continue"),
                ]
            ))
            #expect(try await connection.readResponseHead().contains(" 100 "))
            #expect(try #require(await server.networkResourceSnapshotForTesting())
                .connections.flatMap(\.requests).count == 1)

            try await server.stop()

            _ = try await connection.readUntilEOF()
            #expect(await server.currentGenerationIDForTesting() == nil)
        }
    }

    @Test func networkFiniteStreamExhaustionFinishesItsActiveRequest() async throws {
        try await withHTTPServer(store: CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        )) { server in
            let endpoint = await server.url
            let sessionID = try await initializeSession(endpoint: endpoint)
            _ = try await postJSONRPCData(
                endpoint: endpoint,
                sessionID: sessionID,
                bodyData: makeToolsListBody(id: 29)
            )
            #expect(await server.sessionActiveRequestCountForTesting(sessionID: sessionID) == 0)
        }
    }

    @Test func networkOpenStreamDisconnectFinishesItsActiveRequest() async throws {
        let server = makeHTTPServer(configuration: .init(
            host: "127.0.0.1",
            port: 0,
            streamHeartbeatInterval: .milliseconds(10)
        ))
        try await server.start()
        let endpoint = await server.url
        let sessionID = try await initializeSession(endpoint: endpoint)
        let connection = try await RawHTTPConnection.connect(to: endpoint)
        try await connection.send(rawHTTPRequest(
            endpoint: endpoint,
            method: "GET",
            sessionID: sessionID,
            headers: [("Accept", "text/event-stream, application/json")]
        ))
        _ = try await connection.readResponseHead()
        #expect(await server.sessionActiveRequestCountForTesting(sessionID: sessionID) == 1)
        connection.reset()
        #expect(await waitUntil(timeout: .seconds(2)) {
            await server.sessionActiveRequestCountForTesting(sessionID: sessionID) == 0
        })
        try await server.stop()
    }

    @Test func stopJoinsHeldFiniteResponseSource() async throws {
        let server = makeHTTPServer()
        try await server.start()
        let endpoint = await server.url
        let sessionID = try await initializeSession(endpoint: endpoint)
        await server.holdNextFiniteSourceCompletionForTesting()
        let response = Task {
            try await postJSONRPCData(
                endpoint: endpoint,
                sessionID: sessionID,
                bodyData: makeToolsListBody(id: 30)
            )
        }
        await server.waitUntilFiniteSourceCompletionIsHeldForTesting()
        #expect(try #require(await server.networkResourceSnapshotForTesting())
            .connections.flatMap(\.requests).count == 1)

        let stop = Task { try await server.stop() }
        #expect(await waitUntil(timeout: .seconds(2)) {
            await server.networkResourceSnapshotForTesting()?.phase == .closing(.serverStop)
        })
        #expect(await server.eventLoopGroupShutdownCountForTesting() == 0)
        await server.releaseFiniteSourceCompletionForTesting()
        _ = try? await response.value
        try await stop.value
        #expect(await server.eventLoopGroupShutdownCountForTesting() == 1)
    }

    @Test func heldPhysicalBodyWriteAllowsOneSourceRead() async throws {
        let server = makeHTTPServer()
        try await server.start()
        let endpoint = await server.url
        let sessionID = try await initializeSession(endpoint: endpoint)
        await server.holdNextResponseBodyWriteForTesting()
        let response = Task {
            try await postJSONRPCData(
                endpoint: endpoint,
                sessionID: sessionID,
                bodyData: makeToolsListBody(id: 31)
            )
        }
        await server.waitUntilResponseBodyWriteIsHeldForTesting()
        #expect(await server.responseSourceReadCountForTesting() == 1)
        await server.releaseResponseBodyWriteForTesting()
        _ = try await response.value
        #expect(await server.responseSourceReadCountForTesting() >= 2)
        try await server.stop()
    }

    @Test func repeatedHeartbeatsCannotOvertakePendingBody() async {
        #expect(await CodexReviewMCPHTTPServer.responseRendezvousPrioritizesBodyForTesting())
    }

    @Test func stopJoinsWriterBeforeEventLoopShutdown() async throws {
        let server = makeHTTPServer()
        try await server.start()
        let endpoint = await server.url
        let sessionID = try await initializeSession(endpoint: endpoint)
        await server.holdNextWriterCompletionForTesting()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
        let (bytes, _) = try await URLSession.shared.bytes(for: request)

        let stop = Task { try await server.stop() }
        await server.waitUntilWriterCompletionIsHeldForTesting()
        #expect(await server.eventLoopGroupShutdownCountForTesting() == 0)
        await server.releaseWriterCompletionForTesting()
        try await stop.value
        withExtendedLifetime(bytes) {}
        #expect(await server.eventLoopGroupShutdownCountForTesting() == 1)
    }

    @Test func loneNonPersistentRequestsSendCompleteResponseThenEOF() async throws {
        let server = makeHTTPServer()
        try await server.start()
        let endpoint = await server.url
        let sessionID = try await initializeSession(endpoint: endpoint)
        for (version, connectionHeader, id) in [
            ("HTTP/1.0", Optional<String>.none, 32),
            ("HTTP/1.1", Optional("close"), 33),
        ] {
            let connection = try await RawHTTPConnection.connect(to: endpoint)
            try await connection.send(rawHTTPRequest(
                endpoint: endpoint,
                version: version,
                sessionID: sessionID,
                headers: connectionHeader.map { [("Connection", $0)] } ?? [],
                body: makeToolsListBody(id: id)
            ))
            let head = try await connection.readResponseHead()
            let body = try await connection.readUntilEOF()
            connection.close()
            #expect(head.contains(" 200 "))
            #expect(try decodeSSEJSON(from: body)["id"] as? Int == id)
            if version == "HTTP/1.1" {
                #expect(body.suffix(5) == Data("0\r\n\r\n".utf8))
            }
        }
        try await server.stop()
    }

    @Test func channelCloseCancelsOpenSSEWithoutLateEventLoopWork() async throws {
        let server = makeHTTPServer(configuration: .init(
            host: "127.0.0.1",
            port: 0,
            streamHeartbeatInterval: .milliseconds(10)
        ))
        try await server.start()
        let sessionID = try await initializeSession(endpoint: await server.url)
        try await openAndCloseRawEventStream(endpoint: await server.url, sessionID: sessionID)
        #expect(await waitUntil(timeout: .seconds(2)) {
            await server.networkResourceSnapshotForTesting()?.connections
                .flatMap(\.requests).isEmpty == true
        })
        try await server.stop()
        #expect(await server.eventLoopGroupShutdownCountForTesting() == 1)
    }

    @Test func acknowledgedResponseEndWinsConcurrentStop() async throws {
        let server = makeHTTPServer()
        try await server.start()
        let endpoint = await server.url
        let sessionID = try await initializeSession(endpoint: endpoint)
        await server.holdNextResponseEndAcknowledgementForTesting()
        let response = Task {
            try await postJSONRPCData(
                endpoint: endpoint,
                sessionID: sessionID,
                bodyData: makeToolsListBody(id: 34)
            )
        }
        await server.waitUntilResponseEndAcknowledgementIsHeldForTesting()
        let before = try #require(await server.networkResourceSnapshotForTesting()?
            .connections.flatMap(\.requests).first)
        #expect(before.responseEnd == .acknowledged)
        #expect(before.terminalCause == nil)

        let stop = Task { try await server.stop() }
        #expect(await waitUntil(timeout: .seconds(2)) {
            await server.networkResourceSnapshotForTesting()?.phase == .closing(.serverStop)
        })
        let after = try #require(await server.networkResourceSnapshotForTesting()?
            .connections.flatMap(\.requests).first)
        #expect(after.responseEnd == .acknowledged)
        #expect(after.terminalCause == nil)
        await server.releaseResponseEndAcknowledgementForTesting()
        _ = try? await response.value
        try await stop.value
    }

    @Test func clientDisconnectDrainsOwnedFiniteSource() async throws {
        let server = makeHTTPServer()
        try await server.start()
        let endpoint = await server.url
        let sessionID = try await initializeSession(endpoint: endpoint)
        await server.holdNextFiniteSourceCompletionForTesting()
        await server.holdNextWriterCompletionForTesting()
        let connection = try await RawHTTPConnection.connect(to: endpoint)
        try await connection.send(rawHTTPRequest(
            endpoint: endpoint,
            sessionID: sessionID,
            body: makeToolsListBody(id: 35)
        ))
        await server.waitUntilFiniteSourceCompletionIsHeldForTesting()
        _ = try await connection.readResponseHead()
        connection.reset()
        #expect(try #require(await server.networkResourceSnapshotForTesting())
            .connections.flatMap(\.requests).count == 1)
        await server.releaseFiniteSourceCompletionForTesting()
        await server.waitUntilWriterCompletionIsHeldForTesting()
        let closing = try #require(await server.networkResourceSnapshotForTesting()?
            .connections.flatMap(\.requests).first)
        #expect(closing.responseEnd == .closed)
        #expect(closing.terminalCause == .peerClosed || closing.terminalCause.map {
            if case .transportFailure = $0 { true } else { false }
        } == true)
        await server.releaseWriterCompletionForTesting()
        #expect(await waitUntil(timeout: .seconds(2)) {
            await server.networkResourceSnapshotForTesting()?.connections
                .flatMap(\.requests).isEmpty == true
        })
        try await server.stop()
    }

    @Test func nonStreamRequestRemainsOwnedUntilFinalEndWrite() async throws {
        let server = makeHTTPServer()
        try await server.start()
        let endpoint = await server.url
        await server.holdNextResponseEndWriteForTesting()
        let connection = try await RawHTTPConnection.connect(to: endpoint)
        try await connection.send(rawHTTPRequest(
            endpoint: endpoint,
            sessionID: nil,
            body: makeToolsListBody(id: 36)
        ))
        await server.waitUntilResponseEndWriteIsHeldForTesting()
        let pending = try #require(await server.networkResourceSnapshotForTesting()?
            .connections.flatMap(\.requests).first)
        #expect(pending.responseEnd == .pending)
        await server.releaseResponseEndWriteForTesting()
        #expect(await waitUntil(timeout: .seconds(2)) {
            await server.networkResourceSnapshotForTesting()?.connections
                .flatMap(\.requests).isEmpty == true
        })
        #expect(try await connection.readResponseHead().contains(" 400 "))
        connection.close()
        try await server.stop()
    }

    @Test func acceptedChildCloseAcknowledgementPrecedesEventLoopShutdown() async throws {
        let server = makeHTTPServer()
        try await server.start()
        let connection = try await RawHTTPConnection.connect(to: await server.url)
        await server.holdNextStopCompletionForTesting()
        let stop = Task { try await server.stop() }
        await server.waitUntilStopCompletionIsHeldForTesting()
        _ = try await connection.readUntilEOF()
        #expect(await server.networkResourceSnapshotForTesting()?.isClosed == true)
        #expect(await server.eventLoopGroupShutdownCountForTesting() == 0)
        await server.releaseStopCompletionForTesting()
        try await stop.value
        connection.close()
        #expect(await server.eventLoopGroupShutdownCountForTesting() == 1)
    }

    @Test func streamableHTTPCallsReviewStartWithCustomTarget() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
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
            #expect(resolved.value(for: ["result", "structuredContent", "jobId"]) as? String == "job-1")
            #expect(resolved.value(for: ["result", "structuredContent", "jobID"]) == nil)
            #expect(resolved.value(for: ["result", "structuredContent", "logs"]) == nil)
            #expect(resolved.value(for: ["result", "structuredContent", "lifecycle", "status"]) as? String == "succeeded")
            #expect(resolved.value(for: ["result", "structuredContent", "lifecycle", "terminal", "kind"]) as? String == "completed")
            #expect(resolved.value(for: ["result", "structuredContent", "output", "review"]) as? String == "review text")
            let commands = await backend.recordedCommands()
            #expect(commands.contains(.startReview(.init(
                jobID: "job-1",
                sessionID: sessionID,
                request: .init(cwd: "/tmp/project", target: .custom(instructions: "Focus on test coverage."))
            ))))
        }
    }

    @Test func streamableHTTPBoundsClaudeReviewStartAndContinuesWithReviewAwait() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
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
            #expect(running.value(for: ["result", "structuredContent", "jobId"]) as? String == "job-1")
            #expect(running.value(for: ["result", "structuredContent", "lifecycle", "status"]) as? String == "running")
            #expect(running.value(for: ["result", "structuredContent", "lifecycle", "terminal"]) is NSNull)
            #expect(running.value(for: ["result", "structuredContent", "logs"]) == nil)
            #expect(running.value(for: ["result", "structuredContent", "rawLogText"]) == nil)
            #expect(running.value(for: ["result", "structuredContent", "nextAction", "tool"]) as? String == "review_await")

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
                            "jobId": "job-1",
                        ],
                    ],
                ]
            )

            #expect(awaited.value(for: ["result", "isError"]) as? Bool == false)
            #expect(awaited.value(for: ["result", "structuredContent", "lifecycle", "status"]) as? String == "succeeded")
            #expect(awaited.value(for: ["result", "structuredContent", "lifecycle", "terminal", "kind"]) as? String == "completed")
            #expect(awaited.value(for: ["result", "structuredContent", "output", "review"]) as? String == "review text")
            #expect(awaited.value(for: ["result", "structuredContent", "logs"]) == nil)
        }
    }

    @Test func streamableHTTPBindsReviewStartToTransportSessionWhenArgumentIsOmitted() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
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

            #expect(resolved.value(for: ["result", "structuredContent", "jobId"]) as? String == "job-1")
            let commands = await backend.recordedCommands()
            #expect(commands.contains(.startReview(.init(
                jobID: "job-1",
                sessionID: sessionID,
                request: .init(cwd: "/tmp/project", target: .custom(instructions: "Focus on test coverage."))
            ))))
        }
    }

    @Test func streamableHTTPReportsFailedReviewStartAsToolError() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
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
            #expect(resolved.value(for: ["result", "structuredContent", "jobId"]) as? String == "job-1")
            #expect(resolved.value(for: ["result", "structuredContent", "lifecycle", "status"]) as? String == "failed")
            #expect(resolved.value(for: ["result", "structuredContent", "lifecycle", "terminal", "kind"]) as? String == "failed")
            #expect(resolved.value(for: ["result", "structuredContent", "lifecycle", "terminal", "message"]) as? String == "Backend failed")
        }
    }

    @Test func streamableHTTPFiltersReviewListBySessionAndCWD() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let included = CodexReviewJob.makeForTesting(
                id: "job-included",
                sessionID: sessionID,
                cwd: "/tmp/project",
                targetSummary: "Uncommitted changes",
                status: .succeeded,
                summary: "Done"
            )
            let otherSession = CodexReviewJob.makeForTesting(
                id: "job-other-session",
                sessionID: "other-session",
                cwd: "/tmp/project",
                targetSummary: "Uncommitted changes",
                status: .succeeded,
                summary: "Done"
            )
            let otherWorkspace = CodexReviewJob.makeForTesting(
                id: "job-other-workspace",
                sessionID: sessionID,
                cwd: "/tmp/other",
                targetSummary: "Uncommitted changes",
                status: .succeeded,
                summary: "Done"
            )
            store.loadForTesting(
                serverState: .running,
                workspaces: [
                    .init(cwd: "/tmp/project"),
                    .init(cwd: "/tmp/other"),
                ],
                jobs: [included, otherSession, otherWorkspace]
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
            #expect(items.compactMap { $0["jobId"] as? String } == ["job-included"])
        }
    }

    @Test func streamableHTTPEncodesEveryLifecycleTerminalShape() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            @MainActor func job(
                id: String,
                status: ReviewJobState,
                cancellation: ReviewCancellation? = nil,
                terminal: ReviewTerminalRecord?
            ) -> CodexReviewJob {
                let job = CodexReviewJob.makeForTesting(
                    id: id,
                    sessionID: sessionID,
                    cwd: "/tmp/project",
                    targetSummary: id,
                    status: status,
                    cancellation: cancellation,
                    summary: id,
                    errorMessage: status == .failed ? id : nil
                )
                job.core.lifecycle.terminal = terminal
                return job
            }

            let requested = ReviewCancellation.mcpClient(message: "Stop")
            let jobs = [
                job(id: "running", status: .running, terminal: nil),
                job(id: "completed", status: .succeeded, terminal: .completed),
                job(id: "failed-null", status: .failed, terminal: .failed(message: nil)),
                job(id: "failed-message", status: .failed, terminal: .failed(message: "Failure")),
                job(id: "server", status: .failed, terminal: .interrupted(.server(message: nil))),
                job(id: "transport", status: .failed, terminal: .interrupted(.transport(message: "Disconnected"))),
                job(id: "previous", status: .failed, terminal: .interrupted(.previousProcessExit)),
                job(
                    id: "requested",
                    status: .cancelled,
                    cancellation: requested,
                    terminal: .interrupted(.requested(requested))
                ),
            ]
            store.loadForTesting(
                serverState: .running,
                workspaces: [.init(cwd: "/tmp/project")],
                jobs: jobs
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
                        "arguments": ["limit": 20],
                    ],
                ]
            )
            let items = try #require(
                response.value(for: ["result", "structuredContent", "items"])
                    as? [[String: Any]]
            )
            let itemsByID = Dictionary(uniqueKeysWithValues: items.compactMap { item in
                (item["jobId"] as? String).map { ($0, item) }
            })
            func terminal(_ id: String) throws -> [String: Any]? {
                let item = try #require(itemsByID[id])
                let lifecycle = try #require(item["lifecycle"] as? [String: Any])
                if lifecycle["terminal"] is NSNull {
                    return nil
                }
                return try #require(lifecycle["terminal"] as? [String: Any])
            }

            #expect(try terminal("running") == nil)
            #expect(try terminal("completed")?["kind"] as? String == "completed")
            #expect(try terminal("failed-null")?["kind"] as? String == "failed")
            #expect(try terminal("failed-null")?["message"] is NSNull)
            #expect(try terminal("failed-message")?["message"] as? String == "Failure")

            let serverCause = try #require(terminal("server")?["cause"] as? [String: Any])
            #expect(serverCause["kind"] as? String == "server")
            #expect(serverCause["source"] is NSNull)
            #expect(serverCause["message"] is NSNull)
            let transportCause = try #require(terminal("transport")?["cause"] as? [String: Any])
            #expect(transportCause["kind"] as? String == "transport")
            #expect(transportCause["message"] as? String == "Disconnected")
            let previousCause = try #require(terminal("previous")?["cause"] as? [String: Any])
            #expect(previousCause["kind"] as? String == "previousProcessExit")
            #expect(previousCause["message"] is NSNull)
            let requestedCause = try #require(terminal("requested")?["cause"] as? [String: Any])
            #expect(requestedCause["kind"] as? String == "requested")
            #expect(requestedCause["source"] as? String == "mcpClient")
            #expect(requestedCause["message"] as? String == "Stop")
        }
    }

    @Test func streamableHTTPScopesReviewReadToTransportSession() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            store.loadForTesting(
                serverState: .running,
                workspaces: [.init(cwd: "/tmp/project")],
                jobs: [
                    CodexReviewJob.makeForTesting(
                        id: "job-in-session",
                        sessionID: sessionID,
                        cwd: "/tmp/project",
                        targetSummary: "Included",
                        status: .succeeded,
                        summary: "Done",
                        logEntries: [
                            .init(kind: .command, groupID: "cmd-1", text: "$ swift test"),
                            .init(kind: .commandOutput, groupID: "cmd-1", text: "Tests passed"),
                            .init(kind: .agentMessage, text: "No correctness issues found."),
                        ]
                    ),
                    CodexReviewJob.makeForTesting(
                        id: "job-other-session",
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
                        "arguments": ["jobId": "job-in-session"],
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
                        "arguments": ["jobID": "job-other-session"],
                    ],
                ]
            )
            let allLogs = try await postJSONRPC(
                endpoint: await server.url,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 4,
                    "method": "tools/call",
                    "params": [
                        "name": "review_read",
                        "arguments": [
                            "jobId": "job-in-session",
                            "logFilter": "all",
                        ],
                    ],
                ]
            )

            #expect(allowed.value(for: ["result", "isError"]) as? Bool == false)
            #expect(allowed.value(for: ["result", "structuredContent", "jobId"]) as? String == "job-in-session")
            let defaultLogs = allowed.value(for: ["result", "structuredContent", "logs"]) as? [[String: Any]]
            #expect(defaultLogs?.compactMap { $0["kind"] as? String } == ["command", "agentMessage"])
            #expect(allowed.value(for: ["result", "structuredContent", "logsPage", "total"]) as? Int == 2)
            #expect(allowed.value(for: ["result", "structuredContent", "logsPage", "offset"]) as? Int == 0)
            #expect(allowed.value(for: ["result", "structuredContent", "logsPage", "limit"]) as? Int == 100)
            #expect(allowed.value(for: ["result", "structuredContent", "logsPage", "returned"]) as? Int == 2)
            let unfilteredLogs = allLogs.value(for: ["result", "structuredContent", "logs"]) as? [[String: Any]]
            #expect(unfilteredLogs?.compactMap { $0["kind"] as? String } == [
                "command",
                "commandOutput",
                "agentMessage",
            ])
            let readText = (allowed.value(for: ["result", "content"]) as? [[String: Any]])?.first?["text"] as? String
            #expect(readText == "Done")
            #expect(readText?.contains("rawLogText") == false)
            #expect(denied.value(for: ["result", "isError"]) as? Bool == true)
            #expect((denied.value(for: ["result", "content"]) as? [[String: Any]])?.first?["text"] as? String == "Job job-other-session was not found.")
        }
    }

    @Test func streamableHTTPReviewReadReturnsPagedRunningSummary() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            clock: .init(now: { Date(timeIntervalSince1970: 10) })
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let longLatest = "latest " + String(repeating: "x", count: 400)
            let entries = (0..<119).map { index in
                ReviewLogEntry(kind: .progress, text: "line-\(index)")
            } + [
                ReviewLogEntry(kind: .progress, text: longLatest),
            ]
            store.loadForTesting(
                serverState: .running,
                workspaces: [.init(cwd: "/tmp/project")],
                jobs: [
                    CodexReviewJob.makeForTesting(
                        id: "job-running",
                        sessionID: sessionID,
                        cwd: "/tmp/project",
                        targetSummary: "Running",
                        status: .running,
                        startedAt: Date(timeIntervalSince1970: 5),
                        summary: "Review started.",
                        logEntries: entries
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
                        "name": "review_read",
                        "arguments": [
                            "jobId": "job-running",
                            "logLimit": 5,
                        ],
                    ],
                ]
            )

            let logs = try #require(response.value(for: ["result", "structuredContent", "logs"]) as? [[String: Any]])
            let readText = try #require((response.value(for: ["result", "content"]) as? [[String: Any]])?.first?["text"] as? String)
            #expect(logs.compactMap { $0["text"] as? String }.first == "line-115")
            #expect(logs.count == 5)
            #expect(response.value(for: ["result", "structuredContent", "logsPage", "total"]) as? Int == 120)
            #expect(response.value(for: ["result", "structuredContent", "logsPage", "offset"]) as? Int == 115)
            #expect(response.value(for: ["result", "structuredContent", "logsPage", "limit"]) as? Int == 5)
            #expect(response.value(for: ["result", "structuredContent", "logsPage", "returned"]) as? Int == 5)
            #expect(response.value(for: ["result", "structuredContent", "logsPage", "hasMoreBefore"]) as? Bool == true)
            #expect(response.value(for: ["result", "structuredContent", "logsPage", "hasMoreAfter"]) as? Bool == false)
            #expect(response.value(for: ["result", "structuredContent", "logsPage", "previousOffset"]) as? Int == 110)
            #expect(response.value(for: ["result", "structuredContent", "logsPage", "nextOffset"]) is NSNull)
            #expect(readText.hasPrefix("Review running for 5s. Returned logs 116-120 of 120. Latest: latest "))
            #expect(readText.count < longLatest.count)
            #expect(readText.contains("Review started.") == false)
        }
    }

    @Test func streamableHTTPReviewReadRejectsInvalidPagingArguments() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            store.loadForTesting(
                serverState: .running,
                workspaces: [.init(cwd: "/tmp/project")],
                jobs: [
                    CodexReviewJob.makeForTesting(
                        id: "job-running",
                        sessionID: sessionID,
                        cwd: "/tmp/project",
                        targetSummary: "Running",
                        status: .running,
                        summary: "Review started."
                    ),
                ]
            )

            let negativeOffset = try await postJSONRPC(
                endpoint: await server.url,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/call",
                    "params": [
                        "name": "review_read",
                        "arguments": [
                            "jobId": "job-running",
                            "logOffset": -1,
                        ],
                    ],
                ]
            )
            let tooLargeLimit = try await postJSONRPC(
                endpoint: await server.url,
                sessionID: sessionID,
                body: [
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "tools/call",
                    "params": [
                        "name": "review_read",
                        "arguments": [
                            "jobId": "job-running",
                            "logLimit": CodexReviewAPI.Log.PageRequest.maxLimit + 1,
                        ],
                    ],
                ]
            )

            #expect(negativeOffset.value(for: ["result", "isError"]) as? Bool == true)
            #expect((negativeOffset.value(for: ["result", "content"]) as? [[String: Any]])?.first?["text"] as? String == "logOffset must be greater than or equal to 0.")
            #expect(tooLargeLimit.value(for: ["result", "isError"]) as? Bool == true)
            #expect((tooLargeLimit.value(for: ["result", "content"]) as? [[String: Any]])?.first?["text"] as? String == "logLimit must be between 1 and 500.")
        }
    }

    @Test func streamableHTTPCancelsReviewByTransportScopedSelector() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let running = CodexReviewJob.makeForTesting(
                id: "job-running",
                sessionID: sessionID,
                cwd: "/tmp/project",
                targetSummary: "Uncommitted changes",
                threadID: "thread-1",
                turnID: "turn-1",
                status: .running,
                summary: "Running"
            )
            let otherSession = CodexReviewJob.makeForTesting(
                id: "job-other-session",
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
                workspaces: [.init(cwd: "/tmp/project")],
                jobs: [running, otherSession]
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

            #expect(response.value(for: ["result", "structuredContent", "jobId"]) as? String == "job-running")
            #expect(response.value(for: ["result", "structuredContent", "cancelled"]) as? Bool == true)
            #expect(response.value(for: ["result", "structuredContent", "lifecycle", "terminal", "kind"]) as? String == "interrupted")
            #expect(response.value(for: ["result", "structuredContent", "lifecycle", "terminal", "cause", "kind"]) as? String == "requested")
            #expect(response.value(for: ["result", "structuredContent", "lifecycle", "terminal", "cause", "source"]) as? String == "mcpClient")
            #expect(response.value(for: ["result", "structuredContent", "lifecycle", "terminal", "cause", "message"]) as? String == "Stop from MCP")
            #expect(running.core.lifecycle.status == .cancelled)
            #expect(running.core.lifecycle.cancellation?.message == "Stop from MCP")
            #expect(otherSession.cancellationRequested == false)
            let commands = await backend.recordedCommands()
            #expect(commands.contains(.interruptReview(
                .init(threadID: "thread-1", turnID: "turn-1", reviewThreadID: "thread-1", model: "gpt-5"),
                .init(message: "Stop from MCP")
            )))
        }
    }

    @Test func streamableHTTPCancelDefaultsSelectorToActiveJobsInTransportSession() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let completed = CodexReviewJob.makeForTesting(
                id: "job-completed",
                sessionID: sessionID,
                cwd: "/tmp/project",
                targetSummary: "Completed",
                threadID: "thread-completed",
                turnID: "turn-completed",
                status: .succeeded,
                summary: "Done"
            )
            let running = CodexReviewJob.makeForTesting(
                id: "job-running",
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
                workspaces: [.init(cwd: "/tmp/project")],
                jobs: [completed, running]
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

            #expect(response.value(for: ["result", "structuredContent", "jobId"]) as? String == "job-running")
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
                workspaces: [.init(cwd: "/tmp/project")],
                jobs: [
                    CodexReviewJob.makeForTesting(
                        id: "job-running-1",
                        sessionID: sessionID,
                        cwd: "/tmp/project",
                        targetSummary: "First",
                        threadID: "thread-1",
                        turnID: "turn-1",
                        status: .running,
                        summary: "Running"
                    ),
                    CodexReviewJob.makeForTesting(
                        id: "job-running-2",
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
            #expect(text?.contains("matched multiple jobs") == true)
            #expect(text?.contains("job-running-1") == true)
            #expect(text?.contains("job-running-2") == true)
        }
    }

    @Test func streamableHTTPCancelsDocumentedJobId() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let running = CodexReviewJob.makeForTesting(
                id: "job-running",
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
                workspaces: [.init(cwd: "/tmp/project")],
                jobs: [running]
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
                            "jobId": "job-running",
                            "reason": "Stop from MCP",
                        ],
                    ],
                ]
            )

            #expect(response.value(for: ["result", "structuredContent", "jobId"]) as? String == "job-running")
            #expect(running.core.lifecycle.status == .cancelled)
        }
    }

    @Test func streamableHTTPDoesNotExpireSessionWithActiveReviewRequest() async throws {
        let backend = FakeCodexReviewBackend()
        let gate = AsyncGate()
        await backend.holdStartReview(with: gate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
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

            #expect(resolved.value(for: ["result", "structuredContent", "jobId"]) as? String == "job-1")
            #expect(resolved.value(for: ["result", "structuredContent", "logs"]) == nil)
            #expect(resolved.value(for: ["result", "structuredContent", "rawLogText"]) == nil)
            let startText = (resolved.value(for: ["result", "content"]) as? [[String: Any]])?.first?["text"] as? String
            #expect(startText == "review text")
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

    @Test func streamableHTTPKeepsJobIDCancellationInTransportSession() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        try await withHTTPServer(store: store) { server in
            let sessionID = try await initializeSession(endpoint: await server.url)
            let other = CodexReviewJob.makeForTesting(
                id: "job-other-session",
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
                workspaces: [.init(cwd: "/tmp/project")],
                jobs: [other]
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
                            "jobID": "job-other-session",
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
            let running = CodexReviewJob.makeForTesting(
                id: "job-running",
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
                workspaces: [.init(cwd: "/tmp/project")],
                jobs: [running]
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
                        "uri": "codex-review://help/targets/custom",
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
            #expect(templates.compactMap { $0["uriTemplate"] as? String } == [
                "codex-review://help/tools/{tool}",
                "codex-review://help/targets/{target}",
            ])
        }
    }

    private func lifecycleError(
        operation: () async throws -> Void
    ) async -> CodexReviewMCPHTTPServer.LifecycleError? {
        do {
            try await operation()
            return nil
        } catch let error as CodexReviewMCPHTTPServer.LifecycleError {
            return error
        } catch {
            Issue.record("Unexpected lifecycle error: \(error)")
            return nil
        }
    }

    private func makeHTTPServer(
        configuration: CodexReviewMCPHTTPServer.Configuration = .init(
            host: "127.0.0.1",
            port: 0
        )
    ) -> CodexReviewMCPHTTPServer {
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        )
        return CodexReviewMCPHTTPServer(
            adapter: CodexReviewMCPServer(store: store),
            configuration: configuration
        )
    }

    private func withHTTPServer<T>(
        store: CodexReviewStore,
        configuration: CodexReviewMCPHTTPServer.Configuration = .init(
            host: "127.0.0.1",
            port: 0
        ),
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
            try await server.stop()
            return result
        } catch {
            try? await server.stop()
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

    private func makeToolsListBody(id: Int) throws -> Data {
        try makeJSONBody([
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/list",
        ])
    }

    private func makeReviewStartBody(id: Int) throws -> Data {
        try makeJSONBody([
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": [
                "name": "review_start",
                "arguments": [
                    "cwd": "/tmp/project",
                    "target": ["type": "uncommittedChanges"],
                ],
            ],
        ])
    }

    private func rawHTTPRequest(
        endpoint: URL,
        method: String = "POST",
        version: String = "HTTP/1.1",
        sessionID: String?,
        headers: [(String, String)] = [],
        body: Data? = nil
    ) throws -> Data {
        let components = try #require(URLComponents(url: endpoint, resolvingAgainstBaseURL: false))
        let host = try #require(components.host)
        let port = try #require(components.port)
        var requestHeaders: [(String, String)] = [
            ("Host", "\(host):\(port)"),
        ]
        if method == "POST" {
            requestHeaders.append(("Content-Type", "application/json"))
            requestHeaders.append(("Accept", "text/event-stream, application/json"))
        }
        if let sessionID {
            requestHeaders.append(("MCP-Session-Id", sessionID))
        }
        requestHeaders.append(contentsOf: headers)
        let hasFramingHeader = requestHeaders.contains { name, _ in
            name.caseInsensitiveCompare("Content-Length") == .orderedSame
                || name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame
        }
        if let body, hasFramingHeader == false {
            requestHeaders.append(("Content-Length", "\(body.count)"))
        }

        let serializedHeaders = requestHeaders
            .map { "\($0.0): \($0.1)\r\n" }
            .joined()
        var request = Data(
            "\(method) \(endpoint.path) \(version)\r\n\(serializedHeaders)\r\n".utf8
        )
        if let body {
            request.append(body)
        }
        return request
    }

    private func canonicalJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
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
        let payload = try #require(text
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

private final class RawHTTPConnection: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var bufferedInput = Data()
    private var isClosed = false

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func connect(to endpoint: URL) async throws -> RawHTTPConnection {
        let components = try #require(URLComponents(url: endpoint, resolvingAgainstBaseURL: false))
        let host = try #require(components.host)
        let ipv4Host = host == "localhost" ? "127.0.0.1" : host
        let port = try #require(components.port)
        return try await Task.detached {
            let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                throw currentPOSIXError()
            }
            do {
                var noSignal = Int32(1)
                _ = withUnsafePointer(to: &noSignal) {
                    Darwin.setsockopt(
                        descriptor,
                        SOL_SOCKET,
                        SO_NOSIGPIPE,
                        $0,
                        socklen_t(MemoryLayout<Int32>.size)
                    )
                }
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                _ = withUnsafePointer(to: &timeout) {
                    Darwin.setsockopt(
                        descriptor,
                        SOL_SOCKET,
                        SO_RCVTIMEO,
                        $0,
                        socklen_t(MemoryLayout<timeval>.size)
                    )
                }

                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = in_port_t(port).bigEndian
                guard inet_pton(AF_INET, ipv4Host, &address.sin_addr) == 1 else {
                    throw testError("Unable to resolve IPv4 loopback host \(host)")
                }
                let connected = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(
                            descriptor,
                            $0,
                            socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                }
                guard connected == 0 else {
                    throw currentPOSIXError()
                }
                return RawHTTPConnection(descriptor: descriptor)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }.value
    }

    func send(_ bytes: Data) async throws {
        let descriptor = self.descriptor
        try await Task.detached {
            try bytes.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return
                }
                var sent = 0
                while sent < rawBuffer.count {
                    let count = Darwin.send(
                        descriptor,
                        baseAddress.advanced(by: sent),
                        rawBuffer.count - sent,
                        0
                    )
                    if count < 0, errno == EINTR {
                        continue
                    }
                    guard count > 0 else {
                        throw currentPOSIXError()
                    }
                    sent += count
                }
            }
        }.value
    }

    func readResponseHead() async throws -> String {
        let descriptor = self.descriptor
        var bytes = lock.withLock {
            defer { bufferedInput.removeAll(keepingCapacity: false) }
            return bufferedInput
        }
        let terminator = Data("\r\n\r\n".utf8)
        let result = try await Task.detached {
            while let range = bytes.range(of: terminator) {
                let head = Data(bytes[..<range.upperBound])
                let remainder = Data(bytes[range.upperBound...])
                return (head, remainder)
            }
            while true {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    if count == 0 {
                        throw testError("Connection closed before the response head completed")
                    }
                    throw currentPOSIXError()
                }
                bytes.append(contentsOf: buffer.prefix(count))
                if let range = bytes.range(of: terminator) {
                    let head = Data(bytes[..<range.upperBound])
                    let remainder = Data(bytes[range.upperBound...])
                    return (head, remainder)
                }
            }
        }.value
        lock.withLock {
            bufferedInput = result.1 + bufferedInput
        }
        return String(decoding: result.0, as: UTF8.self)
    }

    func readUntilEOF() async throws -> Data {
        let descriptor = self.descriptor
        var bytes = lock.withLock {
            defer { bufferedInput.removeAll(keepingCapacity: false) }
            return bufferedInput
        }
        return try await Task.detached {
            while true {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
                if count < 0, errno == EINTR {
                    continue
                }
                if count == 0 {
                    return bytes
                }
                guard count > 0 else {
                    throw currentPOSIXError()
                }
                bytes.append(contentsOf: buffer.prefix(count))
            }
        }.value
    }

    func close() {
        let shouldClose = lock.withLock {
            guard isClosed == false else {
                return false
            }
            isClosed = true
            return true
        }
        if shouldClose {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
    }

    func reset() {
        let shouldClose = lock.withLock {
            guard isClosed == false else { return false }
            isClosed = true
            return true
        }
        if shouldClose {
            var option = linger(l_onoff: 1, l_linger: 0)
            _ = withUnsafePointer(to: &option) {
                Darwin.setsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_LINGER,
                    $0,
                    socklen_t(MemoryLayout<linger>.size)
                )
            }
            Darwin.close(descriptor)
        }
    }

    deinit {
        close()
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
