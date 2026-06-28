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

extension ReviewRunRecord {
    @MainActor
    static func makeForTesting(
        id: String = UUID().uuidString,
        sessionID: String = "session-1",
        cwd: String = "/tmp/repo",
        targetSummary: String,
        model: String? = "gpt-5",
        threadID: String? = nil,
        turnID: String? = nil,
        status: ReviewRunState,
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
    ) -> ReviewRunRecord {
        let run = ReviewRunRecord.makeForTesting(
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
        ReviewChatLogFixtureStore.setEntries(chatEntries, for: run.previewChatIDForTesting)
        return run
    }
}

@MainActor
func seedChatLogForTesting(
    _ run: ReviewRunRecord,
    logText: String = "",
    rawLogText: String = ""
) {
    seedChatLogForTesting(
        chatID: run.previewChatIDForTesting,
        fixtureID: run.id,
        logText: logText,
        rawLogText: rawLogText
    )
}

@MainActor
func seedChatLogForTesting(
    chatID: CodexThreadID,
    fixtureID: String,
    logText: String = "",
    rawLogText: String = ""
) {
    ReviewChatLogFixtureStore.setEntries(
        makeChatLogEntriesForTesting(fixtureID: fixtureID, logText: logText, rawLogText: rawLogText),
        for: chatID
    )
}

@MainActor
func appendChatLogEntryForTesting(_ run: ReviewRunRecord, _ entry: ReviewChatLogEntryForTesting) {
    appendChatLogEntryForTesting(entry, to: run.previewChatIDForTesting, turnID: run.previewTurnIDForTesting)
}

@MainActor
func appendChatLogEntryForTesting(
    _ entry: ReviewChatLogEntryForTesting,
    to chatID: CodexThreadID,
    turnID: CodexTurnID
) {
    ReviewChatLogFixtureStore.append(entry, to: chatID, turnID: turnID)
}

@MainActor
func replaceChatLogTextForTesting(_ run: ReviewRunRecord, _ text: String) {
    replaceChatLogTextForTesting(
        text,
        for: run.previewChatIDForTesting,
        fixtureID: run.id,
        turnID: run.previewTurnIDForTesting
    )
}

@MainActor
func replaceChatLogTextForTesting(
    _ text: String,
    for chatID: CodexThreadID,
    fixtureID: String,
    turnID: CodexTurnID
) {
    ReviewChatLogFixtureStore.replaceEntries(
        [.init(kind: .agentMessage, groupID: "fixture-log-\(fixtureID)", text: text.trimmingCharacters(in: .newlines))],
        for: chatID,
        turnID: turnID
    )
}

@MainActor
func installPreviewChatLogSourceForTesting(on store: CodexReviewStore, reviewRuns: [ReviewRunRecord]) {
    let fixtures = reviewRuns.compactMap { try? makePreviewChatLogFixtureForTesting(run: $0) }
    let source = ReviewMonitorPreviewChatLogSource(fixtures: fixtures)
    store.previewSupportRetainer = ReviewMonitorPreviewRuntimeSupport(chatLogSource: source)
    runStorePreviewSupportRetainers.append(
        ReviewChatLogFixtureRetainer(
            source: source,
            chatIDs: Set(reviewRuns.map(\.previewChatIDForTesting))
        ))
}

@MainActor
func reviewChatLogText(for run: ReviewRunRecord) -> String {
    reviewChatLogText(
        for: makeCodexChatSnapshotForTesting(
            chatID: run.previewChatIDForTesting,
            turnID: run.previewTurnIDForTesting,
            turnStatus: CodexTurnStatus(reviewRunStateForTesting: run.core.lifecycle.status),
            items: ReviewChatLogFixtureStore.items(
                for: run.previewChatIDForTesting,
                turnID: run.previewTurnIDForTesting
            )
        ),
        chatUpdatedAt: run.core.lifecycle.endedAt
    )
}

@MainActor
func reviewChatLogText(
    for snapshot: CodexChatSnapshot,
    chatUpdatedAt: Date? = nil
) -> String {
    ReviewChatLogFixtureStore.logText(for: snapshot, chatUpdatedAt: chatUpdatedAt)
}

@MainActor
func awaitChatRenderForTesting(
    _ run: ReviewRunRecord,
    in transport: ReviewMonitorTransportViewController,
    allowIncrementalUpdate: Bool = true,
    timeout: Duration = .seconds(2),
    matching predicate: (@Sendable (ReviewMonitorTransportViewController.RenderSnapshotForTesting) -> Bool)? = nil
) async throws -> ReviewMonitorTransportViewController.RenderSnapshotForTesting {
    try await awaitChatRenderForTesting(
        chatID: run.previewChatIDForTesting,
        expectedLog: reviewChatLogText(for: run),
        in: transport,
        allowIncrementalUpdate: allowIncrementalUpdate,
        timeout: timeout,
        matching: predicate
    )
}

@MainActor
func awaitChatRenderForTesting(
    snapshot: CodexChatSnapshot,
    in transport: ReviewMonitorTransportViewController,
    allowIncrementalUpdate: Bool = true,
    timeout: Duration = .seconds(2),
    matching predicate: (@Sendable (ReviewMonitorTransportViewController.RenderSnapshotForTesting) -> Bool)? = nil
) async throws -> ReviewMonitorTransportViewController.RenderSnapshotForTesting {
    try await awaitChatRenderForTesting(
        chatID: snapshot.chatID,
        expectedLog: reviewChatLogText(for: snapshot),
        in: transport,
        allowIncrementalUpdate: allowIncrementalUpdate,
        timeout: timeout,
        matching: predicate
    )
}

@MainActor
func awaitChatRenderForTesting(
    chatID: CodexThreadID,
    expectedLog: String,
    in transport: ReviewMonitorTransportViewController,
    allowIncrementalUpdate: Bool = true,
    timeout: Duration = .seconds(2),
    matching predicate: (@Sendable (ReviewMonitorTransportViewController.RenderSnapshotForTesting) -> Bool)? = nil
) async throws -> ReviewMonitorTransportViewController.RenderSnapshotForTesting {
    _ = allowIncrementalUpdate
    let expectedSelection: ReviewMonitorTransportViewController.DisplayedSelectionForTesting =
        .chat(chatID.rawValue)
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
    run: ReviewRunRecord,
    items makeItems: (CodexTurnID) -> [CodexChatItemSnapshot]
) throws -> ReviewMonitorPreviewChatLogSource {
    ReviewMonitorPreviewChatLogSource(
        fixtures: [try makePreviewChatLogFixtureForTesting(run: run, items: makeItems)]
    )
}

@MainActor
func makePreviewChatLogSourceForTesting(
    chat: ReviewMonitorCodexSidebarSnapshot.Chat,
    cwd: String,
    streamID: String,
    isRunning: Bool,
    initialSnapshot: CodexChatSnapshot
) -> ReviewMonitorPreviewChatLogSource {
    ReviewMonitorPreviewChatLogSource(
        fixtures: [
            makePreviewChatLogFixtureForTesting(
                chat: chat,
                cwd: cwd,
                streamID: streamID,
                isRunning: isRunning,
                initialSnapshot: initialSnapshot
            )
        ]
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
    _ run: ReviewRunRecord,
    itemID: String
) -> ReviewMonitorLog.BlockID {
    chatCommandOutputBlockIDForTesting(turnID: run.previewTurnIDForTesting, itemID: itemID)
}

@MainActor
func chatCommandOutputBlockIDForTesting(
    turnID: CodexTurnID,
    itemID: String
) -> ReviewMonitorLog.BlockID {
    ReviewMonitorLog.BlockID("commandOutput:\(turnID.rawValue):\(itemID)")
}

@MainActor
private func makePreviewChatLogFixtureForTesting(run: ReviewRunRecord) throws -> ReviewMonitorPreviewChatLogFixture {
    try makePreviewChatLogFixtureForTesting(run: run) { _ in
        ReviewChatLogFixtureStore.items(for: run.previewChatIDForTesting, turnID: run.previewTurnIDForTesting)
    }
}

@MainActor
private func makePreviewChatLogFixtureForTesting(
    run: ReviewRunRecord,
    items makeItems: (CodexTurnID) -> [CodexChatItemSnapshot]
) throws -> ReviewMonitorPreviewChatLogFixture {
    let chat = run.reviewChatSelectionForTesting
    let turn = CodexChatTurnStateSnapshot(
        id: run.previewTurnIDForTesting,
        status: CodexTurnStatus(reviewRunStateForTesting: run.core.lifecycle.status),
        errorDescription: run.core.lifecycle.errorMessage,
        usage: nil
    )
    let initialSnapshot = makeCodexChatSnapshotForTesting(
        chatID: chat.id,
        phase: CodexDataPhase(
            reviewRunStateForTesting: run.core.lifecycle.status,
            errorMessage: run.core.lifecycle.errorMessage
        ),
        turns: [turn],
        items: makeItems(turn.id)
    )
    return makePreviewChatLogFixtureForTesting(
        chat: chat,
        cwd: run.cwd,
        streamID: run.id,
        isRunning: run.core.lifecycle.status == .running,
        initialSnapshot: initialSnapshot
    )
}

@MainActor
func makeCodexChatSnapshotForTesting(
    chatID: CodexThreadID,
    turnID: CodexTurnID,
    phase: CodexDataPhase = .loaded,
    turnStatus: CodexTurnStatus = .completed,
    turnErrorDescription: String? = nil,
    items: [CodexChatItemSnapshot] = []
) -> CodexChatSnapshot {
    makeCodexChatSnapshotForTesting(
        chatID: chatID,
        phase: phase,
        turns: [
            .init(
                id: turnID,
                status: turnStatus,
                errorDescription: turnErrorDescription,
                usage: nil
            )
        ],
        items: items
    )
}

@MainActor
func makeCodexChatSnapshotForTesting(
    chatID: CodexThreadID,
    phase: CodexDataPhase = .loaded,
    turns: [CodexChatTurnStateSnapshot],
    items: [CodexChatItemSnapshot] = []
) -> CodexChatSnapshot {
    CodexChatSnapshot(
        chatID: chatID,
        phase: phase,
        turns: turns,
        items: items
    )
}

@MainActor
func makePreviewChatLogFixtureForTesting(
    chat: ReviewMonitorCodexSidebarSnapshot.Chat,
    cwd: String,
    streamID: String,
    isRunning: Bool,
    initialSnapshot: CodexChatSnapshot
) -> ReviewMonitorPreviewChatLogFixture {
    ReviewMonitorPreviewChatLogFixture(
        chat: chat,
        cwd: cwd,
        streamID: streamID,
        isRunning: isRunning,
        initialSnapshot: initialSnapshot
    )
}

@MainActor
private enum ReviewChatLogFixtureStore {
    private static var entriesByChatID: [CodexThreadID: [ReviewChatLogEntryForTesting]] = [:]

    static func setEntries(_ entries: [ReviewChatLogEntryForTesting], for chatID: CodexThreadID) {
        entriesByChatID[chatID] = entries
    }

    static func replaceEntries(
        _ entries: [ReviewChatLogEntryForTesting],
        for chatID: CodexThreadID,
        turnID: CodexTurnID
    ) {
        setEntries(entries, for: chatID)
        updateRetainedPreviewSource(for: chatID, turnID: turnID)
    }

    static func append(_ entry: ReviewChatLogEntryForTesting, to chatID: CodexThreadID, turnID: CodexTurnID) {
        entriesByChatID[chatID, default: []].append(entry)
        updateRetainedPreviewSource(for: chatID, turnID: turnID)
    }

    static func items(for chatID: CodexThreadID, turnID: CodexTurnID) -> [CodexChatItemSnapshot] {
        makeChatItems(from: entriesByChatID[chatID, default: []], turnID: turnID)
    }

    static func logText(for snapshot: CodexChatSnapshot, chatUpdatedAt: Date?) -> String {
        var projection = ReviewMonitorSelectedCodexChatLogProjection()
        var document: ReviewMonitorLog.Document?
        for change in CodexChatChange.previewChangesForTesting(from: nil, to: snapshot) {
            document = projection.apply(
                change,
                chatCreatedAt: nil,
                chatUpdatedAt: chatUpdatedAt
            )?.sourceDocument ?? document
        }
        guard let document else {
            return ""
        }
        let displayDocument = ReviewMonitorCommandOutputDisplayDocument.make(from: document)
        return ReviewMonitorCommandOutputDisplayDocument.userVisibleText(from: displayDocument.text)
    }

    private static func updateRetainedPreviewSource(for chatID: CodexThreadID, turnID: CodexTurnID) {
        for support in runStorePreviewSupportRetainers where support.contains(chatID: chatID) {
            support.upsert(chatID: chatID, items: items(for: chatID, turnID: turnID))
        }
    }
}

@MainActor
private final class ReviewChatLogFixtureRetainer {
    let source: ReviewMonitorPreviewChatLogSource
    private var chatIDs: Set<CodexThreadID>

    init(source: ReviewMonitorPreviewChatLogSource, chatIDs: Set<CodexThreadID>) {
        self.source = source
        self.chatIDs = chatIDs
    }

    func contains(chatID: CodexThreadID) -> Bool {
        chatIDs.contains(chatID)
    }

    func upsert(chatID: CodexThreadID, items: [CodexChatItemSnapshot]) {
        for item in items {
            source.upsertPreviewItem(id: item.id, kind: item.kind, content: item.content, to: chatID)
        }
    }
}

@MainActor
private var runStorePreviewSupportRetainers: [ReviewChatLogFixtureRetainer] = []

private func makeChatLogEntriesForTesting(
    fixtureID: String,
    logText: String,
    rawLogText: String
) -> [ReviewChatLogEntryForTesting] {
    var entries: [ReviewChatLogEntryForTesting] = []
    let trimmedLogText = logText.trimmingCharacters(in: .newlines)
    if trimmedLogText.isEmpty == false {
        entries.append(.init(kind: .agentMessage, groupID: "fixture-log-\(fixtureID)", text: trimmedLogText))
    }
    for (index, line) in rawLogText.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        entries.append(
            .init(
                kind: .diagnostic,
                groupID: "fixture-diagnostic-\(fixtureID)-\(index)",
                text: String(line)
            ))
    }
    return entries
}

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

extension ReviewRunRecord {
    var previewChatIDForTesting: CodexThreadID {
        if let reviewThreadID = nonEmptyReviewChatProjectionStringForTesting(core.run.reviewThreadID) {
            return CodexThreadID(rawValue: reviewThreadID)
        }
        if let threadID = nonEmptyReviewChatProjectionStringForTesting(core.run.threadID) {
            return CodexThreadID(rawValue: threadID)
        }
        return CodexThreadID(rawValue: id)
    }

    var reviewChatSelectionForTesting: ReviewMonitorCodexSidebarSnapshot.Chat {
        let chatID = previewChatIDForTesting
        return ReviewMonitorCodexSidebarSnapshot.Chat(
            rowID: .chat(chatID),
            id: chatID,
            title: displayTitle,
            preview: nonEmptyReviewChatProjectionStringForTesting(core.output.lastAgentMessage)
                ?? nonEmptyReviewChatProjectionStringForTesting(core.output.summary),
            workspaceCWD: cwd,
            updatedAt: core.lifecycle.endedAt ?? core.lifecycle.startedAt,
            recencyAt: core.lifecycle.endedAt ?? core.lifecycle.startedAt,
            status: CodexThreadStatus(reviewRunStateForTesting: core.lifecycle.status)
        )
    }

    var previewTurnIDForTesting: CodexTurnID {
        core.run.turnID.map(CodexTurnID.init(rawValue:)) ?? CodexTurnID(rawValue: "\(id):preview-turn")
    }
}

private extension CodexThreadStatus {
    init(reviewRunStateForTesting jobState: ReviewRunState) {
        switch jobState {
        case .queued, .running:
            self = .active(activeFlags: [])
        case .succeeded, .failed, .cancelled:
            self = .idle
        }
    }
}

private extension CodexTurnStatus {
    init(reviewRunStateForTesting jobState: ReviewRunState) {
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
    init(reviewRunStateForTesting jobState: ReviewRunState, errorMessage: String?) {
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
