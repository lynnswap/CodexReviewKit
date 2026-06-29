import CodexKit
import Foundation

struct ReviewMonitorCodexChatLogProjection: Sendable {
    private var documentProjection = ReviewMonitorLogDocumentProjection()

    var currentDocument: ReviewMonitorLog.Document {
        documentProjection.currentDocument
    }

    mutating func reset() {
        documentProjection.reset()
    }

    mutating func render(
        from snapshot: CodexChatProjectedTurnSnapshot,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?
    ) -> ReviewMonitorLog.Document? {
        guard snapshot.items.isEmpty == false else {
            documentProjection.reset()
            return nil
        }
        let blocks = snapshot.items.flatMap {
            projectedBlocks(
                from: $0,
                turnSnapshot: snapshot.turn,
                chatCreatedAt: chatCreatedAt,
                chatUpdatedAt: chatUpdatedAt
            )
        }
        guard blocks.isEmpty == false else {
            documentProjection.reset()
            return nil
        }
        return documentProjection.render(projectedBlocks: blocks)
    }

    private func projectedBlocks(
        from item: CodexChatItemSnapshot,
        turnSnapshot: CodexChatTurnStateSnapshot,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?
    ) -> [ReviewMonitorLogProjectedBlock] {
        switch item.content {
        case .message(let message):
            return [
                projectedBlock(
                    item,
                    kind: .agentMessage,
                    text: message.text
                )
            ]
        case .plan(let markdown):
            return [
                projectedBlock(
                    item,
                    kind: logKind(for: item, fallback: .plan),
                    text: markdown
                )
            ]
        case .reasoning(let reasoning):
            return [
                projectedBlock(
                    item,
                    kind: logKind(for: item, fallback: .reasoning),
                    text: reasoning.text
                )
            ]
        case .command(let command):
            return commandBlocks(
                item: item,
                command: command,
                turnSnapshot: turnSnapshot,
                chatCreatedAt: chatCreatedAt,
                chatUpdatedAt: chatUpdatedAt
            )
        case .fileChange(let fileChange):
            let title = fileChange.path ?? "File change"
            return [
                projectedBlock(
                    item,
                    kind: .commandOutput,
                    groupID: sourceBlockID(for: item),
                    text: fileChange.output?.nilIfEmpty ?? title,
                    metadata: .init(
                        sourceType: "fileChange",
                        title: title,
                        status: fileChangeStatus(
                            item: item,
                            fileChange: fileChange,
                            turnSnapshot: turnSnapshot
                        ),
                        path: fileChange.path
                    )
                )
            ]
        case .toolCall(let toolCall):
            if item.kind == .webSearch {
                return webSearchBlocks(item: item, toolCall: toolCall)
            }
            return toolCallBlocks(item: item, toolCall: toolCall)
        case .contextCompaction(let text):
            let title = text ?? "Context compaction"
            return [
                projectedBlock(
                    item,
                    kind: .contextCompaction,
                    text: title,
                    metadata: .init(
                        sourceType: "contextCompaction",
                        title: title,
                        status: turnSnapshot.status?.rawValue
                    )
                )
            ]
        case .diagnostic(let message):
            return [
                projectedBlock(
                    item,
                    kind: logKind(for: item, fallback: .diagnostic),
                    text: message,
                    metadata: metadata(
                        for: item,
                        sourceType: item.kind.rawValue,
                        title: message,
                        status: itemStatus(for: item, turnSnapshot: turnSnapshot).rawValue
                    )
                )
            ]
        case .log(let message):
            return [
                projectedBlock(
                    item,
                    kind: .diagnostic,
                    text: message,
                    metadata: metadata(
                        for: item,
                        sourceType: "log",
                        title: message,
                        status: itemStatus(for: item, turnSnapshot: turnSnapshot).rawValue
                    )
                )
            ]
        case .unknown(let raw):
            let title = raw.text ?? raw.rawType
            return [
                projectedBlock(
                    item,
                    kind: logKind(for: item, fallback: .event),
                    text: unknownText(title: title, detail: raw.text),
                    metadata: metadata(
                        for: item,
                        sourceType: item.kind.rawValue,
                        title: title,
                        status: item.itemStatus?.rawValue,
                        detail: raw.text
                    )
                )
            ]
        }
    }

    private func unknownText(title: String, detail: String?) -> String {
        guard let detail, detail != title else {
            return title
        }
        return "\(title)\n\(detail)"
    }

    private func commandBlocks(
        item: CodexChatItemSnapshot,
        command: CodexCommand,
        turnSnapshot: CodexChatTurnStateSnapshot,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?
    ) -> [ReviewMonitorLogProjectedBlock] {
        let groupID = sourceBlockID(for: item)
        let metadata = commandMetadata(
            item: item,
            command: command,
            turnSnapshot: turnSnapshot,
            chatCreatedAt: chatCreatedAt,
            chatUpdatedAt: chatUpdatedAt
        )
        let commandLine = command.command.nilIfEmpty
        let output = command.output ?? ""
        if (commandLine == nil || command.command == "Command"), output.isEmpty == false {
            return [
                .init(
                    id: derivedBlockID(prefix: "commandOutput", item: item),
                    kind: .commandOutput,
                    groupID: groupID,
                    text: output,
                    metadata: outputOnlyCommandMetadata(
                        item: item,
                        command: command,
                        turnSnapshot: turnSnapshot,
                        chatCreatedAt: chatCreatedAt,
                        chatUpdatedAt: chatUpdatedAt
                    )
                )
            ]
        }
        guard let commandLine else {
            return []
        }
        var blocks = [
            ReviewMonitorLogProjectedBlock(
                id: derivedBlockID(prefix: "command", item: item),
                kind: .command,
                groupID: groupID,
                text: "$ \(commandLine)",
                metadata: metadata
            )
        ]
        if output.isEmpty == false {
            blocks.append(
                .init(
                    id: derivedBlockID(prefix: "commandOutput", item: item),
                    kind: .commandOutput,
                    groupID: groupID,
                    text: output,
                    metadata: metadata
                ))
        }
        return blocks
    }

    private func webSearchBlocks(
        item: CodexChatItemSnapshot,
        toolCall: CodexToolCall
    ) -> [ReviewMonitorLogProjectedBlock] {
        let query = toolCall.arguments ?? toolCall.name ?? "Web search"
        return [
            projectedBlock(
                item,
                kind: .toolCall,
                text: toolCall.result ?? toolCall.error ?? "Web search: \(query)",
                metadata: metadata(
                    for: item,
                    sourceType: "webSearch",
                    title: "Web search",
                    status: toolCall.status?.rawValue,
                    query: query,
                    resultText: toolCall.result,
                    errorText: toolCall.error
                )
            )
        ]
    }

    private func toolCallBlocks(
        item: CodexChatItemSnapshot,
        toolCall: CodexToolCall
    ) -> [ReviewMonitorLogProjectedBlock] {
        let label = [toolCall.namespace, toolCall.server, toolCall.name]
            .compactMap { $0?.nilIfEmpty }
            .joined(separator: ".")
        return [
            projectedBlock(
                item,
                kind: .toolCall,
                text: toolCall.error?.nilIfEmpty
                    ?? toolCall.result?.nilIfEmpty
                    ?? label.nilIfEmpty
                    ?? "Tool call",
                metadata: metadata(
                    for: item,
                    sourceType: item.kind.rawValue,
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
    }

    private func projectedBlock(
        _ item: CodexChatItemSnapshot,
        kind: ReviewMonitorLog.Kind,
        groupID: String? = nil,
        text: String,
        metadata: ReviewMonitorLog.Metadata? = nil
    ) -> ReviewMonitorLogProjectedBlock {
        .init(
            id: derivedBlockID(prefix: kind.rawValue, item: item),
            kind: kind,
            groupID: groupID,
            text: text,
            metadata: metadata
        )
    }

    private func derivedBlockID(
        prefix: String,
        item: CodexChatItemSnapshot
    ) -> ReviewMonitorLog.BlockID {
        ReviewMonitorLog.BlockID("\(prefix):\(sourceBlockID(for: item))")
    }

    private func sourceBlockID(for item: CodexChatItemSnapshot) -> String {
        let rawTurnID = item.turnID?.rawValue ?? "unknown-turn"
        return "\(rawTurnID):\(item.id)"
    }

    private func logKind(
        for item: CodexChatItemSnapshot,
        fallback: ReviewMonitorLog.Kind
    ) -> ReviewMonitorLog.Kind {
        ReviewMonitorLog.Kind(rawValue: item.kind.rawValue) ?? fallback
    }

    private func metadata(
        for item: CodexChatItemSnapshot,
        sourceType: String,
        title: String? = nil,
        status: String? = nil,
        detail: String? = nil,
        namespace: String? = nil,
        server: String? = nil,
        tool: String? = nil,
        query: String? = nil,
        resultText: String? = nil,
        errorText: String? = nil
    ) -> ReviewMonitorLog.Metadata {
        .init(
            sourceType: sourceType,
            title: title,
            status: status,
            detail: detail,
            itemID: sourceBlockID(for: item),
            namespace: namespace,
            server: server,
            tool: tool,
            query: query,
            resultText: resultText,
            errorText: errorText
        )
    }

    private func commandMetadata(
        item: CodexChatItemSnapshot,
        command: CodexCommand,
        turnSnapshot: CodexChatTurnStateSnapshot,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?
    ) -> ReviewMonitorLog.Metadata {
        let status = commandStatus(item: item, command: command, turnSnapshot: turnSnapshot)
        return .init(
            sourceType: "commandExecution",
            status: status,
            itemID: sourceBlockID(for: item),
            command: command.command,
            cwd: command.cwd,
            exitCode: command.exitCode,
            startedAt: chatCreatedAt,
            completedAt: terminalStatus(itemStatus(for: item, turnSnapshot: turnSnapshot)) ? chatUpdatedAt : nil,
            commandStatus: status
        )
    }

    private func outputOnlyCommandMetadata(
        item: CodexChatItemSnapshot,
        command: CodexCommand,
        turnSnapshot: CodexChatTurnStateSnapshot,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?
    ) -> ReviewMonitorLog.Metadata {
        guard
            command.cwd != nil || command.exitCode != nil || command.status != nil || chatCreatedAt != nil
                || chatUpdatedAt != nil
        else {
            let status = itemStatus(for: item, turnSnapshot: turnSnapshot)
            return .init(
                sourceType: "command",
                title: "Command output",
                status: terminalStatus(status) ? status.rawValue : "completed"
            )
        }
        return commandMetadata(
            item: item,
            command: command,
            turnSnapshot: turnSnapshot,
            chatCreatedAt: chatCreatedAt,
            chatUpdatedAt: chatUpdatedAt
        )
    }

    private func commandStatus(
        item: CodexChatItemSnapshot,
        command: CodexCommand,
        turnSnapshot: CodexChatTurnStateSnapshot
    ) -> String {
        let status = itemStatus(for: item, turnSnapshot: turnSnapshot)
        if terminalStatus(status) {
            return status.rawValue
        }
        if let commandStatus = command.status,
            terminalStatus(commandStatus)
        {
            return commandStatus.rawValue
        }
        if let exitCode = command.exitCode {
            return exitCode == 0 ? CodexTurnStatus.completed.rawValue : CodexTurnStatus.failed.rawValue
        }
        return command.status?.rawValue ?? status.rawValue
    }

    private func fileChangeStatus(
        item: CodexChatItemSnapshot,
        fileChange: CodexFileChange,
        turnSnapshot: CodexChatTurnStateSnapshot
    ) -> String {
        let status = itemStatus(for: item, turnSnapshot: turnSnapshot)
        if terminalStatus(status) {
            return status.rawValue
        }
        return fileChange.status?.rawValue ?? status.rawValue
    }

    private func itemStatus(
        for item: CodexChatItemSnapshot,
        turnSnapshot: CodexChatTurnStateSnapshot
    ) -> CodexTurnStatus {
        item.itemStatus ?? turnSnapshot.status ?? .running
    }

    private func terminalStatus(_ status: CodexTurnStatus) -> Bool {
        switch status {
        case .running, .unknown:
            return false
        case .completed, .failed, .interrupted, .cancelled:
            return true
        }
    }
}

private extension CodexChatItemSnapshot {
    var itemStatus: CodexTurnStatus? {
        switch content {
        case .command(let command):
            return command.status
        case .fileChange(let fileChange):
            return fileChange.status
        case .toolCall(let toolCall):
            return toolCall.status
        case .message, .plan, .reasoning, .contextCompaction, .diagnostic, .log, .unknown:
            return nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
