import CodexAppServerKit
import CodexDataKit
import CodexAppServerKitTesting
import CodexReviewKit
import Foundation
import ReviewUI

private actor ReviewMonitorPreviewSnapshotMutationQueue {
    private var tailTask: Task<Void, Never>?

    func run<Value: Sendable>(
        _ operation: @Sendable @escaping () async -> Value
    ) async -> Value {
        let previousTask = tailTask
        let task = Task<Value, Never> {
            await previousTask?.value
            return await operation()
        }
        tailTask = Task {
            _ = await task.value
        }
        return await task.value
    }
}

private actor ReviewMonitorPreviewCancelledChatIDs {
    private var ids: Set<CodexThreadID> = []

    func insert(_ id: CodexThreadID) {
        ids.insert(id)
    }

    func contains(_ id: CodexThreadID) -> Bool {
        ids.contains(id)
    }
}

struct ReviewMonitorPreviewStoredThreadItem: Sendable {
    var item: CodexThreadItem
    var turnID: CodexTurnID
    var fixtureItem: CodexAppServerTestItem?
}

struct ReviewMonitorPreviewChatLogFixture: Sendable {
    let chatID: CodexThreadID
    let title: String
    let preview: String
    let model: String
    let modelProvider: String
    let workspaceCWD: String
    let createdAt: Date
    let updatedAt: Date
    let recencyAt: Date?
    let status: CodexThreadStatus
    let cwd: String
    let streamID: String
    let isRunning: Bool
    let storedThread: CodexAppServerTestStoredThread

    var initialThreadSnapshot: CodexThreadSnapshot {
        storedThread.snapshot
    }

    init(
        chatID: CodexThreadID,
        title: String,
        preview: String,
        model: String,
        modelProvider: String,
        workspaceCWD: String,
        createdAt: Date,
        updatedAt: Date,
        recencyAt: Date?,
        status: CodexThreadStatus,
        cwd: String,
        streamID: String,
        isRunning: Bool,
        initialThreadSnapshot: CodexThreadSnapshot
    ) {
        self.chatID = chatID
        self.title = title
        self.preview = preview
        self.model = model
        self.modelProvider = modelProvider
        self.workspaceCWD = workspaceCWD
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.recencyAt = recencyAt
        self.status = status
        self.cwd = cwd
        self.streamID = streamID
        self.isRunning = isRunning
        do {
            self.storedThread = try makePreviewStoredThread(
                chatID: chatID,
                title: title,
                preview: preview,
                model: model,
                modelProvider: modelProvider,
                workspaceCWD: workspaceCWD,
                createdAt: createdAt,
                updatedAt: updatedAt,
                recencyAt: recencyAt,
                status: status,
                cwd: cwd,
                initialThreadSnapshot: initialThreadSnapshot
            )
        } catch {
            preconditionFailure("Invalid Preview stored-thread fixture: \(error)")
        }
    }
}

enum ReviewMonitorPreviewRuntimeNotification: Sendable {
    case itemLifecycle(
        ReviewMonitorPreviewStoredThreadItem,
        ReviewMonitorPreviewChatLogFixture
    )
    case textDelta(
        delta: String,
        itemID: String,
        turnID: CodexTurnID,
        chatID: CodexThreadID,
        kind: CodexThreadItem.Kind,
        content: CodexThreadItem.Content
    )
    case stream(
        ReviewMonitorPreviewContent.PreviewChatLogStreamStep,
        ReviewMonitorPreviewStoredThreadItem,
        ReviewMonitorPreviewChatLogFixture
    )
    case cancelled(
        CodexAppServerTestStoredThread,
        ReviewMonitorPreviewChatLogFixture
    )
}

struct ReviewMonitorPreviewStreamMutation: Sendable {
    let tick: Int
    let notifications: [ReviewMonitorPreviewRuntimeNotification]
}

@MainActor
final class ReviewMonitorPreviewRuntimeEventSink {
    private let fixtures: [ReviewMonitorPreviewChatLogFixture]
    private let fixturesByChatID: [CodexThreadID: ReviewMonitorPreviewChatLogFixture]
    let threadStore: CodexAppServerTestThreadStore
    private var turnCompletionNotificationCount = 0
    private let snapshotMutationQueue = ReviewMonitorPreviewSnapshotMutationQueue()
    private let cancelledChatIDs = ReviewMonitorPreviewCancelledChatIDs()
    private(set) var currentTick = 0

    init(fixtures: [ReviewMonitorPreviewChatLogFixture]) {
        self.fixtures = fixtures
        self.fixturesByChatID = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.chatID, $0) })
        do {
            self.threadStore = try CodexAppServerTestThreadStore(
                threads: fixtures.map(\.storedThread)
            )
        } catch {
            preconditionFailure("Invalid Preview thread store: \(error)")
        }
    }

    var initialChatID: CodexThreadID? {
        fixtures.first?.chatID
    }

    func chatPresentation(id: CodexThreadID) -> (title: String, subtitle: String)? {
        guard let fixture = fixturesByChatID[id] else {
            return nil
        }
        return (title: fixture.title, subtitle: fixture.cwd)
    }

    func snapshotForTesting(chatID: CodexThreadID) async -> CodexThreadSnapshot? {
        await threadStore.storedThread(id: chatID)?.snapshot
    }

    func turnCompletionNotificationCountForTesting() -> Int {
        turnCompletionNotificationCount
    }

    func prepareUpsertPreviewItem(
        _ item: CodexAppServerTestItem,
        to chatID: CodexThreadID
    ) async -> ReviewMonitorPreviewRuntimeNotification? {
        guard let fixture = fixturesByChatID[chatID] else {
            return nil
        }
        guard let storedItem = await upsertStoredItem(item, in: fixture) else {
            return nil
        }
        return .itemLifecycle(storedItem, fixture)
    }

    func prepareAppendPreviewText(
        _ delta: String,
        to chatID: CodexThreadID,
        itemID: String,
        kind: CodexThreadItem.Kind,
        content: CodexThreadItem.Content
    ) async -> ReviewMonitorPreviewRuntimeNotification? {
        guard delta.isEmpty == false,
              fixturesByChatID[chatID] != nil else {
            return nil
        }
        guard let item = await appendStoredText(
            delta,
            itemID: itemID,
            in: chatID
        ) else {
            return nil
        }
        return .textDelta(
            delta: delta,
            itemID: itemID,
            turnID: item.turnID,
            chatID: chatID,
            kind: kind,
            content: item.item.content
        )
    }

    func prepareStreamMutation(
        after currentTick: Int
    ) async -> ReviewMonitorPreviewStreamMutation {
        var runningFixtures: [(index: Int, fixture: ReviewMonitorPreviewChatLogFixture)] = []
        for (index, fixture) in fixtures.filter(\.isRunning).enumerated() {
            if await cancelledChatIDs.contains(fixture.chatID) == false,
                await threadStore.storedThread(id: fixture.chatID)?.isArchived == false
            {
                runningFixtures.append((index, fixture))
            }
        }
        guard runningFixtures.isEmpty == false else {
            return .init(tick: currentTick, notifications: [])
        }

        let nextTick = currentTick + 1
        var notifications: [ReviewMonitorPreviewRuntimeNotification] = []
        for (index, fixture) in runningFixtures {
            guard
                let frame = ReviewMonitorPreviewContent.streamFrame(
                    forRunningChatAt: index,
                    tick: nextTick
                )
            else {
                continue
            }
            guard let storedItem = await apply(frame.step, cycle: frame.cycle, for: fixture) else {
                continue
            }
            notifications.append(.stream(frame.step, storedItem, fixture))
        }
        self.currentTick = nextTick
        return .init(tick: nextTick, notifications: notifications)
    }

    func prepareCancellation(
        chatID: CodexThreadID
    ) async -> ReviewMonitorPreviewRuntimeNotification? {
        guard let fixture = fixturesByChatID[chatID] else {
            return nil
        }
        await cancelledChatIDs.insert(chatID)
        let cancelledThread: CodexAppServerTestStoredThread? = await snapshotMutationQueue.run { @MainActor [weak self] in
            guard let self,
                  let stored = await self.threadStore.storedThread(id: fixture.chatID) else {
                return nil
            }
            do {
                let turns = try stored.turns.map { turn in
                    guard turn.snapshot.state.isTerminalForPreview == false else {
                        return turn
                    }
                    var snapshot = turn.snapshot
                    snapshot.state = .interrupted
                    return try CodexAppServerTestTurn(
                        snapshot: snapshot,
                        items: turn.items
                    )
                }
                let updated = try stored.replacingTurns(turns).replacingStatus(.idle)
                await self.threadStore.upsert(updated)
                return updated
            } catch {
                preconditionFailure("Failed to interrupt a Preview stored thread: \(error)")
            }
        }
        guard let cancelledThread else {
            return nil
        }
        return .cancelled(cancelledThread, fixture)
    }

    func emit(
        _ notification: ReviewMonitorPreviewRuntimeNotification,
        using runtime: CodexAppServerTestRuntime
    ) async throws {
        switch notification {
        case .itemLifecycle(let storedItem, let fixture):
            try await emitItemLifecycle(storedItem, for: fixture, using: runtime)
        case .textDelta(let delta, let itemID, let turnID, let chatID, let kind, let content):
            try await emitTextDelta(
                delta,
                itemID: itemID,
                turnID: turnID,
                chatID: chatID,
                kind: kind,
                content: content,
                runtime: runtime
            )
        case .stream(let step, let storedItem, let fixture):
            try await emit(step, storedItem: storedItem, for: fixture, using: runtime)
        case .cancelled(let storedThread, let fixture):
            try await emitCancelledState(storedThread, for: fixture, using: runtime)
        }
    }

    private func emit(
        _ step: ReviewMonitorPreviewContent.PreviewChatLogStreamStep,
        storedItem: ReviewMonitorPreviewStoredThreadItem,
        for fixture: ReviewMonitorPreviewChatLogFixture,
        using runtime: CodexAppServerTestRuntime
    ) async throws {
        switch step.mode {
        case .textDelta:
            try await emitTextDelta(
                step.deltaText ?? "",
                itemID: storedItem.item.id,
                turnID: storedItem.turnID,
                chatID: fixture.chatID,
                kind: storedItem.item.kind,
                content: storedItem.item.content,
                runtime: runtime
            )
        case .update, .complete:
            guard let fixtureItem = storedItem.fixtureItem else {
                preconditionFailure("A preview item lifecycle event requires its canonical fixture item.")
            }
            switch step.mode {
            case .update:
                try await runtime.notificationEmitter.emitItemStarted(
                    threadID: fixture.chatID,
                    turnID: storedItem.turnID,
                    item: fixtureItem
                )
            case .complete:
                try await runtime.notificationEmitter.emitItemCompleted(
                    threadID: fixture.chatID,
                    turnID: storedItem.turnID,
                    item: fixtureItem
                )
            case .textDelta:
                preconditionFailure("Text deltas are handled above.")
            }
        }
    }

    private func apply(
        _ step: ReviewMonitorPreviewContent.PreviewChatLogStreamStep,
        cycle: Int,
        for fixture: ReviewMonitorPreviewChatLogFixture
    ) async -> ReviewMonitorPreviewStoredThreadItem? {
        let itemID = ReviewMonitorPreviewContent.previewChatLogItemID(
            itemName: step.itemName,
            streamID: fixture.streamID,
            cycle: cycle
        )
        switch step.mode {
        case .update, .complete:
            do {
                return await upsertStoredItem(
                    try makePreviewTestItem(
                        id: itemID,
                        kind: step.kind,
                        content: step.content,
                        cwd: fixture.cwd
                    ),
                    in: fixture
                )
            } catch {
                preconditionFailure("Invalid preview item fixture: \(error)")
            }
        case .textDelta:
            return await appendStoredText(
                step.deltaText ?? "",
                itemID: itemID,
                in: fixture.chatID
            )
        }
    }

    private func upsertStoredItem(
        _ fixtureItem: CodexAppServerTestItem,
        in fixture: ReviewMonitorPreviewChatLogFixture
    ) async -> ReviewMonitorPreviewStoredThreadItem? {
        return await snapshotMutationQueue.run { @MainActor [weak self] in
            guard let self,
                  await self.cancelledChatIDs.contains(fixture.chatID) == false,
                  let stored = await self.threadStore.storedThread(id: fixture.chatID),
                  stored.isArchived == false else {
                return nil
            }
            do {
                var turns = stored.turns
                let turnIndex = try turns.requirePreviewTurn()
                var items = turns[turnIndex].items
                if let itemIndex = items.firstIndex(where: {
                    $0.domainProjection.id == fixtureItem.domainProjection.id
                }) {
                    items[itemIndex] = fixtureItem
                } else {
                    items.append(fixtureItem)
                }
                turns[turnIndex] = try turns[turnIndex].replacingItems(items)
                await self.threadStore.upsert(try stored.replacingTurns(turns))
                return ReviewMonitorPreviewStoredThreadItem(
                    item: fixtureItem.domainProjection,
                    turnID: turns[turnIndex].snapshot.id,
                    fixtureItem: fixtureItem
                )
            } catch {
                preconditionFailure("Failed to update a Preview stored item: \(error)")
            }
        }
    }

    private func appendStoredText(
        _ delta: String,
        itemID: String,
        in chatID: CodexThreadID
    ) async -> ReviewMonitorPreviewStoredThreadItem? {
        guard delta.isEmpty == false,
              let fixture = fixturesByChatID[chatID] else {
            return nil
        }
        return await snapshotMutationQueue.run { @MainActor [weak self] in
            guard let self,
                  await self.cancelledChatIDs.contains(fixture.chatID) == false,
                  let stored = await self.threadStore.storedThread(id: fixture.chatID),
                  stored.isArchived == false else {
                return nil
            }
            do {
                var turns = stored.turns
                let turnIndex = try turns.requirePreviewTurn()
                var items = turns[turnIndex].items
                guard let itemIndex = items.firstIndex(where: {
                    $0.domainProjection.id == itemID
                }) else {
                    preconditionFailure("A preview text delta requires a previously started item.")
                }
                var item = items[itemIndex].domainProjection
                item.content.appendPreviewText(delta)
                let fixtureItem = try makePreviewTestItem(
                    id: item.id,
                    kind: item.kind,
                    content: item.content,
                    cwd: fixture.cwd
                )
                items[itemIndex] = fixtureItem
                turns[turnIndex] = try turns[turnIndex].replacingItems(items)
                await self.threadStore.upsert(try stored.replacingTurns(turns))
                return ReviewMonitorPreviewStoredThreadItem(
                    item: item,
                    turnID: turns[turnIndex].snapshot.id,
                    fixtureItem: fixtureItem
                )
            } catch {
                preconditionFailure("Failed to append Preview stored text: \(error)")
            }
        }
    }

    private func emitItemLifecycle(
        _ storedItem: ReviewMonitorPreviewStoredThreadItem,
        for fixture: ReviewMonitorPreviewChatLogFixture,
        using runtime: CodexAppServerTestRuntime
    ) async throws {
        guard let fixtureItem = storedItem.fixtureItem else {
            preconditionFailure("A preview item lifecycle event requires its canonical fixture item.")
        }
        if storedItem.item.isTerminalPreviewItem {
            try await runtime.notificationEmitter.emitItemCompleted(
                threadID: fixture.chatID,
                turnID: storedItem.turnID,
                item: fixtureItem
            )
        } else {
            try await runtime.notificationEmitter.emitItemStarted(
                threadID: fixture.chatID,
                turnID: storedItem.turnID,
                item: fixtureItem
            )
        }
    }

    private func emitTextDelta(
        _ delta: String,
        itemID: String,
        turnID: CodexTurnID,
        chatID: CodexThreadID,
        kind: CodexThreadItem.Kind,
        content: CodexThreadItem.Content,
        runtime: CodexAppServerTestRuntime
    ) async throws {
        guard delta.isEmpty == false else {
            return
        }
        if isReasoningDelta(kind: kind, content: content) {
            if case .reasoning(let reasoning) = content,
               reasoning.summary.isEmpty == false {
                try await runtime.notificationEmitter.emitReasoningSummaryTextDelta(
                    threadID: chatID,
                    turnID: turnID,
                    itemID: itemID,
                    summaryIndex: 0,
                    delta: delta
                )
            } else {
                try await runtime.notificationEmitter.emitReasoningTextDelta(
                    threadID: chatID,
                    turnID: turnID,
                    itemID: itemID,
                    contentIndex: 0,
                    delta: delta
                )
            }
            return
        }
        switch kind {
        case .commandExecution:
            try await runtime.notificationEmitter.emitCommandExecutionOutputDelta(
                threadID: chatID,
                turnID: turnID,
                itemID: itemID,
                delta: delta
            )
        case .fileChange:
            guard case .fileChange(let fileChange) = content,
                  let path = fileChange.path,
                  let output = fileChange.output else {
                throw CodexAppServerTestError.invalidFixture(
                    "Preview file-change deltas require a path and accumulated diff."
                )
            }
            try await runtime.notificationEmitter.emitFileChangePatchUpdated(
                threadID: chatID,
                turnID: turnID,
                itemID: itemID,
                changes: [.init(path: path, kind: .update(movePath: nil), diff: output)]
            )
        case .mcpToolCall:
            guard case .toolCall(let toolCall) = content,
                  let message = toolCall.result else {
                throw CodexAppServerTestError.invalidFixture(
                    "Preview MCP progress requires an accumulated result message."
                )
            }
            try await runtime.notificationEmitter.emitMCPToolCallProgress(
                threadID: chatID,
                turnID: turnID,
                itemID: itemID,
                message: message
            )
        case .plan:
            try await runtime.notificationEmitter.emitPlanDelta(
                threadID: chatID,
                turnID: turnID,
                itemID: itemID,
                delta: delta
            )
        case .dynamicToolCall, .collabAgentToolCall, .subAgentActivity:
            throw CodexAppServerTestError.invalidFixture(
                "Unsupported Preview current-v2 delta kind \(kind.rawValue)."
            )
        default:
            try await runtime.notificationEmitter.emitAgentMessageDelta(
                threadID: chatID,
                turnID: turnID,
                itemID: itemID,
                delta: delta
            )
        }
    }

    private func isReasoningDelta(
        kind: CodexThreadItem.Kind,
        content: CodexThreadItem.Content
    ) -> Bool {
        if kind == .reasoning {
            return true
        }
        if case .reasoning = content {
            return true
        }
        return false
    }

    private func emitCancelledState(
        _ storedThread: CodexAppServerTestStoredThread,
        for fixture: ReviewMonitorPreviewChatLogFixture,
        using runtime: CodexAppServerTestRuntime
    ) async throws {
        try await runtime.notificationEmitter.emitThreadStatusChanged(
            threadID: fixture.chatID,
            status: .idle
        )
        guard let turn = storedThread.turns.last else {
            preconditionFailure("A cancelled Preview thread must own its interrupted turn.")
        }
        try await runtime.notificationEmitter.emitTurnCompleted(
            threadID: fixture.chatID,
            turn: turn
        )
        turnCompletionNotificationCount += 1
    }
}

private func makePreviewStoredThread(
    chatID: CodexThreadID,
    title: String,
    preview: String,
    model: String,
    modelProvider: String,
    workspaceCWD: String,
    createdAt: Date,
    updatedAt: Date,
    recencyAt: Date?,
    status: CodexThreadStatus,
    cwd: String,
    initialThreadSnapshot: CodexThreadSnapshot
) throws -> CodexAppServerTestStoredThread {
    guard initialThreadSnapshot.id == chatID else {
        throw CodexAppServerTestError.invalidFixture(
            "Preview thread identity must match its initial snapshot."
        )
    }
    let workspace = URL(fileURLWithPath: workspaceCWD, isDirectory: true)
    guard model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        throw CodexAppServerTestError.invalidFixture(
            "Preview stored threads require an explicit model."
        )
    }
    guard let initialTurns = initialThreadSnapshot.turns,
          initialTurns.isEmpty == false else {
        throw CodexAppServerTestError.invalidFixture(
            "Preview stored threads require an explicit turn."
        )
    }
    guard modelProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        throw CodexAppServerTestError.invalidFixture(
            "Preview stored threads require an explicit model provider."
        )
    }
    let turns = try initialTurns.map { turn in
        let items = try turn.items.map {
            try makePreviewTestItem(
                id: $0.id,
                kind: $0.kind,
                content: $0.content,
                cwd: cwd
            )
        }
        var snapshot = turn
        snapshot.items = items.map(\.domainProjection)
        return try CodexAppServerTestTurn(snapshot: snapshot, items: items)
    }
    return try .init(
        snapshot: .init(
            id: chatID,
            workspace: workspace,
            name: title,
            preview: preview,
            modelProvider: modelProvider,
            sourceKind: .subAgentReview,
            createdAt: createdAt.previewWholeSecondDate,
            updatedAt: updatedAt.previewWholeSecondDate,
            recencyAt: recencyAt?.previewWholeSecondDate,
            status: status,
            ephemeral: false,
            turns: turns.map(\.snapshot)
        ),
        turns: turns,
        metadata: .init(
            sessionID: "preview-session-\(chatID.rawValue)",
            cliVersion: "codex-preview",
            source: .subAgentReview
        ),
        runtimeMetadata: .init(
            model: model,
            modelProvider: modelProvider,
            serviceTier: nil,
            cwd: workspace,
            runtimeWorkspaceRoots: [workspace],
            instructionSources: [],
            approvalPolicy: .never,
            approvalsReviewer: .user,
            sandbox: .dangerFullAccess,
            activePermissionProfile: nil,
            reasoningEffort: nil,
            multiAgentMode: .explicitRequestOnly
        ),
        isArchived: false
    )
}

private func makePreviewTestItem(
    id: String,
    kind: CodexThreadItem.Kind,
    content: CodexThreadItem.Content,
    cwd: String
) throws -> CodexAppServerTestItem {
    switch (kind, content) {
    case (.userMessage, .message(let message)):
        return try .userMessage(id: id, text: message.text)
    case (.enteredReviewMode, .log(let review)):
        return try .enteredReviewMode(id: id, review: review)
    case (.exitedReviewMode, .log(let review)):
        return try .exitedReviewMode(id: id, review: review)
    default:
        break
    }
    switch content {
    case .message(let message):
        return try .agentMessage(id: id, text: message.text, phase: message.phase)
    case .plan(let text):
        return try .plan(id: id, text: text)
    case .reasoning(let reasoning):
        return try .reasoning(id: id, summary: reasoning.summary, content: reasoning.content)
    case .command(let command):
        return try .commandExecution(
            id: id,
            command: command.command,
            cwd: URL(fileURLWithPath: command.cwd ?? cwd, isDirectory: true),
            processID: command.processID,
            source: .agent,
            status: command.status.previewCommandStatus,
            aggregatedOutput: command.output,
            exitCode: command.exitCode.flatMap(Int32.init(exactly:)),
            duration: command.duration
        )
    case .fileChange(let fileChange):
        let path = fileChange.path ?? URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent("Preview.patch")
            .path
        return try .fileChange(
            id: id,
            changes: [
                CodexFileUpdateChange(
                    path: path,
                    kind: .update(movePath: nil),
                    diff: fileChange.output ?? ""
                )
            ],
            status: fileChange.status.previewPatchStatus
        )
    case .toolCall(let toolCall):
        guard let server = toolCall.server, let tool = toolCall.name else {
            throw CodexAppServerTestError.invalidFixture(
                "Preview MCP tool calls require server and tool names."
            )
        }
        let result = previewMCPResultComponents(toolCall.result)
        return try .mcpToolCall(
            id: id,
            server: server,
            tool: tool,
            status: toolCall.status.previewMCPStatus,
            resultContent: result.content,
            structuredContent: result.structuredContent,
            resultMetadata: result.metadata,
            errorMessage: toolCall.error
        )
    case .contextCompaction(let text):
        guard text?.isEmpty != false else {
            throw CodexAppServerTestError.invalidFixture(
                "Current-v2 context-compaction fixtures do not carry display text."
            )
        }
        return try .contextCompaction(id: id)
    case .diagnostic, .log, .unknown:
        throw CodexAppServerTestError.invalidFixture(
            "Unsupported current-v2 preview item kind \(kind.rawValue)."
        )
    }
}

func previewMCPResultComponents(
    _ flattenedResult: String?
) -> (
    content: [CodexJSONValue]?,
    structuredContent: CodexJSONValue?,
    metadata: CodexJSONValue?
) {
    guard let flattenedResult else {
        return (nil, nil, nil)
    }
    if let data = flattenedResult.data(using: .utf8),
       let value = try? JSONDecoder().decode(CodexJSONValue.self, from: data),
       case .object(let fields) = value,
       case .array(let content)? = fields["content"] {
        return (
            content,
            fields["structuredContent"]?.nilIfJSONNull,
            fields["_meta"]?.nilIfJSONNull
        )
    }
    return ([.string(flattenedResult)], nil, nil)
}

private extension CodexJSONValue {
    var nilIfJSONNull: Self? {
        self == .null ? nil : self
    }
}

private extension Optional where Wrapped == CodexTurnStatus {
    var previewCommandStatus: CodexAppServerTestItem.CommandStatus {
        switch self {
        case .some(.completed): .completed
        case .some(.failed), .some(.interrupted): .failed
        case .some(.inProgress), .some(.unknown), .none: .inProgress
        }
    }

    var previewPatchStatus: CodexAppServerTestItem.PatchStatus {
        switch self {
        case .some(.completed): .completed
        case .some(.failed), .some(.interrupted): .failed
        case .some(.inProgress), .some(.unknown), .none: .inProgress
        }
    }

    var previewMCPStatus: CodexAppServerTestItem.MCPStatus {
        switch self {
        case .some(.completed): .completed
        case .some(.failed), .some(.interrupted): .failed
        case .some(.inProgress), .some(.unknown), .none: .inProgress
        }
    }
}

private extension CodexThreadItem {
    var isTerminalPreviewItem: Bool {
        switch content {
        case .command(let command):
            command.status != nil && command.status != .inProgress
        case .fileChange(let fileChange):
            fileChange.status != nil && fileChange.status != .inProgress
        case .toolCall(let toolCall):
            toolCall.status != nil && toolCall.status != .inProgress
        default:
            false
        }
    }
}

private extension CodexTurnSnapshot.State {
    var isTerminalForPreview: Bool {
        switch self {
        case .completed, .failed, .interrupted:
            true
        case .inProgress, .unknown:
            false
        }
    }
}

private extension Array where Element == CodexAppServerTestTurn {
    func requirePreviewTurn() throws -> Index {
        guard isEmpty == false else {
            throw CodexAppServerTestError.invalidFixture(
                "A Preview stored thread must own an explicit turn."
            )
        }
        return index(before: endIndex)
    }
}

private extension Date {
    var previewWholeSecondDate: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.towardZero))
    }
}

private extension CodexThreadItem.Content {
    mutating func appendPreviewText(_ delta: String) {
        switch self {
        case .message(var message):
            message.text += delta
            self = .message(message)
        case .plan(let text):
            self = .plan(text + delta)
        case .reasoning(var reasoning):
            if reasoning.summary.isEmpty {
                append(delta, to: &reasoning.content)
            } else {
                append(delta, to: &reasoning.summary)
            }
            self = .reasoning(reasoning)
        case .command(var command):
            command.output = (command.output ?? "") + delta
            self = .command(command)
        case .fileChange(var fileChange):
            fileChange.output = (fileChange.output ?? "") + delta
            self = .fileChange(fileChange)
        case .toolCall(var toolCall):
            toolCall.result = (toolCall.result ?? "") + delta
            self = .toolCall(toolCall)
        case .contextCompaction(let text):
            self = .contextCompaction((text ?? "") + delta)
        case .diagnostic(let text):
            self = .diagnostic(text + delta)
        case .log(let text):
            self = .log(text + delta)
        case .unknown(var rawItem):
            rawItem.text = (rawItem.text ?? "") + delta
            self = .unknown(rawItem)
        }
    }

    private func append(_ delta: String, to parts: inout [String]) {
        if parts.isEmpty {
            parts.append(delta)
        } else {
            parts[parts.count - 1] += delta
        }
    }
}
