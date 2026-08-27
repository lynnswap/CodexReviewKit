import AppKit
import CodexReview

@MainActor
enum ReviewMonitorAddAccountAction {
    static func perform(store: CodexReviewStore) {
        Task { @MainActor in
            await run(store: store) {
                await store.addAccount()
            }
        }
    }

    static func perform(store: CodexReviewStore, apiKey: CodexReviewAPIKey) {
        Task { @MainActor in
            await run(store: store) {
                await store.addAccount(apiKey: apiKey)
            }
        }
    }

    static func promptAndPerformAPIKey(store: CodexReviewStore, window: NSWindow?) {
        Task { @MainActor in
            guard let apiKey = await ReviewMonitorAPIKeyPrompt.request(
                window: window,
                submitTitle: "Add Account"
            ) else {
                return
            }
            await run(store: store) {
                await store.addAccount(apiKey: apiKey)
            }
        }
    }

    private static func run(
        store: CodexReviewStore,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) async {
        let auth = store.auth
        let previousFailureCount = auth.authenticationFailureCount
        let previousWarningMessage = auth.warningMessage
        await operation()
        if auth.authenticationFailureCount != previousFailureCount,
           let message = auth.errorMessage
        {
            await presentFailureAlert(
                title: "Failed to Add Account",
                message: message
            )
        } else if let warningMessage = auth.warningMessage,
                  warningMessage != previousWarningMessage
        {
            await presentFailureAlert(
                title: "Account Updated With Warning",
                message: warningMessage
            )
        }
    }

    private static func presentFailureAlert(
        title: String,
        message: String
    ) async {
        await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
