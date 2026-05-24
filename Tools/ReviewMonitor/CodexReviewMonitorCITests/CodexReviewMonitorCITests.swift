import AppKit
import Foundation
import CodexReview
import CodexReviewHost
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

        #expect(environment[ReviewMonitorLaunchEnvironment.mockJobsKey] == "1")
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
        let recorder = WindowControllerFactoryRecorder()
        let composition = ReviewMonitorAppComposition(
            makeStore: { context, _ in
                capturedContext = context
                return expectedStore
            },
            makeWindowController: { store in
                #expect(store === expectedStore)
                return recorder.makeWindowController()
            }
        )
        let delegate = ReviewMonitorAppDelegate(
            launchContextProvider: {
                ReviewMonitorLaunchContext(
                    environment: [
                        ReviewMonitorLaunchEnvironment.mockJobsKey: "1",
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
    }

    @Test func liveCompositionUsesPreviewStoreWhenPreviewContentIsRequested() {
        let runtimePreferencesStore = FailingRuntimePreferencesStore()
        var didCallLiveStoreFactory = false
        let composition = ReviewMonitorAppComposition.live(
            runtimePreferencesStore: runtimePreferencesStore,
            makeLiveStore: { _, _ in
                didCallLiveStoreFactory = true
                Issue.record("Preview store creation should not build a live store.")
                return CodexReviewStore.makePreviewStore()
            }
        )
        let context = ReviewMonitorLaunchContext(
            environment: [
                ReviewMonitorLaunchEnvironment.mockJobsKey: "1",
            ],
            arguments: [],
            launchMode: .application
        )
        var didRequestPresentationAnchor = false

        _ = composition.makeStore(context) {
            didRequestPresentationAnchor = true
            Issue.record("Preview store creation should not request a presentation anchor.")
            return nil
        }

        #expect(didRequestPresentationAnchor == false)
        #expect(didCallLiveStoreFactory == false)
        #expect(context.shouldStartEmbeddedServer == false)
    }

    @Test func liveCompositionPassesLoadedRuntimePreferencesToApplicationStoreFactory() {
        let expectedRuntimePreferences = CodexReviewRuntimePreferences(
            codexHomePath: FileManager.default.temporaryDirectory
                .appending(path: "codex-review-monitor-ci-\(UUID().uuidString)", directoryHint: .isDirectory)
                .path,
            mcpHost: "127.0.0.1",
            mcpPort: 54321,
            mcpPath: "/custom-mcp",
            codexExecutablePath: "/tmp/codex"
        )
        let runtimePreferencesStore = RuntimePreferencesStoreStub(
            preferences: expectedRuntimePreferences
        )
        let expectedStore = CodexReviewStore.makePreviewStore()
        var capturedRuntimePreferences: CodexReviewRuntimePreferences?
        var capturedAuthenticationConfiguration: CodexReviewNativeAuthenticationConfiguration?
        let composition = ReviewMonitorAppComposition.live(
            runtimePreferencesStore: runtimePreferencesStore,
            makeLiveStore: { runtimePreferences, authenticationConfiguration in
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

        let store = composition.makeStore(context) {
            didRequestPresentationAnchor = true
            return nil
        }

        #expect(store === expectedStore)
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
            makeStore: { _, _ in
                CodexReviewStore.makePreviewStore()
            },
            makeWindowController: { _ in
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

private final class RuntimePreferencesStoreStub: CodexReviewRuntimePreferencesStore {
    private let preferences: CodexReviewRuntimePreferences

    init(preferences: CodexReviewRuntimePreferences = .defaults) {
        self.preferences = preferences
    }

    func load() -> CodexReviewRuntimePreferences {
        return preferences
    }

    func save(_: CodexReviewRuntimePreferences) throws {
    }
}

@MainActor
private final class FailingRuntimePreferencesStore: CodexReviewRuntimePreferencesStore {
    func load() -> CodexReviewRuntimePreferences {
        Issue.record("Preview store creation should not load runtime preferences.")
        return .defaults
    }

    func save(_: CodexReviewRuntimePreferences) throws {
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
