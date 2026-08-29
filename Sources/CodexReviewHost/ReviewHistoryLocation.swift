import Darwin
import Foundation
import CodexReview
import CodexReviewPersistence

package final class ReviewHistoryLocation: Sendable {
    package static let applicationDirectoryName = "CodexReviewMonitor"
    package static let recoveryDirectoryName = "RecoveryV1"
    package static let databaseFileName = "review-history.sqlite"

    private let recoveryDirectory: DirectoryCapability

    private init(recoveryDirectory: DirectoryCapability) {
        self.recoveryDirectory = recoveryDirectory
    }

    package static func prepareProduction(
        applicationSupportDirectory: URL? = nil,
        ownerUserID: uid_t = geteuid()
    ) throws -> ReviewHistoryLocation {
        let applicationSupportDirectory = try applicationSupportDirectory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first.unwrap(or: DirectoryCapabilityError.invalidRequest(
                "The user Application Support directory is unavailable."
            ))
        let trustedRequirements = DirectoryCapability.Requirements.trustedAnchor(
            ownerUserID: ownerUserID
        )
        let applicationSupport = try DirectoryCapability.openExisting(
            at: applicationSupportDirectory,
            requirements: trustedRequirements
        )
        defer { try? applicationSupport.close() }

        let applicationDirectory = try applicationSupport.directory(
            named: .init(applicationDirectoryName),
            acquisition: .existingOrCreate,
            requirements: .managed(
                ownerUserID: ownerUserID,
                deviceID: applicationSupport.identity.deviceID
            )
        )
        defer { try? applicationDirectory.close() }

        let recoveryDirectory = try applicationDirectory.directory(
            named: .init(recoveryDirectoryName),
            acquisition: .existingOrCreate,
            requirements: .managed(
                ownerUserID: ownerUserID,
                deviceID: applicationDirectory.identity.deviceID
            )
        )
        return ReviewHistoryLocation(recoveryDirectory: recoveryDirectory)
    }

    package func databaseURL() throws -> URL {
        try recoveryDirectory.withRevalidatedPath {
            $0.appendingPathComponent(Self.databaseFileName, isDirectory: false)
        }
    }

    package func close() throws {
        try recoveryDirectory.close()
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> any Error) throws -> Wrapped {
        guard let self else {
            throw error()
        }
        return self
    }
}

package actor OwnedReviewHistoryPersistence: ReviewHistoryPersistence {
    private let database: ReviewHistoryDatabase
    private let location: ReviewHistoryLocation

    package init(location: ReviewHistoryLocation, databaseURL: URL) {
        self.location = location
        database = ReviewHistoryDatabase(databaseURL: databaseURL)
    }

    package func load(
        retentionPolicy: ReviewHistoryRetentionPolicy
    ) async throws -> [RestoredReviewRecord] {
        try await database.load(retentionPolicy: retentionPolicy)
    }

    package func recordStarted(_ record: StartedReviewRecord) async throws {
        try await database.recordStarted(record)
    }

    package func recordTerminal(
        _ record: TerminalReviewRecord,
        retentionPolicy: ReviewHistoryRetentionPolicy
    ) async throws -> ReviewHistoryMutationResult {
        try await database.recordTerminal(record, retentionPolicy: retentionPolicy)
    }

    package func saveOrdering(_ ordering: ReviewHistoryOrdering) async throws {
        try await database.saveOrdering(ordering)
    }

    package func deleteTerminalReview(
        id: String
    ) async throws -> ReviewHistoryMutationResult {
        try await database.deleteTerminalReview(id: id)
    }

    package func deleteAllTerminalReviews() async throws -> ReviewHistoryMutationResult {
        try await database.deleteAllTerminalReviews()
    }

    package func close() async throws {
        var databaseFailure: (any Error)?
        do {
            try await database.close()
        } catch {
            databaseFailure = error
        }

        var locationFailure: (any Error)?
        do {
            try location.close()
        } catch {
            locationFailure = error
        }

        if let databaseFailure {
            throw databaseFailure
        }
        if let locationFailure {
            throw locationFailure
        }
    }
}

package struct UnavailableReviewHistoryPersistence: ReviewHistoryPersistence {
    private struct Failure: LocalizedError, Sendable {
        let message: String

        var errorDescription: String? {
            message
        }
    }

    private let failure: Failure

    package init(_ error: any Error) {
        failure = Failure(message: error.localizedDescription)
    }

    package func load(
        retentionPolicy _: ReviewHistoryRetentionPolicy
    ) async throws -> [RestoredReviewRecord] {
        throw failure
    }

    package func recordStarted(_: StartedReviewRecord) async throws {
        throw failure
    }

    package func recordTerminal(
        _: TerminalReviewRecord,
        retentionPolicy _: ReviewHistoryRetentionPolicy
    ) async throws -> ReviewHistoryMutationResult {
        throw failure
    }

    package func saveOrdering(_: ReviewHistoryOrdering) async throws {
        throw failure
    }

    package func deleteTerminalReview(
        id _: String
    ) async throws -> ReviewHistoryMutationResult {
        throw failure
    }

    package func deleteAllTerminalReviews() async throws -> ReviewHistoryMutationResult {
        throw failure
    }

    package func close() async throws {
        throw failure
    }
}
