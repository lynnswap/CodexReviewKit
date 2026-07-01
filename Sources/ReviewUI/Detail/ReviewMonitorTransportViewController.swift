import AppKit
import CodexKit
import ObservationBridge
import ReviewChatLogUI

@MainActor
final class ReviewMonitorTransportViewController: NSViewController {
    private let codexModelSource: ReviewMonitorCodexModelSource?
    private let uiState: ReviewMonitorUIState
    private let chatLogTarget = ReviewMonitorCodexChatLogTarget()
    private let placeholderViewController = PlaceholderViewController()
    private var displayedContentConstraints: [NSLayoutConstraint] = []
    private var selectionObservation: PortableObservationTracking.Token?
    private var boundModelContext: CodexModelContext?
    private var boundChatID: CodexThreadID?
    private var displayedSelection: ReviewMonitorSelectionID?

    convenience init(
        uiState: ReviewMonitorUIState,
        modelContext: CodexModelContext
    ) {
        self.init(
            uiState: uiState,
            codexModelSource: ReviewMonitorCodexModelSource(modelContext: modelContext)
        )
    }

    init(
        uiState: ReviewMonitorUIState,
        codexModelSource: ReviewMonitorCodexModelSource? = nil
    ) {
        self.codexModelSource = codexModelSource
        self.uiState = uiState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        selectionObservation?.cancel()
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        bindObservation()
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard performDisplayedTextFinderAction(sender) else {
            super.performTextFinderAction(sender)
            return
        }
    }

    private func configureHierarchy() {
        let safeArea = view.safeAreaLayoutGuide
        let placeholderView = placeholderViewController.view
        let chatLogView = chatLogTarget.view
        addChild(placeholderViewController)
        placeholderView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(chatLogView)
        view.addSubview(placeholderView)

        displayedContentConstraints = [
            chatLogView.topAnchor.constraint(equalTo: view.topAnchor),
            chatLogView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            chatLogView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            chatLogView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
        ]

        NSLayoutConstraint.activate(
            displayedContentConstraints
                + [
                    placeholderView.topAnchor.constraint(equalTo: view.topAnchor),
                    placeholderView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
                    placeholderView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
                    placeholderView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                ]
        )
    }

    private func bindObservation() {
        selectionObservation?.cancel()
        selectionObservation = withPortableContinuousObservation { [weak self, uiState] event in
            let selection = uiState.selection
            let modelContext = self?.codexModelSource?.modelContext
            guard let self else {
                return
            }
            guard event.kind == .initial
                || self.selectionRequiresPresentationUpdate(selection, modelContext: modelContext)
            else {
                return
            }
            self.updatePresentation(selection: selection, modelContext: modelContext)
        }
    }

    private func selectionRequiresPresentationUpdate(
        _ selection: ReviewMonitorSelection?,
        modelContext: CodexModelContext?
    ) -> Bool {
        switch selection {
        case .workspaceGroup:
            return displayedSelection != selection?.id
        case .chat(let selectedChatID):
            return boundChatID != selectedChatID
                || boundModelContext !== modelContext
                || displayedSelection != selection?.id
        case nil:
            return displayedSelection != nil
        }
    }

    private func updatePresentation(selection: ReviewMonitorSelection?, modelContext: CodexModelContext?) {
        switch selection {
        case .workspaceGroup:
            clearDisplayedLogSelection()
            displayPlaceholder(.noFindings)
            chatLogTarget.view.isHidden = true
            displayedSelection = selection?.id

        case .chat:
            if case .chat(let selectedChatID) = selection {
                displayChat(selectedChatID, modelContext: modelContext)
            }
            hidePlaceholder()
            chatLogTarget.view.isHidden = false
            displayedSelection = selection?.id

        case nil:
            clearDisplayedLogSelection()
            displayPlaceholder(.noSelection)
            chatLogTarget.view.isHidden = true
            displayedSelection = nil
        }
    }

    private func displayChat(_ selectedChatID: CodexThreadID, modelContext: CodexModelContext?) {
        guard boundChatID != selectedChatID || boundModelContext !== modelContext else {
            return
        }
        boundChatID = selectedChatID
        boundModelContext = modelContext
        guard let modelContext else {
            chatLogTarget.clear()
            return
        }

        let chat = modelContext.model(for: selectedChatID)
        chatLogTarget.bind(chat: chat, modelContext: modelContext)
    }

    private func clearDisplayedLogSelection() {
        boundChatID = nil
        boundModelContext = nil
        chatLogTarget.clear()
    }

    @discardableResult
    private func displayPlaceholder(_ content: PlaceholderContent) -> Bool {
        let contentChanged = placeholderViewController.render(content: content)
        let hiddenChanged = placeholderViewController.view.isHidden
        placeholderViewController.view.isHidden = false
        return contentChanged || hiddenChanged
    }

    @discardableResult
    private func hidePlaceholder() -> Bool {
        let hiddenChanged = placeholderViewController.view.isHidden == false
        placeholderViewController.view.isHidden = true
        return hiddenChanged
    }

    @discardableResult
    func performDisplayedTextFinderAction(_ sender: Any?) -> Bool {
        switch displayedSelection {
        case .chat:
            return chatLogTarget.performDisplayedTextFinderAction(sender)
        case .workspaceGroup, nil:
            return false
        }
    }

    func validateDisplayedTextFinderAction(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch displayedSelection {
        case .chat:
            return chatLogTarget.validateDisplayedTextFinderAction(item)
        case .workspaceGroup, nil:
            return false
        }
    }

}

#if DEBUG
    @MainActor
    extension ReviewMonitorTransportViewController {
        struct RenderSnapshotForTesting: Sendable, Equatable {
            let log: String
            let isShowingEmptyState: Bool
        }

        enum DisplayedSelectionForTesting: Sendable, Equatable {
            case workspaceGroup(String)
            case chat(String)
        }

        struct RenderedStateForTesting: Sendable, Equatable {
            let snapshot: RenderSnapshotForTesting
            let selection: DisplayedSelectionForTesting?
        }

        var selectionObservationForTesting: PortableObservationTracking.Token? {
            selectionObservation
        }

        var selectedChatLogTaskForTesting: Task<Void, Never>? {
            chatLogTarget.selectedChatLogTaskForTesting
        }

        var displayedLogForTesting: String {
            chatLogTarget.displayedTextForTesting
        }

        var isShowingEmptyStateForTesting: Bool {
            placeholderViewController.view.isHidden == false && placeholderViewController.content == .noSelection
        }

        var emptyStateFrameForTesting: NSRect {
            placeholderViewController.view.frame
        }

        var isShowingNoFindingsStateForTesting: Bool {
            placeholderViewController.view.isHidden == false && placeholderViewController.content == .noFindings
        }

        var logAppendCountForTesting: Int {
            chatLogTarget.appendCount
        }

        var logReplaceCountForTesting: Int {
            chatLogTarget.replaceCount
        }

        var logReloadCountForTesting: Int {
            chatLogTarget.reloadCount
        }

        var logAutoFollowCountForTesting: Int {
            chatLogTarget.autoFollowCount
        }

        var logWordGlowCountForTesting: Int {
            chatLogTarget.wordGlowCountForTesting
        }

        var logWordFadeRenderingAttributeRangeCountForTesting: Int {
            chatLogTarget.wordFadeRenderingAttributeRangeCountForTesting
        }

        var logWordFadeStorageUsesOpaqueTextColorForTesting: Bool {
            chatLogTarget.wordFadeStorageUsesOpaqueTextColorForTesting
        }

        var logWordFadeDisplayInvalidationCountForTesting: Int {
            chatLogTarget.wordFadeDisplayInvalidationCountForTesting
        }

        var logCommandOutputPanelCountForTesting: Int {
            chatLogTarget.commandOutputPanelCountForTesting
        }

        var logTerminalDecorationRectCountForTesting: Int {
            chatLogTarget.terminalDecorationRectCountForTesting
        }

        var logExpandedCommandOutputPanelCountForTesting: Int {
            chatLogTarget.expandedCommandOutputPanelCountForTesting
        }

        var logCommandOutputPanelUsesTextKit2ForTesting: Bool {
            chatLogTarget.commandOutputPanelUsesTextKit2ForTesting
        }

        var logCommandOutputPanelUsesInlineAttachmentForTesting: Bool {
            chatLogTarget.commandOutputPanelUsesInlineAttachmentForTesting
        }

        var logCommandOutputPanelUsesButtonAttachmentForTesting: Bool {
            chatLogTarget.commandOutputPanelUsesButtonAttachmentForTesting
        }

        var logCollapsedCommandOutputPanelAttachmentLineHeightForTesting: CGFloat? {
            chatLogTarget.collapsedCommandOutputPanelAttachmentLineHeightForTesting
        }

        var logCollapsedCommandOutputPanelAttachmentPayloadIsEmptyForTesting: Bool {
            chatLogTarget.collapsedCommandOutputPanelAttachmentPayloadIsEmptyForTesting
        }

        var logCommandOutputPanelUsesSystemMaterialBackgroundForTesting: Bool {
            chatLogTarget.commandOutputPanelUsesSystemMaterialBackgroundForTesting
        }

        var logCommandOutputPanelVisibleLineCapacityForTesting: Int {
            chatLogTarget.commandOutputPanelVisibleLineCapacityForTesting
        }

        var logCommandOutputPanelResultTextForTesting: String? {
            chatLogTarget.commandOutputPanelResultTextForTesting
        }

        var logCommandOutputPanelTerminalTextForTesting: String? {
            chatLogTarget.commandOutputPanelTerminalTextForTesting
        }

        func logCommandOutputPanelTerminalTextForTesting(blockID: ReviewMonitorLog.BlockID) -> String? {
            chatLogTarget.commandOutputPanelTerminalTextForTesting(blockID: blockID)
        }

        var logCommandOutputPanelCommandLineTextForTesting: String? {
            chatLogTarget.commandOutputPanelCommandLineTextForTesting
        }

        var logCommandOutputPanelOutputScrollTextForTesting: String? {
            chatLogTarget.commandOutputPanelOutputScrollTextForTesting
        }

        var logCommandOutputPanelOutputScrollIsScrollableForTesting: Bool {
            chatLogTarget.commandOutputPanelOutputScrollIsScrollableForTesting
        }

        var logCommandOutputPanelOutputScrollUsesHorizontalScrollingForTesting: Bool {
            chatLogTarget.commandOutputPanelOutputScrollUsesHorizontalScrollingForTesting
        }

        var logCommandOutputPanelOutputScrollVerticalOffsetForTesting: CGFloat? {
            chatLogTarget.commandOutputPanelOutputScrollVerticalOffsetForTesting
        }

        var logCommandOutputPanelOutputScrollMaximumVerticalOffsetForTesting: CGFloat? {
            chatLogTarget.commandOutputPanelOutputScrollMaximumVerticalOffsetForTesting
        }

        func scrollCommandOutputPanelOutputForTesting(deltaY: CGFloat) -> Bool {
            chatLogTarget.scrollCommandOutputPanelOutputForTesting(deltaY: deltaY)
        }

        var logCommandOutputPanelOutputHitTestTargetsTextViewForTesting: Bool {
            chatLogTarget.commandOutputPanelOutputHitTestTargetsTextViewForTesting
        }

        func logFinderRectsForTesting(_ range: NSRange) -> [NSRect] {
            chatLogTarget.finderRectsForTesting(range)
        }

        var logFirstCommandOutputPanelRectForTesting: NSRect? {
            chatLogTarget.firstCommandOutputPanelRectForTesting
        }

        var logCommandOutputPanelToggleSymbolNameForTesting: String? {
            chatLogTarget.commandOutputPanelToggleSymbolNameForTesting
        }

        var logCommandOutputPanelLeadingAlignmentDeltaForTesting: CGFloat? {
            chatLogTarget.commandOutputPanelLeadingAlignmentDeltaForTesting
        }

        var logCommandOutputPanelChevronSizeDeltaForTesting: CGFloat? {
            chatLogTarget.commandOutputPanelChevronSizeDeltaForTesting
        }

        var logCommandOutputPanelChevronVerticalAlignmentDeltaForTesting: CGFloat? {
            chatLogTarget.commandOutputPanelChevronVerticalAlignmentDeltaForTesting
        }

        func logHitTestTargetsDocumentViewForFirstOccurrenceForTesting(_ text: String) -> Bool {
            chatLogTarget.hitTestTargetsDocumentViewForFirstLogOccurrenceForTesting(text)
        }

        func toggleFirstLogCommandOutputPanelForTesting() {
            chatLogTarget.toggleFirstCommandOutputPanelForTesting()
        }

        @discardableResult
        func clickFirstLogCommandOutputPanelHeaderForTesting() -> Bool {
            chatLogTarget.clickFirstCommandOutputPanelHeaderForTesting()
        }

        @discardableResult
        func clickLogCommandOutputPanelHeaderForTesting(blockID: ReviewMonitorLog.BlockID) -> Bool {
            chatLogTarget.clickCommandOutputPanelHeaderForTesting(blockID: blockID)
        }

        func completeLogWordGlowAnimationsForTesting() {
            chatLogTarget.completeWordGlowAnimationsForTesting()
        }

        func advanceLogWordGlowAnimationsAfterInitialDelayForTesting(_ delay: TimeInterval) {
            chatLogTarget.advanceWordGlowAnimationsAfterInitialDelayForTesting(delay)
        }

        func setLogReduceMotionForTesting(_ reduceMotion: Bool?) {
            chatLogTarget.setReduceMotionForTesting(reduceMotion)
        }

        var logUsesCustomTextKit2SurfaceForTesting: Bool {
            chatLogTarget.usesCustomTextKit2SurfaceForTesting
        }

        var logUsesTextViewForTesting: Bool {
            chatLogTarget.usesTextViewForTesting
        }

        var logUsesLogLayoutManagerForTesting: Bool {
            chatLogTarget.usesLogLayoutManagerForTesting
        }

        var logIsEditableForTesting: Bool {
            chatLogTarget.isEditableForTesting
        }

        var logIsSelectableForTesting: Bool {
            chatLogTarget.isSelectableForTesting
        }

        var logUsesFindBarForTesting: Bool {
            chatLogTarget.usesFindBarForTesting
        }

        var logIsIncrementalSearchingEnabledForTesting: Bool {
            chatLogTarget.isIncrementalSearchingEnabledForTesting
        }

        var logFindBarVisibleForTesting: Bool {
            chatLogTarget.isFindBarVisibleForTesting
        }

        var logTextFinderIdentifierForTesting: ObjectIdentifier {
            chatLogTarget.textFinderIdentifierForTesting
        }

        var logFindVisibleCharacterRangesForTesting: [NSRange] {
            chatLogTarget.findVisibleCharacterRangesForTesting
        }

        var logFindStringLengthForTesting: Int {
            chatLogTarget.findStringLengthForTesting
        }

        var logFindClientUsesSnapshotForTesting: Bool {
            chatLogTarget.findClientUsesSnapshotForTesting
        }

        var logFindClientSnapshotMapsToDocumentForTesting: Bool {
            chatLogTarget.findClientSnapshotMapsToDocumentForTesting
        }

        var logFindClientFirstSelectedRangeForTesting: NSRange {
            chatLogTarget.findClientFirstSelectedRangeForTesting
        }

        var logHasActiveFindQueryForTesting: Bool {
            chatLogTarget.hasActiveFindQueryForTesting
        }

        var logVisibleFindBarSearchStringForTesting: String? {
            chatLogTarget.visibleFindBarSearchStringForTesting
        }

        @discardableResult
        func setLogVisibleFindBarSearchStringForTesting(_ string: String) -> Bool {
            chatLogTarget.setVisibleFindBarSearchStringForTesting(string)
        }

        var logFindIndicatorInvalidationCountForTesting: Int {
            chatLogTarget.findIndicatorInvalidationCountForTesting
        }

        var logFindIncrementalMatchRangeCountForTesting: Int {
            chatLogTarget.findIncrementalMatchRangeCountForTesting
        }

        var logFindBarContainerContentViewIsTextContentViewForTesting: Bool {
            chatLogTarget.findBarContainerContentViewIsTextContentViewForTesting
        }

        var logFindIncrementalSearchUsesSystemHighlightingForTesting: Bool {
            chatLogTarget.findIncrementalSearchUsesSystemHighlightingForTesting
        }

        var logHitTestTargetsDocumentViewForTesting: Bool {
            chatLogTarget.hitTestTargetsDocumentViewForTesting
        }

        var logWritingToolsDisabledForTesting: Bool {
            chatLogTarget.writingToolsDisabledForTesting
        }

        var logOverlayScrollerHideRequestCountForTesting: Int {
            chatLogTarget.overlayScrollerHideRequestCountForTesting
        }

        var logRenderIsIdleForTesting: Bool {
            chatLogTarget.logRenderIsIdleForTesting
        }

        var logFrameForTesting: NSRect {
            chatLogTarget.frame
        }

        var viewFrameForTesting: NSRect {
            view.frame
        }

        var viewBoundsForTesting: NSRect {
            view.bounds
        }

        var safeAreaFrameForTesting: NSRect {
            view.safeAreaRect
        }

        var displayedViewFrameForTesting: NSRect {
            chatLogTarget.frame
        }

        var activeDisplayedViewConstraintCountForTesting: Int {
            displayedContentConstraints.filter(\.isActive).count
        }

        var renderSnapshotForTesting: RenderSnapshotForTesting {
            if isShowingEmptyStateForTesting {
                return .init(
                    log: "",
                    isShowingEmptyState: true
                )
            }
            return .init(
                log: displayedLogForTesting,
                isShowingEmptyState: false
            )
        }

        var renderedStateForTesting: RenderedStateForTesting {
            .init(
                snapshot: renderSnapshotForTesting,
                selection: displayedSelectionForTesting
            )
        }

        private var displayedSelectionForTesting: DisplayedSelectionForTesting? {
            switch displayedSelection {
            case .workspaceGroup(let id):
                .workspaceGroup(id.rawValue)
            case .chat(let id):
                .chat(id.rawValue)
            case nil:
                nil
            }
        }

        func scrollLogToTopForTesting() {
            chatLogTarget.scrollToTopForTesting()
        }

        func scrollLogToOffsetForTesting(_ y: CGFloat) {
            chatLogTarget.scrollToOffsetForTesting(y)
        }

        var logVerticalScrollOffsetForTesting: CGFloat {
            chatLogTarget.verticalScrollOffsetForTesting
        }

        var logViewportHeightForTesting: CGFloat {
            chatLogTarget.viewportHeightForTesting
        }

        var logMinimumVerticalScrollOffsetForTesting: CGFloat {
            chatLogTarget.minimumVerticalScrollOffsetForTesting
        }

        var logMaximumVerticalScrollOffsetForTesting: CGFloat {
            chatLogTarget.maximumVerticalScrollOffsetForTesting
        }

        var logTextContentFrameForTesting: NSRect {
            chatLogTarget.textContentFrameForTesting
        }

        var logDocumentViewFrameForTesting: NSRect {
            chatLogTarget.documentViewFrameForTesting
        }

        var logContentInsetsForTesting: NSEdgeInsets {
            chatLogTarget.contentInsetsForTesting
        }

        var logAutomaticallyAdjustsContentInsetsForTesting: Bool {
            chatLogTarget.automaticallyAdjustsContentInsetsForTesting
        }

        var logTextContainerSizeForTesting: NSSize {
            chatLogTarget.textContainerSizeForTesting
        }

        var logTextContainerInsetForTesting: NSSize {
            chatLogTarget.textContainerInsetForTesting
        }

        var logVisibleFragmentViewCountForTesting: Int {
            chatLogTarget.visibleFragmentViewCountForTesting
        }

        var logVisibleFragmentViewCountWithoutForcingLayoutForTesting: Int {
            chatLogTarget.visibleFragmentViewCountWithoutForcingLayoutForTesting
        }

        var logVisibleFragmentBoundsForTesting: NSRect {
            chatLogTarget.visibleFragmentBoundsForTesting
        }

        var logVisibleFragmentBoundsWithoutForcingLayoutForTesting: NSRect {
            chatLogTarget.visibleFragmentBoundsWithoutForcingLayoutForTesting
        }

        var logStaleFragmentViewCountForTesting: Int {
            chatLogTarget.staleFragmentViewCountForTesting
        }

        var logProgrammaticScrollCountForTesting: Int {
            chatLogTarget.programmaticScrollCountForTesting
        }

        var logAccessibilityValueForTesting: String? {
            chatLogTarget.accessibilityValueForTesting
        }

        var logSelectedTextForTesting: String? {
            chatLogTarget.selectedTextForTesting
        }

        var logSelectedRangeForTesting: NSRange {
            chatLogTarget.selectedRangeForTesting
        }

        var logFindStringForTesting: String {
            chatLogTarget.findStringForTesting
        }

        func selectAllLogForTesting() {
            chatLogTarget.selectAllForTesting()
        }

        func setSelectedLogRangeForTesting(_ range: NSRange) {
            chatLogTarget.setSelectedLogRangeForTesting(range)
        }

        var logDocumentViewExportsUserInterfaceValidationForTesting: Bool {
            chatLogTarget.documentViewExportsUserInterfaceValidationForTesting
        }

        func validateLogDocumentUserInterfaceItemForTesting(_ item: NSValidatedUserInterfaceItem) -> Bool {
            chatLogTarget.validateDocumentUserInterfaceItemForTesting(item)
        }

        func clearLogFinderSelectedRangesForTesting() {
            chatLogTarget.clearFinderSelectedRangesForTesting()
        }

        func setLogFinderSelectedRangeForTesting(_ range: NSRange) {
            chatLogTarget.setFinderSelectedRangeForTesting(range)
        }

        func simulateLogFinderEmptySelectedRangesForTesting() {
            chatLogTarget.simulateFinderEmptySelectedRangesForTesting()
        }

        func performLogKeyboardCommandForTesting(_ selector: Selector) {
            chatLogTarget.performKeyboardCommandForTesting(selector)
        }

        @discardableResult
        func renderLogForTesting(text: String, allowIncrementalUpdate: Bool) -> Bool {
            chatLogTarget.renderForTesting(text: text, allowIncrementalUpdate: allowIncrementalUpdate)
        }

        @discardableResult
        func renderLogDocumentForTesting(
            _ sourceDocument: ReviewMonitorLog.Document,
            target: DisplayedSelectionForTesting? = nil,
            allowIncrementalUpdate: Bool
        ) -> Bool {
            let chatID: CodexThreadID
            switch target ?? displayedSelectionForTesting {
            case .chat(let id):
                chatID = CodexThreadID(rawValue: id)
            case .workspaceGroup, nil:
                return false
            }
            return chatLogTarget.renderLogDocumentForTesting(
                sourceDocument,
                chatID: chatID,
                allowIncrementalUpdate: allowIncrementalUpdate
            )
        }

        func bindLogRenderTargetForTesting(_ target: DisplayedSelectionForTesting) {
            switch target {
            case .chat(let id):
                let chatID = CodexThreadID(rawValue: id)
                chatLogTarget.bindLogRenderTargetForTesting(chatID)
                boundChatID = chatID
                boundModelContext = nil
                hidePlaceholder()
                chatLogTarget.view.isHidden = false
                displayedSelection = .chat(chatID)
            case .workspaceGroup:
                break
            }
        }

        func copyLogSelectionForTesting() {
            chatLogTarget.copySelectionForTesting()
        }

        func beginLogLiveResizeForTesting() {
            chatLogTarget.beginLiveResizeForTesting()
        }

        func endLogLiveResizeForTesting() {
            chatLogTarget.endLiveResizeForTesting()
        }

        func scrollLogToBottomForTesting() {
            chatLogTarget.scrollToBottomForTesting()
        }

        var isLogPinnedToBottomForTesting: Bool {
            chatLogTarget.isPinnedToBottomForTesting
        }

        func setLogScrollerStyleForTesting(_ style: NSScroller.Style) {
            chatLogTarget.setScrollerStyleForTesting(style)
        }

        func setLogOverlayScrollersShownForTesting(_ isShown: Bool?) {
            chatLogTarget.setOverlayScrollersShownForTesting(isShown)
        }

        func setLogOverlayScrollerBridgeModeForTesting(
            _ mode: ReviewMonitorCodexChatLogTarget.OverlayScrollerBridgeModeForTesting
        ) {
            chatLogTarget.setOverlayScrollerBridgeModeForTesting(mode)
        }
    }
#endif
