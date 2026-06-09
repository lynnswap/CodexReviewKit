import AppKit
import ObjectiveC.runtime
import CodexReview

@MainActor
final class ReviewMonitorLogScrollView: NSScrollView {
    private static let scrollerImpPairSelector = NSSelectorFromString("scrollerImpPair")
    private static let overlayScrollersShownSelector = NSSelectorFromString("overlayScrollersShown")
    private static let hideOverlayScrollersSelector = NSSelectorFromString("hideOverlayScrollers")
    private static let beginHideOverlayScrollersSelector = NSSelectorFromString("_beginHideOverlayScrollers")

    private typealias ObjectGetter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    private typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
    private typealias VoidMethod = @convention(c) (AnyObject, Selector) -> Void

    enum ScrollRestorationTarget: Equatable, Sendable {
        case top
        case offset(CGFloat)
        case bottom
    }

#if DEBUG
    enum OverlayScrollerBridgeModeForTesting {
        case live
        case missingScrollerImpPair
        case missingOverlayScrollersShown
        case missingHideMethods
    }
#endif

    private let logDocumentView = ReviewMonitorLogDocumentView()
    private var textFinder = NSTextFinder()
    private let textFinderClient = ReviewMonitorLogTextFinderClient()
    private let textFinderBarContainer = ReviewMonitorLogTextFinderBarContainer()
    private var findBarSearchFieldChangeObserver: NSObjectProtocol?
    private weak var observedFindBarSearchField: NSSearchField?
    private var displayedText = ""
    private var displayedUTF16Length = 0
    private var displayedRevision: UInt64?
    private var displayedPresentationSignature: Int?
    private var displayedFinderSupplementSignature: Int?
    private var sourceDocument: ReviewMonitorLogDocument?
    private var currentDisplayDocument: ReviewMonitorLogDocument?
    private var logProjection = ReviewMonitorLogProjection()
    private var liveResizeRestorationTarget: ScrollRestorationTarget?
    private var isFindQueryActive = false
    private var activeFindQueryString: String?

    private enum LogTextMutation: Equatable {
        case appendPreservingPrefix
        case structural
    }

    private enum FindIndicatorInvalidationReason {
        case clientStringChanged
        case viewportChanged
    }

#if DEBUG
    private(set) var appendCount = 0
    private(set) var replaceCount = 0
    private(set) var reloadCount = 0
    private(set) var autoFollowCount = 0
    private(set) var programmaticScrollCount = 0
    private(set) var findIndicatorInvalidationCount = 0
    private(set) var overlayScrollerHideRequestCount = 0
    private var overlayScrollersShownOverrideForTesting: Bool?
    private var overlayScrollerBridgeModeForTesting: OverlayScrollerBridgeModeForTesting = .live
#endif

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        automaticallyAdjustsContentInsets = true

        documentView = logDocumentView
        logDocumentView.onLayoutInvalidated = { [weak self] in
            self?.syncDocumentFrameToTextLayout()
        }
        logDocumentView.onUserSelectionChanged = { [weak self] in
            self?.handleUserSelectionChanged()
        }
        logDocumentView.onCommandOutputPanelToggle = { [weak self] blockID in
            self?.toggleCommandOutputPanel(blockID)
        }
        logDocumentView.setAccessibilityIdentifier("review-monitor.activity-log")

        textFinderClient.documentView = logDocumentView
        textFinderClient.onSelectedRangeChangedByFinder = { [weak self] range in
            self?.handleFinderSelectedRangeChanged(range)
        }
        textFinderBarContainer.scrollView = self
        textFinderBarContainer.finderContentView = logDocumentView.finderContentView
        textFinderBarContainer.onFindBarVisibilityChanged = { [weak self] isVisible in
            guard isVisible == false else {
                return
            }
            self?.resetDeferredFindStateAfterFindBarHidden()
        }
        configureTextFinder()

        invalidateDocumentLayout()
    }

    isolated deinit {
        if let findBarSearchFieldChangeObserver {
            NotificationCenter.default.removeObserver(findBarSearchFieldChangeObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            endFindSession()
            stopObservingFindBarSearchField()
            textFinder.client = nil
            textFinder.findBarContainer = nil
        } else if textFinder.client == nil {
            configureTextFinder()
        }
    }

    func resetFindStateForContentReuse() {
        endFindSession()
        logDocumentView.resetCommandOutputPanelState()
        displayedFinderSupplementSignature = nil
        sourceDocument = nil
    }

    override func tile() {
        let shouldPreserveBottom = shouldPreserveBottomForLayout()
        super.tile()
        invalidateDocumentLayout()
        if shouldPreserveBottom, hasScrollableVerticalRange() {
            scrollToBottom(countAsAutoFollow: false, hideOverlayScroller: false)
        }
    }

    override func layout() {
        super.layout()
        invalidateDocumentLayout()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        liveResizeRestorationTarget = currentScrollRestorationTarget
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        invalidateDocumentLayout()
        if let liveResizeRestorationTarget {
            restoreScrollPosition(liveResizeRestorationTarget, countAsAutoFollow: false)
        }
        self.liveResizeRestorationTarget = nil
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        logDocumentView.layoutTextViewport()
        invalidateFindIndicator(reason: .viewportChanged)
    }

    @discardableResult
    func clear() -> Bool {
        logProjection = ReviewMonitorLogProjection()
        displayedRevision = nil
        displayedPresentationSignature = nil
        displayedFinderSupplementSignature = nil
        sourceDocument = nil
        currentDisplayDocument = nil
        logDocumentView.resetCommandOutputPanelState()
        return applyReload(
            "",
            document: .init(),
            restoring: .top,
            countBottomRestoreAsAutoFollow: false
        )
    }

    @discardableResult
    func render(
        entries: [ReviewLogEntry],
        restoring restorationTarget: ScrollRestorationTarget,
        allowIncrementalUpdate: Bool
    ) -> Bool {
        let document = logProjection.render(entries: entries)
        return render(
            document: document,
            restoring: restorationTarget,
            allowIncrementalUpdate: allowIncrementalUpdate
        )
    }

    @discardableResult
    func render(
        document: ReviewMonitorLogDocument,
        restoring restorationTarget: ScrollRestorationTarget,
        allowIncrementalUpdate: Bool
    ) -> Bool {
        render(
            sourceDocument: document,
            displayDocument: displayDocument(for: document),
            restoring: restorationTarget,
            allowIncrementalUpdate: allowIncrementalUpdate
        )
    }

    @discardableResult
    func render(
        sourceDocument source: ReviewMonitorLogDocument,
        displayDocument display: ReviewMonitorLogDocument,
        restoring restorationTarget: ScrollRestorationTarget,
        allowIncrementalUpdate: Bool
    ) -> Bool {
        let display = displayDocument(for: source, rendererDisplay: display)
        sourceDocument = source
        logDocumentView.pruneCommandOutputPanelExpansionState(for: display.commandOutputPanels)
        if allowIncrementalUpdate, displayedRevision == display.revision {
            return false
        }

        let canApplyLastChange = displayedRevision.map { $0 &+ 1 == display.revision } == true
        if allowIncrementalUpdate,
           canApplyLastChange,
           case .append(let append) = display.lastChange,
           canApplyAppend(append, to: display) {
            let didRender = applyAppend(
                append,
                document: display,
                forceAutoFollow: restorationTarget == .bottom
            )
            displayedRevision = display.revision
            currentDisplayDocument = display
            return didRender
        }
        if allowIncrementalUpdate,
           canApplyLastChange,
           case .replace(let replacement) = display.lastChange,
           canApplyReplacement(replacement, to: display) {
            let didRender = applyReplacement(replacement, document: display)
            displayedRevision = display.revision
            currentDisplayDocument = display
            return didRender
        }
        if allowIncrementalUpdate,
           let suffix = appendedSuffix(for: display.text),
           canApplyFallbackAppend(suffix, to: display) {
            let suffixUTF16Length = (suffix as NSString).length
            let append = ReviewMonitorLogAppend(
                kind: .event,
                blockID: ReviewMonitorLogBlockID("fallback"),
                range: NSRange(
                    location: displayedUTF16Length,
                    length: suffixUTF16Length
                ),
                text: suffix,
                textUTF16Length: suffixUTF16Length,
                animationSpans: fallbackAppendAnimationSpans(
                    suffixUTF16Length: suffixUTF16Length,
                    in: display
                )
            )
            let didRender = applyAppend(
                append,
                document: display,
                forceAutoFollow: restorationTarget == .bottom
            )
            displayedRevision = display.revision
            currentDisplayDocument = display
            return didRender
        }
        let didRender = applyReload(
            display.text,
            document: display,
            restoring: restorationTarget,
            countBottomRestoreAsAutoFollow: false
        )
        displayedRevision = display.revision
        currentDisplayDocument = display
        return didRender
    }

    private func toggleCommandOutputPanel(_ blockID: ReviewMonitorLogBlockID) {
        let restorationTarget = currentScrollRestorationTarget
        guard let sourceDocument
        else {
            return
        }

        let previousDisplay = displayDocument(for: sourceDocument)
        guard displayedText == previousDisplay.text,
              let previousPanel = previousDisplay.commandOutputPanels.first(where: { $0.blockID == blockID }),
              logDocumentView.toggleCommandOutputPanelExpansionState(blockID)
        else {
            assertionFailure("Command output display state is not synchronized.")
            return
        }

        let display = displayDocument(for: sourceDocument)
        guard let nextPanel = display.commandOutputPanels.first(where: { $0.blockID == blockID }) else {
            assertionFailure("Toggled command output panel disappeared from the display document.")
            return
        }

        let replacementText = (display.text as NSString).substring(with: nextPanel.range)
        let replacement = ReviewMonitorLogReplacement(
            kind: .commandOutput,
            blockID: blockID,
            range: previousPanel.range,
            text: replacementText,
            textUTF16Length: nextPanel.range.length
        )
        guard canApplyReplacement(replacement, to: display) else {
            assertionFailure("Command output panel replacement cannot be applied incrementally.")
            return
        }

        applyReplacement(replacement, document: display)
        currentDisplayDocument = display
        displayedRevision = display.revision
        invalidateDocumentLayout()
        restoreScrollPosition(restorationTarget, countAsAutoFollow: false)
        invalidateFindIndicator(reason: .viewportChanged)
    }

    private func displayDocument(for document: ReviewMonitorLogDocument) -> ReviewMonitorLogDocument {
        displayDocument(for: document, rendererDisplay: nil)
    }

    private func displayDocument(
        for document: ReviewMonitorLogDocument,
        rendererDisplay: ReviewMonitorLogDocument?
    ) -> ReviewMonitorLogDocument {
        let expandedBlockIDs = logDocumentView.expandedCommandOutputBlockIDsForDisplayDocument
        guard expandedBlockIDs.isEmpty == false else {
            return rendererDisplay ?? ReviewMonitorCommandOutputDisplayDocument.make(
                from: document,
                expandedBlockIDs: [],
                previousDisplay: currentDisplayDocument
            )
        }
        return ReviewMonitorCommandOutputDisplayDocument.make(
            from: document,
            expandedBlockIDs: expandedBlockIDs,
            previousDisplay: currentDisplayDocument
        )
    }

    private func canApplyAppend(_ append: ReviewMonitorLogAppend, to document: ReviewMonitorLogDocument) -> Bool {
        guard append.text.isEmpty == false else {
            return false
        }
        let appendEnd = displayedUTF16Length + append.textUTF16Length
        return append.textUTF16Length > 0 &&
            append.range.location >= displayedUTF16Length &&
            NSMaxRange(append.range) <= appendEnd &&
            document.textUTF16Length == displayedUTF16Length + append.textUTF16Length
    }

    private func canApplyReplacement(
        _ replacement: ReviewMonitorLogReplacement,
        to document: ReviewMonitorLogDocument
    ) -> Bool {
        replacement.textUTF16Length >= 0 &&
            replacement.range.location >= 0 &&
            NSMaxRange(replacement.range) <= displayedUTF16Length &&
        document.textUTF16Length == displayedUTF16Length - replacement.range.length + replacement.textUTF16Length
    }

    private func canApplyFallbackAppend(_ suffix: String, to document: ReviewMonitorLogDocument) -> Bool {
        guard let displayedPresentationSignature else {
            return false
        }
        guard document.textUTF16Length == displayedUTF16Length + (suffix as NSString).length else {
            return false
        }
        return displayedPresentationSignature == presentationSignature(
            forPrefixUTF16Length: displayedUTF16Length,
            in: document
        )
    }

    private func fallbackAppendAnimationSpans(
        suffixUTF16Length: Int,
        in document: ReviewMonitorLogDocument
    ) -> [ReviewMonitorLogAnimationSpan] {
        let suffixRange = NSRange(location: displayedUTF16Length, length: suffixUTF16Length)
        var spans: [ReviewMonitorLogAnimationSpan] = []
        for block in document.blocks {
            let intersection = NSIntersectionRange(block.range, suffixRange)
            guard intersection.length > 0 else {
                continue
            }
            spans.append(contentsOf: ReviewMonitorLogAppend.animationSpans(
                forKind: block.kind,
                absoluteRange: intersection,
                appendBaseLocation: displayedUTF16Length
            ))
        }
        return spans
    }

    @discardableResult
    private func applyAppend(
        _ append: ReviewMonitorLogAppend,
        document: ReviewMonitorLogDocument,
        forceAutoFollow: Bool
    ) -> Bool {
        guard append.text.isEmpty == false else {
            return false
        }

        let shouldAutoFollow = forceAutoFollow || isPinnedToBottom()
        let finderSupplementSignature = document.finderSupplementSignature
        let shouldRefreshFindSession = shouldRefreshFindSessionForFinderSupplementChange(
            to: finderSupplementSignature
        )
        let shouldClearFindSelection = prepareFindSessionForLogMutation(.appendPreservingPrefix)
        logDocumentView.appendText(append.text, animation: append)
        displayedText += append.text
        displayedUTF16Length += append.textUTF16Length
        logDocumentView.applyPresentation(document, appended: append)
        displayedPresentationSignature = presentationSignature(
            forPrefixUTF16Length: displayedUTF16Length,
            in: document
        )
        displayedFinderSupplementSignature = finderSupplementSignature
        finishLogMutationForFindSession(clearSelection: shouldClearFindSelection)
        invalidateDocumentLayout()
#if DEBUG
        appendCount += 1
#endif
        if shouldAutoFollow {
            scrollToBottom(countAsAutoFollow: true)
        }
        if shouldRefreshFindSession {
            refreshFindSessionAfterUserVisibleLogChange()
        } else {
            invalidateFindIndicator()
        }
        return true
    }

    @discardableResult
    private func applyReplacement(
        _ replacement: ReviewMonitorLogReplacement,
        document: ReviewMonitorLogDocument
    ) -> Bool {
        let shouldAutoFollow = isPinnedToBottom()
        let resultingTextUTF16Length = displayedUTF16Length - replacement.range.length + replacement.textUTF16Length
        let finderSupplementSignature = document.finderSupplementSignature
        let shouldRefreshFindSession = shouldRefreshFindSessionForFinderSupplementChange(
            to: finderSupplementSignature
        ) || shouldRefreshFindSessionForCommandOutputReplacement(replacement)
        let shouldClearFindSelection = prepareFindSessionForLogMutation(
            .structural,
            resultingTextIsEmpty: resultingTextUTF16Length == 0
        )
        logDocumentView.replaceText(in: replacement.range, with: replacement.text)
        replaceDisplayedText(in: replacement.range, with: replacement.text)
        displayedUTF16Length = resultingTextUTF16Length
        logDocumentView.applyPresentation(document, replacement: replacement)
        displayedPresentationSignature = presentationSignature(
            forPrefixUTF16Length: displayedUTF16Length,
            in: document
        )
        displayedFinderSupplementSignature = finderSupplementSignature
        finishLogMutationForFindSession(clearSelection: shouldClearFindSelection)
        invalidateDocumentLayout()
#if DEBUG
        replaceCount += 1
#endif
        if shouldAutoFollow {
            scrollToBottom(countAsAutoFollow: true)
        }
        if shouldRefreshFindSession {
            refreshFindSessionAfterUserVisibleLogChange()
        } else {
            invalidateFindIndicator()
        }
        return true
    }

    @discardableResult
    private func applyReload(
        _ text: String,
        document: ReviewMonitorLogDocument,
        restoring restorationTarget: ScrollRestorationTarget,
        countBottomRestoreAsAutoFollow: Bool
    ) -> Bool {
        let finderSupplementSignature = document.finderSupplementSignature
        if displayedText == text {
            let previousOrigin = contentView.bounds.origin
            let presentationSignature = presentationSignature(
                forPrefixUTF16Length: displayedUTF16Length,
                in: document
            )
            let presentationChanged = displayedPresentationSignature != presentationSignature
            let finderSupplementChanged = displayedFinderSupplementSignature != finderSupplementSignature
            let shouldRefreshFindSession = shouldRefreshFindSessionForFinderSupplementChange(
                to: finderSupplementSignature
            )
            if presentationChanged {
                logDocumentView.applyPresentation(document)
                invalidateDocumentLayout()
                restoreScrollPosition(restorationTarget, countAsAutoFollow: countBottomRestoreAsAutoFollow)
            } else if finderSupplementChanged {
                logDocumentView.updateFinderSupplement(document)
            }
            displayedPresentationSignature = presentationSignature
            displayedFinderSupplementSignature = finderSupplementSignature
            if shouldRefreshFindSession {
                refreshFindSessionAfterUserVisibleLogChange()
            }
            return presentationChanged || contentView.bounds.origin != previousOrigin
        }

        let mutation = reloadMutation(for: text)
        let shouldClearFindSelection = prepareFindSessionForLogMutation(mutation, resultingTextIsEmpty: text.isEmpty)
        logDocumentView.replaceText(text)
        displayedText = text
        displayedUTF16Length = (text as NSString).length
        logDocumentView.applyPresentation(document)
        displayedPresentationSignature = presentationSignature(
            forPrefixUTF16Length: displayedUTF16Length,
            in: document
        )
        displayedFinderSupplementSignature = finderSupplementSignature
        finishLogMutationForFindSession(clearSelection: shouldClearFindSelection)
        invalidateDocumentLayout()
        layoutSubtreeIfNeeded()
#if DEBUG
        reloadCount += 1
#endif
        restoreScrollPosition(restorationTarget, countAsAutoFollow: countBottomRestoreAsAutoFollow)
        invalidateFindIndicator()
        return true
    }

    private func reloadMutation(for text: String) -> LogTextMutation {
        guard displayedText.isEmpty == false,
              text.hasPrefix(displayedText)
        else {
            return .structural
        }
        return .appendPreservingPrefix
    }

    private func prepareFindSessionForLogMutation(
        _ mutation: LogTextMutation,
        resultingTextIsEmpty: Bool = false
    ) -> Bool {
        guard textFinder.isIncrementalSearchingEnabled else {
            return false
        }

        guard isFindBarVisible else {
            endFindSession()
            return false
        }
        refreshFindBarSearchFieldObservation()

        guard isFindQueryActive else {
            return false
        }
        guard resultingTextIsEmpty == false else {
            endFindSession()
            return false
        }

        captureFindSessionSnapshotIfNeeded()
        if mutation == .structural {
            textFinderClient.invalidateSnapshotDocumentMapping()
            return true
        }

        return false
    }

    private func finishLogMutationForFindSession(clearSelection: Bool) {
        if clearSelection {
            logDocumentView.setSelectedRangeFromTextFinder(NSRange(location: 0, length: 0))
        }
    }

    private func shouldRefreshFindSessionForFinderSupplementChange(to nextSignature: Int) -> Bool {
        guard isFindBarVisible,
              isFindQueryActive,
              textFinderClient.usesSnapshot,
              let displayedFinderSupplementSignature,
              displayedFinderSupplementSignature != nextSignature
        else {
            return false
        }
        return true
    }

    private func shouldRefreshFindSessionForCommandOutputReplacement(
        _ replacement: ReviewMonitorLogReplacement
    ) -> Bool {
        guard replacement.kind == .commandOutput,
              isFindBarVisible,
              isFindQueryActive,
              textFinderClient.usesSnapshot
        else {
            return false
        }
        return true
    }

    private func resetDeferredFindStateAfterFindBarHidden() {
        stopObservingFindBarSearchField()
        endFindSession()
    }

    private func handleUserSelectionChanged() {
        textFinderClient.clearSelectedRangeOverride()
        guard isFindBarVisible else {
            return
        }
        refreshFindBarSearchFieldObservation()
        if hasFindQuerySignal == false {
            endFindSession()
        }
    }

    private func handleFinderSelectedRangeChanged(_ range: NSRange) {
        if range.length > 0 || hasFindQuerySignal {
            beginFindSessionIfPossible()
        } else {
            endFindSession()
        }
    }

    private var hasFindQuerySignal: Bool {
        currentFindQueryString != nil
    }

    private var currentFindQueryString: String? {
        if let visibleSearchString = visibleFindBarSearchString {
            return visibleSearchString.isEmpty ? nil : visibleSearchString
        }
        guard let findString = NSPasteboard(name: .find).string(forType: .string),
              findString.isEmpty == false
        else {
            return nil
        }
        return findString
    }

    private var visibleFindBarSearchString: String? {
        guard isFindBarVisible,
              let findBarView = textFinderBarContainer.findBarView
        else {
            return nil
        }
        return findBarSearchField(in: findBarView)?.stringValue
    }

    private func refreshFindBarSearchFieldObservation() {
        guard isFindBarVisible,
              let findBarView = textFinderBarContainer.findBarView,
              let searchField = findBarSearchField(in: findBarView)
        else {
            stopObservingFindBarSearchField()
            return
        }

        guard observedFindBarSearchField !== searchField else {
            return
        }
        stopObservingFindBarSearchField()
        observedFindBarSearchField = searchField
        findBarSearchFieldChangeObserver = NotificationCenter.default.addObserver(
            forName: NSControl.textDidChangeNotification,
            object: searchField,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.findBarSearchStringDidChange()
            }
        }
    }

    private func stopObservingFindBarSearchField() {
        if let findBarSearchFieldChangeObserver {
            NotificationCenter.default.removeObserver(findBarSearchFieldChangeObserver)
        }
        findBarSearchFieldChangeObserver = nil
        observedFindBarSearchField = nil
    }

    private func findBarSearchStringDidChange() {
        refreshFindBarSearchFieldObservation()
        beginFindSessionForQueryChange(from: activeFindQueryString)
    }

    @discardableResult
    private func beginFindSessionIfPossible() -> Bool {
        guard isFindBarVisible, hasFindQuerySignal else {
            endFindSession()
            return false
        }

        isFindQueryActive = true
        activeFindQueryString = currentFindQueryString
        if textFinderClient.snapshotMapsToDocument == false {
            textFinderClient.clearSnapshot()
        }
        captureFindSessionSnapshotIfNeeded()
        return true
    }

    @discardableResult
    private func beginFindSessionForQueryChange(from previousQuery: String?) -> Bool {
        let currentQuery = currentFindQueryString
        if let currentQuery, currentQuery != previousQuery {
            textFinderClient.clearSnapshot()
        }
        return beginFindSessionIfPossible()
    }

    private func refreshFindSessionAfterUserVisibleLogChange() {
        guard isFindBarVisible else {
            return
        }

        textFinderClient.clearSnapshot()
        if hasFindQuerySignal {
            _ = beginFindSessionIfPossible()
        }
        invalidateFindIndicator()
    }

    private func captureFindSessionSnapshotIfNeeded() {
        guard textFinderClient.usesSnapshot == false else {
            return
        }
        textFinderClient.captureSnapshotIfNeeded(mapsToDocument: true) { logDocumentView.finderString }
    }

    private func endFindSession() {
        isFindQueryActive = false
        activeFindQueryString = nil
        textFinderClient.clearSnapshot()
        textFinder.cancelFindIndicator()
    }

    private func findBarSearchField(in view: NSView) -> NSSearchField? {
        if let searchField = view as? NSSearchField {
            return searchField
        }
        for subview in view.subviews {
            if let searchField = findBarSearchField(in: subview) {
                return searchField
            }
        }
        return nil
    }

    private func configureTextFinder() {
        textFinder.client = textFinderClient
        textFinder.findBarContainer = textFinderBarContainer
        textFinder.isIncrementalSearchingEnabled = true
        textFinder.incrementalSearchingShouldDimContentView = true
    }

    private func invalidateFindIndicator(reason: FindIndicatorInvalidationReason = .clientStringChanged) {
        guard isFindBarVisible else {
            return
        }
        if reason != .viewportChanged, textFinderClient.snapshotMapsToDocument == false {
            return
        }
#if DEBUG
        findIndicatorInvalidationCount += 1
#endif
        textFinder.findIndicatorNeedsUpdate = true
    }

    private func appendedSuffix(for text: String) -> String? {
        guard text.count > displayedText.count,
              text.hasPrefix(displayedText)
        else {
            return nil
        }
        let suffixStart = text.index(text.startIndex, offsetBy: displayedText.count)
        return String(text[suffixStart...])
    }

    private func presentationSignature(
        forPrefixUTF16Length prefixLength: Int,
        in document: ReviewMonitorLogDocument
    ) -> Int {
        let clampedPrefixLength = min(max(0, prefixLength), document.textUTF16Length)
        var hasher = Hasher()
        hasher.combine(clampedPrefixLength)

        for block in document.blocks {
            guard let range = clippedRange(block.range, upperBound: clampedPrefixLength) else {
                continue
            }
            hasher.combine("block")
            hasher.combine(block.id)
            hasher.combine(block.kind)
            hasher.combine(block.groupID)
            combine(range, into: &hasher)
            combine(sourceSignatureRange(for: block, clippedDisplayRange: range), into: &hasher)
            hasher.combine(block.metadata)
        }

        for styleRun in document.styleRuns {
            guard let range = clippedRange(styleRun.range, upperBound: clampedPrefixLength) else {
                continue
            }
            hasher.combine("style")
            combine(range, into: &hasher)
            hasher.combine(styleRun.style)
        }

        for decoration in document.decorations {
            guard let range = clippedRange(decoration.range, upperBound: clampedPrefixLength) else {
                continue
            }
            hasher.combine("decoration")
            hasher.combine(decoration.blockID)
            combine(range, into: &hasher)
            hasher.combine(decoration.style)
        }

        for panel in document.commandOutputPanels {
            guard let range = clippedRange(panel.range, upperBound: clampedPrefixLength) else {
                continue
            }
            hasher.combine("commandOutputPanel")
            hasher.combine(panel.blockID)
            combine(range, into: &hasher)
            hasher.combine(panel.commandText)
            hasher.combine(panel.isActive)
            hasher.combine(panel.startedAt)
            hasher.combine(panel.title)
            hasher.combine(panel.exitText)
            hasher.combine(panel.isExpanded)
            if panel.isExpanded {
                hasher.combine(panel.lineCount)
                hasher.combine(panel.outputText)
            }
        }

        return hasher.finalize()
    }

    private func sourceSignatureRange(
        for block: ReviewMonitorLogBlock,
        clippedDisplayRange: NSRange
    ) -> NSRange {
        if block.kind == .commandOutput {
            return clippedDisplayRange
        }
        return NSRange(
            location: block.sourceRange.location,
            length: min(block.sourceRange.length, clippedDisplayRange.length)
        )
    }

    private func clippedRange(_ range: NSRange, upperBound: Int) -> NSRange? {
        guard range.location < upperBound else {
            return nil
        }
        let end = min(NSMaxRange(range), upperBound)
        guard end > range.location else {
            return nil
        }
        return NSRange(location: range.location, length: end - range.location)
    }

    private func combine(_ range: NSRange, into hasher: inout Hasher) {
        hasher.combine(range.location)
        hasher.combine(range.length)
    }

    private func replaceDisplayedText(in range: NSRange, with text: String) {
        let mutable = NSMutableString(string: displayedText)
        mutable.replaceCharacters(in: range, with: text)
        displayedText = mutable as String
    }

    private func invalidateDocumentLayout() {
        if syncDocumentFrameToTextLayout() {
            logDocumentView.invalidateIntrinsicContentSize()
            logDocumentView.needsLayout = true
        }
    }

    private var effectiveScrollContentSize: NSSize {
        let scrollContentSize = contentSize
        let contentInsets = contentView.contentInsets
        return NSSize(
            width: max(0, scrollContentSize.width - max(0, contentInsets.left) - max(0, contentInsets.right)),
            height: max(0, scrollContentSize.height - max(0, contentInsets.bottom))
        )
    }

    @discardableResult
    private func syncDocumentFrameToTextLayout() -> Bool {
        let contentSize = effectiveScrollContentSize
        let metricsChanged = logDocumentView.updateLayoutMetrics(
            preferredTextContainerWidth: contentSize.width,
            contentInsets: contentView.contentInsets
        )
        var frameChanged = syncDocumentFrame(contentSize: contentSize)
        if metricsChanged {
            logDocumentView.layoutTextViewport()
            if syncDocumentFrame(contentSize: contentSize) {
                frameChanged = true
            }
        }
        return metricsChanged || frameChanged
    }

    @discardableResult
    private func syncDocumentFrame(contentSize: NSSize) -> Bool {
        let minimumHeight = minimumDocumentHeight(for: contentSize)
        let targetHeight = max(
            logDocumentView.estimatedDocumentHeight,
            minimumHeight
        )
        let targetFrame = NSRect(
            x: 0,
            y: 0,
            width: contentSize.width,
            height: targetHeight
        )
        guard rectsAreNearlyEqual(logDocumentView.frame, targetFrame) == false else {
            return false
        }
        logDocumentView.frame = targetFrame
        return true
    }

    private func minimumDocumentHeight(for contentSize: NSSize) -> CGFloat {
        max(0, contentSize.height - max(0, contentView.contentInsets.top))
    }

    private func rectsAreNearlyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 0.5 &&
            abs(lhs.minY - rhs.minY) <= 0.5 &&
            abs(lhs.width - rhs.width) <= 0.5 &&
            abs(lhs.height - rhs.height) <= 0.5
    }

    private func scrollToBottom(countAsAutoFollow: Bool, hideOverlayScroller: Bool = true) {
        syncDocumentFrameToTextLayout()
        let targetOrigin = NSPoint(x: 0, y: maximumVerticalScrollOffset())
        if pointsAreNearlyEqual(contentView.bounds.origin, targetOrigin) {
#if DEBUG
            if countAsAutoFollow {
                autoFollowCount += 1
            }
#endif
            if hideOverlayScroller {
                hideOverlayScrollerAfterProgrammaticScrollIfNeeded()
            }
            return
        }

        restoreScrollOrigin(targetOrigin, hideOverlayScroller: hideOverlayScroller)
        let settledMaximumOffset = maximumVerticalScrollOffset()
        if abs(contentView.bounds.origin.y - settledMaximumOffset) > 0.5 {
            restoreScrollOrigin(
                NSPoint(x: 0, y: settledMaximumOffset),
                hideOverlayScroller: hideOverlayScroller
            )
        }
#if DEBUG
        if countAsAutoFollow {
            autoFollowCount += 1
        }
#endif
    }

    private func shouldPreserveBottomForLayout() -> Bool {
        guard displayedText.isEmpty == false else {
            return false
        }
        if liveResizeRestorationTarget == .bottom {
            return true
        }
        return isPinnedToBottom()
    }

    private func hasScrollableVerticalRange() -> Bool {
        maximumVerticalScrollOffset() > minimumVerticalScrollOffset() + 0.5
    }

    private func restoreScrollOrigin(_ origin: NSPoint, hideOverlayScroller: Bool = true) {
        guard documentView != nil else {
            return
        }
        let minY = minimumVerticalScrollOffset()
        let maxY = maximumVerticalScrollOffset()
        let clampedOrigin = NSPoint(
            x: 0,
            y: min(max(minY, origin.y), maxY)
        )
        guard pointsAreNearlyEqual(contentView.bounds.origin, clampedOrigin) == false else {
            return
        }

        contentView.scroll(to: clampedOrigin)
#if DEBUG
        programmaticScrollCount += 1
#endif
        reflectScrolledClipView(contentView)
        if hideOverlayScroller {
            hideOverlayScrollerAfterProgrammaticScrollIfNeeded()
        }
    }

    private func restoreScrollPosition(
        _ restorationTarget: ScrollRestorationTarget,
        countAsAutoFollow: Bool
    ) {
        switch restorationTarget {
        case .top:
            restoreScrollOrigin(NSPoint(x: 0, y: minimumVerticalScrollOffset()))
        case .offset(let y):
            restoreScrollOrigin(NSPoint(x: 0, y: y))
        case .bottom:
            scrollToBottom(countAsAutoFollow: countAsAutoFollow)
        }
    }

    var currentScrollRestorationTarget: ScrollRestorationTarget {
        guard displayedText.isEmpty == false else {
            return .top
        }

        let maxOffset = maximumVerticalScrollOffset()
        let minOffset = minimumVerticalScrollOffset()
        guard maxOffset > minOffset else {
            return .top
        }

        let offset = contentView.bounds.origin.y
        if isAtBottom(tolerance: 1) {
            return .bottom
        }

        return offset > minOffset + 0.5 ? .offset(offset) : .top
    }

    private func maximumVerticalScrollOffset() -> CGFloat {
        guard let documentView else {
            return 0
        }
        let minY = minimumVerticalScrollOffset()
        let bottomInset = max(0, contentView.contentInsets.bottom)
        let maxY = documentView.frame.height - contentView.bounds.height + bottomInset
        return max(minY, maxY)
    }

    private func minimumVerticalScrollOffset() -> CGFloat {
        -max(0, contentView.contentInsets.top)
    }

    private func hideOverlayScrollerAfterProgrammaticScrollIfNeeded() {
        guard scrollerStyle == .overlay,
              maximumVerticalScrollOffset() > minimumVerticalScrollOffset() + 0.5,
              let scrollerImpPair = scrollerImpPairForOverlayControl(),
              overlayScrollersShown(on: scrollerImpPair) == true,
              requestOverlayScrollersHide(on: scrollerImpPair)
        else {
            return
        }

#if DEBUG
        overlayScrollerHideRequestCount += 1
#endif
    }

    private func scrollerImpPairForOverlayControl() -> NSObject? {
#if DEBUG
        if overlayScrollerBridgeModeForTesting == .missingScrollerImpPair {
            return nil
        }
#endif
        return objectValue(for: Self.scrollerImpPairSelector, on: self)
    }

    private func overlayScrollersShown(on scrollerImpPair: NSObject) -> Bool? {
#if DEBUG
        if let overlayScrollersShownOverrideForTesting {
            return overlayScrollersShownOverrideForTesting
        }
        if overlayScrollerBridgeModeForTesting == .missingOverlayScrollersShown {
            return nil
        }
#endif
        return boolValue(for: Self.overlayScrollersShownSelector, on: scrollerImpPair)
    }

    private func requestOverlayScrollersHide(on scrollerImpPair: NSObject) -> Bool {
#if DEBUG
        if overlayScrollerBridgeModeForTesting == .missingHideMethods {
            return false
        }
#endif
        if invokeVoidSelector(Self.hideOverlayScrollersSelector, on: scrollerImpPair) {
            return true
        }
        return invokeVoidSelector(Self.beginHideOverlayScrollersSelector, on: scrollerImpPair)
    }

    private func objectValue(for selector: Selector, on object: NSObject) -> NSObject? {
        guard let method = resolvedMethod(for: selector, on: object) else {
            return nil
        }
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: ObjectGetter.self)
        return function(object, selector)?.takeUnretainedValue() as? NSObject
    }

    private func boolValue(for selector: Selector, on object: NSObject) -> Bool? {
        guard let method = resolvedMethod(for: selector, on: object) else {
            return nil
        }
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: BoolGetter.self)
        return function(object, selector)
    }

    private func invokeVoidSelector(_ selector: Selector, on object: NSObject) -> Bool {
        guard let method = resolvedMethod(for: selector, on: object) else {
            return false
        }
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: VoidMethod.self)
        function(object, selector)
        return true
    }

    private func resolvedMethod(for selector: Selector, on object: NSObject) -> Method? {
        guard object.responds(to: selector) else {
            return nil
        }
        return class_getInstanceMethod(type(of: object), selector)
    }

    private func isPinnedToBottom() -> Bool {
        isAtBottom(tolerance: 1)
    }

    private func isAtBottom(tolerance: CGFloat) -> Bool {
        let maxOffset = maximumVerticalScrollOffset()
        let minOffset = minimumVerticalScrollOffset()
        guard maxOffset > minOffset else {
            return true
        }
        return maxOffset - contentView.bounds.origin.y <= tolerance
    }

    private func pointsAreNearlyEqual(_ lhs: NSPoint, _ rhs: NSPoint) -> Bool {
        abs(lhs.x - rhs.x) <= 0.5 && abs(lhs.y - rhs.y) <= 0.5
    }

    @discardableResult
    func performDisplayedTextFinderAction(_ sender: Any?) -> Bool {
        guard isHidden == false,
              let action = textFinderAction(from: sender)
        else {
            return false
        }
        guard textFinder.validateAction(action) else {
            return false
        }
        let activeFindQueryStringBeforeAction = activeFindQueryString
        let selectedRangeBeforeAction = textFinderClient.firstSelectedRange
        textFinder.performAction(action)
        refreshFindBarSearchFieldObservation()
        if action == .setSearchString {
            if selectedRangeBeforeAction.length > 0 || hasFindQuerySignal {
                beginFindSessionForQueryChange(from: activeFindQueryStringBeforeAction)
            } else {
                endFindSession()
            }
        } else if actionActivatesFindQuery(action) &&
            (isFindQueryActive || hasFindQuerySignal || textFinderClient.firstSelectedRange.length > 0) {
            beginFindSessionIfPossible()
        }
        return true
    }

    private func actionActivatesFindQuery(_ action: NSTextFinder.Action) -> Bool {
        action == .setSearchString ||
            action == .showFindInterface ||
            action == .nextMatch ||
            action == .previousMatch ||
            action == .selectAll ||
            action == .selectAllInSelection
    }

    func validateDisplayedTextFinderAction(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard isHidden == false,
              let action = textFinderAction(from: item)
        else {
            return false
        }
        return textFinder.validateAction(action)
    }

    private func textFinderAction(from sender: Any?) -> NSTextFinder.Action? {
        switch sender {
        case let item as NSValidatedUserInterfaceItem:
            return NSTextFinder.Action(rawValue: item.tag)
        case let control as NSControl:
            return NSTextFinder.Action(rawValue: control.tag)
        case let menuItem as NSMenuItem:
            return NSTextFinder.Action(rawValue: menuItem.tag)
        case let value as NSNumber:
            return NSTextFinder.Action(rawValue: value.intValue)
        default:
            return nil
        }
    }
}

#if DEBUG
@MainActor
extension ReviewMonitorLogScrollView {
    var displayedTextForTesting: String {
        ReviewMonitorCommandOutputDisplayDocument.userVisibleText(from: displayedText)
    }

    func displayTextForTesting(sourceDocument: ReviewMonitorLogDocument) -> String {
        ReviewMonitorCommandOutputDisplayDocument.userVisibleText(from: displayDocument(for: sourceDocument).text)
    }

    var usesCustomTextKit2SurfaceForTesting: Bool {
        logDocumentView.usesTextKit2ForTesting
    }

    var usesTextViewForTesting: Bool {
        false
    }

    var usesLegacyLayoutManagerForTesting: Bool {
        false
    }

    var isEditableForTesting: Bool {
        false
    }

    var isSelectableForTesting: Bool {
        true
    }

    var usesFindBarForTesting: Bool {
        textFinder.findBarContainer === textFinderBarContainer
    }

    var isIncrementalSearchingEnabledForTesting: Bool {
        textFinder.isIncrementalSearchingEnabled
    }

    var isFindBarVisibleForTesting: Bool {
        isFindBarVisible
    }

    var textFinderIdentifierForTesting: ObjectIdentifier {
        ObjectIdentifier(textFinder)
    }

    var findVisibleCharacterRangesForTesting: [NSRange] {
        textFinderClient.visibleCharacterRanges.map(\.rangeValue)
    }

    var findStringLengthForTesting: Int {
        textFinderClient.stringLength()
    }

    var findStringForTesting: String {
        textFinderClient.string
    }

    var findClientUsesSnapshotForTesting: Bool {
        textFinderClient.usesSnapshotForTesting
    }

    var findClientSnapshotMapsToDocumentForTesting: Bool {
        textFinderClient.snapshotMapsToDocumentForTesting
    }

    var findClientFirstSelectedRangeForTesting: NSRange {
        textFinderClient.firstSelectedRange
    }

    func setFinderSelectedRangeForTesting(_ range: NSRange) {
        textFinderClient.selectedRanges = [NSValue(range: range)]
    }

    var findIncrementalMatchRangeCountForTesting: Int {
        textFinder.incrementalMatchRanges.count
    }

    var hasActiveFindQueryForTesting: Bool {
        isFindQueryActive
    }

    var visibleFindBarSearchStringForTesting: String? {
        visibleFindBarSearchString
    }

    @discardableResult
    func setVisibleFindBarSearchStringForTesting(_ string: String) -> Bool {
        guard isFindBarVisible,
              let findBarView = textFinderBarContainer.findBarView,
              let searchField = findBarSearchField(in: findBarView)
        else {
            return false
        }
        searchField.stringValue = string
        findBarSearchStringDidChange()
        return true
    }

    var findIndicatorInvalidationCountForTesting: Int {
        findIndicatorInvalidationCount
    }

    var findBarContainerContentViewIsTextContentViewForTesting: Bool {
        textFinderBarContainer.contentView() === logDocumentView.finderContentView
    }

    var findIncrementalSearchUsesSystemHighlightingForTesting: Bool {
        textFinder.incrementalSearchingShouldDimContentView
    }

    var hitTestTargetsDocumentViewForTesting: Bool {
        logDocumentView.hitTestTargetsDocumentViewForTesting
    }

    var writingToolsDisabledForTesting: Bool {
        true
    }

    var isPinnedToBottomForTesting: Bool {
        isPinnedToBottom()
    }

    func scrollToTopForTesting() {
        restoreScrollOrigin(NSPoint(x: 0, y: minimumVerticalScrollOffset()))
    }

    func scrollToOffsetForTesting(_ y: CGFloat) {
        restoreScrollOrigin(NSPoint(x: 0, y: y))
    }

    var verticalScrollOffsetForTesting: CGFloat {
        contentView.bounds.origin.y
    }

    var viewportHeightForTesting: CGFloat {
        contentView.bounds.height
    }

    var minimumVerticalScrollOffsetForTesting: CGFloat {
        minimumVerticalScrollOffset()
    }

    var maximumVerticalScrollOffsetForTesting: CGFloat {
        maximumVerticalScrollOffset()
    }

    var textContentFrameForTesting: NSRect {
        logDocumentView.bounds
    }

    var documentViewFrameForTesting: NSRect {
        logDocumentView.frame
    }

    var contentInsetsForTesting: NSEdgeInsets {
        contentView.contentInsets
    }

    var automaticallyAdjustsContentInsetsForTesting: Bool {
        automaticallyAdjustsContentInsets
    }

    var textContainerSizeForTesting: NSSize {
        syncDocumentFrameToTextLayout()
        return logDocumentView.textContainerSize
    }

    var textContainerInsetForTesting: NSSize {
        logDocumentView.textContainerInset
    }

    func scrollToBottomForTesting() {
        scrollToBottom(countAsAutoFollow: false)
    }

    var visibleFragmentViewCountForTesting: Int {
        logDocumentView.layoutTextViewport(force: true)
        return logDocumentView.visibleFragmentViewCountForTesting
    }

    var commandOutputPanelCountForTesting: Int {
        logDocumentView.commandOutputPanelCountForTesting
    }

    var terminalDecorationRectCountForTesting: Int {
        logDocumentView.terminalDecorationRectCountForTesting
    }

    var expandedCommandOutputPanelCountForTesting: Int {
        logDocumentView.expandedCommandOutputPanelCountForTesting
    }

    var commandOutputPanelUsesTextKit2ForTesting: Bool {
        logDocumentView.commandOutputPanelUsesTextKit2ForTesting
    }

    var commandOutputPanelUsesInlineAttachmentForTesting: Bool {
        logDocumentView.commandOutputPanelUsesInlineAttachmentForTesting
    }

    var commandOutputPanelUsesButtonAttachmentForTesting: Bool {
        logDocumentView.commandOutputPanelUsesButtonAttachmentForTesting
    }

    var collapsedCommandOutputPanelAttachmentLineHeightForTesting: CGFloat? {
        logDocumentView.collapsedCommandOutputPanelAttachmentLineHeightForTesting
    }

    var collapsedCommandOutputPanelAttachmentPayloadIsEmptyForTesting: Bool {
        logDocumentView.collapsedCommandOutputPanelAttachmentPayloadIsEmptyForTesting
    }

    var commandOutputPanelUsesSystemMaterialBackgroundForTesting: Bool {
        logDocumentView.commandOutputPanelUsesSystemMaterialBackgroundForTesting
    }

    var commandOutputPanelVisibleLineCapacityForTesting: Int {
        logDocumentView.commandOutputPanelVisibleLineCapacityForTesting
    }

    var commandOutputPanelResultTextForTesting: String? {
        logDocumentView.commandOutputPanelResultTextForTesting
    }

    var commandOutputPanelTerminalTextForTesting: String? {
        logDocumentView.commandOutputPanelTerminalTextForTesting
    }

    func commandOutputPanelTerminalTextForTesting(blockID: ReviewMonitorLogBlockID) -> String? {
        logDocumentView.commandOutputPanelTerminalTextForTesting(blockID: blockID)
    }

    var commandOutputPanelCommandLineTextForTesting: String? {
        logDocumentView.commandOutputPanelCommandLineTextForTesting
    }

    var commandOutputPanelOutputScrollTextForTesting: String? {
        logDocumentView.commandOutputPanelOutputScrollTextForTesting
    }

    var commandOutputPanelOutputScrollIsScrollableForTesting: Bool {
        logDocumentView.commandOutputPanelOutputScrollIsScrollableForTesting
    }

    var commandOutputPanelOutputScrollUsesHorizontalScrollingForTesting: Bool {
        logDocumentView.commandOutputPanelOutputScrollUsesHorizontalScrollingForTesting
    }

    var commandOutputPanelOutputScrollVerticalOffsetForTesting: CGFloat? {
        logDocumentView.commandOutputPanelOutputScrollVerticalOffsetForTesting
    }

    var commandOutputPanelOutputScrollMaximumVerticalOffsetForTesting: CGFloat? {
        logDocumentView.commandOutputPanelOutputScrollMaximumVerticalOffsetForTesting
    }

    func scrollCommandOutputPanelOutputForTesting(deltaY: CGFloat) -> Bool {
        logDocumentView.scrollCommandOutputPanelOutputForTesting(deltaY: deltaY)
    }

    var commandOutputPanelOutputHitTestTargetsTextViewForTesting: Bool {
        logDocumentView.commandOutputPanelOutputHitTestTargetsTextViewForTesting
    }

    func finderRectsForTesting(_ range: NSRange) -> [NSRect] {
        logDocumentView.finderRectsForTesting(range)
    }

    var firstCommandOutputPanelRectForTesting: NSRect? {
        logDocumentView.firstCommandOutputPanelRectForTesting
    }

    var commandOutputPanelToggleSymbolNameForTesting: String? {
        logDocumentView.commandOutputPanelToggleSymbolNameForTesting
    }

    var commandOutputPanelLeadingAlignmentDeltaForTesting: CGFloat? {
        logDocumentView.commandOutputPanelLeadingAlignmentDeltaForTesting
    }

    var commandOutputPanelChevronSizeDeltaForTesting: CGFloat? {
        logDocumentView.commandOutputPanelChevronSizeDeltaForTesting
    }

    var commandOutputPanelChevronVerticalAlignmentDeltaForTesting: CGFloat? {
        logDocumentView.commandOutputPanelChevronVerticalAlignmentDeltaForTesting
    }

    func hitTestTargetsDocumentViewForFirstLogOccurrenceForTesting(_ text: String) -> Bool {
        logDocumentView.hitTestTargetsDocumentViewForFirstOccurrenceForTesting(text)
    }

    func toggleFirstCommandOutputPanelForTesting() {
        logDocumentView.toggleFirstCommandOutputPanelForTesting()
    }

    @discardableResult
    func clickFirstCommandOutputPanelHeaderForTesting() -> Bool {
        logDocumentView.clickFirstCommandOutputPanelHeaderForTesting()
    }

    @discardableResult
    func clickCommandOutputPanelHeaderForTesting(blockID: ReviewMonitorLogBlockID) -> Bool {
        logDocumentView.clickCommandOutputPanelHeaderForTesting(blockID: blockID)
    }

    var visibleFragmentBoundsForTesting: NSRect {
        logDocumentView.layoutTextViewport(force: true)
        return logDocumentView.visibleFragmentBoundsForTesting
    }

    var staleFragmentViewCountForTesting: Int {
        logDocumentView.staleFragmentViewCountForTesting
    }

    var accessibilityValueForTesting: String? {
        logDocumentView.accessibilityValue() as? String
    }

    var selectedTextForTesting: String? {
        logDocumentView.accessibilitySelectedText()
    }

    var selectedRangeForTesting: NSRange {
        logDocumentView.selectedRangeForTesting
    }

    func selectAllForTesting() {
        logDocumentView.selectAll(nil)
    }

    func setSelectedLogRangeForTesting(_ range: NSRange) {
        logDocumentView.setSelectedRange(range)
    }

    var documentViewExportsUserInterfaceValidationForTesting: Bool {
        logDocumentView.responds(to: #selector(ReviewMonitorLogDocumentView.validateUserInterfaceItem(_:)))
    }

    func validateDocumentUserInterfaceItemForTesting(_ item: NSValidatedUserInterfaceItem) -> Bool {
        logDocumentView.validateUserInterfaceItem(item)
    }

    func contextMenuForTesting() -> NSMenu? {
        logDocumentView.contextMenuForTesting()
    }

    func clearFinderSelectedRangesForTesting() {
        logDocumentView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    func simulateFinderEmptySelectedRangesForTesting() {
        textFinderClient.selectedRanges = []
    }

    func performKeyboardCommandForTesting(_ selector: Selector) {
        logDocumentView.doCommand(by: selector)
    }

    @discardableResult
    func renderForTesting(text: String, allowIncrementalUpdate: Bool) -> Bool {
        render(
            document: .init(text: text, revision: (displayedRevision ?? 0) &+ 1),
            restoring: currentScrollRestorationTarget,
            allowIncrementalUpdate: allowIncrementalUpdate
        )
    }

    func copySelectionForTesting() {
        logDocumentView.copy(nil)
    }

    var wordGlowCountForTesting: Int {
        logDocumentView.wordGlowCountForTesting
    }

    var wordFadeRenderingAttributeRangeCountForTesting: Int {
        logDocumentView.wordFadeRenderingAttributeRangeCountForTesting
    }

    var wordFadeStorageUsesOpaqueTextColorForTesting: Bool {
        logDocumentView.wordFadeStorageUsesOpaqueTextColorForTesting
    }

    var wordFadeDisplayInvalidationCountForTesting: Int {
        logDocumentView.wordFadeDisplayInvalidationCountForTesting
    }

    func completeWordGlowAnimationsForTesting() {
        logDocumentView.completeWordGlowAnimationsForTesting()
    }

    func advanceWordGlowAnimationsAfterInitialDelayForTesting(_ delay: TimeInterval) {
        logDocumentView.advanceWordGlowAnimationsAfterInitialDelayForTesting(delay)
    }

    func setReduceMotionForTesting(_ reduceMotion: Bool?) {
        logDocumentView.reduceMotionOverrideForTesting = reduceMotion
        if reduceMotion == true {
            logDocumentView.cancelGlowAnimations()
        }
    }

    var overlayScrollerHideRequestCountForTesting: Int {
        overlayScrollerHideRequestCount
    }

    var programmaticScrollCountForTesting: Int {
        programmaticScrollCount
    }

    func setScrollerStyleForTesting(_ style: NSScroller.Style) {
        scrollerStyle = style
    }

    func setOverlayScrollersShownForTesting(_ isShown: Bool?) {
        overlayScrollersShownOverrideForTesting = isShown
    }

    func setOverlayScrollerBridgeModeForTesting(_ mode: OverlayScrollerBridgeModeForTesting) {
        overlayScrollerBridgeModeForTesting = mode
    }

    func beginLiveResizeForTesting() {
        viewWillStartLiveResize()
    }

    func endLiveResizeForTesting() {
        viewDidEndLiveResize()
    }
}

#endif
