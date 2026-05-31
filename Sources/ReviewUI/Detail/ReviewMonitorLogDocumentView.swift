import AppKit
import CodexReview

private extension ReviewLogEntry.Kind {
    var requiresMarkdownPresentationInvalidationOnAppend: Bool {
        switch self {
        case .agentMessage, .plan, .reasoning, .reasoningSummary, .rawReasoning:
            return true
        case .command, .commandOutput, .todoList, .toolCall, .diagnostic, .error, .progress, .event:
            return false
        }
    }
}

@MainActor
final class ReviewMonitorLogDocumentView: NSView, NSUserInterfaceValidations, @preconcurrency NSTextViewportLayoutControllerDelegate {
    private let textContentStorage = NSTextContentStorage()
    private let textLayoutManager = NSTextLayoutManager()
    private let textContainer = NSTextContainer(
        size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )
    private let textStorage = NSTextStorage()
    private let textContentView = ReviewMonitorLogContentView()
    private let decorationView = ReviewMonitorLogDecorationView()
    private let fragmentViewportView = ReviewMonitorLogContentViewportView()
    private let selectionView = ReviewMonitorLogSelectionView()
    private let fragmentViewMap = NSMapTable<NSTextLayoutFragment, ReviewMonitorLogFragmentView>.weakToWeakObjects()
    private var visibleFragmentViews = Set<ReviewMonitorLogFragmentView>()
    private var lastUsedFragmentViews = Set<ReviewMonitorLogFragmentView>()
    private var wordFadeAnimations: [ReviewMonitorLogWordFadeAnimation] = []
    private var needsViewportLayout = true
    private var needsViewportRelayout = false
    private var lastViewportLayoutBounds: CGRect?
    private var isLayingOutViewport = false
    private var selectedRange = NSRange(location: 0, length: 0)
    private var isApplyingTextFinderSelection = false
    private var dragAnchorUTF16Offset: Int?
    private var keyboardSelectionAnchorUTF16Offset: Int?
    private var keyboardSelectionFocusUTF16Offset: Int?
    private var preferredTextContainerWidth: CGFloat = 0
    private var currentDecorations: [ReviewMonitorLogDecoration] = []
    private var currentCommandOutputPanels: [ReviewMonitorLogCommandOutputPanel] = []
    private(set) var estimatedDocumentHeight: CGFloat = 0
    private var glowTimer: Timer?
    var contentInsets: NSEdgeInsets = .init()
    var textContainerInset = NSSize(width: 12, height: 10)
    var onLayoutInvalidated: (() -> Void)?
    var onUserSelectionChanged: (() -> Void)?
    var onCommandOutputPanelToggle: ((ReviewMonitorLogBlockID) -> Void)?
#if DEBUG
    var reduceMotionOverrideForTesting: Bool?
    private var wordFadeDisplayInvalidationCount = 0
#endif

    private let baseFont = NSFont.systemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize
    )
    private let monoFont = NSFont.monospacedSystemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize,
        weight: .regular
    )
    private var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .foregroundColor: normalTextColor,
        ]
    }

    private static let wordFadeKinds: Set<ReviewLogEntry.Kind> = [
        .agentMessage,
        .plan,
        .reasoning,
        .reasoningSummary,
        .rawReasoning,
    ]
    private static let maxWordFadeCount = 80
    private static let maxWordFadeUTF16Length = 8 * 1024
    private static let maxLineFadeChunkUTF16Length = 12
    private static let wordFadeDuration: TimeInterval = 0.34
    private static let wordFadeInitialAlpha: CGFloat = 0
    private static let wordFadeStagger: TimeInterval = 0.028
    private static let wordFadeAlphaStepCount = 16
    private static let maxReadableTextWidth: CGFloat = 980

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
        textContainer.lineFragmentPadding = 4
        textLayoutManager.textContainer = textContainer
        textContentStorage.textStorage = textStorage
        textContentStorage.addTextLayoutManager(textLayoutManager)
        textContentStorage.primaryTextLayoutManager = textLayoutManager
        textLayoutManager.textViewportLayoutController.delegate = self
        addSubview(textContentView)
        textContentView.addSubview(decorationView)
        textContentView.addSubview(selectionView)
        textContentView.addSubview(fragmentViewportView)
        estimatedDocumentHeight = measuredDocumentHeight()
        setAccessibilityElement(true)
        observeAccessibilityDisplayOptions()
    }

    isolated deinit {
        glowTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
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
        textContainerInset.width = max(12, floor((preferredTextContainerWidth - Self.maxReadableTextWidth) / 2))
        let containerChanged = syncTextContainerSize()
        if insetsChanged {
            needsViewportLayout = true
            lastViewportLayoutBounds = nil
        }
        if widthChanged || insetsChanged {
            clearWordFadeAnimations()
        }
        if containerChanged || estimatedDocumentHeight <= 0 {
            updateEstimatedDocumentHeight()
        }
        return true
    }

    func appendText(_ suffix: String, animation: ReviewMonitorLogAppend?) {
        guard suffix.isEmpty == false else {
            return
        }
        let appendBaseLocation = textStorage.length
        let invalidationStart = appendInvalidationStartUTF16Offset()
        let fadeRanges = wordFadeRanges(in: suffix, baseLocation: appendBaseLocation, animation: animation)
        textContentStorage.performEditingTransaction {
            textStorage.append(NSAttributedString(string: suffix, attributes: baseAttributes))
        }
        clampSelectedRange()
        increaseEstimatedDocumentHeightForAppend(suffix)
        let glowAnimationStart = CACurrentMediaTime()
        if let animation,
           shouldAnimateGlow,
           animation.range.length > 0,
           Self.wordFadeKinds.contains(animation.kind) {
            enqueueWordFadeAnimations(ranges: fadeRanges, startedAt: glowAnimationStart)
        }
        invalidateTextLayout(
            in: NSRange(location: invalidationStart, length: textStorage.length - invalidationStart),
            measureEstimatedHeightImmediately: false
        )
        if animation != nil {
            startGlowTimerIfNeeded()
        }
    }

    private func increaseEstimatedDocumentHeightForAppend(_ suffix: String) {
        estimatedDocumentHeight += CGFloat(estimatedLineCount(in: suffix)) * estimatedBaseLineHeight
        invalidateIntrinsicContentSize()
    }

    private var estimatedBaseLineHeight: CGFloat {
        ceil(baseFont.ascender - baseFont.descender + baseFont.leading)
    }

    private func estimatedLineCount(in text: String) -> Int {
        let unitsPerLine = estimatedUTF16UnitsPerVisualLine
        var currentLineLength = 0
        var lineCount = 0
        for codeUnit in text.utf16 {
            if codeUnit == 10 {
                lineCount += estimatedVisualLineCount(
                    forUTF16Length: currentLineLength,
                    unitsPerLine: unitsPerLine
                )
                currentLineLength = 0
            } else {
                currentLineLength += 1
            }
        }
        lineCount += estimatedVisualLineCount(
            forUTF16Length: currentLineLength,
            unitsPerLine: unitsPerLine
        )
        return max(1, lineCount)
    }

    private var estimatedUTF16UnitsPerVisualLine: Int {
        let availableWidth = max(
            1,
            textContainer.size.width > 0
                ? textContainer.size.width
                : preferredTextContainerWidth - textContainerInset.width * 2
        )
        let estimatedCharacterWidth = max(
            1,
            ceil(max(baseFont.maximumAdvancement.width, monoFont.maximumAdvancement.width))
        )
        return max(1, Int(floor(availableWidth / estimatedCharacterWidth)))
    }

    private func estimatedVisualLineCount(
        forUTF16Length length: Int,
        unitsPerLine: Int
    ) -> Int {
        max(1, Int(ceil(CGFloat(max(1, length)) / CGFloat(unitsPerLine))))
    }

    func replaceText(_ text: String) {
        cancelGlowAnimations()
        textContentStorage.performEditingTransaction {
            textStorage.setAttributedString(NSAttributedString(string: text, attributes: baseAttributes))
        }
        clampSelectedRange()
        invalidateTextLayout(measureEstimatedHeightImmediately: true)
    }

    func replaceText(in range: NSRange, with text: String) {
        cancelGlowAnimations()
        let replacementRange = clamp(range)
        guard replacementRange.length == range.length else {
            replaceText(textStorage.string)
            return
        }

        let invalidationStart = textReplacementInvalidationStartUTF16Offset(for: replacementRange)
        let replacedText = (textStorage.string as NSString).substring(with: replacementRange)
        textContentStorage.performEditingTransaction {
            textStorage.replaceCharacters(
                in: replacementRange,
                with: NSAttributedString(string: text, attributes: baseAttributes)
            )
        }
        clampSelectedRange()
        adjustEstimatedDocumentHeight(replacing: replacedText, with: text)
        invalidateTextLayout(
            in: NSRange(location: invalidationStart, length: textStorage.length - invalidationStart),
            measureEstimatedHeightImmediately: false
        )
    }

    private func adjustEstimatedDocumentHeight(replacing replacedText: String, with replacementText: String) {
        let delta = estimatedLineCount(in: replacementText) - estimatedLineCount(in: replacedText)
        guard delta != 0 else {
            return
        }
        estimatedDocumentHeight = max(
            ceil(textContainerInset.height * 2),
            estimatedDocumentHeight + CGFloat(delta) * estimatedBaseLineHeight
        )
        invalidateIntrinsicContentSize()
    }

    func applyPresentation(
        _ document: ReviewMonitorLogDocument,
        appended append: ReviewMonitorLogAppend? = nil,
        replacement: ReviewMonitorLogReplacement? = nil
    ) {
        guard document.textUTF16Length == textStorage.length,
              append != nil || replacement != nil || document.text == textStorage.string
        else {
            currentDecorations = []
            currentCommandOutputPanels = []
            decorationView.decorations = []
            return
        }

        currentDecorations = document.decorations
        currentCommandOutputPanels = document.commandOutputPanels
        if let append,
           let invalidationRange = styleInvalidationRange(for: append, in: document) {
            applyStyleRuns(document.styleRuns, commandOutputPanels: document.commandOutputPanels, in: invalidationRange)
        } else if let replacement,
                  let invalidationRange = styleInvalidationRange(for: replacement, in: document) {
            applyStyleRuns(document.styleRuns, commandOutputPanels: document.commandOutputPanels, in: invalidationRange)
        } else {
            applyStyleRuns(document.styleRuns, commandOutputPanels: document.commandOutputPanels)
        }
        updateDecorationRects()
    }

    private func applyStyleRuns(
        _ styleRuns: [ReviewMonitorLogTextRun],
        commandOutputPanels: [ReviewMonitorLogCommandOutputPanel]
    ) {
        guard textStorage.length > 0 else {
            return
        }

        let fullRange = NSRange(location: 0, length: textStorage.length)
        textContentStorage.performEditingTransaction {
            textStorage.setAttributes(baseAttributes, range: fullRange)
            for styleRun in styleRuns {
                let range = NSIntersectionRange(styleRun.range, fullRange)
                guard range.length > 0 else {
                    continue
                }
                textStorage.addAttributes(attributes(for: styleRun.style), range: range)
            }
            applyCommandOutputAttachments(commandOutputPanels, in: fullRange)
        }
        invalidateTextLayout(measureEstimatedHeightImmediately: true)
    }

    private func applyStyleRuns(
        _ styleRuns: [ReviewMonitorLogTextRun],
        commandOutputPanels: [ReviewMonitorLogCommandOutputPanel],
        in invalidationRange: NSRange
    ) {
        guard textStorage.length > 0 else {
            return
        }

        let fullRange = NSRange(location: 0, length: textStorage.length)
        let targetRange = NSIntersectionRange(invalidationRange, fullRange)
        guard targetRange.length > 0 else {
            return
        }

        textContentStorage.performEditingTransaction {
            textStorage.setAttributes(baseAttributes, range: targetRange)
            for styleRun in styleRuns {
                let range = NSIntersectionRange(styleRun.range, targetRange)
                guard range.length > 0 else {
                    continue
                }
                textStorage.addAttributes(attributes(for: styleRun.style), range: range)
            }
            applyCommandOutputAttachments(commandOutputPanels, in: targetRange)
        }
        invalidateTextLayout(in: targetRange, measureEstimatedHeightImmediately: false)
    }

    private func applyCommandOutputAttachments(
        _ panels: [ReviewMonitorLogCommandOutputPanel],
        in targetRange: NSRange
    ) {
        for panel in panels {
            let attachmentRange = NSRange(location: panel.range.location, length: min(1, panel.range.length))
            guard NSIntersectionRange(attachmentRange, targetRange).length == attachmentRange.length,
                  attachmentRange.length == 1,
                  attachmentRange.location < textStorage.length
            else {
                continue
            }
            textStorage.addAttribute(
                .attachment,
                value: ReviewMonitorCommandOutputToggleAttachment(
                    blockID: panel.blockID,
                    isExpanded: panel.isExpanded,
                    font: commandOutputControlFont
                ),
                range: attachmentRange
            )

            guard panel.isExpanded else {
                continue
            }
            let panelAttachmentRange = NSRange(
                location: NSMaxRange(panel.range) - 1,
                length: 1
            )
            guard panelAttachmentRange.location >= panel.range.location,
                  NSIntersectionRange(panelAttachmentRange, targetRange).length == panelAttachmentRange.length,
                  panelAttachmentRange.location < textStorage.length
            else {
                continue
            }
            textStorage.addAttribute(
                .attachment,
                value: ReviewMonitorCommandOutputPanelAttachment(
                    panel: panel,
                    outputLineHeight: commandOutputPanelLineHeight
                ),
                range: panelAttachmentRange
            )
        }
    }

    private func styleInvalidationRange(
        for append: ReviewMonitorLogAppend,
        in document: ReviewMonitorLogDocument
    ) -> NSRange? {
        guard let block = document.blocks.last(where: { $0.id == append.blockID }) else {
            return append.range
        }

        if block.kind.requiresMarkdownPresentationInvalidationOnAppend {
            return block.range
        }
        return append.range
    }

    private func styleInvalidationRange(
        for replacement: ReviewMonitorLogReplacement,
        in document: ReviewMonitorLogDocument
    ) -> NSRange? {
        guard let block = document.blocks.last(where: { $0.id == replacement.blockID }) else {
            return NSRange(location: replacement.range.location, length: replacement.textUTF16Length)
        }

        return block.range
    }

    private func attributes(for style: ReviewMonitorLogTextStyle) -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes
        switch style {
        case .body:
            break
        case .heading(let level):
            attributes[.font] = boldFont(
                size: baseFont.pointSize + max(1, 5 - CGFloat(level))
            )
            attributes[.foregroundColor] = normalTextColor
        case .bullet:
            attributes[.foregroundColor] = normalTextColor
        case .blockquote:
            attributes[.font] = italicFont(baseFont)
            attributes[.foregroundColor] = normalTextColor
        case .strong:
            attributes[.font] = boldFont(size: baseFont.pointSize)
            attributes[.foregroundColor] = normalTextColor
        case .emphasis:
            attributes[.font] = italicFont(baseFont)
            attributes[.foregroundColor] = normalTextColor
        case .link:
            attributes[.foregroundColor] = normalTextColor
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        case .strikethrough:
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.foregroundColor] = normalTextColor
        case .inlineCode:
            attributes[.font] = monoFont
            attributes[.foregroundColor] = normalTextColor
            attributes[.backgroundColor] = NSColor.textColor.withAlphaComponent(0.07)
        case .codeFence:
            attributes[.font] = monoFont
            attributes[.foregroundColor] = normalTextColor
        case .markdownSyntax:
            attributes[.foregroundColor] = normalTextColor
        case .command:
            attributes[.foregroundColor] = normalTextColor
        case .terminalOutput:
            attributes[.font] = monoFont
            attributes[.foregroundColor] = secondaryTextColor
        case .commandOutputControl(let isExpanded):
            attributes[.font] = commandOutputControlFont
            attributes[.foregroundColor] = secondaryTextColor
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.firstLineHeadIndent = 0
            paragraphStyle.headIndent = commandOutputControlTextIndent
            if isExpanded == false {
                paragraphStyle.lineBreakMode = .byTruncatingTail
            }
            attributes[.paragraphStyle] = paragraphStyle
        case .plan(let status):
            attributes[.foregroundColor] = planTextColor(for: status)
        case .tool:
            attributes[.foregroundColor] = normalTextColor
        case .diagnostic:
            attributes[.foregroundColor] = normalTextColor
        case .error:
            attributes[.font] = boldFont(size: baseFont.pointSize)
            attributes[.foregroundColor] = normalTextColor
        case .event:
            attributes[.foregroundColor] = normalTextColor
        case .muted:
            attributes[.foregroundColor] = normalTextColor
        }
        return attributes
    }

    private var normalTextColor: NSColor {
        NSColor.textColor
    }

    private var secondaryTextColor: NSColor {
        NSColor.systemGray
    }

    private var commandOutputControlFont: NSFont {
        baseFont
    }

    private var commandOutputControlTextIndent: CGFloat {
        ReviewMonitorCommandOutputPanelView.chevronSlotWidth(for: commandOutputControlFont)
    }

    private func boldFont(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    private func italicFont(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    private func planTextColor(for status: ReviewMonitorLogPlanStatus?) -> NSColor {
        normalTextColor
    }

    private var shouldAnimateGlow: Bool {
#if DEBUG
        if let reduceMotionOverrideForTesting {
            return reduceMotionOverrideForTesting == false
        }
#endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false
    }

    private func enqueueWordFadeAnimations(ranges: [NSRange], startedAt: TimeInterval) {
        guard ranges.isEmpty == false else {
            return
        }

        var initialColorUpdates: [(range: NSRange, color: NSColor)] = []
        for (index, range) in ranges.enumerated() {
            let range = clamp(range)
            guard range.length > 0 else {
                continue
            }
            let baseColor = foregroundColor(at: range.location)
            initialColorUpdates.append((
                range,
                wordFadeColor(progress: 0, baseColor: baseColor)
            ))
            wordFadeAnimations.append(
                ReviewMonitorLogWordFadeAnimation(
                    range: range,
                    startedAt: startedAt + TimeInterval(index) * Self.wordFadeStagger,
                    renderedStep: 0,
                    baseColor: baseColor
                )
            )
        }
        updateWordFadeRenderingColors(initialColorUpdates)
        invalidateWordFadeDisplay(for: ranges)
    }

    private func wordFadeRanges(
        in suffix: String,
        baseLocation: Int,
        animation: ReviewMonitorLogAppend?
    ) -> [NSRange] {
        guard shouldAnimateGlow,
              let animation,
              Self.wordFadeKinds.contains(animation.kind)
        else {
            return []
        }

        let nsString = suffix as NSString
        let suffixRange = NSRange(location: baseLocation, length: nsString.length)
        let clampedRange = NSIntersectionRange(animation.range, suffixRange)
        guard clampedRange.length > 0 else {
            return []
        }
        let localRange = NSRange(location: clampedRange.location - suffixRange.location, length: clampedRange.length)
        let cappedRange = NSRange(
            location: localRange.location,
            length: min(clampedRange.length, Self.maxWordFadeUTF16Length)
        )
        var ranges: [NSRange] = []
        nsString.enumerateSubstrings(
            in: cappedRange,
            options: [.byLines, .substringNotRequired, .localized]
        ) { _, lineRange, _, stop in
            ranges.append(contentsOf: self.lineFadeRanges(
                in: nsString,
                localLineRange: lineRange,
                baseLocation: suffixRange.location,
                limit: Self.maxWordFadeCount - ranges.count
            ))
            if ranges.count >= Self.maxWordFadeCount {
                stop.pointee = true
            }
        }
        return ranges
    }

    private func lineFadeRanges(
        in string: NSString,
        localLineRange: NSRange,
        baseLocation: Int,
        limit: Int
    ) -> [NSRange] {
        guard localLineRange.length > 0,
              limit > 0
        else {
            return []
        }

        var ranges: [NSRange] = []
        var chunkStart: Int?
        var chunkEnd: Int?
        string.enumerateSubstrings(
            in: localLineRange,
            options: [.byComposedCharacterSequences, .substringNotRequired, .localized]
        ) { _, characterRange, _, characterStop in
            if chunkStart == nil {
                chunkStart = characterRange.location
            }
            chunkEnd = NSMaxRange(characterRange)

            if let start = chunkStart,
               let end = chunkEnd,
               end - start >= Self.maxLineFadeChunkUTF16Length {
                ranges.append(NSRange(location: baseLocation + start, length: end - start))
                chunkStart = nil
                chunkEnd = nil
            }

            if ranges.count >= limit {
                characterStop.pointee = true
            }
        }

        if ranges.count < limit,
           let start = chunkStart,
           let end = chunkEnd,
           end > start {
            ranges.append(NSRange(location: baseLocation + start, length: end - start))
        }
        return ranges
    }

    private func wordFadeColor(progress: Double, baseColor: NSColor) -> NSColor {
        let alpha = Self.wordFadeInitialAlpha + (1 - Self.wordFadeInitialAlpha) * CGFloat(progress)
        return baseColor.withAlphaComponent(alpha)
    }

    private func foregroundColor(at location: Int) -> NSColor {
        guard textStorage.length > 0 else {
            return normalTextColor
        }
        let clampedLocation = min(max(0, location), textStorage.length - 1)
        return textStorage.attribute(
            .foregroundColor,
            at: clampedLocation,
            effectiveRange: nil
        ) as? NSColor ?? normalTextColor
    }

    private func updateWordFadeAnimations(at now: TimeInterval) {
        guard wordFadeAnimations.isEmpty == false else {
            return
        }

        var activeAnimations: [ReviewMonitorLogWordFadeAnimation] = []
        var updatedRanges: [NSRange] = []
        var colorUpdates: [(range: NSRange, color: NSColor)] = []
        var finishedRanges: [NSRange] = []
        for var animation in wordFadeAnimations {
            if now >= animation.startedAt + Self.wordFadeDuration {
                finishedRanges.append(animation.range)
                updatedRanges.append(animation.range)
                continue
            }

            let progress = min(1, max(0, (now - animation.startedAt) / Self.wordFadeDuration))
            let step = wordFadeAlphaStep(for: progress)
            if step != animation.renderedStep {
                colorUpdates.append((
                    animation.range,
                    wordFadeColor(
                        progress: wordFadeProgress(forAlphaStep: step),
                        baseColor: animation.baseColor
                    )
                ))
                updatedRanges.append(animation.range)
                animation.renderedStep = step
            }
            activeAnimations.append(animation)
        }
        wordFadeAnimations = activeAnimations
        removeWordFadeRenderingAttributes(in: finishedRanges)
        updateWordFadeRenderingColors(colorUpdates)
        invalidateWordFadeDisplay(for: updatedRanges)
    }

    private func wordFadeAlphaStep(for progress: Double) -> Int {
        min(
            Self.wordFadeAlphaStepCount,
            max(0, Int(progress * Double(Self.wordFadeAlphaStepCount)))
        )
    }

    private func wordFadeProgress(forAlphaStep step: Int) -> Double {
        Double(min(Self.wordFadeAlphaStepCount, max(0, step))) / Double(Self.wordFadeAlphaStepCount)
    }

    private func clearWordFadeAnimations() {
        guard wordFadeAnimations.isEmpty == false else {
            return
        }

        let storageRanges = wordFadeAnimations.map(\.range)
        wordFadeAnimations.removeAll()
        removeWordFadeRenderingAttributes(in: storageRanges)
        invalidateWordFadeDisplay(for: storageRanges)
    }

    private func updateWordFadeRenderingColors(_ updates: [(range: NSRange, color: NSColor)]) {
        guard updates.isEmpty == false else {
            return
        }

        for (range, color) in updates {
            let range = clamp(range)
            guard range.length > 0,
                  let textRange = textRange(for: range)
            else {
                continue
            }
            textLayoutManager.addRenderingAttribute(.foregroundColor, value: color, for: textRange)
        }
    }

    private func removeWordFadeRenderingAttributes(in ranges: [NSRange]) {
        guard ranges.isEmpty == false else {
            return
        }

        for range in ranges {
            let range = clamp(range)
            guard range.length > 0,
                  let textRange = textRange(for: range)
            else {
                continue
            }
            textLayoutManager.removeRenderingAttribute(.foregroundColor, for: textRange)
        }
    }

    private func invalidateWordFadeDisplay(for ranges: [NSRange]) {
        guard var invalidationRange = ranges.first else {
            return
        }
        for range in ranges.dropFirst() {
            invalidationRange = NSUnionRange(invalidationRange, range)
        }

#if DEBUG
        wordFadeDisplayInvalidationCount += 1
#endif
        for fragmentView in visibleFragmentViews {
            let fragmentRange = nsRange(for: fragmentView.layoutFragment.rangeInElement)
            if NSIntersectionRange(fragmentRange, invalidationRange).length > 0 {
                fragmentView.needsDisplay = true
            }
        }
    }

    private func startGlowTimerIfNeeded() {
        guard glowTimer == nil,
              hasActiveGlowAnimations
        else {
            return
        }

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advanceGlowAnimations()
            }
        }
        glowTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceGlowAnimations() {
        guard shouldAnimateGlow else {
            cancelGlowAnimations()
            return
        }

        let now = CACurrentMediaTime()
        updateWordFadeAnimations(at: now)
        if hasActiveGlowAnimations == false {
            glowTimer?.invalidate()
            glowTimer = nil
        }
    }

    func cancelGlowAnimations() {
        glowTimer?.invalidate()
        glowTimer = nil
        clearWordFadeAnimations()
    }

    private var hasActiveGlowAnimations: Bool {
        wordFadeAnimations.isEmpty == false
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
            updateDecorationRects()
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
        setSelectedRange(range, preserveKeyboardSelection: false)
    }

    func setSelectedRangeFromTextFinder(_ range: NSRange) {
        isApplyingTextFinderSelection = true
        setSelectedRange(range)
        isApplyingTextFinderSelection = false
    }

    private func setSelectedRange(_ range: NSRange, preserveKeyboardSelection: Bool) {
        let clampedRange = clamp(range)
        selectedRange = clampedRange
        if preserveKeyboardSelection == false {
            keyboardSelectionAnchorUTF16Offset = nil
            keyboardSelectionFocusUTF16Offset = nil
        }
        if let textRange = textRange(for: clampedRange) {
            textLayoutManager.textSelections = [
                NSTextSelection([textRange], affinity: .downstream, granularity: .character),
            ]
        } else {
            textLayoutManager.textSelections = []
        }
        updateSelectionRects()
        setNeedsDisplay(bounds)
        if isApplyingTextFinderSelection == false {
            onUserSelectionChanged?()
        }
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

        let clipRects = rects(forCharacterRange: range).map(\.rectValue)
        guard clipRects.isEmpty == false else {
            return
        }

        context.saveGState()
        for clipRect in clipRects {
            context.addRect(clipRect)
        }
        context.clip()
        defer {
            context.restoreGState()
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

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSStandardKeyBindingResponding.moveLeft(_:)):
            moveInsertionPoint(by: .character, direction: .backward)
        case #selector(NSStandardKeyBindingResponding.moveRight(_:)):
            moveInsertionPoint(by: .character, direction: .forward)
        case #selector(NSStandardKeyBindingResponding.moveWordLeft(_:)):
            moveInsertionPoint(by: .word, direction: .backward)
        case #selector(NSStandardKeyBindingResponding.moveWordRight(_:)):
            moveInsertionPoint(by: .word, direction: .forward)
        case #selector(NSStandardKeyBindingResponding.moveUp(_:)):
            moveInsertionPoint(by: .line, direction: .backward)
        case #selector(NSStandardKeyBindingResponding.moveDown(_:)):
            moveInsertionPoint(by: .line, direction: .forward)
        case #selector(NSStandardKeyBindingResponding.moveToBeginningOfLine(_:)):
            moveInsertionPoint(by: .lineBoundary, direction: .backward)
        case #selector(NSStandardKeyBindingResponding.moveToEndOfLine(_:)):
            moveInsertionPoint(by: .lineBoundary, direction: .forward)
        case #selector(NSStandardKeyBindingResponding.moveToBeginningOfDocument(_:)):
            moveInsertionPoint(by: .document, direction: .backward)
        case #selector(NSStandardKeyBindingResponding.moveToEndOfDocument(_:)):
            moveInsertionPoint(by: .document, direction: .forward)
        case #selector(NSStandardKeyBindingResponding.moveLeftAndModifySelection(_:)):
            extendSelection(by: .character, direction: .backward)
        case #selector(NSStandardKeyBindingResponding.moveRightAndModifySelection(_:)):
            extendSelection(by: .character, direction: .forward)
        case #selector(NSStandardKeyBindingResponding.moveWordLeftAndModifySelection(_:)):
            extendSelection(by: .word, direction: .backward)
        case #selector(NSStandardKeyBindingResponding.moveWordRightAndModifySelection(_:)):
            extendSelection(by: .word, direction: .forward)
        case #selector(NSStandardKeyBindingResponding.moveUpAndModifySelection(_:)):
            extendSelection(by: .line, direction: .backward)
        case #selector(NSStandardKeyBindingResponding.moveDownAndModifySelection(_:)):
            extendSelection(by: .line, direction: .forward)
        case #selector(NSStandardKeyBindingResponding.moveToBeginningOfLineAndModifySelection(_:)):
            extendSelection(by: .lineBoundary, direction: .backward)
        case #selector(NSStandardKeyBindingResponding.moveToEndOfLineAndModifySelection(_:)):
            extendSelection(by: .lineBoundary, direction: .forward)
        case #selector(NSStandardKeyBindingResponding.moveToBeginningOfDocumentAndModifySelection(_:)):
            extendSelection(by: .document, direction: .backward)
        case #selector(NSStandardKeyBindingResponding.moveToEndOfDocumentAndModifySelection(_:)):
            extendSelection(by: .document, direction: .forward)
        default:
            super.doCommand(by: selector)
        }
    }

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func menu(for _: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        return makeContextMenu()
    }

    private func makeContextMenu() -> NSMenu? {
        guard let menu = NSTextView.defaultMenu?.copy() as? NSMenu else {
            return nil
        }
        menu.autoenablesItems = true
        return menu
    }

    @objc func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
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
        NSPasteboard.general.setString(Self.userVisibleString(selectedText), forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        setSelectedRange(NSRange(location: 0, length: textStorage.length))
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .staticText
    }

    override func accessibilityValue() -> Any? {
        Self.userVisibleString(textStorage.string)
    }

    override func accessibilitySelectedText() -> String? {
        guard selectedRange.length > 0 else {
            return nil
        }
        return Self.userVisibleString((textStorage.string as NSString).substring(with: selectedRange))
    }

    private static func userVisibleString(_ string: String) -> String {
        string.replacingOccurrences(
            of: ReviewMonitorCommandOutputDisplayDocument.toggleAttachmentCharacter,
            with: ""
        )
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
            layoutTextViewport()
        }
        needsLayout = true
        needsDisplay = true
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

    private func textReplacementInvalidationStartUTF16Offset(for range: NSRange) -> Int {
        let string = textStorage.string as NSString
        guard string.length > 0,
              range.location < string.length
        else {
            return clampUTF16Offset(range.location)
        }
        return string.paragraphRange(for: NSRange(location: range.location, length: 0)).location
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

    private func updateDecorationRects() {
        let visibleDecorations = currentDecorations.filter { decorationNeedsResolvedRect($0.style) }
        guard visibleDecorations.isEmpty == false,
              bounds.width > 0
        else {
            decorationView.decorations = []
            return
        }

        let horizontalInset = max(8, textContainerInset.width - 8)
        let verticalInset: CGFloat = 4
        let panelWidth = min(
            max(0, textContentView.bounds.width - horizontalInset * 2),
            textContainer.size.width + 16
        )
        let resolved = visibleDecorations.compactMap { decoration -> ReviewMonitorLogResolvedDecoration? in
            let segmentRects = rects(forCharacterRange: decoration.range).map(\.rectValue)
            guard var rect = segmentRects.first else {
                return nil
            }
            for segmentRect in segmentRects.dropFirst() {
                rect = rect.union(segmentRect)
            }
            rect = NSRect(
                x: horizontalInset,
                y: max(0, rect.minY - verticalInset),
                width: panelWidth,
                height: rect.height + verticalInset * 2
            )
            return ReviewMonitorLogResolvedDecoration(style: decoration.style, rect: rect)
        }
        decorationView.decorations = resolved
    }

    private var commandOutputPanelLineHeight: CGFloat {
        ceil(monoFont.ascender - monoFont.descender + monoFont.leading)
    }

    private var commandOutputPanelBackgroundAlpha: CGFloat {
        let workspace = NSWorkspace.shared
        if workspace.accessibilityDisplayShouldReduceTransparency ||
            workspace.accessibilityDisplayShouldIncreaseContrast {
            return 1
        }
        return 0.3
    }

    private func observeAccessibilityDisplayOptions() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @objc private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        syncCommandOutputPanelBackgroundAppearance()
    }

    private func syncCommandOutputPanelBackgroundAppearance() {
        let alpha = commandOutputPanelBackgroundAlpha
        for fragmentView in visibleFragmentViews {
            fragmentView.setCommandOutputPanelBackgroundAlpha(alpha)
        }
    }

    private func decorationNeedsResolvedRect(_ style: ReviewMonitorLogDecorationStyle) -> Bool {
        switch style {
        case .transcript, .command, .terminal, .codeBlock, .plan, .reasoning, .tool, .diagnostic, .error, .event:
            return false
        }
    }

    private func syncContentSubviewFrames() {
        textContentView.frame = bounds
        decorationView.frame = textContentView.bounds
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

    private enum KeyboardMoveUnit {
        case character
        case word
        case line
        case lineBoundary
        case document
    }

    private enum KeyboardMoveDirection {
        case backward
        case forward
    }

    private func moveInsertionPoint(by unit: KeyboardMoveUnit, direction: KeyboardMoveDirection) {
        if selectedRange.length > 0 {
            let collapsedOffset = characterBoundaryOffset(
                at: direction == .backward ? selectedRange.location : NSMaxRange(selectedRange),
                rounding: direction
            )
            setSelectedRange(NSRange(location: collapsedOffset, length: 0))
            scrollRangeToVisible(selectedRange)
            return
        }

        let movedOffset = keyboardMovedOffset(from: selectedRange.location, unit: unit, direction: direction)
        setSelectedRange(NSRange(location: movedOffset, length: 0))
        scrollRangeToVisible(selectedRange)
    }

    private func extendSelection(by unit: KeyboardMoveUnit, direction: KeyboardMoveDirection) {
        let initialFocus = keyboardSelectionFocusUTF16Offset ?? keyboardSelectionFocus(for: direction)
        let anchor = keyboardSelectionAnchorUTF16Offset ?? initialFocus
        let movedFocus = keyboardMovedOffset(from: initialFocus, unit: unit, direction: direction)
        keyboardSelectionAnchorUTF16Offset = anchor
        keyboardSelectionFocusUTF16Offset = movedFocus
        setSelectedRange(rangeBetween(anchor, movedFocus), preserveKeyboardSelection: true)
        scrollRangeToVisible(NSRange(location: movedFocus, length: 0))
    }

    private func keyboardSelectionFocus(for direction: KeyboardMoveDirection) -> Int {
        if selectedRange.length == 0 {
            return selectedRange.location
        }
        return direction == .backward ? selectedRange.location : NSMaxRange(selectedRange)
    }

    private func keyboardMovedOffset(
        from offset: Int,
        unit: KeyboardMoveUnit,
        direction: KeyboardMoveDirection
    ) -> Int {
        let movedOffset: Int
        switch unit {
        case .character:
            movedOffset = characterMovedOffset(from: offset, direction: direction)
        case .word:
            movedOffset = wordMovedOffset(from: offset, direction: direction)
        case .line:
            movedOffset = lineMovedOffset(from: offset, direction: direction)
        case .lineBoundary:
            movedOffset = lineBoundaryOffset(from: offset, direction: direction)
        case .document:
            movedOffset = direction == .backward ? 0 : textStorage.length
        }
        return characterBoundaryOffset(at: movedOffset, rounding: direction)
    }

    private func rangeBetween(_ firstOffset: Int, _ secondOffset: Int) -> NSRange {
        let location = min(firstOffset, secondOffset)
        return NSRange(location: location, length: abs(firstOffset - secondOffset))
    }

    private func characterMovedOffset(from offset: Int, direction: KeyboardMoveDirection) -> Int {
        let string = textStorage.string
        guard string.isEmpty == false else {
            return 0
        }

        let clampedOffset = clampUTF16Offset(offset)
        let boundaryOffset = characterBoundaryOffset(at: clampedOffset, rounding: direction)
        guard boundaryOffset == clampedOffset,
              let currentIndex = stringIndex(atUTF16Offset: boundaryOffset, in: string)
        else {
            return boundaryOffset
        }

        switch direction {
        case .backward:
            guard currentIndex > string.startIndex else {
                return 0
            }
            return string.index(before: currentIndex).utf16Offset(in: string)
        case .forward:
            guard currentIndex < string.endIndex else {
                return textStorage.length
            }
            return string.index(after: currentIndex).utf16Offset(in: string)
        }
    }

    private func characterBoundaryOffset(at offset: Int, rounding direction: KeyboardMoveDirection) -> Int {
        let string = textStorage.string
        let clampedOffset = clampUTF16Offset(offset)
        guard string.isEmpty == false else {
            return 0
        }

        var previousOffset = 0
        for index in string.indices {
            let currentOffset = index.utf16Offset(in: string)
            if currentOffset == clampedOffset {
                return currentOffset
            }
            if currentOffset > clampedOffset {
                return direction == .backward ? previousOffset : currentOffset
            }
            previousOffset = currentOffset
        }

        let endOffset = string.endIndex.utf16Offset(in: string)
        if clampedOffset == endOffset {
            return endOffset
        }
        return direction == .backward ? previousOffset : endOffset
    }

    private func stringIndex(atUTF16Offset offset: Int, in string: String) -> String.Index? {
        guard offset >= 0, offset <= string.utf16.count else {
            return nil
        }
        let utf16Index = string.utf16.index(string.utf16.startIndex, offsetBy: offset)
        return String.Index(utf16Index, within: string)
    }

    private func wordMovedOffset(from offset: Int, direction: KeyboardMoveDirection) -> Int {
        let string = textStorage.string as NSString
        let length = string.length
        guard length > 0 else {
            return 0
        }

        let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-./:"))

        func isWordCharacter(at index: Int) -> Bool {
            guard index >= 0, index < length,
                  let scalar = UnicodeScalar(string.character(at: index))
            else {
                return false
            }
            return wordCharacters.contains(scalar)
        }

        switch direction {
        case .backward:
            var index = clampUTF16Offset(offset)
            while index > 0, isWordCharacter(at: index - 1) == false {
                index -= 1
            }
            while index > 0, isWordCharacter(at: index - 1) {
                index -= 1
            }
            return index
        case .forward:
            var index = clampUTF16Offset(offset)
            while index < length, isWordCharacter(at: index) {
                index += 1
            }
            while index < length, isWordCharacter(at: index) == false {
                index += 1
            }
            return index
        }
    }

    private func lineMovedOffset(from offset: Int, direction: KeyboardMoveDirection) -> Int {
        switch direction {
        case .backward:
            return textSelectionNavigationMovedOffset(
                from: offset,
                direction: .up,
                destination: .character,
                rounding: direction
            ) ?? lineBoundaryOffset(from: offset, direction: .backward)
        case .forward:
            return textSelectionNavigationMovedOffset(
                from: offset,
                direction: .down,
                destination: .character,
                rounding: direction
            ) ?? lineBoundaryOffset(from: offset, direction: .forward)
        }
    }

    private func lineBoundaryOffset(from offset: Int, direction: KeyboardMoveDirection) -> Int {
        switch direction {
        case .backward:
            return textSelectionNavigationMovedOffset(
                from: offset,
                direction: .left,
                destination: .line,
                rounding: direction
            ) ?? 0
        case .forward:
            return textSelectionNavigationMovedOffset(
                from: offset,
                direction: .right,
                destination: .line,
                rounding: direction
            ) ?? textStorage.length
        }
    }

    private func textSelectionNavigationMovedOffset(
        from offset: Int,
        direction: NSTextSelectionNavigation.Direction,
        destination: NSTextSelectionNavigation.Destination,
        rounding: KeyboardMoveDirection
    ) -> Int? {
        let boundaryOffset = characterBoundaryOffset(at: offset, rounding: rounding)
        guard let textRange = textRange(for: NSRange(location: boundaryOffset, length: 0)) else {
            return nil
        }

        layoutTextViewport()
        textLayoutManager.ensureLayout(for: textRange)
        guard let destinationSelection = textLayoutManager.textSelectionNavigation.destinationSelection(
            for: NSTextSelection([textRange], affinity: .downstream, granularity: .character),
            direction: direction,
            destination: destination,
            extending: false,
            confined: false
        ),
            let destinationRange = destinationSelection.textRanges.first
        else {
            return nil
        }

        let range = nsRange(for: destinationRange)
        if range.length == 0 {
            return range.location
        }
        return rounding == .backward ? range.location : NSMaxRange(range)
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

    private func textLocation(forUTF16Offset offset: Int) -> (any NSTextLocation)? {
        textContentStorage.location(
            textContentStorage.documentRange.location,
            offsetBy: clampUTF16Offset(offset)
        )
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
        let alignedFrame = backingAlignedRect(layoutFragmentFrame, options: .alignAllEdgesOutward)
        let fragmentView: ReviewMonitorLogFragmentView
        var fragmentNeedsImmediateDisplay = false
        if let cachedFragmentView = fragmentViewMap.object(forKey: textLayoutFragment) {
            fragmentView = cachedFragmentView
            lastUsedFragmentViews.remove(cachedFragmentView)
        } else {
            fragmentView = ReviewMonitorLogFragmentView(
                layoutFragment: textLayoutFragment,
                frame: alignedFrame
            )
            fragmentViewMap.setObject(fragmentView, forKey: textLayoutFragment)
            fragmentNeedsImmediateDisplay = true
        }

        if fragmentView.superview !== fragmentViewportView {
            fragmentViewportView.addSubview(fragmentView)
            fragmentNeedsImmediateDisplay = true
        }

        if rectsAreNearlyEqual(fragmentView.frame, alignedFrame) == false {
            fragmentView.frame = alignedFrame
            fragmentView.needsDisplay = true
            fragmentNeedsImmediateDisplay = true
        }

        let attachmentViewProviders = textLayoutFragment.textAttachmentViewProviders.isEmpty
            ? commandOutputAttachmentViewProviders(in: textLayoutFragment, parentView: fragmentView)
            : textLayoutFragment.textAttachmentViewProviders
        fragmentView.syncTextAttachmentViews(
            attachmentViewProviders,
            commandOutputPanelBackgroundAlpha: commandOutputPanelBackgroundAlpha
        )
        if fragmentNeedsImmediateDisplay {
            fragmentView.needsDisplay = true
        }
        visibleFragmentViews.insert(fragmentView)
    }

    private func commandOutputAttachmentViewProviders(
        in layoutFragment: NSTextLayoutFragment,
        parentView: NSView
    ) -> [NSTextAttachmentViewProvider] {
        let fragmentRange = clamp(nsRange(for: layoutFragment.rangeInElement))
        guard fragmentRange.length > 0 else {
            return []
        }

        var providers: [NSTextAttachmentViewProvider] = []
        textStorage.enumerateAttribute(.attachment, in: fragmentRange) { value, range, _ in
            guard let attachment = value as? NSTextAttachment,
                  (attachment is ReviewMonitorCommandOutputToggleAttachment ||
                    attachment is ReviewMonitorCommandOutputPanelAttachment),
                  let location = textLocation(forUTF16Offset: range.location),
                  let provider = attachment.viewProvider(
                      for: parentView,
                      location: location,
                      textContainer: textContainer
                  )
            else {
                return
            }
            providers.append(provider)
        }
        return providers
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
        updateDecorationRects()
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


#if DEBUG
@MainActor
extension ReviewMonitorLogDocumentView {
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

    var commandOutputPanelCountForTesting: Int {
        layoutTextViewport(force: true)
        return currentCommandOutputPanels.count
    }

    var expandedCommandOutputPanelCountForTesting: Int {
        layoutTextViewport(force: true)
        return currentCommandOutputPanels.filter(\.isExpanded).count
    }

    var commandOutputPanelUsesTextKit2ForTesting: Bool {
        layoutTextViewport(force: true)
        let visiblePanelViews = visibleCommandOutputPanelAttachmentViewsForTesting()
        guard visiblePanelViews.isEmpty == false else {
            return false
        }
        return visiblePanelViews.allSatisfy(\.usesTextKit2ForTesting)
    }

    var commandOutputPanelUsesInlineAttachmentForTesting: Bool {
        layoutTextViewport(force: true)
        return firstCommandOutputToggleAttachmentForTesting() != nil
    }

    var commandOutputPanelUsesButtonAttachmentForTesting: Bool {
        layoutTextViewport(force: true)
        return firstCommandOutputToggleButtonForTesting() != nil
    }

    var commandOutputPanelUsesSystemMaterialBackgroundForTesting: Bool {
        layoutTextViewport(force: true)
        let visiblePanelViews = visibleCommandOutputPanelAttachmentViewsForTesting()
        guard visiblePanelViews.isEmpty == false else {
            return false
        }
        return visiblePanelViews.allSatisfy(\.usesSystemMaterialBackgroundForTesting)
    }

    var commandOutputPanelVisibleLineCapacityForTesting: Int {
        layoutTextViewport(force: true)
        return visibleCommandOutputPanelAttachmentViewsForTesting()
            .map(\.visibleLineCapacityForTesting)
            .max() ?? 0
    }

    var commandOutputPanelResultTextForTesting: String? {
        layoutTextViewport(force: true)
        return firstVisibleCommandOutputPanelViewForTesting()?.resultTextForTesting
    }

    var commandOutputPanelTerminalTextForTesting: String? {
        layoutTextViewport(force: true)
        return firstVisibleCommandOutputPanelViewForTesting()?.terminalTextForTesting
    }

    var commandOutputPanelCommandLineTextForTesting: String? {
        layoutTextViewport(force: true)
        return firstVisibleCommandOutputPanelViewForTesting()?.commandLineTextForTesting
    }

    var commandOutputPanelOutputScrollTextForTesting: String? {
        layoutTextViewport(force: true)
        return firstVisibleCommandOutputPanelViewForTesting()?.outputScrollTextForTesting
    }

    var commandOutputPanelOutputScrollIsScrollableForTesting: Bool {
        layoutTextViewport(force: true)
        return firstVisibleCommandOutputPanelViewForTesting()?.outputScrollIsScrollableForTesting ?? false
    }

    var commandOutputPanelOutputScrollVerticalOffsetForTesting: CGFloat? {
        layoutTextViewport(force: true)
        return firstVisibleCommandOutputPanelViewForTesting()?.outputScrollVerticalOffsetForTesting
    }

    var commandOutputPanelOutputScrollMaximumVerticalOffsetForTesting: CGFloat? {
        layoutTextViewport(force: true)
        return firstVisibleCommandOutputPanelViewForTesting()?.outputScrollMaximumVerticalOffsetForTesting
    }

    func scrollCommandOutputPanelOutputForTesting(deltaY: CGFloat) -> Bool {
        layoutTextViewport(force: true)
        return firstVisibleCommandOutputPanelViewForTesting()?.scrollOutputForTesting(deltaY: deltaY) ?? false
    }

    var commandOutputPanelToggleSymbolNameForTesting: String? {
        layoutTextViewport(force: true)
        return firstCommandOutputToggleAttachmentForTesting()?.symbolName
    }

    var commandOutputPanelLeadingAlignmentDeltaForTesting: CGFloat? {
        layoutTextViewport(force: true)
        guard let panel = currentCommandOutputPanels.first,
              let panelView = firstVisibleCommandOutputPanelViewForTesting(),
              let attachmentLeadingX = rects(forCharacterRange: NSRange(location: panel.range.location, length: 1))
                .first?.rectValue.minX
        else {
            return nil
        }
        let panelLeadingX = panelView.convert(panelView.bounds.origin, to: self).x
        return panelLeadingX - attachmentLeadingX
    }

    var commandOutputPanelChevronSizeDeltaForTesting: CGFloat? {
        layoutTextViewport(force: true)
        guard let attachment = firstCommandOutputToggleAttachmentForTesting() else {
            return nil
        }
        return attachment.symbolSize - attachment.fontPointSize
    }

    var commandOutputPanelChevronVerticalAlignmentDeltaForTesting: CGFloat? {
        layoutTextViewport(force: true)
        guard let panel = currentCommandOutputPanels.first,
              panel.range.length > 1,
              let attachmentMidY = rects(forCharacterRange: NSRange(location: panel.range.location, length: 1))
                .first?.rectValue.midY,
              let labelMidY = rects(forCharacterRange: NSRange(location: panel.range.location + 1, length: panel.range.length - 1))
                .first?.rectValue.midY
        else {
            return nil
        }
        return attachmentMidY - labelMidY
    }

    func hitTestTargetsDocumentViewForFirstOccurrenceForTesting(_ text: String) -> Bool {
        layoutTextViewport(force: true)
        let range = (textStorage.string as NSString).range(of: text)
        guard range.location != NSNotFound,
              let rect = rects(forCharacterRange: range).first?.rectValue
        else {
            return false
        }
        return hitTest(NSPoint(x: rect.midX, y: rect.midY)) === self
    }

    func toggleFirstCommandOutputPanelForTesting() {
        layoutTextViewport(force: true)
        guard let blockID = currentCommandOutputPanels.first?.blockID else {
            return
        }
        onCommandOutputPanelToggle?(blockID)
    }

    @discardableResult
    func clickFirstCommandOutputPanelHeaderForTesting() -> Bool {
        layoutTextViewport(force: true)
        guard let panel = currentCommandOutputPanels.first,
              let rect = rects(forCharacterRange: NSRange(location: panel.range.location, length: 1)).first?.rectValue,
              let event = NSEvent.mouseEvent(
                  with: .leftMouseDown,
                  location: convert(NSPoint(x: rect.midX, y: rect.midY), to: nil),
                  modifierFlags: [],
                  timestamp: 0,
                  windowNumber: window?.windowNumber ?? 0,
                  context: nil,
                  eventNumber: 0,
                  clickCount: 1,
                  pressure: 1
              )
        else {
            return false
        }

        let documentPoint = convert(event.locationInWindow, from: nil)
        guard let target = hitTest(documentPoint) else {
            return false
        }
        if let button = target as? ReviewMonitorCommandOutputToggleButton {
            button.performClick(nil)
            return true
        }
        target.mouseDown(with: event)
        return true
    }

    private func firstCommandOutputToggleAttachmentForTesting() -> ReviewMonitorCommandOutputToggleAttachment? {
        guard let panel = currentCommandOutputPanels.first,
              panel.range.location < textStorage.length
        else {
            return nil
        }
        return textStorage.attribute(.attachment, at: panel.range.location, effectiveRange: nil)
            as? ReviewMonitorCommandOutputToggleAttachment
    }

    private func firstCommandOutputToggleButtonForTesting() -> ReviewMonitorCommandOutputToggleButton? {
        visibleFragmentViews
            .sorted { $0.frame.minY < $1.frame.minY }
            .compactMap(\.firstCommandOutputToggleButtonForTesting)
            .first
    }

    private func firstVisibleCommandOutputPanelViewForTesting() -> ReviewMonitorCommandOutputPanelAttachmentView? {
        visibleCommandOutputPanelAttachmentViewsForTesting()
            .sorted { lhs, rhs in
                lhs.convert(lhs.bounds.origin, to: self).y < rhs.convert(rhs.bounds.origin, to: self).y
            }
            .first
    }

    private func visibleCommandOutputPanelAttachmentViewsForTesting() -> [ReviewMonitorCommandOutputPanelAttachmentView] {
        visibleFragmentViews.flatMap { fragmentView in
            fragmentView.subviews.compactMap { $0 as? ReviewMonitorCommandOutputPanelAttachmentView }
        }
    }

    var wordGlowCountForTesting: Int {
        wordFadeAnimations.count
    }

    var wordFadeRenderingAttributeRangeCountForTesting: Int {
        var count = 0
        textLayoutManager.enumerateRenderingAttributes(
            from: textContentStorage.documentRange.location,
            reverse: false
        ) { _, attributes, _ in
            if attributes[.foregroundColor] != nil {
                count += 1
            }
            return true
        }
        return count
    }

    var wordFadeStorageUsesOpaqueTextColorForTesting: Bool {
        guard textStorage.length > 0 else {
            return true
        }

        var usesOpaqueTextColor = true
        textStorage.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: textStorage.length)
        ) { value, _, stop in
            guard let color = value as? NSColor else {
                return
            }
            if color.alphaComponent < 0.999 {
                usesOpaqueTextColor = false
                stop.pointee = true
            }
        }
        return usesOpaqueTextColor
    }

    var wordFadeDisplayInvalidationCountForTesting: Int {
        wordFadeDisplayInvalidationCount
    }

    func completeWordGlowAnimationsForTesting() {
        glowTimer?.invalidate()
        glowTimer = nil
        let completionTime = wordFadeAnimations
            .map(\.startedAt)
            .max()
            .map { $0 + Self.wordFadeDuration }
            ?? CACurrentMediaTime()
        updateWordFadeAnimations(at: completionTime)
    }

    func contextMenuForTesting() -> NSMenu? {
        window?.makeFirstResponder(self)
        return makeContextMenu()
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
