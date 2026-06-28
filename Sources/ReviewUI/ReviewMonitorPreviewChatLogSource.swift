import CodexKit
import CodexReviewKit
import Foundation
import Observation
import ObservationBridge

@MainActor
struct ReviewMonitorPreviewChatLogFixture {
    let chat: ReviewMonitorCodexSidebarSnapshot.Chat
    let cwd: String
    let streamID: String
    let isRunning: Bool
    let initialSnapshot: CodexChatSnapshot

    init(
        chat: ReviewMonitorCodexSidebarSnapshot.Chat,
        cwd: String,
        streamID: String,
        isRunning: Bool,
        initialSnapshot: CodexChatSnapshot
    ) {
        self.chat = chat
        self.cwd = cwd
        self.streamID = streamID
        self.isRunning = isRunning
        self.initialSnapshot = initialSnapshot
    }
}

@MainActor
final class ReviewMonitorPreviewChatLogSource {
    let snapshot: ReviewMonitorCodexSidebarSnapshot
    let initialChat: ReviewMonitorCodexSidebarSnapshot.Chat?

    private let previewChats: [PreviewReviewChat]
    private let previewChatsByID: [CodexThreadID: PreviewReviewChat]

    init(fixtures: [ReviewMonitorPreviewChatLogFixture]) {
        var sections: [ReviewMonitorCodexSidebarSnapshot.Section] = []
        var sectionIndexesByCWD: [String: Int] = [:]
        var previewChats: [PreviewReviewChat] = []
        var previewChatsByID: [CodexThreadID: PreviewReviewChat] = [:]
        var initialRunningChat: ReviewMonitorCodexSidebarSnapshot.Chat?
        var firstChat: ReviewMonitorCodexSidebarSnapshot.Chat?

        for fixture in fixtures {
            let previewChat = PreviewReviewChat(fixture: fixture)
            let chat = previewChat.chat
            previewChats.append(previewChat)
            previewChatsByID[chat.id] = previewChat
            firstChat = firstChat ?? chat
            if initialRunningChat == nil, previewChat.isRunning {
                initialRunningChat = chat
            }

            if let sectionIndex = sectionIndexesByCWD[previewChat.cwd] {
                sections[sectionIndex].uncategorizedChats.append(chat)
            } else {
                sectionIndexesByCWD[previewChat.cwd] = sections.count
                sections.append(
                    ReviewMonitorCodexSidebarSnapshot.Section(
                        rowID: .section(previewChat.cwd),
                        id: previewChat.cwd,
                        title: URL(fileURLWithPath: previewChat.cwd).lastPathComponent,
                        workspaces: [],
                        uncategorizedChats: [chat]
                    ))
            }
        }

        self.snapshot = ReviewMonitorCodexSidebarSnapshot(sections: sections)
        self.initialChat = initialRunningChat ?? firstChat
        self.previewChats = previewChats
        self.previewChatsByID = previewChatsByID
    }

    func chatChangeStream(for chatID: CodexThreadID) -> AsyncStream<CodexChatChange>? {
        guard let previewChat = previewChatsByID[chatID] else {
            return nil
        }
        let pair = AsyncStream<CodexChatChange>.makeStream(bufferingPolicy: .unbounded)
        let subscription = PreviewChatLogSubscription(previewChat: previewChat, continuation: pair.continuation)
        subscription.start()
        pair.continuation.onTermination = { _ in
            Task { @MainActor in
                subscription.cancel()
            }
        }
        return pair.stream
    }

    func upsertPreviewItem(
        id: String,
        kind: CodexThreadItem.Kind,
        content: CodexThreadItem.Content,
        to chatID: CodexThreadID
    ) {
        previewChatsByID[chatID]?.upsertItem(id: id, kind: kind, content: content)
    }

    func appendPreviewText(
        _ delta: String,
        to chatID: CodexThreadID,
        itemID: String,
        kind: CodexThreadItem.Kind,
        content: CodexThreadItem.Content
    ) {
        previewChatsByID[chatID]?.appendTextDelta(delta, itemID: itemID, kind: kind, content: content)
    }

    func snapshotForTesting(chatID: CodexThreadID) -> CodexChatSnapshot? {
        previewChatsByID[chatID]?.snapshot()
    }

    @discardableResult
    func appendPreviewStreamTick(after currentTick: Int = 0) -> Int {
        let runningChats = previewChats.filter(\.isRunning)
        guard runningChats.isEmpty == false else {
            return currentTick
        }

        let nextTick = currentTick + 1
        for (index, previewChat) in runningChats.enumerated() {
            guard let frame = ReviewMonitorPreviewContent.streamFrame(
                forJobAt: index,
                tick: nextTick
            ) else {
                continue
            }
            previewChat.applyPreviewStreamStep(frame.step, cycle: frame.cycle)
        }
        return nextTick
    }
}

@MainActor
@Observable
private final class PreviewReviewChat {
    let chat: ReviewMonitorCodexSidebarSnapshot.Chat
    let cwd: String
    let streamID: String
    let isRunning: Bool

    private var revision = 0
    private var snapshotStorage: CodexChatSnapshot

    init(fixture: ReviewMonitorPreviewChatLogFixture) {
        self.chat = fixture.chat
        self.cwd = fixture.cwd
        self.streamID = fixture.streamID
        self.isRunning = fixture.isRunning
        self.snapshotStorage = fixture.initialSnapshot
    }

    func trackRevision() {
        _ = revision
    }

    func snapshot() -> CodexChatSnapshot {
        snapshotStorage
    }

    func applyPreviewStreamStep(
        _ step: ReviewMonitorPreviewContent.PreviewTimelineStep,
        cycle: Int
    ) {
        let itemID = ReviewMonitorPreviewContent.previewTimelineItemID(
            itemName: step.itemName,
            jobID: streamID,
            cycle: cycle
        )
        switch step.mode {
        case .update:
            upsertItem(step.seed(id: itemID))
        case .complete:
            upsertItem(step.seed(id: itemID))
        case .textDelta:
            appendTextDelta(
                step.deltaText ?? "",
                itemID: itemID.rawValue,
                kind: CodexThreadItem.Kind(step.kind),
                content: CodexThreadItem.Content(
                    previewContent: step.content,
                    id: itemID.rawValue,
                    phase: step.phase,
                    fallbackRawKind: step.kind.rawValue
                )
            )
        }
    }

    private var currentTurnID: CodexTurnID? {
        snapshotStorage.turns.last?.id
    }

    private func upsertItem(_ seed: ReviewTimelineItemSeed) {
        let item = CodexChatItemSnapshot(previewSeed: seed, turnID: currentTurnID)
        upsertItem(item)
    }

    func upsertItem(
        id: String,
        kind: CodexThreadItem.Kind,
        content: CodexThreadItem.Content
    ) {
        let item = CodexChatItemSnapshot(
            id: id,
            turnID: currentTurnID,
            kind: kind,
            content: content
        )
        upsertItem(item)
    }

    private func upsertItem(_ item: CodexChatItemSnapshot) {
        if let index = snapshotStorage.items.firstIndex(where: { $0.id == item.id && $0.turnID == item.turnID }) {
            snapshotStorage.items[index] = item
        } else {
            snapshotStorage.items.append(item)
        }
        bumpRevision()
    }

    func appendTextDelta(
        _ delta: String,
        itemID: String,
        kind: CodexThreadItem.Kind,
        content: CodexThreadItem.Content
    ) {
        guard delta.isEmpty == false else {
            return
        }
        let turnID = currentTurnID
        if let index = snapshotStorage.items.firstIndex(where: { $0.id == itemID && $0.turnID == turnID }) {
            snapshotStorage.items[index].content.appendPreviewText(delta)
        } else {
            var item = CodexChatItemSnapshot(
                id: itemID,
                turnID: turnID,
                kind: kind,
                content: content
            )
            item.content.appendPreviewText(delta)
            snapshotStorage.items.append(item)
        }
        bumpRevision()
    }

    private func updateTurnStatus(_ status: CodexTurnStatus) {
        guard snapshotStorage.turns.isEmpty == false else {
            return
        }
        snapshotStorage.turns[snapshotStorage.turns.count - 1].status = status
        snapshotStorage.phase = .loaded
        bumpRevision()
    }

    private func bumpRevision() {
        revision += 1
    }
}

@MainActor
final class ReviewMonitorPreviewChatLogStreamer {
    private weak var source: ReviewMonitorPreviewChatLogSource?
    private let interval: Duration
    private var task: Task<Void, Never>?
    private var tick = 0

    init(source: ReviewMonitorPreviewChatLogSource, interval: Duration) {
        self.source = source
        self.interval = interval
        task = Task { [weak self, interval] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: interval)
                guard let self, Task.isCancelled == false else {
                    return
                }
                self.emitTick()
            }
        }
    }

    deinit {
        task?.cancel()
    }

    private func emitTick() {
        guard let source else {
            task?.cancel()
            return
        }
        tick = source.appendPreviewStreamTick(after: tick)
    }
}

@MainActor
private final class PreviewChatLogSubscription {
    private let previewChat: PreviewReviewChat
    private let continuation: AsyncStream<CodexChatChange>.Continuation
    private var observation: PortableObservationTracking.Token?
    private var previousSnapshot: CodexChatSnapshot?

    init(
        previewChat: PreviewReviewChat,
        continuation: AsyncStream<CodexChatChange>.Continuation
    ) {
        self.previewChat = previewChat
        self.continuation = continuation
    }

    func start() {
        publish()
        observation = withPortableContinuousObservation { [weak self] _ in
            guard let self else {
                return
            }
            previewChat.trackRevision()
            publish()
        }
    }

    func cancel() {
        observation?.cancel()
        observation = nil
    }

    private func publish() {
        let snapshot = previewChat.snapshot()
        let changes = CodexChatChange.previewChanges(from: previousSnapshot, to: snapshot)
        previousSnapshot = snapshot
        for change in changes {
            continuation.yield(change)
        }
    }
}

private extension CodexChatChange {
    static func previewChanges(from previous: CodexChatSnapshot?, to current: CodexChatSnapshot) -> [Self] {
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
            if let delta = previousItem.textDelta(to: item) {
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

extension CodexChatItemSnapshot {
    @MainActor
    init(previewItem item: ReviewTimelineItem, turnID: CodexTurnID) {
        self.init(
            id: item.id.rawValue,
            turnID: turnID,
            kind: CodexThreadItem.Kind(item.kind),
            content: CodexThreadItem.Content(previewItem: item),
            rawPayload: nil
        )
    }

    func textDelta(to item: CodexChatItemSnapshot) -> String? {
        guard
            turnID == item.turnID,
            kind == item.kind,
            sameContentShape(as: item),
            let previousText = text,
            let nextText = item.text,
            nextText.hasPrefix(previousText),
            nextText.count > previousText.count
        else {
            return nil
        }
        return String(nextText.dropFirst(previousText.count))
    }

    private func sameContentShape(as item: CodexChatItemSnapshot) -> Bool {
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

private extension CodexThreadItem.Kind {
    init(_ kind: ReviewItemKind) {
        self.init(rawValue: kind.rawValue)
    }
}

private extension CodexThreadItem.Content {
    @MainActor
    init(previewItem item: ReviewTimelineItem) {
        self.init(
            previewContent: item.content,
            id: item.id.rawValue,
            phase: item.phase,
            fallbackRawKind: item.kind.rawValue
        )
    }

    init(
        previewContent content: ReviewTimelineItem.Content,
        id: String,
        phase: ReviewItemPhase,
        fallbackRawKind: String
    ) {
        switch content {
        case .approval(let approval):
            self = .diagnostic(
                [
                    approval.title.nilIfEmpty,
                    approval.detail?.nilIfEmpty,
                ]
                .compactMap { $0 }
                .joined(separator: "\n")
            )
        case .command(let command):
            self = .command(
                .init(
                    command: command.command,
                    cwd: command.cwd,
                    output: command.output.nilIfEmpty,
                    exitCode: command.exitCode,
                    status: command.status.map(CodexTurnStatus.init) ?? CodexTurnStatus(phase)
                ))
        case .contextCompaction(let compaction):
            self = .contextCompaction(compaction.title)
        case .diagnostic(let diagnostic):
            self = .diagnostic(diagnostic.message)
        case .fileChange(let fileChange):
            self = .fileChange(
                .init(
                    path: fileChange.paths.first ?? fileChange.title.nilIfEmpty,
                    output: fileChange.output.nilIfEmpty ?? fileChange.patch?.nilIfEmpty,
                    status: fileChange.status.map(CodexTurnStatus.init) ?? CodexTurnStatus(phase)
                ))
        case .message(let message):
            self = .message(.init(id: id, role: .assistant, text: message.text))
        case .plan(let plan):
            self = .plan(plan.markdown)
        case .reasoning(let reasoning):
            switch reasoning.style {
            case .raw:
                self = .reasoning(.init(content: reasoning.text))
            case .summary:
                self = .reasoning(.init(summary: reasoning.text))
            }
        case .search(let search):
            self = .toolCall(
                .init(
                    name: "web_search",
                    arguments: search.query,
                    result: search.result,
                    status: search.status.map(CodexTurnStatus.init) ?? CodexTurnStatus(phase)
                ))
        case .toolCall(let toolCall):
            self = .toolCall(
                .init(
                    namespace: toolCall.namespace,
                    server: toolCall.server,
                    name: toolCall.tool,
                    arguments: toolCall.arguments,
                    result: toolCall.result,
                    error: toolCall.error,
                    status: toolCall.status.map(CodexTurnStatus.init) ?? CodexTurnStatus(phase)
                ))
        case .unknown(let unknown):
            let text = [
                unknown.title.nilIfEmpty,
                unknown.detail?.nilIfEmpty,
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
            .nilIfEmpty
            self = .unknown(
                .init(
                    rawType: unknown.rawKind?.rawValue ?? fallbackRawKind,
                    text: text
                ))
        }
    }

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

private extension CodexChatItemSnapshot {
    init(previewSeed seed: ReviewTimelineItemSeed, turnID: CodexTurnID?) {
        self.init(
            id: seed.id.rawValue,
            turnID: turnID,
            kind: CodexThreadItem.Kind(seed.kind),
            content: CodexThreadItem.Content(
                previewContent: seed.content,
                id: seed.id.rawValue,
                phase: seed.phase,
                fallbackRawKind: seed.kind.rawValue
            ),
            rawPayload: nil
        )
    }
}

private extension CodexTurnStatus {
    init(_ phase: ReviewItemPhase) {
        switch phase {
        case .awaitingApproval, .queued, .running, .waitingForInput:
            self = .running
        case .cancelled:
            self = .cancelled
        case .completed, .skipped:
            self = .completed
        case .failed, .incomplete:
            self = .failed
        }
    }

    init(_ status: some ReviewOpenStringValue) {
        self.init(rawValue: status.rawValue)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
