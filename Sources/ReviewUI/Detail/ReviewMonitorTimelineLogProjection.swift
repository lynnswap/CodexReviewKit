import Foundation
import CodexReviewKit
import ReviewMonitorRendering

struct ReviewMonitorTimelineLogProjection: Sendable {
    private var documentProjection = ReviewMonitorLogDocumentProjection()

    var currentDocument: ReviewMonitorLog.Document {
        documentProjection.currentDocument
    }

    mutating func render(timelineDocument: ReviewTimelineDocument) -> ReviewMonitorLog.Document {
        documentProjection.render(projectedBlocks: Self.projectedBlocks(from: timelineDocument))
    }

    private static func projectedBlocks(
        from timelineDocument: ReviewTimelineDocument
    ) -> [ReviewMonitorLogProjectedBlock] {
        var blocks: [ReviewMonitorLogProjectedBlock] = []
        let blocksByID = Dictionary(uniqueKeysWithValues: timelineDocument.blocks.map { ($0.id, $0) })
        for blockID in timelineDocument.orderedBlockIDs {
            guard let block = blocksByID[blockID] else {
                continue
            }
            blocks.append(contentsOf: projectedBlocks(for: block))
        }
        return blocks
    }

    private static func projectedBlocks(
        for block: ReviewTimelineDocument.Block
    ) -> [ReviewMonitorLogProjectedBlock] {
        switch block.content {
        case .approval(let approval):
            return [
                projectedBlock(
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
                )
            ]
        case .command(let command):
            let groupID = block.id.rawValue
            let metadata = commandMetadata(for: block, command: command)
            let commandLine = command.command.nilIfEmpty
            if (commandLine == nil || command.command == "Command"), command.output.isEmpty == false {
                return [
                    ReviewMonitorLogProjectedBlock(
                        id: derivedBlockID(prefix: "commandOutput", from: block),
                        kind: .commandOutput,
                        groupID: groupID,
                        text: command.output,
                        metadata: outputOnlyCommandMetadata(for: block, command: command)
                    )
                ]
            }
            guard let commandLine else {
                return []
            }
            var blocks = [
                ReviewMonitorLogProjectedBlock(
                    id: derivedBlockID(prefix: "command", from: block),
                    kind: .command,
                    groupID: groupID,
                    text: "$ \(commandLine)",
                    metadata: metadata
                )
            ]
            if command.output.isEmpty == false {
                blocks.append(
                    ReviewMonitorLogProjectedBlock(
                        id: derivedBlockID(prefix: "commandOutput", from: block),
                        kind: .commandOutput,
                        groupID: groupID,
                        text: command.output,
                        metadata: metadata
                    ))
            }
            return blocks
        case .contextCompaction(let contextCompaction):
            return [
                projectedBlock(
                    block,
                    kind: .contextCompaction,
                    text: contextCompaction.title,
                    metadata: metadata(
                        for: block,
                        sourceType: "contextCompaction",
                        title: contextCompaction.title,
                        status: contextCompaction.status?.rawValue
                    )
                )
            ]
        case .diagnostic(let diagnostic):
            return [
                projectedBlock(
                    block,
                    kind: logKind(for: block, fallback: .diagnostic),
                    text: diagnostic.message,
                    metadata: metadata(
                        for: block,
                        sourceType: block.kind.rawValue,
                        title: diagnostic.message,
                        status: block.phase.rawValue
                    )
                )
            ]
        case .fileChange(let fileChange):
            return [
                projectedBlock(
                    block,
                    kind: .commandOutput,
                    groupID: block.id.rawValue,
                    text: fileChange.output.isEmpty ? fileChange.title : fileChange.output,
                    metadata: fileChangeMetadata(
                        title: fileChange.title,
                        status: fileChangeStatus(for: block, fileChange: fileChange),
                        path: fileChange.paths.first
                    )
                )
            ]
        case .message(let message):
            return [projectedBlock(block, kind: .agentMessage, text: message.text)]
        case .plan(let plan):
            return [projectedBlock(block, kind: logKind(for: block, fallback: .plan), text: plan.markdown)]
        case .reasoning(let reasoning):
            return [
                projectedBlock(
                    block,
                    kind: logKind(
                        for: block,
                        fallback: reasoning.style == .raw ? .rawReasoning : .reasoningSummary
                    ),
                    text: reasoning.text
                )
            ]
        case .search(let search):
            return [
                projectedBlock(
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
                )
            ]
        case .toolCall(let toolCall):
            let label = [toolCall.namespace, toolCall.server, toolCall.name]
                .compactMap { $0?.nilIfEmpty }
                .joined(separator: ".")
            return [
                projectedBlock(
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
                )
            ]
        case .unknown(let unknown):
            return [
                projectedBlock(
                    block,
                    kind: logKind(for: block, fallback: .event),
                    text: [unknown.title, unknown.detail].compactMap { $0 }.joined(separator: "\n"),
                    metadata: metadata(
                        for: block,
                        sourceType: unknown.rawKind?.rawValue ?? block.kind.rawValue,
                        title: unknown.title,
                        status: unknown.rawStatus ?? block.phase.rawValue,
                        detail: unknown.detail
                    )
                )
            ]
        }
    }

    private static func projectedBlock(
        _ block: ReviewTimelineDocument.Block,
        kind: ReviewMonitorLog.Kind,
        groupID: String? = nil,
        text: String,
        metadata: ReviewMonitorLog.Metadata? = nil
    ) -> ReviewMonitorLogProjectedBlock {
        ReviewMonitorLogProjectedBlock(
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

    private static func logKind(
        for block: ReviewTimelineDocument.Block,
        fallback: ReviewMonitorLog.Kind
    ) -> ReviewMonitorLog.Kind {
        ReviewMonitorLog.Kind(rawValue: block.kind.rawValue) ?? fallback
    }

    private static func commandMetadata(
        for block: ReviewTimelineDocument.Block,
        command: ReviewTimelineDocument.Command
    ) -> ReviewMonitorLog.Metadata {
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
            ReviewItemPhase.normalized(status).isTerminal
        {
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
    ) -> ReviewMonitorLog.Metadata {
        guard hasStructuredOutputOnlyCommandMetadata(for: block, command: command) else {
            return genericCommandOutputMetadata(for: block)
        }

        let normalizedStatus = commandStatus(for: block, command: command)
        return ReviewMonitorLog.Metadata(
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
        command.cwd != nil || command.exitCode != nil || command.status != nil || command.source != nil
            || command.processID != nil || command.actions.isEmpty == false || command.durationMs != nil
            || block.startedAt != nil || block.completedAt != nil || block.durationMs != nil
    }

    private static func genericCommandOutputMetadata(
        for block: ReviewTimelineDocument.Block
    ) -> ReviewMonitorLog.Metadata {
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
    ) -> ReviewMonitorLog.Metadata {
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
    ) -> ReviewMonitorLog.Metadata.CommandAction {
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
    ) -> ReviewMonitorLog.Metadata.CommandAction.Kind {
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
    ) -> ReviewMonitorLog.Metadata {
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
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
