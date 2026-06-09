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
        await backend.waitForEventStream()

        let commands = await backend.recordedCommands()
        #expect(commands.first == .readSettings)
        let startReview = try #require(commands.compactMap { command -> BackendReviewStart? in
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
        let preferences = CodexReviewRuntimePreferences(
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
            let preferences = CodexReviewRuntimePreferences(mcpHost: host)
            #expect(preferences.mcpHost == "localhost")
        }
    }

    @Test func runtimePreferencesKeepValidMCPHosts() {
        for host in ["localhost", "127.0.0.1", "0.0.0.0", "example.com", "xn--bcher-kva.de"] {
            let preferences = CodexReviewRuntimePreferences(mcpHost: host)
            #expect(preferences.mcpHost == host)
        }
    }

    @Test func runtimePreferencesDefaultEscapedMCPPaths() {
        for path in ["custom mcp", "/custom?mcp", "/custom#mcp", "/custom%20mcp"] {
            let preferences = CodexReviewRuntimePreferences(mcpPath: path)
            #expect(preferences.mcpPath == "/mcp")
        }
    }

    @Test func runtimePreferencesDefaultRelativePaths() {
        let preferences = CodexReviewRuntimePreferences(
            codexHomePath: "tmp/home",
            codexExecutablePath: "codex"
        )

        #expect(preferences.codexHomePath == nil)
        #expect(preferences.codexExecutablePath == nil)
    }

    @Test func runtimePreferencesExpandHomeRelativePaths() {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let preferences = CodexReviewRuntimePreferences(
            codexHomePath: " ~/.codex_review ",
            codexExecutablePath: " ~/bin/codex "
        )

        #expect(preferences.codexHomePath == "\(homePath)/.codex_review")
        #expect(preferences.codexExecutablePath == "\(homePath)/bin/codex")

        let homeOnlyPreferences = CodexReviewRuntimePreferences(codexHomePath: "~")
        #expect(homeOnlyPreferences.codexHomePath == homePath)
    }

    @Test func userDefaultsRuntimePreferencesStoreRoundTripsNormalizedPreferences() throws {
        let suiteName = "CodexReviewRuntimePreferencesStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = UserDefaultsCodexReviewRuntimePreferencesStore(defaults: defaults)

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
        try await transport.enqueue(InitializeResponse(), for: "initialize")
        try await transport.enqueue(AccountReadResponse(), for: "account/read")
        try await transport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(ModelListResponse(data: []), for: "model/list")
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
        try await transport.enqueue(InitializeResponse(), for: "initialize")
        try await transport.enqueue(AccountReadResponse(), for: "account/read")
        try await transport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(ModelListResponse(data: []), for: "model/list")
        var capturedConfiguration: CodexReviewMCPHTTPServerConfiguration?
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
            transportFactory: { _ in transport }
        )

        await store.start(forceRestartIfNeeded: true)
        let serverURL = try #require(store.serverURL)

        #expect(capturedConfiguration?.port == 54321)
        #expect(capturedConfiguration?.endpoint == "/custom-mcp")
        #expect(serverURL.path == "/custom-mcp")
        await store.stop()
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
        try await transport.enqueue(InitializeResponse(), for: "initialize")
        try await transport.enqueue(
            TestAccountReadResponse(account: .init(type: "apiKey")),
            for: "account/read"
        )
        try await transport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(ModelListResponse(data: []), for: "model/list")
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
        try await transport.enqueue(InitializeResponse(), for: "initialize")
        try await transport.enqueue(AccountReadResponse(), for: "account/read")
        try await transport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(ModelListResponse(data: []), for: "model/list")
        try await transport.enqueue(
            LoginAccountResponse.chatgpt(
                loginID: "login-1",
                authURL: "https://example.com/auth",
                nativeWebAuthentication: .init(callbackURLScheme: "lynnpd.CodexReviewMonitor.auth")
            ),
            for: "account/login/start"
        )
        try await transport.enqueue(CancelLoginAccountResponse(), for: "account/login/cancel")
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
        try await transport.enqueue(InitializeResponse(), for: "initialize")
        try await transport.enqueue(AccountReadResponse(), for: "account/read")
        try await transport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(ModelListResponse(data: []), for: "model/list")
        try await transport.enqueue(
            LoginAccountResponse.chatgpt(
                loginID: "login-1",
                authURL: "https://example.com/auth",
                nativeWebAuthentication: .init(callbackURLScheme: "lynnpd.CodexReviewMonitor.auth")
            ),
            for: "account/login/start"
        )
        try await transport.enqueue(CancelLoginAccountResponse(), for: "account/login/cancel")
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.CodexReviewMonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: { _, _, _, _ in
                throw ReviewError.io("Authentication presentation failed.")
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
        try await mainTransport.enqueue(InitializeResponse(), for: "initialize")
        try await mainTransport.enqueue(
            AccountReadResponse(
                account: .init(email: "active@example.com", planType: "pro")
            ),
            for: "account/read"
        )
        try await mainTransport.enqueue(
            AppServerAccountRateLimitsResponse(rateLimits: .init(
                limitID: "codex",
                primary: .init(usedPercent: 10, windowDurationMins: 300)
            )),
            for: "account/rateLimits/read"
        )
        try await mainTransport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await mainTransport.enqueue(ModelListResponse(data: []), for: "model/list")

        let authTransport = FakeJSONRPCTransport()
        try await authTransport.enqueue(InitializeResponse(), for: "initialize")
        try await authTransport.enqueue(
            LoginAccountResponse.chatgpt(
                loginID: "login-2",
                authURL: "https://example.com/auth",
                nativeWebAuthentication: nil
            ),
            for: "account/login/start"
        )
        try await authTransport.enqueue(
            AccountReadResponse(
                account: .init(email: "new@example.com", planType: "plus")
            ),
            for: "account/read"
        )
        try await authTransport.enqueue(
            AppServerAccountRateLimitsResponse(rateLimits: .init(
                limitID: "codex",
                primary: .init(usedPercent: 25, windowDurationMins: 300)
            )),
            for: "account/rateLimits/read"
        )
        let refreshTransport = FakeJSONRPCTransport()
        let refreshGate = AsyncGate()
        await refreshTransport.hold(method: "account/rateLimits/read", gate: refreshGate)
        try await refreshTransport.enqueue(InitializeResponse(), for: "initialize")
        try await refreshTransport.enqueue(
            AccountReadResponse(
                account: .init(email: "new@example.com", planType: "plus")
            ),
            for: "account/read"
        )
        try await refreshTransport.enqueue(
            AppServerAccountRateLimitsResponse(rateLimits: .init(
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
        let loginParams = try JSONDecoder().decode(LoginAccountParams.self, from: loginRequest.params)
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
        try await mainTransport.enqueue(InitializeResponse(), for: "initialize")
        try await mainTransport.enqueue(
            AccountReadResponse(account: .init(email: "active@example.com", planType: "pro")),
            for: "account/read"
        )
        try await mainTransport.enqueue(
            AppServerAccountRateLimitsResponse(rateLimits: .init(
                limitID: "codex",
                primary: .init(usedPercent: 10, windowDurationMins: 300)
            )),
            for: "account/rateLimits/read"
        )
        try await mainTransport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await mainTransport.enqueue(ModelListResponse(data: []), for: "model/list")

        let refreshTransport = FakeJSONRPCTransport()
        try await refreshTransport.enqueue(InitializeResponse(), for: "initialize")
        try await refreshTransport.enqueue(
            AccountReadResponse(account: .init(email: "active@example.com", planType: "pro")),
            for: "account/read"
        )
        try await refreshTransport.enqueue(
            AppServerAccountRateLimitsResponse(rateLimits: .init(
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
        try await transport.enqueue(InitializeResponse(), for: "initialize")
        try await transport.enqueue(AccountReadResponse(), for: "account/read")
        try await transport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(ModelListResponse(data: []), for: "model/list")
        try await transport.enqueue(
            LoginAccountResponse.chatgpt(
                loginID: "login-new",
                authURL: "https://example.com/auth",
                nativeWebAuthentication: .init(callbackURLScheme: "lynnpd.CodexReviewMonitor.auth")
            ),
            for: "account/login/start"
        )
        try await transport.enqueue(CompleteLoginAccountResponse(), for: "account/login/complete")
        try await transport.enqueue(
            AccountReadResponse(account: .init(email: "new@example.com", planType: "plus")),
            for: "account/read"
        )
        try await transport.enqueue(
            AppServerAccountRateLimitsResponse(rateLimits: .init(
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
        try await mainTransport.enqueue(InitializeResponse(), for: "initialize")
        try await mainTransport.enqueue(
            AccountReadResponse(account: .init(email: "active@example.com", planType: "pro")),
            for: "account/read"
        )
        try await mainTransport.enqueue(
            AppServerAccountRateLimitsResponse(rateLimits: .init(
                limitID: "codex",
                primary: .init(usedPercent: 10, windowDurationMins: 300)
            )),
            for: "account/rateLimits/read"
        )
        try await mainTransport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await mainTransport.enqueue(ModelListResponse(data: []), for: "model/list")
        let loginTransport = FakeJSONRPCTransport()
        try await loginTransport.enqueue(InitializeResponse(), for: "initialize")
        try await loginTransport.enqueue(
            LoginAccountResponse.chatgpt(
                loginID: "login-2",
                authURL: "https://example.com/auth",
                nativeWebAuthentication: .init(callbackURLScheme: "lynnpd.CodexReviewMonitor.auth")
            ),
            for: "account/login/start"
        )
        try await loginTransport.enqueue(CancelLoginAccountResponse(), for: "account/login/cancel")
        var isolatedCodexHomeURL: URL?
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.CodexReviewMonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: { _, _, _, _ in
                throw ReviewError.io("Authentication presentation failed.")
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
        try await transport.enqueue(InitializeResponse(), for: "initialize")
        try await transport.enqueue(
            AccountReadResponse(account: .init(email: "active@example.com", planType: "pro")),
            for: "account/read"
        )
        try await transport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(ModelListResponse(data: []), for: "model/list")
        try await transport.enqueue(
            AppServerAccountRateLimitsResponse(rateLimits: .init(
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
        try await firstTransport.enqueue(InitializeResponse(), for: "initialize")
        try await firstTransport.enqueue(
            AccountReadResponse(account: .init(email: "first@example.com", planType: "pro")),
            for: "account/read"
        )
        try await firstTransport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await firstTransport.enqueue(ModelListResponse(data: []), for: "model/list")
        try await firstTransport.enqueue(
            AppServerAccountRateLimitsResponse(rateLimits: .init(
                limitID: "codex",
                primary: .init(usedPercent: 10, windowDurationMins: 300)
            )),
            for: "account/rateLimits/read"
        )
        try await firstTransport.enqueue(ThreadStartResponse(threadID: "thread-first", model: "gpt-5"), for: "thread/start")
        try await firstTransport.enqueue(ReviewStartResponse(turnID: "turn-first"), for: "review/start")
        try await firstTransport.enqueue(EmptyResponse(), for: "turn/interrupt")

        let secondTransport = FakeJSONRPCTransport()
        try await secondTransport.enqueue(InitializeResponse(), for: "initialize")
        try await secondTransport.enqueue(
            AccountReadResponse(account: .init(email: "second@example.com", planType: "plus")),
            for: "account/read"
        )
        try await secondTransport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await secondTransport.enqueue(ModelListResponse(data: []), for: "model/list")
        try await secondTransport.enqueue(
            AppServerAccountRateLimitsResponse(rateLimits: .init(
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

        try await store.switchAccount(CodexAccount(email: "second@example.com"))
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

        let firstTransport = FakeJSONRPCTransport()
        try await firstTransport.enqueue(InitializeResponse(), for: "initialize")
        try await firstTransport.enqueue(
            AccountReadResponse(account: .init(email: "active@example.com", planType: "pro")),
            for: "account/read"
        )
        try await firstTransport.enqueue(AccountReadResponse(), for: "account/read")
        try await firstTransport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await firstTransport.enqueue(ModelListResponse(data: []), for: "model/list")
        try await firstTransport.enqueue(
            AppServerAccountRateLimitsResponse(rateLimits: .init(
                limitID: "codex",
                primary: .init(usedPercent: 10, windowDurationMins: 300)
            )),
            for: "account/rateLimits/read"
        )
        try await firstTransport.enqueue(ThreadStartResponse(threadID: "thread-active", model: "gpt-5"), for: "thread/start")
        try await firstTransport.enqueue(ReviewStartResponse(turnID: "turn-active"), for: "review/start")
        try await firstTransport.enqueue(EmptyResponse(), for: "turn/interrupt")
        try await firstTransport.enqueue(EmptyResponse(), for: "account/logout")

        let secondTransport = FakeJSONRPCTransport()
        try await secondTransport.enqueue(InitializeResponse(), for: "initialize")
        try await secondTransport.enqueue(AccountReadResponse(), for: "account/read")
        try await secondTransport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await secondTransport.enqueue(ModelListResponse(data: []), for: "model/list")

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

        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(InitializeResponse(), for: "initialize")
        try await transport.enqueue(
            AccountReadResponse(account: .init(email: "first@example.com", planType: "pro")),
            for: "account/read"
        )
        try await transport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(ModelListResponse(data: []), for: "model/list")
        try await transport.enqueue(
            AppServerAccountRateLimitsResponse(rateLimits: .init(
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
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(InitializeResponse(), for: "initialize")
        try await transport.enqueue(AccountReadResponse(), for: "account/read")
        try await transport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(ModelListResponse(data: []), for: "model/list")
        try await transport.enqueue(ThreadStartResponse(threadID: "thread-1", model: "gpt-5"), for: "thread/start")
        try await transport.enqueue(ReviewStartResponse(turnID: "turn-1"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: { store, _ in
                CodexReviewMCPHTTPServer(
                    adapter: CodexReviewMCPServer(store: store),
                    configuration: .init(port: 0)
                )
            },
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

        await store.stop()
        let result = try await reviewRead

        #expect(result.core.lifecycle.status == .cancelled)
        #expect(await transport.recordedRequests().map(\.method).contains("turn/interrupt"))
    }

    @Test func liveStoreMarksRuntimeFailedWhenAppServerNotificationStreamCloses() async throws {
        let homeURL = try temporaryHome()
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(InitializeResponse(), for: "initialize")
        try await transport.enqueue(AccountReadResponse(), for: "account/read")
        try await transport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(ModelListResponse(data: []), for: "model/list")
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await transport.waitForNotificationStreamCount(1)
        await transport.finishNotificationStreams(throwing: JSONRPCError.closed)
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
        try await mainTransport.enqueue(InitializeResponse(), for: "initialize")
        try await mainTransport.enqueue(
            AccountReadResponse(account: .init(email: "active@example.com", planType: "pro")),
            for: "account/read"
        )
        try await mainTransport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await mainTransport.enqueue(ModelListResponse(data: []), for: "model/list")
        let loginTransport = FakeJSONRPCTransport()
        try await loginTransport.enqueue(InitializeResponse(), for: "initialize")
        try await loginTransport.enqueue(
            LoginAccountResponse.chatgpt(
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

        await mainTransport.finishNotificationStreams(throwing: JSONRPCError.closed)
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
        await #expect(throws: JSONRPCError.closed) {
            _ = try await loginTransport.send(JSONRPCRequest(id: 99, method: "ping", params: Data()))
        }
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
        try await firstTransport.enqueue(InitializeResponse(), for: "initialize")
        try await firstTransport.enqueue(
            AccountReadResponse(account: .init(email: "active@example.com", planType: "pro")),
            for: "account/read"
        )
        try await firstTransport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await firstTransport.enqueue(ModelListResponse(data: []), for: "model/list")
        try await firstTransport.enqueue(
            AppServerAccountRateLimitsResponse(rateLimits: .init(
                limitID: "codex",
                primary: .init(usedPercent: 10, windowDurationMins: 300)
            )),
            for: "account/rateLimits/read"
        )
        try await firstTransport.enqueue(EmptyResponse(), for: "account/logout")

        let secondTransport = FakeJSONRPCTransport()
        try await secondTransport.enqueue(InitializeResponse(), for: "initialize")
        try await secondTransport.enqueue(AccountReadResponse(), for: "account/read")
        try await secondTransport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await secondTransport.enqueue(ModelListResponse(data: []), for: "model/list")

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
        try await mainTransport.enqueue(InitializeResponse(), for: "initialize")
        try await mainTransport.enqueue(
            AccountReadResponse(account: .init(email: "active@example.com", planType: "pro")),
            for: "account/read"
        )
        try await mainTransport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await mainTransport.enqueue(ModelListResponse(data: []), for: "model/list")
        let loginTransport = FakeJSONRPCTransport()
        try await loginTransport.enqueue(InitializeResponse(), for: "initialize")
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
        try await mainTransport.enqueue(InitializeResponse(), for: "initialize")
        try await mainTransport.enqueue(
            AccountReadResponse(account: .init(email: "active@example.com", planType: "pro")),
            for: "account/read"
        )
        try await mainTransport.enqueue(
            ConfigReadResponse(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await mainTransport.enqueue(ModelListResponse(data: []), for: "model/list")
        let loginTransport = FakeJSONRPCTransport()
        try await loginTransport.enqueue(InitializeResponse(), for: "initialize")
        try await loginTransport.enqueue(
            LoginAccountResponse.chatgpt(
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
    var rateLimits: AppServerRateLimitSnapshotPayload
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
        browserSessionPolicy _: CodexReviewNativeAuthenticationConfiguration.BrowserSessionPolicy,
        presentationAnchorProvider _: @escaping @MainActor @Sendable () -> ASPresentationAnchor?
    ) async throws -> any CodexReviewWebAuthenticationSession {
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
private final class FakeWebAuthenticationSession: CodexReviewWebAuthenticationSession {
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
