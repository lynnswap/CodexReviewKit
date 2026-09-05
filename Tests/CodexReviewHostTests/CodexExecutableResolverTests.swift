import Foundation
import Testing
import CodexReviewHost

actor CodexExecutableVersionProbeRecorder {
    private var paths: [String] = []

    func record(_ executableURL: URL) -> Result<String, CodexExecutableVersionProbe.Failure> {
        paths.append(executableURL.path)
        return .success("codex-cli 0.153.4")
    }

    func recordedPaths() -> [String] {
        paths
    }
}

@Suite("Codex executable version")
struct CodexExecutableVersionTests {
    @Test func followsSemanticVersionPrecedence() throws {
        let alpha2 = try #require(version("1.0.0-alpha.2"))
        let alpha10 = try #require(version("1.0.0-alpha.10"))
        let beta = try #require(version("1.0.0-beta"))
        let release = try #require(version("1.0.0"))
        let otherBuild = try #require(version("1.0.0+other.2"))

        #expect(alpha2 < alpha10)
        #expect(alpha10 < beta)
        #expect(beta < release)
        #expect(release == otherBuild)
    }

    @Test func rejectsNonCodexAndInvalidSemanticVersions() {
        for output in [
            "codex 1.0.0",
            "codex-cli 01.0.0",
            "codex-cli 1.0.0-01",
            "codex-cli 1.0.0-\u{0661}",
            "codex-cli 18446744073709551616.0.0",
            "codex-cli 1.0",
            "codex-cli 1.0.0 extra",
        ] {
            #expect(CodexExecutableVersion(codexVersionOutput: output) == nil)
        }
    }

    private func version(_ value: String) -> CodexExecutableVersion? {
        CodexExecutableVersion(codexVersionOutput: "codex-cli \(value)")
    }
}

@Suite("Codex executable resolver")
struct CodexExecutableResolverTests {
    @Test func explicitAndEnvironmentPrecedenceDoesNotProbeVersions() async throws {
        let resolver = makeResolver(executables: [
            "/explicit", "/commands/app", "/commands/review", "/commands/legacy",
        ], defaultVersionOutput: nil)
        let allEnvironment = [
            "CODEX_APP_SERVER_CODEX_EXECUTABLE": "app",
            "CODEX_REVIEW_CODEX_EXECUTABLE": "review",
            "CODEX_EXECUTABLE": "legacy",
            "PATH": "/commands",
        ]
        #expect(try await resolver.resolve(configuredPath: "/explicit", environment: allEnvironment).path == "/explicit")
        #expect(try await resolver.resolve(configuredPath: nil, environment: allEnvironment).path == "/commands/app")
        #expect(try await resolver.resolve(configuredPath: nil, environment: [
            "CODEX_REVIEW_CODEX_EXECUTABLE": "review", "CODEX_EXECUTABLE": "legacy", "PATH": "/commands",
        ]).path == "/commands/review")
        #expect(try await resolver.resolve(configuredPath: nil, environment: [
            "CODEX_EXECUTABLE": "legacy", "PATH": "/commands",
        ]).path == "/commands/legacy")
    }

    @Test func invalidExplicitSourcesDoNotFallback() async {
        let resolver = makeResolver(executables: ["/auto/codex", "/home/.local/bin/codex"])
        do {
            _ = try await resolver.resolve(configuredPath: "/missing", environment: ["PATH": "/auto"])
            Issue.record("Invalid configured path unexpectedly fell back.")
        } catch {
            #expect(error.kind == .invalidExplicit)
            #expect(error.trace.first?.source == .configuredPath)
        }
        do {
            _ = try await resolver.resolve(configuredPath: nil, environment: [
                "CODEX_APP_SERVER_CODEX_EXECUTABLE": "missing",
                "CODEX_REVIEW_CODEX_EXECUTABLE": "/auto/codex",
                "PATH": "/auto",
            ])
            Issue.record("Invalid environment command unexpectedly fell back.")
        } catch {
            #expect(error.kind == .invalidExplicit)
            #expect(error.trace.allSatisfy { $0.source == .environment("CODEX_APP_SERVER_CODEX_EXECUTABLE") })
        }
    }

    @Test func equalVersionsKeepPathOrderAndIgnoreEmptyComponents() async throws {
        let resolver = makeResolver(executables: ["/first/codex", "/second/codex"])
        let resolved = try await resolver.resolve(
            configuredPath: nil,
            environment: ["PATH": ":/first::/second:"]
        )
        #expect(resolved.path == "/first/codex")
    }

    @Test func equalVersionsKeepHomeBundleAndFallbackContractOrder() async throws {
        let homeFirst = makeResolver(
            executables: [
                "/home/.local/bin/codex",
                "/Applications/Codex.app/Contents/Resources/codex",
                "/brew/codex",
            ],
            directories: ["/Applications/Codex.app"],
            bundleIDs: ["/Applications/Codex.app": "com.openai.codex"]
        )
        #expect(try await homeFirst.resolve(configuredPath: nil, environment: ["HOME": "/other"]).path == "/home/.local/bin/codex")
        let systemAppFirst = makeResolver(
            executables: [
                "/Applications/Codex.app/Contents/Resources/codex",
                "/home/Applications/ChatGPT.app/Contents/Resources/codex",
            ],
            directories: ["/Applications/Codex.app", "/home/Applications/ChatGPT.app"],
            bundleIDs: [
                "/Applications/Codex.app": "com.openai.codex",
                "/home/Applications/ChatGPT.app": "com.openai.codex",
            ]
        )
        #expect(try await systemAppFirst.resolve(configuredPath: nil, environment: [:]).path == "/Applications/Codex.app/Contents/Resources/codex")
        let fallback = makeResolver(executables: ["/brew/codex", "/system/codex"])
        #expect(try await fallback.resolve(configuredPath: nil, environment: [:]).path == "/brew/codex")
    }

    @Test func bundleIdentityAndExactLayoutAreRequired() async throws {
        let resolver = makeResolver(
            executables: [
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                "/Applications/Codex.app/codex",
                "/system/codex",
            ],
            directories: ["/Applications/ChatGPT.app", "/Applications/Codex.app"],
            bundleIDs: [
                "/Applications/ChatGPT.app": "com.apple.Safari.WebApp",
                "/Applications/Codex.app": "com.openai.codex",
            ]
        )
        #expect(try await resolver.resolve(configuredPath: nil, environment: [:]).path == "/system/codex")
    }

    @Test func canonicalizesSymlinksAndDeduplicatesTrace() async throws {
        let recorder = CodexExecutableVersionProbeRecorder()
        let selected = makeResolver(
            executables: ["/real/codex"],
            canonical: ["/link/codex": "/real/codex"],
            versionProbe: .init { executableURL, _ in
                await recorder.record(executableURL)
            }
        )
        #expect(try await selected.resolve(configuredPath: nil, environment: ["PATH": "/link"]).path == "/real/codex")
        #expect(await recorder.recordedPaths() == ["/real/codex"])
        let failed = makeResolver(canonical: [
            "/link/codex": "/real/missing",
            "/home/.local/bin/codex": "/real/missing",
        ])
        do {
            _ = try await failed.resolve(configuredPath: nil, environment: ["PATH": "/link"])
            Issue.record("Missing candidates unexpectedly resolved.")
        } catch {
            #expect(error.kind == .notFound)
            #expect(error.trace.contains { $0.reason.contains("duplicate of /real/missing") })
            #expect(error.trace.contains { if case .applicationBundle = $0.source { true } else { false } })
            #expect(error.trace.contains { if case .fallbackBin = $0.source { true } else { false } })
            #expect(error.localizedDescription.contains("No usable Codex executable was found."))
        }
        do {
            _ = try await makeResolver().resolve(configuredPath: nil, environment: ["PATH": "::"])
            Issue.record("Empty PATH unexpectedly resolved.")
        } catch {
            let first = error.trace.first
            #expect(first?.source == .path("::"))
            #expect(first?.candidate == "codex")
            #expect(first?.reason == "PATH is missing or empty")
        }
    }

    @Test func newestAutomaticCandidateWinsAcrossInstallSources() async throws {
        let app = "/Applications/ChatGPT.app/Contents/Resources/codex"
        let appNewest = makeResolver(
            executables: ["/commands/codex", app, "/brew/codex"],
            directories: ["/Applications/ChatGPT.app"],
            bundleIDs: ["/Applications/ChatGPT.app": "com.openai.codex"],
            versionOutputs: [
                "/commands/codex": "codex-cli 0.152.0",
                app: "codex-cli 0.153.4",
                "/brew/codex": "codex-cli 0.151.0",
            ]
        )
        #expect(try await appNewest.resolve(
            configuredPath: nil,
            environment: ["PATH": "/commands"]
        ).path == app)

        let homeNewest = makeResolver(
            executables: ["/commands/codex", "/home/.local/bin/codex"],
            versionOutputs: [
                "/commands/codex": "codex-cli 0.152.0",
                "/home/.local/bin/codex": "codex-cli 0.153.4",
            ]
        )
        #expect(try await homeNewest.resolve(
            configuredPath: nil,
            environment: ["PATH": "/commands"]
        ).path == "/home/.local/bin/codex")

        let fallbackNewest = makeResolver(
            executables: ["/commands/codex", app, "/brew/codex"],
            directories: ["/Applications/ChatGPT.app"],
            bundleIDs: ["/Applications/ChatGPT.app": "com.openai.codex"],
            versionOutputs: [
                "/commands/codex": "codex-cli 0.152.0",
                app: "codex-cli 0.153.4",
                "/brew/codex": "codex-cli 0.154.0",
            ]
        )
        #expect(try await fallbackNewest.resolve(
            configuredPath: nil,
            environment: ["PATH": "/commands"]
        ).path == "/brew/codex")
    }

    @Test func semanticVersionsUseNumericAndPrereleasePrecedence() async throws {
        let numeric = makeResolver(
            executables: ["/old/codex", "/new/codex"],
            versionOutputs: [
                "/old/codex": "codex-cli 0.99.0",
                "/new/codex": "codex-cli 0.100.0",
            ]
        )
        #expect(try await numeric.resolve(
            configuredPath: nil,
            environment: ["PATH": "/old:/new"]
        ).path == "/new/codex")

        let prerelease = makeResolver(
            executables: ["/alpha/codex", "/beta/codex", "/stable/codex"],
            versionOutputs: [
                "/alpha/codex": "codex-cli 1.0.0-alpha.10+build.9",
                "/beta/codex": "codex-cli 1.0.0-beta.1",
                "/stable/codex": "codex-cli 1.0.0+build.1",
            ]
        )
        #expect(try await prerelease.resolve(
            configuredPath: nil,
            environment: ["PATH": "/alpha:/beta:/stable"]
        ).path == "/stable/codex")
    }

    @Test func failedAndInvalidVersionProbesAreRejected() async throws {
        let fallback = makeResolver(
            executables: ["/timeout/codex", "/invalid/codex", "/valid/codex"],
            versionOutputs: [
                "/invalid/codex": "codex 999",
                "/valid/codex": "codex-cli 0.153.4",
            ],
            probeFailures: ["/timeout/codex": .timedOut],
            defaultVersionOutput: nil
        )
        #expect(try await fallback.resolve(
            configuredPath: nil,
            environment: ["PATH": "/timeout:/invalid:/valid"]
        ).path == "/valid/codex")

        let allRejected = makeResolver(
            executables: ["/timeout/codex", "/invalid/codex"],
            versionOutputs: ["/invalid/codex": "codex 999"],
            probeFailures: ["/timeout/codex": .timedOut],
            defaultVersionOutput: nil
        )
        do {
            _ = try await allRejected.resolve(
                configuredPath: nil,
                environment: ["PATH": "/timeout:/invalid"]
            )
            Issue.record("Candidates with unusable versions unexpectedly resolved.")
        } catch {
            #expect(error.kind == .notFound)
            #expect(error.trace.contains {
                $0.candidate == "/timeout/codex" && $0.reason == "version probe timed out"
            })
            #expect(error.trace.contains {
                $0.candidate == "/invalid/codex"
                    && $0.reason == "version probe returned an invalid codex-cli semantic version"
            })
        }
    }

    @Test func liveVersionProbeSelectsNewestExecutableFixture() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-executable-version-\(UUID().uuidString)", isDirectory: true)
        let oldDirectory = root.appendingPathComponent("old", isDirectory: true)
        let newDirectory = root.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let oldExecutable = oldDirectory.appendingPathComponent("codex")
        let newExecutable = newDirectory.appendingPathComponent("codex")
        try writeVersionExecutable("0.152.0", to: oldExecutable)
        try writeVersionExecutable("0.153.4", to: newExecutable)
        let resolver = CodexExecutableResolver(configuration: .init(
            homeDirectory: root,
            applicationDirectories: [],
            fallbackBinDirectories: [],
            fileSystem: .live,
            versionProbe: .live
        ))

        let resolved = try await resolver.resolve(
            configuredPath: nil,
            environment: ["PATH": "\(oldDirectory.path):\(newDirectory.path)"]
        )

        #expect(resolved == newExecutable)
    }

    @Test func liveVersionProbeTimesOutWhenDescendantKeepsOutputOpen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-version-open-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex")
        try writeExecutable(
            "#!/bin/sh\n/bin/sleep 0.25 &\nprintf '%s\\n' 'codex-cli 0.153.4'\n",
            to: executable
        )

        let result = await CodexExecutableVersionProbe.live(timeout: .milliseconds(50))(
            executable,
            environment: ["PATH": "/usr/bin:/bin"]
        )

        #expect(result == .failure(.timedOut))
    }

    private func writeVersionExecutable(_ version: String, to url: URL) throws {
        try writeExecutable("#!/bin/sh\nprintf '%s\\n' 'codex-cli \(version)'\n", to: url)
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

func makeResolver(
    executables: Set<String> = [],
    directories: Set<String> = [],
    bundleIDs: [String: String] = [:],
    canonical: [String: String] = [:],
    versionOutputs: [String: String] = [:],
    probeFailures: [String: CodexExecutableVersionProbe.Failure] = [:],
    defaultVersionOutput: String? = "codex-cli 0.1.0",
    versionProbe: CodexExecutableVersionProbe? = nil
) -> CodexExecutableResolver {
    let fileSystem = CodexExecutableResolver.FileSystem(
        canonicalURL: { URL(fileURLWithPath: canonical[$0.standardizedFileURL.path] ?? $0.standardizedFileURL.path) },
        isExecutableRegularFile: { executables.contains($0.path) },
        isDirectory: { directories.contains($0.path) },
        bundleIdentifier: { bundleIDs[$0.path] }
    )
    let resolvedVersionProbe = versionProbe ?? .init { executableURL, _ in
        let path = executableURL.path
        if let failure = probeFailures[path] {
            return .failure(failure)
        }
        if let output = versionOutputs[path] ?? defaultVersionOutput {
            return .success(output)
        }
        return .failure(.launchFailed)
    }
    return .init(configuration: .init(
        homeDirectory: URL(fileURLWithPath: "/home", isDirectory: true),
        applicationDirectories: [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/home/Applications", isDirectory: true),
        ],
        fallbackBinDirectories: [
            URL(fileURLWithPath: "/brew", isDirectory: true),
            URL(fileURLWithPath: "/system", isDirectory: true),
        ],
        fileSystem: fileSystem,
        versionProbe: resolvedVersionProbe
    ))
}
