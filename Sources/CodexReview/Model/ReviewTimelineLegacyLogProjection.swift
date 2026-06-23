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
            var entries: [ReviewLogEntry] = []
            let commandLine = commandLineText(for: command)
            if let commandLine {
                entries.append(entry(
                    item: item,
                    kind: .command,
                    text: "$ \(commandLine)",
                    metadata: commandMetadata(item: item, command: command)
                ))
            }
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
                ?? toolCall.progress
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
    private static func commandLineText(for command: ReviewTimelineItem.Command) -> String? {
        guard let commandLine = command.command.nilIfEmpty,
              isGenericCommandTitle(commandLine) == false
        else {
            return nil
        }
        return commandLine
    }

    @MainActor
    private static func isGenericCommandTitle(_ title: String) -> Bool {
        switch title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "command", "command output":
            return true
        default:
            return false
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
            id: stableLogEntryID(item: item, kind: kind),
            kind: kind,
            groupID: legacyGroupID(for: item, kind: kind),
            replacesGroup: false,
            text: text,
            metadata: metadata,
            timestamp: item.updatedAt
        )
    }

    @MainActor
    private static func stableLogEntryID(
        item: ReviewTimelineItem,
        kind: ReviewLogEntry.Kind
    ) -> UUID {
        deterministicUUID(for: "timeline-log:\(item.id.rawValue):\(kind.rawValue)")
    }

    private static func deterministicUUID(for key: String) -> UUID {
        var first = UInt64(0xcbf29ce484222325)
        var second = UInt64(0x84222325cbf29ce4)

        for byte in key.utf8 {
            first ^= UInt64(byte)
            first = first &* 0x100000001b3

            second ^= UInt64(byte) &+ 0x9e3779b97f4a7c15
            second = second &* 0x100000001b3
            second = (second << 13) | (second >> 51)
        }

        var uuid: uuid_t = (
            UInt8((first >> 56) & 0xff),
            UInt8((first >> 48) & 0xff),
            UInt8((first >> 40) & 0xff),
            UInt8((first >> 32) & 0xff),
            UInt8((first >> 24) & 0xff),
            UInt8((first >> 16) & 0xff),
            UInt8((first >> 8) & 0xff),
            UInt8(first & 0xff),
            UInt8((second >> 56) & 0xff),
            UInt8((second >> 48) & 0xff),
            UInt8((second >> 40) & 0xff),
            UInt8((second >> 32) & 0xff),
            UInt8((second >> 24) & 0xff),
            UInt8((second >> 16) & 0xff),
            UInt8((second >> 8) & 0xff),
            UInt8(second & 0xff)
        )
        uuid.6 = (uuid.6 & UInt8(0x0f)) | UInt8(0x50)
        uuid.8 = (uuid.8 & UInt8(0x3f)) | UInt8(0x80)
        return UUID(uuid: uuid)
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
        let commandActions = command.actions.map(ReviewLogEntry.Metadata.CommandAction.init)
        return .init(
            sourceType: "commandExecution",
            status: item.phase.rawValue,
            itemID: item.id.rawValue,
            command: commandLineText(for: command),
            cwd: command.cwd,
            exitCode: command.exitCode,
            startedAt: item.startedAt,
            completedAt: item.completedAt,
            durationMs: item.durationMs,
            commandActions: commandActions.isEmpty ? nil : commandActions,
            commandStatus: item.phase.rawValue
        )
    }
}

private extension ReviewLogEntry.Metadata.CommandAction {
    init(_ action: ReviewTimelineItem.CommandAction) {
        self.init(
            kind: .init(rawValue: action.kind.rawValue) ?? .unknown,
            command: action.command,
            name: action.name,
            path: action.path,
            query: action.query
        )
    }
}
