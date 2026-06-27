import Foundation

package struct ReviewLogBuffer {
    package enum TruncationDirection {
        case prefix
        case suffix
    }

    package enum Mutation {
        case reload
        case append
    }

    package struct AppendResult {
        package var entry: ReviewLogEntry
        package var mutation: Mutation
    }

    package struct Snapshot {
        package var entries: [ReviewLogEntry]
        package var logText: String
        package var rawLogText: String
        package var reviewOutputText: String
        package var activityLogText: String
        package var diagnosticText: String
        package var cappedBytes: Int
    }

    package private(set) var entries: [ReviewLogEntry]
    private var projectionState: ReviewLogProjectionState

    package init(entries: [ReviewLogEntry]) {
        let trimmed = Self.trimmedEntriesAndProjection(entries: entries)
        self.entries = trimmed.entries
        self.projectionState = trimmed.projectionState
    }

    package var cappedBytes: Int {
        projectionState.cappedBytes
    }

    package var snapshot: Snapshot {
        Snapshot(
            entries: entries,
            logText: projectionState.logText,
            rawLogText: projectionState.rawLogText,
            reviewOutputText: projectionState.reviewOutputText,
            activityLogText: projectionState.activityLogText,
            diagnosticText: projectionState.diagnosticText,
            cappedBytes: projectionState.cappedBytes
        )
    }

    package mutating func replace(with entries: [ReviewLogEntry]) {
        let trimmed = Self.trimmedEntriesAndProjection(entries: entries)
        self.entries = trimmed.entries
        self.projectionState = trimmed.projectionState
    }

    package mutating func append(_ entry: ReviewLogEntry) -> AppendResult {
        let entry = entry.clampingUnownedRetainedMetadata(maxBytes: Self.limitBytes)
        let supportsIncrementalAppend = projectionState.supportsIncrementalAppend(entry)
        if supportsIncrementalAppend {
            projectionState.append(entry)
        }
        entries.append(entry)
        if supportsIncrementalAppend == false {
            projectionState = ReviewLogProjectionState(entries: entries)
        }
        return AppendResult(
            entry: entry,
            mutation: supportsIncrementalAppend ? .append : .reload
        )
    }

    @discardableResult
    package mutating func applyLimit() -> Bool {
        guard projectionState.cappedBytes > Self.limitBytes else {
            return false
        }

        let trimmed = Self.trimmedEntriesAndProjection(entries: entries)
        guard trimmed.entries != entries else {
            return false
        }
        entries = trimmed.entries
        projectionState = trimmed.projectionState
        return true
    }

    @discardableResult
    package mutating func truncateOrRemoveEntry(
        at index: Int,
        keeping direction: TruncationDirection,
        overflowBytes: Int
    ) -> Bool {
        guard entries.indices.contains(index) else {
            return false
        }

        var updatedEntries = entries
        let entry = updatedEntries[index]
        let retainedBytes = max(0, entry.text.utf8.count - overflowBytes)
        let truncatedText = switch direction {
        case .prefix:
            Self.truncateTextKeepingUTF8Prefix(entry.text, bytes: retainedBytes)
        case .suffix:
            Self.truncateTextKeepingUTF8Suffix(entry.text, bytes: retainedBytes)
        }

        if truncatedText.isEmpty {
            updatedEntries.remove(at: index)
        } else {
            updatedEntries[index] = ReviewLogEntry(
                id: entry.id,
                kind: entry.kind,
                groupID: entry.groupID,
                replacesGroup: entry.replacesGroup,
                text: truncatedText,
                metadata: entry.metadata,
                timestamp: entry.timestamp
            )
        }
        replace(with: updatedEntries)
        return true
    }

    package static func activeCommandClosingEntries(
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

    private struct TrimmedEntriesAndProjection {
        var entries: [ReviewLogEntry]
        var projectionState: ReviewLogProjectionState
    }

    private static func trimmedEntriesAndProjection(
        entries initialEntries: [ReviewLogEntry]
    ) -> TrimmedEntriesAndProjection {
        var entries = initialEntries.map {
            $0.clampingUnownedRetainedMetadata(maxBytes: limitBytes)
        }
        var projectionState = ReviewLogProjectionState(entries: entries)

        while projectionState.cappedBytes > limitBytes {
            let overflowBytes = projectionState.cappedBytes - limitBytes
            guard let trimmedEntries = trimOnce(entries: entries, overflowBytes: overflowBytes) else {
                break
            }
            entries = trimmedEntries
            projectionState = ReviewLogProjectionState(entries: entries)
        }

        return .init(entries: entries, projectionState: projectionState)
    }

    private static func trimOnce(
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

        if let index = entries.firstIndex(where: {
            ReviewLogProjectionState.prefixTrimmableCappedKinds.contains($0.kind)
        }) {
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

    private static func trimWholeEntryPreferringNewest(
        entries: [ReviewLogEntry],
        at index: Int,
        kind: ReviewLogEntry.Kind,
        overflowBytes: Int
    ) -> [ReviewLogEntry] {
        let entry = entries[index]
        let hasNewerEntryOfSameKind = entries.dropFirst(index + 1).contains { $0.kind == kind }
        let hasOtherCappedEntries = entries.contains {
            $0.id != entry.id && ReviewLogProjectionState.cappedLogKinds.contains($0.kind)
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

    private static func trimEntry(
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

        trimmedEntries[index] = ReviewLogEntry(
            id: entry.id,
            kind: entry.kind,
            groupID: entry.groupID,
            replacesGroup: entry.replacesGroup,
            text: truncatedText,
            metadata: entry.metadata?.truncatingRetainedText(from: entry.text, to: truncatedText),
            timestamp: entry.timestamp
        )
        return trimmedEntries
    }

    private static func truncateTextKeepingUTF8Prefix(_ text: String, bytes maxBytes: Int) -> String {
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

    private static func truncateTextKeepingUTF8Suffix(_ text: String, bytes maxBytes: Int) -> String {
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

    package static let limitBytes = 256 * 1024
}

package struct ReviewLogProjectionState {
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

    private var blocks: [RenderedBlock]
    private var indexByGroup: [GroupKey: Int]
    private var logProjection: ProjectionAccumulator
    private var reviewOutputProjection: ProjectionAccumulator
    private var activityProjection: ProjectionAccumulator
    private var errorProjection: ProjectionAccumulator
    private var rawProjection: ProjectionAccumulator
    private var cappedProjection: ProjectionAccumulator

    package init(entries: [ReviewLogEntry]) {
        self = Self.rebuild(entries: entries)
    }

    package var logText: String {
        logProjection.text
    }

    package var rawLogText: String {
        rawProjection.text
    }

    package var reviewOutputText: String {
        reviewOutputProjection.text
    }

    package var activityLogText: String {
        activityProjection.text
    }

    package var diagnosticText: String {
        Self.combinedText(
            sections: [
                errorProjection.text,
                rawProjection.text,
            ]
        )
    }

    package var cappedBytes: Int {
        cappedProjection.text.utf8.count
    }

    package func supportsIncrementalAppend(_ entry: ReviewLogEntry) -> Bool {
        guard entry.replacesGroup == false,
              let key = Self.mergeKey(for: entry),
              let blockIndex = indexByGroup[key]
        else {
            return entry.replacesGroup == false
        }
        return blockIndex == blocks.indices.last
    }

    package mutating func append(_ entry: ReviewLogEntry) {
        if let key = Self.mergeKey(for: entry) {
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

    private init(
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

    private static func rebuild(entries: [ReviewLogEntry]) -> ReviewLogProjectionState {
        var state = ReviewLogProjectionState(
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
            if let key = Self.mergeKey(for: entry) {
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

    private mutating func ingestBlock(_ block: RenderedBlock, at index: Int) {
        _ = Self.updateRenderedProjection(
            &logProjection,
            block: block,
            blockIndex: index,
            visibleKinds: Self.displayedLogKinds,
            includeEmptyDiagnostic: true
        )
        _ = Self.updateRenderedProjection(
            &reviewOutputProjection,
            block: block,
            blockIndex: index,
            visibleKinds: Self.reviewOutputKinds,
            includeEmptyDiagnostic: false
        )
        _ = Self.updateRenderedProjection(
            &activityProjection,
            block: block,
            blockIndex: index,
            visibleKinds: Self.activityKinds,
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
            visibleKinds: Self.cappedLogKinds,
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
            visibleKinds: Self.displayedLogKinds,
            includeEmptyDiagnostic: true
        )
        _ = Self.updateRenderedProjection(
            &reviewOutputProjection,
            block: block,
            blockIndex: blockIndex,
            visibleKinds: Self.reviewOutputKinds,
            includeEmptyDiagnostic: false
        )
        _ = Self.updateRenderedProjection(
            &activityProjection,
            block: block,
            blockIndex: blockIndex,
            visibleKinds: Self.activityKinds,
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
            visibleKinds: Self.cappedLogKinds,
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
            visibleKinds: Self.displayedLogKinds,
            includeEmptyDiagnostic: true
        )
        _ = Self.updateTailProjection(
            &reviewOutputProjection,
            kind: block.kind,
            oldText: oldText,
            newText: newText,
            blockIndex: blockIndex,
            delta: delta,
            visibleKinds: Self.reviewOutputKinds,
            includeEmptyDiagnostic: false
        )
        _ = Self.updateTailProjection(
            &activityProjection,
            kind: block.kind,
            oldText: oldText,
            newText: newText,
            blockIndex: blockIndex,
            delta: delta,
            visibleKinds: Self.activityKinds,
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
            visibleKinds: Self.cappedLogKinds,
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
        let wasVisible = Self.isVisibleInRenderedProjection(
            kind: kind,
            text: oldText,
            visibleKinds: visibleKinds,
            includeEmptyDiagnostic: includeEmptyDiagnostic
        )
        let isVisible = Self.isVisibleInRenderedProjection(
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
        guard Self.isVisibleInRenderedProjection(
            kind: block.kind,
            text: block.text,
            visibleKinds: visibleKinds,
            includeEmptyDiagnostic: includeEmptyDiagnostic
        ) else {
            return nil
        }
        return projection.appendSection(block.text, at: blockIndex)
    }

    private static func combinedText(sections: [String]) -> String {
        joinSectionsPreservingWhitespace(
            sections.filter { $0.isEmpty == false }
        )
    }

    private static func mergeKey(for entry: ReviewLogEntry) -> GroupKey? {
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

    private static func isVisibleInRenderedProjection(
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

    private static func joinSectionsPreservingWhitespace(_ sections: [String]) -> String {
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

    private static let displayedLogKinds: Set<ReviewLogEntry.Kind> = [
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

    private static let reviewOutputKinds: Set<ReviewLogEntry.Kind> = [
        .agentMessage,
        .plan,
        .reasoningSummary,
        .reasoning,
        .rawReasoning,
    ]

    private static let activityKinds: Set<ReviewLogEntry.Kind> = [
        .command,
        .commandOutput,
        .toolCall,
        .progress,
        .event,
        .contextCompaction,
    ]

    package static let cappedLogKinds: Set<ReviewLogEntry.Kind> = [
        .agentMessage,
        .commandOutput,
        .toolCall,
        .plan,
        .todoList,
        .reasoningSummary,
        .rawReasoning,
        .diagnostic,
        .error,
        .progress,
        .event,
    ]

    package static let prefixTrimmableCappedKinds = cappedLogKinds.subtracting([.rawReasoning, .diagnostic, .error])
}

private extension ReviewLogEntry {
    func clampingUnownedRetainedMetadata(maxBytes: Int) -> ReviewLogEntry {
        guard let metadata else {
            return self
        }
        let clampedMetadata = metadata.clampingUnownedRetainedText(entryText: text, maxBytes: maxBytes)
        guard clampedMetadata != metadata else {
            return self
        }
        return ReviewLogEntry(
            id: id,
            kind: kind,
            groupID: groupID,
            replacesGroup: replacesGroup,
            text: text,
            metadata: clampedMetadata,
            timestamp: timestamp
        )
    }

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

private extension ReviewLogEntry.Metadata {
    func clampingUnownedRetainedText(entryText: String, maxBytes: Int) -> Self {
        Self(
            sourceType: sourceType,
            title: title,
            status: status,
            detail: detail,
            itemID: itemID,
            command: command,
            cwd: cwd,
            exitCode: exitCode,
            startedAt: startedAt,
            completedAt: completedAt,
            durationMs: durationMs,
            commandActions: commandActions,
            commandStatus: commandStatus,
            namespace: namespace,
            server: server,
            tool: tool,
            query: query,
            path: path,
            resultText: Self.clampedUnownedRetainedText(resultText, entryText: entryText, maxBytes: maxBytes),
            errorText: Self.clampedUnownedRetainedText(errorText, entryText: entryText, maxBytes: maxBytes)
        )
    }

    func truncatingRetainedText(from originalText: String, to truncatedText: String) -> Self {
        Self(
            sourceType: sourceType,
            title: title,
            status: status,
            detail: detail,
            itemID: itemID,
            command: command,
            cwd: cwd,
            exitCode: exitCode,
            startedAt: startedAt,
            completedAt: completedAt,
            durationMs: durationMs,
            commandActions: commandActions,
            commandStatus: commandStatus,
            namespace: namespace,
            server: server,
            tool: tool,
            query: query,
            path: path,
            resultText: resultText == originalText ? truncatedText : resultText,
            errorText: errorText == originalText ? truncatedText : errorText
        )
    }

    private static func clampedUnownedRetainedText(_ text: String?, entryText: String, maxBytes: Int) -> String? {
        guard let text else {
            return nil
        }
        guard text != entryText,
              text.utf8.count > maxBytes
        else {
            return text
        }
        return nil
    }
}
