import CodexAppServerKit
import CodexDataKit
import Foundation

@MainActor
enum ReviewMonitorLogSourceChange: Equatable {
    case replaceAll(ReviewMonitorLog.Document)
    case update(ReviewMonitorLog.Document)
    case clear

    var sourceDocument: ReviewMonitorLog.Document? {
        switch self {
        case .replaceAll(let document),
            .update(let document):
            return document
        case .clear:
            return nil
        }
    }

    var allowsIncrementalRender: Bool {
        switch self {
        case .update:
            return true
        case .replaceAll,
            .clear:
            return false
        }
    }
}

@MainActor
struct ReviewMonitorCodexChatLogSourceProjection {
    private struct Cursor: Equatable {
        var generation: UInt64
        var sequence: UInt64
    }

    private var logProjection = ReviewMonitorCodexChatLogProjection()
    private var snapshot: CodexChatObservationSnapshot?
    private var cursor: Cursor?
    private var hasLogDocument = false

    mutating func reset() {
        logProjection.reset()
        snapshot = nil
        cursor = nil
        hasLogDocument = false
    }

    mutating func apply(
        _ event: CodexChatObservationEvent
    ) -> ReviewMonitorLogSourceChange? {
        switch event.payload {
        case .snapshot(let snapshot, let reason):
            validateSnapshotCursor(event, reason: reason)
            self.snapshot = snapshot
            cursor = .init(generation: event.generation, sequence: event.sequence)
            return renderSnapshot(allowIncrementalUpdate: false)
        case .update(let update):
            validateUpdateCursor(event)
            apply(update)
            cursor = .init(generation: event.generation, sequence: event.sequence)
            return renderSnapshot(allowIncrementalUpdate: hasLogDocument)
        }
    }

    private mutating func validateSnapshotCursor(
        _ event: CodexChatObservationEvent,
        reason: CodexChatSnapshotReason
    ) {
        guard let cursor else {
            return
        }
        if event.generation > cursor.generation {
            precondition(event.sequence == 0)
            precondition(reason == .generationRestart)
            return
        }
        precondition(event.generation == cursor.generation)
        precondition(event.sequence >= cursor.sequence)
    }

    private func validateUpdateCursor(_ event: CodexChatObservationEvent) {
        guard let cursor else {
            preconditionFailure("A chat observation update requires an initial snapshot.")
        }
        precondition(event.generation == cursor.generation)
        precondition(event.sequence == cursor.sequence &+ 1)
    }

    private mutating func apply(_ update: CodexChatUpdate) {
        guard var snapshot else {
            preconditionFailure("A chat observation update requires projection state.")
        }
        var turns = snapshot.thread.turns ?? []
        switch update {
        case .turnInserted(let turn, let index):
            precondition(turns.contains { $0.id == turn.id } == false)
            precondition(turns.indices.contains(index) || index == turns.endIndex)
            turns.insert(turn, at: index)
        case .turnUpdated(var turn, let index):
            let previousIndex = requiredTurnIndex(turn.id, in: turns)
            precondition(
                itemsAreSemanticallyEqual(turns[previousIndex].items, turn.items),
                "A turnUpdated event changed semantic item ownership."
            )
            turn.items = turns[previousIndex].items
            turns.remove(at: previousIndex)
            precondition(turns.indices.contains(index) || index == turns.endIndex)
            turns.insert(turn, at: index)
        case .turnRemoved(let id):
            let index = requiredUniqueIndex(in: turns) { $0.id == id }
            turns.remove(at: index)
        case .itemInserted(let item, let turnID, let index):
            let turnIndex = requiredTurnIndex(turnID, in: turns)
            precondition(turns[turnIndex].items.contains {
                itemMatches($0, id: item.id, kind: item.kind)
            } == false)
            precondition(
                turns[turnIndex].items.indices.contains(index)
                    || index == turns[turnIndex].items.endIndex
            )
            turns[turnIndex].items.insert(item, at: index)
        case .itemUpdated(let item, let turnID, let index):
            let turnIndex = requiredTurnIndex(turnID, in: turns)
            let previousIndex = requiredUniqueIndex(in: turns[turnIndex].items) {
                itemMatches($0, id: item.id, kind: item.kind)
            }
            turns[turnIndex].items.remove(at: previousIndex)
            precondition(
                turns[turnIndex].items.indices.contains(index)
                    || index == turns[turnIndex].items.endIndex
            )
            turns[turnIndex].items.insert(item, at: index)
        case .itemRemoved(let locator):
            let turnIndex = requiredTurnIndex(locator.turnID, in: turns)
            let itemIndex = requiredUniqueIndex(in: turns[turnIndex].items) {
                itemMatches($0, id: locator.id, kind: locator.kind)
            }
            turns[turnIndex].items.remove(at: itemIndex)
        case .itemTextAppended(let locator, let delta):
            let turnIndex = requiredTurnIndex(locator.turnID, in: turns)
            let itemIndex = requiredUniqueIndex(in: turns[turnIndex].items) {
                itemMatches($0, id: locator.id, kind: locator.kind)
            }
            append(delta, to: &turns[turnIndex].items[itemIndex])
        case .statusChanged(let status):
            snapshot.thread.status = status
        case .phaseChanged(let phase):
            snapshot.phase = phase
        }
        snapshot.thread.turns = turns
        self.snapshot = snapshot
    }

    private func requiredTurnIndex(
        _ id: CodexTurnID,
        in turns: [CodexTurnSnapshot]
    ) -> Int {
        requiredUniqueIndex(in: turns) { $0.id == id }
    }

    private func requiredUniqueIndex<Value>(
        in values: [Value],
        where predicate: (Value) -> Bool
    ) -> Int {
        let indices = values.indices.filter { predicate(values[$0]) }
        precondition(indices.count == 1)
        return indices[0]
    }

    private func itemMatches(
        _ item: CodexThreadItem,
        id: String,
        kind: CodexThreadItem.Kind
    ) -> Bool {
        item.id == id && item.kind == kind
    }

    private func itemsAreSemanticallyEqual(
        _ lhs: [CodexThreadItem],
        _ rhs: [CodexThreadItem]
    ) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        return zip(lhs, rhs).allSatisfy { lhs, rhs in
            lhs.id == rhs.id
                && lhs.kind == rhs.kind
                && contentsAreSemanticallyEqual(lhs.content, rhs.content)
        }
    }

    private func contentsAreSemanticallyEqual(
        _ lhs: CodexThreadItem.Content,
        _ rhs: CodexThreadItem.Content
    ) -> Bool {
        if case .reasoning(let lhsReasoning) = lhs,
           case .reasoning(let rhsReasoning) = rhs {
            return lhsReasoning.text == rhsReasoning.text
        }
        return lhs == rhs
    }

    private func append(_ delta: String, to item: inout CodexThreadItem) {
        switch item.content {
        case .message(var message):
            message.text += delta
            item.content = .message(message)
        case .plan(let text):
            item.content = .plan(text + delta)
        case .reasoning(var reasoning):
            if reasoning.summary.isEmpty {
                append(delta, to: &reasoning.content)
            } else {
                append(delta, to: &reasoning.summary)
            }
            item.content = .reasoning(reasoning)
        case .command(var command):
            command.output = (command.output ?? "") + delta
            item.content = .command(command)
        case .fileChange(var fileChange):
            fileChange.output = (fileChange.output ?? "") + delta
            item.content = .fileChange(fileChange)
        case .toolCall(var toolCall):
            toolCall.result = (toolCall.result ?? "") + delta
            item.content = .toolCall(toolCall)
        case .contextCompaction(let text):
            item.content = .contextCompaction((text ?? "") + delta)
        case .diagnostic(let text):
            item.content = .diagnostic(text + delta)
        case .log(let text):
            item.content = .log(text + delta)
        case .unknown(var raw):
            raw.text = (raw.text ?? "") + delta
            item.content = .unknown(raw)
        }
    }

    private func append(_ delta: String, to fragments: inout [String]) {
        if fragments.isEmpty {
            fragments = [delta]
        } else {
            fragments[fragments.index(before: fragments.endIndex)] += delta
        }
    }

    private mutating func renderSnapshot(
        allowIncrementalUpdate: Bool
    ) -> ReviewMonitorLogSourceChange? {
        guard let snapshot,
              let document = logProjection.render(
                  from: snapshot.thread,
                  chatCreatedAt: snapshot.thread.createdAt,
                  chatUpdatedAt: snapshot.thread.updatedAt
              )
        else {
            if allowIncrementalUpdate {
                return clearIfNeeded()
            }
            logProjection.reset()
            hasLogDocument = false
            return .clear
        }
        defer {
            hasLogDocument = true
        }
        return allowIncrementalUpdate ? .update(document) : .replaceAll(document)
    }

    private mutating func clearIfNeeded() -> ReviewMonitorLogSourceChange? {
        guard hasLogDocument else {
            return nil
        }
        logProjection.reset()
        hasLogDocument = false
        return .clear
    }
}
