import Foundation
import AppKit
import AuthenticationServices
import Testing
import CodexReview
import CodexReviewAppServer
import CodexReviewHost
import CodexReviewMCPServer
import CodexReviewTesting

private enum HostCloseFailure: LocalizedError, Equatable, Sendable {
    case injected

    var errorDescription: String? {
        "Injected host close failure."
    }
}

private actor HostCloseFailureTransport: JSONRPC.Transport {
    private var closeCallCount = 0

    func send(_: JSONRPC.Request) async throws -> Data {
        Data("{}".utf8)
    }

    func notify(_: JSONRPC.Notification) async throws {}

    func notificationStream() async -> AsyncThrowingStream<JSONRPC.Notification, Error> {
        AsyncThrowingStream { _ in }
    }

    func close() async throws {
        closeCallCount += 1
        throw HostCloseFailure.injected
    }

    func recordedCloseCallCount() -> Int {
        closeCallCount
    }
}

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

    @Test func directRuntimeFailureUsesExactCancellationReason() async throws {
        let interruptGate = AsyncGate()
        let backend = FakeCodexReviewBackend()
        await backend.holdInterruptReview(with: interruptGate)
        let host = CodexReviewHost(backend: backend)
        await host.start()
        let review = Task { @MainActor in
            try await host.store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        let active = await StoreSnapshotProbe(store: host.store).waitUntil {
            $0.job()?.activeRun != nil
        }
        let activeRun = try #require(active?.job()?.activeRun)

        let failure = Task { @MainActor in
            await host.store.stop(intent: .unexpectedFailure("Injected direct failure."))
        }
        try await backend.waitForInterruptReview(timeout: .seconds(2))
        let expected = "Review runtime stopped unexpectedly: Injected direct failure."
        #expect(host.store.serverState == .failed(expected))
        let command = try #require(await backend.recordedCommands().last)
        guard case .interruptReviewAdmission(let admission, let reason) = command else {
            Issue.record("Expected an interrupt request.")
            return
        }
        #expect(admission.run == activeRun)
        #expect(reason.message == expected)
        #expect(host.store.jobs.first?.core.lifecycle.cancellation?.message == expected)

        await interruptGate.open()
        await backend.yield(.cancelled(expected), for: activeRun)
        await failure.value
        let result = try await review.value
        #expect(result.core.lifecycle.cancellation?.message == expected)
        #expect(host.store.serverState == .failed(expected))
    }

    @Test func teardownIntentDerivesReasonStateAndDiagnosticsFromOneValue() {
        let explicit = ReviewRuntimeTeardownIntent.explicitStop
        #expect(explicit.reviewCancellation == .system(message: "Review runtime stopped."))
        #expect(explicit.finalState == .stopped)
        #expect(explicit.diagnosticContext == "runtime stop")
        #expect(explicit.cleanupTimeoutWarning == "Timed out cleaning active reviews before stopping runtime")

        let failure = ReviewRuntimeTeardownIntent.unexpectedFailure("Connection lost.")
        let message = "Review runtime stopped unexpectedly: Connection lost."
        #expect(failure.reviewCancellation == .system(message: message))
        #expect(failure.finalState == .failed(message))
        #expect(failure.diagnosticContext == "runtime failure")
        #expect(failure.cleanupTimeoutWarning == "Timed out cleaning active reviews after runtime failure")
    }

    @Test func hostStopReplaysAppServerLifecycleCloseFailure() async {
        let transport = HostCloseFailureTransport()
        let host = CodexReviewHost(appServerTransport: transport)

        await #expect(throws: HostCloseFailure.injected) {
            try await host.stop()
        }
        await #expect(throws: HostCloseFailure.injected) {
            try await host.stop()
        }

        #expect(await transport.recordedCloseCallCount() == 1)
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
        await store.stop()
    }

    @Test func liveStoreKeepsThrowingMCPStopAtItsNonthrowingBoundary() async throws {
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
            try await transport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        }
        let firstServer = ControlledMCPHTTPServer(
            endpoint: try #require(URL(string: "http://127.0.0.1:19432/mcp")),
            stopFailure: .injected
        )
        let secondServer = ControlledMCPHTTPServer(
            endpoint: try #require(URL(string: "http://127.0.0.1:19433/mcp"))
        )
        var servers = [firstServer, secondServer]
        var transports = [firstTransport, secondTransport]
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: { _, _ in servers.removeFirst() },
            mcpHTTPServerBindChecker: { _ in },
            transportFactory: { _ in transports.removeFirst() }
        )

        await store.start()
        #expect(store.serverURL == firstServer.endpoint)
        await store.stop()
        #expect(store.serverState == .stopped)
        #expect(firstServer.startCallCount == 1)
        #expect(firstServer.stopCallCount == 1)

        await store.start()
        #expect(store.serverURL == secondServer.endpoint)
        #expect(secondServer.startCallCount == 1)
        await store.stop()
        #expect(secondServer.stopCallCount == 1)
        #expect(servers.isEmpty)
        #expect(transports.isEmpty)
    }

    @Test func liveStoreStopsMCPServerAfterItsStartFails() async throws {
        let homeURL = try temporaryHome()
        let transport = FakeJSONRPCTransport()
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
        try await transport.enqueue(
            AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
            for: "config/read"
        )
        try await transport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        let server = ControlledMCPHTTPServer(
            endpoint: try #require(URL(string: "http://127.0.0.1:19434/mcp")),
            startFailure: .injected
        )
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: { _, _ in server },
            mcpHTTPServerBindChecker: { _ in },
            transportFactory: { _ in transport }
        )

        await store.start()

        guard case .failed(let message) = store.serverState else {
            Issue.record("Expected failed server state.")
            return
        }
        #expect(message == HostCloseFailure.injected.localizedDescription)
        #expect(store.serverURL == nil)
        #expect(server.startCallCount == 1)
        #expect(server.stopCallCount == 1)
    }

    @Test func liveSameAccountRestartRetainsMCPListenerAndURL() async throws {
        let homeURL = try temporaryHome()
        let firstTransport = FakeJSONRPCTransport()
        let secondTransport = FakeJSONRPCTransport()
        try await enqueueRuntimeStartResponses(firstTransport)
        try await enqueueRuntimeStartResponses(secondTransport)
        let server = ControlledMCPHTTPServer(
            endpoint: try #require(URL(string: "http://127.0.0.1:19435/mcp"))
        )
        var transports = [firstTransport, secondTransport]
        var serverFactoryCallCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: { _, _ in
                serverFactoryCallCount += 1
                return server
            },
            mcpHTTPServerBindChecker: { _ in },
            transportFactory: { _ in transports.removeFirst() }
        )

        await store.start()
        let firstURL = store.serverURL
        await store.restart()

        #expect(store.serverState == .running)
        #expect(store.serverURL == firstURL)
        #expect(serverFactoryCallCount == 1)
        #expect(server.startCallCount == 1)
        #expect(server.stopCallCount == 0)
        #expect(await firstTransport.isClosedForTesting())
        #expect(transports.isEmpty)

        await store.stop()
        #expect(server.stopCallCount == 1)
    }

    @Test func liveExplicitOutcomeUnknownStartRetainsProvisionalRouteForExactCleanup() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueRuntimeStartResponses(transport)
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "route-thread", model: "gpt-5"),
            for: "thread/start"
        )
        await transport.enqueueCancellation(for: "review/start")
        try await enqueueReviewCleanupResponses(transport)
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transport: transport
        )
        await store.start()
        let admission = ReviewStartAdmission()

        await #expect(throws: CancellationError.self) {
            try await store.backend.startReview(
                makeLiveRouteReviewStartRequest(jobID: "job-outcome-unknown"),
                admission: admission
            )
        }
        guard case .startingReview(let preparedRun, .outcomeUnknown) = await admission.currentPhase() else {
            Issue.record("Outcome-unknown review start did not retain its prepared run.")
            await store.stop()
            return
        }
        #expect(store.liveReviewAttemptRouteCountForTesting == 1)
        let methodsBeforeCleanup = await transport.recordedRequests().map(\.method)
        #expect(methodsBeforeCleanup.contains("thread/backgroundTerminals/clean") == false)
        #expect(methodsBeforeCleanup.contains("thread/unsubscribe") == false)
        #expect(methodsBeforeCleanup.contains("thread/delete") == false)

        var lateActiveRun = preparedRun
        lateActiveRun.turnID = "late-turn"
        lateActiveRun.reviewThreadID = "late-review-thread"
        try await store.backend.cleanupReview(lateActiveRun)

        #expect(store.liveReviewAttemptRouteCountForTesting == 0)
        let methodsAfterCleanup = await transport.recordedRequests().map(\.method)
        #expect(methodsAfterCleanup.filter { $0 == "thread/backgroundTerminals/clean" }.count == 1)
        #expect(methodsAfterCleanup.filter { $0 == "thread/unsubscribe" }.count == 1)
        #expect(methodsAfterCleanup.filter { $0 == "thread/delete" }.count == 2)
        await #expect(throws: ReviewRuntimeCloseFailure.self) {
            try await store.backend.cleanupReview(lateActiveRun)
        }
        #expect(await transport.recordedRequests().map(\.method) == methodsAfterCleanup)
        await store.stop()
    }

    @Test func notificationFirstCleanupInvalidationClaimsOneEventualReplacement() async throws {
        let transport = FakeJSONRPCTransport()
        let replacementTransport = FakeJSONRPCTransport()
        try await enqueueRuntimeStartResponses(transport)
        try await enqueueLiveRouteReviewStartResponses(
            transport,
            threadID: "route-thread",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let cleanupGate = AsyncGate()
        await transport.holdNextIgnoringCancellation(
            method: "thread/backgroundTerminals/clean",
            gate: cleanupGate
        )
        try await enqueueRuntimeStartResponses(replacementTransport)
        try await enqueueLiveRouteReviewStartResponses(
            replacementTransport,
            threadID: "replacement-thread",
            turnID: "replacement-turn",
            reviewThreadID: "replacement-review-thread"
        )
        try await enqueueReviewCleanupResponses(replacementTransport)
        let replacementFactoryStarted = AsyncGate()
        let replacementFactoryGate = AsyncGate()
        var transports = [transport, replacementTransport]
        var factoryCallCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transportFactory: { _ in
                factoryCallCount += 1
                if factoryCallCount == 2 {
                    await replacementFactoryStarted.open()
                    await replacementFactoryGate.waitIgnoringCancellation()
                }
                return transports.removeFirst()
            }
        )
        await store.start()
        await transport.waitForNotificationStreamCount(1)
        let attempt = try await store.backend.startReview(
            makeLiveRouteReviewStartRequest(jobID: "job-cleanup-invalidation"),
            admission: ReviewStartAdmission()
        )
        let cleanup = Task { @MainActor in
            try await store.backend.cleanupReview(attempt.run)
        }
        await transport.waitForActiveRequests(method: "thread/backgroundTerminals/clean")

        await transport.finishNotificationStreams(
            throwing: JSONRPC.Error.transportTerminated(.ownerClose)
        )
        await transport.waitUntilClosedForTesting()
        await #expect(throws: ReviewRuntimeCloseFailure.self) {
            try await cleanup.value
        }
        await replacementFactoryStarted.wait()
        guard case .acquiring(_, _, let replacementTask) = store.runtimeState else {
            Issue.record("Expected cleanup recovery to own an eventual replacement task.")
            return
        }

        #expect(await transport.isClosedForTesting())
        #expect(store.liveReviewAttemptRouteCountForTesting == 0)
        #expect(factoryCallCount == 2)
        #expect(store.serverState != .running)

        await replacementFactoryGate.open()
        await replacementTask.value
        #expect(store.serverState == .running)
        let replacementAttempt = try await store.backend.startReview(
            makeLiveRouteReviewStartRequest(jobID: "job-replacement"),
            admission: ReviewStartAdmission()
        )
        try await store.backend.cleanupReview(replacementAttempt.run)
        #expect(store.liveReviewAttemptRouteCountForTesting == 0)
        await store.stop()
    }

    @Test func cleanupFirstTransportInvalidationClaimsOneEventualReplacement() async throws {
        let transport = FakeJSONRPCTransport()
        let replacementTransport = FakeJSONRPCTransport()
        try await enqueueRuntimeStartResponses(transport)
        try await enqueueLiveRouteReviewStartResponses(
            transport,
            threadID: "route-thread",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        await transport.enqueueTransportFailure(
            message: "raw cleanup I/O failed",
            for: "thread/backgroundTerminals/clean"
        )
        try await enqueueRuntimeStartResponses(replacementTransport)
        try await enqueueLiveRouteReviewStartResponses(
            replacementTransport,
            threadID: "replacement-thread",
            turnID: "replacement-turn",
            reviewThreadID: "replacement-review-thread"
        )
        try await enqueueReviewCleanupResponses(replacementTransport)
        var transports = [transport, replacementTransport]
        var factoryCallCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transportFactory: { _ in
                factoryCallCount += 1
                return transports.removeFirst()
            }
        )
        await store.start()
        let attempt = try await store.backend.startReview(
            makeLiveRouteReviewStartRequest(jobID: "job-cleanup-first"),
            admission: ReviewStartAdmission()
        )

        await #expect(throws: ReviewRuntimeCloseFailure.connection(
            "thread/backgroundTerminals/clean for route-thread: "
                + "App-server cleanup request failed during transport: raw cleanup I/O failed"
        )) {
            try await store.backend.cleanupReview(attempt.run)
        }
        await waitForRuntimeLifecycleSettlement(store)

        #expect(await transport.isClosedForTesting())
        #expect(factoryCallCount == 2)
        #expect(store.serverState == .running)
        #expect(store.liveReviewAttemptRouteCountForTesting == 0)

        let replacement = try await store.backend.startReview(
            makeLiveRouteReviewStartRequest(jobID: "job-after-cleanup-first"),
            admission: ReviewStartAdmission()
        )
        try await store.backend.cleanupReview(replacement.run)
        #expect(store.liveReviewAttemptRouteCountForTesting == 0)
        await store.stop()
    }

    @Test func liveCancelledCleanupReturnsBeforeEventualRuntimeReplacement() async throws {
        let transport = FakeJSONRPCTransport()
        let replacementTransport = FakeJSONRPCTransport()
        let unusedTransport = FakeJSONRPCTransport()
        try await enqueueRuntimeStartResponses(transport)
        try await enqueueLiveRouteReviewStartResponses(
            transport,
            threadID: "route-thread",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        let cleanupGate = AsyncGate()
        await transport.holdNextIgnoringCancellation(
            method: "thread/backgroundTerminals/clean",
            gate: cleanupGate
        )
        try await enqueueRuntimeStartResponses(replacementTransport)
        try await enqueueLiveRouteReviewStartResponses(
            replacementTransport,
            threadID: "replacement-thread",
            turnID: "replacement-turn",
            reviewThreadID: "replacement-review-thread"
        )
        try await enqueueReviewCleanupResponses(replacementTransport)
        let replacementFactoryStarted = AsyncGate()
        let replacementFactoryGate = AsyncGate()
        var transports = [transport, replacementTransport, unusedTransport]
        var factoryCallCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transportFactory: { _ in
                factoryCallCount += 1
                if factoryCallCount == 2 {
                    await replacementFactoryStarted.open()
                    await replacementFactoryGate.waitIgnoringCancellation()
                }
                return transports.removeFirst()
            }
        )
        await store.start()
        let attempt = try await store.backend.startReview(
            makeLiveRouteReviewStartRequest(jobID: "job-cancelled-cleanup"),
            admission: ReviewStartAdmission()
        )
        let cleanup = Task { @MainActor in
            try await store.backend.cleanupReview(attempt.run)
        }
        try #require(await waitUntil(timeout: .seconds(2)) {
            await transport.recordedRequests().contains {
                $0.method == "thread/backgroundTerminals/clean"
            }
        })

        cleanup.cancel()
        await #expect(throws: CancellationError.self) {
            try await cleanup.value
        }
        await replacementFactoryStarted.wait()
        guard case .acquiring(_, _, let replacementTask) = store.runtimeState else {
            Issue.record("Expected cancelled cleanup to admit one eventual replacement.")
            return
        }

        #expect(await transport.isClosedForTesting())
        #expect(factoryCallCount == 2)
        #expect(store.serverState != .running)

        await replacementFactoryGate.open()
        await replacementTask.value
        #expect(store.serverState == .running)
        let replacementAttempt = try await store.backend.startReview(
            makeLiveRouteReviewStartRequest(jobID: "job-after-cancelled-cleanup"),
            admission: ReviewStartAdmission()
        )
        try await store.backend.cleanupReview(replacementAttempt.run)
        #expect(store.liveReviewAttemptRouteCountForTesting == 0)
        await store.stop()
    }

    @Test func reviewWorkerCleanupReturnsBeforeItsRuntimeReplacementCompletes() async throws {
        let transport = FakeJSONRPCTransport()
        let replacementTransport = FakeJSONRPCTransport()
        try await enqueueRuntimeStartResponses(transport)
        try await enqueueLiveRouteReviewStartResponses(
            transport,
            threadID: "route-thread",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let interruptAccepted = AsyncGate()
        await transport.beforeReturningNextResponse(method: "turn/interrupt") {
            await interruptAccepted.open()
        }
        let cleanupStarted = AsyncGate()
        await transport.beforeReturningNextResponse(
            method: "thread/backgroundTerminals/clean"
        ) {
            await cleanupStarted.open()
        }
        await transport.enqueueTransportFailure(
            message: "cleanup transport failed",
            for: "thread/backgroundTerminals/clean"
        )
        try await enqueueRuntimeStartResponses(replacementTransport)
        let replacementFactoryStarted = AsyncGate()
        let replacementFactoryGate = AsyncGate()
        var transports = [transport, replacementTransport]
        var factoryCallCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            shutdownCleanupTimeout: .seconds(30),
            transportFactory: { _ in
                factoryCallCount += 1
                if factoryCallCount == 2 {
                    await replacementFactoryStarted.open()
                    await replacementFactoryGate.waitIgnoringCancellation()
                }
                return transports.removeFirst()
            }
        )
        await store.start()
        let review = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-worker-cleanup",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        let active = try #require(await StoreSnapshotProbe(store: store).waitUntil { snapshot in
            snapshot.jobs.first?.activeRun?.turnID == "turn-1"
        })
        let jobID = try #require(active.jobs.first?.jobID)
        let cancel = Task { @MainActor in
            try await store.cancelReview(
                jobID: jobID,
                cancellation: .mcpClient(message: "Stop review")
            )
        }

        await interruptAccepted.wait()
        try await emitInterruptedTurn(
            transport,
            threadID: "review-thread-1",
            turnID: "turn-1",
            message: "Stop review"
        )
        await cleanupStarted.wait()
        let cancellation = try await cancel.value
        let result = try await review.value
        await replacementFactoryStarted.wait()
        guard case .acquiring(_, _, let replacementTask) = store.runtimeState else {
            Issue.record("Expected worker cleanup to leave replacement completion Store-owned.")
            return
        }

        #expect(cancellation.cancelled)
        #expect(result.core.lifecycle.status == .cancelled)
        #expect(store.reviewWorkerTasks[jobID] == nil)
        #expect(store.runtimeStopDetachedReviewWorkerTasks[jobID] == nil)
        #expect(factoryCallCount == 2)
        #expect(store.serverState != .running)

        await replacementFactoryGate.open()
        await replacementTask.value
        #expect(store.serverState == .running)
        await store.stop()
    }

    @Test func concurrentLiveCleanupFailuresShareOneRuntimeReplacement() async throws {
        let transport = FakeJSONRPCTransport()
        let replacementTransport = FakeJSONRPCTransport()
        let unusedTransport = FakeJSONRPCTransport()
        try await enqueueRuntimeStartResponses(transport)
        try await enqueueLiveRouteReviewStartResponses(
            transport,
            threadID: "route-thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1"
        )
        try await enqueueLiveRouteReviewStartResponses(
            transport,
            threadID: "route-thread-2",
            turnID: "turn-2",
            reviewThreadID: "review-thread-2"
        )
        let cleanupGate = AsyncGate()
        await transport.holdNextIgnoringCancellation(
            method: "thread/backgroundTerminals/clean",
            gate: cleanupGate
        )
        await transport.holdNextIgnoringCancellation(
            method: "thread/backgroundTerminals/clean",
            gate: cleanupGate
        )
        try await enqueueRuntimeStartResponses(replacementTransport)
        try await enqueueLiveRouteReviewStartResponses(
            replacementTransport,
            threadID: "replacement-thread",
            turnID: "replacement-turn",
            reviewThreadID: "replacement-review-thread"
        )
        try await enqueueReviewCleanupResponses(replacementTransport)
        var transports = [transport, replacementTransport, unusedTransport]
        var factoryCallCount = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transportFactory: { _ in
                factoryCallCount += 1
                return transports.removeFirst()
            }
        )
        await store.start()
        let first = try await store.backend.startReview(
            makeLiveRouteReviewStartRequest(jobID: "job-cleanup-1"),
            admission: ReviewStartAdmission()
        )
        let second = try await store.backend.startReview(
            makeLiveRouteReviewStartRequest(jobID: "job-cleanup-2"),
            admission: ReviewStartAdmission()
        )
        let firstCleanup = Task {
            do {
                try await store.backend.cleanupReview(first.run)
                return false
            } catch is ReviewRuntimeCloseFailure {
                return true
            } catch {
                return false
            }
        }
        let secondCleanup = Task {
            do {
                try await store.backend.cleanupReview(second.run)
                return false
            } catch is ReviewRuntimeCloseFailure {
                return true
            } catch {
                return false
            }
        }

        try #require(await waitUntil(timeout: .seconds(2)) {
            await transport.recordedRequests().filter {
                $0.method == "thread/backgroundTerminals/clean"
            }.count == 2
        })
        await transport.close()
        #expect(await firstCleanup.value)
        #expect(await secondCleanup.value)
        await waitForRuntimeLifecycleSettlement(store)
        #expect(factoryCallCount == 2)
        #expect(store.serverState == .running)
        #expect(store.liveReviewAttemptRouteCountForTesting == 0)

        let replacement = try await store.backend.startReview(
            makeLiveRouteReviewStartRequest(jobID: "job-after-cleanup-replacement"),
            admission: ReviewStartAdmission()
        )
        try await store.backend.cleanupReview(replacement.run)
        #expect(store.liveReviewAttemptRouteCountForTesting == 0)
        await store.stop()
    }

    @Test func liveCompatibilityOutcomeUnknownStartDoesNotRetainLowerCleanupRoute() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueRuntimeStartResponses(transport)
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "compatibility-thread", model: "gpt-5"),
            for: "thread/start"
        )
        await transport.enqueueCancellation(for: "review/start")
        try await enqueueReviewCleanupResponses(transport)
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transport: transport
        )
        await store.start()

        await #expect(throws: CancellationError.self) {
            try await store.backend.startReview(
                makeLiveRouteReviewStartRequest(jobID: "job-compatibility"),
                admission: .compatibility()
            )
        }

        #expect(store.liveReviewAttemptRouteCountForTesting == 0)
        let methods = await transport.recordedRequests().map(\.method)
        #expect(methods.filter { $0 == "thread/backgroundTerminals/clean" }.count == 1)
        #expect(methods.filter { $0 == "thread/unsubscribe" }.count == 1)
        #expect(methods.filter { $0 == "thread/delete" }.count == 1)
        await store.stop()
    }

    @Test func liveTypedRecoveryPreparationRetainsOnlyItsExactSourceRoute() async throws {
        let source = FakeJSONRPCTransport()
        let replacement = FakeJSONRPCTransport()
        try await enqueueRuntimeStartResponses(source)
        try await enqueueRuntimeStartResponses(replacement)
        try await enqueueLiveRouteReviewStartResponses(
            source,
            threadID: "typed-source-thread",
            turnID: "typed-source-turn",
            reviewThreadID: "typed-source-review"
        )
        var transports = [source, replacement]
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transportFactory: { _ in transports.removeFirst() }
        )
        await store.start()
        let attempt = try await store.backend.startReview(
            makeLiveRouteReviewStartRequest(jobID: "job-typed-source"),
            admission: ReviewStartAdmission()
        )
        var staleRun = attempt.run
        staleRun.turnID = "stale-turn"
        await #expect(throws: ReviewAttemptContractFailure.self) {
            try await store.backend.prepareReviewRecovery(
                makeRecoveryCandidate(for: staleRun)
            )
        }

        let candidate = try await makeRecoveryCandidate(for: attempt.run)
        let prepared = try await store.backend.prepareReviewRecovery(candidate)
        let retainedHandoff = prepared.handoff
        #expect(prepared.receipt.sourceRun == attempt.run)
        #expect(prepared.receipt.sourceGeneration.rawValue == store.runtimeLifecycleAdmissionGeneration)
        #expect(store.liveReviewRecoveryRouteCountForTesting == 1)
        await #expect(throws: ReviewAttemptContractFailure.self) {
            try await store.backend.prepareReviewRecovery(candidate)
        }

        await store.restart()
        let replacementMethods = await replacement.recordedRequests().map(\.method)
        await #expect(throws: JSONRPC.Error.closed) {
            try await store.backend.discardReviewRecovery(prepared)
        }
        #expect(store.liveReviewAttemptRouteCountForTesting == 0)
        #expect(store.liveReviewRecoveryRouteCountForTesting == 0)
        await #expect(throws: ReviewRecoveryHandoffAlreadyConsumed.self) {
            try await retainedHandoff.consume()
        }
        await #expect(throws: ReviewRecoveryHandoffAlreadyConsumed.self) {
            try await store.backend.discardReviewRecovery(prepared)
        }
        await #expect(throws: ReviewAttemptContractFailure.self) {
            try await store.backend.prepareReviewRecovery(
                makeRecoveryCandidate(for: attempt.run)
            )
        }
        #expect(await replacement.recordedRequests().map(\.method) == replacementMethods)
        await store.stop()
    }

    @Test func liveTypedRecoveryDiscardInvalidatesRetainedHandoffBeforeCleanup() async throws {
        let transport = FakeJSONRPCTransport()
        try await enqueueRuntimeStartResponses(transport)
        try await enqueueLiveRouteReviewStartResponses(
            transport,
            threadID: "typed-discard-thread",
            turnID: "typed-discard-turn",
            reviewThreadID: "typed-discard-review"
        )
        try await enqueueReviewCleanupResponses(transport)
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transport: transport
        )
        await store.start()
        let attempt = try await store.backend.startReview(
            makeLiveRouteReviewStartRequest(jobID: "job-typed-discard"),
            admission: ReviewStartAdmission()
        )
        let candidate = try await makeRecoveryCandidate(for: attempt.run)
        let prepared = try await store.backend.prepareReviewRecovery(candidate)
        let retainedHandoff = prepared.handoff

        try await store.backend.discardReviewRecovery(prepared)

        #expect(store.liveReviewAttemptRouteCountForTesting == 0)
        #expect(store.liveReviewRecoveryRouteCountForTesting == 0)
        await #expect(throws: ReviewRecoveryHandoffAlreadyConsumed.self) {
            try await retainedHandoff.consume()
        }
        let methodsAfterDiscard = await transport.recordedRequests().map(\.method)
        #expect(methodsAfterDiscard.filter { $0 == "thread/backgroundTerminals/clean" }.count == 1)
        #expect(methodsAfterDiscard.filter { $0 == "thread/unsubscribe" }.count == 1)
        await #expect(throws: ReviewRecoveryHandoffAlreadyConsumed.self) {
            try await store.backend.discardReviewRecovery(prepared)
        }
        #expect(await transport.recordedRequests().map(\.method) == methodsAfterDiscard)
        await store.stop()
    }

    @Test func liveTypedRecoveryDestinationCommitsOnlyItsExactGeneration() async throws {
        let fixture = try await makeLiveTypedRecoveryFixture()
        let methodsBeforeStaging = await fixture.destination.recordedRequests().map(\.method)
        await #expect(throws: ReviewRecoveryStagingFailure.callerRetainsPreparedRecovery(
            message: "Review recovery destination generation \(fixture.destinationGeneration.successor().rawValue) is not active."
        )) {
            try await fixture.store.backend.stageReviewRecovery(
                fixture.prepared,
                destinationGeneration: fixture.destinationGeneration.successor(),
                request: fixture.request,
                admission: ReviewStartAdmission()
            )
        }
        #expect(await fixture.destination.recordedRequests().map(\.method) == methodsBeforeStaging)
        let admission = ReviewStartAdmission()
        let staged = try await fixture.store.backend.stageReviewRecovery(
            fixture.prepared,
            destinationGeneration: fixture.destinationGeneration,
            request: fixture.request,
            admission: admission
        )
        let methodsAfterStaging = await fixture.destination.recordedRequests().map(\.method)
        await #expect(throws: ReviewRecoveryStagingFailure.backendOwnsRecovery(
            message: "Review recovery staging requires its exact route for attempt \(fixture.prepared.receipt.sourceRun.attemptID)."
        )) {
            try await fixture.store.backend.stageReviewRecovery(
                fixture.prepared,
                destinationGeneration: fixture.destinationGeneration.successor(),
                request: fixture.request,
                admission: ReviewStartAdmission()
            )
        }
        #expect(await fixture.destination.recordedRequests().map(\.method) == methodsAfterStaging)
        let reconstructed = StagedReviewRecovery(
            receipt: staged.receipt,
            destinationGeneration: staged.destinationGeneration,
            attempt: staged.attempt,
            admission: staged.admission
        )
        await #expect(throws: ReviewAttemptContractFailure.self) {
            try await fixture.store.backend.commitReviewRecovery(reconstructed)
        }
        #expect(await fixture.destination.recordedRequests().map(\.method) == methodsAfterStaging)
        try await fixture.store.backend.commitReviewRecovery(staged)
        #expect(fixture.store.liveReviewRecoveryRouteCountForTesting == 0)
        #expect(fixture.store.liveReviewAttemptRouteCountForTesting == 1)
        await #expect(throws: ReviewAttemptContractFailure.self) {
            try await fixture.store.backend.commitReviewRecovery(staged)
        }
        await #expect(throws: ReviewAttemptContractFailure.self) {
            try await fixture.store.backend.discardReviewRecovery(staged)
        }
        #expect(await fixture.destination.recordedRequests().map(\.method) == methodsAfterStaging)
        try await fixture.store.backend.cleanupReview(staged.attempt.run)
        #expect(fixture.store.liveReviewAttemptRouteCountForTesting == 0)
        let sourceMethods = await fixture.source.recordedRequests().map(\.method)
        let destinationMethods = await fixture.destination.recordedRequests().map(\.method)
        #expect(sourceMethods.contains("thread/rollback") == false)
        #expect(destinationMethods.filter { $0 == "thread/rollback" }.count == 1)
        #expect(destinationMethods.filter { $0 == "review/start" }.count == 1)
        await fixture.store.stop()
    }

    @Test func liveTypedRecoveryDestinationDiscardIsTerminalAndExact() async throws {
        let fixture = try await makeLiveTypedRecoveryFixture()
        let staged = try await fixture.store.backend.stageReviewRecovery(
            fixture.prepared,
            destinationGeneration: fixture.destinationGeneration,
            request: fixture.request,
            admission: ReviewStartAdmission()
        )
        try await staged.admission.recordCanonicalTerminal(
            .interrupted(.server(message: "Recovery superseded")),
            for: staged.attempt.run
        )
        await #expect(throws: ReviewAttemptContractFailure.self) {
            try await fixture.store.backend.commitReviewRecovery(staged)
        }
        try await fixture.store.backend.discardReviewRecovery(staged)
        #expect(fixture.store.liveReviewAttemptRouteCountForTesting == 0)
        #expect(fixture.store.liveReviewRecoveryRouteCountForTesting == 0)
        let methods = await fixture.destination.recordedRequests().map(\.method)
        await #expect(throws: ReviewAttemptContractFailure.self) {
            try await fixture.store.backend.discardReviewRecovery(staged)
        }
        #expect(await fixture.destination.recordedRequests().map(\.method) == methods)
        #expect(methods.filter { $0 == "thread/unsubscribe" }.count == 1)
        await fixture.store.stop()
    }

    @Test(arguments: [false, true])
    func liveTypedRecoveryDestinationCleansFailedStart(cancelAfterRollback: Bool) async throws {
        let fixture = try await makeLiveTypedRecoveryFixture(
            outcomeUnknown: cancelAfterRollback == false
        )
        let retainedHandoff = fixture.prepared.handoff
        let admission = ReviewStartAdmission()
        if cancelAfterRollback {
            await fixture.destination.beforeReturningNextResponse(
                method: "thread/rollback"
            ) {
                await admission.recordCancellation(.system())
            }
        }
        await #expect {
            try await fixture.store.backend.stageReviewRecovery(
                fixture.prepared,
                destinationGeneration: fixture.destinationGeneration,
                request: fixture.request,
                admission: admission
            )
        } throws: { error in
            guard case ReviewRecoveryStagingFailure.backendOwnsRecovery = error else {
                return false
            }
            return true
        }
        #expect(fixture.store.liveReviewAttemptRouteCountForTesting == 0)
        #expect(fixture.store.liveReviewRecoveryRouteCountForTesting == 0)
        let methods = await fixture.destination.recordedRequests().map(\.method)
        #expect(methods.filter { $0 == "thread/rollback" }.count == 1)
        #expect(methods.filter { $0 == "review/start" }.count == (cancelAfterRollback ? 0 : 1))
        #expect(methods.filter { $0 == "thread/unsubscribe" }.count == 1)
        #expect(methods.filter { $0 == "thread/backgroundTerminals/clean" }.count == 1)
        await #expect(throws: ReviewRecoveryHandoffAlreadyConsumed.self) {
            try await retainedHandoff.consume()
        }
        await #expect(throws: ReviewRecoveryHandoffAlreadyConsumed.self) {
            try await fixture.store.backend.discardReviewRecovery(fixture.prepared)
        }
        #expect(await fixture.destination.recordedRequests().map(\.method) == methods)
        await fixture.store.stop()
    }

    @Test func liveLateInterruptNeverFallsThroughToReplacementRuntime() async throws {
        let sourceTransport = FakeJSONRPCTransport()
        let replacementTransport = FakeJSONRPCTransport()
        try await enqueueRuntimeStartResponses(sourceTransport)
        try await enqueueRuntimeStartResponses(replacementTransport)
        try await enqueueLiveRouteReviewStartResponses(
            sourceTransport,
            threadID: "late-interrupt-thread",
            turnID: "late-interrupt-turn",
            reviewThreadID: "late-interrupt-review-thread"
        )
        try await enqueueLiveRouteReviewStartResponses(
            sourceTransport,
            threadID: "late-source-thread",
            turnID: "late-source-turn",
            reviewThreadID: "late-source-review-thread"
        )
        try await sourceTransport.enqueue(EmptyResponse(), for: "turn/interrupt")
        var transports = [sourceTransport, replacementTransport]
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transportFactory: { _ in transports.removeFirst() }
        )
        await store.start()
        let admission = ReviewStartAdmission()
        let attempt = try await store.backend.startReview(
            makeLiveRouteReviewStartRequest(jobID: "job-late-interrupt"),
            admission: admission
        )

        var staleRun = attempt.run
        staleRun.turnID = "stale-turn"
        let staleAdmission = ReviewStartAdmission()
        try await staleAdmission.recordPreparedRecoveryRun(staleRun)
        try await staleAdmission.admitReviewStartDispatch(for: staleRun)
        try await staleAdmission.recordActiveRun(staleRun)
        let staleRequestEntered = AsyncGate()
        let staleRecovery = Task {
            try await staleAdmission.beginRecovery(
                staleRun,
                trigger: .recoverableNetworkLoss
            ) { request, reason in
                await staleRequestEntered.open()
                try await store.backend.interruptReview(request, reason: reason)
            }
        }
        await staleRequestEntered.wait()
        await #expect(throws: ReviewInterruptRequestFailure.self) {
            try await staleRecovery.value
        }
        #expect(await staleAdmission.currentPhase() == .active(staleRun))
        #expect(await sourceTransport.recordedRequests().map(\.method).contains("turn/interrupt") == false)

        let interruptAcknowledged = AsyncGate()
        let recovery = Task {
            try await admission.beginRecovery(
                attempt.run,
                trigger: .recoverableNetworkLoss
            ) { request, reason in
                try await store.backend.interruptReview(request, reason: reason)
                await interruptAcknowledged.open()
            }
        }
        await interruptAcknowledged.wait()
        #expect(await attempt.events.isFinished() == false)
        try await admission.recordCanonicalTerminal(.completed, for: attempt.run)
        _ = try await recovery.value
        #expect(await attempt.events.isFinished() == false)

        let lateAdmission = ReviewStartAdmission()
        let lateAttempt = try await store.backend.startReview(
            makeLiveRouteReviewStartRequest(jobID: "job-late-source"),
            admission: lateAdmission
        )
        await store.restart()
        #expect(store.liveReviewAttemptRouteCountForTesting == 2)

        let exactRequestEntered = AsyncGate()
        let exactRecovery = Task {
            try await lateAdmission.beginRecovery(
                lateAttempt.run,
                trigger: .recoverableNetworkLoss
            ) { request, reason in
                await exactRequestEntered.open()
                try await store.backend.interruptReview(request, reason: reason)
            }
        }
        await exactRequestEntered.wait()
        try await lateAdmission.recordConnectionTerminal(
            .connection("Source runtime closed."),
            for: lateAttempt.run
        )
        _ = try await exactRecovery.value

        let replacementMethods = await replacementTransport.recordedRequests().map(\.method)
        #expect(replacementMethods.contains("turn/interrupt") == false)
        for run in [attempt.run, lateAttempt.run] {
            await #expect(throws: JSONRPC.Error.closed) {
                try await store.backend.cleanupReview(run)
            }
        }
        #expect(store.liveReviewAttemptRouteCountForTesting == 0)
        #expect(await replacementTransport.recordedRequests().map(\.method) == replacementMethods)
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
        let homeURL = try temporaryHome()
        try writeRegistryRecords(
            homeURL: homeURL,
            activeAccountKey: "api-key",
            records: [
                [
                    "accountKey": "api-key",
                    "kind": "chatgpt",
                    "email": "API Key",
                    "planType": "pro",
                    "lastRateLimitFetchAt": 1_800_000_000,
                    "lastRateLimitError": "Stale ChatGPT rate-limit failure.",
                    "cachedRateLimits": [
                        [
                            "windowDurationMinutes": 300,
                            "usedPercent": 40,
                        ],
                    ],
                ],
            ]
        )
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
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transport: transport
        )
        let staleAccount = try #require(store.auth.selectedAccount)
        #expect(staleAccount.kind == .chatGPT)
        #expect(staleAccount.rateLimits.first?.usedPercent == 40)
        #expect(staleAccount.lastRateLimitFetchAt != nil)
        #expect(staleAccount.lastRateLimitError == "Stale ChatGPT rate-limit failure.")

        await store.start(forceRestartIfNeeded: true)
        await transport.waitForRequestCount(4)
        await store.refreshAccountRateLimits(accountKey: "api-key")
        await Task.yield()

        let reconciledAccount = try #require(store.auth.selectedAccount)
        #expect(reconciledAccount === staleAccount)
        #expect(reconciledAccount.kind == .apiKey)
        #expect(reconciledAccount.capabilities.supportsRateLimitRefresh == false)
        #expect(reconciledAccount.rateLimits.isEmpty)
        #expect(reconciledAccount.lastRateLimitFetchAt == nil)
        #expect(reconciledAccount.lastRateLimitError == nil)
        #expect(await transport.recordedRequests().map(\.method) == [
            "initialize",
            "account/read",
            "config/read",
            "model/list",
        ])
    }

    @Test func liveStoreAddAccountReturnsAfterPresentationAndCancelsWhenAuthenticationSessionCloses() async throws {
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

    @Test func liveRuntimeStopCancelsAndJoinsExactAuthenticationSessionBeforeRejectingLateCallback() async throws {
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
        let cancelLoginGate = AsyncGate()
        await transport.hold(method: "account/login/cancel", gate: cancelLoginGate)
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
        let cancellationGate = AsyncGate()
        session.holdCancellation(with: cancellationGate)
        let stopFinished = CompletionFlag()
        let stop = Task { @MainActor in
            await store.stop()
            await stopFinished.complete()
        }

        await session.waitUntilCancellationStarted()
        #expect(await stopFinished.isCompleted() == false)
        session.complete(with: URL(string: "lynnpd.CodexReviewMonitor.auth://callback?code=late")!)
        await cancellationGate.open()

        await transport.waitForRequestCount(6)
        #expect(await stopFinished.isCompleted() == false)
        #expect(await transport.taskCancellationStates(for: "account/login/cancel") == [false])
        await cancelLoginGate.open()

        await stop.value
        #expect(store.serverState == .stopped)
        #expect(store.auth.phase == .signedOut)
        #expect(store.auth.isAuthenticating == false)
        #expect(store.auth.selectedAccount == nil)
        #expect(await transport.recordedRequests().map(\.method) == [
            "initialize",
            "account/read",
            "config/read",
            "model/list",
            "account/login/start",
            "account/login/cancel",
        ])
    }

    @Test func liveConcurrentAuthenticationPublicationWaiterCancellationDoesNotCancelOwner() async throws {
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
                loginID: "login-shared",
                authURL: "https://example.com/auth",
                nativeWebAuthentication: .init(callbackURLScheme: "lynnpd.CodexReviewMonitor.auth")
            ),
            for: "account/login/start"
        )
        try await transport.enqueue(AppServerAPI.Account.Login.Cancel.Response(), for: "account/login/cancel")
        let sessions = FakeWebAuthenticationSessions()
        let presentationGate = AsyncGate()
        sessions.holdNextCreation(with: presentationGate)
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
        let ownerFinished = CompletionFlag()
        let owner = Task { @MainActor in
            await store.signIn()
            await ownerFinished.complete()
        }
        await sessions.waitForCreationStarted()
        let waiterFinished = CompletionFlag()
        let waiter = Task { @MainActor in
            await store.addAccount()
            await waiterFinished.complete()
        }
        waiter.cancel()

        #expect(await ownerFinished.isCompleted() == false)
        #expect(await waiterFinished.isCompleted() == false)
        await presentationGate.open()
        await owner.value
        await waiter.value

        let session = await sessions.waitForSession()
        await session.waitUntilWaitingForCallback()
        #expect(store.auth.isAuthenticating)
        #expect(sessions.createdSessionCount == 1)
        await store.cancelAuthentication()
        #expect(await transport.recordedRequests().filter { $0.method == "account/login/start" }.count == 1)
    }

    @Test func liveCancelAuthenticationJoinsBrowserLoginAndIgnoresLateAppServerCompletion() async throws {
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
                loginID: "login-browser",
                authURL: "https://example.com/auth",
                nativeWebAuthentication: nil
            ),
            for: "account/login/start"
        )
        try await transport.enqueue(AppServerAPI.Account.Login.Cancel.Response(), for: "account/login/cancel")
        let cancelGate = AsyncGate()
        await transport.hold(method: "account/login/cancel", gate: cancelGate)
        let externalURLOpener = FakeExternalURLOpener()
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": try temporaryHome().path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            externalURLOpener: externalURLOpener.open,
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        await transport.waitForNotificationStreamCount(1)
        await store.signIn()
        #expect(externalURLOpener.openedURLs == [URL(string: "https://example.com/auth")!])
        let cancelFinished = CompletionFlag()
        let cancel = Task { @MainActor in
            await store.cancelAuthentication()
            await cancelFinished.complete()
        }
        await transport.waitForRequestCount(6)

        #expect(await cancelFinished.isCompleted() == false)
        #expect(await transport.taskCancellationStates(for: "account/login/cancel") == [false])
        try await transport.emitServerNotification(
            method: "account/login/completed",
            params: TestLoginCompletedNotification(loginID: "login-browser", success: true)
        )
        await cancelGate.open()

        await cancel.value
        #expect(store.auth.phase == .signedOut)
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

        let accountSwitch = Task { @MainActor in
            try await store.switchAccount(CodexAccount(email: "second@example.com"))
        }
        try #require(await waitUntil(timeout: .seconds(2)) {
            await firstTransport.recordedRequests().map(\.method).contains("turn/interrupt")
        })
        try await emitInterruptedTurn(
            firstTransport,
            threadID: "thread-first",
            turnID: "turn-first",
            message: "Account switched."
        )
        try await accountSwitch.value
        let result = try await reviewRead
        await secondTransport.waitForRequestCount(2)
        await firstTransport.waitForRequestCount(8)

        #expect(result.core.lifecycle.status == .cancelled)
        #expect(result.core.lifecycle.cancellation?.message == "Account switched.")
        #expect(store.auth.selectedAccount?.accountKey == "second@example.com")
        #expect(await firstTransport.recordedRequests().map(\.method).contains("turn/interrupt"))
        #expect(await secondTransport.recordedRequests().map(\.method).contains("account/read"))
    }

    @Test func accountSwitchDuringHeldLiveStartPublishesOnlyPostSwitchRuntime() async throws {
        let homeURL = try temporaryHome()
        let mainCodexHomeURL = homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        try writeRegistry(
            homeURL: homeURL,
            activeAccountKey: "first@example.com",
            accounts: ["first@example.com", "second@example.com"]
        )
        try writeSavedAccountAuth(homeURL: homeURL, accountKey: "first@example.com")
        try writeSavedAccountAuth(homeURL: homeURL, accountKey: "second@example.com")

        let firstTransport = FakeJSONRPCTransport()
        let secondTransport = FakeJSONRPCTransport()
        try await enqueueRuntimeStartResponses(firstTransport, accountEmail: "first@example.com")
        try await enqueueRuntimeStartResponses(secondTransport, accountEmail: "second@example.com")
        let heldAuthRead = AsyncGate()
        await firstTransport.holdNextIgnoringCancellation(
            method: "account/read",
            gate: heldAuthRead
        )
        var transports = [firstTransport, secondTransport]
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transportFactory: { codexHomeURL in
                #expect(codexHomeURL == mainCodexHomeURL)
                return transports.removeFirst()
            }
        )

        let initialStart = Task { @MainActor in await store.start() }
        await firstTransport.waitForRequestCount(2)
        let accountSwitch = Task { @MainActor in
            try await store.switchAccount(CodexAccount(email: "second@example.com"))
        }
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.auth.selectedAccount?.accountKey == "second@example.com"
        })

        await heldAuthRead.open()
        try await accountSwitch.value
        await initialStart.value

        #expect(store.serverState == .running)
        #expect(store.auth.selectedAccount?.accountKey == "second@example.com")
        #expect(await firstTransport.isClosedForTesting())
        #expect(transports.isEmpty)
        await store.stop()
    }

    @Test func staleAccountNotificationCannotOverwriteReplacementRuntime() async throws {
        let homeURL = try temporaryHome()
        let firstTransport = FakeJSONRPCTransport()
        let secondTransport = FakeJSONRPCTransport()
        try await enqueueRuntimeStartResponses(firstTransport, accountEmail: "first@example.com")
        try await enqueueRuntimeStartResponses(secondTransport, accountEmail: "second@example.com")
        var transports = [firstTransport, secondTransport]
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transportFactory: { _ in transports.removeFirst() }
        )
        await store.start()
        await firstTransport.waitForNotificationStreamCount(1)

        try await firstTransport.enqueue(
            AppServerAPI.Account.Read.Response(
                account: .init(email: "stale@example.com", planType: "pro")
            ),
            for: "account/read"
        )
        let staleReadGate = AsyncGate()
        await firstTransport.holdNextIgnoringCancellation(
            method: "account/read",
            gate: staleReadGate
        )
        let requestCount = await firstTransport.recordedRequests().count
        try await firstTransport.emitServerNotification(
            method: "account/updated",
            params: EmptyResponse()
        )
        await firstTransport.waitForRequestCount(requestCount + 1)

        let generationBeforeRestart = store.runtimeLifecycleAdmissionGeneration
        let restart = Task { @MainActor in await store.restart() }
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.runtimeLifecycleAdmissionGeneration > generationBeforeRestart
        })
        await staleReadGate.open()
        await restart.value

        #expect(store.serverState == .running)
        #expect(store.auth.selectedAccount?.accountKey == "second@example.com")
        #expect(store.auth.accounts.contains { $0.accountKey == "stale@example.com" } == false)
        await store.stop()
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

        let logout = Task { @MainActor in await store.logout() }
        try #require(await waitUntil(timeout: .seconds(2)) {
            await firstTransport.recordedRequests().map(\.method).contains("turn/interrupt")
        })
        try await emitInterruptedTurn(
            firstTransport,
            threadID: "thread-active",
            turnID: "turn-active",
            message: "Signed out."
        )
        await logout.value
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
        try await emitInterruptedTurn(
            transport,
            threadID: "thread-1",
            turnID: "turn-1",
            message: "Review runtime stopped."
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

    @Test func liveStoreStopBoundsStuckReviewCancellationCleanup() async throws {
        let homeURL = try temporaryHome()
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

    @Test func liveStoreStopForceClosesBeforeCleanupAfterInterruptRejection() async throws {
        let homeURL = try temporaryHome()
        let cleanupGate = AsyncGate()
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
            AppServerAPI.Review.Start.Response(turnID: "turn-1"),
            for: "review/start"
        )
        await transport.enqueueFailure(
            .responseError(code: -32000, message: "Interrupt rejected."),
            for: "turn/interrupt"
        )
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            shutdownCleanupTimeout: .seconds(5),
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        let review = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        try #require(await StoreSnapshotProbe(store: store).waitUntil { snapshot in
            snapshot.jobs.first?.activeRun?.turnID == "turn-1"
        } != nil)

        let stop = Task { @MainActor in
            await store.stop()
        }
        await transport.waitUntilClosedForTesting()
        let methodsAtBoundary = await transport.recordedRequests().map(\.method)
        let jobAtForcedCloseBoundary = try #require(store.jobs.first)
        let statusAtForcedCloseBoundary = jobAtForcedCloseBoundary.core.lifecycle.status
        let cancellationAtForcedCloseBoundary = jobAtForcedCloseBoundary.core.lifecycle.cancellation
        let cancellationWasPendingAtForcedCloseBoundary = jobAtForcedCloseBoundary.cancellationRequested
        await cleanupGate.open()
        await stop.value
        let result = try await review.value

        #expect(methodsAtBoundary.contains("thread/backgroundTerminals/clean") == false)
        #expect(methodsAtBoundary.contains("turn/interrupt"))
        #expect(statusAtForcedCloseBoundary != .failed)
        #expect(cancellationAtForcedCloseBoundary?.message == "Review runtime stopped.")
        #expect(cancellationWasPendingAtForcedCloseBoundary || statusAtForcedCloseBoundary == .cancelled)
        #expect(result.core.lifecycle.status == .cancelled && result.core.lifecycle.cancellation?.message == "Review runtime stopped.")
    }

    @Test func liveStoreStopDetachesStartingWorkerFromPreCancellationSnapshot() async throws {
        let homeURL = try temporaryHome()
        let reviewStartGate = AsyncGate()
        let transport = FakeJSONRPCTransport()
        await transport.holdNextIgnoringCancellation(method: "review/start", gate: reviewStartGate)
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
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1"), for: "review/start")
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            shutdownCleanupTimeout: .milliseconds(20),
            transport: transport
        )

        await store.start(forceRestartIfNeeded: true)
        let review = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        try #require(await waitUntil(timeout: .seconds(2)) {
            await transport.recordedRequests().contains { $0.method == "review/start" }
        })
        let job = try #require(store.jobs.first)
        guard case .starting = store.reviewAttemptOwnerships[job.id] else {
            Issue.record("Expected the held review/start to retain its starting owner.")
            return
        }

        let stop = Task { @MainActor in
            await store.stop()
        }
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.runtimeStopDetachedReviewWorkerTasks[job.id] != nil
        })
        let detachedWorker = try #require(
            store.runtimeStopDetachedReviewWorkerTasks[job.id]
        )
        let ownershipRemainedStarting: Bool
        if case .starting = store.reviewAttemptOwnerships[job.id] {
            ownershipRemainedStarting = true
        } else {
            ownershipRemainedStarting = false
        }

        #expect(store.reviewWorkerTasks[job.id] == nil)
        #expect(ownershipRemainedStarting)

        await stop.value
        let result = try #require(try await waitForTaskValue(review, timeout: .seconds(1)))
        await reviewStartGate.open()
        await detachedWorker.value

        #expect(result.core.lifecycle.status == .cancelled)
        #expect(store.reviewAttemptOwnerships[job.id] == nil)
        #expect(store.runtimeStopDetachedReviewWorkerTasks[job.id] == nil)
        #expect(await transport.isClosedForTesting())
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

        networkMonitor.yield(.init(status: .unsatisfied))
        try #require(await waitUntil(timeout: .seconds(2)) {
            await transport.recordedRequests().map(\.method).contains("turn/interrupt")
        })
        try await emitInterruptedTurn(
            transport,
            threadID: "review-thread-1",
            turnID: "turn-1",
            message: "Network recovery"
        )
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.liveReviewRecoveryRouteCountForTesting == 1
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
        #expect(store.liveReviewRecoveryRouteCountForTesting == 0)
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

    @Test func notificationFailurePublishesBeforeHeldTeardownAndExplicitStopCancelsWaitingStart() async throws {
        let homeURL = try temporaryHome()
        let stopGate = AsyncGate()
        let firstTransport = FakeJSONRPCTransport()
        let secondTransport = FakeJSONRPCTransport()
        for transport in [firstTransport, secondTransport] {
            try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
            try await transport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
            try await transport.enqueue(
                AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
                for: "config/read"
            )
            try await transport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
        }
        let firstServer = ControlledMCPHTTPServer(
            endpoint: try #require(URL(string: "http://127.0.0.1:19435/mcp")),
            stopGate: stopGate
        )
        let secondServer = ControlledMCPHTTPServer(
            endpoint: try #require(URL(string: "http://127.0.0.1:19436/mcp"))
        )
        var transports = [firstTransport, secondTransport]
        var servers = [firstServer, secondServer]
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            mcpHTTPServerFactory: { _, _ in servers.removeFirst() },
            mcpHTTPServerBindChecker: { _ in },
            transportFactory: { _ in transports.removeFirst() }
        )

        await store.start()
        await firstTransport.waitForNotificationStreamCount(1)
        await firstTransport.finishNotificationStreams(throwing: JSONRPC.Error.closed)
        try #require(await waitUntil(timeout: .seconds(2)) {
            firstServer.stopCallCount == 1
        })

        let expected = "Review runtime stopped unexpectedly: \(JSONRPC.Error.closed.localizedDescription)"
        #expect(store.serverState == .failed(expected))
        #expect(store.serverURL == nil)

        let generationBeforeStart = store.runtimeLifecycleAdmissionGeneration
        let pendingStart = Task { @MainActor in
            await store.start()
        }
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.runtimeLifecycleAdmissionGeneration > generationBeforeStart
        })
        let waitingStartGeneration = store.runtimeLifecycleAdmissionGeneration
        let explicitStop = Task { @MainActor in
            await store.stop()
        }
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.runtimeLifecycleAdmissionGeneration > waitingStartGeneration
                && store.runtimeTeardownFinalState == .stopped
        })
        #expect(store.serverState == .failed(expected))

        await stopGate.open()
        await explicitStop.value
        await pendingStart.value

        #expect(store.serverState == .stopped)
        #expect(store.serverURL == nil)
        #expect(firstServer.stopCallCount == 1)
        #expect(secondServer.startCallCount == 0)
        #expect(servers.count == 1)
        #expect(transports.count == 1)
    }

    @Test func explicitStopJoinsLiveRuntimeFailureWithoutRewritingCleanupReason() async throws {
        let homeURL = try temporaryHome()
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
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-1", model: "gpt-5"),
            for: "thread/start"
        )
        try await transport.enqueue(AppServerAPI.Review.Start.Response(turnID: "turn-1"), for: "review/start")
        try await transport.enqueue(EmptyResponse(), for: "turn/interrupt")
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            transport: transport
        )
        await store.start(forceRestartIfNeeded: true)
        let review = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.jobs.first?.core.run.turnID == "turn-1"
        })

        let failure = Task { @MainActor in
            await store.stop(intent: .unexpectedFailure("Injected live failure."))
        }
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.jobs.first?.cancellationRequested == true
        })
        let expected = "Review runtime stopped unexpectedly: Injected live failure."
        #expect(store.jobs.first?.core.lifecycle.cancellation?.message == expected)
        let explicitStop = Task { @MainActor in await store.stop() }
        try #require(await waitUntil(timeout: .seconds(2)) {
            store.runtimeTeardownFinalState == .stopped
        })
        #expect(await transport.recordedRequests().map(\.method).filter { $0 == "turn/interrupt" }.count == 1)

        await interruptGate.open()
        try await emitInterruptedTurn(
            transport,
            threadID: "thread-1",
            turnID: "turn-1",
            message: expected
        )
        await failure.value
        await explicitStop.value
        let result = try await review.value
        #expect(result.core.lifecycle.cancellation?.message == expected)
        #expect(store.serverState == .stopped)
        let methods = await transport.recordedRequests().map(\.method)
        #expect(methods.filter { $0 == "turn/interrupt" }.count == 1)
        #expect(methods.filter { $0 == "thread/delete" }.count == 1)
    }

    @Test func liveStoreReplaysExecutableResolutionFailureWithoutTransportSearch() async throws {
        let homeURL = try temporaryHome()
        var transportFactoryCalls = 0
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            codexExecutableResolver: makeResolver(),
            webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
            resolvedTransportFactory: { _, _ in
                transportFactoryCalls += 1
                return FakeJSONRPCTransport()
            }
        )

        await store.start(forceRestartIfNeeded: true)
        let firstFailure = store.serverState
        await store.start(forceRestartIfNeeded: true)

        #expect(store.serverState == firstFailure)
        #expect(transportFactoryCalls == 0)
        guard case .failed(let message) = firstFailure else {
            Issue.record("Expected executable resolution failure.")
            return
        }
        #expect(message.contains("No usable Codex executable was found."))
    }

    @Test func liveStoreUsesOneExecutableForPrimaryAndStagingAndCleansLoginOnFailure() async throws {
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
                loginID: "login-1",
                authURL: "https://example.com/auth",
                nativeWebAuthentication: .init(callbackURLScheme: "lynnpd.CodexReviewMonitor.auth")
            ),
            for: "account/login/start"
        )
        let sessions = FakeWebAuthenticationSessions()
        var isolatedCodexHomeURL: URL?
        let executableURL = URL(fileURLWithPath: "/resolved/codex")
        var runtimeExecutables: [URL] = []
        let store = CodexReviewStore.makeLiveStoreForTesting(
            environment: ["HOME": homeURL.path],
            runtimePreferences: .init(codexExecutablePath: executableURL.path),
            codexExecutableResolver: makeResolver(executables: [executableURL.path]),
            nativeAuthenticationConfiguration: .init(
                callbackScheme: "lynnpd.CodexReviewMonitor.auth",
                browserSessionPolicy: .ephemeral,
                presentationAnchorProvider: { NSWindow() }
            ),
            webAuthenticationSessionFactory: sessions.makeSession,
            resolvedTransportFactory: { codexHomeURL, resolvedExecutableURL in
                runtimeExecutables.append(resolvedExecutableURL)
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
        #expect(runtimeExecutables == [executableURL, executableURL])
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
    private var creationGate: AsyncGate?
    private var creationStartedGate = AsyncGate()

    var createdSessionCount: Int {
        sessionCount
    }

    func makeSession(
        url _: URL,
        callbackScheme _: String,
        browserSessionPolicy _: CodexReviewNativeAuthentication.Configuration.BrowserSessionPolicy,
        presentationAnchorProvider _: @escaping @MainActor @Sendable () -> ASPresentationAnchor?
    ) async throws -> any CodexReviewNativeAuthentication.WebSession {
        if let creationGate {
            await creationStartedGate.open()
            await creationGate.waitIgnoringCancellation()
            self.creationGate = nil
        }
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

    func holdNextCreation(with gate: AsyncGate) {
        creationGate = gate
        creationStartedGate = AsyncGate()
    }

    func waitForCreationStarted() async {
        await creationStartedGate.wait()
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
    private var cancellationGate: AsyncGate?
    private var cancellationStarted = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

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
        cancellationStarted = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        if let cancellationGate {
            await cancellationGate.waitIgnoringCancellation()
        }
        resume(throwing: CodexReviewNativeAuthenticationError.cancelled)
    }

    func holdCancellation(with gate: AsyncGate) {
        cancellationGate = gate
    }

    func waitUntilCancellationStarted() async {
        if cancellationStarted {
            return
        }
        await withCheckedContinuation { continuation in
            if cancellationStarted {
                continuation.resume()
            } else {
                cancellationWaiters.append(continuation)
            }
        }
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

private func enqueueRuntimeStartResponses(
    _ transport: FakeJSONRPCTransport,
    accountEmail: String? = nil
) async throws {
    try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
    if let accountEmail {
        try await transport.enqueue(
            AppServerAPI.Account.Read.Response(
                account: .init(email: accountEmail, planType: "pro")
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
    } else {
        try await transport.enqueue(AppServerAPI.Account.Read.Response(), for: "account/read")
    }
    try await transport.enqueue(
        AppServerAPI.Config.Read.Response(config: .init(model: "gpt-5")),
        for: "config/read"
    )
    try await transport.enqueue(AppServerAPI.Model.List.Response(data: []), for: "model/list")
}

private func makeLiveRouteReviewStartRequest(
    jobID: String
) -> CodexReviewBackendModel.Review.Start {
    .init(
        jobID: jobID,
        sessionID: "route-session",
        request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
        model: "gpt-5"
    )
}

private func enqueueLiveRouteReviewStartResponses(
    _ transport: FakeJSONRPCTransport,
    threadID: String,
    turnID: String,
    reviewThreadID: String
) async throws {
    try await transport.enqueue(
        AppServerAPI.Thread.Start.Response(threadID: threadID, model: "gpt-5"),
        for: "thread/start"
    )
    try await transport.enqueue(
        AppServerAPI.Review.Start.Response(
            turnID: turnID,
            reviewThreadID: reviewThreadID
        ),
        for: "review/start"
    )
}

private func enqueueReviewCleanupResponses(
    _ transport: FakeJSONRPCTransport
) async throws {
    try await transport.enqueue(
        AppServerAPI.Thread.Unsubscribe.Response(status: .unsubscribed),
        for: "thread/unsubscribe"
    )
}

private func makeRecoveryCandidate(
    for run: CodexReviewBackendModel.Review.Run
) async throws -> ReviewRecoveryCandidate {
    let admission = ReviewStartAdmission()
    try await admission.recordPreparedRecoveryRun(run)
    try await admission.admitReviewStartDispatch(for: run)
    try await admission.recordActiveRun(run)
    let requestStarted = AsyncGate()
    let task = Task {
        try await admission.beginRecovery(
            run,
            trigger: .sameAccountRestart,
            request: { _, _ in await requestStarted.open() }
        )
    }
    await requestStarted.wait()
    try await admission.recordCanonicalTerminal(
        .interrupted(.server(message: "Prepare replacement")),
        for: run
    )
    guard case .replacement(let candidate) = try await task.value else {
        throw ReviewAttemptContractFailure(message: "Expected a recovery candidate.")
    }
    return candidate
}

@MainActor
private struct LiveTypedRecoveryFixture {
    var store: CodexReviewStore
    var source: FakeJSONRPCTransport
    var destination: FakeJSONRPCTransport
    var request: CodexReviewBackendModel.Review.Start
    var prepared: PreparedReviewRecovery
    var destinationGeneration: ReviewRuntimeGeneration
}
@MainActor
private func makeLiveTypedRecoveryFixture(
    outcomeUnknown: Bool = false
) async throws -> LiveTypedRecoveryFixture {
    let source = FakeJSONRPCTransport()
    let destination = FakeJSONRPCTransport()
    try await enqueueRuntimeStartResponses(source)
    try await enqueueRuntimeStartResponses(destination)
    try await enqueueLiveRouteReviewStartResponses(
        source,
        threadID: "typed-stage-thread",
        turnID: "typed-stage-source-turn",
        reviewThreadID: "typed-stage-source-review"
    )
    try await destination.enqueue(EmptyResponse(), for: "thread/rollback")
    if outcomeUnknown {
        await destination.enqueueCancellation(for: "review/start")
    } else {
        try await destination.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "typed-stage-destination-turn",
                reviewThreadID: "typed-stage-destination-review"
            ),
            for: "review/start"
        )
    }
    try await enqueueReviewCleanupResponses(destination)
    var transports = [source, destination]
    let store = CodexReviewStore.makeLiveStoreForTesting(
        environment: ["HOME": try temporaryHome().path],
        webAuthenticationSessionFactory: FakeWebAuthenticationSessions().makeSession,
        transportFactory: { _ in transports.removeFirst() }
    )
    await store.start()
    let request = makeLiveRouteReviewStartRequest(jobID: "job-typed-stage")
    let attempt = try await store.backend.startReview(
        request,
        admission: ReviewStartAdmission()
    )
    let candidate = try await makeRecoveryCandidate(for: attempt.run)
    let prepared = try await store.backend.prepareReviewRecovery(candidate)
    await store.restart()
    return .init(
        store: store,
        source: source,
        destination: destination,
        request: request,
        prepared: prepared,
        destinationGeneration: .init(rawValue: store.runtimeLifecycleAdmissionGeneration)
    )
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

private func emitInterruptedTurn(
    _ transport: FakeJSONRPCTransport,
    threadID: String,
    turnID: String,
    message: String
) async throws {
    try await transport.emitServerNotification(
        method: "turn/completed",
        params: InterruptedTurnNotification(
            threadID: threadID,
            turn: .init(id: turnID, error: .init(message: message))
        )
    )
}

@MainActor
private func waitForRuntimeLifecycleSettlement(
    _ store: CodexReviewStore
) async {
    while true {
        switch store.runtimeState {
        case .acquiring(_, _, let task),
             .replacing(_, let task),
             .tearingDown(_, _, _, _, let task):
            await task.value
        case .stopped, .running, .failed:
            return
        }
    }
}

private struct InterruptedTurnNotification: Encodable, Sendable {
    struct Turn: Encodable, Sendable {
        struct Error: Encodable, Sendable { let message: String }
        let id: String
        let status = "interrupted"
        let items: [String] = []
        let error: Error
    }

    let threadID: String
    let turn: Turn

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
    }
}

private func failedMessage(from phase: CodexReviewAuthModel.Phase) -> String? {
    guard case .failed(let message) = phase else {
        return nil
    }
    return message
}

@MainActor
private final class ControlledMCPHTTPServer: CodexReviewMCPHTTPServing {
    let endpoint: URL
    private let startFailure: HostCloseFailure?
    private let stopFailure: HostCloseFailure?
    private let stopGate: AsyncGate?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    init(
        endpoint: URL,
        startFailure: HostCloseFailure? = nil,
        stopFailure: HostCloseFailure? = nil,
        stopGate: AsyncGate? = nil
    ) {
        self.endpoint = endpoint
        self.startFailure = startFailure
        self.stopFailure = stopFailure
        self.stopGate = stopGate
    }

    var url: URL {
        get async {
            endpoint
        }
    }

    func start() async throws {
        startCallCount += 1
        if let startFailure {
            throw startFailure
        }
    }

    func stop() async throws {
        stopCallCount += 1
        if let stopGate {
            await stopGate.wait()
        }
        if let stopFailure {
            throw stopFailure
        }
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

    func stop() async throws {}
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
