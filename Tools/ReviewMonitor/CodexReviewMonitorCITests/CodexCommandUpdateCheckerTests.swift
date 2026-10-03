import Darwin
import Foundation
import Testing
@_spi(ApplicationHostSupport) import CodexReviewHost
@testable import CodexReviewMonitor

@Suite("Codex command update checker", .serialized)
struct CodexCommandUpdateCheckerTests {
    private let launcherURL = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
    private let executableURL = URL(
        fileURLWithPath: "/opt/homebrew/Caskroom/codex/1.2.3/bin/codex"
    )

    @Test @MainActor func updateCheckKeepsFileResolutionAndDoctorWorkOffTheMainThread() async throws {
        let executableURL = executableURL
        let expectBackgroundWork: @Sendable () -> Void = { #expect(Thread.isMainThread == false) }
        let output = report(
            enabled: "true", latestStatus: "newer version is available",
            action: "brew upgrade --cask codex"
        )
        let checker = CodexCommandUpdateChecker(
            environment: ["PATH": "/opt/homebrew/bin"],
            resolve: { _, _ in
                expectBackgroundWork()
                return (URL(fileURLWithPath: "/opt/homebrew/bin/codex"), executableURL)
            },
            run: { _, _, _ in
                expectBackgroundWork()
                return Data(output.utf8)
            }
        )
        let check: ReviewMonitorCodexUpdater.Check = checker.check
        guard case .available = try await check() else {
            Issue.record("Expected an available update from the MainActor check callback.")
            return
        }
    }

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
                #expect(environment["CODEX_HOME"] == "/users/reviewer/.codex")
                #expect(environment["CODEX_SQLITE_HOME"] == "/users/reviewer/.codex/sqlite")
                #expect(environment["CODEX_MANAGED_BY_NPM"] == nil)
                #expect(environment["CODEX_MANAGED_BY_FUTURE"] == nil)
                #expect(environment["CODEX_MANAGED_PACKAGE_ROOT"] == nil)
                #expect(environment["PATH"] == "relative:/custom/bin:/usr/bin:/custom/bin")
            }
        )

        guard case .available(let plan) = try await checker.check() else {
            Issue.record("Expected an available Homebrew update.")
            return
        }
        #expect(plan.executableURL == launcherURL)
        #expect(plan.environment["CODEX_HOME"] == "/users/reviewer/.codex")
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
            resolve: { _, _ in (launcherURL, executableURL) },
            run: { _, _, environment in
                #expect(environment["PATH"] == "/opt/homebrew/bin:/usr/local/bin")
                return output
            }
        )

        guard case .available(let plan) = try await checker.check() else {
            Issue.record("Expected an available Intel Homebrew update.")
            return
        }
        #expect(plan.executableURL == launcherURL)
        #expect(plan.environment["PATH"]?.contains("/opt/homebrew/bin") == false)
    }

    @Test func versionPinnedHomebrewExecutableIsNotOfferedAnAutomaticUpdate() async throws {
        let pinnedExecutableURL = URL(
            fileURLWithPath: "/opt/homebrew/Caskroom/codex/1.2.3/bin/codex"
        )
        let checker = CodexCommandUpdateChecker(
            runtimePreferences: .init(codexExecutablePath: pinnedExecutableURL.path),
            environment: ["HOME": "/users/reviewer", "PATH": "/opt/homebrew/bin"],
            resolve: { _, _ in (pinnedExecutableURL, pinnedExecutableURL) },
            run: { _, _, _ in
                Data(report(enabled: "true", latestStatus: "newer version is available",
                            action: "brew upgrade --cask codex").utf8)
            }
        )

        if case .manualUpdate = try await checker.check() {} else { Issue.record("Expected a newer version requiring manual installation") }
    }

    @Test func reviewRuntimeHomeDoesNotOverrideInstallationEnvironment() async throws {
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
        #expect(plan.environment["CODEX_HOME"] == "/ignored")
        #expect(plan.environment["CODEX_SQLITE_HOME"] == "/ignored/sqlite")
        #expect(plan.environment["PATH"] == [
            "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":"))
    }

    @Test func startupPreferenceDoesNotDisableMonitorChecks() async throws {
        let result = try await makeChecker(
            output: report(enabled: "false", latestStatus: "newer version is available", action: "brew upgrade --cask codex")
        ).check()
        if case .available = result {} else { Issue.record("Expected a Monitor update despite the CLI startup preference") }
    }

    @Test func currentAndUnsupportedActionsHaveDifferentResults() async throws {
        let current = try await makeChecker(output: report(
            enabled: "true",
            latestStatus: "current version is not older"
        )).check()
        #expect(current == .upToDate)

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
            if case .manualUpdate = unsupported {} else { Issue.record("Expected a newer version requiring manual installation") }
        }
    }

    @Test func scriptBasedCheckRetainsInterpreterLookupFromTheSourcePath() async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("codex-node-\(UUID())")
        defer { try? manager.removeItem(at: directory) }
        let launcher = directory.appendingPathComponent("commands/codex")
        let interpreter = directory.appendingPathComponent("node/bin/node")
        let json = report(
            enabled: "true", latestStatus: "newer version is available",
            action: "npm install -g @openai/codex"
        )
        for (executable, script) in [
            (launcher, "#!/usr/bin/env node\n"),
            (interpreter, "#!/bin/sh\nprintf '%s' '\(json)'\n"),
        ] {
            try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(script.utf8).write(to: executable)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let result = try await CodexCommandUpdateChecker(
            runtimePreferences: .init(codexExecutablePath: launcher.path),
            environment: ["HOME": directory.path, "PATH": interpreter.deletingLastPathComponent().path]
        ).check()
        if case .manualUpdate = result {} else {
            Issue.record("Expected a successfully probed version with manual npm installation.")
        }
    }

    @Test func missingOrUnknownUpdateStatusThrows() async {
        let reports = [
            report(enabled: "true", latestStatus: "unknown"),
            #"{"checks":{}}"#,
            #"{"checks":{"updates.status":{"details":{"latest version status":["current version is not older","newer version is available"]}}}}"#,
        ]
        for output in reports {
            await #expect(throws: (any Error).self) {
                try await makeChecker(output: output).check()
            }
        }
    }

    @Test func failedVersionProbePreservesItsReason() async {
        let report = #"{"checks":{"updates.status":{"details":{"latest version probe":"network offline"}}}}"#
        do {
            _ = try await makeChecker(output: report).check()
            Issue.record("Expected a failed check")
        } catch {
            #expect(error.localizedDescription.contains("network offline"))
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
        let readyURL = directory.appendingPathComponent("ready")
        let script = """
        trap 'exit 0' TERM
        printf %s $$ > "$1"
        : > "$2"
        exec /bin/sleep 60
        """
        let task = Task {
            try await CodexCommandUpdateChecker.runDoctor(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script, "codex-doctor", processIdentifierURL.path, readyURL.path],
                environment: ["PATH": "/usr/bin:/bin"]
            )
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(2)
        while FileManager.default.fileExists(atPath: readyURL.path) == false {
            try #require(
                ContinuousClock.now < deadline,
                "Doctor process did not report readiness before the deadline."
            )
            try await Task.sleep(for: .milliseconds(10))
        }
        let processIdentifier = try #require(pid_t(
            String(contentsOf: processIdentifierURL, encoding: .utf8)
        ))
        let watchdog = Task.detached {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return false
            }
            _ = Darwin.kill(processIdentifier, SIGKILL)
            return true
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
        #expect(await watchdog.value == false, "Doctor required SIGKILL after cancellation.")
        let processStatus = Darwin.kill(processIdentifier, 0)
        let processError = errno
        #expect(processStatus == -1)
        #expect(processError == ESRCH)
    }

    @Test(arguments: [false, true])
    func standaloneChecksAndUpdatesUseInstallationHome(customHome: Bool) async throws {
        let fixture = try StandaloneUpdateFixture(customHome: customHome)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let preferences = CodexReviewRuntime.Preferences(
            codexHomePath: fixture.directory.appendingPathComponent("review-home").path,
            codexExecutablePath: fixture.launcher.path
        )
        let installationHome = fixture.installationHome
        let checker = CodexCommandUpdateChecker(
            runtimePreferences: preferences,
            environment: [
                "HOME": fixture.directory.path,
                "CODEX_HOME": preferences.codexHomePath!,
                "CODEX_SQLITE_HOME": "/review/sqlite",
                "CODEX_INSTALL_DIR": "/wrong/bin",
                "UPDATE_LOG": fixture.directory.appendingPathComponent("update-environment").path,
            ],
            run: { executable, arguments, environment in
                #expect(executable.path.hasPrefix(installationHome.path + "/packages/standalone/releases/"))
                #expect(arguments == ["doctor", "--json"])
                #expect(environment["CODEX_HOME"] == installationHome.path)
                #expect(environment["CODEX_SQLITE_HOME"] == installationHome.appendingPathComponent("sqlite").path)
                return Data(report(enabled: "true", latestStatus: "newer version is available",
                                   action: "standalone installer").utf8)
            }
        )
        guard case .available(let plan) = try await checker.check() else {
            Issue.record("Expected a standalone update.")
            return
        }
        #expect(plan.executableURL == fixture.launcher)
        #expect(plan.environment["CODEX_INSTALL_DIR"] == fixture.launcher.deletingLastPathComponent().path)
        try await ReviewMonitorCodexUpdateProcess.run(plan)
        let environment = try String(
            contentsOf: fixture.directory.appendingPathComponent("update-environment"), encoding: .utf8
        )
        #expect(environment == installationHome.path + "\n" + fixture.launcher.deletingLastPathComponent().path + "\n")
        let restarted = try CodexReviewRuntime.resolveExecutable(
            configuredPath: preferences.codexExecutablePath, environment: plan.environment
        )
        #expect(restarted.launcherURL == fixture.launcher)
        #expect(restarted.executableURL.path.contains("/releases/2.0.0/bin/codex"))
        #expect(FileManager.default.fileExists(atPath: preferences.codexHomePath!) == false)
    }

    @Test(arguments: [false, true])
    func standalonePinnedAliasAndPackageLauncherRequireManualInstallation(packageLauncher: Bool) async throws {
        let fixture = try StandaloneUpdateFixture(customHome: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.removeItem(at: fixture.launcher)
        try FileManager.default.createSymbolicLink(
            at: fixture.launcher, withDestinationURL: fixture.firstExecutable
        )
        let result = try await CodexCommandUpdateChecker(
            runtimePreferences: .init(codexExecutablePath: packageLauncher
                ? fixture.installationHome.appendingPathComponent("packages/standalone/current/bin/codex").path
                : fixture.launcher.path),
            environment: [:],
            run: { _, _, _ in Data(report(enabled: "true", latestStatus: "newer version is available",
                                          action: "standalone installer").utf8) }
        ).check()
        if case .manualUpdate = result {} else { Issue.record("Expected a newer version requiring a stable launcher.") }
    }

    @Test func standaloneFailedProbePreservesFailure() async throws {
        let fixture = try StandaloneUpdateFixture(customHome: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let checker = CodexCommandUpdateChecker(
            runtimePreferences: .init(codexExecutablePath: fixture.launcher.path),
            environment: ["CODEX_HOME": "/review/home"],
            run: { _, _, _ in
                Data(#"{"checks":{"updates.status":{"details":{"latest version probe":"network offline"}}}}"#.utf8)
            }
        )
        do {
            _ = try await checker.check()
            Issue.record("Expected a failed standalone probe.")
        } catch {
            #expect(error.localizedDescription.contains("network offline"))
        }
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
            resolve: { _, _ in (launcherURL, executableURL) },
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

private struct StandaloneUpdateFixture {
    let directory: URL
    let installationHome: URL
    let launcher: URL
    let firstExecutable: URL

    init(customHome: Bool) throws {
        let manager = FileManager.default
        directory = manager.temporaryDirectory.appendingPathComponent("codex-standalone-\(UUID())")
        installationHome = directory.appendingPathComponent(customHome ? "custom installation/home" : ".codex")
        launcher = directory.appendingPathComponent("commands/codex")
        let root = installationHome.appendingPathComponent("packages/standalone")
        firstExecutable = root.appendingPathComponent("releases/1.0.0/bin/codex")
        let nextExecutable = root.appendingPathComponent("releases/2.0.0/bin/codex")
        do {
            for executable in [firstExecutable, nextExecutable] {
                try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
                let script = """
                #!/bin/sh
                if [ "$1" = update ]; then
                    printf '%s\\n%s\\n' "$CODEX_HOME" "$CODEX_INSTALL_DIR" > "$UPDATE_LOG"
                    /bin/ln -sfn "$CODEX_HOME/packages/standalone/releases/2.0.0" "$CODEX_HOME/packages/standalone/current"
                fi
                """
                try Data(script.utf8).write(to: executable)
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            }
            try manager.createSymbolicLink(
                at: root.appendingPathComponent("current"),
                withDestinationURL: root.appendingPathComponent("releases/1.0.0")
            )
            try manager.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
            let visibleHome: URL
            if customHome {
                visibleHome = directory.appendingPathComponent("home-alias")
                try manager.createSymbolicLink(at: visibleHome, withDestinationURL: installationHome)
            } else {
                visibleHome = installationHome
            }
            try manager.createSymbolicLink(
                at: launcher,
                withDestinationURL: visibleHome.appendingPathComponent("packages/standalone/current/bin/codex")
            )
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }
}
