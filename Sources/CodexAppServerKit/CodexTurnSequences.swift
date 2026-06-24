import Foundation

public struct CodexThreadEventSequence: AsyncSequence, Sendable {
    public typealias Element = CodexThreadEvent

    private let makeStream: @Sendable () -> AsyncThrowingStream<CodexThreadEvent, Error>

    package init(
        makeStream: @escaping @Sendable () -> AsyncThrowingStream<CodexThreadEvent, Error>
    ) {
        self.makeStream = makeStream
    }

    public func makeAsyncIterator() -> AsyncThrowingStream<CodexThreadEvent, Error>.Iterator {
        makeStream().makeAsyncIterator()
    }
}

public struct CodexThreadMessageSequence: AsyncSequence, Sendable {
    public typealias Element = CodexMessage

    private let events: CodexThreadEventSequence

    package init(events: CodexThreadEventSequence) {
        self.events = events
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator())
    }

    public struct Iterator: AsyncIteratorProtocol {
        private var events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator

        fileprivate init(events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator) {
            self.events = events
        }

        public mutating func next() async throws -> CodexMessage? {
            while let event = try await events.next() {
                switch event {
                case .message(let message, _):
                    return message
                case .itemCompleted(let item, _):
                    if let message = item.message {
                        return message
                    }
                case .itemStarted, .itemUpdated, .messageDelta:
                    continue
                case .turnStarted, .turnCompleted, .turnFailed, .reasoningSummaryPartAdded,
                    .reasoningDelta, .tokenUsageUpdated, .statusChanged, .closed, .unknown:
                    continue
                }
            }
            return nil
        }
    }
}

public struct CodexThreadTranscriptSequence: AsyncSequence, Sendable {
    public typealias Element = CodexTranscript

    private let events: CodexThreadEventSequence

    package init(events: CodexThreadEventSequence) {
        self.events = events
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator())
    }

    public struct Iterator: AsyncIteratorProtocol {
        private var events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator
        private var accumulator = CodexTranscriptAccumulator()

        fileprivate init(events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator) {
            self.events = events
        }

        public mutating func next() async throws -> CodexTranscript? {
            while let event = try await events.next() {
                if accumulator.apply(event) {
                    return accumulator.transcript
                }
            }
            return nil
        }
    }
}

public struct CodexThreadLogSequence: AsyncSequence, Sendable {
    public typealias Element = CodexThreadLogEntry

    private let events: CodexThreadEventSequence

    package init(events: CodexThreadEventSequence) {
        self.events = events
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator())
    }

    public struct Iterator: AsyncIteratorProtocol {
        private var events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator
        private var logEntryIndex = 0

        fileprivate init(events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator) {
            self.events = events
        }

        public mutating func next() async throws -> CodexThreadLogEntry? {
            while let event = try await events.next() {
                switch event {
                case .itemStarted(let item, let turnID):
                    return .itemStarted(item, turnID: turnID)
                case .itemUpdated(let item, let turnID):
                    return .itemUpdated(item, turnID: turnID)
                case .itemCompleted(let item, let turnID):
                    return .itemCompleted(item, turnID: turnID)
                case .message(let message, let turnID):
                    let item = CodexThreadItem(
                        id: message.id,
                        kind: message.role == .user ? .userMessage : .agentMessage,
                        content: .message(message)
                    )
                    return .itemCompleted(item, turnID: turnID)
                case .messageDelta(let delta, let turnID):
                    return .messageDelta(delta, turnID: turnID, id: nextDeltaLogEntryID(for: delta))
                case .reasoningSummaryPartAdded(let part, let turnID):
                    return .reasoningPartStarted(part, turnID: turnID)
                case .reasoningDelta(let delta, let turnID):
                    return .reasoningDelta(delta, turnID: turnID)
                case .turnStarted, .turnCompleted, .turnFailed, .tokenUsageUpdated, .statusChanged,
                    .closed, .unknown:
                    continue
                }
            }
            return nil
        }

        private mutating func nextDeltaLogEntryID(for delta: CodexMessageDelta) -> String {
            defer {
                logEntryIndex += 1
            }
            return "\(delta.itemID ?? "agent-message-delta"):\(logEntryIndex)"
        }
    }
}

/// Review-scoped event stream for a `CodexReviewSession`.
public struct CodexReviewEventSequence: AsyncSequence, Sendable {
    public typealias Element = CodexReviewEvent

    private let events: CodexThreadEventSequence
    private let terminalTurnID: CodexTurnID?

    package init(events: CodexThreadEventSequence, terminalTurnID: CodexTurnID? = nil) {
        self.events = events
        self.terminalTurnID = terminalTurnID
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator(), terminalTurnID: terminalTurnID)
    }

    public struct Iterator: AsyncIteratorProtocol {
        private var events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator
        private let terminalTurnID: CodexTurnID?
        private var finished = false

        fileprivate init(
            events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator,
            terminalTurnID: CodexTurnID?
        ) {
            self.events = events
            self.terminalTurnID = terminalTurnID
        }

        public mutating func next() async throws -> CodexReviewEvent? {
            guard finished == false else {
                return nil
            }
            guard let event = try await events.next() else {
                return nil
            }
            if isTerminal(event) {
                finished = true
            }
            return CodexReviewEvent(event)
        }

        private func isTerminal(_ event: CodexThreadEvent) -> Bool {
            switch event {
            case .turnCompleted(let response):
                guard terminalTurnID.map({ response.turnID == $0 }) ?? true else {
                    return false
                }
                return response.shouldFinishReviewSequence
            case .turnFailed(let turnID, _):
                return terminalTurnID.map { turnID == $0 } ?? true
            case .itemCompleted(let item, let turnID):
                return item.finishesReviewMode && matchesTerminalTurn(turnID)
            case .closed:
                return true
            case .turnStarted, .itemStarted, .itemUpdated, .message, .messageDelta,
                .reasoningSummaryPartAdded, .reasoningDelta, .tokenUsageUpdated, .statusChanged,
                .unknown:
                return false
            }
        }

        private func matchesTerminalTurn(_ turnID: CodexTurnID?) -> Bool {
            terminalTurnID.map { turnID == $0 } ?? true
        }
    }
}

/// Review-scoped log stream for a `CodexReviewSession`.
public struct CodexReviewLogSequence: AsyncSequence, Sendable {
    public typealias Element = CodexReviewLogEntry

    private let events: CodexThreadEventSequence
    private let terminalTurnID: CodexTurnID?

    package init(events: CodexThreadEventSequence, terminalTurnID: CodexTurnID? = nil) {
        self.events = events
        self.terminalTurnID = terminalTurnID
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator(), terminalTurnID: terminalTurnID)
    }

    public struct Iterator: AsyncIteratorProtocol {
        private var events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator
        private let terminalTurnID: CodexTurnID?
        private var logEntryIndex = 0
        private var finished = false

        fileprivate init(
            events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator,
            terminalTurnID: CodexTurnID?
        ) {
            self.events = events
            self.terminalTurnID = terminalTurnID
        }

        public mutating func next() async throws -> CodexReviewLogEntry? {
            guard finished == false else {
                return nil
            }
            while let event = try await events.next() {
                switch event {
                case .itemStarted(let item, let turnID):
                    return .itemStarted(item, turnID: turnID)
                case .itemUpdated(let item, let turnID):
                    return .itemUpdated(item, turnID: turnID)
                case .itemCompleted(let item, let turnID):
                    if isTerminal(event) {
                        finished = true
                        return nil
                    }
                    return .itemCompleted(item, turnID: turnID)
                case .message(let message, let turnID):
                    let item = CodexThreadItem(
                        id: message.id,
                        kind: message.role == .user ? .userMessage : .agentMessage,
                        content: .message(message)
                    )
                    return .itemCompleted(item, turnID: turnID)
                case .messageDelta(let delta, let turnID):
                    return .messageDelta(delta, turnID: turnID, id: nextDeltaLogEntryID(for: delta))
                case .reasoningSummaryPartAdded(let part, let turnID):
                    return .reasoningPartStarted(part, turnID: turnID)
                case .reasoningDelta(let delta, let turnID):
                    return .reasoningDelta(delta, turnID: turnID)
                case .turnCompleted, .turnFailed, .closed:
                    if isTerminal(event) {
                        finished = true
                        return nil
                    }
                    continue
                case .turnStarted, .tokenUsageUpdated, .statusChanged, .unknown:
                    continue
                }
            }
            finished = true
            return nil
        }

        private mutating func nextDeltaLogEntryID(for delta: CodexMessageDelta) -> String {
            defer {
                logEntryIndex += 1
            }
            return "\(delta.itemID ?? "agent-message-delta"):\(logEntryIndex)"
        }

        private func isTerminal(_ event: CodexThreadEvent) -> Bool {
            switch event {
            case .turnCompleted(let response):
                guard terminalTurnID.map({ response.turnID == $0 }) ?? true else {
                    return false
                }
                return response.shouldFinishReviewSequence
            case .turnFailed(let turnID, _):
                return terminalTurnID.map { turnID == $0 } ?? true
            case .itemCompleted(let item, let turnID):
                return item.finishesReviewMode && matchesTerminalTurn(turnID)
            case .closed:
                return true
            case .turnStarted, .itemStarted, .itemUpdated, .message, .messageDelta,
                .reasoningSummaryPartAdded, .reasoningDelta, .tokenUsageUpdated, .statusChanged,
                .unknown:
                return false
            }
        }

        private func matchesTerminalTurn(_ turnID: CodexTurnID?) -> Bool {
            terminalTurnID.map { turnID == $0 } ?? true
        }
    }
}

/// Incremental progress stream for a `CodexReviewSession`.
public struct CodexReviewProgressSequence: AsyncSequence, Sendable {
    public typealias Element = CodexReviewProgress

    private let events: CodexThreadEventSequence
    private let terminalTurnID: CodexTurnID?

    package init(events: CodexThreadEventSequence, terminalTurnID: CodexTurnID? = nil) {
        self.events = events
        self.terminalTurnID = terminalTurnID
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator(), terminalTurnID: terminalTurnID)
    }

    public struct Iterator: AsyncIteratorProtocol {
        private var events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator
        private let terminalTurnID: CodexTurnID?
        private var accumulator = CodexTranscriptAccumulator()
        private var usage: CodexTokenUsage?
        private var finished = false

        fileprivate init(
            events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator,
            terminalTurnID: CodexTurnID?
        ) {
            self.events = events
            self.terminalTurnID = terminalTurnID
        }

        public mutating func next() async throws -> CodexReviewProgress? {
            guard finished == false else {
                return nil
            }
            while let event = try await events.next() {
                switch event {
                case .turnStarted, .unknown:
                    return .init(phase: .running, transcript: accumulator.transcript, usage: usage)
                case .itemStarted, .itemUpdated, .message, .messageDelta,
                    .reasoningSummaryPartAdded, .reasoningDelta:
                    _ = accumulator.apply(event)
                    return .init(phase: .running, transcript: accumulator.transcript, usage: usage)
                case .itemCompleted(let item, let turnID):
                    _ = accumulator.apply(event)
                    if isTerminal(event) {
                        finished = true
                        let result = finalizedReviewExitResult(item: item, turnID: turnID)
                        return .init(
                            phase: .completed,
                            transcript: result.transcript,
                            usage: result.usage,
                            result: result
                        )
                    }
                    return .init(phase: .running, transcript: accumulator.transcript, usage: usage)
                case .tokenUsageUpdated(let newUsage, _):
                    usage = newUsage
                    return .init(phase: .running, transcript: accumulator.transcript, usage: usage)
                case .turnCompleted(var result):
                    guard isTerminal(event) else {
                        continue
                    }
                    finished = true
                    result = finalizedResult(result)
                    if result.errorMessage != nil || result.status?.isFailure == true {
                        return .init(
                            phase: .failed(.turnFailedWithResponse(result)),
                            transcript: result.transcript,
                            usage: result.usage,
                            result: result
                        )
                    }
                    return .init(
                        phase: .completed,
                        transcript: result.transcript,
                        usage: result.usage,
                        result: result
                    )
                case .turnFailed(_, let message):
                    guard isTerminal(event) else {
                        continue
                    }
                    finished = true
                    return .init(
                        phase: .failed(.turnFailed(message)),
                        transcript: accumulator.transcript,
                        usage: usage
                    )
                case .statusChanged:
                    return .init(phase: .running, transcript: accumulator.transcript, usage: usage)
                case .closed:
                    finished = true
                    return nil
                }
            }
            finished = true
            return nil
        }

        private func finalizedResult(_ result: CodexResponse) -> CodexResponse {
            var result = result
            if result.finalAnswer == nil {
                result.finalAnswer = accumulator.transcript.finalAnswer
            }
            if result.transcript.items.isEmpty {
                result.transcript = accumulator.transcript
            }
            if result.usage == nil {
                result.usage = usage
            }
            return result
        }

        private func finalizedReviewExitResult(
            item: CodexThreadItem,
            turnID: CodexTurnID?
        ) -> CodexResponse {
            CodexResponse(
                turnID: terminalTurnID ?? turnID ?? .init(rawValue: ""),
                status: .completed,
                finalAnswer: item.reviewExitResult ?? accumulator.transcript.finalAnswer,
                transcript: accumulator.transcript,
                usage: usage
            )
        }

        private func isTerminal(_ event: CodexThreadEvent) -> Bool {
            switch event {
            case .turnCompleted(let response):
                guard terminalTurnID.map({ response.turnID == $0 }) ?? true else {
                    return false
                }
                return response.shouldFinishReviewSequence
            case .turnFailed(let turnID, _):
                return terminalTurnID.map { turnID == $0 } ?? true
            case .itemCompleted(let item, let turnID):
                return item.finishesReviewMode && matchesTerminalTurn(turnID)
            case .closed:
                return true
            case .turnStarted, .itemStarted, .itemUpdated, .message, .messageDelta,
                .reasoningSummaryPartAdded, .reasoningDelta, .tokenUsageUpdated, .statusChanged,
                .unknown:
                return false
            }
        }

        private func matchesTerminalTurn(_ turnID: CodexTurnID?) -> Bool {
            terminalTurnID.map { turnID == $0 } ?? true
        }
    }
}

package struct CodexTurnEventSequence: AsyncSequence, Sendable {
    package typealias Element = CodexTurnEvent

    private let makeStream: @Sendable () -> AsyncThrowingStream<CodexTurnEvent, Error>

    package init(makeStream: @escaping @Sendable () -> AsyncThrowingStream<CodexTurnEvent, Error>) {
        self.makeStream = makeStream
    }

    package func makeAsyncIterator() -> AsyncThrowingStream<CodexTurnEvent, Error>.Iterator {
        makeStream().makeAsyncIterator()
    }
}

package struct CodexTurnProgressSequence: AsyncSequence, Sendable {
    package typealias Element = CodexTurnProgress

    private let events: CodexTurnEventSequence

    package init(events: CodexTurnEventSequence) {
        self.events = events
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator())
    }

    package struct Iterator: AsyncIteratorProtocol {
        private var events: AsyncThrowingStream<CodexTurnEvent, Error>.Iterator
        private var accumulator = CodexTranscriptAccumulator()
        private var usage: CodexTokenUsage?

        fileprivate init(events: AsyncThrowingStream<CodexTurnEvent, Error>.Iterator) {
            self.events = events
        }

        package mutating func next() async throws -> CodexTurnProgress? {
            guard let event = try await events.next() else {
                return nil
            }
            switch event {
            case .started, .unknown:
                return .init(phase: .running, transcript: accumulator.transcript)
            case .itemStarted, .itemUpdated, .itemCompleted, .messageDelta,
                .reasoningSummaryPartAdded, .reasoningDelta:
                _ = accumulator.apply(event)
                return .init(phase: .running, transcript: accumulator.transcript)
            case .tokenUsageUpdated(let newUsage):
                usage = newUsage
                return .init(phase: .running, transcript: accumulator.transcript)
            case .completed(var result):
                result = finalizedResult(result)
                if result.errorMessage != nil {
                    return .init(
                        phase: .failed(.turnFailedWithResponse(result)),
                        transcript: result.transcript,
                        result: result
                    )
                }
                if result.status?.isFailure == true {
                    return .init(
                        phase: .failed(.turnFailedWithResponse(result)),
                        transcript: result.transcript,
                        result: result
                    )
                }
                return .init(phase: .completed, transcript: result.transcript, result: result)
            case .failed(let message):
                return .init(
                    phase: .failed(.turnFailed(message)),
                    transcript: accumulator.transcript
                )
            }
        }

        private func finalizedResult(_ result: CodexResponse) -> CodexResponse {
            var result = result
            if result.finalAnswer == nil {
                result.finalAnswer = accumulator.transcript.finalAnswer
            }
            if result.transcript.items.isEmpty {
                result.transcript = accumulator.transcript
            }
            if result.usage == nil {
                result.usage = usage
            }
            return result
        }
    }
}

package struct CodexResponseCollector {
    static func collect(from events: CodexTurnEventSequence) async throws -> CodexResponse {
        var accumulator = CodexTranscriptAccumulator()
        var usage: CodexTokenUsage?
        for try await event in events {
            switch event {
            case .started, .unknown:
                continue
            case .itemStarted, .itemUpdated, .itemCompleted, .messageDelta,
                .reasoningSummaryPartAdded, .reasoningDelta:
                _ = accumulator.apply(event)
            case .tokenUsageUpdated(let newUsage):
                usage = newUsage
            case .completed(var result):
                if result.finalAnswer == nil {
                    result.finalAnswer = accumulator.transcript.finalAnswer
                }
                if result.transcript.items.isEmpty {
                    result.transcript = accumulator.transcript
                }
                if result.usage == nil {
                    result.usage = usage
                }
                if result.errorMessage != nil {
                    throw CodexAppServerError.turnFailedWithResponse(result)
                }
                if result.status?.isFailure == true {
                    throw CodexAppServerError.turnFailedWithResponse(result)
                }
                return result
            case .failed(let message):
                throw CodexAppServerError.turnFailed(message)
            }
        }
        throw CodexAppServerError.transportClosed
    }
}

private struct CodexTranscriptAccumulator {
    private var items: [CodexThreadItem] = []
    private var itemIndexesByID: [String: Int] = [:]
    private var messageDeltaTextByItemID: [String: String] = [:]
    private var reasoningDeltaTextByPartID: [String: String] = [:]

    var transcript: CodexTranscript {
        .init(items: items)
    }

    mutating func apply(_ event: CodexTurnEvent) -> Bool {
        switch event {
        case .itemStarted(let item), .itemUpdated(let item), .itemCompleted(let item):
            upsert(item)
            return true
        case .messageDelta(let delta):
            append(delta)
            return true
        case .reasoningSummaryPartAdded(let part):
            start(part)
            return true
        case .reasoningDelta(let delta):
            append(delta)
            return true
        case .started, .tokenUsageUpdated, .completed, .failed, .unknown:
            return false
        }
    }

    mutating func apply(_ event: CodexThreadEvent) -> Bool {
        switch event {
        case .itemStarted(let item, _), .itemUpdated(let item, _), .itemCompleted(let item, _):
            upsert(item)
            return true
        case .message(let message, _):
            upsert(
                .init(
                    id: message.id,
                    kind: message.role == .user ? .userMessage : .agentMessage,
                    content: .message(message)
                ))
            return true
        case .messageDelta(let delta, _):
            append(delta)
            return true
        case .reasoningSummaryPartAdded(let part, _):
            start(part)
            return true
        case .reasoningDelta(let delta, _):
            append(delta)
            return true
        case .turnStarted, .turnCompleted, .turnFailed, .tokenUsageUpdated, .statusChanged,
            .closed, .unknown:
            return false
        }
    }

    private mutating func upsert(_ item: CodexThreadItem) {
        if item.kind == .reasoning && item.id.contains(":summary:") == false
            && item.id.contains(":content:") == false
        {
            removeReasoningParts(parentItemID: item.id)
        }
        if let index = itemIndexesByID[item.id] {
            items[index] = item
        } else {
            itemIndexesByID[item.id] = items.count
            items.append(item)
        }
    }

    private mutating func append(_ delta: CodexMessageDelta) {
        let itemID = delta.itemID ?? "agent-message-delta"
        let text = (messageDeltaTextByItemID[itemID] ?? "") + delta.text
        messageDeltaTextByItemID[itemID] = text
        let message = CodexMessage(
            id: itemID,
            role: .assistant,
            phase: delta.phase,
            text: text
        )
        upsert(.init(id: itemID, kind: .agentMessage, content: .message(message)))
    }

    private mutating func start(_ part: CodexReasoningPart) {
        upsert(.init(
            id: part.id,
            kind: .reasoning,
            content: .reasoning(.empty)
        ))
    }

    private mutating func append(_ delta: CodexReasoningDelta) {
        let text = (reasoningDeltaTextByPartID[delta.id] ?? "") + delta.delta
        reasoningDeltaTextByPartID[delta.id] = text
        let reasoning: CodexReasoning
        switch delta.part.kind {
        case .summary:
            reasoning = .init(summary: text)
        case .text:
            reasoning = .init(content: text)
        }
        upsert(.init(id: delta.id, kind: .reasoning, content: .reasoning(reasoning)))
    }

    private mutating func removeReasoningParts(parentItemID: String) {
        let prefixes = ["\(parentItemID):summary:", "\(parentItemID):content:"]
        items.removeAll { item in
            prefixes.contains { item.id.hasPrefix($0) }
        }
        reasoningDeltaTextByPartID = reasoningDeltaTextByPartID.filter { id, _ in
            prefixes.contains { id.hasPrefix($0) } == false
        }
        itemIndexesByID = Dictionary(
            uniqueKeysWithValues: items.enumerated().map { index, item in (item.id, index) }
        )
    }
}

private extension CodexResponse {
    var shouldFinishReviewSequence: Bool {
        if errorMessage != nil || status?.isFailure == true {
            return true
        }
        if finalAnswer?.isEmpty == false
            || transcript.finalAnswer?.isEmpty == false
            || transcript.responseText?.isEmpty == false
        {
            return true
        }
        return false
    }
}
