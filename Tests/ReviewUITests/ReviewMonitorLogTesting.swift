import CodexReview
@_spi(PreviewSupport) @testable import ReviewUI

@MainActor
func reviewMonitorLogText(for job: CodexReviewJob) -> String {
    var projection = ReviewMonitorLogProjection()
    return projection.render(entries: job.logEntries).text
}
