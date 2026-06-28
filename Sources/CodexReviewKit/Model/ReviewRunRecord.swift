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

    @ObservationIgnored
    package var agentMessagesByItemID: [String: String]
    @ObservationIgnored
    package var latestAgentMessageItemID: String?
    @ObservationIgnored
    package var completedAgentMessageItemIDs: Set<String>
    @ObservationIgnored
    private var syntheticMessageItemCounter: UInt64

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
        self.agentMessagesByItemID = [:]
        self.latestAgentMessageItemID = nil
        self.completedAgentMessageItemIDs = []
        self.syntheticMessageItemCounter = 0
    }

    package nonisolated static func == (lhs: ReviewRunRecord, rhs: ReviewRunRecord) -> Bool {
        lhs.id == rhs.id
    }

    package nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    package func nextSyntheticMessageItemID(prefix: String) -> String {
        syntheticMessageItemCounter &+= 1
        return "\(id):\(prefix):\(syntheticMessageItemCounter)"
    }
}
