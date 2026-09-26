import Foundation
import CodexReviewHost

struct CodexCommandUpdatePlan: Equatable, Sendable {
    let executableURL: URL
    let environment: [String: String]
}

enum CodexCommandUpdateCheckResult: Equatable, Sendable {
    case disabled
    case unavailable
    case available(CodexCommandUpdatePlan)
}

struct CodexCommandUpdateChecker: Sendable {
    typealias Run = @Sendable (
        _ executableURL: URL,
        _ arguments: [String],
        _ environment: [String: String]
    ) async throws -> Data

    private let runtimePreferences: CodexReviewRuntime.Preferences
    private let sourceEnvironment: [String: String]
    private let resolver: CodexHomebrewInstallationResolver
    private let run: Run

    init(
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.init(
            runtimePreferences: runtimePreferences,
            environment: environment,
            resolver: .live(),
            run: Self.runDoctor
        )
    }

    init(
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        environment: [String: String],
        resolver: CodexHomebrewInstallationResolver,
        run: @escaping Run
    ) {
        self.runtimePreferences = CodexReviewRuntime.Preferences(
            codexHomePath: runtimePreferences.codexHomePath,
            mcpHost: runtimePreferences.mcpHost,
            mcpPort: runtimePreferences.mcpPort,
            mcpPath: runtimePreferences.mcpPath,
            codexExecutablePath: runtimePreferences.codexExecutablePath
        )
        self.sourceEnvironment = environment
        self.resolver = resolver
        self.run = run
    }

    func check() async throws -> CodexCommandUpdateCheckResult {
        guard let installation = try resolver.resolve(
            configuredPath: runtimePreferences.codexExecutablePath,
            environment: sourceEnvironment
        ) else {
            return .unavailable
        }
        let codexHomeURL = runtimePreferences.codexHomePath.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? Self.codexHomeURL(environment: sourceEnvironment)
        let environment = Self.sanitizedEnvironment(
            sourceEnvironment,
            codexHomeURL: codexHomeURL,
            homebrewBinURL: installation.binURL
        )
        let output = try await run(
            installation.executableURL,
            ["doctor", "--json"],
            environment
        )
        let report = try JSONDecoder().decode(DoctorReport.self, from: output)
        guard report.schemaVersion == 1 else {
            throw CodexCommandUpdateCheckError.unsupportedSchema(report.schemaVersion)
        }
        guard let update = report.checks["updates.status"] else {
            throw CodexCommandUpdateCheckError.missingUpdateStatus
        }

        switch try update.scalar(named: "check for update on startup") {
        case "false":
            return .disabled
        case "true":
            break
        case let value:
            throw CodexCommandUpdateCheckError.invalidDetail(
                name: "check for update on startup",
                value: value
            )
        }

        switch try update.scalar(named: "latest version status") {
        case "current version is not older":
            return .unavailable
        case "newer version is available":
            break
        case let value:
            throw CodexCommandUpdateCheckError.invalidDetail(
                name: "latest version status",
                value: value
            )
        }

        guard try update.scalar(named: "update action")
            == "brew upgrade --cask codex" else {
            return .unavailable
        }
        return .available(.init(
            executableURL: installation.launcherURL,
            environment: environment
        ))
    }

    private static let systemPathEntries = [
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    private static func codexHomeURL(
        environment: [String: String],
        homeDirectoryForCurrentUser: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let codexHome = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           codexHome.isEmpty == false {
            return URL(fileURLWithPath: codexHome, isDirectory: true)
        }
        if let home = environment["HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           home.isEmpty == false {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".codex_review", isDirectory: true)
        }
        return homeDirectoryForCurrentUser
            .appendingPathComponent(".codex_review", isDirectory: true)
    }

    private static func sanitizedEnvironment(
        _ source: [String: String],
        codexHomeURL: URL,
        homebrewBinURL: URL
    ) -> [String: String] {
        var environment = source
        for key in source.keys where
            key.hasPrefix("CODEX_MANAGED_BY_") || key == "CODEX_MANAGED_PACKAGE_ROOT"
        {
            environment.removeValue(forKey: key)
        }

        environment["CODEX_HOME"] = codexHomeURL.path
        environment["CODEX_SQLITE_HOME"] = codexHomeURL
            .appendingPathComponent("sqlite", isDirectory: true)
            .path
        environment["PATH"] = ([homebrewBinURL.path] + systemPathEntries)
            .joined(separator: ":")
        return environment
    }

    static func runDoctor(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> Data {
        let process = CancellableDoctorProcess(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment
        )
        return try await withTaskCancellationHandler {
            let output = try await Task.detached(priority: .utility) {
                try process.run()
            }.value
            try Task.checkCancellation()
            return output
        } onCancel: {
            process.cancel()
        }
    }
}

struct CodexHomebrewInstallationResolver: Sendable {
    struct Installation: Equatable, Sendable {
        let launcherURL: URL
        let executableURL: URL
        let binURL: URL
    }

    struct FileSystem: Sendable {
        var canonicalURL: @Sendable (URL) -> URL
        var isExecutableRegularFile: @Sendable (URL) -> Bool

        static let live = FileSystem(
            canonicalURL: { $0.standardizedFileURL.resolvingSymlinksInPath() },
            isExecutableRegularFile: { url in
                let manager = FileManager.default
                guard manager.isExecutableFile(atPath: url.path),
                      let attributes = try? manager.attributesOfItem(atPath: url.path)
                else {
                    return false
                }
                return attributes[.type] as? FileAttributeType == .typeRegular
            }
        )
    }

    struct Configuration: Sendable {
        var homeDirectory: URL
        var fallbackBinDirectories: [URL]
        var fileSystem: FileSystem

        static func live() -> Self {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return .init(
                homeDirectory: home,
                fallbackBinDirectories: [
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                    "/usr/bin",
                    "/bin",
                    "/usr/sbin",
                    "/sbin",
                ].map { URL(fileURLWithPath: $0, isDirectory: true) },
                fileSystem: .live
            )
        }
    }

    private struct Selection {
        let launcherURL: URL
        let executableURL: URL
    }

    private let configuration: Configuration

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    static func live() -> Self {
        .init(configuration: .live())
    }

    func resolve(
        configuredPath: String?,
        environment: [String: String]
    ) throws -> Installation? {
        if let configuredPath {
            return installation(for: try explicitSelection(configuredPath))
        }

        let path = pathDirectories(environment["PATH"])
        for key in [
            "CODEX_APP_SERVER_CODEX_EXECUTABLE",
            "CODEX_REVIEW_CODEX_EXECUTABLE",
            "CODEX_EXECUTABLE",
        ] {
            guard let command = environment[key] else {
                continue
            }
            return installation(for: try environmentSelection(command, path: path))
        }

        for directory in path {
            if let selection = candidate(directory.appendingPathComponent("codex")) {
                return installation(for: selection)
            }
        }

        if candidate(
            configuration.homeDirectory.appendingPathComponent(".local/bin/codex")
        ) != nil {
            return nil
        }

        for directory in configuration.fallbackBinDirectories {
            if let selection = candidate(directory.appendingPathComponent("codex")) {
                return installation(for: selection)
            }
        }
        throw CodexHomebrewInstallationResolutionError.notFound
    }

    private func explicitSelection(_ value: String) throws -> Selection {
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"),
              let selection = candidate(URL(fileURLWithPath: path)) else {
            throw CodexHomebrewInstallationResolutionError.invalidExplicit
        }
        return selection
    }

    private func environmentSelection(
        _ value: String,
        path: [URL]
    ) throws -> Selection {
        let command = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.contains("/") {
            guard command.hasPrefix("/"),
                  let selection = candidate(URL(fileURLWithPath: command)) else {
                throw CodexHomebrewInstallationResolutionError.invalidExplicit
            }
            return selection
        }
        if command.isEmpty == false {
            for directory in path {
                if let selection = candidate(directory.appendingPathComponent(command)) {
                    return selection
                }
            }
        }
        throw CodexHomebrewInstallationResolutionError.invalidExplicit
    }

    private func candidate(_ launcherURL: URL) -> Selection? {
        let executableURL = configuration.fileSystem
            .canonicalURL(launcherURL)
            .standardizedFileURL
        guard configuration.fileSystem.isExecutableRegularFile(executableURL) else {
            return nil
        }
        return Selection(
            launcherURL: launcherURL.standardizedFileURL,
            executableURL: executableURL
        )
    }

    private func installation(for selection: Selection) -> Installation? {
        let launcherPath = selection.launcherURL.path
        let executablePath = selection.executableURL.path
        for prefix in ["/opt/homebrew", "/usr/local"] {
            guard launcherPath == "\(prefix)/bin/codex" else {
                continue
            }
            let caskRoot = "\(prefix)/Caskroom/codex/"
            guard executablePath.hasPrefix(caskRoot) else {
                return nil
            }
            let components = executablePath
                .dropFirst(caskRoot.count)
                .split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == 3,
                  components[0].isEmpty == false,
                  components[1] == "bin",
                  components[2] == "codex" else {
                return nil
            }
            return Installation(
                launcherURL: selection.launcherURL,
                executableURL: selection.executableURL,
                binURL: URL(fileURLWithPath: "\(prefix)/bin", isDirectory: true)
            )
        }
        return nil
    }

    private func pathDirectories(_ path: String?) -> [URL] {
        (path ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
    }
}

private final class CancellableDoctorProcess: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let stateLock = NSLock()
    private var cancellationRequested = false
    private var launched = false

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    func run() throws -> Data {
        stateLock.lock()
        if cancellationRequested {
            stateLock.unlock()
            throw CancellationError()
        }
        do {
            try process.run()
            launched = true
            stateLock.unlock()
        } catch {
            stateLock.unlock()
            throw error
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if stateLock.withLock({ cancellationRequested }) {
            throw CancellationError()
        }
        return data
    }

    func cancel() {
        stateLock.withLock {
            cancellationRequested = true
            if launched, process.isRunning {
                process.terminate()
            }
        }
    }
}

private struct DoctorReport: Decodable {
    let schemaVersion: Int
    let checks: [String: DoctorCheck]
}

private struct DoctorCheck: Decodable {
    let details: [String: DoctorDetail]

    func scalar(named name: String) throws -> String {
        guard let detail = details[name] else {
            throw CodexCommandUpdateCheckError.missingDetail(name)
        }
        guard case .scalar(let value) = detail else {
            throw CodexCommandUpdateCheckError.nonScalarDetail(name)
        }
        return value
    }
}

private enum DoctorDetail: Decodable {
    case scalar(String)
    case multiple([String])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let scalar = try? container.decode(String.self) {
            self = .scalar(scalar)
        } else {
            self = .multiple(try container.decode([String].self))
        }
    }
}

private enum CodexCommandUpdateCheckError: LocalizedError {
    case unsupportedSchema(Int)
    case missingUpdateStatus
    case missingDetail(String)
    case nonScalarDetail(String)
    case invalidDetail(name: String, value: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "Codex returned unsupported doctor schema version \(version)."
        case .missingUpdateStatus:
            "Codex did not include updates.status in its doctor report."
        case .missingDetail(let name):
            "Codex did not include \(name) in its update status."
        case .nonScalarDetail(let name):
            "Codex returned multiple values for \(name) in its update status."
        case .invalidDetail(let name, let value):
            "Codex returned unsupported \(name) value: \(value)."
        }
    }
}

private enum CodexHomebrewInstallationResolutionError: LocalizedError {
    case invalidExplicit
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidExplicit:
            "The explicitly selected Codex executable is invalid."
        case .notFound:
            "No usable Codex executable was found."
        }
    }
}
