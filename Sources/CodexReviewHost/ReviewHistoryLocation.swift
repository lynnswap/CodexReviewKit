import Darwin
import Foundation
import CodexReview
import CodexReviewPersistence

package struct ReviewHistoryLocationCloseError: LocalizedError, Sendable {
    package let failures: [String]

    package var errorDescription: String? {
        failures.joined(separator: "; ")
    }
}

package final class ReviewHistoryLocation: Sendable {
    package static let applicationDirectoryName = "CodexReviewMonitor"
    package static let recoveryDirectoryName = "RecoveryV1"
    package static let databaseFileName = "review-history.sqlite"

    private let applicationSupportDirectory: DirectoryCapability
    private let applicationDirectory: DirectoryCapability
    private let recoveryDirectory: DirectoryCapability

    private init(
        applicationSupportDirectory: DirectoryCapability,
        applicationDirectory: DirectoryCapability,
        recoveryDirectory: DirectoryCapability
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.applicationDirectory = applicationDirectory
        self.recoveryDirectory = recoveryDirectory
    }

    package static func prepareProduction(
        applicationSupportDirectory: URL? = nil,
        ownerUserID: uid_t = geteuid()
    ) throws -> ReviewHistoryLocation {
        let resolvedApplicationSupportDirectory: URL
        if let explicitApplicationSupportDirectory = applicationSupportDirectory {
            resolvedApplicationSupportDirectory = explicitApplicationSupportDirectory
        } else {
            guard let userApplicationSupportDirectory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw DirectoryCapabilityError.invalidRequest(
                    "The user Application Support directory is unavailable."
                )
            }
            resolvedApplicationSupportDirectory = userApplicationSupportDirectory
        }
        let trustedRequirements = DirectoryCapability.Requirements.trustedAnchor(
            ownerUserID: ownerUserID
        )
        let applicationSupport = try DirectoryCapability.openExisting(
            at: resolvedApplicationSupportDirectory,
            requirements: trustedRequirements
        )

        let applicationDirectory = try applicationSupport.directory(
            named: .init(applicationDirectoryName),
            acquisition: .existingOrCreate,
            requirements: .managed(
                ownerUserID: ownerUserID,
                deviceID: applicationSupport.identity.deviceID
            )
        )

        let recoveryDirectory = try applicationDirectory.directory(
            named: .init(recoveryDirectoryName),
            acquisition: .existingOrCreate,
            requirements: .managed(
                ownerUserID: ownerUserID,
                deviceID: applicationDirectory.identity.deviceID
            )
        )
        return ReviewHistoryLocation(
            applicationSupportDirectory: applicationSupport,
            applicationDirectory: applicationDirectory,
            recoveryDirectory: recoveryDirectory
        )
    }

    package func databaseURL() throws -> URL {
        try recoveryDirectory.withRevalidatedPath {
            $0.appendingPathComponent(Self.databaseFileName, isDirectory: false)
        }
    }

    package func close() throws {
        var failures: [String] = []
        for directory in [
            recoveryDirectory,
            applicationDirectory,
            applicationSupportDirectory,
        ] {
            do {
                try directory.close()
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if failures.isEmpty == false {
            throw ReviewHistoryLocationCloseError(failures: failures)
        }
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

    package func deleteTerminalReviews(
        withIDs ids: Set<String>
    ) async throws -> ReviewHistoryMutationResult {
        try await database.deleteTerminalReviews(withIDs: ids)
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

    package init(message: String) {
        failure = Failure(message: message)
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

    package func deleteTerminalReviews(
        withIDs _: Set<String>
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
