import SwiftUI
import CodexReviewKit

struct ReviewMonitorAuthenticationSubmission {
    let method: CodexReviewAuthenticationMethod

    static var chatGPT: Self {
        .init(method: .chatGPT)
    }
}

struct ReviewMonitorAPIKeyInput {
    var value = ""

    var isEmpty: Bool {
        value.isEmpty
    }

    mutating func takeSubmission() throws -> ReviewMonitorAuthenticationSubmission {
        let submittedValue = value
        clear()

        do {
            let apiKey = try CodexReviewAPIKey(validating: submittedValue)
            return ReviewMonitorAuthenticationSubmission(
                method: .apiKey(apiKey)
            )
        } catch {
            throw ReviewMonitorAPIKeyValidationFailure()
        }
    }

    mutating func clear() {
        value.removeAll(keepingCapacity: false)
    }
}

private struct ReviewMonitorAPIKeyValidationFailure: LocalizedError {
    var errorDescription: String? {
        "Enter a valid OpenAI API key."
    }
}

struct SignInView: View {
    struct ControlState: Equatable {
        let providerInputsAreDisabled: Bool
        let apiKeySubmitIsDisabled: Bool
        let showsCancelAction: Bool

        init(
            apiKeyIsEmpty: Bool,
            isAuthenticating: Bool,
            canPerformAuthentication: Bool
        ) {
            providerInputsAreDisabled = isAuthenticating || canPerformAuthentication == false
            apiKeySubmitIsDisabled = providerInputsAreDisabled || apiKeyIsEmpty
            showsCancelAction = isAuthenticating
        }
    }

    enum AccessibilityIdentifier {
        static let chatGPTButton = "review-monitor.sign-in-button"
        static let apiKeyField = "review-monitor.api-key-field"
        static let apiKeyButton = "review-monitor.api-key-sign-in-button"
        static let cancelButton = "review-monitor.authentication-cancel-button"
    }

    let store: CodexReviewStore
    @State private var apiKeyInput = ReviewMonitorAPIKeyInput()
    @State private var authenticationFailureMessage: String?

    var body: some View {
        let controlState = ControlState(
            apiKeyIsEmpty: apiKeyInput.isEmpty,
            isAuthenticating: store.auth.isAuthenticating,
            canPerformAuthentication: store.canPerformPrimaryAuthenticationAction
        )

        ContentUnavailableView {
            Text("Welcome to CodexReviewMonitor")
                .font(.largeTitle)
                .fontDesign(.rounded)
                .fontWidth(.compressed)
                .fontWeight(.semibold)
                .scenePadding(.bottom)

            VStack(spacing: 12) {
                Button("Sign in with ChatGPT") {
                    performAuthentication(.chatGPT)
                }
                .buttonSizing(.flexible)
                .buttonBorderShape(.capsule)
                .buttonStyle(.glassProminent)
                .disabled(controlState.providerInputsAreDisabled)
                .accessibilityIdentifier(AccessibilityIdentifier.chatGPTButton)

                HStack(spacing: 8) {
                    SecureField("OpenAI API key", text: apiKeyBinding)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("OpenAI API key")
                        .accessibilityIdentifier(AccessibilityIdentifier.apiKeyField)
                        .onSubmit {
                            guard controlState.apiKeySubmitIsDisabled == false else {
                                return
                            }
                            submitAPIKey()
                        }

                    Button("Sign in with API Key") {
                        submitAPIKey()
                    }
                    .accessibilityIdentifier(AccessibilityIdentifier.apiKeyButton)
                    .disabled(controlState.apiKeySubmitIsDisabled)
                }
                .disabled(controlState.providerInputsAreDisabled)
                .frame(maxWidth: 440)

                if controlState.showsCancelAction {
                    Button(role: .cancel) {
                        cancelAuthentication()
                    } label: {
                        LabeledContent {
                            ProgressView()
                                .controlSize(.small)
                        } label: {
                            Text("Cancel")
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonSizing(.flexible)
                    .buttonBorderShape(.capsule)
                    .accessibilityIdentifier(AccessibilityIdentifier.cancelButton)
                }
            }
            .animation(.default, value: controlState)

        } description: {
            if let descriptionText {
                Text(descriptionText)
            }
        }
        .scenePadding()
        .onDisappear {
            apiKeyInput.clear()
        }
        .alert(
            "Authentication Request Failed",
            isPresented: Binding(
                get: { authenticationFailureMessage != nil },
                set: { if $0 == false { authenticationFailureMessage = nil } }
            )
        ) {
            Button("OK") {
                authenticationFailureMessage = nil
            }
        } message: {
            Text(authenticationFailureMessage ?? "Authentication request failed.")
        }
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { apiKeyInput.value },
            set: { apiKeyInput.value = $0 }
        )
    }

    private func submitAPIKey() {
        do {
            let submission = try apiKeyInput.takeSubmission()
            performAuthentication(submission)
        } catch {
            authenticationFailureMessage = error.localizedDescription
        }
    }

    private func performAuthentication(_ submission: ReviewMonitorAuthenticationSubmission) {
        Task { @MainActor in
            do {
                try await store.performPrimaryAuthenticationAction(using: submission.method)
            } catch {
                authenticationFailureMessage = error.localizedDescription
            }
        }
    }

    private func cancelAuthentication() {
        apiKeyInput.clear()
        Task { @MainActor in
            await store.cancelAuthentication()
        }
    }

    private var descriptionText: String? {
        store.auth.progress?.detail ?? store.auth.errorMessage ?? serverFailureMessage
    }

    private var serverFailureMessage: String? {
        guard case .failed(let message) = store.serverState else {
            return nil
        }
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedMessage.isEmpty ? nil : trimmedMessage
    }
}
