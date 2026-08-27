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

    @Test func resolvedLocationsRetainMissingEntryChainsWithoutCreation() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let requirements = DirectoryCapability.Requirements.trustedAnchor(ownerUserID: geteuid())
        let missingURL = fixture.appendingPathComponent("missing", isDirectory: true)
        let same = try DirectoryCapability.resolveLocation(at: missingURL, requirements: requirements)
        defer { try? same.close() }
        let alias = try DirectoryCapability.resolveLocation(at: missingURL, requirements: requirements)
        defer { try? alias.close() }
        let descendant = try DirectoryCapability.resolveLocation(
            at: missingURL.appendingPathComponent("child", isDirectory: true),
            requirements: requirements
        )
        defer { try? descendant.close() }
        let sibling = try DirectoryCapability.resolveLocation(
            at: fixture.appendingPathComponent("sibling", isDirectory: true),
            requirements: requirements
        )
        defer { try? sibling.close() }

        #expect(try same.relationship(to: alias) == .same)
        #expect(try same.relationship(to: descendant) == .ancestor)
        #expect(try descendant.relationship(to: same) == .descendant)
        #expect(try same.relationship(to: sibling) == .disjoint)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.path).isEmpty)
    }

    @Test func resolvedLocationsUseExistingIdentityAndAncestry() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        let child = try root.directory(
            named: .init("child"),
            acquisition: .new,
            requirements: managedRequirements(root)
        )
        let grandchild = try child.directory(
            named: .init("grandchild"),
            acquisition: .new,
            requirements: managedRequirements(child)
        )
        try grandchild.close()
        try child.close()
        let managed = managedRequirements(root)
        let childLocation = try DirectoryCapability.resolveLocation(
            at: fixture.appendingPathComponent("child", isDirectory: true),
            requirements: managed
        )
        defer { try? childLocation.close() }
        let grandchildLocation = try DirectoryCapability.resolveLocation(
            at: fixture.appendingPathComponent("child/grandchild", isDirectory: true),
            requirements: managed
        )
        defer { try? grandchildLocation.close() }

        #expect(try childLocation.relationship(to: grandchildLocation) == .ancestor)
        #expect(try grandchildLocation.relationship(to: childLocation) == .descendant)
    }

    @Test func partiallyResolvedLocationsFailClosedAfterNamespaceMutation() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let requirements = DirectoryCapability.Requirements.trustedAnchor(ownerUserID: geteuid())
        let ancestorURL = fixture.appendingPathComponent("appeared", isDirectory: true)
        let pending = try DirectoryCapability.resolveLocation(
            at: ancestorURL.appendingPathComponent("child", isDirectory: true),
            requirements: requirements
        )
        defer { try? pending.close() }
        try createDirectory(ancestorURL, permissions: 0o700)
        let appeared = try DirectoryCapability.resolveLocation(
            at: ancestorURL,
            requirements: requirements
        )
        defer { try? appeared.close() }

        #expect(try pending.relationship(to: appeared) == .indeterminate)
        #expect(try appeared.relationship(to: pending) == .indeterminate)
    }

    @Test func resolvedEntryNamesUseDescriptorScopedCaseAndUnicodeSemantics() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let requirements = DirectoryCapability.Requirements.trustedAnchor(ownerUserID: geteuid())
        let upper = try DirectoryCapability.resolveLocation(
            at: fixture.appendingPathComponent("Pending", isDirectory: true),
            requirements: requirements
        )
        defer { try? upper.close() }
        let lower = try DirectoryCapability.resolveLocation(
            at: fixture.appendingPathComponent("pending", isDirectory: true),
            requirements: requirements
        )
        defer { try? lower.close() }
        let sensitivity = try directoryCaseSensitivity(at: fixture)
        let expectedCaseRelationship: DirectoryCapability.Relationship = switch sensitivity {
        case true: .disjoint
        case false: .same
        case nil: .indeterminate
        }
        #expect(try upper.relationship(to: lower) == expectedCaseRelationship)

        let composedName = "Caf\u{00E9}"
        let composed = try DirectoryCapability.resolveLocation(
            at: fixture.appendingPathComponent(composedName, isDirectory: true),
            requirements: requirements
        )
        defer { try? composed.close() }
        let decomposed = try DirectoryCapability.resolveLocation(
            at: fixture.appendingPathComponent(
                composedName.decomposedStringWithCanonicalMapping,
                isDirectory: true
            ),
            requirements: requirements
        )
        defer { try? decomposed.close() }
        #expect(try composed.relationship(to: decomposed) == .same)

        let nonASCIIUpper = try DirectoryCapability.resolveLocation(
            at: fixture.appendingPathComponent("\u{00C6}ther", isDirectory: true),
            requirements: requirements
        )
        defer { try? nonASCIIUpper.close() }
        let nonASCIILower = try DirectoryCapability.resolveLocation(
            at: fixture.appendingPathComponent("\u{00E6}ther", isDirectory: true),
            requirements: requirements
        )
        defer { try? nonASCIILower.close() }
        #expect(try nonASCIIUpper.relationship(to: nonASCIILower) == (
            sensitivity == true ? .disjoint : .indeterminate
        ))
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

        let usersLocation = try DirectoryCapability.resolveLocation(
            at: URL(fileURLWithPath: "/Users", isDirectory: true),
            requirements: .trustedAnchor(ownerUserID: 0)
        )
        defer { try? usersLocation.close() }
        let dataUsersLocation = try DirectoryCapability.resolveLocation(
            at: URL(fileURLWithPath: "/System/Volumes/Data/Users", isDirectory: true),
            requirements: .trustedAnchor(ownerUserID: 0)
        )
        defer { try? dataUsersLocation.close() }
        #expect(try usersLocation.relationship(to: dataUsersLocation) == .same)
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

    @Test func optionalAbsoluteOpenTreatsOnlyENOENTAsAbsence() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let requirements = DirectoryCapability.Requirements.trustedAnchor(ownerUserID: geteuid())
        let candidate = try DirectoryCapability.openExistingIfPresent(
            at: fixture,
            requirements: requirements
        )
        let opened = try #require(candidate)
        defer { try? opened.close() }
        let fixtureIdentity = try fileIdentity(at: fixture)
        #expect(opened.identity.deviceID == fixtureIdentity.deviceID)
        #expect(opened.identity.inode == fixtureIdentity.inode)

        #expect(try DirectoryCapability.openExistingIfPresent(
            at: fixture.appendingPathComponent("missing", isDirectory: true),
            requirements: requirements
        ) == nil)
        try Data().write(to: fixture.appendingPathComponent("file"))
        #expect(symlink("missing", fixture.appendingPathComponent("link").path) == 0)
        for name in ["file", "link"] {
            expectDirectoryError(.policyViolation) {
                _ = try DirectoryCapability.openExistingIfPresent(
                    at: fixture.appendingPathComponent(name, isDirectory: true),
                    requirements: requirements
                )
            }
        }
        expectDirectoryError(.policyViolation) {
            _ = try DirectoryCapability.openExistingIfPresent(
                at: fixture,
                requirements: .trustedAnchor(ownerUserID: geteuid() == 0 ? 1 : 0)
            )
        }
    }

    @Test func createFileIfMissingCreates0600AndPreservesExistingRegularFile() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        let name = try DirectoryCapability.Name("app-server-state")
        let fileURL = fixture.appendingPathComponent("app-server-state")

        try root.createFileIfMissing(named: name)
        #expect(try Data(contentsOf: fileURL).isEmpty)
        #expect(try permissions(at: fileURL) == 0o600)

        let contents = Data("preserve me".utf8)
        try contents.write(to: fileURL)
        #expect(chmod(fileURL.path, 0o640) == 0)
        let identity = try fileIdentity(at: fileURL)
        try root.createFileIfMissing(named: name)

        #expect(try Data(contentsOf: fileURL) == contents)
        #expect(try permissions(at: fileURL) == 0o640)
        #expect(try fileIdentity(at: fileURL) == identity)
    }

    @Test func leafCreationAndRemovalRejectSymlinksAndNonregularEntries() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        let targetContents = Data("unchanged".utf8)
        try targetContents.write(to: fixture.appendingPathComponent("target"))
        #expect(symlink("target", fixture.appendingPathComponent("link").path) == 0)
        try createDirectory(fixture.appendingPathComponent("directory"), permissions: 0o700)
        #expect(mkfifo(fixture.appendingPathComponent("fifo").path, 0o600) == 0)
        let socketDescriptor = try bindUnixSocket(
            at: fixture.appendingPathComponent("socket").path
        )
        defer { _ = Darwin.close(socketDescriptor) }

        for value in ["link", "directory", "fifo", "socket"] {
            let name = try DirectoryCapability.Name(value)
            expectDirectoryError(.policyViolation) {
                try root.createFileIfMissing(named: name)
            }
            expectDirectoryError(.policyViolation) {
                try root.removeFile(named: name)
            }
        }
        #expect(try Data(contentsOf: fixture.appendingPathComponent("target")) == targetContents)
    }

    @Test func regularFileRemovalIsAbsentAwareAndChangesOnlyTheNamedIdentity() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        try root.removeFile(named: .init("missing"))

        let fileURL = fixture.appendingPathComponent("auth.json")
        let contents = Data("authenticated".utf8)
        try contents.write(to: fileURL)
        let identity = try fileIdentity(at: fileURL)
        let openHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? openHandle.close() }

        try root.removeFile(named: .init("auth.json"))
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
        #expect(try openHandle.readToEnd() == contents)

        try Data("replacement".utf8).write(to: fileURL)
        #expect(try fileIdentity(at: fileURL) != identity)
    }

    @Test func leafMutationsRemainAnchoredToTheCapabilityIdentityAfterPathSwap() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        let child = try root.directory(
            named: .init("child"),
            acquisition: .new,
            requirements: managedRequirements(root)
        )
        defer { try? child.close() }
        let childURL = fixture.appendingPathComponent("child", isDirectory: true)
        let movedURL = fixture.appendingPathComponent("moved", isDirectory: true)
        try Data("original".utf8).write(to: childURL.appendingPathComponent("remove"))
        try FileManager.default.moveItem(at: childURL, to: movedURL)
        try createDirectory(childURL, permissions: 0o700)
        try Data("replacement".utf8).write(to: childURL.appendingPathComponent("remove"))

        try child.createFileIfMissing(named: .init("created"))
        try child.removeFile(named: .init("remove"))

        #expect(FileManager.default.fileExists(
            atPath: movedURL.appendingPathComponent("created").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: movedURL.appendingPathComponent("remove").path
        ) == false)
        #expect(try Data(contentsOf: childURL.appendingPathComponent("remove")) == Data("replacement".utf8))
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
        let socketDescriptor = try bindUnixSocket(
            at: fixture.appendingPathComponent("socket").path
        )
        defer { _ = Darwin.close(socketDescriptor) }

        for value in ["link", "directory", "fifo", "socket"] {
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
        let socketDescriptor = try bindUnixSocket(
            at: fixture.appendingPathComponent("socket").path
        )
        defer { _ = Darwin.close(socketDescriptor) }

        for value in ["link", "directory", "fifo", "socket"] {
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

    @Test func recursiveRemovalDeletesNestedTreesWithoutFollowingSymbolicLinks() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        let victim = try root.directory(
            named: try .init("victim"),
            acquisition: .new,
            requirements: managedRequirements(root)
        )
        let victimIdentity = victim.identity
        try victim.close()
        let victimURL = fixture.appendingPathComponent("victim", isDirectory: true)
        let nestedURL = victimURL.appendingPathComponent("nested", isDirectory: true)
        try createDirectory(nestedURL, permissions: 0o700)
        try Data("payload".utf8).write(to: nestedURL.appendingPathComponent("file"))
        let externalURL = fixture.appendingPathComponent("external")
        let externalContents = Data("preserved".utf8)
        try externalContents.write(to: externalURL)
        #expect(symlink(externalURL.path, nestedURL.appendingPathComponent("link").path) == 0)

        try root.removeDirectoryRecursively(
            named: .init("victim"),
            expectedIdentity: victimIdentity
        )

        #expect(FileManager.default.fileExists(atPath: victimURL.path) == false)
        #expect(try Data(contentsOf: externalURL) == externalContents)
    }

    @Test func recursiveRemovalNoOpsOnlyForAnAbsentRootAndRejectsConflicts() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        try root.removeDirectoryRecursively(
            named: .init("absent"),
            expectedIdentity: root.identity
        )
        let victim = try root.directory(
            named: try .init("victim"),
            acquisition: .new,
            requirements: managedRequirements(root)
        )
        let victimIdentity = victim.identity
        try victim.close()

        expectDirectoryError(.policyViolation) {
            try root.removeDirectoryRecursively(
                named: .init("victim"),
                expectedIdentity: root.identity
            )
        }
        let victimURL = fixture.appendingPathComponent("victim", isDirectory: true)
        try FileManager.default.removeItem(at: victimURL)
        let externalURL = fixture.appendingPathComponent("external")
        try Data("preserved".utf8).write(to: externalURL)
        #expect(symlink(externalURL.path, victimURL.path) == 0)
        expectDirectoryError(.policyViolation) {
            try root.removeDirectoryRecursively(
                named: .init("victim"),
                expectedIdentity: victimIdentity
            )
        }
        #expect(try Data(contentsOf: externalURL) == Data("preserved".utf8))
    }

    @Test func recursiveRemovalRejectsUnsupportedDescendantEntries() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        let victim = try root.directory(
            named: try .init("victim"),
            acquisition: .new,
            requirements: managedRequirements(root)
        )
        let victimIdentity = victim.identity
        try victim.close()
        let victimURL = fixture.appendingPathComponent("victim", isDirectory: true)
        let fifoURL = victimURL.appendingPathComponent("fifo")
        #expect(mkfifo(fifoURL.path, 0o600) == 0)

        let error = captureDirectoryError {
            try root.removeDirectoryRecursively(
                named: .init("victim"),
                expectedIdentity: victimIdentity
            )
        }

        guard case .policyViolation(let message) = error else {
            Issue.record("Expected an unsupported-entry policy violation.")
            return
        }
        #expect(message.contains(fifoURL.path))
        #expect(FileManager.default.fileExists(atPath: fifoURL.path))
    }

    @Test func recursiveRemovalReportsPartialFailureAfterCompletedDescendantMutation() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        let victim = try root.directory(
            named: try .init("victim"),
            acquisition: .new,
            requirements: managedRequirements(root)
        )
        let victimIdentity = victim.identity
        try victim.close()
        let victimURL = fixture.appendingPathComponent("victim", isDirectory: true)
        let childURL = victimURL.appendingPathComponent("child", isDirectory: true)
        try createDirectory(childURL, permissions: 0o700)
        let removedBeforeFailureURL = childURL.appendingPathComponent("removed-before-failure")
        try Data().write(to: removedBeforeFailureURL)
        try addDenyDeleteChildACL(to: victimURL)
        defer { try? removeFirstACL(from: victimURL) }

        let error = captureDirectoryError {
            try root.removeDirectoryRecursively(
                named: .init("victim"),
                expectedIdentity: victimIdentity
            )
        }

        guard case .userActionRequired(let failure) = error else {
            Issue.record("Expected a recursive-removal POSIX failure.")
            return
        }
        #expect(failure.path == childURL.path)
        #expect(FileManager.default.fileExists(atPath: victimURL.path))
        #expect(FileManager.default.fileExists(atPath: childURL.path))
        #expect(FileManager.default.fileExists(atPath: removedBeforeFailureURL.path) == false)
    }

    @Test func recursiveRemovalRejectsPreAdmissionRootIdentitySwap() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        let victim = try root.directory(
            named: try .init("victim"),
            acquisition: .new,
            requirements: managedRequirements(root)
        )
        let victimIdentity = victim.identity
        try victim.close()
        let victimURL = fixture.appendingPathComponent("victim", isDirectory: true)
        let movedURL = fixture.appendingPathComponent("moved", isDirectory: true)
        guard rename(victimURL.path, movedURL.path) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        try createDirectory(victimURL, permissions: 0o700)
        let replacementIdentity = try fileIdentity(at: victimURL)

        expectDirectoryError(.policyViolation) {
            try root.removeDirectoryRecursively(
                named: .init("victim"),
                expectedIdentity: victimIdentity
            )
        }
        #expect(try fileIdentity(at: victimURL) == replacementIdentity)
        #expect(replacementIdentity.inode != victimIdentity.inode)
        #expect(FileManager.default.fileExists(atPath: movedURL.path))
    }

    @Test func recursiveRemovalBoundsDescriptorsIndependentlyOfDepth() throws {
        if ProcessInfo.processInfo.environment[descriptorLimitChildEnvironmentKey] == nil {
            try runDescriptorLimitTestInSubprocess()
            return
        }
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        defer { try? root.close() }
        let victim = try root.directory(
            named: try .init("victim"),
            acquisition: .new,
            requirements: managedRequirements(root)
        )
        let victimIdentity = victim.identity
        let victimURL = fixture.appendingPathComponent("victim", isDirectory: true)
        let limit = try reduceOpenFileLimit()
        defer { restoreOpenFileLimit(limit.original) }
        let depth = max(Int(limit.reducedSoftLimit) + 16, 512)
        var current = victim
        for _ in 0..<depth {
            let child = try current.directory(
                named: .init("d"),
                acquisition: .new,
                requirements: managedRequirements(current)
            )
            try current.close()
            current = child
        }
        try current.close()

        try root.removeDirectoryRecursively(
            named: .init("victim"),
            expectedIdentity: victimIdentity
        )
        #expect(FileManager.default.fileExists(atPath: victimURL.path) == false)
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
        expectDirectoryError(.closed) {
            try root.createFileIfMissing(named: .init("file"))
        }
        expectDirectoryError(.closed) {
            try root.removeFile(named: .init("file"))
        }
        expectDirectoryError(.closed) {
            try root.removeDirectoryRecursively(
                named: .init("directory"),
                expectedIdentity: root.identity
            )
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

    @Test func leafOperationsRaceCloseWithoutUsingAClosedOrReusedDescriptor() async throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let root = try openFixtureRoot(fixture)
        let workerCount = 32
        for index in 0..<workerCount where index.isMultiple(of: 2) == false {
            try Data().write(to: fixture.appendingPathComponent("leaf-\(index)"))
        }
        let release = DispatchSemaphore(value: 0)
        let (entries, entryContinuation) = AsyncStream.makeStream(of: Void.self)
        let operations = (0..<workerCount).map { index in
            Task {
                await withCheckedContinuation { completion in
                    DispatchQueue.global().async {
                        entryContinuation.yield()
                        release.wait()
                        let result: RaceResult
                        do {
                            let name = try DirectoryCapability.Name("leaf-\(index)")
                            if index.isMultiple(of: 2) {
                                try root.createFileIfMissing(named: name)
                            } else {
                                try root.removeFile(named: name)
                            }
                            result = .success
                        } catch DirectoryCapabilityError.closed {
                            result = .closed
                        } catch {
                            result = .unexpected(error.localizedDescription)
                        }
                        completion.resume(returning: result)
                    }
                }
            }
        }
        var enteredCount = 0
        for await _ in entries {
            enteredCount += 1
            if enteredCount == workerCount { break }
        }
        for _ in 0..<workerCount { release.signal() }
        try root.close()
        for operation in operations {
            let result = await operation.value
            #expect(result == .success || result == .closed, "Unexpected result: \(result)")
        }
        entryContinuation.finish()
        try root.close()
    }

    @Test func resolvedLocationCloseIsIdempotentAndRejectsLaterRelationships() throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let requirements = DirectoryCapability.Requirements.trustedAnchor(ownerUserID: geteuid())
        let location = try DirectoryCapability.resolveLocation(
            at: fixture.appendingPathComponent("missing", isDirectory: true),
            requirements: requirements
        )
        let peer = try DirectoryCapability.resolveLocation(
            at: fixture.appendingPathComponent("peer", isDirectory: true),
            requirements: requirements
        )
        defer { try? peer.close() }

        try location.close()
        try location.close()
        expectDirectoryError(.closed) {
            _ = try location.relationship(to: peer)
        }
    }

    @Test func resolvedLocationRelationshipsRaceCloseWithoutDescriptorReuse() async throws {
        let fixture = try makePrivateTemporaryDirectory()
        defer { removeFixture(fixture) }
        let requirements = DirectoryCapability.Requirements.trustedAnchor(ownerUserID: geteuid())
        let location = try DirectoryCapability.resolveLocation(
            at: fixture.appendingPathComponent("missing", isDirectory: true),
            requirements: requirements
        )
        let peer = try DirectoryCapability.resolveLocation(
            at: fixture.appendingPathComponent("peer", isDirectory: true),
            requirements: requirements
        )
        defer { try? peer.close() }
        let operations = (0..<32).map { _ in
            Task {
                do {
                    _ = try location.relationship(to: peer)
                    return RaceResult.success
                } catch DirectoryCapabilityError.closed {
                    return RaceResult.closed
                } catch {
                    return RaceResult.unexpected(error.localizedDescription)
                }
            }
        }

        try location.close()
        for operation in operations {
            let result = await operation.value
            #expect(result == .success || result == .closed, "Unexpected result: \(result)")
        }
        try location.close()
    }
}

private enum ExpectedError { case invalidRequest, policyViolation, userActionRequired, closed }

private enum RaceResult: Equatable, Sendable { case success, closed, unexpected(String) }

private enum FixtureError: Error {
    case unableToCreateTemporaryDirectory
    case commandFailed
}

private let descriptorLimitChildEnvironmentKey = "CODEX_RECURSIVE_REMOVAL_RLIMIT_CHILD"

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

private func captureDirectoryError(
    operation: () throws -> Void
) -> DirectoryCapabilityError? {
    do {
        try operation()
        Issue.record("Expected DirectoryCapabilityError.")
        return nil
    } catch let error as DirectoryCapabilityError {
        return error
    } catch {
        Issue.record("Unexpected error type: \(error)")
        return nil
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

private func directoryCaseSensitivity(at url: URL) throws -> Bool? {
    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    defer { _ = close(descriptor) }
    errno = 0
    let value = fpathconf(descriptor, _PC_CASE_SENSITIVE)
    if value == -1 {
        guard errno == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return nil
    }
    if value == 0 { return false }
    if value == 1 { return true }
    return nil
}

private func createDirectory(_ url: URL, permissions: mode_t) throws {
    guard mkdir(url.path, permissions) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    guard chmod(url.path, permissions) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
}

private func reduceOpenFileLimit() throws -> (original: rlimit, reducedSoftLimit: rlim_t) {
    var original = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &original) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    let openDescriptorCount = (0..<4_096).reduce(into: 0) { count, descriptor in
        if fcntl(Int32(descriptor), F_GETFD) >= 0 { count += 1 }
    }
    let reducedSoftLimit = min(original.rlim_cur, rlim_t(max(256, openDescriptorCount + 128)))
    var reduced = original
    reduced.rlim_cur = reducedSoftLimit
    guard setrlimit(RLIMIT_NOFILE, &reduced) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    return (original, reducedSoftLimit)
}

private func runDescriptorLimitTestInSubprocess() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    var arguments = Array(CommandLine.arguments.dropFirst())
    if let filterIndex = arguments.firstIndex(of: "--filter"),
       arguments.indices.contains(filterIndex + 1) {
        arguments[filterIndex + 1] = "recursiveRemovalBoundsDescriptorsIndependentlyOfDepth"
    } else {
        arguments += ["--filter", "recursiveRemovalBoundsDescriptorsIndependentlyOfDepth"]
    }
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment[descriptorLimitChildEnvironmentKey] = "1"
    process.environment = environment
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

private func restoreOpenFileLimit(_ original: rlimit) {
    var original = original
    #expect(setrlimit(RLIMIT_NOFILE, &original) == 0)
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

private func addDenyDeleteChildACL(to url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = ["+a", "everyone deny delete_child", url.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw FixtureError.commandFailed }
}

private func removeFirstACL(from url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = ["-a#", "0", url.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw FixtureError.commandFailed }
}

private func bindUnixSocket(at path: String) throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    var transfersDescriptor = false
    defer { if transfersDescriptor == false { _ = Darwin.close(descriptor) } }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let pathByteCount = path.utf8CString.count
    guard pathByteCount <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw POSIXError(.ENAMETOOLONG)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        path.withCString { source in
            destination.copyBytes(from: UnsafeRawBufferPointer(
                start: source,
                count: pathByteCount
            ))
        }
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.bind(
                descriptor,
                socketAddress,
                socklen_t(MemoryLayout<sockaddr_un>.size)
            )
        }
    }
    guard bound == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    transfersDescriptor = true
    return descriptor
}

private func removeFixture(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}
