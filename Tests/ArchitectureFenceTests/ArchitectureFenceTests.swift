import Foundation
import Testing

@Suite("architecture fence")
struct ArchitectureFenceTests {
    @Test func finalTargetsDoNotImportForbiddenImplementationTargets() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = repo.appending(path: "Sources")
        let forbiddenModules: Set<String> = [
            "ReviewApplication",
            "ReviewDomain",
            "ReviewPorts",
            "ReviewServiceRuntime",
            "ReviewNativeAuthAdapter",
            "ReviewHTTPServerAdapter",
            "ReviewStdioAdapter",
            "ReviewTestSupport",
            "ReviewServiceRuntimeTestSupport",
            "ReviewAppServerAdapter",
        ]

        let files = try FileManager.default
            .subpathsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }

        var violations: [String] = []
        for file in files {
            let url = sources.appending(path: file)
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") || trimmed.hasPrefix("package import ") else {
                    continue
                }
                let module = trimmed.split(separator: " ").last.map(String.init)
                if let module, forbiddenModules.contains(module) {
                    violations.append("\(file): \(trimmed)")
                }
            }
        }

        #expect(violations.isEmpty, Comment(rawValue: violations.joined(separator: "\n")))
    }
}
