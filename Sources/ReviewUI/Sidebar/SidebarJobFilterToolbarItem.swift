import AppKit
import ObservationBridge

@MainActor
final class ReviewMonitorSidebarJobFilterToolbarItem: NSToolbarItem {
    private let uiState: ReviewMonitorUIState
    private let filterMenu: NSMenu
    private let menuFormItem: NSMenuItem
    private let toolbarButton: NSButton
    private var filterMenuItems: [SidebarJobFilter: NSMenuItem] = [:]
    private let observationScope = ObservationScope()

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

    private func bindObservation() {
        observationScope.observe(uiState) { [weak self] _, uiState in
            self?.applySelection(uiState.sidebarJobFilter)
        }
    }

    private func applySelection(_ filter: SidebarJobFilter) {
        toolbarButton.state = filter.isActive ? .on : .off
        menuFormItem.state = filter.isActive ? .on : .off
        for (candidate, item) in filterMenuItems {
            item.state = candidate == filter ? .on : .off
        }
    }

    @objc
    private func handleToolbarButton(_ sender: NSButton) {
        applySelection(uiState.sidebarJobFilter)
        sender.state = .on
        filterMenu.popUp(
            positioning: filterMenuItems[uiState.sidebarJobFilter],
            at: NSPoint(x: 0, y: sender.bounds.maxY),
            in: sender
        )
        applySelection(uiState.sidebarJobFilter)
    }

    @objc
    private func handleFilterSelection(_ sender: NSMenuItem) {
        guard let filter = sender.representedObject as? SidebarJobFilter else {
            return
        }
        uiState.sidebarJobFilter = filter
        applySelection(filter)
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
}
#endif
