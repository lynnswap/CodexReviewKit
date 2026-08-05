import Foundation
import Testing
@testable import CodexReviewKit
@testable import ReviewUI

@Suite("ReviewMonitor add account action")
@MainActor
struct ReviewMonitorAddAccountActionTests {
    @Test func signedOutSignInControlsExposeStableProviderIdentifiers() {
        #expect(SignInView.AccessibilityIdentifier.chatGPTButton == "review-monitor.sign-in-button")
        #expect(SignInView.AccessibilityIdentifier.apiKeyField == "review-monitor.api-key-field")
        #expect(SignInView.AccessibilityIdentifier.apiKeyButton == "review-monitor.api-key-sign-in-button")
    }

    @Test func signInControlStateKeepsOnlyCancellationAvailableDuringAuthentication() {
        let signedOut = SignInView.ControlState(
            apiKeyIsEmpty: true,
            isAuthenticating: false,
            canPerformAuthentication: true
        )
        #expect(signedOut.providerInputsAreDisabled == false)
        #expect(signedOut.apiKeySubmitIsDisabled)
        #expect(signedOut.showsCancelAction == false)

        let populated = SignInView.ControlState(
            apiKeyIsEmpty: false,
            isAuthenticating: false,
            canPerformAuthentication: true
        )
        #expect(populated.apiKeySubmitIsDisabled == false)

        let authenticating = SignInView.ControlState(
            apiKeyIsEmpty: false,
            isAuthenticating: true,
            canPerformAuthentication: true
        )
        #expect(authenticating.providerInputsAreDisabled)
        #expect(authenticating.apiKeySubmitIsDisabled)
        #expect(authenticating.showsCancelAction)
    }

    @Test func nonChatGPTAccountsUseProviderNamesInsteadOfEmailMasking() {
        let apiKeyAccount = CodexReviewAccount(
            accountKey: "api-key",
            email: "api-key@example.invalid",
            kind: .apiKey
        )
        let bedrockAccount = CodexReviewAccount(
            accountKey: "bedrock",
            email: "bedrock@example.invalid",
            kind: .amazonBedrock
        )

        #expect(apiKeyAccount.reviewMonitorDisplayName == "API Key")
        #expect(apiKeyAccount.reviewMonitorDisplayName.contains("@") == false)
        #expect(bedrockAccount.reviewMonitorDisplayName == "Amazon Bedrock")
    }

    @Test func operationFailureUsesTheAccountActionAlertFlow() async throws {
        let store = CodexReviewStore.makePreviewStore()

        await ReviewMonitorAddAccountAction.perform(store: store) { _ in
            throw CodexReviewAPI.Error.io("Review runtime operations are closed.")
        }

        let alert = try #require(store.auth.accountActionAlert)
        #expect(String(localized: alert.title) == "Failed to Add Account")
        #expect(alert.message == "Review runtime operations are closed.")
    }

    @Test func apiKeySubmissionClearsInputAndSelectsAPIKeyAuthentication() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let secret = "sk-ui-test-secret"
        var input = ReviewMonitorAPIKeyInput(value: secret)
        let submission = try input.takeSubmission()
        var receivedAPIKeyMethod = false

        await ReviewMonitorAddAccountAction.perform(
            store: store,
            submission: submission
        ) { method in
            guard case .apiKey = method else {
                return
            }
            receivedAPIKeyMethod = true
        }

        #expect(input.value.isEmpty)
        #expect(receivedAPIKeyMethod)
        #expect(store.auth.accountActionAlert == nil)
    }

    @Test func apiKeyOperationFailureRedactsTheSubmittedSecret() async throws {
        let store = CodexReviewStore.makePreviewStore()
        let secret = "sk-ui-test-secret"
        var input = ReviewMonitorAPIKeyInput(value: secret)
        let submission = try input.takeSubmission()

        await ReviewMonitorAddAccountAction.perform(
            store: store,
            submission: submission
        ) { _ in
            throw CodexReviewAPI.Error.io("Request rejected for \(secret)")
        }

        let alert = try #require(store.auth.accountActionAlert)
        #expect(alert.message == "Request rejected for [REDACTED]")
        #expect(alert.message.contains(secret) == false)
    }

    @Test func invalidAPIKeyClearsInputWithoutEchoingIt() {
        let invalidValue = "   "
        var input = ReviewMonitorAPIKeyInput(value: invalidValue)

        #expect(throws: (any Error).self) {
            _ = try input.takeSubmission()
        }

        #expect(input.value.isEmpty)
        do {
            var retryInput = ReviewMonitorAPIKeyInput(value: invalidValue)
            _ = try retryInput.takeSubmission()
            Issue.record("Expected API key validation to fail.")
        } catch {
            #expect(error.localizedDescription.contains(invalidValue) == false)
            #expect(error.localizedDescription == "Enter a valid OpenAI API key.")
        }
    }
}
