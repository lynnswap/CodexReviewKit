import AsyncAlgorithms
import CodexAppServerKit
import Foundation
import OSLog
import Synchronization

private let logger = Logger(subsystem: "CodexDataKit", category: "model-context")

public enum CodexModelContextError: Error, Equatable, Sendable {
    case unsupportedModelType(String)
    case modelIsDetached
}

package struct CodexModelContextID: Hashable, Sendable {
    private let rawValue: UUID

    package init() {
        self.rawValue = UUID()
    }
}

package struct CodexStartedReviewContextChange: Sendable {
    package var snapshot: CodexThreadSnapshot
    package var eventThread: CodexThread
    package var archived: Bool
    package var provisionalSeedTurnID: CodexTurnID?

    package init(
        snapshot: CodexThreadSnapshot,
        eventThread: CodexThread,
        archived: Bool,
        provisionalSeedTurnID: CodexTurnID?
    ) {
        self.snapshot = snapshot
        self.eventThread = eventThread
        self.archived = archived
        self.provisionalSeedTurnID = provisionalSeedTurnID
    }
}

package struct CodexModelContextTransaction: Sendable {
    package var startedReviews: [CodexStartedReviewContextChange] = []

    package init(startedReviews: [CodexStartedReviewContextChange] = []) {
        self.startedReviews = startedReviews
    }

    package var isEmpty: Bool {
        startedReviews.isEmpty
    }
}

@MainActor
package final class CodexModelContextCoordinator {
    package nonisolated let appServer: CodexAppServer
    private weak var mainContext: CodexModelContext?

    package init(appServer: CodexAppServer) {
        self.appServer = appServer
    }

    package func attachMainContext(_ context: CodexModelContext) {
        precondition(mainContext == nil, "A model coordinator can have one main context.")
        precondition(context.appServer === appServer)
        mainContext = context
    }

    package func multicast(
        _ transaction: CodexModelContextTransaction,
        from sourceContextID: CodexModelContextID
    ) async {
        guard transaction.isEmpty == false,
            let mainContext,
            sourceContextID != mainContext.contextID
        else {
            return
        }
        await mainContext.merge(transaction)
    }
}

public final class CodexModelContainer: Equatable, Sendable {
    public let appServer: CodexAppServer
    package let coordinator: CodexModelContextCoordinator

    @MainActor
    public let mainContext: CodexModelContext

    @MainActor
    public init(appServer: CodexAppServer) {
        let coordinator = CodexModelContextCoordinator(appServer: appServer)
        let mainContext = CodexModelContext(coordinator: coordinator)
        self.appServer = appServer
        self.coordinator = coordinator
        self.mainContext = mainContext
        coordinator.attachMainContext(mainContext)
    }

    public nonisolated static func == (
        lhs: CodexModelContainer,
        rhs: CodexModelContainer
    ) -> Bool {
        lhs === rhs
    }

}

public final class CodexModelContext: Equatable, SendableMetatype {
    private static let localCursorPrefix = "codexkit-ui-offset:"

    private final class WeakActorReference: Sendable {
        private final class Storage {
            weak var value: (any Actor)?

            init(_ value: any Actor) {
                self.value = value
            }
        }

        private let storage: Mutex<Storage>

        init(_ value: any Actor) {
            storage = Mutex(Storage(value))
        }

        func load() -> (any Actor)? {
            storage.withLock { $0.value }
        }
    }

    private struct ChatFetchedResultState: Equatable {
        var name: String?
        var preview: String?
        var modelProvider: String?
        var sessionID: String?
        var parentThreadID: CodexThreadID?
        var sourceResolution: CodexThreadSourceResolution
        var gitInfo: CodexThreadGitInfo?
        var isArchived: Bool
        var createdAt: Date?
        var updatedAt: Date?
        var recencyAt: Date?
        var status: CodexThreadStatus?
        var ephemeral: Bool?
        var workspaceID: CodexWorkspaceID?
        var workspaceGroupID: CodexWorkspaceGroupID?
    }

    private struct FetchedThreadOccurrence: Sendable {
        var snapshot: CodexThreadSnapshot
        var sourceProvenance: CodexThreadListSourceProvenance
    }

    private struct FetchedThreadCandidate: Sendable {
        var firstOccurrence: FetchedThreadOccurrence
        var additionalOccurrences: [FetchedThreadOccurrence] = []

        init(snapshot: CodexThreadSnapshot, sourceKinds: [CodexThreadSourceKind]?) {
            firstOccurrence = FetchedThreadOccurrence(
                snapshot: snapshot,
                sourceProvenance: CodexThreadListSourceProvenance(sourceKinds: sourceKinds)
            )
        }

        var id: CodexThreadID {
            firstOccurrence.snapshot.id
        }

        var latestSnapshot: CodexThreadSnapshot {
            additionalOccurrences.last?.snapshot ?? firstOccurrence.snapshot
        }

        var hasMultipleOccurrences: Bool {
            additionalOccurrences.isEmpty == false
        }

        func sourceResolution(
            startingAt initialResolution: CodexThreadSourceResolution
        ) -> CodexThreadSourceResolution {
            var resolution = initialResolution
            resolution.apply(
                firstOccurrence.snapshot,
                partitionProvenance: firstOccurrence.sourceProvenance
            )
            for occurrence in additionalOccurrences {
                resolution.apply(
                    occurrence.snapshot,
                    partitionProvenance: occurrence.sourceProvenance
                )
            }
            return resolution
        }

        mutating func append(
            snapshot: CodexThreadSnapshot,
            sourceKinds: [CodexThreadSourceKind]?
        ) {
            precondition(
                snapshot.id == id,
                "Only snapshots for the same thread can be combined."
            )
            additionalOccurrences.append(FetchedThreadOccurrence(
                snapshot: snapshot,
                sourceProvenance: CodexThreadListSourceProvenance(sourceKinds: sourceKinds)
            ))
        }
    }

    private struct RefreshedThreadSnapshot: Sendable {
        var snapshot: CodexThreadSnapshot
        var metadataReadCompleted: Bool
    }

    private enum ChatObservationStartSnapshot: Sendable {
        case loaded(RefreshedThreadSnapshot)
        case failed(CodexAppServerError)
    }

    private struct ChatObservationStartLoad: Sendable {
        var thread: CodexThread
        var source: String
        var usesPreparedThread: Bool
        var includesTurns: Bool
        var eventStream: CodexThreadEventSequence?
        var snapshot: ChatObservationStartSnapshot
    }

    private enum ChatObservationStartOutcome: Sendable {
        case loaded(ChatObservationStartLoad)
        case failed(CodexAppServerError)
    }

    private final class ActiveChatObservation {
        let generation: UInt64
        let stablePhase: CodexChatPhase
        let isolation: WeakActorReference
        let releaseSignal = ChatObservationReleaseSignal()
        var eventThread: CodexThread?
        var eventStream: CodexThreadEventSequence?
        var includesTurns = false
        var isFinished = false
        var isClosing = false
        var finishSnapshotReason: CodexChatSnapshotReason?
        var isBufferingEvents = false
        var bufferedEvents: [CodexThreadEvent] = []
        var subscribers: [UUID: CodexChatObservationChannel] = [:]
        var sequence: UInt64 = 0
        var hasAppliedLiveUpdates = false
        var isStarting = true
        var isCommittingStart = false
        var startWasCancelled = false
        var startWaiters: [ChatObservationStartWaiter] = []
        var pendingRegistrationCount = 0
        var startOperation: ChatObservationStartOperation<ChatObservationStartOutcome>?
        var isUpgrading = false
        var upgradeWaiters: [CheckedContinuation<Void, any Error>] = []
        var closeWaiters: [CheckedContinuation<Void, Never>] = []

        init(
            generation: UInt64,
            stablePhase: CodexChatPhase,
            isolation: any Actor
        ) {
            self.generation = generation
            self.stablePhase = stablePhase
            self.isolation = WeakActorReference(isolation)
        }

        func cancel() {
            isFinished = true
            startOperation?.cancel()
            releaseSignal.terminate()
            eventPump?.cancel()
            discardBufferedEvents()
            for channel in subscribers.values {
                channel.finish()
            }
            subscribers.removeAll(keepingCapacity: false)
            eventStream = nil
            finishClosing()
        }

        func waitUntilStarted() async throws {
            if startWasCancelled { throw CancellationError() }
            guard isStarting else { return }
            let waiter = ChatObservationStartWaiter()
            if startWasCancelled {
                waiter.resolve(cancelled: true)
            } else if isStarting {
                startWaiters.append(waiter)
            } else {
                waiter.resolve(cancelled: false)
            }
            try await waiter.wait()
        }

        func finishStarting(cancelled: Bool = false) {
            precondition(isStarting)
            isStarting = false
            startWasCancelled = cancelled
            let waiters = startWaiters
            startWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resolve(cancelled: cancelled)
            }
        }

        func waitUntilUpgradeFinishes() async throws {
            guard isUpgrading else { return }
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if isUpgrading { upgradeWaiters.append(continuation) }
                else { continuation.resume() }
            }
        }

        func finishUpgrade(with error: (any Error)? = nil) {
            precondition(isUpgrading)
            isUpgrading = false
            let waiters = upgradeWaiters
            upgradeWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                if let error { waiter.resume(throwing: error) }
                else { waiter.resume() }
            }
        }

        func waitUntilClosed() async {
            guard isFinished == false else { return }
            await withCheckedContinuation { continuation in
                if isFinished {
                    continuation.resume()
                } else {
                    closeWaiters.append(continuation)
                }
            }
        }

        func finishClosing() {
            isClosing = false
            let waiters = closeWaiters
            closeWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
        }

        var eventPump: ThreadEventPump?

        func beginBufferingEvents() {
            isBufferingEvents = true
        }

        func appendBufferedEvent(_ event: CodexThreadEvent) {
            bufferedEvents.append(event)
        }

        var hasBufferedEvents: Bool {
            bufferedEvents.isEmpty == false
        }

        var shouldPreserveLiveTurnItems: Bool {
            hasAppliedLiveUpdates || hasBufferedEvents
        }

        func markAppliedLiveUpdates() {
            hasAppliedLiveUpdates = true
        }

        func finishBufferingEvents() -> [CodexThreadEvent] {
            isBufferingEvents = false
            defer {
                bufferedEvents.removeAll(keepingCapacity: true)
            }
            return bufferedEvents
        }

        func discardBufferedEvents() {
            isBufferingEvents = false
            bufferedEvents.removeAll(keepingCapacity: true)
        }

        func yield(_ mutations: [CodexChatMutation], chat: CodexChat) {
            let updates = chat.observationUpdates(for: mutations)
            guard updates.isEmpty == false else {
                return
            }
            let firstSequence = sequence &+ 1
            sequence &+= UInt64(updates.count)
            let events = updates.enumerated().map { offset, update in
                CodexChatObservationEvent(
                    generation: generation,
                    sequence: firstSequence &+ UInt64(offset),
                    payload: .update(update)
                )
            }
            let overflow = snapshotEvent(chat: chat, reason: .bufferOverflow)
            for channel in subscribers.values {
                channel.yield(events, overflowSnapshot: overflow)
            }
        }

        func makeSubscriber(chat: CodexChat) -> (UUID, CodexChatUpdates) {
            let id = UUID()
            let channel = CodexChatObservationChannel(
                releaseSignal: releaseSignal,
                leaseID: id
            )
            channel.seed(snapshotEvent(
                chat: chat,
                reason: finishSnapshotReason
                    ?? (generation == 1 ? .initial : .generationRestart)
            ))
            if isFinished {
                channel.finish()
            } else {
                subscribers[id] = channel
            }
            return (id, CodexChatUpdates(channel: channel))
        }

        func removeSubscriber(_ id: UUID) {
            subscribers.removeValue(forKey: id)?.finish()
        }

        func broadcastSnapshot(
            chat: CodexChat,
            reason: CodexChatSnapshotReason,
            advancesSequence: Bool = true
        ) {
            if advancesSequence {
                sequence &+= 1
            }
            let event = snapshotEvent(chat: chat, reason: reason)
            for channel in subscribers.values {
                channel.yield(event, overflowSnapshot: event)
            }
        }

        func finishSubscribers() {
            for channel in subscribers.values {
                channel.finish()
            }
            subscribers.removeAll(keepingCapacity: false)
        }

        private func snapshotEvent(
            chat: CodexChat,
            reason: CodexChatSnapshotReason
        ) -> CodexChatObservationEvent {
            CodexChatObservationEvent(
                generation: generation,
                sequence: sequence,
                payload: .snapshot(
                    .init(thread: chat.observationSnapshot(), phase: chat.phase),
                    reason: reason
                )
            )
        }
    }

    private final class ThreadEventPump {
        private enum ChildResult: Sendable {
            case upstreamFinished
            case upstreamCancelled
            case releaseReceiverFinished
            case lastLeaseReleased(UUID)
        }

        private let task: Task<Void, Never>
        private let releaseSignal: ChatObservationReleaseSignal

        init(
            context: CodexModelContext,
            chatID: CodexThreadID,
            observation: ActiveChatObservation,
            stream: CodexThreadEventSequence,
            releaseSignal: ChatObservationReleaseSignal,
            isolation: WeakActorReference
        ) {
            self.releaseSignal = releaseSignal
            let target = ThreadEventPumpTarget(
                context: context,
                chatID: chatID,
                observation: observation
            )
            task = Task {
                var lastReleasedLeaseID: UUID?
                await withTaskGroup(of: ChildResult.self) { group in
                    group.addTask {
                        do {
                            for try await event in stream {
                                guard let actor = isolation.load() else {
                                    return .upstreamCancelled
                                }
                                await target.process(event, isolation: actor)
                            }
                            if let actor = isolation.load() {
                                await target.finish(isolation: actor)
                            }
                            releaseSignal.terminate()
                            return .upstreamFinished
                        } catch is CancellationError {
                            return .upstreamCancelled
                        } catch {
                            if let actor = isolation.load() {
                                await target.fail(with: error, isolation: actor)
                            }
                            releaseSignal.terminate()
                            return .upstreamFinished
                        }
                    }
                    group.addTask {
                        while let release = await releaseSignal.next() {
                            guard let actor = isolation.load() else {
                                return .lastLeaseReleased(release.leaseID)
                            }
                            let isLast = await target.release(
                                leaseID: release.leaseID,
                                isolation: actor
                            )
                            if isLast {
                                return .lastLeaseReleased(release.leaseID)
                            }
                            releaseSignal.acknowledge(release.leaseID)
                        }
                        return .releaseReceiverFinished
                    }
                    while let result = await group.next() {
                        switch result {
                        case .lastLeaseReleased(let leaseID):
                            lastReleasedLeaseID = leaseID
                            releaseSignal.terminate()
                            group.cancelAll()
                        case .upstreamFinished, .upstreamCancelled:
                            releaseSignal.terminate()
                            group.cancelAll()
                        case .releaseReceiverFinished:
                            if Task.isCancelled {
                                group.cancelAll()
                            }
                        }
                    }
                }
                if let lastReleasedLeaseID {
                    if let actor = isolation.load() {
                        await target.completeLastRelease(isolation: actor)
                    }
                    releaseSignal.acknowledge(lastReleasedLeaseID)
                }
                releaseSignal.completeAllAcknowledgements()
            }
        }

        func cancel() {
            releaseSignal.terminate()
            task.cancel()
        }

        func cancelAndWait() async {
            releaseSignal.terminate()
            task.cancel()
            await task.value
        }
    }

    // The raw event stream is consumed off-actor; model mutation hops to the
    // isolation the observation was started from, which is the context owner's
    // isolation (MainActor for the main context, the model executor for
    // model-actor contexts).
    private final class ThreadEventPumpTarget: @unchecked Sendable {
        private weak var context: CodexModelContext?
        private let chatID: CodexThreadID
        private let observation: ActiveChatObservation

        init(
            context: CodexModelContext,
            chatID: CodexThreadID,
            observation: ActiveChatObservation
        ) {
            self.context = context
            self.chatID = chatID
            self.observation = observation
        }

        func process(_ event: CodexThreadEvent, isolation: isolated any Actor) async {
            await context?.processObservedEvent(event, chatID: chatID, observation: observation)
        }

        func finish(isolation: isolated any Actor) {
            context?.finishChatObservationIfIdle(chatID, observation: observation)
        }

        func fail(with error: Error, isolation: isolated any Actor) async {
            await context?.failChatObservation(chatID, observation: observation, error: error)
        }

        func release(
            leaseID: UUID,
            isolation: isolated any Actor
        ) -> Bool {
            guard let context else { return true }
            return context.releaseChatObservationLease(
                chatID,
                observation: observation,
                subscriberID: leaseID
            )
        }

        func completeLastRelease(isolation: isolated any Actor) {
            context?.completeChatObservationClose(chatID, observation: observation)
        }
    }

    private let coordinator: CodexModelContextCoordinator
    package let appServer: CodexAppServer
    package let contextID = CodexModelContextID()

    private var workspaceGroupsByID: [CodexWorkspaceGroupID: CodexWorkspaceGroup] = [:]
    private var workspacesByID: [CodexWorkspaceID: CodexWorkspace] = [:]
    private var chatsByID: [CodexThreadID: CodexChat] = [:]
    private var turnsByID: [CodexTurnID: CodexTurn] = [:]
    private var itemsByID: [CodexChatItemID: CodexItem] = [:]
    private var fetchedResults: [WeakFetchedResultsRegistration] = []
    private var activeChatObservationsByID: [CodexThreadID: ActiveChatObservation] = [:]
    private var chatObservationGenerationByID: [CodexThreadID: UInt64] = [:]
    private var preparedEventThreadsByID: [CodexThreadID: CodexThread] = [:]

    public convenience init(_ container: CodexModelContainer) {
        self.init(coordinator: container.coordinator)
    }

    package init(coordinator: CodexModelContextCoordinator) {
        self.coordinator = coordinator
        self.appServer = coordinator.appServer
    }

    public nonisolated static func == (
        lhs: CodexModelContext,
        rhs: CodexModelContext
    ) -> Bool {
        lhs === rhs
    }

    public nonisolated(nonsending) func fetch<Model: CodexPersistentModel>(
        _ descriptor: CodexFetchDescriptor<Model>
    ) async throws -> [Model] {
        do {
            try descriptor.validate()
            let page = try await fetchPage(descriptor)
            let items = fetchedItemsIncludingPendingChanges(from: page, descriptor: descriptor)
            await syncLoadedRelationships(from: page, descriptor: descriptor, loadedItems: items)
            return items
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as CodexFetchValidationError {
            throw CodexFetchFailure.validation(failure)
        } catch let failure as CodexAppServerError {
            throw CodexFetchFailure.appServer(failure)
        }
    }

    public func fetchedResults<Model: CodexPersistentModel>(
        for descriptor: CodexFetchDescriptor<Model>,
        sectionedBy sectionBy: CodexSectionDescriptor<Model>? = nil
    ) -> CodexFetchedResults<Model> {
        let results = CodexFetchedResults(
            modelContext: self,
            fetchDescriptor: descriptor,
            sectionBy: sectionBy
        )
        register(results)
        return results
    }

    public func model(for id: CodexThreadID) -> CodexChat {
        chat(for: id)
    }

    public func registeredModel(for id: CodexThreadID) -> CodexChat? {
        chatsByID[id]
    }

    public func registeredModel(for id: CodexWorkspaceID) -> CodexWorkspace? {
        workspacesByID[id]
    }

    public func registeredModel(for id: CodexWorkspaceGroupID) -> CodexWorkspaceGroup? {
        workspaceGroupsByID[id]
    }

    private func requireAttached<Model: CodexPersistentModel>(_ model: Model) throws {
        guard model.modelContext === self else {
            throw CodexModelContextError.modelIsDetached
        }
        let isRegistered: Bool
        switch model {
        case let chat as CodexChat:
            isRegistered = chatsByID[chat.id] === chat
        case let workspace as CodexWorkspace:
            isRegistered = workspacesByID[workspace.id] === workspace
        case let group as CodexWorkspaceGroup:
            isRegistered = workspaceGroupsByID[group.id] === group
        case let turn as CodexTurn:
            isRegistered = turnsByID[turn.id] === turn
        case let item as CodexItem:
            isRegistered = itemsByID[item.id] === item
        default:
            throw CodexModelContextError.unsupportedModelType(String(describing: Model.self))
        }
        guard isRegistered else {
            throw CodexModelContextError.modelIsDetached
        }
    }

    package func turn(
        id: CodexTurnID,
        in chat: CodexChat,
        state: CodexTurnSnapshot.State? = nil,
        itemsLoadState: CodexTurnItemsLoadState? = nil,
        usage: CodexTokenUsage? = nil
    ) -> CodexTurn {
        if let turn = turnsByID[id] {
            turn.applyContextChat(chat)
            return turn
        }
        let turn = CodexTurn(
            id: id,
            chat: chat,
            modelContext: self,
            state: state,
            itemsLoadState: itemsLoadState,
            usage: usage
        )
        turnsByID[id] = turn
        return turn
    }

    package func item(
        threadItem: CodexThreadItem,
        turnID: CodexTurnID?,
        in chat: CodexChat,
        itemsLoadState: CodexTurnItemsLoadState
    ) -> CodexItem {
        let itemTurn: CodexTurn?
        if let turnID {
            itemTurn = turn(id: turnID, in: chat)
        } else {
            itemTurn = nil
        }
        let id = CodexChatItemKey(threadItem: threadItem, turnID: turnID).modelID(in: chat.id)
        if let item = itemsByID[id] {
            item.applyContextOwners(chat: chat, turn: itemTurn)
            return item
        }
        let item = CodexItem(
            threadItem: threadItem,
            chat: chat,
            turn: itemTurn,
            modelContext: self,
            itemsLoadState: itemsLoadState
        )
        itemsByID[id] = item
        return item
    }

    package func unregisterContextItem(_ item: CodexItem) {
        itemsByID = itemsByID.filter { $0.value !== item }
    }

    package func rekeyContextItem(
        _ item: CodexItem,
        from oldID: CodexChatItemID,
        to newID: CodexChatItemID
    ) {
        if itemsByID[oldID] === item {
            itemsByID.removeValue(forKey: oldID)
        }
        itemsByID[newID] = item
    }

    public nonisolated(nonsending) func refresh(_ group: CodexWorkspaceGroup) async throws {
        try requireAttached(group)

        let descriptor = CodexFetchDescriptor<CodexWorkspace>(
            sortBy: [CodexSortDescriptor(\.name)]
        )
        let previousWorkspaces = group.workspaces
        let previousChats = group.workspaces.flatMap(\.chats)
        let fetchedChats = defaultUserVisibleChats(from: try await fetchAndApplyAllThreadSnapshots(
            matching: descriptor,
            appliedArchived: archivedScope(for: descriptor) == true,
            scopedWorkspaceURL: singleWorkspaceScope(for: descriptor)
        ))
        let fetchedChatIDs = Set(fetchedChats.map(\.id))
        let chats = fetchedChats.filter { $0.workspace?.workspaceGroup?.id == group.id }
        let workspaces = unique(chats.compactMap(\.workspace))
        for workspace in unique(previousWorkspaces + workspaces) {
            let previousWorkspaceChats = workspace.chats
            let fetchedWorkspaceChats = fetchedChats.filter { $0.workspace === workspace }
            let fetchedIDs = Set(fetchedWorkspaceChats.map(\.id))
            let preservedChats = previousWorkspaceChats.filter {
                fetchedIDs.contains($0.id) == false
                    && shouldPreserveMissingRefreshChat($0, archivedScope: archivedScope(for: descriptor))
            }
            let currentChats = fetchedWorkspaceChats + preservedChats
            workspace.replaceContextChats(currentChats)
            pruneWorkspaceIfEmpty(workspace)
            _ = detachStaleChats(
                previousWorkspaceChats,
                from: workspace,
                keeping: currentChats,
                archivedScope: archivedScope(for: descriptor)
            )
        }
        let previousWorkspacesStillInGroup = previousWorkspaces.filter {
            $0.workspaceGroup?.id == group.id
        }
        let refreshedWorkspaces = workspaces.filter { $0.workspaceGroup?.id == group.id }
        let refreshedWorkspaceIDs = Set(refreshedWorkspaces.map(\.id))
        let preservedWorkspaces = previousWorkspacesStillInGroup.filter {
            refreshedWorkspaceIDs.contains($0.id) == false
                && containsPreservedMissingRefreshChat(in: $0, archivedScope: archivedScope(for: descriptor))
        }
        group.replaceContextWorkspaces(sort(refreshedWorkspaces + preservedWorkspaces, using: descriptor.sortBy))
        let currentChatIDs = Set(group.workspaces.flatMap(\.chats).map(\.id))
        let removedChats = previousChats.filter {
            currentChatIDs.contains($0.id) == false
                && fetchedChatIDs.contains($0.id) == false
                && isInRefreshedScope($0, archivedScope: archivedScope(for: descriptor))
        }
        await refreshWorkspaceGroupInRegisteredResults(
            group,
            archived: archivedScope(for: descriptor) == true,
            removedChats: removedChats
        )
    }

    public nonisolated(nonsending) func refresh(_ workspace: CodexWorkspace) async throws {
        try requireAttached(workspace)

        let descriptor = CodexFetchDescriptor<CodexChat>.chats(in: workspace)
        let previousChats = workspace.chats
        let fetchedChats = defaultUserVisibleChats(from: try await fetchAndApplyAllThreadSnapshots(
            matching: descriptor,
            appliedArchived: archivedScope(for: descriptor) == true,
            scopedWorkspaceURL: singleWorkspaceScope(for: descriptor)
        ))
        let chats = sort(
            fetchedChats,
            using: descriptor.sortBy
        )
        let refreshedIDs = Set(chats.map(\.id))
        let preservedChats = previousChats.filter {
            refreshedIDs.contains($0.id) == false
                && shouldPreserveMissingRefreshChat($0, archivedScope: archivedScope(for: descriptor))
        }
        let currentChats = chats + preservedChats
        workspace.replaceContextChats(currentChats)
        pruneWorkspaceIfEmpty(workspace)
        let removedChats = detachStaleChats(
            previousChats,
            from: workspace,
            keeping: currentChats,
            archivedScope: archivedScope(for: descriptor)
        )
        await refreshWorkspaceInRegisteredResults(
            workspace,
            archived: archivedScope(for: descriptor) == true,
            removedChats: removedChats
        )
    }

    public nonisolated(nonsending) func refresh(
        _ chat: CodexChat,
        includeTurns: Bool = true
    ) async throws {
        try requireAttached(chat)

        let stablePhase = chat.phase
        chat.beginLoading()
        do {
            let thread = try await eventThread(for: chat)
            try await refresh(chat, using: thread, includeTurns: includeTurns)
        } catch is CancellationError {
            chat.restorePhaseIfLoading(stablePhase)
            throw CancellationError()
        } catch {
            chat.fail(with: error)
            throw error
        }
    }

    private func refresh(
        _ chat: CodexChat,
        using thread: CodexThread,
        includeTurns: Bool,
        replaysBufferedEvents: Bool = true,
        emitsResynchronization: Bool = true
    ) async throws {
        let observation = activeChatObservationsByID[chat.id]
        observation?.beginBufferingEvents()
        let refreshedSnapshot: RefreshedThreadSnapshot
        do {
            refreshedSnapshot = try await Self.refreshedThreadSnapshot(
                for: thread,
                includeTurns: includeTurns
            )
        } catch {
            if replaysBufferedEvents {
                await flushBufferedEvents(from: observation, to: chat)
            } else {
                observation?.discardBufferedEvents()
            }
            throw error
        }
        await applyRefreshedThreadSnapshot(
            refreshedSnapshot,
            to: chat,
            includeTurns: includeTurns,
            observation: observation,
            replaysBufferedEvents: replaysBufferedEvents,
            emitsResynchronization: emitsResynchronization
        )
    }

    private func applyRefreshedThreadSnapshot(
        _ refreshedSnapshot: RefreshedThreadSnapshot,
        to chat: CodexChat,
        includeTurns: Bool,
        observation: ActiveChatObservation?,
        replaysBufferedEvents: Bool,
        emitsResynchronization: Bool
    ) async {
        let previousWorkspace = chat.workspace
        let previousGroup = previousWorkspace?.workspaceGroup
        let snapshot = refreshedSnapshot.snapshot
        let snapshotCanLagBehindLiveEvents = snapshotCanLagBehindLiveEvents(refreshedSnapshot)
        let chatShouldPreserveTurnItems = snapshotCanLagBehindLiveEvents
            && chat.shouldPreserveTurnItemsWhenReconcilingSnapshot
        let observationShouldPreserveTurnItems = snapshotCanLagBehindLiveEvents
            && observation?.shouldPreserveLiveTurnItems == true
        let preservesExistingTurnItems = replaysBufferedEvents
            && (chatShouldPreserveTurnItems || observationShouldPreserveTurnItems)
        if preservesExistingTurnItems {
            logger.debug(
                "Preserving live chat turn items during snapshot refresh chatID=\(chat.id.rawValue, privacy: .public) includeTurns=\(includeTurns, privacy: .public) chatHasLiveUpdates=\(chatShouldPreserveTurnItems, privacy: .public) observationHasLiveUpdates=\(observationShouldPreserveTurnItems, privacy: .public)"
            )
        }
        let refreshedChat = apply(
            snapshot,
            preservesExistingTurnItems: preservesExistingTurnItems
        )
        if includeTurns {
            refreshedChat.resetLiveMergeStateFromCurrentItems()
        }
        refreshedChat.syncPhaseAfterRefresh(includeTurns: includeTurns)
        if emitsResynchronization {
            observation?.broadcastSnapshot(chat: refreshedChat, reason: .refresh)
        }
        if replaysBufferedEvents {
            await flushBufferedEvents(from: observation, to: refreshedChat)
        } else {
            observation?.discardBufferedEvents()
        }
        await revalidateChatInRegisteredResults(
            refreshedChat,
            previousWorkspace: previousWorkspace,
            previousGroup: previousGroup,
            archived: refreshedChat.isArchived
        )
    }

    private func snapshotCanLagBehindLiveEvents(_ refreshedSnapshot: RefreshedThreadSnapshot) -> Bool {
        guard refreshedSnapshot.metadataReadCompleted,
            refreshedSnapshot.snapshot.hasField(.status),
            let status = refreshedSnapshot.snapshot.status
        else {
            return true
        }
        switch status {
        case .active,
            .unknown:
            return true
        case .idle,
            .notLoaded,
            .systemError:
            return false
        }
    }

    private static func refreshedThreadSnapshot(
        for thread: CodexThread,
        includeTurns: Bool
    ) async throws -> RefreshedThreadSnapshot {
        guard includeTurns else {
            return .init(
                snapshot: try await thread.read(includeTurns: false),
                metadataReadCompleted: true
            )
        }

        do {
            let turns = try await fullTurnList(for: thread)
            return try await threadSnapshot(
                for: thread,
                withAuthoritativeTurns: turns
            )
        } catch {
            return .init(
                snapshot: try await thread.read(includeTurns: true),
                metadataReadCompleted: true
            )
        }
    }

    private static func fullTurnList(for thread: CodexThread) async throws -> [CodexTurnSnapshot] {
        var cursor: String?
        var turns: [CodexTurnSnapshot] = []
        repeat {
            let page = try await thread.listTurns(.init(
                cursor: cursor,
                sortDirection: .ascending,
                itemsLoadState: .full
            ))
            turns.append(contentsOf: page.turns)
            cursor = page.nextCursor
        } while cursor != nil
        return turns
    }

    private static func threadSnapshot(
        for thread: CodexThread,
        withAuthoritativeTurns turns: [CodexTurnSnapshot]
    ) async throws -> RefreshedThreadSnapshot {
        do {
            let metadata = try await thread.read(includeTurns: false)
            var presentFields = metadata.presentFields
            presentFields.insert(.turns)
            return .init(
                snapshot: .init(
                    id: metadata.id,
                    workspace: metadata.workspace,
                    name: metadata.name,
                    preview: metadata.preview,
                    modelProvider: metadata.modelProvider,
                    sessionID: metadata.sessionID,
                    parentThreadID: metadata.parentThreadID,
                    source: metadata.source,
                    sourceKind: metadata.source == nil ? metadata.sourceKind : nil,
                    gitInfo: metadata.gitInfo,
                    createdAt: metadata.createdAt,
                    updatedAt: metadata.updatedAt,
                    recencyAt: metadata.recencyAt,
                    status: metadata.status,
                    ephemeral: metadata.ephemeral,
                    turns: turns,
                    turnItemsAreAuthoritative: true,
                    presentFields: presentFields
                ),
                metadataReadCompleted: true
            )
        } catch {
            if Self.isThreadNotLoadedError(error) {
                var presentFields: Set<CodexThreadSnapshot.Field> = [.status, .turns]
                if thread.workspace != nil {
                    presentFields.insert(.workspace)
                }
                return .init(
                    snapshot: .init(
                        id: thread.id,
                        workspace: thread.workspace,
                        status: .notLoaded,
                        turns: turns,
                        turnItemsAreAuthoritative: true,
                        presentFields: presentFields
                    ),
                    metadataReadCompleted: false
                )
            }
            var presentFields: Set<CodexThreadSnapshot.Field> = [.turns]
            if thread.workspace != nil {
                presentFields.insert(.workspace)
            }
            return .init(
                snapshot: .init(
                    id: thread.id,
                    workspace: thread.workspace,
                    turns: turns,
                    turnItemsAreAuthoritative: true,
                    presentFields: presentFields
                ),
                metadataReadCompleted: false
            )
        }
    }

    private static func isThreadNotLoadedError(_ error: Error) -> Bool {
        let message: String
        if case JSONRPC.Error.responseError(let serverError) = error {
            message = serverError.message
        } else if case CodexAppServerError.request(let failure) = error,
                  case .server(let serverError) = failure.kind {
            message = serverError.message
        } else {
            return false
        }
        return message.lowercased().contains("thread not loaded")
    }

    private func flushBufferedEvents(
        from observation: ActiveChatObservation?,
        to chat: CodexChat
    ) async {
        let bufferedEvents = observation?.finishBufferingEvents() ?? []
        for event in bufferedEvents {
            _ = await apply(event, to: chat)
        }
    }

    private func yield(
        _ updates: [CodexChatMutation],
        from chat: CodexChat,
        to observation: ActiveChatObservation?
    ) {
        guard let observation else {
            return
        }
        observation.yield(updates, chat: chat)
    }

    public func observe(
        _ chat: CodexChat,
        includeTurns: Bool = true,
        isolation: isolated any Actor = #isolation
    ) async throws -> CodexChatObservation {
        try requireAttached(chat)

        let activeObservation = try await activeObservation(
            for: chat,
            includeTurns: includeTurns,
            isolation: isolation
        )

        return makeChatObservation(chat: chat, activeObservation: activeObservation)
    }

    private func activeObservation(
        for chat: CodexChat,
        includeTurns: Bool,
        isolation: any Actor,
        resumedThread: CodexThread? = nil
    ) async throws -> ActiveChatObservation {
        if let observation = activeChatObservationsByID[chat.id] {
            precondition(
                observation.isolation.load() === isolation,
                "A chat observation generation must remain on its owner actor."
            )
            if observation.isFinished {
                activeChatObservationsByID.removeValue(forKey: chat.id)
            } else if observation.isClosing {
                await observation.waitUntilClosed()
                return try await activeObservation(
                    for: chat,
                    includeTurns: includeTurns,
                    isolation: isolation,
                    resumedThread: resumedThread
                )
            } else {
                return try await joinObservation(
                    observation,
                    for: chat,
                    includeTurns: includeTurns
                )
            }
        }

        let chatID = chat.id
        let generation = (chatObservationGenerationByID[chatID] ?? 0) &+ 1
        chatObservationGenerationByID[chatID] = generation
        let stablePhase = chat.phase
        chat.beginLoading()
        let observation = ActiveChatObservation(
            generation: generation,
            stablePhase: stablePhase,
            isolation: isolation
        )
        activeChatObservationsByID[chatID] = observation
        let suppliedThread: CodexThread?
        let suppliedSource: String?
        let usesPreparedThread: Bool
        if let resumedThread {
            suppliedThread = resumedThread
            suppliedSource = "resumedThread"
            usesPreparedThread = false
        } else if let preparedThread = takePreparedEventThread(for: chatID) {
            suppliedThread = preparedThread
            suppliedSource = "preparedEventThread"
            usesPreparedThread = true
        } else {
            suppliedThread = nil
            suppliedSource = nil
            usesPreparedThread = false
        }
        let appServer = appServer
        observation.startOperation = ChatObservationStartOperation {
            do {
                let thread: CodexThread
                let source: String
                if let suppliedThread, let suppliedSource {
                    thread = suppliedThread
                    source = suppliedSource
                } else {
                    thread = try await appServer.resumeThread(chatID)
                    source = "resumeThread"
                }
                try Task.checkCancellation()
                let eventStream = usesPreparedThread
                    ? nil
                    : thread.makeCurrentGenerationEventStream()
                let snapshot: ChatObservationStartSnapshot
                do {
                    snapshot = .loaded(try await Self.refreshedThreadSnapshot(
                        for: thread,
                        includeTurns: includeTurns
                    ))
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as CodexAppServerError {
                    snapshot = .failed(error)
                }
                try Task.checkCancellation()
                return .loaded(.init(
                    thread: thread,
                    source: source,
                    usesPreparedThread: usesPreparedThread,
                    includesTurns: includeTurns,
                    eventStream: eventStream,
                    snapshot: snapshot
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CodexAppServerError {
                return .failed(error)
            }
        }
        return try await joinObservation(
            observation,
            for: chat,
            includeTurns: includeTurns
        )
    }

    private func joinObservation(
        _ observation: ActiveChatObservation,
        for chat: CodexChat,
        includeTurns: Bool
    ) async throws -> ActiveChatObservation {
        observation.pendingRegistrationCount += 1
        do {
            guard let startOperation = observation.startOperation else {
                preconditionFailure("A starting observation must own its start operation.")
            }
            let outcome = try await startOperation.value()
            try await commitObservationStartIfNeeded(
                outcome,
                observation: observation,
                chat: chat
            )
            try Task.checkCancellation()
            if observation.isFinished {
                precondition(observation.pendingRegistrationCount > 0)
                observation.pendingRegistrationCount -= 1
                return observation
            }
            if includeTurns, observation.includesTurns == false {
                try await upgradeObservation(observation, for: chat)
            }
            try Task.checkCancellation()
            precondition(observation.pendingRegistrationCount > 0)
            observation.pendingRegistrationCount -= 1
            return observation
        } catch {
            precondition(observation.pendingRegistrationCount > 0)
            observation.pendingRegistrationCount -= 1
            await cancelUnclaimedObservationIfNeeded(
                chat.id,
                observation: observation
            )
            throw error
        }
    }

    private func commitObservationStartIfNeeded(
        _ outcome: ChatObservationStartOutcome,
        observation: ActiveChatObservation,
        chat: CodexChat
    ) async throws {
        if observation.isStarting == false {
            return
        }
        if observation.isCommittingStart {
            try await observation.waitUntilStarted()
            return
        }
        observation.isCommittingStart = true
        defer { observation.isCommittingStart = false }

        switch outcome {
        case .failed(let error):
            finishObservationStartWithFailure(
                error,
                observation: observation,
                chat: chat
            )
        case .loaded(let load):
            logger.debug(
                "Starting chat observation chatID=\(chat.id.rawValue, privacy: .public) includeTurns=\(load.includesTurns, privacy: .public) source=\(load.source, privacy: .public) turns=\(chat.turns.count, privacy: .public) items=\(chat.items.count, privacy: .public)"
            )
            observation.eventThread = load.thread
            switch load.snapshot {
            case .loaded(let refreshedSnapshot):
                await applyRefreshedThreadSnapshot(
                    refreshedSnapshot,
                    to: chat,
                    includeTurns: load.includesTurns,
                    observation: observation,
                    replaysBufferedEvents: true,
                    emitsResynchronization: false
                )
            case .failed(let error):
                guard canObserveSeededSnapshotAfterInitialRefreshFailure(
                    chat,
                    usesPreparedThread: load.usesPreparedThread,
                    includeTurns: load.includesTurns
                ) else {
                    finishObservationStartWithFailure(
                        error,
                        observation: observation,
                        chat: chat
                    )
                    return
                }
                chat.syncPhaseAfterRefresh(includeTurns: load.includesTurns)
            }
            if load.usesPreparedThread,
               shouldResetPreparedEventGenerationBeforeObserving(
                   chat,
                   includeTurns: load.includesTurns
               ) {
                load.thread.beginEventGeneration()
            }
            let eventStream = load.eventStream
                ?? load.thread.makeCurrentGenerationEventStream()
            startEventPump(
                observation,
                thread: load.thread,
                eventStream: eventStream
            )
            observation.includesTurns = load.includesTurns
            observation.finishStarting()
        }
    }

    private func finishObservationStartWithFailure(
        _ error: CodexAppServerError,
        observation: ActiveChatObservation,
        chat: CodexChat
    ) {
        chat.fail(with: error)
        observation.finishSnapshotReason = .upstreamFailure
        observation.isFinished = true
        if observation.isStarting {
            observation.finishStarting()
        }
        observation.releaseSignal.terminate()
        activeChatObservationsByID.removeValue(forKey: chat.id)
    }

    private func cancelUnclaimedObservationIfNeeded(
        _ chatID: CodexThreadID,
        observation: ActiveChatObservation
    ) async {
        guard observation.pendingRegistrationCount == 0,
              observation.subscribers.isEmpty,
              activeChatObservationsByID[chatID] === observation
        else {
            return
        }
        chat(for: chatID).restorePhaseIfLoading(observation.stablePhase)
        await observation.startOperation?.cancelAndWait()
        observation.releaseSignal.terminate()
        await observation.eventPump?.cancelAndWait()
        discardChatObservation(chatID, observation: observation)
    }

    private func upgradeObservation(
        _ observation: ActiveChatObservation,
        for chat: CodexChat
    ) async throws {
        if observation.includesTurns { return }
        if observation.isUpgrading {
            try await observation.waitUntilUpgradeFinishes()
            return
        }
        guard let thread = observation.eventThread else {
            preconditionFailure("An active chat observation must own its event thread.")
        }
        observation.isUpgrading = true
        do {
            try await refresh(
                chat,
                using: thread,
                includeTurns: true,
                emitsResynchronization: false
            )
            observation.includesTurns = true
            observation.broadcastSnapshot(chat: chat, reason: .includeTurnsUpgrade)
            observation.finishUpgrade()
        } catch {
            observation.finishUpgrade(with: error)
            throw error
        }
    }

    private func startEventPump(
        _ observation: ActiveChatObservation,
        thread: CodexThread,
        eventStream: CodexThreadEventSequence
    ) {
        observation.eventStream = eventStream
        observation.eventPump = ThreadEventPump(
            context: self,
            chatID: thread.id,
            observation: observation,
            stream: eventStream,
            releaseSignal: observation.releaseSignal,
            isolation: observation.isolation
        )
    }

    private func shouldResetPreparedEventGenerationBeforeObserving(
        _ chat: CodexChat,
        includeTurns: Bool
    ) -> Bool {
        guard includeTurns else {
            return false
        }
        if chat.phase == .loading || chat.status?.isActive == true {
            return false
        }
        if case .running = chat.phase {
            return false
        }
        return true
    }

    private func applyObservedEvent(
        _ event: CodexThreadEvent,
        to chat: CodexChat,
        observation: ActiveChatObservation
    ) async {
        if observation.isBufferingEvents {
            observation.appendBufferedEvent(event)
            return
        }
        _ = await apply(event, to: chat)
    }

    private func processObservedEvent(
        _ event: CodexThreadEvent,
        chatID: CodexThreadID,
        observation: ActiveChatObservation
    ) async {
        guard observation.isFinished == false else {
            return
        }
        guard let chat = registeredModel(for: chatID) else {
            finishChatObservationIfIdle(chatID, observation: observation)
            return
        }
        await applyObservedEvent(event, to: chat, observation: observation)
    }

    private func failChatObservation(
        _ chatID: CodexThreadID,
        observation: ActiveChatObservation,
        error: Error
    ) async {
        if let chat = registeredModel(for: chatID) {
            chat.fail(with: error)
            observation.finishSnapshotReason = .upstreamFailure
            observation.broadcastSnapshot(
                chat: chat,
                reason: .upstreamFailure
            )
        }
        finishChatObservationIfIdle(chatID, observation: observation)
    }

    private func canObserveSeededSnapshotAfterInitialRefreshFailure(
        _ chat: CodexChat,
        usesPreparedThread: Bool,
        includeTurns: Bool
    ) -> Bool {
        includeTurns
            && usesPreparedThread
            && chat.turns.isEmpty == false
    }

    private func releaseChatObservationLease(
        _ chatID: CodexThreadID,
        observation: ActiveChatObservation,
        subscriberID: UUID
    ) -> Bool {
        guard activeChatObservationsByID[chatID] === observation else {
            observation.removeSubscriber(subscriberID)
            return observation.subscribers.isEmpty
        }
        observation.removeSubscriber(subscriberID)
        if observation.subscribers.isEmpty == false {
            return false
        }
        observation.isClosing = true
        return true
    }

    private func completeChatObservationClose(
        _ chatID: CodexThreadID,
        observation: ActiveChatObservation
    ) {
        observation.isFinished = true
        observation.finishClosing()
        if activeChatObservationsByID[chatID] === observation {
            activeChatObservationsByID.removeValue(forKey: chatID)
        }
    }

    private func finishChatObservationIfIdle(
        _ chatID: CodexThreadID,
        observation: ActiveChatObservation
    ) {
        guard activeChatObservationsByID[chatID] === observation else {
            return
        }
        observation.isFinished = true
        observation.finishSubscribers()
        observation.releaseSignal.terminate()
        observation.finishClosing()
        activeChatObservationsByID.removeValue(forKey: chatID)
    }

    private func discardChatObservation(
        _ chatID: CodexThreadID,
        observation: ActiveChatObservation
    ) {
        guard activeChatObservationsByID[chatID] === observation else {
            return
        }
        observation.cancel()
        activeChatObservationsByID.removeValue(forKey: chatID)
    }

    private func makeChatObservation(
        chat: CodexChat,
        activeObservation: ActiveChatObservation
    ) -> CodexChatObservation {
        let (subscriberID, updates) = activeObservation.makeSubscriber(chat: chat)
        return CodexChatObservation(
            chat: chat,
            updates: updates,
            leaseID: subscriberID,
            modelContext: self,
            releaseSignal: activeObservation.releaseSignal
        )
    }

    private func prepareEventThread(_ thread: CodexThread, for chatID: CodexThreadID) {
        if let observation = activeChatObservationsByID[chatID],
            observation.isFinished == false
        {
            observation.eventThread = observation.eventThread ?? thread
            preparedEventThreadsByID.removeValue(forKey: chatID)
        } else {
            preparedEventThreadsByID[chatID] = thread
        }
    }

    private func preparedEventThread(for chatID: CodexThreadID) -> CodexThread? {
        preparedEventThreadsByID[chatID]
    }

    private func takePreparedEventThread(for chatID: CodexThreadID) -> CodexThread? {
        preparedEventThreadsByID.removeValue(forKey: chatID)
    }

    private func eventThread(for chat: CodexChat) async throws -> CodexThread {
        try requireAttached(chat)
        if let thread = activeChatObservationsByID[chat.id]?.eventThread {
            return thread
        }
        if let thread = takePreparedEventThread(for: chat.id) {
            return thread
        }
        let thread = try await appServer.resumeThread(chat.id)
        return thread
    }

    @discardableResult
    public nonisolated(nonsending) func startChat(
        in workspace: CodexWorkspace,
        input: CodexChatInput = .init()
    ) async throws -> CodexChat {
        try requireAttached(workspace)
        let thread = try await appServer.startThread(
            in: workspace.url,
            instructions: input.instructions,
            options: input.options
        )
        let now = Date()
        let snapshot = CodexThreadSnapshot(
            id: thread.id,
            workspace: thread.workspace,
            modelProvider: input.options.modelProvider,
            source: .appServer,
            createdAt: now,
            updatedAt: now,
            ephemeral: input.options.ephemeral
        )
        let chat = apply(snapshot)
        chat.preserveSeededMetadataUntilAuthoritativeSnapshot()
        chat.applyContextArchived(false)
        prepareEventThread(thread, for: chat.id)
        workspace.moveContextChatToFront(chat)
        await insertChatIntoRegisteredResults(chat, archived: false)
        return chat
    }

    @discardableResult
    public nonisolated(nonsending) func startReview(
        in workspace: URL,
        input: CodexReviewInput
    ) async throws -> CodexStartedReview {
        let review = try await appServer.startReview(
            in: workspace,
            target: input.target,
            instructions: input.instructions,
            options: input.options,
            delivery: input.delivery
        )
        return await applyStartedReview(
            review,
            workspaceURL: workspace,
            input: input
        )
    }

    @discardableResult
    public nonisolated(nonsending) func startReview(
        in workspace: CodexWorkspace,
        input: CodexReviewInput
    ) async throws -> CodexStartedReview {
        try requireAttached(workspace)
        return try await startReview(in: workspace.url, input: input)
    }

    private func applyStartedReview(
        _ review: CodexReviewSession,
        workspaceURL: URL,
        input: CodexReviewInput
    ) async -> CodexStartedReview {
        let eventThread = await appServer.reviewEventThread(
            for: review,
            workspace: workspaceURL
        )
        let isExistingChat = chatsByID[review.activeTurnThreadID] != nil
        let now = Date()
        let change = CodexStartedReviewContextChange(
            snapshot: CodexThreadSnapshot(
                id: review.activeTurnThreadID,
                workspace: eventThread.workspace ?? workspaceURL,
                preview: input.target.dataKitPreview,
                modelProvider: input.options.modelProvider,
                source: .subAgent(.review),
                createdAt: now,
                updatedAt: now,
                recencyAt: now,
                status: .active(activeFlags: []),
                ephemeral: input.options.ephemeral,
                turns: [review.initialTurn],
                turnItemsAreAuthoritative: false
            ),
            eventThread: eventThread,
            archived: false,
            provisionalSeedTurnID: review.initialTurn.id
        )
        let chat = await applyStartedReview(change)
        await coordinator.multicast(
            CodexModelContextTransaction(startedReviews: [change]),
            from: contextID
        )
        logger.debug(
            "Started review chat chatID=\(chat.id.rawValue, privacy: .public) reusedExistingChat=\(isExistingChat, privacy: .public) initialTurns=\(chat.turns.count, privacy: .public) initialItems=\(chat.items.count, privacy: .public)"
        )
        return CodexStartedReview(chat: chat, session: review)
    }

    @discardableResult
    private func applyStartedReview(_ change: CodexStartedReviewContextChange) async -> CodexChat {
        let chat = apply(change.snapshot)
        chat.preserveSeededMetadataUntilAuthoritativeSnapshot()
        if let provisionalSeedTurnID = change.provisionalSeedTurnID {
            chat.markProvisionalSeedTurn(provisionalSeedTurnID)
        }
        chat.applyContextArchived(change.archived)
        chat.syncPhaseAfterRefresh(includeTurns: change.snapshot.hasField(.turns))
        prepareEventThread(change.eventThread, for: chat.id)
        chat.workspace?.moveContextChatToFront(chat)
        await insertChatIntoRegisteredResults(chat, archived: change.archived)
        return chat
    }

    package func merge(_ transaction: CodexModelContextTransaction) async {
        for change in transaction.startedReviews {
            await applyStartedReview(change)
        }
    }

    @discardableResult
    public nonisolated(nonsending) func send(
        _ input: CodexChatMessageInput,
        in chat: CodexChat
    ) async throws -> CodexTurnOutcome {
        try requireAttached(chat)
        let thread = try await eventThread(for: chat)
        switch try await thread.collectResponse(to: input.prompt, options: input.options) {
        case .outcome(let outcome):
            await apply(outcome, to: chat)
            return outcome
        case .cancelled(let outcome):
            await apply(outcome, to: chat)
            throw CancellationError()
        }
    }

    @discardableResult
    package func apply(_ outcome: CodexTurnOutcome, to chat: CodexChat) async -> [CodexChatMutation] {
        let previousWorkspace = chat.workspace
        let previousGroup = previousWorkspace?.workspaceGroup
        let previousUpdatedAt = chat.updatedAt
        let changes = chat.apply(outcome)
        if let workspace = chat.workspace,
            let updatedAt = chat.updatedAt,
            previousUpdatedAt.map({ updatedAt > $0 }) ?? true
        {
            workspace.moveContextChatToFront(chat)
        }
        let observation = activeChatObservationsByID[chat.id]
        observation?.markAppliedLiveUpdates()
        yield(changes, from: chat, to: observation)
        await revalidateChatInRegisteredResults(
            chat,
            previousWorkspace: previousWorkspace,
            previousGroup: previousGroup,
            archived: chat.isArchived
        )
        return changes
    }

    package func syncPhaseAfterSend(in chat: CodexChat) async {
        guard let change = chat.syncPhaseWithTurnsAfterRefresh() else {
            return
        }
        yield([change], from: chat, to: activeChatObservationsByID[chat.id])
    }

    @discardableResult
    package func apply(_ event: CodexThreadEvent, to chat: CodexChat) async -> [CodexChatMutation] {
        let previousWorkspace = chat.workspace
        let previousGroup = previousWorkspace?.workspaceGroup
        let previousState = fetchedResultState(for: chat)
        let previousUpdatedAt = chat.updatedAt
        let changes = chat.apply(event)
        if let workspace = chat.workspace,
            let updatedAt = chat.updatedAt,
            previousUpdatedAt.map({ updatedAt > $0 }) ?? true
        {
            workspace.moveContextChatToFront(chat)
        }
        let observation = activeChatObservationsByID[chat.id]
        observation?.markAppliedLiveUpdates()
        yield(changes, from: chat, to: observation)
        if previousState != fetchedResultState(for: chat) {
            await revalidateChatInRegisteredResults(
                chat,
                previousWorkspace: previousWorkspace,
                previousGroup: previousGroup,
                archived: chat.isArchived
            )
        }
        return changes
    }

    public nonisolated(nonsending) func cancelActiveTurn(in chat: CodexChat) async throws {
        try requireAttached(chat)
        let thread = try await eventThread(for: chat)
        _ = try await thread.cancelActiveTurn()
    }

    public nonisolated(nonsending) func archive(_ chat: CodexChat) async throws {
        try requireAttached(chat)
        try await appServer.archiveThread(chat.id)
        let workspace = chat.workspace
        let group = workspace?.workspaceGroup
        preparedEventThreadsByID.removeValue(forKey: chat.id)
        if let workspace {
            detach(chat, from: workspace)
        }
        chat.applyContextArchived(true)
        await archiveChatInRegisteredResults(chat, workspace: workspace, group: group)
    }

    public nonisolated(nonsending) func unarchive(_ chat: CodexChat) async throws {
        try requireAttached(chat)
        let previousWorkspace = chat.workspace
        let previousGroup = previousWorkspace?.workspaceGroup
        var snapshot = try await appServer.unarchiveThreadSnapshot(chat.id)
        if snapshot.hasField(.workspace) == false,
            let previousWorkspace
        {
            snapshot = snapshotForApply(snapshot, scopedWorkspaceURL: previousWorkspace.url)
        }
        let restoredChat = apply(snapshot, archived: false)
        await revalidateChatInRegisteredResults(
            restoredChat,
            previousWorkspace: previousWorkspace,
            previousGroup: previousGroup,
            archived: false
        )
    }

    public nonisolated(nonsending) func delete(_ chat: CodexChat) async throws {
        try requireAttached(chat)
        try await appServer.deleteThread(chat.id)
        await remove(chat)
    }

    package func fetchPage<Model: CodexPersistentModel>(
        _ descriptor: CodexFetchDescriptor<Model>,
        cursor: String? = nil,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async throws -> CodexFetchPage<Model> {
        try descriptor.validate()
        if Model.self == CodexChat.self {
            let page = try await fetchChatPage(
                descriptor as! CodexFetchDescriptor<CodexChat>,
                cursor: cursor,
                excluding: excludedRegistration
            )
            return CodexFetchPage(
                items: page.items.map { $0 as! Model },
                nextCursor: page.nextCursor,
                backwardsCursor: page.backwardsCursor,
                relationshipItems: page.relationshipItems?.map { $0 as! Model },
                relationshipIsComplete: page.relationshipIsComplete
            )
        }
        if Model.self == CodexWorkspace.self {
            let page = try await fetchWorkspacePage(
                descriptor as! CodexFetchDescriptor<CodexWorkspace>,
                cursor: cursor,
                excluding: excludedRegistration
            )
            return CodexFetchPage(
                items: page.items.map { $0 as! Model },
                nextCursor: page.nextCursor,
                backwardsCursor: page.backwardsCursor,
                relationshipItems: page.relationshipItems?.map { $0 as! Model },
                relationshipIsComplete: page.relationshipIsComplete
            )
        }
        if Model.self == CodexWorkspaceGroup.self {
            let page = try await fetchWorkspaceGroupPage(
                descriptor as! CodexFetchDescriptor<CodexWorkspaceGroup>,
                cursor: cursor,
                excluding: excludedRegistration
            )
            return CodexFetchPage(
                items: page.items.map { $0 as! Model },
                nextCursor: page.nextCursor,
                backwardsCursor: page.backwardsCursor,
                relationshipItems: page.relationshipItems?.map { $0 as! Model },
                relationshipIsComplete: page.relationshipIsComplete
            )
        }
        throw CodexModelContextError.unsupportedModelType(String(describing: Model.self))
    }

    package func sections<Model: CodexPersistentModel>(
        for items: [Model],
        sectionBy: CodexSectionDescriptor<Model>?
    ) -> [CodexFetchSection<Model>] {
        guard items.isEmpty == false else {
            return []
        }
        guard let sectionBy else {
            return [CodexFetchSection(id: .default, title: nil, items: items)]
        }

        var grouped: [(id: CodexFetchSectionID, title: String, items: [Model])] = []
        for item in items {
            let section = sectionIdentity(for: item, descriptor: sectionBy)
            if let index = grouped.firstIndex(where: { $0.id == section.id }) {
                grouped[index].items.append(item)
            } else {
                grouped.append((id: section.id, title: section.title, items: [item]))
            }
        }
        return grouped.map {
            CodexFetchSection(id: $0.id, title: $0.title, items: $0.items)
        }
    }

    package func sortedItems<Model: CodexPersistentModel>(
        _ items: [Model],
        for descriptor: CodexFetchDescriptor<Model>
    ) -> [Model] {
        if Model.self == CodexChat.self {
            let descriptor = descriptor as! CodexFetchDescriptor<CodexChat>
            return sortLocallyFetchedChats(
                items as! [CodexChat],
                using: descriptor
            ).map { $0 as! Model }
        }
        if Model.self == CodexWorkspace.self {
            let descriptor = descriptor as! CodexFetchDescriptor<CodexWorkspace>
            return sort(items as! [CodexWorkspace], using: descriptor.sortBy).map {
                $0 as! Model
            }
        }
        if Model.self == CodexWorkspaceGroup.self {
            let descriptor = descriptor as! CodexFetchDescriptor<CodexWorkspaceGroup>
            return sort(items as! [CodexWorkspaceGroup], using: descriptor.sortBy).map {
                $0 as! Model
            }
        }
        return items
    }

    package func fetchedItemsIncludingPendingChanges<Model: CodexPersistentModel>(
        from page: CodexFetchPage<Model>,
        descriptor: CodexFetchDescriptor<Model>,
        existingItems: [Model] = []
    ) -> [Model] {
        guard Model.self == CodexChat.self else {
            return page.items
        }
        let preservedChats = preservedLiveChats(
            omittedFrom: page.items,
            descriptor: descriptor
        )
        guard preservedChats.isEmpty == false else {
            return page.items
        }
        logger.debug(
            "Keeping live chats omitted from fetched page preservedCount=\(preservedChats.count, privacy: .public) pageCount=\(page.items.count, privacy: .public)"
        )
        let chatDescriptor = descriptor as! CodexFetchDescriptor<CodexChat>
        let mergedChats = mergePreservedLiveChats(
            preservedChats,
            into: page.items as! [CodexChat],
            existingChats: existingItems as? [CodexChat] ?? [],
            descriptor: chatDescriptor
        )
        return mergedChats.map { $0 as! Model }
    }

    private func mergePreservedLiveChats(
        _ preservedChats: [CodexChat],
        into pageChats: [CodexChat],
        existingChats: [CodexChat],
        descriptor: CodexFetchDescriptor<CodexChat>
    ) -> [CodexChat] {
        var result = pageChats
        let existingIndexes = Dictionary(
            uniqueKeysWithValues: existingChats.enumerated().map { ($0.element.id, $0.offset) }
        )
        let orderedPreservedChats = preservedChats.sorted { lhs, rhs in
            switch (existingIndexes[lhs.id], existingIndexes[rhs.id]) {
            case (.some(let lhsIndex), .some(let rhsIndex)):
                return lhsIndex < rhsIndex
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                if descriptor.sortBy.isEmpty {
                    return lhs.id.rawValue < rhs.id.rawValue
                }
                return liveChatShouldSortBefore(lhs, rhs, descriptor: descriptor)
            }
        }
        for chat in orderedPreservedChats {
            let insertionIndex = min(
                existingIndexes[chat.id]
                    ?? liveChatInsertionIndex(for: chat, in: result, descriptor: descriptor),
                result.count
            )
            result.insert(chat, at: insertionIndex)
        }
        return sortLocallyFetchedChats(result, using: descriptor)
    }

    private func liveChatInsertionIndex(
        for chat: CodexChat,
        in chats: [CodexChat],
        descriptor: CodexFetchDescriptor<CodexChat>
    ) -> Int {
        chats.firstIndex { existing in
            liveChatShouldSortBefore(chat, existing, descriptor: descriptor)
        } ?? chats.count
    }

    private func liveChatShouldSortBefore(
        _ lhs: CodexChat,
        _ rhs: CodexChat,
        descriptor: CodexFetchDescriptor<CodexChat>
    ) -> Bool {
        guard descriptor.sortBy.isEmpty == false else {
            return false
        }
        let plans = descriptor.sortBy.map(CodexSortPlan.afterValidation)
        return shouldSortBefore(
            lhs,
            rhs,
            using: plans,
            stableID: { $0.id.rawValue },
            tieBreakOrder: plans[0].order
        ) { plan, lhs, rhs in
            plan.compare(lhs, rhs)
        }
    }

    package func backfillCursor(after itemCount: Int, currentCursor: String?) -> String? {
        guard currentCursor?.hasPrefix(Self.localCursorPrefix) == true else {
            return currentCursor
        }
        return localCursor(for: itemCount)
    }

    private func fetchChatPage(
        _ descriptor: CodexFetchDescriptor<CodexChat>,
        cursor: String?,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async throws
        -> CodexFetchPage<CodexChat>
    {
        let plan = try CodexThreadQueryPlan(descriptor: descriptor)
        if canUseBoundedCompositeRecencyPage(
            for: descriptor,
            plan: plan,
            cursor: cursor
        ) {
            if let page = try await fetchBoundedCompositeRecencyPage(
                matching: descriptor,
                plan: plan,
                cursor: cursor,
                excluding: excludedRegistration
            ) {
                return page
            }
        }
        if canUseServerOrderedPages(for: descriptor, cursor: cursor) == false {
            let fetchedChats = try await fetchAllChats(
                matching: descriptor,
                plan: plan,
                excluding: excludedRegistration
            )
            let chats = sortLocallyFetchedChats(fetchedChats, using: descriptor)
            let page = localPage(chats, for: descriptor, cursor: cursor)
            return CodexFetchPage(
                items: page.items,
                nextCursor: page.nextCursor,
                backwardsCursor: page.backwardsCursor,
                relationshipItems: chats,
                relationshipIsComplete: true
            )
        }

        let query = plan.threadQuery(cursor: cursor, includePaging: true)
        let page = try await appServer.listThreads(query)
        try Task.checkCancellation()
        let fetchedChats = await applyFetchedSnapshots(
            coalescedThreadCandidates(page.threads, sourceKinds: query.sourceKinds),
            archived: plan.archived == true,
            scopedWorkspaceURL: plan.singleWorkspace,
            excluding: excludedRegistration
        ).filter { plan.matchesServerResponse($0) }
        let chats = sort(
            fetchedChats,
            using: descriptor.sortBy
        )
        return CodexFetchPage(
            items: chats,
            nextCursor: page.nextCursor,
            backwardsCursor: page.backwardsCursor
        )
    }

    private func coalescedThreadCandidates(
        _ snapshots: [CodexThreadSnapshot],
        sourceKinds: [CodexThreadSourceKind]?
    ) -> [FetchedThreadCandidate] {
        var candidates: [FetchedThreadCandidate] = []
        var indexesByID: [CodexThreadID: Int] = [:]
        for snapshot in snapshots {
            if let index = indexesByID[snapshot.id] {
                candidates[index].append(snapshot: snapshot, sourceKinds: sourceKinds)
            } else {
                indexesByID[snapshot.id] = candidates.count
                candidates.append(FetchedThreadCandidate(
                    snapshot: snapshot,
                    sourceKinds: sourceKinds
                ))
            }
        }
        return candidates
    }

    private func fetchBoundedCompositeRecencyPage(
        matching descriptor: CodexFetchDescriptor<CodexChat>,
        plan: CodexThreadQueryPlan,
        cursor: String?,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)?
    ) async throws -> CodexFetchPage<CodexChat>? {
        guard let limit = descriptor.fetchLimit, limit > 0 else {
            preconditionFailure("A bounded composite page requires a positive fetch limit.")
        }
        let requestedOffset = cursor == nil
            ? descriptor.normalizedFetchOffset
            : localCursorOffset(from: cursor)
        let (candidateLimit, overflow) = requestedOffset.addingReportingOverflow(limit)
        precondition(overflow == false, "The composite page offset and limit must fit in Int.")

        var candidates: [FetchedThreadCandidate] = []
        var indexesByID: [CodexThreadID: Int] = [:]
        var hasUnfetchedCandidates = false
        let baseQuery = plan.threadQuery(cursor: nil, includePaging: true)
        for sourceKinds in plan.candidateSourceScope.sourceKindFilters {
            var query = baseQuery
            query.sourceKinds = sourceKinds
            let partition = try await fetchBoundedThreadSnapshots(
                query: query,
                limit: candidateLimit
            )
            for snapshot in partition.snapshots {
                if let index = indexesByID[snapshot.id] {
                    candidates[index].append(snapshot: snapshot, sourceKinds: sourceKinds)
                } else {
                    indexesByID[snapshot.id] = candidates.count
                    candidates.append(FetchedThreadCandidate(
                        snapshot: snapshot,
                        sourceKinds: sourceKinds
                    ))
                }
            }
            hasUnfetchedCandidates = hasUnfetchedCandidates || partition.hasMore
        }

        let requiresExhaustiveFallback = candidates.contains { candidate in
            let initialResolution = chatsByID[candidate.id]?.threadSourceResolution ?? .unresolved
            return candidate.hasMultipleOccurrences
                || plan.candidateSourceScope.matches(
                    candidate.sourceResolution(startingAt: initialResolution)
                ) == false
        }
        guard requiresExhaustiveFallback == false else {
            return nil
        }

        let sortOrder = plan.sortPlans[0].order
        candidates.sort { lhs, rhs in
            threadSnapshot(
                lhs.latestSnapshot,
                sortsBefore: rhs.latestSnapshot,
                byRecencyIn: sortOrder
            )
        }

        let start = min(requestedOffset, candidates.count)
        let end = min(start + limit, candidates.count)
        let pageCandidates = Array(candidates[start..<end])
        let hasNextPage = end < candidates.count || hasUnfetchedCandidates
        precondition(
            pageCandidates.isEmpty == false || hasNextPage == false,
            "A composite page cursor must advance while more candidates remain."
        )

        try Task.checkCancellation()
        let chats = await applyFetchedSnapshots(
            pageCandidates,
            archived: plan.archived == true,
            scopedWorkspaceURL: plan.singleWorkspace,
            excluding: excludedRegistration
        )
        let relationshipIsComplete = hasNextPage == false
            && descriptor.normalizedFetchOffset == 0
        let previousStart = max(0, start - limit)
        return CodexFetchPage(
            items: chats,
            nextCursor: hasNextPage ? localCursor(for: end) : nil,
            backwardsCursor: start > 0 ? localCursor(for: previousStart) : nil,
            relationshipItems: relationshipIsComplete && start == 0 ? chats : nil,
            relationshipIsComplete: relationshipIsComplete
        )
    }

    private func fetchBoundedThreadSnapshots(
        query baseQuery: CodexThreadQuery,
        limit: Int
    ) async throws -> (snapshots: [CodexThreadSnapshot], hasMore: Bool) {
        var snapshots: [CodexThreadSnapshot] = []
        var cursor: String?
        var seenCursors: Set<String> = []

        while snapshots.count < limit {
            try Task.checkCancellation()
            var query = baseQuery
            query.cursor = cursor
            query.limit = limit - snapshots.count
            let page = try await appServer.listThreads(query)
            let remainingCount = limit - snapshots.count
            snapshots.append(contentsOf: page.threads.prefix(remainingCount))

            if let nextCursor = page.nextCursor {
                precondition(
                    nextCursor != cursor && seenCursors.insert(nextCursor).inserted,
                    "The app-server returned a repeated thread-list cursor."
                )
                precondition(
                    page.threads.isEmpty == false,
                    "The app-server returned a non-advancing empty thread-list page."
                )
            }

            if page.threads.count > remainingCount {
                return (snapshots, true)
            }
            guard snapshots.count < limit else {
                return (snapshots, page.nextCursor != nil)
            }
            guard let nextCursor = page.nextCursor else {
                return (snapshots, false)
            }
            cursor = nextCursor
        }

        return (snapshots, false)
    }

    private func threadSnapshot(
        _ lhs: CodexThreadSnapshot,
        sortsBefore rhs: CodexThreadSnapshot,
        byRecencyIn order: SortOrder
    ) -> Bool {
        switch (lhs.recencyAt, rhs.recencyAt) {
        case (.some(let lhsDate), .some(let rhsDate)) where lhsDate != rhsDate:
            return order == .forward ? lhsDate < rhsDate : lhsDate > rhsDate
        case (.none, .some):
            return order == .forward
        case (.some, .none):
            return order == .reverse
        case (.some, .some), (.none, .none):
            break
        }
        return order == .forward
            ? lhs.id.rawValue < rhs.id.rawValue
            : lhs.id.rawValue > rhs.id.rawValue
    }

    private func fetchAllChats(
        matching descriptor: CodexFetchDescriptor<CodexChat>,
        plan: CodexThreadQueryPlan,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async throws -> [CodexChat] {
        var chats: [CodexChat] = []
        for archived in plan.archiveScopes {
            let fetchedChats = try await fetchAndApplyAllThreadSnapshots(
                matching: descriptor,
                archiveScope: archived,
                appliedArchived: archived,
                scopedWorkspaceURL: plan.singleWorkspace,
                excluding: excludedRegistration
            )
            chats.append(contentsOf: fetchedChats.filter { plan.matchesServerResponse($0) })
        }
        return unique(chats)
    }

    private func fetchWorkspacePage(
        _ descriptor: CodexFetchDescriptor<CodexWorkspace>,
        cursor: String?,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async throws -> CodexFetchPage<CodexWorkspace> {
        let chats = defaultUserVisibleChats(from: try await fetchAndApplyAllThreadSnapshots(
            matching: descriptor,
            appliedArchived: archivedScope(for: descriptor) == true,
            scopedWorkspaceURL: singleWorkspaceScope(for: descriptor),
            excluding: excludedRegistration
        ))
        let relationshipChats = chats + preservedLiveChatsForFetchedRelationships(
            omittedFrom: chats,
            descriptor: descriptor,
            requiresIncludeContextChanges: true
        )
        let removedChats = syncWorkspaceChats(
            chats,
            preservingExisting: shouldPreserveExistingWorkspaceChats(
                for: descriptor,
                relationshipIsComplete: true
            ),
            workspaceFilters: workspaceFilters(for: descriptor),
            archivedScope: archivedScope(for: descriptor)
        )
        await removeChatsFromRegisteredResults(removedChats, excluding: excludedRegistration)
        let workspaces = unique(relationshipChats.compactMap(\.workspace))
        let sortedWorkspaces = sort(workspaces, using: descriptor.sortBy)
        let page = localPage(sortedWorkspaces, for: descriptor, cursor: cursor)
        return CodexFetchPage(
            items: page.items,
            nextCursor: page.nextCursor,
            backwardsCursor: page.backwardsCursor,
            relationshipItems: sortedWorkspaces,
            relationshipIsComplete: true
        )
    }

    private func fetchWorkspaceGroupPage(
        _ descriptor: CodexFetchDescriptor<CodexWorkspaceGroup>,
        cursor: String?,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async throws -> CodexFetchPage<CodexWorkspaceGroup> {
        let chats = defaultUserVisibleChats(from: try await fetchAndApplyAllThreadSnapshots(
            matching: descriptor,
            appliedArchived: archivedScope(for: descriptor) == true,
            scopedWorkspaceURL: singleWorkspaceScope(for: descriptor),
            excluding: excludedRegistration
        ))
        let relationshipChats = chats + preservedLiveChatsForFetchedRelationships(
            omittedFrom: chats,
            descriptor: descriptor,
            requiresIncludeContextChanges: true
        )
        let preservingGroupWorkspaces = workspaceFilters(for: descriptor) != nil
            || shouldPreserveExistingWorkspaceChats(
                for: descriptor,
                relationshipIsComplete: true
            )
        let removedChats = syncWorkspaceChats(
            chats,
            preservingExisting: shouldPreserveExistingWorkspaceChats(
                for: descriptor,
                relationshipIsComplete: true
            ),
            workspaceFilters: workspaceFilters(for: descriptor),
            archivedScope: archivedScope(for: descriptor)
        )
        await removeChatsFromRegisteredResults(removedChats, excluding: excludedRegistration)
        let workspaces = unique(relationshipChats.compactMap(\.workspace))
        syncGroupWorkspaces(
            workspaces,
            preservingExisting: preservingGroupWorkspaces,
            archivedScope: archivedScope(for: descriptor)
        )
        let groups = unique(workspaces.compactMap(\.workspaceGroup))
        let sortedGroups = sort(groups, using: descriptor.sortBy)
        let page = localPage(sortedGroups, for: descriptor, cursor: cursor)
        return CodexFetchPage(
            items: page.items,
            nextCursor: page.nextCursor,
            backwardsCursor: page.backwardsCursor,
            relationshipItems: sortedGroups,
            relationshipIsComplete: true
        )
    }

    private func applyFetchedSnapshots(
        _ candidates: [FetchedThreadCandidate],
        archived: Bool,
        scopedWorkspaceURL: URL? = nil,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async -> [CodexChat] {
        var revalidations: [CodexFetchedChatRevalidation] = []
        var appliedChats: [CodexChat] = []
        for candidate in candidates {
            let existingChat = chatsByID[candidate.id]
            let previousState = existingChat.map(fetchedResultState(for:))
            let previousWorkspace = existingChat?.workspace
            let previousGroup = previousWorkspace?.workspaceGroup
            let firstOccurrence = candidate.firstOccurrence
            let firstSnapshot = snapshotForApply(
                firstOccurrence.snapshot,
                scopedWorkspaceURL: scopedWorkspaceURL
            )
            var chat = apply(
                firstSnapshot,
                archived: archived,
                sourceProvenance: firstOccurrence.sourceProvenance
            )
            for occurrence in candidate.additionalOccurrences {
                let snapshot = snapshotForApply(
                    occurrence.snapshot,
                    scopedWorkspaceURL: scopedWorkspaceURL
                )
                chat = apply(
                    snapshot,
                    archived: archived,
                    sourceProvenance: occurrence.sourceProvenance
                )
            }
            if previousState == nil || previousState != fetchedResultState(for: chat) {
                revalidations.append(CodexFetchedChatRevalidation(
                    chat: chat,
                    previousWorkspace: previousWorkspace,
                    previousGroup: previousGroup,
                    archived: chat.isArchived
                ))
            }
            appliedChats.append(chat)
        }
        await revalidateChatsInRegisteredResults(revalidations, excluding: excludedRegistration)
        return appliedChats
    }

    private func defaultUserVisibleChats(from chats: [CodexChat]) -> [CodexChat] {
        chats.filter {
            CodexThreadCandidateSourceScope.defaultUserVisible.matches(
                CodexChatRecord(chat: $0)
            )
        }
    }

    private func snapshotForApply(
        _ snapshot: CodexThreadSnapshot,
        scopedWorkspaceURL: URL?
    ) -> CodexThreadSnapshot {
        guard let scopedWorkspaceURL, snapshot.hasField(.workspace) == false else {
            return snapshot
        }
        var presentFields = snapshot.presentFields
        presentFields.insert(.workspace)
        return CodexThreadSnapshot(
            id: snapshot.id,
            workspace: scopedWorkspaceURL,
            name: snapshot.name,
            preview: snapshot.preview,
            modelProvider: snapshot.modelProvider,
            sessionID: snapshot.sessionID,
            parentThreadID: snapshot.parentThreadID,
            source: snapshot.source,
            sourceKind: snapshot.source == nil ? snapshot.sourceKind : nil,
            gitInfo: snapshot.gitInfo,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt,
            recencyAt: snapshot.recencyAt,
            status: snapshot.status,
            ephemeral: snapshot.ephemeral,
            turns: snapshot.turns,
            turnItemsAreAuthoritative: snapshot.turnItemsAreAuthoritative,
            presentFields: presentFields
        )
    }

    private func fetchedResultState(for chat: CodexChat) -> ChatFetchedResultState {
        ChatFetchedResultState(
            name: chat.name,
            preview: chat.preview,
            modelProvider: chat.modelProvider,
            sessionID: chat.sessionID,
            parentThreadID: chat.parentThreadID,
            sourceResolution: chat.threadSourceResolution,
            gitInfo: chat.gitInfo,
            isArchived: chat.isArchived,
            createdAt: chat.createdAt,
            updatedAt: chat.updatedAt,
            recencyAt: chat.recencyAt,
            status: chat.status,
            ephemeral: chat.ephemeral,
            workspaceID: chat.workspace?.id,
            workspaceGroupID: chat.workspace?.workspaceGroup?.id
        )
    }

    @discardableResult
    private func apply(
        _ snapshot: CodexThreadSnapshot,
        archived: Bool? = nil,
        sourceProvenance: CodexThreadListSourceProvenance? = nil,
        preservesExistingTurnItems: Bool = false
    ) -> CodexChat {
        let chat = chat(for: snapshot.id)
        let workspace: CodexWorkspace?
        if snapshot.hasField(.workspace) {
            workspace = snapshot.workspace.map(workspace(for:))
            if let previousWorkspace = chat.workspace {
                let movedToDifferentWorkspace = workspace.map { $0 !== previousWorkspace } ?? true
                if movedToDifferentWorkspace {
                    detach(chat, from: previousWorkspace)
                }
            }
        } else {
            workspace = chat.workspace
        }
        chat.apply(
            snapshot,
            workspace: workspace,
            sourceProvenance: sourceProvenance,
            preservesExistingTurnItems: preservesExistingTurnItems
        )
        if let archived {
            chat.applyContextArchived(archived)
        }
        workspace?.attachContextChatIfNeeded(chat)
        return chat
    }

    private func chat(for id: CodexThreadID) -> CodexChat {
        if let chat = chatsByID[id] {
            return chat
        }
        let chat = CodexChat(id: id, modelContext: self)
        chatsByID[id] = chat
        return chat
    }

    private func workspace(for url: URL) -> CodexWorkspace {
        let standardizedURL = Self.standardizedDirectoryURL(url)
        let id = CodexWorkspaceID(rawValue: standardizedURL.path)
        let groupIdentity = CodexWorkspaceGroupIdentity.identity(for: standardizedURL)
        let group = workspaceGroup(for: groupIdentity)
        let name = Self.displayName(for: standardizedURL)
        let workspace: CodexWorkspace
        if let existing = workspacesByID[id] {
            workspace = existing
            if let previousGroup = workspace.workspaceGroup,
                previousGroup !== group
            {
                previousGroup.replaceContextWorkspaces(previousGroup.workspaces.filter { $0 !== workspace })
            }
            workspace.applyContextSnapshot(url: standardizedURL, name: name, workspaceGroup: group)
        } else {
            workspace = CodexWorkspace(
                id: id,
                url: standardizedURL,
                name: name,
                workspaceGroup: group,
                modelContext: self
            )
            workspacesByID[id] = workspace
        }
        if group.workspaces.contains(where: { $0 === workspace }) == false {
            group.replaceContextWorkspaces(sort(
                group.workspaces + [workspace],
                using: [CodexSortDescriptor(\.name)]
            ))
        }
        return workspace
    }

    private func workspaceGroup(for identity: CodexWorkspaceGroupIdentity) -> CodexWorkspaceGroup {
        if let group = workspaceGroupsByID[identity.id] {
            group.applyContextSnapshot(name: identity.title)
            return group
        }
        let group = CodexWorkspaceGroup(
            id: identity.id,
            name: identity.title,
            modelContext: self
        )
        workspaceGroupsByID[identity.id] = group
        return group
    }

    private func remove(_ chat: CodexChat) async {
        let workspace = chat.workspace
        let group = workspace?.workspaceGroup
        if let observation = activeChatObservationsByID[chat.id] {
            discardChatObservation(chat.id, observation: observation)
        }
        preparedEventThreadsByID.removeValue(forKey: chat.id)
        chatsByID.removeValue(forKey: chat.id)
        turnsByID = turnsByID.filter { $0.value.chat !== chat }
        itemsByID = itemsByID.filter { $0.value.chat !== chat }
        if let workspace {
            detach(chat, from: workspace)
        }
        chat.detachFromContext()
        await removeChatFromRegisteredResults(chat, workspace: workspace, group: group)
    }

    package func syncLoadedRelationships<Model: CodexPersistentModel>(
        from page: CodexFetchPage<Model>,
        descriptor: CodexFetchDescriptor<Model>,
        loadedItems: [Model]? = nil,
        cursor: String? = nil,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async {
        var relationshipItems = page.relationshipItems ?? loadedItems ?? page.items
        if Model.self == CodexChat.self {
            let preserved = relationshipPreservedLiveChats(
                omittedFrom: relationshipItems,
                descriptor: descriptor
            )
            if preserved.isEmpty == false {
                relationshipItems.append(contentsOf: preserved.map { $0 as! Model })
            }
        }
        let relationshipIsComplete = page.relationshipIsComplete
            ?? (page.nextCursor == nil && descriptor.normalizedFetchOffset == 0)
        await syncLoadedRelationships(
            relationshipItems,
            descriptor: descriptor,
            relationshipIsComplete: relationshipIsComplete,
            excluding: excludedRegistration
        )
    }

    private func syncLoadedRelationships<Model: CodexPersistentModel>(
        _ items: [Model],
        descriptor: CodexFetchDescriptor<Model>,
        relationshipIsComplete: Bool,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async {
        if let chats = items as? [CodexChat] {
            let preservingExisting = shouldPreserveExistingWorkspaceChats(
                for: descriptor,
                relationshipIsComplete: relationshipIsComplete
            )
            let removedChats = syncWorkspaceChats(
                chats,
                preservingExisting: preservingExisting,
                workspaceFilters: workspaceFilters(for: descriptor),
                archivedScope: archivedScope(for: descriptor)
            )
            await removeChatsFromRegisteredResults(removedChats, excluding: excludedRegistration)
        }
    }

    private func syncWorkspaceChats(
        _ chats: [CodexChat],
        preservingExisting: Bool,
        workspaceFilters: [URL]?,
        archivedScope: Bool?
    ) -> [(chat: CodexChat, workspace: CodexWorkspace, group: CodexWorkspaceGroup?)] {
        var removedChats: [(
            chat: CodexChat,
            workspace: CodexWorkspace,
            group: CodexWorkspaceGroup?
        )] = []
        let fetchedWorkspaces = unique(chats.compactMap(\.workspace))
        let workspaces: [CodexWorkspace]
        if preservingExisting {
            workspaces = fetchedWorkspaces
        } else if let workspaceFilters {
            let filteredWorkspaces = workspaceFilters.compactMap(workspaceIfLoaded(for:))
            workspaces = unique(filteredWorkspaces + fetchedWorkspaces)
        } else {
            workspaces = Array(workspacesByID.values)
        }
        for workspace in workspaces {
            let previousChats = workspace.chats
            let fetchedChats = chats.filter { $0.workspace === workspace }
            if preservingExisting {
                let fetchedIDs = Set(fetchedChats.map(\.id))
                let remainingChats = workspace.chats.filter { fetchedIDs.contains($0.id) == false }
                workspace.replaceContextChats(fetchedChats + remainingChats)
            } else {
                let fetchedIDs = Set(fetchedChats.map(\.id))
                let preservedChats = workspace.chats.filter {
                    fetchedIDs.contains($0.id) == false
                        && shouldPreserveMissingRefreshChat($0, archivedScope: archivedScope)
                }
                let currentChats = fetchedChats + preservedChats
                workspace.replaceContextChats(currentChats)
                let staleChats = detachStaleChats(
                    previousChats,
                    from: workspace,
                    keeping: currentChats,
                    archivedScope: archivedScope
                )
                let group = workspace.workspaceGroup
                if staleChats.isEmpty == false {
                }
                removedChats.append(contentsOf: staleChats.map {
                    (chat: $0, workspace: workspace, group: group)
                })
                pruneWorkspaceIfEmpty(workspace)
            }
        }
        return removedChats
    }

    private func shouldPreserve(_ chat: CodexChat, outside archivedScope: Bool?) -> Bool {
        switch archivedScope {
        case .some(true):
            chat.isArchived == false
        case .some(false), .none:
            chat.isArchived
        }
    }

    private func isInRefreshedScope(_ chat: CodexChat, archivedScope: Bool?) -> Bool {
        switch archivedScope {
        case .some(true):
            chat.isArchived
        case .some(false), .none:
            chat.isArchived == false
        }
    }

    private func shouldPreserveMissingRefreshChat(_ chat: CodexChat, archivedScope: Bool?) -> Bool {
        CodexThreadCandidateSourceScope.defaultUserVisible.matches(CodexChatRecord(chat: chat))
            && (shouldPreserve(chat, outside: archivedScope) || shouldPreserveLiveFetchedChat(chat))
    }

    private func containsPreservedMissingRefreshChat(
        in workspace: CodexWorkspace,
        archivedScope: Bool?
    ) -> Bool {
        workspace.chats.contains {
            shouldPreserveMissingRefreshChat($0, archivedScope: archivedScope)
        }
    }

    private func syncGroupWorkspaces(
        _ workspaces: [CodexWorkspace],
        preservingExisting: Bool,
        archivedScope: Bool?
    ) {
        let fetchedGroups = unique(workspaces.compactMap(\.workspaceGroup))
        let groups = preservingExisting ? fetchedGroups : Array(workspaceGroupsByID.values)
        for group in groups {
            let fetchedWorkspaces = workspaces.filter { $0.workspaceGroup === group }
            if preservingExisting {
                let fetchedIDs = Set(fetchedWorkspaces.map(\.id))
                let remainingWorkspaces = group.workspaces.filter {
                    fetchedIDs.contains($0.id) == false
                }
                group.replaceContextWorkspaces(sort(
                    fetchedWorkspaces + remainingWorkspaces,
                    using: [CodexSortDescriptor(\.name)]
                ))
            } else {
                let fetchedIDs = Set(fetchedWorkspaces.map(\.id))
                let preservedWorkspaces = group.workspaces.filter {
                    fetchedIDs.contains($0.id) == false
                        && containsPreservedMissingRefreshChat(in: $0, archivedScope: archivedScope)
                }
                group.replaceContextWorkspaces(sort(
                    fetchedWorkspaces + preservedWorkspaces,
                    using: [CodexSortDescriptor(\.name)]
                ))
            }
        }
    }

    private func detach(_ chat: CodexChat, from workspace: CodexWorkspace) {
        workspace.replaceContextChats(workspace.chats.filter { $0 !== chat })
        pruneWorkspaceIfEmpty(workspace)
    }

    private func detachStaleChats(
        _ previousChats: [CodexChat],
        from workspace: CodexWorkspace,
        keeping refreshedChats: [CodexChat],
        archivedScope: Bool?
    ) -> [CodexChat] {
        let refreshedIDs = Set(refreshedChats.map(\.id))
        let staleChats = previousChats.filter {
            refreshedIDs.contains($0.id) == false
                && isInRefreshedScope($0, archivedScope: archivedScope)
                && shouldPreserveLiveFetchedChat($0) == false
        }
        for chat in staleChats {
            chat.detachFromWorkspace(workspace)
        }
        return staleChats
    }

    private func pruneWorkspaceIfEmpty(_ workspace: CodexWorkspace) {
        guard workspace.chats.isEmpty, let group = workspace.workspaceGroup else {
            return
        }
        group.replaceContextWorkspaces(group.workspaces.filter { $0 !== workspace })
    }

    private func shouldPreserveExistingWorkspaceChats<Model: CodexPersistentModel>(
        for descriptor: CodexFetchDescriptor<Model>,
        relationshipIsComplete: Bool
    ) -> Bool {
        let plan = chatQueryPlan(for: descriptor)
        return (Model.self == CodexChat.self
            && relationshipIsComplete == false)
            || plan?.membershipRequiresServerRefresh == true
    }

    package func preservedLiveChats<Model: CodexPersistentModel>(
        omittedFrom loadedItems: [Model],
        descriptor: CodexFetchDescriptor<Model>
    ) -> [CodexChat] {
        preservedLiveChats(
            omittedFrom: loadedItems,
            descriptor: descriptor,
            requiresIncludeContextChanges: true
        )
    }

    private func relationshipPreservedLiveChats<Model: CodexPersistentModel>(
        omittedFrom loadedItems: [Model],
        descriptor: CodexFetchDescriptor<Model>
    ) -> [CodexChat] {
        preservedLiveChats(
            omittedFrom: loadedItems,
            descriptor: descriptor,
            requiresIncludeContextChanges: false
        )
    }

    private func preservedLiveChats<Model: CodexPersistentModel>(
        omittedFrom loadedItems: [Model],
        descriptor: CodexFetchDescriptor<Model>,
        requiresIncludeContextChanges: Bool
    ) -> [CodexChat] {
        guard Model.self == CodexChat.self,
            canPreserveLiveChats(
                for: descriptor,
                requiresIncludeContextChanges: requiresIncludeContextChanges
            )
        else {
            return []
        }
        return preservedLiveChatsForFetchedRelationships(
            omittedFrom: loadedItems as? [CodexChat] ?? [],
            descriptor: descriptor,
            requiresIncludeContextChanges: requiresIncludeContextChanges
        )
    }

    private func preservedLiveChatsForFetchedRelationships<Model: CodexPersistentModel>(
        omittedFrom loadedChats: [CodexChat],
        descriptor: CodexFetchDescriptor<Model>,
        requiresIncludeContextChanges: Bool
    ) -> [CodexChat] {
        guard canPreserveLiveChats(
            for: descriptor,
            requiresIncludeContextChanges: requiresIncludeContextChanges
        ) else {
            return []
        }
        let loadedChatIDs = Set(loadedChats.map(\.id))
        return chatsByID.values.filter { chat in
            loadedChatIDs.contains(chat.id) == false
                && shouldPreserveLiveFetchedChat(chat)
                && shouldIncludeLiveFetchedChat(chat, descriptor: descriptor)
        }
    }

    package func shouldPreserveLiveFetchedChat(_ chat: CodexChat) -> Bool {
        guard chatsByID[chat.id] === chat else {
            return false
        }
        if activeChatObservationsByID[chat.id]?.isFinished == false {
            return true
        }
        if chat.status?.isActive == true {
            return true
        }
        if chat.phase == .loading {
            return true
        }
        return false
    }

    private func canPreserveLiveChats<Model: CodexPersistentModel>(
        for descriptor: CodexFetchDescriptor<Model>,
        requiresIncludeContextChanges: Bool
    ) -> Bool {
        let plan = chatQueryPlan(for: descriptor)
        return (requiresIncludeContextChanges == false || descriptor.includeContextChanges)
            && descriptor.normalizedFetchOffset == 0
            && plan?.membershipRequiresServerRefresh != true
    }

    private func shouldIncludeLiveFetchedChat<Model: CodexPersistentModel>(
        _ chat: CodexChat,
        descriptor: CodexFetchDescriptor<Model>
    ) -> Bool {
        guard let plan = chatQueryPlan(for: descriptor) else {
            return chat.isArchived == false
                && CodexThreadCandidateSourceScope.defaultUserVisible.matches(
                    CodexChatRecord(chat: chat)
                )
        }
        return plan.matchesLocalCandidate(chat)
    }

    private func workspaceIfLoaded(for url: URL) -> CodexWorkspace? {
        let id = CodexWorkspaceID(rawValue: Self.standardizedDirectoryURL(url).path)
        return workspacesByID[id]
    }

    private func register(_ results: any CodexFetchedResultsRegistration) {
        fetchedResults.removeAll { $0.value == nil }
        fetchedResults.append(WeakFetchedResultsRegistration(results))
    }

    private func insertChatIntoRegisteredResults(_ chat: CodexChat, archived: Bool) async {
        fetchedResults.removeAll { $0.value == nil }
        for registration in fetchedResults {
            await registration.value?.insert(chat, archived: archived)
        }
    }

    private func archiveChatInRegisteredResults(
        _ chat: CodexChat,
        workspace: CodexWorkspace?,
        group: CodexWorkspaceGroup?
    ) async {
        fetchedResults.removeAll { $0.value == nil }
        for registration in fetchedResults {
            await registration.value?.archive(chat, workspace: workspace, group: group)
        }
    }

    private func revalidateChatInRegisteredResults(
        _ chat: CodexChat,
        previousWorkspace: CodexWorkspace?,
        previousGroup: CodexWorkspaceGroup?,
        archived: Bool,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async {
        await revalidateChatsInRegisteredResults(
            [CodexFetchedChatRevalidation(
                chat: chat,
                previousWorkspace: previousWorkspace,
                previousGroup: previousGroup,
                archived: archived
            )],
            excluding: excludedRegistration
        )
    }

    private func revalidateChatsInRegisteredResults(
        _ changes: [CodexFetchedChatRevalidation],
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async {
        guard changes.isEmpty == false else {
            return
        }
        fetchedResults.removeAll { $0.value == nil }
        for registration in fetchedResults {
            guard let value = registration.value else {
                continue
            }
            if let excludedRegistration,
                (value as AnyObject) === (excludedRegistration as AnyObject)
            {
                continue
            }
            await value.revalidate(changes)
        }
    }

    private func removeChatFromRegisteredResults(
        _ chat: CodexChat,
        workspace: CodexWorkspace?,
        group: CodexWorkspaceGroup?,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async {
        fetchedResults.removeAll { $0.value == nil }
        for registration in fetchedResults {
            guard let value = registration.value else {
                continue
            }
            if let excludedRegistration,
                (value as AnyObject) === (excludedRegistration as AnyObject)
            {
                continue
            }
            await value.remove(chat, workspace: workspace, group: group)
        }
    }

    private func removeChatsFromRegisteredResults(
        _ removedChats: [(
            chat: CodexChat,
            workspace: CodexWorkspace,
            group: CodexWorkspaceGroup?
        )],
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async {
        for removedChat in removedChats {
            await removeChatFromRegisteredResults(
                removedChat.chat,
                workspace: removedChat.workspace,
                group: removedChat.group,
                excluding: excludedRegistration
            )
        }
    }

    private func refreshWorkspaceInRegisteredResults(
        _ workspace: CodexWorkspace,
        archived: Bool,
        removedChats: [CodexChat]
    ) async {
        fetchedResults.removeAll { $0.value == nil }
        for registration in fetchedResults {
            await registration.value?.refresh(workspace, archived: archived, removedChats: removedChats)
        }
    }

    private func refreshWorkspaceGroupInRegisteredResults(
        _ group: CodexWorkspaceGroup,
        archived: Bool,
        removedChats: [CodexChat]
    ) async {
        fetchedResults.removeAll { $0.value == nil }
        for registration in fetchedResults {
            await registration.value?.refresh(group, archived: archived, removedChats: removedChats)
        }
    }

    private func fetchAndApplyAllThreadSnapshots<Model: CodexPersistentModel>(
        matching descriptor: CodexFetchDescriptor<Model>,
        archiveScope: Bool? = nil,
        appliedArchived: Bool,
        scopedWorkspaceURL: URL? = nil,
        excluding excludedRegistration: (any CodexFetchedResultsRegistration)? = nil
    ) async throws -> [CodexChat] {
        let candidates = try await fetchAllThreadSnapshots(
            matching: descriptor,
            archived: archiveScope
        )
        try Task.checkCancellation()
        return await applyFetchedSnapshots(
            candidates,
            archived: appliedArchived,
            scopedWorkspaceURL: scopedWorkspaceURL,
            excluding: excludedRegistration
        )
    }

    private func fetchAllThreadSnapshots<Model: CodexPersistentModel>(
        matching descriptor: CodexFetchDescriptor<Model>,
        archived archiveScope: Bool? = nil
    ) async throws -> [FetchedThreadCandidate] {
        var candidates: [FetchedThreadCandidate] = []
        var indexesByID: [CodexThreadID: Int] = [:]

        for var query in threadQueries(
            from: descriptor,
            includePaging: false,
            archived: archiveScope
        ) {
            let sourceKinds = query.sourceKinds
            // Created/updated cursors in the pinned app-server do not contain a thread-ID
            // tie-breaker. Enumerate with its stable recency cursor, then apply the requested
            // effective ordering locally.
            query.sortDirection = .descending
            query.sortKey = .recencyAt
            var cursor: String?

            repeat {
                try Task.checkCancellation()
                query.cursor = cursor
                let page = try await appServer.listThreads(query)
                for thread in page.threads {
                    if let index = indexesByID[thread.id] {
                        candidates[index].append(
                            snapshot: thread,
                            sourceKinds: sourceKinds
                        )
                    } else {
                        indexesByID[thread.id] = candidates.count
                        candidates.append(FetchedThreadCandidate(
                            snapshot: thread,
                            sourceKinds: sourceKinds
                        ))
                    }
                }
                cursor = page.nextCursor
            } while cursor != nil
        }

        return candidates
    }

    private func chatQueryPlan<Model: CodexPersistentModel>(
        for descriptor: CodexFetchDescriptor<Model>
    ) -> CodexThreadQueryPlan? {
        guard Model.self == CodexChat.self else {
            return nil
        }
        return try? CodexThreadQueryPlan(
            descriptor: descriptor as! CodexFetchDescriptor<CodexChat>
        )
    }

    private func archivedScope<Model: CodexPersistentModel>(
        for descriptor: CodexFetchDescriptor<Model>
    ) -> Bool? {
        chatQueryPlan(for: descriptor)?.archived
    }

    private func workspaceFilters<Model: CodexPersistentModel>(
        for descriptor: CodexFetchDescriptor<Model>
    ) -> [URL]? {
        chatQueryPlan(for: descriptor)?.workspaces
    }

    private func singleWorkspaceScope<Model: CodexPersistentModel>(
        for descriptor: CodexFetchDescriptor<Model>
    ) -> URL? {
        chatQueryPlan(for: descriptor)?.singleWorkspace
    }

    private func localPage<Model: CodexPersistentModel>(
        _ items: [Model],
        for descriptor: CodexFetchDescriptor<Model>,
        cursor: String?
    ) -> CodexFetchPage<Model> {
        let offset =
            cursor == nil
            ? descriptor.normalizedFetchOffset
            : localCursorOffset(from: cursor)
        let start = min(offset, items.count)
        guard let limit = descriptor.fetchLimit else {
            return CodexFetchPage(
                items: Array(items[start..<items.endIndex]),
                nextCursor: nil,
                backwardsCursor: start > 0 ? localCursor(for: 0) : nil
            )
        }
        guard limit > 0 else {
            return CodexFetchPage(items: [], nextCursor: nil, backwardsCursor: nil)
        }

        let end = min(start + limit, items.count)
        let previousStart = max(0, start - limit)
        return CodexFetchPage(
            items: Array(items[start..<end]),
            nextCursor: end < items.count ? localCursor(for: end) : nil,
            backwardsCursor: start > 0 ? localCursor(for: previousStart) : nil
        )
    }

    private func canUseServerOrderedPages<Model: CodexPersistentModel>(
        for descriptor: CodexFetchDescriptor<Model>,
        cursor: String?
    ) -> Bool {
        if descriptor.normalizedFetchOffset > 0 {
            return false
        }
        if cursor?.hasPrefix(Self.localCursorPrefix) == true {
            return false
        }
        guard let plan = chatQueryPlan(for: descriptor) else {
            return false
        }
        guard plan.archived != nil else {
            return false
        }
        guard plan.serverPredicateIsComplete else {
            return false
        }
        guard plan.candidateSourceScope.requiresCompositeFetch == false else {
            return false
        }
        return plan.sortPlans.isEmpty
            || (plan.sortPlans.count == 1 && plan.sortPlans[0].key == .recencyAt)
    }

    private func canUseBoundedCompositeRecencyPage(
        for descriptor: CodexFetchDescriptor<CodexChat>,
        plan: CodexThreadQueryPlan,
        cursor: String?
    ) -> Bool {
        guard cursor == nil || cursor?.hasPrefix(Self.localCursorPrefix) == true else {
            return false
        }
        guard plan.candidateSourceScope == .defaultUserVisible,
            plan.archived != nil,
            plan.serverPredicateIsComplete,
            plan.sortPlans.count == 1,
            plan.sortPlans[0].key == .recencyAt,
            let fetchLimit = descriptor.fetchLimit,
            fetchLimit > 0
        else {
            return false
        }
        return true
    }

    package func localCursor(for offset: Int) -> String {
        "\(Self.localCursorPrefix)\(offset)"
    }

    package func localCursorOffset(from cursor: String?) -> Int {
        guard let cursor,
            cursor.hasPrefix(Self.localCursorPrefix)
        else {
            return 0
        }

        let rawOffset = cursor.dropFirst(Self.localCursorPrefix.count)
        guard let offset = Int(rawOffset), offset > 0 else {
            return 0
        }
        return offset
    }

    private func threadQuery<Model: CodexPersistentModel>(
        from descriptor: CodexFetchDescriptor<Model>,
        cursor: String? = nil,
        includePaging: Bool = true,
        archived archiveScope: Bool? = nil
    )
        -> CodexThreadQuery
    {
        if let plan = chatQueryPlan(for: descriptor) {
            return plan.threadQuery(
                cursor: cursor,
                includePaging: includePaging,
                archived: archiveScope
            )
        }
        let sortPlans = descriptor.sortBy.map(CodexSortPlan.afterValidation)
        let serverSort = sortPlans.first { sortDescriptor in
            switch sortDescriptor.key {
            case .createdAt, .updatedAt, .recencyAt:
                return true
            case .name:
                return false
            }
        }
        return CodexThreadQuery(
            cursor: includePaging ? cursor : nil,
            limit: includePaging ? descriptor.fetchLimit : nil,
            sortDirection: serverSort?.threadSortDirection,
            sortKey: serverSort?.threadSortKey
        )
    }

    private func threadQueries<Model: CodexPersistentModel>(
        from descriptor: CodexFetchDescriptor<Model>,
        cursor: String? = nil,
        includePaging: Bool = true,
        archived archiveScope: Bool? = nil
    ) -> [CodexThreadQuery] {
        let candidateSourceScope = chatQueryPlan(for: descriptor)?.candidateSourceScope
            ?? .defaultUserVisible
        let baseQuery = threadQuery(
            from: descriptor,
            cursor: cursor,
            includePaging: includePaging,
            archived: archiveScope
        )
        return candidateSourceScope.sourceKindFilters.map { sourceKinds in
            var query = baseQuery
            query.sourceKinds = sourceKinds
            return query
        }
    }

    private func sortLocallyFetchedChats(
        _ chats: [CodexChat],
        using descriptor: CodexFetchDescriptor<CodexChat>
    ) -> [CodexChat] {
        guard descriptor.sortBy.isEmpty,
            chatQueryPlan(for: descriptor)?.candidateSourceScope.requiresCompositeFetch == true
        else {
            return sort(chats, using: descriptor.sortBy)
        }
        return sort(
            chats,
            using: [CodexSortDescriptor(\CodexChat.createdAt, order: .reverse)]
        )
    }

    private func sectionIdentity<Model: CodexPersistentModel>(
        for item: Model,
        descriptor: CodexSectionDescriptor<Model>
    ) -> (id: CodexFetchSectionID, title: String) {
        let sectionKey: CodexSectionKey
        do {
            sectionKey = try descriptor.resolveKey()
        } catch {
            preconditionFailure(
                "CodexSectionDescriptor was used before successful validation: \(error)"
            )
        }
        switch sectionKey {
        case .workspace:
            if let chat = item as? CodexChat, let workspace = chat.workspace {
                return (.workspace(workspace.id), workspace.name)
            }
        case .workspaceGroup:
            if let workspace = item as? CodexWorkspace, let group = workspace.workspaceGroup {
                return (.workspaceGroup(group.id), group.name)
            }
            if let chat = item as? CodexChat, let group = chat.workspace?.workspaceGroup {
                return (.workspaceGroup(group.id), group.name)
            }
        }
        return (.unknown("unknown"), "Unknown")
    }

    private func sort(
        _ chats: [CodexChat],
        using descriptors: [CodexSortDescriptor<CodexChat>]
    )
        -> [CodexChat]
    {
        guard descriptors.isEmpty == false else {
            return chats
        }
        let plans = descriptors.map(CodexSortPlan.afterValidation)
        return sortModels(
            chats,
            using: plans,
            stableID: { $0.id.rawValue },
            tieBreakOrder: plans[0].order
        ) { plan, lhs, rhs in
            plan.compare(lhs, rhs)
        }
    }

    private func sort(
        _ workspaces: [CodexWorkspace],
        using descriptors: [CodexSortDescriptor<CodexWorkspace>]
    ) -> [CodexWorkspace] {
        let plans = descriptors.map(CodexSortPlan.afterValidation)
        return sortModels(
            workspaces,
            using: plans,
            stableID: { $0.id.rawValue },
            tieBreakOrder: plans.first?.order ?? .forward
        ) { plan, lhs, rhs in
            plan.compare(lhs, rhs)
        }
    }

    private func sort(
        _ groups: [CodexWorkspaceGroup],
        using descriptors: [CodexSortDescriptor<CodexWorkspaceGroup>]
    ) -> [CodexWorkspaceGroup] {
        let plans = descriptors.map(CodexSortPlan.afterValidation)
        return sortModels(
            groups,
            using: plans,
            stableID: { $0.id.rawValue },
            tieBreakOrder: plans.first?.order ?? .forward
        ) { plan, lhs, rhs in
            plan.compare(lhs, rhs)
        }
    }

    private func sortModels<Model, Descriptor>(
        _ models: [Model],
        using descriptors: [Descriptor],
        stableID: (Model) -> String,
        tieBreakOrder: SortOrder,
        compare: (Descriptor, Model, Model) -> ComparisonResult
    ) -> [Model] {
        return models.sorted { lhs, rhs in
            shouldSortBefore(
                lhs,
                rhs,
                using: descriptors,
                stableID: stableID,
                tieBreakOrder: tieBreakOrder,
                compare: compare
            )
        }
    }

    private func shouldSortBefore<Model, Descriptor>(
        _ lhs: Model,
        _ rhs: Model,
        using descriptors: [Descriptor],
        stableID: (Model) -> String,
        tieBreakOrder: SortOrder,
        compare: (Descriptor, Model, Model) -> ComparisonResult
    ) -> Bool {
        for descriptor in descriptors {
            switch compare(descriptor, lhs, rhs) {
            case .orderedAscending:
                return true
            case .orderedDescending:
                return false
            case .orderedSame:
                continue
            }
        }
        let lhsID = stableID(lhs)
        let rhsID = stableID(rhs)
        guard lhsID != rhsID else {
            return false
        }
        return tieBreakOrder == .forward ? lhsID < rhsID : lhsID > rhsID
    }

    private func unique<Model: CodexPersistentModel>(_ models: [Model]) -> [Model] {
        var seen: Set<Model.ID> = []
        var result: [Model] = []
        for model in models where seen.insert(model.id).inserted {
            result.append(model)
        }
        return result
    }

    private static func standardizedDirectoryURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }
}

@available(*, unavailable, message: "contexts cannot be shared across concurrency contexts")
extension CodexModelContext: @unchecked Sendable {}

private extension CodexReviewTarget {
    var dataKitPreview: String {
        switch self {
        case .uncommittedChanges:
            return "Review the current code changes (staged, unstaged, and untracked files) and provide prioritized findings."
        case .baseBranch(let branch):
            return "Review the code changes against the base branch '\(branch)'."
        case .commit(let sha, let title):
            if let title, title.isEmpty == false {
                return "Review the code changes introduced by commit \(sha) (\"\(title)\"). Provide prioritized, actionable findings."
            }
            return "Review the code changes introduced by commit \(sha). Provide prioritized, actionable findings."
        case .custom(let instructions):
            let preview = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            return preview.isEmpty ? "Review code changes." : preview
        }
    }
}

extension ComparisonResult {
    fileprivate var reversed: ComparisonResult {
        switch self {
        case .orderedAscending:
            return .orderedDescending
        case .orderedDescending:
            return .orderedAscending
        case .orderedSame:
            return .orderedSame
        }
    }
}

private final class WeakFetchedResultsRegistration {
    weak var value: (any CodexFetchedResultsRegistration)?

    init(_ value: any CodexFetchedResultsRegistration) {
        self.value = value
    }
}

private struct CodexWorkspaceGroupIdentity: Sendable {
    var id: CodexWorkspaceGroupID
    var title: String

    static func identity(
        for workspaceURL: URL,
        fileManager: FileManager = .default
    ) -> CodexWorkspaceGroupIdentity {
        guard
            let gitMetadataURL = enclosingGitMetadataURL(
                startingAt: workspaceURL, fileManager: fileManager)
        else {
            return .cwd(workspaceURL)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gitMetadataURL.path, isDirectory: &isDirectory) else {
            return .cwd(workspaceURL)
        }

        let gitRootURL = gitMetadataURL.deletingLastPathComponent()
        let commonDirURL: URL?
        if isDirectory.boolValue {
            commonDirURL = gitMetadataURL
        } else if let gitDirURL = linkedGitDirURL(from: gitMetadataURL) {
            commonDirURL = linkedCommonDirURL(for: gitDirURL) ?? gitDirURL
        } else {
            commonDirURL = nil
        }

        guard let commonDirURL else {
            return .cwd(workspaceURL)
        }

        let standardizedCommonDirURL = commonDirURL.standardizedFileURL.resolvingSymlinksInPath()
        return CodexWorkspaceGroupIdentity(
            id: .init(rawValue: "git-common:\(standardizedCommonDirURL.path)"),
            title: sectionTitle(
                commonDirURL: standardizedCommonDirURL,
                gitRootURL: gitRootURL,
                fallbackURL: workspaceURL
            )
        )
    }

    private static func cwd(_ url: URL) -> CodexWorkspaceGroupIdentity {
        CodexWorkspaceGroupIdentity(
            id: .init(rawValue: "cwd:\(url.path)"),
            title: displayName(for: url)
        )
    }

    private static func enclosingGitMetadataURL(startingAt url: URL, fileManager: FileManager)
        -> URL?
    {
        var directoryPath = url.standardizedFileURL.path
        while true {
            let gitPath = (directoryPath as NSString).appendingPathComponent(".git")
            if fileManager.fileExists(atPath: gitPath) {
                return URL(fileURLWithPath: gitPath)
            }

            let parentPath = (directoryPath as NSString).deletingLastPathComponent
            guard parentPath != directoryPath, parentPath.isEmpty == false else {
                return nil
            }
            directoryPath = parentPath
        }
    }

    private static func linkedGitDirURL(from gitFileURL: URL) -> URL? {
        guard let contents = try? String(contentsOf: gitFileURL, encoding: .utf8),
            let firstLine = contents.split(whereSeparator: \.isNewline).first
        else {
            return nil
        }

        let prefix = "gitdir:"
        let line = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.lowercased().hasPrefix(prefix) else {
            return nil
        }

        let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty == false else {
            return nil
        }
        return resolvedURL(path: path, relativeTo: gitFileURL.deletingLastPathComponent())
    }

    private static func linkedCommonDirURL(for gitDirURL: URL) -> URL? {
        let commonDirFileURL = gitDirURL.appendingPathComponent("commondir")
        guard let contents = try? String(contentsOf: commonDirFileURL, encoding: .utf8),
            let firstLine = contents.split(whereSeparator: \.isNewline).first
        else {
            return nil
        }

        let path = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty == false else {
            return nil
        }
        return resolvedURL(path: path, relativeTo: gitDirURL)
    }

    private static func resolvedURL(path: String, relativeTo baseURL: URL) -> URL {
        let url =
            path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : baseURL.appendingPathComponent(path, isDirectory: true)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func sectionTitle(
        commonDirURL: URL,
        gitRootURL: URL,
        fallbackURL: URL
    ) -> String {
        if commonDirURL.lastPathComponent == ".git" {
            let title = commonDirURL.deletingLastPathComponent().lastPathComponent
            if title.isEmpty == false {
                return title
            }
        }

        let commonDirName = commonDirURL.lastPathComponent
        if commonDirName.hasSuffix(".git"), commonDirName.count > ".git".count {
            return String(commonDirName.dropLast(".git".count))
        }

        let rootTitle = gitRootURL.lastPathComponent
        return rootTitle.isEmpty ? displayName(for: fallbackURL) : rootTitle
    }

    private static func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }
}
