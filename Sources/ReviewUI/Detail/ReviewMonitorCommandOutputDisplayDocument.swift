import Foundation

enum ReviewMonitorCommandOutputDisplayDocument {
    static let toggleAttachmentCharacter = "\u{fffc}"

    static func make(
        from source: ReviewMonitorLogDocument,
        expandedBlockIDs: Set<ReviewMonitorLogBlockID>
    ) -> ReviewMonitorLogDocument {
        guard source.blocks.contains(where: { $0.kind == .commandOutput }) else {
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
        let commandOutputGroupIDs = Set(sourceBlocks.compactMap { block in
            block.kind == .commandOutput ? block.groupID : nil
        })
        let commandTextByGroupID = commandOutputCommandTextByGroupID(
            in: sourceBlocks,
            sourceString: sourceString,
            commandOutputGroupIDs: commandOutputGroupIDs
        )

        var shouldSuppressGapAfterSkippedCommand = false
        for block in sourceBlocks {
            if cursor < block.range.location {
                if shouldSuppressGapAfterSkippedCommand {
                    cursor = block.range.location
                    shouldSuppressGapAfterSkippedCommand = false
                } else {
                    let gapRange = NSRange(location: cursor, length: block.range.location - cursor)
                    _ = appendText(sourceString.substring(with: gapRange))
                }
            } else if shouldSuppressGapAfterSkippedCommand {
                shouldSuppressGapAfterSkippedCommand = false
            }

            if block.kind == .command,
               let groupID = block.groupID,
               commandOutputGroupIDs.contains(groupID) {
                shouldSuppressGapAfterSkippedCommand = true
                cursor = NSMaxRange(block.range)
                continue
            }

            if block.kind == .commandOutput {
                let isExpanded = expandedBlockIDs.contains(block.id)
                let title = commandOutputTitle(
                    for: block,
                    commandTextByGroupID: commandTextByGroupID
                )
                let commandText = commandOutputCommandText(
                    for: block,
                    commandTextByGroupID: commandTextByGroupID
                )
                let placeholder = commandOutputPlaceholder(
                    title: title,
                    isExpanded: isExpanded
                )
                let displayRange = appendText(placeholder)
                blocks.append(.init(
                    id: block.id,
                    kind: block.kind,
                    groupID: block.groupID,
                    range: displayRange,
                    sourceRange: block.sourceRange,
                    metadata: block.metadata
                ))
                styleRuns.append(.init(range: displayRange, style: .commandOutputControl(isExpanded: isExpanded)))
                decorations.append(.init(
                    blockID: block.id,
                    range: displayRange,
                    style: terminalDecorationStyle(for: block, in: source)
                ))
                let outputText = commandOutputText(
                    for: block,
                    sourceString: sourceString,
                    isExpanded: isExpanded
                )
                panels.append(.init(
                    blockID: block.id,
                    range: displayRange,
                    commandText: commandText,
                    outputText: outputText,
                    lineCount: commandOutputLineCount(outputText),
                    isExpanded: isExpanded,
                    title: title,
                    exitText: commandOutputResultText(for: block)
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

    private static func commandOutputLineCount(_ text: String) -> Int {
        guard text.isEmpty == false else {
            return 0
        }
        let rawLineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return text.hasSuffix("\n") ? max(0, rawLineCount - 1) : rawLineCount
    }

    private static func commandOutputText(
        for block: ReviewMonitorLogBlock,
        sourceString: NSString,
        isExpanded: Bool
    ) -> String {
        guard isExpanded else {
            return ""
        }
        return sourceString.substring(with: block.range)
    }

    private static func commandOutputTitle(
        for block: ReviewMonitorLogBlock,
        commandTextByGroupID: [String: String]
    ) -> String {
        let trimmedTitle = block.metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTitle, trimmedTitle.isEmpty == false {
            return trimmedTitle
        }

        let commandText = commandOutputCommandText(
            for: block,
            commandTextByGroupID: commandTextByGroupID
        )
        if commandText.isEmpty == false {
            return "Ran \(commandSummaryName(commandText))"
        }

        return "Command output"
    }

    private static func commandOutputCommandText(
        for block: ReviewMonitorLogBlock,
        commandTextByGroupID: [String: String]
    ) -> String {
        if let groupID = block.groupID,
           let commandText = commandTextByGroupID[groupID] {
            return commandText
        }

        let trimmedCommand = block.metadata?.command?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedCommand, trimmedCommand.isEmpty == false else {
            return ""
        }
        return commandTextWithoutPrompt(trimmedCommand)
    }

    private static func commandOutputResultText(for block: ReviewMonitorLogBlock) -> String? {
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
        if let exitCode = block.metadata?.exitCode {
            return "exit \(exitCode)"
        }
        return block.metadata?.status?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func commandSummaryName(_ commandText: String) -> String {
        let components = commandText.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return components.prefix(2).joined(separator: " ")
    }

    private static func commandOutputCommandTextByGroupID(
        in blocks: [ReviewMonitorLogBlock],
        sourceString: NSString,
        commandOutputGroupIDs: Set<String>
    ) -> [String: String] {
        var commandTextByGroupID: [String: String] = [:]
        for block in blocks where block.kind == .command {
            guard let groupID = block.groupID,
                  commandOutputGroupIDs.contains(groupID),
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
