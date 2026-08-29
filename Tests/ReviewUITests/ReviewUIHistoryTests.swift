import AppKit
import Foundation
import Testing
@_spi(Testing) @testable import CodexReview
@testable import ReviewUI

@Suite(.serialized)
@MainActor
struct ReviewUIHistoryTests {
    @Test func terminalContextMenuDeletesDurableHistory() async throws {
        let record = try restoredRecord(id: "review-history-row")
        let history = ReviewUIHistoryPersistence(records: [record])
        let store = CodexReviewStore.makeTestingStore(
            backend: PreviewCodexReviewStoreBackend(),
            historyPersistence: history
        )
        await store.loadReviewHistoryIfNeeded()
        let job = try #require(store.job(id: record.started.id))
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
        sidebar.selectJobForTesting(job)

        var menuItem: NSMenuItem?
        sidebar.presentContextMenuForTesting(for: job) { menu in
            menuItem = menu.items.first
        }
        let deleteItem = try #require(menuItem)
        #expect(deleteItem.title == "Delete from History")
        #expect(deleteItem.isEnabled)
        let action = try #require(deleteItem.action)
        #expect(NSApp.sendAction(action, to: deleteItem.target, from: deleteItem))

        await sidebar.waitForHistoryActionsForTesting()

        #expect(await history.deletedReviewIDs() == [record.started.id])
        #expect(store.job(id: record.started.id) == nil)
        #expect(store.workspaces.isEmpty)
        #expect(uiState.selectedJobEntry == nil)
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

    @Test func historyFailureHasIndependentStatusPresentation() {
        let presentation = ReviewMonitorHistoryStatusPresentation(
            failureMessage: "database is unavailable"
        )

        #expect(presentation?.title == "History unavailable")
        #expect(presentation?.detail == "database is unavailable")
        #expect(ReviewMonitorHistoryStatusPresentation(failureMessage: nil) == nil)
    }

    private func restoredRecord(id: String) throws -> RestoredReviewRecord {
        let started = try StartedReviewRecord(
            id: id,
            cwd: "/tmp/workspace",
            workspaceSortOrder: 0,
            sortOrder: 0,
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
    private var deletedIDs: [String] = []

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

    func deleteTerminalReview(
        id: String
    ) async throws -> ReviewHistoryMutationResult {
        deletedIDs.append(id)
        return .init(removedReviewIDs: [id])
    }

    func deleteAllTerminalReviews() async throws -> ReviewHistoryMutationResult {
        .init()
    }

    func close() async throws {}

    func deletedReviewIDs() -> [String] {
        deletedIDs
    }
}
