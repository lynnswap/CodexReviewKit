import Foundation
import Observation

@MainActor
@Observable
public final class CodexReviewAuthModel {
    package enum PendingAccountAction: Equatable, Sendable {
        case switchAccount(accountKey: String)
        case signOutActiveAccount
        case removeAccount(accountKey: String)

        package var confirmationTitle: LocalizedStringResource {
            switch self {
            case .switchAccount:
                "Switch Account?"
            case .signOutActiveAccount:
                "Sign Out?"
            case .removeAccount:
                "Remove Account?"
            }
        }

        package var confirmationMessage: LocalizedStringResource {
            "Running review jobs may stop after the account change is applied."
        }

        package var confirmationButtonTitle: LocalizedStringResource {
            switch self {
            case .switchAccount:
                "Switch"
            case .signOutActiveAccount:
                "Sign Out"
            case .removeAccount:
                "Remove"
            }
        }

        package var failureTitle: LocalizedStringResource {
            switch self {
            case .switchAccount:
                "Failed to Switch Account"
            case .signOutActiveAccount:
                "Failed to Sign Out"
            case .removeAccount:
                "Failed to Remove Account"
            }
        }
    }

    package struct AccountActionAlert: Equatable, Sendable {
        package let title: LocalizedStringResource
        package let message: String
    }

    public struct Progress: Sendable, Equatable {
        public var title: String
        public var detail: String
        public var browserURL: String?
        public var userCode: String?

        public init(
            title: String,
            detail: String,
            browserURL: String? = nil,
            userCode: String? = nil
        ) {
            self.title = title
            self.detail = detail
            self.browserURL = browserURL
            self.userCode = userCode
        }
    }

    public enum Phase: Sendable, Equatable {
        case signedOut
        case signingIn(Progress)
        case failed(message: String)
    }

    public package(set) var phase: Phase = .signedOut
    public package(set) var persistedAccounts: [CodexAccount] = []
    public package(set) var persistedActiveAccountKey: String?
    package private(set) var detachedAccount: CodexAccount?
    public private(set) var selectedAccount :CodexAccount?

    public package(set) var authenticationFailureCount = 0
    public package(set) var warningMessage: String?
    package private(set) var pendingAccountAction: PendingAccountAction?
    package private(set) var accountActionAlert: AccountActionAlert?

    public var progress: Progress? {
        guard case .signingIn(let progress) = phase else {
            return nil
        }
        return progress
    }

    public var isAuthenticating: Bool {
        progress != nil
    }

    public var isAuthenticated: Bool {
        selectedAccount != nil
    }

    public var accounts: [CodexAccount] {
        guard let detachedAccount else {
            return persistedAccounts
        }
        return persistedAccounts + [detachedAccount]
    }

    public var hasAccounts: Bool {
        accounts.isEmpty == false
    }

    public var errorMessage: String? {
        guard case .failed(let message) = phase else {
            return nil
        }
        return message
    }

    package static func makePreview() -> CodexReviewAuthModel {
        .init()
    }

    package init() {}

    package func requestSwitchAccount(
        _ account: CodexAccount,
        requiresConfirmation: Bool
    ) {
        guard persistedAccounts.contains(where: { $0.accountKey == account.accountKey }) else {
            return
        }
        requestAccountAction(
            .switchAccount(accountKey: account.accountKey),
            requiresConfirmation: requiresConfirmation
        )
    }

    package func requestSignOutActiveAccount(requiresConfirmation: Bool) {
        guard selectedAccount != nil else {
            return
        }
        requestAccountAction(
            .signOutActiveAccount,
            requiresConfirmation: requiresConfirmation
        )
    }

    package func requestRemoveAccount(
        _ account: CodexAccount,
        requiresConfirmation: Bool
    ) {
        requestAccountAction(
            .removeAccount(accountKey: account.accountKey),
            requiresConfirmation: requiresConfirmation
        )
    }

    package func cancelPendingAccountAction() {
        pendingAccountAction = nil
    }

    package func consumePendingAccountAction() -> PendingAccountAction? {
        defer {
            pendingAccountAction = nil
        }
        return pendingAccountAction
    }

    package func presentAccountActionAlert(
        title: LocalizedStringResource,
        message: String
    ) {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        accountActionAlert = .init(
            title: title,
            message: trimmedMessage.isEmpty ? "Request failed." : trimmedMessage
        )
    }

    package func dismissAccountActionAlert() {
        accountActionAlert = nil
    }

    package func updatePhase(_ phase: Phase) {
        self.phase = phase
    }

    package func recordAuthenticationFailure(message: String) {
        authenticationFailureCount += 1
        warningMessage = nil
        phase = .failed(message: message)
    }

    package func updateWarning(message: String?) {
        warningMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    package func selectPersistedAccount(_ persistedAccountID: CodexAccount.ID?) {
        guard let persistedAccountID else {
            selectedAccount = nil
            detachedAccount = nil
            return
        }
        selectedAccount = persistedAccounts.first(where: { $0.id == persistedAccountID })
        detachedAccount = nil
    }

    package func updateCurrentAccount(_ account: CodexAccount?) {
        guard let account else {
            selectedAccount = nil
            detachedAccount = nil
            return
        }

        if let persistedAccount = persistedAccounts.first(where: { $0.accountKey == account.accountKey }) {
            selectedAccount = persistedAccount
            detachedAccount = nil
            return
        }

        selectedAccount = account
        detachedAccount = account
    }

    package func applyPersistedAccountStates(
        _ incomingPersistedAccounts: [CodexSavedAccountPayload]
    ) {
        applyPersistedAccountStates(
            incomingPersistedAccounts,
            activeAccountKey: persistedActiveAccountKey
        )
    }

    package func applyPersistedAccountStates(
        _ incomingPersistedAccounts: [CodexSavedAccountPayload],
        activeAccountKey: String?
    ) {
        let resolvedPersistedAccounts = incomingPersistedAccounts.map { incomingAccount in
            let reconciledAccount = reusableAccount(for: incomingAccount.accountKey)
                ?? CodexAccount(
                    accountKey: incomingAccount.accountKey,
                    email: incomingAccount.email,
                    planType: incomingAccount.planType
                )
            reconciledAccount.apply(incomingAccount)
            return reconciledAccount
        }
        self.persistedAccounts = resolvedPersistedAccounts
        self.persistedActiveAccountKey = activeAccountKey.flatMap { activeAccountKey in
            resolvedPersistedAccounts.contains(where: { $0.accountKey == activeAccountKey })
                ? activeAccountKey
                : nil
        }
        reconcileDetachedAccount()
    }

    package func isPersistedActiveAccount(_ accountKey: String) -> Bool {
        persistedActiveAccountKey == accountKey
    }

    private func reusableAccount(for accountKey: String) -> CodexAccount? {
        persistedAccounts.first(where: { $0.accountKey == accountKey })
    }

    private func reconcileDetachedAccount() {
        guard let selectedAccount else {
            detachedAccount = nil
            return
        }
        guard let persistedAccount = persistedAccounts.first(where: { $0.accountKey == selectedAccount.accountKey }) else {
            detachedAccount = selectedAccount
            return
        }
        self.selectedAccount = persistedAccount
        detachedAccount = nil
    }

    private func requestAccountAction(
        _ action: PendingAccountAction,
        requiresConfirmation: Bool
    ) {
        pendingAccountAction = action
    }
}
