import Foundation
import Darwin
import Testing
@_spi(ApplicationHostSupport) @testable import CodexReviewHost

@Suite("Codex command update checker")
struct CodexCommandUpdateCheckerTests {
    private let launcherURL = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
    private let executableURL = URL(
        fileURLWithPath: "/opt/homebrew/Caskroom/codex/1.2.3/bin/codex"
    )

    @Test func homebrewUpdateReturnsOneReusablePlanWithAStableEnvironment() async throws {
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
                action: "brew upgrade --cask codex"
            ),
            inspect: { executableURL, arguments, environment in
                #expect(executableURL.path == "/opt/homebrew/Caskroom/codex/1.2.3/bin/codex")
                #expect(arguments == ["doctor", "--json"])
                #expect(environment["CODEX_HOME"] == "/users/reviewer/.codex_review")
                #expect(environment["CODEX_SQLITE_HOME"] == "/users/reviewer/.codex_review/sqlite")
                #expect(environment["CODEX_MANAGED_BY_NPM"] == nil)
                #expect(environment["CODEX_MANAGED_BY_FUTURE"] == nil)
                #expect(environment["CODEX_MANAGED_PACKAGE_ROOT"] == nil)
                #expect(environment["PATH"] == [
                    "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                ].joined(separator: ":"))
            }
        )

        guard case .available(let plan) = try await checker.check() else {
            Issue.record("Expected an available Homebrew update.")
            return
        }
        #expect(plan.executableURL == executableURL)
        #expect(plan.environment["CODEX_HOME"] == "/users/reviewer/.codex_review")
        #expect(plan.environment["CODEX_MANAGED_BY_NPM"] == nil)
    }

    @Test func updatePathMatchesTheSelectedStableHomebrewLauncher() async throws {
        let launcherURL = URL(fileURLWithPath: "/usr/local/bin/codex")
        let executableURL = URL(
            fileURLWithPath: "/usr/local/Caskroom/codex/1.2.3/bin/codex"
        )
        let output = Data(report(
            enabled: "true",
            latestStatus: "newer version is available",
            action: "brew upgrade --cask codex"
        ).utf8)
        let checker = CodexCommandUpdateChecker(
            runtimePreferences: .init(codexExecutablePath: launcherURL.path),
            environment: [
                "HOME": "/users/reviewer",
                "PATH": "/opt/homebrew/bin:/usr/local/bin",
            ],
            resolver: makeResolver(
                executables: [executableURL.path],
                canonical: [launcherURL.path: executableURL.path]
            ),
            run: { _, _, environment in
                #expect(environment["PATH"] == [
                    "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                ].joined(separator: ":"))
                return output
            }
        )

        guard case .available(let plan) = try await checker.check() else {
            Issue.record("Expected an available Intel Homebrew update.")
            return
        }
        #expect(plan.executableURL == executableURL)
        #expect(plan.environment["PATH"]?.contains("/opt/homebrew/bin") == false)
    }

    @Test func versionPinnedHomebrewExecutableIsNotOfferedAnAutomaticUpdate() async throws {
        let pinnedExecutableURL = URL(
            fileURLWithPath: "/opt/homebrew/Caskroom/codex/1.2.3/bin/codex"
        )
        let checker = CodexCommandUpdateChecker(
            runtimePreferences: .init(codexExecutablePath: pinnedExecutableURL.path),
            environment: ["HOME": "/users/reviewer", "PATH": "/opt/homebrew/bin"],
            resolver: makeResolver(executables: [pinnedExecutableURL.path]),
            run: { _, _, _ in
                Issue.record("A pinned executable must not run the automatic update check.")
                return Data()
            }
        )

        #expect(try await checker.check() == .unavailable)
    }

    @Test func explicitRuntimeHomeOwnsDoctorAndPlanEnvironment() async throws {
        let checker = makeChecker(
            preferences: .init(
                codexHomePath: "/runtime/codex",
                codexExecutablePath: "/opt/homebrew/bin/codex"
            ),
            environment: ["CODEX_HOME": "/ignored", "PATH": ""],
            output: report(
                enabled: "true",
                latestStatus: "newer version is available",
                action: "brew upgrade --cask codex"
            )
        )
        guard case .available(let plan) = try await checker.check() else {
            Issue.record("Expected an available update.")
            return
        }
        #expect(plan.environment["CODEX_HOME"] == "/runtime/codex")
        #expect(plan.environment["CODEX_SQLITE_HOME"] == "/runtime/codex/sqlite")
        #expect(plan.environment["PATH"] == [
            "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
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

        for action in [
            "manual or unknown",
            "npm install -g @openai/codex",
            "standalone installer",
            "future updater",
        ] {
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

        let output = try await CodexCommandUpdateChecker.runDoctor(
            executableURL: executable,
            arguments: ["doctor", "--json"],
            environment: ["HOME": directory.path, "PATH": "/usr/bin:/bin"]
        )
        #expect(String(data: output, encoding: .utf8) == json)
    }

    @Test func cancellingLiveRunnerTerminatesTheDoctorProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codex-update-checker-cancellation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let processIdentifierURL = directory.appendingPathComponent("pid")
        let script = "printf %s $$ > \"$1\"; trap 'exit 0' TERM; while :; do :; done"
        let task = Task {
            try await CodexCommandUpdateChecker.runDoctor(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script, "codex-doctor", processIdentifierURL.path],
                environment: ["PATH": "/usr/bin:/bin"]
            )
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(2)
        while FileManager.default.fileExists(atPath: processIdentifierURL.path) == false,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let processIdentifier = try #require(pid_t(
            String(contentsOf: processIdentifierURL, encoding: .utf8)
        ))
        let watchdog = Task.detached {
            try? await Task.sleep(for: .seconds(2))
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
        defer { watchdog.cancel() }

        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected doctor cancellation.")
        } catch {
            #expect(error is CancellationError)
        }
        watchdog.cancel()
        #expect(Darwin.kill(processIdentifier, 0) == -1)
        #expect(errno == ESRCH)
    }

    private func makeChecker(
        preferences: CodexReviewRuntime.Preferences = .init(
            codexExecutablePath: "/opt/homebrew/bin/codex"
        ),
        environment: [String: String] = [
            "HOME": "/users/reviewer",
            "PATH": "/opt/homebrew/bin",
        ],
        output: String,
        inspect: @escaping @Sendable (URL, [String], [String: String]) -> Void = { _, _, _ in }
    ) -> CodexCommandUpdateChecker {
        CodexCommandUpdateChecker(
            runtimePreferences: preferences,
            environment: environment,
            resolver: makeResolver(
                executables: [executableURL.path],
                canonical: [launcherURL.path: executableURL.path]
            ),
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
