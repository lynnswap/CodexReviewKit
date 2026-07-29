import SwiftUI
import CodexReviewKit

struct SignInView: View {
    let store: CodexReviewStore
    @State private var authenticationFailureMessage: String?

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
                    do {
                        try await store.performPrimaryAuthenticationAction()
                    } catch {
                        authenticationFailureMessage = error.localizedDescription
                    }
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
            
        } description: {
            if let descriptionText {
                Text(descriptionText)
            }
        }
        .animation(.default, value: store.auth.isAuthenticating)
        .scenePadding()
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
