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
    private enum Phase {
        case preparing
        case threadStarted
        case reviewStarted(turnID: String)
        case finished
    }

    private struct Snapshot {
        var phase: Phase
        var reviewSession: CodexReviewSession?
    }

    private let phaseLock = NSLock()
    private var phase: Phase = .preparing
    private var reviewSession: CodexReviewSession?

    package init() {}

    package func recordThreadStarted() {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        guard case .preparing = phase else {
            return
        }
        phase = .threadStarted
        reviewSession = nil
    }

    package func recordReviewStarted(turnID: String) {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        phase = .reviewStarted(turnID: turnID)
        reviewSession = nil
    }

    package func recordReviewStarted(_ reviewSession: CodexReviewSession) {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        phase = .reviewStarted(turnID: reviewSession.turnID.rawValue)
        self.reviewSession = reviewSession
    }

    package func recordTurnStarted(turnID: String) {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        switch phase {
        case .preparing, .finished:
            return
        case .threadStarted:
            phase = .reviewStarted(turnID: turnID)
        case .reviewStarted:
            phase = .reviewStarted(turnID: turnID)
        }
    }

    @discardableResult
    package func interrupt(
        willInterruptActiveTurn: (@Sendable (AppServerReviewInterruption) async -> Void)? = nil
    ) async throws -> AppServerReviewInterruption? {
        let snapshot = stateSnapshot()
        switch snapshot.phase {
        case .preparing, .finished:
            return nil
        case .threadStarted:
            return nil
        case .reviewStarted(let turnID):
            guard let reviewSession = snapshot.reviewSession else {
                return nil
            }
            return try await interrupt(
                reviewSession,
                expectedTurnID: turnID,
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
        let interruption = try await reviewSession.interrupt()
        let reviewInterruption = AppServerReviewInterruption(interruption)
        if reviewInterruption.turnID != expectedTurnID,
           let willInterruptActiveTurn {
            await willInterruptActiveTurn(reviewInterruption)
        }
        if reviewInterruption.turnID != expectedTurnID {
            setPhase(.reviewStarted(turnID: reviewInterruption.turnID), reviewSession: reviewSession)
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
