import Foundation
import Observation

package struct ReviewWorkspaceMetadata: Hashable, Sendable {
    package enum Kind: String, Hashable, Sendable {
        case directory
        case primaryCheckout
        case linkedWorktree
    }

    package let repositoryIdentity: String
    package let displayTitle: String
    package let kind: Kind

    package var isWorktree: Bool {
        kind == .linkedWorktree
    }

    package init(
        repositoryIdentity: String,
        displayTitle: String,
        kind: Kind
    ) {
        self.repositoryIdentity = repositoryIdentity
        self.displayTitle = displayTitle
        self.kind = kind
    }

    package static func resolve(
        cwd: String,
        fileManager: FileManager = .default
    ) -> ReviewWorkspaceMetadata {
        let cwdURL = standardizedDirectoryURL(cwd)
        guard let gitMetadataURL = enclosingGitMetadataURL(
            startingAt: cwdURL,
            fileManager: fileManager
        ) else {
            return directoryMetadata(for: cwdURL)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gitMetadataURL.path, isDirectory: &isDirectory) else {
            return directoryMetadata(for: cwdURL)
        }

        let gitRootURL = gitMetadataURL.deletingLastPathComponent()
        let commonDirURL: URL?
        let kind: Kind
        if isDirectory.boolValue {
            commonDirURL = gitMetadataURL
            kind = .primaryCheckout
        } else if let gitDirURL = linkedGitDirURL(from: gitMetadataURL) {
            if let linkedCommonDirURL = linkedCommonDirURL(for: gitDirURL) {
                commonDirURL = linkedCommonDirURL
                kind = .linkedWorktree
            } else {
                commonDirURL = gitDirURL
                kind = .primaryCheckout
            }
        } else {
            commonDirURL = nil
            kind = .directory
        }

        guard let commonDirURL else {
            return directoryMetadata(for: cwdURL)
        }

        let standardizedCommonDirURL = commonDirURL.standardizedFileURL.resolvingSymlinksInPath()
        return ReviewWorkspaceMetadata(
            repositoryIdentity: "git-common:\(standardizedCommonDirURL.path)",
            displayTitle: repositoryTitle(
                commonDirURL: standardizedCommonDirURL,
                gitRootURL: gitRootURL,
                fallbackURL: cwdURL
            ),
            kind: kind
        )
    }

    private static func enclosingGitMetadataURL(
        startingAt cwdURL: URL,
        fileManager: FileManager
    ) -> URL? {
        var directoryURL = cwdURL
        while true {
            let gitURL = directoryURL.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: gitURL.path) {
                return gitURL
            }

            let parentURL = directoryURL.deletingLastPathComponent()
            guard parentURL.path != directoryURL.path else {
                return nil
            }
            directoryURL = parentURL
        }
    }

    private static func linkedGitDirURL(from gitFileURL: URL) -> URL? {
        guard let contents = try? String(contentsOf: gitFileURL, encoding: .utf8),
              let firstLine = contents.split(whereSeparator: \.isNewline).first
        else {
            return nil
        }

        let prefix = "gitdir:"
        let line = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.lowercased().hasPrefix(prefix) else {
            return nil
        }

        let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty == false else {
            return nil
        }
        return resolvedURL(path: path, relativeTo: gitFileURL.deletingLastPathComponent())
    }

    private static func linkedCommonDirURL(for gitDirURL: URL) -> URL? {
        let commonDirFileURL = gitDirURL.appendingPathComponent("commondir")
        guard let contents = try? String(contentsOf: commonDirFileURL, encoding: .utf8),
              let firstLine = contents.split(whereSeparator: \.isNewline).first
        else {
            return nil
        }

        let path = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty == false else {
            return nil
        }
        return resolvedURL(path: path, relativeTo: gitDirURL)
    }

    private static func resolvedURL(path: String, relativeTo baseURL: URL) -> URL {
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : baseURL.appendingPathComponent(path, isDirectory: true)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func repositoryTitle(
        commonDirURL: URL,
        gitRootURL: URL,
        fallbackURL: URL
    ) -> String {
        if commonDirURL.lastPathComponent == ".git" {
            let title = commonDirURL.deletingLastPathComponent().lastPathComponent
            if title.isEmpty == false {
                return title
            }
        }

        let commonDirName = commonDirURL.lastPathComponent
        if commonDirName.hasSuffix(".git"), commonDirName.count > ".git".count {
            return String(commonDirName.dropLast(".git".count))
        }

        let rootTitle = gitRootURL.lastPathComponent
        return rootTitle.isEmpty ? fallbackTitle(for: fallbackURL) : rootTitle
    }

    private static func directoryMetadata(for url: URL) -> ReviewWorkspaceMetadata {
        ReviewWorkspaceMetadata(
            repositoryIdentity: "cwd:\(url.path)",
            displayTitle: fallbackTitle(for: url),
            kind: .directory
        )
    }

    private static func fallbackTitle(for url: URL) -> String {
        let title = url.lastPathComponent
        return title.isEmpty ? url.path : title
    }

    private static func standardizedDirectoryURL(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }
}

@MainActor
@Observable
public final class CodexReviewWorkspace: Hashable {
    public nonisolated let cwd: String
    package var metadata: ReviewWorkspaceMetadata?
    public package(set) var sortOrder: Double

    public nonisolated var displayTitle: String {
        let title = URL(fileURLWithPath: cwd).lastPathComponent
        return title.isEmpty ? cwd : title
    }

    public init(cwd: String, sortOrder: Double = 0) {
        self.cwd = cwd
        self.metadata = nil
        self.sortOrder = sortOrder
    }

    package convenience init(
        cwd: String,
        metadata: ReviewWorkspaceMetadata?,
        sortOrder: Double = 0
    ) {
        self.init(cwd: cwd, sortOrder: sortOrder)
        self.metadata = metadata
    }

    public nonisolated static func == (lhs: CodexReviewWorkspace, rhs: CodexReviewWorkspace) -> Bool {
        lhs.cwd == rhs.cwd
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(cwd)
    }
}
