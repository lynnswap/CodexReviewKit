import Foundation
import Synchronization

package struct ThreadEventGenerationCheckpoint: Sendable {
    fileprivate let identity: ThreadEventGenerationCheckpointIdentity
}

package enum ThreadEventGenerationOperation: Equatable, Sendable {
    case standard
    case reviewStart(delivery: CodexReviewDelivery)
}

package enum ThreadEventTurnStartDisposition: Equatable, Sendable {
    case route
    case suppress
    case deferUntilOwned
}

package struct CodexThreadEventSequence: AsyncSequence, Sendable {
    package typealias Element = CodexThreadEvent

    private let channel: ThreadEventSubscriberChannel
    private let cancellation: ThreadEventSubscriptionCancellation

    fileprivate init(
        channel: ThreadEventSubscriberChannel,
        cancellation: ThreadEventSubscriptionCancellation
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

    package struct Iterator: AsyncIteratorProtocol {
        private let channel: ThreadEventSubscriberChannel
        private let cancellation: ThreadEventSubscriptionCancellation

        fileprivate init(
            channel: ThreadEventSubscriberChannel,
            cancellation: ThreadEventSubscriptionCancellation
        ) {
            self.channel = channel
            self.cancellation = cancellation
        }

        package mutating func next() async throws -> CodexThreadEvent? {
            try await channel.next(cancellation: cancellation)
        }
    }
}

package final class ThreadEventHub: Sendable {
    package struct Snapshot: Equatable, Sendable {
        package var subscriberCount: Int
        package var pendingCheckpointCount: Int
        package var hasActiveCheckpoint: Bool
        package var hasCurrentGeneration: Bool
        package var currentTurnID: CodexTurnID?
        package var currentEventCount: Int
        package var overflowCount: Int
        package var isClosed: Bool
        package var failure: CodexAppServerError?
        package var threadStateCount: Int
    }

    private enum Phase: Sendable {
        case open
        case failed(CodexAppServerError)
    }

    private struct ThreadState: Sendable {
        var current: ThreadEventGeneration?
        var activeCheckpointID: UUID?
        var subscribers: [UUID: ThreadEventSubscriberChannel] = [:]
        var isClosed = false
        var publicationRevision: UInt64 = 0
    }

    private struct CheckpointRecord: Sendable {
        var identity: ThreadEventGenerationCheckpointIdentity
        var threadID: CodexThreadID
        var operation: ThreadEventGenerationOperation
        var generation: ThreadEventGeneration?
    }

    private struct State: Sendable {
        var phase = Phase.open
        var threads: [CodexThreadID: ThreadState] = [:]
        var checkpoints: [UUID: CheckpointRecord] = [:]
    }

    private let state = Mutex(State())
    // `removeSubscriber` and deinit cancellation must never acquire `delivery`: channel
    // completion can wait on a task-status lock while its cancellation handler removes here.
    private let delivery = Mutex(())

    package init() {}

    deinit {
        let channels = state.withLock { state in
            let channels = state.threads.values.flatMap { $0.subscribers.values }
            state.threads.removeAll(keepingCapacity: false)
            state.checkpoints.removeAll(keepingCapacity: false)
            return channels
        }
        for channel in channels {
            channel.cancel()
        }
    }

    package func registerCheckpoint(
        for threadID: CodexThreadID,
        operation: ThreadEventGenerationOperation = .standard
    ) throws -> ThreadEventGenerationCheckpoint {
        let identity = ThreadEventGenerationCheckpointIdentity()
        try state.withLock { state in
            if case .failed(let error) = state.phase {
                throw error
            }
            state.checkpoints[identity.id] = .init(
                identity: identity,
                threadID: threadID,
                operation: operation,
                generation: nil
            )
        }
        return .init(identity: identity)
    }

    package func turnStartDisposition(for threadID: CodexThreadID) -> ThreadEventTurnStartDisposition {
        state.withLock { state in
            if let checkpointID = state.threads[threadID]?.activeCheckpointID,
               let checkpoint = state.checkpoints[checkpointID] {
                if case .reviewStart(let delivery) = checkpoint.operation {
                    return delivery == .inline ? .suppress : .route
                }
                return .route
            }
            return .deferUntilOwned
        }
    }

    package func activate(_ checkpoint: ThreadEventGenerationCheckpoint) {
        state.withLock { state in
            guard var record = state.checkpoints[checkpoint.identity.id] else {
                switch checkpoint.identity.phase {
                case .committed, .connectionTerminated:
                    return
                case .inactive, .active, .discarded:
                    preconditionFailure("Only a registered generation checkpoint can be activated.")
                }
            }
            precondition(record.identity === checkpoint.identity)
            var thread = state.threads[record.threadID] ?? .init()
            switch checkpoint.identity.phase {
            case .inactive:
                precondition(
                    thread.activeCheckpointID == nil,
                    "A thread can have at most one active generation checkpoint."
                )
                checkpoint.identity.phase = .active
                thread.activeCheckpointID = checkpoint.identity.id
                record.generation = .init()
                state.checkpoints[checkpoint.identity.id] = record
                state.threads[record.threadID] = thread
            case .active:
                precondition(
                    thread.activeCheckpointID == checkpoint.identity.id,
                    "An active checkpoint must own the thread's active attempt."
                )
            case .committed:
                break
            case .connectionTerminated:
                break
            case .discarded:
                preconditionFailure("A discarded generation checkpoint cannot be activated.")
            }
        }
    }

    package func seed(
        _ snapshot: CodexTurnSnapshot,
        at checkpoint: ThreadEventGenerationCheckpoint
    ) throws {
        try state.withLock { state in
            guard var record = state.checkpoints[checkpoint.identity.id] else {
                if checkpoint.identity.phase == .connectionTerminated {
                    return
                }
                preconditionFailure("Only a registered generation checkpoint can be seeded.")
            }
            precondition(record.identity === checkpoint.identity)
            precondition(
                checkpoint.identity.phase == .active,
                "A generation checkpoint must be active when its response snapshot is seeded."
            )
            var generation = record.generation ?? .init()
            try generation.mergeResponseSnapshot(snapshot)
            record.generation = generation
            state.checkpoints[checkpoint.identity.id] = record
        }
    }

    package func seedProvisionalResumeSnapshot(
        _ snapshot: CodexTurnSnapshot,
        at checkpoint: ThreadEventGenerationCheckpoint
    ) {
        state.withLock { state in
            guard var record = state.checkpoints[checkpoint.identity.id] else {
                if checkpoint.identity.phase == .connectionTerminated {
                    return
                }
                preconditionFailure("Only a registered generation checkpoint can be seeded.")
            }
            precondition(record.identity === checkpoint.identity)
            precondition(
                checkpoint.identity.phase == .active,
                "A generation checkpoint must be active when its response snapshot is seeded."
            )
            var generation = record.generation ?? .init()
            generation.mergeProvisionalResumeSnapshot(snapshot)
            record.generation = generation
            state.checkpoints[checkpoint.identity.id] = record
        }
    }

    package func resolveReviewStart(
        _ checkpoint: ThreadEventGenerationCheckpoint,
        eventThreadID: CodexThreadID,
        responseSnapshot: CodexTurnSnapshot
    ) throws {
        var publication: ThreadEventPublication?
        try state.withLock { state in
            guard let record = state.checkpoints[checkpoint.identity.id] else {
                preconditionFailure("Only an active review checkpoint can resolve a response.")
            }
            precondition(record.identity === checkpoint.identity)
            precondition(
                checkpoint.identity.phase == .active,
                "A review checkpoint must remain active until its response identity resolves."
            )
            guard case .reviewStart(let delivery) = record.operation else {
                preconditionFailure("Only review/start may move its event generation.")
            }

            switch delivery {
            case .inline:
                guard eventThreadID == record.threadID else {
                    throw CodexTransportFailure.contractViolation(
                        message: "An inline review cannot move to another event thread."
                    )
                }
            case .detached:
                guard eventThreadID != record.threadID else {
                    throw CodexTransportFailure.contractViolation(
                        message: "A detached review must use a different event thread."
                    )
                }
                guard state.threads[eventThreadID] == nil else {
                    throw CodexTransportFailure.contractViolation(
                        message: "A detached review must use a previously unseen event thread."
                    )
                }
            }

            var sourceThread = state.threads[record.threadID] ?? .init()
            precondition(sourceThread.activeCheckpointID == checkpoint.identity.id)
            sourceThread.activeCheckpointID = nil

            var generation = record.generation ?? .init()
            try generation.mergeResponseSnapshot(responseSnapshot)
            checkpoint.identity.phase = .committed
            state.checkpoints.removeValue(forKey: checkpoint.identity.id)

            var eventThread: ThreadState
            if eventThreadID == record.threadID {
                eventThread = sourceThread
            } else {
                store(sourceThread, for: record.threadID, in: &state)
                eventThread = state.threads[eventThreadID] ?? .init()
                precondition(
                    eventThread.activeCheckpointID == nil,
                    "A detached review cannot replace an active event-thread request."
                )
            }
            eventThread.current = generation
            eventThread.isClosed = generation.isClosed
            let revision = nextPublicationRevision(for: &eventThread)
            if generation.isClosed {
                let channels = Array(eventThread.subscribers.values)
                eventThread.subscribers.removeAll(keepingCapacity: false)
                publication = .finish(channels, generation.replayEvents, revision)
            } else {
                publication = .supersede(
                    Array(eventThread.subscribers.values),
                    generation.replayEvents,
                    revision,
                    resetsGeneration: true
                )
            }
            state.threads[eventThreadID] = eventThread
        }
        _ = deliver(publication)
    }

    package func reject(_ checkpoint: ThreadEventGenerationCheckpoint) {
        state.withLock { state in
            guard var record = state.checkpoints[checkpoint.identity.id] else {
                switch checkpoint.identity.phase {
                case .committed, .connectionTerminated:
                    return
                case .inactive, .active, .discarded:
                    preconditionFailure("Only an active generation checkpoint can reject an attempt.")
                }
            }
            precondition(record.identity === checkpoint.identity)
            var thread = state.threads[record.threadID] ?? .init()
            switch checkpoint.identity.phase {
            case .active:
                precondition(thread.activeCheckpointID == checkpoint.identity.id)
                checkpoint.identity.phase = .inactive
                thread.activeCheckpointID = nil
                record.generation = nil
                state.checkpoints[checkpoint.identity.id] = record
                store(thread, for: record.threadID, in: &state)
            case .inactive:
                precondition(record.generation == nil)
            case .committed:
                break
            case .connectionTerminated:
                break
            case .discarded:
                preconditionFailure("A discarded generation checkpoint cannot reject an attempt.")
            }
        }
    }

    package func commit(_ checkpoint: ThreadEventGenerationCheckpoint) {
        commit(checkpoint, beforeDelivery: {})
    }

    package func commitForTesting(
        _ checkpoint: ThreadEventGenerationCheckpoint,
        beforeDelivery: @escaping @Sendable () -> Void
    ) {
        commit(checkpoint, beforeDelivery: beforeDelivery)
    }

    private func commit(
        _ checkpoint: ThreadEventGenerationCheckpoint,
        beforeDelivery: @escaping @Sendable () -> Void
    ) {
        var publication: ThreadEventPublication?
        state.withLock { state in
            guard let record = state.checkpoints[checkpoint.identity.id] else {
                switch checkpoint.identity.phase {
                case .committed, .connectionTerminated:
                    return
                case .inactive, .active, .discarded:
                    preconditionFailure("Only an active generation checkpoint can be committed.")
                }
            }
            precondition(record.identity === checkpoint.identity)
            precondition(
                checkpoint.identity.phase == .active,
                "A generation checkpoint must be active when its response commits."
            )
            var thread = state.threads[record.threadID] ?? .init()
            precondition(thread.activeCheckpointID == checkpoint.identity.id)
            let generation = record.generation ?? .init()
            checkpoint.identity.phase = .committed
            thread.activeCheckpointID = nil
            thread.current = generation
            thread.isClosed = generation.isClosed
            let revision = nextPublicationRevision(for: &thread)
            state.checkpoints.removeValue(forKey: checkpoint.identity.id)
            if generation.isClosed {
                let channels = Array(thread.subscribers.values)
                thread.subscribers.removeAll(keepingCapacity: false)
                publication = .finish(channels, generation.replayEvents, revision)
            } else {
                publication = .supersede(
                    Array(thread.subscribers.values),
                    generation.replayEvents,
                    revision,
                    resetsGeneration: true
                )
            }
            state.threads[record.threadID] = thread
        }
        beforeDelivery()
        _ = deliver(publication)
    }

    package func discard(_ checkpoint: ThreadEventGenerationCheckpoint) {
        state.withLock { state in
            guard let record = state.checkpoints[checkpoint.identity.id] else {
                precondition(
                    checkpoint.identity.phase == .committed
                        || checkpoint.identity.phase == .discarded
                        || checkpoint.identity.phase == .connectionTerminated,
                    "An unknown generation checkpoint cannot be discarded."
                )
                return
            }
            precondition(record.identity === checkpoint.identity)
            var thread = state.threads[record.threadID] ?? .init()
            if thread.activeCheckpointID == checkpoint.identity.id {
                thread.activeCheckpointID = nil
            }
            checkpoint.identity.phase = .discarded
            state.checkpoints.removeValue(forKey: checkpoint.identity.id)
            store(thread, for: record.threadID, in: &state)
        }
    }

    package func resetGeneration(for threadID: CodexThreadID) {
        var publication: ThreadEventPublication?
        state.withLock { state in
            guard case .open = state.phase else {
                return
            }
            var thread = state.threads[threadID] ?? .init()
            precondition(
                thread.activeCheckpointID == nil,
                "A current generation cannot reset during an active request attempt."
            )
            thread.current = .init()
            thread.isClosed = false
            let revision = nextPublicationRevision(for: &thread)
            publication = .supersede(
                Array(thread.subscribers.values),
                [],
                revision,
                resetsGeneration: true
            )
            state.threads[threadID] = thread
        }
        _ = deliver(publication)
    }

    package func beginGeneration(
        for threadID: CodexThreadID,
        including turnID: CodexTurnID
    ) {
        var publication: ThreadEventPublication?
        state.withLock { state in
            guard case .open = state.phase else {
                return
            }
            var thread = state.threads[threadID] ?? .init()
            if thread.current?.turnID == turnID {
                state.threads[threadID] = thread
                return
            }

            let matches = state.checkpoints.values.filter {
                $0.threadID == threadID && $0.generation?.turnID == turnID
            }
            precondition(
                matches.count <= 1,
                "A detached turn can match at most one provisional thread generation."
            )
            if let match = matches.first {
                match.identity.phase = .committed
                state.checkpoints.removeValue(forKey: match.identity.id)
                if thread.activeCheckpointID == match.identity.id {
                    thread.activeCheckpointID = nil
                }
                thread.current = match.generation
            } else if var current = thread.current,
                      current.hasProvisionalResumeSnapshot {
                current.adoptProvisionalResumeIdentity(turnID)
                thread.current = current
            } else {
                thread.current = .init(expectedTurnID: turnID)
            }
            thread.isClosed = false
            let revision = nextPublicationRevision(for: &thread)
            publication = .supersede(
                Array(thread.subscribers.values),
                thread.current?.replayEvents ?? [],
                revision,
                resetsGeneration: true
            )
            state.threads[threadID] = thread
        }
        _ = deliver(publication)
    }

    package func seedCurrentTurnSnapshot(
        _ snapshot: CodexTurnSnapshot,
        for threadID: CodexThreadID
    ) {
        var publication: ThreadEventPublication?
        state.withLock { state in
            guard case .open = state.phase else {
                return
            }
            var thread = state.threads[threadID] ?? .init()
            guard thread.activeCheckpointID == nil else {
                return
            }
            let resetsGeneration: Bool
            var generation: ThreadEventGeneration
            if let current = thread.current {
                if current.turnID == nil, current.hasProvisionalResumeSnapshot == false {
                    generation = current
                    resetsGeneration = true
                } else if current.turnID == snapshot.id {
                    generation = current
                    resetsGeneration = false
                } else {
                    guard current.isSupersededByHistoricalTurn(snapshot.id) else {
                        return
                    }
                    generation = .init()
                    resetsGeneration = true
                }
            } else {
                generation = .init()
                resetsGeneration = true
            }
            do {
                try generation.mergeHistoricalSnapshot(snapshot)
            } catch {
                preconditionFailure(
                    "A matching current turn snapshot must merge into its generation: \(error)"
                )
            }
            thread.current = generation
            thread.isClosed = generation.isClosed
            let revision = nextPublicationRevision(for: &thread)
            publication = .supersede(
                Array(thread.subscribers.values),
                generation.replayEvents,
                revision,
                resetsGeneration: resetsGeneration
            )
            state.threads[threadID] = thread
        }
        _ = deliver(publication)
    }

    package func events(for threadID: CodexThreadID) -> CodexThreadEventSequence {
        events(for: threadID, beforePublication: {})
    }

    package func eventsForTesting(
        for threadID: CodexThreadID,
        beforePublication: @escaping @Sendable () -> Void
    ) -> CodexThreadEventSequence {
        events(for: threadID, beforePublication: beforePublication)
    }

    private func events(
        for threadID: CodexThreadID,
        beforePublication: @escaping @Sendable () -> Void
    ) -> CodexThreadEventSequence {
        let subscriptionID = UUID()
        let channel = ThreadEventSubscriberChannel()
        let cancellation = ThreadEventSubscriptionCancellation(
            id: subscriptionID,
            threadID: threadID,
            hub: self,
            channel: channel
        )
        beforePublication()
        delivery.withLock { _ in
            let publication = state.withLock { state -> ThreadEventInitialPublication in
                switch state.phase {
                case .failed(let error):
                    return .fail(error)
                case .open:
                    var thread = state.threads[threadID] ?? .init()
                    if thread.isClosed {
                        return .finish(
                            thread.current?.replayEvents ?? [.closed],
                            thread.publicationRevision
                        )
                    } else {
                        let publication = ThreadEventInitialPublication.supersede(
                            thread.current?.replayEvents ?? [],
                            thread.publicationRevision
                        )
                        thread.subscribers[subscriptionID] = channel
                        state.threads[threadID] = thread
                        return publication
                    }
                }
            }
            publication.deliver(to: channel)
        }
        return .init(channel: channel, cancellation: cancellation)
    }

    @discardableResult
    package func route(
        _ event: CodexThreadEvent,
        for threadID: CodexThreadID
    ) throws -> Int {
        let publication = try state.withLock { state -> ThreadEventPublication? in
            if case .failed(let error) = state.phase {
                throw error
            }
            var thread = state.threads[threadID] ?? .init()
            if thread.isClosed {
                if case .closed = event {
                    return nil
                }
            }

            if let activeID = thread.activeCheckpointID {
                guard var record = state.checkpoints[activeID] else {
                    preconditionFailure("An active thread checkpoint lost its registration.")
                }
                // A detached review is required to run on a fresh response-identified thread.
                // Explicit source-thread notifications therefore stay on the source generation;
                // moving them with the request checkpoint would corrupt both thread histories.
                if record.operation != .reviewStart(delivery: .detached) {
                    var generation = record.generation ?? .init()
                    _ = try generation.apply(event)
                    record.generation = generation
                    state.checkpoints[activeID] = record
                    state.threads[threadID] = thread
                    return nil
                }
            }

            let eventTurnID = Self.turnID(of: event)
            let shouldRollGeneration = thread.isClosed
                || thread.current?.isSupersededByObservedTurn(eventTurnID) == true
                || (
                    thread.current?.hasTerminal == true
                        && eventTurnID != nil
                        && eventTurnID != thread.current?.turnID
            )
            var generation = shouldRollGeneration ? .init() : (thread.current ?? .init())
            let priorTurnID = generation.turnID
            let disposition = try generation.apply(event)
            guard disposition == .accepted else {
                thread.current = generation
                state.threads[threadID] = thread
                return nil
            }
            thread.current = generation
            thread.isClosed = generation.isClosed
            let didEstablishTurn = priorTurnID == nil && generation.turnID != nil
            let channels = Array(thread.subscribers.values)
            let revision = nextPublicationRevision(for: &thread)
            let publication: ThreadEventPublication
            switch event {
            case .terminal:
                publication = .supersede(
                    channels,
                    generation.replayEvents,
                    revision,
                    resetsGeneration: shouldRollGeneration || didEstablishTurn
                )
            case .closed:
                thread.subscribers.removeAll(keepingCapacity: false)
                publication = .finish(channels, generation.replayEvents, revision)
            case .turnStarted, .snapshot, .itemStarted, .itemUpdated, .itemCompleted,
                .message, .messageDelta, .reasoningSummaryPartAdded, .reasoningDelta,
                .diagnostic, .tokenUsageUpdated, .statusChanged, .unknown:
                if shouldRollGeneration || didEstablishTurn {
                    publication = .supersede(
                        channels,
                        generation.replayEvents,
                        revision,
                        resetsGeneration: true
                    )
                } else {
                    publication = .yield(
                        channels,
                        event,
                        generation.compactEvents,
                        revision
                    )
                }
            }
            state.threads[threadID] = thread
            return publication
        }
        return deliver(publication)
    }

    package func finish(throwing error: CodexAppServerError) {
        let channels = state.withLock { state -> [ThreadEventSubscriberChannel] in
            switch state.phase {
            case .open:
                state.phase = .failed(error)
            case .failed(let existing):
                precondition(existing == error, "A thread event hub failure cannot be replaced.")
                return []
            }
            for record in state.checkpoints.values {
                record.identity.phase = .connectionTerminated
            }
            state.checkpoints.removeAll(keepingCapacity: false)
            let channels = state.threads.values.flatMap { $0.subscribers.values }
            state.threads.removeAll(keepingCapacity: false)
            return channels
        }
        delivery.withLock { _ in
            for channel in channels {
                channel.fail(error)
            }
        }
    }

    package func snapshotForTesting(threadID: CodexThreadID) -> Snapshot {
        let captured = state.withLock { state -> (
            snapshot: Snapshot,
            subscribers: [ThreadEventSubscriberChannel]
        ) in
            let thread = state.threads[threadID]
            let failure: CodexAppServerError?
            switch state.phase {
            case .open:
                failure = nil
            case .failed(let error):
                failure = error
            }
            let subscribers = thread.map { Array($0.subscribers.values) } ?? []
            return (
                snapshot: .init(
                    subscriberCount: subscribers.count,
                    pendingCheckpointCount: state.checkpoints.values.filter {
                        $0.threadID == threadID
                    }.count,
                    hasActiveCheckpoint: thread?.activeCheckpointID != nil,
                    hasCurrentGeneration: thread?.current != nil,
                    currentTurnID: thread?.current?.turnID,
                    currentEventCount: thread?.current?.replayEvents.count ?? 0,
                    overflowCount: 0,
                    isClosed: thread?.isClosed ?? false,
                    failure: failure,
                    threadStateCount: state.threads.count
                ),
                subscribers: subscribers
            )
        }
        var snapshot = captured.snapshot
        snapshot.overflowCount = captured.subscribers.reduce(0) {
            $0 + $1.overflowCountForTesting()
        }
        return snapshot
    }

    fileprivate func removeSubscriber(_ id: UUID, threadID: CodexThreadID) {
        state.withLock { state in
            guard var thread = state.threads[threadID] else {
                return
            }
            thread.subscribers.removeValue(forKey: id)
            store(thread, for: threadID, in: &state)
        }
    }

    private func nextPublicationRevision(for thread: inout ThreadState) -> UInt64 {
        thread.publicationRevision &+= 1
        return thread.publicationRevision
    }

    private func deliver(_ publication: ThreadEventPublication?) -> Int {
        guard let publication else {
            return 0
        }
        return delivery.withLock { _ in
            publication.deliver()
        }
    }

    private func store(
        _ thread: ThreadState,
        for threadID: CodexThreadID,
        in state: inout State
    ) {
        if thread.current == nil,
           thread.activeCheckpointID == nil,
           thread.subscribers.isEmpty,
           thread.isClosed == false
        {
            state.threads.removeValue(forKey: threadID)
        } else {
            state.threads[threadID] = thread
        }
    }

    private static func turnID(of event: CodexThreadEvent) -> CodexTurnID? {
        switch event {
        case .turnStarted(let turnID):
            turnID
        case .snapshot(let snapshot):
            snapshot.id
        case .terminal(let outcome):
            outcome.response.turnID
        case .itemStarted(_, let turnID), .itemUpdated(_, let turnID),
             .itemCompleted(_, let turnID), .message(_, let turnID),
             .messageDelta(_, let turnID), .reasoningSummaryPartAdded(_, let turnID),
             .reasoningDelta(_, let turnID), .tokenUsageUpdated(_, let turnID):
            turnID
        case .diagnostic(_, let turnID):
            turnID
        case .unknown(let raw):
            raw.turnID
        case .statusChanged, .closed:
            nil
        }
    }
}

private final class ThreadEventGenerationCheckpointIdentity: Sendable {
    enum Phase: Equatable, Sendable {
        case inactive
        case active
        case committed
        case connectionTerminated
        case discarded
    }

    let id = UUID()
    private let state = Mutex(Phase.inactive)

    var phase: Phase {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

private struct ThreadEventGeneration: Equatable, Sendable {
    enum ApplyDisposition: Equatable, Sendable {
        case accepted
        case duplicate
    }

    private static let compactCapacity = 256
    private static let compactTailCapacity = compactCapacity - 3
    private static let postTerminalTailCapacity = compactCapacity - 1

    private var snapshotReducer: CodexTurnSnapshotReducer?
    private var latestUsage: CodexTokenUsage?
    private var latestStatus: CodexThreadStatus?
    private var compactTail: [CodexThreadEvent] = []
    private var postTerminalTail: [CodexThreadEvent] = []
    private var terminal: CodexTurnOutcome?
    private var provisionalResumeSnapshot: CodexTurnSnapshot?
    private var isHistoricalSnapshotOnly = false
    private(set) var isClosed = false

    init(expectedTurnID: CodexTurnID? = nil) {
        if let expectedTurnID {
            snapshotReducer = .init(turnID: expectedTurnID)
        }
    }

    var turnID: CodexTurnID? {
        snapshotReducer?.snapshot.id
    }

    private var snapshot: CodexTurnSnapshot? {
        snapshotReducer?.snapshot
    }

    var hasTerminal: Bool {
        if terminal != nil {
            return true
        }
        switch snapshot?.state {
        case .completed, .interrupted, .failed, .unknown:
            return true
        case .inProgress, nil:
            return false
        }
    }
    var hasProvisionalResumeSnapshot: Bool {
        turnID == nil && provisionalResumeSnapshot != nil
    }

    func isSupersededByObservedTurn(_ observedTurnID: CodexTurnID?) -> Bool {
        isHistoricalSnapshotOnly
            && observedTurnID != nil
            && observedTurnID != turnID
    }

    func isSupersededByHistoricalTurn(_ historicalTurnID: CodexTurnID) -> Bool {
        turnID != historicalTurnID && (isHistoricalSnapshotOnly || hasTerminal)
    }

    var compactEvents: [CodexThreadEvent] {
        if let terminal {
            return terminalReplayEvents(terminal)
        }
        var events: [CodexThreadEvent] = []
        if let snapshot {
            events.append(.snapshot(snapshot))
        }
        if let latestStatus {
            events.append(.statusChanged(latestStatus))
        }
        if let latestUsage {
            events.append(.tokenUsageUpdated(latestUsage, turnID: turnID))
        }
        events.append(contentsOf: compactTail)
        precondition(events.count <= Self.compactCapacity)
        return events
    }

    var replayEvents: [CodexThreadEvent] {
        var events = compactEvents
        if isClosed {
            events.append(.closed)
        }
        return events
    }

    mutating func apply(_ event: CodexThreadEvent) throws -> ApplyDisposition {
        if isClosed {
            if case .closed = event {
                return .duplicate
            }
            throw CodexTransportFailure.contractViolation(
                message: "A compact thread generation received an event after thread/closed."
            )
        }

        switch event {
        case .turnStarted(let eventTurnID):
            try establishTurn(eventTurnID)
            try requireNonterminalTurnEvent("turn/started")
            snapshotReducer?.markStarted()

        case .snapshot(let newSnapshot):
            try establishTurn(newSnapshot.id)
            try requireNonterminalTurnEvent("turn snapshot")
            seed(newSnapshot)
            compactTail.removeAll(keepingCapacity: true)

        case .terminal(let outcome):
            let outcome = finalized(outcome)
            try establishTurn(outcome.response.turnID)
            guard var candidateReducer = snapshotReducer else {
                preconditionFailure("A terminal turn requires a snapshot reducer.")
            }
            let compactSnapshot = candidateReducer.finish(outcome)
            if let terminal {
                guard terminal == compactSnapshot.outcome else {
                    throw CodexTransportFailure.contractViolation(
                        message: "Turn \(outcome.response.turnID.rawValue) reported conflicting terminal outcomes."
                    )
                }
                return .duplicate
            }
            snapshotReducer = candidateReducer
            terminal = compactSnapshot.outcome

        case .itemStarted(let item, let eventTurnID),
             .itemUpdated(let item, let eventTurnID),
             .itemCompleted(let item, let eventTurnID):
            try establishOptionalTurn(eventTurnID)
            try requireNonterminalTurnEvent("item update")
            guard turnID != nil else {
                appendCompactTail(event)
                return .accepted
            }
            upsert(item)

        case .message(let message, let eventTurnID):
            try establishOptionalTurn(eventTurnID)
            try requireNonterminalTurnEvent("message")
            guard turnID != nil else {
                appendCompactTail(event)
                return .accepted
            }
            upsert(.init(
                id: message.id,
                kind: message.role == .user ? .userMessage : .agentMessage,
                content: .message(message)
            ))

        case .messageDelta(let delta, let eventTurnID):
            try establishOptionalTurn(eventTurnID)
            try requireNonterminalTurnEvent("message delta")
            guard turnID != nil, let currentItem = delta.currentItem else {
                appendCompactTail(event)
                return .accepted
            }
            upsert(currentItem)
            appendCompactTail(event)

        case .reasoningSummaryPartAdded(let part, let eventTurnID):
            try establishOptionalTurn(eventTurnID)
            try requireNonterminalTurnEvent("reasoning part")
            guard turnID != nil, let currentItem = part.currentItem else {
                appendCompactTail(event)
                return .accepted
            }
            upsert(currentItem)
            appendCompactTail(event)

        case .reasoningDelta(let delta, let eventTurnID):
            try establishOptionalTurn(eventTurnID)
            try requireNonterminalTurnEvent("reasoning delta")
            guard turnID != nil, let currentItem = delta.currentItem else {
                appendCompactTail(event)
                return .accepted
            }
            upsert(currentItem)
            appendCompactTail(event)

        case .tokenUsageUpdated(let usage, let eventTurnID):
            try establishOptionalTurn(eventTurnID)
            try requireNonterminalTurnEvent("token usage")
            latestUsage = usage

        case .diagnostic(_, let eventTurnID):
            try establishTurn(eventTurnID)
            try requireNonterminalTurnEvent("turn diagnostic")
            appendCompactTail(event)

        case .statusChanged(let status):
            if terminal == nil {
                latestStatus = status
            } else {
                appendPostTerminal(event)
            }

        case .unknown:
            if terminal == nil {
                appendCompactTail(event)
            } else {
                appendPostTerminal(event)
            }

        case .closed:
            isClosed = true
        }
        return .accepted
    }

    private mutating func establishOptionalTurn(_ eventTurnID: CodexTurnID?) throws {
        if let eventTurnID {
            try establishTurn(eventTurnID)
        }
    }

    private mutating func establishTurn(_ eventTurnID: CodexTurnID) throws {
        if let turnID {
            guard turnID == eventTurnID else {
                throw CodexTransportFailure.contractViolation(
                    message: "One thread generation cannot contain turns \(turnID.rawValue) and \(eventTurnID.rawValue)."
                )
            }
            isHistoricalSnapshotOnly = false
            return
        }
        if hasProvisionalResumeSnapshot {
            adoptProvisionalResumeIdentity(eventTurnID)
        } else {
            snapshotReducer = .init(turnID: eventTurnID)
        }
        isHistoricalSnapshotOnly = false
    }

    mutating func mergeResponseSnapshot(_ responseSnapshot: CodexTurnSnapshot) throws {
        try establishTurn(responseSnapshot.id)
        seed(responseSnapshot)
        reconcileTerminalSnapshot()
    }

    mutating func mergeHistoricalSnapshot(_ historicalSnapshot: CodexTurnSnapshot) throws {
        if let provisionalResumeSnapshot {
            guard provisionalResumeSnapshot.id == historicalSnapshot.id else {
                throw CodexTransportFailure.contractViolation(
                    message: "A provisional resume snapshot cannot merge historical turn "
                        + "\(historicalSnapshot.id.rawValue) into "
                        + "\(provisionalResumeSnapshot.id.rawValue)."
                )
            }
            var reducer = CodexTurnSnapshotReducer(snapshot: provisionalResumeSnapshot)
            reducer.merge(historicalSnapshot)
            self.provisionalResumeSnapshot = reducer.snapshot
            return
        }
        if let turnID {
            guard turnID == historicalSnapshot.id else {
                throw CodexTransportFailure.contractViolation(
                    message: "One thread generation cannot contain turns "
                        + "\(turnID.rawValue) and \(historicalSnapshot.id.rawValue)."
                )
            }
            seed(historicalSnapshot)
            reconcileTerminalSnapshot()
            return
        }
        snapshotReducer = .init(snapshot: historicalSnapshot)
        isHistoricalSnapshotOnly = true
    }

    mutating func mergeProvisionalResumeSnapshot(_ responseSnapshot: CodexTurnSnapshot) {
        precondition(
            responseSnapshot.state == .inProgress,
            "Only an in-progress resume response can provisionally seed a live generation."
        )
        guard let turnID else {
            precondition(
                provisionalResumeSnapshot == nil,
                "A generation can receive one provisional response snapshot."
            )
            // thread/resume reconstructs review turn IDs from rollout history. Keep that
            // baseline private until a notification supplies the canonical live identity.
            provisionalResumeSnapshot = responseSnapshot
            return
        }
        var adoptedSnapshot = responseSnapshot
        adoptedSnapshot.id = turnID
        seed(adoptedSnapshot)
        reconcileTerminalSnapshot()
    }

    mutating func adoptProvisionalResumeIdentity(_ canonicalTurnID: CodexTurnID) {
        precondition(
            hasProvisionalResumeSnapshot,
            "Only an identity-unbound resume snapshot can adopt a persisted live turn identity."
        )
        provisionalResumeSnapshot?.id = canonicalTurnID
        snapshotReducer = provisionalResumeSnapshot.map(CodexTurnSnapshotReducer.init(snapshot:))
        provisionalResumeSnapshot = nil
    }

    private func requireNonterminalTurnEvent(_ name: StaticString) throws {
        guard terminal == nil else {
            throw CodexTransportFailure.contractViolation(
                message: "A thread generation received \(name) after its terminal outcome."
            )
        }
    }

    private mutating func seed(_ newSnapshot: CodexTurnSnapshot) {
        guard var snapshotReducer else {
            self.snapshotReducer = .init(snapshot: newSnapshot)
            return
        }
        snapshotReducer.merge(newSnapshot)
        self.snapshotReducer = snapshotReducer
    }

    private mutating func upsert(_ item: CodexThreadItem) {
        guard var snapshotReducer else {
            preconditionFailure("A compact item update requires a turn snapshot.")
        }
        snapshotReducer.observe(item)
        self.snapshotReducer = snapshotReducer
    }

    private mutating func reconcileTerminalSnapshot() {
        guard let terminal else {
            return
        }
        guard var snapshotReducer else {
            preconditionFailure("A terminal turn requires a snapshot reducer.")
        }
        let compactSnapshot = snapshotReducer.finish(terminal)
        self.snapshotReducer = snapshotReducer
        self.terminal = compactSnapshot.outcome
    }

    private func finalized(_ outcome: CodexTurnOutcome) -> CodexTurnOutcome {
        guard outcome.response.usage == nil, let latestUsage else {
            return outcome
        }
        var response = outcome.response
        response.usage = latestUsage
        switch outcome {
        case .completed:
            return .completed(response)
        case .interrupted:
            return .interrupted(response)
        case .failed(let failed):
            return .failed(.init(response: response, error: failed.error))
        case .invalidTerminalStatus(let rawStatus, let error, _):
            return .invalidTerminalStatus(
                rawStatus: rawStatus,
                error: error,
                response: response
            )
        }
    }

    private mutating func appendCompactTail(_ event: CodexThreadEvent) {
        compactTail.append(event)
        if compactTail.count > Self.compactTailCapacity {
            compactTail.removeFirst(compactTail.count - Self.compactTailCapacity)
        }
    }

    private mutating func appendPostTerminal(_ event: CodexThreadEvent) {
        postTerminalTail.append(event)
        if postTerminalTail.count > Self.postTerminalTailCapacity {
            postTerminalTail.removeFirst(
                postTerminalTail.count - Self.postTerminalTailCapacity
            )
        }
    }

    private func terminalReplayEvents(
        _ terminal: CodexTurnOutcome
    ) -> [CodexThreadEvent] {
        var events: [CodexThreadEvent] = []
        if let snapshot {
            events.append(.snapshot(snapshot))
        }
        events.append(.terminal(terminal))
        events.append(contentsOf: postTerminalTail)
        precondition(
            events.filter(\.isThreadBufferedIncrementalEvent).count <= Self.compactCapacity
        )
        return events
    }
}

private enum ThreadEventPublication {
    case yield(
        [ThreadEventSubscriberChannel],
        CodexThreadEvent,
        [CodexThreadEvent],
        UInt64
    )
    case supersede(
        [ThreadEventSubscriberChannel],
        [CodexThreadEvent],
        UInt64,
        resetsGeneration: Bool
    )
    case finish([ThreadEventSubscriberChannel], [CodexThreadEvent], UInt64)

    func deliver() -> Int {
        switch self {
        case .yield(let channels, let event, let compactEvents, let revision):
            return channels.reduce(into: 0) { overflowCount, channel in
                overflowCount += channel.yield(
                    event,
                    compactEvents: compactEvents,
                    revision: revision
                )
            }
        case .supersede(let channels, let events, let revision, let resetsGeneration):
            for channel in channels {
                channel.supersede(
                    with: events,
                    revision: revision,
                    resetsGeneration: resetsGeneration
                )
            }
            return 0
        case .finish(let channels, let events, let revision):
            for channel in channels {
                channel.finish(with: events, revision: revision)
            }
            return 0
        }
    }
}

private enum ThreadEventInitialPublication {
    case supersede([CodexThreadEvent], UInt64)
    case finish([CodexThreadEvent], UInt64)
    case fail(CodexAppServerError)

    func deliver(to channel: ThreadEventSubscriberChannel) {
        switch self {
        case .supersede(let events, let revision):
            channel.supersede(with: events, revision: revision, resetsGeneration: true)
        case .finish(let events, let revision):
            channel.finish(with: events, revision: revision)
        case .fail(let error):
            channel.fail(error)
        }
    }
}

private final class ThreadEventSubscriberChannel: Sendable {
    private enum Phase: Sendable {
        case open
        case finishing
        case failed(CodexAppServerError)
        case finished
        case cancelled
    }

    private struct State: Sendable {
        var pending: [CodexThreadEvent] = []
        var waiter: CheckedContinuation<CodexThreadEvent?, Error>?
        var phase = Phase.open
        var nextIsActive = false
        var overflowCount = 0
        var lastPublicationRevision: UInt64?
        var currentTurnID: CodexTurnID?
        var deliveredTerminal: CodexTurnOutcome?
    }

    private static let incrementalCapacity = 256
    private let state = Mutex(State())

    @discardableResult
    func yield(
        _ event: CodexThreadEvent,
        compactEvents: [CodexThreadEvent],
        revision: UInt64
    ) -> Int {
        let result = state.withLock { state -> (ThreadEventWaiterDelivery?, Int) in
            let hasRevisionGap = state.lastPublicationRevision.map {
                revision > ($0 &+ 1)
            } ?? false
            guard case .open = state.phase, accept(revision, state: &state) else {
                return (nil, 0)
            }
            if hasRevisionGap {
                prepareGeneration(
                    for: compactEvents,
                    resetsGeneration: false,
                    state: &state
                )
                state.pending = filtered(compactEvents, state: &state)
                state.overflowCount += 1
                guard let waiter = state.waiter, state.pending.isEmpty == false else {
                    return (nil, 1)
                }
                state.waiter = nil
                let next = state.pending.removeFirst()
                recordTerminal(next, state: &state)
                return (.value(waiter, next), 1)
            }
            prepareGeneration(for: [event], resetsGeneration: false, state: &state)
            if let waiter = state.waiter {
                state.waiter = nil
                return (.value(waiter, event), 0)
            }
            if case .snapshot = event {
                precondition(
                    compactEvents.filter(\.isThreadBufferedIncrementalEvent).count
                        <= Self.incrementalCapacity
                )
                if state.pending.isEmpty {
                    state.pending.append(event)
                } else {
                    let closed = state.pending.filter(\.isThreadClosedEvent)
                    state.pending = compactEvents + closed
                }
                return (nil, 0)
            }
            let pendingIncrementalCount = state.pending.reduce(into: 0) { count, pending in
                if pending.isThreadBufferedIncrementalEvent {
                    count += 1
                }
            }
            if pendingIncrementalCount == Self.incrementalCapacity {
                precondition(
                    compactEvents.filter(\.isThreadBufferedIncrementalEvent).count
                        <= Self.incrementalCapacity
                )
                let closed = state.pending.filter(\.isThreadClosedEvent)
                state.pending = compactEvents + closed
                state.overflowCount += 1
                return (nil, 1)
            }
            if let closedIndex = state.pending.firstIndex(where: \.isThreadClosedEvent) {
                state.pending.insert(event, at: closedIndex)
            } else {
                state.pending.append(event)
            }
            return (nil, 0)
        }
        result.0?.resume()
        return result.1
    }

    func supersede(
        with events: [CodexThreadEvent],
        revision: UInt64,
        resetsGeneration: Bool
    ) {
        let delivery = state.withLock { state -> ThreadEventWaiterDelivery? in
            guard case .open = state.phase, accept(revision, state: &state) else {
                return nil
            }
            prepareGeneration(
                for: events,
                resetsGeneration: resetsGeneration,
                state: &state
            )
            state.pending = filtered(events, state: &state)
            guard let waiter = state.waiter, state.pending.isEmpty == false else {
                return nil
            }
            state.waiter = nil
            let event = state.pending.removeFirst()
            recordTerminal(event, state: &state)
            return .value(waiter, event)
        }
        delivery?.resume()
    }

    func finish(with events: [CodexThreadEvent], revision: UInt64) {
        let delivery = state.withLock { state -> ThreadEventWaiterDelivery? in
            switch state.phase {
            case .open:
                let requiresReplay = state.lastPublicationRevision == nil
                    || state.lastPublicationRevision.map {
                        revision > ($0 &+ 1)
                    } == true
                guard accept(revision, state: &state) else {
                    return nil
                }
                prepareGeneration(for: events, resetsGeneration: false, state: &state)
                if requiresReplay {
                    state.pending = filtered(events, state: &state)
                } else {
                    state.pending.append(contentsOf: events.filter(\.isThreadClosedEvent))
                }
                state.phase = .finishing
                guard let waiter = state.waiter else {
                    return nil
                }
                state.waiter = nil
                if state.pending.isEmpty {
                    state.phase = .finished
                    return .finished(waiter)
                }
                let event = state.pending.removeFirst()
                recordTerminal(event, state: &state)
                return .value(waiter, event)
            case .finishing, .finished, .cancelled:
                return nil
            case .failed(let existing):
                preconditionFailure(
                    "A failed thread event subscriber cannot finish successfully: \(existing)."
                )
            }
        }
        delivery?.resume()
    }

    func fail(_ error: CodexAppServerError) {
        let waiter = state.withLock { state -> CheckedContinuation<CodexThreadEvent?, Error>? in
            switch state.phase {
            case .open:
                state.pending.removeAll(keepingCapacity: false)
                state.phase = .failed(error)
                let waiter = state.waiter
                state.waiter = nil
                return waiter
            case .failed(let existing):
                precondition(existing == error, "A thread subscriber failure cannot be replaced.")
                return nil
            case .finishing, .finished:
                preconditionFailure("A normally finished thread subscriber cannot fail afterward.")
            case .cancelled:
                return nil
            }
        }
        waiter?.resume(throwing: error)
    }

    func next(
        cancellation: ThreadEventSubscriptionCancellation
    ) async throws -> CodexThreadEvent? {
        precondition(tryBeginNext(), "CodexThreadEventSequence supports one in-flight next() call.")
        defer { endNext() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate = state.withLock { state -> Result<CodexThreadEvent?, Error>? in
                    if state.pending.isEmpty == false {
                        let event = state.pending.removeFirst()
                        recordTerminal(event, state: &state)
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
        let waiter = state.withLock { state -> CheckedContinuation<CodexThreadEvent?, Error>? in
            switch state.phase {
            case .open, .finishing, .failed:
                state.phase = .cancelled
                state.pending.removeAll(keepingCapacity: false)
                let waiter = state.waiter
                state.waiter = nil
                return waiter
            case .finished, .cancelled:
                return nil
            }
        }
        waiter?.resume(returning: nil)
    }

    func overflowCountForTesting() -> Int {
        state.withLock { $0.overflowCount }
    }

    private func filtered(
        _ events: [CodexThreadEvent],
        state: inout State
    ) -> [CodexThreadEvent] {
        events.filter { event in
            guard case .terminal(let outcome) = event else {
                return true
            }
            guard let delivered = state.deliveredTerminal else {
                return true
            }
            return delivered.response.turnID != outcome.response.turnID
        }
    }

    private func recordTerminal(_ event: CodexThreadEvent, state: inout State) {
        guard case .terminal(let outcome) = event else {
            return
        }
        if let existing = state.deliveredTerminal,
           existing.response.turnID == outcome.response.turnID
        {
            precondition(existing == outcome, "A subscriber cannot observe conflicting terminals.")
            return
        }
        state.deliveredTerminal = outcome
    }

    private func accept(_ revision: UInt64, state: inout State) -> Bool {
        if let last = state.lastPublicationRevision, revision <= last {
            return false
        }
        state.lastPublicationRevision = revision
        return true
    }

    private func prepareGeneration(
        for events: [CodexThreadEvent],
        resetsGeneration: Bool,
        state: inout State
    ) {
        let eventTurnID = events.lazy.compactMap(\.threadTurnID).first
        if resetsGeneration || (eventTurnID != nil && eventTurnID != state.currentTurnID) {
            state.deliveredTerminal = nil
            state.currentTurnID = eventTurnID
        } else if state.currentTurnID == nil, let eventTurnID {
            state.currentTurnID = eventTurnID
        }
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

private enum ThreadEventWaiterDelivery {
    case value(CheckedContinuation<CodexThreadEvent?, Error>, CodexThreadEvent)
    case finished(CheckedContinuation<CodexThreadEvent?, Error>)

    func resume() {
        switch self {
        case .value(let waiter, let event):
            waiter.resume(returning: event)
        case .finished(let waiter):
            waiter.resume(returning: nil)
        }
    }
}

private final class ThreadEventSubscriptionCancellation: Sendable {
    private let state = Mutex(false)
    private let id: UUID
    private let threadID: CodexThreadID
    private let hub: ThreadEventHub
    private let channel: ThreadEventSubscriberChannel

    init(
        id: UUID,
        threadID: CodexThreadID,
        hub: ThreadEventHub,
        channel: ThreadEventSubscriberChannel
    ) {
        self.id = id
        self.threadID = threadID
        self.hub = hub
        self.channel = channel
    }

    func cancel() {
        let shouldRemove = state.withLock { isCancelled in
            guard isCancelled == false else {
                return false
            }
            isCancelled = true
            return true
        }
        if shouldRemove {
            hub.removeSubscriber(id, threadID: threadID)
            channel.cancel()
        }
    }

    deinit {
        cancel()
    }
}

private extension CodexThreadEvent {
    var threadTurnID: CodexTurnID? {
        switch self {
        case .turnStarted(let turnID):
            turnID
        case .snapshot(let snapshot):
            snapshot.id
        case .terminal(let outcome):
            outcome.response.turnID
        case .itemStarted(_, let turnID), .itemUpdated(_, let turnID),
             .itemCompleted(_, let turnID), .message(_, let turnID),
             .messageDelta(_, let turnID), .reasoningSummaryPartAdded(_, let turnID),
             .reasoningDelta(_, let turnID), .tokenUsageUpdated(_, let turnID):
            turnID
        case .diagnostic(_, let turnID):
            turnID
        case .unknown(let raw):
            raw.turnID
        case .statusChanged, .closed:
            nil
        }
    }

    var isThreadControlEvent: Bool {
        switch self {
        case .terminal, .closed:
            true
        case .turnStarted, .snapshot, .itemStarted, .itemUpdated, .itemCompleted,
             .message, .messageDelta, .reasoningSummaryPartAdded, .reasoningDelta,
             .diagnostic, .tokenUsageUpdated, .statusChanged, .unknown:
            false
        }
    }

    var isThreadBufferedIncrementalEvent: Bool {
        switch self {
        case .turnStarted, .itemStarted, .itemUpdated, .itemCompleted, .message,
             .messageDelta, .reasoningSummaryPartAdded, .reasoningDelta,
             .diagnostic, .tokenUsageUpdated, .statusChanged, .unknown:
            true
        case .snapshot, .terminal, .closed:
            false
        }
    }

    var isThreadClosedEvent: Bool {
        if case .closed = self {
            return true
        }
        return false
    }
}
