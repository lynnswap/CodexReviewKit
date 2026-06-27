import Foundation
import AppKit
import AuthenticationServices
import Testing
import CodexAppServerKit
import CodexAppServerKitTesting
import CodexReviewKit
import CodexReviewAppServer
import CodexReviewHost
import CodexReviewMCPServer
import CodexReviewTesting

private let testAuthenticationURL = URL(string: "https://example.com/auth")!

private extension CodexReviewStore {
    @MainActor
    static func makeLiveStoreForTesting(
        environment: [String: String],
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        nativeAuthenticationConfiguration: CodexReviewNativeAuthentication.Configuration? = nil,
        webAuthenticationSessionFactory: @escaping CodexReviewNativeAuthentication.WebSessionFactory,
        externalURLOpener: @escaping @MainActor @Sendable (URL) -> Void = { _ in },
        mcpPortOwnerResolver: CodexReviewMCPPortOwnerResolver? = nil,
        mcpHTTPServerBindChecker: CodexReviewMCPHTTPServerBindChecker? = nil,
        shutdownCleanupTimeout: Duration = .seconds(2),
        networkMonitor: any CodexReviewNetworkMonitoring = SystemCodexReviewNetworkMonitor(),
        networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy = .default,
        appServerLifecycleHandler: CodexReviewAppServerLifecycleHandler? = nil,
        transport: FakeCodexAppServerTransport
    ) -> CodexReviewStore {
        makeLiveStoreForTesting(
            environment: environment,
            runtimePreferences: runtimePreferences,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory,
            externalURLOpener: externalURLOpener,
            mcpPortOwnerResolver: mcpPortOwnerResolver,
            mcpHTTPServerBindChecker: mcpHTTPServerBindChecker,
            shutdownCleanupTimeout: shutdownCleanupTimeout,
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: networkRecoveryPolicy,
            appServerLifecycleHandler: appServerLifecycleHandler,
            appServerFactory: { codexHomeURL in
                try await CodexAppServerTestRuntime.start(
                    transport: transport,
                    codexHome: codexHomeURL.path
                ).server
            }
        )
    }

    @MainActor
    static func makeLiveStoreForTesting(
        environment: [String: String],
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        nativeAuthenticationConfiguration: CodexReviewNativeAuthentication.Configuration? = nil,
        webAuthenticationSessionFactory: @escaping CodexReviewNativeAuthentication.WebSessionFactory,
        externalURLOpener: @escaping @MainActor @Sendable (URL) -> Void = { _ in },
        mcpHTTPServerFactory: (@MainActor @Sendable (
            CodexReviewStore,
            CodexReviewMCPHTTPServer.Configuration
        ) -> any CodexReviewMCPHTTPServing)? = nil,
        mcpPortOwnerResolver: CodexReviewMCPPortOwnerResolver? = nil,
        mcpHTTPServerBindChecker: CodexReviewMCPHTTPServerBindChecker? = nil,
        shutdownCleanupTimeout: Duration = .seconds(2),
        networkMonitor: any CodexReviewNetworkMonitoring = SystemCodexReviewNetworkMonitor(),
        networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy = .default,
        appServerLifecycleHandler: CodexReviewAppServerLifecycleHandler? = nil,
        transportFactory: @escaping @MainActor @Sendable (URL) async throws -> FakeCodexAppServerTransport
    ) -> CodexReviewStore {
        makeLiveStoreForTesting(
            environment: environment,
            runtimePreferences: runtimePreferences,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory,
            externalURLOpener: externalURLOpener,
            mcpHTTPServerFactory: mcpHTTPServerFactory,
            mcpPortOwnerResolver: mcpPortOwnerResolver,
            mcpHTTPServerBindChecker: mcpHTTPServerBindChecker,
            shutdownCleanupTimeout: shutdownCleanupTimeout,
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: networkRecoveryPolicy,
            appServerLifecycleHandler: appServerLifecycleHandler,
            appServerFactory: { codexHomeURL in
                let transport = try await transportFactory(codexHomeURL)
                return try await CodexAppServerTestRuntime.start(
                    transport: transport,
                    codexHome: codexHomeURL.path
                ).server
            }
        )
    }
}

@Suite("host composition")
@MainActor
struct CodexReviewHostTests {
    @Test func hostStartsAndStopsRuntimeWithFakeBackend() async {
        let backend = FakeCodexReviewBackend()
        let host = CodexReviewHost(
            backend: backend,
            endpoint: URL(string: "http://localhost:9417/mcp")
        )

        await host.start()
        #expect(host.store.serverState == .running)
        #expect(host.store.serverURL == URL(string: "http://localhost:9417/mcp"))

        await host.stop()
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
        #expect(commands.first == .readSettings)
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
        let transport = FakeCodexAppServerTransport()
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

    @Test func liveStorePublishesPrimaryAppServerLifecycle() async throws {
        let homeURL = try temporaryHome()
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        var observedLifecycleStates: [Bool] = []
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: { _, configuration in
                NoopMCPHTTPServer(endpoint: configuration.url())
            },
            mcpHTTPServerBindChecker: { _ in },
            appServerLifecycleHandler: { appServer in
                observedLifecycleStates.append(appServer != nil)
            },
            transportFactory: { _ in transport }
        )

        await store.start(forceRestartIfNeeded: true)

        #expect(store.serverState == .running)
        #expect(observedLifecycleStates == [true])

        await store.stop()

        #expect(observedLifecycleStates == [true, false])
    }

    @Test func liveStorePassesRuntimePreferenceMCPPortAndPathToHTTPServerFactory() async throws {
        let homeURL = try temporaryHome()
        let transport = FakeCodexAppServerTransport()
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
        await store.stop()
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
                return FakeCodexAppServerTransport()
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
                return FakeCodexAppServerTransport()
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
            transport: FakeCodexAppServerTransport()
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

    @Test func liveStoreSkipsRateLimitRefreshForUnsupportedActiveAccount() async throws {
        let transport = FakeCodexAppServerTransport()
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

    @Test func liveStoreCompletesBrowserLoginFromAccountNotifications() async throws {
        let transport = FakeCodexAppServerTransport()
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
        let externalURLOpener = FakeExternalURLOpener()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.CodexReviewMonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: sessions.makeSession,
            externalURLOpener: externalURLOpener.open,
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await transport.waitForNotificationStreamCount(1)
        await store.addAccount()
        await transport.waitForRequestCount(5)
        #expect(store.auth.isAuthenticating)
        #expect(sessions.createdSessionCount == 0)
        #expect(externalURLOpener.openedURLs == [URL(string: "https://example.com/auth")!])
        try await transport.emitServerNotification(
            method: "account/login/completed",
            params: TestLoginCompletedNotification(loginID: "login-1", success: true)
        )
        try await transport.emitServerNotification(
            method: "account/updated",
            params: EmptyResponse()
        )
        await waitUntil { store.auth.selectedAccount?.accountKey == "new@example.com" }
        let loginRequest = try #require(await transport.recordedRequests().first {
            $0.method == "account/login/start"
        })
        let loginParams = try JSONDecoder().decode(AppServerAPI.Account.Login.Params.self, from: loginRequest.params)
        #expect(loginParams.nativeWebAuthentication == nil)
        let methods = await transport.recordedRequests().map(\.method)
        #expect(methods == [
            "initialize",
            "account/read",
            "config/read",
            "model/list",
            "account/login/start",
            "account/read",
            "account/rateLimits/read",
        ])
        await store.stop()
    }

    @Test func liveStoreUsesExternalBrowserWhenNativeSessionFactoryIsConfigured() async throws {
        let transport = FakeCodexAppServerTransport()
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
        try await transport.enqueue(
            AppServerAPI.Account.Login.Cancel.Response(),
            for: "account/login/cancel"
        )
        var didCreateNativeSession = false
        let externalURLOpener = FakeExternalURLOpener()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.CodexReviewMonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: { _, _, _, _ in
                didCreateNativeSession = true
                throw CodexReviewAPI.Error.io("Authentication presentation failed.")
            },
            externalURLOpener: externalURLOpener.open,
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await store.addAccount()
        await transport.waitForRequestCount(5)

        #expect(didCreateNativeSession == false)
        #expect(store.auth.isAuthenticating)
        #expect(externalURLOpener.openedURLs == [URL(string: "https://example.com/auth")!])
        #expect(Array(await transport.recordedRequests().map(\.method).prefix(5)) == [
            "initialize",
            "account/read",
            "config/read",
            "model/list",
            "account/login/start",
        ])
        await store.stop()
    }

    @Test func liveStoreAddsAccountWithoutSwitchingExistingActiveAccount() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let mainTransport = FakeCodexAppServerTransport()
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

        let authTransport = FakeCodexAppServerTransport()
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
        let refreshTransport = FakeCodexAppServerTransport()
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
        await authTransport.waitForNotificationStreamCount(1)
        await authTransport.waitForRequestCount(2)
        #expect(sessions.createdSessionCount == 0)
        #expect(externalURLOpener.openedURLs == [URL(string: "https://example.com/auth")!])
        let loginRequest = try #require(await authTransport.recordedRequests().first {
            $0.method == "account/login/start"
        })
        let loginParams = try JSONDecoder().decode(AppServerAPI.Account.Login.Params.self, from: loginRequest.params)
        #expect(loginParams.nativeWebAuthentication == nil)
        try await authTransport.emitServerNotification(
            method: "account/login/completed",
            params: TestLoginCompletedNotification(loginID: "login-2", success: true)
        )
        try await authTransport.emitServerNotification(
            method: "account/updated",
            params: EmptyResponse()
        )
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

        let mainTransport = FakeCodexAppServerTransport()
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

        let refreshTransport = FakeCodexAppServerTransport()
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
        let transport = FakeCodexAppServerTransport()
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
        let externalURLOpener = FakeExternalURLOpener()
        let sessions = FakeWebAuthenticationSessions()
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
                #expect(codexHomeURL == mainCodexHomeURL)
                return transport
            }
        )

        await store.start(forceRestartIfNeeded: true)
        #expect(store.auth.selectedAccount == nil)
        #expect(store.auth.persistedAccounts.map(\.accountKey) == ["existing@example.com"])

        await store.addAccount()
        await transport.waitForRequestCount(5)
        #expect(sessions.createdSessionCount == 0)
        #expect(externalURLOpener.openedURLs == [URL(string: "https://example.com/auth")!])
        try await transport.emitServerNotification(
            method: "account/login/completed",
            params: TestLoginCompletedNotification(loginID: "login-new", success: true)
        )
        try await transport.emitServerNotification(
            method: "account/updated",
            params: EmptyResponse()
        )
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
            "account/read",
            "account/rateLimits/read",
        ])
    }

    @Test func liveStoreAddAccountUsesExternalBrowserWhenNativeSessionFactoryFails() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "active@example.com",
            accounts: ["active@example.com"]
        )
        let mainTransport = FakeCodexAppServerTransport()
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
        let loginTransport = FakeCodexAppServerTransport()
        try await loginTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await loginTransport.enqueue(
            AppServerAPI.Account.Login.Response.chatgpt(
                loginID: "login-2",
                authURL: "https://example.com/auth",
                nativeWebAuthentication: .init(callbackURLScheme: "lynnpd.CodexReviewMonitor.auth")
            ),
            for: "account/login/start"
        )
        try await loginTransport.enqueue(
            AppServerAPI.Account.Login.Cancel.Response(),
            for: "account/login/cancel"
        )
        var isolatedCodexHomeURL: URL?
        let externalURLOpener = FakeExternalURLOpener()
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
            externalURLOpener: externalURLOpener.open,
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
        await loginTransport.waitForRequestCount(2)

        let resolvedIsolatedCodexHomeURL = try #require(isolatedCodexHomeURL)
        #expect(store.auth.authenticationFailureCount == previousFailureCount)
        #expect(store.auth.isAuthenticating)
        #expect(store.auth.selectedAccount?.accountKey == "active@example.com")
        #expect(externalURLOpener.openedURLs == [URL(string: "https://example.com/auth")!])
        await store.stop()
        #expect(FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path) == false)
        #expect(Array(await loginTransport.recordedRequests().map(\.method).prefix(2)) == [
            "initialize",
            "account/login/start",
        ])
    }

    @Test func liveStoreIgnoresNonCodexRateLimitNotifications() async throws {
        let transport = FakeCodexAppServerTransport()
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

        let firstTransport = FakeCodexAppServerTransport()
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

        let secondTransport = FakeCodexAppServerTransport()
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

        try await store.switchAccount(CodexReviewKit.CodexReviewAccount(email: "second@example.com"))
        let result = try await reviewRead
        await secondTransport.waitForRequestCount(2)
        await firstTransport.waitForRequestCount(8)

        #expect(result.core.lifecycle.status == .cancelled)
        #expect(result.core.lifecycle.cancellation?.message == "Account switched.")
        #expect(store.auth.selectedAccount?.accountKey == "second@example.com")
        #expect(await firstTransport.recordedRequests().map(\.method).contains("turn/interrupt"))
        #expect(await secondTransport.recordedRequests().map(\.method).contains("account/read"))
    }

    @Test func liveStoreSignOutRestartsRuntimeAndCancelsRunningReviews() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "active@example.com",
            accounts: ["active@example.com"]
        )

        let firstTransport = FakeCodexAppServerTransport()
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
        try await firstTransport.enqueue(EmptyResponse(), for: "account/logout")

        let secondTransport = FakeCodexAppServerTransport()
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

        await store.logout()
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

        let transport = FakeCodexAppServerTransport()
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
            try await store.switchAccount(CodexReviewKit.CodexReviewAccount(email: "second@example.com"))
        }

        #expect(store.auth.selectedAccount?.accountKey == "first@example.com")
        #expect(try activeAccountKey(homeURL: homeURL) == "first@example.com")
        #expect(try Data(contentsOf: mainCodexHomeURL.appendingPathComponent("auth.json")) == originalAuth)
    }

    @Test func liveStoreStopLetsHTTPServerCancelSessionsBeforeDroppingBackend() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let interruptGate = AsyncGate()
        let transport = FakeCodexAppServerTransport()
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
        try await transport.enqueue(EmptyResponse(), for: "thread/delete")
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
        await interruptGate.open()
        await stopTask.value
        let result = try await reviewRead

        #expect(interruptStarted)
        #expect(methodsBeforeInterruptCompletes.contains("turn/interrupt"))
        #expect(methodsBeforeInterruptCompletes.contains("thread/delete") == false)
        #expect(result.core.lifecycle.status == .cancelled)
        let methods = await transport.recordedRequests().map(\.method)
        let interruptIndex = try #require(methods.firstIndex(of: "turn/interrupt"))
        let deleteIndex = try #require(methods.firstIndex(of: "thread/delete"))
        #expect(interruptIndex < deleteIndex)
    }

    @Test func liveStoreStopBoundsStuckReviewCancellationCleanup() async throws {
        let homeURL = try temporaryHome()
        let interruptGate = AsyncGate()
        let transport = FakeCodexAppServerTransport()
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
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            shutdownCleanupTimeout: .milliseconds(20),
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        let reviewRead = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        await waitUntil { store.jobs.first?.core.run.turnID == "turn-1" }

        let startedAt = Date()
        await store.stop()
        let elapsed = Date().timeIntervalSince(startedAt)
        let resultBeforeRemoteCleanupUnblocked = try await waitForTaskValue(reviewRead, timeout: .seconds(1))
        await interruptGate.open()
        let result = try #require(resultBeforeRemoteCleanupUnblocked)

        #expect(elapsed < 1)
        #expect(result.core.lifecycle.status == .cancelled)
        #expect(await transport.recordedRequests().map(\.method).contains("turn/interrupt"))
    }

    @Test func liveStoreStopCleansRecoveryWaitingReviewWithoutAppServerCleanup() async throws {
        let homeURL = try temporaryHome()
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let transport = FakeCodexAppServerTransport()
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
        try await transport.enqueueThreadResume(.init(id: "review-thread-1"))
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await transport.enqueue(EmptyResponse(), for: "thread/delete")
        try await transport.enqueue(EmptyResponse(), for: "thread/delete")
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            shutdownCleanupTimeout: .seconds(1),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in }),
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await transport.waitForNotificationStreamCount(1)
        let reviewRead = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        try #require(await waitUntil(timeout: .seconds(2)) { store.jobs.first?.core.run.turnID == "turn-1" })

        networkMonitor.yield(.init(status: .unsatisfied))
        try #require(await waitUntil(timeout: .seconds(2)) {
            await transport.recordedRequests().map(\.method).contains("turn/interrupt")
        })

        let stopFinished = CompletionFlag()
        let stopTask = Task { @MainActor in
            await store.stop()
            await stopFinished.complete()
        }
        await stopTask.value
        let result = try await reviewRead.value
        let methods = await transport.recordedRequests().map(\.method)

        #expect(await stopFinished.isCompleted())
        #expect(result.core.lifecycle.status == .cancelled)
        #expect(methods.contains("turn/interrupt"))
        #expect(methods.filter { $0 == "thread/delete" }.count == 2)
    }

    @Test func liveStoreMarksRuntimeFailedWhenAppServerNotificationStreamCloses() async throws {
        let homeURL = try temporaryHome()
        let transport = FakeCodexAppServerTransport()
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
        await transport.finishNotificationStreams(throwing: TestTransportClosedError())
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
        let mainTransport = FakeCodexAppServerTransport()
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
        let loginTransport = FakeCodexAppServerTransport()
        try await loginTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await loginTransport.enqueue(
            AppServerAPI.Account.Login.Response.chatgpt(
                loginID: "login-1",
                authURL: "https://example.com/auth",
                nativeWebAuthentication: .init(callbackURLScheme: "lynnpd.CodexReviewMonitor.auth")
            ),
            for: "account/login/start"
        )
        let externalURLOpener = FakeExternalURLOpener()
        var isolatedCodexHomeURL: URL?
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.CodexReviewMonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            externalURLOpener: externalURLOpener.open,
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
        let resolvedIsolatedCodexHomeURL = try #require(isolatedCodexHomeURL)
        #expect(FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path))
        #expect(externalURLOpener.openedURLs == [URL(string: "https://example.com/auth")!])

        await mainTransport.finishNotificationStreams(throwing: TestTransportClosedError())
        await waitUntil {
            if case .failed = store.serverState {
                return true
            }
            return false
        }
        await waitUntil {
            FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path) == false
        }
        #expect(FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path) == false)
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

        let firstTransport = FakeCodexAppServerTransport()
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

        let secondTransport = FakeCodexAppServerTransport()
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
                return FakeCodexAppServerTransport()
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
        let mainTransport = FakeCodexAppServerTransport()
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
        let loginTransport = FakeCodexAppServerTransport()
        try await loginTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        await loginTransport.enqueueFailure(
            code: -32603,
            message: "login unavailable",
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

    @Test func liveStoreClosesIsolatedLoginRuntimeWhenLoginCompletionNotificationFails() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "active@example.com",
            accounts: ["active@example.com"]
        )
        let mainTransport = FakeCodexAppServerTransport()
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
        let loginTransport = FakeCodexAppServerTransport()
        try await loginTransport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await loginTransport.enqueue(
            AppServerAPI.Account.Login.Response.chatgpt(
                loginID: "login-2",
                authURL: "https://example.com/auth",
                nativeWebAuthentication: .init(callbackURLScheme: "lynnpd.CodexReviewMonitor.auth")
            ),
            for: "account/login/start"
        )
        let externalURLOpener = FakeExternalURLOpener()
        var isolatedCodexHomeURL: URL?
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.CodexReviewMonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            externalURLOpener: externalURLOpener.open,
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
        await loginTransport.waitForNotificationStreamCount(1)
        #expect(externalURLOpener.openedURLs == [URL(string: "https://example.com/auth")!])
        try await loginTransport.emitServerNotification(
            method: "account/login/completed",
            params: TestLoginCompletedNotification(
                loginID: "login-2",
                success: false,
                error: "login completion failed"
            )
        )

        let resolvedIsolatedCodexHomeURL = try #require(isolatedCodexHomeURL)
        await waitUntil { failedMessage(from: store.auth.phase) == "login completion failed" }
        await waitUntil {
            FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path) == false
        }
        #expect(FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path) == false)
        #expect(await loginTransport.recordedRequests().map(\.method) == [
            "initialize",
            "account/login/start",
        ])
    }

    @Test func liveStoreRemovesOnlyEncodedSavedAccountDirectory() async throws {
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let account = CodexReviewKit.CodexReviewAccount(email: "../outside@example.com")
        let rawFallbackDirectoryURL = codexHomeURL.appendingPathComponent("outside@example.com", isDirectory: true)
        try FileManager.default.createDirectory(at: rawFallbackDirectoryURL, withIntermediateDirectories: true)
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transport: FakeCodexAppServerTransport()
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

        let dotAccount = CodexReviewKit.CodexReviewAccount(email: ".")
        let dotDotAccount = CodexReviewKit.CodexReviewAccount(email: "..")
        let dotDirectoryURL = accountsURL.appendingPathComponent("%2E", isDirectory: true)
        let dotDotDirectoryURL = accountsURL.appendingPathComponent("%2E%2E", isDirectory: true)
        try FileManager.default.createDirectory(at: dotDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dotDotDirectoryURL, withIntermediateDirectories: true)
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transport: FakeCodexAppServerTransport()
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

private struct TestTransportClosedError: LocalizedError, Equatable, Sendable {
    var errorDescription: String? {
        "JSON-RPC transport is closed."
    }
}

private struct EmptyResponse: Codable, Equatable, Sendable {
    init() {}
}

private enum AppServerAPI {
    enum Initialize {
        struct Response: Codable, Equatable, Sendable {
            var codexHome: String?
            var userAgent: String?

            init(codexHome: String? = nil, userAgent: String? = nil) {
                self.codexHome = codexHome
                self.userAgent = userAgent
            }
        }
    }

    enum Config {
        enum Read {
            struct Response: Codable, Equatable, Sendable {
                var config: Snapshot
            }
        }

        struct Snapshot: Codable, Equatable, Sendable {
            var model: String?
            var reviewModel: String?
            var modelReasoningEffort: String?
            var serviceTier: String?

            enum CodingKeys: String, CodingKey {
                case model
                case reviewModel = "review_model"
                case modelReasoningEffort = "model_reasoning_effort"
                case serviceTier = "service_tier"
            }

            init(
                model: String? = nil,
                reviewModel: String? = nil,
                modelReasoningEffort: String? = nil,
                serviceTier: String? = nil
            ) {
                self.model = model
                self.reviewModel = reviewModel
                self.modelReasoningEffort = modelReasoningEffort
                self.serviceTier = serviceTier
            }
        }
    }

    enum Model {
        enum List {
            struct Response: Codable, Equatable, Sendable {
                var data: [CodexModel]
                var nextCursor: String?

                init(data: [CodexModel], nextCursor: String? = nil) {
                    self.data = data
                    self.nextCursor = nextCursor
                }
            }
        }
    }

    enum Thread {
        enum Start {
            struct Response: Codable, Equatable, Sendable {
                var threadID: String
                var model: String?

                enum CodingKeys: String, CodingKey {
                    case thread
                    case model
                }

                private struct Thread: Codable, Equatable, Sendable {
                    var id: String
                }

                init(threadID: String, model: String? = nil) {
                    self.threadID = threadID
                    self.model = model
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    threadID = try container.decode(Thread.self, forKey: .thread).id
                    model = try container.decodeIfPresent(String.self, forKey: .model)
                }

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(Thread(id: threadID), forKey: .thread)
                    try container.encodeIfPresent(model, forKey: .model)
                }
            }
        }
    }

    enum Review {
        enum Start {
            struct Response: Codable, Equatable, Sendable {
                var turnID: String
                var reviewThreadID: String?

                enum CodingKeys: String, CodingKey {
                    case turn
                    case reviewThreadID = "reviewThreadId"
                }

                private struct Turn: Codable, Equatable, Sendable {
                    var id: String
                }

                init(turnID: String, reviewThreadID: String? = nil) {
                    self.turnID = turnID
                    self.reviewThreadID = reviewThreadID
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    turnID = try container.decode(Turn.self, forKey: .turn).id
                    reviewThreadID = try container.decodeIfPresent(String.self, forKey: .reviewThreadID)
                }

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(Turn(id: turnID), forKey: .turn)
                    try container.encodeIfPresent(reviewThreadID, forKey: .reviewThreadID)
                }
            }
        }
    }

    enum Account {
        enum Read {
            struct Response: Codable, Equatable, Sendable {
                var account: Snapshot?
                var requiresOpenAIAuth: Bool

                enum CodingKeys: String, CodingKey {
                    case account
                    case requiresOpenAIAuth = "requiresOpenaiAuth"
                }

                init(account: Snapshot? = nil, requiresOpenAIAuth: Bool = false) {
                    self.account = account
                    self.requiresOpenAIAuth = requiresOpenAIAuth
                }
            }
        }

        struct Snapshot: Codable, Equatable, Sendable {
            var type: String
            var email: String?
            var planType: String?

            init(type: String = "chatgpt", email: String? = nil, planType: String? = nil) {
                self.type = type
                self.email = email
                self.planType = planType
            }
        }

        enum RateLimits {
            struct Response: Codable, Equatable, Sendable {
                var rateLimits: Snapshot
                var rateLimitsByLimitID: [String: Snapshot]?

                enum CodingKeys: String, CodingKey {
                    case rateLimits
                    case rateLimitsByLimitID = "rateLimitsByLimitId"
                }

                init(rateLimits: Snapshot, rateLimitsByLimitID: [String: Snapshot]? = nil) {
                    self.rateLimits = rateLimits
                    self.rateLimitsByLimitID = rateLimitsByLimitID
                }
            }

            struct Snapshot: Codable, Equatable, Sendable {
                var limitID: String?
                var primary: Window?
                var secondary: Window?
                var planType: String?

                enum CodingKeys: String, CodingKey {
                    case limitID = "limitId"
                    case primary
                    case secondary
                    case planType
                }

                init(
                    limitID: String? = nil,
                    primary: Window? = nil,
                    secondary: Window? = nil,
                    planType: String? = nil
                ) {
                    self.limitID = limitID
                    self.primary = primary
                    self.secondary = secondary
                    self.planType = planType
                }
            }

            struct Window: Codable, Equatable, Sendable {
                var usedPercent: Int
                var windowDurationMins: Int?
                var resetsAt: Int64?

                init(usedPercent: Int, windowDurationMins: Int? = nil, resetsAt: Int64? = nil) {
                    self.usedPercent = usedPercent
                    self.windowDurationMins = windowDurationMins
                    self.resetsAt = resetsAt
                }
            }
        }

        enum Login {
            struct Params: Codable, Equatable, Sendable {
                var type: String
                var apiKey: String?
                var codexStreamlinedLogin: Bool
                var nativeWebAuthentication: NativeWebAuthentication?

                init(
                    type: String = "chatgpt",
                    apiKey: String? = nil,
                    codexStreamlinedLogin: Bool = true,
                    nativeWebAuthentication: NativeWebAuthentication? = nil
                ) {
                    self.type = type
                    self.apiKey = apiKey
                    self.codexStreamlinedLogin = codexStreamlinedLogin
                    self.nativeWebAuthentication = nativeWebAuthentication
                }
            }

            struct NativeWebAuthentication: Codable, Equatable, Sendable {
                var callbackURLScheme: String

                enum CodingKeys: String, CodingKey {
                    case callbackURLScheme = "callbackUrlScheme"
                }
            }

            enum Complete {
                struct Params: Codable, Equatable, Sendable {
                    var loginID: String
                    var callbackURL: String

                    enum CodingKeys: String, CodingKey {
                        case loginID = "loginId"
                        case callbackURL = "callbackUrl"
                    }
                }

                struct Response: Codable, Equatable, Sendable {
                    init() {}
                }
            }

            enum Response: Codable, Equatable, Sendable {
                case apiKey
                case chatgpt(
                    loginID: String,
                    authURL: String,
                    nativeWebAuthentication: NativeWebAuthentication?
                )
                case chatgptDeviceCode(loginID: String, verificationURL: String, userCode: String)
                case chatgptAuthTokens

                private enum CodingKeys: String, CodingKey {
                    case type
                    case loginID = "loginId"
                    case authURL = "authUrl"
                    case nativeWebAuthentication
                    case verificationURL = "verificationUrl"
                    case userCode
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    switch try container.decode(String.self, forKey: .type) {
                    case "apiKey":
                        self = .apiKey
                    case "chatgpt":
                        self = .chatgpt(
                            loginID: try container.decode(String.self, forKey: .loginID),
                            authURL: try container.decode(String.self, forKey: .authURL),
                            nativeWebAuthentication: try container.decodeIfPresent(
                                NativeWebAuthentication.self,
                                forKey: .nativeWebAuthentication
                            )
                        )
                    case "chatgptDeviceCode":
                        self = .chatgptDeviceCode(
                            loginID: try container.decode(String.self, forKey: .loginID),
                            verificationURL: try container.decode(String.self, forKey: .verificationURL),
                            userCode: try container.decode(String.self, forKey: .userCode)
                        )
                    case "chatgptAuthTokens":
                        self = .chatgptAuthTokens
                    case let type:
                        throw DecodingError.dataCorruptedError(
                            forKey: .type,
                            in: container,
                            debugDescription: "Unsupported login response type: \(type)"
                        )
                    }
                }

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    switch self {
                    case .apiKey:
                        try container.encode("apiKey", forKey: .type)
                    case .chatgpt(let loginID, let authURL, let nativeWebAuthentication):
                        try container.encode("chatgpt", forKey: .type)
                        try container.encode(loginID, forKey: .loginID)
                        try container.encode(authURL, forKey: .authURL)
                        try container.encodeIfPresent(nativeWebAuthentication, forKey: .nativeWebAuthentication)
                    case .chatgptDeviceCode(let loginID, let verificationURL, let userCode):
                        try container.encode("chatgptDeviceCode", forKey: .type)
                        try container.encode(loginID, forKey: .loginID)
                        try container.encode(verificationURL, forKey: .verificationURL)
                        try container.encode(userCode, forKey: .userCode)
                    case .chatgptAuthTokens:
                        try container.encode("chatgptAuthTokens", forKey: .type)
                    }
                }
            }

            enum Cancel {
                struct Response: Codable, Equatable, Sendable {
                    init() {}
                }
            }

        }
    }
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
