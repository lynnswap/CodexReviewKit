import SwiftUI
import CodexReview

struct SignInView: View {
    let store: CodexReviewStore
    let startAPIKeySignIn: () -> Void

    init(
        store: CodexReviewStore,
        startAPIKeySignIn: @escaping () -> Void = {}
    ) {
        self.store = store
        self.startAPIKeySignIn = startAPIKeySignIn
    }

    var body: some View {
        ContentUnavailableView {
            Text("Welcome to CodexReviewMonitor")
                .font(.largeTitle)
                .fontDesign(.rounded)
                .fontWidth(.compressed)
                .fontWeight(.semibold)
                .scenePadding(.bottom)
            
            Button(role: store.auth.isAuthenticating ? .cancel : .confirm) {
                Task { @MainActor in
                    await store.performPrimaryAuthenticationAction()
                }
            } label: {
                LabeledContent {
                    if store.auth.isAuthenticating {
                        ProgressView()
                            .controlSize(.small)
                    }
                } label: {
                    Text(store.auth.isAuthenticating ? "Cancel" : "Sign in with ChatGPT")
                }
                .padding(.vertical, 4)
            }
            .buttonSizing(.flexible)
            .buttonBorderShape(.capsule)
            .buttonStyle(.glassProminent)
            .tint(store.auth.isAuthenticating ? .clear : .none)
            .disabled(store.canPerformPrimaryAuthenticationAction == false)
            .animation(.default,value:store.canPerformPrimaryAuthenticationAction)
            .accessibilityIdentifier("review-monitor.sign-in-button")

            if store.auth.isAuthenticating == false {
                Button {
                    startAPIKeySignIn()
                } label: {
                    Text("Sign in another way")
                        .padding(.vertical, 4)
                }
                .buttonSizing(.flexible)
                .buttonBorderShape(.capsule)
                .buttonStyle(.bordered)
                .disabled(store.canPerformPrimaryAuthenticationAction == false)
                .accessibilityIdentifier("review-monitor.api-key-sign-in-button")
            }
            
        } description: {
            VStack(spacing: 12) {
                Text("Reviews run using the Codex CLI installed on your Mac.")
                Link("Install Codex CLI", destination: URL(string: "https://github.com/openai/codex")!)
                    .accessibilityIdentifier("review-monitor.install-codex-link")
                if let descriptionText {
                    Text(descriptionText)
                }
                if case .failed = store.serverState {
                    Button("Retry Setup", systemImage: "arrow.clockwise") {
                        Task { await store.restart() }
                    }
                    .accessibilityIdentifier("review-monitor.retry-setup-button")
                }
            }
        }
        .animation(.default, value: store.auth.isAuthenticating)
        .scenePadding()
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
#Preview("Signed Out") {
    SignInView(store: makeSignInPreviewStore())
}

#Preview("Authenticating") {
    SignInView(store: makeAuthenticatingSignInPreviewStore())
}

#Preview("Codex CLI Not Installed") {
    SignInView(store: makeSetupFailurePreviewStore("No usable Codex executable was found. Install the Codex CLI, then retry setup."))
}

#Preview("Codex Startup Failed") {
    SignInView(store: makeSetupFailurePreviewStore("The explicitly selected Codex executable is invalid. Check its path in Settings."))
}

@MainActor
private func makeSetupFailurePreviewStore(_ message: String) -> CodexReviewStore {
    let store = makeSignInPreviewStore()
    store.transitionToFailed(message)
    return store
}

@MainActor
func makeSignInPreviewStore() -> CodexReviewStore {
    CodexReviewStore.makePreviewStore()
}

@MainActor
func makeAuthenticatingSignInPreviewStore() -> CodexReviewStore {
    let store = makeSignInPreviewStore()
    store.auth.updatePhase(
        .signingIn(
            .init(
                title: "Sign in with ChatGPT",
                detail: "Open the browser to continue.",
                browserURL: "https://auth.openai.com/oauth/authorize"
            )
        )
    )
    return store
}
#endif
