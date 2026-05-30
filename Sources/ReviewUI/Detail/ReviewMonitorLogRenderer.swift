import CodexReview

actor ReviewMonitorLogRenderer {
    private var projection = ReviewMonitorLogProjection()

    func reset() {
        projection = ReviewMonitorLogProjection()
    }

    func render(entries: [ReviewLogEntry]) -> ReviewMonitorLogDocument {
        projection.render(entries: entries)
    }

    func append(
        entries: [ReviewLogEntry],
        sourceRange: Range<Int>
    ) -> ReviewMonitorLogDocument? {
        projection.append(entries: entries, sourceRange: sourceRange)
    }
}
