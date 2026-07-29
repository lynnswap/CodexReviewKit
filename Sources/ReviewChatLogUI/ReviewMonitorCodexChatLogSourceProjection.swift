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
    private var cachedPresentationState: ThreadPresentationState?
    private var projectedBlocksByLocator:
        [CodexChatItemLocator: [ReviewMonitorLogProjectedBlock]] = [:]

    mutating func reset() {
        logProjection.reset()
        snapshot = nil
        cursor = nil
        hasLogDocument = false
        cachedPresentationState = nil
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
        let previousSnapshot = snapshot
        var turns = snapshot.thread.turns ?? []
        var explicitlyChanged: Set<CodexChatItemLocator> = []
        var removed: Set<CodexChatItemLocator> = []
        var statusDependent: Set<CodexChatItemLocator> = []
        var presentationChanged = false
        switch update {
        case .turnInserted(let turn, let index):
            precondition(turns.contains { $0.id == turn.id } == false)
            precondition(turns.indices.contains(index) || index == turns.endIndex)
            turns.insert(turn, at: index)
            presentationChanged = cachedPresentationState?.hasExitedReviewMarker == true
                || turn.items.contains(where: itemAffectsPresentation)
            explicitlyChanged.formUnion(turn.items.map {
                locator(for: $0, turnID: turn.id)
            })
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
            presentationChanged = previousIndex != index
                && turn.items.contains(where: itemAffectsPresentation)
            if previous.status != turn.status {
                statusDependent.formUnion(turn.items.compactMap { item in
                    logProjection.dependsOnTurnStatus(item)
                        ? locator(for: item, turnID: turn.id)
                        : nil
                })
            }
        case .turnRemoved(let id):
            let index = requiredUniqueIndex(in: turns) { $0.id == id }
            let removedTurn = turns.remove(at: index)
            presentationChanged = cachedPresentationState?.hasExitedReviewMarker == true
                || removedTurn.items.contains(where: itemAffectsPresentation)
            for item in removedTurn.items {
                removed.insert(locator(for: item, turnID: removedTurn.id))
            }
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
            presentationChanged = itemAffectsPresentation(item)
            explicitlyChanged.insert(locator(for: item, turnID: turnID))
        case .itemUpdated(let item, let turnID, let index):
            let turnIndex = requiredTurnIndex(turnID, in: turns)
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
            presentationChanged =
                itemAffectsPresentation(previousItem) || itemAffectsPresentation(item)
            explicitlyChanged.insert(currentLocator)
            if previousLocator != currentLocator {
                removed.insert(previousLocator)
            }
        case .itemRemoved(let locator):
            let turnIndex = requiredTurnIndex(locator.turnID, in: turns)
            let itemIndex = requiredUniqueIndex(in: turns[turnIndex].items) {
                itemMatches($0, id: locator.id, kind: locator.kind)
            }
            let removedItem = turns[turnIndex].items.remove(at: itemIndex)
            presentationChanged = itemAffectsPresentation(removedItem)
            removed.insert(locator)
        case .itemTextAppended(let locator, let delta):
            let turnIndex = requiredTurnIndex(locator.turnID, in: turns)
            let itemIndex = requiredUniqueIndex(in: turns[turnIndex].items) {
                itemMatches($0, id: locator.id, kind: locator.kind)
            }
            presentationChanged = itemAffectsPresentation(turns[turnIndex].items[itemIndex])
            append(delta, to: &turns[turnIndex].items[itemIndex])
            explicitlyChanged.insert(locator)
        case .statusChanged(let status):
            snapshot.thread.status = status
        case .phaseChanged(let phase):
            let affectedTurnIDs = Set([snapshot.phase.turnID, phase.turnID].compactMap { $0 })
            snapshot.phase = phase
            for turnID in affectedTurnIDs {
                let turnIndex = requiredTurnIndex(turnID, in: turns)
                statusDependent.formUnion(turns[turnIndex].items.compactMap { item in
                    logProjection.dependsOnTurnStatus(item)
                        ? locator(for: item, turnID: turnID)
                        : nil
                })
            }
        }
        snapshot.thread.turns = turns
        self.snapshot = snapshot
        reconcileProjection(
            previous: previousSnapshot,
            current: snapshot,
            explicitlyChanged: explicitlyChanged.union(statusDependent),
            removed: removed,
            presentationChanged: presentationChanged
        )
    }

    private mutating func replaceProjectionCache(
        with snapshot: CodexChatObservationSnapshot
    ) {
        projectedBlocksByLocator.removeAll(keepingCapacity: true)
        let presentation = presentationState(for: snapshot, reportMissing: true)
        cachedPresentationState = presentation
        for turn in snapshot.thread.turns ?? [] {
            projectWholeTurn(
                turn,
                phase: snapshot.phase,
                presentation: presentation
            )
        }
    }

    private mutating func projectWholeTurn(
        _ turn: CodexTurnSnapshot,
        phase: CodexChatPhase,
        presentation: ThreadPresentationState
    ) {
        var seen: Set<CodexChatItemLocator> = []
        for item in turn.items {
            let locator = locator(for: item, turnID: turn.id)
            precondition(seen.insert(locator).inserted)
            precondition(projectedBlocksByLocator[locator] == nil)
            reproject(item, in: turn, phase: phase, presentation: presentation)
        }
    }

    private mutating func reconcileProjection(
        previous: CodexChatObservationSnapshot,
        current: CodexChatObservationSnapshot,
        explicitlyChanged: Set<CodexChatItemLocator>,
        removed: Set<CodexChatItemLocator>,
        presentationChanged: Bool
    ) {
        precondition(previous.thread.id == current.thread.id)
        guard let previousPresentation = cachedPresentationState else {
            preconditionFailure("Projection cache requires presentation state.")
        }
        let currentPresentation: ThreadPresentationState
        if presentationChanged {
            currentPresentation = presentationState(for: current, reportMissing: true)
            cachedPresentationState = currentPresentation
        } else {
            currentPresentation = previousPresentation
        }

        for locator in removed {
            precondition(projectedBlocksByLocator.removeValue(forKey: locator) != nil)
        }

        var locatorsToReproject = explicitlyChanged
        if presentationChanged {
            for turn in current.thread.turns ?? [] {
                let userMessageVisibilityChanged =
                    previousPresentation.hidesUserMessage(in: turn.id)
                        != currentPresentation.hidesUserMessage(in: turn.id)
                for item in turn.items {
                    let locator = locator(for: item, turnID: turn.id)
                    if userMessageVisibilityChanged && item.isUserMessage {
                        locatorsToReproject.insert(locator)
                    }
                    let facts = logProjection.presentationFacts(
                        for: item,
                        turnID: turn.id,
                        turnStatus: projectedStatus(for: turn, phase: current.phase)
                    )
                    let wasSuppressed = previousPresentation.suppressedRolloutSourceIDs
                        .contains(facts.sourceID)
                    let isSuppressed = currentPresentation.suppressedRolloutSourceIDs
                        .contains(facts.sourceID)
                    if wasSuppressed != isSuppressed {
                        locatorsToReproject.insert(locator)
                    }
                }
            }
        }

        for locator in locatorsToReproject {
            let turns = current.thread.turns ?? []
            let turnIndex = requiredTurnIndex(locator.turnID, in: turns)
            let turn = turns[turnIndex]
            let itemIndex = requiredUniqueIndex(in: turn.items) {
                itemMatches($0, id: locator.id, kind: locator.kind)
            }
            reproject(
                turn.items[itemIndex],
                in: turn,
                phase: current.phase,
                presentation: currentPresentation
            )
        }
    }

    private mutating func reproject(
        _ item: CodexThreadItem,
        in turn: CodexTurnSnapshot,
        phase: CodexChatPhase,
        presentation: ThreadPresentationState
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
                suppressUserMessage: presentation.hidesUserMessage(in: turn.id),
                suppressRolloutCompanion:
                    presentation.suppressedRolloutSourceIDs.contains(facts.sourceID)
            )
    }

    private mutating func presentationState(
        for snapshot: CodexChatObservationSnapshot,
        reportMissing: Bool
    ) -> ThreadPresentationState {
        let facts = (snapshot.thread.turns ?? []).flatMap { turn in
            let status = projectedStatus(for: turn, phase: snapshot.phase)
            return turn.items.map {
                logProjection.presentationFacts(
                    for: $0,
                    turnID: turn.id,
                    turnStatus: status
                )
            }
        }
        let rollout = ReviewRolloutPresentationPolicy().evaluate(facts)
        if reportMissing {
            logProjection.reportMissingRolloutTargets(rollout.missingTargetSourceIDs)
        }
        return .init(
            userMessagePolicy: ReviewTurnPresentationPolicy(
                items: facts,
                additionalHiddenTurnIDs: rollout.hiddenUserMessageTurnIDs
            ),
            suppressedRolloutSourceIDs: rollout.suppressedCompanionSourceIDs,
            hasExitedReviewMarker: facts.contains { $0.kind == .exitedReviewMode }
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

    private func itemAffectsPresentation(_ item: CodexThreadItem) -> Bool {
        if item.kind == .enteredReviewMode
            || item.kind == .exitedReviewMode
            || item.origin == .reviewRolloutAssistant
        {
            return true
        }
        guard cachedPresentationState?.hasExitedReviewMarker == true else {
            return false
        }
        return item.kind == .userMessage || item.kind == .agentMessage
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

    private struct ThreadPresentationState {
        var userMessagePolicy: ReviewTurnPresentationPolicy
        var suppressedRolloutSourceIDs: Set<String>
        var hasExitedReviewMarker: Bool

        func hidesUserMessage(in turnID: CodexTurnID) -> Bool {
            userMessagePolicy.hidesUserMessage(in: turnID)
        }
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
