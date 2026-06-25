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
    package var recordFinished: @Sendable (
        _ run: CodexReviewBackendModel.Review.Run,
        _ metrics: ReviewBackendEventSessionMetrics
    ) async -> Void

    package init(
        recordTurnStarted: @escaping @Sendable (_ turnID: String) async -> Void = { _ in },
        recordFinished: @escaping @Sendable (
            _ run: CodexReviewBackendModel.Review.Run,
            _ metrics: ReviewBackendEventSessionMetrics
        ) async -> Void = { _, _ in }
    ) {
        self.recordTurnStarted = recordTurnStarted
        self.recordFinished = recordFinished
    }
}

package actor ReviewBackendEventSession {
    private static let commandTimeoutExitCode = 124
    private static let longCommandDurationWarningMs = 100_000
    private static let streamedLogFlushIntervalNanoseconds: UInt64 = 20_000_000

    private var run: CodexReviewBackendModel.Review.Run
    private let mailbox: BackendReviewEventMailbox
    private let callbacks: ReviewBackendEventSessionCallbacks
    private var reviewThreadIDsForCleanup: [String] = []
    private var pendingStreamedLogEntries: [PendingStreamedLogEntry] = []
    private var pendingStreamedLogIndexByKey: [PendingStreamedLogEntry.Key: Int] = [:]
    private var streamedLogFlushTask: Task<Void, Never>?
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
           reviewThreadID != run.threadID {
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

    package func finish(
        cancellationMessage: String?,
        buffersMissingContinuation _: Bool = false
    ) async {
        let precedingEvents = drainPendingStreamedLogEvents()
        if cancellationMessage == nil {
            cancelPendingStreamedLogFlush()
        } else {
            cancellationRequestedMessage = cancellationMessage
        }
        await finish(precedingEvents: precedingEvents, cancellationMessage: cancellationMessage)
    }

    package func finish(throwing error: (any Error)?) async {
        guard finished == false else {
            return
        }
        let precedingEvents = drainPendingStreamedLogEvents()
        cancelPendingStreamedLogFlush()
        await emitPrecedingEvents(precedingEvents)
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
        cancelPendingStreamedLogFlush()
        pendingStreamedLogEntries.removeAll(keepingCapacity: true)
        pendingStreamedLogIndexByKey.removeAll(keepingCapacity: true)
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
        let events = eventsWithTypedResultFallback(events)
        for index in events.indices {
            let event = events[index]
            if case .domainEvents = event {
                let followingEvents = events[events.index(after: index)...]
                if shouldFlushPendingStreamedLogBeforeDomainEvent(
                    followingEvents: followingEvents,
                    suppressTimelineProjection: false
                ),
                   await flushPendingStreamedLog(controlThreadID: controlThreadID) {
                    return
                }
                if await emit(event, controlThreadID: controlThreadID) {
                    return
                }
                continue
            }
            if bufferStreamedLog(event) {
                continue
            }
            if await flushPendingStreamedLog(controlThreadID: controlThreadID) {
                return
            }
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
            case .logEntry(.agentMessage, let text, _, _, _):
                if let text = text.nilIfEmpty {
                    typedReviewResultText = text
                }
                return event
            case .completed(let summary, nil):
                return .completed(summary: summary, result: typedReviewResultText)
            case .domainEvents,
                 .suppressNextLegacyTimelineProjection,
                 .suppressNextTerminalFailureLogTimelineProjection,
                 .started,
                 .log,
                 .logEntry,
                 .completed,
                 .failed,
                 .cancelled:
                return event
            }
        }
    }

    private func finish(
        precedingEvents: [CodexReviewBackendModel.Review.Event],
        cancellationMessage: String?
    ) async {
        guard finished == false else {
            return
        }
        completionCoordinator.cancelPendingCompletion()
        cancelPendingStreamedLogFlush()
        await emitPrecedingEvents(precedingEvents)
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

    private func shouldFlushPendingStreamedLogBeforeDomainEvent(
        followingEvents: ArraySlice<CodexReviewBackendModel.Review.Event>,
        suppressTimelineProjection: Bool
    ) -> Bool {
        guard pendingStreamedLogEntries.isEmpty == false else {
            return false
        }
        return followingEvents.contains {
            canCoalescePendingStreamedLog(
                with: $0,
                suppressTimelineProjection: suppressTimelineProjection
            )
        } == false
    }

    private func canCoalescePendingStreamedLog(
        with event: CodexReviewBackendModel.Review.Event,
        suppressTimelineProjection: Bool
    ) -> Bool {
        guard let entry = PendingStreamedLogEntry(
            event,
            suppressesTimelineProjection: suppressTimelineProjection
        ) else {
            return false
        }
        return pendingStreamedLogIndexByKey[entry.key] != nil
    }

    private func bufferStreamedLog(
        _ event: CodexReviewBackendModel.Review.Event,
        suppressTimelineProjection: Bool = false
    ) -> Bool {
        guard let entry = PendingStreamedLogEntry(
            event,
            suppressesTimelineProjection: suppressTimelineProjection
        ) else {
            return false
        }
        if let index = pendingStreamedLogIndexByKey[entry.key] {
            pendingStreamedLogEntries[index].append(entry.text)
            if suppressTimelineProjection {
                pendingStreamedLogEntries[index].suppressTimelineProjection()
            }
        } else {
            pendingStreamedLogIndexByKey[entry.key] = pendingStreamedLogEntries.count
            pendingStreamedLogEntries.append(entry)
        }
        schedulePendingStreamedLogFlush()
        return true
    }

    private func schedulePendingStreamedLogFlush() {
        guard streamedLogFlushTask == nil else {
            return
        }
        streamedLogFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.streamedLogFlushIntervalNanoseconds)
            } catch {
                return
            }
            await self?.flushPendingStreamedLogFromTimer()
        }
    }

    private func flushPendingStreamedLogFromTimer() async {
        streamedLogFlushTask = nil
        _ = await flushPendingStreamedLog()
    }

    private func flushPendingStreamedLog(
        controlThreadID: String? = nil
    ) async -> Bool {
        let events = drainPendingStreamedLogEvents()
        guard events.isEmpty == false else {
            return false
        }
        cancelPendingStreamedLogFlush()
        for event in events {
            if await emit(event, controlThreadID: controlThreadID) {
                return true
            }
        }
        return false
    }

    private func drainPendingStreamedLogEvents() -> [CodexReviewBackendModel.Review.Event] {
        let events = pendingStreamedLogEntries.flatMap(\.events)
        pendingStreamedLogEntries.removeAll(keepingCapacity: true)
        pendingStreamedLogIndexByKey.removeAll(keepingCapacity: true)
        return events
    }

    private func cancelPendingStreamedLogFlush() {
        streamedLogFlushTask?.cancel()
        streamedLogFlushTask = nil
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
             .suppressNextLegacyTimelineProjection,
             .suppressNextTerminalFailureLogTimelineProjection,
             .message,
             .messageDelta,
             .log,
             .logEntry:
            break
        }
    }

    private func noteEmissions(_ events: [CodexReviewBackendModel.Review.Event]) {
        for event in events {
            noteEmission(event)
        }
    }

    private func emitPrecedingEvents(_ events: [CodexReviewBackendModel.Review.Event]) async {
        noteEmissions(events)
        for event in events {
            await mailbox.append(event)
            await recordReviewEvent(event)
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
        if Self.isCommandTimeoutWarning(event) {
            metrics.commandTimeoutWarnings += 1
        }
    }

    private static func isCommandTimeoutWarning(_ event: CodexReviewBackendModel.Review.Event) -> Bool {
        guard case .logEntry(_, _, _, _, let metadata) = event,
              metadata?.sourceType == "commandExecution"
        else {
            return false
        }
        if metadata?.exitCode == commandTimeoutExitCode {
            return true
        }
        return (metadata?.durationMs ?? 0) >= longCommandDurationWarningMs
    }

    private static func durationMs(from start: Date, to end: Date) -> Int {
        let milliseconds = end.timeIntervalSince(start) * 1000
        guard milliseconds.isFinite else {
            return 0
        }
        return max(0, Int(milliseconds.rounded()))
    }
}

private struct PendingStreamedLogEntry: Sendable {
    struct Key: Hashable, Sendable {
        var kind: ReviewLogEntry.Kind
        var groupID: String
        var sourceType: String?
        var itemID: String?
    }

    var kind: ReviewLogEntry.Kind
    var text: String
    var groupID: String
    var metadata: ReviewLogEntry.Metadata?
    var suppressesTimelineProjection: Bool

    var key: Key {
        .init(
            kind: kind,
            groupID: groupID,
            sourceType: metadata?.sourceType,
            itemID: metadata?.itemID
        )
    }

    var events: [CodexReviewBackendModel.Review.Event] {
        let logEntry = CodexReviewBackendModel.Review.Event.logEntry(
            kind: kind,
            text: text,
            groupID: groupID,
            replacesGroup: false,
            metadata: metadata
        )
        return suppressesTimelineProjection
            ? [.suppressNextLegacyTimelineProjection, logEntry]
            : [logEntry]
    }

    init?(_ event: CodexReviewBackendModel.Review.Event, suppressesTimelineProjection: Bool = false) {
        guard case .logEntry(let kind, let text, let groupID, let replacesGroup, let metadata) = event,
              text.isEmpty == false,
              replacesGroup == false,
              let groupID
        else {
            return nil
        }
        switch kind {
        case .commandOutput:
            guard metadata?.sourceType == "commandExecution",
                  metadata?.title == "Command output"
            else {
                return nil
            }
        case .reasoningSummary, .rawReasoning:
            break
        case .agentMessage, .command, .plan, .reasoning, .todoList, .toolCall, .diagnostic, .error, .progress, .event, .contextCompaction:
            return nil
        }
        self.kind = kind
        self.text = text
        self.groupID = groupID
        self.metadata = metadata
        self.suppressesTimelineProjection = suppressesTimelineProjection
    }

    mutating func append(_ suffix: String) {
        text += suffix
    }

    mutating func suppressTimelineProjection() {
        suppressesTimelineProjection = true
    }
}

package extension Array where Element == CodexReviewBackendModel.Review.Event {
    var legacyTimelineProjectionCount: Int {
        reduce(0) { count, event in
            count + (event.createsImmediateLegacyTimelineProjection ? 1 : 0)
        }
    }

    var addingTerminalFailureLogProjectionSuppressionIfNeeded: [Element] {
        flatMap { event -> [Element] in
            if case .failed = event {
                return [.suppressNextTerminalFailureLogTimelineProjection, event]
            }
            return [event]
        }
    }
}

private extension CodexReviewBackendModel.Review.Event {
    var isReviewBackendTerminal: Bool {
        return switch self {
        case .completed, .failed, .cancelled:
            true
        case .domainEvents,
             .suppressNextLegacyTimelineProjection,
             .suppressNextTerminalFailureLogTimelineProjection,
             .started,
             .message,
             .messageDelta,
             .log,
             .logEntry:
            false
        }
    }

    var shouldDeferReviewBackendCompletion: Bool {
        guard case .completed(_, let result) = self else {
            return false
        }
        return result?.nilIfEmpty == nil
    }

    var createsImmediateLegacyTimelineProjection: Bool {
        guard PendingStreamedLogEntry(self) == nil else {
            return false
        }
        return switch self {
        case .message, .messageDelta, .log, .logEntry:
            true
        case .domainEvents,
             .suppressNextLegacyTimelineProjection,
             .suppressNextTerminalFailureLogTimelineProjection,
             .started,
             .completed,
             .failed,
             .cancelled:
            false
        }
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
