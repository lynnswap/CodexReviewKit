import AppKit
import ObservationBridge

@MainActor
final class ReviewMonitorSidebarReviewChatFilterToolbarItem: NSToolbarItem {
    private let uiState: ReviewMonitorUIState
    private let filterMenu: NSMenu
    private let menuFormItem: NSMenuItem
    private let toolbarButton: NSButton
    private var filterMenuItems: [SidebarReviewChatFilter: NSMenuItem] = [:]
    private var observation: PortableObservationTracking.Token?

    init(
        itemIdentifier: NSToolbarItem.Identifier,
        uiState: ReviewMonitorUIState
    ) {
        self.uiState = uiState
        self.filterMenu = NSMenu(title: "Filter")
        self.menuFormItem = NSMenuItem(title: "Filter", action: nil, keyEquivalent: "")
        self.toolbarButton = NSButton(
            image: NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: "Filter")!,
            target: nil,
            action: nil
        )
        super.init(itemIdentifier: itemIdentifier)

        label = "Filter"
        paletteLabel = "Filter"
        toolTip = "Filter"
        image = toolbarButton.image
        view = toolbarButton

        menuFormItem.submenu = filterMenu
        menuFormRepresentation = menuFormItem
        configureButton()
        configureMenu()
        bindObservation()
    }

    isolated deinit {
        observation?.cancel()
    }

    private func configureButton() {
        toolbarButton.target = self
        toolbarButton.action = #selector(handleToolbarButton(_:))
        toolbarButton.toolTip = "Filter"
        toolbarButton.bezelStyle = .toolbar
        toolbarButton.controlSize = .extraLarge
        toolbarButton.setButtonType(.onOff)
        toolbarButton.isBordered = true
        toolbarButton.imagePosition = .imageOnly
        toolbarButton.imageScaling = .scaleProportionallyDown
        toolbarButton.setAccessibilityLabel("Filter")
    }

    private func configureMenu() {
        filterMenu.autoenablesItems = false
        filterMenuItems.removeAll(keepingCapacity: true)

        addMenuItem(for: .all)
        filterMenu.addItem(.separator())
        addMenuItem(for: .running)
        addMenuItem(for: .latestFinished)
    }

    private func addMenuItem(for filter: SidebarReviewChatFilter) {
        let item = NSMenuItem(
            title: String(localized: filter.localized),
            action: #selector(handleFilterSelection(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = filter
        filterMenu.addItem(item)
        filterMenuItems[filter] = item
    }

    private func bindObservation() {
        observation?.cancel()
        observation = withPortableContinuousObservation { [weak self, uiState] _ in
            self?.applySelection(uiState.sidebarReviewChatFilter)
        }
    }

    private func applySelection(_ filter: SidebarReviewChatFilter) {
        toolbarButton.state = filter.isActive ? .on : .off
        menuFormItem.state = filter.isActive ? .on : .off
        for (candidate, item) in filterMenuItems {
            if candidate == .all {
                item.state = filter.isActive ? .off : .on
            } else {
                item.state = filter.contains(candidate) ? .on : .off
            }
        }
    }

    @objc
    private func handleToolbarButton(_ sender: NSButton) {
        applySelection(uiState.sidebarReviewChatFilter)
        sender.state = .on
        filterMenu.popUp(
            positioning: positioningMenuItem(for: uiState.sidebarReviewChatFilter),
            at: NSPoint(x: 0, y: sender.bounds.maxY),
            in: sender
        )
        applySelection(uiState.sidebarReviewChatFilter)
    }

    @objc
    private func handleFilterSelection(_ sender: NSMenuItem) {
        guard let filter = sender.representedObject as? SidebarReviewChatFilter else {
            return
        }
        let updatedFilter = toggledFilter(filter)
        uiState.sidebarReviewChatFilter = updatedFilter
        applySelection(updatedFilter)
    }

    private func toggledFilter(_ filter: SidebarReviewChatFilter) -> SidebarReviewChatFilter {
        guard filter != .all else {
            return .all
        }
        var currentFilter = uiState.sidebarReviewChatFilter
        if currentFilter.contains(filter) {
            currentFilter.remove(filter)
        } else {
            currentFilter.insert(filter)
        }
        return currentFilter
    }

    private func positioningMenuItem(for filter: SidebarReviewChatFilter) -> NSMenuItem? {
        if filter.isActive == false {
            return filterMenuItems[.all]
        }
        for candidate in SidebarReviewChatFilter.menuFilters where filter.contains(candidate) {
            return filterMenuItems[candidate]
        }
        return filterMenuItems[.all]
    }
}

#if DEBUG
@MainActor
extension ReviewMonitorSidebarReviewChatFilterToolbarItem {
    var menuItemTitlesForTesting: [String] {
        filterMenu.items.map { item in
            item.isSeparatorItem ? "-" : item.title
        }
    }

    var selectedFilterForTesting: SidebarReviewChatFilter {
        uiState.sidebarReviewChatFilter
    }

    var selectedMenuItemTitlesForTesting: [String] {
        filterMenu.items
            .filter { $0.state == .on }
            .map(\.title)
    }

    var buttonShowsActiveBackgroundForTesting: Bool {
        toolbarButton.state == .on
    }

    func selectFilterForTesting(_ filter: SidebarReviewChatFilter) {
        guard let item = filterMenuItems[filter] else {
            fatalError("Sidebar review chat filter menu item is not configured.")
        }
        handleFilterSelection(item)
    }
}
#endif
