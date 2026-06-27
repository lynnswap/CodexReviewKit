import Foundation
import Observation

@MainActor
@Observable
public final class CodexReviewJob: Identifiable, Hashable {
    package enum TruncationDirection {
        case prefix
        case suffix
    }

    package enum LogMutation: Sendable, Equatable {
        case reload
        case append
    }

    @ObservationIgnored
    private var legacyLogBuffer: ReviewLegacyLogBuffer

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
    package private(set) var usesDirectTimelineEvents: Bool
    @ObservationIgnored
    private var pendingLegacyTimelineProjectionSuppressions: Int
    @ObservationIgnored
    private var pendingTerminalFailureLogTimelineProjectionSuppressions: Int
    @ObservationIgnored
    package var directTimelineTextItemIDs: Set<ReviewTimelineItem.ID>
    @ObservationIgnored
    package var directTimelineTextItemIDsWithRetainedLogText: Set<ReviewTimelineItem.ID>
    @ObservationIgnored
    package var retainedTimelineTextItemIDsByLogEntryID: [ReviewLogEntry.ID: Set<ReviewTimelineItem.ID>]
    @ObservationIgnored
    private var pendingDirectTimelineTextItemIDsForLogRetention: [ReviewTimelineItem.ID]
    @ObservationIgnored
    private var latestDirectTimelineTextItemIDs: [ReviewTimelineItem.ID]
    @ObservationIgnored
    package var legacyProjectedTimelineTextItemIDs: Set<ReviewTimelineItem.ID>
    public private(set) var logEntries: [ReviewLogEntry]
    public private(set) var logText: String
    public private(set) var rawLogText: String
    public private(set) var reviewOutputText: String
    public private(set) var activityLogText: String
    public private(set) var diagnosticText: String
    package private(set) var cappedLogBytes: Int
    package private(set) var logRevision: UInt64
    @ObservationIgnored
    package private(set) var lastLogMutation: LogMutation

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
        cancellationRequested: Bool = false,
        logEntries: [ReviewLogEntry]
    ) {
        let initialLogBuffer = ReviewLegacyLogBuffer(entries: logEntries)
        let initialLogSnapshot = initialLogBuffer.snapshot
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
        self.usesDirectTimelineEvents = false
        self.pendingLegacyTimelineProjectionSuppressions = 0
        self.pendingTerminalFailureLogTimelineProjectionSuppressions = 0
        self.directTimelineTextItemIDs = []
        self.directTimelineTextItemIDsWithRetainedLogText = []
        self.retainedTimelineTextItemIDsByLogEntryID = [:]
        self.pendingDirectTimelineTextItemIDsForLogRetention = []
        self.latestDirectTimelineTextItemIDs = []
        self.legacyProjectedTimelineTextItemIDs = []
        self.legacyLogBuffer = initialLogBuffer
        self.logEntries = initialLogSnapshot.entries
        self.logText = initialLogSnapshot.logText
        self.rawLogText = initialLogSnapshot.rawLogText
        self.reviewOutputText = initialLogSnapshot.reviewOutputText
        self.activityLogText = initialLogSnapshot.activityLogText
        self.diagnosticText = initialLogSnapshot.diagnosticText
        self.cappedLogBytes = initialLogSnapshot.cappedBytes
        self.logRevision = 0
        self.lastLogMutation = .reload
        if usesDirectTimelineEvents == false {
            rebuildTimelineFromLogEntries()
        }
    }

    public nonisolated static func == (lhs: CodexReviewJob, rhs: CodexReviewJob) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    package func replaceLogEntries(_ entries: [ReviewLogEntry], resetDirectTimeline: Bool = false) {
        legacyLogBuffer.replace(with: entries)
        syncLogEntriesFromBuffer()
        if resetDirectTimeline {
            usesDirectTimelineEvents = false
            pendingLegacyTimelineProjectionSuppressions = 0
            pendingTerminalFailureLogTimelineProjectionSuppressions = 0
            directTimelineTextItemIDs.removeAll(keepingCapacity: true)
            directTimelineTextItemIDsWithRetainedLogText.removeAll(keepingCapacity: true)
            retainedTimelineTextItemIDsByLogEntryID.removeAll(keepingCapacity: true)
            pendingDirectTimelineTextItemIDsForLogRetention.removeAll(keepingCapacity: true)
            latestDirectTimelineTextItemIDs.removeAll(keepingCapacity: true)
            legacyProjectedTimelineTextItemIDs.removeAll(keepingCapacity: true)
        }
        if usesDirectTimelineEvents {
            trimTimelineTextContentToLogEntries()
        } else {
            rebuildTimelineFromLogEntries()
        }
        syncLogSnapshot(mutation: .reload)
    }

    package func appendLogEntry(_ entry: ReviewLogEntry, suppressTimelineProjection: Bool = false) {
        let appendResult = legacyLogBuffer.append(entry)
        let entry = appendResult.entry
        syncLogEntriesFromBuffer()
        if usesDirectTimelineEvents, entry.canProvideDirectTimelineText {
            let allowsPendingRetainedText = suppressTimelineProjection || pendingLegacyTimelineProjectionSuppressions > 0
            if entry.retainedTimelineText != nil {
                recordDirectTimelineTextRetention(
                    for: entry,
                    allowsPendingRetainedText: allowsPendingRetainedText
                )
            } else {
                discardDirectTimelineTextRetention(
                    for: entry,
                    allowsPendingRetainedText: allowsPendingRetainedText
                )
            }
        }
        if suppressTimelineProjection == false,
           consumeLegacyTimelineProjectionSuppression() == false {
            applyTimelineEntry(entry)
            if usesDirectTimelineEvents, entry.canProvideDirectTimelineText {
                legacyProjectedTimelineTextItemIDs.insert(entry.timelineItemID)
            }
        }
        let didTrim = core.lifecycle.status.isTerminal ? trimReviewLogToLimit() : false
        if didTrim {
            rebuildTimelineFromLogEntries()
        }
        syncLogSnapshot(mutation: didTrim ? .reload : LogMutation(appendResult.mutation))
    }

    package func closeActiveCommandLogEntries(status: String, completedAt: Date) {
        let replacements = ReviewLegacyLogBuffer.activeCommandClosingEntries(
            entries: logEntries,
            status: status,
            completedAt: completedAt
        )
        for replacement in replacements {
            appendLogEntry(replacement)
        }
    }

    package func applyDirectTimelineEvents(
        _ events: [ReviewDomainEvent],
        legacyProjectionSuppressionCount: Int,
        at timestamp: Date
    ) {
        let directEvents = events.filter {
            $0.appliesFromDirectTimelineSource && shouldApplyDirectTimelineEvent($0)
        }
        guard directEvents.isEmpty == false else {
            return
        }
        if usesDirectTimelineEvents == false {
            recordLegacyProjectedTimelineTextItemIDsFromLogEntries()
        }
        usesDirectTimelineEvents = true
        pendingLegacyTimelineProjectionSuppressions += max(0, legacyProjectionSuppressionCount)
        var directTextItemIDsApplied: [ReviewTimelineItem.ID] = []
        for event in directEvents {
            if let itemID = event.directTimelineTextItemID {
                directTimelineTextItemIDs.insert(itemID)
                directTextItemIDsApplied.append(itemID)
            }
            timeline.apply(event, at: timestamp)
        }
        latestDirectTimelineTextItemIDs = directTextItemIDsApplied
        if legacyProjectionSuppressionCount > 0 {
            appendPendingDirectTimelineTextItemIDsForLogRetention(directTextItemIDsApplied)
        }
    }

    private func shouldApplyDirectTimelineEvent(_ event: ReviewDomainEvent) -> Bool {
        switch event {
        case .textDelta(let itemID, _, let family, _, _)
            where family == .message && completedAgentMessageItemIDs.contains(itemID.rawValue):
            false
        default:
            true
        }
    }

    private func recordDirectTimelineTextRetention(
        for entry: ReviewLogEntry,
        allowsPendingRetainedText: Bool
    ) {
        var itemIDs: Set<ReviewTimelineItem.ID> = []
        for itemID in entry.directTimelineTextCandidateIDs where directTimelineTextItemIDs.contains(itemID) {
            itemIDs.insert(itemID)
        }
        if itemIDs.isEmpty,
           allowsPendingRetainedText,
           let pendingItemID = popPendingDirectTimelineTextItemIDForLogRetention() {
            itemIDs.insert(pendingItemID)
        }
        guard itemIDs.isEmpty == false else {
            return
        }
        directTimelineTextItemIDsWithRetainedLogText.formUnion(itemIDs)
        retainedTimelineTextItemIDsByLogEntryID[entry.id, default: []].formUnion(itemIDs)
        removePendingDirectTimelineTextItemIDsForLogRetention(itemIDs)
    }

    private func discardDirectTimelineTextRetention(
        for entry: ReviewLogEntry,
        allowsPendingRetainedText: Bool
    ) {
        var itemIDs: Set<ReviewTimelineItem.ID> = []
        for itemID in entry.directTimelineTextCandidateIDs where directTimelineTextItemIDs.contains(itemID) {
            itemIDs.insert(itemID)
        }
        if itemIDs.isEmpty,
           allowsPendingRetainedText,
           let pendingItemID = popPendingDirectTimelineTextItemIDForLogRetention() {
            itemIDs.insert(pendingItemID)
        }
        removePendingDirectTimelineTextItemIDsForLogRetention(itemIDs)
    }

    private func appendPendingDirectTimelineTextItemIDsForLogRetention(_ itemIDs: [ReviewTimelineItem.ID]) {
        for itemID in itemIDs where pendingDirectTimelineTextItemIDsForLogRetention.contains(itemID) == false {
            pendingDirectTimelineTextItemIDsForLogRetention.append(itemID)
        }
    }

    private func popPendingDirectTimelineTextItemIDForLogRetention() -> ReviewTimelineItem.ID? {
        guard pendingDirectTimelineTextItemIDsForLogRetention.isEmpty == false else {
            return nil
        }
        return pendingDirectTimelineTextItemIDsForLogRetention.removeFirst()
    }

    private func removePendingDirectTimelineTextItemIDsForLogRetention(_ itemIDs: Set<ReviewTimelineItem.ID>) {
        guard itemIDs.isEmpty == false else {
            return
        }
        pendingDirectTimelineTextItemIDsForLogRetention.removeAll { itemIDs.contains($0) }
    }

    private func recordLegacyProjectedTimelineTextItemIDsFromLogEntries() {
        for entry in logEntries where entry.retainedTimelineText != nil {
            let itemID = entry.timelineItemID
            if timeline.item(for: itemID) != nil {
                legacyProjectedTimelineTextItemIDs.insert(itemID)
            }
        }
    }

    package func suppressNextLegacyTimelineProjection() {
        pendingLegacyTimelineProjectionSuppressions += 1
        appendPendingDirectTimelineTextItemIDsForLogRetention(latestDirectTimelineTextItemIDs)
    }

    package func suppressNextTerminalFailureLogTimelineProjection() {
        pendingTerminalFailureLogTimelineProjectionSuppressions += 1
        appendPendingDirectTimelineTextItemIDsForLogRetention(latestDirectTimelineTextItemIDs)
    }

    package func discardPendingLegacyTimelineProjectionSuppression() {
        _ = consumeLegacyTimelineProjectionSuppression()
    }

    package func consumeTerminalFailureLogTimelineProjectionSuppression() -> Bool {
        guard pendingTerminalFailureLogTimelineProjectionSuppressions > 0 else {
            return false
        }
        pendingTerminalFailureLogTimelineProjectionSuppressions -= 1
        return true
    }

    private func consumeLegacyTimelineProjectionSuppression() -> Bool {
        guard pendingLegacyTimelineProjectionSuppressions > 0 else {
            return false
        }
        pendingLegacyTimelineProjectionSuppressions -= 1
        return true
    }

    @discardableResult
    package func applyReviewLogLimit() -> Bool {
        guard trimReviewLogToLimit() else {
            return false
        }
        syncLogSnapshot(mutation: .reload)
        return true
    }

    @discardableResult
    private func trimReviewLogToLimit() -> Bool {
        guard legacyLogBuffer.applyLimit() else {
            return false
        }
        syncLogEntriesFromBuffer()
        if usesDirectTimelineEvents {
            trimTimelineTextContentToLogEntries()
        } else {
            rebuildTimelineFromLogEntries()
        }
        return true
    }

    package func truncateOrRemoveEntry(
        at index: Int,
        keeping direction: TruncationDirection,
        overflowBytes: Int
    ) {
        guard legacyLogBuffer.truncateOrRemoveEntry(
            at: index,
            keeping: ReviewLegacyLogBuffer.TruncationDirection(direction),
            overflowBytes: overflowBytes
        ) else {
            return
        }
        syncLogEntriesFromBuffer()
        if usesDirectTimelineEvents {
            trimTimelineTextContentToLogEntries()
        } else {
            rebuildTimelineFromLogEntries()
        }
        syncLogSnapshot(mutation: .reload)
    }

    private func syncLogEntriesFromBuffer() {
        logEntries = legacyLogBuffer.entries
    }

    private func syncLogSnapshot(mutation: LogMutation) {
        let snapshot = legacyLogBuffer.snapshot
        logEntries = snapshot.entries
        logText = snapshot.logText
        rawLogText = snapshot.rawLogText
        reviewOutputText = snapshot.reviewOutputText
        activityLogText = snapshot.activityLogText
        diagnosticText = snapshot.diagnosticText
        cappedLogBytes = snapshot.cappedBytes
        lastLogMutation = mutation
        logRevision &+= 1
    }

}

private extension CodexReviewJob.LogMutation {
    init(_ mutation: ReviewLegacyLogBuffer.Mutation) {
        switch mutation {
        case .reload:
            self = .reload
        case .append:
            self = .append
        }
    }
}

private extension ReviewLegacyLogBuffer.TruncationDirection {
    init(_ direction: CodexReviewJob.TruncationDirection) {
        switch direction {
        case .prefix:
            self = .prefix
        case .suffix:
            self = .suffix
        }
    }
}

private extension ReviewDomainEvent {
    var appliesFromDirectTimelineSource: Bool {
        switch self {
        case .itemStarted, .itemUpdated, .itemCompleted, .textDelta:
            true
        case .runStarted, .reviewCompleted, .reviewFailed, .reviewCancelled:
            false
        }
    }

    var directTimelineTextItemID: ReviewTimelineItem.ID? {
        switch self {
        case .itemStarted(let seed),
             .itemUpdated(let seed),
             .itemCompleted(let seed):
            seed.hasTrimmableTimelineText ? seed.id : nil
        case .textDelta(let itemID, _, _, _, _):
            itemID
        case .runStarted, .reviewCompleted, .reviewFailed, .reviewCancelled:
            nil
        }
    }
}

private extension ReviewTimelineItemSeed {
    var hasTrimmableTimelineText: Bool {
        switch content {
        case .fileChange(let fileChange):
            fileChange.output.isEmpty == false
                && kind.rawValue != "item/fileChange/patchUpdated"
        default:
            content.hasTrimmableTimelineText
        }
    }
}

private extension ReviewTimelineItem.Content {
    var hasTrimmableTimelineText: Bool {
        switch self {
        case .command(let command):
            command.output.isEmpty == false
        case .diagnostic(let diagnostic):
            diagnostic.message.isEmpty == false
        case .message,
             .plan,
             .reasoning:
            true
        case .search(let search):
            search.result?.isEmpty == false
        case .toolCall(let toolCall):
            toolCall.progress?.isEmpty == false
                || toolCall.result?.isEmpty == false
                || toolCall.error?.isEmpty == false
        case .fileChange:
            false
        case .approval,
             .contextCompaction,
             .unknown:
            false
        }
    }
}
