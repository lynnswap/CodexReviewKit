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

    private struct InterruptDispatch {
        var interruption: AppServerReviewInterruption
        var reservation: InterruptReservation
    }

    private enum InterruptDispatchDecision {
        case send(InterruptDispatch)
        case fallbackRequired
        case superseded
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
        var decision = nextInterruptDispatch()
        while true {
            switch decision {
            case .fallbackRequired:
                return .fallbackRequired
            case .superseded:
                return .superseded
            case .send(let dispatch):
                do {
                    let _: EmptyResponse = try await client.send(
                        AppServerAPI.Turn.Interrupt.Request(params: .init(
                            threadID: dispatch.interruption.threadID,
                            turnID: dispatch.interruption.turnID
                        ))
                    )
                    if recordInterruptAccepted(ifOwnedBy: dispatch.reservation) {
                        return .sent(dispatch.interruption)
                    }
                    decision = nextInterruptDispatch()
                } catch {
                    guard let activeTurnID = Self.activeTurnID(from: error),
                          activeTurnID != dispatch.interruption.turnID
                    else {
                        throw error
                    }
                    decision = nextInterruptDispatch(
                        after: dispatch,
                        reportedActiveTurnID: activeTurnID
                    )
                }
            }
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

    private func nextInterruptDispatch() -> InterruptDispatchDecision {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        return dispatchDecision(for: .init(
            phase: phase,
            generation: phaseGeneration
        ))
    }

    private func nextInterruptDispatch(
        after dispatch: InterruptDispatch,
        reportedActiveTurnID: String
    ) -> InterruptDispatchDecision {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        let currentReservation = InterruptReservation(
            phase: phase,
            generation: phaseGeneration
        )
        switch phase {
        case .interruptAcceptedAwaitingTerminalNotification, .finished:
            return .superseded
        case .preparing, .threadStarted, .reviewStarted:
            break
        }
        if currentReservation == dispatch.reservation
            || phase == .reviewStarted(
                turnThreadID: dispatch.interruption.threadID,
                turnID: reportedActiveTurnID
            ) {
            return .send(.init(
                interruption: .init(
                    threadID: dispatch.interruption.threadID,
                    turnID: reportedActiveTurnID
                ),
                reservation: currentReservation
            ))
        }
        return dispatchDecision(for: currentReservation)
    }

    private func dispatchDecision(
        for reservation: InterruptReservation
    ) -> InterruptDispatchDecision {
        switch reservation.phase {
        case .preparing:
            return .fallbackRequired
        case .interruptAcceptedAwaitingTerminalNotification, .finished:
            return .superseded
        case .threadStarted(let threadID):
            return .send(.init(
                interruption: .init(threadID: threadID, turnID: ""),
                reservation: reservation
            ))
        case .reviewStarted(let turnThreadID, let turnID):
            return .send(.init(
                interruption: .init(threadID: turnThreadID, turnID: turnID),
                reservation: reservation
            ))
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

    @discardableResult
    private func recordInterruptAccepted(
        ifOwnedBy reservation: InterruptReservation
    ) -> Bool {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        guard phase == reservation.phase,
              phaseGeneration == reservation.generation
        else {
            return false
        }
        phase = .interruptAcceptedAwaitingTerminalNotification
        phaseGeneration += 1
        return true
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
