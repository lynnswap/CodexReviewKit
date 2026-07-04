import SwiftUI
import CodexReviewKit

struct SignInView: View {
    let store: CodexReviewStore

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
            
        } description: {
            if let descriptionText {
                Text(descriptionText)
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
