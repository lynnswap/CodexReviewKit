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
    private var logBuffer: ReviewLogBuffer

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
    private var pendingTimelineTextRetentionEntries: Int
    @ObservationIgnored
    private var pendingTerminalFailureTimelineTextRetentionEntries: Int
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
    package private(set) var logEntries: [ReviewLogEntry]
    package private(set) var logText: String
    package private(set) var rawLogText: String
    package private(set) var reviewOutputText: String
    package private(set) var activityLogText: String
    package private(set) var diagnosticText: String
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
        logEntries: [ReviewLogEntry] = []
    ) {
        let initialLogBuffer = ReviewLogBuffer(entries: logEntries)
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
        self.pendingTimelineTextRetentionEntries = 0
        self.pendingTerminalFailureTimelineTextRetentionEntries = 0
        self.directTimelineTextItemIDs = []
        self.directTimelineTextItemIDsWithRetainedLogText = []
        self.retainedTimelineTextItemIDsByLogEntryID = [:]
        self.pendingDirectTimelineTextItemIDsForLogRetention = []
        self.latestDirectTimelineTextItemIDs = []
        self.logBuffer = initialLogBuffer
        self.logEntries = initialLogSnapshot.entries
        self.logText = initialLogSnapshot.logText
        self.rawLogText = initialLogSnapshot.rawLogText
        self.reviewOutputText = initialLogSnapshot.reviewOutputText
        self.activityLogText = initialLogSnapshot.activityLogText
        self.diagnosticText = initialLogSnapshot.diagnosticText
        self.cappedLogBytes = initialLogSnapshot.cappedBytes
        self.logRevision = 0
        self.lastLogMutation = .reload
        syncTimelineTerminalStateFromCore()
    }

    public nonisolated static func == (lhs: CodexReviewJob, rhs: CodexReviewJob) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    package func replaceLogEntries(_ entries: [ReviewLogEntry], resetDirectTimeline: Bool = false) {
        logBuffer.replace(with: entries)
        syncLogEntriesFromBuffer()
        if resetDirectTimeline {
            pendingTimelineTextRetentionEntries = 0
            pendingTerminalFailureTimelineTextRetentionEntries = 0
            directTimelineTextItemIDs.removeAll(keepingCapacity: true)
            directTimelineTextItemIDsWithRetainedLogText.removeAll(keepingCapacity: true)
            retainedTimelineTextItemIDsByLogEntryID.removeAll(keepingCapacity: true)
            pendingDirectTimelineTextItemIDsForLogRetention.removeAll(keepingCapacity: true)
            latestDirectTimelineTextItemIDs.removeAll(keepingCapacity: true)
            timeline.reset(keepingTerminal: core.lifecycle.status.isTerminal)
            syncTimelineTerminalStateFromCore()
        }
        trimTimelineTextContentToLogEntries()
        syncLogSnapshot(mutation: .reload)
    }

    package func appendLogEntry(_ entry: ReviewLogEntry, retainTimelineText: Bool = false) {
        let appendResult = logBuffer.append(entry)
        let entry = appendResult.entry
        syncLogEntriesFromBuffer()
        if entry.canProvideDirectTimelineText {
            let allowsPendingRetainedText = retainTimelineText || pendingTimelineTextRetentionEntries > 0
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
        if retainTimelineText == false {
            _ = consumeTimelineTextRetention()
        }
        let didTrim = core.lifecycle.status.isTerminal ? trimReviewLogToLimit() : false
        syncLogSnapshot(mutation: didTrim ? .reload : LogMutation(appendResult.mutation))
    }

    package func closeActiveCommandLogEntries(status: String, completedAt: Date) {
        let replacements = ReviewLogBuffer.activeCommandClosingEntries(
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
        retainedLogEntryCount: Int,
        at timestamp: Date
    ) {
        let directEvents = events.filter {
            $0.appliesFromDirectTimelineSource && shouldApplyDirectTimelineEvent($0)
        }
        guard directEvents.isEmpty == false else {
            return
        }
        pendingTimelineTextRetentionEntries += max(0, retainedLogEntryCount)
        var directTextItemIDsApplied: [ReviewTimelineItem.ID] = []
        for event in directEvents {
            if let itemID = event.directTimelineTextItemID {
                directTimelineTextItemIDs.insert(itemID)
                directTextItemIDsApplied.append(itemID)
            }
            timeline.apply(event, at: timestamp)
        }
        latestDirectTimelineTextItemIDs = directTextItemIDsApplied
        if retainedLogEntryCount > 0 {
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
            let pendingItemID = popPendingDirectTimelineTextItemIDForLogRetention()
        {
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
            let pendingItemID = popPendingDirectTimelineTextItemIDForLogRetention()
        {
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

    package func retainNextTimelineTextFromLogEntry() {
        pendingTimelineTextRetentionEntries += 1
        appendPendingDirectTimelineTextItemIDsForLogRetention(latestDirectTimelineTextItemIDs)
    }

    package func retainNextTerminalFailureTimelineTextFromLogEntry() {
        pendingTerminalFailureTimelineTextRetentionEntries += 1
        appendPendingDirectTimelineTextItemIDsForLogRetention(latestDirectTimelineTextItemIDs)
    }

    package func discardPendingTimelineTextRetention() {
        _ = consumeTimelineTextRetention()
    }

    package func consumeTerminalFailureTimelineTextRetention() -> Bool {
        guard pendingTerminalFailureTimelineTextRetentionEntries > 0 else {
            return false
        }
        pendingTerminalFailureTimelineTextRetentionEntries -= 1
        return true
    }

    private func consumeTimelineTextRetention() -> Bool {
        guard pendingTimelineTextRetentionEntries > 0 else {
            return false
        }
        pendingTimelineTextRetentionEntries -= 1
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
        guard logBuffer.applyLimit() else {
            return false
        }
        syncLogEntriesFromBuffer()
        trimTimelineTextContentToLogEntries()
        return true
    }

    package func truncateOrRemoveEntry(
        at index: Int,
        keeping direction: TruncationDirection,
        overflowBytes: Int
    ) {
        guard
            logBuffer.truncateOrRemoveEntry(
                at: index,
                keeping: ReviewLogBuffer.TruncationDirection(direction),
                overflowBytes: overflowBytes
            )
        else {
            return
        }
        syncLogEntriesFromBuffer()
        trimTimelineTextContentToLogEntries()
        syncLogSnapshot(mutation: .reload)
    }

    private func syncLogEntriesFromBuffer() {
        logEntries = logBuffer.entries
    }

    private func syncLogSnapshot(mutation: LogMutation) {
        let snapshot = logBuffer.snapshot
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
    init(_ mutation: ReviewLogBuffer.Mutation) {
        switch mutation {
        case .reload:
            self = .reload
        case .append:
            self = .append
        }
    }
}

private extension ReviewLogBuffer.TruncationDirection {
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
