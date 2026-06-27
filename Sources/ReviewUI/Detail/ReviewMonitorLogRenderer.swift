import CodexReviewKit
import ReviewMonitorRendering

struct ReviewMonitorRenderedLogDocument: Equatable, Sendable {
    var source: ReviewMonitorLog.Document
    var display: ReviewMonitorLog.Document
}

actor ReviewMonitorLogRenderer {
    private var projection = ReviewMonitorLog.Projection()
    private var timelineProjection = ReviewMonitorTimelineLogProjection()
    private var displayDocument = ReviewMonitorLog.Document()

    func reset() {
        projection = ReviewMonitorLog.Projection()
        timelineProjection = ReviewMonitorTimelineLogProjection()
        displayDocument = ReviewMonitorLog.Document()
    }

#if DEBUG
    func render(entries: [ReviewLogEntry]) -> ReviewMonitorRenderedLogDocument {
        renderedDocument(from: projection.render(entries: entries))
    }
#endif

    func render(timelineDocument: ReviewTimelineDocument) -> ReviewMonitorRenderedLogDocument {
        renderedDocument(from: timelineProjection.render(timelineDocument: timelineDocument))
    }

#if DEBUG
    func append(
        entries: [ReviewLogEntry],
        sourceRange: Range<Int>
    ) -> ReviewMonitorRenderedLogDocument? {
        projection.append(entries: entries, sourceRange: sourceRange).map(renderedDocument(from:))
    }

    func appendSteps(
        entries: [ReviewLogEntry],
        sourceRange: Range<Int>
    ) -> [ReviewMonitorRenderedLogDocument]? {
        guard sourceRange.lowerBound <= projection.entryCount else {
            return nil
        }
        guard projection.entryCount < sourceRange.upperBound else {
            guard sourceRange.lowerBound < projection.entryCount else {
                return []
            }
            return [currentRenderedDocument()]
        }

        let skipCount = projection.entryCount - sourceRange.lowerBound
        guard skipCount >= 0,
              skipCount <= entries.count
        else {
            return nil
        }

        var documents: [ReviewMonitorRenderedLogDocument] = []
        if skipCount > 0 {
            documents.append(currentRenderedDocument())
        }
        var entryIndex = sourceRange.lowerBound + skipCount
        for entry in entries.dropFirst(skipCount) {
            guard let document = projection.append(
                entries: [entry],
                sourceRange: entryIndex..<(entryIndex + 1)
            ) else {
                return nil
            }
            documents.append(renderedDocument(from: document))
            entryIndex += 1
        }
        return documents
    }
#endif

    private func currentRenderedDocument() -> ReviewMonitorRenderedLogDocument {
        .init(
            source: projection.currentDocument,
            display: displayDocument
        )
    }

    private func renderedDocument(
        from source: ReviewMonitorLog.Document
    ) -> ReviewMonitorRenderedLogDocument {
        let display = ReviewMonitorCommandOutputDisplayDocument.make(
            from: source,
            previousDisplay: displayDocument
        )
        displayDocument = display
        return .init(
            source: source,
            display: display
        )
    }
}
