struct ReviewMonitorRenderedLogDocument: Equatable, Sendable {
    var source: ReviewMonitorLog.Document
    var display: ReviewMonitorLog.Document
}

actor ReviewMonitorLogRenderer {
    private var displayDocument = ReviewMonitorLog.Document()

    func reset() {
        displayDocument = ReviewMonitorLog.Document()
    }

    func render(sourceDocument: ReviewMonitorLog.Document) -> ReviewMonitorRenderedLogDocument {
        renderedDocument(from: sourceDocument)
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
