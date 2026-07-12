import Foundation
import Observation

@MainActor
@Observable
package final class ReviewRunRecord: Identifiable, Hashable {
    package nonisolated let id: ReviewRunID
    package let sessionID: String
    package let cwd: String
    package var sortOrder: Double
    package var targetSummary: String
    package var core: ReviewRunCore
    package var executionPhase: ReviewExecutionPhase?
    package var cancellationRequested: Bool
    package var pendingCancellation: ReviewCancellation?

    package var isTerminal: Bool {
        core.isTerminal
    }

    package init(
        id: ReviewRunID,
        sessionID: String,
        cwd: String,
        sortOrder: Double = 0,
        targetSummary: String,
        core: ReviewRunCore = .queued,
        executionPhase: ReviewExecutionPhase? = .starting,
        cancellationRequested: Bool = false,
        pendingCancellation: ReviewCancellation? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.cwd = cwd
        self.sortOrder = sortOrder
        self.targetSummary = targetSummary
        self.core = core
        self.executionPhase = executionPhase
        self.cancellationRequested = cancellationRequested
        self.pendingCancellation = pendingCancellation
    }

    package var presentation: ReviewRunPresentation {
        ReviewRunPresentation(core: core, executionPhase: executionPhase)
    }

    package nonisolated static func == (lhs: ReviewRunRecord, rhs: ReviewRunRecord) -> Bool {
        lhs.id == rhs.id
    }

    package nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

}
