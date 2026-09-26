import Foundation

@MainActor
package final class PreviewCodexReviewUpdateBackend: PreviewCodexReviewStoreBackend {
    package let started = PreviewCodexUpdateGate()
    package var completesReviews = false
    package var failsNextPreparation = false
    private var mailboxes: [String: BackendReviewEventMailbox] = [:]

    package init() {
        super.init(seed: .init(initialAccounts: [CodexAccount(email: "reviewer@example.com")]))
    }

    package override func prepareRuntime(generation: ReviewRuntimeGeneration, purpose: ReviewRuntimeTransitionPurpose) async throws -> PreparedRuntime {
        if failsNextPreparation {
            failsNextPreparation = false
            throw CodexReviewAPI.Error.io("Codex could not restart after the update. Try again.")
        }
        let account = CodexReviewBackendModel.Account.Snapshot(id: .init("reviewer@example.com"), label: "reviewer@example.com", isActive: true)
        return PreparedRuntime(
            snapshot: .init(authentication: .init(accounts: [account], activeAccountID: account.id), settings: currentSettingsSnapshot),
            handle: UpdatePreviewRuntime(
                onActivate: { [weak self] in self?.isActive = true },
                onClose: { [weak self] in self?.isActive = false }
            )
        )
    }

    package override func startReview(_ request: CodexReviewBackendModel.Review.Start, admission: ReviewStartAdmission) async throws -> BackendReviewAttempt {
        let run = CodexReviewBackendModel.Review.Run(threadID: request.jobID, turnID: request.jobID)
        try await admission.admitThreadStartDispatch()
        try await admission.recordPreparedThread(run)
        try await admission.admitReviewStartDispatch(for: run)
        try await admission.recordActiveRun(run)
        let mailbox = BackendReviewEventMailbox()
        mailboxes[run.threadID] = mailbox
        await started.open()
        if completesReviews { await mailbox.append(.completed(summary: "Review completed.", result: "No findings.")) }
        return .init(run: run, events: mailbox)
    }

    package override func interruptReview(_ admission: ReviewInterruptRequestAdmission, reason: CodexReviewBackendModel.CancellationReason) async throws {
        await mailboxes[admission.run.threadID]?.append(.cancelled(reason.message))
    }

    package override func cleanupReview(_ run: CodexReviewBackendModel.Review.Run) async {
        await mailboxes.removeValue(forKey: run.threadID)?.finish()
    }
}

@MainActor
private final class UpdatePreviewRuntime: RuntimeLifecycleHandle {
    private var closed = false
    private let onActivate: @MainActor () -> Void
    private let onClose: @MainActor () -> Void
    init(onActivate: @escaping @MainActor () -> Void, onClose: @escaping @MainActor () -> Void) {
        self.onActivate = onActivate
        self.onClose = onClose
    }
    func activate() async throws { onActivate() }
    func closeAdmission() {}
    func close(purpose: ReviewRuntimeTransitionPurpose) async throws { closed = true; onClose() }
    func waitUntilClosed() async throws {
        if closed == false { throw CancellationError() }
    }
}

package actor PreviewCodexUpdateGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    package init() {}
    package func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    package func open() {
        opened = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}
