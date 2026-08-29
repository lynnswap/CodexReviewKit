import Darwin
import Foundation
import Testing
@testable import CodexReviewHost

@Suite("review history location")
struct ReviewHistoryLocationTests {
    @Test func productionLocationOwnsExactPrivateApplicationSupportDirectory() throws {
        let applicationSupport = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "review-history-location-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: false
        )
        #expect(chmod(applicationSupport.path, 0o700) == 0)
        defer { try? FileManager.default.removeItem(at: applicationSupport) }

        let location = try ReviewHistoryLocation.prepareProduction(
            applicationSupportDirectory: applicationSupport
        )
        defer { try? location.close() }

        let databaseURL = try location.databaseURL()
        let applicationDirectory = applicationSupport.appendingPathComponent(
            ReviewHistoryLocation.applicationDirectoryName,
            isDirectory: true
        )
        let recoveryDirectory = applicationDirectory.appendingPathComponent(
            ReviewHistoryLocation.recoveryDirectoryName,
            isDirectory: true
        )

        #expect(databaseURL == recoveryDirectory.appendingPathComponent(
            ReviewHistoryLocation.databaseFileName,
            isDirectory: false
        ))
        #expect(try permissions(at: applicationDirectory) == 0o700)
        #expect(try permissions(at: recoveryDirectory) == 0o700)
        #expect(FileManager.default.fileExists(atPath: databaseURL.path) == false)
    }

    @Test func closedLocationRejectsPathHandoff() throws {
        let applicationSupport = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "closed-review-history-location-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: false
        )
        #expect(chmod(applicationSupport.path, 0o700) == 0)
        defer { try? FileManager.default.removeItem(at: applicationSupport) }

        let location = try ReviewHistoryLocation.prepareProduction(
            applicationSupportDirectory: applicationSupport
        )
        try location.close()
        try location.close()

        do {
            _ = try location.databaseURL()
            Issue.record("A closed location unexpectedly handed off its database path.")
        } catch let error as DirectoryCapabilityError {
            #expect(error == .closed)
        }
    }

    private func permissions(at url: URL) throws -> mode_t {
        var status = stat()
        guard stat(url.path, &status) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return status.st_mode & 0o7777
    }
}
