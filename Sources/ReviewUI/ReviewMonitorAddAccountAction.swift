import AppKit
import CodexReviewKit

@MainActor
enum ReviewMonitorAddAccountAction {
    static func perform(store: CodexReviewStore) {
        Task {
            do {
                try await store.addAccount()
            } catch let failure as CodexReviewAuthenticationFailure {
                await presentFailureAlert(
                    title: "Failed to Add Account",
                    message: failure.localizedDescription
                )
            } catch {
                preconditionFailure("Unexpected authentication error: \(error)")
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
