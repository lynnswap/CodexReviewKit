import Foundation
import CodexReview

package enum MCPToolName: String, Codable, Equatable, Sendable, CaseIterable {
    case reviewStart = "review_start"
    case reviewRead = "review_read"
    case reviewList = "review_list"
    case reviewCancel = "review_cancel"
}

package struct MCPToolDescriptor: Codable, Equatable, Sendable {
    package var name: MCPToolName
    package var description: String

    package init(name: MCPToolName, description: String) {
        self.name = name
        self.description = description
    }
}

package enum MCPToolRequest: Equatable, Sendable {
    case reviewStart(sessionID: String, request: ReviewStartRequest)
    case reviewRead(sessionID: String?, jobID: String, logFilter: ReviewLogFilter, logPage: ReviewLogPageRequest)
    case reviewList(sessionID: String?, cwd: String?, statuses: [ReviewJobState]?, limit: Int?)
    case reviewCancel(sessionID: String?, selector: ReviewJobSelector, reason: ReviewCancellation)
}

package enum MCPToolResponse: Equatable, Sendable {
    case reviewRead(ReviewReadResult)
    case reviewList(ReviewListResult)
    case reviewCancel(ReviewCancelOutcome)
}

@MainActor
package final class CodexReviewMCPServer {
    private let store: CodexReviewStore

    package init(store: CodexReviewStore) {
        self.store = store
    }

    package var tools: [MCPToolDescriptor] {
        [
            .init(name: .reviewStart, description: "Start a Codex review."),
            .init(name: .reviewRead, description: "Read a Codex review job."),
            .init(name: .reviewList, description: "List Codex review jobs."),
            .init(name: .reviewCancel, description: "Cancel a Codex review job."),
        ]
    }

    package func handle(_ request: MCPToolRequest) async throws -> MCPToolResponse {
        switch request {
        case .reviewStart(let sessionID, let reviewRequest):
            return .reviewRead(try await store.startReview(
                sessionID: sessionID,
                request: reviewRequest
            ))
        case .reviewRead(let sessionID, let jobID, let logFilter, let logPage):
            return .reviewRead(try store.readReview(
                sessionID: sessionID,
                jobID: jobID,
                logFilter: logFilter,
                logPage: logPage
            ))
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

    package func closeSession(_ sessionID: String) async {
        await store.closeSession(sessionID)
    }

    package func hasActiveReviews(in sessionID: String) -> Bool {
        store.activeJobIDs(for: sessionID).isEmpty == false
    }
}

private extension ReviewJobSelector {
    func defaultingToActiveStatusesForCancellation() -> ReviewJobSelector {
        guard jobID == nil, statuses == nil else {
            return self
        }
        return .init(jobID: jobID, cwd: cwd, statuses: [.queued, .running])
    }
}
