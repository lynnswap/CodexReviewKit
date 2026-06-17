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

    @Test func codexReviewTargetDoesNotOwnReviewMonitorRenderingArtifacts() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let codexReviewSources = repo.appending(path: "Sources/CodexReview")
        let files = try FileManager.default
            .subpathsOfDirectory(atPath: codexReviewSources.path)
            .filter { $0.hasSuffix(".swift") }

        var violations: [String] = []
        for file in files {
            let url = codexReviewSources.appending(path: file)
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("ReviewMonitor") {
                violations.append(file)
            }
        }

        #expect(violations.isEmpty, Comment(rawValue: violations.joined(separator: "\n")))
    }

    @Test func reviewUIDoesNotMutateStoreOwnedJobStateDirectly() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let checkedRoots = [
            repo.appending(path: "Sources/ReviewUI"),
            repo.appending(path: "Tests/ReviewUITests"),
        ]
        let forbiddenAssignments = try [
            NSRegularExpression(pattern: #"\.core(?:\.[A-Za-z_][A-Za-z0-9_]*)+\s*=(?!=)"#),
            NSRegularExpression(pattern: #"\.targetSummary\s*=(?!=)"#),
            NSRegularExpression(pattern: #"\.cancellationRequested\s*=(?!=)"#),
        ]

        var violations: [String] = []
        for root in checkedRoots {
            let files = try FileManager.default
                .subpathsOfDirectory(atPath: root.path)
                .filter { $0.hasSuffix(".swift") }
            for file in files {
                let url = root.appending(path: file)
                let text = try String(contentsOf: url, encoding: .utf8)
                for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let lineText = String(line)
                    guard forbiddenAssignments.contains(where: {
                        let range = NSRange(lineText.startIndex..<lineText.endIndex, in: lineText)
                        return $0.firstMatch(in: lineText, range: range) != nil
                    }) else {
                        continue
                    }
                    let relativePath = url.path.replacingOccurrences(of: repo.path + "/", with: "")
                    violations.append("\(relativePath):\(offset + 1): \(lineText.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        #expect(violations.isEmpty, Comment(rawValue: violations.joined(separator: "\n")))
    }
}
