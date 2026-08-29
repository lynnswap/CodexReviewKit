import Foundation

package enum ReviewHistoryAvailability: Sendable, Equatable {
    case loading
    case available
    case failed(String)
    case closed
}

package struct ReviewHistoryRetentionPolicy: Sendable, Equatable {
    package var maximumReviewsPerWorkspace: Int
    package var maximumReviews: Int

    package init(
        maximumReviewsPerWorkspace: Int,
        maximumReviews: Int
    ) {
        precondition(maximumReviewsPerWorkspace > 0)
        precondition(maximumReviews > 0)
        self.maximumReviewsPerWorkspace = maximumReviewsPerWorkspace
        self.maximumReviews = maximumReviews
    }

    package static let `default` = ReviewHistoryRetentionPolicy(
        maximumReviewsPerWorkspace: 50,
        maximumReviews: 500
    )
}

package struct ReviewHistoryMutationResult: Sendable, Equatable {
    package var removedReviewIDs: Set<String>

    package init(removedReviewIDs: Set<String> = []) {
        self.removedReviewIDs = removedReviewIDs
    }
}

package struct ReviewHistoryOrdering: Sendable, Equatable {
    package struct Workspace: Sendable, Equatable {
        package var cwd: String
        package var sortOrder: Double

        package init(cwd: String, sortOrder: Double) {
            self.cwd = cwd
            self.sortOrder = sortOrder
        }
    }

    package struct Review: Sendable, Equatable {
        package var id: String
        package var sortOrder: Double

        package init(id: String, sortOrder: Double) {
            self.id = id
            self.sortOrder = sortOrder
        }
    }

    package var workspaces: [Workspace]
    package var reviews: [Review]

    package init(workspaces: [Workspace], reviews: [Review]) {
        self.workspaces = workspaces
        self.reviews = reviews
    }
}

package protocol ReviewHistoryPersistence: Sendable {
    func load() async throws -> [ReviewHistoryRecord]
    func recordStarted(_ record: ReviewHistoryRecord) async throws
    func recordTerminal(
        _ record: ReviewHistoryRecord,
        retentionPolicy: ReviewHistoryRetentionPolicy
    ) async throws -> ReviewHistoryMutationResult
    func saveOrdering(_ ordering: ReviewHistoryOrdering) async throws
    func deleteReview(id: String) async throws
    func deleteAll() async throws
    func close() async throws
}

package struct DisabledReviewHistoryPersistence: ReviewHistoryPersistence {
    package init() {}

    package func load() async throws -> [ReviewHistoryRecord] {
        []
    }

    package func recordStarted(_: ReviewHistoryRecord) async throws {}

    package func recordTerminal(
        _: ReviewHistoryRecord,
        retentionPolicy _: ReviewHistoryRetentionPolicy
    ) async throws -> ReviewHistoryMutationResult {
        .init()
    }

    package func saveOrdering(_: ReviewHistoryOrdering) async throws {}

    package func deleteReview(id _: String) async throws {}

    package func deleteAll() async throws {}

    package func close() async throws {}
}
