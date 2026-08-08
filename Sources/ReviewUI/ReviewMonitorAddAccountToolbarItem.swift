import AppKit
import ObservationBridge
import CodexReviewKit

@MainActor
final class ReviewMonitorAddAccountToolbarItem: NSToolbarItem {
    enum Provider: Equatable {
        case chatGPT
        case apiKey
    }

    private let store: CodexReviewStore
    private let auth: CodexReviewAuthModel
    private let toolbarView: AddAccountToolbarItemView
    private let overflowMenuItem: NSMenuItem
    private let providerMenu = NSMenu(title: "Add Account")
    private let chatGPTMenuItem = NSMenuItem(
        title: "ChatGPT",
        action: nil,
        keyEquivalent: ""
    )
    private let apiKeyMenuItem = NSMenuItem(
        title: "API Key",
        action: nil,
        keyEquivalent: ""
    )
    private var observation: PortableObservationTracking.Token?
    private var apiKeyPrompt: NSAlert?
    private var apiKeyField: NSSecureTextField?

    init(
        itemIdentifier: NSToolbarItem.Identifier,
        store: CodexReviewStore
    ) {
        self.store = store
        auth = store.auth
        toolbarView = AddAccountToolbarItemView()
        overflowMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        super.init(itemIdentifier: itemIdentifier)

        visibilityPriority = .high
        view = toolbarView
        menuFormRepresentation = overflowMenuItem
        configureProviderMenu()
        toolbarView.configureActions(
            target: self,
            addAction: #selector(handleShowProviderMenu(_:)),
            cancelAction: #selector(handleCancel(_:))
        )
        toolbarView.didDetachFromWindow = { [weak self] in
            self?.dismissAPIKeyPromptIfNeeded()
        }

        bindObservation()
    }

    isolated deinit {
        observation?.cancel()
        apiKeyField?.stringValue = ""
    }

    private func configureProviderMenu() {
        providerMenu.autoenablesItems = false

        chatGPTMenuItem.target = self
        chatGPTMenuItem.action = #selector(handleAddChatGPT(_:))
        chatGPTMenuItem.image = NSImage(
            systemSymbolName: "person.crop.circle.badge.plus",
            accessibilityDescription: "ChatGPT"
        )

        apiKeyMenuItem.target = self
        apiKeyMenuItem.action = #selector(handleAddAPIKey(_:))
        apiKeyMenuItem.image = NSImage(
            systemSymbolName: "key",
            accessibilityDescription: "API Key"
        )

        providerMenu.addItem(chatGPTMenuItem)
        providerMenu.addItem(apiKeyMenuItem)
    }

    private func bindObservation() {
        observation?.cancel()
        observation = withPortableContinuousObservation { [weak self, auth] event in
            let progress = auth.progress
            let hasPersistedAPIKeyAccount = auth.persistedAccounts.contains { account in
                account.kind == .apiKey
            }
            self?.updateForAuthState(
                progress: progress,
                hasPersistedAPIKeyAccount: hasPersistedAPIKeyAccount,
                animated: event.kind != .initial
            )
        }
    }

    private func updateForAuthState(
        progress: CodexReviewAuthModel.Progress?,
        hasPersistedAPIKeyAccount: Bool,
        animated: Bool
    ) {
        let isAuthenticating = progress != nil
        overflowMenuItem.title = isAuthenticating ? "Cancel Sign-In" : "Add Account"
        overflowMenuItem.target = isAuthenticating ? self : nil
        overflowMenuItem.action = isAuthenticating ? #selector(handleOverflowAction(_:)) : nil
        overflowMenuItem.submenu = isAuthenticating ? nil : providerMenu

        chatGPTMenuItem.isEnabled = isAuthenticating == false
        apiKeyMenuItem.isEnabled = isAuthenticating == false && hasPersistedAPIKeyAccount == false
        apiKeyMenuItem.toolTip = hasPersistedAPIKeyAccount
            ? "Only one API key account can be added."
            : nil

        if isAuthenticating {
            dismissAPIKeyPromptIfNeeded()
        }

        toolbarView.applyPresentation(
            mode: isAuthenticating ? .progress : .add,
            progressDetail: progress?.detail,
            animated: animated
        )
    }

    @objc
    private func handleShowProviderMenu(_ sender: Any?) {
        guard auth.isAuthenticating == false else {
            return
        }
        toolbarView.presentProviderMenu(providerMenu)
    }

    @objc
    private func handleAddChatGPT(_ sender: Any?) {
        performAddAccount(using: .chatGPT)
    }

    @objc
    private func handleAddAPIKey(_ sender: Any?) {
        guard auth.isAuthenticating == false,
              hasPersistedAPIKeyAccount == false
        else {
            return
        }
        presentAPIKeyPrompt()
    }

    private var hasPersistedAPIKeyAccount: Bool {
        auth.persistedAccounts.contains { account in
            account.kind == .apiKey
        }
    }

    private func performAddAccount(using submission: ReviewMonitorAuthenticationSubmission) {
        ReviewMonitorAddAccountAction.perform(
            store: store,
            submission: submission
        )
    }

    private func presentAPIKeyPrompt() {
        guard apiKeyPrompt == nil,
              let window = toolbarView.window
        else {
            return
        }

        let secureField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        secureField.placeholderString = "OpenAI API key"
        secureField.setAccessibilityLabel("OpenAI API key")
        secureField.setAccessibilityIdentifier("review-monitor.add-account-api-key-field")

        let alert = NSAlert()
        alert.messageText = "Add API Key Account"
        alert.informativeText = "Enter the OpenAI API key to use with Codex."
        alert.accessoryView = secureField
        alert.addButton(withTitle: "Add Account")
        alert.addButton(withTitle: "Cancel")

        apiKeyPrompt = alert
        apiKeyField = secureField
        alert.beginSheetModal(for: window) { [weak self, weak alert, weak secureField] response in
            Task { @MainActor in
                guard let alert, let secureField else {
                    return
                }
                guard let self else {
                    secureField.stringValue = ""
                    return
                }
                self.finishAPIKeyPrompt(
                    alert: alert,
                    secureField: secureField,
                    response: response
                )
            }
        }
    }

    private func finishAPIKeyPrompt(
        alert: NSAlert,
        secureField: NSSecureTextField,
        response: NSApplication.ModalResponse
    ) {
        let rawValue = secureField.stringValue
        secureField.stringValue = ""

        guard apiKeyPrompt === alert else {
            return
        }
        apiKeyPrompt = nil
        apiKeyField = nil

        guard response == .alertFirstButtonReturn else {
            return
        }

        var input = ReviewMonitorAPIKeyInput(value: rawValue)
        do {
            performAddAccount(using: try input.takeSubmission())
        } catch {
            ReviewMonitorAddAccountAction.presentValidationFailure(
                store: store,
                error: error
            )
        }
    }

    private func dismissAPIKeyPromptIfNeeded() {
        guard let alert = apiKeyPrompt else {
            return
        }

        apiKeyField?.stringValue = ""
        apiKeyField = nil
        apiKeyPrompt = nil
        if let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .cancel)
        }
    }

    @objc
    private func handleCancel(_ sender: Any?) {
        dismissAPIKeyPromptIfNeeded()
        Task { @MainActor [store] in
            await store.cancelAuthentication()
        }
    }

    @objc
    private func handleOverflowAction(_ sender: Any?) {
        guard auth.isAuthenticating else {
            return
        }
        handleCancel(nil)
    }
}

#if DEBUG
@MainActor
extension ReviewMonitorAddAccountToolbarItem {
    var displayedModeForTesting: AddAccountToolbarItemView.Mode {
        toolbarView.displayedModeForTesting
    }

    var menuTitleForTesting: String {
        overflowMenuItem.title
    }

    var providerMenuItemTitlesForTesting: [String] {
        providerMenu.items.map(\.title)
    }

    var apiKeyProviderIsEnabledForTesting: Bool {
        apiKeyMenuItem.isEnabled
    }

    var isPresentingAPIKeyPromptForTesting: Bool {
        apiKeyPrompt != nil
    }

    var apiKeyPromptContainsTextForTesting: Bool {
        apiKeyField?.stringValue.isEmpty == false
    }

    func selectProviderForTesting(_ provider: Provider) {
        switch provider {
        case .chatGPT:
            handleAddChatGPT(nil)
        case .apiKey:
            handleAddAPIKey(nil)
        }
    }

    func setAPIKeyPromptValueForTesting(_ value: String) {
        guard let apiKeyField else {
            preconditionFailure("The API key prompt is not presented.")
        }
        apiKeyField.stringValue = value
    }

    func completeAPIKeyPromptForTesting(submit: Bool) {
        guard let alert = apiKeyPrompt,
              let secureField = apiKeyField
        else {
            preconditionFailure("The API key prompt is not presented.")
        }
        finishAPIKeyPrompt(
            alert: alert,
            secureField: secureField,
            response: submit ? .alertFirstButtonReturn : .alertSecondButtonReturn
        )
        if let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: submit ? .alertFirstButtonReturn : .alertSecondButtonReturn)
        }
    }

    func waitForStableModeForTesting(_ mode: AddAccountToolbarItemView.Mode) async {
        await toolbarView.waitForStableModeForTesting(mode)
    }
}
#endif
