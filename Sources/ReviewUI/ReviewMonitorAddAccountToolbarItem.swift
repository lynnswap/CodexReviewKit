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
        updateForAuthState(animated: false)
    }

    private func bindObservation() {
        observationScope.update {
            auth.observe(\.phase) { [weak self] _ in
                self?.updateForAuthState(animated: true)
            }
            .store(in: observationScope)
        }
    }

    private func updateForAuthState(animated: Bool) {
        overflowMenuItem.title = auth.isAuthenticating ? "Cancel Sign-In" : "Add Account"
        toolbarView.applyPresentation(
            mode: auth.isAuthenticating ? .progress : .add,
            progressDetail: auth.progress?.detail,
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
