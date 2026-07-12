import Foundation
import AppKit
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
        externalURLOpener: @escaping ExternalURLOpener = { _ in },
        mcpPortOwnerResolver: CodexReviewMCPPortOwnerResolver? = nil,
        mcpHTTPServerBindChecker: CodexReviewMCPHTTPServerBindChecker? = nil,
        networkMonitor: any CodexReviewNetworkMonitoring = SystemCodexReviewNetworkMonitor(),
        networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy = .default,
        appServerLifecycleHandler: CodexReviewAppServerLifecycleHandler? = nil,
        transport: FakeCodexAppServerTransport
    ) -> CodexReviewStore {
        makeLiveStoreForTesting(
            environment: environment,
            runtimePreferences: runtimePreferences,
            externalURLOpener: externalURLOpener,
            mcpPortOwnerResolver: mcpPortOwnerResolver,
            mcpHTTPServerBindChecker: mcpHTTPServerBindChecker,
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: networkRecoveryPolicy,
            appServerLifecycleHandler: appServerLifecycleHandler,
            appServerFactory: { codexHomeURL in
                try await CodexAppServerTestRuntime.start(
                    transport: transport,
                    configuration: .init(localProcess: .init(
                        codexHomeURL: codexHomeURL
                    ))
                ).server
            }
        )
    }

    @MainActor
    static func makeLiveStoreForTesting(
        environment: [String: String],
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        externalURLOpener: @escaping ExternalURLOpener = { _ in },
        mcpHTTPServerFactory: (@MainActor @Sendable (
            CodexReviewStore,
            CodexReviewMCPHTTPServer.Configuration,
            ReviewMCPLogProjectionProvider?
        ) -> any CodexReviewMCPHTTPServing)? = nil,
        mcpPortOwnerResolver: CodexReviewMCPPortOwnerResolver? = nil,
        mcpHTTPServerBindChecker: CodexReviewMCPHTTPServerBindChecker? = nil,
        networkMonitor: any CodexReviewNetworkMonitoring = SystemCodexReviewNetworkMonitor(),
        networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy = .default,
        appServerLifecycleHandler: CodexReviewAppServerLifecycleHandler? = nil,
        transportFactory: @escaping @MainActor @Sendable (URL) async throws -> FakeCodexAppServerTransport
    ) -> CodexReviewStore {
        makeLiveStoreForTesting(
            environment: environment,
            runtimePreferences: runtimePreferences,
            externalURLOpener: externalURLOpener,
            mcpHTTPServerFactory: mcpHTTPServerFactory,
            mcpPortOwnerResolver: mcpPortOwnerResolver,
            mcpHTTPServerBindChecker: mcpHTTPServerBindChecker,
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: networkRecoveryPolicy,
            appServerLifecycleHandler: appServerLifecycleHandler,
            appServerFactory: { codexHomeURL in
                let transport = try await transportFactory(codexHomeURL)
                return try await CodexAppServerTestRuntime.start(
                    transport: transport,
                    configuration: .init(localProcess: .init(
                        codexHomeURL: codexHomeURL
                    ))
                ).server
            }
        )
    }
}

@Suite("host composition")
@MainActor
struct CodexReviewHostTests {
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
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            runtimePreferences: .init(codexHomePath: configuredCodexHomeURL.path),
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
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        var observedLifecycleStates: [Bool] = []
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            mcpHTTPServerFactory: { _, configuration, _ in
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
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        var capturedConfiguration: CodexReviewMCPHTTPServer.Configuration?
        var capturedLogProjectionProvider: ReviewMCPLogProjectionProvider?
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            runtimePreferences: .init(
                mcpPort: 54321,
                mcpPath: "custom-mcp"
            ),
            mcpHTTPServerFactory: { store, configuration, logProjectionProvider in
                capturedConfiguration = configuration
                capturedLogProjectionProvider = logProjectionProvider
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
        #expect(capturedLogProjectionProvider != nil)
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
            mcpHTTPServerFactory: { _, configuration, _ in
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
            mcpHTTPServerFactory: { _, configuration, _ in
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

    @Test func liveStoreFailsFastForCorruptAccountRegistry() async throws {
        let homeURL = try temporaryHome()
        let registryURL = homeURL
            .appendingPathComponent(".codex_review", isDirectory: true)
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent("registry.json")
        try FileManager.default.createDirectory(
            at: registryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: registryURL)
        var didLaunchAppServer = false
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transportFactory: { _ in
                didLaunchAppServer = true
                return FakeCodexAppServerTransport()
            }
        )

        await store.start(forceRestartIfNeeded: true)

        #expect(didLaunchAppServer == false)
        #expect(store.auth.errorMessage?.contains("account registry is inconsistent") == true)
        guard case .failed(let message) = store.serverState else {
            Issue.record("Expected corrupt persistence to fail the runtime start.")
            return
        }
        #expect(message.contains("account registry is inconsistent"))
    }

    @Test func liveStoreMigratesLegacyRegistryToVersionedImmutableRevision() throws {
        let homeURL = try temporaryHome()
        let accountKey = "legacy@example.com"
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: accountKey,
            accounts: [accountKey]
        )
        try writeSavedAccountAuth(homeURL: homeURL, accountKey: accountKey)

        _ = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transport: FakeCodexAppServerTransport()
        )

        let registry = try accountRegistryObject(homeURL: homeURL)
        #expect(registry["schemaVersion"] as? Int == 1)
        #expect((registry["generation"] as? Int) == 1)
        #expect((registry["contentHash"] as? String)?.isEmpty == false)
        let records = try #require(registry["accounts"] as? [[String: Any]])
        let record = try #require(records.first)
        let revision = try #require(record["immutableRevision"] as? String)
        let revisionURL = homeURL
            .appendingPathComponent(".codex_review", isDirectory: true)
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(pathComponent(forAccountKey: accountKey), isDirectory: true)
            .appendingPathComponent("revisions", isDirectory: true)
            .appendingPathComponent("\(revision).json")
        #expect(try Data(contentsOf: revisionURL) == Data("{\"tokens\":{\"id_token\":\"legacy@example.com\"}}".utf8))
        let orphanURL = revisionURL.deletingLastPathComponent().appendingPathComponent("orphan.json")
        try Data(#"{"tokens":{"id_token":"orphan@example.com"}}"#.utf8).write(to: orphanURL)

        _ = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transport: FakeCodexAppServerTransport()
        )

        #expect(FileManager.default.fileExists(atPath: revisionURL.path))
        #expect(FileManager.default.fileExists(atPath: orphanURL.path) == false)
    }

    @Test func liveStoreFailsFastForMissingImmutableAuthRevision() async throws {
        let homeURL = try temporaryHome()
        let accountKey = "missing-revision@example.com"
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: accountKey,
            accounts: [accountKey]
        )
        try writeSavedAccountAuth(homeURL: homeURL, accountKey: accountKey)
        _ = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transport: FakeCodexAppServerTransport()
        )
        let registry = try accountRegistryObject(homeURL: homeURL)
        let records = try #require(registry["accounts"] as? [[String: Any]])
        let revision = try #require(records.first?["immutableRevision"] as? String)
        let revisionURL = homeURL
            .appendingPathComponent(".codex_review", isDirectory: true)
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(pathComponent(forAccountKey: accountKey), isDirectory: true)
            .appendingPathComponent("revisions", isDirectory: true)
            .appendingPathComponent("\(revision).json")
        try FileManager.default.removeItem(at: revisionURL)
        var didLaunchAppServer = false
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transportFactory: { _ in
                didLaunchAppServer = true
                return FakeCodexAppServerTransport()
            }
        )

        await store.start(forceRestartIfNeeded: true)

        #expect(didLaunchAppServer == false)
        #expect(store.auth.errorMessage?.contains("account registry is inconsistent") == true)
    }

    @Test func liveStoreFailsFastForRegistryContentHashMismatch() async throws {
        let homeURL = try temporaryHome()
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: nil,
            accounts: ["stored@example.com"]
        )
        _ = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transport: FakeCodexAppServerTransport()
        )
        let registryURL = accountRegistryURL(homeURL: homeURL)
        var registry = try accountRegistryObject(homeURL: homeURL)
        registry["activeAccountKey"] = "stored@example.com"
        try JSONSerialization.data(withJSONObject: registry).write(to: registryURL)
        var didLaunchAppServer = false
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transportFactory: { _ in
                didLaunchAppServer = true
                return FakeCodexAppServerTransport()
            }
        )

        await store.start(forceRestartIfNeeded: true)

        #expect(didLaunchAppServer == false)
        #expect(store.auth.errorMessage?.contains("content hash") == true)
    }

    @Test func liveStoreSkipsRateLimitRefreshForUnsupportedActiveAccount() async throws {
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .apiKey),
            requiresOpenAIAuth: false
        )
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            transport: transport
        )
        await store.start(forceRestartIfNeeded: true)
        await transport.waitForRequestCount(4)
        await store.refreshAccountRateLimits(accountKey: "api-key")
        await Task.yield()

        #expect(store.auth.selectedAccount?.kind == .apiKey)
        #expect(await transport.recordedRequests().map(\.request.operation) == [
            .initialize,
            .accountRead,
            .configurationRead,
            .modelList,
        ])
    }

    @Test func liveStoreCompletesStockLoginAfterAccountReadiness() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueChatGPTLogin(loginID: "login-1", authenticationURL: testAuthenticationURL)
        try await transport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "new@example.com",
                planType: .plus
            )),
            requiresOpenAIAuth: false
        )
        try await transport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 20
        ))
        let externalURLOpener = FakeExternalURLOpener()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            externalURLOpener: externalURLOpener.open,
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await transport.waitForNotificationStreamCount(1)
        try await store.addAccount()
        await transport.waitForRequestCount(5)
        #expect(store.auth.isAuthenticating)
        #expect(externalURLOpener.openedURLs == [testAuthenticationURL])
        do {
            try await store.addAccount()
            Issue.record("Expected an active authentication mutation to reject a second command.")
        } catch let failure as CodexReviewAuthenticationFailure {
            #expect(failure == .alreadyInProgress)
        }
        #expect(store.auth.isAuthenticating)
        #expect(await transport.recordedRequests(for: .accountLoginStart).count == 1)
        do {
            try await store.removeAccount(accountKey: "missing@example.com")
            Issue.record("Expected account mutation rejection while authentication is active.")
        } catch let failure as CodexReviewAuthenticationFailure {
            #expect(failure == .accountMutationBlockedByAuthentication)
        }
        #expect(store.auth.isAuthenticating)
        try FileManager.default.createDirectory(at: mainCodexHomeURL, withIntermediateDirectories: true)
        try Data(#"{"tokens":{"id_token":"new@example.com"}}"#.utf8).write(
            to: mainCodexHomeURL.appendingPathComponent("auth.json")
        )
        try await transport.notificationEmitter.emitLoginCompleted(
            loginID: "login-1",
            completion: .succeeded
        )
        try await transport.notificationEmitter.emitAccountChanged(.init(
            authMode: .chatGPT,
            planType: .plus
        ))
        #expect(await waitUntil(timeout: .seconds(1)) {
            store.auth.selectedAccount?.accountKey == "new@example.com"
        })
        await transport.waitForRequestCount(7)
        #expect(await transport.recordedRequests().map(\.request.operation) == [
            .initialize,
            .accountRead,
            .configurationRead,
            .modelList,
            .accountLoginStart,
            .accountRead,
            .accountRateLimitsRead,
        ])
        await store.stop()
    }

    @Test func liveStoreCancelsLoginWhenOpeningAuthenticationURLFails() async throws {
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueChatGPTLogin(loginID: "login-1", authenticationURL: testAuthenticationURL)
        try await transport.enqueueChatGPTLoginCancellation(.canceled)
        let externalURLOpener = FakeExternalURLOpener(
            failure: CodexReviewAPI.Error.io("Authentication presentation failed.")
        )
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            externalURLOpener: externalURLOpener.open,
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        try await store.addAccount()
        await transport.waitForRequestCount(6)

        #expect(
            failedMessage(from: store.auth.phase)
                == "Failed to open the authentication URL: https://example.com/auth"
        )
        #expect(externalURLOpener.openedURLs == [testAuthenticationURL])
        #expect(await transport.recordedRequests().map(\.request.operation) == [
            .initialize,
            .accountRead,
            .configurationRead,
            .modelList,
            .accountLoginStart,
            .accountLoginCancel,
        ])
        await store.stop()
    }

    @Test func liveStoreJoinsConcurrentCancellationAndStopInOneLoginTermination() async throws {
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueChatGPTLogin(loginID: "login-1", authenticationURL: testAuthenticationURL)
        try await transport.enqueueChatGPTLoginCancellation(.canceled)
        let cancelGate = CodexAppServerTestGate()
        await transport.holdNextIgnoringCancellation(
            .accountLoginCancel,
            gate: cancelGate
        )
        var appServerLifecycleStates: [Bool] = []
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            appServerLifecycleHandler: { container in
                appServerLifecycleStates.append(container != nil)
            },
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        try await store.addAccount()
        await transport.waitForRequest(.accountLoginStart)

        async let cancel: Void = store.cancelAuthentication()
        await transport.waitForRequest(.accountLoginCancel)
        async let stop: Void = store.stop()
        await waitUntil { appServerLifecycleStates == [true, false] }

        #expect(await transport.recordedRequests(for: .accountLoginCancel).count == 1)
        await cancelGate.open()
        await cancel
        await stop

        #expect(await transport.recordedRequests(for: .accountLoginCancel).count == 1)
        #expect(store.auth.isAuthenticating == false)
        #expect(store.serverURL == nil)
    }

    @Test func liveStoreKeepsNewLoginGenerationWhenOldNotificationsArrive() async throws {
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueChatGPTLogin(loginID: "login-old", authenticationURL: testAuthenticationURL)
        try await transport.enqueueChatGPTLoginCancellation(.canceled)
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await transport.waitForNotificationStreamCount(1)
        try await store.addAccount()
        await transport.waitForRequest(.accountLoginStart)
        await store.cancelAuthentication()

        try await transport.enqueueChatGPTLogin(loginID: "login-new", authenticationURL: testAuthenticationURL)
        try await transport.enqueueChatGPTLoginCancellation(.canceled)

        try await store.addAccount()
        await transport.waitForRequest(.accountLoginStart, count: 2)
        try await transport.notificationEmitter.emitLoginCompleted(
            loginID: "login-old",
            completion: .failed(message: "late old-generation completion")
        )
        try await transport.notificationEmitter.emitAccountChanged(.init(
            authMode: .chatGPT,
            planType: .plus
        ))
        await Task.yield()

        #expect(store.auth.isAuthenticating)
        do {
            try await store.addAccount()
            Issue.record("Expected the new login generation to remain active.")
        } catch let failure as CodexReviewAuthenticationFailure {
            #expect(failure == .alreadyInProgress)
        }

        await store.cancelAuthentication()
        #expect(await transport.recordedRequests(for: .accountLoginCancel).count == 2)
        await store.stop()
    }

    @Test func liveStoreInstallsSessionBeforeAnAlreadyCompletedLoginRootRuns() async throws {
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueChatGPTLogin(loginID: "login-early", authenticationURL: testAuthenticationURL)
        try await transport.enqueueChatGPTLoginCancellation(.canceled)
        let loginStartGate = CodexAppServerTestGate()
        await transport.holdNextIgnoringCancellation(
            .accountLoginStart,
            gate: loginStartGate
        )
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await transport.waitForNotificationStreamCount(1)
        let firstLogin = Task { @MainActor in
            try await store.addAccount()
        }
        await transport.waitForRequest(.accountLoginStart)
        await loginStartGate.waitUntilBlocked()
        try await transport.notificationEmitter.emitLoginCompleted(
            loginID: "login-early",
            completion: .failed(message: "login completed before handle publication")
        )
        await loginStartGate.open()
        try await firstLogin.value

        await waitUntil {
            failedMessage(from: store.auth.phase) == "login completed before handle publication"
        }
        #expect(
            failedMessage(from: store.auth.phase)
                == "login completed before handle publication"
        )
        await store.cancelAuthentication()
        try await transport.enqueueChatGPTLogin(loginID: "login-next", authenticationURL: testAuthenticationURL)
        try await store.addAccount()
        await transport.waitForRequest(.accountLoginStart, count: 2)
        #expect(store.auth.isAuthenticating)

        await store.cancelAuthentication()
        #expect(await transport.recordedRequests(for: .accountLoginCancel).count == 1)
        await store.stop()
    }

    @Test func liveStoreAddsAccountWithoutSwitchingExistingActiveAccount() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try FileManager.default.createDirectory(at: mainCodexHomeURL, withIntermediateDirectories: true)
        try Data(#"{"tokens":{"id_token":"active@example.com"}}"#.utf8).write(
            to: mainCodexHomeURL.appendingPathComponent("auth.json")
        )
        let mainTransport = FakeCodexAppServerTransport()
        try await mainTransport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "active@example.com",
                planType: .pro
            )),
            requiresOpenAIAuth: false
        )
        try await mainTransport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 10
        ))
        try await mainTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await mainTransport.enqueueModels(.init(models: []))

        let authTransport = FakeCodexAppServerTransport()
        try await authTransport.enqueueChatGPTLogin(loginID: "login-2", authenticationURL: testAuthenticationURL)
        try await authTransport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "new@example.com",
                planType: .plus
            )),
            requiresOpenAIAuth: false
        )
        try await authTransport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 25
        ))
        let refreshTransport = FakeCodexAppServerTransport()
        let refreshGate = AsyncGate()
        await refreshTransport.holdNext(.accountRateLimitsRead, gate: refreshGate)
        try await refreshTransport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "new@example.com",
                planType: .plus
            )),
            requiresOpenAIAuth: false
        )
        try await refreshTransport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 44
        ))
        var nonPrimaryTransports = [authTransport, refreshTransport]
        var nonPrimaryRuntimeIndex = 0
        var refreshCodexHomeURL: URL?
        let externalURLOpener = FakeExternalURLOpener()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
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

        try await store.addAccount()
        await authTransport.waitForNotificationStreamCount(1)
        await authTransport.waitForRequestCount(2)
        #expect(externalURLOpener.openedURLs == [testAuthenticationURL])
        let loginRequest = try #require(
            await authTransport.recordedRequests(for: .accountLoginStart).first
        )
        #expect(loginRequest.request == .accountLoginStart)
        try await authTransport.notificationEmitter.emitLoginCompleted(
            loginID: "login-2",
            completion: .succeeded
        )
        try await authTransport.notificationEmitter.emitAccountChanged(.init(
            authMode: .chatGPT,
            planType: .plus
        ))
        #expect(await waitUntil(timeout: .seconds(1)) {
            store.auth.persistedAccounts.contains { $0.accountKey == "new@example.com" }
                && store.auth.persistedAccounts.first { $0.accountKey == "new@example.com" }?.rateLimits.first?.usedPercent == 25
                && store.auth.isAuthenticating == false
        })

        #expect(store.auth.selectedAccount?.accountKey == "active@example.com")
        #expect(store.auth.persistedActiveAccountKey == "active@example.com")
        #expect(store.auth.persistedAccounts.map(\.accountKey).contains("new@example.com"))
        #expect(store.auth.persistedAccounts.first { $0.accountKey == "new@example.com" }?.rateLimits.first?.usedPercent == 25)
        #expect(await mainTransport.recordedRequests().map(\.request.operation).contains(.accountLoginStart) == false)
        #expect(await authTransport.recordedRequests().map(\.request.operation) == [
            .initialize,
            .accountLoginStart,
            .accountRead,
            .accountRateLimitsRead,
        ])
        try await store.reorderPersistedAccount(accountKey: "new@example.com", toIndex: 1)
        #expect(store.auth.persistedAccounts.map(\.accountKey) == [
            "active@example.com",
            "new@example.com",
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
        #expect(await refreshTransport.recordedRequests().map(\.request.operation) == [
            .initialize,
            .accountRead,
            .accountRateLimitsRead,
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
        try await mainTransport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "active@example.com",
                planType: .pro
            )),
            requiresOpenAIAuth: false
        )
        try await mainTransport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 10
        ))
        try await mainTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await mainTransport.enqueueModels(.init(models: []))

        let refreshTransport = FakeCodexAppServerTransport()
        try await refreshTransport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "active@example.com",
                planType: .pro
            )),
            requiresOpenAIAuth: false
        )
        try await refreshTransport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 44
        ))

        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
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
        #expect(await refreshTransport.recordedRequests().map(\.request.operation) == [
            .initialize,
            .accountRead,
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
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueChatGPTLogin(loginID: "login-new", authenticationURL: testAuthenticationURL)
        try await transport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "new@example.com",
                planType: .plus
            )),
            requiresOpenAIAuth: false
        )
        try await transport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 20
        ))
        let externalURLOpener = FakeExternalURLOpener()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            externalURLOpener: externalURLOpener.open,
            transportFactory: { codexHomeURL in
                #expect(codexHomeURL == mainCodexHomeURL)
                return transport
            }
        )

        await store.start(forceRestartIfNeeded: true)
        #expect(store.auth.selectedAccount == nil)
        #expect(store.auth.persistedAccounts.map(\.accountKey) == ["existing@example.com"])

        try await store.addAccount()
        await transport.waitForRequestCount(5)
        #expect(externalURLOpener.openedURLs == [testAuthenticationURL])
        try FileManager.default.createDirectory(
            at: mainCodexHomeURL,
            withIntermediateDirectories: true
        )
        try Data(#"{"tokens":{"id_token":"new@example.com"}}"#.utf8).write(
            to: mainCodexHomeURL.appendingPathComponent("auth.json")
        )
        try await transport.notificationEmitter.emitLoginCompleted(
            loginID: "login-new",
            completion: .succeeded
        )
        try await transport.notificationEmitter.emitAccountChanged(.init(
            authMode: .chatGPT,
            planType: .plus
        ))
        await transport.waitForRequestCount(7)
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
        #expect(await transport.recordedRequests().map(\.request.operation) == [
            .initialize,
            .accountRead,
            .configurationRead,
            .modelList,
            .accountLoginStart,
            .accountRead,
            .accountRateLimitsRead,
        ])
    }

    @Test func liveStoreAddAccountCancelsLoginWhenOpeningURLFails() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "active@example.com",
            accounts: ["active@example.com"]
        )
        let mainTransport = FakeCodexAppServerTransport()
        try await mainTransport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "active@example.com",
                planType: .pro
            )),
            requiresOpenAIAuth: false
        )
        try await mainTransport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 10
        ))
        try await mainTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await mainTransport.enqueueModels(.init(models: []))
        let loginTransport = FakeCodexAppServerTransport()
        try await loginTransport.enqueueChatGPTLogin(loginID: "login-2", authenticationURL: testAuthenticationURL)
        try await loginTransport.enqueueChatGPTLoginCancellation(.canceled)
        var isolatedCodexHomeURL: URL?
        let externalURLOpener = FakeExternalURLOpener(
            failure: CodexReviewAPI.Error.io("Authentication presentation failed.")
        )
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
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
        do {
            try await store.addAccount()
            Issue.record("Expected URL presentation failure to propagate to the command.")
        } catch let failure as CodexReviewAuthenticationFailure {
            #expect(failure == .urlOpen(testAuthenticationURL))
        }
        await loginTransport.waitForRequestCount(3)

        let resolvedIsolatedCodexHomeURL = try #require(isolatedCodexHomeURL)
        #expect(
            failedMessage(from: store.auth.phase)
                == "Failed to open the authentication URL: https://example.com/auth"
        )
        #expect(store.auth.selectedAccount?.accountKey == "active@example.com")
        #expect(externalURLOpener.openedURLs == [testAuthenticationURL])
        await store.stop()
        #expect(FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path) == false)
        #expect(await loginTransport.recordedRequests().map(\.request.operation) == [
            .initialize,
            .accountLoginStart,
            .accountLoginCancel,
        ])
    }

    @Test func liveStoreIgnoresNonCodexRateLimitNotifications() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try FileManager.default.createDirectory(at: mainCodexHomeURL, withIntermediateDirectories: true)
        try Data(#"{"tokens":{"id_token":"active@example.com"}}"#.utf8).write(
            to: mainCodexHomeURL.appendingPathComponent("auth.json")
        )
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "active@example.com",
                planType: .pro
            )),
            requiresOpenAIAuth: false
        )
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueRateLimits(try makeHostRateLimits(
            planType: .pro,
            windowDurationMinutes: 300,
            usedPercent: 10
        ))
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await transport.waitForNotificationStreamCount(1)
        #expect(await waitUntil(timeout: .seconds(1)) {
            store.auth.selectedAccount?.rateLimits.first?.usedPercent == 10
        })
        try await transport.notificationEmitter.emitRateLimitsUpdated(.init(snapshot: try .init(
                limitID: "openai",
                limitName: nil,
                primary: .init(
                    usedPercent: 99,
                    windowDurationMinutes: 300,
                    resetsAtUnixSeconds: nil
                ),
                secondary: nil,
                credits: nil,
                individualLimit: nil,
                planType: .pro,
                reachedType: nil
            )))
        try await transport.notificationEmitter.emitRateLimitsUpdated(.init(snapshot: try .init(
                limitID: "codex",
                limitName: nil,
                primary: .init(
                    usedPercent: 11,
                    windowDurationMinutes: 300,
                    resetsAtUnixSeconds: nil
                ),
                secondary: nil,
                credits: nil,
                individualLimit: nil,
                planType: nil,
                reachedType: nil
            )))
        #expect(await waitUntil(timeout: .seconds(1)) {
            store.auth.selectedAccount?.rateLimits.first?.usedPercent == 11
        })
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
        try await firstTransport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "first@example.com",
                planType: .pro
            )),
            requiresOpenAIAuth: false
        )
        try await firstTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await firstTransport.enqueueModels(.init(models: []))
        try await firstTransport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 10
        ))
        try await firstTransport.enqueueThreadStart(threadID: "thread-first", model: "gpt-5")
        try await firstTransport.enqueueReviewStart(turnID: "turn-first", reviewThreadID: "thread-first")
        try await firstTransport.enqueueSuccess(for: .turnInterrupt)

        let secondTransport = FakeCodexAppServerTransport()
        try await secondTransport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "second@example.com",
                planType: .plus
            )),
            requiresOpenAIAuth: false
        )
        try await secondTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await secondTransport.enqueueModels(.init(models: []))
        try await secondTransport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 30
        ))

        var mainTransports = [firstTransport, secondTransport]
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transportFactory: { codexHomeURL in
                #expect(codexHomeURL == mainCodexHomeURL)
                return mainTransports.removeFirst()
            }
        )
        let legacySecondAuthURL = mainCodexHomeURL
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(pathComponent(forAccountKey: "second@example.com"), isDirectory: true)
            .appendingPathComponent("auth.json")
        try FileManager.default.removeItem(at: legacySecondAuthURL)

        await store.start(forceRestartIfNeeded: true)
        async let reviewRead = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await waitUntil { store.reviewRuns.first?.core.attempt?.turnID.rawValue == "turn-first" }

        try await store.switchAccount(CodexReviewKit.CodexReviewAccount(email: "second@example.com"))
        let result = try await reviewRead
        await secondTransport.waitForRequestCount(2)
        await firstTransport.waitForRequestCount(8)

        #expect(result.presentation.status == .cancelled)
        #expect(result.core.cancellation?.message == "Account switched.")
        #expect(store.auth.selectedAccount?.accountKey == "second@example.com")
        #expect(await firstTransport.recordedRequests().map(\.request.operation).contains(.turnInterrupt))
        #expect(await secondTransport.recordedRequests().map(\.request.operation).contains(.accountRead))
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
        try await firstTransport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "active@example.com",
                planType: .pro
            )),
            requiresOpenAIAuth: false
        )
        try await firstTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await firstTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await firstTransport.enqueueModels(.init(models: []))
        try await firstTransport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 10
        ))
        try await firstTransport.enqueueThreadStart(threadID: "thread-active", model: "gpt-5")
        try await firstTransport.enqueueReviewStart(turnID: "turn-active", reviewThreadID: "thread-active")
        try await firstTransport.enqueueSuccess(for: .turnInterrupt)
        try await firstTransport.enqueueSuccess(for: .accountLogout)

        let secondTransport = FakeCodexAppServerTransport()
        try await secondTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await secondTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await secondTransport.enqueueModels(.init(models: []))

        var mainTransports = [firstTransport, secondTransport]
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
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
        await waitUntil { store.reviewRuns.first?.core.attempt?.turnID.rawValue == "turn-active" }

        await store.logout()
        let result = try await reviewRead
        await secondTransport.waitForRequestCount(2)

        let firstMethods = await firstTransport.recordedRequests().map(\.request.operation)
        let interruptIndex = try #require(firstMethods.firstIndex(of: .turnInterrupt))
        let logoutIndex = try #require(firstMethods.firstIndex(of: .accountLogout))
        #expect(interruptIndex < logoutIndex)
        #expect(result.presentation.status == .cancelled)
        #expect(result.core.cancellation?.message == "Signed out.")
        #expect(store.auth.selectedAccount == nil)
        #expect(store.auth.persistedAccounts.isEmpty)
        #expect(await secondTransport.recordedRequests().map(\.request.operation).contains(.accountRead))
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
        try await transport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "first@example.com",
                planType: .pro
            )),
            requiresOpenAIAuth: false
        )
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 10
        ))
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
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
        await transport.holdNext(.turnInterrupt, gate: interruptGate)
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "thread-1")
        try await transport.enqueueSuccess(for: .turnInterrupt)
        try await transport.enqueueSuccess(for: .threadDelete)
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            mcpHTTPServerFactory: { store, _, _ in
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
        await transport.waitForNotificationStreamCount(1)
        let endpoint = try #require(store.serverURL)
        let sessionID = try await initializeMCPSession(endpoint: endpoint)
        async let reviewRead = store.startReview(
            sessionID: sessionID,
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.reviewRuns.first?.core.attempt?.turnID.rawValue == "turn-1"
        })

        let stopTask = Task { @MainActor in
            await store.stop()
        }
        let interruptStarted = await waitUntil(timeout: .seconds(2)) {
            await transport.recordedRequests().map(\.request.operation).contains(.turnInterrupt)
        }
        let methodsBeforeInterruptCompletes = await transport.recordedRequests().map(\.request.operation)
        await interruptGate.open()
        await stopTask.value
        let result = try await reviewRead

        #expect(interruptStarted)
        #expect(methodsBeforeInterruptCompletes.contains(.turnInterrupt))
        #expect(methodsBeforeInterruptCompletes.contains(.threadDelete) == false)
        #expect(result.presentation.status == .cancelled)
        let methods = await transport.recordedRequests().map(\.request.operation)
        let interruptIndex = try #require(methods.firstIndex(of: .turnInterrupt))
        let deleteIndex = try #require(methods.firstIndex(of: .threadDelete))
        #expect(interruptIndex < deleteIndex)
    }

    @Test func liveStoreStopJoinsReviewCancellationCleanup() async throws {
        let homeURL = try temporaryHome()
        let interruptGate = AsyncGate()
        let transport = FakeCodexAppServerTransport()
        await transport.holdNext(.turnInterrupt, gate: interruptGate)
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "thread-1")
        try await transport.enqueueSuccess(for: .turnInterrupt)
        try await transport.enqueueSuccess(for: .threadDelete)
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
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
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.reviewRuns.first?.core.attempt?.turnID.rawValue == "turn-1"
        })

        let stopFinished = CompletionFlag()
        let stopTask = Task { @MainActor in
            await store.stop()
            await stopFinished.complete()
        }
        try #require(await waitUntil(timeout: .seconds(2)) {
            await transport.recordedRequests().map(\.request.operation).contains(.turnInterrupt)
        })
        #expect(await stopFinished.isCompleted() == false)
        await interruptGate.open()
        await stopTask.value
        let result = try await reviewRead.value

        #expect(await stopFinished.isCompleted())
        #expect(result.presentation.status == .cancelled)
        #expect(await transport.recordedRequests().map(\.request.operation).contains(.turnInterrupt))
    }

    @Test func liveStoreStopCleansRecoveryWaitingReviewWithoutAppServerCleanup() async throws {
        let homeURL = try temporaryHome()
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "thread-1")
        try await transport.enqueueThreadResume(makeHostStoredThread(id: "thread-1"))
        try await transport.enqueueSuccess(for: .turnInterrupt)
        try await transport.enqueueSuccess(for: .threadDelete)
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
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
        try #require(
            await waitUntil(timeout: .seconds(2)) {
                store.reviewRuns.first?.core.attempt?.turnID.rawValue == "turn-1"
            }
        )

        networkMonitor.yield(.init(status: .unsatisfied))
        try #require(await waitUntil(timeout: .seconds(2)) {
            await transport.recordedRequests().map(\.request.operation).contains(.turnInterrupt)
        })

        let stopFinished = CompletionFlag()
        let stopTask = Task { @MainActor in
            await store.stop()
            await stopFinished.complete()
        }
        await stopTask.value
        let result = try await reviewRead.value
        let methods = await transport.recordedRequests().map(\.request.operation)

        #expect(await stopFinished.isCompleted())
        #expect(result.presentation.status == .cancelled)
        #expect(methods.contains(.turnInterrupt))
        #expect(methods.filter { $0 == .threadDelete }.count == 1)
    }

    @Test func liveStoreMarksRuntimeFailedWhenAppServerNotificationStreamCloses() async throws {
        let homeURL = try temporaryHome()
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await transport.waitForNotificationStreamCount(1)
        await transport.failConnection(.closed)
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
        #expect(message.contains("The Codex app-server transport is closed."))
        #expect(store.serverURL == nil)
    }

    @Test func liveStoreDoesNotResumeActiveReviewAfterConnectionTerminates() async throws {
        let homeURL = try temporaryHome()
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "thread-1")
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
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
        try #require(
            await waitUntil(timeout: .seconds(2)) {
                store.reviewRuns.first?.core.attempt?.turnID.rawValue == "turn-1"
            }
        )

        await transport.failConnection(.closed)
        try #require(
            await waitUntil(timeout: .seconds(2)) {
                if case .failed = store.serverState {
                    return true
                }
                return false
            }
        )
        let result = try await reviewRead.value
        let methods = await transport.recordedRequests().map(\.request.operation)

        #expect(result.core.isTerminal)
        #expect(store.serverURL == nil)
        #expect(methods.contains(.threadResume) == false)
        #expect(methods.contains(.turnInterrupt) == false)
        #expect(methods.contains(.threadDelete) == false)
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
        try await mainTransport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "active@example.com",
                planType: .pro
            )),
            requiresOpenAIAuth: false
        )
        try await mainTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await mainTransport.enqueueModels(.init(models: []))
        let loginTransport = FakeCodexAppServerTransport()
        try await loginTransport.enqueueChatGPTLogin(loginID: "login-1", authenticationURL: testAuthenticationURL)
        try await loginTransport.enqueueChatGPTLoginCancellation(.canceled)
        let externalURLOpener = FakeExternalURLOpener()
        var isolatedCodexHomeURL: URL?
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
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
        try await store.addAccount()
        await loginTransport.waitForRequestCount(2)
        let resolvedIsolatedCodexHomeURL = try #require(isolatedCodexHomeURL)
        #expect(FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path))
        #expect(externalURLOpener.openedURLs == [testAuthenticationURL])

        await mainTransport.failConnection(.closed)
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
        #expect(await loginTransport.recordedRequests(for: .accountLoginCancel).count == 1)
        #expect(store.auth.isAuthenticating == false)
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
        try await firstTransport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "active@example.com",
                planType: .pro
            )),
            requiresOpenAIAuth: false
        )
        try await firstTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await firstTransport.enqueueModels(.init(models: []))
        try await firstTransport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 10
        ))
        try await firstTransport.enqueueSuccess(for: .accountLogout)
        try await firstTransport.enqueueAccount(nil, requiresOpenAIAuth: false)

        let secondTransport = FakeCodexAppServerTransport()
        try await secondTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await secondTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await secondTransport.enqueueModels(.init(models: []))

        var mainTransports = [firstTransport, secondTransport]
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
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
        #expect(await firstTransport.recordedRequests().map(\.request.operation).contains(.accountLogout))
        #expect(await secondTransport.recordedRequests().map(\.request.operation).contains(.accountRead))
    }

    @Test func liveStoreFsyncsRemovalJournalBeforeUpstreamLogout() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "active@example.com",
            accounts: ["active@example.com"]
        )
        try Data("{\"tokens\":{\"id_token\":\"test\"}}".utf8)
            .write(to: mainCodexHomeURL.appendingPathComponent("auth.json"))
        let logoutGate = AsyncGate()
        let firstTransport = FakeCodexAppServerTransport()
        try await firstTransport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "active@example.com",
                planType: .pro
            )),
            requiresOpenAIAuth: false
        )
        try await firstTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await firstTransport.enqueueModels(.init(models: []))
        try await firstTransport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 10
        ))
        try await firstTransport.enqueueSuccess(for: .accountLogout)
        try await firstTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        await firstTransport.holdNext(.accountLogout, gate: logoutGate)
        let secondTransport = FakeCodexAppServerTransport()
        try await secondTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await secondTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await secondTransport.enqueueModels(.init(models: []))
        var transports = [firstTransport, secondTransport]
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transportFactory: { _ in transports.removeFirst() }
        )
        await store.start(forceRestartIfNeeded: true)

        let removal = Task {
            try await store.removeAccount(accountKey: "active@example.com")
        }
        await firstTransport.waitForRequestCount(6)
        let journalData = try Data(contentsOf: accountMutationJournalURL(homeURL: homeURL))
        let journal = try #require(JSONSerialization.jsonObject(with: journalData) as? [String: Any])
        #expect(journal["phase"] as? String == "prepared")
        #expect(journal["mayApplyIrreversibleLogout"] as? Bool == true)
        try await firstTransport.notificationEmitter.emitRateLimitsUpdated(.init(snapshot: try .init(
                limitID: "codex",
                limitName: nil,
                primary: .init(
                    usedPercent: 12,
                    windowDurationMinutes: 300,
                    resetsAtUnixSeconds: nil
                ),
                secondary: nil,
                credits: nil,
                individualLimit: nil,
                planType: nil,
                reachedType: nil
            )))
        #expect(await waitUntil(timeout: .seconds(1)) {
            store.auth.selectedAccount?.rateLimits.first?.usedPercent == 12
        })
        #expect(
            try Data(contentsOf: accountMutationJournalURL(homeURL: homeURL))
                == journalData
        )

        let recoveryHomeURL = try temporaryHome()
        let recoveryAccountsURL = recoveryHomeURL
            .appendingPathComponent(".codex_review", isDirectory: true)
            .appendingPathComponent("accounts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recoveryAccountsURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: mainCodexHomeURL
                .appendingPathComponent("accounts", isDirectory: true)
                .appendingPathComponent(pathComponent(forAccountKey: "active@example.com"), isDirectory: true),
            to: recoveryAccountsURL
                .appendingPathComponent(pathComponent(forAccountKey: "active@example.com"), isDirectory: true)
        )
        let beforeRegistry = try #require(journal["beforeRegistry"] as? [String: Any])
        try JSONSerialization.data(withJSONObject: beforeRegistry).write(
            to: recoveryAccountsURL.appendingPathComponent("registry.json")
        )
        try journalData.write(
            to: recoveryAccountsURL.appendingPathComponent("mutation-journal.json")
        )
        let recoveredStore = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": recoveryHomeURL.path],
            transport: FakeCodexAppServerTransport()
        )
        #expect(recoveredStore.auth.errorMessage == nil)
        #expect(recoveredStore.auth.persistedAccounts.isEmpty)
        #expect(recoveredStore.auth.persistedActiveAccountKey == nil)
        #expect(
            FileManager.default.fileExists(
                atPath: accountMutationJournalURL(homeURL: recoveryHomeURL).path
            ) == false
        )

        await logoutGate.open()
        try await removal.value

        #expect(FileManager.default.fileExists(atPath: accountMutationJournalURL(homeURL: homeURL).path) == false)
        #expect(try activeAccountKey(homeURL: homeURL) == nil)
    }

    @Test func liveStoreAbortsPreparedRemovalWhenUpstreamLogoutFails() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "active@example.com",
            accounts: ["active@example.com"]
        )
        let originalAuth = try Data(
            contentsOf: mainCodexHomeURL.appendingPathComponent("auth.json")
        )
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "active@example.com",
                planType: .pro
            )),
            requiresOpenAIAuth: false
        )
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 10
        ))
        try await transport.enqueueFailure(
            .response(code: -32603, message: "logout unavailable"),
            for: .accountLogout
        )
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transport: transport
        )
        await store.start(forceRestartIfNeeded: true)

        do {
            try await store.signOutActiveAccount()
            Issue.record("Expected upstream logout failure to abort the prepared account mutation.")
        } catch {
            #expect(error.localizedDescription.contains("logout unavailable"))
        }

        #expect(store.auth.selectedAccount?.accountKey == "active@example.com")
        #expect(try activeAccountKey(homeURL: homeURL) == "active@example.com")
        #expect(
            try Data(contentsOf: mainCodexHomeURL.appendingPathComponent("auth.json"))
                == originalAuth
        )
        #expect(
            FileManager.default.fileExists(
                atPath: accountMutationJournalURL(homeURL: homeURL).path
            ) == false
        )
        await store.stop()
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
            transportFactory: { codexHomeURL in
                isolatedCodexHomeURL = codexHomeURL
                try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
                return FakeCodexAppServerTransport()
            }
        )

        do {
            try await store.addAccount()
            Issue.record("Expected unavailable main runtime to propagate to the add-account command.")
        } catch let failure as CodexReviewAuthenticationFailure {
            #expect(failure == .runtime(message: "Review runtime is not running."))
        }

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
        try await mainTransport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "active@example.com",
                planType: .pro
            )),
            requiresOpenAIAuth: false
        )
        try await mainTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await mainTransport.enqueueModels(.init(models: []))
        let loginTransport = FakeCodexAppServerTransport()
        try await loginTransport.enqueueFailure(
            .response(code: -32603, message: "login unavailable"),
            for: .accountLoginStart
        )
        var isolatedCodexHomeURL: URL?
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
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
        do {
            try await store.addAccount()
            Issue.record("Expected login-start failure to propagate to the command.")
        } catch let failure as CodexReviewAuthenticationFailure {
            #expect(
                failure
                    == .runtime(
                        message: "JSON-RPC request 2 (account/login/start) was rejected by the server: login unavailable"
                    )
            )
        }

        let resolvedIsolatedCodexHomeURL = try #require(isolatedCodexHomeURL)
        #expect(
            failedMessage(from: store.auth.phase)
                == "JSON-RPC request 2 (account/login/start) was rejected by the server: login unavailable"
        )
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
        try await mainTransport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "active@example.com",
                planType: .pro
            )),
            requiresOpenAIAuth: false
        )
        try await mainTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await mainTransport.enqueueModels(.init(models: []))
        let loginTransport = FakeCodexAppServerTransport()
        try await loginTransport.enqueueChatGPTLogin(loginID: "login-2", authenticationURL: testAuthenticationURL)
        let externalURLOpener = FakeExternalURLOpener()
        var isolatedCodexHomeURL: URL?
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
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
        try await store.addAccount()
        await loginTransport.waitForNotificationStreamCount(1)
        #expect(externalURLOpener.openedURLs == [testAuthenticationURL])
        try await loginTransport.notificationEmitter.emitLoginCompleted(
            loginID: "login-2",
            completion: .failed(message: "login completion failed")
        )

        let resolvedIsolatedCodexHomeURL = try #require(isolatedCodexHomeURL)
        await waitUntil { failedMessage(from: store.auth.phase) == "login completion failed" }
        await waitUntil {
            FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path) == false
        }
        #expect(FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path) == false)
        #expect(await loginTransport.recordedRequests().map(\.request.operation) == [
            .initialize,
            .accountLoginStart,
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

private extension CodexAppServerTestTransport {
    nonisolated var notificationEmitter: CodexAppServerTestNotificationEmitter {
        CodexAppServerTestNotificationEmitter(transport: self)
    }

    func enqueueThreadStart(threadID: CodexThreadID, model: String) throws {
        try enqueueThreadStart(makeHostStoredThread(id: threadID, model: model))
    }

    func enqueueReviewStart(
        turnID: CodexTurnID,
        reviewThreadID: CodexThreadID
    ) throws {
        let turn = try CodexAppServerTestTurn(
            snapshot: .init(id: turnID, state: .inProgress),
            items: []
        )
        try enqueueReviewStart(turn, reviewThreadID: reviewThreadID)
    }
}

private func makeHostConfigurationReadResult(
    model: String = "gpt-5"
) throws -> CodexAppServerTestConfigurationReadResult {
    let metadata = try CodexAppServerTestConfigurationLayerMetadata(
        source: .sessionFlags,
        version: "host-test-config-v1"
    )
    return try .init(
        configuration: .init(model: model),
        origins: ["model": metadata],
        layers: [try .init(
            metadata: metadata,
            configuration: .object(["model": .string(model)])
        )]
    )
}

private func makeHostRateLimits(
    planType: CodexAppServerTestPlanType?,
    windowDurationMinutes: Int64,
    usedPercent: Int32
) throws -> CodexAppServerTestRateLimitsResponse {
    let snapshot = try CodexAppServerTestRateLimitSnapshot(
        limitID: "codex",
        limitName: nil,
        primary: .init(
            usedPercent: usedPercent,
            windowDurationMinutes: windowDurationMinutes,
            resetsAtUnixSeconds: nil
        ),
        secondary: nil,
        credits: nil,
        individualLimit: nil,
        planType: planType,
        reachedType: nil
    )
    return try .init(
        primarySnapshot: snapshot,
        snapshotsByLimitID: nil,
        resetCredits: nil
    )
}

private func makeHostStoredThread(
    id: CodexThreadID,
    model: String = "gpt-5"
) throws -> CodexAppServerTestStoredThread {
    let workspace = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
    return try .init(
        snapshot: .init(
            id: id,
            workspace: workspace,
            preview: id.rawValue,
            modelProvider: "openai",
            sourceKind: .appServer,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            status: .idle,
            ephemeral: false,
            turns: []
        ),
        turns: [],
        metadata: .init(
            sessionID: "session-\(id.rawValue)",
            cliVersion: "host-test-cli",
            source: .appServer
        ),
        runtimeMetadata: .init(
            model: model,
            modelProvider: "openai",
            serviceTier: nil,
            cwd: workspace,
            runtimeWorkspaceRoots: [workspace],
            instructionSources: [],
            approvalPolicy: .never,
            approvalsReviewer: .user,
            sandbox: .dangerFullAccess,
            activePermissionProfile: nil,
            reasoningEffort: nil,
            multiAgentMode: .explicitRequestOnly
        ),
        isArchived: false
    )
}

@MainActor
private final class FakeExternalURLOpener {
    private(set) var openedURLs: [URL] = []
    private let failure: (any Error)?

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    func open(_ url: URL) async throws {
        openedURLs.append(url)
        if let failure {
            throw failure
        }
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
    if let activeAccountKey {
        try Data("{\"tokens\":{\"id_token\":\"\(activeAccountKey)\"}}".utf8)
            .write(to: codexHomeURL.appendingPathComponent("auth.json"))
    }
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
    let accountDirectoryURL = homeURL
        .appendingPathComponent(".codex_review", isDirectory: true)
        .appendingPathComponent("accounts", isDirectory: true)
        .appendingPathComponent(pathComponent(forAccountKey: accountKey), isDirectory: true)
    let registryURL = homeURL
        .appendingPathComponent(".codex_review", isDirectory: true)
        .appendingPathComponent("accounts", isDirectory: true)
        .appendingPathComponent("registry.json")
    let registryData = try Data(contentsOf: registryURL)
    let registry = try #require(JSONSerialization.jsonObject(with: registryData) as? [String: Any])
    let records = try #require(registry["accounts"] as? [[String: Any]])
    let normalizedAccountKey = accountKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let record = try #require(records.first { record in
        (record["accountKey"] as? String)?.lowercased() == normalizedAccountKey
    })
    if let revision = record["immutableRevision"] as? String {
        return try Data(contentsOf: accountDirectoryURL
            .appendingPathComponent("revisions", isDirectory: true)
            .appendingPathComponent("\(revision).json"))
    }
    return try Data(contentsOf: accountDirectoryURL.appendingPathComponent("auth.json"))
}

private func activeAccountKey(homeURL: URL) throws -> String? {
    let object = try accountRegistryObject(homeURL: homeURL)
    return object["activeAccountKey"] as? String
}

private func accountRegistryURL(homeURL: URL) -> URL {
    homeURL
        .appendingPathComponent(".codex_review", isDirectory: true)
        .appendingPathComponent("accounts", isDirectory: true)
        .appendingPathComponent("registry.json")
}

private func accountMutationJournalURL(homeURL: URL) -> URL {
    homeURL
        .appendingPathComponent(".codex_review", isDirectory: true)
        .appendingPathComponent("accounts", isDirectory: true)
        .appendingPathComponent("mutation-journal.json")
}

private func accountRegistryObject(homeURL: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: accountRegistryURL(homeURL: homeURL))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
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
    guard case .failed(let failure) = phase else {
        return nil
    }
    return failure.localizedDescription
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
