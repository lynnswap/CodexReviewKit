import AppKit

struct ReviewMonitorLogResolvedDecoration: Equatable {
    var style: ReviewMonitorLogDecorationStyle
    var rect: NSRect
}

struct ReviewMonitorCommandOutputToggleAttachmentPlacement {
    var attachment: ReviewMonitorCommandOutputToggleAttachment
    var location: any NSTextLocation
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
        }
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

    func syncTextAttachmentViews(_ placements: [ReviewMonitorCommandOutputToggleAttachmentPlacement]) {
        var visibleAttachmentViews = Set<ObjectIdentifier>()
        for placement in placements {
            let attachment = placement.attachment
            let button = commandOutputToggleButton(for: attachment)
            button.configure(attachment: attachment)
            button.frame = layoutFragment
                .frameForTextAttachment(at: placement.location)
                .integral
            if button.superview !== self {
                addSubview(button)
            }
            visibleAttachmentViews.insert(ObjectIdentifier(button))
        }

        for subview in subviews where subview is ReviewMonitorCommandOutputToggleButton {
            guard visibleAttachmentViews.contains(ObjectIdentifier(subview)) == false else {
                continue
            }
            subview.removeFromSuperview()
        }
    }

    private func commandOutputToggleButton(
        for attachment: ReviewMonitorCommandOutputToggleAttachment
    ) -> ReviewMonitorCommandOutputToggleButton {
        if let existingButton = subviews.compactMap({ $0 as? ReviewMonitorCommandOutputToggleButton })
            .first(where: { $0.blockID == attachment.blockID }) {
            return existingButton
        }
        return ReviewMonitorCommandOutputToggleButton(attachment: attachment)
    }

#if DEBUG
    var firstCommandOutputToggleButtonForTesting: ReviewMonitorCommandOutputToggleButton? {
        subviews.compactMap { $0 as? ReviewMonitorCommandOutputToggleButton }.first
    }
#endif
}

struct ReviewMonitorLogWordFadeAnimation {
    var range: NSRange
    var startedAt: TimeInterval
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

