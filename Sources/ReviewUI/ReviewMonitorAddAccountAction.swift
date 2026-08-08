import CodexReviewKit

@MainActor
enum ReviewMonitorAddAccountAction {
    static func perform(
        store: CodexReviewStore,
        submission: ReviewMonitorAuthenticationSubmission
    ) {
        Task {
            await perform(store: store, submission: submission) { method in
                try await store.addAccount(using: method)
            }
        }
    }

    static func perform(
        store: CodexReviewStore,
        submission: ReviewMonitorAuthenticationSubmission = .chatGPT,
        operation: (CodexReviewAuthenticationMethod) async throws -> Void
    ) async {
        do {
            try await operation(submission.method)
        } catch {
            store.auth.presentAccountActionAlert(
                title: "Failed to Add Account",
                message: error.localizedDescription
            )
        }
    }

    static func presentValidationFailure(
        store: CodexReviewStore,
        error: any Error
    ) {
        store.auth.presentAccountActionAlert(
            title: "Failed to Add Account",
            message: error.localizedDescription
        )
    }
}
