import Darwin
import Dispatch
import Foundation
import Testing
import CodexReviewHost

@Suite("directory capability")
struct DirectoryCapabilityTests {
    @Test func entryNamesRejectTraversalAndSeparators() {
        for value in ["", ".", "..", "a/b", "a\0b"] {
            expectDirectoryError(.invalidRequest) {
                _ = try DirectoryCapability.Name(value)
            }
        }
        #expect((try? DirectoryCapability.Name("valid-name")) != nil)
        expectDirectoryError(.invalidRequest) {
            _ = try DirectoryCapability.openExisting(
                at: URL(string: "relative")!,
                requirements: .trustedAnchor(ownerUserID: geteuid())
            )
        }
        expectDirectoryError(.invalidRequest) {
            _ = try DirectoryCapability.openExisting(
                at: URL(string: "http://:80/path")!,
                requirements: .trustedAnchor(ownerUserID: geteuid())
            )
        }
    }

    @Test func absoluteAndChildWalksRejectSymbolicLinks() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        let managed = managedRequirements(root)
        let real = try root.directory(
            named: try .init("real"),
            acquisition: .new,
            requirements: managed
        )
        defer { try? real.close() }
        let nested = try real.directory(
            named: try .init("nested"),
            acquisition: .new,
            requirements: managedRequirements(real)
        )
        defer { try? nested.close() }

        let linkURL = fixture.appendingPathComponent("link", isDirectory: true)
        #expect(symlink("real", linkURL.path) == 0)
        expectDirectoryError(.policyViolation) {
            _ = try root.directory(
                named: .init("link"),
                acquisition: .existing,
                requirements: managed
            )
        }
        expectDirectoryError(.policyViolation) {
            _ = try DirectoryCapability.openExisting(
                at: linkURL.appendingPathComponent("nested", isDirectory: true),
                requirements: managed
            )
        }
    }

    @Test func relationshipsUseDescriptorIdentity() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        let child = try root.directory(
            named: try .init("child"),
            acquisition: .new,
            requirements: managedRequirements(root)
        )
        defer { try? child.close() }
        let sameChild = try root.directory(
            named: try .init("child"),
            acquisition: .existing,
            requirements: managedRequirements(root)
        )
        defer { try? sameChild.close() }
        let grandchild = try child.directory(
            named: try .init("grandchild"),
            acquisition: .new,
            requirements: managedRequirements(child)
        )
        defer { try? grandchild.close() }
        let sibling = try root.directory(
            named: try .init("sibling"),
            acquisition: .new,
            requirements: managedRequirements(root)
        )
        defer { try? sibling.close() }

        #expect(try child.relationship(to: sameChild) == .same)
        #expect(try root.relationship(to: grandchild) == .ancestor)
        #expect(try grandchild.relationship(to: root) == .descendant)
        #expect(try child.relationship(to: sibling) == .disjoint)
    }

    @Test func firmlinkAliasesResolveToOneIdentity() throws {
        let users = try DirectoryCapability.openExisting(
            at: URL(fileURLWithPath: "/Users", isDirectory: true),
            requirements: .trustedAnchor(ownerUserID: 0)
        )
        defer { try? users.close() }
        let dataUsers = try DirectoryCapability.openExisting(
            at: URL(fileURLWithPath: "/System/Volumes/Data/Users", isDirectory: true),
            requirements: .trustedAnchor(ownerUserID: 0)
        )
        defer { try? dataUsers.close() }

        #expect(users.identity == dataUsers.identity)
        #expect(try users.relationship(to: dataUsers) == .same)
    }

    @Test func createReopensAndExistingOrCreatePreservesIdentity() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        let requirements = managedRequirements(root)
        let first = try root.directory(
            named: try .init("managed"),
            acquisition: .existingOrCreate,
            requirements: requirements
        )
        defer { try? first.close() }
        let reopened = try root.directory(
            named: try .init("managed"),
            acquisition: .existingOrCreate,
            requirements: requirements
        )
        defer { try? reopened.close() }

        #expect(first.identity == reopened.identity)
        #expect(try permissions(at: fixture.appendingPathComponent("managed")) == 0o700)
        expectDirectoryError(.policyViolation) {
            _ = try root.directory(
                named: .init("managed"),
                acquisition: .new,
                requirements: requirements
            )
        }
    }

    @Test func existingDirectoriesAreValidatedWithoutPermissionMutation() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        for (name, mode): (String, mode_t) in [("shared", 0o750), ("special", 0o1700)] {
            let existingURL = fixture.appendingPathComponent(name, isDirectory: true)
            try createDirectory(existingURL, permissions: mode)
            expectDirectoryError(.policyViolation) {
                _ = try root.directory(
                    named: .init(name),
                    acquisition: .existing,
                    requirements: managedRequirements(root)
                )
            }
            #expect(try permissions(at: existingURL) == mode)
        }
    }

    @Test func ownerDeviceAndACLPoliciesFailClosed() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        let child = try root.directory(
            named: try .init("child"),
            acquisition: .new,
            requirements: managedRequirements(root)
        )
        try child.close()

        expectDirectoryError(.policyViolation) {
            _ = try root.directory(
                named: .init("child"),
                acquisition: .existing,
                requirements: .managed(
                    ownerUserID: geteuid() &+ 1,
                    deviceID: root.identity.deviceID
                )
            )
        }
        expectDirectoryError(.policyViolation) {
            _ = try root.directory(
                named: .init("child"),
                acquisition: .existing,
                requirements: .managed(
                    ownerUserID: geteuid(),
                    deviceID: root.identity.deviceID &+ 1
                )
            )
        }
        let rollbackURL = fixture.appendingPathComponent("rollback", isDirectory: true)
        expectDirectoryError(.policyViolation) {
            _ = try root.directory(
                named: .init("rollback"),
                acquisition: .new,
                requirements: .managed(
                    ownerUserID: geteuid(),
                    deviceID: root.identity.deviceID &+ 1
                )
            )
        }
        #expect(FileManager.default.fileExists(atPath: rollbackURL.path) == false)

        let childURL = fixture.appendingPathComponent("child", isDirectory: true)
        try addAllowACL(to: childURL)
        expectDirectoryError(.policyViolation) {
            _ = try root.directory(
                named: .init("child"),
                acquisition: .existing,
                requirements: managedRequirements(root)
            )
        }
    }

    @Test func descriptorMutationSurvivesPathSwapButHandoffRejectsIt() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        let child = try root.directory(
            named: try .init("child"),
            acquisition: .new,
            requirements: managedRequirements(root)
        )
        defer { try? child.close() }
        let childURL = fixture.appendingPathComponent("child", isDirectory: true)
        let movedURL = fixture.appendingPathComponent("moved", isDirectory: true)
        try child.withRevalidatedPath { #expect($0 == childURL) }
        try FileManager.default.moveItem(at: childURL, to: movedURL)
        try createDirectory(childURL, permissions: 0o700)

        let nested = try child.directory(
            named: try .init("nested"),
            acquisition: .new,
            requirements: managedRequirements(child)
        )
        defer { try? nested.close() }
        #expect(FileManager.default.fileExists(
            atPath: movedURL.appendingPathComponent("nested").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: childURL.appendingPathComponent("nested").path
        ) == false)
        expectDirectoryError(.policyViolation) {
            try child.withRevalidatedPath { _ in }
        }
    }

    @Test func missingDirectoryUsesUserActionError() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        expectDirectoryError(.userActionRequired) {
            _ = try root.directory(
                named: .init("missing"),
                acquisition: .existing,
                requirements: managedRequirements(root)
            )
        }
    }

    @Test func regularFileReadDistinguishesMissingAndEnforcesBound() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        let name = try DirectoryCapability.Name("payload")

        #expect(try root.readFile(named: name, maximumByteCount: 8) == nil)
        expectDirectoryError(.invalidRequest) {
            _ = try root.readFile(named: name, maximumByteCount: -1)
        }

        let contents = Data(repeating: 0x5A, count: 64 * 1024 + 7)
        try contents.write(to: fixture.appendingPathComponent("payload"))
        #expect(try root.readFile(named: name, maximumByteCount: contents.count + 1) == contents)
        #expect(try root.readFile(named: name, maximumByteCount: contents.count) == contents)
        expectDirectoryError(.policyViolation) {
            _ = try root.readFile(named: name, maximumByteCount: contents.count - 1)
        }

        try Data().write(to: fixture.appendingPathComponent("empty"))
        #expect(try root.readFile(named: .init("empty"), maximumByteCount: 0) == Data())
    }

    @Test func regularFileReadRejectsSymbolicLinksAndNonregularEntries() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        let targetContents = Data("unchanged".utf8)
        try targetContents.write(to: fixture.appendingPathComponent("target"))
        #expect(symlink("target", fixture.appendingPathComponent("link").path) == 0)
        try createDirectory(fixture.appendingPathComponent("directory"), permissions: 0o700)
        #expect(mkfifo(fixture.appendingPathComponent("fifo").path, 0o600) == 0)

        for value in ["link", "directory", "fifo"] {
            let name = try DirectoryCapability.Name(value)
            expectDirectoryError(.policyViolation) {
                _ = try root.readFile(named: name, maximumByteCount: 32)
            }
        }
        #expect(try Data(contentsOf: fixture.appendingPathComponent("target")) == targetContents)
    }

    @Test func replacementPublishesOneNewRegularFileWithBoundedChunkedContents() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        let destination = fixture.appendingPathComponent("payload")
        let original = Data("original".utf8)
        try original.write(to: destination)
        let originalHandle = try FileHandle(forReadingFrom: destination)
        defer { try? originalHandle.close() }
        let originalIdentity = try fileIdentity(at: destination)
        let replacement = Data(repeating: 0xA5, count: 64 * 1024 + 7)

        try root.replaceFile(
            named: .init("payload"),
            with: replacement,
            maximumByteCount: replacement.count
        )

        #expect(try originalHandle.readToEnd() == original)
        #expect(try fileIdentity(at: destination) != originalIdentity)
        #expect(try Data(contentsOf: destination) == replacement)
        #expect(try permissions(at: destination) == 0o600)
        #expect(try replacementTemporaryNames(in: fixture).isEmpty)
    }

    @Test func replacementBoundsFailBeforeMutationAndPreserveDestination() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        let destination = fixture.appendingPathComponent("payload")
        let original = Data("unchanged".utf8)
        try original.write(to: destination)

        expectDirectoryError(.invalidRequest) {
            try root.replaceFile(
                named: .init("payload"),
                with: Data("too large".utf8),
                maximumByteCount: 3
            )
        }
        expectDirectoryError(.invalidRequest) {
            try root.replaceFile(named: .init("payload"), with: Data(), maximumByteCount: -1)
        }

        #expect(try Data(contentsOf: destination) == original)
        #expect(try replacementTemporaryNames(in: fixture).isEmpty)
    }

    @Test func replacementFailureRemovesOnlyItsTemporaryFileAndPreservesDestination() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        let destination = fixture.appendingPathComponent("payload")
        let original = Data("unchanged".utf8)
        try original.write(to: destination)
        #expect(chflags(destination.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(destination.path, 0) }

        expectDirectoryError(.userActionRequired) {
            try root.replaceFile(
                named: .init("payload"),
                with: Data("replacement".utf8),
                maximumByteCount: 32
            )
        }

        #expect(try Data(contentsOf: destination) == original)
        #expect(try replacementTemporaryNames(in: fixture).isEmpty)
    }

    @Test func replacementRejectsSymlinkAndNonregularDestinationsWithoutTemporaryFiles() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        let targetContents = Data("unchanged".utf8)
        try targetContents.write(to: fixture.appendingPathComponent("target"))
        #expect(symlink("target", fixture.appendingPathComponent("link").path) == 0)
        try createDirectory(fixture.appendingPathComponent("directory"), permissions: 0o700)
        #expect(mkfifo(fixture.appendingPathComponent("fifo").path, 0o600) == 0)

        for value in ["link", "directory", "fifo"] {
            expectDirectoryError(.policyViolation) {
                try root.replaceFile(
                    named: .init(value),
                    with: Data("replacement".utf8),
                    maximumByteCount: 32
                )
            }
        }

        #expect(try Data(contentsOf: fixture.appendingPathComponent("target")) == targetContents)
        #expect(try replacementTemporaryNames(in: fixture).isEmpty)
    }

    @Test func closeIsIdempotentAndRejectsLaterOperations() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        try root.close()
        try root.close()
        expectDirectoryError(.closed) {
            try root.withRevalidatedPath { _ in }
        }
        expectDirectoryError(.closed) {
            _ = try root.readFile(named: .init("file"), maximumByteCount: 0)
        }
        expectDirectoryError(.closed) {
            try root.replaceFile(named: .init("file"), with: Data(), maximumByteCount: 0)
        }
    }

    @Test func borrowedOperationCompletesAcrossClose() async throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        let release = DispatchSemaphore(value: 0)
        let (entries, entryContinuation) = AsyncStream.makeStream(of: Void.self)
        let operation = Task {
            await withCheckedContinuation { completion in
                DispatchQueue.global().async {
                    let result: RaceResult
                    do {
                        try root.withRevalidatedPath { _ in
                            entryContinuation.yield()
                            release.wait()
                        }
                        result = .success
                    } catch {
                        result = .unexpected(error.localizedDescription)
                    }
                    entryContinuation.finish()
                    completion.resume(returning: result)
                }
            }
        }
        for await _ in entries { break }
        try root.close()
        release.signal()
        #expect(await operation.value == .success)
        expectDirectoryError(.closed) {
            try root.withRevalidatedPath { _ in }
        }
        try root.close()
    }
}

private enum ExpectedError { case invalidRequest, policyViolation, userActionRequired, closed }

private enum RaceResult: Equatable, Sendable { case success, unexpected(String) }

private enum FixtureError: Error { case unableToCreateTemporaryDirectory, commandFailed }

private struct FileIdentity: Equatable {
    let deviceID: UInt64
    let inode: UInt64
}

private func expectDirectoryError(
    _ expected: ExpectedError,
    operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected DirectoryCapabilityError.\(expected).")
    } catch let error as DirectoryCapabilityError {
        let matches: Bool
        switch (expected, error) {
        case (.invalidRequest, .invalidRequest),
             (.policyViolation, .policyViolation),
             (.userActionRequired, .userActionRequired),
             (.closed, .closed):
            matches = true
        default:
            matches = false
        }
        #expect(matches, "Unexpected error: \(error.localizedDescription)")
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

private func makePrivateTemporaryDirectory() throws -> URL {
    var template = Array("/private/tmp/codex-directory-capability.XXXXXX".utf8CString)
    let path = template.withUnsafeMutableBufferPointer { buffer -> String? in
        guard let pointer = mkdtemp(buffer.baseAddress) else { return nil }
        return String(cString: pointer)
    }
    guard let path else { throw FixtureError.unableToCreateTemporaryDirectory }
    return URL(fileURLWithPath: path, isDirectory: true)
}

private func openFixtureRoot(_ url: URL) throws -> DirectoryCapability {
    try DirectoryCapability.openExisting(
        at: url,
        requirements: .trustedAnchor(ownerUserID: geteuid())
    )
}

private func managedRequirements(
    _ parent: DirectoryCapability
) -> DirectoryCapability.Requirements {
    .managed(ownerUserID: geteuid(), deviceID: parent.identity.deviceID)
}

private func createDirectory(_ url: URL, permissions: mode_t) throws {
    guard mkdir(url.path, permissions) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    guard chmod(url.path, permissions) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
}

private func permissions(at url: URL) throws -> mode_t {
    var status = stat()
    guard stat(url.path, &status) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    return status.st_mode & 0o7777
}

private func fileIdentity(at url: URL) throws -> FileIdentity {
    var status = stat()
    guard stat(url.path, &status) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    return FileIdentity(
        deviceID: UInt64(bitPattern: Int64(status.st_dev)),
        inode: UInt64(status.st_ino)
    )
}

private func replacementTemporaryNames(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
        $0.hasPrefix(".codex-replace-")
    }
}

private func addAllowACL(to url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = ["+a", "everyone allow read", url.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw FixtureError.commandFailed }
}

private func removeFixture(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}
