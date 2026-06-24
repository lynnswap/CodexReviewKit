import Foundation
import Observation

@MainActor
@Observable
public final class ReviewStore {
    public private(set) var orderedJobIDs: [ReviewJob.ID] = []
    public private(set) var jobsByID: [ReviewJob.ID: ReviewJob] = [:]

    public init() {}

    public var jobs: [ReviewJob] {
        orderedJobIDs.compactMap { jobsByID[$0] }
    }

    @discardableResult
    public func upsertJob(id: ReviewJob.ID) -> ReviewJob {
        if let job = jobsByID[id] {
            return job
        }
        let job = ReviewJob(id: id)
        jobsByID[id] = job
        orderedJobIDs.append(id)
        return job
    }

    public func job(id: ReviewJob.ID) -> ReviewJob? {
        jobsByID[id]
    }

    public func apply(_ event: ReviewDomainEvent, to jobID: ReviewJob.ID, at timestamp: Date = Date()) {
        let job = upsertJob(id: jobID)
        job.timeline.apply(event, at: timestamp)
    }
}
