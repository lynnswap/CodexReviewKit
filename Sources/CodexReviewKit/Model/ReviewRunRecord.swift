import Foundation
import Observation

@MainActor
@Observable
public final class ReviewRunRecord: Identifiable, Hashable {
    public nonisolated let id: String
    public let sessionID: String
    public let cwd: String
    public internal(set) var sortOrder: Double
    public internal(set) var targetSummary: String
    public internal(set) var core: ReviewJobCore
    public internal(set) var cancellationRequested: Bool

    @ObservationIgnored
    package var agentMessagesByItemID: [String: String]
    @ObservationIgnored
    package var completedAgentMessageItemIDs: Set<String>
    @ObservationIgnored
    private var syntheticMessageItemCounter: UInt64

    public var isTerminal: Bool {
        core.isTerminal
    }

    public var displayTitle: String {
        targetSummary
    }

    public var reviewText: String {
        core.reviewText
    }

    package init(
        id: String,
        sessionID: String,
        cwd: String,
        sortOrder: Double = 0,
        targetSummary: String,
        core: ReviewJobCore,
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
        self.completedAgentMessageItemIDs = []
        self.syntheticMessageItemCounter = 0
    }

    public nonisolated static func == (lhs: ReviewRunRecord, rhs: ReviewRunRecord) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    package func nextSyntheticMessageItemID(prefix: String) -> String {
        syntheticMessageItemCounter &+= 1
        return "\(id):\(prefix):\(syntheticMessageItemCounter)"
    }
}
