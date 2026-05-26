import AppKit
import Foundation
import SwiftUI
import Testing
@_spi(Testing) @testable import CodexReview
@_spi(PreviewSupport) @testable import ReviewUI
import CodexReviewTesting

@Suite(.serialized)
@MainActor
struct ReviewUIShellTests {
    @Test func rootViewControllerLoadsContentDuringViewLifecycle() {
        let rootViewController = makeReviewMonitorPreviewContentViewControllerForPreview()

        #expect(rootViewController.isViewLoaded == false)

        rootViewController.loadViewIfNeeded()

        #expect(rootViewController.isViewLoaded)
        #expect(rootViewController.isSplitViewEmbeddedForTesting)
    }

    @Test func bindingStoreAppliesInitialState() {
        let store = CodexReviewStore.makePreviewStore()
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarTopAccessoryCountForTesting == 0)
        #expect(viewController.sidebarAccessoryCountForTesting == 1)
        #expect(viewController.contentAccessoryCountForTesting == 0)
        #expect(viewController.sidebarViewControllerForTesting.isShowingEmptyStateForTesting)
        #expect(viewController.contentPaneViewControllerForTesting.isShowingEmptyStateForTesting)
    }

    @Test func splitViewShowsEmptyStateWithoutJobs() {
        let store = CodexReviewStore.makePreviewStore()
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        #expect(viewController.splitViewItems.count == 2)
        #expect(viewController.sidebarTopAccessoryCountForTesting == 0)
        #expect(viewController.sidebarAccessoryCountForTesting == 1)
        #expect(viewController.contentAccessoryCountForTesting == 0)
        #expect(viewController.sidebarViewControllerForTesting.isShowingEmptyStateForTesting)
        #expect(viewController.contentPaneViewControllerForTesting.isShowingEmptyStateForTesting)
    }

    @Test func splitViewShowsUnavailableSidebarWhenServerFailedOnLoad() {
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .failed("Embedded server is unavailable in preview mode."),
            workspaces: []
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        #expect(viewController.splitViewItems.count == 2)
        #expect(viewController.sidebarPresentationForTesting == .unavailable)
        #expect(viewController.sidebarTopAccessoryCountForTesting == 0)
        #expect(viewController.sidebarAccessoryCountForTesting == 1)
    }

    @Test func splitViewShowsJobSidebarWhenServerRunningOnLoad() {
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            serverURL: URL(string: "http://localhost:9417/mcp"),
            workspaces: []
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarPresentationForTesting == .jobList)
        #expect(viewController.sidebarTopAccessoryCountForTesting == 0)
        #expect(viewController.sidebarAccessoryCountForTesting == 1)
    }

    @Test func splitViewSwitchesSidebarPresentationWhenPickerSelectionChanges() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarPresentationForTesting == .jobList)
        #expect(viewController.sidebarBottomAccessoryIsHiddenForTesting == false)

        uiState.sidebarSelection = .account
        try await waitForSidebarBottomAccessoryHidden(viewController, true)
        #expect(viewController.sidebarPresentationForTesting == .accountList)

        uiState.sidebarSelection = .workspace
        try await waitForSidebarBottomAccessoryHidden(viewController, false)
        #expect(viewController.sidebarPresentationForTesting == .jobList)
    }

    @Test func statusAccessoryViewControllerVisibilityTracksOnlySidebarSelection() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let viewController = ReviewMonitorServerStatusAccessoryViewController(
            store: store,
            uiState: uiState
        )
        viewController.loadViewIfNeeded()

        #expect(viewController.isHidden == false)

        store.loadForTesting(
            serverState: .failed("Embedded server is unavailable in preview mode."),
            workspaces: []
        )
        #expect(viewController.isHidden == false)

        uiState.sidebarSelection = .account
        try await waitForCondition {
            viewController.isHidden
        }
    }

    @Test func contentPaneExtendsDisplayedContentBehindTitlebarWithoutOverlappingSidebar() {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 900, height: 600)
        )
        let window = harness.window
        defer { window.close() }

        let contentPane = harness.viewController.contentPaneViewControllerForTesting
        window.layoutIfNeeded()
        contentPane.view.layoutSubtreeIfNeeded()

        let viewBounds = contentPane.viewBoundsForTesting
        let safeAreaFrame = contentPane.safeAreaFrameForTesting
        let displayedViewFrame = contentPane.displayedViewFrameForTesting

        #expect(abs(displayedViewFrame.minX - safeAreaFrame.minX) < 0.5)
        #expect(abs(displayedViewFrame.maxX - safeAreaFrame.maxX) < 0.5)
        #expect(abs(displayedViewFrame.minY - safeAreaFrame.minY) < 0.5)
        #expect(abs(displayedViewFrame.maxY - viewBounds.maxY) < 0.5)
        #expect(safeAreaFrame.maxY < viewBounds.maxY)
        #expect(contentPane.activeDisplayedViewConstraintCountForTesting == 4)
    }

    @Test func detailEmptyStateHostingViewFillsContentHeightIgnoringVerticalSafeArea() {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 900, height: 600)
        )
        let window = harness.window
        defer { window.close() }

        let contentPane = harness.viewController.contentPaneViewControllerForTesting
        window.layoutIfNeeded()
        contentPane.view.layoutSubtreeIfNeeded()

        let viewBounds = contentPane.viewBoundsForTesting
        let safeAreaFrame = contentPane.safeAreaFrameForTesting
        let emptyStateFrame = contentPane.emptyStateFrameForTesting

        #expect(contentPane.isShowingEmptyStateForTesting)
        #expect(abs(emptyStateFrame.minX - safeAreaFrame.minX) < 0.5)
        #expect(abs(emptyStateFrame.maxX - safeAreaFrame.maxX) < 0.5)
        #expect(abs(emptyStateFrame.minY - viewBounds.minY) < 0.5)
        #expect(abs(emptyStateFrame.maxY - viewBounds.maxY) < 0.5)
        #expect(safeAreaFrame.maxY < viewBounds.maxY)
    }

    @Test func sidebarScrollViewExtendsBehindBottomAccessory() {
        let store = ReviewMonitorPreviewContent.makeStore(
            streamInterval: .seconds(60)
        )
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 760, height: 420)
        )
        let window = harness.window
        defer { window.close() }

        let sidebar = harness.viewController.sidebarViewControllerForTesting
        window.layoutIfNeeded()
        sidebar.view.layoutSubtreeIfNeeded()

        let safeAreaFrame = sidebar.safeAreaFrameForTesting
        let scrollViewFrame = sidebar.scrollViewFrameForTesting

        #expect(safeAreaFrame.minY > sidebar.view.bounds.minY)
        #expect(abs(scrollViewFrame.minY - sidebar.view.bounds.minY) < 0.5)
        #expect(scrollViewFrame.minY < safeAreaFrame.minY)
        #expect(abs(scrollViewFrame.maxY - sidebar.view.bounds.maxY) < 0.5)
    }

    @Test func splitViewSwitchesSidebarWhenServerAvailabilityChanges() async throws {
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            serverURL: URL(string: "http://localhost:9417/mcp"),
            workspaces: []
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarPresentationForTesting == .jobList)

        store.loadForTesting(
            serverState: .failed("Embedded server is unavailable in preview mode."),
            workspaces: []
        )
        try await waitForSidebarPresentation(viewController, .unavailable)
        #expect(viewController.sidebarAccessoryCountForTesting == 1)

        store.loadForTesting(
            serverState: .running,
            serverURL: URL(string: "http://localhost:9417/mcp"),
            workspaces: []
        )
        try await waitForSidebarPresentation(viewController, .jobList)
        #expect(viewController.sidebarAccessoryCountForTesting == 1)
    }

    @Test func splitViewInstallsToolbarWithSidebarTrackingSeparator() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(store: store)
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }

        #expect(window.toolbar != nil)
        #expect(harness.rootViewController.contentKindForTesting == .contentView)
        #expect(viewController.toolbarIdentifiersForTesting.contains(viewController.sidebarPickerToolbarItemIdentifierForTesting))
        #expect(viewController.toolbarIdentifiersForTesting.contains(.toggleSidebar) == false)
        #expect(viewController.toolbarIdentifiersForTesting.contains(.sidebarTrackingSeparator))
        #expect(
            viewController.sidebarPickerToolbarSegmentAccessibilityDescriptionsForTesting ==
                ["Workspace", "Account"]
        )
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .hidden)
        #expect(window.isOpaque)
        #expect(window.backgroundColor == .windowBackgroundColor)
        #expect(window.titlebarAppearsTransparent == false)
        #expect(window.isMovableByWindowBackground == false)
        #expect(viewController.sidebarAllowsFullHeightLayoutForTesting)
        #expect(viewController.sidebarCanCollapseFromWindowResizeForTesting == false)
        #expect(viewController.contentAutomaticallyAdjustsSafeAreaInsetsForTesting)
    }

    @Test func sidebarPickerToolbarItemSwitchesSidebarPresentation() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(store: store)
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let sidebarItem = try #require(viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false

        #expect(viewController.sidebarPresentationForTesting == .jobList)
        #expect(viewController.sidebarPickerToolbarSelectedSelectionForTesting == .workspace)

        viewController.selectSidebarPickerToolbarSegmentForTesting(.account)
        try await waitForSidebarPresentation(viewController, .accountList)

        #expect(sidebarItem.isCollapsed == false)
        #expect(viewController.sidebarPickerToolbarSelectedSelectionForTesting == .account)
    }

    @Test func sidebarPickerToolbarItemTogglesSidebarWhenCurrentSelectionIsClicked() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(store: store)
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let sidebarItem = try #require(viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false
        window.layoutIfNeeded()

        viewController.selectSidebarPickerToolbarSegmentForTesting(.workspace)
        window.layoutIfNeeded()

        #expect(sidebarItem.isCollapsed)

        viewController.selectSidebarPickerToolbarSegmentForTesting(.workspace)
        window.layoutIfNeeded()

        #expect(sidebarItem.isCollapsed == false)
        #expect(viewController.sidebarPickerToolbarSelectedSelectionForTesting == .workspace)
    }

    @Test func sidebarPickerToolbarItemOpensCollapsedSidebarWhenSwitchingSelection() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(store: store)
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let sidebarItem = try #require(viewController.splitViewItems.first)
        sidebarItem.isCollapsed = true
        window.layoutIfNeeded()

        viewController.selectSidebarPickerToolbarSegmentForTesting(.account)
        window.layoutIfNeeded()
        try await waitForSidebarPresentation(viewController, .accountList)

        #expect(sidebarItem.isCollapsed == false)
        #expect(viewController.sidebarPickerToolbarSelectedSelectionForTesting == .account)
    }

    @Test func sidebarPickerToolbarItemProvidesOverflowMenuActions() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(store: store)
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let sidebarItem = try #require(viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false

        #expect(viewController.sidebarPickerToolbarOverflowMenuItemTitlesForTesting == ["Workspace", "Account"])

        viewController.selectSidebarPickerToolbarOverflowMenuItemForTesting(.account)
        try await waitForSidebarPresentation(viewController, .accountList)

        #expect(sidebarItem.isCollapsed == false)
        #expect(viewController.sidebarPickerToolbarSelectedSelectionForTesting == .account)

        viewController.selectSidebarPickerToolbarOverflowMenuItemForTesting(.account)
        window.layoutIfNeeded()

        #expect(sidebarItem.isCollapsed)
    }

    @Test func sidebarPickerToolbarItemTracksExternalSelectionChanges() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }

        viewController.attach(to: window)
        #expect(viewController.sidebarPickerToolbarSelectedSelectionForTesting == .workspace)

        uiState.sidebarSelection = .account
        try await waitForCondition {
            viewController.sidebarPickerToolbarSelectedSelectionForTesting == .account
        }
    }

    @Test func splitViewShowsAddAccountToolbarItemOnlyForAccountSidebar() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))

        viewController.attach(to: window)
        let sidebarItem = try #require(viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false
        window.layoutIfNeeded()

        #expect(uiState.sidebarSelection == .workspace)

        uiState.sidebarSelection = .account
        try await waitForAddAccountToolbarItemHidden(viewController, false)
        #expect(viewController.addAccountToolbarItemIsHiddenForTesting == false)

        uiState.sidebarSelection = .workspace
        try await waitForAddAccountToolbarItemHidden(viewController, true)
        #expect(uiState.sidebarSelection == .workspace)
        #expect(viewController.addAccountToolbarItemIsHiddenForTesting)
    }

    @Test func splitViewHidesAddAccountToolbarItemWhileSidebarIsCollapsed() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))

        viewController.attach(to: window)
        let sidebarItem = try #require(viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false
        window.layoutIfNeeded()

        try await waitForAddAccountToolbarItemHidden(viewController, false)
        sidebarItem.isCollapsed = true
        try await waitForAddAccountToolbarItemHidden(viewController, true)
        #expect(viewController.addAccountToolbarItemIsHiddenForTesting)

        sidebarItem.isCollapsed = false
        try await waitForAddAccountToolbarItemHidden(viewController, false)
        #expect(viewController.addAccountToolbarItemIsHiddenForTesting == false)
    }

    @Test func previewContentViewControllerConfiguresAttachedWindowLikeSplitPresentation() {
        let viewController = makeReviewMonitorPreviewContentViewControllerForPreview()
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        window.layoutIfNeeded()

        #expect(window.toolbar != nil)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .visible)
        #expect(window.title.isEmpty == false)
        #expect(window.isOpaque)
        #expect(window.backgroundColor == .windowBackgroundColor)
        #expect(window.titlebarAppearsTransparent == false)
        #expect(window.titlebarSeparatorStyle == .automatic)
        #expect(window.isMovableByWindowBackground == false)
    }

    @Test func windowControllerUsesSeededAuthenticatedStateOnFirstPresentation() {
        let backend = AuthActionBackend(
            initialAuthState: .signedIn(accountID: "review@example.com")
        )
        let store = makeStore(backend: backend)
        let windowController = ReviewMonitorWindowController(store: store)
        guard let window = windowController.window else {
            Issue.record("ReviewMonitorWindowController did not create a window.")
            return
        }
        guard let rootViewController = window.contentViewController as? ReviewMonitorRootViewController else {
            Issue.record("ReviewMonitorWindowController did not install ReviewMonitorRootViewController.")
            return
        }
        defer { window.close() }

        #expect(rootViewController.contentKindForTesting == .contentView)
        #expect(window.toolbar != nil)
    }

    @Test func windowControllerUsesDefaultContentSizeWithoutSavedFrame() {
        let store = CodexReviewStore.makePreviewStore()
        let autosaveName = NSWindow.FrameAutosaveName(
            "ReviewMonitor.MainWindow.Tests.\(UUID().uuidString)"
        )
        let windowController = ReviewMonitorWindowController(
            store: store,
            contentTransitionAnimator: ReviewMonitorRootViewController.defaultContentTransitionAnimator,
            frameAutosaveName: autosaveName
        )
        guard let window = windowController.window else {
            Issue.record("ReviewMonitorWindowController did not create a window.")
            return
        }
        defer {
            window.close()
            NSWindow.removeFrame(usingName: autosaveName)
        }

        let contentSize = window.contentView?.bounds.size ?? .zero
        #expect(abs(contentSize.width - 600) < 0.5)
        #expect(abs(contentSize.height - 400) < 0.5)
    }

    @Test func windowControllerKeepsSplitViewForUnsavedCurrentSession() {
        let store = CodexReviewStore.makePreviewStore()
        let currentAccount = CodexAccount(email: "current@example.com", planType: "pro")
        store.loadForTesting(
            serverState: .running,
            authPhase: .signedOut,
            account: currentAccount,
            persistedAccounts: [],
            workspaces: []
        )
        let windowController = ReviewMonitorWindowController(store: store)
        guard let window = windowController.window else {
            Issue.record("ReviewMonitorWindowController did not create a window.")
            return
        }
        guard let rootViewController = window.contentViewController as? ReviewMonitorRootViewController else {
            Issue.record("ReviewMonitorWindowController did not install ReviewMonitorRootViewController.")
            return
        }
        defer { window.close() }

        #expect(rootViewController.contentKindForTesting == .contentView)
        #expect(window.toolbar != nil)
    }

    @Test func accountSidebarDisplaysUnsavedCurrentSession() {
        let store = CodexReviewStore.makePreviewStore()
        let currentAccount = CodexAccount(email: "current@example.com", planType: "pro")
        store.loadForTesting(
            serverState: .running,
            authPhase: .signedOut,
            account: currentAccount,
            persistedAccounts: [],
            workspaces: []
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)

        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarPresentationForTesting == .accountList)
        #expect(
            viewController
                .sidebarViewControllerForTesting
                .accountsViewControllerForTesting
                .displayedAccountEmailsForTesting == ["current@example.com"]
        )
        #expect(store.auth.persistedAccounts.isEmpty)
    }

    @Test func windowControllerShowsSignInViewWhenSignedOut() {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(
            store: store,
            authState: .signedOut
        )
        let window = harness.window
        defer { window.close() }

        #expect(harness.rootViewController.contentKindForTesting == .signInView)
        #expect(window.toolbar == nil)
        #expect(window.titleVisibility == .hidden)
        #expect(window.isMovableByWindowBackground)
    }

    @Test func windowControllerShowsSplitViewWhenSignedOutWithPersistedAccounts() {
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            authPhase: .signedOut,
            account: nil,
            persistedAccounts: [CodexAccount(email: "saved@example.com", planType: "pro")],
            workspaces: []
        )
        let windowController = ReviewMonitorWindowController(store: store)
        guard let window = windowController.window else {
            Issue.record("ReviewMonitorWindowController did not create a window.")
            return
        }
        guard let rootViewController = window.contentViewController as? ReviewMonitorRootViewController else {
            Issue.record("ReviewMonitorWindowController did not install ReviewMonitorRootViewController.")
            return
        }
        defer { window.close() }

        #expect(rootViewController.contentKindForTesting == .contentView)
        #expect(rootViewController.isSplitViewEmbeddedForTesting)
        #expect(rootViewController.isSignInViewEmbeddedForTesting == false)
        #expect(window.toolbar != nil)
        #expect(window.titleVisibility == .hidden)
        #expect(window.isMovableByWindowBackground == false)
    }

    @Test func windowControllerDoesNotRefreshAuthStateBeforeStoreStart() async {
        let backend = AuthActionBackend()
        let store = makeStore(backend: backend)
        let windowController = ReviewMonitorWindowController(store: store)
        defer { windowController.window?.close() }
        await Task.yield()

        #expect(backend.refreshAuthStateCallCount() == 0)
    }

    @Test func windowControllerSwitchesToSignInViewAfterLogout() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(
            store: store,
            authState: .signedIn(accountID: "review@example.com")
        )
        let window = harness.window
        defer { window.close() }

        applyTestAuthState(auth: store.auth, state: .signedOut)
        try await waitForWindowContentKind(harness.rootViewController, .signInView)
        try await waitForEmbeddedContentSubviewCount(harness.rootViewController, 1)

        #expect(harness.rootViewController.embeddedContentSubviewCountForTesting == 1)
        #expect(window.toolbar == nil)
        #expect(window.titleVisibility == .hidden)
        #expect(window.isMovableByWindowBackground)
    }

    @Test func windowControllerCrossfadesBackToSplitViewAfterAuthentication() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(
            store: store,
            authState: .signedOut
        )
        let window = harness.window
        defer { window.close() }

        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))
        try await waitForWindowContentKind(harness.rootViewController, .contentView)
        try await waitForEmbeddedContentSubviewCount(harness.rootViewController, 1)

        #expect(harness.rootViewController.embeddedContentSubviewCountForTesting == 1)
        #expect(window.toolbar != nil)
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarSeparatorStyle == .automatic)
        #expect(window.isMovableByWindowBackground == false)
    }

    @Test func windowControllerRapidAuthFlipsKeepLatestContentEmbedded() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let animator = ManualContentTransitionAnimator()
        let harness = makeWindowHarness(
            store: store,
            authState: .signedIn(accountID: "review@example.com"),
            contentTransitionAnimator: animator.animate
        )
        let window = harness.window
        defer { window.close() }

        applyTestAuthState(auth: store.auth, state: .signedOut)
        try await animator.waitForAnimationCount(1)
        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))
        try await animator.waitForAnimationCount(2)
        animator.completeAll()
        try await waitForEmbeddedContentSubviewCount(harness.rootViewController, 1)

        #expect(harness.rootViewController.embeddedContentSubviewCountForTesting == 1)
        #expect(harness.rootViewController.isSplitViewEmbeddedForTesting)
        #expect(harness.rootViewController.isSignInViewEmbeddedForTesting == false)
        #expect(window.toolbar != nil)
    }

    @Test func windowControllerRapidAuthFlipsDoNotAccumulateEmbeddedConstraints() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let animator = ManualContentTransitionAnimator()
        let harness = makeWindowHarness(
            store: store,
            authState: .signedIn(accountID: "review@example.com"),
            contentTransitionAnimator: animator.animate
        )
        defer { harness.window.close() }

        applyTestAuthState(auth: store.auth, state: .signedOut)
        try await animator.waitForAnimationCount(1)
        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))
        try await animator.waitForAnimationCount(2)
        applyTestAuthState(auth: store.auth, state: .signedOut)
        try await animator.waitForAnimationCount(3)
        applyTestAuthState(auth: store.auth, state: .signedIn(accountID: "review@example.com"))
        try await animator.waitForAnimationCount(4)
        animator.completeAll()
        try await waitForEmbeddedContentSubviewCount(harness.rootViewController, 1)

        #expect(harness.rootViewController.embeddedContentSubviewCountForTesting == 1)
        #expect(harness.rootViewController.isSplitViewEmbeddedForTesting)
    }

    @Test func windowControllerPreservesWindowSizeWhenSwitchingToSignInView() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(
            store: store,
            authState: .signedIn(accountID: "review@example.com")
        )
        let window = harness.window
        defer { window.close() }

        window.setContentSize(NSSize(width: 1080, height: 720))
        window.layoutIfNeeded()
        let beforeSize = window.frame.size

        applyTestAuthState(auth: store.auth, state: .signedOut)
        try await waitForWindowContentKind(harness.rootViewController, .signInView)
        window.layoutIfNeeded()
        let afterSize = window.frame.size

        #expect(abs(beforeSize.width - afterSize.width) < 0.5)
        #expect(abs(beforeSize.height - afterSize.height) < 0.5)
    }

    @Test func windowControllerKeepsSplitViewAfterAuthFailureWhenSessionExists() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(
            store: store,
            authState: .signedIn(accountID: "review@example.com")
        )
        let window = harness.window
        defer { window.close() }

        applyTestAuthState(
            auth: store.auth,
            state: .failed(
                "Authentication failed.",
                isAuthenticated: true,
                accountID: "review@example.com"
            )
        )
        try await waitForWindowContentKind(harness.rootViewController, .contentView)

        #expect(harness.rootViewController.contentKindForTesting == .contentView)
        #expect(window.toolbar != nil)
    }

    @Test func windowControllerKeepsSplitViewPresentedWhileAuthenticatingWithSession() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(
            store: store,
            authState: .signedOut
        )
        defer { harness.window.close() }

        applyTestAuthState(
            auth: store.auth,
            state: .init(
                isAuthenticated: true,
                accountID: "review@example.com",
                progress: .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue.",
                    browserURL: "https://auth.openai.com/oauth/authorize?foo=bar"
                )
            )
        )
        try await waitForWindowContentKind(harness.rootViewController, .contentView)

        #expect(harness.rootViewController.contentKindForTesting == .contentView)
    }

    @Test func windowControllerKeepsSplitViewWhileAuthenticatedRetryAuthenticates() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(
            store: store,
            authState: .signedIn(accountID: "review@example.com")
        )
        defer { harness.window.close() }

        applyTestAuthState(auth: store.auth, state: 
            .failed(
                "Authentication failed.",
                isAuthenticated: true,
                accountID: "review@example.com"
            )
        )
        await Task.yield()

        applyTestAuthState(
            auth: store.auth,
            state: .init(
                isAuthenticated: true,
                accountID: "review@example.com",
                progress: .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue.",
                    browserURL: "https://auth.openai.com/oauth/authorize?foo=bar"
                )
            )
        )
        try await waitForWindowContentKind(harness.rootViewController, .contentView)
        try await waitForEmbeddedContentSubviewCount(harness.rootViewController, 1)

        #expect(harness.rootViewController.contentKindForTesting == .contentView)
        #expect(harness.rootViewController.isSignInViewEmbeddedForTesting == false)
        #expect(harness.rootViewController.isSplitViewEmbeddedForTesting)
    }

    @Test func detailLogViewExtendsBehindTitlebarWithoutOverlappingSidebar() async throws {
        let job = makeJob(
            id: "job-safe-area",
            status: .running,
            targetSummary: "Uncommitted changes",
            logText: "Safe area log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 900, height: 600)
        )
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)
        transport.view.layoutSubtreeIfNeeded()

        let logFrame = transport.logFrameForTesting
        let viewBounds = transport.viewBoundsForTesting
        let safeAreaFrame = transport.safeAreaFrameForTesting
        let contentInsets = transport.logContentInsetsForTesting

        #expect(abs(logFrame.minX - safeAreaFrame.minX) < 0.5)
        #expect(abs(logFrame.maxX - safeAreaFrame.maxX) < 0.5)
        #expect(abs(logFrame.minY - safeAreaFrame.minY) < 0.5)
        #expect(abs(logFrame.maxY - viewBounds.maxY) < 0.5)
        #expect(safeAreaFrame.maxY < viewBounds.maxY)
        #expect(transport.logAutomaticallyAdjustsContentInsetsForTesting)
        #expect(contentInsets.top > 0)
        #expect(abs(transport.logVerticalScrollOffsetForTesting + contentInsets.top) < 0.5)
        #expect(abs(
            transport.logMaximumVerticalScrollOffsetForTesting
                - transport.logMinimumVerticalScrollOffsetForTesting
        ) < 0.5)
    }

    @Test func shortDetailLogKeepsTextContentWithinDocumentBounds() async throws {
        let job = makeJob(
            id: "job-short-log-layout",
            status: .running,
            targetSummary: "Uncommitted changes",
            logText: "Short log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 900, height: 600)
        )
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)
        transport.view.layoutSubtreeIfNeeded()

        let textContentFrame = transport.logTextContentFrameForTesting
        let documentViewFrame = transport.logDocumentViewFrameForTesting

        #expect(abs(textContentFrame.minY) < 0.5)
        #expect(textContentFrame.maxY <= documentViewFrame.maxY + 0.5)
        #expect(textContentFrame.height <= documentViewFrame.height + 0.5)
        expectLogTextContainerWidthTracksContentView(transport)
    }

    @Test func detailLogExpandsAfterSidebarReopensFromCompactWidth() async throws {
        let job = makeJob(
            id: "job-sidebar-width-regression",
            status: .running,
            targetSummary: "Uncommitted changes",
            logText: Array(repeating: "Long line that should reflow across the widened detail pane.\n", count: 40).joined()
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 520, height: 420)
        )
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        try await waitForWindowContentKind(harness.rootViewController, .contentView)
        let transport = viewController.transportViewControllerForTesting
        let sidebarItem = try #require(viewController.splitViewItems.first)

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        window.setContentSize(NSSize(width: 360, height: 420))
        sidebarItem.isCollapsed = true
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        let compactDocumentWidth = transport.logDocumentViewFrameForTesting.width
        expectLogTextContainerWidthTracksContentView(transport)

        sidebarItem.isCollapsed = false
        window.setContentSize(NSSize(width: 960, height: 600))
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        await transport.flushMainQueueForTesting()

        let expandedDocumentWidth = transport.logDocumentViewFrameForTesting.width
        let expandedLogWidth = transport.logFrameForTesting.width
        let expandedTextWidth = transport.logTextContentFrameForTesting.width

        #expect(expandedDocumentWidth > compactDocumentWidth + 200)
        #expect(abs(expandedDocumentWidth - expandedLogWidth) < 32)
        #expect(abs(expandedTextWidth - expandedLogWidth) < 32)
        expectLogTextContainerWidthTracksContentView(transport)
    }

    @Test func detailLogShrinksAfterSidebarReopensIntoNarrowWidth() async throws {
        let job = makeJob(
            id: "job-sidebar-width-shrink-regression",
            status: .running,
            targetSummary: "Uncommitted changes",
            logText: Array(repeating: "Long line that should reflow when the detail pane narrows.\n", count: 40).joined()
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 960, height: 600)
        )
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        try await waitForWindowContentKind(harness.rootViewController, .contentView)
        let transport = viewController.transportViewControllerForTesting
        let sidebarItem = try #require(viewController.splitViewItems.first)

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)
        window.layoutIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        let expandedDocumentWidth = transport.logDocumentViewFrameForTesting.width
        expectLogTextContainerWidthTracksContentView(transport)

        sidebarItem.isCollapsed = true
        window.setContentSize(NSSize(width: 360, height: 420))
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        await transport.flushMainQueueForTesting()

        let compactDocumentWidth = transport.logDocumentViewFrameForTesting.width
        let compactLogWidth = transport.logFrameForTesting.width
        let compactTextWidth = transport.logTextContentFrameForTesting.width

        #expect(compactDocumentWidth < expandedDocumentWidth - 200)
        #expect(abs(compactDocumentWidth - compactLogWidth) < 32)
        #expect(abs(compactTextWidth - compactLogWidth) < 32)
        expectLogTextContainerWidthTracksContentView(transport)
    }

    @Test func detailLogTracksSimpleWindowResizeInBothDirections() async throws {
        let job = makeJob(
            id: "job-window-resize-width-regression",
            status: .running,
            targetSummary: "Uncommitted changes",
            logText: Array(repeating: "Long line that should reflow as the window resizes.\n", count: 40).joined()
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 960, height: 600)
        )
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)
        window.layoutIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        let wideWidth = transport.logDocumentViewFrameForTesting.width
        expectLogTextContainerWidthTracksContentView(transport)

        window.setContentSize(NSSize(width: 520, height: 420))
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        await transport.flushMainQueueForTesting()
        let narrowWidth = transport.logDocumentViewFrameForTesting.width
        let narrowTextWidth = transport.logTextContentFrameForTesting.width
        let narrowLogWidth = transport.logFrameForTesting.width
        expectLogTextContainerWidthTracksContentView(transport)

        window.setContentSize(NSSize(width: 900, height: 600))
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        await transport.flushMainQueueForTesting()
        let widenedAgainWidth = transport.logDocumentViewFrameForTesting.width
        let widenedAgainTextWidth = transport.logTextContentFrameForTesting.width
        let widenedAgainLogWidth = transport.logFrameForTesting.width

        #expect(narrowWidth < wideWidth - 150)
        #expect(widenedAgainWidth > narrowWidth + 150)
        #expect(abs(narrowWidth - narrowLogWidth) < 32)
        #expect(abs(narrowTextWidth - narrowLogWidth) < 32)
        #expect(abs(widenedAgainWidth - widenedAgainLogWidth) < 32)
        #expect(abs(widenedAgainTextWidth - widenedAgainLogWidth) < 32)
        expectLogTextContainerWidthTracksContentView(transport)
    }

    @Test func detailLogRewrapsVisibleTextDuringLiveWindowResize() async throws {
        let job = makeJob(
            id: "job-window-live-resize-log",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: String(repeating: "wrap-sensitive text ", count: 600)
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 960, height: 600)
        )
        let viewController = harness.viewController
        let window = harness.window
        let transport = viewController.transportViewControllerForTesting
        var liveResizeActive = false
        defer {
            if liveResizeActive {
                transport.endLogLiveResizeForTesting()
            }
            window.close()
        }

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)
        window.layoutIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        let wideWidth = transport.logDocumentViewFrameForTesting.width
        let wideDocumentHeight = transport.logDocumentViewFrameForTesting.height
        let wideFragmentHeight = transport.logVisibleFragmentBoundsForTesting.height
        #expect(transport.isLogPinnedToBottomForTesting)

        transport.beginLogLiveResizeForTesting()
        liveResizeActive = true
        window.setContentSize(NSSize(width: 520, height: 420))
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        await transport.flushMainQueueForTesting()

        let narrowWidth = transport.logDocumentViewFrameForTesting.width
        let narrowDocumentHeight = transport.logDocumentViewFrameForTesting.height
        let narrowFragmentHeight = transport.logVisibleFragmentBoundsForTesting.height
        transport.endLogLiveResizeForTesting()
        liveResizeActive = false

        #expect(narrowWidth < wideWidth - 150)
        #expect(narrowDocumentHeight > wideDocumentHeight + 20)
        #expect(narrowDocumentHeight >= narrowFragmentHeight - 0.5)
        #expect(narrowFragmentHeight > wideFragmentHeight + 20)
        #expect(transport.logVisibleFragmentViewCountForTesting > 0)
        #expect(transport.logStaleFragmentViewCountForTesting == 0)
        #expect(transport.isLogPinnedToBottomForTesting)
    }

    @Test func detailLogKeepsBottomFilledForMultilineStreamDuringLiveWindowResize() async throws {
        let streamLog = (0..<80)
            .map { index in
                "stream.tick \(String(format: "%03d", index)) delta/render +5 -3 after resizing the split view, avoiding sidebar auto-collapse, and keeping visible TextKit 2 fragments fresh"
            }
            .joined(separator: "\n\n")
        let job = makeJob(
            id: "job-window-live-resize-stream-log",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: streamLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 1_060, height: 600)
        )
        let viewController = harness.viewController
        let window = harness.window
        let transport = viewController.transportViewControllerForTesting
        var liveResizeActive = false
        defer {
            if liveResizeActive {
                transport.endLogLiveResizeForTesting()
            }
            window.close()
        }

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)
        window.layoutIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        #expect(transport.isLogPinnedToBottomForTesting)

        transport.beginLogLiveResizeForTesting()
        liveResizeActive = true
        window.setContentSize(NSSize(width: 620, height: 600))
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        await transport.flushMainQueueForTesting()

        let visibleFragmentBounds = transport.logVisibleFragmentBoundsForTesting
        let visibleBottomInViewport = visibleFragmentBounds.maxY - transport.logVerticalScrollOffsetForTesting
        let bottomGap = transport.logViewportHeightForTesting - visibleBottomInViewport

        #expect(abs(bottomGap) < 120)
        #expect(transport.isLogPinnedToBottomForTesting)
        #expect(transport.logStaleFragmentViewCountForTesting == 0)
    }

    @Test func detailLogTextContainerExpandsAfterToolbarSidebarToggleAtCompactWidth() async throws {
        let job = makeJob(
            id: "job-toolbar-sidebar-toggle-textkit-width-regression",
            status: .running,
            targetSummary: "Uncommitted changes",
            logText: Array(repeating: "Long line that should reflow after the toolbar sidebar toggle path.\n", count: 40).joined()
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 520, height: 420)
        )
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        try await waitForWindowContentKind(harness.rootViewController, .contentView)
        let transport = viewController.transportViewControllerForTesting
        let sidebarItem = try #require(viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        await transport.flushMainQueueForTesting()

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        viewController.toggleSidebar(nil)
        window.setContentSize(NSSize(width: 360, height: 420))
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        await transport.flushMainQueueForTesting()
        #expect(sidebarItem.isCollapsed)

        viewController.toggleSidebar(nil)
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        await transport.flushMainQueueForTesting()
        let compactDocumentWidth = transport.logDocumentViewFrameForTesting.width
        expectLogTextContainerWidthTracksContentView(transport)

        window.setContentSize(NSSize(width: 960, height: 600))
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        await transport.flushMainQueueForTesting()

        let expandedDocumentWidth = transport.logDocumentViewFrameForTesting.width
        let expandedLogWidth = transport.logFrameForTesting.width
        let expandedTextWidth = transport.logTextContentFrameForTesting.width

        #expect(sidebarItem.isCollapsed == false)
        #expect(expandedDocumentWidth > compactDocumentWidth + 200)
        #expect(abs(expandedDocumentWidth - expandedLogWidth) < 32)
        #expect(abs(expandedTextWidth - expandedLogWidth) < 32)
        expectLogTextContainerWidthTracksContentView(transport)
    }

    @Test func windowControllerDoesNotStartStoreWhenConstructed() {
        let backend = CountingStartBackend()
        let store = makeStore(backend: backend)
        let harness = makeWindowHarness(store: store)
        let window = harness.window
        defer { window.close() }

        #expect(backend.startCallCount() == 0)
    }

    @Test func splitViewAttachIsIdempotentForSameWindow() {
        let backend = CountingStartBackend()
        let store = makeStore(backend: backend)
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }

        viewController.attach(to: window)
        let initialToolbar = window.toolbar
        let initialIdentifiers = viewController.toolbarIdentifiersForTesting
        viewController.attach(to: window)

        #expect(window.toolbar === initialToolbar)
        #expect(viewController.toolbarIdentifiersForTesting == initialIdentifiers)
        #expect(backend.startCallCount() == 0)
    }

    @Test func previewRunningJobsAppendPseudoStreamWhenTicked() throws {
        let store = ReviewMonitorPreviewContent.makeStore(
            streamInterval: .seconds(60)
        )
        let runningJob = try #require(
            store.orderedJobs.first(where: { $0.core.lifecycle.status == .running })
        )
        let initialRevision = runningJob.reviewMonitorRevision
        let initialLog = runningJob.reviewMonitorLogDocument.text

        ReviewMonitorPreviewContent.appendPreviewStreamTick(to: store)

        let appendedText = String(runningJob.reviewMonitorLogDocument.text.dropFirst(initialLog.count))
        #expect(runningJob.reviewMonitorRevision > initialRevision)
        #expect(runningJob.reviewMonitorLogDocument.text != initialLog)
        #expect(appendedText.contains("stream.tick"))
        #expect(appendedText.contains("delta/") == false)
        #expect(appendedText.count < 32)
        let expectedAppendText = "\n\nstream.tick "
        #expect(runningJob.reviewMonitorLogDocument.lastChange == .append(.init(
            kind: .agentMessage,
            blockID: ReviewMonitorLogBlockID("agentMessage:preview-stream-\(runningJob.id)"),
            range: NSRange(
                location: (runningJob.reviewMonitorLogDocument.text as NSString).length - ("stream.tick " as NSString).length,
                length: ("stream.tick " as NSString).length
            ),
            text: expectedAppendText
        )))
    }

    @Test func previewFirstWorkspaceShowsStructuredFindingsWhenSelected() async throws {
        let store = ReviewMonitorPreviewContent.makeStore(
            streamInterval: .seconds(60)
        )
        let firstWorkspace = try #require(store.workspaces.sorted { $0.cwd < $1.cwd }.first)
        let harness = makeWindowHarness(store: store)
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectWorkspaceForTesting(firstWorkspace)

        _ = try await awaitTransportRender(transport, after: initialRenderCount)
        let accessibilityValue = try #require(transport.workspaceFindingsAccessibilityValueForTesting)
        #expect(transport.workspaceFindingSnapshotForTesting.isShowingFindingsList)
        #expect(transport.workspaceFindingSnapshotForTesting.isShowingNoFindingsState == false)
        #expect(accessibilityValue.isEmpty == false)
    }
}
