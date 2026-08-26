import Foundation
import Testing
@_spi(Testing) @testable import CodexReview

@Suite("Codex review job rendering")
@MainActor
struct CodexReviewJobRenderingTests {
    @Test func reviewLogEntryAudienceDefaultsAndDecodesLegacyPayloadsAsProduct() throws {
        let product = ReviewLogEntry(kind: .diagnostic, text: "Product diagnostic")
        #expect(product.audience == .product)

        var developer = product
        developer.audience = .developer
        #expect(product.audience == .product)
        #expect(developer.audience == .developer)

        let productObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(product)) as? [String: Any]
        )
        #expect(Set(productObject.keys) == [
            "id",
            "kind",
            "replacesGroup",
            "text",
            "timestamp",
        ])

        let encoded = try JSONEncoder().encode(developer)
        let developerObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(developerObject["audience"] as? String == "developer")
        #expect(try JSONDecoder().decode(
            ReviewLogEntry.self,
            from: encoded
        ).audience == .developer)

        var legacyObject = developerObject
        legacyObject.removeValue(forKey: "audience")
        let legacyPayload = try JSONSerialization.data(withJSONObject: legacyObject)

        #expect(try JSONDecoder().decode(
            ReviewLogEntry.self,
            from: legacyPayload
        ).audience == .product)
    }

    @Test func productProjectionsHideDeveloperEntriesWhileRawDiagnosticsAndCapRetainThem() {
        let developerDiagnostic = "Developer cleanup detail"
        let job = CodexReviewJob.makeForTesting(
            id: "job-audience-projections",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .failed,
            summary: "Failed",
            logEntries: [
                .init(
                    kind: .agentMessage,
                    groupID: "shared-review",
                    text: "Developer review",
                    audience: .developer
                ),
                .init(kind: .agentMessage, groupID: "shared-review", text: "Product review"),
                .init(kind: .progress, text: "Product activity"),
                .init(kind: .error, text: "Product error"),
                .init(kind: .diagnostic, text: "Product diagnostic"),
                .init(kind: .progress, text: "Developer activity", audience: .developer),
                .init(kind: .diagnostic, text: developerDiagnostic, audience: .developer),
            ]
        )

        #expect(job.logEntries.count == 7)
        #expect(job.logText == """
        Product review

        Product activity

        Product error

        Product diagnostic
        """)
        #expect(job.reviewOutputText == "Product review")
        #expect(job.activityLogText == "Product activity")
        #expect(job.rawLogText == """
        Product diagnostic
        Developer cleanup detail
        """)
        #expect(job.diagnosticText == """
        Product error

        Product diagnostic
        Developer cleanup detail
        """)
        #expect(job.cappedLogBytes >= developerDiagnostic.utf8.count)
    }

    @Test func activeCommandCleanupKeepsProductAndDeveloperGroupsIndependent() throws {
        let productStartedAt = Date(timeIntervalSince1970: 100)
        let developerCompletedAt = Date(timeIntervalSince1970: 101)
        let terminalDate = Date(timeIntervalSince1970: 102)
        let job = CodexReviewJob.makeForTesting(
            id: "job-command-audience",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(
                    kind: .command,
                    groupID: "shared-command",
                    text: "$ product command",
                    metadata: .init(
                        sourceType: "commandExecution",
                        status: "inProgress",
                        startedAt: productStartedAt,
                        commandStatus: "inProgress"
                    )
                ),
                .init(
                    kind: .command,
                    groupID: "shared-command",
                    text: "$ developer command",
                    metadata: .init(
                        sourceType: "commandExecution",
                        status: "completed",
                        completedAt: developerCompletedAt,
                        commandStatus: "completed"
                    ),
                    audience: .developer
                ),
            ]
        )

        job.closeActiveCommandLogEntries(status: "completed", completedAt: terminalDate)

        #expect(job.logEntries.count == 3)
        let replacement = try #require(job.logEntries.last)
        #expect(replacement.audience == .product)
        #expect(replacement.replacesGroup)
        #expect(replacement.metadata?.commandStatus == "completed")
        #expect(replacement.metadata?.completedAt == terminalDate)
    }

    @Test func cancellationRequestedSetterProjectsOnlyThePendingReceipt() throws {
        let job = CodexReviewJob.makeForTesting(
            id: "job-cancellation-projection",
            targetSummary: "Uncommitted changes",
            status: .running,
            cancellationRequested: true,
            summary: "Running"
        )
        let receipt = try #require(job.pendingCancellationRequest)

        job.cancellationRequested = true
        #expect(job.pendingCancellationRequest == receipt)

        job.cancellationRequested = false
        #expect(job.pendingCancellationRequest == nil)
        #expect(job.cancellationRequested == false)
    }

    @Test func renderedLogTextKeepsCommandOutputInSemanticProjection() {
        let job = CodexReviewJob.makeForTesting(
            id: "job-command-output",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .succeeded,
            summary: "Done",
            logEntries: [
                .init(kind: .command, text: "$ git diff --stat"),
                .init(kind: .commandOutput, groupID: "cmd-1", text: "README.md | 1 +"),
                .init(kind: .agentMessage, text: "No correctness issues found."),
            ]
        )

        #expect(job.logText == """
        $ git diff --stat

        README.md | 1 +

        No correctness issues found.
        """)
        #expect(job.activityLogText == """
        $ git diff --stat

        README.md | 1 +
        """)
    }

    @Test func tailAppendPublishesIncrementalLogMutation() {
        let job = CodexReviewJob.makeForTesting(
            id: "job-tail-append-mutation",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .agentMessage, groupID: "msg-1", text: "Initial")
            ]
        )

        let initialRevision = job.logRevision
        job.appendLogEntry(.init(kind: .agentMessage, groupID: "msg-1", text: " append"))

        #expect(job.logRevision == initialRevision + 1)
        #expect(job.lastLogMutation == .append)
        #expect(job.logText == "Initial append")
    }

    @Test func groupedReplacementPublishesReloadLogMutation() {
        let job = CodexReviewJob.makeForTesting(
            id: "job-grouped-replacement-mutation",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .plan, groupID: "plan-1", text: "- original")
            ]
        )

        let initialRevision = job.logRevision
        job.appendLogEntry(.init(
            kind: .plan,
            groupID: "plan-1",
            replacesGroup: true,
            text: "- updated"
        ))

        #expect(job.logRevision == initialRevision + 1)
        #expect(job.lastLogMutation == .reload)
        #expect(job.logEntries.count == 2)
        #expect(job.logText == "- updated")
    }

    @Test func runningRawReasoningOverLimitRemainsAppendOnly() {
        let initialText = String(repeating: "a", count: 250 * 1024)
        let delta = String(repeating: "b", count: 20 * 1024)
        let job = CodexReviewJob.makeForTesting(
            id: "job-live-raw-reasoning-limit",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .rawReasoning, groupID: "reasoning-1", text: initialText)
            ]
        )

        let initialRevision = job.logRevision
        job.appendLogEntry(.init(kind: .rawReasoning, groupID: "reasoning-1", text: delta))

        #expect(job.logRevision == initialRevision + 1)
        #expect(job.lastLogMutation == .append)
        #expect(job.logEntries.count == 2)
        #expect(job.logText.hasSuffix(delta))
        #expect(job.cappedLogBytes > 256 * 1024)
    }

    @Test func terminalRawReasoningTrimKeepsNewestTail() {
        let initialText = String(repeating: "a", count: 250 * 1024)
        let delta = String(repeating: "b", count: 20 * 1024)
        let job = CodexReviewJob.makeForTesting(
            id: "job-terminal-raw-reasoning-limit",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .succeeded,
            summary: "Done",
            logEntries: [
                .init(kind: .rawReasoning, groupID: "reasoning-1", text: initialText)
            ]
        )

        job.appendLogEntry(.init(kind: .rawReasoning, groupID: "reasoning-1", text: delta))

        #expect(job.lastLogMutation == .reload)
        #expect(job.logText.hasSuffix(delta))
        #expect(job.logEntries.last?.text == delta)
        #expect(job.cappedLogBytes <= 256 * 1024)
    }

    @Test func explicitReviewLogLimitApplicationPublishesReloadMutation() {
        let initialText = String(repeating: "a", count: 250 * 1024)
        let delta = String(repeating: "b", count: 20 * 1024)
        let job = CodexReviewJob.makeForTesting(
            id: "job-explicit-raw-reasoning-limit",
            cwd: "/tmp/workspace",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .rawReasoning, groupID: "reasoning-1", text: initialText)
            ]
        )
        job.appendLogEntry(.init(kind: .rawReasoning, groupID: "reasoning-1", text: delta))
        let appendRevision = job.logRevision

        #expect(job.applyReviewLogLimit())
        #expect(job.logRevision == appendRevision + 1)
        #expect(job.lastLogMutation == .reload)
        #expect(job.logText.hasSuffix(delta))
        #expect(job.cappedLogBytes <= 256 * 1024)
    }
}
