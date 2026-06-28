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
        #expect(
            outlineSection.children.map(\.rowID.rawValue) == [
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
        #expect(
            library.snapshot.outlineItem(rowID: .chat(CodexThreadID(rawValue: "thread-app"))) == .chat(snapshotAppChat))
        #expect(
            library.snapshot.rowIDs.map(\.rawValue) == [
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
        #expect(
            section.rowIDs.map(\.rawValue) == [
                section.rowID.rawValue,
                "chat:thread-uncategorized",
            ])
    }

    @Test func sidebarOutlineTreePreservesNodeIdentityAcrossSnapshots() throws {
        let workspaceID = CodexWorkspaceID(rawValue: "/tmp/App")
        let threadID = CodexThreadID(rawValue: "thread-app")
        let tree = ReviewMonitorCodexSidebarOutlineTree()

        #expect(
            tree.apply(
                snapshot: sidebarSnapshot(
                    workspaceID: workspaceID,
                    threadID: threadID,
                    chatTitle: "Initial review",
                    includesChat: true
                )
            ).topologyChanged)

        let root = try #require(tree.roots.first)
        let workspace = try #require(tree.node(rowID: .workspace(workspaceID)))
        let chat = try #require(tree.node(rowID: .chat(threadID)))

        #expect(
            tree.apply(
                snapshot: sidebarSnapshot(
                    workspaceID: workspaceID,
                    threadID: threadID,
                    chatTitle: "Updated review",
                    includesChat: true
                )
            ).topologyChanged == false)

        let updatedRoot = try #require(tree.roots.first)
        let updatedWorkspace = try #require(tree.node(rowID: .workspace(workspaceID)))
        let updatedChat = try #require(tree.node(rowID: .chat(threadID)))
        #expect(updatedRoot === root)
        #expect(updatedWorkspace === workspace)
        #expect(updatedChat === chat)
        #expect(chat.title == "Updated review")
        #expect(root.children.first === workspace)
        #expect(workspace.children.first === chat)

        #expect(
            tree.apply(
                snapshot: sidebarSnapshot(
                    workspaceID: workspaceID,
                    threadID: threadID,
                    chatTitle: "Removed review",
                    includesChat: false
                )
            ).topologyChanged)

        #expect(tree.node(rowID: .chat(threadID)) == nil)
        #expect(workspace.children.isEmpty)
    }

    @Test func sidebarSnapshotRunningFilterUsesThreadStatus() throws {
        let workspaceID = CodexWorkspaceID(rawValue: "/tmp/App")
        let runningThreadID = CodexThreadID(rawValue: "thread-running")
        let idleThreadID = CodexThreadID(rawValue: "thread-idle")
        let snapshot = sidebarSnapshot(
            workspaceID: workspaceID,
            chats: [
                sidebarChat(
                    id: runningThreadID,
                    title: "Running review",
                    workspaceID: workspaceID,
                    updatedAt: Date(timeIntervalSince1970: 20),
                    status: .active(activeFlags: [])
                ),
                sidebarChat(
                    id: idleThreadID,
                    title: "Idle review",
                    workspaceID: workspaceID,
                    updatedAt: Date(timeIntervalSince1970: 30),
                    status: .idle
                ),
            ]
        )

        let filtered = snapshot.filtered(by: .running)
        let workspace = try #require(filtered.sections.first?.workspaces.first)
        #expect(workspace.chats.map(\.id) == [runningThreadID])
        #expect(filtered.chat(id: idleThreadID) == nil)
    }

    @Test func sidebarSnapshotLatestFinishedFilterUsesSectionActivityDate() throws {
        let workspaceID = CodexWorkspaceID(rawValue: "/tmp/App")
        let olderFinishedID = CodexThreadID(rawValue: "thread-older-finished")
        let newerFinishedID = CodexThreadID(rawValue: "thread-newer-finished")
        let runningThreadID = CodexThreadID(rawValue: "thread-running")
        let snapshot = sidebarSnapshot(
            workspaceID: workspaceID,
            chats: [
                sidebarChat(
                    id: olderFinishedID,
                    title: "Older finished",
                    workspaceID: workspaceID,
                    updatedAt: Date(timeIntervalSince1970: 100),
                    status: .idle
                ),
                sidebarChat(
                    id: newerFinishedID,
                    title: "Newer finished",
                    workspaceID: workspaceID,
                    updatedAt: Date(timeIntervalSince1970: 300),
                    status: .idle
                ),
                sidebarChat(
                    id: runningThreadID,
                    title: "Running review",
                    workspaceID: workspaceID,
                    updatedAt: Date(timeIntervalSince1970: 400),
                    status: .active(activeFlags: [])
                ),
            ]
        )

        let latestFinished = snapshot.filtered(by: .latestFinished)
        let combined: SidebarReviewChatFilter = [.running, .latestFinished]
        let combinedFiltered = snapshot.filtered(by: combined)

        #expect(latestFinished.sections.first?.workspaces.first?.chats.map(\.id) == [newerFinishedID])
        #expect(
            combinedFiltered.sections.first?.workspaces.first?.chats.map(\.id) == [
                newerFinishedID,
                runningThreadID,
            ])
    }

    @Test func sidebarPresentationOrderReordersSectionsAndChatsLocally() throws {
        let alphaWorkspaceID = CodexWorkspaceID(rawValue: "/tmp/Alpha")
        let betaWorkspaceID = CodexWorkspaceID(rawValue: "/tmp/Beta")
        let alphaFirstID = CodexThreadID(rawValue: "thread-alpha-first")
        let alphaSecondID = CodexThreadID(rawValue: "thread-alpha-second")
        let betaThreadID = CodexThreadID(rawValue: "thread-beta")
        let alpha = sidebarSection(
            id: "alpha",
            title: "Alpha",
            workspaceID: alphaWorkspaceID,
            chats: [
                sidebarChat(id: alphaFirstID, title: "Alpha first", workspaceID: alphaWorkspaceID),
                sidebarChat(id: alphaSecondID, title: "Alpha second", workspaceID: alphaWorkspaceID),
            ]
        )
        let beta = sidebarSection(
            id: "beta",
            title: "Beta",
            workspaceID: betaWorkspaceID,
            chats: [
                sidebarChat(id: betaThreadID, title: "Beta", workspaceID: betaWorkspaceID)
            ]
        )
        var order = ReviewMonitorCodexSidebarPresentationOrder()

        let didReorderSection = order.reorderSection(id: "beta", before: "alpha")
        let didReorderChat = order.reorderChat(
            id: alphaSecondID,
            in: .workspace(alphaWorkspaceID),
            currentOrder: [alphaFirstID, alphaSecondID],
            before: alphaFirstID
        )

        #expect(didReorderSection)
        #expect(didReorderChat)

        let ordered = order.applying(to: ReviewMonitorCodexSidebarSnapshot(sections: [alpha, beta]))

        #expect(ordered.sections.map(\.id) == ["beta", "alpha"])
        #expect(
            ordered.sections[1].workspaces.first?.chats.map(\.id) == [
                alphaSecondID,
                alphaFirstID,
            ])
        #expect(ordered.sections[0].workspaces.first?.chats.map(\.id) == [betaThreadID])
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
        store.loadForTesting(
            serverState: .running,
            workspaces: [CodexReviewWorkspace(cwd: "/tmp/review-job-store")]
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
            sidebar.codexSidebarSnapshotForTesting?
                .chat(id: threadID)?
                .title == "App review"
        }
        try await waitForCondition {
            sidebar.codexSidebarRootTitlesForTesting == [repo.lastPathComponent]
                && sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(threadID)) == "App review"
        }
        #expect(
            sidebar.displayedCodexSidebarTitlesForTesting == [
                repo.lastPathComponent,
                repo.lastPathComponent,
                "App review",
            ])
        #expect(sidebar.codexSidebarChatRowUsesReviewMonitorChatRowViewForTesting(threadID))

        sidebar.selectCodexSidebarRowForTesting(rowID: .chat(threadID))
        guard case .chat(let selectedChat) = uiState.selection else {
            Issue.record("Expected selecting a Codex sidebar chat row to select the chat.")
            return
        }
        #expect(selectedChat.id == threadID)
        #expect(selectedChat.title == "App review")
    }

    @Test func codexSidebarSelectionDoesNotFallBackToReviewJobRows() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let visibleThreadID = CodexThreadID(rawValue: "thread-app")
        let hiddenLegacyThreadID = CodexThreadID(rawValue: "legacy-review-thread")

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

        let legacyJob = ReviewRunRecord.makeForTesting(
            id: "legacy-job",
            cwd: repo.path,
            targetSummary: "Legacy review row",
            threadID: "legacy-review-thread",
            turnID: "legacy-turn",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 4_000),
            summary: "Running legacy review."
        )
        let legacyChat = ReviewMonitorCodexSidebarSnapshot.Chat(
            rowID: .chat(hiddenLegacyThreadID),
            id: hiddenLegacyThreadID,
            title: "Legacy review row",
            preview: "Running legacy review.",
            workspaceCWD: repo.path,
            updatedAt: Date(timeIntervalSince1970: 4_000)
        )
        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(
            serverState: .running,
            workspaces: [CodexReviewWorkspace(cwd: repo.path)],
            reviewRuns: [legacyJob]
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
        #expect(sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(legacyChat.id)) == nil)

        uiState.selection = .chat(legacyChat)

        try await waitForCondition {
            uiState.selection == nil && sidebar.selectedReviewChatIDForTesting == nil
        }
    }

    @Test func sidebarViewControllerTracksCodexSidebarFetchResultChanges() async throws {
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
        store.loadForTesting(
            serverState: .running,
            workspaces: [CodexReviewWorkspace(cwd: "/tmp/review-job-store")]
        )
        let uiState = ReviewMonitorUIState(auth: store.auth)
        let viewController = ReviewMonitorSplitViewController(
            store: store,
            uiState: uiState,
            modelContext: context
        )
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        try await waitForCondition(timeout: .milliseconds(500)) {
            sidebar.codexSidebarSnapshotForTesting?
                .chat(id: threadID)?
                .title == "App review"
        }
        try await waitForCondition(timeout: .milliseconds(500)) {
            sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(threadID)) == "App review"
        }
        let fullReloadCountBeforeContentUpdate = sidebar.sidebarFullReloadCountForTesting

        let chat = context.model(for: threadID)
        try await runtime.transport.enqueueThreadResume(.init(id: threadID))
        try await runtime.transport.enqueueThreadRead(
            .init(
                id: threadID,
                workspace: repo,
                name: "App review renamed",
                updatedAt: Date(timeIntervalSince1970: 6_000)
            ))
        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [
                    .init(
                        id: threadID,
                        workspace: repo,
                        name: "App review renamed",
                        updatedAt: Date(timeIntervalSince1970: 6_000)
                    )
                ]
            ))
        try await chat.refresh(includeTurns: false)
        #expect(await runtime.transport.recordedRequests(method: "thread/list").count == 2)

        try await waitForCondition {
            sidebar.codexSidebarSnapshotForTesting?
                .chat(id: threadID)?
                .title == "App review renamed"
        }
        try await waitForCondition {
            sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(threadID)) == "App review renamed"
        }
        #expect(sidebar.sidebarFullReloadCountForTesting == fullReloadCountBeforeContentUpdate)
        #expect(
            sidebar.displayedCodexSidebarTitlesForTesting == [
                repo.lastPathComponent,
                repo.lastPathComponent,
                "App review renamed",
            ])
    }

    @Test func sidebarViewControllerReordersCodexSectionsLocally() async throws {
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
        store.loadForTesting(serverState: .running, workspaces: [])
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
        let snapshot = try #require(sidebar.codexSidebarSnapshotForTesting)
        let firstSection = try #require(snapshot.sections.first)
        let secondSection = try #require(snapshot.sections.dropFirst().first)
        let fullReloadCountBeforeReorder = sidebar.sidebarFullReloadCountForTesting

        #expect(sidebar.codexSidebarCanStartDragForTesting(rowID: secondSection.rowID))
        #expect(sidebar.performCodexSectionDropForTesting(id: secondSection.id, toIndex: 0))
        #expect(
            sidebar.codexSidebarRootTitlesForTesting == [
                secondSection.title,
                firstSection.title,
            ])
        #expect(
            sidebar.codexSidebarSnapshotForTesting?.sections.map(\.id) == [
                firstSection.id,
                secondSection.id,
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
        store.loadForTesting(serverState: .running, workspaces: [])
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
        let snapshot = try #require(sidebar.codexSidebarSnapshotForTesting)
        let container = try #require(snapshot.sections.first?.workspaces.first?.rowID)
        let fullReloadCountBeforeReorder = sidebar.sidebarFullReloadCountForTesting

        #expect(sidebar.displayedCodexChatIDsForTesting(container: container) == [firstThreadID, secondThreadID])
        #expect(sidebar.codexSidebarCanStartDragForTesting(rowID: .chat(secondThreadID)))
        #expect(sidebar.performCodexChatDropForTesting(id: secondThreadID, container: container, childIndex: 0))
        #expect(sidebar.displayedCodexChatIDsForTesting(container: container) == [secondThreadID, firstThreadID])
        #expect(
            sidebar.codexSidebarSnapshotForTesting?.sections.first?.workspaces.first?.chats.map(\.id) == [
                firstThreadID,
                secondThreadID,
            ])
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
        store.loadForTesting(serverState: .running, workspaces: [])
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

private func sidebarSnapshot(
    workspaceID: CodexWorkspaceID,
    threadID: CodexThreadID,
    chatTitle: String,
    includesChat: Bool
) -> ReviewMonitorCodexSidebarSnapshot {
    let chat = sidebarChat(
        id: threadID,
        title: chatTitle,
        workspaceID: workspaceID
    )
    return sidebarSnapshot(
        workspaceID: workspaceID,
        chats: includesChat ? [chat] : []
    )
}

private func sidebarSnapshot(
    workspaceID: CodexWorkspaceID,
    chats: [ReviewMonitorCodexSidebarSnapshot.Chat]
) -> ReviewMonitorCodexSidebarSnapshot {
    return ReviewMonitorCodexSidebarSnapshot(
        sections: [
            sidebarSection(id: "repo", title: "Repo", workspaceID: workspaceID, chats: chats)
        ]
    )
}

private func sidebarSection(
    id: String,
    title: String,
    workspaceID: CodexWorkspaceID,
    chats: [ReviewMonitorCodexSidebarSnapshot.Chat]
) -> ReviewMonitorCodexSidebarSnapshot.Section {
    ReviewMonitorCodexSidebarSnapshot.Section(
        rowID: .section(id),
        id: id,
        title: title,
        workspaces: [
            ReviewMonitorCodexSidebarSnapshot.Workspace(
                rowID: .workspace(workspaceID),
                id: workspaceID,
                cwd: workspaceID.rawValue,
                title: URL(fileURLWithPath: workspaceID.rawValue).lastPathComponent,
                chats: chats
            )
        ],
        uncategorizedChats: []
    )
}

private func sidebarChat(
    id: CodexThreadID,
    title: String,
    workspaceID: CodexWorkspaceID,
    updatedAt: Date? = nil,
    status: CodexThreadStatus? = nil
) -> ReviewMonitorCodexSidebarSnapshot.Chat {
    ReviewMonitorCodexSidebarSnapshot.Chat(
        rowID: .chat(id),
        id: id,
        title: title,
        preview: nil,
        workspaceCWD: workspaceID.rawValue,
        updatedAt: updatedAt,
        recencyAt: updatedAt,
        status: status
    )
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
