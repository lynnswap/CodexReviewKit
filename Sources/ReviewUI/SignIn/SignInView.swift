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
        if store.serverStatus.executableFailure != nil {
            ScrollView {
                signInContent
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.center, for: .alignment)
        } else {
            signInContent
        }
    }

    private var signInContent: some View {
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
                if let kind = store.serverStatus.executableFailure, let message = serverFailureMessage {
                    CodexCLISetupHelp(kind: kind, diagnostic: message)
                }
                if let message = store.auth.progress?.detail ?? store.auth.errorMessage {
                    Text(message)
                } else if store.serverStatus.executableFailure == nil, let message = serverFailureMessage {
                    Text(message)
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

    private var serverFailureMessage: String? {
        guard case .failed(let message) = store.serverState else {
            return nil
        }
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedMessage.isEmpty ? nil : trimmedMessage
    }
}

private struct CodexCLISetupHelp: View {
    let kind: CodexExecutableFailureKind
    let diagnostic: String
    @State private var showsDetails = false

    var body: some View {
        switch kind {
        case .notFound:
            Text("Install the Codex CLI, then retry. If it’s already installed, set its path in Settings, then quit and reopen ReviewMonitor.")
        case .invalidConfiguredPath:
            Text("Check the Codex executable path in Settings, then quit and reopen ReviewMonitor.")
        case .invalidEnvironment(let variable):
            Text("Update or remove the \(variable) environment variable, then quit and reopen ReviewMonitor.")
        }
        HStack(spacing: 16) {
            if kind == .notFound {
                Link("Install Codex CLI", destination: URL(string: "https://github.com/openai/codex#quickstart")!)
                    .accessibilityIdentifier("review-monitor.install-codex-link")
            }
            Button("Diagnostic Details") { showsDetails = true }
                .buttonStyle(.link)
                .popover(isPresented: $showsDetails) {
                    ScrollView {
                        Text(verbatim: diagnostic)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .frame(width: 360, height: 180)
                }
        }
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
    SignInView(store: makeSetupFailurePreviewStore(.notFound, message: "No usable Codex executable was found.\n/usr/local/bin/codex — not an executable regular file"))
}

#Preview("Codex Startup Failed") {
    SignInView(store: makeSetupFailurePreviewStore(.invalidConfiguredPath, message: "The explicitly selected Codex executable is invalid."))
}

@MainActor
private func makeSetupFailurePreviewStore(_ kind: CodexExecutableFailureKind, message: String) -> CodexReviewStore {
    let store = makeSignInPreviewStore()
    store.transitionToFailed(message, executableFailure: kind)
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
