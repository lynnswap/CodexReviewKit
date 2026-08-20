import AppKit
import CodexReview

@MainActor
enum ReviewMonitorAddAccountAction {
    static func perform(store: CodexReviewStore) {
        Task {
            let auth = store.auth
            let previousFailureCount = auth.authenticationFailureCount
            let previousWarningMessage = auth.warningMessage
            await store.addAccount()
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
