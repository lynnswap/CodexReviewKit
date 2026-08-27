import Darwin
import Foundation
import Testing
import CodexReviewHost

@Suite("recovery environment")
struct RecoveryEnvironmentTests {
    @Test func defaultPlanPreparesOneCapabilityGraphAndAppServerScaffold() throws {
        let fixture = try makePrivateRecoveryRoot()
        defer { removeRecoveryFixture(fixture) }
        let plan = recoveryPlan(in: fixture)

        let prepared = try plan.prepare()
        defer { try? prepared.close() }

        try prepared.withRecoveryDirectoryURL { url in
            #expect(url == fixture.appendingPathComponent("RecoveryV1", isDirectory: true))
            let permissions = try recoveryPermissions(at: url)
            #expect(permissions == 0o700)
        }
        try prepared.withCodexHomeURL { url in
            #expect(url.lastPathComponent == "CodexHome")
            let config = url.appendingPathComponent("config.toml")
            let agents = url.appendingPathComponent("AGENTS.md")
            let permissions = try recoveryPermissions(at: url)
            let configContents = try Data(contentsOf: config)
            let agentsContents = try Data(contentsOf: agents)
            let configPermissions = try recoveryPermissions(at: config)
            let agentsPermissions = try recoveryPermissions(at: agents)
            #expect(permissions == 0o700)
            #expect(configContents.isEmpty)
            #expect(agentsContents.isEmpty)
            #expect(configPermissions == 0o600)
            #expect(agentsPermissions == 0o600)
        }
        try prepared.withCodexSQLiteHomeURL { #expect($0.lastPathComponent == "sqlite") }
        try prepared.withLoginStagingDirectoryURL { #expect($0.lastPathComponent == "LoginStaging") }
        try prepared.withSavedAccountsDirectoryURL { #expect($0.lastPathComponent == "SavedAccounts") }
        try prepared.withHistoryDatabaseURL {
            #expect($0.lastPathComponent == "review-history.sqlite")
            #expect(FileManager.default.fileExists(atPath: $0.path) == false)
        }
        expectRecoveryError(.invalidRequest) { _ = try plan.prepare() }
    }

    @Test func preparationPreservesExistingScaffoldContentsAndModes() throws {
        let fixture = try makePrivateRecoveryRoot()
        defer { removeRecoveryFixture(fixture) }
        let codexHome = fixture.appendingPathComponent(
            "RecoveryV1/CodexHome",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try chmodDirectoryChain(
            from: fixture,
            components: ["RecoveryV1", "CodexHome"],
            permissions: 0o700
        )
        let config = codexHome.appendingPathComponent("config.toml")
        let agents = codexHome.appendingPathComponent("AGENTS.md")
        let configContents = Data("model = \"gpt-5\"".utf8)
        let agentsContents = Data("existing instructions".utf8)
        try configContents.write(to: config)
        try agentsContents.write(to: agents)
        #expect(chmod(config.path, 0o640) == 0)
        #expect(chmod(agents.path, 0o600) == 0)

        let prepared = try recoveryPlan(in: fixture).prepare()
        defer { try? prepared.close() }

        #expect(try Data(contentsOf: config) == configContents)
        #expect(try Data(contentsOf: agents) == agentsContents)
        #expect(try recoveryPermissions(at: config) == 0o640)
        #expect(try recoveryPermissions(at: agents) == 0o600)
    }

    @Test func safeExistingExplicitHomeIsPreservedAndPreparedOutsideRecovery() throws {
        let fixture = try makePrivateRecoveryRoot()
        defer { removeRecoveryFixture(fixture) }
        let explicitHome = fixture.appendingPathComponent("explicit-codex", isDirectory: true)
        try createRecoveryDirectory(explicitHome, permissions: 0o700)
        let sentinel = explicitHome.appendingPathComponent("sentinel")
        try Data("owned".utf8).write(to: sentinel)

        let prepared = try recoveryPlan(in: fixture, explicitHome: explicitHome).prepare()
        defer { try? prepared.close() }

        try prepared.withCodexHomeURL { #expect($0 == explicitHome) }
        try prepared.withCodexSQLiteHomeURL {
            #expect($0 == explicitHome.appendingPathComponent("sqlite", isDirectory: true))
        }
        #expect(try Data(contentsOf: sentinel) == Data("owned".utf8))
        #expect(try recoveryPermissions(at: explicitHome) == 0o700)
    }

    @Test func unsafeOrUnanchoredExplicitHomesFailWithoutMutatingThem() throws {
        let fixture = try makePrivateRecoveryRoot()
        defer { removeRecoveryFixture(fixture) }
        let shared = fixture.appendingPathComponent("shared", isDirectory: true)
        try createRecoveryDirectory(shared, permissions: 0o755)
        expectRecoveryError(.policyViolation) {
            _ = try recoveryPlan(in: fixture, explicitHome: shared).prepare()
        }
        #expect(try recoveryPermissions(at: shared) == 0o755)

        let aclHome = fixture.appendingPathComponent("acl-home", isDirectory: true)
        try createRecoveryDirectory(aclHome, permissions: 0o700)
        try addRecoveryAllowACL(to: aclHome)
        expectRecoveryError(.policyViolation) {
            _ = try recoveryPlan(in: fixture, explicitHome: aclHome).prepare()
        }
        try removeRecoveryACL(from: aclHome)

        let missingParentHome = fixture
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("home", isDirectory: true)
        expectRecoveryError(.userActionRequired) {
            _ = try recoveryPlan(in: fixture, explicitHome: missingParentHome).prepare()
        }
        #expect(FileManager.default.fileExists(atPath: missingParentHome.path) == false)
    }

    @Test func anchorPoliciesRejectSymlinksAndWrongOwnershipBeforeMutation() throws {
        let fixture = try makePrivateRecoveryRoot()
        defer { removeRecoveryFixture(fixture) }
        let target = fixture.appendingPathComponent("target", isDirectory: true)
        try createRecoveryDirectory(target, permissions: 0o700)
        let link = fixture.appendingPathComponent("anchor-link", isDirectory: true)
        #expect(symlink("target", link.path) == 0)
        expectRecoveryError(.policyViolation) {
            _ = try RecoveryEnvironmentPlan(
                recoveryParentURL: link,
                legacyCodexHomeURL: fixture.appendingPathComponent("legacy", isDirectory: true)
            ).prepare()
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)

        expectRecoveryError(.policyViolation) {
            _ = try RecoveryEnvironmentPlan(
                recoveryParentURL: fixture,
                legacyCodexHomeURL: fixture.appendingPathComponent("legacy", isDirectory: true),
                ownerUserID: geteuid() == 0 ? 1 : 0
            ).prepare()
        }
    }

    @Test func existingManagedLayoutIsValidatedWithoutPermissionRepair() throws {
        let fixture = try makePrivateRecoveryRoot()
        defer { removeRecoveryFixture(fixture) }
        let recovery = fixture.appendingPathComponent("RecoveryV1", isDirectory: true)
        try createRecoveryDirectory(recovery, permissions: 0o750)

        expectRecoveryError(.policyViolation) {
            _ = try recoveryPlan(in: fixture).prepare()
        }

        #expect(try recoveryPermissions(at: recovery) == 0o750)
        #expect(FileManager.default.fileExists(
            atPath: recovery.appendingPathComponent("CodexHome").path
        ) == false)
    }

    @Test func explicitAndLegacyRootsRejectSameAndReverseAncestorOverlap() throws {
        let fixture = try makePrivateRecoveryRoot()
        defer { removeRecoveryFixture(fixture) }
        let nestedAnchor = fixture.appendingPathComponent("owned-root", isDirectory: true)
        try createRecoveryDirectory(nestedAnchor, permissions: 0o700)

        expectRecoveryError(.policyViolation) {
            _ = try RecoveryEnvironmentPlan(
                recoveryParentURL: nestedAnchor,
                explicitCodexHomeURL: nestedAnchor,
                legacyCodexHomeURL: fixture.appendingPathComponent("legacy", isDirectory: true)
            ).prepare()
        }

        let descendantAnchor = fixture.appendingPathComponent("descendant-root", isDirectory: true)
        try createRecoveryDirectory(descendantAnchor, permissions: 0o700)
        let recovery = descendantAnchor.appendingPathComponent("RecoveryV1", isDirectory: true)
        try createRecoveryDirectory(recovery, permissions: 0o700)
        let forbiddenExplicit = recovery.appendingPathComponent("explicit", isDirectory: true)
        expectRecoveryError(.policyViolation) {
            _ = try RecoveryEnvironmentPlan(
                recoveryParentURL: descendantAnchor,
                explicitCodexHomeURL: forbiddenExplicit,
                legacyCodexHomeURL: fixture.appendingPathComponent("legacy", isDirectory: true)
            ).prepare()
        }
        #expect(FileManager.default.fileExists(atPath: forbiddenExplicit.path) == false)

        let legacyAncestor = fixture.appendingPathComponent("legacy-ancestor", isDirectory: true)
        try createRecoveryDirectory(legacyAncestor, permissions: 0o700)
        let legacyRecoveryParent = legacyAncestor.appendingPathComponent("parent", isDirectory: true)
        try createRecoveryDirectory(legacyRecoveryParent, permissions: 0o700)
        expectRecoveryError(.policyViolation) {
            _ = try RecoveryEnvironmentPlan(
                recoveryParentURL: legacyRecoveryParent,
                legacyCodexHomeURL: legacyAncestor
            ).prepare()
        }
    }

    @Test func filesystemAliasesCannotBypassIdentityOverlapPolicy() throws {
        let fixture = try makePrivateRecoveryRoot()
        defer { removeRecoveryFixture(fixture) }
        let recovery = fixture.appendingPathComponent("RecoveryV1", isDirectory: true)
        try createRecoveryDirectory(recovery, permissions: 0o700)
        let caseAlias = fixture.appendingPathComponent("recoveryv1", isDirectory: true)
        if try sameRecoveryIdentity(recovery, caseAlias) {
            expectRecoveryError(.policyViolation) {
                _ = try recoveryPlan(in: fixture, explicitHome: caseAlias).prepare()
            }
        }

        let explicitName = "Caf\u{00E9}"
        let explicit = fixture.appendingPathComponent(explicitName, isDirectory: true)
        try createRecoveryDirectory(explicit, permissions: 0o700)
        let unicodeAlias = fixture.appendingPathComponent(
            explicitName.decomposedStringWithCanonicalMapping,
            isDirectory: true
        )
        if try sameRecoveryIdentity(explicit, unicodeAlias) {
            expectRecoveryError(.policyViolation) {
                _ = try RecoveryEnvironmentPlan(
                    recoveryParentURL: fixture,
                    explicitCodexHomeURL: explicit,
                    legacyCodexHomeURL: unicodeAlias
                ).prepare()
            }
        }
    }

    @Test func firmlinkSpellingCannotBypassIdentityOverlapPolicy() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard home.path.hasPrefix("/Users/") else { return }
        let fixture = try makePrivateRecoveryRoot(in: home.path)
        defer { removeRecoveryFixture(fixture) }
        let recovery = fixture.appendingPathComponent("RecoveryV1", isDirectory: true)
        try createRecoveryDirectory(recovery, permissions: 0o700)
        let dataSpelling = URL(
            fileURLWithPath: "/System/Volumes/Data\(recovery.path)",
            isDirectory: true
        )
        guard try sameRecoveryIdentity(recovery, dataSpelling) else { return }

        expectRecoveryError(.policyViolation) {
            _ = try recoveryPlan(in: fixture, explicitHome: dataSpelling).prepare()
        }
    }

    @Test func closeIsIdempotentAndClosesEveryRetainedCapability() throws {
        let fixture = try makePrivateRecoveryRoot()
        defer { removeRecoveryFixture(fixture) }
        let prepared = try recoveryPlan(in: fixture).prepare()

        try prepared.close()
        try prepared.close()

        expectRecoveryError(.closed) { try prepared.withRecoveryDirectoryURL { _ in } }
        expectRecoveryError(.closed) { try prepared.withCodexHomeURL { _ in } }
        expectRecoveryError(.closed) { try prepared.withCodexSQLiteHomeURL { _ in } }
        expectRecoveryError(.closed) { try prepared.withLoginStagingDirectoryURL { _ in } }
        expectRecoveryError(.closed) { try prepared.withSavedAccountsDirectoryURL { _ in } }
        expectRecoveryError(.closed) { try prepared.withHistoryDatabaseURL { _ in } }
    }
}

private enum ExpectedRecoveryError { case invalidRequest, policyViolation, userActionRequired, closed }

private enum RecoveryFixtureError: Error { case unableToCreateTemporaryDirectory, commandFailed }

private func recoveryPlan(
    in fixture: URL,
    explicitHome: URL? = nil
) -> RecoveryEnvironmentPlan {
    RecoveryEnvironmentPlan(
        recoveryParentURL: fixture,
        explicitCodexHomeURL: explicitHome,
        legacyCodexHomeURL: fixture.appendingPathComponent("legacy-codex", isDirectory: true)
    )
}

private func expectRecoveryError(
    _ expected: ExpectedRecoveryError,
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

private func makePrivateRecoveryRoot(in parent: String = "/private/tmp") throws -> URL {
    var template = Array("\(parent)/codex-recovery-environment.XXXXXX".utf8CString)
    let path = template.withUnsafeMutableBufferPointer { buffer -> String? in
        guard let pointer = mkdtemp(buffer.baseAddress) else { return nil }
        return String(cString: pointer)
    }
    guard let path else { throw RecoveryFixtureError.unableToCreateTemporaryDirectory }
    return URL(fileURLWithPath: path, isDirectory: true)
}

private func createRecoveryDirectory(_ url: URL, permissions: mode_t) throws {
    guard mkdir(url.path, permissions) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    guard chmod(url.path, permissions) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
}

private func chmodDirectoryChain(
    from root: URL,
    components: [String],
    permissions: mode_t
) throws {
    var current = root
    for component in components {
        current.appendPathComponent(component, isDirectory: true)
        guard chmod(current.path, permissions) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
}

private func recoveryPermissions(at url: URL) throws -> mode_t {
    var status = stat()
    guard stat(url.path, &status) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    return status.st_mode & 0o7777
}

private func sameRecoveryIdentity(_ lhs: URL, _ rhs: URL) throws -> Bool {
    var lhsStatus = stat()
    var rhsStatus = stat()
    guard stat(lhs.path, &lhsStatus) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    if stat(rhs.path, &rhsStatus) != 0 { return false }
    return lhsStatus.st_dev == rhsStatus.st_dev && lhsStatus.st_ino == rhsStatus.st_ino
}

private func addRecoveryAllowACL(to url: URL) throws {
    try runRecoveryCommand("/bin/chmod", arguments: ["+a", "everyone allow read", url.path])
}

private func removeRecoveryACL(from url: URL) throws {
    try runRecoveryCommand("/bin/chmod", arguments: ["-a#", "0", url.path])
}

private func runRecoveryCommand(_ path: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw RecoveryFixtureError.commandFailed }
}

private func removeRecoveryFixture(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}
