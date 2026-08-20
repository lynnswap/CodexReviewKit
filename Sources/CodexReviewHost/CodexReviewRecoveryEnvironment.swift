import Foundation

package enum CodexReviewRecoveryEnvironmentError: Error, Equatable, LocalizedError, Sendable {
    case invalidDirectoryURL(URL)
    case legacyCodexHome(URL)
    case directoryPreparationFailed(URL, message: String)
    case directoryPermissionsMismatch(URL, actual: Int)
    case invalidLoginStagingDirectory(URL)
    case directoryRemovalFailed(URL, message: String)

    package var errorDescription: String? {
        switch self {
        case .invalidDirectoryURL(let url):
            "RecoveryV1 requires an absolute file URL, but received \(url.absoluteString)."
        case .legacyCodexHome(let url):
            "The legacy Codex home at \(url.path) is a read-only migration input and cannot be used by RecoveryV1."
        case .directoryPreparationFailed(let url, let message):
            "Unable to prepare the RecoveryV1 directory at \(url.path): \(message)"
        case .directoryPermissionsMismatch(let url, let actual):
            "RecoveryV1 requires owner-only permissions at \(url.path), but found \(String(format: "%03o", actual))."
        case .invalidLoginStagingDirectory(let url):
            "RecoveryV1 cannot remove an unowned login staging directory at \(url.path)."
        case .directoryRemovalFailed(let url, let message):
            "Unable to remove the RecoveryV1 login staging directory at \(url.path): \(message)"
        }
    }
}

package struct CodexReviewRecoveryEnvironment: Equatable, Sendable {
    package static let recoveryDirectoryName = "RecoveryV1"

    package let recoveryDirectoryURL: URL
    package let codexHomeURL: URL
    package let loginStagingDirectoryURL: URL
    package let savedAccountsDirectoryURL: URL
    package let historyDatabaseURL: URL

    private let legacyCodexHomeURL: URL

    package static var production: Self {
        let recoveryDirectoryURL = URL.applicationSupportDirectory
            .appending(path: "CodexReviewMonitor", directoryHint: .isDirectory)
            .appending(path: recoveryDirectoryName, directoryHint: .isDirectory)
        return Self(
            recoveryDirectoryURL: recoveryDirectoryURL,
            legacyCodexHomeURL: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".codex_review", directoryHint: .isDirectory)
        )
    }

    package init(
        recoveryDirectoryURL: URL,
        codexHomeURL: URL? = nil,
        legacyCodexHomeURL: URL
    ) {
        self.recoveryDirectoryURL = recoveryDirectoryURL
        self.codexHomeURL = codexHomeURL
            ?? recoveryDirectoryURL.appending(path: "CodexHome", directoryHint: .isDirectory)
        self.loginStagingDirectoryURL = recoveryDirectoryURL
            .appending(path: "LoginStaging", directoryHint: .isDirectory)
        self.savedAccountsDirectoryURL = recoveryDirectoryURL
            .appending(path: "SavedAccounts", directoryHint: .isDirectory)
        self.historyDatabaseURL = recoveryDirectoryURL
            .appending(path: "review-history.sqlite", directoryHint: .notDirectory)
        self.legacyCodexHomeURL = legacyCodexHomeURL
    }

    package func configured(codexHomePath: String?) -> Self {
        guard let codexHomePath else {
            return self
        }
        return Self(
            recoveryDirectoryURL: recoveryDirectoryURL,
            codexHomeURL: URL(filePath: codexHomePath, directoryHint: .isDirectory),
            legacyCodexHomeURL: legacyCodexHomeURL
        )
    }

    package func loginStagingCodexHomeURL(sessionID: UUID) -> URL {
        loginStagingDirectoryURL.appending(
            path: sessionID.uuidString,
            directoryHint: .isDirectory
        )
    }

    package func prepare() async throws {
        try await Task.detached(priority: .utility) {
            try prepareSynchronously()
        }.value
    }

    package func prepareLoginStagingCodexHome(sessionID: UUID) async throws -> URL {
        let url = loginStagingCodexHomeURL(sessionID: sessionID)
        try await Task.detached(priority: .utility) {
            try Self.validateDirectoryURL(url)
            try Self.prepareOwnerOnlyDirectory(at: url)
        }.value
        return url
    }

    package func removeLoginStagingCodexHome(at url: URL) async throws {
        try await Task.detached(priority: .utility) {
            let stagingRoot = loginStagingDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
            let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
            guard candidate != stagingRoot,
                  Self.isSameOrDescendant(candidate, of: stagingRoot)
            else {
                throw CodexReviewRecoveryEnvironmentError.invalidLoginStagingDirectory(url)
            }
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: url.path) else {
                return
            }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw CodexReviewRecoveryEnvironmentError.directoryRemovalFailed(
                    url,
                    message: error.localizedDescription
                )
            }
        }.value
    }

    private func prepareSynchronously() throws {
        try Self.validateDirectoryURL(recoveryDirectoryURL)
        try Self.validateDirectoryURL(codexHomeURL)
        try Self.validateDirectoryURL(loginStagingDirectoryURL)
        try Self.validateDirectoryURL(savedAccountsDirectoryURL)

        let resolvedLegacyURL = legacyCodexHomeURL.standardizedFileURL.resolvingSymlinksInPath()
        let directoryURLs = [
            recoveryDirectoryURL,
            codexHomeURL,
            loginStagingDirectoryURL,
            savedAccountsDirectoryURL,
        ]
        for directoryURL in directoryURLs {
            let resolvedDirectoryURL = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
            guard Self.isSameOrDescendant(resolvedDirectoryURL, of: resolvedLegacyURL) == false else {
                throw CodexReviewRecoveryEnvironmentError.legacyCodexHome(directoryURL)
            }
        }

        for directoryURL in directoryURLs {
            try Self.prepareOwnerOnlyDirectory(at: directoryURL)
        }
    }

    private static func validateDirectoryURL(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw CodexReviewRecoveryEnvironmentError.invalidDirectoryURL(url)
        }
    }

    package static func prepareOwnerOnlyDirectory(at url: URL) throws {
        let fileManager = FileManager.default
        do {
            var isDirectory = ObjCBool(false)
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue == false
            {
                throw CocoaError(.fileWriteFileExists)
            }
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: ownerOnlyDirectoryPermissions)]
            )
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: ownerOnlyDirectoryPermissions)],
                ofItemAtPath: url.path
            )
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            let effectivePermissions = permissions & 0o777
            guard effectivePermissions == ownerOnlyDirectoryPermissions else {
                throw CodexReviewRecoveryEnvironmentError.directoryPermissionsMismatch(
                    url,
                    actual: effectivePermissions
                )
            }
        } catch let error as CodexReviewRecoveryEnvironmentError {
            throw error
        } catch {
            throw CodexReviewRecoveryEnvironmentError.directoryPreparationFailed(
                url,
                message: error.localizedDescription
            )
        }
    }

    private static func isSameOrDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let directoryComponents = directory.pathComponents
        guard candidateComponents.count >= directoryComponents.count else {
            return false
        }
        return candidateComponents.prefix(directoryComponents.count).elementsEqual(directoryComponents)
    }

    private static let ownerOnlyDirectoryPermissions = 0o700
}
