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
    private var projectedBlocksByLocator:
        [CodexChatItemLocator: [ReviewMonitorLogProjectedBlock]] = [:]

    mutating func reset() {
        logProjection.reset()
        snapshot = nil
        cursor = nil
        hasLogDocument = false
        projectedBlocksByLocator.removeAll(keepingCapacity: false)
    }

    mutating func apply(
        _ event: CodexChatObservationEvent
    ) -> ReviewMonitorLogSourceChange? {
        switch event.payload {
        case .snapshot(let snapshot, let reason):
            validateSnapshotCursor(event, reason: reason)
            self.snapshot = snapshot
            replaceProjectionCache(with: snapshot)
            cursor = .init(generation: event.generation, sequence: event.sequence)
            return renderCachedProjection(allowIncrementalUpdate: false)
        case .update(let update):
            validateUpdateCursor(event)
            apply(update)
            cursor = .init(generation: event.generation, sequence: event.sequence)
            return renderCachedProjection(allowIncrementalUpdate: hasLogDocument)
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
            projectWholeTurn(turn, phase: snapshot.phase)
        case .turnUpdated(var turn, let index):
            let previousIndex = requiredTurnIndex(turn.id, in: turns)
            precondition(
                itemsAreSemanticallyEqual(turns[previousIndex].items, turn.items),
                "A turnUpdated event changed semantic item ownership."
            )
            let previous = turns[previousIndex]
            turn.items = turns[previousIndex].items
            turns.remove(at: previousIndex)
            precondition(turns.indices.contains(index) || index == turns.endIndex)
            turns.insert(turn, at: index)
            if previous.status != turn.status {
                reprojectStatusDependentItems(in: turn, phase: snapshot.phase)
            }
        case .turnRemoved(let id):
            let index = requiredUniqueIndex(in: turns) { $0.id == id }
            let removed = turns.remove(at: index)
            for item in removed.items {
                projectedBlocksByLocator.removeValue(
                    forKey: locator(for: item, turnID: removed.id)
                )
            }
        case .itemInserted(let item, let turnID, let index):
            let turnIndex = requiredTurnIndex(turnID, in: turns)
            precondition(turns[turnIndex].items.contains {
                itemMatches($0, id: item.id, kind: item.kind)
            } == false)
            let previous = turns[turnIndex]
            precondition(
                turns[turnIndex].items.indices.contains(index)
                    || index == turns[turnIndex].items.endIndex
            )
            turns[turnIndex].items.insert(item, at: index)
            reconcileItemMutation(
                previous: previous,
                current: turns[turnIndex],
                explicitlyChanged: [locator(for: item, turnID: turnID)],
                removed: [],
                phase: snapshot.phase
            )
        case .itemUpdated(let item, let turnID, let index):
            let turnIndex = requiredTurnIndex(turnID, in: turns)
            let previous = turns[turnIndex]
            let previousIndex = requiredUniqueIndex(in: turns[turnIndex].items) {
                itemMatches($0, id: item.id, kind: item.kind)
            }
            let previousItem = turns[turnIndex].items.remove(at: previousIndex)
            precondition(
                turns[turnIndex].items.indices.contains(index)
                    || index == turns[turnIndex].items.endIndex
            )
            turns[turnIndex].items.insert(item, at: index)
            let previousLocator = locator(for: previousItem, turnID: turnID)
            let currentLocator = locator(for: item, turnID: turnID)
            reconcileItemMutation(
                previous: previous,
                current: turns[turnIndex],
                explicitlyChanged: [currentLocator],
                removed: previousLocator == currentLocator ? [] : [previousLocator],
                phase: snapshot.phase
            )
        case .itemRemoved(let locator):
            let turnIndex = requiredTurnIndex(locator.turnID, in: turns)
            let previous = turns[turnIndex]
            let itemIndex = requiredUniqueIndex(in: turns[turnIndex].items) {
                itemMatches($0, id: locator.id, kind: locator.kind)
            }
            turns[turnIndex].items.remove(at: itemIndex)
            reconcileItemMutation(
                previous: previous,
                current: turns[turnIndex],
                explicitlyChanged: [],
                removed: [locator],
                phase: snapshot.phase
            )
        case .itemTextAppended(let locator, let delta):
            let turnIndex = requiredTurnIndex(locator.turnID, in: turns)
            let previous = turns[turnIndex]
            let itemIndex = requiredUniqueIndex(in: turns[turnIndex].items) {
                itemMatches($0, id: locator.id, kind: locator.kind)
            }
            append(delta, to: &turns[turnIndex].items[itemIndex])
            reconcileItemMutation(
                previous: previous,
                current: turns[turnIndex],
                explicitlyChanged: [locator],
                removed: [],
                phase: snapshot.phase
            )
        case .statusChanged(let status):
            snapshot.thread.status = status
        case .phaseChanged(let phase):
            let affectedTurnIDs = Set([snapshot.phase.turnID, phase.turnID].compactMap { $0 })
            snapshot.phase = phase
            for turnID in affectedTurnIDs {
                let turnIndex = requiredTurnIndex(turnID, in: turns)
                reprojectStatusDependentItems(in: turns[turnIndex], phase: phase)
            }
        }
        snapshot.thread.turns = turns
        self.snapshot = snapshot
    }

    private mutating func replaceProjectionCache(
        with snapshot: CodexChatObservationSnapshot
    ) {
        projectedBlocksByLocator.removeAll(keepingCapacity: true)
        for turn in snapshot.thread.turns ?? [] {
            projectWholeTurn(turn, phase: snapshot.phase)
        }
    }

    private mutating func projectWholeTurn(
        _ turn: CodexTurnSnapshot,
        phase: CodexChatPhase
    ) {
        var seen: Set<CodexChatItemLocator> = []
        let presentation = presentationState(for: turn, phase: phase, reportMissing: true)
        for item in turn.items {
            let locator = locator(for: item, turnID: turn.id)
            precondition(seen.insert(locator).inserted)
            precondition(projectedBlocksByLocator[locator] == nil)
            reproject(item, in: turn, phase: phase, presentation: presentation)
        }
    }

    private mutating func reconcileItemMutation(
        previous: CodexTurnSnapshot,
        current: CodexTurnSnapshot,
        explicitlyChanged: Set<CodexChatItemLocator>,
        removed: Set<CodexChatItemLocator>,
        phase: CodexChatPhase
    ) {
        precondition(previous.id == current.id)
        let previousPresentation = presentationState(
            for: previous,
            phase: phase,
            reportMissing: false
        )
        let currentPresentation = presentationState(
            for: current,
            phase: phase,
            reportMissing: true
        )

        for locator in removed {
            precondition(projectedBlocksByLocator.removeValue(forKey: locator) != nil)
        }

        var locatorsToReproject = explicitlyChanged
        if previousPresentation.hidesUserMessages != currentPresentation.hidesUserMessages {
            for item in current.items where item.isUserMessage {
                locatorsToReproject.insert(locator(for: item, turnID: current.id))
            }
        }

        let changedSuppressionSourceIDs =
            previousPresentation.suppressedRolloutSourceIDs
                .symmetricDifference(currentPresentation.suppressedRolloutSourceIDs)
        if changedSuppressionSourceIDs.isEmpty == false {
            for item in current.items {
                let facts = logProjection.presentationFacts(
                    for: item,
                    turnID: current.id,
                    turnStatus: projectedStatus(for: current, phase: phase)
                )
                if changedSuppressionSourceIDs.contains(facts.sourceID) {
                    locatorsToReproject.insert(locator(for: item, turnID: current.id))
                }
            }
        }

        for locator in locatorsToReproject {
            let itemIndex = requiredUniqueIndex(in: current.items) {
                itemMatches($0, id: locator.id, kind: locator.kind)
            }
            reproject(
                current.items[itemIndex],
                in: current,
                phase: phase,
                presentation: currentPresentation
            )
        }
    }

    private mutating func reprojectStatusDependentItems(
        in turn: CodexTurnSnapshot,
        phase: CodexChatPhase
    ) {
        let presentation = presentationState(for: turn, phase: phase, reportMissing: true)
        for item in turn.items where logProjection.dependsOnTurnStatus(item) {
            reproject(item, in: turn, phase: phase, presentation: presentation)
        }
    }

    private mutating func reproject(
        _ item: CodexThreadItem,
        in turn: CodexTurnSnapshot,
        phase: CodexChatPhase,
        presentation: TurnPresentationState
    ) {
        let status = projectedStatus(for: turn, phase: phase)
        let facts = logProjection.presentationFacts(
            for: item,
            turnID: turn.id,
            turnStatus: status
        )
        projectedBlocksByLocator[locator(for: item, turnID: turn.id)] =
            logProjection.projectedBlocks(
                from: item,
                turnID: turn.id,
                turnStatus: status,
                chatCreatedAt: snapshot?.thread.createdAt,
                chatUpdatedAt: snapshot?.thread.updatedAt,
                suppressUserMessage: presentation.hidesUserMessages,
                suppressRolloutCompanion:
                    presentation.suppressedRolloutSourceIDs.contains(facts.sourceID)
            )
    }

    private mutating func presentationState(
        for turn: CodexTurnSnapshot,
        phase: CodexChatPhase,
        reportMissing: Bool
    ) -> TurnPresentationState {
        let status = projectedStatus(for: turn, phase: phase)
        let facts = turn.items.map {
            logProjection.presentationFacts(for: $0, turnID: turn.id, turnStatus: status)
        }
        let rollout = ReviewRolloutPresentationPolicy().evaluate(facts)
        if reportMissing {
            logProjection.reportMissingRolloutTargets(rollout.missingTargetSourceIDs)
        }
        return .init(
            hidesUserMessages: ReviewTurnPresentationPolicy(items: facts)
                .hidesUserMessage(in: turn.id),
            suppressedRolloutSourceIDs: rollout.suppressedCompanionSourceIDs
        )
    }

    private func projectedStatus(
        for turn: CodexTurnSnapshot,
        phase: CodexChatPhase
    ) -> CodexTurnStatus {
        guard phase.turnID == turn.id else {
            return turn.status
        }
        switch phase {
        case .running:
            return .inProgress
        case .terminal(_, let disposition):
            switch disposition {
            case .completed:
                return .completed
            case .interrupted:
                return .interrupted
            case .failed:
                return .failed
            case .invalid(let rawStatus):
                return .unknown(rawValue: rawStatus)
            }
        case .idle, .loading, .failed:
            return turn.status
        }
    }

    private func locator(
        for item: CodexThreadItem,
        turnID: CodexTurnID
    ) -> CodexChatItemLocator {
        .init(item: item, turnID: turnID)
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
                && lhs.origin == rhs.origin
                && lhs.semanticRelation == rhs.semanticRelation
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

    private mutating func renderCachedProjection(
        allowIncrementalUpdate: Bool
    ) -> ReviewMonitorLogSourceChange? {
        guard let snapshot else {
            preconditionFailure("Projection cache requires an observation snapshot.")
        }
        let projectedBlocks = (snapshot.thread.turns ?? []).flatMap { turn in
            turn.items.flatMap { item -> [ReviewMonitorLogProjectedBlock] in
                let locator = locator(for: item, turnID: turn.id)
                guard let blocks = projectedBlocksByLocator[locator] else {
                    preconditionFailure("Projection cache is missing item \(locator.id).")
                }
                return blocks
            }
        }
        guard let document = logProjection.render(projectedBlocks: projectedBlocks) else {
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

    private struct TurnPresentationState {
        var hidesUserMessages: Bool
        var suppressedRolloutSourceIDs: Set<String>
    }
}

private extension CodexThreadItem {
    var isUserMessage: Bool {
        guard case .message(let message) = content else {
            return false
        }
        return message.role == .user
    }
}
