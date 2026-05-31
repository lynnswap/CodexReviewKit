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
        snapshot?.string ?? documentView?.finderString ?? ""
    }

    func stringLength() -> Int {
        snapshot.map { ($0.string as NSString).length } ?? documentView?.finderStringLength ?? 0
    }

    private struct Snapshot {
        var string: String
        // Structural reloads keep the visible find state but invalidate old UTF-16 ranges.
        var mapsToDocument: Bool
    }

    private var snapshot: Snapshot?
    private var selectedFinderRangeOverride: NSRange?

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
        selectedFinderRangeOverride = nil
    }

    func clearSelectedRangeOverride() {
        selectedFinderRangeOverride = nil
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
            if let selectedFinderRangeOverride {
                return [NSValue(range: rangeClampedToActiveString(selectedFinderRangeOverride))]
            }
            let finderRange = documentView.finderRangeForDocumentRange(documentView.selectedRangeForFinding)
            return [NSValue(range: rangeClampedToActiveString(finderRange))]
        }
        set {
            guard snapshot?.mapsToDocument != false else {
                let range = NSRange(location: 0, length: 0)
                selectedFinderRangeOverride = nil
                documentView?.setSelectedRangeFromTextFinder(range)
                onSelectedRangeChangedByFinder?(range)
                return
            }
            guard let rawRange = newValue.first?.rangeValue else {
                let range = NSRange(location: 0, length: 0)
                selectedFinderRangeOverride = nil
                documentView?.setSelectedRangeFromTextFinder(range)
                onSelectedRangeChangedByFinder?(range)
                return
            }
            let range = rangeClampedToActiveString(rawRange)
            let documentRange = documentView?.documentRangeForFinderRange(range) ?? NSRange(location: 0, length: 0)
            documentView?.setSelectedRangeFromTextFinder(documentRange)
            onSelectedRangeChangedByFinder?(documentRange)
            selectedFinderRangeOverride = range
        }
    }

    func scrollRangeToVisible(_ range: NSRange) {
        guard let documentView,
              snapshot?.mapsToDocument != false
        else {
            return
        }
        documentView.scrollFinderRangeToVisible(range)
    }

    var visibleCharacterRanges: [NSValue] {
        guard let documentView else {
            return []
        }
        let ranges = documentView.finderVisibleCharacterRanges().map(\.rangeValue)
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
              snapshot?.mapsToDocument != false
        else {
            return []
        }
        return documentView.rects(forFinderCharacterRange: range)
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
              snapshot?.mapsToDocument != false
        else {
            return
        }
        documentView.drawCharacters(inFinderRange: range, forContentView: view)
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
