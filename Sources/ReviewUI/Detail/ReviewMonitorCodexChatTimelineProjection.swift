import CodexKit
import CodexReviewKit
import Foundation
import ReviewMonitorRendering

@MainActor
struct ReviewMonitorCodexChatTimelineProjection {
    func document(
        from turnSnapshot: CodexChatTurnSnapshot,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?,
        revision: UInt64
    ) -> ReviewTimelineDocument? {
        guard turnSnapshot.items.isEmpty == false else {
            return nil
        }

        let blocks = turnSnapshot.items.map {
            block(
                from: $0,
                turnSnapshot: turnSnapshot,
                chatCreatedAt: chatCreatedAt,
                chatUpdatedAt: chatUpdatedAt
            )
        }
        let activeBlockIDs = blocks.filter(\.isActive).map(\.id)
        return ReviewTimelineDocument(
            timelineRevision: .init(rawValue: revision),
            orderedBlockIDs: blocks.map(\.id),
            activeBlockIDs: activeBlockIDs,
            activeBlockCount: activeBlockIDs.count,
            latestActivityBlockID: blocks.last?.id,
            terminalStatus: terminalStatus(for: turnSnapshot),
            terminalSummary: turnSnapshot.errorDescription,
            terminalResult: nil,
            blocks: blocks
        )
    }

    private func block(
        from item: CodexChat.Item,
        turnSnapshot: CodexChatTurnSnapshot,
        chatCreatedAt: Date?,
        chatUpdatedAt: Date?
    ) -> ReviewTimelineDocument.Block {
        let content = content(from: item, turnSnapshot: turnSnapshot)
        let phase = phase(for: item, turnSnapshot: turnSnapshot)
        let blockID = blockID(for: item)
        let sourceItemID = ReviewTimelineItem.ID(rawValue: blockID.rawValue)
        let timestamp = chatUpdatedAt ?? chatCreatedAt ?? Date(timeIntervalSince1970: 0)
        return ReviewTimelineDocument.Block(
            id: blockID,
            sourceItemID: sourceItemID,
            kind: kind(for: item.kind),
            family: family(for: item),
            phase: phase,
            isActive: phase.isTerminal == false,
            primaryText: primaryText(for: content),
            rawTranscriptText: rawTranscriptText(for: content),
            content: content,
            createdAt: chatCreatedAt ?? timestamp,
            updatedAt: timestamp
        )
    }

    private func blockID(for item: CodexChat.Item) -> ReviewTimelineDocument.Block.ID {
        let rawTurnID = item.turnID?.rawValue ?? "unknown-turn"
        return .init(rawValue: "\(rawTurnID):\(item.id)")
    }

    private func kind(for kind: CodexThreadItem.Kind) -> ReviewItemKind {
        switch kind {
        case .agentMessage:
            return .agentMessage
        case .userMessage:
            return ReviewItemKind(rawValue: kind.rawValue)
        case .plan:
            return .plan
        case .reasoning:
            return .reasoning
        case .commandExecution:
            return .commandExecution
        case .fileChange:
            return .fileChange
        case .mcpToolCall:
            return .mcpToolCall
        case .dynamicToolCall:
            return .dynamicToolCall
        case .webSearch:
            return .webSearch
        case .imageGeneration:
            return .imageGeneration
        case .imageView:
            return .imageView
        case .contextCompaction:
            return .contextCompaction
        case .collabAgentToolCall, .subAgentActivity, .sleep, .diagnostic, .error, .unknown:
            return ReviewItemKind(rawValue: kind.rawValue)
        }
    }

    private func family(for item: CodexChat.Item) -> ReviewItemFamily {
        switch item.content {
        case .message:
            return .message
        case .plan:
            return .plan
        case .reasoning:
            return .reasoning
        case .command:
            return .command
        case .fileChange:
            return .fileChange
        case .toolCall:
            return item.kind == .webSearch ? .search : .tool
        case .contextCompaction:
            return .contextCompaction
        case .diagnostic, .log:
            return .diagnostic
        case .unknown:
            return .unknown
        }
    }

    private func content(
        from item: CodexChat.Item,
        turnSnapshot: CodexChatTurnSnapshot
    ) -> ReviewTimelineDocument.Content {
        switch item.content {
        case .message(let message):
            return .message(.init(text: message.text))
        case .plan(let markdown):
            return .plan(.init(markdown: markdown))
        case .reasoning(let reasoning):
            return .reasoning(
                .init(
                    text: reasoning.text,
                    style: reasoning.summary.isEmpty ? .raw : .summary
                ))
        case .command(let command):
            return .command(
                .init(
                    title: command.command,
                    command: command.command,
                    cwd: command.cwd,
                    output: command.output ?? "",
                    exitCode: command.exitCode,
                    status: commandStatus(for: command.status)
                ))
        case .fileChange(let fileChange):
            let title = fileChange.path ?? "File change"
            return .fileChange(
                .init(
                    title: title,
                    output: fileChange.output ?? "",
                    paths: fileChange.path.map { [$0] } ?? [],
                    status: fileChangeStatus(for: fileChange.status)
                ))
        case .toolCall(let toolCall):
            if item.kind == .webSearch {
                return .search(
                    .init(
                        query: toolCall.arguments ?? toolCall.name ?? "Web search",
                        result: toolCall.result ?? toolCall.error,
                        status: searchStatus(for: toolCall.status)
                    ))
            }
            return .toolCall(
                .init(
                    namespace: toolCall.namespace,
                    server: toolCall.server,
                    name: toolCall.name,
                    arguments: toolCall.arguments,
                    result: toolCall.result,
                    error: toolCall.error,
                    status: toolCallStatus(for: toolCall.status)
                ))
        case .contextCompaction(let text):
            return .contextCompaction(
                .init(
                    title: text ?? "Context compaction",
                    status: contextCompactionStatus(for: turnSnapshot.status)
                ))
        case .diagnostic(let message):
            return .diagnostic(
                .init(
                    message: message,
                    severity: item.kind == .error ? .error : nil
                ))
        case .log(let message):
            return .diagnostic(.init(message: message))
        case .unknown(let raw):
            return .unknown(
                .init(
                    title: raw.text ?? raw.rawType,
                    detail: raw.text,
                    rawKind: ReviewItemKind(rawValue: item.kind.rawValue),
                    rawStatus: item.itemStatus?.rawValue
                ))
        }
    }

    private func phase(
        for item: CodexChat.Item,
        turnSnapshot: CodexChatTurnSnapshot
    ) -> ReviewItemPhase {
        statusPhase(item.itemStatus ?? turnSnapshot.status)
    }

    private func terminalStatus(for turnSnapshot: CodexChatTurnSnapshot) -> ReviewLifecycleStatus? {
        switch turnSnapshot.status {
        case .completed:
            return .succeeded
        case .failed, .interrupted:
            return .failed
        case .cancelled:
            return .cancelled
        case .running, .unknown, nil:
            return nil
        }
    }

    private func statusPhase(_ status: CodexTurnStatus?) -> ReviewItemPhase {
        switch status {
        case .running:
            return .running
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .interrupted:
            return .incomplete
        case .cancelled:
            return .cancelled
        case .unknown(let rawValue):
            return .normalized(rawValue)
        case nil:
            return .running
        }
    }

    private func commandStatus(for status: CodexTurnStatus?) -> ReviewCommandStatus? {
        switch status {
        case .running:
            return .inProgress
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .interrupted, .cancelled:
            return .cancelled
        case .unknown(let rawValue):
            return .init(rawValue: rawValue)
        case nil:
            return nil
        }
    }

    private func toolCallStatus(for status: CodexTurnStatus?) -> ReviewToolCallStatus? {
        switch status {
        case .running:
            return .inProgress
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .interrupted, .cancelled:
            return .cancelled
        case .unknown(let rawValue):
            return .init(rawValue: rawValue)
        case nil:
            return nil
        }
    }

    private func fileChangeStatus(for status: CodexTurnStatus?) -> ReviewFileChangeStatus? {
        switch status {
        case .running:
            return .updated
        case .completed:
            return .completed
        case .failed, .interrupted, .cancelled:
            return .failed
        case .unknown(let rawValue):
            return .init(rawValue: rawValue)
        case nil:
            return nil
        }
    }

    private func searchStatus(for status: CodexTurnStatus?) -> ReviewSearchStatus? {
        switch status {
        case .running:
            return .started
        case .completed:
            return .completed
        case .failed, .interrupted, .cancelled:
            return .failed
        case .unknown(let rawValue):
            return .init(rawValue: rawValue)
        case nil:
            return nil
        }
    }

    private func contextCompactionStatus(for status: CodexTurnStatus?) -> ReviewContextCompactionStatus? {
        switch status {
        case .running:
            return .inProgress
        case .completed:
            return .completed
        case .failed, .interrupted, .cancelled:
            return .failed
        case .unknown(let rawValue):
            return .init(rawValue: rawValue)
        case nil:
            return nil
        }
    }

    private func primaryText(for content: ReviewTimelineDocument.Content) -> String {
        switch content {
        case .approval(let approval):
            return approval.title
        case .command(let command):
            return command.title
        case .contextCompaction(let contextCompaction):
            return contextCompaction.title
        case .diagnostic(let diagnostic):
            return diagnostic.message
        case .fileChange(let fileChange):
            return fileChange.title
        case .message(let message):
            return message.text
        case .plan(let plan):
            return plan.markdown
        case .reasoning(let reasoning):
            return reasoning.text
        case .search(let search):
            return search.query
        case .toolCall(let toolCall):
            return [toolCall.namespace, toolCall.server, toolCall.name]
                .compactMap { $0?.nilIfEmpty }
                .joined(separator: ".")
        case .unknown(let unknown):
            return unknown.title
        }
    }

    private func rawTranscriptText(for content: ReviewTimelineDocument.Content) -> String {
        switch content {
        case .approval(let approval):
            return [approval.title, approval.detail].compactMap { $0 }.joined(separator: "\n")
        case .command(let command):
            guard command.command.isEmpty == false else {
                return command.output
            }
            return command.output.isEmpty ? "$ \(command.command)" : "$ \(command.command)\n\(command.output)"
        case .contextCompaction(let contextCompaction):
            return contextCompaction.title
        case .diagnostic(let diagnostic):
            return diagnostic.message
        case .fileChange(let fileChange):
            return fileChange.output.isEmpty ? fileChange.title : "\(fileChange.title)\n\(fileChange.output)"
        case .message(let message):
            return message.text
        case .plan(let plan):
            return plan.markdown
        case .reasoning(let reasoning):
            return reasoning.text
        case .search(let search):
            return [search.query, search.result].compactMap { $0 }.joined(separator: "\n")
        case .toolCall(let toolCall):
            return [
                primaryText(for: content).nilIfEmpty,
                toolCall.progress?.nilIfEmpty,
                toolCall.result?.nilIfEmpty,
                toolCall.error?.nilIfEmpty,
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
        case .unknown(let unknown):
            return [unknown.title, unknown.detail].compactMap { $0 }.joined(separator: "\n")
        }
    }
}

private extension CodexChat.Item {
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
