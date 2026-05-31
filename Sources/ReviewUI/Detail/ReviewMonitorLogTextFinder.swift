import AppKit

@MainActor
final class ReviewMonitorLogTextFinderBarContainer: NSObject, @preconcurrency NSTextFinderBarContainer {
    weak var scrollView: NSScrollView?
    weak var finderContentView: NSView?
    var onFindBarVisibilityChanged: ((Bool) -> Void)?

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
            onFindBarVisibilityChanged?(newValue)
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
final class ReviewMonitorLogTextFinderClient: NSObject, @preconcurrency NSTextFinderClient {
    weak var documentView: ReviewMonitorLogDocumentView?
    var onSelectedRangeChangedByFinder: ((NSRange) -> Void)?

    var string: String {
        snapshot?.string ?? documentView?.string ?? ""
    }

    func stringLength() -> Int {
        snapshot.map { ($0.string as NSString).length } ?? documentView?.stringLength ?? 0
    }

    private struct Snapshot {
        var string: String
        // Structural reloads keep the visible find state but invalidate old UTF-16 ranges.
        var mapsToDocument: Bool
    }

    private var snapshot: Snapshot?

    var usesSnapshot: Bool {
        snapshot != nil
    }

    var usesSnapshotForTesting: Bool {
        usesSnapshot
    }

    var snapshotMapsToDocument: Bool {
        snapshot?.mapsToDocument ?? true
    }

    var snapshotMapsToDocumentForTesting: Bool {
        snapshotMapsToDocument
    }

    func captureSnapshotIfNeeded(mapsToDocument: Bool, string: () -> String) {
        if snapshot == nil {
            snapshot = Snapshot(string: string(), mapsToDocument: mapsToDocument)
        }
    }

    func invalidateSnapshotDocumentMapping() {
        snapshot?.mapsToDocument = false
    }

    func clearSnapshot() {
        snapshot = nil
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
            guard snapshot?.mapsToDocument != false else {
                return [NSValue(range: NSRange(location: 0, length: 0))]
            }
            return [NSValue(range: rangeClampedToActiveString(documentView.selectedRangeForFinding))]
        }
        set {
            guard snapshot?.mapsToDocument != false else {
                let range = NSRange(location: 0, length: 0)
                documentView?.setSelectedRangeFromTextFinder(range)
                onSelectedRangeChangedByFinder?(range)
                return
            }
            guard let rawRange = newValue.first?.rangeValue else {
                let range = NSRange(location: 0, length: 0)
                documentView?.setSelectedRangeFromTextFinder(range)
                onSelectedRangeChangedByFinder?(range)
                return
            }
            let range = rangeClampedToActiveString(rawRange)
            documentView?.setSelectedRangeFromTextFinder(range)
            onSelectedRangeChangedByFinder?(range)
        }
    }

    func scrollRangeToVisible(_ range: NSRange) {
        guard let documentView,
              snapshot?.mapsToDocument != false,
              let range = rangeClampedToCurrentDocument(range, documentView: documentView)
        else {
            return
        }
        documentView.scrollRangeToVisible(range)
    }

    var visibleCharacterRanges: [NSValue] {
        guard let documentView else {
            return []
        }
        let ranges = documentView.visibleCharacterRanges().map(\.rangeValue)
        guard let snapshot else {
            return ranges.map(NSValue.init(range:))
        }
        let snapshotRange = NSRange(location: 0, length: (snapshot.string as NSString).length)
        guard snapshot.mapsToDocument else {
            return []
        }
        let clampedRanges = ranges
            .map { NSIntersectionRange($0, snapshotRange) }
            .filter { $0.length > 0 }
        return clampedRanges.map(NSValue.init(range:))
    }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        guard let documentView,
              snapshot?.mapsToDocument != false,
              let range = rangeClampedToCurrentDocument(range, documentView: documentView)
        else {
            return []
        }
        return documentView.rects(forCharacterRange: range)
    }

    func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
        guard let documentView else {
            outRange.pointee = NSRange(location: 0, length: 0)
            return NSView()
        }
        outRange.pointee = NSRange(location: 0, length: stringLength())
        return documentView.finderContentView
    }

    func drawCharacters(in range: NSRange, forContentView view: NSView) {
        guard let documentView,
              snapshot?.mapsToDocument != false,
              let range = rangeClampedToCurrentDocument(range, documentView: documentView)
        else {
            return
        }
        documentView.drawCharacters(in: range, forContentView: view)
    }

    private func rangeClampedToCurrentDocument(
        _ range: NSRange,
        documentView: ReviewMonitorLogDocumentView
    ) -> NSRange? {
        let clampedRange = NSIntersectionRange(
            range,
            NSRange(location: 0, length: documentView.stringLength)
        )
        guard clampedRange.length > 0 else {
            return nil
        }
        return clampedRange
    }

    private func rangeClampedToActiveString(_ range: NSRange) -> NSRange {
        guard let snapshotRange else {
            return range
        }
        let intersection = NSIntersectionRange(range, snapshotRange)
        if intersection.location == range.location,
           intersection.length == range.length {
            return range
        }
        return NSRange(
            location: min(max(0, range.location), snapshotRange.length),
            length: 0
        )
    }

    private var snapshotRange: NSRange? {
        snapshot.map { NSRange(location: 0, length: ($0.string as NSString).length) }
    }
}

