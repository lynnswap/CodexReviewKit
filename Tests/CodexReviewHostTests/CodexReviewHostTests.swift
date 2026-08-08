import Foundation
import AppKit
import Testing
import CodexAppServerKit
import CodexAppServerKitTesting
import CodexReviewKit
import CodexReviewAppServer
@testable import CodexReviewHost
import CodexReviewMCPServer
import CodexReviewTesting

private let testAuthenticationURL = URL(string: "https://example.com/auth")!

private extension CodexReviewStore {
    @MainActor
    static func makeLiveStoreForTesting(
        environment: [String: String],
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        externalURLOpener: @escaping ExternalURLOpener = { _ in },
        deadlineClock: CodexAppServerTestDeadlineClock? = nil,
        mcpPortOwnerResolver: CodexReviewMCPPortOwnerResolver? = nil,
        mcpHTTPServerBindChecker: CodexReviewMCPHTTPServerBindChecker? = nil,
        networkMonitor: any CodexReviewNetworkMonitoring = SystemCodexReviewNetworkMonitor(),
        networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy = .default,
        appServerLifecycleHandler: CodexReviewAppServerLifecycleHandler? = nil,
        authenticationMutationDidBegin: CodexReviewAuthenticationMutationDidBegin? = nil,
        authenticationCancellationDidRequest: CodexReviewAuthenticationCancellationDidRequest? = nil,
        authenticationProductCommitDidApply: CodexReviewAuthenticationProductCommitDidApply? = nil,
        authenticationOperationDidBind: CodexReviewAuthenticationOperationDidBind? = nil,
        accountRegistryLoadDidBegin: CodexReviewAccountRegistryLoadDidBegin? = nil,
        finalRuntimeRetirementDidClaim: CodexReviewFinalRuntimeRetirementDidClaim? = nil,
        finalShutdownDidRequest: CodexReviewFinalShutdownDidRequest? = nil,
        reconciliationDebtDidClear: CodexReviewReconciliationDebtDidClear? = nil,
        registryDestinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil,
        appServerCloser: @escaping CodexReviewAppServerCloser = { await $0.close() },
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
            authenticationMutationDidBegin: authenticationMutationDidBegin,
            authenticationCancellationDidRequest: authenticationCancellationDidRequest,
            authenticationProductCommitDidApply: authenticationProductCommitDidApply,
            authenticationOperationDidBind: authenticationOperationDidBind,
            accountRegistryLoadDidBegin: accountRegistryLoadDidBegin,
            finalRuntimeRetirementDidClaim: finalRuntimeRetirementDidClaim,
            finalShutdownDidRequest: finalShutdownDidRequest,
            reconciliationDebtDidClear: reconciliationDebtDidClear,
            registryDestinationDidReplace: registryDestinationDidReplace,
            appServerCloser: appServerCloser,
            appServerFactory: { codexHomeURL in
                try await CodexAppServerTestRuntime.start(
                    transport: transport,
                    configuration: .init(localProcess: .init(
                        codexHomeURL: codexHomeURL
                    )),
                    deadlineClock: deadlineClock
                ).server
            }
        )
    }

    @MainActor
    static func makeLiveStoreForTesting(
        environment: [String: String],
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        externalURLOpener: @escaping ExternalURLOpener = { _ in },
        deadlineClock: CodexAppServerTestDeadlineClock? = nil,
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
        authenticationMutationDidBegin: CodexReviewAuthenticationMutationDidBegin? = nil,
        authenticationCancellationDidRequest: CodexReviewAuthenticationCancellationDidRequest? = nil,
        authenticationProductCommitDidApply: CodexReviewAuthenticationProductCommitDidApply? = nil,
        authenticationOperationDidBind: CodexReviewAuthenticationOperationDidBind? = nil,
        accountRegistryLoadDidBegin: CodexReviewAccountRegistryLoadDidBegin? = nil,
        finalRuntimeRetirementDidClaim: CodexReviewFinalRuntimeRetirementDidClaim? = nil,
        finalShutdownDidRequest: CodexReviewFinalShutdownDidRequest? = nil,
        reconciliationDebtDidClear: CodexReviewReconciliationDebtDidClear? = nil,
        registryDestinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil,
        appServerCloser: @escaping CodexReviewAppServerCloser = { await $0.close() },
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
            authenticationMutationDidBegin: authenticationMutationDidBegin,
            authenticationCancellationDidRequest: authenticationCancellationDidRequest,
            authenticationProductCommitDidApply: authenticationProductCommitDidApply,
            authenticationOperationDidBind: authenticationOperationDidBind,
            accountRegistryLoadDidBegin: accountRegistryLoadDidBegin,
            finalRuntimeRetirementDidClaim: finalRuntimeRetirementDidClaim,
            finalShutdownDidRequest: finalShutdownDidRequest,
            reconciliationDebtDidClear: reconciliationDebtDidClear,
            registryDestinationDidReplace: registryDestinationDidReplace,
            appServerCloser: appServerCloser,
            appServerFactory: { codexHomeURL in
                let transport = try await transportFactory(codexHomeURL)
                return try await CodexAppServerTestRuntime.start(
                    transport: transport,
                    configuration: .init(localProcess: .init(
                        codexHomeURL: codexHomeURL
                    )),
                    deadlineClock: deadlineClock
                ).server
            }
        )
    }
}

@Suite("host composition")
@MainActor
struct CodexReviewHostTests {
    @Test func stoppedPrimaryReconciliationWaitsOnlyForItsReservedTransition() async throws {
        let coordinator = AccountRuntimeTransitionCoordinator()
        var admittedLogin: AccountRuntimeTransitionCoordinator.LoginAdmission?
        var didAdmitLogin = false
        coordinator.installDidBecomeIdle {
            guard didAdmitLogin == false else { return }
            didAdmitLogin = true
            admittedLogin = try! coordinator.reserveLoginAdmission()
        }
        let reconciliationCompleted = CompletionFlag()
        let reconciliation = Task { @MainActor in
            await coordinator.performStoppedPrimaryReconciliation { _ in }
            await reconciliationCompleted.complete()
        }

        try #require(await waitUntil(timeout: .seconds(2)) {
            await reconciliationCompleted.isCompleted()
        })
        #expect(coordinator.hasActiveLoginTransition)

        coordinator.finishLoginAdmission(try #require(admittedLogin))
        await reconciliation.value
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

    @Test func liveStoreDoesNotPublishLifecycleWhenMCPStagingFails() async throws {
        let homeURL = try temporaryHome()
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        let mcpServer = MCPHTTPServerProbe(
            endpoint: URL(string: "http://127.0.0.1:9417/mcp")!,
            stageFailure: .stagingFailed
        )
        var observedLifecycleStates: [Bool] = []
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            mcpHTTPServerFactory: { _, _, _ in mcpServer },
            mcpHTTPServerBindChecker: { _ in },
            appServerLifecycleHandler: { container in
                observedLifecycleStates.append(container != nil)
            },
            transportFactory: { _ in transport }
        )

        await store.start(forceRestartIfNeeded: true)

        guard case .failed = store.serverState else {
            Issue.record("Expected failed server state.")
            return
        }
        #expect(store.serverURL == nil)
        #expect(observedLifecycleStates.isEmpty)
        #expect(await mcpServer.snapshot() == .init(stageCount: 1, activateCount: 0, stopCount: 1))
    }

    @Test func liveStoreStopWinsOverLateMCPStagingCompletion() async throws {
        let homeURL = try temporaryHome()
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        let stageGate = CodexAppServerTestGate()
        let mcpServer = MCPHTTPServerProbe(
            endpoint: URL(string: "http://127.0.0.1:9417/mcp")!,
            stageGate: stageGate
        )
        var observedLifecycleStates: [Bool] = []
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            mcpHTTPServerFactory: { _, _, _ in mcpServer },
            mcpHTTPServerBindChecker: { _ in },
            appServerLifecycleHandler: { container in
                observedLifecycleStates.append(container != nil)
            },
            transportFactory: { _ in transport }
        )

        let start = Task { @MainActor in
            await store.start(forceRestartIfNeeded: true)
        }
        await stageGate.waitUntilBlocked()
        await store.stop()

        #expect(store.serverState == .stopped)
        #expect(store.serverURL == nil)
        #expect(observedLifecycleStates.isEmpty)
        #expect(await mcpServer.snapshot() == .init(stageCount: 1, activateCount: 0, stopCount: 1))

        await stageGate.open()
        await start.value

        #expect(store.serverState == .stopped)
        #expect(store.serverURL == nil)
        #expect(observedLifecycleStates.isEmpty)
        #expect(await mcpServer.snapshot() == .init(stageCount: 1, activateCount: 0, stopCount: 1))
    }

    @Test func liveStoreJoinsConcurrentStopsIntoOneRuntimeTeardown() async throws {
        let homeURL = try temporaryHome()
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        let stopGate = CodexAppServerTestGate()
        let secondStopStarted = CodexAppServerTestGate()
        let mcpServer = MCPHTTPServerProbe(
            endpoint: URL(string: "http://127.0.0.1:9417/mcp")!,
            stopGate: stopGate
        )
        var observedLifecycleStates: [Bool] = []
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            mcpHTTPServerFactory: { _, _, _ in mcpServer },
            mcpHTTPServerBindChecker: { _ in },
            appServerLifecycleHandler: { container in
                observedLifecycleStates.append(container != nil)
            },
            transportFactory: { _ in transport }
        )
        await store.start(forceRestartIfNeeded: true)

        let firstStop = Task { @MainActor in
            await store.stop()
        }
        await stopGate.waitUntilBlocked()
        let secondStopStartedWaiter = Task {
            await secondStopStarted.waitIgnoringCancellation()
        }
        await secondStopStarted.waitUntilBlocked()
        let secondStop = Task { @MainActor in
            await secondStopStarted.open()
            await store.stop()
        }
        await secondStopStartedWaiter.value
        await stopGate.open()
        await firstStop.value
        await secondStop.value

        #expect(await mcpServer.snapshot().stopCount == 1)
        #expect(observedLifecycleStates == [true, false])
    }

    @Test func liveStoreIgnoresLateStagingGenerationCompletion() async throws {
        let homeURL = try temporaryHome()
        let firstFactoryGate = CodexAppServerTestGate()
        let firstTransport = FakeCodexAppServerTransport()
        let secondTransport = FakeCodexAppServerTransport()
        try await secondTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        for _ in 0..<2 {
            try await secondTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
            try await secondTransport.enqueueModels(.init(models: []))
        }
        var factoryCallCount = 0
        var observedLifecycleStates: [Bool] = []
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            mcpHTTPServerFactory: { _, configuration, _ in
                NoopMCPHTTPServer(endpoint: configuration.url())
            },
            mcpHTTPServerBindChecker: { _ in },
            appServerLifecycleHandler: { container in
                observedLifecycleStates.append(container != nil)
            },
            transportFactory: { _ in
                factoryCallCount += 1
                if factoryCallCount == 1 {
                    await firstFactoryGate.waitIgnoringCancellation()
                    return firstTransport
                }
                return secondTransport
            }
        )

        let oldStart = Task { @MainActor in
            await store.start(forceRestartIfNeeded: true)
        }
        await firstFactoryGate.waitUntilBlocked()
        await store.stop()
        await store.start(forceRestartIfNeeded: true)
        #expect(store.serverState == .running)
        #expect(observedLifecycleStates == [true])

        await firstFactoryGate.open()
        await oldStart.value

        #expect(store.serverState == .running)
        #expect(store.serverURL != nil)
        #expect(observedLifecycleStates == [true])
        await store.stop()
        #expect(observedLifecycleStates == [true, false])
    }

    @Test func liveStoreFinalStopRetiresRunsWhileReplacementIsStaging() async throws {
        let homeURL = try temporaryHome()
        let firstTransport = FakeCodexAppServerTransport()
        try await firstTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await firstTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await firstTransport.enqueueModels(.init(models: []))
        try await firstTransport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await firstTransport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "thread-1")

        let secondTransport = FakeCodexAppServerTransport()
        try await secondTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await secondTransport.enqueueSuccess(for: .threadDelete)
        var transports = [firstTransport, secondTransport]
        let replacementStageGate = CodexAppServerTestGate()
        let replacementMCPServer = MCPHTTPServerProbe(
            endpoint: URL(string: "http://127.0.0.1:9417/mcp")!,
            stageGate: replacementStageGate
        )
        var mcpFactoryCallCount = 0
        var observedLifecycleStates: [Bool] = []
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            mcpHTTPServerFactory: { _, configuration, _ in
                mcpFactoryCallCount += 1
                if mcpFactoryCallCount == 1 {
                    return NoopMCPHTTPServer(endpoint: configuration.url())
                }
                return replacementMCPServer
            },
            mcpHTTPServerBindChecker: { _ in },
            appServerLifecycleHandler: { container in
                observedLifecycleStates.append(container != nil)
            },
            transportFactory: { _ in transports.removeFirst() }
        )

        await store.start(forceRestartIfNeeded: true)
        let review = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.reviewRuns.first?.core.attempt?.turnID.rawValue == "turn-1"
        })
        let reviewOutput = try CodexAppServerTestItem.exitedReviewMode(
            id: "review-output",
            review: "No issues found."
        )
        let completedTurn = try CodexAppServerTestTurn(
            snapshot: .init(
                id: "turn-1",
                state: .completed,
                items: [reviewOutput.domainProjection]
            ),
            items: [reviewOutput]
        )
        try await firstTransport.enqueueThreadRead(
            makeHostStoredThread(id: "thread-1", turns: [completedTurn])
        )
        try await firstTransport.notificationEmitter.emitTurnCompleted(
            threadID: "thread-1",
            turn: completedTurn
        )
        #expect(try await review.value.presentation.status == .succeeded)

        let restart = Task { @MainActor in
            await store.restart()
        }
        await replacementStageGate.waitUntilBlocked()
        #expect(store.reviewRuns.count == 1)

        await store.stop()

        #expect(store.serverState == .stopped)
        #expect(store.reviewRuns.isEmpty)
        #expect(await secondTransport.recordedRequests(for: .threadDelete).count == 1)
        #expect(observedLifecycleStates == [true, false])
        #expect(await replacementMCPServer.snapshot() == .init(
            stageCount: 1,
            activateCount: 0,
            stopCount: 1
        ))

        await replacementStageGate.open()
        await restart.value
        #expect(store.serverState == .stopped)
        #expect(observedLifecycleStates == [true, false])
    }

    @Test func liveStoreFinalStopRetiresRunsWhenRequestedDuringPreservingAppServerClose() async throws {
        let homeURL = try temporaryHome()
        let firstTransport = FakeCodexAppServerTransport()
        try await firstTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await firstTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await firstTransport.enqueueModels(.init(models: []))
        try await firstTransport.enqueueThreadStart(threadID: "thread-close-race", model: "gpt-5")
        try await firstTransport.enqueueReviewStart(
            turnID: "turn-close-race",
            reviewThreadID: "thread-close-race"
        )
        let cleanupTransport = FakeCodexAppServerTransport()
        try await cleanupTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await cleanupTransport.enqueueSuccess(for: .threadDelete)
        var transports = [firstTransport, cleanupTransport]
        let firstCloseStarted = OneShotSignal()
        let firstCloseGate = CodexAppServerTestGate()
        let finalRetirementClaimed = OneShotSignal()
        var closeCount = 0
        var observedLifecycleStates: [Bool] = []
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            appServerLifecycleHandler: { container in
                observedLifecycleStates.append(container != nil)
            },
            finalRuntimeRetirementDidClaim: {
                await finalRetirementClaimed.signal()
            },
            appServerCloser: { appServer in
                closeCount += 1
                if closeCount == 1 {
                    await firstCloseStarted.signal()
                    await firstCloseGate.waitIgnoringCancellation()
                }
                await appServer.close()
            },
            transportFactory: { _ in transports.removeFirst() }
        )

        await store.start(forceRestartIfNeeded: true)
        let review = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-close-race",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.reviewRuns.first?.core.attempt?.turnID.rawValue == "turn-close-race"
        })
        let reviewOutput = try CodexAppServerTestItem.exitedReviewMode(
            id: "review-output-close-race",
            review: "No issues found."
        )
        let completedTurn = try CodexAppServerTestTurn(
            snapshot: .init(
                id: "turn-close-race",
                state: .completed,
                items: [reviewOutput.domainProjection]
            ),
            items: [reviewOutput]
        )
        try await firstTransport.enqueueThreadRead(
            makeHostStoredThread(id: "thread-close-race", turns: [completedTurn])
        )
        try await firstTransport.notificationEmitter.emitTurnCompleted(
            threadID: "thread-close-race",
            turn: completedTurn
        )
        #expect(try await review.value.presentation.status == .succeeded)

        await firstTransport.failConnection(.closed)
        await firstCloseStarted.wait()
        #expect(store.reviewRuns.count == 1)
        #expect(observedLifecycleStates == [true, false])

        let finalStop = Task { @MainActor in
            await store.stop()
        }
        await finalRetirementClaimed.wait()
        await firstCloseGate.open()
        await finalStop.value

        #expect(store.serverState == .stopped)
        #expect(store.reviewRuns.isEmpty)
        #expect(closeCount == 2)
        #expect(await cleanupTransport.recordedRequests(for: .threadDelete).count == 1)
        #expect(observedLifecycleStates == [true, false])
        #expect(store.auth.selectedAccount == nil)
    }

    @Test func liveStoreWaitUntilStoppedJoinsFinalCoordinatorBeforeRuntimeStopStarts() async throws {
        let homeURL = try temporaryHome()
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        let finalRequestGate = CodexAppServerTestGate()
        let waiterStarted = OneShotSignal()
        let waiterCompleted = OneShotSignal()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            finalShutdownDidRequest: {
                await finalRequestGate.waitIgnoringCancellation()
            },
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        let finalStop = Task { @MainActor in
            await store.stop()
        }
        await finalRequestGate.waitUntilBlocked()
        let waiter = Task { @MainActor in
            await waiterStarted.signal()
            await store.waitUntilStopped()
            await waiterCompleted.signal()
        }
        await waiterStarted.wait()
        #expect(await waiterCompleted.snapshot() == false)

        await finalRequestGate.open()
        await finalStop.value
        await waiter.value
        #expect(await waiterCompleted.snapshot())
        #expect(store.serverState == .stopped)
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

    @Test func liveStoreReportsMCPPortOwnerAfterStagingAppServer() async throws {
        let homeURL = try temporaryHome()
        let port = 54321
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)

        var didLaunchAppServer = false
        var observedLifecycleStates: [Bool] = []
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
            appServerLifecycleHandler: { container in
                observedLifecycleStates.append(container != nil)
            },
            transportFactory: { _ in
                didLaunchAppServer = true
                return transport
            }
        )

        await store.start(forceRestartIfNeeded: true)

        #expect(didLaunchAppServer)
        #expect(observedLifecycleStates.isEmpty)
        guard case .failed(let message) = store.serverState else {
            Issue.record("Expected failed server state.")
            return
        }
        #expect(message.contains("MCP endpoint http://127.0.0.1:\(port)/mcp is already in use by PID 98695"))
        #expect(message.contains("/Applications/CodexReviewMonitor.app/Contents/MacOS/CodexReviewMonitor"))
        #expect(message.contains("Quit that process or change the MCP port in Settings"))
    }

    @Test func liveStoreReportsMCPPortInUseWithoutOwnerAfterStagingAppServer() async throws {
        let homeURL = try temporaryHome()
        let port = 54322
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)

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
                return transport
            }
        )

        await store.start(forceRestartIfNeeded: true)

        #expect(didLaunchAppServer)
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

    @Test func preparedAPIKeyActivationCarriesExactProviderFromCredentialRevision() async throws {
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
        let sentinel = "test-secret-prepared-activation"
        try Data("{\"OPENAI_API_KEY\":\"\(sentinel)\"}".utf8)
            .write(to: codexHomeURL.appendingPathComponent("auth.json"))
        let registry = AccountRegistryStore(codexHomeURL: codexHomeURL)
        _ = try await registry.commitAuthenticatedAccount(
            .init(
                accountKey: "api-key",
                email: "API Key",
                kind: .apiKey,
                planType: nil,
                capabilities: .noCodexRateLimits,
                rateLimits: [],
                lastRateLimitFetchAt: nil,
                lastRateLimitError: nil
            ),
            activation: .activateAuthenticatedAccount,
            authSourceCodexHomeURL: codexHomeURL,
            authorization: nil
        )

        let prepared = try await registry.prepareAccountActivation("api-key")

        #expect(prepared.expectedAccount == .observedAccount(accountKey: "api-key", provider: .apiKey))
        _ = try await registry.abortPreparedMutation(prepared)
        let registryDescription = String(data: try Data(contentsOf: accountRegistryURL(homeURL: homeURL)), encoding: .utf8)
        #expect(registryDescription?.contains(sentinel) == false)
    }

    @Test func liveStoreBuildsSwitchPlanFromDiskWhenAuthModelIsStale() async throws {
        let homeURL = try temporaryHome()
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "first@example.com",
            accounts: ["first@example.com", "second@example.com"]
        )
        try writeSavedAccountAuth(homeURL: homeURL, accountKey: "first@example.com")
        try writeSavedAccountAuth(homeURL: homeURL, accountKey: "second@example.com")
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transport: FakeCodexAppServerTransport()
        )
        let staleSecondAccount = CodexReviewAccount(email: "second@example.com")
        store.auth.applyPersistedAccountStates(
            [savedAccountPayload(from: staleSecondAccount)],
            activeAccountKey: nil
        )
        store.auth.selectPersistedAccount(nil)

        try await store.switchAccount(staleSecondAccount)

        #expect(try activeAccountKey(homeURL: homeURL) == "second@example.com")
        #expect(store.auth.persistedAccounts.map(\.accountKey) == [
            "first@example.com",
            "second@example.com",
        ])
        #expect(store.auth.selectedAccount?.accountKey == "second@example.com")
    }

    @Test func liveStoreChoosesAddAccountRuntimeFromLeasedDiskSnapshot() async throws {
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
        let isolatedTransport = FakeCodexAppServerTransport()
        try await isolatedTransport.enqueueChatGPTLogin(
            loginID: "isolated-login",
            authenticationURL: testAuthenticationURL
        )
        try await isolatedTransport.enqueueChatGPTLoginCancellation(.canceled)
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transportFactory: { codexHomeURL in
                if codexHomeURL == mainCodexHomeURL {
                    return mainTransport
                }
                try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
                return isolatedTransport
            }
        )

        await store.start(forceRestartIfNeeded: true)
        store.auth.applyPersistedAccountStates([], activeAccountKey: nil)
        store.auth.selectPersistedAccount(nil)
        try await store.addAccount()

        await isolatedTransport.waitForRequest(.accountLoginStart)
        #expect(await mainTransport.recordedRequests(for: .accountLoginStart).isEmpty)
        await store.cancelAuthentication()
        await store.stop()
    }

    @Test func liveStoreRejectsDuplicateAPIKeyBeforeCreatingAnIsolatedRuntime() async throws {
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
        let registry = AccountRegistryStore(codexHomeURL: codexHomeURL)
        let sharedAuthURL = codexHomeURL.appendingPathComponent("auth.json")
        try Data(#"{"OPENAI_API_KEY":"existing-key"}"#.utf8).write(to: sharedAuthURL)
        _ = try await registry.commitAuthenticatedAccount(
            .init(
                accountKey: "api-key",
                email: "API Key",
                kind: .apiKey,
                planType: nil,
                capabilities: .noCodexRateLimits,
                rateLimits: [],
                lastRateLimitFetchAt: nil,
                lastRateLimitError: nil
            ),
            activation: .activateAuthenticatedAccount,
            authSourceCodexHomeURL: codexHomeURL,
            authorization: nil
        )
        try Data(#"{"tokens":{"id_token":"active@example.com"}}"#.utf8).write(to: sharedAuthURL)
        _ = try await registry.commitAuthenticatedAccount(
            .init(
                accountKey: "active@example.com",
                email: "active@example.com",
                planType: "pro",
                rateLimits: [],
                lastRateLimitFetchAt: nil,
                lastRateLimitError: nil
            ),
            activation: .activateAuthenticatedAccount,
            authSourceCodexHomeURL: codexHomeURL,
            authorization: nil
        )
        let mainTransport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: mainTransport, email: "active@example.com")
        var isolatedRuntimeCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transportFactory: { runtimeHomeURL in
                if runtimeHomeURL == codexHomeURL {
                    return mainTransport
                }
                isolatedRuntimeCount += 1
                return FakeCodexAppServerTransport()
            }
        )
        await store.start(forceRestartIfNeeded: true)

        await #expect(throws: CodexReviewAuthenticationFailure.apiKeyAccountAlreadyExists) {
            try await store.addAccount(using: .apiKey(try CodexReviewAPIKey(validating: "replacement-key")))
        }

        #expect(isolatedRuntimeCount == 0)
        #expect(try activeAccountKey(homeURL: homeURL) == "active@example.com")
        await store.stop()
    }

    @Test func liveStoreRejectsAPIKeySignInWhenFixedIdentityIsAlreadyPersisted() async throws {
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
        try writeAPIKeyAuth(Data(#"{"OPENAI_API_KEY":"existing-key"}"#.utf8), to: codexHomeURL)
        let registry = AccountRegistryStore(codexHomeURL: codexHomeURL)
        _ = try await registry.commitAuthenticatedAccount(
            .init(
                accountKey: "api-key",
                email: "API Key",
                kind: .apiKey,
                planType: nil,
                capabilities: .noCodexRateLimits,
                rateLimits: [],
                lastRateLimitFetchAt: nil,
                lastRateLimitError: nil
            ),
            activation: .preserveActiveAccount,
            authSourceCodexHomeURL: codexHomeURL,
            authorization: nil
        )
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transport: transport
        )
        await store.start(forceRestartIfNeeded: true)

        await #expect(throws: CodexReviewAuthenticationFailure.apiKeyAccountAlreadyExists) {
            try await store.signIn(using: .apiKey(
                try CodexReviewAPIKey(validating: "replacement-key")
            ))
        }

        #expect(await transport.recordedRequests(for: .accountLoginStart).isEmpty)
        #expect(try activeAccountKey(homeURL: homeURL) == nil)
        #expect(store.auth.persistedAccounts.map(\.accountKey) == ["api-key"])
        await store.stop()
    }

    @Test func liveStoreSignsInWithAPIKeyWithoutBrowserOrRateLimitRequest() async throws {
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueAPIKeyLogin()
        try await transport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .apiKey),
            requiresOpenAIAuth: false
        )
        let externalURLOpener = FakeExternalURLOpener()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            externalURLOpener: externalURLOpener.open,
            transport: transport
        )
        await store.start(forceRestartIfNeeded: true)
        let sentinel = "test-secret-primary-api-key"
        let authData = Data("{\"OPENAI_API_KEY\":\"\(sentinel)\"}".utf8)
        try writeAPIKeyAuth(authData, to: codexHomeURL)

        try await store.signIn(using: .apiKey(try CodexReviewAPIKey(validating: sentinel)))

        #expect(externalURLOpener.openedURLs.isEmpty)
        #expect(store.auth.selectedAccount?.accountKey == "api-key")
        #expect(store.auth.selectedAccount?.kind == .apiKey)
        #expect(store.auth.selectedAccount?.capabilities.supportsRateLimitRefresh == false)
        #expect(try activeAccountKey(homeURL: homeURL) == "api-key")
        #expect(await transport.recordedRequests(for: .accountRateLimitsRead).isEmpty)
        let registryData = try Data(contentsOf: accountRegistryURL(homeURL: homeURL))
        #expect(String(data: registryData, encoding: .utf8)?.contains(sentinel) == false)
        #expect(FileManager.default.fileExists(
            atPath: accountReconciliationDebtURL(homeURL: homeURL).path
        ) == false)
        let immutableAuthURL = try immutableAccountAuthURL(homeURL: homeURL, accountKey: "api-key")
        #expect(try Data(contentsOf: immutableAuthURL) == authData)
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: immutableAuthURL.path)[.posixPermissions]
                as? NSNumber
        )
        #expect(permissions.intValue == 0o600)

        await store.stop()
    }

    @Test func liveStoreCancelsAPIKeyLoginBeforeRequestWrite() async throws {
        let homeURL = try temporaryHome()
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueAPIKeyLogin()
        let operationGate = CodexAppServerTestGate()
        let cancellationRequested = OneShotSignal()
        let externalURLOpener = FakeExternalURLOpener()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            externalURLOpener: externalURLOpener.open,
            authenticationCancellationDidRequest: {
                await cancellationRequested.signal()
            },
            authenticationOperationDidBind: {
                await operationGate.waitIgnoringCancellation()
            },
            transport: transport
        )
        await store.start(forceRestartIfNeeded: true)
        let login = Task { @MainActor in
            try await store.signIn(using: .apiKey(
                try CodexReviewAPIKey(validating: "test-secret-pre-write")
            ))
        }
        await operationGate.waitUntilBlocked()

        let cancellation = Task { @MainActor in
            await store.cancelAuthentication()
        }
        await cancellationRequested.wait()
        await operationGate.open()
        try await login.value
        await cancellation.value

        #expect(await transport.recordedRequests(for: .accountLoginStart).isEmpty)
        #expect(externalURLOpener.openedURLs.isEmpty)
        #expect(store.auth.selectedAccount == nil)
        #expect(FileManager.default.fileExists(atPath: accountRegistryURL(homeURL: homeURL).path) == false)
        await store.stop()
    }

    @Test func liveStoreCompletesCommittedAPIKeyLoginAfterPostWriteCancellation() async throws {
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueAPIKeyLogin()
        try await transport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .apiKey),
            requiresOpenAIAuth: false
        )
        let responseGate = CodexAppServerTestGate()
        await transport.holdNextIgnoringCancellation(.accountLoginStart, gate: responseGate)
        let cancellationRequested = OneShotSignal()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            authenticationCancellationDidRequest: {
                await cancellationRequested.signal()
            },
            transport: transport
        )
        await store.start(forceRestartIfNeeded: true)
        let sentinel = "test-secret-post-write"
        try writeAPIKeyAuth(
            Data("{\"OPENAI_API_KEY\":\"\(sentinel)\"}".utf8),
            to: codexHomeURL
        )
        let login = Task { @MainActor in
            try await store.signIn(using: .apiKey(try CodexReviewAPIKey(validating: sentinel)))
        }
        await transport.waitForRequest(.accountLoginStart)

        let cancellation = Task { @MainActor in
            await store.cancelAuthentication()
        }
        await cancellationRequested.wait()
        await responseGate.open()
        try await login.value
        await cancellation.value

        #expect(await transport.recordedRequests(for: .accountLoginStart).count == 1)
        #expect(await transport.recordedRequests(for: .accountLoginCancel).isEmpty)
        #expect(store.auth.selectedAccount?.accountKey == "api-key")
        #expect(try activeAccountKey(homeURL: homeURL) == "api-key")
        #expect(FileManager.default.fileExists(
            atPath: accountReconciliationDebtURL(homeURL: homeURL).path
        ) == false)
        await store.stop()
    }

    @Test func liveStoreCommitsIsolatedAPIKeyAfterPostWriteCancellation() async throws {
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let activeChatGPTAccountKey = "active@example.com"
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: activeChatGPTAccountKey,
            accounts: [activeChatGPTAccountKey]
        )
        try writeSavedAccountAuth(homeURL: homeURL, accountKey: activeChatGPTAccountKey)
        let mainTransport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: mainTransport, email: activeChatGPTAccountKey)
        let isolatedTransport = FakeCodexAppServerTransport()
        try await isolatedTransport.enqueueAPIKeyLogin()
        try await isolatedTransport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .apiKey),
            requiresOpenAIAuth: false
        )
        let responseGate = CodexAppServerTestGate()
        await isolatedTransport.holdNextIgnoringCancellation(
            .accountLoginStart,
            gate: responseGate
        )
        let cancellationRequested = OneShotSignal()
        let sentinel = "test-secret-isolated-post-write"
        let authData = Data("{\"OPENAI_API_KEY\":\"\(sentinel)\"}".utf8)
        var isolatedCodexHomeURL: URL?
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            authenticationCancellationDidRequest: {
                await cancellationRequested.signal()
            },
            transportFactory: { runtimeHomeURL in
                guard runtimeHomeURL != codexHomeURL else {
                    return mainTransport
                }
                isolatedCodexHomeURL = runtimeHomeURL
                try writeAPIKeyAuth(authData, to: runtimeHomeURL)
                return isolatedTransport
            }
        )
        await store.start(forceRestartIfNeeded: true)
        let add = Task { @MainActor in
            try await store.addAccount(using: .apiKey(
                try CodexReviewAPIKey(validating: sentinel)
            ))
        }
        await isolatedTransport.waitForRequest(.accountLoginStart)

        let cancellation = Task { @MainActor in
            await store.cancelAuthentication()
        }
        await cancellationRequested.wait()
        await responseGate.open()
        try await add.value
        await cancellation.value
        let isolatedURL = try #require(isolatedCodexHomeURL)

        #expect(store.auth.selectedAccount?.accountKey == activeChatGPTAccountKey)
        #expect(Set(store.auth.persistedAccounts.map(\.accountKey)) == Set([activeChatGPTAccountKey, "api-key"]))
        #expect(try activeAccountKey(homeURL: homeURL) == activeChatGPTAccountKey)
        #expect(try savedAccountAuth(homeURL: homeURL, accountKey: "api-key") == authData)
        #expect(await isolatedTransport.recordedRequests(for: .accountLoginCancel).isEmpty)
        #expect(FileManager.default.fileExists(atPath: isolatedURL.path) == false)
        await store.stop()
    }

    @Test func liveStorePreservesKnownAPIKeyFailureAfterPostWriteCancellation() async throws {
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let activeChatGPTAccountKey = "active@example.com"
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: activeChatGPTAccountKey,
            accounts: [activeChatGPTAccountKey]
        )
        try writeSavedAccountAuth(homeURL: homeURL, accountKey: activeChatGPTAccountKey)
        let mainTransport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: mainTransport, email: activeChatGPTAccountKey)
        let isolatedTransport = FakeCodexAppServerTransport()
        let sentinel = "test-secret-isolated-rejection"
        try await isolatedTransport.enqueueFailure(
            .response(code: -32_000, message: "rejected \(sentinel)"),
            for: .accountLoginStart
        )
        let responseGate = CodexAppServerTestGate()
        await isolatedTransport.holdNextIgnoringCancellation(
            .accountLoginStart,
            gate: responseGate
        )
        let cancellationRequested = OneShotSignal()
        var isolatedCodexHomeURL: URL?
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            authenticationCancellationDidRequest: {
                await cancellationRequested.signal()
            },
            transportFactory: { runtimeHomeURL in
                guard runtimeHomeURL != codexHomeURL else {
                    return mainTransport
                }
                isolatedCodexHomeURL = runtimeHomeURL
                return isolatedTransport
            }
        )
        await store.start(forceRestartIfNeeded: true)
        let add = Task { @MainActor in
            try await store.addAccount(using: .apiKey(
                try CodexReviewAPIKey(validating: sentinel)
            ))
        }
        await isolatedTransport.waitForRequest(.accountLoginStart)

        let cancellation = Task { @MainActor in
            await store.cancelAuthentication()
        }
        await cancellationRequested.wait()
        await responseGate.open()
        let failure: CodexReviewAuthenticationFailure
        do {
            try await add.value
            Issue.record("Expected the known API-key rejection to remain a failure.")
            await cancellation.value
            await store.stop()
            return
        } catch let caughtFailure as CodexReviewAuthenticationFailure {
            failure = caughtFailure
        }
        await cancellation.value
        let isolatedURL = try #require(isolatedCodexHomeURL)

        guard case .login(let message) = failure else {
            Issue.record("Expected a login failure, got \(failure).")
            await store.stop()
            return
        }
        #expect((message ?? "").isEmpty == false)
        #expect((message ?? "").contains(sentinel) == false)
        #expect((store.auth.errorMessage ?? "").contains(sentinel) == false)
        #expect(store.auth.selectedAccount?.accountKey == activeChatGPTAccountKey)
        #expect(store.auth.persistedAccounts.map(\.accountKey) == [activeChatGPTAccountKey])
        #expect(try activeAccountKey(homeURL: homeURL) == activeChatGPTAccountKey)
        #expect(FileManager.default.fileExists(atPath: isolatedURL.path) == false)
        await store.stop()
    }

    @Test func liveStoreDefersAPIKeyCommitWhenSuccessfulResponseIsFollowedBySignedOutAccount() async throws {
        try await assertAPIKeyLoginReconciliationDebt(observedAccount: nil)
    }

    @Test func liveStoreDefersAPIKeyCommitWhenSuccessfulResponseIsFollowedByWrongProvider() async throws {
        try await assertAPIKeyLoginReconciliationDebt(observedAccount: try CodexAppServerTestAccount(
            kind: .chatGPT(email: "wrong@example.com", planType: .pro)
        ))
    }

    @Test func liveStoreReconcilesUnknownAPIKeyOutcomeToAuthenticatedAccount() async throws {
        try await assertUnknownAPIKeyLoginOutcome(committed: true)
    }

    @Test func liveStoreReconcilesUnknownAPIKeyOutcomeToNoCommit() async throws {
        try await assertUnknownAPIKeyLoginOutcome(committed: false)
    }

    @Test func liveStoreDiscardsIsolatedRuntimeWhenAPIKeyOutcomeIsUnknown() async throws {
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let chatGPTAccountKey = "active@example.com"
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: chatGPTAccountKey,
            accounts: [chatGPTAccountKey]
        )
        try writeSavedAccountAuth(homeURL: homeURL, accountKey: chatGPTAccountKey)
        let mainTransport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: mainTransport, email: chatGPTAccountKey)
        let isolatedTransport = FakeCodexAppServerTransport()
        try await isolatedTransport.enqueueChatGPTLogin(
            loginID: "unexpected-isolated-api-key-response",
            authenticationURL: testAuthenticationURL
        )
        var isolatedCodexHomeURL: URL?
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transportFactory: { runtimeHomeURL in
                if runtimeHomeURL == codexHomeURL {
                    return mainTransport
                }
                isolatedCodexHomeURL = runtimeHomeURL
                try FileManager.default.createDirectory(at: runtimeHomeURL, withIntermediateDirectories: true)
                #expect(FileManager.default.createFile(
                    atPath: runtimeHomeURL.appendingPathComponent("auth.json").path,
                    contents: Data(#"{"OPENAI_API_KEY":"isolated-secret"}"#.utf8),
                    attributes: [.posixPermissions: 0o600]
                ))
                return isolatedTransport
            }
        )
        await store.start(forceRestartIfNeeded: true)

        await #expect(throws: CodexReviewAuthenticationFailure.self) {
            try await store.addAccount(using: .apiKey(
                try CodexReviewAPIKey(validating: "isolated-secret")
            ))
        }

        let isolatedURL = try #require(isolatedCodexHomeURL)
        #expect(FileManager.default.fileExists(atPath: isolatedURL.path) == false)
        #expect(store.auth.selectedAccount?.accountKey == chatGPTAccountKey)
        #expect(store.auth.persistedAccounts.map(\.accountKey) == [chatGPTAccountKey])
        #expect(try activeAccountKey(homeURL: homeURL) == chatGPTAccountKey)
        #expect(FileManager.default.fileExists(
            atPath: accountReconciliationDebtURL(homeURL: homeURL).path
        ) == false)
        #expect(store.auth.errorMessage?.contains("isolated-secret") == false)
        await store.stop()
    }

    @Test func liveStoreAddsAPIKeyInIsolationThenSwitchesAndRestartsWithExactProvider() async throws {
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let chatGPTAccountKey = "active@example.com"
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: chatGPTAccountKey,
            accounts: [chatGPTAccountKey]
        )
        try writeSavedAccountAuth(homeURL: homeURL, accountKey: chatGPTAccountKey)
        let chatGPTAuthData = try Data(contentsOf: codexHomeURL.appendingPathComponent("auth.json"))

        let initialChatGPTTransport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: initialChatGPTTransport, email: chatGPTAccountKey)
        let switchedAPIKeyTransport = FakeCodexAppServerTransport()
        try await enqueueAPIKeyAccountBootstrap(on: switchedAPIKeyTransport)
        let restartedAPIKeyTransport = FakeCodexAppServerTransport()
        try await enqueueAPIKeyAccountBootstrap(on: restartedAPIKeyTransport)
        let switchedChatGPTTransport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: switchedChatGPTTransport, email: chatGPTAccountKey)
        var mainTransports = [
            initialChatGPTTransport,
            switchedAPIKeyTransport,
            restartedAPIKeyTransport,
            switchedChatGPTTransport,
        ]
        let isolatedTransport = FakeCodexAppServerTransport()
        try await isolatedTransport.enqueueAPIKeyLogin()
        try await isolatedTransport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .apiKey),
            requiresOpenAIAuth: false
        )
        let apiKeySentinel = "test-secret-isolated-api-key"
        let apiKeyAuthData = Data("{\"OPENAI_API_KEY\":\"\(apiKeySentinel)\"}".utf8)
        var isolatedCodexHomeURL: URL?
        let externalURLOpener = FakeExternalURLOpener()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            externalURLOpener: externalURLOpener.open,
            transportFactory: { runtimeHomeURL in
                if runtimeHomeURL == codexHomeURL {
                    return mainTransports.removeFirst()
                }
                isolatedCodexHomeURL = runtimeHomeURL
                try FileManager.default.createDirectory(at: runtimeHomeURL, withIntermediateDirectories: true)
                #expect(FileManager.default.createFile(
                    atPath: runtimeHomeURL.appendingPathComponent("auth.json").path,
                    contents: apiKeyAuthData,
                    attributes: [.posixPermissions: 0o600]
                ))
                return isolatedTransport
            }
        )
        await store.start(forceRestartIfNeeded: true)

        try await store.addAccount(using: .apiKey(try CodexReviewAPIKey(validating: apiKeySentinel)))

        let isolatedURL = try #require(isolatedCodexHomeURL)
        #expect(FileManager.default.fileExists(atPath: isolatedURL.path) == false)
        #expect(externalURLOpener.openedURLs.isEmpty)
        #expect(store.auth.selectedAccount?.accountKey == chatGPTAccountKey)
        #expect(Set(store.auth.persistedAccounts.map(\.accountKey)) == Set([chatGPTAccountKey, "api-key"]))
        #expect(try Data(contentsOf: codexHomeURL.appendingPathComponent("auth.json")) == chatGPTAuthData)
        #expect(await isolatedTransport.recordedRequests(for: .accountRateLimitsRead).isEmpty)

        let apiKeyAccount = try #require(store.auth.persistedAccounts.first { $0.accountKey == "api-key" })
        try await store.switchAccount(apiKeyAccount)
        #expect(store.auth.selectedAccount?.kind == .apiKey)
        #expect(try Data(contentsOf: codexHomeURL.appendingPathComponent("auth.json")) == apiKeyAuthData)
        #expect(await switchedAPIKeyTransport.recordedRequests(for: .accountRateLimitsRead).isEmpty)

        await store.restart()
        #expect(store.serverState == .running)
        #expect(store.auth.selectedAccount?.kind == .apiKey)
        #expect(await restartedAPIKeyTransport.recordedRequests(for: .accountRateLimitsRead).isEmpty)

        let chatGPTAccount = try #require(store.auth.persistedAccounts.first {
            $0.accountKey == chatGPTAccountKey
        })
        try await store.switchAccount(chatGPTAccount)
        #expect(store.auth.selectedAccount?.kind == .chatGPT)
        #expect(try Data(contentsOf: codexHomeURL.appendingPathComponent("auth.json")) == chatGPTAuthData)
        #expect(mainTransports.isEmpty)

        await store.stop()
    }

    @Test func liveStoreRejectsLoginWhoseLeaseReturnsAfterFinalAdmissionCloses() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let accountKey = "active@example.com"
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: accountKey,
            accounts: [accountKey]
        )
        let firstMainTransport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: firstMainTransport, email: accountKey)
        let secondMainTransport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: secondMainTransport, email: accountKey)
        var mainTransports = [firstMainTransport, secondMainTransport]
        let isolatedTransport = FakeCodexAppServerTransport()
        try await isolatedTransport.enqueueChatGPTLogin(
            loginID: "post-final-login",
            authenticationURL: testAuthenticationURL
        )
        try await isolatedTransport.enqueueChatGPTLoginCancellation(.canceled)
        let leasedMutationGate = CodexAppServerTestGate()
        let finalShutdownRequested = OneShotSignal()
        var isolatedFactoryCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            authenticationMutationDidBegin: {
                await leasedMutationGate.waitIgnoringCancellation()
            },
            finalShutdownDidRequest: {
                await finalShutdownRequested.signal()
            },
            transportFactory: { codexHomeURL in
                if codexHomeURL == mainCodexHomeURL {
                    return mainTransports.removeFirst()
                }
                isolatedFactoryCount += 1
                return isolatedTransport
            }
        )

        await store.start(forceRestartIfNeeded: true)
        let lateLogin = Task { @MainActor in
            try await store.addAccount()
        }
        await leasedMutationGate.waitUntilBlocked()

        let finalStop = Task { @MainActor in
            await store.stop()
        }
        await finalShutdownRequested.wait()
        await leasedMutationGate.open()
        await finalStop.value
        #expect(isolatedFactoryCount == 0)
        #expect(await firstMainTransport.recordedRequests(for: .accountLoginStart).isEmpty)

        do {
            try await lateLogin.value
            Issue.record("Expected final shutdown to reject the login before session installation.")
        } catch let failure as CodexReviewAuthenticationFailure {
            #expect(failure == .accountMutationBlockedByAuthentication)
        }
        #expect(isolatedFactoryCount == 0)

        await store.start(forceRestartIfNeeded: true)
        try await store.addAccount()
        await isolatedTransport.waitForRequest(.accountLoginStart)
        #expect(isolatedFactoryCount == 1)
        await store.cancelAuthentication()
        await store.stop()
    }

    @Test func liveStoreClassifiesConcurrentLoginBeforeSessionInstallation() async throws {
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueChatGPTLogin(
            loginID: "pre-session-concurrent-login",
            authenticationURL: testAuthenticationURL
        )
        try await transport.enqueueChatGPTLoginCancellation(.canceled)
        let mutationGate = CodexAppServerTestGate()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            authenticationMutationDidBegin: {
                await mutationGate.waitIgnoringCancellation()
            },
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        let firstLogin = Task { @MainActor in
            try await store.addAccount()
        }
        await mutationGate.waitUntilBlocked()

        do {
            try await store.addAccount()
            Issue.record("Expected the reserved pre-session login to reject a concurrent command.")
        } catch let failure as CodexReviewAuthenticationFailure {
            #expect(failure == .alreadyInProgress)
        }

        await mutationGate.open()
        try await firstLogin.value
        await transport.waitForRequest(.accountLoginStart)
        #expect(await transport.recordedRequests(for: .accountLoginStart).count == 1)
        await store.cancelAuthentication()
        await store.stop()
    }

    @Test func liveStoreCollectsPostCommitAccountDirectoryDebtOnNextLoad() async throws {
        let homeURL = try temporaryHome()
        let accountKey = "removed@example.com"
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: nil,
            accounts: [accountKey]
        )
        try writeSavedAccountAuth(homeURL: homeURL, accountKey: accountKey)
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transport: FakeCodexAppServerTransport()
        )
        try await store.removeAccount(accountKey: accountKey)

        let orphanedAccountURL = homeURL
            .appendingPathComponent(".codex_review", isDirectory: true)
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(pathComponent(forAccountKey: accountKey), isDirectory: true)
        let orphanedRevisionURL = orphanedAccountURL
            .appendingPathComponent("revisions", isDirectory: true)
            .appendingPathComponent("post-commit-orphan.json")
        try FileManager.default.createDirectory(
            at: orphanedRevisionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"tokens":{"id_token":"orphan"}}"#.utf8).write(to: orphanedRevisionURL)

        _ = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transport: FakeCodexAppServerTransport()
        )

        #expect(FileManager.default.fileExists(atPath: orphanedAccountURL.path) == false)
        #expect(try activeAccountKey(homeURL: homeURL) == nil)
    }

    @Test func liveStoreRetriesCredentialTemporaryHomeCleanupDebtOnLoad() throws {
        let homeURL = try temporaryHome()
        let credentialHomeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-review-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: credentialHomeURL,
            withIntermediateDirectories: false
        )
        try Data(#"{"tokens":{"id_token":"pending-cleanup"}}"#.utf8).write(
            to: credentialHomeURL.appendingPathComponent("auth.json")
        )
        let debtURL = temporaryHomeCleanupDebtURL(homeURL: homeURL)
        try FileManager.default.createDirectory(
            at: debtURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: ["paths": [credentialHomeURL.path]])
            .write(to: debtURL)

        _ = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transport: FakeCodexAppServerTransport()
        )

        #expect(FileManager.default.fileExists(atPath: credentialHomeURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: debtURL.path) == false)
    }

    @Test func accountRegistryKeepsTemporaryHomeDebtUntilParentRemovalIsDurable() async throws {
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let temporaryParentURL = FileManager.default.temporaryDirectory.standardizedFileURL
        let synchronization = PathSynchronizationFailureProbe(
            path: temporaryParentURL.path,
            failureCount: 0
        )
        let registry = AccountRegistryStore(
            codexHomeURL: codexHomeURL,
            directoryDurabilityDidSynchronize: synchronization.failIfNeeded
        )
        let temporaryHomeURL = try await registry.reserveTemporaryCodexHome(
            kind: .authentication
        )
        try Data(#"{"tokens":{"id_token":"pending-cleanup"}}"#.utf8).write(
            to: temporaryHomeURL.appendingPathComponent("auth.json")
        )
        synchronization.arm(failureCount: 2)

        await registry.finishTemporaryCodexHome(temporaryHomeURL)

        #expect(FileManager.default.fileExists(atPath: temporaryHomeURL.path) == false)
        let debtURL = temporaryHomeCleanupDebtURL(homeURL: homeURL)
        #expect(FileManager.default.fileExists(atPath: debtURL.path))
        let debt = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: debtURL)) as? [String: Any]
        )
        #expect((debt["paths"] as? [String])?.contains(temporaryHomeURL.path) == true)
        #expect(synchronization.recordedFailureCount == 2)

        await registry.finishTemporaryCodexHome(temporaryHomeURL)

        #expect(FileManager.default.fileExists(atPath: debtURL.path) == false)
        #expect(synchronization.recordedInvocationCount == 3)
    }

    @Test func accountRegistryRejectsLateRuntimeWriteAfterGenerationAdmissionCloses() async throws {
        let homeURL = try temporaryHome()
        let accountKey = "active@example.com"
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: accountKey,
            accounts: [accountKey]
        )
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let registry = AccountRegistryStore(codexHomeURL: codexHomeURL)
        let snapshot = try await registry.load()
        var payload = try #require(snapshot.accounts.first)
        payload.rateLimits = [(windowDurationMinutes: 300, usedPercent: 99, resetsAt: nil)]
        payload.lastRateLimitFetchAt = Date(timeIntervalSince1970: 123)

        await registry.openRuntimeAdmission(generation: 7)
        await registry.closeRuntimeAdmission(generation: 7)
        let before = try Data(contentsOf: accountRegistryURL(homeURL: homeURL))
        do {
            try await registry.updateCachedRateLimits(
                from: payload,
                runtimeAuthorization: .init(generation: 7)
            )
            Issue.record("Expected a closed runtime generation to reject its late disk commit.")
        } catch let failure as CodexReviewAuthenticationFailure {
            #expect(failure == .accountMutationBlockedByAuthentication)
        }

        #expect(try Data(contentsOf: accountRegistryURL(homeURL: homeURL)) == before)
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
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeAPIKeyAuth(
            Data(#"{"OPENAI_API_KEY":"test-key"}"#.utf8),
            to: codexHomeURL
        )
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .apiKey),
            requiresOpenAIAuth: false
        )
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
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
        await store.stop()
    }

    @Test func liveStoreCompletesStockLoginAfterAccountReadiness() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueChatGPTLogin(loginID: "login-1", authenticationURL: testAuthenticationURL)
        let newAccount = try CodexAppServerTestAccount(kind: .chatGPT(
            email: "new@example.com",
            planType: .plus
        ))
        try await transport.enqueueAccount(newAccount, requiresOpenAIAuth: false)
        try await transport.enqueueAccount(newAccount, requiresOpenAIAuth: false)
        try await transport.enqueueAccount(newAccount, requiresOpenAIAuth: false)
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
        await transport.waitForRequestCount(9)
        #expect(await transport.recordedRequests().map(\.request.operation) == [
            .initialize,
            .accountRead,
            .configurationRead,
            .modelList,
            .accountLoginStart,
            .accountRead,
            .accountRead,
            .accountRateLimitsRead,
            .accountRead,
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

    @Test func liveStoreRejectsForcedRuntimeStartWhileLoginOwnsPrimaryRuntime() async throws {
        let homeURL = try temporaryHome()
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueChatGPTLogin(
            loginID: "login-runtime-start-admission",
            authenticationURL: testAuthenticationURL
        )
        try await transport.enqueueChatGPTLoginCancellation(.canceled)
        var factoryCount = 0
        var closeCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            appServerCloser: { appServer in
                closeCount += 1
                await appServer.close()
            },
            transportFactory: { _ in
                factoryCount += 1
                return transport
            }
        )

        await store.start(forceRestartIfNeeded: true)
        try await store.addAccount()
        await transport.waitForRequest(.accountLoginStart)

        await store.start(forceRestartIfNeeded: true)

        #expect(store.serverState == .running)
        #expect(store.auth.isAuthenticating)
        #expect(factoryCount == 1)
        #expect(closeCount == 0)
        #expect(await transport.recordedRequests(for: .accountLoginCancel).isEmpty)

        await store.cancelAuthentication()
        await store.stop()
    }

    @Test func liveStoreLetsCancellationWinBeforeURLPresentationClaim() async throws {
        let homeURL = try temporaryHome()
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueChatGPTLogin(
            loginID: "login-presentation-claim",
            authenticationURL: testAuthenticationURL
        )
        try await transport.enqueueChatGPTLoginCancellation(.canceled)
        let presentationClaimGate = CodexAppServerTestGate()
        let externalURLOpener = FakeExternalURLOpener()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            externalURLOpener: externalURLOpener.open,
            authenticationOperationDidBind: {
                await presentationClaimGate.waitIgnoringCancellation()
            },
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        let login = Task { @MainActor in
            try await store.addAccount()
        }
        await presentationClaimGate.waitUntilBlocked()
        let cancellation = Task { @MainActor in
            await store.cancelAuthentication()
        }
        await transport.waitForRequest(.accountLoginCancel)
        await presentationClaimGate.open()
        try await login.value
        await cancellation.value

        #expect(externalURLOpener.openedURLs.isEmpty)
        #expect(await transport.recordedRequests(for: .accountLoginCancel).count == 1)
        #expect(store.auth.isAuthenticating == false)
        try await store.reorderPersistedAccount(accountKey: "missing@example.com", toIndex: 0)
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
        try #require(await waitUntil(timeout: .seconds(2)) {
            appServerLifecycleStates == [true, false]
        })

        #expect(await transport.recordedRequests(for: .accountLoginCancel).count == 1)
        await cancelGate.open()
        await cancel
        await stop

        #expect(await transport.recordedRequests(for: .accountLoginCancel).count == 1)
        #expect(store.auth.isAuthenticating == false)
        #expect(store.serverURL == nil)
    }

    @Test func liveStoreDefersSupersededPrimaryLoginHandoffToRuntimeStop() async throws {
        let homeURL = try temporaryHome()
        let initialTransport = FakeCodexAppServerTransport()
        try await initialTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await initialTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await initialTransport.enqueueModels(.init(models: []))
        try await initialTransport.enqueueChatGPTLogin(
            loginID: "final-primary-handoff",
            authenticationURL: testAuthenticationURL
        )
        try await initialTransport.enqueueFailure(
            .response(code: -32_000, message: "cancel response lost"),
            for: .accountLoginCancel
        )
        let reconciliationTransport = FakeCodexAppServerTransport()
        try await reconciliationTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await reconciliationTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await reconciliationTransport.enqueueModels(.init(models: []))
        let cancellationGate = CodexAppServerTestGate()
        let finalShutdownRequested = OneShotSignal()
        var transports = [initialTransport, reconciliationTransport]
        var appServerCloseCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            finalShutdownDidRequest: { await finalShutdownRequested.signal() },
            appServerCloser: { appServer in
                appServerCloseCount += 1
                await appServer.close()
            },
            transportFactory: { _ in transports.removeFirst() }
        )

        await store.start(forceRestartIfNeeded: true)
        try await store.addAccount()
        await initialTransport.waitForRequest(.accountLoginStart)
        await initialTransport.holdNextIgnoringCancellation(
            .accountLoginCancel,
            gate: cancellationGate
        )
        let cancellation = Task { @MainActor in
            await store.cancelAuthentication()
        }
        await cancellationGate.waitUntilBlocked()
        let stop = Task { @MainActor in
            await store.stop()
        }
        await finalShutdownRequested.wait()
        await cancellationGate.open()
        await cancellation.value
        await stop.value
        await store.waitUntilStopped()

        #expect(transports.isEmpty)
        #expect(appServerCloseCount == 2)
        #expect(store.serverState == .stopped)
        #expect(store.auth.isAuthenticating == false)
        #expect(FileManager.default.fileExists(
            atPath: accountReconciliationDebtURL(homeURL: homeURL).path
        ) == false)
    }

    @Test func liveStoreRoutesExplicitClosingHandoffOnceWhenRuntimeFails() async throws {
        let homeURL = try temporaryHome()
        let initialTransport = FakeCodexAppServerTransport()
        try await initialTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await initialTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await initialTransport.enqueueModels(.init(models: []))
        try await initialTransport.enqueueChatGPTLogin(
            loginID: "explicit-closing-runtime-failure",
            authenticationURL: testAuthenticationURL
        )
        try await initialTransport.enqueueFailure(
            .response(code: -32_000, message: "cancel response lost"),
            for: .accountLoginCancel
        )
        let cancelGate = CodexAppServerTestGate()
        await initialTransport.holdNextIgnoringCancellation(
            .accountLoginCancel,
            gate: cancelGate
        )
        let replacementTransport = FakeCodexAppServerTransport()
        try await replacementTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await replacementTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await replacementTransport.enqueueModels(.init(models: []))
        var transports = [initialTransport, replacementTransport]
        var lifecycleStates: [Bool] = []
        let firstRuntimeClosed = OneShotSignal()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            appServerLifecycleHandler: { container in
                lifecycleStates.append(container != nil)
                if container == nil {
                    Task { await firstRuntimeClosed.signal() }
                }
            },
            transportFactory: { _ in transports.removeFirst() }
        )

        await store.start(forceRestartIfNeeded: true)
        try await store.addAccount()
        await initialTransport.waitForRequest(.accountLoginStart)
        let cancellation = Task { @MainActor in
            await store.cancelAuthentication()
        }
        await initialTransport.waitForRequest(.accountLoginCancel)
        await cancelGate.waitUntilBlocked()

        await initialTransport.failConnection(.closed)
        await firstRuntimeClosed.wait()
        await cancelGate.open()
        await cancellation.value
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.serverState == .running
        })

        #expect(await initialTransport.recordedRequests(for: .accountLoginCancel).count == 1)
        #expect(transports.isEmpty)
        #expect(lifecycleStates == [true, false, true])
        await store.stop()
    }

    @Test func liveStoreRetainsPrimaryAuthenticationHandoffAcrossIncompleteStopRetry() async throws {
        let homeURL = try temporaryHome()
        let initialTransport = FakeCodexAppServerTransport()
        try await initialTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await initialTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await initialTransport.enqueueModels(.init(models: []))
        try await initialTransport.enqueueChatGPTLogin(
            loginID: "stop-incomplete-primary-handoff",
            authenticationURL: testAuthenticationURL
        )
        try await initialTransport.enqueueFailure(
            .response(code: -32_000, message: "cancel response lost"),
            for: .accountLoginCancel
        )
        let replacementTransport = FakeCodexAppServerTransport()
        try await replacementTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await replacementTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await replacementTransport.enqueueModels(.init(models: []))
        try await replacementTransport.enqueueSuccess(for: .threadDelete)
        try await replacementTransport.enqueueSuccess(for: .threadDelete)
        var transports = [initialTransport, replacementTransport]
        var factoryCount = 0
        var closeCount = 0
        let liveStore = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            appServerCloser: { appServer in
                closeCount += 1
                await appServer.close()
            },
            transportFactory: { _ in
                factoryCount += 1
                return transports.removeFirst()
            }
        )
        let journal = ControlledHostRetentionJournal()
        let store = CodexReviewStore.makeTestingStore(
            backend: liveStore.backend,
            reviewThreadRetentionJournal: journal
        )

        await store.start(forceRestartIfNeeded: true)
        let retainedRunID = try ReviewRunID(validating: "retained-run")
        let retainedAttempt = makeReviewAttemptForTesting(
            attemptID: "retained-attempt",
            sourceThreadID: "retained-source",
            activeTurnThreadID: "retained-review",
            turnID: "retained-turn"
        )
        try await store.reviewThreadRetentionRegistry.claim(
            retainedAttempt,
            for: retainedRunID,
            scope: store.currentReviewThreadRetentionScope
        )
        await journal.failReplacements("injected retention write failure")
        try await store.addAccount()
        await initialTransport.waitForRequest(.accountLoginStart)

        await store.stop()

        #expect({
            if case .failed = store.serverState { return true }
            return false
        }())
        #expect(factoryCount == 1)
        #expect(closeCount == 0)
        #expect(await initialTransport.recordedRequests(for: .accountLoginCancel).count == 1)
        #expect(await store.reviewThreadRetentionRegistry.acceptance().isAccepting == false)
        let lateCancellationCompleted = CompletionFlag()
        let lateCancellationStarted = OneShotSignal()
        let lateCancellation = Task { @MainActor in
            await lateCancellationStarted.signal()
            await store.cancelAuthentication()
            await lateCancellationCompleted.complete()
        }
        await lateCancellationStarted.wait()
        #expect(await lateCancellationCompleted.isCompleted() == false)

        await journal.failReplacements(nil)
        await store.stop()
        await lateCancellation.value

        #expect(store.serverState == .stopped)
        #expect(factoryCount == 2)
        #expect(closeCount == 2)
        #expect(await lateCancellationCompleted.isCompleted())
        #expect(await initialTransport.recordedRequests(for: .accountLoginCancel).count == 1)
        #expect(try await journal.load().entries.isEmpty)
        #expect(await store.reviewThreadRetentionRegistry.acceptance().isAccepting)
        #expect(FileManager.default.fileExists(
            atPath: accountReconciliationDebtURL(homeURL: homeURL).path
        ) == false)
        #expect(transports.isEmpty)
        _ = liveStore
    }

    @Test func liveStoreKeepsEmptyRegistryWhenUnknownPrimaryCancellationIsSignedOut() async throws {
        try await exerciseUnknownPrimaryCancellation(
            previousAccountKey: nil,
            observedAccountKey: nil,
            expectedActiveAccountKey: nil
        )
    }

    @Test func liveStoreDeactivatesPreviousAccountWhenUnknownPrimaryCancellationIsSignedOut() async throws {
        try await exerciseUnknownPrimaryCancellation(
            previousAccountKey: "previous@example.com",
            observedAccountKey: nil,
            expectedActiveAccountKey: nil
        )
    }

    @Test func liveStoreKeepsPreviousAccountWhenUnknownPrimaryCancellationObservesSameAccount() async throws {
        try await exerciseUnknownPrimaryCancellation(
            previousAccountKey: "previous@example.com",
            observedAccountKey: "previous@example.com",
            expectedActiveAccountKey: "previous@example.com"
        )
    }

    @Test func liveStoreCommitsNewAccountWhenUnknownPrimaryCancellationObservesNewAccount() async throws {
        try await exerciseUnknownPrimaryCancellation(
            previousAccountKey: "previous@example.com",
            observedAccountKey: "new@example.com",
            expectedActiveAccountKey: "new@example.com"
        )
    }

    @Test func liveStoreJoinsLateCancellationToActivePrimaryReconciliationResult() async throws {
        let homeURL = try temporaryHome()
        let initialTransport = FakeCodexAppServerTransport()
        try await initialTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await initialTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await initialTransport.enqueueModels(.init(models: []))
        try await initialTransport.enqueueChatGPTLogin(
            loginID: "unknown-primary-cancel-join",
            authenticationURL: testAuthenticationURL
        )
        try await initialTransport.enqueueFailure(
            .response(code: -32_000, message: "cancel response lost"),
            for: .accountLoginCancel
        )
        let replacementTransport = FakeCodexAppServerTransport()
        try await replacementTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await replacementTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await replacementTransport.enqueueModels(.init(models: []))
        let replacementStageGate = CodexAppServerTestGate()
        let replacementMCPServer = MCPHTTPServerProbe(
            endpoint: URL(string: "http://127.0.0.1:9417/mcp")!,
            stageGate: replacementStageGate
        )
        var transports = [initialTransport, replacementTransport]
        var mcpFactoryCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            mcpHTTPServerFactory: { _, configuration, _ in
                mcpFactoryCount += 1
                return mcpFactoryCount == 1
                    ? NoopMCPHTTPServer(endpoint: configuration.url())
                    : replacementMCPServer
            },
            mcpHTTPServerBindChecker: { _ in },
            transportFactory: { _ in transports.removeFirst() }
        )

        await store.start(forceRestartIfNeeded: true)
        try await store.addAccount()
        await initialTransport.waitForRequest(.accountLoginStart)
        let firstCompleted = CompletionFlag()
        let firstCancellation = Task { @MainActor in
            await store.cancelAuthentication()
            await firstCompleted.complete()
        }
        await replacementStageGate.waitUntilBlocked()
        let secondCompleted = CompletionFlag()
        let secondCancellationStarted = OneShotSignal()
        let secondCancellation = Task { @MainActor in
            await secondCancellationStarted.signal()
            await store.cancelAuthentication()
            await secondCompleted.complete()
        }
        await secondCancellationStarted.wait()

        #expect(await firstCompleted.isCompleted() == false)
        #expect(await secondCompleted.isCompleted() == false)
        #expect(await initialTransport.recordedRequests(for: .accountLoginCancel).count == 1)
        #expect(mcpFactoryCount == 2)

        await replacementStageGate.open()
        await firstCancellation.value
        await secondCancellation.value

        #expect(await firstCompleted.isCompleted())
        #expect(await secondCompleted.isCompleted())
        #expect(store.serverState == .running)
        #expect(await initialTransport.recordedRequests(for: .accountLoginCancel).count == 1)
        #expect(transports.isEmpty)
        await store.stop()
    }

    @Test func liveStoreKeepsPrimaryReconciliationFailureStickyUntilExplicitRepairCommits() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: nil,
            accounts: ["first@example.com", "second@example.com"]
        )
        let initialTransport = FakeCodexAppServerTransport()
        try await initialTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await initialTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await initialTransport.enqueueModels(.init(models: []))
        try await initialTransport.enqueueChatGPTLogin(
            loginID: "primary-unknown-cancel",
            authenticationURL: testAuthenticationURL
        )
        try await initialTransport.enqueueFailure(
            .response(code: -32_000, message: "cancel response lost"),
            for: .accountLoginCancel
        )
        let repairTransport = FakeCodexAppServerTransport()
        try await repairTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await repairTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await repairTransport.enqueueModels(.init(models: []))
        try await repairTransport.enqueueChatGPTLogin(
            loginID: "post-repair-login",
            authenticationURL: testAuthenticationURL
        )
        try await repairTransport.enqueueChatGPTLoginCancellation(.canceled)
        var mainFactoryCallCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transportFactory: { codexHomeURL in
                #expect(codexHomeURL == mainCodexHomeURL)
                mainFactoryCallCount += 1
                switch mainFactoryCallCount {
                case 1:
                    return initialTransport
                case 2:
                    throw CodexReviewAPI.Error.io("replacement validation runtime unavailable")
                case 3:
                    return repairTransport
                default:
                    Issue.record("Unexpected primary runtime factory invocation.")
                    return repairTransport
                }
            }
        )

        await store.start(forceRestartIfNeeded: true)
        try await store.addAccount()
        await initialTransport.waitForRequest(.accountLoginStart)
        await store.cancelAuthentication()
        try #require(await waitUntil(timeout: .seconds(2)) {
            if case .failed = store.serverState {
                return true
            }
            return false
        })
        #expect(mainFactoryCallCount == 2)
        #expect(FileManager.default.fileExists(
            atPath: accountReconciliationDebtURL(homeURL: homeURL).path
        ))

        let reviewRunCount = store.reviewRuns.count
        do {
            _ = try await store.startReview(
                sessionID: "sticky-failure-review",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            Issue.record("Expected sticky reconciliation failure to reject review admission.")
        } catch {}
        #expect(store.reviewRuns.count == reviewRunCount)
        do {
            try await store.addAccount()
            Issue.record("Expected sticky reconciliation failure to reject account admission.")
        } catch {}
        #expect(await initialTransport.recordedRequests(for: .accountLoginStart).count == 1)
        do {
            try await store.reorderPersistedAccount(
                accountKey: "second@example.com",
                toIndex: 0
            )
            Issue.record("Expected sticky reconciliation failure to reject a runtime-independent account mutation.")
        } catch let failure as CodexReviewAuthenticationFailure {
            #expect(failure == .accountMutationBlockedByAuthentication)
        }

        await store.start(forceRestartIfNeeded: true)

        #expect(store.serverState == .running)
        #expect(mainFactoryCallCount == 3)
        #expect(FileManager.default.fileExists(
            atPath: accountReconciliationDebtURL(homeURL: homeURL).path
        ) == false)
        try await store.reorderPersistedAccount(
            accountKey: "second@example.com",
            toIndex: 0
        )
        #expect(store.auth.persistedAccounts.map(\.accountKey).first == "second@example.com")
        try await store.addAccount()
        await repairTransport.waitForRequest(.accountLoginStart)
        await store.cancelAuthentication()
        await store.stop()
    }

    @Test func liveStoreRecordsReconciliationDebtAsFirstAccountArtifact() async throws {
        let homeURL = try temporaryHome()
        let initialTransport = FakeCodexAppServerTransport()
        try await initialTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await initialTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await initialTransport.enqueueModels(.init(models: []))
        try await initialTransport.enqueueChatGPTLogin(
            loginID: "first-account-artifact-debt",
            authenticationURL: testAuthenticationURL
        )
        try await initialTransport.enqueueFailure(
            .response(code: -32_000, message: "cancel response lost"),
            for: .accountLoginCancel
        )
        var factoryCallCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transportFactory: { _ in
                factoryCallCount += 1
                if factoryCallCount == 1 {
                    return initialTransport
                }
                throw CodexReviewAPI.Error.io("replacement runtime unavailable")
            }
        )

        await store.start(forceRestartIfNeeded: true)
        let accountsURL = accountReconciliationDebtURL(homeURL: homeURL)
            .deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: accountsURL.path) == false)
        try await store.addAccount()
        await initialTransport.waitForRequest(.accountLoginStart)

        await store.cancelAuthentication()

        #expect(factoryCallCount == 2)
        #expect(FileManager.default.fileExists(
            atPath: accountReconciliationDebtURL(homeURL: homeURL).path
        ))
        #expect(FileManager.default.fileExists(atPath: accountsURL.path))
        #expect({
            if case .failed = store.serverState { return true }
            return false
        }())
        await store.stop()
    }

    @Test func accountRegistryRetriesAncestorDurabilityAfterVisibleDirectoryFailure() async throws {
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL
            .appendingPathComponent("missing-parent", isDirectory: true)
            .appendingPathComponent("custom-codex-home", isDirectory: true)
        let synchronization = DirectorySynchronizationFailureProbe()
        let registry = AccountRegistryStore(
            codexHomeURL: codexHomeURL,
            directoryDurabilityDidSynchronize: synchronization.failFirstSynchronization
        )

        do {
            try await registry.recordReconciliationDebt(
                expectedAccount: .signedOut,
                message: "first attempt"
            )
            Issue.record("Expected the first directory durability confirmation to fail.")
        } catch {}
        #expect(FileManager.default.fileExists(
            atPath: accountReconciliationDebtURLForCodexHome(codexHomeURL).path
        ) == false)

        try await registry.recordReconciliationDebt(
            expectedAccount: .signedOut,
            message: "retry"
        )

        #expect(FileManager.default.fileExists(
            atPath: accountReconciliationDebtURLForCodexHome(codexHomeURL).path
        ))
        #expect(synchronization.failureCount == 1)
        #expect(synchronization.synchronizedPaths.last == "/")
        #expect(synchronization.synchronizedPaths.filter { $0 == "/" }.count == 1)
    }

    @Test func liveStoreFailsClosedWhenDirectRegistryMutationDurabilityIsUnresolved() async throws {
        let homeURL = try temporaryHome()
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "first@example.com",
            accounts: ["first@example.com", "second@example.com"]
        )
        let transport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(
            on: transport,
            email: "first@example.com"
        )
        let corruption = RegistryReplacementCorruptingProbe(
            registryURL: accountRegistryURL(homeURL: homeURL)
        )
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            registryDestinationDidReplace: corruption.corruptIfArmed,
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        corruption.arm()
        await #expect(throws: CodexReviewAuthenticationFailure.self) {
            try await store.reorderPersistedAccount(
                accountKey: "second@example.com",
                toIndex: 0
            )
        }

        #expect(corruption.corruptionCount == 1)
        #expect({
            if case .failed = store.serverState { return true }
            return false
        }())
        #expect(store.auth.errorMessage?.contains("unresolved durable outcome") == true)
        #expect(FileManager.default.fileExists(
            atPath: accountReconciliationDebtURL(homeURL: homeURL).path
        ))
        let debtData = try Data(contentsOf: accountReconciliationDebtURL(homeURL: homeURL))
        let debt = try #require(JSONSerialization.jsonObject(with: debtData) as? [String: Any])
        #expect(debt["expectation"] as? String == "observedAccount")
        #expect(debt["accountKey"] as? String == "first@example.com")
        #expect(debt["provider"] as? String == "chatGPT")
        do {
            try await store.reorderPersistedAccount(
                accountKey: "first@example.com",
                toIndex: 0
            )
            Issue.record("Expected unresolved registry durability to keep account admission closed.")
        } catch let failure as CodexReviewAuthenticationFailure {
            #expect(failure == .accountMutationBlockedByAuthentication)
        }
        await store.stop()
    }

    @Test func liveStoreRecordsExactProviderForUnresolvedDirectRegistryMutation() async throws {
        let homeURL = try temporaryHome()
        try writeRegistryRecords(
            homeURL: homeURL,
            activeAccountKey: "api-key",
            records: [
                [
                    "accountKey": "api-key",
                    "kind": "apiKey",
                    "email": "API Key",
                    "planType": "pro",
                ],
                [
                    "accountKey": "second@example.com",
                    "kind": "chatgpt",
                    "email": "second@example.com",
                    "planType": "pro",
                ],
            ]
        )
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .apiKey),
            requiresOpenAIAuth: false
        )
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        let corruption = RegistryReplacementCorruptingProbe(
            registryURL: accountRegistryURL(homeURL: homeURL)
        )
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            registryDestinationDidReplace: corruption.corruptIfArmed,
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        corruption.arm()
        await #expect(throws: CodexReviewAuthenticationFailure.self) {
            try await store.reorderPersistedAccount(
                accountKey: "second@example.com",
                toIndex: 0
            )
        }

        let debtData = try Data(contentsOf: accountReconciliationDebtURL(homeURL: homeURL))
        let debt = try #require(JSONSerialization.jsonObject(with: debtData) as? [String: Any])
        #expect(debt["expectation"] as? String == "observedAccount")
        #expect(debt["accountKey"] as? String == "api-key")
        #expect(debt["provider"] as? String == "apiKey")
        await store.stop()
    }

    @Test func liveStoreUsesCurrentRuntimeRecoveryWhenDirectMutationObservationAdvances() async throws {
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "first@example.com",
            accounts: ["first@example.com", "second@example.com"]
        )
        let transport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: transport, email: "first@example.com")
        let loadGate = ArmableAsyncHookGate()
        let corruption = RegistryReplacementCorruptingProbe(
            registryURL: accountRegistryURL(homeURL: homeURL)
        )
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            accountRegistryLoadDidBegin: { await loadGate.waitIfArmed() },
            registryDestinationDidReplace: corruption.corruptIfArmed,
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await loadGate.arm()
        corruption.arm()
        let mutation = Task { @MainActor in
            try await store.reorderPersistedAccount(
                accountKey: "second@example.com",
                toIndex: 0
            )
        }
        await loadGate.waitUntilBlocked()
        try Data(#"{"tokens":{"id_token":"third@example.com"}}"#.utf8).write(
            to: codexHomeURL.appendingPathComponent("auth.json")
        )
        try await transport.notificationEmitter.emitAccountChanged(.init(
            authMode: .chatGPT,
            planType: .plus
        ))
        await loadGate.open()
        await #expect(throws: CodexReviewAuthenticationFailure.self) {
            try await mutation.value
        }

        let debtData = try Data(contentsOf: accountReconciliationDebtURL(homeURL: homeURL))
        let debt = try #require(JSONSerialization.jsonObject(with: debtData) as? [String: Any])
        #expect(debt["expectation"] as? String == "reconcileCurrentRuntime")
        #expect({ if case .failed = store.serverState { return true }; return false }())
        await store.stop()
    }

    @Test func liveStoreRestoresDebtWhenStagingConsumerFailsAfterDebtClear() async throws {
        let homeURL = try temporaryHome()
        let expectedAccountKey = "expected@example.com"
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: expectedAccountKey,
            accounts: [expectedAccountKey]
        )
        try writeReconciliationDebt(
            homeURL: homeURL,
            expectedAccountKey: expectedAccountKey
        )

        let interruptedRepair = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(
            on: interruptedRepair,
            email: expectedAccountKey,
            planType: .pro,
            usedPercent: 10
        )
        let wrongAccountRepair = FakeCodexAppServerTransport()
        try await wrongAccountRepair.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "wrong@example.com",
                planType: .plus
            )),
            requiresOpenAIAuth: false
        )
        try await wrongAccountRepair.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await wrongAccountRepair.enqueueModels(.init(models: []))
        let successfulRepair = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(
            on: successfulRepair,
            email: expectedAccountKey,
            planType: .pro,
            usedPercent: 20
        )
        var transports = [interruptedRepair, wrongAccountRepair, successfulRepair]
        var injectConsumerFailure = true
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            reconciliationDebtDidClear: { appServer in
                guard injectConsumerFailure else {
                    return
                }
                injectConsumerFailure = false
                await appServer.close()
            },
            transportFactory: { _ in transports.removeFirst() }
        )

        await store.start(forceRestartIfNeeded: true)
        #expect({
            if case .failed = store.serverState { return true }
            return false
        }())
        #expect(FileManager.default.fileExists(
            atPath: accountReconciliationDebtURL(homeURL: homeURL).path
        ))

        await store.start(forceRestartIfNeeded: true)
        #expect({
            if case .failed = store.serverState { return true }
            return false
        }())
        #expect(FileManager.default.fileExists(
            atPath: accountReconciliationDebtURL(homeURL: homeURL).path
        ))

        await store.start(forceRestartIfNeeded: true)
        #expect(store.serverState == .running)
        #expect(FileManager.default.fileExists(
            atPath: accountReconciliationDebtURL(homeURL: homeURL).path
        ) == false)
        await store.stop()
    }

    @Test func liveStoreFailsClosedWhenKnownPrimaryAccountCannotCommitRegistry() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: nil,
            accounts: ["first@example.com", "second@example.com"]
        )
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueChatGPTLogin(
            loginID: "known-primary-commit-failure",
            authenticationURL: testAuthenticationURL
        )
        let newAccount = try CodexAppServerTestAccount(kind: .chatGPT(
            email: "new@example.com",
            planType: .plus
        ))
        try await transport.enqueueAccount(newAccount, requiresOpenAIAuth: false)
        try await transport.enqueueAccount(newAccount, requiresOpenAIAuth: false)
        try await transport.enqueueAccount(newAccount, requiresOpenAIAuth: false)
        let accountReadGate = CodexAppServerTestGate()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        try await store.addAccount()
        await transport.waitForRequest(.accountLoginStart)
        try FileManager.default.createDirectory(
            at: mainCodexHomeURL,
            withIntermediateDirectories: true
        )
        try Data(#"{"tokens":{"id_token":"new@example.com"}}"#.utf8).write(
            to: mainCodexHomeURL.appendingPathComponent("auth.json")
        )
        await transport.holdNextIgnoringCancellation(.accountRead, gate: accountReadGate)
        try await transport.notificationEmitter.emitLoginCompleted(
            loginID: "known-primary-commit-failure",
            completion: .succeeded
        )
        try await transport.notificationEmitter.emitAccountChanged(.init(
            authMode: .chatGPT,
            planType: .plus
        ))
        await accountReadGate.waitUntilBlocked()
        try FileManager.default.removeItem(
            at: mainCodexHomeURL.appendingPathComponent("auth.json")
        )
        await accountReadGate.open()

        try #require(await waitUntil(timeout: .seconds(2)) {
            if case .failed = store.serverState { return true }
            return false
        })
        #expect(store.auth.errorMessage?.contains("reconciliation remains pending") == true)
        #expect(FileManager.default.fileExists(
            atPath: accountReconciliationDebtURL(homeURL: homeURL).path
        ))
        do {
            try await store.reorderPersistedAccount(accountKey: "second@example.com", toIndex: 0)
            Issue.record("Expected committed primary reconciliation debt to close account admission.")
        } catch let failure as CodexReviewAuthenticationFailure {
            #expect(failure == .accountMutationBlockedByAuthentication)
        }
        await store.stop()
    }

    @Test func liveStoreCommitsPrimaryAccountAfterPostReplaceSyncFailure() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueChatGPTLogin(
            loginID: "post-replace-primary",
            authenticationURL: testAuthenticationURL
        )
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
        let replaceFailure = RegistryReplaceFailureProbe()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            registryDestinationDidReplace: replaceFailure.failIfArmed,
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        try await store.addAccount()
        await transport.waitForRequest(.accountLoginStart)
        try FileManager.default.createDirectory(
            at: mainCodexHomeURL,
            withIntermediateDirectories: true
        )
        try Data(#"{"tokens":{"id_token":"new@example.com"}}"#.utf8).write(
            to: mainCodexHomeURL.appendingPathComponent("auth.json")
        )
        replaceFailure.arm()
        try await transport.notificationEmitter.emitLoginCompleted(
            loginID: "post-replace-primary",
            completion: .succeeded
        )
        try await transport.notificationEmitter.emitAccountChanged(.init(
            authMode: .chatGPT,
            planType: .plus
        ))

        try #require(await waitUntil(timeout: .seconds(2)) {
            store.auth.selectedAccount?.accountKey == "new@example.com"
        })
        #expect(store.serverState == .running)
        #expect(replaceFailure.failureCount == 1)
        #expect(try activeAccountKey(homeURL: homeURL) == "new@example.com")
        #expect(FileManager.default.fileExists(
            atPath: accountReconciliationDebtURL(homeURL: homeURL).path
        ) == false)
        #expect(try savedAccountAuth(
            homeURL: homeURL,
            accountKey: "new@example.com"
        ) == Data(#"{"tokens":{"id_token":"new@example.com"}}"#.utf8))
        await store.stop()
    }

    @Test func liveStoreCancelsLoginBeforeIsolatedRuntimeFactoryReturns() async throws {
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

        let lateRuntimeGate = CodexAppServerTestGate()
        let lateTransport = FakeCodexAppServerTransport()
        let nextTransport = FakeCodexAppServerTransport()
        try await nextTransport.enqueueChatGPTLogin(
            loginID: "login-next",
            authenticationURL: testAuthenticationURL
        )
        try await nextTransport.enqueueChatGPTLoginCancellation(.canceled)
        var isolatedFactoryCount = 0
        var lateCodexHomeURL: URL?
        let externalURLOpener = FakeExternalURLOpener()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            externalURLOpener: externalURLOpener.open,
            transportFactory: { codexHomeURL in
                if codexHomeURL == mainCodexHomeURL {
                    return mainTransport
                }
                isolatedFactoryCount += 1
                try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
                if isolatedFactoryCount == 1 {
                    lateCodexHomeURL = codexHomeURL
                    await lateRuntimeGate.waitIgnoringCancellation()
                    return lateTransport
                }
                return nextTransport
            }
        )

        await store.start(forceRestartIfNeeded: true)
        let add = Task { @MainActor in
            try await store.addAccount()
        }
        await lateRuntimeGate.waitUntilBlocked()
        let reservedTemporaryHome = try #require(lateCodexHomeURL)
        let cleanupDebt = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: temporaryHomeCleanupDebtURL(homeURL: homeURL))
            ) as? [String: Any]
        )
        #expect((cleanupDebt["paths"] as? [String])?.contains(reservedTemporaryHome.path) == true)
        async let cancel: Void = store.cancelAuthentication()
        await lateRuntimeGate.open()
        try await add.value
        await cancel

        let resolvedLateCodexHomeURL = try #require(lateCodexHomeURL)
        #expect(externalURLOpener.openedURLs.isEmpty)
        #expect(await lateTransport.recordedRequests(for: .accountLoginStart).isEmpty)
        #expect(FileManager.default.fileExists(atPath: resolvedLateCodexHomeURL.path) == false)

        try await store.addAccount()
        await nextTransport.waitForRequest(.accountLoginStart)
        #expect(externalURLOpener.openedURLs == [testAuthenticationURL])
        await store.cancelAuthentication()
        await store.stop()
    }

    @Test func liveStoreKeepsPreBindCancellationWhenIsolatedRuntimeFactoryFailsLate() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "active@example.com",
            accounts: ["active@example.com"]
        )
        let mainTransport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(
            on: mainTransport,
            email: "active@example.com"
        )
        let factoryGate = CodexAppServerTestGate()
        let cancellationRequested = OneShotSignal()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            authenticationCancellationDidRequest: {
                await cancellationRequested.signal()
            },
            transportFactory: { codexHomeURL in
                if codexHomeURL == mainCodexHomeURL {
                    return mainTransport
                }
                await factoryGate.waitIgnoringCancellation()
                throw CodexReviewAPI.Error.io("late isolated factory failure")
            }
        )

        await store.start(forceRestartIfNeeded: true)
        let add = Task { @MainActor in
            try await store.addAccount()
        }
        await factoryGate.waitUntilBlocked()
        let cancellation = Task { @MainActor in
            await store.cancelAuthentication()
        }
        await cancellationRequested.wait()
        await factoryGate.open()
        try await add.value
        await cancellation.value

        #expect(store.auth.selectedAccount?.accountKey == "active@example.com")
        #expect(store.auth.errorMessage == nil)
        #expect(store.auth.isAuthenticating == false)
        await store.stop()
    }

    @Test func liveStoreCancelsLoginAfterStartRequestBeforeHandleBinding() async throws {
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
        try await loginTransport.enqueueChatGPTLogin(
            loginID: "login-held",
            authenticationURL: testAuthenticationURL
        )
        try await loginTransport.enqueueChatGPTLoginCancellation(.canceled)
        let loginStartGate = CodexAppServerTestGate()
        await loginTransport.holdNextIgnoringCancellation(
            .accountLoginStart,
            gate: loginStartGate
        )
        var isolatedCodexHomeURL: URL?
        let externalURLOpener = FakeExternalURLOpener()
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
        let add = Task { @MainActor in
            try await store.addAccount()
        }
        await loginTransport.waitForRequest(.accountLoginStart)
        await loginStartGate.waitUntilBlocked()
        async let cancel: Void = store.cancelAuthentication()
        await loginStartGate.open()
        try await add.value
        await cancel

        let resolvedIsolatedCodexHomeURL = try #require(isolatedCodexHomeURL)
        #expect(externalURLOpener.openedURLs.isEmpty)
        #expect(await loginTransport.recordedRequests(for: .accountLoginCancel).count == 1)
        #expect(FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path) == false)
        await store.stop()
    }

    @Test func liveStoreKeepsPreBindCancellationWhenLoginStartFailsLate() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "active@example.com",
            accounts: ["active@example.com"]
        )
        let mainTransport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(
            on: mainTransport,
            email: "active@example.com"
        )
        let loginTransport = FakeCodexAppServerTransport()
        try await loginTransport.enqueueFailure(
            .response(code: -32603, message: "late login-start failure"),
            for: .accountLoginStart
        )
        let loginStartGate = CodexAppServerTestGate()
        await loginTransport.holdNextIgnoringCancellation(
            .accountLoginStart,
            gate: loginStartGate
        )
        let cancellationRequested = OneShotSignal()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            authenticationCancellationDidRequest: {
                await cancellationRequested.signal()
            },
            transportFactory: { codexHomeURL in
                codexHomeURL == mainCodexHomeURL ? mainTransport : loginTransport
            }
        )

        await store.start(forceRestartIfNeeded: true)
        let add = Task { @MainActor in
            try await store.addAccount()
        }
        await loginStartGate.waitUntilBlocked()
        let cancellation = Task { @MainActor in
            await store.cancelAuthentication()
        }
        await cancellationRequested.wait()
        await loginStartGate.open()
        try await add.value
        await cancellation.value

        #expect(store.auth.selectedAccount?.accountKey == "active@example.com")
        #expect(store.auth.errorMessage == nil)
        #expect(store.auth.isAuthenticating == false)
        #expect(await loginTransport.recordedRequests(for: .accountLoginCancel).isEmpty)
        await store.stop()
    }

    @Test func liveStoreKeepsCancellationWhenIsolatedAccountReadFailsAfterSDKSuccess() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "active@example.com",
            accounts: ["active@example.com"]
        )
        let mainTransport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(
            on: mainTransport,
            email: "active@example.com"
        )
        let loginTransport = FakeCodexAppServerTransport()
        try await loginTransport.enqueueChatGPTLogin(
            loginID: "login-read-failure",
            authenticationURL: testAuthenticationURL
        )
        try await loginTransport.enqueueFailure(
            .response(code: -32603, message: "late isolated account read failure"),
            for: .accountRead
        )
        let accountReadGate = CodexAppServerTestGate()
        await loginTransport.holdNextIgnoringCancellation(
            .accountRead,
            gate: accountReadGate
        )
        let cancellationRequested = OneShotSignal()
        var isolatedCodexHomeURL: URL?
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            authenticationCancellationDidRequest: {
                await cancellationRequested.signal()
            },
            transportFactory: { codexHomeURL in
                if codexHomeURL == mainCodexHomeURL {
                    return mainTransport
                }
                isolatedCodexHomeURL = codexHomeURL
                return loginTransport
            }
        )

        await store.start(forceRestartIfNeeded: true)
        try await store.addAccount()
        try await loginTransport.notificationEmitter.emitLoginCompleted(
            loginID: "login-read-failure",
            completion: .succeeded
        )
        try await loginTransport.notificationEmitter.emitAccountChanged(.init(
            authMode: .chatGPT,
            planType: .plus
        ))
        await accountReadGate.waitUntilBlocked()
        let cancellation = Task { @MainActor in
            await store.cancelAuthentication()
        }
        await cancellationRequested.wait()
        await accountReadGate.open()
        await cancellation.value

        #expect(store.auth.selectedAccount?.accountKey == "active@example.com")
        #expect(store.auth.persistedAccounts.map(\.accountKey) == ["active@example.com"])
        #expect(store.auth.errorMessage == nil)
        #expect(FileManager.default.fileExists(atPath: try #require(isolatedCodexHomeURL).path) == false)
        await store.stop()
    }

    @Test func liveStoreLetsIsolatedCancellationWinBeforeRegistryProductCommit() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let oldAccountKey = "active@example.com"
        let newAccountKey = "new@example.com"
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: oldAccountKey,
            accounts: [oldAccountKey]
        )
        let mainTransport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: mainTransport, email: oldAccountKey)
        let loginTransport = FakeCodexAppServerTransport()
        try await loginTransport.enqueueChatGPTLogin(
            loginID: "isolated-before-commit",
            authenticationURL: testAuthenticationURL
        )
        try await loginTransport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: newAccountKey,
                planType: .plus
            )),
            requiresOpenAIAuth: false
        )
        try await loginTransport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 25
        ))
        let accountReadGate = CodexAppServerTestGate()
        await loginTransport.holdNextIgnoringCancellation(.accountRead, gate: accountReadGate)
        let cancellationRequested = OneShotSignal()
        var isolatedCodexHomeURL: URL?
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            authenticationCancellationDidRequest: {
                await cancellationRequested.signal()
            },
            transportFactory: { codexHomeURL in
                if codexHomeURL == mainCodexHomeURL {
                    return mainTransport
                }
                isolatedCodexHomeURL = codexHomeURL
                return loginTransport
            }
        )

        await store.start(forceRestartIfNeeded: true)
        try await store.addAccount()
        let resolvedIsolatedCodexHomeURL = try #require(isolatedCodexHomeURL)
        try Data(#"{"tokens":{"id_token":"new@example.com"}}"#.utf8).write(
            to: resolvedIsolatedCodexHomeURL.appendingPathComponent("auth.json")
        )
        try await loginTransport.notificationEmitter.emitLoginCompleted(
            loginID: "isolated-before-commit",
            completion: .succeeded
        )
        try await loginTransport.notificationEmitter.emitAccountChanged(.init(
            authMode: .chatGPT,
            planType: .plus
        ))
        await accountReadGate.waitUntilBlocked()

        let cancellation = Task { @MainActor in
            await store.cancelAuthentication()
        }
        await cancellationRequested.wait()
        await accountReadGate.open()
        await cancellation.value

        #expect(try activeAccountKey(homeURL: homeURL) == oldAccountKey)
        #expect(store.auth.persistedAccounts.map(\.accountKey) == [oldAccountKey])
        #expect(store.auth.selectedAccount?.accountKey == oldAccountKey)
        #expect(store.auth.errorMessage == nil)
        #expect(FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path) == false)
        await store.stop()
    }

    @Test func liveStoreKeepsIsolatedSuccessWhenCancellationArrivesAfterRegistryProductCommit() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let oldAccountKey = "active@example.com"
        let newAccountKey = "new@example.com"
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: oldAccountKey,
            accounts: [oldAccountKey]
        )
        let mainTransport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: mainTransport, email: oldAccountKey)
        let loginTransport = FakeCodexAppServerTransport()
        try await loginTransport.enqueueChatGPTLogin(
            loginID: "isolated-after-commit",
            authenticationURL: testAuthenticationURL
        )
        try await loginTransport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: newAccountKey,
                planType: .plus
            )),
            requiresOpenAIAuth: false
        )
        try await loginTransport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 25
        ))
        let productCommitApplied = OneShotSignal()
        let productCommitReleaseGate = CodexAppServerTestGate()
        let cancellationRequested = OneShotSignal()
        var isolatedCodexHomeURL: URL?
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            authenticationCancellationDidRequest: {
                await cancellationRequested.signal()
            },
            authenticationProductCommitDidApply: {
                await productCommitApplied.signal()
                await productCommitReleaseGate.waitIgnoringCancellation()
            },
            transportFactory: { codexHomeURL in
                if codexHomeURL == mainCodexHomeURL {
                    return mainTransport
                }
                isolatedCodexHomeURL = codexHomeURL
                return loginTransport
            }
        )

        await store.start(forceRestartIfNeeded: true)
        try await store.addAccount()
        let resolvedIsolatedCodexHomeURL = try #require(isolatedCodexHomeURL)
        try Data(#"{"tokens":{"id_token":"new@example.com"}}"#.utf8).write(
            to: resolvedIsolatedCodexHomeURL.appendingPathComponent("auth.json")
        )
        try await loginTransport.notificationEmitter.emitLoginCompleted(
            loginID: "isolated-after-commit",
            completion: .succeeded
        )
        try await loginTransport.notificationEmitter.emitAccountChanged(.init(
            authMode: .chatGPT,
            planType: .plus
        ))
        await productCommitApplied.wait()

        let cancellation = Task { @MainActor in
            await store.cancelAuthentication()
        }
        await cancellationRequested.wait()
        await productCommitReleaseGate.open()
        await cancellation.value
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.auth.persistedAccounts.contains { $0.accountKey == newAccountKey }
                && store.auth.isAuthenticating == false
        })

        #expect(try activeAccountKey(homeURL: homeURL) == oldAccountKey)
        #expect(store.auth.persistedAccounts.map(\.accountKey).contains(newAccountKey))
        #expect(store.auth.selectedAccount?.accountKey == oldAccountKey)
        #expect(store.auth.errorMessage == nil)
        #expect(FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path) == false)
        await store.stop()
    }

    @Test func liveStoreKeepsPostProductCommitFailureWhenCancellationArrivesDuringFinalLoad() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let oldAccountKey = "active@example.com"
        let newAccountKey = "new@example.com"
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: oldAccountKey,
            accounts: [oldAccountKey]
        )
        let mainTransport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: mainTransport, email: oldAccountKey)
        let loginTransport = FakeCodexAppServerTransport()
        try await loginTransport.enqueueChatGPTLogin(
            loginID: "isolated-post-commit-failure",
            authenticationURL: testAuthenticationURL
        )
        try await loginTransport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: newAccountKey,
                planType: .plus
            )),
            requiresOpenAIAuth: false
        )
        try await loginTransport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 25
        ))
        let productCommitApplied = OneShotSignal()
        let productCommitReleaseGate = CodexAppServerTestGate()
        let cancellationRequested = OneShotSignal()
        var isolatedCodexHomeURL: URL?
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            authenticationCancellationDidRequest: {
                await cancellationRequested.signal()
            },
            authenticationProductCommitDidApply: {
                await productCommitApplied.signal()
                await productCommitReleaseGate.waitIgnoringCancellation()
            },
            transportFactory: { codexHomeURL in
                if codexHomeURL == mainCodexHomeURL {
                    return mainTransport
                }
                isolatedCodexHomeURL = codexHomeURL
                return loginTransport
            }
        )

        await store.start(forceRestartIfNeeded: true)
        try await store.addAccount()
        let resolvedIsolatedCodexHomeURL = try #require(isolatedCodexHomeURL)
        try Data(#"{"tokens":{"id_token":"new@example.com"}}"#.utf8).write(
            to: resolvedIsolatedCodexHomeURL.appendingPathComponent("auth.json")
        )
        try await loginTransport.notificationEmitter.emitLoginCompleted(
            loginID: "isolated-post-commit-failure",
            completion: .succeeded
        )
        try await loginTransport.notificationEmitter.emitAccountChanged(.init(
            authMode: .chatGPT,
            planType: .plus
        ))
        await productCommitApplied.wait()

        let cancellation = Task { @MainActor in
            await store.cancelAuthentication()
        }
        await cancellationRequested.wait()
        try Data("invalid registry".utf8).write(
            to: accountRegistryURL(homeURL: homeURL)
        )
        await productCommitReleaseGate.open()
        await cancellation.value

        #expect(store.auth.selectedAccount?.accountKey == oldAccountKey)
        #expect(store.auth.persistedAccounts.map(\.accountKey) == [oldAccountKey])
        #expect(store.auth.errorMessage?.contains("account registry") == true)
        #expect(store.auth.isAuthenticating == false)
        #expect(FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path) == false)
        #expect(await loginTransport.recordedRequests(for: .accountLoginCancel).isEmpty)
        await store.stop()
    }

    @Test func liveStoreUsesInjectedMonotonicDeadlineForLoginCancellationAcknowledgement() async throws {
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueChatGPTLogin(
            loginID: "login-deadline",
            authenticationURL: testAuthenticationURL
        )
        let replacementTransport = FakeCodexAppServerTransport()
        try await replacementTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await replacementTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await replacementTransport.enqueueModels(.init(models: []))
        var transports = [transport, replacementTransport]
        let deadlineClock = CodexAppServerTestDeadlineClock()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            deadlineClock: deadlineClock,
            transportFactory: { _ in transports.removeFirst() }
        )

        await store.start(forceRestartIfNeeded: true)
        try await store.addAccount()
        let cancel = Task { @MainActor in
            await store.cancelAuthentication()
        }
        await transport.waitForRequest(.accountLoginCancel)
        try await deadlineClock.waitForSleeperCount(1)
        deadlineClock.advance(by: .seconds(5))
        await cancel.value

        try #require(await waitUntil(timeout: .seconds(2)) {
            store.auth.isAuthenticating == false && store.serverState == .running
        })
        #expect(await transport.recordedRequests(for: .accountLoginCancel).count == 1)
        await store.stop()
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

        try #require(await waitUntil(timeout: .seconds(2)) {
            failedMessage(from: store.auth.phase) == "login completed before handle publication"
        })
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
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.auth.persistedAccounts.first { $0.accountKey == "new@example.com" }?.rateLimits.first?.usedPercent == 44
        })

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
        let newAccount = try CodexAppServerTestAccount(kind: .chatGPT(
            email: "new@example.com",
            planType: .plus
        ))
        try await transport.enqueueAccount(newAccount, requiresOpenAIAuth: false)
        try await transport.enqueueAccount(newAccount, requiresOpenAIAuth: false)
        try await transport.enqueueAccount(newAccount, requiresOpenAIAuth: false)
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
        await transport.waitForRequestCount(9)
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.auth.selectedAccount?.accountKey == "new@example.com"
                && store.auth.selectedAccount?.rateLimits.first?.usedPercent == 20
        })

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
            .accountRead,
            .accountRateLimitsRead,
            .accountRead,
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
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "active@example.com",
            accounts: ["active@example.com"]
        )
        let transport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(
            on: transport,
            email: "active@example.com",
            planType: .pro,
            usedPercent: 10
        )
        let activeAccount = try CodexAppServerTestAccount(kind: .chatGPT(
            email: "active@example.com",
            planType: .pro
        ))
        try await transport.enqueueAccount(activeAccount, requiresOpenAIAuth: false)
        try await transport.enqueueAccount(activeAccount, requiresOpenAIAuth: false)
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await transport.waitForNotificationStreamCount(1)
        await store.refreshAccountRateLimits(accountKey: "active@example.com")
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

    @Test func liveStoreDropsActiveRateRefreshAfterAccountGenerationQuiesces() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "first@example.com",
            accounts: ["first@example.com", "second@example.com"]
        )
        try writeSavedAccountAuth(homeURL: homeURL, accountKey: "second@example.com")
        let firstTransport = FakeCodexAppServerTransport()
        let firstAccount = try CodexAppServerTestAccount(kind: .chatGPT(
            email: "first@example.com",
            planType: .pro
        ))
        try await firstTransport.enqueueAccount(firstAccount, requiresOpenAIAuth: false)
        try await firstTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await firstTransport.enqueueModels(.init(models: []))
        try await firstTransport.enqueueAccount(firstAccount, requiresOpenAIAuth: false)
        try await firstTransport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 99
        ))
        try await firstTransport.enqueueAccount(firstAccount, requiresOpenAIAuth: false)
        let secondTransport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(
            on: secondTransport,
            email: "second@example.com",
            planType: .plus,
            usedPercent: 20
        )
        let rateReadGate = CodexAppServerTestGate()
        let oldGenerationQuiesced = OneShotSignal()
        var didPublishRuntime = false
        var transports = [firstTransport, secondTransport]
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            appServerLifecycleHandler: { container in
                if container != nil {
                    didPublishRuntime = true
                } else if didPublishRuntime {
                    Task { await oldGenerationQuiesced.signal() }
                }
            },
            transportFactory: { codexHomeURL in
                #expect(codexHomeURL == mainCodexHomeURL)
                return transports.removeFirst()
            }
        )

        await store.start(forceRestartIfNeeded: true)
        let firstAuthBeforeRefresh = try savedAccountAuth(
            homeURL: homeURL,
            accountKey: "first@example.com"
        )
        await firstTransport.holdNextIgnoringCancellation(
            .accountRateLimitsRead,
            gate: rateReadGate
        )
        let refresh = Task { @MainActor in
            await store.refreshAccountRateLimits(accountKey: "first@example.com")
        }
        await rateReadGate.waitUntilBlocked()
        let accountSwitch = Task { @MainActor in
            try await store.switchAccount(
                CodexReviewKit.CodexReviewAccount(email: "second@example.com")
            )
        }
        await oldGenerationQuiesced.wait()
        await rateReadGate.open()
        await refresh.value
        try await accountSwitch.value

        #expect(store.auth.selectedAccount?.accountKey == "second@example.com")
        #expect(try savedAccountAuth(
            homeURL: homeURL,
            accountKey: "first@example.com"
        ) == firstAuthBeforeRefresh)
        #expect(store.auth.persistedAccounts.first(where: {
            $0.accountKey == "first@example.com"
        })?.rateLimits.first?.usedPercent != 99)
        await store.stop()
    }

    @Test func liveStoreClosesAdmissionWhileRuntimeAuthenticationReconciles() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "first@example.com",
            accounts: ["first@example.com"]
        )
        let transport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: transport, email: "first@example.com")
        let secondAccount = try CodexAppServerTestAccount(kind: .chatGPT(
            email: "second@example.com",
            planType: .plus
        ))
        try await transport.enqueueAccount(secondAccount, requiresOpenAIAuth: false)
        try await transport.enqueueAccount(secondAccount, requiresOpenAIAuth: false)
        try await transport.enqueueAccount(secondAccount, requiresOpenAIAuth: false)
        try await transport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 20
        ))
        let accountReadGate = CodexAppServerTestGate()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await transport.holdNextIgnoringCancellation(.accountRead, gate: accountReadGate)
        try Data(#"{"tokens":{"id_token":"second@example.com"}}"#.utf8).write(
            to: mainCodexHomeURL.appendingPathComponent("auth.json")
        )
        let refresh = Task { @MainActor in
            await store.refreshAuthentication()
        }
        await accountReadGate.waitUntilBlocked()

        do {
            _ = try await store.beginReview(
                sessionID: "runtime-auth-reservation",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            Issue.record("Expected runtime authentication reconciliation to close review admission.")
        } catch {}
        do {
            try await store.reorderPersistedAccount(accountKey: "first@example.com", toIndex: 0)
            Issue.record("Expected runtime authentication reconciliation to close account admission.")
        } catch let failure as CodexReviewAuthenticationFailure {
            #expect(failure == .accountMutationBlockedByAuthentication)
        }

        await accountReadGate.open()
        await refresh.value

        #expect(store.serverState == .running)
        #expect(store.auth.selectedAccount?.accountKey == "second@example.com")
        #expect(FileManager.default.fileExists(
            atPath: accountReconciliationDebtURL(homeURL: homeURL).path
        ) == false)
        try await store.reorderPersistedAccount(accountKey: "first@example.com", toIndex: 0)
        await store.stop()
    }

    @Test func liveStoreDrainsAccountInvalidationAfterIsolatedLoginReleasesOwnership() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "first@example.com",
            accounts: ["first@example.com"]
        )
        let mainTransport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: mainTransport, email: "first@example.com")
        let secondAccount = try CodexAppServerTestAccount(kind: .chatGPT(
            email: "second@example.com",
            planType: .plus
        ))
        let loginTransport = FakeCodexAppServerTransport()
        try await loginTransport.enqueueChatGPTLogin(
            loginID: "isolated-pending-drain",
            authenticationURL: testAuthenticationURL
        )
        try await loginTransport.enqueueChatGPTLoginCancellation(.canceled)
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transportFactory: { codexHomeURL in
                codexHomeURL == mainCodexHomeURL ? mainTransport : loginTransport
            }
        )

        await store.start(forceRestartIfNeeded: true)
        try await store.addAccount()
        await loginTransport.waitForRequest(.accountLoginStart)
        try Data(#"{"tokens":{"id_token":"second@example.com"}}"#.utf8).write(
            to: mainCodexHomeURL.appendingPathComponent("auth.json")
        )
        try await mainTransport.notificationEmitter.emitAccountChanged(.init(
            authMode: .chatGPT,
            planType: .plus
        ))
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.backend.acceptsNewReviewOperations == false
        })
        try await mainTransport.enqueueAccount(secondAccount, requiresOpenAIAuth: false)
        try await mainTransport.enqueueAccount(secondAccount, requiresOpenAIAuth: false)
        try await mainTransport.enqueueAccount(secondAccount, requiresOpenAIAuth: false)
        try await mainTransport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 20
        ))

        do {
            _ = try await store.beginReview(
                sessionID: "isolated-pending-drain",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            Issue.record("Expected an accepted account invalidation to close review admission immediately.")
        } catch {}
        do {
            try await store.reorderPersistedAccount(accountKey: "first@example.com", toIndex: 0)
            Issue.record("Expected an accepted account invalidation to close account admission immediately.")
        } catch let failure as CodexReviewAuthenticationFailure {
            #expect(failure == .accountMutationBlockedByAuthentication)
        }

        await store.cancelAuthentication()

        #expect(store.serverState == .running)
        #expect(await mainTransport.recordedRequests(for: .accountRead).count >= 4)
        #expect(store.backend.acceptsNewReviewOperations)
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.auth.selectedAccount?.accountKey == "second@example.com"
        })
        #expect(await mainTransport.recordedRequests(for: .accountRead).count >= 2)
        await store.stop()
    }

    @Test func liveStoreRedrainsNewGenerationAfterSupersededDrainCompletes() async throws {
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "first@example.com",
            accounts: ["first@example.com"]
        )
        let oldTransport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: oldTransport, email: "first@example.com")
        let firstAccount = try CodexAppServerTestAccount(kind: .chatGPT(
            email: "first@example.com",
            planType: .pro
        ))
        try await oldTransport.enqueueAccount(firstAccount, requiresOpenAIAuth: false)
        try await oldTransport.enqueueAccount(firstAccount, requiresOpenAIAuth: false)
        try await oldTransport.enqueueAccount(firstAccount, requiresOpenAIAuth: false)
        let oldReadGate = CodexAppServerTestGate()

        let newTransport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: newTransport, email: "first@example.com")
        let secondAccount = try CodexAppServerTestAccount(kind: .chatGPT(
            email: "second@example.com",
            planType: .plus
        ))
        try await newTransport.enqueueAccount(secondAccount, requiresOpenAIAuth: false)
        try await newTransport.enqueueAccount(secondAccount, requiresOpenAIAuth: false)
        try await newTransport.enqueueAccount(secondAccount, requiresOpenAIAuth: false)
        try await newTransport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 30
        ))
        let oldActivationGate = CodexAppServerTestGate()
        let oldMCPHTTPServer = MCPHTTPServerProbe(
            endpoint: URL(string: "http://127.0.0.1:0/mcp")!,
            activationGate: oldActivationGate
        )
        let newActivationGate = CodexAppServerTestGate()
        let newMCPHTTPServer = MCPHTTPServerProbe(
            endpoint: URL(string: "http://127.0.0.1:0/mcp")!,
            activationGate: newActivationGate
        )
        var transports = [oldTransport, newTransport]
        var mcpHTTPServerCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            mcpHTTPServerFactory: { _, configuration, _ in
                defer { mcpHTTPServerCount += 1 }
                if mcpHTTPServerCount == 0 {
                    _ = configuration
                    return oldMCPHTTPServer
                }
                return newMCPHTTPServer
            },
            mcpHTTPServerBindChecker: { _ in },
            appServerCloser: { _ in },
            transportFactory: { _ in transports.removeFirst() }
        )

        let initialStart = Task { @MainActor in
            await store.start(forceRestartIfNeeded: true)
        }
        try #require(await waitUntil(timeout: .seconds(2)) {
            await oldMCPHTTPServer.snapshot().activateCount == 1
        })
        let oldAccountReadCount = await oldTransport.recordedRequests(for: .accountRead).count
        await oldTransport.holdNextIgnoringCancellation(.accountRead, gate: oldReadGate)
        try await oldTransport.notificationEmitter.emitAccountChanged(.init(
            authMode: .chatGPT,
            planType: .pro
        ))
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.backend.acceptsNewReviewOperations == false
        })
        await oldActivationGate.open()
        await initialStart.value
        try #require(await waitUntil(timeout: .seconds(2)) {
            await oldTransport.recordedRequests(for: .accountRead).count
                >= oldAccountReadCount + 1
        })

        await store.stop()
        let restart = Task { @MainActor in
            await store.start(forceRestartIfNeeded: true)
        }
        try #require(await waitUntil(timeout: .seconds(2)) {
            await newMCPHTTPServer.snapshot().activateCount == 1
        })
        try Data(#"{"tokens":{"id_token":"second@example.com"}}"#.utf8).write(
            to: codexHomeURL.appendingPathComponent("auth.json")
        )
        try await newTransport.notificationEmitter.emitAccountChanged(.init(
            authMode: .chatGPT,
            planType: .plus
        ))
        await newActivationGate.open()
        await restart.value

        #expect(store.auth.selectedAccount?.accountKey == "first@example.com")
        await oldReadGate.open()
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.auth.selectedAccount?.accountKey == "second@example.com"
        })

        #expect(store.serverState == .running)
        #expect(await newTransport.recordedRequests(for: .accountRead).count >= 4)
        await store.stop()
    }

    @Test func liveStoreFailsClosedWhenRuntimeAuthenticationRegistryCommitIsUnresolved() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "first@example.com",
            accounts: ["first@example.com"]
        )
        let transport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: transport, email: "first@example.com")
        try await transport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "second@example.com",
                planType: .plus
            )),
            requiresOpenAIAuth: false
        )
        let corruption = RegistryReplacementCorruptingProbe(
            registryURL: accountRegistryURL(homeURL: homeURL)
        )
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            registryDestinationDidReplace: corruption.corruptIfArmed,
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        try Data(#"{"tokens":{"id_token":"second@example.com"}}"#.utf8).write(
            to: mainCodexHomeURL.appendingPathComponent("auth.json")
        )
        corruption.arm()
        await store.refreshAuthentication()

        #expect(corruption.corruptionCount == 1)
        #expect(store.auth.selectedAccount?.accountKey == "first@example.com")
        #expect(store.auth.errorMessage?.contains("reconciliation remains pending") == true)
        #expect({
            if case .failed = store.serverState { return true }
            return false
        }())
        #expect(FileManager.default.fileExists(
            atPath: accountReconciliationDebtURL(homeURL: homeURL).path
        ))
        do {
            _ = try await store.beginReview(
                sessionID: "runtime-auth-sticky-failure",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            Issue.record("Expected unresolved runtime authentication reconciliation to keep review admission closed.")
        } catch {}
        await store.stop()
    }

    @Test func liveStoreDoesNotRecordStaleRuntimeAccountAfterAClaimedEffectFails() async throws {
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "first@example.com",
            accounts: ["first@example.com"]
        )
        let transport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: transport, email: "first@example.com")
        try await transport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "second@example.com",
                planType: .plus
            )),
            requiresOpenAIAuth: false
        )
        let replacement = BlockingRegistryReplacementCorruptingProbe(
            registryURL: accountRegistryURL(homeURL: homeURL)
        )
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            registryDestinationDidReplace: replacement.blockCorruptAndFailIfArmed,
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        try Data(#"{"tokens":{"id_token":"second@example.com"}}"#.utf8).write(
            to: codexHomeURL.appendingPathComponent("auth.json")
        )
        replacement.arm()
        let refresh = Task { @MainActor in
            await store.refreshAuthentication()
        }
        await replacement.waitUntilBlocked()
        try Data(#"{"tokens":{"id_token":"third@example.com"}}"#.utf8).write(
            to: codexHomeURL.appendingPathComponent("auth.json")
        )
        try await transport.notificationEmitter.emitAccountChanged(.init(
            authMode: .chatGPT,
            planType: .pro
        ))
        replacement.open()
        await refresh.value

        let debtData = try Data(contentsOf: accountReconciliationDebtURL(homeURL: homeURL))
        let debt = try #require(JSONSerialization.jsonObject(with: debtData) as? [String: Any])
        #expect(debt["expectation"] as? String == "reconcileCurrentRuntime")
        #expect({ if case .failed = store.serverState { return true }; return false }())
        await store.stop()
    }

    @Test func liveStoreFinalShutdownSupersedesRuntimeAuthenticationRead() async throws {
        let homeURL = try temporaryHome()
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "first@example.com",
            accounts: ["first@example.com"]
        )
        let transport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: transport, email: "first@example.com")
        try await transport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "second@example.com",
                planType: .plus
            )),
            requiresOpenAIAuth: false
        )
        let readGate = CodexAppServerTestGate()
        let stopCompletion = CompletionFlag()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            appServerCloser: { _ in },
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await transport.holdNextIgnoringCancellation(.accountRead, gate: readGate)
        let refresh = Task { @MainActor in
            await store.refreshAuthentication()
        }
        await readGate.waitUntilBlocked()
        let stop = Task { @MainActor in
            await store.stop()
            await stopCompletion.complete()
        }

        #expect(await waitUntil(timeout: .seconds(1)) {
            await stopCompletion.isCompleted()
        })
        #expect(store.serverState == .stopped)
        await readGate.open()
        await refresh.value
        await stop.value
        #expect(try activeAccountKey(homeURL: homeURL) == "first@example.com")
        #expect(FileManager.default.fileExists(
            atPath: accountReconciliationDebtURL(homeURL: homeURL).path
        ) == false)
    }

    @Test func liveStoreFinalShutdownWaitsForClaimedRuntimeAuthenticationEffect() async throws {
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "first@example.com",
            accounts: ["first@example.com"]
        )
        let transport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: transport, email: "first@example.com")
        try await transport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "second@example.com",
                planType: .plus
            )),
            requiresOpenAIAuth: false
        )
        let replacement = BlockingRegistryReplacementProbe()
        let stopCompletion = CompletionFlag()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            registryDestinationDidReplace: replacement.blockIfArmed,
            appServerCloser: { _ in },
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        try Data(#"{"tokens":{"id_token":"second@example.com"}}"#.utf8).write(
            to: codexHomeURL.appendingPathComponent("auth.json")
        )
        replacement.arm()
        let refresh = Task { @MainActor in
            await store.refreshAuthentication()
        }
        await replacement.waitUntilBlocked()
        let stop = Task { @MainActor in
            await store.stop()
            await stopCompletion.complete()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await stopCompletion.isCompleted() == false)

        replacement.open()
        await refresh.value
        await stop.value
        #expect(await stopCompletion.isCompleted())
        #expect(try activeAccountKey(homeURL: homeURL) == "second@example.com")
        #expect(FileManager.default.fileExists(
            atPath: accountReconciliationDebtURL(homeURL: homeURL).path
        ) == false)
    }

    @Test func liveStoreFailsClosedWhenCausalRuntimeAuthRefreshCannotRefetch() async throws {
        let homeURL = try temporaryHome()
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "first@example.com",
            accounts: ["first@example.com"]
        )
        let transport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: transport, email: "first@example.com")
        try await transport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "first@example.com",
                planType: .pro
            )),
            requiresOpenAIAuth: false
        )
        try await transport.enqueueFailure(
            .response(code: -32_000, message: "authoritative auth read failed"),
            for: .accountRead
        )
        let readGate = CodexAppServerTestGate()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await transport.holdNextIgnoringCancellation(.accountRead, gate: readGate)
        let refresh = Task { @MainActor in
            await store.refreshAuthentication()
        }
        await readGate.waitUntilBlocked()
        try await transport.notificationEmitter.emitAccountChanged(.init(
            authMode: .chatGPT,
            planType: .pro
        ))
        await readGate.open()
        await refresh.value

        #expect({
            if case .failed = store.serverState { return true }
            return false
        }())
        #expect(store.auth.errorMessage?.contains("authoritative auth read failed") == true)
        #expect(FileManager.default.fileExists(
            atPath: accountReconciliationDebtURL(homeURL: homeURL).path
        ) == false)
        await store.stop()
    }

    @Test func liveStoreStopsOnceWhenConnectionFailsDuringRuntimeAuthRead() async throws {
        let homeURL = try temporaryHome()
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "first@example.com",
            accounts: ["first@example.com"]
        )
        let transport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: transport, email: "first@example.com")
        try await transport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "second@example.com",
                planType: .plus
            )),
            requiresOpenAIAuth: false
        )
        let readGate = CodexAppServerTestGate()
        var closeCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            appServerCloser: { _ in closeCount += 1 },
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await transport.holdNextIgnoringCancellation(.accountRead, gate: readGate)
        let refresh = Task { @MainActor in
            await store.refreshAuthentication()
        }
        await readGate.waitUntilBlocked()
        await transport.failConnection(.closed)
        try #require(await waitUntil(timeout: .seconds(1)) {
            closeCount == 1
        })
        #expect({
            if case .failed = store.serverState { return true }
            return false
        }())

        await readGate.open()
        await refresh.value
        #expect(closeCount == 1)
        #expect(store.auth.selectedAccount?.accountKey == "first@example.com")
    }

    @Test func liveStoreRefetchesStagingAuthAfterSubscribedInvalidation() async throws {
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "first@example.com",
            accounts: ["first@example.com"]
        )
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "first@example.com",
                planType: .pro
            )),
            requiresOpenAIAuth: false
        )
        try await transport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "second@example.com",
                planType: .plus
            )),
            requiresOpenAIAuth: false
        )
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        let readGate = CodexAppServerTestGate()
        await transport.holdNextIgnoringCancellation(.accountRead, gate: readGate)
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transport: transport
        )

        let start = Task { @MainActor in
            await store.start(forceRestartIfNeeded: true)
        }
        await readGate.waitUntilBlocked()
        try Data(#"{"tokens":{"id_token":"second@example.com"}}"#.utf8).write(
            to: codexHomeURL.appendingPathComponent("auth.json")
        )
        try await transport.notificationEmitter.emitAccountChanged(.init(
            authMode: .chatGPT,
            planType: .plus
        ))
        await readGate.open()
        await start.value

        #expect(store.serverState == .running)
        #expect(store.auth.selectedAccount?.accountKey == "second@example.com")
        #expect(await transport.recordedRequests(for: .accountRead).count == 2)
        await store.stop()
    }

    @Test func liveStoreDropsActiveRateLimitsWhenBackendAccountChanges() async throws {
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "first@example.com",
            accounts: ["first@example.com"]
        )
        let transport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(on: transport, email: "first@example.com")
        try await transport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "first@example.com",
                planType: .pro
            )),
            requiresOpenAIAuth: false
        )
        try await transport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "second@example.com",
                planType: .plus
            )),
            requiresOpenAIAuth: false
        )
        let rateGate = CodexAppServerTestGate()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        let savedAuthBefore = try savedAccountAuth(
            homeURL: homeURL,
            accountKey: "first@example.com"
        )
        await transport.holdNextIgnoringCancellation(.accountRateLimitsRead, gate: rateGate)
        let refresh = Task { @MainActor in
            await store.refreshAccountRateLimits(accountKey: "first@example.com")
        }
        await rateGate.waitUntilBlocked()
        try Data(#"{"tokens":{"id_token":"second@example.com"}}"#.utf8).write(
            to: codexHomeURL.appendingPathComponent("auth.json")
        )
        await rateGate.open()
        await refresh.value

        #expect(store.auth.selectedAccount?.accountKey == "first@example.com")
        #expect(store.auth.selectedAccount?.rateLimits.isEmpty == true)
        #expect(try savedAccountAuth(
            homeURL: homeURL,
            accountKey: "first@example.com"
        ) == savedAuthBefore)
        await store.stop()
    }

    @Test func liveStoreKeepsPrimaryLoginAdmissionUntilStablePublication() async throws {
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueChatGPTLogin(
            loginID: "primary-admission",
            authenticationURL: testAuthenticationURL
        )
        try await transport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "second@example.com",
                planType: .plus
            )),
            requiresOpenAIAuth: false
        )
        let finalAccount = try CodexAppServerTestAccount(kind: .chatGPT(
            email: "third@example.com",
            planType: .pro
        ))
        try await transport.enqueueAccount(finalAccount, requiresOpenAIAuth: false)
        try await transport.enqueueAccount(finalAccount, requiresOpenAIAuth: false)
        try await transport.enqueueAccount(finalAccount, requiresOpenAIAuth: false)
        try await transport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 15
        ))
        let replacement = BlockingRegistryReplacementProbe()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            registryDestinationDidReplace: replacement.blockIfArmed,
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        try await store.addAccount()
        await transport.waitForRequest(.accountLoginStart)
        try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
        try Data(#"{"tokens":{"id_token":"second@example.com"}}"#.utf8).write(
            to: codexHomeURL.appendingPathComponent("auth.json")
        )
        replacement.arm()
        try await transport.notificationEmitter.emitLoginCompleted(
            loginID: "primary-admission",
            completion: .succeeded
        )
        try await transport.notificationEmitter.emitAccountChanged(.init(
            authMode: .chatGPT,
            planType: .plus
        ))
        await replacement.waitUntilBlocked()
        let accountReadCount = await transport.recordedRequests(for: .accountRead).count
        await store.refreshAuthentication()
        #expect(await transport.recordedRequests(for: .accountRead).count == accountReadCount)
        do {
            _ = try await store.beginReview(
                sessionID: "primary-login-admission",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            Issue.record("Expected primary login ownership to reject review admission.")
        } catch {}

        try Data(#"{"tokens":{"id_token":"third@example.com"}}"#.utf8).write(
            to: codexHomeURL.appendingPathComponent("auth.json")
        )
        try await transport.notificationEmitter.emitAccountChanged(.init(
            authMode: .chatGPT,
            planType: .pro
        ))
        replacement.open()
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.auth.selectedAccount?.accountKey == "third@example.com"
        })

        #expect(try activeAccountKey(homeURL: homeURL) == "third@example.com")
        #expect(FileManager.default.fileExists(
            atPath: accountReconciliationDebtURL(homeURL: homeURL).path
        ) == false)
        await store.stop()
    }

    @Test func liveStoreFailsPrimaryLoginClosedWithoutRecordingAnInvalidatedAccount() async throws {
        let homeURL = try temporaryHome()
        let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(homeURL: homeURL, activeAccountKey: nil, accounts: [])
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueChatGPTLogin(
            loginID: "primary-invalidated-commit",
            authenticationURL: testAuthenticationURL
        )
        try await transport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "second@example.com",
                planType: .plus
            )),
            requiresOpenAIAuth: false
        )
        let replacement = BlockingRegistryReplacementCorruptingProbe(
            registryURL: accountRegistryURL(homeURL: homeURL)
        )
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            registryDestinationDidReplace: replacement.blockCorruptAndFailIfArmed,
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        try await store.addAccount()
        await transport.waitForRequest(.accountLoginStart)
        try Data(#"{"tokens":{"id_token":"second@example.com"}}"#.utf8).write(
            to: codexHomeURL.appendingPathComponent("auth.json")
        )
        replacement.arm()
        try await transport.notificationEmitter.emitLoginCompleted(
            loginID: "primary-invalidated-commit",
            completion: .succeeded
        )
        try await transport.notificationEmitter.emitAccountChanged(.init(
            authMode: .chatGPT,
            planType: .plus
        ))
        try #require(await waitUntil(timeout: .seconds(2)) {
            replacement.hasBlocked
        })
        try Data(#"{"tokens":{"id_token":"third@example.com"}}"#.utf8).write(
            to: codexHomeURL.appendingPathComponent("auth.json")
        )
        try await transport.notificationEmitter.emitAccountChanged(.init(
            authMode: .chatGPT,
            planType: .pro
        ))
        replacement.open()

        try #require(await waitUntil(timeout: .seconds(2)) {
            if case .failed = store.serverState { return true }
            return false
        })
        let debtData = try Data(contentsOf: accountReconciliationDebtURL(homeURL: homeURL))
        let debt = try #require(JSONSerialization.jsonObject(with: debtData) as? [String: Any])
        #expect(debt["expectation"] as? String == "reconcileCurrentRuntime")
        do {
            _ = try await store.beginReview(
                sessionID: "primary-invalidated-commit",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            Issue.record("Expected unresolved primary login reconciliation to stay fail-closed.")
        } catch {}
        await store.stop()
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
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.reviewRuns.first?.core.attempt?.turnID.rawValue == "turn-first"
        })

        try await store.switchAccount(CodexReviewKit.CodexReviewAccount(email: "second@example.com"))
        let result = try await reviewRead
        await secondTransport.waitForRequestCount(2)
        await firstTransport.waitForRequestCount(7)

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
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.reviewRuns.first?.core.attempt?.turnID.rawValue == "turn-active"
        })

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

    @Test func liveStoreDoesNotPublishNoopSignOutAfterFinalShutdownRequest() async throws {
        let homeURL = try temporaryHome()
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        let loadGate = ArmableAsyncHookGate()
        let finalShutdownRequested = OneShotSignal()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            accountRegistryLoadDidBegin: {
                await loadGate.waitIfArmed()
            },
            finalShutdownDidRequest: {
                await finalShutdownRequested.signal()
            },
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        store.auth.updatePhase(.failed(.runtime(message: "preserved failure")))
        await loadGate.arm()
        let signOut = Task { @MainActor in
            try await store.signOutActiveAccount()
        }
        await loadGate.waitUntilBlocked()
        let finalStop = Task { @MainActor in
            await store.stop()
        }
        await finalShutdownRequested.wait()

        await loadGate.open()
        try await signOut.value
        await finalStop.value

        #expect(store.serverState == .stopped)
        #expect(store.auth.errorMessage == "preserved failure")
        #expect(store.auth.selectedAccount == nil)
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
        let recoveryTransport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(
            on: recoveryTransport,
            email: "first@example.com"
        )
        var transports = [firstTransport, recoveryTransport]
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transportFactory: { _ in transports.removeFirst() }
        )

        await store.start(forceRestartIfNeeded: true)
        await #expect(throws: (any Error).self) {
            try await store.switchAccount(CodexReviewKit.CodexReviewAccount(email: "second@example.com"))
        }

        #expect(store.auth.selectedAccount?.accountKey == "first@example.com")
        #expect(try activeAccountKey(homeURL: homeURL) == "first@example.com")
        #expect(try Data(contentsOf: mainCodexHomeURL.appendingPathComponent("auth.json")) == originalAuth)
        await store.stop()
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
        let workerClock = ContinuousClock()
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
            networkRecoveryPolicy: .init(
                clock: .init(
                    now: { workerClock.now },
                    sleep: { _ in }
                )
            ),
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
        var observedLifecycleStates: [Bool] = []
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            appServerLifecycleHandler: { container in
                observedLifecycleStates.append(container != nil)
            },
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await transport.waitForNotificationStreamCount(1)
        await transport.failConnection(.closed)
        try #require(await waitUntil(timeout: .seconds(2)) {
            if case .failed = store.serverState {
                return true
            }
            return false
        })

        guard case .failed(let message) = store.serverState else {
            Issue.record("Expected failed server state.")
            return
        }
        #expect(message.contains("The Codex app-server transport is closed."))
        #expect(store.serverURL == nil)
        try #require(await waitUntil(timeout: .seconds(2)) {
            observedLifecycleStates == [true, false]
        })
        #expect(observedLifecycleStates == [true, false])
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

    @Test func liveStoreRetainsPreparedRestartOwnershipWhenConnectionTerminates() async throws {
        let homeURL = try temporaryHome()
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let workerClock = ContinuousClock()
        let transport = FakeCodexAppServerTransport()
        try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await transport.enqueueModels(.init(models: []))
        try await transport.enqueueThreadStart(threadID: "thread-1", model: "gpt-5")
        try await transport.enqueueReviewStart(turnID: "turn-1", reviewThreadID: "thread-1")
        try await transport.enqueueThreadResume(makeHostStoredThread(id: "thread-1"))
        try await transport.enqueueSuccess(for: .turnInterrupt)
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(
                clock: .init(
                    now: { workerClock.now },
                    sleep: { _ in }
                )
            ),
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

        networkMonitor.yield(.init(status: .unsatisfied))
        await transport.waitForRequest(.turnInterrupt)
        try await transport.notificationEmitter.emitTurnCompleted(
            threadID: "thread-1",
            turn: try CodexAppServerTestTurn(
                snapshot: .init(id: "turn-1", state: .interrupted),
                items: []
            )
        )
        await transport.failConnection(.closed)

        try #require(await waitUntil(timeout: .seconds(2)) {
            if case .failed = store.serverState {
                return true
            }
            return false
        })
        let result = try await reviewRead.value
        let journal = try await store.reviewThreadRetentionRegistry.snapshotForTesting()
        let retained = try #require(journal.entries.first)

        #expect(result.core.isTerminal)
        #expect(journal.entries.count == 1)
        #expect(retained.attempts.count == 1)
        #expect(retained.attempts[0].turnID.rawValue == "turn-1")
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
        try #require(await waitUntil(timeout: .seconds(2)) {
            if case .failed = store.serverState {
                return true
            }
            return false
        })
        try #require(await waitUntil(timeout: .seconds(2)) {
            FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path) == false
        })
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
        let mcpStopGate = CodexAppServerTestGate()
        let firstMCPServer = MCPHTTPServerProbe(
            endpoint: URL(string: "http://127.0.0.1:9417/mcp")!,
            stopGate: mcpStopGate
        )
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
        try await firstTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        await firstTransport.holdNext(.accountLogout, gate: logoutGate)
        let secondTransport = FakeCodexAppServerTransport()
        try await secondTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await secondTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await secondTransport.enqueueModels(.init(models: []))
        var transports = [firstTransport, secondTransport]
        var mcpFactoryCallCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            mcpHTTPServerFactory: { _, configuration, _ in
                mcpFactoryCallCount += 1
                if mcpFactoryCallCount == 1 {
                    return firstMCPServer
                }
                return NoopMCPHTTPServer(endpoint: configuration.url())
            },
            mcpHTTPServerBindChecker: { _ in },
            transportFactory: { _ in transports.removeFirst() }
        )
        await store.start(forceRestartIfNeeded: true)
        try await firstTransport.notificationEmitter.emitRateLimitsUpdated(.init(snapshot: try .init(
            limitID: "codex",
            limitName: nil,
            primary: .init(
                usedPercent: 10,
                windowDurationMinutes: 300,
                resetsAtUnixSeconds: nil
            ),
            secondary: nil,
            credits: nil,
            individualLimit: nil,
            planType: nil,
            reachedType: nil
        )))
        try #require(await waitUntil(timeout: .seconds(1)) {
            store.auth.selectedAccount?.rateLimits.first?.usedPercent == 10
        })

        let removal = Task {
            try await store.removeAccount(accountKey: "active@example.com")
        }
        await mcpStopGate.waitUntilBlocked()
        #expect(await firstMCPServer.snapshot().stopCount == 1)
        #expect(
            FileManager.default.fileExists(
                atPath: accountMutationJournalURL(homeURL: homeURL).path
            ) == false
        )
        #expect(await firstTransport.recordedRequests(for: .accountLogout).isEmpty)
        await mcpStopGate.open()
        await firstTransport.waitForRequestCount(5)
        let journalData = try Data(contentsOf: accountMutationJournalURL(homeURL: homeURL))
        let journal = try #require(JSONSerialization.jsonObject(with: journalData) as? [String: Any])
        #expect(journal["phase"] as? String == "prepared")
        #expect(journal["mayApplyIrreversibleLogout"] as? Bool == true)
        let reviewRunCountBeforeRejectedAdmission = store.reviewRuns.count
        do {
            _ = try await store.beginReview(
                sessionID: "transition-rejected-session",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            Issue.record("Expected account-transition admission to reject a new review before run publication.")
        } catch {
            #expect(error.localizedDescription.contains("changing accounts or stopping"))
        }
        #expect(store.reviewRuns.count == reviewRunCountBeforeRejectedAdmission)
        let selectedAccountBeforeDroppedRefresh = store.auth.selectedAccount?.accountKey
        let transitionedAccountProjection = try #require(store.auth.selectedAccount)
        await store.refreshAuthentication()
        #expect(store.auth.selectedAccount?.accountKey == selectedAccountBeforeDroppedRefresh)
        #expect(store.auth.errorMessage == nil)
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
        #expect(
            try Data(contentsOf: accountMutationJournalURL(homeURL: homeURL))
                == journalData
        )
        try await firstTransport.notificationEmitter.emitAccountChanged(.init(
            authMode: .chatGPT,
            planType: .pro
        ))

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

        #expect(transitionedAccountProjection.rateLimits.first?.usedPercent == 10)
        let firstRuntimeAccountReadCount = await firstTransport.recordedRequests(for: .accountRead).count
        #expect(firstRuntimeAccountReadCount == 2)
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
        let replacementTransport = FakeCodexAppServerTransport()
        try await replacementTransport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: "active@example.com",
                planType: .pro
            )),
            requiresOpenAIAuth: false
        )
        try await replacementTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await replacementTransport.enqueueModels(.init(models: []))
        var transports = [transport, replacementTransport]
        var lifecycleStates: [Bool] = []
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            appServerLifecycleHandler: { container in
                lifecycleStates.append(container != nil)
            },
            transportFactory: { _ in transports.removeFirst() }
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
        #expect(lifecycleStates == [true, false, true])
        await store.stop()
    }

    @Test func liveStoreRejectsAddAccountBeforeCreatingIsolatedRuntimeWhenMainRuntimeIsUnavailable() async throws {
        let homeURL = try temporaryHome()
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "active@example.com",
            accounts: ["active@example.com"]
        )
        var runtimeFactoryCallCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transportFactory: { _ in
                runtimeFactoryCallCount += 1
                return FakeCodexAppServerTransport()
            }
        )

        do {
            try await store.addAccount()
            Issue.record("Expected unavailable main runtime to propagate to the add-account command.")
        } catch {
            #expect(error.localizedDescription == "The review runtime is changing accounts or stopping.")
        }

        #expect(runtimeFactoryCallCount == 0)
        #expect(store.auth.selectedAccount?.accountKey == "active@example.com")
        #expect(store.auth.errorMessage == nil)
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
        try #require(await waitUntil(timeout: .seconds(2)) {
            failedMessage(from: store.auth.phase) == "login completion failed"
        })
        try #require(await waitUntil(timeout: .seconds(2)) {
            FileManager.default.fileExists(atPath: resolvedIsolatedCodexHomeURL.path) == false
        })
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
        try writeRegistryRecords(
            homeURL: homeURL,
            activeAccountKey: nil,
            records: [
                ["accountKey": dotAccount.accountKey, "email": dotAccount.email],
                ["accountKey": dotDotAccount.accountKey, "email": dotDotAccount.email],
            ]
        )
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            transport: FakeCodexAppServerTransport()
        )

        try await store.removeAccount(accountKey: dotAccount.accountKey)
        try await store.removeAccount(accountKey: dotDotAccount.accountKey)

        #expect(FileManager.default.fileExists(atPath: codexHomeURL.path))
        #expect(FileManager.default.fileExists(atPath: accountsURL.path))
        #expect(FileManager.default.fileExists(atPath: sentinelURL.path))
        #expect(FileManager.default.fileExists(atPath: dotDirectoryURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: dotDotDirectoryURL.path) == false)
    }
}

@MainActor
private func exerciseUnknownPrimaryCancellation(
    previousAccountKey: String?,
    observedAccountKey: String?,
    expectedActiveAccountKey: String?
) async throws {
    let homeURL = try temporaryHome()
    let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
    if let previousAccountKey {
        let includesSwitchProbe = observedAccountKey == previousAccountKey
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: previousAccountKey,
            accounts: includesSwitchProbe
                ? [previousAccountKey, "other@example.com"]
                : [previousAccountKey]
        )
        if includesSwitchProbe {
            try writeSavedAccountAuth(
                homeURL: homeURL,
                accountKey: "other@example.com"
            )
        }
    }

    let initialTransport = FakeCodexAppServerTransport()
    if let previousAccountKey {
        try await initialTransport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: previousAccountKey,
                planType: .pro
            )),
            requiresOpenAIAuth: false
        )
    } else {
        try await initialTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
    }
    try await initialTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
    try await initialTransport.enqueueModels(.init(models: []))
    if previousAccountKey != nil {
        try await initialTransport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 10
        ))
    }
    try await initialTransport.enqueueChatGPTLogin(
        loginID: "unknown-primary-cancel",
        authenticationURL: testAuthenticationURL
    )
    try await initialTransport.enqueueFailure(
        .response(code: -32_000, message: "cancel response lost"),
        for: .accountLoginCancel
    )

    let replacementTransport = FakeCodexAppServerTransport()
    if let observedAccountKey {
        try await replacementTransport.enqueueAccount(
            try CodexAppServerTestAccount(kind: .chatGPT(
                email: observedAccountKey,
                planType: .plus
            )),
            requiresOpenAIAuth: false
        )
    } else {
        try await replacementTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
    }
    try await replacementTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
    try await replacementTransport.enqueueModels(.init(models: []))
    if observedAccountKey != nil {
        try await replacementTransport.enqueueRateLimits(try makeHostRateLimits(
            planType: nil,
            windowDurationMinutes: 300,
            usedPercent: 20
        ))
    }
    var transports = [initialTransport, replacementTransport]
    if observedAccountKey == previousAccountKey,
       let previousAccountKey {
        let switchAwayTransport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(
            on: switchAwayTransport,
            email: "other@example.com",
            planType: .plus,
            usedPercent: 25
        )
        let switchBackTransport = FakeCodexAppServerTransport()
        try await enqueueActiveAccountBootstrap(
            on: switchBackTransport,
            email: previousAccountKey,
            planType: .pro,
            usedPercent: 30
        )
        transports.append(switchAwayTransport)
        transports.append(switchBackTransport)
    }
    let store = CodexReviewStore.makeLiveStoreForTesting(
        environment: ["HOME": homeURL.path],
        transportFactory: { codexHomeURL in
            #expect(codexHomeURL == mainCodexHomeURL)
            return transports.removeFirst()
        }
    )

    await store.start(forceRestartIfNeeded: true)
    if previousAccountKey == nil {
        try await store.addAccount()
    } else {
        try await store.signIn()
    }
    await initialTransport.waitForRequest(.accountLoginStart)
    let replacementAuthData = observedAccountKey.map { observedAccountKey in
        Data(#"{"tokens":{"id_token":"\#(observedAccountKey)-rotated"}}"#.utf8)
    }
    if let replacementAuthData {
        try replacementAuthData.write(
            to: mainCodexHomeURL.appendingPathComponent("auth.json")
        )
    }

    await store.cancelAuthentication()

    #expect(store.serverState == .running)
    #expect(store.auth.selectedAccount?.accountKey == expectedActiveAccountKey)
    let persistedActiveAccountKey = FileManager.default.fileExists(
        atPath: accountRegistryURL(homeURL: homeURL).path
    ) ? try activeAccountKey(homeURL: homeURL) : nil
    #expect(persistedActiveAccountKey == expectedActiveAccountKey)
    #expect(FileManager.default.fileExists(
        atPath: accountReconciliationDebtURL(homeURL: homeURL).path
    ) == false)
    if let mutationProbeAccountKey = expectedActiveAccountKey ?? previousAccountKey {
        try await store.reorderPersistedAccount(
            accountKey: mutationProbeAccountKey,
            toIndex: 0
        )
    }
    if observedAccountKey == previousAccountKey,
       let previousAccountKey,
       let replacementAuthData {
        #expect(try savedAccountAuth(
            homeURL: homeURL,
            accountKey: previousAccountKey
        ) == replacementAuthData)
        try await store.switchAccount(
            CodexReviewKit.CodexReviewAccount(email: "other@example.com")
        )
        try await store.switchAccount(
            CodexReviewKit.CodexReviewAccount(email: previousAccountKey)
        )
        #expect(try Data(
            contentsOf: mainCodexHomeURL.appendingPathComponent("auth.json")
        ) == replacementAuthData)
    }
    #expect(transports.isEmpty)
    await store.stop()
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

private func enqueueActiveAccountBootstrap(
    on transport: FakeCodexAppServerTransport,
    email: String,
    planType: CodexAppServerTestPlanType = .pro,
    usedPercent: Int32 = 10
) async throws {
    let account = try CodexAppServerTestAccount(kind: .chatGPT(
        email: email,
        planType: planType
    ))
    try await transport.enqueueAccount(account, requiresOpenAIAuth: false)
    try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
    try await transport.enqueueModels(.init(models: []))
    try await transport.enqueueRateLimits(try makeHostRateLimits(
        planType: nil,
        windowDurationMinutes: 300,
        usedPercent: usedPercent
    ))
}

private func enqueueAPIKeyAccountBootstrap(
    on transport: FakeCodexAppServerTransport
) async throws {
    try await transport.enqueueAccount(
        try CodexAppServerTestAccount(kind: .apiKey),
        requiresOpenAIAuth: false
    )
    try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
    try await transport.enqueueModels(.init(models: []))
}

private func writeAPIKeyAuth(_ data: Data, to codexHomeURL: URL) throws {
    try FileManager.default.createDirectory(
        at: codexHomeURL,
        withIntermediateDirectories: true
    )
    let authURL = codexHomeURL.appendingPathComponent("auth.json")
    try data.write(to: authURL, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: authURL.path
    )
}

@MainActor
private func assertAPIKeyLoginReconciliationDebt(
    observedAccount: CodexAppServerTestAccount?
) async throws {
    let homeURL = try temporaryHome()
    let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
    let transport = FakeCodexAppServerTransport()
    try await transport.enqueueAccount(nil, requiresOpenAIAuth: false)
    try await transport.enqueueConfiguration(try makeHostConfigurationReadResult())
    try await transport.enqueueModels(.init(models: []))
    try await transport.enqueueAPIKeyLogin()
    try await transport.enqueueAccount(observedAccount, requiresOpenAIAuth: false)
    let store = CodexReviewStore.makeLiveStoreForTesting(
        environment: ["HOME": homeURL.path],
        transport: transport
    )
    await store.start(forceRestartIfNeeded: true)
    let sentinel = "test-secret-invalid-api-key-observation"
    try writeAPIKeyAuth(
        Data("{\"OPENAI_API_KEY\":\"\(sentinel)\"}".utf8),
        to: codexHomeURL
    )

    try await store.signIn(using: .apiKey(try CodexReviewAPIKey(validating: sentinel)))

    let debtURL = accountReconciliationDebtURL(homeURL: homeURL)
    let debtData = try Data(contentsOf: debtURL)
    let debtDescription = try #require(String(data: debtData, encoding: .utf8))
    #expect(debtDescription.contains("observedAccount"))
    #expect(debtDescription.contains("api-key"))
    #expect(debtDescription.contains("apiKey"))
    #expect(debtDescription.contains(sentinel) == false)
    #expect((store.auth.errorMessage ?? "").contains(sentinel) == false)
    #expect(store.auth.selectedAccount == nil)
    await store.stop()
}

@MainActor
private func assertUnknownAPIKeyLoginOutcome(committed: Bool) async throws {
    let homeURL = try temporaryHome()
    let codexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
    let initialTransport = FakeCodexAppServerTransport()
    try await initialTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
    try await initialTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
    try await initialTransport.enqueueModels(.init(models: []))
    try await initialTransport.enqueueChatGPTLogin(
        loginID: "unexpected-api-key-response",
        authenticationURL: testAuthenticationURL
    )
    let reconciliationTransport = FakeCodexAppServerTransport()
    if committed {
        try await enqueueAPIKeyAccountBootstrap(on: reconciliationTransport)
    } else {
        try await reconciliationTransport.enqueueAccount(nil, requiresOpenAIAuth: false)
        try await reconciliationTransport.enqueueConfiguration(try makeHostConfigurationReadResult())
        try await reconciliationTransport.enqueueModels(.init(models: []))
    }
    var transports = [initialTransport, reconciliationTransport]
    let externalURLOpener = FakeExternalURLOpener()
    let store = CodexReviewStore.makeLiveStoreForTesting(
        environment: ["HOME": homeURL.path],
        externalURLOpener: externalURLOpener.open,
        transportFactory: { runtimeHomeURL in
            #expect(runtimeHomeURL == codexHomeURL)
            return transports.removeFirst()
        }
    )
    await store.start(forceRestartIfNeeded: true)
    let sentinel = "test-secret-unknown-api-key-outcome"
    try writeAPIKeyAuth(
        Data("{\"OPENAI_API_KEY\":\"\(sentinel)\"}".utf8),
        to: codexHomeURL
    )

    try await store.signIn(using: .apiKey(try CodexReviewAPIKey(validating: sentinel)))

    #expect(externalURLOpener.openedURLs.isEmpty)
    #expect(transports.isEmpty)
    #expect(store.auth.selectedAccount?.accountKey == (committed ? "api-key" : nil))
    let persistedActiveAccountKey = FileManager.default.fileExists(
        atPath: accountRegistryURL(homeURL: homeURL).path
    ) ? try activeAccountKey(homeURL: homeURL) : nil
    #expect(persistedActiveAccountKey == (committed ? "api-key" : nil))
    #expect(FileManager.default.fileExists(
        atPath: accountReconciliationDebtURL(homeURL: homeURL).path
    ) == false)
    #expect((store.auth.errorMessage ?? "").contains(sentinel) == false)
    await store.stop()
}

private func makeHostStoredThread(
    id: CodexThreadID,
    model: String = "gpt-5",
    turns: [CodexAppServerTestTurn] = []
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
            turns: turns.map(\.snapshot)
        ),
        turns: turns,
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

    func open(_ url: URL) throws {
        openedURLs.append(url)
        if let failure {
            throw failure
        }
    }
}

private actor OneShotSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard isSignaled == false else {
            return
        }
        isSignaled = true
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        guard isSignaled == false else {
            return
        }
        await withCheckedContinuation { continuation in
            if isSignaled {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func snapshot() -> Bool {
        isSignaled
    }
}

private actor ArmableAsyncHookGate {
    private var armed = false
    private let gate = CodexAppServerTestGate()

    func arm() {
        armed = true
    }

    func waitIfArmed() async {
        guard armed else { return }
        await gate.waitIgnoringCancellation()
    }

    func waitUntilBlocked() async {
        await gate.waitUntilBlocked()
    }

    func open() async {
        await gate.open()
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
    try Data(contentsOf: immutableAccountAuthURL(homeURL: homeURL, accountKey: accountKey))
}

private func immutableAccountAuthURL(homeURL: URL, accountKey: String) throws -> URL {
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
        return accountDirectoryURL
            .appendingPathComponent("revisions", isDirectory: true)
            .appendingPathComponent("\(revision).json")
    }
    return accountDirectoryURL.appendingPathComponent("auth.json")
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

private func accountReconciliationDebtURL(homeURL: URL) -> URL {
    homeURL
        .appendingPathComponent(".codex_review", isDirectory: true)
        .appendingPathComponent("accounts", isDirectory: true)
        .appendingPathComponent("reconciliation-debt.json")
}

private func accountReconciliationDebtURLForCodexHome(_ codexHomeURL: URL) -> URL {
    codexHomeURL
        .appendingPathComponent("accounts", isDirectory: true)
        .appendingPathComponent("reconciliation-debt.json")
}

private func writeReconciliationDebt(
    homeURL: URL,
    expectedAccountKey: String
) throws {
    let url = accountReconciliationDebtURL(homeURL: homeURL)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let data = try JSONSerialization.data(withJSONObject: [
        "expectation": "account",
        "accountKey": expectedAccountKey,
        "message": "test reconciliation debt",
        "recordedAt": 0,
    ])
    try data.write(to: url)
}

private func temporaryHomeCleanupDebtURL(homeURL: URL) -> URL {
    homeURL
        .appendingPathComponent(".codex_review", isDirectory: true)
        .appendingPathComponent("accounts", isDirectory: true)
        .appendingPathComponent("temporary-home-cleanup-debt.json")
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

private enum MCPHTTPServerProbeError: Error, Sendable {
    case stagingFailed
}

private struct InjectedRegistryReplaceFailure: Error, Sendable {}

private final class RegistryReplaceFailureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var isArmed = false
    private var recordedFailureCount = 0

    var failureCount: Int {
        lock.withLock { recordedFailureCount }
    }

    func arm() {
        lock.withLock { isArmed = true }
    }

    func failIfArmed() throws {
        let shouldFail = lock.withLock {
            guard isArmed else { return false }
            isArmed = false
            recordedFailureCount += 1
            return true
        }
        if shouldFail {
            throw InjectedRegistryReplaceFailure()
        }
    }
}

private final class RegistryReplacementCorruptingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let registryURL: URL
    private var isArmed = false
    private var recordedCorruptionCount = 0

    init(registryURL: URL) {
        self.registryURL = registryURL
    }

    var corruptionCount: Int {
        lock.withLock { recordedCorruptionCount }
    }

    func arm() {
        lock.withLock { isArmed = true }
    }

    func corruptIfArmed() throws {
        let shouldCorrupt = lock.withLock {
            guard isArmed else { return false }
            isArmed = false
            recordedCorruptionCount += 1
            return true
        }
        guard shouldCorrupt else { return }
        try Data("invalid registry".utf8).write(to: registryURL)
        throw InjectedRegistryReplaceFailure()
    }
}

private final class BlockingRegistryReplacementProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var isArmed = false
    private var isBlocked = false
    private var isOpen = false

    func arm() {
        condition.withLock {
            isArmed = true
            isBlocked = false
            isOpen = false
        }
    }

    func blockIfArmed() {
        condition.lock()
        guard isArmed else {
            condition.unlock()
            return
        }
        isArmed = false
        isBlocked = true
        condition.broadcast()
        while isOpen == false {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilBlocked() async {
        while condition.withLock({ isBlocked }) == false {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func open() {
        condition.withLock {
            isOpen = true
            condition.broadcast()
        }
    }
}

private final class BlockingRegistryReplacementCorruptingProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private let registryURL: URL
    private var isArmed = false
    private var isBlocked = false
    private var isOpen = false

    init(registryURL: URL) {
        self.registryURL = registryURL
    }

    var hasBlocked: Bool {
        condition.withLock { isBlocked }
    }

    func arm() {
        condition.withLock {
            isArmed = true
            isBlocked = false
            isOpen = false
        }
    }

    func blockCorruptAndFailIfArmed() throws {
        condition.lock()
        guard isArmed else {
            condition.unlock()
            return
        }
        isArmed = false
        isBlocked = true
        condition.broadcast()
        while isOpen == false {
            condition.wait()
        }
        condition.unlock()
        try Data("invalid registry".utf8).write(to: registryURL)
        throw InjectedRegistryReplaceFailure()
    }

    func waitUntilBlocked() async {
        while condition.withLock({ isBlocked }) == false {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func open() {
        condition.withLock {
            isOpen = true
            condition.broadcast()
        }
    }
}

private final class PathSynchronizationFailureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let path: String
    private var remainingFailures: Int
    private var failures = 0
    private var invocations = 0

    init(path: String, failureCount: Int) {
        self.path = path
        remainingFailures = failureCount
    }

    var recordedFailureCount: Int {
        lock.withLock { failures }
    }

    var recordedInvocationCount: Int {
        lock.withLock { invocations }
    }

    func arm(failureCount: Int) {
        lock.withLock {
            remainingFailures = failureCount
            failures = 0
            invocations = 0
        }
    }

    func failIfNeeded(_ url: URL) throws {
        let shouldFail = lock.withLock {
            guard url.standardizedFileURL.path == path else {
                return false
            }
            invocations += 1
            guard remainingFailures > 0 else { return false }
            remainingFailures -= 1
            failures += 1
            return true
        }
        if shouldFail {
            throw InjectedRegistryReplaceFailure()
        }
    }
}

private final class DirectorySynchronizationFailureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true
    private var recordedFailureCount = 0
    private var recordedSynchronizedPaths: [String] = []

    var failureCount: Int {
        lock.withLock { recordedFailureCount }
    }

    var synchronizedPaths: [String] {
        lock.withLock { recordedSynchronizedPaths }
    }

    func failFirstSynchronization(_ url: URL) throws {
        let shouldThrow = lock.withLock {
            recordedSynchronizedPaths.append(url.path)
            guard shouldFail else { return false }
            shouldFail = false
            recordedFailureCount += 1
            return true
        }
        if shouldThrow {
            throw InjectedDirectorySynchronizationFailure()
        }
    }
}

private struct InjectedDirectorySynchronizationFailure: Error, Sendable {}

private actor MCPHTTPServerProbeState {
    private(set) var stageCount = 0
    private(set) var activateCount = 0
    private(set) var stopCount = 0

    func recordStage() {
        stageCount += 1
    }

    func recordActivation() {
        activateCount += 1
    }

    func recordStop() {
        stopCount += 1
    }

    func snapshot() -> MCPHTTPServerProbe.Snapshot {
        .init(
            stageCount: stageCount,
            activateCount: activateCount,
            stopCount: stopCount
        )
    }
}

private final class MCPHTTPServerProbe: CodexReviewMCPHTTPServing, @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        var stageCount: Int
        var activateCount: Int
        var stopCount: Int
    }

    private let endpoint: URL
    private let stageFailure: MCPHTTPServerProbeError?
    private let stageGate: CodexAppServerTestGate?
    private let activationGate: CodexAppServerTestGate?
    private let stopGate: CodexAppServerTestGate?
    private let state = MCPHTTPServerProbeState()

    init(
        endpoint: URL,
        stageFailure: MCPHTTPServerProbeError? = nil,
        stageGate: CodexAppServerTestGate? = nil,
        activationGate: CodexAppServerTestGate? = nil,
        stopGate: CodexAppServerTestGate? = nil
    ) {
        self.endpoint = endpoint
        self.stageFailure = stageFailure
        self.stageGate = stageGate
        self.activationGate = activationGate
        self.stopGate = stopGate
    }

    var url: URL {
        get async {
            endpoint
        }
    }

    func start() async throws {
        try await stage()
    }

    func stage() async throws {
        await state.recordStage()
        await stageGate?.waitIgnoringCancellation()
        if let stageFailure {
            throw stageFailure
        }
    }

    func activate() async {
        await state.recordActivation()
        await activationGate?.waitIgnoringCancellation()
    }

    func stop() async {
        await state.recordStop()
        await stopGate?.waitIgnoringCancellation()
    }

    func snapshot() async -> Snapshot {
        await state.snapshot()
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

private actor ControlledHostRetentionJournal: ReviewThreadRetentionJournaling {
    private var snapshot = ReviewThreadRetentionJournalSnapshot()
    private var replacementFailure: String?

    func failReplacements(_ message: String?) {
        replacementFailure = message
    }

    func load() throws -> ReviewThreadRetentionJournalSnapshot {
        snapshot
    }

    func replace(with snapshot: ReviewThreadRetentionJournalSnapshot) throws {
        if let replacementFailure {
            throw ControlledHostRetentionJournalError(message: replacementFailure)
        }
        self.snapshot = snapshot
    }
}

private struct ControlledHostRetentionJournalError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}
