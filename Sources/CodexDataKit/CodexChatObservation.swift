import CodexAppServerKit
import Foundation
import Synchronization

public enum CodexChatSnapshotReason: Equatable, Sendable {
    case initial
    case refresh
    case includeTurnsUpgrade
    case generationRestart
    case bufferOverflow
    case upstreamFailure
}

public struct CodexChatObservationSnapshot: Equatable, Sendable {
    public var thread: CodexThreadSnapshot
    public var phase: CodexChatPhase

    public init(thread: CodexThreadSnapshot, phase: CodexChatPhase) {
        self.thread = thread
        self.phase = phase
    }
}

public struct CodexChatObservationEvent: Equatable, Sendable {
    public enum Payload: Equatable, Sendable {
        case snapshot(CodexChatObservationSnapshot, reason: CodexChatSnapshotReason)
        case update(CodexChatUpdate)
    }

    public let generation: UInt64
    public let sequence: UInt64
    public let payload: Payload

    public init(generation: UInt64, sequence: UInt64, payload: Payload) {
        self.generation = generation
        self.sequence = sequence
        self.payload = payload
    }
}

public struct CodexChatUpdates: AsyncSequence, Sendable {
    public typealias Element = CodexChatObservationEvent

    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let channel: CodexChatObservationChannel

        public mutating func next() async -> CodexChatObservationEvent? {
            await channel.next()
        }
    }

    private let channel: CodexChatObservationChannel
    private let iteratorClaim: CodexChatObservationIteratorClaim

    package init(channel: CodexChatObservationChannel) {
        self.channel = channel
        self.iteratorClaim = CodexChatObservationIteratorClaim()
    }

    public func makeAsyncIterator() -> AsyncIterator {
        precondition(
            iteratorClaim.claim(),
            "CodexChatUpdates supports exactly one iterator; call observe() for another subscriber."
        )
        return AsyncIterator(channel: channel)
    }
}

public final class CodexChatObservation {
    public let chat: CodexChat
    public let updates: CodexChatUpdates

    private enum CloseState {
        case open
        case closing([CheckedContinuation<Void, Never>])
        case closed
    }

    private let leaseID: UUID
    // The stream must not outlive the context that applies its events.
    private let modelContext: CodexModelContext
    private let releaseSignal: ChatObservationReleaseSignal
    private let closeState = Mutex<CloseState>(.open)

    package init(
        chat: CodexChat,
        updates: CodexChatUpdates,
        leaseID: UUID,
        modelContext: CodexModelContext,
        releaseSignal: ChatObservationReleaseSignal
    ) {
        self.chat = chat
        self.updates = updates
        self.leaseID = leaseID
        self.modelContext = modelContext
        self.releaseSignal = releaseSignal
    }

    public nonisolated(nonsending) func close() async {
        let ownsRelease = closeState.withLock { state in
            guard case .open = state else { return false }
            state = .closing([])
            return true
        }
        guard ownsRelease else {
            await waitUntilClosed()
            return
        }
        let acknowledgement = ChatObservationReleaseAcknowledgement()
        releaseSignal.release(leaseID, acknowledgement: acknowledgement)
        await acknowledgement.wait()
        let waiters = closeState.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard case .closing(let waiters) = state else {
                preconditionFailure("Observation close owner lost its close state.")
            }
            state = .closed
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    package func cancel() {
        let shouldRelease = closeState.withLock { state in
            guard case .open = state else { return false }
            state = .closed
            return true
        }
        guard shouldRelease else { return }
        releaseSignal.release(leaseID)
    }

    package var releaseSignalForTesting: ChatObservationReleaseSignal {
        releaseSignal
    }

    deinit {
        let shouldRelease = closeState.withLock { state in
            guard case .open = state else { return false }
            state = .closed
            return true
        }
        if shouldRelease {
            releaseSignal.release(leaseID)
        }
    }

    private func waitUntilClosed() async {
        await withCheckedContinuation { continuation in
            let isClosed = closeState.withLock { state in
                switch state {
                case .open:
                    preconditionFailure("A close waiter requires an active close owner.")
                case .closing(var waiters):
                    waiters.append(continuation)
                    state = .closing(waiters)
                    return false
                case .closed:
                    return true
                }
            }
            if isClosed {
                continuation.resume()
            }
        }
    }
}

package final class ChatObservationReleaseAcknowledgement: Sendable {
    private enum State {
        case pending(CheckedContinuation<Void, Never>?)
        case completed
    }

    private let state = Mutex<State>(.pending(nil))

    package init() {}

    package func wait() async {
        await withCheckedContinuation { continuation in
            let isCompleted = state.withLock { state in
                switch state {
                case .pending(nil):
                    state = .pending(continuation)
                    return false
                case .pending(.some):
                    preconditionFailure("Observation release acknowledgement has one waiter.")
                case .completed:
                    return true
                }
            }
            if isCompleted {
                continuation.resume()
            }
        }
    }

    package func complete() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            switch state {
            case .pending(let continuation):
                state = .completed
                return continuation
            case .completed:
                return nil
            }
        }
        continuation?.resume()
    }

    package func isCompletedForTesting() -> Bool {
        state.withLock { state in
            if case .completed = state { return true }
            return false
        }
    }
}

package final class ChatObservationStartWaiter: Sendable {
    private enum State {
        case pending(CheckedContinuation<Void, any Error>?)
        case resolved(cancelled: Bool)
    }

    private let state = Mutex<State>(.pending(nil))

    package init() {}

    package func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock { state -> Bool? in
                    switch state {
                    case .pending(nil):
                        state = .pending(continuation)
                        return nil
                    case .pending(.some):
                        preconditionFailure("Observation start waiter supports one caller.")
                    case .resolved(let cancelled):
                        return cancelled
                    }
                }
                if let cancelled = result {
                    if cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            resolve(cancelled: true)
        }
    }

    package func resolve(cancelled: Bool) {
        let continuation = state.withLock {
            state -> CheckedContinuation<Void, any Error>? in
            switch state {
            case .pending(let continuation):
                state = .resolved(cancelled: cancelled)
                return continuation
            case .resolved:
                return nil
            }
        }
        if cancelled {
            continuation?.resume(throwing: CancellationError())
        } else {
            continuation?.resume()
        }
    }
}

package final class ChatObservationStartOperation<Output: Sendable>: Sendable {
    private let task: Task<Output, any Error>
    private let completion: ChatObservationStartCompletion<Output>
    private let completionTask: Task<Void, Never>

    package init(
        operation: sending @escaping @isolated(any) @Sendable () async throws -> Output
    ) {
        let task = Task(operation: operation)
        let completion = ChatObservationStartCompletion<Output>()
        self.task = task
        self.completion = completion
        completionTask = Task { [task, completion] in
            do {
                completion.resolve(.success(try await task.value))
            } catch {
                completion.resolve(.failure(error))
            }
        }
    }

    package func value() async throws -> Output {
        try await completion.value()
    }

    package func cancel() {
        task.cancel()
    }

    package func cancelAndWait() async {
        task.cancel()
        await completionTask.value
    }
}

private final class ChatObservationStartCompletion<Output: Sendable>: Sendable {
    private enum State: Sendable {
        case pending([ChatObservationStartValueWaiter<Output>])
        case completed(Result<Output, any Error>)
    }

    private let state = Mutex<State>(.pending([]))

    func value() async throws -> Output {
        let waiter = ChatObservationStartValueWaiter<Output>()
        let result = state.withLock { state -> Result<Output, any Error>? in
            switch state {
            case .pending(var waiters):
                waiters.append(waiter)
                state = .pending(waiters)
                return nil
            case .completed(let result):
                return result
            }
        }
        if let result {
            waiter.resolve(result)
        }
        return try await waiter.value()
    }

    func resolve(_ result: Result<Output, any Error>) {
        let waiters = state.withLock { state -> [ChatObservationStartValueWaiter<Output>] in
            switch state {
            case .pending(let waiters):
                state = .completed(result)
                return waiters
            case .completed:
                return []
            }
        }
        for waiter in waiters {
            waiter.resolve(result)
        }
    }
}

private final class ChatObservationStartValueWaiter<Output: Sendable>: Sendable {
    private enum State: Sendable {
        case pending(CheckedContinuation<Output, any Error>?)
        case resolved(Result<Output, any Error>)
    }

    private let state = Mutex<State>(.pending(nil))

    func value() async throws -> Output {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock { state -> Result<Output, any Error>? in
                    switch state {
                    case .pending(nil):
                        state = .pending(continuation)
                        return nil
                    case .pending(.some):
                        preconditionFailure("Observation start value supports one waiter.")
                    case .resolved(let result):
                        return result
                    }
                }
                if let result {
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            resolve(.failure(CancellationError()))
        }
    }

    func resolve(_ result: Result<Output, any Error>) {
        let continuation = state.withLock {
            state -> CheckedContinuation<Output, any Error>? in
            switch state {
            case .pending(let continuation):
                state = .resolved(result)
                return continuation
            case .resolved:
                return nil
            }
        }
        continuation?.resume(with: result)
    }
}

package struct ChatObservationRelease: Sendable {
    package let leaseID: UUID
}

package final class ChatObservationReleaseSignal: Sendable {
    private struct State {
        var pending: [ChatObservationRelease] = []
        var waiter: CheckedContinuation<ChatObservationRelease?, Never>?
        var releasedLeaseIDs: Set<UUID> = []
        var acknowledgementsByLeaseID: [UUID: [ChatObservationReleaseAcknowledgement]] = [:]
        var receiverIsActive = false
        var isTerminated = false
        var receiverDidComplete = false
    }

    private let state = Mutex(State())

    package init() {}

    package func release(
        _ leaseID: UUID,
        acknowledgement: ChatObservationReleaseAcknowledgement? = nil
    ) {
        let action = state.withLock { state -> (
            CheckedContinuation<ChatObservationRelease?, Never>?,
            Bool,
            Bool
        ) in
            guard state.isTerminated == false else {
                return (nil, true, false)
            }
            if state.releasedLeaseIDs.contains(leaseID) {
                guard var acknowledgements = state.acknowledgementsByLeaseID[leaseID] else {
                    return (nil, true, false)
                }
                if let acknowledgement {
                    acknowledgements.append(acknowledgement)
                    state.acknowledgementsByLeaseID[leaseID] = acknowledgements
                }
                return (nil, false, false)
            }
            state.releasedLeaseIDs.insert(leaseID)
            state.acknowledgementsByLeaseID[leaseID] = acknowledgement.map { [$0] } ?? []
            let release = ChatObservationRelease(leaseID: leaseID)
            if let waiter = state.waiter {
                state.waiter = nil
                return (waiter, false, true)
            }
            state.pending.append(release)
            return (nil, false, true)
        }
        if action.1 {
            acknowledgement?.complete()
        } else if action.2 {
            action.0?.resume(returning: .init(leaseID: leaseID))
        }
    }

    package func acknowledge(_ leaseID: UUID) {
        let acknowledgements = state.withLock { state in
            state.acknowledgementsByLeaseID.removeValue(forKey: leaseID) ?? []
        }
        for acknowledgement in acknowledgements {
            acknowledgement.complete()
        }
    }

    package func next() async -> ChatObservationRelease? {
        precondition(beginReceive(), "Observation release signal supports one receiver.")
        defer { endReceive() }
        return await withCheckedContinuation { continuation in
            let immediate = state.withLock { state -> ChatObservationRelease?? in
                if state.pending.isEmpty == false {
                    return .some(state.pending.removeFirst())
                }
                if state.isTerminated {
                    return .some(nil)
                }
                precondition(state.waiter == nil)
                state.waiter = continuation
                return nil
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
    }

    package func terminate() {
        let waiter = state.withLock { state -> CheckedContinuation<ChatObservationRelease?, Never>? in
            guard state.isTerminated == false else {
                return nil
            }
            state.isTerminated = true
            state.pending.removeAll(keepingCapacity: false)
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume(returning: nil)
    }

    package func completeAllAcknowledgements() {
        let acknowledgements = state.withLock { state in
            let acknowledgements = state.acknowledgementsByLeaseID.values.flatMap { $0 }
            state.acknowledgementsByLeaseID.removeAll(keepingCapacity: false)
            state.receiverDidComplete = true
            return acknowledgements
        }
        for acknowledgement in acknowledgements {
            acknowledgement.complete()
        }
    }

    package func releasedLeaseCountForTesting() -> Int {
        state.withLock { $0.releasedLeaseIDs.count }
    }

    package func receiverDidCompleteForTesting() -> Bool {
        state.withLock { $0.receiverDidComplete }
    }

    private func beginReceive() -> Bool {
        state.withLock { state in
            guard state.receiverIsActive == false else { return false }
            state.receiverIsActive = true
            return true
        }
    }

    private func endReceive() {
        state.withLock { state in
            precondition(state.receiverIsActive)
            state.receiverIsActive = false
        }
    }
}

private final class CodexChatObservationIteratorClaim: Sendable {
    private let claimed = Mutex(false)

    func claim() -> Bool {
        claimed.withLock { claimed in
            guard claimed == false else {
                return false
            }
            claimed = true
            return true
        }
    }
}

package final class CodexChatObservationChannel: Sendable {
    private enum Phase: Sendable {
        case open
        case finishing
        case finished
        case cancelled
    }

    private struct State: Sendable {
        var pending: [CodexChatObservationEvent] = []
        var waiter: CheckedContinuation<CodexChatObservationEvent?, Never>?
        var phase = Phase.open
        var nextIsActive = false
        var overflowCount = 0
        var latestAcceptedCursor: (generation: UInt64, sequence: UInt64)?
        var didSendCancellation = false
    }

    package static let capacity = 256
    private let state = Mutex(State())
    private let releaseSignal: ChatObservationReleaseSignal?
    private let leaseID: UUID?

    package init(
        releaseSignal: ChatObservationReleaseSignal? = nil,
        leaseID: UUID? = nil
    ) {
        precondition((releaseSignal == nil) == (leaseID == nil))
        self.releaseSignal = releaseSignal
        self.leaseID = leaseID
    }

    package func yield(
        _ event: CodexChatObservationEvent,
        overflowSnapshot: CodexChatObservationEvent
    ) {
        yield([event], overflowSnapshot: overflowSnapshot)
    }

    package func yield(
        _ events: [CodexChatObservationEvent],
        overflowSnapshot: CodexChatObservationEvent
    ) {
        guard events.isEmpty == false else { return }
        let delivery = state.withLock { state -> (
            CheckedContinuation<CodexChatObservationEvent?, Never>?,
            CodexChatObservationEvent?
        ) in
            guard case .open = state.phase else {
                return (nil, nil)
            }
            for event in events {
                Self.accept(event, state: &state)
            }
            if let waiter = state.waiter {
                state.waiter = nil
                Self.enqueue(
                    Array(events.dropFirst()),
                    overflowSnapshot: overflowSnapshot,
                    state: &state
                )
                return (waiter, events[0])
            }
            Self.enqueue(events, overflowSnapshot: overflowSnapshot, state: &state)
            return (nil, nil)
        }
        delivery.0?.resume(returning: delivery.1)
    }

    package func seed(_ event: CodexChatObservationEvent) {
        state.withLock { state in
            precondition(state.pending.isEmpty && state.waiter == nil)
            guard case .open = state.phase else {
                return
            }
            Self.accept(event, state: &state)
            state.pending = [event]
        }
    }

    package func supersedeAndFinish(with event: CodexChatObservationEvent) {
        let delivery = state.withLock { state -> CheckedContinuation<CodexChatObservationEvent?, Never>? in
            guard case .open = state.phase else {
                return nil
            }
            Self.accept(event, state: &state)
            guard case .snapshot = event.payload else {
                preconditionFailure("A terminal observation event must be a complete snapshot.")
            }
            state.pending = [event]
            state.phase = .finishing
            let waiter = state.waiter
            state.waiter = nil
            if waiter != nil {
                state.pending.removeFirst()
            }
            return waiter
        }
        delivery?.resume(returning: event)
    }

    package func finish() {
        let waiter = state.withLock { state -> CheckedContinuation<CodexChatObservationEvent?, Never>? in
            switch state.phase {
            case .open:
                state.phase = state.pending.isEmpty ? .finished : .finishing
                let waiter = state.waiter
                state.waiter = nil
                return waiter
            case .finishing, .finished, .cancelled:
                return nil
            }
        }
        waiter?.resume(returning: nil)
    }

    package func cancel() {
        let action = state.withLock { state -> (
            CheckedContinuation<CodexChatObservationEvent?, Never>?,
            Bool
        ) in
            guard case .finished = state.phase else {
                state.phase = .cancelled
                state.pending.removeAll(keepingCapacity: false)
                let waiter = state.waiter
                state.waiter = nil
                let shouldRelease = state.didSendCancellation == false
                state.didSendCancellation = true
                return (waiter, shouldRelease)
            }
            return (nil, false)
        }
        action.0?.resume(returning: nil)
        if action.1, let releaseSignal, let leaseID {
            releaseSignal.release(leaseID)
        }
    }

    fileprivate func next() async -> CodexChatObservationEvent? {
        precondition(beginNext(), "CodexChatUpdates supports one in-flight next() call.")
        defer { endNext() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate = state.withLock { state -> CodexChatObservationEvent?? in
                    if state.pending.isEmpty == false {
                        let event = state.pending.removeFirst()
                        if state.pending.isEmpty, case .finishing = state.phase {
                            state.phase = .finished
                        }
                        return .some(.some(event))
                    }
                    switch state.phase {
                    case .open:
                        precondition(state.waiter == nil)
                        state.waiter = continuation
                        return nil
                    case .finishing, .finished, .cancelled:
                        state.phase = .finished
                        return .some(nil)
                    }
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: {
            cancel()
        }
    }

    package func overflowCountForTesting() -> Int {
        state.withLock(\.overflowCount)
    }

    private func beginNext() -> Bool {
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

    private static func accept(
        _ event: CodexChatObservationEvent,
        state: inout State
    ) {
        defer {
            state.latestAcceptedCursor = (event.generation, event.sequence)
        }
        guard let latest = state.latestAcceptedCursor else {
            guard case .snapshot = event.payload else {
                preconditionFailure("The first observation event must be a snapshot.")
            }
            return
        }
        if event.generation > latest.generation {
            guard event.sequence == 0, case .snapshot = event.payload else {
                preconditionFailure("A new observation generation must start with sequence zero snapshot.")
            }
            return
        }
        precondition(
            event.generation == latest.generation,
            "Observation events cannot return to an older generation."
        )
        switch event.payload {
        case .snapshot:
            precondition(
                event.sequence >= latest.sequence,
                "Observation snapshots cannot move their cursor backwards."
            )
        case .update:
            precondition(
                event.sequence == latest.sequence &+ 1,
                "Observation updates must advance the cursor by exactly one."
            )
        }
    }

    private static func compactPending(
        with snapshot: CodexChatObservationEvent,
        state: inout State
    ) {
        guard let first = state.pending.first else {
            state.pending = [snapshot]
            return
        }
        if snapshot.generation > first.generation {
            state.pending = [snapshot]
            return
        }
        precondition(snapshot.generation == first.generation)
        state.pending.removeAll {
            $0.generation < snapshot.generation
                || ($0.generation == snapshot.generation
                    && $0.sequence <= snapshot.sequence)
        }
        state.pending.insert(snapshot, at: 0)
    }

    private static func enqueue(
        _ events: [CodexChatObservationEvent],
        overflowSnapshot: CodexChatObservationEvent,
        state: inout State
    ) {
        guard events.isEmpty == false else { return }
        for event in events {
            if case .snapshot = event.payload {
                compactPending(with: event, state: &state)
            } else if state.pending.count == capacity {
                guard let finalEvent = events.last else {
                    preconditionFailure("A non-empty observation batch requires a final event.")
                }
                precondition(
                    overflowSnapshot.generation == finalEvent.generation
                        && overflowSnapshot.sequence == finalEvent.sequence
                )
                guard case .snapshot(_, reason: .bufferOverflow) = overflowSnapshot.payload else {
                    preconditionFailure("Overflow compaction requires a buffer-overflow snapshot.")
                }
                state.pending = [overflowSnapshot]
                state.overflowCount += 1
                return
            } else {
                state.pending.append(event)
            }
        }
    }
}
