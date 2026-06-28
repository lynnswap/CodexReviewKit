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
    private let completionCoordinator = ReviewCompletionCoordinator()
    private let createdAt = Date()
    private var finished = false
    private var metrics = ReviewBackendEventSessionMetrics()
    private var typedMessageTextByItemID: [String: String] = [:]
    private var typedReviewResultText: String?

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
            completionCoordinator.cancelPendingCompletion()
            await mailbox.fail(error)
        } else {
            if await flushPendingCompletion() {
                finished = true
                return
            }
            finished = true
            await mailbox.finish()
        }
    }

    package func abandon() async {
        guard finished == false else {
            return
        }
        finished = true
        completionCoordinator.cancelPendingCompletion()
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
        for event in eventsWithTypedResultFallback(events) {
            if event.shouldDeferReviewBackendCompletion {
                completionCoordinator.deferCompletion(event)
                continue
            }
            if await emit(event, controlThreadID: controlThreadID) {
                return
            }
        }
    }

    private func eventsWithTypedResultFallback(
        _ events: [CodexReviewBackendModel.Review.Event]
    ) -> [CodexReviewBackendModel.Review.Event] {
        events.map { event in
            switch event {
            case .message(let text):
                if let text = text.nilIfEmpty {
                    typedReviewResultText = text
                }
                return event
            case .messageDelta(let delta, let itemID):
                let text = (typedMessageTextByItemID[itemID] ?? "") + delta
                typedMessageTextByItemID[itemID] = text
                if let text = text.nilIfEmpty {
                    typedReviewResultText = text
                }
                return event
            case .domainEvents(let events):
                recordTypedMessageText(from: events)
                return event
            case .completed(let summary, nil):
                return .completed(summary: summary, result: typedReviewResultText)
            case .started,
                .log,
                .completed,
                .failed,
                .cancelled:
                return event
            }
        }
    }

    private func recordTypedMessageText(from events: [ReviewDomainEvent]) {
        for event in events {
            switch event {
            case .itemStarted(let seed),
                .itemUpdated(let seed),
                .itemCompleted(let seed):
                recordTypedMessageText(from: seed)
            case .textDelta(let itemID, _, let family, _, let delta) where family == .message:
                let text = (typedMessageTextByItemID[itemID.rawValue] ?? "") + delta
                typedMessageTextByItemID[itemID.rawValue] = text
                if let text = text.nilIfEmpty {
                    typedReviewResultText = text
                }
            case .runStarted,
                .textDelta,
                .reviewCompleted,
                .reviewFailed,
                .reviewCancelled:
                break
            }
        }
    }

    private func recordTypedMessageText(from seed: ReviewEventItemSeed) {
        guard seed.family == .message,
            case .message(let message) = seed.content
        else {
            return
        }
        typedMessageTextByItemID[seed.id.rawValue] = message.text
        if let text = message.text.nilIfEmpty {
            typedReviewResultText = text
        }
    }

    private func finishSession(cancellationMessage: String?) async {
        guard finished == false else {
            return
        }
        completionCoordinator.cancelPendingCompletion()
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
        let didFinish = completionCoordinator.emit(event)
        await mailbox.append(event)
        await recordReviewEvent(event, controlThreadID: controlThreadID)
        return didFinish
    }

    private func flushPendingCompletion(
        controlThreadID: String? = nil
    ) async -> Bool {
        guard let event = completionCoordinator.flushPendingCompletion() else {
            return false
        }
        let events = eventsWithTypedResultFallback([event])
        guard let event = events.first else {
            return false
        }
        noteEmission(event)
        await mailbox.append(event)
        await recordReviewEvent(event, controlThreadID: controlThreadID)
        return true
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
        case .domainEvents,
            .message,
            .messageDelta,
            .log:
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
        case .domainEvents,
            .started,
            .message,
            .messageDelta,
            .log:
            false
        }
    }

    var shouldDeferReviewBackendCompletion: Bool {
        guard case .completed(_, let result) = self else {
            return false
        }
        return result?.nilIfEmpty == nil
    }
}

private final class ReviewCompletionCoordinator {
    private var pendingCompletion: CodexReviewBackendModel.Review.Event?
    private var finished = false

    func emit(_ event: CodexReviewBackendModel.Review.Event) -> Bool {
        guard finished == false else {
            return true
        }
        guard event.isReviewBackendTerminal else {
            return false
        }
        finished = true
        pendingCompletion = nil
        return true
    }

    func deferCompletion(_ event: CodexReviewBackendModel.Review.Event) {
        guard finished == false else {
            return
        }
        pendingCompletion = event
    }

    func flushPendingCompletion() -> CodexReviewBackendModel.Review.Event? {
        guard finished == false,
            let event = pendingCompletion
        else {
            return nil
        }
        pendingCompletion = nil
        finished = true
        return event
    }

    func cancelPendingCompletion() {
        pendingCompletion = nil
    }
}
