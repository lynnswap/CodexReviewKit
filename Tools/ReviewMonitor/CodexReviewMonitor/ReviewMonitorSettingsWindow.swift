import AppKit
import CodexReviewHost
import Observation
import SwiftUI

@MainActor
enum ReviewMonitorSettingsPane: String, CaseIterable {
    case runtime

    var label: String {
        switch self {
        case .runtime:
            "Runtime"
        }
    }

    var systemSymbolName: String {
        switch self {
        case .runtime:
            "gearshape"
        }
    }

    func tabViewItem(
        runtimePreferencesStore: any CodexReviewRuntimePreferencesStore
    ) -> NSTabViewItem {
        let viewController = makeViewController(
            runtimePreferencesStore: runtimePreferencesStore
        )
        let tabViewItem = NSTabViewItem(viewController: viewController)
        tabViewItem.label = label
        tabViewItem.identifier = rawValue
        tabViewItem.image = NSImage(
            systemSymbolName: systemSymbolName,
            accessibilityDescription: label
        )
        return tabViewItem
    }

    private func makeViewController(
        runtimePreferencesStore: any CodexReviewRuntimePreferencesStore
    ) -> NSViewController {
        switch self {
        case .runtime:
            ReviewMonitorRuntimeSettingsViewController(
                runtimePreferencesStore: runtimePreferencesStore
            )
        }
    }
}

@MainActor
final class ReviewMonitorSettingsWindowController: NSWindowController {
    init(runtimePreferencesStore: any CodexReviewRuntimePreferencesStore) {
        let tabViewController = NSTabViewController()
        tabViewController.tabStyle = .toolbar
        tabViewController.title = "Settings"
        tabViewController.tabViewItems = ReviewMonitorSettingsPane.allCases.map {
            $0.tabViewItem(runtimePreferencesStore: runtimePreferencesStore)
        }

        let window = ReviewMonitorSettingsWindow(
            contentViewController: tabViewController
        )
        window.title = "Settings"
        window.styleMask = [.closable, .titled]
        window.toolbarStyle = .preference
        window.collectionBehavior.insert(.auxiliary)

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func openPane(_ pane: ReviewMonitorSettingsPane) {
        guard let tabViewController = contentViewController as? NSTabViewController,
              let index = ReviewMonitorSettingsPane.allCases.firstIndex(of: pane)
        else {
            showWindow(nil)
            return
        }
        tabViewController.selectedTabViewItemIndex = index
        showWindow(nil)
    }
}

@MainActor
final class ReviewMonitorSettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(NSWindow.toggleToolbarShown(_:)) {
            return false
        }
        return super.validateMenuItem(menuItem)
    }
}

@MainActor
final class ReviewMonitorRuntimeSettingsViewController: NSHostingController<ReviewMonitorRuntimeSettingsForm> {
    let formState: ReviewMonitorRuntimeSettingsFormState

    init(runtimePreferencesStore: any CodexReviewRuntimePreferencesStore) {
        let formState = ReviewMonitorRuntimeSettingsFormState(
            runtimePreferencesStore: runtimePreferencesStore
        )
        self.formState = formState
        super.init(rootView: ReviewMonitorRuntimeSettingsForm(state: formState))
        title = ReviewMonitorSettingsPane.runtime.label
        preferredContentSize = NSSize(width: 560, height: 280)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    @objc func savePreferences(_: Any?) {
        formState.savePreferences()
    }
}

@MainActor
@Observable
final class ReviewMonitorRuntimeSettingsFormState {
    private static let defaultCodexHomeDisplayPath = "~/.codex_review"

    var codexHomePath = "" {
        didSet {
            if isPopulatingFields == false {
                preservesCodexHomeFallback = false
            }
            clearStatusAfterEditing()
        }
    }
    var mcpHost = "" {
        didSet { clearStatusAfterEditing() }
    }
    var mcpPort = "" {
        didSet { clearStatusAfterEditing() }
    }
    var mcpPath = "" {
        didSet { clearStatusAfterEditing() }
    }
    var codexExecutablePath = "" {
        didSet { clearStatusAfterEditing() }
    }
    var statusMessage = ""
    var saveFailed = false
    private var savedPreferences: CodexReviewRuntimePreferences
    private var preservesCodexHomeFallback = false
    private var isPopulatingFields = false

    @ObservationIgnored
    private let runtimePreferencesStore: any CodexReviewRuntimePreferencesStore

    init(runtimePreferencesStore: any CodexReviewRuntimePreferencesStore) {
        self.runtimePreferencesStore = runtimePreferencesStore
        let preferences = runtimePreferencesStore.load()
        self.savedPreferences = preferences
        self.preservesCodexHomeFallback = preferences.codexHomePath == nil
        populateFields(with: preferences)
    }

    var hasUnsavedChanges: Bool {
        currentPreferences != savedPreferences || validationMessage != nil
    }

    var canSavePreferences: Bool {
        hasUnsavedChanges && validationMessage == nil
    }

    var canRestoreDefaults: Bool {
        currentPreferences != .defaults || validationMessage != nil
    }

    var validationMessage: String? {
        if let pathValidationMessage = pathValidationMessage(
            codexHomePath,
            fieldName: "Codex home"
        ) {
            return pathValidationMessage
        }

        if let hostValidationMessage = hostValidationMessage(mcpHost) {
            return hostValidationMessage
        }

        let port = mcpPort.trimmingCharacters(in: .whitespacesAndNewlines)
        if port.isEmpty == false {
            guard let value = Int(port),
                  (1...65535).contains(value)
            else {
                return "MCP port must be a number from 1 to 65535."
            }
        }

        if let mcpPathValidationMessage = mcpPathValidationMessage(mcpPath) {
            return mcpPathValidationMessage
        }

        return pathValidationMessage(
            codexExecutablePath,
            fieldName: "Codex executable"
        )
    }

    func savePreferences() {
        if let validationMessage {
            statusMessage = validationMessage
            saveFailed = true
            return
        }
        guard hasUnsavedChanges else {
            return
        }

        let preferences = currentPreferences
        do {
            try runtimePreferencesStore.save(preferences)
            savedPreferences = preferences
            preservesCodexHomeFallback = preferences.codexHomePath == nil
            populateFields(with: preferences)
            statusMessage = "Saved. Restart ReviewMonitor to apply changes."
            saveFailed = false
        } catch {
            statusMessage = error.localizedDescription
            saveFailed = true
        }
    }

    func restoreDefaults() {
        guard canRestoreDefaults else {
            return
        }
        preservesCodexHomeFallback = true
        populateFields(with: .defaults)
    }

    private var parsedMCPPort: Int {
        let trimmed = mcpPort.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed) ?? 0
    }

    private var currentPreferences: CodexReviewRuntimePreferences {
        let preferences = CodexReviewRuntimePreferences(
            codexHomePath: preservesCodexHomeFallback ? nil : codexHomePath,
            mcpHost: mcpHost,
            mcpPort: parsedMCPPort,
            mcpPath: mcpPath,
            codexExecutablePath: codexExecutablePath
        )
        return preferences
    }

    private func populateFields(
        with preferences: CodexReviewRuntimePreferences
    ) {
        isPopulatingFields = true
        defer { isPopulatingFields = false }

        codexHomePath = displayCodexHomePath(
            preferences.codexHomePath
        )
        mcpHost = preferences.mcpHost
        mcpPort = String(preferences.mcpPort)
        mcpPath = preferences.mcpPath
        codexExecutablePath = displayPath(preferences.codexExecutablePath)
    }

    private func displayCodexHomePath(_ path: String?) -> String {
        guard let path else {
            return Self.defaultCodexHomeDisplayPath
        }
        return displayPath(path)
    }

    private func clearStatusAfterEditing() {
        guard statusMessage.isEmpty == false else {
            return
        }
        statusMessage = ""
        saveFailed = false
    }

    private func displayPath(_ path: String?) -> String {
        guard let path, path.isEmpty == false else {
            return ""
        }

        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if path == homePath {
            return "~"
        }

        let homePrefix = "\(homePath)/"
        if path.hasPrefix(homePrefix) {
            return "~/" + String(path.dropFirst(homePrefix.count))
        }

        return path
    }

    private func pathValidationMessage(_ path: String, fieldName: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }
        guard trimmed == "~" || trimmed.hasPrefix("~/") || trimmed.hasPrefix("/") else {
            return "\(fieldName) must start with / or ~/."
        }
        return nil
    }

    private func hostValidationMessage(_ host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }

        guard trimmed.contains("[") == false,
              trimmed.contains("]") == false,
              let components = URLComponents(string: "http://\(trimmed)"),
              components.url != nil,
              components.host == trimmed,
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil
        else {
            return "MCP host must be a host name or IPv4 address without a scheme or port."
        }
        return nil
    }

    private func mcpPathValidationMessage(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }

        let normalized = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.path = normalized
        guard components.url != nil,
              components.percentEncodedPath == normalized
        else {
            return "MCP path must be a URL path that does not require escaping."
        }
        return nil
    }
}

struct ReviewMonitorRuntimeSettingsForm: View {
    @Bindable var state: ReviewMonitorRuntimeSettingsFormState

    var body: some View {
        Form {
            TextField(
                "Codex home",
                text: $state.codexHomePath,
                prompt: Text("~/.codex_review")
            )
            TextField(
                "MCP host",
                text: $state.mcpHost,
                prompt: Text(CodexReviewRuntimePreferences.defaults.mcpHost)
            )
            TextField(
                "MCP port",
                text: $state.mcpPort,
                prompt: Text(String(CodexReviewRuntimePreferences.defaults.mcpPort))
            )
            TextField(
                "MCP path",
                text: $state.mcpPath,
                prompt: Text(CodexReviewRuntimePreferences.defaults.mcpPath)
            )
            TextField(
                "Codex executable",
                text: $state.codexExecutablePath,
                prompt: Text("Default: env or PATH")
            )

            Button("Restore Defaults") {
                state.restoreDefaults()
            }
            .disabled(!state.canRestoreDefaults)

            Button("Save") {
                state.savePreferences()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!state.canSavePreferences)

            if let validationMessage = state.validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if !state.statusMessage.isEmpty {
                Label(
                    state.statusMessage,
                    systemImage: state.saveFailed ? "exclamationmark.triangle" : "checkmark.circle"
                )
                .foregroundStyle(state.saveFailed ? .red : .secondary)
            }
        }
        .scenePadding()
    }
}

#if DEBUG
#Preview("Runtime Settings") {
    ReviewMonitorRuntimeSettingsViewController(
        runtimePreferencesStore: PreviewRuntimePreferencesStore()
    )
}

@MainActor
private final class PreviewRuntimePreferencesStore: CodexReviewRuntimePreferencesStore {
    func load() -> CodexReviewRuntimePreferences {
        CodexReviewRuntimePreferences(
            codexHomePath: "~/.codex_review",
            mcpHost: "localhost",
            mcpPort: 9417,
            mcpPath: "/mcp"
        )
    }

    func save(_: CodexReviewRuntimePreferences) throws {
    }
}
#endif
