import AppKit
import ObservationBridge
import CodexReview

@MainActor
final class ReviewMonitorAddAccountToolbarItem: NSToolbarItem {
    private let store: CodexReviewStore
    private let auth: CodexReviewAuthModel
    private let toolbarView: AddAccountToolbarItemView
    private let overflowMenuItem: NSMenuItem
    private let observationScope = ObservationScope()

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

    private func bindObservation() {
        observationScope.observe(auth) { [weak self] event, auth in
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
        toolbarView.applyPresentation(
            mode: isAuthenticating ? .progress : .add,
            progressDetail: progress?.detail,
            animated: animated
        )
    }

    @objc
    private func handleAddAccount(_ sender: Any?) {
        ReviewMonitorAddAccountAction.perform(store: store)
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

    func waitForStableModeForTesting(_ mode: AddAccountToolbarItemView.Mode) async {
        await toolbarView.waitForStableModeForTesting(mode)
    }
}
#endif
