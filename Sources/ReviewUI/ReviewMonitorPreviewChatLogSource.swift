import CodexKit
import CodexReviewKit
import Foundation
import ObservationBridge

@MainActor
struct ReviewMonitorPreviewChatLogFixture {
    let chat: ReviewMonitorCodexSidebarSnapshot.Chat
    let cwd: String
    let isRunning: Bool
    let turn: CodexChatTurnStateSnapshot
    let phase: CodexDataPhase
    let timeline: ReviewTimeline
}

@MainActor
final class ReviewMonitorPreviewChatLogSource {
    let snapshot: ReviewMonitorCodexSidebarSnapshot
    let initialChat: ReviewMonitorCodexSidebarSnapshot.Chat?

    private let previewChatsByID: [CodexThreadID: PreviewReviewChat]

    init(fixtures: [ReviewMonitorPreviewChatLogFixture]) {
        var sections: [ReviewMonitorCodexSidebarSnapshot.Section] = []
        var sectionIndexesByCWD: [String: Int] = [:]
        var previewChatsByID: [CodexThreadID: PreviewReviewChat] = [:]
        var initialRunningChat: ReviewMonitorCodexSidebarSnapshot.Chat?
        var firstChat: ReviewMonitorCodexSidebarSnapshot.Chat?

        for fixture in fixtures {
            let previewChat = PreviewReviewChat(fixture: fixture)
            let chat = previewChat.chat
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
}

@MainActor
private final class PreviewReviewChat {
    let chat: ReviewMonitorCodexSidebarSnapshot.Chat
    let cwd: String
    let isRunning: Bool

    private let turn: CodexChatTurnStateSnapshot
    private let phase: CodexDataPhase
    private let timeline: ReviewTimeline

    init(fixture: ReviewMonitorPreviewChatLogFixture) {
        self.chat = fixture.chat
        self.cwd = fixture.cwd
        self.isRunning = fixture.isRunning
        self.turn = fixture.turn
        self.phase = fixture.phase
        self.timeline = fixture.timeline
    }

    func trackTimelineRevision() {
        _ = timeline.revision
    }

    func snapshot() -> CodexChatSnapshot {
        CodexChatSnapshot(
            chatID: chat.id,
            phase: phase,
            turns: [turn],
            items: timeline.items.map { CodexChatItemSnapshot(previewItem: $0, turnID: turn.id) }
        )
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
            previewChat.trackTimelineRevision()
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

private extension CodexChatItemSnapshot {
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
        switch item.content {
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
                    status: command.status.map(CodexTurnStatus.init) ?? CodexTurnStatus(item.phase)
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
                    status: fileChange.status.map(CodexTurnStatus.init) ?? CodexTurnStatus(item.phase)
                ))
        case .message(let message):
            self = .message(.init(id: item.id.rawValue, role: .assistant, text: message.text))
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
                    status: search.status.map(CodexTurnStatus.init) ?? CodexTurnStatus(item.phase)
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
                    status: toolCall.status.map(CodexTurnStatus.init) ?? CodexTurnStatus(item.phase)
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
                    rawType: unknown.rawKind?.rawValue ?? item.kind.rawValue,
                    text: text
                ))
        }
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
