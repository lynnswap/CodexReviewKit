import CodexKit
import Foundation

@MainActor
struct ReviewMonitorCodexChatLogProjection {
    private var documentProjection = ReviewMonitorLogDocumentProjection()

    var currentDocument: ReviewMonitorLog.Document {
        documentProjection.currentDocument
    }

    mutating func reset() {
        documentProjection.reset()
    }

    mutating func render(
        from chat: CodexChat,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?
    ) -> ReviewMonitorLog.Document? {
        var turnStatusByID: [CodexTurnID: CodexTurnStatus] = [:]
        for turn in chat.turns {
            if let status = turn.status {
                turnStatusByID[turn.id] = status
            }
        }
        return render(
            items: chat.items.map { item in
                CodexChatModelLogItem(
                    item: item,
                    turnStatus: item.turnID.flatMap { turnStatusByID[$0] }
                )
            },
            turnStatus: nil,
            chatCreatedAt: chatCreatedAt,
            chatUpdatedAt: chatUpdatedAt
        )
    }

    mutating func render(
        from snapshot: CodexTurnSnapshot,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?
    ) -> ReviewMonitorLog.Document? {
        render(
            items: snapshot.items.map {
                CodexThreadSnapshotLogItem(
                    item: $0,
                    turnID: snapshot.id,
                    turnStatus: snapshot.status
                )
            },
            turnStatus: snapshot.status,
            chatCreatedAt: chatCreatedAt,
            chatUpdatedAt: chatUpdatedAt
        )
    }

    mutating func render(
        from snapshot: CodexThreadSnapshot,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?
    ) -> ReviewMonitorLog.Document? {
        let items = (snapshot.turns ?? []).flatMap { turn in
            turn.items.map {
                CodexThreadSnapshotLogItem(
                    item: $0,
                    turnID: turn.id,
                    turnStatus: turn.status
                )
            }
        }
        return render(
            items: items,
            turnStatus: nil,
            chatCreatedAt: chatCreatedAt ?? snapshot.createdAt,
            chatUpdatedAt: chatUpdatedAt ?? snapshot.updatedAt
        )
    }

    private mutating func render<Item: CodexChatLogProjectionItem>(
        items: [Item],
        turnStatus: CodexTurnStatus?,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?
    ) -> ReviewMonitorLog.Document? {
        guard items.isEmpty == false else {
            documentProjection.reset()
            return nil
        }
        let suppressUserMessages = items.contains { item in
            item.kind == .enteredReviewMode || item.kind == .exitedReviewMode
        }
        let blocks = items.flatMap {
            projectedBlocks(
                from: $0,
                turnStatus: turnStatus,
                chatCreatedAt: chatCreatedAt,
                chatUpdatedAt: chatUpdatedAt,
                suppressUserMessages: suppressUserMessages
            )
        }
        guard blocks.isEmpty == false else {
            documentProjection.reset()
            return nil
        }
        return documentProjection.render(projectedBlocks: blocks)
    }

    private func projectedBlocks<Item: CodexChatLogProjectionItem>(
        from item: Item,
        turnStatus: CodexTurnStatus?,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?,
        suppressUserMessages: Bool
    ) -> [ReviewMonitorLogProjectedBlock] {
        switch item.content {
        case .message(let message):
            guard suppressUserMessages == false || message.role != .user else {
                return []
            }
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
                turnStatus: turnStatus
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
                            turnStatus: turnStatus
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
                        status: turnStatus?.rawValue
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
                        status: itemStatus(for: item, turnStatus: turnStatus).rawValue
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
                        status: itemStatus(for: item, turnStatus: turnStatus).rawValue
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

    private func commandBlocks<Item: CodexChatLogProjectionItem>(
        item: Item,
        command: CodexCommand,
        turnStatus: CodexTurnStatus?
    ) -> [ReviewMonitorLogProjectedBlock] {
        let groupID = sourceBlockID(for: item)
        let metadata = commandMetadata(
            item: item,
            command: command,
            turnStatus: turnStatus
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
                        turnStatus: turnStatus
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
                ReviewMonitorLogProjectedBlock(
                    id: derivedBlockID(prefix: "commandOutput", item: item),
                    kind: .commandOutput,
                    groupID: groupID,
                    text: output,
                    metadata: metadata
                ))
        }
        return blocks
    }

    private func webSearchBlocks<Item: CodexChatLogProjectionItem>(
        item: Item,
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

    private func toolCallBlocks<Item: CodexChatLogProjectionItem>(
        item: Item,
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

    private func projectedBlock<Item: CodexChatLogProjectionItem>(
        _ item: Item,
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

    private func derivedBlockID<Item: CodexChatLogProjectionItem>(
        prefix: String,
        item: Item
    ) -> ReviewMonitorLog.BlockID {
        ReviewMonitorLog.BlockID("\(prefix):\(sourceBlockID(for: item))")
    }

    private func sourceBlockID<Item: CodexChatLogProjectionItem>(for item: Item) -> String {
        let rawTurnID = item.projectionTurnID?.rawValue ?? "unknown-turn"
        return "\(rawTurnID):\(item.id)"
    }

    private func logKind<Item: CodexChatLogProjectionItem>(
        for item: Item,
        fallback: ReviewMonitorLog.Kind
    ) -> ReviewMonitorLog.Kind {
        ReviewMonitorLog.Kind(rawValue: item.kind.rawValue) ?? fallback
    }

    private func metadata<Item: CodexChatLogProjectionItem>(
        for item: Item,
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

    private func commandMetadata<Item: CodexChatLogProjectionItem>(
        item: Item,
        command: CodexCommand,
        turnStatus: CodexTurnStatus?
    ) -> ReviewMonitorLog.Metadata {
        let status = commandStatus(item: item, command: command, turnStatus: turnStatus)
        return .init(
            sourceType: "commandExecution",
            status: status,
            itemID: sourceBlockID(for: item),
            command: command.command,
            cwd: command.cwd,
            exitCode: command.exitCode,
            startedAt: command.startedAt,
            completedAt: command.completedAt,
            durationMs: command.durationMilliseconds,
            commandStatus: status
        )
    }

    private func outputOnlyCommandMetadata<Item: CodexChatLogProjectionItem>(
        item: Item,
        command: CodexCommand,
        turnStatus: CodexTurnStatus?
    ) -> ReviewMonitorLog.Metadata {
        guard
            command.cwd != nil || command.exitCode != nil || command.status != nil
                || command.startedAt != nil || command.completedAt != nil
                || command.durationMilliseconds != nil
        else {
            let status = itemStatus(for: item, turnStatus: turnStatus)
            return .init(
                sourceType: "command",
                title: "Command output",
                status: terminalStatus(status) ? status.rawValue : "completed"
            )
        }
        return commandMetadata(
            item: item,
            command: command,
            turnStatus: turnStatus
        )
    }

    private func commandStatus<Item: CodexChatLogProjectionItem>(
        item: Item,
        command: CodexCommand,
        turnStatus: CodexTurnStatus?
    ) -> String {
        let status = itemStatus(for: item, turnStatus: turnStatus)
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

    private func fileChangeStatus<Item: CodexChatLogProjectionItem>(
        item: Item,
        fileChange: CodexFileChange,
        turnStatus: CodexTurnStatus?
    ) -> String {
        let status = itemStatus(for: item, turnStatus: turnStatus)
        if terminalStatus(status) {
            return status.rawValue
        }
        return fileChange.status?.rawValue ?? status.rawValue
    }

    private func itemStatus<Item: CodexChatLogProjectionItem>(
        for item: Item,
        turnStatus: CodexTurnStatus?
    ) -> CodexTurnStatus {
        item.itemStatus ?? turnStatus ?? .running
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

@MainActor
private protocol CodexChatLogProjectionItem {
    var id: String { get }
    var projectionTurnID: CodexTurnID? { get }
    var kind: CodexThreadItem.Kind { get }
    var content: CodexThreadItem.Content { get }
    var itemStatus: CodexTurnStatus? { get }
}

extension CodexChat.Item: CodexChatLogProjectionItem {
    fileprivate var projectionTurnID: CodexTurnID? {
        turnID
    }

    var itemStatus: CodexTurnStatus? {
        content.reviewMonitorLogItemStatus
    }
}

@MainActor
private struct CodexChatModelLogItem: CodexChatLogProjectionItem {
    var item: CodexChat.Item
    var turnStatus: CodexTurnStatus?

    var id: String {
        item.id
    }

    var projectionTurnID: CodexTurnID? {
        item.turnID
    }

    var kind: CodexThreadItem.Kind {
        item.kind
    }

    var content: CodexThreadItem.Content {
        item.content
    }

    var itemStatus: CodexTurnStatus? {
        item.content.reviewMonitorLogItemStatus ?? turnStatus
    }
}

@MainActor
private struct CodexThreadSnapshotLogItem: CodexChatLogProjectionItem {
    var item: CodexThreadItem
    var turnID: CodexTurnID
    var turnStatus: CodexTurnStatus?

    var id: String {
        item.id
    }

    var projectionTurnID: CodexTurnID? {
        turnID
    }

    var kind: CodexThreadItem.Kind {
        item.kind
    }

    var content: CodexThreadItem.Content {
        item.content
    }

    var itemStatus: CodexTurnStatus? {
        item.content.reviewMonitorLogItemStatus ?? turnStatus
    }
}

private extension CodexThreadItem.Content {
    var reviewMonitorLogItemStatus: CodexTurnStatus? {
        switch self {
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
