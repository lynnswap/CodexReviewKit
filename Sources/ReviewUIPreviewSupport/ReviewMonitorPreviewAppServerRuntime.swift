import CodexKit
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

    func interruptRequestCountForTesting() async -> Int {
        guard let runtime else {
            return 0
        }
        return await runtime.transport.recordedRequests(method: "turn/interrupt").count
    }

    func archiveRequestCountForTesting() async -> Int {
        guard let runtime else {
            return 0
        }
        return await runtime.transport.recordedRequests(method: "thread/archive").count
    }

    func upsertPreviewItem(
        id: String,
        kind: CodexThreadItem.Kind,
        content: CodexThreadItem.Content,
        to chatID: CodexThreadID
    ) async {
        guard let fixture = fixturesByChatID[chatID] else {
            return
        }
        guard let item = await upsertStoredItem(
            id: id,
            kind: kind,
            content: content,
            in: fixture
        ) else {
            return
        }
        start()
        enqueueNotification { [weak self] in
            await self?.emitItem(item, for: fixture)
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
            kind: kind,
            content: content,
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

    @discardableResult
    func appendPreviewStreamTick(
        after currentTick: Int = 0,
        emitsNotifications: Bool = false
    ) async -> Int {
        var runningFixtures: [ReviewMonitorPreviewChatLogFixture] = []
        for fixture in fixtures where fixture.isRunning {
            if await cancelledChatIDs.contains(fixture.chatID) == false {
                runningFixtures.append(fixture)
            }
        }
        guard runningFixtures.isEmpty == false else {
            return currentTick
        }

        if emitsNotifications {
            do {
                try await ensureStarted()
            } catch {
                return currentTick
            }
        }

        let nextTick = currentTick + 1
        for (index, fixture) in runningFixtures.enumerated() {
            guard let frame = ReviewMonitorPreviewContent.streamFrame(
                forRunningChatAt: index,
                tick: nextTick
            ) else {
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
                if turn.status.isTerminalForPreview == false {
                    turn.status = .cancelled
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
                await emitItem(storedItem, for: fixture)
            }
        } catch {
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
            return await upsertStoredItem(
                id: itemID,
                kind: step.kind,
                content: step.content,
                in: fixture
            )
        case .textDelta:
            return await appendStoredText(
                step.deltaText ?? "",
                itemID: itemID,
                kind: step.kind,
                content: step.content,
                in: fixture.chatID
            )
        }
    }

    private func upsertStoredItem(
        id: String,
        kind: CodexThreadItem.Kind,
        content: CodexThreadItem.Content,
        in fixture: ReviewMonitorPreviewChatLogFixture
    ) async -> ReviewMonitorPreviewStoredThreadItem? {
        let fallbackTurnID = fixture.previewFallbackTurnID
        return await updateStoredSnapshot(for: fixture) { snapshot in
            let turnID = snapshot.ensurePreviewTurn(fallback: fallbackTurnID)
            let item = CodexThreadItem(
                id: id,
                kind: kind,
                content: content
            )
            guard let turnIndex = snapshot.turns?.lastIndex(where: { $0.id == turnID }) else {
                return nil
            }
            if let itemIndex = snapshot.turns?[turnIndex].items.firstIndex(where: { $0.id == item.id }) {
                snapshot.turns?[turnIndex].items[itemIndex] = item
            } else {
                snapshot.turns?[turnIndex].items.append(item)
            }
            return ReviewMonitorPreviewStoredThreadItem(item: item, turnID: turnID)
        }
    }

    private func appendStoredText(
        _ delta: String,
        itemID: String,
        kind: CodexThreadItem.Kind,
        content: CodexThreadItem.Content,
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
                return ReviewMonitorPreviewStoredThreadItem(item: item, turnID: turnID)
            }
            var item = CodexThreadItem(
                id: itemID,
                kind: kind,
                content: content
            )
            item.content.appendPreviewText(delta)
            snapshot.turns?[turnIndex].items.append(item)
            return ReviewMonitorPreviewStoredThreadItem(item: item, turnID: turnID)
        }
    }

    private func updateStoredSnapshot(
        for fixture: ReviewMonitorPreviewChatLogFixture,
        _ mutation: @escaping @Sendable (inout CodexThreadSnapshot) -> ReviewMonitorPreviewStoredThreadItem?
    ) async -> ReviewMonitorPreviewStoredThreadItem? {
        await snapshotMutationQueue.run { @MainActor [weak self] in
            guard let self,
                  var snapshot = await self.threadStore.snapshot(id: fixture.chatID),
                  let item = mutation(&snapshot) else {
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
        }
    }

    private func emitItem(
        _ storedItem: ReviewMonitorPreviewStoredThreadItem,
        for fixture: ReviewMonitorPreviewChatLogFixture
    ) async {
        do {
            try await ensureStarted()
            guard let runtime else {
                return
            }
            await runtime.transport.waitForNotificationStreamCount(1)
            await runtime.transport.waitForRequest(method: "thread/read")
            try await runtime.transport.emitServerNotification(
                method: "item/updated",
                params: PreviewThreadItemParams(
                    threadID: fixture.chatID.rawValue,
                    turnID: storedItem.turnID.rawValue,
                    item: makePreviewNotificationItem(
                        id: storedItem.item.id,
                        kind: storedItem.item.kind,
                        content: storedItem.item.content
                    )
                )
            )
        } catch {
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
            let method: String
            let summaryIndex: Int?
            let contentIndex: Int?
            if case .reasoning(let reasoning) = content,
               reasoning.summary.isEmpty == false {
                method = "item/reasoning/summaryTextDelta"
                summaryIndex = 0
                contentIndex = nil
            } else {
                method = "item/reasoning/textDelta"
                summaryIndex = nil
                contentIndex = 0
            }
            try await runtime.transport.emitServerNotification(
                method: method,
                params: PreviewTurnDeltaParams(
                    threadID: chatID.rawValue,
                    turnID: turnID.rawValue,
                    itemID: itemID,
                    delta: delta,
                    phase: nil,
                    summaryIndex: summaryIndex,
                    contentIndex: contentIndex
                )
            )
            return
        }
        switch kind {
        case .commandExecution:
            try await emitOutputDelta(
                method: "item/commandExecution/outputDelta",
                delta: delta,
                itemID: itemID,
                turnID: turnID,
                chatID: chatID,
                runtime: runtime
            )
        case .fileChange:
            try await emitOutputDelta(
                method: "item/fileChange/outputDelta",
                delta: delta,
                itemID: itemID,
                turnID: turnID,
                chatID: chatID,
                runtime: runtime
            )
        case .mcpToolCall, .dynamicToolCall, .collabAgentToolCall, .subAgentActivity:
            try await emitOutputDelta(
                method: "item/mcpToolCall/progress",
                delta: delta,
                itemID: itemID,
                turnID: turnID,
                chatID: chatID,
                runtime: runtime
            )
        default:
            try await runtime.transport.emitServerNotification(
                method: "item/agentMessage/delta",
                params: PreviewTurnDeltaParams(
                    threadID: chatID.rawValue,
                    turnID: turnID.rawValue,
                    itemID: itemID,
                    delta: delta,
                    phase: "final_answer",
                    summaryIndex: nil,
                    contentIndex: nil
                )
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

    private func emitOutputDelta(
        method: String,
        delta: String,
        itemID: String,
        turnID: CodexTurnID,
        chatID: CodexThreadID,
        runtime: CodexAppServerTestRuntime
    ) async throws {
        try await runtime.transport.emitServerNotification(
            method: method,
            params: PreviewTurnDeltaParams(
                threadID: chatID.rawValue,
                turnID: turnID.rawValue,
                itemID: itemID,
                delta: delta,
                phase: nil,
                summaryIndex: nil,
                contentIndex: nil
            )
        )
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
            let turnID = snapshot.turns?.last?.id ?? fixture.previewFallbackTurnID
            try await runtime.transport.emitServerNotification(
                method: "thread/status/changed",
                params: PreviewThreadStatusParams(
                    threadID: fixture.chatID.rawValue,
                    status: .init(type: "idle")
                )
            )
            try await runtime.transport.emitServerNotification(
                method: "turn/completed",
                params: PreviewTurnCompletedParams(
                    threadID: fixture.chatID.rawValue,
                    turn: .init(
                        id: turnID.rawValue,
                        status: "cancelled",
                        completedAt: Int(Date().timeIntervalSince1970)
                    )
                )
            )
        } catch {
        }
    }
}

private struct PreviewTurnInterruptParams: Decodable, Sendable {
    var threadID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

private struct PreviewThreadItemParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var item: Item

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case item
    }

    struct Item: Encodable, Sendable {
        var id: String
        var type: String
        var text: String?
        var phase: String?
        var command: String?
        var cwd: String?
        var output: String?
        var exitCode: Int?
        var status: String?
        var path: String?
    }
}

private struct PreviewThreadArchiveParams: Decodable, Sendable {
    var threadID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

private struct PreviewThreadStatusParams: Encodable, Sendable {
    var threadID: String
    var status: Status

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case status
    }

    struct Status: Encodable, Sendable {
        var type: String
    }
}

private struct PreviewTurnCompletedParams: Encodable, Sendable {
    var threadID: String
    var turn: Turn

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
    }

    struct Turn: Encodable, Sendable {
        var id: String
        var status: String?
        var completedAt: Int?
    }
}

private extension Optional where Wrapped == CodexTurnStatus {
    var isTerminalForPreview: Bool {
        switch self {
        case .completed?, .failed?, .interrupted?, .cancelled?:
            true
        case .running?, .unknown?, nil:
            false
        }
    }
}

private struct PreviewTurnDeltaParams: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var delta: String
    var phase: String?
    var summaryIndex: Int?
    var contentIndex: Int?

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case delta
        case phase
        case summaryIndex
        case contentIndex
    }
}

private func makePreviewNotificationItem(
    id: String,
    kind: CodexThreadItem.Kind,
    content: CodexThreadItem.Content
) -> PreviewThreadItemParams.Item {
    PreviewThreadItemParams.Item(
        id: id,
        type: previewNotificationItemType(kind: kind, content: content),
        text: previewNotificationText(content),
        phase: previewNotificationPhase(content),
        command: previewNotificationCommand(content),
        cwd: previewNotificationCWD(content),
        output: previewNotificationOutput(content),
        exitCode: previewNotificationExitCode(content),
        status: previewNotificationStatus(content),
        path: previewNotificationPath(content)
    )
}

private func previewNotificationItemType(
    kind: CodexThreadItem.Kind,
    content: CodexThreadItem.Content
) -> String {
    switch content {
    case .diagnostic:
        "diagnostic"
    default:
        kind.rawValue
    }
}

private func previewNotificationText(_ content: CodexThreadItem.Content) -> String? {
    switch content {
    case .message(let message):
        message.text
    case .plan(let text), .diagnostic(let text), .log(let text):
        text
    case .reasoning(let reasoning):
        reasoning.text
    case .toolCall(let toolCall):
        toolCall.result ?? toolCall.error ?? toolCall.name
    case .contextCompaction(let text):
        text
    case .command, .fileChange, .unknown:
        nil
    }
}

private func previewNotificationPhase(_ content: CodexThreadItem.Content) -> String? {
    if case .message(let message) = content {
        return message.phase?.rawValue
    }
    return nil
}

private func previewNotificationCommand(_ content: CodexThreadItem.Content) -> String? {
    if case .command(let command) = content {
        return command.command
    }
    return nil
}

private func previewNotificationCWD(_ content: CodexThreadItem.Content) -> String? {
    if case .command(let command) = content {
        return command.cwd
    }
    return nil
}

private func previewNotificationOutput(_ content: CodexThreadItem.Content) -> String? {
    switch content {
    case .command(let command):
        return command.output
    case .fileChange(let fileChange):
        return fileChange.output
    default:
        return nil
    }
}

private func previewNotificationExitCode(_ content: CodexThreadItem.Content) -> Int? {
    if case .command(let command) = content {
        return command.exitCode
    }
    return nil
}

private func previewNotificationStatus(_ content: CodexThreadItem.Content) -> String? {
    switch content {
    case .command(let command):
        command.status?.rawValue
    case .fileChange(let fileChange):
        fileChange.status?.rawValue
    case .toolCall(let toolCall):
        toolCall.status?.rawValue
    default:
        nil
    }
}

private func previewNotificationPath(_ content: CodexThreadItem.Content) -> String? {
    if case .fileChange(let fileChange) = content {
        return fileChange.path
    }
    return nil
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
        turns = [CodexTurnSnapshot(id: turnID, status: .running)]
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
