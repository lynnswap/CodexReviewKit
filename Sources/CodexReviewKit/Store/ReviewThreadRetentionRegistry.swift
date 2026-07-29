import Foundation
import Darwin

package struct ReviewThreadRetentionScope: Codable, Hashable, Sendable {
    package let codexHomePath: String
    package let accountKey: String?

    package init(codexHomePath: String, accountKey: String?) {
        precondition(
            codexHomePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            "A review retention scope requires a Codex home path."
        )
        let normalizedPath = URL(fileURLWithPath: codexHomePath, isDirectory: true)
            .standardizedFileURL.path
        self.codexHomePath = normalizedPath
        self.accountKey = accountKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    package func matchesCodexHome(of other: Self) -> Bool {
        codexHomePath == other.codexHomePath
    }

    private enum CodingKeys: String, CodingKey {
        case codexHomePath
        case accountKey
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawPath = try container.decode(String.self, forKey: .codexHomePath)
        guard rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw DecodingError.dataCorruptedError(
                forKey: .codexHomePath,
                in: container,
                debugDescription: "A review retention scope requires a Codex home path."
            )
        }
        self.init(
            codexHomePath: rawPath,
            accountKey: try container.decodeIfPresent(String.self, forKey: .accountKey)
        )
    }
}

package struct ReviewThreadRetentionEntry: Codable, Hashable, Sendable {
    package let runID: ReviewRunID
    package let scope: ReviewThreadRetentionScope
    package private(set) var attempts: [ReviewAttempt]
    package private(set) var additionalCleanupThreadIDs: [ReviewThreadID]

    package init(
        runID: ReviewRunID,
        scope: ReviewThreadRetentionScope,
        attempts: [ReviewAttempt],
        additionalCleanupThreadIDs: [ReviewThreadID] = []
    ) {
        let validatedAttempts: [ReviewAttempt]
        do {
            validatedAttempts = try Self.validatedAttempts(attempts, runID: runID)
        } catch {
            preconditionFailure("Invalid retained review entry: \(error)")
        }
        let sourceThreadID = validatedAttempts[0].threadIdentity.sourceThreadID
        precondition(
            validatedAttempts.allSatisfy { $0.threadIdentity.sourceThreadID == sourceThreadID },
            "All retained attempts for one run must share the source thread identity."
        )
        self.runID = runID
        self.scope = scope
        self.attempts = validatedAttempts
        self.additionalCleanupThreadIDs = Self.deduplicated(additionalCleanupThreadIDs)
    }

    package var sourceThreadID: ReviewThreadID {
        attempts[0].threadIdentity.sourceThreadID
    }

    package mutating func merge(_ attempt: ReviewAttempt, scope: ReviewThreadRetentionScope) throws {
        guard self.scope == scope else {
            throw ReviewThreadRetentionRegistryError.scopeMismatch(runID: runID)
        }
        guard attempt.threadIdentity.sourceThreadID == sourceThreadID else {
            throw ReviewThreadRetentionRegistryError.sourceThreadMismatch(runID: runID)
        }
        if let existing = attempts.first(where: { $0.attemptID == attempt.attemptID }) {
            guard existing == attempt else {
                throw ReviewThreadRetentionRegistryError.attemptIdentityConflict(
                    runID: runID,
                    attemptID: attempt.attemptID
                )
            }
            return
        }
        attempts.append(attempt)
    }

    package mutating func merge(_ other: ReviewThreadRetentionEntry) throws {
        guard runID == other.runID else {
            preconditionFailure("Only entries for the same review run can be merged.")
        }
        for attempt in other.attempts {
            try merge(attempt, scope: other.scope)
        }
        mergeAdditionalCleanupThreadIDs(other.additionalCleanupThreadIDs)
    }

    package mutating func mergeAdditionalCleanupThreadIDs(_ threadIDs: [ReviewThreadID]) {
        var seen = Set(additionalCleanupThreadIDs)
        for threadID in threadIDs where seen.insert(threadID).inserted {
            additionalCleanupThreadIDs.append(threadID)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case runID
        case scope
        case attempts
        case additionalCleanupThreadIDs
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let runID = try container.decode(ReviewRunID.self, forKey: .runID)
        let attempts = try container.decode([ReviewAttempt].self, forKey: .attempts)
        do {
            self.runID = runID
            self.scope = try container.decode(ReviewThreadRetentionScope.self, forKey: .scope)
            self.attempts = try Self.validatedAttempts(attempts, runID: runID)
            self.additionalCleanupThreadIDs = Self.deduplicated(
                try container.decodeIfPresent(
                    [ReviewThreadID].self,
                    forKey: .additionalCleanupThreadIDs
                ) ?? []
            )
        } catch let error as ReviewThreadRetentionRegistryError {
            throw DecodingError.dataCorruptedError(
                forKey: .attempts,
                in: container,
                debugDescription: error.message
            )
        }
    }

    private static func validatedAttempts(
        _ attempts: [ReviewAttempt],
        runID: ReviewRunID
    ) throws -> [ReviewAttempt] {
        guard let first = attempts.first else {
            throw ReviewThreadRetentionRegistryError.emptyEntry(runID: runID)
        }
        guard attempts.allSatisfy({
            $0.threadIdentity.sourceThreadID == first.threadIdentity.sourceThreadID
        }) else {
            throw ReviewThreadRetentionRegistryError.sourceThreadMismatch(runID: runID)
        }
        var attemptsByID: [ReviewAttemptID: ReviewAttempt] = [:]
        var validated: [ReviewAttempt] = []
        for attempt in attempts {
            if let existing = attemptsByID[attempt.attemptID] {
                guard existing == attempt else {
                    throw ReviewThreadRetentionRegistryError.attemptIdentityConflict(
                        runID: runID,
                        attemptID: attempt.attemptID
                    )
                }
                continue
            }
            attemptsByID[attempt.attemptID] = attempt
            validated.append(attempt)
        }
        return validated
    }

    private static func deduplicated(_ threadIDs: [ReviewThreadID]) -> [ReviewThreadID] {
        var seen: Set<ReviewThreadID> = []
        return threadIDs.filter { seen.insert($0).inserted }
    }
}

package struct ReviewThreadRetentionJournalSnapshot: Codable, Equatable, Sendable {
    package var entries: [ReviewThreadRetentionEntry]

    package init(entries: [ReviewThreadRetentionEntry] = []) {
        self.entries = entries
    }
}

package protocol ReviewThreadRetentionJournaling: Sendable {
    func load() async throws -> ReviewThreadRetentionJournalSnapshot
    func replace(with snapshot: ReviewThreadRetentionJournalSnapshot) async throws
}

package actor InMemoryReviewThreadRetentionJournal: ReviewThreadRetentionJournaling {
    private var snapshot: ReviewThreadRetentionJournalSnapshot

    package init(snapshot: ReviewThreadRetentionJournalSnapshot = .init()) {
        self.snapshot = snapshot
    }

    package func load() -> ReviewThreadRetentionJournalSnapshot {
        snapshot
    }

    package func replace(with snapshot: ReviewThreadRetentionJournalSnapshot) {
        self.snapshot = snapshot
    }
}

package actor FileReviewThreadRetentionJournal: ReviewThreadRetentionJournaling {
    private struct Payload: Codable {
        var version: Int
        var entries: [ReviewThreadRetentionEntry]
    }

    private let fileURL: URL

    package init(fileURL: URL) {
        self.fileURL = fileURL
    }

    package func load() throws -> ReviewThreadRetentionJournalSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .init()
        }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: fileURL))
        guard payload.version == 1 else {
            throw ReviewThreadRetentionRegistryError.unsupportedJournalVersion(payload.version)
        }
        return .init(entries: payload.entries)
    }

    package func replace(with snapshot: ReviewThreadRetentionJournalSnapshot) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        let directoryExisted = FileManager.default.fileExists(atPath: directoryURL.path)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        if directoryExisted == false {
            try Self.synchronizeDirectory(at: directoryURL.deletingLastPathComponent())
        }
        if snapshot.entries.isEmpty {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return
            }
            try FileManager.default.removeItem(at: fileURL)
            try Self.synchronizeDirectory(at: directoryURL)
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = Payload(version: 1, entries: snapshot.entries)
        let data = try encoder.encode(payload)
        let replacementURL = directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).replacement-\(UUID().uuidString)",
            isDirectory: false
        )
        guard FileManager.default.createFile(
            atPath: replacementURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ReviewThreadRetentionRegistryError.journal(
                message: "Could not create review retention journal replacement file."
            )
        }
        do {
            let replacement = try FileHandle(forWritingTo: replacementURL)
            try replacement.write(contentsOf: data)
            try replacement.synchronize()
            try replacement.close()
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: replacementURL)
            } else {
                try FileManager.default.moveItem(at: replacementURL, to: fileURL)
            }
            let persisted = try FileHandle(forWritingTo: fileURL)
            try persisted.synchronize()
            try persisted.close()
            try Self.synchronizeDirectory(at: directoryURL)
        } catch {
            try? FileManager.default.removeItem(at: replacementURL)
            throw error
        }
    }

    private nonisolated static func synchronizeDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
}

package enum ReviewThreadRetentionRegistryError: Error, Equatable, Sendable {
    case journal(message: String)
    case scopeMismatch(runID: ReviewRunID)
    case sourceThreadMismatch(runID: ReviewRunID)
    case emptyEntry(runID: ReviewRunID)
    case attemptIdentityConflict(runID: ReviewRunID, attemptID: ReviewAttemptID)
    case unsupportedJournalVersion(Int)

    package var message: String {
        switch self {
        case .journal(let message):
            message
        case .scopeMismatch(let runID):
            "Review run \(runID.rawValue) changed retention scope."
        case .sourceThreadMismatch(let runID):
            "Review run \(runID.rawValue) changed source thread identity."
        case .emptyEntry(let runID):
            "Review run \(runID.rawValue) has no retained attempt identity."
        case .attemptIdentityConflict(let runID, let attemptID):
            "Review run \(runID.rawValue) has conflicting identity for attempt \(attemptID.rawValue)."
        case .unsupportedJournalVersion(let version):
            "Unsupported review retention journal version \(version)."
        }
    }
}

package struct ReviewThreadRetentionQuarantine: Equatable, Sendable {
    package let entry: ReviewThreadRetentionEntry
    package let journalFailure: String
    package let cleanupFailure: String
}

package enum ReviewThreadRetentionAcceptance: Equatable, Sendable {
    case accepting
    case quarantined([ReviewThreadRetentionQuarantine])
    case journalUnavailable(message: String)

    package var isAccepting: Bool {
        if case .accepting = self {
            return true
        }
        return false
    }
}

package enum ReviewThreadOrphanRecoveryResult: Equatable, Sendable {
    case recovered
    case cleanupIncomplete
    case journalUnavailable(message: String)
}

package actor ReviewThreadRetentionRegistry {
    private let journal: any ReviewThreadRetentionJournaling
    private var didLoadJournal = false
    private var persistedEntriesByRunID: [ReviewRunID: ReviewThreadRetentionEntry] = [:]
    private var pendingOwnershipByRunID: [ReviewRunID: ReviewThreadRetentionEntry] = [:]
    private var quarantinesByRunID: [ReviewRunID: ReviewThreadRetentionQuarantine] = [:]

    package init(journal: any ReviewThreadRetentionJournaling) {
        self.journal = journal
    }

    package func acceptance() async -> ReviewThreadRetentionAcceptance {
        guard quarantinesByRunID.isEmpty else {
            return .quarantined(orderedQuarantines())
        }
        do {
            try await loadJournalIfNeeded()
            return .accepting
        } catch {
            return .journalUnavailable(
                message: (error as? ReviewThreadRetentionRegistryError)?.message
                    ?? error.localizedDescription
            )
        }
    }

    package func claim(
        _ attempt: ReviewAttempt,
        for runID: ReviewRunID,
        scope: ReviewThreadRetentionScope
    ) async throws {
        let existingCandidate = pendingOwnershipByRunID[runID]
            ?? persistedEntriesByRunID[runID]
        var candidate: ReviewThreadRetentionEntry
        if let existingCandidate {
            candidate = existingCandidate
            try candidate.merge(attempt, scope: scope)
        } else {
            candidate = ReviewThreadRetentionEntry(runID: runID, scope: scope, attempts: [attempt])
        }
        pendingOwnershipByRunID[runID] = candidate

        do {
            try await loadJournalIfNeeded()
            if var persisted = persistedEntriesByRunID[runID] {
                try persisted.merge(candidate)
                candidate = persisted
                pendingOwnershipByRunID[runID] = candidate
            }
            if persistedEntriesByRunID[runID] == candidate,
               quarantinesByRunID[runID] == nil
            {
                pendingOwnershipByRunID.removeValue(forKey: runID)
                return
            }
            var desired = persistedEntriesByRunID
            desired[runID] = candidate
            try await journal.replace(with: Self.snapshot(desired))
            persistedEntriesByRunID = desired
            pendingOwnershipByRunID.removeValue(forKey: runID)
            quarantinesByRunID.removeValue(forKey: runID)
        } catch let error as ReviewThreadRetentionRegistryError {
            throw error
        } catch {
            throw ReviewThreadRetentionRegistryError.journal(message: error.localizedDescription)
        }
    }

    package func recordFailedClaimCleanup(
        runID: ReviewRunID,
        journalFailure: String,
        failedThreadIDs: [ReviewThreadID],
        cleanupFailure: String?
    ) {
        guard let pending = pendingOwnershipByRunID[runID] else {
            preconditionFailure("A failed retention claim must keep pending ownership until rollback resolves.")
        }
        guard let cleanupFailure else {
            pendingOwnershipByRunID.removeValue(forKey: runID)
            quarantinesByRunID.removeValue(forKey: runID)
            return
        }
        var quarantinedEntry = pending
        quarantinedEntry.mergeAdditionalCleanupThreadIDs(failedThreadIDs)
        pendingOwnershipByRunID[runID] = quarantinedEntry
        quarantinesByRunID[runID] = .init(
            entry: quarantinedEntry,
            journalFailure: journalFailure,
            cleanupFailure: cleanupFailure
        )
    }

    package func retryQuarantinedJournalCommits() async -> ReviewThreadRetentionAcceptance {
        guard quarantinesByRunID.isEmpty == false else {
            return await acceptance()
        }
        do {
            try await loadJournalIfNeeded()
            var desired = persistedEntriesByRunID
            for (runID, quarantine) in quarantinesByRunID {
                if var current = desired[runID] {
                    try current.merge(quarantine.entry)
                    desired[runID] = current
                } else {
                    desired[runID] = quarantine.entry
                }
            }
            try await journal.replace(with: Self.snapshot(desired))
            persistedEntriesByRunID = desired
            for runID in quarantinesByRunID.keys {
                pendingOwnershipByRunID.removeValue(forKey: runID)
            }
            quarantinesByRunID.removeAll(keepingCapacity: false)
            return .accepting
        } catch {
            return .quarantined(orderedQuarantines())
        }
    }

    package func quarantinedEntries() -> [ReviewThreadRetentionEntry] {
        orderedQuarantines().map(\.entry)
    }

    package func pendingEntry(for runID: ReviewRunID) -> ReviewThreadRetentionEntry? {
        pendingOwnershipByRunID[runID]
    }

    package func entriesForFinalRetirement(
        matchingCodexHome scope: ReviewThreadRetentionScope
    ) async throws -> [ReviewThreadRetentionEntry] {
        try await loadJournalIfNeeded()
        return persistedEntriesByRunID.values
            .filter { $0.scope.matchesCodexHome(of: scope) }
            .sorted(by: Self.entryOrder)
    }

    package func orphanedEntries(
        excluding liveRunIDs: Set<ReviewRunID>,
        matchingCodexHome scope: ReviewThreadRetentionScope
    ) async throws -> [ReviewThreadRetentionEntry] {
        try await loadJournalIfNeeded()
        return persistedEntriesByRunID.values
            .filter {
                liveRunIDs.contains($0.runID) == false
                    && $0.scope.matchesCodexHome(of: scope)
            }
            .sorted(by: Self.entryOrder)
    }

    package func recordCleanupSucceeded(for runID: ReviewRunID) async {
        pendingOwnershipByRunID.removeValue(forKey: runID)
        quarantinesByRunID.removeValue(forKey: runID)
        guard persistedEntriesByRunID[runID] != nil else {
            return
        }
        var desired = persistedEntriesByRunID
        desired.removeValue(forKey: runID)
        do {
            try await journal.replace(with: Self.snapshot(desired))
            persistedEntriesByRunID = desired
        } catch {
            // The durable tombstone is intentionally retained. Cleanup is idempotent,
            // so startup recovery can repeat it and retry journal removal.
        }
    }

    package func recordCleanupFailed(
        for runID: ReviewRunID,
        failedThreadIDs: [ReviewThreadID],
        message: String
    ) async -> Bool {
        guard failedThreadIDs.isEmpty == false else {
            preconditionFailure("A retained cleanup failure requires at least one failed thread identity.")
        }
        guard var entry = persistedEntriesByRunID[runID] else {
            if var quarantine = quarantinesByRunID[runID] {
                var quarantinedEntry = quarantine.entry
                quarantinedEntry.mergeAdditionalCleanupThreadIDs(failedThreadIDs)
                pendingOwnershipByRunID[runID] = quarantinedEntry
                quarantine = .init(
                    entry: quarantinedEntry,
                    journalFailure: quarantine.journalFailure,
                    cleanupFailure: message
                )
                quarantinesByRunID[runID] = quarantine
            }
            return false
        }
        entry.mergeAdditionalCleanupThreadIDs(failedThreadIDs)
        var desired = persistedEntriesByRunID
        desired[runID] = entry
        do {
            try await journal.replace(with: Self.snapshot(desired))
            persistedEntriesByRunID = desired
            return true
        } catch {
            pendingOwnershipByRunID[runID] = entry
            quarantinesByRunID[runID] = .init(
                entry: entry,
                journalFailure: error.localizedDescription,
                cleanupFailure: message
            )
            return false
        }
    }

    package func snapshotForTesting() async throws -> ReviewThreadRetentionJournalSnapshot {
        try await loadJournalIfNeeded()
        return Self.snapshot(persistedEntriesByRunID)
    }

    private func loadJournalIfNeeded() async throws {
        guard didLoadJournal == false else {
            return
        }
        do {
            let snapshot = try await journal.load()
            persistedEntriesByRunID = try Self.entriesByRunID(snapshot.entries)
            didLoadJournal = true
        } catch let error as ReviewThreadRetentionRegistryError {
            throw error
        } catch {
            throw ReviewThreadRetentionRegistryError.journal(message: error.localizedDescription)
        }
    }

    private func orderedQuarantines() -> [ReviewThreadRetentionQuarantine] {
        quarantinesByRunID.values.sorted {
            Self.entryOrder($0.entry, $1.entry)
        }
    }

    private nonisolated static func entriesByRunID(
        _ entries: [ReviewThreadRetentionEntry]
    ) throws -> [ReviewRunID: ReviewThreadRetentionEntry] {
        var result: [ReviewRunID: ReviewThreadRetentionEntry] = [:]
        for entry in entries {
            if var existing = result[entry.runID] {
                try existing.merge(entry)
                result[entry.runID] = existing
            } else {
                result[entry.runID] = entry
            }
        }
        return result
    }

    private nonisolated static func snapshot(
        _ entriesByRunID: [ReviewRunID: ReviewThreadRetentionEntry]
    ) -> ReviewThreadRetentionJournalSnapshot {
        .init(entries: entriesByRunID.values.sorted(by: entryOrder))
    }

    private nonisolated static func entryOrder(
        _ lhs: ReviewThreadRetentionEntry,
        _ rhs: ReviewThreadRetentionEntry
    ) -> Bool {
        lhs.runID.rawValue < rhs.runID.rawValue
    }
}

extension CodexReviewStore {
    package var currentReviewThreadRetentionScope: ReviewThreadRetentionScope {
        ReviewThreadRetentionScope(
            codexHomePath: backend.reviewThreadRetentionCodexHomePath,
            accountKey: auth.selectedAccount?.accountKey ?? auth.persistedActiveAccountKey
        )
    }

    package func requireReviewThreadRetentionAcceptance() async throws {
        switch await reviewThreadRetentionRegistry.acceptance() {
        case .accepting:
            return
        case .quarantined(let quarantines):
            let runIDs = quarantines.map { $0.entry.runID.rawValue }.joined(separator: ", ")
            throw ReviewBackendFailure.retentionJournal(
                message: "Review thread retention recovery is quarantined for run(s): \(runIDs)."
            )
        case .journalUnavailable(let message):
            throw ReviewBackendFailure.retentionJournal(message: message)
        }
    }

    package func claimReviewThreadOwnership(
        _ attempt: ReviewAttempt,
        for runID: ReviewRunID
    ) async throws {
        do {
            try await reviewThreadRetentionRegistry.claim(
                attempt,
                for: runID,
                scope: currentReviewThreadRetentionScope
            )
        } catch {
            let journalFailure = (error as? ReviewThreadRetentionRegistryError)?.message
                ?? error.localizedDescription
            try? await backend.interruptReview(
                attempt,
                reason: .init(message: "Review retention journal commit failed.")
            )
            await backend.cleanupReview(attempt)
            let pending = await reviewThreadRetentionRegistry.pendingEntry(for: runID)
            let cleanup = await backend.cleanupRetainedReviews(
                pending?.attempts ?? [attempt],
                additionalThreadIDs: pending?.additionalCleanupThreadIDs ?? []
            )
            await reviewThreadRetentionRegistry.recordFailedClaimCleanup(
                runID: runID,
                journalFailure: journalFailure,
                failedThreadIDs: cleanup.failures.map(\.threadID),
                cleanupFailure: cleanup.failureMessage
            )
            throw ReviewBackendFailure.retentionJournal(
                message: "Review identity could not be committed to the retention journal: \(journalFailure)"
            )
        }
    }

    package func recoverOrphanedReviewThreads() async -> ReviewThreadOrphanRecoveryResult {
        let scope = currentReviewThreadRetentionScope
        let liveRunIDs = Set(reviewRuns.map(\.id))
        let entries: [ReviewThreadRetentionEntry]
        do {
            entries = try await reviewThreadRetentionRegistry.orphanedEntries(
                excluding: liveRunIDs,
                matchingCodexHome: scope
            )
        } catch {
            return .journalUnavailable(
                message: (error as? ReviewThreadRetentionRegistryError)?.message
                    ?? error.localizedDescription
            )
        }
        var allCleaned = true
        var journalRemainsAvailable = true
        for entry in entries {
            let result = await backend.cleanupRetainedReviews(
                entry.attempts,
                additionalThreadIDs: entry.additionalCleanupThreadIDs
            )
            if result.succeeded {
                await reviewThreadRetentionRegistry.recordCleanupSucceeded(for: entry.runID)
            } else {
                let didPersistFailure = await reviewThreadRetentionRegistry.recordCleanupFailed(
                    for: entry.runID,
                    failedThreadIDs: result.failures.map(\.threadID),
                    message: result.failureMessage ?? "Review thread cleanup failed."
                )
                journalRemainsAvailable = journalRemainsAvailable && didPersistFailure
                allCleaned = false
            }
        }
        if journalRemainsAvailable == false {
            return .journalUnavailable(
                message: "Review cleanup failures could not be committed to the retention journal."
            )
        }
        return allCleaned ? .recovered : .cleanupIncomplete
    }

    @discardableResult
    package func retireReviewRunsForFinalStoreStop() async -> Bool {
        _ = await reviewThreadRetentionRegistry.retryQuarantinedJournalCommits()
        let currentScope = currentReviewThreadRetentionScope
        let entries: [ReviewThreadRetentionEntry]
        do {
            entries = try await reviewThreadRetentionRegistry.entriesForFinalRetirement(
                matchingCodexHome: currentScope
            )
        } catch {
            return false
        }
        let quarantined = await reviewThreadRetentionRegistry.quarantinedEntries()
        let quarantinedRunIDs = Set(quarantined.map(\.runID))

        reviewRuns.removeAll(keepingCapacity: false)
        writeDiagnosticsIfNeeded()

        for entry in quarantined {
            guard entry.scope.matchesCodexHome(of: currentScope) else {
                return false
            }
            let cleanup = await backend.cleanupRetainedReviews(
                entry.attempts,
                additionalThreadIDs: entry.additionalCleanupThreadIDs
            )
            guard cleanup.succeeded else {
                _ = await reviewThreadRetentionRegistry.recordCleanupFailed(
                    for: entry.runID,
                    failedThreadIDs: cleanup.failures.map(\.threadID),
                    message: cleanup.failureMessage ?? "Review thread cleanup failed."
                )
                continue
            }
            await reviewThreadRetentionRegistry.recordCleanupSucceeded(for: entry.runID)
        }
        guard await reviewThreadRetentionRegistry.acceptance().isAccepting else {
            return false
        }

        for entry in entries
        where entry.scope.matchesCodexHome(of: currentScope)
            && quarantinedRunIDs.contains(entry.runID) == false
        {
            let result = await backend.cleanupRetainedReviews(
                entry.attempts,
                additionalThreadIDs: entry.additionalCleanupThreadIDs
            )
            if result.succeeded {
                await reviewThreadRetentionRegistry.recordCleanupSucceeded(for: entry.runID)
            } else if await reviewThreadRetentionRegistry.recordCleanupFailed(
                for: entry.runID,
                failedThreadIDs: result.failures.map(\.threadID),
                message: result.failureMessage ?? "Review thread cleanup failed."
            ) == false {
                return false
            }
        }
        return true
    }
}
