import AppKit
import Testing
@_spi(Testing) @testable import CodexReview
@_spi(PreviewSupport) @testable import ReviewUI

@MainActor
extension ReviewUITests {
    @Test func updateAvailabilityNotificationControlsToolbarPresentation() async throws {
        let notificationCenter = NotificationCenter()
        let harness = makeWindowHarness(
            store: CodexReviewStore.makePreviewStore(),
            notificationCenter: notificationCenter
        )
        defer { harness.window.close() }
        let sidebarItem = try #require(harness.viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false

        #expect(
            ReviewMonitorCodexUpdateNotification.availabilityChanged.rawValue
                == "CodexReviewKit.ReviewMonitor.codexUpdateAvailabilityChanged"
        )
        #expect(harness.viewController.sidebarUpdateToolbarItemIsHiddenForTesting)

        postCodexUpdateAvailability(true, to: notificationCenter)
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

        postCodexUpdateAvailability(false, to: notificationCenter)
        sidebarItem.isCollapsed = false
        #expect(harness.viewController.sidebarUpdateToolbarItemIsHiddenForTesting)
    }

    @Test func updateToolbarPostsOneRequestAndRejectsDuplicateHiddenAction() async throws {
        let notificationCenter = NotificationCenter()
        let recorder = CodexUpdateRequestRecorder()
        let requestObserver = notificationCenter.addObserver(
            forName: Notification.Name(
                "CodexReviewKit.ReviewMonitor.codexUpdateRequested"
            ),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                recorder.requestCount += 1
            }
        }
        defer { notificationCenter.removeObserver(requestObserver) }

        let harness = makeWindowHarness(
            store: CodexReviewStore.makePreviewStore(),
            notificationCenter: notificationCenter
        )
        defer { harness.window.close() }
        let sidebarItem = try #require(harness.viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false
        postCodexUpdateAvailability(true, to: notificationCenter)
        try await waitForCondition {
            harness.viewController.sidebarUpdateToolbarItemIsHiddenForTesting == false
        }

        harness.viewController.requestCodexUpdateForTesting()
        harness.viewController.requestCodexUpdateForTesting()
        try await waitForCondition {
            harness.viewController.sidebarUpdateToolbarItemIsHiddenForTesting
                && recorder.requestCount == 1
        }

        #expect(
            ReviewMonitorCodexUpdateNotification.requested.rawValue
                == "CodexReviewKit.ReviewMonitor.codexUpdateRequested"
        )
        #expect(recorder.requestCount == 1)

        harness.viewController.requestCodexUpdateForTesting()
        #expect(recorder.requestCount == 1)

        postCodexUpdateAvailability(true, to: notificationCenter)
        try await waitForCondition {
            harness.viewController.sidebarUpdateToolbarItemIsHiddenForTesting == false
        }
    }

    @Test func malformedUpdateAvailabilityNotificationIsIgnored() throws {
        let notificationCenter = NotificationCenter()
        let harness = makeWindowHarness(
            store: CodexReviewStore.makePreviewStore(),
            notificationCenter: notificationCenter
        )
        defer { harness.window.close() }
        let sidebarItem = try #require(harness.viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false

        notificationCenter.post(
            name: ReviewMonitorCodexUpdateNotification.availabilityChanged,
            object: nil,
            userInfo: [ReviewMonitorCodexUpdateNotification.availableUserInfoKey: "true"]
        )

        #expect(harness.viewController.sidebarUpdateToolbarItemIsHiddenForTesting)
    }

    @Test func updateAvailabilityObserverCleanupStopsDelivery() throws {
        let notificationCenter = RemovalRecordingNotificationCenter()
        let harness = makeWindowHarness(
            store: CodexReviewStore.makePreviewStore(),
            notificationCenter: notificationCenter
        )
        defer { harness.window.close() }
        let sidebarItem = try #require(harness.viewController.splitViewItems.first)
        sidebarItem.isCollapsed = false
        #expect(notificationCenter.removedObserverCount == 0)

        harness.windowController.stopObservingCodexUpdateAvailabilityForTesting()
        harness.windowController.stopObservingCodexUpdateAvailabilityForTesting()
        postCodexUpdateAvailability(true, to: notificationCenter)

        #expect(notificationCenter.removedObserverCount == 1)
        #expect(harness.viewController.sidebarUpdateToolbarItemIsHiddenForTesting)
    }
}

@MainActor
private final class CodexUpdateRequestRecorder {
    var requestCount = 0
}

private final class RemovalRecordingNotificationCenter: NotificationCenter, @unchecked Sendable {
    nonisolated(unsafe) private(set) var removedObserverCount = 0

    override func removeObserver(_ observer: Any) {
        removedObserverCount += 1
        super.removeObserver(observer)
    }
}

private func postCodexUpdateAvailability(
    _ available: Bool,
    to notificationCenter: NotificationCenter
) {
    notificationCenter.post(
        name: Notification.Name(
            "CodexReviewKit.ReviewMonitor.codexUpdateAvailabilityChanged"
        ),
        object: nil,
        userInfo: ["available": available]
    )
}
