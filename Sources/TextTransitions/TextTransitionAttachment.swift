import AppKit

public final class TextTransitionAttachment: NSTextAttachment {
    public private(set) var text: NSAttributedString
    public private(set) var contentTransition: TextTransition.Content
    public private(set) var widthReservation: TextTransition.WidthReservation
    public private(set) var motionPolicy: TextTransition.MotionPolicy
    public var reuseIdentifier: String?
    private let activeViews = NSHashTable<TextTransitionView>.weakObjects()

    public init(
        text: NSAttributedString,
        contentTransition: TextTransition.Content = .numericText(),
        widthReservation: TextTransition.WidthReservation = .natural,
        motionPolicy: TextTransition.MotionPolicy = .system,
        reuseIdentifier: String? = nil
    ) {
        self.text = text.copy() as? NSAttributedString ?? text
        self.contentTransition = contentTransition
        self.widthReservation = widthReservation
        self.motionPolicy = motionPolicy
        self.reuseIdentifier = reuseIdentifier
        super.init(data: nil, ofType: nil)

        allowsTextAttachmentView = true
        lineLayoutPadding = 0
        updateBounds()
    }

    @MainActor
    public func configure(
        contentTransition: TextTransition.Content? = nil,
        widthReservation: TextTransition.WidthReservation? = nil,
        motionPolicy: TextTransition.MotionPolicy? = nil
    ) {
        var shouldUpdateBounds = false
        if let contentTransition, self.contentTransition != contentTransition {
            self.contentTransition = contentTransition
        }
        if let widthReservation, self.widthReservation != widthReservation {
            self.widthReservation = widthReservation
            shouldUpdateBounds = true
        }
        if let motionPolicy, self.motionPolicy != motionPolicy {
            self.motionPolicy = motionPolicy
        }
        if shouldUpdateBounds {
            updateBounds()
        }
        updateActiveViews(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    @MainActor
    public func setText(_ text: NSAttributedString, animated: Bool = true) {
        self.text = text.copy() as? NSAttributedString ?? text
        updateBounds()
        updateActiveViews(animated: animated)
    }

    override public func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        position: CGPoint
    ) -> CGRect {
        bounds(for: attributes)
    }

    override public func viewProvider(
        for parentView: NSView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        TextTransitionAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: nil,
            location: location
        )
    }

    override public func image(
        for bounds: CGRect,
        attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSImage? {
        Self.transparentImage
    }

    private func updateBounds() {
        let size = textTransitionPreferredSize(for: text, widthReservation: widthReservation)
        bounds = CGRect(
            x: 0,
            y: baselineOffset(),
            width: size.width,
            height: size.height
        )
    }

    private func bounds(for attributes: [NSAttributedString.Key: Any]) -> CGRect {
        var rect = bounds
        if textTransitionFontDescender(in: text) == nil {
            rect.origin.y = baselineOffset(attributes: attributes)
        }
        return rect
    }

    private func baselineOffset(attributes: [NSAttributedString.Key: Any] = [:]) -> CGFloat {
        let descender = textTransitionFontDescender(in: text) ??
            (attributes[.font] as? NSFont)?.descender ??
            0
        return floor(descender)
    }

    @MainActor
    fileprivate func registerActiveView(_ transitionView: TextTransitionView) {
        activeViews.add(transitionView)
    }

    @MainActor
    private func updateActiveViews(animated: Bool) {
        for transitionView in activeViews.allObjects {
            transitionView.configure(
                text: text,
                contentTransition: contentTransition,
                widthReservation: widthReservation,
                motionPolicy: motionPolicy,
                animated: animated
            )
        }
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
public final class TextTransitionAttachmentViewProvider: NSTextAttachmentViewProvider {
    private var transitionView: TextTransitionView?

    override public init(
        textAttachment: NSTextAttachment,
        parentView: NSView?,
        textLayoutManager: NSTextLayoutManager?,
        location: any NSTextLocation
    ) {
        super.init(
            textAttachment: textAttachment,
            parentView: parentView,
            textLayoutManager: textLayoutManager,
            location: location
        )
        tracksTextAttachmentViewBounds = true
    }

    override public func loadView() {
        nonisolated(unsafe) let provider = self
        let loadedView = MainActor.assumeIsolated {
            provider.configureView(animated: false) ?? NSView(frame: .zero)
        }
        view = loadedView
    }

    public func configureView(animated: Bool = false) -> TextTransitionView? {
        guard let attachment = textAttachment as? TextTransitionAttachment else {
            return nil
        }

        if let transitionView {
            attachment.registerActiveView(transitionView)
            transitionView.configure(
                text: attachment.text,
                contentTransition: attachment.contentTransition,
                widthReservation: attachment.widthReservation,
                motionPolicy: attachment.motionPolicy,
                animated: animated
            )
            return transitionView
        }

        let transitionView = TextTransitionView(
            text: attachment.text,
            contentTransition: attachment.contentTransition,
            widthReservation: attachment.widthReservation,
            motionPolicy: attachment.motionPolicy
        )
        self.transitionView = transitionView
        attachment.registerActiveView(transitionView)
        return transitionView
    }
}
