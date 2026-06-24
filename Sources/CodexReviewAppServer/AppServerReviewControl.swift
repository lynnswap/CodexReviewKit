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

    private struct Snapshot {
        var phase: Phase
        var reviewSession: CodexReviewSession?
    }

    private let client: AppServerClient
    private let phaseLock = NSLock()
    private var phase: Phase = .preparing
    private var reviewSession: CodexReviewSession?

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
        reviewSession = nil
    }

    package func recordReviewStarted(turnThreadID: String, turnID: String) {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        phase = .reviewStarted(turnThreadID: turnThreadID, turnID: turnID)
        reviewSession = nil
    }

    package func recordReviewStarted(_ reviewSession: CodexReviewSession) {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        phase = .reviewStarted(
            turnThreadID: reviewSession.reviewThreadID.rawValue,
            turnID: reviewSession.turnID.rawValue
        )
        self.reviewSession = reviewSession
    }

    package func recordTurnStarted(turnThreadID: String, turnID: String) {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        phase = .reviewStarted(turnThreadID: turnThreadID, turnID: turnID)
        reviewSession = nil
    }

    @discardableResult
    package func interrupt(
        willInterruptActiveTurn: (@Sendable (AppServerReviewInterruption) async -> Void)? = nil
    ) async throws -> AppServerReviewInterruption? {
        let snapshot = stateSnapshot()
        switch snapshot.phase {
        case .preparing, .finished:
            return nil
        case .threadStarted(let threadID):
            return try await sendInterrupt(
                threadID: threadID,
                turnID: "",
                willInterruptActiveTurn: willInterruptActiveTurn
            )
        case .reviewStarted(let turnThreadID, let turnID):
            if let reviewSession = snapshot.reviewSession {
                return try await interrupt(
                    reviewSession,
                    expectedTurnID: turnID,
                    willInterruptActiveTurn: willInterruptActiveTurn
                )
            }
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
        reviewSession = nil
    }

    private func stateSnapshot() -> Snapshot {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        return Snapshot(phase: phase, reviewSession: reviewSession)
    }

    private func interrupt(
        _ reviewSession: CodexReviewSession,
        expectedTurnID: String,
        willInterruptActiveTurn: (@Sendable (AppServerReviewInterruption) async -> Void)?
    ) async throws -> AppServerReviewInterruption {
        let interruption = try await reviewSession.interrupt { interruption in
            guard let willInterruptActiveTurn else {
                return
            }
            await willInterruptActiveTurn(AppServerReviewInterruption(interruption))
        }
        let reviewInterruption = AppServerReviewInterruption(interruption)
        if reviewInterruption.turnID != expectedTurnID {
            setPhase(
                .reviewStarted(
                    turnThreadID: reviewInterruption.threadID,
                    turnID: reviewInterruption.turnID
                )
            )
        }
        return reviewInterruption
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
                await willInterruptActiveTurn(AppServerReviewInterruption(interruption))
            }
        )
        let reviewInterruption = AppServerReviewInterruption(interruption)
        if reviewInterruption.turnID != turnID {
            setPhase(.reviewStarted(turnThreadID: threadID, turnID: reviewInterruption.turnID))
        }
        return reviewInterruption
    }

    private func setPhase(_ phase: Phase, reviewSession: CodexReviewSession? = nil) {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        self.phase = phase
        self.reviewSession = reviewSession
    }
}

private extension AppServerReviewInterruption {
    init(_ interruption: CodexTurnInterruption) {
        self.init(
            threadID: interruption.threadID.rawValue,
            turnID: interruption.turnID?.rawValue ?? ""
        )
    }
}
