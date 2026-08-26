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
        case interruptAcceptedAwaitingTerminalNotification
        case finished
    }

    private struct InterruptReservation: Equatable {
        var phase: Phase
        var generation: Int
    }

    private enum RetryAuthorization {
        case exactReservation(InterruptReservation)
        case currentActiveTurn(InterruptReservation)
        case incompatibleReplacement
        case superseded

        var reservation: InterruptReservation? {
            switch self {
            case .exactReservation(let reservation), .currentActiveTurn(let reservation):
                reservation
            case .incompatibleReplacement, .superseded:
                nil
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
        recordActivePhaseIfOpen(.reviewStarted(
            turnThreadID: turnThreadID,
            turnID: turnID
        ))
    }

    package func recordTurnStarted(turnThreadID: String, turnID: String) {
        recordActivePhaseIfOpen(.reviewStarted(
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
        case .interruptAcceptedAwaitingTerminalNotification, .finished:
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
            recordInterruptAccepted(ifOwnedBy: reservation)
            return .sent(.init(threadID: threadID, turnID: turnID))
        } catch {
            guard let activeTurnID = Self.activeTurnID(from: error),
                  activeTurnID != turnID
            else {
                throw error
            }
            guard let retryReservation = authorizeRetry(
                for: reservation,
                threadID: threadID,
                activeTurnID: activeTurnID
            ).reservation else {
                return .superseded
            }
            let activeInterruption = AppServerReviewInterruption(threadID: threadID, turnID: activeTurnID)
            let _: EmptyResponse = try await client.send(AppServerAPI.Turn.Interrupt.Request(
                params: .init(threadID: threadID, turnID: activeTurnID)
            ))
            // Do not rebind to activeTurnID: non-startup interrupt responses are sent
            // only after that turn is terminal, before its terminal notification.
            recordInterruptAccepted(ifOwnedBy: retryReservation)
            return .sent(activeInterruption)
        }
    }

    private func recordActivePhaseIfOpen(_ phase: Phase) {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        switch self.phase {
        case .interruptAcceptedAwaitingTerminalNotification, .finished:
            return
        case .preparing, .threadStarted, .reviewStarted:
            break
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
        switch phase {
        case .interruptAcceptedAwaitingTerminalNotification, .finished:
            return .superseded
        case .preparing, .threadStarted, .reviewStarted:
            break
        }
        let currentReservation = InterruptReservation(
            phase: phase,
            generation: phaseGeneration
        )
        if phase == reservation.phase,
           phaseGeneration == reservation.generation {
            return .exactReservation(currentReservation)
        }
        if phase == .reviewStarted(
            turnThreadID: threadID,
            turnID: activeTurnID
        ) {
            return .currentActiveTurn(currentReservation)
        }
        return .incompatibleReplacement
    }

    private func recordInterruptAccepted(
        ifOwnedBy reservation: InterruptReservation
    ) {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        guard phase == reservation.phase,
              phaseGeneration == reservation.generation
        else {
            return
        }
        phase = .interruptAcceptedAwaitingTerminalNotification
        phaseGeneration += 1
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
