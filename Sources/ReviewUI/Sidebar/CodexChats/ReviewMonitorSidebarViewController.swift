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
                reviewChat: measuredReviewMonitorChatRowHeight()
            )
        }

        @MainActor
        private static func measuredWorkspaceRowHeight() -> CGFloat {
            let cellView = ReviewMonitorWorkspaceCellView()
            cellView.configure(title: "workspace-alpha", toolTip: "/tmp/workspace-alpha")
            return ceil(cellView.fittingSize.height)
        }
    }

    private enum SidebarDragPayload: Codable, Equatable {
        case codexWorkspaceGroup(id: String)
        case codexChat(id: String, containerRowID: String)
    }

    private struct SidebarResolvedDrop {
        enum Operation {
            case none
            case reorderCodexWorkspaceGroup(
                id: CodexWorkspaceGroupID,
                beforeID: CodexWorkspaceGroupID?
            )
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
    private let scrollView = NSScrollView()
    private let outlineView = ReviewMonitorSidebarOutlineView()
    private let accountsViewController: ReviewMonitorAccountsViewController
    private let emptyStateViewController = PlaceholderViewController(content: .noReviewChats)
    private let unavailableView: NSHostingView<MCPServerUnavailableView>
    private let rowHeights: SidebarRowHeights

    private var sidebarKindObservation: PortableObservationTracking.Token?
    private var sidebarFilterObservation: PortableObservationTracking.Token?
    private var sidebarSelectionObservation: PortableObservationTracking.Token?
    private var codexSidebarObservation: PortableObservationTracking.Token?
    private var codexSidebarSectionsObservation: PortableObservationTracking.Token?
    private var codexSidebarFetchTask: Task<Void, Never>?
    private var codexSidebarFetchedResults: CodexFetchedResults<CodexChat>?
    private var codexSidebarModelContext: CodexModelContext?
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
        codexModelSource: ReviewMonitorCodexModelSource? = nil
    ) {
        self.store = store
        self.uiState = uiState
        self.codexModelSource = codexModelSource
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
        sidebarSelectionObservation?.cancel()
        codexSidebarObservation?.cancel()
        codexSidebarSectionsObservation?.cancel()
        codexSidebarFetchTask?.cancel()
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        configureOutlineView()
        applyCodexSidebarSourceSections([])
        bindObservation()
        bindCodexSidebarFetchedResults()
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
        sidebarSelectionObservation?.cancel()

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
            self?.applyFilteredCodexSidebarSections()
        }

        sidebarSelectionObservation = withPortableContinuousObservation { [weak self, uiState] event in
            _ = uiState.selection?.id
            guard event.kind != .initial,
                let self,
                self.hasCodexSidebarContent
            else {
                return
            }
            self.reconcileOutlineSelection()
        }
    }

    static var defaultCodexSidebarDescriptor: CodexFetchDescriptor<CodexChat> {
        CodexFetchDescriptor<CodexChat>(
            predicate: .init(sourceKinds: [.subAgentReview]),
            sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
        )
    }

    private static func makeCodexSidebarFetchedResults(
        modelContext: CodexModelContext
    ) -> CodexFetchedResults<CodexChat> {
        modelContext.fetchedResults(
            for: defaultCodexSidebarDescriptor,
            sectionedBy: .workspaceGroup
        )
    }

    private func bindCodexSidebarFetchedResults() {
        guard let codexModelSource else {
            return
        }
        codexSidebarObservation?.cancel()
        codexSidebarObservation = withPortableContinuousObservation { [weak self, codexModelSource] _ in
            self?.installCodexSidebarFetchedResults(modelContext: codexModelSource.modelContext)
        }
    }

    private func installCodexSidebarFetchedResults(modelContext: CodexModelContext?) {
        if let modelContext,
            let codexSidebarModelContext,
            codexSidebarModelContext === modelContext,
            codexSidebarFetchedResults != nil
        {
            return
        }
        codexSidebarFetchTask?.cancel()
        codexSidebarFetchTask = nil
        codexSidebarSectionsObservation?.cancel()
        codexSidebarSectionsObservation = nil
        guard let modelContext else {
            codexSidebarModelContext = nil
            codexSidebarFetchedResults = nil
            applyCodexSidebarSourceSections([])
            return
        }

        let fetchedResults = Self.makeCodexSidebarFetchedResults(modelContext: modelContext)
        codexSidebarModelContext = modelContext
        codexSidebarFetchedResults = fetchedResults
        codexSidebarSectionsObservation = withPortableContinuousObservation { [weak self, fetchedResults] event in
            guard let self,
                self.codexSidebarFetchedResults === fetchedResults
            else {
                return
            }
            let sections = fetchedResults.sections
            guard event.kind != .initial else {
                return
            }
            self.applyCodexSidebarSourceSections(sections)
        }
        codexSidebarFetchTask = Task { @MainActor [weak self, fetchedResults] in
            do {
                try await fetchedResults.performFetch()
            } catch is CancellationError {
            } catch {
            }
            guard self?.codexSidebarFetchedResults === fetchedResults else {
                return
            }
            self?.applyCodexSidebarSourceSections(fetchedResults.sections)
            self?.codexSidebarFetchTask = nil
        }
    }

    private var codexSidebarSourceSections: [CodexFetchSection<CodexChat>] {
        codexSidebarFetchedResults?.sections ?? []
    }

    private func codexSidebarVisibleSections(
        from sourceSections: [CodexFetchSection<CodexChat>]
    ) -> [CodexFetchSection<CodexChat>] {
        codexSidebarPresentationOrder
            .applying(to: sourceSections)
            .filtered(by: uiState.sidebarReviewChatFilter)
    }

    private var currentCodexSidebarVisibleSections: [CodexFetchSection<CodexChat>] {
        codexSidebarVisibleSections(from: codexSidebarSourceSections)
    }

    private func applyCodexSidebarSourceSections(_ sections: [CodexFetchSection<CodexChat>]) {
        codexSidebarPresentationOrder.prune(to: sections)
        applyCodexSidebarVisibleSections(from: sections)
    }

    private func applyFilteredCodexSidebarSections() {
        applyCodexSidebarVisibleSections(from: codexSidebarSourceSections)
    }

    private func applyCodexSidebarVisibleSections(
        from sourceSections: [CodexFetchSection<CodexChat>]
    ) {
        let sections = codexSidebarVisibleSections(from: sourceSections)
        let applyResult = codexSidebarOutlineTree.apply(sections: sections)
        applySidebarKind(sidebarKind)
        if applyResult.topologyChanged {
            applyCodexSidebarOutlineTopologyChanges(applyResult.topologyChanges)
        } else {
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
            reconcileOutlineSelection()
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
        reconcileOutlineSelection()
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
        case .workspaceGroup(let selectedWorkspaceGroupID):
            guard codexWorkspaceGroupSelection(id: selectedWorkspaceGroupID) != nil,
                let row = row(forCodexSidebarSelectionID: .workspaceGroup(selectedWorkspaceGroupID))
            else {
                guard codexSidebarContentIsAuthoritative else {
                    return
                }
                uiState.selection = nil
                outlineView.deselectAll(nil)
                return
            }

            guard outlineView.selectedRow != row else {
                return
            }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        case .workspace(let selectedWorkspaceID):
            guard codexWorkspaceSelection(id: selectedWorkspaceID) != nil,
                let row = row(forCodexSidebarSelectionID: .workspace(selectedWorkspaceID))
            else {
                guard codexSidebarContentIsAuthoritative else {
                    return
                }
                uiState.selection = nil
                outlineView.deselectAll(nil)
                return
            }

            guard outlineView.selectedRow != row else {
                return
            }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        case .chat(let selectedChatID):
            guard currentChatSelection(id: selectedChatID) != nil else {
                guard codexSidebarContentIsAuthoritative else {
                    return
                }
                uiState.selection = nil
                outlineView.deselectAll(nil)
                return
            }

            guard let row = row(forCurrentChatSelectionID: selectedChatID)
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
            case .workspaceGroup(let id):
                uiState.selection = .workspaceGroup(id)
            case .workspace(let id):
                uiState.selection = .workspace(id)
            case .chat(let id):
                uiState.selection = .chat(id)
            }
        } else {
            uiState.selection = nil
        }
    }

    private func makeContextMenu(at point: NSPoint) -> NSMenu? {
        let row = outlineView.row(at: point)
        guard row >= 0,
            let node = codexSidebarNode(from: outlineView.item(atRow: row)),
            case .chat(let id) = node.item,
            let chat = codexChatSelection(id: id)
        else {
            return nil
        }

        return NSHostingMenu(
            rootView: ReviewMonitorChatContextMenuView(chat: chat, store: store)
        )
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

    private func row(forWorkspaceCWD cwd: String) -> Int? {
        row(forCodexSidebarSelectionID: .workspace(CodexWorkspaceID(rawValue: cwd)))
            ?? row(forCodexSidebarSelectionID: .workspaceGroup(CodexWorkspaceGroupID(rawValue: cwd)))
    }

    private func workspaceGroupID(forWorkspaceCWD cwd: String) -> CodexWorkspaceGroupID? {
        let workspaceID = CodexWorkspaceID(rawValue: cwd)
        for section in codexSidebarSourceSections {
            if section.workspaces.contains(where: { $0.id == workspaceID })
                || section.items.contains(where: { $0.workspaceID == workspaceID })
            {
                return section.sidebarWorkspaceGroupID
            }
            if section.sidebarWorkspaceGroupID.rawValue == cwd || section.sidebarWorkspaceGroupID.rawValue == "cwd:\(cwd)" {
                return section.sidebarWorkspaceGroupID
            }
        }
        return nil
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
        case .workspaceGroup(let id):
            rowID = .workspaceGroup(id)
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
        guard codexSidebarContentIsAuthoritative else {
            return true
        }
        switch selection {
        case .workspaceGroup(let id):
            return codexWorkspaceGroupSelection(id: id) != nil
        case .workspace(let id):
            return codexWorkspaceSelection(id: id) != nil
        case .chat(let id):
            return currentChatSelection(id: id) != nil
        }
    }

    private var codexSidebarContentIsAuthoritative: Bool {
        guard let codexSidebarFetchedResults else {
            return false
        }
        switch codexSidebarFetchedResults.phase {
        case .loaded, .failed:
            return true
        case .idle, .loading:
            return false
        }
    }

    private func currentChatSelection(id: CodexThreadID) -> CodexChat? {
        codexSidebarSourceSections.chat(id: id)
    }

    private func displayedCodexSidebarSection(id: CodexWorkspaceGroupID) -> CodexFetchSection<CodexChat>? {
        currentCodexSidebarVisibleSections.first { $0.sidebarWorkspaceGroupID == id }
    }

    private func displayedCodexChat(id: CodexThreadID) -> CodexChat? {
        currentCodexSidebarVisibleSections.chat(id: id)
            ?? currentChatSelection(id: id)
    }

    private func displayedCodexWorkspace(id: CodexWorkspaceID) -> CodexWorkspace? {
        for section in currentCodexSidebarVisibleSections {
            if let workspace = section.workspaces.first(where: { $0.id == id }) {
                return workspace
            }
        }
        for section in codexSidebarSourceSections {
            if let workspace = section.workspaces.first(where: { $0.id == id }) {
                return workspace
            }
        }
        return nil
    }

    private func codexSidebarTitle(for node: ReviewMonitorCodexSidebarOutlineNode) -> String? {
        switch node.item {
        case .workspaceGroup(let id):
            return displayedCodexSidebarSection(id: id)?.displayTitle
                ?? codexWorkspaceGroupSection(id: id)?.displayTitle
        case .workspace(let id):
            return displayedCodexWorkspace(id: id)?.name
        case .chat(let id):
            return displayedCodexChat(id: id)?.title
        }
    }

    private func codexWorkspaceSelection(
        id: CodexWorkspaceID
    ) -> CodexWorkspace? {
        guard let node = codexSidebarOutlineTree.node(rowID: .workspace(id)),
            case .workspace(let workspaceID) = node.item,
            workspaceID == id
        else {
            return nil
        }
        return displayedCodexWorkspace(id: id)
    }

    private func codexWorkspaceGroupSelection(
        id: CodexWorkspaceGroupID
    ) -> ReviewMonitorCodexSidebarOutlineNode? {
        guard let node = codexSidebarOutlineTree.node(rowID: .workspaceGroup(id)) else {
            return nil
        }
        switch node.item {
        case .workspaceGroup(let workspaceGroupID) where workspaceGroupID == id:
            return node
        case .workspace, .chat:
            return nil
        case .workspaceGroup:
            return nil
        }
    }

    private func codexWorkspaceGroupSection(
        id: CodexWorkspaceGroupID
    ) -> CodexFetchSection<CodexChat>? {
        codexSidebarSourceSections.first { $0.sidebarWorkspaceGroupID == id }
    }

    private func codexChatSelection(id: CodexThreadID) -> CodexChat? {
        guard let node = codexSidebarOutlineTree.node(rowID: .chat(id)),
            case .chat(let chatID) = node.item,
            chatID == id
        else {
            return nil
        }
        return displayedCodexChat(id: id)
    }

    func codexChatTitlePresentation(id: CodexThreadID) -> (title: String, subtitle: String)? {
        if let chat = codexSidebarFetchedResults?.items.first(where: { $0.id == id }) {
            return (
                title: chat.title,
                subtitle: chat.workspace?.url.path ?? ""
            )
        }
        guard let chat = currentChatSelection(id: id) else {
            return nil
        }
        return (
            title: chat.title,
            subtitle: chat.workspace?.url.path ?? ""
        )
    }

    func codexWorkspaceGroupTitlePresentation(
        id: CodexWorkspaceGroupID
    ) -> (title: String, subtitle: String)? {
        guard let node = codexWorkspaceGroupSelection(id: id) else {
            return nil
        }
        let title = codexSidebarTitle(for: node) ?? id.rawValue
        let workspaceCWDs = codexWorkspaceGroupSection(id: id)?.workspaces.map(\.url.path) ?? []
        return (
            title: title,
            subtitle: workspaceCWDs.count == 1 ? (workspaceCWDs.first ?? "") : "\(workspaceCWDs.count) workspaces"
        )
    }

    func codexWorkspaceTitlePresentation(
        id: CodexWorkspaceID
    ) -> (title: String, subtitle: String)? {
        guard let workspace = codexWorkspaceSelection(id: id) else {
            return nil
        }
        return (title: workspace.name, subtitle: workspace.url.path)
    }

    private func dragPayload(for item: Any) -> SidebarDragPayload? {
        guard let node = codexSidebarNode(from: item) else {
            return nil
        }
        switch node.item {
        case .workspaceGroup(let id):
            return .codexWorkspaceGroup(id: id.rawValue)
        case .workspace:
            return nil
        case .chat(let id):
            guard let parent = outlineView.parent(forItem: node) as? ReviewMonitorCodexSidebarOutlineNode else {
                return nil
            }
            return .codexChat(id: id.rawValue, containerRowID: parent.rowID.rawValue)
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
        case .codexWorkspaceGroup(let id):
            resolvedCodexWorkspaceGroupDrop(
                id: CodexWorkspaceGroupID(rawValue: id),
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

    private func resolvedCodexWorkspaceGroupDrop(
        id: CodexWorkspaceGroupID,
        draggingLocation: NSPoint?,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> SidebarResolvedDrop? {
        guard let sourceNode = codexSidebarOutlineTree.node(rowID: .workspaceGroup(id)),
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
        let beforeID: CodexWorkspaceGroupID?
        if displayDestinationIndex < remainingRoots.count,
            let workspaceGroupID = remainingRoots[displayDestinationIndex].workspaceGroupID
        {
            beforeID = workspaceGroupID
        } else {
            beforeID = nil
        }

        return SidebarResolvedDrop(
            operation: .reorderCodexWorkspaceGroup(id: id, beforeID: beforeID),
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
            case .chat(let targetChatID) = targetNode.item,
            index == NSOutlineViewDropOnItemIndex,
            let parentNode = outlineView.parent(forItem: targetNode) as? ReviewMonitorCodexSidebarOutlineNode,
            parentNode.rowID == sourceContainer,
            let targetIndex = codexVisibleChatIDs(in: parentNode.rowID).firstIndex(of: targetChatID),
            let draggingLocation,
            let targetRow = row(forCodexSidebarSelectionID: .chat(targetChatID))
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
        case .workspaceGroup:
            return node.children.contains { $0.item.isChat }
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
        return node.children.compactMap(\.item.chatID)
    }

    private func codexUnfilteredChatIDs(in container: ReviewMonitorCodexSidebarRowID) -> [CodexThreadID] {
        for section in codexSidebarSourceSections {
            if section.rowID == container {
                if section.displaysWorkspaceNodes == false {
                    return section.items.map(\.id)
                }
                return section.uncategorizedChats.map(\.id)
            }
            for workspace in section.workspaces where ReviewMonitorCodexSidebarRowID.workspace(workspace.id) == container {
                return section.chats(in: workspace.id).map(\.id)
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
        case .reorderCodexWorkspaceGroup(let id, let beforeID):
            guard codexSidebarPresentationOrder.reorderWorkspaceGroup(id: id, before: beforeID) else {
                return false
            }
            applyFilteredCodexSidebarSections()
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
            applyFilteredCodexSidebarSections()
            return true
        }
    }

    private func makeCodexSidebarCellView(for node: ReviewMonitorCodexSidebarOutlineNode) -> NSView? {
        switch node.item {
        case .chat:
            let view =
                (outlineView.makeView(withIdentifier: Identifier.reviewChatCell, owner: self)
                    as? ReviewMonitorReviewChatCellView)
                ?? ReviewMonitorReviewChatCellView()
            view.identifier = Identifier.reviewChatCell
            guard configureCodexSidebarCell(view, for: node) else {
                return nil
            }
            return view
        case .workspaceGroup, .workspace:
            let view =
                (outlineView.makeView(withIdentifier: Identifier.workspaceCell, owner: self)
                    as? ReviewMonitorWorkspaceCellView)
                ?? ReviewMonitorWorkspaceCellView()
            view.identifier = Identifier.workspaceCell
            guard configureCodexSidebarCell(view, for: node) else {
                return nil
            }
            return view
        }
    }

    @discardableResult
    private func configureCodexSidebarCell(
        _ cellView: NSView,
        for node: ReviewMonitorCodexSidebarOutlineNode
    ) -> Bool {
        switch node.item {
        case .chat(let id):
            guard let cellView = cellView as? ReviewMonitorReviewChatCellView,
                let chat = displayedCodexChat(id: id)
            else {
                return false
            }
            cellView.configure(with: chat)
            return true
        case .workspaceGroup(let id):
            guard let cellView = cellView as? ReviewMonitorWorkspaceCellView else {
                return false
            }
            if let workspaceGroup = displayedCodexSidebarSection(id: id)?.workspaceGroup
                ?? codexWorkspaceGroupSection(id: id)?.workspaceGroup
            {
                cellView.configure(workspaceGroup: workspaceGroup)
            } else {
                cellView.configureFallbackWorkspaceGroup(title: codexSidebarTitle(for: node) ?? id.rawValue)
            }
            return true
        case .workspace(let id):
            guard let cellView = cellView as? ReviewMonitorWorkspaceCellView,
                let workspace = displayedCodexWorkspace(id: id)
            else {
                return false
            }
            cellView.configure(workspace: workspace)
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
            if node.item.isChat {
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
            if node.item.isChat {
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
        guard let node = codexSidebarNode(from: item) else {
            return nil
        }
        return makeCodexSidebarCellView(for: node)
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
            guard case .chat(let id) = uiState.selection else {
                return nil
            }
            return id
        }

        var selectedWorkspaceGroupIDForTesting: CodexWorkspaceGroupID? {
            guard case .workspaceGroup(let id) = uiState.selection else {
                return nil
            }
            return id
        }

        func workspaceGroupIDForTesting(cwd: String) -> CodexWorkspaceGroupID? {
            workspaceGroupID(forWorkspaceCWD: cwd)
        }

        var codexSidebarSectionsForTesting: [CodexFetchSection<CodexChat>] {
            codexSidebarFetchedResults?.sections ?? []
        }

        var codexSidebarRootTitlesForTesting: [String] {
            codexSidebarOutlineTree.roots.map { codexSidebarTitle(for: $0) ?? $0.rowID.rawValue }
        }

        var displayedCodexSidebarTitlesForTesting: [String] {
            (0..<outlineView.numberOfRows).compactMap { row in
                guard let node = codexSidebarNode(from: outlineView.item(atRow: row)) else {
                    return nil
                }
                return codexSidebarTitle(for: node) ?? node.rowID.rawValue
            }
        }

        func codexSidebarNodeTitleForTesting(rowID: ReviewMonitorCodexSidebarRowID) -> String? {
            codexSidebarOutlineTree.node(rowID: rowID).flatMap { codexSidebarTitle(for: $0) }
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
        func performCodexWorkspaceGroupDropForTesting(id: CodexWorkspaceGroupID, toIndex index: Int) -> Bool {
            guard
                let resolvedDrop = resolvedDrop(
                    for: .codexWorkspaceGroup(id: id.rawValue),
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

        func refreshCodexSidebarForTesting() async throws {
            try await codexSidebarFetchedResults?.refresh()
            applyCodexSidebarSourceSections(codexSidebarFetchedResults?.sections ?? [])
        }

        var sidebarFullReloadCountForTesting: Int {
            fullReloadCountForTesting
        }

        var isShowingEmptyStateForTesting: Bool {
            emptyStateViewController.view.isHidden == false
        }

        func selectReviewChatForTesting(chat: CodexChat) {
            guard let row = row(forCodexSidebarSelectionID: .chat(chat.id)) else {
                uiState.selection = .chat(chat.id)
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
                uiState.selection = .chat(chatID)
                return
            }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        func presentContextMenuForTesting(
            chatID: CodexThreadID,
            presenter: @escaping (NSMenu) -> Void
        ) {
            view.layoutSubtreeIfNeeded()
            guard let row = row(for: chatID) else {
                return
            }
            let rowRect = outlineView.rect(ofRow: row)
            outlineView.presentContextMenuForTesting(
                at: NSPoint(x: rowRect.midX, y: rowRect.midY),
                presenter: presenter
            )
        }

        func selectWorkspaceForTesting(cwd: String) {
            guard let row = row(forWorkspaceCWD: cwd) else {
                uiState.selection = fallbackWorkspaceGroupSelection(cwd: cwd)
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

        func workspaceIsSelectableForTesting(cwd: String) -> Bool {
            row(forWorkspaceCWD: cwd).map { shouldAllowSelection(of: outlineView.item(atRow: $0)) } ?? false
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

        func workspaceRowHeightForTesting(cwd: String) -> CGFloat? {
            guard let row = row(forWorkspaceCWD: cwd) else {
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

        func workspaceCellMinXForTesting(cwd: String) -> CGFloat? {
            guard let row = row(forWorkspaceCWD: cwd) else {
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

        func workspaceDisclosureMaxXForTesting(cwd: String) -> CGFloat? {
            guard let row = row(forWorkspaceCWD: cwd) else {
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

        func clickWorkspaceHeaderForTesting(cwd: String) {
            view.layoutSubtreeIfNeeded()
            let workspaceGroupID = workspaceGroupID(forWorkspaceCWD: cwd) ?? CodexWorkspaceGroupID(rawValue: cwd)
            guard
                let row = row(forCodexSidebarSelectionID: .workspaceGroup(workspaceGroupID))
                    ?? row(forWorkspaceCWD: cwd)
            else {
                uiState.selection = fallbackWorkspaceGroupSelection(cwd: cwd)
                return
            }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            updateSelectionFromOutlineView()
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

        func workspaceIsExpandedForTesting(cwd: String) -> Bool {
            workspaceOutlineIsExpandedForTesting(cwd: cwd)
        }

        func workspaceOutlineIsExpandedForTesting(cwd: String) -> Bool {
            guard let row = row(forWorkspaceCWD: cwd),
                let item = outlineView.item(atRow: row)
            else {
                return false
            }
            return outlineView.isItemExpanded(item)
        }

        func toggleWorkspaceDisclosureForTesting(cwd: String) {
            guard let row = row(forWorkspaceCWD: cwd),
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

        func collapseWorkspaceInOutlineForTesting(cwd: String) {
            guard let row = row(forWorkspaceCWD: cwd),
                let item = outlineView.item(atRow: row)
            else {
                preconditionFailure("Workspace row is not visible.")
            }
            outlineView.collapseItem(item)
        }

        func expandWorkspaceInOutlineForTesting(cwd: String) {
            guard let row = row(forWorkspaceCWD: cwd),
                let item = outlineView.item(atRow: row)
            else {
                preconditionFailure("Workspace row is not visible.")
            }
            outlineView.expandItem(item)
        }

        func workspaceRowIsFloatingForTesting(cwd: String) -> Bool {
            guard let row = row(forWorkspaceCWD: cwd),
                let rowView = outlineView.rowView(atRow: row, makeIfNecessary: true)
            else {
                return false
            }
            return rowView.isFloating
        }

        private func fallbackWorkspaceGroupSelection(cwd: String) -> ReviewMonitorSelection {
            .workspaceGroup(CodexWorkspaceGroupID(rawValue: cwd))
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
    private weak var boundChat: CodexChat?
    private var chatObservation: PortableObservationTracking.Token?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
    }

    isolated deinit {
        chatObservation?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(with chat: CodexChat) {
        guard boundChat !== chat else {
            return
        }
        objectValue = chat
        boundChat = chat
        chatObservation?.cancel()
        render(chat)
        chatObservation = withPortableContinuousObservation { [weak self, chat] _ in
            self?.render(chat)
        }
    }

    private func configureHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false
    }

    private func render(_ chat: CodexChat) {
        toolTip = chat.workspace?.url.path ?? chat.preview ?? chat.title
        if let hostingView {
            if hostingView.rootView.chat !== chat {
                hostingView.rootView.chat = chat
            }
            return
        }

        let hostingView = NSHostingView(
            rootView: ReviewMonitorChatRowView(chat: chat)
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

    #if DEBUG
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
        chat: CodexChat
    ) -> NSTableCellView {
        let cellView = ReviewMonitorReviewChatCellView()
        cellView.configure(with: chat)
        return cellView
    }

    @MainActor
    func configureReviewMonitorReviewChatCellViewForTesting(
        _ cellView: NSTableCellView,
        chat: CodexChat
    ) {
        guard let cellView = cellView as? ReviewMonitorReviewChatCellView else {
            fatalError("Expected ReviewMonitorReviewChatCellView.")
        }
        cellView.configure(with: chat)
    }
#endif

@MainActor
private final class ReviewMonitorWorkspaceCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let contentStack = NSStackView()
    private enum BoundIdentity: Equatable {
        case workspaceGroup(ObjectIdentifier)
        case fallbackWorkspaceGroup(String)
        case workspace(ObjectIdentifier)
    }

    private var boundIdentity: BoundIdentity?
    private var modelObservation: PortableObservationTracking.Token?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
    }

    isolated deinit {
        modelObservation?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(workspaceGroup: CodexWorkspaceGroup) {
        let identity = BoundIdentity.workspaceGroup(ObjectIdentifier(workspaceGroup))
        guard boundIdentity != identity else {
            return
        }
        objectValue = workspaceGroup
        boundIdentity = identity
        modelObservation?.cancel()
        render(workspaceGroup: workspaceGroup)
        modelObservation = withPortableContinuousObservation { [weak self, workspaceGroup] _ in
            self?.render(workspaceGroup: workspaceGroup)
        }
    }

    func configureFallbackWorkspaceGroup(title: String) {
        let identity = BoundIdentity.fallbackWorkspaceGroup(title)
        guard boundIdentity != identity else {
            return
        }
        objectValue = title
        boundIdentity = identity
        modelObservation?.cancel()
        render(title: title, toolTip: title, systemSymbolName: "folder")
    }

    func configure(workspace: CodexWorkspace) {
        let identity = BoundIdentity.workspace(ObjectIdentifier(workspace))
        guard boundIdentity != identity else {
            return
        }
        objectValue = workspace
        boundIdentity = identity
        modelObservation?.cancel()
        render(workspace: workspace)
        modelObservation = withPortableContinuousObservation { [weak self, workspace] _ in
            self?.render(workspace: workspace)
        }
    }

    func configure(title: String, toolTip: String, systemSymbolName: String = "folder") {
        objectValue = title
        boundIdentity = .fallbackWorkspaceGroup(title)
        modelObservation?.cancel()
        render(title: title, toolTip: toolTip, systemSymbolName: systemSymbolName)
    }

    private func render(title: String, toolTip: String, systemSymbolName: String) {
        iconView.image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil)
        titleLabel.stringValue = title
        self.toolTip = toolTip
    }

    private func render(workspaceGroup: CodexWorkspaceGroup) {
        render(title: workspaceGroup.name, toolTip: workspaceGroup.name, systemSymbolName: "folder")
    }

    private func render(workspace: CodexWorkspace) {
        render(title: workspace.name, toolTip: workspace.url.path, systemSymbolName: "folder")
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
