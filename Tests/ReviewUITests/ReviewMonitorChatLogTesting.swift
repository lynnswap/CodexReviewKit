import Foundation
import Testing
import CodexKit
@_spi(Testing) @testable import CodexReviewKit
@testable import ReviewChatLogUI
@testable import ReviewUI
@testable import ReviewUIPreviewSupport

@MainActor
func makeReviewMonitorPreviewContentViewControllerForPreview(
    authPhase: CodexReviewAuthModel.Phase = .signedOut,
    account: CodexReviewAccount? = nil,
    serverState: CodexReviewServerState = .running,
    previewContent: ReviewMonitorPreviewContentSource? = nil
) -> ReviewMonitorRootViewController {
    let viewController = ReviewUIPreviewSupport.makeReviewMonitorPreviewContentViewControllerForPreview(
        authPhase: authPhase,
        account: account,
        serverState: serverState,
        previewContent: previewContent
    )
    guard let rootViewController = viewController as? ReviewMonitorRootViewController else {
        fatalError("Expected ReviewMonitorRootViewController.")
    }
    return rootViewController
}

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

@MainActor
struct ReviewChatFixtureForTesting {
    struct Chat: Sendable {
        var rowID: ReviewMonitorCodexSidebarRowID
        var id: CodexThreadID
        var title: String
        var preview: String?
        var model: String?
        var workspaceCWD: String?
        var updatedAt: Date?
        var recencyAt: Date?
        var status: CodexThreadStatus?
    }

    var id: String
    var cwd: String
    var chat: Chat
    var turnID: CodexTurnID
    var streamID: String
    var isRunning: Bool
    var initialSnapshot: CodexThreadSnapshot

    var chatID: CodexThreadID {
        chat.id
    }
}

enum ReviewChatFixtureStatus: Sendable, Hashable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .queued, .running:
            false
        case .succeeded, .failed, .cancelled:
            true
        }
    }

    var displayText: String {
        switch self {
        case .queued:
            "Queued"
        case .running:
            "Running"
        case .succeeded:
            "Succeeded"
        case .failed:
            "Failed"
        case .cancelled:
            "Cancelled"
        }
    }
}

@MainActor
func makeReviewChatFixtureForTesting(
    id: String = UUID().uuidString,
    cwd: String = "/tmp/repo",
    title: String,
    preview: String? = nil,
    model: String? = "gpt-5",
    chatID: CodexThreadID? = nil,
    turnID: CodexTurnID? = nil,
    status: ReviewChatFixtureStatus = .succeeded,
    startedAt: Date? = Date(timeIntervalSince1970: 200),
    updatedAt: Date? = nil,
    chatEntries: [ReviewChatLogEntryForTesting] = [],
    errorMessage: String? = nil
) -> ReviewChatFixtureForTesting {
    let resolvedChatID = chatID ?? CodexThreadID(rawValue: id)
    let resolvedTurnID = turnID ?? CodexTurnID(rawValue: "\(id):preview-turn")
    let resolvedUpdatedAt = updatedAt ?? startedAt
    let chat = ReviewChatFixtureForTesting.Chat(
        rowID: .chat(resolvedChatID),
        id: resolvedChatID,
        title: title,
        preview: preview,
        model: model,
        workspaceCWD: cwd,
        updatedAt: resolvedUpdatedAt,
        recencyAt: resolvedUpdatedAt,
        status: CodexThreadStatus(chatFixtureStatusForTesting: status)
    )
    ReviewChatLogFixtureStore.setEntries(chatEntries, for: resolvedChatID)
    let initialSnapshot = makeCodexThreadSnapshotForTesting(
        chatID: resolvedChatID,
        turnID: resolvedTurnID,
        turnStatus: CodexTurnStatus(chatFixtureStatusForTesting: status),
        turnErrorDescription: errorMessage,
        items: ReviewChatLogFixtureStore.items(for: resolvedChatID, turnID: resolvedTurnID)
    )
    return ReviewChatFixtureForTesting(
        id: id,
        cwd: cwd,
        chat: chat,
        turnID: resolvedTurnID,
        streamID: id,
        isRunning: status == .running,
        initialSnapshot: initialSnapshot
    )
}

@MainActor
func appendChatLogEntryForTesting(
    _ entry: ReviewChatLogEntryForTesting,
    to chatID: CodexThreadID,
    turnID: CodexTurnID
) async {
    await ReviewChatLogFixtureStore.append(entry, to: chatID, turnID: turnID)
}

@MainActor
func replaceChatLogTextForTesting(
    _ text: String,
    for chatID: CodexThreadID,
    fixtureID: String,
    turnID: CodexTurnID
) async {
    await ReviewChatLogFixtureStore.replaceEntries(
        [.init(kind: .agentMessage, groupID: "fixture-log-\(fixtureID)", text: text.trimmingCharacters(in: .newlines))],
        for: chatID,
        turnID: turnID
    )
}

@MainActor
@discardableResult
func installPreviewChatLogSourceForTesting(
    on store: CodexReviewStore,
    fixtures: [ReviewChatFixtureForTesting]
) -> ReviewMonitorPreviewAppServerRuntime {
    let fixtures = fixtures.map(makePreviewChatLogFixtureForTesting)
    let runtime = ReviewMonitorPreviewAppServerRuntime(fixtures: fixtures)
    let retainer = ReviewChatLogFixtureRetainer(
        store: store,
        runtime: runtime,
        chatIDs: Set(fixtures.map(\.chatID))
    )
    runStorePreviewSupportRetainers.append(retainer)
    previewSupportRetainersByStore[ObjectIdentifier(store)] = retainer
    return runtime
}

@MainActor
func previewRuntimeForTesting(on store: CodexReviewStore) -> ReviewMonitorPreviewAppServerRuntime? {
    prunePreviewSupportRetainersByStore()
    guard let retainer = previewSupportRetainersByStore[ObjectIdentifier(store)],
          retainer.store === store
    else {
        previewSupportRetainersByStore[ObjectIdentifier(store)] = nil
        return nil
    }
    return retainer.runtime
}

@MainActor
private func prunePreviewSupportRetainersByStore() {
    previewSupportRetainersByStore = previewSupportRetainersByStore.filter { _, retainer in
        retainer.store != nil
    }
}

@MainActor
func makeReviewMonitorSplitViewControllerForTesting(
    store: CodexReviewStore,
    uiState: ReviewMonitorUIState,
    codexModelSource: ReviewMonitorCodexModelSource? = nil,
    showSettings: (@MainActor () -> Void)? = nil
) -> ReviewMonitorSplitViewController {
    let previewRuntime = previewRuntimeForTesting(on: store)
    previewRuntime?.start()
    return ReviewMonitorSplitViewController(
        store: store,
        uiState: uiState,
        codexModelSource: codexModelSource ?? previewRuntime?.modelSource,
        showSettings: showSettings
    )
}

@MainActor
func makeReviewMonitorSplitViewControllerForTesting(
    store: CodexReviewStore,
    uiState: ReviewMonitorUIState,
    modelContext: CodexModelContext,
    showSettings: (@MainActor () -> Void)? = nil
) -> ReviewMonitorSplitViewController {
    ReviewMonitorSplitViewController(
        store: store,
        uiState: uiState,
        modelContext: modelContext,
        showSettings: showSettings
    )
}

@MainActor
func reviewChatLogText(for fixture: ReviewChatFixtureForTesting) -> String {
    reviewChatLogText(
        for: codexThreadSnapshotForTesting(fixture),
        chatUpdatedAt: fixture.chat.updatedAt
    )
}

@MainActor
func reviewChatLogText(
    for snapshot: CodexThreadSnapshot,
    chatUpdatedAt: Date? = nil
) -> String {
    ReviewChatLogFixtureStore.logText(for: snapshot, chatUpdatedAt: chatUpdatedAt)
}

@MainActor
func awaitChatRenderForTesting(
    _ fixture: ReviewChatFixtureForTesting,
    in transport: ReviewMonitorTransportViewController,
    allowIncrementalUpdate: Bool = true,
    timeout: Duration = .seconds(2),
    matching predicate: (@Sendable (ReviewMonitorTransportViewController.RenderSnapshotForTesting) -> Bool)? = nil
) async throws -> ReviewMonitorTransportViewController.RenderSnapshotForTesting {
    try await awaitChatRenderForTesting(
        chatID: fixture.chatID,
        expectedLog: reviewChatLogText(for: fixture),
        in: transport,
        allowIncrementalUpdate: allowIncrementalUpdate,
        timeout: timeout,
        matching: predicate
    )
}

@MainActor
func awaitChatRenderForTesting(
    snapshot: CodexThreadSnapshot,
    in transport: ReviewMonitorTransportViewController,
    allowIncrementalUpdate: Bool = true,
    timeout: Duration = .seconds(2),
    matching predicate: (@Sendable (ReviewMonitorTransportViewController.RenderSnapshotForTesting) -> Bool)? = nil
) async throws -> ReviewMonitorTransportViewController.RenderSnapshotForTesting {
    try await awaitChatRenderForTesting(
        chatID: snapshot.id,
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
func makePreviewAppServerRuntimeForTesting(
    chat: ReviewChatFixtureForTesting.Chat,
    cwd: String,
    streamID: String,
    isRunning: Bool,
    initialSnapshot: CodexThreadSnapshot
) -> ReviewMonitorPreviewAppServerRuntime {
    ReviewMonitorPreviewAppServerRuntime(
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
) -> CodexThreadItem {
    CodexThreadItem(
        id: id,
        kind: .agentMessage,
        content: .message(.init(id: id, role: .assistant, text: text))
    )
}

@MainActor
func chatCommandOutputBlockIDForTesting(
    turnID: CodexTurnID,
    itemID: String
) -> ReviewMonitorLog.BlockID {
    ReviewMonitorLog.BlockID("commandOutput:\(turnID.rawValue):\(itemID)")
}

@MainActor
private func makePreviewChatLogFixtureForTesting(
    _ fixture: ReviewChatFixtureForTesting
) -> ReviewMonitorPreviewChatLogFixture {
    makePreviewChatLogFixtureForTesting(fixture: fixture) { _ in
        fixture.initialSnapshot.items
    }
}

@MainActor
private func makePreviewChatLogFixtureForTesting(
    fixture: ReviewChatFixtureForTesting,
    items makeItems: (CodexTurnID) -> [CodexThreadItem]
) -> ReviewMonitorPreviewChatLogFixture {
    let initialSnapshot = makeCodexThreadSnapshotForTesting(
        chatID: fixture.chatID,
        turns: fixture.initialSnapshot.turns ?? [],
        items: makeItems(fixture.turnID)
    )
    return makePreviewChatLogFixtureForTesting(
        chat: fixture.chat,
        cwd: fixture.cwd,
        streamID: fixture.streamID,
        isRunning: fixture.isRunning,
        initialSnapshot: initialSnapshot
    )
}

@MainActor
func codexThreadSnapshotForTesting(_ fixture: ReviewChatFixtureForTesting) -> CodexThreadSnapshot {
    makeCodexThreadSnapshotForTesting(
        chatID: fixture.chatID,
        turns: fixture.initialSnapshot.turns ?? [],
        items: ReviewChatLogFixtureStore.items(for: fixture.chatID, turnID: fixture.turnID)
    )
}

@MainActor
func makeCodexThreadSnapshotForTesting(
    chatID: CodexThreadID,
    turnID: CodexTurnID,
    turnStatus: CodexTurnStatus = .completed,
    turnErrorDescription: String? = nil,
    items: [CodexThreadItem] = []
) -> CodexThreadSnapshot {
    makeCodexThreadSnapshotForTesting(
        chatID: chatID,
        turns: [
            .init(
                id: turnID,
                status: turnStatus,
                errorMessage: turnErrorDescription,
                items: items
            )
        ]
    )
}

@MainActor
func makeCodexThreadSnapshotForTesting(
    chatID: CodexThreadID,
    turns: [CodexTurnSnapshot],
    items: [CodexThreadItem] = []
) -> CodexThreadSnapshot {
    var resolvedTurns = turns
    if items.isEmpty == false {
        if resolvedTurns.isEmpty {
            resolvedTurns = [CodexTurnSnapshot(id: CodexTurnID(rawValue: "\(chatID.rawValue):preview-turn"))]
        }
        resolvedTurns[resolvedTurns.count - 1].items = items
    }
    return CodexThreadSnapshot(
        id: chatID,
        turns: resolvedTurns
    )
}

@MainActor
func makePreviewChatLogFixtureForTesting(
    chat: ReviewChatFixtureForTesting.Chat,
    cwd: String,
    streamID: String,
    isRunning: Bool,
    initialSnapshot: CodexThreadSnapshot
) -> ReviewMonitorPreviewChatLogFixture {
    ReviewMonitorPreviewChatLogFixture(
        chatID: chat.id,
        title: chat.title,
        preview: chat.preview,
        model: chat.model,
        workspaceCWD: chat.workspaceCWD,
        updatedAt: chat.updatedAt,
        recencyAt: chat.recencyAt,
        status: chat.status,
        cwd: cwd,
        streamID: streamID,
        isRunning: isRunning,
        initialThreadSnapshot: initialSnapshot
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
    ) async {
        setEntries(entries, for: chatID)
        await updateRetainedPreviewSource(for: chatID, turnID: turnID)
    }

    static func append(_ entry: ReviewChatLogEntryForTesting, to chatID: CodexThreadID, turnID: CodexTurnID) async {
        entriesByChatID[chatID, default: []].append(entry)
        await updateRetainedPreviewSource(for: chatID, turnID: turnID)
    }

    static func items(for chatID: CodexThreadID, turnID: CodexTurnID) -> [CodexThreadItem] {
        makeChatItems(from: entriesByChatID[chatID, default: []], turnID: turnID)
    }

    static func logText(for snapshot: CodexThreadSnapshot, chatUpdatedAt: Date?) -> String {
        var projection = ReviewMonitorCodexChatLogProjection()
        let document = projection.render(
            from: snapshot,
            chatCreatedAt: nil,
            chatUpdatedAt: chatUpdatedAt
        )
        guard let document else {
            return ""
        }
        let displayDocument = ReviewMonitorCommandOutputDisplayDocument.make(from: document)
        return ReviewMonitorCommandOutputDisplayDocument.userVisibleText(from: displayDocument.text)
    }

    private static func updateRetainedPreviewSource(for chatID: CodexThreadID, turnID: CodexTurnID) async {
        prunePreviewSupportRetainersByStore()
        for support in runStorePreviewSupportRetainers where support.contains(chatID: chatID) {
            await support.upsert(chatID: chatID, items: items(for: chatID, turnID: turnID))
        }
    }
}

@MainActor
private final class ReviewChatLogFixtureRetainer {
    weak var store: CodexReviewStore?
    let runtime: ReviewMonitorPreviewAppServerRuntime
    private var chatIDs: Set<CodexThreadID>

    init(store: CodexReviewStore, runtime: ReviewMonitorPreviewAppServerRuntime, chatIDs: Set<CodexThreadID>) {
        self.store = store
        self.runtime = runtime
        self.chatIDs = chatIDs
    }

    func contains(chatID: CodexThreadID) -> Bool {
        chatIDs.contains(chatID)
    }

    func upsert(chatID: CodexThreadID, items: [CodexThreadItem]) async {
        let previousItemsByID = Dictionary(
            uniqueKeysWithValues: await runtime.snapshotForTesting(chatID: chatID)?.items.map { ($0.id, $0) } ?? []
        )
        for item in items {
            guard let previousItem = previousItemsByID[item.id] else {
                await runtime.upsertPreviewItem(id: item.id, kind: item.kind, content: item.content, to: chatID)
                continue
            }
            guard previousItem != item else {
                continue
            }
            if let outputDelta = previousItem.outputDeltaForTesting(to: item) {
                await runtime.appendPreviewText(
                    outputDelta,
                    to: chatID,
                    itemID: item.id,
                    kind: item.kind,
                    content: previousItem.content
                )
            } else if let textDelta = previousItem.textDeltaForTesting(to: item) {
                await runtime.appendPreviewText(
                    textDelta,
                    to: chatID,
                    itemID: item.id,
                    kind: item.kind,
                    content: previousItem.content
                )
            } else {
                await runtime.upsertPreviewItem(id: item.id, kind: item.kind, content: item.content, to: chatID)
            }
        }
    }
}

@MainActor
private var runStorePreviewSupportRetainers: [ReviewChatLogFixtureRetainer] = []
@MainActor
private var previewSupportRetainersByStore: [ObjectIdentifier: ReviewChatLogFixtureRetainer] = [:]

@MainActor
private func makeChatItems(
    from entries: [ReviewChatLogEntryForTesting],
    turnID: CodexTurnID
) -> [CodexThreadItem] {
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
    var snapshot: CodexThreadItem

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
                kind: entry.kind == .todoList ? .init(rawValue: "todoList") : .plan,
                content: .plan((existing?.plainText ?? "") + entry.text)
            )
        case .reasoning, .rawReasoning:
            snapshot = .init(
                id: itemID,
                kind: entry.kind == .rawReasoning ? .init(rawValue: "rawReasoning") : .reasoning,
                content: .reasoning(.init(content: (existing?.reasoningText ?? "") + entry.text))
            )
        case .reasoningSummary:
            snapshot = .init(
                id: itemID,
                kind: .init(rawValue: "reasoningSummary"),
                content: .reasoning(.init(summary: (existing?.reasoningText ?? "") + entry.text))
            )
        case .contextCompaction:
            snapshot = .init(
                id: itemID,
                kind: .contextCompaction,
                content: .contextCompaction(entry.text)
            )
        case .toolCall:
            snapshot = .init(
                id: itemID,
                kind: .mcpToolCall,
                content: .toolCall(.init(result: (existing?.toolResult ?? "") + entry.text, status: status))
            )
        case .diagnostic, .error, .progress, .event:
            snapshot = .init(
                id: itemID,
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

private extension CodexThreadStatus {
    init(chatFixtureStatusForTesting status: ReviewChatFixtureStatus) {
        switch status {
        case .queued, .running:
            self = .active(activeFlags: [])
        case .succeeded, .failed, .cancelled:
            self = .idle
        }
    }
}

private extension CodexTurnStatus {
    init(chatFixtureStatusForTesting status: ReviewChatFixtureStatus) {
        switch status {
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
    init(chatFixtureStatusForTesting status: ReviewChatFixtureStatus, errorMessage: String?) {
        switch status {
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

extension CodexThreadSnapshot {
    var items: [CodexThreadItem] {
        (turns ?? []).flatMap(\.items)
    }
}

private extension CodexThreadItem {
    func outputDeltaForTesting(to item: CodexThreadItem) -> String? {
        guard kind == item.kind,
              preservesOutputDeltaMetadata(for: item),
              let previousOutput = commandOutputForTesting,
              let nextOutput = item.commandOutputForTesting,
              nextOutput.hasPrefix(previousOutput),
              nextOutput.count > previousOutput.count
        else {
            return nil
        }
        return String(nextOutput.dropFirst(previousOutput.count))
    }

    func textDeltaForTesting(to item: CodexThreadItem) -> String? {
        guard
            kind == item.kind,
            sameContentShapeForTesting(as: item),
            preservesTextDeltaMetadata(for: item),
            let previousText = text,
            let nextText = item.text,
            nextText.hasPrefix(previousText),
            nextText.count > previousText.count
        else {
            return nil
        }
        return String(nextText.dropFirst(previousText.count))
    }

    private func preservesTextDeltaMetadata(for item: CodexThreadItem) -> Bool {
        switch (content, item.content) {
        case (.command, .command),
            (.fileChange, .fileChange),
            (.toolCall, .toolCall):
            preservesOutputDeltaMetadata(for: item)
        default:
            true
        }
    }

    private func preservesOutputDeltaMetadata(for item: CodexThreadItem) -> Bool {
        switch (content, item.content) {
        case (.command(let previous), .command(let next)):
            previous.command == next.command
                && previous.cwd == next.cwd
                && previous.exitCode == next.exitCode
                && previous.status == next.status
        case (.fileChange(let previous), .fileChange(let next)):
            previous.path == next.path
                && previous.status == next.status
        case (.toolCall(let previous), .toolCall(let next)):
            previous.namespace == next.namespace
                && previous.server == next.server
                && previous.name == next.name
                && previous.arguments == next.arguments
                && previous.error == next.error
                && previous.status == next.status
        default:
            false
        }
    }

    private var commandOutputForTesting: String? {
        switch content {
        case .command(let command):
            return command.output
        case .fileChange(let fileChange):
            return fileChange.output
        case .toolCall(let toolCall):
            return toolCall.result
        default:
            return nil
        }
    }

    private func sameContentShapeForTesting(as item: CodexThreadItem) -> Bool {
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
