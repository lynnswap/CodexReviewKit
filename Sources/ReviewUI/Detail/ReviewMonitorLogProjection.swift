import Foundation
import CodexReview

struct ReviewMonitorLogBlockID: Codable, Hashable, Sendable {
    var rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

struct ReviewMonitorLogBlock: Equatable, Sendable {
    var id: ReviewMonitorLogBlockID
    var kind: ReviewLogEntry.Kind
    var groupID: String?
    var range: NSRange

    init(
        id: ReviewMonitorLogBlockID,
        kind: ReviewLogEntry.Kind,
        groupID: String?,
        range: NSRange
    ) {
        self.id = id
        self.kind = kind
        self.groupID = groupID
        self.range = range
    }
}

struct ReviewMonitorLogAppend: Equatable, Sendable {
    var kind: ReviewLogEntry.Kind
    var blockID: ReviewMonitorLogBlockID
    var range: NSRange
    var text: String
    var textUTF16Length: Int

    init(
        kind: ReviewLogEntry.Kind,
        blockID: ReviewMonitorLogBlockID,
        range: NSRange,
        text: String,
        textUTF16Length: Int? = nil
    ) {
        self.kind = kind
        self.blockID = blockID
        self.range = range
        self.text = text
        self.textUTF16Length = textUTF16Length ?? Self.utf16Length(text)
    }

    private static func utf16Length(_ text: String) -> Int {
        (text as NSString).length
    }
}

struct ReviewMonitorLogReplacement: Equatable, Sendable {
    var kind: ReviewLogEntry.Kind
    var blockID: ReviewMonitorLogBlockID
    var range: NSRange
    var text: String
    var textUTF16Length: Int

    init(
        kind: ReviewLogEntry.Kind,
        blockID: ReviewMonitorLogBlockID,
        range: NSRange,
        text: String,
        textUTF16Length: Int? = nil
    ) {
        self.kind = kind
        self.blockID = blockID
        self.range = range
        self.text = text
        self.textUTF16Length = textUTF16Length ?? Self.utf16Length(text)
    }

    private static func utf16Length(_ text: String) -> Int {
        (text as NSString).length
    }
}

enum ReviewMonitorLogChange: Equatable, Sendable {
    case reload
    case append(ReviewMonitorLogAppend)
    case replace(ReviewMonitorLogReplacement)
}

struct ReviewMonitorLogDocument: Equatable, Sendable {
    var text: String
    var textUTF16Length: Int
    var blocks: [ReviewMonitorLogBlock]
    var revision: UInt64
    var lastChange: ReviewMonitorLogChange

    init(
        text: String = "",
        textUTF16Length: Int? = nil,
        blocks: [ReviewMonitorLogBlock] = [],
        revision: UInt64 = 0,
        lastChange: ReviewMonitorLogChange = .reload
    ) {
        self.text = text
        self.textUTF16Length = textUTF16Length ?? Self.utf16Length(text)
        self.blocks = blocks
        self.revision = revision
        self.lastChange = lastChange
    }

    private static func utf16Length(_ text: String) -> Int {
        (text as NSString).length
    }
}

struct ReviewMonitorLogProjection {
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

    private struct Accumulator {
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
            let suffixLength = ReviewMonitorLogProjection.utf16Length(appended)
            let blockLength = ReviewMonitorLogProjection.utf16Length(block.text)
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
            let deltaLength = ReviewMonitorLogProjection.utf16Length(delta)
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

    private struct State {
        var entries: [ReviewLogEntry]
        var blocks: [RenderedBlock]
        var indexByGroup: [GroupKey: Int]
        var projection: Accumulator

        init(entries: [ReviewLogEntry]) {
            self = Self.rebuild(entries: entries)
        }

        var document: ReviewMonitorLogDocument {
            projection.document
        }

        static func rebuild(entries: [ReviewLogEntry]) -> State {
            var state = State(
                entries: entries,
                blocks: [],
                indexByGroup: [:],
                projection: .init()
            )

            for entry in entries {
                if let key = ReviewMonitorLogProjection.mergeKey(for: entry) {
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
                    id: ReviewMonitorLogProjection.blockID(for: entry),
                    kind: entry.kind,
                    groupID: entry.groupID,
                    text: entry.text
                ))
            }

            for (index, block) in state.blocks.enumerated() {
                _ = state.appendBlock(block, at: index)
            }
            return state
        }

        private init(
            entries: [ReviewLogEntry],
            blocks: [RenderedBlock],
            indexByGroup: [GroupKey: Int],
            projection: Accumulator
        ) {
            self.entries = entries
            self.blocks = blocks
            self.indexByGroup = indexByGroup
            self.projection = projection
        }

        mutating func append(
            _ entry: ReviewLogEntry,
            previousDocument: ReviewMonitorLogDocument
        ) -> ReviewMonitorLogChange? {
            entries.append(entry)

            if let key = ReviewMonitorLogProjection.mergeKey(for: entry) {
                if let blockIndex = indexByGroup[key] {
                    let oldText = blocks[blockIndex].text
                    if entry.replacesGroup || blockIndex != blocks.indices.last {
                        let blockID = blocks[blockIndex].id
                        self = Self.rebuild(entries: entries)
                        if entry.replacesGroup,
                           let replacement = Self.replacement(
                               previous: previousDocument,
                               current: projection.document,
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
                id: ReviewMonitorLogProjection.blockID(for: entry),
                kind: entry.kind,
                groupID: entry.groupID,
                text: entry.text
            )
            blocks.append(block)
            return appendBlock(block, at: blockIndex).map(ReviewMonitorLogChange.append)
        }

        private mutating func appendBlock(
            _ block: RenderedBlock,
            at blockIndex: Int
        ) -> ReviewMonitorLogAppend? {
            guard ReviewMonitorLogProjection.isVisible(
                kind: block.kind,
                text: block.text
            ) else {
                return nil
            }
            return projection.appendBlock(block, at: blockIndex)
        }

        private mutating func appendTailGroupDelta(
            block: RenderedBlock,
            oldText: String,
            newText: String,
            blockIndex: Int,
            delta: String
        ) -> ReviewMonitorLogAppend? {
            let wasVisible = ReviewMonitorLogProjection.isVisible(
                kind: block.kind,
                text: oldText
            )
            let isVisible = ReviewMonitorLogProjection.isVisible(
                kind: block.kind,
                text: newText
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

        private static func replacement(
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

    private var state = State(entries: [])
    private var document = ReviewMonitorLogDocument()

    mutating func render(entries: [ReviewLogEntry]) -> ReviewMonitorLogDocument {
        guard entries != state.entries else {
            return document
        }

        let previousDocument = document
        let preferredChange: ReviewMonitorLogChange?
        if entries.count == state.entries.count + 1,
           entries.dropLast().elementsEqual(state.entries),
           let entry = entries.last {
            preferredChange = state.append(entry, previousDocument: previousDocument)
        } else {
            state = State.rebuild(entries: entries)
            preferredChange = .reload
        }

        if let resolved = Self.resolveDocument(
            previous: previousDocument,
            current: state.document,
            preferredChange: preferredChange
        ) {
            document = resolved
        }
        return document
    }

    private static func resolveDocument(
        previous: ReviewMonitorLogDocument,
        current: ReviewMonitorLogDocument,
        preferredChange: ReviewMonitorLogChange?
    ) -> ReviewMonitorLogDocument? {
        guard let preferredChange else {
            return nil
        }

        guard contentChanged(previous: previous, current: current) else {
            return nil
        }

        var resolved = current
        resolved.revision = previous.revision &+ 1

        switch preferredChange {
        case .append(let append)
            where isContiguousAppend(
                append,
                previousUTF16Length: previous.textUTF16Length,
                currentUTF16Length: current.textUTF16Length
            ):
            resolved.lastChange = .append(append)
        case .replace(let replacement)
            where isValidReplacement(
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

    private static func contentChanged(
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

    private static func isContiguousAppend(
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

    private static func isValidReplacement(
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

    private static func blockID(for entry: ReviewLogEntry) -> ReviewMonitorLogBlockID {
        if let key = mergeKey(for: entry) {
            return ReviewMonitorLogBlockID("\(key.kind.rawValue):\(key.groupID)")
        }
        return ReviewMonitorLogBlockID(entry.id.uuidString)
    }

    private static func mergeKey(for entry: ReviewLogEntry) -> GroupKey? {
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

    private static func isVisible(kind: ReviewLogEntry.Kind, text: String) -> Bool {
        guard displayedKinds.contains(kind) else {
            return false
        }
        if kind == .diagnostic {
            return true
        }
        return text.isEmpty == false
    }

    private static func utf16Length(_ text: String) -> Int {
        (text as NSString).length
    }

    private static let displayedKinds: Set<ReviewLogEntry.Kind> = [
        .agentMessage,
        .command,
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
}
