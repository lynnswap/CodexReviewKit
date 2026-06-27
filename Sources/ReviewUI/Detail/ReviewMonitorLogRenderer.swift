import ReviewMonitorRendering

struct ReviewMonitorRenderedLogDocument: Equatable, Sendable {
    var source: ReviewMonitorLog.Document
    var display: ReviewMonitorLog.Document
}

actor ReviewMonitorLogRenderer {
    private var timelineProjection = ReviewMonitorTimelineLogProjection()
    private var displayDocument = ReviewMonitorLog.Document()

    func reset() {
        timelineProjection = ReviewMonitorTimelineLogProjection()
        displayDocument = ReviewMonitorLog.Document()
    }

    func render(timelineDocument: ReviewTimelineDocument) -> ReviewMonitorRenderedLogDocument {
        renderedDocument(from: timelineProjection.render(timelineDocument: timelineDocument))
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
