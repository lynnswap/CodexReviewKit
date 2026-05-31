import AppKit
import Foundation
import ObservationBridge
import SwiftUI
import Testing
@_spi(Testing) @testable import CodexReview
@_spi(PreviewSupport) @testable import ReviewUI
import CodexReviewTesting

@MainActor
private extension CodexReviewAuthModel {
    func updatePersistedAccounts(_ accounts: [CodexAccount]) {
        applyPersistedAccountStates(accounts.map(savedAccountPayload(from:)))
    }

    func updateAccount(_ account: CodexAccount?) {
        updateCurrentAccount(account)
    }
}

@Suite(.serialized)
@MainActor
struct ReviewUITests {

    @Test func splitViewSectionsByWorkspace() {
        let workspaceAlphaJob = makeJob(
            cwd: "/tmp/workspace-alpha",
            startedAt: Date(timeIntervalSince1970: 200),
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let workspaceBetaJob = makeJob(
            cwd: "/tmp/workspace-beta",
            startedAt: Date(timeIntervalSince1970: 100),
            status: .failed,
            targetSummary: "Base branch: main"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [workspaceBetaJob, workspaceAlphaJob])
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarViewControllerForTesting.displayedSectionTitlesForTesting == [
            "workspace-alpha",
            "workspace-beta",
        ])
        #expect(viewController.splitViewItems.count == 2)
        #expect(viewController.splitViewItems[0].behavior == .sidebar)
        #expect(viewController.splitViewItems[1].behavior == .default)
        #expect(viewController.sidebarAccessoryCountForTesting == 1)
        #expect(viewController.contentAccessoryCountForTesting == 0)
    }

    @Test func workspaceDropReordersDisplayedSectionsImmediately() async {
        let workspaceAlphaJob = makeJob(
            id: "job-workspace-alpha",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let workspaceBetaJob = makeJob(
            id: "job-workspace-beta",
            cwd: "/tmp/workspace-beta",
            status: .failed,
            targetSummary: "Base branch: main"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [workspaceBetaJob, workspaceAlphaJob])
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        guard let workspaceAlpha = store.workspaces.first(where: { $0.cwd == "/tmp/workspace-alpha" }) else {
            Issue.record("workspace-alpha was not loaded.")
            return
        }
        let fullReloadCountBeforeDrop = sidebar.sidebarFullReloadCountForTesting
        let workspaceReloadCountBeforeDrop = sidebar.sidebarWorkspaceReloadCountForTesting
        let incrementalMoveCountBeforeDrop = sidebar.sidebarIncrementalMoveCountForTesting
        #expect(sidebar.performWorkspaceDropForTesting(workspaceAlpha, toIndex: store.workspaces.count))
        await Task.yield()

        #expect(sidebar.displayedSectionTitlesForTesting == [
            "workspace-beta",
            "workspace-alpha",
        ])
        #expect(sidebar.sidebarFullReloadCountForTesting == fullReloadCountBeforeDrop)
        #expect(sidebar.sidebarWorkspaceReloadCountForTesting == workspaceReloadCountBeforeDrop)
        #expect(sidebar.sidebarIncrementalMoveCountForTesting == incrementalMoveCountBeforeDrop + 1)
    }

    @Test func workspaceDropOnWorkspaceRowReordersDisplayedSections() {
        let workspaceAlphaJob = makeJob(
            id: "job-workspace-alpha-on-row",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let workspaceBetaJob = makeJob(
            id: "job-workspace-beta-on-row",
            cwd: "/tmp/workspace-beta",
            status: .failed,
            targetSummary: "Base branch: main"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [workspaceBetaJob, workspaceAlphaJob])
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        guard let workspaceAlpha = store.workspaces.first(where: { $0.cwd == "/tmp/workspace-alpha" }),
              let workspaceBeta = store.workspaces.first(where: { $0.cwd == "/tmp/workspace-beta" })
        else {
            Issue.record("workspaces were not loaded.")
            return
        }

        #expect(sidebar.performWorkspaceDropForTesting(workspaceBeta, proposedWorkspace: workspaceAlpha))
        #expect(sidebar.displayedSectionTitlesForTesting == [
            "workspace-beta",
            "workspace-alpha",
        ])
    }

    @Test func workspaceMembershipChangeUsesRootInsertWithoutFullReload() async throws {
        let alphaJob = makeJob(
            id: "job-workspace-alpha-membership",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let betaJob = makeJob(
            id: "job-workspace-beta-membership",
            cwd: "/tmp/workspace-beta",
            status: .succeeded,
            targetSummary: "Commit: abc123"
        )
        let alphaWorkspace = CodexReviewWorkspace(cwd: alphaJob.cwd)
        let betaWorkspace = CodexReviewWorkspace(cwd: betaJob.cwd)
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [alphaWorkspace],
            jobs: [alphaJob]
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        let fullReloadCountBeforeMembershipChange = sidebar.sidebarFullReloadCountForTesting
        let incrementalMoveCountBeforeMembershipChange = sidebar.sidebarIncrementalMoveCountForTesting
        let incrementalMembershipChangeCountBeforeMembershipChange = sidebar.sidebarIncrementalMembershipChangeCountForTesting

        store.loadForTesting(
            serverState: .running,
            workspaces: [alphaWorkspace, betaWorkspace],
            jobs: [alphaJob, betaJob]
        )
        try await waitForObservedValue(
            from: sidebar.sidebarTopologyDeliveryForTesting,
            [
                "workspace-alpha",
                "workspace-beta",
            ]
        ) {
            sidebar.displayedSectionTitlesForTesting
        }

        #expect(sidebar.displayedSectionTitlesForTesting == [
            "workspace-alpha",
            "workspace-beta",
        ])
        #expect(sidebar.sidebarFullReloadCountForTesting == fullReloadCountBeforeMembershipChange)
        #expect(sidebar.sidebarIncrementalMoveCountForTesting == incrementalMoveCountBeforeMembershipChange)
        #expect(sidebar.sidebarIncrementalMembershipChangeCountForTesting == incrementalMembershipChangeCountBeforeMembershipChange + 1)
    }

    @Test func workspaceSameMembershipSortOrderChangeMovesRowsWithoutReload() async throws {
        let alphaJob = makeJob(
            id: "job-workspace-alpha-sort-order",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let betaJob = makeJob(
            id: "job-workspace-beta-sort-order",
            cwd: "/tmp/workspace-beta",
            status: .succeeded,
            targetSummary: "Commit: abc123"
        )
        let alphaWorkspace = CodexReviewWorkspace(cwd: alphaJob.cwd)
        let betaWorkspace = CodexReviewWorkspace(cwd: betaJob.cwd)
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [alphaWorkspace, betaWorkspace],
            jobs: [alphaJob, betaJob]
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        let fullReloadCountBeforeChange = sidebar.sidebarFullReloadCountForTesting
        let incrementalMoveCountBeforeChange = sidebar.sidebarIncrementalMoveCountForTesting
        let incrementalMembershipChangeCountBeforeChange = sidebar.sidebarIncrementalMembershipChangeCountForTesting

        store.loadForTesting(
            serverState: .running,
            workspaces: [betaWorkspace, alphaWorkspace],
            jobs: [alphaJob, betaJob]
        )
        try await waitForObservedValue(
            from: sidebar.sidebarTopologyDeliveryForTesting,
            [
                "workspace-beta",
                "workspace-alpha",
            ]
        ) {
            sidebar.displayedSectionTitlesForTesting
        }

        #expect(sidebar.sidebarFullReloadCountForTesting == fullReloadCountBeforeChange)
        #expect(sidebar.sidebarIncrementalMembershipChangeCountForTesting == incrementalMembershipChangeCountBeforeChange)
        #expect(sidebar.sidebarIncrementalMoveCountForTesting == incrementalMoveCountBeforeChange + 1)
    }

    @Test func workspaceInsertionIndexFollowsCurrentHoverPosition() {
        let workspaceAlphaJob = makeJob(
            id: "job-workspace-alpha-blank",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let workspaceBetaJob = makeJob(
            id: "job-workspace-beta-blank",
            cwd: "/tmp/workspace-beta",
            status: .failed,
            targetSummary: "Base branch: main"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [workspaceBetaJob, workspaceAlphaJob])
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        guard let workspaceAlpha = store.workspaces.first(where: { $0.cwd == "/tmp/workspace-alpha" }) else {
            Issue.record("workspace-alpha was not loaded.")
            return
        }
        #expect(sidebar.workspaceInsertionIndexForTesting(workspaceAlpha, hoveringBelowMidpoint: false) == 0)
        #expect(sidebar.workspaceInsertionIndexForTesting(workspaceAlpha, hoveringBelowMidpoint: true) == 1)
    }

    @Test func workspaceBlankAreaInsertionUsesPointerPosition() {
        let workspaceAlphaJob = makeJob(
            id: "job-workspace-alpha-blank-area",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let workspaceBetaJob = makeJob(
            id: "job-workspace-beta-blank-area",
            cwd: "/tmp/workspace-beta",
            status: .failed,
            targetSummary: "Base branch: main"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [workspaceBetaJob, workspaceAlphaJob])
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.blankAreaWorkspaceInsertionIndexForTesting(atEnd: false) == 0)
        #expect(sidebar.blankAreaWorkspaceInsertionIndexForTesting(atEnd: true) == store.workspaces.count)
    }

    @Test func workspaceDropOnJobRowIsRejected() {
        let workspaceAlphaJob = makeJob(
            id: "job-workspace-alpha-reject",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let workspaceBetaJob = makeJob(
            id: "job-workspace-beta-reject",
            cwd: "/tmp/workspace-beta",
            status: .failed,
            targetSummary: "Base branch: main"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [workspaceBetaJob, workspaceAlphaJob])
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        guard let workspaceBeta = store.workspaces.first(where: { $0.cwd == "/tmp/workspace-beta" }),
              let workspaceAlpha = store.workspaces.first(where: { $0.cwd == "/tmp/workspace-alpha" }),
              let alphaJob = store.orderedJobs(in: workspaceAlpha).first
        else {
            Issue.record("workspace/job state was not loaded.")
            return
        }

        #expect(sidebar.workspaceDropIsRejectedForTesting(workspaceBeta, proposedJob: alphaJob))
    }

    @Test func jobDropOnBlankAreaIsRejected() {
        let firstJob = makeJob(
            id: "job-blank-area-reject",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let secondJob = makeJob(
            id: "job-blank-area-peer",
            cwd: "/tmp/workspace-alpha",
            status: .queued,
            targetSummary: "Queued review"
        )
        let workspace = CodexReviewWorkspace(cwd: "/tmp/workspace-alpha")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            jobs: [firstJob, secondJob]
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.jobDropIsRejectedForTesting(firstJob))
    }

    @Test func jobDropReordersWithinWorkspaceAndPreservesSelection() async throws {
        let firstJob = makeJob(
            id: "job-1",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let secondJob = makeJob(
            id: "job-2",
            cwd: "/tmp/workspace-alpha",
            status: .succeeded,
            targetSummary: "Commit: abc123"
        )
        let workspace = CodexReviewWorkspace(cwd: "/tmp/workspace-alpha")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            jobs: [firstJob, secondJob]
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.selectJobForTesting(firstJob)
        let fullReloadCountBeforeDrop = sidebar.sidebarFullReloadCountForTesting
        let workspaceReloadCountBeforeDrop = sidebar.sidebarWorkspaceReloadCountForTesting
        let incrementalMoveCountBeforeDrop = sidebar.sidebarIncrementalMoveCountForTesting
        let firstJobRowHeightBeforeDrop = try #require(sidebar.jobRowHeightForTesting(firstJob))
        let secondJobRowHeightBeforeDrop = try #require(sidebar.jobRowHeightForTesting(secondJob))
        #expect(firstJobRowHeightBeforeDrop == secondJobRowHeightBeforeDrop)
        #expect(sidebar.performJobDropForTesting(firstJob, proposedWorkspace: workspace, childIndex: store.jobCount(in: workspace)))
        await Task.yield()
        #expect(sidebar.displayedJobIDsForTesting(in: workspace) == ["job-2", "job-1"])
        #expect(sidebar.selectedJobForTesting?.id == "job-1")
        #expect(sidebar.sidebarFullReloadCountForTesting == fullReloadCountBeforeDrop)
        #expect(sidebar.sidebarWorkspaceReloadCountForTesting == workspaceReloadCountBeforeDrop)
        #expect(sidebar.sidebarIncrementalMoveCountForTesting == incrementalMoveCountBeforeDrop + 1)
        #expect(sidebar.jobRowHeightForTesting(firstJob) == firstJobRowHeightBeforeDrop)
        #expect(sidebar.jobRowHeightForTesting(secondJob) == secondJobRowHeightBeforeDrop)
    }

    @Test func sidebarRunningFilterKeepsWorkspacesAndShowsActiveJobs() async throws {
        let runningJob = makeJob(
            id: "job-alpha-running",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let queuedJob = makeJob(
            id: "job-alpha-queued",
            cwd: "/tmp/workspace-alpha",
            status: .queued,
            targetSummary: "Base branch: main"
        )
        let completedAlphaJob = makeJob(
            id: "job-alpha-succeeded",
            cwd: "/tmp/workspace-alpha",
            status: .succeeded,
            targetSummary: "Commit: abc123"
        )
        let completedBetaJob = makeJob(
            id: "job-beta-succeeded",
            cwd: "/tmp/workspace-beta",
            status: .succeeded,
            targetSummary: "Base branch: main"
        )
        let alphaWorkspace = CodexReviewWorkspace(cwd: "/tmp/workspace-alpha")
        let betaWorkspace = CodexReviewWorkspace(cwd: "/tmp/workspace-beta")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [alphaWorkspace, betaWorkspace],
            jobs: [runningJob, queuedJob, completedAlphaJob, completedBetaJob]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        uiState.sidebarJobFilter = .running

        try await waitForObservedValue(
            from: sidebar.sidebarFilterDeliveryForTesting,
            ["job-alpha-running", "job-alpha-queued"]
        ) {
            sidebar.displayedJobIDsForTesting(in: alphaWorkspace)
        }
        #expect(sidebar.displayedSectionTitlesForTesting == [
            "workspace-alpha",
            "workspace-beta",
        ])
        #expect(sidebar.displayedJobIDsForTesting(in: alphaWorkspace) == ["job-alpha-running", "job-alpha-queued"])
        #expect(sidebar.displayedJobIDsForTesting(in: betaWorkspace) == [])
    }

    @Test func sidebarRunningFilterFollowsJobTerminalStateChanges() async throws {
        let runningJob = makeJob(
            id: "job-filter-state",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let workspace = CodexReviewWorkspace(cwd: "/tmp/workspace-alpha")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            jobs: [runningJob]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarJobFilter = .running
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.displayedJobIDsForTesting(in: workspace) == ["job-filter-state"])

        runningJob.core.lifecycle.status = .succeeded
        runningJob.core.lifecycle.endedAt = Date(timeIntervalSince1970: 201)
        try await waitForObservedValue(
            from: sidebar.sidebarTopologyDeliveryForTesting,
            [String]()
        ) {
            sidebar.displayedJobIDsForTesting(in: workspace)
        }

        runningJob.core.lifecycle.status = .running
        runningJob.core.lifecycle.endedAt = nil
        try await waitForObservedValue(
            from: sidebar.sidebarTopologyDeliveryForTesting,
            ["job-filter-state"]
        ) {
            sidebar.displayedJobIDsForTesting(in: workspace)
        }
    }

    @Test func sidebarRunningFilterDoesNotClearHiddenSelectedJob() async throws {
        let runningJob = makeJob(
            id: "job-filter-running",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let completedJob = makeJob(
            id: "job-filter-completed",
            cwd: "/tmp/workspace-alpha",
            status: .succeeded,
            targetSummary: "Commit: abc123"
        )
        let workspace = CodexReviewWorkspace(cwd: "/tmp/workspace-alpha")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            jobs: [runningJob, completedJob]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.selectJobForTesting(completedJob)
        #expect(sidebar.selectedJobForTesting?.id == "job-filter-completed")

        uiState.sidebarJobFilter = .running
        try await waitForObservedValue(
            from: sidebar.sidebarFilterDeliveryForTesting,
            ["job-filter-running"]
        ) {
            sidebar.displayedJobIDsForTesting(in: workspace)
        }

        #expect(sidebar.displayedJobIDsForTesting(in: workspace) == ["job-filter-running"])
        #expect(sidebar.selectedJobForTesting?.id == "job-filter-completed")
    }

    @Test func jobDropWhileFilteredMapsVisibleIndexToStoreOrder() async throws {
        let hiddenPrefix = makeJob(
            id: "job-hidden-prefix",
            cwd: "/tmp/workspace-alpha",
            status: .succeeded,
            targetSummary: "Completed prefix"
        )
        let runningA = makeJob(
            id: "job-running-a",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Running A"
        )
        let hiddenMiddle = makeJob(
            id: "job-hidden-middle",
            cwd: "/tmp/workspace-alpha",
            status: .failed,
            targetSummary: "Failed middle"
        )
        let runningB = makeJob(
            id: "job-running-b",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Running B"
        )
        let hiddenSuffix = makeJob(
            id: "job-hidden-suffix",
            cwd: "/tmp/workspace-alpha",
            status: .succeeded,
            targetSummary: "Completed suffix"
        )
        let workspace = CodexReviewWorkspace(cwd: "/tmp/workspace-alpha")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            jobs: [hiddenPrefix, runningA, hiddenMiddle, runningB, hiddenSuffix]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarJobFilter = .running
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.displayedJobIDsForTesting(in: workspace) == ["job-running-a", "job-running-b"])

        #expect(sidebar.performJobDropForTesting(runningA, proposedWorkspace: workspace, childIndex: 1))
        await Task.yield()

        #expect(sidebar.displayedJobIDsForTesting(in: workspace) == ["job-running-a", "job-running-b"])
        #expect(store.orderedJobs(in: workspace).map(\.id) == [
            "job-hidden-prefix",
            "job-running-a",
            "job-hidden-middle",
            "job-running-b",
            "job-hidden-suffix",
        ])

        #expect(sidebar.performJobDropForTesting(runningA, proposedWorkspace: workspace, childIndex: 2))
        await Task.yield()

        #expect(sidebar.displayedJobIDsForTesting(in: workspace) == ["job-running-b", "job-running-a"])
        #expect(store.orderedJobs(in: workspace).map(\.id) == [
            "job-hidden-prefix",
            "job-hidden-middle",
            "job-running-b",
            "job-running-a",
            "job-hidden-suffix",
        ])
    }

    @Test func jobSameMembershipSortOrderChangeMovesRowsWithoutReloadingWorkspace() async throws {
        let firstJob = makeJob(
            id: "job-sort-order-1",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let secondJob = makeJob(
            id: "job-sort-order-2",
            cwd: "/tmp/workspace-alpha",
            status: .succeeded,
            targetSummary: "Commit: abc123"
        )
        let workspace = CodexReviewWorkspace(cwd: "/tmp/workspace-alpha")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            jobs: [firstJob, secondJob]
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        let fullReloadCountBeforeChange = sidebar.sidebarFullReloadCountForTesting
        let workspaceReloadCountBeforeChange = sidebar.sidebarWorkspaceReloadCountForTesting
        let incrementalMoveCountBeforeChange = sidebar.sidebarIncrementalMoveCountForTesting
        let incrementalMembershipChangeCountBeforeChange = sidebar.sidebarIncrementalMembershipChangeCountForTesting

        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            jobs: [secondJob, firstJob]
        )
        try await waitForObservedValue(
            from: sidebar.sidebarTopologyDeliveryForTesting,
            [
                "job-sort-order-2",
                "job-sort-order-1",
            ]
        ) {
            sidebar.displayedJobIDsForTesting(in: workspace)
        }

        #expect(sidebar.sidebarFullReloadCountForTesting == fullReloadCountBeforeChange)
        #expect(sidebar.sidebarWorkspaceReloadCountForTesting == workspaceReloadCountBeforeChange)
        #expect(sidebar.sidebarIncrementalMembershipChangeCountForTesting == incrementalMembershipChangeCountBeforeChange)
        #expect(sidebar.sidebarIncrementalMoveCountForTesting == incrementalMoveCountBeforeChange + 1)
    }

    @Test func workspaceJobsChangeUsesChildInsertWithoutReload() async throws {
        let firstJob = makeJob(
            id: "job-membership-1",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let secondJob = makeJob(
            id: "job-membership-2",
            cwd: "/tmp/workspace-alpha",
            status: .queued,
            targetSummary: "Queued review"
        )
        let workspace = CodexReviewWorkspace(cwd: "/tmp/workspace-alpha")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            jobs: [firstJob]
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        let fullReloadCountBeforeChange = sidebar.sidebarFullReloadCountForTesting
        let workspaceReloadCountBeforeChange = sidebar.sidebarWorkspaceReloadCountForTesting
        let incrementalMoveCountBeforeChange = sidebar.sidebarIncrementalMoveCountForTesting
        let incrementalMembershipChangeCountBeforeChange = sidebar.sidebarIncrementalMembershipChangeCountForTesting

        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            jobs: [firstJob, secondJob]
        )
        try await waitForObservedValue(
            from: sidebar.sidebarTopologyDeliveryForTesting,
            [
                "job-membership-1",
                "job-membership-2",
            ]
        ) {
            sidebar.displayedJobIDsForTesting(in: workspace)
        }

        #expect(sidebar.displayedJobIDsForTesting(in: workspace) == ["job-membership-1", "job-membership-2"])
        #expect(sidebar.sidebarFullReloadCountForTesting == fullReloadCountBeforeChange)
        #expect(sidebar.sidebarWorkspaceReloadCountForTesting == workspaceReloadCountBeforeChange)
        #expect(sidebar.sidebarIncrementalMembershipChangeCountForTesting == incrementalMembershipChangeCountBeforeChange + 1)
        #expect(sidebar.sidebarIncrementalMoveCountForTesting == incrementalMoveCountBeforeChange)
    }

    @Test func addAccountToolbarItemShowsProgressPresentation() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let activeAccount = CodexAccount(email: "first@example.com", planType: "pro")
        store.loadForTesting(
            serverState: .running,
            authPhase: .signingIn(
                .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue."
                )
            ),
            account: activeAccount,
            persistedAccounts: [activeAccount],
            workspaces: []
        )

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

        #expect(viewController.addAccountToolbarItemModeForTesting == .progress)
    }

    @Test func addAccountToolbarItemDoesNotStickInProgressModeWhenAuthenticationEndsImmediately() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let activeAccount = CodexAccount(email: "first@example.com", planType: "pro")
        store.loadForTesting(
            serverState: .running,
            authPhase: .signedOut,
            account: activeAccount,
            persistedAccounts: [activeAccount],
            workspaces: []
        )

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
        let activeAccount = CodexAccount(email: "first@example.com", planType: "pro")
        store.loadForTesting(
            serverState: .running,
            authPhase: .signedOut,
            account: activeAccount,
            persistedAccounts: [activeAccount],
            workspaces: []
        )

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
        let activeAccount = CodexAccount(email: "first@example.com", planType: "pro")
        store.loadForTesting(
            serverState: .running,
            authPhase: .signingIn(
                .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue."
                )
            ),
            account: activeAccount,
            persistedAccounts: [activeAccount],
            workspaces: []
        )

        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .workspace
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
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
        let activeAccount = CodexAccount(email: "first@example.com", planType: "pro")
        store.loadForTesting(
            serverState: .running,
            authPhase: .signingIn(
                .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue."
                )
            ),
            account: activeAccount,
            persistedAccounts: [activeAccount],
            workspaces: []
        )

        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .workspace
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
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
        let activeAccount = CodexAccount(email: "active@example.com", planType: "pro")
        let otherAccount = CodexAccount(email: "other@example.com", planType: "plus")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            account: activeAccount,
            persistedAccounts: [activeAccount, otherAccount],
            workspaces: []
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        let accountsViewController = viewController
            .sidebarViewControllerForTesting
            .accountsViewControllerForTesting
        let displayedActiveAccount = try #require(
            store.auth.persistedAccounts.first { $0.email == "active@example.com" }
        )

        #expect(accountsViewController.accountListUsesOutlineViewForTesting)
        #expect(accountsViewController.displayedAccountEmailsForTesting == [
            "active@example.com",
            "other@example.com",
        ])
        #expect(accountsViewController.accountRowUsesReviewMonitorAccountCellViewForTesting(displayedActiveAccount))
        #expect(accountsViewController.accountRowUsesSwiftUIRowViewForTesting(displayedActiveAccount))
    }

    @Test func accountDropReordersToDisplayedGapForDownwardMove() async throws {
        let firstAccount = CodexAccount(email: "first@example.com", planType: "pro")
        let secondAccount = CodexAccount(email: "second@example.com", planType: "plus")
        let thirdAccount = CodexAccount(email: "third@example.com", planType: "team")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            account: firstAccount,
            persistedAccounts: [firstAccount, secondAccount, thirdAccount],
            workspaces: []
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
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

        #expect(await accountsViewController.performAccountDropForTesting(
            displayedFirstAccount,
            proposedChildIndex: 2
        ))
        #expect(store.auth.persistedAccounts.map(\.email) == [
            "second@example.com",
            "first@example.com",
            "third@example.com",
        ])
        try await waitForObservedValue(
            from: accountsViewController.accountListDeliveryForTesting,
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
            accountsViewController.accountIncrementalMembershipChangeCountForTesting ==
                incrementalMembershipChangeCountBeforeDrop
        )
        #expect(accountsViewController.accountIncrementalMoveCountForTesting == incrementalMoveCountBeforeDrop + 1)
    }

    @Test func accountDropBeforeDetachedCurrentSessionMovesToLastSavedPosition() async throws {
        let firstAccount = CodexAccount(email: "first@example.com", planType: "pro")
        let secondAccount = CodexAccount(email: "second@example.com", planType: "plus")
        let detachedAccount = CodexAccount(email: "detached@example.com", planType: "team")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            account: detachedAccount,
            persistedAccounts: [firstAccount, secondAccount],
            workspaces: []
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        let accountsViewController = viewController
            .sidebarViewControllerForTesting
            .accountsViewControllerForTesting
        let displayedFirstAccount = try #require(
            store.auth.persistedAccounts.first { $0.email == "first@example.com" }
        )

        #expect(accountsViewController.displayedAccountEmailsForTesting == [
            "first@example.com",
            "second@example.com",
            "detached@example.com",
        ])
        #expect(await accountsViewController.performAccountDropForTesting(
            displayedFirstAccount,
            proposedItem: detachedAccount,
            proposedChildIndex: NSOutlineViewDropOnItemIndex
        ))
        #expect(store.auth.persistedAccounts.map(\.email) == [
            "second@example.com",
            "first@example.com",
        ])
        try await waitForObservedValue(
            from: accountsViewController.accountListDeliveryForTesting,
            [
                "second@example.com",
                "first@example.com",
                "detached@example.com",
            ]
        ) {
            accountsViewController.displayedAccountEmailsForTesting
        }
        #expect(accountsViewController.displayedAccountEmailsForTesting == [
            "second@example.com",
            "first@example.com",
            "detached@example.com",
        ])
    }

    @Test func jobCellViewUpdatesHostedObservationReferenceWithoutReplacingHostingView() throws {
        let placeholderJob = makeJob(
            id: "job-placeholder",
            status: .queued,
            targetSummary: "Queued review"
        )
        let loadedJob = makeJob(
            id: "job-loaded",
            status: .running,
            targetSummary: "Uncommitted changes"
        )

        let cellView = makeReviewMonitorJobCellViewForTesting(job: placeholderJob)
        let initialHostingViewIdentity = try #require(
            reviewMonitorJobCellHostingViewIdentityForTesting(cellView)
        )
        let initialHostedJobID = reviewMonitorJobCellHostedJobIDForTesting(cellView)

        configureReviewMonitorJobCellViewForTesting(cellView, job: loadedJob)

        let updatedHostingViewIdentity = try #require(
            reviewMonitorJobCellHostingViewIdentityForTesting(cellView)
        )
        let updatedHostedJobID = reviewMonitorJobCellHostedJobIDForTesting(cellView)

        #expect(initialHostedJobID == placeholderJob.id)
        #expect(updatedHostedJobID == loadedJob.id)
        #expect(initialHostingViewIdentity == updatedHostingViewIdentity)
        #expect(cellView.objectValue as? CodexReviewJob === loadedJob)
        #expect(cellView.toolTip == loadedJob.cwd)
    }

    @Test func workspaceDropPreservesExpansionState() {
        let alphaJob = makeJob(
            id: "job-alpha",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let betaJob = makeJob(
            id: "job-beta",
            cwd: "/tmp/workspace-beta",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let alphaWorkspace = CodexReviewWorkspace(cwd: alphaJob.cwd)
        let betaWorkspace = CodexReviewWorkspace(cwd: betaJob.cwd)
        betaWorkspace.isExpanded = false

        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [alphaWorkspace, betaWorkspace],
            jobs: [alphaJob, betaJob]
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.performWorkspaceDropForTesting(betaWorkspace, toIndex: 0))
        #expect(sidebar.workspaceIsExpandedForTesting(betaWorkspace) == false)
    }

    @Test func crossWorkspaceJobDropIsRejected() {
        let alphaJob = makeJob(
            id: "job-alpha",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let betaJob = makeJob(
            id: "job-beta",
            cwd: "/tmp/workspace-beta",
            status: .running,
            targetSummary: "Base branch: main"
        )
        let alphaWorkspace = CodexReviewWorkspace(cwd: alphaJob.cwd)
        let betaWorkspace = CodexReviewWorkspace(cwd: betaJob.cwd)
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [alphaWorkspace, betaWorkspace],
            jobs: [alphaJob, betaJob]
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.performJobDropForTesting(alphaJob, proposedWorkspace: betaWorkspace, childIndex: 0) == false)
        #expect(store.orderedJobs(in: alphaWorkspace).map(\.id) == ["job-alpha"])
        #expect(store.orderedJobs(in: betaWorkspace).map(\.id) == ["job-beta"])
    }

    @Test func sidebarWorkspaceRowsStayExpandedAndUseExpectedCellViews() {
        let job = makeJob(
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let workspace = CodexReviewWorkspace(cwd: job.cwd)
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            jobs: [job]
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.allWorkspaceRowsExpandedForTesting)
        #expect(sidebar.workspaceIsSelectableForTesting(workspace))
        #expect(sidebar.floatsGroupRowsEnabledForTesting == false)
        #expect(sidebar.draggingDestinationFeedbackStyleForTesting == .sourceList)
        #expect(sidebar.sidebarUsesAutomaticRowHeightsForTesting == false)
        #expect(sidebar.jobRowUsesReviewMonitorJobRowViewForTesting(job))
    }

    @Test func sidebarUsesMeasuredRowHeightsForWorkspaceAndJobRows() throws {
        let job = makeJob(
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let workspace = CodexReviewWorkspace(cwd: job.cwd)
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            jobs: [job]
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 360, height: 260))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        let workspaceRowHeight = try #require(sidebar.workspaceRowHeightForTesting(workspace))
        let jobRowHeight = try #require(sidebar.jobRowHeightForTesting(job))
        #expect(workspaceRowHeight == sidebar.expectedWorkspaceRowRectHeightForTesting)
        #expect(jobRowHeight == sidebar.expectedJobRowRectHeightForTesting)
        #expect(workspaceRowHeight < jobRowHeight)
    }

    @Test func jobRowsUseLabelIconSlotInsteadOfOutlineChildIndent() throws {
        let job = makeJob(
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let workspace = CodexReviewWorkspace(cwd: job.cwd)
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            jobs: [job]
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 360, height: 260))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        let workspaceCellMinX = try #require(sidebar.workspaceCellMinXForTesting(workspace))
        let jobCellMinX = try #require(sidebar.jobCellMinXForTesting(job))
        #expect(jobCellMinX < workspaceCellMinX)
    }

    @Test func workspaceContentStartsAfterNativeDisclosureGutter() throws {
        let job = makeJob(
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let workspace = CodexReviewWorkspace(cwd: job.cwd)
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            jobs: [job]
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 360, height: 260))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        let workspaceCellMinX = try #require(sidebar.workspaceCellMinXForTesting(workspace))
        let disclosureMaxX = try #require(sidebar.workspaceDisclosureMaxXForTesting(workspace))
        #expect(workspaceCellMinX >= disclosureMaxX - 0.5)
    }

    @Test func workspaceDisclosureStaysNativeWhenWorkspaceHasNoJobs() throws {
        let workspace = CodexReviewWorkspace(cwd: "/tmp/workspace-alpha")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            jobs: []
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 360, height: 260))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.displayedSectionTitlesForTesting == ["workspace-alpha"])
        #expect(sidebar.displayedJobIDsForTesting(in: workspace) == [])
        #expect(sidebar.isShowingEmptyStateForTesting == false)
        let workspaceCellMinX = try #require(sidebar.workspaceCellMinXForTesting(workspace))
        let disclosureMaxX = try #require(sidebar.workspaceDisclosureMaxXForTesting(workspace))
        #expect(workspaceCellMinX >= disclosureMaxX - 0.5)
    }

    @Test func scrollingSidebarDoesNotFloatWorkspaceRows() throws {
        let primaryJobs = (0..<8).map { index in
            makeJob(
                id: "job-\(index)",
                cwd: "/tmp/workspace-alpha",
                status: .running,
                targetSummary: "Review \(index)"
            )
        }
        let secondaryJob = makeJob(
            id: "job-secondary",
            cwd: "/tmp/workspace-beta",
            status: .queued,
            targetSummary: "Queued review"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [secondaryJob] + primaryJobs)
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 360, height: 220))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let workspace = try #require(store.workspaces.first(where: { $0.cwd == "/tmp/workspace-alpha" }))
        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.scrollSidebarToOffsetForTesting(80)

        #expect(sidebar.workspaceRowIsFloatingForTesting(workspace) == false)
    }

    @Test func sidebarDoesNotAddBlankScrollWhenRowsFitVisibleArea() {
        let jobs = (0..<2).map { index in
            makeJob(
                id: "job-\(index)",
                cwd: "/tmp/workspace-alpha",
                status: .running,
                targetSummary: "Review \(index)"
            )
        }
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: jobs)
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 360, height: 320))
        viewController.loadViewIfNeeded()
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting

        #expect(sidebar.sidebarOutlineContentHeightForTesting < sidebar.sidebarVisibleHeightForTesting)
        #expect(sidebar.sidebarMaximumVerticalScrollOffsetForTesting < 0.5)
    }

    @Test func sidebarTopRowIsFullyVisibleAtMinimumScrollOffset() {
        let jobs = (0..<12).map { index in
            makeJob(
                id: "job-\(index)",
                cwd: "/tmp/workspace-alpha",
                status: .running,
                targetSummary: "Review \(index)"
            )
        }
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: jobs)
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 360, height: 220))
        viewController.loadViewIfNeeded()
        viewController.attach(to: window)
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.scrollSidebarToOffsetForTesting(0)

        #expect(sidebar.sidebarFirstRowRectForTesting.minY >= sidebar.sidebarVisibleRectForTesting.minY - 0.5)
        #expect(sidebar.sidebarFirstRowRectForTesting.maxY <= sidebar.sidebarVisibleRectForTesting.maxY + 0.5)
    }

    @Test func sidebarBottomRowRemainsVisibleAtMaximumScrollOffset() {
        let jobs = (0..<12).map { index in
            makeJob(
                id: "job-\(index)",
                cwd: "/tmp/workspace-alpha",
                status: .running,
                targetSummary: "Review \(index)"
            )
        }
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: jobs)
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 360, height: 220))
        viewController.loadViewIfNeeded()
        viewController.attach(to: window)
        window.layoutIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.scrollSidebarToOffsetForTesting(10_000)

        #expect(sidebar.sidebarLastRowRectForTesting.maxY <= sidebar.sidebarVisibleRectForTesting.maxY + 0.5)
    }

    @Test func nativeWorkspaceDisclosureKeepsModelAndOutlineExpansionInSync() async throws {
        let job = makeJob(
            id: "job-selected",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Review is still running.",
            logText: "Selected log\n"
        )
        let workspace = CodexReviewWorkspace(cwd: job.cwd)
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            jobs: [job]
        )
        let storedWorkspace = try #require(store.workspaces.first)
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        sidebar.collapseWorkspaceInOutlineForTesting(storedWorkspace)
        try await waitForCondition {
            sidebar.workspaceIsExpandedForTesting(storedWorkspace) == false
                && sidebar.workspaceOutlineIsExpandedForTesting(storedWorkspace) == false
        }

        sidebar.expandWorkspaceInOutlineForTesting(storedWorkspace)
        try await waitForCondition {
            sidebar.workspaceIsExpandedForTesting(storedWorkspace)
                && sidebar.workspaceOutlineIsExpandedForTesting(storedWorkspace)
                && sidebar.selectedOutlineJobIDForTesting == job.id
        }
    }

    @Test func collapsedWorkspaceStaysCollapsedAcrossStoreReload() throws {
        let job = makeJob(
            id: "job-1",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [job])
        )
        let workspace = try #require(store.workspaces.first(where: { $0.cwd == job.cwd }))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.toggleWorkspaceDisclosureForTesting(workspace)
        #expect(sidebar.workspaceIsExpandedForTesting(workspace) == false)

        let replacement = makeJob(
            id: "job-2",
            cwd: job.cwd,
            status: .succeeded,
            targetSummary: "Commit: abc123"
        )
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [replacement])
        )

        let reloadedWorkspace = try #require(store.workspaces.first(where: { $0.cwd == job.cwd }))
        #expect(sidebar.workspaceIsExpandedForTesting(reloadedWorkspace) == false)
    }

    @Test func cancellingRunningJobFromSidebarMarksJobCancelled() async throws {
        let startedAt = Date(timeIntervalSince1970: 200)
        let job = makeJob(
            id: "job-running",
            cwd: "/tmp/workspace-alpha",
            startedAt: startedAt,
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review."
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [job])
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        await viewController.sidebarViewControllerForTesting.cancelJobForTesting(job)

        #expect(job.core.lifecycle.status == .cancelled)
        #expect(job.core.output.summary == "Cancelled by user from Review Monitor.")
        #expect(job.core.lifecycle.errorMessage == "Cancelled by user from Review Monitor.")
        #expect(job.core.lifecycle.cancellation?.source == .userInterface)
        #expect(job.core.lifecycle.cancellation?.message == "Cancelled by user from Review Monitor.")
        #expect(job.core.lifecycle.startedAt == startedAt)
        #expect(job.core.lifecycle.endedAt != nil)
    }

    @Test func cancellationFailureUpdatesJobErrorState() async {
        let job = makeJob(
            id: "job-running",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review."
        )
        let store = CodexReviewStore.makeTestingStore(backend: FailingCancellationBackend())
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [job])
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        await viewController.sidebarViewControllerForTesting.cancelJobForTesting(job)

        #expect(job.core.lifecycle.status == .running)
        #expect(job.core.output.summary == "Failed to cancel review: Cancellation failed.")
        #expect(job.core.lifecycle.errorMessage == "Cancellation failed.")
        #expect(job.core.lifecycle.endedAt == nil)
    }

    @Test func sidebarContextMenuPresentationRestoresResponderStateAfterClosing() {
        let job = makeJob(
            id: "job-running",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review."
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [job])
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.focusSidebarForTesting()

        #expect(sidebar.sidebarHasFirstResponderForTesting)
        #expect(sidebar.acceptsFirstResponderForTesting)
        #expect(sidebar.hasTemporaryContextMenuForTesting == false)

        var presentedTitles: [String] = []
        sidebar.presentContextMenuForTesting(for: job) { menu in
            presentedTitles = menu.items.map(\.title)
            #expect(sidebar.isPresentingContextMenuForTesting)
            #expect(sidebar.acceptsFirstResponderForTesting == false)
            #expect(sidebar.sidebarHasFirstResponderForTesting == false)
            #expect(sidebar.hasTemporaryContextMenuForTesting)
        }

        #expect(presentedTitles == ["Cancel"])
        #expect(sidebar.isPresentingContextMenuForTesting == false)
        #expect(sidebar.acceptsFirstResponderForTesting)
        #expect(sidebar.sidebarHasFirstResponderForTesting)
        #expect(sidebar.hasTemporaryContextMenuForTesting == false)
    }

    @Test func accountContextMenuPresentationRestoresResponderStateAfterClosing() throws {
        let activeAccount = CodexAccount(email: "active@example.com", planType: "pro")
        let otherAccount = CodexAccount(email: "other@example.com", planType: "plus")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            account: activeAccount,
            persistedAccounts: [activeAccount, otherAccount],
            workspaces: []
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
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

        #expect(presentedTitles == [
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
        let activeAccount = CodexAccount(email: "active@example.com", planType: "pro")
        let otherAccount = CodexAccount(email: "other@example.com", planType: "plus")
        let backend = AuthActionBackend()
        let store = makeStore(backend: backend)
        store.loadForTesting(
            serverState: .running,
            account: activeAccount,
            persistedAccounts: [activeAccount, otherAccount],
            workspaces: []
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
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
            from: accountsViewController.accountSelectionDeliveryForTesting,
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
        let activeAccount = CodexAccount(email: "active@example.com", planType: "pro")
        let otherAccount = CodexAccount(email: "other@example.com", planType: "plus")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            account: activeAccount,
            persistedAccounts: [activeAccount, otherAccount],
            workspaces: []
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        let accountsViewController = viewController
            .sidebarViewControllerForTesting
            .accountsViewControllerForTesting
        let displayedOtherAccount = try #require(
            store.auth.persistedAccounts.first { $0.email == "other@example.com" }
        )
        try await waitForObservedValue(
            from: accountsViewController.accountSelectionDeliveryForTesting,
            true
        ) {
            accountsViewController.selectedAccountEmailForTesting == "active@example.com"
        }

        #expect(accountsViewController.dragPasteboardAccountKeyForTesting(displayedOtherAccount) == displayedOtherAccount.accountKey)
        #expect(accountsViewController.selectedAccountEmailForTesting == "active@example.com")
        #expect(store.auth.selectedAccount?.email == "active@example.com")
    }

    @Test func accountBlankClickKeepsAuthenticatedSelection() async throws {
        let activeAccount = CodexAccount(email: "active@example.com", planType: "pro")
        let otherAccount = CodexAccount(email: "other@example.com", planType: "plus")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            account: activeAccount,
            persistedAccounts: [activeAccount, otherAccount],
            workspaces: []
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let accountsViewController = viewController
            .sidebarViewControllerForTesting
            .accountsViewControllerForTesting
        try await waitForObservedValue(
            from: accountsViewController.accountSelectionDeliveryForTesting,
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
        let activeAccount = CodexAccount(email: "active@example.com", planType: "pro")
        let otherAccount = CodexAccount(email: "other@example.com", planType: "plus")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            account: activeAccount,
            persistedAccounts: [activeAccount, otherAccount],
            workspaces: []
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
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
            from: accountsViewController.accountSelectionDeliveryForTesting,
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
            from: accountsViewController.accountSelectionDeliveryForTesting,
            true
        ) {
            accountsViewController.selectedAccountEmailForTesting == "other@example.com"
        }

        #expect(accountsViewController.selectedAccountEmailForTesting == "other@example.com")
        #expect(accountsViewController.displayedAccountEmailsForTesting == displayedEmails)
        #expect(accountsViewController.accountFullReloadCountForTesting == fullReloadCountBeforeSelectionChange)
        #expect(
            accountsViewController.accountIncrementalMembershipChangeCountForTesting ==
                incrementalMembershipChangeCountBeforeSelectionChange
        )
        #expect(accountsViewController.accountIncrementalMoveCountForTesting == incrementalMoveCountBeforeSelectionChange)
    }

    @Test func accountContentUpdateDoesNotReloadOutlineTopology() async throws {
        let activeAccount = CodexAccount(email: "active@example.com", planType: "pro")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            account: activeAccount,
            persistedAccounts: [activeAccount],
            workspaces: []
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        let accountsViewController = viewController
            .sidebarViewControllerForTesting
            .accountsViewControllerForTesting
        let displayedActiveAccount = try #require(store.auth.persistedAccounts.first)
        let fullReloadCountBeforeUpdate = accountsViewController.accountFullReloadCountForTesting
        let incrementalMembershipChangeCountBeforeUpdate = accountsViewController
            .accountIncrementalMembershipChangeCountForTesting
        let incrementalMoveCountBeforeUpdate = accountsViewController.accountIncrementalMoveCountForTesting

        let updatedAccount = CodexAccount(email: "active@example.com", planType: "team")
        store.auth.applyPersistedAccountStates([savedAccountPayload(from: updatedAccount)])
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(store.auth.persistedAccounts.first === displayedActiveAccount)
        #expect(store.auth.persistedAccounts.first?.planType == "team")
        #expect(accountsViewController.displayedAccountEmailsForTesting == ["active@example.com"])
        #expect(accountsViewController.accountFullReloadCountForTesting == fullReloadCountBeforeUpdate)
        #expect(
            accountsViewController.accountIncrementalMembershipChangeCountForTesting ==
                incrementalMembershipChangeCountBeforeUpdate
        )
        #expect(accountsViewController.accountIncrementalMoveCountForTesting == incrementalMoveCountBeforeUpdate)
    }

    @Test func accountListTracksDetachedCurrentSessionMembership() async throws {
        let savedAccount = CodexAccount(email: "saved@example.com", planType: "pro")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            account: savedAccount,
            persistedAccounts: [savedAccount],
            workspaces: []
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
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

        store.auth.updateCurrentAccount(CodexAccount(email: "detached@example.com", planType: "pro"))
        try await waitForObservedValue(
            from: accountsViewController.accountListDeliveryForTesting,
            [
                "saved@example.com",
                "detached@example.com",
            ]
        ) {
            accountsViewController.displayedAccountEmailsForTesting
        }

        #expect(accountsViewController.displayedAccountEmailsForTesting == [
            "saved@example.com",
            "detached@example.com",
        ])
        #expect(accountsViewController.selectedAccountEmailForTesting == "detached@example.com")
        #expect(accountsViewController.accountFullReloadCountForTesting == fullReloadCountBeforeMembershipChanges)
        #expect(
            accountsViewController.accountIncrementalMembershipChangeCountForTesting ==
                incrementalMembershipChangeCountBeforeMembershipChanges + 1
        )
        #expect(accountsViewController.accountIncrementalMoveCountForTesting == incrementalMoveCountBeforeMembershipChanges)

        store.auth.selectPersistedAccount(savedAccount.accountKey)
        try await waitForObservedValue(
            from: accountsViewController.accountListDeliveryForTesting,
            ["saved@example.com"]
        ) {
            accountsViewController.displayedAccountEmailsForTesting
        }

        #expect(accountsViewController.displayedAccountEmailsForTesting == ["saved@example.com"])
        #expect(accountsViewController.selectedAccountEmailForTesting == "saved@example.com")
        #expect(accountsViewController.accountFullReloadCountForTesting == fullReloadCountBeforeMembershipChanges)
        #expect(
            accountsViewController.accountIncrementalMembershipChangeCountForTesting ==
                incrementalMembershipChangeCountBeforeMembershipChanges + 2
        )
        #expect(accountsViewController.accountIncrementalMoveCountForTesting == incrementalMoveCountBeforeMembershipChanges)
    }

    @Test func accountActionAlertRestoresSelectionToAuthenticatedAccount() async throws {
        let activeAccount = CodexAccount(email: "active@example.com", planType: "pro")
        let otherAccount = CodexAccount(email: "other@example.com", planType: "plus")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            account: activeAccount,
            persistedAccounts: [activeAccount, otherAccount],
            workspaces: []
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarSelection = .account
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
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
            from: accountsViewController.accountPromptDeliveryForTesting,
            true
        ) {
            accountsViewController.selectedAccountEmailForTesting == "active@example.com"
        }

        #expect(accountsViewController.selectedAccountEmailForTesting == "active@example.com")
    }

    @Test func jobsPresentOnInitialLoadStayUnselected() {
        let activeJob = makeJob(status: .running, targetSummary: "Uncommitted changes")
        let recentJob = makeJob(status: .succeeded, targetSummary: "Commit: abc123")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [activeJob, recentJob])
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarViewControllerForTesting.selectedJobForTesting == nil)
        #expect(viewController.contentPaneViewControllerForTesting.isShowingEmptyStateForTesting)
        #expect(viewController.contentPaneViewControllerForTesting.displayedTitleForTesting == nil)
    }

    @Test func selectingJobUpdatesDetailPane() async throws {
        let activeJob = makeJob(status: .running, targetSummary: "Uncommitted changes", logText: "Running review\n")
        let recentJob = makeJob(
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "MCP server codex_review ready.",
            logText: "Findings ready\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [activeJob, recentJob])
        )
        let backend = makeWindowHarness(store: store)
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(recentJob)

        let selectedSnapshot = try await awaitTransportRender(transport)
        #expect(
            selectedSnapshot == .init(
                title: nil,
                summary: nil,
                log: recentJob.logText,
                isShowingEmptyState: false
            )
        )
        #expect(window.title == recentJob.targetSummary)
        #expect(window.subtitle == recentJob.cwd)
        #expect(transport.logUsesFindBarForTesting)
        #expect(transport.logIsIncrementalSearchingEnabledForTesting)
        #expect(transport.logFindBarVisibleForTesting == false)

        let findItem = textFinderMenuItemForTesting(.showFindInterface)
        #expect(viewController.validateUserInterfaceItem(findItem))
        viewController.performTextFinderAction(findItem)
        #expect(transport.logFindBarVisibleForTesting)

        recentJob.targetSummary = "Commit: def456"
        try await waitForCondition {
            window.title == "Commit: def456"
        }
        #expect(window.title == "Commit: def456")
        #expect(window.subtitle == recentJob.cwd)
        activeJob.core.output.summary = "Old selection should not render."
        activeJob.replaceLogEntries([.init(kind: .agentMessage, text: "Old selection log")])
        recentJob.appendLogEntry(.init(kind: .progress, text: "Current selection log after stale mutation"))

        let updatedSnapshot = try await awaitTransportRender(transport) { snapshot in
            snapshot.log.contains("Current selection log after stale mutation")
        }
        #expect(updatedSnapshot.log.contains("Old selection log") == false)
        #expect(transport.displayedLogForTesting.contains("Old selection log") == false)
    }

    @Test func selectingWorkspaceShowsStructuredFindings() async throws {
        let workspaceCWD = "/tmp/workspace-alpha"
        let firstJob = makeJob(
            id: "job-first-findings",
            cwd: workspaceCWD,
            status: .succeeded,
            targetSummary: "Commit: abc123",
            reviewResult: .init(
                state: .hasFindings,
                findingCount: 2,
                findings: [
                    .init(
                        title: "[P0] Stop stale undo commands",
                        body: "Queued undo work must be cancelled before clearing history.",
                        priority: 0,
                        location: nil,
                        rawText: ""
                    ),
                    .init(
                        title: "[P1] Preserve selection identity",
                        body: "The sidebar should resolve the selected workspace by cwd after reload.",
                        priority: 1,
                        location: .init(
                            path: "\(workspaceCWD)/Sources/Sidebar.swift",
                            startLine: 10,
                            endLine: 12
                        ),
                        rawText: ""
                    )
                ],
                source: .parsedFinalReviewText
            )
        )
        let secondJob = makeJob(
            id: "job-second-findings",
            cwd: workspaceCWD,
            status: .succeeded,
            targetSummary: "Branch: workspace-detail",
            reviewResult: .init(
                state: .hasFindings,
                findingCount: 1,
                findings: [
                    .init(
                        title: "[P2] Render workspace findings",
                        body: "The detail pane should aggregate structured findings without parsing logs.",
                        priority: 2,
                        location: .init(
                            path: "/tmp/workspace-alpha-other/Other.swift",
                            startLine: 5,
                            endLine: 5
                        ),
                        rawText: ""
                    )
                ],
                source: .parsedFinalReviewText
            )
        )
        let workspace = CodexReviewWorkspace(cwd: workspaceCWD)
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, workspaces: [workspace], jobs: [firstJob, secondJob])
        let backend = makeWindowHarness(store: store)
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectWorkspaceForTesting(workspace)

        _ = try await awaitTransportRender(transport)
        #expect(viewController.sidebarViewControllerForTesting.selectedWorkspaceForTesting?.cwd == workspaceCWD)
        #expect(viewController.sidebarViewControllerForTesting.selectedJobForTesting == nil)
        #expect(transport.workspaceFindingsTextIsSelectableForTesting)
        #expect(transport.workspaceFindingsTextIsEditableForTesting == false)
        #expect(transport.workspaceFindingsUsesFindBarForTesting)
        #expect(transport.workspaceFindingsIsIncrementalSearchingEnabledForTesting)
        #expect(transport.workspaceFindingsFindBarVisibleForTesting == false)
        #expect(transport.workspaceFindingsThreadBackgroundRangeCountForTesting == 2)
        #expect(transport.workspaceFindingsAccessibilityValueForTesting?.isEmpty == false)
        #expect(transport.workspaceFindingSnapshotForTesting.text.isEmpty == false)
        #expect(transport.workspaceFindingSnapshotForTesting.isShowingNoFindingsState == false)
        #expect(transport.workspaceFindingSnapshotForTesting.isShowingFindingsList)
        #expect(window.title == workspace.displayTitle)
        #expect(window.subtitle == workspace.cwd)

        let findItem = textFinderMenuItemForTesting(.showFindInterface)
        #expect(viewController.validateUserInterfaceItem(findItem))
        viewController.performTextFinderAction(findItem)
        #expect(transport.workspaceFindingsFindBarVisibleForTesting)
    }

    @Test func workspaceFindingsTextWrapsWithinDetailWidth() async throws {
        let workspaceCWD = "/tmp/workspace-alpha"
        let longBody = Array(repeating: "structured finding text should wrap inside the detail pane", count: 12)
            .joined(separator: " ")
        let job = makeJob(
            id: "job-long-finding",
            cwd: workspaceCWD,
            status: .succeeded,
            targetSummary: "Branch: long-finding",
            reviewResult: .init(
                state: .hasFindings,
                findingCount: 1,
                findings: [
                    .init(
                        title: "[P2] Keep workspace finding rows constrained to the visible detail width",
                        body: longBody,
                        priority: 2,
                        location: .init(
                            path: "\(workspaceCWD)/Sources/VeryLongFinding.swift",
                            startLine: 42,
                            endLine: 47
                        ),
                        rawText: ""
                    )
                ],
                source: .parsedFinalReviewText
            )
        )
        let workspace = CodexReviewWorkspace(cwd: workspaceCWD)
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, workspaces: [workspace], jobs: [job])
        let backend = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 560, height: 360)
        )
        let viewController = backend.viewController
        defer { backend.window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectWorkspaceForTesting(workspace)

        _ = try await awaitTransportRender(transport)
        let contentWidth = transport.workspaceFindingsContentWidthForTesting
        let textContainerWidth = transport.workspaceFindingsTextContainerWidthForTesting
        #expect(textContainerWidth > 0)
        #expect(textContainerWidth <= contentWidth + 0.5)
    }

    @Test func workspaceFindingsViewExtendsBehindTitlebarWithoutOverlappingSidebar() async throws {
        let workspaceCWD = "/tmp/workspace-alpha"
        let job = makeJob(
            id: "job-finding-layout",
            cwd: workspaceCWD,
            status: .succeeded,
            targetSummary: "Branch: finding-layout",
            reviewResult: .init(
                state: .hasFindings,
                findingCount: 1,
                findings: [
                    .init(
                        title: "[P2] Keep workspace finding rows visible under unified titlebar",
                        body: "Structured finding body",
                        priority: 2,
                        location: nil,
                        rawText: ""
                    )
                ],
                source: .parsedFinalReviewText
            )
        )
        let workspace = CodexReviewWorkspace(cwd: workspaceCWD)
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, workspaces: [workspace], jobs: [job])
        let backend = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 900, height: 600)
        )
        let viewController = backend.viewController
        defer { backend.window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectWorkspaceForTesting(workspace)

        _ = try await awaitTransportRender(transport)
        backend.window.layoutIfNeeded()
        transport.view.layoutSubtreeIfNeeded()

        let findingsFrame = transport.workspaceFindingsFrameForTesting
        let findingsScrollFrame = transport.workspaceFindingsScrollFrameForTesting
        let viewBounds = transport.viewBoundsForTesting
        let safeAreaFrame = transport.safeAreaFrameForTesting
        let contentInsets = transport.workspaceFindingsContentInsetsForTesting

        #expect(abs(findingsFrame.minX - safeAreaFrame.minX) < 0.5)
        #expect(abs(findingsFrame.maxX - safeAreaFrame.maxX) < 0.5)
        #expect(abs(findingsFrame.minY - viewBounds.minY) < 0.5)
        #expect(abs(findingsFrame.maxY - viewBounds.maxY) < 0.5)
        #expect(abs(findingsScrollFrame.minX) < 0.5)
        #expect(abs(findingsScrollFrame.width - findingsFrame.width) < 0.5)
        #expect(abs(findingsScrollFrame.minY) < 0.5)
        #expect(abs(findingsScrollFrame.height - findingsFrame.height) < 0.5)
        #expect(safeAreaFrame.maxY < viewBounds.maxY)
        #expect(transport.workspaceFindingsAutomaticallyAdjustsContentInsetsForTesting)
        #expect(contentInsets.top > 0)
        #expect(abs(transport.workspaceFindingsVerticalScrollOffsetForTesting + contentInsets.top) < 0.5)
        #expect(abs(
            transport.workspaceFindingsMaximumVerticalScrollOffsetForTesting
                - transport.workspaceFindingsMinimumVerticalScrollOffsetForTesting
        ) < 0.5)
    }

    @Test func selectingWorkspaceWithoutStructuredFindingsShowsNoFindingsState() async throws {
        let job = makeJob(
            id: "job-no-findings",
            cwd: "/tmp/workspace-alpha",
            status: .succeeded,
            targetSummary: "Commit: clean",
            reviewResult: .init(
                state: .noFindings,
                findingCount: 0,
                findings: [],
                source: .parsedFinalReviewText
            )
        )
        let workspace = CodexReviewWorkspace(cwd: job.cwd)
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, workspaces: [workspace], jobs: [job])
        let backend = makeWindowHarness(store: store)
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectWorkspaceForTesting(workspace)

        _ = try await awaitTransportRender(transport)
        backend.window.layoutIfNeeded()
        transport.view.layoutSubtreeIfNeeded()

        let findingsFrame = transport.workspaceFindingsFrameForTesting
        let noFindingsPlaceholderFrame = transport.workspaceFindingsNoFindingsFrameForTesting
        let viewBounds = transport.viewBoundsForTesting
        let safeAreaFrame = transport.safeAreaFrameForTesting

        #expect(
            transport.workspaceFindingSnapshotForTesting == .init(
                text: "",
                isShowingNoFindingsState: true,
                isShowingFindingsList: false
            )
        )
        #expect(abs(findingsFrame.minX - safeAreaFrame.minX) < 0.5)
        #expect(abs(findingsFrame.maxX - safeAreaFrame.maxX) < 0.5)
        #expect(abs(findingsFrame.minY - viewBounds.minY) < 0.5)
        #expect(abs(findingsFrame.maxY - viewBounds.maxY) < 0.5)
        #expect(abs(noFindingsPlaceholderFrame.minX - safeAreaFrame.minX) < 0.5)
        #expect(abs(noFindingsPlaceholderFrame.maxX - safeAreaFrame.maxX) < 0.5)
        #expect(abs(noFindingsPlaceholderFrame.minY - viewBounds.minY) < 0.5)
        #expect(abs(noFindingsPlaceholderFrame.maxY - viewBounds.maxY) < 0.5)
        #expect(safeAreaFrame.maxY < viewBounds.maxY)
        #expect(window.title == workspace.displayTitle)
        #expect(window.subtitle == workspace.cwd)
    }

    @Test func workspaceSelectionReloadsByCWDAndClearsWhenWorkspaceDisappears() async throws {
        let job = makeJob(
            id: "job-workspace-selection",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes"
        )
        let workspace = CodexReviewWorkspace(cwd: job.cwd)
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, workspaces: [workspace], jobs: [job])
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let sidebar = viewController.sidebarViewControllerForTesting
        let transport = viewController.transportViewControllerForTesting
        sidebar.selectWorkspaceForTesting(workspace)
        _ = try await awaitTransportRender(transport)

        let replacement = CodexReviewWorkspace(cwd: workspace.cwd)
        let replacementJob = makeJob(
            id: "job-workspace-selection-replacement",
            cwd: workspace.cwd,
            status: .succeeded,
            targetSummary: "Commit: replacement"
        )
        store.loadForTesting(serverState: .running, workspaces: [replacement], jobs: [replacementJob])

        #expect(sidebar.selectedWorkspaceForTesting?.cwd == replacement.cwd)
        #expect(store.orderedJobs(in: replacement).first?.id == "job-workspace-selection-replacement")

        store.loadForTesting(serverState: .running, workspaces: [])
        try await waitForCondition {
            sidebar.selectedWorkspaceForTesting == nil &&
            sidebar.selectedJobForTesting == nil &&
            transport.isShowingEmptyStateForTesting
        }

        #expect(sidebar.selectedWorkspaceForTesting == nil)
        #expect(sidebar.selectedJobForTesting == nil)
        #expect(transport.isShowingEmptyStateForTesting)
    }

    @Test func detailPaneRendersSelectedJobMonitorLogProjection() async throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-monitor-log",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .succeeded,
            startedAt: Date(timeIntervalSince1970: 200),
            endedAt: Date(timeIntervalSince1970: 201),
            summary: "Review completed.",
            hasFinalReview: true,
            lastAgentMessage: "No correctness issues found.",
            logEntries: [
                .init(kind: .command, text: "$ git diff --stat"),
                .init(kind: .commandOutput, groupID: "cmd_1", text: "README.md | 1 +"),
                .init(kind: .agentMessage, text: "No correctness issues found.")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [job])
        )
        let backend = makeWindowHarness(store: store)
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let selectedSnapshot = try await awaitTransportRender(transport)
        #expect(selectedSnapshot.title == nil)
        #expect(selectedSnapshot.summary == nil)
        #expect(window.title == job.targetSummary)
        #expect(window.subtitle == job.cwd)

        let displayedLog = transport.displayedLogForTesting
        #expect(selectedSnapshot.log == displayedLog)
        #expect(displayedLog.contains("$ git diff --stat"))
        #expect(displayedLog.contains("Command output"))
        #expect(displayedLog.contains("Command output - 1 line") == false)
        #expect(displayedLog.contains("README.md | 1 +") == false)
        #expect(displayedLog.contains("No correctness issues found."))
        #expect(transport.logCommandOutputPanelCountForTesting == 1)
        #expect(transport.logExpandedCommandOutputPanelCountForTesting == 0)
        #expect(transport.logCommandOutputPanelUsesTextKit2ForTesting == false)
    }

    @Test func commandOutputRendersCollapsedTextKitPanelAndExpandsInline() async throws {
        let outputText = (1...9)
            .map { "output line \($0)" }
            .joined(separator: "\n")
        let commandMetadata = ReviewLogEntry.Metadata(
            sourceType: "command",
            title: "Ran command for 17s",
            status: "succeeded",
            exitCode: 0
        )
        let job = CodexReviewJob.makeForTesting(
            id: "job-command-output-panel",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            logEntries: [
                .init(kind: .command, groupID: "cmd_1", text: "$ swift test"),
                .init(
                    kind: .commandOutput,
                    groupID: "cmd_1",
                    text: outputText,
                    metadata: commandMetadata
                ),
                .init(kind: .agentMessage, text: "Continuing after the command.")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [job])
        )
        let backend = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 860, height: 520)
        )
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        _ = try await awaitTransportRender(transport)
        #expect(transport.displayedLogForTesting.contains("Ran command for 17s"))
        #expect(transport.displayedLogForTesting.contains("Ran command for 17s - 9 lines") == false)
        #expect(transport.displayedLogForTesting.contains("swift test") == false)
        #expect(transport.displayedLogForTesting.contains("$ swift test") == false)
        #expect(transport.displayedLogForTesting.contains("output line 1") == false)
        let titleRange = (transport.displayedLogForTesting as NSString).range(of: "Ran command for 17s")
        try #require(titleRange.location != NSNotFound)
        #expect(transport.logHitTestTargetsDocumentViewForFirstOccurrenceForTesting("Ran command for 17s"))
        transport.setSelectedLogRangeForTesting(titleRange)
        #expect(transport.logSelectedTextForTesting?.hasPrefix("Ran command for 17") == true)
        #expect(transport.logHitTestTargetsDocumentViewForFirstOccurrenceForTesting("Ran command for 17s"))
        #expect(transport.logCommandOutputPanelCountForTesting == 1)
        #expect(transport.logExpandedCommandOutputPanelCountForTesting == 0)
        #expect(transport.logCommandOutputPanelToggleSymbolNameForTesting == "chevron.forward")
        #expect(abs(transport.logCommandOutputPanelChevronSizeDeltaForTesting ?? .infinity) <= 1)
        #expect(abs(transport.logCommandOutputPanelChevronVerticalAlignmentDeltaForTesting ?? .infinity) <= 0.5)
        #expect(transport.logCommandOutputPanelUsesInlineAttachmentForTesting)
        #expect(transport.logCommandOutputPanelUsesButtonAttachmentForTesting)
        #expect(transport.logCommandOutputPanelUsesSystemMaterialBackgroundForTesting == false)
        #expect(transport.logCommandOutputPanelUsesTextKit2ForTesting == false)

        #expect(transport.clickFirstLogCommandOutputPanelHeaderForTesting())
        await awaitNativeLayoutTurn()

        #expect(transport.logCommandOutputPanelCountForTesting == 1)
        #expect(transport.logExpandedCommandOutputPanelCountForTesting == 1)
        #expect(transport.logCommandOutputPanelToggleSymbolNameForTesting == "chevron.down")
        #expect(transport.logCommandOutputPanelUsesSystemMaterialBackgroundForTesting)
        #expect(transport.logCommandOutputPanelUsesTextKit2ForTesting)
        #expect((5...6).contains(transport.logCommandOutputPanelVisibleLineCapacityForTesting))
        #expect(transport.logCommandOutputPanelResultTextForTesting == "Success")
        #expect(transport.logCommandOutputPanelCommandLineTextForTesting == "$ swift test")
        #expect(transport.logCommandOutputPanelOutputScrollTextForTesting?.contains("$ swift test") == false)
        #expect(transport.logCommandOutputPanelOutputScrollTextForTesting?.contains("output line 1") == true)
        #expect(transport.logCommandOutputPanelOutputScrollIsScrollableForTesting)
        let initialOutputScrollOffset = try #require(transport.logCommandOutputPanelOutputScrollVerticalOffsetForTesting)
        let initialOutputScrollMaximumOffset = try #require(transport.logCommandOutputPanelOutputScrollMaximumVerticalOffsetForTesting)
        #expect(abs(initialOutputScrollOffset - initialOutputScrollMaximumOffset) <= 0.5)
        #expect(transport.scrollCommandOutputPanelOutputForTesting(deltaY: -24))
        let scrolledOutputScrollOffset = try #require(transport.logCommandOutputPanelOutputScrollVerticalOffsetForTesting)
        #expect(scrolledOutputScrollOffset < initialOutputScrollMaximumOffset)
        job.appendLogEntry(.init(
            kind: .commandOutput,
            groupID: "cmd_1",
            text: "\noutput line 10",
            metadata: commandMetadata
        ))
        _ = try await awaitTransportRender(transport)
        await awaitNativeLayoutTurn()
        let offsetAfterOutputAppend = try #require(transport.logCommandOutputPanelOutputScrollVerticalOffsetForTesting)
        #expect(abs(offsetAfterOutputAppend - scrolledOutputScrollOffset) <= 0.5)
        #expect(transport.clickFirstLogCommandOutputPanelHeaderForTesting())
        await awaitNativeLayoutTurn()
        #expect(transport.logExpandedCommandOutputPanelCountForTesting == 0)
        #expect(transport.clickFirstLogCommandOutputPanelHeaderForTesting())
        await awaitNativeLayoutTurn()
        let reopenedOutputScrollOffset = try #require(transport.logCommandOutputPanelOutputScrollVerticalOffsetForTesting)
        let reopenedOutputScrollMaximumOffset = try #require(transport.logCommandOutputPanelOutputScrollMaximumVerticalOffsetForTesting)
        #expect(abs(reopenedOutputScrollOffset - reopenedOutputScrollMaximumOffset) <= 0.5)
        #expect(transport.logCommandOutputPanelTerminalTextForTesting?.contains("$ swift test") == true)
        #expect(transport.logCommandOutputPanelTerminalTextForTesting?.contains("output line 1") == true)
        #expect(transport.logCommandOutputPanelTerminalTextForTesting?.contains("Ran command for 17s - 9 lines") == false)
        #expect(transport.displayedLogForTesting.contains("output line 9") == false)
    }

    @Test func switchingSelectedJobRebindsDetailPane() async throws {
        let activeJob = makeJob(
            id: "job-active",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Active review in progress.",
            logText: "Active log\n"
        )
        let recentJob = makeJob(
            id: "job-recent",
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "Recent review completed.",
            logText: "Recent log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [activeJob, recentJob])
        )
        let backend = makeWindowHarness(store: store)
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)

        let activeSnapshot = try await awaitTransportRender(transport)
        #expect(activeSnapshot.title == nil)
        #expect(activeSnapshot.summary == nil)
        #expect(window.title == activeJob.targetSummary)
        #expect(window.subtitle == activeJob.cwd)
        viewController.sidebarViewControllerForTesting.selectJobForTesting(recentJob)

        let recentSnapshot = try await awaitTransportRender(transport)
        #expect(
            recentSnapshot == .init(
                title: nil,
                summary: nil,
                log: recentJob.logText,
                isShowingEmptyState: false
            )
        )
        #expect(window.title == recentJob.targetSummary)
        #expect(window.subtitle == recentJob.cwd)
    }

    @Test func firstSelectionFromEmptyStatePinsUnvisitedJobToBottom() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let job = makeJob(
            id: "job-first-bottom",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)
        transport.view.layoutSubtreeIfNeeded()

        #expect(transport.isLogPinnedToBottomForTesting)
    }

    @Test func switchingSelectedJobStartsUnvisitedJobAtBottomAndRestoresPreviousOffset() async throws {
        let longActiveLog = (0..<400).map { "active line \($0)" }.joined(separator: "\n")
        let longRecentLog = (0..<400).map { "recent line \($0)" }.joined(separator: "\n")
        let activeJob = makeJob(
            id: "job-active-scroll",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Active review in progress.",
            logText: longActiveLog
        )
        let recentJob = makeJob(
            id: "job-recent-scroll",
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "Recent review completed.",
            logText: longRecentLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [activeJob, recentJob])
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)
        _ = try await awaitTransportRender(transport)

        transport.scrollLogToOffsetForTesting(120)
        let activeOffset = transport.logVerticalScrollOffsetForTesting
        #expect(activeOffset > 0)
        #expect(transport.isLogPinnedToBottomForTesting == false)
        viewController.sidebarViewControllerForTesting.selectJobForTesting(recentJob)
        _ = try await awaitTransportRender(transport)

        #expect(transport.isLogPinnedToBottomForTesting)
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)
        _ = try await awaitTransportRender(transport)

        #expect(transport.logVerticalScrollOffsetForTesting == activeOffset)
        #expect(transport.isLogPinnedToBottomForTesting == false)
    }

    @Test func switchingSelectedJobRestoresPinnedBottomPosition() async throws {
        let longActiveLog = (0..<400).map { "active line \($0)" }.joined(separator: "\n")
        let longRecentLog = (0..<400).map { "recent line \($0)" }.joined(separator: "\n")
        let activeJob = makeJob(
            id: "job-active-bottom",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Active review in progress.",
            logText: longActiveLog
        )
        let recentJob = makeJob(
            id: "job-recent-bottom",
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "Recent review completed.",
            logText: longRecentLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [activeJob, recentJob])
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)
        _ = try await awaitTransportRender(transport)

        transport.scrollLogToBottomForTesting()
        #expect(transport.isLogPinnedToBottomForTesting)
        viewController.sidebarViewControllerForTesting.selectJobForTesting(recentJob)
        _ = try await awaitTransportRender(transport)

        #expect(transport.isLogPinnedToBottomForTesting)

        activeJob.appendLogEntry(.init(kind: .progress, text: "Newest active line"))
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)
        let snapshot = try await awaitTransportRender(transport)

        #expect(snapshot.log.contains("Newest active line"))
        #expect(transport.isLogPinnedToBottomForTesting)
    }

    @Test func rehydratingSameSelectedJobPreservesLogScrollPosition() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let job = makeJob(
            id: "job-rehydrated",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        transport.scrollLogToOffsetForTesting(120)
        let preservedOffset = transport.logVerticalScrollOffsetForTesting
        #expect(preservedOffset > 0)

        let replacement = makeJob(
            id: "job-rehydrated",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [replacement]))

        #expect(transport.displayedLogForTesting == longLog)
        #expect(transport.logVerticalScrollOffsetForTesting == preservedOffset)
    }

    @Test func switchingJobWithIdenticalLogTextStartsUnvisitedJobAtBottom() async throws {
        let sharedLog = (0..<400).map { "shared line \($0)" }.joined(separator: "\n")
        let firstJob = makeJob(
            id: "job-identical-1",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: sharedLog
        )
        let secondJob = makeJob(
            id: "job-identical-2",
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "Review completed.",
            logText: sharedLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [firstJob, secondJob]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(firstJob)
        _ = try await awaitTransportRender(transport)

        transport.scrollLogToOffsetForTesting(120)
        #expect(transport.logVerticalScrollOffsetForTesting > 0)
        viewController.sidebarViewControllerForTesting.selectJobForTesting(secondJob)
        _ = try await awaitTransportRender(transport)

        #expect(transport.isLogPinnedToBottomForTesting)
    }

    @Test func shortLogSelectionCacheRestoresTopAfterLaterGrowth() async throws {
        let shortLog = (0..<3).map { "short line \($0)" }.joined(separator: "\n")
        let longLog = (0..<400).map { "long line \($0)" }.joined(separator: "\n")
        let shortJob = makeJob(
            id: "job-short-cache",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Short preview.",
            logText: shortLog
        )
        let recentJob = makeJob(
            id: "job-short-cache-recent",
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "Recent review completed.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [shortJob, recentJob]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(shortJob)
        _ = try await awaitTransportRender(transport)
        viewController.sidebarViewControllerForTesting.selectJobForTesting(recentJob)
        _ = try await awaitTransportRender(transport)

        shortJob.replaceLogEntries([.init(kind: .agentMessage, text: longLog)])
        viewController.sidebarViewControllerForTesting.selectJobForTesting(shortJob)
        _ = try await awaitTransportRender(transport)

        #expect(abs(
            transport.logVerticalScrollOffsetForTesting
                - transport.logMinimumVerticalScrollOffsetForTesting
        ) < 0.5)
        #expect(transport.isLogPinnedToBottomForTesting == false)
    }

    @Test func previouslySelectedJobUpdatesDoNotRepaintCurrentDetailPane() async throws {
        let activeJob = makeJob(
            id: "job-old-selection",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Active review.",
            logText: "Active log\n"
        )
        let recentJob = makeJob(
            id: "job-current-selection",
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "Recent review.",
            logText: "Recent log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [activeJob, recentJob]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)
        _ = try await awaitTransportRender(transport)
        viewController.sidebarViewControllerForTesting.selectJobForTesting(recentJob)
        _ = try await awaitTransportRender(transport)
        activeJob.appendLogEntry(.init(kind: .progress, text: "stale update"))
        recentJob.appendLogEntry(.init(kind: .progress, text: "fresh update"))

        let updatedSnapshot = try await awaitTransportRender(transport) { snapshot in
            snapshot.log.contains("fresh update")
        }
        #expect(updatedSnapshot.log.contains("stale update") == false)
        #expect(transport.displayedLogForTesting.contains("stale update") == false)
    }

    @Test func clickingSidebarBlankAreaKeepsSelectionAndDetailPane() async throws {
        let job = makeJob(
            id: "job-selected",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Review is still running.",
            logText: "Selected log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [job])
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let selectedSnapshot = try await awaitTransportRender(transport)
        viewController.sidebarViewControllerForTesting.clickBlankAreaForTesting()

        #expect(viewController.sidebarViewControllerForTesting.selectedJobForTesting?.id == job.id)
        #expect(transport.renderSnapshotForTesting == selectedSnapshot)
    }

    @Test func clickingWorkspaceHeaderSelectsWorkspaceAndShowsFindingsPane() async throws {
        let job = makeJob(
            id: "job-selected",
            cwd: "/tmp/workspace-alpha",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Review is still running.",
            logText: "Selected log\n"
        )
        let workspace = CodexReviewWorkspace(cwd: job.cwd)
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            jobs: [job]
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        _ = try await awaitTransportRender(transport)
        viewController.sidebarViewControllerForTesting.clickWorkspaceHeaderForTesting(workspace)

        _ = try await awaitTransportRender(transport)
        #expect(viewController.sidebarViewControllerForTesting.selectedWorkspaceForTesting?.cwd == workspace.cwd)
        #expect(viewController.sidebarViewControllerForTesting.selectedJobForTesting == nil)
        #expect(
            transport.workspaceFindingSnapshotForTesting == .init(
                text: "",
                isShowingNoFindingsState: true,
                isShowingFindingsList: false
            )
        )
    }

    @Test func newJobsArrivingWhileUnselectedDoNotAutoSelect() {
        let activeJob = makeJob(status: .running, targetSummary: "Uncommitted changes")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, workspaces: [])
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarViewControllerForTesting.selectedJobForTesting == nil)
        #expect(viewController.contentPaneViewControllerForTesting.isShowingEmptyStateForTesting)

        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [activeJob])
        )

        #expect(viewController.sidebarViewControllerForTesting.selectedJobForTesting == nil)
        #expect(viewController.contentPaneViewControllerForTesting.isShowingEmptyStateForTesting)
        #expect(viewController.contentPaneViewControllerForTesting.displayedTitleForTesting == nil)
    }

    @Test func removingSelectedJobClearsSelectionWithoutAutoSelectingReplacement() async throws {
        let activeJob = makeJob(
            id: "job-active",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Active review in progress.",
            logText: "Active log\n"
        )
        let recentJob = makeJob(
            id: "job-recent",
            status: .succeeded,
            targetSummary: "Commit: abc123",
            summary: "Recent review completed.",
            logText: "Recent log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [activeJob, recentJob])
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let contentPane = viewController.contentPaneViewControllerForTesting
        let transport = viewController.transportViewControllerForTesting
        let sidebar = viewController.sidebarViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)

        let activeSnapshot = try await awaitTransportRender(transport)
        #expect(activeSnapshot.title == nil)
        #expect(activeSnapshot.summary == nil)
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [recentJob])
        )
        try await waitForObservedValue(
            from: sidebar.sidebarTopologyDeliveryForTesting,
            true
        ) {
            sidebar.selectedJobForTesting == nil
        }

        let emptySnapshot = try await awaitContentPaneRender(contentPane)
        #expect(sidebar.selectedJobForTesting == nil)
        #expect(emptySnapshot.isShowingEmptyState)
        #expect(emptySnapshot.title == nil)
        #expect(emptySnapshot.summary == nil)
    }

    @Test func clearingSelectionShowsEmptyStateAndClearsDetailPane() async throws {
        let job = makeJob(
            id: "job-1",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: "Initial log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [job])
        )
        let backend = makeWindowHarness(store: store)
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let contentPane = viewController.contentPaneViewControllerForTesting
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let selectedSnapshot = try await awaitTransportRender(transport)
        #expect(selectedSnapshot.title == nil)
        #expect(window.title == job.targetSummary)
        #expect(window.subtitle == job.cwd)
        viewController.sidebarViewControllerForTesting.clearSelectionForTesting()

        let emptySnapshot = try await awaitContentPaneRender(contentPane)
        #expect(emptySnapshot.isShowingEmptyState)
        #expect(emptySnapshot.title == nil)
        #expect(emptySnapshot.summary == nil)
        #expect(emptySnapshot.log.isEmpty)
        #expect(window.title == "")
        #expect(window.subtitle == "")
        job.core.output.summary = "Deselected summary"
        job.replaceLogEntries([.init(kind: .agentMessage, text: "Deselected log")])

        #expect(contentPane.selectedJobDeliveryForTesting == nil)
        #expect(contentPane.renderSnapshotForTesting == emptySnapshot)
    }

    @Test func inPlaceJobUpdateKeepsSelectionAndRefreshesDetailPane() async throws {
        let job = makeJob(
            id: "job-1",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: "Initial log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [job])
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let selectedSnapshot = try await awaitTransportRender(transport)
        #expect(selectedSnapshot.title == nil)
        #expect(selectedSnapshot.summary == nil)
        job.core.lifecycle.status = .succeeded
        job.core.output.summary = "Review completed successfully."
        job.replaceLogEntries([.init(kind: .agentMessage, text: "Updated log")])

        let updatedSnapshot = try await awaitTransportRender(transport)
        #expect(viewController.sidebarViewControllerForTesting.selectedJobForTesting?.id == "job-1")
        #expect(updatedSnapshot.summary == nil)
        #expect(updatedSnapshot.log == "Updated log")
    }

    @Test func selectedJobLogAppendUsesAppendPath() async throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-append",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            logEntries: [
                .init(kind: .agentMessage, groupID: "msg_1", text: "Initial")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 360))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)
        transport.setLogReduceMotionForTesting(false)
        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        job.appendLogEntry(.init(kind: .agentMessage, groupID: "msg_1", text: " log"))

        let snapshot = try await awaitTransportRender(transport)
        #expect(snapshot.log == "Initial log")
        #expect(transport.logAppendCountForTesting == appendCount + 1)
        #expect(transport.logReloadCountForTesting == reloadCount)
        #expect(transport.logWordGlowCountForTesting == 1)
    }

    @Test func separatorPrefixedProgressAppendDoesNotUseGenericWordGlow() async throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-progress-separator-append",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            logEntries: [
                .init(kind: .agentMessage, groupID: "msg_1", text: "Initial")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)
        let wordGlowCount = transport.logWordGlowCountForTesting
        job.appendLogEntry(.init(kind: .progress, groupID: "progress_1", text: "stream.tick 001"))

        let snapshot = try await awaitTransportRender(transport)
        #expect(snapshot.log.hasSuffix("stream.tick 001"))
        #expect(transport.logWordGlowCountForTesting == wordGlowCount)
    }

    @Test func logCanonicalEquivalentPrefixReloadsWhenUTF16LengthChanges() async throws {
        let decomposedPrefix = "Caf\u{0065}\u{0301}"
        let precomposedUpdate = "Caf\u{00E9} appended"
        let job = CodexReviewJob.makeForTesting(
            id: "job-canonical-append",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            logEntries: [
                .init(kind: .agentMessage, groupID: "msg_1", text: decomposedPrefix)
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        #expect(transport.renderLogForTesting(text: precomposedUpdate, allowIncrementalUpdate: true))

        #expect(transport.displayedLogForTesting.hasSuffix(" appended"))
        #expect(transport.logAppendCountForTesting == appendCount)
        #expect(transport.logReloadCountForTesting == reloadCount + 1)
    }

    @Test func coalescedLogTextUpdateUsesAppendPathWhenSuffixCanBeDerived() async throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-coalesced",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            logEntries: [
                .init(kind: .agentMessage, groupID: "msg_1", text: "Initial")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)
        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        job.appendLogEntry(.init(kind: .agentMessage, groupID: "msg_1", text: " one"))
        job.appendLogEntry(.init(kind: .agentMessage, groupID: "msg_1", text: " two"))

        let snapshot = try await awaitTransportRender(transport)
        #expect(snapshot.log == "Initial one two")
        #expect(transport.logAppendCountForTesting == appendCount + 1)
        #expect(transport.logReloadCountForTesting == reloadCount)
    }

    @Test func coalescedProgressSuffixDoesNotUseGenericWordGlow() async throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-coalesced-progress",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            logEntries: [
                .init(kind: .agentMessage, groupID: "msg_1", text: "Initial")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)
        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        let wordGlowCount = transport.logWordGlowCountForTesting
        job.appendLogEntry(.init(kind: .progress, groupID: "progress_1", text: "stream.tick 001"))
        job.appendLogEntry(.init(kind: .progress, groupID: "progress_2", text: "stream.tick 002"))

        let snapshot = try await awaitTransportRender(transport)
        #expect(snapshot.log.hasSuffix("stream.tick 002"))
        #expect(transport.logAppendCountForTesting == appendCount + 1)
        #expect(transport.logReloadCountForTesting == reloadCount)
        #expect(transport.logWordGlowCountForTesting == wordGlowCount)
    }

    @Test func shortLogAppendDoesNotGrowDocumentFrameBeforeContentIsScrollable() async throws {
        let job = makeJob(
            id: "job-short-append-frame-stability",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: "review.start\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let harness = makeWindowHarness(store: store, contentSize: NSSize(width: 900, height: 600))
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)
        transport.view.layoutSubtreeIfNeeded()

        let initialDocumentFrame = transport.logDocumentViewFrameForTesting
        #expect(transport.isLogPinnedToBottomForTesting)
        #expect(abs(transport.logMaximumVerticalScrollOffsetForTesting - transport.logMinimumVerticalScrollOffsetForTesting) < 0.5)
        job.appendLogEntry(.init(
            kind: .progress,
            text: "stream.tick 001 delta/layout +2 -0 while the short log remains below the scrollable viewport height"
        ))
        _ = try await awaitTransportRender(transport)
        transport.view.layoutSubtreeIfNeeded()

        let appendedDocumentFrame = transport.logDocumentViewFrameForTesting
        #expect(abs(appendedDocumentFrame.height - initialDocumentFrame.height) < 0.5)
        #expect(abs(transport.logMaximumVerticalScrollOffsetForTesting - transport.logMinimumVerticalScrollOffsetForTesting) < 0.5)
    }

    @Test func selectedJobGroupedReplacementUsesReplacementPath() async throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-reload",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            logEntries: [
                .init(kind: .plan, groupID: "plan_1", text: "- original")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)
        let appendCount = transport.logAppendCountForTesting
        let replaceCount = transport.logReplaceCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        job.appendLogEntry(.init(kind: .plan, groupID: "plan_1", replacesGroup: true, text: "- updated"))

        let snapshot = try await awaitTransportRender(transport)
        #expect(snapshot.log == "- updated")
        #expect(transport.logAppendCountForTesting == appendCount)
        #expect(transport.logReplaceCountForTesting == replaceCount + 1)
        #expect(transport.logReloadCountForTesting == reloadCount)
    }

    @Test func selectedJobMarkdownAppendReplacesTailBlockWithoutReload() async throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-markdown-append-fallback",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            logEntries: [
                .init(kind: .agentMessage, groupID: "msg_1", text: "**bo")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)
        let appendCount = transport.logAppendCountForTesting
        let replaceCount = transport.logReplaceCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        job.appendLogEntry(.init(kind: .agentMessage, groupID: "msg_1", text: "ld**"))

        let snapshot = try await awaitTransportRender(transport)
        #expect(snapshot.log == "bold")
        #expect(transport.logAppendCountForTesting == appendCount)
        #expect(transport.logReplaceCountForTesting == replaceCount + 1)
        #expect(transport.logReloadCountForTesting == reloadCount)
    }

    @Test func skippedMarkdownRestyleReloadsBeforeSuffixAppendFallback() {
        let logScrollView = ReviewMonitorLogScrollView()
        let initialEntry = ReviewLogEntry(kind: .agentMessage, groupID: "msg_1", text: "bold")
        let restyledEntry = ReviewLogEntry(kind: .agentMessage, groupID: "msg_1", replacesGroup: true, text: "**bold**")
        let appendedEntry = ReviewLogEntry(kind: .agentMessage, groupID: "msg_1", text: " tail")
        var projection = ReviewMonitorLogProjection()
        let initialDocument = projection.render(entries: [initialEntry])
        logScrollView.render(document: initialDocument, restoring: .top, allowIncrementalUpdate: false)
        let appendCount = logScrollView.appendCount
        let reloadCount = logScrollView.reloadCount

        _ = projection.render(entries: [initialEntry, restyledEntry])
        let latestDocument = projection.render(entries: [initialEntry, restyledEntry, appendedEntry])
        logScrollView.render(document: latestDocument, restoring: .top, allowIncrementalUpdate: true)

        #expect(logScrollView.displayedTextForTesting == "bold tail")
        #expect(logScrollView.appendCount == appendCount)
        #expect(logScrollView.reloadCount == reloadCount + 1)
    }

    @Test func staleGroupedReplacementIsNotReplayedAfterHiddenCommandOutput() async throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-stale-replacement",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            logEntries: [
                .init(kind: .plan, groupID: "plan_1", text: "- original")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)
        job.appendLogEntry(.init(
            kind: .plan,
            groupID: "plan_1",
            replacesGroup: true,
            text: "- updated with longer replacement text"
        ))
        _ = try await awaitTransportRender(transport)
        let replaceCount = transport.logReplaceCountForTesting
        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        job.appendLogEntry(.init(kind: .commandOutput, groupID: "cmd_1", text: "hidden output"))
        _ = try await awaitTransportRender(transport) { snapshot in
            snapshot.log.contains("Command output")
        }

        #expect(transport.displayedLogForTesting.contains("- updated with longer replacement text"))
        #expect(transport.displayedLogForTesting.contains("Command output"))
        #expect(transport.displayedLogForTesting.contains("Command output - 1 line") == false)
        #expect(transport.displayedLogForTesting.contains("hidden output") == false)
        #expect(transport.logAppendCountForTesting == appendCount + 1)
        #expect(transport.logReplaceCountForTesting == replaceCount)
        #expect(transport.logReloadCountForTesting == reloadCount)
    }

    @Test func metadataOnlyUpdatesDoNotTouchLogView() async throws {
        let job = makeJob(
            id: "job-metadata",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: "Initial log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)
        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        job.core.output.summary = "Updated summary."

        #expect(transport.displayedLogForTesting == "Initial log")
        #expect(transport.logAppendCountForTesting == appendCount)
        #expect(transport.logReloadCountForTesting == reloadCount)
    }

    @Test func reasoningAppendUsesWordGlowAndReduceMotionDisablesGlow() async throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-reasoning-glow",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            logEntries: [
                .init(kind: .rawReasoning, groupID: "reasoning_1", text: "Thinking")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)
        transport.setLogReduceMotionForTesting(false)
        job.appendLogEntry(.init(kind: .rawReasoning, groupID: "reasoning_1", text: " through options"))
        _ = try await awaitTransportRender(transport)

        #expect(transport.logWordGlowCountForTesting == 2)

        transport.setLogReduceMotionForTesting(true)
        job.appendLogEntry(.init(kind: .rawReasoning, groupID: "reasoning_1", text: " without animation"))
        _ = try await awaitTransportRender(transport)

        #expect(transport.logWordGlowCountForTesting == 0)
    }

    @Test func reasoningWordGlowCompletesAndClearsRenderingAttributes() async throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-reasoning-glow-completion",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            logEntries: [
                .init(kind: .rawReasoning, groupID: "reasoning_1", text: "Thinking")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let harness = makeWindowHarness(store: store, contentSize: NSSize(width: 900, height: 360))
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)
        transport.setLogReduceMotionForTesting(false)

        let invalidationCount = transport.logWordFadeDisplayInvalidationCountForTesting
        job.appendLogEntry(.init(kind: .rawReasoning, groupID: "reasoning_1", text: " through options"))
        _ = try await awaitTransportRender(transport)

        #expect(transport.logWordGlowCountForTesting > 0)
        #expect(transport.logWordFadeRenderingAttributeRangeCountForTesting > 0)
        #expect(transport.logWordFadeStorageUsesOpaqueTextColorForTesting)

        transport.completeLogWordGlowAnimationsForTesting()

        #expect(transport.logWordGlowCountForTesting == 0)
        #expect(transport.logWordFadeRenderingAttributeRangeCountForTesting == 0)
        #expect(transport.logWordFadeStorageUsesOpaqueTextColorForTesting)
        #expect(transport.logWordFadeDisplayInvalidationCountForTesting > invalidationCount)
    }

    @Test func logAutoFollowRunsOnlyWhenPinnedToBottom() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let job = makeJob(
            id: "job-autofollow",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)
        #expect(transport.isLogPinnedToBottomForTesting)

        transport.scrollLogToBottomForTesting()
        #expect(transport.isLogPinnedToBottomForTesting)

        transport.scrollLogToTopForTesting()
        #expect(transport.isLogPinnedToBottomForTesting == false)
        let unpinnedAutoFollow = transport.logAutoFollowCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "Unpinned update"))
        _ = try await awaitTransportRender(transport)
        #expect(transport.logAutoFollowCountForTesting == unpinnedAutoFollow)
        #expect(transport.isLogPinnedToBottomForTesting == false)

        transport.scrollLogToBottomForTesting()
        #expect(transport.isLogPinnedToBottomForTesting)
        let pinnedAutoFollow = transport.logAutoFollowCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "Pinned update"))
        _ = try await awaitTransportRender(transport)
        #expect(transport.logAutoFollowCountForTesting == pinnedAutoFollow + 1)
        #expect(transport.isLogPinnedToBottomForTesting)
    }

    @Test func logAutoFollowKeepsBottomAfterWrappedSingleLineAppend() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let job = makeJob(
            id: "job-autofollow-wrapped-append",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let harness = makeWindowHarness(store: store, contentSize: NSSize(width: 560, height: 360))
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        transport.scrollLogToBottomForTesting()
        #expect(transport.isLogPinnedToBottomForTesting)
        let pinnedAutoFollow = transport.logAutoFollowCountForTesting
        let wrappedLine = (0..<140)
            .map { "wrapped-append-segment-\($0)" }
            .joined(separator: " ")
        job.appendLogEntry(.init(kind: .progress, text: wrappedLine))
        _ = try await awaitTransportRender(transport)

        #expect(transport.logAutoFollowCountForTesting == pinnedAutoFollow + 1)
        #expect(transport.isLogPinnedToBottomForTesting)
        #expect(transport.logVisibleFragmentViewCountForTesting > 0)
        #expect(transport.isLogPinnedToBottomForTesting)
    }

    @Test func logAppendDoesNotScrollWhenNearBottomButUnpinned() async throws {
        let longLog = (0..<500)
            .map { "scroll stability line \($0) with enough text to keep TextKit 2 viewport layout active" }
            .joined(separator: "\n")
        let job = makeJob(
            id: "job-append-near-bottom-scroll-stability",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        let nearBottomOffset = transport.logMaximumVerticalScrollOffsetForTesting - 12
        transport.scrollLogToOffsetForTesting(nearBottomOffset)
        #expect(transport.isLogPinnedToBottomForTesting == false)
        let offsetBeforeAppend = transport.logVerticalScrollOffsetForTesting
        let autoFollowBeforeAppend = transport.logAutoFollowCountForTesting
        let programmaticScrollsBeforeAppend = transport.logProgrammaticScrollCountForTesting
        job.appendLogEntry(.init(
            kind: .progress,
            text: "Near-bottom append should not snap inertial or manual scrolling to the document end"
        ))
        _ = try await awaitTransportRender(transport)

        #expect(transport.logAutoFollowCountForTesting == autoFollowBeforeAppend)
        #expect(transport.logProgrammaticScrollCountForTesting == programmaticScrollsBeforeAppend)
        #expect(abs(transport.logVerticalScrollOffsetForTesting - offsetBeforeAppend) < 0.5)
        #expect(transport.isLogPinnedToBottomForTesting == false)
    }

    @Test func programmaticLogAutoFollowRequestsOverlayScrollerHideWhenShown() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let job = makeJob(
            id: "job-overlay-hide",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.scrollLogToBottomForTesting()
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "Newest line"))
        _ = try await awaitTransportRender(transport)

        #expect(transport.isLogPinnedToBottomForTesting)
        #expect(transport.logOverlayScrollerHideRequestCountForTesting == hideCountBeforeAppend + 1)
    }

    @Test func legacyScrollerStyleDoesNotRequestOverlayScrollerHide() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let job = makeJob(
            id: "job-legacy-hide",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        transport.setLogScrollerStyleForTesting(.legacy)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.scrollLogToBottomForTesting()
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "Newest line"))
        _ = try await awaitTransportRender(transport)

        #expect(transport.logOverlayScrollerHideRequestCountForTesting == hideCountBeforeAppend)
    }

    @Test func shortLogDoesNotRequestOverlayScrollerHideWhenNoScrollRange() async throws {
        let job = makeJob(
            id: "job-overlay-short",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: "short log"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "short update"))
        _ = try await awaitTransportRender(transport)

        #expect(transport.logOverlayScrollerHideRequestCountForTesting == hideCountBeforeAppend)
    }

    @Test func selectingJobRequestsOverlayScrollerHideWhenRestoringScrollPosition() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let firstJob = makeJob(
            id: "job-restore-1",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let secondJob = makeJob(
            id: "job-restore-2",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [firstJob, secondJob]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(firstJob)
        _ = try await awaitTransportRender(transport)

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.scrollLogToOffsetForTesting(120)
        viewController.sidebarViewControllerForTesting.selectJobForTesting(secondJob)
        _ = try await awaitTransportRender(transport)

        let hideCountBeforeRestore = transport.logOverlayScrollerHideRequestCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(firstJob)
        _ = try await awaitTransportRender(transport)

        #expect(transport.logOverlayScrollerHideRequestCountForTesting > hideCountBeforeRestore)
    }

    @Test func privateOverlayBridgeNoOpsWhenScrollerImpPairIsUnavailable() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let job = makeJob(
            id: "job-missing-pair",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.setLogOverlayScrollerBridgeModeForTesting(.missingScrollerImpPair)
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "Newest line"))
        _ = try await awaitTransportRender(transport)

        #expect(transport.logOverlayScrollerHideRequestCountForTesting == hideCountBeforeAppend)
    }

    @Test func privateOverlayBridgeNoOpsWhenHideSelectorsAreUnavailable() async throws {
        let longLog = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        let job = makeJob(
            id: "job-missing-hide",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.setLogOverlayScrollerBridgeModeForTesting(.missingHideMethods)
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "Newest line"))
        _ = try await awaitTransportRender(transport)

        #expect(transport.logOverlayScrollerHideRequestCountForTesting == hideCountBeforeAppend)
    }

    @Test func logViewUsesCustomTextKit2SurfaceAndDisablesEditingFeatures() async throws {
        let job = makeJob(
            id: "job-log-config",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: "Initial log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        #expect(transport.logUsesCustomTextKit2SurfaceForTesting)
        #expect(transport.logUsesTextViewForTesting == false)
        #expect(transport.logUsesLegacyLayoutManagerForTesting == false)
        #expect(transport.logIsEditableForTesting == false)
        #expect(transport.logIsSelectableForTesting)
        #expect(transport.logHitTestTargetsDocumentViewForTesting)
        #expect(transport.logWritingToolsDisabledForTesting)
    }

    @Test func logViewMaintainsVisibleTextKit2FragmentCoverageWhenScrolled() async throws {
        let longLog = (0..<1_000).map { "fragment coverage line \($0)" }.joined(separator: "\n")
        let job = makeJob(
            id: "job-log-fragments",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let harness = makeWindowHarness(store: store, contentSize: NSSize(width: 900, height: 520))
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)
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
        let job = makeJob(
            id: "job-log-fragment-append",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let harness = makeWindowHarness(store: store, contentSize: NSSize(width: 900, height: 520))
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)
        let appendCount = transport.logAppendCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "Newest fragment line"))
        _ = try await awaitTransportRender(transport)

        #expect(transport.logAppendCountForTesting == appendCount + 1)
        #expect(transport.logVisibleFragmentViewCountForTesting > 0)
        #expect(transport.logStaleFragmentViewCountForTesting == 0)
    }

    @Test func logViewSupportsReadOnlySelectAllCopyFindValidationAndAccessibility() async throws {
        let job = makeJob(
            id: "job-log-readonly",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: "First readonly line\nSecond readonly line\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        #expect(viewController.validateUserInterfaceItem(textFinderMenuItemForTesting(.showFindInterface)))
        #expect(viewController.validateUserInterfaceItem(textFinderMenuItemForTesting(.nextMatch)))
        #expect(viewController.validateUserInterfaceItem(textFinderMenuItemForTesting(.replace)) == false)
        #expect(transport.logAccessibilityValueForTesting == job.logText)
        #expect(transport.logDocumentViewExportsUserInterfaceValidationForTesting)

        let copyItem = commandMenuItemForTesting("copy:")
        let selectAllItem = commandMenuItemForTesting("selectAll:")
        #expect(transport.validateLogDocumentUserInterfaceItemForTesting(copyItem) == false)
        #expect(transport.validateLogDocumentUserInterfaceItemForTesting(selectAllItem))

        transport.selectAllLogForTesting()
        #expect(transport.logSelectedTextForTesting == job.logText)
        #expect(transport.validateLogDocumentUserInterfaceItemForTesting(copyItem))

        NSPasteboard.general.clearContents()
        transport.copyLogSelectionForTesting()
        #expect(NSPasteboard.general.string(forType: .string) == job.logText)

        transport.clearLogFinderSelectedRangesForTesting()
        #expect(transport.logSelectedTextForTesting == nil)
        #expect(transport.validateLogDocumentUserInterfaceItemForTesting(copyItem) == false)

        transport.setSelectedLogRangeForTesting(NSRange(location: 0, length: 0))
        transport.performLogKeyboardCommandForTesting(#selector(NSStandardKeyBindingResponding.moveRightAndModifySelection(_:)))
        transport.performLogKeyboardCommandForTesting(#selector(NSStandardKeyBindingResponding.moveRightAndModifySelection(_:)))
        #expect(transport.logSelectedTextForTesting == "Fi")
        #expect(transport.validateLogDocumentUserInterfaceItemForTesting(copyItem))
        transport.performLogKeyboardCommandForTesting(#selector(NSStandardKeyBindingResponding.moveRight(_:)))
        #expect(transport.logSelectedTextForTesting == nil)
        transport.performLogKeyboardCommandForTesting(#selector(NSStandardKeyBindingResponding.moveRightAndModifySelection(_:)))
        #expect(transport.logSelectedTextForTesting == "r")

        let graphemeLog = "A🙂e\u{301}B\n"
        transport.renderLogForTesting(text: graphemeLog, allowIncrementalUpdate: false)
        transport.setSelectedLogRangeForTesting(NSRange(location: ("A" as NSString).length, length: 0))
        transport.performLogKeyboardCommandForTesting(#selector(NSStandardKeyBindingResponding.moveRightAndModifySelection(_:)))
        #expect(transport.logSelectedTextForTesting == "🙂")

        transport.setSelectedLogRangeForTesting(NSRange(location: ("A🙂" as NSString).length, length: 0))
        transport.performLogKeyboardCommandForTesting(#selector(NSStandardKeyBindingResponding.moveRightAndModifySelection(_:)))
        #expect(transport.logSelectedTextForTesting == "e\u{301}")
    }

    @Test func logViewUsesStandardTextContextMenu() async throws {
        let job = makeJob(
            id: "job-log-context-menu",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: "First readonly line\nSecond readonly line\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let harness = makeWindowHarness(store: store, contentSize: NSSize(width: 900, height: 360))
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        let emptySelectionMenu = try #require(transport.logContextMenuForTesting)
        #expect(emptySelectionMenu.items.contains { $0.title == "Copy" })
        #expect(emptySelectionMenu.items.contains { $0.title == "Paste" })
        #expect(emptySelectionMenu.items.contains { $0.title == "Font" })

        transport.setSelectedLogRangeForTesting(NSRange(location: 0, length: ("First" as NSString).length))
        let selectedTextMenu = try #require(transport.logContextMenuForTesting)
        #expect(selectedTextMenu.items.contains { $0.action == #selector(NSText.copy(_:)) })
    }

    @Test func logKeyboardLineNavigationUsesSoftWrappedVisualLines() async throws {
        let wrappedLine = (1...80)
            .map { "wrapped-segment-\($0)" }
            .joined(separator: " ")
        let job = makeJob(
            id: "job-log-soft-wrap-keyboard",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: wrappedLine + "\nnext logical line\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let harness = makeWindowHarness(store: store, contentSize: NSSize(width: 560, height: 360))
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        transport.scrollLogToTopForTesting()
        #expect(transport.logVisibleFragmentViewCountForTesting > 0)

        transport.setSelectedLogRangeForTesting(NSRange(location: 0, length: 0))
        transport.performLogKeyboardCommandForTesting(#selector(NSStandardKeyBindingResponding.moveToEndOfLineAndModifySelection(_:)))
        let selectedVisualLineEnd = try #require(transport.logSelectedTextForTesting)
        #expect(selectedVisualLineEnd.isEmpty == false)
        #expect(selectedVisualLineEnd.contains("\n") == false)
        #expect((selectedVisualLineEnd as NSString).length < (wrappedLine as NSString).length)

        transport.setSelectedLogRangeForTesting(NSRange(location: 0, length: 0))
        transport.performLogKeyboardCommandForTesting(#selector(NSStandardKeyBindingResponding.moveDownAndModifySelection(_:)))
        let selectedVisualLineMove = try #require(transport.logSelectedTextForTesting)
        #expect(selectedVisualLineMove.isEmpty == false)
        #expect(selectedVisualLineMove.contains("\n") == false)
        #expect((selectedVisualLineMove as NSString).length < (wrappedLine as NSString).length)
    }

    @Test func logFindPreservesVisibleSearchStateDuringLogUpdatesUntilHidden() async throws {
        let initialLog = (1...140)
            .map { "needle \($0) with enough trailing text to wrap in the visible log surface" }
            .joined(separator: "\n") + "\n"
        let job = makeJob(
            id: "job-log-find-system-highlights",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: initialLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 360))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        let renderedInitialLog = reviewMonitorLogText(for: job)
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
        job.appendLogEntry(.init(kind: .progress, text: "needle appended"))
        _ = try await awaitTransportRender(transport)

        let appendedLength = (reviewMonitorLogText(for: job) as NSString).length
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
        #expect(transport.logFindIndicatorInvalidationCountForTesting == findIndicatorInvalidationCountBeforeSnapshotScroll + 1)
        #expect(transport.isLogPinnedToBottomForTesting == false)

        let offsetBeforeMiddleAppend = transport.logVerticalScrollOffsetForTesting
        job.appendLogEntry(.init(kind: .progress, text: "needle appended while the log is not following bottom"))
        _ = try await awaitTransportRender(transport)

        #expect(abs(transport.logVerticalScrollOffsetForTesting - offsetBeforeMiddleAppend) < 0.5)
        #expect(transport.logSelectedTextForTesting == "needle")
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting)
        #expect(transport.logFindClientSnapshotMapsToDocumentForTesting)

        var burstText = reviewMonitorLogText(for: job)
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
        #expect(transport.renderLogForTesting(
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

        #expect(transport.renderLogForTesting(
            text: "",
            allowIncrementalUpdate: false
        ))
        #expect(transport.logFindClientUsesSnapshotForTesting == false)
        #expect(transport.logFindStringLengthForTesting == 0)

        let liveReloadText = "needle after empty structural reload\n"
        #expect(transport.renderLogForTesting(
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
        #expect(transport.renderLogForTesting(
            text: hiddenUpdateText,
            allowIncrementalUpdate: true
        ))

        #expect(transport.logFindStringLengthForTesting == (hiddenUpdateText as NSString).length)
    }

    @Test func logFindClearsVisibleSnapshotWhenLogContentIsReused() async throws {
        let firstJob = makeJob(
            id: "job-log-find-reuse-first",
            status: .running,
            targetSummary: "First job",
            summary: "Running review.",
            logText: "needle first job\n"
        )
        let secondJob = makeJob(
            id: "job-log-find-reuse-second",
            status: .running,
            targetSummary: "Second job",
            summary: "Running review.",
            logText: "needle second job\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [firstJob, secondJob]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(firstJob)
        _ = try await awaitTransportRender(transport)

        let firstNeedleRange = (reviewMonitorLogText(for: firstJob) as NSString).range(of: "needle")
        #expect(firstNeedleRange.location != NSNotFound)
        transport.setSelectedLogRangeForTesting(firstNeedleRange)
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.setSearchString))
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        firstJob.appendLogEntry(.init(kind: .progress, text: "needle appended"))
        _ = try await awaitTransportRender(transport)
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting)
        viewController.sidebarViewControllerForTesting.clearSelectionForTesting()
        _ = try await awaitTransportRender(transport)
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting == false)
        viewController.sidebarViewControllerForTesting.selectJobForTesting(secondJob)
        _ = try await awaitTransportRender(transport)

        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting == false)
        #expect(transport.logFindStringLengthForTesting == (reviewMonitorLogText(for: secondJob) as NSString).length)
    }

    @Test func logFindContentReuseClearsSnapshotWhenSameTextSkipsRender() async throws {
        let initialLog = "needle initial"
        let appendedLine = "needle appended"
        let reusedLog = initialLog + "\n\n" + appendedLine
        let firstJob = makeJob(
            id: "job-log-find-same-text-reuse-first",
            status: .running,
            targetSummary: "First job",
            summary: "Running review.",
            logText: initialLog
        )
        let secondJob = makeJob(
            id: "job-log-find-same-text-reuse-second",
            status: .running,
            targetSummary: "Second job",
            summary: "Running review.",
            logText: reusedLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [firstJob, secondJob]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(firstJob)
        _ = try await awaitTransportRender(transport)

        let firstNeedleRange = (reviewMonitorLogText(for: firstJob) as NSString).range(of: "needle")
        #expect(firstNeedleRange.location != NSNotFound)
        transport.setSelectedLogRangeForTesting(firstNeedleRange)
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.setSearchString))
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        firstJob.appendLogEntry(.init(kind: .progress, text: appendedLine))
        _ = try await awaitTransportRender(transport)
        #expect(transport.displayedLogForTesting == reviewMonitorLogText(for: secondJob))
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting)

        viewController.sidebarViewControllerForTesting.selectJobForTesting(secondJob)
        _ = try await awaitTransportRender(transport)

        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting == false)
        #expect(transport.logFindStringLengthForTesting == (reviewMonitorLogText(for: secondJob) as NSString).length)
    }

    @Test func logFindContentReuseClearsSnapshotForPrefixRelatedLogs() async throws {
        let firstLog = "needle shared prefix\n"
        let firstJob = makeJob(
            id: "job-log-find-prefix-reuse-first",
            status: .running,
            targetSummary: "First job",
            summary: "Running review.",
            logText: firstLog
        )
        let secondJob = makeJob(
            id: "job-log-find-prefix-reuse-second",
            status: .running,
            targetSummary: "Second job",
            summary: "Running review.",
            logText: firstLog + "needle second suffix\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [firstJob, secondJob]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(firstJob)
        _ = try await awaitTransportRender(transport)

        let firstNeedleRange = (reviewMonitorLogText(for: firstJob) as NSString).range(of: "needle")
        #expect(firstNeedleRange.location != NSNotFound)
        transport.setSelectedLogRangeForTesting(firstNeedleRange)
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.setSearchString))
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.setLogVisibleFindBarSearchStringForTesting(""))
        #expect(transport.logFindClientUsesSnapshotForTesting == false)

        let finderIdentifierBeforeSwitch = transport.logTextFinderIdentifierForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(secondJob)
        _ = try await awaitTransportRender(transport)

        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logTextFinderIdentifierForTesting == finderIdentifierBeforeSwitch)
        #expect(transport.logFindClientUsesSnapshotForTesting == false)
        #expect(transport.logFindStringLengthForTesting == (reviewMonitorLogText(for: secondJob) as NSString).length)
    }

    @Test func logFindHidingVisibleSnapshotReturnsClientToLiveString() async throws {
        let job = makeJob(
            id: "job-log-find-hide-snapshot",
            status: .running,
            targetSummary: "Hide snapshot",
            summary: "Running review.",
            logText: "needle initial\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        let firstNeedleRange = (reviewMonitorLogText(for: job) as NSString).range(of: "needle")
        #expect(firstNeedleRange.location != NSNotFound)
        transport.setSelectedLogRangeForTesting(firstNeedleRange)
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.setSearchString))
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        job.appendLogEntry(.init(kind: .progress, text: "needle appended"))
        _ = try await awaitTransportRender(transport)
        #expect(transport.logFindClientUsesSnapshotForTesting)

        viewController.performTextFinderAction(textFinderMenuItemForTesting(.hideFindInterface))

        #expect(transport.logFindBarVisibleForTesting == false)
        #expect(transport.logFindClientUsesSnapshotForTesting == false)
        #expect(transport.logFindStringLengthForTesting == (reviewMonitorLogText(for: job) as NSString).length)
    }

    @Test func logFindClearedSelectionReturnsVisibleUpdatesToLiveString() async throws {
        let job = makeJob(
            id: "job-log-find-cleared-selection",
            status: .running,
            targetSummary: "Cleared selection",
            summary: "Running review.",
            logText: "needle initial\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        let firstNeedleRange = (reviewMonitorLogText(for: job) as NSString).range(of: "needle")
        #expect(firstNeedleRange.location != NSNotFound)
        transport.setSelectedLogRangeForTesting(firstNeedleRange)
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.setSearchString))
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        job.appendLogEntry(.init(kind: .progress, text: "needle appended into snapshot"))
        _ = try await awaitTransportRender(transport)
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting)

        #expect(transport.setLogVisibleFindBarSearchStringForTesting(""))
        transport.clearLogFinderSelectedRangesForTesting()
        #expect(transport.logFindClientFirstSelectedRangeForTesting.length == 0)
        #expect(transport.logSelectedTextForTesting == nil)
        #expect(transport.logFindClientUsesSnapshotForTesting == false)
        job.appendLogEntry(.init(kind: .progress, text: "needle appended after cleared selection"))
        _ = try await awaitTransportRender(transport)

        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting == false)
        #expect(transport.logFindStringLengthForTesting == (reviewMonitorLogText(for: job) as NSString).length)
    }

    @Test func logFindClearedQueryReturnsVisibleUpdatesToLiveString() async throws {
        let job = makeJob(
            id: "job-log-find-cleared-query",
            status: .running,
            targetSummary: "Cleared query",
            summary: "Running review.",
            logText: "needle initial\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        let firstNeedleRange = (reviewMonitorLogText(for: job) as NSString).range(of: "needle")
        #expect(firstNeedleRange.location != NSNotFound)
        transport.setSelectedLogRangeForTesting(firstNeedleRange)
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.setSearchString))
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        job.appendLogEntry(.init(kind: .progress, text: "needle appended into snapshot"))
        _ = try await awaitTransportRender(transport)
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting)

        try await withFindPasteboardString(nil) {
            #expect(transport.setLogVisibleFindBarSearchStringForTesting(""))
            transport.simulateLogFinderEmptySelectedRangesForTesting()
            #expect(transport.logFindClientFirstSelectedRangeForTesting.length == 0)
            #expect(transport.logHasActiveFindQueryForTesting == false)
            #expect(transport.logFindClientUsesSnapshotForTesting == false)
            job.appendLogEntry(.init(kind: .progress, text: "needle appended after cleared query"))
            _ = try await awaitTransportRender(transport)

            #expect(transport.logFindBarVisibleForTesting)
            #expect(transport.logFindClientUsesSnapshotForTesting == false)
            #expect(transport.logFindStringLengthForTesting == (reviewMonitorLogText(for: job) as NSString).length)
        }
    }

    @Test func logFindDoesNotFreezeVisibleBarBeforeSearchQuery() async throws {
        let job = makeJob(
            id: "job-log-find-visible-no-query",
            status: .running,
            targetSummary: "Visible find bar",
            summary: "Running review.",
            logText: "initial log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        try await withFindPasteboardString(nil) {
            viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
            #expect(transport.logFindBarVisibleForTesting)
            #expect(transport.setLogVisibleFindBarSearchStringForTesting(""))
            #expect(transport.logVisibleFindBarSearchStringForTesting == "")
            #expect(transport.logFindClientUsesSnapshotForTesting == false)
            job.appendLogEntry(.init(kind: .progress, text: "future-only needle"))
            _ = try await awaitTransportRender(transport)

            #expect(transport.logFindBarVisibleForTesting)
            #expect(transport.logFindClientUsesSnapshotForTesting == false)
            #expect(transport.logFindStringLengthForTesting == (reviewMonitorLogText(for: job) as NSString).length)
        }
    }

    @Test func logFindPreservesDirectFindBarQueryDuringLogUpdates() async throws {
        let job = makeJob(
            id: "job-log-find-direct-query",
            status: .running,
            targetSummary: "Visible find bar direct query",
            summary: "Running review.",
            logText: "core initial log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        let initialLength = (reviewMonitorLogText(for: job) as NSString).length
        try await withFindPasteboardString(nil) {
            viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
            #expect(transport.logFindBarVisibleForTesting)
            #expect(transport.setLogVisibleFindBarSearchStringForTesting("core"))
            #expect(transport.logVisibleFindBarSearchStringForTesting == "core")
            #expect(transport.logHasActiveFindQueryForTesting)
            job.appendLogEntry(.init(kind: .progress, text: "core appended while query is visible"))
            _ = try await awaitTransportRender(transport)

            #expect(transport.logFindBarVisibleForTesting)
            #expect(transport.logVisibleFindBarSearchStringForTesting == "core")
            #expect(transport.logHasActiveFindQueryForTesting)
            #expect(transport.logFindClientUsesSnapshotForTesting)
            #expect(transport.logFindStringLengthForTesting == initialLength)
        }
    }

    @Test func logFindQueryChangeRefreshesVisibleSnapshotAfterLogUpdates() async throws {
        let job = makeJob(
            id: "job-log-find-query-change",
            status: .running,
            targetSummary: "Visible find bar query change",
            summary: "Running review.",
            logText: "alpha initial log\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        let initialLength = (reviewMonitorLogText(for: job) as NSString).length
        try await withFindPasteboardString(nil) {
            viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
            #expect(transport.logFindBarVisibleForTesting)
            #expect(transport.setLogVisibleFindBarSearchStringForTesting("alpha"))
            #expect(transport.logFindStringLengthForTesting == initialLength)

            job.appendLogEntry(.init(kind: .progress, text: "beta appended after active search"))
            _ = try await awaitTransportRender(transport)
            #expect(transport.logFindClientUsesSnapshotForTesting)
            #expect(transport.logFindStringLengthForTesting == initialLength)

            #expect(transport.setLogVisibleFindBarSearchStringForTesting("beta"))
            #expect(transport.logVisibleFindBarSearchStringForTesting == "beta")
            #expect(transport.logFindClientUsesSnapshotForTesting)
            #expect(transport.logFindClientSnapshotMapsToDocumentForTesting)
            #expect(transport.logFindStringLengthForTesting == (reviewMonitorLogText(for: job) as NSString).length)
        }
    }

    @Test func logFindVisibleBarNormalSelectionKeepsUpdatesLive() async throws {
        let job = makeJob(
            id: "job-log-find-visible-normal-selection",
            status: .running,
            targetSummary: "Visible find bar normal selection",
            summary: "Running review.",
            logText: "copyable text before updates\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        try await withFindPasteboardString(nil) {
            viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
            #expect(transport.logFindBarVisibleForTesting)
            #expect(transport.setLogVisibleFindBarSearchStringForTesting(""))
            #expect(transport.logVisibleFindBarSearchStringForTesting == "")
            let normalSelectionRange = (reviewMonitorLogText(for: job) as NSString).range(of: "copyable")
            #expect(normalSelectionRange.location != NSNotFound)
            transport.setSelectedLogRangeForTesting(normalSelectionRange)
            #expect(transport.logSelectedTextForTesting == "copyable")
            #expect(transport.logHasActiveFindQueryForTesting == false)
            job.appendLogEntry(.init(kind: .progress, text: "needle appended after normal selection"))
            _ = try await awaitTransportRender(transport)

            #expect(transport.logFindBarVisibleForTesting)
            #expect(transport.logFindClientUsesSnapshotForTesting == false)
            #expect(transport.logFindStringLengthForTesting == (reviewMonitorLogText(for: job) as NSString).length)
        }
    }

    @Test func logFindPreservesNoResultSearchStateDuringLogUpdatesUntilHidden() async throws {
        let job = makeJob(
            id: "job-log-find-visible-no-result",
            status: .running,
            targetSummary: "Visible find bar no result",
            summary: "Running review.",
            logText: "initial log without the active query\n"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientFirstSelectedRangeForTesting.length == 0)
        try await withFindPasteboardString("active query") {
            #expect(transport.setLogVisibleFindBarSearchStringForTesting("active query"))
            transport.simulateLogFinderEmptySelectedRangesForTesting()
            #expect(transport.logHasActiveFindQueryForTesting)

            let initialLength = (reviewMonitorLogText(for: job) as NSString).length
            job.appendLogEntry(.init(kind: .progress, text: "active query appears after no-result search"))
            _ = try await awaitTransportRender(transport)

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
        let job = makeJob(
            id: "job-log-find-empty-append",
            status: .running,
            targetSummary: "Empty log",
            summary: "Running review.",
            logText: ""
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport)

        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.setLogVisibleFindBarSearchStringForTesting(""))
        #expect(transport.logFindStringLengthForTesting == 0)
        job.appendLogEntry(.init(kind: .progress, text: "needle first content"))
        _ = try await awaitTransportRender(transport)

        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting == false)
        #expect(transport.logFindStringLengthForTesting == (reviewMonitorLogText(for: job) as NSString).length)
    }

    @Test func authFailedJobShowsNormalFailureDetails() async throws {
        let job = makeJob(
            id: "job-auth",
            status: .failed,
            targetSummary: "Uncommitted changes",
            summary: "Failed to start review.",
            logText: "Authentication required. Sign in to ReviewMonitor and retry."
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            authState: .signedOut,
            content: makeSidebarContent(from: [job])
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let snapshot = try await awaitTransportRender(transport)
        #expect(snapshot.summary == nil)
        #expect(snapshot.log == "Authentication required. Sign in to ReviewMonitor and retry.")
    }

    @Test func authenticatedAuthFailedJobStillShowsNormalFailureDetails() async throws {
        let job = makeJob(
            id: "job-auth-restored",
            status: .failed,
            targetSummary: "Uncommitted changes",
            summary: "Failed to start review.",
            logText: "Authentication required. Sign in to ReviewMonitor and retry."
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            authState: .signedIn(accountID: "review@example.com"),
            content: makeSidebarContent(from: [job])
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let snapshot = try await awaitTransportRender(transport)
        #expect(snapshot.summary == nil)
        #expect(snapshot.log == "Authentication required. Sign in to ReviewMonitor and retry.")
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
    sidebarJobFilterDefaults: UserDefaults? = nil,
    contentTransitionAnimator: @escaping ReviewMonitorContentTransitionAnimator = ReviewMonitorRootViewController.defaultContentTransitionAnimator
) -> ReviewMonitorWindowHarness {
    applyTestAuthState(auth: store.auth, state: authState)
    let windowController = ReviewMonitorWindowController(
        store: store,
        contentTransitionAnimator: contentTransitionAnimator,
        sidebarJobFilterDefaults: sidebarJobFilterDefaults
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
    delivery: ObservationDelivery?,
    timeout: Duration = .seconds(2)
) async throws {
    try await waitForObservedValue(from: delivery, expected, timeout: timeout) {
        viewController.sidebarPresentationForTesting
    }
}

@MainActor
func waitForWorkspaceExpanded(
    _ viewController: ReviewMonitorSidebarViewController,
    workspace: CodexReviewWorkspace,
    _ expected: Bool,
    timeout: Duration = .seconds(2)
) async throws {
    let viewControllerBox = UncheckedSendableBox(viewController)
    let workspaceBox = UncheckedSendableBox(workspace)
    try await withTestTimeout(timeout) {
        while await MainActor.run(body: {
            viewControllerBox.value.workspaceIsExpandedForTesting(workspaceBox.value) != expected
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
    from delivery: ObservationDelivery?,
    sample: @escaping @MainActor @Sendable () -> Value
) async throws -> ObservedValues<Value> {
    let delivery = try #require(delivery)
    return await delivery.values {
        sample()
    }
}

@MainActor
func waitForObservedValue<Value: Sendable & Equatable>(
    from delivery: ObservationDelivery?,
    _ expected: Value,
    timeout: Duration = .seconds(2),
    sample: @escaping @MainActor @Sendable () -> Value
) async throws {
    let values = try await observedValues(from: delivery, sample: sample)
    guard await values.waitUntilValue(expected, timeout: timeout) else {
        throw TestFailure("timed out waiting for observed value")
    }
}

@MainActor
func awaitTransportRender(
    _ transport: ReviewMonitorTransportViewController,
    delivery explicitDelivery: ObservationDelivery? = nil,
    timeout: Duration = .seconds(2),
    matching predicate: (@Sendable (ReviewMonitorTransportViewController.RenderSnapshotForTesting) -> Bool)? = nil
) async throws -> ReviewMonitorTransportViewController.RenderSnapshotForTesting {
    _ = try #require(explicitDelivery ?? transport.deliveryForExpectedRenderedStateForTesting)
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
    throw TestFailure("timed out waiting for rendered transport state")
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
func awaitContentPaneRender(
    _ contentPane: ReviewMonitorTransportViewController,
    delivery explicitDelivery: ObservationDelivery? = nil,
    timeout: Duration = .seconds(2),
    matching predicate: (@Sendable (ReviewMonitorTransportViewController.RenderSnapshotForTesting) -> Bool)? = nil
) async throws -> ReviewMonitorTransportViewController.RenderSnapshotForTesting {
    try await awaitTransportRender(
        contentPane,
        delivery: explicitDelivery,
        timeout: timeout,
        matching: predicate
    )
}

final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

@MainActor
func makeJob(
    id: String = UUID().uuidString,
    cwd: String = "/tmp/repo",
    startedAt: Date = Date(timeIntervalSince1970: 200),
    status: ReviewJobState,
    targetSummary: String,
    summary: String? = nil,
    reviewResult: ParsedReviewResult? = nil,
    logText: String = "",
    rawLogText: String = ""
) -> CodexReviewJob {
    CodexReviewJob.makeForTesting(
        id: id,
        cwd: cwd,
        targetSummary: targetSummary,
        threadID: status == .queued ? nil : UUID().uuidString,
        turnID: UUID().uuidString,
        status: status,
        startedAt: startedAt,
        endedAt: status.isTerminal ? startedAt.addingTimeInterval(1) : nil,
        summary: summary ?? status.displayText,
        reviewResult: reviewResult,
        lastAgentMessage: "",
        logEntries:
            (logText.isEmpty ? [] : [.init(kind: .agentMessage, text: logText.trimmingCharacters(in: .newlines))])
            + (rawLogText.isEmpty ? [] : rawLogText.split(separator: "\n", omittingEmptySubsequences: false).map {
                .init(kind: .diagnostic, text: String($0))
            }),
        errorMessage: status == .failed ? summary ?? status.displayText : nil
    )
}

@MainActor
func makeWorkspaces(from jobs: [CodexReviewJob]) -> [CodexReviewWorkspace] {
    var seenCWDs: Set<String> = []
    var order: [String] = []
    for job in jobs {
        if seenCWDs.contains(job.cwd) == false {
            order.insert(job.cwd, at: 0)
            seenCWDs.insert(job.cwd)
        }
    }
    return order.map { CodexReviewWorkspace(cwd: $0) }
}

@MainActor
func makeSidebarContent(from jobs: [CodexReviewJob]) -> (workspaces: [CodexReviewWorkspace], jobs: [CodexReviewJob]) {
    (makeWorkspaces(from: jobs), Array(jobs.reversed()))
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
        let account = CodexAccount(
            email: accountEmail,
            planType: state.accountPlanType ?? "pro"
        )
        auth.updatePersistedAccounts([account])
        auth.updateAccount(account)
    } else {
        auth.updatePersistedAccounts([CodexAccount]())
        auth.updateAccount(nil as CodexAccount?)
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
        workspaces: [CodexReviewWorkspace],
        jobs: [CodexReviewJob] = [],
        settingsSnapshot: CodexReviewSettingsSnapshot? = nil
    ) {
        loadForTesting(
            serverState: serverState,
            authPhase: authState.phase,
            account: authState.accountEmail.map {
                CodexAccount(
                    email: $0,
                    planType: authState.accountPlanType ?? "pro"
                )
            },
            persistedAccounts: authState.accountEmail.map {
                [
                    CodexAccount(
                        email: $0,
                        planType: authState.accountPlanType ?? "pro"
                    )
                ]
            } ?? [],
            serverURL: serverURL,
            workspaces: workspaces,
            jobs: jobs,
            settingsSnapshot: settingsSnapshot
        )
    }

    func loadForTesting(
        serverState: CodexReviewServerState,
        authState: TestAuthState = .signedOut,
        serverURL: URL? = nil,
        content: (workspaces: [CodexReviewWorkspace], jobs: [CodexReviewJob]),
        settingsSnapshot: CodexReviewSettingsSnapshot? = nil
    ) {
        loadForTesting(
            serverState: serverState,
            authState: authState,
            serverURL: serverURL,
            workspaces: content.workspaces,
            jobs: content.jobs,
            settingsSnapshot: settingsSnapshot
        )
    }
}

@MainActor
func makeSettingsSnapshot(
    model: String? = "gpt-5.4",
    fallbackModel: String? = nil,
    reasoningEffort: CodexReviewReasoningEffort = .medium,
    serviceTier: CodexReviewServiceTier? = .fast
) -> CodexReviewSettingsSnapshot {
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
            CodexAccount(email: $0, planType: initialAuthState.accountPlanType ?? "pro")
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

    override func interruptReview(_: BackendReviewRun, reason _: BackendCancellationReason) async throws {
        throw ReviewError.io("Cancellation failed.")
    }

}

@MainActor
final class BlockingSettingsBackend: PreviewCodexReviewStoreBackend {
    struct ModelUpdateCall: Equatable {
        let model: String?
        let reasoningEffort: CodexReviewReasoningEffort?
        let serviceTier: CodexReviewServiceTier?
    }

    private(set) var refreshCallCount = 0
    private(set) var modelUpdateCalls: [ModelUpdateCall] = []
    private(set) var reasoningUpdateCalls: [CodexReviewReasoningEffort?] = []
    private(set) var serviceTierUpdateCalls: [CodexReviewServiceTier?] = []

    private var shouldBlockNextRefresh = false
    private var shouldBlockNextModelUpdate = false
    private var shouldBlockNextReasoningUpdate = false
    private let blockedRefreshStartedGate = OneShotGate()
    private let blockedRefreshResumeGate = OneShotGate()
    private let blockedModelUpdateStartedGate = OneShotGate()
    private let blockedModelUpdateResumeGate = OneShotGate()
    private let blockedReasoningUpdateStartedGate = OneShotGate()
    private let blockedReasoningUpdateResumeGate = OneShotGate()

    init(snapshot: CodexReviewSettingsSnapshot) {
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

    override func refreshSettings() async throws -> CodexReviewSettingsSnapshot {
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
        reasoningEffort: CodexReviewReasoningEffort?,
        persistReasoningEffort: Bool,
        serviceTier: CodexReviewServiceTier?,
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
        _ reasoningEffort: CodexReviewReasoningEffort?
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
        _ serviceTier: CodexReviewServiceTier?
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
