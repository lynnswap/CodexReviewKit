import Foundation
import Synchronization
import Testing
@_spi(Testing) @testable import CodexReview
@testable import CodexReviewAppServer
import CodexReviewTesting
@_spi(PreviewSupport) @testable import ReviewUI

@MainActor
extension ReviewUITests {
    @Test func unsupportedAppServerItemsStayOutOfRenderedReview() async throws {
        let transport = FakeJSONRPCTransport()
        let diagnostics = ReviewUIIngestionDiagnosticCapture()
        try await transport.enqueue(AppServerAPI.Initialize.Response(), for: "initialize")
        try await transport.enqueue(
            AppServerAPI.Thread.Start.Response(threadID: "thread-review", model: "gpt-5"),
            for: "thread/start"
        )
        try await transport.enqueue(
            AppServerAPI.Review.Start.Response(
                turnID: "turn-review",
                reviewThreadID: "thread-review"
            ),
            for: "review/start"
        )
        let backend = AppServerCodexReviewBackend(
            client: .init(transport: transport),
            ingestionDiagnosticRecorder: diagnostics
        )
        let store = CodexReviewStore.makeTestingStore(
            backend: ReviewUIAppServerStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        let review = Task { @MainActor in
            try await store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
        }
        try #require(await StoreSnapshotProbe(store: store).waitUntil { snapshot in
            snapshot.job("job-1")?.activeRun?.turnID == "turn-review"
        } != nil)
        let job = try #require(store.job(id: "job-1"))
        let harness = makeWindowHarness(store: store)
        defer { harness.window.close() }
        let contentPane = harness.viewController.transportViewControllerForTesting
        harness.viewController.sidebarViewControllerForTesting.selectJobForTesting(job)
        _ = try await awaitTransportRender(contentPane)

        let unsupportedNotifications = [
            ReviewUIAppServerNotification(
                method: "item/started",
                params: .init(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    item: .init(type: "futureItem", id: "future-1")
                )
            ),
            ReviewUIAppServerNotification(
                method: "item/completed",
                params: .init(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    item: .init(type: "futureItem", id: "future-1")
                )
            ),
        ]
        for notification in unsupportedNotifications {
            try await transport.emitServerNotification(
                method: notification.method,
                params: notification.params
            )
        }
        try await transport.emitServerNotification(
            method: "item/started",
            params: ReviewUIV2ItemNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .command(id: "command-1", status: "inProgress")
            )
        )
        try await transport.emitServerNotification(
            method: "item/commandExecution/outputDelta",
            params: ReviewUIV2DeltaNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                itemID: "command-1",
                delta: "ordinary command output"
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ReviewUIV2ItemNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .command(id: "command-1", status: "completed", exitCode: 0)
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: ReviewUIV2ItemNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(
                    type: "agentMessage",
                    id: "ordinary-log",
                    text: "Ordinary log after unsupported items."
                )
            )
        )
        for method in ["item/started", "item/completed"] {
            try await transport.emitServerNotification(
                method: method,
                params: ReviewUIV2ItemNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    item: .init(
                        type: "exitedReviewMode",
                        id: "review-result",
                        review: "Final review"
                    )
                )
            )
        }
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: ReviewUIV2TurnNotification(
                threadID: "thread-review",
                turn: .init(
                    id: "turn-review",
                    items: [],
                    itemsView: "notLoaded",
                    status: "completed"
                )
            )
        )

        let result = try await review.value
        let rendered = try await awaitTransportRender(contentPane) { snapshot in
            snapshot.log.contains("Ordinary log after unsupported items.")
                && snapshot.log.contains("Final review")
        }

        #expect(result.core.lifecycle.status == .succeeded)
        #expect(result.core.lifecycle.terminal == .completed)
        #expect(result.core.output.hasFinalReview)
        #expect(result.core.output.lastAgentMessage == "Final review")
        #expect(job.logEntries.contains { $0.kind == .error } == false)
        #expect(job.logEntries.contains { $0.text.contains("ordinary command output") })
        #expect(rendered.log.contains("Ran swift test"))
        #expect(rendered.log.contains("Ordinary log after unsupported items."))
        #expect(rendered.log.contains("Final review"))
        #expect(rendered.log.contains("Unsupported app-server") == false)
        #expect(rendered.log.contains("Malformed app-server notification") == false)
        #expect(contentPane.logCommandOutputPanelCountForTesting == 1)
        #expect(contentPane.clickFirstLogCommandOutputPanelHeaderForTesting())
        await awaitNativeLayoutTurn()
        #expect(contentPane.logCommandOutputPanelTerminalTextForTesting?
            .contains("ordinary command output") == true)

        let capturedDiagnostics = diagnostics.snapshot()
        #expect(capturedDiagnostics.count == unsupportedNotifications.count)
        for (diagnostic, notification) in zip(capturedDiagnostics, unsupportedNotifications) {
            #expect(diagnostic.method == notification.method)
            #expect(diagnostic.threadID == "thread-review")
            #expect(diagnostic.turnID == "turn-review")
            #expect(diagnostic.itemType == "futureItem")
            #expect(diagnostic.disposition == .ignored)
            #expect(try canonicalJSON(diagnostic.rawParams) == canonicalJSON(
                JSONEncoder().encode(notification.params)
            ))
        }

        await store.cancelAndDrainReviewWorkersForTesting()
        try await backend.runtimeOwnerLifecycleHandle.closeAndWait()
    }
}

@MainActor
private final class ReviewUIAppServerStoreBackend: PreviewCodexReviewStoreBackend {
    private let reviewBackend: AppServerCodexReviewBackend

    init(reviewBackend: AppServerCodexReviewBackend) {
        self.reviewBackend = reviewBackend
        super.init()
    }

    override func startReview(
        _ request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> BackendReviewAttempt {
        try await reviewBackend.startReview(request, admission: admission)
    }
}

private final class ReviewUIIngestionDiagnosticCapture: ReviewIngestionDiagnosticRecording {
    private let diagnostics = Mutex<[ReviewIngestionDiagnosticRecord]>([])

    func record(_ diagnostic: ReviewIngestionDiagnosticRecord) {
        diagnostics.withLock { $0.append(diagnostic) }
    }

    func snapshot() -> [ReviewIngestionDiagnosticRecord] {
        diagnostics.withLock { $0 }
    }
}

private struct ReviewUIAppServerNotification: Sendable {
    var method: String
    var params: ReviewUIV2ItemNotification
}

private struct ReviewUIV2ItemNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var item: Item
    var startedAtMs: Int64 = 1
    var completedAtMs: Int64 = 2

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case item
        case startedAtMs
        case completedAtMs
    }

    struct Item: Encodable, Sendable {
        var type: String
        var id: String
        var text: String?
        var review: String?
        var command: String?
        var cwd: String?
        var source: String?
        var status: String?
        var commandActions: [[String: String]]?
        var aggregatedOutput: String?
        var exitCode: Int?

        init(
            type: String,
            id: String,
            text: String? = nil,
            review: String? = nil,
            command: String? = nil,
            cwd: String? = nil,
            source: String? = nil,
            status: String? = nil,
            commandActions: [[String: String]]? = nil,
            aggregatedOutput: String? = nil,
            exitCode: Int? = nil
        ) {
            self.type = type
            self.id = id
            self.text = text
            self.review = review
            self.command = command
            self.cwd = cwd
            self.source = source
            self.status = status
            self.commandActions = commandActions
            self.aggregatedOutput = aggregatedOutput
            self.exitCode = exitCode
        }

        static func command(
            id: String,
            status: String,
            exitCode: Int? = nil
        ) -> Self {
            .init(
                type: "commandExecution",
                id: id,
                command: "swift test",
                cwd: "/tmp/project",
                source: "agent",
                status: status,
                commandActions: [],
                aggregatedOutput: "",
                exitCode: exitCode
            )
        }
    }
}

private struct ReviewUIV2DeltaNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var itemID: String
    var delta: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case delta
    }
}

private struct ReviewUIV2TurnNotification: Encodable, Sendable {
    struct Turn: Encodable, Sendable {
        var id: String
        var items: [ReviewUIV2ItemNotification.Item]
        var itemsView: String
        var status: String
    }

    var threadID: String
    var turn: Turn

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
    }
}

private func canonicalJSON(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return try JSONSerialization.data(
        withJSONObject: object,
        options: [.fragmentsAllowed, .sortedKeys]
    )
}
