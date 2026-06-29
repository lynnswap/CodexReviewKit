import CodexKit
import CodexAppServerKitTesting
import CodexReviewKit
import Foundation
import ReviewUI

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
    let initialSnapshot: CodexChatSnapshot

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
        initialSnapshot: CodexChatSnapshot
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
        self.initialSnapshot = initialSnapshot
    }
}

@MainActor
final class ReviewMonitorPreviewAppServerRuntime {
    let modelSource = ReviewMonitorCodexModelSource()

    private let fixtures: [ReviewMonitorPreviewChatLogFixture]
    private let fixturesByChatID: [CodexThreadID: ReviewMonitorPreviewChatLogFixture]
    private let threadStore: CodexAppServerTestThreadStore
    private var runtime: CodexAppServerTestRuntime?
    private var container: CodexModelContainer?
    private var startTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
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

    func snapshotForTesting(chatID: CodexThreadID) async -> CodexChatSnapshot? {
        await threadStore.snapshot(id: chatID)?.chatSnapshot
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
                    turnID: item.turnID ?? CodexTurnID(rawValue: "preview-turn"),
                    chatID: chatID,
                    kind: kind,
                    content: item.content,
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
        let runningFixtures = fixtures.filter(\.isRunning)
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
            guard let item = await apply(frame.step, cycle: frame.cycle, for: fixture) else {
                continue
            }
            if emitsNotifications {
                enqueueNotification { [weak self] in
                    await self?.emit(frame.step, item: item, for: fixture)
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
        self.container = container
        modelSource.install(container: container)
    }

    private func emit(
        _ step: ReviewMonitorPreviewContent.PreviewChatLogStreamStep,
        item: CodexChatItemSnapshot,
        for fixture: ReviewMonitorPreviewChatLogFixture
    ) async {
        guard let runtime else {
            return
        }
        let turnID = item.turnID ?? fixture.initialSnapshot.turns.last?.id ?? CodexTurnID(rawValue: "preview-turn")
        do {
            switch step.mode {
            case .textDelta:
                try await emitTextDelta(
                    step.deltaText ?? "",
                    itemID: item.id,
                    turnID: turnID,
                    chatID: fixture.chatID,
                    kind: item.kind,
                    content: item.content,
                    runtime: runtime
                )
            case .update, .complete:
                await emitItem(item, for: fixture)
            }
        } catch {
        }
    }

    private func apply(
        _ step: ReviewMonitorPreviewContent.PreviewChatLogStreamStep,
        cycle: Int,
        for fixture: ReviewMonitorPreviewChatLogFixture
    ) async -> CodexChatItemSnapshot? {
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
    ) async -> CodexChatItemSnapshot? {
        await updateStoredSnapshot(for: fixture) { snapshot in
            let item = CodexChatItemSnapshot(
                id: id,
                turnID: snapshot.turns.last?.id,
                kind: kind,
                content: content
            )
            if let index = snapshot.items.firstIndex(where: { $0.id == item.id && $0.turnID == item.turnID }) {
                snapshot.items[index] = item
            } else {
                snapshot.items.append(item)
            }
            return item
        }
    }

    private func appendStoredText(
        _ delta: String,
        itemID: String,
        kind: CodexThreadItem.Kind,
        content: CodexThreadItem.Content,
        in chatID: CodexThreadID
    ) async -> CodexChatItemSnapshot? {
        guard delta.isEmpty == false,
              let fixture = fixturesByChatID[chatID] else {
            return nil
        }
        return await updateStoredSnapshot(for: fixture) { snapshot in
            let turnID = snapshot.turns.last?.id
            if let index = snapshot.items.firstIndex(where: { $0.id == itemID && $0.turnID == turnID }) {
                snapshot.items[index].content.appendPreviewText(delta)
                return snapshot.items[index]
            }
            var item = CodexChatItemSnapshot(
                id: itemID,
                turnID: turnID,
                kind: kind,
                content: content
            )
            item.content.appendPreviewText(delta)
            snapshot.items.append(item)
            return item
        }
    }

    private func updateStoredSnapshot(
        for fixture: ReviewMonitorPreviewChatLogFixture,
        _ mutation: (inout CodexChatSnapshot) -> CodexChatItemSnapshot?
    ) async -> CodexChatItemSnapshot? {
        guard var snapshot = await threadStore.snapshot(id: fixture.chatID)?.chatSnapshot,
              let item = mutation(&snapshot) else {
            return nil
        }
        await threadStore.upsert(fixture.threadSnapshot(snapshot))
        return item
    }

    private func emitItem(
        _ item: CodexChatItemSnapshot,
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
                    turnID: item.turnID?.rawValue ?? fixture.initialSnapshot.turns.last?.id.rawValue ?? "preview-turn",
                    item: makePreviewNotificationItem(id: item.id, kind: item.kind, content: item.content)
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
        threadSnapshot(initialSnapshot)
    }

    func threadSnapshot(_ snapshot: CodexChatSnapshot) -> CodexThreadSnapshot {
        CodexThreadSnapshot(
            id: chatID,
            workspace: workspaceCWD.map { URL(fileURLWithPath: $0, isDirectory: true) },
            name: title,
            preview: preview,
            modelProvider: model,
            updatedAt: updatedAt,
            recencyAt: recencyAt,
            status: status,
            turns: snapshot.turns.map { turn in
                CodexTurnSnapshot(
                    id: turn.id,
                    status: turn.status,
                    errorMessage: turn.errorDescription,
                    items: snapshot.items
                        .filter { $0.turnID == turn.id }
                        .map(\.threadItem)
                )
            }
        )
    }
}

private extension CodexThreadSnapshot {
    var chatSnapshot: CodexChatSnapshot {
        let turnSnapshots = turns ?? []
        let chatTurns = turnSnapshots.map { turn in
            CodexChatTurnStateSnapshot(
                id: turn.id,
                status: turn.status,
                errorDescription: turn.errorMessage,
                usage: nil
            )
        }
        let chatItems = turnSnapshots.flatMap { turn in
            turn.items.map { item in
                CodexChatItemSnapshot(
                    id: item.id,
                    turnID: turn.id,
                    kind: item.kind,
                    content: item.content,
                    rawPayload: item.rawPayload
                )
            }
        }
        return CodexChatSnapshot(
            chatID: id,
            phase: turnSnapshots.compactMap(\.errorMessage).first.map(CodexDataPhase.failed) ?? .loaded,
            turns: chatTurns,
            items: chatItems
        )
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
