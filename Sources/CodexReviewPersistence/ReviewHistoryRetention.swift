import CodexReview
import Foundation
import SQLiteData

enum ReviewHistoryRetention {
    private typealias TerminalRow = (id: String, cwd: String, committedAt: Double)

    static func prune(
        in db: Database,
        policy: ReviewHistoryRetentionPolicy,
        protecting protectedReviewID: String?
    ) throws -> Set<String> {
        let terminalRows: [TerminalRow] = try ReviewRecordRow
            .where { $0.phase.eq("terminal") }
            .select { ($0.id, $0.cwd, $0.terminalCommittedAt) }
            .fetchAll(db)
            .map { id, cwd, committedAt in
                guard let committedAt else {
                    throw ReviewHistoryDatabaseError.invalidRecord(
                        id: id, reason: "terminal row is missing its retention timestamp"
                    )
                }
                return (id, cwd, committedAt)
            }
            .sorted { ($0.committedAt, $0.id) < ($1.committedAt, $1.id) }

        var removedIDs = Set<String>()
        for rows in Dictionary(grouping: terminalRows, by: \.cwd).values {
            removedIDs.formUnion(removals(
                from: rows,
                maximumCount: policy.maximumReviewsPerWorkspace,
                protecting: protectedReviewID
            ))
        }

        let globallyRemaining = terminalRows.filter { removedIDs.contains($0.id) == false }
        removedIDs.formUnion(removals(
            from: globallyRemaining,
            maximumCount: policy.maximumReviews,
            protecting: protectedReviewID
        ))

        for id in removedIDs.sorted() {
            try ReviewRecordRow.find(id).delete().execute(db)
            guard db.changesCount == 1 else {
                throw ReviewHistoryDatabaseError.reviewNotFound(id)
            }
        }
        return removedIDs
    }

    static func deleteEmptyWorkspaces(in db: Database) throws {
        try #sql(
            """
            DELETE FROM "review_workspaces"
            WHERE "cwd" NOT IN (SELECT "cwd" FROM "review_records")
            """
        ).execute(db)
    }

    private static func removals(
        from rows: [TerminalRow],
        maximumCount: Int,
        protecting protectedReviewID: String?
    ) -> Set<String> {
        let excess = max(0, rows.count - maximumCount)
        guard excess > 0 else {
            return []
        }
        return Set(
            rows.lazy
                .filter { $0.id != protectedReviewID }
                .prefix(excess)
                .map(\.id)
        )
    }
}
