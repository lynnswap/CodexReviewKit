import AppKit
import CodexAppServerKitTesting
import Foundation
import ObservationBridge
import CodexKit
import CodexReviewKit
import SwiftUI
import Testing
@_spi(Testing) @testable import CodexReviewKit
@_spi(PreviewSupport) @testable import ReviewUI
import CodexReviewTesting

@MainActor
private extension CodexReviewAuthModel {
    func updatePersistedAccounts(_ accounts: [CodexReviewAccount]) {
        applyPersistedAccountStates(accounts.map(savedAccountPayload(from:)))
    }

    func updateAccount(_ account: CodexReviewAccount?) {
        updateCurrentAccount(account)
    }
}

@Suite(.serialized)
@MainActor
struct ReviewUITests {

    @Test func addAccountToolbarItemShowsProgressPresentation() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let activeAccount = CodexReviewAccount(email: "first@example.com", planType: "pro")
        store.loadForTesting(
            serverState: .running,
            authPhase: .signingIn(
                .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue."
                )
            ),
            account: activeAccount,
            persistedAccounts: [activeAccount]
        )

        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = makeReviewMonitorSplitViewControllerForTesting(store: store, uiState: uiState)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))

        viewController.attach(to: window)
        let sidebarItem = try #require(viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false
        window.layoutIfNeeded()
        try await waitForAddAccountToolbarItemHidden(viewController, false)

        #expect(viewController.addAccountToolbarItemModeForTesting == .progress)
    }

    @Test func addAccountToolbarItemDoesNotStickInProgressModeWhenAuthenticationEndsImmediately() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let activeAccount = CodexReviewAccount(email: "first@example.com", planType: "pro")
        store.loadForTesting(
            serverState: .running,
            authPhase: .signedOut,
            account: activeAccount,
            persistedAccounts: [activeAccount]
        )

        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = makeReviewMonitorSplitViewControllerForTesting(store: store, uiState: uiState)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))

        viewController.attach(to: window)
        let sidebarItem = try #require(viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false
        window.layoutIfNeeded()
        try await waitForAddAccountToolbarItemHidden(viewController, false)

        #expect(viewController.addAccountToolbarItemModeForTesting == .add)

        store.auth.updatePhase(
            .signingIn(
                .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue."
                )
            )
        )
        store.auth.updatePhase(.signedOut)

        try await waitForAddAccountToolbarMode(viewController, .add)
        #expect(viewController.addAccountToolbarItemModeForTesting == .add)
    }

    @Test func addAccountToolbarItemProvidesOverflowMenuFallback() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let activeAccount = CodexReviewAccount(email: "first@example.com", planType: "pro")
        store.loadForTesting(
            serverState: .running,
            authPhase: .signedOut,
            account: activeAccount,
            persistedAccounts: [activeAccount]
        )

        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = makeReviewMonitorSplitViewControllerForTesting(store: store, uiState: uiState)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))

        viewController.attach(to: window)
        let sidebarItem = try #require(viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false
        window.layoutIfNeeded()
        try await waitForAddAccountToolbarItemHidden(viewController, false)
        try await waitForAddAccountToolbarMode(viewController, .add)

        #expect(viewController.addAccountToolbarMenuTitleForTesting == "Add Account")

        store.auth.updatePhase(
            .signingIn(
                .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue."
                )
            )
        )

        try await waitForAddAccountToolbarMode(viewController, .progress)
        #expect(viewController.addAccountToolbarMenuTitleForTesting == "Cancel Sign-In")
    }

    @Test func addAccountToolbarItemStaysVisibleDuringAuthenticationOutsideAccountSidebar() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let activeAccount = CodexReviewAccount(email: "first@example.com", planType: "pro")
        store.loadForTesting(
            serverState: .running,
            authPhase: .signingIn(
                .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue."
                )
            ),
            account: activeAccount,
            persistedAccounts: [activeAccount]
        )

        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .workspace
        let viewController = makeReviewMonitorSplitViewControllerForTesting(store: store, uiState: uiState)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))

        viewController.attach(to: window)
        let sidebarItem = try #require(viewController.splitViewItems.first)
        sidebarItem.isCollapsed = true
        window.layoutIfNeeded()

        #expect(viewController.addAccountToolbarItemIsHiddenForTesting == false)
        #expect(viewController.addAccountToolbarItemModeForTesting == .progress)
    }

    @Test func addAccountToolbarItemRehidesAfterAuthenticationEndsOutsideAccountSidebar() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let activeAccount = CodexReviewAccount(email: "first@example.com", planType: "pro")
        store.loadForTesting(
            serverState: .running,
            authPhase: .signingIn(
                .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue."
                )
            ),
            account: activeAccount,
            persistedAccounts: [activeAccount]
        )

        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .workspace
        let viewController = makeReviewMonitorSplitViewControllerForTesting(store: store, uiState: uiState)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))

        viewController.attach(to: window)
        let sidebarItem = try #require(viewController.splitViewItems.first)
        sidebarItem.isCollapsed = true
        window.layoutIfNeeded()

        #expect(viewController.addAccountToolbarItemIsHiddenForTesting == false)

        store.auth.updatePhase(.signedOut)

        try await waitForCondition {
            viewController.addAccountToolbarItemIsHiddenForTesting
        }
        #expect(viewController.addAccountToolbarItemIsHiddenForTesting)
    }

    @Test func accountSidebarUsesOutlineViewRows() throws {
        let activeAccount = CodexReviewAccount(email: "active@example.com", planType: "pro")
        let otherAccount = CodexReviewAccount(email: "other@example.com", planType: "plus")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            account: activeAccount,
            persistedAccounts: [activeAccount, otherAccount]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = makeReviewMonitorSplitViewControllerForTesting(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        let accountsViewController = viewController
            .sidebarViewControllerForTesting
            .accountsViewControllerForTesting
        let displayedActiveAccount = try #require(
            store.auth.persistedAccounts.first { $0.email == "active@example.com" }
        )

        #expect(accountsViewController.accountListUsesOutlineViewForTesting)
        #expect(
            accountsViewController.displayedAccountEmailsForTesting == [
                "active@example.com",
                "other@example.com",
            ])
        #expect(accountsViewController.accountRowUsesReviewMonitorAccountCellViewForTesting(displayedActiveAccount))
        #expect(accountsViewController.accountRowUsesSwiftUIRowViewForTesting(displayedActiveAccount))
    }

    @Test func accountDropReordersToDisplayedGapForDownwardMove() async throws {
        let firstAccount = CodexReviewAccount(email: "first@example.com", planType: "pro")
        let secondAccount = CodexReviewAccount(email: "second@example.com", planType: "plus")
        let thirdAccount = CodexReviewAccount(email: "third@example.com", planType: "team")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            account: firstAccount,
            persistedAccounts: [firstAccount, secondAccount, thirdAccount]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = makeReviewMonitorSplitViewControllerForTesting(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        let accountsViewController = viewController
            .sidebarViewControllerForTesting
            .accountsViewControllerForTesting
        let displayedFirstAccount = try #require(
            store.auth.persistedAccounts.first { $0.email == "first@example.com" }
        )
        let fullReloadCountBeforeDrop = accountsViewController.accountFullReloadCountForTesting
        let incrementalMembershipChangeCountBeforeDrop = accountsViewController
            .accountIncrementalMembershipChangeCountForTesting
        let incrementalMoveCountBeforeDrop = accountsViewController.accountIncrementalMoveCountForTesting

        #expect(
            await accountsViewController.performAccountDropForTesting(
                displayedFirstAccount,
                proposedChildIndex: 2
            ))
        #expect(
            store.auth.persistedAccounts.map(\.email) == [
                "second@example.com",
                "first@example.com",
                "third@example.com",
            ])
        try await waitForObservedValue(
            from: accountsViewController.accountListObservationForTesting,
            [
                "second@example.com",
                "first@example.com",
                "third@example.com",
            ]
        ) {
            accountsViewController.displayedAccountEmailsForTesting
        }
        #expect(accountsViewController.accountFullReloadCountForTesting == fullReloadCountBeforeDrop)
        #expect(
            accountsViewController.accountIncrementalMembershipChangeCountForTesting
                == incrementalMembershipChangeCountBeforeDrop
        )
        #expect(accountsViewController.accountIncrementalMoveCountForTesting == incrementalMoveCountBeforeDrop + 1)
    }

    @Test func accountDropBeforeDetachedCurrentSessionMovesToLastSavedPosition() async throws {
        let firstAccount = CodexReviewAccount(email: "first@example.com", planType: "pro")
        let secondAccount = CodexReviewAccount(email: "second@example.com", planType: "plus")
        let detachedAccount = CodexReviewAccount(email: "detached@example.com", planType: "team")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            account: detachedAccount,
            persistedAccounts: [firstAccount, secondAccount]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = makeReviewMonitorSplitViewControllerForTesting(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        let accountsViewController = viewController
            .sidebarViewControllerForTesting
            .accountsViewControllerForTesting
        let displayedFirstAccount = try #require(
            store.auth.persistedAccounts.first { $0.email == "first@example.com" }
        )

        #expect(
            accountsViewController.displayedAccountEmailsForTesting == [
                "first@example.com",
                "second@example.com",
                "detached@example.com",
            ])
        #expect(
            await accountsViewController.performAccountDropForTesting(
                displayedFirstAccount,
                proposedItem: detachedAccount,
                proposedChildIndex: NSOutlineViewDropOnItemIndex
            ))
        #expect(
            store.auth.persistedAccounts.map(\.email) == [
                "second@example.com",
                "first@example.com",
            ])
        try await waitForObservedValue(
            from: accountsViewController.accountListObservationForTesting,
            [
                "second@example.com",
                "first@example.com",
                "detached@example.com",
            ]
        ) {
            accountsViewController.displayedAccountEmailsForTesting
        }
        #expect(
            accountsViewController.displayedAccountEmailsForTesting == [
                "second@example.com",
                "first@example.com",
                "detached@example.com",
            ])
    }

    @Test func reviewChatCellViewUpdatesNativeOwnerStateWhenConfiguredWithNewChat() async throws {
        let placeholderChat = try await reviewChatCellTestChat(
            id: "chat-placeholder",
            title: "Queued review",
            workspaceCWD: "/tmp/placeholder"
        )
        let loadedChat = try await reviewChatCellTestChat(
            id: "chat-loaded",
            title: "Uncommitted changes",
            workspaceCWD: "/tmp/loaded"
        )

        let cellView = makeReviewMonitorReviewChatCellViewForTesting(chat: placeholderChat)
        let initialObjectNode = try #require(cellView.objectValue as? ReviewMonitorCodexSidebarOutlineNode)
        guard case .chat(let initialObjectChat) = initialObjectNode.item else {
            Issue.record("Expected cell to bind a Codex chat node.")
            return
        }

        #expect(initialObjectChat.id == placeholderChat.id)
        #expect(cellView.toolTip == (placeholderChat.workspace?.url.path ?? placeholderChat.preview ?? placeholderChat.title))

        configureReviewMonitorReviewChatCellViewForTesting(cellView, chat: loadedChat)

        let objectNode = try #require(cellView.objectValue as? ReviewMonitorCodexSidebarOutlineNode)
        guard case .chat(let objectChat) = objectNode.item else {
            Issue.record("Expected cell to bind a Codex chat node.")
            return
        }
        #expect(objectChat.id == loadedChat.id)
        #expect(cellView.toolTip == (loadedChat.workspace?.url.path ?? loadedChat.preview ?? loadedChat.title))
    }

    @Test func accountContextMenuPresentationRestoresResponderStateAfterClosing() throws {
        let activeAccount = CodexReviewAccount(email: "active@example.com", planType: "pro")
        let otherAccount = CodexReviewAccount(email: "other@example.com", planType: "plus")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            account: activeAccount,
            persistedAccounts: [activeAccount, otherAccount]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = makeReviewMonitorSplitViewControllerForTesting(store: store, uiState: uiState)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()

        let accountsViewController = viewController
            .sidebarViewControllerForTesting
            .accountsViewControllerForTesting
        let displayedOtherAccount = try #require(
            store.auth.persistedAccounts.first { $0.email == "other@example.com" }
        )
        accountsViewController.focusAccountListForTesting()

        #expect(accountsViewController.accountListHasFirstResponderForTesting)
        #expect(accountsViewController.acceptsFirstResponderForTesting)
        #expect(accountsViewController.hasTemporaryContextMenuForTesting == false)

        var presentedTitles: [String] = []
        var presentedHostingMenu = false
        accountsViewController.presentContextMenuForTesting(for: displayedOtherAccount) { menu in
            presentedTitles = menu.items.map(\.title).filter { $0.isEmpty == false }
            presentedHostingMenu = menu is NSHostingMenu<AccountContextMenuView>
            #expect(accountsViewController.isPresentingContextMenuForTesting)
            #expect(accountsViewController.acceptsFirstResponderForTesting == false)
            #expect(accountsViewController.accountListHasFirstResponderForTesting == false)
            #expect(accountsViewController.hasTemporaryContextMenuForTesting)
        }

        #expect(
            presentedTitles == [
                "other@example.com",
                "Switch",
                "Refresh",
                "Sign Out",
            ])
        #expect(presentedHostingMenu)
        #expect(accountsViewController.isPresentingContextMenuForTesting == false)
        #expect(accountsViewController.acceptsFirstResponderForTesting)
        #expect(accountsViewController.accountListHasFirstResponderForTesting)
        #expect(accountsViewController.hasTemporaryContextMenuForTesting == false)
    }

    @Test func accountOutlineRowsRejectUserSelection() async throws {
        let activeAccount = CodexReviewAccount(email: "active@example.com", planType: "pro")
        let otherAccount = CodexReviewAccount(email: "other@example.com", planType: "plus")
        let backend = AuthActionBackend()
        let store = makeStore(backend: backend)
        store.loadForTesting(
            serverState: .running,
            account: activeAccount,
            persistedAccounts: [activeAccount, otherAccount]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = makeReviewMonitorSplitViewControllerForTesting(store: store, uiState: uiState)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()

        let accountsViewController = viewController
            .sidebarViewControllerForTesting
            .accountsViewControllerForTesting
        let displayedOtherAccount = try #require(
            store.auth.persistedAccounts.first { $0.email == "other@example.com" }
        )

        try await waitForObservedValue(
            from: accountsViewController.accountListObservationForTesting,
            true
        ) {
            accountsViewController.selectedAccountEmailForTesting == "active@example.com"
        }

        #expect(accountsViewController.selectedAccountEmailForTesting == "active@example.com")
        #expect(accountsViewController.allowsUserSelectionForTesting(displayedOtherAccount) == false)
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(accountsViewController.selectedAccountEmailForTesting == "active@example.com")
        #expect(store.auth.selectedAccount?.email == "active@example.com")
        #expect(backend.switchAccountCallCount() == 0)
    }

    @Test func accountDragUsesClickedRowWithoutChangingAuthSelection() async throws {
        let activeAccount = CodexReviewAccount(email: "active@example.com", planType: "pro")
        let otherAccount = CodexReviewAccount(email: "other@example.com", planType: "plus")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            account: activeAccount,
            persistedAccounts: [activeAccount, otherAccount]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = makeReviewMonitorSplitViewControllerForTesting(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        let accountsViewController = viewController
            .sidebarViewControllerForTesting
            .accountsViewControllerForTesting
        let displayedOtherAccount = try #require(
            store.auth.persistedAccounts.first { $0.email == "other@example.com" }
        )
        try await waitForObservedValue(
            from: accountsViewController.accountListObservationForTesting,
            true
        ) {
            accountsViewController.selectedAccountEmailForTesting == "active@example.com"
        }

        #expect(
            accountsViewController.dragPasteboardAccountKeyForTesting(displayedOtherAccount)
                == displayedOtherAccount.accountKey)
        #expect(accountsViewController.selectedAccountEmailForTesting == "active@example.com")
        #expect(store.auth.selectedAccount?.email == "active@example.com")
    }

    @Test func accountBlankClickKeepsAuthenticatedSelection() async throws {
        let activeAccount = CodexReviewAccount(email: "active@example.com", planType: "pro")
        let otherAccount = CodexReviewAccount(email: "other@example.com", planType: "plus")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            account: activeAccount,
            persistedAccounts: [activeAccount, otherAccount]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = makeReviewMonitorSplitViewControllerForTesting(store: store, uiState: uiState)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let accountsViewController = viewController
            .sidebarViewControllerForTesting
            .accountsViewControllerForTesting
        try await waitForObservedValue(
            from: accountsViewController.accountListObservationForTesting,
            true
        ) {
            accountsViewController.selectedAccountEmailForTesting == "active@example.com"
        }

        accountsViewController.clickBlankAreaForTesting()
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(accountsViewController.selectedAccountEmailForTesting == "active@example.com")
        #expect(store.auth.selectedAccount?.email == "active@example.com")
    }

    @Test func accountSelectionChangeKeepsDisplayedAccounts() async throws {
        let activeAccount = CodexReviewAccount(email: "active@example.com", planType: "pro")
        let otherAccount = CodexReviewAccount(email: "other@example.com", planType: "plus")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            account: activeAccount,
            persistedAccounts: [activeAccount, otherAccount]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = makeReviewMonitorSplitViewControllerForTesting(store: store, uiState: uiState)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()

        let accountsViewController = viewController
            .sidebarViewControllerForTesting
            .accountsViewControllerForTesting
        let displayedOtherAccount = try #require(
            store.auth.persistedAccounts.first { $0.email == "other@example.com" }
        )
        try await waitForObservedValue(
            from: accountsViewController.accountListObservationForTesting,
            true
        ) {
            accountsViewController.selectedAccountEmailForTesting == "active@example.com"
        }
        let displayedEmails = accountsViewController.displayedAccountEmailsForTesting
        let fullReloadCountBeforeSelectionChange = accountsViewController.accountFullReloadCountForTesting
        let incrementalMembershipChangeCountBeforeSelectionChange = accountsViewController
            .accountIncrementalMembershipChangeCountForTesting
        let incrementalMoveCountBeforeSelectionChange = accountsViewController.accountIncrementalMoveCountForTesting

        store.auth.selectPersistedAccount(displayedOtherAccount.accountKey)
        try await waitForObservedValue(
            from: accountsViewController.accountListObservationForTesting,
            true
        ) {
            accountsViewController.selectedAccountEmailForTesting == "other@example.com"
        }

        #expect(accountsViewController.selectedAccountEmailForTesting == "other@example.com")
        #expect(accountsViewController.displayedAccountEmailsForTesting == displayedEmails)
        #expect(accountsViewController.accountFullReloadCountForTesting == fullReloadCountBeforeSelectionChange)
        #expect(
            accountsViewController.accountIncrementalMembershipChangeCountForTesting
                == incrementalMembershipChangeCountBeforeSelectionChange
        )
        #expect(
            accountsViewController.accountIncrementalMoveCountForTesting == incrementalMoveCountBeforeSelectionChange)
    }

    @Test func accountContentUpdateDoesNotReloadOutlineTopology() async throws {
        let activeAccount = CodexReviewAccount(email: "active@example.com", planType: "pro")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            account: activeAccount,
            persistedAccounts: [activeAccount]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = makeReviewMonitorSplitViewControllerForTesting(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        let accountsViewController = viewController
            .sidebarViewControllerForTesting
            .accountsViewControllerForTesting
        let displayedActiveAccount = try #require(store.auth.persistedAccounts.first)
        let fullReloadCountBeforeUpdate = accountsViewController.accountFullReloadCountForTesting
        let incrementalMembershipChangeCountBeforeUpdate = accountsViewController
            .accountIncrementalMembershipChangeCountForTesting
        let incrementalMoveCountBeforeUpdate = accountsViewController.accountIncrementalMoveCountForTesting

        let updatedAccount = CodexReviewAccount(email: "active@example.com", planType: "team")
        store.auth.applyPersistedAccountStates([savedAccountPayload(from: updatedAccount)])
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(store.auth.persistedAccounts.first === displayedActiveAccount)
        #expect(store.auth.persistedAccounts.first?.planType == "team")
        #expect(accountsViewController.displayedAccountEmailsForTesting == ["active@example.com"])
        #expect(accountsViewController.accountFullReloadCountForTesting == fullReloadCountBeforeUpdate)
        #expect(
            accountsViewController.accountIncrementalMembershipChangeCountForTesting
                == incrementalMembershipChangeCountBeforeUpdate
        )
        #expect(accountsViewController.accountIncrementalMoveCountForTesting == incrementalMoveCountBeforeUpdate)
    }

    @Test func accountListTracksDetachedCurrentSessionMembership() async throws {
        let savedAccount = CodexReviewAccount(email: "saved@example.com", planType: "pro")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            account: savedAccount,
            persistedAccounts: [savedAccount]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = makeReviewMonitorSplitViewControllerForTesting(store: store, uiState: uiState)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()

        let accountsViewController = viewController
            .sidebarViewControllerForTesting
            .accountsViewControllerForTesting
        #expect(accountsViewController.displayedAccountEmailsForTesting == ["saved@example.com"])
        let fullReloadCountBeforeMembershipChanges = accountsViewController.accountFullReloadCountForTesting
        let incrementalMembershipChangeCountBeforeMembershipChanges = accountsViewController
            .accountIncrementalMembershipChangeCountForTesting
        let incrementalMoveCountBeforeMembershipChanges = accountsViewController.accountIncrementalMoveCountForTesting

        store.auth.updateCurrentAccount(CodexReviewAccount(email: "detached@example.com", planType: "pro"))
        try await waitForObservedValue(
            from: accountsViewController.accountListObservationForTesting,
            [
                "saved@example.com",
                "detached@example.com",
            ]
        ) {
            accountsViewController.displayedAccountEmailsForTesting
        }

        #expect(
            accountsViewController.displayedAccountEmailsForTesting == [
                "saved@example.com",
                "detached@example.com",
            ])
        #expect(accountsViewController.selectedAccountEmailForTesting == "detached@example.com")
        #expect(accountsViewController.accountFullReloadCountForTesting == fullReloadCountBeforeMembershipChanges)
        #expect(
            accountsViewController.accountIncrementalMembershipChangeCountForTesting
                == incrementalMembershipChangeCountBeforeMembershipChanges + 1
        )
        #expect(
            accountsViewController.accountIncrementalMoveCountForTesting == incrementalMoveCountBeforeMembershipChanges)

        store.auth.selectPersistedAccount(savedAccount.accountKey)
        try await waitForObservedValue(
            from: accountsViewController.accountListObservationForTesting,
            ["saved@example.com"]
        ) {
            accountsViewController.displayedAccountEmailsForTesting
        }

        #expect(accountsViewController.displayedAccountEmailsForTesting == ["saved@example.com"])
        #expect(accountsViewController.selectedAccountEmailForTesting == "saved@example.com")
        #expect(accountsViewController.accountFullReloadCountForTesting == fullReloadCountBeforeMembershipChanges)
        #expect(
            accountsViewController.accountIncrementalMembershipChangeCountForTesting
                == incrementalMembershipChangeCountBeforeMembershipChanges + 2
        )
        #expect(
            accountsViewController.accountIncrementalMoveCountForTesting == incrementalMoveCountBeforeMembershipChanges)
    }

    @Test func accountActionAlertRestoresSelectionToAuthenticatedAccount() async throws {
        let activeAccount = CodexReviewAccount(email: "active@example.com", planType: "pro")
        let otherAccount = CodexReviewAccount(email: "other@example.com", planType: "plus")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            account: activeAccount,
            persistedAccounts: [activeAccount, otherAccount]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = makeReviewMonitorSplitViewControllerForTesting(store: store, uiState: uiState)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()

        let accountsViewController = viewController
            .sidebarViewControllerForTesting
            .accountsViewControllerForTesting
        let displayedOtherAccount = try #require(
            store.auth.persistedAccounts.first { $0.email == "other@example.com" }
        )

        accountsViewController.selectAccountRowForTesting(displayedOtherAccount)
        #expect(accountsViewController.selectedAccountEmailForTesting == "other@example.com")

        store.auth.presentAccountActionAlert(
            title: "Failed to Switch Accounts",
            message: "Request failed."
        )
        try await waitForObservedValue(
            from: accountsViewController.accountPromptObservationForTesting,
            true
        ) {
            accountsViewController.selectedAccountEmailForTesting == "active@example.com"
        }

        #expect(accountsViewController.selectedAccountEmailForTesting == "active@example.com")
    }

    @Test func reviewChatsPresentOnInitialLoadStayUnselected() {
        let activeChat = makeReviewChatFixtureForTesting(title: "Uncommitted changes", status: .running)
        let recentChat = makeReviewChatFixtureForTesting(title: "Commit: abc123", status: .succeeded)
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            fixtures: [activeChat, recentChat]
        )
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarViewControllerForTesting.selectedReviewChatIDForTesting == nil)
        #expect(viewController.contentPaneViewControllerForTesting.isShowingEmptyStateForTesting)
        #expect(viewController.contentPaneViewControllerForTesting.displayedTitleForTesting == nil)
    }

    @Test func selectingReviewChatUpdatesDetailPane() async throws {
        let activeChat = makeReviewChatFixtureForTesting(
            title: "Uncommitted changes",
            status: .running,
            chatEntries: [.init(kind: .agentMessage, text: "Running review")]
        )
        let recentChat = makeReviewChatFixtureForTesting(
            title: "Commit: abc123",
            preview: "MCP server codex_review ready.",
            status: .succeeded,
            chatEntries: [.init(kind: .agentMessage, text: "Findings ready")]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            fixtures: [activeChat, recentChat]
        )
        let backend = makeWindowHarness(store: store)
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: recentChat.chatID)

        let selectedSnapshot = try await awaitChatRenderForTesting(
            recentChat,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(selectedSnapshot.title == nil)
        #expect(selectedSnapshot.summary == nil)
        #expect(selectedSnapshot.log == reviewChatLogText(for: recentChat))
        #expect(selectedSnapshot.isShowingEmptyState == false)
        #expect(window.title == recentChat.chat.title)
        #expect(window.subtitle == recentChat.cwd)
        #expect(transport.logUsesFindBarForTesting)
        #expect(transport.logIsIncrementalSearchingEnabledForTesting)
        #expect(transport.logFindBarVisibleForTesting == false)

        let findItem = textFinderMenuItemForTesting(.showFindInterface)
        #expect(viewController.validateUserInterfaceItem(findItem))
        viewController.performTextFinderAction(findItem)
        #expect(transport.logFindBarVisibleForTesting)

        replaceChatLogTextForTesting(
            "Old selection log",
            for: activeChat.chatID,
            fixtureID: activeChat.id,
            turnID: activeChat.turnID
        )
        appendChatLogEntryForTesting(
            .init(kind: .progress, text: "Current selection log after stale mutation"),
            to: recentChat.chatID,
            turnID: recentChat.turnID
        )

        let updatedSnapshot = try await awaitChatRenderForTesting(recentChat, in: transport) { snapshot in
            snapshot.log.contains("Current selection log after stale mutation")
        }
        #expect(updatedSnapshot.log.contains("Old selection log") == false)
        #expect(transport.displayedLogForTesting.contains("Old selection log") == false)
    }

    @Test func detailPaneRendersSelectedReviewChatLogProjection() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-monitor-log",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            preview: "No correctness issues found.",
            turnID: CodexTurnID(rawValue: "turn-monitor-log"),
            status: .succeeded,
            startedAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 201),
            chatEntries: [
                .init(
                    kind: .command,
                    groupID: "cmd_1",
                    text: "$ git diff --stat",
                    metadata: .init(
                        sourceType: "commandExecution",
                        status: "completed",
                        itemID: "cmd_1",
                        command: "git diff --stat",
                        commandStatus: "completed"
                    )
                ),
                .init(
                    kind: .commandOutput,
                    groupID: "cmd_1",
                    text: "README.md | 1 +",
                    metadata: .init(
                        sourceType: "commandExecution",
                        status: "completed",
                        itemID: "cmd_1",
                        command: "git diff --stat",
                        commandStatus: "completed"
                    )
                ),
                .init(kind: .agentMessage, text: "No correctness issues found."),
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            fixtures: [chat]
        )
        let backend = makeWindowHarness(store: store)
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)

        let selectedSnapshot = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(selectedSnapshot.title == nil)
        #expect(selectedSnapshot.summary == nil)
        #expect(window.title == chat.chat.title)
        #expect(window.subtitle == chat.cwd)

        let displayedLog = transport.displayedLogForTesting
        #expect(selectedSnapshot.log == displayedLog)
        #expect(displayedLog.contains("Ran git diff"))
        #expect(displayedLog.contains("$ git diff --stat") == false)
        #expect(displayedLog.contains("Command output - 1 line") == false)
        #expect(displayedLog.contains("README.md | 1 +") == false)
        #expect(displayedLog.contains("No correctness issues found."))
        #expect(transport.logCommandOutputPanelCountForTesting == 1)
        #expect(transport.logTerminalDecorationRectCountForTesting == 0)
        #expect(transport.logExpandedCommandOutputPanelCountForTesting == 0)
        #expect(transport.logCommandOutputPanelUsesTextKit2ForTesting == false)
    }

    @Test func detailPaneRendersSelectedChatStreamUpdates() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-selected-chat-stream-detail",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            turnID: CodexTurnID(rawValue: "turn-selected-chat-stream-detail"),
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            chatEntries: []
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            fixtures: [chat]
        )
        let backend = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 860, height: 520)
        )
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        appendChatLogEntryForTesting(
            .init(kind: .agentMessage, groupID: "message-direct", text: "Selected chat detail update"),
            to: chat.chatID,
            turnID: chat.turnID
        )

        var snapshot = try await awaitChatRenderForTesting(chat, in: transport)
        #expect(snapshot.log == "Selected chat detail update")

        appendChatLogEntryForTesting(
            .init(
                kind: .command,
                groupID: "cmd-direct",
                text: "$ swift test",
                metadata: .init(command: "swift test", commandStatus: "completed")
            ),
            to: chat.chatID,
            turnID: chat.turnID
        )
        appendChatLogEntryForTesting(
            .init(
                kind: .commandOutput,
                groupID: "cmd-direct",
                text: "Tests passed",
                metadata: .init(command: "swift test", exitCode: 0, commandStatus: "completed")
            ),
            to: chat.chatID,
            turnID: chat.turnID
        )

        snapshot = try await awaitChatRenderForTesting(chat, in: transport) {
            $0.log.contains("Ran swift test")
        }
        #expect(snapshot.log.contains("Selected chat detail update"))
        #expect(snapshot.log.contains("Ran swift test"))
        #expect(snapshot.log.contains("$ swift test") == false)
        #expect(snapshot.log.contains("Tests passed") == false)
        #expect(transport.logCommandOutputPanelCountForTesting == 1)

        let panelBlockID = chatCommandOutputBlockIDForTesting(turnID: chat.turnID, itemID: "cmd-direct")
        #expect(transport.clickLogCommandOutputPanelHeaderForTesting(blockID: panelBlockID))
        try await waitForCondition {
            transport.logRenderIsIdleForTesting
                && transport.logCommandOutputPanelTerminalTextForTesting(blockID: panelBlockID)?
                    .contains("Tests passed") == true
        }
        #expect(
            transport.logCommandOutputPanelTerminalTextForTesting(blockID: panelBlockID)?.contains("$ swift test")
                == true)
        #expect(
            transport.logCommandOutputPanelTerminalTextForTesting(blockID: panelBlockID)?.contains("Tests passed")
                == true)
    }

    @Test func selectedChatFailedCommandPreservesFailedPanelStatus() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-selected-chat-failed-command",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            turnID: CodexTurnID(rawValue: "turn-selected-chat-failed-command"),
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            chatEntries: []
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            fixtures: [chat]
        )
        let backend = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 860, height: 520)
        )
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        appendChatLogEntryForTesting(
            .init(
                kind: .commandOutput,
                groupID: "cmd-failed-direct",
                text: "Tests failed",
                metadata: .init(command: "swift test", commandStatus: "failed")
            ),
            to: chat.chatID,
            turnID: chat.turnID
        )

        let snapshot = try await awaitChatRenderForTesting(chat, in: transport) {
            $0.log.contains("Ran swift test")
        }
        #expect(snapshot.log.contains("Tests failed") == false)
        #expect(transport.logCommandOutputPanelCountForTesting == 1)

        let panelBlockID = chatCommandOutputBlockIDForTesting(turnID: chat.turnID, itemID: "cmd-failed-direct")
        #expect(transport.clickLogCommandOutputPanelHeaderForTesting(blockID: panelBlockID))
        await awaitNativeLayoutTurn()
        #expect(transport.logCommandOutputPanelResultTextForTesting == "Failed")
        #expect(
            transport.logCommandOutputPanelTerminalTextForTesting(blockID: panelBlockID)?.contains("Tests failed")
                == true)
    }

    @Test func selectedChatRunningCommandOutputStaysActive() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-selected-chat-running-command",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            turnID: CodexTurnID(rawValue: "turn-selected-chat-running-command"),
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            chatEntries: []
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            fixtures: [chat]
        )
        let backend = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 860, height: 520)
        )
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        appendChatLogEntryForTesting(
            .init(
                kind: .commandOutput,
                groupID: "cmd-running-direct",
                text: "Building...",
                metadata: .init(command: "swift test", commandStatus: "running")
            ),
            to: chat.chatID,
            turnID: chat.turnID
        )

        let snapshot = try await awaitChatRenderForTesting(chat, in: transport) {
            $0.log.contains("Running swift test")
        }
        #expect(snapshot.log.contains("Running swift test"))
        #expect(snapshot.log.contains("Ran swift test") == false)
        #expect(snapshot.log.contains("Building...") == false)
        #expect(transport.logCommandOutputPanelCountForTesting == 1)

        let panelBlockID = chatCommandOutputBlockIDForTesting(turnID: chat.turnID, itemID: "cmd-running-direct")
        #expect(transport.clickLogCommandOutputPanelHeaderForTesting(blockID: panelBlockID))
        await awaitNativeLayoutTurn()
        #expect(transport.logCommandOutputPanelResultTextForTesting == "running")
        #expect(
            transport.logCommandOutputPanelTerminalTextForTesting(blockID: panelBlockID)?.contains("Building...")
                == true)
    }

    @Test func selectedChatFileChangePreservesPanelTitle() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-selected-chat-file-change",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            turnID: CodexTurnID(rawValue: "turn-selected-chat-file-change"),
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            chatEntries: []
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            fixtures: [chat]
        )
        let backend = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 860, height: 520)
        )
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        appendChatLogEntryForTesting(
            .init(
                kind: .fileChange,
                groupID: "file-change-direct",
                text: "Sources/App.swift | 12 ++++++------",
                metadata: .init(
                    title: "Updated Sources/App.swift",
                    commandStatus: "completed"
                )
            ),
            to: chat.chatID,
            turnID: chat.turnID
        )

        let snapshot = try await awaitChatRenderForTesting(chat, in: transport) {
            $0.log.contains("Updated Sources/App.swift")
        }
        #expect(snapshot.log.contains("Updated Sources/App.swift"))
        #expect(snapshot.log.contains("Ran command") == false)
        #expect(snapshot.log.contains("Sources/App.swift | 12") == false)
        #expect(transport.logCommandOutputPanelCountForTesting == 1)

        let panelBlockID = chatCommandOutputBlockIDForTesting(turnID: chat.turnID, itemID: "file-change-direct")
        #expect(transport.clickLogCommandOutputPanelHeaderForTesting(blockID: panelBlockID))
        await awaitNativeLayoutTurn()
        #expect(transport.logCommandOutputPanelResultTextForTesting == "Success")
        #expect(
            transport.logCommandOutputPanelTerminalTextForTesting(blockID: panelBlockID)?
                .contains("Sources/App.swift | 12 ++++++------") == true
        )
    }

    @Test func contextCompactionMarkerRendersAsVisibleLogTextWithoutCommandPanel() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-context-compaction-marker",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            turnID: CodexTurnID(rawValue: "turn-context-compaction-marker"),
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            chatEntries: [
                .init(
                    kind: .contextCompaction,
                    groupID: "compact_1",
                    replacesGroup: true,
                    text: "Automatically compacting context",
                    metadata: .init(
                        sourceType: "contextCompaction",
                        status: "inProgress",
                        itemID: "compact_1"
                    )
                )
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            fixtures: [chat]
        )
        let backend = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 860, height: 520)
        )
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)

        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(transport.displayedLogForTesting == "Automatically compacting context")
        #expect(transport.logFindStringForTesting.contains("Automatically compacting context"))
        #expect(transport.logCommandOutputPanelCountForTesting == 0)

        appendChatLogEntryForTesting(
            .init(
                kind: .contextCompaction,
                groupID: "compact_1",
                replacesGroup: true,
                text: "Context automatically compacted",
                metadata: .init(
                    sourceType: "contextCompaction",
                    status: "completed",
                    itemID: "compact_1"
                )
            ),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)

        #expect(transport.displayedLogForTesting == "Context automatically compacted")
        #expect(transport.displayedLogForTesting.contains("Automatically compacting context") == false)
        #expect(transport.logFindStringForTesting.contains("Context automatically compacted"))
        #expect(transport.logCommandOutputPanelCountForTesting == 0)
    }

    @Test func commandOutputRendersCollapsedTextKitPanelAndExpandsInline() async throws {
        let outputText = (1...9)
            .map { "output line \($0)" }
            .joined(separator: "\n")
        let commandMetadata = ReviewChatLogEntryForTesting.Metadata(
            sourceType: "command",
            title: "Ran command for 17s",
            status: "succeeded",
            command: "swift test",
            exitCode: 0,
            commandStatus: "completed"
        )
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-command-output-panel",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            chatEntries: [
                .init(kind: .command, groupID: "cmd_1", text: "$ swift test"),
                .init(
                    kind: .commandOutput,
                    groupID: "cmd_1",
                    text: outputText,
                    metadata: commandMetadata
                ),
                .init(kind: .agentMessage, text: "Continuing after the command."),
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            fixtures: [chat]
        )
        let backend = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 860, height: 520)
        )
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)

        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(transport.displayedLogForTesting.contains("Ran swift test"))
        #expect(transport.displayedLogForTesting.contains("Ran swift test - 9 lines") == false)
        #expect(transport.displayedLogForTesting.contains("$ swift test") == false)
        #expect(transport.displayedLogForTesting.contains("output line 1") == false)
        let titleRange = (transport.displayedLogForTesting as NSString).range(of: "Ran swift test")
        try #require(titleRange.location != NSNotFound)
        #expect(transport.logHitTestTargetsDocumentViewForFirstOccurrenceForTesting("Ran swift test"))
        transport.setSelectedLogRangeForTesting(titleRange)
        #expect(transport.logHitTestTargetsDocumentViewForFirstOccurrenceForTesting("Ran swift test"))
        #expect(transport.logCommandOutputPanelCountForTesting == 1)
        #expect(transport.logExpandedCommandOutputPanelCountForTesting == 0)
        #expect(transport.logCommandOutputPanelToggleSymbolNameForTesting == "chevron.forward")
        #expect(abs(transport.logCommandOutputPanelChevronSizeDeltaForTesting ?? .infinity) <= 1)
        #expect(abs(transport.logCommandOutputPanelChevronVerticalAlignmentDeltaForTesting ?? .infinity) <= 0.5)
        #expect(transport.logCommandOutputPanelUsesInlineAttachmentForTesting)
        #expect(transport.logCommandOutputPanelUsesButtonAttachmentForTesting)
        #expect(transport.logCollapsedCommandOutputPanelAttachmentLineHeightForTesting == nil)
        #expect(transport.logCollapsedCommandOutputPanelAttachmentPayloadIsEmptyForTesting)
        #expect(transport.logCommandOutputPanelUsesSystemMaterialBackgroundForTesting == false)
        #expect(transport.logCommandOutputPanelUsesTextKit2ForTesting == false)
        #expect(transport.logFindStringForTesting.contains("Ran swift test"))
        #expect(transport.logFindStringForTesting.contains("$ swift test") == false)
        #expect(transport.logFindStringForTesting.contains("output line 3") == false)

        let expandReloadCount = transport.logReloadCountForTesting
        #expect(transport.clickFirstLogCommandOutputPanelHeaderForTesting())
        #expect(transport.logReloadCountForTesting == expandReloadCount)
        #expect(transport.logExpandedCommandOutputPanelCountForTesting == 1)
        #expect(transport.logCommandOutputPanelToggleSymbolNameForTesting == "chevron.down")
        await awaitNativeLayoutTurn()

        #expect(transport.logCommandOutputPanelCountForTesting == 1)
        #expect(transport.logExpandedCommandOutputPanelCountForTesting == 1)
        #expect(transport.logCommandOutputPanelToggleSymbolNameForTesting == "chevron.down")
        #expect(transport.logCommandOutputPanelUsesSystemMaterialBackgroundForTesting)
        #expect(transport.logCommandOutputPanelUsesTextKit2ForTesting)
        #expect(transport.logCommandOutputPanelOutputScrollUsesHorizontalScrollingForTesting)
        #expect((5...6).contains(transport.logCommandOutputPanelVisibleLineCapacityForTesting))
        #expect(transport.logCommandOutputPanelResultTextForTesting == "Success")
        #expect(transport.logCommandOutputPanelCommandLineTextForTesting == "$ swift test")
        #expect(transport.logCommandOutputPanelOutputScrollTextForTesting?.contains("$ swift test") == false)
        #expect(transport.logCommandOutputPanelOutputScrollTextForTesting?.contains("output line 1") == true)
        #expect(transport.logCommandOutputPanelOutputHitTestTargetsTextViewForTesting)
        #expect(transport.logFindStringForTesting.contains("Ran swift test"))
        #expect(transport.logFindStringForTesting.contains("$ swift test") == false)
        #expect(transport.logFindStringForTesting.contains("output line 3") == false)
        #expect(transport.logCommandOutputPanelOutputScrollIsScrollableForTesting)
        let initialOutputScrollOffset = try #require(
            transport.logCommandOutputPanelOutputScrollVerticalOffsetForTesting)
        let initialOutputScrollMaximumOffset = try #require(
            transport.logCommandOutputPanelOutputScrollMaximumVerticalOffsetForTesting)
        #expect(abs(initialOutputScrollOffset - initialOutputScrollMaximumOffset) <= 0.5)
        #expect(transport.scrollCommandOutputPanelOutputForTesting(deltaY: -24))
        let scrolledOutputScrollOffset = try #require(
            transport.logCommandOutputPanelOutputScrollVerticalOffsetForTesting)
        #expect(scrolledOutputScrollOffset < initialOutputScrollMaximumOffset)
        let expandedOutputAppendReloadCount = transport.logReloadCountForTesting
        appendChatLogEntryForTesting(
            .init(
                kind: .commandOutput,
                groupID: "cmd_1",
                text: "\noutput line 10",
                metadata: commandMetadata
            ),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)
        await awaitNativeLayoutTurn()
        #expect(transport.logReloadCountForTesting == expandedOutputAppendReloadCount)
        let offsetAfterOutputAppend = try #require(transport.logCommandOutputPanelOutputScrollVerticalOffsetForTesting)
        #expect(abs(offsetAfterOutputAppend - scrolledOutputScrollOffset) <= 0.5)
        let collapseReloadCount = transport.logReloadCountForTesting
        #expect(transport.clickFirstLogCommandOutputPanelHeaderForTesting())
        #expect(transport.logReloadCountForTesting == collapseReloadCount)
        #expect(transport.logExpandedCommandOutputPanelCountForTesting == 0)
        #expect(transport.logCommandOutputPanelToggleSymbolNameForTesting == "chevron.forward")
        await awaitNativeLayoutTurn()
        #expect(transport.logExpandedCommandOutputPanelCountForTesting == 0)
        let reopenReloadCount = transport.logReloadCountForTesting
        #expect(transport.clickFirstLogCommandOutputPanelHeaderForTesting())
        #expect(transport.logReloadCountForTesting == reopenReloadCount)
        #expect(transport.logExpandedCommandOutputPanelCountForTesting == 1)
        await awaitNativeLayoutTurn()
        let reopenedOutputScrollOffset = try #require(
            transport.logCommandOutputPanelOutputScrollVerticalOffsetForTesting)
        let reopenedOutputScrollMaximumOffset = try #require(
            transport.logCommandOutputPanelOutputScrollMaximumVerticalOffsetForTesting)
        #expect(abs(reopenedOutputScrollOffset - reopenedOutputScrollMaximumOffset) <= 0.5)
        #expect(transport.logCommandOutputPanelTerminalTextForTesting?.contains("$ swift test") == true)
        #expect(transport.logCommandOutputPanelTerminalTextForTesting?.contains("output line 1") == true)
        #expect(transport.logCommandOutputPanelTerminalTextForTesting?.contains("Ran swift test - 9 lines") == false)
        #expect(transport.displayedLogForTesting.contains("output line 9") == false)
        #expect(transport.logFindStringForTesting.contains("output line 9") == false)

        appendChatLogEntryForTesting(
            .init(
                kind: .commandOutput,
                groupID: "cmd_1",
                text: "\noutput line 11",
                metadata: commandMetadata
            ),
            to: chat.chatID,
            turnID: chat.turnID
        )
        appendChatLogEntryForTesting(
            .init(kind: .agentMessage, text: "Visible text after command output."),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)
        await awaitNativeLayoutTurn()
        #expect(transport.logCommandOutputPanelTerminalTextForTesting?.contains("output line 11") == true)
        #expect(transport.logFindStringForTesting.contains("output line 11") == false)
        #expect(transport.displayedLogForTesting.contains("Visible text after command output."))
    }

    @Test func expandingCommandOutputPanelsPreserveVisibleContent() async throws {
        let firstOutput = (1...80)
            .map { "first output line \($0)" }
            .joined(separator: "\n")
        let secondOutput = (1...80)
            .map { "second output line \($0)" }
            .joined(separator: "\n")
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-command-output-panel-isolation",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            chatEntries: [
                .init(kind: .command, groupID: "cmd_1", text: "$ swift test"),
                .init(
                    kind: .commandOutput,
                    groupID: "cmd_1",
                    text: firstOutput,
                    metadata: .init(sourceType: "command", title: "Ran swift test for 1s", status: "succeeded")
                ),
                .init(kind: .command, groupID: "cmd_2", text: "$ git diff"),
                .init(
                    kind: .commandOutput,
                    groupID: "cmd_2",
                    text: secondOutput,
                    metadata: .init(sourceType: "command", title: "Ran git diff for 1s", status: "succeeded")
                ),
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            fixtures: [chat]
        )
        let backend = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 860, height: 900)
        )
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)

        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        let firstBlockID = chatCommandOutputBlockIDForTesting(turnID: chat.turnID, itemID: "cmd_1")
        let secondBlockID = chatCommandOutputBlockIDForTesting(turnID: chat.turnID, itemID: "cmd_2")
        #expect(transport.clickLogCommandOutputPanelHeaderForTesting(blockID: firstBlockID))
        await awaitNativeLayoutTurn()

        #expect(
            transport.logCommandOutputPanelTerminalTextForTesting(blockID: firstBlockID)?
                .contains("first output line 80") == true)

        #expect(transport.clickLogCommandOutputPanelHeaderForTesting(blockID: secondBlockID))
        await awaitNativeLayoutTurn()

        #expect(
            transport.logCommandOutputPanelTerminalTextForTesting(blockID: firstBlockID)?
                .contains("first output line 80") == true)
        #expect(
            transport.logCommandOutputPanelTerminalTextForTesting(blockID: secondBlockID)?
                .contains("second output line 80") == true)
    }

    @Test func startedCommandRendersAsCollapsedPanelBeforeOutputArrives() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-command-start-panel",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            chatEntries: [
                .init(kind: .command, groupID: "cmd_1", text: "$ swift test")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            fixtures: [chat]
        )
        let backend = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 860, height: 520)
        )
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)

        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(transport.logCommandOutputPanelCountForTesting == 1)
        #expect(transport.displayedLogForTesting.contains("Running swift test"))
        #expect(transport.displayedLogForTesting.contains("$ swift test") == false)

        appendChatLogEntryForTesting(
            .init(
                kind: .commandOutput,
                groupID: "cmd_1",
                text: "output line 1",
                metadata: .init(
                    sourceType: "commandExecution",
                    title: "Command output",
                    status: "succeeded",
                    command: "swift test",
                    exitCode: 0,
                    commandStatus: "completed"
                )
            ),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)
        #expect(transport.logCommandOutputPanelCountForTesting == 1)
        #expect(transport.displayedLogForTesting.contains("Ran swift test"))
        #expect(transport.displayedLogForTesting.contains("$ swift test") == false)
        #expect(transport.displayedLogForTesting.contains("output line 1") == false)
    }

    @Test func expandingCommandOutputKeepsPanelTextOutOfActiveFindSnapshot() async throws {
        let outputText = (1...5)
            .map { "output line \($0)" }
            .joined(separator: "\n")
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-command-output-find-refresh",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            chatEntries: [
                .init(kind: .command, groupID: "cmd_1", text: "$ swift test"),
                .init(kind: .commandOutput, groupID: "cmd_1", text: outputText),
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            fixtures: [chat]
        )
        let backend = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 860, height: 520)
        )
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        try await withFindPasteboardString(nil) {
            viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
            #expect(transport.logFindBarVisibleForTesting)
            #expect(transport.setLogVisibleFindBarSearchStringForTesting("Running swift test"))
            #expect(transport.logFindClientUsesSnapshotForTesting)
            #expect(transport.logFindClientSnapshotMapsToDocumentForTesting)
            #expect(transport.logFindStringForTesting.contains("Running swift test"))
            #expect(transport.logFindStringForTesting.contains("$ swift test") == false)
            #expect(transport.logFindStringForTesting.contains("output line 3") == false)

            #expect(transport.clickFirstLogCommandOutputPanelHeaderForTesting())
            await awaitNativeLayoutTurn()

            #expect(transport.logFindClientUsesSnapshotForTesting)
            #expect(transport.logFindClientSnapshotMapsToDocumentForTesting)
            #expect(transport.logFindStringForTesting.contains("Running swift test"))
            #expect(transport.logFindStringForTesting.contains("$ swift test") == false)
            #expect(transport.logFindStringForTesting.contains("output line 3") == false)

            appendChatLogEntryForTesting(
                .init(kind: .commandOutput, groupID: "cmd_1", text: "\noutput line 6"),
                to: chat.chatID,
                turnID: chat.turnID
            )
            _ = try await awaitChatRenderForTesting(chat, in: transport)
            await awaitNativeLayoutTurn()

            #expect(transport.logFindClientUsesSnapshotForTesting)
            #expect(transport.logFindClientSnapshotMapsToDocumentForTesting)
            #expect(transport.logFindStringForTesting.contains("Running swift test"))
            #expect(transport.logFindStringForTesting.contains("output line 6") == false)
        }
    }

    @Test func switchingSelectedReviewChatRebindsDetailPane() async throws {
        let activeChat = makeReviewChatFixtureForTesting(
            id: "chat-active",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Active review in progress.",
            logText: "Active log\n"
        )
        let recentChat = makeReviewChatFixtureForTesting(
            id: "chat-recent",
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "Recent review completed.",
            logText: "Recent log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            fixtures: [activeChat, recentChat]
        )
        let backend = makeWindowHarness(store: store)
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: activeChat.chatID)

        let activeSnapshot = try await awaitChatRenderForTesting(
            activeChat,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(activeSnapshot.title == nil)
        #expect(activeSnapshot.summary == nil)
        #expect(window.title == activeChat.chat.title)
        #expect(window.subtitle == activeChat.cwd)
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: recentChat.chatID)

        let recentSnapshot = try await awaitChatRenderForTesting(
            recentChat,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(
            recentSnapshot
                == .init(
                    title: nil,
                    summary: nil,
                    log: reviewChatLogText(for: recentChat),
                    isShowingEmptyState: false
                )
        )
        #expect(window.title == recentChat.chat.title)
        #expect(window.subtitle == recentChat.cwd)
    }

    @Test func firstSelectionFromEmptyStatePinsUnvisitedReviewChatToBottom() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-first-bottom",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        transport.view.layoutSubtreeIfNeeded()

        try await waitForLogPinnedToBottom(in: transport)
    }

    @Test func switchingSelectedReviewChatStartsUnvisitedReviewChatAtBottomAndRestoresPreviousOffset() async throws {
        let longActiveLog = (0..<400).map { "active line \($0)" }.joined(separator: "\n")
        let longRecentLog = (0..<400).map { "recent line \($0)" }.joined(separator: "\n")
        let activeChat = makeReviewChatFixtureForTesting(
            id: "chat-active-scroll",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Active review in progress.",
            logText: longActiveLog
        )
        let recentChat = makeReviewChatFixtureForTesting(
            id: "chat-recent-scroll",
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "Recent review completed.",
            logText: longRecentLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            fixtures: [activeChat, recentChat]
        )
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: activeChat.chatID)
        _ = try await awaitChatRenderForTesting(
            activeChat,
            in: transport,
            allowIncrementalUpdate: false
        )

        transport.scrollLogToOffsetForTesting(120)
        let activeOffset = transport.logVerticalScrollOffsetForTesting
        #expect(activeOffset > 0)
        #expect(transport.isLogPinnedToBottomForTesting == false)
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: recentChat.chatID)
        _ = try await awaitChatRenderForTesting(
            recentChat,
            in: transport,
            allowIncrementalUpdate: false
        )

        #expect(transport.isLogPinnedToBottomForTesting)
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: activeChat.chatID)
        _ = try await awaitChatRenderForTesting(
            activeChat,
            in: transport,
            allowIncrementalUpdate: false
        )

        #expect(transport.logVerticalScrollOffsetForTesting == activeOffset)
        #expect(transport.isLogPinnedToBottomForTesting == false)
    }

    @Test func switchingSelectedReviewChatRestoresPinnedBottomPosition() async throws {
        let longActiveLog = (0..<400).map { "active line \($0)" }.joined(separator: "\n")
        let longRecentLog = (0..<400).map { "recent line \($0)" }.joined(separator: "\n")
        let activeChat = makeReviewChatFixtureForTesting(
            id: "chat-active-bottom",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Active review in progress.",
            logText: longActiveLog
        )
        let recentChat = makeReviewChatFixtureForTesting(
            id: "chat-recent-bottom",
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "Recent review completed.",
            logText: longRecentLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            fixtures: [activeChat, recentChat]
        )
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: activeChat.chatID)
        _ = try await awaitChatRenderForTesting(
            activeChat,
            in: transport,
            allowIncrementalUpdate: false
        )

        transport.scrollLogToBottomForTesting()
        #expect(transport.isLogPinnedToBottomForTesting)
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: recentChat.chatID)
        _ = try await awaitChatRenderForTesting(
            recentChat,
            in: transport,
            allowIncrementalUpdate: false
        )

        #expect(transport.isLogPinnedToBottomForTesting)

        appendChatLogEntryForTesting(
            .init(kind: .progress, text: "Newest active line"),
            to: activeChat.chatID,
            turnID: activeChat.turnID
        )
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: activeChat.chatID)
        let snapshot = try await awaitChatRenderForTesting(
            activeChat,
            in: transport,
            allowIncrementalUpdate: false
        )

        #expect(snapshot.log.contains("Newest active line"))
        #expect(transport.isLogPinnedToBottomForTesting)
    }

    @Test func rehydratingSameSelectedReviewChatPreservesLogScrollPosition() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-rehydrated",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        transport.scrollLogToOffsetForTesting(120)
        let preservedOffset = transport.logVerticalScrollOffsetForTesting
        #expect(preservedOffset > 0)

        let replacement = makeReviewChatFixtureForTesting(
            id: "chat-rehydrated",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        store.loadForTesting(serverState: .running, fixtures: [replacement])

        #expect(transport.displayedLogForTesting == reviewChatLogText(for: replacement))
        #expect(transport.logVerticalScrollOffsetForTesting == preservedOffset)
    }

    @Test func switchingReviewChatWithIdenticalLogTextStartsUnvisitedReviewChatAtBottom() async throws {
        let sharedLog = (0..<400).map { "shared line \($0)" }.joined(separator: "\n")
        let firstChat = makeReviewChatFixtureForTesting(
            id: "chat-identical-1",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: sharedLog
        )
        let secondChat = makeReviewChatFixtureForTesting(
            id: "chat-identical-2",
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "Review completed.",
            logText: sharedLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [firstChat, secondChat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: firstChat.chatID)
        _ = try await awaitChatRenderForTesting(
            firstChat,
            in: transport,
            allowIncrementalUpdate: false
        )

        transport.scrollLogToOffsetForTesting(120)
        #expect(transport.logVerticalScrollOffsetForTesting > 0)
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: secondChat.chatID)
        _ = try await awaitChatRenderForTesting(
            secondChat,
            in: transport,
            allowIncrementalUpdate: false
        )

        try await waitForLogPinnedToBottom(in: transport)
    }

    @Test func switchingFromShortToLongChatMaterializesVisibleTextKit2Fragments() async throws {
        let shortLog = (0..<3).map { "short visible line \($0)" }.joined(separator: "\n")
        let longLog = (0..<700)
            .map { "long visible fragment line \($0) with enough text to exercise viewport surface reuse" }
            .joined(separator: "\n")
        let shortChat = makeReviewChatFixtureForTesting(
            id: "chat-fragment-short",
            status: .running,
            targetSummary: "Short log",
            summary: "Short preview.",
            logText: shortLog
        )
        let longChat = makeReviewChatFixtureForTesting(
            id: "chat-fragment-long",
            status: .succeeded,
            targetSummary: "Long log",
            summary: "Long review completed.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [shortChat, longChat])
        let harness = makeWindowHarness(store: store, contentSize: NSSize(width: 900, height: 600))
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: shortChat.chatID)
        _ = try await awaitChatRenderForTesting(
            shortChat,
            in: transport,
            allowIncrementalUpdate: false
        )

        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: longChat.chatID)
        let longSnapshot = try await awaitChatRenderForTesting(
            longChat,
            in: transport,
            allowIncrementalUpdate: false
        )

        #expect(longSnapshot.log == reviewChatLogText(for: longChat))
        #expect(transport.isLogPinnedToBottomForTesting)
        expectLogVisibleFragmentsWithoutForcingLayout(transport)
    }

    @Test func shortLogSelectionAutoFollowsAfterLaterGrowth() async throws {
        let shortLog = (0..<3).map { "short line \($0)" }.joined(separator: "\n")
        let longLog = (0..<400).map { "long line \($0)" }.joined(separator: "\n")
        let shortChat = makeReviewChatFixtureForTesting(
            id: "chat-short-cache",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Short preview.",
            logText: shortLog
        )
        let recentChat = makeReviewChatFixtureForTesting(
            id: "chat-short-cache-recent",
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "Recent review completed.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [shortChat, recentChat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: shortChat.chatID)
        _ = try await awaitChatRenderForTesting(
            shortChat,
            in: transport,
            allowIncrementalUpdate: false
        )
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: recentChat.chatID)
        _ = try await awaitChatRenderForTesting(
            recentChat,
            in: transport,
            allowIncrementalUpdate: false
        )
        expectLogVisibleFragmentsWithoutForcingLayout(transport)

        replaceChatLogTextForTesting(
            longLog,
            for: shortChat.chatID,
            fixtureID: shortChat.id,
            turnID: shortChat.turnID
        )
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: shortChat.chatID)
        _ = try await awaitChatRenderForTesting(
            shortChat,
            in: transport,
            allowIncrementalUpdate: false
        )

        #expect(transport.isLogPinnedToBottomForTesting)
        expectLogVisibleFragmentsWithoutForcingLayout(transport)
    }

    @Test func previouslySelectedReviewChatUpdatesDoNotRepaintCurrentDetailPane() async throws {
        let activeChat = makeReviewChatFixtureForTesting(
            id: "chat-old-selection",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Active review.",
            logText: "Active log\n"
        )
        let recentChat = makeReviewChatFixtureForTesting(
            id: "chat-current-selection",
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "Recent review.",
            logText: "Recent log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [activeChat, recentChat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: activeChat.chatID)
        _ = try await awaitChatRenderForTesting(
            activeChat,
            in: transport,
            allowIncrementalUpdate: false
        )
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: recentChat.chatID)
        _ = try await awaitChatRenderForTesting(
            recentChat,
            in: transport,
            allowIncrementalUpdate: false
        )
        appendChatLogEntryForTesting(
            .init(kind: .progress, text: "stale update"),
            to: activeChat.chatID,
            turnID: activeChat.turnID
        )
        appendChatLogEntryForTesting(
            .init(kind: .progress, text: "fresh update"),
            to: recentChat.chatID,
            turnID: recentChat.turnID
        )

        let updatedSnapshot = try await awaitChatRenderForTesting(recentChat, in: transport) { snapshot in
            snapshot.log.contains("fresh update")
        }
        #expect(updatedSnapshot.log.contains("stale update") == false)
        #expect(transport.displayedLogForTesting.contains("stale update") == false)
    }

    @Test func clickingSidebarBlankAreaKeepsSelectionAndDetailPane() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-selected",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Review is still running.",
            logText: "Selected log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            fixtures: [chat]
        )
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)

        let selectedSnapshot = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        viewController.sidebarViewControllerForTesting.clickBlankAreaForTesting()

        #expect(viewController.sidebarViewControllerForTesting.selectedReviewChatIDForTesting == chat.chatID)
        #expect(transport.renderSnapshotForTesting == selectedSnapshot)
    }

    @Test func clickingWorkspaceHeaderSelectsWorkspacePlaceholder() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-selected",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Review is still running.",
            logText: "Selected log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            fixtures: [chat]
        )
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)

        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        let expectedWorkspaceGroupID = try #require(
            viewController.sidebarViewControllerForTesting.workspaceGroupIDForTesting(cwd: chat.cwd)
        )
        viewController.sidebarViewControllerForTesting.clickWorkspaceHeaderForTesting(cwd: chat.cwd)

        _ = try await awaitTransportRender(transport)
        #expect(
            viewController.sidebarViewControllerForTesting.selectedWorkspaceGroupIDForTesting
                == expectedWorkspaceGroupID)
        #expect(viewController.sidebarViewControllerForTesting.selectedReviewChatIDForTesting == nil)
        #expect(transport.isShowingNoFindingsStateForTesting)
    }

    @Test func newChatsArrivingWhileUnselectedDoNotAutoSelect() {
        let activeChat = makeReviewChatFixtureForTesting(status: .running, targetSummary: "Uncommitted changes")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running)
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarViewControllerForTesting.selectedReviewChatIDForTesting == nil)
        #expect(viewController.contentPaneViewControllerForTesting.isShowingEmptyStateForTesting)

        store.loadForTesting(
            serverState: .running,
            fixtures: [activeChat]
        )

        #expect(viewController.sidebarViewControllerForTesting.selectedReviewChatIDForTesting == nil)
        #expect(viewController.contentPaneViewControllerForTesting.isShowingEmptyStateForTesting)
        #expect(viewController.contentPaneViewControllerForTesting.displayedTitleForTesting == nil)
    }

    @Test func removingSelectedReviewChatClearsSelectionWithoutAutoSelectingReplacement() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let activeThreadID = CodexThreadID(rawValue: "thread-active")
        let recentThreadID = CodexThreadID(rawValue: "thread-recent")

        try await runtime.transport.enqueueThreadList(
            .init(threads: [
                .init(
                    id: activeThreadID,
                    workspace: repo,
                    name: "Uncommitted changes",
                    updatedAt: Date(timeIntervalSince1970: 5_000)
                ),
                .init(
                    id: recentThreadID,
                    workspace: repo,
                    name: "Commit: abc123",
                    updatedAt: Date(timeIntervalSince1970: 4_000)
                ),
            ]))

        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running)
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store,
            uiState: ReviewMonitorUIState(auth: store.auth),
            modelContext: context
        )
        viewController.loadViewIfNeeded()
        let contentPane = viewController.contentPaneViewControllerForTesting
        let sidebar = viewController.sidebarViewControllerForTesting

        try await waitForCondition {
            sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(activeThreadID)) == "Uncommitted changes"
                && sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(recentThreadID)) == "Commit: abc123"
        }
        sidebar.selectCodexSidebarRowForTesting(rowID: .chat(activeThreadID))
        try await waitForCondition {
            sidebar.selectedReviewChatIDForTesting == activeThreadID
        }

        let activeChat = context.model(for: activeThreadID)
        try await runtime.transport.enqueueEmpty(for: "thread/delete")
        try await activeChat.delete()

        try await waitForCondition {
            sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(activeThreadID)) == nil
                && sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(recentThreadID)) == "Commit: abc123"
                && sidebar.selectedReviewChatIDForTesting == nil
        }

        let emptySnapshot = try await awaitContentPaneRender(contentPane) { snapshot in
            snapshot.isShowingEmptyState
        }
        #expect(sidebar.selectedReviewChatIDForTesting == nil)
        #expect(emptySnapshot.isShowingEmptyState)
        #expect(emptySnapshot.title == nil)
        #expect(emptySnapshot.summary == nil)
    }

    @Test func clearingSelectionShowsEmptyStateAndClearsDetailPane() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-1",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: "Initial log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            fixtures: [chat]
        )
        let backend = makeWindowHarness(store: store)
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let contentPane = viewController.contentPaneViewControllerForTesting
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)

        let selectedSnapshot = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(selectedSnapshot.title == nil)
        #expect(window.title == chat.chat.title)
        #expect(window.subtitle == chat.cwd)
        viewController.sidebarViewControllerForTesting.clearSelectionForTesting()

        let emptySnapshot = try await awaitContentPaneRender(contentPane)
        #expect(emptySnapshot.isShowingEmptyState)
        #expect(emptySnapshot.title == nil)
        #expect(emptySnapshot.summary == nil)
        #expect(emptySnapshot.log.isEmpty)
        #expect(window.title == "")
        #expect(window.subtitle == "")
        replaceChatLogTextForTesting(
            "Deselected log",
            for: chat.chatID,
            fixtureID: chat.id,
            turnID: chat.turnID
        )

        #expect(contentPane.selectedChatLogTaskForTesting == nil)
        #expect(contentPane.renderSnapshotForTesting == emptySnapshot)
    }

    @Test func inPlaceReviewChatUpdateKeepsSelectionAndRefreshesDetailPane() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-1",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: "Initial log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            fixtures: [chat]
        )
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)

        let selectedSnapshot = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(selectedSnapshot.title == nil)
        #expect(selectedSnapshot.summary == nil)
        replaceChatLogTextForTesting(
            "Updated log",
            for: chat.chatID,
            fixtureID: chat.id,
            turnID: chat.turnID
        )

        let updatedSnapshot = try await awaitChatRenderForTesting(chat, in: transport)
        #expect(viewController.sidebarViewControllerForTesting.selectedReviewChatIDForTesting == chat.chatID)
        #expect(updatedSnapshot.summary == nil)
        #expect(reviewChatRenderedLogMatches(updatedSnapshot.log, reviewChatLogText(for: chat)))
    }

    @Test func selectedReviewChatLogAppendUsesAppendPath() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-append",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            chatEntries: [
                .init(kind: .agentMessage, groupID: "msg_1", text: "Initial")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let previewRuntime = try #require(previewRuntimeForTesting(on: store))
        previewRuntime.start()
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store,
            uiState: ReviewMonitorUIState(auth: store.auth),
            codexModelSource: previewRuntime.modelSource
        )
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 360))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        let chatID = chat.chatID
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatID)
        _ = try await awaitTransportRender(transport) { $0.log == "Initial" }
        transport.setLogReduceMotionForTesting(false)
        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        previewRuntime.appendPreviewText(
            " log",
            to: chatID,
            itemID: "msg_1",
            kind: .agentMessage,
            content: .message(.init(id: "msg_1", role: .assistant, text: ""))
        )

        let snapshot = try await awaitTransportRender(transport) { $0.log == "Initial log" }
        #expect(snapshot.log == "Initial log")
        #expect(transport.logAppendCountForTesting == appendCount + 1)
        #expect(transport.logReloadCountForTesting == reloadCount)
        #expect(transport.logWordGlowCountForTesting == 0)
    }

    @Test func separatorPrefixedProgressAppendDoesNotUseGenericWordGlow() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-progress-separator-append",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            chatEntries: [
                .init(kind: .agentMessage, groupID: "msg_1", text: "Initial")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let previewRuntime = try #require(previewRuntimeForTesting(on: store))
        previewRuntime.start()
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store,
            uiState: ReviewMonitorUIState(auth: store.auth),
            codexModelSource: previewRuntime.modelSource
        )
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 360))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        let chatID = chat.chatID
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatID)
        _ = try await awaitTransportRender(transport) { $0.log == "Initial" }
        let wordGlowCount = transport.logWordGlowCountForTesting
        previewRuntime.upsertPreviewItem(
            id: "progress_1",
            kind: CodexThreadItem.Kind(rawValue: "progress"),
            content: .diagnostic("stream.tick 001"),
            to: chatID
        )

        let snapshot = try await awaitTransportRender(transport) { $0.log.hasSuffix("stream.tick 001") }
        #expect(snapshot.log.hasSuffix("stream.tick 001"))
        #expect(transport.logWordGlowCountForTesting == wordGlowCount)
    }

    @Test func logCanonicalEquivalentPrefixReloadsWhenUTF16LengthChanges() async throws {
        let decomposedPrefix = "Caf\u{0065}\u{0301}"
        let precomposedUpdate = "Caf\u{00E9} appended"
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-canonical-append",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            chatEntries: [
                .init(kind: .agentMessage, groupID: "msg_1", text: decomposedPrefix)
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        #expect(transport.renderLogForTesting(text: precomposedUpdate, allowIncrementalUpdate: true))

        #expect(transport.displayedLogForTesting.hasSuffix(" appended"))
        #expect(transport.logAppendCountForTesting == appendCount)
        #expect(transport.logReloadCountForTesting == reloadCount + 1)
    }

    @Test func coalescedLogTextUpdateDisplaysCombinedSuffix() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-coalesced",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            chatEntries: [
                .init(kind: .agentMessage, groupID: "msg_1", text: "Initial")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        appendChatLogEntryForTesting(
            .init(kind: .agentMessage, groupID: "msg_1", text: " one"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        appendChatLogEntryForTesting(
            .init(kind: .agentMessage, groupID: "msg_1", text: " two"),
            to: chat.chatID,
            turnID: chat.turnID
        )

        let snapshot = try await awaitChatRenderForTesting(chat, in: transport)
        #expect(snapshot.log == "Initial one two")
    }

    @Test func coalescedProgressSuffixDisplaysLatestProgress() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-coalesced-progress",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            chatEntries: [
                .init(kind: .agentMessage, groupID: "msg_1", text: "Initial")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        appendChatLogEntryForTesting(
            .init(kind: .progress, groupID: "progress_1", text: "stream.tick 001"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        appendChatLogEntryForTesting(
            .init(kind: .progress, groupID: "progress_2", text: "stream.tick 002"),
            to: chat.chatID,
            turnID: chat.turnID
        )

        let snapshot = try await awaitChatRenderForTesting(chat, in: transport)
        #expect(snapshot.log.hasSuffix("stream.tick 002"))
    }

    @Test func coalescedMixedReasoningAndProgressSuffixAnimatesOnlyReasoningRange() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-coalesced-mixed-reasoning-progress",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            chatEntries: [
                .init(kind: .rawReasoning, groupID: "reasoning_1", text: "Thinking")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        transport.setLogReduceMotionForTesting(false)
        let wordGlowCount = transport.logWordGlowCountForTesting
        appendChatLogEntryForTesting(
            .init(kind: .rawReasoning, groupID: "reasoning_1", text: " ok"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        appendChatLogEntryForTesting(
            .init(
                kind: .progress,
                groupID: "progress_1",
                text: String(repeating: "progress ", count: 20)
            ),
            to: chat.chatID,
            turnID: chat.turnID
        )

        let snapshot = try await awaitChatRenderForTesting(chat, in: transport)
        #expect(snapshot.log.contains("progress progress"))
        #expect(transport.logAppendCountForTesting > 0)
        #expect(transport.logWordGlowCountForTesting == wordGlowCount + 1)
    }

    @Test func shortLogAppendDoesNotGrowDocumentFrameBeforeContentIsScrollable() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-short-append-frame-stability",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: "review.start\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let harness = makeWindowHarness(store: store, contentSize: NSSize(width: 900, height: 600))
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        transport.view.layoutSubtreeIfNeeded()

        let initialDocumentFrame = transport.logDocumentViewFrameForTesting
        #expect(transport.isLogPinnedToBottomForTesting)
        #expect(
            abs(transport.logMaximumVerticalScrollOffsetForTesting - transport.logMinimumVerticalScrollOffsetForTesting)
                < 0.5)
        appendChatLogEntryForTesting(
            .init(
                kind: .progress,
                text:
                    "stream.tick 001 delta/layout +2 -0 while the short log remains below the scrollable viewport height"
            ),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)
        transport.view.layoutSubtreeIfNeeded()

        let appendedDocumentFrame = transport.logDocumentViewFrameForTesting
        #expect(abs(appendedDocumentFrame.height - initialDocumentFrame.height) < 0.5)
        #expect(
            abs(transport.logMaximumVerticalScrollOffsetForTesting - transport.logMinimumVerticalScrollOffsetForTesting)
                < 0.5)
    }

    @Test func selectedReviewChatGroupedReplacementUsesReplacementPath() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-reload",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            chatEntries: [
                .init(kind: .plan, groupID: "plan_1", text: "- original")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        let appendCount = transport.logAppendCountForTesting
        let replaceCount = transport.logReplaceCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        appendChatLogEntryForTesting(
            .init(kind: .plan, groupID: "plan_1", replacesGroup: true, text: "- updated"),
            to: chat.chatID,
            turnID: chat.turnID
        )

        let snapshot = try await awaitChatRenderForTesting(chat, in: transport)
        #expect(snapshot.log == "- updated")
        #expect(transport.logAppendCountForTesting == appendCount)
        #expect(transport.logReplaceCountForTesting == replaceCount + 1)
        #expect(transport.logReloadCountForTesting == reloadCount)
    }

    @Test func coalescedCommandAppendAfterReasoningKeepsReasoningAndDoesNotReload() async throws {
        let startedAt = Date(timeIntervalSince1970: 200)
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-reasoning-command-append",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            status: .running,
            startedAt: startedAt,
            chatEntries: [
                .init(
                    kind: .rawReasoning,
                    groupID: "reasoning_1",
                    text: "Need to inspect files."
                )
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let harness = makeWindowHarness(store: store, contentSize: NSSize(width: 860, height: 520))
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting

        appendChatLogEntryForTesting(
            .init(
                kind: .command,
                groupID: "cmd_1",
                text: "$ git diff",
                metadata: .init(
                    sourceType: "commandExecution",
                    status: "inProgress",
                    itemID: "cmd_1",
                    command: "git diff",
                    startedAt: startedAt,
                    commandStatus: "inProgress"
                )
            ),
            to: chat.chatID,
            turnID: chat.turnID
        )
        appendChatLogEntryForTesting(
            .init(
                kind: .rawReasoning,
                groupID: "reasoning_2",
                text: "Inspecting details after the command starts."
            ),
            to: chat.chatID,
            turnID: chat.turnID
        )

        let snapshot = try await awaitChatRenderForTesting(chat, in: transport)
        #expect(snapshot.log.contains("Need to inspect files."))
        #expect(snapshot.log.contains("Running git diff"))
        #expect(snapshot.log.contains("Inspecting details after the command starts."))
        #expect(transport.logAppendCountForTesting == appendCount + 1)
        #expect(transport.logReloadCountForTesting == reloadCount)
    }

    @Test func selectedReviewChatMarkdownAppendReplacesTailBlockWithoutReload() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-markdown-append-fallback",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            chatEntries: [
                .init(kind: .agentMessage, groupID: "msg_1", text: "**bo")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        let appendCount = transport.logAppendCountForTesting
        let replaceCount = transport.logReplaceCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        appendChatLogEntryForTesting(
            .init(kind: .agentMessage, groupID: "msg_1", text: "ld**"),
            to: chat.chatID,
            turnID: chat.turnID
        )

        let snapshot = try await awaitChatRenderForTesting(chat, in: transport)
        #expect(snapshot.log == "bold")
        #expect(transport.logAppendCountForTesting == appendCount)
        #expect(transport.logReplaceCountForTesting == replaceCount + 1)
        #expect(transport.logReloadCountForTesting == reloadCount)
    }

    @Test func staleGroupedReplacementIsNotReplayedAfterHiddenCommandOutput() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-stale-replacement",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            chatEntries: [
                .init(kind: .plan, groupID: "plan_1", text: "- original")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        appendChatLogEntryForTesting(
            .init(
                kind: .plan,
                groupID: "plan_1",
                replacesGroup: true,
                text: "- updated with longer replacement text"
            ),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)
        let replaceCount = transport.logReplaceCountForTesting
        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        appendChatLogEntryForTesting(
            .init(kind: .commandOutput, groupID: "cmd_1", text: "hidden output"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport) { snapshot in
            snapshot.log.contains("Running Command")
        }

        #expect(transport.displayedLogForTesting.contains("- updated with longer replacement text"))
        #expect(transport.displayedLogForTesting.contains("Running Command"))
        #expect(transport.displayedLogForTesting.contains("Command output - 1 line") == false)
        #expect(transport.displayedLogForTesting.contains("hidden output") == false)
        #expect(transport.logAppendCountForTesting == appendCount + 1)
        #expect(transport.logReplaceCountForTesting == replaceCount)
        #expect(transport.logReloadCountForTesting == reloadCount)
    }

    @Test func metadataOnlyUpdatesDoNotTouchLogView() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-metadata",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: "Initial log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let previewRuntime = try #require(previewRuntimeForTesting(on: store))
        previewRuntime.start()
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store,
            uiState: ReviewMonitorUIState(auth: store.auth),
            codexModelSource: previewRuntime.modelSource
        )
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        previewRuntime.upsertPreviewItem(
            id: "fixture-log-\(chat.id)",
            kind: .agentMessage,
            content: .message(.init(id: "fixture-log-\(chat.id)", role: .assistant, text: "Initial log")),
            to: chat.chatID
        )

        #expect(transport.displayedLogForTesting == reviewChatLogText(for: chat))
        #expect(transport.logAppendCountForTesting == appendCount)
        #expect(transport.logReloadCountForTesting == reloadCount)
    }

    @Test func reasoningAppendUsesWordGlowAndReduceMotionDisablesGlow() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-reasoning-glow",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            chatEntries: [
                .init(kind: .rawReasoning, groupID: "reasoning_1", text: "Thinking")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        transport.setLogReduceMotionForTesting(false)
        appendChatLogEntryForTesting(
            .init(kind: .rawReasoning, groupID: "reasoning_1", text: " through options"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)

        #expect(transport.logWordGlowCountForTesting == 2)

        transport.completeLogWordGlowAnimationsForTesting()
        #expect(transport.logWordGlowCountForTesting == 0)

        appendChatLogEntryForTesting(
            .init(kind: .rawReasoning, groupID: "reasoning_1", text: " again"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)

        #expect(transport.logWordGlowCountForTesting == 1)

        transport.setLogReduceMotionForTesting(true)
        appendChatLogEntryForTesting(
            .init(kind: .rawReasoning, groupID: "reasoning_1", text: " without animation"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)

        #expect(transport.logWordGlowCountForTesting == 0)
    }

    @Test func screenSwitchBacklogDoesNotAnimateButNextVisibleReasoningAppendDoes() async throws {
        let firstChat = makeReviewChatFixtureForTesting(
            id: "chat-reasoning-switch-backlog",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            chatEntries: [
                .init(kind: .rawReasoning, groupID: "reasoning_1", text: "Thinking")
            ]
        )
        let secondChat = makeReviewChatFixtureForTesting(
            id: "chat-other-selected",
            cwd: "/tmp/workspace-beta",
            title: "Uncommitted changes",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 201),
            chatEntries: [
                .init(kind: .agentMessage, groupID: "msg_1", text: "Other chat")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [firstChat, secondChat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        transport.setLogReduceMotionForTesting(false)

        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: firstChat.chatID)
        _ = try await awaitChatRenderForTesting(
            firstChat,
            in: transport,
            allowIncrementalUpdate: false
        )
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: secondChat.chatID)
        _ = try await awaitChatRenderForTesting(
            secondChat,
            in: transport,
            allowIncrementalUpdate: false
        )
        appendChatLogEntryForTesting(
            .init(kind: .rawReasoning, groupID: "reasoning_1", text: " hidden backlog"),
            to: firstChat.chatID,
            turnID: firstChat.turnID
        )

        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: firstChat.chatID)
        _ = try await awaitChatRenderForTesting(
            firstChat,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(transport.logWordGlowCountForTesting == 0)

        appendChatLogEntryForTesting(
            .init(kind: .rawReasoning, groupID: "reasoning_1", text: " live"),
            to: firstChat.chatID,
            turnID: firstChat.turnID
        )
        _ = try await awaitChatRenderForTesting(firstChat, in: transport)
        #expect(transport.logWordGlowCountForTesting > 0)
    }

    @Test func reasoningWordGlowCompletesAndClearsRenderingAttributes() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-reasoning-glow-completion",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            chatEntries: [
                .init(kind: .rawReasoning, groupID: "reasoning_1", text: "Thinking")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let harness = makeWindowHarness(store: store, contentSize: NSSize(width: 900, height: 360))
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        transport.setLogReduceMotionForTesting(false)

        let invalidationCount = transport.logWordFadeDisplayInvalidationCountForTesting
        appendChatLogEntryForTesting(
            .init(kind: .rawReasoning, groupID: "reasoning_1", text: " through options"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)

        #expect(transport.logWordGlowCountForTesting > 0)
        #expect(transport.logWordFadeRenderingAttributeRangeCountForTesting > 0)
        #expect(transport.logWordFadeStorageUsesOpaqueTextColorForTesting)

        transport.completeLogWordGlowAnimationsForTesting()

        #expect(transport.logWordGlowCountForTesting == 0)
        #expect(transport.logWordFadeRenderingAttributeRangeCountForTesting == 0)
        #expect(transport.logWordFadeStorageUsesOpaqueTextColorForTesting)
        #expect(transport.logWordFadeDisplayInvalidationCountForTesting > invalidationCount)
    }

    @Test func delayedFirstWordGlowTickDoesNotImmediatelyClearAnimation() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-reasoning-glow-delayed-first-tick",
            cwd: "/tmp/workspace-alpha",
            title: "Uncommitted changes",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            chatEntries: [
                .init(kind: .rawReasoning, groupID: "reasoning_1", text: "Thinking")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let harness = makeWindowHarness(store: store, contentSize: NSSize(width: 900, height: 360))
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        transport.setLogReduceMotionForTesting(false)

        appendChatLogEntryForTesting(
            .init(kind: .rawReasoning, groupID: "reasoning_1", text: " ok"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)
        #expect(transport.logWordGlowCountForTesting > 0)

        transport.advanceLogWordGlowAnimationsAfterInitialDelayForTesting(5)
        #expect(transport.logWordGlowCountForTesting > 0)
    }

    @Test func logAutoFollowRunsOnlyWhenPinnedToBottom() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-autofollow",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(transport.isLogPinnedToBottomForTesting)

        transport.scrollLogToBottomForTesting()
        #expect(transport.isLogPinnedToBottomForTesting)

        transport.scrollLogToTopForTesting()
        #expect(transport.isLogPinnedToBottomForTesting == false)
        let unpinnedAutoFollow = transport.logAutoFollowCountForTesting
        appendChatLogEntryForTesting(
            .init(kind: .progress, text: "Unpinned update"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)
        #expect(transport.logAutoFollowCountForTesting == unpinnedAutoFollow)
        #expect(transport.isLogPinnedToBottomForTesting == false)

        transport.scrollLogToBottomForTesting()
        #expect(transport.isLogPinnedToBottomForTesting)
        let pinnedAutoFollow = transport.logAutoFollowCountForTesting
        appendChatLogEntryForTesting(
            .init(kind: .progress, text: "Pinned update"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)
        #expect(transport.logAutoFollowCountForTesting == pinnedAutoFollow + 1)
        #expect(transport.isLogPinnedToBottomForTesting)
    }

    @Test func logAutoFollowKeepsBottomAfterWrappedSingleLineAppend() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-autofollow-wrapped-append",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let harness = makeWindowHarness(store: store, contentSize: NSSize(width: 560, height: 360))
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        transport.scrollLogToBottomForTesting()
        #expect(transport.isLogPinnedToBottomForTesting)
        let pinnedAutoFollow = transport.logAutoFollowCountForTesting
        let wrappedLine = (0..<140)
            .map { "wrapped-append-segment-\($0)" }
            .joined(separator: " ")
        appendChatLogEntryForTesting(
            .init(kind: .progress, text: wrappedLine),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)

        #expect(transport.logAutoFollowCountForTesting == pinnedAutoFollow + 1)
        #expect(transport.isLogPinnedToBottomForTesting)
        #expect(transport.logVisibleFragmentViewCountForTesting > 0)
        #expect(transport.isLogPinnedToBottomForTesting)
    }

    @Test func logAppendDoesNotScrollWhenNearBottomButUnpinned() async throws {
        let longLog = (0..<500)
            .map { "scroll stability line \($0) with enough text to keep TextKit 2 viewport layout active" }
            .joined(separator: "\n")
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-append-near-bottom-scroll-stability",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        let nearBottomOffset = transport.logMaximumVerticalScrollOffsetForTesting - 12
        transport.scrollLogToOffsetForTesting(nearBottomOffset)
        #expect(transport.isLogPinnedToBottomForTesting == false)
        let offsetBeforeAppend = transport.logVerticalScrollOffsetForTesting
        let autoFollowBeforeAppend = transport.logAutoFollowCountForTesting
        let programmaticScrollsBeforeAppend = transport.logProgrammaticScrollCountForTesting
        appendChatLogEntryForTesting(
            .init(
                kind: .progress,
                text: "Near-bottom append should not snap inertial or manual scrolling to the document end"
            ),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)

        #expect(transport.logAutoFollowCountForTesting == autoFollowBeforeAppend)
        #expect(transport.logProgrammaticScrollCountForTesting == programmaticScrollsBeforeAppend)
        #expect(abs(transport.logVerticalScrollOffsetForTesting - offsetBeforeAppend) < 0.5)
        #expect(transport.isLogPinnedToBottomForTesting == false)
    }

    @Test func programmaticLogAutoFollowRequestsOverlayScrollerHideWhenShown() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-overlay-hide",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.scrollLogToBottomForTesting()
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting
        appendChatLogEntryForTesting(
            .init(kind: .progress, text: "Newest line"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)

        #expect(transport.isLogPinnedToBottomForTesting)
        #expect(transport.logOverlayScrollerHideRequestCountForTesting == hideCountBeforeAppend + 1)
    }

    @Test func legacyScrollerStyleDoesNotRequestOverlayScrollerHide() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-legacy-hide",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        transport.setLogScrollerStyleForTesting(.legacy)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.scrollLogToBottomForTesting()
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting
        appendChatLogEntryForTesting(
            .init(kind: .progress, text: "Newest line"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)

        #expect(transport.logOverlayScrollerHideRequestCountForTesting == hideCountBeforeAppend)
    }

    @Test func shortLogDoesNotRequestOverlayScrollerHideWhenNoScrollRange() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-overlay-short",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: "short log"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting
        appendChatLogEntryForTesting(
            .init(kind: .progress, text: "short update"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)

        #expect(transport.logOverlayScrollerHideRequestCountForTesting == hideCountBeforeAppend)
    }

    @Test func selectingReviewChatRequestsOverlayScrollerHideWhenRestoringScrollPosition() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let firstChat = makeReviewChatFixtureForTesting(
            id: "chat-restore-1",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let secondChat = makeReviewChatFixtureForTesting(
            id: "chat-restore-2",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog + "\nsecond chat"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [firstChat, secondChat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: firstChat.chatID)
        _ = try await awaitChatRenderForTesting(
            firstChat,
            in: transport,
            allowIncrementalUpdate: false
        )

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.scrollLogToOffsetForTesting(120)
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: secondChat.chatID)
        _ = try await awaitChatRenderForTesting(
            secondChat,
            in: transport,
            allowIncrementalUpdate: false
        )

        let hideCountBeforeRestore = transport.logOverlayScrollerHideRequestCountForTesting
        transport.setLogOverlayScrollersShownForTesting(true)
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: firstChat.chatID)
        _ = try await awaitChatRenderForTesting(
            firstChat,
            in: transport,
            allowIncrementalUpdate: false
        )

        try await waitForOverlayScrollerHideRequest(
            in: transport,
            exceeding: hideCountBeforeRestore
        )
    }

    @Test func privateOverlayBridgeNoOpsWhenScrollerImpPairIsUnavailable() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-missing-pair",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.setLogOverlayScrollerBridgeModeForTesting(.missingScrollerImpPair)
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting
        appendChatLogEntryForTesting(
            .init(kind: .progress, text: "Newest line"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)

        #expect(transport.logOverlayScrollerHideRequestCountForTesting == hideCountBeforeAppend)
    }

    @Test func privateOverlayBridgeNoOpsWhenHideSelectorsAreUnavailable() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-missing-hide",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.setLogOverlayScrollerBridgeModeForTesting(.missingHideMethods)
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting
        appendChatLogEntryForTesting(
            .init(kind: .progress, text: "Newest line"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)

        #expect(transport.logOverlayScrollerHideRequestCountForTesting == hideCountBeforeAppend)
    }

    @Test func logViewUsesCustomTextKit2SurfaceAndDisablesEditingFeatures() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-log-config",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: "Initial log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        #expect(transport.logUsesCustomTextKit2SurfaceForTesting)
        #expect(transport.logUsesTextViewForTesting == false)
        #expect(transport.logUsesLogLayoutManagerForTesting == false)
        #expect(transport.logIsEditableForTesting == false)
        #expect(transport.logIsSelectableForTesting)
        #expect(transport.logHitTestTargetsDocumentViewForTesting)
        #expect(transport.logWritingToolsDisabledForTesting)
    }

    @Test func logViewMaintainsVisibleTextKit2FragmentCoverageWhenScrolled() async throws {
        let longLog = (0..<1_000).map { "fragment coverage line \($0)" }.joined(separator: "\n")
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-log-fragments",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let harness = makeWindowHarness(store: store, contentSize: NSSize(width: 900, height: 520))
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        transport.view.layoutSubtreeIfNeeded()

        let bottomFragmentCount = transport.logVisibleFragmentViewCountForTesting
        #expect(bottomFragmentCount > 0)
        #expect(bottomFragmentCount < 1_000)
        #expect(transport.logStaleFragmentViewCountForTesting == 0)

        transport.scrollLogToTopForTesting()
        #expect(transport.logVisibleFragmentViewCountForTesting > 0)
        #expect(transport.logStaleFragmentViewCountForTesting == 0)

        let middleOffset = transport.logMaximumVerticalScrollOffsetForTesting / 2
        transport.scrollLogToOffsetForTesting(middleOffset)
        #expect(transport.logVisibleFragmentViewCountForTesting > 0)
        #expect(transport.logStaleFragmentViewCountForTesting == 0)

        transport.scrollLogToBottomForTesting()
        #expect(transport.logVisibleFragmentViewCountForTesting > 0)
        #expect(transport.logStaleFragmentViewCountForTesting == 0)
    }

    @Test func logAppendDoesNotLeaveStaleTextKit2FragmentViews() async throws {
        let longLog = (0..<400).map { "append fragment line \($0)" }.joined(separator: "\n")
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-log-fragment-append",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let harness = makeWindowHarness(store: store, contentSize: NSSize(width: 900, height: 520))
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        let appendCount = transport.logAppendCountForTesting
        appendChatLogEntryForTesting(
            .init(kind: .progress, text: "Newest fragment line"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)

        #expect(transport.logAppendCountForTesting == appendCount + 1)
        #expect(transport.logVisibleFragmentViewCountForTesting > 0)
        #expect(transport.logStaleFragmentViewCountForTesting == 0)
    }

    @Test func logViewSupportsReadOnlySelectAllCopyFindValidationAndAccessibility() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-log-readonly",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: "First readonly line\nSecond readonly line\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        #expect(viewController.validateUserInterfaceItem(textFinderMenuItemForTesting(.showFindInterface)))
        #expect(viewController.validateUserInterfaceItem(textFinderMenuItemForTesting(.nextMatch)))
        #expect(viewController.validateUserInterfaceItem(textFinderMenuItemForTesting(.replace)) == false)
        #expect(transport.logAccessibilityValueForTesting == reviewChatLogText(for: chat))
        #expect(transport.logDocumentViewExportsUserInterfaceValidationForTesting)

        let copyItem = commandMenuItemForTesting("copy:")
        let selectAllItem = commandMenuItemForTesting("selectAll:")
        let cutItem = commandMenuItemForTesting("cut:")
        let pasteItem = commandMenuItemForTesting("paste:")
        let deleteItem = commandMenuItemForTesting("delete:")
        #expect(transport.validateLogDocumentUserInterfaceItemForTesting(copyItem) == false)
        #expect(transport.validateLogDocumentUserInterfaceItemForTesting(selectAllItem))
        #expect(transport.validateLogDocumentUserInterfaceItemForTesting(cutItem) == false)
        #expect(transport.validateLogDocumentUserInterfaceItemForTesting(pasteItem) == false)
        #expect(transport.validateLogDocumentUserInterfaceItemForTesting(deleteItem) == false)

        transport.selectAllLogForTesting()
        #expect(transport.logSelectedTextForTesting == reviewChatLogText(for: chat))
        #expect(transport.validateLogDocumentUserInterfaceItemForTesting(copyItem))
        #expect(transport.validateLogDocumentUserInterfaceItemForTesting(cutItem) == false)
        #expect(transport.validateLogDocumentUserInterfaceItemForTesting(pasteItem) == false)
        #expect(transport.validateLogDocumentUserInterfaceItemForTesting(deleteItem) == false)

        NSPasteboard.general.clearContents()
        transport.copyLogSelectionForTesting()
        #expect(NSPasteboard.general.string(forType: .string) == reviewChatLogText(for: chat))

        transport.clearLogFinderSelectedRangesForTesting()
        #expect(transport.logSelectedTextForTesting == nil)
        #expect(transport.validateLogDocumentUserInterfaceItemForTesting(copyItem) == false)

        transport.setSelectedLogRangeForTesting(NSRange(location: 0, length: 0))
        transport.performLogKeyboardCommandForTesting(
            #selector(NSStandardKeyBindingResponding.moveRightAndModifySelection(_:)))
        transport.performLogKeyboardCommandForTesting(
            #selector(NSStandardKeyBindingResponding.moveRightAndModifySelection(_:)))
        #expect(transport.logSelectedTextForTesting == "Fi")
        #expect(transport.validateLogDocumentUserInterfaceItemForTesting(copyItem))
        transport.performLogKeyboardCommandForTesting(#selector(NSStandardKeyBindingResponding.moveRight(_:)))
        #expect(transport.logSelectedTextForTesting == nil)
        transport.performLogKeyboardCommandForTesting(
            #selector(NSStandardKeyBindingResponding.moveRightAndModifySelection(_:)))
        #expect(transport.logSelectedTextForTesting == "r")

        let graphemeLog = "A🙂e\u{301}B\n"
        transport.renderLogForTesting(text: graphemeLog, allowIncrementalUpdate: false)
        transport.setSelectedLogRangeForTesting(NSRange(location: ("A" as NSString).length, length: 0))
        transport.performLogKeyboardCommandForTesting(
            #selector(NSStandardKeyBindingResponding.moveRightAndModifySelection(_:)))
        #expect(transport.logSelectedTextForTesting == "🙂")

        transport.setSelectedLogRangeForTesting(NSRange(location: ("A🙂" as NSString).length, length: 0))
        transport.performLogKeyboardCommandForTesting(
            #selector(NSStandardKeyBindingResponding.moveRightAndModifySelection(_:)))
        #expect(transport.logSelectedTextForTesting == "e\u{301}")
    }

    @Test func logKeyboardLineNavigationUsesSoftWrappedVisualLines() async throws {
        let wrappedLine = (1...80)
            .map { "wrapped-segment-\($0)" }
            .joined(separator: " ")
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-log-soft-wrap-keyboard",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: wrappedLine + "\nnext logical line\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let harness = makeWindowHarness(store: store, contentSize: NSSize(width: 560, height: 360))
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        transport.scrollLogToTopForTesting()
        #expect(transport.logVisibleFragmentViewCountForTesting > 0)

        transport.setSelectedLogRangeForTesting(NSRange(location: 0, length: 0))
        transport.performLogKeyboardCommandForTesting(
            #selector(NSStandardKeyBindingResponding.moveToEndOfLineAndModifySelection(_:)))
        let selectedVisualLineEnd = try #require(transport.logSelectedTextForTesting)
        #expect(selectedVisualLineEnd.isEmpty == false)
        #expect(selectedVisualLineEnd.contains("\n") == false)
        #expect((selectedVisualLineEnd as NSString).length < (wrappedLine as NSString).length)

        transport.setSelectedLogRangeForTesting(NSRange(location: 0, length: 0))
        transport.performLogKeyboardCommandForTesting(
            #selector(NSStandardKeyBindingResponding.moveDownAndModifySelection(_:)))
        let selectedVisualLineMove = try #require(transport.logSelectedTextForTesting)
        #expect(selectedVisualLineMove.isEmpty == false)
        #expect(selectedVisualLineMove.contains("\n") == false)
        #expect((selectedVisualLineMove as NSString).length < (wrappedLine as NSString).length)
    }

    @Test func logFindPreservesVisibleSearchStateDuringLogUpdatesUntilHidden() async throws {
        let initialLog =
            (1...140)
            .map { "needle \($0) with enough trailing text to wrap in the visible log surface" }
            .joined(separator: "\n") + "\n"
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-log-find-system-highlights",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: initialLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 360))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        let renderedInitialLog = reviewChatLogText(for: chat)
        let renderedInitialLength = (renderedInitialLog as NSString).length
        let visibleRanges = transport.logFindVisibleCharacterRangesForTesting
        #expect(transport.logFindIncrementalSearchUsesSystemHighlightingForTesting)
        #expect(transport.logFindBarContainerContentViewIsTextContentViewForTesting)
        #expect(transport.logFindStringLengthForTesting == renderedInitialLength)
        #expect(visibleRanges.isEmpty == false)
        #expect(visibleRanges.allSatisfy { $0.location >= 0 && NSMaxRange($0) <= renderedInitialLength })

        let firstNeedleRange = (renderedInitialLog as NSString).range(of: "needle")
        #expect(firstNeedleRange.location != NSNotFound)
        transport.setSelectedLogRangeForTesting(firstNeedleRange)
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.setSearchString))
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindIncrementalSearchUsesSystemHighlightingForTesting)
        try await waitForCondition {
            transport.logFindIncrementalMatchRangeCountForTesting > 0
        }
        #expect(transport.logFindClientUsesSnapshotForTesting)
        #expect(transport.logHasActiveFindQueryForTesting)
        appendChatLogEntryForTesting(
            .init(kind: .progress, text: "needle appended"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)

        let appendedLength = (reviewChatLogText(for: chat) as NSString).length
        let appendedVisibleRanges = transport.logFindVisibleCharacterRangesForTesting
        #expect(transport.logFindStringLengthForTesting == renderedInitialLength)
        #expect(transport.logSelectedTextForTesting == "needle")
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting)
        #expect(transport.logFindClientSnapshotMapsToDocumentForTesting)
        #expect(appendedVisibleRanges.allSatisfy { $0.location >= 0 && NSMaxRange($0) <= renderedInitialLength })

        viewController.performTextFinderAction(textFinderMenuItemForTesting(.nextMatch))
        #expect(transport.logSelectedTextForTesting == "needle")
        #expect(NSMaxRange(transport.logSelectedRangeForTesting) <= renderedInitialLength)
        #expect(appendedLength > renderedInitialLength)

        let middleOffset = transport.logMaximumVerticalScrollOffsetForTesting / 2
        let findIndicatorInvalidationCountBeforeSnapshotScroll = transport.logFindIndicatorInvalidationCountForTesting
        transport.scrollLogToOffsetForTesting(middleOffset)
        #expect(
            transport.logFindIndicatorInvalidationCountForTesting == findIndicatorInvalidationCountBeforeSnapshotScroll
                + 1)
        #expect(transport.isLogPinnedToBottomForTesting == false)

        let offsetBeforeMiddleAppend = transport.logVerticalScrollOffsetForTesting
        appendChatLogEntryForTesting(
            .init(kind: .progress, text: "needle appended while the log is not following bottom"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)

        #expect(abs(transport.logVerticalScrollOffsetForTesting - offsetBeforeMiddleAppend) < 0.5)
        #expect(transport.logSelectedTextForTesting == "needle")
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting)
        #expect(transport.logFindClientSnapshotMapsToDocumentForTesting)

        var burstText = reviewChatLogText(for: chat)
        for index in 0..<8 {
            burstText += "\nneedle burst \(index)"
            #expect(transport.renderLogForTesting(text: burstText, allowIncrementalUpdate: true))
        }

        #expect(transport.logSelectedTextForTesting == "needle")
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting)
        #expect(transport.logFindClientSnapshotMapsToDocumentForTesting)

        let reloadedText = "replacement header\nneedle after structural reload\n"
        let reloadedLength = (reloadedText as NSString).length
        #expect(
            transport.renderLogForTesting(
                text: reloadedText,
                allowIncrementalUpdate: false
            ))

        #expect(transport.logSelectedTextForTesting == nil)
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting)
        #expect(transport.logFindClientSnapshotMapsToDocumentForTesting == false)
        #expect(transport.logFindStringLengthForTesting == renderedInitialLength)

        viewController.performTextFinderAction(textFinderMenuItemForTesting(.nextMatch))
        #expect(transport.logSelectedTextForTesting == nil)
        #expect(NSMaxRange(transport.logSelectedRangeForTesting) <= reloadedLength)

        #expect(
            transport.renderLogForTesting(
                text: "",
                allowIncrementalUpdate: false
            ))
        #expect(transport.logFindClientUsesSnapshotForTesting == false)
        #expect(transport.logFindStringLengthForTesting == 0)

        let liveReloadText = "needle after empty structural reload\n"
        #expect(
            transport.renderLogForTesting(
                text: liveReloadText,
                allowIncrementalUpdate: false
            ))
        #expect(transport.logFindClientUsesSnapshotForTesting == false)
        #expect(transport.logFindStringLengthForTesting == (liveReloadText as NSString).length)

        viewController.performTextFinderAction(textFinderMenuItemForTesting(.hideFindInterface))
        #expect(transport.logFindBarVisibleForTesting == false)
        #expect(transport.logFindClientUsesSnapshotForTesting == false)
        #expect(transport.logFindIncrementalSearchUsesSystemHighlightingForTesting)

        let hiddenUpdateText = liveReloadText + "\nneedle after close\n"
        #expect(
            transport.renderLogForTesting(
                text: hiddenUpdateText,
                allowIncrementalUpdate: true
            ))

        #expect(transport.logFindStringLengthForTesting == (hiddenUpdateText as NSString).length)
    }

    @Test func logFindClearsVisibleSnapshotWhenLogContentIsReused() async throws {
        let firstChat = makeReviewChatFixtureForTesting(
            id: "chat-log-find-reuse-first",
            status: .running,
            targetSummary: "First chat",
            summary: "Running review.",
            logText: "needle first job\n"
        )
        let secondChat = makeReviewChatFixtureForTesting(
            id: "chat-log-find-reuse-second",
            status: .running,
            targetSummary: "Second chat",
            summary: "Running review.",
            logText: "needle second job\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [firstChat, secondChat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: firstChat.chatID)
        _ = try await awaitChatRenderForTesting(
            firstChat,
            in: transport,
            allowIncrementalUpdate: false
        )

        let firstNeedleRange = (reviewChatLogText(for: firstChat) as NSString).range(of: "needle")
        #expect(firstNeedleRange.location != NSNotFound)
        transport.setSelectedLogRangeForTesting(firstNeedleRange)
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.setSearchString))
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        appendChatLogEntryForTesting(
            .init(kind: .progress, text: "needle appended"),
            to: firstChat.chatID,
            turnID: firstChat.turnID
        )
        _ = try await awaitChatRenderForTesting(firstChat, in: transport)
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting)
        viewController.sidebarViewControllerForTesting.clearSelectionForTesting()
        _ = try await awaitTransportRender(transport)
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting == false)
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: secondChat.chatID)
        _ = try await awaitChatRenderForTesting(
            secondChat,
            in: transport,
            allowIncrementalUpdate: false
        )

        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting == false)
        #expect(transport.logFindStringLengthForTesting == (transport.displayedLogForTesting as NSString).length)
    }

    @Test func logFindContentReuseClearsSnapshotWhenSameTextSkipsRender() async throws {
        let initialLog = "needle initial"
        let appendedLine = "needle appended"
        let reusedLog = initialLog + "\n\n" + appendedLine
        let firstChat = makeReviewChatFixtureForTesting(
            id: "chat-log-find-same-text-reuse-first",
            status: .running,
            targetSummary: "First chat",
            summary: "Running review.",
            logText: initialLog
        )
        let secondChat = makeReviewChatFixtureForTesting(
            id: "chat-log-find-same-text-reuse-second",
            status: .running,
            targetSummary: "Second chat",
            summary: "Running review.",
            logText: reusedLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [firstChat, secondChat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: firstChat.chatID)
        _ = try await awaitChatRenderForTesting(
            firstChat,
            in: transport,
            allowIncrementalUpdate: false
        )

        let firstNeedleRange = (reviewChatLogText(for: firstChat) as NSString).range(of: "needle")
        #expect(firstNeedleRange.location != NSNotFound)
        transport.setSelectedLogRangeForTesting(firstNeedleRange)
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.setSearchString))
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        appendChatLogEntryForTesting(
            .init(kind: .progress, text: appendedLine),
            to: firstChat.chatID,
            turnID: firstChat.turnID
        )
        _ = try await awaitChatRenderForTesting(firstChat, in: transport)
        #expect(
            transport.displayedLogForTesting.trimmingCharacters(in: .newlines)
                == reviewChatLogText(for: secondChat).trimmingCharacters(in: .newlines)
        )
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting)

        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: secondChat.chatID)
        _ = try await awaitChatRenderForTesting(
            secondChat,
            in: transport,
            allowIncrementalUpdate: false
        )

        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting == false)
        #expect(transport.logFindStringLengthForTesting == (transport.displayedLogForTesting as NSString).length)
    }

    @Test func logFindContentReuseClearsSnapshotForPrefixRelatedLogs() async throws {
        let firstLog = "needle shared prefix\n"
        let firstChat = makeReviewChatFixtureForTesting(
            id: "chat-log-find-prefix-reuse-first",
            status: .running,
            targetSummary: "First chat",
            summary: "Running review.",
            logText: firstLog
        )
        let secondChat = makeReviewChatFixtureForTesting(
            id: "chat-log-find-prefix-reuse-second",
            status: .running,
            targetSummary: "Second chat",
            summary: "Running review.",
            logText: firstLog + "needle second suffix\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [firstChat, secondChat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: firstChat.chatID)
        _ = try await awaitChatRenderForTesting(
            firstChat,
            in: transport,
            allowIncrementalUpdate: false
        )

        let firstNeedleRange = (reviewChatLogText(for: firstChat) as NSString).range(of: "needle")
        #expect(firstNeedleRange.location != NSNotFound)
        transport.setSelectedLogRangeForTesting(firstNeedleRange)
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.setSearchString))
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.setLogVisibleFindBarSearchStringForTesting(""))
        #expect(transport.logFindClientUsesSnapshotForTesting == false)

        let finderIdentifierBeforeSwitch = transport.logTextFinderIdentifierForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: secondChat.chatID)
        _ = try await awaitChatRenderForTesting(
            secondChat,
            in: transport,
            allowIncrementalUpdate: false
        )

        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logTextFinderIdentifierForTesting == finderIdentifierBeforeSwitch)
        #expect(transport.logFindClientUsesSnapshotForTesting == false)
        #expect(transport.logFindStringLengthForTesting == (reviewChatLogText(for: secondChat) as NSString).length)
    }

    @Test func logFindHidingVisibleSnapshotReturnsClientToLiveString() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-log-find-hide-snapshot",
            status: .running,
            targetSummary: "Hide snapshot",
            summary: "Running review.",
            logText: "needle initial\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        let firstNeedleRange = (reviewChatLogText(for: chat) as NSString).range(of: "needle")
        #expect(firstNeedleRange.location != NSNotFound)
        transport.setSelectedLogRangeForTesting(firstNeedleRange)
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.setSearchString))
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        appendChatLogEntryForTesting(
            .init(kind: .progress, text: "needle appended"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)
        #expect(transport.logFindClientUsesSnapshotForTesting)

        viewController.performTextFinderAction(textFinderMenuItemForTesting(.hideFindInterface))

        #expect(transport.logFindBarVisibleForTesting == false)
        #expect(transport.logFindClientUsesSnapshotForTesting == false)
        #expect(transport.logFindStringLengthForTesting == (reviewChatLogText(for: chat) as NSString).length)
    }

    @Test func logFindClearedSelectionReturnsVisibleUpdatesToLiveString() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-log-find-cleared-selection",
            status: .running,
            targetSummary: "Cleared selection",
            summary: "Running review.",
            logText: "needle initial\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        let firstNeedleRange = (reviewChatLogText(for: chat) as NSString).range(of: "needle")
        #expect(firstNeedleRange.location != NSNotFound)
        transport.setSelectedLogRangeForTesting(firstNeedleRange)
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.setSearchString))
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        appendChatLogEntryForTesting(
            .init(kind: .progress, text: "needle appended into snapshot"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting)

        #expect(transport.setLogVisibleFindBarSearchStringForTesting(""))
        transport.clearLogFinderSelectedRangesForTesting()
        #expect(transport.logFindClientFirstSelectedRangeForTesting.length == 0)
        #expect(transport.logSelectedTextForTesting == nil)
        #expect(transport.logFindClientUsesSnapshotForTesting == false)
        appendChatLogEntryForTesting(
            .init(kind: .progress, text: "needle appended after cleared selection"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)

        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting == false)
        #expect(transport.logFindStringLengthForTesting == (reviewChatLogText(for: chat) as NSString).length)
    }

    @Test func logFindClearedQueryReturnsVisibleUpdatesToLiveString() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-log-find-cleared-query",
            status: .running,
            targetSummary: "Cleared query",
            summary: "Running review.",
            logText: "needle initial\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        let firstNeedleRange = (reviewChatLogText(for: chat) as NSString).range(of: "needle")
        #expect(firstNeedleRange.location != NSNotFound)
        transport.setSelectedLogRangeForTesting(firstNeedleRange)
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.setSearchString))
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        appendChatLogEntryForTesting(
            .init(kind: .progress, text: "needle appended into snapshot"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting)

        try await withFindPasteboardString(nil) {
            #expect(transport.setLogVisibleFindBarSearchStringForTesting(""))
            transport.simulateLogFinderEmptySelectedRangesForTesting()
            #expect(transport.logFindClientFirstSelectedRangeForTesting.length == 0)
            #expect(transport.logHasActiveFindQueryForTesting == false)
            #expect(transport.logFindClientUsesSnapshotForTesting == false)
            appendChatLogEntryForTesting(
                .init(kind: .progress, text: "needle appended after cleared query"),
                to: chat.chatID,
                turnID: chat.turnID
            )
            _ = try await awaitChatRenderForTesting(chat, in: transport)

            #expect(transport.logFindBarVisibleForTesting)
            #expect(transport.logFindClientUsesSnapshotForTesting == false)
            #expect(transport.logFindStringLengthForTesting == (reviewChatLogText(for: chat) as NSString).length)
        }
    }

    @Test func logFindDoesNotFreezeVisibleBarBeforeSearchQuery() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-log-find-visible-no-query",
            status: .running,
            targetSummary: "Visible find bar",
            summary: "Running review.",
            logText: "initial log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        try await withFindPasteboardString(nil) {
            viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
            #expect(transport.logFindBarVisibleForTesting)
            #expect(transport.setLogVisibleFindBarSearchStringForTesting(""))
            #expect(transport.logVisibleFindBarSearchStringForTesting == "")
            #expect(transport.logFindClientUsesSnapshotForTesting == false)
            appendChatLogEntryForTesting(
                .init(kind: .progress, text: "future-only needle"),
                to: chat.chatID,
                turnID: chat.turnID
            )
            _ = try await awaitChatRenderForTesting(chat, in: transport)

            #expect(transport.logFindBarVisibleForTesting)
            #expect(transport.logFindClientUsesSnapshotForTesting == false)
            #expect(transport.logFindStringLengthForTesting == (reviewChatLogText(for: chat) as NSString).length)
        }
    }

    @Test func logFindPreservesDirectFindBarQueryDuringLogUpdates() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-log-find-direct-query",
            status: .running,
            targetSummary: "Visible find bar direct query",
            summary: "Running review.",
            logText: "core initial log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        let initialLength = (reviewChatLogText(for: chat) as NSString).length
        try await withFindPasteboardString(nil) {
            viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
            #expect(transport.logFindBarVisibleForTesting)
            #expect(transport.setLogVisibleFindBarSearchStringForTesting("core"))
            #expect(transport.logVisibleFindBarSearchStringForTesting == "core")
            #expect(transport.logHasActiveFindQueryForTesting)
            appendChatLogEntryForTesting(
                .init(kind: .progress, text: "core appended while query is visible"),
                to: chat.chatID,
                turnID: chat.turnID
            )
            _ = try await awaitChatRenderForTesting(chat, in: transport)

            #expect(transport.logFindBarVisibleForTesting)
            #expect(transport.logVisibleFindBarSearchStringForTesting == "core")
            #expect(transport.logHasActiveFindQueryForTesting)
            #expect(transport.logFindClientUsesSnapshotForTesting)
            #expect(transport.logFindStringLengthForTesting == initialLength)
        }
    }

    @Test func logFindQueryChangeRefreshesVisibleSnapshotAfterLogUpdates() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-log-find-query-change",
            status: .running,
            targetSummary: "Visible find bar query change",
            summary: "Running review.",
            logText: "alpha initial log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        let initialLength = (reviewChatLogText(for: chat) as NSString).length
        try await withFindPasteboardString(nil) {
            viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
            #expect(transport.logFindBarVisibleForTesting)
            #expect(transport.setLogVisibleFindBarSearchStringForTesting("alpha"))
            #expect(transport.logFindStringLengthForTesting == initialLength)

            appendChatLogEntryForTesting(
                .init(kind: .progress, text: "beta appended after active search"),
                to: chat.chatID,
                turnID: chat.turnID
            )
            _ = try await awaitChatRenderForTesting(chat, in: transport)
            #expect(transport.logFindClientUsesSnapshotForTesting)
            #expect(transport.logFindStringLengthForTesting == initialLength)

            #expect(transport.setLogVisibleFindBarSearchStringForTesting("beta"))
            #expect(transport.logVisibleFindBarSearchStringForTesting == "beta")
            #expect(transport.logFindClientUsesSnapshotForTesting)
            #expect(transport.logFindClientSnapshotMapsToDocumentForTesting)
            #expect(transport.logFindStringLengthForTesting == (reviewChatLogText(for: chat) as NSString).length)
        }
    }

    @Test func logFindVisibleBarNormalSelectionKeepsUpdatesLive() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-log-find-visible-normal-selection",
            status: .running,
            targetSummary: "Visible find bar normal selection",
            summary: "Running review.",
            logText: "copyable text before updates\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        try await withFindPasteboardString(nil) {
            viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
            #expect(transport.logFindBarVisibleForTesting)
            #expect(transport.setLogVisibleFindBarSearchStringForTesting(""))
            #expect(transport.logVisibleFindBarSearchStringForTesting == "")
            let normalSelectionRange = (reviewChatLogText(for: chat) as NSString).range(of: "copyable")
            #expect(normalSelectionRange.location != NSNotFound)
            transport.setSelectedLogRangeForTesting(normalSelectionRange)
            #expect(transport.logSelectedTextForTesting == "copyable")
            #expect(transport.logHasActiveFindQueryForTesting == false)
            appendChatLogEntryForTesting(
                .init(kind: .progress, text: "needle appended after normal selection"),
                to: chat.chatID,
                turnID: chat.turnID
            )
            _ = try await awaitChatRenderForTesting(chat, in: transport)

            #expect(transport.logFindBarVisibleForTesting)
            #expect(transport.logFindClientUsesSnapshotForTesting == false)
            #expect(transport.logFindStringLengthForTesting == (reviewChatLogText(for: chat) as NSString).length)
        }
    }

    @Test func logFindPreservesNoResultSearchStateDuringLogUpdatesUntilHidden() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-log-find-visible-no-result",
            status: .running,
            targetSummary: "Visible find bar no result",
            summary: "Running review.",
            logText: "initial log without the active query\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientFirstSelectedRangeForTesting.length == 0)
        try await withFindPasteboardString("active query") {
            #expect(transport.setLogVisibleFindBarSearchStringForTesting("active query"))
            transport.simulateLogFinderEmptySelectedRangesForTesting()
            #expect(transport.logHasActiveFindQueryForTesting)

            let initialLength = (reviewChatLogText(for: chat) as NSString).length
            appendChatLogEntryForTesting(
                .init(kind: .progress, text: "active query appears after no-result search"),
                to: chat.chatID,
                turnID: chat.turnID
            )
            _ = try await awaitChatRenderForTesting(chat, in: transport)

            #expect(transport.logFindBarVisibleForTesting)
            #expect(transport.logFindClientUsesSnapshotForTesting)
            #expect(transport.logFindStringLengthForTesting == initialLength)

            viewController.performTextFinderAction(textFinderMenuItemForTesting(.hideFindInterface))
            #expect(transport.logFindBarVisibleForTesting == false)
            #expect(transport.logFindClientUsesSnapshotForTesting == false)
        }
    }

    private func withFindPasteboardString<T>(
        _ string: String?,
        perform body: () async throws -> T
    ) async rethrows -> T {
        let pasteboard = NSPasteboard(name: .find)
        let previousString = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        if let string {
            pasteboard.setString(string, forType: .string)
        }
        defer {
            pasteboard.clearContents()
            if let previousString {
                pasteboard.setString(previousString, forType: .string)
            }
        }
        return try await body()
    }

    @Test func logFindKeepsFirstAppendIntoEmptyVisibleLogLive() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-log-find-empty-append",
            status: .running,
            targetSummary: "Empty log",
            summary: "Running review.",
            logText: ""
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
        _ = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )

        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.setLogVisibleFindBarSearchStringForTesting(""))
        #expect(transport.logFindStringLengthForTesting == 0)
        appendChatLogEntryForTesting(
            .init(kind: .progress, text: "needle first content"),
            to: chat.chatID,
            turnID: chat.turnID
        )
        _ = try await awaitChatRenderForTesting(chat, in: transport)

        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting == false)
        #expect(transport.logFindStringLengthForTesting == (reviewChatLogText(for: chat) as NSString).length)
    }

    @Test func authFailedChatShowsNormalFailureDetails() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-auth",
            status: .failed,
            targetSummary: "Uncommitted changes",
            summary: "Failed to start review.",
            logText: "Authentication required. Sign in to ReviewMonitor and retry."
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            authState: .signedOut,
            fixtures: [chat]
        )
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)

        let snapshot = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(snapshot.summary == nil)
        #expect(snapshot.log == reviewChatLogText(for: chat))
    }

    @Test func authenticatedAuthFailedChatStillShowsNormalFailureDetails() async throws {
        let chat = makeReviewChatFixtureForTesting(
            id: "chat-auth-restored",
            status: .failed,
            targetSummary: "Uncommitted changes",
            summary: "Failed to start review.",
            logText: "Authentication required. Sign in to ReviewMonitor and retry."
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            authState: .signedIn(accountID: "review@example.com"),
            fixtures: [chat]
        )
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)

        let snapshot = try await awaitChatRenderForTesting(
            chat,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(snapshot.summary == nil)
        #expect(snapshot.log == reviewChatLogText(for: chat))
    }

}

func textFinderMenuItemForTesting(_ action: NSTextFinder.Action) -> NSMenuItem {
    let item = NSMenuItem(
        title: "",
        action: #selector(NSResponder.performTextFinderAction(_:)),
        keyEquivalent: ""
    )
    item.tag = action.rawValue
    return item
}

func commandMenuItemForTesting(_ selectorName: String) -> NSMenuItem {
    NSMenuItem(title: "", action: Selector((selectorName)), keyEquivalent: "")
}

@MainActor
struct ReviewMonitorWindowHarness {
    let windowController: ReviewMonitorWindowController
    let rootViewController: ReviewMonitorRootViewController
    let viewController: ReviewMonitorSplitViewController
    let window: NSWindow
}

@MainActor
func makeWindowHarness(
    store: CodexReviewStore,
    authState: TestAuthState = .signedIn(accountID: "review@example.com"),
    contentSize: NSSize? = nil,
    sidebarReviewChatFilterDefaults: UserDefaults? = nil,
    contentTransitionAnimator: @escaping ReviewMonitorContentTransitionAnimator = ReviewMonitorRootViewController
        .defaultContentTransitionAnimator
) -> ReviewMonitorWindowHarness {
    applyTestAuthState(auth: store.auth, state: authState)
    let previewRuntime = previewRuntimeForTesting(on: store)
    previewRuntime?.start()
    let windowController = ReviewMonitorWindowController(
        store: store,
        codexModelSource: previewRuntime?.modelSource,
        contentTransitionAnimator: contentTransitionAnimator,
        sidebarReviewChatFilterDefaults: sidebarReviewChatFilterDefaults
    )
    guard let window = windowController.window else {
        fatalError("ReviewMonitorWindowController did not create a window.")
    }
    guard let rootViewController = window.contentViewController as? ReviewMonitorRootViewController else {
        fatalError("ReviewMonitorWindowController did not install ReviewMonitorRootViewController.")
    }
    if let contentSize {
        window.setContentSize(contentSize)
    }
    return ReviewMonitorWindowHarness(
        windowController: windowController,
        rootViewController: rootViewController,
        viewController: rootViewController.splitViewControllerForTesting,
        window: window
    )
}

@MainActor
final class ManualContentTransitionAnimator {
    private var completions: [@MainActor () -> Void] = []
    private var animationCount = 0

    func animate(
        outgoingView: NSView,
        incomingView: NSView,
        completion: @escaping @MainActor () -> Void
    ) {
        outgoingView.alphaValue = 0
        incomingView.alphaValue = 1
        completions.append(completion)
        animationCount += 1
    }

    func waitForAnimationCount(
        _ expectedCount: Int,
        timeout: Duration = .seconds(2)
    ) async throws {
        let animatorBox = UncheckedSendableBox(self)
        try await withTestTimeout(timeout) {
            while await MainActor.run(body: {
                animatorBox.value.animationCount < expectedCount
            }) {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }

    func completeAll() {
        let pendingCompletions = completions
        completions.removeAll()
        for completion in pendingCompletions {
            completion()
        }
    }
}

@MainActor
func waitForWindowShowingSplitView(
    _ rootViewController: ReviewMonitorRootViewController,
    isShowing expected: Bool,
    timeout: Duration = .seconds(2)
) async throws {
    let rootViewControllerBox = UncheckedSendableBox(rootViewController)
    try await withTestTimeout(timeout) {
        while await MainActor.run(body: {
            rootViewControllerBox.value.isShowingSplitViewForTesting != expected
        }) {
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}

@MainActor
func waitForWindowContentKind(
    _ rootViewController: ReviewMonitorRootViewController,
    _ expected: ReviewMonitorContentKind,
    timeout: Duration = .seconds(2)
) async throws {
    let rootViewControllerBox = UncheckedSendableBox(rootViewController)
    try await withTestTimeout(timeout) {
        while await MainActor.run(body: {
            rootViewControllerBox.value.contentKindForTesting != expected
        }) {
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}

@MainActor
func waitForEmbeddedContentSubviewCount(
    _ rootViewController: ReviewMonitorRootViewController,
    _ expected: Int,
    timeout: Duration = .seconds(2)
) async throws {
    let rootViewControllerBox = UncheckedSendableBox(rootViewController)
    try await withTestTimeout(timeout) {
        while await MainActor.run(body: {
            rootViewControllerBox.value.embeddedContentSubviewCountForTesting != expected
        }) {
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}

@MainActor
func waitForSidebarPresentation(
    _ viewController: ReviewMonitorSplitViewController,
    _ expected: ReviewMonitorSplitViewController.SidebarPresentationForTesting,
    observation: PortableObservationTracking.Token?,
    timeout: Duration = .seconds(2)
) async throws {
    try await waitForObservedValue(from: observation, expected, timeout: timeout) {
        viewController.sidebarPresentationForTesting
    }
}

@MainActor
func waitForWorkspaceExpanded(
    _ viewController: ReviewMonitorSidebarViewController,
    workspaceCWD: String,
    _ expected: Bool,
    timeout: Duration = .seconds(2)
) async throws {
    let viewControllerBox = UncheckedSendableBox(viewController)
    let workspaceCWDBox = UncheckedSendableBox(workspaceCWD)
    try await withTestTimeout(timeout) {
        while await MainActor.run(body: {
            viewControllerBox.value.workspaceIsExpandedForTesting(cwd: workspaceCWDBox.value) != expected
        }) {
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}

@MainActor
func waitForSidebarBottomAccessoryHidden(
    _ viewController: ReviewMonitorSplitViewController,
    _ expected: Bool,
    timeout: Duration = .seconds(2)
) async throws {
    let viewControllerBox = UncheckedSendableBox(viewController)
    try await withTestTimeout(timeout) {
        while await MainActor.run(body: {
            viewControllerBox.value.sidebarBottomAccessoryIsHiddenForTesting != expected
        }) {
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}

@MainActor
func waitForAddAccountToolbarItemHidden(
    _ viewController: ReviewMonitorSplitViewController,
    _ expected: Bool,
    timeout: Duration = .seconds(2)
) async throws {
    let viewControllerBox = UncheckedSendableBox(viewController)
    try await withTestTimeout(timeout) {
        while await MainActor.run(body: {
            if let window = viewControllerBox.value.view.window {
                window.layoutIfNeeded()
            }
            viewControllerBox.value.view.layoutSubtreeIfNeeded()
            return viewControllerBox.value.addAccountToolbarItemIsHiddenForTesting != expected
        }) {
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}

@MainActor
func waitForAddAccountToolbarMode(
    _ viewController: ReviewMonitorSplitViewController,
    _ expected: ReviewMonitorSplitViewController.AddAccountToolbarItemModeForTesting,
    timeout: Duration = .seconds(2)
) async throws {
    let viewControllerBox = UncheckedSendableBox(viewController)
    try await withTestTimeout(timeout) {
        await MainActor.run {
            if let window = viewControllerBox.value.view.window {
                window.layoutIfNeeded()
            }
            viewControllerBox.value.view.layoutSubtreeIfNeeded()
        }
        await viewControllerBox.value.waitForAddAccountToolbarItemModeForTesting(expected)
    }
}

func withTestTimeout<T: Sendable>(
    _ timeout: Duration = .seconds(2),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TestFailure("timed out")
        }
        defer { group.cancelAll() }
        return try await #require(group.next())
    }
}

@MainActor
func waitForCondition(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @MainActor @Sendable () -> Bool
) async throws {
    try await withTestTimeout(timeout) {
        while await MainActor.run(body: {
            condition() == false
        }) {
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}

@MainActor
func observedValues<Value: Sendable>(
    from observation: PortableObservationTracking.Token?,
    sample: @escaping @MainActor @Sendable () -> Value
) async throws -> ObservedValues<Value> {
    let observation = try #require(observation)
    return await observation.values {
        sample()
    }
}

@MainActor
func waitForObservedValue<Value: Sendable & Equatable>(
    from observation: PortableObservationTracking.Token?,
    _ expected: Value,
    timeout: Duration = .seconds(2),
    sample: @escaping @MainActor @Sendable () -> Value
) async throws {
    let values = try await observedValues(from: observation, sample: sample)
    guard await values.waitUntilValue(expected, timeout: timeout) else {
        throw TestFailure("timed out waiting for observed value")
    }
}

@MainActor
func waitForObservedValueFromCurrentObservation<Value: Sendable & Equatable>(
    from observation: @escaping @MainActor @Sendable () -> PortableObservationTracking.Token?,
    _ expected: Value,
    timeout: Duration = .seconds(2),
    sample: @escaping @MainActor @Sendable () -> Value
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    repeat {
        if sample() == expected {
            return
        }

        if let token = observation() {
            let values = await token.values {
                sample()
            }
            defer {
                values.cancel()
            }
            if await values.waitUntilValue(expected, timeout: .milliseconds(50)) {
                return
            }
        }

        try Task.checkCancellation()
        await Task.yield()
    } while clock.now < deadline

    throw TestFailure("timed out waiting for observed value")
}

@MainActor
func awaitTransportRender(
    _ transport: ReviewMonitorTransportViewController,
    observation explicitObservation: PortableObservationTracking.Token? = nil,
    timeout: Duration = .seconds(2),
    matching predicate: (@Sendable (ReviewMonitorTransportViewController.RenderSnapshotForTesting) -> Bool)? = nil
) async throws -> ReviewMonitorTransportViewController.RenderSnapshotForTesting {
    _ = try #require(explicitObservation ?? transport.observationForExpectedRenderedStateForTesting)
    let expectedState = transport.expectedRenderedStateForTesting
    let resolvedPredicate: @Sendable (ReviewMonitorTransportViewController.RenderedStateForTesting) -> Bool = { state in
        if let predicate {
            return predicate(state.snapshot)
        }
        return state == expectedState
    }

    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    repeat {
        let state = transport.renderedStateForTesting
        if transport.logRenderIsIdleForTesting, resolvedPredicate(state) {
            return state.snapshot
        }
        await Task.yield()
    } while clock.now < deadline

    let state = transport.renderedStateForTesting
    if transport.logRenderIsIdleForTesting, resolvedPredicate(state) {
        return state.snapshot
    }
    throw TestFailure(
        "timed out waiting for rendered transport state: "
            + "idle=\(transport.logRenderIsIdleForTesting), "
            + "actual=\(state), expected=\(expectedState)"
    )
}

@MainActor
func awaitNativeLayoutTurn() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

@MainActor
func expectLogTextContainerWidthTracksContentView(
    _ transport: ReviewMonitorTransportViewController
) {
    let textContentFrame = transport.logTextContentFrameForTesting
    let textContainerInset = transport.logTextContainerInsetForTesting
    let textContainerSize = transport.logTextContainerSizeForTesting
    let expectedWidth = max(0, textContentFrame.width - textContainerInset.width * 2)

    #expect(abs(textContainerSize.width - expectedWidth) < 1)
}

@MainActor
func expectLogVisibleFragmentsWithoutForcingLayout(
    _ transport: ReviewMonitorTransportViewController
) {
    let fragmentBounds = transport.logVisibleFragmentBoundsWithoutForcingLayoutForTesting
    let viewportRect = NSRect(
        x: 0,
        y: transport.logVerticalScrollOffsetForTesting,
        width: transport.logDocumentViewFrameForTesting.width,
        height: transport.logViewportHeightForTesting
    )

    #expect(transport.logVisibleFragmentViewCountWithoutForcingLayoutForTesting > 0)
    #expect(fragmentBounds.isEmpty == false)
    #expect(fragmentBounds.intersects(viewportRect))
    #expect(transport.logStaleFragmentViewCountForTesting == 0)
}

@MainActor
func awaitContentPaneRender(
    _ contentPane: ReviewMonitorTransportViewController,
    observation explicitObservation: PortableObservationTracking.Token? = nil,
    timeout: Duration = .seconds(2),
    matching predicate: (@Sendable (ReviewMonitorTransportViewController.RenderSnapshotForTesting) -> Bool)? = nil
) async throws -> ReviewMonitorTransportViewController.RenderSnapshotForTesting {
    try await awaitTransportRender(
        contentPane,
        observation: explicitObservation,
        timeout: timeout,
        matching: predicate
    )
}

@MainActor
func waitForOverlayScrollerHideRequest(
    in transport: ReviewMonitorTransportViewController,
    exceeding previousCount: Int,
    timeout: Duration = .seconds(2)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    repeat {
        if transport.logOverlayScrollerHideRequestCountForTesting > previousCount {
            return
        }
        try Task.checkCancellation()
        await Task.yield()
    } while clock.now < deadline

    throw TestFailure("timed out waiting for overlay scroller hide request")
}

@MainActor
func waitForLogPinnedToBottom(
    in transport: ReviewMonitorTransportViewController,
    timeout: Duration = .seconds(2)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    repeat {
        if transport.isLogPinnedToBottomForTesting {
            return
        }
        try Task.checkCancellation()
        await Task.yield()
    } while clock.now < deadline

    throw TestFailure("timed out waiting for log to pin to bottom")
}

final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

@MainActor
func makeReviewChatFixtureForTesting(
    id: String = UUID().uuidString,
    cwd: String = "/tmp/repo",
    startedAt: Date = Date(timeIntervalSince1970: 200),
    status: ReviewChatFixtureStatus,
    targetSummary: String,
    summary: String? = nil,
    logText: String = ""
) -> ReviewChatFixtureForTesting {
    let trimmedLogText = logText.trimmingCharacters(in: .newlines)
    return makeReviewChatFixtureForTesting(
        id: id,
        cwd: cwd,
        title: targetSummary,
        preview: summary ?? status.displayText,
        status: status,
        startedAt: startedAt,
        updatedAt: status.isTerminal ? startedAt.addingTimeInterval(1) : startedAt,
        chatEntries: trimmedLogText.isEmpty
            ? []
            : [.init(kind: .agentMessage, groupID: "fixture-log-\(id)", text: trimmedLogText)]
    )
}

@MainActor
func reviewChatCellTestChat(
    id: String,
    title: String,
    workspaceCWD: String
) async throws -> CodexChat {
    let chatID = CodexThreadID(rawValue: id)
    let workspaceURL = URL(fileURLWithPath: workspaceCWD, isDirectory: true)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: workspaceURL.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
    let runtime = try await CodexAppServerTestRuntime.start()
    let context = CodexModelContainer(appServer: runtime.server).mainContext
    try await runtime.transport.enqueueThreadList(
        .init(
            threads: [
                .init(
                    id: chatID,
                    workspace: workspaceURL,
                    name: title,
                    updatedAt: Date(timeIntervalSince1970: 200),
                    status: .idle
                )
            ]
        ))
    let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>())
    try await results.performFetch()
    guard let chat = results.items.first else {
        throw TestFailure("Expected test CodexChat for \(id).")
    }
    return chat
}

struct LinkedWorktreeFixtureForTesting {
    var rootURL: URL
    var firstWorktreeURL: URL
    var secondWorktreeURL: URL
}

func makeLinkedWorktreeFixtureForTesting(
    repositoryName: String,
    fileManager: FileManager = .default
) throws -> LinkedWorktreeFixtureForTesting {
    let rootURL = fileManager.temporaryDirectory
        .appendingPathComponent("CodexReviewKitWorktreeGrouping-\(UUID().uuidString)", isDirectory: true)
    let repositoryURL = rootURL.appendingPathComponent(repositoryName, isDirectory: true)
    let repositoryGitURL = repositoryURL.appendingPathComponent(".git", isDirectory: true)
    let worktreesURL = rootURL.appendingPathComponent("worktrees", isDirectory: true)
    let firstWorktreeURL =
        worktreesURL
        .appendingPathComponent("825b", isDirectory: true)
        .appendingPathComponent(repositoryName, isDirectory: true)
    let secondWorktreeURL =
        worktreesURL
        .appendingPathComponent("be78", isDirectory: true)
        .appendingPathComponent(repositoryName, isDirectory: true)
    let firstGitDirURL =
        repositoryGitURL
        .appendingPathComponent("worktrees", isDirectory: true)
        .appendingPathComponent("825b", isDirectory: true)
    let secondGitDirURL =
        repositoryGitURL
        .appendingPathComponent("worktrees", isDirectory: true)
        .appendingPathComponent("be78", isDirectory: true)

    try fileManager.createDirectory(at: repositoryGitURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: firstWorktreeURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: secondWorktreeURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: firstGitDirURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: secondGitDirURL, withIntermediateDirectories: true)

    try "gitdir: \(firstGitDirURL.path)\n".write(
        to: firstWorktreeURL.appendingPathComponent(".git"),
        atomically: true,
        encoding: .utf8
    )
    try "gitdir: \(secondGitDirURL.path)\n".write(
        to: secondWorktreeURL.appendingPathComponent(".git"),
        atomically: true,
        encoding: .utf8
    )
    try "../..\n".write(
        to: firstGitDirURL.appendingPathComponent("commondir"),
        atomically: true,
        encoding: .utf8
    )
    try "../..\n".write(
        to: secondGitDirURL.appendingPathComponent("commondir"),
        atomically: true,
        encoding: .utf8
    )

    return LinkedWorktreeFixtureForTesting(
        rootURL: rootURL,
        firstWorktreeURL: firstWorktreeURL,
        secondWorktreeURL: secondWorktreeURL
    )
}

struct TestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

struct TestAuthState: Equatable {
    var phase: CodexReviewAuthModel.Phase
    var accountEmail: String?
    var accountPlanType: String?

    init(
        isAuthenticated: Bool = false,
        accountID: String? = nil,
        progress: CodexReviewAuthModel.Progress? = nil,
        errorMessage: String? = nil
    ) {
        if let progress {
            phase = .signingIn(progress)
        } else if let errorMessage {
            phase = .failed(message: errorMessage)
        } else {
            phase = .signedOut
        }
        accountEmail = isAuthenticated ? accountID : nil
        accountPlanType = isAuthenticated ? "pro" : nil
    }

    static let signedOut = Self()

    static func signedIn(accountID: String?) -> Self {
        .init(
            isAuthenticated: true,
            accountID: accountID
        )
    }

    static func signingIn(_ progress: CodexReviewAuthModel.Progress) -> Self {
        .init(progress: progress)
    }

    static func failed(
        _ message: String,
        isAuthenticated: Bool = false,
        accountID: String? = nil
    ) -> Self {
        .init(
            isAuthenticated: isAuthenticated,
            accountID: accountID,
            errorMessage: message
        )
    }

    var progress: CodexReviewAuthModel.Progress? {
        guard case .signingIn(let progress) = phase else {
            return nil
        }
        return progress
    }

    var isAuthenticated: Bool {
        accountEmail != nil
    }

    var errorMessage: String? {
        guard case .failed(let message) = phase else {
            return nil
        }
        return message
    }
}

@MainActor
func applyTestAuthState(
    auth: CodexReviewAuthModel,
    state: TestAuthState
) {
    auth.updatePhase(state.phase)
    if let accountEmail = state.accountEmail {
        let account = CodexReviewAccount(
            email: accountEmail,
            planType: state.accountPlanType ?? "pro"
        )
        auth.updatePersistedAccounts([account])
        auth.updateAccount(account)
    } else {
        auth.updatePersistedAccounts([CodexReviewAccount]())
        auth.updateAccount(nil as CodexReviewAccount?)
    }
}

@MainActor
func testAuthState(from auth: CodexReviewAuthModel) -> TestAuthState {
    .init(
        isAuthenticated: auth.isAuthenticated,
        accountID: auth.selectedAccount?.email,
        progress: auth.progress,
        errorMessage: auth.errorMessage
    )
}

@MainActor
extension CodexReviewStore {
    func loadForTesting(
        serverState: CodexReviewServerState,
        authState: TestAuthState = .signedOut,
        serverURL: URL? = nil,
        fixtures: [ReviewChatFixtureForTesting],
        settingsSnapshot: CodexReviewSettings.Snapshot? = nil
    ) {
        loadForTesting(
            serverState: serverState,
            authState: authState,
            serverURL: serverURL,
            settingsSnapshot: settingsSnapshot
        )
        installPreviewChatLogSourceForTesting(on: self, fixtures: fixtures)
    }

    func loadForTesting(
        serverState: CodexReviewServerState,
        authState: TestAuthState = .signedOut,
        serverURL: URL? = nil,
        settingsSnapshot: CodexReviewSettings.Snapshot? = nil
    ) {
        loadForTesting(
            serverState: serverState,
            authPhase: authState.phase,
            account: authState.accountEmail.map {
                CodexReviewAccount(
                    email: $0,
                    planType: authState.accountPlanType ?? "pro"
                )
            },
            persistedAccounts: authState.accountEmail.map {
                [
                    CodexReviewAccount(
                        email: $0,
                        planType: authState.accountPlanType ?? "pro"
                    )
                ]
            } ?? [],
            serverURL: serverURL,
            reviewRuns: [],
            settingsSnapshot: settingsSnapshot
        )
    }

    func loadReviewCancellationStateForTesting(
        serverState: CodexReviewServerState,
        authState: TestAuthState = .signedOut,
        serverURL: URL? = nil,
        reviewRuns: [ReviewRunRecord],
        settingsSnapshot: CodexReviewSettings.Snapshot? = nil
    ) {
        loadForTesting(
            serverState: serverState,
            authPhase: authState.phase,
            account: authState.accountEmail.map {
                CodexReviewAccount(
                    email: $0,
                    planType: authState.accountPlanType ?? "pro"
                )
            },
            persistedAccounts: authState.accountEmail.map {
                [
                    CodexReviewAccount(
                        email: $0,
                        planType: authState.accountPlanType ?? "pro"
                    )
                ]
            } ?? [],
            serverURL: serverURL,
            reviewRuns: reviewRuns,
            settingsSnapshot: settingsSnapshot
        )
    }
}

@MainActor
func makeSettingsSnapshot(
    model: String? = "gpt-5.4",
    fallbackModel: String? = nil,
    reasoningEffort: CodexReviewSettings.ReasoningEffort = .medium,
    serviceTier: CodexReviewSettings.ServiceTier? = .fast
) -> CodexReviewSettings.Snapshot {
    .init(
        model: model,
        fallbackModel: fallbackModel,
        reasoningEffort: reasoningEffort,
        serviceTier: serviceTier,
        models: ReviewMonitorPreviewContent.makePreviewModelCatalog()
    )
}

@MainActor
func makeStore(backend: CountingStartBackend) -> CodexReviewStore {
    CodexReviewStore.makeTestingStore(backend: backend)
}

@MainActor
func makeStore(backend: AuthActionBackend) -> CodexReviewStore {
    CodexReviewStore.makeTestingStore(backend: backend)
}

@MainActor
final class CountingStartBackend: PreviewCodexReviewStoreBackend {
    private var startCalls = 0

    override func start(
        store _: CodexReviewStore,
        forceRestartIfNeeded _: Bool
    ) async {
        isActive = true
        startCalls += 1
    }

    override func stop(store _: CodexReviewStore) async {
        isActive = false
    }

    override func waitUntilStopped() async {}

    func startCallCount() -> Int {
        startCalls
    }
}

@MainActor
final class AuthActionBackend: PreviewCodexReviewStoreBackend {
    private var refreshCalls = 0
    private var switchCalls = 0

    init(initialAuthState: TestAuthState = .signedOut) {
        let initialAccount = initialAuthState.accountEmail.map {
            CodexReviewAccount(email: $0, planType: initialAuthState.accountPlanType ?? "pro")
        }
        super.init(
            seed: .init(
                shouldAutoStartEmbeddedServer: false,
                initialAccount: initialAccount,
                initialAccounts: initialAccount.map { [$0] } ?? []
            )
        )
    }

    override func start(
        store _: CodexReviewStore,
        forceRestartIfNeeded _: Bool
    ) async {
        isActive = true
    }

    override func stop(store _: CodexReviewStore) async {
        isActive = false
    }

    override func waitUntilStopped() async {}

    override func refreshAuth(auth _: CodexReviewAuthModel) async {
        refreshCalls += 1
    }

    override func switchAccount(
        auth _: CodexReviewAuthModel,
        accountKey _: String
    ) async throws {
        switchCalls += 1
    }

    func refreshAuthStateCallCount() -> Int {
        refreshCalls
    }

    func switchAccountCallCount() -> Int {
        switchCalls
    }
}

@MainActor
final class FailingCancellationBackend: PreviewCodexReviewStoreBackend {
    init() {
        super.init(
            seed: .init(
                shouldAutoStartEmbeddedServer: false
            )
        )
    }

    override func start(
        store _: CodexReviewStore,
        forceRestartIfNeeded _: Bool
    ) async {
    }

    override func stop(store _: CodexReviewStore) async {
    }

    override func waitUntilStopped() async {}

    override func interruptReview(
        _: CodexReviewBackendModel.Review.Run, reason _: CodexReviewBackendModel.CancellationReason
    ) async throws {
        throw CodexReviewAPI.Error.io("Cancellation failed.")
    }

}

@MainActor
final class BlockingSettingsBackend: PreviewCodexReviewStoreBackend {
    struct ModelUpdateCall: Equatable {
        let model: String?
        let reasoningEffort: CodexReviewSettings.ReasoningEffort?
        let serviceTier: CodexReviewSettings.ServiceTier?
    }

    private(set) var refreshCallCount = 0
    private(set) var modelUpdateCalls: [ModelUpdateCall] = []
    private(set) var reasoningUpdateCalls: [CodexReviewSettings.ReasoningEffort?] = []
    private(set) var serviceTierUpdateCalls: [CodexReviewSettings.ServiceTier?] = []

    private var shouldBlockNextRefresh = false
    private var shouldBlockNextModelUpdate = false
    private var shouldBlockNextReasoningUpdate = false
    private let blockedRefreshStartedGate = OneShotGate()
    private let blockedRefreshResumeGate = OneShotGate()
    private let blockedModelUpdateStartedGate = OneShotGate()
    private let blockedModelUpdateResumeGate = OneShotGate()
    private let blockedReasoningUpdateStartedGate = OneShotGate()
    private let blockedReasoningUpdateResumeGate = OneShotGate()

    init(snapshot: CodexReviewSettings.Snapshot) {
        super.init(
            seed: .init(
                shouldAutoStartEmbeddedServer: false,
                initialSettingsSnapshot: snapshot
            )
        )
    }

    override func start(
        store _: CodexReviewStore,
        forceRestartIfNeeded _: Bool
    ) async {
    }

    override func stop(store _: CodexReviewStore) async {
    }

    override func waitUntilStopped() async {}

    override func refreshSettings() async throws -> CodexReviewSettings.Snapshot {
        refreshCallCount += 1
        if shouldBlockNextRefresh {
            shouldBlockNextRefresh = false
            await blockedRefreshStartedGate.open()
            await blockedRefreshResumeGate.wait()
        }
        return currentSettingsSnapshot
    }

    override func updateSettingsModel(
        _ model: String?,
        reasoningEffort: CodexReviewSettings.ReasoningEffort?,
        persistReasoningEffort: Bool,
        serviceTier: CodexReviewSettings.ServiceTier?,
        persistServiceTier: Bool
    ) async throws {
        modelUpdateCalls.append(
            .init(
                model: model,
                reasoningEffort: reasoningEffort,
                serviceTier: serviceTier
            )
        )
        currentSettingsSnapshot.model = model
        if persistReasoningEffort {
            currentSettingsSnapshot.reasoningEffort = reasoningEffort
        }
        if persistServiceTier {
            currentSettingsSnapshot.serviceTier = serviceTier
        }

        if shouldBlockNextModelUpdate {
            shouldBlockNextModelUpdate = false
            await blockedModelUpdateStartedGate.open()
            await blockedModelUpdateResumeGate.wait()
        }
    }

    override func updateSettingsReasoningEffort(
        _ reasoningEffort: CodexReviewSettings.ReasoningEffort?
    ) async throws {
        reasoningUpdateCalls.append(reasoningEffort)
        currentSettingsSnapshot.reasoningEffort = reasoningEffort

        if shouldBlockNextReasoningUpdate {
            shouldBlockNextReasoningUpdate = false
            await blockedReasoningUpdateStartedGate.open()
            await blockedReasoningUpdateResumeGate.wait()
        }
    }

    override func updateSettingsServiceTier(
        _ serviceTier: CodexReviewSettings.ServiceTier?
    ) async throws {
        serviceTierUpdateCalls.append(serviceTier)
        currentSettingsSnapshot.serviceTier = serviceTier
    }

    func blockNextRefresh() {
        shouldBlockNextRefresh = true
    }

    func waitForBlockedRefreshToStart() async {
        await blockedRefreshStartedGate.wait()
    }

    func resumeBlockedRefresh() async {
        await blockedRefreshResumeGate.open()
    }

    func blockNextModelUpdate() {
        shouldBlockNextModelUpdate = true
    }

    func waitForBlockedModelUpdateToStart() async {
        await blockedModelUpdateStartedGate.wait()
    }

    func resumeBlockedModelUpdate() async {
        await blockedModelUpdateResumeGate.open()
    }

    func blockNextReasoningUpdate() {
        shouldBlockNextReasoningUpdate = true
    }

    func waitForBlockedReasoningUpdateToStart() async {
        await blockedReasoningUpdateStartedGate.wait()
    }

    func resumeBlockedReasoningUpdate() async {
        await blockedReasoningUpdateResumeGate.open()
    }
}
