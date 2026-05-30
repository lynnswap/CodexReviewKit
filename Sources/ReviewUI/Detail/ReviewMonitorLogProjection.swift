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
    var metadata: ReviewLogEntry.Metadata?

    init(
        id: ReviewMonitorLogBlockID,
        kind: ReviewLogEntry.Kind,
        groupID: String?,
        range: NSRange,
        metadata: ReviewLogEntry.Metadata? = nil
    ) {
        self.id = id
        self.kind = kind
        self.groupID = groupID
        self.range = range
        self.metadata = metadata
    }
}

enum ReviewMonitorLogStatusTone: Equatable, Sendable {
    case neutral
    case running
    case success
    case warning
    case failure
}

enum ReviewMonitorLogPlanStatus: String, Equatable, Sendable {
    case pending
    case inProgress
    case completed
    case failed
}

enum ReviewMonitorLogTextStyle: Equatable, Sendable {
    case body
    case heading(level: Int)
    case bullet
    case blockquote
    case strong
    case emphasis
    case link
    case strikethrough
    case inlineCode
    case codeFence
    case markdownSyntax
    case command
    case terminalOutput
    case plan(status: ReviewMonitorLogPlanStatus?)
    case tool
    case diagnostic
    case error
    case event
    case muted
}

struct ReviewMonitorLogTextRun: Equatable, Sendable {
    var range: NSRange
    var style: ReviewMonitorLogTextStyle
}

enum ReviewMonitorLogDecorationStyle: Equatable, Sendable {
    case transcript
    case command(tone: ReviewMonitorLogStatusTone)
    case terminal(tone: ReviewMonitorLogStatusTone)
    case codeBlock
    case plan(tone: ReviewMonitorLogStatusTone)
    case reasoning
    case tool(tone: ReviewMonitorLogStatusTone)
    case diagnostic(tone: ReviewMonitorLogStatusTone)
    case error
    case event
}

struct ReviewMonitorLogDecoration: Equatable, Sendable {
    var blockID: ReviewMonitorLogBlockID
    var range: NSRange
    var style: ReviewMonitorLogDecorationStyle
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
    var styleRuns: [ReviewMonitorLogTextRun]
    var decorations: [ReviewMonitorLogDecoration]
    var revision: UInt64
    var lastChange: ReviewMonitorLogChange

    init(
        text: String = "",
        textUTF16Length: Int? = nil,
        blocks: [ReviewMonitorLogBlock] = [],
        styleRuns: [ReviewMonitorLogTextRun] = [],
        decorations: [ReviewMonitorLogDecoration] = [],
        revision: UInt64 = 0,
        lastChange: ReviewMonitorLogChange = .reload
    ) {
        self.text = text
        self.textUTF16Length = textUTF16Length ?? Self.utf16Length(text)
        self.blocks = blocks
        self.styleRuns = styleRuns
        self.decorations = decorations
        self.revision = revision
        self.lastChange = lastChange
    }

    private static func utf16Length(_ text: String) -> Int {
        (text as NSString).length
    }

    mutating func rebuildPresentation() {
        styleRuns.removeAll(keepingCapacity: true)
        decorations.removeAll(keepingCapacity: true)
        for block in blocks {
            ReviewMonitorLogStyler.appendPresentation(for: block, to: &self)
        }
    }
}

private enum ReviewMonitorLogStyler {
    static func appendPresentation(for block: ReviewMonitorLogBlock, to document: inout ReviewMonitorLogDocument) {
        guard block.range.location >= 0,
              block.range.length >= 0,
              NSMaxRange(block.range) <= document.textUTF16Length
        else {
            return
        }

        if block.range.length > 0 {
            document.styleRuns.append(.init(range: block.range, style: baseTextStyle(for: block.kind)))
            document.decorations.append(.init(
                blockID: block.id,
                range: block.range,
                style: decorationStyle(for: block.kind, metadata: block.metadata)
            ))
        }

        switch block.kind {
        case .agentMessage, .reasoning, .reasoningSummary, .rawReasoning:
            appendMarkdownLiteRuns(
                for: block.range,
                in: document.text,
                blockID: block.id,
                styleRuns: &document.styleRuns,
                decorations: &document.decorations
            )
        case .plan, .todoList:
            appendPlanRuns(for: block.range, in: document.text, to: &document.styleRuns)
        case .command, .commandOutput, .toolCall, .diagnostic, .error, .progress, .event:
            break
        }
    }

    private static func baseTextStyle(for kind: ReviewLogEntry.Kind) -> ReviewMonitorLogTextStyle {
        switch kind {
        case .agentMessage:
            .body
        case .command:
            .body
        case .commandOutput:
            .terminalOutput
        case .plan, .todoList:
            .body
        case .reasoning, .reasoningSummary, .rawReasoning:
            .body
        case .toolCall:
            .body
        case .diagnostic, .error:
            .body
        case .progress, .event:
            .event
        }
    }

    private static func decorationStyle(
        for kind: ReviewLogEntry.Kind,
        metadata: ReviewLogEntry.Metadata?
    ) -> ReviewMonitorLogDecorationStyle {
        let tone = statusTone(for: metadata)
        switch kind {
        case .agentMessage:
            return .transcript
        case .command:
            return .command(tone: tone)
        case .commandOutput:
            return .terminal(tone: tone)
        case .plan, .todoList:
            return .plan(tone: tone)
        case .reasoning, .reasoningSummary, .rawReasoning:
            return .reasoning
        case .toolCall:
            return .tool(tone: tone)
        case .diagnostic:
            return .diagnostic(tone: tone)
        case .error:
            return .error
        case .progress, .event:
            return .event
        }
    }

    private static func statusTone(for metadata: ReviewLogEntry.Metadata?) -> ReviewMonitorLogStatusTone {
        if let exitCode = metadata?.exitCode {
            return exitCode == 0 ? .success : .failure
        }

        let normalized = metadata?.status?
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch normalized {
        case "started", "running", "inprogress":
            return .running
        case "completed", "complete", "succeeded", "success", "passed", "applied":
            return .success
        case "failed", "failure", "errored", "error", "cancelled", "canceled":
            return .failure
        case "warning", "warn", "updated":
            return .warning
        default:
            return .neutral
        }
    }

    private static func appendMarkdownLiteRuns(
        for range: NSRange,
        in text: String,
        blockID: ReviewMonitorLogBlockID,
        styleRuns: inout [ReviewMonitorLogTextRun],
        decorations: inout [ReviewMonitorLogDecoration]
    ) {
        guard range.length > 0 else {
            return
        }

        let nsText = text as NSString
        var inCodeFence = false
        var localRuns: [ReviewMonitorLogTextRun] = []
        var localDecorations: [ReviewMonitorLogDecoration] = []
        var codeFenceRange: NSRange?
        nsText.enumerateSubstrings(
            in: range,
            options: [.byLines, .localized]
        ) { substring, lineRange, _, _ in
            guard let line = substring else {
                return
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                localRuns.append(.init(range: lineRange, style: .codeFence))
                codeFenceRange = codeFenceRange.map { NSUnionRange($0, lineRange) } ?? lineRange
                inCodeFence.toggle()
                if inCodeFence == false, let range = codeFenceRange {
                    localDecorations.append(.init(blockID: blockID, range: range, style: .codeBlock))
                    codeFenceRange = nil
                }
                return
            }
            if inCodeFence {
                localRuns.append(.init(range: lineRange, style: .codeFence))
                codeFenceRange = codeFenceRange.map { NSUnionRange($0, lineRange) } ?? lineRange
                return
            }

            if let level = markdownHeadingLevel(in: trimmed) {
                localRuns.append(.init(range: lineRange, style: .heading(level: level)))
            } else if trimmed.hasPrefix(">") {
                localRuns.append(.init(range: lineRange, style: .blockquote))
                appendLeadingMarkerStyle(marker: ">", in: line, lineRange: lineRange, to: &localRuns)
            } else if isBulletLine(trimmed) {
                localRuns.append(.init(range: lineRange, style: .bullet))
                appendBulletMarkerStyle(line: line, lineRange: lineRange, to: &localRuns)
            }
            if let headingMarkerRange = markdownHeadingMarkerRange(in: line, lineRange: lineRange) {
                localRuns.append(.init(range: headingMarkerRange, style: .markdownSyntax))
            }

            appendInlineMarkdownRuns(line: line, lineRange: lineRange, to: &localRuns)
        }
        if let codeFenceRange {
            localDecorations.append(.init(blockID: blockID, range: codeFenceRange, style: .codeBlock))
        }
        styleRuns.append(contentsOf: localRuns)
        decorations.append(contentsOf: localDecorations)
    }

    private static func appendPlanRuns(
        for range: NSRange,
        in text: String,
        to runs: inout [ReviewMonitorLogTextRun]
    ) {
        guard range.length > 0 else {
            return
        }

        let nsText = text as NSString
        var localRuns: [ReviewMonitorLogTextRun] = []
        nsText.enumerateSubstrings(
            in: range,
            options: [.byLines, .localized]
        ) { substring, lineRange, _, _ in
            guard let line = substring,
                  let status = planStatus(in: line)
            else {
                return
            }
            localRuns.append(.init(range: lineRange, style: .plan(status: status)))
        }
        runs.append(contentsOf: localRuns)
    }

    private static func markdownHeadingLevel(in trimmedLine: String) -> Int? {
        var count = 0
        for character in trimmedLine {
            if character == "#" {
                count += 1
            } else {
                break
            }
        }
        guard (1...6).contains(count) else {
            return nil
        }
        let afterHashes = trimmedLine.dropFirst(count)
        return afterHashes.first == " " ? count : nil
    }

    private static func markdownHeadingMarkerRange(in line: String, lineRange: NSRange) -> NSRange? {
        let nsLine = line as NSString
        var index = 0
        while index < nsLine.length {
            let character = nsLine.character(at: index)
            if character == 32 || character == 9 {
                index += 1
                continue
            }
            break
        }

        var markerLength = 0
        while index + markerLength < nsLine.length,
              nsLine.character(at: index + markerLength) == 35 {
            markerLength += 1
        }
        guard (1...6).contains(markerLength),
              index + markerLength < nsLine.length,
              nsLine.character(at: index + markerLength) == 32
        else {
            return nil
        }
        return NSRange(location: lineRange.location + index, length: markerLength + 1)
    }

    private static func isBulletLine(_ trimmedLine: String) -> Bool {
        if trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") || trimmedLine.hasPrefix("+ ") {
            return true
        }
        let pattern = #"^\d+[.)]\s+"#
        return trimmedLine.range(of: pattern, options: .regularExpression) != nil
    }

    private static func appendLeadingMarkerStyle(
        marker: String,
        in line: String,
        lineRange: NSRange,
        to runs: inout [ReviewMonitorLogTextRun]
    ) {
        let nsLine = line as NSString
        let markerRange = nsLine.range(of: marker)
        guard markerRange.location != NSNotFound else {
            return
        }
        runs.append(.init(
            range: NSRange(location: lineRange.location + markerRange.location, length: markerRange.length),
            style: .markdownSyntax
        ))
    }

    private static func appendBulletMarkerStyle(
        line: String,
        lineRange: NSRange,
        to runs: inout [ReviewMonitorLogTextRun]
    ) {
        let nsLine = line as NSString
        guard let expression = try? NSRegularExpression(pattern: #"^\s*(?:[-*+]|\d+[.)])\s+"#) else {
            return
        }
        let fullRange = NSRange(location: 0, length: nsLine.length)
        guard let match = expression.firstMatch(in: line, options: [], range: fullRange) else {
            return
        }
        runs.append(.init(
            range: NSRange(location: lineRange.location + match.range.location, length: match.range.length),
            style: .markdownSyntax
        ))
    }

    private static func appendInlineMarkdownRuns(
        line: String,
        lineRange: NSRange,
        to runs: inout [ReviewMonitorLogTextRun]
    ) {
        var protectedRanges: [NSRange] = []
        appendDelimitedInlineRuns(
            delimiter: "`",
            style: .inlineCode,
            line: line,
            lineRange: lineRange,
            protectedRanges: &protectedRanges,
            to: &runs
        )
        appendLinkRuns(line: line, lineRange: lineRange, protectedRanges: &protectedRanges, to: &runs)
        appendDelimitedInlineRuns(
            delimiter: "**",
            style: .strong,
            line: line,
            lineRange: lineRange,
            protectedRanges: &protectedRanges,
            to: &runs
        )
        appendDelimitedInlineRuns(
            delimiter: "__",
            style: .strong,
            line: line,
            lineRange: lineRange,
            protectedRanges: &protectedRanges,
            to: &runs
        )
        appendDelimitedInlineRuns(
            delimiter: "~~",
            style: .strikethrough,
            line: line,
            lineRange: lineRange,
            protectedRanges: &protectedRanges,
            to: &runs
        )
        appendDelimitedInlineRuns(
            delimiter: "*",
            style: .emphasis,
            line: line,
            lineRange: lineRange,
            protectedRanges: &protectedRanges,
            to: &runs
        )
        appendDelimitedInlineRuns(
            delimiter: "_",
            style: .emphasis,
            line: line,
            lineRange: lineRange,
            protectedRanges: &protectedRanges,
            to: &runs
        )
    }

    private static func appendDelimitedInlineRuns(
        delimiter: String,
        style: ReviewMonitorLogTextStyle,
        line: String,
        lineRange: NSRange,
        protectedRanges: inout [NSRange],
        to runs: inout [ReviewMonitorLogTextRun]
    ) {
        let nsLine = line as NSString
        var searchLocation = 0
        let delimiterLength = (delimiter as NSString).length
        while searchLocation < nsLine.length {
            let openRange = nsLine.range(
                of: delimiter,
                options: [],
                range: NSRange(location: searchLocation, length: nsLine.length - searchLocation)
            )
            guard openRange.location != NSNotFound else {
                return
            }

            guard isProtected(openRange, protectedRanges) == false,
                  isUsableSingleDelimiter(delimiter, in: nsLine, at: openRange.location)
            else {
                searchLocation = NSMaxRange(openRange)
                continue
            }

            let closeSearchStart = NSMaxRange(openRange)
            guard closeSearchStart < nsLine.length else {
                return
            }
            let closeRange = nsLine.range(
                of: delimiter,
                options: [],
                range: NSRange(location: closeSearchStart, length: nsLine.length - closeSearchStart)
            )
            guard closeRange.location != NSNotFound else {
                return
            }
            guard isProtected(closeRange, protectedRanges) == false,
                  isUsableSingleDelimiter(delimiter, in: nsLine, at: closeRange.location)
            else {
                searchLocation = NSMaxRange(closeRange)
                continue
            }

            let contentRange = NSRange(
                location: NSMaxRange(openRange),
                length: closeRange.location - NSMaxRange(openRange)
            )
            guard contentRange.length > 0 else {
                searchLocation = NSMaxRange(closeRange)
                continue
            }
            let protectedRange = NSRange(
                location: openRange.location,
                length: closeRange.location - openRange.location + delimiterLength
            )
            runs.append(.init(
                range: NSRange(
                    location: lineRange.location + contentRange.location,
                    length: contentRange.length
                ),
                style: style
            ))
            appendSyntaxRun(openRange, lineRange: lineRange, to: &runs)
            appendSyntaxRun(closeRange, lineRange: lineRange, to: &runs)
            protectedRanges.append(protectedRange)
            searchLocation = NSMaxRange(closeRange)
        }
    }

    private static func appendLinkRuns(
        line: String,
        lineRange: NSRange,
        protectedRanges: inout [NSRange],
        to runs: inout [ReviewMonitorLogTextRun]
    ) {
        guard let expression = try? NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^\)\n]+)\)"#) else {
            return
        }
        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        for match in expression.matches(in: line, options: [], range: fullRange) {
            guard match.numberOfRanges >= 3,
                  isProtected(match.range, protectedRanges) == false
            else {
                continue
            }
            let labelRange = match.range(at: 1)
            let urlRange = match.range(at: 2)
            runs.append(.init(
                range: NSRange(location: lineRange.location + labelRange.location, length: labelRange.length),
                style: .link
            ))
            appendSyntaxRun(NSRange(location: match.range.location, length: 1), lineRange: lineRange, to: &runs)
            appendSyntaxRun(NSRange(location: NSMaxRange(labelRange), length: 2), lineRange: lineRange, to: &runs)
            appendSyntaxRun(NSRange(location: NSMaxRange(urlRange), length: 1), lineRange: lineRange, to: &runs)
            protectedRanges.append(match.range)
        }
    }

    private static func appendSyntaxRun(
        _ localRange: NSRange,
        lineRange: NSRange,
        to runs: inout [ReviewMonitorLogTextRun]
    ) {
        guard localRange.length > 0 else {
            return
        }
        runs.append(.init(
            range: NSRange(location: lineRange.location + localRange.location, length: localRange.length),
            style: .markdownSyntax
        ))
    }

    private static func isProtected(_ range: NSRange, _ protectedRanges: [NSRange]) -> Bool {
        protectedRanges.contains { NSIntersectionRange($0, range).length > 0 }
    }

    private static func isUsableSingleDelimiter(_ delimiter: String, in string: NSString, at location: Int) -> Bool {
        guard delimiter == "*" || delimiter == "_" else {
            return true
        }
        let delimiterCharacter = (delimiter as NSString).character(at: 0)
        if location > 0, string.character(at: location - 1) == delimiterCharacter {
            return false
        }
        if location + 1 < string.length, string.character(at: location + 1) == delimiterCharacter {
            return false
        }
        return true
    }

    private static func planStatus(in line: String) -> ReviewMonitorLogPlanStatus? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["),
              let closingIndex = trimmed.firstIndex(of: "]")
        else {
            return nil
        }
        let rawStatus = trimmed[trimmed.index(after: trimmed.startIndex)..<closingIndex]
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch rawStatus {
        case "pending":
            return .pending
        case "inprogress":
            return .inProgress
        case "completed", "complete", "done":
            return .completed
        case "failed", "failure", "error":
            return .failed
        default:
            return nil
        }
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
        var metadata: ReviewLogEntry.Metadata?
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
            let logBlock = ReviewMonitorLogBlock(
                id: block.id,
                kind: block.kind,
                groupID: block.groupID,
                range: blockRange,
                metadata: block.metadata
            )
            document.blocks.append(logBlock)
            ReviewMonitorLogStyler.appendPresentation(for: logBlock, to: &document)
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
            document.blocks[blockIndexInDocument].metadata = block.metadata
            document.rebuildPresentation()
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
                        if let metadata = entry.metadata {
                            state.blocks[index].metadata = metadata
                        }
                        continue
                    }
                    state.indexByGroup[key] = state.blocks.count
                }

                state.blocks.append(.init(
                    id: ReviewMonitorLogProjection.blockID(for: entry),
                    kind: entry.kind,
                    groupID: entry.groupID,
                    text: entry.text,
                    metadata: entry.metadata
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
                    if let metadata = entry.metadata {
                        blocks[blockIndex].metadata = metadata
                    }
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
                text: entry.text,
                metadata: entry.metadata
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
        if previous.styleRuns != current.styleRuns {
            return true
        }
        if previous.decorations != current.decorations {
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
}
