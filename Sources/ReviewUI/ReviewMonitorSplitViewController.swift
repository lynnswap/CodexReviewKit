import AppKit
import Combine
import Foundation
import ObservationBridge
import CodexReview

@MainActor
final class ReviewMonitorSplitViewController: NSSplitViewController, NSToolbarDelegate {
    private static let autosaveName = NSSplitView.AutosaveName("CodexReviewKit.ReviewMonitorSplitView")
    private static let sidebarPickerToolbarItemIdentifier = NSToolbarItem.Identifier(
        "CodexReviewKit.ReviewMonitor.Toolbar.SidebarPicker"
    )
    private static let addAccountToolbarItemIdentifier = NSToolbarItem.Identifier(
        "CodexReviewKit.ReviewMonitor.Toolbar.AddAccount"
    )
    private static let sidebarJobFilterToolbarItemIdentifier = NSToolbarItem.Identifier(
        "CodexReviewKit.ReviewMonitor.Toolbar.SidebarJobFilter"
    )

    private let store: CodexReviewStore
    private let uiState: ReviewMonitorUIState
    private let showSettings: (@MainActor () -> Void)?
    private var sidebarViewController: ReviewMonitorSidebarViewController?
    private var transportViewController: ReviewMonitorTransportViewController?
    private var sidebarItem: NSSplitViewItem?
    private var contentItem: NSSplitViewItem?
    private var toolbar: NSToolbar?
    private var toolbarMembershipObservation: PortableObservationTracking.Token?
    private var windowTitleObservation: PortableObservationTracking.Token?
    private var sidebarCollapseObservation: NSKeyValueObservation?
    private var windowCancellable: AnyCancellable?
    private weak var attachedWindow: NSWindow?
    private var isSidebarCollapsed = false

    init(
        store: CodexReviewStore,
        uiState: ReviewMonitorUIState,
        showSettings: (@MainActor () -> Void)? = nil
    ) {
        self.store = store
        self.uiState = uiState
        self.showSettings = showSettings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        cancelToolbarObservations()
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
            uiState: uiState,
            showSettings: showSettings
        )
        if #available(macOS 27.0, *) {
            statusAccessoryViewController.preferredScrollEdgeEffectStyle = .hard
        } else if #available(macOS 26.1, *) {
            statusAccessoryViewController.preferredScrollEdgeEffectStyle = .soft
        }
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.minimumThickness = 220
        sidebarItem.preferredThicknessFraction = 0.22
        sidebarItem.canCollapseFromWindowResize = false
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
        synchronizeSidebarToolbarState()
        applyWindowTitle(Self.windowTitlePresentation(for: uiState.selection))
    }

    func detachFromWindow() {
        cancelToolbarObservations()
        attachedWindow = nil
    }

    private func bindToolbarState() {
        cancelToolbarObservations()

        toolbarMembershipObservation = withPortableContinuousObservation { [weak self, uiState] _ in
            let sidebarSelection = uiState.sidebarSelection
            let isAuthenticating = uiState.auth.isAuthenticating
            guard let self else {
                return
            }
            let identifiers = Self.toolbarItemIdentifiers(
                sidebarSelection: sidebarSelection,
                isSidebarCollapsed: self.isSidebarCollapsed,
                isAuthenticating: isAuthenticating
            )
            self.applyToolbarItemIdentifiers(identifiers)
        }

        windowTitleObservation = withPortableContinuousObservation { [weak self, uiState] _ in
            let presentation = Self.windowTitlePresentation(for: uiState.selection)
            self?.applyWindowTitle(presentation)
        }
    }

    private func cancelToolbarObservations() {
        toolbarMembershipObservation?.cancel()
        toolbarMembershipObservation = nil
        windowTitleObservation?.cancel()
        windowTitleObservation = nil
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

    private struct WindowTitlePresentation {
        var title: String
        var subtitle: String
    }

    private static func windowTitlePresentation(
        for selection: ReviewMonitorSelection?
    ) -> WindowTitlePresentation {
        switch selection {
        case .workspaceSection(let section):
            WindowTitlePresentation(
                title: section.title,
                subtitle: section.subtitle
            )
        case .job(let job):
            WindowTitlePresentation(
                title: job.targetSummary,
                subtitle: job.cwd
            )
        case nil:
            WindowTitlePresentation(title: "", subtitle: "")
        }
    }

    private func applyWindowTitle(_ presentation: WindowTitlePresentation) {
        guard let attachedWindow else {
            return
        }
        attachedWindow.title = presentation.title
        attachedWindow.subtitle = presentation.subtitle
        attachedWindow.titleVisibility =
            (presentation.title.isEmpty && presentation.subtitle.isEmpty) ? .hidden : .visible
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.toolbarItemIdentifiers(
            sidebarSelection: uiState.sidebarSelection,
            isSidebarCollapsed: isSidebarCollapsed,
            isAuthenticating: uiState.auth.isAuthenticating
        )
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.sidebarPickerToolbarItemIdentifier,
            Self.addAccountToolbarItemIdentifier,
            Self.sidebarJobFilterToolbarItemIdentifier,
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
            return makeSidebarPickerToolbarItem()

        case Self.addAccountToolbarItemIdentifier:
            return makeAddAccountToolbarItem()

        case Self.sidebarJobFilterToolbarItemIdentifier:
            return makeSidebarJobFilterToolbarItem()

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

    private func makeSidebarPickerToolbarItem() -> ReviewMonitorSidebarPickerToolbarItem {
        ReviewMonitorSidebarPickerToolbarItem(
            itemIdentifier: Self.sidebarPickerToolbarItemIdentifier,
            uiState: uiState
        ) { [weak self] selection in
            self?.handleSidebarPickerSelection(selection)
        }
    }

    private func makeSidebarJobFilterToolbarItem() -> ReviewMonitorSidebarJobFilterToolbarItem {
        ReviewMonitorSidebarJobFilterToolbarItem(
            itemIdentifier: Self.sidebarJobFilterToolbarItemIdentifier,
            uiState: uiState
        )
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

    private func makeAddAccountToolbarItem() -> ReviewMonitorAddAccountToolbarItem {
        ReviewMonitorAddAccountToolbarItem(
            itemIdentifier: Self.addAccountToolbarItemIdentifier,
            store: store
        )
    }

    private var sidebarPickerToolbarItem: ReviewMonitorSidebarPickerToolbarItem? {
        toolbar?.items.first(where: {
            $0.itemIdentifier == Self.sidebarPickerToolbarItemIdentifier
        }) as? ReviewMonitorSidebarPickerToolbarItem
    }

    private var sidebarJobFilterToolbarItem: ReviewMonitorSidebarJobFilterToolbarItem? {
        toolbar?.items.first(where: {
            $0.itemIdentifier == Self.sidebarJobFilterToolbarItemIdentifier
        }) as? ReviewMonitorSidebarJobFilterToolbarItem
    }

    private var addAccountToolbarItem: ReviewMonitorAddAccountToolbarItem? {
        toolbar?.items.first(where: {
            $0.itemIdentifier == Self.addAccountToolbarItemIdentifier
        }) as? ReviewMonitorAddAccountToolbarItem
    }

    private static func isShowingAddAccountToolbarItem(
        sidebarSelection: SidebarPickerSelection,
        isSidebarCollapsed: Bool,
        isAuthenticating: Bool
    ) -> Bool {
        if isAuthenticating {
            return true
        }
        return sidebarSelection == .account && isSidebarCollapsed == false
    }

    private static func isShowingSidebarJobFilterToolbarItem(
        sidebarSelection: SidebarPickerSelection,
        isSidebarCollapsed: Bool
    ) -> Bool {
        sidebarSelection == .workspace && isSidebarCollapsed == false
    }

    private static func toolbarItemIdentifiers(
        sidebarSelection: SidebarPickerSelection,
        isSidebarCollapsed: Bool,
        isAuthenticating: Bool
    ) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = [
            sidebarPickerToolbarItemIdentifier,
            .flexibleSpace,
        ]
        if isShowingAddAccountToolbarItem(
            sidebarSelection: sidebarSelection,
            isSidebarCollapsed: isSidebarCollapsed,
            isAuthenticating: isAuthenticating
        ) {
            identifiers.append(addAccountToolbarItemIdentifier)
        }
        if isShowingSidebarJobFilterToolbarItem(
            sidebarSelection: sidebarSelection,
            isSidebarCollapsed: isSidebarCollapsed
        ) {
            identifiers.append(sidebarJobFilterToolbarItemIdentifier)
        }
        identifiers.append(.sidebarTrackingSeparator)
        identifiers.append(.flexibleSpace)
        return identifiers
    }

    private func setSidebarCollapsed(_ isCollapsed: Bool) {
        guard isSidebarCollapsed != isCollapsed else {
            return
        }
        isSidebarCollapsed = isCollapsed
        updateToolbarItemIdentifiers()
    }

    private func synchronizeSidebarToolbarState() {
        isSidebarCollapsed = sidebarItem?.isCollapsed ?? isSidebarCollapsed
        updateToolbarItemIdentifiers()
    }

    private func updateToolbarItemIdentifiers() {
        applyToolbarItemIdentifiers(Self.toolbarItemIdentifiers(
            sidebarSelection: uiState.sidebarSelection,
            isSidebarCollapsed: isSidebarCollapsed,
            isAuthenticating: uiState.auth.isAuthenticating
        ))
    }

    private func applyToolbarItemIdentifiers(
        _ identifiers: [NSToolbarItem.Identifier]
    ) {
        guard let toolbar,
              toolbar.itemIdentifiers != identifiers
        else {
            return
        }
        toolbar.itemIdentifiers = identifiers
    }

}

#if DEBUG
@MainActor
extension ReviewMonitorSplitViewController {
    enum AddAccountToolbarItemModeForTesting: Equatable {
        case add
        case progress
    }

    enum SidebarPresentationForTesting: Sendable, Equatable {
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

    var windowTitleObservationForTesting: PortableObservationTracking.Token? {
        windowTitleObservation
    }

    var sidebarPresentationForTesting: SidebarPresentationForTesting {
        switch sidebarViewControllerForTesting.sidebarKindForTesting {
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

    var sidebarJobFilterToolbarItemIdentifierForTesting: NSToolbarItem.Identifier {
        Self.sidebarJobFilterToolbarItemIdentifier
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

    var sidebarCanCollapseFromWindowResizeForTesting: Bool {
        sidebarItem?.canCollapseFromWindowResize ?? false
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

    var sidebarJobFilterToolbarItemIsHiddenForTesting: Bool {
        toolbar?.items.contains(where: {
            $0.itemIdentifier == Self.sidebarJobFilterToolbarItemIdentifier
        }) != true
    }

    var sidebarJobFilterToolbarShowsActiveBackgroundForTesting: Bool {
        sidebarJobFilterToolbarItem?.buttonShowsActiveBackgroundForTesting ?? false
    }

    var selectedToolbarItemIdentifierForTesting: NSToolbarItem.Identifier? {
        toolbar?.selectedItemIdentifier
    }

    var sidebarJobFilterToolbarMenuItemTitlesForTesting: [String] {
        sidebarJobFilterToolbarItem?.menuItemTitlesForTesting ?? []
    }

    var sidebarJobFilterToolbarSelectedMenuItemTitlesForTesting: [String] {
        sidebarJobFilterToolbarItem?.selectedMenuItemTitlesForTesting ?? []
    }

    var sidebarJobFilterToolbarSelectedFilterForTesting: SidebarJobFilter? {
        sidebarJobFilterToolbarItem?.selectedFilterForTesting
    }

    func setSidebarJobFilterForTesting(_ filter: SidebarJobFilter) {
        uiState.sidebarJobFilter = filter
    }

    func selectSidebarJobFilterForTesting(_ filter: SidebarJobFilter) {
        guard let sidebarJobFilterToolbarItem else {
            fatalError("Sidebar job filter toolbar item is not configured yet.")
        }
        sidebarJobFilterToolbarItem.selectFilterForTesting(filter)
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

    var addAccountProviderMenuTitlesForTesting: [String] {
        addAccountToolbarItem?.providerMenuTitlesForTesting ?? []
    }

    var addAccountAPIKeyProviderIsEnabledForTesting: Bool {
        addAccountToolbarItem?.apiKeyProviderIsEnabledForTesting == true
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
