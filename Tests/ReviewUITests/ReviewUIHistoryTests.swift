import AppKit
import Foundation
import Testing
@_spi(Testing) @testable import CodexReview
@testable import ReviewUI

@Suite(.serialized)
@MainActor
struct ReviewUIHistoryTests {
    @Test func selectedTerminalContextMenuDeletesOneDurableBatch() async throws {
        let first = try restoredRecord(id: "review-history-first", sortOrder: 0)
        let second = try restoredRecord(id: "review-history-second", sortOrder: 1)
        let retained = try restoredRecord(id: "review-history-retained", sortOrder: 2)
        let history = ReviewUIHistoryPersistence(records: [first, second, retained])
        let store = CodexReviewStore.makeTestingStore(
            backend: PreviewCodexReviewStoreBackend(),
            historyPersistence: history
        )
        await store.loadReviewHistoryIfNeeded()
        let firstJob = try #require(store.job(id: first.started.id))
        let secondJob = try #require(store.job(id: second.started.id))
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let viewController = ReviewMonitorSplitViewController(
            store: store,
            uiState: uiState
        )
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        let sidebar = viewController.sidebarViewControllerForTesting
        let workspace = try #require(store.workspace(cwd: first.started.cwd))
        sidebar.selectJobForTesting(firstJob)
        #expect(sidebar.selectedJobCanStartDragForTesting(firstJob))
        sidebar.selectJobForTesting(secondJob, byExtendingSelection: true)
        #expect(sidebar.selectedJobIDsForTesting == [first.started.id, second.started.id])
        #expect(sidebar.selectedJobForTesting?.id == secondJob.id)
        sidebar.proposeSelectionForTesting(
            jobs: [firstJob, secondJob],
            workspace: workspace
        )

        #expect(sidebar.allowsMultipleSelectionForTesting)
        #expect(sidebar.selectedJobIDsForTesting == [first.started.id, second.started.id])
        #expect(sidebar.selectedWorkspaceSectionForTesting == nil)
        #expect(sidebar.selectedJobForTesting?.id == sidebar.selectedOutlineJobIDForTesting)
        #expect(sidebar.selectedJobCanStartDragForTesting(firstJob) == false)

        var menuItem: NSMenuItem?
        sidebar.presentContextMenuForTesting(for: firstJob) { menu in
            menuItem = menu.items.first
        }
        let deleteItem = try #require(menuItem)
        #expect(deleteItem.title == "Delete from History")
        #expect(deleteItem.isEnabled)
        let action = try #require(deleteItem.action)
        #expect(NSApp.sendAction(action, to: deleteItem.target, from: deleteItem))

        await sidebar.waitForHistoryActionsForTesting()

        #expect(await history.deletionRequests() == [[first.started.id, second.started.id]])
        #expect(store.job(id: first.started.id) == nil)
        #expect(store.job(id: second.started.id) == nil)
        #expect(store.job(id: retained.started.id) != nil)
        #expect(store.workspaces.isEmpty == false)
        #expect(uiState.selectedJobEntry == nil)
    }

    @Test func unselectedTerminalContextMenuDeletesOnlyTheClickedRow() async throws {
        let first = try restoredRecord(id: "selected-first", sortOrder: 0)
        let second = try restoredRecord(id: "selected-second", sortOrder: 1)
        let clicked = try restoredRecord(id: "clicked", sortOrder: 2)
        let history = ReviewUIHistoryPersistence(records: [first, second, clicked])
        let store = CodexReviewStore.makeTestingStore(
            backend: PreviewCodexReviewStoreBackend(),
            historyPersistence: history
        )
        await store.loadReviewHistoryIfNeeded()
        let firstJob = try #require(store.job(id: first.started.id))
        let secondJob = try #require(store.job(id: second.started.id))
        let clickedJob = try #require(store.job(id: clicked.started.id))
        let viewController = ReviewMonitorSplitViewController(
            store: store,
            uiState: ReviewMonitorUIState(auth: store.auth)
        )
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.proposeSelectionForTesting(jobs: [firstJob, secondJob])
        let primaryJobID = sidebar.selectedJobForTesting?.id

        var menuItem: NSMenuItem?
        sidebar.presentContextMenuForTesting(for: clickedJob) { menu in
            menuItem = menu.items.first
        }
        let deleteItem = try #require(menuItem)
        let action = try #require(deleteItem.action)
        #expect(NSApp.sendAction(action, to: deleteItem.target, from: deleteItem))
        await sidebar.waitForHistoryActionsForTesting()

        #expect(await history.deletionRequests() == [[clicked.started.id]])
        #expect(store.job(id: clicked.started.id) == nil)
        #expect(sidebar.selectedJobIDsForTesting == [first.started.id, second.started.id])
        #expect(sidebar.selectedJobForTesting?.id == primaryJobID)
    }

    @Test func activeContextMenuKeepsCancellationAction() {
        let job = CodexReviewJob.makeForTesting(
            id: "active-review-row",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 100),
            summary: "Review running."
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [CodexReviewWorkspace(cwd: job.cwd)],
            jobs: [job]
        )
        let viewController = ReviewMonitorSplitViewController(
            store: store,
            uiState: ReviewMonitorUIState(auth: store.auth)
        )
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()

        var titles: [String] = []
        viewController.sidebarViewControllerForTesting.presentContextMenuForTesting(
            for: job
        ) { menu in
            titles = menu.items.map(\.title)
        }

        #expect(titles == ["Cancel"])
    }

    @Test func mixedActiveAndTerminalSelectionDisablesHistoryDeletion() throws {
        let cwd = "/tmp/workspace"
        let terminal = CodexReviewJob.makeForTesting(
            id: "terminal-review-row",
            cwd: cwd,
            targetSummary: "Base branch: main",
            status: .succeeded,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 120),
            summary: "Review completed."
        )
        let active = CodexReviewJob.makeForTesting(
            id: "active-review-row",
            cwd: cwd,
            targetSummary: "Uncommitted changes",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 100),
            summary: "Review running."
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [CodexReviewWorkspace(cwd: cwd)],
            jobs: [terminal, active]
        )
        let viewController = ReviewMonitorSplitViewController(
            store: store,
            uiState: ReviewMonitorUIState(auth: store.auth)
        )
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        let sidebar = viewController.sidebarViewControllerForTesting
        sidebar.proposeSelectionForTesting(jobs: [terminal, active])

        var menuItem: NSMenuItem?
        sidebar.presentContextMenuForTesting(for: terminal) { menu in
            menuItem = menu.items.first
        }

        let deleteItem = try #require(menuItem)
        #expect(deleteItem.title == "Delete from History")
        #expect(deleteItem.isEnabled == false)
    }

    @Test func historyFailureHasIndependentStatusPresentation() {
        let presentation = ReviewMonitorHistoryStatusPresentation(
            failureMessage: "database is unavailable"
        )

        #expect(presentation?.title == "History unavailable")
        #expect(presentation?.detail == "database is unavailable")
        #expect(ReviewMonitorHistoryStatusPresentation(failureMessage: nil) == nil)
    }

    private func restoredRecord(
        id: String,
        sortOrder: Double = 0
    ) throws -> RestoredReviewRecord {
        let started = try StartedReviewRecord(
            id: id,
            cwd: "/tmp/workspace",
            workspaceSortOrder: 0,
            sortOrder: sortOrder,
            target: .uncommittedChanges,
            model: "gpt-5.6-sol",
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let terminal = try TerminalReviewRecord(
            id: id,
            model: started.model,
            terminal: .completed,
            endedAt: Date(timeIntervalSince1970: 120),
            summary: "Review completed.",
            canonicalReview: "No findings.",
            parsedResult: PersistedParsedReviewResult(.init(
                state: .noFindings,
                findingCount: 0,
                findings: [],
                source: .parsedFinalReviewText
            ))
        )
        return try RestoredReviewRecord(started: started, terminal: terminal)
    }
}

private actor ReviewUIHistoryPersistence: ReviewHistoryPersistence {
    private let records: [RestoredReviewRecord]
    private var requestedDeletions: [Set<String>] = []

    init(records: [RestoredReviewRecord]) {
        self.records = records
    }

    func load(
        retentionPolicy _: ReviewHistoryRetentionPolicy
    ) async throws -> [RestoredReviewRecord] {
        records
    }

    func recordStarted(_: StartedReviewRecord) async throws {}

    func recordTerminal(
        _: TerminalReviewRecord,
        retentionPolicy _: ReviewHistoryRetentionPolicy
    ) async throws -> ReviewHistoryMutationResult {
        .init()
    }

    func saveOrdering(_: ReviewHistoryOrdering) async throws {}

    func deleteTerminalReviews(
        withIDs ids: Set<String>
    ) async throws -> ReviewHistoryMutationResult {
        requestedDeletions.append(ids)
        return .init(removedReviewIDs: ids)
    }

    func deleteAllTerminalReviews() async throws -> ReviewHistoryMutationResult {
        .init()
    }

    func close() async throws {}

    func deletionRequests() -> [Set<String>] {
        requestedDeletions
    }
}
