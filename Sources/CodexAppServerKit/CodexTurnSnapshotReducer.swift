import Foundation

struct CodexTurnItemIdentity: Hashable, Sendable {
    var id: String
    var kind: CodexThreadItem.Kind

    init(_ item: CodexThreadItem) {
        id = item.id
        kind = item.kind
    }
}

struct CodexTurnSnapshotReducer: Equatable, Sendable {
    private enum ItemEvidence: Equatable, Sendable {
        case partialSnapshot
        case completeSnapshot
        case observed
    }

    private(set) var snapshot: CodexTurnSnapshot
    private var evidenceByIdentity: [CodexTurnItemIdentity: ItemEvidence]
    private var hasSnapshotEvidence: Bool

    init(turnID: CodexTurnID) {
        snapshot = .init(
            id: turnID,
            state: .inProgress,
            itemsLoadState: .notLoaded
        )
        evidenceByIdentity = [:]
        hasSnapshotEvidence = false
    }

    init(snapshot: CodexTurnSnapshot) {
        self.snapshot = snapshot
        evidenceByIdentity = Self.snapshotEvidence(for: snapshot)
        hasSnapshotEvidence = true
    }

    mutating func markStarted() {
        guard hasSnapshotEvidence == false else {
            return
        }
        snapshot.itemsLoadState = .full
    }

    mutating func replace(with newSnapshot: CodexTurnSnapshot) {
        replace(with: newSnapshot, hasSnapshotEvidence: true)
    }

    mutating func replaceBindingSnapshot(with newSnapshot: CodexTurnSnapshot) {
        replace(
            with: newSnapshot,
            hasSnapshotEvidence: newSnapshot.itemsLoadState != .notLoaded
                || newSnapshot.items.isEmpty == false
        )
    }

    private mutating func replace(
        with newSnapshot: CodexTurnSnapshot,
        hasSnapshotEvidence: Bool
    ) {
        precondition(newSnapshot.id == snapshot.id)
        snapshot = newSnapshot
        evidenceByIdentity = Self.snapshotEvidence(for: newSnapshot)
        self.hasSnapshotEvidence = hasSnapshotEvidence
    }

    mutating func merge(_ newSnapshot: CodexTurnSnapshot) {
        precondition(newSnapshot.id == snapshot.id)
        hasSnapshotEvidence = true
        if snapshot.itemsLoadState == .full, newSnapshot.itemsLoadState != .full {
            mergePartialSnapshotIntoCompleteState(newSnapshot)
            return
        }
        var items = newSnapshot.items
        var indexes = Self.indexes(for: items)
        var mergedEvidence = Self.snapshotEvidence(for: newSnapshot)

        for item in snapshot.items {
            let identity = CodexTurnItemIdentity(item)
            let evidence = evidenceByIdentity[identity]
                ?? Self.snapshotEvidence(for: snapshot.itemsLoadState)
            if let index = indexes[identity] {
                if evidence == .observed
                    || (evidence == .completeSnapshot && newSnapshot.itemsLoadState != .full)
                {
                    items[index] = item
                    mergedEvidence[identity] = evidence
                }
            } else if newSnapshot.itemsLoadState != .full || evidence == .observed {
                indexes[identity] = items.count
                items.append(item)
                mergedEvidence[identity] = evidence
            }
        }

        snapshot = .init(
            id: newSnapshot.id,
            state: newSnapshot.state,
            itemsLoadState: Self.moreComplete(
                snapshot.itemsLoadState,
                newSnapshot.itemsLoadState
            ),
            items: items,
            startedAt: newSnapshot.startedAt ?? snapshot.startedAt,
            completedAt: newSnapshot.completedAt ?? snapshot.completedAt,
            duration: newSnapshot.duration ?? snapshot.duration
        )
        evidenceByIdentity = mergedEvidence
    }

    private mutating func mergePartialSnapshotIntoCompleteState(
        _ newSnapshot: CodexTurnSnapshot
    ) {
        var indexes = Self.indexes(for: snapshot.items)
        for item in newSnapshot.items {
            let identity = CodexTurnItemIdentity(item)
            guard indexes[identity] == nil else {
                continue
            }
            indexes[identity] = snapshot.items.count
            snapshot.items.append(item)
            evidenceByIdentity[identity] = .partialSnapshot
        }
        snapshot = .init(
            id: newSnapshot.id,
            state: newSnapshot.state,
            itemsLoadState: .full,
            items: snapshot.items,
            startedAt: newSnapshot.startedAt ?? snapshot.startedAt,
            completedAt: newSnapshot.completedAt ?? snapshot.completedAt,
            duration: newSnapshot.duration ?? snapshot.duration
        )
    }

    mutating func observe(_ item: CodexThreadItem) {
        let identity = CodexTurnItemIdentity(item)
        if let index = snapshot.items.firstIndex(where: {
            CodexTurnItemIdentity($0) == identity
        }) {
            snapshot.items[index] = item
        } else {
            snapshot.items.append(item)
        }
        evidenceByIdentity[identity] = .observed
    }

    mutating func finish(_ outcome: CodexTurnOutcome) -> CompactTurnSnapshot {
        precondition(outcome.response.turnID == snapshot.id)
        var response = outcome.response
        let terminalItems = response.transcript.items
        let terminalLoadState = response.transcriptItemsLoadState

        if terminalLoadState == .full {
            snapshot.items = terminalItems
            evidenceByIdentity = Self.snapshotEvidence(
                for: terminalItems,
                loadState: .full
            )
        } else {
            var indexes = Self.indexes(for: snapshot.items)
            for terminalItem in terminalItems {
                let identity = CodexTurnItemIdentity(terminalItem)
                if let index = indexes[identity] {
                    switch evidenceByIdentity[identity] {
                    case .completeSnapshot, .observed:
                        break
                    case .partialSnapshot, nil:
                        snapshot.items[index] = terminalItem
                        evidenceByIdentity[identity] = .partialSnapshot
                    }
                } else {
                    indexes[identity] = snapshot.items.count
                    snapshot.items.append(terminalItem)
                    evidenceByIdentity[identity] = .partialSnapshot
                }
            }
        }

        let finalLoadState = Self.moreComplete(
            snapshot.itemsLoadState,
            terminalLoadState
        )
        response.transcript = .init(items: snapshot.items)
        response.transcriptItemsLoadState = finalLoadState
        let finalOutcome = outcome.replacingResponse(response)
        snapshot = .init(
            id: response.turnID,
            state: .init(outcome: finalOutcome),
            itemsLoadState: finalLoadState,
            items: response.transcript.items,
            startedAt: response.startedAt ?? snapshot.startedAt,
            completedAt: response.completedAt ?? snapshot.completedAt,
            duration: response.duration ?? snapshot.duration
        )
        if finalLoadState == .full {
            evidenceByIdentity = Self.snapshotEvidence(for: snapshot)
        }
        return .init(snapshot: snapshot, outcome: finalOutcome)
    }

    private static func snapshotEvidence(
        for snapshot: CodexTurnSnapshot
    ) -> [CodexTurnItemIdentity: ItemEvidence] {
        snapshotEvidence(for: snapshot.items, loadState: snapshot.itemsLoadState)
    }

    private static func snapshotEvidence(
        for items: [CodexThreadItem],
        loadState: CodexTurnItemsLoadState
    ) -> [CodexTurnItemIdentity: ItemEvidence] {
        let evidence = snapshotEvidence(for: loadState)
        var result: [CodexTurnItemIdentity: ItemEvidence] = [:]
        for item in items {
            let identity = CodexTurnItemIdentity(item)
            precondition(
                result.updateValue(evidence, forKey: identity) == nil,
                "A turn snapshot cannot contain duplicate item identities."
            )
        }
        return result
    }

    private static func snapshotEvidence(
        for loadState: CodexTurnItemsLoadState
    ) -> ItemEvidence {
        loadState == .full ? .completeSnapshot : .partialSnapshot
    }

    private static func indexes(
        for items: [CodexThreadItem]
    ) -> [CodexTurnItemIdentity: Int] {
        var result: [CodexTurnItemIdentity: Int] = [:]
        for index in items.indices {
            let identity = CodexTurnItemIdentity(items[index])
            precondition(
                result.updateValue(index, forKey: identity) == nil,
                "A turn snapshot cannot contain duplicate item identities."
            )
        }
        return result
    }

    private static func moreComplete(
        _ lhs: CodexTurnItemsLoadState,
        _ rhs: CodexTurnItemsLoadState
    ) -> CodexTurnItemsLoadState {
        if lhs == .full || rhs == .full {
            return .full
        }
        if lhs == .summary || rhs == .summary {
            return .summary
        }
        return .notLoaded
    }
}

private extension CodexTurnSnapshot.State {
    init(outcome: CodexTurnOutcome) {
        switch outcome {
        case .completed:
            self = .completed
        case .interrupted:
            self = .interrupted
        case .failed(let failed):
            self = .failed(failed.error)
        case .invalidTerminalStatus(let rawStatus, let error, _):
            self = .unknown(rawValue: rawStatus, error: error)
        }
    }
}

private extension CodexTurnOutcome {
    func replacingResponse(_ response: CodexResponse) -> Self {
        switch self {
        case .completed:
            .completed(response)
        case .interrupted:
            .interrupted(response)
        case .failed(let failed):
            .failed(.init(response: response, error: failed.error))
        case .invalidTerminalStatus(let rawStatus, let error, _):
            .invalidTerminalStatus(
                rawStatus: rawStatus,
                error: error,
                response: response
            )
        }
    }
}
