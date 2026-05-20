import AppKit
import Combine
import Foundation
import Observation
import ObservationBridge
import CodexReview

@MainActor
@Observable
final class ReviewMonitorSplitViewController: NSSplitViewController, NSToolbarDelegate {
    private static let autosaveName = NSSplitView.AutosaveName("CodexReviewKit.ReviewMonitorSplitView")
    private static let sidebarPickerToolbarItemIdentifier = NSToolbarItem.Identifier(
        "CodexReviewKit.ReviewMonitor.Toolbar.SidebarPicker"
    )
    private static let addAccountToolbarItemIdentifier = NSToolbarItem.Identifier(
        "CodexReviewKit.ReviewMonitor.Toolbar.AddAccount"
    )

    private let store: CodexReviewStore
    private let uiState: ReviewMonitorUIState
    private var sidebarViewController: ReviewMonitorSidebarViewController?
    private var transportViewController: ReviewMonitorTransportViewController?
    private var sidebarItem: NSSplitViewItem?
    private var contentItem: NSSplitViewItem?
    private var toolbar: NSToolbar?
    private var sidebarPickerToolbarItem: ReviewMonitorSidebarPickerToolbarItem?
    private var addAccountToolbarItem: ReviewMonitorAddAccountToolbarItem?
    @ObservationIgnored private let toolbarObservationScope = ObservationScope()
    private var sidebarCollapseObservation: NSKeyValueObservation?
    private var windowCancellable: AnyCancellable?
    private weak var attachedWindow: NSWindow?
    private var isSidebarCollapsed = false

    init(store: CodexReviewStore, uiState: ReviewMonitorUIState) {
        self.store = store
        self.uiState = uiState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarViewController = ReviewMonitorSidebarViewController(
            store: store,
            uiState: uiState
        )
        let transportViewController = ReviewMonitorTransportViewController(
            store: store,
            uiState: uiState
        )
        let statusAccessoryViewController = ReviewMonitorServerStatusAccessoryViewController(
            store: store,
            uiState: uiState
        )
        if #available(macOS 26.1, *) {
            statusAccessoryViewController.preferredScrollEdgeEffectStyle = .soft
        }
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.minimumThickness = 220
        sidebarItem.preferredThicknessFraction = 0.22
        sidebarItem.titlebarSeparatorStyle = .none
        sidebarItem.addBottomAlignedAccessoryViewController(statusAccessoryViewController)

        let contentItem = NSSplitViewItem(viewController: transportViewController)
        contentItem.minimumThickness = 300
        contentItem.automaticallyAdjustsSafeAreaInsets = true

        self.sidebarViewController = sidebarViewController
        self.transportViewController = transportViewController
        self.sidebarItem = sidebarItem
        self.contentItem = contentItem
        isSidebarCollapsed = sidebarItem.isCollapsed
        sidebarCollapseObservation = sidebarItem.observe(\.isCollapsed, options: [.initial, .new]) { [weak self] observedItem, _ in
            let isCollapsed = observedItem.isCollapsed
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                self.setSidebarCollapsed(isCollapsed)
            }
        }

        insertSplitViewItem(sidebarItem, at: 0)
        insertSplitViewItem(contentItem, at: 1)
        windowCancellable = view.publisher(for: \.window, options: [.initial, .new])
            .sink { [weak self] window in
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    if let window {
                        self.attach(to: window)
                    } else {
                        self.detachFromWindow()
                    }
                }
            }
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard transportViewController?.performDisplayedTextFinderAction(sender) == true else {
            super.performTextFinderAction(sender)
            return
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(NSResponder.performTextFinderAction(_:)) else {
            return super.validateUserInterfaceItem(item)
        }
        return transportViewController?.validateDisplayedTextFinderAction(item) ?? false
    }

    func attach(to window: NSWindow) {
        loadViewIfNeeded()
        let isNewWindow = attachedWindow !== window
        attachedWindow = window

        configureReviewMonitorWindowBase(window)
        // macOS 26 applies NSSplitView autosave reliably only after the split view is in a window.
        if isNewWindow {
            splitView.identifier = NSUserInterfaceItemIdentifier(Self.autosaveName)
            splitView.autosaveName = Self.autosaveName
        }
        installToolbarIfNeeded(on: window)
        if isNewWindow {
            bindToolbarState()
        }
        window.layoutIfNeeded()
        setShowingAddAccount(isShowingAddAccountButton)
        updateWindowTitleAndSubtitle()
    }

    func detachFromWindow() {
        toolbarObservationScope.cancelAll()
        attachedWindow = nil
    }

    private func bindToolbarState() {
        toolbarObservationScope.cancelAll()
        toolbarObservationScope.update {
            observe(\.isShowingAddAccountButton) { [weak self] _ in
                guard let self else {
                    return
                }
                setShowingAddAccount(isShowingAddAccountButton)
            }
            .store(in: toolbarObservationScope)

            uiState.observe(\.selection) { [weak self] _ in
                self?.updateWindowTitleAndSubtitle()
            }
            .store(in: toolbarObservationScope)

            uiState.observe([\.selectedJobEntry?.targetSummary, \.selectedJobEntry?.cwd]) { [weak self] in
                self?.updateWindowTitleAndSubtitle()
            }
            .store(in: toolbarObservationScope)
        }
    }

    private func installToolbarIfNeeded(on window: NSWindow) {
        if toolbar == nil {
            let toolbar = NSToolbar(identifier: "CodexReviewKit.ReviewMonitor.Toolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
            self.toolbar = toolbar
        }

        if window.toolbar !== toolbar {
            window.toolbar = toolbar
        }
    }

    private func updateWindowTitleAndSubtitle() {
        guard let attachedWindow else {
            return
        }
        let title: String
        let subtitle: String
        switch uiState.selection {
        case .workspace(let workspace):
            title = workspace.displayTitle
            subtitle = workspace.cwd
        case .job(let job):
            title = job.targetSummary
            subtitle = job.cwd
        case nil:
            title = ""
            subtitle = ""
        }
        attachedWindow.title = title
        attachedWindow.subtitle = subtitle
        attachedWindow.titleVisibility = (title.isEmpty && subtitle.isEmpty) ? .hidden : .visible
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.sidebarPickerToolbarItemIdentifier,
            .flexibleSpace,
            .sidebarTrackingSeparator,
            .flexibleSpace,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.sidebarPickerToolbarItemIdentifier,
            Self.addAccountToolbarItemIdentifier,
            .sidebarTrackingSeparator,
            .space,
            .flexibleSpace,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.sidebarPickerToolbarItemIdentifier:
            return resolvedSidebarPickerToolbarItem()

        case Self.addAccountToolbarItemIdentifier:
            let item = resolvedAddAccountToolbarItem()
            return item

        case .sidebarTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitView,
                dividerIndex: 0
            )

        default:
            return nil
        }
    }

    private func resolvedSidebarPickerToolbarItem() -> ReviewMonitorSidebarPickerToolbarItem {
        if let sidebarPickerToolbarItem {
            return sidebarPickerToolbarItem
        }

        let item = ReviewMonitorSidebarPickerToolbarItem(
            itemIdentifier: Self.sidebarPickerToolbarItemIdentifier,
            uiState: uiState
        ) { [weak self] selection in
            self?.handleSidebarPickerSelection(selection)
        }
        sidebarPickerToolbarItem = item
        return item
    }

    private func handleSidebarPickerSelection(_ selection: SidebarPickerSelection) {
        guard uiState.sidebarSelection != selection else {
            toggleSidebar(nil)
            return
        }

        uiState.sidebarSelection = selection
        if sidebarItem?.isCollapsed == true {
            toggleSidebar(nil)
        }
    }

    private func resolvedAddAccountToolbarItem() -> ReviewMonitorAddAccountToolbarItem {
        if let addAccountToolbarItem {
            return addAccountToolbarItem
        }

        let item = ReviewMonitorAddAccountToolbarItem(
            itemIdentifier: Self.addAccountToolbarItemIdentifier,
            store: store
        )
        addAccountToolbarItem = item
        return item
    }

    private var isShowingAddAccountButton: Bool {
        if store.auth.isAuthenticating {
            return true
        }
        return uiState.sidebarSelection == .account && isSidebarCollapsed == false
    }

    private func setSidebarCollapsed(_ isCollapsed: Bool) {
        guard isSidebarCollapsed != isCollapsed else {
            return
        }
        isSidebarCollapsed = isCollapsed
        setShowingAddAccount(isShowingAddAccountButton)
    }

    private func setShowingAddAccount(_ isShowing: Bool) {
        guard let toolbar else {
            return
        }

        if let existingIndex = toolbar.items.firstIndex(where: {
            $0.itemIdentifier == Self.addAccountToolbarItemIdentifier
        }) {
            guard isShowing == false else {
                return
            }
            toolbar.removeItem(at: existingIndex)
            return
        }

        guard isShowing else {
            return
        }

        let insertionIndex = toolbar.items.firstIndex(where: {
            $0.itemIdentifier == .sidebarTrackingSeparator
        }) ?? toolbar.items.count
        toolbar.insertItem(
            withItemIdentifier: Self.addAccountToolbarItemIdentifier,
            at: insertionIndex
        )
    }
}

#if DEBUG
@MainActor
extension ReviewMonitorSplitViewController {
    enum AddAccountToolbarItemModeForTesting: Equatable {
        case add
        case progress
    }

    enum SidebarPresentationForTesting: Equatable {
        case jobList
        case accountList
        case unavailable
    }

    var sidebarViewControllerForTesting: ReviewMonitorSidebarViewController {
        guard let sidebarViewController else {
            fatalError("Sidebar pane view controller is not configured yet.")
        }
        sidebarViewController.loadViewIfNeeded()
        return sidebarViewController
    }

    var sidebarPresentationForTesting: SidebarPresentationForTesting {
        switch sidebarViewControllerForTesting.presentationForTesting {
        case .jobList, .empty:
            return .jobList
        case .accountList:
            return .accountList
        case .unavailable:
            return .unavailable
        }
    }

    var sidebarAccessoryCountForTesting: Int {
        sidebarBottomAccessoryCountForTesting
    }

    var sidebarTopAccessoryCountForTesting: Int {
        sidebarItem?.topAlignedAccessoryViewControllers.count ?? 0
    }

    var sidebarBottomAccessoryCountForTesting: Int {
        sidebarItem?.bottomAlignedAccessoryViewControllers.count ?? 0
    }

    var sidebarBottomAccessoryIsHiddenForTesting: Bool {
        sidebarItem?.bottomAlignedAccessoryViewControllers.first?.isHidden ?? false
    }

    var contentAccessoryCountForTesting: Int {
        contentItem?.bottomAlignedAccessoryViewControllers.count ?? 0
    }

    var contentPaneViewControllerForTesting: ReviewMonitorTransportViewController {
        transportViewControllerForTesting
    }

    var transportViewControllerForTesting: ReviewMonitorTransportViewController {
        guard let transportViewController else {
            fatalError("Transport view controller is not configured yet.")
        }
        transportViewController.loadViewIfNeeded()
        return transportViewController
    }

    var toolbarIdentifiersForTesting: [NSToolbarItem.Identifier] {
        toolbar?.items.map(\.itemIdentifier) ?? []
    }

    var sidebarPickerToolbarItemIdentifierForTesting: NSToolbarItem.Identifier {
        Self.sidebarPickerToolbarItemIdentifier
    }

    var sidebarPickerToolbarSegmentAccessibilityDescriptionsForTesting: [String] {
        sidebarPickerToolbarItem?.segmentAccessibilityDescriptionsForTesting ?? []
    }

    var sidebarPickerToolbarSelectedSelectionForTesting: SidebarPickerSelection? {
        sidebarPickerToolbarItem?.selectedSelectionForTesting
    }

    var sidebarPickerToolbarOverflowMenuItemTitlesForTesting: [String] {
        sidebarPickerToolbarItem?.overflowMenuItemTitlesForTesting ?? []
    }

    var sidebarItemIsCollapsedForTesting: Bool {
        sidebarItem?.isCollapsed ?? false
    }

    func selectSidebarPickerToolbarSegmentForTesting(_ selection: SidebarPickerSelection) {
        guard let sidebarPickerToolbarItem else {
            fatalError("Sidebar picker toolbar item is not configured yet.")
        }
        sidebarPickerToolbarItem.selectSegmentForTesting(selection)
    }

    func selectSidebarPickerToolbarOverflowMenuItemForTesting(_ selection: SidebarPickerSelection) {
        guard let sidebarPickerToolbarItem else {
            fatalError("Sidebar picker toolbar item is not configured yet.")
        }
        sidebarPickerToolbarItem.selectOverflowMenuItemForTesting(selection)
    }

    var addAccountToolbarItemIdentifierForTesting: NSToolbarItem.Identifier {
        Self.addAccountToolbarItemIdentifier
    }

    var addAccountToolbarItemIsHiddenForTesting: Bool {
        toolbar?.items.contains(where: {
            $0.itemIdentifier == Self.addAccountToolbarItemIdentifier
        }) != true
    }

    var addAccountToolbarItemModeForTesting: AddAccountToolbarItemModeForTesting? {
        switch addAccountToolbarItem?.displayedModeForTesting {
        case .add:
            .add
        case .progress:
            .progress
        case nil:
            nil
        }
    }

    var addAccountToolbarMenuTitleForTesting: String? {
        addAccountToolbarItem?.menuTitleForTesting
    }

    func waitForAddAccountToolbarItemModeForTesting(
        _ mode: AddAccountToolbarItemModeForTesting
    ) async {
        guard let addAccountToolbarItem else {
            fatalError("Add Account toolbar item is not configured yet.")
        }
        let targetMode: AddAccountToolbarItemView.Mode
        switch mode {
        case .add:
            targetMode = .add
        case .progress:
            targetMode = .progress
        }
        await addAccountToolbarItem.waitForStableModeForTesting(targetMode)
    }

    var sidebarAllowsFullHeightLayoutForTesting: Bool {
        sidebarItem?.allowsFullHeightLayout ?? false
    }

    var contentAutomaticallyAdjustsSafeAreaInsetsForTesting: Bool {
        contentItem?.automaticallyAdjustsSafeAreaInsets ?? false
    }
}
#endif
