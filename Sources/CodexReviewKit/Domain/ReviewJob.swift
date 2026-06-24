import Foundation
import Observation

@MainActor
@Observable
public final class ReviewJob: Identifiable, Hashable {
    public typealias ID = ReviewJobID

    public nonisolated let id: ID
    public private(set) var run: ReviewRun?
    public let timeline: ReviewTimeline

    public init(
        id: ID,
        run: ReviewRun? = nil,
        timeline: ReviewTimeline = ReviewTimeline()
    ) {
        self.id = id
        self.run = run
        self.timeline = timeline
    }

    public func updateRun(_ run: ReviewRun?) {
        self.run = run
    }

    public nonisolated static func == (lhs: ReviewJob, rhs: ReviewJob) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
