import Foundation

package struct ReviewWorkerState: Sendable {
    package struct Outage: Sendable {
        package let epoch: UInt64
        package let observedAt: ReviewWorkerClock.Instant
        package let presentationDate: Date
    }

    package enum LiveNetworkPhase: Sendable {
        case satisfied
        case pendingOutage(
            Outage,
            heldConnectionTermination: ReviewBackendConnectionTermination?
        )
    }

    package enum WaitingConnectivity: Sendable {
        case unsatisfied(nextSettleGeneration: UInt64)
        case settling(generation: UInt64)
    }

    package enum Stage: Sendable {
        case live(attempt: BackendReviewAttempt, network: LiveNetworkPhase)
        case preparingRestart(interruptedAttempt: ReviewAttempt, outage: Outage)
        case waitingForNetwork(
            interruptedAttempt: ReviewAttempt,
            outage: Outage,
            token: CodexReviewBackendModel.Review.RestartToken,
            connectivity: WaitingConnectivity
        )
        case restarting(
            interruptedAttempt: ReviewAttempt,
            outage: Outage,
            token: CodexReviewBackendModel.Review.RestartToken
        )
    }

    package var attemptGeneration: UInt64
    package var nextOutageEpoch: UInt64
    package var stage: Stage
}

package struct ReviewWorkerConnectivitySnapshot: Sendable {
    package enum Connectivity: Sendable {
        case satisfied
        case outage
    }

    package let connectivity: Connectivity
    package let observedAt: ReviewWorkerClock.Instant
    package let presentationDate: Date

    init(
        _ snapshot: CodexReviewNetworkSnapshot,
        clock: ReviewWorkerClock
    ) {
        switch snapshot.status {
        case .satisfied:
            connectivity = .satisfied
        case .unsatisfied, .requiresConnection:
            connectivity = .outage
        }
        observedAt = clock.now
        presentationDate = snapshot.observedAt
    }
}

package enum ReviewWorkerSignal: Sendable {
    case backendTerminal(generation: UInt64, ReviewBackendTerminal)
    case resultWaitCancelled(generation: UInt64)
    case networkSnapshot(generation: UInt64, ReviewWorkerConnectivitySnapshot)
    case networkSourceFinished(generation: UInt64)
    case outageDebounceElapsed(generation: UInt64, outageEpoch: UInt64)
    case outageDebounceCancelled(generation: UInt64, outageEpoch: UInt64)
    case recoverySettleElapsed(
        generation: UInt64,
        outageEpoch: UInt64,
        settleGeneration: UInt64
    )
    case recoverySettleCancelled(
        generation: UInt64,
        outageEpoch: UInt64,
        settleGeneration: UInt64
    )
    case prepareRestartCompleted(
        generation: UInt64,
        outageEpoch: UInt64,
        Result<CodexReviewBackendModel.Review.RestartToken, ReviewBackendFailure>
    )
    case prepareRestartCancelled(generation: UInt64, outageEpoch: UInt64)
    case restartCompleted(
        generation: UInt64,
        outageEpoch: UInt64,
        Result<BackendReviewAttempt, ReviewBackendFailure>
    )
    case restartCancelled(generation: UInt64, outageEpoch: UInt64)

    var generation: UInt64 {
        switch self {
        case .backendTerminal(let generation, _),
             .resultWaitCancelled(let generation),
             .networkSnapshot(let generation, _),
             .networkSourceFinished(let generation),
             .outageDebounceElapsed(let generation, _),
             .outageDebounceCancelled(let generation, _),
             .recoverySettleElapsed(let generation, _, _),
             .recoverySettleCancelled(let generation, _, _),
             .prepareRestartCompleted(let generation, _, _),
             .prepareRestartCancelled(let generation, _),
             .restartCompleted(let generation, _, _),
             .restartCancelled(let generation, _):
            generation
        }
    }
}

@MainActor
struct ReviewStoreWorker {
    let runID: ReviewRunID
    let startRequest: CodexReviewBackendModel.Review.Start
    let backend: any CodexReviewStoreBackend
    let networkMonitor: any CodexReviewNetworkMonitoring
    let networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy
    let retentionRegistry: ReviewThreadRetentionRegistry
    let retentionScope: ReviewThreadRetentionScope
    let sink: ReviewStoreCommitSink
    let workerGeneration: ReviewWorkerGeneration

    func run() async {
        defer {
            sink.workerFinished(runID: runID, generation: workerGeneration)
        }

        let initialAttempt: BackendReviewAttempt
        do {
            initialAttempt = try await backend.startReview(startRequest)
        } catch is CancellationError {
            sink.commitWorkerCancellation(for: runID)
            return
        } catch {
            sink.markWorkerFailure(
                backendFailure(error, operation: "startReview"),
                for: runID
            )
            return
        }

        switch sink.startupDisposition(for: runID) {
        case .cleanupOnly(let cancellation):
            await rollbackUnpublishedAttempt(
                initialAttempt.attempt,
                cancellation: cancellation,
                claimOwnership: true
            )
            return
        case .abandoned:
            await rollbackUnpublishedAttempt(
                initialAttempt.attempt,
                cancellation: .system(),
                claimOwnership: true
            )
            return
        case .proceed:
            break
        }

        do {
            try await claimRetention(initialAttempt.attempt)
        } catch let failure as ReviewBackendFailure {
            sink.markWorkerFailure(failure, for: runID)
            return
        } catch {
            sink.markWorkerFailure(
                .protocolViolation(
                    message: "Review retention ownership failed with an unsupported error: \(error.localizedDescription)"
                ),
                for: runID
            )
            return
        }

        switch sink.startupDisposition(for: runID) {
        case .cleanupOnly(let cancellation):
            await rollbackUnpublishedAttempt(
                initialAttempt.attempt,
                cancellation: cancellation,
                claimOwnership: false
            )
            return
        case .abandoned:
            await rollbackUnpublishedAttempt(
                initialAttempt.attempt,
                cancellation: .system(),
                claimOwnership: false
            )
            return
        case .proceed:
            break
        }

        guard sink.publishAttempt(
            initialAttempt.attempt,
            runID: runID,
            attemptGeneration: 0
        ) else {
            await rollbackUnpublishedAttempt(
                initialAttempt.attempt,
                cancellation: .system(),
                claimOwnership: false
            )
            return
        }

        var cleanedAttempts: Set<ReviewAttemptID> = []
        var state = ReviewWorkerState(
            attemptGeneration: 0,
            nextOutageEpoch: 1,
            stage: .live(attempt: initialAttempt, network: .satisfied)
        )

        while true {
            switch state.stage {
            case .live(let attempt, _):
                switch await runLivePhase(state: &state) {
                case .continueWithUpdatedState:
                    continue
                case .terminal(let terminal):
                    sink.commitTerminal(terminal, for: runID)
                    await cleanupOnce(attempt.attempt, cleanedAttempts: &cleanedAttempts)
                    return
                case .confirmedOutage(let outage):
                    state.stage = .preparingRestart(
                        interruptedAttempt: attempt.attempt,
                        outage: outage
                    )
                    sink.setExecutionPhase(
                        .preparingRestart,
                        cancellationAuthority: .workerCleanup,
                        for: runID
                    )
                case .cancelled:
                    await finishParentCancellation(
                        activeAttempt: attempt.attempt,
                        preparedToken: nil,
                        cleanedAttempts: &cleanedAttempts
                    )
                    return
                case .failed(let failure):
                    sink.markWorkerFailure(failure, for: runID)
                    await cleanupOnce(attempt.attempt, cleanedAttempts: &cleanedAttempts)
                    return
                }

            case .preparingRestart(let interruptedAttempt, let outage):
                let decision = await prepareRestart(
                    interruptedAttempt,
                    generation: state.attemptGeneration,
                    outage: outage
                )
                switch decision {
                case .success(let token):
                    await cleanupOnce(interruptedAttempt, cleanedAttempts: &cleanedAttempts)
                    if Task.isCancelled || sink.workerSnapshot(for: runID)?.isTerminal == true
                        || sink.workerSnapshot(for: runID)?.pendingCancellation != nil
                    {
                        await finishParentCancellation(
                            activeAttempt: nil,
                            preparedToken: token,
                            cleanedAttempts: &cleanedAttempts
                        )
                        return
                    }
                    state.stage = .waitingForNetwork(
                        interruptedAttempt: interruptedAttempt,
                        outage: outage,
                        token: token,
                        connectivity: .unsatisfied(nextSettleGeneration: 1)
                    )
                    sink.setExecutionPhase(
                        .waitingForNetwork(since: outage.presentationDate),
                        cancellationAuthority: .workerCleanup,
                        for: runID
                    )
                case .failure(let failure):
                    await cleanupOnce(interruptedAttempt, cleanedAttempts: &cleanedAttempts)
                    sink.markWorkerFailure(failure, for: runID)
                    return
                case .cancelled:
                    await cleanupOnce(interruptedAttempt, cleanedAttempts: &cleanedAttempts)
                    if Task.isCancelled {
                        sink.commitWorkerCancellation(for: runID)
                    } else {
                        sink.markWorkerFailure(.prepareRestartCancelledUnexpectedly, for: runID)
                    }
                    return
                }

            case .waitingForNetwork(
                let interruptedAttempt,
                let outage,
                let token,
                _
            ):
                switch await waitForNetwork(state: &state) {
                case .continueWithUpdatedState:
                    continue
                case .readyToRestart:
                    state.stage = .restarting(
                        interruptedAttempt: interruptedAttempt,
                        outage: outage,
                        token: token
                    )
                    sink.setExecutionPhase(
                        .restarting,
                        cancellationAuthority: .workerCleanup,
                        for: runID
                    )
                case .cancelled:
                    await finishParentCancellation(
                        activeAttempt: nil,
                        preparedToken: token,
                        cleanedAttempts: &cleanedAttempts
                    )
                    return
                case .failed(let failure):
                    await discardPreparedToken(token, cleanedAttempts: &cleanedAttempts)
                    sink.markWorkerFailure(failure, for: runID)
                    return
                }

            case .restarting(_, let outage, let token):
                switch await restartReview(
                    token,
                    generation: state.attemptGeneration,
                    outage: outage
                ) {
                case .success(let replacement):
                    do {
                        try await claimRetention(replacement.attempt)
                    } catch let failure as ReviewBackendFailure {
                        sink.markWorkerFailure(failure, for: runID)
                        return
                    } catch {
                        sink.markWorkerFailure(
                            .protocolViolation(
                                message: "Replacement review retention failed with an unsupported error: \(error.localizedDescription)"
                            ),
                            for: runID
                        )
                        return
                    }
                    if Task.isCancelled || sink.workerSnapshot(for: runID)?.isTerminal == true
                        || sink.workerSnapshot(for: runID)?.pendingCancellation != nil
                    {
                        await interruptAndCleanup(
                            replacement.attempt,
                            cancellation: sink.workerSnapshot(for: runID)?.cancellation ?? .system()
                        )
                        sink.commitWorkerCancellation(for: runID)
                        return
                    }
                    state.attemptGeneration += 1
                    state.nextOutageEpoch = 1
                    guard sink.publishAttempt(
                        replacement.attempt,
                        runID: runID,
                        attemptGeneration: state.attemptGeneration
                    ) else {
                        await interruptAndCleanup(replacement.attempt, cancellation: .system())
                        return
                    }
                    state.stage = .live(attempt: replacement, network: .satisfied)
                case .failure(let failure):
                    await discardPreparedToken(token, cleanedAttempts: &cleanedAttempts)
                    sink.markWorkerFailure(failure, for: runID)
                    return
                case .cancelled:
                    await discardPreparedToken(token, cleanedAttempts: &cleanedAttempts)
                    if Task.isCancelled {
                        sink.commitWorkerCancellation(for: runID)
                    } else {
                        sink.markWorkerFailure(.restartCancelledUnexpectedly, for: runID)
                    }
                    return
                }
            }
        }
    }

    private func runLivePhase(
        state: inout ReviewWorkerState
    ) async -> ReviewLivePhaseDecision {
        guard case .live(let backendAttempt, let initialNetworkPhase) = state.stage else {
            preconditionFailure("A live phase requires a live worker stage.")
        }
        let generation = state.attemptGeneration
        let policy = networkRecoveryPolicy
        let networkSource = ReviewWorkerNetworkSource(monitor: networkMonitor)
        return await withTaskGroup(of: ReviewWorkerSignal.self) { group in
            group.addTask {
                await observeTerminal(backendAttempt, generation: generation)
            }
            addNetworkChild(
                to: &group,
                source: networkSource,
                clock: policy.clock,
                generation: generation
            )
            var networkPhase = initialNetworkPhase
            if case .pendingOutage(let outage, _) = networkPhase {
                addOutageTimer(
                    to: &group,
                    policy: policy,
                    generation: generation,
                    outageEpoch: outage.epoch
                )
            }

            while let signal = await group.next() {
                guard signal.generation == generation else {
                    if signal.generation < generation {
                        continue
                    }
                    let drain = await drainLiveGroup(&group, startingWith: signal, generation: generation)
                    return .failed(drain.terminalFailure ?? .protocolViolation(
                        message: "A future review generation emitted into the current live phase."
                    ))
                }

                if Task.isCancelled {
                    let drain = await drainLiveGroup(&group, startingWith: signal, generation: generation)
                    if let terminal = drain.terminal {
                        return .terminal(terminal)
                    }
                    return .cancelled
                }

                switch signal {
                case .backendTerminal(_, let terminal) where terminal.isConnectionTermination:
                    switch networkPhase {
                    case .satisfied:
                        let drain = await drainLiveGroup(&group, startingWith: signal, generation: generation)
                        return .terminal(drain.terminal ?? terminal)
                    case .pendingOutage(let outage, let held):
                        guard held == nil,
                              case .failed(.connectionTerminated(let termination)) = terminal else {
                            let drain = await drainLiveGroup(&group, startingWith: signal, generation: generation)
                            return .failed(drain.terminalFailure ?? .protocolViolation(
                                message: "A pending outage produced duplicate or malformed connection terminals."
                            ))
                        }
                        networkPhase = .pendingOutage(
                            outage,
                            heldConnectionTermination: termination
                        )
                        state.stage = .live(attempt: backendAttempt, network: networkPhase)
                        sink.setCancellationAuthority(.workerCleanup, for: runID)
                    }

                case .backendTerminal:
                    let drain = await drainLiveGroup(&group, startingWith: signal, generation: generation)
                    guard let terminal = drain.terminal else {
                        return .failed(.protocolViolation(
                            message: "A backend terminal signal was lost while draining the live phase."
                        ))
                    }
                    return .terminal(terminal)

                case .resultWaitCancelled:
                    let drain = await drainLiveGroup(&group, startingWith: signal, generation: generation)
                    if let terminal = drain.terminal {
                        return .terminal(terminal)
                    }
                    return .failed(.protocolViolation(
                        message: "Review terminal observation was cancelled without parent cancellation."
                    ))

                case .networkSnapshot(_, let snapshot):
                    switch (networkPhase, snapshot.connectivity) {
                    case (.satisfied, .satisfied):
                        addNetworkChild(
                            to: &group,
                            source: networkSource,
                            clock: policy.clock,
                            generation: generation
                        )
                    case (.satisfied, .outage):
                        let outage = ReviewWorkerState.Outage(
                            epoch: state.nextOutageEpoch,
                            observedAt: snapshot.observedAt,
                            presentationDate: snapshot.presentationDate
                        )
                        state.nextOutageEpoch += 1
                        networkPhase = .pendingOutage(outage, heldConnectionTermination: nil)
                        state.stage = .live(attempt: backendAttempt, network: networkPhase)
                        addOutageTimer(
                            to: &group,
                            policy: policy,
                            generation: generation,
                            outageEpoch: outage.epoch
                        )
                        addNetworkChild(
                            to: &group,
                            source: networkSource,
                            clock: policy.clock,
                            generation: generation
                        )
                    case (.pendingOutage, .outage):
                        addNetworkChild(
                            to: &group,
                            source: networkSource,
                            clock: policy.clock,
                            generation: generation
                        )
                    case (.pendingOutage(_, let held), .satisfied):
                        let drain = await drainLiveGroup(&group, startingWith: signal, generation: generation)
                        if let terminal = drain.nonConnectionTerminal {
                            return .terminal(terminal)
                        }
                        if let held {
                            return .terminal(.failed(.connectionTerminated(held)))
                        }
                        state.stage = .live(attempt: backendAttempt, network: .satisfied)
                        sink.setCancellationAuthority(.interrupt(backendAttempt.attempt), for: runID)
                        return .continueWithUpdatedState
                    }

                case .networkSourceFinished:
                    let drain = await drainLiveGroup(&group, startingWith: signal, generation: generation)
                    if let terminal = drain.nonConnectionTerminal {
                        return .terminal(terminal)
                    }
                    if case .pendingOutage(_, let held) = networkPhase, let held {
                        return .terminal(.failed(.connectionTerminated(held)))
                    }
                    return .failed(.connectivityObservationEnded)

                case .outageDebounceElapsed(_, let outageEpoch):
                    guard case .pendingOutage(let outage, _) = networkPhase else {
                        if outageEpoch < state.nextOutageEpoch {
                            continue
                        }
                        return .failed(.protocolViolation(
                            message: "A future outage timer fired outside a pending outage."
                        ))
                    }
                    guard outageEpoch == outage.epoch else {
                        if outageEpoch < outage.epoch {
                            continue
                        }
                        return .failed(.protocolViolation(
                            message: "A future outage timer fired for the current attempt."
                        ))
                    }
                    let drain = await drainLiveGroup(&group, startingWith: signal, generation: generation)
                    if let terminal = drain.nonConnectionTerminal {
                        return .terminal(terminal)
                    }
                    if Task.isCancelled {
                        return .cancelled
                    }
                    return .confirmedOutage(outage)

                case .outageDebounceCancelled(_, let outageEpoch):
                    guard case .pendingOutage(let outage, _) = networkPhase,
                          outageEpoch == outage.epoch else {
                        if outageEpoch < state.nextOutageEpoch {
                            continue
                        }
                        return .failed(.protocolViolation(
                            message: "An outage timer was cancelled for an impossible epoch."
                        ))
                    }
                    let drain = await drainLiveGroup(&group, startingWith: signal, generation: generation)
                    if let terminal = drain.terminal {
                        return .terminal(terminal)
                    }
                    return Task.isCancelled
                        ? .cancelled
                        : .failed(.protocolViolation(
                            message: "Network outage debounce was cancelled unexpectedly."
                        ))

                case .recoverySettleElapsed, .recoverySettleCancelled,
                     .prepareRestartCompleted, .prepareRestartCancelled,
                     .restartCompleted, .restartCancelled:
                    let drain = await drainLiveGroup(&group, startingWith: signal, generation: generation)
                    return .failed(drain.terminalFailure ?? .protocolViolation(
                        message: "A non-live signal was emitted into the live review phase."
                    ))
                }
            }

            return Task.isCancelled
                ? .cancelled
                : .failed(.protocolViolation(message: "The live review phase ended without a decision."))
        }
    }

    private func prepareRestart(
        _ attempt: ReviewAttempt,
        generation: UInt64,
        outage: ReviewWorkerState.Outage
    ) async -> ReviewPhaseOperationResult<CodexReviewBackendModel.Review.RestartToken> {
        let operation: @MainActor @Sendable () async throws
            -> CodexReviewBackendModel.Review.RestartToken = { [backend] in
                try await backend.prepareReviewRestart(attempt)
            }
        return await withTaskGroup(of: ReviewWorkerSignal.self) { group in
            group.addTask {
                do {
                    return .prepareRestartCompleted(
                        generation: generation,
                        outageEpoch: outage.epoch,
                        .success(try await operation())
                    )
                } catch is CancellationError {
                    return .prepareRestartCancelled(
                        generation: generation,
                        outageEpoch: outage.epoch
                    )
                } catch {
                    return .prepareRestartCompleted(
                        generation: generation,
                        outageEpoch: outage.epoch,
                        .failure(backendFailure(error, operation: "prepareReviewRestart"))
                    )
                }
            }
            guard let signal = await group.next() else {
                return .failure(.protocolViolation(
                    message: "Review restart preparation ended without a signal."
                ))
            }
            group.cancelAll()
            while await group.next() != nil {}
            guard signal.generation == generation else {
                return .failure(.protocolViolation(
                    message: "Review restart preparation returned a mismatched generation."
                ))
            }
            switch signal {
            case .prepareRestartCompleted(_, let epoch, let result) where epoch == outage.epoch:
                switch result {
                case .success(let token):
                    return .success(token)
                case .failure(let failure):
                    return .failure(failure)
                }
            case .prepareRestartCancelled(_, let epoch) where epoch == outage.epoch:
                return .cancelled
            default:
                return .failure(.protocolViolation(
                    message: "Review restart preparation returned an impossible signal."
                ))
            }
        }
    }

    private func waitForNetwork(
        state: inout ReviewWorkerState
    ) async -> ReviewNetworkPhaseDecision {
        guard case .waitingForNetwork(
            let interruptedAttempt,
            let outage,
            let token,
            let initialConnectivity
        ) = state.stage else {
            preconditionFailure("A network wait requires a waiting worker stage.")
        }
        let generation = state.attemptGeneration
        let policy = networkRecoveryPolicy
        let source = ReviewWorkerNetworkSource(monitor: networkMonitor)
        return await withTaskGroup(of: ReviewWorkerSignal.self) { group in
            addNetworkChild(
                to: &group,
                source: source,
                clock: policy.clock,
                generation: generation
            )
            var connectivity = initialConnectivity
            if case .settling(let settleGeneration) = connectivity {
                addSettleTimer(
                    to: &group,
                    policy: policy,
                    generation: generation,
                    outageEpoch: outage.epoch,
                    settleGeneration: settleGeneration
                )
            }
            while let signal = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    while await group.next() != nil {}
                    return .cancelled
                }
                guard signal.generation == generation else {
                    if signal.generation < generation {
                        continue
                    }
                    group.cancelAll()
                    while await group.next() != nil {}
                    return .failed(.protocolViolation(
                        message: "A future review generation emitted during network recovery."
                    ))
                }
                switch signal {
                case .networkSnapshot(_, let snapshot):
                    switch (connectivity, snapshot.connectivity) {
                    case (.unsatisfied, .outage):
                        addNetworkChild(
                            to: &group,
                            source: source,
                            clock: policy.clock,
                            generation: generation
                        )
                    case (.unsatisfied(let next), .satisfied):
                        connectivity = .settling(generation: next)
                        state.stage = .waitingForNetwork(
                            interruptedAttempt: interruptedAttempt,
                            outage: outage,
                            token: token,
                            connectivity: connectivity
                        )
                        addSettleTimer(
                            to: &group,
                            policy: policy,
                            generation: generation,
                            outageEpoch: outage.epoch,
                            settleGeneration: next
                        )
                        addNetworkChild(
                            to: &group,
                            source: source,
                            clock: policy.clock,
                            generation: generation
                        )
                    case (.settling, .satisfied):
                        addNetworkChild(
                            to: &group,
                            source: source,
                            clock: policy.clock,
                            generation: generation
                        )
                    case (.settling(let current), .outage):
                        group.cancelAll()
                        while await group.next() != nil {}
                        state.stage = .waitingForNetwork(
                            interruptedAttempt: interruptedAttempt,
                            outage: outage,
                            token: token,
                            connectivity: .unsatisfied(nextSettleGeneration: current + 1)
                        )
                        return .continueWithUpdatedState
                    }
                case .networkSourceFinished:
                    group.cancelAll()
                    while await group.next() != nil {}
                    return .failed(.connectivityObservationEnded)
                case .recoverySettleElapsed(_, let epoch, let settleGeneration):
                    guard epoch == outage.epoch,
                          case .settling(let current) = connectivity else {
                        if epoch < outage.epoch {
                            continue
                        }
                        return .failed(.protocolViolation(
                            message: "A network settle timer fired outside a settling window."
                        ))
                    }
                    guard settleGeneration == current else {
                        if settleGeneration < current {
                            continue
                        }
                        return .failed(.protocolViolation(
                            message: "A future network settle timer fired."
                        ))
                    }
                    group.cancelAll()
                    while await group.next() != nil {}
                    return Task.isCancelled ? .cancelled : .readyToRestart
                case .recoverySettleCancelled(_, let epoch, let settleGeneration):
                    if epoch < outage.epoch {
                        continue
                    }
                    if case .settling(let current) = connectivity, settleGeneration < current {
                        continue
                    }
                    group.cancelAll()
                    while await group.next() != nil {}
                    return Task.isCancelled
                        ? .cancelled
                        : .failed(.protocolViolation(
                            message: "Network recovery settling was cancelled unexpectedly."
                        ))
                case .backendTerminal, .resultWaitCancelled,
                     .outageDebounceElapsed, .outageDebounceCancelled,
                     .prepareRestartCompleted, .prepareRestartCancelled,
                     .restartCompleted, .restartCancelled:
                    group.cancelAll()
                    while await group.next() != nil {}
                    return .failed(.protocolViolation(
                        message: "A non-network signal was emitted during network recovery."
                    ))
                }
            }
            return Task.isCancelled
                ? .cancelled
                : .failed(.protocolViolation(message: "Network recovery ended without a decision."))
        }
    }

    private func restartReview(
        _ token: CodexReviewBackendModel.Review.RestartToken,
        generation: UInt64,
        outage: ReviewWorkerState.Outage
    ) async -> ReviewPhaseOperationResult<BackendReviewAttempt> {
        let operation: @MainActor @Sendable () async throws -> BackendReviewAttempt = {
            [backend, startRequest] in
            try await backend.restartPreparedReview(token, request: startRequest)
        }
        return await withTaskGroup(of: ReviewWorkerSignal.self) { group in
            group.addTask {
                do {
                    return .restartCompleted(
                        generation: generation,
                        outageEpoch: outage.epoch,
                        .success(try await operation())
                    )
                } catch is CancellationError {
                    return .restartCancelled(
                        generation: generation,
                        outageEpoch: outage.epoch
                    )
                } catch {
                    return .restartCompleted(
                        generation: generation,
                        outageEpoch: outage.epoch,
                        .failure(backendFailure(error, operation: "restartPreparedReview"))
                    )
                }
            }
            guard let signal = await group.next() else {
                return .failure(.protocolViolation(message: "Review restart ended without a signal."))
            }
            group.cancelAll()
            while await group.next() != nil {}
            guard signal.generation == generation else {
                return .failure(.protocolViolation(
                    message: "Review restart returned a mismatched generation."
                ))
            }
            switch signal {
            case .restartCompleted(_, let epoch, let result) where epoch == outage.epoch:
                switch result {
                case .success(let attempt):
                    return .success(attempt)
                case .failure(let failure):
                    return .failure(failure)
                }
            case .restartCancelled(_, let epoch) where epoch == outage.epoch:
                return .cancelled
            default:
                return .failure(.protocolViolation(
                    message: "Review restart returned an impossible signal."
                ))
            }
        }
    }

    private func finishParentCancellation(
        activeAttempt: ReviewAttempt?,
        preparedToken: CodexReviewBackendModel.Review.RestartToken?,
        cleanedAttempts: inout Set<ReviewAttemptID>
    ) async {
        if let preparedToken {
            await discardPreparedToken(preparedToken, cleanedAttempts: &cleanedAttempts)
        }
        let snapshot = sink.workerSnapshot(for: runID)
        if snapshot?.isTerminal == false, snapshot?.pendingCancellation == nil,
           let activeAttempt
        {
            _ = await interruptForCleanup(activeAttempt, cancellation: .system())
        }
        if let activeAttempt {
            await cleanupOnce(activeAttempt, cleanedAttempts: &cleanedAttempts)
        }
        sink.commitWorkerCancellation(for: runID)
    }

    private func discardPreparedToken(
        _ token: CodexReviewBackendModel.Review.RestartToken,
        cleanedAttempts: inout Set<ReviewAttemptID>
    ) async {
        let lateAttempts = await backend.discardPreparedReviewRestart(token)
        for attempt in lateAttempts {
            do {
                try await claimRetention(attempt)
            } catch {
                // claimRetention owns rollback cleanup before it throws.
                continue
            }
            guard cleanedAttempts.contains(attempt.attemptID) == false else {
                continue
            }
            _ = await interruptForCleanup(
                attempt,
                cancellation: sink.workerSnapshot(for: runID)?.cancellation ?? .system()
            )
            await cleanupOnce(attempt, cleanedAttempts: &cleanedAttempts)
        }
    }

    private func claimRetention(_ attempt: ReviewAttempt) async throws {
        do {
            try await retentionRegistry.claim(
                attempt,
                for: runID,
                scope: retentionScope
            )
        } catch {
            let journalFailure = (error as? ReviewThreadRetentionRegistryError)?.message
                ?? error.localizedDescription
            _ = await interruptForCleanup(
                attempt,
                cancellation: .system(message: "Review retention journal commit failed.")
            )
            await backend.cleanupReview(attempt)
            let pending = await retentionRegistry.pendingEntry(for: runID)
            let cleanup = await backend.cleanupRetainedReviews(
                pending?.attempts ?? [attempt],
                additionalThreadIDs: pending?.additionalCleanupThreadIDs ?? []
            )
            await retentionRegistry.recordFailedClaimCleanup(
                runID: runID,
                journalFailure: journalFailure,
                failedThreadIDs: cleanup.failures.map(\.threadID),
                cleanupFailure: cleanup.failureMessage
            )
            throw ReviewBackendFailure.retentionJournal(
                message: "Review identity could not be committed to the retention journal: \(journalFailure)"
            )
        }
    }

    private func rollbackUnpublishedAttempt(
        _ attempt: ReviewAttempt,
        cancellation: ReviewCancellation,
        claimOwnership: Bool
    ) async {
        if claimOwnership {
            do {
                try await claimRetention(attempt)
            } catch {
                // claimRetention owns the quarantine rollback when ownership
                // cannot be committed.
                return
            }
        }

        _ = await interruptForCleanup(attempt, cancellation: cancellation)
        await backend.cleanupReview(attempt)
        let cleanup = await backend.cleanupRetainedReviews(
            [attempt],
            additionalThreadIDs: []
        )
        if cleanup.succeeded {
            await retentionRegistry.recordCleanupSucceeded(for: runID)
        } else {
            _ = await retentionRegistry.recordCleanupFailed(
                for: runID,
                failedThreadIDs: cleanup.failures.map(\.threadID),
                message: cleanup.failureMessage ?? "Unpublished review thread cleanup failed."
            )
        }
    }

    private func interruptAndCleanup(
        _ attempt: ReviewAttempt,
        cancellation: ReviewCancellation
    ) async {
        _ = await interruptForCleanup(attempt, cancellation: cancellation)
        await backend.cleanupReview(attempt)
    }

    private func interruptForCleanup(
        _ attempt: ReviewAttempt,
        cancellation: ReviewCancellation
    ) async -> ReviewBackendFailure? {
        do {
            try await backend.interruptReview(
                attempt,
                reason: .init(message: cancellation.message)
            )
            return nil
        } catch {
            return backendFailure(error, operation: "interruptReview")
        }
    }

    private func cleanupOnce(
        _ attempt: ReviewAttempt,
        cleanedAttempts: inout Set<ReviewAttemptID>
    ) async {
        guard cleanedAttempts.insert(attempt.attemptID).inserted else {
            preconditionFailure("A started review attempt can only be cleaned once by its worker.")
        }
        await backend.cleanupReview(attempt)
    }
}

private enum ReviewLivePhaseDecision: Sendable {
    case continueWithUpdatedState
    case terminal(ReviewBackendTerminal)
    case confirmedOutage(ReviewWorkerState.Outage)
    case cancelled
    case failed(ReviewBackendFailure)
}

private enum ReviewNetworkPhaseDecision: Sendable {
    case continueWithUpdatedState
    case readyToRestart
    case cancelled
    case failed(ReviewBackendFailure)
}

private enum ReviewPhaseOperationResult<Value: Sendable>: Sendable {
    case success(Value)
    case failure(ReviewBackendFailure)
    case cancelled
}

private struct ReviewLivePhaseDrain: Sendable {
    var terminal: ReviewBackendTerminal?
    var duplicateTerminal = false

    var nonConnectionTerminal: ReviewBackendTerminal? {
        guard terminal?.isConnectionTermination == false else {
            return nil
        }
        return terminal
    }

    var terminalFailure: ReviewBackendFailure? {
        if duplicateTerminal {
            return .protocolViolation(
                message: "A review phase produced more than one backend terminal."
            )
        }
        if case .failed(let failure) = terminal {
            return failure
        }
        return nil
    }

    mutating func record(_ signal: ReviewWorkerSignal, generation: UInt64) {
        guard signal.generation == generation else {
            return
        }
        guard case .backendTerminal(_, let candidate) = signal else {
            return
        }
        if terminal == nil {
            terminal = candidate
        } else {
            duplicateTerminal = true
        }
    }
}

private actor ReviewWorkerNetworkSource {
    private final class IteratorState {
        var iterator: AsyncStream<CodexReviewNetworkSnapshot>.Iterator

        init(_ stream: AsyncStream<CodexReviewNetworkSnapshot>) {
            iterator = stream.makeAsyncIterator()
        }
    }

    private let state: IteratorState

    init(monitor: any CodexReviewNetworkMonitoring) {
        state = IteratorState(monitor.snapshots())
    }

    func next() async -> CodexReviewNetworkSnapshot? {
        var iterator = state.iterator
        let next = await iterator.next(isolation: self)
        state.iterator = iterator
        return next
    }
}

private func observeTerminal(
    _ backendAttempt: BackendReviewAttempt,
    generation: UInt64
) async -> ReviewWorkerSignal {
    do {
        let observed = try await backendAttempt.observeTerminal()
        return .backendTerminal(
            generation: generation,
            await backendAttempt.finalizeTerminal(observed)
        )
    } catch is CancellationError {
        guard let observed = await backendAttempt.observedTerminalIfKnown() else {
            return .resultWaitCancelled(generation: generation)
        }
        return .backendTerminal(
            generation: generation,
            await backendAttempt.finalizeTerminal(observed)
        )
    } catch {
        return .backendTerminal(
            generation: generation,
            .failed(.protocolViolation(
                message: "Review terminal observation threw an unsupported error: \(error.localizedDescription)"
            ))
        )
    }
}

private func addNetworkChild(
    to group: inout TaskGroup<ReviewWorkerSignal>,
    source: ReviewWorkerNetworkSource,
    clock: ReviewWorkerClock,
    generation: UInt64
) {
    group.addTask {
        guard let snapshot = await source.next() else {
            return .networkSourceFinished(generation: generation)
        }
        return .networkSnapshot(
            generation: generation,
            ReviewWorkerConnectivitySnapshot(snapshot, clock: clock)
        )
    }
}

private func addOutageTimer(
    to group: inout TaskGroup<ReviewWorkerSignal>,
    policy: CodexReviewNetworkRecoveryPolicy,
    generation: UInt64,
    outageEpoch: UInt64
) {
    group.addTask {
        do {
            try await policy.clock.sleep(for: policy.outageDebounce)
            return .outageDebounceElapsed(
                generation: generation,
                outageEpoch: outageEpoch
            )
        } catch {
            return .outageDebounceCancelled(
                generation: generation,
                outageEpoch: outageEpoch
            )
        }
    }
}

private func addSettleTimer(
    to group: inout TaskGroup<ReviewWorkerSignal>,
    policy: CodexReviewNetworkRecoveryPolicy,
    generation: UInt64,
    outageEpoch: UInt64,
    settleGeneration: UInt64
) {
    group.addTask {
        do {
            try await policy.clock.sleep(for: policy.recoverySettle)
            return .recoverySettleElapsed(
                generation: generation,
                outageEpoch: outageEpoch,
                settleGeneration: settleGeneration
            )
        } catch {
            return .recoverySettleCancelled(
                generation: generation,
                outageEpoch: outageEpoch,
                settleGeneration: settleGeneration
            )
        }
    }
}

@MainActor
private func drainLiveGroup(
    _ group: inout TaskGroup<ReviewWorkerSignal>,
    startingWith signal: ReviewWorkerSignal,
    generation: UInt64
) async -> ReviewLivePhaseDrain {
    var drain = ReviewLivePhaseDrain()
    drain.record(signal, generation: generation)
    group.cancelAll()
    while let signal = await group.next() {
        drain.record(signal, generation: generation)
    }
    return drain
}

private func backendFailure(_ error: any Error, operation: String) -> ReviewBackendFailure {
    if let failure = error as? ReviewBackendFailure {
        return failure
    }
    return .protocolViolation(
        message: "Review backend \(operation) threw an unsupported error: \(error.localizedDescription)"
    )
}
