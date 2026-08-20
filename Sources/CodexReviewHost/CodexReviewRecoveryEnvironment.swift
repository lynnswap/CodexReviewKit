import Foundation
import Darwin
import CodexReviewAppServer

package enum CodexReviewRecoveryEnvironmentError: Error, Equatable, LocalizedError, Sendable {
    case invalidDirectoryURL(URL)
    case unsafeCodexHome(URL)
    case legacyCodexHome(URL)
    case symbolicLinkDirectory(URL)
    case directoryPreparationFailed(URL, message: String)
    case directoryOwnershipMismatch(URL, expected: Int, actual: Int)
    case directoryPermissionsMismatch(URL, actual: Int)
    case invalidLoginStagingDirectory(URL)
    case directoryRemovalFailed(URL, message: String)
    case loginStagingRollbackFailed(URL, preparation: String, cleanup: String)

    package var errorDescription: String? {
        switch self {
        case .invalidDirectoryURL(let url):
            "RecoveryV1 requires an absolute file URL, but received \(url.absoluteString)."
        case .unsafeCodexHome(let url):
            "RecoveryV1 requires a dedicated Codex home and cannot use \(url.path)."
        case .legacyCodexHome(let url):
            "The legacy Codex home at \(url.path) is a read-only migration input and cannot be used by RecoveryV1."
        case .symbolicLinkDirectory(let url):
            "RecoveryV1 cannot claim ownership of the symbolic-link directory at \(url.path)."
        case .directoryPreparationFailed(let url, let message):
            "Unable to prepare the RecoveryV1 directory at \(url.path): \(message)"
        case .directoryOwnershipMismatch(let url, let expected, let actual):
            "RecoveryV1 requires \(url.path) to be owned by user \(expected), but found owner \(actual)."
        case .directoryPermissionsMismatch(let url, let actual):
            "RecoveryV1 requires owner-only permissions at \(url.path), but found \(String(format: "%03o", actual))."
        case .invalidLoginStagingDirectory(let url):
            "RecoveryV1 cannot remove an unowned login staging directory at \(url.path)."
        case .directoryRemovalFailed(let url, let message):
            "Unable to remove the RecoveryV1 login staging directory at \(url.path): \(message)"
        case .loginStagingRollbackFailed(let url, let preparation, let cleanup):
            "Unable to roll back the RecoveryV1 login staging directory at \(url.path) after preparation failed (preparation: \(preparation); cleanup: \(cleanup))."
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

    package var codexSQLiteHomeURL: URL {
        AppServerCodexHome.sqliteHomeURL(for: codexHomeURL)
    }

    package var recoveryTrustRootURL: URL {
        legacyCodexHomeURL.deletingLastPathComponent()
    }

    private let legacyCodexHomeURL: URL
    private let usesExplicitCodexHome: Bool

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
        let defaultCodexHomeURL = recoveryDirectoryURL
            .appending(path: "CodexHome", directoryHint: .isDirectory)
        self.recoveryDirectoryURL = recoveryDirectoryURL
        self.codexHomeURL = codexHomeURL ?? defaultCodexHomeURL
        self.loginStagingDirectoryURL = recoveryDirectoryURL
            .appending(path: "LoginStaging", directoryHint: .isDirectory)
        self.savedAccountsDirectoryURL = recoveryDirectoryURL
            .appending(path: "SavedAccounts", directoryHint: .isDirectory)
        self.historyDatabaseURL = recoveryDirectoryURL
            .appending(path: "review-history.sqlite", directoryHint: .notDirectory)
        self.legacyCodexHomeURL = legacyCodexHomeURL
        self.usesExplicitCodexHome = codexHomeURL.map {
            $0.standardizedFileURL != defaultCodexHomeURL.standardizedFileURL
        } ?? false
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

    package func prepareLoginStagingCodexHome() async throws -> URL {
        try await prepareLoginStagingCodexHome(sessionID: UUID())
    }

    package func prepareLoginStagingCodexHome(sessionID: UUID) async throws -> URL {
        let url = loginStagingCodexHomeURL(sessionID: sessionID)
        let preparationTask = Task.detached(priority: .utility) {
            try Self.validateDirectoryURL(url)
            try Task.checkCancellation()
            for directoryURL in Self.codexRuntimeDirectoryURLs(codexHomeURL: url) {
                try Self.prepareOwnerOnlyDirectory(
                    at: directoryURL,
                    trustedRootURL: recoveryTrustRootURL
                )
                try Task.checkCancellation()
            }
        }
        do {
            try await withTaskCancellationHandler {
                try await preparationTask.value
                try Task.checkCancellation()
            } onCancel: {
                preparationTask.cancel()
            }
            return url
        } catch {
            let preparationError = error
            do {
                try await removeLoginStagingCodexHome(at: url)
            } catch {
                throw CodexReviewRecoveryEnvironmentError.loginStagingRollbackFailed(
                    url,
                    preparation: preparationError.localizedDescription,
                    cleanup: error.localizedDescription
                )
            }
            throw preparationError
        }
    }

    package func removeLoginStagingCodexHome(at url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try Self.validateExistingDirectoryChain(
                from: recoveryTrustRootURL,
                through: loginStagingDirectoryURL,
                reportedURL: url
            )
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

        if usesExplicitCodexHome {
            try Self.validateExplicitCodexHomeBoundary(
                codexHomeURL,
                recoveryDirectoryURL: recoveryDirectoryURL,
                legacyCodexHomeURL: legacyCodexHomeURL
            )
        }

        let recoveryTrustRootURL = recoveryTrustRootURL.standardizedFileURL
        let resolvedLegacyURL = legacyCodexHomeURL.standardizedFileURL.resolvingSymlinksInPath()
        let recoveryDirectoryURLs = [
            recoveryDirectoryURL,
            loginStagingDirectoryURL,
            savedAccountsDirectoryURL,
        ]
        let codexRuntimeDirectoryURLs = Self.codexRuntimeDirectoryURLs(codexHomeURL: codexHomeURL)
        let directoryURLs = recoveryDirectoryURLs + codexRuntimeDirectoryURLs
        for directoryURL in directoryURLs {
            let resolvedDirectoryURL = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
            guard Self.isSameOrDescendant(resolvedDirectoryURL, of: resolvedLegacyURL) == false else {
                throw CodexReviewRecoveryEnvironmentError.legacyCodexHome(directoryURL)
            }
        }

        for directoryURL in recoveryDirectoryURLs {
            try Self.prepareOwnerOnlyDirectory(
                at: directoryURL,
                trustedRootURL: recoveryTrustRootURL
            )
        }
        if usesExplicitCodexHome {
            let codexHomeTrustRootURL = codexHomeURL.standardizedFileURL
                .deletingLastPathComponent()
            try Self.prepareExplicitCodexHomeDirectory(
                at: codexHomeURL,
                trustedRootURL: codexHomeTrustRootURL
            )
            try Self.prepareOwnerOnlyDirectory(
                at: codexSQLiteHomeURL,
                trustedRootURL: codexHomeURL,
                withIntermediateDirectories: false
            )
        } else {
            for directoryURL in codexRuntimeDirectoryURLs {
                try Self.prepareOwnerOnlyDirectory(
                    at: directoryURL,
                    trustedRootURL: recoveryTrustRootURL
                )
            }
        }
    }

    private static func validateDirectoryURL(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw CodexReviewRecoveryEnvironmentError.invalidDirectoryURL(url)
        }
    }

    package static func prepareOwnerOnlyDirectory(
        at url: URL,
        trustedRootURL: URL,
        withIntermediateDirectories: Bool = true
    ) throws {
        let fileManager = FileManager.default
        do {
            try validateExistingDirectoryChain(
                from: trustedRootURL,
                through: url,
                reportedURL: url
            )
            var isDirectory = ObjCBool(false)
            let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if exists {
                guard isDirectory.boolValue else {
                    throw CocoaError(.fileWriteFileExists)
                }
            } else {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: withIntermediateDirectories,
                    attributes: [.posixPermissions: NSNumber(value: ownerOnlyDirectoryPermissions)]
                )
            }
            try validateDirectoryIsNotSymbolicLink(at: url, reportedURL: url)
            try validateDirectoryOwnership(at: url, reportedURL: url)
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

    private static func validateExplicitCodexHomeBoundary(
        _ url: URL,
        recoveryDirectoryURL: URL,
        legacyCodexHomeURL: URL
    ) throws {
        let standardizedURL = url.standardizedFileURL
        let resolvedURL = standardizedURL.resolvingSymlinksInPath()
        guard resolvedURL.path != "/" else {
            throw CodexReviewRecoveryEnvironmentError.unsafeCodexHome(url)
        }
        try validateExistingDirectoryChain(
            from: standardizedURL.deletingLastPathComponent(),
            through: standardizedURL,
            reportedURL: url
        )

        let resolvedLegacyURL = legacyCodexHomeURL.standardizedFileURL.resolvingSymlinksInPath()
        if isSameOrDescendant(resolvedURL, of: resolvedLegacyURL) {
            throw CodexReviewRecoveryEnvironmentError.legacyCodexHome(url)
        }
        guard isSameOrDescendant(resolvedLegacyURL, of: resolvedURL) == false else {
            throw CodexReviewRecoveryEnvironmentError.unsafeCodexHome(url)
        }

        let resolvedRecoveryURL = recoveryDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        guard pathsOverlap(resolvedURL, resolvedRecoveryURL) == false else {
            throw CodexReviewRecoveryEnvironmentError.unsafeCodexHome(url)
        }

        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory) {
            do {
                let resourceValues = try standardizedURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard resourceValues.isSymbolicLink != true else {
                    throw CodexReviewRecoveryEnvironmentError.unsafeCodexHome(url)
                }
            } catch let error as CodexReviewRecoveryEnvironmentError {
                throw error
            } catch {
                throw CodexReviewRecoveryEnvironmentError.directoryPreparationFailed(
                    url,
                    message: error.localizedDescription
                )
            }
            guard isDirectory.boolValue else {
                throw CodexReviewRecoveryEnvironmentError.directoryPreparationFailed(
                    url,
                    message: CocoaError(.fileWriteFileExists).localizedDescription
                )
            }
            try validateDirectoryOwnership(at: resolvedURL, reportedURL: url)
            try validateOwnerOnlyPermissions(at: resolvedURL, reportedURL: url)
            return
        }

        let parentURL = standardizedURL.deletingLastPathComponent().resolvingSymlinksInPath()
        var isParentDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: parentURL.path, isDirectory: &isParentDirectory),
              isParentDirectory.boolValue
        else {
            throw CodexReviewRecoveryEnvironmentError.unsafeCodexHome(url)
        }
        try validateDirectoryOwnership(at: parentURL, reportedURL: url)
    }

    private static func prepareExplicitCodexHomeDirectory(
        at url: URL,
        trustedRootURL: URL
    ) throws {
        let fileManager = FileManager.default
        do {
            try validateExistingDirectoryChain(
                from: trustedRootURL,
                through: url,
                reportedURL: url
            )
            var isDirectory = ObjCBool(false)
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else {
                    throw CocoaError(.fileWriteFileExists)
                }
            } else {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: ownerOnlyDirectoryPermissions)]
                )
            }
            let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
            try validateDirectoryIsNotSymbolicLink(at: url, reportedURL: url)
            try validateDirectoryOwnership(at: resolvedURL, reportedURL: url)
            try validateOwnerOnlyPermissions(at: resolvedURL, reportedURL: url)
        } catch let error as CodexReviewRecoveryEnvironmentError {
            throw error
        } catch {
            throw CodexReviewRecoveryEnvironmentError.directoryPreparationFailed(
                url,
                message: error.localizedDescription
            )
        }
    }

    private static func validateDirectoryOwnership(at url: URL, reportedURL: URL) throws {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.intValue ?? -1
            let expectedOwnerID = Int(geteuid())
            guard ownerID == expectedOwnerID else {
                throw CodexReviewRecoveryEnvironmentError.directoryOwnershipMismatch(
                    reportedURL,
                    expected: expectedOwnerID,
                    actual: ownerID
                )
            }
        } catch let error as CodexReviewRecoveryEnvironmentError {
            throw error
        } catch {
            throw CodexReviewRecoveryEnvironmentError.directoryPreparationFailed(
                reportedURL,
                message: error.localizedDescription
            )
        }
    }

    private static func validateOwnerOnlyPermissions(at url: URL, reportedURL: URL) throws {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            let effectivePermissions = permissions & 0o777
            guard effectivePermissions == ownerOnlyDirectoryPermissions else {
                throw CodexReviewRecoveryEnvironmentError.directoryPermissionsMismatch(
                    reportedURL,
                    actual: effectivePermissions
                )
            }
        } catch let error as CodexReviewRecoveryEnvironmentError {
            throw error
        } catch {
            throw CodexReviewRecoveryEnvironmentError.directoryPreparationFailed(
                reportedURL,
                message: error.localizedDescription
            )
        }
    }

    private static func validateDirectoryIsNotSymbolicLink(at url: URL, reportedURL: URL) throws {
        do {
            let resourceValues = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard resourceValues.isSymbolicLink != true else {
                throw CodexReviewRecoveryEnvironmentError.symbolicLinkDirectory(reportedURL)
            }
        } catch let error as CodexReviewRecoveryEnvironmentError {
            throw error
        } catch {
            throw CodexReviewRecoveryEnvironmentError.directoryPreparationFailed(
                reportedURL,
                message: error.localizedDescription
            )
        }
    }

    private static func validateExistingDirectoryChain(
        from trustedRootURL: URL,
        through targetURL: URL,
        reportedURL: URL
    ) throws {
        let trustedRootURL = trustedRootURL.standardizedFileURL
        let targetURL = targetURL.standardizedFileURL
        guard isSameOrDescendant(targetURL, of: trustedRootURL) else {
            throw CodexReviewRecoveryEnvironmentError.unsafeCodexHome(reportedURL)
        }

        var componentURLs = [trustedRootURL]
        var componentURL = trustedRootURL
        let remainingComponents = targetURL.pathComponents.dropFirst(
            trustedRootURL.pathComponents.count
        )
        for component in remainingComponents {
            componentURL.append(path: component, directoryHint: .isDirectory)
            componentURLs.append(componentURL)
        }
        for componentURL in componentURLs {
            var fileStatus = stat()
            guard lstat(componentURL.path, &fileStatus) == 0 else {
                let errorCode = errno
                if errorCode == ENOENT {
                    return
                }
                throw CodexReviewRecoveryEnvironmentError.directoryPreparationFailed(
                    componentURL,
                    message: String(cString: strerror(errorCode))
                )
            }
            let fileType = fileStatus.st_mode & mode_t(S_IFMT)
            guard fileType != mode_t(S_IFLNK) else {
                throw CodexReviewRecoveryEnvironmentError.symbolicLinkDirectory(componentURL)
            }
            guard fileType == mode_t(S_IFDIR) else {
                throw CodexReviewRecoveryEnvironmentError.directoryPreparationFailed(
                    componentURL,
                    message: CocoaError(.fileWriteFileExists).localizedDescription
                )
            }
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

    private static func pathsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
        isSameOrDescendant(lhs, of: rhs) || isSameOrDescendant(rhs, of: lhs)
    }

    private static func codexRuntimeDirectoryURLs(codexHomeURL: URL) -> [URL] {
        [
            codexHomeURL,
            AppServerCodexHome.sqliteHomeURL(for: codexHomeURL),
        ]
    }

    private static let ownerOnlyDirectoryPermissions = 0o700
}
