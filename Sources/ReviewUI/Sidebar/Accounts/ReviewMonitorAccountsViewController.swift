import AppKit
import ObservationBridge
import CodexReview
import SwiftUI

@MainActor
final class ReviewMonitorAccountsViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private enum Identifier {
        static let tableColumn = NSUserInterfaceItemIdentifier("ReviewMonitorAccounts.Column")
        static let accountCell = NSUserInterfaceItemIdentifier("ReviewMonitorAccounts.AccountCell")
    }

    private enum DragType {
        static let account = NSPasteboard.PasteboardType("dev.codexreviewmcp.account")
    }

    private let store: CodexReviewStore
    private let scrollView = NSScrollView()
    private let outlineView = ReviewMonitorAccountsOutlineView()

    private let authObservationScope = ObservationScope()
    private var accountListDelivery: ObservationDelivery?
    private var accountSelectionDelivery: ObservationDelivery?
    private var accountPromptDelivery: ObservationDelivery?
    private var isApplyingAuthSelection = false
    private var presentedPendingAccountAction: CodexReviewAuthModel.PendingAccountAction?
    private var presentedAccountActionAlert: CodexReviewAuthModel.AccountActionAlert?

#if DEBUG
    private var fullReloadCountForTesting = 0
    private var incrementalMembershipChangeCountForTesting = 0
    private var incrementalMoveCountForTesting = 0
#endif

    init(store: CodexReviewStore) {
        self.store = store
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

    override func viewDidAppear() {
        super.viewDidAppear()
        presentAccountPromptsIfNeeded(
            pendingAccountAction: auth.pendingAccountAction,
            accountActionAlert: auth.accountActionAlert
        )
    }

    private var auth: CodexReviewAuthModel {
        store.auth
    }

    private var accounts: [CodexAccount] {
        auth.accounts
    }

    private func configureHierarchy() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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
        outlineView.indentationPerLevel = 0
        outlineView.indentationMarkerFollowsCell = false
        outlineView.rowSizeStyle = .custom
        outlineView.usesAutomaticRowHeights = true
        outlineView.style = .sourceList
        outlineView.backgroundColor = .clear
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.intercellSpacing = NSSize(width: 0, height: 12)
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.setAccessibilityIdentifier("review-monitor.account-list")
        outlineView.registerForDraggedTypes([DragType.account])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask([], forLocal: false)
        outlineView.draggingDestinationFeedbackStyle = .gap
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.contextMenuProvider = { [weak self] point in
            self?.makeContextMenu(at: point)
        }
        outlineView.dragPasteboardWriterProvider = { [weak self] row in
            guard let self,
                  let account = account(atRow: row)
            else {
                return nil
            }
            return pasteboardWriter(for: account)
        }

        scrollView.documentView = outlineView
    }

    private func bindObservation() {
        authObservationScope.cancelAll()

        accountListDelivery = authObservationScope.observe(auth, tracking: { auth in
            for account in auth.accounts {
                _ = account.accountKey
            }
        }) { [weak self] _, auth in
            let accounts = auth.accounts
            let selectedAccount = auth.selectedAccount
            self?.applyAccountTopology(
                accounts: accounts,
                selectedAccount: selectedAccount
            )
        }

        accountSelectionDelivery = authObservationScope.observe(auth) { [weak self] _, auth in
            let selectedAccount = auth.selectedAccount
            guard let self else {
                return
            }
            self.reconcileSelection(
                selectedAccount: selectedAccount,
                accounts: self.displayedAccounts()
            )
        }

        accountPromptDelivery = authObservationScope.observe(auth, tracking: { auth in
            _ = auth.pendingAccountAction
            _ = auth.accountActionAlert
        }) { [weak self] _, auth in
            let pendingAccountAction = auth.pendingAccountAction
            let accountActionAlert = auth.accountActionAlert
            self?.presentAccountPromptsIfNeeded(
                pendingAccountAction: pendingAccountAction,
                accountActionAlert: accountActionAlert
            )
        }
    }

    private func applyAccountTopology(
        accounts: [CodexAccount],
        selectedAccount: CodexAccount?
    ) {
        applyAccountMembershipChange(accounts)
        reconcileSelection(selectedAccount: selectedAccount, accounts: accounts)
    }

    private func displayedAccounts() -> [CodexAccount] {
        (0..<outlineView.numberOfRows).compactMap { row in
            account(atRow: row)
        }
    }

    private func applyAccountMembershipChange(_ targetAccounts: [CodexAccount]) {
        let currentAccounts = displayedAccounts()
        guard hasSameIdentityOrder(currentAccounts, targetAccounts) == false else {
            return
        }

        var visibleAccounts = currentAccounts
        outlineView.beginUpdates()
        defer {
            outlineView.endUpdates()
        }

        for sourceIndex in visibleAccounts.indices.reversed() {
            guard targetAccounts.contains(where: { $0 === visibleAccounts[sourceIndex] }) == false else {
                continue
            }
            outlineView.removeItems(
                at: IndexSet(integer: sourceIndex),
                inParent: nil,
                withAnimation: []
            )
#if DEBUG
            incrementalMembershipChangeCountForTesting += 1
#endif
            visibleAccounts.remove(at: sourceIndex)
        }

        for targetIndex in targetAccounts.indices {
            let targetAccount = targetAccounts[targetIndex]
            if visibleAccounts.contains(where: { $0 === targetAccount }) {
                continue
            }
            let insertionIndex = min(targetIndex, visibleAccounts.count)
            outlineView.insertItems(
                at: IndexSet(integer: insertionIndex),
                inParent: nil,
                withAnimation: []
            )
#if DEBUG
            incrementalMembershipChangeCountForTesting += 1
#endif
            visibleAccounts.insert(targetAccount, at: insertionIndex)
        }

        for targetIndex in targetAccounts.indices {
            guard targetIndex < visibleAccounts.count else {
                continue
            }
            let targetAccount = targetAccounts[targetIndex]
            if visibleAccounts[targetIndex] === targetAccount {
                continue
            }
            guard let sourceIndex = visibleAccounts.firstIndex(where: { $0 === targetAccount }) else {
                continue
            }
            outlineView.moveItem(
                at: sourceIndex,
                inParent: nil,
                to: targetIndex,
                inParent: nil
            )
#if DEBUG
            incrementalMoveCountForTesting += 1
#endif
            let movedAccount = visibleAccounts.remove(at: sourceIndex)
            visibleAccounts.insert(movedAccount, at: targetIndex)
        }
    }

    private func hasSameIdentityOrder(_ lhs: [CodexAccount], _ rhs: [CodexAccount]) -> Bool {
        lhs.count == rhs.count &&
            zip(lhs, rhs).allSatisfy { left, right in
                left === right
            }
    }

    private func reconcileSelection() {
        reconcileSelection(selectedAccount: auth.selectedAccount)
    }

    private func reconcileSelection(selectedAccount: CodexAccount?) {
        reconcileSelection(selectedAccount: selectedAccount, accounts: accounts)
    }

    private func reconcileSelection(
        selectedAccount: CodexAccount?,
        accounts: [CodexAccount]
    ) {
        guard let selectedAccount,
              let row = row(forAccountKey: selectedAccount.accountKey, accounts: accounts)
        else {
            if outlineView.selectedRow != -1 {
                outlineView.deselectAll(nil)
            }
            return
        }

        guard outlineView.selectedRow != row else {
            return
        }
        selectAccountRow(row)
    }

    private func selectAccountRow(_ row: Int) {
        let wasApplyingAuthSelection = isApplyingAuthSelection
        isApplyingAuthSelection = true
        defer {
            isApplyingAuthSelection = wasApplyingAuthSelection
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func performReorder(accountKey: String, toIndex destinationIndex: Int) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                try await store.reorderPersistedAccount(accountKey: accountKey, toIndex: destinationIndex)
            } catch {
                store.auth.presentAccountActionAlert(
                    title: "Failed to Reorder Accounts",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func presentAccountPromptsIfNeeded() {
        presentAccountPromptsIfNeeded(
            pendingAccountAction: auth.pendingAccountAction,
            accountActionAlert: auth.accountActionAlert
        )
    }

    private func presentAccountPromptsIfNeeded(
        pendingAccountAction: CodexReviewAuthModel.PendingAccountAction?,
        accountActionAlert: CodexReviewAuthModel.AccountActionAlert?
    ) {
        presentPendingAccountActionIfNeeded(pendingAccountAction)
        presentAccountActionAlertIfNeeded(accountActionAlert)
    }

    private func presentPendingAccountActionIfNeeded(
        _ action: CodexReviewAuthModel.PendingAccountAction?
    ) {
        guard let action else {
            presentedPendingAccountAction = nil
            return
        }
        guard presentedPendingAccountAction != action,
              let window = view.window
        else {
            return
        }

        presentedPendingAccountAction = action

        let alert = NSAlert()
        alert.messageText = String(localized: action.confirmationTitle)
        alert.informativeText = String(localized: action.confirmationMessage)
        alert.addButton(withTitle: String(localized: action.confirmationButtonTitle))
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.presentedPendingAccountAction = nil
                guard self.auth.pendingAccountAction == action else {
                    self.reconcileSelection()
                    self.presentAccountPromptsIfNeeded()
                    return
                }
                if response == .alertFirstButtonReturn {
                    self.store.confirmPendingAccountAction()
                } else {
                    self.store.cancelPendingAccountAction()
                    self.reconcileSelection()
                }
                self.presentAccountPromptsIfNeeded()
            }
        }
    }

    private func presentAccountActionAlertIfNeeded(
        _ accountActionAlert: CodexReviewAuthModel.AccountActionAlert?
    ) {
        guard let accountActionAlert else {
            presentedAccountActionAlert = nil
            reconcileSelection()
            return
        }
        guard presentedAccountActionAlert != accountActionAlert,
              let window = view.window
        else {
            return
        }

        presentedAccountActionAlert = accountActionAlert
        reconcileSelection()

        let alert = NSAlert()
        alert.messageText = String(localized: accountActionAlert.title)
        alert.informativeText = accountActionAlert.message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.presentedAccountActionAlert = nil
                if self.auth.accountActionAlert == accountActionAlert {
                    self.store.dismissAccountActionAlert()
                }
                self.reconcileSelection()
                self.presentAccountPromptsIfNeeded()
            }
        }
    }

    private func makeContextMenu(at point: NSPoint) -> NSMenu? {
        let row = outlineView.row(at: point)
        guard row != -1,
              let account = account(atRow: row)
        else {
            return nil
        }

        return NSHostingMenu(
            rootView: AccountContextMenuView(
                store: store,
                account: account
            )
        )
    }

    private func account(from item: Any?) -> CodexAccount? {
        item as? CodexAccount
    }

    private func account(atRow row: Int) -> CodexAccount? {
        guard row >= 0,
              let item = outlineView.item(atRow: row)
        else {
            return nil
        }
        return account(from: item)
    }

    private func row(for account: CodexAccount) -> Int? {
        row(forAccountKey: account.accountKey)
    }

    private func row(forAccountKey accountKey: String) -> Int? {
        row(forAccountKey: accountKey, accounts: accounts)
    }

    private func row(
        forAccountKey accountKey: String,
        accounts: [CodexAccount]
    ) -> Int? {
        guard let account = accounts.first(where: { $0.accountKey == accountKey }) else {
            return nil
        }
        let row = outlineView.row(forItem: account)
        return row == -1 ? nil : row
    }

    private func persistedAccountIndex(accountKey: String) -> Int? {
        auth.persistedAccounts.firstIndex { $0.accountKey == accountKey }
    }

    private func dragAccountKey(from draggingInfo: any NSDraggingInfo) -> String? {
        draggingInfo.draggingPasteboard.string(forType: DragType.account)
    }

    private func resolvedDropIndex(
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> Int? {
        let persistedCount = auth.persistedAccounts.count
        guard persistedCount > 1 else {
            return nil
        }

        if let account = account(from: item) {
            if let accountIndex = persistedAccountIndex(accountKey: account.accountKey) {
                return accountIndex
            }
            guard accounts.indices.contains(persistedCount),
                  accounts[persistedCount].accountKey == account.accountKey
            else {
                return nil
            }
            return persistedCount
        }

        guard item == nil else {
            return nil
        }

        let rawIndex = index == NSOutlineViewDropOnItemIndex ? persistedCount : index
        return max(0, min(rawIndex, persistedCount))
    }

    private func reorderDestinationIndex(accountKey: String, dropIndex: Int) -> Int? {
        let persistedCount = auth.persistedAccounts.count
        guard let sourceIndex = persistedAccountIndex(accountKey: accountKey),
              persistedCount > 1
        else {
            return nil
        }

        let clampedDropIndex = max(0, min(dropIndex, persistedCount))
        let adjustedDropIndex = clampedDropIndex > sourceIndex
            ? clampedDropIndex - 1
            : clampedDropIndex
        return max(0, min(adjustedDropIndex, persistedCount - 1))
    }

    private func pasteboardWriter(for account: CodexAccount) -> (any NSPasteboardWriting)? {
        guard auth.persistedAccounts.count > 1,
              persistedAccountIndex(accountKey: account.accountKey) != nil
        else {
            return nil
        }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(account.accountKey, forType: DragType.account)
        return pasteboardItem
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? accounts.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        accounts[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        isApplyingAuthSelection && account(from: item) != nil
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard account(from: item) != nil else {
            return nil
        }
        return ReviewMonitorAccountTableRowView()
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let account = account(from: item) else {
            return nil
        }

        let view = (outlineView.makeView(withIdentifier: Identifier.accountCell, owner: self) as? ReviewMonitorAccountCellView)
            ?? ReviewMonitorAccountCellView(store: store)
        view.identifier = Identifier.accountCell
        view.configure(account: account)
        return view
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        pasteboardWriterForItem item: Any
    ) -> (any NSPasteboardWriting)? {
        account(from: item).flatMap(pasteboardWriter(for:))
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let accountKey = dragAccountKey(from: info),
              persistedAccountIndex(accountKey: accountKey) != nil,
              let dropIndex = resolvedDropIndex(proposedItem: item, proposedChildIndex: index)
        else {
            return []
        }

        outlineView.setDropItem(nil, dropChildIndex: dropIndex)
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: any NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let accountKey = dragAccountKey(from: info),
              persistedAccountIndex(accountKey: accountKey) != nil,
              let dropIndex = resolvedDropIndex(proposedItem: item, proposedChildIndex: index),
              let destinationIndex = reorderDestinationIndex(accountKey: accountKey, dropIndex: dropIndex)
        else {
            return false
        }

        performReorder(accountKey: accountKey, toIndex: destinationIndex)
        return true
    }
}

#if DEBUG
@MainActor
extension ReviewMonitorAccountsViewController {
    var accountListDeliveryForTesting: ObservationDelivery? {
        accountListDelivery
    }

    var accountSelectionDeliveryForTesting: ObservationDelivery? {
        accountSelectionDelivery
    }

    var accountPromptDeliveryForTesting: ObservationDelivery? {
        accountPromptDelivery
    }

    var accountFullReloadCountForTesting: Int {
        fullReloadCountForTesting
    }

    var accountIncrementalMembershipChangeCountForTesting: Int {
        incrementalMembershipChangeCountForTesting
    }

    var accountIncrementalMoveCountForTesting: Int {
        incrementalMoveCountForTesting
    }

    var displayedAccountEmailsForTesting: [String] {
        (0..<outlineView.numberOfRows).compactMap { row in
            account(atRow: row)?.email
        }
    }

    var accountListUsesOutlineViewForTesting: Bool {
        scrollView.documentView === outlineView
    }

    func focusAccountListForTesting() {
        _ = view.window?.makeFirstResponder(outlineView)
    }

    var accountListHasFirstResponderForTesting: Bool {
        view.window?.firstResponder === outlineView
    }

    var selectedAccountEmailForTesting: String? {
        guard outlineView.selectedRow != -1 else {
            return nil
        }
        return account(atRow: outlineView.selectedRow)?.email
    }

    func selectAccountRowForTesting(_ account: CodexAccount) {
        guard let row = row(for: account) else {
            preconditionFailure("Account row is not visible.")
        }
        selectAccountRow(row)
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

    func presentContextMenuForTesting(
        for account: CodexAccount,
        presenter: @escaping (NSMenu) -> Void
    ) {
        view.layoutSubtreeIfNeeded()
        guard let row = row(for: account) else {
            preconditionFailure("Account row is not visible.")
        }
        let rect = outlineView.rect(ofRow: row)
        let point = NSPoint(x: rect.midX, y: rect.midY)
        outlineView.presentContextMenuForTesting(at: point, presenter: presenter)
    }

    func accountRowUsesReviewMonitorAccountCellViewForTesting(_ account: CodexAccount) -> Bool {
        guard let row = row(for: account),
              outlineView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: true
              ) is ReviewMonitorAccountCellView
        else {
            return false
        }
        return true
    }

    func accountRowUsesSwiftUIRowViewForTesting(_ account: CodexAccount) -> Bool {
        guard let row = row(for: account),
              let cellView = outlineView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: true
              ) as? ReviewMonitorAccountCellView
        else {
            return false
        }
        return cellView.isHostingReviewMonitorAccountRowViewForTesting
    }

    func dragPasteboardAccountKeyForTesting(_ account: CodexAccount) -> String? {
        guard let row = row(for: account) else {
            preconditionFailure("Account row is not visible.")
        }
        return outlineView.dragPasteboardStringForTesting(
            row: row,
            type: DragType.account
        )
    }

    func clickBlankAreaForTesting() {
        view.layoutSubtreeIfNeeded()
        let point = blankPointForTesting()
        precondition(
            outlineView.suppressesSelectionClearingForTesting(at: point),
            "Expected a blank click target outside any account item."
        )
        outlineView.mouseDown(with: mouseEventForTesting(at: point))
    }

    func allowsUserSelectionForTesting(_ account: CodexAccount) -> Bool {
        guard let row = row(for: account) else {
            preconditionFailure("Account row is not visible.")
        }
        return outlineView(
            outlineView,
            shouldSelectItem: outlineView.item(atRow: row) as Any
        )
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
            fatalError("Accounts view controller must be attached to a window for click testing.")
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

    @discardableResult
    func performAccountDropForTesting(
        _ account: CodexAccount,
        proposedChildIndex index: Int
    ) async -> Bool {
        await performAccountDropForTesting(
            account,
            proposedItem: nil,
            proposedChildIndex: index
        )
    }

    @discardableResult
    func performAccountDropForTesting(
        _ account: CodexAccount,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) async -> Bool {
        guard let dropIndex = resolvedDropIndex(proposedItem: item, proposedChildIndex: index),
              let destinationIndex = reorderDestinationIndex(accountKey: account.accountKey, dropIndex: dropIndex)
        else {
            return false
        }

        do {
            try await store.reorderPersistedAccount(
                accountKey: account.accountKey,
                toIndex: destinationIndex
            )
            return true
        } catch {
            return false
        }
    }
}
#endif

@MainActor
private final class ReviewMonitorAccountsOutlineView: NSOutlineView {
    var contextMenuProvider: ((NSPoint) -> NSMenu?)?
    var dragPasteboardWriterProvider: ((Int) -> (any NSPasteboardWriting)?)?
    private var pendingExplicitDragRow: Int?
    private var isPresentingContextMenu = false
    private weak var contextMenuFirstResponder: NSResponder?
    private var previousContextMenu: NSMenu?

    override var acceptsFirstResponder: Bool {
        isPresentingContextMenu ? false : super.acceptsFirstResponder
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        pendingExplicitDragRow = clickedRow
        guard shouldSuppressSelectionClearing(clickedRow: clickedRow) == false else {
            pendingExplicitDragRow = nil
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let row = pendingExplicitDragRow,
              beginExplicitDrag(forRow: row, event: event)
        else {
            super.mouseDragged(with: event)
            return
        }
        pendingExplicitDragRow = nil
    }

    override func mouseUp(with event: NSEvent) {
        pendingExplicitDragRow = nil
        super.mouseUp(with: event)
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

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        guard isPresentingContextMenu else {
            return
        }
        endContextMenuPresentation()
    }

    private func shouldSuppressSelectionClearing(clickedRow: Int) -> Bool {
        selectedRow != -1 && clickedRow == -1
    }

    private func shouldSuppressSelectionClearing(at point: NSPoint) -> Bool {
        shouldSuppressSelectionClearing(clickedRow: row(at: point))
    }

    private func beginExplicitDrag(forRow row: Int, event: NSEvent) -> Bool {
        guard row != -1,
              let pasteboardWriter = dragPasteboardWriterProvider?(row)
        else {
            return false
        }

        let rowRect = rect(ofRow: row)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardWriter)
        draggingItem.setDraggingFrame(
            rowRect,
            contents: draggingImage(for: rowRect)
        )
        beginDraggingSession(with: [draggingItem], event: event, source: self)
        return true
    }

    private func draggingImage(for rect: NSRect) -> NSImage {
        let image = NSImage(size: rect.size)
        guard let bitmap = bitmapImageRepForCachingDisplay(in: rect) else {
            return image
        }
        cacheDisplay(in: rect, to: bitmap)
        image.addRepresentation(bitmap)
        return image
    }

    private func isAccountListFirstResponder(_ responder: NSResponder) -> Bool {
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
        guard previousFirstResponder.map(isAccountListFirstResponder(_:)) ?? false else {
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
    func presentContextMenuForTesting(
        at point: NSPoint,
        presenter: @escaping (NSMenu) -> Void
    ) {
        guard window != nil else {
            fatalError("Accounts outline view must be attached to a window for context menu testing.")
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

    func dragPasteboardStringForTesting(
        row: Int,
        type: NSPasteboard.PasteboardType
    ) -> String? {
        (dragPasteboardWriterProvider?(row) as? NSPasteboardItem)?.string(forType: type)
    }

    func suppressesSelectionClearingForTesting(at point: NSPoint) -> Bool {
        shouldSuppressSelectionClearing(at: point)
    }
#endif
}

@MainActor
private final class ReviewMonitorAccountTableRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set { }
    }
}

@MainActor
private final class ReviewMonitorAccountCellView: NSTableCellView {
    private let hostingView: NSHostingView<ReviewMonitorAccountRowView>

    init(store: CodexReviewStore) {
        hostingView = NSHostingView(rootView: ReviewMonitorAccountRowView(store: store))
        super.init(frame: .zero)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(account: CodexAccount) {
        objectValue = account
        toolTip = account.email
        hostingView.rootView.account = account
    }

    private func configureHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.setAccessibilityIdentifier("review-monitor.account-row")
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    #if DEBUG
    var isHostingReviewMonitorAccountRowViewForTesting: Bool {
        hostingView.rootView.account != nil
    }
    #endif
}
