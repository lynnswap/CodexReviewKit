import SwiftUI
import Observation
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

@MainActor
@Observable
final class ReviewMonitorSignInSession {
    enum Screen: Equatable {
        case options
        case apiKey
    }

    private struct Operation {
        let id: UUID
        let task: Task<Void, Never>
    }

    private(set) var screen = Screen.options
    var failureMessage: String?

    @ObservationIgnored
    private var operation: Operation?

    isolated deinit {
        operation?.task.cancel()
    }

    func showAPIKeySignIn() {
        screen = .apiKey
    }

    func present(_ error: any Error) {
        failureMessage = error.localizedDescription
    }

    func authenticate(
        _ submission: ReviewMonitorAuthenticationSubmission,
        store: CodexReviewStore
    ) {
        precondition(operation == nil, "A sign-in session can perform one operation at a time.")
        failureMessage = nil

        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            let failureMessage: String?
            do {
                try await store.performPrimaryAuthenticationAction(using: submission.method)
                failureMessage = nil
            } catch is CancellationError {
                failureMessage = nil
            } catch {
                failureMessage = error.localizedDescription
            }
            self?.finish(operationID, failureMessage: failureMessage)
        }
        operation = Operation(id: operationID, task: task)
    }

    func cancelAuthentication(
        store: CodexReviewStore,
        returnsToOptions: Bool = false
    ) {
        let authentication = operation
        operation = nil
        authentication?.task.cancel()
        failureMessage = nil

        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            await store.cancelAuthentication()
            await authentication?.task.value
            guard Task.isCancelled == false else {
                self?.finish(operationID, failureMessage: nil)
                return
            }
            if returnsToOptions {
                self?.screen = .options
            }
            self?.finish(operationID, failureMessage: nil)
        }
        operation = Operation(id: operationID, task: task)
    }

    func close(store: CodexReviewStore) {
        screen = .options
        cancelAuthentication(store: store)
    }

    private func finish(_ operationID: UUID, failureMessage: String?) {
        guard operation?.id == operationID else {
            return
        }
        operation = nil
        if let failureMessage {
            self.failureMessage = failureMessage
        }
    }

#if DEBUG
    func waitUntilIdleForTesting() async {
        while let operation {
            await operation.task.value
        }
    }
#endif
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
        static let alternateSignInButton = "review-monitor.alternate-sign-in-button"
        static let apiKeyField = "review-monitor.api-key-field"
        static let apiKeyButton = "review-monitor.api-key-sign-in-button"
        static let apiKeyCancelButton = "review-monitor.api-key-cancel-button"
        static let cancelButton = "review-monitor.authentication-cancel-button"
    }

    let store: CodexReviewStore
    @State private var session = ReviewMonitorSignInSession()

    var body: some View {
        ZStack {
            if session.screen == .apiKey {
                APIKeySignInView(
                    store: store,
                    session: session,
                    onSubmit: performAuthentication,
                    onCancel: {
                        session.cancelAuthentication(
                            store: store,
                            returnsToOptions: true
                        )
                    }
                )
            } else {
                signInOptions
            }
        }
        .animation(.easeInOut(duration: 0.22), value: session.screen)
        .onDisappear {
            session.close(store: store)
        }
        .alert(
            "Authentication Request Failed",
            isPresented: Binding(
                get: { session.failureMessage != nil },
                set: { if $0 == false { session.failureMessage = nil } }
            )
        ) {
            Button("OK") {
                session.failureMessage = nil
            }
        } message: {
            Text(session.failureMessage ?? "Authentication request failed.")
        }
    }

    private var signInOptions: some View {
        let controlState = ControlState(
            apiKeyIsEmpty: true,
            isAuthenticating: store.auth.isAuthenticating,
            canPerformAuthentication: store.canPerformPrimaryAuthenticationAction
        )

        return ContentUnavailableView {
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

                Button("Sign in another way") {
                    session.showAPIKeySignIn()
                }
                .buttonSizing(.flexible)
                .buttonBorderShape(.capsule)
                .disabled(controlState.providerInputsAreDisabled)
                .accessibilityIdentifier(AccessibilityIdentifier.alternateSignInButton)

                if controlState.showsCancelAction {
                    Button(role: .cancel) {
                        session.cancelAuthentication(store: store)
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
            .frame(maxWidth: 440)
            .animation(.default, value: controlState)

        } description: {
            if let descriptionText {
                Text(descriptionText)
            }
        }
        .scenePadding()
    }

    private func performAuthentication(_ submission: ReviewMonitorAuthenticationSubmission) {
        session.authenticate(submission, store: store)
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

private struct APIKeySignInView: View {
    let store: CodexReviewStore
    let session: ReviewMonitorSignInSession
    let onSubmit: (ReviewMonitorAuthenticationSubmission) -> Void
    let onCancel: () -> Void
    @State private var apiKeyInput = ReviewMonitorAPIKeyInput()

    var body: some View {
        let controlState = SignInView.ControlState(
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("OpenAI API key")

                    SecureField("sk-…", text: apiKeyBinding)
                        .textFieldStyle(.roundedBorder)
                        .disabled(controlState.providerInputsAreDisabled)
                        .accessibilityLabel("OpenAI API key")
                        .accessibilityIdentifier(SignInView.AccessibilityIdentifier.apiKeyField)
                        .onSubmit {
                            guard controlState.apiKeySubmitIsDisabled == false else {
                                return
                            }
                            submitAPIKey()
                        }
                }

                HStack(spacing: 8) {
                    Button("Cancel", role: .cancel) {
                        cancel()
                    }
                    .buttonSizing(.flexible)
                    .buttonBorderShape(.capsule)
                    .accessibilityIdentifier(SignInView.AccessibilityIdentifier.apiKeyCancelButton)

                    Button("Continue") {
                        submitAPIKey()
                    }
                    .buttonSizing(.flexible)
                    .buttonBorderShape(.capsule)
                    .buttonStyle(.glassProminent)
                    .disabled(controlState.apiKeySubmitIsDisabled)
                    .accessibilityIdentifier(SignInView.AccessibilityIdentifier.apiKeyButton)
                }

                if controlState.showsCancelAction {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: 440)
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
            onSubmit(submission)
        } catch {
            session.present(error)
        }
    }

    private func cancel() {
        apiKeyInput.clear()
        onCancel()
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

#if DEBUG
#Preview("Sign In") {
    SignInView(store: CodexReviewStore.makePreviewStore())
}

#Preview("API Key Sign In") {
    APIKeySignInView(
        store: CodexReviewStore.makePreviewStore(),
        session: ReviewMonitorSignInSession(),
        onSubmit: { _ in },
        onCancel: {}
    )
}
#endif
