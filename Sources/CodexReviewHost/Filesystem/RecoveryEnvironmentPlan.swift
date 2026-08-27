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
        return try Self.prepare(configuration)
    }

    private static func prepare(_ configuration: Configuration) throws -> PreparedRecoveryEnvironment {
        let trusted = DirectoryCapability.Requirements.trustedAnchor(
            ownerUserID: configuration.ownerUserID)
        let recoveryParent = try DirectoryCapability.openExisting(
            at: configuration.recoveryParentURL, requirements: trusted)
        let legacyHome = try DirectoryCapability.openExistingIfPresent(
            at: configuration.legacyCodexHomeURL, requirements: trusted)
        let recoveryURL = configuration.recoveryParentURL.appendingPathComponent(
            "RecoveryV1", isDirectory: true)
        let recoveryRequirements = managed(
            for: recoveryParent, ownerUserID: configuration.ownerUserID)
        let existingRecovery = try DirectoryCapability.openExistingIfPresent(
            at: recoveryURL, requirements: recoveryRequirements)

        let explicitParent: DirectoryCapability?
        let explicitName: DirectoryCapability.Name?
        let existingExplicitHome: DirectoryCapability?
        if let explicitURL = configuration.explicitCodexHomeURL {
            // Rejection only: acquired identity remains the overlap authority, but identical
            // standardized inputs cannot become disjoint even while both leaves are absent.
            guard rejectionKey(explicitURL) != rejectionKey(configuration.legacyCodexHomeURL) else {
                throw DirectoryCapabilityError.policyViolation(
                    "Legacy and explicit Codex home inputs must be disjoint."
                )
            }
            guard rejectionKey(explicitURL) != rejectionKey(recoveryURL) else {
                throw DirectoryCapabilityError.policyViolation(
                    "RecoveryV1 and explicit Codex home inputs must be disjoint."
                )
            }
            let name = try DirectoryCapability.Name(explicitURL.lastPathComponent)
            let parent = try DirectoryCapability.openExisting(
                at: explicitURL.deletingLastPathComponent(),
                requirements: trusted
            )
            explicitParent = parent
            explicitName = name
            existingExplicitHome = try DirectoryCapability.openExistingIfPresent(
                at: explicitURL,
                requirements: managed(for: parent, ownerUserID: configuration.ownerUserID))
            try requireDisjoint(
                legacyHome, existingExplicitHome, roots: "legacy and explicit Codex home")
            try requireRootDoesNotContain(
                existingExplicitHome, candidateParent: recoveryParent, candidate: "RecoveryV1")
        } else {
            explicitParent = nil
            explicitName = nil
            existingExplicitHome = nil
        }
        try requireRootDoesNotContain(
            legacyHome, candidateParent: recoveryParent, candidate: "RecoveryV1")
        if existingExplicitHome == nil, let explicitParent {
            try requireRootDoesNotContain(
                legacyHome, candidateParent: explicitParent, candidate: "explicit Codex home")
            try requireRootDoesNotContain(
                existingRecovery, candidateParent: explicitParent, candidate: "explicit Codex home")
        }
        try existingRecovery?.close()

        let recovery = try recoveryParent.directory(
            named: .init("RecoveryV1"),
            acquisition: .existingOrCreate,
            requirements: recoveryRequirements
        )
        let codexHome: DirectoryCapability
        if let existingExplicitHome {
            codexHome = existingExplicitHome
        } else if let explicitParent, let explicitName {
            codexHome = try explicitParent.directory(
                named: explicitName, acquisition: .existingOrCreate,
                requirements: managed(for: explicitParent, ownerUserID: configuration.ownerUserID))
        } else {
            codexHome = try recovery.directory(
                named: .init("CodexHome"),
                acquisition: .existingOrCreate,
                requirements: managed(for: recovery, ownerUserID: configuration.ownerUserID)
            )
        }
        if configuration.explicitCodexHomeURL != nil {
            try requireDisjoint(recovery, codexHome, roots: "RecoveryV1 and explicit Codex home")
            try requireDisjoint(legacyHome, codexHome, roots: "legacy and explicit Codex home")
        }
        try requireDisjoint(legacyHome, recovery, roots: "legacy Codex home and RecoveryV1")

        let codexSQLite = try codexHome.directory(
            named: .init("sqlite"),
            acquisition: .existingOrCreate,
            requirements: managed(for: codexHome, ownerUserID: configuration.ownerUserID)
        )
        let loginStaging = try recovery.directory(
            named: .init("LoginStaging"),
            acquisition: .existingOrCreate,
            requirements: managed(for: recovery, ownerUserID: configuration.ownerUserID)
        )
        let savedAccounts = try recovery.directory(
            named: .init("SavedAccounts"),
            acquisition: .existingOrCreate,
            requirements: managed(for: recovery, ownerUserID: configuration.ownerUserID)
        )
        try codexHome.createFileIfMissing(named: .init("config.toml"))
        try codexHome.createFileIfMissing(named: .init("AGENTS.md"))

        try explicitParent?.close()
        try legacyHome?.close()
        try recoveryParent.close()
        return PreparedRecoveryEnvironment(
            recovery: recovery, codexHome: codexHome, codexSQLite: codexSQLite,
            loginStaging: loginStaging, savedAccounts: savedAccounts)
    }

    private static func managed(
        for parent: DirectoryCapability,
        ownerUserID: uid_t
    ) -> DirectoryCapability.Requirements {
        .managed(ownerUserID: ownerUserID, deviceID: parent.identity.deviceID)
    }

    private static func rejectionKey(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func requireDisjoint(
        _ lhs: DirectoryCapability?,
        _ rhs: DirectoryCapability?,
        roots: String
    ) throws {
        guard let lhs, let rhs else { return }
        guard try lhs.relationship(to: rhs) == .disjoint else {
            throw DirectoryCapabilityError.policyViolation(
                "RecoveryV1 requires disjoint \(roots) roots."
            )
        }
    }

    private static func requireRootDoesNotContain(
        _ root: DirectoryCapability?,
        candidateParent: DirectoryCapability,
        candidate description: String
    ) throws {
        guard let root else { return }
        let relationship = try root.relationship(to: candidateParent)
        guard relationship != .same, relationship != .ancestor else {
            throw DirectoryCapabilityError.policyViolation(
                "\(description) cannot be created within a protected recovery root."
            )
        }
    }
}
