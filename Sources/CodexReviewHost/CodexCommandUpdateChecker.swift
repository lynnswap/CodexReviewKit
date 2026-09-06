import Foundation
import CodexReviewAppServer

@_spi(ApplicationHostSupport)
public struct CodexCommandUpdatePlan: Equatable, Sendable {
    public let executableURL: URL
    public let environment: [String: String]

    public init(executableURL: URL, environment: [String: String]) {
        self.executableURL = executableURL
        self.environment = environment
    }
}

@_spi(ApplicationHostSupport)
public enum CodexCommandUpdateCheckResult: Equatable, Sendable {
    case disabled
    case unavailable
    case available(CodexCommandUpdatePlan)
}

@_spi(ApplicationHostSupport)
public struct CodexCommandUpdateChecker: Sendable {
    package typealias Run = @Sendable (
        _ executableURL: URL,
        _ arguments: [String],
        _ environment: [String: String]
    ) async throws -> Data

    private let runtimePreferences: CodexReviewRuntime.Preferences
    private let sourceEnvironment: [String: String]
    private let resolver: CodexExecutableResolver
    private let run: Run

    public init(
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.init(
            runtimePreferences: runtimePreferences,
            environment: environment,
            resolver: CodexExecutableResolver(configuration: .live()),
            run: Self.runDoctor
        )
    }

    package init(
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        environment: [String: String],
        resolver: CodexExecutableResolver,
        run: @escaping Run
    ) {
        self.runtimePreferences = runtimePreferences.normalized
        self.sourceEnvironment = environment
        self.resolver = resolver
        self.run = run
    }

    public func check() async throws -> CodexCommandUpdateCheckResult {
        let executableURL = try resolver.resolve(
            configuredPath: runtimePreferences.codexExecutablePath,
            environment: sourceEnvironment
        )
        let codexHomeURL = runtimePreferences.codexHomePath.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? AppServerCodexHome.url(environment: sourceEnvironment)
        let environment = Self.sanitizedEnvironment(
            AppServerCodexHome.environment(
                sourceEnvironment,
                codexHomeURL: codexHomeURL
            )
        )
        let output = try await run(
            executableURL,
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
            executableURL: executableURL,
            environment: environment
        ))
    }

    private static let stablePathEntries = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    private static func sanitizedEnvironment(
        _ source: [String: String]
    ) -> [String: String] {
        var environment = source
        for key in source.keys where
            key.hasPrefix("CODEX_MANAGED_BY_") || key == "CODEX_MANAGED_PACKAGE_ROOT"
        {
            environment.removeValue(forKey: key)
        }

        environment["PATH"] = stablePathEntries.joined(separator: ":")
        return environment
    }

    private static func runDoctor(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }.value
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
