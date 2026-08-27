import AppKit
import CodexReview

@MainActor
enum ReviewMonitorAPIKeyPrompt {
    static func request(
        window: NSWindow?,
        submitTitle: String,
        didPresent: @MainActor (NSAlert) -> Void = { _ in }
    ) async -> CodexReviewAPIKey? {
        var validationMessage: String?
        while true {
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            field.placeholderString = "OpenAI API key"
            field.setAccessibilityLabel("OpenAI API key")

            let alert = NSAlert()
            alert.messageText = "Use an API Key"
            alert.informativeText = validationMessage
                ?? "The key is stored by your local Codex app-server and is not shown in ReviewMonitor."
            alert.accessoryView = field
            alert.addButton(withTitle: submitTitle)
            alert.addButton(withTitle: "Cancel")
            didPresent(alert)

            let response = await response(to: alert, window: window)
            guard response == .alertFirstButtonReturn else {
                field.stringValue = ""
                return nil
            }
            do {
                return try consume(field)
            } catch {
                validationMessage = error.localizedDescription
            }
        }
    }

    static func consume(_ field: NSSecureTextField) throws -> CodexReviewAPIKey {
        let value = field.stringValue
        // Clear the control before validation so neither errors nor retries retain the raw key.
        field.stringValue = ""
        return try CodexReviewAPIKey(validating: value)
    }

    private static func response(
        to alert: NSAlert,
        window: NSWindow?
    ) async -> NSApplication.ModalResponse {
        guard let window else {
            return alert.runModal()
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }
}
