import Foundation
import CodexReview

enum ReviewMonitorCommandOutputDisplayDocument {
    static let toggleAttachmentCharacter = "\u{fffc}"

    static func make(
        from source: ReviewMonitorLogDocument,
        expandedBlockIDs: Set<ReviewMonitorLogBlockID>
    ) -> ReviewMonitorLogDocument {
        guard source.blocks.contains(where: { $0.kind == .command || $0.kind == .commandOutput }) else {
            return source
        }

        let sourceString = source.text as NSString
        var text = ""
        var textUTF16Length = 0
        var blocks: [ReviewMonitorLogBlock] = []
        var styleRuns: [ReviewMonitorLogTextRun] = []
        var decorations: [ReviewMonitorLogDecoration] = []
        var panels: [ReviewMonitorLogCommandOutputPanel] = []
        var cursor = 0

        func appendText(_ segment: String) -> NSRange {
            let range = NSRange(location: textUTF16Length, length: (segment as NSString).length)
            text += segment
            textUTF16Length += range.length
            return range
        }

        let sourceBlocks = source.blocks.sorted(by: { $0.range.location < $1.range.location })
        let commandBlocksByGroupID = firstBlocksByGroupID(in: sourceBlocks, kind: .command)
        let commandOutputBlocksByGroupID = firstBlocksByGroupID(in: sourceBlocks, kind: .commandOutput)
        let commandTextByGroupID = commandOutputCommandTextByGroupID(
            in: sourceBlocks,
            sourceString: sourceString
        )

        for block in sourceBlocks {
            if shouldSkipBlockAndLeadingGap(
                block,
                commandBlocksByGroupID: commandBlocksByGroupID,
                commandOutputBlocksByGroupID: commandOutputBlocksByGroupID
            ) {
                cursor = NSMaxRange(block.range)
                continue
            }

            if cursor < block.range.location {
                let gapRange = NSRange(location: cursor, length: block.range.location - cursor)
                _ = appendText(sourceString.substring(with: gapRange))
            }

            if let panelSource = commandPanelSource(
                for: block,
                commandBlocksByGroupID: commandBlocksByGroupID,
                commandOutputBlocksByGroupID: commandOutputBlocksByGroupID
            ) {
                let blockID = commandPanelBlockID(for: panelSource.anchor)
                let metadata = panelSource.output?.metadata ?? panelSource.command?.metadata ?? panelSource.anchor.metadata
                let isExpanded = expandedBlockIDs.contains(blockID)
                let title = commandOutputTitle(
                    metadata: metadata,
                    commandText: commandOutputCommandText(
                        for: panelSource,
                        sourceString: sourceString,
                        commandTextByGroupID: commandTextByGroupID
                    )
                )
                let commandText = commandOutputCommandText(
                    for: panelSource,
                    sourceString: sourceString,
                    commandTextByGroupID: commandTextByGroupID
                )
                let outputText = commandOutputText(
                    for: panelSource,
                    sourceString: sourceString,
                    isExpanded: isExpanded
                )
                let placeholder = commandOutputPlaceholder(
                    title: title,
                    isExpanded: isExpanded
                )
                let displayRange = appendText(placeholder)
                let controlRange = commandOutputControlRange(in: displayRange, title: title)
                blocks.append(.init(
                    id: blockID,
                    kind: .commandOutput,
                    groupID: panelSource.anchor.groupID,
                    range: displayRange,
                    sourceRange: commandPanelSourceRange(panelSource),
                    metadata: metadata
                ))
                styleRuns.append(.init(range: controlRange, style: .commandOutputControl(isExpanded: isExpanded)))
                decorations.append(.init(
                    blockID: blockID,
                    range: displayRange,
                    style: terminalDecorationStyle(for: panelSource.output ?? panelSource.anchor, in: source)
                ))
                panels.append(.init(
                    blockID: blockID,
                    range: displayRange,
                    commandText: commandText,
                    outputText: outputText,
                    lineCount: commandOutputLineCount(outputText),
                    isExpanded: isExpanded,
                    title: title,
                    exitText: commandOutputResultText(for: panelSource.output ?? panelSource.anchor)
                ))
            } else {
                let displayRange = appendText(sourceString.substring(with: block.range))
                blocks.append(.init(
                    id: block.id,
                    kind: block.kind,
                    groupID: block.groupID,
                    range: displayRange,
                    sourceRange: block.sourceRange,
                    metadata: block.metadata
                ))
                appendPresentationRuns(
                    from: source,
                    sourceRange: block.range,
                    displayRange: displayRange,
                    styleRuns: &styleRuns,
                    decorations: &decorations
                )
            }

            cursor = NSMaxRange(block.range)
        }

        if cursor < source.textUTF16Length {
            let gapRange = NSRange(location: cursor, length: source.textUTF16Length - cursor)
            _ = appendText(sourceString.substring(with: gapRange))
        }

        return .init(
            text: text,
            textUTF16Length: textUTF16Length,
            sourceText: source.sourceText,
            sourceTextUTF16Length: source.sourceTextUTF16Length,
            blocks: blocks,
            styleRuns: styleRuns,
            decorations: decorations,
            commandOutputPanels: panels,
            revision: source.revision,
            lastChange: mappedLastChange(
                source.lastChange,
                sourceBlocks: source.blocks,
                displayBlocks: blocks
            )
        )
    }

    private struct CommandPanelSource {
        var anchor: ReviewMonitorLogBlock
        var command: ReviewMonitorLogBlock?
        var output: ReviewMonitorLogBlock?
    }

    private static func firstBlocksByGroupID(
        in blocks: [ReviewMonitorLogBlock],
        kind: ReviewLogEntry.Kind
    ) -> [String: ReviewMonitorLogBlock] {
        var result: [String: ReviewMonitorLogBlock] = [:]
        for block in blocks where block.kind == kind {
            guard let groupID = block.groupID,
                  result[groupID] == nil
            else {
                continue
            }
            result[groupID] = block
        }
        return result
    }

    private static func commandPanelSource(
        for block: ReviewMonitorLogBlock,
        commandBlocksByGroupID: [String: ReviewMonitorLogBlock],
        commandOutputBlocksByGroupID: [String: ReviewMonitorLogBlock]
    ) -> CommandPanelSource? {
        switch block.kind {
        case .command:
            let output = block.groupID.flatMap { commandOutputBlocksByGroupID[$0] }
            return .init(anchor: block, command: block, output: output)
        case .commandOutput:
            guard let groupID = block.groupID,
                  let command = commandBlocksByGroupID[groupID]
            else {
                return .init(anchor: block, command: nil, output: block)
            }
            let anchor = command.range.location <= block.range.location ? command : block
            guard anchor.id == block.id else {
                return nil
            }
            return .init(anchor: anchor, command: command, output: block)
        case .agentMessage, .plan, .todoList, .reasoning, .reasoningSummary, .rawReasoning,
             .toolCall, .diagnostic, .error, .progress, .event:
            return nil
        }
    }

    private static func shouldSkipBlockAndLeadingGap(
        _ block: ReviewMonitorLogBlock,
        commandBlocksByGroupID: [String: ReviewMonitorLogBlock],
        commandOutputBlocksByGroupID: [String: ReviewMonitorLogBlock]
    ) -> Bool {
        guard let groupID = block.groupID,
              let command = commandBlocksByGroupID[groupID],
              let output = commandOutputBlocksByGroupID[groupID]
        else {
            return false
        }

        let anchor = command.range.location <= output.range.location ? command : output
        return block.id != anchor.id && (block.kind == .command || block.kind == .commandOutput)
    }

    private static func commandPanelBlockID(for block: ReviewMonitorLogBlock) -> ReviewMonitorLogBlockID {
        if let groupID = block.groupID {
            return ReviewMonitorLogBlockID("commandOutput:\(groupID)")
        }
        return block.id
    }

    private static func commandPanelSourceRange(_ source: CommandPanelSource) -> NSRange {
        let ranges = [source.command?.sourceRange, source.output?.sourceRange]
            .compactMap { $0 }
            .filter { $0.length > 0 }
        guard var union = ranges.first else {
            return source.anchor.sourceRange
        }
        for range in ranges.dropFirst() {
            union = NSUnionRange(union, range)
        }
        return union
    }

    private static func appendPresentationRuns(
        from source: ReviewMonitorLogDocument,
        sourceRange: NSRange,
        displayRange: NSRange,
        styleRuns: inout [ReviewMonitorLogTextRun],
        decorations: inout [ReviewMonitorLogDecoration]
    ) {
        for styleRun in source.styleRuns {
            let intersection = NSIntersectionRange(styleRun.range, sourceRange)
            guard intersection.length > 0 else {
                continue
            }
            styleRuns.append(.init(
                range: map(intersection, from: sourceRange, to: displayRange),
                style: styleRun.style
            ))
        }

        for decoration in source.decorations {
            let intersection = NSIntersectionRange(decoration.range, sourceRange)
            guard intersection.length > 0 else {
                continue
            }
            decorations.append(.init(
                blockID: decoration.blockID,
                range: map(intersection, from: sourceRange, to: displayRange),
                style: decoration.style
            ))
        }
    }

    private static func map(_ range: NSRange, from sourceRange: NSRange, to displayRange: NSRange) -> NSRange {
        NSRange(
            location: displayRange.location + range.location - sourceRange.location,
            length: range.length
        )
    }

    private static func commandOutputPlaceholder(
        title: String,
        isExpanded: Bool
    ) -> String {
        let label = "\(toggleAttachmentCharacter)\(title)"
        guard isExpanded else {
            return label
        }
        return "\(label)\n\(toggleAttachmentCharacter)"
    }

    private static func commandOutputControlRange(
        in displayRange: NSRange,
        title: String
    ) -> NSRange {
        NSRange(
            location: displayRange.location,
            length: (toggleAttachmentCharacter + title).utf16.count
        )
    }

    private static func commandOutputLineCount(_ text: String) -> Int {
        guard text.isEmpty == false else {
            return 0
        }
        let rawLineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return text.hasSuffix("\n") ? max(0, rawLineCount - 1) : rawLineCount
    }

    private static func commandOutputText(
        for panelSource: CommandPanelSource,
        sourceString: NSString,
        isExpanded: Bool
    ) -> String {
        guard isExpanded,
              let output = panelSource.output
        else {
            return ""
        }
        return sourceString.substring(with: output.range)
    }

    private static func commandOutputTitle(
        metadata: ReviewLogEntry.Metadata?,
        commandText: String
    ) -> String {
        let trimmedTitle = metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTitle,
           trimmedTitle.isEmpty == false,
           isGenericCommandTitle(trimmedTitle) == false {
            return trimmedTitle
        }

        if commandText.isEmpty == false {
            return "Ran \(commandSummaryName(commandText))"
        }

        return "Command output"
    }

    private static func commandOutputCommandText(
        for panelSource: CommandPanelSource,
        sourceString: NSString,
        commandTextByGroupID: [String: String]
    ) -> String {
        if let groupID = panelSource.anchor.groupID,
           let commandText = commandTextByGroupID[groupID] {
            return commandText
        }

        if let command = panelSource.command {
            let text = commandTextWithoutPrompt(sourceString.substring(with: command.range))
            if text.isEmpty == false {
                return text
            }
        }

        let metadata = panelSource.output?.metadata ?? panelSource.command?.metadata ?? panelSource.anchor.metadata
        let trimmedCommand = metadata?.command?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedCommand, trimmedCommand.isEmpty == false else {
            return ""
        }
        return commandTextWithoutPrompt(trimmedCommand)
    }

    private static func isGenericCommandTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "command" || normalized == "command output"
    }

    private static func commandOutputResultText(for block: ReviewMonitorLogBlock) -> String? {
        if let exitCode = block.metadata?.exitCode {
            return exitCode == 0 ? "Success" : "exit \(exitCode)"
        }

        let normalizedStatus = block.metadata?.status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedStatus == "succeeded" || normalizedStatus == "success" || normalizedStatus == "completed" {
            return "Success"
        }
        if normalizedStatus == "failed" || normalizedStatus == "failure" || normalizedStatus == "errored" {
            if let exitCode = block.metadata?.exitCode {
                return "exit \(exitCode)"
            }
            return "Failed"
        }
        return block.metadata?.status?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func commandSummaryName(_ commandText: String) -> String {
        let components = commandText.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return components.prefix(2).joined(separator: " ")
    }

    private static func commandOutputCommandTextByGroupID(
        in blocks: [ReviewMonitorLogBlock],
        sourceString: NSString
    ) -> [String: String] {
        var commandTextByGroupID: [String: String] = [:]
        for block in blocks where block.kind == .command {
            guard let groupID = block.groupID,
                  commandTextByGroupID[groupID] == nil
            else {
                continue
            }
            let text = commandTextWithoutPrompt(sourceString.substring(with: block.range))
            guard text.isEmpty == false else {
                continue
            }
            commandTextByGroupID[groupID] = text
        }
        return commandTextByGroupID
    }

    private static func commandTextWithoutPrompt(_ text: String) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.hasPrefix("$") else {
            return trimmedText
        }
        return String(trimmedText.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static func terminalDecorationStyle(
        for block: ReviewMonitorLogBlock,
        in source: ReviewMonitorLogDocument
    ) -> ReviewMonitorLogDecorationStyle {
        source.decorations.first { decoration in
            decoration.blockID == block.id &&
                NSIntersectionRange(decoration.range, block.range).length > 0
        }?.style ?? .terminal(tone: .neutral)
    }

    private static func mappedLastChange(
        _ change: ReviewMonitorLogChange,
        sourceBlocks: [ReviewMonitorLogBlock],
        displayBlocks: [ReviewMonitorLogBlock]
    ) -> ReviewMonitorLogChange {
        switch change {
        case .append(let append):
            guard let mappedRange = mappedChangeRange(
                append.range,
                blockID: append.blockID,
                sourceBlocks: sourceBlocks,
                displayBlocks: displayBlocks
            ) else {
                return .reload
            }
            return .append(.init(
                kind: append.kind,
                blockID: append.blockID,
                range: mappedRange,
                text: append.text,
                textUTF16Length: append.textUTF16Length
            ))
        case .replace(let replacement):
            guard let mappedRange = mappedChangeRange(
                replacement.range,
                blockID: replacement.blockID,
                sourceBlocks: sourceBlocks,
                displayBlocks: displayBlocks
            ) else {
                return .reload
            }
            return .replace(.init(
                kind: replacement.kind,
                blockID: replacement.blockID,
                range: mappedRange,
                text: replacement.text,
                textUTF16Length: replacement.textUTF16Length
            ))
        case .reload:
            return .reload
        }
    }

    private static func mappedChangeRange(
        _ range: NSRange,
        blockID: ReviewMonitorLogBlockID,
        sourceBlocks: [ReviewMonitorLogBlock],
        displayBlocks: [ReviewMonitorLogBlock]
    ) -> NSRange? {
        guard let sourceBlock = sourceBlocks.first(where: { $0.id == blockID }),
              sourceBlock.kind != .command,
              sourceBlock.kind != .commandOutput,
              let displayBlock = displayBlocks.first(where: { $0.id == blockID }),
              NSMaxRange(range) <= NSMaxRange(sourceBlock.range)
        else {
            return nil
        }
        let mappedRange = map(range, from: sourceBlock.range, to: displayBlock.range)
        guard NSMaxRange(mappedRange) <= NSMaxRange(displayBlock.range) else {
            return nil
        }
        return mappedRange
    }
}
