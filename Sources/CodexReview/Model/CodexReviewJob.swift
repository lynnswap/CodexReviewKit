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
        var id: ReviewMonitorLogBlockID
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

    private struct MonitorProjectionAccumulator {
        private(set) var document = ReviewMonitorLogDocument()
        private(set) var hasVisibleSections = false
        private(set) var lastBlockIndex: Int?

        mutating func appendBlock(
            _ block: RenderedBlock,
            at blockIndex: Int
        ) -> ReviewMonitorLogAppend {
            let appended: String
            if hasVisibleSections == false {
                appended = block.text
                hasVisibleSections = true
            } else if block.text.isEmpty {
                appended = "\n\n"
            } else if document.text.hasSuffix("\n\n") {
                appended = block.text
            } else if document.text.hasSuffix("\n") || block.text.hasPrefix("\n") {
                appended = "\n" + block.text
            } else {
                appended = "\n\n" + block.text
            }

            let previousLength = document.textUTF16Length
            let suffixLength = CodexReviewJob.utf16Length(appended)
            let blockLength = CodexReviewJob.utf16Length(block.text)
            let blockRange = NSRange(
                location: previousLength + max(0, suffixLength - blockLength),
                length: blockLength
            )

            document.text += appended
            document.textUTF16Length += suffixLength
            document.blocks.append(.init(
                id: block.id,
                kind: block.kind,
                groupID: block.groupID,
                range: blockRange
            ))
            lastBlockIndex = blockIndex
            return .init(
                kind: block.kind,
                blockID: block.id,
                range: blockRange,
                text: appended,
                textUTF16Length: suffixLength
            )
        }

        mutating func appendToCurrentBlock(
            _ block: RenderedBlock,
            at blockIndex: Int,
            delta: String
        ) -> ReviewMonitorLogAppend? {
            guard delta.isEmpty == false,
                  let blockIndexInDocument = document.blocks.lastIndex(where: { $0.id == block.id })
            else {
                return nil
            }

            let previousLength = document.textUTF16Length
            let deltaLength = CodexReviewJob.utf16Length(delta)
            document.text += delta
            document.textUTF16Length += deltaLength
            document.blocks[blockIndexInDocument].range.length += deltaLength
            lastBlockIndex = blockIndex
            return .init(
                kind: block.kind,
                blockID: block.id,
                range: NSRange(location: previousLength, length: deltaLength),
                text: delta,
                textUTF16Length: deltaLength
            )
        }
    }

    private struct LogState {
        var entries: [ReviewLogEntry]
        var blocks: [RenderedBlock]
        var indexByGroup: [GroupKey: Int]
        var logProjection: ProjectionAccumulator
        var reviewMonitorProjection: MonitorProjectionAccumulator
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
            reviewMonitorProjection: MonitorProjectionAccumulator,
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
            self.reviewMonitorProjection = reviewMonitorProjection
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

        var reviewMonitorDocument: ReviewMonitorLogDocument {
            reviewMonitorProjection.document
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
                reviewMonitorProjection: .init(),
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
                    id: CodexReviewJob.blockID(for: entry),
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

        mutating func append(_ entry: ReviewLogEntry) -> ReviewMonitorLogChange? {
            entries.append(entry)

            if let key = CodexReviewJob.mergeKey(for: entry) {
                if let blockIndex = indexByGroup[key] {
                    let oldText = blocks[blockIndex].text
                    if entry.replacesGroup || blockIndex != blocks.indices.last {
                        let previousMonitorDocument = reviewMonitorProjection.document
                        let blockID = blocks[blockIndex].id
                        self = Self.rebuild(entries: entries)
                        if entry.replacesGroup,
                           let replacement = Self.monitorReplacement(
                               previous: previousMonitorDocument,
                               current: reviewMonitorProjection.document,
                               blockID: blockID
                           ) {
                            return .replace(replacement)
                        }
                        return .reload
                    }

                    blocks[blockIndex].text.append(entry.text)
                    let newText = blocks[blockIndex].text
                    return appendTailGroupDelta(
                        block: blocks[blockIndex],
                        oldText: oldText,
                        newText: newText,
                        blockIndex: blockIndex,
                        delta: entry.text
                    ).map(ReviewMonitorLogChange.append)
                }

                indexByGroup[key] = blocks.count
            }

            let blockIndex = blocks.count
            let block = RenderedBlock(
                id: CodexReviewJob.blockID(for: entry),
                kind: entry.kind,
                groupID: entry.groupID,
                text: entry.text
            )
            blocks.append(block)
            return appendTailBlock(block, at: blockIndex).map(ReviewMonitorLogChange.append)
        }

        private mutating func ingestBlock(_ block: RenderedBlock, at index: Int) {
            _ = Self.updateRenderedProjection(
                &logProjection,
                block: block,
                blockIndex: index,
                visibleKinds: CodexReviewJob.displayedLogKinds,
                includeEmptyDiagnostic: true
            )
            _ = Self.updateMonitorProjection(
                &reviewMonitorProjection,
                block: block,
                blockIndex: index,
                visibleKinds: CodexReviewJob.reviewMonitorDisplayedLogKinds,
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
        ) -> ReviewMonitorLogAppend? {
            _ = Self.updateRenderedProjection(
                &logProjection,
                block: block,
                blockIndex: blockIndex,
                visibleKinds: CodexReviewJob.displayedLogKinds,
                includeEmptyDiagnostic: true
            )
            let monitorAppend = Self.updateMonitorProjection(
                &reviewMonitorProjection,
                block: block,
                blockIndex: blockIndex,
                visibleKinds: CodexReviewJob.reviewMonitorDisplayedLogKinds,
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
            return monitorAppend
        }

        private mutating func appendTailGroupDelta(
            block: RenderedBlock,
            oldText: String,
            newText: String,
            blockIndex: Int,
            delta: String
        ) -> ReviewMonitorLogAppend? {
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
            let monitorAppend = Self.updateTailMonitorProjection(
                &reviewMonitorProjection,
                block: block,
                oldText: oldText,
                newText: newText,
                blockIndex: blockIndex,
                delta: delta,
                visibleKinds: CodexReviewJob.reviewMonitorDisplayedLogKinds,
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
            return monitorAppend
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

        private static func updateMonitorProjection(
            _ projection: inout MonitorProjectionAccumulator,
            block: RenderedBlock,
            blockIndex: Int,
            visibleKinds: Set<ReviewLogEntry.Kind>,
            includeEmptyDiagnostic: Bool
        ) -> ReviewMonitorLogAppend? {
            guard CodexReviewJob.isVisibleInRenderedProjection(
                kind: block.kind,
                text: block.text,
                visibleKinds: visibleKinds,
                includeEmptyDiagnostic: includeEmptyDiagnostic
            ) else {
                return nil
            }
            return projection.appendBlock(block, at: blockIndex)
        }

        private static func updateTailMonitorProjection(
            _ projection: inout MonitorProjectionAccumulator,
            block: RenderedBlock,
            oldText: String,
            newText: String,
            blockIndex: Int,
            delta: String,
            visibleKinds: Set<ReviewLogEntry.Kind>,
            includeEmptyDiagnostic: Bool
        ) -> ReviewMonitorLogAppend? {
            let wasVisible = CodexReviewJob.isVisibleInRenderedProjection(
                kind: block.kind,
                text: oldText,
                visibleKinds: visibleKinds,
                includeEmptyDiagnostic: includeEmptyDiagnostic
            )
            let isVisible = CodexReviewJob.isVisibleInRenderedProjection(
                kind: block.kind,
                text: newText,
                visibleKinds: visibleKinds,
                includeEmptyDiagnostic: includeEmptyDiagnostic
            )

            switch (wasVisible, isVisible) {
            case (false, false):
                return nil
            case (false, true):
                return projection.appendBlock(block, at: blockIndex)
            case (true, true):
                return projection.appendToCurrentBlock(block, at: blockIndex, delta: delta)
            case (true, false):
                return nil
            }
        }

        private static func monitorReplacement(
            previous: ReviewMonitorLogDocument,
            current: ReviewMonitorLogDocument,
            blockID: ReviewMonitorLogBlockID
        ) -> ReviewMonitorLogReplacement? {
            guard let previousBlock = previous.blocks.first(where: { $0.id == blockID }),
                  let currentBlock = current.blocks.first(where: { $0.id == blockID }),
                  previousBlock.range.location == currentBlock.range.location,
                  NSMaxRange(currentBlock.range) <= current.textUTF16Length
            else {
                return nil
            }

            let replacementText = (current.text as NSString).substring(with: currentBlock.range)
            return .init(
                kind: currentBlock.kind,
                blockID: currentBlock.id,
                range: previousBlock.range,
                text: replacementText,
                textUTF16Length: currentBlock.range.length
            )
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
    package private(set) var reviewMonitorLogDocument: ReviewMonitorLogDocument
    public private(set) var rawLogText: String
    public private(set) var reviewOutputText: String
    public private(set) var activityLogText: String
    public private(set) var diagnosticText: String
    package private(set) var cappedLogBytes: Int

    package var reviewMonitorRevision: UInt64 {
        reviewMonitorLogDocument.revision
    }

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
        self.reviewMonitorLogDocument = initialState.reviewMonitorDocument
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
        let previousMonitorDocument = reviewMonitorLogDocument
        logState = Self.trimmedLogState(entries: entries)
        syncLogState(
            previousMonitorDocument: previousMonitorDocument,
            preferredMonitorChange: .reload
        )
    }

    package func appendLogEntry(_ entry: ReviewLogEntry) {
        let previousMonitorDocument = reviewMonitorLogDocument
        let preferredMonitorChange = logState.append(entry)
        let didTrim = applyReviewLogLimit()
        syncLogState(
            previousMonitorDocument: previousMonitorDocument,
            preferredMonitorChange: didTrim ? .reload : preferredMonitorChange
        )
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
                timestamp: entry.timestamp
            )
        }
        replaceLogEntries(entries)
    }

    private func syncLogState(
        previousMonitorDocument: ReviewMonitorLogDocument,
        preferredMonitorChange: ReviewMonitorLogChange?
    ) {
        logEntries = logState.entries
        logText = logState.logText
        rawLogText = logState.rawLogText
        reviewOutputText = logState.reviewOutputText
        activityLogText = logState.activityLogText
        diagnosticText = logState.diagnosticText
        cappedLogBytes = logState.cappedBytes

        let currentMonitorDocument = logState.reviewMonitorDocument
        guard let resolvedMonitorDocument = Self.resolveMonitorDocument(
            previous: previousMonitorDocument,
            current: currentMonitorDocument,
            preferredChange: preferredMonitorChange
        ) else {
            return
        }
        reviewMonitorLogDocument = resolvedMonitorDocument
    }

    private nonisolated static func resolveMonitorDocument(
        previous: ReviewMonitorLogDocument,
        current: ReviewMonitorLogDocument,
        preferredChange: ReviewMonitorLogChange?
    ) -> ReviewMonitorLogDocument? {
        guard let preferredChange else {
            return nil
        }

        guard monitorDocumentContentChanged(previous: previous, current: current) else {
            return nil
        }

        var resolved = current
        resolved.revision = previous.revision &+ 1

        switch preferredChange {
        case .append(let preferredAppend)
            where isContiguousMonitorAppend(
                preferredAppend,
                previousUTF16Length: previous.textUTF16Length,
                currentUTF16Length: current.textUTF16Length
            ):
            resolved.lastChange = .append(preferredAppend)
        case .replace(let replacement)
            where isValidMonitorReplacement(
                replacement,
                previousUTF16Length: previous.textUTF16Length,
                currentUTF16Length: current.textUTF16Length
            ):
            resolved.lastChange = .replace(replacement)
        default:
            resolved.lastChange = .reload
        }
        return resolved
    }

    private nonisolated static func monitorDocumentContentChanged(
        previous: ReviewMonitorLogDocument,
        current: ReviewMonitorLogDocument
    ) -> Bool {
        if previous.textUTF16Length != current.textUTF16Length {
            return true
        }
        if previous.blocks != current.blocks {
            return true
        }
        return previous.text != current.text
    }

    private nonisolated static func isContiguousMonitorAppend(
        _ append: ReviewMonitorLogAppend,
        previousUTF16Length: Int,
        currentUTF16Length: Int
    ) -> Bool {
        let appendEnd = previousUTF16Length + append.textUTF16Length
        return append.textUTF16Length > 0 &&
            currentUTF16Length == appendEnd &&
            append.range.location >= previousUTF16Length &&
            NSMaxRange(append.range) <= appendEnd
    }

    private nonisolated static func isValidMonitorReplacement(
        _ replacement: ReviewMonitorLogReplacement,
        previousUTF16Length: Int,
        currentUTF16Length: Int
    ) -> Bool {
        let replacementEnd = replacement.range.location + replacement.textUTF16Length
        return replacement.textUTF16Length >= 0 &&
            NSMaxRange(replacement.range) <= previousUTF16Length &&
            currentUTF16Length == previousUTF16Length - replacement.range.length + replacement.textUTF16Length &&
            replacementEnd <= currentUTF16Length
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

    private nonisolated static func blockID(for entry: ReviewLogEntry) -> ReviewMonitorLogBlockID {
        if let key = mergeKey(for: entry) {
            return ReviewMonitorLogBlockID("\(key.kind.rawValue):\(key.groupID)")
        }
        return ReviewMonitorLogBlockID(entry.id.uuidString)
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

    private nonisolated static func utf16Length(_ text: String) -> Int {
        (text as NSString).length
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

    private nonisolated static let reviewMonitorDisplayedLogKinds = displayedLogKinds.subtracting([.commandOutput])

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
