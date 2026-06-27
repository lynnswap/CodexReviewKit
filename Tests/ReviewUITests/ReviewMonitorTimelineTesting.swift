import Foundation
import CodexReviewKit
import ReviewMonitorRendering
@_spi(PreviewSupport) @testable import ReviewUI

@MainActor
func seedTimelineForTesting(
    _ job: CodexReviewJob,
    logText: String = "",
    rawLogText: String = ""
) {
    let trimmedLogText = logText.trimmingCharacters(in: .newlines)
    if trimmedLogText.isEmpty == false {
        job.timeline.apply(.itemCompleted(.init(
            id: .init(rawValue: "fixture-log-\(job.id)"),
            kind: .agentMessage,
            family: .message,
            phase: .completed,
            content: .message(.init(text: trimmedLogText))
        )))
    }

    for (index, line) in rawLogText.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        job.timeline.apply(.itemCompleted(.init(
            id: .init(rawValue: "fixture-diagnostic-\(job.id)-\(index)"),
            kind: .dynamicToolCall,
            family: .diagnostic,
            phase: .completed,
            content: .diagnostic(.init(message: String(line)))
        )))
    }
}

@MainActor
func seedTimelineForTesting(_ job: CodexReviewJob, logEntries: [ReviewLogEntry]) {
    guard job.timeline.items.isEmpty else {
        return
    }
    for entry in logEntries {
        appendTimelineLogEntryForTesting(job, entry)
    }
}

@MainActor
func appendTimelineLogEntryForTesting(_ job: CodexReviewJob, _ entry: ReviewLogEntry) {
    let itemID = ReviewTimelineItem.ID(rawValue: entry.groupID ?? entry.id.uuidString)
    let existingContent = entry.replacesGroup ? nil : job.timeline.item(for: itemID)?.content
    let phase = timelinePhase(for: entry)
    job.timeline.apply(.itemUpdated(.init(
        id: itemID,
        kind: timelineKind(for: entry),
        family: timelineFamily(for: entry),
        phase: phase,
        content: timelineContent(for: entry, existing: existingContent),
        startedAt: entry.metadata?.startedAt,
        completedAt: entry.metadata?.completedAt,
        durationMs: entry.metadata?.durationMs
    )))
}

@MainActor
func replaceTimelineLogTextForTesting(_ job: CodexReviewJob, _ text: String) {
    job.timeline.apply(.itemUpdated(.init(
        id: .init(rawValue: "fixture-log-\(job.id)"),
        kind: .agentMessage,
        family: .message,
        phase: .completed,
        content: .message(.init(text: text.trimmingCharacters(in: .newlines)))
    )))
}

@MainActor
func reviewMonitorLogText(for job: CodexReviewJob) -> String {
    var projection = ReviewMonitorTimelineLogProjection()
    let timelineDocument = ReviewTimelineDocumentRenderer().document(from: job.timeline)
    return projection.render(timelineDocument: timelineDocument).text
}

private func timelineKind(for entry: ReviewLogEntry) -> ReviewItemKind {
    switch entry.kind {
    case .command, .commandOutput:
        .commandExecution
    case .agentMessage:
        .agentMessage
    case .plan, .todoList:
        .plan
    case .reasoning, .reasoningSummary, .rawReasoning:
        .reasoning
    case .contextCompaction:
        .contextCompaction
    case .toolCall:
        .mcpToolCall
    case .diagnostic, .error, .progress, .event:
        ReviewItemKind(rawValue: entry.kind.rawValue)
    }
}

private func timelineFamily(for entry: ReviewLogEntry) -> ReviewItemFamily {
    switch entry.kind {
    case .command, .commandOutput:
        .command
    case .agentMessage:
        .message
    case .plan, .todoList:
        .plan
    case .reasoning, .reasoningSummary, .rawReasoning:
        .reasoning
    case .contextCompaction:
        .contextCompaction
    case .toolCall:
        .tool
    case .diagnostic, .error, .progress, .event:
        .diagnostic
    }
}

private func timelineContent(
    for entry: ReviewLogEntry,
    existing: ReviewTimelineItem.Content?
) -> ReviewTimelineItem.Content {
    switch entry.kind {
    case .command:
        return .command(.init(
            command: commandText(for: entry),
            cwd: entry.metadata?.cwd,
            output: "",
            exitCode: entry.metadata?.exitCode,
            status: commandStatus(for: entry),
            durationMs: entry.metadata?.durationMs
        ))
    case .commandOutput:
        let existingOutput: String
        let existingCommand: String?
        if case .command(let command) = existing {
            existingOutput = command.output
            existingCommand = command.command
        } else {
            existingOutput = ""
            existingCommand = nil
        }
        return .command(.init(
            command: entry.metadata?.command ?? existingCommand ?? "Command",
            cwd: entry.metadata?.cwd,
            output: existingOutput + entry.text,
            exitCode: entry.metadata?.exitCode,
            status: commandStatus(for: entry),
            durationMs: entry.metadata?.durationMs
        ))
    case .agentMessage:
        return .message(.init(text: existingText(existing, message: "") + entry.text))
    case .plan, .todoList:
        return .plan(.init(markdown: existingText(existing, plan: "") + entry.text))
    case .reasoning:
        return .reasoning(.init(text: existingText(existing, reasoning: "") + entry.text, style: .raw))
    case .reasoningSummary:
        return .reasoning(.init(text: existingText(existing, reasoning: "") + entry.text, style: .summary))
    case .rawReasoning:
        return .reasoning(.init(text: existingText(existing, reasoning: "") + entry.text, style: .raw))
    case .contextCompaction:
        return .contextCompaction(.init(
            title: entry.text,
            status: contextCompactionStatus(for: entry)
        ))
    case .toolCall:
        return .toolCall(.init(
            result: entry.text,
            status: toolCallStatus(for: entry)
        ))
    case .diagnostic, .error, .progress, .event:
        return .diagnostic(.init(message: existingText(existing, diagnostic: "") + entry.text))
    }
}

private func existingText(_ content: ReviewTimelineItem.Content?, message defaultValue: String) -> String {
    if case .message(let message) = content {
        return message.text
    }
    return defaultValue
}

private func existingText(_ content: ReviewTimelineItem.Content?, plan defaultValue: String) -> String {
    if case .plan(let plan) = content {
        return plan.markdown
    }
    return defaultValue
}

private func existingText(_ content: ReviewTimelineItem.Content?, reasoning defaultValue: String) -> String {
    if case .reasoning(let reasoning) = content {
        return reasoning.text
    }
    return defaultValue
}

private func existingText(_ content: ReviewTimelineItem.Content?, diagnostic defaultValue: String) -> String {
    if case .diagnostic(let diagnostic) = content {
        return diagnostic.message
    }
    return defaultValue
}

private func commandText(for entry: ReviewLogEntry) -> String {
    if let command = entry.metadata?.command, command.isEmpty == false {
        return command
    }
    if entry.text.hasPrefix("$ ") {
        return String(entry.text.dropFirst(2))
    }
    return entry.text
}

private func timelinePhase(for entry: ReviewLogEntry) -> ReviewItemPhase {
    let status = entry.metadata?.commandStatus ?? entry.metadata?.status
    switch status {
    case "inProgress", "running", "started":
        return .running
    case "failed":
        return .failed
    case "cancelled":
        return .cancelled
    default:
        return entry.kind == .command ? .running : .completed
    }
}

private func commandStatus(for entry: ReviewLogEntry) -> ReviewCommandStatus? {
    guard let rawValue = entry.metadata?.commandStatus ?? entry.metadata?.status else {
        return nil
    }
    switch rawValue {
    case "succeeded", "success":
        return .completed
    default:
        return .init(rawValue: rawValue)
    }
}

private func contextCompactionStatus(for entry: ReviewLogEntry) -> ReviewContextCompactionStatus? {
    guard let rawValue = entry.metadata?.status else {
        return nil
    }
    switch rawValue {
    case "inProgress", "running":
        return .inProgress
    case "completed", "succeeded", "success":
        return .completed
    default:
        return .init(rawValue: rawValue)
    }
}

private func toolCallStatus(for entry: ReviewLogEntry) -> ReviewToolCallStatus? {
    guard let rawValue = entry.metadata?.status else {
        return nil
    }
    switch rawValue {
    case "inProgress", "running":
        return .inProgress
    case "completed", "succeeded", "success":
        return .completed
    case "failed":
        return .failed
    default:
        return .init(rawValue: rawValue)
    }
}
