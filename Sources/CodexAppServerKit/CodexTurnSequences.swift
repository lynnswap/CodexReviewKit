import Foundation

package struct CodexThreadMessageSequence: AsyncSequence, Sendable {
    package typealias Element = CodexMessage

    private let events: CodexThreadEventSequence

    package init(events: CodexThreadEventSequence) {
        self.events = events
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator())
    }

    package struct Iterator: AsyncIteratorProtocol {
        private var events: CodexThreadEventSequence.Iterator
        private var pendingMessages: [CodexMessage] = []
        private var pendingMessageIndex = 0
        private var emittedMessagesByID: [String: CodexMessage] = [:]
        private var currentTurnID: CodexTurnID?

        fileprivate init(events: CodexThreadEventSequence.Iterator) {
            self.events = events
        }

        package mutating func next() async throws -> CodexMessage? {
            if let pending = nextPendingMessage() {
                return pending
            }
            while let event = try await events.next() {
                switch event {
                case .message(let message, let turnID):
                    beginGenerationIfNeeded(turnID)
                    emittedMessagesByID[message.id] = message
                    return message
                case .itemCompleted(let item, let turnID):
                    beginGenerationIfNeeded(turnID)
                    if let message = item.message {
                        emittedMessagesByID[message.id] = message
                        return message
                    }
                case .snapshot(let snapshot):
                    beginGenerationIfNeeded(snapshot.id)
                    pendingMessages = snapshot.items.compactMap(\.message).filter {
                        emittedMessagesByID[$0.id] != $0
                    }
                    for message in pendingMessages {
                        emittedMessagesByID[message.id] = message
                    }
                    pendingMessageIndex = 0
                    if let pending = nextPendingMessage() {
                        return pending
                    }
                case .itemStarted(_, let turnID), .itemUpdated(_, let turnID),
                     .messageDelta(_, let turnID),
                     .reasoningSummaryPartAdded(_, let turnID),
                     .reasoningDelta(_, let turnID),
                     .tokenUsageUpdated(_, let turnID):
                    beginGenerationIfNeeded(turnID)
                case .diagnostic(_, let turnID):
                    beginGenerationIfNeeded(turnID)
                case .turnStarted(let turnID):
                    beginGenerationIfNeeded(turnID)
                case .terminal(let outcome):
                    beginGenerationIfNeeded(outcome.response.turnID)
                case .unknown(let raw):
                    beginGenerationIfNeeded(raw.turnID)
                case .statusChanged, .closed:
                    break
                }
            }
            return nil
        }

        private mutating func nextPendingMessage() -> CodexMessage? {
            guard pendingMessageIndex < pendingMessages.count else {
                pendingMessages.removeAll(keepingCapacity: false)
                pendingMessageIndex = 0
                return nil
            }
            defer { pendingMessageIndex += 1 }
            return pendingMessages[pendingMessageIndex]
        }

        private mutating func beginGenerationIfNeeded(_ turnID: CodexTurnID?) {
            guard let turnID, currentTurnID != turnID else {
                return
            }
            currentTurnID = turnID
            pendingMessages.removeAll(keepingCapacity: false)
            pendingMessageIndex = 0
            emittedMessagesByID.removeAll(keepingCapacity: false)
        }
    }
}

package struct CodexThreadTranscriptSequence: AsyncSequence, Sendable {
    package typealias Element = CodexTranscript

    private let events: CodexThreadEventSequence

    package init(events: CodexThreadEventSequence) {
        self.events = events
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator())
    }

    package struct Iterator: AsyncIteratorProtocol {
        private var events: CodexThreadEventSequence.Iterator
        private var accumulator = CodexTranscriptAccumulator()

        fileprivate init(events: CodexThreadEventSequence.Iterator) {
            self.events = events
        }

        package mutating func next() async throws -> CodexTranscript? {
            while let event = try await events.next() {
                if accumulator.apply(event) {
                    return accumulator.transcript
                }
            }
            return nil
        }
    }
}

package struct CodexThreadLogSequence: AsyncSequence, Sendable {
    package typealias Element = CodexThreadLogEntry

    private let events: CodexThreadEventSequence
    private let terminalTurnID: CodexTurnID?

    package init(events: CodexThreadEventSequence, terminalTurnID: CodexTurnID? = nil) {
        self.events = events
        self.terminalTurnID = terminalTurnID
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator(), terminalTurnID: terminalTurnID)
    }

    package struct Iterator: AsyncIteratorProtocol {
        private var events: CodexThreadEventSequence.Iterator
        private let terminalTurnID: CodexTurnID?
        private var logEntryIndex = 0
        private var finished = false
        private var pendingSnapshotItems: [CodexThreadItem] = []
        private var pendingSnapshotIndex = 0
        private var pendingSnapshotTurnID: CodexTurnID?
        private var emittedItemsByID: [String: CodexThreadItem] = [:]
        private var currentTurnID: CodexTurnID?

        fileprivate init(
            events: CodexThreadEventSequence.Iterator,
            terminalTurnID: CodexTurnID?
        ) {
            self.events = events
            self.terminalTurnID = terminalTurnID
        }

        package mutating func next() async throws -> CodexThreadLogEntry? {
            guard finished == false else {
                return nil
            }
            if let pending = nextPendingSnapshotEntry() {
                return pending
            }
            while let event = try await events.next() {
                guard reviewEventMatches(event, terminalTurnID: terminalTurnID) else {
                    continue
                }
                switch event {
                case .itemStarted(let item, let turnID):
                    beginGenerationIfNeeded(turnID)
                    emittedItemsByID[item.id] = item
                    return .itemStarted(item, turnID: turnID)
                case .itemUpdated(let item, let turnID):
                    beginGenerationIfNeeded(turnID)
                    emittedItemsByID[item.id] = item
                    return .itemUpdated(item, turnID: turnID)
                case .itemCompleted(let item, let turnID):
                    beginGenerationIfNeeded(turnID)
                    emittedItemsByID[item.id] = item
                    return .itemCompleted(item, turnID: turnID)
                case .message(let message, let turnID):
                    beginGenerationIfNeeded(turnID)
                    let item = CodexThreadItem(
                        id: message.id,
                        kind: message.role == .user ? .userMessage : .agentMessage,
                        content: .message(message)
                    )
                    emittedItemsByID[item.id] = item
                    return .itemCompleted(item, turnID: turnID)
                case .messageDelta(let delta, let turnID):
                    beginGenerationIfNeeded(turnID)
                    return .messageDelta(delta, turnID: turnID, id: nextDeltaLogEntryID(for: delta))
                case .reasoningSummaryPartAdded(let part, let turnID):
                    beginGenerationIfNeeded(turnID)
                    return .reasoningPartStarted(part, turnID: turnID)
                case .reasoningDelta(let delta, let turnID):
                    beginGenerationIfNeeded(turnID)
                    return .reasoningDelta(delta, turnID: turnID)
                case .diagnostic(let diagnostic, let turnID):
                    beginGenerationIfNeeded(turnID)
                    return .diagnostic(
                        diagnostic,
                        turnID: turnID,
                        id: nextDiagnosticLogEntryID(turnID: turnID)
                    )
                case .snapshot(let snapshot):
                    beginGenerationIfNeeded(snapshot.id)
                    pendingSnapshotItems = snapshot.items.filter {
                        emittedItemsByID[$0.id] != $0
                    }
                    for item in pendingSnapshotItems {
                        emittedItemsByID[item.id] = item
                    }
                    pendingSnapshotIndex = 0
                    pendingSnapshotTurnID = snapshot.id
                    if let pending = nextPendingSnapshotEntry() {
                        return pending
                    }
                case .terminal(let outcome):
                    beginGenerationIfNeeded(outcome.response.turnID)
                    guard terminalTurnID != nil else {
                        continue
                    }
                    finished = true
                    return nil
                case .closed:
                    finished = true
                    return nil
                case .turnStarted(let turnID):
                    beginGenerationIfNeeded(turnID)
                case .tokenUsageUpdated(_, let turnID):
                    beginGenerationIfNeeded(turnID)
                case .unknown(let raw):
                    beginGenerationIfNeeded(raw.turnID)
                case .statusChanged:
                    break
                }
            }
            finished = true
            return nil
        }

        private mutating func nextPendingSnapshotEntry() -> CodexThreadLogEntry? {
            guard pendingSnapshotIndex < pendingSnapshotItems.count else {
                pendingSnapshotItems.removeAll(keepingCapacity: false)
                pendingSnapshotIndex = 0
                pendingSnapshotTurnID = nil
                return nil
            }
            defer { pendingSnapshotIndex += 1 }
            return .itemCompleted(
                pendingSnapshotItems[pendingSnapshotIndex],
                turnID: pendingSnapshotTurnID
            )
        }

        private mutating func beginGenerationIfNeeded(_ turnID: CodexTurnID?) {
            guard let turnID, currentTurnID != turnID else {
                return
            }
            currentTurnID = turnID
            pendingSnapshotItems.removeAll(keepingCapacity: false)
            pendingSnapshotIndex = 0
            pendingSnapshotTurnID = nil
            emittedItemsByID.removeAll(keepingCapacity: false)
        }

        private mutating func nextDeltaLogEntryID(for delta: CodexMessageDelta) -> String {
            defer {
                logEntryIndex += 1
            }
            return "\(delta.itemID):\(logEntryIndex)"
        }

        private mutating func nextDiagnosticLogEntryID(turnID: CodexTurnID) -> String {
            defer {
                logEntryIndex += 1
            }
            return "\(turnID.rawValue):diagnostic:\(logEntryIndex)"
        }
    }
}

/// Projection over a thread event stream for a `CodexReviewSession`.
package struct CodexReviewEventSequence: AsyncSequence, Sendable {
    package typealias Element = CodexReviewEvent

    private let events: CodexTurnEventSequence
    private let turnID: CodexTurnID

    package init(events: CodexTurnEventSequence, turnID: CodexTurnID) {
        self.events = events
        self.turnID = turnID
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator(), turnID: turnID)
    }

    package struct Iterator: AsyncIteratorProtocol {
        private var events: CodexTurnEventSequence.Iterator
        private let turnID: CodexTurnID
        private var finished = false

        fileprivate init(
            events: CodexTurnEventSequence.Iterator,
            turnID: CodexTurnID
        ) {
            self.events = events
            self.turnID = turnID
        }

        package mutating func next() async throws -> CodexReviewEvent? {
            guard finished == false else {
                return nil
            }
            guard let event = try await events.next() else {
                finished = true
                return nil
            }
            switch event {
            case .terminal(let outcome):
                finished = true
                return .terminal(outcome)
            case .started, .snapshot, .itemStarted, .itemUpdated, .itemCompleted, .message,
                 .messageDelta, .reasoningSummaryPartAdded, .reasoningDelta,
                 .diagnostic, .tokenUsageUpdated, .unknown:
                return CodexReviewEvent(event, turnID: turnID)
            }
        }
    }
}

/// Incremental review progress projected from the thread event stream.
package struct CodexReviewProgressSequence: AsyncSequence, Sendable {
    package typealias Element = CodexReviewProgress

    private let turnID: CodexTurnID
    private let store: TurnReplayStore
    private let state: TurnGenerationHandleState

    package init(
        turnID: CodexTurnID,
        store: TurnReplayStore,
        state: TurnGenerationHandleState
    ) {
        self.turnID = turnID
        self.store = store
        self.state = state
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(turnID: turnID, store: store, state: state)
    }

    package struct Iterator: AsyncIteratorProtocol {
        private let turnID: CodexTurnID
        private let store: TurnReplayStore
        private let state: TurnGenerationHandleState
        private var events: TurnReplayProgressEvents.Iterator?

        fileprivate init(
            turnID: CodexTurnID,
            store: TurnReplayStore,
            state: TurnGenerationHandleState
        ) {
            self.turnID = turnID
            self.store = store
            self.state = state
        }

        package mutating func next() async throws -> CodexReviewProgress? {
            if events == nil {
                events = try await store.progressEvents(for: turnID, state: state)
                    .makeAsyncIterator()
            }
            guard var iterator = events else {
                preconditionFailure("A replay progress iterator must be installed before use.")
            }
            let value = try await iterator.next()
            events = iterator
            return value
        }
    }
}

private func reviewEventMatches(
    _ event: CodexThreadEvent,
    terminalTurnID: CodexTurnID?
) -> Bool {
    guard let terminalTurnID else {
        return true
    }
    switch event {
    case .turnStarted(let turnID):
        return turnID == terminalTurnID
    case .snapshot(let snapshot):
        return snapshot.id == terminalTurnID
    case .terminal(let outcome):
        return outcome.response.turnID == terminalTurnID
    case .itemStarted(_, let turnID), .itemUpdated(_, let turnID),
         .itemCompleted(_, let turnID), .message(_, let turnID), .messageDelta(_, let turnID),
         .reasoningSummaryPartAdded(_, let turnID), .reasoningDelta(_, let turnID),
         .tokenUsageUpdated(_, let turnID):
        return turnID == terminalTurnID
    case .diagnostic(_, let turnID):
        return turnID == terminalTurnID
    case .unknown(let raw):
        return raw.turnID.map { $0 == terminalTurnID } ?? true
    case .statusChanged:
        return true
    case .closed:
        return true
    }
}

package struct CodexTurnEventSequence: AsyncSequence, Sendable {
    package typealias Element = CodexTurnEvent

    private let turnID: CodexTurnID
    private let store: TurnReplayStore
    private let state: TurnGenerationHandleState

    package init(
        turnID: CodexTurnID,
        store: TurnReplayStore,
        state: TurnGenerationHandleState
    ) {
        self.turnID = turnID
        self.store = store
        self.state = state
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(turnID: turnID, store: store, state: state)
    }

    package struct Iterator: AsyncIteratorProtocol {
        private let turnID: CodexTurnID
        private let store: TurnReplayStore
        private let state: TurnGenerationHandleState
        private var events: TurnReplayEvents.Iterator?

        fileprivate init(
            turnID: CodexTurnID,
            store: TurnReplayStore,
            state: TurnGenerationHandleState
        ) {
            self.turnID = turnID
            self.store = store
            self.state = state
        }

        package mutating func next() async throws -> CodexTurnEvent? {
            if events == nil {
                events = try await store.events(for: turnID, state: state)
                    .makeAsyncIterator()
            }
            guard var iterator = events else {
                preconditionFailure("A turn replay iterator must be installed before use.")
            }
            let value = try await iterator.next()
            events = iterator
            return value
        }
    }
}

package struct CodexTurnProgressSequence: AsyncSequence, Sendable {
    package typealias Element = CodexTurnProgress

    private let turnID: CodexTurnID
    private let store: TurnReplayStore
    private let state: TurnGenerationHandleState

    package init(
        turnID: CodexTurnID,
        store: TurnReplayStore,
        state: TurnGenerationHandleState
    ) {
        self.turnID = turnID
        self.store = store
        self.state = state
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(turnID: turnID, store: store, state: state)
    }

    package struct Iterator: AsyncIteratorProtocol {
        private var events: CodexReviewProgressSequence.Iterator

        fileprivate init(
            turnID: CodexTurnID,
            store: TurnReplayStore,
            state: TurnGenerationHandleState
        ) {
            self.events = CodexReviewProgressSequence(
                turnID: turnID,
                store: store,
                state: state
            ).makeAsyncIterator()
        }

        package mutating func next() async throws -> CodexTurnProgress? {
            switch try await events.next() {
            case .running(let transcript, let usage):
                .running(transcript: transcript, usage: usage)
            case .terminal(let outcome):
                .terminal(outcome)
            case nil:
                nil
            }
        }
    }
}

package struct CodexTurnMessageSequence: AsyncSequence, Sendable {
    package typealias Element = CodexMessage
    private let events: CodexTurnEventSequence

    package init(events: CodexTurnEventSequence) {
        self.events = events
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator())
    }

    package struct Iterator: AsyncIteratorProtocol {
        private var events: CodexTurnEventSequence.Iterator
        private var pendingMessages: [CodexMessage] = []
        private var pendingMessageIndex = 0

        fileprivate init(events: CodexTurnEventSequence.Iterator) {
            self.events = events
        }

        package mutating func next() async throws -> CodexMessage? {
            if let pending = nextPendingMessage() {
                return pending
            }
            while let event = try await events.next() {
                switch event {
                case .message(let message):
                    return message
                case .itemCompleted(let item):
                    if let message = item.message {
                        return message
                    }
                case .snapshot(let snapshot):
                    pendingMessages = snapshot.items.compactMap(\.message)
                    pendingMessageIndex = 0
                    if let pending = nextPendingMessage() {
                        return pending
                    }
                case .started, .terminal, .itemStarted, .itemUpdated,
                     .messageDelta, .reasoningSummaryPartAdded, .reasoningDelta,
                     .diagnostic, .tokenUsageUpdated, .unknown:
                    continue
                }
            }
            return nil
        }

        private mutating func nextPendingMessage() -> CodexMessage? {
            guard pendingMessageIndex < pendingMessages.count else {
                pendingMessages.removeAll(keepingCapacity: false)
                pendingMessageIndex = 0
                return nil
            }
            defer { pendingMessageIndex += 1 }
            return pendingMessages[pendingMessageIndex]
        }
    }
}

package struct CodexTurnTranscriptSequence: AsyncSequence, Sendable {
    package typealias Element = CodexTranscript
    private let events: CodexTurnEventSequence

    package init(events: CodexTurnEventSequence) {
        self.events = events
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator())
    }

    package struct Iterator: AsyncIteratorProtocol {
        private var events: CodexTurnEventSequence.Iterator
        private var accumulator = CodexTranscriptAccumulator()

        fileprivate init(events: CodexTurnEventSequence.Iterator) {
            self.events = events
        }

        package mutating func next() async throws -> CodexTranscript? {
            while let event = try await events.next() {
                if accumulator.apply(event) {
                    return accumulator.transcript
                }
            }
            return nil
        }
    }
}

package struct CodexTurnLogSequence: AsyncSequence, Sendable {
    package typealias Element = CodexThreadLogEntry
    private let events: CodexTurnEventSequence
    private let turnID: CodexTurnID

    package init(events: CodexTurnEventSequence, turnID: CodexTurnID) {
        self.events = events
        self.turnID = turnID
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator(), turnID: turnID)
    }

    package struct Iterator: AsyncIteratorProtocol {
        private var events: CodexTurnEventSequence.Iterator
        private let turnID: CodexTurnID
        private var logEntryIndex = 0
        private var pendingSnapshotItems: [CodexThreadItem] = []
        private var pendingSnapshotIndex = 0

        fileprivate init(events: CodexTurnEventSequence.Iterator, turnID: CodexTurnID) {
            self.events = events
            self.turnID = turnID
        }

        package mutating func next() async throws -> CodexThreadLogEntry? {
            if let pending = nextPendingSnapshotEntry() {
                return pending
            }
            while let event = try await events.next() {
                switch event {
                case .itemStarted(let item):
                    return .itemStarted(item, turnID: turnID)
                case .itemUpdated(let item):
                    return .itemUpdated(item, turnID: turnID)
                case .itemCompleted(let item):
                    return .itemCompleted(item, turnID: turnID)
                case .message(let message):
                    return .itemCompleted(
                        .init(
                            id: message.id,
                            kind: message.role == .user ? .userMessage : .agentMessage,
                            content: .message(message)
                        ),
                        turnID: turnID
                    )
                case .messageDelta(let delta):
                    defer { logEntryIndex += 1 }
                    return .messageDelta(
                        delta,
                        turnID: turnID,
                        id: "\(delta.itemID):\(logEntryIndex)"
                    )
                case .reasoningSummaryPartAdded(let part):
                    return .reasoningPartStarted(part, turnID: turnID)
                case .reasoningDelta(let delta):
                    return .reasoningDelta(delta, turnID: turnID)
                case .diagnostic(let diagnostic):
                    defer { logEntryIndex += 1 }
                    return .diagnostic(
                        diagnostic,
                        turnID: turnID,
                        id: "\(turnID.rawValue):diagnostic:\(logEntryIndex)"
                    )
                case .terminal:
                    return nil
                case .snapshot(let snapshot):
                    pendingSnapshotItems = snapshot.items
                    pendingSnapshotIndex = 0
                    if let pending = nextPendingSnapshotEntry() {
                        return pending
                    }
                case .started, .tokenUsageUpdated, .unknown:
                    continue
                }
            }
            return nil
        }

        private mutating func nextPendingSnapshotEntry() -> CodexThreadLogEntry? {
            guard pendingSnapshotIndex < pendingSnapshotItems.count else {
                pendingSnapshotItems.removeAll(keepingCapacity: false)
                pendingSnapshotIndex = 0
                return nil
            }
            defer { pendingSnapshotIndex += 1 }
            return .itemCompleted(
                pendingSnapshotItems[pendingSnapshotIndex],
                turnID: turnID
            )
        }
    }
}

package struct CodexResponseCollector {
    static func collect(from events: CodexTurnEventSequence) async throws -> CodexTurnOutcome {
        var accumulator = CodexResponseAccumulator()
        for try await event in events {
            switch event {
            case .started, .snapshot, .diagnostic, .unknown:
                continue
            case .itemStarted, .itemUpdated, .itemCompleted, .message, .messageDelta,
                .reasoningSummaryPartAdded, .reasoningDelta:
                _ = accumulator.apply(event)
            case .tokenUsageUpdated:
                _ = accumulator.apply(event)
            case .terminal(let outcome):
                return accumulator.finalized(outcome)
            }
        }
        try Task.checkCancellation()
        throw CodexAppServerError.connectionTerminated(.transportFailure(.closed))
    }
}

private struct CodexResponseAccumulator {
    private var transcriptAccumulator = CodexTranscriptAccumulator()
    private(set) var usage: CodexTokenUsage?

    var transcript: CodexTranscript {
        transcriptAccumulator.transcript
    }

    mutating func apply(_ event: CodexTurnEvent) -> Bool {
        switch event {
        case .tokenUsageUpdated(let newUsage):
            usage = newUsage
            return true
        case .started, .snapshot, .diagnostic, .terminal, .unknown:
            return false
        case .itemStarted, .itemUpdated, .itemCompleted, .message, .messageDelta,
            .reasoningSummaryPartAdded, .reasoningDelta:
            return transcriptAccumulator.apply(event)
        }
    }

    mutating func apply(_ event: CodexThreadEvent) -> Bool {
        switch event {
        case .tokenUsageUpdated(let newUsage, _):
            usage = newUsage
            return true
        case .turnStarted, .snapshot, .diagnostic, .terminal, .statusChanged, .closed, .unknown:
            return false
        case .itemStarted, .itemUpdated, .itemCompleted, .message, .messageDelta,
            .reasoningSummaryPartAdded, .reasoningDelta:
            return transcriptAccumulator.apply(event)
        }
    }

    func finalized(_ response: CodexResponse) -> CodexResponse {
        var response = response
        let finalizedTranscript = finalizedTranscript(
            for: response.transcript,
            itemsLoadState: response.transcriptItemsLoadState
        )
        response.transcript = finalizedTranscript
        if response.usage == nil {
            response.usage = usage
        }
        return response
    }

    func finalized(_ outcome: CodexTurnOutcome) -> CodexTurnOutcome {
        switch outcome {
        case .completed(let response):
            .completed(finalized(response))
        case .interrupted(let response):
            .interrupted(finalized(response))
        case .failed(let failedTurn):
            .failed(.init(response: finalized(failedTurn.response), error: failedTurn.error))
        case .invalidTerminalStatus(let rawStatus, let error, let response):
            .invalidTerminalStatus(
                rawStatus: rawStatus,
                error: error,
                response: finalized(response)
            )
        }
    }

    private func finalizedTranscript(
        for terminalTranscript: CodexTranscript,
        itemsLoadState: CodexTurnItemsLoadState
    ) -> CodexTranscript {
        guard itemsLoadState != .full else {
            return terminalTranscript
        }
        let liveTranscript = transcript
        guard terminalTranscript.items.isEmpty == false else {
            return liveTranscript
        }
        guard terminalTranscript.reviewOutputText == nil else {
            return terminalTranscript
        }

        var mergedItems = terminalTranscript.items
        var didMerge = false
        for liveItem in liveTranscript.items where liveItem.kind == .exitedReviewMode {
            guard liveItem.text?.isEmpty == false else {
                continue
            }
            if let index = mergedItems.firstIndex(where: { $0.id == liveItem.id && $0.kind == liveItem.kind }) {
                guard mergedItems[index].text?.isEmpty != false else {
                    continue
                }
                mergedItems[index] = liveItem
            } else {
                mergedItems.append(liveItem)
            }
            didMerge = true
        }
        guard didMerge else {
            return terminalTranscript
        }
        return CodexTranscript(items: mergedItems)
    }
}

private struct CodexTranscriptAccumulator {
    private var items: [CodexThreadItem] = []
    private var itemIndexesByID: [String: Int] = [:]

    var transcript: CodexTranscript {
        .init(items: items)
    }

    mutating func apply(_ event: CodexTurnEvent) -> Bool {
        switch event {
        case .snapshot(let snapshot):
            let previousItems = items
            replace(with: snapshot.items)
            return items != previousItems
        case .itemStarted(let item), .itemUpdated(let item), .itemCompleted(let item):
            upsert(item)
            return true
        case .message(let message):
            upsert(
                .init(
                    id: message.id,
                    kind: message.role == .user ? .userMessage : .agentMessage,
                    content: .message(message)
                )
            )
            return true
        case .messageDelta(let delta):
            upsert(Self.currentItem(from: delta))
            return true
        case .reasoningSummaryPartAdded(let part):
            upsert(Self.currentItem(from: part))
            return true
        case .reasoningDelta(let delta):
            upsert(Self.currentItem(from: delta))
            return true
        case .started, .diagnostic, .tokenUsageUpdated, .terminal, .unknown:
            return false
        }
    }

    private mutating func replace(with snapshotItems: [CodexThreadItem]) {
        items.removeAll(keepingCapacity: true)
        itemIndexesByID.removeAll(keepingCapacity: true)
        for item in snapshotItems {
            upsert(item)
        }
    }

    mutating func apply(_ event: CodexThreadEvent) -> Bool {
        switch event {
        case .snapshot(let snapshot):
            let previousItems = items
            replace(with: snapshot.items)
            return items != previousItems
        case .itemStarted(let item, _), .itemUpdated(let item, _), .itemCompleted(let item, _):
            upsert(item)
            return true
        case .message(let message, _):
            upsert(
                .init(
                    id: message.id,
                    kind: message.role == .user ? .userMessage : .agentMessage,
                    content: .message(message)
                )
            )
            return true
        case .messageDelta(let delta, _):
            upsert(Self.currentItem(from: delta))
            return true
        case .reasoningSummaryPartAdded(let part, _):
            upsert(Self.currentItem(from: part))
            return true
        case .reasoningDelta(let delta, _):
            upsert(Self.currentItem(from: delta))
            return true
        case .turnStarted, .diagnostic, .terminal, .tokenUsageUpdated, .statusChanged,
            .closed, .unknown:
            return false
        }
    }

    private mutating func upsert(_ item: CodexThreadItem) {
        if let index = itemIndexesByID[item.id] {
            items[index] = item
        } else {
            itemIndexesByID[item.id] = items.count
            items.append(item)
        }
    }

    private static func currentItem(from delta: CodexMessageDelta) -> CodexThreadItem {
        guard let currentItem = delta.currentItem else {
            preconditionFailure("CodexMessageDelta must be emitted through CodexItemReducer.")
        }
        return currentItem
    }

    private static func currentItem(from part: CodexReasoningPart) -> CodexThreadItem {
        guard let currentItem = part.currentItem else {
            preconditionFailure("CodexReasoningPart must be emitted through CodexItemReducer.")
        }
        return currentItem
    }

    private static func currentItem(from delta: CodexReasoningDelta) -> CodexThreadItem {
        guard let currentItem = delta.currentItem else {
            preconditionFailure("CodexReasoningDelta must be emitted through CodexItemReducer.")
        }
        return currentItem
    }
}
