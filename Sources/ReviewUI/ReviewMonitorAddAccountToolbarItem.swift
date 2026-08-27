import AppKit
import ObservationBridge
import CodexReview

@MainActor
final class ReviewMonitorAddAccountToolbarItem: NSToolbarItem {
    private let store: CodexReviewStore
    private let auth: CodexReviewAuthModel
    private let toolbarView: AddAccountToolbarItemView
    private let overflowMenuItem: NSMenuItem
    private var observation: PortableObservationTracking.Token?

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
        toolbarView.configureActions(
            target: self,
            addAction: #selector(handleAddAccount(_:)),
            cancelAction: #selector(handleCancel(_:))
        )
        overflowMenuItem.target = self
        overflowMenuItem.action = #selector(handleOverflowAction(_:))

        bindObservation()
    }

    isolated deinit {
        observation?.cancel()
    }

    private func bindObservation() {
        observation?.cancel()
        observation = withPortableContinuousObservation { [weak self, auth] event in
            let progress = auth.progress
            self?.updateForAuthState(progress: progress, animated: event.kind != .initial)
        }
    }

    private func updateForAuthState(
        progress: CodexReviewAuthModel.Progress?,
        animated: Bool
    ) {
        let isAuthenticating = progress != nil
        overflowMenuItem.title = isAuthenticating ? "Cancel Sign-In" : "Add Account"
        overflowMenuItem.submenu = isAuthenticating ? nil : makeProviderMenu()
        overflowMenuItem.target = isAuthenticating ? self : nil
        overflowMenuItem.action = isAuthenticating ? #selector(handleOverflowAction(_:)) : nil
        toolbarView.applyPresentation(
            mode: isAuthenticating ? .progress : .add,
            progressDetail: progress?.detail,
            animated: animated
        )
    }

    @objc
    private func handleAddAccount(_ sender: Any?) {
        let menu = makeProviderMenu()
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: toolbarView.bounds.minX, y: toolbarView.bounds.minY),
            in: toolbarView
        )
    }

    @objc
    private func handleAddChatGPT(_ sender: Any?) {
        ReviewMonitorAddAccountAction.perform(store: store)
    }

    @objc
    private func handleAddAPIKey(_ sender: Any?) {
        ReviewMonitorAddAccountAction.promptAndPerformAPIKey(
            store: store,
            window: toolbarView.window
        )
    }

    @objc
    private func handleCancel(_ sender: Any?) {
        Task { @MainActor [store] in
            await store.cancelAuthentication()
        }
    }

    @objc
    private func handleOverflowAction(_ sender: Any?) {
        if auth.isAuthenticating {
            handleCancel(nil)
        } else {
            handleAddAccount(nil)
        }
    }

    private func makeProviderMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let chatGPT = NSMenuItem(
            title: "ChatGPT",
            action: #selector(handleAddChatGPT(_:)),
            keyEquivalent: ""
        )
        chatGPT.target = self
        menu.addItem(chatGPT)

        let apiKey = NSMenuItem(
            title: "API Key",
            action: #selector(handleAddAPIKey(_:)),
            keyEquivalent: ""
        )
        apiKey.target = self
        apiKey.isEnabled = auth.persistedAccounts.contains { $0.kind == .apiKey } == false
        menu.addItem(apiKey)
        return menu
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

    var providerMenuTitlesForTesting: [String] {
        makeProviderMenu().items.map(\.title)
    }

    var apiKeyProviderIsEnabledForTesting: Bool {
        makeProviderMenu().items.first(where: { $0.title == "API Key" })?.isEnabled == true
    }

    func waitForStableModeForTesting(_ mode: AddAccountToolbarItemView.Mode) async {
        await toolbarView.waitForStableModeForTesting(mode)
    }
}
#endif
