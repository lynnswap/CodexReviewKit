import AppKit
import CodexReviewHost
import Observation
import SwiftUI
@_spi(ApplicationHostSupport) import CodexReview
@_spi(PreviewSupport) import ReviewUI

@MainActor
enum ReviewMonitorSettingsPane: String, CaseIterable {
    case runtime
    case updates

    var label: String {
        switch self {
        case .runtime:
            "Runtime"
        case .updates:
            "Updates"
        }
    }

    var systemSymbolName: String {
        switch self {
        case .runtime:
            "gearshape"
        case .updates:
            "arrow.triangle.2.circlepath"
        }
    }

    func tabViewItem(
        runtimePreferencesStore: any CodexReviewRuntime.PreferencesStore,
        updater: ReviewMonitorCodexUpdater?
    ) -> NSTabViewItem? {
        guard let viewController = makeViewController(
            runtimePreferencesStore: runtimePreferencesStore,
            updater: updater
        ) else { return nil }
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
        runtimePreferencesStore: any CodexReviewRuntime.PreferencesStore,
        updater: ReviewMonitorCodexUpdater?
    ) -> NSViewController? {
        switch self {
        case .runtime:
            ReviewMonitorRuntimeSettingsViewController(
                runtimePreferencesStore: runtimePreferencesStore
            )
        case .updates:
            updater.map { ReviewMonitorUpdateSettingsViewController(updater: $0) }
        }
    }
}

@MainActor
final class ReviewMonitorSettingsWindowController: NSWindowController {
    init(runtimePreferencesStore: any CodexReviewRuntime.PreferencesStore, updater: ReviewMonitorCodexUpdater? = nil) {
        let tabViewController = NSTabViewController()
        tabViewController.tabStyle = .toolbar
        tabViewController.title = "Settings"
        tabViewController.tabViewItems = ReviewMonitorSettingsPane.allCases.compactMap {
            $0.tabViewItem(runtimePreferencesStore: runtimePreferencesStore, updater: updater)
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
              let index = tabViewController.tabViewItems.firstIndex(where: { $0.identifier as? String == pane.rawValue })
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

    init(runtimePreferencesStore: any CodexReviewRuntime.PreferencesStore) {
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
    private var savedPreferences: CodexReviewRuntime.Preferences
    private var preservesCodexHomeFallback = false
    private var isPopulatingFields = false

    @ObservationIgnored
    private let runtimePreferencesStore: any CodexReviewRuntime.PreferencesStore

    init(runtimePreferencesStore: any CodexReviewRuntime.PreferencesStore) {
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

    private var currentPreferences: CodexReviewRuntime.Preferences {
        let preferences = CodexReviewRuntime.Preferences(
            codexHomePath: preservesCodexHomeFallback ? nil : codexHomePath,
            mcpHost: mcpHost,
            mcpPort: parsedMCPPort,
            mcpPath: mcpPath,
            codexExecutablePath: codexExecutablePath
        )
        return preferences
    }

    private func populateFields(
        with preferences: CodexReviewRuntime.Preferences
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

        guard CodexReviewRuntime.Preferences(mcpHost: trimmed).mcpHost == trimmed else {
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
                prompt: Text(CodexReviewRuntime.Preferences.defaults.mcpHost)
            )
            TextField(
                "MCP port",
                text: $state.mcpPort,
                prompt: Text(String(CodexReviewRuntime.Preferences.defaults.mcpPort))
            )
            TextField(
                "MCP path",
                text: $state.mcpPath,
                prompt: Text(CodexReviewRuntime.Preferences.defaults.mcpPath)
            )
            TextField(
                "Codex executable",
                text: $state.codexExecutablePath,
                prompt: Text("Default: auto-detected")
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
private final class PreviewRuntimePreferencesStore: CodexReviewRuntime.PreferencesStore {
    func load() -> CodexReviewRuntime.Preferences {
        CodexReviewRuntime.Preferences(
            codexHomePath: "~/.codex_review",
            mcpHost: "localhost",
            mcpPort: 9417,
            mcpPath: "/mcp"
        )
    }

    func save(_: CodexReviewRuntime.Preferences) throws {
    }
}
#endif

@MainActor
final class ReviewMonitorUpdateSettingsViewController: NSHostingController<ReviewMonitorUpdateSettingsForm> {
    init(updater: ReviewMonitorCodexUpdater) {
        super.init(rootView: ReviewMonitorUpdateSettingsForm(updater: updater))
        title = ReviewMonitorSettingsPane.updates.label
        preferredContentSize = NSSize(width: 560, height: 320)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

struct ReviewMonitorUpdateSettingsForm: View {
    @Bindable var updater: ReviewMonitorCodexUpdater

    var body: some View {
        Form {
            Section("Codex Updates") {
                HStack {
                    status
                    Spacer()
                    if updater.checkState == .checking { ProgressView().controlSize(.small) }
                    Button("Check for Updates") {
                        Task { await updater.checkForUpdates() }
                    }
                    .disabled(updater.isBusy)
                }
                if let date = updater.lastCheckedAt {
                    LabeledContent("Last checked", value: date.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text("Not checked yet.").foregroundStyle(.secondary)
                }
                Text("Automatically checks at launch and every 8 hours.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            operationStatus
        }
        .formStyle(.grouped)
        .frame(width: 560)
    }

    @ViewBuilder
    private var status: some View {
        switch updater.checkState {
        case .notChecked: Text("Not Checked")
        case .checking: Text("Checking…")
        case .available: Text("Update Available")
        case .upToDate: Text("Up to Date")
        case .unavailable(let message):
            VStack(alignment: .leading) {
                Text("Check Unavailable")
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading) {
                Text("Check Failed")
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var operationStatus: some View {
        switch updater.store.codexUpdateState {
        case .idle: EmptyView()
        case .waitingForReviews:
            Section { Text("The update will start after current reviews finish. New requests are queued.") }
        case .stoppingRuntime, .installing, .restarting:
            Section { Label("Updating Codex…", systemImage: "arrow.triangle.2.circlepath") }
        case .failed(let message):
            Section("Last Update Error") { Text(message).foregroundStyle(.secondary) }
        }
    }
}

#if DEBUG
#Preview("Checking for Updates") { UpdateSettingsPreview(.checking) }
#Preview("Update Available") { UpdateSettingsPreview(.available) }
#Preview("Codex Up to Date") { UpdateSettingsPreview(.upToDate) }
#Preview("Update Check Unavailable") { UpdateSettingsPreview(.unavailable) }
#Preview("Update Check Failed") { UpdateSettingsPreview(.failed) }

@MainActor
private struct UpdateSettingsPreview: View {
    enum Result { case checking, available, upToDate, unavailable, failed }
    @State private var updater: ReviewMonitorCodexUpdater

    init(_ result: Result) {
        _updater = State(initialValue: ReviewMonitorCodexUpdater(
            store: ReviewMonitorUpdatePreview().store,
            check: {
                switch result {
                case .checking:
                    try await Task.sleep(for: .seconds(600))
                    return .upToDate
                case .available:
                    return .available(.init(executableURL: URL(fileURLWithPath: "/preview/codex"), environment: [:]))
                case .upToDate: return .upToDate
                case .unavailable: return .unavailable("This installation is managed outside ReviewMonitor.")
                case .failed: throw PreviewUpdateCheckError.offline
                }
            },
            publishAvailability: { _ in },
            chooseTiming: { nil },
            runUpdate: { _ in },
            presentFailure: { _, _ in }
        ))
    }

    var body: some View {
        ReviewMonitorUpdateSettingsForm(updater: updater)
            .frame(height: 320)
            .task { await updater.checkForUpdates() }
            .onDisappear { Task { await updater.stopChecking() } }
    }
}

private enum PreviewUpdateCheckError: LocalizedError {
    case offline
    var errorDescription: String? { "The update server could not be reached. Check your connection and try again." }
}
#endif
