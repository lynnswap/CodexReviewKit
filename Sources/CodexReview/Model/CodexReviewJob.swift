import Foundation
import Observation
import CodexReviewDomain

@MainActor
@Observable
public final class CodexReviewJob: Identifiable, Hashable {
    package enum TruncationDirection {
        case prefix
        case suffix
    }

    private struct GroupKey: Hashable {
        var kind: ReviewLogEntry.Kind
        var groupID: String
    }

    private struct RenderedBlock {
        var kind: ReviewLogEntry.Kind
        var groupID: String?
        var text: String
    }

    package enum LogMutation: Sendable, Equatable {
        case reload
        case append
    }

    private struct ProjectionAccumulator {
        enum JoinMode {
            case rendered
            case rawLines
        }

        let joinMode: JoinMode
        private(set) var text = ""
        private(set) var hasVisibleSections = false
        private(set) var lastBlockIndex: Int?

        mutating func appendSection(_ section: String, at blockIndex: Int) -> String {
            let appended: String
            if hasVisibleSections == false {
                text = section
                hasVisibleSections = true
                lastBlockIndex = blockIndex
                return section
            }

            switch joinMode {
            case .rawLines:
                appended = "\n" + section
            case .rendered:
                if section.isEmpty {
                    appended = "\n\n"
                } else if text.hasSuffix("\n\n") {
                    appended = section
                } else if text.hasSuffix("\n") || section.hasPrefix("\n") {
                    appended = "\n" + section
                } else {
                    appended = "\n\n" + section
                }
            }

            text += appended
            lastBlockIndex = blockIndex
            return appended
        }

        mutating func appendToCurrentSection(_ suffix: String) {
            guard suffix.isEmpty == false else {
                return
            }
            text += suffix
        }
    }

    private struct LogState {
        var blocks: [RenderedBlock]
        var indexByGroup: [GroupKey: Int]
        var logProjection: ProjectionAccumulator
        var reviewOutputProjection: ProjectionAccumulator
        var activityProjection: ProjectionAccumulator
        var errorProjection: ProjectionAccumulator
        var rawProjection: ProjectionAccumulator
        var cappedProjection: ProjectionAccumulator

        init(
            blocks: [RenderedBlock],
            indexByGroup: [GroupKey: Int],
            logProjection: ProjectionAccumulator,
            reviewOutputProjection: ProjectionAccumulator,
            activityProjection: ProjectionAccumulator,
            errorProjection: ProjectionAccumulator,
            rawProjection: ProjectionAccumulator,
            cappedProjection: ProjectionAccumulator
        ) {
            self.blocks = blocks
            self.indexByGroup = indexByGroup
            self.logProjection = logProjection
            self.reviewOutputProjection = reviewOutputProjection
            self.activityProjection = activityProjection
            self.errorProjection = errorProjection
            self.rawProjection = rawProjection
            self.cappedProjection = cappedProjection
        }

        init(entries: [ReviewLogEntry]) {
            self = Self.rebuild(entries: entries)
        }

        var logText: String {
            logProjection.text
        }

        var rawLogText: String {
            rawProjection.text
        }

        var reviewOutputText: String {
            reviewOutputProjection.text
        }

        var activityLogText: String {
            activityProjection.text
        }

        var diagnosticText: String {
            CodexReviewJob.combinedText(
                sections: [
                    errorProjection.text,
                    rawProjection.text,
                ]
            )
        }

        var cappedBytes: Int {
            cappedProjection.text.utf8.count
        }

        static func rebuild(entries: [ReviewLogEntry]) -> LogState {
            var state = LogState(
                blocks: [],
                indexByGroup: [:],
                logProjection: .init(joinMode: .rendered),
                reviewOutputProjection: .init(joinMode: .rendered),
                activityProjection: .init(joinMode: .rendered),
                errorProjection: .init(joinMode: .rendered),
                rawProjection: .init(joinMode: .rawLines),
                cappedProjection: .init(joinMode: .rendered)
            )

            for entry in entries {
                if let key = CodexReviewJob.mergeKey(for: entry) {
                    if let index = state.indexByGroup[key] {
                        if entry.replacesGroup {
                            state.blocks[index].text = entry.text
                        } else {
                            state.blocks[index].text.append(entry.text)
                        }
                        continue
                    }
                    state.indexByGroup[key] = state.blocks.count
                }

                state.blocks.append(.init(
                    kind: entry.kind,
                    groupID: entry.groupID,
                    text: entry.text
                ))
            }

            for (index, block) in state.blocks.enumerated() {
                state.ingestBlock(block, at: index)
            }
            return state
        }

        func supportsIncrementalAppend(_ entry: ReviewLogEntry) -> Bool {
            guard entry.replacesGroup == false,
                  let key = CodexReviewJob.mergeKey(for: entry),
                  let blockIndex = indexByGroup[key]
            else {
                return entry.replacesGroup == false
            }
            return blockIndex == blocks.indices.last
        }

        mutating func append(_ entry: ReviewLogEntry) {
            if let key = CodexReviewJob.mergeKey(for: entry) {
                if let blockIndex = indexByGroup[key] {
                    let oldText = blocks[blockIndex].text
                    precondition(entry.replacesGroup == false && blockIndex == blocks.indices.last)

                    blocks[blockIndex].text.append(entry.text)
                    let newText = blocks[blockIndex].text
                    appendTailGroupDelta(
                        block: blocks[blockIndex],
                        oldText: oldText,
                        newText: newText,
                        blockIndex: blockIndex,
                        delta: entry.text
                    )
                    return
                }

                indexByGroup[key] = blocks.count
            }

            let blockIndex = blocks.count
            let block = RenderedBlock(
                kind: entry.kind,
                groupID: entry.groupID,
                text: entry.text
            )
            blocks.append(block)
            appendTailBlock(block, at: blockIndex)
        }

        private mutating func ingestBlock(_ block: RenderedBlock, at index: Int) {
            _ = Self.updateRenderedProjection(
                &logProjection,
                block: block,
                blockIndex: index,
                visibleKinds: CodexReviewJob.displayedLogKinds,
                includeEmptyDiagnostic: true
            )
            _ = Self.updateRenderedProjection(
                &reviewOutputProjection,
                block: block,
                blockIndex: index,
                visibleKinds: CodexReviewJob.reviewOutputKinds,
                includeEmptyDiagnostic: false
            )
            _ = Self.updateRenderedProjection(
                &activityProjection,
                block: block,
                blockIndex: index,
                visibleKinds: CodexReviewJob.activityKinds,
                includeEmptyDiagnostic: false
            )
            _ = Self.updateRenderedProjection(
                &errorProjection,
                block: block,
                blockIndex: index,
                visibleKinds: [.error],
                includeEmptyDiagnostic: false
            )
            _ = Self.updateRenderedProjection(
                &cappedProjection,
                block: block,
                blockIndex: index,
                visibleKinds: CodexReviewJob.cappedLogKinds,
                includeEmptyDiagnostic: false
            )
            if block.kind == .diagnostic {
                _ = rawProjection.appendSection(block.text, at: index)
            }
        }

        private mutating func appendTailBlock(
            _ block: RenderedBlock,
            at blockIndex: Int
        ) {
            _ = Self.updateRenderedProjection(
                &logProjection,
                block: block,
                blockIndex: blockIndex,
                visibleKinds: CodexReviewJob.displayedLogKinds,
                includeEmptyDiagnostic: true
            )
            _ = Self.updateRenderedProjection(
                &reviewOutputProjection,
                block: block,
                blockIndex: blockIndex,
                visibleKinds: CodexReviewJob.reviewOutputKinds,
                includeEmptyDiagnostic: false
            )
            _ = Self.updateRenderedProjection(
                &activityProjection,
                block: block,
                blockIndex: blockIndex,
                visibleKinds: CodexReviewJob.activityKinds,
                includeEmptyDiagnostic: false
            )
            _ = Self.updateRenderedProjection(
                &errorProjection,
                block: block,
                blockIndex: blockIndex,
                visibleKinds: [.error],
                includeEmptyDiagnostic: false
            )
            _ = Self.updateRenderedProjection(
                &cappedProjection,
                block: block,
                blockIndex: blockIndex,
                visibleKinds: CodexReviewJob.cappedLogKinds,
                includeEmptyDiagnostic: false
            )
            if block.kind == .diagnostic {
                _ = rawProjection.appendSection(block.text, at: blockIndex)
            }
        }

        private mutating func appendTailGroupDelta(
            block: RenderedBlock,
            oldText: String,
            newText: String,
            blockIndex: Int,
            delta: String
        ) {
            _ = Self.updateTailProjection(
                &logProjection,
                kind: block.kind,
                oldText: oldText,
                newText: newText,
                blockIndex: blockIndex,
                delta: delta,
                visibleKinds: CodexReviewJob.displayedLogKinds,
                includeEmptyDiagnostic: true
            )
            _ = Self.updateTailProjection(
                &reviewOutputProjection,
                kind: block.kind,
                oldText: oldText,
                newText: newText,
                blockIndex: blockIndex,
                delta: delta,
                visibleKinds: CodexReviewJob.reviewOutputKinds,
                includeEmptyDiagnostic: false
            )
            _ = Self.updateTailProjection(
                &activityProjection,
                kind: block.kind,
                oldText: oldText,
                newText: newText,
                blockIndex: blockIndex,
                delta: delta,
                visibleKinds: CodexReviewJob.activityKinds,
                includeEmptyDiagnostic: false
            )
            _ = Self.updateTailProjection(
                &errorProjection,
                kind: block.kind,
                oldText: oldText,
                newText: newText,
                blockIndex: blockIndex,
                delta: delta,
                visibleKinds: [.error],
                includeEmptyDiagnostic: false
            )
            _ = Self.updateTailProjection(
                &cappedProjection,
                kind: block.kind,
                oldText: oldText,
                newText: newText,
                blockIndex: blockIndex,
                delta: delta,
                visibleKinds: CodexReviewJob.cappedLogKinds,
                includeEmptyDiagnostic: false
            )
        }

        private static func updateTailProjection(
            _ projection: inout ProjectionAccumulator,
            kind: ReviewLogEntry.Kind,
            oldText: String,
            newText: String,
            blockIndex: Int,
            delta: String,
            visibleKinds: Set<ReviewLogEntry.Kind>,
            includeEmptyDiagnostic: Bool
        ) -> String? {
            let wasVisible = CodexReviewJob.isVisibleInRenderedProjection(
                kind: kind,
                text: oldText,
                visibleKinds: visibleKinds,
                includeEmptyDiagnostic: includeEmptyDiagnostic
            )
            let isVisible = CodexReviewJob.isVisibleInRenderedProjection(
                kind: kind,
                text: newText,
                visibleKinds: visibleKinds,
                includeEmptyDiagnostic: includeEmptyDiagnostic
            )

            switch (wasVisible, isVisible) {
            case (false, false):
                return nil
            case (false, true):
                return projection.appendSection(newText, at: blockIndex)
            case (true, true):
                projection.appendToCurrentSection(delta)
                return delta
            case (true, false):
                return nil
            }
        }

        private static func updateRenderedProjection(
            _ projection: inout ProjectionAccumulator,
            block: RenderedBlock,
            blockIndex: Int,
            visibleKinds: Set<ReviewLogEntry.Kind>,
            includeEmptyDiagnostic: Bool
        ) -> String? {
            guard CodexReviewJob.isVisibleInRenderedProjection(
                kind: block.kind,
                text: block.text,
                visibleKinds: visibleKinds,
                includeEmptyDiagnostic: includeEmptyDiagnostic
            ) else {
                return nil
            }
            return projection.appendSection(block.text, at: blockIndex)
        }
    }

    private struct TrimmedLogState {
        var entries: [ReviewLogEntry]
        var logState: LogState
    }

    @ObservationIgnored
    private var logState: LogState

    public nonisolated let id: String
    public let domainJob: ReviewJob
    public var timeline: ReviewTimeline {
        domainJob.timeline
    }
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
    package var directTimelineTextItemIDsWithCompatibilityLog: Set<ReviewTimelineItem.ID>
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
        let initialState = Self.trimmedLogState(entries: logEntries)
        self.id = id
        self.domainJob = ReviewJob(id: .init(rawValue: id))
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
        self.directTimelineTextItemIDsWithCompatibilityLog = []
        self.legacyProjectedTimelineTextItemIDs = []
        self.logState = initialState.logState
        self.logEntries = initialState.entries
        self.logText = initialState.logState.logText
        self.rawLogText = initialState.logState.rawLogText
        self.reviewOutputText = initialState.logState.reviewOutputText
        self.activityLogText = initialState.logState.activityLogText
        self.diagnosticText = initialState.logState.diagnosticText
        self.cappedLogBytes = initialState.logState.cappedBytes
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
        let trimmedState = Self.trimmedLogState(entries: entries)
        logEntries = trimmedState.entries
        logState = trimmedState.logState
        if resetDirectTimeline {
            usesDirectTimelineEvents = false
            pendingLegacyTimelineProjectionSuppressions = 0
            pendingTerminalFailureLogTimelineProjectionSuppressions = 0
            directTimelineTextItemIDs.removeAll(keepingCapacity: true)
            directTimelineTextItemIDsWithCompatibilityLog.removeAll(keepingCapacity: true)
            legacyProjectedTimelineTextItemIDs.removeAll(keepingCapacity: true)
        }
        if usesDirectTimelineEvents {
            trimTimelineTextContentToLogEntries()
        } else {
            rebuildTimelineFromLogEntries()
        }
        syncLogState(mutation: .reload)
    }

    package func appendLogEntry(_ entry: ReviewLogEntry, suppressTimelineProjection: Bool = false) {
        let supportsIncrementalAppend = logState.supportsIncrementalAppend(entry)
        if supportsIncrementalAppend {
            logState.append(entry)
        }
        logEntries.append(entry)
        if supportsIncrementalAppend == false {
            logState = LogState(entries: logEntries)
        }
        if usesDirectTimelineEvents, entry.canProvideDirectTimelineText {
            recordDirectTimelineTextCompatibilityLog(for: entry)
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
        syncLogState(mutation: didTrim || supportsIncrementalAppend == false ? .reload : .append)
    }

    package func closeActiveCommandLogEntries(status: String, completedAt: Date) {
        let replacements = Self.activeCommandClosingEntries(
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
        for event in directEvents {
            if let itemID = event.directTimelineTextItemID {
                directTimelineTextItemIDs.insert(itemID)
            }
            timeline.apply(event, at: timestamp)
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

    private func recordDirectTimelineTextCompatibilityLog(for entry: ReviewLogEntry) {
        for itemID in entry.directTimelineTextCandidateIDs where directTimelineTextItemIDs.contains(itemID) {
            directTimelineTextItemIDsWithCompatibilityLog.insert(itemID)
        }
    }

    private func recordLegacyProjectedTimelineTextItemIDsFromLogEntries() {
        for entry in logEntries where entry.canProvideDirectTimelineText {
            let itemID = entry.timelineItemID
            if timeline.item(for: itemID) != nil {
                legacyProjectedTimelineTextItemIDs.insert(itemID)
            }
        }
    }

    package func suppressNextLegacyTimelineProjection() {
        pendingLegacyTimelineProjectionSuppressions += 1
    }

    package func suppressNextTerminalFailureLogTimelineProjection() {
        pendingTerminalFailureLogTimelineProjectionSuppressions += 1
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
        syncLogState(mutation: .reload)
        return true
    }

    @discardableResult
    private func trimReviewLogToLimit() -> Bool {
        guard logState.cappedBytes > Self.logLimitBytes else {
            return false
        }

        let trimmedState = Self.trimmedLogState(entries: logEntries)
        guard trimmedState.entries != logEntries else {
            return false
        }
        logEntries = trimmedState.entries
        logState = trimmedState.logState
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
        var entries = logEntries
        guard entries.indices.contains(index) else {
            return
        }

        let entry = entries[index]
        let retainedBytes = max(0, entry.text.utf8.count - overflowBytes)
        let truncatedText = switch direction {
        case .prefix:
            Self.truncateTextKeepingUTF8Prefix(entry.text, bytes: retainedBytes)
        case .suffix:
            Self.truncateTextKeepingUTF8Suffix(entry.text, bytes: retainedBytes)
        }

        if truncatedText.isEmpty {
            entries.remove(at: index)
        } else {
            entries[index] = .init(
                id: entry.id,
                kind: entry.kind,
                groupID: entry.groupID,
                replacesGroup: entry.replacesGroup,
                text: truncatedText,
                metadata: entry.metadata,
                timestamp: entry.timestamp
            )
        }
        replaceLogEntries(entries)
    }

    private func syncLogState(mutation: LogMutation) {
        logText = logState.logText
        rawLogText = logState.rawLogText
        reviewOutputText = logState.reviewOutputText
        activityLogText = logState.activityLogText
        diagnosticText = logState.diagnosticText
        cappedLogBytes = logState.cappedBytes
        lastLogMutation = mutation
        logRevision &+= 1
    }

    private nonisolated static func trimmedLogState(entries initialEntries: [ReviewLogEntry]) -> TrimmedLogState {
        var entries = initialEntries
        var logState = LogState(entries: entries)

        while logState.cappedBytes > logLimitBytes {
            let overflowBytes = logState.cappedBytes - logLimitBytes
            guard let trimmedEntries = trimOnce(entries: entries, overflowBytes: overflowBytes) else {
                break
            }
            entries = trimmedEntries
            logState = LogState(entries: entries)
        }

        return .init(entries: entries, logState: logState)
    }

    private nonisolated static func trimOnce(
        entries: [ReviewLogEntry],
        overflowBytes: Int
    ) -> [ReviewLogEntry]? {
        if let index = entries.firstIndex(where: { $0.kind == .diagnostic }) {
            return trimWholeEntryPreferringNewest(
                entries: entries,
                at: index,
                kind: .diagnostic,
                overflowBytes: overflowBytes
            )
        }

        if let index = entries.firstIndex(where: { $0.kind == .rawReasoning }) {
            return trimEntry(
                entries: entries,
                at: index,
                overflowBytes: overflowBytes,
                direction: .suffix
            )
        }

        if let index = entries.firstIndex(where: { prefixTrimmableCappedKinds.contains($0.kind) }) {
            return trimEntry(
                entries: entries,
                at: index,
                overflowBytes: overflowBytes,
                direction: .suffix
            )
        }

        if let index = entries.firstIndex(where: { $0.kind == .error }) {
            return trimEntry(
                entries: entries,
                at: index,
                overflowBytes: overflowBytes,
                direction: .suffix
            )
        }

        return nil
    }

    private nonisolated static func trimWholeEntryPreferringNewest(
        entries: [ReviewLogEntry],
        at index: Int,
        kind: ReviewLogEntry.Kind,
        overflowBytes: Int
    ) -> [ReviewLogEntry] {
        let entry = entries[index]
        let hasNewerEntryOfSameKind = entries.dropFirst(index + 1).contains { $0.kind == kind }
        let hasOtherCappedEntries = entries.contains {
            $0.id != entry.id && cappedLogKinds.contains($0.kind)
        }

        if hasNewerEntryOfSameKind || hasOtherCappedEntries {
            var trimmedEntries = entries
            trimmedEntries.remove(at: index)
            return trimmedEntries
        }

        return trimEntry(
            entries: entries,
            at: index,
            overflowBytes: overflowBytes,
            direction: .prefix
        )
    }

    private nonisolated static func trimEntry(
        entries: [ReviewLogEntry],
        at index: Int,
        overflowBytes: Int,
        direction: TruncationDirection
    ) -> [ReviewLogEntry] {
        var trimmedEntries = entries
        let entry = trimmedEntries[index]

        if entry.text.utf8.count <= overflowBytes {
            trimmedEntries.remove(at: index)
            return trimmedEntries
        }

        let retainedBytes = max(0, entry.text.utf8.count - overflowBytes)
        let truncatedText = switch direction {
        case .prefix:
            truncateTextKeepingUTF8Prefix(entry.text, bytes: retainedBytes)
        case .suffix:
            truncateTextKeepingUTF8Suffix(entry.text, bytes: retainedBytes)
        }

        if truncatedText.isEmpty {
            trimmedEntries.remove(at: index)
            return trimmedEntries
        }

        trimmedEntries[index] = .init(
            id: entry.id,
            kind: entry.kind,
            groupID: entry.groupID,
            replacesGroup: entry.replacesGroup,
            text: truncatedText,
            metadata: entry.metadata,
            timestamp: entry.timestamp
        )
        return trimmedEntries
    }

    private nonisolated static func truncateTextKeepingUTF8Prefix(_ text: String, bytes maxBytes: Int) -> String {
        guard maxBytes > 0 else {
            return ""
        }

        var result = ""
        var usedBytes = 0
        for character in text {
            let characterBytes = String(character).utf8.count
            if usedBytes + characterBytes > maxBytes {
                break
            }
            result.append(character)
            usedBytes += characterBytes
        }
        return result
    }

    private nonisolated static func truncateTextKeepingUTF8Suffix(_ text: String, bytes maxBytes: Int) -> String {
        guard maxBytes > 0 else {
            return ""
        }

        var reversedCharacters: [Character] = []
        var usedBytes = 0
        for character in text.reversed() {
            let characterBytes = String(character).utf8.count
            if usedBytes + characterBytes > maxBytes {
                break
            }
            reversedCharacters.append(character)
            usedBytes += characterBytes
        }
        return String(reversedCharacters.reversed())
    }

    private nonisolated static func combinedText(sections: [String]) -> String {
        joinSectionsPreservingWhitespace(
            sections.filter { $0.isEmpty == false }
        )
    }

    private nonisolated static func mergeKey(for entry: ReviewLogEntry) -> GroupKey? {
        guard let groupID = entry.groupID,
              groupID.isEmpty == false
        else {
            return nil
        }

        switch entry.kind {
        case .agentMessage, .command, .commandOutput, .plan, .reasoning, .reasoningSummary, .rawReasoning, .contextCompaction:
            return GroupKey(kind: entry.kind, groupID: groupID)
        case .todoList, .toolCall, .diagnostic, .error, .progress, .event:
            return nil
        }
    }

    private nonisolated static func activeCommandClosingEntries(
        entries: [ReviewLogEntry],
        status: String,
        completedAt: Date
    ) -> [ReviewLogEntry] {
        var latestCommandByGroupID: [String: ReviewLogEntry] = [:]
        var orderedGroupIDs: [String] = []

        for entry in entries where entry.kind == .command {
            guard let groupID = entry.groupID?.nilIfEmpty else {
                continue
            }
            if latestCommandByGroupID[groupID] == nil {
                orderedGroupIDs.append(groupID)
            }
            latestCommandByGroupID[groupID] = entry
        }

        return orderedGroupIDs.compactMap { groupID in
            guard let entry = latestCommandByGroupID[groupID],
                  entry.isActiveCommandEntry
            else {
                return nil
            }
            return entry.closingActiveCommandEntry(status: status, completedAt: completedAt)
        }
    }

    private nonisolated static func isVisibleInRenderedProjection(
        kind: ReviewLogEntry.Kind,
        text: String,
        visibleKinds: Set<ReviewLogEntry.Kind>,
        includeEmptyDiagnostic: Bool
    ) -> Bool {
        guard visibleKinds.contains(kind) else {
            return false
        }
        if kind == .diagnostic {
            return includeEmptyDiagnostic || text.isEmpty == false
        }
        return text.isEmpty == false
    }

    private nonisolated static func joinSectionsPreservingWhitespace(_ sections: [String]) -> String {
        var iterator = sections.makeIterator()
        guard var result = iterator.next() else {
            return ""
        }

        while let next = iterator.next() {
            if next.isEmpty {
                result += "\n\n"
                continue
            }
            if result.hasSuffix("\n\n") {
                result += next
                continue
            }
            if result.hasSuffix("\n") || next.hasPrefix("\n") {
                result += "\n"
            } else {
                result += "\n\n"
            }
            result += next
        }

        return result
    }

    private nonisolated static let displayedLogKinds: Set<ReviewLogEntry.Kind> = [
        .agentMessage,
        .command,
        .commandOutput,
        .plan,
        .todoList,
        .reasoning,
        .reasoningSummary,
        .rawReasoning,
        .toolCall,
        .diagnostic,
        .error,
        .progress,
        .event,
        .contextCompaction,
    ]

    private nonisolated static let reviewOutputKinds: Set<ReviewLogEntry.Kind> = [
        .agentMessage,
        .plan,
        .reasoningSummary,
        .reasoning,
        .rawReasoning,
    ]

    private nonisolated static let activityKinds: Set<ReviewLogEntry.Kind> = [
        .command,
        .commandOutput,
        .toolCall,
        .progress,
        .event,
        .contextCompaction,
    ]

    private nonisolated static let cappedLogKinds: Set<ReviewLogEntry.Kind> = [
        .agentMessage,
        .commandOutput,
        .toolCall,
        .plan,
        .todoList,
        .reasoningSummary,
        .rawReasoning,
        .diagnostic,
        .error,
    ]

    private nonisolated static let prefixTrimmableCappedKinds = cappedLogKinds.subtracting([.rawReasoning, .diagnostic, .error])

    private nonisolated static let logLimitBytes = 256 * 1024
}

private extension ReviewLogEntry {
    var isActiveCommandEntry: Bool {
        guard kind == .command else {
            return false
        }
        let status = metadata?.commandStatus ?? metadata?.status
        return status == "inProgress" || status == "running" || status == "started"
    }

    func closingActiveCommandEntry(status: String, completedAt: Date) -> ReviewLogEntry {
        let startedAt = metadata?.startedAt
        let durationMs = Self.durationMs(startedAt: startedAt, completedAt: completedAt)
            ?? metadata?.durationMs
        return ReviewLogEntry(
            kind: kind,
            groupID: groupID,
            replacesGroup: true,
            text: text,
            metadata: .init(
                sourceType: metadata?.sourceType ?? "commandExecution",
                title: metadata?.title,
                status: status,
                detail: metadata?.detail,
                itemID: metadata?.itemID ?? groupID,
                command: metadata?.command ?? Self.commandText(from: text),
                cwd: metadata?.cwd,
                exitCode: metadata?.exitCode,
                startedAt: startedAt,
                completedAt: completedAt,
                durationMs: durationMs,
                commandActions: metadata?.commandActions,
                commandStatus: status,
                namespace: metadata?.namespace,
                server: metadata?.server,
                tool: metadata?.tool,
                query: metadata?.query,
                path: metadata?.path,
                resultText: metadata?.resultText,
                errorText: metadata?.errorText
            ),
            timestamp: completedAt
        )
    }

    private static func durationMs(startedAt: Date?, completedAt: Date) -> Int? {
        guard let startedAt else {
            return nil
        }
        let milliseconds = completedAt.timeIntervalSince(startedAt) * 1000
        guard milliseconds.isFinite else {
            return nil
        }
        return max(0, Int(milliseconds.rounded()))
    }

    private static func commandText(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$ ") else {
            return trimmed.nilIfEmpty
        }
        return String(trimmed.dropFirst(2)).nilIfEmpty
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
            seed.content.hasTrimmableTimelineText ? seed.id : nil
        case .textDelta(let itemID, _, _, _, _):
            itemID
        case .runStarted, .reviewCompleted, .reviewFailed, .reviewCancelled:
            nil
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
        case .fileChange(let fileChange):
            fileChange.output.isEmpty == false
        case .message,
             .plan,
             .reasoning:
            true
        case .toolCall(let toolCall):
            toolCall.progress?.isEmpty == false || toolCall.result?.isEmpty == false
        case .approval,
             .contextCompaction,
             .search,
             .unknown:
            false
        }
    }
}
