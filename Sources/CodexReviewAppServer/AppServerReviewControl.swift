import Foundation
import CodexAppServerKit
import CodexReviewKit

package struct AppServerReviewInterruption: Equatable, Sendable {
    package var threadID: String
    package var turnID: String

    package init(threadID: String, turnID: String) {
        self.threadID = threadID
        self.turnID = turnID
    }
}

package final class AppServerReviewControl: @unchecked Sendable {
    private enum Phase: Equatable {
        case preparing
        case threadStarted(threadID: String)
        case reviewStarted(turnThreadID: String, turnID: String)
        case finished
    }

    private let client: AppServerClient
    private let phaseLock = NSLock()
    private var phase: Phase = .preparing

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
    }

    package func recordReviewStarted(turnThreadID: String, turnID: String) {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        phase = .reviewStarted(turnThreadID: turnThreadID, turnID: turnID)
    }

    package func recordTurnStarted(turnThreadID: String, turnID: String) {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        phase = .reviewStarted(turnThreadID: turnThreadID, turnID: turnID)
    }

    @discardableResult
    package func interrupt(
        willInterruptActiveTurn: (@Sendable (AppServerReviewInterruption) async -> Void)? = nil
    ) async throws -> AppServerReviewInterruption? {
        let currentPhase = phaseSnapshot()
        switch currentPhase {
        case .preparing, .finished:
            return nil
        case .threadStarted(let threadID):
            return try await sendInterrupt(
                threadID: threadID,
                turnID: "",
                willInterruptActiveTurn: willInterruptActiveTurn
            )
        case .reviewStarted(let turnThreadID, let turnID):
            return try await sendInterrupt(
                threadID: turnThreadID,
                turnID: turnID,
                willInterruptActiveTurn: willInterruptActiveTurn
            )
        }
    }

    package func finish() {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        phase = .finished
    }

    private func phaseSnapshot() -> Phase {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        return phase
    }

    private func sendInterrupt(
        threadID: String,
        turnID: String,
        willInterruptActiveTurn: (@Sendable (AppServerReviewInterruption) async -> Void)?
    ) async throws -> AppServerReviewInterruption {
        let interruption = try await interruptCodexTurn(
            threadID: .init(rawValue: threadID),
            turnID: turnID.nilIfEmpty.map(CodexTurnID.init(rawValue:)),
            client: client,
            willInterruptActiveTurn: { interruption in
                guard let willInterruptActiveTurn else {
                    return
                }
                await willInterruptActiveTurn(AppServerReviewInterruption(
                    threadID: interruption.threadID.rawValue,
                    turnID: interruption.turnID?.rawValue ?? ""
                ))
            }
        )
        let reviewInterruption = AppServerReviewInterruption(
            threadID: interruption.threadID.rawValue,
            turnID: interruption.turnID?.rawValue ?? ""
        )
        if reviewInterruption.turnID != turnID {
            setPhase(.reviewStarted(turnThreadID: threadID, turnID: reviewInterruption.turnID))
        }
        return reviewInterruption
    }

    private func setPhase(_ phase: Phase) {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        self.phase = phase
    }
}
