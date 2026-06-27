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
            let job = CodexReviewJob(
                id: "row-height-measurement",
                sessionID: "row-height-measurement",
                cwd: "/tmp/workspace",
                targetSummary: "Uncommitted changes",
                core: .init(
                    run: .init(model: "gpt-5.5"),
                    lifecycle: .init(
                        status: .running,
                        startedAt: Date(timeIntervalSince1970: 0)
                    ),
                    output: .init(
                        summary: "",
                        lastAgentMessage: "Review output preview"
                    )
                )
            )
            let cellView = ReviewMonitorReviewChatCellView()
            cellView.configure(with: ReviewMonitorSidebarReviewChatRow(job: job))
            return ceil(cellView.fittingSize.height)
        }
    }

    private enum SidebarDragPayload: Codable, Equatable {
        case workspaceSection(id: String)
        case reviewChat(jobID: String, cwd: String)
    }

    private struct SidebarResolvedDrop {
        enum Operation {
            case none
            case reorderWorkspaceSection(id: String, cwds: [String], beforeCWD: String?, displayIndex: Int)
            case reorderReviewChat(jobID: String, cwd: String, beforeJobID: String?, displayIndex: Int)
        }

        let operation: Operation
        let dropItem: Any?
        let dropChildIndex: Int
    }

    private struct SidebarWorkspaceTopology {
        let workspace: CodexReviewWorkspace
        let reviewRows: [ReviewMonitorSidebarReviewChatRow]
    }

    private struct SidebarWorkspaceDropDestination {
        let rootInsertionIndex: Int
    }

    private struct SidebarReviewChatDropDestination {
        let workspace: CodexReviewWorkspace
        let childIndex: Int
        let movesToFullOrderEnd: Bool
    }

    private struct DisplayedSidebarTopologySnapshot {
        let rootTopologies: [SidebarRootTopology]

        func rootIndex(forRootItem rootItem: AnyObject) -> Int? {
            rootTopologies.firstIndex { $0.item === rootItem }
        }

        func workspaceBeforeCWD(
            movingRootItem: AnyObject,
            rootInsertionIndex rawRootInsertionIndex: Int
        ) -> String? {
            let displayDestinationIndex = displayDestinationIndex(
                movingRootItem: movingRootItem,
                rootInsertionIndex: rawRootInsertionIndex
            )
            let remainingTopologies = rootTopologies.filter { $0.item !== movingRootItem }
            guard displayDestinationIndex < remainingTopologies.count else {
                return nil
            }
            return remainingTopologies[displayDestinationIndex].workspaces.first?.cwd
        }

        func displayDestinationIndex(
            movingRootItem: AnyObject,
            rootInsertionIndex rawRootInsertionIndex: Int
        ) -> Int {
            let sourceRootIndex = rootIndex(forRootItem: movingRootItem) ?? rootTopologies.count
            let remainingRootCount = max(0, rootTopologies.count - 1)
            let rootInsertionIndex = max(0, min(rawRootInsertionIndex, rootTopologies.count))
            let displayDestinationIndex = rootInsertionIndex > sourceRootIndex
                ? rootInsertionIndex - 1
                : rootInsertionIndex
            return max(0, min(displayDestinationIndex, remainingRootCount))
        }
    }

    private final class SidebarWorkspaceSection: Hashable {
        let id: String
        var title: String
        var workspaces: [CodexReviewWorkspace]
        var reviewRows: [ReviewMonitorSidebarReviewChatRow]
        var isExpanded: Bool

        init(
            id: String,
            title: String,
            workspaces: [CodexReviewWorkspace],
            reviewRows: [ReviewMonitorSidebarReviewChatRow]
        ) {
            self.id = id
            self.title = title
            self.workspaces = workspaces
            self.reviewRows = reviewRows
            self.isExpanded = true
        }

        var selection: ReviewMonitorWorkspaceSectionSelection {
            ReviewMonitorWorkspaceSectionSelection(
                id: id,
                title: title,
                workspaceCWDs: workspaces.map(\.cwd)
            )
        }

        static func == (lhs: SidebarWorkspaceSection, rhs: SidebarWorkspaceSection) -> Bool {
            lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    private struct SidebarRootTopology {
        let item: AnyObject
        let workspaces: [CodexReviewWorkspace]
        let reviewRows: [ReviewMonitorSidebarReviewChatRow]
    }

    private enum SidebarMutationAnimation {
        static let duration: TimeInterval = 0.18
        static let insertionOptions: NSTableView.AnimationOptions = [.effectFade, .slideDown]
        static let removalOptions: NSTableView.AnimationOptions = [.effectFade, .slideUp]
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
    private var sidebarTopologyObservation: PortableObservationTracking.Token?
    private var sidebarFilterObservation: PortableObservationTracking.Token?
    private var codexSidebarObservation: PortableObservationTracking.Token?
    private var codexSidebarSnapshotObservation: PortableObservationTracking.Token?
    private var selectedChatSnapshotObservation: PortableObservationTracking.Token?
    private var codexSidebarFetchTask: Task<Void, Never>?
    private var codexSidebarLibrary: ReviewMonitorCodexSidebarLibrary?
    private var codexSidebarModelContext: CodexModelContext?
    private let codexSidebarOutlineTree = ReviewMonitorCodexSidebarOutlineTree()
    private let reviewChatIndex = ReviewMonitorSidebarReviewChatIndex()
    private var workspaceSectionIdentitiesByCWD: [String: ReviewMonitorWorkspaceSectionIdentity] = [:]
    private var workspaceSectionsByID: [String: SidebarWorkspaceSection] = [:]
    private var currentRootTopologies: [SidebarRootTopology] = []
    private var isReconcilingSelection = false
#if DEBUG
    private var fullReloadCountForTesting = 0
    private var workspaceReloadCountForTesting = 0
    private var incrementalMoveCountForTesting = 0
    private var incrementalMembershipChangeCountForTesting = 0
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
        sidebarTopologyObservation?.cancel()
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
        bindObservation()
        applyPreviewCodexSidebarSnapshotIfNeeded()
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
        sidebarTopologyObservation?.cancel()
        sidebarFilterObservation?.cancel()
        selectedChatSnapshotObservation?.cancel()

        sidebarKindObservation = withPortableContinuousObservation { [weak self, uiState, store] _ in
            let sidebarSelection = uiState.sidebarSelection
            let serverState = store.serverState
            let hasReviewJobs = store.hasReviewJobs
            let hasWorkspaces = store.workspaces.isEmpty == false
            guard let self else {
                return
            }
            self.applySidebarKind(Self.sidebarKind(
                sidebarSelection: sidebarSelection,
                serverState: serverState,
                hasReviewJobs: hasReviewJobs,
                hasWorkspaces: hasWorkspaces,
                hasCodexSidebarContent: self.hasCodexSidebarContent
            ))
        }

        let initialFilter = uiState.sidebarReviewChatFilter
        sidebarFilterObservation = withPortableContinuousObservation { [weak self, uiState] event in
            let filter = uiState.sidebarReviewChatFilter
            guard event.kind != .initial else {
                return
            }
            let animatedInitialDelivery = true
            Task { @MainActor [weak self] in
                self?.bindSidebarStoreTopologyObservation(
                    filter: filter,
                    animatedInitialDelivery: animatedInitialDelivery
                )
            }
        }
        bindSidebarStoreTopologyObservation(
            filter: initialFilter,
            animatedInitialDelivery: false
        )

        selectedChatSnapshotObservation = withPortableContinuousObservation { [weak self, uiState] _ in
            guard let self,
                  case .chat(let selectedChat) = uiState.selection
            else {
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
           codexSidebarLibrary != nil {
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
        let wasUsingCodexSidebarOutline = isUsingCodexSidebarOutline
        codexSidebarOutlineTree.apply(snapshot: snapshot)
        applySidebarKind(sidebarKind)
        if wasUsingCodexSidebarOutline || isUsingCodexSidebarOutline {
            reloadCodexSidebarOutline()
        }
    }

    private func reloadCodexSidebarOutline() {
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

    private func bindSidebarStoreTopologyObservation(
        filter: SidebarReviewChatFilter,
        animatedInitialDelivery: Bool
    ) {
        sidebarTopologyObservation?.cancel()
        sidebarTopologyObservation = withPortableContinuousObservation { [weak self] event in
            guard let self else {
                return
            }
            let workspaceTopologies = self.sidebarWorkspaceTopologies()
            let rootTopologies = self.sidebarRootTopologies(
                from: workspaceTopologies,
                filter: filter
            )
            let animated = event.kind == .initial ? animatedInitialDelivery : true
            self.applySidebarTopology(
                rootTopologies,
                animated: animated
            )
        }
    }

    private var sidebarKind: SidebarKind {
        Self.sidebarKind(
            sidebarSelection: uiState.sidebarSelection,
            serverState: store.serverState,
            hasReviewJobs: store.hasReviewJobs,
            hasWorkspaces: store.workspaces.isEmpty == false,
            hasCodexSidebarContent: hasCodexSidebarContent
        )
    }

    private static func sidebarKind(
        sidebarSelection: SidebarPickerSelection?,
        serverState: CodexReviewServerState,
        hasReviewJobs: Bool,
        hasWorkspaces: Bool,
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
        let hasSidebarContent = hasReviewJobs || hasWorkspaces || hasCodexSidebarContent
        return hasSidebarContent ? .chatList : .empty
    }

    private var hasCodexSidebarContent: Bool {
        codexSidebarOutlineTree.roots.isEmpty == false
    }

    private var isUsingCodexSidebarOutline: Bool {
        hasCodexSidebarContent
    }

    private func sidebarWorkspaceTopologies() -> [SidebarWorkspaceTopology] {
        let workspaces = store.orderedWorkspaces
        let workspaceJobs = workspaces.map { workspace in
            (workspace: workspace, jobs: store.orderedJobs(in: workspace))
        }
        let activeJobIDs = Set(workspaceJobs.flatMap { $0.jobs.map(\.id) })
        let topologies = workspaceJobs.map { workspace, jobs in
            SidebarWorkspaceTopology(
                workspace: workspace,
                reviewRows: reviewChatIndex.rows(for: jobs)
            )
        }
        reviewChatIndex.prune(keeping: activeJobIDs)
        return topologies
    }

    private func sidebarRootTopologies(
        from workspaceTopologies: [SidebarWorkspaceTopology],
        filter: SidebarReviewChatFilter
    ) -> [SidebarRootTopology] {
        var topologiesBySectionID: [String: [SidebarWorkspaceTopology]] = [:]
        var sectionIdentityByID: [String: ReviewMonitorWorkspaceSectionIdentity] = [:]
        var sectionOrder: [String] = []

        for topology in workspaceTopologies {
            let identity = workspaceSectionIdentity(for: topology.workspace)
            if topologiesBySectionID[identity.id] == nil {
                sectionOrder.append(identity.id)
            }
            sectionIdentityByID[identity.id] = identity
            topologiesBySectionID[identity.id, default: []].append(topology)
        }

        var renderedSectionIDs: Set<String> = []
        let rootTopologies = sectionOrder.compactMap { sectionID -> SidebarRootTopology? in
            guard let topologies = topologiesBySectionID[sectionID],
                  let identity = sectionIdentityByID[sectionID]
            else {
                return nil
            }

            renderedSectionIDs.insert(identity.id)
            let sectionRows = Self.visibleReviewRows(
                in: topologies.flatMap(\.reviewRows),
                filter: filter
            )
            let section = workspaceSection(
                identity: identity,
                workspaces: topologies.map(\.workspace),
                reviewRows: sectionRows
            )
            return SidebarRootTopology(
                item: section,
                workspaces: section.workspaces,
                reviewRows: section.reviewRows
            )
        }
        workspaceSectionsByID = workspaceSectionsByID.filter { renderedSectionIDs.contains($0.key) }
        return rootTopologies
    }

    private func workspaceSectionIdentity(for workspace: CodexReviewWorkspace) -> ReviewMonitorWorkspaceSectionIdentity {
        if let identity = workspaceSectionIdentitiesByCWD[workspace.cwd] {
            return identity
        }
        let identity = ReviewMonitorWorkspaceSectioning.identity(for: workspace.cwd)
        workspaceSectionIdentitiesByCWD[workspace.cwd] = identity
        return identity
    }

    private func workspaceSection(
        identity: ReviewMonitorWorkspaceSectionIdentity,
        workspaces: [CodexReviewWorkspace],
        reviewRows: [ReviewMonitorSidebarReviewChatRow]
    ) -> SidebarWorkspaceSection {
        if let section = workspaceSectionsByID[identity.id] {
            section.title = identity.title
            section.workspaces = workspaces
            section.reviewRows = reviewRows
            return section
        }

        let section = SidebarWorkspaceSection(
            id: identity.id,
            title: identity.title,
            workspaces: workspaces,
            reviewRows: reviewRows
        )
        workspaceSectionsByID[identity.id] = section
        return section
    }

    private func applySidebarTopology(
        _ rootTopologies: [SidebarRootTopology],
        animated: Bool
    ) {
        let shouldAnimate = animated && shouldAnimateSidebarMutations
        currentRootTopologies = rootTopologies
        applyRootMembershipChange(
            rootTopologies.map(\.item),
            animated: shouldAnimate
        )
        applyReviewRowMembershipChange(rootTopologies, animated: shouldAnimate)
        scheduleOutlineSelectionReconciliation()
    }

    private var shouldAnimateSidebarMutations: Bool {
        view.window != nil && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false
    }

    private func applyRootMembershipChange(
        _ rootItems: [AnyObject],
        animated: Bool
    ) {
        let currentRootItems = displayedRootItems()
        let insertedRootItems = applyMembershipChange(
            currentItems: currentRootItems,
            targetItems: rootItems,
            parent: nil,
            animated: animated
        )
        applyStoredExpansionState(for: insertedRootItems)
    }

    private func applyReviewRowMembershipChange(
        _ rootTopologies: [SidebarRootTopology],
        animated: Bool
    ) {
        let rootItems = rootTopologies.map(\.item)
        for rootItem in displayedRootItems() {
            guard let topology = rootTopologies.first(where: { $0.item === rootItem }) else {
                continue
            }
            let displayedRows = displayedReviewRows(inRootItem: rootItem)
            let targetRows = topology.reviewRows
            guard hasSameIdentityOrder(displayedRows, targetRows) == false else {
                continue
            }
            if outlineView.isItemExpanded(rootItem) {
                applyMembershipChange(
                    currentItems: displayedRows,
                    targetItems: targetRows,
                    parent: rootItem,
                    animated: animated
                )
                continue
            }
            reloadRootItem(rootItem, allRootItems: rootItems)
        }
    }

    private func reloadOutline(rootItems: [AnyObject]) {
        clearSelectionIfNeeded(for: workspaces())

#if DEBUG
        fullReloadCountForTesting += 1
#endif
        isReconcilingSelection = true
        outlineView.reloadData()
        applyStoredExpansionState(for: rootItems)
        reconcileOutlineSelection()
        isReconcilingSelection = false
    }

    private func applyStoredExpansionState(for rootItems: [AnyObject]) {
        for rootItem in rootItems {
            setRootItem(rootItem, expanded: rootItemIsExpanded(rootItem))
        }
    }

    private func setWorkspace(_ workspace: CodexReviewWorkspace, expanded: Bool) {
        guard let rootItem = rootItem(containing: workspace) else {
            return
        }
        setRootItem(rootItem, expanded: expanded)
    }

    private func setRootItem(_ rootItem: AnyObject, expanded: Bool) {
        guard row(forRootItem: rootItem) != nil else {
            return
        }
        let outlineIsExpanded = outlineView.isItemExpanded(rootItem)
        if expanded && outlineIsExpanded == false {
            outlineView.expandItem(rootItem)
        } else if expanded == false && outlineIsExpanded {
            outlineView.collapseItem(rootItem)
        }
    }

    private func rootItemIsExpanded(_ rootItem: AnyObject) -> Bool {
        workspaceSection(from: rootItem)?.isExpanded ?? true
    }

    private func reloadRootItem(
        _ rootItem: AnyObject,
        allRootItems: [AnyObject]
    ) {
        guard let rootItem = allRootItems.first(where: { $0 === rootItem })
        else {
            return
        }

#if DEBUG
        workspaceReloadCountForTesting += 1
#endif
        isReconcilingSelection = true
        outlineView.reloadItem(rootItem, reloadChildren: true)
        setRootItem(rootItem, expanded: rootItemIsExpanded(rootItem))
        isReconcilingSelection = false
    }

    private func scheduleOutlineSelectionReconciliation() {
        Task { @MainActor [weak self] in
            self?.reconcileSelectionAfterOutlineMutation()
        }
    }

    private func reconcileSelectionAfterOutlineMutation() {
        let wasReconcilingSelection = isReconcilingSelection
        isReconcilingSelection = true
        reconcileOutlineSelection()
        isReconcilingSelection = wasReconcilingSelection
    }

    private func applySidebarKind(_ kind: SidebarKind) {
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
            guard let currentSection = workspaceSection(id: selectedSection.id) else {
                uiState.selection = nil
                outlineView.deselectAll(nil)
                return
            }

            if currentSection.selection != selectedSection {
                uiState.selection = .workspaceSection(currentSection.selection)
            }

            guard let row = row(forRootItem: currentSection) else {
                return
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
        } else if let section = workspaceSection(from: item) {
            uiState.selection = .workspaceSection(section.selection)
        } else if let row = reviewRow(from: item) {
            uiState.selection = row.chat.map(ReviewMonitorSelection.chat)
        } else {
            uiState.selection = nil
        }
    }

    private func triggerCancellation(for row: ReviewMonitorSidebarReviewChatRow) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await performCancellation(for: row)
        }
    }

    private func toggleWorkspaceExpansion(_ workspace: CodexReviewWorkspace) {
        guard let rootItem = rootItem(containing: workspace) else {
            return
        }
        setRootItem(rootItem, expanded: outlineView.isItemExpanded(rootItem) == false)
    }

    private func restoreSelectedReviewChatRowAfterExpansion(of section: SidebarWorkspaceSection) {
        guard let selectedRuntimeJob = runtimeJobForCurrentChatSelection(),
              section.workspaces.contains(where: { $0.cwd == selectedRuntimeJob.cwd })
        else {
            return
        }
        let selectedRuntimeJobID = selectedRuntimeJob.id
        DispatchQueue.main.async { [weak self, weak section] in
            guard let self,
                  let section,
                  let currentSelectedRuntimeJob = self.runtimeJobForCurrentChatSelection(),
                  section.isExpanded,
                  currentSelectedRuntimeJob.id == selectedRuntimeJobID,
                  let row = self.row(forJobID: selectedRuntimeJobID),
                  self.outlineView.selectedRow != row
            else {
                return
            }
            self.isReconcilingSelection = true
            self.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            self.isReconcilingSelection = false
        }
    }

    private func runtimeJobForCurrentChatSelection() -> CodexReviewJob? {
        guard isUsingCodexSidebarOutline == false else {
            return nil
        }
        switch uiState.selection {
        case .chat(let chat):
            return store.reviewJob(forChatID: chat.id, in: workspaces())
        case .workspaceSection, .workspace, nil:
            return nil
        }
    }

    private func makeContextMenu(at point: NSPoint) -> NSMenu? {
        let row = outlineView.row(at: point)
        guard row != -1,
              let reviewRow = reviewRow(atRow: row)
        else {
            return nil
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let cancelItem = NSMenuItem(
            title: "Cancel",
            action: #selector(handleCancelMenuItem(_:)),
            keyEquivalent: ""
        )
        cancelItem.target = self
        cancelItem.representedObject = reviewRow
        cancelItem.isEnabled = reviewRow.isTerminal == false && reviewRow.cancellationRequested == false
        menu.addItem(cancelItem)
        return menu
    }

    @objc
    private func handleCancelMenuItem(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? ReviewMonitorSidebarReviewChatRow else {
            return
        }
        triggerCancellation(for: row)
    }

    private func requestCancellation(for row: ReviewMonitorSidebarReviewChatRow) async throws {
        guard row.isTerminal == false,
              row.cancellationRequested == false
        else {
            return
        }
        let operation = row.operation
        _ = try await store.cancelReview(
            jobID: operation.jobID,
            sessionID: operation.sessionID,
            cancellation: .userInterface()
        )
    }

    private func performCancellation(for row: ReviewMonitorSidebarReviewChatRow) async {
        do {
            try await requestCancellation(for: row)
        } catch {
            handleCancellationFailure(error, for: row)
        }
    }

    private func handleCancellationFailure(_ error: Error, for row: ReviewMonitorSidebarReviewChatRow) {
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = description.isEmpty ? "Failed to cancel review." : description
        let operation = row.operation
        try? store.recordCancellationFailure(
            jobID: operation.jobID,
            sessionID: operation.sessionID,
            message: message
        )
    }

    private func clearSelectionIfNeeded(for workspaces: [CodexReviewWorkspace]) {
        guard selectionStillExists(uiState.selection, in: workspaces) == false else {
            return
        }
        uiState.selection = nil
        if outlineView.selectedRow != -1 {
            outlineView.deselectAll(nil)
        }
    }

    @discardableResult
    private func applyMembershipChange<Item: AnyObject>(
        currentItems: [Item],
        targetItems: [Item],
        parent: Any?,
        animated: Bool
    ) -> [Item] {
        guard hasSameIdentityOrder(currentItems, targetItems) == false else {
            return []
        }

        var insertedItems: [Item] = []
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? SidebarMutationAnimation.duration : 0
            context.allowsImplicitAnimation = animated

            var visibleItems = currentItems
            outlineView.beginUpdates()
            defer {
                outlineView.endUpdates()
            }

            for sourceIndex in visibleItems.indices.reversed() {
                guard targetItems.contains(where: { $0 === visibleItems[sourceIndex] }) == false else {
                    continue
                }
                outlineView.removeItems(
                    at: IndexSet(integer: sourceIndex),
                    inParent: parent,
                    withAnimation: animated ? SidebarMutationAnimation.removalOptions : []
                )
#if DEBUG
                incrementalMembershipChangeCountForTesting += 1
#endif
                visibleItems.remove(at: sourceIndex)
            }

            for targetIndex in targetItems.indices {
                let targetItem = targetItems[targetIndex]
                if visibleItems.contains(where: { $0 === targetItem }) {
                    continue
                }
                let insertionIndex = min(targetIndex, visibleItems.count)

                outlineView.insertItems(
                    at: IndexSet(integer: insertionIndex),
                    inParent: parent,
                    withAnimation: animated ? SidebarMutationAnimation.insertionOptions : []
                )
#if DEBUG
                incrementalMembershipChangeCountForTesting += 1
#endif
                visibleItems.insert(targetItem, at: insertionIndex)
                insertedItems.append(targetItem)
            }

            for targetIndex in targetItems.indices {
                guard targetIndex < visibleItems.count else {
                    continue
                }
                let targetItem = targetItems[targetIndex]
                if visibleItems[targetIndex] === targetItem {
                    continue
                }
                guard let sourceIndex = visibleItems.firstIndex(where: { $0 === targetItem }) else {
                    continue
                }
                outlineView.moveItem(
                    at: sourceIndex,
                    inParent: parent,
                    to: targetIndex,
                    inParent: parent
                )
#if DEBUG
                incrementalMoveCountForTesting += 1
#endif
                let movedItem = visibleItems.remove(at: sourceIndex)
                visibleItems.insert(movedItem, at: targetIndex)
            }
        }
        return insertedItems
    }

    private func hasSameIdentityOrder<Item: AnyObject>(_ lhs: [Item], _ rhs: [Item]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0 === $1 }
    }

    private func moveWorkspaceSectionInOutline(id: String, toRootIndex destinationIndex: Int) {
        guard let section = workspaceSection(id: id) else {
            return
        }
        moveRootItemInOutline(section, toRootIndex: destinationIndex)
    }

    private func moveRootItemInOutline(_ rootItem: AnyObject, toRootIndex destinationIndex: Int) {
        let currentRootItems = displayedRootItems()
        guard let sourceIndex = currentRootItems.firstIndex(where: { $0 === rootItem }),
              sourceIndex != destinationIndex
        else {
            return
        }
        moveOutlineItem(from: sourceIndex, to: destinationIndex, parent: nil)
    }

    private func moveReviewChatInOutline(id: String, in workspace: CodexReviewWorkspace, toIndex destinationIndex: Int) {
        let currentRows = displayedReviewRows(in: workspace)
        guard let sourceIndex = currentRows.firstIndex(where: { $0.operation.jobID == id }),
              let parentItem = rootItem(containing: workspace)
        else {
            return
        }
        let rootRows = displayedReviewRows(inRootItem: parentItem)
        guard let sourceRootIndex = rootRows.firstIndex(where: { $0.operation.jobID == id }),
              let workspaceRootStartIndex = rootRows.firstIndex(where: { $0.operation.cwd == workspace.cwd })
        else {
            return
        }
        let destinationRootIndex = workspaceRootStartIndex + destinationIndex
        guard sourceIndex != destinationIndex,
              sourceRootIndex != destinationRootIndex
        else {
            return
        }
        moveOutlineItem(from: sourceRootIndex, to: destinationRootIndex, parent: parentItem)
    }

    private func moveOutlineItem(from sourceIndex: Int, to destinationIndex: Int, parent: Any?) {
        let animated = shouldAnimateSidebarMutations
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? SidebarMutationAnimation.duration : 0
            context.allowsImplicitAnimation = animated

            outlineView.beginUpdates()
            outlineView.moveItem(
                at: sourceIndex,
                inParent: parent,
                to: destinationIndex,
                inParent: parent
            )
#if DEBUG
            incrementalMoveCountForTesting += 1
#endif
            outlineView.endUpdates()
        }
        reconcileSelectionAfterOutlineMutation()
    }

    private func displayedRootItems() -> [AnyObject] {
        (0..<outlineView.numberOfRows).compactMap { row in
            let item = outlineView.item(atRow: row)
            if let section = workspaceSection(from: item), outlineView.parent(forItem: item) == nil {
                return section
            }
            return nil
        }
    }

    private func displayedReviewRows(in workspace: CodexReviewWorkspace) -> [ReviewMonitorSidebarReviewChatRow] {
        (0..<outlineView.numberOfRows).compactMap { row in
            let item = outlineView.item(atRow: row)
            guard let reviewRow = reviewRow(from: item),
                  reviewRow.operation.cwd == workspace.cwd
            else {
                return nil
            }
            return reviewRow
        }
    }

    private func displayedReviewRows(inRootItem rootItem: AnyObject) -> [ReviewMonitorSidebarReviewChatRow] {
        (0..<outlineView.numberOfRows).compactMap { row in
            let item = outlineView.item(atRow: row)
            guard let reviewRow = reviewRow(from: item),
                  let parentItem = outlineView.parent(forItem: item) as? AnyObject,
                  parentItem === rootItem
            else {
                return nil
            }
            return reviewRow
        }
    }

    private func visibleReviewRows(in workspace: CodexReviewWorkspace) -> [ReviewMonitorSidebarReviewChatRow] {
        guard let section = workspaceSection(containing: workspace) else {
            return []
        }
        return section.reviewRows.filter { $0.operation.cwd == workspace.cwd }
    }

    private static func visibleReviewRows(
        in rows: [ReviewMonitorSidebarReviewChatRow],
        filter: SidebarReviewChatFilter
    ) -> [ReviewMonitorSidebarReviewChatRow] {
        guard filter.isActive else {
            return rows
        }

        let latestFinishedRow = filter.contains(.latestFinished)
            ? latestFinishedRow(in: rows)
            : nil
        return rows.filter { row in
            if filter.contains(.running),
               row.isTerminal == false
            {
                return true
            }
            return latestFinishedRow.map { $0 === row } ?? false
        }
    }

    private static func latestFinishedRow(
        in orderedRows: [ReviewMonitorSidebarReviewChatRow]
    ) -> ReviewMonitorSidebarReviewChatRow? {
        var latestRow: ReviewMonitorSidebarReviewChatRow?
        var latestDate = Date.distantPast
        for row in orderedRows {
            guard row.isTerminal else {
                continue
            }
            let finishedAt = row.presentation.endedAt
                ?? row.presentation.startedAt
                ?? .distantPast
            if latestRow == nil || finishedAt > latestDate {
                latestRow = row
                latestDate = finishedAt
            }
        }
        return latestRow
    }

    private func workspaceSection(from item: Any?) -> SidebarWorkspaceSection? {
        item as? SidebarWorkspaceSection
    }

    private func reviewRow(from item: Any?) -> ReviewMonitorSidebarReviewChatRow? {
        item as? ReviewMonitorSidebarReviewChatRow
    }

    private func codexSidebarNode(from item: Any?) -> ReviewMonitorCodexSidebarOutlineNode? {
        item as? ReviewMonitorCodexSidebarOutlineNode
    }

    private func shouldAllowSelection(of item: Any?) -> Bool {
        if codexSidebarNode(from: item) != nil {
            return true
        }
        return workspaceSection(from: item) != nil || reviewRow(from: item) != nil
    }

    private func configureCodexSidebarCell(
        _ view: ReviewMonitorWorkspaceCellView,
        node: ReviewMonitorCodexSidebarOutlineNode
    ) {
        switch node.item {
        case .section(let section):
            view.configure(title: section.title, toolTip: section.title, systemSymbolName: "folder")
        case .workspace(let workspace):
            view.configure(title: workspace.title, toolTip: workspace.cwd, systemSymbolName: "folder")
        case .chat(let chat):
            view.configure(
                title: chat.title,
                toolTip: chat.preview ?? chat.title,
                systemSymbolName: "bubble.left"
            )
        }
    }

    private func workspaces() -> [CodexReviewWorkspace] {
        store.orderedWorkspaces
    }

    private func filteredJobCount(in workspace: CodexReviewWorkspace) -> Int {
        visibleReviewRows(in: workspace).count
    }

    private func reviewRow(atRow row: Int) -> ReviewMonitorSidebarReviewChatRow? {
        guard row >= 0,
              let item = outlineView.item(atRow: row)
        else {
            return nil
        }
        return reviewRow(from: item)
    }

    private func row(for workspace: CodexReviewWorkspace) -> Int? {
        guard let rootItem = rootItem(containing: workspace) else {
            return nil
        }
        let row = outlineView.row(forItem: rootItem)
        return row == -1 ? nil : row
    }

    private func row(forRootItem rootItem: AnyObject) -> Int? {
        let row = outlineView.row(forItem: rootItem)
        return row == -1 ? nil : row
    }

    private func workspace(cwd: String) -> CodexReviewWorkspace? {
        store.workspace(cwd: cwd)
    }

    private func workspaceSection(id: String) -> SidebarWorkspaceSection? {
        workspaceSectionsByID[id]
    }

    private func workspaceSection(containing workspace: CodexReviewWorkspace) -> SidebarWorkspaceSection? {
        rootItem(containing: workspace).flatMap { workspaceSection(from: $0) }
    }

    private func rootItem(containing workspace: CodexReviewWorkspace) -> AnyObject? {
        workspaceSectionsByID.values.first { section in
            section.workspaces.contains(where: { $0.cwd == workspace.cwd })
        }
    }

    private func rootItem(containing row: ReviewMonitorSidebarReviewChatRow) -> AnyObject? {
        guard let workspace = workspace(cwd: row.operation.cwd) else {
            return nil
        }
        return rootItem(containing: workspace)
    }

    private func row(forJobID jobID: String) -> Int? {
        guard let rowItem = reviewChatIndex.row(jobID: jobID) else {
            return nil
        }
        let row = outlineView.row(forItem: rowItem)
        return row == -1 ? nil : row
    }

    private func row(forReviewChatID chatID: CodexThreadID) -> Int? {
        guard let rowItem = reviewChatIndex.row(chatID: chatID) else {
            return nil
        }
        let row = outlineView.row(forItem: rowItem)
        return row == -1 ? nil : row
    }

    private func row(forCurrentChatSelectionID chatID: CodexThreadID) -> Int? {
        if isUsingCodexSidebarOutline {
            return row(forCodexSidebarSelectionID: .chat(chatID))
        }
        return row(forReviewChatID: chatID)
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

    private func containsJob(id: String) -> Bool {
        job(withID: id) != nil
    }

    private func containsJob(id: String, in workspaces: [CodexReviewWorkspace]) -> Bool {
        job(withID: id, in: workspaces) != nil
    }

    private func selectionStillExists(_ selection: ReviewMonitorSelection?) -> Bool {
        selectionStillExists(selection, in: workspaces())
    }

    private func selectionStillExists(
        _ selection: ReviewMonitorSelection?,
        in workspaces: [CodexReviewWorkspace]
    ) -> Bool {
        guard let selection else {
            return true
        }
        switch selection {
        case .workspaceSection(let section):
            return workspaceSectionsByID[section.id] != nil
                || section.workspaceCWDs.contains { cwd in
                    workspaces.contains(where: { $0.cwd == cwd })
                }
        case .workspace(let workspace):
            return codexWorkspaceSelection(id: workspace.id) != nil
        case .chat(let chat):
            return currentChatSelection(id: chat.id, in: workspaces) != nil
        }
    }

    private func job(withID id: String) -> CodexReviewJob? {
        job(withID: id, in: workspaces())
    }

    private func job(withID id: String, in workspaces: [CodexReviewWorkspace]) -> CodexReviewJob? {
        guard let job = store.job(id: id),
              workspaces.contains(where: { $0.cwd == job.cwd })
        else {
            return nil
        }
        return job
    }

    private func reviewChatSelection(
        id: CodexThreadID,
        in workspaces: [CodexReviewWorkspace]
    ) -> ReviewMonitorCodexSidebarSnapshot.Chat? {
        reviewChatIndex.chat(id: id, in: workspaces)
    }

    private func currentChatSelection(id: CodexThreadID) -> ReviewMonitorCodexSidebarSnapshot.Chat? {
        currentChatSelection(id: id, in: workspaces())
    }

    private func currentChatSelection(
        id: CodexThreadID,
        in workspaces: [CodexReviewWorkspace]
    ) -> ReviewMonitorCodexSidebarSnapshot.Chat? {
        if isUsingCodexSidebarOutline {
            return codexChatSelection(id: id)
        }
        return reviewChatSelection(id: id, in: workspaces)
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

    private func codexChatSelection(id: CodexThreadID) -> ReviewMonitorCodexSidebarSnapshot.Chat? {
        guard let node = codexSidebarOutlineTree.node(rowID: .chat(id)),
              case .chat(let chat) = node.item
        else {
            return nil
        }
        return chat
    }

    private func workspaceReorderWouldChange(cwds: [String], beforeCWD: String?) -> Bool {
        let cwdSet = Set(cwds)
        guard cwdSet.isEmpty == false,
              beforeCWD.map({ cwdSet.contains($0) }) != true
        else {
            return false
        }

        let ordered = workspaces()
        let moving = ordered.filter { cwdSet.contains($0.cwd) }
        guard moving.isEmpty == false else {
            return false
        }

        let remaining = ordered.filter { cwdSet.contains($0.cwd) == false }
        let destinationIndex: Int
        if let beforeCWD {
            guard let beforeIndex = remaining.firstIndex(where: { $0.cwd == beforeCWD }) else {
                return false
            }
            destinationIndex = beforeIndex
        } else {
            destinationIndex = remaining.count
        }

        var reordered = remaining
        reordered.insert(contentsOf: moving, at: destinationIndex)
        return reordered.count == ordered.count &&
            zip(reordered, ordered).contains { $0.0 !== $0.1 }
    }

    private func dragPayload(for item: Any) -> SidebarDragPayload? {
        if let section = workspaceSection(from: item) {
            return .workspaceSection(id: section.id)
        }
        if let row = reviewRow(from: item) {
            let operation = row.operation
            return .reviewChat(jobID: operation.jobID, cwd: operation.cwd)
        }
        return nil
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
        case .workspaceSection(let id):
            resolvedWorkspaceSectionDrop(
                id: id,
                draggingLocation: draggingLocation,
                proposedItem: proposedItem,
                proposedChildIndex: index
            )
        case .reviewChat(let id, let cwd):
            resolvedReviewChatDrop(
                id: id,
                cwd: cwd,
                draggingLocation: draggingLocation,
                proposedItem: proposedItem,
                proposedChildIndex: index
            )
        }
    }

    private func resolvedWorkspaceSectionDrop(
        id: String,
        draggingLocation: NSPoint?,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> SidebarResolvedDrop? {
        let snapshot = DisplayedSidebarTopologySnapshot(rootTopologies: currentRootTopologies)
        guard let section = workspaceSection(id: id),
              snapshot.rootIndex(forRootItem: section) != nil,
              let destination = resolvedWorkspaceDropDestination(
                draggingLocation: draggingLocation,
                proposedItem: proposedItem,
                proposedChildIndex: index
              )
        else {
            return nil
        }

        let beforeCWD = snapshot.workspaceBeforeCWD(
            movingRootItem: section,
            rootInsertionIndex: destination.rootInsertionIndex
        )
        let cwds = section.workspaces.map(\.cwd)
        guard workspaceReorderWouldChange(cwds: cwds, beforeCWD: beforeCWD) else {
            return nil
        }
        let displayDestinationIndex = snapshot.displayDestinationIndex(
            movingRootItem: section,
            rootInsertionIndex: destination.rootInsertionIndex
        )
        let operation: SidebarResolvedDrop.Operation = .reorderWorkspaceSection(
            id: section.id,
            cwds: cwds,
            beforeCWD: beforeCWD,
            displayIndex: displayDestinationIndex
        )
        return SidebarResolvedDrop(
            operation: operation,
            dropItem: nil,
            dropChildIndex: destination.rootInsertionIndex
        )
    }

    private func resolvedWorkspaceDropDestination(
        draggingLocation: NSPoint?,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> SidebarWorkspaceDropDestination? {
        if proposedItem == nil,
           index != NSOutlineViewDropOnItemIndex
        {
            return workspaceRootDropDestination(rootInsertionIndex: index)
        }

        if let blankAreaDestination = blankAreaWorkspaceDropDestination(draggingLocation: draggingLocation) {
            return blankAreaDestination
        }

        if let targetSection = workspaceSection(from: proposedItem),
           let targetRootIndex = rootIndex(forRootItem: targetSection)
        {
            return workspaceRootDropDestination(
                rootInsertionIndex: workspaceRootInsertionIndex(
                    aroundRootItem: targetSection,
                    defaultIndex: targetRootIndex,
                    draggingLocation: draggingLocation
                )
            )
        }

        if let targetRow = reviewRow(from: proposedItem),
           let targetWorkspace = workspace(cwd: targetRow.operation.cwd),
           let targetSection = workspaceSection(containing: targetWorkspace),
           let targetRootIndex = rootIndex(forRootItem: targetSection)
        {
            return workspaceRootDropDestination(
                rootInsertionIndex: workspaceRootInsertionIndex(
                    aroundRootItem: targetSection,
                    defaultIndex: targetRootIndex,
                    draggingLocation: draggingLocation
                )
            )
        }

        return nil
    }

    private func resolvedWorkspaceInsertionIndex(
        draggingLocation: NSPoint?,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> Int? {
        resolvedWorkspaceDropDestination(
            draggingLocation: draggingLocation,
            proposedItem: proposedItem,
            proposedChildIndex: index
        )?.rootInsertionIndex
    }

    private func blankAreaWorkspaceDropDestination(
        draggingLocation: NSPoint?
    ) -> SidebarWorkspaceDropDestination? {
        guard let draggingLocation,
              outlineView.numberOfRows > 0
        else {
            return nil
        }

        let firstRowRect = outlineView.rect(ofRow: 0)
        if draggingLocation.y < firstRowRect.minY {
            return workspaceRootDropDestination(rootInsertionIndex: 0)
        }

        let lastRowRect = outlineView.rect(ofRow: outlineView.numberOfRows - 1)
        if draggingLocation.y > lastRowRect.maxY {
            return workspaceRootDropDestination(rootInsertionIndex: currentRootTopologies.count)
        }

        return nil
    }

    private func workspaceRootInsertionIndex(
        aroundRootItem rootItem: AnyObject,
        defaultIndex: Int,
        draggingLocation: NSPoint?
    ) -> Int {
        guard let draggingLocation,
              let sectionRect = rootSectionRect(forRootItem: rootItem)
        else {
            return max(0, min(defaultIndex, currentRootTopologies.count))
        }

        let insertionIndex = draggingLocation.y < sectionRect.midY
            ? defaultIndex
            : defaultIndex + 1
        return max(0, min(insertionIndex, currentRootTopologies.count))
    }

    private func workspaceRootDropDestination(rootInsertionIndex index: Int) -> SidebarWorkspaceDropDestination {
        let rootInsertionIndex = max(0, min(index, currentRootTopologies.count))
        return SidebarWorkspaceDropDestination(rootInsertionIndex: rootInsertionIndex)
    }

    private func rootIndex(containing workspace: CodexReviewWorkspace) -> Int? {
        guard let rootItem = rootItem(containing: workspace) else {
            return nil
        }
        return rootIndex(forRootItem: rootItem)
    }

    private func rootIndex(forRootItem rootItem: AnyObject) -> Int? {
        currentRootTopologies.firstIndex { $0.item === rootItem }
    }

    private func workspaceSectionRect(for workspace: CodexReviewWorkspace) -> NSRect? {
        guard let rootItem = rootItem(containing: workspace) else {
            return nil
        }
        return rootSectionRect(forRootItem: rootItem)
    }

    private func rootSectionRect(forRootItem rootItem: AnyObject) -> NSRect? {
        guard let rootRow = row(forRootItem: rootItem) else {
            return nil
        }

        var sectionRect = outlineView.rect(ofRow: rootRow)
        let isExpanded = workspaceSection(from: rootItem)?.isExpanded ?? false
        guard isExpanded,
              let lastRow = displayedReviewRows(inRootItem: rootItem).last,
              let lastReviewChatRow = row(forJobID: lastRow.operation.jobID)
        else {
            return sectionRect
        }

        sectionRect = sectionRect.union(outlineView.rect(ofRow: lastReviewChatRow))
        return sectionRect
    }

    private func resolvedReviewChatDrop(
        id: String,
        cwd: String,
        draggingLocation: NSPoint?,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> SidebarResolvedDrop? {
        guard uiState.sidebarReviewChatFilter.allowsReviewChatReordering else {
            return nil
        }
        guard let destination = resolvedReviewChatDropDestination(
            draggingLocation: draggingLocation,
            proposedItem: proposedItem,
            proposedChildIndex: index,
            sourceCWD: cwd
        ),
        destination.workspace.cwd == cwd
        else {
            return nil
        }

        let orderedJobs = store.orderedJobs(in: destination.workspace)
        let destinationVisibleRows = visibleReviewRows(in: destination.workspace)
        guard let visibleSourceIndex = destinationVisibleRows.firstIndex(where: { $0.operation.jobID == id }) else {
            return nil
        }

        let visibleInsertionIndex = max(0, min(destination.childIndex, destinationVisibleRows.count))
        let beforeJobID = reviewChatBeforeJobID(
            movingJobID: id,
            visibleInsertionIndex: visibleInsertionIndex,
            visibleRows: destinationVisibleRows,
            orderedJobs: orderedJobs,
            movesToFullOrderEnd: destination.movesToFullOrderEnd
        )
        let displayDestinationIndex = visibleInsertionIndex > visibleSourceIndex
            ? visibleInsertionIndex - 1
            : visibleInsertionIndex
        let clampedDisplayDestinationIndex = max(0, min(displayDestinationIndex, destinationVisibleRows.count - 1))
        let displayOrderChanges = clampedDisplayDestinationIndex != visibleSourceIndex
        guard destination.movesToFullOrderEnd || displayOrderChanges else {
            return nil
        }
        guard reviewChatReorderWouldChange(id: id, inWorkspace: cwd, beforeJobID: beforeJobID) else {
            return nil
        }
        let operation: SidebarResolvedDrop.Operation = .reorderReviewChat(
            jobID: id,
            cwd: cwd,
            beforeJobID: beforeJobID,
            displayIndex: clampedDisplayDestinationIndex
        )
        let dropPresentation = reviewChatDropPresentation(
            for: destination.workspace,
            childIndex: visibleInsertionIndex
        )
        return SidebarResolvedDrop(
            operation: operation,
            dropItem: dropPresentation.item,
            dropChildIndex: dropPresentation.childIndex
        )
    }

    private func reviewChatBeforeJobID(
        movingJobID: String,
        visibleInsertionIndex: Int,
        visibleRows: [ReviewMonitorSidebarReviewChatRow],
        orderedJobs: [CodexReviewJob],
        movesToFullOrderEnd: Bool
    ) -> String? {
        if movesToFullOrderEnd {
            return nil
        }
        if visibleInsertionIndex < visibleRows.count {
            let targetJobID = visibleRows[visibleInsertionIndex].operation.jobID
            return targetJobID == movingJobID ? movingJobID : targetJobID
        }
        guard let lastVisibleRow = visibleRows.last,
              let lastVisibleIndex = orderedJobs.firstIndex(where: { $0.id == lastVisibleRow.operation.jobID })
        else {
            return nil
        }
        let nextIndex = lastVisibleIndex + 1
        guard nextIndex < orderedJobs.count,
              orderedJobs[nextIndex].id != movingJobID
        else {
            return nil
        }
        return orderedJobs[nextIndex].id
    }

    private func reviewChatReorderWouldChange(
        id: String,
        inWorkspace cwd: String,
        beforeJobID: String?
    ) -> Bool {
        guard beforeJobID != id else {
            return false
        }
        let ordered = store.orderedJobs(inWorkspace: cwd)
        guard let movingJob = ordered.first(where: { $0.id == id }) else {
            return false
        }
        let remaining = ordered.filter { $0 !== movingJob }
        let destinationIndex: Int
        if let beforeJobID {
            guard let beforeIndex = remaining.firstIndex(where: { $0.id == beforeJobID }) else {
                return false
            }
            destinationIndex = beforeIndex
        } else {
            destinationIndex = remaining.count
        }
        var reordered = remaining
        reordered.insert(movingJob, at: destinationIndex)
        return reordered.count == ordered.count &&
            zip(reordered, ordered).contains { $0.0 !== $0.1 }
    }

    private func resolvedReviewChatDropDestination(
        draggingLocation: NSPoint?,
        proposedItem: Any?,
        proposedChildIndex index: Int,
        sourceCWD: String
    ) -> SidebarReviewChatDropDestination? {
        if let destination = blankAreaReviewChatDropDestination(
            draggingLocation: draggingLocation,
            sourceCWD: sourceCWD
        ) {
            return destination
        }

        if let section = workspaceSection(from: proposedItem),
           index != NSOutlineViewDropOnItemIndex
        {
            return resolvedReviewChatDropDestination(
                in: section,
                sourceCWD: sourceCWD,
                proposedRootChildIndex: index
            )
        }

        guard let targetRow = reviewRow(from: proposedItem),
              index == NSOutlineViewDropOnItemIndex
        else {
            return nil
        }
        return resolvedReviewChatDropDestination(
            around: targetRow,
            draggingLocation: draggingLocation,
            sourceCWD: sourceCWD
        )
    }

    private func resolvedReviewChatDropDestination(
        around targetRow: ReviewMonitorSidebarReviewChatRow,
        draggingLocation: NSPoint?,
        sourceCWD: String
    ) -> SidebarReviewChatDropDestination? {
        guard let draggingLocation,
              let targetWorkspace = workspace(cwd: targetRow.operation.cwd),
              let targetSection = workspaceSection(containing: targetWorkspace),
              let targetWorkspaceRootStartIndex = targetSection.reviewRows.firstIndex(where: { $0.operation.cwd == targetWorkspace.cwd }),
              let targetJobIndex = visibleReviewRows(in: targetWorkspace)
                .firstIndex(where: { $0.operation.jobID == targetRow.operation.jobID }),
              let outlineRow = row(forJobID: targetRow.operation.jobID)
        else {
            return nil
        }

        let targetRowRect = outlineView.rect(ofRow: outlineRow)
        let rootInsertionIndex = targetWorkspaceRootStartIndex
            + targetJobIndex
            + (draggingLocation.y < targetRowRect.midY ? 0 : 1)
        return resolvedReviewChatDropDestination(
            in: targetSection,
            sourceCWD: sourceCWD,
            proposedRootChildIndex: rootInsertionIndex
        )
    }

    private func blankAreaReviewChatDropDestination(
        draggingLocation: NSPoint?,
        sourceCWD: String
    ) -> SidebarReviewChatDropDestination? {
        guard let draggingLocation,
              outlineView.numberOfRows > 0
        else {
            return nil
        }

        let lastRowRect = outlineView.rect(ofRow: outlineView.numberOfRows - 1)
        guard draggingLocation.y > lastRowRect.maxY,
              let workspace = workspace(cwd: sourceCWD),
              let sourceSection = workspaceSection(containing: workspace),
              currentRootTopologies.last?.item === sourceSection,
              sourceSection.reviewRows.last?.operation.cwd == sourceCWD
        else {
            return nil
        }

        return SidebarReviewChatDropDestination(
            workspace: workspace,
            childIndex: visibleReviewRows(in: workspace).count,
            movesToFullOrderEnd: true
        )
    }

    private func resolvedReviewChatDropDestination(
        in section: SidebarWorkspaceSection,
        sourceCWD: String,
        proposedRootChildIndex index: Int
    ) -> SidebarReviewChatDropDestination? {
        guard let workspace = section.workspaces.first(where: { $0.cwd == sourceCWD }),
              let workspaceRootStartIndex = section.reviewRows.firstIndex(where: { $0.operation.cwd == sourceCWD })
        else {
            return nil
        }

        let workspaceJobCount = visibleReviewRows(in: workspace).count
        let workspaceRootEndIndex = workspaceRootStartIndex + workspaceJobCount
        let rootInsertionIndex = max(0, min(index, section.reviewRows.count))
        guard rootInsertionIndex >= workspaceRootStartIndex,
              rootInsertionIndex <= workspaceRootEndIndex
        else {
            return nil
        }

        return SidebarReviewChatDropDestination(
            workspace: workspace,
            childIndex: rootInsertionIndex - workspaceRootStartIndex,
            movesToFullOrderEnd: false
        )
    }

    private func reviewChatDropPresentation(
        for workspace: CodexReviewWorkspace,
        childIndex: Int
    ) -> (item: Any?, childIndex: Int) {
        guard let rootItem = rootItem(containing: workspace),
              let section = workspaceSection(from: rootItem),
              let workspaceRootStartIndex = section.reviewRows.firstIndex(where: { $0.operation.cwd == workspace.cwd })
        else {
            return (workspace, childIndex)
        }

        let rootChildIndex = workspaceRootStartIndex + childIndex
        return (section, max(0, min(rootChildIndex, section.reviewRows.count)))
    }

    @discardableResult
    private func applyResolvedDrop(_ resolvedDrop: SidebarResolvedDrop) -> Bool {
        switch resolvedDrop.operation {
        case .none:
            return false
        case .reorderWorkspaceSection(let id, let cwds, let beforeCWD, let displayIndex):
            guard store.reorderWorkspaces(cwds: cwds, beforeCWD: beforeCWD) else {
                return false
            }
            moveWorkspaceSectionInOutline(id: id, toRootIndex: displayIndex)
            return true
        case .reorderReviewChat(let id, let cwd, let beforeJobID, let displayIndex):
            let workspace = workspace(cwd: cwd)
            guard store.reorderJob(id: id, inWorkspace: cwd, beforeJobID: beforeJobID) else {
                return false
            }
            if let workspace {
                moveReviewChatInOutline(id: id, in: workspace, toIndex: displayIndex)
            }
            return true
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if isUsingCodexSidebarOutline {
            guard let item else {
                return codexSidebarOutlineTree.roots.count
            }
            if let node = codexSidebarNode(from: item) {
                return node.children.count
            }
            return 0
        }
        guard let item else {
            return currentRootTopologies.count
        }
        if let section = workspaceSection(from: item) {
            return section.reviewRows.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if isUsingCodexSidebarOutline {
            guard let item else {
                return codexSidebarOutlineTree.roots[index]
            }
            if let node = codexSidebarNode(from: item) {
                return node.children[index]
            }
            fatalError("Unsupported Codex sidebar item.")
        }
        guard let item else {
            return currentRootTopologies[index].item
        }
        if let section = workspaceSection(from: item) {
            return section.reviewRows[index]
        }
        fatalError("Unsupported sidebar item.")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let node = codexSidebarNode(from: item) {
            return node.isExpandable
        }
        return workspaceSection(from: item) != nil
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if codexSidebarNode(from: item) != nil {
            return rowHeights.workspace
        }
        if workspaceSection(from: item) != nil {
            return rowHeights.workspace
        }
        if reviewRow(from: item) != nil {
            return rowHeights.reviewChat
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
        let item = notification.userInfo?["NSObject"]
        if let section = workspaceSection(from: item) {
            if section.isExpanded == false {
                section.isExpanded = true
            }
            restoreSelectedReviewChatRowAfterExpansion(of: section)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        let item = notification.userInfo?["NSObject"]
        if let section = workspaceSection(from: item) {
            if section.isExpanded {
                section.isExpanded = false
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        if codexSidebarNode(from: item) != nil {
            return ReviewMonitorWorkspaceRowView()
        }
        if workspaceSection(from: item) != nil {
            return ReviewMonitorWorkspaceRowView()
        }
        if reviewRow(from: item) != nil {
            return ReviewMonitorReviewChatTableRowView()
        }
        return nil
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        if let node = codexSidebarNode(from: item) {
            let view = (outlineView.makeView(withIdentifier: Identifier.workspaceCell, owner: self) as? ReviewMonitorWorkspaceCellView)
                ?? ReviewMonitorWorkspaceCellView()
            view.identifier = Identifier.workspaceCell
            view.objectValue = node
            configureCodexSidebarCell(view, node: node)
            return view
        }

        if let section = workspaceSection(from: item) {
            let view = (outlineView.makeView(withIdentifier: Identifier.workspaceCell, owner: self) as? ReviewMonitorWorkspaceCellView)
                ?? ReviewMonitorWorkspaceCellView()
            view.identifier = Identifier.workspaceCell
            view.objectValue = section
            view.configure(title: section.title, toolTip: section.selection.subtitle)
            return view
        }

        if let row = reviewRow(from: item) {
            let view = (outlineView.makeView(withIdentifier: Identifier.reviewChatCell, owner: self) as? ReviewMonitorReviewChatCellView)
                ?? ReviewMonitorReviewChatCellView()
            view.identifier = Identifier.reviewChatCell
            view.configure(with: row)
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

    var sidebarTopologyObservationForTesting: PortableObservationTracking.Token? {
        sidebarTopologyObservation
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
        var titles: [String] = []
        for row in 0..<outlineView.numberOfRows {
            let item = outlineView.item(atRow: row)
            if let section = workspaceSection(from: item) {
                titles.append(section.title)
                continue
            }
        }
        return titles
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

    var sidebarWorkspaceReloadCountForTesting: Int {
        workspaceReloadCountForTesting
    }

    var sidebarIncrementalMoveCountForTesting: Int {
        incrementalMoveCountForTesting
    }

    var sidebarIncrementalMembershipChangeCountForTesting: Int {
        incrementalMembershipChangeCountForTesting
    }

    var isShowingEmptyStateForTesting: Bool {
        emptyStateViewController.view.isHidden == false
    }

    func selectReviewChatForTesting(id chatID: CodexThreadID) {
        guard let row = row(forCodexSidebarSelectionID: .chat(chatID)) ?? row(forReviewChatID: chatID) else {
            return
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func selectWorkspaceForTesting(_ workspace: CodexReviewWorkspace) {
        guard let row = row(for: workspace) else {
            return
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func clearSelectionForTesting() {
        uiState.selection = nil
        outlineView.deselectAll(nil)
    }

    var allWorkspaceRowsExpandedForTesting: Bool {
        currentRootTopologies.allSatisfy { topology in
            guard let section = workspaceSection(from: topology.item) else {
                return false
            }
            return section.isExpanded && outlineView.isItemExpanded(section)
        }
    }

    func workspaceIsSelectableForTesting(_ workspace: CodexReviewWorkspace) -> Bool {
        workspaceSection(containing: workspace).map(shouldAllowSelection(of:)) ?? false
    }

    func displayedReviewChatJobIDsForTesting(in workspace: CodexReviewWorkspace) -> [String] {
        var jobIDs: [String] = []
        for row in 0..<outlineView.numberOfRows {
            guard let reviewRow = reviewRow(from: outlineView.item(atRow: row)),
                  reviewRow.operation.cwd == workspace.cwd
            else {
                continue
            }
            jobIDs.append(reviewRow.operation.jobID)
        }
        return jobIDs
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

    func reviewChatRowHeightForTesting(_ job: CodexReviewJob) -> CGFloat? {
        guard let row = row(forJobID: job.id) else {
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
        guard let cellView = outlineView.view(
            atColumn: 0,
            row: row,
            makeIfNecessary: true
        ) as? ReviewMonitorWorkspaceCellView else {
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

    func reviewChatCellMinXForTesting(_ job: CodexReviewJob) -> CGFloat? {
        guard let row = row(forJobID: job.id) else {
            return nil
        }
        view.layoutSubtreeIfNeeded()
        guard let cellView = outlineView.view(
            atColumn: 0,
            row: row,
            makeIfNecessary: true
        ) as? ReviewMonitorReviewChatCellView else {
            return nil
        }
        outlineView.layoutSubtreeIfNeeded()
        return cellView.contentMinXForTesting(relativeTo: outlineView)
    }

    func reviewChatRowUsesReviewMonitorChatRowViewForTesting(_ job: CodexReviewJob) -> Bool {
        guard let row = row(forJobID: job.id),
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

    func cancelReviewChatForTesting(_ job: CodexReviewJob) async {
        guard let row = reviewChatIndex.row(jobID: job.id) else {
            return
        }
        await performCancellation(for: row)
    }

    func clickBlankAreaForTesting() {
        view.layoutSubtreeIfNeeded()
        let point = blankPointForTesting()
        precondition(
            outlineView.suppressesSelectionClearingForTesting(at: point),
            "Expected a blank click target outside any review chat item."
        )
        outlineView.mouseDown(with: mouseEventForTesting(at: point))
    }

    func clickWorkspaceHeaderForTesting(_ workspace: CodexReviewWorkspace) {
        view.layoutSubtreeIfNeeded()
        guard let row = row(for: workspace) else {
            preconditionFailure("Workspace row is not visible.")
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func presentContextMenuForTesting(
        for job: CodexReviewJob,
        presenter: @escaping (NSMenu) -> Void
    ) {
        view.layoutSubtreeIfNeeded()
        guard let row = row(forJobID: job.id) else {
            preconditionFailure("Review chat row is not visible.")
        }
        let rect = outlineView.rect(ofRow: row)
        let point = NSPoint(x: rect.midX, y: rect.midY)
        outlineView.presentContextMenuForTesting(at: point, presenter: presenter)
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
        workspaceSection(containing: workspace)?.isExpanded ?? false
    }

    func workspaceOutlineIsExpandedForTesting(_ workspace: CodexReviewWorkspace) -> Bool {
        guard let rootItem = rootItem(containing: workspace) else {
            return false
        }
        return outlineView.isItemExpanded(rootItem)
    }

    func toggleWorkspaceDisclosureForTesting(_ workspace: CodexReviewWorkspace) {
        guard row(for: workspace) != nil else {
            preconditionFailure("Workspace row is not visible.")
        }
        toggleWorkspaceExpansion(workspace)
    }

    func collapseWorkspaceInOutlineForTesting(_ workspace: CodexReviewWorkspace) {
        guard let rootItem = rootItem(containing: workspace),
              row(for: workspace) != nil
        else {
            preconditionFailure("Workspace row is not visible.")
        }
        outlineView.collapseItem(rootItem)
    }

    func expandWorkspaceInOutlineForTesting(_ workspace: CodexReviewWorkspace) {
        guard let rootItem = rootItem(containing: workspace),
              row(for: workspace) != nil
        else {
            preconditionFailure("Workspace row is not visible.")
        }
        outlineView.expandItem(rootItem)
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

    @discardableResult
    func performWorkspaceDropForTesting(
        _ workspace: CodexReviewWorkspace,
        toIndex index: Int
    ) -> Bool {
        guard let section = workspaceSection(containing: workspace),
              let resolvedDrop = resolvedDrop(
            for: .workspaceSection(id: section.id),
            proposedItem: nil,
            proposedChildIndex: index
        ) else {
            return false
        }
        return applyResolvedDrop(resolvedDrop)
    }

    @discardableResult
    func performWorkspaceDropForTesting(
        _ workspace: CodexReviewWorkspace,
        proposedWorkspace targetWorkspace: CodexReviewWorkspace
    ) -> Bool {
        guard let section = workspaceSection(containing: workspace),
              let targetSection = workspaceSection(containing: targetWorkspace),
              let resolvedDrop = resolvedDrop(
            for: .workspaceSection(id: section.id),
            proposedItem: targetSection,
            proposedChildIndex: NSOutlineViewDropOnItemIndex
        ) else {
            return false
        }
        return applyResolvedDrop(resolvedDrop)
    }

    func workspaceDropIsRejectedForTesting(
        _ workspace: CodexReviewWorkspace,
        proposedJob targetJob: CodexReviewJob
    ) -> Bool {
        guard let section = workspaceSection(containing: workspace),
              let targetRow = reviewChatIndex.row(jobID: targetJob.id)
        else {
            return true
        }
        return resolvedDrop(
            for: .workspaceSection(id: section.id),
            proposedItem: targetRow,
            proposedChildIndex: NSOutlineViewDropOnItemIndex
        ) == nil
    }

    @discardableResult
    func performWorkspaceDropForTesting(
        _ workspace: CodexReviewWorkspace,
        proposedJob targetJob: CodexReviewJob,
        hoveringBelowMidpoint: Bool
    ) -> Bool {
        guard let section = workspaceSection(containing: workspace),
              let targetRowItem = reviewChatIndex.row(jobID: targetJob.id),
              let targetRow = row(forJobID: targetJob.id)
        else {
            return false
        }
        let targetRowRect = outlineView.rect(ofRow: targetRow)
        let draggingLocation = NSPoint(
            x: targetRowRect.midX,
            y: hoveringBelowMidpoint ? targetRowRect.midY + 1 : targetRowRect.midY - 1
        )
        guard let resolvedDrop = resolvedDrop(
            for: .workspaceSection(id: section.id),
            draggingLocation: draggingLocation,
            proposedItem: targetRowItem,
            proposedChildIndex: NSOutlineViewDropOnItemIndex
        ) else {
            return false
        }
        return applyResolvedDrop(resolvedDrop)
    }

    func workspaceSectionCanStartDragForTesting(containing workspace: CodexReviewWorkspace) -> Bool {
        guard let section = workspaceSection(containing: workspace) else {
            return false
        }
        return dragPayload(for: section) != nil
    }

    @discardableResult
    func performWorkspaceSectionDropForTesting(
        containing workspace: CodexReviewWorkspace,
        toIndex index: Int
    ) -> Bool {
        guard let section = workspaceSection(containing: workspace),
              let resolvedDrop = resolvedDrop(
                for: .workspaceSection(id: section.id),
                proposedItem: nil,
                proposedChildIndex: index
              )
        else {
            return false
        }
        return applyResolvedDrop(resolvedDrop)
    }

    func workspaceInsertionIndexForTesting(
        _ workspace: CodexReviewWorkspace,
        hoveringBelowMidpoint: Bool
    ) -> Int? {
        guard let sectionRect = workspaceSectionRect(for: workspace) else {
            return nil
        }
        let point = NSPoint(
            x: sectionRect.midX,
            y: hoveringBelowMidpoint ? sectionRect.midY + 1 : sectionRect.midY - 1
        )
        return resolvedWorkspaceInsertionIndex(
            draggingLocation: point,
            proposedItem: workspaceSection(containing: workspace),
            proposedChildIndex: NSOutlineViewDropOnItemIndex
        )
    }

    func blankAreaWorkspaceInsertionIndexForTesting(atEnd: Bool) -> Int? {
        guard outlineView.numberOfRows > 0 else {
            return nil
        }
        let rowRect = outlineView.rect(ofRow: atEnd ? outlineView.numberOfRows - 1 : 0)
        let point = NSPoint(
            x: rowRect.midX,
            y: atEnd ? rowRect.maxY + 1 : rowRect.minY - 1
        )
        return resolvedWorkspaceInsertionIndex(
            draggingLocation: point,
            proposedItem: nil,
            proposedChildIndex: NSOutlineViewDropOnItemIndex
        )
    }

    @discardableResult
    func performReviewChatDropForTesting(
        _ job: CodexReviewJob,
        proposedWorkspace: CodexReviewWorkspace,
        childIndex: Int
    ) -> Bool {
        guard let section = workspaceSection(containing: proposedWorkspace),
              let resolvedDrop = resolvedDrop(
            for: .reviewChat(jobID: job.id, cwd: job.cwd),
            proposedItem: section,
            proposedChildIndex: childIndex
        ) else {
            return false
        }
        return applyResolvedDrop(resolvedDrop)
    }

    @discardableResult
    func performReviewChatDropForTesting(
        _ job: CodexReviewJob,
        proposedJob targetJob: CodexReviewJob,
        hoveringBelowMidpoint: Bool
    ) -> Bool {
        guard let targetRowItem = reviewChatIndex.row(jobID: targetJob.id),
              let targetRow = row(forJobID: targetJob.id)
        else {
            return false
        }
        let targetRowRect = outlineView.rect(ofRow: targetRow)
        let draggingLocation = NSPoint(
            x: targetRowRect.midX,
            y: hoveringBelowMidpoint ? targetRowRect.midY + 1 : targetRowRect.midY - 1
        )
        guard let resolvedDrop = resolvedDrop(
            for: .reviewChat(jobID: job.id, cwd: job.cwd),
            draggingLocation: draggingLocation,
            proposedItem: targetRowItem,
            proposedChildIndex: NSOutlineViewDropOnItemIndex
        ) else {
            return false
        }
        return applyResolvedDrop(resolvedDrop)
    }

    @discardableResult
    func performReviewChatDropForTesting(
        _ job: CodexReviewJob,
        proposedWorkspaceSectionContaining workspace: CodexReviewWorkspace,
        childIndex: Int
    ) -> Bool {
        guard let section = workspaceSection(containing: workspace),
              let resolvedDrop = resolvedDrop(
                for: .reviewChat(jobID: job.id, cwd: job.cwd),
                proposedItem: section,
                proposedChildIndex: childIndex
              )
        else {
            return false
        }
        return applyResolvedDrop(resolvedDrop)
    }

    func reviewChatDropIsRejectedForTesting(_ job: CodexReviewJob) -> Bool {
        resolvedDrop(
            for: .reviewChat(jobID: job.id, cwd: job.cwd),
            proposedItem: nil,
            proposedChildIndex: NSOutlineViewDropOnItemIndex
        ) == nil
    }

    @discardableResult
    func performJobBlankAreaDropForTesting(_ job: CodexReviewJob) -> Bool {
        guard outlineView.numberOfRows > 0,
              let workspace = workspace(cwd: job.cwd),
              let section = workspaceSection(containing: workspace)
        else {
            return false
        }
        let lastRowRect = outlineView.rect(ofRow: outlineView.numberOfRows - 1)
        let draggingLocation = NSPoint(x: lastRowRect.midX, y: lastRowRect.maxY + 1)
        guard let resolvedDrop = resolvedDrop(
            for: .reviewChat(jobID: job.id, cwd: job.cwd),
            draggingLocation: draggingLocation,
            proposedItem: section,
            proposedChildIndex: section.reviewRows.count
        ) else {
            return false
        }
        return applyResolvedDrop(resolvedDrop)
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
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
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
        set { }
    }
}

@MainActor
private final class ReviewMonitorReviewChatTableRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set { }
    }
}

@MainActor
private final class ReviewMonitorReviewChatCellView: NSTableCellView {
    private var hostingView: NSHostingView<ReviewMonitorChatRowView>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(with row: ReviewMonitorSidebarReviewChatRow) {
        objectValue = row
        toolTip = row.operation.cwd
        configureRow(row.presentation)
    }

    private func configureRow(_ row: ReviewMonitorSidebarChatRow) {
        if let hostingView {
            hostingView.rootView.row = row
        } else {
            let hostingView = NSHostingView(
                rootView: ReviewMonitorChatRowView(row: row)
            )
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            hostingView.setAccessibilityIdentifier("review-monitor.review-chat-row")
            addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: topAnchor),
                hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
                hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
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
        hostingView?.rootView.row.id
    }

    var hostingViewIdentityForTesting: ObjectIdentifier? {
        hostingView.map(ObjectIdentifier.init)
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
func makeReviewMonitorReviewChatCellViewForTesting(job: CodexReviewJob) -> NSTableCellView {
    let cellView = ReviewMonitorReviewChatCellView()
    cellView.configure(with: ReviewMonitorSidebarReviewChatRow(job: job))
    return cellView
}

@MainActor
func configureReviewMonitorReviewChatCellViewForTesting(
    _ cellView: NSTableCellView,
    job: CodexReviewJob
) {
    guard let cellView = cellView as? ReviewMonitorReviewChatCellView else {
        fatalError("Expected ReviewMonitorReviewChatCellView.")
    }
    cellView.configure(with: ReviewMonitorSidebarReviewChatRow(job: job))
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
#endif

@MainActor
private final class ReviewMonitorWorkspaceCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let contentStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(_ workspace: CodexReviewWorkspace) {
        objectValue = workspace
        configure(title: workspace.displayTitle, toolTip: workspace.cwd)
    }

    func configure(title: String, toolTip: String, systemSymbolName: String = "folder") {
        iconView.image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil)
        titleLabel.stringValue = title
        self.toolTip = toolTip
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
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    #if DEBUG
    func contentMinXForTesting(relativeTo view: NSView) -> CGFloat {
        layoutSubtreeIfNeeded()
        return convert(contentStack.frame, to: view).minX
    }
    #endif
}
