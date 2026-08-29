import CodexReview
import Foundation
import SQLiteData

package actor ReviewHistoryDatabase: ReviewHistoryPersistence {
    private enum Storage: Sendable {
        case unopenedURL(URL)
        case unopenedWriter(any DatabaseWriter)
        case open(any DatabaseWriter, prepared: Bool)
        case closed
    }

    private var storage: Storage

    package init(databaseURL: URL) {
        storage = .unopenedURL(databaseURL)
    }

    package init(databaseWriter: any DatabaseWriter) {
        storage = .unopenedWriter(databaseWriter)
    }

    package func load() async throws -> [ReviewHistoryRecord] {
        let database = try preparedDatabase()
        let now = Date()
        return try write(database) { db in
            _ = try Self.decodeAll(in: db)
            try Self.finalizeOrphanedReviews(in: db, updatedAt: now)
            _ = try ReviewHistoryRetention.prune(in: db, policy: .default)
            try ReviewHistoryRetention.deleteEmptyWorkspaces(in: db)
            return try Self.decodeAll(in: db)
        }
    }

    package func recordStarted(_ record: ReviewHistoryRecord) async throws {
        let database = try preparedDatabase()
        let now = Date()
        let encoded = try ReviewHistoryRecordCodec.encodeStarted(
            record,
            createdAt: now,
            updatedAt: now
        )
        try write(database) { db in
            guard try ReviewRecordRow.where({ $0.id.eq(record.id) }).fetchOne(db) == nil else {
                throw ReviewHistoryDatabaseError.duplicateReview(record.id)
            }
            try Self.upsert(encoded.workspace, in: db)
            try ReviewRecordRow.insert { encoded.review }.execute(db)
        }
    }

    package func recordTerminal(
        _ record: ReviewHistoryRecord,
        retentionPolicy: ReviewHistoryRetentionPolicy
    ) async throws -> ReviewHistoryMutationResult {
        let database = try preparedDatabase()
        let now = Date()
        return try write(database) { db in
            guard let existing = try ReviewRecordRow.where({ $0.id.eq(record.id) }).fetchOne(db)
            else {
                throw ReviewHistoryDatabaseError.reviewNotFound(record.id)
            }
            guard existing.status == ReviewJobState.queued.rawValue
                    || existing.status == ReviewJobState.running.rawValue
            else {
                throw ReviewHistoryDatabaseError.invalidRecord(
                    id: record.id,
                    reason: "terminal state can only be recorded once"
                )
            }
            guard existing.cwd == record.cwd,
                  try ReviewHistoryRecordCodec.decodeTarget(existing) == record.target
            else {
                throw ReviewHistoryDatabaseError.invalidRecord(
                    id: record.id,
                    reason: "terminal record changed immutable admission identity"
                )
            }

            let encoded = try ReviewHistoryRecordCodec.encodeTerminal(
                record,
                createdAt: existing.createdAt,
                updatedAt: now
            )
            try Self.upsert(encoded.workspace, in: db)
            try ReviewRecordRow.update(encoded.review).execute(db)
            guard db.changesCount == 1 else {
                throw ReviewHistoryDatabaseError.reviewNotFound(record.id)
            }
            try ReviewFindingRow.where { $0.reviewID.eq(record.id) }.delete().execute(db)
            if encoded.findings.isEmpty == false {
                try ReviewFindingRow.insert { encoded.findings }.execute(db)
            }

            let removedIDs = try ReviewHistoryRetention.prune(
                in: db,
                policy: retentionPolicy
            )
            try ReviewHistoryRetention.deleteEmptyWorkspaces(in: db)
            return ReviewHistoryMutationResult(removedReviewIDs: removedIDs)
        }
    }

    package func saveOrdering(_ ordering: ReviewHistoryOrdering) async throws {
        try Self.validate(ordering)
        let database = try preparedDatabase()
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
                    .update { $0.sortOrder = review.sortOrder }
                    .execute(db)
            }
        }
    }

    package func deleteReview(id: String) async throws {
        let database = try preparedDatabase()
        try write(database) { db in
            guard let row = try ReviewRecordRow.where({ $0.id.eq(id) }).fetchOne(db) else {
                throw ReviewHistoryDatabaseError.reviewNotFound(id)
            }
            guard row.status != ReviewJobState.queued.rawValue,
                  row.status != ReviewJobState.running.rawValue
            else {
                throw ReviewHistoryDatabaseError.activeReviewCannotBeDeleted(id)
            }
            try ReviewRecordRow.find(id).delete().execute(db)
            guard db.changesCount == 1 else {
                throw ReviewHistoryDatabaseError.reviewNotFound(id)
            }
            try ReviewHistoryRetention.deleteEmptyWorkspaces(in: db)
        }
    }

    package func deleteAll() async throws {
        let database = try preparedDatabase()
        try write(database) { db in
            let terminalIDs = try ReviewRecordRow.fetchAll(db)
                .filter {
                    $0.status != ReviewJobState.queued.rawValue
                        && $0.status != ReviewJobState.running.rawValue
                }
                .map(\.id)
            for id in terminalIDs {
                try ReviewRecordRow.find(id).delete().execute(db)
            }
            try ReviewHistoryRetention.deleteEmptyWorkspaces(in: db)
        }
    }

    package func close() async throws {
        let database: (any DatabaseWriter)?
        switch storage {
        case .unopenedURL:
            database = nil
        case .unopenedWriter(let writer), .open(let writer, prepared: _):
            database = writer
        case .closed:
            return
        }
        storage = .closed
        try database?.close()
    }

    private func preparedDatabase() throws -> any DatabaseWriter {
        switch storage {
        case .unopenedURL(let url):
            let database = try DatabaseQueue(path: url.path(percentEncoded: false))
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
        updatedAt: Date
    ) throws {
        for var row in try ReviewRecordRow.fetchAll(db)
        where row.status == ReviewJobState.queued.rawValue
            || row.status == ReviewJobState.running.rawValue {
            row.status = ReviewJobState.failed.rawValue
            row.exitCode = nil
            row.endedAt = nil
            row.cancellationSource = nil
            row.cancellationMessage = nil
            row.terminalKind = ReviewTerminalKind.interrupted.rawValue
            row.interruptionKind = "previousProcessExit"
            row.terminalMessage = nil
            row.errorMessage = nil
            row.hasFinalReview = false
            row.canonicalFinalReview = nil
            row.parsedState = nil
            row.parsedFindingCount = nil
            row.parsedSource = nil
            row.parserVersion = nil
            row.updatedAt = updatedAt
            try ReviewRecordRow.update(row).execute(db)
        }
    }

    private static func decodeAll(in db: Database) throws -> [ReviewHistoryRecord] {
        let workspaces = try ReviewWorkspaceRow.fetchAll(db)
        let workspacesByCWD = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.cwd, $0) })
        let findingRows = try ReviewFindingRow.fetchAll(db)
        let findingsByReviewID = Dictionary(grouping: findingRows, by: \.reviewID)

        let records = try ReviewRecordRow.fetchAll(db).map { row in
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

        return records.sorted { lhs, rhs in
            if lhs.workspaceSortOrder != rhs.workspaceSortOrder {
                return lhs.workspaceSortOrder < rhs.workspaceSortOrder
            }
            if lhs.cwd != rhs.cwd {
                return lhs.cwd < rhs.cwd
            }
            if lhs.sortOrder != rhs.sortOrder {
                return lhs.sortOrder < rhs.sortOrder
            }
            return lhs.id < rhs.id
        }
    }

    private static func upsert(_ workspace: ReviewWorkspaceRow, in db: Database) throws {
        if try ReviewWorkspaceRow.where({ $0.cwd.eq(workspace.cwd) }).fetchOne(db) == nil {
            try ReviewWorkspaceRow.insert { workspace }.execute(db)
        } else {
            try ReviewWorkspaceRow.update(workspace).execute(db)
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
}

private func write<Result>(
    _ database: any DatabaseWriter,
    _ operation: (Database) throws -> Result
) throws -> Result {
    try database.write(operation)
}
