import AppKit
import ObservationBridge
import CodexReview
import SwiftUI

package enum SidebarLayout {
    static let disclosureGutterWidth: CGFloat = 16
}

@MainActor
final class ReviewMonitorSidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    enum SidebarKind: Equatable {
        case unavailable
        case empty
        case jobList
        case accountList
    }

    private enum Identifier {
        static let tableColumn = NSUserInterfaceItemIdentifier("ReviewMonitorJobs.Column")
        static let jobCell = NSUserInterfaceItemIdentifier("ReviewMonitorJobs.JobCell")
        static let workspaceCell = NSUserInterfaceItemIdentifier("ReviewMonitorJobs.WorkspaceCell")
    }

    private enum DragType {
        static let sidebarItem = NSPasteboard.PasteboardType("dev.codexreviewmcp.sidebar-item")
    }

    private struct SidebarRowHeights {
        let workspace: CGFloat
        let job: CGFloat

        @MainActor
        static func measure() -> SidebarRowHeights {
            SidebarRowHeights(
                workspace: measuredWorkspaceRowHeight(),
                job: measuredJobRowHeight()
            )
        }

        @MainActor
        private static func measuredWorkspaceRowHeight() -> CGFloat {
            let cellView = ReviewMonitorWorkspaceCellView()
            cellView.configure(CodexReviewWorkspace(cwd: "/tmp/workspace-alpha"))
            return ceil(cellView.fittingSize.height)
        }

        @MainActor
        private static func measuredJobRowHeight() -> CGFloat {
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
                ),
                logEntries: []
            )
            let cellView = ReviewMonitorJobCellView()
            cellView.configure(with: job)
            return ceil(cellView.fittingSize.height)
        }
    }

    private enum SidebarDragPayload: Codable, Equatable {
        case workspace(cwd: String)
        case job(id: String, cwd: String)
    }

    private struct SidebarResolvedDrop {
        enum Operation {
            case none
            case reorderWorkspace(cwd: String, toIndex: Int)
            case reorderJob(id: String, cwd: String, storeIndex: Int, displayIndex: Int)
        }

        let operation: Operation
        let dropItem: Any?
        let dropChildIndex: Int
    }

    private struct SidebarWorkspaceTopology {
        let workspace: CodexReviewWorkspace
        let jobs: [CodexReviewJob]
    }

    private enum SidebarMutationAnimation {
        static let duration: TimeInterval = 0.18
        static let insertionOptions: NSTableView.AnimationOptions = [.effectFade, .slideDown]
        static let removalOptions: NSTableView.AnimationOptions = [.effectFade, .slideUp]
    }

    private let store: CodexReviewStore
    private let uiState: ReviewMonitorUIState
    private let scrollView = NSScrollView()
    private let outlineView = ReviewMonitorSidebarOutlineView()
    private let accountsViewController: ReviewMonitorAccountsViewController
    private let emptyStateViewController = PlaceholderViewController(content: .noReviewJobs)
    private let unavailableView: NSHostingView<MCPServerUnavailableView>
    private let rowHeights: SidebarRowHeights

    private let sidebarKindObservationScope = ObservationScope()
    private let sidebarTopologyObservationScope = ObservationScope()
    private var sidebarSelectionDelivery: ObservationDelivery?
    private var sidebarStoreKindDelivery: ObservationDelivery?
    private var sidebarTopologyDelivery: ObservationDelivery?
    private var sidebarFilterDelivery: ObservationDelivery?
    private var isReconcilingSelection = false
#if DEBUG
    private var fullReloadCountForTesting = 0
    private var workspaceReloadCountForTesting = 0
    private var incrementalMoveCountForTesting = 0
    private var incrementalMembershipChangeCountForTesting = 0
#endif

    init(store: CodexReviewStore, uiState: ReviewMonitorUIState) {
        self.store = store
        self.uiState = uiState
        self.accountsViewController = ReviewMonitorAccountsViewController(store: store)
        self.unavailableView = NSHostingView(rootView: MCPServerUnavailableView(store: store))
        self.rowHeights = SidebarRowHeights.measure()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        configureOutlineView()
        bindObservation()
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
        outlineView.rowHeight = rowHeights.job
        outlineView.usesAutomaticRowHeights = false
        outlineView.floatsGroupRows = false
        outlineView.backgroundColor = .clear
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.intercellSpacing = NSSize(width: 0, height: 12)
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.setAccessibilityIdentifier("review-monitor.job-list")
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
        sidebarKindObservationScope.cancelAll()
        sidebarTopologyObservationScope.cancelAll()

        sidebarSelectionDelivery = sidebarKindObservationScope.observe(uiState) { [weak self] _, uiState in
            let sidebarSelection = uiState.sidebarSelection
            guard let self else {
                return
            }
            self.applySidebarKind(self.sidebarKind(sidebarSelection: sidebarSelection))
        }

        sidebarStoreKindDelivery = sidebarKindObservationScope.observe(store) { [weak self] _, store in
            let serverState = store.serverState
            let hasReviewJobs = store.hasReviewJobs
            guard let self else {
                return
            }
            self.applySidebarKind(self.sidebarKind(serverState: serverState, hasReviewJobs: hasReviewJobs))
        }

        sidebarTopologyDelivery = sidebarTopologyObservationScope.observe(store) { [weak self] event, _ in
            guard let self else {
                return
            }
            self.applySidebarTopology(
                self.sidebarWorkspaceTopologies,
                animated: event.kind != .initial
            )
        }

        sidebarFilterDelivery = sidebarTopologyObservationScope.observe(uiState) { [weak self] event, uiState in
            _ = uiState.sidebarJobFilter
            guard let self else {
                return
            }
            self.applySidebarTopology(
                self.sidebarWorkspaceTopologies,
                animated: event.kind != .initial
            )
        }
    }

    private var sidebarKind: SidebarKind {
        sidebarKind(
            sidebarSelection: uiState.sidebarSelection,
            serverState: store.serverState,
            hasReviewJobs: store.hasReviewJobs
        )
    }

    private func sidebarKind(
        sidebarSelection: SidebarPickerSelection? = nil,
        serverState: CodexReviewServerState? = nil,
        hasReviewJobs: Bool? = nil
    ) -> SidebarKind {
        if (sidebarSelection ?? uiState.sidebarSelection) == .account {
            return .accountList
        }
        if case .failed = serverState ?? store.serverState {
            return .unavailable
        }
        return (hasReviewJobs ?? store.hasReviewJobs) ? .jobList : .empty
    }

    private var sidebarWorkspaceTopologies: [SidebarWorkspaceTopology] {
        store.orderedWorkspaces.map { workspace in
            SidebarWorkspaceTopology(
                workspace: workspace,
                jobs: filteredJobs(in: workspace)
            )
        }
    }

    private func applySidebarTopology(
        _ workspaceTopologies: [SidebarWorkspaceTopology],
        animated: Bool
    ) {
        let shouldAnimate = animated && shouldAnimateSidebarMutations
        applyWorkspaceMembershipChange(
            workspaceTopologies.map(\.workspace),
            animated: shouldAnimate
        )
        applyJobMembershipChange(workspaceTopologies, animated: shouldAnimate)
    }

    private var shouldAnimateSidebarMutations: Bool {
        view.window != nil && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false
    }

    private func applyWorkspaceMembershipChange(
        _ workspaces: [CodexReviewWorkspace],
        animated: Bool
    ) {
        clearSelectionIfNeeded(for: workspaces)
        let currentWorkspaces = displayedWorkspaces()
        let insertedWorkspaces = applyMembershipChange(
            currentItems: currentWorkspaces,
            targetItems: workspaces,
            parent: nil,
            animated: animated
        )
        applyStoredExpansionState(for: insertedWorkspaces)
        reconcileSelectionAfterOutlineMutation()
    }

    private func applyJobMembershipChange(
        _ workspaceTopologies: [SidebarWorkspaceTopology],
        animated: Bool
    ) {
        let workspaces = workspaceTopologies.map(\.workspace)
        clearSelectionIfNeeded(for: workspaces)
        for workspace in displayedWorkspaces() {
            guard let topology = workspaceTopologies.first(where: { $0.workspace === workspace }) else {
                continue
            }
            let displayedJobs = displayedJobs(in: workspace)
            let targetJobs = topology.jobs
            guard hasSameIdentityOrder(displayedJobs, targetJobs) == false else {
                continue
            }
            if outlineView.isItemExpanded(workspace) {
                applyMembershipChange(
                    currentItems: displayedJobs,
                    targetItems: targetJobs,
                    parent: workspace,
                    animated: animated
                )
                reconcileSelectionAfterOutlineMutation()
                continue
            }
            reloadWorkspace(workspace, allWorkspaces: workspaces)
        }
    }

    private func reloadOutline(workspaces: [CodexReviewWorkspace]) {
        clearSelectionIfNeeded(for: workspaces)

#if DEBUG
        fullReloadCountForTesting += 1
#endif
        isReconcilingSelection = true
        outlineView.reloadData()
        applyStoredExpansionState(for: workspaces)
        reconcileOutlineSelection()
        isReconcilingSelection = false
    }

    private func applyStoredExpansionState(for workspaces: [CodexReviewWorkspace]) {
        for workspace in workspaces {
            setWorkspace(workspace, expanded: workspace.isExpanded)
        }
    }

    private func setWorkspace(_ workspace: CodexReviewWorkspace, expanded: Bool) {
        guard row(for: workspace) != nil else {
            return
        }
        let outlineIsExpanded = outlineView.isItemExpanded(workspace)
        if expanded && outlineIsExpanded == false {
            outlineView.expandItem(workspace)
        } else if expanded == false && outlineIsExpanded {
            outlineView.collapseItem(workspace)
        }
    }

    private func reloadWorkspace(
        _ workspace: CodexReviewWorkspace,
        allWorkspaces: [CodexReviewWorkspace]
    ) {
        clearSelectionIfNeeded(for: allWorkspaces)
        guard let workspace = allWorkspaces.first(where: { $0 === workspace })
        else {
            return
        }

#if DEBUG
        workspaceReloadCountForTesting += 1
#endif
        isReconcilingSelection = true
        outlineView.reloadItem(workspace, reloadChildren: true)
        setWorkspace(workspace, expanded: workspace.isExpanded)
        reconcileOutlineSelection()
        isReconcilingSelection = false
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
        case .jobList:
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
        case .workspace(let selectedWorkspace):
            guard let currentWorkspace = workspace(cwd: selectedWorkspace.cwd) else {
                uiState.selection = nil
                outlineView.deselectAll(nil)
                return
            }

            if currentWorkspace !== selectedWorkspace {
                uiState.selection = .workspace(currentWorkspace)
            }

            guard let row = row(for: currentWorkspace) else {
                return
            }
            guard outlineView.selectedRow != row else {
                return
            }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        case .job(let selectedJob):
            guard let currentJob = job(withID: selectedJob.id) else {
                uiState.selection = nil
                outlineView.deselectAll(nil)
                return
            }

            if currentJob !== selectedJob {
                uiState.selection = .job(currentJob)
            }

            guard let row = row(forJobID: currentJob.id) else {
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
        if let workspace = workspace(from: item) {
            uiState.selection = .workspace(workspace)
        } else if let job = job(from: item) {
            uiState.selection = .job(job)
        } else {
            uiState.selection = nil
        }
    }

    private func triggerCancellation(for job: CodexReviewJob) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await performCancellation(for: job)
        }
    }

    private func toggleWorkspaceExpansion(_ workspace: CodexReviewWorkspace) {
        setWorkspace(workspace, expanded: outlineView.isItemExpanded(workspace) == false)
    }

    private func restoreSelectedJobRowAfterExpansion(of workspace: CodexReviewWorkspace) {
        guard let selectedJob = uiState.selectedJobEntry,
              selectedJob.cwd == workspace.cwd
        else {
            return
        }
        let selectedJobID = selectedJob.id
        DispatchQueue.main.async { [weak self, weak workspace] in
            guard let self,
                  let workspace,
                  workspace.isExpanded,
                  self.uiState.selectedJobEntry?.id == selectedJobID,
                  let row = self.row(forJobID: selectedJobID),
                  self.outlineView.selectedRow != row
            else {
                return
            }
            self.isReconcilingSelection = true
            self.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            self.isReconcilingSelection = false
        }
    }

    private func makeContextMenu(at point: NSPoint) -> NSMenu? {
        let row = outlineView.row(at: point)
        guard row != -1,
              let job = job(atRow: row)
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
        cancelItem.representedObject = job
        cancelItem.isEnabled = job.isTerminal == false && job.cancellationRequested == false
        menu.addItem(cancelItem)
        return menu
    }

    @objc
    private func handleCancelMenuItem(_ sender: NSMenuItem) {
        guard let job = sender.representedObject as? CodexReviewJob else {
            return
        }
        triggerCancellation(for: job)
    }

    private func requestCancellation(for job: CodexReviewJob) async throws {
        guard job.isTerminal == false,
              job.cancellationRequested == false
        else {
            return
        }
        _ = try await store.cancelReview(
            jobID: job.id,
            sessionID: job.sessionID,
            cancellation: .userInterface()
        )
    }

    private func performCancellation(for job: CodexReviewJob) async {
        do {
            try await requestCancellation(for: job)
        } catch {
            handleCancellationFailure(error, for: job)
        }
    }

    private func handleCancellationFailure(_ error: Error, for job: CodexReviewJob) {
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = description.isEmpty ? "Failed to cancel review." : description
        do {
            try store.recordCancellationFailure(
                jobID: job.id,
                sessionID: job.sessionID,
                message: message
            )
        } catch {
            applyCancellationFailure(message: message, to: job)
        }
    }

    private func applyCancellationFailure(message: String, to job: CodexReviewJob) {
        if message == "Failed to cancel review." {
            job.core.output.summary = message
        } else {
            job.core.output.summary = "Failed to cancel review: \(message)"
        }
        job.core.lifecycle.errorMessage = message
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

    private func moveWorkspaceInOutline(cwd: String, toIndex destinationIndex: Int) {
        let currentWorkspaces = displayedWorkspaces()
        guard let sourceIndex = currentWorkspaces.firstIndex(where: { $0.cwd == cwd }),
              sourceIndex != destinationIndex
        else {
            return
        }
        moveOutlineItem(from: sourceIndex, to: destinationIndex, parent: nil)
    }

    private func moveJobInOutline(id: String, in workspace: CodexReviewWorkspace, toIndex destinationIndex: Int) {
        let currentJobs = displayedJobs(in: workspace)
        guard let sourceIndex = currentJobs.firstIndex(where: { $0.id == id }),
              sourceIndex != destinationIndex
        else {
            return
        }
        moveOutlineItem(from: sourceIndex, to: destinationIndex, parent: workspace)
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

    private func displayedWorkspaces() -> [CodexReviewWorkspace] {
        (0..<outlineView.numberOfRows).compactMap { row in
            workspace(from: outlineView.item(atRow: row))
        }
    }

    private func displayedJobs(in workspace: CodexReviewWorkspace) -> [CodexReviewJob] {
        (0..<outlineView.numberOfRows).compactMap { row in
            let item = outlineView.item(atRow: row)
            guard let job = job(from: item),
                  let parentWorkspace = outlineView.parent(forItem: item) as? CodexReviewWorkspace,
                  parentWorkspace === workspace
            else {
                return nil
            }
            return job
        }
    }

    private func filteredJobs(in workspace: CodexReviewWorkspace) -> [CodexReviewJob] {
        let filter = uiState.sidebarJobFilter
        return store.orderedJobs(in: workspace).filter { filter.includes($0) }
    }

    private func workspace(from item: Any?) -> CodexReviewWorkspace? {
        item as? CodexReviewWorkspace
    }

    private func job(from item: Any?) -> CodexReviewJob? {
        item as? CodexReviewJob
    }

    private func shouldAllowSelection(of item: Any?) -> Bool {
        workspace(from: item) != nil || job(from: item) != nil
    }

    private func workspaces() -> [CodexReviewWorkspace] {
        store.orderedWorkspaces
    }

    private func filteredJobCount(in workspace: CodexReviewWorkspace) -> Int {
        filteredJobs(in: workspace).count
    }

    private func job(atRow row: Int) -> CodexReviewJob? {
        guard row >= 0,
              let item = outlineView.item(atRow: row)
        else {
            return nil
        }
        return job(from: item)
    }

    private func row(for workspace: CodexReviewWorkspace) -> Int? {
        let row = outlineView.row(forItem: workspace)
        return row == -1 ? nil : row
    }

    private func workspace(cwd: String) -> CodexReviewWorkspace? {
        store.workspace(cwd: cwd)
    }

    private func row(forJobID jobID: String) -> Int? {
        guard let job = job(withID: jobID) else {
            return nil
        }
        let row = outlineView.row(forItem: job)
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
        case .workspace(let workspace):
            return workspaces.contains(where: { $0.cwd == workspace.cwd })
        case .job(let job):
            return containsJob(id: job.id, in: workspaces)
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

    private func workspaceIndex(cwd: String) -> Int? {
        workspaces().firstIndex(where: { $0.cwd == cwd })
    }

    private func workspace(containing job: CodexReviewJob) -> CodexReviewWorkspace? {
        store.workspace(containing: job)
    }

    private func dragPayload(for item: Any) -> SidebarDragPayload? {
        if let workspace = workspace(from: item) {
            return .workspace(cwd: workspace.cwd)
        }
        if let job = job(from: item) {
            return .job(id: job.id, cwd: job.cwd)
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
        draggingInfo: (any NSDraggingInfo)? = nil,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> SidebarResolvedDrop? {
        switch payload {
        case .workspace(let cwd):
            resolvedWorkspaceDrop(
                cwd: cwd,
                draggingInfo: draggingInfo,
                proposedItem: proposedItem,
                proposedChildIndex: index
            )
        case .job(let id, let cwd):
            resolvedJobDrop(
                id: id,
                cwd: cwd,
                proposedItem: proposedItem,
                proposedChildIndex: index
            )
        }
    }

    private func resolvedWorkspaceDrop(
        cwd: String,
        draggingInfo: (any NSDraggingInfo)?,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> SidebarResolvedDrop? {
        guard let sourceIndex = workspaceIndex(cwd: cwd),
              let insertionIndex = resolvedWorkspaceInsertionIndex(
                draggingInfo: draggingInfo,
                proposedItem: proposedItem,
                proposedChildIndex: index
              )
        else {
            return nil
        }

        let destinationIndex = insertionIndex > sourceIndex
            ? insertionIndex - 1
            : insertionIndex
        let clampedDestinationIndex = max(0, min(destinationIndex, workspaces().count - 1))
        let operation: SidebarResolvedDrop.Operation = clampedDestinationIndex == sourceIndex
            ? .none
            : .reorderWorkspace(cwd: cwd, toIndex: clampedDestinationIndex)
        return SidebarResolvedDrop(
            operation: operation,
            dropItem: nil,
            dropChildIndex: insertionIndex
        )
    }

    private func resolvedWorkspaceInsertionIndex(
        draggingInfo: (any NSDraggingInfo)?,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> Int? {
        resolvedWorkspaceInsertionIndex(
            draggingLocation: draggingInfo.map { outlineView.convert($0.draggingLocation, from: nil) },
            proposedItem: proposedItem,
            proposedChildIndex: index
        )
    }

    private func resolvedWorkspaceInsertionIndex(
        draggingLocation: NSPoint?,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> Int? {
        if proposedItem == nil,
           index != NSOutlineViewDropOnItemIndex
        {
            return max(0, min(index, workspaces().count))
        }

        if let blankAreaInsertionIndex = blankAreaWorkspaceInsertionIndex(draggingLocation: draggingLocation) {
            return blankAreaInsertionIndex
        }

        guard let targetWorkspace = workspace(from: proposedItem),
              let workspaceIndex = workspaceIndex(cwd: targetWorkspace.cwd)
        else {
            return nil
        }

        return workspaceInsertionIndex(
            aroundWorkspace: targetWorkspace,
            defaultIndex: workspaceIndex,
            draggingLocation: draggingLocation
        )
    }

    private func blankAreaWorkspaceInsertionIndex(
        draggingLocation: NSPoint?
    ) -> Int? {
        guard let draggingLocation,
              outlineView.numberOfRows > 0
        else {
            return nil
        }

        let firstRowRect = outlineView.rect(ofRow: 0)
        if draggingLocation.y < firstRowRect.minY {
            return 0
        }

        let lastRowRect = outlineView.rect(ofRow: outlineView.numberOfRows - 1)
        if draggingLocation.y > lastRowRect.maxY {
            return workspaces().count
        }

        return nil
    }

    private func workspaceInsertionIndex(
        aroundWorkspace workspace: CodexReviewWorkspace,
        defaultIndex: Int,
        draggingLocation: NSPoint?
    ) -> Int {
        guard let draggingLocation,
              let sectionRect = workspaceSectionRect(for: workspace)
        else {
            return max(0, min(defaultIndex, workspaces().count))
        }

        let insertionIndex = draggingLocation.y < sectionRect.midY
            ? (workspaceIndex(cwd: workspace.cwd) ?? defaultIndex)
            : workspaceIndex(cwd: workspace.cwd).map { $0 + 1 } ?? defaultIndex
        return max(0, min(insertionIndex, workspaces().count))
    }

    private func workspaceSectionRect(for workspace: CodexReviewWorkspace) -> NSRect? {
        guard let workspaceRow = row(for: workspace) else {
            return nil
        }

        var sectionRect = outlineView.rect(ofRow: workspaceRow)
        guard workspace.isExpanded,
              let lastJob = filteredJobs(in: workspace).last,
              let lastJobRow = row(forJobID: lastJob.id)
        else {
            return sectionRect
        }

        sectionRect = sectionRect.union(outlineView.rect(ofRow: lastJobRow))
        return sectionRect
    }

    private func resolvedJobDrop(
        id: String,
        cwd: String,
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> SidebarResolvedDrop? {
        guard let destination = resolvedJobDropDestination(
            proposedItem: proposedItem,
            proposedChildIndex: index
        ),
        destination.workspace.cwd == cwd
        else {
            return nil
        }

        let orderedJobs = store.orderedJobs(in: destination.workspace)
        let visibleJobs = filteredJobs(in: destination.workspace)
        guard let sourceIndex = orderedJobs.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        guard let visibleSourceIndex = visibleJobs.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        let visibleInsertionIndex = max(0, min(destination.childIndex, visibleJobs.count))
        let storeInsertionIndex = storeJobInsertionIndex(
            visibleInsertionIndex: visibleInsertionIndex,
            visibleJobs: visibleJobs,
            orderedJobs: orderedJobs
        )
        let storeDestinationIndex = storeInsertionIndex > sourceIndex
            ? storeInsertionIndex - 1
            : storeInsertionIndex
        let clampedStoreDestinationIndex = max(0, min(storeDestinationIndex, orderedJobs.count - 1))
        let displayDestinationIndex = visibleInsertionIndex > visibleSourceIndex
            ? visibleInsertionIndex - 1
            : visibleInsertionIndex
        let clampedDisplayDestinationIndex = max(0, min(displayDestinationIndex, visibleJobs.count - 1))
        let operation: SidebarResolvedDrop.Operation = clampedDisplayDestinationIndex == visibleSourceIndex
            || clampedStoreDestinationIndex == sourceIndex
            ? .none
            : .reorderJob(
                id: id,
                cwd: cwd,
                storeIndex: clampedStoreDestinationIndex,
                displayIndex: clampedDisplayDestinationIndex
            )
        return SidebarResolvedDrop(
            operation: operation,
            dropItem: destination.workspace,
            dropChildIndex: visibleInsertionIndex
        )
    }

    private func storeJobInsertionIndex(
        visibleInsertionIndex: Int,
        visibleJobs: [CodexReviewJob],
        orderedJobs: [CodexReviewJob]
    ) -> Int {
        if visibleInsertionIndex < visibleJobs.count,
           let targetIndex = orderedJobs.firstIndex(where: { $0 === visibleJobs[visibleInsertionIndex] }) {
            return targetIndex
        }
        guard let lastVisibleJob = visibleJobs.last,
              let lastVisibleIndex = orderedJobs.firstIndex(where: { $0 === lastVisibleJob })
        else {
            return orderedJobs.count
        }
        return lastVisibleIndex + 1
    }

    private func resolvedJobDropDestination(
        proposedItem: Any?,
        proposedChildIndex index: Int
    ) -> (workspace: CodexReviewWorkspace, childIndex: Int)? {
        if let workspace = workspace(from: proposedItem),
           index != NSOutlineViewDropOnItemIndex
        {
            return (workspace, index)
        }

        guard let job = job(from: proposedItem),
              index == NSOutlineViewDropOnItemIndex,
              let workspace = workspace(containing: job),
              let jobIndex = filteredJobs(in: workspace).firstIndex(where: { $0.id == job.id })
        else {
            return nil
        }
        return (workspace, jobIndex)
    }

    @discardableResult
    private func applyResolvedDrop(_ resolvedDrop: SidebarResolvedDrop) -> Bool {
        switch resolvedDrop.operation {
        case .none:
            return true
        case .reorderWorkspace(let cwd, let toIndex):
            store.reorderWorkspace(cwd: cwd, toIndex: toIndex)
            moveWorkspaceInOutline(cwd: cwd, toIndex: toIndex)
            return true
        case .reorderJob(let id, let cwd, let storeIndex, let displayIndex):
            let workspace = workspace(cwd: cwd)
            store.reorderJob(id: id, inWorkspace: cwd, toIndex: storeIndex)
            if let workspace {
                moveJobInOutline(id: id, in: workspace, toIndex: displayIndex)
            }
            return true
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else {
            return workspaces().count
        }
        guard let workspace = workspace(from: item) else {
            return 0
        }
        return filteredJobCount(in: workspace)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else {
            return workspaces()[index]
        }
        guard let workspace = workspace(from: item) else {
            fatalError("Unsupported sidebar item.")
        }
        return filteredJobs(in: workspace)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let workspace = workspace(from: item) else {
            return false
        }
        return filteredJobCount(in: workspace) > 0
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if workspace(from: item) != nil {
            return rowHeights.workspace
        }
        if job(from: item) != nil {
            return rowHeights.job
        }
        return rowHeights.job
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        self.outlineView(outlineView, isItemExpandable: item)
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
        guard let payload = dragPayload(from: info),
              let resolvedDrop = resolvedDrop(
                for: payload,
                draggingInfo: info,
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
        guard let payload = dragPayload(from: info),
              let resolvedDrop = resolvedDrop(
                for: payload,
                draggingInfo: info,
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
        guard let workspace = workspace(from: notification.userInfo?["NSObject"]) else {
            return
        }
        if workspace.isExpanded == false {
            workspace.isExpanded = true
        }
        restoreSelectedJobRowAfterExpansion(of: workspace)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let workspace = workspace(from: notification.userInfo?["NSObject"]) else {
            return
        }
        if workspace.isExpanded {
            workspace.isExpanded = false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        if workspace(from: item) != nil {
            return ReviewMonitorWorkspaceRowView()
        }
        if job(from: item) != nil {
            return ReviewMonitorJobTableRowView()
        }
        return nil
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        if let workspace = workspace(from: item) {
            let view = (outlineView.makeView(withIdentifier: Identifier.workspaceCell, owner: self) as? ReviewMonitorWorkspaceCellView)
                ?? ReviewMonitorWorkspaceCellView()
            view.identifier = Identifier.workspaceCell
            view.configure(workspace)
            return view
        }

        if let job = job(from: item) {
            let view = (outlineView.makeView(withIdentifier: Identifier.jobCell, owner: self) as? ReviewMonitorJobCellView)
                ?? ReviewMonitorJobCellView()
            view.identifier = Identifier.jobCell
            view.configure(with: job)
            return view
        }
        return nil
    }

}

#if DEBUG
@MainActor
extension ReviewMonitorSidebarViewController {
    var sidebarSelectionDeliveryForTesting: ObservationDelivery? {
        sidebarSelectionDelivery
    }

    var sidebarStoreKindDeliveryForTesting: ObservationDelivery? {
        sidebarStoreKindDelivery
    }

    var sidebarTopologyDeliveryForTesting: ObservationDelivery? {
        sidebarTopologyDelivery
    }

    var sidebarFilterDeliveryForTesting: ObservationDelivery? {
        sidebarFilterDelivery
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
            guard let workspace = workspace(from: outlineView.item(atRow: row)) else {
                continue
            }
            titles.append(workspace.displayTitle)
        }
        return titles
    }

    var selectedJobForTesting: CodexReviewJob? {
        uiState.selectedJobEntry
    }

    var selectedWorkspaceForTesting: CodexReviewWorkspace? {
        uiState.selectedWorkspaceEntry
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

    func selectJobForTesting(_ job: CodexReviewJob) {
        guard let row = row(forJobID: job.id) else {
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
        workspaces().allSatisfy { $0.isExpanded && outlineView.isItemExpanded($0) }
    }

    func workspaceIsSelectableForTesting(_ workspace: CodexReviewWorkspace) -> Bool {
        shouldAllowSelection(of: workspace)
    }

    func displayedJobIDsForTesting(in workspace: CodexReviewWorkspace) -> [String] {
        var jobIDs: [String] = []
        for row in 0..<outlineView.numberOfRows {
            guard let job = job(from: outlineView.item(atRow: row)),
                  job.cwd == workspace.cwd
            else {
                continue
            }
            jobIDs.append(job.id)
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

    var expectedJobRowRectHeightForTesting: CGFloat {
        rowHeights.job + outlineView.intercellSpacing.height
    }

    func workspaceRowHeightForTesting(_ workspace: CodexReviewWorkspace) -> CGFloat? {
        guard let row = row(for: workspace) else {
            return nil
        }
        view.layoutSubtreeIfNeeded()
        return outlineView.rect(ofRow: row).height
    }

    func jobRowHeightForTesting(_ job: CodexReviewJob) -> CGFloat? {
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

    func jobCellMinXForTesting(_ job: CodexReviewJob) -> CGFloat? {
        guard let row = row(forJobID: job.id) else {
            return nil
        }
        view.layoutSubtreeIfNeeded()
        guard let cellView = outlineView.view(
            atColumn: 0,
            row: row,
            makeIfNecessary: true
        ) as? ReviewMonitorJobCellView else {
            return nil
        }
        outlineView.layoutSubtreeIfNeeded()
        return cellView.contentMinXForTesting(relativeTo: outlineView)
    }

    func jobRowUsesReviewMonitorJobRowViewForTesting(_ job: CodexReviewJob) -> Bool {
        guard let row = row(forJobID: job.id),
              let cellView = outlineView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: true
              ) as? ReviewMonitorJobCellView
        else {
            return false
        }
        return cellView.isHostingReviewMonitorJobRowViewForTesting
    }

    func cancelJobForTesting(_ job: CodexReviewJob) async {
        await performCancellation(for: job)
    }

    func clickBlankAreaForTesting() {
        view.layoutSubtreeIfNeeded()
        let point = blankPointForTesting()
        precondition(
            outlineView.suppressesSelectionClearingForTesting(at: point),
            "Expected a blank click target outside any job item."
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
            preconditionFailure("Job row is not visible.")
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
        workspace.isExpanded
    }

    func workspaceOutlineIsExpandedForTesting(_ workspace: CodexReviewWorkspace) -> Bool {
        outlineView.isItemExpanded(workspace)
    }

    var selectedOutlineJobIDForTesting: String? {
        guard outlineView.selectedRow != -1 else {
            return nil
        }
        return job(atRow: outlineView.selectedRow)?.id
    }

    func toggleWorkspaceDisclosureForTesting(_ workspace: CodexReviewWorkspace) {
        guard row(for: workspace) != nil else {
            preconditionFailure("Workspace row is not visible.")
        }
        toggleWorkspaceExpansion(workspace)
    }

    func collapseWorkspaceInOutlineForTesting(_ workspace: CodexReviewWorkspace) {
        guard row(for: workspace) != nil else {
            preconditionFailure("Workspace row is not visible.")
        }
        outlineView.collapseItem(workspace)
    }

    func expandWorkspaceInOutlineForTesting(_ workspace: CodexReviewWorkspace) {
        guard row(for: workspace) != nil else {
            preconditionFailure("Workspace row is not visible.")
        }
        outlineView.expandItem(workspace)
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
        guard let resolvedDrop = resolvedDrop(
            for: .workspace(cwd: workspace.cwd),
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
        guard let resolvedDrop = resolvedDrop(
            for: .workspace(cwd: workspace.cwd),
            proposedItem: targetWorkspace,
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
        resolvedDrop(
            for: .workspace(cwd: workspace.cwd),
            proposedItem: targetJob,
            proposedChildIndex: NSOutlineViewDropOnItemIndex
        ) == nil
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
            proposedItem: workspace,
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
    func performJobDropForTesting(
        _ job: CodexReviewJob,
        proposedWorkspace: CodexReviewWorkspace,
        childIndex: Int
    ) -> Bool {
        guard let resolvedDrop = resolvedDrop(
            for: .job(id: job.id, cwd: job.cwd),
            proposedItem: proposedWorkspace,
            proposedChildIndex: childIndex
        ) else {
            return false
        }
        return applyResolvedDrop(resolvedDrop)
    }

    func jobDropIsRejectedForTesting(_ job: CodexReviewJob) -> Bool {
        resolvedDrop(
            for: .job(id: job.id, cwd: job.cwd),
            proposedItem: nil,
            proposedChildIndex: NSOutlineViewDropOnItemIndex
        ) == nil
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
        // Workspace rows keep AppKit's native disclosure gutter. Job rows do
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
private final class ReviewMonitorJobTableRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set { }
    }
}

@MainActor
private final class ReviewMonitorJobCellView: NSTableCellView {
    private var hostingView: NSHostingView<ReviewMonitorJobRowView>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(with job: CodexReviewJob) {
        objectValue = job
        toolTip = job.cwd
        if let hostingView {
            hostingView.rootView.job = job
        } else {
            let hostingView = NSHostingView(
                rootView: ReviewMonitorJobRowView(job: job)
            )
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            hostingView.setAccessibilityIdentifier("review-monitor.job-row")
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
    var isHostingReviewMonitorJobRowViewForTesting: Bool {
        hostingView != nil
    }

    var hostedJobIDForTesting: String? {
        hostingView?.rootView.job.id
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
func makeReviewMonitorJobCellViewForTesting(job: CodexReviewJob) -> NSTableCellView {
    let cellView = ReviewMonitorJobCellView()
    cellView.configure(with: job)
    return cellView
}

@MainActor
func configureReviewMonitorJobCellViewForTesting(
    _ cellView: NSTableCellView,
    job: CodexReviewJob
) {
    guard let cellView = cellView as? ReviewMonitorJobCellView else {
        fatalError("Expected ReviewMonitorJobCellView.")
    }
    cellView.configure(with: job)
}

@MainActor
func reviewMonitorJobCellHostedJobIDForTesting(_ cellView: NSTableCellView) -> String? {
    guard let cellView = cellView as? ReviewMonitorJobCellView else {
        return nil
    }
    return cellView.hostedJobIDForTesting
}

@MainActor
func reviewMonitorJobCellHostingViewIdentityForTesting(
    _ cellView: NSTableCellView
) -> ObjectIdentifier? {
    guard let cellView = cellView as? ReviewMonitorJobCellView else {
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
        iconView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        titleLabel.stringValue = workspace.displayTitle
        toolTip = workspace.cwd
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
