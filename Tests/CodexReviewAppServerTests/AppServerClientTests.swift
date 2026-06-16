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
        let script = """
        #!/bin/sh
        if [ "$1" = "app-server" ] && [ "$2" = "--help" ]; then
          printf 'Usage: codex app-server --listen <URL> --session-source <SOURCE>\\n'
        fi
        """
        try Data(script.utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        let configuration = AppServerProcessTransport.Configuration(
            environment: ["PATH": directory.path, "HOME": "/tmp/review-home"]
        )

        #expect(configuration.executable == codex.path)
        #expect(configuration.arguments == [
            "-c", CodexAppServerExecutable.fileBackedAuthConfiguration,
            "app-server",
            "--listen", "stdio://",
            "--session-source", "app-server",
        ])
        #expect(configuration.arguments.contains(#"cli_auth_credentials_store="file""#))
        #expect(configuration.threadStartPermissionStrategy == .modernPermissions)
        let sessionSourceIndex = try #require(configuration.arguments.firstIndex(of: "--session-source"))
        #expect(configuration.arguments[sessionSourceIndex + 1] == "app-server")
    }

    @Test func processTransportConfigurationUsesExplicitExecutableWithoutPathSearch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-explicit-executable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let codex = directory.appending(path: "custom-codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "app-server" ] && [ "$2" = "--help" ]; then
          printf 'Usage: custom codex app-server --listen <URL>\\n'
        fi
        """
        try Data(script.utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        let configuration = AppServerProcessTransport.Configuration(
            executable: codex.path,
            environment: [
                "PATH": "/tmp/not-used",
                "HOME": "/tmp/review-home",
            ]
        )

        #expect(configuration.executable == codex.path)
        #expect(configuration.arguments == CodexAppServerExecutable.appServerArguments())
    }

    @Test func processTransportConfigurationOmitsUnsupportedSessionSourceFlag() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let codex = directory.appending(path: "codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "app-server" ] && [ "$2" = "--help" ]; then
          printf 'Usage: codex app-server --listen <URL>\\n'
        fi
        """
        try Data(script.utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        let configuration = AppServerProcessTransport.Configuration(
            environment: ["PATH": directory.path, "HOME": "/tmp/review-home"]
        )

        #expect(configuration.executable == codex.path)
        #expect(configuration.arguments == CodexAppServerExecutable.appServerArguments())
        #expect(configuration.arguments.contains("--session-source") == false)
        #expect(configuration.threadStartPermissionStrategy == .legacySandbox)
    }

    @Test func processTransportConfigurationDoesNotProbeWhenArgumentsAreExplicit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let codex = directory.appending(path: "codex")
        let probed = directory.appending(path: "probed")
        let script = """
        #!/bin/sh
        touch "\(probed.path)"
        """
        try Data(script.utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        let configuration = AppServerProcessTransport.Configuration(
            executable: codex.path,
            arguments: ["custom", "argument"],
            environment: ["PATH": directory.path, "HOME": "/tmp/review-home"]
        )

        #expect(configuration.executable == codex.path)
        #expect(configuration.arguments == ["custom", "argument"])
        #expect(configuration.threadStartPermissionStrategy == .legacySandbox)
        #expect(FileManager.default.fileExists(atPath: probed.path) == false)
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

    @Test func stderrLogFilterSuppressesCommandOutputAfterToolError() {
        var filter = AppServerStderrLogFilter()
        let stderr = """
        \u{001B}[31m2026-06-08T09:20:00.000Z ERROR codex_core::tools::router: error=Exit code: 124\u{001B}[0m
        Wall time: 20 seconds
        Output:
        command timed out after 20000 milliseconds
        README.md | 1 +
        func expensiveDump() {}
        2026-06-08T09:20:01.000Z ERROR codex_core::exec: next error

        """

        var events = filter.append(Data(stderr.utf8))
        events.append(contentsOf: filter.finish())

        #expect(events.map(\.level) == [.error, .error, .warning, .warning, .warning, .error])
        #expect(events.map(\.message) == [
            "2026-06-08T09:20:00.000Z ERROR codex_core::tools::router: error=Exit code: 124",
            "Wall time: 20 seconds",
            "command output omitted after tool error",
            "command timed out after 20000 milliseconds",
            "suppressed 2 command-output line(s)",
            "2026-06-08T09:20:01.000Z ERROR codex_core::exec: next error",
        ])
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
        printf '{"id":1,"result":{"value":'
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

    @Test func processTransportWritesCodexJSONRPCLiteMessages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "codex-review-jsonrpc-lite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let executable = directory.appending(path: "app-server-stub.sh")
        let requestFile = directory.appending(path: "request.json")
        let notificationFile = directory.appending(path: "notification.json")
        let script = """
        #!/bin/sh
        request_file="$1"
        notification_file="$2"
        IFS= read -r request
        printf '%s\\n' "$request" > "$request_file"
        printf '{"id":7,"result":{}}\\n'
        IFS= read -r notification
        printf '%s\\n' "$notification" > "$notification_file"
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let transport = try AppServerProcessTransport(configuration: .init(
            executable: executable.path,
            arguments: [requestFile.path, notificationFile.path],
            environment: [
                "HOME": directory.path,
                "PATH": "/bin:/usr/bin",
            ]
        ))

        _ = try await transport.send(JSONRPCRequest(
            id: 7,
            method: "test/request",
            params: Data(#"{"value":true}"#.utf8)
        ))
        try await transport.notify(JSONRPCNotification(
            method: "initialized",
            params: Data("{}".utf8)
        ))
        let notificationWritten = await waitUntil(timeout: .seconds(2)) {
            FileManager.default.fileExists(atPath: notificationFile.path)
        }
        await transport.close()

        #expect(notificationWritten)
        let request = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: requestFile)
        ) as? [String: Any])
        let notification = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: notificationFile)
        ) as? [String: Any])
        #expect(request["jsonrpc"] == nil)
        #expect(request["id"] as? Int == 7)
        #expect(request["method"] as? String == "test/request")
        #expect(notification["jsonrpc"] == nil)
        #expect(notification["method"] as? String == "initialized")
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

        #expect(object["jsonrpc"] == nil)
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

    @Test func sendRetriesAppServerOverloadWithFreshRequestID() async throws {
        let transport = FakeJSONRPCTransport()
        await transport.enqueueFailure(
            .responseError(code: -32001, message: "Server overloaded; retry later."),
            for: "test/request"
        )
        let client = AppServerClient(
            transport: transport,
            overloadRetryDelay: { _ in .milliseconds(100) },
            retrySleep: { _ in }
        )

        let response: EmptyResponse = try await client.send(
            method: "test/request",
            params: EmptyResponse(),
            responseType: EmptyResponse.self
        )

        #expect(response == EmptyResponse())
        let requests = await transport.recordedRequests()
        #expect(requests.map(\.method) == ["test/request", "test/request"])
        #expect(requests[0].id != requests[1].id)
    }

    @Test func sendDoesNotRetryNonOverloadAppServerErrors() async throws {
        let transport = FakeJSONRPCTransport()
        await transport.enqueueFailure(
            .responseError(code: -32602, message: "invalid target"),
            for: "test/request"
        )
        let client = AppServerClient(transport: transport)

        await #expect(throws: JSONRPCError.responseError(code: -32602, message: "invalid target")) {
            let _: EmptyResponse = try await client.send(
                method: "test/request",
                params: EmptyResponse(),
                responseType: EmptyResponse.self
            )
        }
        #expect(await transport.recordedRequests().map(\.method) == ["test/request"])
    }

    @Test func startupInterruptUsesEmptyTurnID() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let client = AppServerClient(transport: transport)
        let control = AppServerReviewControl(client: client)

        control.recordThreadStarted(threadID: "thread-1")
        let interruption = try await control.interrupt()
        #expect(interruption == .init(threadID: "thread-1", turnID: ""))

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

        control.recordReviewStarted(turnThreadID: "thread-1", turnID: "turn-1")
        let interruption = try await control.interrupt()
        #expect(interruption == .init(threadID: "thread-1", turnID: "turn-1"))

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

        control.recordReviewStarted(turnThreadID: "thread-1", turnID: "turn-old")
        let interruption = try await control.interrupt()
        #expect(interruption == .init(threadID: "thread-1", turnID: "turn-new"))

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

    @Test func accountReadResponseDecodesChatGPTAccountAuthRequirement() throws {
        let data = Data("""
        {"account":{"type":"chatgpt","email":"review@example.com","planType":"pro"},"requiresOpenaiAuth":true}
        """.utf8)
        let response = try JSONDecoder().decode(AccountReadResponse.self, from: data)

        #expect(response.requiresOpenAIAuth)
        #expect(response.account?.id == .init("review@example.com"))
        #expect(response.account?.kind == .chatGPT)
        #expect(response.account?.label == "review@example.com")
        #expect(response.account?.planType == "pro")
        #expect(response.account?.capabilities.supportsRateLimitRefresh == true)
    }

    @Test func accountReadResponseNormalizesProviderAccountCapabilities() throws {
        let apiKeyData = Data("""
        {"account":{"type":"apiKey"},"requiresOpenaiAuth":false}
        """.utf8)
        let bedrockData = Data("""
        {"account":{"type":"amazonBedrock"},"requiresOpenaiAuth":false}
        """.utf8)

        let apiKeyResponse = try JSONDecoder().decode(AccountReadResponse.self, from: apiKeyData)
        let bedrockResponse = try JSONDecoder().decode(AccountReadResponse.self, from: bedrockData)

        #expect(apiKeyResponse.account?.id == .init("api-key"))
        #expect(apiKeyResponse.account?.kind == .apiKey)
        #expect(apiKeyResponse.account?.label == "API Key")
        #expect(apiKeyResponse.account?.capabilities.supportsRateLimitRefresh == false)
        #expect(bedrockResponse.account?.id == .init("amazon-bedrock"))
        #expect(bedrockResponse.account?.kind == .amazonBedrock)
        #expect(bedrockResponse.account?.label == "Amazon Bedrock")
        #expect(bedrockResponse.account?.capabilities.supportsRateLimitRefresh == false)
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
                nativeWebAuthentication: .init(callbackURLScheme: "lynnpd.CodexReviewMonitor.auth")
            ),
            for: "account/login/start"
        )
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let challenge = try await backend.startLogin(.init(
            nativeWebAuthenticationCallbackScheme: "lynnpd.CodexReviewMonitor.auth"
        ))

        #expect(challenge.id == "login-1")
        #expect(challenge.verificationURL == URL(string: "https://example.com/auth"))
        #expect(challenge.nativeWebAuthenticationCallbackScheme == "lynnpd.CodexReviewMonitor.auth")
        let request = try #require(await transport.recordedRequests().last)
        #expect(request.method == "account/login/start")
        let params = try JSONDecoder().decode(LoginAccountParams.self, from: request.params)
        #expect(params.nativeWebAuthentication?.callbackURLScheme == "lynnpd.CodexReviewMonitor.auth")
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

    @Test func backendStartsPersistentReviewThreads() async throws {
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
        let object = try #require(JSONSerialization.jsonObject(with: threadStart.params) as? [String: Any])
        #expect(params.ephemeral == false)
        #expect(params.approvalPolicy == "never")
        #expect(params.permissions == .profileID(":danger-full-access"))
        #expect(params.sessionStartSource == .startup)
        #expect(params.threadSource == .user)
        #expect(params.sandbox == nil)
        #expect(object["permissions"] as? String == ":danger-full-access")
        #expect(object["sessionStartSource"] as? String == "startup")
        #expect(object["threadSource"] as? String == "user")
        #expect(object["sandbox"] == nil)
    }

    @Test func backendUsesLegacySandboxWhenProcessDoesNotSupportModernSessionSource() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(
            client: .init(transport: transport),
            threadStartPermissionStrategy: .legacySandbox
        )

        _ = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))

        let threadStarts = await transport.recordedRequests().filter { $0.method == "thread/start" }
        #expect(threadStarts.count == 1)
        let request = try #require(threadStarts.first)
        let params = try #require(JSONSerialization.jsonObject(with: request.params) as? [String: Any])
        #expect(params["ephemeral"] as? Bool == false)
        #expect(params["sandbox"] as? String == "danger-full-access")
        #expect(params["permissions"] == nil)
        #expect(params["sessionStartSource"] as? String == "startup")
        #expect(params["threadSource"] as? String == "user")
    }

    @Test func backendRetriesThreadStartWithObjectPermissionsForInstalledCodex() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        await transport.enqueueFailure(
            .responseError(
                code: -32602,
                message: #"Invalid request: invalid type: string ":danger-full-access", expected internally tagged enum PermissionProfileSelectionParams"#
            ),
            for: "thread/start"
        )
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        _ = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))

        let threadStarts = await transport.recordedRequests().filter { $0.method == "thread/start" }
        #expect(threadStarts.count == 2)

        let firstRequest = try #require(threadStarts.first)
        let secondRequest = try #require(threadStarts.last)
        let first = try #require(JSONSerialization.jsonObject(
            with: firstRequest.params
        ) as? [String: Any])
        let second = try #require(JSONSerialization.jsonObject(
            with: secondRequest.params
        ) as? [String: Any])
        let permissions = try #require(second["permissions"] as? [String: Any])

        #expect(first["permissions"] as? String == ":danger-full-access")
        #expect(first["sandbox"] == nil)
        #expect(first["sessionStartSource"] as? String == "startup")
        #expect(first["threadSource"] as? String == "user")
        #expect(permissions["type"] as? String == "profile")
        #expect(permissions["id"] as? String == ":danger-full-access")
        #expect(second["sandbox"] == nil)
        #expect(second["sessionStartSource"] as? String == "startup")
        #expect(second["threadSource"] as? String == "user")
    }

    @Test func backendFallsBackToLegacySandboxWhenInstalledCodexLacksDangerProfile() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        await transport.enqueueFailure(
            .responseError(
                code: -32602,
                message: #"Invalid request: invalid type: string ":danger-full-access", expected internally tagged enum PermissionProfileSelectionParams"#
            ),
            for: "thread/start"
        )
        await transport.enqueueFailure(
            .responseError(
                code: -32602,
                message: "failed to load configuration: default_permissions refers to unknown built-in profile `:danger-full-access`"
            ),
            for: "thread/start"
        )
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        _ = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))

        let threadStarts = await transport.recordedRequests().filter { $0.method == "thread/start" }
        #expect(threadStarts.count == 3)

        let fallbackRequest = try #require(threadStarts.last)
        let fallback = try #require(JSONSerialization.jsonObject(
            with: fallbackRequest.params
        ) as? [String: Any])
        #expect(fallback["sandbox"] as? String == "danger-full-access")
        #expect(fallback["permissions"] == nil)
        #expect(fallback["sessionStartSource"] as? String == "startup")
        #expect(fallback["threadSource"] as? String == "user")
    }

    @Test func backendFallsBackToLegacySandboxWhenProfileIDPermissionsAreUnknown() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        await transport.enqueueFailure(
            .responseError(
                code: -32602,
                message: "failed to load configuration: default_permissions refers to unknown built-in profile `:danger-full-access`"
            ),
            for: "thread/start"
        )
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        _ = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))

        let threadStarts = await transport.recordedRequests().filter { $0.method == "thread/start" }
        #expect(threadStarts.count == 2)

        let firstRequest = try #require(threadStarts.first)
        let fallbackRequest = try #require(threadStarts.last)
        let first = try #require(JSONSerialization.jsonObject(
            with: firstRequest.params
        ) as? [String: Any])
        let fallback = try #require(JSONSerialization.jsonObject(
            with: fallbackRequest.params
        ) as? [String: Any])
        #expect(first["permissions"] as? String == ":danger-full-access")
        #expect(first["sandbox"] == nil)
        #expect(fallback["sandbox"] as? String == "danger-full-access")
        #expect(fallback["permissions"] == nil)
        #expect(fallback["sessionStartSource"] as? String == "startup")
        #expect(fallback["threadSource"] as? String == "user")
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

    @Test func threadUnsubscribeResponseDecodesStatus() throws {
        let data = Data(#"{"status":"unsubscribed"}"#.utf8)
        let response = try JSONDecoder().decode(ThreadUnsubscribeResponse.self, from: data)

        #expect(response.status == .unsubscribed)
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

    @Test func backendInterruptUsesDetachedReviewThreadBeforeStartedNotification() async throws {
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
        try await backend.interruptReview(run, reason: .init(message: "Stop"))

        let request = try #require(await transport.recordedRequests().last)
        #expect(request.method == "turn/interrupt")
        let params = try JSONDecoder().decode(TurnInterruptParams.self, from: request.params)
        #expect(params.threadID == "review-thread")
        #expect(params.turnID == "turn-old")
    }

    @Test func backendPreservesDetachedReviewThreadIDWhenReviewItemOmitsIt() async throws {
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
            method: "item/started",
            params: TestItemNotification(
                threadID: "parent-thread",
                turnID: "turn-new",
                item: .init(type: "enteredReviewMode", id: "review-item-1", review: "current changes")
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-new", reviewThreadID: "review-thread", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .progress,
            text: "Reviewing current changes",
            groupID: "review-item-1",
            replacesGroup: true
        ))
    }

    @Test func backendRoutesDetachedReviewThreadNotificationsToParentSession() async throws {
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
        var iterator = await backend.events(for: run).makeAsyncIterator()

        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(
                threadID: "review-thread",
                turn: .init(id: "turn-new"),
                reviewThreadID: "review-thread"
            )
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TestDeltaNotification(
                threadID: "review-thread",
                turnID: "turn-new",
                itemID: "message-1",
                delta: "review text"
            )
        )

        #expect(try await iterator.next() == .started(turnID: "turn-new", reviewThreadID: "review-thread", model: nil))
        #expect(try await iterator.next() == .messageDelta("review text", itemID: "message-1"))
        #expect(await backend.reviewEventSessionMetricsForTesting(threadID: "review-thread")?.routed == 2)

        try await backend.interruptReview(run, reason: .init(message: "Stop"))
        let interruptRequest = try #require(await transport.recordedRequests().last)
        #expect(interruptRequest.method == "turn/interrupt")
        let interruptParams = try JSONDecoder().decode(TurnInterruptParams.self, from: interruptRequest.params)
        #expect(interruptParams.threadID == "review-thread")
        #expect(interruptParams.turnID == "turn-new")
    }

    @Test func backendIgnoresStaleEventStreamDetachAfterResubscribe() async throws {
        let run = BackendReviewRun(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let firstEvents = await backend.events(for: run)
        _ = firstEvents

        let firstAttached = await waitUntil {
            await backend.activeReviewEventStreamSubscriptionIDForTesting(threadID: "thread-1") != nil
        }
        #expect(firstAttached)
        let firstSubscriptionID = try #require(
            await backend.activeReviewEventStreamSubscriptionIDForTesting(threadID: "thread-1")
        )

        let secondEvents = await backend.events(for: run)
        var secondIterator = secondEvents.makeAsyncIterator()
        let secondAttached = await waitUntil {
            await backend.activeReviewEventStreamSubscriptionIDForTesting(threadID: "thread-1") != firstSubscriptionID
        }
        #expect(secondAttached)
        let secondSubscriptionID = try #require(
            await backend.activeReviewEventStreamSubscriptionIDForTesting(threadID: "thread-1")
        )

        await backend.detachReviewEventStreamForTesting(
            threadID: "thread-1",
            subscriptionID: firstSubscriptionID
        )
        #expect(await backend.activeReviewEventStreamSubscriptionIDForTesting(threadID: "thread-1") == secondSubscriptionID)

        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "message-1",
                delta: "review text"
            )
        )

        #expect(try await secondIterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await secondIterator.next() == .messageDelta("review text", itemID: "message-1"))
    }

    @Test func backendPreservesNotificationStreamErrorForLateEventStreamSubscriber() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        #expect(await transport.notificationStreamCount() == 1)

        await transport.finishNotificationStreams(throwing: JSONRPCError.closed)
        let routerStopped = await waitUntil {
            await backend.notificationRouterIsRunningForTesting() == false
        }
        #expect(routerStopped)

        var iterator = await backend.events(for: run).makeAsyncIterator()
        await #expect(throws: JSONRPCError.closed) {
            _ = try await iterator.next()
        }
        await transport.close()
    }

    @Test func backendTracksSyntheticDetachedReviewThreadStartsForInterrupt() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = BackendReviewRun(threadID: "parent-thread", reviewThreadID: "review-thread")
        var iterator = await backend.events(for: run).makeAsyncIterator()

        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TestDeltaNotification(
                threadID: "review-thread",
                turnID: "turn-new",
                itemID: "message-1",
                delta: "review text"
            )
        )

        #expect(try await iterator.next() == .started(turnID: "turn-new", reviewThreadID: "review-thread", model: nil))
        #expect(try await iterator.next() == .messageDelta("review text", itemID: "message-1"))

        try await backend.interruptReview(run, reason: .init(message: "Stop"))
        let interruptRequest = try #require(await transport.recordedRequests().last)
        #expect(interruptRequest.method == "turn/interrupt")
        let interruptParams = try JSONDecoder().decode(TurnInterruptParams.self, from: interruptRequest.params)
        #expect(interruptParams.threadID == "review-thread")
        #expect(interruptParams.turnID == "turn-new")
    }

    @Test func backendBuffersDetachedReviewThreadNotificationsDuringReviewStart() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "parent-thread", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-old", reviewThreadID: "review-thread"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
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
            method: "turn/started",
            params: TestTurnNotification(
                threadID: "review-thread",
                turn: .init(id: "turn-new"),
                reviewThreadID: "review-thread"
            )
        )
        let bufferedDetachedNotification = await waitUntil {
            await backend.notificationRouterMetricsForTesting().buffered == 1
        }
        #expect(bufferedDetachedNotification)

        await gate.open()
        let run = try await started
        var iterator = await backend.events(for: run).makeAsyncIterator()

        #expect(try await iterator.next() == .started(turnID: "turn-new", reviewThreadID: "review-thread", model: nil))
        #expect(await backend.reviewEventSessionMetricsForTesting(threadID: "review-thread")?.routed == 1)
        try await backend.interruptReview(run, reason: .init(message: "Stop"))
        let interruptRequest = try #require(await transport.recordedRequests().last)
        #expect(interruptRequest.method == "turn/interrupt")
        let interruptParams = try JSONDecoder().decode(TurnInterruptParams.self, from: interruptRequest.params)
        #expect(interruptParams.threadID == "review-thread")
        #expect(interruptParams.turnID == "turn-new")
    }

    @Test func backendUsesSingleNotificationRouterForConcurrentReviews() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-2", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-2", reviewThreadID: "thread-2"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        async let first = backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project-1", target: .uncommittedChanges)
        ))
        async let second = backend.startReview(.init(
            jobID: "job-2",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project-2", target: .uncommittedChanges)
        ))
        _ = try await (first, second)
        await transport.waitForNotificationStreamCount(1)

        #expect(await transport.notificationStreamCount() == 1)
    }

    @Test func backendRoutesInterleavedNotificationsToMatchingReviewSessions() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-2", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-2", reviewThreadID: "thread-2"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let firstRun = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project-1", target: .uncommittedChanges)
        ))
        let secondRun = try await backend.startReview(.init(
            jobID: "job-2",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project-2", target: .uncommittedChanges)
        ))
        let firstEvents = await backend.events(for: firstRun)
        let secondEvents = await backend.events(for: secondRun)
        var firstIterator = firstEvents.makeAsyncIterator()
        var secondIterator = secondEvents.makeAsyncIterator()

        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-2", turn: .init(id: "turn-2"))
        )
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-1"))
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TestDeltaNotification(threadID: "thread-2", turnID: "turn-2", itemID: "msg-2", delta: "Second")
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TestDeltaNotification(threadID: "thread-1", turnID: "turn-1", itemID: "msg-1", delta: "First")
        )

        #expect(try await firstIterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await firstIterator.next() == .messageDelta("First", itemID: "msg-1"))
        #expect(try await secondIterator.next() == .started(turnID: "turn-2", reviewThreadID: "thread-2", model: nil))
        #expect(try await secondIterator.next() == .messageDelta("Second", itemID: "msg-2"))
    }

    @Test func backendBroadcastsGlobalDiagnosticsToActiveReviewSessions() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-2", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-2", reviewThreadID: "thread-2"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let firstRun = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project-1", target: .uncommittedChanges)
        ))
        let secondRun = try await backend.startReview(.init(
            jobID: "job-2",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project-2", target: .uncommittedChanges)
        ))
        var firstIterator = await backend.events(for: firstRun).makeAsyncIterator()
        var secondIterator = await backend.events(for: secondRun).makeAsyncIterator()

        try await transport.emitServerNotification(
            method: "warning",
            params: TestGlobalMessageNotification(message: "Global warning")
        )

        let expected = BackendReviewEvent.logEntry(
            kind: .diagnostic,
            text: "Global warning",
            groupID: nil,
            replacesGroup: false
        )
        #expect(try await firstIterator.next() == expected)
        #expect(try await secondIterator.next() == expected)
        #expect(await backend.notificationRouterMetricsForTesting().decoded == 1)
        #expect(await backend.notificationRouterMetricsForTesting().routed == 2)
    }

    @Test func backendBroadcastsThreadlessErrorsToActiveReviewSessions() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-2", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1", reviewThreadID: "thread-1"), for: "review/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-2", reviewThreadID: "thread-2"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))

        let firstRun = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project-1", target: .uncommittedChanges)
        ))
        let secondRun = try await backend.startReview(.init(
            jobID: "job-2",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project-2", target: .uncommittedChanges)
        ))
        var firstIterator = await backend.events(for: firstRun).makeAsyncIterator()
        var secondIterator = await backend.events(for: secondRun).makeAsyncIterator()

        try await transport.emitServerNotification(
            method: "error",
            params: TestErrorNotification(message: "App-server failed.", willRetry: false)
        )

        #expect(try await firstIterator.next() == .failed("App-server failed."))
        #expect(try await secondIterator.next() == .failed("App-server failed."))
        #expect(await backend.notificationRouterMetricsForTesting().decoded == 1)
        #expect(await backend.notificationRouterMetricsForTesting().routed == 2)
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

    @Test func backendRecoverReviewRollsBackAndRestartsSameThread() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-2", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = BackendReviewRun(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: "gpt-5"
        )

        let recovered = try await backend.recoverReview(
            run,
            request: .init(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                model: "gpt-5"
            ),
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )

        #expect(recovered.threadID == "thread-1")
        #expect(recovered.turnID == "turn-2")
        let requests = await transport.recordedRequests()
        #expect(requests.map(\.method) == [
            "initialize",
            "turn/interrupt",
            "thread/rollback",
            "review/start",
        ])
        let interrupt = try #require(requests.first { $0.method == "turn/interrupt" })
        let interruptParams = try JSONDecoder().decode(TurnInterruptParams.self, from: interrupt.params)
        #expect(interruptParams.threadID == "thread-1")
        #expect(interruptParams.turnID == "turn-1")
        let rollback = try #require(requests.first { $0.method == "thread/rollback" })
        let rollbackParams = try JSONDecoder().decode(ThreadRollbackParams.self, from: rollback.params)
        #expect(rollbackParams.threadID == "thread-1")
        #expect(rollbackParams.numTurns == 1)
        let restart = try #require(requests.first { $0.method == "review/start" })
        let restartParams = try JSONDecoder().decode(ReviewStartParams.self, from: restart.params)
        #expect(restartParams.threadID == "thread-1")
        #expect(restartParams.target == .baseBranch("main"))
    }

    @Test func backendRecoverReviewUsesDetachedReviewThreadBeforeStartedNotification() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "parent-thread", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-old", reviewThreadID: "review-thread"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-2", reviewThreadID: "review-thread"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))

        let recovered = try await backend.recoverReview(
            run,
            request: .init(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                model: "gpt-5"
            ),
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )

        #expect(recovered.threadID == "parent-thread")
        #expect(recovered.turnID == "turn-2")
        #expect(recovered.reviewThreadID == "review-thread")
        let requests = await transport.recordedRequests()
        let interrupt = try #require(requests.first { $0.method == "turn/interrupt" })
        let interruptParams = try JSONDecoder().decode(TurnInterruptParams.self, from: interrupt.params)
        #expect(interruptParams.threadID == "review-thread")
        #expect(interruptParams.turnID == "turn-old")
        let rollback = try #require(requests.first { $0.method == "thread/rollback" })
        let rollbackParams = try JSONDecoder().decode(ThreadRollbackParams.self, from: rollback.params)
        #expect(rollbackParams.threadID == "review-thread")
        #expect(rollbackParams.numTurns == 1)
        let restart = try #require(requests.last { $0.method == "review/start" })
        let restartParams = try JSONDecoder().decode(ReviewStartParams.self, from: restart.params)
        #expect(restartParams.threadID == "parent-thread")
        #expect(restartParams.target == .baseBranch("main"))
    }

    @Test func backendRecoverReviewRollsBackInterruptedDetachedReviewThread() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(ThreadStartResponse(threadID: "parent-thread", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-old", reviewThreadID: "review-thread"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-2", reviewThreadID: "review-thread"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let startedRun = try await backend.startReview(.init(
            jobID: "job-1",
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        var iterator = await backend.events(for: startedRun).makeAsyncIterator()
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(
                threadID: "review-thread",
                turn: .init(id: "turn-new"),
                reviewThreadID: "review-thread"
            )
        )
        #expect(try await iterator.next() == .started(
            turnID: "turn-new",
            reviewThreadID: "review-thread",
            model: nil
        ))
        let currentRun = BackendReviewRun(
            threadID: "parent-thread",
            turnID: "turn-new",
            reviewThreadID: "review-thread",
            model: "gpt-5"
        )
        let reason = BackendCancellationReason(message: "Network unavailable; waiting to reconnect.")

        try await backend.interruptReviewForRecovery(currentRun, reason: reason)
        let recovered = try await backend.recoverReview(
            currentRun,
            request: .init(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                model: "gpt-5"
            ),
            reason: reason
        )

        #expect(recovered.threadID == "parent-thread")
        #expect(recovered.turnID == "turn-2")
        #expect(recovered.reviewThreadID == "review-thread")
        let requests = await transport.recordedRequests()
        let interruptParams = try requests
            .filter { $0.method == "turn/interrupt" }
            .map { try JSONDecoder().decode(TurnInterruptParams.self, from: $0.params) }
        #expect(interruptParams == [
            .init(threadID: "review-thread", turnID: "turn-new"),
        ])
        let rollback = try #require(requests.first { $0.method == "thread/rollback" })
        let rollbackParams = try JSONDecoder().decode(ThreadRollbackParams.self, from: rollback.params)
        #expect(rollbackParams.threadID == "review-thread")
        #expect(rollbackParams.numTurns == 1)
        let restart = try #require(requests.last { $0.method == "review/start" })
        let restartParams = try JSONDecoder().decode(ReviewStartParams.self, from: restart.params)
        #expect(restartParams.threadID == "parent-thread")
        #expect(restartParams.target == .baseBranch("main"))
    }

    @Test func backendRecoverReviewDefaultsMissingReviewThreadToActiveThread() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-2"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = BackendReviewRun(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )

        let recovered = try await backend.recoverReview(
            run,
            request: .init(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                model: "gpt-5"
            ),
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )

        #expect(recovered.threadID == "thread-1")
        #expect(recovered.turnID == "turn-2")
        #expect(recovered.reviewThreadID == "thread-1")
    }

    @Test func backendSuppressesRecoveryInterruptTerminalEvent() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-2", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = BackendReviewRun(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: "gpt-5"
        )
        let events = await backend.events(for: run)
        var iterator = events.makeAsyncIterator()

        _ = try await backend.recoverReview(
            run,
            request: .init(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                model: "gpt-5"
            ),
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "thread-1",
                turn: .init(id: "turn-1", status: "interrupted", error: .init(message: "Network unavailable"))
            )
        )
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-2"))
        )

        #expect(try await iterator.next() == .started(
            turnID: "turn-2",
            reviewThreadID: "thread-1",
            model: nil
        ))
    }

    @Test func backendRecoverReviewDoesNotReinterruptPreviouslyInterruptedTurn() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-2", reviewThreadID: "thread-1"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = BackendReviewRun(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: "gpt-5"
        )
        let events = await backend.events(for: run)
        var iterator = events.makeAsyncIterator()

        try await backend.interruptReviewForRecovery(
            run,
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "thread-1",
                turn: .init(id: "turn-1", status: "interrupted", error: .init(message: "Network unavailable"))
            )
        )
        let suppressedTerminal = await waitUntil {
            await backend.reviewEventSessionMetricsForTesting(threadID: "thread-1")?.ignored == 1
        }
        #expect(suppressedTerminal)

        let recovered = try await backend.recoverReview(
            run,
            request: .init(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                model: "gpt-5"
            ),
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )

        #expect(recovered.turnID == "turn-2")
        let requests = await transport.recordedRequests()
        #expect(requests.map(\.method) == [
            "initialize",
            "turn/interrupt",
            "thread/rollback",
            "review/start",
        ])
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-2"))
        )
        #expect(try await iterator.next() == .started(
            turnID: "turn-2",
            reviewThreadID: "thread-1",
            model: nil
        ))
    }

    @Test func backendCancelAfterRecoveryInterruptDoesNotReinterruptStoppedTurn() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = BackendReviewRun(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: "gpt-5"
        )
        let events = await backend.events(for: run)
        var iterator = events.makeAsyncIterator()

        try await backend.interruptReviewForRecovery(
            run,
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "thread-1",
                turn: .init(id: "turn-1", status: "interrupted", error: .init(message: "Network unavailable"))
            )
        )
        let suppressedTerminal = await waitUntil {
            await backend.reviewEventSessionMetricsForTesting(threadID: "thread-1")?.ignored == 1
        }
        #expect(suppressedTerminal)

        try await backend.interruptReview(run, reason: .init(message: "Stop"))

        #expect(try await iterator.next() == .cancelled("Stop"))
        #expect(try await iterator.next() == nil)
        let interruptRequests = await transport.recordedRequests().filter { $0.method == "turn/interrupt" }
        #expect(interruptRequests.count == 1)
    }

    @Test func backendDoesNotSuppressCompletedRecoveryTurn() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = BackendReviewRun(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: "gpt-5"
        )
        let events = await backend.events(for: run)
        var iterator = events.makeAsyncIterator()

        try await backend.interruptReviewForRecovery(
            run,
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "thread-1",
                turn: .init(id: "turn-1", status: "completed"),
                result: "finished review"
            )
        )

        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "finished review"))
        #expect(try await iterator.next() == nil)
        #expect(await backend.reviewEventSessionMetricsForTesting(threadID: "thread-1")?.ignored == 0)
    }

    @Test func backendCancelDuringFailingRecoveryInterruptStillInterruptsTurn() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        await transport.enqueueFailure(
            .responseError(code: -32000, message: "network unavailable"),
            for: "turn/interrupt"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let interruptGate = AsyncGate()
        await transport.hold(method: "turn/interrupt", gate: interruptGate)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = BackendReviewRun(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: "gpt-5"
        )
        let events = await backend.events(for: run)
        var iterator = events.makeAsyncIterator()

        async let recovery: Void = backend.interruptReviewForRecovery(
            run,
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )
        let recoveryInterruptRequested = await waitUntil {
            await transport.recordedRequests().filter { $0.method == "turn/interrupt" }.count == 1
        }
        #expect(recoveryInterruptRequested)

        async let cancellation: Void = backend.interruptReview(run, reason: .init(message: "Stop"))
        let cancellationInterruptRequested = await waitUntil {
            await transport.recordedRequests().filter { $0.method == "turn/interrupt" }.count == 2
        }
        #expect(cancellationInterruptRequested)

        await interruptGate.open()
        do {
            try await recovery
            Issue.record("Expected recovery interrupt to fail.")
        } catch {}
        try await cancellation

        #expect(try await iterator.next() == .cancelled("Stop"))
        #expect(try await iterator.next() == nil)
        let interruptRequests = await transport.recordedRequests().filter { $0.method == "turn/interrupt" }
        #expect(interruptRequests.count == 2)
    }

    @Test func backendSuppressesRecoveryInterruptRetriedToActiveTurn() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        await transport.enqueueFailure(
            .responseError(
                code: -32602,
                message: "expected active turn id turn-old but found turn-active"
            ),
            for: "turn/interrupt"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = BackendReviewRun(
            threadID: "thread-1",
            turnID: "turn-old",
            reviewThreadID: "thread-1",
            model: "gpt-5"
        )
        let events = await backend.events(for: run)

        try await backend.interruptReviewForRecovery(
            run,
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )
        let requests = await transport.recordedRequests()
        let interruptRequests = requests.filter { $0.method == "turn/interrupt" }
        let interruptTurnIDs = try interruptRequests.map { request in
            try JSONDecoder().decode(TurnInterruptParams.self, from: request.params).turnID
        }
        #expect(interruptTurnIDs == ["turn-old", "turn-active"])

        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "thread-1",
                turn: .init(id: "turn-active", status: "interrupted", error: .init(message: "Network unavailable"))
            )
        )
        let suppressedTerminal = await waitUntil {
            await backend.reviewEventSessionMetricsForTesting(threadID: "thread-1")?.ignored == 1
        }
        #expect(suppressedTerminal)
        _ = events
    }

    @Test func backendSuppressesActiveTurnTerminalWhileRecoveryRetryInterruptIsInFlight() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        await transport.enqueueFailure(
            .responseError(
                code: -32602,
                message: "expected active turn id turn-old but found turn-active"
            ),
            for: "turn/interrupt"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let firstInterruptGate = AsyncGate()
        await firstInterruptGate.open()
        let retryInterruptGate = AsyncGate()
        await transport.holdNext(method: "turn/interrupt", gate: firstInterruptGate)
        await transport.holdNext(method: "turn/interrupt", gate: retryInterruptGate)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = BackendReviewRun(
            threadID: "thread-1",
            turnID: "turn-old",
            reviewThreadID: "thread-1",
            model: "gpt-5"
        )
        let events = await backend.events(for: run)

        async let recovery: Void = backend.interruptReviewForRecovery(
            run,
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )
        let retryInterruptRequested = await waitUntil {
            await transport.recordedRequests().filter { $0.method == "turn/interrupt" }.count == 2
        }
        #expect(retryInterruptRequested)

        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(
                threadID: "thread-1",
                turn: .init(id: "turn-active", status: "interrupted", error: .init(message: "Network unavailable"))
            )
        )
        let suppressedTerminal = await waitUntil {
            await backend.reviewEventSessionMetricsForTesting(threadID: "thread-1")?.ignored == 1
        }
        #expect(suppressedTerminal)

        await retryInterruptGate.open()
        try await recovery
        _ = events
    }

    @Test func backendRecoveryBuffersFastTerminalNotificationUntilRecoveredRunIsTracked() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-2", reviewThreadID: "thread-1"), for: "review/start")
        let reviewStartGate = AsyncGate()
        await transport.hold(method: "review/start", gate: reviewStartGate)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = BackendReviewRun(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: "gpt-5"
        )
        let events = await backend.events(for: run)
        var iterator = events.makeAsyncIterator()

        async let recovered = backend.recoverReview(
            run,
            request: BackendReviewStart(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                model: "gpt-5"
            ),
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )
        await transport.waitForRequestCount(4)
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-2", status: "completed"))
        )
        let bufferedFastTerminal = await waitUntil {
            await backend.reviewEventSessionMetricsForTesting(threadID: "thread-1")?.buffered == 1
        }
        #expect(bufferedFastTerminal)

        await reviewStartGate.open()
        let recoveredRun = try await recovered

        #expect(recoveredRun.turnID == "turn-2")
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: nil))
    }

    @Test func backendBuffersStaleInterruptedTurnNotificationsWhileRollbackIsInFlight() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-2", reviewThreadID: "thread-1"), for: "review/start")
        let rollbackGate = AsyncGate()
        await transport.holdNext(method: "thread/rollback", gate: rollbackGate)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = BackendReviewRun(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: "gpt-5"
        )
        let events = await backend.events(for: run)
        var iterator = events.makeAsyncIterator()

        async let recovered = backend.recoverReview(
            run,
            request: BackendReviewStart(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                model: "gpt-5"
            ),
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )
        let rollbackRequested = await waitUntil {
            await transport.recordedRequests().contains { $0.method == "thread/rollback" }
        }
        #expect(rollbackRequested)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "swift test")
            )
        )
        let bufferedStaleNotification = await waitUntil {
            await backend.reviewEventSessionMetricsForTesting(threadID: "thread-1")?.buffered == 1
        }
        #expect(bufferedStaleNotification)

        await rollbackGate.open()
        let recoveredRun = try await recovered
        #expect(recoveredRun.turnID == "turn-2")

        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-2"))
        )
        #expect(try await iterator.next() == .started(
            turnID: "turn-2",
            reviewThreadID: "thread-1",
            model: nil
        ))
    }

    @Test func backendRecoveryClearsInterruptedCommandStateBeforeReplayingRecoveredTurn() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-2", reviewThreadID: "thread-1"), for: "review/start")
        let reviewStartGate = AsyncGate()
        await transport.hold(method: "review/start", gate: reviewStartGate)
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = BackendReviewRun(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1",
            model: "gpt-5"
        )
        let events = await backend.events(for: run)
        var iterator = events.makeAsyncIterator()

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "swift test")
            )
        )
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ swift test",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-1",
                command: "swift test",
                commandStatus: "inProgress"
            )
        ))
        try await transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "cmd-1",
                delta: "old output"
            )
        )

        async let recovered = backend.recoverReview(
            run,
            request: BackendReviewStart(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                model: "gpt-5"
            ),
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )
        await transport.waitForRequestCount(4)
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "enteredReviewMode", id: "stale-review", review: "stale changes")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/started",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-2"))
        )

        await reviewStartGate.open()
        let recoveredRun = try await recovered

        #expect(recoveredRun.turnID == "turn-2")
        #expect(try await iterator.next() == .started(turnID: "turn-2", reviewThreadID: "thread-1", model: nil))
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-2", status: "completed"))
        )
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: nil))
    }

    @Test func backendCleanupDeletesAllRecoveryReviewThreads() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueInitialize(transport)
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-2", reviewThreadID: "review-thread-2"), for: "review/start")
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = BackendReviewRun(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )

        let recovered = try await backend.recoverReview(
            run,
            request: .init(
                jobID: "job-1",
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                model: "gpt-5"
            ),
            reason: .init(message: "Network unavailable; waiting to reconnect.")
        )
        await backend.cleanupReview(recovered)

        let deleteThreadIDs = try await transport.recordedRequests()
            .filter { $0.method == "thread/delete" }
            .map { request in
                try JSONDecoder().decode(ThreadDeleteParams.self, from: request.params).threadID
            }
        #expect(deleteThreadIDs == [
            "review-thread-1",
            "review-thread-2",
            "thread-1",
        ])
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
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-new",
                item: .init(type: "enteredReviewMode", id: "review-item-1", review: "current changes")
            )
        )
        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: TestDeltaNotification(threadID: "thread-1", turnID: "turn-new", itemID: "message-1", delta: " hello")
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
        #expect(try await iterator.next() == .messageDelta(" hello", itemID: "message-1"))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "final review text",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "final review text"))
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
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-new",
                item: .init(type: "enteredReviewMode", id: "review-item-1", review: "current changes")
            )
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
        #expect(try await iterator.next() == .messageDelta(" current", itemID: "message-1"))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "final review text",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "final review text"))
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
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-new",
                item: .init(type: "enteredReviewMode", id: "review-item-1", review: "current changes")
            )
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
            kind: .agentMessage,
            text: "final review text",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "final review text"))
    }

    @Test func backendDoesNotCloseIgnoredTurnCommandLifecycleOnTrackedCompletion() async throws {
        let run = BackendReviewRun(threadID: "thread-1", turnID: "turn-current")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await backend.events(for: run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-ignored",
                item: .init(type: "commandExecution", id: "cmd-ignored", command: "git diff")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: TestTurnNotification(threadID: "thread-1", turn: .init(id: "turn-current", status: "completed"))
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: nil))
        #expect(try await iterator.next() == nil)
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

    @Test func backendWaitsForDetailedFailureAfterSystemErrorStatus() async throws {
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
            params: TestThreadStatusNotification(threadID: "thread-1", status: .init(type: "systemError"))
        )
        try await transport.emitServerNotification(
            method: "error",
            params: TestErrorNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                message: "Detailed failure",
                willRetry: false
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .logEntry(
            kind: .diagnostic,
            text: "Review thread entered a system error state.",
            groupID: nil,
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .failed("Detailed failure"))
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

    @Test func backendInterruptClosesActiveCommandLifecycle() async throws {
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
        let startedAtMs: Int64 = 1_700_000_000_000
        let startedAt = Date(timeIntervalSince1970: TimeInterval(startedAtMs) / 1_000)
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "git diff"),
                startedAtMs: startedAtMs
            )
        )

        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ git diff",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-1",
                command: "git diff",
                startedAt: startedAt,
                commandStatus: "inProgress"
            )
        ))

        try await backend.interruptReview(run, reason: .init(message: "Stop"))

        guard case .logEntry(let kind, let text, let groupID, let replacesGroup, let metadata) = try await iterator.next()
        else {
            Issue.record("Expected active command to be closed before cancellation.")
            return
        }
        #expect(kind == .command)
        #expect(text == "$ git diff")
        #expect(groupID == "cmd-1")
        #expect(replacesGroup == true)
        #expect(metadata?.sourceType == "commandExecution")
        #expect(metadata?.status == "canceled")
        #expect(metadata?.itemID == "cmd-1")
        #expect(metadata?.command == "git diff")
        #expect(metadata?.startedAt == startedAt)
        #expect(metadata?.completedAt != nil)
        #expect(metadata?.durationMs != nil)
        #expect(metadata?.commandStatus == "canceled")
        #expect(try await iterator.next() == .cancelled("Stop"))
        #expect(try await iterator.next() == nil)
    }

    @Test func backendInterruptClosesActiveCommandOutputLifecycle() async throws {
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
        let startedAtMs: Int64 = 1_700_000_000_000
        let startedAt = Date(timeIntervalSince1970: TimeInterval(startedAtMs) / 1_000)
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "git status"),
                startedAtMs: startedAtMs
            )
        )
        try await transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "cmd-1",
                delta: " M README.md\n"
            )
        )
        try await transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "cmd-1",
                delta: "?? Sources/New.swift\n"
            )
        )

        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        _ = try await iterator.next()

        let routedOutput = await waitUntil {
            await backend.reviewEventSessionMetricsForTesting(threadID: "thread-1")?.routed ?? 0 >= 3
        }
        #expect(routedOutput)

        try await backend.interruptReview(run, reason: .init(message: "Stop"))

        var sawClosedOutput = false
        while let event = try await iterator.next() {
            if case .cancelled("Stop") = event {
                break
            }
            guard case .logEntry(let kind, let text, let groupID, let replacesGroup, let metadata) = event,
                  kind == .commandOutput,
                  replacesGroup
            else {
                continue
            }
            sawClosedOutput = true
            #expect(text == " M README.md\n?? Sources/New.swift\n")
            #expect(groupID == "cmd-1")
            #expect(metadata?.sourceType == "commandExecution")
            #expect(metadata?.status == "canceled")
            #expect(metadata?.itemID == "cmd-1")
            #expect(metadata?.command == "git status")
            #expect(metadata?.startedAt == startedAt)
            #expect(metadata?.completedAt != nil)
            #expect(metadata?.durationMs != nil)
            #expect(metadata?.commandStatus == "canceled")
        }
        #expect(sawClosedOutput)
        #expect(try await iterator.next() == nil)
    }

    @Test func backendCoalescesReasoningSummaryDeltasBeforeNextEvent() async throws {
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
            method: "item/reasoning/summaryTextDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "reasoning-1",
                delta: "Need to "
            )
        )
        try await transport.emitServerNotification(
            method: "item/reasoning/summaryTextDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "reasoning-1",
                delta: "inspect logs."
            )
        )
        try await transport.emitServerNotification(
            method: "log",
            params: TestMessageNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                message: "Continuing."
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .reasoningSummary,
            text: "Need to inspect logs.",
            groupID: "reasoning-1:summary:0",
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .log("Continuing."))
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
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "final review text"))
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
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "final review text"))
    }

    @Test func backendKeepsReviewResponseTurnWhenAuxiliaryTurnStarts() async throws {
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
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-1",
                command: "swift test",
                commandStatus: "inProgress"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .commandOutput,
            text: "Tests",
            groupID: "cmd-1",
            replacesGroup: false,
            metadata: .init(sourceType: "commandExecution", title: "Command output", itemID: "cmd-1")
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ swift test",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "completed",
                itemID: "cmd-1",
                command: "swift test",
                commandStatus: "completed"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .commandOutput,
            text: "Tests passed",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "completed",
                itemID: "cmd-1",
                command: "swift test",
                commandStatus: "completed"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ pwd",
            groupID: "cmd-2",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-2",
                command: "pwd",
                commandStatus: "inProgress"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ pwd",
            groupID: "cmd-2",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "completed",
                itemID: "cmd-2",
                command: "pwd",
                commandStatus: "completed"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .toolCall,
            text: "MCP codex_review.review_read started.",
            groupID: "tool-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "mcpToolCall",
                title: "codex_review.review_read",
                status: "started",
                server: "codex_review",
                tool: "review_read"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .toolCall,
            text: "Reading review job",
            groupID: "tool-1",
            replacesGroup: false,
            metadata: .init(sourceType: "mcpToolCall", title: "Tool progress")
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .toolCall,
            text: "codex_review.review_read completed. Result: ok",
            groupID: "tool-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "mcpToolCall",
                title: "codex_review.review_read",
                status: "completed",
                server: "codex_review",
                tool: "review_read",
                resultText: "ok"
            )
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
            kind: .contextCompaction,
            text: "Automatically compacting context",
            groupID: "compact-1",
            replacesGroup: true,
            metadata: .init(sourceType: "contextCompaction", status: "inProgress", itemID: "compact-1")
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .contextCompaction,
            text: "Context automatically compacted",
            groupID: "compact-1",
            replacesGroup: true,
            metadata: .init(sourceType: "contextCompaction", status: "completed", itemID: "compact-1")
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
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "final review text"))
    }

    @Test func backendPreservesCommandLifecycleMetadata() async throws {
        let run = BackendReviewRun(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await backend.events(for: run)
        let startedAtMs: Int64 = 1_700_000_000_000
        let completedAtMs: Int64 = startedAtMs + 3_456

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    type: "commandExecution",
                    id: "cmd-1",
                    command: "cat Sources/ThreadItem.ts",
                    commandActions: [
                        .read(command: "cat Sources/ThreadItem.ts", name: "ThreadItem.ts", path: "Sources/ThreadItem.ts")
                    ],
                    status: "inProgress"
                ),
                startedAtMs: startedAtMs
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    type: "commandExecution",
                    id: "cmd-1",
                    aggregatedOutput: "file contents",
                    exitCode: 0,
                    durationMs: 3_000
                ),
                completedAtMs: completedAtMs
            )
        )

        let startedAt = Date(timeIntervalSince1970: TimeInterval(startedAtMs) / 1_000)
        let completedAt = Date(timeIntervalSince1970: TimeInterval(completedAtMs) / 1_000)
        let action = ReviewLogEntry.Metadata.CommandAction(
            kind: .read,
            command: "cat Sources/ThreadItem.ts",
            name: "ThreadItem.ts",
            path: "Sources/ThreadItem.ts"
        )
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ cat Sources/ThreadItem.ts",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-1",
                command: "cat Sources/ThreadItem.ts",
                startedAt: startedAt,
                commandActions: [action],
                commandStatus: "inProgress"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ cat Sources/ThreadItem.ts",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "succeeded",
                itemID: "cmd-1",
                command: "cat Sources/ThreadItem.ts",
                exitCode: 0,
                startedAt: startedAt,
                completedAt: completedAt,
                durationMs: 3_000,
                commandActions: [action],
                commandStatus: "succeeded"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .commandOutput,
            text: "file contents",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "succeeded",
                itemID: "cmd-1",
                command: "cat Sources/ThreadItem.ts",
                exitCode: 0,
                startedAt: startedAt,
                completedAt: completedAt,
                durationMs: 3_000,
                commandActions: [action],
                commandStatus: "succeeded"
            )
        ))
    }

    @Test func backendDerivesFailedCommandDurationWhenCompletedItemReportsZero() async throws {
        let run = BackendReviewRun(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await backend.events(for: run)
        let startedAtMs: Int64 = 1_700_000_000_000
        let completedAtMs: Int64 = startedAtMs + 10_007

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    type: "commandExecution",
                    id: "cmd-failed",
                    command: "git diff -- Sources/CodexReview"
                ),
                startedAtMs: startedAtMs
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    type: "commandExecution",
                    id: "cmd-failed",
                    command: "git diff -- Sources/CodexReview",
                    aggregatedOutput: "execution error: No such process",
                    exitCode: -1,
                    durationMs: 0,
                    status: "failed"
                ),
                completedAtMs: completedAtMs
            )
        )

        let startedAt = Date(timeIntervalSince1970: TimeInterval(startedAtMs) / 1_000)
        let completedAt = Date(timeIntervalSince1970: TimeInterval(completedAtMs) / 1_000)
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ git diff -- Sources/CodexReview",
            groupID: "cmd-failed",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-failed",
                command: "git diff -- Sources/CodexReview",
                startedAt: startedAt,
                commandStatus: "inProgress"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ git diff -- Sources/CodexReview",
            groupID: "cmd-failed",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "failed",
                itemID: "cmd-failed",
                command: "git diff -- Sources/CodexReview",
                exitCode: -1,
                startedAt: startedAt,
                completedAt: completedAt,
                durationMs: 10_007,
                commandStatus: "failed"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .commandOutput,
            text: "execution error: No such process",
            groupID: "cmd-failed",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "failed",
                itemID: "cmd-failed",
                command: "git diff -- Sources/CodexReview",
                exitCode: -1,
                startedAt: startedAt,
                completedAt: completedAt,
                durationMs: 10_007,
                commandStatus: "failed"
            )
        ))
    }

    @Test func backendPreservesContextCompactionLifecycleMetadata() async throws {
        let run = BackendReviewRun(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await backend.events(for: run)
        let startedAtMs: Int64 = 1_700_000_000_000
        let completedAtMs: Int64 = startedAtMs + 2_000

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "contextCompaction", id: "compact-1"),
                startedAtMs: startedAtMs
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "contextCompaction", id: "compact-1"),
                completedAtMs: completedAtMs
            )
        )

        let startedAt = Date(timeIntervalSince1970: TimeInterval(startedAtMs) / 1_000)
        let completedAt = Date(timeIntervalSince1970: TimeInterval(completedAtMs) / 1_000)
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .contextCompaction,
            text: "Automatically compacting context",
            groupID: "compact-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "contextCompaction",
                status: "inProgress",
                itemID: "compact-1",
                startedAt: startedAt
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .contextCompaction,
            text: "Context automatically compacted",
            groupID: "compact-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "contextCompaction",
                status: "completed",
                itemID: "compact-1",
                completedAt: completedAt
            )
        ))
    }

    @Test func backendPreservesFailedContextCompactionCompletionStatus() async throws {
        let run = BackendReviewRun(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await backend.events(for: run)
        let completedAtMs: Int64 = 1_700_000_002_000

        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    type: "contextCompaction",
                    id: "compact-1",
                    status: "failed",
                    error: "compaction failed"
                ),
                completedAtMs: completedAtMs
            )
        )

        let completedAt = Date(timeIntervalSince1970: TimeInterval(completedAtMs) / 1_000)
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .contextCompaction,
            text: "Context compaction failed",
            groupID: "compact-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "contextCompaction",
                status: "failed",
                itemID: "compact-1",
                completedAt: completedAt,
                errorText: "compaction failed"
            )
        ))
    }

    @Test func backendMapsDeprecatedThreadCompactedToCompletedContextCompactionMarker() async throws {
        let run = BackendReviewRun(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await backend.events(for: run)

        try await transport.emitServerNotification(
            method: "thread/compacted",
            params: TestContextCompactedNotification(threadID: "thread-1", turnID: "turn-1")
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .contextCompaction,
            text: "Context automatically compacted",
            groupID: "contextCompaction:turn-1",
            replacesGroup: true,
            metadata: .init(sourceType: "contextCompaction", status: "completed")
        ))
    }

    @Test func backendFallsBackCommandDurationToLifecycleDates() async throws {
        let run = BackendReviewRun(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await backend.events(for: run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "swift test"),
                startedAtMs: 2_000
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "swift test"),
                completedAtMs: 5_250
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ swift test",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-1",
                command: "swift test",
                startedAt: Date(timeIntervalSince1970: 2),
                commandStatus: "inProgress"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ swift test",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "completed",
                itemID: "cmd-1",
                command: "swift test",
                startedAt: Date(timeIntervalSince1970: 2),
                completedAt: Date(timeIntervalSince1970: 5.25),
                durationMs: 3_250,
                commandStatus: "completed"
            )
        ))
    }

    @Test func backendCompletesStreamedCommandOutputWhenCompletionHasNoAggregatedOutput() async throws {
        let run = BackendReviewRun(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await backend.events(for: run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "swift test"),
                startedAtMs: 2_000
            )
        )
        try await transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "cmd-1",
                delta: " Tests passed\n"
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "swift test", exitCode: 0),
                completedAtMs: 5_250
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ swift test",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-1",
                command: "swift test",
                startedAt: Date(timeIntervalSince1970: 2),
                commandStatus: "inProgress"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .commandOutput,
            text: " Tests passed\n",
            groupID: "cmd-1",
            replacesGroup: false,
            metadata: .init(sourceType: "commandExecution", title: "Command output", itemID: "cmd-1")
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ swift test",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "succeeded",
                itemID: "cmd-1",
                command: "swift test",
                exitCode: 0,
                startedAt: Date(timeIntervalSince1970: 2),
                completedAt: Date(timeIntervalSince1970: 5.25),
                durationMs: 3_250,
                commandStatus: "succeeded"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .commandOutput,
            text: " Tests passed\n",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "succeeded",
                itemID: "cmd-1",
                command: "swift test",
                exitCode: 0,
                startedAt: Date(timeIntervalSince1970: 2),
                completedAt: Date(timeIntervalSince1970: 5.25),
                durationMs: 3_250,
                commandStatus: "succeeded"
            )
        ))
    }

    @Test func backendFlushesPendingStreamedCommandOutputBeforeNotificationStreamFinishes() async throws {
        let run = BackendReviewRun(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await backend.events(for: run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "swift test"),
                startedAtMs: 2_000
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ swift test",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-1",
                command: "swift test",
                startedAt: Date(timeIntervalSince1970: 2),
                commandStatus: "inProgress"
            )
        ))

        try await transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "cmd-1",
                delta: "tail output\n"
            )
        )
        await transport.close()

        #expect(try await iterator.next() == .logEntry(
            kind: .commandOutput,
            text: "tail output\n",
            groupID: "cmd-1",
            replacesGroup: false,
            metadata: .init(sourceType: "commandExecution", title: "Command output", itemID: "cmd-1")
        ))
        #expect(try await iterator.next() == nil)
    }

    @Test func backendReviewExitCompletesMissingCommandCompletion() async throws {
        let run = BackendReviewRun(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await backend.events(for: run)

        let startedAtMs: Int64 = 2_000
        let startedAt = Date(timeIntervalSince1970: 2)
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "enteredReviewMode", id: "review-item-1", review: "current changes")
            )
        )
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "git diff"),
                startedAtMs: startedAtMs
            )
        )
        try await transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "cmd-1",
                delta: " M README.md\n"
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

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .progress,
            text: "Reviewing current changes",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ git diff",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-1",
                command: "git diff",
                startedAt: startedAt,
                commandStatus: "inProgress"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .commandOutput,
            text: " M README.md\n",
            groupID: "cmd-1",
            replacesGroup: false,
            metadata: .init(sourceType: "commandExecution", title: "Command output", itemID: "cmd-1")
        ))
        guard case .logEntry(let kind, let text, let groupID, let replacesGroup, let metadata) = try await iterator.next()
        else {
            Issue.record("Expected review exit to close the active command execution.")
            return
        }
        #expect(kind == .command)
        #expect(text == "$ git diff")
        #expect(groupID == "cmd-1")
        #expect(replacesGroup == true)
        #expect(metadata?.sourceType == "commandExecution")
        #expect(metadata?.status == "completed")
        #expect(metadata?.itemID == "cmd-1")
        #expect(metadata?.command == "git diff")
        #expect(metadata?.startedAt == startedAt)
        #expect(metadata?.completedAt != nil)
        #expect(metadata?.durationMs != nil)
        #expect(metadata?.commandStatus == "completed")
        guard case .logEntry(let outputKind, let outputText, let outputGroupID, let outputReplacesGroup, let outputMetadata) = try await iterator.next()
        else {
            Issue.record("Expected review exit to close the active command output.")
            return
        }
        #expect(outputKind == .commandOutput)
        #expect(outputText == " M README.md\n")
        #expect(outputGroupID == "cmd-1")
        #expect(outputReplacesGroup == true)
        #expect(outputMetadata?.sourceType == "commandExecution")
        #expect(outputMetadata?.status == "completed")
        #expect(outputMetadata?.itemID == "cmd-1")
        #expect(outputMetadata?.command == "git diff")
        #expect(outputMetadata?.startedAt == startedAt)
        #expect(outputMetadata?.completedAt != nil)
        #expect(outputMetadata?.durationMs != nil)
        #expect(outputMetadata?.commandStatus == "completed")
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "final review text",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "final review text"))
        #expect(try await iterator.next() == nil)
    }

    @Test func backendClosesMissingCommandCompletionBeforeFollowingReasoning() async throws {
        let run = BackendReviewRun(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await backend.events(for: run)

        let startedAt = Date(timeIntervalSince1970: 2)
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "git diff"),
                startedAtMs: 2_000
            )
        )
        try await transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "cmd-1",
                delta: "diff output\n"
            )
        )
        try await transport.emitServerNotification(
            method: "item/reasoning/summaryTextDelta",
            params: TestDeltaNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "reasoning-1",
                delta: "Inspecting diffs"
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

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ git diff",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-1",
                command: "git diff",
                startedAt: startedAt,
                commandStatus: "inProgress"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .commandOutput,
            text: "diff output\n",
            groupID: "cmd-1",
            replacesGroup: false,
            metadata: .init(sourceType: "commandExecution", title: "Command output", itemID: "cmd-1")
        ))
        guard case .logEntry(let commandKind, _, let commandGroupID, let commandReplacesGroup, let commandMetadata) = try await iterator.next()
        else {
            Issue.record("Expected following reasoning to close the active command execution.")
            return
        }
        #expect(commandKind == .command)
        #expect(commandGroupID == "cmd-1")
        #expect(commandReplacesGroup == true)
        #expect(commandMetadata?.status == "completed")
        #expect(commandMetadata?.itemID == "cmd-1")
        #expect(commandMetadata?.startedAt == startedAt)
        #expect(commandMetadata?.completedAt != nil)
        guard case .logEntry(let outputKind, let outputText, let outputGroupID, let outputReplacesGroup, let outputMetadata) = try await iterator.next()
        else {
            Issue.record("Expected following reasoning to close the active command output.")
            return
        }
        #expect(outputKind == .commandOutput)
        #expect(outputText == "diff output\n")
        #expect(outputGroupID == "cmd-1")
        #expect(outputReplacesGroup == true)
        #expect(outputMetadata?.status == "completed")
        #expect(outputMetadata?.itemID == "cmd-1")
        #expect(outputMetadata?.completedAt != nil)
        #expect(try await iterator.next() == .logEntry(
            kind: .reasoningSummary,
            text: "Inspecting diffs",
            groupID: "reasoning-1:summary:0",
            replacesGroup: false
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .agentMessage,
            text: "final review text",
            groupID: "review-item-1",
            replacesGroup: true
        ))
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "final review text"))
        #expect(try await iterator.next() == nil)
    }

    @Test func backendIgnoresEmptyCommandTerminalInteractionPolls() async throws {
        let run = BackendReviewRun(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await backend.events(for: run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "git diff")
            )
        )
        try await transport.emitServerNotification(
            method: "item/commandExecution/terminalInteraction",
            params: TestTerminalInteractionNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "cmd-1",
                processID: "123",
                stdin: ""
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "commandExecution", id: "cmd-1", command: "git diff")
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ git diff",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "inProgress",
                itemID: "cmd-1",
                command: "git diff",
                commandStatus: "inProgress"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .command,
            text: "$ git diff",
            groupID: "cmd-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "commandExecution",
                status: "completed",
                itemID: "cmd-1",
                command: "git diff",
                commandStatus: "completed"
            )
        ))
    }

    @Test func backendCarriesRichToolAndFileMetadata() async throws {
        let run = BackendReviewRun(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await backend.events(for: run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "webSearch", id: "web-1", query: "TextKit 2 markdown")
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "imageView", id: "image-1", status: "completed", path: "/tmp/screenshot.png")
            )
        )
        try await transport.emitServerNotification(
            method: "item/started",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "fileChange", id: "file-1", path: "Sources/App.swift")
            )
        )
        try await transport.emitServerNotification(
            method: "item/fileChange/patchUpdated",
            params: TestMessageNotification(threadID: "thread-1", turnID: "turn-1", itemID: "file-1", message: "patch")
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "hookPrompt", id: "hook-1", status: "completed", prompt: "Allow command?")
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .toolCall,
            text: "Web search: TextKit 2 markdown",
            groupID: "web-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "webSearch",
                title: "Web search",
                status: "started",
                query: "TextKit 2 markdown"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .toolCall,
            text: "Image viewed: /tmp/screenshot.png.",
            groupID: "image-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "imageView",
                title: "Image view",
                status: "completed",
                path: "/tmp/screenshot.png"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .toolCall,
            text: "Applying file changes.",
            groupID: "file-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "fileChange",
                title: "File changes",
                status: "started",
                path: "Sources/App.swift"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .toolCall,
            text: "File changes updated.",
            groupID: "file-1",
            replacesGroup: false,
            metadata: .init(sourceType: "fileChange", title: "File changes", status: "updated")
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .event,
            text: "Hook prompt completed.",
            groupID: "hook-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "hookPrompt",
                title: "Hook prompt",
                status: "completed",
                detail: "Allow command?"
            )
        ))
    }

    @Test func backendMarksErroredToolCompletionsAsFailedMetadata() async throws {
        let run = BackendReviewRun(threadID: "thread-1", turnID: "turn-1")
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let events = await backend.events(for: run)

        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    type: "mcpToolCall",
                    id: "tool-error",
                    server: "codex_review",
                    tool: "review_read",
                    error: "denied"
                )
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: TestItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(
                    type: "dynamicToolCall",
                    id: "tool-success-false",
                    namespace: "web",
                    tool: "search",
                    result: "no matches",
                    success: false
                )
            )
        )

        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == .started(turnID: "turn-1", reviewThreadID: "thread-1", model: nil))
        #expect(try await iterator.next() == .logEntry(
            kind: .toolCall,
            text: "codex_review.review_read completed. Error: denied",
            groupID: "tool-error",
            replacesGroup: true,
            metadata: .init(
                sourceType: "mcpToolCall",
                title: "codex_review.review_read",
                status: "failed",
                server: "codex_review",
                tool: "review_read",
                errorText: "denied"
            )
        ))
        #expect(try await iterator.next() == .logEntry(
            kind: .toolCall,
            text: "Dynamic tool web.search completed. Result: no matches",
            groupID: "tool-success-false",
            replacesGroup: true,
            metadata: .init(
                sourceType: "dynamicToolCall",
                title: "web.search",
                status: "failed",
                namespace: "web",
                tool: "search",
                resultText: "no matches"
            )
        ))
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
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "final review text"))
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
        #expect(try await iterator.next() == .completed(summary: "Succeeded.", result: "final review text"))
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
            "thread/delete",
        ])
    }

    private func waitUntil(timeout: Duration = .seconds(2), condition: () async -> Bool) async -> Bool {
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
    var result: String? = nil

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
        case reviewThreadID = "reviewThreadId"
        case result
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

private struct TestContextCompactedNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
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

private struct TestTerminalInteractionNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var processID: String
    var stdin: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case processID = "processId"
        case stdin
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
    var startedAtMs: Int64?
    var completedAtMs: Int64?

    init(
        threadID: String,
        turnID: String,
        item: TestItem,
        startedAtMs: Int64? = nil,
        completedAtMs: Int64? = nil
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.item = item
        self.startedAtMs = startedAtMs
        self.completedAtMs = completedAtMs
    }

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case item
        case startedAtMs
        case completedAtMs
    }
}

private struct TestItem: Encodable, Sendable {
    var type: String
    var id: String
    var review: String?
    var command: String?
    var cwd: String?
    var processID: String?
    var source: String?
    var aggregatedOutput: String?
    var exitCode: Int?
    var durationMs: Int?
    var commandActions: [TestCommandAction]?
    var status: String?
    var namespace: String?
    var server: String?
    var tool: String?
    var query: String?
    var path: String?
    var result: String?
    var error: String?
    var success: Bool?
    var prompt: String?
    var summary: [String]?
    var content: [String]?

    init(
        type: String,
        id: String,
        review: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        processID: String? = nil,
        source: String? = nil,
        aggregatedOutput: String? = nil,
        exitCode: Int? = nil,
        durationMs: Int? = nil,
        commandActions: [TestCommandAction]? = nil,
        status: String? = nil,
        namespace: String? = nil,
        server: String? = nil,
        tool: String? = nil,
        query: String? = nil,
        path: String? = nil,
        result: String? = nil,
        error: String? = nil,
        success: Bool? = nil,
        prompt: String? = nil,
        summary: [String]? = nil,
        content: [String]? = nil
    ) {
        self.type = type
        self.id = id
        self.review = review
        self.command = command
        self.cwd = cwd
        self.processID = processID
        self.source = source
        self.aggregatedOutput = aggregatedOutput
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.commandActions = commandActions
        self.status = status
        self.namespace = namespace
        self.server = server
        self.tool = tool
        self.query = query
        self.path = path
        self.result = result
        self.error = error
        self.success = success
        self.prompt = prompt
        self.summary = summary
        self.content = content
    }
}

private struct TestCommandAction: Encodable, Sendable {
    var type: String
    var command: String
    var name: String?
    var path: String?
    var query: String?

    init(
        type: String,
        command: String,
        name: String? = nil,
        path: String? = nil,
        query: String? = nil
    ) {
        self.type = type
        self.command = command
        self.name = name
        self.path = path
        self.query = query
    }

    static func read(command: String, name: String, path: String) -> Self {
        .init(type: "read", command: command, name: name, path: path)
    }

    static func search(command: String, query: String?, path: String?) -> Self {
        .init(type: "search", command: command, path: path, query: query)
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

private struct TestGlobalMessageNotification: Encodable, Sendable {
    var message: String
}

private struct TestErrorNotification: Encodable, Sendable {
    var threadID: String? = nil
    var turnID: String? = nil
    var message: String
    var willRetry: Bool

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case message
        case willRetry
    }
}
