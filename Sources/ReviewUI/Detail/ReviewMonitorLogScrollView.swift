import AppKit
import ObjectiveC.runtime

@MainActor
final class ReviewMonitorLogScrollView: NSScrollView {
    private static let scrollerImpPairSelector = NSSelectorFromString("scrollerImpPair")
    private static let overlayScrollersShownSelector = NSSelectorFromString("overlayScrollersShown")
    private static let hideOverlayScrollersSelector = NSSelectorFromString("hideOverlayScrollers")
    private static let beginHideOverlayScrollersSelector = NSSelectorFromString("_beginHideOverlayScrollers")

    private typealias ObjectGetter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    private typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
    private typealias VoidMethod = @convention(c) (AnyObject, Selector) -> Void

    enum ScrollRestorationTarget: Equatable {
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
    private let textFinder = NSTextFinder()
    private let textFinderClient = ReviewMonitorLogTextFinderClient()
    private let textFinderBarContainer = ReviewMonitorLogTextFinderBarContainer()
    private var displayedText = ""
    private var liveResizeRestorationTarget: ScrollRestorationTarget?

#if DEBUG
    private(set) var appendCount = 0
    private(set) var reloadCount = 0
    private(set) var autoFollowCount = 0
    private(set) var programmaticScrollCount = 0
    private(set) var findClientStringWillChangeCount = 0
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
        logDocumentView.setAccessibilityIdentifier("review-monitor.activity-log")

        textFinderClient.documentView = logDocumentView
        textFinderBarContainer.scrollView = self
        textFinderBarContainer.finderContentView = logDocumentView.finderContentView
        textFinder.client = textFinderClient
        textFinder.findBarContainer = textFinderBarContainer
        textFinder.isIncrementalSearchingEnabled = true
        textFinder.incrementalSearchingShouldDimContentView = true

        invalidateDocumentLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            textFinder.cancelFindIndicator()
            textFinder.client = nil
            textFinder.findBarContainer = nil
        } else if textFinder.client == nil {
            textFinder.client = textFinderClient
            textFinder.findBarContainer = textFinderBarContainer
        }
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
        invalidateFindIndicator()
    }

    @discardableResult
    func clear() -> Bool {
        applyReload("", restoring: .top, countBottomRestoreAsAutoFollow: false)
    }

    @discardableResult
    func render(
        text: String,
        restoring restorationTarget: ScrollRestorationTarget,
        allowIncrementalUpdate: Bool
    ) -> Bool {
        if allowIncrementalUpdate, let suffix = appendedSuffix(for: text) {
            return applyAppend(suffix)
        }
        return applyReload(text, restoring: restorationTarget, countBottomRestoreAsAutoFollow: false)
    }

    @discardableResult
    private func applyAppend(_ suffix: String) -> Bool {
        guard suffix.isEmpty == false else {
            return false
        }

        let shouldAutoFollow = isPinnedToBottom()
        noteClientStringWillChange()
        logDocumentView.appendText(suffix)
        displayedText += suffix
        invalidateDocumentLayout()
#if DEBUG
        appendCount += 1
#endif
        if shouldAutoFollow {
            scrollToBottom(countAsAutoFollow: true)
        } else {
            logDocumentView.layoutTextViewport()
        }
        invalidateFindIndicator()
        return true
    }

    @discardableResult
    private func applyReload(
        _ text: String,
        restoring restorationTarget: ScrollRestorationTarget,
        countBottomRestoreAsAutoFollow: Bool
    ) -> Bool {
        if displayedText == text {
            let previousOrigin = contentView.bounds.origin
            invalidateDocumentLayout()
            restoreScrollPosition(restorationTarget, countAsAutoFollow: countBottomRestoreAsAutoFollow)
            return contentView.bounds.origin != previousOrigin
        }

        noteClientStringWillChange()
        logDocumentView.replaceText(text)
        displayedText = text
        invalidateDocumentLayout()
        layoutSubtreeIfNeeded()
#if DEBUG
        reloadCount += 1
#endif
        restoreScrollPosition(restorationTarget, countAsAutoFollow: countBottomRestoreAsAutoFollow)
        invalidateFindIndicator()
        return true
    }

    private func noteClientStringWillChange() {
        if textFinder.isIncrementalSearchingEnabled {
#if DEBUG
            findClientStringWillChangeCount += 1
#endif
            textFinder.noteClientStringWillChange()
        }
    }

    private func invalidateFindIndicator() {
        guard isFindBarVisible else {
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
        if metricsChanged || frameChanged {
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
        textFinder.performAction(action)
        return true
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

@MainActor
private final class ReviewMonitorLogDocumentView: NSView, @preconcurrency NSTextViewportLayoutControllerDelegate {
    private let textContentStorage = NSTextContentStorage()
    private let textLayoutManager = NSTextLayoutManager()
    private let textContainer = NSTextContainer(
        size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )
    private let textStorage = NSTextStorage()
    private let textContentView = ReviewMonitorLogContentView()
    private let fragmentViewportView = ReviewMonitorLogContentViewportView()
    private let selectionView = ReviewMonitorLogSelectionView()
    private let fragmentViewMap = NSMapTable<NSTextLayoutFragment, ReviewMonitorLogFragmentView>.weakToWeakObjects()
    private var visibleFragmentViews = Set<ReviewMonitorLogFragmentView>()
    private var lastUsedFragmentViews = Set<ReviewMonitorLogFragmentView>()
    private var needsViewportLayout = true
    private var needsViewportRelayout = false
    private var lastViewportLayoutBounds: CGRect?
    private var isLayingOutViewport = false
    private var selectedRange = NSRange(location: 0, length: 0)
    private var dragAnchorUTF16Offset: Int?
    private var preferredTextContainerWidth: CGFloat = 0
    private(set) var estimatedDocumentHeight: CGFloat = 0
    var contentInsets: NSEdgeInsets = .init()
    var textContainerInset = NSSize(width: 4, height: 6)
    var onLayoutInvalidated: (() -> Void)?

    private let baseFont = NSFont.monospacedSystemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize,
        weight: .regular
    )
    private var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .foregroundColor: NSColor.textColor,
        ]
    }

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: estimatedDocumentHeight)
    }

    var string: String {
        textStorage.string
    }

    var stringLength: Int {
        textStorage.length
    }

    var textContainerSize: NSSize {
        textContainer.size
    }

    var selectedRangeForFinding: NSRange {
        selectedRange
    }

    var finderContentView: NSView {
        textContentView
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        textContainer.lineFragmentPadding = 5
        textLayoutManager.textContainer = textContainer
        textContentStorage.textStorage = textStorage
        textContentStorage.addTextLayoutManager(textLayoutManager)
        textContentStorage.primaryTextLayoutManager = textLayoutManager
        textLayoutManager.textViewportLayoutController.delegate = self
        addSubview(textContentView)
        textContentView.addSubview(selectionView)
        textContentView.addSubview(fragmentViewportView)
        estimatedDocumentHeight = measuredDocumentHeight()
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        syncContentSubviewFrames()
        layoutTextViewport()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        syncContentSubviewFrames()
        if sizesAreNearlyEqual(oldSize, frame.size) == false, isLayingOutViewport {
            needsViewportRelayout = true
        }
    }

    override class var isCompatibleWithResponsiveScrolling: Bool {
        false
    }

    override func prepareContent(in rect: NSRect) {
        let previousPreparedContentRect = preparedContentRect
        var preparedRect = rect

        let verticalPrepExpansion = preparedRect.height * 0.5
        if verticalPrepExpansion > 0 {
            let upwardShift = min(verticalPrepExpansion, max(0, preparedRect.minY))
            preparedRect.origin.y -= upwardShift
            preparedRect.size.height += upwardShift
        }
        preparedRect.size.width = max(preparedRect.width, frame.width)

        super.prepareContent(in: preparedRect)

        if rectsAreNearlyEqual(previousPreparedContentRect, preparedContentRect) == false {
            layoutTextViewport()
        }
    }

    @discardableResult
    func updateLayoutMetrics(
        preferredTextContainerWidth: CGFloat,
        contentInsets: NSEdgeInsets
    ) -> Bool {
        let widthChanged = abs(self.preferredTextContainerWidth - preferredTextContainerWidth) > 0.5
        let insetsChanged = edgeInsetsAreNearlyEqual(self.contentInsets, contentInsets) == false
        guard widthChanged || insetsChanged else {
            return false
        }

        self.contentInsets = contentInsets
        self.preferredTextContainerWidth = preferredTextContainerWidth
        let containerChanged = syncTextContainerSize()
        if insetsChanged {
            needsViewportLayout = true
            lastViewportLayoutBounds = nil
        }
        if containerChanged || estimatedDocumentHeight <= 0 {
            updateEstimatedDocumentHeight()
        }
        return true
    }

    func appendText(_ suffix: String) {
        guard suffix.isEmpty == false else {
            return
        }
        let invalidationStart = appendInvalidationStartUTF16Offset()
        textContentStorage.performEditingTransaction {
            textStorage.append(NSAttributedString(string: suffix, attributes: baseAttributes))
        }
        clampSelectedRange()
        invalidateTextLayout(
            in: NSRange(location: invalidationStart, length: textStorage.length - invalidationStart),
            measureEstimatedHeightImmediately: false
        )
    }

    func replaceText(_ text: String) {
        textContentStorage.performEditingTransaction {
            textStorage.setAttributedString(NSAttributedString(string: text, attributes: baseAttributes))
        }
        clampSelectedRange()
        invalidateTextLayout(measureEstimatedHeightImmediately: true)
    }

    func layoutTextViewport(force: Bool = false) {
        guard window != nil || superview != nil else {
            return
        }
        let viewportBounds = currentViewportBounds()
        guard force ||
              needsViewportLayout ||
              lastViewportLayoutBounds.map({ rectsAreNearlyEqual($0, viewportBounds) == false }) ?? true
        else {
            return
        }
        guard isLayingOutViewport == false else {
            needsViewportRelayout = true
            return
        }

        isLayingOutViewport = true
        defer {
            isLayingOutViewport = false
            updateSelectionRects()
        }

        var iterations = 5
        repeat {
            needsViewportRelayout = false
            let currentBounds = currentViewportBounds()
            lastViewportLayoutBounds = currentBounds
            textLayoutManager.textViewportLayoutController.layoutViewport()
            iterations -= 1
        } while needsViewportRelayout && iterations > 0

        needsViewportLayout = needsViewportRelayout
    }

    func setSelectedRange(_ range: NSRange) {
        let clampedRange = clamp(range)
        selectedRange = clampedRange
        if let textRange = textRange(for: clampedRange) {
            textLayoutManager.textSelections = [
                NSTextSelection([textRange], affinity: .downstream, granularity: .character),
            ]
        } else {
            textLayoutManager.textSelections = []
        }
        updateSelectionRects()
        setNeedsDisplay(bounds)
    }

    func scrollRangeToVisible(_ range: NSRange) {
        let rects = rects(forCharacterRange: range).map(\.rectValue)
        guard let firstRect = rects.first else {
            return
        }
        var unionRect = firstRect
        for rect in rects.dropFirst() {
            unionRect = unionRect.union(rect)
        }
        scrollToVisible(unionRect.insetBy(dx: -12, dy: -12))
    }

    func rects(forCharacterRange range: NSRange) -> [NSValue] {
        guard let textRange = textRange(for: range) else {
            return []
        }

        textLayoutManager.ensureLayout(for: textRange)
        var rects: [NSValue] = []
        textLayoutManager.enumerateTextSegments(
            in: textRange,
            type: .standard,
            options: .rangeNotRequired
        ) { _, rect, _, _ in
            rects.append(NSValue(rect: rect.offsetBy(dx: textContainerInset.width, dy: textContainerInset.height)))
            return true
        }
        return rects
    }

    func visibleCharacterRanges() -> [NSValue] {
        layoutTextViewport()
        guard let viewportRange = textLayoutManager.textViewportLayoutController.viewportRange else {
            return [NSValue(range: NSRange(location: 0, length: textStorage.length))]
        }
        return [NSValue(range: nsRange(for: viewportRange))]
    }

    func drawCharacters(in range: NSRange, forContentView view: NSView) {
        guard view === finderContentView,
              let textRange = textRange(for: range),
              let context = NSGraphicsContext.current?.cgContext
        else {
            return
        }

        textLayoutManager.ensureLayout(for: textRange)
        textLayoutManager.enumerateTextLayoutFragments(
            from: textRange.location,
            options: [.ensuresLayout]
        ) { layoutFragment in
            guard layoutFragment.rangeInElement.intersects(textRange) else {
                return layoutFragment.rangeInElement.location.compare(textRange.endLocation) == .orderedAscending
            }
            let origin = layoutFragment.layoutFragmentFrame.origin
            layoutFragment.draw(
                at: NSPoint(
                    x: origin.x + textContainerInset.width,
                    y: origin.y + textContainerInset.height
                ),
                in: context
            )
            return layoutFragment.rangeInElement.endLocation.compare(textRange.endLocation) == .orderedAscending
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let offset = utf16Offset(at: point)
        dragAnchorUTF16Offset = offset
        if event.clickCount > 1 {
            setSelectedRange(wordRange(containing: offset))
        } else {
            setSelectedRange(NSRange(location: offset, length: 0))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragAnchorUTF16Offset else {
            return
        }
        autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let offset = utf16Offset(at: point)
        let location = min(dragAnchorUTF16Offset, offset)
        let length = abs(offset - dragAnchorUTF16Offset)
        setSelectedRange(NSRange(location: location, length: length))
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchorUTF16Offset = nil
        super.mouseUp(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        true
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return selectedRange.length > 0
        case #selector(selectAll(_:)):
            return textStorage.length > 0
        default:
            return false
        }
    }

    @objc func copy(_ sender: Any?) {
        guard selectedRange.length > 0 else {
            return
        }
        let selectedText = (textStorage.string as NSString).substring(with: selectedRange)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedText, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        setSelectedRange(NSRange(location: 0, length: textStorage.length))
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .staticText
    }

    override func accessibilityValue() -> Any? {
        textStorage.string
    }

    override func accessibilitySelectedText() -> String? {
        guard selectedRange.length > 0 else {
            return nil
        }
        return (textStorage.string as NSString).substring(with: selectedRange)
    }

    private func invalidateTextLayout(measureEstimatedHeightImmediately: Bool) {
        invalidateTextLayout(in: NSRange(location: 0, length: textStorage.length), measureEstimatedHeightImmediately: measureEstimatedHeightImmediately)
    }

    private func invalidateTextLayout(
        in characterRange: NSRange,
        measureEstimatedHeightImmediately: Bool
    ) {
        let clampedRange = clamp(characterRange)
        if let textRange = textRange(for: clampedRange) {
            textLayoutManager.invalidateLayout(for: textRange)
        } else {
            textLayoutManager.invalidateLayout(for: textContentStorage.documentRange)
        }
        needsViewportLayout = true
        lastViewportLayoutBounds = nil
        if measureEstimatedHeightImmediately {
            updateEstimatedDocumentHeight()
            onLayoutInvalidated?()
        }
        needsLayout = true
        needsDisplay = true
        layoutTextViewport()
    }

    private func appendInvalidationStartUTF16Offset() -> Int {
        let string = textStorage.string as NSString
        guard string.length > 0 else {
            return 0
        }

        let lastCharacter = string.character(at: string.length - 1)
        if lastCharacter == 10 || lastCharacter == 13 {
            return string.length
        }

        return string.paragraphRange(for: NSRange(location: string.length - 1, length: 0)).location
    }

    @discardableResult
    private func syncTextContainerSize() -> Bool {
        let targetWidth = max(0, preferredTextContainerWidth - textContainerInset.width * 2)
        let targetSize = NSSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)
        guard abs(textContainer.size.width - targetSize.width) > 0.5 ||
              textContainer.size.height != targetSize.height
        else {
            return false
        }
        textContainer.size = targetSize
        textLayoutManager.invalidateLayout(for: textContentStorage.documentRange)
        needsViewportLayout = true
        lastViewportLayoutBounds = nil
        return true
    }

    @discardableResult
    private func updateEstimatedDocumentHeight() -> Bool {
        let measuredHeight = measuredDocumentHeight()
        guard abs(measuredHeight - estimatedDocumentHeight) > 0.5 else {
            return false
        }
        estimatedDocumentHeight = measuredHeight
        invalidateIntrinsicContentSize()
        return true
    }

    private func measuredDocumentHeight() -> CGFloat {
        guard textStorage.length > 0 else {
            return ceil(textContainerInset.height * 2)
        }

        let documentRange = textContentStorage.documentRange
        var maxY: CGFloat = 0

        let documentEndLocation = documentRange.endLocation
        textLayoutManager.enumerateTextLayoutFragments(
            from: documentEndLocation,
            options: [.reverse, .ensuresLayout, .ensuresExtraLineFragment]
        ) { layoutFragment in
            maxY = max(maxY, layoutFragment.layoutFragmentFrame.maxY)
            return false
        }

        let endRange = NSTextRange(location: documentEndLocation)
        textLayoutManager.ensureLayout(for: endRange)
        textLayoutManager.enumerateTextSegments(
            in: endRange,
            type: .standard,
            options: .middleFragmentsExcluded
        ) { _, rect, _, _ in
            maxY = max(maxY, rect.maxY)
            return true
        }

        return ceil(max(0, maxY) + textContainerInset.height * 2)
    }

    private func updateSelectionRects() {
        guard selectedRange.length > 0,
              let textRange = textRange(for: selectedRange)
        else {
            selectionView.selectionRects = []
            return
        }

        textLayoutManager.ensureLayout(for: textRange)
        var rects: [NSRect] = []
        textLayoutManager.enumerateTextSegments(
            in: textRange,
            type: .selection,
            options: []
        ) { _, rect, _, _ in
            rects.append(rect.offsetBy(dx: textContainerInset.width, dy: textContainerInset.height))
            return true
        }
        selectionView.selectionRects = rects
    }

    private func syncContentSubviewFrames() {
        textContentView.frame = bounds
        selectionView.frame = textContentView.bounds
        fragmentViewportView.frame = textContentView.bounds
    }

    private func utf16Offset(at point: NSPoint) -> Int {
        guard textStorage.length > 0 else {
            return 0
        }

        let textPoint = NSPoint(
            x: max(0, point.x - textContainerInset.width),
            y: max(0, point.y - textContainerInset.height)
        )
        let selections = textLayoutManager.textSelectionNavigation.textSelections(
            interactingAt: textPoint,
            inContainerAt: textContentStorage.documentRange.location,
            anchors: [],
            modifiers: [],
            selecting: false,
            bounds: textLayoutManager.usageBoundsForTextContainer
        )
        guard let textRange = selections.first?.textRanges.first else {
            return point.y >= estimatedDocumentHeight ? textStorage.length : 0
        }
        return clampUTF16Offset(nsRange(for: textRange).location)
    }

    private func wordRange(containing offset: Int) -> NSRange {
        let string = textStorage.string as NSString
        guard string.length > 0 else {
            return NSRange(location: 0, length: 0)
        }
        let location = min(offset, string.length - 1)
        let characters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-./:"))
        var start = location
        while start > 0 {
            let scalar = UnicodeScalar(string.character(at: start - 1))
            guard let scalar, characters.contains(scalar) else {
                break
            }
            start -= 1
        }

        var end = location
        while end < string.length {
            let scalar = UnicodeScalar(string.character(at: end))
            guard let scalar, characters.contains(scalar) else {
                break
            }
            end += 1
        }

        if start == end {
            return NSRange(location: location, length: 0)
        }
        return NSRange(location: start, length: end - start)
    }

    private func clampSelectedRange() {
        selectedRange = clamp(selectedRange)
        updateSelectionRects()
    }

    private func clamp(_ range: NSRange) -> NSRange {
        let location = clampUTF16Offset(range.location)
        let upperBound = min(textStorage.length, range.location + range.length)
        return NSRange(location: location, length: max(0, upperBound - location))
    }

    private func clampUTF16Offset(_ offset: Int) -> Int {
        min(max(0, offset), textStorage.length)
    }

    private func textRange(for range: NSRange) -> NSTextRange? {
        let clampedRange = clamp(range)
        guard let startLocation = textContentStorage.location(
            textContentStorage.documentRange.location,
            offsetBy: clampedRange.location
        ),
            let endLocation = textContentStorage.location(
                startLocation,
                offsetBy: clampedRange.length
            )
        else {
            return nil
        }
        return NSTextRange(location: startLocation, end: endLocation)
    }

    private func nsRange(for textRange: NSTextRange) -> NSRange {
        let location = textContentStorage.offset(
            from: textContentStorage.documentRange.location,
            to: textRange.location
        )
        let length = textContentStorage.offset(
            from: textRange.location,
            to: textRange.endLocation
        )
        return clamp(NSRange(location: location, length: length))
    }

    func viewportBounds(for textViewportLayoutController: NSTextViewportLayoutController) -> CGRect {
        currentViewportBounds()
    }

    private func currentViewportBounds() -> CGRect {
        var visible = usableViewportRect(visibleBoundsForViewportLayout())
        var prepared = usableViewportRect(preparedContentRect)

        if prepared.isEmpty {
            prepared = visible
        }

        visible = textLayoutRect(fromContentRect: visible)
        prepared = textLayoutRect(fromContentRect: prepared)

        let yRange: (minY: CGFloat, maxY: CGFloat)
        if prepared.intersects(visible) {
            yRange = (
                minY: max(0, min(prepared.minY, visible.minY)),
                maxY: max(prepared.maxY, visible.maxY)
            )
        } else {
            yRange = (minY: visible.minY, maxY: visible.maxY)
        }

        return CGRect(
            x: 0,
            y: yRange.minY,
            width: max(textContainer.size.width, visible.width),
            height: max(0, yRange.maxY - yRange.minY)
        )
    }

    private func visibleBoundsForViewportLayout() -> NSRect {
        if let clipView = superview as? NSClipView {
            let bounds = clipView.bounds
            if isUsableViewportRect(bounds) {
                return bounds
            }
        }
        if isUsableViewportRect(visibleRect) {
            return visibleRect
        }
        return bounds
    }

    private func textLayoutRect(fromContentRect rect: NSRect) -> NSRect {
        var textRect = rect
        if textRect.minX < 0 {
            textRect.size.width += textRect.minX
            textRect.origin.x = 0
        }
        if textRect.minY < 0 {
            textRect.size.height += textRect.minY
            textRect.origin.y = 0
        }
        textRect.origin.x = max(0, textRect.origin.x - textContainerInset.width)
        textRect.origin.y = max(0, textRect.origin.y - textContainerInset.height)
        textRect.size.width = max(0, textRect.width - textContainerInset.width * 2)
        textRect.size.height = max(0, textRect.height - textContainerInset.height * 2)
        return textRect
    }

    private func usableViewportRect(_ rect: NSRect) -> NSRect {
        guard isUsableViewportRect(rect) else {
            return .zero
        }
        return rect
    }

    private func isUsableViewportRect(_ rect: NSRect) -> Bool {
        rect.minX.isFinite &&
            rect.minY.isFinite &&
            rect.width.isFinite &&
            rect.height.isFinite &&
            abs(rect.minX) < 1_000_000_000 &&
            abs(rect.minY) < 1_000_000_000 &&
            rect.width >= 0 &&
            rect.height >= 0
    }

    func textViewportLayoutControllerWillLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
        lastUsedFragmentViews = visibleFragmentViews
    }

    func textViewportLayoutController(
        _ textViewportLayoutController: NSTextViewportLayoutController,
        configureRenderingSurfaceFor textLayoutFragment: NSTextLayoutFragment
    ) {
        let layoutFragmentFrame = textLayoutFragment.layoutFragmentFrame.offsetBy(
            dx: textContainerInset.width,
            dy: textContainerInset.height
        )
        let fragmentView: ReviewMonitorLogFragmentView
        if let cachedFragmentView = fragmentViewMap.object(forKey: textLayoutFragment) {
            fragmentView = cachedFragmentView
            lastUsedFragmentViews.remove(cachedFragmentView)
        } else {
            fragmentView = ReviewMonitorLogFragmentView(
                layoutFragment: textLayoutFragment,
                frame: backingAlignedRect(layoutFragmentFrame, options: .alignAllEdgesOutward)
            )
            fragmentViewMap.setObject(fragmentView, forKey: textLayoutFragment)
        }

        let alignedFrame = backingAlignedRect(layoutFragmentFrame, options: .alignAllEdgesOutward)
        if rectsAreNearlyEqual(fragmentView.frame, alignedFrame) == false {
            fragmentView.frame = alignedFrame
            fragmentView.needsDisplay = true
        }

        if fragmentView.superview !== fragmentViewportView {
            fragmentViewportView.addSubview(fragmentView)
        }
        visibleFragmentViews.insert(fragmentView)
    }

    func textViewportLayoutControllerDidLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
        for staleView in lastUsedFragmentViews {
            staleView.removeFromSuperview()
            visibleFragmentViews.remove(staleView)
        }
        lastUsedFragmentViews.removeAll()
        syncContentSubviewFrames()
        if let viewportRange = textViewportLayoutController.viewportRange {
            textLayoutManager.ensureLayout(for: viewportRange)
        }
        let heightChanged = updateEstimatedDocumentHeight()
        if heightChanged {
            onLayoutInvalidated?()
        }
        updateSelectionRects()
    }

    private func rectsAreNearlyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 0.5 &&
            abs(lhs.minY - rhs.minY) <= 0.5 &&
            abs(lhs.width - rhs.width) <= 0.5 &&
            abs(lhs.height - rhs.height) <= 0.5
    }

    private func sizesAreNearlyEqual(_ lhs: NSSize, _ rhs: NSSize) -> Bool {
        abs(lhs.width - rhs.width) <= 0.5 &&
            abs(lhs.height - rhs.height) <= 0.5
    }

    private func edgeInsetsAreNearlyEqual(_ lhs: NSEdgeInsets, _ rhs: NSEdgeInsets) -> Bool {
        abs(lhs.top - rhs.top) <= 0.5 &&
            abs(lhs.left - rhs.left) <= 0.5 &&
            abs(lhs.bottom - rhs.bottom) <= 0.5 &&
            abs(lhs.right - rhs.right) <= 0.5
    }
}

@MainActor
private class ReviewMonitorLogTiledContentView: NSView {
    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func makeBackingLayer() -> CALayer {
        CATiledLayer()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
private final class ReviewMonitorLogContentView: ReviewMonitorLogTiledContentView {}

@MainActor
private final class ReviewMonitorLogContentViewportView: ReviewMonitorLogTiledContentView {}

@MainActor
private final class ReviewMonitorLogFragmentView: NSView {
    var layoutFragment: NSTextLayoutFragment {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    init(layoutFragment: NSTextLayoutFragment, frame: NSRect) {
        self.layoutFragment = layoutFragment
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        context.saveGState()
        layoutFragment.draw(at: .zero, in: context)
        context.restoreGState()
    }
}

@MainActor
private final class ReviewMonitorLogSelectionView: NSView {
    var selectionRects: [NSRect] = [] {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard selectionRects.isEmpty == false else {
            return
        }
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35).setFill()
        for rect in selectionRects where rect.intersects(dirtyRect) {
            rect.fill()
        }
    }
}

@MainActor
private final class ReviewMonitorLogTextFinderBarContainer: NSObject, @preconcurrency NSTextFinderBarContainer {
    weak var scrollView: NSScrollView?
    weak var finderContentView: NSView?

    var findBarView: NSView? {
        get {
            scrollView?.findBarView
        }
        set {
            scrollView?.findBarView = newValue
        }
    }

    var isFindBarVisible: Bool {
        get {
            scrollView?.isFindBarVisible ?? false
        }
        set {
            scrollView?.isFindBarVisible = newValue
        }
    }

    func contentView() -> NSView? {
        finderContentView
    }

    func findBarViewDidChangeHeight() {
        scrollView?.findBarViewDidChangeHeight()
    }
}

@MainActor
@objcMembers
private final class ReviewMonitorLogTextFinderClient: NSObject, @preconcurrency NSTextFinderClient {
    weak var documentView: ReviewMonitorLogDocumentView?

    var string: String {
        documentView?.string ?? ""
    }

    func stringLength() -> Int {
        documentView?.stringLength ?? 0
    }

    var isSelectable: Bool {
        true
    }

    var isEditable: Bool {
        false
    }

    var allowsMultipleSelection: Bool {
        false
    }

    func shouldReplaceCharacters(inRanges ranges: [NSValue], with strings: [String]) -> Bool {
        false
    }

    var firstSelectedRange: NSRange {
        selectedRanges.first?.rangeValue ?? NSRange(location: 0, length: 0)
    }

    var selectedRanges: [NSValue] {
        get {
            guard let documentView else {
                return []
            }
            return [NSValue(range: documentView.selectedRangeForFinding)]
        }
        set {
            guard let range = newValue.first?.rangeValue else {
                return
            }
            documentView?.setSelectedRange(range)
        }
    }

    func scrollRangeToVisible(_ range: NSRange) {
        documentView?.scrollRangeToVisible(range)
    }

    var visibleCharacterRanges: [NSValue] {
        documentView?.visibleCharacterRanges() ?? []
    }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        documentView?.rects(forCharacterRange: range)
    }

    func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
        guard let documentView else {
            outRange.pointee = NSRange(location: 0, length: 0)
            return NSView()
        }
        outRange.pointee = NSRange(location: 0, length: documentView.stringLength)
        return documentView.finderContentView
    }

    func drawCharacters(in range: NSRange, forContentView view: NSView) {
        documentView?.drawCharacters(in: range, forContentView: view)
    }
}

#if DEBUG
@MainActor
extension ReviewMonitorLogScrollView {
    var displayedTextForTesting: String {
        displayedText
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

    var findVisibleCharacterRangesForTesting: [NSRange] {
        textFinderClient.visibleCharacterRanges.map(\.rangeValue)
    }

    var findStringLengthForTesting: Int {
        textFinderClient.stringLength()
    }

    var findClientStringWillChangeCountForTesting: Int {
        findClientStringWillChangeCount
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

    var findFeedbackDimmingEnabledForTesting: Bool {
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
        logDocumentView.layoutTextViewport()
        return logDocumentView.visibleFragmentViewCountForTesting
    }

    var visibleFragmentBoundsForTesting: NSRect {
        logDocumentView.layoutTextViewport()
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

    func selectAllForTesting() {
        logDocumentView.selectAll(nil)
    }

    func setSelectedLogRangeForTesting(_ range: NSRange) {
        logDocumentView.setSelectedRange(range)
    }

    @discardableResult
    func renderForTesting(text: String, allowIncrementalUpdate: Bool) -> Bool {
        render(text: text, restoring: currentScrollRestorationTarget, allowIncrementalUpdate: allowIncrementalUpdate)
    }

    func copySelectionForTesting() {
        logDocumentView.copy(nil)
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

@MainActor
private extension ReviewMonitorLogDocumentView {
    var selectedRangeForTesting: NSRange {
        selectedRange
    }

    var usesTextKit2ForTesting: Bool {
        textLayoutManager.textContainer === textContainer &&
            textContentStorage.textLayoutManagers.contains(textLayoutManager)
    }

    var hitTestTargetsDocumentViewForTesting: Bool {
        guard bounds.isEmpty == false else {
            return false
        }
        syncContentSubviewFrames()
        let point = NSPoint(x: bounds.midX, y: bounds.midY)
        return hitTest(point) === self
    }

    var visibleFragmentViewCountForTesting: Int {
        visibleFragmentViews.count
    }

    var visibleFragmentBoundsForTesting: NSRect {
        guard let firstFragmentView = visibleFragmentViews.first else {
            return .zero
        }
        return visibleFragmentViews.reduce(firstFragmentView.frame) { bounds, fragmentView in
            bounds.union(fragmentView.frame)
        }
    }

    var staleFragmentViewCountForTesting: Int {
        lastUsedFragmentViews.filter { $0.superview != nil }.count
    }
}
#endif
