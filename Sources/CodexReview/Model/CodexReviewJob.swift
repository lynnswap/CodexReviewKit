import Foundation
import Observation

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
        var entries: [ReviewLogEntry]
        var blocks: [RenderedBlock]
        var indexByGroup: [GroupKey: Int]
        var logProjection: ProjectionAccumulator
        var reviewOutputProjection: ProjectionAccumulator
        var activityProjection: ProjectionAccumulator
        var errorProjection: ProjectionAccumulator
        var rawProjection: ProjectionAccumulator
        var cappedProjection: ProjectionAccumulator

        init(
            entries: [ReviewLogEntry],
            blocks: [RenderedBlock],
            indexByGroup: [GroupKey: Int],
            logProjection: ProjectionAccumulator,
            reviewOutputProjection: ProjectionAccumulator,
            activityProjection: ProjectionAccumulator,
            errorProjection: ProjectionAccumulator,
            rawProjection: ProjectionAccumulator,
            cappedProjection: ProjectionAccumulator
        ) {
            self.entries = entries
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
                entries: entries,
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

        mutating func append(_ entry: ReviewLogEntry) {
            entries.append(entry)

            if let key = CodexReviewJob.mergeKey(for: entry) {
                if let blockIndex = indexByGroup[key] {
                    let oldText = blocks[blockIndex].text
                    if entry.replacesGroup || blockIndex != blocks.indices.last {
                        self = Self.rebuild(entries: entries)
                        return
                    }

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

    @ObservationIgnored
    private var logState: LogState

    public nonisolated let id: String
    public let sessionID: String
    public let cwd: String
    public package(set) var sortOrder: Double
    public var targetSummary: String
    public var core: ReviewJobCore
    public var cancellationRequested: Bool
    @ObservationIgnored
    package var agentMessagesByItemID: [String: String]
    @ObservationIgnored
    package var completedAgentMessageItemIDs: Set<String>
    public private(set) var logEntries: [ReviewLogEntry]
    public private(set) var logText: String
    public private(set) var rawLogText: String
    public private(set) var reviewOutputText: String
    public private(set) var activityLogText: String
    public private(set) var diagnosticText: String
    package private(set) var cappedLogBytes: Int

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
        self.sessionID = sessionID
        self.cwd = cwd
        self.sortOrder = sortOrder
        self.targetSummary = targetSummary
        self.core = core
        self.cancellationRequested = cancellationRequested
        self.agentMessagesByItemID = [:]
        self.completedAgentMessageItemIDs = []
        self.logState = initialState
        self.logEntries = initialState.entries
        self.logText = initialState.logText
        self.rawLogText = initialState.rawLogText
        self.reviewOutputText = initialState.reviewOutputText
        self.activityLogText = initialState.activityLogText
        self.diagnosticText = initialState.diagnosticText
        self.cappedLogBytes = initialState.cappedBytes
    }

    public nonisolated static func == (lhs: CodexReviewJob, rhs: CodexReviewJob) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    package func replaceLogEntries(_ entries: [ReviewLogEntry]) {
        logState = Self.trimmedLogState(entries: entries)
        syncLogState()
    }

    package func appendLogEntry(_ entry: ReviewLogEntry) {
        logState.append(entry)
        _ = applyReviewLogLimit()
        syncLogState()
    }

    @discardableResult
    package func applyReviewLogLimit() -> Bool {
        guard logState.cappedBytes > Self.logLimitBytes else {
            return false
        }

        let trimmedState = Self.trimmedLogState(from: logState)
        guard trimmedState.entries != logState.entries else {
            return false
        }
        logState = trimmedState
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

    private func syncLogState() {
        logEntries = logState.entries
        logText = logState.logText
        rawLogText = logState.rawLogText
        reviewOutputText = logState.reviewOutputText
        activityLogText = logState.activityLogText
        diagnosticText = logState.diagnosticText
        cappedLogBytes = logState.cappedBytes
    }

    private nonisolated static func trimmedLogState(entries: [ReviewLogEntry]) -> LogState {
        trimmedLogState(from: LogState(entries: entries))
    }

    private nonisolated static func trimmedLogState(from initialState: LogState) -> LogState {
        var state = initialState

        while state.cappedBytes > logLimitBytes {
            let overflowBytes = state.cappedBytes - logLimitBytes
            guard let trimmedEntries = trimOnce(entries: state.entries, overflowBytes: overflowBytes) else {
                break
            }
            state = LogState(entries: trimmedEntries)
        }

        return state
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
                direction: .prefix
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
        case .agentMessage, .commandOutput, .plan, .reasoning, .reasoningSummary, .rawReasoning:
            return GroupKey(kind: entry.kind, groupID: groupID)
        case .command, .todoList, .toolCall, .diagnostic, .error, .progress, .event:
            return nil
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
    ]

    private nonisolated static let cappedLogKinds: Set<ReviewLogEntry.Kind> = [
        .agentMessage,
        .commandOutput,
        .toolCall,
        .plan,
        .reasoningSummary,
        .rawReasoning,
        .diagnostic,
        .error,
    ]

    private nonisolated static let prefixTrimmableCappedKinds = cappedLogKinds.subtracting([.rawReasoning, .diagnostic, .error])

    private nonisolated static let logLimitBytes = 256 * 1024
}
