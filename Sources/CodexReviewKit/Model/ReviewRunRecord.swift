import Foundation
import Observation

@MainActor
@Observable
package final class ReviewRunRecord: Identifiable, Hashable {
    package nonisolated let id: String
    package let sessionID: String
    package let cwd: String
    package var sortOrder: Double
    package var targetSummary: String
    package var core: ReviewRunCore
    package var cancellationRequested: Bool

    package var isTerminal: Bool {
        core.isTerminal
    }

    package init(
        id: String,
        sessionID: String,
        cwd: String,
        sortOrder: Double = 0,
        targetSummary: String,
        core: ReviewRunCore,
        cancellationRequested: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.cwd = cwd
        self.sortOrder = sortOrder
        self.targetSummary = targetSummary
        self.core = core
        self.cancellationRequested = cancellationRequested
    }

    package nonisolated static func == (lhs: ReviewRunRecord, rhs: ReviewRunRecord) -> Bool {
        lhs.id == rhs.id
    }

    package nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

}
