import AppKit
import ObservationBridge

@MainActor
final class ReviewMonitorSidebarPickerToolbarItem: NSToolbarItem {
    private static let selections = SidebarPickerSelection.allCases

    private let uiState: ReviewMonitorUIState
    private let segmentedControl: NSSegmentedControl
    private let selectionAction: (SidebarPickerSelection) -> Void
    private let observationScope = ObservationScope()
    private let overflowMenuItem = NSMenuItem(title: "Sidebar", action: nil, keyEquivalent: "")
    private var overflowSelectionMenuItems: [SidebarPickerSelection: NSMenuItem] = [:]

    init(
        itemIdentifier: NSToolbarItem.Identifier,
        uiState: ReviewMonitorUIState,
        selectionAction: @escaping (SidebarPickerSelection) -> Void
    ) {
        self.uiState = uiState
        self.selectionAction = selectionAction
        segmentedControl = Self.makeSegmentedControl()
        super.init(itemIdentifier: itemIdentifier)

        label = "Sidebar"
        paletteLabel = "Sidebar"
        visibilityPriority = .high
        view = segmentedControl
        menuFormRepresentation = overflowMenuItem
        segmentedControl.target = self
        segmentedControl.action = #selector(handleSegmentedControl(_:))
        configureOverflowMenu()
        bindObservation()
        updateSelection(uiState.sidebarSelection)
    }

    private static func makeSegmentedControl() -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = selections.count
        control.trackingMode = .selectOne
        control.controlSize = .large
        control.segmentStyle = .texturedRounded
        control.setAccessibilityLabel("Sidebar")

        for (index, selection) in selections.enumerated() {
            let title = String(localized: selection.localized)
            control.setImage(
                NSImage(
                    systemSymbolName: selection.systemImage,
                    accessibilityDescription: title
                ),
                forSegment: index
            )
            control.setToolTip(title, forSegment: index)
        }

        return control
    }

    private func configureOverflowMenu() {
        let menu = NSMenu()
        overflowSelectionMenuItems.removeAll(keepingCapacity: true)

        for selection in Self.selections {
            let title = String(localized: selection.localized)
            let item = NSMenuItem(
                title: title,
                action: #selector(handleOverflowSelection(_:)),
                keyEquivalent: ""
            )
            item.image = NSImage(
                systemSymbolName: selection.systemImage,
                accessibilityDescription: title
            )
            item.target = self
            item.representedObject = selection
            menu.addItem(item)
            overflowSelectionMenuItems[selection] = item
        }

        overflowMenuItem.submenu = menu
    }

    private func bindObservation() {
        observationScope.update {
            uiState.observe(\.sidebarSelection) { [weak self] selection in
                self?.updateSelection(selection)
            }
            .store(in: observationScope)
        }
    }

    private func updateSelection(_ selection: SidebarPickerSelection) {
        segmentedControl.selectedSegment = Self.segmentIndex(for: selection)
        for (candidate, item) in overflowSelectionMenuItems {
            item.state = candidate == selection ? .on : .off
        }
    }

    @objc
    private func handleSegmentedControl(_ sender: NSSegmentedControl) {
        guard let selection = Self.selection(at: sender.selectedSegment) else {
            updateSelection(uiState.sidebarSelection)
            return
        }

        selectionAction(selection)
        updateSelection(uiState.sidebarSelection)
    }

    @objc
    private func handleOverflowSelection(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? SidebarPickerSelection else {
            updateSelection(uiState.sidebarSelection)
            return
        }

        selectionAction(selection)
        updateSelection(uiState.sidebarSelection)
    }

    private static func selection(at segmentIndex: Int) -> SidebarPickerSelection? {
        guard selections.indices.contains(segmentIndex) else {
            return nil
        }
        return selections[segmentIndex]
    }

    private static func segmentIndex(for selection: SidebarPickerSelection) -> Int {
        selections.firstIndex(of: selection) ?? 0
    }
}

#if DEBUG
@MainActor
extension ReviewMonitorSidebarPickerToolbarItem {
    var segmentAccessibilityDescriptionsForTesting: [String] {
        Self.selections.map { String(localized: $0.localized) }
    }

    var selectedSelectionForTesting: SidebarPickerSelection? {
        Self.selection(at: segmentedControl.selectedSegment)
    }

    var overflowMenuItemTitlesForTesting: [String] {
        overflowMenuItem.submenu?.items.map(\.title) ?? []
    }

    func selectSegmentForTesting(_ selection: SidebarPickerSelection) {
        segmentedControl.selectedSegment = Self.segmentIndex(for: selection)
        handleSegmentedControl(segmentedControl)
    }

    func selectOverflowMenuItemForTesting(_ selection: SidebarPickerSelection) {
        guard let item = overflowSelectionMenuItems[selection] else {
            fatalError("Sidebar picker overflow menu item is not configured.")
        }
        handleOverflowSelection(item)
    }
}
#endif
