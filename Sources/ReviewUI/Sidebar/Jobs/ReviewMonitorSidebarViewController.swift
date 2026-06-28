import AppKit
import CodexKit
import ObservationBridge
import CodexReviewKit
import SwiftUI

package enum SidebarLayout {
    static let disclosureGutterWidth: CGFloat = 16
}

@MainActor
final class ReviewMonitorSidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    enum SidebarKind: Equatable {
        case unavailable
        case empty
        case chatList
        case accountList
    }

    private enum Identifier {
        static let tableColumn = NSUserInterfaceItemIdentifier("ReviewMonitorReviewChats.Column")
        static let reviewChatCell = NSUserInterfaceItemIdentifier("ReviewMonitorReviewChats.ReviewChatCell")
        static let workspaceCell = NSUserInterfaceItemIdentifier("ReviewMonitorReviewChats.WorkspaceCell")
    }

    private enum DragType {
        static let sidebarItem = NSPasteboard.PasteboardType("dev.codexreviewmcp.sidebar-item")
    }

    private struct SidebarRowHeights {
        let workspace: CGFloat
        let reviewChat: CGFloat

        @MainActor
        static func measure() -> SidebarRowHeights {
            SidebarRowHeights(
                workspace: measuredWorkspaceRowHeight(),
                reviewChat: measuredReviewChatRowHeight()
            )
        }

        @MainActor
        private static func measuredWorkspaceRowHeight() -> CGFloat {
            let cellView = ReviewMonitorWorkspaceCellView()
            cellView.configure(CodexReviewWorkspace(cwd: "/tmp/workspace-alpha"))
            return ceil(cellView.fittingSize.height)
        }

        @MainActor
        private static func measuredReviewChatRowHeight() -> CGFloat {
            let chatID = CodexThreadID(rawValue: "row-height-measurement")
            let chat = ReviewMonitorCodexSidebarSnapshot.Chat(
                rowID: .chat(chatID),
                id: chatID,
                title: "Uncommitted changes",
                preview: "Review output preview",
                model: "gpt-5.5",
                workspaceCWD: "/tmp/workspace",
                updatedAt: Date(timeIntervalSince1970: 0)
            )
            let cellView = ReviewMonitorReviewChatCellView()
            cellView.configure(with: ReviewMonitorCodexSidebarOutlineNode(item: .chat(chat)))
            return ceil(cellView.fittingSize.height)
        }
    }

    private enum SidebarDragPayload: Codable, Equatable {
        case codexSection(id: String)
        case codexChat(id: String, containerRowID: String)
    }

    private struct SidebarResolvedDrop {
        enum Operation {
            case none
            case reorderCodexSection(id: String, beforeID: String?)
            case reorderCodexChat(
                id: CodexThreadID,
                container: ReviewMonitorCodexSidebarRowID,
                currentOrder: [CodexThreadID],
                beforeID: CodexThreadID?
            )
        }

        let operation: Operation
        let dropItem: Any?
        let dropChildIndex: Int
    }

    private struct SidebarCodexChatDropDestination {
        let container: ReviewMonitorCodexSidebarRowID
        let childIndex: Int
        let dropItem: Any?
        let dropChildIndex: Int
    }

    private let store: CodexReviewStore
    private let uiState: ReviewMonitorUIState
    private let codexModelSource: ReviewMonitorCodexModelSource?
    private let previewChatLogSource: ReviewMonitorPreviewChatLogSource?
    private let scrollView = NSScrollView()
    private let outlineView = ReviewMonitorSidebarOutlineView()
    private let accountsViewController: ReviewMonitorAccountsViewController
    private let emptyStateViewController = PlaceholderViewController(content: .noReviewChats)
    private let unavailableView: NSHostingView<MCPServerUnavailableView>
    private let rowHeights: SidebarRowHeights

    private var sidebarKindObservation: PortableObservationTracking.Token?
    private var sidebarFilterObservation: PortableObservationTracking.Token?
    private var codexSidebarObservation: PortableObservationTracking.Token?
    private var codexSidebarSnapshotObservation: PortableObservationTracking.Token?
    private var selectedChatSnapshotObservation: PortableObservationTracking.Token?
    private var codexSidebarFetchTask: Task<Void, Never>?
    private var codexSidebarLibrary: ReviewMonitorCodexSidebarLibrary?
    private var codexSidebarModelContext: CodexModelContext?
    private var codexSidebarUnfilteredSnapshot = ReviewMonitorCodexSidebarSnapshot(sections: [])
    private var codexSidebarPresentationOrder = ReviewMonitorCodexSidebarPresentationOrder()
    private let codexSidebarOutlineTree = ReviewMonitorCodexSidebarOutlineTree()
    private var appliedSidebarKind: SidebarKind?
    private var isReconcilingSelection = false
    #if DEBUG
        private var fullReloadCountForTesting = 0
    #endif

    init(
        store: CodexReviewStore,
        uiState: ReviewMonitorUIState,
        codexModelSource: ReviewMonitorCodexModelSource? = nil,
        previewChatLogSource: ReviewMonitorPreviewChatLogSource? = nil
    ) {
        self.store = store
        self.uiState = uiState
        self.codexModelSource = codexModelSource
        self.previewChatLogSource = previewChatLogSource
        self.accountsViewController = ReviewMonitorAccountsViewController(store: store)
        self.unavailableView = NSHostingView(rootView: MCPServerUnavailableView(store: store))
        self.rowHeights = SidebarRowHeights.measure()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        sidebarKindObservation?.cancel()
        sidebarFilterObservation?.cancel()
        codexSidebarObservation?.cancel()
        codexSidebarSnapshotObservation?.cancel()
        selectedChatSnapshotObservation?.cancel()
        codexSidebarFetchTask?.cancel()
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        configureOutlineView()
        applyPreviewCodexSidebarSnapshotIfNeeded()
        bindObservation()
        bindCodexSidebarLibrary()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
    }

    private func configureHierarchy() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        view.addSubview(scrollView)
        addChild(emptyStateViewController)
        emptyStateViewController.view.translatesAutoresizingMaskIntoConstraints = false
        emptyStateViewController.view.isHidden = true
        view.addSubview(emptyStateViewController.view)
        addChild(accountsViewController)
        accountsViewController.view.translatesAutoresizingMaskIntoConstraints = false
        accountsViewController.view.isHidden = true
        view.addSubview(accountsViewController.view)
        unavailableView.translatesAutoresizingMaskIntoConstraints = false
        unavailableView.isHidden = true
        view.addSubview(unavailableView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyStateViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            emptyStateViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyStateViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyStateViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            accountsViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            accountsViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            accountsViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            accountsViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            unavailableView.topAnchor.constraint(equalTo: view.topAnchor),
            unavailableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            unavailableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            unavailableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureOutlineView() {
        let tableColumn = NSTableColumn(identifier: Identifier.tableColumn)
        tableColumn.resizingMask = .autoresizingMask

        outlineView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        outlineView.autoresizingMask = [.width]
        outlineView.addTableColumn(tableColumn)
        outlineView.outlineTableColumn = tableColumn
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.indentationPerLevel = SidebarLayout.disclosureGutterWidth
        outlineView.indentationMarkerFollowsCell = false
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = rowHeights.reviewChat
        outlineView.usesAutomaticRowHeights = false
        outlineView.floatsGroupRows = false
        outlineView.backgroundColor = .clear
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.intercellSpacing = NSSize(width: 0, height: 12)
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.setAccessibilityIdentifier("review-monitor.review-chat-list")
        outlineView.registerForDraggedTypes([DragType.sidebarItem])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask([], forLocal: false)
        outlineView.draggingDestinationFeedbackStyle = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.contextMenuProvider = { [weak self] point in
            self?.makeContextMenu(at: point)
        }
        outlineView.draggingExitedHandler = { [weak self] in
            self?.clearDropTarget()
        }

        scrollView.documentView = outlineView
    }

    private func bindObservation() {
        sidebarKindObservation?.cancel()
        sidebarFilterObservation?.cancel()
        selectedChatSnapshotObservation?.cancel()

        sidebarKindObservation = withPortableContinuousObservation { [weak self, uiState, store] _ in
            let sidebarSelection = uiState.sidebarSelection
            let serverState = store.serverState
            guard let self else {
                return
            }
            self.applySidebarKind(
                Self.sidebarKind(
                    sidebarSelection: sidebarSelection,
                    serverState: serverState,
                    hasCodexSidebarContent: self.hasCodexSidebarContent
                ))
        }

        sidebarFilterObservation = withPortableContinuousObservation { [weak self, uiState] event in
            _ = uiState.sidebarReviewChatFilter
            guard event.kind != .initial else {
                return
            }
            self?.applyFilteredCodexSidebarSnapshot()
        }

        selectedChatSnapshotObservation = withPortableContinuousObservation { [weak self, uiState] _ in
            guard let self,
                case .chat(let selectedChat) = uiState.selection
            else {
                return
            }
            guard self.hasCodexSidebarContent else {
                return
            }
            guard let currentChat = self.currentChatSelection(id: selectedChat.id) else {
                uiState.selection = nil
                return
            }
            guard currentChat != selectedChat else {
                return
            }
            uiState.selection = .chat(currentChat)
        }
    }

    private func bindCodexSidebarLibrary() {
        guard let codexModelSource else {
            return
        }
        codexSidebarObservation?.cancel()
        codexSidebarObservation = withPortableContinuousObservation { [weak self, codexModelSource] _ in
            _ = codexModelSource.generation
            self?.installCodexSidebarLibrary(modelContext: codexModelSource.modelContext)
        }
    }

    private func installCodexSidebarLibrary(modelContext: CodexModelContext?) {
        if let modelContext,
            let codexSidebarModelContext,
            codexSidebarModelContext === modelContext,
            codexSidebarLibrary != nil
        {
            return
        }
        codexSidebarFetchTask?.cancel()
        codexSidebarFetchTask = nil
        codexSidebarSnapshotObservation?.cancel()
        codexSidebarSnapshotObservation = nil
        guard let modelContext else {
            codexSidebarModelContext = nil
            codexSidebarLibrary = nil
            applyPreviewCodexSidebarSnapshotIfNeeded()
            return
        }

        let library = ReviewMonitorCodexSidebarLibrary(modelContext: modelContext)
        codexSidebarModelContext = modelContext
        codexSidebarLibrary = library
        codexSidebarSnapshotObservation = withPortableContinuousObservation { [weak self, library] event in
            guard let self,
                self.codexSidebarLibrary === library
            else {
                return
            }
            let snapshot = library.snapshot
            guard event.kind != .initial else {
                return
            }
            self.applyCodexSidebarSnapshot(snapshot)
        }
        codexSidebarFetchTask = Task { @MainActor [weak self, library] in
            do {
                try await library.performFetch()
            } catch is CancellationError {
            } catch {
            }
            guard self?.codexSidebarLibrary === library else {
                return
            }
            self?.applyCodexSidebarSnapshot(library.snapshot)
            self?.codexSidebarFetchTask = nil
        }
    }

    private func applyPreviewCodexSidebarSnapshotIfNeeded() {
        if let previewChatLogSource {
            applyCodexSidebarSnapshot(previewChatLogSource.snapshot)
        } else {
            applyCodexSidebarSnapshot(ReviewMonitorCodexSidebarSnapshot(sections: []))
        }
    }

    private func applyCodexSidebarSnapshot(_ snapshot: ReviewMonitorCodexSidebarSnapshot) {
        codexSidebarUnfilteredSnapshot = snapshot
        codexSidebarPresentationOrder.prune(to: snapshot)
        applyFilteredCodexSidebarSnapshot()
    }

    private func applyFilteredCodexSidebarSnapshot() {
        let snapshot =
            codexSidebarPresentationOrder
            .applying(to: codexSidebarUnfilteredSnapshot)
            .filtered(by: uiState.sidebarReviewChatFilter)
        let wasUsingCodexSidebarOutline = isUsingCodexSidebarOutline
        let applyResult = codexSidebarOutlineTree.apply(snapshot: snapshot)
        applySidebarKind(sidebarKind)
        guard wasUsingCodexSidebarOutline || isUsingCodexSidebarOutline else {
            return
        }
        if applyResult.topologyChanged {
            applyCodexSidebarOutlineTopologyChanges(applyResult.topologyChanges)
        } else if isUsingCodexSidebarOutline {
            reconcileOutlineSelection()
        }
    }

    private func applyCodexSidebarOutlineTopologyChanges(
        _ changes: [ReviewMonitorCodexSidebarOutlineTopologyChange]
    ) {
        guard changes.isEmpty == false else {
            reconcileOutlineSelection()
            return
        }

        isReconcilingSelection = true
        var appliedIncrementally = true
        for change in changes {
            guard applyCodexSidebarOutlineTopologyChange(change) else {
                appliedIncrementally = false
                break
            }
        }
        if appliedIncrementally {
            expandCodexSidebarNodes(codexSidebarOutlineTree.roots)
            if isUsingCodexSidebarOutline {
                reconcileOutlineSelection()
            } else if outlineView.selectedRow != -1 {
                outlineView.deselectAll(nil)
            }
            isReconcilingSelection = false
        } else {
            isReconcilingSelection = false
            reloadCodexSidebarOutline()
        }
    }

    private func applyCodexSidebarOutlineTopologyChange(
        _ change: ReviewMonitorCodexSidebarOutlineTopologyChange
    ) -> Bool {
        let parentItem: Any?
        if let parentRowID = change.parentRowID {
            guard let parentNode = codexSidebarOutlineTree.node(rowID: parentRowID) else {
                return false
            }
            parentItem = parentNode
        } else {
            parentItem = nil
        }
        if applyCodexSidebarOutlineChildDelta(change, parentItem: parentItem) {
            return true
        }
        guard let parentItem else {
            return false
        }
        outlineView.reloadItem(parentItem, reloadChildren: true)
        return true
    }

    private func applyCodexSidebarOutlineChildDelta(
        _ change: ReviewMonitorCodexSidebarOutlineTopologyChange,
        parentItem: Any?
    ) -> Bool {
        let oldChildRowIDs = change.oldChildRowIDs
        let newChildRowIDs = change.newChildRowIDs
        guard oldChildRowIDs != newChildRowIDs else {
            return true
        }

        let oldChildRowIDSet = Set(oldChildRowIDs)
        let newChildRowIDSet = Set(newChildRowIDs)
        if oldChildRowIDSet == newChildRowIDSet {
            return moveCodexSidebarOutlineItems(
                from: oldChildRowIDs,
                to: newChildRowIDs,
                parentItem: parentItem
            )
        }

        let retainedOldChildRowIDs = oldChildRowIDs.filter { newChildRowIDSet.contains($0) }
        let retainedNewChildRowIDs = newChildRowIDs.filter { oldChildRowIDSet.contains($0) }
        guard retainedOldChildRowIDs == retainedNewChildRowIDs else {
            return false
        }

        let removedIndexes = oldChildRowIDs.enumerated().compactMap { offset, rowID in
            newChildRowIDSet.contains(rowID) ? nil : offset
        }
        if removedIndexes.isEmpty == false {
            outlineView.removeItems(
                at: IndexSet(removedIndexes),
                inParent: parentItem,
                withAnimation: []
            )
        }

        let insertedIndexes = newChildRowIDs.enumerated().compactMap { offset, rowID in
            oldChildRowIDSet.contains(rowID) ? nil : offset
        }
        if insertedIndexes.isEmpty == false {
            outlineView.insertItems(
                at: IndexSet(insertedIndexes),
                inParent: parentItem,
                withAnimation: []
            )
        }
        return true
    }

    private func moveCodexSidebarOutlineItems(
        from oldChildRowIDs: [ReviewMonitorCodexSidebarRowID],
        to newChildRowIDs: [ReviewMonitorCodexSidebarRowID],
        parentItem: Any?
    ) -> Bool {
        var currentChildRowIDs = oldChildRowIDs
        for targetIndex in newChildRowIDs.indices {
            let targetRowID = newChildRowIDs[targetIndex]
            guard let currentIndex = currentChildRowIDs.firstIndex(of: targetRowID) else {
                return false
            }
            guard currentIndex != targetIndex else {
                continue
            }
            outlineView.moveItem(
                at: currentIndex,
                inParent: parentItem,
                to: targetIndex,
                inParent: parentItem
            )
            let movedRowID = currentChildRowIDs.remove(at: currentIndex)
            currentChildRowIDs.insert(movedRowID, at: targetIndex)
        }
        return currentChildRowIDs == newChildRowIDs
    }

    private func reloadCodexSidebarOutline() {
        #if DEBUG
            fullReloadCountForTesting += 1
        #endif
        isReconcilingSelection = true
        outlineView.reloadData()
        expandCodexSidebarNodes(codexSidebarOutlineTree.roots)
        if isUsingCodexSidebarOutline {
            reconcileOutlineSelection()
        } else if outlineView.selectedRow != -1 {
            outlineView.deselectAll(nil)
        }
        isReconcilingSelection = false
    }

    private func expandCodexSidebarNodes(_ nodes: [ReviewMonitorCodexSidebarOutlineNode]) {
        for node in nodes where node.isExpandable {
            outlineView.expandItem(node)
            expandCodexSidebarNodes(node.children)
        }
    }

    private var sidebarKind: SidebarKind {
        Self.sidebarKind(
            sidebarSelection: uiState.sidebarSelection,
            serverState: store.serverState,
            hasCodexSidebarContent: hasCodexSidebarContent
        )
    }

    private static func sidebarKind(
        sidebarSelection: SidebarPickerSelection?,
        serverState: CodexReviewServerState,
        hasCodexSidebarContent: Bool
    ) -> SidebarKind {
        if sidebarSelection == .account {
            return .accountList
        }
        switch serverState {
        case .failed, .starting, .stopped:
            return .unavailable
        case .running:
            break
        }
        return hasCodexSidebarContent ? .chatList : .empty
    }

    private var hasCodexSidebarContent: Bool {
        codexSidebarOutlineTree.roots.isEmpty == false
    }

    private var isUsingCodexSidebarOutline: Bool {
        true
    }

    private func applySidebarKind(_ kind: SidebarKind) {
        guard appliedSidebarKind != kind else {
            return
        }
        appliedSidebarKind = kind
        switch kind {
        case .unavailable:
            unavailableView.isHidden = false
            scrollView.isHidden = true
            emptyStateViewController.view.isHidden = true
            accountsViewController.view.isHidden = true
        case .empty:
            unavailableView.isHidden = true
            scrollView.isHidden = true
            emptyStateViewController.view.isHidden = false
            accountsViewController.view.isHidden = true
        case .chatList:
            unavailableView.isHidden = true
            scrollView.isHidden = false
            emptyStateViewController.view.isHidden = true
            accountsViewController.view.isHidden = true
        case .accountList:
            unavailableView.isHidden = true
            scrollView.isHidden = true
            emptyStateViewController.view.isHidden = true
            accountsViewController.view.isHidden = false
        }
    }

    private func reconcileOutlineSelection() {
        guard let selection = uiState.selection else {
            if outlineView.selectedRow != -1 {
                outlineView.deselectAll(nil)
            }
            return
        }

        switch selection {
        case .workspaceSection(let selectedSection):
            guard let currentSection = codexWorkspaceSectionSelection(id: selectedSection.id),
                let row = row(forCodexSidebarSelectionID: .workspaceSection(selectedSection.id))
            else {
                uiState.selection = nil
                outlineView.deselectAll(nil)
                return
            }

            if currentSection.selection != selectedSection {
                uiState.selection = .workspaceSection(currentSection.selection)
            }

            guard outlineView.selectedRow != row else {
                return
            }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        case .workspace(let selectedWorkspace):
            guard let currentWorkspace = codexWorkspaceSelection(id: selectedWorkspace.id),
                let row = row(forCodexSidebarSelectionID: .workspace(selectedWorkspace.id))
            else {
                uiState.selection = nil
                outlineView.deselectAll(nil)
                return
            }

            if currentWorkspace != selectedWorkspace {
                uiState.selection = .workspace(currentWorkspace)
            }

            guard outlineView.selectedRow != row else {
                return
            }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        case .chat(let selectedChat):
            guard let currentChat = currentChatSelection(id: selectedChat.id)
            else {
                uiState.selection = nil
                outlineView.deselectAll(nil)
                return
            }

            if currentChat != selectedChat {
                uiState.selection = .chat(currentChat)
            }

            guard let row = row(forCurrentChatSelectionID: selectedChat.id)
            else {
                return
            }

            guard outlineView.selectedRow != row else {
                return
            }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        }
    }

    private func updateSelectionFromOutlineView() {
        guard isReconcilingSelection == false else {
            return
        }
        guard outlineView.selectedRow != -1 else {
            if selectionStillExists(uiState.selection) {
                return
            }
            uiState.selection = nil
            return
        }
        let item = outlineView.item(atRow: outlineView.selectedRow)
        if let node = codexSidebarNode(from: item) {
            switch node.item {
            case .section(let section):
                uiState.selection = .workspaceSection(section.selection)
            case .workspace(let workspace):
                uiState.selection = .workspace(workspace)
            case .chat(let chat):
                uiState.selection = .chat(chat)
            }
        } else {
            uiState.selection = nil
        }
    }

    private func makeContextMenu(at point: NSPoint) -> NSMenu? {
        let row = outlineView.row(at: point)
        guard row >= 0,
            let node = codexSidebarNode(from: outlineView.item(atRow: row)),
            case .chat(let chat) = node.item
        else {
            return nil
        }

        let menu = NSMenu()
        if let job = cancellableReviewRun(for: chat) {
            let item = NSMenuItem(
                title: "Cancel Review",
                action: #selector(cancelReviewFromContextMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = job.id
            menu.addItem(item)
        }
        return menu.items.isEmpty ? nil : menu
    }

    private func cancellableReviewRun(
        for chat: ReviewMonitorCodexSidebarSnapshot.Chat
    ) -> ReviewRunRecord? {
        store.orderedReviewRuns.first { job in
            guard job.isTerminal == false,
                let chatID = job.sidebarChatID
            else {
                return false
            }
            return chatID == chat.id
        }
    }

    @objc
    private func cancelReviewFromContextMenu(_ sender: NSMenuItem) {
        guard let runID = sender.representedObject as? String else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                _ = try await self.store.cancelReview(
                    runID: runID,
                    cancellation: .userInterface()
                )
            } catch {
                guard let job = self.store.reviewRun(id: runID) else {
                    return
                }
                try? self.store.recordCancellationFailure(
                    runID: runID,
                    sessionID: job.sessionID,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func codexSidebarNode(from item: Any?) -> ReviewMonitorCodexSidebarOutlineNode? {
        item as? ReviewMonitorCodexSidebarOutlineNode
    }

    private func shouldAllowSelection(of item: Any?) -> Bool {
        if codexSidebarNode(from: item) != nil {
            return true
        }
        return false
    }

    private func row(for workspace: CodexReviewWorkspace) -> Int? {
        row(forCodexSidebarSelectionID: .workspace(CodexWorkspaceID(rawValue: workspace.cwd)))
            ?? row(forCodexSidebarSelectionID: .workspaceSection(workspace.cwd))
    }

    private func row(for chatID: CodexThreadID) -> Int? {
        row(forCodexSidebarSelectionID: .chat(chatID))
    }

    private func row(forCurrentChatSelectionID chatID: CodexThreadID) -> Int? {
        row(forCodexSidebarSelectionID: .chat(chatID))
    }

    private func row(forCodexSidebarSelectionID selectionID: ReviewMonitorSelectionID) -> Int? {
        let rowID: ReviewMonitorCodexSidebarRowID
        switch selectionID {
        case .workspace(let id):
            rowID = .workspace(id)
        case .chat(let id):
            rowID = .chat(id)
        case .workspaceSection(let id):
            rowID = .section(id)
        }
        guard let node = codexSidebarOutlineTree.node(rowID: rowID) else {
            return nil
        }
        let row = outlineView.row(forItem: node)
        return row == -1 ? nil : row
    }

    private func selectionStillExists(_ selection: ReviewMonitorSelection?) -> Bool {
        guard let selection else {
            return true
        }
        switch selection {
        case .workspaceSection(let section):
            return codexWorkspaceSectionSelection(id: section.id) != nil
        case .workspace(let workspace):
            return codexWorkspaceSelection(id: workspace.id) != nil
        case .chat(let chat):
            return currentChatSelection(id: chat.id) != nil
        }
    }

    private func currentChatSelection(id: CodexThreadID) -> ReviewMonitorCodexSidebarSnapshot.Chat? {
        codexSidebarUnfilteredSnapshot.chat(id: id)
    }

    private func codexWorkspaceSelection(
        id: CodexWorkspaceID
    ) -> ReviewMonitorCodexSidebarSnapshot.Workspace? {
        guard let node = codexSidebarOutlineTree.node(rowID: .workspace(id)),
            case .workspace(let workspace) = node.item
        else {
            return nil
        }
        return workspace
    }

    private func codexWorkspaceSectionSelection(
        id: String
    ) -> ReviewMonitorCodexSidebarSnapshot.Section? {
        guard let node = codexSidebarOutlineTree.node(rowID: .section(id)),
            case .section(let section) = node.item
        else {
            return nil
        }
        return section
    }

    private func codexChatSelection(id: CodexThreadID) -> ReviewMonitorCodexSidebarSnapshot.Chat? {
        guard let node = codexSidebarOutlineTree.node(rowID: .chat(id)),
            case .chat(let chat) = node.item
        else {
            return nil
        }
        return chat
    }

    private func dragPayload(for item: Any) -> SidebarDragPayload? {
        guard let node = codexSidebarNode(from: item) else {
            return nil
        }
        switch node.item {
        case .section(let section):
            return .codexSection(id: section.id)
        case .workspace:
            return nil
        case .chat(let chat):
            guard let parent = outlineView.parent(forItem: node) as? ReviewMonitorCodexSidebarOutlineNode else {
                return nil
            }
            return .codexChat(id: chat.id.rawValue, containerRowID: parent.rowID.rawValue)
        }
    }

    private func makePasteboardItem(for payload: SidebarDragPayload) -> NSPasteboardItem? {
        guard let data = try? JSONEncoder().encode(payload) else {
            return nil
        }
        let item = NSPasteboardItem()
        item.setData(data, forType: DragType.sidebarItem)
        return item
    }

    private func dragPayload(from draggingInfo: any NSDraggingInfo) -> SidebarDragPayload? {
        guard let draggingSource = draggingInfo.draggingSource as? NSOutlineView,
            draggingSource === outlineView,
            let data = draggingInfo.draggingPasteboard.data(forType: DragType.sidebarItem)
        else {
            return nil
        }
        return try? JSONDecoder().decode(SidebarDragPayload.self, from: data)
    }

    private func clearDropTarget() {
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
    }

    private func resolvedDrop(
        for payload: SidebarDragPayload,
        draggingLocation: NSPoint? = nil,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> SidebarResolvedDrop? {
        switch payload {
        case .codexSection(let id):
            resolvedCodexSectionDrop(
                id: id,
                draggingLocation: draggingLocation,
                proposedItem: proposedItem,
                proposedChildIndex: index
            )
        case .codexChat(let id, let containerRowID):
            resolvedCodexChatDrop(
                id: CodexThreadID(rawValue: id),
                container: ReviewMonitorCodexSidebarRowID(rawValue: containerRowID),
                draggingLocation: draggingLocation,
                proposedItem: proposedItem,
                proposedChildIndex: index
            )
        }
    }

    private func resolvedCodexSectionDrop(
        id: String,
        draggingLocation: NSPoint?,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> SidebarResolvedDrop? {
        guard let sourceNode = codexSidebarOutlineTree.node(rowID: .section(id)),
            let sourceIndex = codexRootIndex(for: sourceNode),
            let destinationIndex = codexRootInsertionIndex(
                draggingLocation: draggingLocation,
                proposedItem: proposedItem,
                proposedChildIndex: index
            )
        else {
            return nil
        }

        let clampedDestinationIndex = max(0, min(destinationIndex, codexSidebarOutlineTree.roots.count))
        let displayDestinationIndex =
            clampedDestinationIndex > sourceIndex
            ? clampedDestinationIndex - 1
            : clampedDestinationIndex
        guard displayDestinationIndex != sourceIndex else {
            return nil
        }

        let remainingRoots = codexSidebarOutlineTree.roots.filter { $0 !== sourceNode }
        let beforeID: String?
        if displayDestinationIndex < remainingRoots.count,
            case .section(let section) = remainingRoots[displayDestinationIndex].item
        {
            beforeID = section.id
        } else {
            beforeID = nil
        }

        return SidebarResolvedDrop(
            operation: .reorderCodexSection(id: id, beforeID: beforeID),
            dropItem: nil,
            dropChildIndex: clampedDestinationIndex
        )
    }

    private func resolvedCodexChatDrop(
        id: CodexThreadID,
        container: ReviewMonitorCodexSidebarRowID,
        draggingLocation: NSPoint?,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> SidebarResolvedDrop? {
        guard uiState.sidebarReviewChatFilter.allowsReviewChatReordering,
            let destination = resolvedCodexChatDropDestination(
                sourceContainer: container,
                draggingLocation: draggingLocation,
                proposedItem: proposedItem,
                proposedChildIndex: index
            ),
            destination.container == container
        else {
            return nil
        }

        let currentOrder = codexUnfilteredChatIDs(in: container)
        let visibleOrder = codexVisibleChatIDs(in: container)
        guard currentOrder.contains(id),
            let visibleSourceIndex = visibleOrder.firstIndex(of: id)
        else {
            return nil
        }

        let visibleInsertionIndex = max(0, min(destination.childIndex, visibleOrder.count))
        let beforeID = codexChatBeforeID(
            movingID: id,
            visibleInsertionIndex: visibleInsertionIndex,
            visibleOrder: visibleOrder,
            currentOrder: currentOrder
        )
        let displayDestinationIndex =
            visibleInsertionIndex > visibleSourceIndex
            ? visibleInsertionIndex - 1
            : visibleInsertionIndex
        guard displayDestinationIndex != visibleSourceIndex || beforeID == nil else {
            return nil
        }

        return SidebarResolvedDrop(
            operation: .reorderCodexChat(
                id: id,
                container: container,
                currentOrder: currentOrder,
                beforeID: beforeID
            ),
            dropItem: destination.dropItem,
            dropChildIndex: destination.dropChildIndex
        )
    }

    private func resolvedCodexChatDropDestination(
        sourceContainer: ReviewMonitorCodexSidebarRowID,
        draggingLocation: NSPoint?,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> SidebarCodexChatDropDestination? {
        if let containerNode = codexSidebarNode(from: proposedItem),
            isCodexChatContainer(containerNode),
            index != NSOutlineViewDropOnItemIndex
        {
            let childIndex = max(0, min(index, codexVisibleChatIDs(in: containerNode.rowID).count))
            return SidebarCodexChatDropDestination(
                container: containerNode.rowID,
                childIndex: childIndex,
                dropItem: containerNode,
                dropChildIndex: childIndex
            )
        }

        guard let targetNode = codexSidebarNode(from: proposedItem),
            case .chat(let targetChat) = targetNode.item,
            index == NSOutlineViewDropOnItemIndex,
            let parentNode = outlineView.parent(forItem: targetNode) as? ReviewMonitorCodexSidebarOutlineNode,
            parentNode.rowID == sourceContainer,
            let targetIndex = codexVisibleChatIDs(in: parentNode.rowID).firstIndex(of: targetChat.id),
            let draggingLocation,
            let targetRow = row(forCodexSidebarSelectionID: .chat(targetChat.id))
        else {
            return nil
        }

        let targetRowRect = outlineView.rect(ofRow: targetRow)
        let childIndex = targetIndex + (draggingLocation.y < targetRowRect.midY ? 0 : 1)
        return SidebarCodexChatDropDestination(
            container: parentNode.rowID,
            childIndex: childIndex,
            dropItem: parentNode,
            dropChildIndex: childIndex
        )
    }

    private func codexRootInsertionIndex(
        draggingLocation: NSPoint?,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> Int? {
        if proposedItem == nil,
            index != NSOutlineViewDropOnItemIndex
        {
            return max(0, min(index, codexSidebarOutlineTree.roots.count))
        }

        if let draggingLocation,
            outlineView.numberOfRows > 0
        {
            let firstRowRect = outlineView.rect(ofRow: 0)
            if draggingLocation.y < firstRowRect.minY {
                return 0
            }
            let lastRowRect = outlineView.rect(ofRow: outlineView.numberOfRows - 1)
            if draggingLocation.y > lastRowRect.maxY {
                return codexSidebarOutlineTree.roots.count
            }
        }

        guard let targetRoot = codexRootNode(for: proposedItem),
            let targetIndex = codexRootIndex(for: targetRoot)
        else {
            return nil
        }

        guard let draggingLocation,
            let targetRect = codexRootRect(for: targetRoot)
        else {
            return targetIndex
        }
        return draggingLocation.y < targetRect.midY ? targetIndex : targetIndex + 1
    }

    private func codexRootNode(for item: Any?) -> ReviewMonitorCodexSidebarOutlineNode? {
        guard var node = codexSidebarNode(from: item) else {
            return nil
        }
        while let parent = outlineView.parent(forItem: node) as? ReviewMonitorCodexSidebarOutlineNode {
            node = parent
        }
        return node
    }

    private func codexRootIndex(for node: ReviewMonitorCodexSidebarOutlineNode) -> Int? {
        codexSidebarOutlineTree.roots.firstIndex { $0 === node }
    }

    private func codexRootRect(for root: ReviewMonitorCodexSidebarOutlineNode) -> NSRect? {
        guard let rootRow = row(forCodexSidebarSelectionID: root.selectionID) else {
            return nil
        }
        var rect = outlineView.rect(ofRow: rootRow)
        for descendant in codexVisibleDescendants(of: root) {
            let row = outlineView.row(forItem: descendant)
            if row != -1 {
                rect = rect.union(outlineView.rect(ofRow: row))
            }
        }
        return rect
    }

    private func codexVisibleDescendants(
        of node: ReviewMonitorCodexSidebarOutlineNode
    ) -> [ReviewMonitorCodexSidebarOutlineNode] {
        guard outlineView.isItemExpanded(node) else {
            return []
        }
        return node.children.flatMap { child in
            [child] + codexVisibleDescendants(of: child)
        }
    }

    private func isCodexChatContainer(_ node: ReviewMonitorCodexSidebarOutlineNode) -> Bool {
        switch node.item {
        case .section(let section):
            return section.uncategorizedChats.isEmpty == false
        case .workspace:
            return true
        case .chat:
            return false
        }
    }

    private func codexVisibleChatIDs(in container: ReviewMonitorCodexSidebarRowID) -> [CodexThreadID] {
        guard let node = codexSidebarOutlineTree.node(rowID: container) else {
            return []
        }
        return node.children.compactMap { child in
            if case .chat(let chat) = child.item {
                return chat.id
            }
            return nil
        }
    }

    private func codexUnfilteredChatIDs(in container: ReviewMonitorCodexSidebarRowID) -> [CodexThreadID] {
        for section in codexSidebarUnfilteredSnapshot.sections {
            if section.rowID == container {
                return section.uncategorizedChats.map(\.id)
            }
            for workspace in section.workspaces where workspace.rowID == container {
                return workspace.chats.map(\.id)
            }
        }
        return []
    }

    private func codexChatBeforeID(
        movingID: CodexThreadID,
        visibleInsertionIndex: Int,
        visibleOrder: [CodexThreadID],
        currentOrder: [CodexThreadID]
    ) -> CodexThreadID? {
        if visibleInsertionIndex < visibleOrder.count {
            let targetID = visibleOrder[visibleInsertionIndex]
            return targetID == movingID ? movingID : targetID
        }
        guard let lastVisibleID = visibleOrder.last,
            let lastVisibleIndex = currentOrder.firstIndex(of: lastVisibleID)
        else {
            return nil
        }
        let nextIndex = lastVisibleIndex + 1
        guard nextIndex < currentOrder.count,
            currentOrder[nextIndex] != movingID
        else {
            return nil
        }
        return currentOrder[nextIndex]
    }

    @discardableResult
    private func applyResolvedDrop(_ resolvedDrop: SidebarResolvedDrop) -> Bool {
        switch resolvedDrop.operation {
        case .none:
            return false
        case .reorderCodexSection(let id, let beforeID):
            guard codexSidebarPresentationOrder.reorderSection(id: id, before: beforeID) else {
                return false
            }
            applyFilteredCodexSidebarSnapshot()
            return true
        case .reorderCodexChat(let id, let container, let currentOrder, let beforeID):
            guard
                codexSidebarPresentationOrder.reorderChat(
                    id: id,
                    in: container,
                    currentOrder: currentOrder,
                    before: beforeID
                )
            else {
                return false
            }
            applyFilteredCodexSidebarSnapshot()
            return true
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else {
            return codexSidebarOutlineTree.roots.count
        }
        if let node = codexSidebarNode(from: item) {
            return node.children.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else {
            return codexSidebarOutlineTree.roots[index]
        }
        if let node = codexSidebarNode(from: item) {
            return node.children[index]
        }
        fatalError("Unsupported Codex sidebar item.")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let node = codexSidebarNode(from: item) {
            return node.isExpandable
        }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if let node = codexSidebarNode(from: item) {
            if case .chat = node.item {
                return rowHeights.reviewChat
            }
            return rowHeights.workspace
        }
        return rowHeights.reviewChat
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        shouldAllowSelection(of: item)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        pasteboardWriterForItem item: Any
    ) -> (any NSPasteboardWriting)? {
        guard let payload = dragPayload(for: item) else {
            return nil
        }
        return makePasteboardItem(for: payload)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        let draggingLocation = outlineView.convert(info.draggingLocation, from: nil)
        guard let payload = dragPayload(from: info),
            let resolvedDrop = resolvedDrop(
                for: payload,
                draggingLocation: draggingLocation,
                proposedItem: item,
                proposedChildIndex: index
            )
        else {
            clearDropTarget()
            return []
        }

        outlineView.setDropItem(resolvedDrop.dropItem, dropChildIndex: resolvedDrop.dropChildIndex)
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: any NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        defer {
            clearDropTarget()
        }
        let draggingLocation = outlineView.convert(info.draggingLocation, from: nil)
        guard let payload = dragPayload(from: info),
            let resolvedDrop = resolvedDrop(
                for: payload,
                draggingLocation: draggingLocation,
                proposedItem: item,
                proposedChildIndex: index
            )
        else {
            return false
        }
        info.animatesToDestination = false
        return applyResolvedDrop(resolvedDrop)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateSelectionFromOutlineView()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        _ = notification
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        _ = notification
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        if let node = codexSidebarNode(from: item) {
            if case .chat = node.item {
                return ReviewMonitorReviewChatTableRowView()
            }
            return ReviewMonitorWorkspaceRowView()
        }
        return nil
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        if let node = codexSidebarNode(from: item) {
            if case .chat = node.item {
                let view =
                    (outlineView.makeView(withIdentifier: Identifier.reviewChatCell, owner: self)
                        as? ReviewMonitorReviewChatCellView)
                    ?? ReviewMonitorReviewChatCellView()
                view.identifier = Identifier.reviewChatCell
                view.configure(with: node)
                return view
            }

            let view =
                (outlineView.makeView(withIdentifier: Identifier.workspaceCell, owner: self)
                    as? ReviewMonitorWorkspaceCellView)
                ?? ReviewMonitorWorkspaceCellView()
            view.identifier = Identifier.workspaceCell
            view.configure(with: node)
            return view
        }

        return nil
    }

}

#if DEBUG
    @MainActor
    extension ReviewMonitorSidebarViewController {
        var sidebarKindObservationForTesting: PortableObservationTracking.Token? {
            sidebarKindObservation
        }

        var sidebarFilterObservationForTesting: PortableObservationTracking.Token? {
            sidebarFilterObservation
        }

        var sidebarKindForTesting: SidebarKind {
            sidebarKind
        }

        var accountsViewControllerForTesting: ReviewMonitorAccountsViewController {
            accountsViewController.loadViewIfNeeded()
            return accountsViewController
        }

        var displayedSectionTitlesForTesting: [String] {
            codexSidebarRootTitlesForTesting
        }

        var selectedReviewChatIDForTesting: CodexThreadID? {
            guard case .chat(let chat) = uiState.selection else {
                return nil
            }
            return chat.id
        }

        var selectedWorkspaceSectionForTesting: ReviewMonitorWorkspaceSectionSelection? {
            uiState.selectedWorkspaceSectionEntry
        }

        var codexSidebarSnapshotForTesting: ReviewMonitorCodexSidebarSnapshot? {
            codexSidebarLibrary?.snapshot
        }

        var codexSidebarRootTitlesForTesting: [String] {
            codexSidebarOutlineTree.roots.map(\.title)
        }

        var displayedCodexSidebarTitlesForTesting: [String] {
            (0..<outlineView.numberOfRows).compactMap { row in
                codexSidebarNode(from: outlineView.item(atRow: row))?.title
            }
        }

        func codexSidebarNodeTitleForTesting(rowID: ReviewMonitorCodexSidebarRowID) -> String? {
            codexSidebarOutlineTree.node(rowID: rowID)?.title
        }

        func displayedCodexChatIDsForTesting(container: ReviewMonitorCodexSidebarRowID) -> [CodexThreadID] {
            codexVisibleChatIDs(in: container)
        }

        func codexSidebarCanStartDragForTesting(rowID: ReviewMonitorCodexSidebarRowID) -> Bool {
            guard let node = codexSidebarOutlineTree.node(rowID: rowID) else {
                return false
            }
            return dragPayload(for: node) != nil
        }

        @discardableResult
        func performCodexSectionDropForTesting(id: String, toIndex index: Int) -> Bool {
            guard
                let resolvedDrop = resolvedDrop(
                    for: .codexSection(id: id),
                    proposedItem: nil,
                    proposedChildIndex: index
                )
            else {
                return false
            }
            return applyResolvedDrop(resolvedDrop)
        }

        @discardableResult
        func performCodexChatDropForTesting(
            id: CodexThreadID,
            container: ReviewMonitorCodexSidebarRowID,
            childIndex: Int
        ) -> Bool {
            guard let containerNode = codexSidebarOutlineTree.node(rowID: container),
                let resolvedDrop = resolvedDrop(
                    for: .codexChat(id: id.rawValue, containerRowID: container.rawValue),
                    proposedItem: containerNode,
                    proposedChildIndex: childIndex
                )
            else {
                return false
            }
            return applyResolvedDrop(resolvedDrop)
        }

        func codexSidebarChatRowUsesReviewMonitorChatRowViewForTesting(_ id: CodexThreadID) -> Bool {
            guard let row = row(forCodexSidebarSelectionID: .chat(id)),
                let cellView = outlineView.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: true
                ) as? ReviewMonitorReviewChatCellView
            else {
                return false
            }
            return cellView.isHostingReviewMonitorChatRowViewForTesting
        }

        func selectCodexSidebarRowForTesting(rowID: ReviewMonitorCodexSidebarRowID) {
            guard let node = codexSidebarOutlineTree.node(rowID: rowID) else {
                return
            }
            let row = outlineView.row(forItem: node)
            guard row != -1 else {
                return
            }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        var sidebarFullReloadCountForTesting: Int {
            fullReloadCountForTesting
        }

        var isShowingEmptyStateForTesting: Bool {
            emptyStateViewController.view.isHidden == false
        }

        func selectReviewChatForTesting(chat: ReviewMonitorCodexSidebarSnapshot.Chat) {
            guard let row = row(forCodexSidebarSelectionID: .chat(chat.id)) else {
                uiState.selection = .chat(chat)
                return
            }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        func selectReviewChatForTesting(id chatID: CodexThreadID) {
            if let chat = currentChatSelection(id: chatID) {
                selectReviewChatForTesting(chat: chat)
                return
            }
            guard let row = row(forCodexSidebarSelectionID: .chat(chatID)) else {
                uiState.selection = .chat(
                    ReviewMonitorCodexSidebarSnapshot.Chat(
                        rowID: .chat(chatID),
                        id: chatID,
                        title: chatID.rawValue,
                        preview: nil,
                        workspaceCWD: nil,
                        updatedAt: nil
                    ))
                return
            }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        func selectWorkspaceForTesting(_ workspace: CodexReviewWorkspace) {
            guard let row = row(for: workspace) else {
                uiState.selection = .workspaceSection(
                    .init(
                        id: workspace.cwd,
                        title: workspace.displayTitle,
                        workspaceCWDs: [workspace.cwd]
                    ))
                return
            }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        func clearSelectionForTesting() {
            uiState.selection = nil
            outlineView.deselectAll(nil)
        }

        var allWorkspaceRowsExpandedForTesting: Bool {
            codexSidebarOutlineTree.roots.allSatisfy { outlineView.isItemExpanded($0) }
        }

        func workspaceIsSelectableForTesting(_ workspace: CodexReviewWorkspace) -> Bool {
            row(for: workspace).map { shouldAllowSelection(of: outlineView.item(atRow: $0)) } ?? false
        }

        var floatsGroupRowsEnabledForTesting: Bool {
            outlineView.floatsGroupRows
        }

        var draggingDestinationFeedbackStyleForTesting: NSTableView.DraggingDestinationFeedbackStyle {
            outlineView.draggingDestinationFeedbackStyle
        }

        var sidebarUsesAutomaticRowHeightsForTesting: Bool {
            outlineView.usesAutomaticRowHeights
        }

        var expectedWorkspaceRowRectHeightForTesting: CGFloat {
            rowHeights.workspace + outlineView.intercellSpacing.height
        }

        var expectedReviewChatRowRectHeightForTesting: CGFloat {
            rowHeights.reviewChat + outlineView.intercellSpacing.height
        }

        func workspaceRowHeightForTesting(_ workspace: CodexReviewWorkspace) -> CGFloat? {
            guard let row = row(for: workspace) else {
                return nil
            }
            view.layoutSubtreeIfNeeded()
            return outlineView.rect(ofRow: row).height
        }

        func reviewChatRowHeightForTesting(_ chatID: CodexThreadID) -> CGFloat? {
            guard let row = row(for: chatID) else {
                return nil
            }
            view.layoutSubtreeIfNeeded()
            return outlineView.rect(ofRow: row).height
        }

        func workspaceCellMinXForTesting(_ workspace: CodexReviewWorkspace) -> CGFloat? {
            guard let row = row(for: workspace) else {
                return nil
            }
            view.layoutSubtreeIfNeeded()
            guard
                let cellView = outlineView.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: true
                ) as? ReviewMonitorWorkspaceCellView
            else {
                return nil
            }
            outlineView.layoutSubtreeIfNeeded()
            return cellView.contentMinXForTesting(relativeTo: outlineView)
        }

        func workspaceDisclosureMaxXForTesting(_ workspace: CodexReviewWorkspace) -> CGFloat? {
            guard let row = row(for: workspace) else {
                return nil
            }
            view.layoutSubtreeIfNeeded()
            outlineView.layoutSubtreeIfNeeded()
            let disclosureFrame = outlineView.frameOfOutlineCell(atRow: row)
            return disclosureFrame.width > 0 ? disclosureFrame.maxX : nil
        }

        func reviewChatCellMinXForTesting(_ chatID: CodexThreadID) -> CGFloat? {
            guard let row = row(for: chatID) else {
                return nil
            }
            view.layoutSubtreeIfNeeded()
            guard
                let cellView = outlineView.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: true
                ) as? ReviewMonitorReviewChatCellView
            else {
                return nil
            }
            outlineView.layoutSubtreeIfNeeded()
            return cellView.contentMinXForTesting(relativeTo: outlineView)
        }

        func reviewChatRowUsesReviewMonitorChatRowViewForTesting(_ chatID: CodexThreadID) -> Bool {
            guard let row = row(for: chatID),
                let cellView = outlineView.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: true
                ) as? ReviewMonitorReviewChatCellView
            else {
                return false
            }
            return cellView.isHostingReviewMonitorChatRowViewForTesting
        }

        func reviewChatContextMenuTitlesForTesting(_ chatID: CodexThreadID) -> [String] {
            var titles: [String] = []
            presentReviewChatContextMenuForTesting(chatID) { menu in
                titles = menu.items.map(\.title)
            }
            return titles
        }

        private func presentReviewChatContextMenuForTesting(
            _ chatID: CodexThreadID,
            presenter: @escaping (NSMenu) -> Void
        ) {
            guard let row = row(for: chatID) else {
                return
            }
            view.layoutSubtreeIfNeeded()
            outlineView.layoutSubtreeIfNeeded()
            let rowRect = outlineView.rect(ofRow: row)
            let point = NSPoint(x: rowRect.midX, y: rowRect.midY)
            outlineView.presentContextMenuForTesting(at: point, presenter: presenter)
        }

        func clickBlankAreaForTesting() {
            view.layoutSubtreeIfNeeded()
            guard outlineView.numberOfRows > 0 else {
                return
            }
            let point = blankPointForTesting()
            guard outlineView.suppressesSelectionClearingForTesting(at: point) else {
                return
            }
            outlineView.mouseDown(with: mouseEventForTesting(at: point))
        }

        func clickWorkspaceHeaderForTesting(_ workspace: CodexReviewWorkspace) {
            view.layoutSubtreeIfNeeded()
            guard let row = row(for: workspace) else {
                uiState.selection = .workspaceSection(
                    .init(
                        id: workspace.cwd,
                        title: workspace.displayTitle,
                        workspaceCWDs: [workspace.cwd]
                    ))
                return
            }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        func focusSidebarForTesting() {
            _ = view.window?.makeFirstResponder(outlineView)
        }

        var sidebarHasFirstResponderForTesting: Bool {
            view.window?.firstResponder === outlineView
        }

        var isPresentingContextMenuForTesting: Bool {
            outlineView.isPresentingContextMenuForTesting
        }

        var acceptsFirstResponderForTesting: Bool {
            outlineView.acceptsFirstResponderForTesting
        }

        var hasTemporaryContextMenuForTesting: Bool {
            outlineView.menu != nil
        }

        func workspaceIsExpandedForTesting(_ workspace: CodexReviewWorkspace) -> Bool {
            workspaceOutlineIsExpandedForTesting(workspace)
        }

        func workspaceOutlineIsExpandedForTesting(_ workspace: CodexReviewWorkspace) -> Bool {
            guard let row = row(for: workspace),
                let item = outlineView.item(atRow: row)
            else {
                return false
            }
            return outlineView.isItemExpanded(item)
        }

        func toggleWorkspaceDisclosureForTesting(_ workspace: CodexReviewWorkspace) {
            guard let row = row(for: workspace),
                let item = outlineView.item(atRow: row)
            else {
                preconditionFailure("Workspace row is not visible.")
            }
            if outlineView.isItemExpanded(item) {
                outlineView.collapseItem(item)
            } else {
                outlineView.expandItem(item)
            }
        }

        func collapseWorkspaceInOutlineForTesting(_ workspace: CodexReviewWorkspace) {
            guard let row = row(for: workspace),
                let item = outlineView.item(atRow: row)
            else {
                preconditionFailure("Workspace row is not visible.")
            }
            outlineView.collapseItem(item)
        }

        func expandWorkspaceInOutlineForTesting(_ workspace: CodexReviewWorkspace) {
            guard let row = row(for: workspace),
                let item = outlineView.item(atRow: row)
            else {
                preconditionFailure("Workspace row is not visible.")
            }
            outlineView.expandItem(item)
        }

        func workspaceRowIsFloatingForTesting(_ workspace: CodexReviewWorkspace) -> Bool {
            guard let row = row(for: workspace),
                let rowView = outlineView.rowView(atRow: row, makeIfNecessary: true)
            else {
                return false
            }
            return rowView.isFloating
        }

        func scrollSidebarToOffsetForTesting(_ yOffset: CGFloat) {
            let clampedOffset = max(0, yOffset)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedOffset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            view.layoutSubtreeIfNeeded()
        }

        var sidebarVisibleHeightForTesting: CGFloat {
            scrollView.documentVisibleRect.height
        }

        var safeAreaFrameForTesting: NSRect {
            view.safeAreaRect
        }

        var scrollViewFrameForTesting: NSRect {
            scrollView.frame
        }

        var sidebarDocumentHeightForTesting: CGFloat {
            outlineView.frame.height
        }

        var sidebarOutlineContentHeightForTesting: CGFloat {
            guard outlineView.numberOfRows > 0 else {
                return 0
            }
            return outlineView.rect(ofRow: outlineView.numberOfRows - 1).maxY
        }

        var sidebarMaximumVerticalScrollOffsetForTesting: CGFloat {
            max(0, sidebarDocumentHeightForTesting - sidebarVisibleHeightForTesting)
        }

        var sidebarVisibleRectForTesting: NSRect {
            scrollView.documentVisibleRect
        }

        var sidebarFirstRowRectForTesting: NSRect {
            guard outlineView.numberOfRows > 0 else {
                return .zero
            }
            return outlineView.rect(ofRow: 0)
        }

        var sidebarLastRowRectForTesting: NSRect {
            guard outlineView.numberOfRows > 0 else {
                return .zero
            }
            return outlineView.rect(ofRow: outlineView.numberOfRows - 1)
        }

        private func blankPointForTesting() -> NSPoint {
            let blankY: CGFloat
            if outlineView.numberOfRows > 0 {
                blankY = outlineView.rect(ofRow: outlineView.numberOfRows - 1).maxY + 10
            } else {
                blankY = outlineView.bounds.midY
            }
            let x = min(outlineView.bounds.maxX - 1, max(1, outlineView.bounds.midX))
            let y = min(outlineView.bounds.maxY - 1, max(1, blankY))
            return NSPoint(x: x, y: y)
        }

        private func mouseEventForTesting(at point: NSPoint) -> NSEvent {
            guard let window = view.window else {
                fatalError("Sidebar view controller must be attached to a window for click testing.")
            }
            let locationInWindow = outlineView.convert(point, to: nil)
            guard
                let event = NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: locationInWindow,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
            else {
                fatalError("Failed to create a synthetic mouse event.")
            }
            return event
        }
    }
#endif

@MainActor
private final class ReviewMonitorSidebarOutlineView: NSOutlineView {
    var contextMenuProvider: ((NSPoint) -> NSMenu?)?
    var draggingExitedHandler: (() -> Void)?
    private var isPresentingContextMenu = false
    private weak var contextMenuFirstResponder: NSResponder?
    private var previousContextMenu: NSMenu?

    override var acceptsFirstResponder: Bool {
        isPresentingContextMenu ? false : super.acceptsFirstResponder
    }

    @objc(_indentationForRow:withLevel:isSourceListGroupRow:)
    dynamic func indentationForRow(
        _ row: Int,
        withLevel level: Int,
        isSourceListGroupRow: Bool
    ) -> CGFloat {
        // Workspace rows keep AppKit's native disclosure gutter. Review chat rows do
        // not add outline-level indentation; the SwiftUI Label icon slot is
        // the visual indent.
        level <= 0 ? max(indentationPerLevel, 0) : 0
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        handlePrimaryInteraction(at: point) {
            super.mouseDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let contextMenu = contextMenuProvider?(point) else {
            super.rightMouseDown(with: event)
            return
        }

        beginContextMenuPresentation(with: contextMenu)
        super.rightMouseDown(with: event)

        if isPresentingContextMenu {
            endContextMenuPresentation()
        }
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        draggingExitedHandler?()
        super.draggingExited(sender)
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        guard isPresentingContextMenu else {
            return
        }
        endContextMenuPresentation()
    }

    private func shouldSuppressSelectionClearing(at point: NSPoint) -> Bool {
        guard selectedRow != -1 else {
            return false
        }
        return row(at: point) == -1
    }

    private func handlePrimaryInteraction(
        at point: NSPoint,
        action: () -> Void
    ) {
        guard shouldSuppressSelectionClearing(at: point) == false else {
            return
        }

        action()
    }

    private func isSidebarFirstResponder(_ responder: NSResponder) -> Bool {
        if responder === self {
            return true
        }
        guard let view = responder as? NSView else {
            return false
        }
        return view === self || view.isDescendant(of: self)
    }

    private func restoreFirstResponder(_ responder: NSResponder?) {
        guard let window else {
            return
        }
        if let view = responder as? NSView, view.window === window {
            _ = window.makeFirstResponder(view)
            return
        }
        _ = window.makeFirstResponder(self)
    }

    private func beginContextMenuPresentation(with contextMenu: NSMenu) {
        previousContextMenu = menu
        menu = contextMenu
        isPresentingContextMenu = true

        guard let window else {
            contextMenuFirstResponder = nil
            return
        }

        let previousFirstResponder = window.firstResponder
        guard previousFirstResponder.map(isSidebarFirstResponder(_:)) ?? false else {
            contextMenuFirstResponder = nil
            return
        }

        contextMenuFirstResponder = previousFirstResponder
        _ = window.makeFirstResponder(nil)
    }

    private func endContextMenuPresentation() {
        let previousFirstResponder = contextMenuFirstResponder
        let previousContextMenu = previousContextMenu

        contextMenuFirstResponder = nil
        self.previousContextMenu = nil
        isPresentingContextMenu = false
        menu = previousContextMenu

        guard let previousFirstResponder else {
            return
        }
        restoreFirstResponder(previousFirstResponder)
    }

    #if DEBUG
        func suppressesSelectionClearingForTesting(at point: NSPoint) -> Bool {
            shouldSuppressSelectionClearing(at: point)
        }

        func presentContextMenuForTesting(
            at point: NSPoint,
            presenter: @escaping (NSMenu) -> Void
        ) {
            guard window != nil else {
                fatalError("Sidebar outline view must be attached to a window for context menu testing.")
            }
            guard let contextMenu = contextMenuProvider?(point) else {
                return
            }
            beginContextMenuPresentation(with: contextMenu)
            presenter(contextMenu)
            if isPresentingContextMenu {
                endContextMenuPresentation()
            }
        }

        var isPresentingContextMenuForTesting: Bool {
            isPresentingContextMenu
        }

        var acceptsFirstResponderForTesting: Bool {
            acceptsFirstResponder
        }

    #endif
}

private extension ReviewRunRecord {
    var sidebarChatID: CodexThreadID? {
        if let reviewThreadID = nonEmptySidebarChatID(core.run.reviewThreadID) {
            return CodexThreadID(rawValue: reviewThreadID)
        }
        if let threadID = nonEmptySidebarChatID(core.run.threadID) {
            return CodexThreadID(rawValue: threadID)
        }
        return nil
    }

    private func nonEmptySidebarChatID(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
private final class ReviewMonitorWorkspaceRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

@MainActor
private final class ReviewMonitorReviewChatTableRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

@MainActor
private final class ReviewMonitorReviewChatCellView: NSTableCellView {
    private var hostingView: NSHostingView<ReviewMonitorChatRowView>?
    private weak var boundNode: ReviewMonitorCodexSidebarOutlineNode?
    private var nodeObservation: PortableObservationTracking.Token?
    #if DEBUG
        private var bindingGenerationForTesting = 0
    #endif

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
    }

    isolated deinit {
        nodeObservation?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(with node: ReviewMonitorCodexSidebarOutlineNode) {
        guard boundNode !== node else {
            return
        }
        objectValue = node
        boundNode = node
        #if DEBUG
            bindingGenerationForTesting += 1
        #endif
        nodeObservation?.cancel()
        nodeObservation = withPortableContinuousObservation { [weak self, node] _ in
            guard let self,
                case .chat(let chat) = node.item
            else {
                return
            }
            self.toolTip = chat.workspaceCWD ?? chat.preview ?? chat.title
        }
        if let hostingView {
            hostingView.rootView.node = node
        } else {
            let hostingView = NSHostingView(
                rootView: ReviewMonitorChatRowView(node: node)
            )
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            hostingView.setAccessibilityIdentifier("review-monitor.review-chat-row")
            addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: topAnchor),
                hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
                hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            self.hostingView = hostingView
        }
    }

    private func configureHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false
    }

    #if DEBUG
        var isHostingReviewMonitorChatRowViewForTesting: Bool {
            hostingView != nil
        }

        var hostedRowIDForTesting: String? {
            hostingView?.rootView.row?.id
        }

        var hostingViewIdentityForTesting: ObjectIdentifier? {
            hostingView.map(ObjectIdentifier.init)
        }

        var hostedNodeIdentityForTesting: ObjectIdentifier? {
            hostingView.map { ObjectIdentifier($0.rootView.node) }
        }

        var nodeObservationForTesting: PortableObservationTracking.Token? {
            nodeObservation
        }

        var bindingGenerationValueForTesting: Int {
            bindingGenerationForTesting
        }

        func contentMinXForTesting(relativeTo view: NSView) -> CGFloat? {
            guard let hostingView else {
                return nil
            }
            layoutSubtreeIfNeeded()
            return convert(hostingView.frame, to: view).minX
        }
    #endif
}

#if DEBUG
    @MainActor
    func makeReviewMonitorReviewChatCellViewForTesting(
        chat: ReviewMonitorCodexSidebarSnapshot.Chat
    ) -> NSTableCellView {
        let cellView = ReviewMonitorReviewChatCellView()
        cellView.configure(
            with: ReviewMonitorCodexSidebarOutlineNode(
                item: .chat(chat)
            ))
        return cellView
    }

    @MainActor
    func makeReviewMonitorReviewChatCellViewForTesting(
        node: ReviewMonitorCodexSidebarOutlineNode
    ) -> NSTableCellView {
        let cellView = ReviewMonitorReviewChatCellView()
        cellView.configure(with: node)
        return cellView
    }

    @MainActor
    func configureReviewMonitorReviewChatCellViewForTesting(
        _ cellView: NSTableCellView,
        chat: ReviewMonitorCodexSidebarSnapshot.Chat
    ) {
        guard let cellView = cellView as? ReviewMonitorReviewChatCellView else {
            fatalError("Expected ReviewMonitorReviewChatCellView.")
        }
        cellView.configure(
            with: ReviewMonitorCodexSidebarOutlineNode(
                item: .chat(chat)
            ))
    }

    @MainActor
    func configureReviewMonitorReviewChatCellViewForTesting(
        _ cellView: NSTableCellView,
        node: ReviewMonitorCodexSidebarOutlineNode
    ) {
        guard let cellView = cellView as? ReviewMonitorReviewChatCellView else {
            fatalError("Expected ReviewMonitorReviewChatCellView.")
        }
        cellView.configure(with: node)
    }

    @MainActor
    func reviewMonitorReviewChatCellHostedRowIDForTesting(_ cellView: NSTableCellView) -> String? {
        guard let cellView = cellView as? ReviewMonitorReviewChatCellView else {
            return nil
        }
        return cellView.hostedRowIDForTesting
    }

    @MainActor
    func reviewMonitorReviewChatCellHostingViewIdentityForTesting(
        _ cellView: NSTableCellView
    ) -> ObjectIdentifier? {
        guard let cellView = cellView as? ReviewMonitorReviewChatCellView else {
            return nil
        }
        return cellView.hostingViewIdentityForTesting
    }

    @MainActor
    func reviewMonitorReviewChatCellHostedNodeIdentityForTesting(
        _ cellView: NSTableCellView
    ) -> ObjectIdentifier? {
        guard let cellView = cellView as? ReviewMonitorReviewChatCellView else {
            return nil
        }
        return cellView.hostedNodeIdentityForTesting
    }

    @MainActor
    func reviewMonitorReviewChatCellNodeObservationForTesting(
        _ cellView: NSTableCellView
    ) -> PortableObservationTracking.Token? {
        guard let cellView = cellView as? ReviewMonitorReviewChatCellView else {
            return nil
        }
        return cellView.nodeObservationForTesting
    }

    @MainActor
    func reviewMonitorReviewChatCellBindingGenerationForTesting(
        _ cellView: NSTableCellView
    ) -> Int? {
        guard let cellView = cellView as? ReviewMonitorReviewChatCellView else {
            return nil
        }
        return cellView.bindingGenerationValueForTesting
    }
#endif

@MainActor
private final class ReviewMonitorWorkspaceCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let contentStack = NSStackView()
    private weak var boundNode: ReviewMonitorCodexSidebarOutlineNode?
    private var nodeObservation: PortableObservationTracking.Token?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
    }

    isolated deinit {
        nodeObservation?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(_ workspace: CodexReviewWorkspace) {
        objectValue = workspace
        configure(title: workspace.displayTitle, toolTip: workspace.cwd)
    }

    func configure(with node: ReviewMonitorCodexSidebarOutlineNode) {
        guard boundNode !== node else {
            return
        }
        objectValue = node
        boundNode = node
        nodeObservation?.cancel()
        nodeObservation = withPortableContinuousObservation { [weak self, node] _ in
            self?.render(node.item)
        }
    }

    func configure(title: String, toolTip: String, systemSymbolName: String = "folder") {
        iconView.image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil)
        titleLabel.stringValue = title
        self.toolTip = toolTip
    }

    private func render(_ item: ReviewMonitorCodexSidebarOutlineItem) {
        switch item {
        case .section(let section):
            configure(title: section.title, toolTip: section.title, systemSymbolName: "folder")
        case .workspace(let workspace):
            configure(title: workspace.title, toolTip: workspace.cwd, systemSymbolName: "folder")
        case .chat(let chat):
            configure(
                title: chat.title,
                toolTip: chat.preview ?? chat.title,
                systemSymbolName: "bubble.left"
            )
        }
    }

    private func configureHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyDown
        iconView.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        imageView = iconView
        textField = titleLabel

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 6
        contentStack.detachesHiddenViews = true
        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(titleLabel)

        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    #if DEBUG
        func contentMinXForTesting(relativeTo view: NSView) -> CGFloat {
            layoutSubtreeIfNeeded()
            return convert(contentStack.frame, to: view).minX
        }
    #endif
}
