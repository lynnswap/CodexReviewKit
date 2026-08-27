import Foundation
import Synchronization

package struct PreparedRecoveryEnvironmentCloseError: Error, LocalizedError, Sendable {
    package struct Failure: Sendable {
        package enum Owner: String, Sendable {
            case savedAccounts
            case loginStaging
            case codexSQLite
            case codexHome
            case recovery
        }

        package let owner: Owner
        package let error: any Error
    }

    package let failures: [Failure]

    package var errorDescription: String? {
        failures.map { "\($0.owner.rawValue): \($0.error.localizedDescription)" }.joined(separator: "; ")
    }
}

package final class PreparedRecoveryEnvironment: Sendable {
    private enum CloseState: Sendable {
        case open
        case closed(PreparedRecoveryEnvironmentCloseError?)
    }

    private let recovery: DirectoryCapability
    private let codexHome: DirectoryCapability
    private let codexSQLite: DirectoryCapability
    private let loginStaging: DirectoryCapability
    private let savedAccounts: DirectoryCapability
    private let closeState: Mutex<CloseState>

    init(recovery: DirectoryCapability, codexHome: DirectoryCapability,
         codexSQLite: DirectoryCapability, loginStaging: DirectoryCapability,
         savedAccounts: DirectoryCapability) {
        self.recovery = recovery
        self.codexHome = codexHome
        self.codexSQLite = codexSQLite
        self.loginStaging = loginStaging
        self.savedAccounts = savedAccounts
        closeState = Mutex(.open)
    }

    deinit { try? close() }

    package func withRecoveryDirectoryURL<Result>(_ body: (URL) throws -> Result) throws -> Result {
        try recovery.withRevalidatedPath(body)
    }

    package func withCodexHomeURL<Result>(_ body: (URL) throws -> Result) throws -> Result {
        try codexHome.withRevalidatedPath(body)
    }

    package func withCodexSQLiteHomeURL<Result>(_ body: (URL) throws -> Result) throws -> Result {
        try codexSQLite.withRevalidatedPath(body)
    }

    package func withLoginStagingDirectoryURL<Result>(_ body: (URL) throws -> Result) throws -> Result {
        try loginStaging.withRevalidatedPath(body)
    }

    package func withSavedAccountsDirectoryURL<Result>(_ body: (URL) throws -> Result) throws -> Result {
        try savedAccounts.withRevalidatedPath(body)
    }

    package func withHistoryDatabaseURL<Result>(_ body: (URL) throws -> Result) throws -> Result {
        try recovery.withRevalidatedPath {
            try body($0.appendingPathComponent("review-history.sqlite", isDirectory: false))
        }
    }

    package func close() throws {
        let error = closeState.withLock { state -> PreparedRecoveryEnvironmentCloseError? in
            if case .closed(let error) = state { return error }
            let owned: [(PreparedRecoveryEnvironmentCloseError.Failure.Owner, DirectoryCapability)] = [
                (.savedAccounts, savedAccounts),
                (.loginStaging, loginStaging),
                (.codexSQLite, codexSQLite),
                (.codexHome, codexHome),
                (.recovery, recovery),
            ]
            var failures: [PreparedRecoveryEnvironmentCloseError.Failure] = []
            for (owner, capability) in owned {
                do {
                    try capability.close()
                } catch {
                    failures.append(.init(owner: owner, error: error))
                }
            }
            let error = failures.isEmpty ? nil : PreparedRecoveryEnvironmentCloseError(failures: failures)
            state = .closed(error)
            return error
        }
        if let error { throw error }
    }
}
