import Foundation

package struct CodexExecutableResolutionError: LocalizedError, Equatable, Sendable {
    package enum Kind: Equatable, Sendable { case invalidExplicit, notFound }
    package enum Source: Equatable, Sendable {
        case configuredPath, environment(String), path(String), homeLocalBin
        case applicationBundle(String), fallbackBin(String)
    }
    package struct Trace: Equatable, Sendable {
        package var source: Source
        package var candidate, reason: String
    }
    package var kind: Kind
    package var trace: [Trace]
    package var errorDescription: String? {
        let headline = kind == .invalidExplicit
            ? "The explicitly selected Codex executable is invalid."
            : "No usable Codex executable was found."
        return ([headline] + trace.map { "\($0.source): \($0.candidate) — \($0.reason)" })
            .joined(separator: "\n")
    }
}

package struct CodexExecutableResolver: Sendable {
    package struct FileSystem: Sendable {
        package var canonicalURL: @Sendable (URL) -> URL
        package var isExecutableRegularFile: @Sendable (URL) -> Bool
        package var isDirectory: @Sendable (URL) -> Bool
        package var bundleIdentifier: @Sendable (URL) -> String?
        package init(
            canonicalURL: @escaping @Sendable (URL) -> URL,
            isExecutableRegularFile: @escaping @Sendable (URL) -> Bool,
            isDirectory: @escaping @Sendable (URL) -> Bool,
            bundleIdentifier: @escaping @Sendable (URL) -> String?
        ) {
            (self.canonicalURL, self.isExecutableRegularFile, self.isDirectory, self.bundleIdentifier) =
                (canonicalURL, isExecutableRegularFile, isDirectory, bundleIdentifier)
        }
        package static let live = FileSystem(
            canonicalURL: { $0.standardizedFileURL.resolvingSymlinksInPath() },
            isExecutableRegularFile: { url in
                let manager = FileManager.default
                guard manager.isExecutableFile(atPath: url.path),
                      let attributes = try? manager.attributesOfItem(atPath: url.path)
                else { return false }
                return attributes[.type] as? FileAttributeType == .typeRegular
            },
            isDirectory: { url in
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                else { return false }
                return attributes[.type] as? FileAttributeType == .typeDirectory
            },
            bundleIdentifier: { bundle in
                let plist = bundle.appendingPathComponent("Contents/Info.plist")
                guard let data = try? Data(contentsOf: plist),
                      let value = try? PropertyListSerialization.propertyList(
                        from: data, options: [], format: nil
                      ),
                      let dictionary = value as? [String: Any]
                else { return nil }
                return dictionary["CFBundleIdentifier"] as? String
            }
        )
    }

    package struct Configuration: Sendable {
        package var homeDirectory: URL
        package var applicationDirectories: [URL]
        package var fallbackBinDirectories: [URL]
        package var fileSystem: FileSystem
        package var versionProbe: CodexExecutableVersionProbe
        package init(
            homeDirectory: URL,
            applicationDirectories: [URL],
            fallbackBinDirectories: [URL],
            fileSystem: FileSystem,
            versionProbe: CodexExecutableVersionProbe
        ) {
            self.homeDirectory = homeDirectory
            self.applicationDirectories = applicationDirectories
            self.fallbackBinDirectories = fallbackBinDirectories
            self.fileSystem = fileSystem
            self.versionProbe = versionProbe
        }
        package static func live() -> Self {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return .init(
                homeDirectory: home,
                applicationDirectories: [
                    URL(fileURLWithPath: "/Applications", isDirectory: true),
                    home.appendingPathComponent("Applications", isDirectory: true),
                ],
                fallbackBinDirectories: [
                    "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                ].map { URL(fileURLWithPath: $0, isDirectory: true) },
                fileSystem: .live,
                versionProbe: .live
            )
        }
    }

    private let configuration: Configuration
    package init(configuration: Configuration) { self.configuration = configuration }
    package func resolve(
        configuredPath: String?, environment: [String: String]
    ) async throws(CodexExecutableResolutionError) -> URL {
        var search = Search(configuration: configuration)
        if let configuredPath { return try search.explicitPath(configuredPath) }
        let path = Self.pathDirectories(environment["PATH"])
        // A present override owns failure; automatic candidates below must not replace it.
        for key in [
            "CODEX_APP_SERVER_CODEX_EXECUTABLE",
            "CODEX_REVIEW_CODEX_EXECUTABLE",
            "CODEX_EXECUTABLE",
        ] where environment[key] != nil {
            return try search.environmentCommand(environment[key]!, key: key, path: path)
        }
        if path.isEmpty {
            search.trace.append(.init(
                source: .path(environment["PATH"] ?? "(missing)"),
                candidate: "codex",
                reason: "PATH is missing or empty"
            ))
        }
        var candidates: [Search.Candidate] = []
        for directory in path {
            if let url = search.candidate(directory.appendingPathComponent("codex"), .path(directory.path)) {
                candidates.append(url)
            }
        }
        // GUI/launchd HOME can be absent or unrelated; the OS account home owns this fallback.
        if let url = search.candidate(
            configuration.homeDirectory.appendingPathComponent(".local/bin/codex"), .homeLocalBin
        ) { candidates.append(url) }
        for root in configuration.applicationDirectories {
            for name in ["ChatGPT.app", "Codex.app"] {
                if let url = search.bundle(root.appendingPathComponent(name)) { candidates.append(url) }
            }
        }
        for directory in configuration.fallbackBinDirectories {
            if let url = search.candidate(
                directory.appendingPathComponent("codex"), .fallbackBin(directory.path)
            ) { candidates.append(url) }
        }
        return try await search.newestCandidate(
            candidates,
            environment: environment,
            versionProbe: configuration.versionProbe
        )
    }
    private static func pathDirectories(_ path: String?) -> [URL] {
        (path ?? "").split(separator: ":", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
    }
    private struct Search {
        struct Candidate: Sendable {
            var url: URL
            var source: CodexExecutableResolutionError.Source
        }

        var configuration: Configuration
        var seen: Set<String> = []
        var trace: [CodexExecutableResolutionError.Trace] = []
        mutating func explicitPath(_ value: String) throws(CodexExecutableResolutionError) -> URL {
            let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/") else { try failExplicit(.configuredPath, value, "not absolute") }
            if let candidate = candidate(URL(fileURLWithPath: path), .configuredPath) { return candidate.url }
            throw .init(kind: .invalidExplicit, trace: trace)
        }
        mutating func environmentCommand(
            _ value: String, key: String, path: [URL]
        ) throws(CodexExecutableResolutionError) -> URL {
            let command = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let source = CodexExecutableResolutionError.Source.environment(key)
            if command.contains("/") {
                guard command.hasPrefix("/") else { try failExplicit(source, value, "not absolute") }
                if let candidate = candidate(URL(fileURLWithPath: command), source) { return candidate.url }
            } else if command.isEmpty == false {
                for directory in path {
                    if let candidate = candidate(directory.appendingPathComponent(command), source) {
                        return candidate.url
                    }
                }
                if path.isEmpty { trace.append(.init(source: source, candidate: command, reason: "PATH is empty")) }
            } else {
                trace.append(.init(source: source, candidate: value, reason: "command is empty"))
            }
            throw .init(kind: .invalidExplicit, trace: trace)
        }
        mutating func bundle(_ rawBundle: URL) -> Candidate? {
            let fs = configuration.fileSystem
            let bundle = fs.canonicalURL(rawBundle).standardizedFileURL
            let source = CodexExecutableResolutionError.Source.applicationBundle(rawBundle.path)
            guard fs.isDirectory(bundle) else { return reject(source, bundle.path, "not a directory") }
            let identifier = fs.bundleIdentifier(bundle)
            guard identifier == "com.openai.codex" else {
                return reject(source, bundle.path, "bundle identifier is \(identifier ?? "missing")")
            }
            return candidate(bundle.appendingPathComponent("Contents/Resources/codex"), source)
        }
        mutating func candidate(
            _ rawURL: URL,
            _ source: CodexExecutableResolutionError.Source
        ) -> Candidate? {
            let fs = configuration.fileSystem
            let url = fs.canonicalURL(rawURL).standardizedFileURL
            guard seen.insert(url.path).inserted else {
                return reject(source, rawURL.path, "duplicate of \(url.path)")
            }
            guard fs.isExecutableRegularFile(url) else {
                return reject(source, url.path, "not an executable regular file")
            }
            return .init(url: url, source: source)
        }

        mutating func newestCandidate(
            _ candidates: [Candidate],
            environment: [String: String],
            versionProbe: CodexExecutableVersionProbe
        ) async throws(CodexExecutableResolutionError) -> URL {
            let results = await withTaskGroup(
                of: (Int, Result<String, CodexExecutableVersionProbe.Failure>).self,
                returning: [Result<String, CodexExecutableVersionProbe.Failure>?].self
            ) { group in
                for (index, candidate) in candidates.enumerated() {
                    group.addTask {
                        (
                            index,
                            await versionProbe(candidate.url, environment: environment)
                        )
                    }
                }
                var results = Array<Result<String, CodexExecutableVersionProbe.Failure>?>(
                    repeating: nil,
                    count: candidates.count
                )
                for await (index, result) in group {
                    results[index] = result
                }
                return results
            }

            var newest: (candidate: Candidate, version: CodexExecutableVersion)?
            for (candidate, result) in zip(candidates, results) {
                guard let result else { continue }
                switch result {
                case .success(let output):
                    guard let version = CodexExecutableVersion(codexVersionOutput: output) else {
                        trace.append(.init(
                            source: candidate.source,
                            candidate: candidate.url.path,
                            reason: "version probe returned an invalid codex-cli semantic version"
                        ))
                        continue
                    }
                    if let current = newest {
                        if current.version < version {
                            newest = (candidate, version)
                        }
                    } else {
                        newest = (candidate, version)
                    }
                case .failure(let failure):
                    trace.append(.init(
                        source: candidate.source,
                        candidate: candidate.url.path,
                        reason: failure.reason
                    ))
                }
            }
            guard let newest else {
                throw .init(kind: .notFound, trace: trace)
            }
            return newest.candidate.url
        }
        mutating func reject(
            _ source: CodexExecutableResolutionError.Source, _ candidate: String, _ reason: String
        ) -> Candidate? {
            trace.append(.init(source: source, candidate: candidate, reason: reason))
            return nil
        }
        mutating func failExplicit(
            _ source: CodexExecutableResolutionError.Source, _ candidate: String, _ reason: String
        ) throws(CodexExecutableResolutionError) -> Never {
            trace.append(.init(source: source, candidate: candidate, reason: reason))
            throw .init(kind: .invalidExplicit, trace: trace)
        }
    }
}
