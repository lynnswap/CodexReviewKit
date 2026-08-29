import Foundation
import Testing
@testable import CodexReview

@Suite(.serialized)
@MainActor
struct CodexReviewStoreDiagnosticsTests {
    @Test func diagnosticsExposeRestoredSemanticHistoryWithoutTranscript() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "review-history-diagnostics-\(UUID().uuidString)",
            isDirectory: true
        )
        let diagnosticsURL = directory.appendingPathComponent(
            "diagnostics.json",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = try StartedReviewRecord(
            id: "review-1",
            cwd: "/tmp/workspace",
            workspaceSortOrder: 0,
            sortOrder: 0,
            target: .uncommittedChanges,
            model: "gpt-5.6-sol",
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let parsedResult = try PersistedParsedReviewResult(
            state: .hasFindings,
            findingCount: 1,
            findings: [
                .init(
                    ordinal: 0,
                    title: "[P1] Preserve semantic history",
                    body: "Persist the finding without its raw source block.",
                    priority: 1,
                    location: .init(path: "Sources/App.swift", startLine: 3, endLine: 4)
                ),
            ],
            source: .parsedFinalReviewText,
            parserVersion: ParsedReviewResult.currentParserVersion
        )
        let terminal = try TerminalReviewRecord(
            id: started.id,
            model: started.model,
            terminal: .completed,
            endedAt: Date(timeIntervalSince1970: 120),
            summary: "Review completed.",
            canonicalReview: "Review comment:\n- [P1] Preserve semantic history — Sources/App.swift:3-4",
            parsedResult: parsedResult
        )
        let job = try RestoredReviewRecord(started: started, terminal: terminal)
            .makeRestoredJob()
        let store = CodexReviewStore.makePreviewStore(diagnosticsURL: diagnosticsURL)
        store.loadForTesting(
            serverState: .failed("MCP unavailable"),
            workspaces: [CodexReviewWorkspace(cwd: started.cwd)],
            jobs: [job]
        )
        store.transitionHistoryAvailability(to: .available)

        let data = try Data(contentsOf: diagnosticsURL)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["historyAvailability"] as? String == "available")
        let jobs = try #require(object["jobs"] as? [[String: Any]])
        let encodedJob = try #require(jobs.first)
        #expect(encodedJob["id"] as? String == started.id)
        #expect(encodedJob["cwd"] as? String == started.cwd)
        #expect(encodedJob["origin"] as? String == "restoredHistory")
        #expect((encodedJob["target"] as? [String: Any])?["type"] as? String == "uncommittedChanges")
        #expect(encodedJob["model"] as? String == started.model)
        #expect((encodedJob["terminal"] as? [String: Any])?["kind"] as? String == "completed")
        #expect(encodedJob["canonicalReview"] as? String == terminal.canonicalReview)
        let encodedParsedResult = try #require(encodedJob["parsedResult"] as? [String: Any])
        #expect(encodedParsedResult["state"] as? String == "hasFindings")
        #expect(encodedParsedResult["findingCount"] as? Int == 1)
        #expect((encodedParsedResult["findings"] as? [[String: Any]])?.count == 1)
        #expect(encodedJob["logText"] == nil)
        #expect(encodedJob["rawLogText"] == nil)
        #expect(String(decoding: data, as: UTF8.self).contains("rawText") == false)
    }
}
