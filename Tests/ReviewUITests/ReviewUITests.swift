import AppKit
import Foundation
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
        try await waitForCondition {
            sidebar.displayedSectionTitlesForTesting == [
                "workspace-alpha",
                "workspace-beta",
            ]
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
        try await waitForCondition {
            sidebar.displayedSectionTitlesForTesting == [
                "workspace-beta",
                "workspace-alpha",
            ]
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
        try await waitForCondition {
            sidebar.displayedJobIDsForTesting(in: workspace) == [
                "job-sort-order-2",
                "job-sort-order-1",
            ]
        }

        #expect(sidebar.sidebarFullReloadCountForTesting == fullReloadCountBeforeChange)
        #expect(sidebar.sidebarWorkspaceReloadCountForTesting == workspaceReloadCountBeforeChange)
        #expect(sidebar.sidebarIncrementalMembershipChangeCountForTesting == incrementalMembershipChangeCountBeforeChange)
        #expect(sidebar.sidebarIncrementalMoveCountForTesting == incrementalMoveCountBeforeChange + 1)
    }

    @Test func workspaceJobsChangeReloadsWorkspaceOnly() async throws {
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

        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            jobs: [firstJob, secondJob]
        )
        try await waitForCondition {
            sidebar.displayedJobIDsForTesting(in: workspace) == [
                "job-membership-1",
                "job-membership-2",
            ]
        }

        #expect(sidebar.displayedJobIDsForTesting(in: workspace) == ["job-membership-1", "job-membership-2"])
        #expect(sidebar.sidebarFullReloadCountForTesting == fullReloadCountBeforeChange)
        #expect(sidebar.sidebarWorkspaceReloadCountForTesting == workspaceReloadCountBeforeChange + 1)
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

        #expect(await accountsViewController.performAccountDropForTesting(
            displayedFirstAccount,
            proposedChildIndex: 2
        ))
        #expect(store.auth.persistedAccounts.map(\.email) == [
            "second@example.com",
            "first@example.com",
            "third@example.com",
        ])
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
        for _ in 0..<10 where accountsViewController.displayedAccountEmailsForTesting != [
            "second@example.com",
            "first@example.com",
            "detached@example.com",
        ] {
            await Task.yield()
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

        let initialRenderCount = transport.renderCountForTesting
        sidebar.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

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

        for _ in 0..<10 where accountsViewController.selectedAccountEmailForTesting != "active@example.com" {
            await Task.yield()
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
        for _ in 0..<10 where accountsViewController.selectedAccountEmailForTesting != "active@example.com" {
            await Task.yield()
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
        for _ in 0..<10 where accountsViewController.selectedAccountEmailForTesting != "active@example.com" {
            await Task.yield()
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
        for _ in 0..<10 where accountsViewController.selectedAccountEmailForTesting != "active@example.com" {
            await Task.yield()
        }
        let displayedEmails = accountsViewController.displayedAccountEmailsForTesting

        store.auth.selectPersistedAccount(displayedOtherAccount.accountKey)
        for _ in 0..<10 where accountsViewController.selectedAccountEmailForTesting != "other@example.com" {
            await Task.yield()
        }

        #expect(accountsViewController.selectedAccountEmailForTesting == "other@example.com")
        #expect(accountsViewController.displayedAccountEmailsForTesting == displayedEmails)
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

        store.auth.updateCurrentAccount(CodexAccount(email: "detached@example.com", planType: "pro"))
        for _ in 0..<10 where accountsViewController.displayedAccountEmailsForTesting != [
            "saved@example.com",
            "detached@example.com",
        ] {
            await Task.yield()
        }

        #expect(accountsViewController.displayedAccountEmailsForTesting == [
            "saved@example.com",
            "detached@example.com",
        ])
        #expect(accountsViewController.selectedAccountEmailForTesting == "detached@example.com")

        store.auth.selectPersistedAccount(savedAccount.accountKey)
        for _ in 0..<10 where accountsViewController.displayedAccountEmailsForTesting != ["saved@example.com"] {
            await Task.yield()
        }

        #expect(accountsViewController.displayedAccountEmailsForTesting == ["saved@example.com"])
        #expect(accountsViewController.selectedAccountEmailForTesting == "saved@example.com")
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
        for _ in 0..<10 where accountsViewController.selectedAccountEmailForTesting != "active@example.com" {
            await Task.yield()
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(recentJob)

        let selectedSnapshot = try await awaitTransportRender(transport, after: initialRenderCount)
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

        let stableRenderCount = transport.renderCountForTesting
        activeJob.core.output.summary = "Old selection should not render."
        activeJob.replaceLogEntries([.init(kind: .agentMessage, text: "Old selection log")])
        await transport.flushMainQueueForTesting()

        #expect(transport.renderCountForTesting == stableRenderCount)
        #expect(transport.renderSnapshotForTesting == selectedSnapshot)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectWorkspaceForTesting(workspace)

        _ = try await awaitTransportRender(transport, after: initialRenderCount)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectWorkspaceForTesting(workspace)

        _ = try await awaitTransportRender(transport, after: initialRenderCount)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectWorkspaceForTesting(workspace)

        _ = try await awaitTransportRender(transport, after: initialRenderCount)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectWorkspaceForTesting(workspace)

        _ = try await awaitTransportRender(transport, after: initialRenderCount)
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

        let initialRenderCount = transport.renderCountForTesting
        sidebar.selectWorkspaceForTesting(workspace)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        let replacement = CodexReviewWorkspace(cwd: workspace.cwd)
        let replacementJob = makeJob(
            id: "job-workspace-selection-replacement",
            cwd: workspace.cwd,
            status: .succeeded,
            targetSummary: "Commit: replacement"
        )
        store.loadForTesting(serverState: .running, workspaces: [replacement], jobs: [replacementJob])
        await transport.flushMainQueueForTesting()

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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let selectedSnapshot = try await awaitTransportRender(transport, after: initialRenderCount)
        #expect(selectedSnapshot.title == nil)
        #expect(selectedSnapshot.summary == nil)
        #expect(window.title == job.targetSummary)
        #expect(window.subtitle == job.cwd)

        let displayedLog = transport.displayedLogForTesting
        #expect(displayedLog == job.reviewMonitorLogDocument.text)
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

        let firstRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)

        let activeSnapshot = try await awaitTransportRender(transport, after: firstRenderCount)
        #expect(activeSnapshot.title == nil)
        #expect(activeSnapshot.summary == nil)
        #expect(window.title == activeJob.targetSummary)
        #expect(window.subtitle == activeJob.cwd)

        let secondRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(recentJob)

        let recentSnapshot = try await awaitTransportRender(transport, after: secondRenderCount)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)
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

        let firstRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)
        _ = try await awaitTransportRender(transport, after: firstRenderCount)

        transport.scrollLogToOffsetForTesting(120)
        let activeOffset = transport.logVerticalScrollOffsetForTesting
        #expect(activeOffset > 0)
        #expect(transport.isLogPinnedToBottomForTesting == false)

        let secondRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(recentJob)
        _ = try await awaitTransportRender(transport, after: secondRenderCount)

        #expect(transport.isLogPinnedToBottomForTesting)

        let thirdRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)
        _ = try await awaitTransportRender(transport, after: thirdRenderCount)

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

        let firstRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)
        _ = try await awaitTransportRender(transport, after: firstRenderCount)

        transport.scrollLogToBottomForTesting()
        #expect(transport.isLogPinnedToBottomForTesting)

        let secondRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(recentJob)
        _ = try await awaitTransportRender(transport, after: secondRenderCount)

        #expect(transport.isLogPinnedToBottomForTesting)

        activeJob.appendLogEntry(.init(kind: .progress, text: "Newest active line"))

        let thirdRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)
        let snapshot = try await awaitTransportRender(transport, after: thirdRenderCount)

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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

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

        let refreshRenderCount = transport.renderCountForTesting
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [replacement]))
        await transport.flushMainQueueForTesting()

        #expect(transport.renderCountForTesting == refreshRenderCount)
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

        let firstRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(firstJob)
        _ = try await awaitTransportRender(transport, after: firstRenderCount)

        transport.scrollLogToOffsetForTesting(120)
        #expect(transport.logVerticalScrollOffsetForTesting > 0)

        let secondRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(secondJob)
        _ = try await awaitTransportRender(transport, after: secondRenderCount)

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

        let firstRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(shortJob)
        _ = try await awaitTransportRender(transport, after: firstRenderCount)

        let secondRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(recentJob)
        _ = try await awaitTransportRender(transport, after: secondRenderCount)

        shortJob.replaceLogEntries([.init(kind: .agentMessage, text: longLog)])

        let thirdRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(shortJob)
        _ = try await awaitTransportRender(transport, after: thirdRenderCount)

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

        let firstRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)
        _ = try await awaitTransportRender(transport, after: firstRenderCount)

        let secondRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(recentJob)
        let snapshot = try await awaitTransportRender(transport, after: secondRenderCount)

        let stableRenderCount = transport.renderCountForTesting
        activeJob.appendLogEntry(.init(kind: .progress, text: "stale update"))
        await transport.flushMainQueueForTesting()

        #expect(transport.renderCountForTesting == stableRenderCount)
        #expect(transport.renderSnapshotForTesting == snapshot)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let selectedSnapshot = try await awaitTransportRender(transport, after: initialRenderCount)

        let stableRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.clickBlankAreaForTesting()
        await transport.flushMainQueueForTesting()

        #expect(viewController.sidebarViewControllerForTesting.selectedJobForTesting?.id == job.id)
        #expect(transport.renderCountForTesting == stableRenderCount)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        let workspaceRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.clickWorkspaceHeaderForTesting(workspace)

        _ = try await awaitTransportRender(transport, after: workspaceRenderCount)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(activeJob)

        let activeSnapshot = try await awaitTransportRender(transport, after: initialRenderCount)
        #expect(activeSnapshot.title == nil)
        #expect(activeSnapshot.summary == nil)

        let removalRenderCount = contentPane.renderCountForTesting
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [recentJob])
        )

        let emptySnapshot = try await awaitContentPaneRender(contentPane, after: removalRenderCount)
        #expect(viewController.sidebarViewControllerForTesting.selectedJobForTesting == nil)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let selectedSnapshot = try await awaitTransportRender(transport, after: initialRenderCount)
        #expect(selectedSnapshot.title == nil)
        #expect(window.title == job.targetSummary)
        #expect(window.subtitle == job.cwd)

        let clearRenderCount = contentPane.renderCountForTesting
        viewController.sidebarViewControllerForTesting.clearSelectionForTesting()

        let emptySnapshot = try await awaitContentPaneRender(contentPane, after: clearRenderCount)
        #expect(emptySnapshot.isShowingEmptyState)
        #expect(emptySnapshot.title == nil)
        #expect(emptySnapshot.summary == nil)
        #expect(emptySnapshot.log.isEmpty)
        #expect(window.title == "")
        #expect(window.subtitle == "")

        let stableRenderCount = transport.renderCountForTesting
        job.core.output.summary = "Deselected summary"
        job.replaceLogEntries([.init(kind: .agentMessage, text: "Deselected log")])
        await transport.flushMainQueueForTesting()

        #expect(transport.renderCountForTesting == stableRenderCount)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let selectedSnapshot = try await awaitTransportRender(transport, after: initialRenderCount)
        #expect(selectedSnapshot.title == nil)
        #expect(selectedSnapshot.summary == nil)

        let updateRenderCount = transport.renderCountForTesting
        job.core.lifecycle.status = .succeeded
        job.core.output.summary = "Review completed successfully."
        job.replaceLogEntries([.init(kind: .agentMessage, text: "Updated log")])

        let updatedSnapshot = try await awaitTransportRender(transport, after: updateRenderCount)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        let appendRenderCount = transport.renderCountForTesting
        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        job.appendLogEntry(.init(kind: .agentMessage, groupID: "msg_1", text: " log"))

        let snapshot = try await awaitTransportRender(transport, after: appendRenderCount)
        #expect(snapshot.log == "Initial log")
        #expect(transport.logAppendCountForTesting == appendCount + 1)
        #expect(transport.logReloadCountForTesting == reloadCount)
        #expect(transport.logWordGlowCountForTesting == 1)
        #expect(transport.logReasoningLineGlowCountForTesting == 0)
    }

    @Test func separatorPrefixedReasoningAppendKeepsStructuredLineGlow() async throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-reasoning-separator-append",
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        let appendRenderCount = transport.renderCountForTesting
        let reasoningLineGlowCount = transport.logReasoningLineGlowCountForTesting
        job.appendLogEntry(.init(kind: .rawReasoning, groupID: "reasoning_1", text: "Thinking through"))

        let snapshot = try await awaitTransportRender(transport, after: appendRenderCount)
        #expect(snapshot.log.hasSuffix("Thinking through"))
        #expect(transport.logReasoningLineGlowCountForTesting == reasoningLineGlowCount + 1)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        let appendRenderCount = transport.renderCountForTesting
        let wordGlowCount = transport.logWordGlowCountForTesting
        let reasoningLineGlowCount = transport.logReasoningLineGlowCountForTesting
        job.appendLogEntry(.init(kind: .progress, groupID: "progress_1", text: "stream.tick 001"))

        let snapshot = try await awaitTransportRender(transport, after: appendRenderCount)
        #expect(snapshot.log.hasSuffix("stream.tick 001"))
        #expect(transport.logWordGlowCountForTesting == wordGlowCount)
        #expect(transport.logReasoningLineGlowCountForTesting == reasoningLineGlowCount)
    }

    @Test func logAppendSuffixUsesNewTextIndexForCanonicalEquivalentPrefix() async throws {
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        #expect(transport.renderLogForTesting(text: precomposedUpdate, allowIncrementalUpdate: true))

        #expect(transport.displayedLogForTesting.hasSuffix(" appended"))
        #expect(transport.logAppendCountForTesting == appendCount + 1)
        #expect(transport.logReloadCountForTesting == reloadCount)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        let updateRenderCount = transport.renderCountForTesting
        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        job.appendLogEntry(.init(kind: .agentMessage, groupID: "msg_1", text: " one"))
        job.appendLogEntry(.init(kind: .agentMessage, groupID: "msg_1", text: " two"))

        let snapshot = try await awaitTransportRender(transport, after: updateRenderCount)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        let updateRenderCount = transport.renderCountForTesting
        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        let wordGlowCount = transport.logWordGlowCountForTesting
        job.appendLogEntry(.init(kind: .progress, groupID: "progress_1", text: "stream.tick 001"))
        job.appendLogEntry(.init(kind: .progress, groupID: "progress_2", text: "stream.tick 002"))

        let snapshot = try await awaitTransportRender(transport, after: updateRenderCount)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)
        transport.view.layoutSubtreeIfNeeded()

        let initialDocumentFrame = transport.logDocumentViewFrameForTesting
        #expect(transport.isLogPinnedToBottomForTesting)
        #expect(abs(transport.logMaximumVerticalScrollOffsetForTesting - transport.logMinimumVerticalScrollOffsetForTesting) < 0.5)

        let appendRenderCount = transport.renderCountForTesting
        job.appendLogEntry(.init(
            kind: .progress,
            text: "stream.tick 001 delta/layout +2 -0 while the short log remains below the scrollable viewport height"
        ))
        _ = try await awaitTransportRender(transport, after: appendRenderCount)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        let reloadRenderCount = transport.renderCountForTesting
        let appendCount = transport.logAppendCountForTesting
        let replaceCount = transport.logReplaceCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        job.appendLogEntry(.init(kind: .plan, groupID: "plan_1", replacesGroup: true, text: "- updated"))

        let snapshot = try await awaitTransportRender(transport, after: reloadRenderCount)
        #expect(snapshot.log == "- updated")
        #expect(transport.logAppendCountForTesting == appendCount)
        #expect(transport.logReplaceCountForTesting == replaceCount + 1)
        #expect(transport.logReloadCountForTesting == reloadCount)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        let replacementRenderCount = transport.renderCountForTesting
        job.appendLogEntry(.init(
            kind: .plan,
            groupID: "plan_1",
            replacesGroup: true,
            text: "- updated with longer replacement text"
        ))
        _ = try await awaitTransportRender(transport, after: replacementRenderCount)

        let stableRenderCount = transport.renderCountForTesting
        let replaceCount = transport.logReplaceCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        job.appendLogEntry(.init(kind: .commandOutput, groupID: "cmd_1", text: "hidden output"))

        await transport.flushMainQueueForTesting()

        #expect(transport.displayedLogForTesting == "- updated with longer replacement text")
        #expect(transport.renderCountForTesting == stableRenderCount)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        let metadataRenderCount = transport.renderCountForTesting
        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        job.core.output.summary = "Updated summary."

        await transport.flushMainQueueForTesting()

        #expect(transport.renderCountForTesting == metadataRenderCount)
        #expect(transport.displayedLogForTesting == "Initial log")
        #expect(transport.logAppendCountForTesting == appendCount)
        #expect(transport.logReloadCountForTesting == reloadCount)
    }

    @Test func reasoningAppendCreatesLineGlowAndReduceMotionDisablesGlow() async throws {
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        let reasoningRenderCount = transport.renderCountForTesting
        job.appendLogEntry(.init(kind: .rawReasoning, groupID: "reasoning_1", text: " through options"))
        _ = try await awaitTransportRender(transport, after: reasoningRenderCount)

        #expect(transport.logWordGlowCountForTesting == 2)
        #expect(transport.logReasoningLineGlowCountForTesting == 1)

        transport.setLogReduceMotionForTesting(true)
        let reduceMotionRenderCount = transport.renderCountForTesting
        job.appendLogEntry(.init(kind: .rawReasoning, groupID: "reasoning_1", text: " without animation"))
        _ = try await awaitTransportRender(transport, after: reduceMotionRenderCount)

        #expect(transport.logWordGlowCountForTesting == 0)
        #expect(transport.logReasoningLineGlowCountForTesting == 0)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)
        #expect(transport.isLogPinnedToBottomForTesting)

        transport.scrollLogToBottomForTesting()
        #expect(transport.isLogPinnedToBottomForTesting)

        transport.scrollLogToTopForTesting()
        #expect(transport.isLogPinnedToBottomForTesting == false)

        let unpinnedRenderCount = transport.renderCountForTesting
        let unpinnedAutoFollow = transport.logAutoFollowCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "Unpinned update"))
        _ = try await awaitTransportRender(transport, after: unpinnedRenderCount)
        #expect(transport.logAutoFollowCountForTesting == unpinnedAutoFollow)
        #expect(transport.isLogPinnedToBottomForTesting == false)

        transport.scrollLogToBottomForTesting()
        #expect(transport.isLogPinnedToBottomForTesting)

        let pinnedRenderCount = transport.renderCountForTesting
        let pinnedAutoFollow = transport.logAutoFollowCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "Pinned update"))
        _ = try await awaitTransportRender(transport, after: pinnedRenderCount)
        #expect(transport.logAutoFollowCountForTesting == pinnedAutoFollow + 1)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        let nearBottomOffset = transport.logMaximumVerticalScrollOffsetForTesting - 12
        transport.scrollLogToOffsetForTesting(nearBottomOffset)
        #expect(transport.isLogPinnedToBottomForTesting == false)
        let offsetBeforeAppend = transport.logVerticalScrollOffsetForTesting
        let autoFollowBeforeAppend = transport.logAutoFollowCountForTesting
        let programmaticScrollsBeforeAppend = transport.logProgrammaticScrollCountForTesting

        let appendRenderCount = transport.renderCountForTesting
        job.appendLogEntry(.init(
            kind: .progress,
            text: "Near-bottom append should not snap inertial or manual scrolling to the document end"
        ))
        _ = try await awaitTransportRender(transport, after: appendRenderCount)

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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.scrollLogToBottomForTesting()
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting

        let updateRenderCount = transport.renderCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "Newest line"))
        _ = try await awaitTransportRender(transport, after: updateRenderCount)

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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        transport.setLogScrollerStyleForTesting(.legacy)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.scrollLogToBottomForTesting()
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting

        let updateRenderCount = transport.renderCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "Newest line"))
        _ = try await awaitTransportRender(transport, after: updateRenderCount)

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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting

        let updateRenderCount = transport.renderCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "short update"))
        _ = try await awaitTransportRender(transport, after: updateRenderCount)

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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(firstJob)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.scrollLogToOffsetForTesting(120)

        let secondRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(secondJob)
        _ = try await awaitTransportRender(transport, after: secondRenderCount)

        let hideCountBeforeRestore = transport.logOverlayScrollerHideRequestCountForTesting
        let thirdRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(firstJob)
        _ = try await awaitTransportRender(transport, after: thirdRenderCount)

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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.setLogOverlayScrollerBridgeModeForTesting(.missingScrollerImpPair)

        let updateRenderCount = transport.renderCountForTesting
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "Newest line"))
        _ = try await awaitTransportRender(transport, after: updateRenderCount)

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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.setLogOverlayScrollerBridgeModeForTesting(.missingHideMethods)

        let updateRenderCount = transport.renderCountForTesting
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "Newest line"))
        _ = try await awaitTransportRender(transport, after: updateRenderCount)

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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)
        let appendCount = transport.logAppendCountForTesting

        let updateRenderCount = transport.renderCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "Newest fragment line"))
        _ = try await awaitTransportRender(transport, after: updateRenderCount)

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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

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

    @Test func logFindUsesSystemHighlightingAndKeepsSearchStringCurrentAfterAppend() async throws {
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(transport, after: initialRenderCount)

        let renderedInitialLog = job.reviewMonitorLogDocument.text
        let renderedInitialLength = (renderedInitialLog as NSString).length
        let visibleRanges = transport.logFindVisibleCharacterRangesForTesting
        #expect(transport.logFindFeedbackDimmingEnabledForTesting)
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
        #expect(transport.logFindFeedbackDimmingEnabledForTesting)

        let findStringWillChangeCountBeforeAppend = transport.logFindClientStringWillChangeCountForTesting
        let findIndicatorInvalidationCountBeforeAppend = transport.logFindIndicatorInvalidationCountForTesting
        let appendRenderCount = transport.renderCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "needle appended"))
        _ = try await awaitTransportRender(transport, after: appendRenderCount)

        let appendedLength = (job.reviewMonitorLogDocument.text as NSString).length
        let appendedVisibleRanges = transport.logFindVisibleCharacterRangesForTesting
        #expect(transport.logFindClientStringWillChangeCountForTesting == findStringWillChangeCountBeforeAppend)
        #expect(transport.logFindIndicatorInvalidationCountForTesting > findIndicatorInvalidationCountBeforeAppend)
        #expect(transport.logFindStringLengthForTesting == appendedLength)
        #expect(transport.logSelectedTextForTesting == "needle")
        #expect(appendedVisibleRanges.isEmpty == false)
        #expect(appendedVisibleRanges.allSatisfy { $0.location >= 0 && NSMaxRange($0) <= appendedLength })

        let middleOffset = transport.logMaximumVerticalScrollOffsetForTesting / 2
        transport.scrollLogToOffsetForTesting(middleOffset)
        #expect(transport.isLogPinnedToBottomForTesting == false)

        let offsetBeforeMiddleAppend = transport.logVerticalScrollOffsetForTesting
        let findStringWillChangeCountBeforeMiddleAppend = transport.logFindClientStringWillChangeCountForTesting
        let findIndicatorInvalidationCountBeforeMiddleAppend = transport.logFindIndicatorInvalidationCountForTesting
        let middleAppendRenderCount = transport.renderCountForTesting
        job.appendLogEntry(.init(kind: .progress, text: "needle appended while the log is not following bottom"))
        _ = try await awaitTransportRender(transport, after: middleAppendRenderCount)

        #expect(abs(transport.logVerticalScrollOffsetForTesting - offsetBeforeMiddleAppend) < 0.5)
        #expect(transport.logFindClientStringWillChangeCountForTesting == findStringWillChangeCountBeforeMiddleAppend)
        #expect(transport.logFindIndicatorInvalidationCountForTesting > findIndicatorInvalidationCountBeforeMiddleAppend)
        #expect(transport.logSelectedTextForTesting == "needle")

        viewController.performTextFinderAction(textFinderMenuItemForTesting(.hideFindInterface))
        #expect(transport.logFindBarVisibleForTesting == false)
        #expect(transport.logFindFeedbackDimmingEnabledForTesting)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let snapshot = try await awaitTransportRender(transport, after: initialRenderCount)
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

        let initialRenderCount = transport.renderCountForTesting
        viewController.sidebarViewControllerForTesting.selectJobForTesting(job)

        let snapshot = try await awaitTransportRender(transport, after: initialRenderCount)
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
    contentTransitionAnimator: @escaping ReviewMonitorContentTransitionAnimator = ReviewMonitorRootViewController.defaultContentTransitionAnimator
) -> ReviewMonitorWindowHarness {
    applyTestAuthState(auth: store.auth, state: authState)
    let windowController = ReviewMonitorWindowController(
        store: store,
        contentTransitionAnimator: contentTransitionAnimator
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
    timeout: Duration = .seconds(2)
) async throws {
    let viewControllerBox = UncheckedSendableBox(viewController)
    try await withTestTimeout(timeout) {
        while await MainActor.run(body: {
            viewControllerBox.value.sidebarPresentationForTesting != expected
        }) {
            try Task.checkCancellation()
            await Task.yield()
        }
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
func awaitTransportRender(
    _ transport: ReviewMonitorTransportViewController,
    after renderCount: Int,
    timeout: Duration = .seconds(2)
) async throws -> ReviewMonitorTransportViewController.RenderSnapshotForTesting {
    let transportBox = UncheckedSendableBox(transport)
    return try await withTestTimeout(timeout) {
        await transportBox.value.waitForRenderCountForTesting(renderCount + 1)
        return await MainActor.run {
            transportBox.value.renderSnapshotForTesting
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
    after renderCount: Int,
    timeout: Duration = .seconds(2)
) async throws -> ReviewMonitorTransportViewController.RenderSnapshotForTesting {
    let contentPaneBox = UncheckedSendableBox(contentPane)
    return try await withTestTimeout(timeout) {
        await contentPaneBox.value.waitForRenderCountForTesting(renderCount + 1)
        return await MainActor.run {
            contentPaneBox.value.renderSnapshotForTesting
        }
    }
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
    startedAt: Date = Date(),
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
