import Foundation
import CodexReviewDomain

@MainActor
extension CodexReviewJob {
    package func rebuildTimelineFromLogEntries(keepingTerminal: Bool = true) {
        guard usesDirectTimelineEvents == false else {
            return
        }
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

    package func trimTimelineTextContentToLogEntries() {
        guard directTimelineTextItemIDs.isEmpty == false
            || legacyProjectedTimelineTextItemIDs.isEmpty == false else {
            return
        }
        var textByItemID: [ReviewTimelineItem.ID: String] = [:]
        for entry in logEntries {
            guard let retainedTimelineText = entry.retainedTimelineText else {
                continue
            }
            for itemID in directTimelineTextCandidateIDs(for: entry) {
                if entry.shouldAppendRetainedTimelineText {
                    textByItemID[itemID, default: ""] += retainedTimelineText
                } else {
                    textByItemID[itemID] = retainedTimelineText
                }
            }
        }
        for itemID in directTimelineTextItemIDs {
            let text: String
            if let retainedText = textByItemID[itemID] {
                text = retainedText
            } else if directTimelineTextItemIDsWithCompatibilityLog.contains(itemID) {
                text = ""
            } else {
                continue
            }
            guard let item = timeline.item(for: itemID),
                  let trimmedContent = item.content.replacingTimelineText(text)
            else {
                continue
            }
            timeline.updateItemContent(trimmedContent, for: itemID)
        }
        for itemID in legacyProjectedTimelineTextItemIDs {
            guard let item = timeline.item(for: itemID),
                  let trimmedContent = item.content.replacingTimelineText(textByItemID[itemID] ?? "")
            else {
                continue
            }
            timeline.updateItemContent(trimmedContent, for: itemID)
        }
    }

    private func directTimelineTextCandidateIDs(for entry: ReviewLogEntry) -> [ReviewTimelineItem.ID] {
        var ids = entry.directTimelineTextCandidateIDs
        if let compatibilityItemIDs = directTimelineTextCompatibilityItemIDsByLogEntryID[entry.id] {
            ids.append(contentsOf: compatibilityItemIDs)
        }
        var seen: Set<ReviewTimelineItem.ID> = []
        return ids.filter { seen.insert($0).inserted }
    }
}

package extension ReviewLogEntry {
    var retainedTimelineText: String? {
        guard canProvideDirectTimelineText else {
            return nil
        }
        switch timelineItemFamily {
        case .fileChange:
            return kind == .commandOutput ? text : nil
        case .search:
            if metadata?.resultText == text {
                return text
            }
            return metadata?.sourceType == "webSearch" ? nil : text
        case .tool:
            if metadata?.resultText == text || metadata?.errorText == text {
                return text
            }
            return metadata?.resultText == nil && metadata?.errorText == nil ? text : nil
        case .approval,
             .command,
             .contextCompaction,
             .diagnostic,
             .lifecycle,
             .message,
             .plan,
             .reasoning,
             .unknown:
            return text
        }
    }

    var canProvideDirectTimelineText: Bool {
        switch kind {
        case .agentMessage,
             .commandOutput,
             .diagnostic,
             .error,
             .event,
             .plan,
             .progress,
             .rawReasoning,
             .reasoning,
             .reasoningSummary,
             .todoList,
             .toolCall:
            true
        case .command,
             .contextCompaction:
            false
        }
    }

    var directTimelineTextCandidateIDs: [ReviewTimelineItem.ID] {
        var ids: [ReviewTimelineItem.ID] = []
        if let rawID = metadata?.itemID?.nilIfEmpty ?? groupID?.nilIfEmpty {
            ids.append(.init(rawValue: rawID))
            if kind == .rawReasoning,
               let directRawReasoningID = rawID.rawReasoningDirectTimelineItemID {
                ids.append(.init(rawValue: directRawReasoningID))
            }
            if kind == .todoList {
                ids.append(.init(rawValue: "\(rawID):turn/plan/updated"))
            }
            if isMCPToolProgressCompatibilityLog {
                ids.append(.init(rawValue: "\(rawID):progress"))
            }
        }
        ids.append(timelineItemID)
        var seen: Set<ReviewTimelineItem.ID> = []
        return ids.filter { seen.insert($0).inserted }
    }

    var isMCPToolProgressCompatibilityLog: Bool {
        kind == .toolCall
            && metadata?.sourceType == "mcpToolCall"
            && metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines) == "Tool progress"
    }

    var shouldAppendRetainedTimelineText: Bool {
        shouldApplyAsTimelineDelta || (kind == .commandOutput && replacesGroup == false)
    }

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
        case .commandOutput:
            return metadata == nil
        case .command, .toolCall, .diagnostic, .error, .progress, .event, .contextCompaction:
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
            let errorText = metadata?.errorText
            return .toolCall(.init(
                namespace: metadata?.namespace,
                server: metadata?.server,
                tool: metadata?.tool,
                arguments: metadata?.detail,
                result: metadata?.resultText ?? (errorText == nil ? text.nilIfEmpty : nil),
                error: errorText
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
                ?? ""
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
    func replacingTimelineText(_ text: String) -> Self? {
        switch self {
        case .command(var command):
            command.output = text
            return .command(command)
        case .diagnostic(var diagnostic):
            diagnostic.message = text
            return .diagnostic(diagnostic)
        case .fileChange(var fileChange):
            fileChange.output = text
            return .fileChange(fileChange)
        case .message:
            return .message(.init(text: text))
        case .plan:
            return .plan(.init(markdown: text))
        case .reasoning(let reasoning):
            return .reasoning(.init(text: text, style: reasoning.style))
        case .search(var search):
            search.result = text.nilIfEmpty
            return .search(search)
        case .toolCall(var toolCall):
            if toolCall.progress != nil {
                toolCall.progress = text
            } else if toolCall.error != nil {
                toolCall.error = text
            } else {
                toolCall.result = text
            }
            return .toolCall(toolCall)
        case .approval, .contextCompaction, .unknown:
            return nil
        }
    }
}

private extension String {
    var rawReasoningDirectTimelineItemID: String? {
        guard let separator = lastIndex(of: ":") else {
            return nil
        }
        let contentIndex = self[index(after: separator)...]
        guard contentIndex.isEmpty == false,
              contentIndex.allSatisfy(\.isNumber)
        else {
            return nil
        }
        return "\(self[..<separator]):content:\(contentIndex)"
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
