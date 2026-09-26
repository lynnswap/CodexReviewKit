import Foundation
import Testing
import CodexReviewHost

@Suite("Codex executable resolver")
struct CodexExecutableResolverTests {
    @Test func explicitAndEnvironmentPrecedence() throws {
        let resolver = makeResolver(executables: [
            "/explicit", "/commands/app", "/commands/review", "/commands/legacy",
        ])
        let allEnvironment = [
            "CODEX_APP_SERVER_CODEX_EXECUTABLE": "app",
            "CODEX_REVIEW_CODEX_EXECUTABLE": "review",
            "CODEX_EXECUTABLE": "legacy",
            "PATH": "/commands",
        ]
        #expect(try resolver.resolve(configuredPath: "/explicit", environment: allEnvironment).path == "/explicit")
        #expect(try resolver.resolve(configuredPath: nil, environment: allEnvironment).path == "/commands/app")
        #expect(try resolver.resolve(configuredPath: nil, environment: [
            "CODEX_REVIEW_CODEX_EXECUTABLE": "review", "CODEX_EXECUTABLE": "legacy", "PATH": "/commands",
        ]).path == "/commands/review")
        #expect(try resolver.resolve(configuredPath: nil, environment: [
            "CODEX_EXECUTABLE": "legacy", "PATH": "/commands",
        ]).path == "/commands/legacy")
    }

    @Test func invalidExplicitSourcesDoNotFallback() {
        let resolver = makeResolver(executables: ["/auto/codex", "/home/.local/bin/codex"])
        do {
            _ = try resolver.resolve(configuredPath: "/missing", environment: ["PATH": "/auto"])
            Issue.record("Invalid configured path unexpectedly fell back.")
        } catch {
            #expect(error.kind == .invalidExplicit)
            #expect(error.trace.first?.source == .configuredPath)
        }
        do {
            _ = try resolver.resolve(configuredPath: nil, environment: [
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

    @Test func pathOrderIgnoresEmptyComponents() throws {
        let resolver = makeResolver(executables: ["/first/codex", "/second/codex"])
        let resolved = try resolver.resolve(
            configuredPath: nil,
            environment: ["PATH": ":/first::/second:"]
        )
        #expect(resolved.path == "/first/codex")
    }

    @Test func installedCommandsIgnoreApplicationBundles() throws {
        let bundled = "/Applications/ChatGPT.app/Contents/Resources/codex"
        let homeFirst = makeResolver(executables: ["/home/.local/bin/codex", bundled, "/brew/codex"])
        #expect(try homeFirst.resolve(configuredPath: nil, environment: ["HOME": "/other"]).path == "/home/.local/bin/codex")
        let fallback = makeResolver(executables: [bundled, "/brew/codex", "/system/codex"])
        #expect(try fallback.resolve(configuredPath: nil, environment: ["PATH": "/usr/bin:/bin"]).path == "/brew/codex")
        #expect(throws: CodexExecutableResolutionError.self) {
            try makeResolver(executables: [bundled]).resolve(configuredPath: nil, environment: [:])
        }
    }

    @Test func canonicalizesSymlinksAndDeduplicatesTrace() throws {
        let selected = makeResolver(
            executables: ["/real/codex"],
            canonical: ["/link/codex": "/real/codex"]
        )
        #expect(try selected.resolve(configuredPath: nil, environment: ["PATH": "/link"]).path == "/real/codex")
        let failed = makeResolver(canonical: [
            "/link/codex": "/real/missing",
            "/home/.local/bin/codex": "/real/missing",
        ])
        do {
            _ = try failed.resolve(configuredPath: nil, environment: ["PATH": "/link"])
            Issue.record("Missing candidates unexpectedly resolved.")
        } catch {
            #expect(error.kind == .notFound)
            #expect(error.trace.contains { $0.reason.contains("duplicate of /real/missing") })
            #expect(error.trace.contains { if case .fallbackBin = $0.source { true } else { false } })
            #expect(error.localizedDescription.contains("No usable Codex executable was found."))
        }
        do {
            _ = try makeResolver().resolve(configuredPath: nil, environment: ["PATH": "::"])
            Issue.record("Empty PATH unexpectedly resolved.")
        } catch {
            let first = error.trace.first
            #expect(first?.source == .path("::"))
            #expect(first?.candidate == "codex")
            #expect(first?.reason == "PATH is missing or empty")
        }
    }
}

func makeResolver(
    executables: Set<String> = [],
    canonical: [String: String] = [:]
) -> CodexExecutableResolver {
    let fileSystem = CodexExecutableResolver.FileSystem(
        canonicalURL: { URL(fileURLWithPath: canonical[$0.standardizedFileURL.path] ?? $0.standardizedFileURL.path) },
        isExecutableRegularFile: { executables.contains($0.path) }
    )
    return .init(configuration: .init(
        homeDirectory: URL(fileURLWithPath: "/home", isDirectory: true),
        fallbackBinDirectories: [
            URL(fileURLWithPath: "/brew", isDirectory: true),
            URL(fileURLWithPath: "/system", isDirectory: true),
        ],
        fileSystem: fileSystem
    ))
}
