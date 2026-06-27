import CodexKit
import CodexAppServerKitTesting
import Foundation
import Testing
@_spi(Testing) @testable import CodexReviewKit
@_spi(PreviewSupport) @testable import ReviewUI

@Suite("ReviewMonitor Codex sidebar library")
@MainActor
struct ReviewMonitorCodexSidebarLibraryTests {
    @Test func buildsSidebarSectionsFromCodexDataKitFetchResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let app = try makeDirectory("App", in: repo)
        let tools = try makeDirectory("Tools", in: repo)

        try await runtime.transport.enqueueThreadList(.init(
            threads: [
                .init(
                    id: "thread-app",
                    workspace: app,
                    name: "App chat",
                    updatedAt: Date(timeIntervalSince1970: 3_000)
                ),
                .init(
                    id: "thread-tools",
                    workspace: tools,
                    name: "Tools chat",
                    updatedAt: Date(timeIntervalSince1970: 2_000)
                ),
            ]
        ))

        let library = ReviewMonitorCodexSidebarLibrary(modelContext: context)
        try await library.performFetch()

        let section = try #require(library.sections.first)
        let snapshotSection = try #require(library.snapshot.sections.first)
        let appWorkspace = try #require(section.workspaces.first)
        let appChat = try #require(appWorkspace.chats.first)
        let snapshotAppWorkspace = try #require(snapshotSection.workspaces.first)
        let snapshotAppChat = try #require(snapshotAppWorkspace.chats.first)
        let resolvedAppPath = app.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedToolsPath = tools.standardizedFileURL.resolvingSymlinksInPath().path

        #expect(library.sections.count == 1)
        #expect(section.title == repo.lastPathComponent)
        #expect(section.selection.workspaceCWDs == [resolvedAppPath, resolvedToolsPath])
        #expect(section.workspaces.map(\.title) == ["App", "Tools"])
        #expect(section.chats.map(\.title) == ["App chat", "Tools chat"])
        #expect(appChat === library.chat(id: CodexThreadID(rawValue: "thread-app")))
        #expect(snapshotSection.selection.workspaceCWDs == [resolvedAppPath, resolvedToolsPath])
        #expect(snapshotAppWorkspace.cwd == resolvedAppPath)
        #expect(snapshotAppChat.id == CodexThreadID(rawValue: "thread-app"))
        #expect(snapshotAppChat.title == "App chat")
        #expect(snapshotAppChat.workspaceCWD == resolvedAppPath)
        #expect(library.snapshot.chat(id: CodexThreadID(rawValue: "thread-app")) == snapshotAppChat)
        let outlineSection = try #require(library.snapshot.outlineItems.first)
        let outlineAppWorkspace = try #require(outlineSection.children.first)
        #expect(outlineSection.rowID == snapshotSection.rowID)
        #expect(outlineSection.title == section.title)
        #expect(outlineSection.selectionID == .workspaceSection(section.id))
        #expect(outlineSection.isExpandable)
        #expect(outlineSection.children.map(\.rowID.rawValue) == [
            "workspace:\(resolvedAppPath)",
            "workspace:\(resolvedToolsPath)",
        ])
        #expect(outlineAppWorkspace.rowID == snapshotAppWorkspace.rowID)
        #expect(outlineAppWorkspace.title == "App")
        #expect(outlineAppWorkspace.selectionID == .workspace(snapshotAppWorkspace.id))
        #expect(outlineAppWorkspace.isExpandable)
        let outlineAppChat = try #require(outlineAppWorkspace.children.first)
        #expect(outlineAppChat.selectionID == .chat(snapshotAppChat.id))
        #expect(outlineAppWorkspace.children.map(\.rowID.rawValue) == ["chat:thread-app"])
        #expect(library.snapshot.outlineItem(rowID: .chat(CodexThreadID(rawValue: "thread-app"))) == .chat(snapshotAppChat))
        #expect(library.snapshot.rowIDs.map(\.rawValue) == [
            "section:\(section.id)",
            "workspace:\(resolvedAppPath)",
            "chat:thread-app",
            "workspace:\(resolvedToolsPath)",
            "chat:thread-tools",
        ])
    }

    @Test func defaultRequestFetchesReviewThreadsOnly() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: []))

        let library = ReviewMonitorCodexSidebarLibrary(modelContext: context)
        try await library.performFetch()

        let request = try #require(await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try request.decodeParams(ThreadListParams.self)
        #expect(params.sourceKinds == ["subAgentReview"])
    }

    @Test func sidebarSnapshotIncludesUncategorizedChatsWithStableRowIDs() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(
            threads: [
                .init(
                    id: "thread-uncategorized",
                    name: "Floating review",
                    preview: "Uncategorized preview",
                    updatedAt: Date(timeIntervalSince1970: 4_000)
                ),
            ]
        ))

        let library = ReviewMonitorCodexSidebarLibrary(modelContext: context)
        try await library.performFetch()

        let section = try #require(library.snapshot.sections.first)
        let chat = try #require(section.uncategorizedChats.first)

        #expect(section.workspaces.isEmpty)
        #expect(chat.id == CodexThreadID(rawValue: "thread-uncategorized"))
        #expect(chat.rowID.rawValue == "chat:thread-uncategorized")
        #expect(chat.title == "Floating review")
        #expect(chat.preview == "Uncategorized preview")
        #expect(chat.workspaceCWD == nil)
        let outlineSection = try #require(library.snapshot.outlineItems.first)
        let outlineChat = try #require(outlineSection.children.first)
        #expect(outlineSection.children.map(\.rowID.rawValue) == ["chat:thread-uncategorized"])
        #expect(outlineChat == .chat(chat))
        #expect(outlineChat.selectionID == .chat(chat.id))
        #expect(outlineChat.isExpandable == false)
        #expect(library.snapshot.outlineItem(rowID: chat.rowID) == .chat(chat))
        #expect(section.rowIDs.map(\.rawValue) == [
            section.rowID.rawValue,
            "chat:thread-uncategorized",
        ])
    }

    @Test func sidebarViewControllerInstallsCodexSidebarLibraryFromModelContext() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(
            threads: [
                .init(
                    id: "thread-app",
                    workspace: try makeGitRepository(),
                    name: "App review",
                    updatedAt: Date(timeIntervalSince1970: 5_000)
                ),
            ]
        ))

        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running, workspaces: [])
        let viewController = ReviewMonitorSplitViewController(
            store: store,
            uiState: ReviewMonitorUIState(auth: store.auth),
            modelContext: context
        )
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        try await waitForCondition {
            sidebar.codexSidebarSnapshotForTesting?
                .chat(id: CodexThreadID(rawValue: "thread-app"))?
                .title == "App review"
        }
    }
}

private struct ThreadListParams: Decodable {
    var sourceKinds: [String]?
}

private func makeDirectory(_ name: String, in parent: URL) throws -> URL {
    let url = parent.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeGitRepository() throws -> URL {
    let repo = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
    return repo
}
