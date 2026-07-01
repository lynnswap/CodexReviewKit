import AppKit
import CodexKit
import CodexAppServerKitTesting
import Foundation
import Testing
@_spi(Testing) @testable import CodexReviewKit
@testable import ReviewUI

@Suite("ReviewMonitor Codex sidebar results")
@MainActor
struct ReviewMonitorCodexSidebarResultsTests {
    @Test func buildsFlatSidebarSectionsFromCodexFetchedResultsController() async throws {
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

        let controller = makeCodexSidebarFetchedResultsController(context: context)
        try await controller.performFetch()

        let section = try #require(controller.sections.first)
        let sectionWorkspaceGroupID = try #require(section.sidebarWorkspaceGroupID)
        let appWorkspace = try #require(section.workspaces.first)
        let appChat = try #require(section.chats(in: appWorkspace.id).first)
        let resolvedAppPath = app.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedToolsPath = tools.standardizedFileURL.resolvingSymlinksInPath().path

        #expect(controller.sections.count == 1)
        #expect(section.displayTitle == repo.lastPathComponent)
        #expect(section.workspaces.map(\.url.path) == [resolvedAppPath, resolvedToolsPath])
        #expect(section.workspaces.map(\.name) == ["App", "Tools"])
        #expect(section.items.map(\.title) == ["App chat", "Tools chat"])
        #expect(appChat === controller.items.first { $0.id == CodexThreadID(rawValue: "thread-app") })
        #expect(appChat.workspace?.url.path == resolvedAppPath)

        let tree = ReviewMonitorCodexSidebarOutlineTree()
        #expect(tree.apply(sections: controller.sections).topologyChanged)
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
            controller.sections.rowIDs.map(\.rawValue) == [
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

        let controller = makeCodexSidebarFetchedResultsController(context: context)
        try await controller.performFetch()
        let sections = controller.sections
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

        try await runtime.transport.enqueueThreadList(
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

        let controller = makeCodexSidebarFetchedResultsController(context: context)
        try await controller.performFetch()

        #expect(controller.sections.count == 1)
        #expect(controller.sections.filtered(by: .running).isEmpty)
    }

    @Test func defaultCodexSidebarDescriptorUsesDedicatedHomeWithoutSourceFiltering() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext

        try await runtime.transport.enqueueThreadList(.init(threads: []))

        let controller = makeCodexSidebarFetchedResultsController(context: context)
        try await controller.performFetch()

        let request = try #require(await runtime.transport.recordedRequests(method: "thread/list").first)
        let params = try request.decodeParams(ThreadListParams.self)
        #expect(params.sourceKinds == nil)
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

        let controller = makeCodexSidebarFetchedResultsController(context: context)
        try await controller.performFetch()

        let section = try #require(controller.sections.first)
        let chat = try #require(section.uncategorizedChats.first)

        #expect(section.sidebarWorkspaceGroupID == nil)
        #expect(section.workspaces.isEmpty)
        #expect(chat.id == CodexThreadID(rawValue: "thread-uncategorized"))
        #expect(chat.title == "Floating review")
        #expect(chat.preview == "Uncategorized preview")
        #expect(chat.workspace == nil)
        #expect(
            section.rowIDs.map(\.rawValue) == [
                "section:unknown:unknown",
                "chat:thread-uncategorized",
            ])

        let tree = ReviewMonitorCodexSidebarOutlineTree()
        #expect(tree.apply(sections: controller.sections).topologyChanged)
        let outlineSection = try #require(tree.roots.first)
        let outlineChat = try #require(tree.node(rowID: .chat(chat.id)))
        #expect(section.rowID == .section(.unknown("unknown")))
        #expect(outlineSection.item == .section(.unknown("unknown")))
        #expect(outlineSection.selectionID == nil)
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

        let controller = makeCodexSidebarFetchedResultsController(context: context)
        try await controller.performFetch()
        let tree = ReviewMonitorCodexSidebarOutlineTree()

        #expect(tree.apply(sections: controller.sections).topologyChanged)
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
        try await context.refresh(context.model(for: threadID), includeTurns: false)

        #expect(tree.apply(sections: controller.sections).topologyChanged == false)
        #expect(tree.roots.first === root)
        #expect(tree.node(rowID: .chat(threadID)) === chatNode)
        #expect(chatNode.item == .chat(threadID))
        #expect(controller.sections.chat(id: threadID)?.title == "Updated review")
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

        let controller = makeCodexSidebarFetchedResultsController(context: context)
        try await controller.performFetch()
        let section = try #require(controller.sections.filtered(by: .running).first)
        let workspace = try #require(section.workspaces.first)

        #expect(section.chats(in: workspace.id).map(\.id) == [runningThreadID])
        #expect(section.chats(in: workspace.id).contains { $0.id == idleThreadID } == false)
    }

    @Test func sidebarViewControllerInstallsCodexSidebarFetchedResultsControllerFromModelContext() async throws {
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

    @Test func sidebarRefreshOmittingSelectedRegisteredChatPreservesSelectionAndDetail() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let selectedThreadID = CodexThreadID(rawValue: "thread-selected")
        let remainingThreadID = CodexThreadID(rawValue: "thread-remaining")

        try await runtime.transport.enqueueThreadList(
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

        try await runtime.transport.enqueueThreadList(
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

        try await runtime.transport.enqueueThreadList(
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

    @Test func sidebarViewControllerRejectsWorkspaceGroupDropsAcrossSectionRows() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let leadingRepo = try makeGitRepository()
        let firstRepo = try makeGitRepository()
        let secondRepo = try makeGitRepository()

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [
                    .init(
                        id: "thread-leading-repo",
                        workspace: leadingRepo,
                        name: "Leading repo review",
                        updatedAt: Date(timeIntervalSince1970: 7_000)
                    ),
                    .init(
                        id: "thread-uncategorized",
                        name: "Uncategorized review",
                        updatedAt: Date(timeIntervalSince1970: 6_000)
                    ),
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
                leadingRepo.lastPathComponent,
                "Unknown",
                firstRepo.lastPathComponent,
                secondRepo.lastPathComponent,
            ]
        }

        let sections = sidebar.codexSidebarSectionsForTesting
        let sectionRow = try #require(sections.first { $0.sidebarWorkspaceGroupID == nil })
        let workspaceGroupSections = sections.filter { $0.sidebarWorkspaceGroupID != nil }
        let leadingSection = try #require(workspaceGroupSections.first)
        let firstSection = try #require(workspaceGroupSections.dropFirst().first)
        let secondSection = try #require(workspaceGroupSections.dropFirst(2).first)
        let leadingWorkspaceGroupID = try #require(leadingSection.sidebarWorkspaceGroupID)
        let firstWorkspaceGroupID = try #require(firstSection.sidebarWorkspaceGroupID)
        let secondWorkspaceGroupID = try #require(secondSection.sidebarWorkspaceGroupID)

        #expect(sidebar.codexSidebarCanStartDragForTesting(rowID: sectionRow.rowID) == false)
        #expect(sidebar.performCodexWorkspaceGroupDropForTesting(id: firstWorkspaceGroupID, toIndex: 1) == false)
        #expect(sidebar.performCodexWorkspaceGroupDropForTesting(id: secondWorkspaceGroupID, toIndex: 2))
        #expect(
            sidebar.codexSidebarRootTitlesForTesting == [
                leadingRepo.lastPathComponent,
                "Unknown",
                secondRepo.lastPathComponent,
                firstRepo.lastPathComponent,
            ])
        #expect(sidebar.performCodexWorkspaceGroupDropForTesting(id: leadingWorkspaceGroupID, toIndex: 4) == false)
    }

    @Test func sidebarViewControllerReordersWorkspaceGroupsAcrossFilteredOutSectionRows() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let leadingRepo = try makeGitRepository()
        let firstRepo = try makeGitRepository()
        let secondRepo = try makeGitRepository()

        try await runtime.transport.enqueueThreadList(
            .init(
                threads: [
                    .init(
                        id: "thread-leading-repo",
                        workspace: leadingRepo,
                        name: "Leading repo review",
                        updatedAt: Date(timeIntervalSince1970: 7_000),
                        status: .active(activeFlags: [])
                    ),
                    .init(
                        id: "thread-uncategorized",
                        name: "Uncategorized review",
                        updatedAt: Date(timeIntervalSince1970: 6_000),
                        status: .idle
                    ),
                    .init(
                        id: "thread-first-repo",
                        workspace: firstRepo,
                        name: "First repo review",
                        updatedAt: Date(timeIntervalSince1970: 5_000),
                        status: .active(activeFlags: [])
                    ),
                    .init(
                        id: "thread-second-repo",
                        workspace: secondRepo,
                        name: "Second repo review",
                        updatedAt: Date(timeIntervalSince1970: 4_000),
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

    @Test func sidebarIgnoresProgrammaticNativeSelectionChanges() async throws {
        let runtime = try await CodexAppServerTestRuntime.start()
        let context = CodexModelContainer(appServer: runtime.server).mainContext
        let repo = try makeGitRepository()
        let activeThreadID = CodexThreadID(rawValue: "thread-active")
        let previousThreadID = CodexThreadID(rawValue: "thread-previous")

        try await runtime.transport.enqueueThreadList(
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

        try await runtime.transport.enqueueThreadList(
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

private struct ThreadListParams: Decodable {
    var sourceKinds: [String]?
}

@MainActor
private func makeCodexSidebarFetchedResultsController(
    context: CodexModelContext
) -> CodexFetchedResultsController<CodexChat> {
    context.fetchedResultsController(
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
