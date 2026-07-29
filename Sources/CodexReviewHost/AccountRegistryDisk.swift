import CryptoKit
import Darwin
import Foundation
import OSLog
import CodexReviewKit

private let logger = Logger(subsystem: "CodexReviewKit", category: "live-store-backend")

extension AccountRegistryStore {
    enum Disk {
        private static let filesystemRootURL = URL(fileURLWithPath: "/", isDirectory: true)

        private struct Registry: Codable {
            static let currentSchemaVersion = 1

            var schemaVersion: Int
            var generation: UInt64
            var contentHash: String
            var activeAccountKey: String?
            var accounts: [Entry]

            enum CodingKeys: String, CodingKey {
                case schemaVersion
                case generation
                case contentHash
                case activeAccountKey
                case accounts
            }

            init(
                schemaVersion: Int = currentSchemaVersion,
                generation: UInt64 = 0,
                contentHash: String = "",
                activeAccountKey: String?,
                accounts: [Entry]
            ) {
                self.schemaVersion = schemaVersion
                self.generation = generation
                self.contentHash = contentHash
                self.activeAccountKey = activeAccountKey
                self.accounts = accounts
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
                generation = try container.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
                contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash) ?? ""
                activeAccountKey = try container.decodeIfPresent(String.self, forKey: .activeAccountKey)
                accounts = try container.decode([Entry].self, forKey: .accounts)
            }
        }

        private struct Entry: Codable {
            var accountKey: String?
            var immutableRevision: String?
            var kind: Kind
            var email: String
            var planType: String?
            var lastActivatedAt: Date?
            var lastRateLimitFetchAt: Date?
            var lastRateLimitError: String?
            var cachedRateLimits: [SavedRateLimitWindow]?

            enum CodingKeys: String, CodingKey {
                case accountKey
                case immutableRevision
                case kind
                case email
                case planType
                case lastActivatedAt
                case lastRateLimitFetchAt
                case lastRateLimitError
                case cachedRateLimits
            }

            init(
                accountKey: String?,
                immutableRevision: String? = nil,
                kind: Kind,
                email: String,
                planType: String?,
                lastActivatedAt: Date?,
                lastRateLimitFetchAt: Date?,
                lastRateLimitError: String?,
                cachedRateLimits: [SavedRateLimitWindow]?
            ) {
                self.accountKey = accountKey
                self.immutableRevision = immutableRevision
                self.kind = kind
                self.email = email
                self.planType = planType
                self.lastActivatedAt = lastActivatedAt
                self.lastRateLimitFetchAt = lastRateLimitFetchAt
                self.lastRateLimitError = lastRateLimitError
                self.cachedRateLimits = cachedRateLimits
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.accountKey = try container.decodeIfPresent(String.self, forKey: .accountKey)
                self.immutableRevision = try container.decodeIfPresent(String.self, forKey: .immutableRevision)
                self.email = try container.decode(String.self, forKey: .email)
                // Registries written before the kind field existed must keep
                // decoding; dropping them would empty the persisted account list.
                self.kind = try container.decodeIfPresent(Kind.self, forKey: .kind)
                    ?? Kind.legacyDefault(accountKey: accountKey, email: email)
                self.planType = try container.decodeIfPresent(String.self, forKey: .planType)
                self.lastActivatedAt = try container.decodeIfPresent(Date.self, forKey: .lastActivatedAt)
                self.lastRateLimitFetchAt = try container.decodeIfPresent(Date.self, forKey: .lastRateLimitFetchAt)
                self.lastRateLimitError = try container.decodeIfPresent(String.self, forKey: .lastRateLimitError)
                self.cachedRateLimits = try container.decodeIfPresent(
                    [SavedRateLimitWindow].self,
                    forKey: .cachedRateLimits
                )
            }
        }

        private enum Kind: String, Codable {
            case chatGPT = "chatgpt"
            case apiKey
            case amazonBedrock

            static func legacyDefault(accountKey: String?, email: String) -> Self {
                let normalizedAccountKey = accountKey
                    .map(CodexReviewAccount.normalizedEmail)
                    .flatMap { $0.isEmpty ? nil : $0 }
                switch normalizedAccountKey ?? CodexReviewAccount.normalizedEmail(email) {
                case "api-key":
                    return .apiKey
                case "amazon-bedrock":
                    return .amazonBedrock
                default:
                    return .chatGPT
                }
            }

            init(_ accountKind: CodexReviewBackendModel.Account.Kind) {
                switch accountKind {
                case .chatGPT:
                    self = .chatGPT
                case .apiKey:
                    self = .apiKey
                case .amazonBedrock:
                    self = .amazonBedrock
                }
            }

            var accountKind: CodexReviewBackendModel.Account.Kind {
                switch self {
                case .chatGPT:
                    .chatGPT
                case .apiKey:
                    .apiKey
                case .amazonBedrock:
                    .amazonBedrock
                }
            }

        }

        private struct SavedRateLimitWindow: Codable {
            var windowDurationMinutes: Int
            var usedPercent: Int
            var resetsAt: Date?

            var tuple: (windowDurationMinutes: Int, usedPercent: Int, resetsAt: Date?) {
                (windowDurationMinutes, usedPercent, resetsAt)
            }
        }

        private struct MutationJournal: Codable {
            enum Phase: String, Codable {
                case prepared
                case sharedAuthApplied
                case registryCommitted
            }

            enum SharedAuthAction: String, Codable {
                case replace
                case remove
            }

            var id: UUID
            var phase: Phase
            var beforeRegistry: Registry
            var desiredRegistry: Registry
            var beforeSharedAuthFingerprint: String?
            var desiredSharedAuthFingerprint: String?
            var sharedAuthAction: SharedAuthAction
            var replacementAccountKey: String?
            var replacementRevision: String?
            var mayApplyIrreversibleLogout: Bool
        }

        private struct ReconciliationDebt: Codable {
            enum Expectation: String, Codable {
                case signedOut
                case account
                case observedAccount
                case anyChatGPT
                case cancelOutcomeUnknown
                case reconcileCurrentRuntime
            }

            var expectation: Expectation
            var accountKey: String?
            var provider: ExpectedRuntimeAccount.Provider?
            var message: String
            var recordedAt: Date

            var expectedRuntimeAccount: ExpectedRuntimeAccount {
                switch expectation {
                case .signedOut:
                    return .signedOut
                case .account:
                    guard let accountKey else {
                        preconditionFailure("An account reconciliation debt requires its expected account key.")
                    }
                    return .account(accountKey)
                case .observedAccount:
                    guard let accountKey, let provider else {
                        preconditionFailure("An observed account reconciliation debt requires identity and provider.")
                    }
                    return .observedAccount(accountKey: accountKey, provider: provider)
                case .anyChatGPT:
                    return .anyChatGPT
                case .cancelOutcomeUnknown:
                    return .cancelOutcomeUnknown(previousActiveAccountKey: accountKey)
                case .reconcileCurrentRuntime:
                    return .reconcileCurrentRuntime
                }
            }
        }

        private struct TemporaryHomeCleanupDebt: Codable {
            var paths: [String]
        }

        static func reserveTemporaryCodexHome(
            kind: AccountRegistryStore.TemporaryCodexHomeKind,
            codexHomeURL: URL
        ) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(kind.pathPrefix)\(UUID().uuidString)", isDirectory: true)
                .standardizedFileURL
            try updateTemporaryHomeCleanupDebt(
                adding: url.path,
                codexHomeURL: codexHomeURL
            )
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            return url
        }

        static func finishTemporaryCodexHome(
            _ url: URL,
            codexHomeURL: URL,
            directoryDurabilityDidSynchronize: (@Sendable (URL) throws -> Void)? = nil
        ) throws {
            let standardizedURL = url.standardizedFileURL
            let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
            let permittedName = standardizedURL.lastPathComponent.hasPrefix("codex-review-auth-")
                || standardizedURL.lastPathComponent.hasPrefix("codex-review-rate-limits-")
            precondition(
                standardizedURL.deletingLastPathComponent() == temporaryDirectory && permittedName,
                "Only owned CodexReview temporary homes can enter cleanup debt."
            )
            do {
                try removeDurably(
                    at: standardizedURL,
                    directoryDurabilityDidSynchronize: directoryDurabilityDidSynchronize
                )
                try updateTemporaryHomeCleanupDebt(
                    removing: standardizedURL.path,
                    codexHomeURL: codexHomeURL
                )
            } catch {
                try updateTemporaryHomeCleanupDebt(
                    adding: standardizedURL.path,
                    codexHomeURL: codexHomeURL
                )
                logger.error(
                    "Credential-bearing temporary home cleanup remains pending: \(standardizedURL.path, privacy: .private(mask: .hash))"
                )
            }
        }

        private static func retryTemporaryHomeCleanup(codexHomeURL: URL) throws {
            let debtURL = temporaryHomeCleanupDebtURL(codexHomeURL: codexHomeURL)
            guard FileManager.default.fileExists(atPath: debtURL.path) else {
                return
            }
            let debt = try JSONDecoder().decode(
                TemporaryHomeCleanupDebt.self,
                from: Data(contentsOf: debtURL)
            )
            for path in debt.paths {
                let url = URL(fileURLWithPath: path, isDirectory: true)
                try finishTemporaryCodexHome(url, codexHomeURL: codexHomeURL)
            }
        }

        private static func updateTemporaryHomeCleanupDebt(
            adding path: String? = nil,
            removing removedPath: String? = nil,
            codexHomeURL: URL
        ) throws {
            let url = temporaryHomeCleanupDebtURL(codexHomeURL: codexHomeURL)
            var paths: Set<String> = []
            if FileManager.default.fileExists(atPath: url.path) {
                paths = Set(try JSONDecoder().decode(
                    TemporaryHomeCleanupDebt.self,
                    from: Data(contentsOf: url)
                ).paths)
            }
            if let path {
                paths.insert(path)
            }
            if let removedPath {
                paths.remove(removedPath)
            }
            if paths.isEmpty {
                try removeDurably(at: url)
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try writeAtomically(
                encoder.encode(TemporaryHomeCleanupDebt(paths: paths.sorted())),
                to: url,
                permissions: 0o600
            )
        }

        static func recordReconciliationDebt(
            expectedAccount: ExpectedRuntimeAccount,
            message: String,
            codexHomeURL: URL,
            directoryDurabilityDidSynchronize: (@Sendable (URL) throws -> Void)? = nil
        ) throws {
            let expectation: ReconciliationDebt.Expectation
            let accountKey: String?
            let provider: ExpectedRuntimeAccount.Provider?
            switch expectedAccount {
            case .signedOut:
                expectation = .signedOut
                accountKey = nil
                provider = nil
            case .account(let value):
                expectation = .account
                accountKey = CodexReviewAccount.normalizedEmail(value)
                provider = nil
            case .observedAccount(let value, let valueProvider):
                expectation = .observedAccount
                accountKey = CodexReviewAccount.normalizedEmail(value)
                provider = valueProvider
            case .anyChatGPT:
                expectation = .anyChatGPT
                accountKey = nil
                provider = nil
            case .cancelOutcomeUnknown(let previousActiveAccountKey):
                expectation = .cancelOutcomeUnknown
                accountKey = previousActiveAccountKey.map(CodexReviewAccount.normalizedEmail)
                provider = nil
            case .reconcileCurrentRuntime:
                expectation = .reconcileCurrentRuntime
                accountKey = nil
                provider = nil
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try writeAtomically(
                encoder.encode(ReconciliationDebt(
                    expectation: expectation,
                    accountKey: accountKey,
                    provider: provider,
                    message: message,
                    recordedAt: Date()
                )),
                to: reconciliationDebtURL(codexHomeURL: codexHomeURL),
                permissions: 0o600,
                directoryDurabilityDidSynchronize: directoryDurabilityDidSynchronize
            )
        }

        static func reconciliationDebtExpectation(
            codexHomeURL: URL
        ) throws -> ExpectedRuntimeAccount? {
            let url = reconciliationDebtURL(codexHomeURL: codexHomeURL)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            do {
                let debt = try JSONDecoder().decode(
                    ReconciliationDebt.self,
                    from: Data(contentsOf: url)
                )
                return debt.expectedRuntimeAccount
            } catch {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "The account reconciliation debt is inconsistent: \(error.localizedDescription)"
                )
            }
        }

        static func clearReconciliationDebt(codexHomeURL: URL) throws {
            let url = reconciliationDebtURL(codexHomeURL: codexHomeURL)
            try removeDurably(at: url)
        }

        static func load(codexHomeURL: URL) throws -> AccountRegistryStore.Snapshot {
            try retryTemporaryHomeCleanup(codexHomeURL: codexHomeURL)
            let registry = try loadRegistry(codexHomeURL: codexHomeURL)
            do {
                try garbageCollectOrphanedRevisions(
                    referencedBy: registry,
                    codexHomeURL: codexHomeURL
                )
            } catch {
                logger.error(
                    "Account registry cleanup remains pending and will retry on the next load: \(error.localizedDescription, privacy: .public)"
                )
            }
            return snapshot(from: registry)
        }

        static func loadSnapshotWithoutMaintenance(
            codexHomeURL: URL
        ) throws -> AccountRegistryStore.Snapshot {
            snapshot(from: try loadRegistry(codexHomeURL: codexHomeURL))
        }

        private static func snapshot(
            from registry: Registry
        ) -> AccountRegistryStore.Snapshot {
            let accounts = registry.accounts.compactMap(makePayload(from:))
            let activeAccountKey = registry.activeAccountKey
                .map(CodexReviewAccount.normalizedEmail)
                .flatMap { activeAccountKey in
                    accounts.contains(where: { $0.accountKey == activeAccountKey }) ? activeAccountKey : nil
                }
            logger.info("Loaded \(accounts.count, privacy: .public) persisted Codex review account(s)")
            return .init(accounts: accounts, activeAccountKey: activeAccountKey)
        }

        static func deactivateAccount(
            codexHomeURL: URL,
            destinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil
        ) throws {
            var registry = try loadRegistry(codexHomeURL: codexHomeURL)
            guard registry.activeAccountKey != nil else {
                return
            }
            registry.activeAccountKey = nil
            try saveRegistry(
                registry,
                codexHomeURL: codexHomeURL,
                destinationDidReplace: destinationDidReplace
            )
        }

        private static func mergedEntries(
            _ accounts: [CodexSavedAccountPayload],
            activeAccountKey: String?,
            existing: [Entry]
        ) -> [Entry] {
            let existingByAccountKey = Dictionary(uniqueKeysWithValues: existing.compactMap { entry in
                normalizedAccountKey(from: entry).map { ($0, entry) }
            })
            return accounts.map { account in
                var entry = existingByAccountKey[account.accountKey] ?? Entry(
                    accountKey: account.accountKey,
                    kind: .init(account.kind),
                    email: account.email,
                    planType: account.planType,
                    lastActivatedAt: nil,
                    lastRateLimitFetchAt: nil,
                    lastRateLimitError: nil,
                    cachedRateLimits: nil
                )
                entry.accountKey = account.accountKey
                entry.kind = .init(account.kind)
                entry.email = account.email
                entry.planType = account.planType
                entry.cachedRateLimits = account.rateLimits.map { window in
                    .init(
                        windowDurationMinutes: window.windowDurationMinutes,
                        usedPercent: window.usedPercent,
                        resetsAt: window.resetsAt
                    )
                }
                entry.lastRateLimitFetchAt = account.lastRateLimitFetchAt
                entry.lastRateLimitError = account.lastRateLimitError
                if account.accountKey == activeAccountKey {
                    entry.lastActivatedAt = Date()
                }
                return entry
            }
        }

        static func prepareAccountActivation(
            _ accountKey: String,
            codexHomeURL: URL
        ) throws -> AccountRegistryStore.PreparedMutation {
            let targetAccountKey = CodexReviewAccount.normalizedEmail(accountKey)
            let beforeRegistry = try loadRegistry(codexHomeURL: codexHomeURL)
            guard let entry = beforeRegistry.accounts.first(where: {
                normalizedAccountKey(from: $0) == targetAccountKey
            }), let revision = entry.immutableRevision,
                  let savedAuthURL = immutableAuthURL(
                    for: entry,
                    accountKey: targetAccountKey,
                    codexHomeURL: codexHomeURL
            ) else {
                throw CodexReviewAPI.Error.io("Saved authentication is missing for account \(targetAccountKey).")
            }
            let desiredAuthData = try validatedAuthData(at: savedAuthURL)
            var desiredRegistry = beforeRegistry
            desiredRegistry.activeAccountKey = targetAccountKey
            if let index = desiredRegistry.accounts.firstIndex(where: {
                normalizedAccountKey(from: $0) == targetAccountKey
            }) {
                desiredRegistry.accounts[index].lastActivatedAt = Date()
            }
            desiredRegistry = try nextRegistry(from: desiredRegistry)
            let id = UUID()
            let journal = MutationJournal(
                id: id,
                phase: .prepared,
                beforeRegistry: beforeRegistry,
                desiredRegistry: desiredRegistry,
                beforeSharedAuthFingerprint: try sharedAuthFingerprint(codexHomeURL: codexHomeURL),
                desiredSharedAuthFingerprint: fingerprint(desiredAuthData),
                sharedAuthAction: .replace,
                replacementAccountKey: targetAccountKey,
                replacementRevision: revision,
                mayApplyIrreversibleLogout: false
            )
            try writeJournal(journal, codexHomeURL: codexHomeURL)
            return .init(id: id)
        }

        static func prepareIrreversibleRemoval(
            accountKey: String,
            codexHomeURL: URL
        ) throws -> AccountRegistryStore.PreparedMutation {
            let beforeRegistry = try loadRegistry(codexHomeURL: codexHomeURL)
            let normalizedAccountKey = CodexReviewAccount.normalizedEmail(accountKey)
            guard beforeRegistry.accounts.contains(where: {
                self.normalizedAccountKey(from: $0) == normalizedAccountKey
            }) else {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "Cannot prepare removal for missing account \(normalizedAccountKey)."
                )
            }
            var desiredRegistry = beforeRegistry
            desiredRegistry.accounts.removeAll {
                self.normalizedAccountKey(from: $0) == normalizedAccountKey
            }
            if desiredRegistry.activeAccountKey.map(CodexReviewAccount.normalizedEmail) == normalizedAccountKey {
                desiredRegistry.activeAccountKey = nil
            }
            desiredRegistry = try nextRegistry(from: desiredRegistry)
            let id = UUID()
            try writeJournal(
                .init(
                    id: id,
                    phase: .prepared,
                    beforeRegistry: beforeRegistry,
                    desiredRegistry: desiredRegistry,
                    beforeSharedAuthFingerprint: try sharedAuthFingerprint(codexHomeURL: codexHomeURL),
                    desiredSharedAuthFingerprint: nil,
                    sharedAuthAction: .remove,
                    replacementAccountKey: nil,
                    replacementRevision: nil,
                    mayApplyIrreversibleLogout: true
                ),
                codexHomeURL: codexHomeURL
            )
            return .init(id: id)
        }

        static func commitPreparedMutation(
            _ mutation: AccountRegistryStore.PreparedMutation,
            codexHomeURL: URL
        ) throws {
            var journal = try loadJournal(codexHomeURL: codexHomeURL)
            guard journal.id == mutation.id else {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "The prepared account mutation token does not match the durable journal."
                )
            }
            do {
                try forwardPreparedJournal(&journal, codexHomeURL: codexHomeURL)
            } catch {
                let originalError = error
                do {
                    let durableJournalURL = journalURL(codexHomeURL: codexHomeURL)
                    if FileManager.default.fileExists(atPath: durableJournalURL.path) {
                        journal = try loadJournal(codexHomeURL: codexHomeURL)
                        guard journal.id == mutation.id else {
                            throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                                message: "The recovered account mutation token no longer matches its durable journal."
                            )
                        }
                        try forwardPreparedJournal(&journal, codexHomeURL: codexHomeURL)
                    } else {
                        let registry = try loadRegistryWithoutRecovery(codexHomeURL: codexHomeURL)
                        guard sameRegistry(registry, journal.desiredRegistry) else {
                            throw originalError
                        }
                    }
                } catch {
                    throw CodexReviewAuthenticationFailure.accountCommit(
                        message: "The prepared account mutation could not forward-complete. "
                            + "Original failure: \(originalError.localizedDescription). "
                            + "Recovery failure: \(error.localizedDescription)"
                    )
                }
            }
        }

        private static func forwardPreparedJournal(
            _ journal: inout MutationJournal,
            codexHomeURL: URL
        ) throws {
            try applySharedAuthAction(journal, codexHomeURL: codexHomeURL)
            journal.phase = .sharedAuthApplied
            try writeJournal(journal, codexHomeURL: codexHomeURL)
            try persistRegistry(journal.desiredRegistry, codexHomeURL: codexHomeURL)
            journal.phase = .registryCommitted
            try writeJournal(journal, codexHomeURL: codexHomeURL)
            try removeJournal(codexHomeURL: codexHomeURL)
        }

        static func abortPreparedMutation(
            _ mutation: AccountRegistryStore.PreparedMutation,
            codexHomeURL: URL
        ) throws -> AccountRegistryStore.PreparedAbortDisposition {
            let journal = try loadJournal(codexHomeURL: codexHomeURL)
            guard journal.id == mutation.id else {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "The aborted account mutation token does not match the durable journal."
                )
            }
            let registry = try loadRegistryWithoutRecovery(codexHomeURL: codexHomeURL)
            let sharedFingerprint = try sharedAuthFingerprint(codexHomeURL: codexHomeURL)
            if sameRegistry(registry, journal.beforeRegistry),
               sharedFingerprint == journal.beforeSharedAuthFingerprint {
                try removeJournal(codexHomeURL: codexHomeURL)
                return .restoredBefore(snapshot(from: journal.beforeRegistry))
            }
            try recoverJournal(journal, codexHomeURL: codexHomeURL)
            let recovered = try loadRegistryWithoutRecovery(codexHomeURL: codexHomeURL)
            if sameRegistry(recovered, journal.beforeRegistry) {
                return .restoredBefore(snapshot(from: recovered))
            }
            if sameRegistry(recovered, journal.desiredRegistry) {
                return .forwardedDesired(snapshot(from: recovered))
            }
            throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                message: "The aborted account mutation resolved to neither its before nor desired registry."
            )
        }

        static func updateCachedRateLimits(
            from account: CodexSavedAccountPayload,
            codexHomeURL: URL,
            destinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil
        ) throws {
            var registry = try loadRegistry(codexHomeURL: codexHomeURL)
            guard let index = registry.accounts.firstIndex(where: {
                normalizedAccountKey(from: $0) == account.accountKey
            }) else {
                return
            }
            registry.accounts[index].planType = account.planType
            registry.accounts[index].cachedRateLimits = account.rateLimits.map { window in
                .init(
                    windowDurationMinutes: window.windowDurationMinutes,
                    usedPercent: window.usedPercent,
                    resetsAt: window.resetsAt
                )
            }
            registry.accounts[index].lastRateLimitFetchAt = account.lastRateLimitFetchAt
            registry.accounts[index].lastRateLimitError = account.lastRateLimitError
            try saveRegistry(
                registry,
                codexHomeURL: codexHomeURL,
                destinationDidReplace: destinationDidReplace
            )
        }

        static func saveSharedAuth(
            for account: CodexSavedAccountPayload,
            codexHomeURL: URL
        ) throws {
            try saveSharedAuth(
                from: codexHomeURL,
                for: account,
                codexHomeURL: codexHomeURL
            )
        }

        static func commitAuthenticatedAccount(
            _ authenticatedAccount: CodexSavedAccountPayload,
            activation: LoginActivation,
            authSourceCodexHomeURL: URL,
            codexHomeURL: URL,
            destinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil
        ) throws {
            let sourceData = try validatedAuthData(
                at: sharedAuthURL(codexHomeURL: authSourceCodexHomeURL)
            )
            let existing = try loadRegistry(codexHomeURL: codexHomeURL)
            let existingEntry = existing.accounts.first(where: {
                normalizedAccountKey(from: $0) == authenticatedAccount.accountKey
            })
            let sourceFingerprint = fingerprint(sourceData)
            let revision: String
            if let existingURL = existingEntry.flatMap({ entry in
                immutableAuthURL(
                    for: entry,
                    accountKey: authenticatedAccount.accountKey,
                    codexHomeURL: codexHomeURL
                )
            }), FileManager.default.fileExists(atPath: existingURL.path),
               fingerprint(try validatedAuthData(at: existingURL)) == sourceFingerprint,
               let immutableRevision = existingEntry?.immutableRevision {
                revision = immutableRevision
            } else {
                revision = try writeImmutableRevision(
                    sourceData,
                    accountKey: authenticatedAccount.accountKey,
                    codexHomeURL: codexHomeURL
                )
            }
            var authenticatedAccount = authenticatedAccount
            if let existingPayload = existingEntry.flatMap(makePayload(from:)) {
                authenticatedAccount.rateLimits = existingPayload.rateLimits
                authenticatedAccount.lastRateLimitFetchAt = existingPayload.lastRateLimitFetchAt
                authenticatedAccount.lastRateLimitError = existingPayload.lastRateLimitError
            }
            var accounts = existing.accounts.compactMap(makePayload(from:))
            if let index = accounts.firstIndex(where: { $0.accountKey == authenticatedAccount.accountKey }) {
                accounts[index] = authenticatedAccount
            } else {
                accounts.insert(authenticatedAccount, at: 0)
            }
            let normalizedActiveAccountKey: String? = switch activation {
            case .activateAuthenticatedAccount:
                authenticatedAccount.accountKey
            case .preserveActiveAccount:
                existing.activeAccountKey
            }
            var desired = existing
            desired.activeAccountKey = normalizedActiveAccountKey
            desired.accounts = mergedEntries(
                accounts,
                activeAccountKey: normalizedActiveAccountKey,
                existing: existing.accounts
            )
            guard let authenticatedIndex = desired.accounts.firstIndex(where: {
                normalizedAccountKey(from: $0) == authenticatedAccount.accountKey
            }) else {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "Authenticated account \(authenticatedAccount.accountKey) is missing from its commit payload."
                )
            }
            desired.accounts[authenticatedIndex].immutableRevision = revision
            let persistedDesired = try nextRegistry(from: desired)
            try persistRegistry(
                persistedDesired,
                codexHomeURL: codexHomeURL,
                destinationDidReplace: destinationDidReplace
            )
        }

        static func upsertAccount(
            _ account: CodexSavedAccountPayload,
            activation: LoginActivation,
            codexHomeURL: URL,
            destinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil
        ) throws {
            let existing = try loadRegistry(codexHomeURL: codexHomeURL)
            var account = account
            if let existingEntry = existing.accounts.first(where: {
                normalizedAccountKey(from: $0) == account.accountKey
            }), let existingPayload = makePayload(from: existingEntry) {
                account.rateLimits = existingPayload.rateLimits
                account.lastRateLimitFetchAt = existingPayload.lastRateLimitFetchAt
                account.lastRateLimitError = existingPayload.lastRateLimitError
            }
            var accounts = existing.accounts.compactMap(makePayload(from:))
            if let index = accounts.firstIndex(where: { $0.accountKey == account.accountKey }) {
                accounts[index] = account
            } else {
                accounts.insert(account, at: 0)
            }
            let activeAccountKey: String? = switch activation {
            case .activateAuthenticatedAccount:
                account.accountKey
            case .preserveActiveAccount:
                existing.activeAccountKey
            }
            try saveRegistry(
                .init(
                    schemaVersion: existing.schemaVersion,
                    generation: existing.generation,
                    contentHash: existing.contentHash,
                    activeAccountKey: activeAccountKey,
                    accounts: mergedEntries(
                        accounts,
                        activeAccountKey: activeAccountKey,
                        existing: existing.accounts
                    )
                ),
                codexHomeURL: codexHomeURL,
                destinationDidReplace: destinationDidReplace
            )
        }

        static func removeInactiveAccount(
            accountKey: String,
            codexHomeURL: URL,
            destinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil
        ) throws {
            let normalizedAccountKey = CodexReviewAccount.normalizedEmail(accountKey)
            let existing = try loadRegistry(codexHomeURL: codexHomeURL)
            precondition(
                existing.activeAccountKey.map(CodexReviewAccount.normalizedEmail) != normalizedAccountKey,
                "An active account removal requires the irreversible mutation journal."
            )
            var desired = existing
            desired.accounts.removeAll {
                self.normalizedAccountKey(from: $0) == normalizedAccountKey
            }
            try saveRegistry(
                desired,
                codexHomeURL: codexHomeURL,
                destinationDidReplace: destinationDidReplace
            )
        }

        static func reorderAccount(
            accountKey: String,
            toIndex: Int,
            codexHomeURL: URL,
            destinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil
        ) throws {
            let normalizedAccountKey = CodexReviewAccount.normalizedEmail(accountKey)
            var registry = try loadRegistry(codexHomeURL: codexHomeURL)
            guard let sourceIndex = registry.accounts.firstIndex(where: {
                self.normalizedAccountKey(from: $0) == normalizedAccountKey
            }), registry.accounts.count > 1 else {
                return
            }
            let destinationIndex = max(0, min(toIndex, registry.accounts.count - 1))
            guard sourceIndex != destinationIndex else {
                return
            }
            let entry = registry.accounts.remove(at: sourceIndex)
            registry.accounts.insert(entry, at: destinationIndex)
            try saveRegistry(
                registry,
                codexHomeURL: codexHomeURL,
                destinationDidReplace: destinationDidReplace
            )
        }

        static func saveSharedAuth(
            from sourceCodexHomeURL: URL,
            for account: CodexSavedAccountPayload,
            codexHomeURL: URL,
            destinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil
        ) throws {
            let sourceURL = sharedAuthURL(codexHomeURL: sourceCodexHomeURL)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                return
            }
            let sourceData = try validatedAuthData(at: sourceURL)
            let previousRegistry = try loadRegistry(codexHomeURL: codexHomeURL)
            var desiredRegistry = previousRegistry
            guard let index = desiredRegistry.accounts.firstIndex(where: {
                normalizedAccountKey(from: $0) == account.accountKey
            }) else {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "Cannot attach authentication revision to missing account \(account.accountKey)."
                )
            }
            if let existingURL = immutableAuthURL(
                for: desiredRegistry.accounts[index],
                accountKey: account.accountKey,
                codexHomeURL: codexHomeURL
            ), FileManager.default.fileExists(atPath: existingURL.path) {
                let existingData = try validatedAuthData(at: existingURL)
                if fingerprint(existingData) == fingerprint(sourceData) {
                    return
                }
            }
            let revision = try writeImmutableRevision(
                sourceData,
                accountKey: account.accountKey,
                codexHomeURL: codexHomeURL
            )
            desiredRegistry.accounts[index].immutableRevision = revision
            let persistedDesired = try nextRegistry(from: desiredRegistry)
            try persistRegistry(
                persistedDesired,
                codexHomeURL: codexHomeURL,
                destinationDidReplace: destinationDidReplace
            )
        }

        static func removeSharedAuth(codexHomeURL: URL) throws {
            let url = sharedAuthURL(codexHomeURL: codexHomeURL)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return
            }
            try FileManager.default.removeItem(at: url)
        }

        static func removeSavedAccountDirectory(
            accountKey: String,
            codexHomeURL: URL
        ) throws {
            let directoryURL = savedAccountDirectoryURL(accountKey: accountKey, codexHomeURL: codexHomeURL)
            guard FileManager.default.fileExists(atPath: directoryURL.path) else {
                return
            }
            try FileManager.default.removeItem(at: directoryURL)
        }

        static func copySavedAuth(
            accountKey: String,
            from sourceCodexHomeURL: URL,
            to destinationCodexHomeURL: URL
        ) throws -> Bool {
            let targetAccountKey = CodexReviewAccount.normalizedEmail(accountKey)
            let registry = try loadRegistry(codexHomeURL: sourceCodexHomeURL)
            guard let entry = registry.accounts.first(where: {
                normalizedAccountKey(from: $0) == targetAccountKey
            }), let sourceURL = immutableAuthURL(
                for: entry,
                accountKey: targetAccountKey,
                codexHomeURL: sourceCodexHomeURL
            ) else {
                return false
            }
            _ = try validatedAuthData(at: sourceURL)
            try copyAuth(
                from: sourceURL,
                to: sharedAuthURL(codexHomeURL: destinationCodexHomeURL)
            )
            return true
        }

        private static func makePayload(from entry: Entry) -> CodexSavedAccountPayload? {
            let email = entry.email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard email.isEmpty == false else {
                return nil
            }
            let normalizedEmail = CodexReviewAccount.normalizedEmail(email)
            let accountKey = entry.accountKey
                .map(CodexReviewAccount.normalizedEmail)
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? normalizedEmail
            return CodexSavedAccountPayload(
                accountKey: accountKey,
                email: email,
                kind: entry.kind.accountKind,
                planType: entry.planType,
                capabilities: entry.kind.accountKind.capabilities,
                rateLimits: entry.cachedRateLimits?.map(\.tuple) ?? [],
                lastRateLimitFetchAt: entry.lastRateLimitFetchAt,
                lastRateLimitError: entry.lastRateLimitError
            )
        }

        private static func loadRegistry(codexHomeURL: URL) throws -> Registry {
            if FileManager.default.fileExists(atPath: journalURL(codexHomeURL: codexHomeURL).path) {
                let journal = try loadJournal(codexHomeURL: codexHomeURL)
                try recoverJournal(journal, codexHomeURL: codexHomeURL)
            }
            return try loadRegistryWithoutRecovery(codexHomeURL: codexHomeURL)
        }

        private static func loadRegistryWithoutRecovery(codexHomeURL: URL) throws -> Registry {
            let url = registryURL(codexHomeURL: codexHomeURL)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .init(activeAccountKey: nil, accounts: [])
            }
            do {
                let data = try Data(contentsOf: url)
                var registry = try JSONDecoder().decode(Registry.self, from: data)
                guard registry.schemaVersion == 0 || registry.schemaVersion == Registry.currentSchemaVersion else {
                    throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                        message: "Unsupported account registry schema version \(registry.schemaVersion)."
                    )
                }
                if registry.schemaVersion == Registry.currentSchemaVersion {
                    let expectedHash = try contentHash(for: registry)
                    guard registry.contentHash == expectedHash else {
                        throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                            message: "The account registry content hash does not match its persisted content."
                        )
                    }
                } else {
                    registry = try migrateLegacyRegistry(registry, codexHomeURL: codexHomeURL)
                    try saveRegistry(registry, codexHomeURL: codexHomeURL)
                    registry = try JSONDecoder().decode(
                        Registry.self,
                        from: Data(contentsOf: url)
                    )
                }
                try validateReferencedAuthRevisions(registry, codexHomeURL: codexHomeURL)
                return registry
            } catch let failure as CodexReviewAuthenticationFailure {
                throw failure
            } catch {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "The account registry is inconsistent: \(error.localizedDescription)"
                )
            }
        }

        private static func saveRegistry(
            _ registry: Registry,
            codexHomeURL: URL,
            destinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil
        ) throws {
            try persistRegistry(
                nextRegistry(from: registry),
                codexHomeURL: codexHomeURL,
                destinationDidReplace: destinationDidReplace
            )
        }

        private static func nextRegistry(from registry: Registry) throws -> Registry {
            var registry = registry
            registry.schemaVersion = Registry.currentSchemaVersion
            registry.generation = registry.generation &+ 1
            registry.contentHash = try contentHash(for: registry)
            return registry
        }

        private static func persistRegistry(
            _ registry: Registry,
            codexHomeURL: URL,
            destinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil
        ) throws {
            let url = registryURL(codexHomeURL: codexHomeURL)
            guard registry.schemaVersion == Registry.currentSchemaVersion,
                  registry.contentHash == (try contentHash(for: registry)) else {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "Refusing to persist an account registry with an invalid content hash."
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(registry)
            do {
                try writeAtomically(
                    data,
                    to: url,
                    permissions: 0o600,
                    destinationDidReplace: destinationDidReplace
                )
            } catch let persistenceError {
                let observed: Registry
                do {
                    observed = try loadRegistryWithoutRecovery(codexHomeURL: codexHomeURL)
                } catch {
                    throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                        message: "The account registry replacement outcome is unresolved. "
                            + "Write failure: \(persistenceError.localizedDescription). "
                            + "Reload failure: \(error.localizedDescription)"
                    )
                }
                guard sameRegistry(observed, registry) else {
                    throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                        message: "The account registry replacement did not expose its desired durable state: "
                            + persistenceError.localizedDescription
                    )
                }
                do {
                    try synchronizeFile(at: url)
                    try synchronizeDirectory(at: url.deletingLastPathComponent())
                } catch {
                    throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                        message: "The desired account registry is visible but its durability remains unresolved: "
                            + error.localizedDescription
                    )
                }
            }
        }

        private static func migrateLegacyRegistry(
            _ legacy: Registry,
            codexHomeURL: URL
        ) throws -> Registry {
            var migrated = legacy
            migrated.schemaVersion = Registry.currentSchemaVersion
            migrated.contentHash = ""
            for index in migrated.accounts.indices {
                guard migrated.accounts[index].immutableRevision == nil,
                      let accountKey = normalizedAccountKey(from: migrated.accounts[index])
                else {
                    continue
                }
                let legacyURL = savedAccountAuthURL(
                    accountKey: accountKey,
                    codexHomeURL: codexHomeURL
                )
                guard FileManager.default.fileExists(atPath: legacyURL.path) else {
                    continue
                }
                let data = try validatedAuthData(at: legacyURL)
                migrated.accounts[index].immutableRevision = try writeImmutableRevision(
                    data,
                    accountKey: accountKey,
                    codexHomeURL: codexHomeURL,
                    preferredRevision: "legacy-0-\(fingerprint(data).prefix(16))"
                )
            }
            return migrated
        }

        private static func validateReferencedAuthRevisions(
            _ registry: Registry,
            codexHomeURL: URL
        ) throws {
            for entry in registry.accounts {
                guard entry.immutableRevision != nil else {
                    continue
                }
                guard let accountKey = normalizedAccountKey(from: entry),
                      let revisionURL = immutableAuthURL(
                        for: entry,
                        accountKey: accountKey,
                        codexHomeURL: codexHomeURL
                      ) else {
                    throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                        message: "An account registry revision has no valid account identity."
                    )
                }
                _ = try validatedAuthData(at: revisionURL)
            }
        }

        private static func garbageCollectOrphanedRevisions(
            referencedBy registry: Registry,
            codexHomeURL: URL
        ) throws {
            let referencedPaths = Set(registry.accounts.compactMap { entry -> String? in
                guard let accountKey = normalizedAccountKey(from: entry),
                      let url = immutableAuthURL(
                        for: entry,
                        accountKey: accountKey,
                        codexHomeURL: codexHomeURL
                      ) else {
                    return nil
                }
                return url.standardizedFileURL.path
            })
            let accountsURL = accountsDirectoryURL(codexHomeURL: codexHomeURL)
            guard FileManager.default.fileExists(atPath: accountsURL.path) else {
                return
            }
            let accountDirectories = try FileManager.default.contentsOfDirectory(
                at: accountsURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            for accountDirectory in accountDirectories {
                let accountValues = try accountDirectory.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard accountValues.isDirectory == true, accountValues.isSymbolicLink != true else {
                    continue
                }
                let revisionsURL = accountDirectory.appendingPathComponent("revisions", isDirectory: true)
                guard FileManager.default.fileExists(atPath: revisionsURL.path) else {
                    continue
                }
                let revisionValues = try revisionsURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard revisionValues.isDirectory == true, revisionValues.isSymbolicLink != true else {
                    throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                        message: "An authentication revisions path is not a regular directory."
                    )
                }
                let revisions = try FileManager.default.contentsOfDirectory(
                    at: revisionsURL,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
                var removedRevision = false
                for revisionURL in revisions where revisionURL.pathExtension == "json" {
                    let values = try revisionURL.resourceValues(
                        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                    )
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                            message: "An immutable authentication revision is not a regular file."
                        )
                    }
                    guard referencedPaths.contains(revisionURL.standardizedFileURL.path) == false else {
                        continue
                    }
                    try FileManager.default.removeItem(at: revisionURL)
                    removedRevision = true
                }
                if removedRevision {
                    try synchronizeDirectory(at: revisionsURL)
                }
                let remainingRevisionURLs = try FileManager.default.contentsOfDirectory(
                    at: revisionsURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ).filter { $0.pathExtension == "json" }
                let accountDirectoryPrefix = accountDirectory.standardizedFileURL.path + "/"
                let isReferencedAccountDirectory = referencedPaths.contains {
                    $0.hasPrefix(accountDirectoryPrefix)
                }
                if remainingRevisionURLs.isEmpty, isReferencedAccountDirectory == false {
                    try FileManager.default.removeItem(at: accountDirectory)
                    try synchronizeDirectory(at: accountsURL)
                }
            }
        }

        private struct RegistryContent: Encodable {
            let schemaVersion: Int
            let generation: UInt64
            let activeAccountKey: String?
            let accounts: [Entry]
        }

        private static func contentHash(for registry: Registry) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(RegistryContent(
                schemaVersion: Registry.currentSchemaVersion,
                generation: registry.generation,
                activeAccountKey: registry.activeAccountKey,
                accounts: registry.accounts
            ))
            return fingerprint(data)
        }

        private static func writeJournal(
            _ journal: MutationJournal,
            codexHomeURL: URL
        ) throws {
            guard journal.beforeRegistry.contentHash == (try contentHash(for: journal.beforeRegistry)),
                  journal.desiredRegistry.contentHash == (try contentHash(for: journal.desiredRegistry)) else {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "Refusing to persist an account mutation journal with invalid registry hashes."
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try writeAtomically(
                encoder.encode(journal),
                to: journalURL(codexHomeURL: codexHomeURL),
                permissions: 0o600
            )
        }

        private static func loadJournal(codexHomeURL: URL) throws -> MutationJournal {
            do {
                return try JSONDecoder().decode(
                    MutationJournal.self,
                    from: Data(contentsOf: journalURL(codexHomeURL: codexHomeURL))
                )
            } catch {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "The account mutation journal is inconsistent: \(error.localizedDescription)"
                )
            }
        }

        private static func removeJournal(codexHomeURL: URL) throws {
            let url = journalURL(codexHomeURL: codexHomeURL)
            try removeDurably(at: url)
        }

        private static func recoverJournal(
            _ journal: MutationJournal,
            codexHomeURL: URL
        ) throws {
            guard journal.beforeRegistry.contentHash == (try contentHash(for: journal.beforeRegistry)),
                  journal.desiredRegistry.contentHash == (try contentHash(for: journal.desiredRegistry)) else {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "The account mutation journal contains invalid registry hashes."
                )
            }
            let currentRegistry = try loadRegistryWithoutRecovery(codexHomeURL: codexHomeURL)
            let currentSharedFingerprint = try sharedAuthFingerprint(codexHomeURL: codexHomeURL)
            let registryIsBefore = sameRegistry(currentRegistry, journal.beforeRegistry)
            let registryIsDesired = sameRegistry(currentRegistry, journal.desiredRegistry)
            guard registryIsBefore || registryIsDesired else {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "The account registry matches neither side of its durable mutation journal."
                )
            }
            let sharedIsBefore = currentSharedFingerprint == journal.beforeSharedAuthFingerprint
            let sharedIsDesired = currentSharedFingerprint == journal.desiredSharedAuthFingerprint
            guard sharedIsBefore || sharedIsDesired else {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "Shared authentication matches neither side of its durable mutation journal."
                )
            }
            let irreversibleEffectMayHaveApplied = journal.mayApplyIrreversibleLogout
                && (currentSharedFingerprint == nil || sharedIsBefore == false)
            let shouldForward = registryIsDesired || sharedIsDesired || irreversibleEffectMayHaveApplied
            guard shouldForward else {
                try removeJournal(codexHomeURL: codexHomeURL)
                return
            }
            if sharedIsDesired == false {
                try applySharedAuthAction(journal, codexHomeURL: codexHomeURL)
            }
            if registryIsDesired == false {
                try persistRegistry(journal.desiredRegistry, codexHomeURL: codexHomeURL)
            }
            try removeJournal(codexHomeURL: codexHomeURL)
        }

        private static func applySharedAuthAction(
            _ journal: MutationJournal,
            codexHomeURL: URL
        ) throws {
            switch journal.sharedAuthAction {
            case .remove:
                try removeSharedAuth(codexHomeURL: codexHomeURL)
                try synchronizeDirectory(at: codexHomeURL)
            case .replace:
                guard let accountKey = journal.replacementAccountKey,
                      let revision = journal.replacementRevision else {
                    throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                        message: "A replacement journal is missing its immutable revision reference."
                    )
                }
                try copyAuth(
                    from: immutableAuthURL(
                        accountKey: accountKey,
                        revision: revision,
                        codexHomeURL: codexHomeURL
                    ),
                    to: sharedAuthURL(codexHomeURL: codexHomeURL)
                )
            }
            let actualFingerprint = try sharedAuthFingerprint(codexHomeURL: codexHomeURL)
            guard actualFingerprint == journal.desiredSharedAuthFingerprint else {
                throw CodexReviewAuthenticationFailure.accountCommit(
                    message: "Shared authentication did not reach the journaled desired fingerprint."
                )
            }
        }

        private static func sharedAuthFingerprint(codexHomeURL: URL) throws -> String? {
            let url = sharedAuthURL(codexHomeURL: codexHomeURL)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            return fingerprint(try validatedAuthData(at: url))
        }

        private static func sameRegistry(_ lhs: Registry, _ rhs: Registry) -> Bool {
            lhs.generation == rhs.generation && lhs.contentHash == rhs.contentHash
        }

        private static func copyAuth(from sourceURL: URL, to destinationURL: URL) throws {
            let sourceData = try validatedAuthData(at: sourceURL)
            try writeAtomically(
                sourceData,
                to: destinationURL,
                permissions: 0o600
            )
            let destinationData = try validatedAuthData(at: destinationURL)
            guard fingerprint(destinationData) == fingerprint(sourceData) else {
                throw CodexReviewAuthenticationFailure.accountCommit(
                    message: "Authentication copy fingerprint mismatch."
                )
            }
        }

        private static func writeImmutableRevision(
            _ data: Data,
            accountKey: String,
            codexHomeURL: URL,
            preferredRevision: String? = nil
        ) throws -> String {
            _ = try validatedAuthObject(data)
            let revision = preferredRevision ?? UUID().uuidString.lowercased()
            let url = immutableAuthURL(
                accountKey: accountKey,
                revision: revision,
                codexHomeURL: codexHomeURL
            )
            let directoryURL = url.deletingLastPathComponent()
            try createDirectoryHierarchy(
                at: directoryURL
            )
            if FileManager.default.fileExists(atPath: url.path) {
                let existing = try validatedAuthData(at: url)
                guard fingerprint(existing) == fingerprint(data) else {
                    throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                        message: "Immutable authentication revision \(revision) has conflicting content."
                    )
                }
                try synchronizeFile(at: url)
                try synchronizeDirectory(at: directoryURL)
                return revision
            }
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CodexReviewAuthenticationFailure.accountCommit(
                    message: "Could not create immutable authentication revision \(revision)."
                )
            }
            do {
                let handle = try FileHandle(forWritingTo: url)
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
                try synchronizeDirectory(at: directoryURL)
                let persisted = try validatedAuthData(at: url)
                guard fingerprint(persisted) == fingerprint(data) else {
                    throw CodexReviewAuthenticationFailure.accountCommit(
                        message: "Immutable authentication revision fingerprint mismatch."
                    )
                }
                return revision
            } catch {
                let originalError = error
                do {
                    try removeDurably(at: url)
                } catch {
                    throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                        message: "Immutable authentication revision creation failed and its partial file could not be durably removed. "
                            + "Original failure: \(originalError.localizedDescription). "
                            + "Cleanup failure: \(error.localizedDescription)"
                    )
                }
                throw originalError
            }
        }

        private static func validatedAuthData(at url: URL) throws -> Data {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                throw CodexReviewAuthenticationFailure.nonExportableCredentialStore
            }
            let data = try Data(contentsOf: url)
            _ = try validatedAuthObject(data)
            return data
        }

        private static func validatedAuthObject(_ data: Data) throws -> [String: Any] {
            guard data.isEmpty == false,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw CodexReviewAuthenticationFailure.nonExportableCredentialStore
            }
            return object
        }

        private static func fingerprint(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        private static func writeAtomically(
            _ data: Data,
            to destinationURL: URL,
            permissions: Int,
            directoryDurabilityDidSynchronize: (@Sendable (URL) throws -> Void)? = nil,
            destinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil
        ) throws {
            let directoryURL = destinationURL.deletingLastPathComponent()
            try createDirectoryHierarchy(
                at: directoryURL,
                directoryDurabilityDidSynchronize: directoryDurabilityDidSynchronize
            )
            let replacementURL = directoryURL.appendingPathComponent(
                ".\(destinationURL.lastPathComponent).replacement-\(UUID().uuidString)"
            )
            guard FileManager.default.createFile(
                atPath: replacementURL.path,
                contents: nil,
                attributes: [.posixPermissions: permissions]
            ) else {
                throw CodexReviewAuthenticationFailure.accountCommit(
                    message: "Could not create registry replacement file."
                )
            }
            var didReplaceDestination = false
            do {
                let handle = try FileHandle(forWritingTo: replacementURL)
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
                try renameAtomically(from: replacementURL, to: destinationURL)
                didReplaceDestination = true
                try destinationDidReplace?()
                try synchronizeFile(at: destinationURL)
                try synchronizeDirectory(at: directoryURL)
            } catch {
                if (try? Data(contentsOf: destinationURL)) == data {
                    do {
                        try synchronizeFile(at: destinationURL)
                        try synchronizeDirectory(at: directoryURL)
                        if FileManager.default.fileExists(atPath: replacementURL.path) {
                            try removeDurably(at: replacementURL)
                        }
                        return
                    } catch {
                        throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                            message: "The replacement at \(destinationURL.path) is visible but its durability remains unresolved: "
                                + error.localizedDescription
                        )
                    }
                }
                if didReplaceDestination {
                    throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                        message: "The replacement outcome at \(destinationURL.path) is unresolved: "
                            + error.localizedDescription
                    )
                }
                if FileManager.default.fileExists(atPath: replacementURL.path) {
                    do {
                        try removeDurably(at: replacementURL)
                    } catch {
                        throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                            message: "Atomic replacement failed before commit and its temporary file could not be removed: "
                                + error.localizedDescription
                        )
                    }
                }
                throw error
            }
        }

        private static func createDirectoryHierarchy(
            at directoryURL: URL,
            directoryDurabilityDidSynchronize: (@Sendable (URL) throws -> Void)? = nil
        ) throws {
            let directoryURL = directoryURL.standardizedFileURL
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            var cursor = directoryURL
            while true {
                try synchronizeDirectory(at: cursor)
                try directoryDurabilityDidSynchronize?(cursor)
                guard cursor != filesystemRootURL else {
                    return
                }
                let parent = cursor.deletingLastPathComponent()
                guard parent != cursor else {
                    throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                        message: "Directory durability escaped its owning ancestor at \(directoryURL.path)."
                    )
                }
                cursor = parent
            }
        }

        private static func renameAtomically(from sourceURL: URL, to destinationURL: URL) throws {
            let result = sourceURL.path.withCString { sourcePath in
                destinationURL.path.withCString { destinationPath in
                    Darwin.rename(sourcePath, destinationPath)
                }
            }
            guard result == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }

        private static func synchronizeFile(at url: URL) throws {
            let handle = try FileHandle(forWritingTo: url)
            try handle.synchronize()
            try handle.close()
        }

        private static func removeDurably(
            at url: URL,
            directoryDurabilityDidSynchronize: (@Sendable (URL) throws -> Void)? = nil
        ) throws {
            let directoryURL = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    guard FileManager.default.fileExists(atPath: url.path) == false else {
                        throw error
                    }
                }
            }
            guard FileManager.default.fileExists(atPath: url.path) == false else {
                throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                    message: "The durable removal left its destination visible at \(url.path)."
                )
            }
            guard FileManager.default.fileExists(atPath: directoryURL.path) else {
                return
            }
            do {
                try synchronizeDirectory(at: directoryURL)
                try directoryDurabilityDidSynchronize?(directoryURL)
            } catch {
                do {
                    try synchronizeDirectory(at: directoryURL)
                    try directoryDurabilityDidSynchronize?(directoryURL)
                } catch {
                    throw CodexReviewAuthenticationFailure.persistenceInconsistent(
                        message: "The removal at \(url.path) is visible but its directory durability remains unresolved: "
                            + error.localizedDescription
                    )
                }
            }
        }

        private static func synchronizeDirectory(at url: URL) throws {
            let descriptor = open(url.path, O_RDONLY)
            guard descriptor >= 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            defer { Darwin.close(descriptor) }
            guard fsync(descriptor) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }

        private static func normalizedAccountKey(from entry: Entry) -> String? {
            let email = entry.email.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedEmail = CodexReviewAccount.normalizedEmail(email)
            return entry.accountKey
                .map(CodexReviewAccount.normalizedEmail)
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? (normalizedEmail.isEmpty ? nil : normalizedEmail)
        }

        private static func registryURL(codexHomeURL: URL) -> URL {
            accountsDirectoryURL(codexHomeURL: codexHomeURL)
                .appendingPathComponent("registry.json")
        }

        private static func journalURL(codexHomeURL: URL) -> URL {
            accountsDirectoryURL(codexHomeURL: codexHomeURL)
                .appendingPathComponent("mutation-journal.json")
        }

        private static func reconciliationDebtURL(codexHomeURL: URL) -> URL {
            accountsDirectoryURL(codexHomeURL: codexHomeURL)
                .appendingPathComponent("reconciliation-debt.json")
        }

        private static func temporaryHomeCleanupDebtURL(codexHomeURL: URL) -> URL {
            accountsDirectoryURL(codexHomeURL: codexHomeURL)
                .appendingPathComponent("temporary-home-cleanup-debt.json")
        }

        private static func sharedAuthURL(codexHomeURL: URL) -> URL {
            codexHomeURL.appendingPathComponent("auth.json")
        }

        private static func savedAccountAuthURL(accountKey: String, codexHomeURL: URL) -> URL {
            savedAccountDirectoryURL(accountKey: accountKey, codexHomeURL: codexHomeURL)
                .appendingPathComponent("auth.json")
        }

        private static func immutableAuthURL(
            for entry: Entry,
            accountKey: String,
            codexHomeURL: URL
        ) -> URL? {
            guard let revision = entry.immutableRevision else {
                return nil
            }
            return immutableAuthURL(
                accountKey: accountKey,
                revision: revision,
                codexHomeURL: codexHomeURL
            )
        }

        private static func immutableAuthURL(
            accountKey: String,
            revision: String,
            codexHomeURL: URL
        ) -> URL {
            savedAccountDirectoryURL(accountKey: accountKey, codexHomeURL: codexHomeURL)
                .appendingPathComponent("revisions", isDirectory: true)
                .appendingPathComponent("\(revision).json")
        }

        private static func savedAccountDirectoryURL(accountKey: String, codexHomeURL: URL) -> URL {
            accountsDirectoryURL(codexHomeURL: codexHomeURL)
                .appendingPathComponent(pathComponent(forAccountKey: accountKey), isDirectory: true)
        }

        private static func accountsDirectoryURL(codexHomeURL: URL) -> URL {
            codexHomeURL.appendingPathComponent("accounts", isDirectory: true)
        }

        private static func pathComponent(forAccountKey accountKey: String) -> String {
            let normalizedAccountKey = CodexReviewAccount.normalizedEmail(accountKey)
            switch normalizedAccountKey {
            case ".":
                return "%2E"
            case "..":
                return "%2E%2E"
            default:
                break
            }
            return normalizedAccountKey
                .addingPercentEncoding(withAllowedCharacters: accountDirectoryNameAllowedCharacters)
                ?? normalizedAccountKey
        }

        private static let accountDirectoryNameAllowedCharacters =
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    }
}
