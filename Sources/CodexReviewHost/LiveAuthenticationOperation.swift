import Foundation
import CodexReview
import CodexReviewAppServer

@MainActor
final class LiveAuthenticationOperation {
    enum Activation: Equatable, Sendable {
        case activateAuthenticatedAccount
        case preserveActiveAccount(String?)

        func resolvedActiveAccountKey(
            authenticatedAccountKey: String,
            persistedAccounts: [CodexAccount]
        ) -> String? {
            switch self {
            case .activateAuthenticatedAccount:
                return authenticatedAccountKey
            case .preserveActiveAccount(let activeAccountKey):
                return activeAccountKey.flatMap { activeAccountKey in
                    persistedAccounts.contains(where: { $0.accountKey == activeAccountKey })
                        ? activeAccountKey
                        : nil
                }
            }
        }
    }

    enum Phase: Equatable {
        case waitingForCompletion
        case waitingForAccountUpdate
    }

    var activation = Activation.activateAuthenticatedAccount
    var challenge: CodexReviewBackendModel.Login.Challenge?
    var backend: AppServerCodexReviewBackend?
    var client: AppServerClient?
    var codexHomeURL: URL?
    var phase = Phase.waitingForCompletion
    var authenticationSession: (any CodexReviewNativeAuthentication.WebSession)?
    var monitorTask: Task<Void, Never>?
    var notificationTask: Task<Void, Never>?
}
