//
//  CodexReviewMonitorApp.swift
//  CodexReviewMonitor
//
//  Created by Kazuki Nakashima on 2026/03/28.
//

import AppKit
import CodexReview
import CodexReviewHost
@_spi(PreviewSupport) import ReviewUI

enum ReviewMonitorLaunchMode: Sendable {
    case application
    case xctest
    case preview
}

enum ReviewMonitorLiveStoreMode: Equatable {
    case production
    case isolatedTest(diagnosticsURL: URL?, historyDatabaseURL: URL)
}

private struct ReviewMonitorIsolatedTestConfiguration {
    var port: Int?
    var codexExecutablePath: String?
    var diagnosticsURL: URL?
    var historyDatabaseURL: URL
    var validationFailure: String?

    func applying(to preferences: CodexReviewRuntime.Preferences) -> CodexReviewRuntime.Preferences {
        CodexReviewRuntime.Preferences(
            codexHomePath: preferences.codexHomePath,
            mcpHost: preferences.mcpHost,
            mcpPort: port ?? preferences.mcpPort,
            mcpPath: preferences.mcpPath,
            codexExecutablePath: codexExecutablePath ?? preferences.codexExecutablePath
        )
    }
}

struct ReviewMonitorLaunchContext: Sendable {
    var environment: [String: String]
    var arguments: [String]
    var launchMode: ReviewMonitorLaunchMode
    var requestsPreviewContent: Bool

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments,
        launchMode: ReviewMonitorLaunchMode? = nil
    ) {
        self.environment = environment
        self.arguments = arguments
        self.launchMode = launchMode ?? ReviewMonitorLaunchEnvironment.launchMode(
            environment: environment,
            arguments: arguments
        )
        requestsPreviewContent = ReviewMonitorLaunchEnvironment.requestsPreviewContent(
            environment: environment,
            arguments: arguments
        )
    }

    var shouldStartEmbeddedServer: Bool {
        launchMode == .application
            && requestsPreviewContent == false
            && isolatedTestConfiguration?.validationFailure == nil
    }

    fileprivate var isolatedTestConfiguration: ReviewMonitorIsolatedTestConfiguration? {
        ReviewMonitorLaunchEnvironment.isolatedTestConfiguration(
            environment: environment,
            arguments: arguments
        )
    }
}

enum ReviewMonitorLaunchEnvironment {
    static let reviewModeKey = CodexReviewStoreTestEnvironment.reviewModeKey
    static let mockJobsKey = CodexReviewStoreTestEnvironment.mockJobsKey
    static let xctestConfigurationKey = "XCTestConfigurationFilePath"
    static let xctestBundlePathKey = "XCTestBundlePath"
    static let xcInjectBundleIntoKey = "XCInjectBundleInto"
    static let xctestSessionIdentifierKey = "XCTestSessionIdentifier"
    static let xcodeRunningForPlaygroundsKey = "XCODE_RUNNING_FOR_PLAYGROUNDS"
    static let xcodeRunningForPreviewsKey = "XCODE_RUNNING_FOR_PREVIEWS"
    static let testPortKey = CodexReviewStoreTestEnvironment.portKey
    static let testCodexCommandKey = CodexReviewStoreTestEnvironment.codexCommandKey
    static let testDiagnosticsPathKey = CodexReviewStoreTestEnvironment.diagnosticsPathKey
    static let testHistoryPathKey = CodexReviewStoreTestEnvironment.historyPathKey
    static let reviewModeArgument = CodexReviewStoreTestEnvironment.reviewModeArgument
    static let mockJobsArgument = CodexReviewStoreTestEnvironment.mockJobsArgument
    static let testPortArgument = CodexReviewStoreTestEnvironment.portArgument
    static let testCodexCommandArgument = CodexReviewStoreTestEnvironment.codexCommandArgument
    static let testDiagnosticsPathArgument = CodexReviewStoreTestEnvironment.diagnosticsPathArgument
    static let testHistoryPathArgument = CodexReviewStoreTestEnvironment.historyPathArgument

    static func launchMode(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> ReviewMonitorLaunchMode {
        if isRunningInPreviews(environment: environment) {
            return .preview
        }
        if hasExplicitTestOverride(environment: environment, arguments: arguments) {
            return .application
        }
        if isRunningUnderXCTest(environment: environment) {
            return .xctest
        }
        return .application
    }

    static func shouldStartEmbeddedServer(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        ReviewMonitorLaunchContext(
            environment: environment,
            arguments: arguments
        ).shouldStartEmbeddedServer
    }

    private static func isRunningInPreviews(environment: [String: String]) -> Bool {
        isEnabledFlag(environment[xcodeRunningForPreviewsKey])
            || isEnabledFlag(environment[xcodeRunningForPlaygroundsKey])
    }

    static func requestsPreviewContent(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        if isRunningInPreviews(environment: environment) {
            return true
        }
        return isEnabledFlag(environment[reviewModeKey])
            || arguments.contains(reviewModeArgument)
            || isEnabledFlag(environment[mockJobsKey])
            || arguments.contains(mockJobsArgument)
    }

    static func isRunningUnderXCTest(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        isNonEmpty(environment[xctestConfigurationKey])
            || isNonEmpty(environment[xctestBundlePathKey])
            || isNonEmpty(environment[xcInjectBundleIntoKey])
            || isNonEmpty(environment[xctestSessionIdentifierKey])
    }

    private static func hasExplicitTestOverride(
        environment: [String: String],
        arguments: [String]
    ) -> Bool {
        environment[testPortKey] != nil
            || environment[testCodexCommandKey] != nil
            || environment[testDiagnosticsPathKey] != nil
            || environment[testHistoryPathKey] != nil
            || arguments.contains(testPortArgument)
            || arguments.contains(testCodexCommandArgument)
            || arguments.contains(testDiagnosticsPathArgument)
            || arguments.contains(testHistoryPathArgument)
            || arguments.contains(where: { $0.hasPrefix(testPortArgument + "=") })
            || arguments.contains(where: { $0.hasPrefix(testCodexCommandArgument + "=") })
            || arguments.contains(where: { $0.hasPrefix(testDiagnosticsPathArgument + "=") })
            || arguments.contains(where: { $0.hasPrefix(testHistoryPathArgument + "=") })
    }

    fileprivate static func isolatedTestConfiguration(
        environment: [String: String],
        arguments: [String]
    ) -> ReviewMonitorIsolatedTestConfiguration? {
        guard hasExplicitTestOverride(environment: environment, arguments: arguments) else {
            return nil
        }

        var failures: [String] = []
        let portValue = explicitTestValue(
            environment: environment,
            key: testPortKey,
            arguments: arguments,
            argument: testPortArgument
        )
        let port: Int?
        if portValue.wasSpecified {
            if let value = portValue.value,
               let parsed = Int(value),
               (1...65535).contains(parsed)
            {
                port = parsed
            } else {
                port = nil
                failures.append("\(testPortKey) requires an integer from 1 through 65535.")
            }
        } else {
            port = nil
        }

        let commandValue = explicitTestValue(
            environment: environment,
            key: testCodexCommandKey,
            arguments: arguments,
            argument: testCodexCommandArgument
        )
        let codexExecutablePath = absolutePath(
            commandValue,
            key: testCodexCommandKey,
            failures: &failures
        )

        let diagnosticsValue = explicitTestValue(
            environment: environment,
            key: testDiagnosticsPathKey,
            arguments: arguments,
            argument: testDiagnosticsPathArgument
        )
        let diagnosticsURL = absolutePath(
            diagnosticsValue,
            key: testDiagnosticsPathKey,
            failures: &failures
        ).map { URL(fileURLWithPath: $0, isDirectory: false) }

        let historyValue = explicitTestValue(
            environment: environment,
            key: testHistoryPathKey,
            arguments: arguments,
            argument: testHistoryPathArgument
        )
        let historyPath = absolutePath(
            historyValue,
            key: testHistoryPathKey,
            isRequired: true,
            failures: &failures
        )
        let historyDatabaseURL = historyPath.map {
            URL(fileURLWithPath: $0, isDirectory: false)
        } ?? URL(string: "review-monitor-invalid://history")!

        return ReviewMonitorIsolatedTestConfiguration(
            port: port,
            codexExecutablePath: codexExecutablePath,
            diagnosticsURL: diagnosticsURL,
            historyDatabaseURL: historyDatabaseURL,
            validationFailure: failures.first
        )
    }

    private static func explicitTestValue(
        environment: [String: String],
        key: String,
        arguments: [String],
        argument: String
    ) -> (wasSpecified: Bool, value: String?) {
        if let value = environment[key] {
            return (true, value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let value = arguments.first(where: { $0.hasPrefix(argument + "=") }) {
            return (
                true,
                String(value.dropFirst(argument.count + 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard let index = arguments.firstIndex(of: argument) else {
            return (false, nil)
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            return (true, nil)
        }
        return (
            true,
            arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func absolutePath(
        _ explicitValue: (wasSpecified: Bool, value: String?),
        key: String,
        isRequired: Bool = false,
        failures: inout [String]
    ) -> String? {
        guard explicitValue.wasSpecified else {
            if isRequired {
                failures.append("\(key) is required for an isolated ReviewMonitor test launch.")
            }
            return nil
        }
        guard let value = explicitValue.value,
              value.isEmpty == false,
              value.hasPrefix("/")
        else {
            failures.append("\(key) requires an absolute path.")
            return nil
        }
        return value
    }

    private static func isEnabledFlag(_ value: String?) -> Bool {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes":
            true
        default:
            false
        }
    }

    private static func isNonEmpty(_ value: String?) -> Bool {
        value?.isEmpty == false
    }
}

@MainActor
protocol ReviewMonitorLifecycleStore: AnyObject {
    func start(forceRestartIfNeeded: Bool) async
    func shutdown() async
}

extension CodexReviewStore: ReviewMonitorLifecycleStore {}

@MainActor
protocol ReviewMonitorTerminationReplying: AnyObject {
    func replyToApplicationShouldTerminate(_ shouldTerminate: Bool)
}

extension NSApplication: ReviewMonitorTerminationReplying {
    func replyToApplicationShouldTerminate(_ shouldTerminate: Bool) {
        reply(toApplicationShouldTerminate: shouldTerminate)
    }
}

@MainActor
final class ReviewMonitorLifecycleController {
    private let store: any ReviewMonitorLifecycleStore
    private let managesEmbeddedServerOnApplicationLaunch: Bool
    private var shouldManageEmbeddedServer = true
    private var launchTask: Task<Void, Never>?
    private var launchTaskID: UUID?
    private var terminationTask: Task<Void, Never>?

    init(
        store: any ReviewMonitorLifecycleStore,
        shouldManageEmbeddedServer: Bool = true
    ) {
        self.store = store
        managesEmbeddedServerOnApplicationLaunch = shouldManageEmbeddedServer
    }

    func applicationDidFinishLaunching(launchMode: ReviewMonitorLaunchMode) {
        shouldManageEmbeddedServer =
            managesEmbeddedServerOnApplicationLaunch &&
            launchMode == .application
        guard shouldManageEmbeddedServer else {
            return
        }
        guard launchTask == nil else {
            return
        }
        let id = UUID()
        let store = store
        launchTaskID = id
        launchTask = Task { @MainActor [weak self] in
            await store.start(forceRestartIfNeeded: true)
            guard self?.launchTaskID == id else {
                return
            }
            self?.launchTask = nil
            self?.launchTaskID = nil
        }
    }

    func applicationShouldTerminate(
        replyingTo application: any ReviewMonitorTerminationReplying
    ) -> NSApplication.TerminateReply {
        guard shouldManageEmbeddedServer else {
            return .terminateNow
        }
        guard terminationTask == nil else {
            return .terminateLater
        }
        let launchTask = launchTask
        launchTask?.cancel()
        self.launchTask = nil
        launchTaskID = nil
        let store = store
        terminationTask = Task { @MainActor [weak self] in
            await launchTask?.value
            await store.shutdown()
            self?.terminationTask = nil
            application.replyToApplicationShouldTerminate(true)
        }
        return .terminateLater
    }
}

@MainActor
private final class ReviewMonitorPresentationAnchorSource {
    weak var window: NSWindow?
}

private enum ReviewMonitorNativeAuthentication {
    static let callbackScheme = "lynnpd.CodexReviewMonitor.auth"
}

@MainActor
struct ReviewMonitorAppComposition {
    typealias PresentationAnchorProvider = @MainActor () -> NSWindow?
    typealias LiveStoreFactory = (
        CodexReviewRuntime.Preferences,
        CodexReviewNativeAuthentication.Configuration?,
        ReviewMonitorLiveStoreMode
    ) -> CodexReviewStore

    var makeStore: (ReviewMonitorLaunchContext, @escaping PresentationAnchorProvider) -> CodexReviewStore
    var makeLifecycleController: (
        any ReviewMonitorLifecycleStore,
        ReviewMonitorLaunchContext
    ) -> ReviewMonitorLifecycleController
    var makeWindowController: (CodexReviewStore, @escaping @MainActor () -> Void) -> NSWindowController
    var makeSettingsWindowController: () -> NSWindowController

    init(
        makeStore: @escaping (
            ReviewMonitorLaunchContext,
            @escaping PresentationAnchorProvider
        ) -> CodexReviewStore,
        makeLifecycleController: @escaping (
            any ReviewMonitorLifecycleStore,
            ReviewMonitorLaunchContext
        ) -> ReviewMonitorLifecycleController = { store, context in
            ReviewMonitorLifecycleController(
                store: store,
                shouldManageEmbeddedServer: context.shouldStartEmbeddedServer
            )
        },
        makeWindowController: @escaping (
            CodexReviewStore,
            @escaping @MainActor () -> Void
        ) -> NSWindowController,
        makeSettingsWindowController: @escaping () -> NSWindowController = {
            ReviewMonitorSettingsWindowController(
                runtimePreferencesStore: CodexReviewRuntime.UserDefaultsPreferencesStore()
            )
        }
    ) {
        self.makeStore = makeStore
        self.makeLifecycleController = makeLifecycleController
        self.makeWindowController = makeWindowController
        self.makeSettingsWindowController = makeSettingsWindowController
    }

    static func live(
        runtimePreferencesStore: any CodexReviewRuntime.PreferencesStore = CodexReviewRuntime.UserDefaultsPreferencesStore(),
        makeLiveStore: @escaping LiveStoreFactory = { runtimePreferences, nativeAuthenticationConfiguration, mode in
            switch mode {
            case .production:
                CodexReviewStore.makeLiveStore(
                    runtimePreferences: runtimePreferences,
                    nativeAuthenticationConfiguration: nativeAuthenticationConfiguration
                )
            case .isolatedTest(let diagnosticsURL, let historyDatabaseURL):
                CodexReviewStore.makeLiveStore(
                    runtimePreferences: runtimePreferences,
                    nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
                    diagnosticsURL: diagnosticsURL,
                    reviewHistoryDatabaseURL: historyDatabaseURL
                )
            }
        }
    ) -> ReviewMonitorAppComposition {
        ReviewMonitorAppComposition(
            makeStore: { context, presentationAnchorProvider in
                if context.requestsPreviewContent {
                    return ReviewMonitorPreviewContent.makeStore()
                }
                let testConfiguration = context.isolatedTestConfiguration
                let runtimePreferences = testConfiguration?.applying(
                    to: runtimePreferencesStore.load()
                ) ?? runtimePreferencesStore.load()
                let storeMode: ReviewMonitorLiveStoreMode = if let testConfiguration {
                    .isolatedTest(
                        diagnosticsURL: testConfiguration.diagnosticsURL,
                        historyDatabaseURL: testConfiguration.historyDatabaseURL
                    )
                } else {
                    .production
                }
                return makeLiveStore(
                    runtimePreferences,
                    .init(
                        callbackScheme: ReviewMonitorNativeAuthentication.callbackScheme,
                        browserSessionPolicy: .ephemeral,
                        presentationAnchorProvider: presentationAnchorProvider
                    ),
                    storeMode
                )
            },
            makeWindowController: { store, showSettings in
                ReviewMonitorWindowController(
                    store: store,
                    showSettings: showSettings
                )
            },
            makeSettingsWindowController: {
                ReviewMonitorSettingsWindowController(
                    runtimePreferencesStore: runtimePreferencesStore
                )
            }
        )
    }
}

@main
@MainActor
final class ReviewMonitorAppDelegate: NSObject, NSApplicationDelegate {
    private let launchContextProvider: () -> ReviewMonitorLaunchContext
    private let composition: ReviewMonitorAppComposition
    private let presentationAnchorSource = ReviewMonitorPresentationAnchorSource()

    private lazy var launchContext = launchContextProvider()
    private var launchMode: ReviewMonitorLaunchMode {
        launchContext.launchMode
    }
    lazy var store: CodexReviewStore = {
        composition.makeStore(launchContext) { [weak presentationAnchorSource] in
            presentationAnchorSource?.window
        }
    }()
    lazy var lifecycle = composition.makeLifecycleController(store, launchContext)
    lazy var windowController: NSWindowController = {
        let windowController = composition.makeWindowController(store) { [weak self] in
            self?.showSettingsWindow(nil)
        }
        presentationAnchorSource.window = windowController.window
        return windowController
    }()
    lazy var settingsWindowController = composition.makeSettingsWindowController()

    override init() {
        launchContextProvider = {
            ReviewMonitorLaunchContext()
        }
        composition = .live()
        super.init()
    }

    init(
        launchContextProvider: @escaping () -> ReviewMonitorLaunchContext,
        composition: ReviewMonitorAppComposition
    ) {
        self.launchContextProvider = launchContextProvider
        self.composition = composition
        super.init()
    }

    static func main() {
        let application = NSApplication.shared
        let delegate = ReviewMonitorAppDelegate()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_: Notification) {
        guard launchMode != .preview else {
            lifecycle.applicationDidFinishLaunching(launchMode: launchMode)
            return
        }
        NSApp.setActivationPolicy(.regular)
        installStandardMainMenuIfNeeded()
        showMainWindow(nil)
        if launchMode == .application {
            NSApp.activate(ignoringOtherApps: true)
        }
        lifecycle.applicationDidFinishLaunching(
            launchMode: launchMode
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        lifecycle.applicationShouldTerminate(replyingTo: sender)
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard launchMode == .application else {
            return false
        }
        guard flag == false else {
            return false
        }
        showMainWindow(nil)
        return true
    }

    @IBAction func showSettingsWindow(_ sender: Any?) {
        settingsWindowController.showWindow(sender)
    }

    private func showMainWindow(_ sender: Any?) {
        windowController.showWindow(sender)
        windowController.window?.orderFrontRegardless()
        windowController.window?.makeKeyAndOrderFront(sender)
    }

    private func installStandardMainMenuIfNeeded() {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName

        let mainMenu = NSMenu(title: "Main Menu")

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: appName)
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettingsWindow(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let deleteItem = NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: String(Character(UnicodeScalar(NSDeleteCharacter)!)))
        editMenu.addItem(deleteItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let findMenuItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        findMenu.addItem(
            textFinderMenuItem(
                title: "Find...",
                action: .showFindInterface,
                keyEquivalent: "f"
            )
        )
        findMenu.addItem(
            textFinderMenuItem(
                title: "Find Next",
                action: .nextMatch,
                keyEquivalent: "g"
            )
        )
        findMenu.addItem(
            textFinderMenuItem(
                title: "Find Previous",
                action: .previousMatch,
                keyEquivalent: "g",
                modifierMask: [.command, .shift]
            )
        )
        findMenuItem.submenu = findMenu
        editMenu.addItem(findMenuItem)
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.servicesMenu = servicesMenu
        NSApp.windowsMenu = windowMenu
    }

    private func textFinderMenuItem(
        title: String,
        action: NSTextFinder.Action,
        keyEquivalent: String,
        modifierMask: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(NSResponder.performTextFinderAction(_:)),
            keyEquivalent: keyEquivalent
        )
        item.tag = action.rawValue
        item.keyEquivalentModifierMask = modifierMask
        return item
    }
}
