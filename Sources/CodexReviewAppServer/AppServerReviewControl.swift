import Foundation
import CodexReview

package final class AppServerReviewControl: @unchecked Sendable {
    private enum Phase: Equatable {
        case preparing
        case threadStarted(threadID: String)
        case reviewStarted(threadID: String, turnID: String)
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

    package func recordReviewStarted(threadID: String, turnID: String) {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        phase = .reviewStarted(threadID: threadID, turnID: turnID)
    }

    package func recordTurnStarted(threadID: String, turnID: String) {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        phase = .reviewStarted(threadID: threadID, turnID: turnID)
    }

    @discardableResult
    package func interrupt() async throws -> Bool {
        let currentPhase = phaseSnapshot()
        switch currentPhase {
        case .preparing, .finished:
            return false
        case .threadStarted(let threadID):
            return try await sendInterrupt(threadID: threadID, turnID: "")
        case .reviewStarted(let threadID, let turnID):
            return try await sendInterrupt(threadID: threadID, turnID: turnID)
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

    private func sendInterrupt(threadID: String, turnID: String) async throws -> Bool {
        do {
            let _: EmptyResponse = try await client.send(TurnInterruptRequest(
                params: .init(threadID: threadID, turnID: turnID)
            ))
            return true
        } catch {
            guard let activeTurnID = Self.activeTurnID(from: error),
                  activeTurnID != turnID
            else {
                throw error
            }
            let _: EmptyResponse = try await client.send(TurnInterruptRequest(
                params: .init(threadID: threadID, turnID: activeTurnID)
            ))
            setPhase(.reviewStarted(threadID: threadID, turnID: activeTurnID))
            return true
        }
    }

    private func setPhase(_ phase: Phase) {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        self.phase = phase
    }

    private static func activeTurnID(from error: Error) -> String? {
        guard case JSONRPCError.responseError(_, let message) = error,
              let range = message.range(of: " but found ")
        else {
            return nil
        }
        return String(message[range.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "` ").union(.whitespacesAndNewlines))
            .nilIfEmpty
    }
}
