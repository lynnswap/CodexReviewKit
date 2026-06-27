import CodexKit
import CodexReviewKit
import Foundation
import ObservationBridge
import ReviewMonitorRendering

@MainActor
final class ReviewMonitorPreviewChatLogSource {
    let snapshot: ReviewMonitorCodexSidebarSnapshot
    let initialChat: ReviewMonitorCodexSidebarSnapshot.Chat?

    private let jobsByChatID: [CodexThreadID: CodexReviewJob]

    init(jobs: [CodexReviewJob]) {
        var sections: [ReviewMonitorCodexSidebarSnapshot.Section] = []
        var sectionIndexesByCWD: [String: Int] = [:]
        var jobsByChatID: [CodexThreadID: CodexReviewJob] = [:]
        var initialRunningChat: ReviewMonitorCodexSidebarSnapshot.Chat?
        var firstChat: ReviewMonitorCodexSidebarSnapshot.Chat?

        for job in jobs {
            guard let chat = job.reviewChatSelection else {
                continue
            }

            jobsByChatID[chat.id] = job
            firstChat = firstChat ?? chat
            if initialRunningChat == nil, job.core.lifecycle.status == .running {
                initialRunningChat = chat
            }

            if let sectionIndex = sectionIndexesByCWD[job.cwd] {
                sections[sectionIndex].uncategorizedChats.append(chat)
            } else {
                sectionIndexesByCWD[job.cwd] = sections.count
                sections.append(
                    ReviewMonitorCodexSidebarSnapshot.Section(
                        rowID: .section(job.cwd),
                        id: job.cwd,
                        title: URL(fileURLWithPath: job.cwd).lastPathComponent,
                        workspaces: [],
                        uncategorizedChats: [chat]
                    ))
            }
        }

        self.snapshot = ReviewMonitorCodexSidebarSnapshot(sections: sections)
        self.initialChat = initialRunningChat ?? firstChat
        self.jobsByChatID = jobsByChatID
    }

    func logSourceChangeStream(for chatID: CodexThreadID) -> AsyncStream<ReviewMonitorLogSourceChange>? {
        guard let job = jobsByChatID[chatID] else {
            return nil
        }
        let pair = AsyncStream<ReviewMonitorLogSourceChange>.makeStream(bufferingPolicy: .unbounded)
        let subscription = PreviewChatLogSubscription(job: job, continuation: pair.continuation)
        subscription.start()
        pair.continuation.onTermination = { _ in
            Task { @MainActor in
                subscription.cancel()
            }
        }
        return pair.stream
    }
}

@MainActor
private final class PreviewChatLogSubscription {
    private let job: CodexReviewJob
    private let continuation: AsyncStream<ReviewMonitorLogSourceChange>.Continuation
    private var observation: PortableObservationTracking.Token?
    private var projection = ReviewMonitorTimelineLogProjection()
    private var hasRenderedDocument = false

    init(
        job: CodexReviewJob,
        continuation: AsyncStream<ReviewMonitorLogSourceChange>.Continuation
    ) {
        self.job = job
        self.continuation = continuation
    }

    func start() {
        publish(allowIncrementalUpdate: false)
        observation = withPortableContinuousObservation { [weak self] _ in
            guard let self else {
                return
            }
            _ = job.timeline.revision
            publish(allowIncrementalUpdate: hasRenderedDocument)
        }
    }

    func cancel() {
        observation?.cancel()
        observation = nil
    }

    private func publish(allowIncrementalUpdate: Bool) {
        let timelineDocument = ReviewTimelineDocumentRenderer().document(from: job.timeline)
        let sourceDocument = projection.render(timelineDocument: timelineDocument)
        continuation.yield(
            allowIncrementalUpdate
                ? .update(sourceDocument)
                : .replaceAll(sourceDocument)
        )
        hasRenderedDocument = true
    }
}
