import AppKit
import Foundation
import Testing
@_spi(Testing) @testable import CodexReview
@_spi(ApplicationHostSupport) import CodexReview
@testable import ReviewUI
import CodexReviewTesting

extension ReviewUITests {
    @Test func queuedReviewAcceptanceMovesWorkspaceAndRetainsManualOrderAndSelection() async throws {
        let alphaWorkspace = CodexReviewWorkspace(cwd: "/tmp/workspace-alpha")
        let betaWorkspace = CodexReviewWorkspace(cwd: "/tmp/workspace-beta")
        let alphaJob = makeWorkspaceSortJob(
            id: "sort-alpha",
            cwd: alphaWorkspace.cwd,
            acceptedAt: 200,
            startedAt: 500
        )
        let betaJob = makeWorkspaceSortJob(
            id: "sort-beta",
            cwd: betaWorkspace.cwd,
            acceptedAt: 100,
            startedAt: 600
        )
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            clock: .init(now: { Date(timeIntervalSince1970: 300) }),
            idGenerator: .init(next: { "sort-beta-queued" })
        )
        await store.loadReviewHistoryIfNeeded()
        store.loadForTesting(
            serverState: .running,
            workspaces: [alphaWorkspace, betaWorkspace],
            jobs: [alphaJob, betaJob]
        )
        store.suspendReviewStarts()
        let uiState = ReviewMonitorUIState(
            auth: store.auth,
            sidebarWorkspaceSortOrder: .latestJobAccepted
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()
        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.collapseWorkspaceInOutlineForTesting(betaWorkspace)
        sidebar.selectJobForTesting(alphaJob)
        let fullReloadCount = sidebar.sidebarFullReloadCountForTesting
        let incrementalMoveCount = sidebar.sidebarIncrementalMoveCountForTesting
        #expect(sidebar.displayedSectionTitlesForTesting == ["workspace-alpha", "workspace-beta"])

        do {
            let accepted = try await store.startReview(
                sessionID: "workspace-sort",
                request: .init(cwd: betaWorkspace.cwd, target: .uncommittedChanges),
                waitTimeout: .zero
            )
            #expect(accepted.core.lifecycle.status == .queued)
            #expect(accepted.core.lifecycle.startedAt == nil)
            let queuedJob = try #require(store.job(id: accepted.jobID))
            #expect(queuedJob.acceptedAt == Date(timeIntervalSince1970: 300))
            try await waitForCondition {
                sidebar.displayedSectionTitlesForTesting == ["workspace-beta", "workspace-alpha"]
            }

            #expect(store.orderedWorkspaces.map(\.cwd) == [alphaWorkspace.cwd, betaWorkspace.cwd])
            #expect(sidebar.selectedJobForTesting === alphaJob)
            #expect(sidebar.selectedOutlineJobIDForTesting == alphaJob.id)
            #expect(sidebar.workspaceIsExpandedForTesting(alphaWorkspace))
            #expect(sidebar.workspaceOutlineIsExpandedForTesting(alphaWorkspace))
            #expect(sidebar.workspaceIsExpandedForTesting(betaWorkspace) == false)
            #expect(sidebar.workspaceOutlineIsExpandedForTesting(betaWorkspace) == false)
            #expect(sidebar.sidebarFullReloadCountForTesting == fullReloadCount)
            #expect(sidebar.sidebarIncrementalMoveCountForTesting == incrementalMoveCount + 1)
            #expect(await backend.recordedCommands().contains {
                if case .startReview = $0 { true } else { false }
            } == false)

            uiState.sidebarWorkspaceSortOrder = .manual
            try await waitForCondition {
                sidebar.displayedSectionTitlesForTesting == ["workspace-alpha", "workspace-beta"]
            }
            #expect(sidebar.selectedJobForTesting === alphaJob)
            #expect(sidebar.selectedOutlineJobIDForTesting == alphaJob.id)
            #expect(sidebar.workspaceIsExpandedForTesting(betaWorkspace) == false)
            #expect(sidebar.sidebarFullReloadCountForTesting == fullReloadCount)
        } catch {
            await store.shutdown()
            throw error
        }
        await store.shutdown()
    }

    @Test(arguments: [SidebarJobFilter.running, .latestFinished])
    func latestAcceptedWorkspaceOrderUsesHiddenJobsAcrossLinkedWorktrees(
        filter: SidebarJobFilter
    ) async throws {
        let fixture = try makeLinkedWorktreeFixtureForTesting(repositoryName: "CodexReviewKit")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let firstWorkspace = CodexReviewWorkspace(cwd: fixture.firstWorktreeURL.path)
        let secondWorkspace = CodexReviewWorkspace(cwd: fixture.secondWorktreeURL.path)
        let otherWorkspace = CodexReviewWorkspace(cwd: "/tmp/workspace-other")
        let firstJob = makeWorkspaceSortJob(
            id: "sort-first-worktree-running",
            cwd: firstWorkspace.cwd,
            acceptedAt: 100,
            startedAt: 800,
            status: .running
        )
        let secondFinishedJob = makeWorkspaceSortJob(
            id: "sort-second-worktree-finished",
            cwd: secondWorkspace.cwd,
            acceptedAt: 200,
            startedAt: 800
        )
        let hiddenJob = makeWorkspaceSortJob(
            id: "sort-second-worktree-hidden",
            cwd: secondWorkspace.cwd,
            acceptedAt: 500,
            startedAt: filter == .running ? 100 : nil,
            status: filter == .running ? .succeeded : .queued
        )
        let otherJob = makeWorkspaceSortJob(
            id: "sort-other-workspace",
            cwd: otherWorkspace.cwd,
            acceptedAt: 400,
            startedAt: 900,
            status: filter == .running ? .running : .succeeded
        )
        let manualWorkspaces = [otherWorkspace, firstWorkspace, secondWorkspace]
        let jobs = [firstJob, otherJob, hiddenJob, secondFinishedJob]
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, workspaces: manualWorkspaces, jobs: jobs)
        let uiState = ReviewMonitorUIState(
            auth: store.auth,
            sidebarJobFilter: filter,
            sidebarWorkspaceSortOrder: .latestJobAccepted
        )
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()
        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.displayedSectionTitlesForTesting == ["CodexReviewKit", "workspace-other"])
        #expect(sidebar.displayedJobIDsForTesting(in: secondWorkspace).contains(hiddenJob.id) == false)
        #expect(sidebar.displayedJobIDsForTesting(in: firstWorkspace) == (filter == .running ? [firstJob.id] : []))
        #expect(sidebar.displayedJobIDsForTesting(in: secondWorkspace) == (filter == .latestFinished ? [secondFinishedJob.id] : []))

        store.loadForTesting(
            serverState: .running,
            workspaces: manualWorkspaces,
            jobs: Array(jobs.reversed())
        )
        uiState.sidebarJobFilter = .all
        try await waitForCondition {
            sidebar.displayedJobIDsForTesting(in: secondWorkspace) == [secondFinishedJob.id, hiddenJob.id]
        }
        #expect(sidebar.displayedSectionTitlesForTesting == ["CodexReviewKit", "workspace-other"])
        #expect(store.orderedWorkspaces.map(\.cwd) == manualWorkspaces.map(\.cwd))

        uiState.sidebarWorkspaceSortOrder = .manual
        try await waitForCondition {
            sidebar.displayedSectionTitlesForTesting == ["workspace-other", "CodexReviewKit"]
        }
    }

    @Test func latestAcceptedWorkspaceOrderRejectsWorkspaceDragAndKeepsJobReordering() async throws {
        let alphaWorkspace = CodexReviewWorkspace(cwd: "/tmp/workspace-alpha")
        let betaWorkspace = CodexReviewWorkspace(cwd: "/tmp/workspace-beta")
        let firstJob = makeWorkspaceSortJob(id: "sort-drag-first", cwd: alphaWorkspace.cwd, acceptedAt: 200)
        let secondJob = makeWorkspaceSortJob(id: "sort-drag-second", cwd: alphaWorkspace.cwd, acceptedAt: 150)
        let betaJob = makeWorkspaceSortJob(id: "sort-drag-beta", cwd: betaWorkspace.cwd, acceptedAt: 100)
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [alphaWorkspace, betaWorkspace],
            jobs: [firstJob, secondJob, betaJob]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()
        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.workspaceSectionCanStartDragForTesting(containing: alphaWorkspace))

        #expect(sidebar.performWorkspaceDropForTesting(alphaWorkspace, toIndex: 2))
        uiState.sidebarWorkspaceSortOrder = .latestJobAccepted
        #expect(sidebar.workspaceSectionCanStartDragForTesting(containing: alphaWorkspace) == false)
        #expect(sidebar.performWorkspaceDropForTesting(alphaWorkspace, toIndex: 2) == false)
        #expect(sidebar.performWorkspaceDropForTesting(betaWorkspace, proposedWorkspace: alphaWorkspace) == false)
        await sidebar.waitForHistoryActionsForTesting()
        try await waitForCondition {
            sidebar.displayedSectionTitlesForTesting == ["workspace-alpha", "workspace-beta"]
        }
        #expect(store.orderedWorkspaces.map(\.cwd) == [alphaWorkspace.cwd, betaWorkspace.cwd])

        sidebar.selectJobForTesting(firstJob)
        #expect(sidebar.selectedJobCanStartDragForTesting(firstJob))
        #expect(sidebar.performJobDropForTesting(firstJob, proposedWorkspace: alphaWorkspace, childIndex: 2))
        await sidebar.waitForHistoryActionsForTesting()
        #expect(sidebar.displayedJobIDsForTesting(in: alphaWorkspace) == [secondJob.id, firstJob.id])
        #expect(sidebar.displayedSectionTitlesForTesting == ["workspace-alpha", "workspace-beta"])
        #expect(sidebar.selectedJobForTesting === firstJob)

        uiState.sidebarWorkspaceSortOrder = .manual
        #expect(sidebar.workspaceSectionCanStartDragForTesting(containing: alphaWorkspace))
        try await waitForCondition {
            sidebar.displayedSectionTitlesForTesting == ["workspace-alpha", "workspace-beta"]
        }
    }

    @Test func workspaceDropStartedInManualKeepsAutomaticOrderWhenPersistenceCompletes() async throws {
        let alphaWorkspace = CodexReviewWorkspace(cwd: "/tmp/workspace-alpha")
        let betaWorkspace = CodexReviewWorkspace(cwd: "/tmp/workspace-beta")
        let gammaWorkspace = CodexReviewWorkspace(cwd: "/tmp/workspace-gamma")
        let saveEntered = AsyncGate()
        let saveRelease = AsyncGate()
        let history = WorkspaceOrderingPersistence(saveEntered: saveEntered, saveRelease: saveRelease)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend()),
            historyPersistence: history
        )
        await store.loadReviewHistoryIfNeeded()
        store.loadForTesting(
            serverState: .running,
            workspaces: [alphaWorkspace, betaWorkspace, gammaWorkspace],
            jobs: [
                makeWorkspaceSortJob(id: "sort-pending-alpha", cwd: alphaWorkspace.cwd, acceptedAt: 200),
                makeWorkspaceSortJob(id: "sort-pending-beta", cwd: betaWorkspace.cwd, acceptedAt: 100),
                makeWorkspaceSortJob(id: "sort-pending-gamma", cwd: gammaWorkspace.cwd, acceptedAt: 300),
            ]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()
        let sidebar = viewController.sidebarViewControllerForTesting
        #expect(sidebar.performWorkspaceDropForTesting(alphaWorkspace, toIndex: 3))

        do {
            try await saveEntered.wait(timeout: .seconds(2), operation: "workspace ordering persistence")
            uiState.sidebarWorkspaceSortOrder = .latestJobAccepted
            try await waitForCondition {
                sidebar.displayedSectionTitlesForTesting == ["workspace-gamma", "workspace-alpha", "workspace-beta"]
            }
            await saveRelease.open()
            await sidebar.waitForHistoryActionsForTesting()
            #expect(store.orderedWorkspaces.map(\.cwd) == [betaWorkspace.cwd, gammaWorkspace.cwd, alphaWorkspace.cwd])
            let savedOrdering = try #require(await history.savedOrdering)
            #expect(savedOrdering.workspaces.sorted { $0.sortOrder > $1.sortOrder }.map(\.cwd) == [
                betaWorkspace.cwd, gammaWorkspace.cwd, alphaWorkspace.cwd,
            ])
            #expect(sidebar.displayedSectionTitlesForTesting == ["workspace-gamma", "workspace-alpha", "workspace-beta"])

            uiState.sidebarWorkspaceSortOrder = .manual
            try await waitForCondition {
                sidebar.displayedSectionTitlesForTesting == ["workspace-beta", "workspace-gamma", "workspace-alpha"]
            }
        } catch {
            await saveRelease.open()
            await store.shutdown()
            throw error
        }
        await store.shutdown()
    }

    @Test func latestAcceptedWorkspaceOrderUsesManualOrderForTiesAndEmptyWorkspaces() {
        let emptyFirst = CodexReviewWorkspace(cwd: "/tmp/empty-first")
        let emptySecond = CodexReviewWorkspace(cwd: "/tmp/empty-second")
        let alpha = CodexReviewWorkspace(cwd: "/tmp/workspace-alpha")
        let beta = CodexReviewWorkspace(cwd: "/tmp/workspace-beta")
        let older = CodexReviewWorkspace(cwd: "/tmp/workspace-older")
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [emptyFirst, older, beta, alpha, emptySecond],
            jobs: [
                makeWorkspaceSortJob(id: "sort-tie-alpha", cwd: alpha.cwd, acceptedAt: 200),
                makeWorkspaceSortJob(id: "sort-tie-beta", cwd: beta.cwd, acceptedAt: 200),
                makeWorkspaceSortJob(id: "sort-older", cwd: older.cwd, acceptedAt: 100),
            ]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth, sidebarWorkspaceSortOrder: .latestJobAccepted)
        let viewController = ReviewMonitorSplitViewController(store: store, uiState: uiState)
        viewController.loadViewIfNeeded()
        #expect(viewController.sidebarViewControllerForTesting.displayedSectionTitlesForTesting == [
            "workspace-beta", "workspace-alpha", "workspace-older", "empty-first", "empty-second",
        ])
    }
}

private actor WorkspaceOrderingPersistence: ReviewHistoryPersistence {
    private let saveEntered: AsyncGate
    private let saveRelease: AsyncGate
    private(set) var savedOrdering: ReviewHistoryOrdering?

    init(saveEntered: AsyncGate, saveRelease: AsyncGate) {
        self.saveEntered = saveEntered
        self.saveRelease = saveRelease
    }

    func load(retentionPolicy _: ReviewHistoryRetentionPolicy) async throws -> [RestoredReviewRecord] {
        []
    }

    func recordAccepted(_: AcceptedReviewRecord) async throws {}

    func recordExecutionStarted(id: String, at date: Date) async throws {}

    func recordTerminal(
        _: TerminalReviewRecord,
        retentionPolicy _: ReviewHistoryRetentionPolicy
    ) async throws -> ReviewHistoryMutationResult {
        .init()
    }

    func saveOrdering(_ ordering: ReviewHistoryOrdering) async throws {
        await saveEntered.open()
        await saveRelease.wait()
        savedOrdering = ordering
    }

    func deleteTerminalReviews(withIDs _: Set<String>) async throws -> ReviewHistoryMutationResult {
        .init()
    }

    func deleteAllTerminalReviews() async throws -> ReviewHistoryMutationResult {
        .init()
    }

    func close() async throws {}
}

@MainActor
private func makeWorkspaceSortJob(
    id: String,
    cwd: String,
    acceptedAt: TimeInterval,
    startedAt: TimeInterval? = nil,
    status: ReviewJobState = .succeeded
) -> CodexReviewJob {
    let executionStartedAt = startedAt.map(Date.init(timeIntervalSince1970:))
    return CodexReviewJob.makeForTesting(
        id: id,
        cwd: cwd,
        targetSummary: "Uncommitted changes",
        status: status,
        acceptedAt: Date(timeIntervalSince1970: acceptedAt),
        startedAt: executionStartedAt,
        endedAt: status.isTerminal ? executionStartedAt?.addingTimeInterval(1) : nil,
        summary: status.displayText
    )
}
