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
        case threadStarted(CodexThread)
        case reviewStarted(thread: CodexThread?, turnID: String)
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

    package func recordThreadStarted(_ thread: CodexThread) {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        guard case .preparing = phase else {
            return
        }
        phase = .threadStarted(thread)
        reviewSession = nil
    }

    package func recordReviewStarted(thread: CodexThread, turnID: String) {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        phase = .reviewStarted(thread: thread, turnID: turnID)
        reviewSession = nil
    }

    package func recordReviewStarted(_ reviewSession: CodexReviewSession) {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        phase = .reviewStarted(
            thread: nil,
            turnID: reviewSession.turnID.rawValue
        )
        self.reviewSession = reviewSession
    }

    package func recordTurnStarted(thread: CodexThread?, turnID: String) {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        switch phase {
        case .preparing, .finished:
            return
        case .threadStarted(let existingThread):
            phase = .reviewStarted(thread: thread ?? existingThread, turnID: turnID)
        case .reviewStarted(let existingThread, _):
            phase = .reviewStarted(thread: thread ?? existingThread, turnID: turnID)
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
        case .threadStarted(let thread):
            return try await interrupt(
                thread,
                expectedTurnID: nil,
                willInterruptActiveTurn: willInterruptActiveTurn
            )
        case .reviewStarted(let thread, let turnID):
            if let reviewSession = snapshot.reviewSession {
                return try await interrupt(
                    reviewSession,
                    expectedTurnID: turnID,
                    willInterruptActiveTurn: willInterruptActiveTurn
                )
            }
            guard let thread else {
                return nil
            }
            return try await interrupt(
                thread,
                expectedTurnID: turnID.nilIfEmpty.map(CodexTurnID.init(rawValue:)),
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
                    thread: nil,
                    turnID: reviewInterruption.turnID
                ),
                reviewSession: reviewSession
            )
        }
        return reviewInterruption
    }

    private func interrupt(
        _ thread: CodexThread,
        expectedTurnID: CodexTurnID?,
        willInterruptActiveTurn: (@Sendable (AppServerReviewInterruption) async -> Void)?
    ) async throws -> AppServerReviewInterruption {
        let interruption = try await thread.interruptActiveTurn(
            expectedTurnID: expectedTurnID,
            willInterruptActiveTurn: { interruption in
                guard let willInterruptActiveTurn else {
                    return
                }
                await willInterruptActiveTurn(AppServerReviewInterruption(interruption))
            }
        )
        let reviewInterruption = AppServerReviewInterruption(interruption)
        if reviewInterruption.turnID != expectedTurnID?.rawValue {
            setPhase(.reviewStarted(thread: thread, turnID: reviewInterruption.turnID))
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
