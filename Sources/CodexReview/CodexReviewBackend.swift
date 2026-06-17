import Foundation

package protocol CodexReviewBackend: Sendable {
    func readSettings() async throws -> BackendSettingsSnapshot
    func applySettings(_ change: BackendSettingsChange) async throws -> BackendSettingsSnapshot

    func readAuth() async throws -> BackendAuthSnapshot
    func startLogin(_ request: BackendLoginRequest) async throws -> BackendLoginChallenge
    func cancelLogin(_ challenge: BackendLoginChallenge) async throws
    func completeLogin(_ response: BackendLoginResponse) async throws -> BackendAuthSnapshot
    func logout(_ account: BackendAccountID) async throws -> BackendAuthSnapshot

    func startReview(_ request: BackendReviewStart) async throws -> BackendReviewAttempt
    func interruptReview(_ run: BackendReviewRun, reason: BackendCancellationReason) async throws
    func beginReviewRecovery(
        _ run: BackendReviewRun,
        reason: BackendCancellationReason
    ) async throws -> BackendReviewRecoveryToken
    func resumeReviewRecovery(
        _ token: BackendReviewRecoveryToken,
        request: BackendReviewStart
    ) async throws -> BackendReviewAttempt
    func cleanupReview(_ run: BackendReviewRun) async
}

package struct BackendReviewAttempt: Sendable {
    package var run: BackendReviewRun
    package var events: BackendReviewEventMailbox

    package init(run: BackendReviewRun, events: BackendReviewEventMailbox = .init()) {
        self.run = run
        self.events = events
    }
}

package actor BackendReviewEventMailbox {
    private enum Terminal {
        case finished
        case cancelled
        case failed(String)
    }

    private enum Delivery {
        case event(BackendReviewEvent)
        case finished
        case cancelled
        case failed(String)
    }

    private var bufferedEvents: [BackendReviewEvent] = []
    private var terminal: Terminal?
    private var waiters: [UUID: CheckedContinuation<Delivery, Never>] = [:]

    package init() {}

    package func next() async throws -> BackendReviewEvent? {
        switch await nextDelivery() {
        case .event(let event):
            return event
        case .finished:
            return nil
        case .cancelled:
            throw CancellationError()
        case .failed(let message):
            throw BackendReviewEventMailboxError(message: message)
        }
    }

    package func append(_ event: BackendReviewEvent) {
        guard terminal == nil else {
            return
        }
        if let waiterID = waiters.keys.first,
           let waiter = waiters.removeValue(forKey: waiterID) {
            waiter.resume(returning: .event(event))
        } else {
            bufferedEvents.append(event)
        }
        if Self.isTerminal(event) {
            terminal = .finished
            resumeWaitersForTerminal()
        }
    }

    package func append(contentsOf events: [BackendReviewEvent]) {
        for event in events {
            append(event)
        }
    }

    package func finish() {
        guard terminal == nil else {
            return
        }
        terminal = .finished
        resumeWaitersForTerminal()
    }

    package func fail(_ error: any Error) {
        guard terminal == nil else {
            return
        }
        terminal = error is CancellationError ? .cancelled : .failed(error.localizedDescription)
        resumeWaitersForTerminal()
    }

    package func abandon() {
        guard terminal == nil else {
            return
        }
        terminal = .finished
        bufferedEvents.removeAll(keepingCapacity: false)
        resumeWaitersForTerminal()
    }

    package func isFinished() -> Bool {
        terminal != nil && bufferedEvents.isEmpty
    }

    private func nextDelivery() async -> Delivery {
        if bufferedEvents.isEmpty == false {
            let event = bufferedEvents.removeFirst()
            resumeWaitersForTerminal()
            return .event(event)
        }
        if let terminal {
            return delivery(for: terminal)
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if bufferedEvents.isEmpty == false {
                    let event = bufferedEvents.removeFirst()
                    resumeWaitersForTerminal()
                    continuation.resume(returning: .event(event))
                } else if let terminal {
                    continuation.resume(returning: delivery(for: terminal))
                } else {
                    waiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
    }

    private func cancelWaiter(id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: .finished)
    }

    private func resumeWaitersForTerminal() {
        guard bufferedEvents.isEmpty, let terminal else {
            return
        }
        let delivery = delivery(for: terminal)
        let waiters = Array(waiters.values)
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: delivery)
        }
    }

    private func delivery(for terminal: Terminal) -> Delivery {
        switch terminal {
        case .finished:
            return .finished
        case .cancelled:
            return .cancelled
        case .failed(let message):
            return .failed(message)
        }
    }

    private static func isTerminal(_ event: BackendReviewEvent) -> Bool {
        switch event {
        case .completed, .failed, .cancelled:
            return true
        case .started, .message, .messageDelta, .log, .logEntry:
            return false
        }
    }
}

package struct BackendReviewEventMailboxError: LocalizedError, Sendable {
    package var message: String

    package init(message: String) {
        self.message = message
    }

    package var errorDescription: String? {
        message
    }
}

package struct CodexReviewClock: Sendable {
    package var now: @Sendable () -> Date

    package init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }
}

package struct CodexReviewIDGenerator: Sendable {
    package var next: @Sendable () -> String

    package init(next: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.next = next
    }
}
