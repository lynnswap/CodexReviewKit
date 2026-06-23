import Foundation
import CodexReview
import CodexReviewDomain
import ReviewMonitorRendering

struct ReviewMonitorTimelineLogProjection: Sendable {
    private struct ProjectedBlock: Equatable, Sendable {
        var id: ReviewMonitorLog.BlockID
        var kind: ReviewLogEntry.Kind
        var groupID: String?
        var text: String
        var metadata: ReviewLogEntry.Metadata?
    }

    private var document = ReviewMonitorLog.Document()

    var currentDocument: ReviewMonitorLog.Document {
        document
    }

    mutating func render(timelineDocument: ReviewTimelineDocument) -> ReviewMonitorLog.Document {
        let previous = document
        var current = Self.makeDocument(from: timelineDocument)

        guard Self.contentChanged(previous: previous, current: current) else {
            return document
        }

        current.revision = previous.revision &+ 1
        current.lastChange = Self.preferredChange(previous: previous, current: current)
        document = current
        return document
    }

    private static func makeDocument(from timelineDocument: ReviewTimelineDocument) -> ReviewMonitorLog.Document {
        var builder = DocumentBuilder()
        let blocksByID = Dictionary(uniqueKeysWithValues: timelineDocument.blocks.map { ($0.id, $0) })
        for blockID in timelineDocument.orderedBlockIDs {
            guard let block = blocksByID[blockID] else {
                continue
            }
            for projectedBlock in projectedBlocks(for: block) {
                builder.append(projectedBlock)
            }
        }
        return builder.document
    }

    private static func projectedBlocks(for block: ReviewTimelineDocument.Block) -> [ProjectedBlock] {
        switch block.content {
        case .approval(let approval):
            return [projectedBlock(
                block,
                kind: .event,
                text: [approval.title, approval.detail].compactMap { $0 }.joined(separator: "\n"),
                metadata: metadata(
                    for: block,
                    sourceType: block.kind.rawValue,
                    title: approval.title,
                    status: approval.status?.rawValue,
                    detail: approval.detail
                )
            )]
        case .command(let command):
            let groupID = block.id.rawValue
            let metadata = commandMetadata(for: block, command: command)
            let commandLine = command.command.nilIfEmpty
            if (commandLine == nil || command.command == "Command"), command.output.isEmpty == false {
                return [
                    ProjectedBlock(
                        id: derivedBlockID(prefix: "commandOutput", from: block),
                        kind: .commandOutput,
                        groupID: groupID,
                        text: command.output,
                        metadata: outputOnlyCommandMetadata(for: block, command: command)
                    ),
                ]
            }
            guard let commandLine else {
                return []
            }
            var blocks = [
                ProjectedBlock(
                    id: derivedBlockID(prefix: "command", from: block),
                    kind: .command,
                    groupID: groupID,
                    text: "$ \(commandLine)",
                    metadata: metadata
                ),
            ]
            if command.output.isEmpty == false {
                blocks.append(ProjectedBlock(
                    id: derivedBlockID(prefix: "commandOutput", from: block),
                    kind: .commandOutput,
                    groupID: groupID,
                    text: command.output,
                    metadata: metadata
                ))
            }
            return blocks
        case .contextCompaction(let contextCompaction):
            return [projectedBlock(
                block,
                kind: .contextCompaction,
                text: contextCompaction.title,
                metadata: metadata(
                    for: block,
                    sourceType: "contextCompaction",
                    title: contextCompaction.title,
                    status: contextCompaction.status?.rawValue
                )
            )]
        case .diagnostic(let diagnostic):
            return [projectedBlock(
                block,
                kind: legacyKind(for: block, fallback: .diagnostic),
                text: diagnostic.message,
                metadata: metadata(
                    for: block,
                    sourceType: block.kind.rawValue,
                    title: diagnostic.message,
                    status: block.phase.rawValue
                )
            )]
        case .fileChange(let fileChange):
            return [projectedBlock(
                block,
                kind: .commandOutput,
                groupID: block.id.rawValue,
                text: fileChange.output.isEmpty ? fileChange.title : fileChange.output,
                metadata: fileChangeMetadata(
                    title: fileChange.title,
                    status: fileChangeStatus(for: block, fileChange: fileChange),
                    path: fileChange.paths.first
                )
            )]
        case .message(let message):
            return [projectedBlock(block, kind: .agentMessage, text: message.text)]
        case .plan(let plan):
            return [projectedBlock(block, kind: legacyKind(for: block, fallback: .plan), text: plan.markdown)]
        case .reasoning(let reasoning):
            return [projectedBlock(
                block,
                kind: legacyKind(
                    for: block,
                    fallback: reasoning.style == .raw ? .rawReasoning : .reasoningSummary
                ),
                text: reasoning.text
            )]
        case .search(let search):
            return [projectedBlock(
                block,
                kind: .toolCall,
                text: search.result ?? "Web search: \(search.query)",
                metadata: metadata(
                    for: block,
                    sourceType: "webSearch",
                    title: "Web search",
                    status: search.status?.rawValue,
                    query: search.query,
                    resultText: search.result
                )
            )]
        case .toolCall(let toolCall):
            let label = [toolCall.namespace, toolCall.server, toolCall.name]
                .compactMap { $0?.nilIfEmpty }
                .joined(separator: ".")
            return [projectedBlock(
                block,
                kind: .toolCall,
                text: toolCall.error?.nilIfEmpty
                    ?? toolCall.result?.nilIfEmpty
                    ?? toolCall.progress?.nilIfEmpty
                    ?? label.nilIfEmpty
                    ?? "Tool call",
                metadata: metadata(
                    for: block,
                    sourceType: block.kind.rawValue,
                    title: label.nilIfEmpty,
                    status: toolCall.status?.rawValue,
                    detail: toolCall.arguments,
                    namespace: toolCall.namespace,
                    server: toolCall.server,
                    tool: toolCall.name,
                    resultText: toolCall.result,
                    errorText: toolCall.error
                )
            )]
        case .unknown(let unknown):
            return [projectedBlock(
                block,
                kind: legacyKind(for: block, fallback: .event),
                text: [unknown.title, unknown.detail].compactMap { $0 }.joined(separator: "\n"),
                metadata: metadata(
                    for: block,
                    sourceType: unknown.rawKind?.rawValue ?? block.kind.rawValue,
                    title: unknown.title,
                    status: unknown.rawStatus ?? block.phase.rawValue,
                    detail: unknown.detail
                )
            )]
        }
    }

    private static func projectedBlock(
        _ block: ReviewTimelineDocument.Block,
        kind: ReviewLogEntry.Kind,
        groupID: String? = nil,
        text: String,
        metadata: ReviewLogEntry.Metadata? = nil
    ) -> ProjectedBlock {
        ProjectedBlock(
            id: derivedBlockID(prefix: kind.rawValue, from: block),
            kind: kind,
            groupID: groupID,
            text: text,
            metadata: metadata
        )
    }

    private static func derivedBlockID(
        prefix: String,
        from block: ReviewTimelineDocument.Block
    ) -> ReviewMonitorLog.BlockID {
        ReviewMonitorLog.BlockID("\(prefix):\(block.id.rawValue)")
    }

    private static func legacyKind(
        for block: ReviewTimelineDocument.Block,
        fallback: ReviewLogEntry.Kind
    ) -> ReviewLogEntry.Kind {
        ReviewLogEntry.Kind(rawValue: block.kind.rawValue) ?? fallback
    }

    private static func commandMetadata(
        for block: ReviewTimelineDocument.Block,
        command: ReviewTimelineDocument.Command
    ) -> ReviewLogEntry.Metadata {
        let status = commandStatus(for: block, command: command)
        return .init(
            sourceType: "commandExecution",
            status: status,
            itemID: block.sourceItemID.rawValue,
            command: command.command,
            cwd: command.cwd,
            exitCode: command.exitCode,
            startedAt: block.startedAt,
            completedAt: block.completedAt,
            durationMs: command.durationMs ?? block.durationMs,
            commandActions: command.actions.map(commandAction),
            commandStatus: status
        )
    }

    private static func commandStatus(
        for block: ReviewTimelineDocument.Block,
        command: ReviewTimelineDocument.Command
    ) -> String {
        if block.phase.isTerminal {
            return block.phase.rawValue
        }
        if let status = command.status?.rawValue,
           ReviewItemPhase.normalized(status).isTerminal {
            return status
        }
        if let exitCode = command.exitCode {
            return exitCode == 0
                ? ReviewCommandStatus.completed.rawValue
                : ReviewCommandStatus.failed.rawValue
        }
        if block.isActive {
            if let status = command.status?.rawValue {
                return status
            }
            return block.phase.rawValue
        }
        return ReviewCommandStatus.completed.rawValue
    }

    private static func outputOnlyCommandMetadata(
        for block: ReviewTimelineDocument.Block,
        command: ReviewTimelineDocument.Command
    ) -> ReviewLogEntry.Metadata {
        guard hasStructuredOutputOnlyCommandMetadata(for: block, command: command) else {
            return genericCommandOutputMetadata(for: block)
        }

        let normalizedStatus = commandStatus(for: block, command: command)
        return ReviewLogEntry.Metadata(
            sourceType: "commandExecution",
            status: normalizedStatus,
            itemID: block.sourceItemID.rawValue,
            cwd: command.cwd,
            exitCode: command.exitCode,
            startedAt: block.startedAt,
            completedAt: block.completedAt,
            durationMs: command.durationMs ?? block.durationMs,
            commandActions: command.actions.map(commandAction),
            commandStatus: normalizedStatus
        )
    }

    private static func hasStructuredOutputOnlyCommandMetadata(
        for block: ReviewTimelineDocument.Block,
        command: ReviewTimelineDocument.Command
    ) -> Bool {
        command.cwd != nil ||
            command.exitCode != nil ||
            command.status != nil ||
            command.source != nil ||
            command.processID != nil ||
            command.actions.isEmpty == false ||
            command.durationMs != nil ||
            block.startedAt != nil ||
            block.completedAt != nil ||
            block.durationMs != nil
    }

    private static func genericCommandOutputMetadata(
        for block: ReviewTimelineDocument.Block
    ) -> ReviewLogEntry.Metadata {
        .init(
            sourceType: "command",
            title: "Command output",
            status: block.phase.isTerminal || block.isActive
                ? block.phase.rawValue
                : "completed"
        )
    }

    private static func fileChangeMetadata(
        title: String?,
        status: String?,
        path: String?
    ) -> ReviewLogEntry.Metadata {
        .init(
            sourceType: "fileChange",
            title: title,
            status: status,
            path: path
        )
    }

    private static func fileChangeStatus(
        for block: ReviewTimelineDocument.Block,
        fileChange: ReviewTimelineDocument.FileChange
    ) -> String {
        if block.phase.isTerminal {
            return block.phase.rawValue
        }
        return fileChange.status?.rawValue ?? block.phase.rawValue
    }

    private static func commandAction(
        _ action: ReviewTimelineDocument.Command.Action
    ) -> ReviewLogEntry.Metadata.CommandAction {
        .init(
            kind: commandActionKind(action.kind),
            command: action.command,
            name: action.name,
            path: action.path,
            query: action.query
        )
    }

    private static func commandActionKind(
        _ kind: ReviewCommandActionKind
    ) -> ReviewLogEntry.Metadata.CommandAction.Kind {
        switch kind.rawValue {
        case ReviewCommandActionKind.read.rawValue:
            return .read
        case ReviewCommandActionKind.listFiles.rawValue:
            return .listFiles
        case ReviewCommandActionKind.search.rawValue:
            return .search
        default:
            return .unknown
        }
    }

    private static func metadata(
        for block: ReviewTimelineDocument.Block,
        sourceType: String,
        title: String? = nil,
        status: String? = nil,
        detail: String? = nil,
        query: String? = nil,
        path: String? = nil,
        namespace: String? = nil,
        server: String? = nil,
        tool: String? = nil,
        resultText: String? = nil,
        errorText: String? = nil
    ) -> ReviewLogEntry.Metadata {
        .init(
            sourceType: sourceType,
            title: title,
            status: status ?? block.phase.rawValue,
            detail: detail,
            itemID: block.sourceItemID.rawValue,
            startedAt: block.startedAt,
            completedAt: block.completedAt,
            durationMs: block.durationMs,
            namespace: namespace,
            server: server,
            tool: tool,
            query: query,
            path: path,
            resultText: resultText,
            errorText: errorText
        )
    }

    private static func preferredChange(
        previous: ReviewMonitorLog.Document,
        current: ReviewMonitorLog.Document
    ) -> ReviewMonitorLog.Change {
        if let append = appendChange(previous: previous, current: current) {
            return .append(append)
        }
        if let replacement = replacementChange(previous: previous, current: current) {
            return .replace(replacement)
        }
        return .reload
    }

    private static func appendChange(
        previous: ReviewMonitorLog.Document,
        current: ReviewMonitorLog.Document
    ) -> ReviewMonitorLog.Append? {
        guard current.textUTF16Length > previous.textUTF16Length,
              current.text.hasPrefix(previous.text)
        else {
            return nil
        }

        let suffix = String(current.text.dropFirst(previous.text.count))
        let suffixLength = utf16Length(suffix)
        let suffixRange = NSRange(location: previous.textUTF16Length, length: suffixLength)
        let block = current.blocks.first {
            NSIntersectionRange($0.range, suffixRange).length > 0
        }
        guard existingPresentationUnchanged(
            previous: previous,
            current: current,
            suffixBlockID: block?.id
        ) else {
            return nil
        }
        return .init(
            kind: block?.kind ?? .event,
            blockID: block?.id ?? ReviewMonitorLog.BlockID("timelineAppend"),
            range: suffixRange,
            text: suffix,
            textUTF16Length: suffixLength,
            animationSpans: current.blocks.flatMap { block in
                let intersection = NSIntersectionRange(block.range, suffixRange)
                guard intersection.length > 0 else {
                    return [] as [ReviewMonitorLog.AnimationSpan]
                }
                return ReviewMonitorLog.Append.animationSpans(
                    forKind: block.kind,
                    absoluteRange: intersection,
                    appendBaseLocation: previous.textUTF16Length
                )
            }
        )
    }

    private static func existingPresentationUnchanged(
        previous: ReviewMonitorLog.Document,
        current: ReviewMonitorLog.Document,
        suffixBlockID: ReviewMonitorLog.BlockID?
    ) -> Bool {
        var currentBlocksByID = [ReviewMonitorLog.BlockID: ReviewMonitorLog.Block]()
        for currentBlock in current.blocks {
            currentBlocksByID[currentBlock.id] = currentBlock
        }

        for previousBlock in previous.blocks {
            guard let currentBlock = currentBlocksByID[previousBlock.id] else {
                return false
            }
            if previousBlock.id == suffixBlockID {
                guard currentBlock.kind == previousBlock.kind,
                      currentBlock.groupID == previousBlock.groupID,
                      currentBlock.range.location == previousBlock.range.location,
                      currentBlock.sourceRange.location == previousBlock.sourceRange.location,
                      currentBlock.metadata == previousBlock.metadata,
                      currentBlock.range.length >= previousBlock.range.length,
                      currentBlock.sourceRange.length >= previousBlock.sourceRange.length
                else {
                    return false
                }
            } else if currentBlock != previousBlock {
                return false
            }
        }
        return true
    }

    private static func replacementChange(
        previous: ReviewMonitorLog.Document,
        current: ReviewMonitorLog.Document
    ) -> ReviewMonitorLog.Replacement? {
        for previousBlock in previous.blocks {
            guard let currentBlock = current.blocks.first(where: { $0.id == previousBlock.id }),
                  currentBlock.range.location == previousBlock.range.location,
                  NSMaxRange(currentBlock.range) <= current.textUTF16Length
            else {
                continue
            }

            let replacementText = (current.text as NSString).substring(with: currentBlock.range)
            let candidate = replacingText(
                in: previous.text,
                range: previousBlock.range,
                with: replacementText
            )
            guard candidate == current.text else {
                continue
            }
            return .init(
                kind: currentBlock.kind,
                blockID: currentBlock.id,
                range: previousBlock.range,
                text: replacementText,
                textUTF16Length: currentBlock.range.length
            )
        }
        return nil
    }

    private static func replacingText(
        in text: String,
        range: NSRange,
        with replacement: String
    ) -> String {
        let string = text as NSString
        let prefix = string.substring(with: NSRange(location: 0, length: range.location))
        let suffixLocation = NSMaxRange(range)
        let suffix = string.substring(
            with: NSRange(location: suffixLocation, length: string.length - suffixLocation)
        )
        return prefix + replacement + suffix
    }

    private static func contentChanged(
        previous: ReviewMonitorLog.Document,
        current: ReviewMonitorLog.Document
    ) -> Bool {
        previous.text != current.text ||
            previous.sourceText != current.sourceText ||
            previous.blocks != current.blocks ||
            previous.styleRuns != current.styleRuns ||
            previous.decorations != current.decorations
    }

    private static func utf16Length(_ text: String) -> Int {
        (text as NSString).length
    }

    private struct DocumentBuilder {
        private(set) var document = ReviewMonitorLog.Document()
        private var hasVisibleSections = false

        mutating func append(_ block: ProjectedBlock) {
            guard Self.isVisible(kind: block.kind, text: block.text) else {
                return
            }

            let renderedText = ReviewMonitorLogStyler.renderedText(
                for: block.kind,
                source: block.text,
                blockID: block.id
            )
            let appended = appendedText(renderedText, after: document.text)
            let appendedSource = appendedText(block.text, after: document.sourceText)
            hasVisibleSections = true

            let previousLength = document.textUTF16Length
            let previousSourceLength = document.sourceTextUTF16Length
            let suffixLength = ReviewMonitorTimelineLogProjection.utf16Length(appended)
            let sourceSuffixLength = ReviewMonitorTimelineLogProjection.utf16Length(appendedSource)
            let blockLength = ReviewMonitorTimelineLogProjection.utf16Length(renderedText)
            let sourceBlockLength = ReviewMonitorTimelineLogProjection.utf16Length(block.text)
            let blockRange = NSRange(
                location: previousLength + max(0, suffixLength - blockLength),
                length: blockLength
            )
            let sourceBlockRange = NSRange(
                location: previousSourceLength + max(0, sourceSuffixLength - sourceBlockLength),
                length: sourceBlockLength
            )

            document.text += appended
            document.textUTF16Length += suffixLength
            document.sourceText += appendedSource
            document.sourceTextUTF16Length += sourceSuffixLength
            let logBlock = ReviewMonitorLog.Block(
                id: block.id,
                kind: block.kind,
                groupID: block.groupID,
                range: blockRange,
                sourceRange: sourceBlockRange,
                metadata: block.metadata
            )
            document.blocks.append(logBlock)
            ReviewMonitorLogStyler.appendPresentation(for: logBlock, to: &document)
        }

        private func appendedText(_ blockText: String, after existingText: String) -> String {
            guard hasVisibleSections else {
                return blockText
            }
            if blockText.isEmpty {
                return "\n\n"
            }
            if existingText.hasSuffix("\n\n") {
                return blockText
            }
            if existingText.hasSuffix("\n") || blockText.hasPrefix("\n") {
                return "\n" + blockText
            }
            return "\n\n" + blockText
        }

        private static func isVisible(kind: ReviewLogEntry.Kind, text: String) -> Bool {
            if kind == .diagnostic {
                return true
            }
            return text.isEmpty == false
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
