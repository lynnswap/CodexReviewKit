import Foundation

package struct ReviewAttemptContractFailure: LocalizedError, Equatable, Sendable {
    package var message: String

    package init(message: String) {
        self.message = message
    }

    package var errorDescription: String? { message }
}

package enum ReviewAttemptRecoveryTrigger: Equatable, Sendable {
    case sameAccountRestart
    case recoverableNetworkLoss

    package var cancellation: ReviewCancellation {
        switch self {
        case .sameAccountRestart:
            .system(message: "Review runtime is restarting.")
        case .recoverableNetworkLoss:
            .system(message: "Network unavailable; waiting to reconnect.")
        }
    }
}

/// Exhaustively classifies why an admitted review event stream ended before its
/// canonical terminal. Recovery policy is derived from this value once, at the
/// attempt admission boundary.
package enum ReviewAttemptStreamFailure: LocalizedError, Equatable, Sendable {
    case recoverableNetwork(ReviewRuntimeCloseFailure)
    case ownerForcedConnectionClose(ReviewRuntimeCloseFailure)
    case unexpectedConnection(ReviewRuntimeCloseFailure)
    case process(ReviewRuntimeCloseFailure)
    case protocolViolation(ReviewAttemptContractFailure)
    case workerContract(ReviewAttemptContractFailure)
    case ownerCancellation

    package var errorDescription: String? {
        switch self {
        case .recoverableNetwork(let failure),
             .ownerForcedConnectionClose(let failure),
             .unexpectedConnection(let failure),
             .process(let failure):
            failure.localizedDescription
        case .protocolViolation(let failure), .workerContract(let failure):
            failure.localizedDescription
        case .ownerCancellation:
            "Review event owner was cancelled before an attempt terminal."
        }
    }

    package var permitsRecoveryReplacement: Bool {
        switch self {
        case .recoverableNetwork, .ownerForcedConnectionClose:
            true
        case .unexpectedConnection, .process, .protocolViolation,
             .workerContract, .ownerCancellation:
            false
        }
    }
}

package enum ReviewAttemptBarrierTerminal: Equatable, Sendable {
    case canonical(ReviewTerminalRecord)
    case stream(ReviewAttemptStreamFailure)

    package var diagnosticDescription: String {
        switch self {
        case .canonical(let terminal):
            "canonical terminal \(terminal.kind.rawValue)"
        case .stream(let failure):
            failure.localizedDescription
        }
    }
}

package struct ReviewResolvedAttemptTerminal: Equatable, Sendable {
    package let run: CodexReviewBackendModel.Review.Run
    package let terminal: ReviewAttemptBarrierTerminal
    package let requestFailure: ReviewInterruptRequestFailure?

    init(
        run: CodexReviewBackendModel.Review.Run,
        terminal: ReviewAttemptBarrierTerminal,
        requestFailure: ReviewInterruptRequestFailure?
    ) {
        self.run = run
        self.terminal = terminal
        self.requestFailure = requestFailure
    }
}

package struct ReviewRecoveryCandidate: Equatable, Sendable {
    package let resolved: ReviewResolvedAttemptTerminal
    package let trigger: ReviewAttemptRecoveryTrigger

    init(
        resolved: ReviewResolvedAttemptTerminal,
        trigger: ReviewAttemptRecoveryTrigger
    ) {
        self.resolved = resolved
        self.trigger = trigger
    }
}

package struct ReviewProductTerminalDisposition: Equatable, Sendable {
    package let resolved: ReviewResolvedAttemptTerminal
    package let productTerminal: ReviewTerminalRecord

    init(
        resolved: ReviewResolvedAttemptTerminal,
        productTerminal: ReviewTerminalRecord
    ) {
        self.resolved = resolved
        self.productTerminal = productTerminal
    }
}

package enum ReviewRecoveryDisposition: Equatable, Sendable {
    case productTerminal(ReviewProductTerminalDisposition)
    case replacement(ReviewRecoveryCandidate)

    package var resolved: ReviewResolvedAttemptTerminal {
        switch self {
        case .productTerminal(let disposition):
            disposition.resolved
        case .replacement(let candidate):
            candidate.resolved
        }
    }
}

package struct ReviewRecoveryHandoffAlreadyConsumed: LocalizedError, Equatable, Sendable {
    package init() {}

    package var errorDescription: String? {
        "Review recovery handoff was already consumed."
    }
}

/// Copies share one consumption owner, so a rollback token can leave this
/// handoff exactly once even when concurrent callers retain the value.
package struct ReviewRecoveryHandoff: Equatable, Sendable {
    package struct Consumption: Equatable, Sendable {
        package let candidate: ReviewRecoveryCandidate
        package let token: CodexReviewBackendModel.Review.RecoveryToken

        fileprivate init(
            candidate: ReviewRecoveryCandidate,
            token: CodexReviewBackendModel.Review.RecoveryToken
        ) {
            self.candidate = candidate
            self.token = token
        }
    }

    package let candidate: ReviewRecoveryCandidate
    private let consumptionOwner: ReviewRecoveryHandoffConsumptionOwner

    package init(
        candidate: ReviewRecoveryCandidate,
        token: CodexReviewBackendModel.Review.RecoveryToken
    ) throws {
        guard candidate.resolved.run == token.interruptedRun else {
            throw ReviewAttemptContractFailure(
                message: "Review recovery token does not belong to the resolved attempt."
            )
        }
        self.candidate = candidate
        consumptionOwner = .init(token: token)
    }

    package func consume() async throws -> Consumption {
        .init(
            candidate: candidate,
            token: try await consumptionOwner.consume()
        )
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.consumptionOwner === rhs.consumptionOwner
    }
}

private actor ReviewRecoveryHandoffConsumptionOwner {
    private var token: CodexReviewBackendModel.Review.RecoveryToken?

    init(token: CodexReviewBackendModel.Review.RecoveryToken) {
        self.token = token
    }

    func consume() throws -> CodexReviewBackendModel.Review.RecoveryToken {
        guard let token else {
            throw ReviewRecoveryHandoffAlreadyConsumed()
        }
        self.token = nil
        return token
    }
}
