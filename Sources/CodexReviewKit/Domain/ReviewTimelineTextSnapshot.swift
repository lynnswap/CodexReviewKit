import Foundation

package struct ReviewTimelineTextSnapshot: Sendable, Equatable {
    package var timelineText: String
    package var rawTimelineText: String
}

package extension ReviewTimeline {
    @MainActor
    var textSnapshot: ReviewTimelineTextSnapshot {
        var timelineSegments: [String] = []
        var rawTimelineSegments: [String] = []

        for item in items {
            if let text = item.timelineTextSegment?.nilIfEmpty {
                timelineSegments.append(text)
            }
            if let text = item.rawTimelineTextSegment?.nilIfEmpty {
                rawTimelineSegments.append(text)
            }
        }

        if let terminalSummary = terminalSummary?.nilIfEmpty {
            timelineSegments.append(terminalSummary)
            rawTimelineSegments.append(terminalSummary)
        }
        if let terminalResult = terminalResult?.nilIfEmpty,
            terminalResult != terminalSummary
        {
            timelineSegments.append(terminalResult)
            rawTimelineSegments.append(terminalResult)
        }

        return .init(
            timelineText: timelineSegments.joined(separator: "\n\n"),
            rawTimelineText: rawTimelineSegments.joined(separator: "\n\n")
        )
    }
}

private extension ReviewTimelineItem {
    var timelineTextSegment: String? {
        switch content {
        case .approval(let approval):
            return [approval.title, approval.detail].compactMap { $0?.nilIfEmpty }.joined(separator: "\n")
        case .command(let command):
            return command.command.nilIfEmpty.map { command.phaseTitle(command: $0, phase: phase) }
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
            return search.result?.nilIfEmpty ?? search.query
        case .toolCall(let toolCall):
            return toolCall.error?.nilIfEmpty
                ?? toolCall.result?.nilIfEmpty
                ?? toolCall.progress?.nilIfEmpty
                ?? [toolCall.namespace, toolCall.server, toolCall.tool]
                    .compactMap { $0?.nilIfEmpty }
                    .joined(separator: ".")
                    .nilIfEmpty
        case .unknown(let unknown):
            return [unknown.title, unknown.detail].compactMap { $0?.nilIfEmpty }.joined(separator: "\n")
        }
    }

    var rawTimelineTextSegment: String? {
        switch content {
        case .command(let command):
            guard command.command.isEmpty == false else {
                return command.output
            }
            return command.output.isEmpty ? "$ \(command.command)" : "$ \(command.command)\n\(command.output)"
        case .fileChange(let fileChange):
            return fileChange.output.isEmpty ? fileChange.title : "\(fileChange.title)\n\(fileChange.output)"
        case .search(let search):
            return [search.query, search.result].compactMap { $0?.nilIfEmpty }.joined(separator: "\n")
        case .toolCall(let toolCall):
            return [
                [toolCall.namespace, toolCall.server, toolCall.tool]
                    .compactMap { $0?.nilIfEmpty }
                    .joined(separator: ".")
                    .nilIfEmpty,
                toolCall.progress?.nilIfEmpty,
                toolCall.result?.nilIfEmpty,
                toolCall.error?.nilIfEmpty,
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
        case .approval,
            .contextCompaction,
            .diagnostic,
            .message,
            .plan,
            .reasoning,
            .unknown:
            return timelineTextSegment
        }
    }
}

private extension ReviewTimelineItem.Command {
    func phaseTitle(command: String, phase: ReviewItemPhase) -> String {
        switch status {
        case .some(.completed):
            return "Ran \(command)"
        case .some(.failed):
            return "Command failed: \(command)"
        case .some(.cancelled):
            return "Command cancelled: \(command)"
        default:
            return phase.isTerminal ? "Ran \(command)" : "Running \(command)"
        }
    }
}
