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

    @Test func recoveryEnvironmentResolvesVersionedRuntimePaths() throws {
        let homeURL = try temporaryHome()
        let environment = recoveryEnvironment(homeURL: homeURL)
        let recoveryURL = recoveryDirectoryURL(homeURL: homeURL)

        #expect(environment.recoveryDirectoryURL == recoveryURL)
        #expect(environment.codexHomeURL == recoveryURL.appendingPathComponent("CodexHome", isDirectory: true))
        #expect(
            environment.codexSQLiteHomeURL
                == recoveryURL
                    .appendingPathComponent("CodexHome", isDirectory: true)
                    .appendingPathComponent("sqlite", isDirectory: true)
        )
        #expect(
            environment.loginStagingDirectoryURL
                == recoveryURL.appendingPathComponent("LoginStaging", isDirectory: true)
        )
        #expect(
            environment.savedAccountsDirectoryURL
                == recoveryURL.appendingPathComponent("SavedAccounts", isDirectory: true)
        )
        #expect(environment.historyDatabaseURL == recoveryURL.appendingPathComponent("review-history.sqlite"))
    }

    @Test func runtimePreferencesDefaultStoreDoesNotReadOrOverwriteLegacyKey() throws {
        let suiteName = "CodexReviewRuntime.RecoveryPreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let legacyKey = "codexReview.runtimePreferences"
        let legacyPreferences = CodexReviewRuntime.Preferences(mcpPort: 50101)
        let legacyData = try JSONEncoder().encode(legacyPreferences)
        defaults.set(legacyData, forKey: legacyKey)
        let store = CodexReviewRuntime.UserDefaultsPreferencesStore(defaults: defaults)

        #expect(store.load() == .defaults)

        let recoveryPreferences = CodexReviewRuntime.Preferences(mcpPort: 50102)
        try store.save(recoveryPreferences)

        #expect(defaults.data(forKey: legacyKey) == legacyData)
        let recoveryData = try #require(
            defaults.data(forKey: CodexReviewRuntime.recoveryRuntimePreferencesKey)
        )
        #expect(try JSONDecoder().decode(CodexReviewRuntime.Preferences.self, from: recoveryData) == recoveryPreferences)
    }

    @Test func liveStorePreparesIsolatedRecoveryEnvironmentBeforeAdmission() async throws {
        let homeURL = try temporaryHome()
        let environment = recoveryEnvironment(homeURL: homeURL)
        let legacyCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let suiteName = "CodexReviewRuntime.RecoveryProbeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let preferencesStore = CodexReviewRuntime.UserDefaultsPreferencesStore(defaults: defaults)
        try preferencesStore.save(.init(mcpPort: 50103))
        let runtimePreferences = preferencesStore.load()
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        var didCheckMCPBind = false
        var capturedCodexHomeURL: URL?
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            recoveryEnvironment: environment,
            runtimePreferences: runtimePreferences,
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: { _, configuration in
                #expect(configuration.port == 50103)
                return NoopMCPHTTPServer(endpoint: configuration.url())
            },
            mcpHTTPServerBindChecker: { configuration in
                #expect(configuration.port == 50103)
                for directoryURL in recoveryOwnedDirectories(environment) {
                    let permissions = try posixPermissions(at: directoryURL)
                    #expect(permissions == 0o700)
                }
                didCheckMCPBind = true
            },
            transportFactory: { codexHomeURL in
                #expect(didCheckMCPBind)
                capturedCodexHomeURL = codexHomeURL
                for directoryURL in recoveryOwnedDirectories(environment) {
                    let permissions = try posixPermissions(at: directoryURL)
                    #expect(permissions == 0o700)
                }
                return transport
            }
        )

        await store.start(forceRestartIfNeeded: true)

        #expect(store.serverState == .running)
        #expect(capturedCodexHomeURL == environment.codexHomeURL)
        #expect(FileManager.default.fileExists(atPath: legacyCodexHomeURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: environment.historyDatabaseURL.path) == false)
        await store.stop()
    }

    @Test func liveStoreRejectsLegacyCodexHomeBeforeAdmission() async throws {
        let homeURL = try temporaryHome()
        let environment = recoveryEnvironment(homeURL: homeURL)
        let legacyCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyCodexHomeURL, withIntermediateDirectories: true)
        let sentinelURL = legacyCodexHomeURL.appendingPathComponent("sentinel")
        try Data("legacy".utf8).write(to: sentinelURL)
        var didCheckMCPBind = false
        var didCreateAppServer = false
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            recoveryEnvironment: environment,
            runtimePreferences: .init(codexHomePath: legacyCodexHomeURL.path),
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerBindChecker: { _ in
                didCheckMCPBind = true
            },
            transportFactory: { _ in
                didCreateAppServer = true
                return FakeJSONRPCTransport()
            }
        )

        await store.start(forceRestartIfNeeded: true)

        guard case .failed(let message) = store.serverState else {
            Issue.record("Expected legacy Codex home admission to fail.")
            return
        }
        #expect(message.contains("read-only migration input"))
        #expect(didCheckMCPBind == false)
        #expect(didCreateAppServer == false)
        #expect(try Data(contentsOf: sentinelURL) == Data("legacy".utf8))
        #expect(FileManager.default.fileExists(atPath: environment.recoveryDirectoryURL.path) == false)
    }

    @Test func liveStoreSurfacesDirectoryPreparationFailureBeforeAdmission() async throws {
        let homeURL = try temporaryHome()
        let recoveryURL = homeURL.appendingPathComponent("RecoveryV1")
        try Data("not a directory".utf8).write(to: recoveryURL)
        let environment = CodexReviewRecoveryEnvironment(
            recoveryDirectoryURL: recoveryURL,
            legacyCodexHomeURL: homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        )
        var didCheckMCPBind = false
        var didCreateAppServer = false
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            recoveryEnvironment: environment,
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerBindChecker: { _ in
                didCheckMCPBind = true
            },
            transportFactory: { _ in
                didCreateAppServer = true
                return FakeJSONRPCTransport()
            }
        )

        await #expect(throws: CodexReviewRecoveryEnvironmentError.self) {
            try await environment.prepare()
        }
        await store.start(forceRestartIfNeeded: true)

        guard case .failed(let message) = store.serverState else {
            Issue.record("Expected RecoveryV1 preparation to fail.")
            return
        }
        #expect(message.contains("Unable to prepare the RecoveryV1 directory"))
        #expect(didCheckMCPBind == false)
        #expect(didCreateAppServer == false)
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
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
            runtimePreferences: .init(codexHomePath: configuredCodexHomeURL.path),
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transportFactory: { codexHomeURL in
                #expect(codexHomeURL == configuredCodexHomeURL)
                return transport
            }
        )

        await store.start(forceRestartIfNeeded: true)

        #expect(store.serverState == .running)
        #expect(try posixPermissions(at: configuredCodexHomeURL) == 0o700)
        #expect(FileManager.default.fileExists(
            atPath: recoveryEnvironment(homeURL: homeURL).historyDatabaseURL.path
        ) == false)
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
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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
        let homeURL = try temporaryHome()
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
            environment: ["HOME": homeURL.path],
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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
        let homeURL = try temporaryHome()
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
            environment: ["HOME": homeURL.path],
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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
        let homeURL = try temporaryHome()
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
            environment: ["HOME": homeURL.path],
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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
        let environment = recoveryEnvironment(homeURL: homeURL)
        let mainCodexHomeURL = environment.codexHomeURL
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
            recoveryEnvironment: environment,
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
                #expect(codexHomeURL.deletingLastPathComponent() == environment.loginStagingDirectoryURL)
                let stagingPermissions = try posixPermissions(at: codexHomeURL)
                #expect(stagingPermissions == 0o700)
                let stagingSQLitePermissions = try posixPermissions(
                    at: AppServerCodexHome.sqliteHomeURL(for: codexHomeURL)
                )
                #expect(stagingSQLitePermissions == 0o700)
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
        #expect(
            try posixPermissions(
                at: environment.savedAccountsDirectoryURL
                    .appendingPathComponent("new%40example.com", isDirectory: true)
            ) == 0o700
        )
        #expect(await refreshTransport.recordedRequests().map(\.method) == [
            "initialize",
            "account/read",
            "account/rateLimits/read",
        ])
    }

    @Test func liveStoreDoesNotApplySavedAccountRateLimitsFromDifferentAuth() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = recoveryEnvironment(homeURL: homeURL).codexHomeURL
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
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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

    @Test func liveStoreRemovesRateLimitStagingHomeWhenSavedAuthIsMissing() async throws {
        let homeURL = try temporaryHome()
        let environment = recoveryEnvironment(homeURL: homeURL)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "active@example.com",
            accounts: ["active@example.com", "missing@example.com"]
        )
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(
            AppServerAPI.Account.Read.Response(
                account: .init(email: "active@example.com", planType: "pro")
            ),
            for: "account/read"
        )
        try await transport.enqueue(
            AppServerAPI.Account.RateLimits.Response(rateLimits: .init(
                limitID: "codex",
                primary: .init(usedPercent: 10, windowDurationMins: 300)
            )),
            for: "account/rateLimits/read"
        )
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        var nonPrimaryRuntimeCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            recoveryEnvironment: environment,
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transportFactory: { codexHomeURL in
                guard codexHomeURL != environment.codexHomeURL else {
                    return transport
                }
                nonPrimaryRuntimeCount += 1
                return FakeJSONRPCTransport()
            }
        )

        await store.start(forceRestartIfNeeded: true)
        await store.refreshAccountRateLimits(accountKey: "missing@example.com")

        #expect(nonPrimaryRuntimeCount == 0)
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: environment.loginStagingDirectoryURL.path
            ).isEmpty
        )
        #expect(
            store.auth.persistedAccounts
                .first { $0.accountKey == "missing@example.com" }?
                .requiresReauthentication == true
        )
        await store.stop()
    }

    @Test func liveStoreAddAccountActivatesNewLoginWhenPersistedAccountsHaveNoActiveAccount() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = recoveryEnvironment(homeURL: homeURL).codexHomeURL
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
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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
        let mainCodexHomeURL = recoveryEnvironment(homeURL: homeURL).codexHomeURL
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
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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
        let homeURL = try temporaryHome()
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
            environment: ["HOME": homeURL.path],
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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
        let mainCodexHomeURL = recoveryEnvironment(homeURL: homeURL).codexHomeURL
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
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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

    @Test func liveStoreSignOutRestartsRuntimeAndCancelsRunningReviews() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = recoveryEnvironment(homeURL: homeURL).codexHomeURL
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
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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
        let mainCodexHomeURL = recoveryEnvironment(homeURL: homeURL).codexHomeURL
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
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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
        let mainCodexHomeURL = recoveryEnvironment(homeURL: homeURL).codexHomeURL
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
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            shutdownCleanupTimeout: .seconds(1),
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
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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
        let mainCodexHomeURL = recoveryEnvironment(homeURL: homeURL).codexHomeURL
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
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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
    }

    @Test func liveStoreRemovingActiveAccountClearsSharedAuthAndRestartsSignedOutRuntime() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = recoveryEnvironment(homeURL: homeURL).codexHomeURL
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "active@example.com",
            accounts: ["active@example.com"]
        )
        try FileManager.default.createDirectory(
            at: mainCodexHomeURL,
            withIntermediateDirectories: true
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
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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
        let mainCodexHomeURL = recoveryEnvironment(homeURL: homeURL).codexHomeURL
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
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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
        let mainCodexHomeURL = recoveryEnvironment(homeURL: homeURL).codexHomeURL
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
            recoveryEnvironment: recoveryEnvironment(homeURL: homeURL),
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
        let environment = recoveryEnvironment(homeURL: homeURL)
        let account = CodexAccount(email: "../outside@example.com")
        let rawFallbackDirectoryURL = environment.recoveryDirectoryURL
            .appendingPathComponent("outside@example.com", isDirectory: true)
        try FileManager.default.createDirectory(at: rawFallbackDirectoryURL, withIntermediateDirectories: true)
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            recoveryEnvironment: environment,
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transport: FakeJSONRPCTransport()
        )
        store.auth.applyPersistedAccountStates([savedAccountPayload(from: account)])

        try await store.removeAccount(accountKey: account.accountKey)

        #expect(FileManager.default.fileExists(atPath: rawFallbackDirectoryURL.path))
    }

    @Test func liveStoreEncodesSpecialSavedAccountDirectoryNames() async throws {
        let homeURL = try temporaryHome()
        let environment = recoveryEnvironment(homeURL: homeURL)
        let accountsURL = environment.savedAccountsDirectoryURL
        try FileManager.default.createDirectory(at: accountsURL, withIntermediateDirectories: true)
        let sentinelURL = environment.recoveryDirectoryURL.appendingPathComponent("sentinel.txt")
        try Data("keep".utf8).write(to: sentinelURL)

        let dotAccount = CodexAccount(email: ".")
        let dotDotAccount = CodexAccount(email: "..")
        let dotDirectoryURL = accountsURL.appendingPathComponent("%2E", isDirectory: true)
        let dotDotDirectoryURL = accountsURL.appendingPathComponent("%2E%2E", isDirectory: true)
        try FileManager.default.createDirectory(at: dotDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dotDotDirectoryURL, withIntermediateDirectories: true)
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            recoveryEnvironment: environment,
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transport: FakeJSONRPCTransport()
        )
        store.auth.applyPersistedAccountStates([
            savedAccountPayload(from: dotAccount),
            savedAccountPayload(from: dotDotAccount),
        ])

        try await store.removeAccount(accountKey: dotAccount.accountKey)
        try await store.removeAccount(accountKey: dotDotAccount.accountKey)

        #expect(FileManager.default.fileExists(atPath: environment.recoveryDirectoryURL.path))
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

private func recoveryEnvironment(homeURL: URL) -> CodexReviewRecoveryEnvironment {
    CodexReviewRecoveryEnvironment(
        recoveryDirectoryURL: recoveryDirectoryURL(homeURL: homeURL),
        legacyCodexHomeURL: homeURL.appendingPathComponent(
            ".codex_review",
            isDirectory: true
        )
    )
}

private func recoveryDirectoryURL(homeURL: URL) -> URL {
    homeURL
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("CodexReviewMonitor", isDirectory: true)
        .appendingPathComponent("RecoveryV1", isDirectory: true)
}

private func recoveryOwnedDirectories(
    _ environment: CodexReviewRecoveryEnvironment
) -> [URL] {
    [
        environment.recoveryDirectoryURL,
        environment.codexHomeURL,
        environment.codexSQLiteHomeURL,
        environment.loginStagingDirectoryURL,
        environment.savedAccountsDirectoryURL,
    ]
}

private func posixPermissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
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
    let registryURL = recoveryDirectoryURL(homeURL: homeURL)
        .appendingPathComponent("SavedAccounts", isDirectory: true)
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
    let authURL = recoveryDirectoryURL(homeURL: homeURL)
        .appendingPathComponent("SavedAccounts", isDirectory: true)
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
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("CodexReviewMonitor", isDirectory: true)
        .appendingPathComponent("RecoveryV1", isDirectory: true)
        .appendingPathComponent("SavedAccounts", isDirectory: true)
        .appendingPathComponent(pathComponent(forAccountKey: accountKey), isDirectory: true)
        .appendingPathComponent("auth.json"))
}

private func activeAccountKey(homeURL: URL) throws -> String? {
    let registryURL = recoveryDirectoryURL(homeURL: homeURL)
        .appendingPathComponent("SavedAccounts", isDirectory: true)
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
