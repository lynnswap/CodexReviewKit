import CodexReviewKit
@_spi(PreviewSupport) @testable import ReviewUI

@MainActor
func reviewMonitorLogText(for job: CodexReviewJob) -> String {
    var projection = ReviewMonitorLog.Projection()
    return projection.render(entries: job.logEntries).text
}
