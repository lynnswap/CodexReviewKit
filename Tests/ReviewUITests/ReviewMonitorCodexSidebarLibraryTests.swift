import AppKit
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

        try await runtime.transport.enqueueThreadList(
            .init(
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
        let appWorkspace = try #require(section.workspaces.first)
        let appChat = try #require(section.chats(in: appWorkspace.id).first)
        let resolvedAppPath = app.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedToolsPath = tools.standardizedFileURL.resolvingSymlinksInPath().path

        #expect(library.sections.count == 1)
        #expect(section.displayTitle == repo.lastPathComponent)
        #expect(section.workspaces.map(\.url.path) == [resolvedAppPath, resolvedToolsPath])
        #expect(section.workspaces.map(\.name) == ["App", "Tools"])
        #expect(section.chats.map(\.title) == ["App chat", "Tools chat"])
        #expect(appChat === library.chat(id: CodexThreadID(rawValue: "thread-app")))
        #expect(appChat.workspace?.url.path == resolvedAppPath)

        let tree = ReviewMonitorCodexSidebarOutlineTree()
        #expect(tree.apply(sections: library.sections).topologyChanged)
        let outlineSection = try #require(tree.roots.first)
        let outlineAppWorkspace = try #require(tree.node(rowID: .workspace(appWorkspace.id)))
        let outlineAppChat = try #require(tree.node(rowID: .chat(appChat.id)))

        #expect(outlineSection.rowID == section.rowID)
        #expect(outlineSection.title == section.displayTitle)
        #expect(outlineSection.selectionID == .workspaceGroup(section.workspaceGroupID))
        #expect(outlineSection.isExpandable)
        #expect(
            outlineSection.children.map(\.rowID.rawValue) == [
                "workspace:\(resolvedAppPath)",
                "workspace:\(resolvedToolsPath)",
            ])
        #expect(outlineAppWorkspace.title == "App")
        #expect(outlineAppWorkspace.selectionID == .workspace(appWorkspace.id))
        #expect(outlineAppWorkspace.isExpandable)
        #expect(outlineAppWorkspace.children.map(\.rowID.rawValue) == ["chat:thread-app"])
        #expect(outlineAppChat.selectionID == .chat(appChat.id))
        #expect(
            library.sections.rowIDs.map(\.rawValue) == [
                "workspaceGroup:\(section.workspaceGroupID.rawValue)",
                "workspace:\(resolvedAppPath)",
                "chat:thread-app",
                "workspace:\(resolvedToolsPath)",
                "chat:thread-tools",
            ])
    }

    @Test func filteringAndPresentationOrderPreserveCodexWorkspaceSource() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let runningThreadID = CodexThreadID(rawValue: "thread-running")
        let idleThreadID = CodexThreadID(rawValue: "thread-idle")

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [
                    .init(
                        id: runningThreadID,
                        workspace: repo,
                        name: "Running review",
                        updatedAt: Date(timeIntervalSince1970: 3_000),
                        status: .active(activeFlags: [])
                    ),
                    .init(
                        id: idleThreadID,
                        workspace: repo,
                        name: "Idle review",
                        updatedAt: Date(timeIntervalSince1970: 2_000),
                        status: .idle
                    ),
                ]
            ))

        let library = ReviewMonitorCodexSidebarLibrary(modelContext: context)
        try await library.performFetch()
        let sections = library.sections
        let originalWorkspace = try #require(sections.first?.workspaces.first)

        let filteredWorkspace = try #require(sections.filtered(by: .running).first?.workspaces.first)
        #expect(filteredWorkspace === originalWorkspace)
        #expect(sections.filtered(by: .running).first?.chats(in: originalWorkspace.id).map(\.id) == [runningThreadID])

        var order = ReviewMonitorCodexSidebarPresentationOrder()
        _ = order.reorderChat(
            id: idleThreadID,
            in: sections[0].rowID,
            currentOrder: [runningThreadID, idleThreadID],
            before: runningThreadID
        )
        let orderedWorkspace = try #require(order.applying(to: sections).first?.workspaces.first)
        #expect(orderedWorkspace === originalWorkspace)
        #expect(order.applying(to: sections).first?.chats(in: originalWorkspace.id).map(\.id) == [
            idleThreadID,
            runningThreadID,
        ])
    }

    @Test func defaultDescriptorFetchesReviewThreadsOnly() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: []))

        let library = ReviewMonitorCodexSidebarLibrary(modelContext: context)
        try await library.performFetch()

        let request = try #require(await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try request.decodeParams(ThreadListParams.self)
        #expect(params.sourceKinds == ["subAgentReview"])
    }

    @Test func sidebarIncludesUncategorizedChatsWithStableRowIDs() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [
                    .init(
                        id: "thread-uncategorized",
                        name: "Floating review",
                        preview: "Uncategorized preview",
                        updatedAt: Date(timeIntervalSince1970: 4_000)
                    )
                ]
            ))

        let library = ReviewMonitorCodexSidebarLibrary(modelContext: context)
        try await library.performFetch()

        let section = try #require(library.sections.first)
        let chat = try #require(section.uncategorizedChats.first)

        #expect(section.workspaces.isEmpty)
        #expect(chat.id == CodexThreadID(rawValue: "thread-uncategorized"))
        #expect(chat.title == "Floating review")
        #expect(chat.preview == "Uncategorized preview")
        #expect(chat.workspace == nil)
        #expect(
            section.rowIDs.map(\.rawValue) == [
                section.rowID.rawValue,
                "chat:thread-uncategorized",
            ])

        let tree = ReviewMonitorCodexSidebarOutlineTree()
        #expect(tree.apply(sections: library.sections).topologyChanged)
        let outlineSection = try #require(tree.roots.first)
        let outlineChat = try #require(tree.node(rowID: .chat(chat.id)))
        #expect(outlineSection.children.map(\.rowID.rawValue) == ["chat:thread-uncategorized"])
        #expect(outlineChat.selectionID == .chat(chat.id))
        #expect(outlineChat.isExpandable == false)
    }

    @Test func sidebarOutlineTreePreservesNodeIdentityAcrossSectionUpdates() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let threadID = CodexThreadID(rawValue: "thread-app")

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [
                    .init(
                        id: threadID,
                        workspace: repo,
                        name: "Initial review",
                        updatedAt: Date(timeIntervalSince1970: 1_000)
                    )
                ]
            ))

        let library = ReviewMonitorCodexSidebarLibrary(modelContext: context)
        try await library.performFetch()
        let section = try #require(library.sections.first)
        let tree = ReviewMonitorCodexSidebarOutlineTree()

        #expect(tree.apply(sections: library.sections).topologyChanged)
        let root = try #require(tree.roots.first)
        let chatNode = try #require(tree.node(rowID: .chat(threadID)))

        try await runtime.transport.enqueueThreadResume(.init(id: threadID))
        try await runtime.transport.enqueueThreadRead(
            .init(
                id: threadID,
                workspace: repo,
                name: "Updated review",
                updatedAt: Date(timeIntervalSince1970: 2_000)
            ))
        try await context.model(for: threadID).refresh(includeTurns: false)

        #expect(tree.apply(sections: library.sections).topologyChanged == false)
        #expect(tree.roots.first === root)
        #expect(tree.node(rowID: .chat(threadID)) === chatNode)
        #expect(chatNode.title == "Updated review")
        #expect(root.children.map(\.rowID) == [.chat(threadID)])
        #expect(root.children.first === chatNode)
    }

    @Test func sidebarRunningFilterUsesThreadStatus() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let runningThreadID = CodexThreadID(rawValue: "thread-running")
        let idleThreadID = CodexThreadID(rawValue: "thread-idle")

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [
                    .init(
                        id: runningThreadID,
                        workspace: repo,
                        name: "Running review",
                        updatedAt: Date(timeIntervalSince1970: 20),
                        status: .active(activeFlags: [])
                    ),
                    .init(
                        id: idleThreadID,
                        workspace: repo,
                        name: "Idle review",
                        updatedAt: Date(timeIntervalSince1970: 30),
                        status: .idle
                    ),
                ]
            ))

        let library = ReviewMonitorCodexSidebarLibrary(modelContext: context)
        try await library.performFetch()
        let section = try #require(library.sections.filtered(by: .running).first)
        let workspace = try #require(section.workspaces.first)

        #expect(section.chats(in: workspace.id).map(\.id) == [runningThreadID])
        #expect(section.chats(in: workspace.id).contains { $0.id == idleThreadID } == false)
    }

    @Test func sidebarViewControllerInstallsCodexSidebarLibraryFromModelContext() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let threadID = CodexThreadID(rawValue: "thread-app")

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [
                    .init(
                        id: threadID,
                        workspace: repo,
                        name: "App review",
                        updatedAt: Date(timeIntervalSince1970: 5_000)
                    )
                ]
            ))

        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running)
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let viewController = ReviewMonitorSplitViewController(
            store: store,
            uiState: uiState,
            modelContext: context
        )
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        try await waitForCondition {
            sidebar.codexSidebarSectionsForTesting.first?.chat(id: threadID)?.title == "App review"
        }
        try await waitForCondition {
            sidebar.codexSidebarRootTitlesForTesting == [repo.lastPathComponent]
                && sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(threadID)) == "App review"
        }
        #expect(
            sidebar.displayedCodexSidebarTitlesForTesting == [
                repo.lastPathComponent,
                "App review",
            ])
        let workspace = try #require(sidebar.codexSidebarSectionsForTesting.first?.workspaces.first)
        #expect(sidebar.codexSidebarNodeTitleForTesting(rowID: .workspace(workspace.id)) == nil)
        #expect(sidebar.workspaceRowHeightForTesting(cwd: repo.path) == sidebar.expectedWorkspaceRowRectHeightForTesting)
        #expect(sidebar.reviewChatRowHeightForTesting(threadID) == sidebar.expectedReviewChatRowRectHeightForTesting)

        sidebar.selectCodexSidebarRowForTesting(rowID: .chat(threadID))
        guard case .chat(let selectedChatID) = uiState.selection else {
            Issue.record("Expected selecting a Codex sidebar chat row to select the chat.")
            return
        }
        #expect(selectedChatID == threadID)
        #expect(sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(threadID)) == "App review")
    }

    @Test func codexSidebarSelectionDoesNotFallBackToReviewRunRows() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let visibleThreadID = CodexThreadID(rawValue: "thread-app")
        let hiddenRunThreadID = CodexThreadID(rawValue: "run-backed-review-thread")

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [
                    .init(
                        id: visibleThreadID,
                        workspace: repo,
                        name: "App review",
                        updatedAt: Date(timeIntervalSince1970: 5_000)
                    )
                ]
            ))

        let runBackedRecord = ReviewRunRecord.makeForTesting(
            id: "run-backed-record",
            cwd: repo.path,
            targetSummary: "Run-backed review row",
            threadID: hiddenRunThreadID.rawValue,
            turnID: "run-backed-turn",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 4_000),
            summary: "Running review."
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadReviewCancellationStateForTesting(
            serverState: .running,
            reviewRuns: [runBackedRecord]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let viewController = ReviewMonitorSplitViewController(
            store: store,
            uiState: uiState,
            modelContext: context
        )
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        try await waitForCondition {
            sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(visibleThreadID)) == "App review"
        }
        #expect(sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(hiddenRunThreadID)) == nil)

        uiState.selection = .chat(hiddenRunThreadID)

        try await waitForCondition {
            uiState.selection == nil && sidebar.selectedReviewChatIDForTesting == nil
        }
    }

    @Test func sidebarViewControllerTracksCodexSidebarFetchResultChanges() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let threadID = CodexThreadID(rawValue: "thread-app")

        try await runtime.transport.enqueueThreadList(.init(threads: []))

        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running)
        let viewController = ReviewMonitorSplitViewController(
            store: store,
            uiState: ReviewMonitorUIState(auth: store.auth),
            modelContext: context
        )
        viewController.loadViewIfNeeded()
        let sidebar = viewController.sidebarViewControllerForTesting

        try await waitForCondition {
            sidebar.isShowingEmptyStateForTesting
        }

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [
                    .init(
                        id: threadID,
                        workspace: repo,
                        name: "App review",
                        updatedAt: Date(timeIntervalSince1970: 5_000)
                    )
                ]
            ))
        try await sidebar.refreshCodexSidebarForTesting()

        try await waitForCondition {
            sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(threadID)) == "App review"
        }
    }

    @Test func sidebarViewControllerPreservesSelectionAndAvoidsFullReloadWhenCodexChatContentChanges() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let threadID = CodexThreadID(rawValue: "thread-app")

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [
                    .init(
                        id: threadID,
                        workspace: repo,
                        name: "App review",
                        updatedAt: Date(timeIntervalSince1970: 5_000)
                    )
                ]
            ))

        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running)
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let viewController = ReviewMonitorSplitViewController(
            store: store,
            uiState: uiState,
            modelContext: context
        )
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        try await waitForCondition(timeout: .milliseconds(500)) {
            sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(threadID)) == "App review"
        }
        try await runtime.transport.enqueueThreadResume(
            .init(
                id: threadID,
                workspace: repo,
                name: "App review",
                updatedAt: Date(timeIntervalSince1970: 5_000)
            ))
        try await runtime.transport.enqueueThreadRead(
            .init(
                id: threadID,
                workspace: repo,
                name: "App review",
                updatedAt: Date(timeIntervalSince1970: 5_000)
            ))
        sidebar.selectCodexSidebarRowForTesting(rowID: .chat(threadID))
        #expect(uiState.selectionID == .chat(threadID))
        try await waitForCondition {
            window.title == "App review"
        }
        let fullReloadCountBeforeContentUpdate = sidebar.sidebarFullReloadCountForTesting
        let chat = context.model(for: threadID)
        let chatIdentityBeforeContentUpdate = ObjectIdentifier(chat)
        try await runtime.transport.enqueueThreadResume(.init(id: threadID))
        try await runtime.transport.enqueueThreadRead(
            .init(
                id: threadID,
                workspace: repo,
                name: "App review renamed",
                updatedAt: Date(timeIntervalSince1970: 6_000)
            ))
        try await chat.refresh(includeTurns: false)

        try await waitForCondition {
            sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(threadID)) == "App review renamed"
        }
        #expect(uiState.selectionID == .chat(threadID))
        try await waitForCondition {
            window.title == "App review renamed"
        }
        #expect(ObjectIdentifier(context.model(for: threadID)) == chatIdentityBeforeContentUpdate)
        #expect(sidebar.sidebarFullReloadCountForTesting == fullReloadCountBeforeContentUpdate)
        #expect(
            sidebar.displayedCodexSidebarTitlesForTesting == [
                repo.lastPathComponent,
                "App review renamed",
            ])
    }

    @Test func sidebarViewControllerReordersCodexWorkspaceGroupsLocally() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstRepo = try makeGitRepository()
        let secondRepo = try makeGitRepository()

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [
                    .init(
                        id: "thread-first-repo",
                        workspace: firstRepo,
                        name: "First repo review",
                        updatedAt: Date(timeIntervalSince1970: 5_000)
                    ),
                    .init(
                        id: "thread-second-repo",
                        workspace: secondRepo,
                        name: "Second repo review",
                        updatedAt: Date(timeIntervalSince1970: 4_000)
                    ),
                ]
            ))

        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running)
        let viewController = ReviewMonitorSplitViewController(
            store: store,
            uiState: ReviewMonitorUIState(auth: store.auth),
            modelContext: context
        )
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        try await waitForCondition {
            sidebar.codexSidebarRootTitlesForTesting == [
                firstRepo.lastPathComponent,
                secondRepo.lastPathComponent,
            ]
        }
        let sections = sidebar.codexSidebarSectionsForTesting
        let firstSection = try #require(sections.first)
        let secondSection = try #require(sections.dropFirst().first)
        let fullReloadCountBeforeReorder = sidebar.sidebarFullReloadCountForTesting

        #expect(sidebar.codexSidebarCanStartDragForTesting(rowID: secondSection.rowID))
        #expect(sidebar.performCodexWorkspaceGroupDropForTesting(id: secondSection.workspaceGroupID, toIndex: 0))
        #expect(
            sidebar.codexSidebarRootTitlesForTesting == [
                secondSection.displayTitle,
                firstSection.displayTitle,
            ])
        #expect(
            sidebar.codexSidebarSectionsForTesting.map(\.workspaceGroupID) == [
                firstSection.workspaceGroupID,
                secondSection.workspaceGroupID,
            ])
        #expect(sidebar.sidebarFullReloadCountForTesting == fullReloadCountBeforeReorder)
    }

    @Test func sidebarViewControllerReordersCodexChatsLocallyWithinContainer() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let firstThreadID = CodexThreadID(rawValue: "thread-first")
        let secondThreadID = CodexThreadID(rawValue: "thread-second")

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [
                    .init(
                        id: firstThreadID,
                        workspace: repo,
                        name: "First review",
                        updatedAt: Date(timeIntervalSince1970: 5_000)
                    ),
                    .init(
                        id: secondThreadID,
                        workspace: repo,
                        name: "Second review",
                        updatedAt: Date(timeIntervalSince1970: 4_000)
                    ),
                ]
            ))

        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running)
        let viewController = ReviewMonitorSplitViewController(
            store: store,
            uiState: ReviewMonitorUIState(auth: store.auth),
            modelContext: context
        )
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        try await waitForCondition {
            sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(secondThreadID)) == "Second review"
        }
        let section = try #require(sidebar.codexSidebarSectionsForTesting.first)
        let workspace = try #require(section.workspaces.first)
        let container = section.rowID
        let fullReloadCountBeforeReorder = sidebar.sidebarFullReloadCountForTesting

        #expect(sidebar.displayedCodexChatIDsForTesting(container: container) == [firstThreadID, secondThreadID])
        #expect(sidebar.codexSidebarCanStartDragForTesting(rowID: .chat(secondThreadID)))
        #expect(sidebar.performCodexChatDropForTesting(id: secondThreadID, container: container, childIndex: 0))
        #expect(sidebar.displayedCodexChatIDsForTesting(container: container) == [secondThreadID, firstThreadID])
        #expect(section.chats(in: workspace.id).map(\.id) == [firstThreadID, secondThreadID])
        #expect(sidebar.sidebarFullReloadCountForTesting == fullReloadCountBeforeReorder)
    }

    @Test func sidebarViewControllerDoesNotReloadCodexOutlineWhenSelectionChanges() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let firstThreadID = CodexThreadID(rawValue: "thread-first")
        let secondThreadID = CodexThreadID(rawValue: "thread-second")

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [
                    .init(
                        id: firstThreadID,
                        workspace: repo,
                        name: "First review",
                        updatedAt: Date(timeIntervalSince1970: 5_000)
                    ),
                    .init(
                        id: secondThreadID,
                        workspace: repo,
                        name: "Second review",
                        updatedAt: Date(timeIntervalSince1970: 4_000)
                    ),
                ]
            ))

        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running)
        let viewController = ReviewMonitorSplitViewController(
            store: store,
            uiState: ReviewMonitorUIState(auth: store.auth),
            modelContext: context
        )
        viewController.loadViewIfNeeded()
        let sidebar = viewController.sidebarViewControllerForTesting

        try await waitForCondition {
            sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(firstThreadID)) == "First review"
                && sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(secondThreadID)) == "Second review"
        }
        let reloadCountAfterInitialFetch = sidebar.sidebarFullReloadCountForTesting

        sidebar.selectCodexSidebarRowForTesting(rowID: .chat(firstThreadID))
        try await waitForCondition {
            sidebar.selectedReviewChatIDForTesting == firstThreadID
        }
        sidebar.selectCodexSidebarRowForTesting(rowID: .chat(secondThreadID))
        try await waitForCondition {
            sidebar.selectedReviewChatIDForTesting == secondThreadID
        }

        #expect(sidebar.sidebarFullReloadCountForTesting == reloadCountAfterInitialFetch)
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
