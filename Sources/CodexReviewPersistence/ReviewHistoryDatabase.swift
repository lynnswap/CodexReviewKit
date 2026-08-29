import CodexReview
import Foundation
import SQLiteData

package actor ReviewHistoryDatabase: ReviewHistoryPersistence {
    private enum Storage: Sendable {
        case unopenedURL(URL)
        case unopenedWriter(any DatabaseWriter)
        case open(any DatabaseWriter, prepared: Bool)
        case closed(failure: ReviewHistoryDatabaseError?)
    }

    private var storage: Storage
    private var fileOwnership: ReviewHistoryDatabaseOwnership?
    private let now: @Sendable () -> Date

    package init(
        databaseURL: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        storage = .unopenedURL(databaseURL)
        self.now = now
    }

    package init(
        databaseWriter: any DatabaseWriter,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        storage = .unopenedWriter(databaseWriter)
        self.now = now
    }

    package func load(
        retentionPolicy: ReviewHistoryRetentionPolicy
    ) async throws -> [RestoredReviewRecord] {
        let database = try preparedDatabase()
        let timestamp = now()
        return try write(database) { db in
            _ = try Self.decodeAll(in: db)
            try Self.backfillWorkspaceMetadata(in: db)
            try Self.finalizeOrphanedReviews(in: db, committedAt: timestamp)
            _ = try ReviewHistoryRetention.prune(
                in: db,
                policy: retentionPolicy,
                protecting: nil
            )
            try ReviewHistoryRetention.deleteEmptyWorkspaces(in: db)
            return try Self.decodeAllRestored(in: db)
        }
    }

    package func recordStarted(_ record: StartedReviewRecord) async throws {
        let database = try preparedDatabase()
        let timestamp = now()
        let encoded = try ReviewHistoryRecordCodec.encodeStarted(
            record,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try write(database) { db in
            guard try ReviewRecordRow.where({ $0.id.eq(record.id) }).fetchOne(db) == nil else {
                throw ReviewHistoryDatabaseError.duplicateReview(record.id)
            }
            try Self.insertWorkspaceIfMissing(encoded.workspace, in: db)
            try ReviewRecordRow.insert { encoded.review }.execute(db)
            try Self.validateUniqueReviewSortOrders(in: db)
        }
    }

    package func recordTerminal(
        _ record: TerminalReviewRecord,
        retentionPolicy: ReviewHistoryRetentionPolicy
    ) async throws -> ReviewHistoryMutationResult {
        let database = try preparedDatabase()
        let timestamp = now()
        return try write(database) { db in
            guard let existing = try ReviewRecordRow.where({ $0.id.eq(record.id) }).fetchOne(db)
            else {
                throw ReviewHistoryDatabaseError.reviewNotFound(record.id)
            }
            guard existing.phase == "active" else {
                throw ReviewHistoryDatabaseError.invalidRecord(
                    id: record.id,
                    reason: "terminal state can only be recorded once"
                )
            }
            guard let workspace = try ReviewWorkspaceRow
                .where({ $0.cwd.eq(existing.cwd) })
                .fetchOne(db)
            else {
                throw ReviewHistoryDatabaseError.invalidRecord(
                    id: record.id,
                    reason: "workspace row is missing"
                )
            }
            _ = try ReviewHistoryRecordCodec.decode(
                existing,
                workspace: workspace,
                findings: try ReviewFindingRow
                    .where { $0.reviewID.eq(record.id) }
                    .fetchAll(db)
            )

            let encoded = try ReviewHistoryRecordCodec.encodeTerminal(
                record,
                replacing: existing,
                terminalCommittedAt: timestamp,
                updatedAt: timestamp
            )
            try Self.updateTerminal(encoded.review, in: db)
            try ReviewFindingRow.where { $0.reviewID.eq(record.id) }.delete().execute(db)
            if encoded.findings.isEmpty == false {
                try ReviewFindingRow.insert { encoded.findings }.execute(db)
            }

            let removedIDs = try ReviewHistoryRetention.prune(
                in: db,
                policy: retentionPolicy,
                protecting: record.id
            )
            try ReviewHistoryRetention.deleteEmptyWorkspaces(in: db)
            return ReviewHistoryMutationResult(removedReviewIDs: removedIDs)
        }
    }

    package func saveOrdering(_ ordering: ReviewHistoryOrdering) async throws {
        let database = try preparedDatabase()
        let timestamp = ReviewHistoryTimestamp.encode(now())
        try Self.validate(ordering)
        try write(database) { db in
            let existingWorkspaces = Set(try ReviewWorkspaceRow.fetchAll(db).map(\.cwd))
            let existingReviews = Set(try ReviewRecordRow.fetchAll(db).map(\.id))

            for workspace in ordering.workspaces {
                guard existingWorkspaces.contains(workspace.cwd) else {
                    throw ReviewHistoryDatabaseError.invalidRecord(
                        id: workspace.cwd,
                        reason: "ordering references an unknown workspace"
                    )
                }
                try ReviewWorkspaceRow.find(workspace.cwd)
                    .update { $0.sortOrder = workspace.sortOrder }
                    .execute(db)
            }
            for review in ordering.reviews {
                guard existingReviews.contains(review.id) else {
                    throw ReviewHistoryDatabaseError.reviewNotFound(review.id)
                }
                try ReviewRecordRow.find(review.id)
                    .update {
                        $0.sortOrder = review.sortOrder
                        $0.updatedAt = #bind(timestamp)
                    }
                    .execute(db)
            }
            try Self.validateUniqueReviewSortOrders(in: db)
        }
    }

    package func deleteTerminalReview(
        id: String
    ) async throws -> ReviewHistoryMutationResult {
        let database = try preparedDatabase()
        return try write(database) { db in
            guard let row = try ReviewRecordRow.where({ $0.id.eq(id) }).fetchOne(db) else {
                return ReviewHistoryMutationResult()
            }
            let decoded = try Self.decode(row, in: db)
            guard case .terminal = decoded else {
                return ReviewHistoryMutationResult()
            }
            try ReviewRecordRow.find(id).delete().execute(db)
            guard db.changesCount == 1 else {
                throw ReviewHistoryDatabaseError.reviewNotFound(id)
            }
            try ReviewHistoryRetention.deleteEmptyWorkspaces(in: db)
            return ReviewHistoryMutationResult(removedReviewIDs: [id])
        }
    }

    package func deleteAllTerminalReviews() async throws -> ReviewHistoryMutationResult {
        let database = try preparedDatabase()
        return try write(database) { db in
            _ = try Self.decodeAll(in: db)
            let terminalIDs = try ReviewRecordRow.fetchAll(db)
                .filter { $0.phase == "terminal" }
                .map(\.id)
            for id in terminalIDs {
                try ReviewRecordRow.find(id).delete().execute(db)
            }
            try ReviewHistoryRetention.deleteEmptyWorkspaces(in: db)
            return ReviewHistoryMutationResult(removedReviewIDs: Set(terminalIDs))
        }
    }

    package func close() async throws {
        let database: (any DatabaseWriter)?
        switch storage {
        case .unopenedURL:
            database = nil
        case .unopenedWriter(let writer), .open(let writer, prepared: _):
            database = writer
        case .closed(let failure):
            if let failure {
                throw failure
            }
            return
        }
        storage = .closed(failure: nil)
        var failures: [String] = []
        do {
            try database?.close()
        } catch {
            failures.append(error.localizedDescription)
        }
        do {
            try fileOwnership?.close()
        } catch {
            failures.append(error.localizedDescription)
        }
        fileOwnership = nil
        if failures.isEmpty == false {
            let failure = ReviewHistoryDatabaseError.closeFailed(
                failures.joined(separator: "; ")
            )
            storage = .closed(failure: failure)
            throw failure
        }
    }

    private func preparedDatabase() throws -> any DatabaseWriter {
        switch storage {
        case .unopenedURL(let url):
            if fileOwnership == nil {
                fileOwnership = try ReviewHistoryDatabaseOwnership(databaseURL: url)
            }
            let database = try DatabasePool(path: url.path(percentEncoded: false))
            storage = .open(database, prepared: false)
            try ReviewHistorySchema.migrate(database)
            storage = .open(database, prepared: true)
            return database
        case .unopenedWriter(let database):
            storage = .open(database, prepared: false)
            try ReviewHistorySchema.migrate(database)
            storage = .open(database, prepared: true)
            return database
        case .open(let database, prepared: false):
            try ReviewHistorySchema.migrate(database)
            storage = .open(database, prepared: true)
            return database
        case .open(let database, prepared: true):
            return database
        case .closed:
            throw ReviewHistoryDatabaseError.closed
        }
    }

    private static func finalizeOrphanedReviews(
        in db: Database,
        committedAt: Date
    ) throws {
        for row in try ReviewRecordRow.fetchAll(db) where row.phase == "active" {
            let terminal = try TerminalReviewRecord(
                id: row.id,
                model: nil,
                terminal: .interrupted(.previousProcessExit),
                endedAt: nil,
                summary: "The previous review process exited before completion.",
                canonicalReview: nil,
                parsedResult: nil
            )
            let encoded = try ReviewHistoryRecordCodec.encodeTerminal(
                terminal,
                replacing: row,
                terminalCommittedAt: committedAt,
                updatedAt: committedAt
            )
            try updateTerminal(encoded.review, in: db)
        }
    }

    private static func backfillWorkspaceMetadata(
        in db: Database,
        fileManager: FileManager = .default
    ) throws {
        for workspace in try ReviewWorkspaceRow.fetchAll(db)
        where workspace.repositoryIdentity == nil
            && workspace.displayTitle == nil
            && workspace.kind == nil
            && fileManager.fileExists(atPath: workspace.cwd) {
            let metadata = ReviewWorkspaceMetadata.resolve(
                cwd: workspace.cwd,
                fileManager: fileManager
            )
            try ReviewWorkspaceRow.find(workspace.cwd)
                .update {
                    $0.repositoryIdentity = #bind(metadata.repositoryIdentity)
                    $0.displayTitle = #bind(metadata.displayTitle)
                    $0.kind = #bind(metadata.kind.rawValue)
                }
                .execute(db)
        }
    }

    private static func decodeAll(in db: Database) throws -> [DecodedReviewHistoryRow] {
        let workspaces = try ReviewWorkspaceRow.fetchAll(db)
        let workspacesByCWD = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.cwd, $0) })
        let reviews = try ReviewRecordRow.fetchAll(db)
        try validateUniqueReviewSortOrders(reviews)
        let findingsByReviewID = Dictionary(
            grouping: try ReviewFindingRow.fetchAll(db),
            by: \.reviewID
        )
        return try reviews.map { row in
            guard let workspace = workspacesByCWD[row.cwd] else {
                throw ReviewHistoryDatabaseError.invalidRecord(
                    id: row.id,
                    reason: "workspace row is missing"
                )
            }
            return try ReviewHistoryRecordCodec.decode(
                row,
                workspace: workspace,
                findings: findingsByReviewID[row.id] ?? []
            )
        }
    }

    private static func decodeAllRestored(in db: Database) throws -> [RestoredReviewRecord] {
        let decoded = try decodeAll(in: db)
        let records = try decoded.map { value -> RestoredReviewRecord in
            switch value {
            case .terminal(let record):
                return record
            case .active(let started):
                throw ReviewHistoryDatabaseError.invalidRecord(
                    id: started.id,
                    reason: "startup orphan finalization left an active row"
                )
            }
        }
        return records.sorted { lhs, rhs in
            if lhs.started.workspaceSortOrder != rhs.started.workspaceSortOrder {
                return lhs.started.workspaceSortOrder < rhs.started.workspaceSortOrder
            }
            if lhs.started.cwd != rhs.started.cwd {
                return lhs.started.cwd < rhs.started.cwd
            }
            if lhs.started.sortOrder != rhs.started.sortOrder {
                return lhs.started.sortOrder < rhs.started.sortOrder
            }
            return lhs.started.id < rhs.started.id
        }
    }

    private static func decode(
        _ row: ReviewRecordRow,
        in db: Database
    ) throws -> DecodedReviewHistoryRow {
        guard let workspace = try ReviewWorkspaceRow
            .where({ $0.cwd.eq(row.cwd) })
            .fetchOne(db)
        else {
            throw ReviewHistoryDatabaseError.invalidRecord(
                id: row.id,
                reason: "workspace row is missing"
            )
        }
        return try ReviewHistoryRecordCodec.decode(
            row,
            workspace: workspace,
            findings: try ReviewFindingRow
                .where { $0.reviewID.eq(row.id) }
                .fetchAll(db)
        )
    }

    private static func updateTerminal(
        _ row: ReviewRecordRow,
        in db: Database
    ) throws {
        try ReviewRecordRow.find(row.id).where { $0.phase.eq("active") }.update {
            $0.phase = #bind(row.phase)
            $0.terminalModel = #bind(row.terminalModel)
            $0.terminalKind = #bind(row.terminalKind)
            $0.interruptionKind = #bind(row.interruptionKind)
            $0.cancellationSource = #bind(row.cancellationSource)
            $0.cancellationMessage = #bind(row.cancellationMessage)
            $0.terminalMessage = #bind(row.terminalMessage)
            $0.endedAt = #bind(row.endedAt)
            $0.summary = #bind(row.summary)
            $0.canonicalReview = #bind(row.canonicalReview)
            $0.parsedState = #bind(row.parsedState)
            $0.parsedFindingCount = #bind(row.parsedFindingCount)
            $0.parsedSource = #bind(row.parsedSource)
            $0.parserVersion = #bind(row.parserVersion)
            $0.terminalCommittedAt = #bind(row.terminalCommittedAt)
            $0.updatedAt = #bind(row.updatedAt)
        }
        .execute(db)
        let persisted = try ReviewRecordRow.where({ $0.id.eq(row.id) }).fetchOne(db)
        let differingColumns = persisted?.differingColumns(from: row) ?? ["missingRow"]
        guard db.changesCount == 1, differingColumns.isEmpty else {
            throw ReviewHistoryDatabaseError.invalidRecord(
                id: row.id,
                reason: "terminal mutation differs in columns: "
                    + differingColumns.joined(separator: ", ")
            )
        }
    }

    private static func insertWorkspaceIfMissing(
        _ workspace: ReviewWorkspaceRow,
        in db: Database
    ) throws {
        guard let existing = try ReviewWorkspaceRow
            .where({ $0.cwd.eq(workspace.cwd) })
            .fetchOne(db)
        else {
            try ReviewWorkspaceRow.insert { workspace }.execute(db)
            return
        }

        let existingMetadata = try ReviewHistoryRecordCodec.decodeWorkspaceMetadata(
            existing,
            reviewID: workspace.cwd
        )
        let incomingMetadata = try ReviewHistoryRecordCodec.decodeWorkspaceMetadata(
            workspace,
            reviewID: workspace.cwd
        )
        switch incomingMetadata {
        case let incoming? where existingMetadata != incoming:
            try ReviewWorkspaceRow.find(workspace.cwd)
                .update {
                    $0.repositoryIdentity = #bind(incoming.repositoryIdentity)
                    $0.displayTitle = #bind(incoming.displayTitle)
                    $0.kind = #bind(incoming.kind.rawValue)
                }
                .execute(db)
        default:
            break
        }
    }

    private static func validate(_ ordering: ReviewHistoryOrdering) throws {
        var workspaceIDs = Set<String>()
        for workspace in ordering.workspaces {
            guard workspace.cwd.nilIfEmpty != nil,
                  workspace.sortOrder.isFinite,
                  workspaceIDs.insert(workspace.cwd).inserted
            else {
                throw ReviewHistoryDatabaseError.invalidRecord(
                    id: workspace.cwd,
                    reason: "workspace ordering is empty, non-finite, or duplicated"
                )
            }
        }

        var reviewIDs = Set<String>()
        for review in ordering.reviews {
            guard review.id.nilIfEmpty != nil,
                  review.sortOrder.isFinite,
                  reviewIDs.insert(review.id).inserted
            else {
                throw ReviewHistoryDatabaseError.invalidRecord(
                    id: review.id,
                    reason: "review ordering is empty, non-finite, or duplicated"
                )
            }
        }
    }

    private static func validateUniqueReviewSortOrders(in db: Database) throws {
        try validateUniqueReviewSortOrders(ReviewRecordRow.fetchAll(db))
    }

    private static func validateUniqueReviewSortOrders(_ reviews: [ReviewRecordRow]) throws {
        var reviewIDsBySortOrder: [Double: String] = [:]
        for review in reviews {
            guard review.sortOrder.isFinite else {
                throw ReviewHistoryDatabaseError.invalidRecord(
                    id: review.id,
                    reason: "review ordering is non-finite"
                )
            }
            if let existingID = reviewIDsBySortOrder[review.sortOrder] {
                throw ReviewHistoryDatabaseError.invalidRecord(
                    id: review.id,
                    reason: "review order duplicates \(existingID)"
                )
            }
            reviewIDsBySortOrder[review.sortOrder] = review.id
        }
    }
}

private extension ReviewRecordRow {
    func differingColumns(from other: Self) -> [String] {
        var columns: [String] = []
        if id != other.id { columns.append("id") }
        if cwd != other.cwd { columns.append("cwd") }
        if sortOrder != other.sortOrder { columns.append("sortOrder") }
        if targetKind != other.targetKind { columns.append("targetKind") }
        if targetBranch != other.targetBranch { columns.append("targetBranch") }
        if targetCommitSHA != other.targetCommitSHA { columns.append("targetCommitSHA") }
        if targetCommitTitle != other.targetCommitTitle { columns.append("targetCommitTitle") }
        if targetInstructions != other.targetInstructions { columns.append("targetInstructions") }
        if startedModel != other.startedModel { columns.append("startedModel") }
        if startedAt != other.startedAt { columns.append("startedAt") }
        if phase != other.phase { columns.append("phase") }
        if terminalModel != other.terminalModel { columns.append("terminalModel") }
        if terminalKind != other.terminalKind { columns.append("terminalKind") }
        if interruptionKind != other.interruptionKind { columns.append("interruptionKind") }
        if cancellationSource != other.cancellationSource { columns.append("cancellationSource") }
        if cancellationMessage != other.cancellationMessage { columns.append("cancellationMessage") }
        if terminalMessage != other.terminalMessage { columns.append("terminalMessage") }
        if endedAt != other.endedAt { columns.append("endedAt") }
        if summary != other.summary { columns.append("summary") }
        if canonicalReview != other.canonicalReview { columns.append("canonicalReview") }
        if parsedState != other.parsedState { columns.append("parsedState") }
        if parsedFindingCount != other.parsedFindingCount { columns.append("parsedFindingCount") }
        if parsedSource != other.parsedSource { columns.append("parsedSource") }
        if parserVersion != other.parserVersion { columns.append("parserVersion") }
        if terminalCommittedAt != other.terminalCommittedAt { columns.append("terminalCommittedAt") }
        if createdAt != other.createdAt { columns.append("createdAt") }
        if updatedAt != other.updatedAt { columns.append("updatedAt") }
        return columns
    }
}

private func write<Result>(
    _ database: any DatabaseWriter,
    _ operation: (Database) throws -> Result
) throws -> Result {
    try database.write(operation)
}
