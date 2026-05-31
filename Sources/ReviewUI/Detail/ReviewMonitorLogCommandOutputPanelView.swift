import AppKit

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
final class ReviewMonitorCommandOutputPanelBackgroundContainerView: NSView {
    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
final class ReviewMonitorCommandOutputPanelContainerView: NSView {
    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isHidden == false, alphaValue > 0 else {
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
}

@MainActor
private final class ReviewMonitorCommandOutputScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let previousNextResponder = nextResponder
        nextResponder = nil
        defer {
            nextResponder = previousNextResponder
        }
        super.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard forwardMouseEventToDocumentView(event, perform: { $0.mouseDown(with: event) }) else {
            super.mouseDown(with: event)
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard forwardMouseEventToDocumentView(event, perform: { $0.mouseDragged(with: event) }) else {
            super.mouseDragged(with: event)
            return
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard forwardMouseEventToDocumentView(event, perform: { $0.mouseUp(with: event) }) else {
            super.mouseUp(with: event)
            return
        }
    }

    private func forwardMouseEventToDocumentView(
        _ event: NSEvent,
        perform: (NSView) -> Void
    ) -> Bool {
        guard let documentView else {
            return false
        }
        let documentPoint = documentView.convert(event.locationInWindow, from: nil)
        guard documentView.bounds.contains(documentPoint) else {
            return false
        }
        perform(documentView)
        return true
    }
}

final class ReviewMonitorCommandOutputToggleAttachment: NSTextAttachment {
    let blockID: ReviewMonitorLogBlockID
    let symbolName: String
    let symbolSize: CGFloat
    let fontPointSize: CGFloat
    let slotWidth: CGFloat
    let renderedSymbolSize: NSSize

    init(blockID: ReviewMonitorLogBlockID, isExpanded: Bool, font: NSFont) {
        self.blockID = blockID
        self.symbolName = isExpanded ? "chevron.down" : "chevron.forward"
        self.symbolSize = ceil(font.pointSize + 1)
        self.fontPointSize = font.pointSize
        self.slotWidth = ReviewMonitorCommandOutputPanelView.chevronSlotWidth(for: font)
        self.renderedSymbolSize = Self.renderedSymbolSize(
            name: symbolName,
            symbolSize: symbolSize,
            pointSize: symbolSize
        )
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
        NSTextAttachmentViewProvider(
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

    private static func renderedSymbolSize(
        name: String,
        symbolSize: CGFloat,
        pointSize: CGFloat
    ) -> NSSize {
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(.init(hierarchicalColor: .secondaryLabelColor))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfiguration)
        else {
            return .zero
        }

        let naturalSize = symbol.size
        let scale = min(
            symbolSize / max(1, naturalSize.width),
            symbolSize / max(1, naturalSize.height)
        )
        let drawSize = NSSize(
            width: max(1, floor(naturalSize.width * scale)),
            height: max(1, floor(naturalSize.height * scale))
        )
        return drawSize
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
final class ReviewMonitorCommandOutputToggleButton: NSButton {
    private(set) var blockID: ReviewMonitorLogBlockID
    private(set) var symbolName: String
    private var buttonSize: NSSize
    private var symbolImage: NSImage?
    private var symbolDrawSize = NSSize(width: 0, height: 0)

    init(attachment: ReviewMonitorCommandOutputToggleAttachment) {
        self.blockID = attachment.blockID
        self.symbolName = attachment.symbolName
        self.buttonSize = NSSize(width: attachment.slotWidth, height: attachment.symbolSize)
        super.init(frame: NSRect(origin: .zero, size: buttonSize))

        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        bezelStyle = .regularSquare
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
        symbolName = attachment.symbolName
        buttonSize = NSSize(width: attachment.slotWidth, height: attachment.symbolSize)
        frame.size = buttonSize
        invalidateIntrinsicContentSize()
        symbolDrawSize = attachment.renderedSymbolSize

        let accessibilityLabel = symbolName == "chevron.down"
            ? "Collapse command output"
            : "Expand command output"
        toolTip = accessibilityLabel
        setAccessibilityLabel(accessibilityLabel)

        let symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: attachment.symbolSize,
            weight: .medium
        )
            .applying(.init(hierarchicalColor: isHighlighted ? .labelColor : .secondaryLabelColor))
        symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfiguration)
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        buttonSize
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let symbolImage else {
            return
        }

        let drawSize = NSSize(
            width: min(bounds.width, max(1, symbolDrawSize.width)),
            height: min(bounds.height, max(1, symbolDrawSize.height))
        )
        symbolImage.draw(
            in: NSRect(
                x: floor((bounds.width - drawSize.width) / 2),
                y: floor((bounds.height - drawSize.height) / 2),
                width: drawSize.width,
                height: drawSize.height
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: isEnabled ? 1 : 0.45,
            respectFlipped: true,
            hints: nil
        )
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
final class ReviewMonitorCommandOutputPanelView: NSView {
    static let visibleOutputLineCount = 5
    static let headerToCardGap: CGFloat = 6

    private static let topInset: CGFloat = 8
    private static let bottomInset: CGFloat = 8
    private static let horizontalInset: CGFloat = 8
    private static let shellToCommandGap: CGFloat = 2
    private static let commandToOutputGap: CGFloat = 2
    private static let outputToFooterGap: CGFloat = 8
    private static let commandLeadingInset: CGFloat = 12
    private static let commandTrailingInset: CGFloat = 2

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

        configureLabel(shellLabel)
        shellLabel.font = Self.labelFont(weight: .medium)
        addSubview(shellLabel)

        configureTerminalTextView(commandTextView, textColor: .labelColor, textContainerInset: .zero)
        commandTextView.isHidden = true
        addSubview(commandTextView)

        outputScrollView.drawsBackground = false
        outputScrollView.borderType = .noBorder
        outputScrollView.hasVerticalScroller = true
        outputScrollView.hasHorizontalScroller = false
        outputScrollView.autohidesScrollers = true
        outputScrollView.scrollerStyle = .overlay
        outputScrollView.documentView = outputTextView
        outputScrollView.isHidden = true
        addSubview(outputScrollView)

        configureTerminalTextView(
            outputTextView,
            textColor: .secondaryLabelColor,
            textContainerInset: NSSize(width: 0, height: 2)
        )

        configureLabel(resultLabel)
        resultLabel.alignment = .right
        addSubview(resultLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(_ panel: ReviewMonitorLogCommandOutputPanel) {
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
        if isExpanded, wasExpanded == false || outputChanged {
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
            outputLineCount = Self.lineCount(panel.outputText)
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
        outputTextView.maxSize = NSSize(width: outputWidth, height: CGFloat.greatestFiniteMagnitude)
        outputTextView.textContainer?.containerSize = NSSize(
            width: outputWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        let outputHeight = Self.outputTextHeight(
            for: outputText,
            width: outputWidth,
            minimumLineCount: outputLineCount,
            textContainerInset: outputTextView.textContainerInset,
            lineHeight: outputLineHeight
        )
        outputTextView.frame.size = NSSize(
            width: outputWidth,
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
            return outputScrollView
        }
        if commandTextView.isHidden == false,
           commandTextView.frame.contains(point) {
            return commandTextView.hitTest(convert(point, to: commandTextView))
        }
        return nil
    }

    private var outputLineHeight: CGFloat {
        let font = outputTextView.font ?? Self.outputFont
        return max(1, ceil(font.ascender - font.descender + font.leading))
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

    private static func labelFont(weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize,
            weight: weight
        )
    }

    private static func labelLineHeight(for font: NSFont) -> CGFloat {
        max(1, ceil(font.ascender - font.descender + font.leading))
    }

    private static var outputFont: NSFont {
        NSFont.monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize,
            weight: .regular
        )
    }

    static func cardHeight(
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

    private static func commandLineText(for commandText: String) -> String {
        let trimmedCommandText = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCommandText.isEmpty == false else {
            return ""
        }
        return "$ \(trimmedCommandText)"
    }

    private static func terminalText(commandLineText: String, outputText: String) -> String {
        let trimmedOutputText = outputText.trimmingCharacters(in: .newlines)
        if commandLineText.isEmpty {
            return outputText
        }
        if trimmedOutputText.isEmpty {
            return commandLineText
        }
        return "\(commandLineText)\n\(trimmedOutputText)"
    }

    private static func terminalAttributedString(text: String, foregroundColor: NSColor) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: outputFont,
                .foregroundColor: foregroundColor
            ]
        )
    }

    private static func commandTextHeight(for text: String, width: CGFloat) -> CGFloat {
        guard text.isEmpty == false else {
            return 0
        }
        return max(
            labelLineHeight(for: outputFont),
            terminalTextBoundingHeight(for: text, width: width, foregroundColor: .labelColor)
        )
    }

    private static func outputTextHeight(
        for text: String,
        width: CGFloat,
        minimumLineCount: Int,
        textContainerInset: NSSize,
        lineHeight: CGFloat
    ) -> CGFloat {
        let minimumHeight = CGFloat(max(1, minimumLineCount)) * lineHeight
        let measuredHeight = terminalTextBoundingHeight(
            for: text,
            width: width,
            foregroundColor: .secondaryLabelColor
        )
        return max(minimumHeight, measuredHeight) + textContainerInset.height * 2
    }

    private static func terminalTextBoundingHeight(
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

    private static func lineCount(_ text: String) -> Int {
        guard text.isEmpty == false else {
            return 0
        }
        let rawLineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return text.hasSuffix("\n") ? max(0, rawLineCount - 1) : rawLineCount
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
        textContainerInset: NSSize
    ) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = textContainerInset
        textView.font = Self.outputFont
        textView.textColor = textColor
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
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
#endif
}
