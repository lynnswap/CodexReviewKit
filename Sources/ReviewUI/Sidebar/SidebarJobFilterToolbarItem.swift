import AppKit
import ObservationBridge

@MainActor
final class ReviewMonitorSidebarJobFilterToolbarItem: NSToolbarItem {
    private let uiState: ReviewMonitorUIState
    private let filterMenu: NSMenu
    private let menuFormItem: NSMenuItem
    private let toolbarButton: NSButton
    private var filterMenuItems: [SidebarJobFilter: NSMenuItem] = [:]
    private var workspaceSortMenuItems: [SidebarWorkspaceSortOrder: NSMenuItem] = [:]
    private var observation: PortableObservationTracking.Token?

    init(
        itemIdentifier: NSToolbarItem.Identifier,
        uiState: ReviewMonitorUIState
    ) {
        self.uiState = uiState
        self.filterMenu = NSMenu(title: "Filter and Sort")
        self.menuFormItem = NSMenuItem(title: "Filter and Sort", action: nil, keyEquivalent: "")
        self.toolbarButton = NSButton(
            image: NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: "Filter and Sort")!,
            target: nil,
            action: nil
        )
        super.init(itemIdentifier: itemIdentifier)

        visibilityPriority = .high
        label = "Filter and Sort"
        paletteLabel = "Filter and Sort"
        toolTip = "Filter and Sort"
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
        toolbarButton.toolTip = "Filter and Sort"
        toolbarButton.bezelStyle = .toolbar
        toolbarButton.controlSize = .extraLarge
        toolbarButton.setButtonType(.onOff)
        toolbarButton.isBordered = true
        toolbarButton.imagePosition = .imageOnly
        toolbarButton.imageScaling = .scaleProportionallyDown
        toolbarButton.setAccessibilityLabel("Filter and Sort")
    }

    private func configureMenu() {
        filterMenu.autoenablesItems = false
        filterMenuItems.removeAll(keepingCapacity: true)
        workspaceSortMenuItems.removeAll(keepingCapacity: true)

        addMenuItem(for: .all)
        filterMenu.addItem(.separator())
        addMenuItem(for: .running)
        addMenuItem(for: .latestFinished)
        filterMenu.addItem(.separator())
        filterMenu.addItem(.sectionHeader(title: String(localized: "Workspace Order")))
        for sortOrder in SidebarWorkspaceSortOrder.allCases {
            addMenuItem(for: sortOrder)
        }
    }

    private func addMenuItem(for filter: SidebarJobFilter) {
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

    private func addMenuItem(for sortOrder: SidebarWorkspaceSortOrder) {
        let item = NSMenuItem(
            title: String(localized: sortOrder.localized),
            action: #selector(handleWorkspaceSortSelection(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = sortOrder
        filterMenu.addItem(item)
        workspaceSortMenuItems[sortOrder] = item
    }

    private func bindObservation() {
        observation?.cancel()
        observation = withPortableContinuousObservation { [weak self, uiState] _ in
            self?.applySelection(
                uiState.sidebarJobFilter,
                workspaceSortOrder: uiState.sidebarWorkspaceSortOrder
            )
        }
    }

    private func applySelection(
        _ filter: SidebarJobFilter,
        workspaceSortOrder: SidebarWorkspaceSortOrder
    ) {
        let isActive = filter.isActive || workspaceSortOrder != .manual
        toolbarButton.state = isActive ? .on : .off
        menuFormItem.state = isActive ? .on : .off
        for (candidate, item) in filterMenuItems {
            if candidate == .all {
                item.state = filter.isActive ? .off : .on
            } else {
                item.state = filter.contains(candidate) ? .on : .off
            }
        }
        for (candidate, item) in workspaceSortMenuItems {
            item.state = candidate == workspaceSortOrder ? .on : .off
        }
    }

    @objc
    private func handleToolbarButton(_ sender: NSButton) {
        applySelection(uiState.sidebarJobFilter, workspaceSortOrder: uiState.sidebarWorkspaceSortOrder)
        sender.state = .on
        filterMenu.popUp(
            positioning: positioningMenuItem(for: uiState.sidebarJobFilter),
            at: NSPoint(x: 0, y: sender.bounds.maxY),
            in: sender
        )
        applySelection(uiState.sidebarJobFilter, workspaceSortOrder: uiState.sidebarWorkspaceSortOrder)
    }

    @objc
    private func handleFilterSelection(_ sender: NSMenuItem) {
        guard let filter = sender.representedObject as? SidebarJobFilter else {
            return
        }
        let updatedFilter = toggledFilter(filter)
        uiState.sidebarJobFilter = updatedFilter
        applySelection(updatedFilter, workspaceSortOrder: uiState.sidebarWorkspaceSortOrder)
    }

    @objc
    private func handleWorkspaceSortSelection(_ sender: NSMenuItem) {
        guard let sortOrder = sender.representedObject as? SidebarWorkspaceSortOrder else {
            return
        }
        uiState.sidebarWorkspaceSortOrder = sortOrder
        applySelection(uiState.sidebarJobFilter, workspaceSortOrder: sortOrder)
    }

    private func toggledFilter(_ filter: SidebarJobFilter) -> SidebarJobFilter {
        guard filter != .all else {
            return .all
        }
        var currentFilter = uiState.sidebarJobFilter
        if currentFilter.contains(filter) {
            currentFilter.remove(filter)
        } else {
            currentFilter.insert(filter)
        }
        return currentFilter
    }

    private func positioningMenuItem(for filter: SidebarJobFilter) -> NSMenuItem? {
        if filter.isActive == false {
            return filterMenuItems[.all]
        }
        for candidate in SidebarJobFilter.menuFilters where filter.contains(candidate) {
            return filterMenuItems[candidate]
        }
        return filterMenuItems[.all]
    }
}

#if DEBUG
@MainActor
extension ReviewMonitorSidebarJobFilterToolbarItem {
    var menuItemTitlesForTesting: [String] {
        filterMenu.items.map { item in
            item.isSeparatorItem ? "-" : item.title
        }
    }

    var selectedFilterForTesting: SidebarJobFilter {
        uiState.sidebarJobFilter
    }

    var selectedWorkspaceSortOrderForTesting: SidebarWorkspaceSortOrder {
        uiState.sidebarWorkspaceSortOrder
    }

    var selectedMenuItemTitlesForTesting: [String] {
        filterMenu.items
            .filter { $0.state == .on }
            .map(\.title)
    }

    var buttonShowsActiveBackgroundForTesting: Bool {
        toolbarButton.state == .on
    }

    func selectFilterForTesting(_ filter: SidebarJobFilter) {
        guard let item = filterMenuItems[filter] else {
            fatalError("Sidebar job filter menu item is not configured.")
        }
        handleFilterSelection(item)
    }

    func selectWorkspaceSortOrderForTesting(_ sortOrder: SidebarWorkspaceSortOrder) {
        guard let item = workspaceSortMenuItems[sortOrder] else {
            fatalError("Sidebar workspace sort menu item is not configured.")
        }
        handleWorkspaceSortSelection(item)
    }
}
#endif
