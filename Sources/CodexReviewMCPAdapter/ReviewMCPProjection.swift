import Foundation
import CodexReviewDomain

public struct ReviewMCPProjection: Sendable, Equatable {
    public var timelineRevision: ReviewTimeline.Revision
    public var activeItemCount: Int
    public var latestActivityID: ReviewTimelineItem.ID?

    @MainActor
    public init(timeline: ReviewTimeline) {
        self.timelineRevision = timeline.revision
        self.activeItemCount = timeline.activeItemIDs.count
        self.latestActivityID = timeline.latestActivity
    }
}
