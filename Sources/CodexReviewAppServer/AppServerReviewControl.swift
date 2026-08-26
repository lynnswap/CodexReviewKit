import Foundation
import CodexReview

package struct AppServerReviewInterruption: Equatable, Sendable {
    package var threadID: String
    package var turnID: String

    package init(threadID: String, turnID: String) {
        self.threadID = threadID
        self.turnID = turnID
    }
}

package final class AppServerReviewControl: @unchecked Sendable {
    package enum InterruptOutcome: Equatable, Sendable {
        case sent(AppServerReviewInterruption)
        case fallbackRequired
        case superseded

        package var interruption: AppServerReviewInterruption? {
            if case .sent(let interruption) = self {
                return interruption
            }
            return nil
        }
    }

    private enum Phase: Equatable {
        case preparing
        case threadStarted(threadID: String)
        case reviewStarted(turnThreadID: String, turnID: String)
        case finished
    }

    private struct InterruptReservation: Equatable {
        var phase: Phase
        var generation: Int
    }

    private enum RetryAuthorization {
        case exactReservation
        case currentActiveTurn
        case incompatibleReplacement
        case finished

        var allowsRetry: Bool {
            switch self {
            case .exactReservation, .currentActiveTurn:
                true
            case .incompatibleReplacement, .finished:
                false
            }
        }
    }

    private let client: AppServerClient
    private let phaseLock = NSLock()
    private var phase: Phase = .preparing
    private var phaseGeneration = 0

    package init(client: AppServerClient) {
        self.client = client
    }

    package func recordThreadStarted(threadID: String) {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        guard phase == .preparing else {
            return
        }
        phase = .threadStarted(threadID: threadID)
        phaseGeneration += 1
    }

    package func recordReviewStarted(turnThreadID: String, turnID: String) {
        setPhaseUnlessFinished(.reviewStarted(
            turnThreadID: turnThreadID,
            turnID: turnID
        ))
    }

    package func recordTurnStarted(turnThreadID: String, turnID: String) {
        setPhaseUnlessFinished(.reviewStarted(
            turnThreadID: turnThreadID,
            turnID: turnID
        ))
    }

    @discardableResult
    package func interrupt() async throws -> AppServerReviewInterruption? {
        try await interruptOutcome().interruption
    }

    package func interruptOutcome() async throws -> InterruptOutcome {
        let reservation = interruptReservation()
        switch reservation.phase {
        case .preparing:
            return .fallbackRequired
        case .finished:
            return .superseded
        case .threadStarted(let threadID):
            return try await sendInterrupt(
                threadID: threadID,
                turnID: "",
                reservation: reservation
            )
        case .reviewStarted(let turnThreadID, let turnID):
            return try await sendInterrupt(
                threadID: turnThreadID,
                turnID: turnID,
                reservation: reservation
            )
        }
    }

    package func finish() {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        guard phase != .finished else {
            return
        }
        phase = .finished
        phaseGeneration += 1
    }

    private func interruptReservation() -> InterruptReservation {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        return .init(phase: phase, generation: phaseGeneration)
    }

    private func sendInterrupt(
        threadID: String,
        turnID: String,
        reservation: InterruptReservation
    ) async throws -> InterruptOutcome {
        do {
            let _: EmptyResponse = try await client.send(AppServerAPI.Turn.Interrupt.Request(
                params: .init(threadID: threadID, turnID: turnID)
            ))
            return .sent(.init(threadID: threadID, turnID: turnID))
        } catch {
            guard let activeTurnID = Self.activeTurnID(from: error),
                  activeTurnID != turnID
            else {
                throw error
            }
            guard authorizeRetry(
                for: reservation,
                threadID: threadID,
                activeTurnID: activeTurnID
            ).allowsRetry else {
                return .superseded
            }
            let activeInterruption = AppServerReviewInterruption(threadID: threadID, turnID: activeTurnID)
            let _: EmptyResponse = try await client.send(AppServerAPI.Turn.Interrupt.Request(
                params: .init(threadID: threadID, turnID: activeTurnID)
            ))
            // Do not rebind phase: non-startup interrupt responses follow TurnAborted,
            // so activeTurnID identifies the terminal turn, not the current phase.
            return .sent(activeInterruption)
        }
    }

    private func setPhaseUnlessFinished(_ phase: Phase) {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        guard self.phase != .finished else {
            return
        }
        guard self.phase != phase else {
            return
        }
        self.phase = phase
        phaseGeneration += 1
    }

    private func authorizeRetry(
        for reservation: InterruptReservation,
        threadID: String,
        activeTurnID: String
    ) -> RetryAuthorization {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        if phase == .finished {
            return .finished
        }
        if phase == reservation.phase,
           phaseGeneration == reservation.generation {
            return .exactReservation
        }
        if phase == .reviewStarted(
            turnThreadID: threadID,
            turnID: activeTurnID
        ) {
            return .currentActiveTurn
        }
        return .incompatibleReplacement
    }

    private static func activeTurnID(from error: Error) -> String? {
        guard case JSONRPC.Error.responseError(_, let message) = error,
              let range = message.range(of: " but found ")
        else {
            return nil
        }
        return String(message[range.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "` ").union(.whitespacesAndNewlines))
            .nilIfEmpty
    }
}
