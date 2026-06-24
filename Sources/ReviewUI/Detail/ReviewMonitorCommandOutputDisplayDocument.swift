import Foundation
import CodexReviewKit

enum ReviewMonitorCommandOutputDisplayDocument {
    static let toggleAttachmentCharacter = "\u{fffc}"

    static func userVisibleText(from displayText: String) -> String {
        var visibleText = ""
        var index = displayText.startIndex
        while index < displayText.endIndex {
            let character = displayText[index]
            let nextIndex = displayText.index(after: index)

            if character == "\n",
               nextIndex < displayText.endIndex,
               String(displayText[nextIndex]) == toggleAttachmentCharacter {
                let afterAttachmentIndex = displayText.index(after: nextIndex)
                if afterAttachmentIndex == displayText.endIndex ||
                    displayText[afterAttachmentIndex] == "\n" ||
                    String(displayText[afterAttachmentIndex]) == toggleAttachmentCharacter {
                    index = afterAttachmentIndex
                    continue
                }
            }

            if String(character) == toggleAttachmentCharacter {
                index = nextIndex
                continue
            }

            visibleText.append(character)
            index = nextIndex
        }
        return visibleText
    }

    static func make(
        from source: ReviewMonitorLog.Document,
        expandedBlockIDs: Set<ReviewMonitorLog.BlockID> = [],
        previousDisplay: ReviewMonitorLog.Document? = nil,
        currentDate: Date = Date()
    ) -> ReviewMonitorLog.Document {
        guard source.blocks.contains(where: { $0.kind == .command || $0.kind == .commandOutput }) else {
            return source
        }

        let sourceString = source.text as NSString
        var text = ""
        var textUTF16Length = 0
        var blocks: [ReviewMonitorLog.Block] = []
        var styleRuns: [ReviewMonitorLog.TextRun] = []
        var decorations: [ReviewMonitorLog.Decoration] = []
        var panels: [ReviewMonitorLog.CommandOutputPanel] = []
        var usedPanelBlockIDs: Set<ReviewMonitorLog.BlockID> = []
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
                let blockID = uniqueCommandPanelBlockID(
                    for: panelSource.anchor,
                    usedBlockIDs: &usedPanelBlockIDs
                )
                let isExpanded = expandedBlockIDs.contains(blockID)
                let metadata = commandPanelMetadata(for: panelSource)
                let commandText = commandOutputCommandText(
                    for: panelSource,
                    sourceString: sourceString,
                    commandTextByGroupID: commandTextByGroupID
                )
                let hasOutput = panelSource.output != nil
                let isActive = commandOutputIsActive(metadata, hasOutput: hasOutput)
                let title = commandOutputTitle(
                    metadata: metadata,
                    commandText: commandText,
                    isActive: isActive,
                    currentDate: currentDate
                )
                let outputText = commandOutputText(
                    for: panelSource,
                    sourceString: sourceString,
                    isExpanded: isExpanded
                )
                let placeholder = commandOutputPlaceholder(
                    title: title,
                    includesActiveTimer: isActive && metadata?.startedAt != nil,
                    includesPanelAttachment: isExpanded
                )
                let displayRange = appendText(placeholder)
                let controlRange = commandOutputControlRange(
                    in: displayRange,
                    title: title,
                    includesActiveTimer: isActive && metadata?.startedAt != nil
                )
                blocks.append(.init(
                    id: blockID,
                    kind: .commandOutput,
                    groupID: panelSource.anchor.groupID,
                    range: displayRange,
                    sourceRange: commandPanelSourceRange(panelSource),
                    metadata: metadata
                ))
                styleRuns.append(.init(
                    range: controlRange,
                    style: .commandOutputControl(keepsTrailingContent: isActive && metadata?.startedAt != nil)
                ))
                panels.append(.init(
                    blockID: blockID,
                    range: displayRange,
                    commandText: commandText,
                    outputText: outputText,
                    outputSourceRange: panelSource.output?.sourceRange,
                    lineCount: commandOutputLineCount(
                        for: panelSource,
                        sourceString: sourceString,
                        isExpanded: isExpanded
                    ),
                    isExpanded: isExpanded,
                    isActive: isActive,
                    startedAt: metadata?.startedAt,
                    title: title,
                    exitText: commandOutputResultText(for: metadata)
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
                displayBlocks: blocks,
                previousDisplay: previousDisplay,
                displayText: text
            )
        )
    }

    private struct CommandPanelSource {
        var anchor: ReviewMonitorLog.Block
        var command: ReviewMonitorLog.Block?
        var output: ReviewMonitorLog.Block?
    }

    private static func commandPanelMetadata(for source: CommandPanelSource) -> ReviewLogEntry.Metadata? {
        mergeCommandMetadata(
            primary: source.output?.metadata,
            fallback: source.command?.metadata ?? source.anchor.metadata
        )
    }

    private static func mergeCommandMetadata(
        primary: ReviewLogEntry.Metadata?,
        fallback: ReviewLogEntry.Metadata?
    ) -> ReviewLogEntry.Metadata? {
        guard let primary else {
            return fallback
        }
        guard let fallback else {
            return primary
        }

        let durationMs = primary.durationMs ?? fallback.durationMs ?? commandDurationMs(
            startedAt: primary.startedAt ?? fallback.startedAt,
            completedAt: primary.completedAt ?? fallback.completedAt
        )
        let title = primary.title ?? fallback.title
        let status = primary.status ?? fallback.status
        let detail = primary.detail ?? fallback.detail
        let itemID = primary.itemID ?? fallback.itemID
        let command = primary.command ?? fallback.command
        let cwd = primary.cwd ?? fallback.cwd
        let exitCode = primary.exitCode ?? fallback.exitCode
        let startedAt = primary.startedAt ?? fallback.startedAt
        let completedAt = primary.completedAt ?? fallback.completedAt
        let commandActions = primary.commandActions ?? fallback.commandActions
        let commandStatus = primary.commandStatus ?? fallback.commandStatus
        let namespace = primary.namespace ?? fallback.namespace
        let server = primary.server ?? fallback.server
        let tool = primary.tool ?? fallback.tool
        let query = primary.query ?? fallback.query
        let path = primary.path ?? fallback.path
        let resultText = primary.resultText ?? fallback.resultText
        let errorText = primary.errorText ?? fallback.errorText

        return ReviewLogEntry.Metadata(
            sourceType: primary.sourceType,
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
            resultText: resultText,
            errorText: errorText
        )
    }

    private static func firstBlocksByGroupID(
        in blocks: [ReviewMonitorLog.Block],
        kind: ReviewLogEntry.Kind
    ) -> [String: ReviewMonitorLog.Block] {
        var result: [String: ReviewMonitorLog.Block] = [:]
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
        for block: ReviewMonitorLog.Block,
        commandBlocksByGroupID: [String: ReviewMonitorLog.Block],
        commandOutputBlocksByGroupID: [String: ReviewMonitorLog.Block]
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
             .toolCall, .diagnostic, .error, .progress, .event, .contextCompaction:
            return nil
        }
    }

    private static func shouldSkipBlockAndLeadingGap(
        _ block: ReviewMonitorLog.Block,
        commandBlocksByGroupID: [String: ReviewMonitorLog.Block],
        commandOutputBlocksByGroupID: [String: ReviewMonitorLog.Block]
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

    private static func commandPanelBlockID(for block: ReviewMonitorLog.Block) -> ReviewMonitorLog.BlockID {
        if let groupID = block.groupID {
            return ReviewMonitorLog.BlockID("commandOutput:\(groupID)")
        }
        return block.id
    }

    private static func uniqueCommandPanelBlockID(
        for block: ReviewMonitorLog.Block,
        usedBlockIDs: inout Set<ReviewMonitorLog.BlockID>
    ) -> ReviewMonitorLog.BlockID {
        let preferredBlockID = commandPanelBlockID(for: block)
        if usedBlockIDs.insert(preferredBlockID).inserted {
            return preferredBlockID
        }

        if usedBlockIDs.insert(block.id).inserted {
            return block.id
        }

        var suffix = 2
        while true {
            let candidate = ReviewMonitorLog.BlockID("\(block.id.rawValue):\(suffix)")
            if usedBlockIDs.insert(candidate).inserted {
                return candidate
            }
            suffix += 1
        }
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
        from source: ReviewMonitorLog.Document,
        sourceRange: NSRange,
        displayRange: NSRange,
        styleRuns: inout [ReviewMonitorLog.TextRun],
        decorations: inout [ReviewMonitorLog.Decoration]
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
        includesActiveTimer: Bool,
        includesPanelAttachment: Bool
    ) -> String {
        let label = "\(toggleAttachmentCharacter)\(title)\(includesActiveTimer ? toggleAttachmentCharacter : "")"
        return includesPanelAttachment ? "\(label)\n\(toggleAttachmentCharacter)" : label
    }

    private static func commandOutputControlRange(
        in displayRange: NSRange,
        title: String,
        includesActiveTimer: Bool
    ) -> NSRange {
        NSRange(
            location: displayRange.location,
            length: (
                toggleAttachmentCharacter
                    + title
                    + (includesActiveTimer ? toggleAttachmentCharacter : "")
            ).utf16.count
        )
    }

    private static func commandOutputLineCount(
        for panelSource: CommandPanelSource,
        sourceString: NSString,
        isExpanded: Bool
    ) -> Int {
        guard isExpanded else {
            return 0
        }
        guard let output = panelSource.output else {
            return 0
        }
        return ReviewMonitorLog.LineCounter.lineCount(in: sourceString, range: output.range)
    }

    private static func commandOutputText(
        for panelSource: CommandPanelSource,
        sourceString: NSString,
        isExpanded: Bool
    ) -> String {
        guard isExpanded else {
            return ""
        }
        guard let output = panelSource.output else {
            return ""
        }
        return sourceString.substring(with: output.range)
    }

    private static func commandOutputTitle(
        metadata: ReviewLogEntry.Metadata?,
        commandText: String,
        isActive: Bool,
        currentDate: Date
    ) -> String {
        if hasStructuredCommandMetadata(metadata) {
            let title = commandActionTitle(
                metadata: metadata,
                commandText: commandText,
                isActive: isActive
            )
            ?? commandRunTitle(
                commandText: commandText,
                metadata: metadata,
                isActive: isActive
            )
            if isActive == false,
               let durationText = commandDurationText(
                metadata: metadata,
                isActive: isActive,
                currentDate: currentDate
            ) {
                return "\(title) for \(durationText)"
            }
            return title
        }

        let trimmedTitle = metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTitle,
           trimmedTitle.isEmpty == false,
           isGenericCommandTitle(trimmedTitle) == false {
            return trimmedTitle
        }
        if commandText.isEmpty == false {
            return "\(isActive ? "Running" : "Ran") \(commandSummaryName(commandText))"
        }

        return "Command output"
    }

    private static func hasStructuredCommandMetadata(_ metadata: ReviewLogEntry.Metadata?) -> Bool {
        guard let metadata else {
            return false
        }
        return metadata.itemID != nil
            || metadata.commandStatus != nil
            || metadata.startedAt != nil
            || metadata.completedAt != nil
            || metadata.durationMs != nil
            || metadata.commandActions?.isEmpty == false
    }

    private static func commandRunTitle(
        commandText: String,
        metadata: ReviewLogEntry.Metadata?,
        isActive: Bool
    ) -> String {
        let command = commandText.nilIfEmpty ?? metadata?.command?.nilIfEmpty ?? "command"
        return "\(isActive ? "Running" : "Ran") \(commandSummaryName(command))"
    }

    private static func commandActionTitle(
        metadata: ReviewLogEntry.Metadata?,
        commandText: String,
        isActive: Bool
    ) -> String? {
        guard let actions = metadata?.commandActions,
              actions.isEmpty == false
        else {
            return nil
        }
        guard actions.allSatisfy({ $0.kind != .unknown }) else {
            return nil
        }

        if actions.allSatisfy({ $0.kind == .read }) {
            let names = uniqueActionLabels(actions.compactMap(readActionLabel))
            guard names.isEmpty == false else {
                return nil
            }
            return "\(isActive ? "Reading" : "Read") \(names.joined(separator: ", "))"
        }
        if actions.allSatisfy({ $0.kind == .search }) {
            let names = uniqueActionLabels(actions.compactMap(searchActionLabel))
            guard names.isEmpty == false else {
                return nil
            }
            return "\(isActive ? "Searching" : "Searched") \(names.joined(separator: ", "))"
        }
        if actions.allSatisfy({ $0.kind == .listFiles }) {
            let names = uniqueActionLabels(actions.compactMap(listActionLabel))
            guard names.isEmpty == false else {
                return nil
            }
            return "\(isActive ? "Listing" : "Listed") \(names.joined(separator: ", "))"
        }

        if commandText.isEmpty == false || metadata?.command?.nilIfEmpty != nil {
            return isActive ? "Exploring" : "Explored"
        }
        return nil
    }

    private static func commandOutputIsActive(
        _ metadata: ReviewLogEntry.Metadata?,
        hasOutput: Bool
    ) -> Bool {
        guard let metadata else {
            return hasOutput == false
        }
        let status = (metadata.commandStatus ?? metadata.status)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch status {
        case "completed", "succeeded", "success", "failed", "failure", "errored", "declined", "canceled", "cancelled":
            return false
        case "inprogress", "in_progress", "started", "running":
            return true
        default:
            break
        }
        if metadata.completedAt != nil || metadata.durationMs != nil || metadata.exitCode != nil {
            return false
        }
        return true
    }

    private static func commandDurationText(
        metadata: ReviewLogEntry.Metadata?,
        isActive: Bool,
        currentDate: Date
    ) -> String? {
        let durationMs: Int?
        if isActive, let startedAt = metadata?.startedAt {
            durationMs = commandDurationMs(startedAt: startedAt, completedAt: currentDate)
        } else {
            durationMs = metadata?.durationMs ?? commandDurationMs(
                startedAt: metadata?.startedAt,
                completedAt: metadata?.completedAt
            )
        }
        guard let durationMs else {
            return nil
        }
        return formattedCommandDuration(milliseconds: durationMs)
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

    private static func commandOutputResultText(for metadata: ReviewLogEntry.Metadata?) -> String? {
        if let exitCode = metadata?.exitCode {
            return exitCode == 0 ? "Success" : "exit \(exitCode)"
        }

        let rawStatus = metadata?.commandStatus ?? metadata?.status
        let normalizedStatus = rawStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedStatus == "succeeded" || normalizedStatus == "success" || normalizedStatus == "completed" {
            return "Success"
        }
        if normalizedStatus == "failed" || normalizedStatus == "failure" || normalizedStatus == "errored" {
            if let exitCode = metadata?.exitCode {
                return "exit \(exitCode)"
            }
            return "Failed"
        }
        return rawStatus?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func commandSummaryName(_ commandText: String) -> String {
        let components = commandText.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return components.prefix(2).joined(separator: " ")
    }

    private static func readActionLabel(_ action: ReviewLogEntry.Metadata.CommandAction) -> String? {
        action.name?.nilIfEmpty
            ?? action.path?.nilIfEmpty.map { URL(fileURLWithPath: $0).lastPathComponent.nilIfEmpty ?? $0 }
            ?? action.command?.nilIfEmpty
    }

    private static func searchActionLabel(_ action: ReviewLogEntry.Metadata.CommandAction) -> String? {
        let query = action.query?.nilIfEmpty
        let path = action.path?.nilIfEmpty.map(actionPathLabel)
        switch (query, path) {
        case (let query?, let path?):
            return "\(query) in \(path)"
        case (let query?, nil):
            return query
        case (nil, let path?):
            return path
        case (nil, nil):
            return action.command?.nilIfEmpty
        }
    }

    private static func listActionLabel(_ action: ReviewLogEntry.Metadata.CommandAction) -> String? {
        action.path?.nilIfEmpty.map(actionPathLabel) ?? action.command?.nilIfEmpty
    }

    private static func actionPathLabel(_ path: String) -> String {
        guard path.hasPrefix("/") else {
            return path
        }
        return URL(fileURLWithPath: path).lastPathComponent.nilIfEmpty ?? path
    }

    private static func uniqueActionLabels(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for label in labels {
            guard seen.insert(label).inserted else {
                continue
            }
            result.append(label)
        }
        return result
    }

    private static func commandDurationMs(startedAt: Date?, completedAt: Date?) -> Int? {
        guard let startedAt, let completedAt else {
            return nil
        }
        let milliseconds = completedAt.timeIntervalSince(startedAt) * 1000
        guard milliseconds.isFinite else {
            return nil
        }
        return max(0, Int(milliseconds.rounded()))
    }

    private static func formattedCommandDuration(milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1000)
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes < 60 {
            return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }

    private static func commandOutputCommandTextByGroupID(
        in blocks: [ReviewMonitorLog.Block],
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

    private static func mappedLastChange(
        _ change: ReviewMonitorLog.Change,
        sourceBlocks: [ReviewMonitorLog.Block],
        displayBlocks: [ReviewMonitorLog.Block],
        previousDisplay: ReviewMonitorLog.Document?,
        displayText: String
    ) -> ReviewMonitorLog.Change {
        switch change {
        case .append(let append):
            guard let mappedRange = mappedChangeRange(
                append.range,
                blockID: append.blockID,
                sourceBlocks: sourceBlocks,
                displayBlocks: displayBlocks
            ) else {
                if let panelMutation = mappedCommandPanelMutation(
                    sourceRange: append.range,
                    blockID: append.blockID,
                    sourceBlocks: sourceBlocks,
                    displayBlocks: displayBlocks,
                    previousDisplay: previousDisplay,
                    displayText: displayText
                ) {
                    return panelMutation
                }
                return .reload
            }
            return .append(.init(
                kind: append.kind,
                blockID: append.blockID,
                range: mappedRange,
                text: append.text,
                textUTF16Length: append.textUTF16Length,
                animationSpans: append.animationSpans
            ))
        case .replace(let replacement):
            guard let mappedRange = mappedChangeRange(
                replacement.range,
                blockID: replacement.blockID,
                sourceBlocks: sourceBlocks,
                displayBlocks: displayBlocks
            ) else {
                if let panelMutation = mappedCommandPanelMutation(
                    sourceRange: replacement.range,
                    blockID: replacement.blockID,
                    sourceBlocks: sourceBlocks,
                    displayBlocks: displayBlocks,
                    previousDisplay: previousDisplay,
                    displayText: displayText
                ) {
                    return panelMutation
                }
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

    private static func mappedCommandPanelMutation(
        sourceRange: NSRange,
        blockID: ReviewMonitorLog.BlockID,
        sourceBlocks: [ReviewMonitorLog.Block],
        displayBlocks: [ReviewMonitorLog.Block],
        previousDisplay: ReviewMonitorLog.Document?,
        displayText: String
    ) -> ReviewMonitorLog.Change? {
        guard let sourceBlock = sourceBlocks.first(where: { $0.id == blockID }),
              sourceBlock.kind == .command || sourceBlock.kind == .commandOutput,
              NSMaxRange(sourceRange) <= NSMaxRange(sourceBlock.range),
              let displayBlock = commandPanelDisplayBlock(
                for: sourceBlock,
                displayBlocks: displayBlocks
              )
        else {
            return nil
        }

        let displayString = displayText as NSString
        guard NSMaxRange(displayBlock.range) <= displayString.length else {
            return nil
        }
        let replacementText = displayString.substring(with: displayBlock.range)
        if let previousRange = commandPanelDisplayBlock(
            for: sourceBlock,
            displayBlocks: previousDisplay?.blocks ?? []
        )?.range {
            return .replace(.init(
                kind: displayBlock.kind,
                blockID: displayBlock.id,
                range: previousRange,
                text: replacementText,
                textUTF16Length: displayBlock.range.length
            ))
        }

        guard let append = mappedNewCommandPanelAppend(
            displayBlock: displayBlock,
            displayText: displayText,
            previousDisplay: previousDisplay
        ) else {
            return nil
        }
        return .append(append)
    }

    private static func mappedNewCommandPanelAppend(
        displayBlock: ReviewMonitorLog.Block,
        displayText: String,
        previousDisplay: ReviewMonitorLog.Document?
    ) -> ReviewMonitorLog.Append? {
        guard let previousDisplay else {
            return nil
        }

        let displayString = displayText as NSString
        let previousLength = previousDisplay.textUTF16Length
        guard previousLength <= displayString.length else {
            return nil
        }
        guard displayString.substring(with: NSRange(location: 0, length: previousLength)) == previousDisplay.text else {
            return nil
        }

        let suffixRange = NSRange(
            location: previousLength,
            length: displayString.length - previousLength
        )
        guard suffixRange.length > 0,
              NSIntersectionRange(displayBlock.range, suffixRange).length > 0
        else {
            return nil
        }

        return .init(
            kind: displayBlock.kind,
            blockID: displayBlock.id,
            range: suffixRange,
            text: displayString.substring(with: suffixRange),
            textUTF16Length: suffixRange.length
        )
    }

    private static func commandPanelDisplayBlock(
        for sourceBlock: ReviewMonitorLog.Block,
        displayBlocks: [ReviewMonitorLog.Block]
    ) -> ReviewMonitorLog.Block? {
        if let groupID = sourceBlock.groupID {
            return displayBlocks.first {
                $0.kind == .commandOutput && $0.groupID == groupID
            }
        }
        return displayBlocks.first {
            $0.kind == .commandOutput && $0.id == sourceBlock.id
        }
    }

    private static func mappedChangeRange(
        _ range: NSRange,
        blockID: ReviewMonitorLog.BlockID,
        sourceBlocks: [ReviewMonitorLog.Block],
        displayBlocks: [ReviewMonitorLog.Block]
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
