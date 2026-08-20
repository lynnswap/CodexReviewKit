import Foundation
import Testing
@testable import CodexReviewAppServer
import CodexReview
import CodexReviewTesting

private enum CurrentV2FixturePin {
    static let upstreamCodexRevision = "3b45c29062ff0e76e71c91b6753290400e7fa8da"
    static let installedCodexVersion = "codex-cli 0.148.0-alpha.15"
    static let schemaRevision = "codex-rs/app-server-protocol/src/protocol/v2@3b45c290"

    static let reviewStart = Data(#"""
    {
      "turn": {
        "id": "turn-review",
        "items": [],
        "itemsView": "notLoaded",
        "status": "inProgress",
        "error": null,
        "startedAt": null,
        "completedAt": null,
        "durationMs": null
      },
      "reviewThreadId": "thread-review"
    }
    """#.utf8)

    static let fullReviewNotifications = [
        Data(#"""
        {
          "method": "item/completed",
          "params": {
            "threadId": "thread-review",
            "turnId": "turn-review",
            "item": {
              "type": "exitedReviewMode",
              "id": "review-result",
              "review": "No findings."
            }
          }
        }
        """#.utf8),
        Data(#"""
        {
          "method": "turn/completed",
          "params": {
            "threadId": "thread-review",
            "turn": {
              "id": "turn-review",
              "items": [
                {
                  "type": "agentMessage",
                  "id": "assistant-final",
                  "text": "No findings.",
                  "delivery": null
                }
              ],
              "itemsView": "summary",
              "status": "completed",
              "error": null,
              "startedAt": 1787187600,
              "completedAt": 1787187601,
              "durationMs": 1000
            }
          }
        }
        """#.utf8),
    ]

    static let sparseTurnCompleted = Data(#"""
    {
      "method": "turn/completed",
      "params": {
        "threadId": "thread-review",
        "turn": {
          "id": "turn-review",
          "items": [
            {
              "type": "agentMessage",
              "id": "assistant-final",
              "text": "No findings.",
              "delivery": null
            }
          ],
          "itemsView": "summary",
          "status": "completed",
          "error": null,
          "startedAt": 1787187600,
          "completedAt": 1787187601,
          "durationMs": 1000
        }
      }
    }
    """#.utf8)

    static let reviewCommandDelta = Data(#"""
    {
      "method": "item/commandExecution/outputDelta",
      "params": {
        "threadId": "thread-review",
        "turnId": "turn-review",
        "itemId": "command-item",
        "delta": "invalid: \uFFFD\n"
      }
    }
    """#.utf8)

    static let standaloneCommandDelta = Data(#"""
    {
      "method": "command/exec/outputDelta",
      "params": {
        "processId": "command-item",
        "stream": "stdout",
        "deltaBase64": "Ynl0ZXM="
      }
    }
    """#.utf8)
}

@Suite("current-v2 review wire characterization")
struct CurrentV2ReviewWireCharacterizationTests {
    @Test func fixturePinsIdentifyTheApprovedContract() {
        #expect(CurrentV2FixturePin.upstreamCodexRevision == "3b45c29062ff0e76e71c91b6753290400e7fa8da")
        #expect(CurrentV2FixturePin.installedCodexVersion == "codex-cli 0.148.0-alpha.15")
        #expect(CurrentV2FixturePin.schemaRevision.hasSuffix("@3b45c290"))
    }

    @Test func reviewStartFixesTheReviewThreadAndTurnPair() throws {
        let response = try JSONDecoder().decode(
            AppServerAPI.Review.Start.Response.self,
            from: CurrentV2FixturePin.reviewStart
        )

        #expect(response.reviewThreadID == "thread-review")
        #expect(response.turnID == "turn-review")
    }

    @Test func terminalStatusAndSparseSummaryAreNestedInsideTurn() throws {
        let object = try object(CurrentV2FixturePin.sparseTurnCompleted)
        let params = try #require(object["params"] as? [String: Any])
        let turn = try #require(params["turn"] as? [String: Any])
        let items = try #require(turn["items"] as? [[String: Any]])

        #expect(params["status"] == nil)
        #expect(params["result"] == nil)
        #expect(turn["status"] as? String == "completed")
        #expect(turn["itemsView"] as? String == "summary")
        #expect(items.count == 1)
        #expect(items[0]["type"] as? String == "agentMessage")
        #expect(items[0]["delivery"] is NSNull)
    }

    @Test func fullDeliveryPlacesTheMarkerBeforeTheTurnTerminal() throws {
        let methods = try CurrentV2FixturePin.fullReviewNotifications.map {
            try #require(object($0)["method"] as? String)
        }

        #expect(methods == ["item/completed", "turn/completed"])
    }

    @Test func reviewAndStandaloneCommandDeltasHaveDifferentRoutingIdentity() throws {
        let review = try object(CurrentV2FixturePin.reviewCommandDelta)
        let reviewParams = try #require(review["params"] as? [String: Any])
        let standalone = try object(CurrentV2FixturePin.standaloneCommandDelta)
        let standaloneParams = try #require(standalone["params"] as? [String: Any])

        #expect(reviewParams["threadId"] as? String == "thread-review")
        #expect(reviewParams["turnId"] as? String == "turn-review")
        #expect(reviewParams["itemId"] as? String == "command-item")
        #expect(reviewParams["delta"] as? String == "invalid: \u{FFFD}\n")
        #expect(standaloneParams["processId"] as? String == "command-item")
        #expect(standaloneParams["threadId"] == nil)
        #expect(standaloneParams["turnId"] == nil)
        #expect(standaloneParams["itemId"] == nil)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@Suite("current-v2 review decoder and terminal reducer")
struct CurrentV2ReviewDecoderReducerTests {
    @Test func fullMarkerIsTheCanonicalResultAndSuppressesItsTypedCompanion() throws {
        var reducer = makeReducer()
        let marker = try reviewEnvelope(CurrentV2FixturePin.fullReviewNotifications[0])
        let terminal = try reviewEnvelope(CurrentV2FixturePin.fullReviewNotifications[1])

        #expect(try reducer.ingest(marker) == .accepted(nil))
        let result = try reducer.ingest(terminal)
        guard case .accepted(.completed(let final)) = result else {
            Issue.record("Expected a completed terminal")
            return
        }
        #expect(final.text == "No findings.")
        #expect(final.source == .exitedReviewMode(itemID: "review-result"))
        #expect(final.suppressedAgentMessageItemIDs == ["assistant-final"])
    }

    @Test func sparseSummaryPromotesOneSynchronousAgentMessage() throws {
        var reducer = makeReducer()
        let terminal = try reviewEnvelope(CurrentV2FixturePin.sparseTurnCompleted)

        let result = try reducer.ingest(terminal)
        guard case .accepted(.completed(let final)) = result else {
            Issue.record("Expected a completed terminal")
            return
        }
        #expect(final.text == "No findings.")
        #expect(final.source == .turnSummary(itemID: "assistant-final"))
        #expect(final.suppressedAgentMessageItemIDs.isEmpty)
    }

    @Test(
        arguments: [
            #"{"items":[],"itemsView":"summary"}"#,
            #"{"items":[{"type":"agentMessage","id":"final","text":"   ","delivery":null}],"itemsView":"summary"}"#,
            #"{"items":[{"type":"agentMessage","id":"one","text":"one","delivery":null},{"type":"agentMessage","id":"two","text":"two","delivery":null}],"itemsView":"summary"}"#,
            #"{"items":[{"type":"agentMessage","id":"final","text":"async","delivery":"async"}],"itemsView":"summary"}"#,
            #"{"items":[{"type":"agentMessage","id":"final","text":"not loaded","delivery":null}],"itemsView":"notLoaded"}"#,
        ]
    )
    func invalidSparseSummariesFailWithoutLastMessageFallback(_ turnFragment: String) throws {
        var reducer = makeReducer()
        let terminal = try reviewEnvelope(try turnCompletedData(turnFragment: turnFragment))

        guard case .accepted(.failed(let message)) = try reducer.ingest(terminal) else {
            Issue.record("Expected missing-final-review failure")
            return
        }
        #expect(message?.contains("canonical final review") == true)
    }

    @Test func emptyFullMarkerDoesNotFallBackToTheSummaryCompanion() throws {
        var reducer = makeReducer()
        let marker = try reviewEnvelope(notificationData(
            method: "item/completed",
            params: #"{"threadId":"thread-review","turnId":"turn-review","item":{"type":"exitedReviewMode","id":"marker","review":"  "}}"#
        ))
        let terminal = try reviewEnvelope(CurrentV2FixturePin.sparseTurnCompleted)

        #expect(try reducer.ingest(marker) == .accepted(nil))
        guard case .accepted(.failed(let message)) = try reducer.ingest(terminal) else {
            Issue.record("Expected empty marker failure")
            return
        }
        #expect(message?.contains("canonical final review") == true)
    }

    @Test(
        arguments: [
            ("interrupted", "Stopped", ReviewAttemptTerminal.interrupted(message: "Stopped")),
            ("failed", "Backend failed", ReviewAttemptTerminal.failed(message: "Backend failed")),
        ]
    )
    func typedTerminalStatusesRemainDistinct(
        status: String,
        message: String,
        expected: ReviewAttemptTerminal
    ) throws {
        var reducer = makeReducer()
        let data = try terminalData(status: status, errorMessage: message)

        #expect(try reducer.ingest(reviewEnvelope(data)) == .accepted(expected))
    }

    @Test(arguments: ["inProgress", "futureStatus"])
    func nonterminalOrUnknownTerminalStatusFailsVisibly(_ status: String) throws {
        var reducer = makeReducer()

        guard case .accepted(.failed(let message)) = try reducer.ingest(
            reviewEnvelope(try terminalData(status: status, errorMessage: nil))
        ) else {
            Issue.record("Expected invalid-terminal-status failure")
            return
        }
        #expect(message?.contains("invalid terminal status \(status)") == true)
    }

    @Test func canonicalPairNeverRebindsToALaterTurn() throws {
        var reducer = makeReducer()
        let foreignMarker = try reviewEnvelope(notificationData(
            method: "item/completed",
            params: #"{"threadId":"thread-review","turnId":"other-turn","item":{"type":"exitedReviewMode","id":"marker","review":"wrong"}}"#
        ))

        #expect(try reducer.ingest(foreignMarker) == .foreignIdentity)
        guard case .accepted(.failed) = try reducer.ingest(
            reviewEnvelope(try turnCompletedData(
                turnFragment: #"{"items":[],"itemsView":"notLoaded"}"#
            ))
        ) else {
            Issue.record("Expected the canonical turn to fail without output")
            return
        }
    }

    @Test func stableLifecycleDuplicateIsNoOpAndConflictFails() throws {
        var reducer = makeReducer()
        let marker = try reviewEnvelope(CurrentV2FixturePin.fullReviewNotifications[0])
        #expect(try reducer.ingest(marker) == .accepted(nil))
        #expect(try reducer.ingest(marker) == .duplicate)

        let conflict = try reviewEnvelope(notificationData(
            method: "item/completed",
            params: #"{"threadId":"thread-review","turnId":"turn-review","item":{"type":"exitedReviewMode","id":"review-result","review":"Different"}}"#
        ))
        #expect(throws: ReviewIngestionError.self) {
            try reducer.ingest(conflict)
        }
    }

    @Test func rawDeltaHasNoReceiptAndIsConsumedEachTime() throws {
        let envelope = try reviewEnvelope(CurrentV2FixturePin.reviewCommandDelta)
        var reducer = makeReducer()

        #expect(envelope.stableReceipt == nil)
        #expect(try reducer.ingest(envelope) == .accepted(nil))
        #expect(try reducer.ingest(envelope) == .accepted(nil))
    }

    @Test func unregisteredStandaloneAndUnrelatedMethodsDoNotEnterTheReviewReducer() throws {
        let standalone = try notification(CurrentV2FixturePin.standaloneCommandDelta)
        let unrelated = JSONRPC.Notification(
            method: "account/updated",
            params: Data(#"{"accountId":"account-1"}"#.utf8)
        )

        guard case .standaloneTraffic = CurrentV2ReviewNotificationDecoder.decode(standalone) else {
            Issue.record("Expected standalone traffic")
            return
        }
        guard case .unrelated = CurrentV2ReviewNotificationDecoder.decode(unrelated) else {
            Issue.record("Expected unrelated traffic")
            return
        }
    }

    @Test func malformedKnownPayloadRetainsItsSelectableAttemptIdentity() throws {
        let malformed = JSONRPC.Notification(
            method: "item/completed",
            params: Data(#"{"threadId":"thread-review","turnId":"turn-review","item":{"type":"exitedReviewMode","review":"missing id"}}"#.utf8)
        )

        guard case .failure(let failure) = CurrentV2ReviewNotificationDecoder.decode(malformed) else {
            Issue.record("Expected a typed decode failure")
            return
        }
        #expect(failure.routedThreadID == "thread-review")
        #expect(failure.routedTurnID == "turn-review")
        guard case .malformedKnownEvent = failure.error else {
            Issue.record("Expected malformed-known-event classification")
            return
        }
    }

    @Test func missingPreRoutingIdentityIsConnectionClassified() throws {
        let malformed = JSONRPC.Notification(
            method: "item/completed",
            params: Data(#"{"turnId":"turn-review","item":{"type":"exitedReviewMode","id":"marker","review":"text"}}"#.utf8)
        )

        guard case .failure(let failure) = CurrentV2ReviewNotificationDecoder.decode(malformed) else {
            Issue.record("Expected a typed decode failure")
            return
        }
        #expect(failure.routedThreadID == nil)
        guard case .missingRoutingIdentity = failure.error else {
            Issue.record("Expected missing-routing-identity classification")
            return
        }
    }

    @Test func replacementUnicodeIsPreservedInTheFinalResult() throws {
        var reducer = makeReducer()
        let terminal = try reviewEnvelope(try terminalData(
            status: "completed",
            items: [[
                "type": "agentMessage",
                "id": "final",
                "text": "invalid: \u{FFFD}",
                "delivery": NSNull(),
            ]],
            itemsView: "summary"
        ))

        guard case .accepted(.completed(let result)) = try reducer.ingest(terminal) else {
            Issue.record("Expected completed result")
            return
        }
        #expect(result.text == "invalid: \u{FFFD}")
    }

    @Test func overLimitFinalOutputFailsInsteadOfTruncating() throws {
        var reducer = makeReducer()
        let oversized = String(repeating: "a", count: ReviewFinalResult.maximumUTF8Bytes + 1)
        let terminal = try reviewEnvelope(try terminalData(
            status: "completed",
            items: [[
                "type": "agentMessage",
                "id": "final",
                "text": oversized,
                "delivery": NSNull(),
            ]],
            itemsView: "summary"
        ))

        guard case .accepted(.failed(let message)) = try reducer.ingest(terminal) else {
            Issue.record("Expected output-too-large failure")
            return
        }
        #expect(message?.contains("UTF-8 bytes") == true)
        #expect(message?.contains("262144") == true)
    }

    private func makeReducer() -> CurrentV2ReviewTerminalReducer {
        CurrentV2ReviewTerminalReducer(identity: .init(
            threadID: "thread-review",
            turnID: "turn-review"
        ))
    }

    private func reviewEnvelope(_ data: Data) throws -> CurrentV2ReviewNotificationEnvelope {
        switch CurrentV2ReviewNotificationDecoder.decode(try notification(data)) {
        case .review(let envelope):
            return envelope
        case .failure(let failure):
            throw failure
        case .globalDiagnostic, .standaloneTraffic, .unrelated:
            throw ContractTestError("Expected a routed review notification")
        }
    }

    private func notification(_ data: Data) throws -> JSONRPC.Notification {
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let method = try #require(object["method"] as? String)
        let params = try #require(object["params"] as? [String: Any])
        return JSONRPC.Notification(
            method: method,
            params: try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])
        )
    }

    private func notificationData(method: String, params: String) -> Data {
        Data("{\"method\":\"\(method)\",\"params\":\(params)}".utf8)
    }

    private func turnCompletedData(turnFragment: String) throws -> Data {
        let fragment = try #require(
            JSONSerialization.jsonObject(with: Data(turnFragment.utf8)) as? [String: Any]
        )
        var turn = fragment
        turn["id"] = "turn-review"
        turn["status"] = "completed"
        turn["error"] = NSNull()
        return try outerNotificationData(method: "turn/completed", params: [
            "threadId": "thread-review",
            "turn": turn,
        ])
    }

    private func terminalData(status: String, errorMessage: String?) throws -> Data {
        try terminalData(
            status: status,
            items: [],
            itemsView: "notLoaded",
            errorMessage: errorMessage
        )
    }

    private func terminalData(
        status: String,
        items: [[String: Any]],
        itemsView: String,
        errorMessage: String? = nil
    ) throws -> Data {
        try outerNotificationData(method: "turn/completed", params: [
            "threadId": "thread-review",
            "turn": [
                "id": "turn-review",
                "items": items,
                "itemsView": itemsView,
                "status": status,
                "error": errorMessage.map { ["message": $0] } ?? NSNull(),
            ] as [String: Any],
        ])
    }

    private func outerNotificationData(
        method: String,
        params: [String: Any]
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "method": method,
            "params": params,
        ], options: [.sortedKeys])
    }

    private struct ContractTestError: LocalizedError {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

@Suite("current-v2 review routing integration")
struct CurrentV2ReviewRoutingIntegrationTests {
    @Test func reviewCommandOutputUsesOnlyCanonicalItemDeltas() async throws {
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let run = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-1",
            threadID: "thread-review",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        )
        let attempt = await backend.reviewAttemptForTesting(run)

        try await transport.emitServerNotification(
            method: "item/started",
            params: V2ItemNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(
                    type: "commandExecution",
                    id: "shared-handle",
                    command: "swift test",
                    aggregatedOutput: nil,
                    exitCode: nil
                )
            )
        )
        for delta in ["begin ", "\u{FFFD}", "\u{FFFD}"] {
            try await transport.emitServerNotification(
                method: "item/commandExecution/outputDelta",
                params: V2DeltaNotification(
                    threadID: "thread-review",
                    turnID: "turn-review",
                    itemID: "shared-handle",
                    delta: delta
                )
            )
        }
        try await transport.emitServerNotification(
            method: "command/exec/outputDelta",
            params: V2StandaloneDeltaNotification(
                processID: "shared-handle",
                deltaBase64: Data("must not appear".utf8).base64EncodedString()
            )
        )
        try await transport.emitServerNotification(
            method: "process/outputDelta",
            params: V2StandaloneDeltaNotification(
                processHandle: "shared-handle",
                deltaBase64: Data("must not appear".utf8).base64EncodedString()
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: V2ItemNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(
                    type: "commandExecution",
                    id: "shared-handle",
                    command: "swift test",
                    aggregatedOutput: "",
                    exitCode: 0
                )
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: V2ItemNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(
                    type: "exitedReviewMode",
                    id: "review-result",
                    review: "No findings."
                )
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: V2TurnNotification(
                threadID: "thread-review",
                turn: .init(
                    id: "turn-review",
                    items: [
                        .init(
                            type: "agentMessage",
                            id: "assistant-final",
                            text: "No findings."
                        ),
                    ],
                    itemsView: "summary",
                    status: "completed"
                )
            )
        )

        let events = try await collectEvents(from: attempt.events)
        let commandOutputTexts = events.compactMap { event -> String? in
            guard case .logEntry(.commandOutput, let text, _, _, _) = event else {
                return nil
            }
            return text
        }
        #expect(commandOutputTexts.contains("begin \u{FFFD}\u{FFFD}"))
        #expect(commandOutputTexts.allSatisfy { $0.contains("must not appear") == false })
        #expect(events.last == .completed(summary: "Succeeded.", result: "No findings."))
        #expect(await backend.notificationRouterMetricsForTesting().standaloneIgnored == 2)
        #expect(await transport.isClosedForTesting() == false)
    }

    @Test func collidingItemStringsStayInsideTheirCanonicalAttempts() async throws {
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let first = await backend.reviewAttemptForTesting(.init(
            attemptID: "attempt-1",
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1"
        ))
        let second = await backend.reviewAttemptForTesting(.init(
            attemptID: "attempt-2",
            threadID: "thread-2",
            turnID: "turn-2",
            reviewThreadID: "thread-2"
        ))

        for (threadID, turnID, output, review) in [
            ("thread-1", "turn-1", "first", "First review"),
            ("thread-2", "turn-2", "second", "Second review"),
        ] {
            try await transport.emitServerNotification(
                method: "item/started",
                params: V2ItemNotification(
                    threadID: threadID,
                    turnID: turnID,
                    item: .init(type: "commandExecution", id: "same-item", command: "echo")
                )
            )
            try await transport.emitServerNotification(
                method: "item/commandExecution/outputDelta",
                params: V2DeltaNotification(
                    threadID: threadID,
                    turnID: turnID,
                    itemID: "same-item",
                    delta: output
                )
            )
            try await transport.emitServerNotification(
                method: "item/completed",
                params: V2ItemNotification(
                    threadID: threadID,
                    turnID: turnID,
                    item: .init(type: "commandExecution", id: "same-item", command: "echo", aggregatedOutput: "")
                )
            )
            try await transport.emitServerNotification(
                method: "item/completed",
                params: V2ItemNotification(
                    threadID: threadID,
                    turnID: turnID,
                    item: .init(type: "exitedReviewMode", id: "result", review: review)
                )
            )
            try await transport.emitServerNotification(
                method: "turn/completed",
                params: V2TurnNotification(
                    threadID: threadID,
                    turn: .init(id: turnID, items: [], itemsView: "notLoaded", status: "completed")
                )
            )
        }

        let firstEvents = try await collectEvents(from: first.events)
        let secondEvents = try await collectEvents(from: second.events)
        #expect(outputTexts(in: firstEvents).contains("first"))
        #expect(outputTexts(in: firstEvents).contains("second") == false)
        #expect(outputTexts(in: secondEvents).contains("second"))
        #expect(outputTexts(in: secondEvents).contains("first") == false)
        #expect(firstEvents.last == .completed(summary: "Succeeded.", result: "First review"))
        #expect(secondEvents.last == .completed(summary: "Succeeded.", result: "Second review"))
    }

    @Test func malformedKnownEventFailsOnlyItsSelectedAttempt() async throws {
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let failedAttempt = await backend.reviewAttemptForTesting(.init(
            attemptID: "attempt-1",
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "thread-1"
        ))
        let healthyAttempt = await backend.reviewAttemptForTesting(.init(
            attemptID: "attempt-2",
            threadID: "thread-2",
            turnID: "turn-2",
            reviewThreadID: "thread-2"
        ))

        try await transport.emitServerNotification(
            method: "item/completed",
            params: MalformedV2ItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "exitedReviewMode", review: "missing item id")
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: V2ItemNotification(
                threadID: "thread-2",
                turnID: "turn-2",
                item: .init(type: "exitedReviewMode", id: "result", review: "Healthy review")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: V2TurnNotification(
                threadID: "thread-2",
                turn: .init(id: "turn-2", items: [], itemsView: "notLoaded", status: "completed")
            )
        )

        #expect(try await failedAttempt.events.next() == .failed(
            "Malformed app-server notification item/completed: id must be a nonempty string"
        ))
        #expect(try await collectEvents(from: healthyAttempt.events).last == .completed(
            summary: "Succeeded.",
            result: "Healthy review"
        ))
        #expect(await backend.notificationRouterMetricsForTesting().attemptFailures == 1)
        #expect(await transport.isClosedForTesting() == false)
    }

    @Test func conflictingActiveRoutingClosesTheConnectionAndFailsAffectedAttempts() async throws {
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let first = await backend.reviewAttemptForTesting(.init(
            attemptID: "attempt-1",
            threadID: "shared-thread",
            turnID: "turn-1",
            reviewThreadID: "shared-thread"
        ))
        let second = await backend.reviewAttemptForTesting(.init(
            attemptID: "attempt-2",
            threadID: "shared-thread",
            turnID: "turn-2",
            reviewThreadID: "shared-thread"
        ))

        try await transport.emitServerNotification(
            method: "item/agentMessage/delta",
            params: V2DeltaNotification(
                threadID: "shared-thread",
                turnID: "turn-1",
                itemID: "message",
                delta: "ambiguous"
            )
        )

        await #expect(throws: BackendReviewEventMailboxError.self) {
            _ = try await first.events.next()
        }
        await #expect(throws: BackendReviewEventMailboxError.self) {
            _ = try await second.events.next()
        }
        #expect(await backend.notificationRouterMetricsForTesting().connectionFailures == 1)
        #expect(await transport.isClosedForTesting())
    }

    @Test func unknownUnrelatedMethodProducesOneDiagnosticAndConnectionContinues() async throws {
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let attempt = await backend.reviewAttemptForTesting(.init(
            attemptID: "attempt-1",
            threadID: "thread-review",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        ))

        try await transport.emitServerNotification(
            method: "account/updated",
            params: ["accountId": "account-1"]
        )
        try await transport.emitServerNotification(
            method: "account/updated",
            params: ["accountId": "account-2"]
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: V2ItemNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(type: "exitedReviewMode", id: "result", review: "No findings.")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: V2TurnNotification(
                threadID: "thread-review",
                turn: .init(id: "turn-review", items: [], itemsView: "notLoaded", status: "completed")
            )
        )

        #expect(try await collectEvents(from: attempt.events).last == .completed(
            summary: "Succeeded.",
            result: "No findings."
        ))
        let metrics = await backend.notificationRouterMetricsForTesting()
        #expect(metrics.diagnostics == 1)
        #expect(metrics.ignored == 2)
        #expect(await transport.isClosedForTesting() == false)
    }

    private func collectEvents(
        from mailbox: BackendReviewEventMailbox
    ) async throws -> [CodexReviewBackendModel.Review.Event] {
        var events: [CodexReviewBackendModel.Review.Event] = []
        while let event = try await mailbox.next() {
            events.append(event)
        }
        return events
    }

    private func outputTexts(
        in events: [CodexReviewBackendModel.Review.Event]
    ) -> [String] {
        events.compactMap { event in
            guard case .logEntry(.commandOutput, let text, _, _, _) = event else {
                return nil
            }
            return text
        }
    }
}

private struct V2DeltaNotification: Encodable, Sendable {
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

private struct V2StandaloneDeltaNotification: Encodable, Sendable {
    var processID: String?
    var processHandle: String?
    var deltaBase64: String

    init(
        processID: String? = nil,
        processHandle: String? = nil,
        deltaBase64: String
    ) {
        self.processID = processID
        self.processHandle = processHandle
        self.deltaBase64 = deltaBase64
    }

    enum CodingKeys: String, CodingKey {
        case processID = "processId"
        case processHandle
        case deltaBase64
    }
}

private struct V2ItemNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var item: V2Item

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case item
    }
}

private struct MalformedV2ItemNotification: Encodable, Sendable {
    struct Item: Encodable, Sendable {
        var type: String
        var review: String
    }

    var threadID: String
    var turnID: String
    var item: Item

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case item
    }
}

private struct V2Item: Encodable, Sendable {
    var type: String
    var id: String
    var text: String?
    var review: String?
    var command: String?
    var cwd: String?
    var status: String?
    var aggregatedOutput: String?
    var exitCode: Int?
    var delivery: String?

    init(
        type: String,
        id: String,
        text: String? = nil,
        review: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        status: String? = nil,
        aggregatedOutput: String? = nil,
        exitCode: Int? = nil,
        delivery: String? = nil
    ) {
        self.type = type
        self.id = id
        self.text = text
        self.review = review
        self.command = command
        self.cwd = cwd
        self.status = status
        self.aggregatedOutput = aggregatedOutput
        self.exitCode = exitCode
        self.delivery = delivery
    }
}

private struct V2TurnNotification: Encodable, Sendable {
    struct Turn: Encodable, Sendable {
        var id: String
        var items: [V2Item]
        var itemsView: String
        var status: String
        var error: ErrorPayload?

        struct ErrorPayload: Encodable, Sendable {
            var message: String
        }
    }

    var threadID: String
    var turn: Turn

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
    }
}
