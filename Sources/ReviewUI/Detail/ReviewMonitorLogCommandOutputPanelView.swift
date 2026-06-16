import AppKit
import TextTransitions

@MainActor
class ReviewMonitorLogTiledContentView: NSView {
    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    fileprivate func hitTestInteractiveSubviews(at point: NSPoint) -> NSView? {
        guard isHidden == false,
              alphaValue > 0,
              bounds.contains(point)
        else {
            return nil
        }

        for subview in subviews.reversed() {
            let subviewPoint = convert(point, to: subview)
            if let hitView = subview.hitTest(subviewPoint) {
                return hitView
            }
        }
        return nil
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
final class ReviewMonitorLogContentView: ReviewMonitorLogTiledContentView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        hitTestInteractiveSubviews(at: point)
    }
}

@MainActor
final class ReviewMonitorLogContentViewportView: ReviewMonitorLogTiledContentView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        hitTestInteractiveSubviews(at: point)
    }
}

@MainActor
private final class ReviewMonitorCommandOutputScrollView: NSScrollView {}

final class ReviewMonitorCommandOutputToggleAttachment: NSTextAttachment {
    let blockID: ReviewMonitorLogBlockID
    let isExpanded: Bool
    let symbolSize: CGFloat
    let fontPointSize: CGFloat
    let slotWidth: CGFloat

    var symbolName: String {
        isExpanded ? "chevron.down" : "chevron.forward"
    }

    init(blockID: ReviewMonitorLogBlockID, isExpanded: Bool, font: NSFont) {
        self.blockID = blockID
        self.isExpanded = isExpanded
        self.symbolSize = ceil(font.pointSize + 1)
        self.fontPointSize = font.pointSize
        self.slotWidth = ReviewMonitorCommandOutputPanelView.chevronSlotWidth(for: font)
        super.init(data: nil, ofType: nil)

        allowsTextAttachmentView = true
        lineLayoutPadding = 0
        bounds = CGRect(
            x: 0,
            y: floor(font.descender + ((font.ascender - font.descender) - symbolSize) / 2),
            width: slotWidth,
            height: symbolSize
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        position: CGPoint
    ) -> CGRect {
        bounds
    }

    override func viewProvider(
        for parentView: NSView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        ReviewMonitorCommandOutputToggleAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: nil,
            location: location
        )
    }

    override func image(
        for bounds: CGRect,
        attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSImage? {
        Self.transparentImage
    }

    private static let transparentImage: NSImage = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return image
    }()
}

final class ReviewMonitorCommandOutputTimerAttachment: NSTextAttachment {
    let blockID: ReviewMonitorLogBlockID
    let startedAt: Date
    let fontPointSize: CGFloat
    let animatesNumericTransition: Bool

    init(
        blockID: ReviewMonitorLogBlockID,
        startedAt: Date,
        font: NSFont,
        animatesNumericTransition: Bool = true
    ) {
        self.blockID = blockID
        self.startedAt = startedAt
        self.fontPointSize = font.pointSize
        self.animatesNumericTransition = animatesNumericTransition
        super.init(data: nil, ofType: nil)

        allowsTextAttachmentView = true
        lineLayoutPadding = 0
        let size = Self.attachmentSize(font: font)
        bounds = CGRect(
            x: 0,
            y: floor(font.descender),
            width: size.width,
            height: size.height
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        position: CGPoint
    ) -> CGRect {
        bounds
    }

    override func viewProvider(
        for parentView: NSView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        ReviewMonitorCommandOutputTimerAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: nil,
            location: location
        )
    }

    override func image(
        for bounds: CGRect,
        attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSImage? {
        Self.transparentImage
    }

    private static func attachmentSize(font: NSFont) -> NSSize {
        let timerFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        let sample = " for 00:00:00"
        let width = sample.reduce(CGFloat.zero) { partialResult, character in
            let characterWidth = (String(character) as NSString)
                .size(withAttributes: [.font: timerFont])
                .width
            return partialResult + ceil(characterWidth)
        }
        let height = ceil(font.ascender - font.descender)
        return NSSize(width: width, height: height)
    }

    private static let transparentImage: NSImage = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return image
    }()
}

@MainActor
final class ReviewMonitorCommandOutputToggleAttachmentViewProvider: NSTextAttachmentViewProvider {
    private var button: ReviewMonitorCommandOutputToggleButton?

    func configureView() -> ReviewMonitorCommandOutputToggleButton? {
        guard let attachment = textAttachment as? ReviewMonitorCommandOutputToggleAttachment else {
            return nil
        }
        if let button {
            button.configure(attachment: attachment)
            return button
        }
        let button = ReviewMonitorCommandOutputToggleButton(attachment: attachment)
        button.configure(attachment: attachment)
        self.button = button
        return button
    }
}

@MainActor
final class ReviewMonitorCommandOutputTimerAttachmentViewProvider: NSTextAttachmentViewProvider {
    private var timerView: ReviewMonitorCommandOutputTimerAttachmentView?

    func configureView() -> ReviewMonitorCommandOutputTimerAttachmentView? {
        guard let attachment = textAttachment as? ReviewMonitorCommandOutputTimerAttachment else {
            return nil
        }
        if let timerView {
            timerView.configure(attachment: attachment)
            return timerView
        }
        let timerView = ReviewMonitorCommandOutputTimerAttachmentView(attachment: attachment)
        timerView.configure(attachment: attachment)
        self.timerView = timerView
        return timerView
    }
}

@MainActor
final class ReviewMonitorCommandOutputTimerAttachmentView: NSView {
    private nonisolated static let minimumTimerInterval: TimeInterval = 0.05

    private(set) var blockID: ReviewMonitorLogBlockID
    private var startedAt: Date
    private var timerFont: NSFont
    private var attachmentSize: NSSize
    private var animatesNumericTransition: Bool
    private var updateTimer: Timer?
    private var displayedText = ""
    private let textTransitionView: TextTransitionView

    override var isFlipped: Bool {
        true
    }

    init(attachment: ReviewMonitorCommandOutputTimerAttachment) {
        self.blockID = attachment.blockID
        self.startedAt = attachment.startedAt
        self.timerFont = .monospacedDigitSystemFont(
            ofSize: attachment.fontPointSize,
            weight: .regular
        )
        self.attachmentSize = attachment.bounds.size
        self.animatesNumericTransition = attachment.animatesNumericTransition
        self.textTransitionView = TextTransitionView(
            text: NSAttributedString(string: ""),
            contentTransition: .numericText(countsDown: false),
            widthReservation: .fixed(attachment.bounds.size),
            motionPolicy: .enabled
        )
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        textTransitionView.setAccessibilityElement(false)
        addSubview(textTransitionView)
        configure(attachment: attachment)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        stopTimer()
    }

    override var intrinsicContentSize: NSSize {
        attachmentSize
    }

    override func layout() {
        super.layout()
        textTransitionView.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        textTransitionView.setText(attributedString(for: displayedText), animated: false)
    }

    func configure(attachment: ReviewMonitorCommandOutputTimerAttachment) {
        let nextFont = NSFont.monospacedDigitSystemFont(
            ofSize: attachment.fontPointSize,
            weight: .regular
        )
        let nextAttachmentSize = attachment.bounds.size
        let identityChanged = blockID != attachment.blockID ||
            startedAt != attachment.startedAt
        let numericTransitionDisabled = animatesNumericTransition &&
            attachment.animatesNumericTransition == false
        let viewConfigurationChanged = timerFont.pointSize != nextFont.pointSize ||
            attachmentSize != nextAttachmentSize ||
            animatesNumericTransition != attachment.animatesNumericTransition
        blockID = attachment.blockID
        startedAt = attachment.startedAt
        timerFont = nextFont
        attachmentSize = nextAttachmentSize
        animatesNumericTransition = attachment.animatesNumericTransition
        if identityChanged {
            stopTimer()
            completeNumericTransitions()
            displayedText = ""
        }
        if numericTransitionDisabled {
            completeNumericTransitions()
        }
        if identityChanged || viewConfigurationChanged {
            textTransitionView.contentTransition = .numericText(countsDown: false)
            textTransitionView.widthReservation = .fixed(attachmentSize)
            textTransitionView.motionPolicy = .enabled
        }
        invalidateIntrinsicContentSize()
        if displayedText.isEmpty {
            updateText(animated: false)
        } else if identityChanged || viewConfigurationChanged {
            textTransitionView.setText(attributedString(for: displayedText), animated: false)
        }
        if superview != nil {
            scheduleNextTickIfNeeded()
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil {
            stopTimer()
        } else {
            updateText(animated: false)
            scheduleNextTick()
        }
    }

    private func scheduleNextTickIfNeeded() {
        guard updateTimer == nil else {
            return
        }
        scheduleNextTick()
    }

    private func scheduleNextTick() {
        stopTimer()
        guard superview != nil else {
            return
        }
        let now = Date()
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        let nextElapsedSecond = floor(elapsed) + 1
        let interval = max(Self.minimumTimerInterval, nextElapsedSecond - elapsed)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.updateText()
                self.scheduleNextTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    private func stopTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    func updateText(referenceDate: Date = Date(), animated: Bool = true) {
        let elapsedSeconds = max(0, Int(referenceDate.timeIntervalSince(startedAt).rounded(.down)))
        let nextText = " for \(Self.durationText(seconds: elapsedSeconds))"
        guard nextText != displayedText else {
            return
        }
        let previousText = displayedText.isEmpty ? nil : displayedText
        displayedText = nextText
        updateAccessibilityText()
        textTransitionView.setText(
            attributedString(for: nextText),
            animated: animated && shouldAnimateNumericTransition && previousText != nil
        )
    }

    private func updateAccessibilityText() {
        let accessibilityText = displayedText.trimmingCharacters(in: .whitespacesAndNewlines)
        setAccessibilityLabel(accessibilityText)
        setAccessibilityValue(accessibilityText)
    }

    private var shouldAnimateNumericTransition: Bool {
        guard animatesNumericTransition else {
            return false
        }
        if let documentView = nearestSuperview(of: ReviewMonitorLogDocumentView.self) {
            return documentView.shouldAnimateCommandOutputPanelTransitions
        }
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false
    }

    private static func durationText(seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes < 60 {
            return remainingSeconds == 0 ? "\(minutes)m" : "\(minutes)m \(remainingSeconds)s"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }

    private func attributedString(for text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: timerFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
    }

    private func completeNumericTransitions() {
        textTransitionView.completeTransitions()
    }

#if DEBUG
    var displayedTextForTesting: String {
        displayedText
    }

    var renderedTextWidthForTesting: CGFloat {
        textTransitionView.renderedTextWidthForTesting
    }

    var activeNumericTransitionCountForTesting: Int {
        textTransitionView.activeTransitionCountForTesting
    }

    func completeNumericTransitionsForTesting() {
        completeNumericTransitions()
    }
#endif
}

final class ReviewMonitorCommandOutputPanelAttachment: NSTextAttachment {
    let blockID: ReviewMonitorLogBlockID
    let panel: ReviewMonitorLogCommandOutputPanel
    let outputLineHeight: CGFloat

    init(
        panel: ReviewMonitorLogCommandOutputPanel,
        outputLineHeight: CGFloat
    ) {
        self.blockID = panel.blockID
        self.panel = panel
        self.outputLineHeight = outputLineHeight
        super.init(data: nil, ofType: nil)

        allowsTextAttachmentView = true
        lineLayoutPadding = 0
        bounds = .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        position: CGPoint
    ) -> CGRect {
        let availableWidth = max(0, lineFrag.maxX - position.x)
        guard panel.isExpanded else {
            return CGRect(x: 0, y: 0, width: availableWidth, height: 0)
        }
        let proposedSize = ReviewMonitorCommandOutputPanelView.proposedSize(
            for: panel,
            width: availableWidth,
            outputLineHeight: outputLineHeight
        )
        return CGRect(
            x: 0,
            y: 0,
            width: proposedSize.width,
            height: ReviewMonitorCommandOutputPanelAttachmentView.outerHeight(cardHeight: proposedSize.height)
        )
    }

    override func viewProvider(
        for parentView: NSView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        let provider = ReviewMonitorCommandOutputPanelAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: nil,
            location: location
        )
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }

    override func image(
        for bounds: CGRect,
        attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSImage? {
        Self.transparentImage
    }

    private static let transparentImage: NSImage = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return image
    }()
}

@MainActor
final class ReviewMonitorCommandOutputPanelAttachmentViewProvider: NSTextAttachmentViewProvider {
    private var panelView: ReviewMonitorCommandOutputPanelAttachmentView?

    func configureView(
        backgroundAlpha: CGFloat
    ) -> ReviewMonitorCommandOutputPanelAttachmentView? {
        guard let attachment = textAttachment as? ReviewMonitorCommandOutputPanelAttachment else {
            return nil
        }
        if let panelView {
            panelView.configure(attachment: attachment, backgroundAlpha: backgroundAlpha)
            return panelView
        }
        let panelView = ReviewMonitorCommandOutputPanelAttachmentView(attachment: attachment)
        panelView.configure(attachment: attachment, backgroundAlpha: backgroundAlpha)
        self.panelView = panelView
        return panelView
    }
}

@MainActor
final class ReviewMonitorCommandOutputToggleButton: NSButton {
    private(set) var blockID: ReviewMonitorLogBlockID
    private(set) var isExpanded: Bool
    private var buttonSize: NSSize

    init(attachment: ReviewMonitorCommandOutputToggleAttachment) {
        self.blockID = attachment.blockID
        self.isExpanded = attachment.isExpanded
        self.buttonSize = NSSize(width: attachment.slotWidth, height: attachment.symbolSize)
        super.init(frame: NSRect(origin: .zero, size: buttonSize))

        title = ""
        setButtonType(.pushOnPushOff)
        bezelStyle = .disclosure
        focusRingType = .none
        target = self
        action = #selector(toggleCommandOutputPanel(_:))
        configure(attachment: attachment)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(attachment: ReviewMonitorCommandOutputToggleAttachment) {
        blockID = attachment.blockID
        isExpanded = attachment.isExpanded
        buttonSize = NSSize(width: attachment.slotWidth, height: attachment.symbolSize)
        frame.size = buttonSize
        invalidateIntrinsicContentSize()
        state = isExpanded ? .on : .off

        let accessibilityLabel = isExpanded
            ? "Collapse command output"
            : "Expand command output"
        toolTip = accessibilityLabel
        setAccessibilityLabel(accessibilityLabel)
    }

    override var intrinsicContentSize: NSSize {
        buttonSize
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    @objc private func toggleCommandOutputPanel(_ sender: ReviewMonitorCommandOutputToggleButton) {
        guard let documentView = sender.nearestSuperview(of: ReviewMonitorLogDocumentView.self) else {
            return
        }
        documentView.onCommandOutputPanelToggle?(sender.blockID)
    }
}

private extension NSView {
    func nearestSuperview<View: NSView>(of type: View.Type) -> View? {
        var view: NSView? = self
        while let currentView = view {
            if let typedView = currentView as? View {
                return typedView
            }
            view = currentView.superview
        }
        return nil
    }
}

@MainActor
final class ReviewMonitorCommandOutputPanelAttachmentView: NSView {
    private nonisolated static let topGap = ReviewMonitorCommandOutputPanelView.headerToCardGap

    private let backgroundView = NSVisualEffectView()
    private let panelView: ReviewMonitorCommandOutputPanelView
    private var backgroundAlpha: CGFloat = 0
    private(set) var blockID: ReviewMonitorLogBlockID

    override var isFlipped: Bool {
        true
    }

    init(attachment: ReviewMonitorCommandOutputPanelAttachment) {
        self.blockID = attachment.blockID
        self.panelView = ReviewMonitorCommandOutputPanelView(blockID: attachment.blockID)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        backgroundView.material = .contentBackground
        backgroundView.blendingMode = .withinWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 8
        backgroundView.layer?.masksToBounds = true
        addSubview(backgroundView)
        addSubview(panelView)
        configure(attachment: attachment, backgroundAlpha: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    nonisolated static func outerHeight(cardHeight: CGFloat) -> CGFloat {
        topGap + cardHeight
    }

    func configure(
        attachment: ReviewMonitorCommandOutputPanelAttachment,
        backgroundAlpha: CGFloat
    ) {
        let panelChanged = panelView.configure(attachment.panel)
        let blockIDChanged = blockID != attachment.blockID
        let backgroundChanged = abs(self.backgroundAlpha - backgroundAlpha) > 0.001
        guard panelChanged || blockIDChanged || backgroundChanged else {
            return
        }

        blockID = attachment.blockID
        if backgroundChanged {
            setBackgroundAlpha(backgroundAlpha)
        }
        needsLayout = true
    }

    func setBackgroundAlpha(_ alpha: CGFloat) {
        guard abs(backgroundAlpha - alpha) > 0.001 else {
            return
        }
        backgroundAlpha = alpha
        backgroundView.alphaValue = alpha
    }

    override func layout() {
        super.layout()
        let contentFrame = NSRect(
            x: 0,
            y: Self.topGap,
            width: bounds.width,
            height: max(0, bounds.height - Self.topGap)
        )
        backgroundView.frame = contentFrame
        panelView.frame = contentFrame
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isHidden == false,
              alphaValue > 0,
              bounds.contains(point),
              panelView.frame.contains(point)
        else {
            return nil
        }
        return panelView.hitTest(convert(point, to: panelView))
    }

    func rects(
        forTerminalRange range: NSRange,
        convertedTo targetView: NSView
    ) -> [NSRect] {
        prepareForRangeQueries()
        return panelView.rects(forTerminalRange: range, convertedTo: targetView)
    }

    func scrollTerminalRangeToVisible(_ range: NSRange) {
        prepareForRangeQueries()
        panelView.scrollTerminalRangeToVisible(range)
    }

    func drawTerminalCharacters(in range: NSRange, forContentView view: NSView) {
        prepareForRangeQueries()
        panelView.drawTerminalCharacters(in: range, forContentView: view)
    }

    private func prepareForRangeQueries() {
        layoutSubtreeIfNeeded()
    }

#if DEBUG
    private func prepareForTesting() {
        layoutSubtreeIfNeeded()
    }

    var outputScrollUsesHorizontalScrollingForTesting: Bool {
        panelView.outputScrollUsesHorizontalScrollingForTesting
    }

    var usesTextKit2ForTesting: Bool {
        prepareForTesting()
        return panelView.usesTextKit2ForTesting
    }

    var usesSystemMaterialBackgroundForTesting: Bool {
        prepareForTesting()
        return backgroundView.material == .contentBackground &&
            backgroundView.blendingMode == .withinWindow &&
            backgroundView.state == .active
    }

    var visibleLineCapacityForTesting: Int {
        prepareForTesting()
        return panelView.visibleLineCapacityForTesting
    }

    var resultTextForTesting: String {
        prepareForTesting()
        return panelView.resultTextForTesting
    }

    var terminalTextForTesting: String {
        prepareForTesting()
        return panelView.terminalTextForTesting
    }

    var commandLineTextForTesting: String {
        prepareForTesting()
        return panelView.commandLineTextForTesting
    }

    var outputScrollTextForTesting: String {
        prepareForTesting()
        return panelView.outputScrollTextForTesting
    }

    var outputScrollIsScrollableForTesting: Bool {
        prepareForTesting()
        return panelView.outputScrollIsScrollableForTesting
    }

    var outputScrollVerticalOffsetForTesting: CGFloat {
        prepareForTesting()
        return panelView.outputScrollVerticalOffsetForTesting
    }

    var outputScrollMaximumVerticalOffsetForTesting: CGFloat {
        prepareForTesting()
        return panelView.outputScrollMaximumVerticalOffsetForTesting
    }

    func scrollOutputForTesting(deltaY: CGFloat) -> Bool {
        prepareForTesting()
        return panelView.scrollOutputForTesting(deltaY: deltaY)
    }

    var outputHitTestTargetsTextViewForTesting: Bool {
        prepareForTesting()
        return panelView.outputHitTestTargetsTextViewForTesting
    }
#endif
}

@MainActor
final class ReviewMonitorCommandOutputPanelView: NSView {
    nonisolated static let visibleOutputLineCount = 5
    nonisolated static let headerToCardGap: CGFloat = 6

    private nonisolated static let topInset: CGFloat = 8
    private nonisolated static let bottomInset: CGFloat = 8
    private nonisolated static let horizontalInset: CGFloat = 8
    private nonisolated static let shellToCommandGap: CGFloat = 2
    private nonisolated static let commandToOutputGap: CGFloat = 2
    private nonisolated static let outputToFooterGap: CGFloat = 8
    private nonisolated static let commandLeadingInset: CGFloat = 12
    private nonisolated static let commandTrailingInset: CGFloat = 2

    private let blockID: ReviewMonitorLogBlockID
    private let shellLabel = NSTextField(labelWithString: "Shell")
    private let commandTextView = NSTextView(usingTextLayoutManager: true)
    private let outputScrollView = ReviewMonitorCommandOutputScrollView()
    private let outputTextView = NSTextView(usingTextLayoutManager: true)
    private let resultLabel = NSTextField(labelWithString: "")
    private var panel: ReviewMonitorLogCommandOutputPanel?
    private var terminalText = ""
    private var commandLineText = ""
    private var outputText = ""
    private var outputLineCount = 0
    private var outputMaximumLineUTF16Length = 0
    private var shouldScrollOutputToBottomOnNextLayout = false

    override var isFlipped: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    init(blockID: ReviewMonitorLogBlockID) {
        self.blockID = blockID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        configureLabel(shellLabel)
        shellLabel.font = Self.labelFont(weight: .medium)
        addSubview(shellLabel)

        configureTerminalTextView(commandTextView, textColor: .labelColor, textContainerInset: .zero)
        commandTextView.isHidden = true
        addSubview(commandTextView)

        outputScrollView.drawsBackground = false
        outputScrollView.borderType = .noBorder
        outputScrollView.hasVerticalScroller = true
        outputScrollView.hasHorizontalScroller = true
        outputScrollView.autohidesScrollers = true
        outputScrollView.scrollerStyle = .overlay
        outputScrollView.documentView = outputTextView
        outputScrollView.isHidden = true
        addSubview(outputScrollView)

        configureTerminalTextView(
            outputTextView,
            textColor: .secondaryLabelColor,
            textContainerInset: NSSize(width: 0, height: 2),
            wrapsLines: false
        )

        configureLabel(resultLabel)
        resultLabel.alignment = .right
        addSubview(resultLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    @discardableResult
    func configure(_ panel: ReviewMonitorLogCommandOutputPanel) -> Bool {
        guard self.panel != panel else {
            return false
        }

        let previousPanel = self.panel
        let wasExpanded = previousPanel?.isExpanded == true
        self.panel = panel
        let isExpanded = panel.isExpanded
        shellLabel.isHidden = isExpanded == false
        let nextCommandLineText = Self.commandLineText(for: panel.commandText)
        commandTextView.isHidden = isExpanded == false || nextCommandLineText.isEmpty
        outputScrollView.isHidden = isExpanded == false
        resultLabel.isHidden = isExpanded == false || (panel.exitText?.isEmpty ?? true)
        let outputChanged = previousPanel?.outputText != panel.outputText ||
            outputText != panel.outputText
        let shouldFollowOutput = wasExpanded == false || outputScrollIsPinnedToBottom()
        if isExpanded, wasExpanded == false || (outputChanged && shouldFollowOutput) {
            shouldScrollOutputToBottomOnNextLayout = true
        }

        let nextTerminalText = Self.terminalText(commandLineText: nextCommandLineText, outputText: panel.outputText)
        if previousPanel?.commandText != panel.commandText ||
            commandLineText != nextCommandLineText {
            commandLineText = nextCommandLineText
            commandTextView.textStorage?.setAttributedString(
                Self.terminalAttributedString(
                    text: nextCommandLineText,
                    foregroundColor: .labelColor
                )
            )
        }

        if outputChanged {
            outputText = panel.outputText
            let outputMetrics = ReviewMonitorLogLineCounter.metrics(panel.outputText)
            outputLineCount = outputMetrics.lineCount
            outputMaximumLineUTF16Length = outputMetrics.maximumLineUTF16Length
            outputTextView.textStorage?.setAttributedString(
                Self.terminalAttributedString(
                    text: panel.outputText,
                    foregroundColor: .secondaryLabelColor
                )
            )
        }

        if previousPanel?.commandText != panel.commandText ||
            previousPanel?.outputText != panel.outputText ||
            terminalText != nextTerminalText {
            terminalText = nextTerminalText
        }
        resultLabel.stringValue = panel.exitText ?? ""
        needsLayout = true
        return true
    }

    override func layout() {
        super.layout()
        guard panel?.isExpanded == true else {
            shellLabel.frame = .zero
            commandTextView.frame = .zero
            outputScrollView.frame = .zero
            resultLabel.frame = .zero
            return
        }

        let shellHeight = Self.labelLineHeight(for: shellLabel.font ?? Self.labelFont(weight: .medium))
        let footerHeight = Self.labelLineHeight(for: resultLabel.font ?? Self.labelFont())
        let contentWidth = max(0, bounds.width - Self.horizontalInset * 2)
        let commandWidth = max(0, bounds.width - Self.commandLeadingInset - Self.commandTrailingInset)

        shellLabel.frame = NSRect(
            x: Self.horizontalInset,
            y: Self.topInset,
            width: contentWidth,
            height: shellHeight
        )

        let commandY = Self.topInset + shellHeight + Self.shellToCommandGap
        let commandHeight = Self.commandTextHeight(for: commandLineText, width: commandWidth)
        if commandTextView.isHidden {
            commandTextView.frame = .zero
        } else {
            commandTextView.textContainer?.containerSize = NSSize(
                width: commandWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
            commandTextView.frame = NSRect(
                x: Self.commandLeadingInset,
                y: commandY,
                width: commandWidth,
                height: commandHeight
            )
            commandTextView.minSize = NSSize(width: commandWidth, height: 0)
            commandTextView.maxSize = NSSize(width: commandWidth, height: CGFloat.greatestFiniteMagnitude)
            commandTextView.frame.size.height = commandHeight
            commandTextView.frame.size.width = commandWidth
        }

        let outputY = commandLineText.isEmpty
            ? commandY
            : commandY + commandHeight + Self.commandToOutputGap
        let footerY = max(commandY, bounds.height - Self.bottomInset - footerHeight)
        outputScrollView.frame = NSRect(
            x: Self.commandLeadingInset,
            y: outputY,
            width: commandWidth,
            height: max(0, footerY - outputY - Self.outputToFooterGap)
        )
        let outputWidth = outputScrollView.contentSize.width
        outputTextView.minSize = NSSize(width: outputWidth, height: 0)
        outputTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        let outputDocumentWidth = max(
            outputWidth,
            Self.outputTextWidth(
                maximumLineUTF16Length: outputMaximumLineUTF16Length,
                textContainerInset: outputTextView.textContainerInset
            )
        )
        outputTextView.textContainer?.containerSize = NSSize(
            width: outputDocumentWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        let outputHeight = Self.outputTextHeight(
            minimumLineCount: outputLineCount,
            textContainerInset: outputTextView.textContainerInset,
            lineHeight: outputLineHeight
        )
        outputTextView.frame.size = NSSize(
            width: outputDocumentWidth,
            height: max(
                outputScrollView.contentSize.height,
                outputHeight
            )
        )

        let resultWidth = min(max(70, ceil(resultLabel.intrinsicContentSize.width)), contentWidth)
        resultLabel.frame = NSRect(
            x: Self.horizontalInset + contentWidth - resultWidth,
            y: footerY,
            width: resultWidth,
            height: footerHeight
        )
        scrollOutputToBottomIfNeeded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isHidden == false,
              alphaValue > 0,
              bounds.contains(point)
        else {
            return nil
        }
        if outputScrollView.isHidden == false,
           outputScrollView.frame.contains(point) {
            let scrollPoint = convert(point, to: outputScrollView)
            if let verticalScroller = outputScrollView.verticalScroller,
               verticalScroller.isHidden == false,
               verticalScroller.frame.contains(scrollPoint) {
                return outputScrollView.hitTest(scrollPoint)
            }
            let outputPoint = convert(point, to: outputTextView)
            if outputTextView.bounds.contains(outputPoint) {
                return outputTextView.hitTest(outputPoint)
            }
            return outputScrollView.hitTest(scrollPoint)
        }
        if commandTextView.isHidden == false,
           commandTextView.frame.contains(point) {
            return commandTextView.hitTest(convert(point, to: commandTextView))
        }
        return nil
    }

    func rects(
        forTerminalRange range: NSRange,
        convertedTo targetView: NSView
    ) -> [NSRect] {
        guard panel?.isExpanded == true else {
            return []
        }

        var rects: [NSRect] = []
        for mappedRange in mappedTextViewRanges(forTerminalRange: range) {
            rects.append(contentsOf: textRects(
                forCharacterRange: mappedRange.range,
                in: mappedRange.textView,
                convertedTo: targetView
            ))
        }
        return rects
    }

    func scrollTerminalRangeToVisible(_ range: NSRange) {
        guard panel?.isExpanded == true else {
            return
        }
        for mappedRange in mappedTextViewRanges(forTerminalRange: range) {
            mappedRange.textView.scrollRangeToVisible(mappedRange.range)
        }
    }

    func drawTerminalCharacters(in range: NSRange, forContentView view: NSView) {
        guard panel?.isExpanded == true else {
            return
        }
        for mappedRange in mappedTextViewRanges(forTerminalRange: range) {
            drawCharacters(in: mappedRange.range, textView: mappedRange.textView, forContentView: view)
        }
    }

    private var outputLineHeight: CGFloat {
        let font = outputTextView.font ?? Self.outputFont
        return max(1, ceil(font.ascender - font.descender + font.leading))
    }

    private func outputScrollIsPinnedToBottom() -> Bool {
        let clipView = outputScrollView.contentView
        let maxY = max(0, outputTextView.frame.height - clipView.bounds.height)
        guard maxY > 0 else {
            return true
        }
        return abs(maxY - clipView.bounds.origin.y) <= 0.5
    }

    private func scrollOutputToBottomIfNeeded() {
        guard shouldScrollOutputToBottomOnNextLayout,
              outputScrollView.isHidden == false,
              outputScrollView.contentSize.height > 0
        else {
            return
        }

        let clipView = outputScrollView.contentView
        let maxY = max(0, outputTextView.frame.height - clipView.bounds.height)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: maxY))
        outputScrollView.reflectScrolledClipView(clipView)
        shouldScrollOutputToBottomOnNextLayout = false
    }

    private struct MappedTextViewRange {
        var textView: NSTextView
        var range: NSRange
    }

    private func mappedTextViewRanges(forTerminalRange range: NSRange) -> [MappedTextViewRange] {
        let terminalRange = NSRange(location: 0, length: (terminalText as NSString).length)
        let clampedRange = NSIntersectionRange(range, terminalRange)
        guard clampedRange.length > 0 else {
            return []
        }

        let commandLength = (commandLineText as NSString).length
        let outputFinderText: String
        let outputFinderStart: Int
        let outputTextStart: Int
        if commandLength > 0 {
            outputFinderText = outputText.trimmingCharacters(in: .newlines)
            outputFinderStart = outputFinderText.isEmpty ? commandLength : commandLength + 1
            outputTextStart = Self.leadingNewlineUTF16Length(in: outputText)
        } else {
            outputFinderText = outputText
            outputFinderStart = 0
            outputTextStart = 0
        }

        var ranges: [MappedTextViewRange] = []
        if commandLength > 0 {
            let commandIntersection = NSIntersectionRange(
                clampedRange,
                NSRange(location: 0, length: commandLength)
            )
            if commandIntersection.length > 0 {
                ranges.append(.init(textView: commandTextView, range: commandIntersection))
            }
        }

        let outputFinderLength = (outputFinderText as NSString).length
        if outputFinderLength > 0 {
            let outputIntersection = NSIntersectionRange(
                clampedRange,
                NSRange(location: outputFinderStart, length: outputFinderLength)
            )
            if outputIntersection.length > 0 {
                ranges.append(.init(
                    textView: outputTextView,
                    range: NSRange(
                        location: outputTextStart + outputIntersection.location - outputFinderStart,
                        length: outputIntersection.length
                    )
                ))
            }
        }
        return ranges
    }

    private func textRects(
        forCharacterRange range: NSRange,
        in textView: NSTextView,
        convertedTo targetView: NSView
    ) -> [NSRect] {
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        let targetRange = NSIntersectionRange(range, fullRange)
        guard targetRange.length > 0 else {
            return []
        }

        var rects: [NSRect] = []
        let sourceString = textView.string as NSString
        sourceString.enumerateSubstrings(
            in: targetRange,
            options: [.byLines, .substringNotRequired]
        ) { _, lineRange, _, _ in
            let lineIntersection = NSIntersectionRange(targetRange, lineRange)
            guard lineIntersection.length > 0,
                  let rect = self.textRect(
                      forCharacterRange: lineIntersection,
                      in: textView,
                      convertedTo: targetView
                  )
            else {
                return
            }
            rects.append(rect)
        }

        if rects.isEmpty,
           let rect = textRect(forCharacterRange: targetRange, in: textView, convertedTo: targetView) {
            rects.append(rect)
        }
        return rects
    }

    private func textRect(
        forCharacterRange range: NSRange,
        in textView: NSTextView,
        convertedTo targetView: NSView
    ) -> NSRect? {
        var actualRange = NSRange(location: 0, length: 0)
        let screenRect = textView.firstRect(forCharacterRange: range, actualRange: &actualRange)
        guard screenRect.isNull == false,
              screenRect.isEmpty == false,
              let window = textView.window
        else {
            return nil
        }

        let windowRect = window.convertFromScreen(screenRect)
        let rect = targetView.convert(windowRect, from: nil)
        if let scrollView = textView.enclosingScrollView {
            let visibleRect = scrollView.convert(scrollView.contentView.bounds, to: targetView)
            let clippedRect = rect.intersection(visibleRect)
            return clippedRect.isNull || clippedRect.isEmpty ? nil : clippedRect
        }
        return rect
    }

    private func drawCharacters(
        in range: NSRange,
        textView: NSTextView,
        forContentView view: NSView
    ) {
        let rects = textRects(forCharacterRange: range, in: textView, convertedTo: view)
            .filter { $0.isNull == false && $0.isEmpty == false }
        guard rects.isEmpty == false else {
            return
        }

        NSGraphicsContext.saveGraphicsState()
        defer {
            NSGraphicsContext.restoreGraphicsState()
        }

        let clipPath = NSBezierPath()
        for rect in rects {
            clipPath.appendRect(rect)
        }
        clipPath.addClip()

        let origin = textView.convert(NSPoint.zero, to: view)
        let transform = NSAffineTransform()
        transform.translateX(by: origin.x, yBy: origin.y)
        transform.concat()
        textView.draw(textView.bounds)
    }

    private nonisolated static func leadingNewlineUTF16Length(in text: String) -> Int {
        var length = 0
        for scalar in text.unicodeScalars {
            guard CharacterSet.newlines.contains(scalar) else {
                break
            }
            length += String(scalar).utf16.count
        }
        return length
    }

    private nonisolated static func labelFont(weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize,
            weight: weight
        )
    }

    private nonisolated static func labelLineHeight(for font: NSFont) -> CGFloat {
        max(1, ceil(font.ascender - font.descender + font.leading))
    }

    private nonisolated static var outputFont: NSFont {
        NSFont.monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize,
            weight: .regular
        )
    }

    nonisolated static func proposedSize(
        for panel: ReviewMonitorLogCommandOutputPanel,
        width: CGFloat,
        outputLineHeight: CGFloat
    ) -> NSSize {
        NSSize(
            width: width,
            height: cardHeight(
                for: panel,
                width: width,
                outputLineHeight: outputLineHeight
            )
        )
    }

    private nonisolated static func cardHeight(
        for panel: ReviewMonitorLogCommandOutputPanel,
        width: CGFloat,
        outputLineHeight: CGFloat
    ) -> CGFloat {
        let contentWidth = max(0, width - commandLeadingInset - commandTrailingInset)
        let commandHeight = commandTextHeight(
            for: commandLineText(for: panel.commandText),
            width: contentWidth
        )
        let commandSectionHeight = commandHeight > 0
            ? shellToCommandGap + commandHeight + commandToOutputGap
            : shellToCommandGap
        return topInset +
            labelLineHeight(for: labelFont(weight: .medium)) +
            commandSectionHeight +
            outputLineHeight * CGFloat(visibleOutputLineCount) +
            outputToFooterGap +
            labelLineHeight(for: labelFont()) +
            bottomInset
    }

    nonisolated static func chevronSlotWidth(for font: NSFont) -> CGFloat {
        ceil(font.pointSize) + 6
    }

    private nonisolated static func commandLineText(for commandText: String) -> String {
        let trimmedCommandText = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCommandText.isEmpty == false else {
            return ""
        }
        return "$ \(trimmedCommandText)"
    }

    private nonisolated static func terminalText(commandLineText: String, outputText: String) -> String {
        let trimmedOutputText = outputText.trimmingCharacters(in: .newlines)
        if commandLineText.isEmpty {
            return outputText
        }
        if trimmedOutputText.isEmpty {
            return commandLineText
        }
        return "\(commandLineText)\n\(trimmedOutputText)"
    }

    private nonisolated static func terminalAttributedString(text: String, foregroundColor: NSColor) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: outputFont,
                .foregroundColor: foregroundColor
            ]
        )
    }

    private nonisolated static func commandTextHeight(for text: String, width: CGFloat) -> CGFloat {
        guard text.isEmpty == false else {
            return 0
        }
        return max(
            labelLineHeight(for: outputFont),
            terminalTextBoundingHeight(for: text, width: width, foregroundColor: .labelColor)
        )
    }

    private nonisolated static func outputTextHeight(
        minimumLineCount: Int,
        textContainerInset: NSSize,
        lineHeight: CGFloat
    ) -> CGFloat {
        CGFloat(max(1, minimumLineCount)) * lineHeight + textContainerInset.height * 2
    }

    private nonisolated static func outputTextWidth(
        maximumLineUTF16Length: Int,
        textContainerInset: NSSize
    ) -> CGFloat {
        let characterWidth = max(1, ceil(outputFont.maximumAdvancement.width))
        return CGFloat(max(1, maximumLineUTF16Length)) * characterWidth + textContainerInset.width * 2
    }

    private nonisolated static func terminalTextBoundingHeight(
        for text: String,
        width: CGFloat,
        foregroundColor: NSColor
    ) -> CGFloat {
        guard text.isEmpty == false else {
            return 0
        }
        let attributedString = terminalAttributedString(text: text, foregroundColor: foregroundColor)
        let rect = attributedString.boundingRect(
            with: NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(rect.height)
    }

    private func configureLabel(_ label: NSTextField) {
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
        label.textColor = .secondaryLabelColor
        label.font = Self.labelFont()
        label.lineBreakMode = .byTruncatingTail
    }

    private func configureTerminalTextView(
        _ textView: NSTextView,
        textColor: NSColor,
        textContainerInset: NSSize,
        wrapsLines: Bool = true
    ) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = textContainerInset
        textView.font = Self.outputFont
        textView.textColor = textColor
        textView.isHorizontallyResizable = wrapsLines == false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = wrapsLines ? [.width] : []
        textView.textContainer?.widthTracksTextView = wrapsLines
        textView.textContainer?.lineFragmentPadding = 0
    }

#if DEBUG
    var usesTextKit2ForTesting: Bool {
        commandTextView.textLayoutManager != nil &&
            outputTextView.textLayoutManager != nil
    }

    var visibleLineCapacityForTesting: Int {
        guard panel?.isExpanded == true else {
            return 0
        }
        layoutSubtreeIfNeeded()
        let font = outputTextView.font ?? NSFont.monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize,
            weight: .regular
        )
        let lineHeight = max(1, ceil(font.ascender - font.descender + font.leading))
        return Int(floor(outputScrollView.contentSize.height / lineHeight))
    }

    var resultTextForTesting: String {
        resultLabel.stringValue
    }

    var terminalTextForTesting: String {
        terminalText
    }

    var commandLineTextForTesting: String {
        commandLineText
    }

    var outputScrollTextForTesting: String {
        outputTextView.string
    }

    var outputScrollIsScrollableForTesting: Bool {
        layoutSubtreeIfNeeded()
        return outputTextView.frame.height > outputScrollView.contentSize.height + 0.5
    }

    var outputScrollUsesHorizontalScrollingForTesting: Bool {
        layoutSubtreeIfNeeded()
        return outputScrollView.hasHorizontalScroller &&
            outputTextView.isHorizontallyResizable &&
            outputTextView.textContainer?.widthTracksTextView == false
    }

    var outputScrollVerticalOffsetForTesting: CGFloat {
        layoutSubtreeIfNeeded()
        return outputScrollView.contentView.bounds.origin.y
    }

    var outputScrollMaximumVerticalOffsetForTesting: CGFloat {
        layoutSubtreeIfNeeded()
        return max(0, outputTextView.frame.height - outputScrollView.contentView.bounds.height)
    }

    func scrollOutputForTesting(deltaY: CGFloat) -> Bool {
        layoutSubtreeIfNeeded()
        guard outputScrollView.isHidden == false else {
            return false
        }
        let clipView = outputScrollView.contentView
        let before = clipView.bounds.origin.y
        let maxY = max(0, outputTextView.frame.height - clipView.bounds.height)
        let nextY = min(max(0, before + deltaY), maxY)
        guard abs(nextY - before) > 0.5 else {
            return false
        }
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: nextY))
        outputScrollView.reflectScrolledClipView(clipView)
        return abs(clipView.bounds.origin.y - before) > 0.5
    }

    var outputHitTestTargetsTextViewForTesting: Bool {
        layoutSubtreeIfNeeded()
        guard outputScrollView.isHidden == false,
              outputTextView.string.isEmpty == false
        else {
            return false
        }
        let visibleBounds = outputScrollView.contentView.bounds
        let outputPoint = NSPoint(
            x: min(max(4, visibleBounds.midX), max(4, outputTextView.bounds.maxX - 1)),
            y: min(max(visibleBounds.minY + outputLineHeight / 2, outputTextView.bounds.minY + 1), max(outputTextView.bounds.minY + 1, outputTextView.bounds.maxY - 1))
        )
        let panelPoint = outputTextView.convert(outputPoint, to: self)
        return hitTest(panelPoint) === outputTextView
    }
#endif
}
