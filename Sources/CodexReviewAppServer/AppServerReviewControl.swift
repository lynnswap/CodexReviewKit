import Foundation
import CodexAppServerKit
import CodexReviewKit

package struct AppServerReviewCancellation: Equatable, Sendable {
    package var threadID: String
    package var turnID: String

    package init(threadID: String, turnID: String) {
        self.threadID = threadID
        self.turnID = turnID
    }

    package init(_ cancellation: CodexTurnCancellation) {
        self.init(
            threadID: cancellation.threadID.rawValue,
            turnID: cancellation.turnID?.rawValue ?? ""
        )
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
    package func cancel(
        willCancelActiveTurn: (@Sendable (AppServerReviewCancellation) async -> Void)? = nil
    ) async throws -> AppServerReviewCancellation? {
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
            guard willCancelActiveTurn == nil else {
                return nil
            }
            return try await cancel(reviewSession, expectedTurnID: turnID)
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

    private func cancel(
        _ reviewSession: CodexReviewSession,
        expectedTurnID: String
    ) async throws -> AppServerReviewCancellation {
        let cancellation = try await reviewSession.cancel()
        let reviewCancellation = AppServerReviewCancellation(cancellation)
        if reviewCancellation.turnID != expectedTurnID {
            setPhase(.reviewStarted(turnID: reviewCancellation.turnID), reviewSession: reviewSession)
        }
        return reviewCancellation
    }

    private func setPhase(_ phase: Phase, reviewSession: CodexReviewSession? = nil) {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        self.phase = phase
        self.reviewSession = reviewSession
    }
}
