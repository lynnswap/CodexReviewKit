import Foundation

struct ReviewMonitorWorkspaceSectionIdentity: Hashable, Sendable {
    var id: String
    var title: String
}

enum ReviewMonitorWorkspaceSectioning {
    static func identity(for cwd: String, fileManager: FileManager = .default) -> ReviewMonitorWorkspaceSectionIdentity {
        let cwdURL = standardizedDirectoryURL(cwd)
        guard let gitMetadataURL = enclosingGitMetadataURL(startingAt: cwdURL, fileManager: fileManager) else {
            return ReviewMonitorWorkspaceSectionIdentity(
                id: "cwd:\(cwdURL.path)",
                title: fallbackTitle(for: cwdURL)
            )
        }

        var isDirectory: ObjCBool = false
        let gitMetadataPath = gitMetadataURL.path
        guard fileManager.fileExists(atPath: gitMetadataPath, isDirectory: &isDirectory) else {
            return ReviewMonitorWorkspaceSectionIdentity(
                id: "cwd:\(cwdURL.path)",
                title: fallbackTitle(for: cwdURL)
            )
        }

        let gitRootURL = gitMetadataURL.deletingLastPathComponent()
        let commonDirURL: URL?
        if isDirectory.boolValue {
            commonDirURL = gitMetadataURL
        } else if let gitDirURL = linkedGitDirURL(from: gitMetadataURL) {
            commonDirURL = linkedCommonDirURL(for: gitDirURL) ?? gitDirURL
        } else {
            commonDirURL = nil
        }

        guard let commonDirURL else {
            return ReviewMonitorWorkspaceSectionIdentity(
                id: "cwd:\(cwdURL.path)",
                title: fallbackTitle(for: cwdURL)
            )
        }

        let standardizedCommonDirURL = commonDirURL.standardizedFileURL.resolvingSymlinksInPath()
        return ReviewMonitorWorkspaceSectionIdentity(
            id: "git-common:\(standardizedCommonDirURL.path)",
            title: sectionTitle(commonDirURL: standardizedCommonDirURL, gitRootURL: gitRootURL, fallbackURL: cwdURL)
        )
    }

    private static func enclosingGitMetadataURL(startingAt cwdURL: URL, fileManager: FileManager) -> URL? {
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

    private static func sectionTitle(
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
