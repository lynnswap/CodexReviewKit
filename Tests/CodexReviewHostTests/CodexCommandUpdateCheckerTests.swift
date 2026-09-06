import Foundation
import Testing
@_spi(ApplicationHostSupport) @testable import CodexReviewHost

@Suite("Codex command update checker")
struct CodexCommandUpdateCheckerTests {
    private let executableURL = URL(fileURLWithPath: "/tools/codex")

    @Test func supportedActionsReturnOneReusablePlan() async throws {
        let actions = [
            "npm install -g @openai/codex",
            "bun install -g @openai/codex",
            "vp install -g @openai/codex",
            "pnpm add -g @openai/codex",
            "brew upgrade --cask codex",
            "standalone installer",
        ]
        for action in actions {
            let checker = makeChecker(
                environment: [
                    "HOME": "/users/reviewer",
                    "PATH": "relative:/custom/bin:/usr/bin:/custom/bin",
                    "CODEX_MANAGED_BY_NPM": "1",
                    "CODEX_MANAGED_BY_FUTURE": "1",
                    "CODEX_MANAGED_PACKAGE_ROOT": "/spoofed",
                ],
                output: report(
                    enabled: "true",
                    latestStatus: "newer version is available",
                    action: action
                ),
                inspect: { executableURL, arguments, environment in
                    #expect(executableURL.path == "/tools/codex")
                    #expect(arguments == ["doctor", "--json"])
                    #expect(environment["CODEX_HOME"] == "/users/reviewer/.codex_review")
                    #expect(environment["CODEX_SQLITE_HOME"] == "/users/reviewer/.codex_review/sqlite")
                    #expect(environment["CODEX_MANAGED_BY_NPM"] == nil)
                    #expect(environment["CODEX_MANAGED_BY_FUTURE"] == nil)
                    #expect(environment["CODEX_MANAGED_PACKAGE_ROOT"] == nil)
                    #expect(environment["PATH"] == [
                        "/custom/bin", "/usr/bin", "/opt/homebrew/bin",
                        "/usr/local/bin", "/bin", "/usr/sbin", "/sbin",
                    ].joined(separator: ":"))
                }
            )

            guard case .available(let plan) = try await checker.check() else {
                Issue.record("Expected an available update for \(action).")
                continue
            }
            #expect(plan.executableURL == executableURL)
            #expect(plan.environment["CODEX_HOME"] == "/users/reviewer/.codex_review")
            #expect(plan.environment["CODEX_MANAGED_BY_NPM"] == nil)
        }
    }

    @Test func explicitRuntimeHomeOwnsDoctorAndPlanEnvironment() async throws {
        let checker = makeChecker(
            preferences: .init(
                codexHomePath: "/runtime/codex",
                codexExecutablePath: "/tools/codex"
            ),
            environment: ["CODEX_HOME": "/ignored", "PATH": ""],
            output: report(
                enabled: "true",
                latestStatus: "newer version is available",
                action: "standalone installer"
            )
        )
        guard case .available(let plan) = try await checker.check() else {
            Issue.record("Expected an available update.")
            return
        }
        #expect(plan.environment["CODEX_HOME"] == "/runtime/codex")
        #expect(plan.environment["CODEX_SQLITE_HOME"] == "/runtime/codex/sqlite")
        #expect(plan.environment["PATH"] == [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":"))
    }

    @Test func disabledSettingWinsWithoutUpdateProbeDetails() async throws {
        let result = try await makeChecker(
            output: report(enabled: "false")
        ).check()
        #expect(result == .disabled)
    }

    @Test func currentAndUnsupportedActionsAreUnavailable() async throws {
        let current = try await makeChecker(output: report(
            enabled: "true",
            latestStatus: "current version is not older"
        )).check()
        #expect(current == .unavailable)

        for action in ["manual or unknown", "future updater"] {
            let unsupported = try await makeChecker(output: report(
                enabled: "true",
                latestStatus: "newer version is available",
                action: action
            )).check()
            #expect(unsupported == .unavailable)
        }
    }

    @Test func malformedContractValuesThrow() async {
        let reports = [
            report(enabled: "TRUE"),
            report(enabled: "true", latestStatus: "unknown"),
            #"{"schemaVersion":2,"checks":{}}"#,
            #"{"schemaVersion":1,"checks":{}}"#,
            #"{"schemaVersion":1,"checks":{"updates.status":{"details":{"check for update on startup":["true","false"]}}}}"#,
        ]
        for output in reports {
            await #expect(throws: (any Error).self) {
                try await makeChecker(output: output).check()
            }
        }
    }

    @Test func liveRunnerAcceptsValidJSONFromNonzeroDoctorExit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codex-update-checker-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        let json = report(enabled: "false")
        try Data("#!/bin/sh\nprintf '%s' '\(json)'\nexit 7\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )

        let result = try await CodexCommandUpdateChecker(
            runtimePreferences: .init(codexExecutablePath: executable.path),
            environment: ["HOME": directory.path, "PATH": "/usr/bin:/bin"]
        ).check()
        #expect(result == .disabled)
    }

    private func makeChecker(
        preferences: CodexReviewRuntime.Preferences = .init(
            codexExecutablePath: "/tools/codex"
        ),
        environment: [String: String] = ["HOME": "/users/reviewer", "PATH": "/tools"],
        output: String,
        inspect: @escaping @Sendable (URL, [String], [String: String]) -> Void = { _, _, _ in }
    ) -> CodexCommandUpdateChecker {
        CodexCommandUpdateChecker(
            runtimePreferences: preferences,
            environment: environment,
            resolver: makeResolver(executables: [executableURL.path]),
            run: { executableURL, arguments, environment in
                inspect(executableURL, arguments, environment)
                return Data(output.utf8)
            }
        )
    }

    private func report(
        enabled: String,
        latestStatus: String? = nil,
        action: String? = nil
    ) -> String {
        var details = ["\"check for update on startup\":\"\(enabled)\""]
        if let latestStatus {
            details.append("\"latest version status\":\"\(latestStatus)\"")
        }
        if let action {
            details.append("\"update action\":\"\(action)\"")
        }
        return "{\"schemaVersion\":1,\"checks\":{\"updates.status\":{\"details\":{\(details.joined(separator: ","))}}}}"
    }
}
