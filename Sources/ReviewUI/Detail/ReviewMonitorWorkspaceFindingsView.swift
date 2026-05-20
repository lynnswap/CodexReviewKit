import AppKit
#if DEBUG
import SwiftUI
#endif

@MainActor
final class ReviewMonitorWorkspaceFindingsView: NSView {
    private final class DocumentContainerView: NSView {
        var measuredTextHeight: @MainActor () -> CGFloat = { 0 }

        override var isFlipped: Bool {
            true
        }

        override var intrinsicContentSize: NSSize {
            NSSize(
                width: NSView.noIntrinsicMetric,
                height: measuredTextHeight()
            )
        }
    }

    private final class FindingsTextView: NSTextView {
        var threadCharacterRanges: [NSRange] = []
        var threadBackgroundColor: NSColor = .textBackgroundColor

        override func drawBackground(in rect: NSRect) {
            super.drawBackground(in: rect)
            drawThreadBackgrounds(in: rect)
        }

        private func drawThreadBackgrounds(in dirtyRect: NSRect) {
            guard let layoutManager,
                  let textContainer
            else {
                return
            }

            threadBackgroundColor.setFill()
            for characterRange in threadCharacterRanges {
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: characterRange,
                    actualCharacterRange: nil
                )
                guard glyphRange.length > 0,
                      let backgroundRect = threadBackgroundRect(
                        forGlyphRange: glyphRange,
                        in: textContainer,
                        layoutManager: layoutManager
                      )
                else {
                    continue
                }
                guard dirtyRect.intersects(backgroundRect)
                else {
                    continue
                }

                NSBezierPath(
                    roundedRect: backgroundRect,
                    xRadius: Layout.threadBackgroundCornerRadius,
                    yRadius: Layout.threadBackgroundCornerRadius
                )
                .fill()
            }
        }

        private func threadBackgroundRect(
            forGlyphRange glyphRange: NSRange,
            in textContainer: NSTextContainer,
            layoutManager: NSLayoutManager
        ) -> NSRect? {
            var usedRect = NSRect.null
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, lineUsedRect, container, lineGlyphRange, _ in
                guard container === textContainer,
                      NSIntersectionRange(lineGlyphRange, glyphRange).length > 0
                else {
                    return
                }

                var lineRect = lineUsedRect
                lineRect.origin.x = 0
                lineRect.size.width = textContainer.containerSize.width
                usedRect = usedRect.union(lineRect)
            }

            guard usedRect.isNull == false else {
                return nil
            }

            return NSRect(
                x: textContainerOrigin.x + usedRect.minX - Layout.threadBackgroundPadding,
                y: textContainerOrigin.y + usedRect.minY - Layout.threadBackgroundPadding,
                width: usedRect.width + Layout.threadBackgroundPadding * 2,
                height: usedRect.height + Layout.threadBackgroundPadding * 2
            )
        }
    }

    private enum Layout {
        static let bodyLineSpacing: CGFloat = 2
        static let sectionTitleBackgroundGap: CGFloat = 4
        static let titleBodySpacing: CGFloat = 4
        static let findingSpacing: CGFloat = 12
        static let threadSpacing: CGFloat = 28
        static let threadBackgroundPadding: CGFloat = 8
        static let threadBackgroundCornerRadius: CGFloat = 8
        static let sectionTitleSpacing = threadBackgroundPadding + sectionTitleBackgroundGap
    }

    private struct RenderedText {
        var attributedString: NSAttributedString
        var threadRanges: [NSRange]
    }

    struct Entry {
        var threadID: String
        var targetSummary: String? = nil
        var priority: Int?
        var title: String
        var body: String
        var locationText: String? = nil

        var displayText: String {
            [
                displayTitle,
                body,
                locationText,
            ]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: "\n")
        }

        var sectionTitle: String? {
            let trimmed = targetSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }

        var priorityText: String? {
            guard let priority,
                  (0...3).contains(priority)
            else {
                return nil
            }
            return "P\(priority)"
        }

        var displayTitle: String {
            guard let priorityText else {
                return titleText
            }
            return "[\(priorityText)] \(titleText)"
        }

        var titleText: String {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let priorityText
            else {
                return trimmedTitle
            }

            let priorityPrefix = "[\(priorityText)]"
            guard trimmedTitle.hasPrefix(priorityPrefix) else {
                return trimmedTitle
            }

            return trimmedTitle
                .dropFirst(priorityPrefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private let scrollView = NSScrollView()
    private let documentContainerView = DocumentContainerView()
    private let textView: FindingsTextView
    private let storage: NSTextStorage
    private let layoutManager: NSLayoutManager
    private let textContainer: NSTextContainer
    private var displayedText = ""
    private var displayedThreadSignature = ""

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        layoutManager.allowsNonContiguousLayout = true

        let textView = FindingsTextView(frame: .zero, textContainer: textContainer)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.translatesAutoresizingMaskIntoConstraints = false

        self.storage = storage
        self.layoutManager = layoutManager
        self.textContainer = textContainer
        self.textView = textView
        super.init(frame: frameRect)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    @discardableResult
    func render(entries: [Entry]) -> Bool {
        let nextText = displayText(for: entries)
        let nextThreadSignature = entries.map { entry in
            "\(entry.threadID)\u{1F}\(entry.sectionTitle ?? "")\u{1F}\(entry.displayText)"
        }
        .joined(separator: "\u{1E}")
        guard displayedText != nextText || displayedThreadSignature != nextThreadSignature else {
            updateVisibility(hasFindings: entries.isEmpty == false)
            return false
        }

        displayedText = nextText
        displayedThreadSignature = nextThreadSignature
        replaceText(with: makeRenderedText(entries: entries))
        textView.setAccessibilityValue(nextText)
        updateVisibility(hasFindings: entries.isEmpty == false)
        return true
    }

    private func displayText(for entries: [Entry]) -> String {
        var components: [String] = []
        var currentThreadID: String?
        for entry in entries {
            if currentThreadID != entry.threadID {
                if let sectionTitle = entry.sectionTitle {
                    components.append(sectionTitle)
                }
                currentThreadID = entry.threadID
            }
            components.append(entry.displayText)
        }
        return components.joined(separator: "\n\n")
    }

    @discardableResult
    func clear() -> Bool {
        let changed = displayedText.isEmpty == false
            || scrollView.isHidden == false
        displayedText = ""
        displayedThreadSignature = ""
        replaceText(with: RenderedText(attributedString: NSAttributedString(), threadRanges: []))
        textView.setAccessibilityValue("")
        scrollView.isHidden = true
        return changed
    }

    override func layout() {
        super.layout()
        invalidateDocumentLayout()
    }

    private func configureHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = true

        textView.textContainerInset = NSSize(width: 28, height: 24)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.enabledTextCheckingTypes = 0
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.usesRuler = false
        textView.usesInspectorBar = false
        textView.drawsBackground = true
        textView.backgroundColor = .clear
        textView.textColor = .textColor
        textView.setAccessibilityIdentifier("review-monitor.workspace-findings-text")
        textView.setAccessibilityLabel("Workspace findings")

        documentContainerView.measuredTextHeight = { [weak self] in
            self?.measuredTextHeight() ?? 0
        }
        documentContainerView.addSubview(textView)
        scrollView.documentView = documentContainerView

        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        clear()
    }

    private func replaceText(with renderedText: RenderedText) {
        storage.beginEditing()
        storage.replaceCharacters(
            in: NSRange(location: 0, length: storage.length),
            with: renderedText.attributedString
        )
        storage.endEditing()
        textView.threadCharacterRanges = renderedText.threadRanges
        textView.threadBackgroundColor = threadBackgroundColor
        textView.needsDisplay = true
        invalidateDocumentLayout()
        layoutSubtreeIfNeeded()
        scrollToTopRespectingContentInsets()
    }

    private func updateVisibility(hasFindings: Bool) {
        scrollView.isHidden = hasFindings == false
    }

    private func invalidateDocumentLayout() {
        syncDocumentFrameToTextLayout()
        documentContainerView.invalidateIntrinsicContentSize()
    }

    @discardableResult
    private func syncTextContainerWidthToTextView() -> Bool {
        let targetWidth = max(0, effectiveScrollContentSize.width - textView.textContainerInset.width * 2)
        let targetSize = NSSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)
        guard abs(textContainer.containerSize.width - targetSize.width) > 0.5 ||
              textContainer.containerSize.height != targetSize.height
        else {
            return false
        }

        textContainer.containerSize = targetSize
        if storage.length > 0 {
            let fullRange = NSRange(location: 0, length: storage.length)
            layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: fullRange)
        }
        documentContainerView.invalidateIntrinsicContentSize()
        return true
    }

    private func measuredTextHeight() -> CGFloat {
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        return ceil(usedRect.height + textView.textContainerInset.height * 2)
    }

    private var effectiveScrollContentSize: NSSize {
        let contentSize = scrollView.contentSize
        let contentInsets = scrollView.contentView.contentInsets
        return NSSize(
            width: max(0, contentSize.width - max(0, contentInsets.left) - max(0, contentInsets.right)),
            height: max(0, contentSize.height - max(0, contentInsets.bottom))
        )
    }

    private func syncDocumentFrameToTextLayout() {
        let contentSize = effectiveScrollContentSize
        syncTextContainerWidthToTextView()
        let targetFrame = NSRect(
            x: 0,
            y: 0,
            width: contentSize.width,
            height: measuredTextHeight()
        )
        if rectsAreNearlyEqual(documentContainerView.frame, targetFrame) == false {
            documentContainerView.frame = targetFrame
        }
        if rectsAreNearlyEqual(textView.frame, documentContainerView.bounds) == false {
            textView.frame = documentContainerView.bounds
        }
    }

    private func rectsAreNearlyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 0.5 &&
            abs(lhs.minY - rhs.minY) <= 0.5 &&
            abs(lhs.width - rhs.width) <= 0.5 &&
            abs(lhs.height - rhs.height) <= 0.5
    }

    private func scrollToTopRespectingContentInsets() {
        let topOrigin = NSPoint(
            x: 0,
            y: -max(0, scrollView.contentView.contentInsets.top)
        )
        scrollView.contentView.scroll(to: topOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func minimumVerticalScrollOffset() -> CGFloat {
        -max(0, scrollView.contentView.contentInsets.top)
    }

    private func maximumVerticalScrollOffset() -> CGFloat {
        let minY = minimumVerticalScrollOffset()
        let bottomInset = max(0, scrollView.contentView.contentInsets.bottom)
        let maxY = documentContainerView.frame.height - scrollView.contentView.bounds.height + bottomInset
        return max(minY, maxY)
    }

    private func makeRenderedText(entries: [Entry]) -> RenderedText {
        let result = NSMutableAttributedString()
        var threadRanges: [NSRange] = []
        var currentThreadID: String?
        var currentThreadLocation: Int?

        func closeCurrentThreadRange() {
            guard let location = currentThreadLocation else {
                return
            }
            let length = result.length - location
            if length > 0 {
                threadRanges.append(NSRange(location: location, length: length))
            }
        }

        for index in entries.indices {
            let entry = entries[index]
            if currentThreadID == nil {
                appendSectionTitle(for: entry, to: result)
                currentThreadID = entry.threadID
                currentThreadLocation = result.length
            } else if currentThreadID == entry.threadID {
                appendParagraphSeparator(
                    to: result,
                    bodyParagraphSpacingAfter: spacingAfterEntry(at: index - 1, in: entries)
                )
            } else {
                closeCurrentThreadRange()
                appendParagraphSeparator(
                    to: result,
                    bodyParagraphSpacingAfter: spacingAfterEntry(at: index - 1, in: entries)
                )
                appendSectionTitle(for: entry, to: result)
                currentThreadID = entry.threadID
                currentThreadLocation = result.length
            }
            appendEntry(
                entry,
                to: result,
                bodyParagraphSpacingAfter: spacingAfterEntry(at: index, in: entries)
            )
        }
        closeCurrentThreadRange()
        return RenderedText(attributedString: result, threadRanges: threadRanges)
    }

    private func spacingAfterEntry(at index: Int, in entries: [Entry]) -> CGFloat {
        let nextIndex = index + 1
        guard entries.indices.contains(nextIndex) else {
            return 0
        }
        return entries[nextIndex].threadID == entries[index].threadID
            ? Layout.findingSpacing
            : Layout.threadSpacing
    }

    private func appendSectionTitle(
        for entry: Entry,
        to result: NSMutableAttributedString
    ) {
        guard let sectionTitle = entry.sectionTitle else {
            return
        }
        appendTrimmed(sectionTitle, to: result, attributes: sectionTitleAttributes)
        appendSectionTitleSeparator(to: result)
    }

    private func appendEntry(
        _ entry: Entry,
        to result: NSMutableAttributedString,
        bodyParagraphSpacingAfter: CGFloat
    ) {
        if let priorityText = entry.priorityText {
            result.append(NSAttributedString(
                string: "[\(priorityText)]",
                attributes: priorityTextAttributes(for: priorityText)
            ))
            result.append(NSAttributedString(string: " ", attributes: titleAttributes))
        }
        appendTrimmed(entry.titleText, to: result, attributes: titleAttributes)
        appendNewline(to: result)
        if let locationText = entry.locationText?.trimmingCharacters(in: .whitespacesAndNewlines),
           locationText.isEmpty == false {
            appendTrimmed(
                entry.body,
                to: result,
                attributes: bodyAttributes(paragraphSpacingAfter: Layout.titleBodySpacing)
            )
            appendMetadataSeparator(to: result)
            appendTrimmed(
                locationText,
                to: result,
                attributes: metadataAttributes(paragraphSpacingAfter: bodyParagraphSpacingAfter)
            )
        } else {
            appendTrimmed(
                entry.body,
                to: result,
                attributes: bodyAttributes(paragraphSpacingAfter: bodyParagraphSpacingAfter)
            )
        }
    }

    private func appendTrimmed(
        _ string: String,
        to result: NSMutableAttributedString,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return
        }
        result.append(NSAttributedString(string: trimmed, attributes: attributes))
    }

    private func appendNewline(to result: NSMutableAttributedString) {
        guard result.string.hasSuffix("\n") == false else {
            return
        }
        result.append(NSAttributedString(string: "\n", attributes: titleAttributes))
    }

    private func appendParagraphSeparator(
        to result: NSMutableAttributedString,
        bodyParagraphSpacingAfter: CGFloat
    ) {
        result.append(NSAttributedString(
            string: "\n",
            attributes: bodyAttributes(paragraphSpacingAfter: bodyParagraphSpacingAfter)
        ))
    }

    private func appendMetadataSeparator(to result: NSMutableAttributedString) {
        result.append(NSAttributedString(
            string: "\n",
            attributes: bodyAttributes(paragraphSpacingAfter: Layout.titleBodySpacing)
        ))
    }

    private func appendSectionTitleSeparator(to result: NSMutableAttributedString) {
        result.append(NSAttributedString(string: "\n", attributes: sectionTitleAttributes))
    }

    private var sectionTitleAttributes: [NSAttributedString.Key: Any] {
        [
            .font: sectionTitleFont,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle(paragraphSpacingAfter: Layout.sectionTitleSpacing),
        ]
    }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [
            .font: titleFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle(paragraphSpacingAfter: Layout.titleBodySpacing),
        ]
    }

    private func priorityTextAttributes(for text: String) -> [NSAttributedString.Key: Any] {
        var attributes = titleAttributes
        attributes[.foregroundColor] = priorityTextColor(for: text)
        return attributes
    }

    private func priorityTextColor(for text: String) -> NSColor {
        let color: NSColor
        switch text {
        case "P0":
            color = .systemRed
        case "P1":
            color = .systemOrange
        case "P2":
            color = .systemYellow
        case "P3":
            return .systemGray
        default:
            return .systemGray
        }
        return tonedPriorityTextColor(color)
    }

    private func tonedPriorityTextColor(_ color: NSColor) -> NSColor {
        let workspace = NSWorkspace.shared
        guard workspace.accessibilityDisplayShouldIncreaseContrast == false,
              workspace.accessibilityDisplayShouldReduceTransparency == false
        else {
            return color
        }
        return color.withAlphaComponent(0.8)
    }

    private var threadBackgroundColor: NSColor {
        let workspace = NSWorkspace.shared
        if workspace.accessibilityDisplayShouldIncreaseContrast ||
            workspace.accessibilityDisplayShouldReduceTransparency {
            return .unemphasizedSelectedContentBackgroundColor
        }
        return NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.18)
    }

    private var titleFont: NSFont {
        NSFont.preferredFont(forTextStyle: .headline)
    }

    private var sectionTitleFont: NSFont {
        NSFont.preferredFont(forTextStyle: .subheadline)
    }

    private var bodyFont: NSFont {
        NSFont.preferredFont(forTextStyle: .subheadline)
    }

    private var metadataFont: NSFont {
        NSFont.preferredFont(forTextStyle: .caption1)
    }

    private func bodyAttributes(
        paragraphSpacingAfter: CGFloat = 0
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: bodyTextColor,
            .paragraphStyle: paragraphStyle(
                lineSpacing: Layout.bodyLineSpacing,
                paragraphSpacingAfter: paragraphSpacingAfter
            ),
        ]
    }

    private var bodyTextColor: NSColor {
        let workspace = NSWorkspace.shared
        if workspace.accessibilityDisplayShouldIncreaseContrast ||
            workspace.accessibilityDisplayShouldReduceTransparency {
            return .labelColor
        }
        return NSColor.labelColor.withAlphaComponent(0.8)
    }

    private func metadataAttributes(
        paragraphSpacingAfter: CGFloat
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: metadataFont,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle(paragraphSpacingAfter: paragraphSpacingAfter),
        ]
    }

    private func paragraphStyle(
        lineSpacing: CGFloat = 0,
        paragraphSpacingAfter: CGFloat = 0
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = paragraphSpacingAfter
        return style
    }

    @discardableResult
    func performDisplayedTextFinderAction(_ sender: Any?) -> Bool {
        guard scrollView.isHidden == false else {
            return false
        }
        textView.performTextFinderAction(sender)
        return true
    }

    func validateDisplayedTextFinderAction(_ item: NSValidatedUserInterfaceItem) -> Bool {
        scrollView.isHidden == false && textView.validateUserInterfaceItem(item)
    }
}

#if DEBUG
@MainActor
extension ReviewMonitorWorkspaceFindingsView {
    var displayedTextForTesting: String {
        displayedText
    }

    var accessibilityValueForTesting: String? {
        textView.accessibilityValue()
    }

    var renderedStorageStringForTesting: String {
        storage.string
    }

    var isShowingFindingsListForTesting: Bool {
        scrollView.isHidden == false
    }

    var contentWidthForTesting: CGFloat {
        layoutSubtreeIfNeeded()
        return scrollView.contentView.bounds.width
    }

    var scrollFrameForTesting: NSRect {
        scrollView.frame
    }

    var contentInsetsForTesting: NSEdgeInsets {
        scrollView.contentView.contentInsets
    }

    var verticalScrollOffsetForTesting: CGFloat {
        scrollView.contentView.bounds.origin.y
    }

    var minimumVerticalScrollOffsetForTesting: CGFloat {
        minimumVerticalScrollOffset()
    }

    var maximumVerticalScrollOffsetForTesting: CGFloat {
        maximumVerticalScrollOffset()
    }

    var documentFrameForTesting: NSRect {
        documentContainerView.frame
    }

    var automaticallyAdjustsContentInsetsForTesting: Bool {
        scrollView.automaticallyAdjustsContentInsets
    }

    var textContainerWidthForTesting: CGFloat {
        layoutSubtreeIfNeeded()
        syncTextContainerWidthToTextView()
        return textContainer.containerSize.width
    }

    var isTextSelectableForTesting: Bool {
        textView.isSelectable
    }

    var isTextEditableForTesting: Bool {
        textView.isEditable
    }

    var usesFindBarForTesting: Bool {
        textView.usesFindBar
    }

    var isIncrementalSearchingEnabledForTesting: Bool {
        textView.isIncrementalSearchingEnabled
    }

    var isFindBarVisibleForTesting: Bool {
        scrollView.isFindBarVisible
    }

    var priorityPrefixCountForTesting: Int {
        (0...3).reduce(0) { count, priority in
            count + displayedText.components(separatedBy: "[P\(priority)]").count - 1
        }
    }

    var textAttachmentCountForTesting: Int {
        var count = 0
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            if value is NSTextAttachment {
                count += 1
            }
        }
        return count
    }

    var threadBackgroundRangeCountForTesting: Int {
        textView.threadCharacterRanges.count
    }
}
#endif

#if DEBUG
#Preview("Workspace Findings") {
    ReviewMonitorWorkspaceFindingsPreviewHost(entries: makeWorkspaceFindingsPreviewEntries())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
}

#Preview("No Findings") {
    ReviewMonitorWorkspaceFindingsPreviewHost(entries: [])
        .frame(maxWidth: .infinity, maxHeight: .infinity)
}

@MainActor
private struct ReviewMonitorWorkspaceFindingsPreviewHost: NSViewRepresentable {
    let entries: [ReviewMonitorWorkspaceFindingsView.Entry]

    func makeNSView(context: Context) -> ReviewMonitorWorkspaceFindingsView {
        let view = ReviewMonitorWorkspaceFindingsView(frame: .zero)
        view.render(entries: entries)
        return view
    }

    func updateNSView(
        _ nsView: ReviewMonitorWorkspaceFindingsView,
        context: Context
    ) {
        nsView.render(entries: entries)
    }
}

@MainActor
private func makeWorkspaceFindingsPreviewEntries() -> [ReviewMonitorWorkspaceFindingsView.Entry] {
    [
        .init(
            threadID: "thread-undo",
            targetSummary: "Uncommitted changes",
            priority: 0,
            title: "[P0] Stop stale undo commands from escaping cleared history",
            body: "Cancel every queued undo operation before clearing history so stale DOM.undo and DOM.redo commands cannot run after detach.",
            locationText: "Sources/WebInspectorRuntime/InspectorSession.swift:1192-1192"
        ),
        .init(
            threadID: "thread-undo",
            targetSummary: "Uncommitted changes",
            priority: 1,
            title: "[P1] Cancel the queued operation chain, not only the tail",
            body: "When multiple undo operations are waiting on each other, clearing the latest task is not enough. Track and cancel every queued operation owned by the thread."
        ),
        .init(
            threadID: "thread-selection",
            targetSummary: "Branch: feature/workspace-alpha-sidebar",
            priority: 1,
            title: "[P1] Preserve the selected workspace across reload",
            body: "The sidebar reload currently drops the workspace selection before the detail view can refresh. Resolve the selected workspace by cwd before clearing selection.",
            locationText: "Sources/ReviewUI/Sidebar/Jobs/ReviewMonitorSidebarViewController.swift:184-203"
        ),
        .init(
            threadID: "thread-selection",
            targetSummary: "Branch: feature/workspace-alpha-sidebar",
            priority: 2,
            title: "[P2] Refresh workspace findings after job result changes",
            body: "The workspace detail should observe each displayed job's structured review result and redraw only when the aggregated finding text changes."
        ),
        .init(
            threadID: "thread-contract",
            targetSummary: "Base branch: main",
            priority: 2,
            title: "[P2] Keep workspace findings scoped to structured results",
            body: "The detail pane should keep using ParsedReviewResult.findings only. Re-parsing log text here would reintroduce mismatches with the MCP result contract.",
            locationText: "Sources/ReviewUI/Detail/ReviewMonitorTransportViewController.swift:223-246"
        ),
        .init(
            threadID: "thread-contract",
            targetSummary: "Base branch: main",
            priority: 0,
            title: "[P0] Do not parse transport logs for review findings",
            body: "The UI must not recover findings by scanning log text. The structured ParsedReviewResult.findings payload is the source of truth for this pane."
        ),
        .init(
            threadID: "thread-polish",
            targetSummary: "Commit: abc1234",
            priority: 3,
            title: "[P3] Avoid clipping long paths in metadata",
            body: "Long file paths need middle truncation so row titles and descriptions remain readable in narrow detail panes."
        ),
        .init(
            threadID: "thread-polish",
            targetSummary: "Commit: abc1234",
            priority: 3,
            title: "[P3] Preserve no-findings empty state alignment",
            body: "A workspace with only unknown or clean review results should continue to show the centered empty state instead of reserving space for an empty text document."
        ),
    ]
}
#endif
