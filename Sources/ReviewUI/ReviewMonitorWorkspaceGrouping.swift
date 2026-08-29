import Foundation
import CodexReview

struct ReviewMonitorWorkspaceSectionSelection: Hashable, Sendable {
    var id: String
    var title: String
    var workspaceCWDs: [String]

    var subtitle: String {
        workspaceCWDs.count == 1 ? (workspaceCWDs.first ?? "") : "\(workspaceCWDs.count) workspaces"
    }
}

struct ReviewMonitorWorkspaceSectionIdentity: Hashable, Sendable {
    var id: String
    var title: String
}

struct ReviewMonitorWorkspacePresentation: Hashable, Sendable {
    var sectionIdentity: ReviewMonitorWorkspaceSectionIdentity
    var isWorktree: Bool
}

enum ReviewMonitorWorkspaceSectioning {
    private struct Candidate {
        var cwd: String
        var metadata: ReviewWorkspaceMetadata
        var legacyManagedWorktreeTitle: String?
    }

    @MainActor
    static func presentations(
        for workspaces: [CodexReviewWorkspace],
        fileManager: FileManager = .default,
        managedWorktreeRoots: [URL]? = nil
    ) -> [String: ReviewMonitorWorkspacePresentation] {
        let managedWorktreeRoots = managedWorktreeRoots ?? defaultManagedWorktreeRoots()
        let candidates = workspaces.map { workspace in
            let resolvedMetadata = workspace.metadata
                ?? ReviewWorkspaceMetadata.resolve(cwd: workspace.cwd, fileManager: fileManager)
            let legacyManagedWorktreeTitle: String?
            if workspace.metadata == nil,
               resolvedMetadata.kind == .directory,
               fileManager.fileExists(atPath: workspace.cwd) == false
            {
                legacyManagedWorktreeTitle = managedWorktreeRepositoryTitle(
                    cwd: workspace.cwd,
                    roots: managedWorktreeRoots
                )
            } else {
                legacyManagedWorktreeTitle = nil
            }
            return Candidate(
                cwd: workspace.cwd,
                metadata: resolvedMetadata,
                legacyManagedWorktreeTitle: legacyManagedWorktreeTitle
            )
        }

        var verifiedGitIdentitiesByTitle: [String: Set<ReviewMonitorWorkspaceSectionIdentity>] = [:]
        for candidate in candidates where candidate.metadata.kind != .directory {
            let identity = sectionIdentity(for: candidate.metadata)
            verifiedGitIdentitiesByTitle[identity.title, default: []].insert(identity)
        }

        return Dictionary(uniqueKeysWithValues: candidates.map { candidate in
            let fallbackIdentity = sectionIdentity(for: candidate.metadata)
            let recoveredIdentity: ReviewMonitorWorkspaceSectionIdentity?
            if let repositoryTitle = candidate.legacyManagedWorktreeTitle,
               let identities = verifiedGitIdentitiesByTitle[repositoryTitle],
               identities.count == 1
            {
                recoveredIdentity = identities.first
            } else {
                recoveredIdentity = nil
            }
            return (
                candidate.cwd,
                ReviewMonitorWorkspacePresentation(
                    sectionIdentity: recoveredIdentity ?? fallbackIdentity,
                    isWorktree: candidate.metadata.isWorktree
                        || candidate.legacyManagedWorktreeTitle != nil
                )
            )
        })
    }

    private static func sectionIdentity(
        for metadata: ReviewWorkspaceMetadata
    ) -> ReviewMonitorWorkspaceSectionIdentity {
        ReviewMonitorWorkspaceSectionIdentity(
            id: metadata.repositoryIdentity,
            title: metadata.displayTitle
        )
    }

    private static func defaultManagedWorktreeRoots() -> [URL] {
        var roots: [URL] = []
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"],
           codexHome.isEmpty == false,
           codexHome.hasPrefix("/")
        {
            roots.append(
                URL(fileURLWithPath: codexHome, isDirectory: true)
                    .appendingPathComponent("worktrees", isDirectory: true)
            )
        }
        roots.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("worktrees", isDirectory: true)
        )
        var seenPaths: Set<String> = []
        return roots.compactMap { root in
            let standardized = root.standardizedFileURL.resolvingSymlinksInPath()
            return seenPaths.insert(standardized.path).inserted ? standardized : nil
        }
    }

    private static func managedWorktreeRepositoryTitle(
        cwd: String,
        roots: [URL]
    ) -> String? {
        let cwdComponents = URL(fileURLWithPath: cwd, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .pathComponents
        for root in roots {
            let rootComponents = root.standardizedFileURL
                .resolvingSymlinksInPath()
                .pathComponents
            guard cwdComponents.count == rootComponents.count + 2,
                  Array(cwdComponents.prefix(rootComponents.count)) == rootComponents
            else {
                continue
            }
            let bucket = cwdComponents[rootComponents.count]
            let repositoryTitle = cwdComponents[rootComponents.count + 1]
            guard bucket.count == 4,
                  bucket.utf8.allSatisfy({ $0.isASCIIHexDigit }),
                  repositoryTitle.isEmpty == false
            else {
                continue
            }
            return repositoryTitle
        }
        return nil
    }
}

private extension UInt8 {
    var isASCIIHexDigit: Bool {
        switch self {
        case 48...57, 65...70, 97...102:
            true
        default:
            false
        }
    }
}
