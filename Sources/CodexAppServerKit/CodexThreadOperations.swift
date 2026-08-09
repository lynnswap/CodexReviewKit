import Foundation
import Synchronization

extension CodexThread {
    /// Thread-scoped events emitted by the app-server.
    ///
    /// The sequence replays buffered events for this thread before yielding
    /// live notifications. It finishes when the app-server reports the thread
    /// as closed or when the app-server connection closes.
    package var events: CodexThreadEventSequence {
        router.events(for: id)
    }

    package func beginEventGeneration() {
        router.resetThreadEventGeneration(id)
    }

    package func makeCurrentGenerationEventStream() -> CodexThreadEventSequence {
        router.events(for: id)
    }

    /// Agent messages emitted by this thread.
    ///
    /// This sequence is derived from `events` and is useful when callers only
    /// need the conversational output rather than every item lifecycle event.
    package var messages: CodexThreadMessageSequence {
        .init(events: events)
    }

    /// Incremental transcript snapshots derived from this thread's events.
    package var transcriptUpdates: CodexThreadTranscriptSequence {
        .init(events: events)
    }

    /// Log-oriented item events for this thread.
    ///
    /// This includes command, tool, file-change, diagnostic, and unknown
    /// app-server items that are useful for output logs or progress views.
    package var logEntries: CodexThreadLogSequence {
        .init(events: events)
    }

    /// Sends a prompt to the thread and waits for the final response.
    ///
    /// Use `streamResponse(to:options:)` when the caller needs incremental
    /// progress, transcript updates, steering, or cancellation.
    ///
    /// - Parameters:
    ///   - prompt: The structured prompt to send.
    ///   - options: Per-turn generation options.
    /// - Returns: The completed response collected from app-server events.
    public func respond(
        to prompt: CodexPrompt,
        options: CodexGenerationOptions = .init(),
        timeout: Duration? = nil
    ) async throws -> CodexTurnOutcome {
        switch try await collectResponse(to: prompt, options: options, timeout: timeout) {
        case .outcome(let outcome):
            return outcome
        case .cancelled:
            throw CancellationError()
        }
    }

    package func collectResponse(
        to prompt: CodexPrompt,
        options: CodexGenerationOptions = .init(),
        timeout: Duration? = nil
    ) async throws -> CodexResponseCollectionResult {
        let cancellationRecorder = CodexResponseCancellationRecorder()
        let stream: CodexResponseStream
        do {
            stream = try await streamResponse(
                to: prompt,
                options: options,
                cancellationRecorder: cancellationRecorder
            )
        } catch is CancellationError {
            guard let outcome = cancellationRecorder.outcome else {
                throw CancellationError()
            }
            return .cancelled(outcome)
        }
        do {
            let outcome = try await stream.collect(timeout: timeout)
            try Task.checkCancellation()
            return .outcome(outcome)
        } catch is CancellationError {
            return .cancelled(try await interruptAndAwaitTerminal(stream))
        } catch let error as CodexAppServerError {
            if case .turnDeadlineExceeded = error {
                _ = try await interruptAndAwaitTerminal(stream)
            }
            throw error
        }
    }

    /// Sends a text prompt to the thread and waits for the final response.
    public func respond(
        to prompt: String,
        options: CodexGenerationOptions = .init(),
        timeout: Duration? = nil
    ) async throws -> CodexTurnOutcome {
        try await respond(to: CodexPrompt(prompt), options: options, timeout: timeout)
    }

    /// Builds a structured prompt, sends it to the thread, and waits for the final response.
    public func respond(
        options: CodexGenerationOptions = .init(),
        timeout: Duration? = nil,
        @CodexPromptBuilder prompt: () throws -> CodexPrompt
    ) async throws -> CodexTurnOutcome {
        try await respond(to: try prompt(), options: options, timeout: timeout)
    }

    /// Sends a prompt and returns a live response stream.
    ///
    /// The returned stream exposes events, progress, transcript updates, the
    /// collected result, and Codex-specific controls such as steer and cancel.
    ///
    /// - Parameters:
    ///   - prompt: The structured prompt to send.
    ///   - options: Per-turn generation options.
    /// - Returns: A live response stream for the started turn.
    package func streamResponse(
        to prompt: CodexPrompt,
        options: CodexGenerationOptions = .init()
    ) async throws -> CodexResponseStream {
        try await streamResponse(
            to: prompt,
            options: options,
            cancellationRecorder: nil
        )
    }

    private func streamResponse(
        to prompt: CodexPrompt,
        options: CodexGenerationOptions,
        cancellationRecorder: CodexResponseCancellationRecorder?
    ) async throws -> CodexResponseStream {
        let turn = try await startTurn(
            prompt,
            options: options,
            cancellationRecorder: cancellationRecorder
        )
        return .init(turn: turn)
    }

    /// Sends a text prompt and returns a live response stream.
    package func streamResponse(
        to prompt: String,
        options: CodexGenerationOptions = .init()
    ) async throws -> CodexResponseStream {
        try await streamResponse(to: CodexPrompt(prompt), options: options)
    }

    /// Builds a structured prompt, sends it, and returns a live response stream.
    package func streamResponse(
        options: CodexGenerationOptions = .init(),
        @CodexPromptBuilder prompt: () throws -> CodexPrompt
    ) async throws -> CodexResponseStream {
        try await streamResponse(to: try prompt(), options: options)
    }

    /// Starts a Codex code review in this thread.
    ///
    /// The returned session owns the source, active review-thread, and turn
    /// identities and exposes the review's typed terminal outcome. Native UI
    /// consumers observe the corresponding chat through CodexDataKit instead
    /// of constructing a second model graph from transport events.
    ///
    /// - Parameters:
    ///   - target: The repository changes or custom instructions to review.
    ///   - delivery: Whether the app-server should run the review inline or in a detached review thread.
    /// - Returns: A live review session.
    public func startReview(
        target: CodexReviewTarget,
        delivery: CodexReviewDelivery = .inline
    ) async throws -> CodexReviewSession {
        try await startReview(
            target: target,
            delivery: delivery,
            onPostWriteCancellation: { review in
                try await cleanupCancelledReviewSession(review)
            }
        )
    }

    package func startReview(
        target: CodexReviewTarget,
        delivery: CodexReviewDelivery = .inline,
        onPostWriteCancellation: @escaping @Sendable (CodexReviewSession) async throws -> Void
    ) async throws -> CodexReviewSession {
        let state = TurnGenerationHandleState(connectionLease: connectionLease)
        let pending = await turnReplayStore.registerPendingOperation(
            kind: .review(sourceThreadID: id, delivery: delivery),
            state: state
        )
        if delivery == .detached {
            await router.registerDetachedReviewRoutingAttempt(pending)
        }
        do {
            let response: AppServerAPI.Review.Start.Response = try await withThreadEventGeneration(
                id,
                router: router,
                generationOperation: .reviewStart(delivery: delivery)
            ) { generation in
                try await client.send(
                    AppServerAPI.Review.Start.Request(
                        params: .init(threadID: id.rawValue, target: target, delivery: delivery)
                    ),
                    reconcileResponse: { response in
                        let responseThreadID = CodexThreadID(
                            rawValue: response.reviewThreadID
                        )
                        switch delivery {
                        case .inline:
                            guard responseThreadID == id else {
                                throw CodexTransportFailure.contractViolation(
                                    message: "An inline review must run on its source thread."
                                )
                            }
                        case .detached:
                            guard responseThreadID != id else {
                                throw CodexTransportFailure.contractViolation(
                                    message: "A detached review must run on a new review thread."
                                )
                            }
                        }
                        try await router.reconcileReviewStartResponse(
                            pending,
                            reviewThreadID: responseThreadID,
                            initialSnapshot: CodexAppServer.turnSnapshots(
                                from: [response.turn]
                            )[0],
                            generation: generation
                        )
                    },
                    onWriteAccepted: {
                        generation.acceptWrite()
                        pending.acceptWrite()
                    },
                    onResponseRejected: {
                        generation.rejectResponse()
                        pending.rejectAcceptedWrite()
                        try await router.rejectDetachedReviewRoutingAttemptResponse(pending)
                    },
                    onPostWriteCancellation: { response in
                        let review = await reviewSession(
                            from: response,
                            state: state
                        )
                        try await onPostWriteCancellation(review)
                    }
                )
            }
            return await reviewSession(from: response, state: state)
        } catch let operationError {
            do {
                try await router.cancelDetachedReviewRoutingAttempt(pending)
            } catch {
                await finishPendingTurnOperation(
                    pending,
                    state: state,
                    store: turnReplayStore
                )
                throw error
            }
            await finishPendingTurnOperation(
                pending,
                state: state,
                store: turnReplayStore
            )
            throw operationError
        }
    }

    private func reviewSession(
        from response: AppServerAPI.Review.Start.Response,
        state: TurnGenerationHandleState
    ) async -> CodexReviewSession {
        let responseReviewThreadID = CodexThreadID(rawValue: response.reviewThreadID)
        let detachedReviewThreadID = responseReviewThreadID == id ? nil : responseReviewThreadID
        let turnID = CodexTurnID(rawValue: response.turnID)
        let initialTurn = CodexAppServer.turnSnapshots(from: [response.turn])[0]
        let identity = CodexReviewIdentity(
            threadID: id,
            turnID: turnID,
            reviewThreadID: detachedReviewThreadID,
            model: detachedReviewThreadID == nil ? model : nil
        )
        return await reviewSession(
            identity,
            initialTurn: initialTurn,
            state: state
        )
    }

    private func cleanupCancelledReviewSession(
        _ review: CodexReviewSession
    ) async throws {
        _ = try await review.interruptAndAwaitTerminalAcknowledgement()
        guard review.reviewThreadID != id else {
            return
        }
        let _: EmptyResponse = try await client.send(
            AppServerAPI.Thread.Delete.Request(
                params: .init(threadID: review.reviewThreadID.rawValue)
            )
        )
    }

    package func reviewSession(
        _ identity: CodexReviewIdentity,
        model: String? = nil,
        initialTurn: CodexTurnSnapshot? = nil,
        state proposedState: TurnGenerationHandleState? = nil
    ) async -> CodexReviewSession {
        let reviewThreadID = identity.activeTurnThreadID
        let initialTurn = initialTurn ?? CodexTurnSnapshot(
            id: identity.turnID,
            state: .inProgress,
            itemsLoadState: .notLoaded
        )
        let state: TurnGenerationHandleState
        if let proposedState {
            state = proposedState
        } else {
            state = await turnReplayStore.restoreGeneration(
                turnID: identity.turnID,
                initialSnapshot: initialTurn,
                connectionLease: connectionLease
            )
        }
        if await state.snapshot() == .live {
            await router.adoptThreadEventGeneration(
                reviewThreadID,
                including: identity.turnID
            )
        }
        let model = model ?? identity.model
        let turn = CodexTurn(
            id: identity.turnID,
            threadID: reviewThreadID,
            client: client,
            router: router,
            turnReplayStore: turnReplayStore,
            state: state
        )
        return .init(
            threadID: identity.sourceThreadID,
            turnID: turn.id,
            reviewThreadID: reviewThreadID,
            model: model,
            initialTurn: initialTurn,
            response: .init(turn: turn)
        )
    }

    /// Cancels the currently active turn for this thread.
    ///
    /// Use this when the caller has a resumed `CodexThread` handle but no
    /// in-memory response or review session object, such as after restoring a
    /// persisted running operation.
    ///
    /// - Parameters:
    ///   - expectedTurnID: The turn the caller expects to cancel. When the
    ///     app-server reports a newer active turn, the returned cancellation
    ///     identifies the actual cancelled turn. Pass `nil` to submit an
    ///     unguarded startup interrupt; that response does not reveal the
    ///     active turn identity.
    ///   - willCancelActiveTurn: Optional hook invoked before retrying an
    ///     cancellation for a newer active turn reported by app-server.
    /// - Returns: The expected or redirected turn when known, or a cancellation
    ///   with no turn identity for an unguarded startup interrupt.
    @discardableResult
    public func cancelActiveTurn(
        expectedTurnID: CodexTurnID? = nil,
        willCancelActiveTurn: (@Sendable (CodexTurnCancellation) async -> Void)? = nil
    ) async throws -> CodexTurnCancellation {
        try await interruptCodexTurn(
            threadID: id,
            turnID: expectedTurnID,
            client: client,
            willCancelActiveTurn: willCancelActiveTurn
        )
    }

    package func startTurn(
        _ prompt: CodexPrompt,
        options: CodexGenerationOptions = .init(),
        cancellationRecorder: CodexResponseCancellationRecorder? = nil
    ) async throws -> CodexTurn {
        try await startCodexTurn(
            threadID: id,
            prompt: prompt,
            options: options,
            client: client,
            router: router,
            connectionLease: connectionLease,
            cancellationRecorder: cancellationRecorder
        )
    }

    /// Reads the current thread snapshot.
    ///
    /// - Parameter includeTurns: Whether to include turn summaries in the snapshot.
    /// - Returns: The current app-server snapshot for this thread.
    public func read(includeTurns: Bool = false) async throws -> CodexThreadSnapshot {
        let response = try await client.send(
            AppServerAPI.Thread.Read.Request(
                params: .init(threadID: id.rawValue, includeTurns: includeTurns)
            ))
        let snapshot = CodexAppServer.threadSnapshot(
            from: response.thread,
            includesTurns: includeTurns
        )
        await router.seedTurns(snapshot.turns, threadID: id)
        if let currentTurn = snapshot.turns?.last {
            await router.seedCurrentTurnSnapshot(currentTurn, threadID: id)
        }
        return snapshot
    }

    /// Lists this thread's turns.
    ///
    /// This endpoint can include the app-server's current in-memory active turn
    /// snapshot, so it is the preferred source for UI detail panes that need an
    /// initial transcript before consuming live item events.
    public func listTurns(_ query: CodexTurnQuery = .init()) async throws -> CodexTurnPage {
        let response = try await client.send(
            AppServerAPI.Thread.Turns.List.Request(
                params: .init(
                    threadID: id.rawValue,
                    cursor: query.cursor,
                    limit: query.limit,
                    sortDirection: query.sortDirection,
                    itemsLoadState: query.itemsLoadState
                )
            ))
        let turns = CodexAppServer.turnSnapshots(from: response.data)
        await router.seedTurns(turns, threadID: id)
        let currentTurn: CodexTurnSnapshot?
        switch query.sortDirection ?? .descending {
        case .ascending where response.nextCursor == nil:
            currentTurn = turns.last
        case .descending where query.cursor == nil:
            currentTurn = turns.first
        default:
            currentTurn = nil
        }
        if let currentTurn {
            await router.seedCurrentTurnSnapshot(currentTurn, threadID: id)
        }
        return .init(
            turns: turns,
            nextCursor: response.nextCursor,
            backwardsCursor: response.backwardsCursor
        )
    }

    /// Renames this thread.
    ///
    /// - Parameter name: The new user-visible thread name.
    public func rename(to name: String) async throws {
        let _: EmptyResponse = try await client.send(
            AppServerAPI.Thread.Name.Set.Request(
                params: .init(threadID: id.rawValue, name: name)
            ))
    }

    /// Starts app-server context compaction for this thread.
    public func compact() async throws {
        let _: EmptyResponse = try await withThreadEventGeneration(id, router: router) { generation in
            try await client.send(
                AppServerAPI.Thread.Compact.Start.Request(
                    params: .init(threadID: id.rawValue)
                ),
                onWriteAccepted: generation.acceptWrite,
                onResponseRejected: generation.rejectResponse,
                onResponseAccepted: generation.acceptResponse
            )
        }
    }

    /// Archives this thread.
    public func archive() async throws {
        let _: EmptyResponse = try await client.send(
            AppServerAPI.Thread.Archive.Request(
                params: .init(threadID: id.rawValue)
            ))
    }

    /// Restores this thread from the archive.
    ///
    /// - Returns: The restored thread snapshot.
    public func unarchive() async throws -> CodexThreadSnapshot {
        let response = try await client.send(
            AppServerAPI.Thread.Unarchive.Request(
                params: .init(threadID: id.rawValue)
            ))
        let snapshot = CodexAppServer.threadSnapshot(from: response.thread, includesTurns: false)
        await router.seedTurns(snapshot.turns, threadID: id)
        return snapshot
    }

    /// Rolls this thread back by the specified number of turns.
    ///
    /// - Parameter turnCount: The number of latest turns to remove.
    package func rollback(turnCount: Int = 1) async throws {
        let _: EmptyResponse = try await client.send(
            AppServerAPI.Thread.Rollback.Request(
                params: .init(threadID: id.rawValue, numTurns: turnCount)
            ))
    }

    /// Permanently deletes this thread.
    public func delete() async throws {
        let _: EmptyResponse = try await client.send(
            AppServerAPI.Thread.Delete.Request(
                params: .init(threadID: id.rawValue)
            ))
    }

    /// Closes the app-server connection shared by this thread.
    public func closeConnection() async {
        await connectionLease.closeConnection()
    }
}

package enum CodexResponseCollectionResult: Sendable {
    case outcome(CodexTurnOutcome)
    case cancelled(CodexTurnOutcome)
}

package final class CodexResponseCancellationRecorder: Sendable {
    private let storedOutcome = Mutex<CodexTurnOutcome?>(nil)

    package var outcome: CodexTurnOutcome? {
        storedOutcome.withLock { $0 }
    }

    package func record(_ outcome: CodexTurnOutcome) {
        storedOutcome.withLock { storedOutcome in
            precondition(
                storedOutcome == nil,
                "A response collection can record only one cancellation outcome."
            )
            storedOutcome = outcome
        }
    }
}

package func interruptAndAwaitTerminal(_ stream: CodexResponseStream) async throws -> CodexTurnOutcome {
    let cleanup = Task {
        try await stream.turn.interruptAndAwaitTerminalAcknowledgement().outcome
    }
    return try await cleanup.value
}

package func startCodexTurn(
    threadID: CodexThreadID,
    prompt: CodexPrompt,
    options: CodexGenerationOptions = .init(),
    client: AppServerClient,
    router: CodexAppServerNotificationRouter,
    connectionLease: AppServerConnectionLease,
    cancellationRecorder: CodexResponseCancellationRecorder? = nil
) async throws -> CodexTurn {
    let store = router.turnReplayStore
    let state = TurnGenerationHandleState(connectionLease: connectionLease)
    let pending = await store.registerPendingOperation(
        kind: .turn(threadID: threadID),
        state: state
    )
    do {
        let response: AppServerAPI.Turn.Start.Response = try await withThreadEventGeneration(
            threadID,
            router: router
        ) { generation in
            try await client.send(
                AppServerAPI.Turn.Start.Request(
                    params: .init(
                        threadID: threadID.rawValue,
                        input: prompt.appServerInput,
                        approvalPolicy: options.approvalMode?.approvalPolicy,
                        approvalsReviewer: options.approvalMode?.approvalsReviewer,
                        clientUserMessageID: options.clientUserMessageID,
                        cwd: options.cwd?.path,
                        effort: options.effort?.rawValue,
                        model: options.model,
                        outputSchema: options.outputSchema?.appServerJSONValue,
                        personality: options.personality?.rawValue,
                        sandboxPolicy: options.sandbox?.turnSandboxPolicy,
                        serviceTier: options.serviceTier,
                        summary: options.summary?.rawValue
                    )
                ),
                reconcileResponse: { response in
                    try generation.seedResponseSnapshot(
                        CodexAppServer.turnSnapshots(from: [response.turn])[0]
                    )
                },
                onWriteAccepted: {
                    generation.acceptWrite()
                    pending.acceptWrite()
                },
                onResponseRejected: {
                    generation.rejectResponse()
                    pending.rejectAcceptedWrite()
                },
                onResponseAccepted: generation.acceptResponse,
                onPostWriteCancellation: { response in
                    let turn = await bindTurn(
                        response,
                        threadID: threadID,
                        client: client,
                        router: router,
                        store: store,
                        pending: pending,
                        state: state
                    )
                    let acknowledgement = try await turn
                        .interruptAndAwaitTerminalAcknowledgement()
                    cancellationRecorder?.record(acknowledgement.outcome)
                }
            )
        }
        return await bindTurn(
            response,
            threadID: threadID,
            client: client,
            router: router,
            store: store,
            pending: pending,
            state: state
        )
    } catch {
        await finishPendingTurnOperation(pending, state: state, store: store)
        throw error
    }
}

private func bindTurn(
    _ response: AppServerAPI.Turn.Start.Response,
    threadID: CodexThreadID,
    client: AppServerClient,
    router: CodexAppServerNotificationRouter,
    store: TurnReplayStore,
    pending: TurnReplayPendingToken,
    state: TurnGenerationHandleState
) async -> CodexTurn {
    let snapshot = CodexAppServer.turnSnapshots(from: [response.turn])[0]
    let turnID = snapshot.id
    await store.bind(pending, to: turnID, initialSnapshot: snapshot)
    await router.seedTurn(turnID, threadID: threadID)
    return CodexTurn(
        id: turnID,
        threadID: threadID,
        client: client,
        router: router,
        turnReplayStore: store,
        state: state
    )
}

private func finishPendingTurnOperation(
    _ pending: TurnReplayPendingToken,
    state: TurnGenerationHandleState,
    store: TurnReplayStore
) async {
    switch await store.cancelPendingOperation(pending) {
    case .removedBeforeWrite:
        return
    case .retainedAfterWrite:
        await store.waitForTermination(retaining: state)
    case .notRegistered:
        guard await state.snapshot() == .live else {
            return
        }
        await state.closeConnection()
        await store.waitForTermination(retaining: state)
    }
}

extension CodexReviewSession {
    package func interruptAndAwaitTerminalAcknowledgement(
        willCancelActiveTurn: (@Sendable (CodexTurnCancellation) async -> Void)? = nil
    ) async throws -> CodexTurnInterruptionAcknowledgement {
        let acknowledgement = try await response.turn.interruptAndAwaitTerminalAcknowledgement(
            adoptsRedirectedTurnAsThreadEventOwner:
                activeTurnThreadID != sourceThreadID,
            willCancelActiveTurn: willCancelActiveTurn
        )
        guard activeTurnThreadID == sourceThreadID,
              acknowledgement.cancellation.turnID != Optional(turnID) else {
            return acknowledgement
        }

        // An inline review's redirected child is a TurnReplay generation only.
        // The source thread remains on the outer review turn, whose terminal is
        // emitted after the child acknowledges interruption.
        let outerOutcome = try await response.waitForCancelledResponse(.init(
            threadID: activeTurnThreadID,
            turnID: turnID
        ))
        return .init(
            cancellation: acknowledgement.cancellation,
            outcome: outerOutcome
        )
    }
}

package func withThreadEventGeneration<Response: Sendable>(
    _ threadID: CodexThreadID,
    router: CodexAppServerNotificationRouter,
    generationOperation: ThreadEventGenerationOperation = .standard,
    operation: @Sendable (ThreadEventGenerationAttempt) async throws -> Response
) async throws -> Response {
    let hub = router.threadEventHub
    let checkpoint = try hub.registerCheckpoint(for: threadID, operation: generationOperation)
    let generation = ThreadEventGenerationAttempt(hub: hub, checkpoint: checkpoint)
    do {
        return try await operation(generation)
    } catch {
        hub.discard(checkpoint)
        throw error
    }
}

package struct ThreadEventGenerationAttempt: Sendable {
    private let hub: ThreadEventHub
    private let checkpoint: ThreadEventGenerationCheckpoint

    fileprivate init(hub: ThreadEventHub, checkpoint: ThreadEventGenerationCheckpoint) {
        self.hub = hub
        self.checkpoint = checkpoint
    }

    package func acceptWrite() {
        hub.activate(checkpoint)
    }

    package func rejectResponse() {
        hub.reject(checkpoint)
    }

    package func seedResponseSnapshot(_ snapshot: CodexTurnSnapshot) throws {
        try hub.seed(snapshot, at: checkpoint)
    }

    package func seedProvisionalResumeSnapshot(_ snapshot: CodexTurnSnapshot) {
        hub.seedProvisionalResumeSnapshot(snapshot, at: checkpoint)
    }

    package func resolveReviewStartResponse(
        eventThreadID: CodexThreadID,
        responseSnapshot: CodexTurnSnapshot
    ) throws {
        try hub.resolveReviewStart(
            checkpoint,
            eventThreadID: eventThreadID,
            responseSnapshot: responseSnapshot
        )
    }

    package func acceptResponse() {
        hub.commit(checkpoint)
    }
}

extension CodexTurn {
    package var events: CodexTurnEventSequence {
        .init(turnID: id, store: turnReplayStore, state: state)
    }

    package var progress: CodexTurnProgressSequence {
        .init(turnID: id, store: turnReplayStore, state: state)
    }

    package func result() async throws -> CodexTurnOutcome {
        try await CodexResponseCollector.collect(from: events)
    }

    package func steer(with prompt: CodexPrompt) async throws {
        let _: AppServerAPI.Turn.Steer.Response = try await client.send(
            AppServerAPI.Turn.Steer.Request(
                params: .init(
                    threadID: threadID.rawValue,
                    expectedTurnID: id.rawValue,
                    input: prompt.appServerInput
                )
            ))
    }

    package func steer(with prompt: String) async throws {
        try await steer(with: CodexPrompt(prompt))
    }

    @discardableResult
    package func interrupt() async throws -> CodexTurnCancellation {
        if try await state.cachedOutcome() != nil {
            return .init(threadID: threadID, turnID: id)
        }
        return try await interruptCodexTurn(threadID: threadID, turnID: id, client: client)
    }

    @discardableResult
    package func interrupt(
        willCancelActiveTurn: (@Sendable (CodexTurnCancellation) async -> Void)?
    ) async throws -> CodexTurnCancellation {
        if try await state.cachedOutcome() != nil {
            return .init(threadID: threadID, turnID: id)
        }
        return try await interruptCodexTurn(
            threadID: threadID,
            turnID: id,
            client: client,
            willCancelActiveTurn: willCancelActiveTurn
        )
    }

    @discardableResult
    package func interruptAndAwaitTerminal(
        willCancelActiveTurn: (@Sendable (CodexTurnCancellation) async -> Void)? = nil
    ) async throws -> CodexTurnCancellation {
        try await interruptAndAwaitTerminalAcknowledgement(
            willCancelActiveTurn: willCancelActiveTurn
        ).cancellation
    }

    package func interruptAndAwaitTerminalAcknowledgement(
        willCancelActiveTurn: (@Sendable (CodexTurnCancellation) async -> Void)? = nil
    ) async throws -> CodexTurnInterruptionAcknowledgement {
        try await interruptAndAwaitTerminalAcknowledgement(
            adoptsRedirectedTurnAsThreadEventOwner: true,
            willCancelActiveTurn: willCancelActiveTurn
        )
    }

    fileprivate func interruptAndAwaitTerminalAcknowledgement(
        adoptsRedirectedTurnAsThreadEventOwner: Bool,
        willCancelActiveTurn: (@Sendable (CodexTurnCancellation) async -> Void)?
    ) async throws -> CodexTurnInterruptionAcknowledgement {
        if let outcome = try await state.cachedOutcome() {
            let cancellation = CodexTurnCancellation(threadID: threadID, turnID: id)
            return .init(
                cancellation: cancellation,
                outcome: outcome
            )
        }
        let connectionLease = try await state.connectionLeaseForSiblingGeneration()
        let prepared = try await interruptCodexTurnPreparingTarget(
            threadID: threadID,
            turnID: id,
            client: client,
            router: router,
            originalState: state,
            store: turnReplayStore,
            connectionLease: connectionLease,
            adoptsRedirectedTurnAsThreadEventOwner: adoptsRedirectedTurnAsThreadEventOwner,
            willCancelActiveTurn: willCancelActiveTurn
        )
        let outcome = try await CodexResponseStream(turn: self).waitForCancelledResponse(
            prepared.cancellation,
            preparedState: prepared.state
        )
        return .init(cancellation: prepared.cancellation, outcome: outcome)
    }
}

package struct CodexTurnInterruptionAcknowledgement: Sendable {
    package var cancellation: CodexTurnCancellation
    package var outcome: CodexTurnOutcome
}

private struct PreparedTurnInterruption: Sendable {
    var cancellation: CodexTurnCancellation
    var state: TurnGenerationHandleState
}

private func interruptCodexTurnPreparingTarget(
    threadID: CodexThreadID,
    turnID: CodexTurnID,
    client: AppServerClient,
    router: CodexAppServerNotificationRouter,
    originalState: TurnGenerationHandleState,
    store: TurnReplayStore,
    connectionLease: AppServerConnectionLease,
    adoptsRedirectedTurnAsThreadEventOwner: Bool,
    willCancelActiveTurn: (@Sendable (CodexTurnCancellation) async -> Void)?
) async throws -> PreparedTurnInterruption {
    var resolver = InterruptRaceResolver(expectedTurnID: turnID)
    while true {
        do {
            try await sendInterrupt(threadID: threadID, turnID: turnID, client: client)
            return .init(
                cancellation: .init(threadID: threadID, turnID: turnID),
                state: originalState
            )
        } catch {
            switch resolver.decision(for: error) {
            case .retry(let delay):
                try await client.sleepForInterruptRace(delay)
                continue
            case .fail:
                throw error
            case .redirect(let activeTurn):
                let cancellation = CodexTurnCancellation(threadID: threadID, turnID: activeTurn)
                let state = await store.restoreGeneration(
                    turnID: activeTurn,
                    initialSnapshot: .init(
                        id: activeTurn,
                        state: .inProgress,
                        itemsLoadState: .notLoaded
                    ),
                    connectionLease: connectionLease
                )
                if adoptsRedirectedTurnAsThreadEventOwner {
                    await router.adoptThreadEventGeneration(threadID, including: activeTurn)
                }
                if let willCancelActiveTurn {
                    await willCancelActiveTurn(cancellation)
                }
                try await sendInterrupt(threadID: threadID, turnID: activeTurn, client: client)
                return .init(cancellation: cancellation, state: state)
            }
        }
    }
}

@discardableResult
package func interruptCodexTurn(
    threadID: CodexThreadID,
    turnID: CodexTurnID?,
    client: AppServerClient,
    willCancelActiveTurn: (@Sendable (CodexTurnCancellation) async -> Void)? = nil
) async throws -> CodexTurnCancellation {
    var resolver = InterruptRaceResolver(expectedTurnID: turnID)
    while true {
        do {
            try await sendInterrupt(threadID: threadID, turnID: turnID, client: client)
            return .init(threadID: threadID, turnID: turnID)
        } catch {
            switch resolver.decision(for: error) {
            case .retry(let delay):
                try await client.sleepForInterruptRace(delay)
                continue
            case .fail:
                throw error
            case .redirect(let activeTurn):
                let cancellation = CodexTurnCancellation(threadID: threadID, turnID: activeTurn)
                if let willCancelActiveTurn {
                    await willCancelActiveTurn(cancellation)
                }
                try await sendInterrupt(threadID: threadID, turnID: activeTurn, client: client)
                return cancellation
            }
        }
    }
}

private func sendInterrupt(
    threadID: CodexThreadID,
    turnID: CodexTurnID?,
    client: AppServerClient
) async throws {
    let _: EmptyResponse = try await client.send(
        AppServerAPI.Turn.Interrupt.Request(
            params: .init(threadID: threadID.rawValue, turnID: turnID?.rawValue ?? "")
        ))
}

extension CodexPrompt {
    package var appServerInput: [AppServerAPI.UserInput] {
        parts.map { part in
            switch part {
            case .text(let text):
                .text(text)
            case .imageURL(let url):
                .image(url: url.absoluteString)
            case .localImage(let url):
                .localImage(path: url.path)
            case .skill(let name, let path):
                .skill(name: name, path: path.path)
            case .mention(let name, let path):
                .mention(name: name, path: path.appServerMentionPath)
            }
        }
    }
}

private extension URL {
    var appServerMentionPath: String {
        isFileURL ? path : absoluteString
    }
}
