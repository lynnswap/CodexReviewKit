import Foundation
import Testing

@Suite("architecture fence")
struct ArchitectureFenceTests {
    @Test func finalTargetsDoNotImportForbiddenImplementationTargets() throws {
        let violations = try Self.importViolations(in: [
            .init(
                root: "Sources",
                forbiddenImports: [
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
            ),
        ])

        Self.expectNoViolations(violations)
    }

    @Test func codexReviewTargetDoesNotOwnReviewMonitorRenderingArtifacts() throws {
        let repo = Self.repositoryRoot
        let codexReviewSources = repo.appending(path: "Sources/CodexReview")

        var violations: [String] = []
        for file in try Self.swiftSourceFiles(in: codexReviewSources) {
            let url = codexReviewSources.appending(path: file)
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("ReviewMonitor") {
                violations.append(file)
            }
        }

        Self.expectNoViolations(violations)
    }

    @Test func reviewUIDoesNotMutateStoreOwnedJobStateDirectly() throws {
        let repo = Self.repositoryRoot
        let checkedRoots = [
            repo.appending(path: "Sources/ReviewUI"),
            repo.appending(path: "Tests/ReviewUITests"),
        ]
        let forbiddenAssignments = try [
            NSRegularExpression(pattern: #"\.core(?:\.[A-Za-z_][A-Za-z0-9_]*)*\s*=(?!=)"#),
            NSRegularExpression(pattern: #"\.targetSummary\s*=(?!=)"#),
            NSRegularExpression(pattern: #"\.cancellationRequested\s*=(?!=)"#),
            NSRegularExpression(pattern: #"\.sortOrder\s*=(?!=)"#),
        ]

        var violations: [String] = []
        for root in checkedRoots {
            for file in try Self.swiftSourceFiles(in: root) {
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

        Self.expectNoViolations(violations)
    }

    @Test func observationTimelineTargetsKeepOneWayDependencies() throws {
        let violations = try Self.importViolations(in: [
            .init(
                root: "Sources/CodexReviewAppServerWire",
                forbiddenImports: [
                    "CodexReview",
                    "CodexReviewApplication",
                    "CodexReviewAppServer",
                    "CodexReviewMCPAdapter",
                    "CodexReviewMCPServer",
                    "ReviewMonitorRendering",
                    "ReviewUI",
                ]
            ),
            .init(
                root: "Sources/CodexReviewDomain",
                forbiddenImports: [
                    "CodexReview",
                    "CodexReviewApplication",
                    "CodexReviewAppServer",
                    "CodexReviewAppServerWire",
                    "CodexReviewMCPAdapter",
                    "CodexReviewMCPServer",
                    "ReviewMonitorRendering",
                    "ReviewUI",
                ]
            ),
            .init(
                root: "Sources/ReviewUI",
                forbiddenImports: [
                    "CodexReviewAppServer",
                    "CodexReviewAppServerWire",
                    "CodexReviewMCPAdapter",
                    "CodexReviewMCPServer",
                ]
            ),
            .init(
                root: "Sources/ReviewMonitorRendering",
                forbiddenImports: [
                    "CodexReview",
                    "CodexReviewApplication",
                    "CodexReviewAppServer",
                    "CodexReviewAppServerWire",
                    "CodexReviewMCPAdapter",
                    "CodexReviewMCPServer",
                    "ReviewUI",
                ]
            ),
            .init(
                root: "Sources/CodexReviewMCPAdapter",
                forbiddenImports: [
                    "CodexReviewAppServer",
                    "CodexReviewAppServerWire",
                    "CodexReviewMCPServer",
                    "ReviewMonitorRendering",
                    "ReviewUI",
                ]
            ),
            .init(
                root: "Sources/CodexReviewApplication",
                forbiddenImports: [
                    "CodexReview",
                    "CodexReviewAppServer",
                    "CodexReviewAppServerWire",
                    "CodexReviewMCPAdapter",
                    "CodexReviewMCPServer",
                    "ReviewMonitorRendering",
                    "ReviewUI",
                ]
            ),
        ])

        Self.expectNoViolations(violations)
    }

    @Test func importScannerHandlesSwiftImportForms() {
        let imports = Self.importedModules(
            from: "import Foundation; @testable import CodexReviewAppServer; import let CodexReviewAppServerWire.someConstant"
        )

        #expect(imports == [
            "Foundation",
            "CodexReviewAppServer",
            "CodexReviewAppServerWire",
        ])
        #expect(Self.importedModules(from: #"let text = "import CodexReviewAppServer""#).isEmpty)
    }

    private struct ImportBoundaryRule {
        var root: String
        var forbiddenImports: Set<String>
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func swiftSourceFiles(in root: URL) throws -> [String] {
        try FileManager.default
            .subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
    }

    private static func importViolations(in rules: [ImportBoundaryRule]) throws -> [String] {
        var violations: [String] = []
        for rule in rules {
            let root = repositoryRoot.appending(path: rule.root)
            for file in try swiftSourceFiles(in: root) {
                let url = root.appending(path: file)
                let text = try String(contentsOf: url, encoding: .utf8)
                for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let forbiddenImports = importedModules(from: line)
                        .filter { rule.forbiddenImports.contains($0) }
                    for _ in forbiddenImports {
                        violations.append("\(rule.root)/\(file):\(offset + 1): \(line.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
        return violations
    }

    private static func importedModules(from line: Substring) -> [String] {
        line.split(separator: ";").compactMap(importedModule(fromImportStatement:))
    }

    private static func importedModule(fromImportStatement statement: Substring) -> String? {
        let trimmed = statement.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty == false,
              trimmed.hasPrefix("//") == false
        else {
            return nil
        }

        let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let importIndex = tokens.firstIndex(of: "import") else {
            return nil
        }

        guard tokens[..<importIndex].allSatisfy(Self.isAllowedImportPrefix(_:)) else {
            return nil
        }

        var moduleIndex = tokens.index(after: importIndex)
        guard moduleIndex < tokens.endIndex else {
            return nil
        }
        if Self.importKinds.contains(String(tokens[moduleIndex])) {
            moduleIndex = tokens.index(after: moduleIndex)
        }
        guard moduleIndex < tokens.endIndex else {
            return nil
        }

        return tokens[moduleIndex]
            .split(whereSeparator: { $0 == "." || $0 == ";" })
            .first
            .map(String.init)
    }

    private static func isAllowedImportPrefix(_ token: Substring) -> Bool {
        token.hasPrefix("@") || importModifiers.contains(String(token))
    }

    private static let importModifiers: Set<String> = [
        "public",
        "internal",
        "package",
        "private",
        "fileprivate",
    ]

    private static let importKinds: Set<String> = [
        "class",
        "enum",
        "func",
        "let",
        "operator",
        "protocol",
        "struct",
        "typealias",
        "var",
    ]

    private static func expectNoViolations(_ violations: [String]) {
        #expect(violations.isEmpty, Comment(rawValue: violations.joined(separator: "\n")))
    }
}
