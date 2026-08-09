import AppKit
import CodexAppServerKit
import CodexDataKit
import CodexAppServerKitTesting
import Foundation
import Testing
@_spi(Testing) @testable import CodexReviewKit
@testable import ReviewUI

@Suite("ReviewMonitor Codex sidebar results")
@MainActor
struct ReviewMonitorCodexSidebarResultsTests {
    @Test func buildsFlatSidebarSectionsFromCodexFetchedResults() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let app = try makeDirectory("App", in: repo)
        let tools = try makeDirectory("Tools", in: repo)

        try await runtime.transport.enqueueDefaultUserVisibleThreadListComposite(
            .init(
                threads: [
                    .init(
                        id: "thread-app",
                        workspace: app,
                        name: "App chat",
                        updatedAt: Date(timeIntervalSince1970: 3_000),
                        recencyAt: Date(timeIntervalSince1970: 3_000)
                    ),
                    .init(
                        id: "thread-tools",
                        workspace: tools,
                        name: "Tools chat",
                        updatedAt: Date(timeIntervalSince1970: 2_000),
                        recencyAt: Date(timeIntervalSince1970: 2_000)
                    ),
                ]
            ))

        let results = makeCodexSidebarFetchedResults(context: context)
        try await results.performFetch()

        let section = try #require(results.sections.first)
        let sectionWorkspaceGroupID = try #require(section.sidebarWorkspaceGroupID)
        let appWorkspace = try #require(section.workspaces.first)
        let appChat = try #require(section.chats(in: appWorkspace.id).first)
        let resolvedAppPath = app.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedToolsPath = tools.standardizedFileURL.resolvingSymlinksInPath().path

        #expect(results.sections.count == 1)
        #expect(section.displayTitle == repo.lastPathComponent)
        #expect(section.workspaces.map(\.url.path) == [resolvedAppPath, resolvedToolsPath])
        #expect(section.workspaces.map(\.name) == ["App", "Tools"])
        #expect(section.items.map(\.title) == ["App chat", "Tools chat"])
        #expect(appChat === results.items.first { $0.id == CodexThreadID(rawValue: "thread-app") })
        #expect(appChat.workspace?.url.path == resolvedAppPath)

        let tree = ReviewMonitorCodexSidebarOutlineTree()
        #expect(tree.apply(sections: results.sections).topologyChanged)
        let outlineSection = try #require(tree.roots.first)
        let outlineAppChat = try #require(tree.node(rowID: .chat(appChat.id)))

        #expect(outlineSection.rowID == section.rowID)
        #expect(outlineSection.item == .workspaceGroup(sectionWorkspaceGroupID))
        #expect(outlineSection.selectionID == .workspaceGroup(sectionWorkspaceGroupID))
        #expect(outlineSection.isExpandable)
        #expect(
            outlineSection.children.map(\.rowID.rawValue) == [
                "chat:thread-app",
                "chat:thread-tools",
            ])
        #expect(outlineAppChat.item == .chat(appChat.id))
        #expect(outlineAppChat.selectionID == .chat(appChat.id))
        #expect(
            results.sections.rowIDs.map(\.rawValue) == [
                "workspaceGroup:\(sectionWorkspaceGroupID.rawValue)",
                "chat:thread-app",
                "chat:thread-tools",
            ])
    }

    @Test func filteringAndPresentationOrderPreserveCodexWorkspaceSource() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let runningThreadID = CodexThreadID(rawValue: "thread-running")
        let idleThreadID = CodexThreadID(rawValue: "thread-idle")

        try await runtime.transport.enqueueDefaultUserVisibleThreadListComposite(
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

        let results = makeCodexSidebarFetchedResults(context: context)
        try await results.performFetch()
        let sections = results.sections
        let originalWorkspace = try #require(sections.first?.workspaces.first)

        let filteredWorkspace = try #require(sections.filtered(by: .running).first?.workspaces.first)
        #expect(filteredWorkspace === originalWorkspace)
        #expect(sections.filtered(by: .running).first?.chats(in: originalWorkspace.id).map(\.id) == [runningThreadID])
        #expect(sections.filtered(by: .latestFinished).first?.chats(in: originalWorkspace.id).map(\.id) == [idleThreadID])

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

    @Test func sidebarFilterDropsSectionsWithoutMatchingChats() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()

        try await runtime.transport.enqueueDefaultUserVisibleThreadListComposite(
            .init(
                threads: [
                    .init(
                        id: "thread-idle",
                        workspace: repo,
                        name: "Idle review",
                        updatedAt: Date(timeIntervalSince1970: 2_000),
                        status: .idle
                    )
                ]
            ))

        let results = makeCodexSidebarFetchedResults(context: context)
        try await results.performFetch()

        #expect(results.sections.count == 1)
        #expect(results.sections.filtered(by: .running).isEmpty)
    }

    @Test func defaultCodexSidebarDescriptorUsesDedicatedHomeAndUserVisibleSources() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueDefaultUserVisibleThreadListComposite(.init(threads: []))

        let results = makeCodexSidebarFetchedResults(context: context)
        try await results.performFetch()

        let requests = await runtime.transport.recordedRequests(for: .threadList)
        #expect(requests.count == 2)
        let interactiveRequest = try #require(requests.first)
        let noninteractiveRequest = try #require(requests.dropFirst().first)
        guard case .threadList(let interactiveQuery) = interactiveRequest.request,
            case .threadList(let noninteractiveQuery) = noninteractiveRequest.request
        else {
            Issue.record("Expected two thread-list requests.")
            return
        }
        #expect(interactiveQuery.archived == false)
        #expect(interactiveQuery.sourceKinds == nil)
        #expect(interactiveQuery.limit == 25)
        #expect(noninteractiveQuery.archived == false)
        #expect(
            noninteractiveQuery.sourceKinds == [
                .exec,
                .appServer,
                .subAgentReview,
                .subAgentCompact,
                .subAgentThreadSpawn,
                .subAgentOther,
                .unknown,
            ])
        #expect(noninteractiveQuery.limit == 25)
    }

    @Test func sidebarIncludesCanonicalWorkspaceChatsWithStableRowIDs() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()

        try await runtime.transport.enqueueDefaultUserVisibleThreadListComposite(
            .init(
                threads: [
                    .init(
                        id: "thread-workspace",
                        workspace: repo,
                        name: "Workspace review",
                        preview: "Workspace preview",
                        updatedAt: Date(timeIntervalSince1970: 4_000)
                    )
                ]
            ))

        let results = makeCodexSidebarFetchedResults(context: context)
        try await results.performFetch()

        let section = try #require(results.sections.first)
        let workspaceGroupID = try #require(section.sidebarWorkspaceGroupID)
        let workspace = try #require(section.workspaces.first)
        let chat = try #require(section.items.first)

        #expect(section.uncategorizedChats.isEmpty)
        #expect(workspace.url.path == repo.standardizedFileURL.resolvingSymlinksInPath().path)
        #expect(chat.id == CodexThreadID(rawValue: "thread-workspace"))
        #expect(chat.title == "Workspace review")
        #expect(chat.preview == "Workspace preview")
        #expect(chat.workspace === workspace)
        #expect(
            section.rowIDs.map(\.rawValue) == [
                "workspaceGroup:\(workspaceGroupID.rawValue)",
                "chat:thread-workspace",
            ])

        let tree = ReviewMonitorCodexSidebarOutlineTree()
        #expect(tree.apply(sections: results.sections).topologyChanged)
        let outlineSection = try #require(tree.roots.first)
        let outlineChat = try #require(tree.node(rowID: .chat(chat.id)))
        #expect(section.rowID == .workspaceGroup(workspaceGroupID))
        #expect(outlineSection.item == .workspaceGroup(workspaceGroupID))
        #expect(outlineSection.selectionID == .workspaceGroup(workspaceGroupID))
        #expect(outlineSection.children.map(\.rowID.rawValue) == ["chat:thread-workspace"])
        #expect(outlineChat.selectionID == .chat(chat.id))
        #expect(outlineChat.isExpandable == false)
    }

    @Test func sidebarOutlineTreePreservesNodeIdentityAcrossSectionUpdates() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let threadID = CodexThreadID(rawValue: "thread-app")

        try await runtime.transport.enqueueDefaultUserVisibleThreadListComposite(
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

        let results = makeCodexSidebarFetchedResults(context: context)
        try await results.performFetch()
        let tree = ReviewMonitorCodexSidebarOutlineTree()

        #expect(tree.apply(sections: results.sections).topologyChanged)
        let root = try #require(tree.roots.first)
        let chatNode = try #require(tree.node(rowID: .chat(threadID)))

        try await runtime.transport.enqueueThreadResume(.init(id: threadID, workspace: repo))
        try await runtime.transport.enqueueThreadRead(
            .init(
                id: threadID,
                workspace: repo,
                name: "Updated review",
                updatedAt: Date(timeIntervalSince1970: 2_000)
            ))
        try await context.refresh(context.model(for: threadID), includeTurns: false)

        #expect(tree.apply(sections: results.sections).topologyChanged == false)
        #expect(tree.roots.first === root)
        #expect(tree.node(rowID: .chat(threadID)) === chatNode)
        #expect(chatNode.item == .chat(threadID))
        #expect(results.sections.chat(id: threadID)?.title == "Updated review")
        #expect(root.children.map(\.rowID) == [.chat(threadID)])
        #expect(root.children.first === chatNode)
    }

    @Test func sidebarRunningFilterUsesThreadStatus() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let runningThreadID = CodexThreadID(rawValue: "thread-running")
        let idleThreadID = CodexThreadID(rawValue: "thread-idle")

        try await runtime.transport.enqueueDefaultUserVisibleThreadListComposite(
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

        let results = makeCodexSidebarFetchedResults(context: context)
        try await results.performFetch()
        let section = try #require(results.sections.filtered(by: .running).first)
        let workspace = try #require(section.workspaces.first)

        #expect(section.chats(in: workspace.id).map(\.id) == [runningThreadID])
        #expect(section.chats(in: workspace.id).contains { $0.id == idleThreadID } == false)
    }

    @Test func sidebarViewControllerInstallsCodexSidebarFetchedResultsFromModelContext() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let threadID = CodexThreadID(rawValue: "thread-app")

        try await runtime.transport.enqueueDefaultUserVisibleThreadListComposite(
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

        try await runtime.transport.enqueueDefaultUserVisibleThreadListComposite(
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
            attemptID: "run-backed-attempt",
            threadID: hiddenRunThreadID.rawValue,
            reviewThreadID: hiddenRunThreadID.rawValue,
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
            sidebar.nativeSelectedReviewChatIDForTesting == nil
        }
        #expect(uiState.selection == .chat(hiddenRunThreadID))
        #expect(sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(hiddenRunThreadID)) == nil)
    }

    @Test func sidebarViewControllerTracksCodexSidebarFetchResultChanges() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let threadID = CodexThreadID(rawValue: "thread-app")

        try await runtime.transport.enqueueDefaultUserVisibleThreadListComposite(.init(threads: []))

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

        try await runtime.transport.enqueueDefaultUserVisibleThreadListComposite(
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

    @Test func sidebarRefreshOmittingSelectedRegisteredChatPreservesSelectionAndDetail() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let selectedThreadID = CodexThreadID(rawValue: "thread-selected")
        let remainingThreadID = CodexThreadID(rawValue: "thread-remaining")

        try await runtime.transport.enqueueDefaultUserVisibleThreadListComposite(
            .init(
                threads: [
                    .init(
                        id: selectedThreadID,
                        workspace: repo,
                        name: "Selected review",
                        updatedAt: Date(timeIntervalSince1970: 5_000),
                        status: .active(activeFlags: [])
                    ),
                    .init(
                        id: remainingThreadID,
                        workspace: repo,
                        name: "Remaining review",
                        updatedAt: Date(timeIntervalSince1970: 4_000),
                        status: .idle
                    ),
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
        window.setContentSize(NSSize(width: 900, height: 600))
        viewController.loadViewIfNeeded()
        viewController.view.layoutSubtreeIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        let transport = viewController.transportViewControllerForTesting
        try await waitForCondition {
            sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(selectedThreadID)) == "Selected review"
                && sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(remainingThreadID)) == "Remaining review"
        }
        let selectedChat = try #require(context.registeredModel(for: selectedThreadID))
        #expect(selectedChat.isArchived == false)

        sidebar.selectCodexSidebarRowForTesting(rowID: .chat(selectedThreadID))
        try await waitForCondition {
            sidebar.selectedReviewChatIDForTesting == selectedThreadID
                && sidebar.nativeSelectedReviewChatIDForTesting == selectedThreadID
                && transport.renderedStateForTesting.selection == .chat(selectedThreadID.rawValue)
                && transport.renderedStateForTesting.snapshot.isShowingEmptyState == false
        }

        try await runtime.transport.enqueueDefaultUserVisibleThreadListComposite(
            .init(
                threads: [
                    .init(
                        id: remainingThreadID,
                        workspace: repo,
                        name: "Remaining review",
                        updatedAt: Date(timeIntervalSince1970: 6_000),
                        status: .idle
                    )
                ]
            ))
        try await sidebar.refreshCodexSidebarForTesting()

        try await waitForCondition {
            sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(selectedThreadID)) == "Selected review"
                && sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(remainingThreadID)) == "Remaining review"
                && sidebar.selectedReviewChatIDForTesting == selectedThreadID
                && sidebar.nativeSelectedReviewChatIDForTesting == selectedThreadID
                && transport.renderedStateForTesting.selection == .chat(selectedThreadID.rawValue)
                && transport.renderedStateForTesting.snapshot.isShowingEmptyState == false
        }
        #expect(context.registeredModel(for: selectedThreadID) === selectedChat)
        #expect(selectedChat.isArchived == false)
    }

    @Test func sidebarViewControllerShowsEmptyStateWhenFilterHasNoMatches() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()

        try await runtime.transport.enqueueDefaultUserVisibleThreadListComposite(
            .init(
                threads: [
                    .init(
                        id: "thread-idle",
                        workspace: repo,
                        name: "Idle review",
                        updatedAt: Date(timeIntervalSince1970: 5_000),
                        status: .idle
                    )
                ]
            ))

        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running)
        let uiState = ReviewMonitorUIState(auth: store.auth, sidebarReviewChatFilter: .running)
        let viewController = ReviewMonitorSplitViewController(
            store: store,
            uiState: uiState,
            modelContext: context
        )
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        try await waitForCondition {
            sidebar.isShowingEmptyStateForTesting
        }
        #expect(sidebar.codexSidebarRootTitlesForTesting.isEmpty)
    }

    @Test func sidebarViewControllerPreservesSelectionAndAvoidsFullReloadWhenCodexChatContentChanges() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let threadID = CodexThreadID(rawValue: "thread-app")

        try await runtime.transport.enqueueDefaultUserVisibleThreadListComposite(
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
        try await runtime.transport.enqueueThreadResume(.init(id: threadID, workspace: repo))
        try await runtime.transport.enqueueThreadRead(
            .init(
                id: threadID,
                workspace: repo,
                name: "App review renamed",
                updatedAt: Date(timeIntervalSince1970: 6_000)
            ))
        try await context.refresh(chat, includeTurns: false)

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

        try await runtime.transport.enqueueDefaultUserVisibleThreadListComposite(
            .init(
                threads: [
                    .init(
                        id: "thread-first-repo",
                        workspace: firstRepo,
                        name: "First repo review",
                        updatedAt: Date(timeIntervalSince1970: 5_000),
                        recencyAt: Date(timeIntervalSince1970: 5_000)
                    ),
                    .init(
                        id: "thread-second-repo",
                        workspace: secondRepo,
                        name: "Second repo review",
                        updatedAt: Date(timeIntervalSince1970: 4_000),
                        recencyAt: Date(timeIntervalSince1970: 4_000)
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
        let firstWorkspaceGroupID = try #require(firstSection.sidebarWorkspaceGroupID)
        let secondWorkspaceGroupID = try #require(secondSection.sidebarWorkspaceGroupID)
        let fullReloadCountBeforeReorder = sidebar.sidebarFullReloadCountForTesting

        #expect(sidebar.codexSidebarCanStartDragForTesting(rowID: secondSection.rowID))
        #expect(sidebar.performCodexWorkspaceGroupDropForTesting(id: secondWorkspaceGroupID, toIndex: 0))
        #expect(
            sidebar.codexSidebarRootTitlesForTesting == [
                secondSection.displayTitle,
                firstSection.displayTitle,
            ])
        #expect(
            sidebar.codexSidebarSectionsForTesting.compactMap(\.sidebarWorkspaceGroupID) == [
                firstWorkspaceGroupID,
                secondWorkspaceGroupID,
            ])
        #expect(sidebar.sidebarFullReloadCountForTesting == fullReloadCountBeforeReorder)
    }

    @Test func sidebarViewControllerReordersAcrossCanonicalWorkspaceGroupRows() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let leadingRepo = try makeGitRepository()
        let middleRepo = try makeGitRepository()
        let firstRepo = try makeGitRepository()
        let secondRepo = try makeGitRepository()

        try await runtime.transport.enqueueDefaultUserVisibleThreadListComposite(
            .init(
                threads: [
                    .init(
                        id: "thread-leading-repo",
                        workspace: leadingRepo,
                        name: "Leading repo review",
                        updatedAt: Date(timeIntervalSince1970: 7_000),
                        recencyAt: Date(timeIntervalSince1970: 7_000)
                    ),
                    .init(
                        id: "thread-middle-repo",
                        workspace: middleRepo,
                        name: "Middle repo review",
                        updatedAt: Date(timeIntervalSince1970: 6_000),
                        recencyAt: Date(timeIntervalSince1970: 6_000)
                    ),
                    .init(
                        id: "thread-first-repo",
                        workspace: firstRepo,
                        name: "First repo review",
                        updatedAt: Date(timeIntervalSince1970: 5_000),
                        recencyAt: Date(timeIntervalSince1970: 5_000)
                    ),
                    .init(
                        id: "thread-second-repo",
                        workspace: secondRepo,
                        name: "Second repo review",
                        updatedAt: Date(timeIntervalSince1970: 4_000),
                        recencyAt: Date(timeIntervalSince1970: 4_000)
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
                leadingRepo.lastPathComponent,
                middleRepo.lastPathComponent,
                firstRepo.lastPathComponent,
                secondRepo.lastPathComponent,
            ]
        }

        let sections = sidebar.codexSidebarSectionsForTesting
        #expect(sections.allSatisfy { $0.sidebarWorkspaceGroupID != nil })
        let leadingSection = try #require(sections.first)
        let middleSection = try #require(sections.dropFirst().first)
        let firstSection = try #require(sections.dropFirst(2).first)
        let secondSection = try #require(sections.dropFirst(3).first)
        let leadingWorkspaceGroupID = try #require(leadingSection.sidebarWorkspaceGroupID)
        let middleWorkspaceGroupID = try #require(middleSection.sidebarWorkspaceGroupID)
        let firstWorkspaceGroupID = try #require(firstSection.sidebarWorkspaceGroupID)
        let secondWorkspaceGroupID = try #require(secondSection.sidebarWorkspaceGroupID)

        for section in sections {
            #expect(sidebar.codexSidebarCanStartDragForTesting(rowID: section.rowID))
        }
        #expect(sidebar.performCodexWorkspaceGroupDropForTesting(id: firstWorkspaceGroupID, toIndex: 1))
        #expect(
            sidebar.codexSidebarRootTitlesForTesting == [
                leadingRepo.lastPathComponent,
                firstRepo.lastPathComponent,
                middleRepo.lastPathComponent,
                secondRepo.lastPathComponent,
            ])
        #expect(sidebar.performCodexWorkspaceGroupDropForTesting(id: leadingWorkspaceGroupID, toIndex: 4))
        #expect(
            sidebar.codexSidebarRootTitlesForTesting == [
                firstRepo.lastPathComponent,
                middleRepo.lastPathComponent,
                secondRepo.lastPathComponent,
                leadingRepo.lastPathComponent,
            ])
        #expect(Set([leadingWorkspaceGroupID, middleWorkspaceGroupID, firstWorkspaceGroupID, secondWorkspaceGroupID]).count == 4)
    }

    @Test func sidebarViewControllerReordersWorkspaceGroupsAcrossFilteredOutSectionRows() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let leadingRepo = try makeGitRepository()
        let middleRepo = try makeGitRepository()
        let firstRepo = try makeGitRepository()
        let secondRepo = try makeGitRepository()

        try await runtime.transport.enqueueDefaultUserVisibleThreadListComposite(
            .init(
                threads: [
                    .init(
                        id: "thread-leading-repo",
                        workspace: leadingRepo,
                        name: "Leading repo review",
                        updatedAt: Date(timeIntervalSince1970: 7_000),
                        recencyAt: Date(timeIntervalSince1970: 7_000),
                        status: .active(activeFlags: [])
                    ),
                    .init(
                        id: "thread-uncategorized",
                        workspace: middleRepo,
                        name: "Uncategorized review",
                        updatedAt: Date(timeIntervalSince1970: 6_000),
                        recencyAt: Date(timeIntervalSince1970: 6_000),
                        status: .idle
                    ),
                    .init(
                        id: "thread-first-repo",
                        workspace: firstRepo,
                        name: "First repo review",
                        updatedAt: Date(timeIntervalSince1970: 5_000),
                        recencyAt: Date(timeIntervalSince1970: 5_000),
                        status: .active(activeFlags: [])
                    ),
                    .init(
                        id: "thread-second-repo",
                        workspace: secondRepo,
                        name: "Second repo review",
                        updatedAt: Date(timeIntervalSince1970: 4_000),
                        recencyAt: Date(timeIntervalSince1970: 4_000),
                        status: .active(activeFlags: [])
                    ),
                ]
            ))

        let store = CodexReviewStore.makePreviewStore()
        store.loadForTesting(serverState: .running)
        let uiState = ReviewMonitorUIState(auth: store.auth, sidebarReviewChatFilter: .running)
        let viewController = ReviewMonitorSplitViewController(
            store: store,
            uiState: uiState,
            modelContext: context
        )
        viewController.loadViewIfNeeded()

        let sidebar = viewController.sidebarViewControllerForTesting
        try await waitForCondition {
            sidebar.codexSidebarRootTitlesForTesting == [
                leadingRepo.lastPathComponent,
                firstRepo.lastPathComponent,
                secondRepo.lastPathComponent,
            ]
        }

        let sections = sidebar.codexSidebarSectionsForTesting
        let secondSection = try #require(
            sections.first { $0.displayTitle == secondRepo.lastPathComponent }
        )
        let secondWorkspaceGroupID = try #require(secondSection.sidebarWorkspaceGroupID)

        #expect(sidebar.performCodexWorkspaceGroupDropForTesting(id: secondWorkspaceGroupID, toIndex: 0))
        #expect(
            sidebar.codexSidebarRootTitlesForTesting == [
                secondRepo.lastPathComponent,
                leadingRepo.lastPathComponent,
                firstRepo.lastPathComponent,
            ])
    }

    @Test func sidebarViewControllerReordersCodexChatsLocallyWithinContainer() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let firstThreadID = CodexThreadID(rawValue: "thread-first")
        let secondThreadID = CodexThreadID(rawValue: "thread-second")

        try await runtime.transport.enqueueDefaultUserVisibleThreadListComposite(
            .init(
                threads: [
                    .init(
                        id: firstThreadID,
                        workspace: repo,
                        name: "First review",
                        updatedAt: Date(timeIntervalSince1970: 5_000),
                        recencyAt: Date(timeIntervalSince1970: 5_000)
                    ),
                    .init(
                        id: secondThreadID,
                        workspace: repo,
                        name: "Second review",
                        updatedAt: Date(timeIntervalSince1970: 4_000),
                        recencyAt: Date(timeIntervalSince1970: 4_000)
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
        let container = section.rowID
        let fullReloadCountBeforeReorder = sidebar.sidebarFullReloadCountForTesting

        #expect(sidebar.displayedCodexChatIDsForTesting(container: container) == [firstThreadID, secondThreadID])
        #expect(sidebar.codexSidebarCanStartDragForTesting(rowID: .chat(secondThreadID)))
        #expect(sidebar.performCodexChatDropForTesting(id: secondThreadID, container: container, childIndex: 0))
        #expect(sidebar.displayedCodexChatIDsForTesting(container: container) == [secondThreadID, firstThreadID])
        #expect(section.items.map(\.id) == [firstThreadID, secondThreadID])
        #expect(sidebar.sidebarFullReloadCountForTesting == fullReloadCountBeforeReorder)
    }

    @Test func sidebarViewControllerDoesNotReloadCodexOutlineWhenSelectionChanges() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let firstThreadID = CodexThreadID(rawValue: "thread-first")
        let secondThreadID = CodexThreadID(rawValue: "thread-second")

        try await runtime.transport.enqueueDefaultUserVisibleThreadListComposite(
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

    @Test func sidebarIgnoresProgrammaticNativeSelectionChanges() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let activeThreadID = CodexThreadID(rawValue: "thread-active")
        let previousThreadID = CodexThreadID(rawValue: "thread-previous")

        try await runtime.transport.enqueueDefaultUserVisibleThreadListComposite(
            .init(
                threads: [
                    .init(
                        id: activeThreadID,
                        workspace: repo,
                        name: "Active review",
                        updatedAt: Date(timeIntervalSince1970: 5_000),
                        status: .active(activeFlags: [])
                    ),
                    .init(
                        id: previousThreadID,
                        workspace: repo,
                        name: "Previous review",
                        updatedAt: Date(timeIntervalSince1970: 4_000),
                        status: .idle
                    ),
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
        let transport = viewController.transportViewControllerForTesting
        try await waitForCondition {
            sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(activeThreadID)) == "Active review"
                && sidebar.codexSidebarNodeTitleForTesting(rowID: .chat(previousThreadID)) == "Previous review"
        }

        sidebar.selectCodexSidebarRowForTesting(rowID: .chat(activeThreadID))
        try await waitForCondition {
            sidebar.selectedReviewChatIDForTesting == activeThreadID
                && sidebar.nativeSelectedReviewChatIDForTesting == activeThreadID
                && transport.renderedStateForTesting.selection == .chat(activeThreadID.rawValue)
        }

        sidebar.selectCodexSidebarRowProgrammaticallyForTesting(rowID: .chat(previousThreadID))

        try await waitForCondition {
            sidebar.selectedReviewChatIDForTesting == activeThreadID
                && sidebar.nativeSelectedReviewChatIDForTesting == activeThreadID
                && transport.renderedStateForTesting.selection == .chat(activeThreadID.rawValue)
        }
    }

    @Test func sidebarViewControllerKeepsWorkspaceGroupOrderWhenSelectedChatRefreshesUpdatedAt() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let firstRepo = try makeGitRepository()
        let secondRepo = try makeGitRepository()
        let firstThreadID = CodexThreadID(rawValue: "thread-first-repo")
        let secondThreadID = CodexThreadID(rawValue: "thread-second-repo")
        let firstRecencyAt = Date(timeIntervalSince1970: 5_000)
        let secondRecencyAt = Date(timeIntervalSince1970: 4_000)

        try await runtime.transport.enqueueDefaultUserVisibleThreadListComposite(
            .init(
                threads: [
                    .init(
                        id: firstThreadID,
                        workspace: firstRepo,
                        name: "First repo review",
                        updatedAt: firstRecencyAt,
                        recencyAt: firstRecencyAt
                    ),
                    .init(
                        id: secondThreadID,
                        workspace: secondRepo,
                        name: "Second repo review",
                        updatedAt: secondRecencyAt,
                        recencyAt: secondRecencyAt
                    ),
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

        try await waitForCondition {
            sidebar.codexSidebarRootTitlesForTesting == [
                firstRepo.lastPathComponent,
                secondRepo.lastPathComponent,
            ]
        }
        let reloadCountAfterInitialFetch = sidebar.sidebarFullReloadCountForTesting

        try await runtime.transport.enqueueThreadResume(
            .init(
                id: secondThreadID,
                workspace: secondRepo,
                name: "Second repo review",
                updatedAt: Date(timeIntervalSince1970: 9_000),
                recencyAt: secondRecencyAt
            ))
        try await runtime.transport.enqueueThreadRead(
            .init(
                id: secondThreadID,
                workspace: secondRepo,
                name: "Second repo review",
                updatedAt: Date(timeIntervalSince1970: 9_000),
                recencyAt: secondRecencyAt
            ))
        sidebar.selectCodexSidebarRowForTesting(rowID: .chat(secondThreadID))

        try await waitForCondition {
            window.title == "Second repo review"
                && sidebar.selectedReviewChatIDForTesting == secondThreadID
        }
        try await waitForCondition {
            context.model(for: secondThreadID).updatedAt == Date(timeIntervalSince1970: 9_000)
        }

        #expect(
            sidebar.codexSidebarRootTitlesForTesting == [
                firstRepo.lastPathComponent,
                secondRepo.lastPathComponent,
            ])
        #expect(sidebar.sidebarFullReloadCountForTesting == reloadCountAfterInitialFetch)
    }
}

@MainActor
private func makeCodexSidebarFetchedResults(
    context: CodexModelContext
) -> CodexFetchedResults<CodexChat> {
    context.fetchedResults(
        for: ReviewMonitorSidebarViewController.defaultCodexSidebarDescriptor,
        sectionedBy: .workspaceGroup
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

extension CodexAppServerTestTransport {
    func enqueueDefaultUserVisibleThreadListComposite(
        _ noninteractivePage: CodexAppServerTestThreadPage
    ) throws {
        // Sidebar fixtures in this file are app-server threads. The default interactive
        // partition must terminate before CodexDataKit requests the noninteractive sources.
        try enqueueThreadList(.init(threads: []))
        try enqueueThreadList(noninteractivePage)
    }

    func enqueueDefaultUserVisibleThreadListComposite(
        interactivePage: CodexAppServerTestThreadPage,
        noninteractivePage: CodexAppServerTestThreadPage = .init(threads: [])
    ) throws {
        try enqueueThreadList(interactivePage)
        try enqueueThreadList(noninteractivePage)
    }
}

private extension CodexAppServerTestStoredThread {
    init(
        id: CodexThreadID,
        workspace: URL,
        name: String? = nil,
        preview: String? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 0),
        recencyAt: Date? = nil,
        status: CodexThreadStatus = .idle
    ) throws {
        let cwd = workspace
        try self.init(
            snapshot: .init(
                id: id,
                workspace: cwd,
                name: name,
                preview: preview ?? name ?? id.rawValue,
                modelProvider: "openai",
                sourceKind: .appServer,
                createdAt: updatedAt,
                updatedAt: updatedAt,
                recencyAt: recencyAt ?? updatedAt,
                status: status,
                ephemeral: false,
                turns: []
            ),
            turns: [],
            metadata: .init(
                sessionID: "session-\(id.rawValue)",
                cliVersion: "codex-cli-test",
                source: .appServer
            ),
            runtimeMetadata: .init(
                model: "gpt-5",
                modelProvider: "openai",
                serviceTier: nil,
                cwd: cwd,
                runtimeWorkspaceRoots: [cwd],
                instructionSources: [],
                approvalPolicy: .never,
                approvalsReviewer: .user,
                sandbox: .dangerFullAccess,
                activePermissionProfile: nil,
                reasoningEffort: nil,
                multiAgentMode: .explicitRequestOnly
            ),
            isArchived: false
        )
    }
}
