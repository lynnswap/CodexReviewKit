import Foundation
import Synchronization
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

    @Test func reasoningTextCoalescesDuplicateFragmentsAndKeepsMarkdownBlocks() {
        let review = """
        **Reviewing inspection needs**

        I need to inspect the changes.
        """
        let slowness = """
        **Investigating potential slowness**

        I need to inspect the running command.
        """

        let reasoning = CodexReasoning(
            summary: [
                review,
                review,
                slowness,
                slowness,
            ],
            content: ["raw", "raw"]
        )

        #expect(reasoning.summary == [review, slowness])
        #expect(reasoning.content == ["raw"])
        #expect(reasoning.text == "\(review)\n\n\(slowness)")
    }

    @Test func localProcessConfigurationResolvesExplicitExecutableCommandNames() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let executableURL = binURL.appendingPathComponent("codex")
        try """
            #!/bin/sh
            exit 0
            """
            .write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let configuration = AppServerProcessTransport.Configuration(
            executable: "codex",
            environment: ["PATH": binURL.path],
            codexHomeURL: rootURL.appendingPathComponent("codex-home", isDirectory: true)
        )

        #expect(configuration.executable == executableURL.path)
        #expect(configuration.arguments == [
            "-c",
            CodexAppServerExecutable.fileBackedAuthConfiguration,
            "app-server",
            "--listen",
            "stdio://",
        ])
    }

    @Test func localProcessConfigurationResolvesStandaloneInstallerExecutableOutsidePATH() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
        let binURL = homeURL.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let executableURL = binURL.appendingPathComponent("codex")
        try """
            #!/bin/sh
            exit 0
            """
            .write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let configuration = AppServerProcessTransport.Configuration(
            environment: [
                "HOME": homeURL.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ],
            codexHomeURL: rootURL.appendingPathComponent("codex-home", isDirectory: true)
        )

        #expect(configuration.executable == executableURL.path)
    }

    @Test func processTransportAnswersServerInitiatedRequestsThroughConfiguredHandler() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let responseURL = rootURL.appendingPathComponent("response.json")
        let executableURL = rootURL.appendingPathComponent("fake-app-server")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try """
            #!/bin/sh
            printf '%s\\n' '{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":123}}'
            IFS= read -r line
            printf '%s\\n' "$line" > "$RESPONSE_PATH"
            """
            .write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let recorder = ServerRequestRecorder()
        let transport = try AppServerProcessTransport(
            configuration: .init(
                executable: executableURL.path,
                arguments: [],
                environment: ["RESPONSE_PATH": responseURL.path],
                codexHomeURL: rootURL.appendingPathComponent("codex-home", isDirectory: true)
            ),
            connectionEventHub: ConnectionEventHub()
        )
        let harness = await CodexAppServerTestConnectionHarness.start(
            transport: transport,
            processTerminationToken: transport.processTerminationToken,
            handler: { request in
                await recorder.append(request)
                return .approval(.accept)
            }
        )

        let wroteResponse = await eventually(attempts: 100) {
            FileManager.default.fileExists(atPath: responseURL.path)
        }
        #expect(wroteResponse)

        let request = try #require(await recorder.requests().first)
        #expect(request.method == "item/commandExecution/requestApproval")
        guard case .commandExecutionApproval(let approval) = request else {
            Issue.record("Expected a command execution approval request.")
            return
        }
        #expect(approval.threadID == "thread-1")
        #expect(approval.turnID == "turn-1")
        #expect(approval.itemID == "item-1")
        #expect(approval.startedAtMs == 123)

        let responseData = try Data(contentsOf: responseURL)
        let response = try #require(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        #expect(response["id"] as? String == "approval-1")
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["decision"] as? String == "accept")
        await harness.close()
    }

    @Test func processSpawnClosePlanPreservesStandardIOFileDescriptors() {
        let closeDescriptors = AppServerProcessFileDescriptorPlan
            .childPipeDescriptorsToClose([0, 1, 2, 3, 4, 5])

        #expect(closeDescriptors == [3, 4, 5])
    }

    @Test func testRuntimeStartsAppServerWithoutLaunchingProcess() async throws {
        let runtime = try await CodexAppServerTestRuntime.start(configuration: .init(
            localProcess: .init(
                codexHomeURL: URL(fileURLWithPath: "/tmp/codex", isDirectory: true)
            )
        ))
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
        await runtime.close()
    }

    @Test func publicConfigurationRoutesTypedServerRequestsToTheHost() async throws {
        let configuration = CodexAppServer.Configuration { request in
            guard case .commandExecutionApproval(let approval) = request else {
                return try await CodexAppServer.Configuration.defaultServerRequestHandler(
                    request: request
                )
            }
            #expect(approval.command == "git status")
            return .approval(.accept)
        }
        let runtime = try await CodexAppServerTestRuntime.start(configuration: configuration)
        let requestID = CodexServerRequestID.string("approval-public-handler")

        try await runtime.transport.emitServerRequest(
            id: requestID,
            method: "item/commandExecution/requestApproval",
            params: Data(
                #"{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":123,"command":"git status"}"#.utf8
            )
        )

        let response = await runtime.transport.serverRequestResponse(for: requestID)
        #expect(response == .result(Data(#"{"decision":"accept"}"#.utf8)))
        await runtime.close()
    }

    @Test func testRuntimeUsesTypedConfigurationFixtures() async throws {
        let configURL = URL(fileURLWithPath: "/tmp/codex/config.toml")
        let layerMetadata = try CodexAppServerTestConfigurationLayerMetadata(
            source: .user(file: configURL, profile: nil),
            version: "config-v1"
        )
        let result = try CodexAppServerTestConfigurationReadResult(
            configuration: .init(
                model: "gpt-5-codex",
                reviewModel: "gpt-5-codex-review",
                reasoningEffort: .high,
                serviceTier: "flex"
            ),
            origins: ["model": layerMetadata],
            layers: [try .init(
                metadata: layerMetadata,
                configuration: .object(["model": .string("gpt-5-codex")])
            )]
        )
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueConfiguration(result)

        let configuration = try await runtime.server.configuration()

        #expect(configuration == result.configuration)
        #expect(
            await runtime.transport.recordedRequests(for: .configurationRead).map(\.request)
                == [.configurationRead]
        )
        await runtime.close()
    }

    @Test func typedConfigurationWriteFixturePreservesOverrideContract() async throws {
        let configURL = URL(fileURLWithPath: "/tmp/codex/config.toml")
        let layerMetadata = try CodexAppServerTestConfigurationLayerMetadata(
            source: .system(file: URL(fileURLWithPath: "/etc/codex/managed.toml")),
            version: "managed-v1"
        )
        let writeResult = try CodexAppServerTestConfigurationWriteResult(
            status: .okOverridden,
            version: "config-v2",
            fileURL: configURL,
            overriddenMetadata: try .init(
                message: "Managed configuration overrides this value.",
                overridingLayer: layerMetadata,
                effectiveValue: .string("gpt-5-codex")
            )
        )
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueConfigurationWrite(writeResult)
        var patch = CodexConfigurationPatch()
        patch.setReviewModel("gpt-5-codex-review")

        try await runtime.server.updateConfiguration(patch)

        let request = try #require(
            await runtime.transport.recordedRequests(for: .configurationUpdate).last
        )
        #expect(request.request == .configurationUpdate(patch))
        await runtime.close()
    }

    @Test func configurationFixturesRejectInvalidOwnershipMetadata() throws {
        #expect(throws: CodexAppServerTestError.invalidFixture(
            "configuration layer file must be an absolute file URL"
        )) {
            _ = try CodexAppServerTestConfigurationLayerMetadata(
                source: .system(file: URL(string: "https://example.com/config.toml")!),
                version: "config-v1"
            )
        }

        let configURL = URL(fileURLWithPath: "/tmp/codex/config.toml")
        #expect(throws: CodexAppServerTestError.invalidFixture(
            "an overridden configuration write requires override metadata"
        )) {
            _ = try CodexAppServerTestConfigurationWriteResult(
                status: .okOverridden,
                version: "config-v1",
                fileURL: configURL
            )
        }
    }

    @Test func manualDeadlineClockResumesOnlyAfterExplicitAdvance() async throws {
        let clock = CodexAppServerTestDeadlineClock()
        let sleeper = Task {
            try await clock.codexDeadlineClock.sleep(.seconds(5))
        }

        try await clock.waitForSleeperCount(1)
        clock.advance(by: .seconds(5))
        try await sleeper.value
        clock.close()
    }

    @Test func testTransportHoldsRequestsAtExplicitGate() async throws {
        let transport = CodexAppServerTestTransport()
        let gate = CodexAppServerTestGate()
        await transport.holdNext(method: "ping", gate: gate)
        try await transport.enqueueEmpty(for: "ping")
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client

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
        await harness.close()
    }

    @Test func testGateCancellationThrowsAndRemovesItsWaiter() async throws {
        let gate = CodexAppServerTestGate()
        let task = Task {
            try await gate.wait()
        }
        await gate.waitUntilBlocked()

        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        await gate.open()

        let closedGate = CodexAppServerTestGate()
        await closedGate.close()
        await #expect(throws: CancellationError.self) {
            try await closedGate.wait()
        }
    }

    @Test func unstubbedTestTransportRequestFailsWithRequestIdentity() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)

        do {
            let _: EmptyResponse = try await harness.client.send(
                method: "unstubbed/probe",
                params: EmptyResponse(),
                responseType: EmptyResponse.self
            )
            Issue.record("Expected an unstubbed test transport request to fail.")
        } catch let error as CodexAppServerError {
            guard case .request(let failure) = error else {
                Issue.record("Expected a typed request failure, got \(error).")
                return
            }
            #expect(failure.requestID == 1)
            #expect(failure.method == "unstubbed/probe")
            #expect(failure.purpose == .operation("unstubbed/probe"))
            #expect(failure.kind == .transport(.contractViolation(
                message: "No test response is configured for unstubbed/probe."
            )))
        }

        await harness.close()
    }

    @Test func testTransportReservesQueuedResponseBeforeGateWait() async throws {
        struct PingResponse: Codable, Equatable, Sendable {
            var value: String
        }

        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(PingResponse(value: "first"), for: "ping")
        try await transport.enqueue(PingResponse(value: "second"), for: "ping")
        let gate = CodexAppServerTestGate()
        await transport.holdNext(method: "ping", gate: gate)
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client

        let first = Task {
            try await client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: PingResponse.self
            )
        }
        await transport.waitForRequest(method: "ping")

        let second = Task {
            try await client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: PingResponse.self
            )
        }

        #expect(try await second.value == PingResponse(value: "second"))
        await gate.open()
        #expect(try await first.value == PingResponse(value: "first"))
        await harness.close()
    }

    @Test func initializeSendsHandshakeAndInitializedNotification() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Initialize.Response(codexHome: "/tmp/codex"), for: "initialize")
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client

        let response = try await client.initialize(clientName: "TestClient", clientVersion: "1")

        #expect(response.codexHome == "/tmp/codex")
        #expect(await transport.recordedRequests().map(\.method) == ["initialize"])
        #expect(await transport.recordedNotifications().map(\.method) == ["initialized"])
        let params = try #require(await transport.recordedRequests().first?.params)
        let decoded = try JSONDecoder().decode(AppServerAPI.Initialize.Params.self, from: params)
        #expect(decoded.clientInfo.name == "TestClient")
        #expect(decoded.clientInfo.version == "1")
        await harness.close()
    }

    @Test func concurrentInitializeCallsShareOneHandshake() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Initialize.Response(codexHome: "/tmp/codex"), for: "initialize")
        let gate = CodexAppServerTestGate()
        await transport.hold(method: "initialize", gate: gate)
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client

        let first = Task {
            try await client.initialize(clientName: "TestClient", clientVersion: "1")
        }
        await transport.waitForRequest(method: "initialize")
        let gateOpener = Task {
            do {
                try await withTimeout {
                    while await client.initializationWaiterCountForTesting() == 0 {
                        await Task.yield()
                    }
                }
            } catch {
                await gate.open()
                throw error
            }
            await gate.open()
        }

        let secondResponse = try await client.initialize(
            clientName: "TestClient",
            clientVersion: "1"
        )
        let firstResponse = try await first.value
        try await gateOpener.value

        #expect(firstResponse == secondResponse)
        #expect(await transport.recordedRequests(method: "initialize").count == 1)
        #expect(await transport.recordedNotifications().map(\.method) == ["initialized"])
        await harness.close()
    }

    @Test func appServerClosesTransportWhenInitializationFails() async throws {
        let transport = CodexAppServerTestTransport()
        await transport.enqueueFailure(code: -32000, message: "initialize failed", for: "initialize")

        do {
            _ = try await CodexAppServer.testing(transport: transport)
            Issue.record("Expected initialization failure.")
        } catch {
            #expect(await transport.isClosedForTesting())
        }
    }

    @Test func appServerStartThreadSerializesDomainOptions() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"),
            for: "thread/start"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let server = harness.server
        let workspace = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

        let thread = try await server.startThread(
            in: workspace,
            instructions: .init(base: "Base", developer: "Developer"),
            options: .init(
                model: "gpt-5",
                sandbox: .workspaceWrite,
                permissions: .profile(id: "codex-default"),
                ephemeral: true,
                config: ["experimental": .bool(true)],
                personality: .pragmatic,
                serviceName: "app-server-kit-test",
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
        #expect(params.permissions == .profileID("codex-default"))
        #expect(params.config == ["experimental": .bool(true)])
        #expect(params.personality == "pragmatic")
        #expect(params.serviceName == "app-server-kit-test")
        #expect(params.sessionStartSource == .startup)
        #expect(params.threadSource?.rawValue == "automation")
    }

    @Test func threadOptionWireValuesUseAppServerConfigSchema() {
        #expect(CodexApprovalMode.autoReview.approvalPolicy == "on-request")
        #expect(CodexApprovalMode.denyAll.approvalPolicy == "never")
        #expect(CodexSandbox.readOnly.threadSandboxValue == "read-only")
        #expect(CodexSandbox.workspaceWrite.threadSandboxValue == "workspace-write")
        #expect(CodexSandbox.fullAccess.threadSandboxValue == "danger-full-access")
    }

    @Test func appServerResumeThreadPreservesServerReturnedModel() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(
            .init(
                id: "thread-1",
                workspace: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
            ),
            model: "gpt-5"
        )

        let thread = try await runtime.server.resumeThread("thread-1")

        #expect(thread.id == "thread-1")
        #expect(thread.model == "gpt-5")
        let request = try #require(await runtime.transport.recordedRequests().last)
        let params = try request.decodeParams(AppServerAPI.Thread.Resume.Params.self)
        #expect(params.threadID == "thread-1")
        #expect(params.model == nil)
    }

    @Test func resumedThreadSeedsNestedTerminalReceivedBeforeResumeResponse() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let gate = CodexAppServerTestGate()
        try await runtime.transport.enqueueThreadResume(.init(
            id: "thread-resume-terminal",
            turns: [.init(id: "turn-resume-terminal", state: .inProgress)]
        ))
        await runtime.transport.holdNext(method: "thread/resume", gate: gate)

        let resumeTask = Task {
            try await runtime.server.resumeThread("thread-resume-terminal")
        }
        await runtime.transport.waitForRequest(method: "thread/resume")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-resume-terminal",
                turn: .init(
                    id: "turn-resume-terminal",
                    status: "completed"
                )
            )
        )
        await gate.open()
        let thread = try await resumeTask.value
        try await runtime.transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-resume-terminal")
        )

        let events = try await collect(thread.events)
        #expect(events.contains(.terminal(.completed(.init(
            turnID: "turn-resume-terminal",
            transcript: .init(),
            transcriptItemsLoadState: .full
        )))))
    }

    @Test func resumedThreadTransfersNestedProtocolViolationAfterAssociation() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let gate = CodexAppServerTestGate()
        try await runtime.transport.enqueueThreadResume(.init(
            id: "thread-resume-malformed",
            turns: [.init(id: "turn-resume-malformed", state: .inProgress)]
        ))
        await runtime.transport.holdNext(method: "thread/resume", gate: gate)

        let resumeTask = Task {
            try await runtime.server.resumeThread("thread-resume-malformed")
        }
        await runtime.transport.waitForRequest(method: "thread/resume")
        try await runtime.transport.emitServerNotificationJSON(
            method: "turn/completed",
            json: #"{"turn":{"id":"turn-resume-malformed"}}"#
        )
        await gate.open()
        let thread = try await resumeTask.value

        do {
            _ = try await collect(thread.events)
            Issue.record("Expected associated malformed terminal failure.")
        } catch let error as CodexAppServerError {
            guard case .connectionTerminated(.transportFailure(
                .protocolViolation(_, let rawData)
            )) = error else {
                Issue.record("Expected connection protocol violation, got \(error).")
                return
            }
            #expect(rawData == Data(#"{"turn":{"id":"turn-resume-malformed"}}"#.utf8))
        }
    }

    @Test func threadReadSeedsNestedTerminalReceivedBeforeReadResponse() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-read-terminal"))
        let thread = try await runtime.server.resumeThread("thread-read-terminal")
        let gate = CodexAppServerTestGate()
        try await runtime.transport.enqueueThreadRead(.init(
            id: "thread-read-terminal",
            turns: [.init(id: "turn-read-terminal", state: .inProgress)]
        ))
        await runtime.transport.holdNext(method: "thread/read", gate: gate)

        let readTask = Task { try await thread.read(includeTurns: true) }
        await runtime.transport.waitForRequest(method: "thread/read")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-read-terminal",
                turn: .init(id: "turn-read-terminal", status: "completed")
            )
        )
        await gate.open()
        _ = try await readTask.value
        try await runtime.transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-read-terminal")
        )

        let events = try await collect(thread.events)
        #expect(events.contains(.terminal(.completed(.init(
            turnID: "turn-read-terminal",
            transcript: .init(),
            transcriptItemsLoadState: .full
        )))))
    }

    @Test func turnListSeedsNestedTerminalReceivedBeforeListResponse() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-list-turns-terminal"))
        let thread = try await runtime.server.resumeThread("thread-list-turns-terminal")
        let gate = CodexAppServerTestGate()
        let listedTurn = try CodexAppServerTestTurn(
            snapshot: .init(id: "turn-list-turns-terminal", state: .inProgress),
            items: []
        )
        try await runtime.transport.enqueueThreadTurns(.init(turns: [listedTurn]))
        await runtime.transport.holdNext(method: "thread/turns/list", gate: gate)

        let listTask = Task { try await thread.listTurns() }
        await runtime.transport.waitForRequest(method: "thread/turns/list")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-list-turns-terminal",
                turn: .init(
                    id: "turn-list-turns-terminal",
                    status: "completed"
                )
            )
        )
        await gate.open()
        _ = try await listTask.value
        try await runtime.transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-list-turns-terminal")
        )

        let events = try await collect(thread.events)
        #expect(events.contains(.terminal(.completed(.init(
            turnID: "turn-list-turns-terminal",
            transcript: .init(),
            transcriptItemsLoadState: .full
        )))))
    }

    @Test func appServerStartReviewStartsThreadThenReview() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-source", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-source"
        )
        let workspace = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

        let review = try await runtime.server.startReview(
            in: workspace,
            target: .baseBranch("main"),
            instructions: .init(base: "Base", developer: "Developer"),
            options: .init(model: "gpt-5"),
            delivery: .inline
        )

        #expect(review.threadID == "thread-source")
        #expect(review.turnID == "turn-review")
        #expect(review.reviewThreadID == "thread-source")
        #expect(review.identity == CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            model: "gpt-5"
        ))

        let requests = await runtime.transport.recordedRequests()
        #expect(requests.map(\.method) == [
            "initialize",
            "thread/start",
            "review/start",
        ])
        let threadStart = try requests[1].decodeParams(AppServerAPI.Thread.Start.Params.self)
        #expect(threadStart.cwd == workspace.path)
        #expect(threadStart.model == "gpt-5")
        #expect(threadStart.baseInstructions == "Base")
        #expect(threadStart.developerInstructions == "Developer")

        let reviewStart = try requests[2].decodeParams(AppServerAPI.Review.Start.Params.self)
        #expect(reviewStart.threadID == "thread-source")
        #expect(reviewStart.target == .baseBranch("main"))
        #expect(reviewStart.delivery == .inline)
    }

    @Test func threadStartReviewTreatsReturnedSourceThreadIDAsInline() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "turn-review",
                reviewThreadID: "thread-1"
            ),
            for: "review/start"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        let thread = CodexThread(id: "thread-1", model: "gpt-5", client: client, router: router, connectionLease: harness.lease)

        let review = try await thread.startReview(target: .baseBranch("main"))

        #expect(review.threadID == "thread-1")
        #expect(review.reviewThreadID == "thread-1")
        #expect(review.model == "gpt-5")
        #expect(review.identity.reviewThreadID == nil)
        #expect(review.identity.model == "gpt-5")
    }

    @Test func reviewStartRequiresTheResponseEventThreadIdentity() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(
            #"{"turn":{"id":"turn-review","status":"inProgress"}}"#,
            for: "review/start"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let thread = CodexThread(
            id: "thread-1",
            client: harness.client,
            router: harness.router,
            connectionLease: harness.lease
        )

        do {
            _ = try await thread.startReview(target: .baseBranch("main"))
            Issue.record("Expected a missing reviewThreadId to fail decoding.")
        } catch let error as CodexAppServerError {
            guard case .request(let failure) = error,
                  case .invalidResponse = failure.kind else {
                Issue.record("Expected a typed invalid response, got \(error).")
                await harness.close()
                return
            }
            #expect(failure.method == "review/start")
        }
        await harness.close()
    }

    @Test func appServerStartReviewDeletesSourceThreadWhenReviewStartFails() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-source", model: "gpt-5")
        await runtime.transport.enqueueFailure(
            code: -32602,
            message: "invalid review target",
            for: "review/start"
        )
        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        let workspace = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

        do {
            _ = try await runtime.server.startReview(
                in: workspace,
                target: .baseBranch("missing")
            )
            Issue.record("Expected review start failure.")
        } catch {
            let requests = await runtime.transport.recordedRequests()
            #expect(requests.map(\.method) == [
                "initialize",
                "thread/start",
                "review/start",
                "thread/delete",
            ])
            let delete = try requests[3].decodeParams(AppServerAPI.Thread.Delete.Params.self)
            #expect(delete.threadID == "thread-source")
        }
    }

    @Test func appServerStartReviewDeletesSourceThreadWhenCancelledDuringThreadStart() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let threadStartGate = CodexAppServerTestGate()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-source", model: "gpt-5")
        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        await runtime.transport.holdNextIgnoringCancellation(
            method: "thread/start",
            gate: threadStartGate
        )
        let workspace = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

        let task = Task {
            try await runtime.server.startReview(
                in: workspace,
                target: .baseBranch("main")
            )
        }
        await runtime.transport.waitForRequest(method: "thread/start")
        task.cancel()
        await threadStartGate.open()

        do {
            _ = try await withTimeout {
                try await task.value
            }
            Issue.record("Expected cancelled thread start failure.")
        } catch is CancellationError {
            let requests = await runtime.transport.recordedRequests()
            #expect(requests.map(\.method) == [
                "initialize",
                "thread/start",
                "thread/delete",
            ])
            let delete = try requests[2].decodeParams(AppServerAPI.Thread.Delete.Params.self)
            #expect(delete.threadID == "thread-source")
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
    }

    @Test func appServerStartReviewDeletesSourceThreadWhenCancelledAfterThreadStart() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let reviewStartGate = CodexAppServerTestGate()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-source", model: "gpt-5")
        await runtime.transport.enqueueFailure(
            code: -32602,
            message: "cancelled review start",
            for: "review/start"
        )
        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        await runtime.transport.holdNextIgnoringCancellation(
            method: "review/start",
            gate: reviewStartGate
        )
        let workspace = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

        let task = Task {
            try await runtime.server.startReview(
                in: workspace,
                target: .baseBranch("main")
            )
        }
        await runtime.transport.waitForRequest(method: "review/start")
        task.cancel()
        await reviewStartGate.open()

        do {
            _ = try await withTimeout {
                try await task.value
            }
            Issue.record("Expected cancelled review start failure.")
        } catch {
            let requests = await runtime.transport.recordedRequests()
            #expect(requests.map(\.method) == [
                "initialize",
                "thread/start",
                "review/start",
                "thread/delete",
            ])
            let delete = try requests[3].decodeParams(AppServerAPI.Thread.Delete.Params.self)
            #expect(delete.threadID == "thread-source")
        }
    }

    @Test func appServerStartReviewCleansDetachedReviewWhenCancelledAfterReviewStart() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let reviewStartGate = CodexAppServerTestGate()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-source", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        await runtime.transport.holdNextIgnoringCancellation(
            method: "review/start",
            gate: reviewStartGate
        )
        let workspace = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

        let task = Task {
            try await runtime.server.startReview(
                in: workspace,
                target: .baseBranch("main"),
                delivery: .detached
            )
        }
        await runtime.transport.waitForRequest(method: "review/start")
        task.cancel()
        await reviewStartGate.open()
        await runtime.transport.waitForRequest(method: "turn/interrupt")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-review",
                turn: .init(id: "turn-review", status: "interrupted")
            )
        )

        do {
            _ = try await withTimeout {
                try await task.value
            }
            Issue.record("Expected cancelled detached review start failure.")
        } catch is CancellationError {
            let requests = await runtime.transport.recordedRequests()
            #expect(requests.map(\.method) == [
                "initialize",
                "thread/start",
                "review/start",
                "turn/interrupt",
                "thread/delete",
                "thread/delete",
            ])
            let deletedThreadIDs = try requests.suffix(2).map {
                try $0.decodeParams(AppServerAPI.Thread.Delete.Params.self).threadID
            }
            #expect(deletedThreadIDs == ["thread-review", "thread-source"])
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
        await runtime.close()
    }

    @Test func inlineReviewStartCancellationKeepsOuterThreadEventOwnerWhenInterruptRedirects() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-source"
        )
        await transport.enqueueFailure(
            code: -32602,
            message: "expected active turn id turn-review but found turn-review-child",
            for: "turn/interrupt"
        )
        try await transport.enqueueEmpty(for: "turn/interrupt")
        let reviewStartGate = CodexAppServerTestGate()
        await transport.holdNextIgnoringCancellation(
            method: "review/start",
            gate: reviewStartGate
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let thread = CodexThread(
            id: "thread-source",
            client: harness.client,
            router: harness.router,
            connectionLease: harness.lease
        )

        let reviewStart = Task {
            try await thread.startReview(target: .baseBranch("main"))
        }
        await transport.waitForRequest(method: "review/start")
        reviewStart.cancel()
        await reviewStartGate.open()
        await transport.waitForRequest(method: "turn/interrupt", count: 2)
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-review-child",
                turn: .init(id: "turn-review-child", status: "interrupted")
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-source",
                turnID: "turn-review",
                item: .init(
                    id: "review-output",
                    type: "agentMessage",
                    text: "Review interrupted"
                )
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-source",
                turn: .init(id: "turn-review", status: "interrupted")
            )
        )

        await #expect(throws: CancellationError.self) {
            try await reviewStart.value
        }
        await harness.close()
    }

    @Test func standaloneStartThreadDeletesLateIdentityBeforeCancellationReturns() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let startGate = CodexAppServerTestGate()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-late", model: "gpt-5")
        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        await runtime.transport.holdNextIgnoringCancellation(method: "thread/start", gate: startGate)

        let task = Task {
            try await runtime.server.startThread(
                in: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
            )
        }
        await runtime.transport.waitForRequest(method: "thread/start")
        task.cancel()
        await startGate.open()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await runtime.transport.recordedRequests().map(\.method) == [
            "initialize",
            "thread/start",
            "thread/delete",
        ])
        let delete = try #require(await runtime.transport.recordedRequests().last)
        #expect(
            try delete.decodeParams(AppServerAPI.Thread.Delete.Params.self).threadID
                == "thread-late"
        )
    }

    @Test func forkThreadDeletesLateForkBeforeCancellationReturns() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let forkGate = CodexAppServerTestGate()
        try await runtime.transport.enqueue(
            AppServerAPI.Thread.Fork.Response(thread: .init(id: "thread-fork")),
            for: "thread/fork"
        )
        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        await runtime.transport.holdNextIgnoringCancellation(method: "thread/fork", gate: forkGate)

        let task = Task {
            try await runtime.server.forkThread("thread-source")
        }
        await runtime.transport.waitForRequest(method: "thread/fork")
        task.cancel()
        await forkGate.open()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await runtime.transport.recordedRequests().map(\.method) == [
            "initialize",
            "thread/fork",
            "thread/delete",
        ])
        let delete = try #require(await runtime.transport.recordedRequests().last)
        #expect(
            try delete.decodeParams(AppServerAPI.Thread.Delete.Params.self).threadID
                == "thread-fork"
        )
    }

    @Test func loginChatGPTCancelsLateLoginBeforeCancellationReturns() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let loginGate = CodexAppServerTestGate()
        try await runtime.transport.enqueueChatGPTLogin(
            loginID: "login-late",
            authenticationURL: URL(string: "https://example.test/auth")!
        )
        try await runtime.transport.enqueue(
            AppServerAPI.Account.Login.Cancel.Response(),
            for: "account/login/cancel"
        )
        await runtime.transport.holdNextIgnoringCancellation(
            method: "account/login/start",
            gate: loginGate
        )

        let task = Task {
            try await runtime.server.loginChatGPT()
        }
        await runtime.transport.waitForRequest(method: "account/login/start")
        task.cancel()
        await loginGate.open()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await runtime.transport.recordedRequests().map(\.method) == [
            "initialize",
            "account/login/start",
            "account/login/cancel",
        ])
        let cancel = try #require(await runtime.transport.recordedRequests().last)
        #expect(
            try cancel.decodeParams(AppServerAPI.Account.Login.Cancel.Params.self).loginID
                == "login-late"
        )
    }

    @Test func appServerListThreadsSerializesQueryOptions() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Thread.List.Response(data: [], nextCursor: "next"),
            for: "thread/list"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let server = harness.server
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
        #expect(params.cwd == .paths([workspace.path]))
        #expect(params.limit == 10)
        #expect(params.searchTerm == "review")
        #expect(params.modelProviders == ["openai"])
        #expect(params.sortDirection == "desc")
        #expect(params.sortKey == "recency_at")
        #expect(params.sourceKinds == ["appServer", "subAgentReview"])
        #expect(params.useStateDbOnly == true)
    }

    @Test func appServerListThreadsSerializesMultipleWorkspaceFilters() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Thread.List.Response(data: []),
            for: "thread/list"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let server = harness.server
        let app = URL(fileURLWithPath: "/tmp/project/App", isDirectory: true)
        let tools = URL(fileURLWithPath: "/tmp/project/Tools", isDirectory: true)

        _ = try await server.listThreads(.init(workspaces: [app, tools]))

        let request = try #require(await transport.recordedRequests().first)
        let params = try JSONDecoder().decode(
            AppServerAPI.Thread.List.Params.self,
            from: request.params
        )
        #expect(params.cwd == .paths([app.path, tools.path]))
    }

    @Test func appServerListThreadsTreatsClearedWorkspaceFiltersAsNoFilter() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Thread.List.Response(data: []),
            for: "thread/list"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let server = harness.server
        var query = CodexThreadQuery(
            workspaces: [URL(fileURLWithPath: "/tmp/project", isDirectory: true)]
        )
        query.workspaces = []

        _ = try await server.listThreads(query)

        let request = try #require(await transport.recordedRequests().first)
        let params = try JSONDecoder().decode(
            AppServerAPI.Thread.List.Params.self,
            from: request.params
        )
        #expect(params.cwd == nil)
    }

    @Test func appServerListThreadsMapsStatusAndRecency() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(
            """
            {
              "data": [
                {
                  "id": "thread-active",
                  "recencyAt": 1234,
                  "status": {
                    "type": "active",
                    "activeFlags": ["waitingOnApproval"]
                  }
                }
              ]
            }
            """,
            for: "thread/list"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let server = harness.server

        let page = try await server.listThreads()
        let snapshot = try #require(page.threads.first)

        #expect(snapshot.hasField(.recencyAt))
        #expect(snapshot.recencyAt == Date(timeIntervalSince1970: 1234))
        #expect(snapshot.hasField(.status))
        #expect(snapshot.status == .active(activeFlags: [.waitingOnApproval]))
    }

    @Test func threadListTreatsEmptyTurnsAsUnloaded() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Thread.List.Response(data: [
                .init(id: "thread-empty", turns: [])
            ]),
            for: "thread/list"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let server = harness.server

        let page = try await server.listThreads()

        #expect(page.threads.first?.turns == nil)
    }

    @Test func threadListTurnItemsAreNotAuthoritative() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Thread.List.Response(data: [
                .init(
                    id: "thread-summary",
                    turns: [
                        .init(
                            id: "turn-summary",
                            status: "completed",
                            items: [
                                .object([
                                    "id": .string("message-summary"),
                                    "type": .string("agentMessage"),
                                    "text": .string("Summary"),
                                ]),
                            ]
                        ),
                    ]
                ),
            ]),
            for: "thread/list"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let server = harness.server

        let page = try await server.listThreads()

        let snapshot = try #require(page.threads.first)
        #expect(snapshot.turns?.first?.items.first?.id == "message-summary")
        #expect(snapshot.turnItemsAreAuthoritative == false)
    }

    @Test func threadSnapshotEqualityIgnoresTurnAuthorityFlag() {
        let turns = [CodexTurnSnapshot(id: "turn-1", state: .completed)]
        let publicSnapshot = CodexThreadSnapshot(id: "thread-1", turns: turns)
        let summarySnapshot = CodexThreadSnapshot(
            id: "thread-1",
            turns: turns,
            turnItemsAreAuthoritative: false
        )

        #expect(publicSnapshot == summarySnapshot)
    }

    @Test func threadSnapshotClampsTurnAuthorityToLoadedItems() {
        let partiallyLoadedSnapshot = CodexThreadSnapshot(
            id: "thread-1",
            turns: [
                CodexTurnSnapshot(id: "turn-full", state: .completed),
                CodexTurnSnapshot(
                    id: "turn-summary",
                    state: .completed,
                    itemsLoadState: .summary
                ),
            ],
            turnItemsAreAuthoritative: true
        )
        #expect(partiallyLoadedSnapshot.turnItemsAreAuthoritative == false)

        let fullyLoadedSnapshot = CodexThreadSnapshot(
            id: "thread-1",
            turns: [CodexTurnSnapshot(id: "turn-full", state: .completed)],
            turnItemsAreAuthoritative: true
        )
        #expect(fullyLoadedSnapshot.turnItemsAreAuthoritative)

        let turnlessSnapshot = CodexThreadSnapshot(
            id: "thread-1",
            turnItemsAreAuthoritative: true
        )
        #expect(turnlessSnapshot.turnItemsAreAuthoritative == false)
    }

    @Test func threadStatusTreatsNonProtocolValuesAsUnknown() {
        #expect(CodexThreadStatus(rawValue: "notLoaded") == .notLoaded)
        #expect(CodexThreadStatus(rawValue: "idle") == .idle)
        #expect(CodexThreadStatus(rawValue: "systemError") == .systemError)
        #expect(CodexThreadStatus(rawValue: "active") == .active(activeFlags: []))
        #expect(CodexThreadStatus(rawValue: "loaded") == .unknown(rawValue: "loaded"))
        #expect(CodexThreadStatus(rawValue: "loaded").isActive == false)
        #expect(CodexThreadStatus(rawValue: "running") == .unknown(rawValue: "running"))
        #expect(CodexThreadStatus(rawValue: "running").isActive == false)
        #expect(CodexThreadStatus(rawValue: "closed") == .unknown(rawValue: "closed"))
    }

    @Test func turnStatusCanonicalizesActiveAliases() {
        #expect(CodexTurnStatus.inProgress.rawValue == "inProgress")
        for rawValue in ["inProgress", "started", "running"] {
            #expect(CodexTurnStatus(rawValue: rawValue) == .inProgress)
        }
        for rawValue in ["success", "succeeded", "cancelled", "aborted"] {
            #expect(CodexTurnStatus(rawValue: rawValue) == .unknown(rawValue: rawValue))
        }
    }

    @Test func terminalClassifierPreservesEveryCurrentV2OutcomeAndTiming() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)

        func makeTurn(_ id: CodexTurnID) async -> CodexTurn {
            let state = await harness.turnReplayStore.restoreGeneration(
                turnID: id,
                initialSnapshot: .init(id: id, state: .inProgress),
                connectionLease: harness.lease
            )
            return CodexTurn(
                id: id,
                threadID: "thread-1",
                client: client,
                router: router,
                turnReplayStore: harness.turnReplayStore,
                state: state
            )
        }

        let completed = await makeTurn("turn-completed")
        let interrupted = await makeTurn("turn-interrupted")
        let failed = await makeTurn("turn-failed")
        let future = await makeTurn("turn-future")
        let inProgress = await makeTurn("turn-in-progress")

        let completedTask = Task { try await completed.result() }
        let interruptedTask = Task { try await interrupted.result() }
        let failedTask = Task { try await failed.result() }
        let futureTask = Task { try await future.result() }
        let inProgressTask = Task { try await inProgress.result() }

        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(
                id: "turn-completed",
                status: "completed",
                startedAt: 1_700_000_000,
                completedAt: 1_700_000_002,
                durationMS: 2_000
            ))
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-interrupted", status: "interrupted"))
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(
                id: "turn-failed",
                status: "failed",
                error: .init(message: "failed", codexErrorInfo: .serverOverloaded)
            ))
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(
                id: "turn-future",
                status: "futureStatus",
                error: .init(
                    message: "future failure",
                    codexErrorInfo: .httpConnectionFailed(httpStatusCode: 503),
                    additionalDetails: "upstream detail"
                )
            ))
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-in-progress", status: "inProgress"))
        )

        let completedOutcome = try await completedTask.value
        guard case .completed(let response) = completedOutcome else {
            Issue.record("Expected completed outcome.")
            return
        }
        #expect(response.startedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(response.completedAt == Date(timeIntervalSince1970: 1_700_000_002))
        #expect(response.duration == .milliseconds(2_000))
        let interruptedOutcome = try await interruptedTask.value
        guard case .interrupted(let interruptedResponse) = interruptedOutcome else {
            Issue.record("Expected interrupted outcome.")
            return
        }
        #expect(interruptedResponse.turnID == "turn-interrupted")

        guard case .failed(let failedTurn) = try await failedTask.value else {
            Issue.record("Expected failed outcome.")
            return
        }
        #expect(failedTurn.error == .init(message: "failed", info: .serverOverloaded))

        guard case .invalidTerminalStatus(let rawStatus, let error, _) = try await futureTask.value else {
            Issue.record("Expected future terminal status to remain invalid.")
            return
        }
        #expect(rawStatus == "futureStatus")
        #expect(error == .init(
            message: "future failure",
            info: .httpConnectionFailed(httpStatusCode: 503),
            additionalDetails: "upstream detail"
        ))

        guard case .invalidTerminalStatus(let rawStatus, let error, _) = try await inProgressTask.value else {
            Issue.record("Expected in-progress terminal status to remain invalid.")
            return
        }
        #expect(rawStatus == "inProgress")
        #expect(error == nil)
    }

    @Test func malformedTerminalPayloadsNeverBecomeOutcomes() async throws {
        let cases: [(CodexTurnID, String)] = [
            ("turn-missing-status", #"{"turn":{"id":"turn-missing-status"}}"#),
            ("turn-failed-without-error", #"{"turn":{"id":"turn-failed-without-error","status":"failed"}}"#),
            ("turn-completed-with-error", #"{"turn":{"id":"turn-completed-with-error","status":"completed","error":{"message":"illegal"}}}"#),
            ("turn-malformed", #"{"turnId":"turn-malformed","turn":"not-an-object"}"#),
        ]
        for (turnID, json) in cases {
            let transport = CodexAppServerTestTransport()
            let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
            let connectionEvents = await harness.server.connectionEvents()
            let terminal = Task { await firstConnectionTermination(in: connectionEvents) }
            await connectionEvents.waitUntilNextSuspendsForTesting()
            await transport.waitForNotificationStreamCount(1)
            try await transport.emitServerNotificationJSON(method: "turn/completed", json: json)
            let termination = try #require(await terminal.value)
            guard case .transportFailure(.protocolViolation(_, let rawData)) = termination else {
                Issue.record("Expected connection protocol violation for \(turnID.rawValue).")
                continue
            }
            #expect(rawData == Data(json.utf8))
        }
    }

    @Test func terminalOutcomeAndConnectionFailureReplayToLateSubscribers() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        await transport.waitForNotificationStreamCount(1)

        let terminalTurnID = CodexTurnID(rawValue: "turn-terminal-replay")
        let state = await harness.turnReplayStore.restoreGeneration(
            turnID: terminalTurnID,
            initialSnapshot: .init(id: terminalTurnID, state: .inProgress),
            connectionLease: harness.lease
        )
        let firstTerminalStream = try await harness.turnReplayStore.events(
            for: terminalTurnID,
            state: state
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-terminal-replay", status: "completed"))
        )
        let firstTerminalEvents = try await collect(firstTerminalStream)
        let lateTerminalEvents = try await collect(
            try await harness.turnReplayStore.events(for: terminalTurnID, state: state)
        )
        #expect(Array(firstTerminalEvents.suffix(lateTerminalEvents.count)) == lateTerminalEvents)
        #expect(lateTerminalEvents.count == 2)
        guard case .terminal(let terminalOutcome) = lateTerminalEvents.last else {
            Issue.record("Expected a replayed terminal outcome.")
            return
        }
        #expect(terminalOutcome.response.turnID == terminalTurnID)

        let connectionEvents = await harness.server.connectionEvents()
        let firstFailure = Task { await firstConnectionTermination(in: connectionEvents) }
        await connectionEvents.waitUntilNextSuspendsForTesting()
        try await transport.emitServerNotificationJSON(
            method: "turn/completed",
            json: #"{"turn":{"id":"turn-failure-replay"}}"#
        )
        let firstTermination = await firstFailure.value
        let lateTermination = await firstConnectionTermination(
            in: await harness.server.connectionEvents()
        )
        #expect(firstTermination == lateTermination)
        guard case .transportFailure(.protocolViolation) = firstTermination else {
            Issue.record("Expected replayed connection protocol violation.")
            return
        }
    }

    @Test func currentV2ThreadSessionSourcesRoundTripLosslessly() throws {
        let sources: [AppServerAPI.Thread.SessionSource] = [
            .cli,
            .vscode,
            .exec,
            .appServer,
            .custom("automation"),
            .subAgent(.review),
            .subAgent(.compact),
            .subAgent(.threadSpawn(.init(
                parentThreadID: "parent-thread",
                depth: 2,
                agentPath: "reviewer/worker",
                agentNickname: "Scout",
                agentRole: "reviewer"
            ))),
            .subAgent(.memoryConsolidation),
            .subAgent(.other("custom-agent")),
            .unknown,
        ]
        let expectedDomainSources: [CodexThreadSessionSource] = [
            .cli,
            .vscode,
            .exec,
            .appServer,
            .custom("automation"),
            .subAgent(.review),
            .subAgent(.compact),
            .subAgent(.threadSpawn(.init(
                parentThreadID: "parent-thread",
                depth: 2,
                agentPath: "reviewer/worker",
                agentNickname: "Scout",
                agentRole: "reviewer"
            ))),
            .subAgent(.memoryConsolidation),
            .subAgent(.other("custom-agent")),
            .unknown,
        ]

        for (source, expectedDomainSource) in zip(sources, expectedDomainSources) {
            let data = try JSONEncoder().encode(source)
            #expect(try JSONDecoder().decode(AppServerAPI.Thread.SessionSource.self, from: data) == source)
            let snapshot = CodexAppServer.threadSnapshot(
                from: .init(id: "thread-source", source: source),
                includesTurns: false
            )
            #expect(snapshot.source == expectedDomainSource)
            #expect(snapshot.sourceKind == expectedDomainSource.sourceKind)
            #expect(snapshot.hasField(.source))
            #expect(snapshot.hasField(.sourceKind) == false)
        }
    }

    @Test func threadListProjectsCanonicalSubAgentReviewSource() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(
            #"{"data":[{"id":"thread-review","source":{"subAgent":"review"}}]}"#,
            for: "thread/list"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)

        let snapshot = try #require(try await harness.server.listThreads().threads.first)

        #expect(snapshot.source == .subAgent(.review))
        #expect(snapshot.sourceKind == .subAgentReview)
        #expect(snapshot.hasField(.source))
        #expect(snapshot.hasField(.sourceKind) == false)
    }

    @Test func threadListProjectsThreadProvenanceMetadata() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(
            """
            {
              "data": [
                {
                  "id": "thread-worker",
                  "sessionId": "session-review",
                  "parentThreadId": "thread-parent",
                  "source": {
                    "subAgent": {
                      "thread_spawn": {
                        "parent_thread_id": "thread-parent",
                        "depth": 2,
                        "agent_path": "reviewer/worker",
                        "agent_nickname": "Scout",
                        "agent_role": "reviewer"
                      }
                    }
                  },
                  "gitInfo": {
                    "sha": "0123456789abcdef",
                    "branch": "agent/review-sidebar",
                    "originUrl": "git@github.com:lynnswap/CodexKit.git"
                  }
                }
              ]
            }
            """,
            for: "thread/list"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)

        let snapshot = try #require(try await harness.server.listThreads().threads.first)

        #expect(snapshot.sessionID == "session-review")
        #expect(snapshot.parentThreadID == "thread-parent")
        #expect(snapshot.source == .subAgent(.threadSpawn(.init(
            parentThreadID: "thread-parent",
            depth: 2,
            agentPath: "reviewer/worker",
            agentNickname: "Scout",
            agentRole: "reviewer"
        ))))
        #expect(snapshot.sourceKind == .subAgentThreadSpawn)
        #expect(snapshot.gitInfo == .init(
            sha: "0123456789abcdef",
            branch: "agent/review-sidebar",
            originURL: "git@github.com:lynnswap/CodexKit.git"
        ))
        #expect(snapshot.hasField(.sessionID))
        #expect(snapshot.hasField(.parentThreadID))
        #expect(snapshot.hasField(.source))
        #expect(snapshot.hasField(.gitInfo))
    }

    @Test func threadListDoesNotUseLegacySourceKindFallback() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(
            #"{"data":[{"id":"thread-legacy","sourceKind":"appServer"}]}"#,
            for: "thread/list"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)

        let snapshot = try #require(try await harness.server.listThreads().threads.first)

        #expect(snapshot.sourceKind == nil)
        #expect(snapshot.source == nil)
        #expect(snapshot.hasField(.source) == false)
        #expect(snapshot.hasField(.sourceKind) == false)
    }

    @Test func threadSnapshotsTrackOmittedAndNullFields() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(
            """
            {
              "data": [
                {
                  "id": "thread-partial",
                  "sessionId": null,
                  "parentThreadId": null,
                  "name": null,
                  "source": null,
                  "gitInfo": null,
                  "updatedAt": 1000
                }
              ]
            }
            """,
            for: "thread/list"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let server = harness.server

        let page = try await server.listThreads()
        let snapshot = try #require(page.threads.first)

        #expect(snapshot.hasField(.name))
        #expect(snapshot.name == nil)
        #expect(snapshot.hasField(.sessionID))
        #expect(snapshot.sessionID == nil)
        #expect(snapshot.hasField(.parentThreadID))
        #expect(snapshot.parentThreadID == nil)
        #expect(snapshot.hasField(.source))
        #expect(snapshot.source == nil)
        #expect(snapshot.sourceKind == nil)
        #expect(snapshot.hasField(.gitInfo))
        #expect(snapshot.gitInfo == nil)
        #expect(snapshot.hasField(.updatedAt))
        #expect(snapshot.updatedAt == Date(timeIntervalSince1970: 1000))
        #expect(!snapshot.hasField(.workspace))
        #expect(!snapshot.hasField(.modelProvider))
    }

    @Test func threadSnapshotEncodingPreservesPresentNullFields() throws {
        let snapshot = AppServerAPI.Thread.Snapshot(
            id: "thread-partial",
            name: nil,
            updatedAt: nil,
            presentFields: [
                .sessionID,
                .parentThreadID,
                .name,
                .source,
                .gitInfo,
                .updatedAt,
            ]
        )

        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["id"] as? String == "thread-partial")
        #expect(object["sessionId"] is NSNull)
        #expect(object["parentThreadId"] is NSNull)
        #expect(object["name"] is NSNull)
        #expect(object["source"] is NSNull)
        #expect(object["gitInfo"] is NSNull)
        #expect(object["updatedAt"] is NSNull)
        #expect(object["cwd"] == nil)
    }

    @Test func threadSnapshotEncodingPreservesThreadProvenanceMetadata() throws {
        let snapshot = AppServerAPI.Thread.Snapshot(
            id: "thread-worker",
            sessionID: "session-review",
            parentThreadID: "thread-parent",
            source: .subAgent(.review),
            gitInfo: .init(
                sha: "0123456789abcdef",
                branch: "agent/review-sidebar",
                originURL: "git@github.com:lynnswap/CodexKit.git"
            )
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AppServerAPI.Thread.Snapshot.self, from: data)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let gitInfo = try #require(object["gitInfo"] as? [String: Any])

        #expect(decoded == snapshot)
        #expect(object["sessionId"] as? String == "session-review")
        #expect(object["parentThreadId"] as? String == "thread-parent")
        #expect(gitInfo["originUrl"] as? String == "git@github.com:lynnswap/CodexKit.git")
    }

    @Test func exactThreadSourceOwnsCompatibilityProjection() {
        var snapshot = CodexThreadSnapshot(
            id: "thread-source-owner",
            source: .subAgent(.review)
        )

        #expect(snapshot.source == .subAgent(.review))
        #expect(snapshot.sourceKind == .subAgentReview)
        #expect(snapshot.hasField(.source))
        #expect(snapshot.hasField(.sourceKind) == false)

        snapshot.sourceKind = .subAgentReview
        #expect(snapshot.source == .subAgent(.review))
        #expect(snapshot.hasField(.source))
        #expect(snapshot.hasField(.sourceKind) == false)

        snapshot.sourceKind = .appServer
        #expect(snapshot.source == nil)
        #expect(snapshot.sourceKind == .appServer)
        #expect(snapshot.hasField(.source) == false)
        #expect(snapshot.hasField(.sourceKind))

        snapshot.source = .custom("automation")
        #expect(snapshot.source == .custom("automation"))
        #expect(snapshot.sourceKind == nil)
        #expect(snapshot.hasField(.source))
        #expect(snapshot.hasField(.sourceKind) == false)

        snapshot.source = nil
        #expect(snapshot.source == nil)
        #expect(snapshot.hasField(.source))
    }

    @Test func threadReadUsesIncludeTurnsToInterpretEmptyTurns() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Thread.Read.Response(thread: .init(id: "thread-empty", turns: [])),
            for: "thread/read"
        )
        try await transport.enqueue(
            AppServerAPI.Thread.Read.Response(thread: .init(id: "thread-empty", turns: [])),
            for: "thread/read"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let thread = CodexThread(
            id: .init(rawValue: "thread-empty"),
            client: client,
            router: harness.router,
            connectionLease: harness.lease
        )

        let metadataOnly = try await thread.read(includeTurns: false)
        let withTurns = try await thread.read(includeTurns: true)

        #expect(metadataOnly.turns == nil)
        #expect(!metadataOnly.hasField(.turns))
        #expect(withTurns.turns == [])
        #expect(withTurns.hasField(.turns))
    }

    @Test func threadReadTreatsOmittedTurnsAsEmptyWhenIncluded() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(
            """
            {
              "thread": {
                "id": "thread-empty"
              }
            }
            """,
            for: "thread/read"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let thread = CodexThread(
            id: .init(rawValue: "thread-empty"),
            client: client,
            router: harness.router,
            connectionLease: harness.lease
        )

        let snapshot = try await thread.read(includeTurns: true)

        #expect(snapshot.turns == [])
        #expect(snapshot.hasField(.turns))
    }

    @Test func threadReadDoesNotTreatSummaryTurnsAsAuthoritative() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(
            """
            {
              "thread": {
                "id": "thread-summary",
                "turns": [
                  {
                    "id": "turn-summary",
                    "status": "completed",
                    "itemsView": "summary",
                    "items": [
                      {
                        "id": "message-summary",
                        "type": "agentMessage",
                        "text": "Summary"
                      }
                    ]
                  }
                ]
              }
            }
            """,
            for: "thread/read"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let thread = CodexThread(
            id: .init(rawValue: "thread-summary"),
            client: client,
            router: harness.router,
            connectionLease: harness.lease
        )

        let snapshot = try await thread.read(includeTurns: true)

        #expect(snapshot.turns?.first?.itemsLoadState == .summary)
        #expect(snapshot.turnItemsAreAuthoritative == false)
    }

    @Test func threadReadPreservesItemsWithoutStableIDs() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(
            """
            {
              "thread": {
                "id": "thread-missing-item-id",
                "turns": [
                  {
                    "id": "turn-missing-item-id",
                    "status": "completed",
                    "items": [
                      {
                        "type": "diagnostic",
                        "text": "Legacy diagnostic"
                      }
                    ]
                  }
                ]
              }
            }
            """,
            for: "thread/read"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let thread = CodexThread(
            id: .init(rawValue: "thread-missing-item-id"),
            client: client,
            router: harness.router,
            connectionLease: harness.lease
        )

        let snapshot = try await thread.read(includeTurns: true)
        let item = try #require(snapshot.turns?.first?.items.first)

        #expect(item.id.hasPrefix("missing-id:diagnostic:"))
        #expect(item.text == "Legacy diagnostic")
        #expect(item.rawPayload != nil)
    }

    @Test func threadStoreDrivesRuntimeThreadStubsAfterStart() async throws {
        let workspace = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let initial = try makeRuntimeStoredThreadFixture(
            id: "thread-a",
            workspace: workspace,
            name: "A"
        )
        let store = try CodexAppServerTestThreadStore(threads: [initial])
        let runtime = try await CodexAppServerTestRuntime.start(threadStore: store)

        let firstPage = try await runtime.server.listThreads()
        #expect(firstPage.threads.map(\.id) == [initial.snapshot.id])
        #expect(firstPage.threads.allSatisfy { $0.turns == nil })
        #expect(firstPage.nextCursor == nil)
        #expect(firstPage.backwardsCursor == nil)

        let updated = try makeRuntimeStoredThreadFixture(
            id: "thread-b",
            workspace: workspace,
            name: "B",
            preview: "Updated",
            turns: [try makeRuntimeTestTurnFixture(id: "turn-b")]
        )
        await store.upsert(updated)

        #expect(await store.storedThread(id: "thread-b") == updated)

        let secondPage = try await runtime.server.listThreads()
        #expect(secondPage.threads.map(\.id) == [updated.snapshot.id, initial.snapshot.id])
        #expect(secondPage.threads.map(\.preview) == [updated.snapshot.preview, initial.snapshot.preview])
        #expect(secondPage.threads.allSatisfy { $0.turns == nil })

        let resumed = try await runtime.server.resumeThread("thread-b")
        let read = try await resumed.read(includeTurns: true)
        #expect(read == updated.snapshot)

        await store.remove(id: "thread-a")
        let removedPage = try await runtime.server.listThreads()
        #expect(removedPage.threads.map(\.id) == [updated.snapshot.id])
        #expect(removedPage.threads.first?.turns == nil)

        let startedWorkspace = URL(fileURLWithPath: "/tmp/started", isDirectory: true)
        let plannedStart = try makeRuntimeStoredThreadFixture(
            id: "thread-started",
            workspace: startedWorkspace,
            model: "gpt-5",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
            recencyAt: Date(timeIntervalSince1970: 100),
            ephemeral: true
        )
        try await store.enqueueStart(plannedStart)
        let started = try await runtime.server.startThread(
            in: startedWorkspace,
            options: .init(model: "gpt-5", modelProvider: "openai", ephemeral: true)
        )
        let startedSnapshot = try #require(await store.storedThread(id: started.id)).snapshot
        #expect(startedSnapshot.workspace == startedWorkspace)
        #expect(startedSnapshot.modelProvider == "openai")
        #expect(startedSnapshot.ephemeral == true)
        #expect(started.model == "gpt-5")
    }

    @Test func threadStoreThreadReadHonorsIncludeTurns() async throws {
        let stored = try makeRuntimeStoredThreadFixture(
            id: "thread-with-turns",
            turns: [try makeRuntimeTestTurnFixture(id: "turn-from-store")]
        )
        let runtime = try await CodexAppServerTestRuntime.start(threads: [stored])
        let thread = try await runtime.server.resumeThread("thread-with-turns")

        let metadataOnly = try await thread.read(includeTurns: false)
        let withTurns = try await thread.read(includeTurns: true)

        #expect(metadataOnly.turns == nil)
        #expect(!metadataOnly.hasField(.turns))
        #expect(withTurns.turns?.map(\.id.rawValue) == ["turn-from-store"])
        #expect(withTurns.hasField(.turns))
    }

    @Test func threadStoreHonorsThreadListPagination() async throws {
        let threads = try [
            makeRuntimeStoredThreadFixture(id: "thread-a", name: "A"),
            makeRuntimeStoredThreadFixture(id: "thread-b", name: "B"),
            makeRuntimeStoredThreadFixture(id: "thread-c", name: "C"),
        ]
        let runtime = try await CodexAppServerTestRuntime.start(threads: threads)

        let firstPage = try await runtime.server.listThreads(.init(limit: 2))
        #expect(firstPage.threads.map(\.id.rawValue) == ["thread-a", "thread-b"])
        let nextCursor = try #require(firstPage.nextCursor)
        #expect(firstPage.backwardsCursor == nil)

        let secondPage = try await runtime.server.listThreads(.init(
            cursor: nextCursor,
            limit: 2
        ))
        #expect(secondPage.threads.map(\.id.rawValue) == ["thread-c"])
        #expect(secondPage.nextCursor == nil)
        #expect(secondPage.backwardsCursor != nil)
    }

    @Test func threadStoreOwnsArchiveMembershipSortingAndMutations() async throws {
        let activeOld = try makeRuntimeStoredThreadFixture(
            id: "active-old",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 40),
            recencyAt: Date(timeIntervalSince1970: 20)
        )
        let activeNew = try makeRuntimeStoredThreadFixture(
            id: "active-new",
            createdAt: Date(timeIntervalSince1970: 30),
            updatedAt: Date(timeIntervalSince1970: 20),
            recencyAt: Date(timeIntervalSince1970: 50)
        )
        let archived = try makeRuntimeStoredThreadFixture(
            id: "archived",
            createdAt: Date(timeIntervalSince1970: 60),
            updatedAt: Date(timeIntervalSince1970: 60),
            recencyAt: Date(timeIntervalSince1970: 60),
            isArchived: true
        )
        let store = try CodexAppServerTestThreadStore(threads: [activeOld, activeNew, archived])
        let runtime = try await CodexAppServerTestRuntime.start(threadStore: store)

        #expect(try await runtime.server.listThreads().threads.map(\.id) == [
            activeNew.snapshot.id,
            activeOld.snapshot.id,
        ])
        #expect(try await runtime.server.listThreads(.init(
            archived: true
        )).threads.map(\.id) == [archived.snapshot.id])
        #expect(try await runtime.server.listThreads(.init(
            sortDirection: .ascending,
            sortKey: .updatedAt
        )).threads.map(\.id) == [activeNew.snapshot.id, activeOld.snapshot.id])

        try await runtime.server.archiveThread(activeNew.snapshot.id)
        #expect(try await runtime.server.listThreads().threads.map(\.id) == [activeOld.snapshot.id])
        #expect(try await runtime.server.listThreads(.init(
            archived: true,
            sortDirection: .ascending,
            sortKey: .createdAt
        )).threads.map(\.id) == [activeNew.snapshot.id, archived.snapshot.id])

        _ = try await runtime.server.unarchiveThread(activeNew.snapshot.id)
        try await runtime.server.deleteThread(activeOld.snapshot.id)
        #expect(try await runtime.server.listThreads().threads.map(\.id) == [activeNew.snapshot.id])
        #expect(await store.storedThread(id: activeOld.snapshot.id) == nil)
        await runtime.close()
    }

    @Test func threadStoreAndQueuedThreadResponsesAreMutuallyExclusive() async throws {
        let storeRuntime = try await CodexAppServerTestRuntime.start(
            threadStore: try CodexAppServerTestThreadStore()
        )
        await #expect(throws: CodexAppServerTestError.invalidFixture(
            "Cannot enqueue thread/list while an authoritative thread store owns thread state."
        )) {
            try await storeRuntime.transport.enqueueThreadList(
                CodexAppServerTestThreadPage(threads: [])
            )
        }
        await storeRuntime.close()

        let queuedTransport = CodexAppServerTestTransport()
        try await queuedTransport.enqueueThreadList(CodexAppServerTestThreadPage(threads: []))
        await #expect(throws: CodexAppServerTestError.invalidFixture(
            "Queued thread responses and an authoritative thread store are mutually exclusive."
        )) {
            try await queuedTransport.stubThreads(try CodexAppServerTestThreadStore())
        }
        await queuedTransport.close()
    }

    @Test func authoritativeThreadStoreNeverFabricatesAnUnplannedStart() async throws {
        let store = try CodexAppServerTestThreadStore()
        let runtime = try await CodexAppServerTestRuntime.start(threadStore: store)

        do {
            _ = try await runtime.server.startThread(
                in: URL(fileURLWithPath: "/tmp/unplanned", isDirectory: true)
            )
            Issue.record("Expected an unplanned thread/start to be rejected.")
        } catch let error as CodexAppServerError {
            guard case .request(let failure) = error,
                  case .server(let serverError) = failure.kind else {
                Issue.record("Expected a typed server rejection, got \(error).")
                return
            }
            #expect(serverError.code == -32602)
            #expect(serverError.message == "thread/start requires an explicitly planned test thread.")
        }
        #expect(await store.storedThread(id: "unplanned") == nil)
        await runtime.close()
    }

    @Test func authoritativeThreadStoreConsumesPlannedForkWithoutMutatingSource() async throws {
        let source = try makeRuntimeStoredThreadFixture(
            id: "fork-source",
            name: "Source"
        )
        let fork = try makeRuntimeStoredThreadFixture(
            id: "fork-result",
            name: "Fork",
            ephemeral: false,
            forkedFromID: source.snapshot.id
        )
        let store = try CodexAppServerTestThreadStore(threads: [source])
        try await store.enqueueFork(fork, from: source.snapshot.id)
        let runtime = try await CodexAppServerTestRuntime.start(threadStore: store)

        let handle = try await runtime.server.forkThread(
            source.snapshot.id,
            options: .init(modelProvider: "openai", ephemeral: false)
        )

        #expect(handle.id == fork.snapshot.id)
        #expect(await store.storedThread(id: source.snapshot.id) == source)
        #expect(await store.storedThread(id: fork.snapshot.id) == fork)
        do {
            _ = try await runtime.server.forkThread(source.snapshot.id)
            Issue.record("Expected an unplanned thread/fork to be rejected.")
        } catch let error as CodexAppServerError {
            guard case .request(let failure) = error,
                  case .server(let serverError) = failure.kind else {
                Issue.record("Expected a typed server rejection, got \(error).")
                return
            }
            #expect(serverError.code == -32602)
        }
        #expect(await store.storedThread(id: source.snapshot.id) == source)
        await runtime.close()
    }

    @Test func threadStoreHonorsThreadTurnListPagination() async throws {
        let turns = try [
            makeRuntimeTestTurnFixture(id: "turn-a"),
            makeRuntimeTestTurnFixture(id: "turn-b"),
            makeRuntimeTestTurnFixture(id: "turn-c"),
        ]
        let runtime = try await CodexAppServerTestRuntime.start(threads: [
            makeRuntimeStoredThreadFixture(id: "thread-turns", turns: turns)
        ])
        let thread = try await runtime.server.resumeThread("thread-turns")

        let firstPage = try await thread.listTurns(.init(limit: 2))
        #expect(firstPage.turns.map(\.id.rawValue) == ["turn-a", "turn-b"])
        let nextCursor = try #require(firstPage.nextCursor)
        #expect(firstPage.backwardsCursor == nil)

        let secondPage = try await thread.listTurns(.init(
            cursor: nextCursor,
            limit: 2
        ))
        #expect(secondPage.turns.map(\.id.rawValue) == ["turn-c"])
        #expect(secondPage.nextCursor == nil)
        #expect(secondPage.backwardsCursor != nil)
    }

    @Test func transportStubThreadsAcceptsMutableThreadStore() async throws {
        let store = try CodexAppServerTestThreadStore()
        let transport = CodexAppServerTestTransport()
        try await transport.stubThreads(store)
        let runtime = try await CodexAppServerTestRuntime.start(transport: transport)

        let stored = try makeRuntimeStoredThreadFixture(
            id: "thread-transport",
            name: "Transport"
        )
        await store.upsert(stored)

        let page = try await runtime.server.listThreads()
        #expect(page.threads.map(\.id) == [stored.snapshot.id])
        #expect(page.threads.first?.name == stored.snapshot.name)
        #expect(page.threads.first?.turns == nil)
    }

    @Test func appServerArchiveThreadSerializesThreadID() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueEmpty(for: "thread/archive")
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let server = harness.server

        try await server.archiveThread("thread-archive")

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.method == "thread/archive")
        let params = try JSONDecoder().decode(
            AppServerAPI.Thread.Archive.Params.self,
            from: request.params
        )
        #expect(params.threadID == "thread-archive")
    }

    @Test func threadStartReviewSerializesTargetAndStreamsReviewEvents() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "turn-review",
                reviewThreadID: "thread-review"
            ),
            for: "review/start"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router, connectionLease: harness.lease)

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

        var eventIterator = review.events.makeAsyncIterator()
        let initialEvent = try #require(try await eventIterator.next())
        #expect(initialEvent == .snapshot(review.initialTurn))
        let eventsTask = Task {
            var events = [initialEvent]
            while let event = try await eventIterator.next() {
                events.append(event)
            }
            return events
        }

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
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(
                    id: "reasoning-1",
                    type: "reasoning",
                    summary: ["Checked the diff"],
                    content: ["trace"]
                )
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(
                    id: "tool-1",
                    type: "mcpToolCall",
                    text: "ok",
                    status: "completed",
                    tool: "review_read"
                )
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(
                    id: "file-1",
                    type: "fileChange",
                    status: "completed",
                    changes: .array([
                        .object([
                            "path": .string("Sources/File.swift"),
                            "kind": .object(["type": .string("update")]),
                            "diff": .string("updated"),
                        ]),
                    ])
                )
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-review",
                turn: .init(id: "turn-review", status: "completed")
            )
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-review")
        )

        let events = try await eventsTask.value
        let completedItems = events.compactMap { event -> (item: CodexThreadItem, turnID: CodexTurnID?)? in
            guard case .itemCompleted(let item, let turnID) = event else {
                return nil
            }
            return (item, turnID)
        }
        #expect(completedItems.count == 4)
        #expect(completedItems.first?.turnID == "turn-review")
        #expect(completedItems.first?.item.kind == .commandExecution)
        #expect(completedItems.first?.item.text == "passed")
        #expect(completedItems.contains {
            if case .reasoning(let reasoning) = $0.item.content {
                reasoning.summary == ["Checked the diff"]
            } else {
                false
            }
        })
        #expect(completedItems.contains {
            if case .toolCall(let toolCall) = $0.item.content {
                toolCall.name == "review_read"
            } else {
                false
            }
        })
        #expect(completedItems.contains {
            if case .fileChange(let fileChange) = $0.item.content {
                fileChange.path == "Sources/File.swift"
            } else {
                false
            }
        })

        let logs = try await collect(review.logEntries)
        #expect(logs.map(\.id) == ["command-1", "reasoning-1", "tool-1", "file-1"])
        #expect(logs.allSatisfy { $0.turnID == "turn-review" })
        #expect(logs.contains {
            if case .command(let command) = $0.item?.content {
                command.command == "swift test"
            } else {
                false
            }
        })
        #expect(logs.contains {
            if case .toolCall(let toolCall) = $0.item?.content {
                toolCall.name == "review_read"
            } else {
                false
            }
        })
        #expect(logs.contains {
            if case .fileChange(let fileChange) = $0.item?.content {
                fileChange.path == "Sources/File.swift"
            } else {
                false
            }
        })
    }

    @Test func reviewSessionExposesPersistableLifecycleIdentity() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-source", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )

        let thread = try await runtime.server.startThread(
            in: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            options: .init(model: "gpt-5")
        )
        let review = try await thread.startReview(
            target: .baseBranch("main"),
            delivery: .detached
        )

        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )
        #expect(review.identity == identity)
        #expect(review.model == nil)
        #expect(review.sourceThreadID == "thread-source")
        #expect(review.activeTurnThreadID == "thread-review")
        #expect(review.associatedThreadIDs == ["thread-source", "thread-review"])
        #expect(review.cleanupThreadIDs == ["thread-review", "thread-source"])
        #expect(identity.associatedThreadIDs == ["thread-source", "thread-review"])
        #expect(identity.cleanupThreadIDs == ["thread-review", "thread-source"])

        let encoded = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(CodexReviewIdentity.self, from: encoded)
        #expect(decoded == identity)
    }

    @Test func inlineReviewIdentityKeepsDetachedReviewThreadNil() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadStart(threadID: "thread-source", model: "gpt-5")
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-source"
        )

        let thread = try await runtime.server.startThread(
            in: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            options: .init(model: "gpt-5")
        )
        let review = try await thread.startReview(target: .baseBranch("main"))

        #expect(review.reviewThreadID == "thread-source")
        #expect(review.identity == CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            model: "gpt-5"
        ))
        #expect(review.identity.reviewThreadID == nil)
        #expect(review.identity.activeTurnThreadID == "thread-source")
        #expect(review.identity.cleanupThreadIDs == ["thread-source"])
    }

    @Test func appServerResumeReviewRestoresEventsAndCancellationFromIdentity() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(
            id: "thread-review",
            workspace: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        ))
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )

        let review = try await runtime.server.resumeReview(identity)
        let cancellation = try await review.cancel()
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(threadID: "thread-review", turn: .init(id: "turn-review", status: "completed"))
        )

        #expect(review.identity == identity)
        #expect(cancellation.threadID == "thread-review")
        #expect(cancellation.turnID == "turn-review")
        let requests = await runtime.transport.recordedRequests()
        #expect(requests.map(\.method) == [
            "initialize",
            "thread/resume",
            "turn/interrupt",
        ])
        let resumeParams = try requests[1].decodeParams(AppServerAPI.Thread.Resume.Params.self)
        #expect(resumeParams.threadID == "thread-review")
        #expect(resumeParams.model == "gpt-5")
        let interruptParams = try requests[2].decodeParams(AppServerAPI.Turn.Interrupt.Params.self)
        #expect(interruptParams.threadID == "thread-review")
        #expect(interruptParams.turnID == "turn-review")

        var iterator = review.events.makeAsyncIterator()
        var terminalResponse: CodexResponse?
        while let event = try await iterator.next() {
            if case .terminal(.completed(let response)) = event {
                terminalResponse = response
            }
        }
        if let terminalResponse {
            #expect(terminalResponse.turnID == "turn-review")
        } else {
            Issue.record("Expected resumed review.events to receive turn-only completion.")
        }
    }

    @Test func appServerResumeReviewUsesThreadOptionModelOverride() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(
            .init(id: "thread-review"),
            model: "gpt-5.1"
        )
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )

        let review = try await runtime.server.resumeReview(
            identity,
            threadOptions: .init(model: "gpt-5.1")
        )

        #expect(review.model == "gpt-5.1")
        #expect(review.identity.model == "gpt-5.1")
        let request = try #require(await runtime.transport.recordedRequests().last)
        let params = try request.decodeParams(AppServerAPI.Thread.Resume.Params.self)
        #expect(params.threadID == "thread-review")
        #expect(params.model == "gpt-5.1")
    }

    @Test func appServerResumeReviewPromotesTheResponseBaselineToItsPersistedTurnIdentity() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(
            id: "thread-review",
            workspace: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            turns: [
                .init(
                    id: "rollout-synthesized-turn",
                    state: .inProgress,
                    items: [
                        .init(
                            id: "response-message",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "response-message",
                                role: .assistant,
                                text: "From resume response"
                            ))
                        ),
                    ]
                ),
            ]
        ))
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )

        let review = try await runtime.server.resumeReview(identity)
        let eventThread = await runtime.server.reviewEventThread(
            for: review,
            workspace: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        )
        try await runtime.transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-review")
        )

        let events = try await collect(eventThread.events)
        #expect(events.containsThreadText("From resume response", turnID: "turn-review"))
        #expect(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.id == "rollout-synthesized-turn"
            }
            return false
        } == false)
    }

    @Test func reviewSessionCancelHookReceivesCurrentActiveTurn() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        await runtime.transport.enqueueFailure(
            code: -32602,
            message: "expected active turn id turn-review but found turn-new",
            for: "turn/interrupt"
        )
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )
        let recorder = CancellationRecorder()

        let review = try await runtime.server.resumeReview(identity)
        let cancellation = try await review.cancel { cancellation in
            await recorder.append(cancellation)
        }

        #expect(cancellation.threadID == "thread-review")
        #expect(cancellation.turnID == "turn-new")
        #expect(await recorder.values() == [
            CodexTurnCancellation(threadID: "thread-review", turnID: "turn-new")
        ])
        let turnIDs = try await runtime.transport.recordedRequests(method: "turn/interrupt")
            .map { request in
                try request.decodeParams(AppServerAPI.Turn.Interrupt.Params.self).turnID
        }
        #expect(turnIDs == ["turn-review", "turn-new"])
    }

    @Test func threadTurnsListRequestUsesThreadScope() {
        let request = AppServerAPI.Thread.Turns.List.Request(params: .init(threadID: "thread-1"))

        #expect(request.scope == .thread("thread-1"))
    }

    @Test func appServerPrepareAndRestartReviewUsesLifecycleControlSequence() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueEmpty(for: "thread/rollback")
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-source"))
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-restarted",
            reviewThreadID: "thread-review-restarted"
        )
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )

        let prepareTask = Task {
            try await runtime.server.prepareReviewRestart(identity)
        }
        defer {
            prepareTask.cancel()
        }
        await runtime.transport.waitForRequest(method: "turn/interrupt")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(threadID: "thread-review", turn: .init(id: "turn-review", status: "interrupted"))
        )
        let token = try await prepareTask.value
        let review = try await runtime.server.restartPreparedReview(
            token,
            target: .baseBranch("main"),
            delivery: .detached
        )

        #expect(token.interruptedIdentity == identity)
        #expect(review.identity == CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-restarted",
            reviewThreadID: "thread-review-restarted"
        ))
        let requests = await runtime.transport.recordedRequests()
        #expect(requests.map(\.method) == [
            "initialize",
            "thread/resume",
            "turn/interrupt",
            "thread/resume",
            "thread/rollback",
            "thread/resume",
            "review/start",
        ])
        let resumeThreadIDs = try requests.filter { $0.method == "thread/resume" }.map {
            try $0.decodeParams(AppServerAPI.Thread.Resume.Params.self).threadID
        }
        #expect(resumeThreadIDs == ["thread-review", "thread-review", "thread-source"])
        let resumeModels = try requests.filter { $0.method == "thread/resume" }.map {
            try $0.decodeParams(AppServerAPI.Thread.Resume.Params.self).model
        }
        #expect(resumeModels == ["gpt-5", "gpt-5", nil])
        let interrupt = try #require(requests.first { $0.method == "turn/interrupt" })
        let interruptParams = try interrupt.decodeParams(AppServerAPI.Turn.Interrupt.Params.self)
        #expect(interruptParams.threadID == "thread-review")
        #expect(interruptParams.turnID == "turn-review")
        let rollback = try #require(requests.first { $0.method == "thread/rollback" })
        let rollbackParams = try rollback.decodeParams(AppServerAPI.Thread.Rollback.Params.self)
        #expect(rollbackParams.threadID == "thread-review")
        #expect(rollbackParams.numTurns == 1)
        let reviewStart = try #require(requests.last)
        let reviewStartParams = try reviewStart.decodeParams(AppServerAPI.Review.Start.Params.self)
        #expect(reviewStartParams.threadID == "thread-source")
        #expect(reviewStartParams.target == .baseBranch("main"))
        #expect(reviewStartParams.delivery == .detached)
        await runtime.close()
    }

    @Test func prepareReviewRestartRejectsConcurrentPreparationForTheSameSource() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let interruptGate = CodexAppServerTestGate()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
        await runtime.transport.holdNextIgnoringCancellation(
            method: "turn/interrupt",
            gate: interruptGate
        )
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )
        let firstPreparation = Task {
            try await runtime.server.prepareReviewRestart(identity)
        }
        defer {
            firstPreparation.cancel()
        }
        await runtime.transport.waitForRequest(method: "turn/interrupt")

        await #expect(throws: CodexAppServerError.self) {
            try await runtime.server.prepareReviewRestart(identity)
        }

        await interruptGate.open()
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-review",
                turn: .init(id: "turn-review", status: "interrupted")
            )
        )
        #expect(try await firstPreparation.value.interruptedIdentity == identity)
        #expect(await runtime.transport.recordedRequests(method: "turn/interrupt").count == 1)
        await runtime.close()
    }

    @Test func prepareReviewRestartRetainsInputIdentityWhenResumeFails() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "resume failed",
            for: "thread/resume"
        )
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )

        await #expect(throws: CodexAppServerError.self) {
            try await runtime.server.prepareReviewRestart(identity)
        }

        #expect(await runtime.server.discardAllPreparedReviewRestarts() == [
            "thread-source": [identity],
        ])
        await runtime.close()
    }

    @Test func prepareInlineReviewRestartKeepsOuterThreadEventOwnerWhenInterruptRedirects() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-source"))
        await runtime.transport.enqueueFailure(
            code: -32602,
            message: "expected active turn id turn-review but found turn-review-child",
            for: "turn/interrupt"
        )
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            model: "gpt-5"
        )

        let prepareTask = Task {
            try await runtime.server.prepareReviewRestart(identity)
        }
        defer {
            prepareTask.cancel()
        }
        await runtime.transport.waitForRequest(method: "turn/interrupt", count: 2)
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-review-child",
                turn: .init(id: "turn-review-child", status: "interrupted")
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-source",
                turnID: "turn-review",
                item: .init(
                    id: "review-output",
                    type: "agentMessage",
                    text: "Review interrupted"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-source",
                turn: .init(id: "turn-review", status: "interrupted")
            )
        )

        let token = try await prepareTask.value
        #expect(token.interruptedIdentity == identity)
        let turnIDs = try await runtime.transport
            .recordedRequests(method: "turn/interrupt")
            .map { request in
                try request.decodeParams(AppServerAPI.Turn.Interrupt.Params.self).turnID
            }
        #expect(turnIDs == ["turn-review", "turn-review-child"])
        await runtime.close()
    }

    @Test func cleanupReviewKeepsCancellationRetryCleanupForPreparedRestart() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        await runtime.transport.enqueueFailure(
            code: -32602,
            message: "expected active turn id turn-review but found turn-new",
            for: "turn/interrupt"
        )
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )
        let restartedIdentity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-restarted",
            reviewThreadID: "thread-review-restarted",
            model: "gpt-5"
        )

        let prepareTask = Task {
            try await runtime.server.prepareReviewRestart(identity)
        }
        defer {
            prepareTask.cancel()
        }
        await runtime.transport.waitForRequest(method: "turn/interrupt", count: 2)
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(threadID: "thread-review", turn: .init(id: "turn-new", status: "interrupted"))
        )
        _ = try await prepareTask.value
        for _ in 0..<3 {
            try await runtime.transport.enqueueEmpty(for: "thread/delete")
        }
        await runtime.server.cleanupReview(restartedIdentity)

        let interruptTurnIDs = try await runtime.transport.recordedRequests(method: "turn/interrupt").map {
            try $0.decodeParams(AppServerAPI.Turn.Interrupt.Params.self).turnID
        }
        #expect(interruptTurnIDs == ["turn-review", "turn-new"])
        let deletedThreadIDs = try await runtime.transport.recordedRequests(method: "thread/delete").map {
            try $0.decodeParams(AppServerAPI.Thread.Delete.Params.self).threadID
        }
        #expect(deletedThreadIDs == [
            "thread-review",
            "thread-review-restarted",
            "thread-source",
        ])
        await runtime.close()
    }

    @Test func cleanupReviewDeletesDetachedThreadsBeforeSourceAndDedupes() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )
        for _ in 0..<4 {
            try await runtime.transport.enqueueEmpty(for: "thread/delete")
        }

        let result = await runtime.server.cleanupReview(
            identity,
            additionalCleanupThreadIDs: [
                ["thread-source", "thread-extra", "thread-review"],
                ["thread-extra", "thread-extra-2", "thread-source"],
            ]
        )

        #expect(result == CodexReviewCleanupResult(
            attemptedThreadIDs: [
                "thread-review",
                "thread-extra",
                "thread-extra-2",
                "thread-source",
            ],
            failures: []
        ))

        let deletedThreadIDs = try await runtime.transport.recordedRequests(method: "thread/delete").map {
            try $0.decodeParams(AppServerAPI.Thread.Delete.Params.self).threadID
        }
        #expect(deletedThreadIDs == [
            "thread-review",
            "thread-extra",
            "thread-extra-2",
            "thread-source",
        ])
        await runtime.close()
    }

    @Test func cleanupReviewRestoresRetainedIdentitiesAfterDeletionFailure() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )

        let prepareTask = Task {
            try await runtime.server.prepareReviewRestart(identity)
        }
        defer {
            prepareTask.cancel()
        }
        await runtime.transport.waitForRequest(method: "turn/interrupt")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-review",
                turn: .init(id: "turn-review", status: "interrupted")
            )
        )
        _ = try await prepareTask.value

        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "delete failed",
            for: "thread/delete"
        )
        for _ in 0..<3 {
            try await runtime.transport.enqueueEmpty(for: "thread/delete")
        }
        let failedCleanup = await runtime.server.cleanupReview(identity)
        #expect(failedCleanup.attemptedThreadIDs == ["thread-review", "thread-source"])
        #expect(failedCleanup.failures.map(\.threadID) == ["thread-review"])
        #expect(failedCleanup.failures.first?.message.contains("delete failed") == true)

        let retriedCleanup = await runtime.server.cleanupReview(identity)
        #expect(retriedCleanup == CodexReviewCleanupResult(
            attemptedThreadIDs: ["thread-review", "thread-source"],
            failures: []
        ))

        let deletedThreadIDs = try await runtime.transport
            .recordedRequests(method: "thread/delete")
            .map { request in
                try request.decodeParams(AppServerAPI.Thread.Delete.Params.self).threadID
            }
        #expect(deletedThreadIDs == [
            "thread-review",
            "thread-source",
            "thread-review",
            "thread-source",
        ])
        await runtime.close()
    }

    @Test func restartPreparedReviewRejectsStaleTokenWithMeaningfulError() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let token = CodexReviewRestartToken(
            id: "stale-token",
            interruptedIdentity: .init(threadID: "thread-source", turnID: "turn-review")
        )

        do {
            _ = try await runtime.server.restartPreparedReview(token, target: .baseBranch("main"))
            Issue.record("Expected stale restart token to throw.")
        } catch let error as CodexAppServerError {
            #expect(error == .reviewRestartUnavailable("stale-token"))
            #expect(error.localizedDescription.contains("stale-token"))
        } catch {
            Issue.record("Expected CodexAppServerError, got \(error).")
        }
        await runtime.close()
    }

    @Test func discardPreparedReviewRestartRequiresTheFullTokenAndTransfersOnce() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )
        let token = try await prepareRestartToken(runtime: runtime, identity: identity)
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueEmpty(for: "thread/rollback")
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-source"))
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-restarted",
            reviewThreadID: "thread-source"
        )
        let restarted = try await runtime.server.restartPreparedReview(
            token,
            target: .baseBranch("main")
        )
        let forged = CodexReviewRestartToken(
            id: token.id,
            interruptedIdentity: .init(
                threadID: "thread-source",
                turnID: "forged-turn",
                reviewThreadID: "thread-review",
                model: "gpt-5"
            )
        )

        #expect(await runtime.server.discardPreparedReviewRestart(forged).isEmpty)
        #expect(await runtime.server.discardPreparedReviewRestart(token) == [
            identity,
            restarted.identity,
        ])
        #expect(await runtime.server.discardPreparedReviewRestart(token).isEmpty)
        await runtime.close()
    }

    @Test func discardAllPreparedReviewRestartsReturnsOrderedSourceGroups() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let firstIdentity = CodexReviewIdentity(
            threadID: "thread-source-a",
            turnID: "turn-review-a",
            reviewThreadID: "thread-review-a"
        )
        let firstToken = try await prepareRestartToken(
            runtime: runtime,
            identity: firstIdentity
        )
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review-a"))
        try await runtime.transport.enqueueEmpty(for: "thread/rollback")
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-source-a"))
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-restarted-a",
            reviewThreadID: "thread-review-restarted-a"
        )
        let restarted = try await runtime.server.restartPreparedReview(
            firstToken,
            target: .uncommittedChanges,
            delivery: .detached
        )

        let secondIdentity = CodexReviewIdentity(
            threadID: "thread-source-b",
            turnID: "turn-review-b",
            reviewThreadID: "thread-review-b"
        )
        _ = try await prepareRestartToken(
            runtime: runtime,
            identity: secondIdentity
        )

        let retainedBySource = await runtime.server.discardAllPreparedReviewRestarts()

        #expect(retainedBySource == [
            "thread-source-a": [firstIdentity, restarted.identity],
            "thread-source-b": [secondIdentity],
        ])
        #expect(await runtime.server.discardAllPreparedReviewRestarts().isEmpty)
        let resumeCount = await runtime.transport.recordedRequests(method: "thread/resume").count
        await #expect(throws: CodexAppServerError.self) {
            try await runtime.server.prepareReviewRestart(.init(
                threadID: "thread-source-c",
                turnID: "turn-review-c",
                reviewThreadID: "thread-review-c"
            ))
        }
        #expect(await runtime.transport.recordedRequests(method: "thread/resume").count == resumeCount)
        await runtime.close()
    }

    @Test func restartPreparedReviewKeepsTokenForRetryAfterPartialFailure() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )
        let prepareTask = Task {
            try await runtime.server.prepareReviewRestart(identity)
        }
        defer {
            prepareTask.cancel()
        }
        await runtime.transport.waitForRequest(method: "turn/interrupt")
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(threadID: "thread-review", turn: .init(id: "turn-review", status: "interrupted"))
        )
        let token = try await prepareTask.value

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueEmpty(for: "thread/rollback")
        await runtime.transport.enqueueFailure(
            code: -32000,
            message: "source resume failed",
            for: "thread/resume"
        )
        do {
            _ = try await runtime.server.restartPreparedReview(token, target: .baseBranch("main"))
            Issue.record("Expected source resume failure.")
        } catch {
            #expect(String(describing: error).contains("source resume failed"))
        }

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-source"))
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-restarted",
            reviewThreadID: "thread-source"
        )
        let review = try await runtime.server.restartPreparedReview(
            token,
            target: .baseBranch("main")
        )

        #expect(review.identity.threadID == "thread-source")
        #expect(review.identity.turnID == "turn-restarted")
        let requests = await runtime.transport.recordedRequests()
        #expect(requests.map(\.method) == [
            "initialize",
            "thread/resume",
            "turn/interrupt",
            "thread/resume",
            "thread/rollback",
            "thread/resume",
            "thread/resume",
            "review/start",
        ])
        #expect(requests.filter { $0.method == "thread/rollback" }.count == 1)
        let resumeThreadIDs = try requests.filter { $0.method == "thread/resume" }.map {
            try $0.decodeParams(AppServerAPI.Thread.Resume.Params.self).threadID
        }
        #expect(resumeThreadIDs == [
            "thread-review",
            "thread-review",
            "thread-source",
            "thread-source",
        ])
    }

    @Test func restartPreparedReviewExhaustsItsTwoInvocationBudget() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )
        let token = try await prepareRestartToken(runtime: runtime, identity: identity)

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueEmpty(for: "thread/rollback")
        await runtime.transport.enqueueFailure(
            code: -32000,
            message: "first source resume failed",
            for: "thread/resume"
        )
        await #expect(throws: CodexAppServerError.self) {
            try await runtime.server.restartPreparedReview(
                token,
                target: .baseBranch("main")
            )
        }

        await runtime.transport.enqueueFailure(
            code: -32000,
            message: "second source resume failed",
            for: "thread/resume"
        )
        await #expect(throws: CodexAppServerError.reviewRestartUnavailable(token.id)) {
            try await runtime.server.restartPreparedReview(
                token,
                target: .baseBranch("main")
            )
        }
        await #expect(throws: CodexAppServerError.reviewRestartUnavailable(token.id)) {
            try await runtime.server.restartPreparedReview(
                token,
                target: .baseBranch("main")
            )
        }

        #expect(await runtime.transport.recordedRequests(method: "thread/rollback").count == 1)
        let resumeThreadIDs = try await runtime.transport.recordedRequests(method: "thread/resume")
            .map { request in
                try request.decodeParams(AppServerAPI.Thread.Resume.Params.self).threadID
            }
        #expect(resumeThreadIDs == [
            "thread-review",
            "thread-review",
            "thread-source",
            "thread-source",
        ])
    }

    @Test func restartPreparedReviewInvalidatesAfterAmbiguousRollbackResponse() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )
        let token = try await prepareRestartToken(runtime: runtime, identity: identity)
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueJSON(
            "\"not-an-empty-response\"",
            for: "thread/rollback"
        )

        await #expect(throws: CodexAppServerError.self) {
            try await runtime.server.restartPreparedReview(
                token,
                target: .baseBranch("main")
            )
        }
        await #expect(throws: CodexAppServerError.reviewRestartUnavailable(token.id)) {
            try await runtime.server.restartPreparedReview(
                token,
                target: .baseBranch("main")
            )
        }
        #expect(await runtime.server.discardPreparedReviewRestart(token) == [identity])
        #expect(await runtime.transport.recordedRequests(method: "thread/rollback").count == 1)
    }

    @Test func restartPreparedReviewCancellationOnlyRemovesTheWaitingCaller() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )
        let token = try await prepareRestartToken(runtime: runtime, identity: identity)

        let rollbackGate = CodexAppServerTestGate()
        let sourceResumeGate = CodexAppServerTestGate()
        await runtime.transport.holdNextIgnoringCancellation(
            method: "thread/rollback",
            gate: rollbackGate
        )
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueEmpty(for: "thread/rollback")
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-source"))
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-restarted",
            reviewThreadID: "thread-source"
        )
        let restart = Task {
            try await runtime.server.restartPreparedReview(token, target: .baseBranch("main"))
        }
        defer {
            restart.cancel()
        }

        await runtime.transport.waitForRequest(method: "thread/rollback")
        await runtime.transport.holdNextIgnoringCancellation(
            method: "thread/resume",
            gate: sourceResumeGate
        )
        await rollbackGate.open()
        await runtime.transport.waitForRequest(method: "thread/resume", count: 3)
        await runtime.server.waitForReviewRestartWaiterCountForTesting(
            tokenID: token.id,
            atLeast: 1
        )
        restart.cancel()

        do {
            _ = try await restart.value
            Issue.record("Expected cancelled source resume failure.")
        } catch is CancellationError {
            #expect(await runtime.transport.recordedRequests(method: "review/start").isEmpty)
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }

        await sourceResumeGate.open()
        let review = try await runtime.server.restartPreparedReview(token, target: .baseBranch("main"))

        #expect(review.identity.threadID == "thread-source")
        #expect(review.identity.turnID == "turn-restarted")
        let requests = await runtime.transport.recordedRequests()
        #expect(requests.map(\.method) == [
            "initialize",
            "thread/resume",
            "turn/interrupt",
            "thread/resume",
            "thread/rollback",
            "thread/resume",
            "review/start",
        ])
        #expect(requests.filter { $0.method == "thread/rollback" }.count == 1)
    }

    @Test func discardPreparedReviewRestartCleansLateDetachedSessionWithoutDeletingThreads() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )
        let token = try await prepareRestartToken(runtime: runtime, identity: identity)
        let reviewStartGate = CodexAppServerTestGate()

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueEmpty(for: "thread/rollback")
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-source"))
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-restarted",
            reviewThreadID: "thread-review-restarted"
        )
        await runtime.transport.holdNextIgnoringCancellation(
            method: "review/start",
            gate: reviewStartGate
        )

        let restart = Task {
            try await runtime.server.restartPreparedReview(
                token,
                target: .baseBranch("main"),
                delivery: .detached
            )
        }
        defer {
            restart.cancel()
        }
        await runtime.transport.waitForRequest(method: "review/start")
        let discard = Task {
            await runtime.server.discardPreparedReviewRestart(token)
        }
        await runtime.server.waitForReviewRestartInvalidationRequestForTesting(
            tokenID: token.id
        )
        await reviewStartGate.open()
        await runtime.transport.waitForRequest(method: "turn/interrupt", count: 2)
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-restarted", status: "interrupted"))
        )
        let retainedIdentities = await discard.value

        do {
            _ = try await restart.value
            Issue.record("Expected invalidated review start failure.")
        } catch let error as CodexAppServerError {
            #expect(error == .reviewRestartUnavailable(token.id))
            let requests = await runtime.transport.recordedRequests()
            #expect(requests.map(\.method) == [
                "initialize",
                "thread/resume",
                "turn/interrupt",
                "thread/resume",
                "thread/rollback",
                "thread/resume",
                "review/start",
                "turn/interrupt",
            ])
        } catch {
            Issue.record("Expected CodexAppServerError, got \(error).")
        }
        #expect(retainedIdentities == [
            identity,
            CodexReviewIdentity(
                threadID: "thread-source",
                turnID: "turn-restarted",
                reviewThreadID: "thread-review-restarted"
            ),
        ])

        do {
            _ = try await runtime.server.restartPreparedReview(token, target: .baseBranch("main"))
            Issue.record("Expected cleaned up restart token to throw.")
        } catch let error as CodexAppServerError {
            #expect(error == .reviewRestartUnavailable(token.id))
        } catch {
            Issue.record("Expected CodexAppServerError, got \(error).")
        }
    }

    @Test func discardPreparedReviewRestartAwaitsInlineOuterTerminalAfterRedirectedChild() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )
        let token = try await prepareRestartToken(runtime: runtime, identity: identity)
        let reviewStartGate = CodexAppServerTestGate()

        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueEmpty(for: "thread/rollback")
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-source"))
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-restarted",
            reviewThreadID: "thread-source"
        )
        await runtime.transport.enqueueFailure(
            code: -32602,
            message: "expected active turn id turn-restarted but found turn-review-child",
            for: "turn/interrupt"
        )
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
        await runtime.transport.holdNextIgnoringCancellation(
            method: "review/start",
            gate: reviewStartGate
        )

        let restart = Task {
            try await runtime.server.restartPreparedReview(
                token,
                target: .baseBranch("main")
            )
        }
        defer {
            restart.cancel()
        }
        await runtime.transport.waitForRequest(method: "review/start")
        let discard = Task {
            await runtime.server.discardPreparedReviewRestart(token)
        }
        await runtime.server.waitForReviewRestartInvalidationRequestForTesting(
            tokenID: token.id
        )
        await reviewStartGate.open()
        await runtime.transport.waitForRequest(method: "turn/interrupt", count: 3)
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-review-child",
                turn: .init(id: "turn-review-child", status: "interrupted")
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-source",
                turnID: "turn-restarted",
                item: .init(
                    id: "review-output",
                    type: "agentMessage",
                    text: "Review interrupted"
                )
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(
                threadID: "thread-source",
                turn: .init(id: "turn-restarted", status: "interrupted")
            )
        )

        let retainedIdentities = await discard.value
        #expect(retainedIdentities == [
            identity,
            CodexReviewIdentity(
                threadID: "thread-source",
                turnID: "turn-restarted",
                model: "gpt-5"
            ),
        ])
        await #expect(throws: CodexAppServerError.reviewRestartUnavailable(token.id)) {
            try await restart.value
        }
        #expect(await runtime.transport.recordedRequests(method: "thread/delete").isEmpty)
        await runtime.close()
    }

    @Test func restartPreparedReviewJoinsConcurrentMatchingInvocation() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )
        let token = try await prepareRestartToken(runtime: runtime, identity: identity)

        let resumeGate = CodexAppServerTestGate()
        await runtime.transport.holdNext(method: "thread/resume", gate: resumeGate)
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueEmpty(for: "thread/rollback")
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-source"))
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-restarted",
            reviewThreadID: "thread-source"
        )
        let firstRestart = Task {
            try await runtime.server.restartPreparedReview(token, target: .baseBranch("main"))
        }
        defer {
            firstRestart.cancel()
        }
        await runtime.transport.waitForRequest(method: "thread/resume", count: 2)

        let secondRestart = Task {
            try await runtime.server.restartPreparedReview(
                token,
                target: .baseBranch("main")
            )
        }
        defer {
            secondRestart.cancel()
        }
        await runtime.server.waitForReviewRestartWaiterCountForTesting(
            tokenID: token.id,
            atLeast: 2
        )

        await resumeGate.open()
        let firstReview = try await firstRestart.value
        let secondReview = try await secondRestart.value

        #expect(firstReview.identity == secondReview.identity)
        #expect(firstReview.turnID == "turn-restarted")
        let requests = await runtime.transport.recordedRequests()
        #expect(requests.filter { $0.method == "thread/rollback" }.count == 1)
        #expect(requests.filter { $0.method == "review/start" }.count == 1)
        let resumeThreadIDs = try requests.filter { $0.method == "thread/resume" }.map {
            try $0.decodeParams(AppServerAPI.Thread.Resume.Params.self).threadID
        }
        #expect(resumeThreadIDs == ["thread-review", "thread-review", "thread-source"])
    }

    @Test func restartPreparedReviewRejectsConcurrentDifferentInvocation() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let identity = CodexReviewIdentity(
            threadID: "thread-source",
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            model: "gpt-5"
        )
        let token = try await prepareRestartToken(runtime: runtime, identity: identity)
        let resumeGate = CodexAppServerTestGate()
        await runtime.transport.holdNext(method: "thread/resume", gate: resumeGate)
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-review"))
        try await runtime.transport.enqueueEmpty(for: "thread/rollback")
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-source"))
        try await runtime.transport.enqueueReviewStart(
            turnID: "turn-restarted",
            reviewThreadID: "thread-source"
        )
        let restart = Task {
            try await runtime.server.restartPreparedReview(
                token,
                target: .baseBranch("main")
            )
        }
        defer {
            restart.cancel()
        }
        await runtime.transport.waitForRequest(method: "thread/resume", count: 2)
        await runtime.server.waitForReviewRestartWaiterCountForTesting(
            tokenID: token.id,
            atLeast: 1
        )

        await #expect(throws: CodexAppServerError.reviewRestartUnavailable(token.id)) {
            try await runtime.server.restartPreparedReview(
                token,
                target: .baseBranch("release")
            )
        }

        await resumeGate.open()
        #expect(try await restart.value.turnID == "turn-restarted")
        #expect(await runtime.transport.recordedRequests(method: "thread/rollback").count == 1)
        #expect(await runtime.transport.recordedRequests(method: "review/start").count == 1)
    }

    @Test func reviewStartSeedsDetachedTurnRoutingForTurnOnlyTerminalNotifications() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "turn-review",
                reviewThreadID: "thread-review"
            ),
            for: "review/start"
        )
        let gate = CodexAppServerTestGate()
        await transport.holdNext(method: "review/start", gate: gate)
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router, connectionLease: harness.lease)

        let reviewTask = Task {
            try await thread.startReview(
                target: .baseBranch("main"),
                delivery: .detached
            )
        }
        await transport.waitForRequest(method: "review/start")
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(threadID: "thread-review", turnID: "turn-review")
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(id: "message-early", type: "agentMessage", text: "Buffered")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(threadID: "thread-review", turn: .init(id: "turn-review", status: "completed"))
        )
        await gate.open()
        let review = try await reviewTask.value

        var eventIterator = review.events.makeAsyncIterator()
        var terminalResponse: CodexResponse?
        while let event = try await eventIterator.next() {
            if case .terminal(.completed(let response)) = event {
                terminalResponse = response
            }
        }
        if let terminalResponse {
            #expect(terminalResponse.turnID == "turn-review")
            #expect(terminalResponse.transcript.items.contains { $0.text == "Buffered" })
        } else {
            Issue.record("Expected review.events to receive turn-only completion.")
        }

        var progressIterator = review.progress.makeAsyncIterator()
        let progress = try #require(try await progressIterator.next())
        if case .terminal(let outcome) = progress {
            #expect(outcome.response.turnID == "turn-review")
        } else {
            Issue.record("Expected terminal review progress.")
        }
        #expect(try await progressIterator.next() == nil)
    }

    @Test func normalTurnSeedsThreadRoutingForTurnOnlyTerminalNotifications() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router, connectionLease: harness.lease)
        let eventTask = Task { () -> CodexThreadEvent? in
            var iterator = thread.events.makeAsyncIterator()
            while let event = try await iterator.next() {
                if case .terminal = event {
                    return event
                }
            }
            return nil
        }
        defer {
            eventTask.cancel()
        }
        #expect(await eventually {
            router.threadSubscriberCountForTesting(for: "thread-1") == 1
        })

        _ = try await thread.streamResponse(to: "Run checks.")
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "completed"))
        )

        let event = try await withTimeout {
            try await eventTask.value
        }
        if case .terminal(.completed(let response)) = event {
            #expect(response.turnID == "turn-1")
        } else {
            Issue.record("Expected thread.events to receive turn-only completion.")
        }
    }

    @Test func reviewEventsAndLogsPreserveTurnDiagnosticsWithoutFabricatingTerminal() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "turn-review",
                reviewThreadID: "thread-review"
            ),
            for: "review/start"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router, connectionLease: harness.lease)

        let review = try await thread.startReview(
            target: .baseBranch("main"),
            delivery: .detached
        )
        let reviewThread = CodexThread(
            id: "thread-review",
            client: client,
            router: router,
            connectionLease: harness.lease
        )
        let expectedDiagnostics = [
            CodexTurnDiagnostic(
                error: .init(
                    message: "recoverable",
                    info: .serverOverloaded,
                    additionalDetails: "retry scheduled"
                ),
                willRetry: true
            ),
            CodexTurnDiagnostic(
                error: .init(message: "not recoverable", info: .badRequest),
                willRetry: false
            ),
        ]
        let diagnosticEvents = Task { () throws -> [CodexTurnDiagnostic] in
            var diagnostics: [CodexTurnDiagnostic] = []
            for try await event in review.events {
                if case .diagnostic(let diagnostic, turnID: "turn-review") = event {
                    diagnostics.append(diagnostic)
                    if diagnostics.count == expectedDiagnostics.count {
                        return diagnostics
                    }
                }
            }
            return diagnostics
        }
        let turnDiagnosticLogs = Task { () throws -> [CodexThreadLogEntry] in
            var entries: [CodexThreadLogEntry] = []
            for try await entry in review.logEntries {
                if case .diagnostic = entry {
                    entries.append(entry)
                    if entries.count == expectedDiagnostics.count {
                        return entries
                    }
                }
            }
            return entries
        }
        let threadDiagnosticLogs = Task { () throws -> [CodexThreadLogEntry] in
            var entries: [CodexThreadLogEntry] = []
            for try await entry in reviewThread.logEntries {
                if case .diagnostic = entry {
                    entries.append(entry)
                    if entries.count == expectedDiagnostics.count {
                        return entries
                    }
                }
            }
            return entries
        }
        defer {
            diagnosticEvents.cancel()
            turnDiagnosticLogs.cancel()
            threadDiagnosticLogs.cancel()
        }
        #expect(await eventually {
            let turnSubscriberCount = await harness.turnReplayStore.subscriberCountForTesting(
                turnID: "turn-review"
            )
            return turnSubscriberCount == 2
                && router.threadSubscriberCountForTesting(for: "thread-review") == 1
        })
        let emitter = CodexAppServerTestNotificationEmitter(transport: transport)
        try await emitter.emitError(
            threadID: "thread-review",
            turnID: "turn-review",
            error: expectedDiagnostics[0].error,
            willRetry: expectedDiagnostics[0].willRetry
        )
        try await emitter.emitError(
            threadID: "thread-review",
            turnID: "turn-review",
            error: expectedDiagnostics[1].error,
            willRetry: expectedDiagnostics[1].willRetry
        )

        #expect(try await withTimeout { try await diagnosticEvents.value } == expectedDiagnostics)
        let turnLogEntries = try await withTimeout { try await turnDiagnosticLogs.value }
        let threadLogEntries = try await withTimeout { try await threadDiagnosticLogs.value }
        for logEntries in [turnLogEntries, threadLogEntries] {
            #expect(logEntries.map(\.diagnostic) == expectedDiagnostics.map(Optional.some))
            #expect(logEntries.map(\.turnID) == ["turn-review", "turn-review"])
            #expect(logEntries.map(\.phase) == [.diagnostic, .diagnostic])
            #expect(Set(logEntries.map(\.id)).count == expectedDiagnostics.count)
        }
        #expect(try await review.response.turn.state.cachedOutcome() == nil)

        var progress = review.progress.makeAsyncIterator()
        guard case .running(let transcript, let usage) = try await progress.next() else {
            Issue.record("A nonterminal diagnostic must preserve running progress.")
            return
        }
        #expect(transcript.items.isEmpty)
        #expect(usage == nil)
        await harness.close()
    }

    @Test func promptPartsEncodeToAppServerInputItems() {
        let prompt = CodexPrompt(parts: [
            .text("Describe these files."),
            .imageURL(URL(string: "https://example.test/diagram.png")!),
            .localImage(URL(fileURLWithPath: "/tmp/screenshot.png")),
            .skill(name: "checks", path: URL(fileURLWithPath: "/tmp/skills/checks")),
            .mention(name: "repo", path: URL(fileURLWithPath: "/tmp/repo")),
            .mention(name: "app", path: URL(string: "app://demo-app")!),
            .mention(name: "plugin", path: URL(string: "plugin://sample@test")!),
        ])

        #expect(
            prompt.appServerInput == [
                .text("Describe these files."),
                .image(url: "https://example.test/diagram.png"),
                .localImage(path: "/tmp/screenshot.png"),
                .skill(name: "checks", path: "/tmp/skills/checks"),
                .mention(name: "repo", path: "/tmp/repo"),
                .mention(name: "app", path: "app://demo-app"),
                .mention(name: "plugin", path: "plugin://sample@test"),
            ])
    }

    @Test func threadStatusNormalizesAppServerLiveStates() {
        #expect(CodexThreadStatus(rawValue: "active") == .active(activeFlags: []))
        #expect(CodexThreadStatus(rawValue: "idle") == .idle)
        #expect(CodexThreadStatus(rawValue: "notLoaded") == .notLoaded)
        #expect(CodexThreadStatus(rawValue: "systemError") == .systemError)
    }

    @Test func clientRetriesOverloadedRequestsThenSucceeds() async throws {
        let transport = CodexAppServerTestTransport()
        await transport.enqueueFailure(code: -32001, message: "server busy", for: "ping")
        try await transport.enqueue(EmptyResponse(), for: "ping")
        let harness = await CodexAppServerTestConnectionHarness.start(
            transport: transport,
            overloadRetryDelay: { $0 == 0 ? .zero : nil },
            retrySleep: { _ in }
        )
        let client = harness.client

        let _: EmptyResponse = try await client.send(
            method: "ping",
            params: EmptyResponse(),
            responseType: EmptyResponse.self
        )

        #expect(await transport.recordedRequests(method: "ping").count == 2)
        await harness.close()
    }

    @Test func requestFailurePreservesCorrelationAndRawServerData() async throws {
        let transport = CodexAppServerTestTransport()
        let rawData = Data(
            #"{"reason":"busy","message":"turn rejected","codexErrorInfo":"serverOverloaded"}"#.utf8
        )
        await transport.enqueueFailure(
            .responseError(.init(
                code: -32_000,
                message: "rejected",
                data: rawData
            )),
            for: "ping"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client

        do {
            let _: EmptyResponse = try await client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: EmptyResponse.self
            )
            Issue.record("Expected request failure.")
        } catch let error as CodexAppServerError {
            guard case .request(let failure) = error,
                  case .server(let serverError) = failure.kind
            else {
                Issue.record("Expected typed server request failure, got \(error).")
                return
            }
            #expect(failure.requestID == 1)
            #expect(failure.method == "ping")
            #expect(failure.purpose == .operation("ping"))
            let serverData = try #require(serverError.data)
            let serverDataObject = try #require(
                JSONSerialization.jsonObject(with: serverData) as? [String: String]
            )
            #expect(serverDataObject == [
                "reason": "busy",
                "message": "turn rejected",
                "codexErrorInfo": "serverOverloaded",
            ])
            #expect(serverError.turnError == .init(message: "turn rejected", info: .serverOverloaded))
        }
        await harness.close()
    }

    @Test func outboundWriterFailurePreservesRequestCorrelation() async throws {
        let failure = CodexTransportFailure.io(errno: EPIPE, message: "broken pipe")
        let transport = TestOutboundWriteFailureTransport(failure: failure)
        let client = AppServerClient(
            transport: transport,
            connectionCloseAction: testConnectionCloseAction(for: transport)
        )

        do {
            let _: EmptyResponse = try await client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: EmptyResponse.self
            )
            Issue.record("Expected an outbound write failure.")
        } catch let error as CodexAppServerError {
            #expect(error == .request(.init(
                requestID: 1,
                method: "ping",
                purpose: .operation("ping"),
                kind: .write(failure)
            )))
        }
    }

    @Test func requestInvalidResponsePreservesCorrelationAndRawBytes() async throws {
        struct RequiredResponse: Decodable, Sendable {
            var value: String
        }

        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(#"{"unexpected":true}"#, for: "ping")
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client

        do {
            let _: RequiredResponse = try await client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: RequiredResponse.self
            )
            Issue.record("Expected invalid response failure.")
        } catch let error as CodexAppServerError {
            guard case .request(let failure) = error,
                  case .invalidResponse(_, _, let rawData) = failure.kind
            else {
                Issue.record("Expected typed invalid response, got \(error).")
                return
            }
            #expect(failure.requestID == 1)
            #expect(failure.method == "ping")
            #expect(failure.purpose == .operation("ping"))
            #expect(rawData == Data(#"{"unexpected":true}"#.utf8))
        }
        await harness.close()
    }

    @Test func responseReconciliationFailureTerminatesWithoutRejectingTheAcceptedWrite() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueEmpty(for: "ping")
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let failure = CodexTransportFailure.contractViolation(
            message: "Response turn does not match the live generation."
        )
        let writeAcceptedCount = Mutex(0)
        let responseRejectedCount = Mutex(0)
        let responseAcceptedCount = Mutex(0)

        do {
            let _: EmptyResponse = try await harness.client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: EmptyResponse.self,
                reconcileResponse: { _ in throw failure },
                onWriteAccepted: { writeAcceptedCount.withLock { $0 += 1 } },
                onResponseRejected: { responseRejectedCount.withLock { $0 += 1 } },
                onResponseAccepted: { responseAcceptedCount.withLock { $0 += 1 } }
            )
            Issue.record("Expected response reconciliation to terminate the connection.")
        } catch let error as CodexAppServerError {
            #expect(error == .connectionTerminated(.transportFailure(failure)))
        }

        #expect(writeAcceptedCount.withLock { $0 } == 1)
        #expect(responseRejectedCount.withLock { $0 } == 0)
        #expect(responseAcceptedCount.withLock { $0 } == 0)
        #expect(
            await harness.supervisor.terminationForTesting()
                == .transportFailure(failure)
        )
    }

    @Test func requestCancellationIsNeverWrapped() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.handle(method: "ping") { _ in
            throw CancellationError()
        }
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client

        do {
            let _: EmptyResponse = try await client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: EmptyResponse.self
            )
            Issue.record("Expected CancellationError.")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
        await harness.close()
    }

    @Test func cancellationBeforeTransportAcceptsWriteHasNoWireEffect() async throws {
        let transport = TestPreWriteSuspendingTransport(
            response: try JSONEncoder().encode(EmptyResponse())
        )
        let client = AppServerClient(
            transport: transport,
            connectionCloseAction: testConnectionCloseAction(for: transport)
        )
        let scope = AppServerAPI.RequestScope.thread("thread-1")
        let task = Task {
            let _: EmptyResponse = try await client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: EmptyResponse.self,
                scope: scope
            )
        }
        await transport.waitUntilSendEntered()
        task.cancel()
        await transport.allowWriteAcceptance()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(transport.wireRequestCount() == 0)
        #expect(await client.requestLaneCountForTesting() == 0)
    }

    @Test func transportClosureIsConnectionTerminationNotRequestFailure() async throws {
        let transport = CodexAppServerTestTransport()
        await transport.enqueueFailure(.closed, for: "ping")
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client

        do {
            let _: EmptyResponse = try await client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: EmptyResponse.self
            )
            Issue.record("Expected connection termination.")
        } catch let error as CodexAppServerError {
            #expect(error == .connectionTerminated(.transportFailure(.closed)))
        }
        await harness.close()
    }

    @Test func requestDeadlineUsesInjectedMonotonicClockAndKeepsCorrelation() async throws {
        let transport = TestSuspendingTransport(response: try JSONEncoder().encode(EmptyResponse()))
        let deadlineGate = CodexAppServerTestGate()
        let deadlineReturned = TestSignal()
        let client = AppServerClient(
            transport: transport,
            deadlines: .init(request: .seconds(5)),
            deadlineClock: .init { duration in
                #expect(duration == .seconds(5))
                await deadlineGate.waitIgnoringCancellation()
                deadlineReturned.signal()
            },
            connectionCloseAction: testConnectionCloseAction(for: transport)
        )

        let task = Task {
            let _: EmptyResponse = try await client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: EmptyResponse.self,
                purpose: .operation("ping"),
                deadline: .seconds(5)
            )
        }
        await transport.waitUntilStarted()
        await deadlineGate.open()
        await deadlineReturned.wait()
        await transport.waitUntilCancelled()
        do {
            try await task.value
            Issue.record("Expected request deadline.")
        } catch let error as CodexAppServerError {
            guard case .request(let failure) = error,
                  case .deadlineExceeded(let duration) = failure.kind
            else {
                Issue.record("Expected request deadline, got \(error).")
                return
            }
            #expect(failure.requestID == 1)
            #expect(failure.method == "ping")
            #expect(failure.purpose == .operation("ping"))
            #expect(duration == .seconds(5))
        }
    }

    @Test func requestDeadlineBoundsOverloadBackoffAndEntireRetryLoop() async throws {
        let transport = CodexAppServerTestTransport()
        await transport.enqueueFailure(code: -32_001, message: "busy", for: "ping")
        let backoffStarted = TestSignal()
        let backoffCancelled = TestSignal()
        let backoffWaiter = TestCancellationWaiter {
            backoffCancelled.signal()
        }
        let deadlineGate = CodexAppServerTestGate()
        let deadlineReturned = TestSignal()
        let harness = await CodexAppServerTestConnectionHarness.start(
            transport: transport,
            deadlineClock: .init { duration in
                #expect(duration == .seconds(5))
                await deadlineGate.waitIgnoringCancellation()
                deadlineReturned.signal()
            },
            overloadRetryDelay: { attempt in
                #expect(attempt == 0)
                return .seconds(30)
            },
            retrySleep: { duration in
                #expect(duration == .seconds(30))
                backoffStarted.signal()
                try await backoffWaiter.wait()
            }
        )
        let client = harness.client
        var connectionIterator = await harness.server.connectionEvents().makeAsyncIterator()

        let task = Task {
            let _: EmptyResponse = try await client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: EmptyResponse.self,
                purpose: .operation("ping"),
                deadline: .seconds(5)
            )
        }
        await backoffStarted.wait()
        #expect(await connectionIterator.next() == .retrying(.init(
            requestID: 1,
            method: "ping",
            attempt: 1,
            delay: .seconds(30),
            serverError: .init(code: -32_001, message: "busy")
        )))
        await deadlineGate.open()
        await deadlineReturned.wait()
        await backoffCancelled.wait()

        do {
            try await task.value
            Issue.record("Expected request deadline during overload backoff.")
        } catch let error as CodexAppServerError {
            #expect(error == .request(.init(
                requestID: 1,
                method: "ping",
                purpose: .operation("ping"),
                kind: .deadlineExceeded(.seconds(5))
            )))
        }
        #expect(await transport.recordedRequests(method: "ping").count == 1)
        await harness.close()
    }

    @Test func overloadBackoffCancellationIsNeverWrapped() async throws {
        let transport = CodexAppServerTestTransport()
        await transport.enqueueFailure(code: -32_001, message: "busy", for: "ping")
        let harness = await CodexAppServerTestConnectionHarness.start(
            transport: transport,
            overloadRetryDelay: { _ in .seconds(30) },
            retrySleep: { _ in throw CancellationError() }
        )
        let client = harness.client

        do {
            let _: EmptyResponse = try await client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: EmptyResponse.self
            )
            Issue.record("Expected CancellationError.")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
        await harness.close()
    }

    @Test func callerCancellationStopsShieldedOverloadBackoff() async throws {
        let transport = CodexAppServerTestTransport()
        await transport.enqueueFailure(code: -32_001, message: "busy", for: "ping")
        let backoffStarted = TestSignal()
        let backoffCancelled = TestSignal()
        let backoffWaiter = TestCancellationWaiter {
            backoffCancelled.signal()
        }
        let harness = await CodexAppServerTestConnectionHarness.start(
            transport: transport,
            overloadRetryDelay: { _ in .seconds(30) },
            retrySleep: { _ in
                backoffStarted.signal()
                try await backoffWaiter.wait()
            }
        )
        let client = harness.client
        let task = Task {
            let _: EmptyResponse = try await client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: EmptyResponse.self
            )
        }
        await backoffStarted.wait()
        task.cancel()
        await backoffCancelled.wait()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await transport.recordedRequests(method: "ping").count == 1)
        await harness.close()
    }

    @Test func handshakeDeadlineTakesPrecedenceOverGenericRequestDeadline() async throws {
        let transport = TestSuspendingTransport(response: try JSONEncoder().encode(
            AppServerAPI.Initialize.Response(codexHome: "/tmp/codex")
        ))
        let deadlineGate = CodexAppServerTestGate()
        let deadlineReturned = TestSignal()
        let client = AppServerClient(
            transport: transport,
            deadlines: .init(handshake: .seconds(7), request: .seconds(2)),
            deadlineClock: .init { duration in
                #expect(duration == .seconds(7))
                await deadlineGate.waitIgnoringCancellation()
                deadlineReturned.signal()
            },
            connectionCloseAction: testConnectionCloseAction(for: transport)
        )

        let task = Task { try await client.initialize() }
        await transport.waitUntilStarted()
        await deadlineGate.open()
        await deadlineReturned.wait()
        await transport.waitUntilCancelled()
        do {
            _ = try await task.value
            Issue.record("Expected handshake deadline.")
        } catch let error as CodexAppServerError {
            guard case .request(let failure) = error,
                  case .deadlineExceeded(let duration) = failure.kind
            else {
                Issue.record("Expected handshake deadline, got \(error).")
                return
            }
            #expect(failure.requestID == 1)
            #expect(failure.method == "initialize")
            #expect(failure.purpose == .handshake)
            #expect(duration == .seconds(7))
        }
    }

    @Test func turnDeadlineKeepsHandleAndDoesNotInterruptServerTurn() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueTurnStart(turnID: "turn-deadline", status: "inProgress")
        let deadlineGate = CodexAppServerTestGate()
        let harness = await CodexAppServerTestConnectionHarness.start(
            transport: transport,
            deadlineClock: .init { duration in
                #expect(duration == .seconds(9))
                await deadlineGate.waitIgnoringCancellation()
            }
        )
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router, connectionLease: harness.lease)
        let stream = try await thread.streamResponse(to: "Wait for terminal.")

        let task = Task { try await stream.collect(timeout: .seconds(9)) }
        await deadlineGate.open()
        do {
            _ = try await task.value
            Issue.record("Expected turn deadline.")
        } catch let error as CodexAppServerError {
            #expect(error == .turnDeadlineExceeded(turnID: "turn-deadline", duration: .seconds(9)))
        }
        #expect(await transport.recordedRequests(method: "turn/interrupt").isEmpty)

        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-deadline", status: "completed"))
        )
        guard case .completed(let response) = try await stream.collect() else {
            Issue.record("Expected terminal replay after deadline.")
            return
        }
        #expect(response.turnID == "turn-deadline")
    }

    @Test func responseCollectionCancellationIsLocalAndTerminalRemainsReplayable() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueTurnStart(turnID: "turn-local-cancel", status: "inProgress")
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router, connectionLease: harness.lease)
        let stream = try await thread.streamResponse(to: "Keep running.")

        let task = Task { try await stream.collect() }
        #expect(await eventually {
            await harness.turnReplayStore.subscriberCountForTesting(
                turnID: "turn-local-cancel"
            ) == 1
        })
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected local collection cancellation.")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
        #expect(await transport.recordedRequests(method: "turn/interrupt").isEmpty)

        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-local-cancel", status: "completed"))
        )
        guard case .completed(let response) = try await stream.collect() else {
            Issue.record("Expected replayed terminal outcome.")
            return
        }
        #expect(response.turnID == "turn-local-cancel")
    }

    @Test func scopedRequestCancelledWhileQueuedDoesNotSend() async throws {
        let transport = CodexAppServerTestTransport()
        let gate = CodexAppServerTestGate()
        await transport.holdNextIgnoringCancellation(method: "turn/start", gate: gate)
        try await transport.enqueueTurnStart(turnID: "turn-1", status: "running")
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client

        let first = Task {
            try await client.send(AppServerAPI.Turn.Start.Request(
                params: .init(threadID: "thread-1", input: [.text("first")])
            ))
        }
        await transport.waitForRequest(method: "turn/start")

        let second = Task {
            try await client.send(AppServerAPI.Turn.Start.Request(
                params: .init(threadID: "thread-1", input: [.text("second")])
            ))
        }
        try await client.waitForQueuedRequestCountForTesting(
            scope: .thread("thread-1"),
            atLeast: 1
        )
        second.cancel()

        do {
            _ = try await second.value
            Issue.record("Expected the queued scoped request to throw CancellationError.")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
        #expect(await client.queuedRequestCountForTesting(scope: .thread("thread-1")) == 0)
        #expect(await client.requestLaneCountForTesting() == 1)

        await gate.open()
        _ = try await first.value
        #expect(await transport.recordedRequests(method: "turn/start").count == 1)
        #expect(await client.requestLaneCountForTesting() == 0)
        await harness.close()
    }

    @Test func postWriteCancellationKeepsLaneUntilCorrelatedResponse() async throws {
        let transport = CodexAppServerTestTransport()
        let responseGate = CodexAppServerTestGate()
        await transport.holdNextIgnoringCancellation(method: "ping", gate: responseGate)
        try await transport.enqueueEmpty(for: "ping")
        try await transport.enqueueEmpty(for: "ping")
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let scope = AppServerAPI.RequestScope.thread("thread-1")

        let first = Task {
            let _: EmptyResponse = try await client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: EmptyResponse.self,
                scope: scope
            )
        }
        await transport.waitForRequest(method: "ping")
        first.cancel()

        let second = Task {
            let _: EmptyResponse = try await client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: EmptyResponse.self,
                scope: scope
            )
        }
        try await client.waitForQueuedRequestCountForTesting(scope: scope, atLeast: 1)

        #expect(await transport.recordedRequests(method: "ping").count == 1)
        await responseGate.open()

        await #expect(throws: CancellationError.self) {
            try await first.value
        }
        try await second.value
        #expect(await transport.recordedRequests(method: "ping").count == 2)
        #expect(await client.requestLaneCountForTesting() == 0)
        await harness.close()
    }

    @Test func postWriteCancellationKeepsLaneThroughRequiredCleanup() async throws {
        let transport = CodexAppServerTestTransport()
        let responseGate = CodexAppServerTestGate()
        let cleanupStarted = TestSignal()
        let cleanupGate = CodexAppServerTestGate()
        await transport.holdNextIgnoringCancellation(method: "ping", gate: responseGate)
        try await transport.enqueueEmpty(for: "ping")
        try await transport.enqueueEmpty(for: "ping")
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let scope = AppServerAPI.RequestScope.thread("thread-1")

        let first = Task {
            let _: EmptyResponse = try await client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: EmptyResponse.self,
                scope: scope,
                onPostWriteCancellation: { _ in
                    cleanupStarted.signal()
                    await cleanupGate.waitIgnoringCancellation()
                }
            )
        }
        await transport.waitForRequest(method: "ping")
        first.cancel()
        await responseGate.open()
        await cleanupStarted.wait()

        let second = Task {
            let _: EmptyResponse = try await client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: EmptyResponse.self,
                scope: scope
            )
        }
        try await client.waitForQueuedRequestCountForTesting(scope: scope, atLeast: 1)

        #expect(await transport.recordedRequests(method: "ping").count == 1)
        await cleanupGate.open()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }
        try await second.value
        #expect(await transport.recordedRequests(method: "ping").count == 2)
        #expect(await client.requestLaneCountForTesting() == 0)
        await harness.close()
    }

    @Test func cleanupChildWithStaleLaneTokenQueuesBehindCurrentOwner() async throws {
        let transport = CodexAppServerTestTransport()
        let firstResponseGate = CodexAppServerTestGate()
        let blockerResponseGate = CodexAppServerTestGate()
        let staleChildGate = CodexAppServerTestGate()
        let staleChildTask = Mutex<Task<Void, Error>?>(nil)
        await transport.holdNextIgnoringCancellation(method: "ping", gate: firstResponseGate)
        await transport.holdNextIgnoringCancellation(method: "ping", gate: blockerResponseGate)
        try await transport.enqueueEmpty(for: "ping")
        try await transport.enqueueEmpty(for: "ping")
        try await transport.enqueueEmpty(for: "ping")
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let scope = AppServerAPI.RequestScope.thread("thread-1")

        let first = Task {
            let _: EmptyResponse = try await client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: EmptyResponse.self,
                scope: scope,
                onPostWriteCancellation: { _ in
                    let task = Task {
                        await staleChildGate.waitIgnoringCancellation()
                        let _: EmptyResponse = try await client.send(
                            method: "ping",
                            params: EmptyResponse(),
                            responseType: EmptyResponse.self,
                            scope: scope
                        )
                    }
                    staleChildTask.withLock { $0 = task }
                }
            )
        }
        await transport.waitForRequest(method: "ping")
        first.cancel()
        await firstResponseGate.open()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }

        let blocker = Task {
            let _: EmptyResponse = try await client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: EmptyResponse.self,
                scope: scope
            )
        }
        await transport.waitForRequest(method: "ping", count: 2)
        let child = try #require(staleChildTask.withLock { $0 })
        await staleChildGate.open()
        try await withTimeout {
            try await client.waitForQueuedRequestCountForTesting(scope: scope, atLeast: 1)
        }

        #expect(await transport.recordedRequests(method: "ping").count == 2)
        await blockerResponseGate.open()
        try await blocker.value
        try await child.value
        #expect(await transport.recordedRequests(method: "ping").count == 3)
        #expect(await client.requestLaneCountForTesting() == 0)
        await harness.close()
    }

    @Test func postWriteDeadlineClosesConnectionBeforeReleasingLane() async throws {
        let transport = CodexAppServerTestTransport()
        let responseGate = CodexAppServerTestGate()
        let deadlineGate = CodexAppServerTestGate()
        await transport.holdNextIgnoringCancellation(method: "ping", gate: responseGate)
        try await transport.enqueueEmpty(for: "ping")
        let harness = await CodexAppServerTestConnectionHarness.start(
            transport: transport,
            deadlineClock: .init { duration in
                #expect(duration == .seconds(5))
                await deadlineGate.waitIgnoringCancellation()
            }
        )
        let client = harness.client
        let scope = AppServerAPI.RequestScope.thread("thread-1")

        let first = Task {
            let _: EmptyResponse = try await client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: EmptyResponse.self,
                scope: scope,
                deadline: .seconds(5)
            )
        }
        await transport.waitForRequest(method: "ping")

        let second = Task {
            let _: EmptyResponse = try await client.send(
                method: "ping",
                params: EmptyResponse(),
                responseType: EmptyResponse.self,
                scope: scope
            )
        }
        try await client.waitForQueuedRequestCountForTesting(scope: scope, atLeast: 1)

        await deadlineGate.open()
        do {
            try await first.value
            Issue.record("Expected request deadline.")
        } catch let error as CodexAppServerError {
            #expect(error == .request(.init(
                requestID: 1,
                method: "ping",
                purpose: .operation("ping"),
                kind: .deadlineExceeded(.seconds(5))
            )))
        }
        await #expect(throws: CodexAppServerError.self) {
            try await second.value
        }

        #expect(await transport.recordedRequests(method: "ping").count == 1)
        #expect(await transport.isClosedForTesting())
        #expect(await client.requestLaneCountForTesting() == 0)
    }

    @Test func turnResultReplaysEarlyDomainEventsAndRoutesUnknownToConnection() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        let connectionEvents = await harness.server.connectionEvents()
        let connectionEventTask = Task {
            var iterator = connectionEvents.makeAsyncIterator()
            return await iterator.next()
        }
        await connectionEvents.waitUntilNextSuspendsForTesting()
        await transport.waitForNotificationStreamCount(1)
        let state = TurnGenerationHandleState(connectionLease: harness.lease)
        let pending = await harness.turnReplayStore.registerPendingOperation(
            kind: .turn(threadID: "thread-1"),
            state: state
        )
        pending.acceptWrite()
        let futureParams = TurnIDParams(turnID: "turn-1")
        try await transport.emitServerNotification(
            method: "future/notification",
            params: futureParams
        )
        try await emitItemStarted(
            on: transport,
            threadID: "thread-1",
            turnID: "turn-1",
            item: .init(id: "message-1", type: "agentMessage", text: "")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(turnID: "turn-1", itemID: "message-1", delta: "Done")
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "completed"))
        )
        await harness.turnReplayStore.bind(
            pending,
            to: "turn-1",
            initialSnapshot: .init(id: "turn-1", state: .inProgress)
        )
        let turn = CodexTurn(
            id: "turn-1",
            threadID: "thread-1",
            client: client,
            router: router,
            turnReplayStore: harness.turnReplayStore,
            state: state
        )

        let events = try await collect(turn.events)
        #expect(events.contains {
            if case .unknown = $0 { true } else { false }
        } == false)
        guard case .unknown(let raw) = await connectionEventTask.value else {
            Issue.record("Expected the future notification on the connection stream.")
            return
        }
        #expect(raw.method == "future/notification")
        #expect(raw.params == (try JSONEncoder().encode(futureParams)))
        #expect(raw.threadID == nil)
        #expect(raw.turnID == "turn-1")
        let result = try await turn.result()
        #expect(result.response.turnID == "turn-1")
        #expect(result == .completed(result.response))
        #expect(result.response.transcript.finalAnswer == "Done")
    }

    @Test func threadEventStreamCancellationRemovesRouterSubscriber() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        let thread = CodexThread(id: "thread-1", client: client, router: router, connectionLease: harness.lease)

        let consumer = Task {
            var iterator = thread.events.makeAsyncIterator()
            _ = try await iterator.next()
        }

        #expect(await eventually {
            router.threadSubscriberCountForTesting(for: "thread-1") == 1
        })
        consumer.cancel()
        try await consumer.value
        #expect(router.threadSubscriberCountForTesting(for: "thread-1") == 0)
    }

    @Test func directThreadEventStreamCancellationRemovesRouterSubscriber() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let router = harness.router
        let stream = router.events(for: CodexThreadID(rawValue: "thread-1"))
        #expect(router.threadSubscriberCountForTesting(for: "thread-1") == 1)
        stream.cancel()
        #expect(router.threadSubscriberCountForTesting(for: "thread-1") == 0)
    }

    @Test func liveThreadEventStreamFinishesWhenHistoryIsAlreadyTerminal() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )
        let replayStream = router.events(for: CodexThreadID(rawValue: "thread-1"))
        let replayEvents = try await withTimeout {
            try await collect(replayStream)
        }
        #expect(replayEvents.contains { event in
            if case .closed = event {
                return true
            }
            return false
        })

        #expect(router.threadSubscriberCountForTesting(for: "thread-1") == 0)
    }

    @Test func threadEventStreamsReplayOnlyCurrentGenerationAfterNewGenerationStarts() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )
        let firstGeneration = try await withTimeout {
            try await collect(router.events(for: CodexThreadID(rawValue: "thread-1")))
        }
        #expect(firstGeneration.contains { event in
            if case .closed = event {
                return true
            }
            return false
        })

        router.resetThreadEventGeneration("thread-1")
        try await emitItemStarted(
            on: transport,
            threadID: "thread-1",
            turnID: "turn-2",
            item: .init(id: "message-1", type: "agentMessage", text: "")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-1",
                turnID: "turn-2",
                itemID: "message-1",
                delta: "Current"
            )
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )

        let currentGeneration = try await withTimeout {
            try await collect(router.events(for: "thread-1"))
        }
        #expect(currentGeneration.containsThreadText("Current", turnID: "turn-2"))
        #expect(currentGeneration.last == .closed)
    }

    @Test func threadGenerationIncludingTurnStartsAfterPriorTerminalTurn() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(threadID: "thread-review", turnID: "turn-old")
        )
        try await emitItemStarted(
            on: transport,
            threadID: "thread-review",
            turnID: "turn-old",
            item: .init(id: "message-1", type: "agentMessage", text: "")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-review",
                turnID: "turn-old",
                itemID: "message-1",
                delta: "Old"
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(threadID: "thread-review", turn: .init(id: "turn-old", status: "completed"))
        )
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(threadID: "thread-review", turnID: "turn-current")
        )
        try await emitItemStarted(
            on: transport,
            threadID: "thread-review",
            turnID: "turn-current",
            item: .init(id: "message-1", type: "agentMessage", text: "")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-review",
                turnID: "turn-current",
                itemID: "message-1",
                delta: "Current"
            )
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-review")
        )

        let provisionalGeneration = try await withTimeout {
            try await collect(router.events(for: "thread-review"))
        }
        #expect(provisionalGeneration.last == .closed)
        await router.adoptThreadEventGeneration(
            "thread-review",
            including: "turn-current"
        )
        let currentGeneration = try await withTimeout {
            try await collect(router.events(for: "thread-review"))
        }

        #expect(currentGeneration.contains { event in
            if case .messageDelta(let delta, let turnID) = event {
                return delta.text == "Old" || turnID == "turn-old"
            }
            return false
        } == false)
        #expect(currentGeneration.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.id == "turn-current"
            }
            return false
        })
        #expect(currentGeneration.containsThreadText("Current", turnID: "turn-current"))
        #expect(currentGeneration.last == .closed)
    }

    @Test func resumeThreadReidentifiesResponseSnapshotFromCanonicalEventsDuringResume() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let gate = CodexAppServerTestGate()
        await runtime.transport.holdNext(method: "thread/resume", gate: gate)
        try await runtime.transport.enqueueThreadResume(.init(
            id: "thread-resume-events",
            turns: [
                .init(
                    id: "rollout-synthesized-turn",
                    state: .inProgress,
                    items: [
                        .init(
                            id: "response-message",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "response-message",
                                role: .assistant,
                                text: "From resume response"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let resumeTask = Task {
            try await runtime.server.resumeThread("thread-resume-events")
        }
        await runtime.transport.waitForRequest(method: "thread/resume")
        try await emitItemStarted(
            on: runtime.transport,
            threadID: "thread-resume-events",
            turnID: "turn-resume-events",
            item: .init(id: "message-1", type: "agentMessage", text: "")
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-resume-events",
                turnID: "turn-resume-events",
                itemID: "message-1",
                delta: "During resume"
            )
        )
        await gate.open()

        let thread = try await resumeTask.value
        try await runtime.transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-resume-events")
        )

        let events = try await collect(thread.events)
        #expect(events.containsThreadText("From resume response", turnID: "turn-resume-events"))
        #expect(events.containsThreadText("During resume", turnID: "turn-resume-events"))
        #expect(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.id == "rollout-synthesized-turn"
            }
            return false
        } == false)
    }

    @Test func resumeThreadReidentifiesProvisionalResponseWhenCanonicalEventsArriveLater() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(
            id: "thread-resume-events",
            turns: [
                .init(
                    id: "rollout-synthesized-turn",
                    state: .inProgress,
                    items: [
                        .init(
                            id: "response-message",
                            kind: .agentMessage,
                            content: .message(.init(
                                id: "response-message",
                                role: .assistant,
                                text: "From resume response"
                            ))
                        ),
                    ]
                ),
            ]
        ))

        let thread = try await runtime.server.resumeThread("thread-resume-events")
        try await emitItemStarted(
            on: runtime.transport,
            threadID: "thread-resume-events",
            turnID: "turn-resume-events",
            item: .init(id: "message-1", type: "agentMessage", text: "")
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-resume-events",
                turnID: "turn-resume-events",
                itemID: "message-1",
                delta: "After resume"
            )
        )
        try await runtime.transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-resume-events")
        )

        let events = try await collect(thread.events)
        #expect(events.containsThreadText("From resume response", turnID: "turn-resume-events"))
        #expect(events.containsThreadText("After resume", turnID: "turn-resume-events"))
        #expect(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.id == "rollout-synthesized-turn"
            }
            return false
        } == false)
    }

    @Test func streamResponseBeginsNewThreadEventGeneration() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueTurnStart(turnID: "turn-2", status: "running")
        let gate = CodexAppServerTestGate()
        await transport.holdNext(method: "turn/start", gate: gate)
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router, connectionLease: harness.lease)

        try await emitItemStarted(
            on: transport,
            threadID: "thread-1",
            turnID: "turn-1",
            item: .init(id: "message-1", type: "agentMessage", text: "")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "message-1",
                delta: "Previous generation"
            )
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )
        let previousEvents = try await withTimeout {
            try await collect(thread.events)
        }
        #expect(previousEvents.last == .closed)

        let streamTask = Task {
            try await thread.streamResponse(to: "Next turn.")
        }
        await transport.waitForRequest(method: "turn/start")
        try await emitItemStarted(
            on: transport,
            threadID: "thread-1",
            turnID: "turn-2",
            item: .init(id: "message-1", type: "agentMessage", text: "")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                turnID: "turn-2",
                itemID: "message-1",
                delta: "During start"
            )
        )
        await gate.open()
        let responseStream = try await streamTask.value
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )

        let events = try await withTimeout {
            try await collect(thread.events)
        }
        #expect(events.count == 3)
        #expect(events.containsThreadText("During start", turnID: "turn-2"))
        #expect(events.containsThreadText("Previous generation", turnID: "turn-1") == false)
        #expect(events.last == .closed)
        withExtendedLifetime(responseStream) {}
    }

    @Test func startReviewBeginsNewThreadEventGeneration() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-1",
            status: .inProgress
        )
        let gate = CodexAppServerTestGate()
        await transport.holdNext(method: "review/start", gate: gate)
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router, connectionLease: harness.lease)

        try await emitItemStarted(
            on: transport,
            threadID: "thread-1",
            turnID: "turn-previous",
            item: .init(id: "message-1", type: "agentMessage", text: "")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-1",
                turnID: "turn-previous",
                itemID: "message-1",
                delta: "Previous generation"
            )
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )
        let previousEvents = try await withTimeout {
            try await collect(thread.events)
        }
        #expect(previousEvents.last == .closed)

        let reviewTask = Task {
            try await thread.startReview(target: .baseBranch("main"))
        }
        await transport.waitForRequest(method: "review/start")
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(threadID: "thread-1", turnID: "turn-review-child")
        )
        try await emitItemStarted(
            on: transport,
            threadID: "thread-1",
            turnID: "turn-review",
            item: .init(id: "message-1", type: "agentMessage", text: "")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                turnID: "turn-review",
                itemID: "message-1",
                delta: "During review start"
            )
        )
        await gate.open()
        let review = try await reviewTask.value
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(threadID: "thread-1", turnID: "turn-review-child-late")
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-1",
                turnID: "turn-review",
                item: .init(id: "review-output", type: "agentMessage", text: "No issues.")
            )
        )
        let eventsTask = Task {
            try await collect(thread.events)
        }
        #expect(await eventually {
            router.threadSubscriberCountForTesting(for: "thread-1") == 1
        })

        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )

        let events = try await withTimeout {
            try await eventsTask.value
        }
        #expect(events.containsThreadText("During review start", turnID: "turn-review"))
        #expect(events.containsThreadText("Previous generation", turnID: "turn-previous") == false)
        #expect(events.last == .closed)
        withExtendedLifetime(review) {}
    }

    @Test func detachedStartReviewBeginsReviewThreadEventGeneration() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            status: .inProgress
        )
        let gate = CodexAppServerTestGate()
        await transport.holdNext(method: "review/start", gate: gate)
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-source", client: client, router: router, connectionLease: harness.lease)
        let reviewThread = CodexThread(id: "thread-review", client: client, router: router, connectionLease: harness.lease)

        let oldSourceEventsTask = Task {
            try await collect(thread.events)
        }
        #expect(await eventually {
            router.threadSubscriberCountForTesting(for: "thread-source") == 1
        })
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-source")
        )
        let oldSourceEvents = try await withTimeout {
            try await oldSourceEventsTask.value
        }
        #expect(oldSourceEvents.last == .closed)

        try await emitItemStarted(
            on: transport,
            threadID: "thread-review-previous",
            turnID: "turn-previous",
            item: .init(id: "message-1", type: "agentMessage", text: "")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-review-previous",
                turnID: "turn-previous",
                itemID: "message-1",
                delta: "Previous detached generation"
            )
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-review-previous")
        )
        let previousEvents = try await withTimeout {
            try await collect(router.events(for: "thread-review-previous"))
        }
        #expect(previousEvents.last == .closed)

        let reviewTask = Task {
            try await thread.startReview(target: .baseBranch("main"), delivery: .detached)
        }
        await transport.waitForRequest(method: "review/start")
        try await transport.emitServerNotificationJSON(
            method: "thread/status/changed",
            json: #"{"threadId":"thread-source","status":{"type":"active","activeFlags":["waitingOnApproval"]}}"#
        )
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(threadID: "thread-review", turnID: "turn-review-child")
        )
        try await transport.emitServerNotificationJSON(
            method: "thread/status/changed",
            json: #"{"threadId":"thread-review","status":{"type":"active","activeFlags":[]}}"#
        )
        try await emitItemStarted(
            on: transport,
            threadID: "thread-review",
            turnID: "turn-review",
            item: .init(id: "message-1", type: "agentMessage", text: "")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-review",
                turnID: "turn-review",
                itemID: "message-1",
                delta: "During detached review start"
            )
        )
        await gate.open()
        let review = try await reviewTask.value
        withExtendedLifetime(review) {}
        let sourceEventsTask = Task {
            try await collect(thread.events)
        }
        #expect(await eventually {
            router.threadSubscriberCountForTesting(for: "thread-source") == 1
        })
        let eventsTask = Task {
            try await collect(reviewThread.events)
        }
        #expect(await eventually {
            router.threadSubscriberCountForTesting(for: "thread-review") == 1
        })

        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-review")
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-source")
        )

        let events = try await withTimeout {
            try await eventsTask.value
        }
        #expect(events.contains(.statusChanged(.active(activeFlags: []))))
        #expect(events.containsThreadText("During detached review start", turnID: "turn-review"))
        #expect(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.id == "turn-review-child"
            }
            return false
        } == false)
        #expect(
            events.containsThreadText("Previous detached generation", turnID: "turn-previous")
                == false
        )
        #expect(events.last == .closed)
        let sourceEvents = try await withTimeout {
            try await sourceEventsTask.value
        }
        #expect(sourceEvents.contains(.statusChanged(.active(activeFlags: [.waitingOnApproval]))))
        #expect(sourceEvents.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.id == "turn-review"
            }
            return false
        } == false)
        #expect(sourceEvents.last == .closed)
    }

    @Test func detachedReviewAmbiguityPreservesAnUnrelatedTurnStart() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            status: .inProgress
        )
        let gate = CodexAppServerTestGate()
        await transport.holdNext(method: "review/start", gate: gate)
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let sourceThread = CodexThread(
            id: "thread-source",
            client: harness.client,
            router: harness.router,
            connectionLease: harness.lease
        )
        let unrelatedThread = CodexThread(
            id: "thread-unrelated",
            client: harness.client,
            router: harness.router,
            connectionLease: harness.lease
        )
        let unrelatedEvents = Task {
            try await collect(unrelatedThread.events)
        }
        #expect(await eventually {
            harness.router.threadSubscriberCountForTesting(for: "thread-unrelated") == 1
        })

        let reviewTask = Task {
            try await sourceThread.startReview(
                target: .baseBranch("main"),
                delivery: .detached
            )
        }
        await transport.waitForRequest(method: "review/start")
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-unrelated",
                turnID: "turn-unrelated"
            )
        )
        #expect(await eventually {
            await harness.router.detachedReviewRoutingSnapshotForTesting() == .init(
                attemptCount: 1,
                candidateCount: 1,
                drainCount: 0
            )
        })
        try await emitItemStarted(
            on: transport,
            threadID: "thread-unrelated",
            turnID: "turn-unrelated",
            item: .init(id: "message-unrelated", type: "agentMessage", text: "")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-unrelated",
                turnID: "turn-unrelated",
                itemID: "message-unrelated",
                delta: "Unrelated work"
            )
        )
        await harness.router.seedTurn(
            "turn-unrelated",
            threadID: "thread-unrelated"
        )
        #expect(await harness.router.detachedReviewRoutingSnapshotForTesting() == .init(
            attemptCount: 1,
            candidateCount: 1,
            drainCount: 0
        ))
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-unrelated")
        )
        await gate.open()
        let review = try await reviewTask.value
        withExtendedLifetime(review) {}
        #expect(await harness.router.detachedReviewRoutingSnapshotForTesting() == .init(
            attemptCount: 0,
            candidateCount: 0,
            drainCount: 0
        ))

        let events = try await withTimeout {
            try await unrelatedEvents.value
        }
        #expect(events.contains { event in
            switch event {
            case .turnStarted("turn-unrelated"):
                true
            case .snapshot(let snapshot):
                snapshot.id == "turn-unrelated"
            default:
                false
            }
        })
        #expect(events.contains { event in
            if case .itemStarted(_, let turnID) = event {
                return turnID == "turn-unrelated"
            }
            return false
        })
        #expect(events.containsThreadText("Unrelated work", turnID: "turn-unrelated"))
        await harness.close()
    }

    @Test func failedDetachedReviewReleasesRoutingCandidates() async throws {
        let transport = CodexAppServerTestTransport()
        await transport.enqueueFailure(
            code: -32_000,
            message: "review start failed",
            for: "review/start"
        )
        let gate = CodexAppServerTestGate()
        await transport.holdNext(method: "review/start", gate: gate)
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let sourceThread = CodexThread(
            id: "thread-source",
            client: harness.client,
            router: harness.router,
            connectionLease: harness.lease
        )

        let reviewTask = Task {
            try await sourceThread.startReview(
                target: .baseBranch("main"),
                delivery: .detached
            )
        }
        await transport.waitForRequest(method: "review/start")
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-unrelated",
                turnID: "turn-unrelated"
            )
        )
        #expect(await eventually {
            await harness.router.detachedReviewRoutingSnapshotForTesting() == .init(
                attemptCount: 1,
                candidateCount: 1,
                drainCount: 0
            )
        })

        await gate.open()
        do {
            _ = try await reviewTask.value
            Issue.record("Expected detached review start failure.")
        } catch {
            // Expected.
        }

        #expect(await harness.router.detachedReviewRoutingSnapshotForTesting() == .init(
            attemptCount: 0,
            candidateCount: 0,
            drainCount: 0
        ))
        await harness.close()
    }

    @Test func detachedReviewRetryReleasesFirstAttemptCandidates() async throws {
        let transport = CodexAppServerTestTransport()
        await transport.enqueueFailure(
            code: -32_001,
            message: "overloaded",
            for: "review/start"
        )
        try await transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            status: .inProgress
        )
        let firstResponseGate = CodexAppServerTestGate()
        await transport.holdNext(method: "review/start", gate: firstResponseGate)
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let sourceThread = CodexThread(
            id: "thread-source",
            client: harness.client,
            router: harness.router,
            connectionLease: harness.lease
        )
        let unrelatedThread = CodexThread(
            id: "thread-unrelated",
            client: harness.client,
            router: harness.router,
            connectionLease: harness.lease
        )
        let unrelatedEvents = Task {
            try await collect(unrelatedThread.events)
        }
        #expect(await eventually {
            harness.router.threadSubscriberCountForTesting(for: "thread-unrelated") == 1
        })

        let reviewTask = Task {
            try await sourceThread.startReview(
                target: .baseBranch("main"),
                delivery: .detached
            )
        }
        await transport.waitForRequest(method: "review/start")
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(
                threadID: "thread-unrelated",
                turnID: "turn-unrelated"
            )
        )
        try await emitItemStarted(
            on: transport,
            threadID: "thread-unrelated",
            turnID: "turn-unrelated",
            item: .init(id: "message-unrelated", type: "agentMessage", text: "")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-unrelated",
                turnID: "turn-unrelated",
                itemID: "message-unrelated",
                delta: "First attempt unrelated work"
            )
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-unrelated")
        )
        #expect(await eventually {
            (await harness.router.detachedReviewRoutingSnapshotForTesting()).candidateCount == 1
        })

        await firstResponseGate.open()
        #expect(await eventually {
            (await harness.router.detachedReviewRoutingSnapshotForTesting()).candidateCount == 0
        })
        await transport.waitForRequest(method: "review/start", count: 2)
        let review = try await reviewTask.value
        withExtendedLifetime(review) {}

        #expect(await harness.router.detachedReviewRoutingSnapshotForTesting() == .init(
            attemptCount: 0,
            candidateCount: 0,
            drainCount: 0
        ))
        let events = try await withTimeout {
            try await unrelatedEvents.value
        }
        #expect(events.contains { event in
            switch event {
            case .turnStarted("turn-unrelated"):
                true
            case .snapshot(let snapshot):
                snapshot.id == "turn-unrelated"
            default:
                false
            }
        })
        #expect(events.containsThreadText(
            "First attempt unrelated work",
            turnID: "turn-unrelated"
        ))
        #expect(events.last == .closed)
        await harness.close()
    }

    @Test func connectionTerminationCanInterleaveWithDetachedReviewDrain() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueReviewStart(
            turnID: "turn-review",
            reviewThreadID: "thread-review",
            status: .inProgress
        )
        let responseGate = CodexAppServerTestGate()
        let drainGate = CodexAppServerTestGate()
        await transport.holdNext(method: "review/start", gate: responseGate)
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        await harness.router.setNotificationDrainPauseForTesting {
            await drainGate.waitIgnoringCancellation()
        }
        let sourceThread = CodexThread(
            id: "thread-source",
            client: harness.client,
            router: harness.router,
            connectionLease: harness.lease
        )
        let reviewTask = Task {
            try await sourceThread.startReview(
                target: .baseBranch("main"),
                delivery: .detached
            )
        }
        await transport.waitForRequest(method: "review/start")
        try await emitItemStarted(
            on: transport,
            threadID: "thread-review",
            turnID: "turn-review",
            item: .init(id: "message-review", type: "agentMessage", text: "")
        )
        for index in 0..<256 {
            try await transport.emitServerNotification(
                method: "item/agentMessage/delta",
                params: TurnDeltaParams(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    itemID: "message-review",
                    delta: "\(index)"
                )
            )
        }

        await responseGate.open()
        await drainGate.waitUntilBlocked()
        let closeTask = Task {
            await harness.close()
        }
        await closeTask.value
        await drainGate.open()
        do {
            let review = try await reviewTask.value
            withExtendedLifetime(review) {}
            Issue.record("Expected connection termination, got a review session.")
        } catch let error as CodexAppServerError {
            #expect(error == .connectionTerminated(.closedByCaller))
        } catch {
            Issue.record("Expected connection termination, got \(error).")
        }
        #expect(await eventually {
            await harness.router.detachedReviewRoutingSnapshotForTesting() == .init(
                attemptCount: 0,
                candidateCount: 0,
                drainCount: 0
            )
        })
    }

    @Test func compactBeginsNewThreadEventGeneration() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueEmpty(for: "thread/compact/start")
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router, connectionLease: harness.lease)

        try await emitItemStarted(
            on: transport,
            threadID: "thread-1",
            turnID: "turn-previous",
            item: .init(id: "message-1", type: "agentMessage", text: "")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-1",
                turnID: "turn-previous",
                itemID: "message-1",
                delta: "Previous generation"
            )
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )
        let previousEvents = try await withTimeout {
            try await collect(thread.events)
        }
        #expect(previousEvents.last == .closed)

        try await thread.compact()
        let eventsTask = Task {
            try await collect(thread.events)
        }
        #expect(await eventually {
            router.threadSubscriberCountForTesting(for: "thread-1") == 1
        })

        try await emitItemStarted(
            on: transport,
            threadID: "thread-1",
            turnID: "turn-compact",
            item: .init(id: "message-1", type: "agentMessage", text: "")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-1",
                turnID: "turn-compact",
                itemID: "message-1",
                delta: "Current compact generation"
            )
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )

        let events = try await withTimeout {
            try await eventsTask.value
        }
        #expect(events.containsThreadText("Current compact generation", turnID: "turn-compact"))
        #expect(events.containsThreadText("Previous generation", turnID: "turn-previous") == false)
        #expect(events.last == .closed)
    }

    @Test func failedReviewStartDoesNotAdvanceThreadEventGeneration() async throws {
        let transport = CodexAppServerTestTransport()
        await transport.enqueueFailure(
            code: -32_000,
            message: "review start failed",
            for: "review/start"
        )
        let gate = CodexAppServerTestGate()
        await transport.holdNext(method: "review/start", gate: gate)
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router, connectionLease: harness.lease)

        try await emitItemStarted(
            on: transport,
            threadID: "thread-1",
            turnID: "turn-previous",
            item: .init(id: "message-1", type: "agentMessage", text: "")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-1",
                turnID: "turn-previous",
                itemID: "message-1",
                delta: "Previous generation"
            )
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )
        let previousEvents = try await withTimeout {
            try await collect(thread.events)
        }
        #expect(previousEvents.last == .closed)

        let reviewTask = Task {
            try await thread.startReview(target: .baseBranch("main"))
        }
        await transport.waitForRequest(method: "review/start")
        await gate.open()
        do {
            _ = try await reviewTask.value
            Issue.record("Expected review start failure.")
        } catch {
            // Expected failure; the existing generation must remain replayable.
        }

        let events = try await withTimeout {
            try await collect(thread.events)
        }
        #expect(events.containsThreadText("Previous generation", turnID: "turn-previous"))
        #expect(events.containsThreadText("Failed review start", turnID: "turn-failed-review") == false)
        #expect(events.last == .closed)
    }

    @Test func failedResumeDoesNotAdvanceThreadEventGeneration() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        try await runtime.transport.enqueueThreadResume(.init(id: "thread-resume-failure"))
        let thread = try await runtime.server.resumeThread("thread-resume-failure")
        let priorEvents = thread.events
        var priorIterator = priorEvents.makeAsyncIterator()
        try await emitItemStarted(
            on: runtime.transport,
            threadID: "thread-resume-failure",
            turnID: "turn-resume-failure",
            item: .init(id: "message-1", type: "agentMessage", text: "")
        )
        try await runtime.transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-resume-failure",
                turnID: "turn-resume-failure",
                itemID: "message-1",
                delta: "Before failed resume"
            )
        )
        var routedPriorGeneration = false
        while let event = try await priorIterator.next() {
            if [event].containsThreadText(
                "Before failed resume",
                turnID: "turn-resume-failure"
            ) {
                routedPriorGeneration = true
                break
            }
        }
        #expect(routedPriorGeneration)
        priorEvents.cancel()

        await runtime.transport.enqueueFailure(
            code: -32_000,
            message: "resume failed",
            for: "thread/resume"
        )
        do {
            _ = try await runtime.server.resumeThread("thread-resume-failure")
            Issue.record("Expected resume failure.")
        } catch {
            // Expected failure; the existing generation must remain replayable.
        }
        try await runtime.transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-resume-failure")
        )

        let events = try await collect(thread.events)
        #expect(events.containsThreadText("Before failed resume", turnID: "turn-resume-failure"))
    }

    @Test func threadStreamsReplayMessagesTranscriptLogsAndUsage() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
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
            router: router,
            connectionLease: harness.lease
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
                if case .terminal(let outcome) = $0 {
                    outcome.response.turnID == "turn-1"
                        && outcome.response.usage?.totalTokens == 3
                } else {
                    false
                }
            })
    }

    @Test func threadItemDecodeReadsTextObjectContentFragments() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    id: "message-1",
                    type: "userMessage",
                    contentItems: [
                        .init(text: "hello"),
                        .init(text: "world"),
                    ]
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
            router: router,
            connectionLease: harness.lease
        )
        let transcripts = try await collect(thread.transcriptUpdates)

        #expect(transcripts.last?.items.first?.text == "hello\nworld")
    }

    @Test func threadTranscriptSupersedesPriorTerminalGeneration() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router,
            connectionLease: harness.lease
        )
        let transcriptsTask = Task {
            try await collect(thread.transcriptUpdates)
        }
        #expect(await eventually {
            router.threadSubscriberCountForTesting(for: "thread-1") == 1
        })
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(threadID: "thread-1", turnID: "turn-1")
        )
        try await emitItemStarted(
            on: transport,
            threadID: "thread-1",
            turnID: "turn-1",
            item: .init(id: "message-1", type: "agentMessage", text: "")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(turnID: "turn-1", itemID: "message-1", delta: "First")
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "completed"))
        )
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TurnStartedParams(threadID: "thread-1", turnID: "turn-2")
        )
        try await emitItemStarted(
            on: transport,
            threadID: "thread-1",
            turnID: "turn-2",
            item: .init(id: "message-2", type: "agentMessage", text: "")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(turnID: "turn-2", itemID: "message-2", delta: "Second")
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-2", status: "completed"))
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )
        let transcripts = try await transcriptsTask.value

        #expect(transcripts.last?.items.compactMap(\.text) == ["Second"])
    }

    @Test func responseStreamYieldsSnapshotsAndCollectsFinalResponse() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router,
            connectionLease: harness.lease
        )

        let stream = try await thread.streamResponse {
            "Summarize this."
            CodexPrompt.Part.mention(name: "repo", path: URL(fileURLWithPath: "/tmp/repo"))
        }
        var iterator = stream.makeAsyncIterator()
        let started = try await iterator.next()
        #expect(started?.turnID == "turn-1")
        #expect(started?.content == nil)

        try await emitItemStarted(
            on: transport,
            threadID: "thread-1",
            turnID: "turn-1",
            item: .init(id: "message-1", type: "agentMessage", text: "", phase: "final_answer")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(turnID: "turn-1", itemID: "message-1", delta: "Final")
        )
        var updated = try await iterator.next()
        while let snapshot = updated, snapshot.content != "Final" {
            updated = try await iterator.next()
        }
        #expect(updated?.turnID == "turn-1")
        #expect(updated?.content == "Final")
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "completed"))
        )

        let response = try await stream.collect()
        #expect(response.response.turnID == "turn-1")
        #expect(response.response.transcript.finalAnswer == "Final")

        let request = try #require(await transport.recordedRequests().first)
        let params = try JSONDecoder().decode(
            AppServerAPI.Turn.Start.Params.self, from: request.params)
        #expect(
            params.input == [
                .text("Summarize this."),
                .mention(name: "repo", path: "/tmp/repo"),
            ])
    }

    @Test func responseStreamDoesNotAppendCompleteAgentMessageAsDelta() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router, connectionLease: harness.lease)

        let stream = try await thread.streamResponse(to: "Summarize this.")
        try await emitItemStarted(
            on: transport,
            threadID: "thread-1",
            turnID: "turn-1",
            item: .init(id: "message-1", type: "agentMessage", text: "", phase: "final_answer")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(turnID: "turn-1", itemID: "message-1", delta: "Final")
        )
        try await transport.emitServerNotification(
            method: "agent/message",
            params: AgentMessageParams(turnID: "turn-1", itemID: "message-1", message: "Final")
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "completed"))
        )

        let response = try await stream.collect()

        #expect(response.response.transcript.finalAnswer == "Final")
        #expect(response.response.transcript.items.first?.text == "Final")
    }

    @Test func responseStreamCollectsTranscriptFromCompletedTurnItems() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router, connectionLease: harness.lease)

        let stream = try await thread.streamResponse(to: "Summarize this.")
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(
                id: "turn-1",
                status: "completed",
                items: [
                    .object([
                        "id": .string("message-1"),
                        "type": .string("agentMessage"),
                        "text": .string("Final from payload"),
                        "phase": .string("final_answer"),
                    ]),
                ]
            ))
        )

        let response = try await stream.collect()

        #expect(response.response.transcript.finalAnswer == "Final from payload")
        #expect(response.response.transcript.items.first?.text == "Final from payload")
    }

    @Test func responseStreamSnapshotsIncludeIncrementalTokenUsage() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router, connectionLease: harness.lease)

        let stream = try await thread.streamResponse(to: "Summarize usage.")
        var iterator = stream.makeAsyncIterator()
        let initial = try await iterator.next()
        #expect(initial?.turnID == "turn-1")
        #expect(initial?.usage == nil)
        try await transport.emitServerNotification(
            method: "thread/tokenUsage/updated",
            params: TokenUsageParams(
                threadID: "thread-1",
                turnID: "turn-1",
                tokenUsage: .init(
                    total: .init(inputTokens: 5, outputTokens: 8, totalTokens: 13)
                )
            )
        )

        let snapshot = try await iterator.next()

        #expect(snapshot?.turnID == "turn-1")
        #expect(snapshot?.usage?.inputTokens == 5)
        #expect(snapshot?.usage?.outputTokens == 8)
        #expect(snapshot?.usage?.totalTokens == 13)
        #expect(snapshot?.response == nil)
    }

    @Test func responseStreamFailureCarriesPartialResponse() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(id: "thread-1", client: client, router: router, connectionLease: harness.lease)

        let stream = try await thread.streamResponse(to: "Try this.")
        var iterator = stream.makeAsyncIterator()
        let started = try await iterator.next()
        #expect(started?.content == nil)
        try await emitItemStarted(
            on: transport,
            threadID: "thread-1",
            turnID: "turn-1",
            item: .init(id: "message-1", type: "agentMessage", text: "", phase: "final_answer")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(turnID: "turn-1", itemID: "message-1", delta: "Partial")
        )
        var partial = try await iterator.next()
        while let snapshot = partial, snapshot.content != "Partial" {
            partial = try await iterator.next()
        }
        #expect(partial?.content == "Partial")
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

        var terminal = try await iterator.next()
        while let snapshot = terminal, snapshot.response == nil {
            terminal = try await iterator.next()
        }
        #expect(terminal?.response?.transcript.responseText == "Partial")
        #expect(terminal?.response?.startedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(terminal?.response?.duration == .milliseconds(1_000))
        #expect(try await iterator.next() == nil)

        let outcome = try await stream.collect()
        if case .failed(let failedTurn) = outcome {
            #expect(failedTurn.error.message == "Tool failed.")
            #expect(failedTurn.response.transcript.responseText == "Partial")
        } else {
            Issue.record("Expected failed turn outcome.")
        }
    }

    @Test func responseStreamSerializesReasoningOptions() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        let thread = CodexThread(id: "thread-1", client: client, router: router, connectionLease: harness.lease)

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

    @Test func responseStreamSerializesSandboxPolicyWithAppServerSchema() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        let thread = CodexThread(id: "thread-1", client: client, router: router, connectionLease: harness.lease)

        _ = try await thread.streamResponse(
            to: "Explain the patch.",
            options: .init(sandbox: .workspaceWrite)
        )

        let request = try #require(await transport.recordedRequests().first)
        let params = try #require(
            JSONSerialization.jsonObject(with: request.params) as? [String: Any]
        )
        let sandboxPolicy = try #require(params["sandboxPolicy"] as? [String: Any])
        #expect(sandboxPolicy["type"] as? String == "workspaceWrite")
        #expect((sandboxPolicy["writableRoots"] as? [Any])?.isEmpty == true)
        #expect(sandboxPolicy["networkAccess"] as? Bool == false)
        #expect(sandboxPolicy["excludeTmpdirEnvVar"] as? Bool == false)
        #expect(sandboxPolicy["excludeSlashTmp"] as? Bool == false)
        #expect(sandboxPolicy.keys.contains("writable_roots") == false)
        #expect(sandboxPolicy.keys.contains("network_access") == false)
    }

    @Test func responseStreamSerializesApprovalPolicyWithAppServerSchema() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        let thread = CodexThread(id: "thread-1", client: client, router: router, connectionLease: harness.lease)

        _ = try await thread.streamResponse(
            to: "Explain the patch.",
            options: .init(approvalMode: .autoReview)
        )

        let request = try #require(await transport.recordedRequests().first)
        let params = try #require(
            JSONSerialization.jsonObject(with: request.params) as? [String: Any]
        )
        #expect(params["approvalPolicy"] as? String == "on-request")
        #expect(params["approvalPolicy"] as? String != "onRequest")
    }

    @Test func messageDeltaLogEntriesUseUniqueEntryIDs() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router,
            connectionLease: harness.lease
        )
        let logs = thread.logEntries
        try await emitItemStarted(
            on: transport,
            threadID: "thread-1",
            turnID: "turn-1",
            item: .init(id: "message-1", type: "agentMessage", text: "")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "message-1",
                delta: "First"
            )
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "message-1",
                delta: "Second"
            )
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )

        let collectedLogs = try await collect(logs)
        let deltas = collectedLogs.filter { $0.phase == .delta }
        #expect(deltas.map(\.id) == ["message-1:0", "message-1:1"])
        #expect(deltas.compactMap(\.messageDelta).map(\.text) == ["First", "Second"])
    }

    @Test func lateThreadLogEntriesReplayOnlyTheCurrentGeneration() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        try await emitItemStarted(
            on: transport,
            threadID: "thread-1",
            turnID: "turn-1",
            item: .init(id: "message-1", type: "agentMessage", text: "")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "message-1",
                delta: "First"
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TurnCompletedParams(turn: .init(id: "turn-1", status: "completed"))
        )
        try await emitItemStarted(
            on: transport,
            threadID: "thread-1",
            turnID: "turn-2",
            item: .init(id: "message-1", type: "agentMessage", text: "")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TurnDeltaParams(
                threadID: "thread-1",
                turnID: "turn-2",
                itemID: "message-1",
                delta: "Second"
            )
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )
        #expect(await eventually {
            router.threadEventHub.snapshotForTesting(threadID: "thread-1").isClosed
        })

        let thread = CodexThread(id: "thread-1", client: client, router: router, connectionLease: harness.lease)
        let logs = try await collect(thread.logEntries)
        let deltas = logs.filter { $0.phase == .delta }
        #expect(deltas.map(\.id) == ["message-1:0"])
        #expect(deltas.compactMap(\.messageDelta).map(\.text) == ["Second"])
    }

    @Test func messageDeltaWithoutItemIDFailsAsMalformedNotification() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        await transport.waitForNotificationStreamCount(1)
        let events = await harness.server.connectionEvents()
        let terminal = Task { await firstConnectionTermination(in: events) }
        await events.waitUntilNextSuspendsForTesting()
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: MessageDeltaWithoutItemIDParams(
                threadID: "thread-1",
                turnID: "turn-1",
                delta: "Missing item identity"
            )
        )

        let termination = try #require(await terminal.value)
        guard case .transportFailure(.protocolViolation(let message, _)) = termination else {
            Issue.record("Expected connection protocol violation, got \(termination).")
            return
        }
        #expect(message.contains("item/agentMessage/delta"))
    }

    @Test func threadItemWithoutIDFailsAsMalformedNotification() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        await transport.waitForNotificationStreamCount(1)
        let events = await harness.server.connectionEvents()
        let terminal = Task { await firstConnectionTermination(in: events) }
        await events.waitUntilNextSuspendsForTesting()
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemWithoutIDParams(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "agentMessage", text: "Missing item identity")
            )
        )

        let termination = try #require(await terminal.value)
        guard case .transportFailure(.protocolViolation(let message, _)) = termination else {
            Issue.record("Expected connection protocol violation, got \(termination).")
            return
        }
        #expect(message.contains("item/completed"))
    }

    @Test func threadLogEntriesIncludeProgressDeltaNotifications() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router,
            connectionLease: harness.lease
        )
        let logEntries = thread.logEntries

        try await emitItemStarted(
            on: transport,
            threadID: "thread-1",
            turnID: "turn-1",
            item: .init(
                id: "command-1",
                type: "commandExecution",
                command: "swift test",
                aggregatedOutput: "",
                status: "inProgress"
            )
        )
        try await transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: ItemOutputDeltaParams(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "command-1",
                delta: "Compiling"
            )
        )
        try await emitItemStarted(
            on: transport,
            threadID: "thread-1",
            turnID: "turn-1",
            item: .init(
                id: "patch-1",
                type: "fileChange",
                status: "inProgress",
                changes: .array([])
            )
        )
        try await transport.emitServerNotification(
            method: "item/fileChange/patchUpdated",
            params: ItemPatchUpdatedParams(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "patch-1",
                changes: .array([
                    .object([
                        "diff": .string("@@ -1 +1 @@"),
                        "kind": .object(["type": .string("update")]),
                        "path": .string("Sources/File.swift"),
                    ]),
                ])
            )
        )
        try await emitItemStarted(
            on: transport,
            threadID: "thread-1",
            turnID: "turn-1",
            item: .init(
                id: "tool-1",
                type: "mcpToolCall",
                status: "inProgress",
                tool: "review"
            )
        )
        try await transport.emitServerNotification(
            method: "item/mcpToolCall/progress",
            params: ItemProgressParams(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "tool-1",
                message: "Reviewing"
            )
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )

        let logs = try await collect(logEntries)
        let updates = logs.filter { $0.phase == .updated }

        #expect(updates.count == 3)
        #expect(updates.allSatisfy { $0.turnID == "turn-1" })
        #expect(updates.contains {
            guard case .command(let command) = $0.item?.content else {
                return false
            }
            return command.command == "swift test" && command.output == "Compiling"
        })
        #expect(
            updates.contains {
                if case .fileChange(let fileChange) = $0.item?.content {
                    fileChange.output == "@@ -1 +1 @@"
                } else {
                    false
                }
            })
        #expect(
            updates.contains {
                if case .toolCall(let toolCall) = $0.item?.content {
                    toolCall.result == "Reviewing"
                } else {
                    false
                }
            })
    }

    @Test func progressDeltaWithoutItemIDFailsAsMalformedNotification() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        await transport.waitForNotificationStreamCount(1)
        let events = await harness.server.connectionEvents()
        let terminal = Task { await firstConnectionTermination(in: events) }
        await events.waitUntilNextSuspendsForTesting()

        try await transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: ItemOutputDeltaWithoutItemIDParams(
                threadID: "thread-1",
                turnID: "turn-1",
                delta: "Compiling"
            )
        )

        let termination = try #require(await terminal.value)
        guard case .transportFailure(.protocolViolation(let message, _)) = termination else {
            Issue.record("Expected connection protocol violation, got \(termination).")
            return
        }
        #expect(message.contains("item/commandExecution/outputDelta"))
    }

    @Test func completedFileChangeItemsPreserveChangesOutput() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ThreadItemParams(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    id: "file-1",
                    type: "fileChange",
                    status: "completed",
                    changes: .array([
                        .object([
                            "diff": .string("@@ -1 +1 @@"),
                            "kind": .object(["type": .string("update")]),
                            "path": .string("Sources/File.swift"),
                        ]),
                    ])
                )
            )
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: ThreadIDParams(threadID: "thread-1")
        )
        let thread = CodexThread(id: "thread-1", client: client, router: router, connectionLease: harness.lease)

        let logs = try await collect(thread.logEntries)

        guard case .fileChange(let fileChange) = logs.first?.item?.content else {
            Issue.record("Expected a structured file-change item.")
            return
        }
        #expect(fileChange.path == "Sources/File.swift")
        #expect(fileChange.output == "@@ -1 +1 @@")
    }

    @Test func reasoningNotificationsRouteAsTypedEventsLogsAndTranscript() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        await transport.waitForNotificationStreamCount(1)
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router,
            connectionLease: harness.lease
        )
        let eventsTask = Task { try await collect(thread.events) }
        let logsTask = Task { try await collect(thread.logEntries) }
        let transcriptsTask = Task { try await collect(thread.transcriptUpdates) }
        #expect(await eventually {
            router.threadSubscriberCountForTesting(for: "thread-1") == 3
        })

        try await emitItemStarted(
            on: transport,
            threadID: "thread-1",
            turnID: "turn-1",
            item: .init(
                id: "reasoning-1",
                type: "reasoning",
                summary: [],
                content: []
            )
        )
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

        let events = try await eventsTask.value
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

        let logs = try await logsTask.value
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

        let transcripts = try await transcriptsTask.value
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
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let server = harness.server

        let models = try await server.models()
        let reasoningEfforts = models.first?.supportedReasoningEfforts.map(\.reasoningEffort)
        #expect(reasoningEfforts == [.medium, .xhigh])
        #expect(models.first?.defaultReasoningEffort == .xhigh)

        let configuration = try await server.configuration()
        #expect(configuration.reasoningEffort == .high)
    }

    @Test func updateConfigurationSendsBatchWriteEdits() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(#"{"status":"ok"}"#, for: "config/batchWrite")
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let server = harness.server

        var patch = CodexConfigurationPatch()
        patch.setReviewModel("gpt-5-codex-review")
        patch.setReasoningEffort(.high)
        patch.setServiceTier("flex")
        try await server.updateConfiguration(patch)

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.method == "config/batchWrite")
        let params = try request.decodeParams(ConfigBatchWriteParams.self)
        #expect(params.reloadUserConfig == true)
        #expect(params.edits == [
            .init(keyPath: "review_model", value: .string("gpt-5-codex-review")),
            .init(keyPath: "model_reasoning_effort", value: .string("high")),
            .init(keyPath: "service_tier", value: .string("flex")),
        ])
    }

    @Test func updateConfigurationSkipsEmptyPatch() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let server = harness.server

        try await server.updateConfiguration(.init())

        #expect(await transport.recordedRequests().isEmpty)
    }

    @Test func testRuntimeEnqueuesRateLimitResetTimesInAppServerSeconds() async throws {
        let transport = CodexAppServerTestTransport()
        let resetDate = Date(timeIntervalSince1970: 1_700_000_000)
        try await transport.enqueueRateLimits(.init(
            planType: "pro",
            windows: [
                .init(
                    windowDurationMinutes: 300,
                    usedPercent: 42,
                    resetsAt: resetDate
                ),
            ]
        ))
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let server = harness.server

        let rateLimits = try await server.rateLimits()

        #expect(rateLimits.planType == "pro")
        #expect(rateLimits.windows == [
            .init(
                windowDurationMinutes: 300,
                usedPercent: 42,
                resetsAt: resetDate
            ),
        ])
    }

    @Test func rateLimitsDecodeCoreWindowWireShape() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "planType": "pro",
                "primary": {
                  "used_percent": 87.5,
                  "window_minutes": 60,
                  "resets_at": 1700000000
                }
              }
            }
            """,
            for: "account/rateLimits/read"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let server = harness.server

        let rateLimits = try await server.rateLimits()

        #expect(rateLimits.planType == "pro")
        #expect(rateLimits.windows == [
            .init(
                windowDurationMinutes: 60,
                usedPercent: 88,
                resetsAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
        ])
    }

    @Test func accountReadAcceptsChatGPTAccountWithoutEmail() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(
            """
            {
              "account": {
                "type": "chatgpt",
                "email": null,
                "planType": "plus"
              },
              "requiresOpenaiAuth": false
            }
            """,
            for: "account/read"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let server = harness.server

        let account = try #require(try await server.account())

        #expect(account.kind == .chatGPT)
        #expect(account.id == "chatgpt")
        #expect(account.label == "ChatGPT")
        #expect(account.planType == "plus")
    }

    @Test func loginFlowUsesSupportedRequests() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueChatGPTLogin(
            loginID: "login-1",
            authenticationURL: URL(string: "https://chatgpt.com/auth")!
        )
        try await transport.enqueue(
            AppServerAPI.Account.Login.Cancel.Response(),
            for: "account/login/cancel"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let server = harness.server
        let handle = try await server.loginChatGPT()

        #expect(handle.id == "login-1")
        #expect(handle.authenticationURL == URL(string: "https://chatgpt.com/auth")!)
        let loginRequest = try #require(await transport.recordedRequests().first)
        #expect(loginRequest.method == "account/login/start")
        let loginParams = try loginRequest.decodeParams(AppServerAPI.Account.Login.Params.self)
        #expect(loginParams.type == "chatgpt")
        #expect(loginParams.codexStreamlinedLogin == true)

        #expect(try await handle.cancel() == .cancelled)
        let cancelRequest = try #require(await transport.recordedRequests().last)
        #expect(cancelRequest.method == "account/login/cancel")
        let cancelParams = try cancelRequest.decodeParams(
            AppServerAPI.Account.Login.Cancel.Params.self
        )
        #expect(cancelParams.loginID == "login-1")

        #expect(await transport.recordedRequests().map(\.method) == [
            "account/login/start",
            "account/login/cancel",
        ])
    }

    @Test func apiKeyLoginUsesAnExclusiveWireShapeWithoutExposingTheSecretSemantically() async throws {
        let apiKey = "sk-test-api-key-secret-sentinel"
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueAPIKeyLogin()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)

        try await harness.server.login(apiKey: apiKey)

        let request = try #require(
            await transport.recordedRequests(method: "account/login/start").first
        )
        guard case .apiKey(let encodedAPIKey) = try request.decodeParams(
            AppServerAPI.Account.Login.Params.self
        ) else {
            Issue.record("Expected API-key login parameters.")
            return
        }
        #expect(encodedAPIKey == apiKey)

        let object = try #require(
            JSONSerialization.jsonObject(with: request.params) as? [String: Any]
        )
        #expect(Set(object.keys) == Set(["type", "apiKey"]))
        #expect(object["type"] as? String == "apiKey")
        #expect(object["apiKey"] as? String == apiKey)

        let semanticRequest = try #require(await transport.recordedRequests().first?.request)
        #expect(semanticRequest == .accountLoginStart)
        #expect(String(reflecting: semanticRequest).contains(apiKey) == false)
        await harness.close()
    }

    @Test func loginParameterDecoderRejectsMixedProviderStates() throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                AppServerAPI.Account.Login.Params.self,
                from: Data(
                    #"{"type":"apiKey","apiKey":"placeholder","codexStreamlinedLogin":true}"#.utf8
                )
            )
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                AppServerAPI.Account.Login.Params.self,
                from: Data(
                    #"{"type":"chatgpt","apiKey":"placeholder","codexStreamlinedLogin":true}"#.utf8
                )
            )
        }
    }

    @Test func apiKeyLoginRejectsInvalidInputBeforeSendingARequest() async throws {
        let transport = CodexAppServerTestTransport()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let invalidInputs: [(String, CodexAPIKeyValidationFailure)] = [
            ("", .empty),
            (" \n\t", .empty),
            (" sk-test-validation-leading", .surroundingWhitespace),
            ("sk-test-validation-trailing\n", .surroundingWhitespace),
        ]

        for (apiKey, expectedFailure) in invalidInputs {
            do {
                try await harness.server.login(apiKey: apiKey)
                Issue.record("Expected invalid API-key input to fail.")
            } catch let error as CodexAppServerError {
                #expect(error == .invalidAPIKey(expectedFailure))
                let sensitiveValue = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if sensitiveValue.hasPrefix("sk-") {
                    #expect(error.localizedDescription.contains(sensitiveValue) == false)
                }
            }
        }

        #expect(await transport.recordedRequests(method: "account/login/start").isEmpty)
        await harness.close()
    }

    @Test func apiKeyLoginRejectsAnUnexpectedProviderResponseWithoutExposingTheSecret() async throws {
        let apiKey = "sk-test-unexpected-response-secret"
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueChatGPTLogin(
            loginID: "unexpected-login",
            authenticationURL: URL(string: "https://example.test/\(apiKey)")!
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)

        do {
            try await harness.server.login(apiKey: apiKey)
            Issue.record("Expected the provider mismatch to require reconciliation.")
        } catch let error as CodexAppServerError {
            #expect(error == .authenticationOutcomeUnknown(.unexpectedResponse))
            #expect(error.localizedDescription.contains(apiKey) == false)
            #expect(String(reflecting: error).contains(apiKey) == false)
        }
        await harness.close()
    }

    @Test func apiKeyLoginSanitizesAnInvalidResponseThatEchoesTheSecret() async throws {
        let apiKey = "sk-test-invalid-response-secret"
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueJSON(
            #"{"type":42,"echo":"\#(apiKey)"}"#,
            for: "account/login/start"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)

        do {
            try await harness.server.login(apiKey: apiKey)
            Issue.record("Expected the invalid response to require reconciliation.")
        } catch let error as CodexAppServerError {
            #expect(error == .authenticationOutcomeUnknown(.invalidResponse))
            #expect(error.localizedDescription.contains(apiKey) == false)
            #expect(String(reflecting: error).contains(apiKey) == false)
        }
        await harness.close()
    }

    @Test func apiKeyLoginKeepsExplicitServerRejectionKnownAndSecretFree() async throws {
        let apiKey = "sk-test-server-rejection-secret"
        let transport = CodexAppServerTestTransport()
        await transport.enqueueFailure(
            code: -32_000,
            message: "rejected \(apiKey)",
            for: "account/login/start"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)

        do {
            try await harness.server.login(apiKey: apiKey)
            Issue.record("Expected an explicit server rejection.")
        } catch let error as CodexAppServerError {
            guard case .request(let failure) = error,
                  case .server(let serverError) = failure.kind else {
                Issue.record("Expected a known server rejection, got \(error).")
                return
            }
            #expect(serverError.code == -32_000)
            #expect(serverError.message == "API-key login was rejected by the app-server.")
            #expect(error.localizedDescription.contains(apiKey) == false)
            #expect(String(reflecting: error).contains(apiKey) == false)
        }
        await harness.close()
    }

    @Test func apiKeyLoginPostWriteCancellationDoesNotHideAServerRejection() async throws {
        let apiKey = "sk-test-cancelled-server-rejection-secret"
        let transport = CodexAppServerTestTransport()
        let responseGate = CodexAppServerTestGate()
        await transport.enqueueFailure(
            code: -32_000,
            message: "rejected \(apiKey)",
            for: "account/login/start"
        )
        await transport.holdNextIgnoringCancellation(
            method: "account/login/start",
            gate: responseGate
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let task = Task {
            try await harness.server.login(apiKey: apiKey)
        }
        await transport.waitForRequest(method: "account/login/start")

        task.cancel()
        await responseGate.open()

        do {
            try await task.value
            Issue.record("Expected the correlated server rejection.")
        } catch let error as CodexAppServerError {
            guard case .request(let failure) = error,
                  case .server(let serverError) = failure.kind else {
                Issue.record("Expected a known server rejection, got \(error).")
                return
            }
            #expect(serverError.code == -32_000)
            #expect(error.localizedDescription.contains(apiKey) == false)
        }
        await harness.close()
    }

    @Test func apiKeyLoginDoesNotRetryOrPublishAnOverloadResponseContainingTheSecret() async throws {
        let apiKey = "sk-test-overload-secret"
        let transport = CodexAppServerTestTransport()
        await transport.enqueueFailure(
            code: -32_001,
            message: "overloaded \(apiKey)",
            for: "account/login/start"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)

        do {
            try await harness.server.login(apiKey: apiKey)
            Issue.record("Expected an explicit overload rejection.")
        } catch let error as CodexAppServerError {
            guard case .request(let failure) = error,
                  case .server(let serverError) = failure.kind else {
                Issue.record("Expected a known overload rejection, got \(error).")
                return
            }
            #expect(serverError.code == -32_001)
            #expect(error.localizedDescription.contains(apiKey) == false)
            #expect(String(reflecting: error).contains(apiKey) == false)
        }
        #expect(await transport.recordedRequests(method: "account/login/start").count == 1)
        await harness.close()
    }

    @Test func apiKeyLoginCancellationBeforeWriteHasNoWireEffect() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueAPIKeyLogin()
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let startGate = CodexAppServerTestGate()
        let task = Task {
            await startGate.waitIgnoringCancellation()
            try await harness.server.login(apiKey: "sk-test-pre-write-cancellation")
        }
        await startGate.waitUntilBlocked()

        task.cancel()
        await startGate.open()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await transport.recordedRequests(method: "account/login/start").isEmpty)
        await harness.close()
    }

    @Test func apiKeyLoginDefersPostWriteCancellationUntilTheResponseIsKnown() async throws {
        let transport = CodexAppServerTestTransport()
        let responseGate = CodexAppServerTestGate()
        try await transport.enqueueAPIKeyLogin()
        await transport.holdNextIgnoringCancellation(
            method: "account/login/start",
            gate: responseGate
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let task = Task {
            try await harness.server.login(apiKey: "sk-test-post-write-cancellation")
        }
        await transport.waitForRequest(method: "account/login/start")

        task.cancel()
        await responseGate.open()

        try await task.value
        #expect(await transport.recordedRequests(method: "account/login/start").count == 1)
        #expect(await transport.recordedRequests(method: "account/login/cancel").isEmpty)
        await harness.close()
    }

    @Test func apiKeyLoginDeadlineAfterWriteRequiresReconciliation() async throws {
        let transport = CodexAppServerTestTransport()
        let responseGate = CodexAppServerTestGate()
        let deadlineClock = CodexAppServerTestDeadlineClock()
        try await transport.enqueueAPIKeyLogin()
        await transport.holdNextIgnoringCancellation(
            method: "account/login/start",
            gate: responseGate
        )
        let runtime = try await CodexAppServerTestRuntime.start(
            transport: transport,
            configuration: .init(deadlines: .init(request: .seconds(5))),
            deadlineClock: deadlineClock
        )
        let task = Task {
            try await runtime.server.login(apiKey: "sk-test-deadline")
        }
        await transport.waitForRequest(method: "account/login/start")
        try await deadlineClock.waitForSleeperCount(1)

        deadlineClock.advance(by: .seconds(5))

        do {
            try await task.value
            Issue.record("Expected an unknown authentication outcome after the deadline.")
        } catch let error as CodexAppServerError {
            #expect(error == .authenticationOutcomeUnknown(.deadlineExceeded(.seconds(5))))
        }
        #expect(await transport.isClosedForTesting())
        await runtime.close()
    }

    @Test func apiKeyLoginWriteFailureAfterAcceptanceRequiresReconciliation() async throws {
        let apiKey = "sk-test-post-write-transport-secret"
        let transport = TestOutboundWriteFailureTransport(
            failure: .contractViolation(message: "failed after writing \(apiKey)")
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)

        do {
            try await harness.server.login(apiKey: apiKey)
            Issue.record("Expected transport reconciliation after write acceptance.")
        } catch let error as CodexAppServerError {
            #expect(error == .authenticationOutcomeUnknown(.transportEnded))
            #expect(error.localizedDescription.contains(apiKey) == false)
            #expect(String(reflecting: error).contains(apiKey) == false)
        }
        await harness.close()
    }

    @Test func apiKeyLoginConnectionTerminationAfterWriteRequiresReconciliation() async throws {
        let apiKey = "sk-test-connection-secret"
        let transport = CodexAppServerTestTransport()
        let responseGate = CodexAppServerTestGate()
        try await transport.enqueueAPIKeyLogin()
        await transport.holdNextIgnoringCancellation(
            method: "account/login/start",
            gate: responseGate
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let task = Task {
            try await harness.server.login(apiKey: apiKey)
        }
        await transport.waitForRequest(method: "account/login/start")

        await transport.failConnection(.closed)
        await responseGate.open()

        do {
            try await task.value
            Issue.record("Expected connection reconciliation.")
        } catch let error as CodexAppServerError {
            #expect(error == .authenticationOutcomeUnknown(.connectionTerminated))
            #expect(error.localizedDescription.contains(apiKey) == false)
        }
        await harness.close()
    }

    @Test func stockChatGPTLoginResolvesAfterPostSuccessAccountUpdate() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueChatGPTLogin(
            loginID: "login-1",
            authenticationURL: URL(string: "https://chatgpt.com/auth")!
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let server = harness.server

        let login = try await server.loginChatGPT()

        #expect(login.id == "login-1")
        #expect(login.authenticationURL == URL(string: "https://chatgpt.com/auth")!)
        let loginRequest = try #require(await transport.recordedRequests().first)
        #expect(loginRequest.method == "account/login/start")
        let loginParams = try loginRequest.decodeParams(AppServerAPI.Account.Login.Params.self)
        #expect(loginParams.type == "chatgpt")
        #expect(loginParams.codexStreamlinedLogin == true)
        try await transport.emitServerNotificationJSON(
            method: "account/login/completed",
            json: #"{"loginId":"login-1","success":true,"error":null}"#
        )
        try await transport.emitServerNotificationJSON(
            method: "account/updated",
            json: #"{"authMode":"chatgpt","planType":"plus"}"#
        )
        #expect(try await login.result() == .succeeded)
        #expect(try await login.result() == .succeeded)
        #expect(await transport.recordedRequests().map(\.method) == ["account/login/start"])
    }

    @Test func stockChatGPTLoginPreservesAccountUpdateReceivedBeforeSuccess() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueChatGPTLogin(
            loginID: "login-1",
            authenticationURL: URL(string: "https://chatgpt.com/auth")!
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let login = try await harness.server.loginChatGPT()

        try await transport.emitServerNotificationJSON(
            method: "account/updated",
            json: #"{"authMode":"chatgpt","planType":"plus"}"#
        )
        try await transport.emitServerNotificationJSON(
            method: "account/login/completed",
            json: #"{"loginId":"login-1","success":true,"error":null}"#
        )

        #expect(try await login.result() == .succeeded)
    }

    @Test func stockChatGPTLoginIgnoresSparseAccountUpdateWhileAwaitingReadiness() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueChatGPTLogin(
            loginID: "login-1",
            authenticationURL: URL(string: "https://chatgpt.com/auth")!
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let login = try await harness.server.loginChatGPT()

        try await transport.emitServerNotificationJSON(
            method: "account/login/completed",
            json: #"{"loginId":"login-1","success":true,"error":null}"#
        )
        try await transport.emitServerNotificationJSON(
            method: "account/updated",
            json: #"{"planType":"plus"}"#
        )
        await #expect(throws: CodexAppServerError.loginAlreadyInProgress) {
            _ = try await harness.server.loginChatGPT()
        }

        try await transport.emitServerNotificationJSON(
            method: "account/updated",
            json: #"{"authMode":"chatgpt","planType":"plus"}"#
        )
        #expect(try await login.result() == .succeeded)
    }

    @Test func stockChatGPTLoginRejectsExplicitNonChatGPTAccountAfterSuccess() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueChatGPTLogin(
            loginID: "login-1",
            authenticationURL: URL(string: "https://chatgpt.com/auth")!
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let login = try await harness.server.loginChatGPT()

        try await transport.emitServerNotificationJSON(
            method: "account/login/completed",
            json: #"{"loginId":"login-1","success":true,"error":null}"#
        )
        try await transport.emitServerNotificationJSON(
            method: "account/updated",
            json: #"{"authMode":"apikey"}"#
        )

        #expect(
            try await login.result() == .authenticationCommittedNeedsConnectionReconciliation(
                .chatGPTAccountUnavailableAfterSuccess
            )
        )
    }

    @Test func stockChatGPTLoginDropsMismatchedCompletionID() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueChatGPTLogin(
            loginID: "login-1",
            authenticationURL: URL(string: "https://chatgpt.com/auth")!
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let handle = try await harness.server.loginChatGPT()

        try await transport.emitServerNotificationJSON(
            method: "account/login/completed",
            json: #"{"loginId":"other-login","success":false,"error":"stale"}"#
        )
        try await transport.emitServerNotificationJSON(
            method: "account/login/completed",
            json: #"{"loginId":"login-1","success":true,"error":null}"#
        )
        try await transport.emitServerNotificationJSON(
            method: "account/updated",
            json: #"{"authMode":"chatgpt","planType":"plus"}"#
        )

        #expect(try await handle.result() == .succeeded)
    }

    @Test func stockChatGPTLoginReleasesReservationAfterStartFailure() async throws {
        let transport = CodexAppServerTestTransport()
        await transport.enqueueFailure(
            code: -32_000,
            message: "login unavailable",
            for: "account/login/start"
        )
        try await transport.enqueueChatGPTLogin(
            loginID: "login-2",
            authenticationURL: URL(string: "https://chatgpt.com/auth/2")!
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)

        await #expect(throws: CodexAppServerError.self) {
            _ = try await harness.server.loginChatGPT()
        }
        let handle = try await harness.server.loginChatGPT()

        #expect(handle.id == "login-2")
        #expect(await transport.recordedRequests(method: "account/login/start").count == 2)
    }

    @Test func stockChatGPTLoginRejectsConcurrentStartBeforeSendingASecondRequest() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueChatGPTLogin(
            loginID: "login-1",
            authenticationURL: URL(string: "https://chatgpt.com/auth")!
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let activeHandle = try await harness.server.loginChatGPT()

        do {
            _ = try await harness.server.loginChatGPT()
            Issue.record("Expected the active login reservation to reject a second start.")
        } catch let error as CodexAppServerError {
            #expect(error == .loginAlreadyInProgress)
        }
        #expect(await transport.recordedRequests(method: "account/login/start").count == 1)
        _ = activeHandle
    }

    @Test func stockChatGPTLoginRegistryRetainsPendingStateAfterHandleIsDropped() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueChatGPTLogin(
            loginID: "login-1",
            authenticationURL: URL(string: "https://chatgpt.com/auth/1")!
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let server = harness.server

        let authenticationURL = try await server.loginChatGPT().authenticationURL
        #expect(authenticationURL == URL(string: "https://chatgpt.com/auth/1")!)
        await #expect(throws: CodexAppServerError.loginAlreadyInProgress) {
            _ = try await server.loginChatGPT()
        }
        #expect(await transport.recordedRequests(method: "account/login/start").count == 1)

        await harness.router.loginRegistry.apply(
            .init(loginID: "login-1", success: true)
        )
        await harness.router.loginRegistry.applyAccountUpdate(
            .init(authMode: .chatGPT, planType: .plus)
        )
        try await transport.enqueueChatGPTLogin(
            loginID: "login-2",
            authenticationURL: URL(string: "https://chatgpt.com/auth/2")!
        )

        let nextHandle = try await server.loginChatGPT()

        #expect(nextHandle.id == "login-2")
        #expect(await transport.recordedRequests(method: "account/login/start").count == 2)
    }

    @Test func stockChatGPTLoginCancellationIsSharedAcrossConcurrentCallers() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueChatGPTLogin(
            loginID: "login-1",
            authenticationURL: URL(string: "https://chatgpt.com/auth")!
        )
        try await transport.enqueue(
            AppServerAPI.Account.Login.Cancel.Response(),
            for: "account/login/cancel"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let handle = try await harness.server.loginChatGPT()

        async let first = handle.cancel()
        async let second = handle.cancel()

        #expect(try await first == .cancelled)
        #expect(try await second == .cancelled)
        #expect(await transport.recordedRequests(method: "account/login/cancel").count == 1)
    }

    @Test func unknownPendingLoginCancelOutcomeRequiresReconciliation() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueChatGPTLogin(
            loginID: "login-1",
            authenticationURL: URL(string: "https://chatgpt.com/auth")!
        )
        await transport.enqueueFailure(
            code: -32_000,
            message: "cancel response lost",
            for: "account/login/cancel"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let handle = try await harness.server.loginChatGPT()

        let outcome = try await handle.cancel(acknowledgementTimeout: .seconds(5))

        guard case .authenticationCommittedNeedsConnectionReconciliation(
            .cancelOutcomeUnknown(let failure)
        ) = outcome else {
            Issue.record("Expected an unknown pending cancel outcome to require reconciliation.")
            return
        }
        #expect(failure?.method == "account/login/cancel")
        #expect(try await handle.result() == outcome)

        try await transport.emitServerNotificationJSON(
            method: "account/login/completed",
            json: #"{"loginId":"login-1","success":true,"error":null}"#
        )
        try await transport.emitServerNotificationJSON(
            method: "account/updated",
            json: #"{"authMode":"chatgpt","planType":"plus"}"#
        )
        #expect(try await handle.result() == outcome)
    }

    @Test func pendingLoginConnectionFailureWhileCancellationIsInFlightRequiresReconciliation() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueChatGPTLogin(
            loginID: "login-1",
            authenticationURL: URL(string: "https://chatgpt.com/auth")!
        )
        await transport.enqueueFailure(
            code: -32_000,
            message: "cancel response lost",
            for: "account/login/cancel"
        )
        let cancelGate = CodexAppServerTestGate()
        await transport.holdNextIgnoringCancellation(
            method: "account/login/cancel",
            gate: cancelGate
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let handle = try await harness.server.loginChatGPT()
        let cancellation = Task {
            try await handle.cancel(acknowledgementTimeout: .seconds(5))
        }
        await transport.waitForRequest(method: "account/login/cancel")
        let result = Task { try await handle.result() }

        await transport.failConnection(.closed)
        let terminalResult = await result.result
        await cancelGate.open()
        let cancellationResult = await cancellation.result

        let expected = CodexLoginOutcome.authenticationCommittedNeedsConnectionReconciliation(
            .cancelOutcomeUnknown(nil)
        )
        switch terminalResult {
        case .success(let outcome):
            #expect(outcome == expected)
        case .failure(let error):
            Issue.record("Expected connection reconciliation, got terminal failure: \(error)")
        }
        switch cancellationResult {
        case .success(let outcome):
            #expect(outcome == expected)
        case .failure(let error):
            Issue.record("Expected shared cancellation reconciliation, got failure: \(error)")
        }
        await harness.close()
    }

    @Test func loginSuccessTerminalWinsOverLateCancelResponse() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueChatGPTLogin(
            loginID: "login-1",
            authenticationURL: URL(string: "https://chatgpt.com/auth")!
        )
        try await transport.enqueue(
            AppServerAPI.Account.Login.Cancel.Response(),
            for: "account/login/cancel"
        )
        let cancelGate = CodexAppServerTestGate()
        await transport.holdNextIgnoringCancellation(
            method: "account/login/cancel",
            gate: cancelGate
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let handle = try await harness.server.loginChatGPT()
        let cancellation = Task {
            try await handle.cancel(acknowledgementTimeout: .seconds(5))
        }
        await transport.waitForRequest(method: "account/login/cancel")

        try await transport.emitServerNotificationJSON(
            method: "account/login/completed",
            json: #"{"loginId":"login-1","success":true,"error":null}"#
        )
        try await transport.emitServerNotificationJSON(
            method: "account/updated",
            json: #"{"authMode":"chatgpt","planType":"plus"}"#
        )
        #expect(try await handle.result() == .succeeded)
        await cancelGate.open()

        #expect(try await cancellation.value == .succeeded)
    }

    @Test func loginFailureTerminalWinsOverLateCancelResponse() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueChatGPTLogin(
            loginID: "login-1",
            authenticationURL: URL(string: "https://chatgpt.com/auth")!
        )
        try await transport.enqueue(
            AppServerAPI.Account.Login.Cancel.Response(),
            for: "account/login/cancel"
        )
        let cancelGate = CodexAppServerTestGate()
        await transport.holdNextIgnoringCancellation(
            method: "account/login/cancel",
            gate: cancelGate
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let handle = try await harness.server.loginChatGPT()
        let cancellation = Task {
            try await handle.cancel(acknowledgementTimeout: .seconds(5))
        }
        await transport.waitForRequest(method: "account/login/cancel")

        try await transport.emitServerNotificationJSON(
            method: "account/login/completed",
            json: #"{"loginId":"login-1","success":false,"error":"denied"}"#
        )
        #expect(try await handle.result() == .failed(message: "denied"))
        await cancelGate.open()

        #expect(try await cancellation.value == .failed(message: "denied"))
    }

    @Test func cancellingLoginResultWaiterDoesNotCancelSharedLogin() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueChatGPTLogin(
            loginID: "login-1",
            authenticationURL: URL(string: "https://chatgpt.com/auth")!
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let handle = try await harness.server.loginChatGPT()
        let cancelledWaiter = Task { try await handle.result() }

        cancelledWaiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelledWaiter.value
        }
        try await transport.emitServerNotificationJSON(
            method: "account/login/completed",
            json: #"{"loginId":"login-1","success":true,"error":null}"#
        )
        try await transport.emitServerNotificationJSON(
            method: "account/updated",
            json: #"{"authMode":"chatgpt","planType":"plus"}"#
        )

        #expect(try await handle.result() == .succeeded)
        #expect(await transport.recordedRequests(method: "account/login/cancel").isEmpty)
    }

    @Test func stockChatGPTLoginReadinessDeadlineStartsAfterSuccess() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueChatGPTLogin(
            loginID: "login-1",
            authenticationURL: URL(string: "https://chatgpt.com/auth")!
        )
        let deadlineGate = CodexAppServerTestGate()
        let deadlineStarted = TestSignal()
        let harness = await CodexAppServerTestConnectionHarness.start(
            transport: transport,
            deadlineClock: .init { duration in
                #expect(duration == .seconds(5))
                deadlineStarted.signal()
                await deadlineGate.waitIgnoringCancellation()
            }
        )
        let handle = try await harness.server.loginChatGPT(accountReadinessTimeout: .seconds(5))
        let result = Task { try await handle.result() }

        try await transport.emitServerNotificationJSON(
            method: "account/login/completed",
            json: #"{"loginId":"login-1","success":true,"error":null}"#
        )
        await deadlineStarted.wait()
        await deadlineGate.open()

        #expect(
            try await result.value == .authenticationCommittedNeedsConnectionReconciliation(
                .accountReadinessDeadlineExceeded(.seconds(5))
            )
        )
    }

    @Test func malformedAccountUpdateAfterLoginSuccessRequiresReconciliation() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueChatGPTLogin(
            loginID: "login-1",
            authenticationURL: URL(string: "https://chatgpt.com/auth")!
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let handle = try await harness.server.loginChatGPT()

        try await transport.emitServerNotificationJSON(
            method: "account/login/completed",
            json: #"{"loginId":"login-1","success":true,"error":null}"#
        )
        try await transport.emitServerNotificationJSON(
            method: "account/updated",
            json: #"{"authMode":42}"#
        )

        guard case .authenticationCommittedNeedsConnectionReconciliation(
            .malformedAccountUpdateAfterSuccess(let malformed)
        ) = try await handle.result() else {
            Issue.record("Expected malformed post-success account update reconciliation.")
            return
        }
        #expect(malformed.method == "account/updated")
    }

    @Test func unknownCancelOutcomeAfterLoginSuccessRequiresReconciliation() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueueChatGPTLogin(
            loginID: "login-1",
            authenticationURL: URL(string: "https://chatgpt.com/auth")!
        )
        await transport.enqueueFailure(
            code: -32_000,
            message: "cancel response lost",
            for: "account/login/cancel"
        )
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let handle = try await harness.server.loginChatGPT()
        try await transport.emitServerNotificationJSON(
            method: "account/login/completed",
            json: #"{"loginId":"login-1","success":true,"error":null}"#
        )

        guard case .authenticationCommittedNeedsConnectionReconciliation(
            .cancelOutcomeUnknown(let failure)
        ) = try await handle.cancel(acknowledgementTimeout: .seconds(5)) else {
            Issue.record("Expected unknown post-success cancel reconciliation.")
            return
        }
        #expect(failure?.method == "account/login/cancel")
    }

    @Test func responseStreamCancelSendsTurnInterrupt() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router,
            connectionLease: harness.lease
        )

        let stream = try await thread.streamResponse(to: "Run the slow checks.")
        try await stream.cancel()

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

    @Test func threadCancelActiveTurnSendsExpectedTurnID() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router,
            connectionLease: harness.lease
        )

        let cancellation = try await thread.cancelActiveTurn(expectedTurnID: "turn-1")

        #expect(cancellation.threadID == "thread-1")
        #expect(cancellation.turnID == "turn-1")
        let request = try #require(await transport.recordedRequests().first)
        #expect(request.method == "turn/interrupt")
        let params = try request.decodeParams(AppServerAPI.Turn.Interrupt.Params.self)
        #expect(params.threadID == "thread-1")
        #expect(params.turnID == "turn-1")
    }

    @Test func responseStreamCancelRetriesWithCurrentActiveTurnID() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-old", status: "running")),
            for: "turn/start"
        )
        await transport.enqueueFailure(
            code: -32602,
            message: "expected active turn id turn-old but found turn-new",
            for: "turn/interrupt"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router,
            connectionLease: harness.lease
        )

        let stream = try await thread.streamResponse(to: "Run the slow checks.")
        let cancellation = try await stream.cancel()

        #expect(cancellation.threadID == "thread-1")
        #expect(cancellation.turnID == "turn-new")
        let cancelRequests = await transport.recordedRequests().filter {
            $0.method == "turn/interrupt"
        }
        let turnIDs = try cancelRequests.map { request in
            try request.decodeParams(AppServerAPI.Turn.Interrupt.Params.self).turnID
        }
        #expect(turnIDs == ["turn-old", "turn-new"])
    }

    @Test func responseStreamCancelRetriesUntilExpectedTurnIsActive() async throws {
        let transport = CodexAppServerTestTransport()
        try await transport.enqueue(
            AppServerAPI.Turn.Start.Response(turn: .init(id: "turn-1", status: "running")),
            for: "turn/start"
        )
        await transport.enqueueFailure(
            code: -32602,
            message: "no active turn to interrupt",
            for: "turn/interrupt"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let harness = await CodexAppServerTestConnectionHarness.start(
            transport: transport,
            deadlineClock: .init { _ in }
        )
        let client = harness.client
        let router = harness.router
        let thread = CodexThread(id: "thread-1", client: client, router: router, connectionLease: harness.lease)

        let stream = try await thread.streamResponse(to: "Run the slow checks.")
        let cancellation = try await stream.cancel()

        #expect(cancellation.threadID == "thread-1")
        #expect(cancellation.turnID == "turn-1")
        let turnIDs = try await transport.recordedRequests(method: "turn/interrupt").map {
            try $0.decodeParams(AppServerAPI.Turn.Interrupt.Params.self).turnID
        }
        #expect(turnIDs == ["turn-1", "turn-1"])
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
        let harness = await CodexAppServerTestConnectionHarness.start(transport: transport)
        let client = harness.client
        let router = harness.router
        let thread = CodexThread(
            id: "thread-1",
            client: client,
            router: router,
            connectionLease: harness.lease
        )

        let stream = try await thread.streamResponse(to: "Run the slow checks.")
        try await stream.steer(with: "Prefer the smallest fix.")

        #expect(await transport.recordedRequests(method: "turn/start").count == 1)
        let request = try #require(
            await transport.recordedRequests(method: "turn/steer").last
        )
        let params = try JSONDecoder().decode(
            AppServerAPI.Turn.Steer.Params.self, from: request.params)
        #expect(params.threadID == "thread-1")
        #expect(params.expectedTurnID == "turn-1")
        #expect(params.input == [.text("Prefer the smallest fix.")])
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

private struct ConfigBatchWriteParams: Decodable, Equatable {
    var edits: [Edit]
    var reloadUserConfig: Bool

    struct Edit: Decodable, Equatable {
        var keyPath: String
        var value: AppServerJSONValue
        var mergeStrategy: String

        init(
            keyPath: String,
            value: AppServerJSONValue,
            mergeStrategy: String = "replace"
        ) {
            self.keyPath = keyPath
            self.value = value
            self.mergeStrategy = mergeStrategy
        }
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

private struct LoginCompletedParams: Encodable, Sendable {
    var loginID: String?
    var success: Bool
    var error: String?

    enum CodingKeys: String, CodingKey {
        case loginID = "loginId"
        case success
        case error
    }

    init(loginID: String? = nil, success: Bool, error: String? = nil) {
        self.loginID = loginID
        self.success = success
        self.error = error
    }
}

private struct ReviewErrorParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var error: ErrorPayload
    var willRetry: Bool

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case error
        case willRetry
    }

    struct ErrorPayload: Encodable, Sendable {
        var message: String
    }
}

private struct TurnDeltaParams: Encodable, Sendable {
    var threadID: String = "thread-1"
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

private struct AgentMessageParams: Encodable, Sendable {
    var threadID: String = "thread-1"
    var turnID: String
    var itemID: String? = "message-1"
    var message: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case message
    }
}

private struct MessageDeltaWithoutItemIDParams: Encodable, Sendable {
    var threadID: String = "thread-1"
    var turnID: String
    var delta: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case delta
    }
}

private struct TurnStartedParams: Encodable, Sendable {
    var threadID: String
    var turn: AppServerAPI.Turn.Payload

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
    }

    init(threadID: String, turnID: String) {
        self.threadID = threadID
        self.turn = .init(id: turnID, status: "inProgress", items: [])
    }
}

private struct ItemOutputDeltaParams: Encodable, Sendable {
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

private struct ItemOutputDeltaWithoutItemIDParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var delta: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case delta
    }
}

private struct ItemPatchUpdatedParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var changes: AppServerJSONValue

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case changes
    }
}

private struct ItemProgressParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var message: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case message
    }
}

private struct TurnCompletedParams: Encodable, Sendable {
    var threadID: String
    var turn: AppServerAPI.Turn.Payload

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
    }

    init(threadID: String = "thread-1", turn: AppServerAPI.Turn.Payload) {
        self.threadID = threadID
        var turn = turn
        turn.items = turn.items ?? []
        self.turn = turn
    }
}

private struct ThreadItemParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var item: Item
    var startedAtMS: Int64 = 0
    var completedAtMS: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case item
        case startedAtMS = "startedAtMs"
        case completedAtMS = "completedAtMs"
    }

    struct Item: Encodable, Sendable {
        var id: String
        var type: String
        var text: String?
        var phase: String?
        var command: String?
        var aggregatedOutput: String?
        var status: String?
        var path: String?
        var tool: String?
        var summary: [String]?
        var content: [String]?
        var contentItems: [TextContent]?
        var changes: AppServerJSONValue?

        init(
            id: String,
            type: String,
            text: String? = nil,
            phase: String? = nil,
            command: String? = nil,
            aggregatedOutput: String? = nil,
            status: String? = nil,
            path: String? = nil,
            tool: String? = nil,
            summary: [String]? = nil,
            content: [String]? = nil,
            contentItems: [TextContent]? = nil,
            changes: AppServerJSONValue? = nil
        ) {
            self.id = id
            self.type = type
            self.text = text
            self.phase = phase
            self.command = command
            self.aggregatedOutput = aggregatedOutput
            self.status = status
            self.path = path
            self.tool = tool
            self.summary = summary
            self.content = content
            self.contentItems = contentItems
            self.changes = changes
        }

        enum CodingKeys: String, CodingKey {
            case id
            case type
            case text
            case phase
            case command
            case aggregatedOutput
            case status
            case path
            case tool
            case summary
            case content
            case changes
            case cwd
            case commandActions
            case server
            case arguments
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(type, forKey: .type)
            try container.encodeIfPresent(text, forKey: .text)
            try container.encodeIfPresent(phase, forKey: .phase)
            try container.encodeIfPresent(command, forKey: .command)
            try container.encodeIfPresent(aggregatedOutput, forKey: .aggregatedOutput)
            try container.encodeIfPresent(status, forKey: .status)
            try container.encodeIfPresent(path, forKey: .path)
            try container.encodeIfPresent(tool, forKey: .tool)
            try container.encodeIfPresent(summary, forKey: .summary)
            try container.encodeIfPresent(changes, forKey: .changes)
            if type == "commandExecution" {
                try container.encode("/workspace", forKey: .cwd)
                try container.encode([String](), forKey: .commandActions)
            }
            if type == "mcpToolCall" {
                try container.encode("server", forKey: .server)
                try container.encode(AppServerJSONValue.object([:]), forKey: .arguments)
            }
            if type == "fileChange", changes == nil {
                try container.encode(AppServerJSONValue.array([]), forKey: .changes)
            }
            if let contentItems {
                try container.encode(contentItems, forKey: .content)
            } else {
                try container.encodeIfPresent(content, forKey: .content)
            }
        }

        struct TextContent: Encodable, Sendable {
            var type = "text"
            var text: String
        }
    }
}

private struct ThreadItemWithoutIDParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var item: Item

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case item
    }

    struct Item: Encodable, Sendable {
        var type: String
        var text: String?
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
        var last: Breakdown
        var total: Breakdown
        var modelContextWindow: Int?

        init(total: Breakdown, modelContextWindow: Int? = nil) {
            self.last = total
            self.total = total
            self.modelContextWindow = modelContextWindow
        }
    }

    struct Breakdown: Encodable, Sendable {
        var cachedInputTokens: Int = 0
        var inputTokens: Int
        var outputTokens: Int
        var reasoningOutputTokens: Int = 0
        var totalTokens: Int
    }
}

private actor CancellationRecorder {
    private var cancellations: [CodexTurnCancellation] = []

    func append(_ cancellation: CodexTurnCancellation) {
        cancellations.append(cancellation)
    }

    func values() -> [CodexTurnCancellation] {
        cancellations
    }
}

private actor ServerRequestRecorder {
    private var recordedRequests: [CodexAppServerRequest] = []

    func append(_ request: CodexAppServerRequest) {
        recordedRequests.append(request)
    }

    func requests() -> [CodexAppServerRequest] {
        recordedRequests
    }
}

private final class TestPreWriteSuspendingTransport: JSONRPC.Transport, Sendable {
    let connectionEventHub = ConnectionEventHub()
    private let response: Data
    private let sendEntered = TestSignal()
    private let writeAcceptanceGate = CodexAppServerTestGate()
    private let requestCount = Mutex(0)

    init(response: Data) {
        self.response = response
    }

    func send(
        _ request: JSONRPC.Request,
        acceptWrite: @Sendable () throws -> Void
    ) async throws -> Data {
        sendEntered.signal()
        await writeAcceptanceGate.waitIgnoringCancellation()
        try acceptWrite()
        requestCount.withLock { $0 += 1 }
        return response
    }

    func waitUntilSendEntered() async {
        await sendEntered.wait()
    }

    func allowWriteAcceptance() async {
        await writeAcceptanceGate.open()
    }

    func wireRequestCount() -> Int {
        requestCount.withLock { $0 }
    }

    func notify(_ notification: JSONRPC.Notification) async throws {}

    func nextInboundEvent() async throws -> JSONRPC.InboundEvent? { nil }

    func respond(
        to requestID: CodexServerRequestID,
        with response: CodexServerRequestResponse
    ) async throws {}

    func beginClose() async -> JSONRPC.ProcessExitObservation? {
        await writeAcceptanceGate.open()
        return nil
    }

    func finishPendingResponsesAfterInboundDrain(_ failure: CodexTransportFailure) async {}

    func waitForProcessExit() async -> JSONRPC.ProcessExitObservation { .unavailable }

    func waitUntilClosed() async {}

    func reapProcess() async {}
}

private final class TestOutboundWriteFailureTransport: JSONRPC.Transport, Sendable {
    let connectionEventHub = ConnectionEventHub()
    private let failure: CodexTransportFailure
    private let inboundGate = CodexAppServerTestGate()

    init(failure: CodexTransportFailure) {
        self.failure = failure
    }

    func send(
        _ request: JSONRPC.Request,
        acceptWrite: @Sendable () throws -> Void
    ) async throws -> Data {
        try acceptWrite()
        throw JSONRPC.OutboundWriteFailure(failure)
    }

    func notify(_ notification: JSONRPC.Notification) async throws {}
    func nextInboundEvent() async throws -> JSONRPC.InboundEvent? {
        await inboundGate.waitIgnoringCancellation()
        return nil
    }
    func respond(
        to requestID: CodexServerRequestID,
        with response: CodexServerRequestResponse
    ) async throws {}
    func beginClose() async -> JSONRPC.ProcessExitObservation? {
        await inboundGate.open()
        return nil
    }
    func finishPendingResponsesAfterInboundDrain(_ failure: CodexTransportFailure) async {}
    func waitForProcessExit() async -> JSONRPC.ProcessExitObservation { .unavailable }
    func waitUntilClosed() async {}
    func reapProcess() async {}
}

private final class TestSuspendingTransport: JSONRPC.Transport, Sendable {
    let connectionEventHub = ConnectionEventHub()
    let response: Data
    private let started = TestSignal()
    private let cancelled: TestSignal
    private let suspension: TestCancellationWaiter

    init(response: Data) {
        self.response = response
        let cancelled = TestSignal()
        self.cancelled = cancelled
        self.suspension = TestCancellationWaiter {
            cancelled.signal()
        }
    }

    func send(
        _ request: JSONRPC.Request,
        acceptWrite: @Sendable () throws -> Void
    ) async throws -> Data {
        try acceptWrite()
        started.signal()
        try await suspension.wait()
        return response
    }

    func waitUntilStarted() async {
        await started.wait()
    }

    func waitUntilCancelled() async {
        await cancelled.wait()
    }

    func notify(_ notification: JSONRPC.Notification) async throws {}

    func nextInboundEvent() async throws -> JSONRPC.InboundEvent? { nil }

    func respond(
        to requestID: CodexServerRequestID,
        with response: CodexServerRequestResponse
    ) async throws {}

    func beginClose() async -> JSONRPC.ProcessExitObservation? {
        suspension.cancel()
        return nil
    }

    func finishPendingResponsesAfterInboundDrain(_ failure: CodexTransportFailure) async {}

    func waitForProcessExit() async -> JSONRPC.ProcessExitObservation { .unavailable }

    func waitUntilClosed() async {}

    func reapProcess() async {}
}

private final class TestSignal: Sendable {
    private struct State {
        var isSignalled = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = Mutex(State())

    func wait() async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResume = state.withLock { state in
                    if state.isSignalled || Task.isCancelled {
                        return true
                    }
                    state.waiters[waiterID] = continuation
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                state.waiters.removeValue(forKey: waiterID)
            }
            waiter?.resume()
        }
    }

    func signal() {
        let waiters = state.withLock { state in
            state.isSignalled = true
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll(keepingCapacity: false)
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private final class TestCancellationWaiter: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Never>?
        var isCancelled = false
    }

    private let state = Mutex(State())
    private let onCancel: @Sendable () -> Void

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    func wait() async throws {
        try Task.checkCancellation()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResume = state.withLock { state in
                    if state.isCancelled {
                        return true
                    }
                    precondition(state.continuation == nil)
                    state.continuation = continuation
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            cancel()
        }
        try Task.checkCancellation()
    }

    func cancel() {
        onCancel()
        let continuation = state.withLock { state in
            state.isCancelled = true
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private func firstConnectionTermination(
    in events: CodexConnectionEvents
) async -> CodexConnectionTermination? {
    var iterator = events.makeAsyncIterator()
    while let event = await iterator.next() {
        if case .terminated(let termination) = event {
            return termination
        }
    }
    return nil
}

private func emitItemStarted(
    on transport: CodexAppServerTestTransport,
    threadID: String,
    turnID: String,
    item: ThreadItemParams.Item
) async throws {
    try await transport.emitServerNotification(
        method: "item/started",
        params: ThreadItemParams(threadID: threadID, turnID: turnID, item: item)
    )
}

private extension Array where Element == CodexThreadEvent {
    func containsThreadText(_ text: String, turnID expectedTurnID: CodexTurnID) -> Bool {
        contains { event in
            switch event {
            case .snapshot(let snapshot):
                snapshot.id == expectedTurnID && snapshot.items.contains { $0.text == text }
            case .itemStarted(let item, let turnID),
                 .itemUpdated(let item, let turnID),
                 .itemCompleted(let item, let turnID):
                turnID == expectedTurnID && item.text == text
            case .message(let message, let turnID):
                turnID == expectedTurnID && message.text == text
            case .messageDelta(let delta, let turnID):
                turnID == expectedTurnID && delta.text == text
            case .turnStarted, .terminal, .reasoningSummaryPartAdded, .reasoningDelta,
                 .diagnostic, .tokenUsageUpdated, .statusChanged, .closed, .unknown:
                false
            }
        }
    }
}

private func eventually(
    attempts: Int = 50,
    _ condition: () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

private func testConnectionCloseAction(
    for transport: any JSONRPC.Transport
) -> ConnectionCloseAction {
    ConnectionCloseAction(action: {
        _ = await transport.beginClose()
    })
}

private enum TestTimeoutError: Error {
    case timedOut
}

private func prepareRestartToken(
    runtime: CodexAppServerTestRuntime,
    identity: CodexReviewIdentity
) async throws -> CodexReviewRestartToken {
    try await runtime.transport.enqueueThreadResume(.init(id: identity.activeTurnThreadID))
    try await runtime.transport.enqueueEmpty(for: "turn/interrupt")
    let expectedInterruptRequestCount = await runtime.transport
        .recordedRequests(method: "turn/interrupt").count + 1
    let prepareTask = Task {
        try await runtime.server.prepareReviewRestart(identity)
    }
    defer {
        prepareTask.cancel()
    }
    await runtime.transport.waitForRequest(
        method: "turn/interrupt",
        count: expectedInterruptRequestCount
    )
    try await runtime.transport.emitServerNotification(
        method: "turn/completed",
        params: TurnCompletedParams(
            threadID: identity.activeTurnThreadID.rawValue,
            turn: .init(id: identity.turnID.rawValue, status: "interrupted")
        )
    )
    return try await prepareTask.value
}

private func withTimeout<Value: Sendable>(
    _ timeout: Duration = .seconds(1),
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TestTimeoutError.timedOut
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}
