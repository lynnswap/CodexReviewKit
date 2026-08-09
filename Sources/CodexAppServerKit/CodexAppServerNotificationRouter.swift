import Foundation
import OSLog

private let notificationRouterLogger = Logger(
    subsystem: "CodexAppServerKit",
    category: "notification-router"
)

package actor CodexAppServerNotificationRouter {
    private typealias NotificationContext = AppServerNotificationDecoder.Context

    private enum Phase {
        case open
        case terminating(CodexAppServerError)
        case terminated(CodexAppServerError)

        var terminationError: CodexAppServerError? {
            switch self {
            case .open:
                nil
            case .terminating(let error), .terminated(let error):
                error
            }
        }
    }

    package struct DetachedReviewRoutingSnapshot: Equatable, Sendable {
        package var attemptCount: Int
        package var candidateCount: Int
        package var drainCount: Int
    }

    private struct DetachedReviewRoutingAttempt {
        var candidateThreadIDs: Set<CodexThreadID> = []
    }

    // A detached review's response is the first value that identifies its fresh event thread.
    // Keep otherwise-unowned notifications intact until that request attempt can claim them;
    // classifying a turn/started by arrival order discards unrelated concurrent work. The
    // upstream fresh-thread contract means a later attempt cannot reuse an existing candidate.
    private struct DetachedReviewRoutingCandidate {
        var waitingAttempts: Set<TurnReplayPendingToken>
        var notifications: [AppServerNotificationDecoder.DecodedNotification] = []
    }

    private enum NotificationDrainMode {
        case claimedReview(CodexTurnID)
        case unclaimed
    }

    private struct NotificationDrain {
        var queuedNotifications: [AppServerNotificationDecoder.DecodedNotification] = []
    }

    private var threadIDByTurnID: [CodexTurnID: CodexThreadID] = [:]
    private var detachedReviewAttempts: [
        TurnReplayPendingToken: DetachedReviewRoutingAttempt
    ] = [:]
    private var detachedReviewCandidatesByThreadID: [
        CodexThreadID: DetachedReviewRoutingCandidate
    ] = [:]
    private var notificationDrainsByThreadID: [CodexThreadID: NotificationDrain] = [:]
    private var notificationDrainPauseForTesting: (@Sendable () async -> Void)?
    private var terminalReplayPublicationPauseForTesting: (@Sendable () async -> Void)?
    private var phase = Phase.open
    private var itemReducer = CodexItemReducer()
    private let accountEventHub: AccountEventHub
    package nonisolated let loginRegistry: LoginRegistry
    package nonisolated let turnReplayStore: TurnReplayStore
    package nonisolated let threadEventHub: ThreadEventHub

    package init(
        client: AppServerClient,
        turnReplayStore: TurnReplayStore,
        threadEventHub: ThreadEventHub,
        accountEventHub: AccountEventHub = .init(),
        loginRegistry: LoginRegistry = .init()
    ) {
        _ = client
        self.turnReplayStore = turnReplayStore
        self.threadEventHub = threadEventHub
        self.accountEventHub = accountEventHub
        self.loginRegistry = loginRegistry
    }

    package nonisolated func events(for threadID: CodexThreadID) -> CodexThreadEventSequence {
        threadEventHub.events(for: threadID)
    }

    package func seedTurn(_ turnID: CodexTurnID, threadID: CodexThreadID) {
        if let existingThreadID = installTurnAssociation(turnID, threadID: threadID) {
            precondition(
                existingThreadID == threadID,
                "A turn cannot move between thread associations."
            )
        }
    }

    private func installTurnAssociation(
        _ turnID: CodexTurnID,
        threadID: CodexThreadID
    ) -> CodexThreadID? {
        if let existingThreadID = threadIDByTurnID[turnID] {
            return existingThreadID
        }
        threadIDByTurnID[turnID] = threadID
        return nil
    }

    private func associateNotificationTurn(
        _ turnID: CodexTurnID,
        threadID: CodexThreadID
    ) throws {
        guard let existingThreadID = installTurnAssociation(turnID, threadID: threadID) else {
            return
        }
        guard existingThreadID == threadID else {
            throw CodexTransportFailure.contractViolation(
                message: "Turn \(turnID.rawValue) is already associated with thread "
                    + "\(existingThreadID.rawValue) and cannot move to thread "
                    + "\(threadID.rawValue)."
            )
        }
    }

    package func discardTurnAssociation(
        _ turnID: CodexTurnID,
        threadID: CodexThreadID
    ) {
        guard let registeredThreadID = threadIDByTurnID[turnID] else {
            return
        }
        precondition(
            registeredThreadID == threadID,
            "Only the thread that owns a turn association may discard it."
        )
        threadIDByTurnID.removeValue(forKey: turnID)
    }

    package func seedTurns(
        _ turns: [CodexTurnSnapshot]?,
        threadID: CodexThreadID
    ) {
        itemReducer.seed(turns)
        for turn in turns ?? [] {
            seedTurn(turn.id, threadID: threadID)
        }
    }

    package func seedCurrentTurnSnapshot(
        _ snapshot: CodexTurnSnapshot,
        threadID: CodexThreadID
    ) {
        threadEventHub.seedCurrentTurnSnapshot(snapshot, for: threadID)
    }

    package func accountEvents() async -> CodexAccountEvents {
        return await accountEventHub.events()
    }

    package func replaceRateLimits(
        with response: AppServerAPI.Account.RateLimits.Response
    ) async {
        await accountEventHub.replaceRateLimits(with: response)
    }
    package nonisolated func threadSubscriberCountForTesting(for threadID: CodexThreadID) -> Int {
        threadEventHub.snapshotForTesting(threadID: threadID).subscriberCount
    }

    package func detachedReviewRoutingSnapshotForTesting() -> DetachedReviewRoutingSnapshot {
        .init(
            attemptCount: detachedReviewAttempts.count,
            candidateCount: detachedReviewCandidatesByThreadID.count,
            drainCount: notificationDrainsByThreadID.count
        )
    }

    package func itemSnapshotForTesting(
        turnID: CodexTurnID,
        itemID: String
    ) -> CodexThreadItem? {
        itemReducer.item(turnID: turnID, itemID: itemID)
    }

    package nonisolated func resetThreadEventGeneration(_ threadID: CodexThreadID) {
        threadEventHub.resetGeneration(for: threadID)
    }

    package func adoptThreadEventGeneration(
        _ threadID: CodexThreadID,
        including turnID: CodexTurnID
    ) {
        threadEventHub.beginGeneration(for: threadID, including: turnID)
        seedTurn(turnID, threadID: threadID)
    }

    package func registerDetachedReviewRoutingAttempt(
        _ pending: TurnReplayPendingToken
    ) {
        precondition(
            detachedReviewAttempts[pending] == nil,
            "A detached review routing attempt may be registered exactly once."
        )
        detachedReviewAttempts[pending] = .init()
    }

    package func reconcileReviewStartResponse(
        _ pending: TurnReplayPendingToken,
        reviewThreadID: CodexThreadID,
        initialSnapshot: CodexTurnSnapshot,
        generation: ThreadEventGenerationAttempt
    ) async throws {
        try requireOpen()
        await turnReplayStore.bind(
            pending,
            to: initialSnapshot.id,
            initialSnapshot: initialSnapshot
        )
        try requireOpen()
        try generation.resolveReviewStartResponse(
            eventThreadID: reviewThreadID,
            responseSnapshot: initialSnapshot
        )
        seedTurn(initialSnapshot.id, threadID: reviewThreadID)
        try await resolveDetachedReviewRoutingAttempt(
            pending,
            reviewThreadID: reviewThreadID,
            turnID: initialSnapshot.id
        )
        try requireOpen()
    }

    package func rejectDetachedReviewRoutingAttemptResponse(
        _ pending: TurnReplayPendingToken
    ) async throws {
        try requireOpen()
        guard var attempt = detachedReviewAttempts[pending] else {
            return
        }
        var candidatesToDrain: [
            (CodexThreadID, DetachedReviewRoutingCandidate, NotificationDrainMode)
        ] = []
        for threadID in attempt.candidateThreadIDs {
            guard var candidate = detachedReviewCandidatesByThreadID[threadID] else {
                continue
            }
            candidate.waitingAttempts.remove(pending)
            if candidate.waitingAttempts.isEmpty {
                detachedReviewCandidatesByThreadID.removeValue(forKey: threadID)
                candidatesToDrain.append((threadID, candidate, .unclaimed))
            } else {
                detachedReviewCandidatesByThreadID[threadID] = candidate
            }
        }
        attempt.candidateThreadIDs.removeAll(keepingCapacity: true)
        detachedReviewAttempts[pending] = attempt
        try await drainCandidates(candidatesToDrain)
        try requireOpen()
    }

    package func cancelDetachedReviewRoutingAttempt(
        _ pending: TurnReplayPendingToken
    ) async throws {
        guard let attempt = detachedReviewAttempts.removeValue(forKey: pending) else {
            return
        }
        var candidatesToDrain: [
            (CodexThreadID, DetachedReviewRoutingCandidate, NotificationDrainMode)
        ] = []
        for threadID in attempt.candidateThreadIDs {
            guard var candidate = detachedReviewCandidatesByThreadID[threadID] else {
                continue
            }
            candidate.waitingAttempts.remove(pending)
            if candidate.waitingAttempts.isEmpty {
                detachedReviewCandidatesByThreadID.removeValue(forKey: threadID)
                candidatesToDrain.append((
                    threadID,
                    candidate,
                    .unclaimed
                ))
            } else {
                detachedReviewCandidatesByThreadID[threadID] = candidate
            }
        }
        try await drainCandidates(candidatesToDrain)
    }

    private func resolveDetachedReviewRoutingAttempt(
        _ pending: TurnReplayPendingToken,
        reviewThreadID: CodexThreadID,
        turnID: CodexTurnID
    ) async throws {
        guard let attempt = detachedReviewAttempts.removeValue(forKey: pending) else {
            return
        }
        var candidatesToDrain: [
            (CodexThreadID, DetachedReviewRoutingCandidate, NotificationDrainMode)
        ] = []
        for candidateThreadID in attempt.candidateThreadIDs {
            guard var candidate = detachedReviewCandidatesByThreadID[candidateThreadID] else {
                continue
            }
            if candidateThreadID == reviewThreadID {
                detachedReviewCandidatesByThreadID.removeValue(forKey: candidateThreadID)
                for waitingAttempt in candidate.waitingAttempts where waitingAttempt != pending {
                    detachedReviewAttempts[waitingAttempt]?.candidateThreadIDs.remove(
                        candidateThreadID
                    )
                }
                candidatesToDrain.append((
                    candidateThreadID,
                    candidate,
                    .claimedReview(turnID)
                ))
                continue
            }

            candidate.waitingAttempts.remove(pending)
            if candidate.waitingAttempts.isEmpty {
                detachedReviewCandidatesByThreadID.removeValue(forKey: candidateThreadID)
                candidatesToDrain.append((
                    candidateThreadID,
                    candidate,
                    .unclaimed
                ))
            } else {
                detachedReviewCandidatesByThreadID[candidateThreadID] = candidate
            }
        }
        try await drainCandidates(candidatesToDrain)
    }

    private func drainCandidates(
        _ candidates: [(
            CodexThreadID,
            DetachedReviewRoutingCandidate,
            NotificationDrainMode
        )]
    ) async throws {
        try requireOpen()
        beginNotificationDrains(candidates)
        do {
            for (threadID, candidate, mode) in candidates {
                try await drainNotifications(
                    candidate.notifications,
                    threadID: threadID,
                    mode: mode
                )
            }
        } catch {
            for (threadID, _, _) in candidates {
                notificationDrainsByThreadID.removeValue(forKey: threadID)
            }
            throw error
        }
    }

    private func beginNotificationDrains(
        _ candidates: [(
            CodexThreadID,
            DetachedReviewRoutingCandidate,
            NotificationDrainMode
        )]
    ) {
        for (threadID, _, _) in candidates {
            precondition(
                notificationDrainsByThreadID[threadID] == nil,
                "A thread may drain only one notification sequence at a time."
            )
            notificationDrainsByThreadID[threadID] = .init()
        }
    }

    private func drainNotifications(
        _ initialNotifications: [AppServerNotificationDecoder.DecodedNotification],
        threadID: CodexThreadID,
        mode: NotificationDrainMode
    ) async throws {
        guard phase.terminationError == nil else {
            return
        }
        guard notificationDrainsByThreadID[threadID] != nil else {
            preconditionFailure("A notification drain must install its routing gate first.")
        }
        if let notificationDrainPauseForTesting {
            await notificationDrainPauseForTesting()
        }
        defer {
            notificationDrainsByThreadID.removeValue(forKey: threadID)
        }
        var notifications = initialNotifications
        while true {
            for notification in notifications {
                guard phase.terminationError == nil else {
                    return
                }
                try await routeDrainedNotification(notification, mode: mode)
            }
            guard phase.terminationError == nil else {
                return
            }
            guard var drain = notificationDrainsByThreadID[threadID] else {
                preconditionFailure("An active notification drain lost its routing gate.")
            }
            if drain.queuedNotifications.isEmpty {
                return
            }
            notifications = drain.queuedNotifications
            drain.queuedNotifications.removeAll(keepingCapacity: true)
            notificationDrainsByThreadID[threadID] = drain
        }
    }

    private func routeDrainedNotification(
        _ notification: AppServerNotificationDecoder.DecodedNotification,
        mode: NotificationDrainMode
    ) async throws {
        try requireOpen()
        if case .claimedReview(let turnID) = mode,
           case .turnStarted(let startedTurnID) = notification.payload,
           (notification.context.turnID ?? startedTurnID) != turnID {
            return
        }
        if let threadID = notification.context.threadID,
           let turnID = notification.context.turnID {
            try associateNotificationTurn(turnID, threadID: threadID)
        }
        let replayRouting: ReplayRouting
        switch mode {
        case .claimedReview:
            replayRouting = .boundOnly
        case .unclaimed:
            replayRouting = .boundOnly
        }
        try await routeNotification(
            notification,
            replayRouting: replayRouting
        )
    }

    package func route(
        _ decoded: AppServerNotificationDecoder.DecodedNotification
    ) async throws {
        guard phase.terminationError == nil else {
            return
        }
        guard decoded.disposition != .explicitIgnore else {
            return
        }

        var context = decoded.context
        if context.threadID == nil, let turnID = context.turnID {
            context.threadID = threadIDByTurnID[turnID]
                ?? detachedReviewCandidatesByThreadID.first { _, candidate in
                    candidate.notifications.contains { $0.context.turnID == turnID }
                }?.key
        }
        var routed = decoded
        routed.context = context
        var replayRouting = ReplayRouting.unboundAllowed

        if let threadID = context.threadID,
           var drain = notificationDrainsByThreadID[threadID] {
            drain.queuedNotifications.append(routed)
            notificationDrainsByThreadID[threadID] = drain
            return
        }

        if let threadID = context.threadID {
            if var candidate = detachedReviewCandidatesByThreadID[threadID] {
                candidate.notifications.append(routed)
                detachedReviewCandidatesByThreadID[threadID] = candidate
                return
            }

            let localDisposition = threadEventHub.turnStartDisposition(for: threadID)
            if let turnID = context.turnID, case .turnStarted = decoded.payload {
                switch await reviewSubturnStartDisposition(turnID, threadID: threadID) {
                case .route:
                    break
                case .suppress:
                    return
                case .deferUntilOwned:
                    break
                }
            }

            let hasWriteAcceptedNonDetachedOperation = await turnReplayStore
                .hasWriteAcceptedNonDetachedOperation(for: threadID)
            let waitingAttempts = activeDetachedReviewRoutingAttempts()
            if waitingAttempts.isEmpty == false,
               hasWriteAcceptedNonDetachedOperation == false {
                replayRouting = .boundOnly
            }
            let hasKnownOwner = context.turnID.flatMap { threadIDByTurnID[$0] } != nil
                || localDisposition != .deferUntilOwned
                || hasWriteAcceptedNonDetachedOperation
            if hasKnownOwner == false {
                if waitingAttempts.isEmpty == false {
                    bufferNotification(
                        routed,
                        threadID: threadID,
                        waitingAttempts: waitingAttempts
                    )
                    return
                }
            }
        } else if activeDetachedReviewRoutingAttempts().isEmpty == false {
            replayRouting = .boundOnly
        }
        if let threadID = context.threadID, let turnID = context.turnID {
            try associateNotificationTurn(turnID, threadID: threadID)
        }
        try await routeNotification(routed, replayRouting: replayRouting)
    }

    private enum ReplayRouting {
        case unboundAllowed
        case boundOnly
    }

    private func reviewSubturnStartDisposition(
        _ turnID: CodexTurnID,
        threadID: CodexThreadID
    ) async -> ThreadEventTurnStartDisposition {
        // Codex reviews can forward the internal reviewer's turn/started with a child ID
        // while every substantive item and terminal belongs to the response's outer turn.
        // Only that advisory start is ignored; other cross-turn events remain fail-fast.
        let associatedTurnIDs = threadIDByTurnID.compactMap { associatedTurnID, associatedThreadID in
            associatedThreadID == threadID && associatedTurnID != turnID ? associatedTurnID : nil
        }
        for associatedTurnID in associatedTurnIDs {
            if await turnReplayStore.isActiveReviewGeneration(associatedTurnID) {
                return .suppress
            }
        }
        return threadEventHub.turnStartDisposition(for: threadID)
    }

    private func activeDetachedReviewRoutingAttempts() -> Set<TurnReplayPendingToken> {
        Set(detachedReviewAttempts.keys.filter(\.isWriteAccepted))
    }

    private func bufferNotification(
        _ notification: AppServerNotificationDecoder.DecodedNotification,
        threadID: CodexThreadID,
        waitingAttempts: Set<TurnReplayPendingToken>
    ) {
        detachedReviewCandidatesByThreadID[threadID] = .init(
            waitingAttempts: waitingAttempts,
            notifications: [notification]
        )
        for pending in waitingAttempts {
            detachedReviewAttempts[pending]?.candidateThreadIDs.insert(threadID)
        }
    }

    private func routeNotification(
        _ notification: AppServerNotificationDecoder.DecodedNotification,
        replayRouting: ReplayRouting = .unboundAllowed
    ) async throws {
        let context = notification.context
        switch notification.payload {
        case .turnCompleted(let turn):
            let outcome = try terminalOutcome(from: turn, context: context)
            let turnID = context.turnID ?? outcome.response.turnID
            if let threadID = context.threadID ?? threadIDByTurnID[turnID] {
                try routeThreadEvent(.terminal(outcome), threadID: threadID)
            }
            threadIDByTurnID.removeValue(forKey: turnID)
            itemReducer.release(turnID: turnID)
            if let terminalReplayPublicationPauseForTesting {
                await terminalReplayPublicationPauseForTesting()
            }
            await finishReplay(
                outcome,
                replayRouting: replayRouting
            )

        case .item(let mutation):
            guard let turnID = context.turnID else {
                preconditionFailure("Validated item notification lost turnId.")
            }
            let event = try itemReducer.reduce(mutation, turnID: turnID)
            if let threadID = context.threadID ?? threadIDByTurnID[turnID] {
                try routeThreadEvent(
                    Self.threadEvent(from: event, turnID: turnID, threadID: threadID),
                    threadID: threadID
                )
            }
            await routeReplay(
                event,
                turnID: turnID,
                replayRouting: replayRouting
            )

        case .turnStarted(let payloadTurnID):
            let turnID = context.turnID ?? payloadTurnID
            if let threadID = context.threadID ?? threadIDByTurnID[turnID] {
                try routeThreadEvent(.turnStarted(turnID), threadID: threadID)
            }
            let event = CodexTurnEvent.started(turnID)
            await routeReplay(
                event,
                turnID: turnID,
                replayRouting: replayRouting
            )

        case .threadStatus(let status):
            if let threadID = context.threadID {
                try routeThreadEvent(.statusChanged(status), threadID: threadID)
            }

        case .tokenUsage(let usage):
            if let threadID = context.threadID {
                try routeThreadEvent(
                    .tokenUsageUpdated(usage, turnID: context.turnID),
                    threadID: threadID
                )
            }
            if let turnID = context.turnID {
                let event = CodexTurnEvent.tokenUsageUpdated(usage)
                await routeReplay(
                    event,
                    turnID: turnID,
                    replayRouting: replayRouting
                )
            }

        case .threadClosed:
            if let threadID = context.threadID {
                try routeThreadEvent(.closed, threadID: threadID)
            }

        case .serverRequestResolved, .connectionDiagnostic:
            preconditionFailure("A connection-owned notification reached the domain router.")

        case .account(let mutation):
            switch mutation {
            case .updated(let update):
                await loginRegistry.applyAccountUpdate(update)
                await accountEventHub.apply(.updated(update))
            case .rateLimitsUpdated(let update):
                await accountEventHub.apply(.rateLimitsUpdated(update))
            case .loginCompleted(let completion):
                await loginRegistry.apply(completion)
            }

        case .raw:
            let raw = CodexRawNotification(
                method: notification.methodName,
                params: notification.rawData,
                threadID: context.threadID,
                turnID: context.turnID
            )
            if let threadID = context.threadID {
                try routeThreadEvent(.unknown(raw), threadID: threadID)
            }
            if let turnID = context.turnID {
                let event = CodexTurnEvent.unknown(raw)
                await routeReplay(
                    event,
                    turnID: turnID,
                    replayRouting: replayRouting
                )
            }

        case .ignored:
            preconditionFailure("Explicit-ignore notification reached the router.")
        }
    }

    private func routeReplay(
        _ event: CodexTurnEvent,
        turnID: CodexTurnID,
        replayRouting: ReplayRouting
    ) async {
        switch replayRouting {
        case .unboundAllowed:
            recordReplayDisposition(
                await turnReplayStore.routeIfTracked(event, for: turnID),
                turnID: turnID
            )
        case .boundOnly:
            recordReplayDisposition(
                await turnReplayStore.routeIfTracked(
                    event,
                    for: turnID,
                    allowsOrphanGeneration: false
                ),
                turnID: turnID
            )
        }
    }

    private func finishReplay(
        _ outcome: CodexTurnOutcome,
        replayRouting: ReplayRouting
    ) async {
        switch replayRouting {
        case .unboundAllowed:
            _ = await turnReplayStore.finishIfTracked(outcome)
        case .boundOnly:
            _ = await turnReplayStore.finishIfTracked(
                outcome,
                allowsOrphanGeneration: false
            )
        }
    }

    private func routeThreadEvent(_ event: CodexThreadEvent, threadID: CodexThreadID) throws {
        let overflowCount = try threadEventHub.route(event, for: threadID)
        if overflowCount > 0 {
            notificationRouterLogger.warning(
                "Compacted \(overflowCount, privacy: .public) slow thread event subscriber(s) for \(threadID.rawValue, privacy: .public)"
            )
        }
        if case .closed = event {
            let turnIDs = threadIDByTurnID.compactMap { entry in
                entry.value == threadID ? entry.key : nil
            }
            for turnID in turnIDs {
                itemReducer.release(turnID: turnID)
                threadIDByTurnID.removeValue(forKey: turnID)
            }
        }
    }

    private nonisolated static func threadEvent(
        from event: CodexTurnEvent,
        turnID: CodexTurnID,
        threadID: CodexThreadID
    ) -> CodexThreadEvent {
        switch event {
        case .started(let turnID):
            return .turnStarted(turnID)
        case .snapshot(let snapshot):
            return .snapshot(snapshot)
        case .itemStarted(let item):
            return .itemStarted(item, turnID: turnID)
        case .itemUpdated(let item):
            return .itemUpdated(item, turnID: turnID)
        case .itemCompleted(let item):
            return .itemCompleted(item, turnID: turnID)
        case .message(let message):
            return .message(message, turnID: turnID)
        case .messageDelta(let delta):
            return .messageDelta(delta, turnID: turnID)
        case .reasoningSummaryPartAdded(let part):
            return .reasoningSummaryPartAdded(part, turnID: turnID)
        case .reasoningDelta(let delta):
            return .reasoningDelta(delta, turnID: turnID)
        case .diagnostic(let diagnostic):
            return .diagnostic(diagnostic, turnID: turnID)
        case .tokenUsageUpdated(let usage):
            return .tokenUsageUpdated(usage, turnID: turnID)
        case .terminal(let outcome):
            return .terminal(outcome)
        case .unknown(let raw):
            var raw = raw
            raw.threadID = threadID
            raw.turnID = turnID
            return .unknown(raw)
        }
    }

    package func finishAll(with termination: CodexConnectionTermination) async {
        let error = CodexAppServerError.connectionTerminated(termination)
        guard case .open = phase else {
            return
        }
        phase = .terminating(error)
        detachedReviewAttempts.removeAll(keepingCapacity: false)
        detachedReviewCandidatesByThreadID.removeAll(keepingCapacity: false)
        threadIDByTurnID.removeAll(keepingCapacity: false)
        itemReducer.releaseAll()
        threadEventHub.finish(throwing: error)
        await turnReplayStore.terminateAll(with: termination)
        await accountEventHub.finish(throwing: error)
        await loginRegistry.finish(throwing: error)
        notificationDrainsByThreadID.removeAll(keepingCapacity: false)
        phase = .terminated(error)
    }

    package func finishLogin(throwing error: CodexAppServerError) async {
        await loginRegistry.finish(throwing: error)
    }

    package func setNotificationDrainPauseForTesting(
        _ pause: (@Sendable () async -> Void)?
    ) {
        notificationDrainPauseForTesting = pause
    }

    package func setTerminalReplayPublicationPauseForTesting(
        _ pause: (@Sendable () async -> Void)?
    ) {
        terminalReplayPublicationPauseForTesting = pause
    }

    package func turnAssociationForTesting(
        _ turnID: CodexTurnID
    ) -> CodexThreadID? {
        threadIDByTurnID[turnID]
    }

    private nonisolated func recordReplayDisposition(
        _ disposition: TurnReplayStore.RoutingDisposition,
        turnID: CodexTurnID
    ) {
        guard case .routed(let count) = disposition else {
            return
        }
        guard count > 0 else {
            return
        }
        notificationRouterLogger.warning(
            "Compacted \(count, privacy: .public) slow turn replay subscriber(s) for \(turnID.rawValue, privacy: .public)"
        )
    }

    private func requireOpen() throws {
        if let error = phase.terminationError {
            throw error
        }
    }

    private func terminalOutcome(
        from turn: AppServerAPI.Turn.Payload,
        context: NotificationContext
    ) throws -> CodexTurnOutcome {
        let turnID = CodexTurnID(rawValue: turn.id)
        if let correlatedTurnID = context.turnID, correlatedTurnID != turnID {
            throw CodexAppServerError.malformedNotification(.init(
                method: "turn/completed",
                message: "Correlated turn id \(correlatedTurnID.rawValue) does not match payload turn id \(turnID.rawValue).",
                rawData: nil
            ))
        }
        let snapshot = CodexAppServer.turnSnapshots(from: [turn])[0]
        // A terminal notification may carry only a sparse summary; without
        // itemsView, omissions cannot be treated as authoritative.
        let transcriptItemsLoadState = turn.itemsLoadState ?? .notLoaded
        let response = CodexResponse(
            turnID: snapshot.id,
            transcript: .init(items: snapshot.items),
            transcriptItemsLoadState: transcriptItemsLoadState,
            startedAt: snapshot.startedAt,
            completedAt: snapshot.completedAt,
            duration: snapshot.duration
        )
        switch snapshot.state {
        case .completed:
            return .completed(response)
        case .interrupted:
            return .interrupted(response)
        case .failed(let error):
            return .failed(.init(response: response, error: error))
        case .inProgress:
            return .invalidTerminalStatus(
                rawStatus: CodexTurnStatus.inProgress.rawValue,
                error: nil,
                response: response
            )
        case .unknown(let rawValue, let error):
            return .invalidTerminalStatus(
                rawStatus: rawValue,
                error: error,
                response: response
            )
        }
    }

}

package enum AppServerThreadItemMapping {
    package static func threadItems(from values: [AppServerJSONValue]?) -> [CodexThreadItem] {
        values?.compactMap(threadItem(from:)) ?? []
    }

    package static func threadItem(from value: AppServerJSONValue) -> CodexThreadItem? {
        guard let data = try? JSONEncoder().encode(value),
              let item = try? JSONDecoder().decode(RawThreadItem.self, from: data)
        else {
            return nil
        }
        return item.makeThreadItem(startedAt: nil, completedAt: nil, allowsFallbackID: true)
    }
}

struct RawCommandAction: Decodable {
    var kind: String
    var command: String?
    var name: String?
    var path: String?
    var query: String?

    var codexCommandAction: CodexCommand.Action {
        CodexCommand.Action(
            kind: codexKind,
            command: command,
            name: name,
            path: path,
            query: query
        )
    }

    private var codexKind: CodexCommand.Action.Kind {
        switch kind {
        case "read":
            .read
        case "listFiles", "list_files":
            .listFiles
        case "search":
            .search
        default:
            .unknown
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case kind
        case command
        case name
        case path
        case query
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decodeStringIfPresent(forKey: .type))
            ?? (try? container.decodeStringIfPresent(forKey: .kind))
            ?? "unknown"
        command = try? container.decodeStringIfPresent(forKey: .command)
        name = try? container.decodeStringIfPresent(forKey: .name)
        path = try? container.decodeStringIfPresent(forKey: .path)
        query = try? container.decodeStringIfPresent(forKey: .query)
    }
}

private struct RawFileUpdateChange: Decodable {
    var path: String
    var kind: CodexFileUpdateChange.Kind
    var diff: String

    private enum CodingKeys: String, CodingKey {
        case path
        case kind
        case diff
    }

    private enum KindCodingKeys: String, CodingKey {
        case type
        case movePath = "move_path"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        diff = try container.decode(String.self, forKey: .diff)

        let kindContainer = try container.nestedContainer(
            keyedBy: KindCodingKeys.self,
            forKey: .kind
        )
        switch try kindContainer.decode(String.self, forKey: .type) {
        case "add":
            kind = .add
        case "delete":
            kind = .delete
        case "update":
            kind = .update(
                movePath: try kindContainer.decodeIfPresent(String.self, forKey: .movePath)
            )
        case let type:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: kindContainer,
                debugDescription: "Unsupported file update change kind: \(type)"
            )
        }
    }

    var domainValue: CodexFileUpdateChange {
        .init(path: path, kind: kind, diff: diff)
    }
}

struct RawThreadItem: Decodable {
    var id: String?
    var type: String?
    var kind: String?
    var text: String?
    var review: String?
    var phase: String?
    var command: String?
    var cwd: String?
    var processID: String?
    var source: String?
    var aggregatedOutput: String?
    var output: String?
    var exitCode: Int?
    var durationMs: Int?
    var commandActions: [RawCommandAction]
    var status: String?
    var path: String?
    var namespace: String?
    var server: String?
    var tool: String?
    var name: String?
    var query: String?
    var prompt: String?
    var summary: [String]?
    var content: [String]?
    var arguments: AppServerJSONValue?
    var input: AppServerJSONValue?
    var result: AppServerJSONValue?
    var error: AppServerJSONValue?
    private var changes: [RawFileUpdateChange]?
    var rawValue: AppServerJSONValue?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case kind
        case text
        case review
        case phase
        case command
        case cwd
        case processID = "processId"
        case source
        case aggregatedOutput
        case output
        case exitCode
        case durationMs
        case commandActions
        case status
        case path
        case namespace
        case server
        case tool
        case name
        case query
        case prompt
        case summary
        case content
        case arguments
        case input
        case result
        case error
        case changes
    }

    init(from decoder: Decoder) throws {
        rawValue = try? AppServerJSONValue(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeStringIfPresent(forKey: .id)
        type = try container.decodeStringIfPresent(forKey: .type)
        kind = try container.decodeStringIfPresent(forKey: .kind)
        text = try container.decodeStringIfPresent(forKey: .text)
        review = try container.decodeStringIfPresent(forKey: .review)
        phase = try container.decodeStringIfPresent(forKey: .phase)
        command = try container.decodeStringIfPresent(forKey: .command)
        cwd = try container.decodeStringIfPresent(forKey: .cwd)
        processID = try container.decodeStringIfPresent(forKey: .processID)
        source = try container.decodeStringIfPresent(forKey: .source)
        aggregatedOutput = try container.decodeStringIfPresent(forKey: .aggregatedOutput)
        output = try container.decodeStringIfPresent(forKey: .output)
        exitCode = try? container.decodeIfPresent(Int.self, forKey: .exitCode)
        durationMs = try? container.decodeIfPresent(Int.self, forKey: .durationMs)
        commandActions = (try? container.decodeIfPresent([RawCommandAction].self, forKey: .commandActions)) ?? []
        status = try container.decodeStringIfPresent(forKey: .status)
        path = try container.decodeStringIfPresent(forKey: .path)
        namespace = try container.decodeStringIfPresent(forKey: .namespace)
        server = try container.decodeStringIfPresent(forKey: .server)
        tool = try container.decodeStringIfPresent(forKey: .tool)
        name = try container.decodeStringIfPresent(forKey: .name)
        query = try container.decodeStringIfPresent(forKey: .query)
        prompt = try container.decodeStringIfPresent(forKey: .prompt)
        summary = try container.decodeTextListIfPresent(forKey: .summary)
        content = try container.decodeTextListIfPresent(forKey: .content)
        arguments = try? container.decodeIfPresent(AppServerJSONValue.self, forKey: .arguments)
        input = try? container.decodeIfPresent(AppServerJSONValue.self, forKey: .input)
        result = try? container.decodeIfPresent(AppServerJSONValue.self, forKey: .result)
        error = try? container.decodeIfPresent(AppServerJSONValue.self, forKey: .error)
        changes = try container.decodeIfPresent([RawFileUpdateChange].self, forKey: .changes)
    }

    var threadItem: CodexThreadItem? {
        makeThreadItem(startedAt: nil, completedAt: nil)
    }

    func makeThreadItem(
        startedAt: Date?,
        completedAt: Date?,
        allowsFallbackID: Bool = false
    ) -> CodexThreadItem? {
        let rawType = type ?? kind ?? "unknown"
        let kind = CodexThreadItem.Kind(rawValue: rawType)
        guard let itemID = id ?? fallbackItemID(rawType: rawType, allowed: allowsFallbackID) else {
            return nil
        }
        guard let content = content(
            kind: kind,
            id: itemID,
            rawType: rawType,
            startedAt: startedAt,
            completedAt: completedAt
        ) else {
            return nil
        }
        return .init(
            id: itemID,
            kind: kind,
            content: content,
            rawPayload: rawPayload
        )
    }

    private func fallbackItemID(rawType: String, allowed: Bool) -> String? {
        guard allowed else {
            return nil
        }
        return "missing-id:\(rawType):\(UUID().uuidString)"
    }

    private func content(
        kind: CodexThreadItem.Kind,
        id: String,
        rawType: String,
        startedAt: Date?,
        completedAt: Date?
    ) -> CodexThreadItem.Content? {
        switch kind {
        case .userMessage:
            return .message(.init(id: id, role: .user, text: messageText))
        case .agentMessage:
            return .message(
                .init(
                    id: id,
                    role: .assistant,
                    phase: phase.map(CodexMessagePhase.init(rawValue:)),
                    text: messageText
                ))
        case .enteredReviewMode, .exitedReviewMode:
            return .log(messageText)
        case .plan:
            return .plan(messageText)
        case .reasoning:
            let summary = summary ?? []
            let content = content ?? []
            if summary.isEmpty && content.isEmpty {
                return .reasoning(.init(summary: messageText))
            }
            return .reasoning(.init(summary: summary, content: content))
        case .commandExecution:
            return .command(
                .init(
                    command: command ?? "",
                    cwd: cwd,
                    output: aggregatedOutput ?? output ?? text,
                    exitCode: exitCode,
                    status: status.map(CodexTurnStatus.init(rawValue:)),
                    startedAt: startedAt,
                    completedAt: completedAt,
                    duration: durationMs.map { .milliseconds(Int64($0)) },
                    processID: processID,
                    source: source.map(CodexCommand.Source.init(rawValue:)),
                    commandActions: commandActions.map(\.codexCommandAction)
                ))
        case .fileChange:
            guard let changes = changes?.map(\.domainValue) else {
                return nil
            }
            return .fileChange(
                .init(
                    path: changes.first?.path,
                    output: changes.isEmpty ? nil : changes.map(\.diff).joined(separator: "\n"),
                    status: status.map(CodexTurnStatus.init(rawValue:))
                ))
        case .mcpToolCall, .dynamicToolCall, .collabAgentToolCall, .subAgentActivity,
            .webSearch, .imageView, .sleep, .imageGeneration:
            return .toolCall(
                .init(
                    namespace: namespace,
                    server: server,
                    name: tool ?? name ?? query ?? path,
                    arguments: arguments?.displayText ?? input?.displayText,
                    result: result?.displayText ?? text,
                    error: error?.displayText,
                    status: status.map(CodexTurnStatus.init(rawValue:))
                ))
        case .contextCompaction:
            return .contextCompaction(status ?? text)
        case .diagnostic, .error:
            return .diagnostic(messageText)
        case .unknown:
            return .unknown(.init(rawType: rawType, text: messageText, payload: rawPayload))
        }
    }

    private var messageText: String {
        text ?? review ?? content?.joined(separator: "\n") ?? ""
    }

    private var rawPayload: Data? {
        rawValue.flatMap { try? JSONEncoder().encode($0) }
    }
}

extension KeyedDecodingContainer {
    fileprivate func decodeTextListIfPresent(forKey key: Key) throws -> [String]? {
        if let values = try? decodeIfPresent([String].self, forKey: key) {
            return values.nonEmpty
        }
        if let value = try? decodeStringIfPresent(forKey: key) {
            return [value]
        }
        if let fragments = try? decodeIfPresent([AppServerTextFragment].self, forKey: key) {
            return fragments.compactMap(\.text).nonEmpty
        }
        return nil
    }

    fileprivate func decodeStringIfPresent(forKey key: Key) throws -> String? {
        if let string = try? decode(String.self, forKey: key) {
            return string
        }
        if let int = try? decode(Int.self, forKey: key) {
            return String(int)
        }
        if let double = try? decode(Double.self, forKey: key) {
            return String(double)
        }
        if let bool = try? decode(Bool.self, forKey: key) {
            return bool ? "true" : "false"
        }
        return nil
    }
}

private struct AppServerTextFragment: Decodable {
    var text: String?

    enum CodingKeys: String, CodingKey {
        case text
    }

    init(from decoder: Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if singleValue.decodeNil() {
            text = nil
            return
        }
        if let text = try? singleValue.decode(String.self) {
            self.text = text
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeStringIfPresent(forKey: .text)
    }
}

private extension Array where Element == String {
    var nonEmpty: [String]? {
        isEmpty ? nil : self
    }
}

extension AppServerJSONValue {
    var displayText: String? {
        switch self {
        case .string(let value):
            value
        case .int(let value):
            String(value)
        case .double(let value):
            String(value)
        case .bool(let value):
            value ? "true" : "false"
        case .object(let value):
            value["displayText"]?.displayText
                ?? value["text"]?.displayText
                ?? value["message"]?.displayText
                ?? canonicalJSONString
        case .array:
            canonicalJSONString
        case .null:
            nil
        }
    }

    private var canonicalJSONString: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
