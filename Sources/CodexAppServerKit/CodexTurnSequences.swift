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
                case .itemStarted(let item, _), .itemUpdated(let item, _),
                    .itemCompleted(let item, _):
                    if let message = item.message {
                        return message
                    }
                case .messageDelta(let delta, _):
                    return .init(
                        id: delta.itemID ?? UUID().uuidString,
                        role: .assistant,
                        phase: delta.phase,
                        text: delta.text
                    )
                case .turnStarted, .turnCompleted, .turnFailed, .tokenUsageUpdated,
                    .statusChanged, .closed, .unknown:
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

        fileprivate init(events: AsyncThrowingStream<CodexThreadEvent, Error>.Iterator) {
            self.events = events
        }

        public mutating func next() async throws -> CodexThreadLogEntry? {
            while let event = try await events.next() {
                switch event {
                case .itemStarted(let item, let turnID):
                    return .init(id: item.id, turnID: turnID, phase: .started, item: item)
                case .itemUpdated(let item, let turnID):
                    return .init(id: item.id, turnID: turnID, phase: .updated, item: item)
                case .itemCompleted(let item, let turnID):
                    return .init(id: item.id, turnID: turnID, phase: .completed, item: item)
                case .message(let message, let turnID):
                    let item = CodexThreadItem(
                        id: message.id,
                        kind: message.role == .user ? .userMessage : .agentMessage,
                        content: .message(message)
                    )
                    return .init(id: message.id, turnID: turnID, phase: .completed, item: item)
                case .messageDelta(let delta, let turnID):
                    return .init(
                        id: delta.itemID ?? UUID().uuidString,
                        turnID: turnID,
                        phase: .delta,
                        messageDelta: delta
                    )
                case .turnStarted, .turnCompleted, .turnFailed, .tokenUsageUpdated,
                    .statusChanged, .closed, .unknown:
                    continue
                }
            }
            return nil
        }
    }
}

public struct CodexTurnEventSequence: AsyncSequence, Sendable {
    public typealias Element = CodexTurnEvent

    private let makeStream: @Sendable () -> AsyncThrowingStream<CodexTurnEvent, Error>

    package init(makeStream: @escaping @Sendable () -> AsyncThrowingStream<CodexTurnEvent, Error>) {
        self.makeStream = makeStream
    }

    public func makeAsyncIterator() -> AsyncThrowingStream<CodexTurnEvent, Error>.Iterator {
        makeStream().makeAsyncIterator()
    }
}

public struct CodexTurnProgressSequence: AsyncSequence, Sendable {
    public typealias Element = CodexTurnProgress

    private let events: CodexTurnEventSequence

    package init(events: CodexTurnEventSequence) {
        self.events = events
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(events: events.makeAsyncIterator())
    }

    public struct Iterator: AsyncIteratorProtocol {
        private var events: AsyncThrowingStream<CodexTurnEvent, Error>.Iterator
        private var accumulator = CodexTranscriptAccumulator()
        private var usage: CodexTokenUsage?

        fileprivate init(events: AsyncThrowingStream<CodexTurnEvent, Error>.Iterator) {
            self.events = events
        }

        public mutating func next() async throws -> CodexTurnProgress? {
            guard let event = try await events.next() else {
                return nil
            }
            switch event {
            case .started, .unknown:
                return .init(phase: .running, transcript: accumulator.transcript)
            case .itemStarted, .itemUpdated, .itemCompleted, .messageDelta:
                _ = accumulator.apply(event)
                return .init(phase: .running, transcript: accumulator.transcript)
            case .tokenUsageUpdated(let newUsage):
                usage = newUsage
                return .init(phase: .running, transcript: accumulator.transcript)
            case .completed(var result):
                result = finalizedResult(result)
                if let errorMessage = result.errorMessage {
                    return .init(
                        phase: .failed(.turnFailed(errorMessage)),
                        transcript: result.transcript,
                        result: result
                    )
                }
                if result.status?.isFailure == true {
                    return .init(
                        phase: .failed(.turnFailed(result.status?.rawValue ?? "Turn failed.")),
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

        private func finalizedResult(_ result: CodexTurnResult) -> CodexTurnResult {
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

package struct CodexTurnResultCollector {
    static func collect(from events: CodexTurnEventSequence) async throws -> CodexTurnResult {
        var accumulator = CodexTranscriptAccumulator()
        var usage: CodexTokenUsage?
        for try await event in events {
            switch event {
            case .started, .unknown:
                continue
            case .itemStarted, .itemUpdated, .itemCompleted, .messageDelta:
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
                if let message = result.errorMessage {
                    throw CodexAppServerError.turnFailed(message)
                }
                if result.status?.isFailure == true {
                    throw CodexAppServerError.turnFailed(result.status?.rawValue ?? "Turn failed.")
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
        case .turnStarted, .turnCompleted, .turnFailed, .tokenUsageUpdated, .statusChanged,
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
}
