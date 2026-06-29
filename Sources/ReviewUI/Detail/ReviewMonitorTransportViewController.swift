import AppKit
import CodexKit
import ObservationBridge

@MainActor
final class ReviewMonitorTransportViewController: NSViewController {
    private enum LogRenderTarget: Equatable {
        case chat(CodexThreadID)
    }

    private let codexModelSource: ReviewMonitorCodexModelSource?
    private let uiState: ReviewMonitorUIState
    private let selectedCodexChat: ReviewMonitorSelectedCodexChat
    private let logScrollView = ReviewMonitorLogScrollView()
    private var logRenderer = ReviewMonitorLogRenderer()
    private let placeholderViewController = PlaceholderViewController()
    private var displayedContentConstraints: [NSLayoutConstraint] = []
    private var selectionObservation: PortableObservationTracking.Token?
    private var selectedChatLogTask: Task<Void, Never>?
    private var boundChatID: CodexThreadID?
    private var displayedSelection: ReviewMonitorSelectionID?
    private var logScrollTargetsByChatID: [CodexThreadID: ReviewMonitorLogScrollView.ScrollRestorationTarget] = [:]
    private var logRenderTask: Task<Void, Never>?
    private var logRenderGeneration: UInt64 = 0
    private var appliedLogRenderGeneration: UInt64 = 0
    private var hasAppliedBoundLog = false

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
        self.selectedCodexChat = ReviewMonitorSelectedCodexChat(
            modelSource: codexModelSource
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        selectionObservation?.cancel()
        selectedChatLogTask?.cancel()
        logRenderTask?.cancel()
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
        addChild(placeholderViewController)
        placeholderView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(logScrollView)
        view.addSubview(placeholderView)

        displayedContentConstraints = [
            logScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            logScrollView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            logScrollView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            logScrollView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
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
            guard let self else {
                return
            }
            guard event.kind == .initial || self.selectionRequiresPresentationUpdate(selection) else {
                return
            }
            self.updatePresentation(selection: selection)
        }
    }

    private func selectionRequiresPresentationUpdate(_ selection: ReviewMonitorSelection?) -> Bool {
        switch selection {
        case .workspaceGroup:
            return displayedSelection != selection?.id
        case .workspace:
            return displayedSelection != selection?.id
        case .chat(let selectedChatID):
            return boundChatID != selectedChatID
                || displayedSelection != selection?.id
        case nil:
            return displayedSelection != nil
        }
    }

    private func updatePresentation(selection: ReviewMonitorSelection?) {
        switch selection {
        case .workspaceGroup:
            clearDisplayedLogSelection()
            displayPlaceholder(.noFindings)
            logScrollView.isHidden = true
            displayedSelection = selection?.id

        case .workspace:
            clearDisplayedLogSelection()
            displayPlaceholder(.noFindings)
            logScrollView.isHidden = true
            displayedSelection = selection?.id

        case .chat:
            if case .chat(let selectedChatID) = selection {
                displayChat(selectedChatID)
            }
            hidePlaceholder()
            logScrollView.isHidden = false
            displayedSelection = selection?.id

        case nil:
            clearDisplayedLogSelection()
            displayPlaceholder(.noSelection)
            logScrollView.isHidden = true
            displayedSelection = nil
        }
    }

    private func displayChat(_ selectedChatID: CodexThreadID) {
        let isSwitchingRenderedChat = boundChatID != nil && boundChatID != selectedChatID
        cacheBoundLogScrollTarget()
        if isSwitchingRenderedChat {
            logScrollView.resetFindStateForContentReuse()
        }
        selectedChatLogTask?.cancel()
        selectedChatLogTask = nil
        resetLogRenderer()
        boundChatID = selectedChatID
        let restorationTarget = restorationTarget(chatID: selectedChatID)
        selectedCodexChat.bind(toChatID: selectedChatID)
        startSelectedCodexChatLogStream(
            target: .chat(selectedChatID),
            initialRestorationTarget: restorationTarget
        )
    }

    private func clearDisplayedLogSelection() {
        cacheBoundLogScrollTarget()
        selectedChatLogTask?.cancel()
        selectedChatLogTask = nil
        boundChatID = nil
        selectedCodexChat.unbind()
        resetLogRenderer()
        logScrollView.resetFindStateForContentReuse()
        logScrollView.clear()
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
    private func renderBoundLog(
        sourceDocument: ReviewMonitorLog.Document,
        target: LogRenderTarget,
        restorationTarget: ReviewMonitorLogScrollView.ScrollRestorationTarget,
        allowIncrementalUpdate: Bool
    ) -> Bool {
        logRenderGeneration &+= 1
        let generation = logRenderGeneration
        let renderer = logRenderer
        logRenderTask?.cancel()
        logRenderTask = Task { @MainActor [weak self] in
            let renderedDocument = await renderer.render(sourceDocument: sourceDocument)
            guard Task.isCancelled == false,
                let self,
                self.logRenderGeneration == generation,
                self.isCurrentLogRenderTarget(target)
            else {
                return
            }
            _ = self.logScrollView.render(
                sourceDocument: renderedDocument.source,
                displayDocument: renderedDocument.display,
                restoring: restorationTarget,
                allowIncrementalUpdate: allowIncrementalUpdate && self.hasAppliedBoundLog
            )
            self.appliedLogRenderGeneration = generation
            self.hasAppliedBoundLog = true
        }
        return true
    }

    private func startSelectedCodexChatLogStream(
        target: LogRenderTarget,
        initialRestorationTarget: ReviewMonitorLogScrollView.ScrollRestorationTarget
    ) {
        startLogSourceChangeStream(
            selectedCodexChat.logSourceChangeStream(),
            target: target,
            initialRestorationTarget: initialRestorationTarget
        )
    }

    private func startLogSourceChangeStream(
        _ stream: AsyncStream<ReviewMonitorLogSourceChange>,
        target: LogRenderTarget,
        initialRestorationTarget: ReviewMonitorLogScrollView.ScrollRestorationTarget
    ) {
        selectedChatLogTask?.cancel()
        selectedChatLogTask = Task { @MainActor [weak self] in
            for await change in stream {
                guard let self,
                    self.isCurrentLogRenderTarget(target)
                else {
                    return
                }
                let hasAppliedInitialDocument = self.hasAppliedBoundLog
                self.applySelectedCodexChatLogChange(
                    change,
                    target: target,
                    restorationTarget: hasAppliedInitialDocument
                        ? self.logScrollView.currentScrollRestorationTarget
                        : initialRestorationTarget,
                    allowIncrementalUpdate: hasAppliedInitialDocument && change.allowsIncrementalRender
                )
            }
        }
    }

    private func applySelectedCodexChatLogChange(
        _ change: ReviewMonitorLogSourceChange,
        target: LogRenderTarget,
        restorationTarget: ReviewMonitorLogScrollView.ScrollRestorationTarget,
        allowIncrementalUpdate: Bool
    ) {
        guard let document = change.sourceDocument else {
            resetLogRenderer()
            logScrollView.clear()
            return
        }
        renderBoundLog(
            sourceDocument: document,
            target: target,
            restorationTarget: restorationTarget,
            allowIncrementalUpdate: allowIncrementalUpdate
        )
    }

    private func isCurrentLogRenderTarget(_ target: LogRenderTarget) -> Bool {
        switch target {
        case .chat(let id):
            boundChatID == id
        }
    }

    private func cacheBoundLogScrollTarget() {
        let restorationTarget = logScrollView.currentScrollRestorationTarget
        if let boundChatID {
            logScrollTargetsByChatID[boundChatID] = restorationTarget
        }
    }

    private func resetLogRenderer() {
        logRenderTask?.cancel()
        logRenderTask = nil
        logRenderGeneration &+= 1
        appliedLogRenderGeneration = logRenderGeneration
        hasAppliedBoundLog = false
        logRenderer = ReviewMonitorLogRenderer()
    }

    private func restorationTarget(
        chatID: CodexThreadID
    ) -> ReviewMonitorLogScrollView.ScrollRestorationTarget {
        logScrollTargetsByChatID[chatID] ?? .bottom
    }

    @discardableResult
    func performDisplayedTextFinderAction(_ sender: Any?) -> Bool {
        switch displayedSelection {
        case .chat:
            return logScrollView.performDisplayedTextFinderAction(sender)
        case .workspaceGroup, .workspace, nil:
            return false
        }
    }

    func validateDisplayedTextFinderAction(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch displayedSelection {
        case .chat:
            return logScrollView.validateDisplayedTextFinderAction(item)
        case .workspaceGroup, .workspace, nil:
            return false
        }
    }

}

#if DEBUG
    @MainActor
    extension ReviewMonitorTransportViewController {
        struct RenderSnapshotForTesting: Sendable, Equatable {
            let title: String?
            let summary: String?
            let log: String
            let isShowingEmptyState: Bool
        }

        enum DisplayedSelectionForTesting: Sendable, Equatable {
            case workspaceGroup(String)
            case workspace(String)
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
            selectedChatLogTask
        }

        var selectedCodexChatIDForTesting: String? {
            selectedCodexChat.chat?.id.rawValue
        }

        var selectedCodexChatPhaseForTesting: CodexDataPhase {
            selectedCodexChat.phase
        }

        var selectedCodexChatItemTextsForTesting: [String] {
            selectedCodexChat.chat?.items.compactMap(\.text) ?? []
        }

        var observationForExpectedRenderedStateForTesting: PortableObservationTracking.Token? {
            let expectedSelection = expectedRenderedStateForTesting.selection
            if displayedSelectionForTesting != expectedSelection {
                return selectionObservation
            }
            switch expectedSelection {
            case .workspaceGroup, .workspace, .chat:
                return selectionObservation
            case nil:
                return selectionObservation
            }
        }

        var displayedTitleForTesting: String? {
            nil
        }

        var displayedLogForTesting: String {
            logScrollView.displayedTextForTesting
        }

        var displayedSummaryForTesting: String? {
            nil
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
            logScrollView.appendCount
        }

        var logReplaceCountForTesting: Int {
            logScrollView.replaceCount
        }

        var logReloadCountForTesting: Int {
            logScrollView.reloadCount
        }

        var logAutoFollowCountForTesting: Int {
            logScrollView.autoFollowCount
        }

        var logWordGlowCountForTesting: Int {
            logScrollView.wordGlowCountForTesting
        }

        var logWordFadeRenderingAttributeRangeCountForTesting: Int {
            logScrollView.wordFadeRenderingAttributeRangeCountForTesting
        }

        var logWordFadeStorageUsesOpaqueTextColorForTesting: Bool {
            logScrollView.wordFadeStorageUsesOpaqueTextColorForTesting
        }

        var logWordFadeDisplayInvalidationCountForTesting: Int {
            logScrollView.wordFadeDisplayInvalidationCountForTesting
        }

        var logCommandOutputPanelCountForTesting: Int {
            logScrollView.commandOutputPanelCountForTesting
        }

        var logTerminalDecorationRectCountForTesting: Int {
            logScrollView.terminalDecorationRectCountForTesting
        }

        var logExpandedCommandOutputPanelCountForTesting: Int {
            logScrollView.expandedCommandOutputPanelCountForTesting
        }

        var logCommandOutputPanelUsesTextKit2ForTesting: Bool {
            logScrollView.commandOutputPanelUsesTextKit2ForTesting
        }

        var logCommandOutputPanelUsesInlineAttachmentForTesting: Bool {
            logScrollView.commandOutputPanelUsesInlineAttachmentForTesting
        }

        var logCommandOutputPanelUsesButtonAttachmentForTesting: Bool {
            logScrollView.commandOutputPanelUsesButtonAttachmentForTesting
        }

        var logCollapsedCommandOutputPanelAttachmentLineHeightForTesting: CGFloat? {
            logScrollView.collapsedCommandOutputPanelAttachmentLineHeightForTesting
        }

        var logCollapsedCommandOutputPanelAttachmentPayloadIsEmptyForTesting: Bool {
            logScrollView.collapsedCommandOutputPanelAttachmentPayloadIsEmptyForTesting
        }

        var logCommandOutputPanelUsesSystemMaterialBackgroundForTesting: Bool {
            logScrollView.commandOutputPanelUsesSystemMaterialBackgroundForTesting
        }

        var logCommandOutputPanelVisibleLineCapacityForTesting: Int {
            logScrollView.commandOutputPanelVisibleLineCapacityForTesting
        }

        var logCommandOutputPanelResultTextForTesting: String? {
            logScrollView.commandOutputPanelResultTextForTesting
        }

        var logCommandOutputPanelTerminalTextForTesting: String? {
            logScrollView.commandOutputPanelTerminalTextForTesting
        }

        func logCommandOutputPanelTerminalTextForTesting(blockID: ReviewMonitorLog.BlockID) -> String? {
            logScrollView.commandOutputPanelTerminalTextForTesting(blockID: blockID)
        }

        var logCommandOutputPanelCommandLineTextForTesting: String? {
            logScrollView.commandOutputPanelCommandLineTextForTesting
        }

        var logCommandOutputPanelOutputScrollTextForTesting: String? {
            logScrollView.commandOutputPanelOutputScrollTextForTesting
        }

        var logCommandOutputPanelOutputScrollIsScrollableForTesting: Bool {
            logScrollView.commandOutputPanelOutputScrollIsScrollableForTesting
        }

        var logCommandOutputPanelOutputScrollUsesHorizontalScrollingForTesting: Bool {
            logScrollView.commandOutputPanelOutputScrollUsesHorizontalScrollingForTesting
        }

        var logCommandOutputPanelOutputScrollVerticalOffsetForTesting: CGFloat? {
            logScrollView.commandOutputPanelOutputScrollVerticalOffsetForTesting
        }

        var logCommandOutputPanelOutputScrollMaximumVerticalOffsetForTesting: CGFloat? {
            logScrollView.commandOutputPanelOutputScrollMaximumVerticalOffsetForTesting
        }

        func scrollCommandOutputPanelOutputForTesting(deltaY: CGFloat) -> Bool {
            logScrollView.scrollCommandOutputPanelOutputForTesting(deltaY: deltaY)
        }

        var logCommandOutputPanelOutputHitTestTargetsTextViewForTesting: Bool {
            logScrollView.commandOutputPanelOutputHitTestTargetsTextViewForTesting
        }

        func logFinderRectsForTesting(_ range: NSRange) -> [NSRect] {
            logScrollView.finderRectsForTesting(range)
        }

        var logFirstCommandOutputPanelRectForTesting: NSRect? {
            logScrollView.firstCommandOutputPanelRectForTesting
        }

        var logCommandOutputPanelToggleSymbolNameForTesting: String? {
            logScrollView.commandOutputPanelToggleSymbolNameForTesting
        }

        var logCommandOutputPanelLeadingAlignmentDeltaForTesting: CGFloat? {
            logScrollView.commandOutputPanelLeadingAlignmentDeltaForTesting
        }

        var logCommandOutputPanelChevronSizeDeltaForTesting: CGFloat? {
            logScrollView.commandOutputPanelChevronSizeDeltaForTesting
        }

        var logCommandOutputPanelChevronVerticalAlignmentDeltaForTesting: CGFloat? {
            logScrollView.commandOutputPanelChevronVerticalAlignmentDeltaForTesting
        }

        func logHitTestTargetsDocumentViewForFirstOccurrenceForTesting(_ text: String) -> Bool {
            logScrollView.hitTestTargetsDocumentViewForFirstLogOccurrenceForTesting(text)
        }

        func toggleFirstLogCommandOutputPanelForTesting() {
            logScrollView.toggleFirstCommandOutputPanelForTesting()
        }

        @discardableResult
        func clickFirstLogCommandOutputPanelHeaderForTesting() -> Bool {
            logScrollView.clickFirstCommandOutputPanelHeaderForTesting()
        }

        @discardableResult
        func clickLogCommandOutputPanelHeaderForTesting(blockID: ReviewMonitorLog.BlockID) -> Bool {
            logScrollView.clickCommandOutputPanelHeaderForTesting(blockID: blockID)
        }

        func completeLogWordGlowAnimationsForTesting() {
            logScrollView.completeWordGlowAnimationsForTesting()
        }

        func advanceLogWordGlowAnimationsAfterInitialDelayForTesting(_ delay: TimeInterval) {
            logScrollView.advanceWordGlowAnimationsAfterInitialDelayForTesting(delay)
        }

        func setLogReduceMotionForTesting(_ reduceMotion: Bool?) {
            logScrollView.setReduceMotionForTesting(reduceMotion)
        }

        var logUsesCustomTextKit2SurfaceForTesting: Bool {
            logScrollView.usesCustomTextKit2SurfaceForTesting
        }

        var logUsesTextViewForTesting: Bool {
            logScrollView.usesTextViewForTesting
        }

        var logUsesLogLayoutManagerForTesting: Bool {
            logScrollView.usesLogLayoutManagerForTesting
        }

        var logIsEditableForTesting: Bool {
            logScrollView.isEditableForTesting
        }

        var logIsSelectableForTesting: Bool {
            logScrollView.isSelectableForTesting
        }

        var logUsesFindBarForTesting: Bool {
            logScrollView.usesFindBarForTesting
        }

        var logIsIncrementalSearchingEnabledForTesting: Bool {
            logScrollView.isIncrementalSearchingEnabledForTesting
        }

        var logFindBarVisibleForTesting: Bool {
            logScrollView.isFindBarVisibleForTesting
        }

        var logTextFinderIdentifierForTesting: ObjectIdentifier {
            logScrollView.textFinderIdentifierForTesting
        }

        var logFindVisibleCharacterRangesForTesting: [NSRange] {
            logScrollView.findVisibleCharacterRangesForTesting
        }

        var logFindStringLengthForTesting: Int {
            logScrollView.findStringLengthForTesting
        }

        var logFindClientUsesSnapshotForTesting: Bool {
            logScrollView.findClientUsesSnapshotForTesting
        }

        var logFindClientSnapshotMapsToDocumentForTesting: Bool {
            logScrollView.findClientSnapshotMapsToDocumentForTesting
        }

        var logFindClientFirstSelectedRangeForTesting: NSRange {
            logScrollView.findClientFirstSelectedRangeForTesting
        }

        var logHasActiveFindQueryForTesting: Bool {
            logScrollView.hasActiveFindQueryForTesting
        }

        var logVisibleFindBarSearchStringForTesting: String? {
            logScrollView.visibleFindBarSearchStringForTesting
        }

        @discardableResult
        func setLogVisibleFindBarSearchStringForTesting(_ string: String) -> Bool {
            logScrollView.setVisibleFindBarSearchStringForTesting(string)
        }

        var logFindIndicatorInvalidationCountForTesting: Int {
            logScrollView.findIndicatorInvalidationCountForTesting
        }

        var logFindIncrementalMatchRangeCountForTesting: Int {
            logScrollView.findIncrementalMatchRangeCountForTesting
        }

        var logFindBarContainerContentViewIsTextContentViewForTesting: Bool {
            logScrollView.findBarContainerContentViewIsTextContentViewForTesting
        }

        var logFindIncrementalSearchUsesSystemHighlightingForTesting: Bool {
            logScrollView.findIncrementalSearchUsesSystemHighlightingForTesting
        }

        var logHitTestTargetsDocumentViewForTesting: Bool {
            logScrollView.hitTestTargetsDocumentViewForTesting
        }

        var logWritingToolsDisabledForTesting: Bool {
            logScrollView.writingToolsDisabledForTesting
        }

        var logOverlayScrollerHideRequestCountForTesting: Int {
            logScrollView.overlayScrollerHideRequestCountForTesting
        }

        var logRenderIsIdleForTesting: Bool {
            appliedLogRenderGeneration == logRenderGeneration
        }

        var logFrameForTesting: NSRect {
            logScrollView.frame
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
            logScrollView.frame
        }

        var activeDisplayedViewConstraintCountForTesting: Int {
            displayedContentConstraints.filter(\.isActive).count
        }

        var renderSnapshotForTesting: RenderSnapshotForTesting {
            if isShowingEmptyStateForTesting {
                return .init(
                    title: nil,
                    summary: nil,
                    log: "",
                    isShowingEmptyState: true
                )
            }
            return .init(
                title: displayedTitleForTesting,
                summary: displayedSummaryForTesting,
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

        var expectedRenderSnapshotForTesting: RenderSnapshotForTesting {
            switch uiState.selection {
            case .workspaceGroup:
                .init(
                    title: nil,
                    summary: nil,
                    log: "",
                    isShowingEmptyState: false
                )
            case .workspace:
                .init(
                    title: nil,
                    summary: nil,
                    log: "",
                    isShowingEmptyState: false
                )
            case .chat:
                .init(
                    title: nil,
                    summary: nil,
                    log: displayedLogForTesting,
                    isShowingEmptyState: false
                )
            case nil:
                .init(
                    title: nil,
                    summary: nil,
                    log: "",
                    isShowingEmptyState: true
                )
            }
        }

        var expectedRenderedStateForTesting: RenderedStateForTesting {
            .init(
                snapshot: expectedRenderSnapshotForTesting,
                selection: expectedDisplayedSelectionForTesting
            )
        }

        private var displayedSelectionForTesting: DisplayedSelectionForTesting? {
            switch displayedSelection {
            case .workspaceGroup(let id):
                .workspaceGroup(id.rawValue)
            case .workspace(let id):
                .workspace(id.rawValue)
            case .chat(let id):
                .chat(id.rawValue)
            case nil:
                nil
            }
        }

        private var expectedDisplayedSelectionForTesting: DisplayedSelectionForTesting? {
            switch uiState.selection {
            case .workspaceGroup(let id):
                .workspaceGroup(id.rawValue)
            case .workspace(let id):
                .workspace(id.rawValue)
            case .chat(let id):
                .chat(id.rawValue)
            case nil:
                nil
            }
        }

        func scrollLogToTopForTesting() {
            logScrollView.scrollToTopForTesting()
        }

        func scrollLogToOffsetForTesting(_ y: CGFloat) {
            logScrollView.scrollToOffsetForTesting(y)
        }

        var logVerticalScrollOffsetForTesting: CGFloat {
            logScrollView.verticalScrollOffsetForTesting
        }

        var logViewportHeightForTesting: CGFloat {
            logScrollView.viewportHeightForTesting
        }

        var logMinimumVerticalScrollOffsetForTesting: CGFloat {
            logScrollView.minimumVerticalScrollOffsetForTesting
        }

        var logMaximumVerticalScrollOffsetForTesting: CGFloat {
            logScrollView.maximumVerticalScrollOffsetForTesting
        }

        var logTextContentFrameForTesting: NSRect {
            logScrollView.textContentFrameForTesting
        }

        var logDocumentViewFrameForTesting: NSRect {
            logScrollView.documentViewFrameForTesting
        }

        var logContentInsetsForTesting: NSEdgeInsets {
            logScrollView.contentInsetsForTesting
        }

        var logAutomaticallyAdjustsContentInsetsForTesting: Bool {
            logScrollView.automaticallyAdjustsContentInsetsForTesting
        }

        var logTextContainerSizeForTesting: NSSize {
            logScrollView.textContainerSizeForTesting
        }

        var logTextContainerInsetForTesting: NSSize {
            logScrollView.textContainerInsetForTesting
        }

        var logVisibleFragmentViewCountForTesting: Int {
            logScrollView.visibleFragmentViewCountForTesting
        }

        var logVisibleFragmentViewCountWithoutForcingLayoutForTesting: Int {
            logScrollView.visibleFragmentViewCountWithoutForcingLayoutForTesting
        }

        var logVisibleFragmentBoundsForTesting: NSRect {
            logScrollView.visibleFragmentBoundsForTesting
        }

        var logVisibleFragmentBoundsWithoutForcingLayoutForTesting: NSRect {
            logScrollView.visibleFragmentBoundsWithoutForcingLayoutForTesting
        }

        var logStaleFragmentViewCountForTesting: Int {
            logScrollView.staleFragmentViewCountForTesting
        }

        var logProgrammaticScrollCountForTesting: Int {
            logScrollView.programmaticScrollCountForTesting
        }

        var logAccessibilityValueForTesting: String? {
            logScrollView.accessibilityValueForTesting
        }

        var logSelectedTextForTesting: String? {
            logScrollView.selectedTextForTesting
        }

        var logSelectedRangeForTesting: NSRange {
            logScrollView.selectedRangeForTesting
        }

        var logFindStringForTesting: String {
            logScrollView.findStringForTesting
        }

        func selectAllLogForTesting() {
            logScrollView.selectAllForTesting()
        }

        func setSelectedLogRangeForTesting(_ range: NSRange) {
            logScrollView.setSelectedLogRangeForTesting(range)
        }

        var logDocumentViewExportsUserInterfaceValidationForTesting: Bool {
            logScrollView.documentViewExportsUserInterfaceValidationForTesting
        }

        func validateLogDocumentUserInterfaceItemForTesting(_ item: NSValidatedUserInterfaceItem) -> Bool {
            logScrollView.validateDocumentUserInterfaceItemForTesting(item)
        }

        func clearLogFinderSelectedRangesForTesting() {
            logScrollView.clearFinderSelectedRangesForTesting()
        }

        func setLogFinderSelectedRangeForTesting(_ range: NSRange) {
            logScrollView.setFinderSelectedRangeForTesting(range)
        }

        func simulateLogFinderEmptySelectedRangesForTesting() {
            logScrollView.simulateFinderEmptySelectedRangesForTesting()
        }

        func performLogKeyboardCommandForTesting(_ selector: Selector) {
            logScrollView.performKeyboardCommandForTesting(selector)
        }

        @discardableResult
        func renderLogForTesting(text: String, allowIncrementalUpdate: Bool) -> Bool {
            logScrollView.renderForTesting(text: text, allowIncrementalUpdate: allowIncrementalUpdate)
        }

        @discardableResult
        func renderLogDocumentForTesting(
            _ sourceDocument: ReviewMonitorLog.Document,
            target: DisplayedSelectionForTesting? = nil,
            restoring restorationTarget: ReviewMonitorLogScrollView.ScrollRestorationTarget? = nil,
            allowIncrementalUpdate: Bool
        ) -> Bool {
            let resolvedTarget: LogRenderTarget
            switch target ?? displayedSelectionForTesting {
            case .chat(let id):
                resolvedTarget = .chat(CodexThreadID(rawValue: id))
            case .workspaceGroup, .workspace, nil:
                return false
            }
            let resolvedRestorationTarget =
                restorationTarget
                ?? {
                    guard hasAppliedBoundLog == false else {
                        return logScrollView.currentScrollRestorationTarget
                    }
                    switch resolvedTarget {
                    case .chat(let id):
                        return logScrollTargetsByChatID[id] ?? .bottom
                    }
                }()
            return renderBoundLog(
                sourceDocument: sourceDocument,
                target: resolvedTarget,
                restorationTarget: resolvedRestorationTarget,
                allowIncrementalUpdate: allowIncrementalUpdate
            )
        }

        func bindLogRenderTargetForTesting(_ target: DisplayedSelectionForTesting) {
            switch target {
            case .chat(let id):
                let chatID = CodexThreadID(rawValue: id)
                if boundChatID != chatID {
                    let isSwitchingRenderedChat = boundChatID != nil
                    cacheBoundLogScrollTarget()
                    if isSwitchingRenderedChat {
                        logScrollView.resetFindStateForContentReuse()
                    }
                    selectedChatLogTask?.cancel()
                    selectedChatLogTask = nil
                    resetLogRenderer()
                    boundChatID = chatID
                }
                hidePlaceholder()
                logScrollView.isHidden = false
                displayedSelection = .chat(chatID)
            case .workspaceGroup, .workspace:
                break
            }
        }

        func copyLogSelectionForTesting() {
            logScrollView.copySelectionForTesting()
        }

        func beginLogLiveResizeForTesting() {
            logScrollView.beginLiveResizeForTesting()
        }

        func endLogLiveResizeForTesting() {
            logScrollView.endLiveResizeForTesting()
        }

        func scrollLogToBottomForTesting() {
            logScrollView.scrollToBottomForTesting()
        }

        var isLogPinnedToBottomForTesting: Bool {
            logScrollView.isPinnedToBottomForTesting
        }

        func setLogScrollerStyleForTesting(_ style: NSScroller.Style) {
            logScrollView.setScrollerStyleForTesting(style)
        }

        func setLogOverlayScrollersShownForTesting(_ isShown: Bool?) {
            logScrollView.setOverlayScrollersShownForTesting(isShown)
        }

        func setLogOverlayScrollerBridgeModeForTesting(
            _ mode: ReviewMonitorLogScrollView.OverlayScrollerBridgeModeForTesting
        ) {
            logScrollView.setOverlayScrollerBridgeModeForTesting(mode)
        }
    }
#endif
