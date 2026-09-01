import Testing
@testable import CodexReview

@Suite("Parsed review results")
struct ParsedReviewResultTests {
    @Test func emptyFinalReviewTextIsNotAvailable() {
        let result = ParsedReviewResult.parse(finalReviewText: " \n ")

        #expect(result == .notAvailable())
    }

    @Test(arguments: [
        "No findings.",
        "No correctness issues found.",
        "No correctness issues found in the touched files.",
        "No findings.\n\nOverall assessment: the changed code is correct.",
    ])
    func explicitNoFindingResultReportsNoFindings(text: String) {
        let result = ParsedReviewResult.parse(finalReviewText: text)

        #expect(result.state == .noFindings)
        #expect(result.findingCount == 0)
        #expect(result.findings.isEmpty)
        #expect(result.source == .parsedFinalReviewText)
    }

    @Test func arbitraryFinalReviewDoesNotClaimNoFindings() {
        let result = ParsedReviewResult.parse(finalReviewText: "Review completed with an unrecognized result.")

        #expect(result.state == .unknown)
        #expect(result.findingCount == nil)
        #expect(result.findings.isEmpty)
        #expect(result.source == .unrecognizedFindingBlock)
    }

    @Test func currentReviewAgentFormatParsesCapturedLocalizedFinding() throws {
        let result = ParsedReviewResult.parse(finalReviewText: """
        [P0] トークン比較を復元してアクセス許可を判定する — AccessGate.swift:3

        `permits` が常に `true` を返すため、`suppliedToken` が `expectedToken` と異なっていても許可され、アクセス制御が完全に無効化されます。`suppliedToken == expectedToken` に戻してください。

        総評: staged 差分と untracked ファイルはなく、unstaged 変更はこの1行です。認証バイパスのためマージ不可です。
        """)

        #expect(result.state == .hasFindings)
        #expect(result.findingCount == 1)
        #expect(result.parserVersion == ParsedReviewResult.currentParserVersion)
        let finding = try #require(result.findings.first)
        #expect(finding.title == "[P0] トークン比較を復元してアクセス許可を判定する")
        #expect(finding.priority == 0)
        #expect(finding.location == .init(path: "AccessGate.swift", startLine: 3, endLine: 3))
        #expect(finding.body == "`permits` が常に `true` を返すため、`suppliedToken` が `expectedToken` と異なっていても許可され、アクセス制御が完全に無効化されます。`suppliedToken == expectedToken` に戻してください。")
        #expect(finding.rawText.contains("総評:") == false)
    }

    @Test func currentReviewAgentFormatParsesInlineCodeLocations() {
        let singleLine = ParsedReviewResult.parse(finalReviewText: """
        [P0] Restore token validation — `AccessGate.swift:3`

        Reject mismatched tokens.
        """)
        let range = ParsedReviewResult.parse(finalReviewText: """
        [P1] Preserve terminal ownership — `Sources/Store.swift:10-12`

        Keep one terminal owner.
        """)

        #expect(singleLine.findings.first?.location == .init(
            path: "AccessGate.swift",
            startLine: 3,
            endLine: 3
        ))
        #expect(range.findings.first?.location == .init(
            path: "Sources/Store.swift",
            startLine: 10,
            endLine: 12
        ))
    }

    @Test func currentReviewAgentFormatParsesMarkdownLinkLocations() {
        let singleLine = ParsedReviewResult.parse(finalReviewText: """
        [P0] Restore token validation — [AccessGate.swift](/tmp/review/AccessGate.swift:3)

        Reject mismatched tokens.
        """)
        let range = ParsedReviewResult.parse(finalReviewText: """
        [P1] Preserve terminal ownership — [Store.swift](Sources/Store.swift:10-12)

        Keep one terminal owner.
        """)
        let encodedPath = ParsedReviewResult.parse(finalReviewText: """
        [P2] Preserve a path containing spaces — [My File.swift](/tmp/My%20Project/My%20File.swift:4)

        Decode the local file destination.
        """)
        let unicodePath = ParsedReviewResult.parse(finalReviewText: """
        [P2] Preserve a Unicode path — [日本語.swift](/tmp/日本語.swift:5)

        Preserve the decoded local file destination.
        """)
        let encodedPunctuation = ParsedReviewResult.parse(finalReviewText: """
        [P2] Preserve encoded punctuation — [Foo?#.swift](/tmp/Foo%3F%23.swift:6)

        Keep encoded query and fragment characters as path data.
        """)
        let relativePath = ParsedReviewResult.parse(finalReviewText: """
        [P2] Preserve a relative path — [Foo.swift](./Foo.swift:7)

        Keep the relative path spelling.
        """)
        let colonPath = ParsedReviewResult.parse(finalReviewText: """
        [P2] Preserve a path colon — [Foo.swift](/tmp/a:b/Foo.swift:8)

        Do not treat an interior path colon as a scheme.
        """)
        let punctuationLabel = ParsedReviewResult.parse(finalReviewText: """
        [P2] Preserve filename punctuation — [My_File~*.swift](/tmp/My_File~*.swift:9)

        Keep literal filename punctuation when the destination matches it exactly.
        """)

        #expect(singleLine.findings.first?.location == .init(
            path: "/tmp/review/AccessGate.swift",
            startLine: 3,
            endLine: 3
        ))
        #expect(range.findings.first?.location == .init(
            path: "Sources/Store.swift",
            startLine: 10,
            endLine: 12
        ))
        #expect(encodedPath.findings.first?.location == .init(
            path: "/tmp/My Project/My File.swift",
            startLine: 4,
            endLine: 4
        ))
        #expect(unicodePath.findings.first?.location == .init(
            path: "/tmp/日本語.swift",
            startLine: 5,
            endLine: 5
        ))
        #expect(encodedPunctuation.findings.first?.location == .init(
            path: "/tmp/Foo?#.swift",
            startLine: 6,
            endLine: 6
        ))
        #expect(relativePath.findings.first?.location == .init(
            path: "./Foo.swift",
            startLine: 7,
            endLine: 7
        ))
        #expect(colonPath.findings.first?.location == .init(
            path: "/tmp/a:b/Foo.swift",
            startLine: 8,
            endLine: 8
        ))
        #expect(punctuationLabel.findings.first?.location == .init(
            path: "/tmp/My_File~*.swift",
            startLine: 9,
            endLine: 9
        ))
    }

    @Test func plainLocationContainingMarkdownLikeBracketsStillParses() {
        let bracketedDirectory = ParsedReviewResult.parse(finalReviewText: """
        [P1] Preserve generated output — [generated]/Page.swift:12

        Keep the existing plain-path contract.
        """)
        let linkLikePrefix = ParsedReviewResult.parse(finalReviewText: """
        [P1] Preserve debug output — [generated](debug)/Page.swift:14

        Keep a complete plain path out of the Markdown-link parser.
        """)
        let linkLikeFilename = ParsedReviewResult.parse(finalReviewText: """
        [P1] Preserve a link-like filename — [generated](debug):16

        Preserve the parser-v3 plain-path contract when the full token is not a link wrapper.
        """)
        let pathWithSpaces = ParsedReviewResult.parse(finalReviewText: """
        [P1] Preserve a plain path containing spaces — My Project/File.swift:18

        Keep parser-v3 plain-path semantics outside a Markdown wrapper.
        """)
        let uriLikePath = ParsedReviewResult.parse(finalReviewText: """
        [P1] Preserve a URI-like plain path — file:/tmp/File.swift:20

        Apply the local URI gate only inside a complete Markdown wrapper.
        """)

        #expect(bracketedDirectory.findings.first?.location == .init(
            path: "[generated]/Page.swift",
            startLine: 12,
            endLine: 12
        ))
        #expect(linkLikePrefix.findings.first?.location == .init(
            path: "[generated](debug)/Page.swift",
            startLine: 14,
            endLine: 14
        ))
        #expect(linkLikeFilename.findings.first?.location == .init(
            path: "[generated](debug)",
            startLine: 16,
            endLine: 16
        ))
        #expect(pathWithSpaces.findings.first?.location == .init(
            path: "My Project/File.swift",
            startLine: 18,
            endLine: 18
        ))
        #expect(uriLikePath.findings.first?.location == .init(
            path: "file:/tmp/File.swift",
            startLine: 20,
            endLine: 20
        ))
    }

    @Test(arguments: [
        "[AccessGate.swift](/tmp/review/Other.swift:3)",
        "[Gate.swift](/tmp/review/AccessGate.swift:3)",
        "[AccessGate.swift](https://example.com/AccessGate.swift:3)",
        "[AccessGate.swift](file:///tmp/review/AccessGate.swift:3)",
        "[AccessGate.swift](file:/tmp/review/AccessGate.swift:3)",
        "[AccessGate.swift](FiLe:/tmp/review/AccessGate.swift:3)",
        "[AccessGate.swift](mailto:AccessGate.swift:3)",
        "[AccessGate.swift](%66ile%3A/tmp/review/AccessGate.swift:3)",
        "[AccessGate.swift](//example.com/review/AccessGate.swift:3)",
        "[AccessGate.swift](///tmp/review/AccessGate.swift:3)",
        "[AccessGate.swift](%2F%2Fexample.com/review/AccessGate.swift:3)",
        "[AccessGate.swift](/tmp/Other.swift?redirect=/AccessGate.swift:3)",
        "[AccessGate.swift](/tmp/Other.swift#anchor/AccessGate.swift:3)",
        "[My File.swift](/tmp/My Project/My File.swift:4)",
        "[AccessGate.swift](/tmp/review\t/AccessGate.swift:3)",
        "[AccessGate.swift](/tmp/review%ZZ/AccessGate.swift:3)",
        "[AccessGate.swift](/tmp/review%/AccessGate.swift:3)",
        "[AccessGate.swift](/tmp/review%2/AccessGate.swift:3)",
        "[AccessGate.swift](/tmp/review%FF/AccessGate.swift:3)",
        "[AccessGate.swift](/tmp/review%00/AccessGate.swift:3)",
        "[AccessGate.swift](/tmp/review%0A/AccessGate.swift:3)",
        "[AccessGate.swift](/tmp/review/AccessGate.swift:not-a-line)",
        "[AccessGate.swift](/tmp/review/AccessGate.swift:0)",
        "[AccessGate.swift](/tmp/review/AccessGate.swift:12-10)",
        "[AccessGate.swift(/tmp/review/AccessGate.swift:3)",
        "[Access[Gate.swift]](/tmp/review/AccessGate.swift:3)",
        "[AccessGate.swift](/tmp/review/AccessGate.swift:3)[Other.swift](Other.swift:4)",
        "[](/tmp/review/AccessGate.swift:3)",
        "[ AccessGate.swift](/tmp/review/AccessGate.swift:3)",
        "[AccessGate.swift ](/tmp/review/AccessGate.swift:3)",
        "[AccessGate.swift](/tmp/review/AccessGate.swift:3 \"title\")",
        "[AccessGate.swift](</tmp/review/AccessGate.swift:3>)",
        "[AccessGate.swift](/tmp/review/(debug)/AccessGate.swift:3)",
        "[`AccessGate.swift`](/tmp/review/AccessGate.swift:3)",
        "[Access&amp;Gate.swift](/tmp/review/Access%26Gate.swift:3)",
    ])
    func malformedMarkdownLinkLocationReportsUnknown(location: String) {
        let result = ParsedReviewResult.parse(finalReviewText: """
        [P1] Reject malformed location markup — \(location)

        Do not guess the path or line.
        """)

        #expect(result.state == .unknown)
        #expect(result.findings.isEmpty)
        #expect(result.source == .unrecognizedFindingBlock)
    }

    @Test(arguments: [
        "`AccessGate.swift:3",
        "AccessGate.swift:3`",
        "``AccessGate.swift:3``",
        "`AccessGate.swift`:3",
        "`Access`Gate.swift:3`",
    ])
    func malformedInlineCodeLocationReportsUnknown(location: String) {
        let result = ParsedReviewResult.parse(finalReviewText: """
        [P1] Reject malformed location markup — \(location)

        Do not guess the path or line.
        """)

        #expect(result.state == .unknown)
        #expect(result.findings.isEmpty)
        #expect(result.source == .unrecognizedFindingBlock)
    }

    @Test func currentReviewAgentFormatParsesMultipleFindingsAndRanges() throws {
        let result = ParsedReviewResult.parse(finalReviewText: """
        Review summary before findings.

        [P1] Preserve the terminal owner — Sources/Store.swift:10-12
        Keep the canonical terminal bound to the selected run.

        [P3] Retain exact file identity — Tests/StoreTests.swift:44
        Assert the single-line location without inventing a range.

        Overall assessment: two actionable findings.
        """)

        #expect(result.state == .hasFindings)
        #expect(result.findingCount == 2)
        #expect(result.findings[0].location == .init(
            path: "Sources/Store.swift",
            startLine: 10,
            endLine: 12
        ))
        #expect(result.findings[1].location == .init(
            path: "Tests/StoreTests.swift",
            startLine: 44,
            endLine: 44
        ))
        #expect(result.findings[1].body == "Assert the single-line location without inventing a range.")
    }

    @Test func malformedCurrentFindingReportsUnknown() {
        let result = ParsedReviewResult.parse(finalReviewText: """
        [P1] Valid first finding — Sources/Store.swift:10
        Body.

        [P2] Missing location range — Sources/Other.swift:not-a-line
        Body.
        """)

        #expect(result.state == .unknown)
        #expect(result.findingCount == nil)
        #expect(result.findings.isEmpty)
        #expect(result.source == .unrecognizedFindingBlock)
    }

    @Test func fullReviewCommentsParseStructuredFindings() throws {
        let result = ParsedReviewResult.parse(finalReviewText: """
        Summary text.

        Full review comments:
        - [P1] Preserve selected workspace identity — Sources/Sidebar.swift:10-12
          Re-resolve the selected workspace by `cwd` after store reloads.
          Otherwise the detail pane can detach from live state.

        - [P3] Trim diagnostic text — Tests/ReviewTests.swift:5-5
          Keep log snapshots bounded.
        """)

        #expect(result.state == .hasFindings)
        #expect(result.findingCount == 2)
        #expect(result.source == .parsedFinalReviewText)

        let first = try #require(result.findings.first)
        #expect(first.title == "[P1] Preserve selected workspace identity")
        #expect(first.priority == 1)
        #expect(first.body == """
        Re-resolve the selected workspace by `cwd` after store reloads.
        Otherwise the detail pane can detach from live state.
        """)
        #expect(first.location == .init(path: "Sources/Sidebar.swift", startLine: 10, endLine: 12))

        let second = try #require(result.findings.last)
        #expect(second.title == "[P3] Trim diagnostic text")
        #expect(second.priority == 3)
        #expect(second.location == .init(path: "Tests/ReviewTests.swift", startLine: 5, endLine: 5))
    }

    @Test func legacyIndentedBulletLikeBodyRemainsInTheCurrentFinding() throws {
        let result = ParsedReviewResult.parse(finalReviewText: """
        Full review comments:
        - [P1] Preserve the legacy body — Sources/Parser.swift:10-12
          Recheck both examples:
          - Recheck the guide — Docs/Guide.md:20-22
        """)

        #expect(result.state == .hasFindings)
        #expect(result.findingCount == 1)
        let finding = try #require(result.findings.first)
        #expect(finding.body == """
        Recheck both examples:
        - Recheck the guide — Docs/Guide.md:20-22
        """)
    }

    @Test func priorityPrefixedCurrentBodyLineIsNotPromotedToAFinding() throws {
        let result = ParsedReviewResult.parse(finalReviewText: """
        [P1] Document priority semantics — Sources/Parser.swift:10
        The severity mapping is:
        [P2] means an ordinary actionable defect — Docs/Guide.md:20
        """)

        #expect(result.state == .hasFindings)
        #expect(result.findingCount == 1)
        let finding = try #require(result.findings.first)
        #expect(finding.body == """
        The severity mapping is:
        [P2] means an ordinary actionable defect — Docs/Guide.md:20
        """)
    }

    @Test func indentedPriorityExampleAfterBlankLineIsNotPromotedToAFinding() throws {
        let result = ParsedReviewResult.parse(finalReviewText: """
        [P1] Document priority semantics — Sources/Parser.swift:10

        Describe the top-level finding.

          - [P2] Example only — Docs/Guide.md:20
        """)

        #expect(result.state == .hasFindings)
        #expect(result.findingCount == 1)
        #expect(result.findings.first?.title == "[P1] Document priority semantics")
    }

    @Test func quotedLegacyBlockAfterCurrentFindingDoesNotReplaceCurrentFormat() throws {
        let result = ParsedReviewResult.parse(finalReviewText: """
        [P1] Keep the current finding — Sources/Parser.swift:10

        Parse this finding before the assessment.

        Full review comments:
        - [P3] Quoted legacy example — Docs/Guide.md:20-22
          This block documents the former output contract.
        """)

        #expect(result.state == .hasFindings)
        #expect(result.findingCount == 1)
        #expect(result.findings.first?.title == "[P1] Keep the current finding")
    }

    @Test func malformedFindingBlockReportsUnknown() {
        let result = ParsedReviewResult.parse(finalReviewText: """
        Review comment:
        This line is not a structured finding.
        """)

        #expect(result.state == .unknown)
        #expect(result.findingCount == nil)
        #expect(result.findings.isEmpty)
        #expect(result.source == .unrecognizedFindingBlock)
    }
}
