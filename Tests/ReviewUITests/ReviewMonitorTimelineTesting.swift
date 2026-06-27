import Foundation
import Testing
@_spi(Testing) @testable import CodexReviewKit
import ReviewMonitorRendering
@_spi(PreviewSupport) @testable import ReviewUI

struct ReviewTimelineEntryForTesting: Sendable, Hashable {
    enum Kind: String, Sendable, Hashable {
        case command
        case commandOutput
        case agentMessage
        case plan
        case todoList
        case reasoning
        case reasoningSummary
        case rawReasoning
        case contextCompaction
        case toolCall
        case diagnostic
        case error
        case progress
        case event
    }

    struct Metadata: Sendable, Hashable {
        var sourceType: String?
        var title: String?
        var status: String?
        var itemID: String?
        var command: String?
        var cwd: String?
        var exitCode: Int?
        var startedAt: Date?
        var completedAt: Date?
        var durationMs: Int?
        var commandStatus: String?

        init(
            sourceType: String? = nil,
            title: String? = nil,
            status: String? = nil,
            itemID: String? = nil,
            command: String? = nil,
            cwd: String? = nil,
            exitCode: Int? = nil,
            startedAt: Date? = nil,
            completedAt: Date? = nil,
            durationMs: Int? = nil,
            commandStatus: String? = nil
        ) {
            self.sourceType = sourceType
            self.title = title
            self.status = status
            self.itemID = itemID
            self.command = command
            self.cwd = cwd
            self.exitCode = exitCode
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.durationMs = durationMs
            self.commandStatus = commandStatus
        }
    }

    var id: UUID
    var kind: Kind
    var groupID: String?
    var replacesGroup: Bool
    var text: String
    var metadata: Metadata?

    init(
        id: UUID = UUID(),
        kind: Kind,
        groupID: String? = nil,
        replacesGroup: Bool = false,
        text: String,
        metadata: Metadata? = nil
    ) {
        self.id = id
        self.kind = kind
        self.groupID = groupID
        self.replacesGroup = replacesGroup
        self.text = text
        self.metadata = metadata
    }
}

extension CodexReviewJob {
    @MainActor
    static func makeForTesting(
        id: String = UUID().uuidString,
        sessionID: String = "session-1",
        cwd: String = "/tmp/repo",
        targetSummary: String,
        model: String? = "gpt-5",
        threadID: String? = nil,
        turnID: String? = nil,
        status: ReviewJobState,
        cancellationRequested: Bool = false,
        cancellation: ReviewCancellation? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        summary: String,
        hasFinalReview: Bool = false,
        reviewResult: ParsedReviewResult? = nil,
        lastAgentMessage: String? = "",
        timelineEntries: [ReviewTimelineEntryForTesting],
        errorMessage: String? = nil,
        exitCode: Int? = nil
    ) -> CodexReviewJob {
        let job = CodexReviewJob.makeForTesting(
            id: id,
            sessionID: sessionID,
            cwd: cwd,
            targetSummary: targetSummary,
            model: model,
            threadID: threadID,
            turnID: turnID,
            status: status,
            cancellationRequested: cancellationRequested,
            cancellation: cancellation,
            startedAt: startedAt,
            endedAt: endedAt,
            summary: summary,
            hasFinalReview: hasFinalReview,
            reviewResult: reviewResult,
            lastAgentMessage: lastAgentMessage,
            errorMessage: errorMessage,
            exitCode: exitCode
        )
        seedTimelineForTesting(job, entries: timelineEntries)
        return job
    }
}

@MainActor
func seedTimelineForTesting(
    _ job: CodexReviewJob,
    logText: String = "",
    rawLogText: String = ""
) {
    let trimmedLogText = logText.trimmingCharacters(in: .newlines)
    if trimmedLogText.isEmpty == false {
        job.timeline.apply(
            .itemCompleted(
                .init(
                    id: .init(rawValue: "fixture-log-\(job.id)"),
                    kind: .agentMessage,
                    family: .message,
                    phase: .completed,
                    content: .message(.init(text: trimmedLogText))
                )))
    }

    for (index, line) in rawLogText.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        job.timeline.apply(
            .itemCompleted(
                .init(
                    id: .init(rawValue: "fixture-diagnostic-\(job.id)-\(index)"),
                    kind: .dynamicToolCall,
                    family: .diagnostic,
                    phase: .completed,
                    content: .diagnostic(.init(message: String(line)))
                )))
    }
}

@MainActor
func seedTimelineForTesting(_ job: CodexReviewJob, entries: [ReviewTimelineEntryForTesting]) {
    guard job.timeline.items.isEmpty else {
        return
    }
    for entry in entries {
        appendTimelineEntryForTesting(job, entry)
    }
}

@MainActor
func appendTimelineEntryForTesting(_ job: CodexReviewJob, _ entry: ReviewTimelineEntryForTesting) {
    let itemID = ReviewTimelineItem.ID(rawValue: entry.groupID ?? entry.id.uuidString)
    let existingContent = entry.replacesGroup ? nil : job.timeline.item(for: itemID)?.content
    let phase = timelinePhase(for: entry)
    let seed = ReviewTimelineItemSeed(
        id: itemID,
        kind: timelineKind(for: entry),
        family: timelineFamily(for: entry),
        phase: phase,
        content: timelineContent(for: entry, existing: existingContent),
        startedAt: entry.metadata?.startedAt,
        completedAt: entry.metadata?.completedAt,
        durationMs: entry.metadata?.durationMs
    )
    job.timeline.apply(phase.isTerminal ? .itemCompleted(seed) : .itemUpdated(seed))
}

@MainActor
func replaceTimelineLogTextForTesting(_ job: CodexReviewJob, _ text: String) {
    job.timeline.apply(
        .itemUpdated(
            .init(
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
    let sourceDocument = projection.render(timelineDocument: timelineDocument)
    let displayDocument = ReviewMonitorCommandOutputDisplayDocument.make(from: sourceDocument)
    return ReviewMonitorCommandOutputDisplayDocument.userVisibleText(from: displayDocument.text)
}

@MainActor
@discardableResult
func renderTimelineForTesting(
    _ job: CodexReviewJob,
    in transport: ReviewMonitorTransportViewController,
    restoring restorationTarget: ReviewMonitorLogScrollView.ScrollRestorationTarget? = nil,
    allowIncrementalUpdate: Bool
) throws -> Bool {
    let timelineDocument = ReviewTimelineDocumentRenderer().document(from: job.timeline)
    let target = try timelineRenderTarget(for: job)
    let sourceDocument = TimelineLogProjectionStore.document(
        from: timelineDocument,
        transport: transport,
        target: target
    )
    return transport.renderLogDocumentForTesting(
        sourceDocument,
        target: target,
        restoring: restorationTarget,
        allowIncrementalUpdate: allowIncrementalUpdate
    )
}

@MainActor
func awaitTimelineRenderForTesting(
    _ job: CodexReviewJob,
    in transport: ReviewMonitorTransportViewController,
    restoring restorationTarget: ReviewMonitorLogScrollView.ScrollRestorationTarget? = nil,
    allowIncrementalUpdate: Bool = true,
    timeout: Duration = .seconds(2),
    matching predicate: (@Sendable (ReviewMonitorTransportViewController.RenderSnapshotForTesting) -> Bool)? = nil
) async throws -> ReviewMonitorTransportViewController.RenderSnapshotForTesting {
    let expectedLog = reviewMonitorLogText(for: job)
    let expectedTarget = try timelineRenderTarget(for: job)
    try await waitForCondition(timeout: timeout) {
        transport.renderedStateForTesting.selection == expectedTarget
            && transport.renderedStateForTesting.snapshot.isShowingEmptyState == false
    }
    _ = try renderTimelineForTesting(
        job,
        in: transport,
        restoring: restorationTarget,
        allowIncrementalUpdate: allowIncrementalUpdate
    )
    return try await awaitTransportRender(transport, timeout: timeout) { snapshot in
        if let predicate {
            return predicate(snapshot)
        }
        return snapshot.log == expectedLog
    }
}

@MainActor
private func timelineRenderTarget(for job: CodexReviewJob) throws -> ReviewMonitorTransportViewController.DisplayedSelectionForTesting {
    let chatID = try #require(job.reviewChatID)
    return .chat(chatID.rawValue)
}

@MainActor
private enum TimelineLogProjectionStore {
    private struct Key: Hashable {
        var transportID: ObjectIdentifier
        var targetID: String
    }

    private static var projectionsByKey: [Key: ReviewMonitorTimelineLogProjection] = [:]

    static func document(
        from timelineDocument: ReviewTimelineDocument,
        transport: ReviewMonitorTransportViewController,
        target: ReviewMonitorTransportViewController.DisplayedSelectionForTesting
    ) -> ReviewMonitorLog.Document {
        let key = Key(transportID: ObjectIdentifier(transport), targetID: target.projectionStoreID)
        var projection = projectionsByKey[key] ?? ReviewMonitorTimelineLogProjection()
        let document = projection.render(timelineDocument: timelineDocument)
        projectionsByKey[key] = projection
        return document
    }
}

private extension ReviewMonitorTransportViewController.DisplayedSelectionForTesting {
    var projectionStoreID: String {
        switch self {
        case .workspaceSection(let id):
            "workspaceSection:\(id)"
        case .workspace(let id):
            "workspace:\(id)"
        case .chat(let id):
            "chat:\(id)"
        }
    }
}

private func timelineKind(for entry: ReviewTimelineEntryForTesting) -> ReviewItemKind {
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

private func timelineFamily(for entry: ReviewTimelineEntryForTesting) -> ReviewItemFamily {
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
    for entry: ReviewTimelineEntryForTesting,
    existing: ReviewTimelineItem.Content?
) -> ReviewTimelineItem.Content {
    switch entry.kind {
    case .command:
        return .command(
            .init(
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
        return .command(
            .init(
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
        return .contextCompaction(
            .init(
                title: entry.text,
                status: contextCompactionStatus(for: entry)
            ))
    case .toolCall:
        return .toolCall(
            .init(
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

private func commandText(for entry: ReviewTimelineEntryForTesting) -> String {
    if let command = entry.metadata?.command, command.isEmpty == false {
        return command
    }
    if entry.text.hasPrefix("$ ") {
        return String(entry.text.dropFirst(2))
    }
    return entry.text
}

private func timelinePhase(for entry: ReviewTimelineEntryForTesting) -> ReviewItemPhase {
    let status = entry.metadata?.commandStatus ?? entry.metadata?.status
    let normalizedStatus = ReviewItemPhase.normalized(status)
    if normalizedStatus.isTerminal {
        return normalizedStatus
    }
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

private func commandStatus(for entry: ReviewTimelineEntryForTesting) -> ReviewCommandStatus? {
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

private func contextCompactionStatus(for entry: ReviewTimelineEntryForTesting) -> ReviewContextCompactionStatus? {
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

private func toolCallStatus(for entry: ReviewTimelineEntryForTesting) -> ReviewToolCallStatus? {
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
