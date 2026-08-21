import Foundation
import AppKit
import AuthenticationServices
import Testing
import CodexReview
import CodexReviewAppServer
import CodexReviewHost
import CodexReviewMCPServer
import CodexReviewTesting

@Suite("host composition")
@MainActor
struct CodexReviewHostTests {
    @Test func hostStartsAndStopsRuntimeWithFakeBackend() async throws {
        let backend = FakeCodexReviewBackend()
        let host = CodexReviewHost(
            backend: backend,
            endpoint: URL(string: "http://localhost:9417/mcp")
        )

        await host.start()
        #expect(host.store.serverState == .running)
        #expect(host.store.serverURL == URL(string: "http://localhost:9417/mcp"))

        try await host.stop()
        #expect(host.store.serverState == .stopped)
    }

    @Test func hostStartLoadsSettingsBeforeStandaloneReviews() async throws {
        let backend = FakeCodexReviewBackend(settings: .init(model: "gpt-5.5"))
        let host = CodexReviewHost(backend: backend)

        await host.start()
        let reviewTask = Task { @MainActor in
            try await host.store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await backend.waitForStartReview()

        let commands = await backend.recordedCommands()
        #expect(Array(commands.prefix(2)) == [.readAuth, .readSettings])
        let startReview = try #require(commands.compactMap { command -> CodexReviewBackendModel.Review.Start? in
            if case .startReview(let request) = command {
                request
            } else {
                nil
            }
        }.first)
        #expect(startReview.model == "gpt-5.5")

        await backend.yield(.completed(summary: "Succeeded.", result: nil))
        await backend.finishEvents()
        _ = try await reviewTask.value
    }

    @Test func hostStartPreservesBackendAccountID() async {
        let backend = FakeCodexReviewBackend(auth: .init(
            accounts: [
                .init(id: .init("review@example.com"), label: "review@example.com", isActive: true),
            ],
            activeAccountID: .init("review@example.com")
        ))
        let host = CodexReviewHost(backend: backend)

        await host.start()
        await host.store.refreshAuthentication()

        #expect(host.store.auth.selectedAccount?.accountKey == "review@example.com")
        #expect(host.store.auth.selectedAccount?.email == "review@example.com")
        #expect(host.store.auth.persistedActiveAccountKey == "review@example.com")
    }

    @Test func hostStoreCloseOwnsDirectAppServerShutdown() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(
            AppServerAPI.Model.List.Response(data: []),
            for: "model/list"
        )
        let host = CodexReviewHost(appServerTransport: transport)

        await host.start()
        try await host.store.close()
        try await host.store.close()
        await host.start(endpoint: URL(string: "http://localhost:19425/mcp"))

        #expect(await transport.closeCallCountForTesting() == 1)
        #expect(host.store.serverState == .stopped)
        #expect(host.store.serverURL == nil)
    }

    @Test func directPreparationFailureRetainsShutdownFailureForStoreClose() async throws {
        let backend = FakeCodexReviewBackend()
        await backend.failAuthRead(message: "auth read failed")
        let host = CodexReviewHost(
            backend: backend,
            shutdown: {
                throw ReviewLifecycleResourceFailure.client("direct shutdown failed")
            }
        )

        await host.start()
        let closeError = try #require(await captureStoreCloseError(host.store))

        guard case .lifecycleResources(let lifecycle) = closeError.failures.first else {
            Issue.record("Direct preparation cleanup must remain a lifecycle failure.")
            return
        }
        #expect(lifecycle.first == .client("direct shutdown failed"))
    }

    @Test func liveStoreCloseReplaysAppServerOwnerFailureOnce() async throws {
        let homeURL = try temporaryHome()
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(
            AppServerAPI.Model.List.Response(data: []),
            for: "model/list"
        )
        await transport.failClose(with: .connection("close failed"))
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: nil,
            transportFactory: { _ in transport }
        )
        await store.start()

        let firstError = await captureStoreCloseError(store)
        let secondError = await captureStoreCloseError(store)

        #expect(firstError?.localizedDescription == secondError?.localizedDescription)
        #expect(await transport.closeCallCountForTesting() == 1)
        let closeError = try #require(firstError)
        guard case .lifecycleResources(let lifecycle) = closeError.failures.first else {
            Issue.record("AppServer owner close failure must remain a lifecycle failure.")
            return
        }
        guard case .client(let message) = lifecycle.first else {
            Issue.record("AppServer connection close must map to client lifecycle failure.")
            return
        }
        #expect(message.contains("close failed"))
    }

    @Test func livePreparationFailureRetainsAppServerCleanupFailureForStoreClose() async throws {
        let homeURL = try temporaryHome()
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        await transport.enqueueFailure(
            .responseError(code: -32_000, message: "auth read failed"),
            for: "account/read"
        )
        await transport.failClose(with: .connection("preparation cleanup failed"))
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: nil,
            transportFactory: { _ in transport }
        )

        await store.start()
        let closeError = try #require(await captureStoreCloseError(store))

        #expect(await transport.closeCallCountForTesting() == 1)
        #expect(closeError.failures.additionalInLifecycleOrder.isEmpty)
        guard case .lifecycleResources(let lifecycle) = closeError.failures.first else {
            Issue.record("Live preparation cleanup must remain a lifecycle failure.")
            return
        }
        guard case .client(let message) = lifecycle.first else {
            Issue.record("Live preparation client close must retain its resource kind.")
            return
        }
        #expect(message.contains("preparation cleanup failed"))
    }

    @Test func runtimePreferencesNormalizeInvalidValues() {
        let preferences = CodexReviewRuntime.Preferences(
            codexHomePath: "  ",
            mcpHost: "\n",
            mcpPort: 0,
            mcpPath: "custom-mcp",
            codexExecutablePath: "\t"
        )

        #expect(preferences.codexHomePath == nil)
        #expect(preferences.mcpHost == "localhost")
        #expect(preferences.mcpPort == 9417)
        #expect(preferences.mcpPath == "/custom-mcp")
        #expect(preferences.codexExecutablePath == nil)
    }

    @Test func runtimePreferencesDefaultInvalidMCPHosts() {
        for host in [
            "::1",
            "[::1]",
            "localhost:9417",
            "http://localhost",
            "256.256.256.256",
            "-foo",
            "..",
        ] {
            let preferences = CodexReviewRuntime.Preferences(mcpHost: host)
            #expect(preferences.mcpHost == "localhost")
        }
    }

    @Test func runtimePreferencesKeepValidMCPHosts() {
        for host in ["localhost", "127.0.0.1", "0.0.0.0", "example.com", "xn--bcher-kva.de"] {
            let preferences = CodexReviewRuntime.Preferences(mcpHost: host)
            #expect(preferences.mcpHost == host)
        }
    }

    @Test func runtimePreferencesDefaultEscapedMCPPaths() {
        for path in ["custom mcp", "/custom?mcp", "/custom#mcp", "/custom%20mcp"] {
            let preferences = CodexReviewRuntime.Preferences(mcpPath: path)
            #expect(preferences.mcpPath == "/mcp")
        }
    }

    @Test func runtimePreferencesDefaultRelativePaths() {
        let preferences = CodexReviewRuntime.Preferences(
            codexHomePath: "tmp/home",
            codexExecutablePath: "codex"
        )

        #expect(preferences.codexHomePath == nil)
        #expect(preferences.codexExecutablePath == nil)
    }

    @Test func runtimePreferencesExpandHomeRelativePaths() {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let preferences = CodexReviewRuntime.Preferences(
            codexHomePath: " ~/.codex_review ",
            codexExecutablePath: " ~/bin/codex "
        )

        #expect(preferences.codexHomePath == "\(homePath)/.codex_review")
        #expect(preferences.codexExecutablePath == "\(homePath)/bin/codex")

        let homeOnlyPreferences = CodexReviewRuntime.Preferences(codexHomePath: "~")
        #expect(homeOnlyPreferences.codexHomePath == homePath)
    }

    @Test func userDefaultsRuntimePreferencesStoreRoundTripsNormalizedPreferences() throws {
        let suiteName = "CodexReviewRuntime.PreferencesStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = CodexReviewRuntime.UserDefaultsPreferencesStore(defaults: defaults)

        try store.save(.init(
            codexHomePath: " /tmp/codex-review-home ",
            mcpHost: " ",
            mcpPort: -1,
            mcpPath: "custom-mcp",
            codexExecutablePath: " /tmp/codex "
        ))

        #expect(store.load() == .init(
            codexHomePath: "/tmp/codex-review-home",
            mcpHost: "localhost",
            mcpPort: 9417,
            mcpPath: "/custom-mcp",
            codexExecutablePath: "/tmp/codex"
        ))
    }

    @Test func liveStoreUsesRuntimePreferenceCodexHome() async throws {
        let homeURL = try temporaryHome()
        let configuredCodexHomeURL = homeURL.appendingPathComponent("custom-codex-home", isDirectory: true)
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            runtimePreferences: .init(codexHomePath: configuredCodexHomeURL.path),
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transportFactory: { codexHomeURL in
                #expect(codexHomeURL == configuredCodexHomeURL)
                return transport
            }
        )

        await store.start(forceRestartIfNeeded: true)

        #expect(store.serverState == .running)
        await store.stop()
    }

    @Test func liveStorePassesRuntimePreferenceMCPPortAndPathToHTTPServerFactory() async throws {
        let homeURL = try temporaryHome()
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        var capturedConfiguration: CodexReviewMCPHTTPServer.Configuration?
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            runtimePreferences: .init(
                mcpPort: 54321,
                mcpPath: "custom-mcp"
            ),
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: { store, configuration in
                capturedConfiguration = configuration
                return CodexReviewMCPHTTPServer(
                    adapter: CodexReviewMCPServer(store: store),
                    configuration: .init(
                        host: configuration.host,
                        port: 0,
                        endpoint: configuration.endpoint
                    )
                )
            },
            mcpHTTPServerBindChecker: { _ in },
            transportFactory: { _ in transport }
        )

        await store.start(forceRestartIfNeeded: true)
        let serverURL = try #require(store.serverURL)

        #expect(capturedConfiguration?.port == 54321)
        #expect(capturedConfiguration?.endpoint == "/custom-mcp")
        #expect(serverURL.path == "/custom-mcp")
        #expect(serverURL.port != 0)
        await store.stop()
    }

    @Test func liveStoreStopThenStartRebindsMCPWithStableOwner() async throws {
        let homeURL = try temporaryHome()
        let firstTransport = FakeJSONRPCTransport()
        let secondTransport = FakeJSONRPCTransport()
        for transport in [firstTransport, secondTransport] {
            try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
            try await transport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
            try await transport.enqueue(
                AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
                for: "config/read"
            )
            try await transport.enqueue(
                AppServerAPI.Model.List.Response(data: []),
                for: "model/list"
            )
        }
        var transports = [firstTransport, secondTransport]
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: { store, configuration in
                CodexReviewMCPHTTPServer(
                    adapter: CodexReviewMCPServer(store: store),
                    configuration: .init(
                        host: configuration.host,
                        port: 0,
                        endpoint: configuration.endpoint
                    )
                )
            },
            mcpHTTPServerBindChecker: { _ in },
            transportFactory: { _ in transports.removeFirst() }
        )

        await store.start()
        let firstURL = try #require(store.serverURL)
        #expect(firstURL.port != 0)

        await store.stop()
        #expect(store.serverState == .stopped)

        await store.start()
        let secondURL = try #require(store.serverURL)
        #expect(secondURL.port != 0)
        #expect(store.serverState == .running)
        #expect(transports.isEmpty)

        await store.stop()
    }

    @Test func liveStoreRestartReplacesOnlyAppServerAndRetainsMCPListener() async throws {
        let homeURL = try temporaryHome()
        let firstTransport = FakeJSONRPCTransport()
        let secondTransport = FakeJSONRPCTransport()
        for transport in [firstTransport, secondTransport] {
            try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
            try await transport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
            try await transport.enqueue(
                AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
                for: "config/read"
            )
            try await transport.enqueue(
                AppServerAPI.Model.List.Response(data: []),
                for: "model/list"
            )
        }
        var transports = [firstTransport, secondTransport]
        var mcpServerFactoryCallCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: { store, configuration in
                mcpServerFactoryCallCount += 1
                return CodexReviewMCPHTTPServer(
                    adapter: CodexReviewMCPServer(store: store),
                    configuration: .init(
                        host: configuration.host,
                        port: 0,
                        endpoint: configuration.endpoint
                    )
                )
            },
            mcpHTTPServerBindChecker: { _ in },
            transportFactory: { _ in transports.removeFirst() }
        )

        await store.start()
        let initialURL = try #require(store.serverURL)

        await store.restart()

        #expect(store.serverState == .running)
        #expect(store.serverURL == initialURL)
        #expect(initialURL.port != 0)
        #expect(mcpServerFactoryCallCount == 1)
        #expect(transports.isEmpty)

        await store.stop()
    }

    @Test func liveGraceForceCloseResumesSiblingOnlyOnReplacementBackend() async throws {
        let homeURL = try temporaryHome()
        let firstTransport = FakeJSONRPCTransport()
        try await firstTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await firstTransport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
        try await firstTransport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await firstTransport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        try await firstTransport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-target", model: "gpt-5"),
            for: "thread/start"
        )
        try await firstTransport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "turn-target",
                reviewThreadID: "review-target"
            ),
            for: "review/start"
        )
        try await firstTransport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-sibling", model: "gpt-5"),
            for: "thread/start"
        )
        try await firstTransport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "turn-sibling",
                reviewThreadID: "review-sibling"
            ),
            for: "review/start"
        )
        try await firstTransport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await firstTransport.enqueue(EmptyResponse(), for: "turn/interrupt")

        let secondTransport = FakeJSONRPCTransport()
        try await secondTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await secondTransport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
        try await secondTransport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await secondTransport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        try await secondTransport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await secondTransport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "turn-sibling-recovered",
                reviewThreadID: "review-sibling"
            ),
            for: "review/start"
        )

        let mcpServer = ControlledMCPHTTPServer(
            endpoint: try #require(URL(string: "http://127.0.0.1:19432/mcp"))
        )
        var transports = [firstTransport, secondTransport]
        var mcpFactoryCallCount = 0
        let routingProbe = HostRecoveryRoutingProbe()
        let jobIDs = HostSequentialIDs(["job-target", "job-sibling"])
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: { _, _ in
                mcpFactoryCallCount += 1
                return mcpServer
            },
            mcpHTTPServerBindChecker: { _ in },
            reviewRuntimeClosePolicy: .init(
                terminalGrace: .seconds(10),
                sleep: { _ in }
            ),
            idGenerator: .init(next: { jobIDs.next() }),
            reviewRecoveryRoutingObserver: { event in
                routingProbe.record(event)
            },
            transportFactory: { _ in transports.removeFirst() }
        )
        await store.start()
        let initialURL = store.serverURL
        let targetTask = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-target",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        _ = await store.waitForRuntimeReplacementRegistrationForTesting(
            jobID: "job-target"
        )
        let siblingTask = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-sibling",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        _ = await store.waitForRuntimeReplacementRegistrationForTesting(
            jobID: "job-sibling"
        )

        let cancellation = Task { @MainActor in
            try await store.cancelReview(
                jobID: "job-target",
                cancellation: .mcpClient(message: "Stop target")
            )
        }
        await secondTransport.waitForRequest(method: "review/start")
        try await secondTransport.emitServerNotification(
            method: "item/completed",
            params: HostCompletedReviewItemNotification(
                threadID: "review-sibling",
                turnID: "turn-sibling-recovered",
                result: "replacement result"
            )
        )
        try await secondTransport.emitServerNotification(
            method: "turn/completed",
            params: HostCompletedReviewTurnNotification(
                threadID: "review-sibling",
                turnID: "turn-sibling-recovered",
                result: "replacement result"
            )
        )

        let target = try await targetTask.value
        let sibling = try await siblingTask.value
        #expect(try await cancellation.value.cancelled)
        #expect(target.core.lifecycle.terminal == .interrupted(
            .requested(.mcpClient(message: "Stop target"))
        ))
        #expect(sibling.core.lifecycle.status == .succeeded)
        #expect(sibling.core.run.turnID == "turn-sibling-recovered")
        #expect(store.serverURL == initialURL)
        #expect(mcpFactoryCallCount == 1)
        #expect(mcpServer.startCallCount == 1)
        #expect(transports.isEmpty)
        let oldMethods = await firstTransport.recordedRequests().map(\.method)
        let newMethods = await secondTransport.recordedRequests().map(\.method)
        #expect(oldMethods.filter { $0 == "review/start" }.count == 2)
        #expect(oldMethods.contains("thread/rollback") == false)
        #expect(newMethods.filter { $0 == "review/start" }.count == 1)
        #expect(newMethods.contains("thread/rollback"))
        #expect(routingProbe.events == [
            .staged(
                sourceAttemptID: routingProbe.sourceAttemptID,
                recoveredAttemptID: routingProbe.recoveredAttemptID
            ),
            .committed(
                sourceAttemptID: routingProbe.sourceAttemptID,
                recoveredAttemptID: routingProbe.recoveredAttemptID
            ),
        ])

        await store.stop()
    }

    @Test func liveHeldRecoveryResumeIsDiscardedWhenStopWins() async throws {
        try await exerciseHeldRecoveryResumeDiscard(applicationClose: false)
    }

    @Test func liveHeldRecoveryResumeIsDiscardedWhenCloseWins() async throws {
        try await exerciseHeldRecoveryResumeDiscard(applicationClose: true)
    }

    private func exerciseHeldRecoveryResumeDiscard(
        applicationClose: Bool
    ) async throws {
        let homeURL = try temporaryHome()
        let firstTransport = FakeJSONRPCTransport()
        try await firstTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await firstTransport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
        try await firstTransport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await firstTransport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        try await firstTransport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-target", model: "gpt-5"),
            for: "thread/start"
        )
        try await firstTransport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "turn-target",
                reviewThreadID: "review-target"
            ),
            for: "review/start"
        )
        try await firstTransport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-sibling", model: "gpt-5"),
            for: "thread/start"
        )
        try await firstTransport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "turn-sibling",
                reviewThreadID: "review-sibling"
            ),
            for: "review/start"
        )
        try await firstTransport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await firstTransport.enqueue(EmptyResponse(), for: "turn/interrupt")

        let secondTransport = FakeJSONRPCTransport()
        let recoveredStartGate = AsyncGate()
        await secondTransport.holdNextIgnoringCancellation(
            method: "review/start",
            gate: recoveredStartGate
        )
        try await secondTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await secondTransport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
        try await secondTransport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await secondTransport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        try await secondTransport.enqueue(EmptyResponse(), for: "thread/rollback")
        try await secondTransport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "turn-sibling-recovered",
                reviewThreadID: "review-sibling"
            ),
            for: "review/start"
        )
        try await secondTransport.enqueue(EmptyResponse(), for: "turn/interrupt")

        let mcpServer = ControlledMCPHTTPServer(
            endpoint: try #require(URL(string: "http://127.0.0.1:19436/mcp"))
        )
        let routingProbe = HostRecoveryRoutingProbe()
        var transports = [firstTransport, secondTransport]
        let jobIDs = HostSequentialIDs(["job-target", "job-sibling"])
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: { _, _ in mcpServer },
            mcpHTTPServerBindChecker: { _ in },
            reviewRuntimeClosePolicy: .init(
                terminalGrace: .seconds(10),
                sleep: { _ in }
            ),
            idGenerator: .init(next: { jobIDs.next() }),
            reviewRecoveryRoutingObserver: { event in
                routingProbe.record(event)
            },
            transportFactory: { _ in transports.removeFirst() }
        )
        await store.start()
        let targetTask = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-target",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        _ = await store.waitForRuntimeReplacementRegistrationForTesting(
            jobID: "job-target"
        )
        let siblingTask = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-sibling",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        _ = await store.waitForRuntimeReplacementRegistrationForTesting(
            jobID: "job-sibling"
        )
        let targetCancellation = Task { @MainActor in
            try await store.cancelReview(
                jobID: "job-target",
                cancellation: .mcpClient(message: "Stop target")
            )
        }
        await secondTransport.waitForRequest(method: "review/start")

        let cancellationBarrierEntered = AsyncGate()
        store.setReviewCancellationBarrierPreparationForTesting {
            await cancellationBarrierEntered.open()
        }
        let shutdownTask = Task { @MainActor in
            do {
                if applicationClose {
                    try await store.close()
                } else {
                    await store.stop()
                }
                return Result<Void, any Error>.success(())
            } catch {
                return Result<Void, any Error>.failure(error)
            }
        }
        await cancellationBarrierEntered.wait()
        await recoveredStartGate.open()
        await secondTransport.waitForRequest(method: "turn/interrupt")
        try await shutdownTask.value.get()
        let target = try await targetTask.value
        let sibling = try await siblingTask.value
        _ = try await targetCancellation.value

        let expectedSiblingCancellation: ReviewCancellation = applicationClose
            ? .system(message: "Review Store closed.")
            : .system(message: "Review runtime stopped.")
        #expect(target.core.lifecycle.terminal == .interrupted(
            .requested(.mcpClient(message: "Stop target"))
        ))
        #expect(sibling.core.lifecycle.terminal == .interrupted(
            .requested(expectedSiblingCancellation)
        ))
        #expect(sibling.core.run.turnID == "turn-sibling")
        #expect(store.reviewWorkerTasks.isEmpty)
        #expect(store.activeRuntimeReplacementReceiptCountForTesting == 0)
        let oldMethods = await firstTransport.recordedRequests().map(\.method)
        let newMethods = await secondTransport.recordedRequests().map(\.method)
        #expect(oldMethods.contains("thread/rollback") == false)
        #expect(newMethods.contains("thread/rollback"))
        #expect(newMethods.filter { $0 == "review/start" }.count == 1)
        #expect(newMethods.contains("turn/interrupt"))
        #expect(routingProbe.events == [
            .staged(
                sourceAttemptID: routingProbe.sourceAttemptID,
                recoveredAttemptID: routingProbe.recoveredAttemptID
            ),
            .discarded(
                sourceAttemptID: routingProbe.sourceAttemptID,
                recoveredAttemptID: routingProbe.recoveredAttemptID
            ),
        ])
        #expect(await secondTransport.closeCallCountForTesting() == 1)
        #expect(store.serverState == .stopped)
        #expect(store.serverURL == nil)
    }

    @Test func liveMCPOwnerStopDuringPreparationJoinsAndAllowsLaterStart() async throws {
        let homeURL = try temporaryHome()
        let preparationStarted = AsyncGate()
        let preparationCancelled = AsyncGate()
        let preparationRelease = AsyncGate()
        let server = ControlledMCPHTTPServer(
            endpoint: try #require(URL(string: "http://127.0.0.1:19418/mcp"))
        )
        let lifecycleCalls = MCPLifecycleCallProbe()
        var factoryCallCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: { _, _ in
                factoryCallCount += 1
                return server
            },
            mcpHTTPServerBindChecker: { _ in
                await preparationStarted.open()
                await withTaskCancellationHandler {
                    await preparationRelease.waitIgnoringCancellation()
                } onCancel: {
                    Task { await preparationCancelled.open() }
                }
            },
            mcpLifecycleCallObserver: { call, count in
                lifecycleCalls.record(call, count: count)
            },
            transportFactory: { _ in FakeJSONRPCTransport() }
        )
        let owner = store.backend.mcpServerLifecycle

        let prepareTask = Task { try await owner.prepare() }
        await preparationStarted.wait()
        let firstStop = Task { try await owner.stop() }
        await preparationCancelled.wait()
        let secondStop = Task { try await owner.stop() }
        await lifecycleCalls.waitFor(.stop, count: 2)

        #expect(factoryCallCount == 0)
        await preparationRelease.open()
        await #expect(throws: ReviewLifecycleResourceFailure.self) {
            _ = try await prepareTask.value
        }
        try await firstStop.value
        try await secondStop.value
        try await owner.waitUntilStopped()
        #expect(factoryCallCount == 0)

        let prepared = try await owner.prepare()
        let repeatedPreparation = try await owner.prepare()
        let snapshot = try await owner.activate(prepared.generation)
        let repeatedSnapshot = try await owner.activate(prepared.generation)
        let serverURL = await server.url
        #expect(repeatedPreparation.generation == prepared.generation)
        #expect(snapshot.serverURL == serverURL)
        #expect(repeatedSnapshot.serverURL == snapshot.serverURL)
        #expect(factoryCallCount == 1)
        #expect(server.startCallCount == 1)
        try await owner.stop()
        try await owner.waitUntilStopped()
    }

    @Test func liveStoreStopSignalsHeldMCPPreparationBeforeJoiningAcquisition() async throws {
        let homeURL = try temporaryHome()
        let preparationStarted = AsyncGate()
        let preparationCancelled = AsyncGate()
        let preparationRelease = AsyncGate()
        var mcpFactoryCallCount = 0
        var appServerFactoryCallCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: { _, configuration in
                mcpFactoryCallCount += 1
                return NoopMCPHTTPServer(endpoint: configuration.url())
            },
            mcpHTTPServerBindChecker: { _ in
                await preparationStarted.open()
                await withTaskCancellationHandler {
                    await preparationRelease.waitIgnoringCancellation()
                } onCancel: {
                    Task { await preparationCancelled.open() }
                }
            },
            transportFactory: { _ in
                appServerFactoryCallCount += 1
                return FakeJSONRPCTransport()
            }
        )

        let startTask = Task { @MainActor in
            await store.start()
        }
        await preparationStarted.wait()
        let stopFinished = CompletionFlag()
        let stopTask = Task { @MainActor in
            await store.stop()
            await stopFinished.complete()
        }
        await preparationCancelled.wait()

        #expect(await stopFinished.isCompleted() == false)
        #expect(mcpFactoryCallCount == 0)
        #expect(appServerFactoryCallCount == 0)

        await preparationRelease.open()
        await stopTask.value
        await startTask.value

        #expect(await stopFinished.isCompleted())
        #expect(store.serverState == .stopped)
        #expect(store.serverURL == nil)
        #expect(mcpFactoryCallCount == 0)
        #expect(appServerFactoryCallCount == 0)
    }

    @Test func liveStoreStopSignalsHeldMCPActivationBeforeJoiningAcquisition() async throws {
        let homeURL = try temporaryHome()
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(
            AppServerAPI.Model.List.Response(data: []),
            for: "model/list"
        )
        let activationRelease = AsyncGate()
        let server = ControlledMCPHTTPServer(
            endpoint: try #require(URL(string: "http://127.0.0.1:19424/mcp"))
        )
        server.holdStart(with: activationRelease)
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: { _, _ in server },
            mcpHTTPServerBindChecker: { _ in },
            transportFactory: { _ in transport }
        )

        let startTask = Task { @MainActor in
            await store.start()
        }
        await server.waitForStart()
        let stopFinished = CompletionFlag()
        let stopTask = Task { @MainActor in
            await store.stop()
            await stopFinished.complete()
        }
        await server.waitForStartCancellation()

        #expect(await stopFinished.isCompleted() == false)
        #expect(store.serverURL == nil)
        #expect(server.stopCallCount == 0)

        await activationRelease.open()
        await stopTask.value
        await startTask.value

        #expect(await stopFinished.isCompleted())
        #expect(store.serverState == .stopped)
        #expect(store.serverURL == nil)
        #expect(server.stopCallCount == 1)
    }

    @Test func liveMCPOwnerJoinerCancellationDoesNotCancelSharedOperations() async throws {
        let homeURL = try temporaryHome()
        let preparationStarted = AsyncGate()
        let preparationRelease = AsyncGate()
        let activationRelease = AsyncGate()
        let server = ControlledMCPHTTPServer(
            endpoint: try #require(URL(string: "http://127.0.0.1:19423/mcp"))
        )
        server.holdStart(with: activationRelease)
        var bindCheckCallCount = 0
        var factoryCallCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: { _, _ in
                factoryCallCount += 1
                return server
            },
            mcpHTTPServerBindChecker: { _ in
                bindCheckCallCount += 1
                await preparationStarted.open()
                await preparationRelease.waitIgnoringCancellation()
            },
            transportFactory: { _ in FakeJSONRPCTransport() }
        )
        let owner = store.backend.mcpServerLifecycle

        let firstPreparation = Task { try await owner.prepare() }
        await preparationStarted.wait()
        let secondPreparation = Task { try await owner.prepare() }
        firstPreparation.cancel()
        await preparationRelease.open()
        let firstPrepared = try await firstPreparation.value
        let secondPrepared = try await secondPreparation.value

        #expect(firstPrepared.generation == secondPrepared.generation)
        #expect(bindCheckCallCount == 1)
        #expect(factoryCallCount == 1)

        let firstActivation = Task {
            try await owner.activate(firstPrepared.generation)
        }
        await server.waitForStart()
        let secondActivation = Task {
            try await owner.activate(firstPrepared.generation)
        }
        firstActivation.cancel()
        await activationRelease.open()
        let firstSnapshot = try await firstActivation.value
        let secondSnapshot = try await secondActivation.value

        #expect(firstSnapshot.serverURL == secondSnapshot.serverURL)
        #expect(server.startCallCount == 1)
        try await owner.stop()
    }

    @Test func liveMCPOwnerStopDuringActivationJoinsAndStartsNewLeaseLater() async throws {
        let homeURL = try temporaryHome()
        let firstServer = ControlledMCPHTTPServer(
            endpoint: try #require(URL(string: "http://127.0.0.1:19419/mcp"))
        )
        let secondServer = ControlledMCPHTTPServer(
            endpoint: try #require(URL(string: "http://127.0.0.1:19420/mcp"))
        )
        let lifecycleCalls = MCPLifecycleCallProbe()
        let activationRelease = AsyncGate()
        firstServer.holdStart(with: activationRelease)
        var servers = [firstServer, secondServer]
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: { _, _ in servers.removeFirst() },
            mcpHTTPServerBindChecker: { _ in },
            mcpLifecycleCallObserver: { call, count in
                lifecycleCalls.record(call, count: count)
            },
            transportFactory: { _ in FakeJSONRPCTransport() }
        )
        let owner = store.backend.mcpServerLifecycle
        let prepared = try await owner.prepare()
        let activationTask = Task {
            try await owner.activate(prepared.generation)
        }
        await firstServer.waitForStart()

        let firstStop = Task { try await owner.stop() }
        await firstServer.waitForStartCancellation()
        let secondStop = Task { try await owner.stop() }
        await lifecycleCalls.waitFor(.stop, count: 2)
        #expect(firstServer.stopCallCount == 0)

        await activationRelease.open()
        await #expect(throws: ReviewLifecycleResourceFailure.self) {
            _ = try await activationTask.value
        }
        try await firstStop.value
        try await secondStop.value
        try await owner.waitUntilStopped()
        #expect(firstServer.stopCallCount == 1)

        let nextPrepared = try await owner.prepare()
        let nextSnapshot = try await owner.activate(nextPrepared.generation)
        let repeatedSnapshot = try await owner.activate(nextPrepared.generation)
        let secondServerURL = await secondServer.url
        #expect(nextPrepared.generation != prepared.generation)
        #expect(nextSnapshot.serverURL == secondServerURL)
        #expect(repeatedSnapshot.serverURL == nextSnapshot.serverURL)
        #expect(secondServer.startCallCount == 1)
        #expect(servers.isEmpty)
        try await owner.stop()
    }

    @Test func liveMCPOwnerCloseDuringActivationJoinsAndPreventsLatePublication() async throws {
        let homeURL = try temporaryHome()
        let server = ControlledMCPHTTPServer(
            endpoint: try #require(URL(string: "http://127.0.0.1:19421/mcp"))
        )
        let lifecycleCalls = MCPLifecycleCallProbe()
        let activationRelease = AsyncGate()
        server.holdStart(with: activationRelease)
        var factoryCallCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: { _, _ in
                factoryCallCount += 1
                return server
            },
            mcpHTTPServerBindChecker: { _ in },
            mcpLifecycleCallObserver: { call, count in
                lifecycleCalls.record(call, count: count)
            },
            transportFactory: { _ in FakeJSONRPCTransport() }
        )
        let owner = store.backend.mcpServerLifecycle
        let prepared = try await owner.prepare()
        let activationTask = Task {
            try await owner.activate(prepared.generation)
        }
        await server.waitForStart()

        let firstClose = Task { try await owner.close() }
        await server.waitForStartCancellation()
        let secondClose = Task { try await owner.close() }
        await lifecycleCalls.waitFor(.close, count: 2)
        #expect(server.stopCallCount == 0)

        await activationRelease.open()
        await #expect(throws: ReviewLifecycleResourceFailure.self) {
            _ = try await activationTask.value
        }
        try await firstClose.value
        try await secondClose.value
        try await owner.waitUntilClosed()
        #expect(server.stopCallCount == 1)
        #expect(factoryCallCount == 1)
        await #expect(throws: ReviewLifecycleResourceFailure.self) {
            _ = try await owner.prepare()
        }
    }

    @Test func liveStoreReportsMCPPortOwnerWhenEndpointPortInUseAndDoesNotLaunchAppServer() async throws {
        let homeURL = try temporaryHome()
        let port = 54321

        var didLaunchAppServer = false
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            runtimePreferences: .init(mcpHost: "127.0.0.1", mcpPort: port),
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: { _, configuration in
                NoopMCPHTTPServer(endpoint: configuration.url())
            },
            mcpPortOwnerResolver: { configuration in
                #expect(configuration.port == port)
                return .init(
                    processIdentifier: 98695,
                    command: "/Applications/CodexReviewMonitor.app/Contents/MacOS/CodexReviewMonitor"
                )
            },
            mcpHTTPServerBindChecker: { configuration in
                throw CodexReviewMCPHTTPServer.Error.addressInUse(
                    host: configuration.host,
                    port: configuration.port
                )
            },
            transportFactory: { _ in
                didLaunchAppServer = true
                return FakeJSONRPCTransport()
            }
        )

        await store.start(forceRestartIfNeeded: true)

        #expect(didLaunchAppServer == false)
        guard case .failed(let message) = store.serverState else {
            Issue.record("Expected failed server state.")
            return
        }
        #expect(message.contains("MCP endpoint http://127.0.0.1:\(port)/mcp is already in use by PID 98695"))
        #expect(message.contains("/Applications/CodexReviewMonitor.app/Contents/MacOS/CodexReviewMonitor"))
        #expect(message.contains("Quit that process or change the MCP port in Settings"))
    }

    @Test func liveStoreReportsMCPPortInUseWhenOwnerCannotBeResolved() async throws {
        let homeURL = try temporaryHome()
        let port = 54322

        var didLaunchAppServer = false
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            runtimePreferences: .init(mcpHost: "127.0.0.1", mcpPort: port),
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: { _, configuration in
                NoopMCPHTTPServer(endpoint: configuration.url())
            },
            mcpPortOwnerResolver: { _ in nil },
            mcpHTTPServerBindChecker: { configuration in
                throw CodexReviewMCPHTTPServer.Error.addressInUse(
                    host: configuration.host,
                    port: configuration.port
                )
            },
            transportFactory: { _ in
                didLaunchAppServer = true
                return FakeJSONRPCTransport()
            }
        )

        await store.start(forceRestartIfNeeded: true)

        #expect(didLaunchAppServer == false)
        guard case .failed(let message) = store.serverState else {
            Issue.record("Expected failed server state.")
            return
        }
        #expect(message.contains("MCP endpoint http://127.0.0.1:\(port)/mcp is already in use."))
        #expect(message.contains("by PID") == false)
    }

    @Test func liveStoreLoadsPersistedRegistryAccountKind() throws {
        let homeURL = try temporaryHome()
        try writeRegistryRecords(
            homeURL: homeURL,
            activeAccountKey: nil,
            records: [
                [
                    "accountKey": "review@example.com",
                    "kind": "chatgpt",
                    "email": "review@example.com",
                    "planType": "pro",
                ],
                [
                    "accountKey": "api-key",
                    "kind": "apiKey",
                    "email": "API Key",
                    "planType": "pro",
                ],
            ]
        )
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transport: FakeJSONRPCTransport()
        )

        let reviewAccount = try #require(store.auth.persistedAccounts.first {
            $0.accountKey == "review@example.com"
        })
        let providerAccount = try #require(store.auth.persistedAccounts.first {
            $0.accountKey == "api-key"
        })

        #expect(reviewAccount.kind == .chatGPT)
        #expect(reviewAccount.capabilities.supportsRateLimitRefresh)
        #expect(providerAccount.kind == .apiKey)
        #expect(providerAccount.capabilities.supportsRateLimitRefresh == false)
    }

    @Test func liveStoreInfersMissingPersistedRegistryKind() throws {
        let homeURL = try temporaryHome()
        try writeRegistryRecords(
            homeURL: homeURL,
            activeAccountKey: nil,
            records: [
                [
                    "accountKey": "review@example.com",
                    "email": "review@example.com",
                    "planType": "pro",
                ],
                [
                    "accountKey": "api-key",
                    "email": "API Key",
                    "planType": "pro",
                ],
                [
                    "accountKey": "amazon-bedrock",
                    "email": "Amazon Bedrock",
                    "planType": "pro",
                ],
            ]
        )
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transport: FakeJSONRPCTransport()
        )

        let reviewAccount = try #require(store.auth.persistedAccounts.first {
            $0.accountKey == "review@example.com"
        })
        let apiKeyAccount = try #require(store.auth.persistedAccounts.first {
            $0.accountKey == "api-key"
        })
        let bedrockAccount = try #require(store.auth.persistedAccounts.first {
            $0.accountKey == "amazon-bedrock"
        })

        #expect(reviewAccount.kind == .chatGPT)
        #expect(reviewAccount.capabilities.supportsRateLimitRefresh)
        #expect(apiKeyAccount.kind == .apiKey)
        #expect(apiKeyAccount.capabilities.supportsRateLimitRefresh == false)
        #expect(bedrockAccount.kind == .amazonBedrock)
        #expect(bedrockAccount.capabilities.supportsRateLimitRefresh == false)
    }

    @Test func liveStoreSkipsRateLimitRefreshForUnsupportedActiveAccount() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(
            TestAccountReadResponse(account: .init(type: "apiKey")),
            for: "account/read"
        )
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await transport.waitForRequestCount(4)
        await store.refreshAccountRateLimits(accountKey: "api-key")
        await Task.yield()

        #expect(store.auth.selectedAccount?.kind == .apiKey)
        #expect(await transport.recordedRequests().map(\.method) == [
            "initialize",
            "account/read",
            "config/read",
            "model/list",
        ])
    }

    @Test func liveStoreCancelsLoginWhenAuthenticationSessionIsClosed() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        try await transport.enqueue(
            AppServerAPI.Account.Login.Response.chatgpt(
                loginID: "login-1",
                authURL: "https://example.com/auth",
                nativeWebAuthentication: .init(callbackURLScheme: "lynnpd.CodexReviewMonitor.auth")
            ),
            for: "account/login/start"
        )
        try await transport.enqueue(AppServerAPI.Account.Login.Cancel.Response(), for: "account/login/cancel")
        let sessions = FakeWebAuthenticationSessions()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.CodexReviewMonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: sessions.makeSession,
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await store.addAccount()
        let session = await sessions.waitForSession()
        await session.waitUntilWaitingForCallback()
        #expect(store.auth.isAuthenticating)

        await session.closeFromAuthenticationWindow()
        await transport.waitForRequestCount(6)
        await waitUntil { store.auth.isAuthenticating == false }

        #expect(store.auth.isAuthenticating == false)
        #expect(store.auth.selectedAccount == nil)
        let methods = await transport.recordedRequests().map(\.method)
        #expect(methods == [
            "initialize",
            "account/read",
            "config/read",
            "model/list",
            "account/login/start",
            "account/login/cancel",
        ])
    }

    @Test func liveStoreCancelsLoginWhenAuthenticationSessionSetupFails() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        try await transport.enqueue(
            AppServerAPI.Account.Login.Response.chatgpt(
                loginID: "login-1",
                authURL: "https://example.com/auth",
                nativeWebAuthentication: .init(callbackURLScheme: "lynnpd.CodexReviewMonitor.auth")
            ),
            for: "account/login/start"
        )
        try await transport.enqueue(AppServerAPI.Account.Login.Cancel.Response(), for: "account/login/cancel")
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.CodexReviewMonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: { _, _, _, _ in
                throw CodexReviewAPI.Error.io("Authentication presentation failed.")
            },
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await store.addAccount()
        await transport.waitForRequestCount(6)

        #expect(failedMessage(from: store.auth.phase) == "Authentication presentation failed.")
        #expect(await transport.recordedRequests().map(\.method) == [
            "initialize",
            "account/read",
            "config/read",
            "model/list",
            "account/login/start",
            "account/login/cancel",
        ])
    }

    @Test func liveStoreAddsAccountWithoutSwitchingExistingActiveAccount() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let mainTransport = FakeJSONRPCTransport()
        try await mainTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await mainTransport.enqueue(
            AppServerAPI.Account.Read.Response(
                account: .init(email: "active@example.com", planType: "pro")
            ),
            for: "account/read"
        )
        try await mainTransport.enqueue(
            AppServerAPI.Account.RateLimits.Response(rateLimits: .init(
                limitID: "codex",
                primary: .init(usedPercent: 10, windowDurationMins: 300)
            )),
            for: "account/rateLimits/read"
        )
        try await mainTransport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await mainTransport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")

        let authTransport = FakeJSONRPCTransport()
        try await authTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await authTransport.enqueue(
            AppServerAPI.Account.Login.Response.chatgpt(
                loginID: "login-2",
                authURL: "https://example.com/auth",
                nativeWebAuthentication: nil
            ),
            for: "account/login/start"
        )
        try await authTransport.enqueue(
            AppServerAPI.Account.Read.Response(
                account: .init(email: "new@example.com", planType: "plus")
            ),
            for: "account/read"
        )
        try await authTransport.enqueue(
            AppServerAPI.Account.RateLimits.Response(rateLimits: .init(
                limitID: "codex",
                primary: .init(usedPercent: 25, windowDurationMins: 300)
            )),
            for: "account/rateLimits/read"
        )
        let refreshTransport = FakeJSONRPCTransport()
        let refreshGate = AsyncGate()
        await refreshTransport.hold(method: "account/rateLimits/read", gate: refreshGate)
        try await refreshTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await refreshTransport.enqueue(
            AppServerAPI.Account.Read.Response(
                account: .init(email: "new@example.com", planType: "plus")
            ),
            for: "account/read"
        )
        try await refreshTransport.enqueue(
            AppServerAPI.Account.RateLimits.Response(rateLimits: .init(
                limitID: "codex",
                primary: .init(usedPercent: 44, windowDurationMins: 300)
            )),
            for: "account/rateLimits/read"
        )
        var nonPrimaryTransports = [authTransport, refreshTransport]
        var nonPrimaryRuntimeIndex = 0
        var refreshCodexHomeURL: URL?
        let sessions = FakeWebAuthenticationSessions()
        let externalURLOpener = FakeExternalURLOpener()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.CodexReviewMonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: sessions.makeSession,
            externalURLOpener: externalURLOpener.open,
            transportFactory: { codexHomeURL in
                if codexHomeURL == mainCodexHomeURL {
                    return mainTransport
                }
                let runtimeIndex = nonPrimaryRuntimeIndex
                nonPrimaryRuntimeIndex += 1
                try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
                if runtimeIndex == 0 {
                    try Data("{\"tokens\":{\"id_token\":\"login-token\"}}".utf8)
                        .write(to: codexHomeURL.appendingPathComponent("auth.json"))
                } else {
                    refreshCodexHomeURL = codexHomeURL
                }
                return nonPrimaryTransports.removeFirst()
            }
        )

        await store.start(forceRestartIfNeeded: true)
        #expect(store.auth.selectedAccount?.accountKey == "active@example.com")

        await store.addAccount()
        let session = await sessions.waitForSession()
        await session.waitUntilWaitingForCallback()
        await authTransport.waitForNotificationStreamCount(1)
        #expect(sessions.createdSessionCount == 1)
        #expect(externalURLOpener.openedURLs == [])
        let loginRequest = try #require(await authTransport.recordedRequests().first {
            $0.method == "account/login/start"
        })
        let loginParams = try JSONDecoder().decode(AppServerAPI.Account.Login.Params.self, from: loginRequest.params)
        #expect(loginParams.nativeWebAuthentication?.callbackURLScheme == "lynnpd.CodexReviewMonitor.auth")
        try await authTransport.emitServerNotification(
            method: "account/updated",
            params: EmptyResponse()
        )
        try await authTransport.emitServerNotification(
            method: "account/login/completed",
            params: TestLoginCompletedNotification(loginID: "login-2", success: true)
        )
        try await authTransport.emitServerNotification(
            method: "account/updated",
            params: EmptyResponse()
        )
        await authTransport.waitForRequestCount(4)
        await waitUntil {
            store.auth.persistedAccounts.contains { $0.accountKey == "new@example.com" }
                && store.auth.persistedAccounts.first { $0.accountKey == "new@example.com" }?.rateLimits.first?.usedPercent == 25
                && store.auth.isAuthenticating == false
        }

        #expect(store.auth.selectedAccount?.accountKey == "active@example.com")
        #expect(store.auth.persistedActiveAccountKey == "active@example.com")
        #expect(store.auth.persistedAccounts.map(\.accountKey).contains("new@example.com"))
        #expect(store.auth.persistedAccounts.first { $0.accountKey == "new@example.com" }?.rateLimits.first?.usedPercent == 25)
        #expect(await mainTransport.recordedRequests().map(\.method).contains("account/login/start") == false)
        #expect(await authTransport.recordedRequests().map(\.method) == [
            "initialize",
            "account/login/start",
            "account/read",
            "account/rateLimits/read",
        ])

        async let refresh: Void = store.refreshAccountRateLimits(accountKey: "new@example.com")
        await refreshTransport.waitForRequestCount(3)
        let capturedRefreshCodexHomeURL = try #require(refreshCodexHomeURL)
        try Data("{\"tokens\":{\"id_token\":\"refreshed-token\"}}".utf8)
            .write(to: capturedRefreshCodexHomeURL.appendingPathComponent("auth.json"))
        await refreshGate.open()
        await refresh
        await waitUntil {
            store.auth.persistedAccounts.first { $0.accountKey == "new@example.com" }?.rateLimits.first?.usedPercent == 44
        }

        #expect(store.auth.selectedAccount?.accountKey == "active@example.com")
        #expect(store.auth.persistedAccounts.first { $0.accountKey == "new@example.com" }?.rateLimits.first?.usedPercent == 44)
        #expect(try savedAccountAuth(homeURL: homeURL, accountKey: "new@example.com") == Data("{\"tokens\":{\"id_token\":\"refreshed-token\"}}".utf8))
        #expect(await refreshTransport.recordedRequests().map(\.method) == [
            "initialize",
            "account/read",
            "account/rateLimits/read",
        ])
    }

    @Test func liveStoreDoesNotApplySavedAccountRateLimitsFromDifferentAuth() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "active@example.com",
            accounts: ["active@example.com", "new@example.com"]
        )
        try writeSavedAccountAuth(homeURL: homeURL, accountKey: "new@example.com")

        let mainTransport = FakeJSONRPCTransport()
        try await mainTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await mainTransport.enqueue(
            AppServerAPI.Account.Read.Response(account: .init(email: "active@example.com", planType: "pro")),
            for: "account/read"
        )
        try await mainTransport.enqueue(
            AppServerAPI.Account.RateLimits.Response(rateLimits: .init(
                limitID: "codex",
                primary: .init(usedPercent: 10, windowDurationMins: 300)
            )),
            for: "account/rateLimits/read"
        )
        try await mainTransport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await mainTransport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")

        let refreshTransport = FakeJSONRPCTransport()
        try await refreshTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await refreshTransport.enqueue(
            AppServerAPI.Account.Read.Response(account: .init(email: "active@example.com", planType: "pro")),
            for: "account/read"
        )
        try await refreshTransport.enqueue(
            AppServerAPI.Account.RateLimits.Response(rateLimits: .init(
                limitID: "codex",
                primary: .init(usedPercent: 44, windowDurationMins: 300)
            )),
            for: "account/rateLimits/read"
        )

        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transportFactory: { codexHomeURL in
                if codexHomeURL == mainCodexHomeURL {
                    return mainTransport
                }
                return refreshTransport
            }
        )

        await store.start(forceRestartIfNeeded: true)
        await store.refreshAccountRateLimits(accountKey: "new@example.com")
        let newAccount = store.auth.persistedAccounts.first { $0.accountKey == "new@example.com" }

        #expect(newAccount?.rateLimits.isEmpty == true)
        #expect(newAccount?.requiresReauthentication == true)
        #expect(newAccount?.lastRateLimitError?.contains("Saved authentication is for") == true)
        #expect(await refreshTransport.recordedRequests().map(\.method) == [
            "initialize",
            "account/read",
        ])
    }

    @Test func liveStoreAddAccountActivatesNewLoginWhenPersistedAccountsHaveNoActiveAccount() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: nil,
            accounts: ["existing@example.com"]
        )
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        try await transport.enqueue(
            AppServerAPI.Account.Login.Response.chatgpt(
                loginID: "login-new",
                authURL: "https://example.com/auth",
                nativeWebAuthentication: .init(callbackURLScheme: "lynnpd.CodexReviewMonitor.auth")
            ),
            for: "account/login/start"
        )
        try await transport.enqueue(AppServerAPI.Account.Login.Complete.Response(), for: "account/login/complete")
        try await transport.enqueue(
            AppServerAPI.Account.Read.Response(account: .init(email: "new@example.com", planType: "plus")),
            for: "account/read"
        )
        try await transport.enqueue(
            AppServerAPI.Account.RateLimits.Response(rateLimits: .init(
                limitID: "codex",
                primary: .init(usedPercent: 20, windowDurationMins: 300)
            )),
            for: "account/rateLimits/read"
        )
        let sessions = FakeWebAuthenticationSessions()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.CodexReviewMonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: sessions.makeSession,
            transportFactory: { codexHomeURL in
                #expect(codexHomeURL == mainCodexHomeURL)
                return transport
            }
        )

        await store.start(forceRestartIfNeeded: true)
        #expect(store.auth.selectedAccount == nil)
        #expect(store.auth.persistedAccounts.map(\.accountKey) == ["existing@example.com"])

        await store.addAccount()
        let session = await sessions.waitForSession()
        await session.waitUntilWaitingForCallback()
        session.complete(with: URL(string: "lynnpd.CodexReviewMonitor.auth://callback?code=1")!)
        await waitUntil {
            store.auth.selectedAccount?.accountKey == "new@example.com"
                && store.auth.selectedAccount?.rateLimits.first?.usedPercent == 20
        }

        #expect(store.auth.persistedActiveAccountKey == "new@example.com")
        #expect(try activeAccountKey(homeURL: homeURL) == "new@example.com")
        #expect(store.auth.persistedAccounts.map(\.accountKey) == [
            "new@example.com",
            "existing@example.com",
        ])
        #expect(await transport.recordedRequests().map(\.method) == [
            "initialize",
            "account/read",
            "config/read",
            "model/list",
            "account/login/start",
            "account/login/complete",
            "account/read",
            "account/rateLimits/read",
        ])
    }

    @Test func liveStoreAddAccountSetupFailureRecordsAuthenticationFailure() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "active@example.com",
            accounts: ["active@example.com"]
        )
        let mainTransport = FakeJSONRPCTransport()
        try await mainTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await mainTransport.enqueue(
            AppServerAPI.Account.Read.Response(account: .init(email: "active@example.com", planType: "pro")),
            for: "account/read"
        )
        try await mainTransport.enqueue(
            AppServerAPI.Account.RateLimits.Response(rateLimits: .init(
                limitID: "codex",
                primary: .init(usedPercent: 10, windowDurationMins: 300)
            )),
            for: "account/rateLimits/read"
        )
        try await mainTransport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await mainTransport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        let loginTransport = FakeJSONRPCTransport()
        try await loginTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await loginTransport.enqueue(
            AppServerAPI.Account.Login.Response.chatgpt(
                loginID: "login-2",
                authURL: "https://example.com/auth",
                nativeWebAuthentication: .init(callbackURLScheme: "lynnpd.CodexReviewMonitor.auth")
            ),
            for: "account/login/start"
        )
        try await loginTransport.enqueue(AppServerAPI.Account.Login.Cancel.Response(), for: "account/login/cancel")
        var isolatedCodexHomeURL: URL?
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.CodexReviewMonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: { _, _, _, _ in
                throw CodexReviewAPI.Error.io("Authentication presentation failed.")
            },
            transportFactory: { codexHomeURL in
                if codexHomeURL == mainCodexHomeURL {
                    return mainTransport
                }
                isolatedCodexHomeURL = codexHomeURL
                try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
                return loginTransport
            }
        )

        await store.start(forceRestartIfNeeded: true)
        let previousFailureCount = store.auth.authenticationFailureCount
        await store.addAccount()
        await loginTransport.waitForRequestCount(3)

        let resolvedIsolatedCodexHomeURL = try #require(isolatedCodexHomeURL)
        #expect(store.auth.authenticationFailureCount == previousFailureCount + 1)
        #expect(failedMessage(from: store.auth.phase) == "Authentication presentation failed.")
        #expect(store.auth.selectedAccount?.accountKey == "active@example.com")
        await waitUntil {
            FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path) == false
        }
        #expect(FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path) == false)
        #expect(await loginTransport.recordedRequests().map(\.method) == [
            "initialize",
            "account/login/start",
            "account/login/cancel",
        ])
    }

    @Test func liveStoreIgnoresNonCodexRateLimitNotifications() async throws {
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(
            AppServerAPI.Account.Read.Response(account: .init(email: "active@example.com", planType: "pro")),
            for: "account/read"
        )
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        try await transport.enqueue(
            AppServerAPI.Account.RateLimits.Response(rateLimits: .init(
                limitID: "codex",
                primary: .init(usedPercent: 10, windowDurationMins: 300),
                planType: "pro"
            )),
            for: "account/rateLimits/read"
        )
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await transport.waitForNotificationStreamCount(1)
        await waitUntil {
            store.auth.selectedAccount?.rateLimits.first?.usedPercent == 10
        }
        try await transport.emitServerNotification(
            method: "account/rateLimits/updated",
            params: TestRateLimitsUpdatedNotification(rateLimits: .init(
                limitID: "openai",
                primary: .init(usedPercent: 99, windowDurationMins: 300),
                planType: "other"
            ))
        )
        try await transport.emitServerNotification(
            method: "account/rateLimits/updated",
            params: TestRateLimitsUpdatedNotification(rateLimits: .init(
                limitID: "codex_bengalfox",
                primary: .init(usedPercent: 11, windowDurationMins: 300)
            ))
        )
        await waitUntil {
            store.auth.selectedAccount?.rateLimits.first?.usedPercent == 11
        }

        #expect(store.auth.selectedAccount?.planType == "pro")
        #expect(store.auth.selectedAccount?.rateLimits.map(\.usedPercent) == [11])
    }

    @Test func liveStoreSwitchingAccountRestartsRuntimeAndCancelsRunningReviews() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "first@example.com",
            accounts: ["first@example.com", "second@example.com"]
        )
        try writeSavedAccountAuth(homeURL: homeURL, accountKey: "second@example.com")

        let firstTransport = FakeJSONRPCTransport()
        try await firstTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await firstTransport.enqueue(
            AppServerAPI.Account.Read.Response(account: .init(email: "first@example.com", planType: "pro")),
            for: "account/read"
        )
        try await firstTransport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await firstTransport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        try await firstTransport.enqueue(
            AppServerAPI.Account.RateLimits.Response(rateLimits: .init(
                limitID: "codex",
                primary: .init(usedPercent: 10, windowDurationMins: 300)
            )),
            for: "account/rateLimits/read"
        )
        try await firstTransport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-first", model: "gpt-5"), for: "thread/start")
        try await firstTransport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-first"), for: "review/start")
        try await firstTransport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await firstTransport.enqueue(
            AppServerAPI.Thread.Unsubscribe.Response(status: .unsubscribed),
            for: "thread/unsubscribe"
        )

        let secondTransport = FakeJSONRPCTransport()
        try await secondTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await secondTransport.enqueue(
            AppServerAPI.Account.Read.Response(account: .init(email: "second@example.com", planType: "plus")),
            for: "account/read"
        )
        try await secondTransport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await secondTransport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        try await secondTransport.enqueue(
            AppServerAPI.Account.RateLimits.Response(rateLimits: .init(
                limitID: "codex",
                primary: .init(usedPercent: 30, windowDurationMins: 300)
            )),
            for: "account/rateLimits/read"
        )

        var mainTransports = [firstTransport, secondTransport]
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transportFactory: { codexHomeURL in
                #expect(codexHomeURL == mainCodexHomeURL)
                return mainTransports.removeFirst()
            }
        )

        await store.start(forceRestartIfNeeded: true)
        async let reviewRead = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await waitUntil { store.jobs.first?.core.run.turnID == "turn-first" }

        let switchTask = Task { @MainActor in
            try await store.switchAccount(CodexAccount(email: "second@example.com"))
        }
        await firstTransport.waitForResponseDelivery(method: "turn/interrupt")
        try await firstTransport.emitServerNotification(
            method: "turn/completed",
            params: HostTurnNotification(
                threadID: "thread-first",
                turnID: "turn-first",
                status: "interrupted",
                errorMessage: "Account switched."
            )
        )
        try await switchTask.value
        let result = try await reviewRead
        await secondTransport.waitForRequestCount(2)
        await firstTransport.waitForRequestCount(8)

        #expect(result.core.lifecycle.status == .cancelled)
        #expect(result.core.lifecycle.cancellation?.message == "Account switched.")
        #expect(store.auth.selectedAccount?.accountKey == "second@example.com")
        #expect(await firstTransport.recordedRequests().map(\.method).contains("turn/interrupt"))
        #expect(await secondTransport.recordedRequests().map(\.method).contains("account/read"))
    }

    @Test func liveStoreSwitchAccountPreservesCredentialsWhenReviewBarrierFails() async throws {
        let homeURL = try temporaryHome()
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "first@example.com",
            accounts: ["first@example.com", "second@example.com"]
        )
        try writeSavedAccountAuth(homeURL: homeURL, accountKey: "second@example.com")

        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(
            AppServerAPI.Account.Read.Response(account: .init(email: "first@example.com", planType: "pro")),
            for: "account/read"
        )
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        try await transport.enqueue(
            AppServerAPI.Account.RateLimits.Response(rateLimits: .init(
                limitID: "codex",
                primary: .init(usedPercent: 10, windowDurationMins: 300)
            )),
            for: "account/rateLimits/read"
        )
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-first", model: "gpt-5"),
            for: "thread/start"
        )
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(turnID: "turn-first"),
            for: "review/start"
        )
        await transport.enqueueFailure(
            .responseError(code: -32_000, message: "Interrupt rejected"),
            for: "turn/interrupt"
        )
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        async let reviewRead = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await waitUntil { store.jobs.first?.core.run.turnID == "turn-first" }

        await #expect(throws: ReviewInterruptRequestFailure.self) {
            try await store.switchAccount(CodexAccount(email: "second@example.com"))
        }
        #expect(store.auth.selectedAccount?.accountKey == "first@example.com")
        #expect(try activeAccountKey(homeURL: homeURL) == "first@example.com")
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: HostTurnNotification(
                threadID: "thread-first",
                turnID: "turn-first",
                status: "interrupted",
                errorMessage: "Review ended."
            )
        )
        _ = try await reviewRead
    }

    @Test func liveStoreSignOutRestartsRuntimeAndCancelsRunningReviews() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "active@example.com",
            accounts: ["active@example.com"]
        )

        let firstTransport = FakeJSONRPCTransport()
        try await firstTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await firstTransport.enqueue(
            AppServerAPI.Account.Read.Response(account: .init(email: "active@example.com", planType: "pro")),
            for: "account/read"
        )
        try await firstTransport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
        try await firstTransport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await firstTransport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        try await firstTransport.enqueue(
            AppServerAPI.Account.RateLimits.Response(rateLimits: .init(
                limitID: "codex",
                primary: .init(usedPercent: 10, windowDurationMins: 300)
            )),
            for: "account/rateLimits/read"
        )
        try await firstTransport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-active", model: "gpt-5"), for: "thread/start")
        try await firstTransport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-active"), for: "review/start")
        try await firstTransport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await firstTransport.enqueue(
            AppServerAPI.Thread.Unsubscribe.Response(status: .unsubscribed),
            for: "thread/unsubscribe"
        )
        try await firstTransport.enqueue(EmptyResponse(), for: "account/logout")

        let secondTransport = FakeJSONRPCTransport()
        try await secondTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await secondTransport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
        try await secondTransport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await secondTransport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")

        var mainTransports = [firstTransport, secondTransport]
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transportFactory: { codexHomeURL in
                #expect(codexHomeURL == mainCodexHomeURL)
                return mainTransports.removeFirst()
            }
        )

        await store.start(forceRestartIfNeeded: true)
        async let reviewRead = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await waitUntil { store.jobs.first?.core.run.turnID == "turn-active" }

        let logoutTask = Task { @MainActor in
            await store.logout()
        }
        await firstTransport.waitForResponseDelivery(method: "turn/interrupt")
        try await firstTransport.emitServerNotification(
            method: "turn/completed",
            params: HostTurnNotification(
                threadID: "thread-active",
                turnID: "turn-active",
                status: "interrupted",
                errorMessage: "Signed out."
            )
        )
        await logoutTask.value
        let result = try await reviewRead
        await secondTransport.waitForRequestCount(2)

        let firstMethods = await firstTransport.recordedRequests().map(\.method)
        let interruptIndex = try #require(firstMethods.firstIndex(of: "turn/interrupt"))
        let logoutIndex = try #require(firstMethods.firstIndex(of: "account/logout"))
        #expect(interruptIndex < logoutIndex)
        #expect(result.core.lifecycle.status == .cancelled)
        #expect(result.core.lifecycle.cancellation?.message == "Signed out.")
        #expect(store.auth.selectedAccount == nil)
        #expect(store.auth.persistedAccounts.isEmpty)
        #expect(await secondTransport.recordedRequests().map(\.method).contains("account/read"))
    }

    @Test func liveStoreSwitchAccountFailsWhenSavedAuthIsMissing() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let originalAuth = Data("{\"tokens\":{\"id_token\":\"first\"}}".utf8)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "first@example.com",
            accounts: ["first@example.com", "second@example.com"]
        )
        try FileManager.default.createDirectory(at: mainCodexHomeURL, withIntermediateDirectories: true)
        try originalAuth.write(to: mainCodexHomeURL.appendingPathComponent("auth.json"))

        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(
            AppServerAPI.Account.Read.Response(account: .init(email: "first@example.com", planType: "pro")),
            for: "account/read"
        )
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        try await transport.enqueue(
            AppServerAPI.Account.RateLimits.Response(rateLimits: .init(
                limitID: "codex",
                primary: .init(usedPercent: 10, windowDurationMins: 300)
            )),
            for: "account/rateLimits/read"
        )
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await #expect(throws: (any Error).self) {
            try await store.switchAccount(CodexAccount(email: "second@example.com"))
        }

        #expect(store.auth.selectedAccount?.accountKey == "first@example.com")
        #expect(try activeAccountKey(homeURL: homeURL) == "first@example.com")
        #expect(try Data(contentsOf: mainCodexHomeURL.appendingPathComponent("auth.json")) == originalAuth)
    }

    @Test func liveStoreStopLetsHTTPServerCancelSessionsBeforeDroppingBackend() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let interruptGate = AsyncGate()
        let transport = FakeJSONRPCTransport()
        await transport.holdNext(method: "turn/interrupt", gate: interruptGate)
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(
            AppServerAPI.Thread.Unsubscribe.Response(status: .unsubscribed),
            for: "thread/unsubscribe"
        )
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: { store, _ in
                CodexReviewMCPHTTPServer(
                    adapter: CodexReviewMCPServer(store: store),
                    configuration: .init(port: 0)
                )
            },
            mcpHTTPServerBindChecker: { _ in },
            transportFactory: { codexHomeURL in
                #expect(codexHomeURL == mainCodexHomeURL)
                return transport
            }
        )

        await store.start(forceRestartIfNeeded: true)
        let endpoint = try #require(store.serverURL)
        let sessionID = try await initializeMCPSession(endpoint: endpoint)
        async let reviewRead = store.startReview(
            sessionID: sessionID,
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await waitUntil { store.jobs.first?.core.run.turnID == "turn-1" }

        let stopTask = Task { @MainActor in
            await store.stop()
        }
        let interruptStarted = await waitUntil(timeout: .seconds(2)) {
            await transport.recordedRequests().map(\.method).contains("turn/interrupt")
        }
        let methodsBeforeInterruptCompletes = await transport.recordedRequests().map(\.method)
        let jobBeforeInterruptCompletes = try #require(store.jobs.first)
        #expect(jobBeforeInterruptCompletes.cancellationRequested)
        #expect(jobBeforeInterruptCompletes.core.lifecycle.cancellation?.message == "Review runtime stopped.")
        await interruptGate.open()
        await transport.waitForResponseDelivery(method: "turn/interrupt")
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: HostTurnNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                status: "interrupted",
                errorMessage: "Review runtime stopped."
            )
        )
        await stopTask.value
        let result = try await reviewRead

        #expect(interruptStarted)
        #expect(methodsBeforeInterruptCompletes.contains("turn/interrupt"))
        #expect(methodsBeforeInterruptCompletes.contains("thread/backgroundTerminals/clean") == false)
        #expect(methodsBeforeInterruptCompletes.contains("thread/delete") == false)
        #expect(result.core.lifecycle.status == .cancelled)
        let methods = await transport.recordedRequests().map(\.method)
        let interruptIndex = try #require(methods.firstIndex(of: "turn/interrupt"))
        let cleanupIndex = try #require(methods.firstIndex(of: "thread/backgroundTerminals/clean"))
        let deleteIndex = try #require(methods.firstIndex(of: "thread/delete"))
        #expect(interruptIndex < cleanupIndex)
        #expect(interruptIndex < deleteIndex)
    }

    @Test func liveStoreStopGraceForceClosesAndAwaitsConnectionTerminal() async throws {
        let homeURL = try temporaryHome()
        let interruptGate = AsyncGate()
        let graceStarted = AsyncGate()
        let graceGate = AsyncGate()
        let transport = FakeJSONRPCTransport()
        await transport.holdNextIgnoringCancellation(method: "turn/interrupt", gate: interruptGate)
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        try await transport.enqueue(AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1"), for: "review/start")
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            reviewRuntimeClosePolicy: .init(
                terminalGrace: .seconds(10),
                sleep: { _ in
                    await graceStarted.open()
                    await graceGate.wait()
                    try Task.checkCancellation()
                }
            ),
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        let reviewRead = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await transport.waitForRequest(method: "review/start")
        let jobID = try #require(store.jobs.first?.id)
        let admission: ReviewStartAdmission
        switch store.reviewAttemptOwnerships[jobID] {
        case .initialStart(let start):
            admission = start.admission
        case .active(let active):
            admission = active.admission
        default:
            Issue.record("Expected initial or active attempt ownership before runtime stop.")
            return
        }
        let run = try #require(await admission.waitForActiveRun())
        try #require(await waitUntil(timeout: .seconds(2)) {
            guard case .active(let active) = store.reviewAttemptOwnerships[jobID] else {
                return false
            }
            return active.run.attemptID == run.attemptID
        })
        #expect(run.turnID == "turn-1")
        let worker = try #require(store.reviewWorkerTasks[jobID])

        let stopFinished = CompletionFlag()
        let stopTask = Task { @MainActor in
            await store.stop()
            await stopFinished.complete()
        }
        await graceStarted.wait()
        #expect(await stopFinished.isCompleted() == false)
        await graceGate.open()
        await transport.waitForCloseCall()
        #expect(await stopFinished.isCompleted() == false)
        await interruptGate.open()
        await worker.value
        await stopTask.value
        let result = try await reviewRead.value

        #expect(result.core.lifecycle.status == .failed)
        #expect(result.core.lifecycle.terminal?.kind == .interrupted)
        #expect(await transport.closeCallCountForTesting() >= 1)
        #expect(await stopFinished.isCompleted())
    }

    @Test func liveStoreStopDrainsRecoveryWaitingWorkerCleanupBeforeDroppingBackend() async throws {
        let homeURL = try temporaryHome()
        let cleanupGate = AsyncGate()
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let transport = FakeJSONRPCTransport()
        await transport.holdNextIgnoringCancellation(
            method: "thread/backgroundTerminals/clean",
            gate: cleanupGate
        )
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"),
            for: "thread/start"
        )
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(turnID: "turn-1", reviewThreadID: "review-thread-1"),
            for: "review/start"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in }),
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        let reviewRead = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        try #require(await waitUntil(timeout: .seconds(2)) { store.jobs.first?.core.run.turnID == "turn-1" })
        let jobID = try #require(store.jobs.first?.id)

        networkMonitor.yield(.init(status: .unsatisfied))
        try #require(await waitUntil(timeout: .seconds(2)) {
            await transport.recordedRequests().map(\.method).contains("turn/interrupt")
        })
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: HostTurnNotification(
                threadID: "review-thread-1",
                turnID: "turn-1",
                status: "interrupted",
                errorMessage: "Network unavailable; waiting to reconnect."
            )
        )
        try #require(await waitUntil(timeout: .seconds(2)) {
            if case .waitingForRecovery = store.reviewAttemptOwnerships[jobID] {
                true
            } else {
                false
            }
        })

        let stopFinished = CompletionFlag()
        let stopTask = Task { @MainActor in
            await store.stop()
            await stopFinished.complete()
        }
        let cleanupStarted = await waitUntil(timeout: .seconds(2)) {
            await transport.recordedRequests().map(\.method).contains("thread/backgroundTerminals/clean")
        }
        let stoppedBeforeCleanupUnblocked = await waitUntil(timeout: .milliseconds(100)) {
            await stopFinished.isCompleted()
        }
        await cleanupGate.open()
        await stopTask.value
        let result = try await reviewRead.value

        #expect(cleanupStarted)
        #expect(stoppedBeforeCleanupUnblocked == false)
        #expect(result.core.lifecycle.status == .cancelled)
        let methods = await transport.recordedRequests().map(\.method)
        #expect(methods.contains("thread/delete"))
    }

    @Test func liveStoreMarksRuntimeFailedWhenAppServerNotificationStreamCloses() async throws {
        let homeURL = try temporaryHome()
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await transport.waitForNotificationStreamCount(1)
        await transport.finishNotificationStreams(throwing: JSONRPC.Error.closed)
        await waitUntil {
            if case .failed = store.serverState {
                return true
            }
            return false
        }

        guard case .failed(let message) = store.serverState else {
            Issue.record("Expected failed server state.")
            return
        }
        #expect(message.contains("JSON-RPC transport is closed"))
        #expect(store.serverURL == nil)
    }

    @Test func liveStoreCleansIsolatedLoginRuntimeWhenMainNotificationStreamCloses() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "active@example.com",
            accounts: ["active@example.com"]
        )
        let mainTransport = FakeJSONRPCTransport()
        try await mainTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await mainTransport.enqueue(
            AppServerAPI.Account.Read.Response(account: .init(email: "active@example.com", planType: "pro")),
            for: "account/read"
        )
        try await mainTransport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await mainTransport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        let loginTransport = FakeJSONRPCTransport()
        await loginTransport.failClose(with: .connection("isolated login close failed"))
        try await loginTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await loginTransport.enqueue(
            AppServerAPI.Account.Login.Response.chatgpt(
                loginID: "login-1",
                authURL: "https://example.com/auth",
                nativeWebAuthentication: .init(callbackURLScheme: "lynnpd.CodexReviewMonitor.auth")
            ),
            for: "account/login/start"
        )
        let sessions = FakeWebAuthenticationSessions()
        var isolatedCodexHomeURL: URL?
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.CodexReviewMonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: sessions.makeSession,
            transportFactory: { codexHomeURL in
                if codexHomeURL == mainCodexHomeURL {
                    return mainTransport
                }
                isolatedCodexHomeURL = codexHomeURL
                try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
                return loginTransport
            }
        )

        await store.start(forceRestartIfNeeded: true)
        await mainTransport.waitForNotificationStreamCount(1)
        await store.addAccount()
        let session = await sessions.waitForSession()
        await session.waitUntilWaitingForCallback()
        let resolvedIsolatedCodexHomeURL = try #require(isolatedCodexHomeURL)
        #expect(FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path))

        await mainTransport.finishNotificationStreams(throwing: JSONRPC.Error.closed)
        await waitUntil {
            if case .failed = store.serverState {
                return true
            }
            return false
        }
        await waitUntil {
            await loginTransport.isClosedForTesting()
        }

        #expect(await loginTransport.isClosedForTesting())
        await waitUntil {
            FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path) == false
        }
        #expect(FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path) == false)
        await #expect(throws: JSONRPC.Error.closed) {
            _ = try await loginTransport.send(JSONRPC.Request(id: 99, method: "ping", params: Data()))
        }
        let closeError = try #require(await captureStoreCloseError(store))
        guard case .lifecycleResources(let lifecycle) = closeError.failures.first else {
            Issue.record("Retired isolated-login cleanup must reach Store close.")
            return
        }
        guard case .client(let message) = lifecycle.first else {
            Issue.record("Isolated-login connection close must remain a client failure.")
            return
        }
        #expect(message.contains("isolated login close failed"))
    }

    @Test func liveStoreRemovingActiveAccountClearsSharedAuthAndRestartsSignedOutRuntime() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "active@example.com",
            accounts: ["active@example.com"]
        )
        try Data("{\"tokens\":{\"id_token\":\"test\"}}".utf8)
            .write(to: mainCodexHomeURL.appendingPathComponent("auth.json"))

        let firstTransport = FakeJSONRPCTransport()
        try await firstTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await firstTransport.enqueue(
            AppServerAPI.Account.Read.Response(account: .init(email: "active@example.com", planType: "pro")),
            for: "account/read"
        )
        try await firstTransport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await firstTransport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        try await firstTransport.enqueue(
            AppServerAPI.Account.RateLimits.Response(rateLimits: .init(
                limitID: "codex",
                primary: .init(usedPercent: 10, windowDurationMins: 300)
            )),
            for: "account/rateLimits/read"
        )
        try await firstTransport.enqueue(EmptyResponse(), for: "account/logout")

        let secondTransport = FakeJSONRPCTransport()
        try await secondTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await secondTransport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
        try await secondTransport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await secondTransport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")

        var mainTransports = [firstTransport, secondTransport]
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transportFactory: { codexHomeURL in
                #expect(codexHomeURL == mainCodexHomeURL)
                return mainTransports.removeFirst()
            }
        )

        await store.start(forceRestartIfNeeded: true)
        try await store.removeAccount(accountKey: "active@example.com")
        await secondTransport.waitForRequestCount(2)

        #expect(FileManager.default.fileExists(atPath: mainCodexHomeURL.appendingPathComponent("auth.json").path) == false)
        #expect(store.auth.selectedAccount == nil)
        #expect(store.auth.persistedAccounts.isEmpty)
        #expect(await firstTransport.recordedRequests().map(\.method).contains("account/logout"))
        #expect(await secondTransport.recordedRequests().map(\.method).contains("account/read"))
    }

    @Test func liveStoreClosesIsolatedLoginRuntimeWhenMainRuntimeIsUnavailable() async throws {
        let homeURL = try temporaryHome()
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "active@example.com",
            accounts: ["active@example.com"]
        )
        var isolatedCodexHomeURL: URL?
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.CodexReviewMonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transportFactory: { codexHomeURL in
                isolatedCodexHomeURL = codexHomeURL
                try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
                return FakeJSONRPCTransport()
            }
        )

        await store.addAccount()

        let resolvedIsolatedCodexHomeURL = try #require(isolatedCodexHomeURL)
        #expect(failedMessage(from: store.auth.phase) == "Review runtime is not running.")
        #expect(FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path) == false)
    }

    @Test func liveStoreClosesIsolatedLoginRuntimeWhenLoginStartFails() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "active@example.com",
            accounts: ["active@example.com"]
        )
        let mainTransport = FakeJSONRPCTransport()
        try await mainTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await mainTransport.enqueue(
            AppServerAPI.Account.Read.Response(account: .init(email: "active@example.com", planType: "pro")),
            for: "account/read"
        )
        try await mainTransport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await mainTransport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        let loginTransport = FakeJSONRPCTransport()
        try await loginTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        await loginTransport.enqueueFailure(
            .responseError(code: -32603, message: "login unavailable"),
            for: "account/login/start"
        )
        var isolatedCodexHomeURL: URL?
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.CodexReviewMonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transportFactory: { codexHomeURL in
                if codexHomeURL == mainCodexHomeURL {
                    return mainTransport
                }
                isolatedCodexHomeURL = codexHomeURL
                try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
                return loginTransport
            }
        )

        await store.start(forceRestartIfNeeded: true)
        await store.addAccount()

        let resolvedIsolatedCodexHomeURL = try #require(isolatedCodexHomeURL)
        #expect(failedMessage(from: store.auth.phase) == "login unavailable")
        #expect(FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path) == false)
    }

    @Test func liveStoreClosesIsolatedLoginRuntimeWhenLoginCompletionFails() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "active@example.com",
            accounts: ["active@example.com"]
        )
        let mainTransport = FakeJSONRPCTransport()
        try await mainTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await mainTransport.enqueue(
            AppServerAPI.Account.Read.Response(account: .init(email: "active@example.com", planType: "pro")),
            for: "account/read"
        )
        try await mainTransport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await mainTransport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        let loginTransport = FakeJSONRPCTransport()
        try await loginTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await loginTransport.enqueue(
            AppServerAPI.Account.Login.Response.chatgpt(
                loginID: "login-2",
                authURL: "https://example.com/auth",
                nativeWebAuthentication: .init(callbackURLScheme: "lynnpd.CodexReviewMonitor.auth")
            ),
            for: "account/login/start"
        )
        await loginTransport.enqueueFailure(
            .responseError(code: -32603, message: "login completion failed"),
            for: "account/login/complete"
        )
        let sessions = FakeWebAuthenticationSessions()
        var isolatedCodexHomeURL: URL?
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.CodexReviewMonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: sessions.makeSession,
            transportFactory: { codexHomeURL in
                if codexHomeURL == mainCodexHomeURL {
                    return mainTransport
                }
                isolatedCodexHomeURL = codexHomeURL
                try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
                return loginTransport
            }
        )

        await store.start(forceRestartIfNeeded: true)
        await store.addAccount()
        let session = await sessions.waitForSession()
        await session.waitUntilWaitingForCallback()
        session.complete(with: URL(string: "lynnpd.CodexReviewMonitor.auth://callback?code=1")!)
        await loginTransport.waitForRequestCount(3)

        let resolvedIsolatedCodexHomeURL = try #require(isolatedCodexHomeURL)
        await waitUntil { failedMessage(from: store.auth.phase) == "login completion failed" }
        #expect(FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path) == false)
        #expect(await loginTransport.recordedRequests().map(\.method) == [
            "initialize",
            "account/login/start",
            "account/login/complete",
        ])
    }

    @Test func liveStoreRemovesOnlyEncodedSavedAccountDirectory() async throws {
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let account = CodexAccount(email: "../outside@example.com")
        let rawFallbackDirectoryURL = codexHomeURL.appendingPathComponent("outside@example.com", isDirectory: true)
        try FileManager.default.createDirectory(at: rawFallbackDirectoryURL, withIntermediateDirectories: true)
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transport: FakeJSONRPCTransport()
        )
        store.auth.applyPersistedAccountStates([savedAccountPayload(from: account)])

        try await store.removeAccount(accountKey: account.accountKey)

        #expect(FileManager.default.fileExists(atPath: rawFallbackDirectoryURL.path))
    }

    @Test func liveStoreEncodesSpecialSavedAccountDirectoryNames() async throws {
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let accountsURL = codexHomeURL.appendingPathComponent("accounts", isDirectory: true)
        try FileManager.default.createDirectory(at: accountsURL, withIntermediateDirectories: true)
        let sentinelURL = codexHomeURL.appendingPathComponent("sentinel.txt")
        try Data("keep".utf8).write(to: sentinelURL)

        let dotAccount = CodexAccount(email: ".")
        let dotDotAccount = CodexAccount(email: "..")
        let dotDirectoryURL = accountsURL.appendingPathComponent("%2E", isDirectory: true)
        let dotDotDirectoryURL = accountsURL.appendingPathComponent("%2E%2E", isDirectory: true)
        try FileManager.default.createDirectory(at: dotDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dotDotDirectoryURL, withIntermediateDirectories: true)
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transport: FakeJSONRPCTransport()
        )
        store.auth.applyPersistedAccountStates([
            savedAccountPayload(from: dotAccount),
            savedAccountPayload(from: dotDotAccount),
        ])

        try await store.removeAccount(accountKey: dotAccount.accountKey)
        try await store.removeAccount(accountKey: dotDotAccount.accountKey)

        #expect(FileManager.default.fileExists(atPath: codexHomeURL.path))
        #expect(FileManager.default.fileExists(atPath: accountsURL.path))
        #expect(FileManager.default.fileExists(atPath: sentinelURL.path))
        #expect(FileManager.default.fileExists(atPath: dotDirectoryURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: dotDotDirectoryURL.path) == false)
    }
}

private struct TestLoginCompletedNotification: Encodable, Sendable {
    var loginID: String?
    var success: Bool
    var error: String?

    init(loginID: String?, success: Bool, error: String? = nil) {
        self.loginID = loginID
        self.success = success
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case loginID = "loginId"
        case success
        case error
    }
}

private struct TestAccountReadResponse: Encodable, Sendable {
    var account: TestAccount
    var requiresOpenAIAuth = false

    enum CodingKeys: String, CodingKey {
        case account
        case requiresOpenAIAuth = "requiresOpenaiAuth"
    }
}

private struct TestAccount: Encodable, Sendable {
    var type: String
}

private struct TestRateLimitsUpdatedNotification: Encodable, Sendable {
    var rateLimits: AppServerAPI.Account.RateLimits.Snapshot
}

@MainActor
private final class FakeWebAuthenticationSessions {
    private var session: FakeWebAuthenticationSession?
    private var sessionCount = 0
    private var waiters: [CheckedContinuation<FakeWebAuthenticationSession, Never>] = []

    var createdSessionCount: Int {
        sessionCount
    }

    func makeSession(
        url _: URL,
        callbackScheme _: String,
        browserSessionPolicy _: CodexReviewNativeAuthentication.Configuration.BrowserSessionPolicy,
        presentationAnchorProvider _: @escaping @MainActor @Sendable () -> ASPresentationAnchor?
    ) async throws -> any CodexReviewNativeAuthentication.WebSession {
        let session = FakeWebAuthenticationSession()
        sessionCount += 1
        self.session = session
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: session)
        }
        return session
    }

    func waitForSession() async -> FakeWebAuthenticationSession {
        if let session {
            return session
        }
        return await withCheckedContinuation { continuation in
            if let session {
                continuation.resume(returning: session)
            } else {
                waiters.append(continuation)
            }
        }
    }
}

@MainActor
private final class FakeExternalURLOpener {
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) {
        openedURLs.append(url)
    }
}

@MainActor
private final class FakeWebAuthenticationSession: CodexReviewNativeAuthentication.WebSession {
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var callbackWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForCallbackURL() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            callbackContinuation = continuation
            let waiters = callbackWaiters
            callbackWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func cancel() async {
        resume(throwing: CodexReviewNativeAuthenticationError.cancelled)
    }

    func closeFromAuthenticationWindow() async {
        resume(throwing: CodexReviewNativeAuthenticationError.cancelled)
    }

    func complete(with url: URL) {
        callbackContinuation?.resume(returning: url)
        callbackContinuation = nil
    }

    func waitUntilWaitingForCallback() async {
        if callbackContinuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            if callbackContinuation != nil {
                continuation.resume()
            } else {
                callbackWaiters.append(continuation)
            }
        }
    }

    private func resume(throwing error: Error) {
        callbackContinuation?.resume(throwing: error)
        callbackContinuation = nil
    }
}

private func temporaryHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-review-host-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeRegistry(
    homeURL: URL,
    activeAccountKey: String?,
    accounts: [String]
) throws {
    try writeRegistryRecords(
        homeURL: homeURL,
        activeAccountKey: activeAccountKey,
        records: accounts.map { email in
            [
                "accountKey": email,
                "kind": "chatgpt",
                "email": email,
                "planType": "pro",
            ]
        }
    )
}

private func writeRegistryRecords(
    homeURL: URL,
    activeAccountKey: String?,
    records: [[String: Any]]
) throws {
    let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
    let registryURL = codexHomeURL
        .appendingPathComponent("accounts", isDirectory: true)
        .appendingPathComponent("registry.json")
    try FileManager.default.createDirectory(
        at: registryURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let data = try JSONSerialization.data(withJSONObject: [
        "activeAccountKey": activeAccountKey as Any,
        "accounts": records,
    ])
    try data.write(to: registryURL)
}

private func writeSavedAccountAuth(homeURL: URL, accountKey: String) throws {
    let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
    let authURL = codexHomeURL
        .appendingPathComponent("accounts", isDirectory: true)
        .appendingPathComponent(pathComponent(forAccountKey: accountKey), isDirectory: true)
        .appendingPathComponent("auth.json")
    try FileManager.default.createDirectory(
        at: authURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("{\"tokens\":{\"id_token\":\"\(accountKey)\"}}".utf8).write(to: authURL)
}

private func savedAccountAuth(homeURL: URL, accountKey: String) throws -> Data {
    try Data(contentsOf: homeURL
        .appendingPathComponent(".codex_review", isDirectory: true)
        .appendingPathComponent("accounts", isDirectory: true)
        .appendingPathComponent(pathComponent(forAccountKey: accountKey), isDirectory: true)
        .appendingPathComponent("auth.json"))
}

private func activeAccountKey(homeURL: URL) throws -> String? {
    let registryURL = homeURL
        .appendingPathComponent(".codex_review", isDirectory: true)
        .appendingPathComponent("accounts", isDirectory: true)
        .appendingPathComponent("registry.json")
    let data = try Data(contentsOf: registryURL)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return object["activeAccountKey"] as? String
}

private func pathComponent(forAccountKey accountKey: String) -> String {
    accountKey
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~")))
        ?? accountKey
}

private func initializeMCPSession(endpoint: URL) async throws -> String {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-11-25",
            "capabilities": [:],
            "clientInfo": [
                "name": "CodexReviewHostTests",
                "version": "0.0.0",
            ],
        ],
    ])
    let (_, response) = try await URLSession.shared.data(for: request)
    let httpResponse = try #require(response as? HTTPURLResponse)
    #expect(httpResponse.statusCode == 200)
    return try #require(httpResponse.value(forHTTPHeaderField: "MCP-Session-Id"))
}

private func failedMessage(from phase: CodexReviewAuthModel.Phase) -> String? {
    guard case .failed(let message) = phase else {
        return nil
    }
    return message
}

@MainActor
private func captureStoreCloseError(_ store: CodexReviewStore) async -> ReviewCloseError? {
    do {
        try await store.close()
        return nil
    } catch let error as ReviewCloseError {
        return error
    } catch {
        Issue.record("Unexpected Store close error: \(error)")
        return nil
    }
}

@MainActor
private final class MCPLifecycleCallProbe {
    private struct Waiter {
        let call: CodexReviewMCPLifecycleCall
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var counts: [CodexReviewMCPLifecycleCall: Int] = [:]
    private var waiters: [UUID: Waiter] = [:]

    func record(_ call: CodexReviewMCPLifecycleCall, count: Int) {
        counts[call] = count
        let completedWaiterIDs = waiters.compactMap { id, waiter in
            waiter.call == call && count >= waiter.count ? id : nil
        }
        for waiterID in completedWaiterIDs {
            waiters.removeValue(forKey: waiterID)?.continuation.resume()
        }
    }

    func waitFor(_ call: CodexReviewMCPLifecycleCall, count: Int) async {
        if counts[call, default: 0] >= count {
            return
        }
        await withCheckedContinuation { continuation in
            if counts[call, default: 0] >= count {
                continuation.resume()
            } else {
                waiters[UUID()] = .init(
                    call: call,
                    count: count,
                    continuation: continuation
                )
            }
        }
    }
}

@MainActor
private final class ControlledMCPHTTPServer: CodexReviewMCPHTTPServing {
    private let endpoint: URL
    private var startGate: AsyncGate?
    private var startStartedGate = AsyncGate()
    private var startCancellationGate = AsyncGate()

    private(set) var startCallCount = 0
    private(set) var closeAdmissionCallCount = 0
    private(set) var waitForAdmittedHandlersCallCount = 0
    private(set) var stopCallCount = 0

    init(endpoint: URL) {
        self.endpoint = endpoint
    }

    var url: URL {
        get async {
            endpoint
        }
    }

    func holdStart(with gate: AsyncGate) {
        startGate = gate
        startStartedGate = AsyncGate()
        startCancellationGate = AsyncGate()
    }

    func waitForStart() async {
        await startStartedGate.wait()
    }

    func waitForStartCancellation() async {
        await startCancellationGate.wait()
    }

    func start() async throws {
        startCallCount += 1
        await startStartedGate.open()
        if let startGate {
            let cancellationGate = startCancellationGate
            await withTaskCancellationHandler {
                await startGate.waitIgnoringCancellation()
            } onCancel: {
                Task { await cancellationGate.open() }
            }
            self.startGate = nil
        }
    }

    func closeAdmission() async {
        closeAdmissionCallCount += 1
    }

    func waitForAdmittedHandlers() async {
        waitForAdmittedHandlersCallCount += 1
    }

    func stop() async {
        stopCallCount += 1
    }
}

private final class NoopMCPHTTPServer: CodexReviewMCPHTTPServing, @unchecked Sendable {
    private let endpoint: URL

    init(endpoint: URL) {
        self.endpoint = endpoint
    }

    var url: URL {
        get async {
            endpoint
        }
    }

    func start() async throws {}

    func stop() async {}
}

@MainActor
private func waitUntil(_ condition: @escaping () -> Bool) async {
    for _ in 0..<100 where condition() == false {
        await Task.yield()
    }
}

@MainActor
private func waitUntil(_ condition: @escaping () async -> Bool) async {
    for _ in 0..<100 where await condition() == false {
        await Task.yield()
    }
}

@MainActor
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
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

private func waitForTaskValue<T: Sendable>(
    _ task: Task<T, any Error>,
    timeout: Duration
) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask {
            try await task.value
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        let result = try await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

private actor CompletionFlag {
    private var completed = false

    func complete() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private final class HostSequentialIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        lock.withLock { values.removeFirst() }
    }
}

@MainActor
private final class HostRecoveryRoutingProbe {
    private(set) var events: [CodexReviewLiveRecoveryRoutingEvent] = []

    var sourceAttemptID: String {
        guard case .staged(let sourceAttemptID, _) = events.first else {
            return "missing-source"
        }
        return sourceAttemptID
    }

    var recoveredAttemptID: String {
        guard case .staged(_, let recoveredAttemptID) = events.first else {
            return "missing-recovered"
        }
        return recoveredAttemptID
    }

    func record(_ event: CodexReviewLiveRecoveryRoutingEvent) {
        events.append(event)
    }
}

private struct HostCompletedReviewTurnNotification: Encodable, Sendable {
    private struct Turn: Encodable, Sendable {
        struct Item: Encodable, Sendable {
            var type = "exitedReviewMode"
            var id = "final-review"
            var review: String
        }

        var id: String
        var items: [Item]
        var itemsView = "full"
        var status = "completed"
        var error: String? = nil
    }

    private var threadId: String
    private var turn: Turn

    init(threadID: String, turnID: String, result: String) {
        self.threadId = threadID
        self.turn = Turn(
            id: turnID,
            items: [.init(review: result)]
        )
    }
}

private struct HostCompletedReviewItemNotification: Encodable, Sendable {
    private struct Item: Encodable, Sendable {
        var type = "exitedReviewMode"
        var id = "final-review"
        var review: String
    }

    private var threadId: String
    private var turnId: String
    private var item: Item
    private var completedAtMs: Int64 = 0

    init(threadID: String, turnID: String, result: String) {
        self.threadId = threadID
        self.turnId = turnID
        self.item = Item(review: result)
    }
}

private struct HostTurnNotification: Encodable, Sendable {
    struct Turn: Encodable, Sendable {
        struct TurnError: Encodable, Sendable {
            var message: String
        }

        var id: String
        var items: [String]
        var itemsView: String
        var status: String
        var error: TurnError
    }

    var threadId: String
    var turn: Turn

    init(threadID: String, turnID: String, status: String, errorMessage: String) {
        self.threadId = threadID
        self.turn = Turn(
            id: turnID,
            items: [],
            itemsView: "notLoaded",
            status: status,
            error: .init(message: errorMessage)
        )
    }
}
