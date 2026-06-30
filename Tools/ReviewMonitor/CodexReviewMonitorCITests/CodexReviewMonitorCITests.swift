import AppKit
import Foundation
import CodexReviewKit
import CodexReviewHost
@testable import ReviewUI
import ReviewUIPreviewSupport
import Testing
@testable import CodexReviewMonitor

@Suite(.serialized)
@MainActor
struct CodexReviewMonitorCITests {
    @Test func ciSchemeBuildsPreviewLaunchContextWithoutStartingServer() {
        let environment = ProcessInfo.processInfo.environment
        let context = ReviewMonitorLaunchContext(
            environment: environment,
            arguments: []
        )

        #expect(environment[ReviewMonitorLaunchEnvironment.reviewModeKey] == "1")
        #expect(context.requestsPreviewContent)
        #expect(context.shouldStartEmbeddedServer == false)
    }

    @Test func hostedUnitTestLaunchDisablesEmbeddedServer() {
        let environment = [
            ReviewMonitorLaunchEnvironment.xcInjectBundleIntoKey: "/tmp/ReviewMonitor",
            ReviewMonitorLaunchEnvironment.xctestBundlePathKey: "/tmp/HostedUnitTests.xctest",
            ReviewMonitorLaunchEnvironment.xctestSessionIdentifierKey: "session-123",
        ]

        #expect(
            ReviewMonitorLaunchEnvironment.launchMode(
                environment: environment,
                arguments: []
            ) == .xctest
        )
        #expect(
            ReviewMonitorLaunchEnvironment.shouldStartEmbeddedServer(
                environment: environment,
                arguments: []
            ) == false
        )
    }

    @Test func lifecycleUsesInjectedStoreWithoutTimingDelays() async {
        let store = FakeLifecycleStore()
        let lifecycle = ReviewMonitorLifecycleController(store: store)
        let responder = TerminationReplyRecorder()

        lifecycle.applicationDidFinishLaunching(launchMode: .application)
        await store.startSignal.wait()

        #expect(store.startArguments == [true])
        #expect(store.stopCallCount == 0)

        let firstReply = lifecycle.applicationShouldTerminate(replyingTo: responder)
        #expect(firstReply == .terminateLater)

        await store.stopStartedSignal.wait()
        #expect(store.stopCallCount == 1)
        #expect(responder.replies.isEmpty)

        let secondReply = lifecycle.applicationShouldTerminate(replyingTo: responder)
        #expect(secondReply == .terminateLater)
        #expect(store.stopCallCount == 1)

        await store.stopGate.open()
        let reply = await responder.waitForReply()

        #expect(reply == true)
        #expect(responder.replies == [true])
    }

    @Test func appDelegateUsesInjectedCompositionForStartupDependencies() {
        let previousMainMenu = NSApp.mainMenu
        let previousServicesMenu = NSApp.servicesMenu
        let previousWindowsMenu = NSApp.windowsMenu
        defer {
            NSApp.mainMenu = previousMainMenu
            NSApp.servicesMenu = previousServicesMenu
            NSApp.windowsMenu = previousWindowsMenu
        }

        let expectedStore = CodexReviewStore.makePreviewStore()
        var capturedContext: ReviewMonitorLaunchContext?
        var capturedShowSettings: (@MainActor () -> Void)?
        let recorder = WindowControllerFactoryRecorder()
        let settingsWindowController = CountingWindowController()
        let composition = ReviewMonitorAppComposition(
            makeDependencies: { context, _ in
                capturedContext = context
                return ReviewMonitorAppDependencies(store: expectedStore)
            },
            makeWindowController: { dependencies, showSettings in
                #expect(dependencies.store === expectedStore)
                #expect(dependencies.previewContent == nil)
                capturedShowSettings = showSettings
                return recorder.makeWindowController()
            },
            makeSettingsWindowController: {
                settingsWindowController
            }
        )
        let delegate = ReviewMonitorAppDelegate(
            launchContextProvider: {
                ReviewMonitorLaunchContext(
                    environment: [
                        ReviewMonitorLaunchEnvironment.reviewModeKey: "1",
                    ],
                    arguments: [],
                    launchMode: .application
                )
            },
            composition: composition
        )

        delegate.applicationDidFinishLaunching(Notification(name: .init("ci-test-launch")))

        guard let capturedContext else {
            Issue.record("Expected the store factory to receive a launch context.")
            return
        }
        let windowController = recorder.lastWindowController
        #expect(capturedContext.launchMode == .application)
        #expect(capturedContext.requestsPreviewContent)
        #expect(capturedContext.shouldStartEmbeddedServer == false)
        #expect(recorder.makeCallCount == 1)
        #expect(delegate.windowController === windowController)
        #expect(windowController?.showWindowCallCount == 1)
        #expect(windowController?.windowForTesting.makeKeyAndOrderFrontCallCount == 1)

        capturedShowSettings?()
        #expect(delegate.settingsWindowController === settingsWindowController)
        #expect(settingsWindowController.showWindowCallCount == 1)
    }

    @Test func appDelegateInstallsSettingsMenuItem() {
        let previousMainMenu = NSApp.mainMenu
        let previousServicesMenu = NSApp.servicesMenu
        let previousWindowsMenu = NSApp.windowsMenu
        defer {
            NSApp.mainMenu = previousMainMenu
            NSApp.servicesMenu = previousServicesMenu
            NSApp.windowsMenu = previousWindowsMenu
        }

        let composition = ReviewMonitorAppComposition(
            makeDependencies: { _, _ in
                ReviewMonitorAppDependencies(store: CodexReviewStore.makePreviewStore())
            },
            makeWindowController: { _, _ in
                CountingWindowController()
            }
        )
        let delegate = ReviewMonitorAppDelegate(
            launchContextProvider: {
                ReviewMonitorLaunchContext(
                    environment: [:],
                    arguments: [],
                    launchMode: .xctest
                )
            },
            composition: composition
        )

        delegate.applicationDidFinishLaunching(Notification(name: .init("ci-test-launch")))

        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else {
            Issue.record("Expected the application menu to be installed.")
            return
        }
        let settingsItem = appMenu.item(withTitle: "Settings…")
        let quitItem = appMenu.items.first {
            $0.action == #selector(NSApplication.terminate(_:))
        }

        #expect(settingsItem?.action == #selector(ReviewMonitorAppDelegate.showSettingsWindow(_:)))
        #expect(settingsItem?.target === delegate)
        #expect(settingsItem?.keyEquivalent == ",")
        #expect(settingsItem?.keyEquivalentModifierMask == [.command])
        if let settingsItem,
           let quitItem
        {
            let settingsIndex = appMenu.index(of: settingsItem)
            let quitIndex = appMenu.index(of: quitItem)
            #expect(settingsIndex < quitIndex)
        } else {
            Issue.record("Expected Settings and Quit menu items.")
        }
    }

    @Test func appDelegateShowsInjectedSettingsWindowController() {
        let settingsWindowController = CountingWindowController()
        let composition = ReviewMonitorAppComposition(
            makeDependencies: { _, _ in
                ReviewMonitorAppDependencies(store: CodexReviewStore.makePreviewStore())
            },
            makeWindowController: { _, _ in
                CountingWindowController()
            },
            makeSettingsWindowController: {
                settingsWindowController
            }
        )
        let delegate = ReviewMonitorAppDelegate(
            launchContextProvider: {
                ReviewMonitorLaunchContext(
                    environment: [:],
                    arguments: [],
                    launchMode: .xctest
                )
            },
            composition: composition
        )

        delegate.showSettingsWindow(nil)

        #expect(delegate.settingsWindowController === settingsWindowController)
        #expect(settingsWindowController.showWindowCallCount == 1)
    }

    @Test func liveCompositionUsesPreviewStoreWhenPreviewContentIsRequested() {
        let runtimePreferencesStore = FailingRuntimePreferencesStore()
        var didCallLiveStoreFactory = false
        let composition = ReviewMonitorAppComposition.live(
            runtimePreferencesStore: runtimePreferencesStore,
            makeLiveStore: { _, _, _ in
                didCallLiveStoreFactory = true
                Issue.record("Preview store creation should not build a live store.")
                return CodexReviewStore.makePreviewStore()
            }
        )
        let context = ReviewMonitorLaunchContext(
            environment: [
                ReviewMonitorLaunchEnvironment.reviewModeKey: "1",
            ],
            arguments: [],
            launchMode: .application
        )
        var didRequestPresentationAnchor = false

        let dependencies = composition.makeDependencies(context) {
            didRequestPresentationAnchor = true
            Issue.record("Preview store creation should not request a presentation anchor.")
            return nil
        }

        #expect(dependencies.previewContent != nil)
        #expect(dependencies.previewContent?.store === dependencies.store)
        #expect(didRequestPresentationAnchor == false)
        #expect(didCallLiveStoreFactory == false)
        #expect(context.shouldStartEmbeddedServer == false)
    }

    @Test func liveCompositionPreviewWindowRendersPreviewChatLog() async throws {
        let runtimePreferencesStore = FailingRuntimePreferencesStore()
        var didCallLiveStoreFactory = false
        let composition = ReviewMonitorAppComposition.live(
            runtimePreferencesStore: runtimePreferencesStore,
            makeLiveStore: { _, _, _ in
                didCallLiveStoreFactory = true
                Issue.record("Preview window creation should not build a live store.")
                return CodexReviewStore.makePreviewStore()
            }
        )
        let context = ReviewMonitorLaunchContext(
            environment: [
                ReviewMonitorLaunchEnvironment.reviewModeKey: "1",
            ],
            arguments: [],
            launchMode: .application
        )
        let dependencies = composition.makeDependencies(context) {
            Issue.record("Preview store creation should not request a presentation anchor.")
            return nil
        }

        let windowController = composition.makeWindowController(dependencies) {}
        let rootViewController = try #require(
            windowController.window?.contentViewController as? ReviewMonitorRootViewController
        )
        rootViewController.prepareForSwiftUIPreviewRendering()

        let sidebar = rootViewController.splitViewControllerForTesting.sidebarViewControllerForTesting
        try await waitForPreviewCondition {
            sidebar.sidebarKindForTesting == .chatList
                && sidebar.displayedCodexSidebarTitlesForTesting.contains("workspace-alpha")
                && sidebar.displayedCodexSidebarTitlesForTesting.contains("Branch: feature/workspace-alpha-sidebar")
        }
        #expect(sidebar.isShowingEmptyStateForTesting == false)

        let transport = rootViewController.splitViewControllerForTesting.transportViewControllerForTesting
        let initialSnapshot = try await awaitPreviewTransportRender(transport) { snapshot in
            snapshot.log.isEmpty == false && snapshot.isShowingEmptyState == false
        }

        #expect(didCallLiveStoreFactory == false)
        if case .chat? = transport.renderedStateForTesting.selection {
        } else {
            Issue.record("Expected preview window to select a chat.")
        }
        #expect(initialSnapshot.log.isEmpty == false)

        let nextTick = try #require(await rootViewController.appendPreviewChatLogStreamTickForTesting())
        #expect(nextTick == 1)
        let updatedSnapshot = try await awaitPreviewTransportRender(transport) { snapshot in
            snapshot.log.count > initialSnapshot.log.count
                && snapshot.log.contains("Turn started")
                && snapshot.isShowingEmptyState == false
        }
        #expect(updatedSnapshot.log.contains("Turn started"))
    }

    @Test func liveCompositionPassesLoadedRuntimePreferencesToApplicationStoreFactory() {
        let expectedRuntimePreferences = CodexReviewRuntime.Preferences(
            codexHomePath: FileManager.default.temporaryDirectory
                .appending(path: "codex-review-monitor-ci-\(UUID().uuidString)", directoryHint: .isDirectory)
                .path,
            mcpHost: "localhost",
            mcpPort: 54321,
            mcpPath: "/custom-mcp",
            codexExecutablePath: "/tmp/codex"
        )
        let runtimePreferencesStore = RuntimePreferencesStoreStub(
            preferences: expectedRuntimePreferences
        )
        let expectedStore = CodexReviewStore.makePreviewStore()
        var capturedRuntimePreferences: CodexReviewRuntime.Preferences?
        var capturedAuthenticationConfiguration: CodexReviewNativeAuthentication.Configuration?
        let composition = ReviewMonitorAppComposition.live(
            runtimePreferencesStore: runtimePreferencesStore,
            makeLiveStore: { runtimePreferences, authenticationConfiguration, _ in
                capturedRuntimePreferences = runtimePreferences
                capturedAuthenticationConfiguration = authenticationConfiguration
                return expectedStore
            }
        )
        let context = ReviewMonitorLaunchContext(
            environment: [:],
            arguments: [],
            launchMode: .application
        )
        var didRequestPresentationAnchor = false

        let dependencies = composition.makeDependencies(context) {
            didRequestPresentationAnchor = true
            return nil
        }
        let store = dependencies.store

        #expect(store === expectedStore)
        #expect(dependencies.previewContent == nil)
        #expect(capturedRuntimePreferences == expectedRuntimePreferences)
        #expect(didRequestPresentationAnchor == false)
        #expect(capturedAuthenticationConfiguration?.callbackScheme == "lynnpd.CodexReviewMonitor.auth")
        if case .ephemeral? = capturedAuthenticationConfiguration?.browserSessionPolicy {
        } else {
            Issue.record("Expected ReviewMonitor to use an ephemeral browser session.")
        }
        #expect(capturedAuthenticationConfiguration?.presentationAnchorProvider() == nil)
        #expect(didRequestPresentationAnchor)
    }

    @Test func liveCompositionPassesAppServerLifecycleHandlerToLiveStoreFactory() {
        let runtimePreferencesStore = RuntimePreferencesStoreStub()
        let expectedStore = CodexReviewStore.makePreviewStore()
        var capturedLifecycleHandler: CodexReviewAppServerLifecycleHandler?
        let composition = ReviewMonitorAppComposition.live(
            runtimePreferencesStore: runtimePreferencesStore,
            makeLiveStore: { _, _, appServerLifecycleHandler in
                capturedLifecycleHandler = appServerLifecycleHandler
                return expectedStore
            }
        )
        let context = ReviewMonitorLaunchContext(
            environment: [:],
            arguments: [],
            launchMode: .application
        )

        let dependencies = composition.makeDependencies(context) { nil }
        let store = dependencies.store

        #expect(store === expectedStore)
        #expect(dependencies.previewContent == nil)
        #expect(capturedLifecycleHandler != nil)
    }

    @Test func liveCompositionBuildsLifecycleFromLaunchContext() async {
        let store = FakeLifecycleStore()
        let lifecycle = ReviewMonitorAppComposition.live().makeLifecycleController(
            store,
            ReviewMonitorLaunchContext(
                environment: [:],
                arguments: [],
                launchMode: .application
            )
        )

        lifecycle.applicationDidFinishLaunching(launchMode: .application)
        await store.startSignal.wait()

        #expect(store.startArguments == [true])
    }

    @Test func settingsWindowUsesAppKitPreferenceShell() {
        let controller = ReviewMonitorSettingsWindowController(
            runtimePreferencesStore: RuntimePreferencesStoreStub()
        )

        guard let window = controller.window,
              let tabViewController = controller.contentViewController as? NSTabViewController
        else {
            Issue.record("Expected a settings window with a tab view controller.")
            return
        }

        #expect(window.styleMask == [.closable, .titled])
        #expect(window.toolbarStyle == .preference)
        #expect(window.collectionBehavior.contains(.auxiliary))
        #expect(tabViewController.tabStyle == .toolbar)
        #expect(tabViewController.tabViewItems.map(\.label) == ["Runtime"])
    }

    @Test func runtimeSettingsPaneSavesNormalizedRuntimePreferences() {
        let initialPreferences = CodexReviewRuntime.Preferences(
            codexHomePath: "/tmp/codex-home",
            mcpHost: "localhost",
            mcpPort: 1234,
            mcpPath: "/initial-mcp",
            codexExecutablePath: "/tmp/codex"
        )
        let store = RuntimePreferencesStoreStub(preferences: initialPreferences)
        let settingsWindowController = ReviewMonitorSettingsWindowController(
            runtimePreferencesStore: store
        )
        guard let tabViewController = settingsWindowController.contentViewController as? NSTabViewController,
              let runtimeViewController = tabViewController.tabViewItems.first?.viewController as? ReviewMonitorRuntimeSettingsViewController
        else {
            Issue.record("Expected the Runtime settings pane.")
            return
        }

        let formState = runtimeViewController.formState
        #expect(formState.mcpHost == initialPreferences.mcpHost)
        #expect(formState.mcpPath == initialPreferences.mcpPath)
        #expect(formState.statusMessage == "")
        #expect(!formState.hasUnsavedChanges)
        #expect(!formState.canSavePreferences)
        #expect(formState.canRestoreDefaults)
        #expect(formState.validationMessage == nil)

        formState.codexHomePath = "   "
        formState.mcpHost = "   "
        formState.mcpPort = "   "
        formState.mcpPath = "custom-mcp"
        formState.codexExecutablePath = "  /tmp/custom-codex  "
        #expect(formState.hasUnsavedChanges)
        #expect(formState.canSavePreferences)
        runtimeViewController.savePreferences(nil)

        #expect(store.savedPreferences == [
            CodexReviewRuntime.Preferences(
                codexHomePath: nil,
                mcpHost: "localhost",
                mcpPort: 9417,
                mcpPath: "/custom-mcp",
                codexExecutablePath: "/tmp/custom-codex"
            ),
        ])
        #expect(formState.statusMessage == "Saved. Restart ReviewMonitor to apply changes.")
        #expect(!formState.saveFailed)
        #expect(!formState.hasUnsavedChanges)
        #expect(formState.canRestoreDefaults)
        #expect(!formState.canSavePreferences)
    }

    @Test func runtimeSettingsPanePreservesFallbackCodexHomeWhenEditingOtherFields() {
        let store = RuntimePreferencesStoreStub(preferences: .defaults)
        let settingsWindowController = ReviewMonitorSettingsWindowController(
            runtimePreferencesStore: store
        )
        guard let tabViewController = settingsWindowController.contentViewController as? NSTabViewController,
              let runtimeViewController = tabViewController.tabViewItems.first?.viewController as? ReviewMonitorRuntimeSettingsViewController
        else {
            Issue.record("Expected the Runtime settings pane.")
            return
        }

        let formState = runtimeViewController.formState
        #expect(!formState.hasUnsavedChanges)

        formState.mcpPath = "custom-mcp"
        runtimeViewController.savePreferences(nil)

        #expect(store.savedPreferences == [
            CodexReviewRuntime.Preferences(
                codexHomePath: nil,
                mcpPath: "/custom-mcp"
            ),
        ])
    }

    @Test func runtimeSettingsPaneRejectsInvalidInputBeforeSaving() {
        let store = RuntimePreferencesStoreStub()
        let settingsWindowController = ReviewMonitorSettingsWindowController(
            runtimePreferencesStore: store
        )
        guard let tabViewController = settingsWindowController.contentViewController as? NSTabViewController,
              let runtimeViewController = tabViewController.tabViewItems.first?.viewController as? ReviewMonitorRuntimeSettingsViewController
        else {
            Issue.record("Expected the Runtime settings pane.")
            return
        }

        let formState = runtimeViewController.formState
        formState.mcpPort = "70000"

        #expect(formState.validationMessage == "MCP port must be a number from 1 to 65535.")
        #expect(formState.hasUnsavedChanges)
        #expect(!formState.canSavePreferences)
        runtimeViewController.savePreferences(nil)
        #expect(store.savedPreferences.isEmpty)
        #expect(formState.statusMessage == "MCP port must be a number from 1 to 65535.")
        #expect(formState.saveFailed)

        formState.mcpPort = "9417"
        formState.codexExecutablePath = "bin/codex"

        #expect(formState.validationMessage == "Codex executable must start with / or ~/.")
        #expect(formState.hasUnsavedChanges)
        #expect(!formState.canSavePreferences)
        runtimeViewController.savePreferences(nil)
        #expect(store.savedPreferences.isEmpty)
        #expect(formState.statusMessage == "Codex executable must start with / or ~/.")
        #expect(formState.saveFailed)

        formState.codexExecutablePath = ""
        for invalidHost in [
            "localhost:9417",
            "http://localhost",
            "::1",
            "[::1]",
            "256.256.256.256",
            "-foo",
            "..",
        ] {
            formState.mcpHost = invalidHost

            #expect(formState.validationMessage == "MCP host must be a host name or IPv4 address without a scheme or port.")
            #expect(formState.hasUnsavedChanges)
            #expect(!formState.canSavePreferences)
            runtimeViewController.savePreferences(nil)
            #expect(store.savedPreferences.isEmpty)
            #expect(formState.statusMessage == "MCP host must be a host name or IPv4 address without a scheme or port.")
            #expect(formState.saveFailed)
        }

        formState.mcpHost = "localhost"
        for invalidPath in ["custom mcp", "/custom?mcp", "/custom#mcp", "/custom%20mcp"] {
            formState.mcpPath = invalidPath

            #expect(formState.validationMessage == "MCP path must be a URL path that does not require escaping.")
            #expect(formState.hasUnsavedChanges)
            #expect(!formState.canSavePreferences)
            runtimeViewController.savePreferences(nil)
            #expect(store.savedPreferences.isEmpty)
            #expect(formState.statusMessage == "MCP path must be a URL path that does not require escaping.")
            #expect(formState.saveFailed)
        }
    }

    @Test func runtimeSettingsPaneRestoresDefaultsBeforeSaving() {
        let store = RuntimePreferencesStoreStub(
            preferences: CodexReviewRuntime.Preferences(
                codexHomePath: "/tmp/codex-home",
                mcpHost: "localhost",
                mcpPort: 1234,
                mcpPath: "/custom-mcp",
                codexExecutablePath: "/tmp/codex"
            )
        )
        let settingsWindowController = ReviewMonitorSettingsWindowController(
            runtimePreferencesStore: store
        )
        guard let tabViewController = settingsWindowController.contentViewController as? NSTabViewController,
              let runtimeViewController = tabViewController.tabViewItems.first?.viewController as? ReviewMonitorRuntimeSettingsViewController
        else {
            Issue.record("Expected the Runtime settings pane.")
            return
        }

        let formState = runtimeViewController.formState
        formState.restoreDefaults()

        #expect(formState.hasUnsavedChanges)
        #expect(formState.canSavePreferences)
        #expect(!formState.canRestoreDefaults)
        #expect(store.savedPreferences.isEmpty)

        runtimeViewController.savePreferences(nil)

        #expect(store.savedPreferences == [.defaults])
        #expect(!formState.hasUnsavedChanges)
        #expect(!formState.canSavePreferences)
        #expect(!formState.canRestoreDefaults)
    }

    @Test func appDelegateInstallsFindMenuWithoutLiveServices() {
        let previousMainMenu = NSApp.mainMenu
        let previousServicesMenu = NSApp.servicesMenu
        let previousWindowsMenu = NSApp.windowsMenu
        defer {
            NSApp.mainMenu = previousMainMenu
            NSApp.servicesMenu = previousServicesMenu
            NSApp.windowsMenu = previousWindowsMenu
        }

        let composition = ReviewMonitorAppComposition(
            makeDependencies: { _, _ in
                ReviewMonitorAppDependencies(store: CodexReviewStore.makePreviewStore())
            },
            makeWindowController: { _, _ in
                CountingWindowController()
            }
        )
        let delegate = ReviewMonitorAppDelegate(
            launchContextProvider: {
                ReviewMonitorLaunchContext(
                    environment: [:],
                    arguments: [],
                    launchMode: .xctest
                )
            },
            composition: composition
        )

        delegate.applicationDidFinishLaunching(Notification(name: .init("ci-test-launch")))

        guard let editMenu = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { $0.title == "Edit" }),
              let findMenu = editMenu.item(withTitle: "Find")?.submenu
        else {
            Issue.record("Expected the app delegate to install Edit > Find.")
            return
        }
        expectTextFinderMenuItem(
            findMenu.item(withTitle: "Find..."),
            action: .showFindInterface,
            keyEquivalent: "f",
            modifierMask: [.command]
        )
        expectTextFinderMenuItem(
            findMenu.item(withTitle: "Find Next"),
            action: .nextMatch,
            keyEquivalent: "g",
            modifierMask: [.command]
        )
        expectTextFinderMenuItem(
            findMenu.item(withTitle: "Find Previous"),
            action: .previousMatch,
            keyEquivalent: "g",
            modifierMask: [.command, .shift]
        )
    }
}

@MainActor
private func expectTextFinderMenuItem(
    _ item: NSMenuItem?,
    action: NSTextFinder.Action,
    keyEquivalent: String,
    modifierMask: NSEvent.ModifierFlags
) {
    guard let item else {
        Issue.record("Expected text finder menu item.")
        return
    }
    #expect(item.action == #selector(NSResponder.performTextFinderAction(_:)))
    #expect(item.tag == action.rawValue)
    #expect(item.keyEquivalent == keyEquivalent)
    #expect(item.keyEquivalentModifierMask == modifierMask)
}

@MainActor
private final class FakeLifecycleStore: ReviewMonitorLifecycleStore {
    private(set) var startArguments: [Bool] = []
    private(set) var stopCallCount = 0
    let startSignal = TestSignal()
    let stopStartedSignal = TestSignal()
    let stopGate = TestGate()

    func start(forceRestartIfNeeded: Bool) async {
        startArguments.append(forceRestartIfNeeded)
        await startSignal.signal()
    }

    func stop() async {
        stopCallCount += 1
        await stopStartedSignal.signal()
        await stopGate.wait()
    }
}

@MainActor
private final class RuntimePreferencesStoreStub: CodexReviewRuntime.PreferencesStore {
    private var preferences: CodexReviewRuntime.Preferences
    private(set) var savedPreferences: [CodexReviewRuntime.Preferences] = []

    init(preferences: CodexReviewRuntime.Preferences = .defaults) {
        self.preferences = preferences
    }

    func load() -> CodexReviewRuntime.Preferences {
        return preferences
    }

    func save(_ preferences: CodexReviewRuntime.Preferences) throws {
        self.preferences = preferences
        savedPreferences.append(preferences)
    }
}

@MainActor
private final class FailingRuntimePreferencesStore: CodexReviewRuntime.PreferencesStore {
    func load() -> CodexReviewRuntime.Preferences {
        Issue.record("Preview store creation should not load runtime preferences.")
        return .defaults
    }

    func save(_: CodexReviewRuntime.Preferences) throws {
        Issue.record("Preview store creation should not save runtime preferences.")
    }
}

@MainActor
private final class TerminationReplyRecorder: ReviewMonitorTerminationReplying {
    private let repliesQueue = TestValueQueue<Bool>()
    private(set) var replies: [Bool] = []

    func replyToApplicationShouldTerminate(_ shouldTerminate: Bool) {
        replies.append(shouldTerminate)
        Task {
            await repliesQueue.push(shouldTerminate)
        }
    }

    func waitForReply() async -> Bool? {
        await repliesQueue.next()
    }
}

private actor TestSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignaled = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func wait() async {
        guard isSignaled == false else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func wait() async {
        guard isOpen == false else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor TestValueQueue<Value: Sendable> {
    private var values: [Value] = []
    private var waiters: [CheckedContinuation<Value, Never>] = []

    func push(_ value: Value) {
        if waiters.isEmpty {
            values.append(value)
            return
        }
        let continuation = waiters.removeFirst()
        continuation.resume(returning: value)
    }

    func next() async -> Value {
        if values.isEmpty == false {
            return values.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

@MainActor
private func awaitPreviewTransportRender(
    _ transport: ReviewMonitorTransportViewController,
    matching predicate: (ReviewMonitorTransportViewController.RenderSnapshotForTesting) -> Bool
) async throws -> ReviewMonitorTransportViewController.RenderSnapshotForTesting {
    for _ in 0..<100 {
        let state = transport.renderedStateForTesting
        if transport.logRenderIsIdleForTesting,
           predicate(state.snapshot)
        {
            return state.snapshot
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    let state = transport.renderedStateForTesting
    Issue.record(
        "Timed out waiting for preview transport render: selection=\(String(describing: state.selection)), log=\(state.snapshot.log)"
    )
    return state.snapshot
}

@MainActor
private func waitForPreviewCondition(
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    for _ in 0..<100 {
        if condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Timed out waiting for preview condition.")
}

@MainActor
private final class WindowControllerFactoryRecorder {
    private(set) var makeCallCount = 0
    private(set) var lastWindowController: CountingWindowController?

    func makeWindowController() -> CountingWindowController {
        makeCallCount += 1
        let windowController = CountingWindowController()
        lastWindowController = windowController
        return windowController
    }
}

@MainActor
private final class CountingWindowController: NSWindowController {
    private(set) var showWindowCallCount = 0

    var windowForTesting: CountingWindow {
        guard let window = window as? CountingWindow else {
            fatalError("Expected CountingWindow.")
        }
        return window
    }

    init() {
        super.init(
            window: CountingWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_: Any?) {
        showWindowCallCount += 1
    }
}

@MainActor
private final class CountingWindow: NSWindow {
    private(set) var makeKeyAndOrderFrontCallCount = 0

    override func makeKeyAndOrderFront(_: Any?) {
        makeKeyAndOrderFrontCallCount += 1
    }
}
