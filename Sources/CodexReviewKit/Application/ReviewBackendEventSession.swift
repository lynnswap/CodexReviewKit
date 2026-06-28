import Foundation

package struct ReviewBackendEventSessionMetrics: Equatable, Sendable {
    package var routed = 0
    package var decoded = 0
    package var emitted = 0
    package var ignored = 0
    package var buffered = 0
    package var commandTimeoutWarnings = 0
    package var firstEventLatencyMs: Int?
    package var terminalLatencyMs: Int?

    package init() {}
}

package struct ReviewBackendEventSessionCallbacks: Sendable {
    package var recordTurnStarted: @Sendable (_ turnID: String) async -> Void
    package var recordFinished:
        @Sendable (
            _ run: CodexReviewBackendModel.Review.Run,
            _ metrics: ReviewBackendEventSessionMetrics
        ) async -> Void

    package init(
        recordTurnStarted: @escaping @Sendable (_ turnID: String) async -> Void = { _ in },
        recordFinished:
            @escaping @Sendable (
                _ run: CodexReviewBackendModel.Review.Run,
                _ metrics: ReviewBackendEventSessionMetrics
            ) async -> Void = { _, _ in }
    ) {
        self.recordTurnStarted = recordTurnStarted
        self.recordFinished = recordFinished
    }
}

package actor ReviewBackendEventSession {
    private var run: CodexReviewBackendModel.Review.Run
    private let mailbox: BackendReviewEventMailbox
    private let callbacks: ReviewBackendEventSessionCallbacks
    private var reviewThreadIDsForCleanup: [String] = []
    private var cancellationRequestedMessage: String?
    private let createdAt = Date()
    private var finished = false
    private var metrics = ReviewBackendEventSessionMetrics()

    package init(
        run: CodexReviewBackendModel.Review.Run,
        mailbox: BackendReviewEventMailbox = .init(),
        callbacks: ReviewBackendEventSessionCallbacks = .init()
    ) {
        self.run = run
        self.mailbox = mailbox
        self.callbacks = callbacks
        if let reviewThreadID = run.reviewThreadID?.nilIfEmpty,
            reviewThreadID != run.threadID
        {
            self.reviewThreadIDsForCleanup.append(reviewThreadID)
        }
    }

    package func updateRun(_ run: CodexReviewBackendModel.Review.Run) {
        self.run = run
        noteReviewThreadIDForCleanup(run.reviewThreadID)
    }

    package func currentRun() -> CodexReviewBackendModel.Review.Run {
        run
    }

    package func attempt() -> BackendReviewAttempt {
        .init(run: run, events: mailbox)
    }

    package func cleanupThreadIDs() -> [String] {
        var threadIDs = reviewThreadIDsForCleanup.filter { $0 != run.threadID }
        threadIDs.append(run.threadID)
        return threadIDs
    }

    package func requestCancellation(message: String) {
        cancellationRequestedMessage = message
    }

    package func clearCancellationRequest() {
        cancellationRequestedMessage = nil
    }

    package func finish(cancellationMessage: String?) async {
        cancellationRequestedMessage = cancellationMessage
        await finishSession(cancellationMessage: cancellationMessage)
    }

    package func finish(throwing error: (any Error)?) async {
        guard finished == false else {
            return
        }
        if let error {
            finished = true
            await mailbox.fail(error)
        } else {
            finished = true
            await mailbox.finish()
        }
    }

    package func abandon() async {
        guard finished == false else {
            return
        }
        finished = true
        await mailbox.abandon()
    }

    package func metricsSnapshot() -> ReviewBackendEventSessionMetrics {
        metrics
    }

    package func receive(
        _ events: [CodexReviewBackendModel.Review.Event],
        controlThreadID: String? = nil
    ) async {
        metrics.routed += 1
        guard finished == false else {
            metrics.ignored += 1
            return
        }
        guard events.isEmpty == false else {
            metrics.ignored += 1
            return
        }
        metrics.decoded += 1
        for event in events {
            if await emit(event, controlThreadID: controlThreadID) {
                return
            }
        }
    }

    private func finishSession(cancellationMessage: String?) async {
        guard finished == false else {
            return
        }
        if let cancellationMessage {
            _ = await emit(.cancelled(cancellationMessage))
        } else {
            await mailbox.finish()
        }
        finished = true
    }

    private func noteReviewThreadIDForCleanup(_ reviewThreadID: String?) {
        guard let reviewThreadID = reviewThreadID?.nilIfEmpty,
            reviewThreadID != run.threadID,
            reviewThreadIDsForCleanup.contains(reviewThreadID) == false
        else {
            return
        }
        reviewThreadIDsForCleanup.append(reviewThreadID)
    }

    private func emit(
        _ event: CodexReviewBackendModel.Review.Event,
        controlThreadID: String? = nil
    ) async -> Bool {
        noteEmission(event)
        await mailbox.append(event)
        await recordReviewEvent(event, controlThreadID: controlThreadID)
        return event.isReviewBackendTerminal
    }

    private func recordReviewEvent(
        _ event: CodexReviewBackendModel.Review.Event,
        controlThreadID _: String? = nil
    ) async {
        switch event {
        case .started(let turnID, _, _):
            await callbacks.recordTurnStarted(turnID)
        case .completed, .failed, .cancelled:
            await callbacks.recordFinished(run, metrics)
        case .progress:
            break
        }
    }

    private func noteEmission(_ event: CodexReviewBackendModel.Review.Event) {
        metrics.emitted += 1
        if metrics.firstEventLatencyMs == nil {
            metrics.firstEventLatencyMs = Self.durationMs(from: createdAt, to: Date())
        }
        if event.isReviewBackendTerminal {
            metrics.terminalLatencyMs = Self.durationMs(from: createdAt, to: Date())
        }
    }

    private static func durationMs(from start: Date, to end: Date) -> Int {
        let milliseconds = end.timeIntervalSince(start) * 1000
        guard milliseconds.isFinite else {
            return 0
        }
        return max(0, Int(milliseconds.rounded()))
    }
}

private extension CodexReviewBackendModel.Review.Event {
    var isReviewBackendTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .started,
            .progress:
            false
        }
    }
}
