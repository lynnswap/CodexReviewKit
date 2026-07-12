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

private actor ReviewMonitorPreviewArchivedChatIDs {
    private var ids: Set<CodexThreadID> = []

    func insert(_ id: CodexThreadID) {
        ids.insert(id)
    }

    func contains(_ id: CodexThreadID) -> Bool {
        ids.contains(id)
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

private struct ReviewMonitorPreviewStoredThreadItem: Sendable {
    var item: CodexThreadItem
    var turnID: CodexTurnID
    var fixtureItem: CodexAppServerTestItem?
}

@MainActor
struct ReviewMonitorPreviewChatLogFixture {
    let chatID: CodexThreadID
    let title: String
    let preview: String?
    let model: String?
    let workspaceCWD: String?
    let updatedAt: Date?
    let recencyAt: Date?
    let status: CodexThreadStatus?
    let cwd: String
    let streamID: String
    let isRunning: Bool
    let initialThreadSnapshot: CodexThreadSnapshot

    init(
        chatID: CodexThreadID,
        title: String,
        preview: String?,
        model: String?,
        workspaceCWD: String?,
        updatedAt: Date?,
        recencyAt: Date?,
        status: CodexThreadStatus?,
        cwd: String,
        streamID: String,
        isRunning: Bool,
        initialThreadSnapshot: CodexThreadSnapshot
    ) {
        self.chatID = chatID
        self.title = title
        self.preview = preview
        self.model = model
        self.workspaceCWD = workspaceCWD
        self.updatedAt = updatedAt
        self.recencyAt = recencyAt
        self.status = status
        self.cwd = cwd
        self.streamID = streamID
        self.isRunning = isRunning
        self.initialThreadSnapshot = initialThreadSnapshot
    }
}

@MainActor
final class ReviewMonitorPreviewAppServerRuntime {
    let modelSource = ReviewMonitorCodexModelSource()

    private let fixtures: [ReviewMonitorPreviewChatLogFixture]
    private let fixturesByChatID: [CodexThreadID: ReviewMonitorPreviewChatLogFixture]
    private var threadStore: CodexAppServerTestThreadStore
    private var runtime: CodexAppServerTestRuntime?
    private var container: CodexModelContainer?
    private var startTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var turnCompletionNotificationCount = 0
    private let snapshotMutationQueue = ReviewMonitorPreviewSnapshotMutationQueue()
    private let archivedChatIDs = ReviewMonitorPreviewArchivedChatIDs()
    private let cancelledChatIDs = ReviewMonitorPreviewCancelledChatIDs()
    private var tick = 0

    init(fixtures: [ReviewMonitorPreviewChatLogFixture]) {
        self.fixtures = fixtures
        self.fixturesByChatID = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.chatID, $0) })
        self.threadStore = CodexAppServerTestThreadStore(
            threads: fixtures.map(\.threadSnapshot)
        )
    }

    isolated deinit {
        startTask?.cancel()
        streamTask?.cancel()
        notificationTask?.cancel()
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
        await threadStore.snapshot(id: chatID)
    }

    func observedTurnStateForTesting(
        chatID: CodexThreadID
    ) -> CodexTurnSnapshot.State? {
        container?.mainContext.registeredModel(for: chatID)?.turns.last?.state
    }

    func interruptRequestCountForTesting() async -> Int {
        guard let runtime else {
            return 0
        }
        return await runtime.transport.recordedRequests(method: "turn/interrupt").count
    }

    func turnCompletionNotificationCountForTesting() -> Int {
        turnCompletionNotificationCount
    }

    func archiveRequestCountForTesting() async -> Int {
        guard let runtime else {
            return 0
        }
        return await runtime.transport.recordedRequests(method: "thread/archive").count
    }

    func upsertPreviewItem(
        _ item: CodexAppServerTestItem,
        to chatID: CodexThreadID
    ) async {
        guard let fixture = fixturesByChatID[chatID] else {
            return
        }
        guard let storedItem = await upsertStoredItem(item, in: fixture) else {
            return
        }
        start()
        enqueueNotification { [weak self] in
            await self?.emitItemLifecycle(storedItem, for: fixture)
        }
    }

    func appendPreviewText(
        _ delta: String,
        to chatID: CodexThreadID,
        itemID: String,
        kind: CodexThreadItem.Kind,
        content: CodexThreadItem.Content
    ) async {
        guard delta.isEmpty == false,
              fixturesByChatID[chatID] != nil else {
            return
        }
        guard let item = await appendStoredText(
            delta,
            itemID: itemID,
            in: chatID
        ) else {
            return
        }
        start()
        enqueueNotification { [weak self] in
            do {
                try await self?.ensureStarted()
                guard let runtime = self?.runtime else {
                    return
                }
                try await self?.emitTextDelta(
                    delta,
                    itemID: itemID,
                    turnID: item.turnID,
                    chatID: chatID,
                    kind: kind,
                    content: item.item.content,
                    runtime: runtime
                )
            } catch {
                preconditionFailure("Failed to append Preview text: \(error)")
            }
        }
    }

    private func enqueueNotification(_ operation: @escaping @MainActor () async -> Void) {
        let previousTask = notificationTask
        notificationTask = Task { @MainActor in
            await previousTask?.value
            await operation()
        }
    }

    func start() {
        guard startTask == nil, runtime == nil else {
            return
        }
        startTask = Task { @MainActor [weak self] in
            do {
                try await self?.startNow()
            } catch {
                preconditionFailure("Failed to start the Preview app-server runtime: \(error)")
            }
        }
    }

    func startStreaming(interval: Duration) {
        start()
        guard streamTask == nil else {
            return
        }
        streamTask = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: interval)
                guard let self, Task.isCancelled == false else {
                    return
                }
                _ = await self.appendPreviewStreamTick(
                    after: self.tick,
                    emitsNotifications: true
                )
            }
        }
    }

    func cancelStreaming() {
        streamTask?.cancel()
    }

    func stopStreaming() async {
        let task = streamTask
        streamTask = nil
        task?.cancel()
        await task?.value
        await notificationTask?.value
    }

    @discardableResult
    func appendPreviewStreamTick(
        after currentTick: Int = 0,
        emitsNotifications: Bool = false
    ) async -> Int {
        var runningFixtures: [(index: Int, fixture: ReviewMonitorPreviewChatLogFixture)] = []
        for (index, fixture) in fixtures.filter(\.isRunning).enumerated() {
            if await cancelledChatIDs.contains(fixture.chatID) == false,
                await archivedChatIDs.contains(fixture.chatID) == false
            {
                runningFixtures.append((index, fixture))
            }
        }
        guard runningFixtures.isEmpty == false else {
            return currentTick
        }

        if emitsNotifications {
            do {
                try await ensureStarted()
            } catch {
                preconditionFailure("Failed to start the Preview app-server runtime while streaming: \(error)")
            }
        }

        let nextTick = currentTick + 1
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
            if emitsNotifications {
                enqueueNotification { [weak self] in
                    await self?.emit(frame.step, storedItem: storedItem, for: fixture)
                }
            }
        }
        tick = nextTick
        return nextTick
    }

    private func ensureStarted() async throws {
        if runtime != nil {
            return
        }
        if let startTask {
            await startTask.value
            return
        }
        try await startNow()
    }

    private func startNow() async throws {
        if runtime != nil {
            return
        }
        let runtime = try await CodexAppServerTestRuntime.start(threadStore: threadStore)
        let container = CodexModelContainer(appServer: runtime.server)
        self.runtime = runtime
        try await rebindRuntimeToCurrentThreadStore(runtime)
        await runtime.transport.handle(method: "turn/interrupt") { params in
            let request = try JSONDecoder().decode(PreviewTurnInterruptParams.self, from: params)
            let threadID = CodexThreadID(rawValue: request.threadID)
            await self.cancelPreviewChat(threadID)
            return Data("{}".utf8)
        }
        self.container = container
        modelSource.install(container: container)
    }

    private func rebindRuntimeToCurrentThreadStore(_ runtime: CodexAppServerTestRuntime) async throws {
        var reboundStore: CodexAppServerTestThreadStore
        repeat {
            reboundStore = threadStore
            try await runtime.transport.stubThreads(reboundStore)
            let archivedChatIDs = archivedChatIDs
            let store = reboundStore
            await runtime.transport.handle(method: "thread/archive") { params in
                let request = try JSONDecoder().decode(PreviewThreadArchiveParams.self, from: params)
                let threadID = CodexThreadID(rawValue: request.threadID)
                await archivedChatIDs.insert(threadID)
                await store.remove(id: threadID)
                return Data("{}".utf8)
            }
        } while reboundStore !== threadStore
    }

    private func cancelPreviewChat(_ chatID: CodexThreadID) async {
        guard let fixture = fixturesByChatID[chatID] else {
            return
        }
        await cancelledChatIDs.insert(chatID)
        guard let cancelledSnapshot = await updateStoredSnapshot(for: fixture, mutation: { snapshot in
            snapshot.turns = snapshot.turns?.map { turn in
                var turn = turn
                if turn.state.isTerminalForPreview == false {
                    turn.state = .interrupted
                }
                return turn
            }
        }) else {
            return
        }
        enqueueNotification { [weak self] in
            await self?.emitCancelledState(cancelledSnapshot, for: fixture)
        }
    }

    private func emit(
        _ step: ReviewMonitorPreviewContent.PreviewChatLogStreamStep,
        storedItem: ReviewMonitorPreviewStoredThreadItem,
        for fixture: ReviewMonitorPreviewChatLogFixture
    ) async {
        guard let runtime else {
            return
        }
        do {
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
                await runtime.transport.waitForNotificationStreamCount(1)
                await runtime.transport.waitForRequest(method: "thread/read")
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
        } catch {
            preconditionFailure("Failed to emit a Preview stream item: \(error)")
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
        let fallbackTurnID = fixture.previewFallbackTurnID
        return await updateStoredSnapshot(for: fixture) { snapshot in
            let turnID = snapshot.ensurePreviewTurn(fallback: fallbackTurnID)
            let item = fixtureItem.domainProjection
            guard let turnIndex = snapshot.turns?.lastIndex(where: { $0.id == turnID }) else {
                return nil
            }
            if let itemIndex = snapshot.turns?[turnIndex].items.firstIndex(where: { $0.id == item.id }) {
                snapshot.turns?[turnIndex].items[itemIndex] = item
            } else {
                snapshot.turns?[turnIndex].items.append(item)
            }
            return ReviewMonitorPreviewStoredThreadItem(
                item: item,
                turnID: turnID,
                fixtureItem: fixtureItem
            )
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
        let fallbackTurnID = fixture.previewFallbackTurnID
        return await updateStoredSnapshot(for: fixture) { snapshot in
            let turnID = snapshot.ensurePreviewTurn(fallback: fallbackTurnID)
            guard let turnIndex = snapshot.turns?.lastIndex(where: { $0.id == turnID }) else {
                return nil
            }
            if let itemIndex = snapshot.turns?[turnIndex].items.firstIndex(where: { $0.id == itemID }) {
                snapshot.turns?[turnIndex].items[itemIndex].content.appendPreviewText(delta)
                guard let item = snapshot.turns?[turnIndex].items[itemIndex] else {
                    return nil
                }
                return ReviewMonitorPreviewStoredThreadItem(
                    item: item,
                    turnID: turnID,
                    fixtureItem: nil
                )
            }
            preconditionFailure("A preview text delta requires a previously started item.")
        }
    }

    private func emitItemLifecycle(
        _ storedItem: ReviewMonitorPreviewStoredThreadItem,
        for fixture: ReviewMonitorPreviewChatLogFixture
    ) async {
        do {
            try await ensureStarted()
            guard let runtime, let fixtureItem = storedItem.fixtureItem else {
                return
            }
            await runtime.transport.waitForNotificationStreamCount(1)
            await runtime.transport.waitForRequest(method: "thread/read")
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
        } catch {
            preconditionFailure("Failed to emit preview item lifecycle: \(error)")
        }
    }

    private func updateStoredSnapshot(
        for fixture: ReviewMonitorPreviewChatLogFixture,
        _ mutation: @escaping @Sendable (inout CodexThreadSnapshot) -> ReviewMonitorPreviewStoredThreadItem?
    ) async -> ReviewMonitorPreviewStoredThreadItem? {
        await snapshotMutationQueue.run { @MainActor [weak self] in
            guard let self,
                await self.cancelledChatIDs.contains(fixture.chatID) == false,
                await self.archivedChatIDs.contains(fixture.chatID) == false,
                var snapshot = await self.threadStore.snapshot(id: fixture.chatID),
                let item = mutation(&snapshot)
            else {
                return nil
            }
            await self.replaceThreadStorePreservingFixtureOrder(
                with: fixture.threadSnapshot(snapshot)
            )
            return item
        }
    }

    private func updateStoredSnapshot(
        for fixture: ReviewMonitorPreviewChatLogFixture,
        mutation: @escaping @Sendable (inout CodexThreadSnapshot) -> Void
    ) async -> CodexThreadSnapshot? {
        await snapshotMutationQueue.run { @MainActor [weak self] in
            guard let self,
                  var snapshot = await self.threadStore.snapshot(id: fixture.chatID) else {
                return nil
            }
            mutation(&snapshot)
            await self.replaceThreadStorePreservingFixtureOrder(
                with: fixture.threadSnapshot(snapshot, status: .idle)
            )
            return snapshot
        }
    }

    private func replaceThreadStorePreservingFixtureOrder(
        with updatedSnapshot: CodexThreadSnapshot
    ) async {
        let currentStore = threadStore
        let storedSnapshots = await currentStore.snapshots()
        let fixtureSnapshotIDs = Set(fixtures.map(\.chatID))
        var orderedFixtureSnapshots: [CodexThreadSnapshot] = []
        for fixture in fixtures {
            if await archivedChatIDs.contains(fixture.chatID) {
                continue
            }
            if fixture.chatID == updatedSnapshot.id {
                orderedFixtureSnapshots.append(updatedSnapshot)
                continue
            }
            orderedFixtureSnapshots.append(
                await currentStore.snapshot(id: fixture.chatID) ?? fixture.threadSnapshot
            )
        }
        let nonFixtureSnapshots = storedSnapshots.filter { snapshot in
            fixtureSnapshotIDs.contains(snapshot.id) == false
        }
        let replacementStore = CodexAppServerTestThreadStore(
            threads: orderedFixtureSnapshots + nonFixtureSnapshots
        )
        threadStore = replacementStore
        do {
            if let runtime {
                try await rebindRuntimeToCurrentThreadStore(runtime)
            }
        } catch {
            preconditionFailure("Failed to rebind the Preview thread store: \(error)")
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
        await runtime.transport.waitForNotificationStreamCount(1)
        await runtime.transport.waitForRequest(method: "thread/read")
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
        _ snapshot: CodexThreadSnapshot,
        for fixture: ReviewMonitorPreviewChatLogFixture
    ) async {
        do {
            try await ensureStarted()
            guard let runtime else {
                return
            }
            await runtime.transport.waitForNotificationStreamCount(1)
            try await runtime.notificationEmitter.emitThreadStatusChanged(
                threadID: fixture.chatID,
                status: .idle
            )
            let turn = snapshot.turns?.last ?? CodexTurnSnapshot(
                id: fixture.previewFallbackTurnID,
                state: .interrupted
            )
            let items = try turn.items.map {
                try makePreviewTestItem(
                    id: $0.id,
                    kind: $0.kind,
                    content: $0.content,
                    cwd: fixture.cwd
                )
            }
            try await runtime.notificationEmitter.emitTurnCompleted(
                threadID: fixture.chatID,
                turn: CodexAppServerTestTurn(snapshot: turn, items: items)
            )
            turnCompletionNotificationCount += 1
        } catch {
            preconditionFailure("Failed to emit a cancelled Preview turn: \(error)")
        }
    }
}

private struct PreviewTurnInterruptParams: Decodable, Sendable {
    var threadID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

private func makePreviewTestItem(
    id: String,
    kind: CodexThreadItem.Kind,
    content: CodexThreadItem.Content,
    cwd: String
) throws -> CodexAppServerTestItem {
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

private struct PreviewThreadArchiveParams: Decodable, Sendable {
    var threadID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
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

private extension ReviewMonitorPreviewChatLogFixture {
    var threadSnapshot: CodexThreadSnapshot {
        threadSnapshot(initialThreadSnapshot)
    }

    var previewFallbackTurnID: CodexTurnID {
        initialThreadSnapshot.turns?.last?.id ?? CodexTurnID(rawValue: "preview-turn")
    }

    func threadSnapshot(
        _ snapshot: CodexThreadSnapshot,
        status: CodexThreadStatus? = nil
    ) -> CodexThreadSnapshot {
        CodexThreadSnapshot(
            id: chatID,
            workspace: workspaceCWD.map { URL(fileURLWithPath: $0, isDirectory: true) },
            name: title,
            preview: preview,
            modelProvider: model,
            updatedAt: updatedAt,
            recencyAt: recencyAt,
            status: status ?? self.status,
            turns: snapshot.turns
        )
    }
}

private extension CodexThreadSnapshot {
    mutating func ensurePreviewTurn(fallback turnID: CodexTurnID) -> CodexTurnID {
        if let existingTurnID = turns?.last?.id {
            return existingTurnID
        }
        turns = [CodexTurnSnapshot(id: turnID, state: .inProgress)]
        return turnID
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
