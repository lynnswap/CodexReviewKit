import AppKit
import CodexAppServerKitTesting
import CodexKit
import Foundation
import ObservationBridge
import SwiftUI
import Testing
@_spi(Testing) @testable import CodexReviewKit
@testable import ReviewUI
import ReviewUIPreviewSupport
import CodexReviewTesting

@MainActor
extension ReviewUITests {
    @Test func rootViewControllerLoadsContentDuringViewLifecycle() {
        let rootViewController = makeReviewMonitorPreviewContentViewControllerForPreview()

        #expect(rootViewController.isViewLoaded == false)

        rootViewController.loadViewIfNeeded()

        #expect(rootViewController.isViewLoaded)
        #expect(rootViewController.isSplitViewEmbeddedForTesting)
    }

    @Test func previewPreparationLoadsSelectedChatStreamBeforeWindowAttachment() async throws {
        let previewContent = ReviewMonitorPreviewContent.makeContentSource()
        let store = previewContent.store
        let selectedChatID = try #require(previewSelectedChatID(in: store))
        let viewController = makeReviewMonitorPreviewContentViewControllerForPreview(
            previewContent: previewContent
        )

        #expect(viewController.isViewLoaded == false)

        viewController.prepareForSwiftUIPreviewRendering()

        #expect(viewController.isViewLoaded)
        #expect(viewController.isSplitViewEmbeddedForTesting)
        #expect(viewController.splitViewControllerForTesting.isTransportViewLoadedForTesting)

        let transport = viewController.splitViewControllerForTesting.transportViewControllerForTesting
        let snapshot = try await awaitTransportRender(transport) { snapshot in
            snapshot.log.isEmpty == false && snapshot.isShowingEmptyState == false
        }

        #expect(transport.renderedStateForTesting.selection == .chat(selectedChatID.rawValue))
        #expect(snapshot.log.isEmpty == false)
    }

    @Test func previewContentViewControllerRendersSidebarFromFakeAppServer() async throws {
        let viewController = makeReviewMonitorPreviewContentViewControllerForPreview()

        viewController.prepareForSwiftUIPreviewRendering()

        let sidebar = viewController.splitViewControllerForTesting.sidebarViewControllerForTesting
        try await waitForCondition {
            sidebar.sidebarKindForTesting == .chatList
                && sidebar.displayedCodexSidebarTitlesForTesting.contains("workspace-alpha")
                && sidebar.displayedCodexSidebarTitlesForTesting.contains("Branch: feature/workspace-alpha-sidebar")
        }

        #expect(sidebar.isShowingEmptyStateForTesting == false)
        #expect(sidebar.sidebarKindForTesting == .chatList)
    }

    @Test func previewChatContextMenuCancelCancelsMatchingReviewRun() async throws {
        let previewContent = ReviewMonitorPreviewContent.makeContentSource()
        let store = previewContent.store
        let selectedChatID = try #require(previewSelectedChatID(in: store))
        let run = try #require(store.cancellableReviewRun(forChatID: selectedChatID.rawValue))
        let viewController = makeReviewMonitorPreviewContentViewControllerForPreview(
            previewContent: previewContent
        )
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let sidebar = viewController.splitViewControllerForTesting.sidebarViewControllerForTesting
        try await waitForCondition {
            sidebar.sidebarKindForTesting == .chatList
                && sidebar.displayedCodexSidebarTitlesForTesting.contains("Branch: feature/workspace-alpha-sidebar")
        }

        var presentedCancelItem = false
        var cancelItemWasEnabled = false
        sidebar.presentContextMenuForTesting(chatID: selectedChatID) { menu in
            guard let cancelIndex = menu.items.firstIndex(where: { $0.title == "Cancel" }) else {
                return
            }
            presentedCancelItem = true
            cancelItemWasEnabled = menu.items[cancelIndex].isEnabled
            menu.performActionForItem(at: cancelIndex)
        }

        #expect(presentedCancelItem)
        #expect(cancelItemWasEnabled)
        try await waitForCondition {
            store.reviewRun(id: run.id)?.core.lifecycle.status == .cancelled
        }
        #expect(store.reviewRun(id: run.id)?.core.lifecycle.cancellation?.source == .userInterface)
        #expect(store.hasCancellableReview(forChatID: selectedChatID.rawValue) == false)

        var cancelItemEnabledAfterCancellation = false
        sidebar.presentContextMenuForTesting(chatID: selectedChatID) { menu in
            guard let cancelItem = menu.items.first(where: { $0.title == "Cancel" }) else {
                return
            }
            cancelItemEnabledAfterCancellation = cancelItem.isEnabled
        }
        #expect(cancelItemEnabledAfterCancellation)
    }

    @Test func activeChatContextMenuCancelFallsBackWhenMatchingReviewRunIsTerminal() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeShellTestGitRepository()
        let chatID = CodexThreadID(rawValue: "active-chat-with-terminal-run")
        let turnID = CodexTurnID(rawValue: "active-turn")

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [
                    .init(
                        id: chatID,
                        workspace: repo,
                        name: "Active chat",
                        updatedAt: Date(timeIntervalSince1970: 5_000),
                        status: .active(activeFlags: []),
                        turns: [
                            .init(id: turnID, status: .running)
                        ]
                    )
                ]
            ))
        try await runtime.transport.enqueueThreadResume(
            .init(
                id: chatID,
                status: .active(activeFlags: []),
                turns: [
                    .init(id: turnID, status: .running)
                ]
            ))
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")

        let terminalRun = ReviewRunRecord.makeForTesting(
            id: "terminal-run",
            cwd: repo.path,
            targetSummary: "Terminal review run",
            threadID: chatID.rawValue,
            turnID: "terminal-turn",
            status: .succeeded,
            startedAt: Date(timeIntervalSince1970: 4_000),
            endedAt: Date(timeIntervalSince1970: 4_100),
            summary: "Completed review."
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadReviewCancellationStateForTesting(
            serverState: .running,
            reviewRuns: [terminalRun]
        )
        let viewController = ReviewMonitorSplitViewController(
            store: store,
            uiState: ReviewMonitorUIState(auth: store.auth),
            modelContext: context
        )
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        try await waitForCondition {
            sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(chatID)) == "Active chat"
        }

        #expect(store.hasReviewRun(forChatID: chatID.rawValue))
        #expect(store.hasCancellableReview(forChatID: chatID.rawValue) == false)

        var presentedCancelItem = false
        var cancelItemWasEnabled = false
        sidebar.presentContextMenuForTesting(chatID: chatID) { menu in
            guard let cancelIndex = menu.items.firstIndex(where: { $0.title == "Cancel" }) else {
                return
            }
            presentedCancelItem = true
            cancelItemWasEnabled = menu.items[cancelIndex].isEnabled
            menu.performActionForItem(at: cancelIndex)
        }

        #expect(presentedCancelItem)
        #expect(cancelItemWasEnabled)
        await runtime.transport.waitForRequest(method: "turn/interrupt")
        let interruptRequestCount = await runtime.transport.recordedRequests(method: "turn/interrupt").count
        #expect(interruptRequestCount == 1)
    }

    @Test func activeChatContextMenuCancelDoesNotBypassPendingReviewCancellation() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeShellTestGitRepository()
        let chatID = CodexThreadID(rawValue: "active-chat-with-pending-run-cancel")
        let turnID = CodexTurnID(rawValue: "pending-turn")

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [
                    .init(
                        id: chatID,
                        workspace: repo,
                        name: "Pending cancellation chat",
                        updatedAt: Date(timeIntervalSince1970: 5_000),
                        status: .active(activeFlags: []),
                        turns: [
                            .init(id: turnID, status: .running)
                        ]
                    )
                ]
            ))
        try await runtime.transport.enqueueThreadResume(
            .init(
                id: chatID,
                status: .active(activeFlags: []),
                turns: [
                    .init(id: turnID, status: .running)
                ]
            ))
        try await runtime.transport.enqueueEmpty(for: "turn/interrupt")

        let terminalRun = ReviewRunRecord.makeForTesting(
            id: "a-terminal-run",
            cwd: repo.path,
            targetSummary: "Terminal review run",
            threadID: chatID.rawValue,
            turnID: "terminal-review-turn",
            status: .succeeded,
            startedAt: Date(timeIntervalSince1970: 4_100),
            endedAt: Date(timeIntervalSince1970: 4_200),
            summary: "Completed review."
        )
        let pendingRun = ReviewRunRecord.makeForTesting(
            id: "z-pending-cancellation-run",
            cwd: repo.path,
            targetSummary: "Pending cancellation review run",
            threadID: chatID.rawValue,
            turnID: "pending-review-turn",
            status: .running,
            cancellationRequested: true,
            startedAt: Date(timeIntervalSince1970: 4_000),
            summary: "Cancellation requested."
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadReviewCancellationStateForTesting(
            serverState: .running,
            reviewRuns: [terminalRun, pendingRun]
        )
        let viewController = ReviewMonitorSplitViewController(
            store: store,
            uiState: ReviewMonitorUIState(auth: store.auth),
            modelContext: context
        )
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        try await waitForCondition {
            sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(chatID)) == "Pending cancellation chat"
        }

        #expect(store.hasReviewRun(forChatID: chatID.rawValue))
        #expect(store.hasCancellableReview(forChatID: chatID.rawValue) == false)

        var cancelItemWasEnabled = false
        sidebar.presentContextMenuForTesting(chatID: chatID) { menu in
            guard let cancelIndex = menu.items.firstIndex(where: { $0.title == "Cancel" }) else {
                return
            }
            cancelItemWasEnabled = menu.items[cancelIndex].isEnabled
            menu.performActionForItem(at: cancelIndex)
        }

        #expect(cancelItemWasEnabled)
        try await Task.sleep(for: .milliseconds(100))
        let resumeRequestCount = await runtime.transport.recordedRequests(method: "thread/resume").count
        let interruptRequestCount = await runtime.transport.recordedRequests(method: "turn/interrupt").count
        #expect(resumeRequestCount == 0)
        #expect(interruptRequestCount == 0)
    }

    @Test func previewContentViewControllerRendersSelectedChatLogDuringViewLifecycle() async throws {
        let previewContent = ReviewMonitorPreviewContent.makeContentSource()
        let store = previewContent.store
        let selectedChatID = try #require(previewSelectedChatID(in: store))
        let selectedSnapshot = try #require(await previewContent.snapshotForTesting(chatID: selectedChatID))
        let expectedLogText = try #require(selectedSnapshot.items.compactMap { $0.text }.first)
        let viewController = makeReviewMonitorPreviewContentViewControllerForPreview(
            previewContent: previewContent
        )

        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let transport = viewController.splitViewControllerForTesting.transportViewControllerForTesting
        let snapshot = try await awaitTransportRender(transport) { snapshot in
            snapshot.log.contains(expectedLogText) && snapshot.isShowingEmptyState == false
        }

        #expect(transport.renderedStateForTesting.selection == .chat(selectedChatID.rawValue))
        #expect(snapshot.log.isEmpty == false)
    }

    @Test func previewContentViewControllerStreamsSelectedChatLogDuringViewLifecycle() async throws {
        let previewContent = ReviewMonitorPreviewContent.makeContentSource()
        let viewController = makeReviewMonitorPreviewContentViewControllerForPreview(
            previewContent: previewContent
        )

        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let transport = viewController.splitViewControllerForTesting.transportViewControllerForTesting
        let initialSnapshot = try await awaitTransportRender(transport) { snapshot in
            snapshot.log.isEmpty == false && snapshot.isShowingEmptyState == false
        }

        let nextTick = try #require(await viewController.appendPreviewChatLogStreamTickForTesting())
        #expect(nextTick == 1)
        let updatedSnapshot = try await awaitTransportRender(transport) { snapshot in
            snapshot.log.count > initialSnapshot.log.count
                && snapshot.log.contains("Turn started")
                && snapshot.isShowingEmptyState == false
        }

        #expect(updatedSnapshot.log.contains("Turn started"))
    }

    @Test func bindingStoreAppliesInitialState() {
        let store = CodexReviewStore.makePreviewStore()
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarTopAccessoryCountForTesting == 0)
        #expect(viewController.sidebarAccessoryCountForTesting == 1)
        #expect(viewController.contentAccessoryCountForTesting == 0)
        #expect(viewController.sidebarPresentationForTesting == .unavailable)
        #expect(viewController.contentPaneViewControllerForTesting.isShowingEmptyStateForTesting)
    }

    @Test func splitViewShowsEmptyStateWithoutChats() {
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            serverURL: URL(string: "http://localhost:9417/mcp")
        )
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
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
            serverState: .failed("Embedded server is unavailable in preview mode.")
        )
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        #expect(viewController.splitViewItems.count == 2)
        #expect(viewController.sidebarPresentationForTesting == .unavailable)
        #expect(viewController.sidebarTopAccessoryCountForTesting == 0)
        #expect(viewController.sidebarAccessoryCountForTesting == 1)
    }

    @Test func splitViewShowsUnavailableSidebarWhenServerStartingOnLoad() {
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .starting
        )
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarPresentationForTesting == .unavailable)
    }

    @Test func splitViewShowsUnavailableSidebarWhenServerStoppedOnLoad() {
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .stopped
        )
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarPresentationForTesting == .unavailable)
    }

    @Test func splitViewShowsReviewChatSidebarWhenServerRunningOnLoad() {
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            serverURL: URL(string: "http://localhost:9417/mcp")
        )
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarPresentationForTesting == .chatList)
        #expect(viewController.sidebarTopAccessoryCountForTesting == 0)
        #expect(viewController.sidebarAccessoryCountForTesting == 1)
    }

    @Test func splitViewSwitchesSidebarPresentationWhenPickerSelectionChanges() async throws {
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            serverURL: URL(string: "http://localhost:9417/mcp")
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let viewController = makeReviewMonitorSplitViewControllerForTesting(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarPresentationForTesting == .chatList)
        #expect(viewController.sidebarBottomAccessoryIsHiddenForTesting == false)

        uiState.sidebarSelection = .account
        try await waitForSidebarBottomAccessoryHidden(viewController, true)
        #expect(viewController.sidebarPresentationForTesting == .accountList)

        uiState.sidebarSelection = .workspace
        try await waitForSidebarBottomAccessoryHidden(viewController, false)
        #expect(viewController.sidebarPresentationForTesting == .chatList)
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
            serverState: .failed("Embedded server is unavailable in preview mode.")
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
        let store = ReviewMonitorPreviewContent.makeStore()
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
            serverURL: URL(string: "http://localhost:9417/mcp")
        )
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarPresentationForTesting == .chatList)

        store.loadForTesting(
            serverState: .failed("Embedded server is unavailable in preview mode.")
        )
        try await waitForSidebarPresentation(
            viewController,
            .unavailable,
            observation: viewController.sidebarViewControllerForTesting.sidebarKindObservationForTesting
        )
        #expect(viewController.sidebarAccessoryCountForTesting == 1)

        store.loadForTesting(
            serverState: .running,
            serverURL: URL(string: "http://localhost:9417/mcp")
        )
        try await waitForSidebarPresentation(
            viewController,
            .chatList,
            observation: viewController.sidebarViewControllerForTesting.sidebarKindObservationForTesting
        )
        #expect(viewController.sidebarAccessoryCountForTesting == 1)
    }

    @Test func splitViewInstallsToolbarWithSidebarTrackingSeparator() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(store: store)
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let sidebarItem = try #require(viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false
        try await waitForCondition {
            viewController.sidebarReviewChatFilterToolbarItemIsHiddenForTesting == false
        }

        #expect(window.toolbar != nil)
        #expect(harness.rootViewController.contentKindForTesting == .contentView)
        #expect(
            viewController.toolbarIdentifiersForTesting.contains(
                viewController.sidebarPickerToolbarItemIdentifierForTesting))
        #expect(
            viewController.toolbarIdentifiersForTesting.contains(
                viewController.sidebarReviewChatFilterToolbarItemIdentifierForTesting))
        #expect(viewController.toolbarIdentifiersForTesting.contains(.toggleSidebar) == false)
        #expect(viewController.toolbarIdentifiersForTesting.contains(.sidebarTrackingSeparator))
        #expect(
            viewController.sidebarPickerToolbarSegmentAccessibilityDescriptionsForTesting == ["Workspace", "Account"]
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

    @Test func sidebarReviewChatFilterToolbarItemProvidesMenuAndSelectedState() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(store: store)
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let sidebarItem = try #require(viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false

        #expect(viewController.sidebarReviewChatFilterToolbarItemIsHiddenForTesting == false)
        #expect(
            viewController.sidebarReviewChatFilterToolbarMenuItemTitlesForTesting == [
                "All Items",
                "-",
                "Running",
                "Latest Finished",
            ])
        #expect(viewController.sidebarReviewChatFilterToolbarShowsActiveBackgroundForTesting == false)
        #expect(viewController.selectedToolbarItemIdentifierForTesting == nil)

        viewController.setSidebarReviewChatFilterForTesting(.running)
        try await waitForCondition {
            viewController.sidebarReviewChatFilterToolbarShowsActiveBackgroundForTesting
        }
        #expect(viewController.sidebarReviewChatFilterToolbarSelectedFilterForTesting == .running)
        #expect(viewController.sidebarReviewChatFilterToolbarSelectedMenuItemTitlesForTesting == ["Running"])
        #expect(viewController.selectedToolbarItemIdentifierForTesting == nil)

        viewController.selectSidebarReviewChatFilterForTesting(.latestFinished)
        let combinedFilter: SidebarReviewChatFilter = [.running, .latestFinished]
        try await waitForCondition {
            viewController.sidebarReviewChatFilterToolbarSelectedFilterForTesting == combinedFilter
        }
        #expect(viewController.sidebarReviewChatFilterToolbarShowsActiveBackgroundForTesting)
        #expect(
            viewController.sidebarReviewChatFilterToolbarSelectedMenuItemTitlesForTesting == ["Running", "Latest Finished"])
        #expect(viewController.selectedToolbarItemIdentifierForTesting == nil)

        viewController.selectSidebarReviewChatFilterForTesting(.running)
        try await waitForCondition {
            viewController.sidebarReviewChatFilterToolbarSelectedFilterForTesting == .latestFinished
        }
        #expect(viewController.sidebarReviewChatFilterToolbarShowsActiveBackgroundForTesting)
        #expect(viewController.sidebarReviewChatFilterToolbarSelectedMenuItemTitlesForTesting == ["Latest Finished"])
        #expect(viewController.selectedToolbarItemIdentifierForTesting == nil)

        viewController.setSidebarReviewChatFilterForTesting(.all)
        try await waitForCondition {
            viewController.sidebarReviewChatFilterToolbarShowsActiveBackgroundForTesting == false
        }
        #expect(viewController.sidebarReviewChatFilterToolbarSelectedFilterForTesting == .all)
        #expect(viewController.sidebarReviewChatFilterToolbarSelectedMenuItemTitlesForTesting == ["All Items"])
        #expect(viewController.selectedToolbarItemIdentifierForTesting == nil)
    }

    @Test func sidebarReviewChatFilterPersistsMenuSelectionAcrossWindowControllers() async throws {
        let defaultsContext = try makeSidebarReviewChatFilterDefaultsForTesting()
        let defaults = defaultsContext.defaults
        defer {
            defaults.removePersistentDomain(forName: defaultsContext.suiteName)
        }
        let combinedFilter: SidebarReviewChatFilter = [.running, .latestFinished]

        do {
            let store = CodexReviewStore.makePreviewStore()
            let harness = makeWindowHarness(
                store: store,
                sidebarReviewChatFilterDefaults: defaults
            )
            let viewController = harness.viewController
            let sidebarItem = try #require(viewController.splitViewItems.first)
            sidebarItem.isCollapsed = false

            try await waitForCondition {
                viewController.sidebarReviewChatFilterToolbarSelectedFilterForTesting == .all
            }
            viewController.selectSidebarReviewChatFilterForTesting(.running)
            try await waitForCondition {
                viewController.sidebarReviewChatFilterToolbarSelectedFilterForTesting == .running
            }
            viewController.selectSidebarReviewChatFilterForTesting(.latestFinished)
            try await waitForCondition {
                viewController.sidebarReviewChatFilterToolbarSelectedFilterForTesting == combinedFilter
            }
            #expect(
                defaults.string(forKey: ReviewMonitorSidebar.ReviewChatFilterPersistence.defaultsKey)
                    == combinedFilter.persistedValue
            )
            harness.window.close()
        }

        do {
            let store = CodexReviewStore.makePreviewStore()
            let harness = makeWindowHarness(
                store: store,
                sidebarReviewChatFilterDefaults: defaults
            )
            let viewController = harness.viewController
            let sidebarItem = try #require(viewController.splitViewItems.first)
            sidebarItem.isCollapsed = false

            try await waitForCondition {
                viewController.sidebarReviewChatFilterToolbarSelectedFilterForTesting == combinedFilter
            }
            viewController.selectSidebarReviewChatFilterForTesting(.all)
            try await waitForCondition {
                viewController.sidebarReviewChatFilterToolbarSelectedFilterForTesting == .all
            }
            #expect(
                defaults.string(forKey: ReviewMonitorSidebar.ReviewChatFilterPersistence.defaultsKey)
                    == SidebarReviewChatFilter.all.persistedValue
            )
            harness.window.close()
        }

        do {
            let store = CodexReviewStore.makePreviewStore()
            let harness = makeWindowHarness(
                store: store,
                sidebarReviewChatFilterDefaults: defaults
            )
            let viewController = harness.viewController
            let sidebarItem = try #require(viewController.splitViewItems.first)
            sidebarItem.isCollapsed = false
            defer { harness.window.close() }

            try await waitForCondition {
                viewController.sidebarReviewChatFilterToolbarSelectedFilterForTesting == .all
            }
        }
    }

    @Test func sidebarReviewChatFilterDefaultsToAllForInvalidPersistedValue() async throws {
        let defaultsContext = try makeSidebarReviewChatFilterDefaultsForTesting()
        let defaults = defaultsContext.defaults
        defer {
            defaults.removePersistentDomain(forName: defaultsContext.suiteName)
        }
        defaults.set("invalid-filter", forKey: ReviewMonitorSidebar.ReviewChatFilterPersistence.defaultsKey)

        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(
            store: store,
            sidebarReviewChatFilterDefaults: defaults
        )
        let viewController = harness.viewController
        let sidebarItem = try #require(viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false
        defer { harness.window.close() }

        try await waitForCondition {
            viewController.sidebarReviewChatFilterToolbarSelectedFilterForTesting == .all
        }
    }

    @Test func sidebarReviewChatFilterToolbarItemOnlyShowsForWorkspaceSidebar() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(store: store)
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let sidebarItem = try #require(viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false

        #expect(viewController.sidebarReviewChatFilterToolbarItemIsHiddenForTesting == false)

        viewController.selectSidebarPickerToolbarSegmentForTesting(.account)
        try await waitForCondition {
            viewController.sidebarReviewChatFilterToolbarItemIsHiddenForTesting
        }

        viewController.selectSidebarPickerToolbarSegmentForTesting(.workspace)
        try await waitForCondition {
            viewController.sidebarReviewChatFilterToolbarItemIsHiddenForTesting == false
        }
    }

    @Test func sidebarPickerToolbarItemSwitchesSidebarPresentation() async throws {
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            serverURL: URL(string: "http://localhost:9417/mcp")
        )
        let harness = makeWindowHarness(store: store)
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let sidebarItem = try #require(viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false

        #expect(viewController.sidebarPresentationForTesting == .chatList)
        #expect(viewController.sidebarPickerToolbarSelectedSelectionForTesting == .workspace)

        viewController.selectSidebarPickerToolbarSegmentForTesting(.account)
        try await waitForSidebarPresentation(
            viewController,
            .accountList,
            observation: viewController.sidebarViewControllerForTesting.sidebarKindObservationForTesting
        )

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
        try await waitForSidebarPresentation(
            viewController,
            .accountList,
            observation: viewController.sidebarViewControllerForTesting.sidebarKindObservationForTesting
        )

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
        try await waitForSidebarPresentation(
            viewController,
            .accountList,
            observation: viewController.sidebarViewControllerForTesting.sidebarKindObservationForTesting
        )

        #expect(sidebarItem.isCollapsed == false)
        #expect(viewController.sidebarPickerToolbarSelectedSelectionForTesting == .account)

        viewController.selectSidebarPickerToolbarOverflowMenuItemForTesting(.account)
        window.layoutIfNeeded()

        #expect(sidebarItem.isCollapsed)
    }

    @Test func sidebarPickerToolbarItemTracksExternalSelectionChanges() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let viewController = makeReviewMonitorSplitViewControllerForTesting(store: store, uiState: uiState)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }

        viewController.attach(to: window)
        #expect(viewController.sidebarPickerToolbarSelectedSelectionForTesting == .workspace)

        uiState.sidebarSelection = .account
        try await waitForObservedValue(
            from: viewController.sidebarViewControllerForTesting.sidebarKindObservationForTesting,
            true
        ) {
            viewController.sidebarPickerToolbarSelectedSelectionForTesting == .account
        }
    }

    @Test func sidebarKindObservationTracksSelectionAndStoreChanges() async throws {
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            serverURL: URL(string: "http://localhost:9417/mcp")
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let viewController = makeReviewMonitorSplitViewControllerForTesting(store: store, uiState: uiState)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        viewController.attach(to: window)
        let sidebar = viewController.sidebarViewControllerForTesting

        uiState.sidebarSelection = .account
        try await waitForSidebarPresentation(
            viewController,
            .accountList,
            observation: sidebar.sidebarKindObservationForTesting
        )

        uiState.sidebarSelection = .workspace
        try await waitForSidebarPresentation(
            viewController,
            .chatList,
            observation: sidebar.sidebarKindObservationForTesting
        )

        store.loadForTesting(
            serverState: .failed("Embedded server is unavailable in preview mode.")
        )
        try await waitForSidebarPresentation(
            viewController,
            .unavailable,
            observation: sidebar.sidebarKindObservationForTesting
        )

        store.loadForTesting(
            serverState: .running,
            serverURL: URL(string: "http://localhost:9417/mcp")
        )
        try await waitForSidebarPresentation(
            viewController,
            .chatList,
            observation: sidebar.sidebarKindObservationForTesting
        )
    }

    @Test func splitViewShowsAddAccountToolbarItemOnlyForAccountSidebar() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let viewController = makeReviewMonitorSplitViewControllerForTesting(store: store, uiState: uiState)
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
        let viewController = makeReviewMonitorSplitViewControllerForTesting(store: store, uiState: uiState)
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

    @Test func previewContentViewControllerConfiguresAttachedWindowLikeSplitPresentation() async throws {
        let viewController = makeReviewMonitorPreviewContentViewControllerForPreview()
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        window.layoutIfNeeded()
        try await waitForCondition {
            window.titleVisibility == .visible && window.title.isEmpty == false
        }

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

    @Test func previewContentViewControllerRendersSelectedChatLog() async throws {
        let previewContent = ReviewMonitorPreviewContent.makeContentSource()
        let store = previewContent.store
        let selectedChatID = try #require(previewSelectedChatID(in: store))
        let selectedSnapshot = try #require(await previewContent.snapshotForTesting(chatID: selectedChatID))
        let expectedLogText = try #require(selectedSnapshot.items.compactMap { $0.text }.first)
        let viewController = makeReviewMonitorPreviewContentViewControllerForPreview(
            previewContent: previewContent
        )
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        window.layoutIfNeeded()

        let transport = viewController.splitViewControllerForTesting.transportViewControllerForTesting
        let snapshot = try await awaitTransportRender(transport) { snapshot in
            snapshot.log.contains(expectedLogText) && snapshot.isShowingEmptyState == false
        }

        #expect(transport.renderedStateForTesting.selection == .chat(selectedChatID.rawValue))
        #expect(snapshot.log.isEmpty == false)
    }

    @Test func previewContentViewControllerStreamsSelectedChatLogTicks() async throws {
        let previewContent = ReviewMonitorPreviewContent.makeContentSource()
        let viewController = makeReviewMonitorPreviewContentViewControllerForPreview(
            previewContent: previewContent
        )
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        window.layoutIfNeeded()

        let transport = viewController.splitViewControllerForTesting.transportViewControllerForTesting
        let initialSnapshot = try await awaitTransportRender(transport) { snapshot in
            snapshot.log.isEmpty == false && snapshot.isShowingEmptyState == false
        }

        let nextTick = try #require(await viewController.appendPreviewChatLogStreamTickForTesting())
        #expect(nextTick == 1)
        let updatedSnapshot = try await awaitTransportRender(transport) { snapshot in
            snapshot.log.count > initialSnapshot.log.count
                && snapshot.log.contains("Turn started")
                && snapshot.isShowingEmptyState == false
        }

        #expect(updatedSnapshot.log.contains("Turn started"))
    }

    @Test func windowControllerUsesSeededAuthenticatedStateOnFirstPresentation() {
        let backend = AuthActionBackend(
            initialAuthState: .signedIn(accountID: "review@example.com")
        )
        let store = makeStore(backend: backend)
        let windowController = ReviewMonitorWindowController(
            store: store,
            contentTransitionAnimator: ReviewMonitorRootViewController.defaultContentTransitionAnimator,
            sidebarReviewChatFilterDefaults: nil
        )
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
            frameAutosaveName: autosaveName,
            sidebarReviewChatFilterDefaults: nil
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
        let currentAccount = CodexReviewAccount(email: "current@example.com", planType: "pro")
        store.loadForTesting(
            serverState: .running,
            authPhase: .signedOut,
            account: currentAccount,
            persistedAccounts: []
        )
        let windowController = ReviewMonitorWindowController(
            store: store,
            contentTransitionAnimator: ReviewMonitorRootViewController.defaultContentTransitionAnimator,
            sidebarReviewChatFilterDefaults: nil
        )
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
        let currentAccount = CodexReviewAccount(email: "current@example.com", planType: "pro")
        store.loadForTesting(
            serverState: .running,
            authPhase: .signedOut,
            account: currentAccount,
            persistedAccounts: []
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = makeReviewMonitorSplitViewControllerForTesting(store: store, uiState: uiState)

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
            persistedAccounts: [CodexReviewAccount(email: "saved@example.com", planType: "pro")]
        )
        let windowController = ReviewMonitorWindowController(
            store: store,
            contentTransitionAnimator: ReviewMonitorRootViewController.defaultContentTransitionAnimator,
            sidebarReviewChatFilterDefaults: nil
        )
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
        let windowController = ReviewMonitorWindowController(
            store: store,
            contentTransitionAnimator: ReviewMonitorRootViewController.defaultContentTransitionAnimator,
            sidebarReviewChatFilterDefaults: nil
        )
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

        applyTestAuthState(
            auth: store.auth,
            state:
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
        let logText = "Safe area log\n"
        let chat = makeShellReviewChatForTesting(
            id: "chat-safe-area",
            title: "Uncommitted changes"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 900, height: 600)
        )
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        try await renderDetailLogForShellLayoutTesting(logText, in: transport, viewController: viewController, chat: chat)

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
        #expect(
            abs(
                transport.logMaximumVerticalScrollOffsetForTesting
                    - transport.logMinimumVerticalScrollOffsetForTesting
            ) < 0.5)
    }

    @Test func shortDetailLogKeepsTextContentWithinDocumentBounds() async throws {
        let logText = "Short log\n"
        let chat = makeShellReviewChatForTesting(
            id: "chat-short-log-layout",
            title: "Uncommitted changes"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 900, height: 600)
        )
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        try await renderDetailLogForShellLayoutTesting(logText, in: transport, viewController: viewController, chat: chat)

        let textContentFrame = transport.logTextContentFrameForTesting
        let documentViewFrame = transport.logDocumentViewFrameForTesting

        #expect(abs(textContentFrame.minY) < 0.5)
        #expect(textContentFrame.maxY <= documentViewFrame.maxY + 0.5)
        #expect(textContentFrame.height <= documentViewFrame.height + 0.5)
        expectLogTextContainerWidthTracksContentView(transport)
    }

    @Test func detailLogExpandsAfterSidebarReopensFromCompactWidth() async throws {
        let logText = Array(repeating: "Long line that should reflow across the widened detail pane.\n", count: 40)
            .joined()
        let chat = makeShellReviewChatForTesting(
            id: "chat-sidebar-width-regression",
            title: "Uncommitted changes"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
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
        try await renderDetailLogForShellLayoutTesting(logText, in: transport, viewController: viewController, chat: chat)

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

        let expandedDocumentWidth = transport.logDocumentViewFrameForTesting.width
        let expandedLogWidth = transport.logFrameForTesting.width
        let expandedTextWidth = transport.logTextContentFrameForTesting.width

        #expect(expandedDocumentWidth > compactDocumentWidth + 200)
        #expect(abs(expandedDocumentWidth - expandedLogWidth) < 32)
        #expect(abs(expandedTextWidth - expandedLogWidth) < 32)
        expectLogTextContainerWidthTracksContentView(transport)
    }

    @Test func detailLogShrinksAfterSidebarReopensIntoNarrowWidth() async throws {
        let logText = Array(repeating: "Long line that should reflow when the detail pane narrows.\n", count: 40)
            .joined()
        let chat = makeShellReviewChatForTesting(
            id: "chat-sidebar-width-shrink-regression",
            title: "Uncommitted changes"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
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
        try await renderDetailLogForShellLayoutTesting(logText, in: transport, viewController: viewController, chat: chat)
        let expandedDocumentWidth = transport.logDocumentViewFrameForTesting.width
        expectLogTextContainerWidthTracksContentView(transport)

        sidebarItem.isCollapsed = true
        window.setContentSize(NSSize(width: 360, height: 420))
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()

        let compactDocumentWidth = transport.logDocumentViewFrameForTesting.width
        let compactLogWidth = transport.logFrameForTesting.width
        let compactTextWidth = transport.logTextContentFrameForTesting.width

        #expect(compactDocumentWidth < expandedDocumentWidth - 200)
        #expect(abs(compactDocumentWidth - compactLogWidth) < 32)
        #expect(abs(compactTextWidth - compactLogWidth) < 32)
        expectLogTextContainerWidthTracksContentView(transport)
    }

    @Test func detailLogTracksSimpleWindowResizeInBothDirections() async throws {
        let logText = Array(repeating: "Long line that should reflow as the window resizes.\n", count: 40).joined()
        let chat = makeShellReviewChatForTesting(
            id: "chat-window-resize-width-regression",
            title: "Uncommitted changes"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
        let harness = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 960, height: 600)
        )
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        try await renderDetailLogForShellLayoutTesting(logText, in: transport, viewController: viewController, chat: chat)
        let wideWidth = transport.logDocumentViewFrameForTesting.width
        expectLogTextContainerWidthTracksContentView(transport)

        window.setContentSize(NSSize(width: 520, height: 420))
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        let narrowWidth = transport.logDocumentViewFrameForTesting.width
        let narrowTextWidth = transport.logTextContentFrameForTesting.width
        let narrowLogWidth = transport.logFrameForTesting.width
        expectLogTextContainerWidthTracksContentView(transport)

        window.setContentSize(NSSize(width: 900, height: 600))
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
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
        let logText = String(repeating: "wrap-sensitive text ", count: 600)
        let chat = makeShellReviewChatForTesting(
            id: "chat-window-live-resize-log",
            title: "Uncommitted changes"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
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
        try await renderDetailLogForShellLayoutTesting(logText, in: transport, viewController: viewController, chat: chat)
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
        let chat = makeShellReviewChatForTesting(
            id: "chat-window-live-resize-stream-log",
            title: "Uncommitted changes"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
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
        try await renderDetailLogForShellLayoutTesting(
            streamLog, in: transport, viewController: viewController, chat: chat)
        #expect(transport.isLogPinnedToBottomForTesting)

        transport.beginLogLiveResizeForTesting()
        liveResizeActive = true
        window.setContentSize(NSSize(width: 620, height: 600))
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()

        let visibleFragmentBounds = transport.logVisibleFragmentBoundsForTesting
        let visibleBottomInViewport = visibleFragmentBounds.maxY - transport.logVerticalScrollOffsetForTesting
        let bottomGap = transport.logViewportHeightForTesting - visibleBottomInViewport

        #expect(abs(bottomGap) < 120)
        #expect(transport.isLogPinnedToBottomForTesting)
        #expect(transport.logStaleFragmentViewCountForTesting == 0)
    }

    @Test func detailLogTextContainerExpandsAfterToolbarSidebarToggleAtCompactWidth() async throws {
        let logText = Array(
            repeating: "Long line that should reflow after the toolbar sidebar toggle path.\n", count: 40
        ).joined()
        let chat = makeShellReviewChatForTesting(
            id: "chat-toolbar-sidebar-toggle-textkit-width-regression",
            title: "Uncommitted changes"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, fixtures: [chat])
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
        try await renderDetailLogForShellLayoutTesting(logText, in: transport, viewController: viewController, chat: chat)

        viewController.toggleSidebar(nil)
        await awaitNativeLayoutTurn()
        window.setContentSize(NSSize(width: 360, height: 420))
        await awaitNativeLayoutTurn()
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        #expect(sidebarItem.isCollapsed)

        viewController.toggleSidebar(nil)
        await awaitNativeLayoutTurn()
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()
        let compactDocumentWidth = transport.logDocumentViewFrameForTesting.width
        expectLogTextContainerWidthTracksContentView(transport)

        window.setContentSize(NSSize(width: 960, height: 600))
        await awaitNativeLayoutTurn()
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        transport.view.layoutSubtreeIfNeeded()

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
        let viewController = makeReviewMonitorSplitViewControllerForTesting(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
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

    @Test func previewRunningChatsAppendPseudoStreamWhenTicked() async throws {
        let source = ReviewMonitorPreviewContent.makeContentSource()
        let runningChatID = CodexThreadID(rawValue: "preview-thread-0-0")
        let initialSnapshot = try #require(await source.snapshotForTesting(chatID: runningChatID))
        let initialItemCount = initialSnapshot.items.count

        await source.appendPreviewChatLogStreamTick()

        let updatedSnapshot = try #require(await source.snapshotForTesting(chatID: runningChatID))
        let appendedItems = Array(updatedSnapshot.items.dropFirst(initialItemCount))
        let appendedText = appendedItems.compactMap { $0.text }.joined(separator: "\n")
        #expect(updatedSnapshot.items != initialSnapshot.items)
        #expect(appendedText.contains("Turn started"))
        #expect(appendedText.contains("delta/") == false)
        #expect(appendedText.count < 160)
        #expect(appendedItems.count == 1)
        #expect(appendedItems.first?.kind.rawValue == "event")
        #expect(appendedItems.first.map(diagnosticMessage)?.contains("preview-turn") == true)
    }

    @Test func previewChatStreamUsesMixedLogKinds() async throws {
        let source = ReviewMonitorPreviewContent.makeContentSource()
        let runningChatID = CodexThreadID(rawValue: "preview-thread-0-0")
        let initialSnapshot = try #require(await source.snapshotForTesting(chatID: runningChatID))
        let initialItemCount = initialSnapshot.items.count
        var tick = 0

        for _ in 0..<720 {
            tick = await source.appendPreviewChatLogStreamTick(after: tick)
        }

        let updatedSnapshot = try #require(await source.snapshotForTesting(chatID: runningChatID))
        let appendedItems = Array(updatedSnapshot.items.dropFirst(initialItemCount))
        let appendedKinds = appendedItems.map { $0.kind.rawValue }
        #expect(appendedKinds.contains("event"))
        #expect(appendedKinds.contains("commandExecution"))
        #expect(appendedKinds.contains("mcpToolCall"))
        #expect(appendedKinds.contains("plan"))
        #expect(appendedKinds.contains("contextCompaction"))
        #expect(appendedKinds.contains("reasoning"))
        #expect(appendedKinds.contains("agentMessage"))
        #expect(Set(appendedKinds).count >= 6)
        #expect(Set(appendedItems.map { $0.id }).count == appendedItems.count)

        let compactionItems = updatedSnapshot.items
            .dropFirst(initialItemCount)
            .filter { $0.kind.rawValue == "contextCompaction" }
        let compactionItem = try #require(compactionItems.last)
        #expect(contextCompactionTitle(compactionItem) == "Context automatically compacted")
        let renderedLog = updatedSnapshot.items.compactMap { $0.text }.joined(separator: "\n")
        #expect(renderedLog.contains("Context automatically compacted"))
        #expect(renderedLog.contains("Automatically compacting context") == false)
    }

    @Test func previewChatStreamWaitsAfterEachCompletedItemAndDrainsChunks() async throws {
        let source = ReviewMonitorPreviewContent.makeContentSource()
        let runningChatID = CodexThreadID(rawValue: "preview-thread-0-0")
        let initialSnapshot = try #require(await source.snapshotForTesting(chatID: runningChatID))
        let initialItemCount = initialSnapshot.items.count
        var tick = 0

        tick = await source.appendPreviewChatLogStreamTick(after: tick)
        var snapshot = try #require(await source.snapshotForTesting(chatID: runningChatID))
        #expect(snapshot.items.count == initialItemCount + 1)
        #expect(snapshot.items.last?.kind.rawValue == "event")

        for _ in 0..<38 {
            tick = await source.appendPreviewChatLogStreamTick(after: tick)
        }
        snapshot = try #require(await source.snapshotForTesting(chatID: runningChatID))
        #expect(snapshot.items.count == initialItemCount + 1)

        tick = await source.appendPreviewChatLogStreamTick(after: tick)
        snapshot = try #require(await source.snapshotForTesting(chatID: runningChatID))
        #expect(snapshot.items.count == initialItemCount + 2)
        #expect(snapshot.items.last?.kind.rawValue == "plan")

        for _ in 0..<180 where snapshot.items.last?.kind.rawValue != "reasoning" {
            tick = await source.appendPreviewChatLogStreamTick(after: tick)
            snapshot = try #require(await source.snapshotForTesting(chatID: runningChatID))
        }
        let firstReasoning = try #require(snapshot.items.last)
        #expect(firstReasoning.kind.rawValue == "reasoning")
        let reasoningID = firstReasoning.id
        let initialReasoningText = reasoningText(firstReasoning)
        var latestReasoningText = initialReasoningText

        for _ in 0..<80 {
            tick = await source.appendPreviewChatLogStreamTick(after: tick)
            snapshot = try #require(await source.snapshotForTesting(chatID: runningChatID))
            let item = try #require(snapshot.items.first { $0.id == reasoningID })
            let text = reasoningText(item)
            if text == latestReasoningText {
                break
            }
            latestReasoningText = text
        }

        #expect(latestReasoningText.count > initialReasoningText.count)
        let countAfterReasoning = snapshot.items.count
        for _ in 0..<37 {
            tick = await source.appendPreviewChatLogStreamTick(after: tick)
        }
        snapshot = try #require(await source.snapshotForTesting(chatID: runningChatID))
        #expect(snapshot.items.count == countAfterReasoning)

        tick = await source.appendPreviewChatLogStreamTick(after: tick)
        snapshot = try #require(await source.snapshotForTesting(chatID: runningChatID))
        #expect(snapshot.items.count == countAfterReasoning + 1)
        #expect(snapshot.items.last?.kind.rawValue == "commandExecution")
    }

}

@MainActor
private func previewSelectedChatID(in store: CodexReviewStore) -> CodexThreadID? {
    _ = store
    return CodexThreadID(rawValue: "preview-thread-0-0")
}

private func makeShellTestGitRepository() throws -> URL {
    let repo = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
    return repo
}

@MainActor
private func diagnosticMessage(_ item: CodexChatItemSnapshot) -> String {
    if case .diagnostic(let message) = item.content {
        return message
    }
    return ""
}

@MainActor
private func reasoningText(_ item: CodexChatItemSnapshot) -> String {
    if case .reasoning(let reasoning) = item.content {
        return reasoning.text
    }
    return ""
}

@MainActor
private func contextCompactionTitle(_ item: CodexChatItemSnapshot) -> String {
    if case .contextCompaction(let title) = item.content {
        return title ?? ""
    }
    return ""
}

@MainActor
private func makeShellReviewChatForTesting(
    id: String,
    title: String
) -> ReviewChatFixtureForTesting {
    makeReviewChatFixtureForTesting(
        id: id,
        title: title,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 200)
    )
}

@MainActor
private func renderDetailLogForShellLayoutTesting(
    _ text: String,
    in transport: ReviewMonitorTransportViewController,
    viewController: ReviewMonitorSplitViewController,
    chat: ReviewChatFixtureForTesting
) async throws {
    viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chat.chatID)
    let expectedSelection: ReviewMonitorTransportViewController.DisplayedSelectionForTesting = .chat(chat.chatID.rawValue)
    try await waitForCondition {
        transport.renderedStateForTesting.selection == expectedSelection
            && transport.renderedStateForTesting.snapshot.isShowingEmptyState == false
    }
    #expect(transport.renderLogForTesting(text: text, allowIncrementalUpdate: false))
    transport.scrollLogToBottomForTesting()
    if let window = viewController.view.window {
        window.layoutIfNeeded()
    }
    viewController.view.layoutSubtreeIfNeeded()
    transport.view.layoutSubtreeIfNeeded()
}

private func makeSidebarReviewChatFilterDefaultsForTesting() throws -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "ReviewMonitorSidebarReviewChatFilterDefaultsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
