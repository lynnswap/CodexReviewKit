struct ReviewRecoveryLoopState {
    private enum ReplacementDelay {
        case idle
        case notRequired
        case waiting
        case elapsed

        var isReady: Bool {
            switch self {
            case .notRequired, .elapsed:
                true
            case .idle, .waiting:
                false
            }
        }
    }

    private enum NetworkReadiness {
        case ready
        case unavailable
        case settling(generation: Int)
    }

    private var replacementDelay = ReplacementDelay.idle
    private var networkReadiness = NetworkReadiness.ready
    private var pendingOutageStreamFailure: ReviewAttemptStreamFailure?

    var isReadyToStageRecovery: Bool {
        guard replacementDelay.isReady else {
            return false
        }
        if case .ready = networkReadiness {
            return true
        }
        return false
    }

    mutating func beginNetworkRecovery() -> Bool {
        let hadPendingTerminal = pendingOutageStreamFailure != nil
        replacementDelay = .notRequired
        networkReadiness = .unavailable
        pendingOutageStreamFailure = nil
        return hadPendingTerminal
    }

    mutating func beginModelCapacityRecovery(
        networkStatus: CodexReviewNetworkStatus
    ) {
        replacementDelay = .waiting
        networkReadiness = networkStatus == .satisfied ? .ready : .unavailable
        pendingOutageStreamFailure = nil
    }

    mutating func attachModelCapacityBackoff() -> Bool {
        guard case .notRequired = replacementDelay else {
            return false
        }
        replacementDelay = .waiting
        return true
    }

    mutating func markModelCapacityBackoffElapsed() -> Bool {
        guard case .waiting = replacementDelay else {
            return false
        }
        replacementDelay = .elapsed
        return true
    }

    mutating func markRecovered() {
        replacementDelay = .idle
        networkReadiness = .ready
        pendingOutageStreamFailure = nil
    }

    mutating func recordPendingOutageStreamFailure(_ failure: ReviewAttemptStreamFailure) {
        pendingOutageStreamFailure = failure
    }

    mutating func takePendingOutageStreamFailureAfterTransientRecovery(
        _ snapshot: CodexReviewNetworkSnapshot
    ) -> ReviewAttemptStreamFailure? {
        guard snapshot.status == .satisfied else { return nil }
        defer { pendingOutageStreamFailure = nil }
        return pendingOutageStreamFailure
    }

    mutating func markNetworkRecoverySettled(
        recoveryGeneration: Int
    ) -> Bool {
        guard case .settling(let currentGeneration) = networkReadiness,
              currentGeneration == recoveryGeneration else {
            return false
        }
        networkReadiness = .ready
        return true
    }

    mutating func networkSnapshotEffect(
        _ snapshot: CodexReviewNetworkSnapshot,
        recoveryGeneration: Int
    ) -> ReviewNetworkSnapshotEffect {
        guard snapshot.status == .satisfied else {
            networkReadiness = .unavailable
            return .none
        }

        switch networkReadiness {
        case .ready:
            return .none
        case .unavailable:
            networkReadiness = .settling(generation: recoveryGeneration)
            return .restartSettling
        case .settling:
            networkReadiness = .settling(generation: recoveryGeneration)
            return .none
        }
    }
}

enum ReviewNetworkSnapshotEffect: Equatable {
    case none
    case restartSettling
}
