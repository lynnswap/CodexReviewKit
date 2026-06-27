import Foundation
import Observation

@MainActor
@Observable
public final class CodexReviewJob: Identifiable, Hashable {
    public nonisolated let id: String
    public let timeline: ReviewTimeline
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
    private var syntheticTimelineItemCounter: UInt64

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
        self.timeline = ReviewTimeline()
        self.sessionID = sessionID
        self.cwd = cwd
        self.sortOrder = sortOrder
        self.targetSummary = targetSummary
        self.core = core
        self.cancellationRequested = cancellationRequested
        self.agentMessagesByItemID = [:]
        self.completedAgentMessageItemIDs = []
        self.syntheticTimelineItemCounter = 0
        syncTimelineTerminalStateFromCore()
    }

    public nonisolated static func == (lhs: CodexReviewJob, rhs: CodexReviewJob) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    package func nextSyntheticTimelineItemID(prefix: String) -> ReviewTimelineItem.ID {
        syntheticTimelineItemCounter &+= 1
        return .init(rawValue: "\(id):\(prefix):\(syntheticTimelineItemCounter)")
    }

    package func syncTimelineTerminalStateFromCore() {
        guard core.lifecycle.status.isTerminal else {
            return
        }
        let timestamp = core.lifecycle.endedAt ?? Date()
        switch core.lifecycle.status {
        case .succeeded:
            timeline.apply(
                .reviewCompleted(
                    summary: core.output.summary,
                    result: core.output.hasFinalReview ? core.output.lastAgentMessage?.nilIfEmpty : nil
                ),
                at: timestamp
            )
        case .failed:
            timeline.apply(.reviewFailed(core.lifecycle.errorMessage?.nilIfEmpty ?? core.output.summary), at: timestamp)
        case .cancelled:
            timeline.apply(
                .reviewCancelled(
                    core.lifecycle.cancellation?.message.nilIfEmpty
                        ?? core.lifecycle.errorMessage?.nilIfEmpty
                        ?? core.output.summary
                ),
                at: timestamp
            )
        case .queued, .running:
            break
        }
    }
}
