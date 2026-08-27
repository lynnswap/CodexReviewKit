import Darwin
import Foundation
import Synchronization

package final class RecoveryEnvironmentPlan: Sendable {
    private struct Configuration: Sendable {
        let recoveryParentURL: URL
        let explicitCodexHomeURL: URL?
        let legacyCodexHomeURL: URL
        let ownerUserID: uid_t
    }

    private enum State: Sendable {
        case ready(Configuration)
        case consumed
    }

    private enum RootRole: String, Sendable {
        case recovery = "RecoveryV1"
        case explicitCodexHome = "explicit Codex home"
        case legacyCodexHome = "legacy Codex home"
    }

    private struct MaterializableRoot: Sendable {
        let role: RootRole
        let location: DirectoryCapability.ResolvedDirectoryLocation
        let parent: DirectoryCapability
        let name: DirectoryCapability.Name
        let requirements: DirectoryCapability.Requirements

        func materialize() throws -> DirectoryCapability {
            try parent.directory(
                named: name,
                acquisition: .existingOrCreate,
                requirements: requirements
            )
        }
    }

    private struct ProtectedRoot: Sendable {
        let role: RootRole
        let location: DirectoryCapability.ResolvedDirectoryLocation
    }

    private struct ResolvedRootSet: Sendable {
        let recovery: MaterializableRoot
        let explicitCodexHome: MaterializableRoot?
        let legacyCodexHome: DirectoryCapability.ResolvedDirectoryLocation

        func validated() throws -> ValidatedRootSet {
            var roots = [ProtectedRoot(role: recovery.role, location: recovery.location)]
            if let explicitCodexHome {
                roots.append(.init(
                    role: explicitCodexHome.role,
                    location: explicitCodexHome.location
                ))
            }
            roots.append(.init(role: .legacyCodexHome, location: legacyCodexHome))

            for leftIndex in roots.indices {
                for rightIndex in roots.index(after: leftIndex)..<roots.endIndex {
                    let left = roots[leftIndex]
                    let right = roots[rightIndex]
                    let relationship = try left.location.relationship(to: right.location)
                    guard relationship == .disjoint else {
                        throw DirectoryCapabilityError.policyViolation(
                            "RecoveryV1 requires disjoint \(left.role.rawValue) and "
                                + "\(right.role.rawValue) roots; found \(relationship)."
                        )
                    }
                }
            }
            return ValidatedRootSet(
                recovery: recovery,
                explicitCodexHome: explicitCodexHome
            )
        }
    }

    private struct ValidatedRootSet: Sendable {
        let recovery: MaterializableRoot
        let explicitCodexHome: MaterializableRoot?

        func materialize(ownerUserID: uid_t) throws -> PreparedRecoveryEnvironment {
            let recoveryCapability = try recovery.materialize()
            let codexHome = try explicitCodexHome?.materialize()
                ?? recoveryCapability.directory(
                    named: .init("CodexHome"),
                    acquisition: .existingOrCreate,
                    requirements: RecoveryEnvironmentPlan.managed(
                        for: recoveryCapability,
                        ownerUserID: ownerUserID
                    )
                )
            let codexSQLite = try codexHome.directory(
                named: .init("sqlite"),
                acquisition: .existingOrCreate,
                requirements: RecoveryEnvironmentPlan.managed(
                    for: codexHome, ownerUserID: ownerUserID)
            )
            let loginStaging = try recoveryCapability.directory(
                named: .init("LoginStaging"),
                acquisition: .existingOrCreate,
                requirements: RecoveryEnvironmentPlan.managed(
                    for: recoveryCapability, ownerUserID: ownerUserID)
            )
            let savedAccounts = try recoveryCapability.directory(
                named: .init("SavedAccounts"),
                acquisition: .existingOrCreate,
                requirements: RecoveryEnvironmentPlan.managed(
                    for: recoveryCapability, ownerUserID: ownerUserID)
            )
            try codexHome.createFileIfMissing(named: .init("config.toml"))
            try codexHome.createFileIfMissing(named: .init("AGENTS.md"))
            return PreparedRecoveryEnvironment(
                recovery: recoveryCapability,
                codexHome: codexHome,
                codexSQLite: codexSQLite,
                loginStaging: loginStaging,
                savedAccounts: savedAccounts
            )
        }
    }

    private let state: Mutex<State>

    package init(
        recoveryParentURL: URL,
        explicitCodexHomeURL: URL? = nil,
        legacyCodexHomeURL: URL,
        ownerUserID: uid_t = geteuid()
    ) {
        state = Mutex(.ready(.init(
            recoveryParentURL: recoveryParentURL,
            explicitCodexHomeURL: explicitCodexHomeURL,
            legacyCodexHomeURL: legacyCodexHomeURL,
            ownerUserID: ownerUserID
        )))
    }

    package func prepare() throws -> PreparedRecoveryEnvironment {
        let configuration = try state.withLock { state -> Configuration in
            guard case .ready(let configuration) = state else {
                throw DirectoryCapabilityError.invalidRequest(
                    "A recovery environment plan can prepare only one capability graph."
                )
            }
            state = .consumed
            return configuration
        }
        let resolved = try Self.resolve(configuration)
        let validated = try resolved.validated()
        return try validated.materialize(ownerUserID: configuration.ownerUserID)
    }

    private static func resolve(_ configuration: Configuration) throws -> ResolvedRootSet {
        let trusted = DirectoryCapability.Requirements.trustedAnchor(
            ownerUserID: configuration.ownerUserID
        )
        let recoveryParent = try DirectoryCapability.openExisting(
            at: configuration.recoveryParentURL,
            requirements: trusted
        )
        let recoveryName = try DirectoryCapability.Name("RecoveryV1")
        let recoveryRequirements = managed(
            for: recoveryParent,
            ownerUserID: configuration.ownerUserID
        )
        let recoveryURL = configuration.recoveryParentURL.appendingPathComponent(
            "RecoveryV1",
            isDirectory: true
        )
        let recoveryLocation = try DirectoryCapability.resolveLocation(
            at: recoveryURL,
            requirements: recoveryRequirements
        )
        let recovery = MaterializableRoot(
            role: .recovery,
            location: recoveryLocation,
            parent: recoveryParent,
            name: recoveryName,
            requirements: recoveryRequirements
        )

        let explicitCodexHome: MaterializableRoot?
        if let explicitURL = configuration.explicitCodexHomeURL {
            let name = try DirectoryCapability.Name(explicitURL.lastPathComponent)
            let parent = try DirectoryCapability.openExisting(
                at: explicitURL.deletingLastPathComponent(),
                requirements: trusted
            )
            let requirements = managed(for: parent, ownerUserID: configuration.ownerUserID)
            let location = try DirectoryCapability.resolveLocation(
                at: explicitURL,
                requirements: requirements
            )
            explicitCodexHome = MaterializableRoot(
                role: .explicitCodexHome,
                location: location,
                parent: parent,
                name: name,
                requirements: requirements
            )
        } else {
            explicitCodexHome = nil
        }

        let legacyCodexHome = try DirectoryCapability.resolveLocation(
            at: configuration.legacyCodexHomeURL,
            requirements: trusted
        )
        return ResolvedRootSet(
            recovery: recovery,
            explicitCodexHome: explicitCodexHome,
            legacyCodexHome: legacyCodexHome
        )
    }

    private static func managed(
        for parent: DirectoryCapability,
        ownerUserID: uid_t
    ) -> DirectoryCapability.Requirements {
        .managed(ownerUserID: ownerUserID, deviceID: parent.identity.deviceID)
    }
}
