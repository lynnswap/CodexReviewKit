import Foundation
import Testing
@testable import CodexReviewKit
import CodexReviewTesting
@testable import ReviewUI

@Suite("ReviewMonitor add account action")
@MainActor
struct ReviewMonitorAddAccountActionTests {
    @Test func signedOutSignInControlsExposeStableProviderIdentifiers() {
        #expect(SignInView.AccessibilityIdentifier.chatGPTButton == "review-monitor.sign-in-button")
        #expect(
            SignInView.AccessibilityIdentifier.alternateSignInButton
                == "review-monitor.alternate-sign-in-button"
        )
        #expect(SignInView.AccessibilityIdentifier.apiKeyField == "review-monitor.api-key-field")
        #expect(SignInView.AccessibilityIdentifier.apiKeyButton == "review-monitor.api-key-sign-in-button")
        #expect(
            SignInView.AccessibilityIdentifier.apiKeyCancelButton
                == "review-monitor.api-key-cancel-button"
        )
    }

    @Test func signInControlStateKeepsOnlyCancellationAvailableDuringAuthentication() {
        let signedOut = SignInView.ControlState(
            apiKeyIsEmpty: true,
            isAuthenticating: false,
            canPerformAuthentication: true,
            hasPendingOperation: false
        )
        #expect(signedOut.providerInputsAreDisabled == false)
        #expect(signedOut.apiKeySubmitIsDisabled)
        #expect(signedOut.showsCancelAction == false)

        let populated = SignInView.ControlState(
            apiKeyIsEmpty: false,
            isAuthenticating: false,
            canPerformAuthentication: true,
            hasPendingOperation: false
        )
        #expect(populated.apiKeySubmitIsDisabled == false)

        let authenticating = SignInView.ControlState(
            apiKeyIsEmpty: false,
            isAuthenticating: true,
            canPerformAuthentication: true,
            hasPendingOperation: false
        )
        #expect(authenticating.providerInputsAreDisabled)
        #expect(authenticating.apiKeySubmitIsDisabled)
        #expect(authenticating.showsCancelAction)

        let pending = SignInView.ControlState(
            apiKeyIsEmpty: false,
            isAuthenticating: false,
            canPerformAuthentication: true,
            hasPendingOperation: true
        )
        #expect(pending.providerInputsAreDisabled)
        #expect(pending.apiKeySubmitIsDisabled)
        #expect(pending.showsCancelAction)
    }

    @Test func nonChatGPTAccountsUseProviderNamesInsteadOfEmailMasking() {
        let chatGPTAccount = CodexReviewAccount(
            accountKey: "chatgpt@example.com",
            email: "chatgpt@example.com",
            kind: .chatGPT
        )
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
        #expect(chatGPTAccount.reviewMonitorIdentityName == "chatgpt@example.com")
        #expect(apiKeyAccount.reviewMonitorIdentityName == "API Key")
        #expect(bedrockAccount.reviewMonitorIdentityName == "Amazon Bedrock")
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

    @Test func apiKeyOperationFailureUsesTheSanitizedCoreMessage() async throws {
        let store = CodexReviewStore.makePreviewStore()
        var input = ReviewMonitorAPIKeyInput(value: "sk-ui-test-secret")
        let submission = try input.takeSubmission()

        await ReviewMonitorAddAccountAction.perform(
            store: store,
            submission: submission
        ) { _ in
            throw CodexReviewAPI.Error.io("Authentication failed.")
        }

        let alert = try #require(store.auth.accountActionAlert)
        #expect(alert.message == "Authentication failed.")
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

    @Test func cancellingAPIKeySignInWhileRuntimeStartsPreventsAuthentication() async throws {
        let startGate = AsyncGate()
        let backend = BlockingSignInStartBackend(startGate: startGate)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        let session = ReviewMonitorSignInSession()
        let apiKey = try CodexReviewAPIKey(validating: "sk-ui-test-secret")
        store.loadForTesting(serverState: .failed("Runtime failed."), authPhase: .signedOut)

        session.showAPIKeySignIn()
        session.authenticate(.init(method: .apiKey(apiKey)), store: store)
        await startGate.waitUntilBlocked()
        session.cancelAuthentication(store: store, returnsToOptions: true)
        await startGate.open()
        await session.waitUntilIdleForTesting()

        #expect(backend.authenticationRequests.isEmpty)
        #expect(session.screen == .options)
    }

    @Test func repeatedSubmissionWhileRuntimeStartsRunsOneAuthentication() async throws {
        let startGate = AsyncGate()
        let backend = BlockingSignInStartBackend(startGate: startGate)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        let session = ReviewMonitorSignInSession()
        let apiKey = try CodexReviewAPIKey(validating: "sk-ui-test-secret")
        let submission = ReviewMonitorAuthenticationSubmission(method: .apiKey(apiKey))
        store.loadForTesting(serverState: .failed("Runtime failed."), authPhase: .signedOut)

        session.authenticate(submission, store: store)
        session.authenticate(submission, store: store)
        await startGate.waitUntilBlocked()
        await startGate.open()
        await session.waitUntilIdleForTesting()

        #expect(backend.authenticationRequests.count == 1)
    }

    @Test func closingSignInSessionRestoresPrimaryOptions() async {
        let store = CodexReviewStore.makePreviewStore()
        let session = ReviewMonitorSignInSession()
        session.showAPIKeySignIn()

        session.close(store: store)
        await session.waitUntilIdleForTesting()

        #expect(session.screen == .options)
    }
}

@MainActor
private final class BlockingSignInStartBackend: PreviewCodexReviewStoreBackend {
    let startGate: AsyncGate
    private(set) var authenticationRequests: [CodexReviewAuthenticationRequest] = []

    init(startGate: AsyncGate) {
        self.startGate = startGate
        super.init()
    }

    override func start(
        store: CodexReviewStore,
        forceRestartIfNeeded _: Bool
    ) async {
        await startGate.waitIgnoringCancellation()
        isActive = true
        store.transitionToRunning(serverURL: nil)
    }

    override func authenticate(
        auth _: CodexReviewAuthModel,
        request: CodexReviewAuthenticationRequest
    ) async throws {
        authenticationRequests.append(request)
    }
}
