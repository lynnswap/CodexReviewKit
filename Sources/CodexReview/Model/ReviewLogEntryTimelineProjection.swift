import Foundation
import CodexReviewDomain

@MainActor
extension CodexReviewJob {
    package func rebuildTimelineFromLogEntries(keepingTerminal: Bool = true) {
        timeline.reset(keepingTerminal: keepingTerminal)
        for entry in logEntries {
            applyTimelineEntry(entry)
        }
    }

    package func applyTimelineEntry(_ entry: ReviewLogEntry) {
        let itemID = entry.timelineItemID
        let existing = timeline.item(for: itemID)
        let kind = entry.timelineItemKind
        let family = entry.timelineItemFamily
        let content = entry.timelineContent(existing: existing)

        if entry.shouldApplyAsTimelineDelta {
            timeline.apply(.textDelta(
                itemID: itemID,
                kind: kind,
                family: family,
                content: content.emptyTextContent,
                delta: entry.text
            ), at: entry.timestamp)
            return
        }

        let seed = ReviewTimelineItemSeed(
            id: itemID,
            kind: kind,
            family: family,
            phase: entry.timelinePhase,
            content: content,
            startedAt: entry.metadata?.startedAt,
            completedAt: entry.metadata?.completedAt,
            durationMs: entry.metadata?.durationMs
        )

        if seed.phase.isTerminal {
            timeline.apply(.itemCompleted(seed), at: entry.timestamp)
        } else if existing == nil {
            timeline.apply(.itemStarted(seed), at: entry.timestamp)
        } else {
            timeline.apply(.itemUpdated(seed), at: entry.timestamp)
        }
    }
}

private extension ReviewLogEntry {
    var timelineItemID: ReviewTimelineItem.ID {
        let rawID: String = if shouldUseSemanticTimelineID {
            semanticTimelineItemID
        } else {
            "\(kind.rawValue):\(id.uuidString)"
        }
        return .init(rawValue: rawID)
    }

    var semanticTimelineItemID: String {
        let baseID = metadata?.itemID?.nilIfEmpty
            ?? groupID?.nilIfEmpty
            ?? "\(kind.rawValue):\(id.uuidString)"
        switch kind {
        case .command, .commandOutput:
            return baseID
        case .agentMessage, .plan, .todoList, .reasoning, .reasoningSummary, .rawReasoning, .toolCall, .diagnostic, .error, .progress, .event, .contextCompaction:
            return "\(kind.rawValue):\(baseID)"
        }
    }

    var timelineItemKind: ReviewItemKind {
        if let sourceType = metadata?.sourceType.nilIfEmpty {
            return .init(rawValue: sourceType)
        }

        switch kind {
        case .agentMessage:
            return .agentMessage
        case .command, .commandOutput:
            return .commandExecution
        case .plan, .todoList, .reasoning, .reasoningSummary, .rawReasoning:
            return .init(rawValue: kind.rawValue)
        case .toolCall:
            return .dynamicToolCall
        case .contextCompaction:
            return .contextCompaction
        case .diagnostic, .error, .progress, .event:
            return .init(rawValue: kind.rawValue)
        }
    }

    var timelineItemFamily: ReviewItemFamily {
        switch metadata?.sourceType {
        case "commandExecution":
            return .command
        case "fileChange":
            return .fileChange
        case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall":
            return .tool
        case "webSearch":
            return .search
        case "contextCompaction":
            return .contextCompaction
        default:
            break
        }

        switch kind {
        case .agentMessage:
            return .message
        case .command, .commandOutput:
            return .command
        case .plan, .todoList:
            return .plan
        case .reasoning, .reasoningSummary, .rawReasoning:
            return .reasoning
        case .toolCall:
            return .tool
        case .contextCompaction:
            return .contextCompaction
        case .diagnostic, .error, .progress, .event:
            return .diagnostic
        }
    }

    var timelinePhase: ReviewItemPhase {
        if kind == .error {
            return .failed
        }
        if metadata == nil, groupID?.nilIfEmpty == nil {
            return .completed
        }
        let rawStatus = metadata?.commandStatus ?? metadata?.status
        if let rawStatus {
            return ReviewItemPhase.normalized(rawStatus)
        }
        if replacesGroup {
            switch kind {
            case .agentMessage, .plan, .todoList, .reasoning, .reasoningSummary, .rawReasoning:
                return .completed
            default:
                break
            }
        }
        switch kind {
        case .diagnostic, .progress, .event:
            return .completed
        default:
            return .running
        }
    }

    var shouldApplyAsTimelineDelta: Bool {
        guard replacesGroup == false else {
            return false
        }
        guard groupID?.nilIfEmpty != nil || metadata?.itemID?.nilIfEmpty != nil else {
            return false
        }
        switch kind {
        case .agentMessage, .plan, .todoList, .reasoning, .reasoningSummary, .rawReasoning:
            return true
        case .command, .commandOutput, .toolCall, .diagnostic, .error, .progress, .event, .contextCompaction:
            return false
        }
    }

    var shouldUseSemanticTimelineID: Bool {
        if replacesGroup {
            return true
        }
        switch kind {
        case .agentMessage, .command, .commandOutput, .plan, .todoList, .reasoning, .reasoningSummary, .rawReasoning, .contextCompaction:
            return groupID?.nilIfEmpty != nil || metadata?.itemID?.nilIfEmpty != nil
        case .toolCall, .diagnostic, .error, .progress, .event:
            return false
        }
    }

    @MainActor
    func timelineContent(existing: ReviewTimelineItem?) -> ReviewTimelineItem.Content {
        switch timelineItemFamily {
        case .command:
            return .command(commandContent(existing: existing))
        case .fileChange:
            return .fileChange(fileChangeContent(existing: existing))
        case .message:
            return .message(.init(text: text))
        case .plan:
            return .plan(.init(markdown: text))
        case .reasoning:
            return .reasoning(.init(
                text: text,
                style: kind == .rawReasoning ? .raw : .summary
            ))
        case .tool:
            return .toolCall(.init(
                namespace: metadata?.namespace,
                server: metadata?.server,
                tool: metadata?.tool,
                arguments: metadata?.detail,
                result: metadata?.resultText ?? text.nilIfEmpty,
                error: metadata?.errorText
            ))
        case .search:
            return .search(.init(
                query: metadata?.query ?? text,
                result: metadata?.resultText
            ))
        case .contextCompaction:
            return .contextCompaction(.init(title: text))
        case .approval:
            return .approval(.init(title: metadata?.title ?? text, detail: metadata?.detail))
        case .diagnostic, .lifecycle:
            return .diagnostic(.init(message: text))
        case .unknown:
            return .unknown(.init(title: metadata?.title ?? kind.rawValue, detail: text.nilIfEmpty))
        }
    }

    @MainActor
    private func commandContent(existing: ReviewTimelineItem?) -> ReviewTimelineItem.Command {
        let existingCommand: ReviewTimelineItem.Command? = if case .command(let command) = existing?.content {
            command
        } else {
            nil
        }
        let commandText: String
        if kind == .commandOutput {
            commandText = metadata?.command?.nilIfEmpty
                ?? existingCommand?.command.nilIfEmpty
                ?? "Command"
        } else {
            commandText = metadata?.command?.nilIfEmpty
                ?? existingCommand?.command.nilIfEmpty
                ?? Self.commandText(from: text)
                ?? metadata?.title?.nilIfEmpty
                ?? "Command"
        }
        let output: String
        if kind == .commandOutput {
            output = replacesGroup ? text : (existingCommand?.output ?? "") + text
        } else {
            output = existingCommand?.output ?? ""
        }
        return .init(
            command: commandText,
            cwd: metadata?.cwd ?? existingCommand?.cwd,
            output: output,
            exitCode: metadata?.exitCode ?? existingCommand?.exitCode,
            actions: metadata?.commandActions?.map(ReviewTimelineItem.CommandAction.init) ?? existingCommand?.actions ?? []
        )
    }

    @MainActor
    private func fileChangeContent(existing: ReviewTimelineItem?) -> ReviewTimelineItem.FileChange {
        let existingFileChange: ReviewTimelineItem.FileChange? = if case .fileChange(let fileChange) = existing?.content {
            fileChange
        } else {
            nil
        }
        let title = metadata?.title?.nilIfEmpty
            ?? metadata?.path?.nilIfEmpty
            ?? existingFileChange?.title.nilIfEmpty
            ?? "File changes"
        let output: String
        if kind == .commandOutput {
            output = replacesGroup ? text : (existingFileChange?.output ?? "") + text
        } else {
            output = existingFileChange?.output ?? text
        }
        return .init(title: title, output: output)
    }

    private static func commandText(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$ ") else {
            return trimmed.nilIfEmpty
        }
        return String(trimmed.dropFirst(2)).nilIfEmpty
    }
}

private extension ReviewTimelineItem.CommandAction {
    init(_ action: ReviewLogEntry.Metadata.CommandAction) {
        self.init(
            kind: .init(rawValue: action.kind.rawValue),
            command: action.command,
            name: action.name,
            path: action.path,
            query: action.query
        )
    }
}

private extension ReviewTimelineItem.Content {
    var emptyTextContent: ReviewTimelineItem.Content {
        switch self {
        case .command(var command):
            command.output = ""
            return .command(command)
        case .fileChange(var fileChange):
            fileChange.output = ""
            return .fileChange(fileChange)
        case .message:
            return .message(.init(text: ""))
        case .plan:
            return .plan(.init(markdown: ""))
        case .reasoning(let reasoning):
            return .reasoning(.init(text: "", style: reasoning.style))
        case .diagnostic:
            return .diagnostic(.init(message: ""))
        case .approval, .contextCompaction, .search, .toolCall, .unknown:
            return self
        }
    }
}
