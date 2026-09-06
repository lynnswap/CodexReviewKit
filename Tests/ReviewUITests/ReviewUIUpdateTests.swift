import AppKit
import Testing
@_spi(Testing) @testable import CodexReview
@_spi(ApplicationHostSupport) @_spi(PreviewSupport) @testable import ReviewUI

@MainActor
extension ReviewUITests {
    @Test func updateToolbarItemIsSelectedVisibleAndImmediatelyBeforeFilter() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let harness = makeWindowHarness(store: store, requestCodexUpdate: {})
        defer { harness.window.close() }
        let sidebarItem = try #require(harness.viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false

        #expect(harness.viewController.sidebarUpdateToolbarItemIsHiddenForTesting)
        harness.windowController.setCodexUpdateAvailable(true)
        try await waitForCondition {
            harness.viewController.sidebarUpdateToolbarItemIsHiddenForTesting == false
        }

        let identifiers = harness.viewController.toolbarIdentifiersForTesting
        let updateIndex = try #require(identifiers.firstIndex(
            of: harness.viewController.sidebarUpdateToolbarItemIdentifierForTesting
        ))
        let filterIndex = try #require(identifiers.firstIndex(
            of: harness.viewController.sidebarJobFilterToolbarItemIdentifierForTesting
        ))
        #expect(updateIndex + 1 == filterIndex)
        #expect(harness.viewController.sidebarUpdateToolbarTitleForTesting == "Update")
        #expect(harness.viewController.sidebarUpdateToolbarAccessibilityLabelForTesting == "Update Codex")
        #expect(harness.viewController.sidebarUpdateToolbarShowsSelectedBackgroundForTesting)

        harness.viewController.selectSidebarPickerToolbarSegmentForTesting(.account)
        try await waitForCondition {
            harness.viewController.sidebarUpdateToolbarItemIsHiddenForTesting
        }
        harness.viewController.selectSidebarPickerToolbarSegmentForTesting(.workspace)
        try await waitForCondition {
            harness.viewController.sidebarUpdateToolbarItemIsHiddenForTesting == false
        }
        sidebarItem.isCollapsed = true
        try await waitForCondition {
            harness.viewController.sidebarUpdateToolbarItemIsHiddenForTesting
        }
    }

    @Test func updateToolbarItemRequiresAnAction() throws {
        let harness = makeWindowHarness(store: CodexReviewStore.makePreviewStore())
        defer { harness.window.close() }
        let sidebarItem = try #require(harness.viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false

        harness.windowController.setCodexUpdateAvailable(true)
        let toolbar = try #require(harness.window.toolbar)

        #expect(harness.viewController.sidebarUpdateToolbarItemIsHiddenForTesting)
        #expect(harness.viewController.toolbarDefaultItemIdentifiers(toolbar).contains(
            harness.viewController.sidebarUpdateToolbarItemIdentifierForTesting
        ) == false)
    }

    @Test func updateWithoutActiveReviewsInvokesOnceWithoutConfirmation() async throws {
        var updateCount = 0
        let harness = makeWindowHarness(
            store: CodexReviewStore.makePreviewStore(),
            requestCodexUpdate: { updateCount += 1 }
        )
        defer { harness.window.close() }
        let sidebarItem = try #require(harness.viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false
        harness.windowController.setCodexUpdateAvailable(true)
        try await waitForCondition {
            harness.viewController.sidebarUpdateToolbarItemIsHiddenForTesting == false
        }

        harness.viewController.requestCodexUpdateForTesting()
        harness.viewController.requestCodexUpdateForTesting()
        try await waitForCondition {
            harness.viewController.sidebarUpdateToolbarItemIsHiddenForTesting
        }

        #expect(updateCount == 1)
        #expect(harness.viewController.pendingUpdateAlertForTesting == nil)
        #expect(harness.viewController.sidebarUpdateToolbarItemIsHiddenForTesting)

        harness.windowController.setCodexUpdateAvailable(true)
        try await waitForCondition {
            harness.viewController.sidebarUpdateToolbarItemIsHiddenForTesting == false
        }
    }

    @Test func activeReviewUpdateCanBeCancelledAndAlertIsRemovedOnDetach() async throws {
        let store = makeActiveReviewStore()
        var updateCount = 0
        let harness = makeWindowHarness(store: store, requestCodexUpdate: { updateCount += 1 })
        defer { harness.window.close() }
        let sidebarItem = try #require(harness.viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false
        harness.windowController.setCodexUpdateAvailable(true)
        try await waitForCondition {
            harness.viewController.sidebarUpdateToolbarItemIsHiddenForTesting == false
        }

        harness.viewController.requestCodexUpdateForTesting()
        let alert = try #require(harness.viewController.pendingUpdateAlertForTesting)
        #expect(alert.messageText == "Stop Active Reviews and Update Codex?")
        #expect(alert.informativeText == "Active and queued reviews will be cancelled. ReviewMonitor will restart after Codex is updated.")
        #expect(alert.buttons.first?.hasDestructiveAction == true)
        harness.viewController.respondToUpdateAlertForTesting(.alertSecondButtonReturn)
        try await waitForCondition {
            harness.viewController.pendingUpdateAlertForTesting == nil
        }
        #expect(updateCount == 0)
        #expect(harness.viewController.sidebarUpdateToolbarItemIsHiddenForTesting == false)

        harness.viewController.requestCodexUpdateForTesting()
        #expect(harness.viewController.pendingUpdateAlertForTesting != nil)
        harness.viewController.detachFromWindow()
        #expect(harness.viewController.pendingUpdateAlertForTesting == nil)
        #expect(updateCount == 0)
    }

    @Test func activeReviewConfirmationConsumesAvailabilityAndRejectsDoubleDispatch() async throws {
        var updateCount = 0
        let harness = makeWindowHarness(
            store: makeActiveReviewStore(),
            requestCodexUpdate: { updateCount += 1 }
        )
        defer { harness.window.close() }
        let sidebarItem = try #require(harness.viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false
        harness.windowController.setCodexUpdateAvailable(true)
        try await waitForCondition {
            harness.viewController.sidebarUpdateToolbarItemIsHiddenForTesting == false
        }

        harness.viewController.requestCodexUpdateForTesting()
        let firstAlert = try #require(harness.viewController.pendingUpdateAlertForTesting)
        harness.viewController.requestCodexUpdateForTesting()
        #expect(harness.viewController.pendingUpdateAlertForTesting === firstAlert)
        harness.viewController.respondToUpdateAlertForTesting(.alertFirstButtonReturn)
        try await waitForCondition { updateCount == 1 }

        harness.viewController.requestCodexUpdateForTesting()
        #expect(updateCount == 1)
        #expect(harness.viewController.pendingUpdateAlertForTesting == nil)
        #expect(harness.viewController.sidebarUpdateToolbarItemIsHiddenForTesting)
    }
}

@MainActor
private func makeActiveReviewStore() -> CodexReviewStore {
    let store = CodexReviewStore.makePreviewStore()
    let job = CodexReviewJob.makeForTesting(
        targetSummary: "Active review",
        status: .running,
        summary: "Running."
    )
    store.loadForTesting(
        serverState: .running,
        workspaces: [CodexReviewWorkspace(cwd: job.cwd)],
        jobs: [job]
    )
    return store
}
