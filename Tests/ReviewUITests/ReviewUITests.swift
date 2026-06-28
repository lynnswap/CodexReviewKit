import AppKit
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

@MainActor
func chatIDForTesting(_ job: CodexReviewJob) -> CodexThreadID {
    guard let chatID = job.legacyReviewChatID else {
        Issue.record("Expected review job \(job.id) to have a chat id.")
        return CodexThreadID(rawValue: job.id)
    }
    return chatID
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        #expect(
            viewController.sidebarViewControllerForTesting.displayedSectionTitlesForTesting == [
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
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

        #expect(
            sidebar.displayedSectionTitlesForTesting == [
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        guard let workspaceAlpha = store.workspaces.first(where: { $0.cwd == "/tmp/workspace-alpha" }),
            let workspaceBeta = store.workspaces.first(where: { $0.cwd == "/tmp/workspace-beta" })
        else {
            Issue.record("workspaces were not loaded.")
            return
        }

        #expect(sidebar.performWorkspaceDropForTesting(workspaceBeta, proposedWorkspace: workspaceAlpha))
        #expect(
            sidebar.displayedSectionTitlesForTesting == [
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        let fullReloadCountBeforeMembershipChange = sidebar.sidebarFullReloadCountForTesting
        let incrementalMoveCountBeforeMembershipChange = sidebar.sidebarIncrementalMoveCountForTesting
        let incrementalMembershipChangeCountBeforeMembershipChange = sidebar
            .sidebarIncrementalMembershipChangeCountForTesting

        store.loadForTesting(
            serverState: .running,
            workspaces: [alphaWorkspace, betaWorkspace],
            jobs: [alphaJob, betaJob]
        )
        try await waitForObservedValue(
            from: sidebar.sidebarTopologyObservationForTesting,
            [
                "workspace-alpha",
                "workspace-beta",
            ]
        ) {
            sidebar.displayedSectionTitlesForTesting
        }

        #expect(
            sidebar.displayedSectionTitlesForTesting == [
                "workspace-alpha",
                "workspace-beta",
            ])
        #expect(sidebar.sidebarFullReloadCountForTesting == fullReloadCountBeforeMembershipChange)
        #expect(sidebar.sidebarIncrementalMoveCountForTesting == incrementalMoveCountBeforeMembershipChange)
        #expect(
            sidebar.sidebarIncrementalMembershipChangeCountForTesting
                == incrementalMembershipChangeCountBeforeMembershipChange + 1)
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
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
            from: sidebar.sidebarTopologyObservationForTesting,
            [
                "workspace-beta",
                "workspace-alpha",
            ]
        ) {
            sidebar.displayedSectionTitlesForTesting
        }

        #expect(sidebar.sidebarFullReloadCountForTesting == fullReloadCountBeforeChange)
        #expect(
            sidebar.sidebarIncrementalMembershipChangeCountForTesting == incrementalMembershipChangeCountBeforeChange)
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.blankAreaWorkspaceInsertionIndexForTesting(atEnd: false) == 0)
        #expect(sidebar.blankAreaWorkspaceInsertionIndexForTesting(atEnd: true) == store.workspaces.count)
    }

    @Test func workspaceDropOnReviewChatRowReordersSection() async {
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        guard let workspaceBeta = store.workspaces.first(where: { $0.cwd == "/tmp/workspace-beta" }),
            let workspaceAlpha = store.workspaces.first(where: { $0.cwd == "/tmp/workspace-alpha" }),
            let betaJob = store.orderedJobs(in: workspaceBeta).first
        else {
            Issue.record("workspace/job state was not loaded.")
            return
        }

        #expect(sidebar.displayedSectionTitlesForTesting == [workspaceAlpha.displayTitle, workspaceBeta.displayTitle])
        #expect(
            sidebar.performWorkspaceDropForTesting(
                workspaceAlpha,
                proposedJob: betaJob,
                hoveringBelowMidpoint: true
            ))
        await Task.yield()
        #expect(sidebar.displayedSectionTitlesForTesting == [workspaceBeta.displayTitle, workspaceAlpha.displayTitle])
    }

    @Test func reviewChatDropOnBlankAreaMovesToFullOrderEnd() async {
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.performJobBlankAreaDropForTesting(firstJob))
        await Task.yield()
        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: workspace) == ["job-blank-area-peer", "job-blank-area-reject"])
        #expect(store.orderedJobs(in: workspace).map(\.id) == ["job-blank-area-peer", "job-blank-area-reject"])
    }

    @Test func reviewChatDropReordersWithinWorkspaceAndPreservesSelection() async throws {
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.selectReviewChatForTesting(id: chatIDForTesting(firstJob))
        let fullReloadCountBeforeDrop = sidebar.sidebarFullReloadCountForTesting
        let workspaceReloadCountBeforeDrop = sidebar.sidebarWorkspaceReloadCountForTesting
        let incrementalMoveCountBeforeDrop = sidebar.sidebarIncrementalMoveCountForTesting
        let firstReviewChatRowHeightBeforeDrop = try #require(sidebar.reviewChatRowHeightForTesting(firstJob))
        let secondReviewChatRowHeightBeforeDrop = try #require(sidebar.reviewChatRowHeightForTesting(secondJob))
        #expect(firstReviewChatRowHeightBeforeDrop == secondReviewChatRowHeightBeforeDrop)
        #expect(
            sidebar.performReviewChatDropForTesting(
                firstJob,
                proposedJob: secondJob,
                hoveringBelowMidpoint: false
            ) == false)
        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: workspace) == ["job-1", "job-2"])

        #expect(
            sidebar.performReviewChatDropForTesting(
                firstJob,
                proposedJob: secondJob,
                hoveringBelowMidpoint: true
            ))
        await Task.yield()
        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: workspace) == ["job-2", "job-1"])
        #expect(sidebar.selectedReviewChatIDForTesting == firstJob.legacyReviewChatID)
        #expect(sidebar.sidebarFullReloadCountForTesting == fullReloadCountBeforeDrop)
        #expect(sidebar.sidebarWorkspaceReloadCountForTesting == workspaceReloadCountBeforeDrop)
        #expect(sidebar.sidebarIncrementalMoveCountForTesting == incrementalMoveCountBeforeDrop + 1)
        #expect(sidebar.reviewChatRowHeightForTesting(firstJob) == firstReviewChatRowHeightBeforeDrop)
        #expect(sidebar.reviewChatRowHeightForTesting(secondJob) == secondReviewChatRowHeightBeforeDrop)
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
        uiState.sidebarReviewChatFilter = .running

        try await waitForObservedValueFromCurrentObservation(
            from: { sidebar.sidebarTopologyObservationForTesting },
            ["job-alpha-running", "job-alpha-queued"]
        ) {
            sidebar.displayedReviewChatJobIDsForTesting(in: alphaWorkspace)
        }
        #expect(
            sidebar.displayedSectionTitlesForTesting == [
                "workspace-alpha",
                "workspace-beta",
            ])
        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: alphaWorkspace) == ["job-alpha-running", "job-alpha-queued"])
        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: betaWorkspace) == [])
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
        uiState.sidebarReviewChatFilter = .running
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: workspace) == ["job-filter-state"])

        runningJob.updateStateForTesting(
            status: .succeeded,
            endedAt: Date(timeIntervalSince1970: 201)
        )
        try await waitForObservedValue(
            from: sidebar.sidebarTopologyObservationForTesting,
            [String]()
        ) {
            sidebar.displayedReviewChatJobIDsForTesting(in: workspace)
        }

        runningJob.updateStateForTesting(status: .running, clearEndedAt: true)
        try await waitForObservedValue(
            from: sidebar.sidebarTopologyObservationForTesting,
            ["job-filter-state"]
        ) {
            sidebar.displayedReviewChatJobIDsForTesting(in: workspace)
        }
    }

    @Test func sidebarRunningFilterDoesNotClearHiddenSelectedReviewChat() async throws {
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
        sidebar.selectReviewChatForTesting(id: chatIDForTesting(completedJob))
        #expect(sidebar.selectedReviewChatIDForTesting == completedJob.legacyReviewChatID)

        uiState.sidebarReviewChatFilter = .running
        try await waitForObservedValueFromCurrentObservation(
            from: { sidebar.sidebarTopologyObservationForTesting },
            ["job-filter-running"]
        ) {
            sidebar.displayedReviewChatJobIDsForTesting(in: workspace)
        }

        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: workspace) == ["job-filter-running"])
        #expect(sidebar.selectedReviewChatIDForTesting == completedJob.legacyReviewChatID)
    }

    @Test func sidebarLatestFinishedFilterKeepsWorkspacesAndShowsLatestTerminalJob() async throws {
        let alphaRunningJob = makeJob(
            id: "job-alpha-running",
            cwd: "/tmp/workspace-alpha",
            startedAt: Date(timeIntervalSince1970: 400),
            status: .running,
            targetSummary: "Running alpha"
        )
        let alphaQueuedJob = makeJob(
            id: "job-alpha-queued",
            cwd: "/tmp/workspace-alpha",
            startedAt: Date(timeIntervalSince1970: 500),
            status: .queued,
            targetSummary: "Queued alpha"
        )
        let alphaSucceededJob = makeJob(
            id: "job-alpha-succeeded",
            cwd: "/tmp/workspace-alpha",
            startedAt: Date(timeIntervalSince1970: 100),
            status: .succeeded,
            targetSummary: "Succeeded alpha"
        )
        let alphaCancelledJob = makeJob(
            id: "job-alpha-cancelled",
            cwd: "/tmp/workspace-alpha",
            startedAt: Date(timeIntervalSince1970: 200),
            status: .cancelled,
            targetSummary: "Cancelled alpha"
        )
        let alphaFailedJob = makeJob(
            id: "job-alpha-failed",
            cwd: "/tmp/workspace-alpha",
            startedAt: Date(timeIntervalSince1970: 300),
            status: .failed,
            targetSummary: "Failed alpha"
        )
        alphaFailedJob.updateStateForTesting(clearEndedAt: true)
        let betaCancelledJob = makeJob(
            id: "job-beta-cancelled",
            cwd: "/tmp/workspace-beta",
            startedAt: Date(timeIntervalSince1970: 250),
            status: .cancelled,
            targetSummary: "Cancelled beta"
        )
        let gammaRunningJob = makeJob(
            id: "job-gamma-running",
            cwd: "/tmp/workspace-gamma",
            startedAt: Date(timeIntervalSince1970: 600),
            status: .running,
            targetSummary: "Running gamma"
        )
        let alphaWorkspace = CodexReviewWorkspace(cwd: "/tmp/workspace-alpha")
        let betaWorkspace = CodexReviewWorkspace(cwd: "/tmp/workspace-beta")
        let gammaWorkspace = CodexReviewWorkspace(cwd: "/tmp/workspace-gamma")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [alphaWorkspace, betaWorkspace, gammaWorkspace],
            jobs: [
                alphaRunningJob,
                alphaQueuedJob,
                alphaSucceededJob,
                alphaCancelledJob,
                alphaFailedJob,
                betaCancelledJob,
                gammaRunningJob,
            ]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.selectReviewChatForTesting(id: chatIDForTesting(alphaRunningJob))
        uiState.sidebarReviewChatFilter = .latestFinished

        try await waitForObservedValueFromCurrentObservation(
            from: { sidebar.sidebarTopologyObservationForTesting },
            ["job-alpha-failed"]
        ) {
            sidebar.displayedReviewChatJobIDsForTesting(in: alphaWorkspace)
        }
        #expect(
            sidebar.displayedSectionTitlesForTesting == [
                "workspace-alpha",
                "workspace-beta",
                "workspace-gamma",
            ])
        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: alphaWorkspace) == ["job-alpha-failed"])
        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: betaWorkspace) == ["job-beta-cancelled"])
        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: gammaWorkspace) == [])
        #expect(sidebar.selectedReviewChatIDForTesting == alphaRunningJob.legacyReviewChatID)
    }

    @Test func sidebarLatestFinishedFilterFollowsTerminalDateChanges() async throws {
        let firstJob = makeJob(
            id: "job-finished-first",
            cwd: "/tmp/workspace-alpha",
            startedAt: Date(timeIntervalSince1970: 100),
            status: .succeeded,
            targetSummary: "First finished"
        )
        let secondJob = makeJob(
            id: "job-finished-second",
            cwd: "/tmp/workspace-alpha",
            startedAt: Date(timeIntervalSince1970: 200),
            status: .failed,
            targetSummary: "Second finished"
        )
        let runningJob = makeJob(
            id: "job-running",
            cwd: "/tmp/workspace-alpha",
            startedAt: Date(timeIntervalSince1970: 300),
            status: .running,
            targetSummary: "Running"
        )
        let workspace = CodexReviewWorkspace(cwd: "/tmp/workspace-alpha")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            jobs: [firstJob, secondJob, runningJob]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarReviewChatFilter = .latestFinished
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: workspace) == ["job-finished-second"])

        firstJob.updateStateForTesting(endedAt: Date(timeIntervalSince1970: 400))
        try await waitForObservedValue(
            from: sidebar.sidebarTopologyObservationForTesting,
            ["job-finished-first"]
        ) {
            sidebar.displayedReviewChatJobIDsForTesting(in: workspace)
        }

        runningJob.updateStateForTesting(
            status: .cancelled,
            endedAt: Date(timeIntervalSince1970: 500)
        )
        try await waitForObservedValue(
            from: sidebar.sidebarTopologyObservationForTesting,
            ["job-running"]
        ) {
            sidebar.displayedReviewChatJobIDsForTesting(in: workspace)
        }
    }

    @Test func sidebarRunningAndLatestFinishedFiltersCombineVisibleJobs() async throws {
        let runningJob = makeJob(
            id: "job-running",
            cwd: "/tmp/workspace-alpha",
            startedAt: Date(timeIntervalSince1970: 400),
            status: .running,
            targetSummary: "Running"
        )
        let queuedJob = makeJob(
            id: "job-queued",
            cwd: "/tmp/workspace-alpha",
            startedAt: Date(timeIntervalSince1970: 500),
            status: .queued,
            targetSummary: "Queued"
        )
        let olderFinishedJob = makeJob(
            id: "job-finished-older",
            cwd: "/tmp/workspace-alpha",
            startedAt: Date(timeIntervalSince1970: 100),
            status: .succeeded,
            targetSummary: "Older finished"
        )
        let latestFinishedJob = makeJob(
            id: "job-finished-latest",
            cwd: "/tmp/workspace-alpha",
            startedAt: Date(timeIntervalSince1970: 300),
            status: .failed,
            targetSummary: "Latest finished"
        )
        let workspace = CodexReviewWorkspace(cwd: "/tmp/workspace-alpha")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            jobs: [runningJob, olderFinishedJob, queuedJob, latestFinishedJob]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarReviewChatFilter = [.running, .latestFinished]
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(
            sidebar.displayedReviewChatJobIDsForTesting(in: workspace) == [
                "job-running",
                "job-queued",
                "job-finished-latest",
            ])
    }

    @Test func reviewChatDropWhileFilteredMapsVisibleIndexToStoreOrder() async throws {
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
        uiState.sidebarReviewChatFilter = .running
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: workspace) == ["job-running-a", "job-running-b"])

        #expect(
            sidebar.performReviewChatDropForTesting(
                runningA,
                proposedJob: runningB,
                hoveringBelowMidpoint: false
            ) == false)
        await Task.yield()

        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: workspace) == ["job-running-a", "job-running-b"])
        #expect(
            store.orderedJobs(in: workspace).map(\.id) == [
                "job-hidden-prefix",
                "job-running-a",
                "job-hidden-middle",
                "job-running-b",
                "job-hidden-suffix",
            ])

        #expect(
            sidebar.performReviewChatDropForTesting(
                runningA,
                proposedJob: runningB,
                hoveringBelowMidpoint: true
            ))
        await Task.yield()

        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: workspace) == ["job-running-b", "job-running-a"])
        #expect(
            store.orderedJobs(in: workspace).map(\.id) == [
                "job-hidden-prefix",
                "job-hidden-middle",
                "job-running-b",
                "job-running-a",
                "job-hidden-suffix",
            ])

        #expect(sidebar.performJobBlankAreaDropForTesting(runningA))
        await Task.yield()

        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: workspace) == ["job-running-b", "job-running-a"])
        #expect(
            store.orderedJobs(in: workspace).map(\.id) == [
                "job-hidden-prefix",
                "job-hidden-middle",
                "job-running-b",
                "job-hidden-suffix",
                "job-running-a",
            ])
    }

    @Test func reviewChatDropIsRejectedForLatestFinishedOnlyFilter() {
        let runningJob = makeJob(
            id: "job-running",
            cwd: "/tmp/workspace-alpha",
            startedAt: Date(timeIntervalSince1970: 300),
            status: .running,
            targetSummary: "Running"
        )
        let olderJob = makeJob(
            id: "job-finished-older",
            cwd: "/tmp/workspace-alpha",
            startedAt: Date(timeIntervalSince1970: 100),
            status: .succeeded,
            targetSummary: "Older finished"
        )
        let latestJob = makeJob(
            id: "job-finished-latest",
            cwd: "/tmp/workspace-alpha",
            startedAt: Date(timeIntervalSince1970: 200),
            status: .failed,
            targetSummary: "Latest finished"
        )
        let workspace = CodexReviewWorkspace(cwd: "/tmp/workspace-alpha")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            jobs: [runningJob, olderJob, latestJob]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarReviewChatFilter = .latestFinished
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: workspace) == ["job-finished-latest"])
        #expect(sidebar.performReviewChatDropForTesting(latestJob, proposedWorkspace: workspace, childIndex: 0) == false)
    }

    @Test func reviewChatDropWhileRunningAndLatestFinishedFilterReordersVisibleReviewChats() async throws {
        let runningJob = makeJob(
            id: "job-running",
            cwd: "/tmp/workspace-alpha",
            startedAt: Date(timeIntervalSince1970: 300),
            status: .running,
            targetSummary: "Running"
        )
        let olderJob = makeJob(
            id: "job-finished-older",
            cwd: "/tmp/workspace-alpha",
            startedAt: Date(timeIntervalSince1970: 100),
            status: .succeeded,
            targetSummary: "Older finished"
        )
        let latestJob = makeJob(
            id: "job-finished-latest",
            cwd: "/tmp/workspace-alpha",
            startedAt: Date(timeIntervalSince1970: 200),
            status: .failed,
            targetSummary: "Latest finished"
        )
        let workspace = CodexReviewWorkspace(cwd: "/tmp/workspace-alpha")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            jobs: [runningJob, olderJob, latestJob]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarReviewChatFilter = [.running, .latestFinished]
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: workspace) == ["job-running", "job-finished-latest"])
        #expect(sidebar.performReviewChatDropForTesting(runningJob, proposedWorkspace: workspace, childIndex: 2))
        await Task.yield()

        try await waitForObservedValueFromCurrentObservation(
            from: { sidebar.sidebarTopologyObservationForTesting },
            ["job-finished-latest", "job-running"]
        ) {
            sidebar.displayedReviewChatJobIDsForTesting(in: workspace)
        }
        #expect(
            store.orderedJobs(in: workspace).map(\.id) == [
                "job-finished-older",
                "job-finished-latest",
                "job-running",
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
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
            from: sidebar.sidebarTopologyObservationForTesting,
            [
                "job-sort-order-2",
                "job-sort-order-1",
            ]
        ) {
            sidebar.displayedReviewChatJobIDsForTesting(in: workspace)
        }

        #expect(sidebar.sidebarFullReloadCountForTesting == fullReloadCountBeforeChange)
        #expect(sidebar.sidebarWorkspaceReloadCountForTesting == workspaceReloadCountBeforeChange)
        #expect(
            sidebar.sidebarIncrementalMembershipChangeCountForTesting == incrementalMembershipChangeCountBeforeChange)
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
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
            from: sidebar.sidebarTopologyObservationForTesting,
            [
                "job-membership-1",
                "job-membership-2",
            ]
        ) {
            sidebar.displayedReviewChatJobIDsForTesting(in: workspace)
        }

        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: workspace) == ["job-membership-1", "job-membership-2"])
        #expect(sidebar.sidebarFullReloadCountForTesting == fullReloadCountBeforeChange)
        #expect(sidebar.sidebarWorkspaceReloadCountForTesting == workspaceReloadCountBeforeChange)
        #expect(
            sidebar.sidebarIncrementalMembershipChangeCountForTesting == incrementalMembershipChangeCountBeforeChange
                + 1)
        #expect(sidebar.sidebarIncrementalMoveCountForTesting == incrementalMoveCountBeforeChange)
    }

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
        let activeAccount = CodexReviewAccount(email: "first@example.com", planType: "pro")
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
        let activeAccount = CodexReviewAccount(email: "first@example.com", planType: "pro")
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
        let activeAccount = CodexReviewAccount(email: "active@example.com", planType: "pro")
        let otherAccount = CodexReviewAccount(email: "other@example.com", planType: "plus")
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

    @Test func reviewChatCellViewUpdatesHostedObservationReferenceWithoutReplacingHostingView() throws {
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

        let cellView = makeReviewMonitorReviewChatCellViewForTesting(job: placeholderJob)
        let initialHostingViewIdentity = try #require(
            reviewMonitorReviewChatCellHostingViewIdentityForTesting(cellView)
        )
        let initialHostedRowID = reviewMonitorReviewChatCellHostedRowIDForTesting(cellView)

        configureReviewMonitorReviewChatCellViewForTesting(cellView, job: loadedJob)

        let updatedHostingViewIdentity = try #require(
            reviewMonitorReviewChatCellHostingViewIdentityForTesting(cellView)
        )
        let updatedHostedRowID = reviewMonitorReviewChatCellHostedRowIDForTesting(cellView)

        #expect(initialHostedRowID == placeholderJob.id)
        #expect(updatedHostedRowID == loadedJob.legacyReviewChatID?.rawValue)
        #expect(initialHostingViewIdentity == updatedHostingViewIdentity)
        #expect((cellView.objectValue as? ReviewMonitorSidebarReviewChatRow)?.operation.jobID == loadedJob.id)
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

        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [alphaWorkspace, betaWorkspace],
            jobs: [alphaJob, betaJob]
        )
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.collapseWorkspaceInOutlineForTesting(betaWorkspace)
        #expect(sidebar.workspaceIsExpandedForTesting(betaWorkspace) == false)
        #expect(sidebar.performWorkspaceDropForTesting(betaWorkspace, toIndex: 0))
        #expect(sidebar.workspaceIsExpandedForTesting(betaWorkspace) == false)
    }

    @Test func crossWorkspaceReviewChatDropIsRejected() {
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.performReviewChatDropForTesting(alphaJob, proposedWorkspace: betaWorkspace, childIndex: 0) == false)
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.allWorkspaceRowsExpandedForTesting)
        #expect(sidebar.workspaceIsSelectableForTesting(workspace))
        #expect(sidebar.floatsGroupRowsEnabledForTesting == false)
        #expect(sidebar.draggingDestinationFeedbackStyleForTesting == .sourceList)
        #expect(sidebar.sidebarUsesAutomaticRowHeightsForTesting == false)
        #expect(sidebar.reviewChatRowUsesReviewMonitorChatRowViewForTesting(job))
    }

    @Test func sidebarUsesMeasuredRowHeightsForWorkspaceAndReviewChatRows() throws {
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 360, height: 260))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        let workspaceRowHeight = try #require(sidebar.workspaceRowHeightForTesting(workspace))
        let reviewChatRowHeight = try #require(sidebar.reviewChatRowHeightForTesting(job))
        #expect(workspaceRowHeight == sidebar.expectedWorkspaceRowRectHeightForTesting)
        #expect(reviewChatRowHeight == sidebar.expectedReviewChatRowRectHeightForTesting)
        #expect(workspaceRowHeight < reviewChatRowHeight)
    }

    @Test func reviewChatRowsUseLabelIconSlotInsteadOfOutlineChildIndent() throws {
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 360, height: 260))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        let workspaceCellMinX = try #require(sidebar.workspaceCellMinXForTesting(workspace))
        let reviewChatCellMinX = try #require(sidebar.reviewChatCellMinXForTesting(job))
        #expect(reviewChatCellMinX < workspaceCellMinX)
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 360, height: 260))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.displayedSectionTitlesForTesting == ["workspace-alpha"])
        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: workspace) == [])
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        sidebar.collapseWorkspaceInOutlineForTesting(storedWorkspace)
        try await waitForCondition {
            sidebar.workspaceIsExpandedForTesting(storedWorkspace) == false
                && sidebar.workspaceOutlineIsExpandedForTesting(storedWorkspace) == false
        }

        sidebar.expandWorkspaceInOutlineForTesting(storedWorkspace)
        try await waitForCondition {
            sidebar.workspaceIsExpandedForTesting(storedWorkspace)
                && sidebar.workspaceOutlineIsExpandedForTesting(storedWorkspace)
                && sidebar.selectedReviewChatIDForTesting == job.legacyReviewChatID
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        await viewController.sidebarViewControllerForTesting.cancelReviewChatForTesting(job)

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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        await viewController.sidebarViewControllerForTesting.cancelReviewChatForTesting(job)

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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
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
        let activeAccount = CodexReviewAccount(email: "active@example.com", planType: "pro")
        let otherAccount = CodexReviewAccount(email: "other@example.com", planType: "plus")
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
            from: accountsViewController.accountPromptObservationForTesting,
            true
        ) {
            accountsViewController.selectedAccountEmailForTesting == "active@example.com"
        }

        #expect(accountsViewController.selectedAccountEmailForTesting == "active@example.com")
    }

    @Test func reviewChatsPresentOnInitialLoadStayUnselected() {
        let activeJob = makeJob(status: .running, targetSummary: "Uncommitted changes")
        let recentJob = makeJob(status: .succeeded, targetSummary: "Commit: abc123")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [activeJob, recentJob])
        )
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarViewControllerForTesting.selectedReviewChatIDForTesting == nil)
        #expect(viewController.contentPaneViewControllerForTesting.isShowingEmptyStateForTesting)
        #expect(viewController.contentPaneViewControllerForTesting.displayedTitleForTesting == nil)
    }

    @Test func selectingReviewChatUpdatesDetailPane() async throws {
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
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(recentJob))

        let selectedSnapshot = try await awaitTimelineRenderForTesting(
            recentJob,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(
            selectedSnapshot
                == .init(
                    title: nil,
                    summary: nil,
                    log: reviewMonitorLogText(for: recentJob),
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

        recentJob.updateStateForTesting(targetSummary: "Commit: def456")
        try await waitForCondition {
            window.title == "Commit: def456"
        }
        #expect(window.title == "Commit: def456")
        #expect(window.subtitle == recentJob.cwd)
        activeJob.updateStateForTesting(summary: "Old selection should not render.")
        replaceTimelineLogTextForTesting(activeJob, "Old selection log")
        appendTimelineEntryForTesting(
            recentJob, .init(kind: .progress, text: "Current selection log after stale mutation"))

        let updatedSnapshot = try await awaitTimelineRenderForTesting(recentJob, in: transport) { snapshot in
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
                    ),
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
        #expect(
            viewController.sidebarViewControllerForTesting.selectedWorkspaceSectionForTesting?.workspaceCWDs == [
                workspaceCWD
            ])
        #expect(viewController.sidebarViewControllerForTesting.selectedReviewChatIDForTesting == nil)
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
        try await waitForCondition {
            window.title == workspace.displayTitle && window.subtitle == workspace.cwd
        }
        #expect(window.title == workspace.displayTitle)
        #expect(window.subtitle == workspace.cwd)

        let findItem = textFinderMenuItemForTesting(.showFindInterface)
        #expect(viewController.validateUserInterfaceItem(findItem))
        viewController.performTextFinderAction(findItem)
        #expect(transport.workspaceFindingsFindBarVisibleForTesting)
    }

    @Test func sidebarGroupsLinkedWorktreeWorkspacesByCommonGitDirectory() async throws {
        let fixture = try makeLinkedWorktreeFixtureForTesting(repositoryName: "CodexReviewKit")
        defer {
            try? FileManager.default.removeItem(at: fixture.rootURL)
        }

        let firstWorkspace = CodexReviewWorkspace(cwd: fixture.firstWorktreeURL.path)
        let secondWorkspace = CodexReviewWorkspace(cwd: fixture.secondWorktreeURL.path)
        let firstJob = makeJob(
            id: "job-first-worktree",
            cwd: firstWorkspace.cwd,
            status: .succeeded,
            targetSummary: "Base branch: refs/pr-fix/base/40",
            reviewResult: .init(
                state: .hasFindings,
                findingCount: 1,
                findings: [
                    .init(
                        title: "[P1] Keep first worktree visible",
                        body: "The grouped sidebar should still render jobs from the first worktree.",
                        priority: 1,
                        location: .init(
                            path: "\(firstWorkspace.cwd)/Sources/First.swift",
                            startLine: 1,
                            endLine: 1
                        ),
                        rawText: ""
                    )
                ],
                source: .parsedFinalReviewText
            )
        )
        let secondJob = makeJob(
            id: "job-second-worktree",
            cwd: secondWorkspace.cwd,
            status: .succeeded,
            targetSummary: "Base branch: refs/pr-fix/base/41",
            reviewResult: .init(
                state: .hasFindings,
                findingCount: 1,
                findings: [
                    .init(
                        title: "[P2] Keep second worktree visible",
                        body: "The grouped sidebar should also render jobs from the second worktree.",
                        priority: 2,
                        location: .init(
                            path: "\(secondWorkspace.cwd)/Sources/Second.swift",
                            startLine: 2,
                            endLine: 2
                        ),
                        rawText: ""
                    )
                ],
                source: .parsedFinalReviewText
            )
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [firstWorkspace, secondWorkspace],
            jobs: [firstJob, secondJob]
        )
        let backend = makeWindowHarness(store: store)
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let sidebar = viewController.sidebarViewControllerForTesting
        let transport = viewController.transportViewControllerForTesting

        #expect(sidebar.displayedSectionTitlesForTesting == ["CodexReviewKit"])
        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: firstWorkspace) == ["job-first-worktree"])
        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: secondWorkspace) == ["job-second-worktree"])

        sidebar.clickWorkspaceHeaderForTesting(firstWorkspace)
        _ = try await awaitTransportRender(transport)

        let selectedSection = try #require(sidebar.selectedWorkspaceSectionForTesting)
        #expect(selectedSection.title == "CodexReviewKit")
        #expect(selectedSection.workspaceCWDs == [firstWorkspace.cwd, secondWorkspace.cwd])
        #expect(transport.workspaceFindingSnapshotForTesting.text.contains("Keep first worktree visible"))
        #expect(transport.workspaceFindingSnapshotForTesting.text.contains("Keep second worktree visible"))
        #expect(transport.workspaceFindingSnapshotForTesting.text.contains("Sources/First.swift:1-1"))
        #expect(transport.workspaceFindingSnapshotForTesting.text.contains("Sources/Second.swift:2-2"))
        try await waitForCondition {
            window.title == "CodexReviewKit" && window.subtitle == "2 workspaces"
        }
    }

    @Test func sidebarLatestFinishedFilterUsesLinkedWorktreeGroupLatestJob() async throws {
        let fixture = try makeLinkedWorktreeFixtureForTesting(repositoryName: "CodexReviewKit")
        defer {
            try? FileManager.default.removeItem(at: fixture.rootURL)
        }

        let firstWorkspace = CodexReviewWorkspace(cwd: fixture.firstWorktreeURL.path)
        let secondWorkspace = CodexReviewWorkspace(cwd: fixture.secondWorktreeURL.path)
        let firstJob = makeJob(
            id: "job-first-worktree-older-finished",
            cwd: firstWorkspace.cwd,
            startedAt: Date(timeIntervalSince1970: 100),
            status: .succeeded,
            targetSummary: "First worktree older finished"
        )
        let secondJob = makeJob(
            id: "job-second-worktree-newer-finished",
            cwd: secondWorkspace.cwd,
            startedAt: Date(timeIntervalSince1970: 200),
            status: .failed,
            targetSummary: "Second worktree newer finished"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [firstWorkspace, secondWorkspace],
            jobs: [firstJob, secondJob]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarReviewChatFilter = .latestFinished
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.displayedSectionTitlesForTesting == ["CodexReviewKit"])
        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: firstWorkspace) == [])
        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: secondWorkspace) == ["job-second-worktree-newer-finished"])

        firstJob.updateStateForTesting(endedAt: Date(timeIntervalSince1970: 400))
        try await waitForObservedValue(
            from: sidebar.sidebarTopologyObservationForTesting,
            ["job-first-worktree-older-finished"]
        ) {
            sidebar.displayedReviewChatJobIDsForTesting(in: firstWorkspace)
        }

        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: secondWorkspace) == [])
    }

    @Test func sidebarRunningAndLatestFinishedFilterUsesLinkedWorktreeGroupLatestJob() async throws {
        let fixture = try makeLinkedWorktreeFixtureForTesting(repositoryName: "CodexReviewKit")
        defer {
            try? FileManager.default.removeItem(at: fixture.rootURL)
        }

        let firstWorkspace = CodexReviewWorkspace(cwd: fixture.firstWorktreeURL.path)
        let secondWorkspace = CodexReviewWorkspace(cwd: fixture.secondWorktreeURL.path)
        let firstRunningJob = makeJob(
            id: "job-first-worktree-running-a",
            cwd: firstWorkspace.cwd,
            startedAt: Date(timeIntervalSince1970: 300),
            status: .running,
            targetSummary: "First worktree running A"
        )
        let firstHiddenFinishedJob = makeJob(
            id: "job-first-worktree-hidden-finished",
            cwd: firstWorkspace.cwd,
            startedAt: Date(timeIntervalSince1970: 100),
            status: .succeeded,
            targetSummary: "First worktree hidden finished"
        )
        let firstQueuedJob = makeJob(
            id: "job-first-worktree-queued-b",
            cwd: firstWorkspace.cwd,
            startedAt: Date(timeIntervalSince1970: 350),
            status: .queued,
            targetSummary: "First worktree queued B"
        )
        let secondQueuedJob = makeJob(
            id: "job-second-worktree-queued",
            cwd: secondWorkspace.cwd,
            startedAt: Date(timeIntervalSince1970: 400),
            status: .queued,
            targetSummary: "Second worktree queued"
        )
        let secondLatestFinishedJob = makeJob(
            id: "job-second-worktree-latest-finished",
            cwd: secondWorkspace.cwd,
            startedAt: Date(timeIntervalSince1970: 200),
            status: .failed,
            targetSummary: "Second worktree latest finished"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [firstWorkspace, secondWorkspace],
            jobs: [
                firstRunningJob,
                firstHiddenFinishedJob,
                firstQueuedJob,
                secondQueuedJob,
                secondLatestFinishedJob,
            ]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        uiState.sidebarReviewChatFilter = [.running, .latestFinished]
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.displayedSectionTitlesForTesting == ["CodexReviewKit"])
        #expect(
            sidebar.displayedReviewChatJobIDsForTesting(in: firstWorkspace) == [
                "job-first-worktree-running-a",
                "job-first-worktree-queued-b",
            ])
        #expect(
            sidebar.displayedReviewChatJobIDsForTesting(in: secondWorkspace) == [
                "job-second-worktree-queued",
                "job-second-worktree-latest-finished",
            ])

        #expect(
            sidebar.performReviewChatDropForTesting(
                firstRunningJob,
                proposedWorkspaceSectionContaining: secondWorkspace,
                childIndex: 3
            ) == false)

        #expect(
            sidebar.performReviewChatDropForTesting(
                firstRunningJob,
                proposedWorkspaceSectionContaining: firstWorkspace,
                childIndex: 2
            ))
        await Task.yield()

        #expect(
            sidebar.displayedReviewChatJobIDsForTesting(in: firstWorkspace) == [
                "job-first-worktree-queued-b",
                "job-first-worktree-running-a",
            ])
        #expect(
            sidebar.displayedReviewChatJobIDsForTesting(in: secondWorkspace) == [
                "job-second-worktree-queued",
                "job-second-worktree-latest-finished",
            ])
        #expect(
            store.orderedJobs(in: firstWorkspace).map(\.id) == [
                "job-first-worktree-hidden-finished",
                "job-first-worktree-queued-b",
                "job-first-worktree-running-a",
            ])
    }

    @Test func workspaceSectionSelectionExpandsWhenLinkedWorktreeArrives() async throws {
        let fixture = try makeLinkedWorktreeFixtureForTesting(repositoryName: "CodexReviewKit")
        defer {
            try? FileManager.default.removeItem(at: fixture.rootURL)
        }
        let firstWorkspace = CodexReviewWorkspace(cwd: fixture.firstWorktreeURL.path)
        let secondWorkspace = CodexReviewWorkspace(cwd: fixture.secondWorktreeURL.path)
        let firstJob = makeJob(
            id: "job-existing-worktree",
            cwd: firstWorkspace.cwd,
            status: .succeeded,
            targetSummary: "Existing worktree"
        )
        let secondJob = makeJob(
            id: "job-arriving-worktree",
            cwd: secondWorkspace.cwd,
            status: .succeeded,
            targetSummary: "Arriving worktree"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [firstWorkspace],
            jobs: [firstJob]
        )
        let backend = makeWindowHarness(store: store)
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.selectWorkspaceForTesting(firstWorkspace)
        #expect(sidebar.selectedWorkspaceSectionForTesting?.workspaceCWDs == [firstWorkspace.cwd])

        store.loadForTesting(
            serverState: .running,
            workspaces: [firstWorkspace, secondWorkspace],
            jobs: [firstJob, secondJob]
        )
        try await waitForObservedValue(
            from: sidebar.sidebarTopologyObservationForTesting,
            ["CodexReviewKit"]
        ) {
            sidebar.displayedSectionTitlesForTesting
        }
        try await waitForCondition {
            sidebar.selectedWorkspaceSectionForTesting?.workspaceCWDs == [firstWorkspace.cwd, secondWorkspace.cwd]
        }

        #expect(window.title == "CodexReviewKit")
        #expect(window.subtitle == "2 workspaces")
    }

    @Test func workspaceSectionSelectionShrinksWhenLinkedWorktreeLeaves() async throws {
        let fixture = try makeLinkedWorktreeFixtureForTesting(repositoryName: "CodexReviewKit")
        defer {
            try? FileManager.default.removeItem(at: fixture.rootURL)
        }
        let firstWorkspace = CodexReviewWorkspace(cwd: fixture.firstWorktreeURL.path)
        let secondWorkspace = CodexReviewWorkspace(cwd: fixture.secondWorktreeURL.path)
        let firstJob = makeJob(
            id: "job-remaining-worktree",
            cwd: firstWorkspace.cwd,
            status: .succeeded,
            targetSummary: "Remaining worktree"
        )
        let secondJob = makeJob(
            id: "job-removed-worktree",
            cwd: secondWorkspace.cwd,
            status: .succeeded,
            targetSummary: "Removed worktree"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [firstWorkspace, secondWorkspace],
            jobs: [firstJob, secondJob]
        )
        let backend = makeWindowHarness(store: store)
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.clickWorkspaceHeaderForTesting(firstWorkspace)
        #expect(sidebar.selectedWorkspaceSectionForTesting?.title == "CodexReviewKit")

        store.loadForTesting(
            serverState: .running,
            workspaces: [firstWorkspace],
            jobs: [firstJob]
        )
        try await waitForCondition {
            sidebar.selectedWorkspaceSectionForTesting?.workspaceCWDs == [firstWorkspace.cwd]
        }

        #expect(sidebar.displayedSectionTitlesForTesting == ["CodexReviewKit"])
        #expect(window.title == "CodexReviewKit")
        #expect(window.subtitle == firstWorkspace.cwd)
    }

    @Test func workspaceSectionDropAcrossSectionRootUsesVisibleRootIndexes() async throws {
        let fixture = try makeLinkedWorktreeFixtureForTesting(repositoryName: "CodexReviewKit")
        defer {
            try? FileManager.default.removeItem(at: fixture.rootURL)
        }
        let standaloneURL = fixture.rootURL.appendingPathComponent("Standalone", isDirectory: true)
        try FileManager.default.createDirectory(at: standaloneURL, withIntermediateDirectories: true)
        let firstWorkspace = CodexReviewWorkspace(cwd: fixture.firstWorktreeURL.path)
        let secondWorkspace = CodexReviewWorkspace(cwd: fixture.secondWorktreeURL.path)
        let standaloneWorkspace = CodexReviewWorkspace(cwd: standaloneURL.path)
        let firstJob = makeJob(
            id: "job-grouped-first-workspace",
            cwd: firstWorkspace.cwd,
            status: .succeeded,
            targetSummary: "First workspace"
        )
        let secondJob = makeJob(
            id: "job-grouped-second-workspace",
            cwd: secondWorkspace.cwd,
            status: .running,
            targetSummary: "Second workspace"
        )
        let standaloneJob = makeJob(
            id: "job-standalone-workspace",
            cwd: standaloneWorkspace.cwd,
            status: .queued,
            targetSummary: "Standalone workspace"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [firstWorkspace, secondWorkspace, standaloneWorkspace],
            jobs: [firstJob, secondJob, standaloneJob]
        )
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.displayedSectionTitlesForTesting == ["CodexReviewKit", "Standalone"])

        let incrementalMoveCountBeforeDrop = sidebar.sidebarIncrementalMoveCountForTesting
        #expect(sidebar.performWorkspaceDropForTesting(standaloneWorkspace, toIndex: 0))
        await Task.yield()

        #expect(sidebar.displayedSectionTitlesForTesting == ["Standalone", "CodexReviewKit"])
        #expect(sidebar.sidebarIncrementalMoveCountForTesting == incrementalMoveCountBeforeDrop + 1)
    }

    @Test func workspaceSectionDropReordersSectionRootAsBlock() async throws {
        let fixture = try makeLinkedWorktreeFixtureForTesting(repositoryName: "CodexReviewKit")
        defer {
            try? FileManager.default.removeItem(at: fixture.rootURL)
        }
        let standaloneURL = fixture.rootURL.appendingPathComponent("Standalone", isDirectory: true)
        try FileManager.default.createDirectory(at: standaloneURL, withIntermediateDirectories: true)
        let firstWorkspace = CodexReviewWorkspace(cwd: fixture.firstWorktreeURL.path)
        let secondWorkspace = CodexReviewWorkspace(cwd: fixture.secondWorktreeURL.path)
        let standaloneWorkspace = CodexReviewWorkspace(cwd: standaloneURL.path)
        let firstJob = makeJob(
            id: "job-draggable-group-first-workspace",
            cwd: firstWorkspace.cwd,
            status: .succeeded,
            targetSummary: "First workspace"
        )
        let secondJob = makeJob(
            id: "job-draggable-group-second-workspace",
            cwd: secondWorkspace.cwd,
            status: .running,
            targetSummary: "Second workspace"
        )
        let standaloneJob = makeJob(
            id: "job-draggable-group-standalone",
            cwd: standaloneWorkspace.cwd,
            status: .queued,
            targetSummary: "Standalone workspace"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [firstWorkspace, secondWorkspace, standaloneWorkspace],
            jobs: [firstJob, secondJob, standaloneJob]
        )
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.displayedSectionTitlesForTesting == ["CodexReviewKit", "Standalone"])
        #expect(sidebar.workspaceSectionCanStartDragForTesting(containing: firstWorkspace))

        let incrementalMoveCountBeforeDrop = sidebar.sidebarIncrementalMoveCountForTesting
        #expect(
            sidebar.performWorkspaceSectionDropForTesting(
                containing: firstWorkspace,
                toIndex: 2
            ))
        await Task.yield()

        #expect(sidebar.displayedSectionTitlesForTesting == ["Standalone", "CodexReviewKit"])
        #expect(
            store.orderedWorkspaces.map(\.cwd) == [
                standaloneWorkspace.cwd,
                firstWorkspace.cwd,
                secondWorkspace.cwd,
            ])
        #expect(sidebar.sidebarIncrementalMoveCountForTesting == incrementalMoveCountBeforeDrop + 1)
    }

    @Test func workspaceSectionDropBlockifiesNonContiguousGroupedWorkspaces() async throws {
        let fixture = try makeLinkedWorktreeFixtureForTesting(repositoryName: "CodexReviewKit")
        defer {
            try? FileManager.default.removeItem(at: fixture.rootURL)
        }
        let standaloneBURL = fixture.rootURL.appendingPathComponent("StandaloneB", isDirectory: true)
        let standaloneCURL = fixture.rootURL.appendingPathComponent("StandaloneC", isDirectory: true)
        try FileManager.default.createDirectory(at: standaloneBURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: standaloneCURL, withIntermediateDirectories: true)
        let firstWorkspace = CodexReviewWorkspace(cwd: fixture.firstWorktreeURL.path)
        let secondWorkspace = CodexReviewWorkspace(cwd: fixture.secondWorktreeURL.path)
        let standaloneBWorkspace = CodexReviewWorkspace(cwd: standaloneBURL.path)
        let standaloneCWorkspace = CodexReviewWorkspace(cwd: standaloneCURL.path)
        let firstJob = makeJob(
            id: "job-noncontiguous-group-first",
            cwd: firstWorkspace.cwd,
            status: .succeeded,
            targetSummary: "First grouped workspace"
        )
        let standaloneBJob = makeJob(
            id: "job-noncontiguous-standalone-b",
            cwd: standaloneBWorkspace.cwd,
            status: .running,
            targetSummary: "Standalone B"
        )
        let standaloneCJob = makeJob(
            id: "job-noncontiguous-standalone-c",
            cwd: standaloneCWorkspace.cwd,
            status: .queued,
            targetSummary: "Standalone C"
        )
        let secondJob = makeJob(
            id: "job-noncontiguous-group-second",
            cwd: secondWorkspace.cwd,
            status: .failed,
            targetSummary: "Second grouped workspace"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [firstWorkspace, standaloneBWorkspace, standaloneCWorkspace, secondWorkspace],
            jobs: [firstJob, standaloneBJob, standaloneCJob, secondJob]
        )
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.displayedSectionTitlesForTesting == ["CodexReviewKit", "StandaloneB", "StandaloneC"])

        #expect(
            sidebar.performWorkspaceSectionDropForTesting(
                containing: firstWorkspace,
                toIndex: 2
            ))
        await Task.yield()

        #expect(sidebar.displayedSectionTitlesForTesting == ["StandaloneB", "CodexReviewKit", "StandaloneC"])
        #expect(
            store.orderedWorkspaces.map(\.cwd) == [
                standaloneBWorkspace.cwd,
                firstWorkspace.cwd,
                secondWorkspace.cwd,
                standaloneCWorkspace.cwd,
            ])
    }

    @Test func workspaceSectionReviewChatDropUsesRootChildIndexesForLaterWorkspaceReviewChats() async throws {
        let fixture = try makeLinkedWorktreeFixtureForTesting(repositoryName: "CodexReviewKit")
        defer {
            try? FileManager.default.removeItem(at: fixture.rootURL)
        }
        let firstWorkspace = CodexReviewWorkspace(cwd: fixture.firstWorktreeURL.path)
        let secondWorkspace = CodexReviewWorkspace(cwd: fixture.secondWorktreeURL.path)
        let firstWorkspaceJob = makeJob(
            id: "job-first-workspace",
            cwd: firstWorkspace.cwd,
            status: .succeeded,
            targetSummary: "First workspace"
        )
        let secondWorkspaceFirstJob = makeJob(
            id: "job-second-workspace-first",
            cwd: secondWorkspace.cwd,
            status: .running,
            targetSummary: "Second workspace first"
        )
        let secondWorkspaceSecondJob = makeJob(
            id: "job-second-workspace-second",
            cwd: secondWorkspace.cwd,
            status: .queued,
            targetSummary: "Second workspace second"
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [firstWorkspace, secondWorkspace],
            jobs: [firstWorkspaceJob, secondWorkspaceFirstJob, secondWorkspaceSecondJob]
        )
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.displayedSectionTitlesForTesting == ["CodexReviewKit"])
        #expect(
            sidebar.displayedReviewChatJobIDsForTesting(in: secondWorkspace) == [
                "job-second-workspace-first",
                "job-second-workspace-second",
            ])

        #expect(
            sidebar.performReviewChatDropForTesting(
                secondWorkspaceFirstJob,
                proposedWorkspaceSectionContaining: secondWorkspace,
                childIndex: 0
            ) == false)

        #expect(
            sidebar.performReviewChatDropForTesting(
                secondWorkspaceFirstJob,
                proposedJob: firstWorkspaceJob,
                hoveringBelowMidpoint: true
            ) == false)

        #expect(
            sidebar.performReviewChatDropForTesting(
                secondWorkspaceFirstJob,
                proposedJob: secondWorkspaceSecondJob,
                hoveringBelowMidpoint: true
            ))
        await Task.yield()

        #expect(sidebar.displayedReviewChatJobIDsForTesting(in: firstWorkspace) == ["job-first-workspace"])
        #expect(
            sidebar.displayedReviewChatJobIDsForTesting(in: secondWorkspace) == [
                "job-second-workspace-second",
                "job-second-workspace-first",
            ])
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
        #expect(
            abs(
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
            transport.workspaceFindingSnapshotForTesting
                == .init(
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
        try await waitForCondition {
            window.title == workspace.displayTitle && window.subtitle == workspace.cwd
        }
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
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

        #expect(sidebar.selectedWorkspaceSectionForTesting?.workspaceCWDs == [replacement.cwd])
        #expect(store.orderedJobs(in: replacement).first?.id == "job-workspace-selection-replacement")

        store.loadForTesting(serverState: .running, workspaces: [])
        try await waitForCondition {
            sidebar.selectedWorkspaceSectionForTesting == nil && sidebar.selectedReviewChatIDForTesting == nil
                && transport.isShowingEmptyStateForTesting
        }

        #expect(sidebar.selectedWorkspaceSectionForTesting == nil)
        #expect(sidebar.selectedReviewChatIDForTesting == nil)
        #expect(transport.isShowingEmptyStateForTesting)
    }

    @Test func detailPaneRendersSelectedReviewChatLogProjection() async throws {
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
            timelineEntries: [
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
            content: makeSidebarContent(from: [job])
        )
        let backend = makeWindowHarness(store: store)
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))

        let selectedSnapshot = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(selectedSnapshot.title == nil)
        #expect(selectedSnapshot.summary == nil)
        #expect(window.title == job.targetSummary)
        #expect(window.subtitle == job.cwd)

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

    @Test func detailPaneRendersDirectTimelineUpdatesWithoutLogEntryChanges() async throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-direct-timeline-detail",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            timelineEntries: []
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
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        job.timeline.apply(
            .itemCompleted(
                .init(
                    id: "message-direct",
                    kind: .agentMessage,
                    family: .message,
                    phase: .completed,
                    content: .message(.init(text: "Timeline-only detail update"))
                )))

        var snapshot = try await awaitTimelineRenderForTesting(job, in: transport)
        #expect(snapshot.log == "Timeline-only detail update")

        let startedAt = Date(timeIntervalSince1970: 250)
        job.timeline.apply(
            .itemCompleted(
                .init(
                    id: "cmd-direct",
                    kind: .commandExecution,
                    family: .command,
                    phase: .completed,
                    content: .command(
                        .init(
                            command: "swift test",
                            output: "Tests passed",
                            exitCode: 0,
                            status: .completed,
                            durationMs: 2_000
                        )),
                    startedAt: startedAt,
                    completedAt: startedAt.addingTimeInterval(2),
                    durationMs: 2_000
                )))

        snapshot = try await awaitTimelineRenderForTesting(job, in: transport) {
            $0.log.contains("Ran swift test for 2s")
        }
        #expect(snapshot.log.contains("Timeline-only detail update"))
        #expect(snapshot.log.contains("Ran swift test for 2s"))
        #expect(snapshot.log.contains("$ swift test") == false)
        #expect(snapshot.log.contains("Tests passed") == false)
        #expect(transport.logCommandOutputPanelCountForTesting == 1)

        let panelBlockID = ReviewMonitorLog.BlockID("commandOutput:cmd-direct")
        #expect(transport.clickLogCommandOutputPanelHeaderForTesting(blockID: panelBlockID))
        await awaitNativeLayoutTurn()
        #expect(
            transport.logCommandOutputPanelTerminalTextForTesting(blockID: panelBlockID)?.contains("$ swift test")
                == true)
        #expect(
            transport.logCommandOutputPanelTerminalTextForTesting(blockID: panelBlockID)?.contains("Tests passed")
                == true)
    }

    @Test func directTimelineFailedCommandPreservesFailedPanelStatus() async throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-direct-timeline-failed-command",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            timelineEntries: []
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
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        let startedAt = Date(timeIntervalSince1970: 300)
        job.timeline.apply(
            .itemCompleted(
                .init(
                    id: "cmd-failed-direct",
                    kind: .commandExecution,
                    family: .command,
                    phase: .failed,
                    content: .command(
                        .init(
                            command: "swift test",
                            output: "Tests failed"
                        )),
                    startedAt: startedAt,
                    completedAt: startedAt.addingTimeInterval(4),
                    durationMs: 4_000
                )))

        let snapshot = try await awaitTimelineRenderForTesting(job, in: transport) {
            $0.log.contains("Ran swift test for 4s")
        }
        #expect(snapshot.log.contains("Tests failed") == false)
        #expect(transport.logCommandOutputPanelCountForTesting == 1)

        let panelBlockID = ReviewMonitorLog.BlockID("commandOutput:cmd-failed-direct")
        #expect(transport.clickLogCommandOutputPanelHeaderForTesting(blockID: panelBlockID))
        await awaitNativeLayoutTurn()
        #expect(transport.logCommandOutputPanelResultTextForTesting == "Failed")
        #expect(
            transport.logCommandOutputPanelTerminalTextForTesting(blockID: panelBlockID)?.contains("Tests failed")
                == true)
    }

    @Test func directTimelineRunningCommandOutputStaysActive() async throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-direct-timeline-running-command",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            timelineEntries: []
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
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        job.timeline.apply(
            .itemStarted(
                .init(
                    id: "cmd-running-direct",
                    kind: .commandExecution,
                    family: .command,
                    phase: .running,
                    content: .command(
                        .init(
                            command: "swift test",
                            output: "Building..."
                        )),
                    startedAt: Date(timeIntervalSince1970: 300)
                )))

        let snapshot = try await awaitTimelineRenderForTesting(job, in: transport) {
            $0.log.contains("Running swift test")
        }
        #expect(snapshot.log.contains("Running swift test"))
        #expect(snapshot.log.contains("Ran swift test") == false)
        #expect(snapshot.log.contains("Building...") == false)
        #expect(transport.logCommandOutputPanelCountForTesting == 1)

        let panelBlockID = ReviewMonitorLog.BlockID("commandOutput:cmd-running-direct")
        #expect(transport.clickLogCommandOutputPanelHeaderForTesting(blockID: panelBlockID))
        await awaitNativeLayoutTurn()
        #expect(transport.logCommandOutputPanelResultTextForTesting == "running")
        #expect(
            transport.logCommandOutputPanelTerminalTextForTesting(blockID: panelBlockID)?.contains("Building...")
                == true)
    }

    @Test func directTimelineTerminalPhaseOverridesStaleCommandStatus() async throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-direct-timeline-stale-command-status",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            timelineEntries: []
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
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        job.timeline.apply(
            .itemCompleted(
                .init(
                    id: "cmd-stale-status-direct",
                    kind: .commandExecution,
                    family: .command,
                    phase: .completed,
                    content: .command(
                        .init(
                            command: "swift test",
                            output: "Tests passed",
                            status: .inProgress
                        ))
                )))

        let snapshot = try await awaitTimelineRenderForTesting(job, in: transport) {
            $0.log.contains("Ran swift test")
        }
        #expect(snapshot.log.contains("Running swift test") == false)
        #expect(transport.logCommandOutputPanelCountForTesting == 1)

        let panelBlockID = ReviewMonitorLog.BlockID("commandOutput:cmd-stale-status-direct")
        #expect(transport.clickLogCommandOutputPanelHeaderForTesting(blockID: panelBlockID))
        await awaitNativeLayoutTurn()
        #expect(transport.logCommandOutputPanelResultTextForTesting == "Success")
        #expect(
            transport.logCommandOutputPanelTerminalTextForTesting(blockID: panelBlockID)?.contains("Tests passed")
                == true)
    }

    @Test func timelineProjectionDoesNotAppendWhenExistingBlockPresentationChanges() {
        let timestamp = Date(timeIntervalSince1970: 300)
        var projection = ReviewMonitorTimelineLogProjection()

        func document(
            revision: UInt64,
            blocks: [ReviewTimelineDocument.Block]
        ) -> ReviewTimelineDocument {
            ReviewTimelineDocument(
                timelineRevision: .init(rawValue: revision),
                orderedBlockIDs: blocks.map(\.id),
                activeBlockIDs: blocks.filter(\.isActive).map(\.id),
                activeBlockCount: blocks.filter(\.isActive).count,
                latestActivityBlockID: blocks.last?.id,
                terminalStatus: nil,
                terminalSummary: nil,
                terminalResult: nil,
                blocks: blocks
            )
        }

        func toolBlock(
            phase: ReviewItemPhase,
            isActive: Bool,
            status: ReviewToolCallStatus
        ) -> ReviewTimelineDocument.Block {
            ReviewTimelineDocument.Block(
                id: "tool-block",
                sourceItemID: "tool-item",
                kind: .mcpToolCall,
                family: .tool,
                phase: phase,
                isActive: isActive,
                primaryText: "Tool output",
                rawTranscriptText: "Tool output",
                content: .toolCall(
                    .init(
                        namespace: "codex_review",
                        server: "codex_review",
                        name: "review_start",
                        result: "Tool output",
                        status: status
                    )),
                createdAt: timestamp,
                updatedAt: timestamp
            )
        }

        let initialDocument = document(
            revision: 1,
            blocks: [
                toolBlock(phase: .running, isActive: true, status: .inProgress)
            ]
        )
        _ = projection.render(timelineDocument: initialDocument)

        let updatedDocument = document(
            revision: 2,
            blocks: [
                toolBlock(phase: .completed, isActive: false, status: .completed),
                ReviewTimelineDocument.Block(
                    id: "message-block",
                    sourceItemID: "message-item",
                    kind: .agentMessage,
                    family: .message,
                    phase: .completed,
                    isActive: false,
                    primaryText: "Review complete.",
                    rawTranscriptText: "Review complete.",
                    content: .message(.init(text: "Review complete.")),
                    createdAt: timestamp,
                    updatedAt: timestamp
                ),
            ]
        )
        let updatedLog = projection.render(timelineDocument: updatedDocument)

        #expect(updatedLog.text == "Tool output\n\nReview complete.")
        if case .append = updatedLog.lastChange {
            Issue.record("Timeline projection must not append when existing block presentation changed.")
        }
    }

    @Test func timelineProjectionRendersToolCallProgressUpdates() {
        let timestamp = Date(timeIntervalSince1970: 300)
        var projection = ReviewMonitorTimelineLogProjection()

        func document(revision: UInt64, progress: String) -> ReviewTimelineDocument {
            ReviewTimelineDocument(
                timelineRevision: .init(rawValue: revision),
                orderedBlockIDs: ["tool-progress"],
                activeBlockIDs: ["tool-progress"],
                activeBlockCount: 1,
                latestActivityBlockID: "tool-progress",
                terminalStatus: nil,
                terminalSummary: nil,
                terminalResult: nil,
                blocks: [
                    .init(
                        id: "tool-progress",
                        sourceItemID: "tool-progress",
                        kind: .mcpToolCall,
                        family: .tool,
                        phase: .running,
                        isActive: true,
                        primaryText: "codex_review.review_start",
                        rawTranscriptText: progress,
                        content: .toolCall(
                            .init(
                                namespace: "codex_review",
                                server: "codex_review",
                                name: "review_start",
                                status: .inProgress,
                                progress: progress
                            )),
                        createdAt: timestamp,
                        updatedAt: timestamp
                    )
                ]
            )
        }

        let initialLog = projection.render(
            timelineDocument: document(
                revision: 1,
                progress: "MCP codex_review.review_start started."
            ))
        let updatedLog = projection.render(
            timelineDocument: document(
                revision: 2,
                progress: "MCP codex_review.review_start still running."
            ))

        #expect(initialLog.text == "MCP codex_review.review_start started.")
        #expect(updatedLog.text == "MCP codex_review.review_start still running.")
    }

    @Test func timelineProjectionPreservesOutputOnlyCommandMetadata() throws {
        let startedAt = Date(timeIntervalSince1970: 300)
        let completedAt = startedAt.addingTimeInterval(4)
        var projection = ReviewMonitorTimelineLogProjection()
        let document = ReviewTimelineDocument(
            timelineRevision: .init(rawValue: 1),
            orderedBlockIDs: ["cmd-output-only"],
            activeBlockIDs: [],
            activeBlockCount: 0,
            latestActivityBlockID: "cmd-output-only",
            terminalStatus: nil,
            terminalSummary: nil,
            terminalResult: nil,
            blocks: [
                .init(
                    id: "cmd-output-only",
                    sourceItemID: "cmd-output-only",
                    kind: .commandExecution,
                    family: .command,
                    phase: .failed,
                    isActive: false,
                    primaryText: "Command output",
                    rawTranscriptText: "stderr",
                    content: .command(
                        .init(
                            title: "",
                            command: "",
                            output: "stderr",
                            exitCode: 2,
                            status: .failed,
                            durationMs: 4_000
                        )),
                    createdAt: startedAt,
                    updatedAt: completedAt,
                    startedAt: startedAt,
                    completedAt: completedAt,
                    durationMs: 4_000
                )
            ]
        )

        let sourceLog = projection.render(timelineDocument: document)
        let renderedLog = ReviewMonitorCommandOutputDisplayDocument.make(from: sourceLog)
        let panel = try #require(renderedLog.commandOutputPanels.first)
        let metadata = try #require(sourceLog.blocks.first?.metadata)

        #expect(sourceLog.blocks.map(\.kind) == [.commandOutput])
        #expect(sourceLog.text == "stderr")
        #expect(panel.isActive == false)
        #expect(panel.title == "Ran command for 4s")
        #expect(panel.exitText == "exit 2")
        #expect(metadata.itemID == "cmd-output-only")
        #expect(metadata.command == nil)
        #expect(metadata.exitCode == 2)
        #expect(metadata.durationMs == 4_000)
    }

    @Test func timelineProjectionTreatsExitCodeAsTerminalBeforeActiveFallback() throws {
        var projection = ReviewMonitorTimelineLogProjection()
        let document = ReviewTimelineDocument(
            timelineRevision: .init(rawValue: 1),
            orderedBlockIDs: ["cmd-active-exited"],
            activeBlockIDs: ["cmd-active-exited"],
            activeBlockCount: 1,
            latestActivityBlockID: "cmd-active-exited",
            terminalStatus: nil,
            terminalSummary: nil,
            terminalResult: nil,
            blocks: [
                .init(
                    id: "cmd-active-exited",
                    sourceItemID: "cmd-active-exited",
                    kind: .commandExecution,
                    family: .command,
                    phase: .running,
                    isActive: true,
                    primaryText: "Running swift test",
                    rawTranscriptText: "$ swift test\nTests failed",
                    content: .command(
                        .init(
                            title: "Command",
                            command: "swift test",
                            output: "Tests failed",
                            exitCode: 1
                        )),
                    createdAt: Date(timeIntervalSince1970: 400),
                    updatedAt: Date(timeIntervalSince1970: 400)
                )
            ]
        )

        let sourceLog = projection.render(timelineDocument: document)
        let renderedLog = ReviewMonitorCommandOutputDisplayDocument.make(from: sourceLog)
        let panel = try #require(renderedLog.commandOutputPanels.first)
        let metadata = try #require(sourceLog.blocks.first?.metadata)

        #expect(panel.isActive == false)
        #expect(panel.title == "Ran swift test")
        #expect(panel.exitText == "exit 1")
        #expect(metadata.status == "failed")
        #expect(metadata.commandStatus == "failed")
    }

    @Test func timelineProjectionMarksInactiveRunningCommandCompleted() throws {
        var projection = ReviewMonitorTimelineLogProjection()
        let document = ReviewTimelineDocument(
            timelineRevision: .init(rawValue: 1),
            orderedBlockIDs: ["cmd-inactive-running"],
            activeBlockIDs: [],
            activeBlockCount: 0,
            latestActivityBlockID: "cmd-inactive-running",
            terminalStatus: nil,
            terminalSummary: nil,
            terminalResult: nil,
            blocks: [
                .init(
                    id: "cmd-inactive-running",
                    sourceItemID: "cmd-inactive-running",
                    kind: .commandExecution,
                    family: .command,
                    phase: .running,
                    isActive: false,
                    primaryText: "Running swift test",
                    rawTranscriptText: "$ swift test",
                    content: .command(
                        .init(
                            title: "Command",
                            command: "swift test",
                            status: .inProgress
                        )),
                    createdAt: Date(timeIntervalSince1970: 400),
                    updatedAt: Date(timeIntervalSince1970: 400)
                )
            ]
        )

        let sourceLog = projection.render(timelineDocument: document)
        let renderedLog = ReviewMonitorCommandOutputDisplayDocument.make(from: sourceLog)
        let panel = try #require(renderedLog.commandOutputPanels.first)
        let metadata = try #require(sourceLog.blocks.first?.metadata)

        #expect(panel.isActive == false)
        #expect(panel.title == "Ran swift test")
        #expect(metadata.status == "completed")
        #expect(metadata.commandStatus == "completed")
    }

    @Test func directTimelineFileChangePreservesPanelTitle() async throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-direct-timeline-file-change",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            timelineEntries: []
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
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        job.timeline.apply(
            .itemCompleted(
                .init(
                    id: "file-change-direct",
                    kind: .fileChange,
                    family: .fileChange,
                    phase: .completed,
                    content: .fileChange(
                        .init(
                            title: "Updated Sources/App.swift",
                            output: "Sources/App.swift | 12 ++++++------",
                            paths: ["Sources/App.swift"],
                            status: .started
                        ))
                )))

        let snapshot = try await awaitTimelineRenderForTesting(job, in: transport) {
            $0.log.contains("Updated Sources/App.swift")
        }
        #expect(snapshot.log.contains("Updated Sources/App.swift"))
        #expect(snapshot.log.contains("Ran command") == false)
        #expect(snapshot.log.contains("Sources/App.swift | 12") == false)
        #expect(transport.logCommandOutputPanelCountForTesting == 1)

        let panelBlockID = ReviewMonitorLog.BlockID("commandOutput:file-change-direct")
        #expect(transport.clickLogCommandOutputPanelHeaderForTesting(blockID: panelBlockID))
        await awaitNativeLayoutTurn()
        #expect(transport.logCommandOutputPanelResultTextForTesting == "Success")
        #expect(
            transport.logCommandOutputPanelTerminalTextForTesting(blockID: panelBlockID)?
                .contains("Sources/App.swift | 12 ++++++------") == true
        )
    }

    @Test func contextCompactionMarkerRendersAsVisibleLogTextWithoutCommandPanel() async throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-context-compaction-marker",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            timelineEntries: [
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
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))

        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(transport.displayedLogForTesting == "Automatically compacting context")
        #expect(transport.logFindStringForTesting.contains("Automatically compacting context"))
        #expect(transport.logCommandOutputPanelCountForTesting == 0)

        appendTimelineEntryForTesting(
            job,
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
            ))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)

        #expect(transport.displayedLogForTesting == "Context automatically compacted")
        #expect(transport.displayedLogForTesting.contains("Automatically compacting context") == false)
        #expect(transport.logFindStringForTesting.contains("Context automatically compacted"))
        #expect(transport.logCommandOutputPanelCountForTesting == 0)
    }

    @Test func commandOutputRendersCollapsedTextKitPanelAndExpandsInline() async throws {
        let outputText = (1...9)
            .map { "output line \($0)" }
            .joined(separator: "\n")
        let commandMetadata = ReviewTimelineEntryForTesting.Metadata(
            sourceType: "command",
            title: "Ran command for 17s",
            status: "succeeded",
            command: "swift test",
            exitCode: 0,
            commandStatus: "completed"
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
            timelineEntries: [
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
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))

        _ = try await awaitTimelineRenderForTesting(
            job,
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
        appendTimelineEntryForTesting(
            job,
            .init(
                kind: .commandOutput,
                groupID: "cmd_1",
                text: "\noutput line 10",
                metadata: commandMetadata
            ))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)
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

        appendTimelineEntryForTesting(
            job,
            .init(
                kind: .commandOutput,
                groupID: "cmd_1",
                text: "\noutput line 11",
                metadata: commandMetadata
            ))
        appendTimelineEntryForTesting(job, .init(kind: .agentMessage, text: "Visible text after command output."))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)
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
        let job = CodexReviewJob.makeForTesting(
            id: "job-command-output-panel-isolation",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            timelineEntries: [
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
            content: makeSidebarContent(from: [job])
        )
        let backend = makeWindowHarness(
            store: store,
            contentSize: NSSize(width: 860, height: 900)
        )
        let viewController = backend.viewController
        let window = backend.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))

        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        let firstBlockID = ReviewMonitorLog.BlockID("commandOutput:cmd_1")
        let secondBlockID = ReviewMonitorLog.BlockID("commandOutput:cmd_2")
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
        let job = CodexReviewJob.makeForTesting(
            id: "job-command-start-panel",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            timelineEntries: [
                .init(kind: .command, groupID: "cmd_1", text: "$ swift test")
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
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))

        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(transport.logCommandOutputPanelCountForTesting == 1)
        #expect(transport.displayedLogForTesting.contains("Running swift test"))
        #expect(transport.displayedLogForTesting.contains("$ swift test") == false)

        appendTimelineEntryForTesting(
            job,
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
            ))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)
        #expect(transport.logCommandOutputPanelCountForTesting == 1)
        #expect(transport.displayedLogForTesting.contains("Ran swift test"))
        #expect(transport.displayedLogForTesting.contains("$ swift test") == false)
        #expect(transport.displayedLogForTesting.contains("output line 1") == false)
    }

    @Test func expandingCommandOutputKeepsPanelTextOutOfActiveFindSnapshot() async throws {
        let outputText = (1...5)
            .map { "output line \($0)" }
            .joined(separator: "\n")
        let job = CodexReviewJob.makeForTesting(
            id: "job-command-output-find-refresh",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            timelineEntries: [
                .init(kind: .command, groupID: "cmd_1", text: "$ swift test"),
                .init(kind: .commandOutput, groupID: "cmd_1", text: outputText),
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
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        try await withFindPasteboardString(nil) {
            viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
            #expect(transport.logFindBarVisibleForTesting)
            #expect(transport.setLogVisibleFindBarSearchStringForTesting("Ran swift test"))
            #expect(transport.logFindClientUsesSnapshotForTesting)
            #expect(transport.logFindClientSnapshotMapsToDocumentForTesting)
            #expect(transport.logFindStringForTesting.contains("Ran swift test"))
            #expect(transport.logFindStringForTesting.contains("$ swift test") == false)
            #expect(transport.logFindStringForTesting.contains("output line 3") == false)

            #expect(transport.clickFirstLogCommandOutputPanelHeaderForTesting())
            await awaitNativeLayoutTurn()

            #expect(transport.logFindClientUsesSnapshotForTesting)
            #expect(transport.logFindClientSnapshotMapsToDocumentForTesting)
            #expect(transport.logFindStringForTesting.contains("Ran swift test"))
            #expect(transport.logFindStringForTesting.contains("$ swift test") == false)
            #expect(transport.logFindStringForTesting.contains("output line 3") == false)

            appendTimelineEntryForTesting(
                job, .init(kind: .commandOutput, groupID: "cmd_1", text: "\noutput line 6"))
            _ = try await awaitTimelineRenderForTesting(job, in: transport)
            await awaitNativeLayoutTurn()

            #expect(transport.logFindClientUsesSnapshotForTesting)
            #expect(transport.logFindClientSnapshotMapsToDocumentForTesting)
            #expect(transport.logFindStringForTesting.contains("Ran swift test"))
            #expect(transport.logFindStringForTesting.contains("output line 6") == false)
        }
    }

    @Test func switchingSelectedReviewChatRebindsDetailPane() async throws {
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
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(activeJob))

        let activeSnapshot = try await awaitTimelineRenderForTesting(
            activeJob,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(activeSnapshot.title == nil)
        #expect(activeSnapshot.summary == nil)
        #expect(window.title == activeJob.targetSummary)
        #expect(window.subtitle == activeJob.cwd)
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(recentJob))

        let recentSnapshot = try await awaitTimelineRenderForTesting(
            recentJob,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(
            recentSnapshot
                == .init(
                    title: nil,
                    summary: nil,
                    log: reviewMonitorLogText(for: recentJob),
                    isShowingEmptyState: false
                )
        )
        #expect(window.title == recentJob.targetSummary)
        #expect(window.subtitle == recentJob.cwd)
    }

    @Test func firstSelectionFromEmptyStatePinsUnvisitedReviewChatToBottom() async throws {
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        transport.view.layoutSubtreeIfNeeded()

        #expect(transport.isLogPinnedToBottomForTesting)
    }

    @Test func switchingSelectedReviewChatStartsUnvisitedReviewChatAtBottomAndRestoresPreviousOffset() async throws {
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(activeJob))
        _ = try await awaitTimelineRenderForTesting(
            activeJob,
            in: transport,
            allowIncrementalUpdate: false
        )

        transport.scrollLogToOffsetForTesting(120)
        let activeOffset = transport.logVerticalScrollOffsetForTesting
        #expect(activeOffset > 0)
        #expect(transport.isLogPinnedToBottomForTesting == false)
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(recentJob))
        _ = try await awaitTimelineRenderForTesting(
            recentJob,
            in: transport,
            allowIncrementalUpdate: false
        )

        #expect(transport.isLogPinnedToBottomForTesting)
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(activeJob))
        _ = try await awaitTimelineRenderForTesting(
            activeJob,
            in: transport,
            allowIncrementalUpdate: false
        )

        #expect(transport.logVerticalScrollOffsetForTesting == activeOffset)
        #expect(transport.isLogPinnedToBottomForTesting == false)
    }

    @Test func switchingSelectedReviewChatRestoresPinnedBottomPosition() async throws {
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(activeJob))
        _ = try await awaitTimelineRenderForTesting(
            activeJob,
            in: transport,
            allowIncrementalUpdate: false
        )

        transport.scrollLogToBottomForTesting()
        #expect(transport.isLogPinnedToBottomForTesting)
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(recentJob))
        _ = try await awaitTimelineRenderForTesting(
            recentJob,
            in: transport,
            allowIncrementalUpdate: false
        )

        #expect(transport.isLogPinnedToBottomForTesting)

        appendTimelineEntryForTesting(activeJob, .init(kind: .progress, text: "Newest active line"))
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(activeJob))
        let snapshot = try await awaitTimelineRenderForTesting(
            activeJob,
            in: transport,
            allowIncrementalUpdate: false
        )

        #expect(snapshot.log.contains("Newest active line"))
        #expect(transport.isLogPinnedToBottomForTesting)
    }

    @Test func rehydratingSameSelectedReviewChatPreservesLogScrollPosition() async throws {
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

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

        #expect(transport.displayedLogForTesting == reviewMonitorLogText(for: replacement))
        #expect(transport.logVerticalScrollOffsetForTesting == preservedOffset)
    }

    @Test func switchingReviewChatWithIdenticalLogTextStartsUnvisitedReviewChatAtBottom() async throws {
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(firstJob))
        _ = try await awaitTimelineRenderForTesting(
            firstJob,
            in: transport,
            allowIncrementalUpdate: false
        )

        transport.scrollLogToOffsetForTesting(120)
        #expect(transport.logVerticalScrollOffsetForTesting > 0)
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(secondJob))
        _ = try await awaitTimelineRenderForTesting(
            secondJob,
            in: transport,
            allowIncrementalUpdate: false
        )

        #expect(transport.isLogPinnedToBottomForTesting)
    }

    @Test func switchingFromShortToLongJobMaterializesVisibleTextKit2Fragments() async throws {
        let shortLog = (0..<3).map { "short visible line \($0)" }.joined(separator: "\n")
        let longLog = (0..<700)
            .map { "long visible fragment line \($0) with enough text to exercise viewport surface reuse" }
            .joined(separator: "\n")
        let shortJob = makeJob(
            id: "job-fragment-short",
            status: .running,
            targetSummary: "Short log",
            summary: "Short preview.",
            logText: shortLog
        )
        let longJob = makeJob(
            id: "job-fragment-long",
            status: .succeeded,
            targetSummary: "Long log",
            summary: "Long review completed.",
            logText: longLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [shortJob, longJob]))
        let harness = makeWindowHarness(store: store, contentSize: NSSize(width: 900, height: 600))
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(shortJob))
        _ = try await awaitTimelineRenderForTesting(
            shortJob,
            in: transport,
            allowIncrementalUpdate: false
        )

        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(longJob))
        let longSnapshot = try await awaitTimelineRenderForTesting(
            longJob,
            in: transport,
            allowIncrementalUpdate: false
        )

        #expect(longSnapshot.log == reviewMonitorLogText(for: longJob))
        #expect(transport.isLogPinnedToBottomForTesting)
        expectLogVisibleFragmentsWithoutForcingLayout(transport)
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(shortJob))
        _ = try await awaitTimelineRenderForTesting(
            shortJob,
            in: transport,
            allowIncrementalUpdate: false
        )
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(recentJob))
        _ = try await awaitTimelineRenderForTesting(
            recentJob,
            in: transport,
            allowIncrementalUpdate: false
        )
        expectLogVisibleFragmentsWithoutForcingLayout(transport)

        replaceTimelineLogTextForTesting(shortJob, longLog)
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(shortJob))
        _ = try await awaitTimelineRenderForTesting(
            shortJob,
            in: transport,
            allowIncrementalUpdate: false
        )

        #expect(
            abs(
                transport.logVerticalScrollOffsetForTesting
                    - transport.logMinimumVerticalScrollOffsetForTesting
            ) < 0.5)
        #expect(transport.isLogPinnedToBottomForTesting == false)
        expectLogVisibleFragmentsWithoutForcingLayout(transport)
    }

    @Test func previouslySelectedReviewChatUpdatesDoNotRepaintCurrentDetailPane() async throws {
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(activeJob))
        _ = try await awaitTimelineRenderForTesting(
            activeJob,
            in: transport,
            allowIncrementalUpdate: false
        )
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(recentJob))
        _ = try await awaitTimelineRenderForTesting(
            recentJob,
            in: transport,
            allowIncrementalUpdate: false
        )
        appendTimelineEntryForTesting(activeJob, .init(kind: .progress, text: "stale update"))
        appendTimelineEntryForTesting(recentJob, .init(kind: .progress, text: "fresh update"))

        let updatedSnapshot = try await awaitTimelineRenderForTesting(recentJob, in: transport) { snapshot in
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))

        let selectedSnapshot = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        viewController.sidebarViewControllerForTesting.clickBlankAreaForTesting()

        #expect(viewController.sidebarViewControllerForTesting.selectedReviewChatIDForTesting == job.legacyReviewChatID)
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))

        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        viewController.sidebarViewControllerForTesting.clickWorkspaceHeaderForTesting(workspace)

        _ = try await awaitTransportRender(transport)
        #expect(
            viewController.sidebarViewControllerForTesting.selectedWorkspaceSectionForTesting?.workspaceCWDs == [
                workspace.cwd
            ])
        #expect(viewController.sidebarViewControllerForTesting.selectedReviewChatIDForTesting == nil)
        #expect(
            transport.workspaceFindingSnapshotForTesting
                == .init(
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()

        #expect(viewController.sidebarViewControllerForTesting.selectedReviewChatIDForTesting == nil)
        #expect(viewController.contentPaneViewControllerForTesting.isShowingEmptyStateForTesting)

        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [activeJob])
        )

        #expect(viewController.sidebarViewControllerForTesting.selectedReviewChatIDForTesting == nil)
        #expect(viewController.contentPaneViewControllerForTesting.isShowingEmptyStateForTesting)
        #expect(viewController.contentPaneViewControllerForTesting.displayedTitleForTesting == nil)
    }

    @Test func removingSelectedReviewChatClearsSelectionWithoutAutoSelectingReplacement() async throws {
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let contentPane = viewController.contentPaneViewControllerForTesting
        let transport = viewController.transportViewControllerForTesting
        let sidebar = viewController.sidebarViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(activeJob))

        let activeSnapshot = try await awaitTimelineRenderForTesting(
            activeJob,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(activeSnapshot.title == nil)
        #expect(activeSnapshot.summary == nil)
        store.loadForTesting(
            serverState: .running,
            content: makeSidebarContent(from: [recentJob])
        )
        try await waitForObservedValue(
            from: sidebar.sidebarTopologyObservationForTesting,
            true
        ) {
            sidebar.selectedReviewChatIDForTesting == nil
        }

        let emptySnapshot = try await awaitContentPaneRender(contentPane)
        #expect(sidebar.selectedReviewChatIDForTesting == nil)
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
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))

        let selectedSnapshot = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
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
        job.updateStateForTesting(summary: "Deselected summary")
        replaceTimelineLogTextForTesting(job, "Deselected log")

        #expect(contentPane.selectedChatLogTaskForTesting == nil)
        #expect(contentPane.renderSnapshotForTesting == emptySnapshot)
    }

    @Test func inPlaceReviewChatUpdateKeepsSelectionAndRefreshesDetailPane() async throws {
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))

        let selectedSnapshot = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(selectedSnapshot.title == nil)
        #expect(selectedSnapshot.summary == nil)
        job.updateStateForTesting(
            status: .succeeded,
            summary: "Review completed successfully."
        )
        replaceTimelineLogTextForTesting(job, "Updated log")

        let updatedSnapshot = try await awaitTimelineRenderForTesting(job, in: transport)
        #expect(viewController.sidebarViewControllerForTesting.selectedReviewChatIDForTesting == job.legacyReviewChatID)
        #expect(updatedSnapshot.summary == nil)
        #expect(updatedSnapshot.log == reviewMonitorLogText(for: job))
    }

    @Test func selectedReviewChatLogAppendUsesAppendPath() async throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-append",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review."
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let previewChatLogSource = try makePreviewChatLogSourceForTesting(job: job) { turnID in
            [makePreviewMessageItemForTesting(id: "msg_1", text: "Initial", turnID: turnID)]
        }
        let viewController = ReviewMonitorSplitViewController(
            store: store,
            uiState: ReviewMonitorUIState(auth: store.auth),
            previewChatLogSource: previewChatLogSource
        )
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 360))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        let chatID = try #require(job.legacyReviewChatID)
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatID)
        _ = try await awaitTransportRender(transport) { $0.log == "Initial" }
        transport.setLogReduceMotionForTesting(false)
        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        previewChatLogSource.appendPreviewText(
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
        let job = CodexReviewJob.makeForTesting(
            id: "job-progress-separator-append",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review."
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let previewChatLogSource = try makePreviewChatLogSourceForTesting(job: job) { turnID in
            [makePreviewMessageItemForTesting(id: "msg_1", text: "Initial", turnID: turnID)]
        }
        let viewController = ReviewMonitorSplitViewController(
            store: store,
            uiState: ReviewMonitorUIState(auth: store.auth),
            previewChatLogSource: previewChatLogSource
        )
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 360))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        let chatID = try #require(job.legacyReviewChatID)
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatID)
        _ = try await awaitTransportRender(transport) { $0.log == "Initial" }
        let wordGlowCount = transport.logWordGlowCountForTesting
        previewChatLogSource.upsertPreviewItem(
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
        let job = CodexReviewJob.makeForTesting(
            id: "job-canonical-append",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            timelineEntries: [
                .init(kind: .agentMessage, groupID: "msg_1", text: decomposedPrefix)
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
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
        let job = CodexReviewJob.makeForTesting(
            id: "job-coalesced",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            timelineEntries: [
                .init(kind: .agentMessage, groupID: "msg_1", text: "Initial")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        appendTimelineEntryForTesting(job, .init(kind: .agentMessage, groupID: "msg_1", text: " one"))
        appendTimelineEntryForTesting(job, .init(kind: .agentMessage, groupID: "msg_1", text: " two"))

        let snapshot = try await awaitTimelineRenderForTesting(job, in: transport)
        #expect(snapshot.log == "Initial one two")
    }

    @Test func coalescedProgressSuffixDisplaysLatestProgress() async throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-coalesced-progress",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            timelineEntries: [
                .init(kind: .agentMessage, groupID: "msg_1", text: "Initial")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        appendTimelineEntryForTesting(job, .init(kind: .progress, groupID: "progress_1", text: "stream.tick 001"))
        appendTimelineEntryForTesting(job, .init(kind: .progress, groupID: "progress_2", text: "stream.tick 002"))

        let snapshot = try await awaitTimelineRenderForTesting(job, in: transport)
        #expect(snapshot.log.hasSuffix("stream.tick 002"))
    }

    @Test func coalescedMixedReasoningAndProgressSuffixAnimatesOnlyReasoningRange() async throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-coalesced-mixed-reasoning-progress",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            timelineEntries: [
                .init(kind: .rawReasoning, groupID: "reasoning_1", text: "Thinking")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        transport.setLogReduceMotionForTesting(false)
        let wordGlowCount = transport.logWordGlowCountForTesting
        appendTimelineEntryForTesting(job, .init(kind: .rawReasoning, groupID: "reasoning_1", text: " ok"))
        appendTimelineEntryForTesting(
            job,
            .init(
                kind: .progress,
                groupID: "progress_1",
                text: String(repeating: "progress ", count: 20)
            ))

        let snapshot = try await awaitTimelineRenderForTesting(job, in: transport)
        #expect(snapshot.log.contains("progress progress"))
        #expect(transport.logAppendCountForTesting > 0)
        #expect(transport.logWordGlowCountForTesting == wordGlowCount + 1)
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
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        transport.view.layoutSubtreeIfNeeded()

        let initialDocumentFrame = transport.logDocumentViewFrameForTesting
        #expect(transport.isLogPinnedToBottomForTesting)
        #expect(
            abs(transport.logMaximumVerticalScrollOffsetForTesting - transport.logMinimumVerticalScrollOffsetForTesting)
                < 0.5)
        appendTimelineEntryForTesting(
            job,
            .init(
                kind: .progress,
                text:
                    "stream.tick 001 delta/layout +2 -0 while the short log remains below the scrollable viewport height"
            ))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)
        transport.view.layoutSubtreeIfNeeded()

        let appendedDocumentFrame = transport.logDocumentViewFrameForTesting
        #expect(abs(appendedDocumentFrame.height - initialDocumentFrame.height) < 0.5)
        #expect(
            abs(transport.logMaximumVerticalScrollOffsetForTesting - transport.logMinimumVerticalScrollOffsetForTesting)
                < 0.5)
    }

    @Test func selectedReviewChatGroupedReplacementUsesReplacementPath() async throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-reload",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            timelineEntries: [
                .init(kind: .plan, groupID: "plan_1", text: "- original")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        let appendCount = transport.logAppendCountForTesting
        let replaceCount = transport.logReplaceCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        appendTimelineEntryForTesting(
            job, .init(kind: .plan, groupID: "plan_1", replacesGroup: true, text: "- updated"))

        let snapshot = try await awaitTimelineRenderForTesting(job, in: transport)
        #expect(snapshot.log == "- updated")
        #expect(transport.logAppendCountForTesting == appendCount)
        #expect(transport.logReplaceCountForTesting == replaceCount + 1)
        #expect(transport.logReloadCountForTesting == reloadCount)
    }

    @Test func coalescedCommandAppendAfterReasoningKeepsReasoningAndDoesNotReload() async throws {
        let startedAt = Date(timeIntervalSince1970: 200)
        let job = CodexReviewJob.makeForTesting(
            id: "job-reasoning-command-append",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: startedAt,
            summary: "Running review.",
            timelineEntries: [
                .init(
                    kind: .rawReasoning,
                    groupID: "reasoning_1",
                    text: "Need to inspect files."
                )
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let harness = makeWindowHarness(store: store, contentSize: NSSize(width: 860, height: 520))
        let viewController = harness.viewController
        let window = harness.window
        defer { window.close() }
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting

        appendTimelineEntryForTesting(
            job,
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
            ))
        appendTimelineEntryForTesting(
            job,
            .init(
                kind: .rawReasoning,
                groupID: "reasoning_2",
                text: "Inspecting details after the command starts."
            ))

        let snapshot = try await awaitTimelineRenderForTesting(job, in: transport)
        #expect(snapshot.log.contains("Need to inspect files."))
        #expect(snapshot.log.contains("Running git diff"))
        #expect(snapshot.log.contains("Inspecting details after the command starts."))
        #expect(transport.logAppendCountForTesting == appendCount + 1)
        #expect(transport.logReloadCountForTesting == reloadCount)
    }

    @Test func selectedReviewChatMarkdownAppendReplacesTailBlockWithoutReload() async throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-markdown-append-fallback",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            timelineEntries: [
                .init(kind: .agentMessage, groupID: "msg_1", text: "**bo")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        let appendCount = transport.logAppendCountForTesting
        let replaceCount = transport.logReplaceCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        appendTimelineEntryForTesting(job, .init(kind: .agentMessage, groupID: "msg_1", text: "ld**"))

        let snapshot = try await awaitTimelineRenderForTesting(job, in: transport)
        #expect(snapshot.log == "bold")
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
            timelineEntries: [
                .init(kind: .plan, groupID: "plan_1", text: "- original")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        appendTimelineEntryForTesting(
            job,
            .init(
                kind: .plan,
                groupID: "plan_1",
                replacesGroup: true,
                text: "- updated with longer replacement text"
            ))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)
        let replaceCount = transport.logReplaceCountForTesting
        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        appendTimelineEntryForTesting(job, .init(kind: .commandOutput, groupID: "cmd_1", text: "hidden output"))
        _ = try await awaitTimelineRenderForTesting(job, in: transport) { snapshot in
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        let appendCount = transport.logAppendCountForTesting
        let reloadCount = transport.logReloadCountForTesting
        job.updateStateForTesting(summary: "Updated summary.")

        #expect(transport.displayedLogForTesting == reviewMonitorLogText(for: job))
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
            timelineEntries: [
                .init(kind: .rawReasoning, groupID: "reasoning_1", text: "Thinking")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        transport.setLogReduceMotionForTesting(false)
        appendTimelineEntryForTesting(
            job, .init(kind: .rawReasoning, groupID: "reasoning_1", text: " through options"))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)

        #expect(transport.logWordGlowCountForTesting == 2)

        transport.completeLogWordGlowAnimationsForTesting()
        #expect(transport.logWordGlowCountForTesting == 0)

        appendTimelineEntryForTesting(job, .init(kind: .rawReasoning, groupID: "reasoning_1", text: " again"))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)

        #expect(transport.logWordGlowCountForTesting == 1)

        transport.setLogReduceMotionForTesting(true)
        appendTimelineEntryForTesting(
            job, .init(kind: .rawReasoning, groupID: "reasoning_1", text: " without animation"))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)

        #expect(transport.logWordGlowCountForTesting == 0)
    }

    @Test func screenSwitchBacklogDoesNotAnimateButNextVisibleReasoningAppendDoes() async throws {
        let firstJob = CodexReviewJob.makeForTesting(
            id: "job-reasoning-switch-backlog",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            timelineEntries: [
                .init(kind: .rawReasoning, groupID: "reasoning_1", text: "Thinking")
            ]
        )
        let secondJob = CodexReviewJob.makeForTesting(
            id: "job-other-selected",
            cwd: "/tmp/workspace-beta",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 201),
            summary: "Running review.",
            timelineEntries: [
                .init(kind: .agentMessage, groupID: "msg_1", text: "Other job")
            ]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [firstJob, secondJob]))
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        transport.setLogReduceMotionForTesting(false)

        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(firstJob))
        _ = try await awaitTimelineRenderForTesting(
            firstJob,
            in: transport,
            allowIncrementalUpdate: false
        )
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(secondJob))
        _ = try await awaitTimelineRenderForTesting(
            secondJob,
            in: transport,
            allowIncrementalUpdate: false
        )
        appendTimelineEntryForTesting(
            firstJob, .init(kind: .rawReasoning, groupID: "reasoning_1", text: " hidden backlog"))

        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(firstJob))
        _ = try await awaitTimelineRenderForTesting(
            firstJob,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(transport.logWordGlowCountForTesting == 0)

        appendTimelineEntryForTesting(firstJob, .init(kind: .rawReasoning, groupID: "reasoning_1", text: " live"))
        _ = try await awaitTimelineRenderForTesting(firstJob, in: transport)
        #expect(transport.logWordGlowCountForTesting > 0)
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
            timelineEntries: [
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
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        transport.setLogReduceMotionForTesting(false)

        let invalidationCount = transport.logWordFadeDisplayInvalidationCountForTesting
        appendTimelineEntryForTesting(
            job, .init(kind: .rawReasoning, groupID: "reasoning_1", text: " through options"))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)

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
        let job = CodexReviewJob.makeForTesting(
            id: "job-reasoning-glow-delayed-first-tick",
            cwd: "/tmp/workspace-alpha",
            targetSummary: "Uncommitted changes",
            threadID: UUID().uuidString,
            turnID: UUID().uuidString,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 200),
            summary: "Running review.",
            timelineEntries: [
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
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        transport.setLogReduceMotionForTesting(false)

        appendTimelineEntryForTesting(job, .init(kind: .rawReasoning, groupID: "reasoning_1", text: " ok"))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)
        #expect(transport.logWordGlowCountForTesting > 0)

        transport.advanceLogWordGlowAnimationsAfterInitialDelayForTesting(5)
        #expect(transport.logWordGlowCountForTesting > 0)
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(transport.isLogPinnedToBottomForTesting)

        transport.scrollLogToBottomForTesting()
        #expect(transport.isLogPinnedToBottomForTesting)

        transport.scrollLogToTopForTesting()
        #expect(transport.isLogPinnedToBottomForTesting == false)
        let unpinnedAutoFollow = transport.logAutoFollowCountForTesting
        appendTimelineEntryForTesting(job, .init(kind: .progress, text: "Unpinned update"))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)
        #expect(transport.logAutoFollowCountForTesting == unpinnedAutoFollow)
        #expect(transport.isLogPinnedToBottomForTesting == false)

        transport.scrollLogToBottomForTesting()
        #expect(transport.isLogPinnedToBottomForTesting)
        let pinnedAutoFollow = transport.logAutoFollowCountForTesting
        appendTimelineEntryForTesting(job, .init(kind: .progress, text: "Pinned update"))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)
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
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        transport.scrollLogToBottomForTesting()
        #expect(transport.isLogPinnedToBottomForTesting)
        let pinnedAutoFollow = transport.logAutoFollowCountForTesting
        let wrappedLine = (0..<140)
            .map { "wrapped-append-segment-\($0)" }
            .joined(separator: " ")
        appendTimelineEntryForTesting(job, .init(kind: .progress, text: wrappedLine))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)

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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        let nearBottomOffset = transport.logMaximumVerticalScrollOffsetForTesting - 12
        transport.scrollLogToOffsetForTesting(nearBottomOffset)
        #expect(transport.isLogPinnedToBottomForTesting == false)
        let offsetBeforeAppend = transport.logVerticalScrollOffsetForTesting
        let autoFollowBeforeAppend = transport.logAutoFollowCountForTesting
        let programmaticScrollsBeforeAppend = transport.logProgrammaticScrollCountForTesting
        appendTimelineEntryForTesting(
            job,
            .init(
                kind: .progress,
                text: "Near-bottom append should not snap inertial or manual scrolling to the document end"
            ))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)

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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.scrollLogToBottomForTesting()
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting
        appendTimelineEntryForTesting(job, .init(kind: .progress, text: "Newest line"))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)

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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        transport.setLogScrollerStyleForTesting(.legacy)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.scrollLogToBottomForTesting()
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting
        appendTimelineEntryForTesting(job, .init(kind: .progress, text: "Newest line"))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)

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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting
        appendTimelineEntryForTesting(job, .init(kind: .progress, text: "short update"))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)

        #expect(transport.logOverlayScrollerHideRequestCountForTesting == hideCountBeforeAppend)
    }

    @Test func selectingReviewChatRequestsOverlayScrollerHideWhenRestoringScrollPosition() async throws {
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(firstJob))
        _ = try await awaitTimelineRenderForTesting(
            firstJob,
            in: transport,
            allowIncrementalUpdate: false
        )

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.scrollLogToOffsetForTesting(120)
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(secondJob))
        _ = try await awaitTimelineRenderForTesting(
            secondJob,
            in: transport,
            allowIncrementalUpdate: false
        )

        let hideCountBeforeRestore = transport.logOverlayScrollerHideRequestCountForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(firstJob))
        _ = try await awaitTimelineRenderForTesting(
            firstJob,
            in: transport,
            restoring: .top,
            allowIncrementalUpdate: false
        )

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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.setLogOverlayScrollerBridgeModeForTesting(.missingScrollerImpPair)
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting
        appendTimelineEntryForTesting(job, .init(kind: .progress, text: "Newest line"))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)

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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        transport.setLogScrollerStyleForTesting(.overlay)
        transport.setLogOverlayScrollersShownForTesting(true)
        transport.setLogOverlayScrollerBridgeModeForTesting(.missingHideMethods)
        let hideCountBeforeAppend = transport.logOverlayScrollerHideRequestCountForTesting
        appendTimelineEntryForTesting(job, .init(kind: .progress, text: "Newest line"))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)

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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
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
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
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
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        let appendCount = transport.logAppendCountForTesting
        appendTimelineEntryForTesting(job, .init(kind: .progress, text: "Newest fragment line"))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)

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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        #expect(viewController.validateUserInterfaceItem(textFinderMenuItemForTesting(.showFindInterface)))
        #expect(viewController.validateUserInterfaceItem(textFinderMenuItemForTesting(.nextMatch)))
        #expect(viewController.validateUserInterfaceItem(textFinderMenuItemForTesting(.replace)) == false)
        #expect(transport.logAccessibilityValueForTesting == reviewMonitorLogText(for: job))
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
        #expect(transport.logSelectedTextForTesting == reviewMonitorLogText(for: job))
        #expect(transport.validateLogDocumentUserInterfaceItemForTesting(copyItem))
        #expect(transport.validateLogDocumentUserInterfaceItemForTesting(cutItem) == false)
        #expect(transport.validateLogDocumentUserInterfaceItemForTesting(pasteItem) == false)
        #expect(transport.validateLogDocumentUserInterfaceItemForTesting(deleteItem) == false)

        NSPasteboard.general.clearContents()
        transport.copyLogSelectionForTesting()
        #expect(NSPasteboard.general.string(forType: .string) == reviewMonitorLogText(for: job))

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
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
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
        let job = makeJob(
            id: "job-log-find-system-highlights",
            status: .running,
            targetSummary: "Uncommitted changes",
            summary: "Running review.",
            logText: initialLog
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, content: makeSidebarContent(from: [job]))
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 360))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

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
        appendTimelineEntryForTesting(job, .init(kind: .progress, text: "needle appended"))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)

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
        #expect(
            transport.logFindIndicatorInvalidationCountForTesting == findIndicatorInvalidationCountBeforeSnapshotScroll
                + 1)
        #expect(transport.isLogPinnedToBottomForTesting == false)

        let offsetBeforeMiddleAppend = transport.logVerticalScrollOffsetForTesting
        appendTimelineEntryForTesting(
            job, .init(kind: .progress, text: "needle appended while the log is not following bottom"))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)

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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(firstJob))
        _ = try await awaitTimelineRenderForTesting(
            firstJob,
            in: transport,
            allowIncrementalUpdate: false
        )

        let firstNeedleRange = (reviewMonitorLogText(for: firstJob) as NSString).range(of: "needle")
        #expect(firstNeedleRange.location != NSNotFound)
        transport.setSelectedLogRangeForTesting(firstNeedleRange)
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.setSearchString))
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        appendTimelineEntryForTesting(firstJob, .init(kind: .progress, text: "needle appended"))
        _ = try await awaitTimelineRenderForTesting(firstJob, in: transport)
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting)
        viewController.sidebarViewControllerForTesting.clearSelectionForTesting()
        _ = try await awaitTransportRender(transport)
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting == false)
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(secondJob))
        _ = try await awaitTimelineRenderForTesting(
            secondJob,
            in: transport,
            allowIncrementalUpdate: false
        )

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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(firstJob))
        _ = try await awaitTimelineRenderForTesting(
            firstJob,
            in: transport,
            allowIncrementalUpdate: false
        )

        let firstNeedleRange = (reviewMonitorLogText(for: firstJob) as NSString).range(of: "needle")
        #expect(firstNeedleRange.location != NSNotFound)
        transport.setSelectedLogRangeForTesting(firstNeedleRange)
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.setSearchString))
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        appendTimelineEntryForTesting(firstJob, .init(kind: .progress, text: appendedLine))
        _ = try await awaitTimelineRenderForTesting(firstJob, in: transport)
        #expect(
            transport.displayedLogForTesting.trimmingCharacters(in: .newlines)
                == reviewMonitorLogText(for: secondJob).trimmingCharacters(in: .newlines)
        )
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting)

        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(secondJob))
        _ = try await awaitTimelineRenderForTesting(
            secondJob,
            in: transport,
            allowIncrementalUpdate: false
        )

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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(firstJob))
        _ = try await awaitTimelineRenderForTesting(
            firstJob,
            in: transport,
            allowIncrementalUpdate: false
        )

        let firstNeedleRange = (reviewMonitorLogText(for: firstJob) as NSString).range(of: "needle")
        #expect(firstNeedleRange.location != NSNotFound)
        transport.setSelectedLogRangeForTesting(firstNeedleRange)
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.setSearchString))
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.setLogVisibleFindBarSearchStringForTesting(""))
        #expect(transport.logFindClientUsesSnapshotForTesting == false)

        let finderIdentifierBeforeSwitch = transport.logTextFinderIdentifierForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(secondJob))
        _ = try await awaitTimelineRenderForTesting(
            secondJob,
            in: transport,
            allowIncrementalUpdate: false
        )

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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        let firstNeedleRange = (reviewMonitorLogText(for: job) as NSString).range(of: "needle")
        #expect(firstNeedleRange.location != NSNotFound)
        transport.setSelectedLogRangeForTesting(firstNeedleRange)
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.setSearchString))
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        appendTimelineEntryForTesting(job, .init(kind: .progress, text: "needle appended"))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        let firstNeedleRange = (reviewMonitorLogText(for: job) as NSString).range(of: "needle")
        #expect(firstNeedleRange.location != NSNotFound)
        transport.setSelectedLogRangeForTesting(firstNeedleRange)
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.setSearchString))
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        appendTimelineEntryForTesting(job, .init(kind: .progress, text: "needle appended into snapshot"))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting)

        #expect(transport.setLogVisibleFindBarSearchStringForTesting(""))
        transport.clearLogFinderSelectedRangesForTesting()
        #expect(transport.logFindClientFirstSelectedRangeForTesting.length == 0)
        #expect(transport.logSelectedTextForTesting == nil)
        #expect(transport.logFindClientUsesSnapshotForTesting == false)
        appendTimelineEntryForTesting(job, .init(kind: .progress, text: "needle appended after cleared selection"))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)

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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        let firstNeedleRange = (reviewMonitorLogText(for: job) as NSString).range(of: "needle")
        #expect(firstNeedleRange.location != NSNotFound)
        transport.setSelectedLogRangeForTesting(firstNeedleRange)
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.setSearchString))
        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        appendTimelineEntryForTesting(job, .init(kind: .progress, text: "needle appended into snapshot"))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.logFindClientUsesSnapshotForTesting)

        try await withFindPasteboardString(nil) {
            #expect(transport.setLogVisibleFindBarSearchStringForTesting(""))
            transport.simulateLogFinderEmptySelectedRangesForTesting()
            #expect(transport.logFindClientFirstSelectedRangeForTesting.length == 0)
            #expect(transport.logHasActiveFindQueryForTesting == false)
            #expect(transport.logFindClientUsesSnapshotForTesting == false)
            appendTimelineEntryForTesting(job, .init(kind: .progress, text: "needle appended after cleared query"))
            _ = try await awaitTimelineRenderForTesting(job, in: transport)

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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        try await withFindPasteboardString(nil) {
            viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
            #expect(transport.logFindBarVisibleForTesting)
            #expect(transport.setLogVisibleFindBarSearchStringForTesting(""))
            #expect(transport.logVisibleFindBarSearchStringForTesting == "")
            #expect(transport.logFindClientUsesSnapshotForTesting == false)
            appendTimelineEntryForTesting(job, .init(kind: .progress, text: "future-only needle"))
            _ = try await awaitTimelineRenderForTesting(job, in: transport)

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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        let initialLength = (reviewMonitorLogText(for: job) as NSString).length
        try await withFindPasteboardString(nil) {
            viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
            #expect(transport.logFindBarVisibleForTesting)
            #expect(transport.setLogVisibleFindBarSearchStringForTesting("core"))
            #expect(transport.logVisibleFindBarSearchStringForTesting == "core")
            #expect(transport.logHasActiveFindQueryForTesting)
            appendTimelineEntryForTesting(job, .init(kind: .progress, text: "core appended while query is visible"))
            _ = try await awaitTimelineRenderForTesting(job, in: transport)

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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        let initialLength = (reviewMonitorLogText(for: job) as NSString).length
        try await withFindPasteboardString(nil) {
            viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
            #expect(transport.logFindBarVisibleForTesting)
            #expect(transport.setLogVisibleFindBarSearchStringForTesting("alpha"))
            #expect(transport.logFindStringLengthForTesting == initialLength)

            appendTimelineEntryForTesting(job, .init(kind: .progress, text: "beta appended after active search"))
            _ = try await awaitTimelineRenderForTesting(job, in: transport)
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

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
            appendTimelineEntryForTesting(
                job, .init(kind: .progress, text: "needle appended after normal selection"))
            _ = try await awaitTimelineRenderForTesting(job, in: transport)

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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
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

            let initialLength = (reviewMonitorLogText(for: job) as NSString).length
            appendTimelineEntryForTesting(
                job, .init(kind: .progress, text: "active query appears after no-result search"))
            _ = try await awaitTimelineRenderForTesting(job, in: transport)

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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 720, height: 320))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))
        _ = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )

        viewController.performTextFinderAction(textFinderMenuItemForTesting(.showFindInterface))
        #expect(transport.logFindBarVisibleForTesting)
        #expect(transport.setLogVisibleFindBarSearchStringForTesting(""))
        #expect(transport.logFindStringLengthForTesting == 0)
        appendTimelineEntryForTesting(job, .init(kind: .progress, text: "needle first content"))
        _ = try await awaitTimelineRenderForTesting(job, in: transport)

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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))

        let snapshot = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(snapshot.summary == nil)
        #expect(snapshot.log == reviewMonitorLogText(for: job))
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
        let viewController = ReviewMonitorSplitViewController(
            store: store, uiState: ReviewMonitorUIState(auth: store.auth))
        viewController.loadViewIfNeeded()
        let transport = viewController.transportViewControllerForTesting
        viewController.sidebarViewControllerForTesting.selectReviewChatForTesting(id: chatIDForTesting(job))

        let snapshot = try await awaitTimelineRenderForTesting(
            job,
            in: transport,
            allowIncrementalUpdate: false
        )
        #expect(snapshot.summary == nil)
        #expect(snapshot.log == reviewMonitorLogText(for: job))
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
    let windowController = ReviewMonitorWindowController(
        store: store,
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
    let job = CodexReviewJob.makeForTesting(
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
        timelineEntries: [],
        errorMessage: status == .failed ? summary ?? status.displayText : nil
    )
    seedTimelineForTesting(job, logText: logText, rawLogText: rawLogText)
    return job
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
    return (makeWorkspaces(from: jobs), Array(jobs.reversed()))
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
        workspaces: [CodexReviewWorkspace],
        jobs: [CodexReviewJob] = [],
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
        settingsSnapshot: CodexReviewSettings.Snapshot? = nil
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
