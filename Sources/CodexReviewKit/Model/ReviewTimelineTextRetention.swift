import Foundation

@MainActor
extension CodexReviewJob {
    package func trimTimelineTextContentToLogEntries() {
        guard directTimelineTextItemIDs.isEmpty == false else {
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
            } else if directTimelineTextItemIDsWithRetainedLogText.contains(itemID) {
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
    }

    package func syncTimelineTerminalStateFromCore() {
        guard core.lifecycle.status.isTerminal else {
            return
        }
        let timestamp = core.lifecycle.endedAt ?? logEntries.last?.timestamp ?? Date()
        switch core.lifecycle.status {
        case .succeeded:
            timeline.apply(
                .reviewCompleted(
                    summary: core.output.summary,
                    result: core.output.hasFinalReview ? core.output.lastAgentMessage?.nilIfEmpty : nil
                ),
                at: timestamp
            )
        case .failed:
            timeline.apply(.reviewFailed(core.lifecycle.errorMessage?.nilIfEmpty ?? core.output.summary), at: timestamp)
        case .cancelled:
            timeline.apply(
                .reviewCancelled(
                    core.lifecycle.cancellation?.message.nilIfEmpty
                        ?? core.lifecycle.errorMessage?.nilIfEmpty
                        ?? core.output.summary
                ),
                at: timestamp
            )
        case .queued, .running:
            break
        }
    }

    private func directTimelineTextCandidateIDs(for entry: ReviewLogEntry) -> [ReviewTimelineItem.ID] {
        var ids = entry.directTimelineTextCandidateIDs
        if let retainedTextItemIDs = retainedTimelineTextItemIDsByLogEntryID[entry.id] {
            ids.append(contentsOf: retainedTextItemIDs)
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
        switch directTimelineFamily {
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
        guard let rawID = metadata?.itemID?.nilIfEmpty ?? groupID?.nilIfEmpty else {
            return []
        }

        var ids: [ReviewTimelineItem.ID] = [.init(rawValue: rawID)]
        if kind == .rawReasoning,
           let directRawReasoningID = rawID.rawReasoningDirectTimelineItemID {
            ids.append(.init(rawValue: directRawReasoningID))
        }
        if kind == .todoList {
            ids.append(.init(rawValue: "\(rawID):turn/plan/updated"))
        }
        if isMCPToolProgressSummaryLog {
            ids.append(.init(rawValue: "\(rawID):progress"))
        }
        var seen: Set<ReviewTimelineItem.ID> = []
        return ids.filter { seen.insert($0).inserted }
    }

    var isMCPToolProgressSummaryLog: Bool {
        kind == .toolCall
            && metadata?.sourceType == "mcpToolCall"
            && metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines) == "Tool progress"
    }

    var shouldAppendRetainedTimelineText: Bool {
        guard replacesGroup == false else {
            return false
        }
        switch kind {
        case .agentMessage,
             .commandOutput,
             .plan,
             .rawReasoning,
             .reasoning,
             .reasoningSummary,
             .todoList:
            return true
        case .command,
             .contextCompaction,
             .diagnostic,
             .error,
             .event,
             .progress,
             .toolCall:
            return false
        }
    }

    private var directTimelineFamily: ReviewItemFamily {
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
