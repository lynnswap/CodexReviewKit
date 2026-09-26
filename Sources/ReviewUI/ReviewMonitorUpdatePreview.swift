import Foundation
@_spi(ApplicationHostSupport) import CodexReview

@_spi(PreviewSupport)
@MainActor
public final class ReviewMonitorUpdatePreview {
    public enum Scenario: Sendable { case waiting, installing, failed, resumed }
    public let store: CodexReviewStore
    private let backend: PreviewCodexReviewUpdateBackend
    private let installation = PreviewCodexUpdateGate()
    private var reviews: [Task<CodexReviewAPI.Read.Result, any Error>] = []

    public init() {
        let backend = PreviewCodexReviewUpdateBackend()
        self.backend = backend
        store = CodexReviewStore.makeTestingStore(backend: backend)
    }

    public func run(_ scenario: Scenario) async {
        await store.start()
        let store = store
        if scenario == .waiting {
            reviews.append(Task { try await store.startReview(
                sessionID: "preview", request: .init(cwd: "/Preview/Current Review", target: .baseBranch("main"))
            ) })
            await backend.started.wait()
        }
        backend.completesReviews = scenario == .resumed
        reviews.append(Task { try await store.startReview(
            sessionID: "preview", request: .init(cwd: "/Preview/Queued Review", target: .uncommittedChanges)
        ) })
        try? await store.updateCodex(when: scenario == .waiting ? .afterCurrentReviews : .immediately) { [self] in
            if scenario == .installing { await installation.wait() }
            if scenario == .failed { backend.failsNextPreparation = true }
        }
        if scenario == .resumed {
            for review in reviews { _ = try? await review.value }
        }
    }

    public func stop() async {
        await installation.open()
        await store.shutdown()
        for review in reviews { _ = try? await review.value }
        reviews = []
    }
}

