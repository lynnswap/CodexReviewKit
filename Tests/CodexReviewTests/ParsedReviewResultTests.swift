import Testing
@testable import CodexReview

@Suite("Parsed review results")
struct ParsedReviewResultTests {
    @Test func emptyFinalReviewTextIsNotAvailable() {
        let result = ParsedReviewResult.parse(finalReviewText: " \n ")

        #expect(result == .notAvailable())
    }

    @Test func finalReviewWithoutFindingHeaderReportsNoFindings() {
        let result = ParsedReviewResult.parse(finalReviewText: "No correctness issues found.")

        #expect(result.state == .noFindings)
        #expect(result.findingCount == 0)
        #expect(result.findings.isEmpty)
        #expect(result.source == .parsedFinalReviewText)
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
