import Foundation
import Observation

@MainActor
@Observable
public final class CodexReviewAccount: Identifiable, Hashable {
    @MainActor
    @Observable
    public final class RateLimitWindow: Identifiable, Hashable {
        nonisolated public let id: String
        nonisolated public let accountKey: String
        nonisolated public let windowDurationMinutes: Int
        public var usedPercent: Int
        public var resetsAt: Date?

        public init(
            accountKey: String = "__standalone__",
            windowDurationMinutes: Int,
            usedPercent: Int,
            resetsAt: Date? = nil
        ) {
            precondition(windowDurationMinutes > 0, "CodexReviewAccount.RateLimitWindow duration must be positive.")
            self.accountKey = accountKey
            self.windowDurationMinutes = windowDurationMinutes
            self.id = "\(accountKey):\(windowDurationMinutes)"
            self.usedPercent = min(max(usedPercent, 0), 100)
            self.resetsAt = resetsAt
        }

        package func update(
            usedPercent: Int,
            resetsAt: Date?
        ) {
            self.usedPercent = min(max(usedPercent, 0), 100)
            self.resetsAt = resetsAt
        }

        public static nonisolated func == (lhs: RateLimitWindow, rhs: RateLimitWindow) -> Bool {
            lhs.id == rhs.id
        }

        public nonisolated func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    public nonisolated static func normalizedEmail(_ email: String) -> String {
        email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
    nonisolated public let id: String
    public package(set) var email: String
    public package(set) var maskedEmail: String
    package private(set) var kind: CodexReviewBackendModel.Account.Kind
    public var planType: String?
    package private(set) var capabilities: CodexReviewBackendModel.Account.Capabilities
    public package(set) var rateLimits: [RateLimitWindow] = []
    public package(set) var isSwitching = false
    public package(set) var lastRateLimitFetchAt: Date?
    public package(set) var lastRateLimitError: String?

    public var requiresReauthentication: Bool {
        lastRateLimitError.map(Self.requiresReauthentication(errorMessage:)) ?? false
    }

    public var rateLimitStatusMessage: String? {
        if requiresReauthentication {
            return "Sign in again"
        }
        return lastRateLimitError
    }

    nonisolated public var accountKey: String {
        id
    }

    public convenience init(
        accountKey: String? = nil,
        email: String,
        planType: String? = nil
    ) {
        self.init(
            accountKey: accountKey,
            email: email,
            planType: planType,
            kind: .chatGPT,
            capabilities: .supportsCodexRateLimits
        )
    }

    package init(
        accountKey: String? = nil,
        email: String,
        planType: String? = nil,
        kind: CodexReviewBackendModel.Account.Kind = .chatGPT,
        capabilities: CodexReviewBackendModel.Account.Capabilities? = nil
    ) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(trimmedEmail.isEmpty == false, "CodexReviewAccount email must not be empty.")
        let normalizedEmail = CodexReviewAccount.normalizedEmail(trimmedEmail)
        let resolvedAccountKey = accountKey.map {
            CodexReviewAccount.normalizedEmail($0)
        } ?? normalizedEmail
        precondition(resolvedAccountKey.isEmpty == false, "CodexReviewAccount accountKey must not be empty.")
        self.id = resolvedAccountKey
        self.email = trimmedEmail
        self.maskedEmail = maskedReviewAccountEmail(trimmedEmail)
        self.kind = kind
        self.planType = planType
        self.capabilities = capabilities ?? kind.capabilities
    }
    package func apply(_ payload: CodexSavedAccountPayload) {
        self.updateEmail(payload.email)
        self.updateKind(payload.kind)
        self.updatePlanType(payload.planType)
        self.updateCapabilities(payload.capabilities)
        self.updateRateLimits(payload.rateLimits)
        self.updateRateLimitFetchMetadata(
            fetchedAt: payload.lastRateLimitFetchAt,
            error: payload.lastRateLimitError
        )
    }

    package func updateEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(trimmedEmail.isEmpty == false, "CodexReviewAccount email must not be empty.")
        self.email = trimmedEmail
        self.maskedEmail = maskedReviewAccountEmail(trimmedEmail)
    }

    package func updatePlanType(_ planType: String?) {
        self.planType = planType
    }

    package func updateKind(
        _ kind: CodexReviewBackendModel.Account.Kind,
        capabilities: CodexReviewBackendModel.Account.Capabilities? = nil
    ) {
        self.kind = kind
        self.capabilities = capabilities ?? kind.capabilities
        clearRateLimitStateIfUnsupported()
    }

    package func updateCapabilities(_ capabilities: CodexReviewBackendModel.Account.Capabilities) {
        self.capabilities = capabilities
        clearRateLimitStateIfUnsupported()
    }

    package func updateIsSwitching(_ isSwitching: Bool) {
        guard self.isSwitching != isSwitching else {
            return
        }
        self.isSwitching = isSwitching
    }

    package func updateRateLimits(
        _ rateLimits: [(windowDurationMinutes: Int, usedPercent: Int, resetsAt: Date?)]
    ) {
        guard capabilities.supportsRateLimitRefresh else {
            clearRateLimits()
            return
        }
        let validRateLimitsByDuration = rateLimits.reduce(
            into: [Int: (windowDurationMinutes: Int, usedPercent: Int, resetsAt: Date?)]()
        ) { result, rateLimit in
            guard rateLimit.windowDurationMinutes > 0 else {
                return
            }
            result[rateLimit.windowDurationMinutes] = rateLimit
        }
        let existingRateLimitsByDuration = self.rateLimits.reduce(into: [Int: CodexReviewAccount.RateLimitWindow]()) { result, window in
            result[window.windowDurationMinutes] = window
        }

        self.rateLimits = validRateLimitsByDuration.values
            .sorted { $0.windowDurationMinutes < $1.windowDurationMinutes }
            .map { rateLimit in
                if let existingRateLimit = existingRateLimitsByDuration[rateLimit.windowDurationMinutes] {
                    existingRateLimit.update(
                        usedPercent: rateLimit.usedPercent,
                        resetsAt: rateLimit.resetsAt
                    )
                    return existingRateLimit
                }

                return CodexReviewAccount.RateLimitWindow(
                    accountKey: accountKey,
                    windowDurationMinutes: rateLimit.windowDurationMinutes,
                    usedPercent: rateLimit.usedPercent,
                    resetsAt: rateLimit.resetsAt
                )
            }
    }

    package func updateRateLimitFetchMetadata(
        fetchedAt: Date?,
        error: String?
    ) {
        guard capabilities.supportsRateLimitRefresh else {
            lastRateLimitFetchAt = nil
            lastRateLimitError = nil
            return
        }
        lastRateLimitFetchAt = fetchedAt
        lastRateLimitError = error?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    package func markRateLimitReauthenticationRequired(
        fetchedAt: Date?,
        error: String
    ) {
        clearRateLimits()
        updateRateLimitFetchMetadata(
            fetchedAt: fetchedAt,
            error: Self.reauthenticationRequiredMessage(from: error)
        )
    }

    package static func requiresReauthentication(errorMessage: String) -> Bool {
        let normalizedMessage = errorMessage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedMessage.contains("token_expired")
            || normalizedMessage.contains("refresh_token_reused")
            || normalizedMessage.contains("refresh_token_expired")
            || normalizedMessage.contains("provided authentication token is expired")
            || normalizedMessage.contains("saved authentication is for")
            || normalizedMessage.contains("sign in again")
    }

    package func clearRateLimits() {
        rateLimits.removeAll()
    }

    private func clearRateLimitStateIfUnsupported() {
        guard capabilities.supportsRateLimitRefresh == false else {
            return
        }
        clearRateLimits()
        lastRateLimitFetchAt = nil
        lastRateLimitError = nil
    }
}

private extension CodexReviewAccount {
    static func reauthenticationRequiredMessage(from error: String) -> String {
        let trimmedError = error.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedError.isEmpty == false else {
            return "Authentication expired. Sign in again."
        }
        return "Authentication expired. Sign in again. \(trimmedError)"
    }
}

package struct CodexSavedAccountPayload: Sendable {
    package var accountKey: String
    package var email: String
    package var kind: CodexReviewBackendModel.Account.Kind
    package var planType: String?
    package var capabilities: CodexReviewBackendModel.Account.Capabilities
    package var rateLimits: [(windowDurationMinutes: Int, usedPercent: Int, resetsAt: Date?)]
    package var lastRateLimitFetchAt: Date?
    package var lastRateLimitError: String?

    package init(
        accountKey: String,
        email: String,
        kind: CodexReviewBackendModel.Account.Kind = .chatGPT,
        planType: String?,
        capabilities: CodexReviewBackendModel.Account.Capabilities = .supportsCodexRateLimits,
        rateLimits: [(windowDurationMinutes: Int, usedPercent: Int, resetsAt: Date?)],
        lastRateLimitFetchAt: Date?,
        lastRateLimitError: String?
    ) {
        self.accountKey = accountKey
        self.email = email
        self.kind = kind
        self.planType = planType
        self.capabilities = capabilities
        self.rateLimits = rateLimits
        self.lastRateLimitFetchAt = lastRateLimitFetchAt
        self.lastRateLimitError = lastRateLimitError
    }
}

@MainActor
package func makeCodexReviewAccount(from payload: CodexSavedAccountPayload) -> CodexReviewAccount {
    let account = CodexReviewAccount(
        accountKey: payload.accountKey,
        email: payload.email,
        planType: payload.planType,
        kind: payload.kind,
        capabilities: payload.capabilities
    )
    account.apply(payload)
    return account
}

@MainActor
package func savedAccountPayload(from account: CodexReviewAccount) -> CodexSavedAccountPayload {
    .init(
        accountKey: account.accountKey,
        email: account.email,
        kind: account.kind,
        planType: account.planType,
        capabilities: account.capabilities,
        rateLimits: account.rateLimits.map {
            (
                windowDurationMinutes: $0.windowDurationMinutes,
                usedPercent: $0.usedPercent,
                resetsAt: $0.resetsAt
            )
        },
        lastRateLimitFetchAt: account.lastRateLimitFetchAt,
        lastRateLimitError: account.lastRateLimitError
    )
}

private func maskedReviewAccountEmail(_ email: String) -> String {
    let parts = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2,
          parts[0].isEmpty == false,
          parts[1].isEmpty == false
    else {
        return maskedReviewAccountEmailSegment(email)
    }
    return "\(maskedReviewAccountEmailSegment(String(parts[0])))@\(parts[1])"
}

private func maskedReviewAccountEmailSegment(_ segment: String) -> String {
    let characters = Array(segment)
    switch characters.count {
    case 0:
        return segment
    case 1 ... 2:
        return String(characters.prefix(1)) + "…"
    case 3 ... 4:
        return String(characters.prefix(1)) + "…" + String(characters.suffix(1))
    default:
        return String(characters.prefix(2)) + "…" + String(characters.suffix(2))
    }
}

extension CodexReviewAccount {
    public static nonisolated func == (lhs: CodexReviewAccount, rhs: CodexReviewAccount) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
