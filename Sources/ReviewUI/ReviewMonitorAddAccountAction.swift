import CodexReviewKit

@MainActor
enum ReviewMonitorAddAccountAction {
    static func perform(store: CodexReviewStore) {
        Task {
            await perform(store: store) {
                try await store.addAccount()
            }
        }
    }

    static func perform(
        store: CodexReviewStore,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
        } catch {
            store.auth.presentAccountActionAlert(
                title: "Failed to Add Account",
                message: error.localizedDescription
            )
        }
    }
}
