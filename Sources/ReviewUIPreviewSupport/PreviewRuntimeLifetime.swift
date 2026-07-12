import CodexAppServerKit
import CodexAppServerKitTesting
import CodexDataKit
import CodexReviewKit
import Foundation
import ReviewUI

private struct PreviewRuntimeNotificationWork: Sendable {
    let sequence: UInt64
    let notification: ReviewMonitorPreviewRuntimeNotification
}

private actor PreviewRuntimeNotificationDrain {
    private var completedSequence: UInt64 = 0
    private var isFinished = false
    private var waiters: [(UInt64, CheckedContinuation<Void, Never>)] = []

    func complete(_ sequence: UInt64) {
        precondition(sequence == completedSequence &+ 1)
        completedSequence = sequence
        resumeSatisfiedWaiters()
    }

    func wait(until sequence: UInt64) async {
        guard isFinished == false, completedSequence < sequence else {
            return
        }
        await withCheckedContinuation { continuation in
            if isFinished || completedSequence >= sequence {
                continuation.resume()
            } else {
                waiters.append((sequence, continuation))
            }
        }
    }

    func finish() {
        guard isFinished == false else {
            return
        }
        isFinished = true
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        for (_, waiter) in waiters {
            waiter.resume()
        }
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [(UInt64, CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if waiter.0 <= completedSequence {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}

@MainActor
final class PreviewRuntimeLifecycleState {
    private(set) var fullCloseCount = 0
    private(set) var emittedNotificationCount = 0

    fileprivate func recordFullClose() {
        fullCloseCount += 1
    }

    fileprivate func recordNotificationEmission() {
        emittedNotificationCount += 1
    }
}

@MainActor
private final class PreviewRuntimeLifetimeCommitSink {
    private weak var lifetime: PreviewRuntimeLifetime?

    init(lifetime: PreviewRuntimeLifetime) {
        self.lifetime = lifetime
    }

    func install(
        runtime: CodexAppServerTestRuntime,
        container: CodexModelContainer
    ) -> Bool {
        lifetime?.install(runtime: runtime, container: container) == true
    }

    func finishStartWithoutInstalling() {
        lifetime?.finishStartWithoutInstalling()
    }

    func appendStreamTick() async {
        guard let lifetime else {
            return
        }
        _ = await lifetime.appendPreviewStreamTick(
            after: lifetime.currentTick,
            emitsNotifications: true
        )
    }

    func cancelPreviewChat(_ chatID: CodexThreadID) async {
        await lifetime?.cancelPreviewChat(chatID)
    }
}

@MainActor
final class PreviewRuntimeLifetime: CodexReviewPreviewRuntimeLifetime {
    private enum Phase {
        case active
        case stopping(Task<Void, Never>)
        case stopped
    }

    let modelSource = ReviewMonitorCodexModelSource()

    private let eventSink: ReviewMonitorPreviewRuntimeEventSink
    private let notificationStream: AsyncStream<PreviewRuntimeNotificationWork>
    private let notificationContinuation: AsyncStream<PreviewRuntimeNotificationWork>.Continuation
    private let notificationDrain = PreviewRuntimeNotificationDrain()
    let lifecycleStateForTesting = PreviewRuntimeLifecycleState()
    private var commitSink: PreviewRuntimeLifetimeCommitSink!
    private var runtime: CodexAppServerTestRuntime?
    private var container: CodexModelContainer?
    private var startTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var notificationSequence: UInt64 = 0
    private var phase = Phase.active
    private var acceptsEvents = true
    private var cancellationSignalled = false
    private(set) var stopOperationCountForTesting = 0

    init(fixtures: [ReviewMonitorPreviewChatLogFixture]) {
        eventSink = ReviewMonitorPreviewRuntimeEventSink(fixtures: fixtures)
        let pair = AsyncStream.makeStream(of: PreviewRuntimeNotificationWork.self)
        notificationStream = pair.stream
        notificationContinuation = pair.continuation
        commitSink = PreviewRuntimeLifetimeCommitSink(lifetime: self)
    }

    isolated deinit {
        signalCancellation()
    }

    var initialChatID: CodexThreadID? {
        eventSink.initialChatID
    }

    var currentTick: Int {
        eventSink.currentTick
    }

    func start() {
        guard acceptsEvents, runtime == nil, startTask == nil else {
            return
        }
        let threadStore = eventSink.threadStore
        let commitSink = commitSink!
        startTask = Task { @MainActor in
            var startedRuntime: CodexAppServerTestRuntime?
            do {
                let runtime = try await CodexAppServerTestRuntime.start(threadStore: threadStore)
                startedRuntime = runtime
                try Task.checkCancellation()
                let container = CodexModelContainer(appServer: runtime.server)
                try await runtime.transport.handleTurnInterrupt { [commitSink] request in
                    await commitSink.cancelPreviewChat(request.threadID)
                }
                try Task.checkCancellation()
                guard commitSink.install(runtime: runtime, container: container) else {
                    await runtime.close()
                    commitSink.finishStartWithoutInstalling()
                    return
                }
            } catch is CancellationError {
                await startedRuntime?.close()
                commitSink.finishStartWithoutInstalling()
            } catch {
                await startedRuntime?.close()
                preconditionFailure("Failed to start the Preview app-server runtime: \(error)")
            }
        }
    }

    func startStreaming(interval: Duration) {
        guard acceptsEvents, streamTask == nil else {
            return
        }
        start()
        let commitSink = commitSink!
        streamTask = Task { @MainActor in
            do {
                while Task.isCancelled == false {
                    try await Task.sleep(for: interval)
                    try Task.checkCancellation()
                    await commitSink.appendStreamTick()
                }
            } catch is CancellationError {
                return
            } catch {
                preconditionFailure("Preview stream sleep failed: \(error)")
            }
        }
    }

    func signalCancellation() {
        guard cancellationSignalled == false else {
            return
        }
        cancellationSignalled = true
        acceptsEvents = false
        startTask?.cancel()
        streamTask?.cancel()
        notificationTask?.cancel()
        notificationContinuation.finish()
    }

    func stop() async {
        switch phase {
        case .active:
            signalCancellation()
            stopOperationCountForTesting += 1

            let startTask = startTask
            let streamTask = streamTask
            let notificationTask = notificationTask
            let runtime = runtime
            let container = container
            let modelSource = modelSource
            let notificationDrain = notificationDrain
            let lifecycleState = lifecycleStateForTesting

            self.startTask = nil
            self.streamTask = nil
            self.notificationTask = nil
            self.runtime = nil
            self.container = nil

            let completion = Task { @MainActor in
                await streamTask?.value
                await startTask?.value
                await notificationTask?.value
                await notificationDrain.finish()
                modelSource.clear()
                if let runtime {
                    await runtime.close()
                    lifecycleState.recordFullClose()
                }
                _ = container
            }
            phase = .stopping(completion)
            await completion.value
            phase = .stopped

        case .stopping(let completion):
            await completion.value
            phase = .stopped

        case .stopped:
            return
        }
    }

    func waitUntilStopped() async {
        guard case .stopping(let completion) = phase else {
            return
        }
        await completion.value
        phase = .stopped
    }

    func cancelStreaming() {
        streamTask?.cancel()
    }

    func stopStreaming() async {
        let task = streamTask
        streamTask = nil
        task?.cancel()
        await task?.value
        await notificationDrain.wait(until: notificationSequence)
    }

    func upsertPreviewItem(
        _ item: CodexAppServerTestItem,
        to chatID: CodexThreadID
    ) async {
        guard acceptsEvents,
              let notification = await eventSink.prepareUpsertPreviewItem(item, to: chatID),
              acceptsEvents else {
            return
        }
        guard await ensureStarted() else {
            return
        }
        enqueue(notification)
    }

    func appendPreviewText(
        _ delta: String,
        to chatID: CodexThreadID,
        itemID: String,
        kind: CodexThreadItem.Kind,
        content: CodexThreadItem.Content
    ) async {
        guard acceptsEvents,
              let notification = await eventSink.prepareAppendPreviewText(
                  delta,
                  to: chatID,
                  itemID: itemID,
                  kind: kind,
                  content: content
              ),
              acceptsEvents else {
            return
        }
        guard await ensureStarted() else {
            return
        }
        enqueue(notification)
    }

    @discardableResult
    func appendPreviewStreamTick(
        after tick: Int,
        emitsNotifications: Bool
    ) async -> Int {
        guard acceptsEvents else {
            return tick
        }
        if emitsNotifications, await ensureStarted() == false {
            return tick
        }
        guard acceptsEvents else {
            return tick
        }
        let mutation = await eventSink.prepareStreamMutation(after: tick)
        guard acceptsEvents else {
            return mutation.tick
        }
        if emitsNotifications {
            for notification in mutation.notifications {
                enqueue(notification)
            }
        }
        return mutation.tick
    }

    func snapshotForTesting(chatID: CodexThreadID) async -> CodexThreadSnapshot? {
        await eventSink.snapshotForTesting(chatID: chatID)
    }

    func observedTurnStateForTesting(
        chatID: CodexThreadID
    ) -> CodexTurnSnapshot.State? {
        container?.mainContext.registeredModel(for: chatID)?.turns.last?.state
    }

    func interruptRequestCountForTesting() async -> Int {
        guard let runtime else {
            return 0
        }
        return await runtime.transport.recordedRequests(for: .turnInterrupt).count
    }

    func turnCompletionNotificationCountForTesting() -> Int {
        eventSink.turnCompletionNotificationCountForTesting()
    }

    func archiveRequestCountForTesting() async -> Int {
        guard let runtime else {
            return 0
        }
        return await runtime.transport.recordedRequests(for: .threadArchive).count
    }

    func startAndWaitForTesting() async {
        start()
        let task = startTask
        await task?.value
        precondition(runtime != nil || acceptsEvents == false)
    }

    var runtimeTransportForTesting: CodexAppServerTestTransport? {
        runtime?.transport
    }

    var runtimeServerForTesting: CodexAppServer? {
        runtime?.server
    }

    var modelContainerForTesting: CodexModelContainer? {
        container
    }

    var activeTaskCountForTesting: Int {
        [startTask, streamTask, notificationTask].compactMap { $0 }.count
    }

    private func ensureStarted() async -> Bool {
        guard acceptsEvents else {
            return false
        }
        if runtime != nil {
            return true
        }
        start()
        let task = startTask
        await task?.value
        return acceptsEvents && runtime != nil
    }

    fileprivate func install(
        runtime: CodexAppServerTestRuntime,
        container: CodexModelContainer
    ) -> Bool {
        guard acceptsEvents, self.runtime == nil else {
            return false
        }
        self.runtime = runtime
        self.container = container
        startNotificationWorker(using: runtime)
        modelSource.install(container: container)
        startTask = nil
        return true
    }

    fileprivate func finishStartWithoutInstalling() {
        startTask = nil
    }

    private func startNotificationWorker(using runtime: CodexAppServerTestRuntime) {
        precondition(notificationTask == nil)
        let stream = notificationStream
        let eventSink = eventSink
        let notificationDrain = notificationDrain
        let lifecycleState = lifecycleStateForTesting
        notificationTask = Task { @MainActor in
            for await work in stream {
                guard Task.isCancelled == false else {
                    break
                }
                await eventSink.emit(work.notification, using: runtime)
                lifecycleState.recordNotificationEmission()
                await notificationDrain.complete(work.sequence)
            }
            await notificationDrain.finish()
        }
    }

    private func enqueue(_ notification: ReviewMonitorPreviewRuntimeNotification) {
        precondition(acceptsEvents)
        precondition(runtime != nil)
        notificationSequence &+= 1
        notificationContinuation.yield(.init(
            sequence: notificationSequence,
            notification: notification
        ))
    }

    fileprivate func cancelPreviewChat(_ chatID: CodexThreadID) async {
        guard acceptsEvents,
              let notification = await eventSink.prepareCancellation(chatID: chatID),
              acceptsEvents else {
            return
        }
        enqueue(notification)
    }
}
