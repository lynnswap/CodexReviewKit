import Foundation
import CodexReviewDomain

@MainActor
extension CodexReviewJob {
    package var timelineLogEntries: [ReviewLogEntry] {
        timeline.items.flatMap { ReviewLogEntry.projectingTimelineItem($0) }
    }
}

private extension ReviewLogEntry {
    @MainActor
    static func projectingTimelineItem(_ item: ReviewTimelineItem) -> [ReviewLogEntry] {
        switch item.content {
        case .message(let message):
            return [entry(item: item, kind: .agentMessage, text: message.text)]
        case .command(let command):
            var entries = [
                entry(
                    item: item,
                    kind: .command,
                    text: "$ \(command.command)",
                    metadata: commandMetadata(item: item, command: command)
                ),
            ]
            if command.output.isEmpty == false {
                entries.append(entry(
                    item: item,
                    kind: .commandOutput,
                    text: command.output,
                    metadata: commandMetadata(item: item, command: command)
                ))
            }
            return entries
        case .fileChange(let fileChange):
            return [entry(
                item: item,
                kind: .commandOutput,
                text: fileChange.output.isEmpty ? fileChange.title : fileChange.output,
                metadata: .init(
                    sourceType: "fileChange",
                    title: fileChange.title,
                    status: item.phase.rawValue,
                    itemID: item.id.rawValue
                )
            )]
        case .plan(let plan):
            return [entry(item: item, kind: legacyKind(for: item), text: plan.markdown)]
        case .reasoning(let reasoning):
            return [entry(
                item: item,
                kind: legacyKind(for: item, fallback: reasoning.style == .raw ? .rawReasoning : .reasoningSummary),
                text: reasoning.text
            )]
        case .toolCall(let toolCall):
            let label = [toolCall.namespace, toolCall.server, toolCall.tool]
                .compactMap { $0?.nilIfEmpty }
                .joined(separator: ".")
            let text = toolCall.error
                ?? toolCall.result
                ?? label.nilIfEmpty
                ?? "Tool call"
            return [entry(
                item: item,
                kind: .toolCall,
                text: text,
                metadata: .init(
                    sourceType: item.kind.rawValue,
                    title: label.nilIfEmpty,
                    status: item.phase.rawValue,
                    detail: toolCall.arguments,
                    itemID: item.id.rawValue,
                    namespace: toolCall.namespace,
                    server: toolCall.server,
                    tool: toolCall.tool,
                    resultText: toolCall.result,
                    errorText: toolCall.error
                )
            )]
        case .search(let search):
            return [entry(
                item: item,
                kind: .toolCall,
                text: search.result ?? "Web search: \(search.query)",
                metadata: .init(
                    sourceType: "webSearch",
                    title: "Web search",
                    status: item.phase.rawValue,
                    itemID: item.id.rawValue,
                    query: search.query,
                    resultText: search.result
                )
            )]
        case .contextCompaction(let contextCompaction):
            return [entry(item: item, kind: .contextCompaction, text: contextCompaction.title)]
        case .diagnostic(let diagnostic):
            return [entry(item: item, kind: legacyKind(for: item), text: diagnostic.message)]
        case .approval(let approval):
            return [entry(
                item: item,
                kind: .event,
                text: [approval.title, approval.detail].compactMap { $0 }.joined(separator: "\n")
            )]
        case .unknown(let unknown):
            return [entry(
                item: item,
                kind: legacyKind(for: item),
                text: [unknown.title, unknown.detail].compactMap { $0 }.joined(separator: "\n")
            )]
        }
    }

    @MainActor
    private static func entry(
        item: ReviewTimelineItem,
        kind: ReviewLogEntry.Kind,
        text: String,
        metadata: ReviewLogEntry.Metadata? = nil
    ) -> ReviewLogEntry {
        ReviewLogEntry(
            kind: kind,
            groupID: legacyGroupID(for: item, kind: kind),
            replacesGroup: false,
            text: text,
            metadata: metadata,
            timestamp: item.updatedAt
        )
    }

    @MainActor
    private static func legacyKind(
        for item: ReviewTimelineItem,
        fallback: ReviewLogEntry.Kind = .event
    ) -> ReviewLogEntry.Kind {
        ReviewLogEntry.Kind(rawValue: item.kind.rawValue) ?? fallback
    }

    @MainActor
    private static func legacyGroupID(
        for item: ReviewTimelineItem,
        kind: ReviewLogEntry.Kind
    ) -> String {
        let rawID = item.id.rawValue
        let prefix = "\(kind.rawValue):"
        guard rawID.hasPrefix(prefix) else {
            return rawID
        }
        return String(rawID.dropFirst(prefix.count))
    }

    @MainActor
    private static func commandMetadata(
        item: ReviewTimelineItem,
        command: ReviewTimelineItem.Command
    ) -> ReviewLogEntry.Metadata {
        .init(
            sourceType: "commandExecution",
            status: item.phase.rawValue,
            itemID: item.id.rawValue,
            command: command.command,
            cwd: command.cwd,
            exitCode: command.exitCode,
            startedAt: item.startedAt,
            completedAt: item.completedAt,
            durationMs: item.durationMs,
            commandStatus: item.phase.rawValue
        )
    }
}
