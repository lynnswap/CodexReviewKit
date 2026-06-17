import AppKit
import QuartzCore

public enum TextTransition {}

public extension TextTransition {
    struct Content: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case identity
            case opacity
            case numericText(countsDown: Bool)
            case numericTextValue(Double)
        }

        var kind: Kind

        public static let identity = TextTransition.Content(kind: .identity)
        public static let opacity = TextTransition.Content(kind: .opacity)

        public static func numericText(countsDown: Bool = false) -> TextTransition.Content {
            TextTransition.Content(kind: .numericText(countsDown: countsDown))
        }

        public static func numericText(value: Double) -> TextTransition.Content {
            TextTransition.Content(kind: .numericTextValue(value))
        }
    }
}

public extension TextTransition {
    enum WidthReservation: @unchecked Sendable {
        case natural
        case fixed(CGSize)
        case sample(NSAttributedString)
    }
}

extension TextTransition.WidthReservation: Equatable {
    public static func == (lhs: TextTransition.WidthReservation, rhs: TextTransition.WidthReservation) -> Bool {
        switch (lhs, rhs) {
        case (.natural, .natural):
            return true
        case (.fixed(let lhsSize), .fixed(let rhsSize)):
            return lhsSize == rhsSize
        case (.sample(let lhsSample), .sample(let rhsSample)):
            return lhsSample.isEqual(to: rhsSample)
        case (.natural, _), (.fixed, _), (.sample, _):
            return false
        }
    }
}

public extension TextTransition {
    enum MotionPolicy: Equatable, Sendable {
        case system
        case enabled
        case disabled

        @MainActor
        var allowsAnimation: Bool {
            switch self {
            case .system:
                return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false
            case .enabled:
                return true
            case .disabled:
                return false
            }
        }
    }
}

@MainActor
public final class TextTransitionView: NSView {
    private nonisolated static let transitionDuration: CFTimeInterval = 0.22
    private nonisolated static let fadeTransitionDuration: CFTimeInterval = 0.14

    private struct Glyph {
        var string: String
        var attributedString: NSAttributedString
        var isNumeric: Bool
    }

    private struct GlyphRun {
        var range: Range<Int>
    }

    private struct RenderedSlot {
        var index: Int
        var layer: CALayer
        var glyph: Glyph
        var frame: CGRect
    }

    private enum NumericTransitionDirection: Equatable {
        case countingUp
        case countingDown
    }

    private struct ActiveTransitionOverlay {
        var layer: CALayer
        var direction: NumericTransitionDirection?
    }

    public private(set) var text: NSAttributedString
    public var contentTransition: TextTransition.Content
    public var widthReservation: TextTransition.WidthReservation {
        didSet {
            guard oldValue != widthReservation else {
                return
            }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    public var motionPolicy: TextTransition.MotionPolicy {
        didSet {
            if motionPolicy.allowsAnimation == false {
                completeTransitions()
            }
        }
    }

    private var characterSlotLayers: [CALayer] = []
    private var activeTransitionOverlays: [ActiveTransitionOverlay] = []
    private var hiddenFinalLayers: [CALayer] = []
    private var transitionGeneration = 0
    private var previousNumericValue: Double?

    override public var isFlipped: Bool {
        true
    }

    override public var intrinsicContentSize: NSSize {
        textTransitionPreferredSize(for: text, widthReservation: widthReservation)
    }

    public init(
        text: NSAttributedString = NSAttributedString(string: ""),
        contentTransition: TextTransition.Content = .numericText(),
        widthReservation: TextTransition.WidthReservation = .natural,
        motionPolicy: TextTransition.MotionPolicy = .system
    ) {
        self.text = text.copy() as? NSAttributedString ?? text
        self.contentTransition = contentTransition
        self.widthReservation = widthReservation
        self.motionPolicy = motionPolicy
        self.previousNumericValue = contentTransition.numericValue
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        updateAccessibilityText()
        renderText(self.text, previousText: nil, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        renderText(text, previousText: nil, animated: false)
    }

    public func configure(
        text: NSAttributedString,
        contentTransition: TextTransition.Content,
        widthReservation: TextTransition.WidthReservation,
        motionPolicy: TextTransition.MotionPolicy,
        animated: Bool = false
    ) {
        self.contentTransition = contentTransition
        self.widthReservation = widthReservation
        self.motionPolicy = motionPolicy
        setText(text, animated: animated)
    }

    public func setText(_ text: NSAttributedString, animated: Bool = true) {
        let nextText = text.copy() as? NSAttributedString ?? text
        let textChanged = self.text.isEqual(to: nextText) == false
        guard textChanged else {
            previousNumericValue = contentTransition.numericValue ?? previousNumericValue
            return
        }
        let previousText = self.text.length > 0 ? self.text : nil
        let shouldAnimate = animated &&
            motionPolicy.allowsAnimation &&
            previousText != nil &&
            contentTransition != .identity
        let direction = numericTransitionDirection()

        self.text = nextText
        previousNumericValue = contentTransition.numericValue ?? previousNumericValue
        updateAccessibilityText()
        renderText(
            nextText,
            previousText: previousText,
            animated: shouldAnimate,
            numericDirection: direction
        )
        invalidateIntrinsicContentSize()
    }

    public func completeTransitions() {
        transitionGeneration += 1
        performWithoutImplicitLayerActions {
            for finalLayer in hiddenFinalLayers {
                finalLayer.opacity = 1
            }
            hiddenFinalLayers.removeAll(keepingCapacity: true)
            for slotLayer in characterSlotLayers {
                slotLayer.removeAnimation(forKey: "textTransitionFade")
                slotLayer.opacity = 1
            }
            for overlay in activeTransitionOverlays {
                overlay.layer.removeAllAnimations()
                overlay.layer.removeFromSuperlayer()
            }
            activeTransitionOverlays.removeAll(keepingCapacity: true)
        }
    }

    private func updateAccessibilityText() {
        setAccessibilityLabel(text.string)
        setAccessibilityValue(text.string)
    }

    private func renderText(
        _ text: NSAttributedString,
        previousText: NSAttributedString?,
        animated: Bool,
        numericDirection: NumericTransitionDirection? = nil
    ) {
        completeTransitions()

        guard let layer else {
            return
        }

        let oldGlyphs = previousText.map(Self.glyphs(in:)) ?? []
        let newGlyphs = Self.glyphs(in: text)
        let layout = characterLayout(for: newGlyphs)
        let oldIndexByNewIndex = oldGlyphMapping(
            oldGlyphs: oldGlyphs,
            newGlyphs: newGlyphs
        )
        var renderedSlots: [RenderedSlot] = []

        performWithoutImplicitLayerActions {
            characterSlotLayers.forEach { $0.removeFromSuperlayer() }
            characterSlotLayers.removeAll(keepingCapacity: true)
            for (index, item) in layout.enumerated() {
                let slotLayer = makeSlotLayer(glyph: item.glyph, frame: item.frame)
                layer.addSublayer(slotLayer)
                characterSlotLayers.append(slotLayer)
                renderedSlots.append(.init(
                    index: index,
                    layer: slotLayer,
                    glyph: item.glyph,
                    frame: item.frame
                ))
            }
        }

        guard animated else {
            return
        }

        transitionGeneration += 1
        for slot in renderedSlots {
            let oldIndex = oldIndexByNewIndex.indices.contains(slot.index)
                ? oldIndexByNewIndex[slot.index]
                : nil
            let oldGlyph = oldIndex.flatMap { oldGlyphs.indices.contains($0) ? oldGlyphs[$0] : nil }
            animateSlotIfNeeded(
                finalSlotLayer: slot.layer,
                oldGlyph: oldGlyph,
                newGlyph: slot.glyph,
                frame: slot.frame,
                numericDirection: numericDirection
            )
        }
    }

    private func numericTransitionDirection() -> NumericTransitionDirection? {
        switch contentTransition.kind {
        case .identity, .opacity:
            return nil
        case .numericText(let countsDown):
            return countsDown ? .countingDown : .countingUp
        case .numericTextValue(let value):
            guard let previousNumericValue else {
                return .countingUp
            }
            return value < previousNumericValue ? .countingDown : .countingUp
        }
    }

    private func oldGlyphMapping(
        oldGlyphs: [Glyph],
        newGlyphs: [Glyph]
    ) -> [Int?] {
        var mapping = Array<Int?>(repeating: nil, count: newGlyphs.count)

        switch contentTransition.kind {
        case .numericText, .numericTextValue:
            let oldRuns = numericRuns(in: oldGlyphs)
            let newRuns = numericRuns(in: newGlyphs)
            for index in 0..<min(oldRuns.count, newRuns.count) {
                mapTrailingDigits(
                    oldRun: oldRuns[index],
                    newRun: newRuns[index],
                    mapping: &mapping
                )
            }
        case .identity, .opacity:
            break
        }

        var usedOldIndices = Set(mapping.compactMap(\.self))
        for newIndex in newGlyphs.indices where mapping[newIndex] == nil {
            if oldGlyphs.indices.contains(newIndex), usedOldIndices.contains(newIndex) == false {
                mapping[newIndex] = newIndex
                usedOldIndices.insert(newIndex)
            }
        }
        return mapping
    }

    private func mapTrailingDigits(
        oldRun: GlyphRun,
        newRun: GlyphRun,
        mapping: inout [Int?]
    ) {
        let oldIndices = Array(oldRun.range)
        let newIndices = Array(newRun.range)
        let pairCount = min(oldIndices.count, newIndices.count)
        guard pairCount > 0 else {
            return
        }

        for offset in 0..<pairCount {
            let newIndex = newIndices[newIndices.count - 1 - offset]
            let oldIndex = oldIndices[oldIndices.count - 1 - offset]
            mapping[newIndex] = oldIndex
        }
    }

    private func numericRuns(in glyphs: [Glyph]) -> [GlyphRun] {
        var runs: [GlyphRun] = []
        var start: Int?
        for index in glyphs.indices {
            if glyphs[index].isNumeric {
                if start == nil {
                    start = index
                }
            } else if let runStart = start {
                runs.append(.init(range: runStart..<index))
                start = nil
            }
        }
        if let start {
            runs.append(.init(range: start..<glyphs.count))
        }
        return runs
    }

    private func characterLayout(for glyphs: [Glyph]) -> [(glyph: Glyph, frame: CGRect)] {
        let lineHeight = max(1, intrinsicContentSize.height)
        var x: CGFloat = 0
        return glyphs.map { glyph in
            let width = textWidth(for: glyph)
            defer { x += width }
            return (
                glyph,
                CGRect(x: x, y: 0, width: width, height: lineHeight)
            )
        }
    }

    private static func glyphs(in text: NSAttributedString) -> [Glyph] {
        let string = text.string as NSString
        let fullRange = NSRange(location: 0, length: string.length)
        var glyphs: [Glyph] = []
        string.enumerateSubstrings(
            in: fullRange,
            options: [.byComposedCharacterSequences, .substringNotRequired]
        ) { _, range, _, _ in
            let attributedString = text.attributedSubstring(from: range)
            let string = attributedString.string
            glyphs.append(.init(
                string: string,
                attributedString: attributedString,
                isNumeric: Self.isNumericGlyph(string)
            ))
        }
        return glyphs
    }

    private static func isNumericGlyph(_ string: String) -> Bool {
        guard string.isEmpty == false else {
            return false
        }
        return string.unicodeScalars.allSatisfy {
            CharacterSet.decimalDigits.contains($0)
        }
    }

    private func textWidth(for glyph: Glyph) -> CGFloat {
        ceil(glyph.attributedString.size().width)
    }

    private func textLayer(for glyph: Glyph) -> CATextLayer {
        let textLayer = CATextLayer()
        textLayer.string = glyph.attributedString
        textLayer.contentsScale = resolvedContentsScale()
        textLayer.alignmentMode = .left
        textLayer.isWrapped = false
        textLayer.truncationMode = .none
        return textLayer
    }

    private func configureTextLayer(_ textLayer: CATextLayer, glyph: Glyph) {
        textLayer.string = glyph.attributedString
        textLayer.contentsScale = resolvedContentsScale()
    }

    private func renderTextLayer(_ textLayer: CATextLayer, in bounds: CGRect) {
        textLayer.frame = bounds
        textLayer.contentsScale = resolvedContentsScale()
    }

    private func makeSlotLayer(glyph: Glyph, frame: CGRect) -> CALayer {
        let slotLayer = CALayer()
        slotLayer.frame = frame
        slotLayer.masksToBounds = true
        let textLayer = textLayer(for: glyph)
        textLayer.frame = slotLayer.bounds
        slotLayer.addSublayer(textLayer)
        return slotLayer
    }

    private func animateSlotIfNeeded(
        finalSlotLayer: CALayer,
        oldGlyph: Glyph?,
        newGlyph: Glyph,
        frame: CGRect,
        numericDirection: NumericTransitionDirection?
    ) {
        guard oldGlyph?.string != newGlyph.string else {
            return
        }

        switch contentTransition.kind {
        case .identity:
            return
        case .opacity:
            animateFadeTransition(finalSlotLayer: finalSlotLayer)
        case .numericText, .numericTextValue:
            let oldIsNumeric = oldGlyph?.isNumeric == true
            let newIsNumeric = newGlyph.isNumeric
            guard oldIsNumeric || newIsNumeric || oldGlyph != nil else {
                return
            }
            if oldIsNumeric, newIsNumeric, let oldGlyph, let numericDirection {
                animateDigitTransition(
                    finalSlotLayer: finalSlotLayer,
                    oldGlyph: oldGlyph,
                    newGlyph: newGlyph,
                    frame: frame,
                    direction: numericDirection
                )
            } else {
                animateFadeTransition(finalSlotLayer: finalSlotLayer)
            }
        }
    }

    private func animateDigitTransition(
        finalSlotLayer: CALayer,
        oldGlyph: Glyph,
        newGlyph: Glyph,
        frame: CGRect,
        direction: NumericTransitionDirection
    ) {
        guard let layers = setupDigitTransitionLayers(
            finalSlotLayer: finalSlotLayer,
            oldGlyph: oldGlyph,
            newGlyph: newGlyph,
            frame: frame,
            direction: direction
        ) else {
            return
        }

        addTransitionAnimations(
            oldLayer: layers.oldLayer,
            newLayer: layers.newLayer,
            lineHeight: max(1, frame.height),
            overlayLayer: layers.overlayLayer,
            finalSlotLayer: finalSlotLayer,
            generation: transitionGeneration,
            direction: direction
        )
    }

    private func setupDigitTransitionLayers(
        finalSlotLayer: CALayer,
        oldGlyph: Glyph,
        newGlyph: Glyph,
        frame: CGRect,
        direction: NumericTransitionDirection
    ) -> (overlayLayer: CALayer, oldLayer: CATextLayer, newLayer: CATextLayer)? {
        guard layer != nil else {
            return nil
        }

        let overlayLayer = makeOverlayLayer(frame: frame)
        let oldLayer = textLayer(for: oldGlyph)
        let newLayer = textLayer(for: newGlyph)
        performWithoutImplicitLayerActions {
            hideFinalSlotLayer(finalSlotLayer)
            addOverlayLayer(overlayLayer, direction: direction)
            configureTextLayer(oldLayer, glyph: oldGlyph)
            configureTextLayer(newLayer, glyph: newGlyph)
            renderTextLayer(oldLayer, in: overlayLayer.bounds)
            renderTextLayer(newLayer, in: overlayLayer.bounds)
            oldLayer.opacity = 0
            newLayer.opacity = 1
            overlayLayer.addSublayer(oldLayer)
            overlayLayer.addSublayer(newLayer)
        }
        return (overlayLayer, oldLayer, newLayer)
    }

    private func addTransitionAnimations(
        oldLayer: CATextLayer,
        newLayer: CATextLayer,
        lineHeight: CGFloat,
        overlayLayer: CALayer,
        finalSlotLayer: CALayer,
        generation: Int,
        direction: NumericTransitionDirection
    ) {
        let oldTranslation = CABasicAnimation(keyPath: "transform.translation.y")
        oldTranslation.fromValue = 0
        oldTranslation.toValue = direction == .countingUp ? lineHeight : -lineHeight
        oldTranslation.duration = Self.transitionDuration
        oldTranslation.timingFunction = transitionTimingFunction()

        let oldOpacity = CABasicAnimation(keyPath: "opacity")
        oldOpacity.fromValue = 1
        oldOpacity.toValue = 0
        oldOpacity.duration = Self.transitionDuration
        oldOpacity.timingFunction = transitionTimingFunction()

        let newTranslation = CABasicAnimation(keyPath: "transform.translation.y")
        newTranslation.fromValue = direction == .countingUp ? -lineHeight : lineHeight
        newTranslation.toValue = 0
        newTranslation.duration = Self.transitionDuration
        newTranslation.timingFunction = transitionTimingFunction()

        let newOpacity = CABasicAnimation(keyPath: "opacity")
        newOpacity.fromValue = 0
        newOpacity.toValue = 1
        newOpacity.duration = Self.transitionDuration
        newOpacity.timingFunction = transitionTimingFunction()

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak overlayLayer, weak finalSlotLayer] in
            Task { @MainActor [weak self, weak overlayLayer, weak finalSlotLayer] in
                self?.finishTransition(
                    overlayLayer: overlayLayer,
                    finalSlotLayer: finalSlotLayer,
                    generation: generation
                )
            }
        }
        oldLayer.add(oldTranslation, forKey: "oldDigitTranslation")
        oldLayer.add(oldOpacity, forKey: "oldDigitOpacity")
        newLayer.add(newTranslation, forKey: "newDigitTranslation")
        newLayer.add(newOpacity, forKey: "newDigitOpacity")
        CATransaction.commit()
    }

    private func animateFadeTransition(finalSlotLayer: CALayer) {
        finalSlotLayer.add(makeFadeAnimation(), forKey: "textTransitionFade")
    }

    private func makeFadeAnimation() -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Self.fadeTransitionDuration
        fade.timingFunction = transitionTimingFunction()
        return fade
    }

    private func finishTransition(
        overlayLayer: CALayer?,
        finalSlotLayer: CALayer?,
        generation: Int
    ) {
        guard generation == transitionGeneration else {
            return
        }
        performWithoutImplicitLayerActions {
            finalSlotLayer?.opacity = 1
            overlayLayer?.removeFromSuperlayer()
            if let overlayLayer {
                activeTransitionOverlays.removeAll { $0.layer === overlayLayer }
            }
            if let finalSlotLayer {
                hiddenFinalLayers.removeAll { $0 === finalSlotLayer }
            }
        }
    }

    private func makeOverlayLayer(frame: CGRect) -> CALayer {
        let overlayLayer = CALayer()
        overlayLayer.frame = frame
        overlayLayer.masksToBounds = true
        return overlayLayer
    }

    private func addOverlayLayer(_ overlayLayer: CALayer, direction: NumericTransitionDirection) {
        layer?.addSublayer(overlayLayer)
        activeTransitionOverlays.append(.init(layer: overlayLayer, direction: direction))
    }

    private func hideFinalSlotLayer(_ finalSlotLayer: CALayer) {
        finalSlotLayer.opacity = 0
        hiddenFinalLayers.append(finalSlotLayer)
    }

    private func performWithoutImplicitLayerActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func transitionTimingFunction() -> CAMediaTimingFunction {
        CAMediaTimingFunction(name: .easeInEaseOut)
    }

    private func resolvedContentsScale() -> CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func updateContentsScale() {
        let scale = resolvedContentsScale()
        for slotLayer in characterSlotLayers {
            for sublayer in slotLayer.sublayers ?? [] {
                sublayer.contentsScale = scale
            }
        }
        for overlay in activeTransitionOverlays {
            for sublayer in overlay.layer.sublayers ?? [] {
                sublayer.contentsScale = scale
            }
        }
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }
}

extension TextTransition.Content {
    fileprivate var numericValue: Double? {
        guard case .numericTextValue(let value) = kind else {
            return nil
        }
        return value
    }
}

func textTransitionPreferredSize(
    for text: NSAttributedString,
    widthReservation: TextTransition.WidthReservation
) -> NSSize {
    switch widthReservation {
    case .natural:
        return textTransitionSize(for: text)
    case .fixed(let size):
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    case .sample(let sample):
        let textSize = textTransitionSize(for: text)
        let sampleSize = textTransitionSize(for: sample)
        return NSSize(
            width: max(textSize.width, sampleSize.width),
            height: max(textSize.height, sampleSize.height)
        )
    }
}

private func textTransitionSize(for text: NSAttributedString) -> NSSize {
    let size = text.size()
    let string = text.string as NSString
    let fullRange = NSRange(location: 0, length: string.length)
    var width: CGFloat = 0
    string.enumerateSubstrings(
        in: fullRange,
        options: [.byComposedCharacterSequences, .substringNotRequired]
    ) { _, range, _, _ in
        width += ceil(text.attributedSubstring(from: range).size().width)
    }
    return NSSize(width: width, height: ceil(size.height))
}

func textTransitionFontDescender(in text: NSAttributedString) -> CGFloat? {
    let fullRange = NSRange(location: 0, length: text.length)
    guard fullRange.length > 0 else {
        return nil
    }

    var descender: CGFloat?
    text.enumerateAttribute(.font, in: fullRange) { value, _, _ in
        guard let font = value as? NSFont else {
            return
        }
        descender = min(descender ?? font.descender, font.descender)
    }
    return descender
}

#if DEBUG
extension TextTransitionView {
    public var activeTransitionCountForTesting: Int {
        activeTransitionOverlays.count
    }

    public var renderedTextWidthForTesting: CGFloat {
        characterLayout(for: Self.glyphs(in: text)).reduce(0) { partialResult, item in
            partialResult + item.frame.width
        }
    }

    var activeTransitionDirectionsForTesting: [TextTransitionDirectionForTesting] {
        activeTransitionOverlays.compactMap { overlay in
            switch overlay.direction {
            case .countingUp:
                return .countingUp
            case .countingDown:
                return .countingDown
            case nil:
                return nil
            }
        }
    }

    var activeFadeTransitionCountForTesting: Int {
        characterSlotLayers.filter { $0.animation(forKey: "textTransitionFade") != nil }.count
    }

    var activeTransitionOldLayerOpacitiesForTesting: [Float] {
        activeTransitionOverlays.compactMap { overlay in
            overlay.layer.sublayers?.first?.opacity
        }
    }

    func completeTransitionsForTesting() {
        completeTransitions()
    }
}

enum TextTransitionDirectionForTesting: Equatable {
    case countingUp
    case countingDown
}
#endif
