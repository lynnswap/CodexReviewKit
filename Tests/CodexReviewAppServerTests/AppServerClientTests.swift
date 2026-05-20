import Darwin
import Foundation
import Testing
@testable import CodexReviewAppServer
import CodexReview
import CodexReviewTesting

@Suite("app-server client")
struct AppServerClientTests {
    @Test func processTransportConfigurationResolvesCodexFromProvidedPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let codex = directory.appending(path: "codex")
        try Data("#!/bin/sh\n".utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        let configuration = AppServerProcessTransport.Configuration(
            environment: ["PATH": directory.path, "HOME": "/tmp/review-home"]
        )

        #expect(configuration.executable == codex.path)
        #expect(configuration.arguments == CodexAppServerExecutable.appServerArguments())
        #expect(configuration.arguments.contains(#"cli_auth_credentials_store="file""#))
    }

    @Test func processTransportSearchesCodexAppBundleResourcesFallback() throws {
        let directories = CodexAppServerExecutable.pathSearchDirectories(
            environment: ["PATH": "/tmp/codex-bin:/usr/bin"]
        )

        #expect(directories.contains("/Applications/Codex.app/Contents/Resources"))
        #expect(directories.filter { $0 == "/usr/bin" }.count == 1)
        let appBundleIndex = try #require(directories.firstIndex(of: "/Applications/Codex.app/Contents/Resources"))
        let homebrewIndex = try #require(directories.firstIndex(of: "/opt/homebrew/bin"))
        #expect(appBundleIndex < homebrewIndex)
    }

    @Test func processTransportConfigurationUsesDedicatedCodexHome() throws {
        let configuration = AppServerProcessTransport.Configuration(
            environment: ["PATH": "/usr/bin", "HOME": "/tmp/review-home"]
        )

        #expect(configuration.codexHomeURL.path == "/tmp/review-home/.codex_review")
        #expect(configuration.environment["CODEX_HOME"] == "/tmp/review-home/.codex_review")
    }

    @Test func processTransportConfigurationUsesExplicitCodexHome() throws {
        let configuration = AppServerProcessTransport.Configuration(
            environment: [
                "PATH": "/usr/bin",
                "HOME": "/tmp/review-home",
                "CODEX_HOME": "/tmp/custom-codex-review",
            ]
        )

        #expect(configuration.codexHomeURL.path == "/tmp/custom-codex-review")
        #expect(configuration.environment["CODEX_HOME"] == "/tmp/custom-codex-review")
    }

    @Test func processTransportCloseTerminatesSpawnedProcessGroup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-process-group-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let executable = directory.appending(path: "app-server-stub.sh")
        let childPIDFile = directory.appending(path: "child.pid")
        let readyFile = directory.appending(path: "ready")
        let script = """
        #!/bin/sh
        child_pid_file="$1"
        ready_file="$2"
        (
          while true; do sleep 1; done
        ) &
        echo $! > "$child_pid_file"
        touch "$ready_file"
        while true; do sleep 1; done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let transport = try AppServerProcessTransport(configuration: .init(
            executable: executable.path,
            arguments: [childPIDFile.path, readyFile.path],
            environment: [
                "HOME": directory.path,
                "PATH": "/bin:/usr/bin",
            ]
        ))
        let becameReady = await waitUntil(timeout: .seconds(2)) {
            FileManager.default.fileExists(atPath: readyFile.path)
        }
        #expect(becameReady)

        let childPIDText = try String(contentsOf: childPIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try #require(pid_t(childPIDText))
        defer {
            _ = Darwin.kill(childPID, SIGKILL)
        }
        #expect(Darwin.kill(childPID, 0) == 0)

        await transport.close()

        let childExited = await waitUntil(timeout: .seconds(2)) {
            Darwin.kill(childPID, 0) != 0 && errno == ESRCH
        }
        #expect(childExited)

        let notifications = await transport.notificationStream()
        var iterator = notifications.makeAsyncIterator()
        await #expect(throws: (any Error).self) {
            _ = try await iterator.next()
        }
    }

    @Test func processTransportProcessesChunkedStdoutBeforeEOF() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-stdout-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let executable = directory.appending(path: "app-server-stub.sh")
        let script = """
        #!/bin/sh
        IFS= read -r request
        printf '{"jsonrpc":"2.0","id":1,"result":{"value":'
        sleep 0.05
        printf '"done"}}\\n'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let transport = try AppServerProcessTransport(configuration: .init(
            executable: executable.path,
            arguments: [],
            environment: [
                "HOME": directory.path,
                "PATH": "/bin:/usr/bin",
            ]
        ))

        let data = try await transport.send(JSONRPCRequest(
            id: 1,
            method: "test/request",
            params: Data("{}".utf8)
        ))
        await transport.close()

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["value"] as? String == "done")
    }

    @Test func processTransportMapsNullJSONRPCResultToEmptyPayload() throws {
        let data = try AppServerProcessTransport.responsePayloadData(from: NSNull())

        #expect(String(decoding: data, as: UTF8.self) == "{}")
        #expect(try JSONDecoder().decode(EmptyResponse.self, from: data) == EmptyResponse())
    }

    @Test func appServerTurnErrorRequiresMessage() throws {
        let valid = Data(#"{"id":"turn-1","error":{"message":"cancelled"}}"#.utf8)
        let turn = try JSONDecoder().decode(AppServerTurn.self, from: valid)
        #expect(turn.error?.message == "cancelled")

        let missingMessage = Data(#"{"id":"turn-1","error":{}}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AppServerTurn.self, from: missingMessage)
        }
    }

    @Test func processTransportBuildsErrorResponseForUnsupportedServerRequests() throws {
        let data = try AppServerProcessTransport.unsupportedServerRequestPayload(
            id: 42,
            method: "approval/request"
        )
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])

        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["id"] as? Int == 42)
        #expect(error["code"] as? Int == -32601)
        #expect(error["message"] as? String == "Unsupported app-server request: approval/request")
        #expect(String(decoding: data, as: UTF8.self).hasSuffix("\n"))
    }

    @Test func sameThreadReviewRequestsDoNotOverlap() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1"), for: "review/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-2"), for: "review/start")
        let gate = AsyncGate()
        await transport.hold(method: "review/start", gate: gate)
        let client = AppServerClient(transport: transport)

        async let first: ReviewStartResponse = client.send(ReviewStartRequest(
            params: .init(threadID: "thread-1", target: .uncommittedChanges)
        ))
        async let second: ReviewStartResponse = client.send(ReviewStartRequest(
            params: .init(threadID: "thread-1", target: .uncommittedChanges)
        ))
        await transport.waitForRequestCount(1)
        await gate.open()
        _ = try await (first, second)

        #expect(await transport.maxActiveCount(for: "review/start") == 1)
    }

    @Test func differentThreadReviewRequestsCanOverlap() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1"), for: "review/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-2"), for: "review/start")
        let gate = AsyncGate()
        await transport.hold(method: "review/start", gate: gate)
        let client = AppServerClient(transport: transport)

        async let first: ReviewStartResponse = client.send(ReviewStartRequest(
            params: .init(threadID: "thread-1", target: .uncommittedChanges)
        ))
        async let second: ReviewStartResponse = client.send(ReviewStartRequest(
            params: .init(threadID: "thread-2", target: .uncommittedChanges)
        ))
        await transport.waitForRequestCount(2)
        await gate.open()
        _ = try await (first, second)

        #expect(await transport.maxActiveCount(for: "review/start") == 2)
    }

    @Test func startupInterruptUsesEmptyTurnID() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let client = AppServerClient(transport: transport)
        let control = AppServerReviewControl(client: client)

        await control.recordThreadStarted(threadID: "thread-1")
        #expect(try await control.interrupt())

        let request = try #require(await transport.recordedRequests().last)
        #expect(request.method == "turn/interrupt")
        let params = try JSONDecoder().decode(TurnInterruptParams.self, from: request.params)
        #expect(params.threadID == "thread-1")
        #expect(params.turnID == "")
    }

    @Test func runningInterruptUsesActualTurnID() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let client = AppServerClient(transport: transport)
        let control = AppServerReviewControl(client: client)

        await control.recordReviewStarted(threadID: "thread-1", turnID: "turn-1")
        #expect(try await control.interrupt())

        let request = try #require(await transport.recordedRequests().last)
        let params = try JSONDecoder().decode(TurnInterruptParams.self, from: request.params)
        #expect(params.turnID == "turn-1")
    }

    @Test func runningInterruptRetriesWithCurrentActiveTurnID() async throws {
        let transport = FakeJSONRPCTransport()
        await transport.enqueueFailure(
            .responseError(
                code: -32602,
                message: "expected active turn id turn-old but found turn-new"
            ),
            for: "turn/interrupt"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let client = AppServerClient(transport: transport)
        let control = AppServerReviewControl(client: client)

        await control.recordReviewStarted(threadID: "thread-1", turnID: "turn-old")
        #expect(try await control.interrupt())

        let requests = await transport.recordedRequests()
        #expect(requests.map(\.method) == ["turn/interrupt", "turn/interrupt"])
        let first = try JSONDecoder().decode(TurnInterruptParams.self, from: requests[0].params)
        let second = try JSONDecoder().decode(TurnInterruptParams.self, from: requests[1].params)
        #expect(first.turnID == "turn-old")
        #expect(second.turnID == "turn-new")
    }

    @Test func initializeSendsInitializedNotificationOnce() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(InitializeResponse(codexHome: "/tmp/codex"), for: "initialize")
        let client = AppServerClient(transport: transport)

        let response = try await client.initialize()
        _ = try await client.initialize()

        #expect(response.codexHome == "/tmp/codex")
        #expect(await transport.recordedRequests().map(\.method) == ["initialize"])
        #expect(await transport.recordedNotifications().map(\.method) == ["initialized"])
        let request = try #require(await transport.recordedRequests().first)
        let params = try #require(JSONSerialization.jsonObject(with: request.params) as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])
        #expect(clientInfo["name"] as? String == "CodexReviewKit")
        #expect(clientInfo["version"] as? String == "2")
        let capabilities = try #require(params["capabilities"] as? [String: Any])
        #expect(capabilities["experimentalApi"] as? Bool == true)
    }

    @Test func concurrentInitializeCallsShareSingleHandshake() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(InitializeResponse(codexHome: "/tmp/codex"), for: "initialize")
        let gate = AsyncGate()
        await transport.hold(method: "initialize", gate: gate)
        let client = AppServerClient(transport: transport)

        async let first = client.initialize()
        async let second = client.initialize()
        await transport.waitForRequestCount(1)
        await gate.open()
        let responses = try await (first, second)

        #expect(responses.0.codexHome == "/tmp/codex")
        #expect(responses.1.codexHome == "/tmp/codex")
        #expect(await transport.recordedRequests().map(\.method) == ["initialize"])
        #expect(await transport.recordedNotifications().map(\.method) == ["initialized"])
    }

    @Test func accountReadResponseDecodesCodexOpenAIAuthKey() throws {
        let data = Data("""
        {"account":{"type":"chatgpt","email":"review@example.com","planType":"pro"},"requiresOpenaiAuth":true}
        """.utf8)
        let response = try JSONDecoder().decode(AccountReadResponse.self, from: data)

        #expect(response.requiresOpenAIAuth)
    }

    @Test func accountRateLimitsResponseResolvesCodexLimitWindows() throws {
        let data = Data("""
        {
          "rateLimits": {
            "limitId": "codex_bengalfox",
            "primary": {"usedPercent": 0, "windowDurationMins": 300, "resetsAt": 1779183121},
            "secondary": {"usedPercent": 0, "windowDurationMins": 10080, "resetsAt": 1779769921},
            "planType": "pro"
          },
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": {"usedPercent": 0, "windowDurationMins": 300, "resetsAt": 1779176539},
              "secondary": {"usedPercent": 11, "windowDurationMins": 10080, "resetsAt": 1779571734},
              "planType": "pro"
            }
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(AppServerAccountRateLimitsResponse.self, from: data)

        #expect(response.codexPlanType == "pro")
        #expect(response.codexRateLimitWindows.map(\.windowDurationMinutes) == [300, 10080])
        #expect(response.codexRateLimitWindows.map(\.usedPercent) == [0, 11])
        #expect(response.codexRateLimitWindows.first?.resetsAt == Date(timeIntervalSince1970: 1_779_176_539))
    }

    @Test func accountRateLimitsResponseFallsBackToCodexPrefixedTopLevelLimit() throws {
        let data = Data("""
        {
          "rateLimits": {
            "limitId": "codex_bengalfox",
            "primary": {"usedPercent": 17, "windowDurationMins": 300},
            "planType": "pro"
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(AppServerAccountRateLimitsResponse.self, from: data)

        #expect(response.codexPlanType == "pro")
        #expect(response.codexRateLimitWindows.map(\.windowDurationMinutes) == [300])
        #expect(response.codexRateLimitWindows.map(\.usedPercent) == [17])
    }

    @Test func loginStartRequestsNativeAuthenticationWhenConfigured() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            LoginAccountResponse.chatgpt(
                loginID: "login-1",
                authURL: "https://example.com/auth",
                nativeWebAuthentication: .init(callbackURLScheme: "lynnpd.ReviewMonitor.auth")
            ),
            for: "account/login/start"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let challenge = try await backend.startLogin(.init(
            nativeWebAuthenticationCallbackScheme: "lynnpd.ReviewMonitor.auth"
        ))

        #expect(challenge.id == "login-1")
        #expect(challenge.verificationURL == URL(string: "https://example.com/auth"))
        #expect(challenge.nativeWebAuthenticationCallbackScheme == "lynnpd.ReviewMonitor.auth")
        let request = try #require(await transport.recordedRequests().last)
        #expect(request.method == "account/login/start")
        let params = try JSONDecoder().decode(LoginAccountParams.self, from: request.params)
        #expect(params.nativeWebAuthentication?.callbackURLScheme == "lynnpd.ReviewMonitor.auth")
    }

    @Test func loginStartPreservesDeviceCodeUserCode() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            LoginAccountResponse.chatgptDeviceCode(
                loginID: "login-1",
                verificationURL: "https://example.com/device",
                userCode: "ABCD-EFGH"
            ),
            for: "account/login/start"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let challenge = try await backend.startLogin(.init())

        #expect(challenge.id == "login-1")
        #expect(challenge.verificationURL == URL(string: "https://example.com/device"))
        #expect(challenge.userCode == "ABCD-EFGH")
    }

    @Test func loginStartRejectsInvalidAuthenticationURL() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            LoginAccountResponse.chatgpt(
                loginID: "login-1",
                authURL: "file:///tmp/auth",
                nativeWebAuthentication: nil
            ),
            for: "account/login/start"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        await #expect(throws: (any Error).self) {
            _ = try await backend.startLogin(.init())
        }
    }

    @Test func settingsReadLoadsConfigAndModelCatalog() async throws {
        let modelList = Data("""
        {
          "data": [
            {
              "id": "gpt-5.5",
              "model": "gpt-5.5",
              "displayName": "GPT-5.5",
              "hidden": false,
              "supportedReasoningEfforts": [
                {"reasoningEffort": "medium", "description": "Balanced"},
                {"reasoningEffort": "xhigh", "description": "Extra high"}
              ],
              "defaultReasoningEffort": "xhigh",
              "serviceTiers": [{"id": "fast"}, {"id": "flex"}],
              "isDefault": true
            }
          ]
        }
        """.utf8)
        let transport = FakeJSONRPCTransport(responses: [
            "model/list": [modelList],
        ])
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            ConfigReadResponse(config: .init(
                model: "gpt-5",
                reviewModel: "gpt-5.5",
                modelReasoningEffort: "medium",
                serviceTier: "flex"
            )),
            for: "config/read"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let settings = try await backend.readSettings()

        #expect(settings.model == "gpt-5.5")
        #expect(settings.fallbackModel == "gpt-5")
        #expect(settings.reasoningEffort == "medium")
        #expect(settings.serviceTier == "flex")
        #expect(settings.models.map(\.model) == ["gpt-5.5"])
        #expect(settings.models.first?.supportedServiceTiers == [.fast, .flex])
        #expect(settings.models.first?.isDefault == true)
    }

    @Test func settingsReadUsesGlobalModelAsFallbackWhenReviewModelIsUnset() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5", reviewModel: nil)),
            for: "config/read"
        )
        try await transport.enqueue(
            ModelListResponse(data: [makeModelCatalogItem(model: "default-model", isDefault: true)]),
            for: "model/list"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let settings = try await backend.readSettings()

        #expect(settings.model == nil)
        #expect(settings.fallbackModel == "gpt-5")
    }

    @Test func settingsReadPagesThroughModelCatalog() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(
            ConfigReadResponse(config: .init(model: nil, reviewModel: nil)),
            for: "config/read"
        )
        try await transport.enqueue(
            ModelListResponse(
                data: [makeModelCatalogItem(model: "first-model")],
                nextCursor: "page-2"
            ),
            for: "model/list"
        )
        try await transport.enqueue(
            ModelListResponse(
                data: [makeModelCatalogItem(model: "default-model", isDefault: true)]
            ),
            for: "model/list"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let settings = try await backend.readSettings()

        #expect(settings.fallbackModel == "default-model")
        #expect(settings.models.map(\.model) == ["first-model", "default-model"])
        let modelRequests = await transport.recordedRequests().filter { $0.method == "model/list" }
        #expect(modelRequests.count == 2)
        let firstParams = try JSONDecoder().decode(ModelListParams.self, from: modelRequests[0].params)
        let secondParams = try JSONDecoder().decode(ModelListParams.self, from: modelRequests[1].params)
        #expect(firstParams.cursor == nil)
        #expect(firstParams.includeHidden == true)
        #expect(secondParams.cursor == "page-2")
        #expect(secondParams.includeHidden == true)
    }

    @Test func reviewTargetEncodesAppServerTaggedShape() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1"), for: "review/start")
        let client = AppServerClient(transport: transport)

        let _: ReviewStartResponse = try await client.send(ReviewStartRequest(
            params: .init(threadID: "thread-1", target: .baseBranch("main"))
        ))

        let request = try #require(await transport.recordedRequests().last)
        let object = try #require(JSONSerialization.jsonObject(with: request.params) as? [String: Any])
        let target = try #require(object["target"] as? [String: Any])
        #expect(target["type"] as? String == "baseBranch")
        #expect(target["branch"] as? String == "main")
        #expect(target["_0"] == nil)
        #expect(object["delivery"] as? String == "inline")
    }

    @Test func backendStartsEphemeralReviewThreads() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        _ = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))

        let threadStart = try #require(await transport.recordedRequests().first { $0.method == "thread/start" })
        let params = try JSONDecoder().decode(ThreadStartParams.self, from: threadStart.params)
        #expect(params.ephemeral == true)
        #expect(params.approvalPolicy == "never")
        #expect(params.sandbox == "danger-full-access")
    }

    @Test func backendAppliesRequestedReviewModelToThreadStartAndRunMetadata() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            model: "gpt-5.5"
        ))

        let threadStart = try #require(await transport.recordedRequests().first { $0.method == "thread/start" })
        let params = try JSONDecoder().decode(ThreadStartParams.self, from: threadStart.params)
        #expect(params.model == "gpt-5.5")
        #expect(run.model == "gpt-5.5")
    }

    @Test func appServerStartupResponsesDecodeNestedThreadAndTurnObjects() async throws {
        let threadStart = """
        {"thread":{"id":"thread-1"},"model":"gpt-5","modelProvider":"openai","serviceTier":null}
        """
        let reviewStart = """
        {"turn":{"id":"turn-1","items":[],"itemsView":"notLoaded","status":"inProgress","error":null,"startedAt":null,"completedAt":null,"durationMs":null},"reviewThreadId":"thread-1"}
        """
        let transport = FakeJSONRPCTransport(responses: [
            "initialize": [try JSONEncoder().encode(InitializeResponse())],
            "thread/start": [Data(threadStart.utf8)],
            "review/start": [Data(reviewStart.utf8)],
        ])
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))

        #expect(run.threadID == "thread-1")
        #expect(run.turnID == "turn-1")
        #expect(run.model == "gpt-5")
    }

    @Test func backendKeepsParentThreadIDForDetachedReviewThread() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "parent-thread", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-old", reviewThreadID: "review-thread"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await backend.events(for: run)

        #expect(run.threadID == "parent-thread")
        #expect(run.reviewThreadID == "review-thread")

        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(
                threadID: "parent-thread",
                turn: .init(id: "turn-new"),
                reviewThreadID: "review-thread"
            )
        )
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-new", reviewThreadID: "review-thread", model: nil))

        try await backend.interruptReview(run, reason: .init())

        let request = try #require(await transport.recordedRequests().last)
        let params = try JSONDecoder().decode(TurnInterruptParams.self, from: request.params)
        #expect(params.threadID == "parent-thread")
        #expect(params.turnID == "turn-new")
    }

    @Test func backendPreservesDetachedReviewThreadIDWhenStartedNotificationOmitsIt() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "parent-thread", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-old", reviewThreadID: "review-thread"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await backend.events(for: run)

        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "parent-thread", turn: .init(id: "turn-new"))
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-new", reviewThreadID: "review-thread", model: nil))
    }

    @Test func backendBuffersTerminalNotificationEmittedDuringReviewStart() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let gate = AsyncGate()
        await transport.hold(method: "review/start", gate: gate)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        async let started = backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        await transport.waitForRequestCount(3)
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-1", status: "completed"))
        )
        await gate.open()
        let run = try await started

        var iterator = await backend.events(for: run).makeAsyncIterator()
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: nil))
    }

    @Test func backendBuffersCancellationBeforeEventStreamRegistration() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))

        try await backend.interruptReview(run, reason: .init(message: "Stop"))

        var iterator = await backend.events(for: run).makeAsyncIterator()
        #expect(try await iterator.next() == .cancelled("Stop"))
        #expect(try await iterator.next() == nil)
    }

    @Test func backendTracksActualStartedTurnAndStreamsReviewItems() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-response", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await backend.events(for: run)

        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-new"))
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TestDeltaNotification(threadID: "thread-1", turnID: "turn-new", itemID: "message-1", delta: " hello")
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-new", status: "completed"))
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-new", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .messageDelta(" hello", itemID: "message-1"))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: nil))
    }

    @Test func backendIgnoresTerminalNotificationFromStaleObservedTurn() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-old", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await backend.events(for: run)

        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-new"))
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "thread-1",
                turn: .init(id: "turn-stale", status: "failed", error: .init(message: "Old turn failed"))
            )
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TestDeltaNotification(threadID: "thread-1", turnID: "turn-new", itemID: "message-1", delta: " current")
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-new", status: "completed"))
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-new", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .messageDelta(" current", itemID: "message-1"))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: nil))
    }

    @Test func backendIgnoresNonTerminalNotificationFromStaleObservedTurn() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-response", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await backend.events(for: run)

        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-new"))
        )
        try await transport.emitServerNotification(
            method: "error",
            params: TestErrorNotification(
                threadID: "thread-1",
                turnID: "turn-stale",
                message: "Retrying stale turn",
                willRetry: true
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-new", status: "completed"))
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-new", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: nil))
    }

    @Test func backendFailsWhenReviewThreadBecomesNotLoaded() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await backend.events(for: run)

        try await transport.emitServerNotification(
            method: "thread/status/changed",
            params: TestThreadStatusNotification(threadID: "thread-1", status: .init(type: "notLoaded"))
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .failed("Review thread is no longer loaded."))
        #expect(try await iterator.next() == nil)
    }

    @Test func backendFailsWhenReviewThreadCloses() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await backend.events(for: run)

        try await transport.emitServerNotification(
            method: "thread/closed",
            params: TestThreadClosedNotification(threadID: "thread-1")
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .failed("Review thread closed."))
        #expect(try await iterator.next() == nil)
    }

    @Test func backendInterruptFinishesReviewEventStream() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await backend.events(for: run)
        var iterator = events.makeAsyncIterator()
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-1"))
        )

        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))

        try await backend.interruptReview(run, reason: .init(message: "Stop"))

        #expect(try await iterator.next() == .cancelled("Stop"))
        #expect(try await iterator.next() == nil)
    }

    @Test func backendRebindsObservedTurnAndInterruptsLatestTurn() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-old", reviewThreadID: "thread-1"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await backend.events(for: run)

        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-old"))
        )
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-new",
                item: .init(type: "enteredReviewMode", id: "review-item-1", review: "current changes")
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-old", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .started(turnID: "turn-new", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .progress,
            text: "Reviewing current changes",
            groupID: "review-item-1",
            replacesGroup: true
        ))

        try await backend.interruptReview(run, reason: .init())

        let request = try #require(await transport.recordedRequests().last)
        let params = try JSONDecoder().decode(TurnInterruptParams.self, from: request.params)
        #expect(params.turnID == "turn-new")
    }

    @Test func backendKeepsReviewModeCompletionAfterTurnRebind() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-old", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await backend.events(for: run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-old",
                item: .init(type: "enteredReviewMode", id: "review-item-1", review: "current changes")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-new"))
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-old", status: "completed"))
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-old",
                item: .init(type: "exitedReviewMode", id: "review-item-1", review: "final review text")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-new", status: "completed"))
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-old", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .progress,
            text: "Reviewing current changes",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .started(turnID: "turn-new", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "final review text",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: nil))
    }

    @Test func backendBindsActualTurnFromFirstReviewItemWhenStartedNotificationIsMissing() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-old", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await backend.events(for: run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-new",
                item: .init(type: "enteredReviewMode", id: "review-item-1", review: "current changes")
            )
        )
        try await transport.emitServerNotification(
            method: "item/reasoning/summaryTextDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-new",
                itemID: "reasoning-1",
                delta: " Checking diff"
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-new", status: "completed"))
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-new",
                item: .init(type: "exitedReviewMode", id: "review-item-1", review: "final review text")
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-new", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .progress,
            text: "Reviewing current changes",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .reasoningSummary,
            text: " Checking diff",
            groupID: "reasoning-1:summary:0",
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "final review text",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: nil))
    }

    @Test func backendKeepsReviewResponseTurnItemsAfterActiveTurnStarts() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "review-turn", reviewThreadID: "thread-1"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await backend.events(for: run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "review-turn",
                item: .init(type: "enteredReviewMode", id: "review-item-1", review: "current changes")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "active-turn"))
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "review-turn",
                itemID: "message-1",
                delta: "review output"
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "review-turn", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .progress,
            text: "Reviewing current changes",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .started(turnID: "active-turn", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .messageDelta("review output", itemID: "message-1"))

        try await backend.interruptReview(run, reason: .init())

        let params = try JSONDecoder().decode(
            TurnInterruptParams.self,
            from: try #require(await transport.recordedRequests().last?.params)
        )
        #expect(params.turnID == "active-turn")
    }

    @Test func backendMapsReviewItemAndDiagnosticNotificationsToLogEntries() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await backend.events(for: run)

        try await transport.emitServerNotification(
            method: "turn/plan/updated",
            params: TestPlanNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                plan: [
                    .init(step: "Inspect diff", status: "inProgress"),
                    .init(step: "Write findings", status: "pending"),
                ]
            )
        )
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "swift test")
            )
        )
        try await transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: TestDeltaNotification(threadID: "thread-1", turnID: "turn-1", itemID: "cmd-1", delta: "Tests")
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", aggregatedOutput: "Tests passed")
            )
        )
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-2", command: "pwd")
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-2", command: "pwd")
            )
        )
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "mcpToolCall", id: "tool-1", status: "inProgress", server: "codex_review", tool: "review_read")
            )
        )
        try await transport.emitServerNotification(
            method: "item/mcpToolCall/progress",
            params: TestMessageNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "tool-1",
                message: "Reading review job"
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    type: "mcpToolCall",
                    id: "tool-1",
                    status: "completed",
                    server: "codex_review",
                    tool: "review_read",
                    result: "ok"
                )
            )
        )
        try await transport.emitServerNotification(
            method: "item/reasoning/summaryTextDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "reasoning-1",
                delta: "summary",
                summaryIndex: 1
            )
        )
        try await transport.emitServerNotification(
            method: "item/reasoning/textDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "reasoning-1",
                delta: "raw chain",
                contentIndex: 2
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    type: "reasoning",
                    id: "reasoning-1",
                    summary: ["first final", "summary replacement"],
                    content: ["raw final", "other raw", "raw chain plus final"]
                )
            )
        )
        try await transport.emitServerNotification(
            method: "warning",
            params: TestMessageNotification(threadID: "thread-1", turnID: "turn-1", message: "Model warning")
        )
        try await transport.emitServerNotification(
            method: "deprecationNotice",
            params: TestDiagnosticNotification(summary: "Deprecated thing", details: "Use newer thing.")
        )
        try await transport.emitServerNotification(
            method: "model/rerouted",
            params: TestModelReroutedNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                fromModel: "gpt-5.4",
                toModel: "gpt-5.5",
                reason: "highRiskCyberActivity"
            )
        )
        try await transport.emitServerNotification(
            method: "turn/diff/updated",
            params: TestDiffNotification(threadID: "thread-1", turnID: "turn-1", diff: "diff --git")
        )
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "contextCompaction", id: "compact-1")
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "contextCompaction", id: "compact-1")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-1", status: "completed"))
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .todoList,
            text: "[inProgress] Inspect diff\n[pending] Write findings",
            groupID: "turn-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ swift test",
            groupID: "cmd-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .commandOutput,
            text: "Tests",
            groupID: "cmd-1",
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .commandOutput,
            text: "Tests passed",
            groupID: "cmd-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ pwd",
            groupID: "cmd-2",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .toolCall,
            text: "MCP codex_review.review_read started.",
            groupID: "tool-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .toolCall,
            text: "Reading review job",
            groupID: "tool-1",
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .toolCall,
            text: "codex_review.review_read completed. Result: ok",
            groupID: "tool-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .reasoningSummary,
            text: "summary",
            groupID: "reasoning-1:summary:1",
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .rawReasoning,
            text: "raw chain",
            groupID: "reasoning-1:2",
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .reasoningSummary,
            text: "first final",
            groupID: "reasoning-1:summary:0",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .reasoningSummary,
            text: "summary replacement",
            groupID: "reasoning-1:summary:1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .rawReasoning,
            text: "raw final",
            groupID: "reasoning-1:0",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .rawReasoning,
            text: "other raw",
            groupID: "reasoning-1:1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .rawReasoning,
            text: "raw chain plus final",
            groupID: "reasoning-1:2",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .diagnostic,
            text: "Model warning",
            groupID: "turn-1",
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .diagnostic,
            text: "Deprecated thing\nUse newer thing.",
            groupID: nil,
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .event,
            text: "Model rerouted: gpt-5.4 -> gpt-5.5 (highRiskCyberActivity).",
            groupID: "turn-1",
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .event,
            text: "diff --git",
            groupID: "turn-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .event,
            text: "Context compaction started.",
            groupID: "compact-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .event,
            text: "Context compacted.",
            groupID: "compact-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: nil))
    }

    @Test func backendMapsExitedReviewModeItemToFinalAgentMessage() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await backend.events(for: run)

        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "exitedReviewMode", id: "review-item-1", review: "final review text")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-1", status: "completed"))
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "final review text",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: nil))
    }

    @Test func backendWaitsForFinalReviewItemAfterTurnCompletes() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        let events = await backend.events(for: run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "enteredReviewMode", id: "review-item-1", review: "current changes")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-1", status: "completed"))
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "exitedReviewMode", id: "review-item-1", review: "final review text")
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .progress,
            text: "Reviewing current changes",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "final review text",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: nil))
    }

    @Test func backendReplaysBufferedReviewLifecycleNotifications() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "enteredReviewMode", id: "review-item-1", review: "current changes")
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "exitedReviewMode", id: "review-item-1", review: "final review text")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-1", status: "completed"))
        )

        let events = await backend.events(for: run)
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .progress,
            text: "Reviewing current changes",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "final review text",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: nil))
        #expect(try await iterator.next() == nil)
    }

    @Test func backendMapsTerminalFailureAndCancellationNotifications() async throws {
        let failedRun = BackendReviewRun(threadID: "thread-1", turnID: "turn-1")
        let failedTransport = FakeJSONRPCTransport()
        let failedBackend = AppServerCodexReviewBackend(client: .init(transport: failedTransport))
        let failedEvents = await failedBackend.events(for: failedRun)

        try await failedTransport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "thread-1",
                turn: .init(id: "turn-1", status: "failed", error: .init(message: "Review failed"))
            )
        )

        var failedIterator = failedEvents.makeAsyncIterator()
        #expect(try await failedIterator.next() == .failed("Review failed"))

        let cancelledRun = BackendReviewRun(threadID: "thread-2", turnID: "turn-2")
        let cancelledTransport = FakeJSONRPCTransport()
        let cancelledBackend = AppServerCodexReviewBackend(client: .init(transport: cancelledTransport))
        let cancelledEvents = await cancelledBackend.events(for: cancelledRun)

        try await cancelledTransport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "thread-2",
                turn: .init(id: "turn-2", status: "interrupted", error: .init(message: "Stopped"))
            )
        )

        var cancelledIterator = cancelledEvents.makeAsyncIterator()
        #expect(try await cancelledIterator.next() == .cancelled("Stopped"))

        let failedWithoutMessageRun = BackendReviewRun(threadID: "thread-4", turnID: "turn-4")
        let failedWithoutMessageTransport = FakeJSONRPCTransport()
        let failedWithoutMessageBackend = AppServerCodexReviewBackend(client: .init(transport: failedWithoutMessageTransport))
        let failedWithoutMessageEvents = await failedWithoutMessageBackend.events(for: failedWithoutMessageRun)

        try await failedWithoutMessageTransport.emitServerNotification(
            method: "turn/completed",
            params: TestPartialTurnNotification(
                threadID: "thread-4",
                turn: .init(id: "turn-4", status: "failed", error: .init())
            )
        )

        var failedWithoutMessageIterator = failedWithoutMessageEvents.makeAsyncIterator()
        #expect(try await failedWithoutMessageIterator.next() == .failed("Failed."))

        let cancelledWithoutMessageRun = BackendReviewRun(threadID: "thread-5", turnID: "turn-5")
        let cancelledWithoutMessageTransport = FakeJSONRPCTransport()
        let cancelledWithoutMessageBackend = AppServerCodexReviewBackend(client: .init(transport: cancelledWithoutMessageTransport))
        let cancelledWithoutMessageEvents = await cancelledWithoutMessageBackend.events(for: cancelledWithoutMessageRun)

        try await cancelledWithoutMessageTransport.emitServerNotification(
            method: "turn/completed",
            params: TestPartialTurnNotification(
                threadID: "thread-5",
                turn: .init(id: "turn-5", status: "interrupted", error: .init())
            )
        )

        var cancelledWithoutMessageIterator = cancelledWithoutMessageEvents.makeAsyncIterator()
        #expect(try await cancelledWithoutMessageIterator.next() == .cancelled("Cancellation requested."))

        let retryingRun = BackendReviewRun(threadID: "thread-3", turnID: "turn-3")
        let retryingTransport = FakeJSONRPCTransport()
        let retryingBackend = AppServerCodexReviewBackend(client: .init(transport: retryingTransport))
        let retryingEvents = await retryingBackend.events(for: retryingRun)

        try await retryingTransport.emitServerNotification(
            method: "error",
            params: TestErrorNotification(threadID: "thread-3", turnID: "turn-3", message: "Retrying request", willRetry: true)
        )
        try await retryingTransport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-3", turn: .init(id: "turn-3", status: "completed"))
        )

        var retryingIterator = retryingEvents.makeAsyncIterator()
        #expect(try await retryingIterator.next() == .started(turnID: "turn-3", reviewThreadID: "thread-3", model: nil))
        #expect(try await retryingIterator.next() == .logEntry(
            kind: .progress,
            text: "Retrying request",
            groupID: "turn-3",
            replacesGroup: false
        ))
        #expect(try await retryingIterator.next() == .completed(summary: "Succeeded.", result: nil))
    }

    @Test func backendIgnoresUnrelatedNotificationsBeforeReviewPayloadDecode() async throws {
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = BackendReviewRun(threadID: "thread-1", turnID: "turn-1")
        let events = await backend.events(for: run)

        try await transport.emitServerNotification(
            method: "account/updated",
            params: ["accountID": "account-1"]
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-1", status: "completed"))
        )

        var iterator = events.makeAsyncIterator()
        let event = try await iterator.next()
        #expect(event == .completed(summary: "Succeeded.", result: nil))
    }

    @Test func backendCleansThreadWhenReviewStartFailsAfterThreadStart() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1"), for: "thread/start")
        await transport.enqueueFailure(.responseError(code: -32602, message: "invalid target"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        await #expect(throws: JSONRPCError.responseError(code: -32602, message: "invalid target")) {
            try await backend.startReview(.init(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            ))
        }

        let methods = await transport.recordedRequests().map(\.method)
        #expect(methods == [
            "initialize",
            "thread/start",
            "review/start",
            "thread/backgroundTerminals/clean",
            "thread/unsubscribe",
        ])
    }

    private func waitUntil(timeout: Duration, condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while condition() == false {
            if clock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }
}

private func enqueueInitialize(_ transport: FakeJSONRPCTransport) async throws {
    try await transport.enqueue(InitializeResponse(), for: "initialize")
}

private func makeModelCatalogItem(
    model: String,
    isDefault: Bool = false
) -> CodexReviewModelCatalogItem {
    .init(
        id: model,
        model: model,
        displayName: model,
        hidden: false,
        supportedReasoningEfforts: [.init(reasoningEffort: .medium, description: "Balanced")],
        defaultReasoningEffort: .medium,
        supportedServiceTiers: [.fast],
        isDefault: isDefault
    )
}

private struct TestTurnNotification: Encodable, Sendable {
    var threadID: String
    var turn: AppServerTurn
    var reviewThreadID: String? = nil

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
        case reviewThreadID = "reviewThreadId"
    }
}

private struct TestPartialTurnNotification: Encodable, Sendable {
    var threadID: String
    var turn: TestPartialTurn

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
    }
}

private struct TestPartialTurn: Encodable, Sendable {
    var id: String
    var status: String
    var error: TestPartialTurnError
}

private struct TestPartialTurnError: Encodable, Sendable {}

private struct TestThreadStatusNotification: Encodable, Sendable {
    var threadID: String
    var status: TestThreadStatus

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case status
    }
}

private struct TestThreadStatus: Encodable, Sendable {
    var type: String
}

private struct TestThreadClosedNotification: Encodable, Sendable {
    var threadID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

private struct TestDeltaNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var delta: String
    var summaryIndex: Int? = nil
    var contentIndex: Int? = nil

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case delta
        case summaryIndex
        case contentIndex
    }
}

private struct TestPlanNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var plan: [Step]

    struct Step: Encodable, Sendable {
        var step: String
        var status: String
    }

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case plan
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
    var review: String?
    var command: String?
    var aggregatedOutput: String?
    var status: String?
    var server: String?
    var tool: String?
    var result: String?
    var summary: [String]?
    var content: [String]?

    init(
        type: String,
        id: String,
        review: String? = nil,
        command: String? = nil,
        aggregatedOutput: String? = nil,
        status: String? = nil,
        server: String? = nil,
        tool: String? = nil,
        result: String? = nil,
        summary: [String]? = nil,
        content: [String]? = nil
    ) {
        self.type = type
        self.id = id
        self.review = review
        self.command = command
        self.aggregatedOutput = aggregatedOutput
        self.status = status
        self.server = server
        self.tool = tool
        self.result = result
        self.summary = summary
        self.content = content
    }
}

private struct TestDiagnosticNotification: Encodable, Sendable {
    var summary: String
    var details: String?
}

private struct TestModelReroutedNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var fromModel: String
    var toModel: String
    var reason: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case fromModel
        case toModel
        case reason
    }
}

private struct TestDiffNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var diff: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case diff
    }
}

private struct TestMessageNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String? = nil
    var message: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case message
    }
}

private struct TestErrorNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var message: String
    var willRetry: Bool

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case message
        case willRetry
    }
}
