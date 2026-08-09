import Foundation

package struct CodexItemReducer {
    package enum Mutation: Equatable, Sendable {
        case started(CodexThreadItem)
        case completed(CodexThreadItem)
        case agentMessageDelta(itemID: String, delta: String)
        case planDelta(itemID: String, delta: String)
        case reasoningSummaryPartAdded(itemID: String, index: Int)
        case reasoningSummaryDelta(itemID: String, index: Int, delta: String)
        case reasoningTextDelta(itemID: String, index: Int, delta: String)
        case commandOutputDelta(itemID: String, delta: String)
        case filePatchSnapshot(itemID: String, output: String?)
        case mcpProgress(itemID: String, message: String)
        case turnDiagnostic(CodexTurnDiagnostic)
    }

    package enum ContractError: Error, Equatable, Sendable, LocalizedError {
        case missingItemID
        case missingBaseItem(turnID: CodexTurnID, itemID: String)
        case unexpectedItemKind(
            turnID: CodexTurnID,
            itemID: String,
            expected: CodexThreadItem.Kind,
            actual: CodexThreadItem.Kind
        )
        case completedItemKindChanged(
            turnID: CodexTurnID,
            itemID: String,
            started: CodexThreadItem.Kind,
            completed: CodexThreadItem.Kind
        )
        case invalidReasoningIndex(itemID: String, index: Int)

        package var errorDescription: String? {
            switch self {
            case .missingItemID:
                "Current-v2 item notification is missing its required item ID."
            case .missingBaseItem(let turnID, let itemID):
                "Item delta for \(itemID) has no base item in turn \(turnID.rawValue)."
            case .unexpectedItemKind(let turnID, let itemID, let expected, let actual):
                "Item delta for \(itemID) in turn \(turnID.rawValue) expected \(expected.rawValue), got \(actual.rawValue)."
            case .completedItemKindChanged(let turnID, let itemID, let started, let completed):
                "Completed item \(itemID) in turn \(turnID.rawValue) changed kind from \(started.rawValue) to \(completed.rawValue)."
            case .invalidReasoningIndex(let itemID, let index):
                "Reasoning item \(itemID) used invalid part index \(index)."
            }
        }
    }

    private struct ItemKey: Hashable {
        var turnID: CodexTurnID
        var itemID: String
    }

    private struct ItemState {
        var item: CodexThreadItem
        var reasoningSummary: [String]?
        var reasoningContent: [String]?

        init(item: CodexThreadItem) {
            self.item = item
            if case .reasoning(let reasoning) = item.content {
                reasoningSummary = reasoning.summary
                reasoningContent = reasoning.content
            }
        }

        mutating func replace(with item: CodexThreadItem) {
            self = .init(item: item)
        }

        mutating func updateReasoningProjection() {
            item.content = .reasoning(.init(
                summary: reasoningSummary ?? [],
                content: reasoningContent ?? []
            ))
        }
    }

    private var stateByItemKey: [ItemKey: ItemState] = [:]

    package init() {}

    package mutating func reduce(
        _ mutation: Mutation,
        turnID: CodexTurnID
    ) throws -> CodexTurnEvent {
        if case .turnDiagnostic(let diagnostic) = mutation {
            return .diagnostic(diagnostic)
        }

        let item = try apply(mutation, turnID: turnID)
        switch mutation {
        case .started:
            return .itemStarted(item)
        case .completed:
            return .itemCompleted(item)
        case .agentMessageDelta(let itemID, let delta):
            return .messageDelta(.init(
                text: delta,
                itemID: itemID,
                phase: item.message?.phase,
                currentItem: item
            ))
        case .reasoningSummaryPartAdded(let itemID, let index):
            return .reasoningSummaryPartAdded(.init(
                itemID: itemID,
                kind: .summary,
                index: index,
                currentItem: item
            ))
        case .reasoningSummaryDelta(let itemID, let index, let delta):
            let part = CodexReasoningPart(itemID: itemID, kind: .summary, index: index)
            return .reasoningDelta(.init(part: part, delta: delta, currentItem: item))
        case .reasoningTextDelta(let itemID, let index, let delta):
            let part = CodexReasoningPart(itemID: itemID, kind: .text, index: index)
            return .reasoningDelta(.init(part: part, delta: delta, currentItem: item))
        case .planDelta, .commandOutputDelta, .filePatchSnapshot, .mcpProgress:
            return .itemUpdated(item)
        case .turnDiagnostic:
            preconditionFailure("A turn diagnostic must return before item reduction.")
        }
    }

    package mutating func seed(_ turns: [CodexTurnSnapshot]?) {
        for turn in turns ?? [] {
            guard case .inProgress = turn.state else {
                continue
            }
            for item in turn.items where Self.hasValidID(item.id) {
                let key = ItemKey(turnID: turn.id, itemID: item.id)
                guard stateByItemKey[key] == nil else {
                    continue
                }
                stateByItemKey[key] = .init(item: item)
            }
        }
    }

    @discardableResult
    package mutating func apply(
        _ mutation: Mutation,
        turnID: CodexTurnID
    ) throws -> CodexThreadItem {
        switch mutation {
        case .started(let item):
            try Self.requireItemID(item.id)
            stateByItemKey[.init(turnID: turnID, itemID: item.id)] = .init(item: item)
            return item

        case .completed(let item):
            try Self.requireItemID(item.id)
            let key = ItemKey(turnID: turnID, itemID: item.id)
            guard let base = stateByItemKey[key]?.item else {
                stateByItemKey[key] = .init(item: item)
                return item
            }
            guard base.kind == item.kind else {
                throw ContractError.completedItemKindChanged(
                    turnID: turnID,
                    itemID: item.id,
                    started: base.kind,
                    completed: item.kind
                )
            }
            let merged = Self.mergeCompleted(item, preservingMetadataFrom: base)
            stateByItemKey[key]?.replace(with: merged)
            return merged

        case .agentMessageDelta(let itemID, let delta):
            return try update(itemID: itemID, turnID: turnID, expectedKind: .agentMessage) {
                guard case .message(var message) = $0.item.content else {
                    return false
                }
                message.text += delta
                $0.item.content = .message(message)
                return true
            }

        case .planDelta(let itemID, let delta):
            return try update(itemID: itemID, turnID: turnID, expectedKind: .plan) {
                guard case .plan(let text) = $0.item.content else {
                    return false
                }
                $0.item.content = .plan(text + delta)
                return true
            }

        case .reasoningSummaryPartAdded(let itemID, let index):
            guard index >= 0 else {
                throw ContractError.invalidReasoningIndex(itemID: itemID, index: index)
            }
            return try update(itemID: itemID, turnID: turnID, expectedKind: .reasoning) {
                guard case .reasoning = $0.item.content else {
                    return false
                }
                Self.grow(&$0.reasoningSummary, through: index)
                $0.updateReasoningProjection()
                return true
            }

        case .reasoningSummaryDelta(let itemID, let index, let delta):
            guard index >= 0 else {
                throw ContractError.invalidReasoningIndex(itemID: itemID, index: index)
            }
            return try update(itemID: itemID, turnID: turnID, expectedKind: .reasoning) {
                guard case .reasoning = $0.item.content else {
                    return false
                }
                Self.grow(&$0.reasoningSummary, through: index)
                $0.reasoningSummary?[index] += delta
                $0.updateReasoningProjection()
                return true
            }

        case .reasoningTextDelta(let itemID, let index, let delta):
            guard index >= 0 else {
                throw ContractError.invalidReasoningIndex(itemID: itemID, index: index)
            }
            return try update(itemID: itemID, turnID: turnID, expectedKind: .reasoning) {
                guard case .reasoning = $0.item.content else {
                    return false
                }
                Self.grow(&$0.reasoningContent, through: index)
                $0.reasoningContent?[index] += delta
                $0.updateReasoningProjection()
                return true
            }

        case .commandOutputDelta(let itemID, let delta):
            return try update(itemID: itemID, turnID: turnID, expectedKind: .commandExecution) {
                guard case .command(var command) = $0.item.content else {
                    return false
                }
                command.output = (command.output ?? "") + delta
                $0.item.content = .command(command)
                return true
            }

        case .filePatchSnapshot(let itemID, let output):
            return try update(itemID: itemID, turnID: turnID, expectedKind: .fileChange) {
                guard case .fileChange(var fileChange) = $0.item.content else {
                    return false
                }
                fileChange.output = output
                $0.item.content = .fileChange(fileChange)
                return true
            }

        case .mcpProgress(let itemID, let message):
            return try update(itemID: itemID, turnID: turnID, expectedKind: .mcpToolCall) {
                guard case .toolCall(var toolCall) = $0.item.content else {
                    return false
                }
                toolCall.result = message
                $0.item.content = .toolCall(toolCall)
                return true
            }

        case .turnDiagnostic:
            preconditionFailure("Use reduce(_:turnID:) for turn diagnostics.")
        }
    }

    package func item(turnID: CodexTurnID, itemID: String) -> CodexThreadItem? {
        stateByItemKey[.init(turnID: turnID, itemID: itemID)]?.item
    }

    package mutating func release(turnID: CodexTurnID) {
        stateByItemKey = stateByItemKey.filter { $0.key.turnID != turnID }
    }

    package mutating func releaseAll() {
        stateByItemKey.removeAll(keepingCapacity: false)
    }

    private mutating func update(
        itemID: String,
        turnID: CodexTurnID,
        expectedKind: CodexThreadItem.Kind,
        body: (inout ItemState) -> Bool
    ) throws -> CodexThreadItem {
        try Self.requireItemID(itemID)
        let key = ItemKey(turnID: turnID, itemID: itemID)
        guard var state = stateByItemKey[key] else {
            throw ContractError.missingBaseItem(turnID: turnID, itemID: itemID)
        }
        guard state.item.kind == expectedKind, body(&state) else {
            throw ContractError.unexpectedItemKind(
                turnID: turnID,
                itemID: itemID,
                expected: expectedKind,
                actual: state.item.kind
            )
        }
        stateByItemKey[key] = state
        return state.item
    }

    private static func mergeCompleted(
        _ completed: CodexThreadItem,
        preservingMetadataFrom started: CodexThreadItem
    ) -> CodexThreadItem {
        var merged = completed
        merged.rawPayload = completed.rawPayload ?? started.rawPayload
        switch (started.content, completed.content) {
        case (.message(let initial), .message(var final)):
            final.phase = final.phase ?? initial.phase
            merged.content = .message(final)

        case (.command(let initial), .command(var final)):
            if final.command.isEmpty {
                final.command = initial.command
            }
            final.cwd = final.cwd ?? initial.cwd
            final.output = final.output ?? initial.output
            final.exitCode = final.exitCode ?? initial.exitCode
            final.status = final.status ?? initial.status
            final.startedAt = final.startedAt ?? initial.startedAt
            final.completedAt = final.completedAt ?? initial.completedAt
            final.duration = final.duration ?? initial.duration
            final.processID = final.processID ?? initial.processID
            final.source = final.source ?? initial.source
            if final.commandActions.isEmpty {
                final.commandActions = initial.commandActions
            }
            merged.content = .command(final)

        case (.fileChange(let initial), .fileChange(var final)):
            final.path = final.path ?? initial.path
            final.output = final.output ?? initial.output
            final.status = final.status ?? initial.status
            merged.content = .fileChange(final)

        case (.toolCall(let initial), .toolCall(var final)):
            final.namespace = final.namespace ?? initial.namespace
            final.server = final.server ?? initial.server
            final.name = final.name ?? initial.name
            final.arguments = final.arguments ?? initial.arguments
            final.result = final.result ?? initial.result
            final.error = final.error ?? initial.error
            final.status = final.status ?? initial.status
            merged.content = .toolCall(final)

        default:
            break
        }
        return CodexThreadItem(
            id: merged.id,
            kind: merged.kind,
            content: merged.content,
            origin: started.origin,
            semanticRelation: started.semanticRelation,
            rawPayload: merged.rawPayload
        )
    }

    private static func grow(_ values: inout [String]?, through index: Int) {
        var buffer = values ?? []
        if buffer.count <= index {
            buffer.append(contentsOf: repeatElement("", count: index - buffer.count + 1))
        }
        values = buffer
    }

    private static func requireItemID(_ itemID: String) throws {
        guard hasValidID(itemID) else {
            throw ContractError.missingItemID
        }
    }

    private static func hasValidID(_ itemID: String) -> Bool {
        itemID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
