import AppKit

struct ReviewMonitorLogResolvedDecoration: Equatable {
    var style: ReviewMonitorLogDecorationStyle
    var rect: NSRect
}

@MainActor
final class ReviewMonitorLogDecorationView: NSView {
    var decorations: [ReviewMonitorLogResolvedDecoration] = [] {
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
        guard decorations.isEmpty == false else {
            return
        }

        for decoration in decorations where decoration.rect.intersects(dirtyRect) {
            draw(decoration)
        }
    }

    private func draw(_ decoration: ReviewMonitorLogResolvedDecoration) {
        if case .contextCompaction(let label, _) = decoration.style {
            drawContextCompactionMarker(in: decoration.rect, label: label)
            return
        }

        let palette = palette(for: decoration.style)
        guard palette.background.alphaComponent > 0 else {
            return
        }
        let rect = decoration.rect
        let backgroundPath = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        palette.background.setFill()
        backgroundPath.fill()
    }

    private func palette(for style: ReviewMonitorLogDecorationStyle) -> Palette {
        switch style {
        case .transcript, .command, .plan, .reasoning, .tool, .diagnostic, .event:
            return .init(
                background: NSColor.clear
            )
        case .terminal:
            return .init(
                background: NSColor.labelColor.withAlphaComponent(0.055)
            )
        case .codeBlock, .error:
            return .init(
                background: NSColor.clear
            )
        case .contextCompaction(_, _):
            return .init(
                background: NSColor.clear
            )
        }
    }

    private func drawContextCompactionMarker(
        in rect: NSRect,
        label: String
    ) {
        let lineColor = NSColor.secondaryLabelColor.withAlphaComponent(0.28)
        let labelFont = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize)
        let labelWidth = ceil((label as NSString).size(withAttributes: [.font: labelFont]).width)
        let centerWidth = labelWidth + 28
        let centerMinX = rect.midX - centerWidth / 2
        let centerMaxX = rect.midX + centerWidth / 2
        let lineY = floor(rect.midY) + 0.5
        let leftLine = NSRect(
            x: rect.minX,
            y: lineY,
            width: max(0, centerMinX - rect.minX),
            height: 1
        )
        let rightLine = NSRect(
            x: centerMaxX,
            y: lineY,
            width: max(0, rect.maxX - centerMaxX),
            height: 1
        )

        lineColor.setFill()
        leftLine.fill()
        rightLine.fill()
    }

    private struct Palette {
        var background: NSColor
    }
}

@MainActor
final class ReviewMonitorLogFragmentView: NSView {
    var layoutFragment: NSTextLayoutFragment {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
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

    func syncTextAttachmentViews(
        _ providers: [NSTextAttachmentViewProvider],
        commandOutputPanelBackgroundAlpha: CGFloat
    ) {
        var visibleAttachmentViews = Set<ObjectIdentifier>()
        for provider in providers {
            let attachmentView: NSView?
            switch provider {
            case let provider as ReviewMonitorCommandOutputToggleAttachmentViewProvider:
                attachmentView = commandOutputToggleButton(for: provider)
            case let provider as ReviewMonitorCommandOutputTimerAttachmentViewProvider:
                attachmentView = commandOutputTimerView(for: provider)
            case let provider as ReviewMonitorCommandOutputPanelAttachmentViewProvider:
                attachmentView = commandOutputPanelAttachmentView(
                    for: provider,
                    backgroundAlpha: commandOutputPanelBackgroundAlpha
                )
            default:
                attachmentView = nil
            }
            guard let attachmentView else {
                continue
            }
            let targetFrame = layoutFragment
                .frameForTextAttachment(at: provider.location)
                .integral
            guard targetFrame.isEmpty == false else {
                continue
            }
            if attachmentView.superview !== self {
                attachmentView.frame = targetFrame
                addSubview(attachmentView)
                attachmentView.needsLayout = true
            } else if rectsAreNearlyEqual(attachmentView.frame, targetFrame) == false {
                attachmentView.frame = targetFrame
                attachmentView.needsLayout = true
            }
            visibleAttachmentViews.insert(ObjectIdentifier(attachmentView))
        }

        for subview in subviews where subview is ReviewMonitorCommandOutputToggleButton ||
            subview is ReviewMonitorCommandOutputTimerAttachmentView ||
            subview is ReviewMonitorCommandOutputPanelAttachmentView {
            guard visibleAttachmentViews.contains(ObjectIdentifier(subview)) == false else {
                continue
            }
            subview.removeFromSuperview()
        }
    }

    private func commandOutputToggleButton(
        for provider: ReviewMonitorCommandOutputToggleAttachmentViewProvider
    ) -> ReviewMonitorCommandOutputToggleButton? {
        guard let attachment = provider.textAttachment as? ReviewMonitorCommandOutputToggleAttachment else {
            return nil
        }
        if let existingButton = subviews.compactMap({ $0 as? ReviewMonitorCommandOutputToggleButton })
            .first(where: { $0.blockID == attachment.blockID }) {
            existingButton.configure(attachment: attachment)
            return existingButton
        }
        return provider.configureView()
    }

    private func commandOutputTimerView(
        for provider: ReviewMonitorCommandOutputTimerAttachmentViewProvider
    ) -> ReviewMonitorCommandOutputTimerAttachmentView? {
        guard let attachment = provider.textAttachment as? ReviewMonitorCommandOutputTimerAttachment else {
            return nil
        }
        if let existingTimerView = subviews.compactMap({ $0 as? ReviewMonitorCommandOutputTimerAttachmentView })
            .first(where: { $0.blockID == attachment.blockID }) {
            existingTimerView.configure(attachment: attachment)
            return existingTimerView
        }
        return provider.configureView()
    }

    private func commandOutputPanelAttachmentView(
        for provider: ReviewMonitorCommandOutputPanelAttachmentViewProvider,
        backgroundAlpha: CGFloat
    ) -> ReviewMonitorCommandOutputPanelAttachmentView? {
        guard let attachment = provider.textAttachment as? ReviewMonitorCommandOutputPanelAttachment else {
            return nil
        }
        if let existingPanelView = subviews.compactMap({ $0 as? ReviewMonitorCommandOutputPanelAttachmentView })
            .first(where: { $0.blockID == attachment.blockID }) {
            existingPanelView.configure(attachment: attachment, backgroundAlpha: backgroundAlpha)
            return existingPanelView
        }
        return provider.configureView(backgroundAlpha: backgroundAlpha)
    }

    func setCommandOutputPanelBackgroundAlpha(_ alpha: CGFloat) {
        for panelView in subviews.compactMap({ $0 as? ReviewMonitorCommandOutputPanelAttachmentView }) {
            panelView.setBackgroundAlpha(alpha)
        }
    }

#if DEBUG
    var firstCommandOutputToggleButtonForTesting: ReviewMonitorCommandOutputToggleButton? {
        subviews.compactMap { $0 as? ReviewMonitorCommandOutputToggleButton }.first
    }

    var firstCommandOutputPanelAttachmentViewForTesting: ReviewMonitorCommandOutputPanelAttachmentView? {
        subviews.compactMap { $0 as? ReviewMonitorCommandOutputPanelAttachmentView }.first
    }
#endif
}

private func rectsAreNearlyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
    abs(lhs.minX - rhs.minX) <= 0.5 &&
        abs(lhs.minY - rhs.minY) <= 0.5 &&
        abs(lhs.width - rhs.width) <= 0.5 &&
        abs(lhs.height - rhs.height) <= 0.5
}

struct ReviewMonitorLogWordFadeAnimation {
    var range: NSRange
    var startedAt: TimeInterval?
    var delay: TimeInterval
    var renderedStep: Int
    var baseColor: NSColor
}

@MainActor
final class ReviewMonitorLogSelectionView: NSView {
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
