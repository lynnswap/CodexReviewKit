import AppKit
import Testing
import CodexReview
@testable import ReviewUI

@Suite("API key prompt")
@MainActor
struct ReviewMonitorAPIKeyPromptTests {
    @Test func consumeClearsValidInputAndReturnsARedactedKey() throws {
        let field = NSSecureTextField()
        let sentinel = "sk-secure-field-sentinel"
        field.stringValue = sentinel

        let apiKey = try ReviewMonitorAPIKeyPrompt.consume(field)

        #expect(field.stringValue.isEmpty)
        #expect(apiKey.description == "<redacted>")
        #expect(apiKey.description.contains(sentinel) == false)
    }

    @Test func consumeClearsInvalidInputBeforeReportingValidation() {
        let field = NSSecureTextField()
        field.stringValue = " invalid "

        #expect(throws: CodexReviewAPIKey.ValidationError.surroundingWhitespace) {
            try ReviewMonitorAPIKeyPrompt.consume(field)
        }
        #expect(field.stringValue.isEmpty)
    }

    @Test func signInControllerEndsPromptWhenItsViewDisappears() async {
        let store = CodexReviewStore.makePreviewStore()
        let viewController = ReviewMonitorSignInViewController(store: store)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)

        viewController.startAPIKeySignInForTesting()
        await waitUntil { window.attachedSheet != nil }
        #expect(viewController.hasAPIKeySignInTaskForTesting)

        viewController.viewWillDisappear()
        await waitUntil { window.attachedSheet == nil }
        await waitUntil { viewController.hasAPIKeySignInTaskForTesting == false }

        #expect(window.attachedSheet == nil)
        #expect(viewController.hasAPIKeySignInTaskForTesting == false)
    }

    @Test func signInControllerCancelsPromptQueuedBehindExistingSheet() async {
        let store = CodexReviewStore.makePreviewStore()
        let viewController = ReviewMonitorSignInViewController(store: store)
        let window = NSWindow(contentViewController: viewController)
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)

        let blockingAlert = NSAlert()
        blockingAlert.messageText = "Blocking sheet"
        blockingAlert.addButton(withTitle: "OK")
        blockingAlert.beginSheetModal(for: window) { _ in }
        await waitUntil { window.attachedSheet === blockingAlert.window }

        viewController.startAPIKeySignInForTesting()
        await waitUntil { viewController.hasAPIKeySignInTaskForTesting }
        viewController.viewWillDisappear()
        await waitUntil { viewController.hasAPIKeySignInTaskForTesting == false }

        #expect(window.attachedSheet === blockingAlert.window)
        #expect(viewController.hasAPIKeySignInTaskForTesting == false)
        window.endSheet(blockingAlert.window, returnCode: .cancel)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 where condition() == false {
            await Task.yield()
        }
    }
}
