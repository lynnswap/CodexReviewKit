import AppKit
import CodexKit

@MainActor
package final class ReviewMonitorCodexChatLogTarget {
    private static let incrementalLogUpdateCoalescingDelay: Duration = .milliseconds(10)

    private enum LogRenderTarget: Equatable {
        case chat(CodexThreadID)
    }

    package var view: NSView {
        logScrollView
    }

    private let logScrollView = ReviewMonitorLogScrollView()
    private var logRenderer = ReviewMonitorLogRenderer()
    private var selectedChatObservation: CodexChatObservation?
    private var selectedChatLogTask: Task<Void, Never>?
    private var boundModelContext: CodexModelContext?
    private var boundChatID: CodexThreadID?
    private var boundChat: CodexChat?
    private var logScrollTargetsByChatID: [CodexThreadID: ReviewMonitorLogScrollView.ScrollRestorationTarget] = [:]
    private var logRenderTask: Task<Void, Never>?
    private var logRenderGeneration: UInt64 = 0
    private var appliedLogRenderGeneration: UInt64 = 0
    private var hasAppliedBoundLog = false
    private var logProjection = ReviewMonitorCodexChatLogSourceProjection()
    private var pendingLogSourceChange: PendingLogSourceChange?
    private var pendingLogSourceChangeTask: Task<Void, Never>?

    private struct PendingLogSourceChange {
        var change: ReviewMonitorLogSourceChange
        var target: LogRenderTarget
        var initialRestorationTarget: ReviewMonitorLogScrollView.ScrollRestorationTarget
    }

    package init() {}

    isolated deinit {
        selectedChatObservation?.cancel()
        selectedChatLogTask?.cancel()
        pendingLogSourceChangeTask?.cancel()
        logRenderTask?.cancel()
    }

    package func bind(
        chat: CodexChat,
        modelContext: CodexModelContext
    ) {
        let selectedChatID = chat.id
        guard boundChatID != selectedChatID || boundModelContext !== modelContext else {
            return
        }
        let isSwitchingRenderedChat = boundChatID != nil && boundChatID != selectedChatID
        cacheBoundLogScrollTarget()
        if isSwitchingRenderedChat {
            logScrollView.resetFindStateForContentReuse()
        }
        cancelSelectedChatObservation()
        cancelPendingLogSourceChange()
        selectedChatLogTask?.cancel()
        selectedChatLogTask = nil
        resetLogRenderer()
        logProjection.reset()
        boundChatID = selectedChatID
        boundModelContext = modelContext
        boundChat = chat
        startSelectedCodexChatObservation(
            chat,
            modelContext: modelContext,
            target: .chat(selectedChatID),
            initialRestorationTarget: restorationTarget(chatID: selectedChatID)
        )
    }

    @discardableResult
    package func clear() -> Bool {
        cacheBoundLogScrollTarget()
        selectedChatLogTask?.cancel()
        selectedChatLogTask = nil
        cancelSelectedChatObservation()
        cancelPendingLogSourceChange()
        boundChatID = nil
        boundModelContext = nil
        boundChat = nil
        logProjection.reset()
        resetLogRenderer()
        logScrollView.resetFindStateForContentReuse()
        return logScrollView.clear()
    }

    @discardableResult
    package func performDisplayedTextFinderAction(_ sender: Any?) -> Bool {
        logScrollView.performDisplayedTextFinderAction(sender)
    }

    package func validateDisplayedTextFinderAction(_ item: NSValidatedUserInterfaceItem) -> Bool {
        logScrollView.validateDisplayedTextFinderAction(item)
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

    private func startSelectedCodexChatObservation(
        _ chat: CodexChat,
        modelContext: CodexModelContext,
        target: LogRenderTarget,
        initialRestorationTarget: ReviewMonitorLogScrollView.ScrollRestorationTarget
    ) {
        selectedChatLogTask?.cancel()
        selectedChatLogTask = Task { @MainActor [weak self, weak chat, weak modelContext] in
            guard let chat, let modelContext else {
                return
            }
            do {
                let observation = try await modelContext.observe(chat)
                guard Task.isCancelled == false,
                    let self,
                    self.boundChat === chat,
                    self.isCurrentLogRenderTarget(target)
                else {
                    observation.cancel()
                    return
                }
                self.selectedChatObservation = observation
                for await change in observation.changes {
                    guard Task.isCancelled == false,
                        self.boundChat === chat,
                        self.isCurrentLogRenderTarget(target)
                    else {
                        return
                    }
                    self.publishSelectedCodexChatLogChange(
                        self.logProjection.apply(
                            change,
                            chatCreatedAt: chat.createdAt,
                            chatUpdatedAt: chat.updatedAt
                        ),
                        target: target,
                        initialRestorationTarget: initialRestorationTarget
                    )
                }
            } catch is CancellationError {
            } catch {
            }
        }
    }

    private func publishSelectedCodexChatLogChange(
        _ change: ReviewMonitorLogSourceChange?,
        target: LogRenderTarget,
        initialRestorationTarget: ReviewMonitorLogScrollView.ScrollRestorationTarget
    ) {
        guard let change else {
            return
        }
        guard change.allowsIncrementalRender else {
            cancelPendingLogSourceChange()
            applySelectedCodexChatLogChange(
                change,
                target: target,
                initialRestorationTarget: initialRestorationTarget
            )
            return
        }
        pendingLogSourceChange = .init(
            change: change,
            target: target,
            initialRestorationTarget: initialRestorationTarget
        )
        guard pendingLogSourceChangeTask == nil else {
            return
        }
        pendingLogSourceChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.incrementalLogUpdateCoalescingDelay)
            guard let self, Task.isCancelled == false else {
                return
            }
            let pending = self.pendingLogSourceChange
            self.pendingLogSourceChange = nil
            self.pendingLogSourceChangeTask = nil
            guard let pending else {
                return
            }
            self.applySelectedCodexChatLogChange(
                pending.change,
                target: pending.target,
                initialRestorationTarget: pending.initialRestorationTarget
            )
        }
    }

    private func applySelectedCodexChatLogChange(
        _ change: ReviewMonitorLogSourceChange,
        target: LogRenderTarget,
        initialRestorationTarget: ReviewMonitorLogScrollView.ScrollRestorationTarget
    ) {
        let hasAppliedInitialDocument = hasAppliedBoundLog
        applySelectedCodexChatLogChange(
            change,
            target: target,
            restorationTarget: hasAppliedInitialDocument
                ? logScrollView.currentScrollRestorationTarget
                : initialRestorationTarget,
            allowIncrementalUpdate: hasAppliedInitialDocument && change.allowsIncrementalRender
        )
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

    private func cancelSelectedChatObservation() {
        selectedChatObservation?.cancel()
        selectedChatObservation = nil
    }

    private func cancelPendingLogSourceChange() {
        pendingLogSourceChangeTask?.cancel()
        pendingLogSourceChangeTask = nil
        pendingLogSourceChange = nil
    }

    private func restorationTarget(
        chatID: CodexThreadID
    ) -> ReviewMonitorLogScrollView.ScrollRestorationTarget {
        logScrollTargetsByChatID[chatID] ?? .bottom
    }
}

#if DEBUG
    @MainActor
    package extension ReviewMonitorCodexChatLogTarget {
        enum OverlayScrollerBridgeModeForTesting {
            case live
            case missingScrollerImpPair
            case missingOverlayScrollersShown
            case missingHideMethods
        }

        var selectedChatLogTaskForTesting: Task<Void, Never>? {
            selectedChatLogTask
        }

        var logRenderIsIdleForTesting: Bool {
            appliedLogRenderGeneration == logRenderGeneration
        }

        var displayedTextForTesting: String {
            logScrollView.displayedTextForTesting
        }

        var appendCount: Int {
            logScrollView.appendCount
        }

        var replaceCount: Int {
            logScrollView.replaceCount
        }

        var reloadCount: Int {
            logScrollView.reloadCount
        }

        var autoFollowCount: Int {
            logScrollView.autoFollowCount
        }

        var wordGlowCountForTesting: Int {
            logScrollView.wordGlowCountForTesting
        }

        var wordFadeRenderingAttributeRangeCountForTesting: Int {
            logScrollView.wordFadeRenderingAttributeRangeCountForTesting
        }

        var wordFadeStorageUsesOpaqueTextColorForTesting: Bool {
            logScrollView.wordFadeStorageUsesOpaqueTextColorForTesting
        }

        var wordFadeDisplayInvalidationCountForTesting: Int {
            logScrollView.wordFadeDisplayInvalidationCountForTesting
        }

        var commandOutputPanelCountForTesting: Int {
            logScrollView.commandOutputPanelCountForTesting
        }

        var terminalDecorationRectCountForTesting: Int {
            logScrollView.terminalDecorationRectCountForTesting
        }

        var expandedCommandOutputPanelCountForTesting: Int {
            logScrollView.expandedCommandOutputPanelCountForTesting
        }

        var commandOutputPanelUsesTextKit2ForTesting: Bool {
            logScrollView.commandOutputPanelUsesTextKit2ForTesting
        }

        var commandOutputPanelUsesInlineAttachmentForTesting: Bool {
            logScrollView.commandOutputPanelUsesInlineAttachmentForTesting
        }

        var commandOutputPanelUsesButtonAttachmentForTesting: Bool {
            logScrollView.commandOutputPanelUsesButtonAttachmentForTesting
        }

        var collapsedCommandOutputPanelAttachmentLineHeightForTesting: CGFloat? {
            logScrollView.collapsedCommandOutputPanelAttachmentLineHeightForTesting
        }

        var collapsedCommandOutputPanelAttachmentPayloadIsEmptyForTesting: Bool {
            logScrollView.collapsedCommandOutputPanelAttachmentPayloadIsEmptyForTesting
        }

        var commandOutputPanelUsesSystemMaterialBackgroundForTesting: Bool {
            logScrollView.commandOutputPanelUsesSystemMaterialBackgroundForTesting
        }

        var commandOutputPanelVisibleLineCapacityForTesting: Int {
            logScrollView.commandOutputPanelVisibleLineCapacityForTesting
        }

        var commandOutputPanelResultTextForTesting: String? {
            logScrollView.commandOutputPanelResultTextForTesting
        }

        var commandOutputPanelTerminalTextForTesting: String? {
            logScrollView.commandOutputPanelTerminalTextForTesting
        }

        func commandOutputPanelTerminalTextForTesting(blockID: ReviewMonitorLog.BlockID) -> String? {
            logScrollView.commandOutputPanelTerminalTextForTesting(blockID: blockID)
        }

        var commandOutputPanelCommandLineTextForTesting: String? {
            logScrollView.commandOutputPanelCommandLineTextForTesting
        }

        var commandOutputPanelOutputScrollTextForTesting: String? {
            logScrollView.commandOutputPanelOutputScrollTextForTesting
        }

        var commandOutputPanelOutputScrollIsScrollableForTesting: Bool {
            logScrollView.commandOutputPanelOutputScrollIsScrollableForTesting
        }

        var commandOutputPanelOutputScrollUsesHorizontalScrollingForTesting: Bool {
            logScrollView.commandOutputPanelOutputScrollUsesHorizontalScrollingForTesting
        }

        var commandOutputPanelOutputScrollVerticalOffsetForTesting: CGFloat? {
            logScrollView.commandOutputPanelOutputScrollVerticalOffsetForTesting
        }

        var commandOutputPanelOutputScrollMaximumVerticalOffsetForTesting: CGFloat? {
            logScrollView.commandOutputPanelOutputScrollMaximumVerticalOffsetForTesting
        }

        func scrollCommandOutputPanelOutputForTesting(deltaY: CGFloat) -> Bool {
            logScrollView.scrollCommandOutputPanelOutputForTesting(deltaY: deltaY)
        }

        var commandOutputPanelOutputHitTestTargetsTextViewForTesting: Bool {
            logScrollView.commandOutputPanelOutputHitTestTargetsTextViewForTesting
        }

        func finderRectsForTesting(_ range: NSRange) -> [NSRect] {
            logScrollView.finderRectsForTesting(range)
        }

        var firstCommandOutputPanelRectForTesting: NSRect? {
            logScrollView.firstCommandOutputPanelRectForTesting
        }

        var commandOutputPanelToggleSymbolNameForTesting: String? {
            logScrollView.commandOutputPanelToggleSymbolNameForTesting
        }

        var commandOutputPanelLeadingAlignmentDeltaForTesting: CGFloat? {
            logScrollView.commandOutputPanelLeadingAlignmentDeltaForTesting
        }

        var commandOutputPanelChevronSizeDeltaForTesting: CGFloat? {
            logScrollView.commandOutputPanelChevronSizeDeltaForTesting
        }

        var commandOutputPanelChevronVerticalAlignmentDeltaForTesting: CGFloat? {
            logScrollView.commandOutputPanelChevronVerticalAlignmentDeltaForTesting
        }

        func hitTestTargetsDocumentViewForFirstLogOccurrenceForTesting(_ text: String) -> Bool {
            logScrollView.hitTestTargetsDocumentViewForFirstLogOccurrenceForTesting(text)
        }

        func toggleFirstCommandOutputPanelForTesting() {
            logScrollView.toggleFirstCommandOutputPanelForTesting()
        }

        @discardableResult
        func clickFirstCommandOutputPanelHeaderForTesting() -> Bool {
            logScrollView.clickFirstCommandOutputPanelHeaderForTesting()
        }

        @discardableResult
        func clickCommandOutputPanelHeaderForTesting(blockID: ReviewMonitorLog.BlockID) -> Bool {
            logScrollView.clickCommandOutputPanelHeaderForTesting(blockID: blockID)
        }

        func completeWordGlowAnimationsForTesting() {
            logScrollView.completeWordGlowAnimationsForTesting()
        }

        func advanceWordGlowAnimationsAfterInitialDelayForTesting(_ delay: TimeInterval) {
            logScrollView.advanceWordGlowAnimationsAfterInitialDelayForTesting(delay)
        }

        func setReduceMotionForTesting(_ reduceMotion: Bool?) {
            logScrollView.setReduceMotionForTesting(reduceMotion)
        }

        var usesCustomTextKit2SurfaceForTesting: Bool {
            logScrollView.usesCustomTextKit2SurfaceForTesting
        }

        var usesTextViewForTesting: Bool {
            logScrollView.usesTextViewForTesting
        }

        var usesLogLayoutManagerForTesting: Bool {
            logScrollView.usesLogLayoutManagerForTesting
        }

        var isEditableForTesting: Bool {
            logScrollView.isEditableForTesting
        }

        var isSelectableForTesting: Bool {
            logScrollView.isSelectableForTesting
        }

        var usesFindBarForTesting: Bool {
            logScrollView.usesFindBarForTesting
        }

        var isIncrementalSearchingEnabledForTesting: Bool {
            logScrollView.isIncrementalSearchingEnabledForTesting
        }

        var isFindBarVisibleForTesting: Bool {
            logScrollView.isFindBarVisibleForTesting
        }

        var textFinderIdentifierForTesting: ObjectIdentifier {
            logScrollView.textFinderIdentifierForTesting
        }

        var findVisibleCharacterRangesForTesting: [NSRange] {
            logScrollView.findVisibleCharacterRangesForTesting
        }

        var findStringLengthForTesting: Int {
            logScrollView.findStringLengthForTesting
        }

        var findStringForTesting: String {
            logScrollView.findStringForTesting
        }

        var findClientUsesSnapshotForTesting: Bool {
            logScrollView.findClientUsesSnapshotForTesting
        }

        var findClientSnapshotMapsToDocumentForTesting: Bool {
            logScrollView.findClientSnapshotMapsToDocumentForTesting
        }

        var findClientFirstSelectedRangeForTesting: NSRange {
            logScrollView.findClientFirstSelectedRangeForTesting
        }

        var hasActiveFindQueryForTesting: Bool {
            logScrollView.hasActiveFindQueryForTesting
        }

        var visibleFindBarSearchStringForTesting: String? {
            logScrollView.visibleFindBarSearchStringForTesting
        }

        @discardableResult
        func setVisibleFindBarSearchStringForTesting(_ string: String) -> Bool {
            logScrollView.setVisibleFindBarSearchStringForTesting(string)
        }

        var findIndicatorInvalidationCountForTesting: Int {
            logScrollView.findIndicatorInvalidationCountForTesting
        }

        var findIncrementalMatchRangeCountForTesting: Int {
            logScrollView.findIncrementalMatchRangeCountForTesting
        }

        var findBarContainerContentViewIsTextContentViewForTesting: Bool {
            logScrollView.findBarContainerContentViewIsTextContentViewForTesting
        }

        var findIncrementalSearchUsesSystemHighlightingForTesting: Bool {
            logScrollView.findIncrementalSearchUsesSystemHighlightingForTesting
        }

        var hitTestTargetsDocumentViewForTesting: Bool {
            logScrollView.hitTestTargetsDocumentViewForTesting
        }

        var writingToolsDisabledForTesting: Bool {
            logScrollView.writingToolsDisabledForTesting
        }

        var overlayScrollerHideRequestCountForTesting: Int {
            logScrollView.overlayScrollerHideRequestCountForTesting
        }

        var frame: NSRect {
            logScrollView.frame
        }

        var verticalScrollOffsetForTesting: CGFloat {
            logScrollView.verticalScrollOffsetForTesting
        }

        var viewportHeightForTesting: CGFloat {
            logScrollView.viewportHeightForTesting
        }

        var minimumVerticalScrollOffsetForTesting: CGFloat {
            logScrollView.minimumVerticalScrollOffsetForTesting
        }

        var maximumVerticalScrollOffsetForTesting: CGFloat {
            logScrollView.maximumVerticalScrollOffsetForTesting
        }

        var textContentFrameForTesting: NSRect {
            logScrollView.textContentFrameForTesting
        }

        var documentViewFrameForTesting: NSRect {
            logScrollView.documentViewFrameForTesting
        }

        var contentInsetsForTesting: NSEdgeInsets {
            logScrollView.contentInsetsForTesting
        }

        var automaticallyAdjustsContentInsetsForTesting: Bool {
            logScrollView.automaticallyAdjustsContentInsetsForTesting
        }

        var textContainerSizeForTesting: NSSize {
            logScrollView.textContainerSizeForTesting
        }

        var textContainerInsetForTesting: NSSize {
            logScrollView.textContainerInsetForTesting
        }

        var visibleFragmentViewCountForTesting: Int {
            logScrollView.visibleFragmentViewCountForTesting
        }

        var visibleFragmentViewCountWithoutForcingLayoutForTesting: Int {
            logScrollView.visibleFragmentViewCountWithoutForcingLayoutForTesting
        }

        var visibleFragmentBoundsForTesting: NSRect {
            logScrollView.visibleFragmentBoundsForTesting
        }

        var visibleFragmentBoundsWithoutForcingLayoutForTesting: NSRect {
            logScrollView.visibleFragmentBoundsWithoutForcingLayoutForTesting
        }

        var staleFragmentViewCountForTesting: Int {
            logScrollView.staleFragmentViewCountForTesting
        }

        var programmaticScrollCountForTesting: Int {
            logScrollView.programmaticScrollCountForTesting
        }

        var accessibilityValueForTesting: String? {
            logScrollView.accessibilityValueForTesting
        }

        var selectedTextForTesting: String? {
            logScrollView.selectedTextForTesting
        }

        var selectedRangeForTesting: NSRange {
            logScrollView.selectedRangeForTesting
        }

        func scrollToTopForTesting() {
            logScrollView.scrollToTopForTesting()
        }

        func scrollToOffsetForTesting(_ y: CGFloat) {
            logScrollView.scrollToOffsetForTesting(y)
        }

        func scrollToBottomForTesting() {
            logScrollView.scrollToBottomForTesting()
        }

        func selectAllForTesting() {
            logScrollView.selectAllForTesting()
        }

        func setSelectedLogRangeForTesting(_ range: NSRange) {
            logScrollView.setSelectedLogRangeForTesting(range)
        }

        var documentViewExportsUserInterfaceValidationForTesting: Bool {
            logScrollView.documentViewExportsUserInterfaceValidationForTesting
        }

        func validateDocumentUserInterfaceItemForTesting(_ item: NSValidatedUserInterfaceItem) -> Bool {
            logScrollView.validateDocumentUserInterfaceItemForTesting(item)
        }

        func clearFinderSelectedRangesForTesting() {
            logScrollView.clearFinderSelectedRangesForTesting()
        }

        func setFinderSelectedRangeForTesting(_ range: NSRange) {
            logScrollView.setFinderSelectedRangeForTesting(range)
        }

        func simulateFinderEmptySelectedRangesForTesting() {
            logScrollView.simulateFinderEmptySelectedRangesForTesting()
        }

        func performKeyboardCommandForTesting(_ selector: Selector) {
            logScrollView.performKeyboardCommandForTesting(selector)
        }

        @discardableResult
        func renderForTesting(text: String, allowIncrementalUpdate: Bool) -> Bool {
            logScrollView.renderForTesting(text: text, allowIncrementalUpdate: allowIncrementalUpdate)
        }

        func copySelectionForTesting() {
            logScrollView.copySelectionForTesting()
        }

        var isPinnedToBottomForTesting: Bool {
            logScrollView.isPinnedToBottomForTesting
        }

        func setScrollerStyleForTesting(_ style: NSScroller.Style) {
            logScrollView.setScrollerStyleForTesting(style)
        }

        func setOverlayScrollersShownForTesting(_ isShown: Bool?) {
            logScrollView.setOverlayScrollersShownForTesting(isShown)
        }

        func setOverlayScrollerBridgeModeForTesting(_ mode: OverlayScrollerBridgeModeForTesting) {
            let scrollViewMode: ReviewMonitorLogScrollView.OverlayScrollerBridgeModeForTesting
            switch mode {
            case .live:
                scrollViewMode = .live
            case .missingScrollerImpPair:
                scrollViewMode = .missingScrollerImpPair
            case .missingOverlayScrollersShown:
                scrollViewMode = .missingOverlayScrollersShown
            case .missingHideMethods:
                scrollViewMode = .missingHideMethods
            }
            logScrollView.setOverlayScrollerBridgeModeForTesting(scrollViewMode)
        }

        func beginLiveResizeForTesting() {
            logScrollView.beginLiveResizeForTesting()
        }

        func endLiveResizeForTesting() {
            logScrollView.endLiveResizeForTesting()
        }

        @discardableResult
        func renderLogDocumentForTesting(
            _ sourceDocument: ReviewMonitorLog.Document,
            chatID: CodexThreadID?,
            allowIncrementalUpdate: Bool
        ) -> Bool {
            let resolvedChatID: CodexThreadID
            if let chatID {
                resolvedChatID = chatID
            } else if let boundChatID {
                resolvedChatID = boundChatID
            } else {
                return false
            }
            let resolvedTarget = LogRenderTarget.chat(resolvedChatID)
            let resolvedRestorationTarget = hasAppliedBoundLog
                ? logScrollView.currentScrollRestorationTarget
                : restorationTarget(chatID: resolvedChatID)
            return renderBoundLog(
                sourceDocument: sourceDocument,
                target: resolvedTarget,
                restorationTarget: resolvedRestorationTarget,
                allowIncrementalUpdate: allowIncrementalUpdate
            )
        }

        func bindLogRenderTargetForTesting(_ chatID: CodexThreadID) {
            if boundChatID != chatID {
                let isSwitchingRenderedChat = boundChatID != nil
                cacheBoundLogScrollTarget()
                if isSwitchingRenderedChat {
                    logScrollView.resetFindStateForContentReuse()
                }
                selectedChatLogTask?.cancel()
                selectedChatLogTask = nil
                cancelSelectedChatObservation()
                cancelPendingLogSourceChange()
                resetLogRenderer()
                boundChatID = chatID
                boundModelContext = nil
                boundChat = nil
            }
            logScrollView.isHidden = false
        }
    }
#endif
