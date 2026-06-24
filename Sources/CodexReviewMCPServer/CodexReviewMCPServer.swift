import Foundation
import CodexReviewKit

package enum CodexReviewMCP {
    package enum Tool {}
}

package extension CodexReviewMCP.Tool {
    enum Name: String, Codable, Equatable, Sendable, CaseIterable {
        case reviewStart = "review_start"
        case reviewAwait = "review_await"
        case reviewRead = "review_read"
        case reviewList = "review_list"
        case reviewCancel = "review_cancel"
    }
}

package extension CodexReviewMCP.Tool {
    struct Descriptor: Codable, Equatable, Sendable {
        package var name: CodexReviewMCP.Tool.Name
        package var description: String

        package init(name: CodexReviewMCP.Tool.Name, description: String) {
            self.name = name
            self.description = description
        }
    }
}

package extension CodexReviewMCP.Tool {
    enum Request: Equatable, Sendable {
        case reviewStart(sessionID: String, request: CodexReviewAPI.Start.Request, waitTimeout: Duration?)
        case reviewAwait(sessionID: String?, jobID: String, waitTimeout: Duration)
        case reviewRead(sessionID: String?, jobID: String, logFilter: CodexReviewAPI.Log.Filter, logPage: CodexReviewAPI.Log.PageRequest)
        case reviewList(sessionID: String?, cwd: String?, statuses: [ReviewJobState]?, limit: Int?)
        case reviewCancel(sessionID: String?, selector: CodexReviewAPI.Job.Selector, reason: ReviewCancellation)
    }
}

package extension CodexReviewMCP.Tool {
    internal struct ReviewSnapshot: Equatable, Sendable {
        var result: CodexReviewAPI.Read.Result
        var timeline: ReviewMCPProjection

        init(result: CodexReviewAPI.Read.Result, timeline: ReviewMCPProjection) {
            self.result = result
            self.timeline = timeline
        }
    }
}

package extension CodexReviewMCP.Tool {
    internal enum Response: Equatable, Sendable {
        case reviewStart(ReviewSnapshot)
        case reviewAwait(ReviewSnapshot)
        case reviewRead(ReviewSnapshot, timelinePage: CodexReviewAPI.Log.PageRequest)
        case reviewList(CodexReviewAPI.List.Result)
        case reviewCancel(CodexReviewAPI.Cancel.Outcome)
    }
}

@MainActor
package final class CodexReviewMCPServer {
    private let store: CodexReviewStore

    package init(store: CodexReviewStore) {
        self.store = store
    }

    package var tools: [CodexReviewMCP.Tool.Descriptor] {
        [
            .init(name: .reviewStart, description: "Start a Codex review."),
            .init(name: .reviewAwait, description: "Wait for a running Codex review job."),
            .init(name: .reviewRead, description: "Read a Codex review job."),
            .init(name: .reviewList, description: "List Codex review jobs."),
            .init(name: .reviewCancel, description: "Cancel a Codex review job."),
        ]
    }

    func handle(_ request: CodexReviewMCP.Tool.Request) async throws -> CodexReviewMCP.Tool.Response {
        switch request {
        case .reviewStart(let sessionID, let reviewRequest, let waitTimeout):
            let result: CodexReviewAPI.Read.Result
            if let waitTimeout {
                result = try await store.startReview(
                    sessionID: sessionID,
                    request: reviewRequest,
                    waitTimeout: waitTimeout
                )
            } else {
                result = try await store.startReview(sessionID: sessionID, request: reviewRequest)
            }
            let snapshot = try reviewSnapshot(
                result,
                sessionID: sessionID
            )
            return .reviewStart(snapshot)
        case .reviewAwait(let sessionID, let jobID, let waitTimeout):
            let snapshot = try reviewSnapshot(
                try await store.awaitReview(
                    sessionID: sessionID,
                    jobID: jobID,
                    timeout: waitTimeout
                ),
                sessionID: sessionID
            )
            return .reviewAwait(snapshot)
        case .reviewRead(let sessionID, let jobID, let logFilter, let logPage):
            let snapshot = try reviewSnapshot(
                try store.readReview(
                    sessionID: sessionID,
                    jobID: jobID,
                    logFilter: logFilter,
                    logPage: logPage
                ),
                sessionID: sessionID
            )
            return .reviewRead(snapshot, timelinePage: logPage)
        case .reviewList(let sessionID, let cwd, let statuses, let limit):
            return .reviewList(store.listReviews(
                sessionID: sessionID,
                cwd: cwd,
                statuses: statuses,
                limit: limit
            ))
        case .reviewCancel(let sessionID, let selector, let reason):
            let job = try store.resolveJob(
                sessionID: sessionID,
                selector: selector.defaultingToActiveStatusesForCancellation()
            )
            return .reviewCancel(try await store.cancelReview(
                jobID: job.id,
                cancellation: reason
            ))
        }
    }

    private func reviewSnapshot(
        _ result: CodexReviewAPI.Read.Result,
        sessionID: String?
    ) throws -> CodexReviewMCP.Tool.ReviewSnapshot {
        let job = try store.resolveJob(
            sessionID: sessionID,
            selector: .init(jobID: result.jobID)
        )
        return .init(result: result, timeline: ReviewMCPProjection(timeline: job.timeline))
    }

    package func closeSession(_ sessionID: String) async {
        await store.closeSession(sessionID)
    }

    package func hasActiveReviews(in sessionID: String) -> Bool {
        store.activeJobIDs(for: sessionID).isEmpty == false
    }
}

private extension CodexReviewAPI.Job.Selector {
    func defaultingToActiveStatusesForCancellation() -> CodexReviewAPI.Job.Selector {
        guard jobID == nil, statuses == nil else {
            return self
        }
        return .init(jobID: jobID, cwd: cwd, statuses: [.queued, .running])
    }
}
