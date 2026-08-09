import Foundation
import Synchronization

package enum TurnReplayPendingOperationKind: Equatable, Sendable {
    case turn(threadID: CodexThreadID)
    case review(sourceThreadID: CodexThreadID, delivery: CodexReviewDelivery)
}

package struct TurnReplayPendingToken: Hashable, Sendable {
    fileprivate let rawValue: UUID
    private let writePhase: TurnReplayPendingWritePhase

    package init() {
        self.rawValue = UUID()
        self.writePhase = TurnReplayPendingWritePhase()
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }

    package func acceptWrite() {
        writePhase.acceptWrite()
    }

    package func rejectAcceptedWrite() {
        writePhase.rejectAcceptedWrite()
    }

    package var isWriteAccepted: Bool {
        writePhase.isWriteAccepted
    }
}

private final class TurnReplayPendingWritePhase: Sendable {
    private let accepted = Mutex(false)

    var isWriteAccepted: Bool {
        accepted.withLock { $0 }
    }

    func acceptWrite() {
        accepted.withLock { accepted in
            precondition(
                accepted == false,
                "A turn operation attempt may accept its write exactly once."
            )
            accepted = true
        }
    }

    func rejectAcceptedWrite() {
        accepted.withLock { accepted in
            precondition(
                accepted,
                "Only a write-accepted turn operation attempt can be rejected."
            )
            accepted = false
        }
    }
}

package struct CompactTurnSnapshot: Equatable, Sendable {
    package let snapshot: CodexTurnSnapshot
    package let outcome: CodexTurnOutcome

    package init(snapshot: CodexTurnSnapshot, outcome: CodexTurnOutcome) {
        precondition(
            snapshot.id == outcome.response.turnID,
            "A compact turn snapshot and terminal outcome must identify the same turn."
        )
        precondition(
            snapshot.state.matches(outcome),
            "A compact turn snapshot and outcome must describe the same terminal state."
        )
        precondition(
            snapshot.items == outcome.response.transcript.items,
            "A compact turn snapshot and outcome must contain the same accumulated items."
        )
        self.snapshot = snapshot
        self.outcome = outcome
    }

    package var replayEvents: [CodexTurnEvent] {
        [.snapshot(snapshot), .terminal(outcome)]
    }
}

package struct TurnReplayEvents: AsyncSequence, Sendable {
    package typealias Element = CodexTurnEvent

    private let channel: TurnReplayEventSubscriberChannel
    private let cancellation: TurnReplaySubscriptionCancellation<TurnReplayEventSubscriberChannel>

    fileprivate init(
        channel: TurnReplayEventSubscriberChannel,
        cancellation: TurnReplaySubscriptionCancellation<TurnReplayEventSubscriberChannel>
    ) {
        self.channel = channel
        self.cancellation = cancellation
    }

    package func makeAsyncIterator() -> Iterator {
        .init(channel: channel, cancellation: cancellation)
    }

    package func cancel() {
        cancellation.cancel()
    }

    package static func replaying(_ compactSnapshot: CompactTurnSnapshot) -> Self {
        let registry = TurnReplaySubscriptionRegistry<TurnReplayEventSubscriberChannel>()
        let subscription = registry.makeSubscription {
            TurnReplayEventSubscriberChannel()
        }
        registry.finish { channel in
            channel.finish(with: compactSnapshot)
        }
        return .init(
            channel: subscription.channel,
            cancellation: subscription.cancellation
        )
    }

    package static func failing(_ error: CodexAppServerError) -> Self {
        let registry = TurnReplaySubscriptionRegistry<TurnReplayEventSubscriberChannel>()
        let subscription = registry.makeSubscription {
            TurnReplayEventSubscriberChannel()
        }
        registry.finish { channel in
            channel.finish(throwing: error)
        }
        return .init(
            channel: subscription.channel,
            cancellation: subscription.cancellation
        )
    }

    package struct Iterator: AsyncIteratorProtocol {
        private let channel: TurnReplayEventSubscriberChannel
        private let cancellation: TurnReplaySubscriptionCancellation<TurnReplayEventSubscriberChannel>

        fileprivate init(
            channel: TurnReplayEventSubscriberChannel,
            cancellation: TurnReplaySubscriptionCancellation<TurnReplayEventSubscriberChannel>
        ) {
            self.channel = channel
            self.cancellation = cancellation
        }

        package mutating func next() async throws -> CodexTurnEvent? {
            try await channel.next(cancellation: cancellation)
        }
    }
}

package struct TurnReplayProgressEvents: AsyncSequence, Sendable {
    package typealias Element = CodexReviewProgress

    private let channel: TurnReplayProgressSubscriberChannel
    private let cancellation: TurnReplaySubscriptionCancellation<TurnReplayProgressSubscriberChannel>

    fileprivate init(
        channel: TurnReplayProgressSubscriberChannel,
        cancellation: TurnReplaySubscriptionCancellation<TurnReplayProgressSubscriberChannel>
    ) {
        self.channel = channel
        self.cancellation = cancellation
    }

    package func makeAsyncIterator() -> Iterator {
        .init(channel: channel, cancellation: cancellation)
    }

    package func cancel() {
        cancellation.cancel()
    }

    package static func replaying(_ compactSnapshot: CompactTurnSnapshot) -> Self {
        let registry = TurnReplaySubscriptionRegistry<TurnReplayProgressSubscriberChannel>()
        let subscription = registry.makeSubscription {
            TurnReplayProgressSubscriberChannel()
        }
        registry.finish { channel in
            channel.finish(with: compactSnapshot.outcome)
        }
        return .init(
            channel: subscription.channel,
            cancellation: subscription.cancellation
        )
    }

    package static func failing(_ error: CodexAppServerError) -> Self {
        let registry = TurnReplaySubscriptionRegistry<TurnReplayProgressSubscriberChannel>()
        let subscription = registry.makeSubscription {
            TurnReplayProgressSubscriberChannel()
        }
        registry.finish { channel in
            channel.finish(throwing: error)
        }
        return .init(
            channel: subscription.channel,
            cancellation: subscription.cancellation
        )
    }

    package struct Iterator: AsyncIteratorProtocol {
        private let channel: TurnReplayProgressSubscriberChannel
        private let cancellation: TurnReplaySubscriptionCancellation<TurnReplayProgressSubscriberChannel>

        fileprivate init(
            channel: TurnReplayProgressSubscriberChannel,
            cancellation: TurnReplaySubscriptionCancellation<TurnReplayProgressSubscriberChannel>
        ) {
            self.channel = channel
            self.cancellation = cancellation
        }

        package mutating func next() async throws -> CodexReviewProgress? {
            try await channel.next(cancellation: cancellation)
        }
    }
}

package final class TurnReplayRelay: Sendable {
    package struct Snapshot: Equatable, Sendable {
        package var subscriberCount: Int
        package var overflowCount: Int
        package var isFinished: Bool
    }

    private let eventRegistry = TurnReplaySubscriptionRegistry<TurnReplayEventSubscriberChannel>()
    private let progressRegistry = TurnReplaySubscriptionRegistry<TurnReplayProgressSubscriberChannel>()

    package init() {}

    deinit {
        eventRegistry.cancelAll()
        progressRegistry.cancelAll()
    }

    package func events(initialSnapshot: CodexTurnSnapshot? = nil) -> TurnReplayEvents {
        events(initialSnapshot: initialSnapshot, beforePublication: {})
    }

    package func eventsForTesting(
        initialSnapshot: CodexTurnSnapshot,
        beforePublication: @escaping @Sendable () -> Void
    ) -> TurnReplayEvents {
        events(
            initialSnapshot: initialSnapshot,
            beforePublication: beforePublication
        )
    }

    private func events(
        initialSnapshot: CodexTurnSnapshot?,
        beforePublication: @escaping @Sendable () -> Void
    ) -> TurnReplayEvents {
        let subscription = eventRegistry.makeSubscription(
            makeChannel: { TurnReplayEventSubscriberChannel() },
            prepareForPublication: { channel in
                beforePublication()
                if let initialSnapshot {
                    channel.yield(
                        .snapshot(initialSnapshot),
                        accumulatedSnapshot: initialSnapshot
                    )
                }
            }
        )
        return .init(channel: subscription.channel, cancellation: subscription.cancellation)
    }

    package func progressEvents(
        initialProgress: CodexReviewProgress? = nil
    ) -> TurnReplayProgressEvents {
        progressEvents(initialProgress: initialProgress, beforePublication: {})
    }

    package func progressEventsForTesting(
        initialProgress: CodexReviewProgress,
        beforePublication: @escaping @Sendable () -> Void
    ) -> TurnReplayProgressEvents {
        progressEvents(
            initialProgress: initialProgress,
            beforePublication: beforePublication
        )
    }

    private func progressEvents(
        initialProgress: CodexReviewProgress?,
        beforePublication: @escaping @Sendable () -> Void
    ) -> TurnReplayProgressEvents {
        let subscription = progressRegistry.makeSubscription(
            makeChannel: { TurnReplayProgressSubscriberChannel() },
            prepareForPublication: { channel in
                beforePublication()
                if let initialProgress {
                    channel.yield(initialProgress)
                }
            }
        )
        return .init(channel: subscription.channel, cancellation: subscription.cancellation)
    }

    @discardableResult
    package func yield(
        _ event: CodexTurnEvent,
        accumulatedSnapshot: CodexTurnSnapshot
    ) -> Int {
        precondition(
            event.isTerminal == false,
            "Turn replay terminal delivery must use finish(with:)."
        )
        return eventRegistry.yield { (channel: TurnReplayEventSubscriberChannel) in
            channel.yield(event, accumulatedSnapshot: accumulatedSnapshot)
        }
    }

    package func yieldProgress(_ progress: CodexReviewProgress) {
        precondition(
            progress.isTerminal == false,
            "Turn replay terminal progress delivery must use finish(with:)."
        )
        _ = progressRegistry.yield { (channel: TurnReplayProgressSubscriberChannel) in
            channel.yield(progress)
        }
    }

    package func finish(with compactSnapshot: CompactTurnSnapshot) {
        eventRegistry.finish { (channel: TurnReplayEventSubscriberChannel) in
            channel.finish(with: compactSnapshot)
        }
        progressRegistry.finish { (channel: TurnReplayProgressSubscriberChannel) in
            channel.finish(with: compactSnapshot.outcome)
        }
    }

    package func finish(throwing error: CodexAppServerError) {
        eventRegistry.finish { (channel: TurnReplayEventSubscriberChannel) in
            channel.finish(throwing: error)
        }
        progressRegistry.finish { (channel: TurnReplayProgressSubscriberChannel) in
            channel.finish(throwing: error)
        }
    }

    package func snapshotForTesting() -> Snapshot {
        let eventSnapshot = eventRegistry.snapshot()
        return .init(
            subscriberCount: eventSnapshot.subscriberCount,
            overflowCount: eventSnapshot.overflowCount,
            isFinished: eventSnapshot.isFinished
        )
    }
}

private protocol TurnReplaySubscriberChannel: AnyObject, Sendable {
    associatedtype Element: Sendable

    func cancel()
    func overflowCountForTesting() -> Int
}

private final class TurnReplayEventSubscriberChannel: TurnReplaySubscriberChannel {
    typealias Element = CodexTurnEvent

    private enum Phase {
        case open
        case finishing
        case failed(CodexAppServerError)
        case finished
        case cancelled
    }

    private struct State {
        var pending: [CodexTurnEvent] = []
        var waiter: CheckedContinuation<CodexTurnEvent?, Error>?
        var phase = Phase.open
        var nextIsActive = false
        var overflowCount = 0
    }

    private static let incrementalCapacity = 256
    private let state = Mutex(State())

    func yield(_ event: CodexTurnEvent, accumulatedSnapshot: CodexTurnSnapshot) {
        let waiter = state.withLock { state -> CheckedContinuation<CodexTurnEvent?, Error>? in
            guard case .open = state.phase else {
                return nil
            }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            if case .snapshot = event {
                state.pending = [event]
                return nil
            }
            let snapshotPrefixCount = state.pending.first?.isSnapshot == true ? 1 : 0
            let pendingIncrementalCount = state.pending.count - snapshotPrefixCount
            if pendingIncrementalCount == Self.incrementalCapacity {
                state.pending = [.snapshot(accumulatedSnapshot)]
                state.overflowCount += 1
                return nil
            }
            state.pending.append(event)
            return nil
        }
        waiter?.resume(returning: event)
    }

    func finish(with compactSnapshot: CompactTurnSnapshot) {
        let waiter = state.withLock { state -> CheckedContinuation<CodexTurnEvent?, Error>? in
            switch state.phase {
            case .open:
                state.pending = compactSnapshot.replayEvents
                state.phase = .finishing
                let waiter = state.waiter
                state.waiter = nil
                if waiter != nil {
                    state.pending.removeFirst()
                }
                return waiter
            case .finishing, .finished:
                return nil
            case .failed(let existing):
                preconditionFailure(
                    "A failed turn replay subscriber cannot finish successfully: \(existing)."
                )
            case .cancelled:
                return nil
            }
        }
        waiter?.resume(returning: compactSnapshot.replayEvents[0])
    }

    func finish(throwing error: CodexAppServerError) {
        let waiter = state.withLock { state -> CheckedContinuation<CodexTurnEvent?, Error>? in
            switch state.phase {
            case .open:
                state.pending.removeAll(keepingCapacity: false)
                state.phase = .failed(error)
                let waiter = state.waiter
                state.waiter = nil
                return waiter
            case .failed(let existing):
                precondition(existing == error, "A turn replay failure cannot be replaced.")
                return nil
            case .finishing, .finished:
                preconditionFailure("A terminal turn replay cannot fail afterward.")
            case .cancelled:
                return nil
            }
        }
        waiter?.resume(throwing: error)
    }

    func next(
        cancellation: TurnReplaySubscriptionCancellation<TurnReplayEventSubscriberChannel>
    ) async throws -> CodexTurnEvent? {
        precondition(tryBeginNext(), "TurnReplayEvents supports one in-flight next() call.")
        defer { endNext() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate = state.withLock { state -> Result<CodexTurnEvent?, Error>? in
                    if state.pending.isEmpty == false {
                        let event = state.pending.removeFirst()
                        if state.pending.isEmpty, case .finishing = state.phase {
                            state.phase = .finished
                        }
                        return .success(event)
                    }
                    switch state.phase {
                    case .open:
                        precondition(state.waiter == nil)
                        state.waiter = continuation
                        return nil
                    case .failed(let error):
                        state.phase = .finished
                        return .failure(error)
                    case .finishing, .finished:
                        state.phase = .finished
                        return .success(nil)
                    case .cancelled:
                        return .success(nil)
                    }
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func cancel() {
        let waiter = state.withLock { state -> CheckedContinuation<CodexTurnEvent?, Error>? in
            guard case .cancelled = state.phase else {
                if case .finished = state.phase {
                    return nil
                }
                state.phase = .cancelled
                state.pending.removeAll(keepingCapacity: false)
                let waiter = state.waiter
                state.waiter = nil
                return waiter
            }
            return nil
        }
        waiter?.resume(returning: nil)
    }

    func overflowCountForTesting() -> Int {
        state.withLock { $0.overflowCount }
    }

    private func tryBeginNext() -> Bool {
        state.withLock { state in
            guard state.nextIsActive == false else {
                return false
            }
            state.nextIsActive = true
            return true
        }
    }

    private func endNext() {
        state.withLock { state in
            precondition(state.nextIsActive)
            state.nextIsActive = false
        }
    }
}

private final class TurnReplayProgressSubscriberChannel: TurnReplaySubscriberChannel {
    typealias Element = CodexReviewProgress

    private enum Phase {
        case open
        case terminalPending(CodexTurnOutcome)
        case failed(CodexAppServerError)
        case finished
        case cancelled
    }

    private struct State {
        var newestProgress: CodexReviewProgress?
        var waiter: CheckedContinuation<CodexReviewProgress?, Error>?
        var phase = Phase.open
        var nextIsActive = false
    }

    private let state = Mutex(State())

    func yield(_ progress: CodexReviewProgress) {
        let waiter = state.withLock { state -> CheckedContinuation<CodexReviewProgress?, Error>? in
            guard case .open = state.phase else {
                return nil
            }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.newestProgress = progress
            return nil
        }
        waiter?.resume(returning: progress)
    }

    func finish(with outcome: CodexTurnOutcome) {
        let waiter = state.withLock { state -> CheckedContinuation<CodexReviewProgress?, Error>? in
            switch state.phase {
            case .open:
                state.phase = .terminalPending(outcome)
                guard state.newestProgress == nil else {
                    return nil
                }
                let waiter = state.waiter
                state.waiter = nil
                if waiter != nil {
                    state.phase = .finished
                }
                return waiter
            case .terminalPending(let existing):
                precondition(existing == outcome, "Turn progress terminal cannot be replaced.")
                return nil
            case .failed(let existing):
                preconditionFailure(
                    "A failed turn progress subscriber cannot finish successfully: \(existing)."
                )
            case .finished, .cancelled:
                return nil
            }
        }
        waiter?.resume(returning: .terminal(outcome))
    }

    func finish(throwing error: CodexAppServerError) {
        let waiter = state.withLock { state -> CheckedContinuation<CodexReviewProgress?, Error>? in
            switch state.phase {
            case .open:
                state.newestProgress = nil
                state.phase = .failed(error)
                let waiter = state.waiter
                state.waiter = nil
                return waiter
            case .failed(let existing):
                precondition(existing == error, "A turn progress failure cannot be replaced.")
                return nil
            case .terminalPending, .finished:
                preconditionFailure("Terminal turn progress cannot fail afterward.")
            case .cancelled:
                return nil
            }
        }
        waiter?.resume(throwing: error)
    }

    func next(
        cancellation: TurnReplaySubscriptionCancellation<TurnReplayProgressSubscriberChannel>
    ) async throws -> CodexReviewProgress? {
        precondition(
            tryBeginNext(),
            "TurnReplayProgressEvents supports one in-flight next() call."
        )
        defer { endNext() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate = state.withLock { state -> Result<CodexReviewProgress?, Error>? in
                    if let progress = state.newestProgress {
                        state.newestProgress = nil
                        return .success(progress)
                    }
                    switch state.phase {
                    case .open:
                        precondition(state.waiter == nil)
                        state.waiter = continuation
                        return nil
                    case .terminalPending(let outcome):
                        state.phase = .finished
                        return .success(.terminal(outcome))
                    case .failed(let error):
                        state.phase = .finished
                        return .failure(error)
                    case .finished, .cancelled:
                        return .success(nil)
                    }
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func cancel() {
        let waiter = state.withLock { state -> CheckedContinuation<CodexReviewProgress?, Error>? in
            guard case .cancelled = state.phase else {
                if case .finished = state.phase {
                    return nil
                }
                state.phase = .cancelled
                state.newestProgress = nil
                let waiter = state.waiter
                state.waiter = nil
                return waiter
            }
            return nil
        }
        waiter?.resume(returning: nil)
    }

    func overflowCountForTesting() -> Int { 0 }

    private func tryBeginNext() -> Bool {
        state.withLock { state in
            guard state.nextIsActive == false else {
                return false
            }
            state.nextIsActive = true
            return true
        }
    }

    private func endNext() {
        state.withLock { state in
            precondition(state.nextIsActive)
            state.nextIsActive = false
        }
    }
}

private final class TurnReplaySubscriptionCancellation<Channel: TurnReplaySubscriberChannel>: Sendable {
    private struct State {
        var isCancelled = false
    }

    private let state = Mutex(State())
    private let id: UUID
    private let registry: TurnReplaySubscriptionRegistry<Channel>

    init(id: UUID, registry: TurnReplaySubscriptionRegistry<Channel>) {
        self.id = id
        self.registry = registry
    }

    func cancel() {
        let shouldRemove = state.withLock { state in
            guard state.isCancelled == false else {
                return false
            }
            state.isCancelled = true
            return true
        }
        if shouldRemove {
            registry.remove(id)
        }
    }

    deinit {
        cancel()
    }
}

private final class TurnReplaySubscriptionRegistry<Channel: TurnReplaySubscriberChannel>: Sendable {
    private struct State {
        var channels: [UUID: Channel] = [:]
        var isFinished = false
    }

    struct Subscription {
        var channel: Channel
        var cancellation: TurnReplaySubscriptionCancellation<Channel>
    }

    struct Snapshot {
        var subscriberCount: Int
        var overflowCount: Int
        var isFinished: Bool
    }

    private let state = Mutex(State())
    // `remove` and `cancelAll` must never acquire `delivery`: channel completion can wait on a
    // subscriber task-status lock while that lock runs its cancellation handler back into remove.
    private let delivery = Mutex(())

    func makeSubscription(
        makeChannel: () -> Channel,
        prepareForPublication: (Channel) -> Void = { _ in }
    ) -> Subscription {
        let id = UUID()
        let channel = makeChannel()
        let cancellation = TurnReplaySubscriptionCancellation(id: id, registry: self)
        delivery.withLock { _ in
            precondition(
                state.withLock { $0.isFinished == false },
                "Late replay must come from handle state."
            )
            prepareForPublication(channel)
            state.withLock { state in
                precondition(
                    state.isFinished == false,
                    "A serialized replay publication cannot overtake finish."
                )
                state.channels[id] = channel
            }
        }
        return .init(channel: channel, cancellation: cancellation)
    }

    @discardableResult
    func yield(
        _ body: (Channel) -> Void
    ) -> Int {
        delivery.withLock { _ in
            let channels = state.withLock { state -> [Channel] in
                guard state.isFinished == false else {
                    return []
                }
                return Array(state.channels.values)
            }
            var overflows = 0
            for channel in channels {
                let before = channel.overflowCountForTesting()
                body(channel)
                overflows += channel.overflowCountForTesting() - before
            }
            return overflows
        }
    }

    func remove(_ id: UUID) {
        let channel = state.withLock { $0.channels.removeValue(forKey: id) }
        channel?.cancel()
    }

    func finish(
        _ body: (Channel) -> Void
    ) {
        delivery.withLock { _ in
            let channels = state.withLock { state -> [Channel] in
                guard state.isFinished == false else {
                    return []
                }
                state.isFinished = true
                let channels = Array(state.channels.values)
                state.channels.removeAll(keepingCapacity: false)
                return channels
            }
            for channel in channels {
                body(channel)
            }
        }
    }

    func cancelAll() {
        let channels = state.withLock { state -> [Channel] in
            let channels = Array(state.channels.values)
            state.channels.removeAll(keepingCapacity: false)
            return channels
        }
        for channel in channels {
            channel.cancel()
        }
    }

    func snapshot() -> Snapshot {
        let captured = state.withLock { state in
            (channels: Array(state.channels.values), isFinished: state.isFinished)
        }
        return .init(
            subscriberCount: captured.channels.count,
            overflowCount: captured.channels.reduce(0) {
                $0 + $1.overflowCountForTesting()
            },
            isFinished: captured.isFinished
        )
    }
}

private extension CodexTurnSnapshot.State {
    func matches(_ outcome: CodexTurnOutcome) -> Bool {
        switch (self, outcome) {
        case (.completed, .completed), (.interrupted, .interrupted):
            true
        case (.failed(let snapshotError), .failed(let failedTurn)):
            snapshotError == failedTurn.error
        case (
            .unknown(let snapshotRawValue, let snapshotError),
            .invalidTerminalStatus(let outcomeRawValue, let outcomeError, _)
        ):
            snapshotRawValue == outcomeRawValue && snapshotError == outcomeError
        case (.inProgress, _), (.completed, _), (.interrupted, _), (.failed, _), (.unknown, _):
            false
        }
    }
}

private extension CodexTurnEvent {
    var isTerminal: Bool {
        if case .terminal = self {
            return true
        }
        return false
    }

    var isSnapshot: Bool {
        if case .snapshot = self {
            return true
        }
        return false
    }
}

private extension CodexReviewProgress {
    var isTerminal: Bool {
        if case .terminal = self {
            return true
        }
        return false
    }
}
