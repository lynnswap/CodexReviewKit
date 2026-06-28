import Foundation
import Testing
import CodexKit
@_spi(Testing) @testable import CodexReviewKit
@_spi(PreviewSupport) @testable import ReviewUI

struct ReviewChatLogEntryForTesting: Sendable, Hashable {
    enum Kind: String, Sendable, Hashable {
        case command
        case commandOutput
        case fileChange
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
        chatEntries: [ReviewChatLogEntryForTesting] = [],
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
        ReviewChatLogFixtureStore.setEntries(chatEntries, for: job)
        return job
    }
}

@MainActor
func seedChatLogForTesting(
    _ job: CodexReviewJob,
    logText: String = "",
    rawLogText: String = ""
) {
    var entries: [ReviewChatLogEntryForTesting] = []
    let trimmedLogText = logText.trimmingCharacters(in: .newlines)
    if trimmedLogText.isEmpty == false {
        entries.append(.init(kind: .agentMessage, groupID: "fixture-log-\(job.id)", text: trimmedLogText))
    }
    for (index, line) in rawLogText.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        entries.append(
            .init(
                kind: .diagnostic,
                groupID: "fixture-diagnostic-\(job.id)-\(index)",
                text: String(line)
            ))
    }
    ReviewChatLogFixtureStore.setEntries(entries, for: job)
}

@MainActor
func appendChatLogEntryForTesting(_ job: CodexReviewJob, _ entry: ReviewChatLogEntryForTesting) {
    ReviewChatLogFixtureStore.append(entry, to: job)
}

@MainActor
func replaceChatLogTextForTesting(_ job: CodexReviewJob, _ text: String) {
    ReviewChatLogFixtureStore.replaceEntries(
        [.init(kind: .agentMessage, groupID: "fixture-log-\(job.id)", text: text.trimmingCharacters(in: .newlines))],
        for: job
    )
}

@MainActor
func installPreviewChatLogSourceForTesting(on store: CodexReviewStore, jobs: [CodexReviewJob]) {
    let fixtures = jobs.compactMap { try? makePreviewChatLogFixtureForTesting(job: $0) }
    let source = ReviewMonitorPreviewChatLogSource(fixtures: fixtures)
    store.previewSupportRetainer = ReviewMonitorPreviewRuntimeSupport(chatLogSource: source)
    jobStorePreviewSupportRetainers.append(
        ReviewChatLogFixtureRetainer(
            source: source,
            jobIDs: Set(jobs.map(\.id))
        ))
}

@MainActor
func reviewChatLogText(for job: CodexReviewJob) -> String {
    ReviewChatLogFixtureStore.logText(for: job)
}

@MainActor
func awaitChatRenderForTesting(
    _ job: CodexReviewJob,
    in transport: ReviewMonitorTransportViewController,
    allowIncrementalUpdate: Bool = true,
    timeout: Duration = .seconds(2),
    matching predicate: (@Sendable (ReviewMonitorTransportViewController.RenderSnapshotForTesting) -> Bool)? = nil
) async throws -> ReviewMonitorTransportViewController.RenderSnapshotForTesting {
    _ = allowIncrementalUpdate
    let expectedLog = reviewChatLogText(for: job)
    let expectedSelection: ReviewMonitorTransportViewController.DisplayedSelectionForTesting =
        .chat(chatIDForTesting(job).rawValue)
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    repeat {
        let state = transport.renderedStateForTesting
        let matchesSnapshot: Bool
        if let predicate {
            matchesSnapshot = predicate(state.snapshot)
        } else {
            matchesSnapshot = reviewChatRenderedLogMatches(state.snapshot.log, expectedLog)
        }
        if transport.logRenderIsIdleForTesting,
            state.selection == expectedSelection,
            matchesSnapshot
        {
            return state.snapshot
        }
        await Task.yield()
    } while clock.now < deadline

    let state = transport.renderedStateForTesting
    let matchesSnapshot: Bool
    if let predicate {
        matchesSnapshot = predicate(state.snapshot)
    } else {
        matchesSnapshot = reviewChatRenderedLogMatches(state.snapshot.log, expectedLog)
    }
    if transport.logRenderIsIdleForTesting,
        state.selection == expectedSelection,
        matchesSnapshot
    {
        return state.snapshot
    }
    throw TestFailure(
        "timed out waiting for selected chat render: "
            + "idle=\(transport.logRenderIsIdleForTesting), "
            + "actual=\(state), expectedSelection=\(expectedSelection), expectedLog=\(expectedLog)"
    )
}

func reviewChatRenderedLogMatches(_ actual: String, _ expected: String) -> Bool {
    actual == expected
        || actual.trimmingCharacters(in: .newlines) == expected.trimmingCharacters(in: .newlines)
}

@MainActor
func makePreviewChatLogSourceForTesting(
    job: CodexReviewJob,
    items makeItems: (CodexTurnID) -> [CodexChatItemSnapshot]
) throws -> ReviewMonitorPreviewChatLogSource {
    ReviewMonitorPreviewChatLogSource(
        fixtures: [try makePreviewChatLogFixtureForTesting(job: job, items: makeItems)]
    )
}

@MainActor
func makePreviewMessageItemForTesting(
    id: String,
    text: String,
    turnID: CodexTurnID
) -> CodexChatItemSnapshot {
    CodexChatItemSnapshot(
        id: id,
        turnID: turnID,
        kind: .agentMessage,
        content: .message(.init(id: id, role: .assistant, text: text))
    )
}

@MainActor
func chatCommandOutputBlockIDForTesting(
    _ job: CodexReviewJob,
    itemID: String
) -> ReviewMonitorLog.BlockID {
    ReviewMonitorLog.BlockID("commandOutput:\(job.previewTurnIDForTesting.rawValue):\(itemID)")
}

@MainActor
private func makePreviewChatLogFixtureForTesting(job: CodexReviewJob) throws -> ReviewMonitorPreviewChatLogFixture {
    try makePreviewChatLogFixtureForTesting(job: job) { _ in
        ReviewChatLogFixtureStore.items(for: job)
    }
}

@MainActor
private func makePreviewChatLogFixtureForTesting(
    job: CodexReviewJob,
    items makeItems: (CodexTurnID) -> [CodexChatItemSnapshot]
) throws -> ReviewMonitorPreviewChatLogFixture {
    let chat = try #require(job.reviewChatSelectionForTesting)
    let turn = CodexChatTurnStateSnapshot(
        id: job.previewTurnIDForTesting,
        status: CodexTurnStatus(reviewJobStateForTesting: job.core.lifecycle.status),
        errorDescription: job.core.lifecycle.errorMessage,
        usage: nil
    )
    let initialSnapshot = CodexChatSnapshot(
        chatID: chat.id,
        phase: CodexDataPhase(
            reviewJobStateForTesting: job.core.lifecycle.status,
            errorMessage: job.core.lifecycle.errorMessage
        ),
        turns: [turn],
        items: makeItems(turn.id)
    )
    return ReviewMonitorPreviewChatLogFixture(
        chat: chat,
        cwd: job.cwd,
        streamID: job.id,
        isRunning: job.core.lifecycle.status == .running,
        initialSnapshot: initialSnapshot
    )
}

@MainActor
private enum ReviewChatLogFixtureStore {
    private static var entriesByJobID: [String: [ReviewChatLogEntryForTesting]] = [:]

    static func setEntries(_ entries: [ReviewChatLogEntryForTesting], for job: CodexReviewJob) {
        entriesByJobID[job.id] = entries
    }

    static func replaceEntries(_ entries: [ReviewChatLogEntryForTesting], for job: CodexReviewJob) {
        setEntries(entries, for: job)
        updateRetainedPreviewSource(for: job)
    }

    static func append(_ entry: ReviewChatLogEntryForTesting, to job: CodexReviewJob) {
        entriesByJobID[job.id, default: []].append(entry)
        updateRetainedPreviewSource(for: job)
    }

    static func items(for job: CodexReviewJob) -> [CodexChatItemSnapshot] {
        makeChatItems(from: entriesByJobID[job.id, default: []], turnID: job.previewTurnIDForTesting)
    }

    static func logText(for job: CodexReviewJob) -> String {
        var projection = ReviewMonitorSelectedCodexChatLogProjection()
        var document: ReviewMonitorLog.Document?
        let snapshot = CodexChatSnapshot(
            chatID: chatIDForTesting(job),
            phase: .loaded,
            turns: [
                .init(
                    id: job.previewTurnIDForTesting,
                    status: CodexTurnStatus(reviewJobStateForTesting: job.core.lifecycle.status)
                )
            ],
            items: items(for: job)
        )
        for change in CodexChatChange.previewChangesForTesting(from: nil, to: snapshot) {
            document = projection.apply(
                change,
                chatCreatedAt: nil,
                chatUpdatedAt: job.core.lifecycle.endedAt
            )?.sourceDocument ?? document
        }
        guard let document else {
            return ""
        }
        let displayDocument = ReviewMonitorCommandOutputDisplayDocument.make(from: document)
        return ReviewMonitorCommandOutputDisplayDocument.userVisibleText(from: displayDocument.text)
    }

    private static func updateRetainedPreviewSource(for job: CodexReviewJob) {
        for support in jobStorePreviewSupportRetainers where support.contains(jobID: job.id) {
            support.upsert(job: job, items: items(for: job))
        }
    }
}

@MainActor
private final class ReviewChatLogFixtureRetainer {
    let source: ReviewMonitorPreviewChatLogSource
    private var jobIDs: Set<String>

    init(source: ReviewMonitorPreviewChatLogSource, jobIDs: Set<String>) {
        self.source = source
        self.jobIDs = jobIDs
    }

    func contains(jobID: String) -> Bool {
        jobIDs.contains(jobID)
    }

    func upsert(job: CodexReviewJob, items: [CodexChatItemSnapshot]) {
        guard let chatID = job.reviewChatIDForTesting else {
            return
        }
        for item in items {
            source.upsertPreviewItem(id: item.id, kind: item.kind, content: item.content, to: chatID)
        }
    }
}

@MainActor
private var jobStorePreviewSupportRetainers: [ReviewChatLogFixtureRetainer] = []

@MainActor
private func makeChatItems(
    from entries: [ReviewChatLogEntryForTesting],
    turnID: CodexTurnID
) -> [CodexChatItemSnapshot] {
    var accumulated: [String: ReviewChatLogAccumulatedItem] = [:]
    var orderedIDs: [String] = []
    for entry in entries {
        let itemID = entry.groupID ?? entry.id.uuidString
        let previous = entry.replacesGroup ? nil : accumulated[itemID]
        let next = ReviewChatLogAccumulatedItem(entry: entry, existing: previous, itemID: itemID, turnID: turnID)
        accumulated[itemID] = next
        if orderedIDs.contains(itemID) == false {
            orderedIDs.append(itemID)
        }
    }
    return orderedIDs.compactMap { accumulated[$0]?.snapshot }
}

private struct ReviewChatLogAccumulatedItem {
    var snapshot: CodexChatItemSnapshot

    init(
        entry: ReviewChatLogEntryForTesting,
        existing: ReviewChatLogAccumulatedItem?,
        itemID: String,
        turnID: CodexTurnID
    ) {
        let status = codexTurnStatus(for: entry)
        switch entry.kind {
        case .command:
            snapshot = .init(
                id: itemID,
                turnID: turnID,
                kind: .commandExecution,
                content: .command(
                    .init(
                        command: chatLogCommandText(for: entry),
                        cwd: entry.metadata?.cwd,
                        output: existing?.commandOutput ?? "",
                        exitCode: entry.metadata?.exitCode,
                        status: status
                    ))
            )
        case .commandOutput:
            snapshot = .init(
                id: itemID,
                turnID: turnID,
                kind: .commandExecution,
                content: .command(
                    .init(
                        command: entry.metadata?.command ?? existing?.commandText ?? "Command",
                        cwd: entry.metadata?.cwd ?? existing?.commandCWD,
                        output: (existing?.commandOutput ?? "") + entry.text,
                        exitCode: entry.metadata?.exitCode ?? existing?.commandExitCode,
                        status: status ?? existing?.commandStatus
                    ))
            )
        case .fileChange:
            snapshot = .init(
                id: itemID,
                turnID: turnID,
                kind: .fileChange,
                content: .fileChange(
                    .init(
                        path: entry.metadata?.title,
                        output: (existing?.plainText ?? "") + entry.text,
                        status: status
                    ))
            )
        case .agentMessage:
            snapshot = .init(
                id: itemID,
                turnID: turnID,
                kind: .agentMessage,
                content: .message(
                    .init(
                        id: itemID,
                        role: .assistant,
                        text: (existing?.messageText ?? "") + entry.text
                    ))
            )
        case .plan, .todoList:
            snapshot = .init(
                id: itemID,
                turnID: turnID,
                kind: entry.kind == .todoList ? .init(rawValue: "todoList") : .plan,
                content: .plan((existing?.plainText ?? "") + entry.text)
            )
        case .reasoning, .rawReasoning:
            snapshot = .init(
                id: itemID,
                turnID: turnID,
                kind: entry.kind == .rawReasoning ? .init(rawValue: "rawReasoning") : .reasoning,
                content: .reasoning(.init(content: (existing?.reasoningText ?? "") + entry.text))
            )
        case .reasoningSummary:
            snapshot = .init(
                id: itemID,
                turnID: turnID,
                kind: .init(rawValue: "reasoningSummary"),
                content: .reasoning(.init(summary: (existing?.reasoningText ?? "") + entry.text))
            )
        case .contextCompaction:
            snapshot = .init(
                id: itemID,
                turnID: turnID,
                kind: .contextCompaction,
                content: .contextCompaction(entry.text)
            )
        case .toolCall:
            snapshot = .init(
                id: itemID,
                turnID: turnID,
                kind: .mcpToolCall,
                content: .toolCall(.init(result: (existing?.toolResult ?? "") + entry.text, status: status))
            )
        case .diagnostic, .error, .progress, .event:
            snapshot = .init(
                id: itemID,
                turnID: turnID,
                kind: .init(rawValue: entry.kind.rawValue),
                content: .diagnostic((existing?.plainText ?? "") + entry.text)
            )
        }
    }

    private var command: CodexCommand? {
        if case .command(let command) = snapshot.content {
            return command
        }
        return nil
    }

    private var commandText: String? {
        command?.command
    }

    private var commandCWD: String? {
        command?.cwd
    }

    private var commandOutput: String {
        command?.output ?? ""
    }

    private var commandExitCode: Int? {
        command?.exitCode
    }

    private var commandStatus: CodexTurnStatus? {
        command?.status
    }

    private var messageText: String? {
        if case .message(let message) = snapshot.content {
            return message.text
        }
        return nil
    }

    private var reasoningText: String? {
        if case .reasoning(let reasoning) = snapshot.content {
            return reasoning.text
        }
        return nil
    }

    private var toolResult: String? {
        if case .toolCall(let toolCall) = snapshot.content {
            return toolCall.result
        }
        return nil
    }

    private var plainText: String? {
        snapshot.text
    }
}

extension CodexReviewJob {
    var reviewChatIDForTesting: CodexThreadID? {
        if let reviewThreadID = nonEmptyReviewChatProjectionStringForTesting(core.run.reviewThreadID) {
            return CodexThreadID(rawValue: reviewThreadID)
        }
        if let threadID = nonEmptyReviewChatProjectionStringForTesting(core.run.threadID) {
            return CodexThreadID(rawValue: threadID)
        }
        return nil
    }

    var reviewChatSelectionForTesting: ReviewMonitorCodexSidebarSnapshot.Chat? {
        guard let chatID = reviewChatIDForTesting else {
            return nil
        }
        return ReviewMonitorCodexSidebarSnapshot.Chat(
            rowID: .chat(chatID),
            id: chatID,
            title: displayTitle,
            preview: nonEmptyReviewChatProjectionStringForTesting(core.output.lastAgentMessage)
                ?? nonEmptyReviewChatProjectionStringForTesting(core.output.summary),
            workspaceCWD: cwd,
            updatedAt: core.lifecycle.endedAt ?? core.lifecycle.startedAt,
            recencyAt: core.lifecycle.endedAt ?? core.lifecycle.startedAt,
            status: CodexThreadStatus(reviewJobStateForTesting: core.lifecycle.status)
        )
    }

    var previewTurnIDForTesting: CodexTurnID {
        core.run.turnID.map(CodexTurnID.init(rawValue:)) ?? CodexTurnID(rawValue: "\(id):preview-turn")
    }
}

private extension CodexThreadStatus {
    init(reviewJobStateForTesting jobState: ReviewJobState) {
        switch jobState {
        case .queued, .running:
            self = .active(activeFlags: [])
        case .succeeded, .failed, .cancelled:
            self = .idle
        }
    }
}

private extension CodexTurnStatus {
    init(reviewJobStateForTesting jobState: ReviewJobState) {
        switch jobState {
        case .queued, .running:
            self = .running
        case .succeeded:
            self = .completed
        case .failed:
            self = .failed
        case .cancelled:
            self = .cancelled
        }
    }
}

private extension CodexDataPhase {
    init(reviewJobStateForTesting jobState: ReviewJobState, errorMessage: String?) {
        switch jobState {
        case .queued, .running, .succeeded, .cancelled:
            self = .loaded
        case .failed:
            self = .failed(errorMessage ?? "Review failed")
        }
    }
}

private func chatLogCommandText(for entry: ReviewChatLogEntryForTesting) -> String {
    if let command = entry.metadata?.command, command.isEmpty == false {
        return command
    }
    if entry.text.hasPrefix("$ ") {
        return String(entry.text.dropFirst(2))
    }
    return entry.text
}

private func codexTurnStatus(for entry: ReviewChatLogEntryForTesting) -> CodexTurnStatus? {
    guard let rawValue = entry.metadata?.commandStatus ?? entry.metadata?.status else {
        return entry.kind == .command ? .running : nil
    }
    return CodexTurnStatus(rawValue: rawValue)
}

private func nonEmptyReviewChatProjectionStringForTesting(_ value: String?) -> String? {
    guard let value, value.isEmpty == false else {
        return nil
    }
    return value
}

private extension CodexChatChange {
    static func previewChangesForTesting(from previous: CodexChatSnapshot?, to current: CodexChatSnapshot) -> [Self] {
        guard let previous else {
            return [.snapshot(current)]
        }

        var changes: [Self] = []
        let previousTurnsByID = Dictionary(uniqueKeysWithValues: previous.turns.map { ($0.id, $0) })
        for turn in current.turns where previousTurnsByID[turn.id] != turn {
            changes.append(.turnUpdated(turn))
        }

        let previousItemsByID = Dictionary(uniqueKeysWithValues: previous.items.map { ($0.id, $0) })
        let currentItemIDs = Set(current.items.map(\.id))
        for removedItem in previous.items where currentItemIDs.contains(removedItem.id) == false {
            changes.append(.itemRemoved(id: removedItem.id, turnID: removedItem.turnID))
        }
        for item in current.items {
            guard let previousItem = previousItemsByID[item.id] else {
                changes.append(.itemInserted(item))
                continue
            }
            guard previousItem != item else {
                continue
            }
            if let delta = previousItem.textDeltaForTesting(to: item) {
                changes.append(.itemTextAppended(id: item.id, turnID: item.turnID, delta: delta, item: item))
            } else {
                changes.append(.itemUpdated(item))
            }
        }

        if previous.phase != current.phase {
            changes.append(.phaseChanged(current.phase))
        }
        return changes
    }
}

private extension CodexChatItemSnapshot {
    func textDeltaForTesting(to item: CodexChatItemSnapshot) -> String? {
        guard
            turnID == item.turnID,
            kind == item.kind,
            sameContentShapeForTesting(as: item),
            let previousText = text,
            let nextText = item.text,
            nextText.hasPrefix(previousText),
            nextText.count > previousText.count
        else {
            return nil
        }
        return String(nextText.dropFirst(previousText.count))
    }

    private func sameContentShapeForTesting(as item: CodexChatItemSnapshot) -> Bool {
        switch (content, item.content) {
        case (.message, .message),
            (.plan, .plan),
            (.reasoning, .reasoning),
            (.command, .command),
            (.fileChange, .fileChange),
            (.toolCall, .toolCall),
            (.contextCompaction, .contextCompaction),
            (.diagnostic, .diagnostic),
            (.log, .log),
            (.unknown, .unknown):
            true
        default:
            false
        }
    }
}
