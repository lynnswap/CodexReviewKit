import AppKit
import Testing
@_spi(Testing) @testable import CodexReview
@testable import ReviewUI

@Suite(.serialized)
@MainActor
struct ReviewMonitorCopyTests {
    @Test func copySubmenuUsesClickedReviewAndCurrentMarkdownWithoutChangingSelection() throws {
        let selected = CodexReviewJob.makeForTesting(
            id: "selected", cwd: "/tmp/selected", targetSummary: "Selected review",
            status: .running, summary: "Running"
        )
        let clicked = CodexReviewJob(
            id: "clicked", sessionID: "session", cwd: "/tmp/日本語 workspace", targetSummary: "Clicked review",
            core: .init(
                run: .init(reviewThreadID: "review-thread", threadID: "parent-thread"),
                lifecycle: .init(status: .running),
                output: .init(summary: "Running")
            ),
            logEntries: [.init(kind: .agentMessage, groupID: "message", text: "## Review\n\n**Original**")]
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [CodexReviewWorkspace(cwd: selected.cwd), CodexReviewWorkspace(cwd: clicked.cwd)],
            jobs: [selected, clicked]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let sidebar = ReviewMonitorSidebarViewController(store: store, uiState: uiState)
        let window = NSWindow(contentViewController: sidebar)
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        sidebar.loadViewIfNeeded()
        sidebar.selectJobForTesting(selected)

        var copyItem: NSMenuItem?
        sidebar.presentContextMenuForTesting(for: clicked) { menu in
            copyItem = menu.item(withTitle: "Copy")
        }
        let item = try #require(copyItem)
        let submenu = try #require(item.submenu)
        #expect(item.image == nil)
        #expect(submenu.items.map(\.title) == [
            "Copy Working Directory", "Copy Deep Link", "Copy as Markdown",
        ])
        #expect(submenu.items.allSatisfy { $0.image == nil && $0.isEnabled })

        clicked.appendLogEntry(.init(
            kind: .agentMessage, groupID: "message", replacesGroup: true,
            text: "## Review\n\n**Updated** with `code`\n\n```swift\nlet value = 1\n```"
        ))
        clicked.appendLogEntry(.init(kind: .diagnostic, text: "Private diagnostic", audience: .developer))

        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { item in
            let saved = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { saved.setData(data, forType: type) }
            }
            return saved
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems)
        }
        let expected = [
            clicked.cwd,
            "codex://threads/review-thread",
            "## Review\n\n**Updated** with `code`\n\n```swift\nlet value = 1\n```",
        ]
        for (actionItem, text) in zip(submenu.items, expected) {
            let action = try #require(actionItem.action)
            #expect(NSApp.sendAction(action, to: actionItem.target, from: actionItem))
            #expect(pasteboard.string(forType: .string) == text)
            #expect(uiState.selectedJobEntry?.id == selected.id)
        }
    }

    @Test(arguments: [nil, "parent-thread"] as [String?])
    func deepLinkAvailabilityUsesTheThreadWhenNoSeparateReviewThreadExists(threadID: String?) throws {
        let job = CodexReviewJob(
            id: "job", sessionID: "session", cwd: "/tmp/repo", targetSummary: "Review",
            core: .init(
                run: .init(threadID: threadID),
                lifecycle: .init(status: .running),
                output: .init(summary: "Running")
            ),
            logEntries: []
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running, workspaces: [CodexReviewWorkspace(cwd: job.cwd)], jobs: [job]
        )
        let sidebar = ReviewMonitorSidebarViewController(store: store, uiState: .init(auth: store.auth))
        let window = NSWindow(contentViewController: sidebar)
        defer { window.close() }
        sidebar.loadViewIfNeeded()
        var copyMenu: NSMenu?
        sidebar.presentContextMenuForTesting(for: job) { menu in
            copyMenu = menu.item(withTitle: "Copy")?.submenu
        }
        let menu = try #require(copyMenu)
        #expect(menu.item(withTitle: "Copy Deep Link")?.isEnabled == (threadID != nil))
        #expect(menu.item(withTitle: "Copy Working Directory")?.isEnabled == true)
        #expect(menu.item(withTitle: "Copy as Markdown")?.isEnabled == true)
    }
}
