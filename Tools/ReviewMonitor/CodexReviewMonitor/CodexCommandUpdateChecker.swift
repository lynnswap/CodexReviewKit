import Foundation
@_spi(ApplicationHostSupport) import CodexReviewHost

struct CodexCommandUpdatePlan: Equatable, Sendable {
    let executableURL: URL
    let environment: [String: String]
}

enum CodexCommandUpdateCheckResult: Equatable, Sendable {
    case upToDate
    case unavailable(String)
    case manualUpdate(String)
    case available(CodexCommandUpdatePlan)
}

struct CodexCommandUpdateChecker: Sendable {
    typealias Resolve = @Sendable (
        _ configuredPath: String?,
        _ environment: [String: String]
    ) throws -> (launcherURL: URL, executableURL: URL)
    typealias Run = @Sendable (
        _ executableURL: URL,
        _ arguments: [String],
        _ environment: [String: String]
    ) async throws -> Data

    private let runtimePreferences: CodexReviewRuntime.Preferences
    private let sourceEnvironment: [String: String]
    private let resolve: Resolve
    private let run: Run

    init(
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resolve: @escaping Resolve = CodexReviewRuntime.resolveExecutable,
        run: @escaping Run = Self.runDoctor
    ) {
        self.runtimePreferences = CodexReviewRuntime.Preferences(
            codexHomePath: runtimePreferences.codexHomePath,
            mcpHost: runtimePreferences.mcpHost,
            mcpPort: runtimePreferences.mcpPort,
            mcpPath: runtimePreferences.mcpPath,
            codexExecutablePath: runtimePreferences.codexExecutablePath
        )
        self.sourceEnvironment = environment
        self.resolve = resolve
        self.run = run
    }

    @concurrent
    func check() async throws -> CodexCommandUpdateCheckResult {
        let selection = try resolve(runtimePreferences.codexExecutablePath, sourceEnvironment)
        let standaloneRoot = Self.standaloneRoot(for: selection.executableURL)
        let codexHomeURL = standaloneRoot?.deletingLastPathComponent().deletingLastPathComponent()
            ?? Self.codexHomeURL(environment: sourceEnvironment)
        var environment = Self.sanitizedEnvironment(
            sourceEnvironment,
            codexHomeURL: codexHomeURL,
            binURL: selection.launcherURL.deletingLastPathComponent()
        )
        // Script-based installations need their interpreter PATH for read-only checks.
        var checkEnvironment = environment
        if let path = sourceEnvironment["PATH"], path.isEmpty == false {
            checkEnvironment["PATH"] = path
        }
        let output = try await run(selection.executableURL, ["doctor", "--json"], checkEnvironment)
        let report = try JSONDecoder().decode(DoctorReport.self, from: output)
        guard let update = report.checks["updates.status"] else {
            throw CodexCommandUpdateCheckError.missingUpdateStatus
        }

        if case .scalar(let message) = update.details["latest version probe"] {
            throw CodexCommandUpdateCheckError.probeFailed(message)
        }

        switch try update.scalar(named: "latest version status") {
        case "current version is not older":
            return .upToDate
        case "newer version is available":
            break
        case let value:
            throw CodexCommandUpdateCheckError.invalidDetail(
                name: "latest version status", value: value
            )
        }

        let action = try? update.scalar(named: "update action")
        switch action {
        case "brew upgrade --cask codex" where Self.isStableHomebrewSelection(selection):
            break
        case "standalone installer":
            let installDirectory = selection.launcherURL.deletingLastPathComponent()
            guard let standaloneRoot,
                  selection.launcherURL.lastPathComponent == "codex",
                  Self.followsCurrentRelease(selection.launcherURL, root: standaloneRoot),
                  installDirectory.resolvingSymlinksInPath().path.hasPrefix(
                    standaloneRoot.appendingPathComponent("releases").path + "/"
                  ) == false else {
                return .manualUpdate("A newer Codex version is available. Select the standalone installation's stable launcher to update automatically.")
            }
            environment["CODEX_INSTALL_DIR"] = installDirectory.path
        default:
            return .manualUpdate("A newer Codex version is available. This installation must be updated outside ReviewMonitor.")
        }
        return .available(.init(executableURL: selection.launcherURL, environment: environment))
    }

    private static let systemPathEntries = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    private static func standaloneRoot(for executableURL: URL) -> URL? {
        var release = executableURL.deletingLastPathComponent()
        if release.lastPathComponent == "bin" { release.deleteLastPathComponent() }
        let releases = release.deletingLastPathComponent()
        let root = releases.deletingLastPathComponent()
        guard releases.lastPathComponent == "releases",
              root.lastPathComponent == "standalone",
              root.deletingLastPathComponent().lastPathComponent == "packages" else {
            return nil
        }
        return root
    }

    private static func followsCurrentRelease(_ launcherURL: URL, root: URL) -> Bool {
        let current = root.appendingPathComponent("current").path
        var url = launcherURL
        var visited: Set<String> = []
        while visited.insert(url.path).inserted {
            if url.path.hasPrefix(current + "/") { return true }
            var ancestor = url.deletingLastPathComponent()
            while ancestor.path != "/" {
                if ancestor.lastPathComponent == "current",
                   ancestor.deletingLastPathComponent().resolvingSymlinksInPath() == root {
                    return true
                }
                ancestor.deleteLastPathComponent()
            }
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
                return false
            }
            url = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : url.deletingLastPathComponent().appendingPathComponent(destination)
            url = url.standardizedFileURL
        }
        return false
    }

    private static func isStableHomebrewSelection(
        _ selection: (launcherURL: URL, executableURL: URL)
    ) -> Bool {
        for prefix in ["/opt/homebrew", "/usr/local"] {
            if selection.launcherURL.path == "\(prefix)/bin/codex",
               selection.executableURL.path.hasPrefix("\(prefix)/Caskroom/codex/") {
                return true
            }
        }
        return false
    }

    private static func codexHomeURL(
        environment: [String: String],
        homeDirectoryForCurrentUser: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           codexHome.isEmpty == false {
            return URL(fileURLWithPath: codexHome, isDirectory: true)
        }
        let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (home.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectoryForCurrentUser).appendingPathComponent(".codex", isDirectory: true)
    }

    private static func sanitizedEnvironment(
        _ source: [String: String], codexHomeURL: URL, binURL: URL
    ) -> [String: String] {
        var environment = source
        for key in source.keys where
            key.hasPrefix("CODEX_MANAGED_BY_") || key == "CODEX_MANAGED_PACKAGE_ROOT"
        {
            environment.removeValue(forKey: key)
        }
        environment["CODEX_HOME"] = codexHomeURL.path
        environment["CODEX_SQLITE_HOME"] = codexHomeURL.appendingPathComponent("sqlite", isDirectory: true).path
        environment["PATH"] = ([binURL.path] + systemPathEntries).joined(separator: ":")
        return environment
    }

    static func runDoctor(
        executableURL: URL, arguments: [String], environment: [String: String]
    ) async throws -> Data {
        let process = CancellableDoctorProcess(
            executableURL: executableURL, arguments: arguments, environment: environment
        )
        return try await withTaskCancellationHandler {
            let output = try await Task.detached(priority: .utility) { try process.run() }.value
            try Task.checkCancellation()
            return output
        } onCancel: {
            process.cancel()
        }
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
    case probeFailed(String)
    case missingUpdateStatus
    case missingDetail(String)
    case nonScalarDetail(String)
    case invalidDetail(name: String, value: String)

    var errorDescription: String? {
        switch self {
        case .probeFailed(let message):
            "The latest Codex version could not be checked. \(message)"
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
