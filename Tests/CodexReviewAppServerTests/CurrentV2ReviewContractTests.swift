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
            "completedAtMs": 1787187601000,
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

    @Test func nonterminalTerminalStatusFailsVisibly() throws {
        var reducer = makeReducer()

        guard case .accepted(.failed(let message)) = try reducer.ingest(
            reviewEnvelope(try terminalData(status: "inProgress", errorMessage: nil))
        ) else {
            Issue.record("Expected invalid-terminal-status failure")
            return
        }
        #expect(message?.contains("invalid terminal status inProgress") == true)
    }

    @Test func unknownTurnStatusIsMalformedAtTheSchemaBoundary() throws {
        let result = CurrentV2ReviewNotificationDecoder.decode(try notification(
            try terminalData(status: "futureStatus", errorMessage: nil)
        ))

        guard case .failure(let failure) = result else {
            Issue.record("Expected a typed decode failure")
            return
        }
        guard case .malformedKnownEvent = failure.error else {
            Issue.record("Expected malformed-known-event classification")
            return
        }
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

    @Test func omittedItemsViewDefaultsToFullWithoutSuppressingHistory() throws {
        var reducer = makeReducer()
        let marker = try reviewEnvelope(CurrentV2FixturePin.fullReviewNotifications[0])
        let terminal = try reviewEnvelope(try outerNotificationData(
            method: "turn/completed",
            params: [
                "threadId": "thread-review",
                "turn": [
                    "id": "turn-review",
                    "items": [[
                        "type": "agentMessage",
                        "id": "historical-message",
                        "text": "Historical message",
                        "delivery": NSNull(),
                    ]],
                    "status": "completed",
                    "error": NSNull(),
                ] as [String: Any],
            ]
        ))

        #expect(try reducer.ingest(marker) == .accepted(nil))
        guard case .accepted(.completed(let final)) = try reducer.ingest(terminal) else {
            Issue.record("Expected a completed terminal")
            return
        }
        #expect(final.source == .exitedReviewMode(itemID: "review-result"))
        #expect(final.suppressedAgentMessageItemIDs.isEmpty)
    }

    @Test(arguments: ["full", "summary"])
    func markerSuppressesOnlyTheSingleSummaryCompanion(_ itemsView: String) throws {
        var reducer = makeReducer()
        let marker = try reviewEnvelope(CurrentV2FixturePin.fullReviewNotifications[0])
        let terminal = try reviewEnvelope(try terminalData(
            status: "completed",
            items: [
                [
                    "type": "agentMessage",
                    "id": "non-final",
                    "text": "Non-final message",
                    "delivery": NSNull(),
                ],
                [
                    "type": "agentMessage",
                    "id": "terminal-companion",
                    "text": "No findings.",
                    "delivery": NSNull(),
                ],
            ],
            itemsView: itemsView
        ))

        #expect(try reducer.ingest(marker) == .accepted(nil))
        guard case .accepted(.completed(let final)) = try reducer.ingest(terminal) else {
            Issue.record("Expected a completed terminal")
            return
        }
        #expect(final.suppressedAgentMessageItemIDs.isEmpty)
    }

    @Test func autoApprovalUsesReviewIdentityForStableReceipts() throws {
        let original = try reviewEnvelope(try autoApprovalData(
            method: "item/autoApprovalReview/started",
            reviewID: "approval-1",
            reviewStatus: "inProgress"
        ))
        let conflict = try reviewEnvelope(try autoApprovalData(
            method: "item/autoApprovalReview/started",
            reviewID: "approval-1",
            reviewStatus: "approved"
        ))
        var reducer = makeReducer()

        #expect(original.stableReceipt?.key.itemID == "approval-1")
        #expect(try reducer.ingest(original) == .accepted(nil))
        #expect(try reducer.ingest(original) == .duplicate)
        #expect(throws: ReviewIngestionError.self) {
            try reducer.ingest(conflict)
        }
    }

    @Test func autoApprovalAcceptsAbsentNullAndStringTargetItemIDs() throws {
        for targetItemID in [nil, NSNull(), "item-1"] as [Any?] {
            var params = try autoApprovalParams(
                reviewID: "approval-1",
                reviewStatus: "inProgress"
            )
            if let targetItemID {
                params["targetItemId"] = targetItemID
            }
            guard case .review = CurrentV2ReviewNotificationDecoder.decode(.init(
                method: "item/autoApprovalReview/started",
                params: try JSONSerialization.data(withJSONObject: params)
            )) else {
                Issue.record("Expected targetItemId variant to remain schema-valid")
                continue
            }
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

    @Test(arguments: ["turn/failed", "turn/cancelled", "agent/message", "log"])
    func retiredNotificationMethodsAreUnrelatedToCurrentV2ReviewReduction(
        _ method: String
    ) {
        let notification = JSONRPC.Notification(
            method: method,
            params: Data(#"{"threadId":"thread-review","turnId":"turn-review","message":"legacy"}"#.utf8)
        )

        guard case .unrelated = CurrentV2ReviewNotificationDecoder.decode(notification) else {
            Issue.record("Expected \(method) to stay outside current-v2 review reduction")
            return
        }
    }

    @Test func currentV2MethodRoutingIdentityMatrixMatchesPinnedSchemas() throws {
        let pair = #"{"threadId":"thread-review","turnId":"turn-review"}"#
        let fixtures: [(method: String, params: String, identity: V2IdentityFixture)] = [
            ("warning", #"{"message":"warning"}"#, .optionalThread),
            ("guardianWarning", #"{"threadId":"thread-review","message":"warning"}"#, .thread),
            ("deprecationNotice", #"{"summary":"deprecated","details":null}"#, .unscoped),
            ("configWarning", #"{"summary":"warning"}"#, .unscoped),
            ("error", #"{"threadId":"thread-review","turnId":"turn-review","error":{"message":"failed"},"willRetry":false}"#, .threadAndTurn),
            ("thread/closed", #"{"threadId":"thread-review"}"#, .thread),
            ("thread/status/changed", #"{"threadId":"thread-review","status":{"type":"systemError"}}"#, .thread),
            ("thread/compacted", pair, .threadAndTurn),
            ("turn/started", #"{"threadId":"thread-review","turn":{"id":"turn-review","items":[],"status":"inProgress","error":null,"startedAt":null,"completedAt":null,"durationMs":null}}"#, .threadAndTurn),
            ("turn/completed", #"{"threadId":"thread-review","turn":{"id":"turn-review","items":[],"itemsView":"notLoaded","status":"failed","error":null}}"#, .threadAndTurn),
            ("turn/diff/updated", #"{"threadId":"thread-review","turnId":"turn-review","diff":"diff"}"#, .threadAndTurn),
            ("turn/plan/updated", #"{"threadId":"thread-review","turnId":"turn-review","plan":[]}"#, .threadAndTurn),
            ("item/started", #"{"threadId":"thread-review","turnId":"turn-review","startedAtMs":1,"item":{"type":"userMessage","id":"item-1","clientId":null,"content":[]}}"#, .threadAndTurn),
            ("item/completed", #"{"threadId":"thread-review","turnId":"turn-review","completedAtMs":2,"item":{"type":"userMessage","id":"item-1","clientId":null,"content":[]}}"#, .threadAndTurn),
            ("item/autoApprovalReview/started", #"{"threadId":"thread-review","turnId":"turn-review","startedAtMs":1,"reviewId":"review-1","targetItemId":null,"review":{"status":"inProgress","riskLevel":null,"userAuthorization":null,"rationale":null},"action":{"type":"applyPatch","cwd":"/tmp","files":[]}}"#, .threadAndTurn),
            ("item/autoApprovalReview/completed", #"{"threadId":"thread-review","turnId":"turn-review","startedAtMs":1,"completedAtMs":2,"reviewId":"review-1","targetItemId":null,"decisionSource":"agent","review":{"status":"approved","riskLevel":null,"userAuthorization":null,"rationale":null},"action":{"type":"applyPatch","cwd":"/tmp","files":[]}}"#, .threadAndTurn),
            ("item/agentMessage/delta", #"{"threadId":"thread-review","turnId":"turn-review","itemId":"item-1","delta":"text"}"#, .threadAndTurn),
            ("item/plan/delta", #"{"threadId":"thread-review","turnId":"turn-review","itemId":"item-1","delta":"text"}"#, .threadAndTurn),
            ("item/reasoning/summaryTextDelta", #"{"threadId":"thread-review","turnId":"turn-review","itemId":"item-1","delta":"text","summaryIndex":0}"#, .threadAndTurn),
            ("item/reasoning/summaryPartAdded", #"{"threadId":"thread-review","turnId":"turn-review","itemId":"item-1","summaryIndex":0}"#, .threadAndTurn),
            ("item/reasoning/textDelta", #"{"threadId":"thread-review","turnId":"turn-review","itemId":"item-1","delta":"text","contentIndex":0}"#, .threadAndTurn),
            ("item/commandExecution/outputDelta", #"{"threadId":"thread-review","turnId":"turn-review","itemId":"item-1","delta":"text"}"#, .threadAndTurn),
            ("item/commandExecution/terminalInteraction", #"{"threadId":"thread-review","turnId":"turn-review","itemId":"item-1","processId":"process-1","stdin":"input"}"#, .threadAndTurn),
            ("item/fileChange/outputDelta", #"{"threadId":"thread-review","turnId":"turn-review","itemId":"item-1","delta":"text"}"#, .threadAndTurn),
            ("item/fileChange/patchUpdated", #"{"threadId":"thread-review","turnId":"turn-review","itemId":"item-1","changes":[]}"#, .threadAndTurn),
            ("item/mcpToolCall/progress", #"{"threadId":"thread-review","turnId":"turn-review","itemId":"item-1","message":"progress"}"#, .threadAndTurn),
            ("model/rerouted", #"{"threadId":"thread-review","turnId":"turn-review","fromModel":"a","toModel":"b","reason":"highRiskCyberActivity"}"#, .threadAndTurn),
            ("model/verification", #"{"threadId":"thread-review","turnId":"turn-review","verifications":[]}"#, .threadAndTurn),
        ]

        for fixture in fixtures {
            let params = try #require(
                JSONSerialization.jsonObject(with: Data(fixture.params.utf8))
                    as? [String: Any]
            )
            let valid = CurrentV2ReviewNotificationDecoder.decode(.init(
                method: fixture.method,
                params: try JSONSerialization.data(withJSONObject: params)
            ))
            switch fixture.identity {
            case .unscoped, .optionalThread:
                guard case .globalDiagnostic = valid else {
                    Issue.record("Expected global routing for \(fixture.method)")
                    continue
                }
            case .thread, .threadAndTurn:
                guard case .review = valid else {
                    Issue.record("Expected review routing for \(fixture.method)")
                    continue
                }
            }

            if fixture.identity == .optionalThread {
                var scoped = params
                scoped["threadId"] = "thread-review"
                guard case .review = CurrentV2ReviewNotificationDecoder.decode(.init(
                    method: fixture.method,
                    params: try JSONSerialization.data(withJSONObject: scoped)
                )) else {
                    Issue.record("Expected optional-thread routing for \(fixture.method)")
                    continue
                }
            }

            guard fixture.identity == .thread || fixture.identity == .threadAndTurn else {
                continue
            }
            var missingThread = params
            missingThread.removeValue(forKey: "threadId")
            try expectConnectionIdentityFailure(
                method: fixture.method,
                params: missingThread
            )

            guard fixture.identity == .threadAndTurn else {
                continue
            }
            var missingTurn = params
            if fixture.method == "turn/started" || fixture.method == "turn/completed" {
                var turn = try #require(missingTurn["turn"] as? [String: Any])
                turn.removeValue(forKey: "id")
                missingTurn["turn"] = turn
            } else {
                missingTurn.removeValue(forKey: "turnId")
            }
            try expectConnectionIdentityFailure(
                method: fixture.method,
                params: missingTurn
            )
        }
    }

    @Test func currentV2ThreadItemClosedUnionMatchesPinnedSchemas() throws {
        let items = [
            #"{"type":"userMessage","id":"item-1","content":[]}"#,
            #"{"type":"hookPrompt","id":"item-1","fragments":[]}"#,
            #"{"type":"agentMessage","id":"item-1","text":"","delivery":null}"#,
            #"{"type":"plan","id":"item-1","text":""}"#,
            #"{"type":"reasoning","id":"item-1","summary":[],"content":[]}"#,
            #"{"type":"commandExecution","id":"item-1","command":"","commandActions":[],"cwd":"","source":"agent","status":"completed"}"#,
            #"{"type":"fileChange","id":"item-1","changes":[],"status":"completed"}"#,
            #"{"type":"mcpToolCall","id":"item-1","arguments":null,"server":"","status":"completed","tool":""}"#,
            #"{"type":"dynamicToolCall","id":"item-1","arguments":{},"status":"completed","tool":""}"#,
            #"{"type":"collabAgentToolCall","id":"item-1","agentsStates":{},"receiverThreadIds":[],"senderThreadId":"","status":"completed","tool":"wait"}"#,
            #"{"type":"subAgentActivity","id":"item-1","agentPath":"worker","agentThreadId":"thread-worker","kind":"interacted"}"#,
            #"{"type":"webSearch","id":"item-1","query":""}"#,
            #"{"type":"imageView","id":"item-1","path":""}"#,
            #"{"type":"sleep","id":"item-1","durationMs":0}"#,
            #"{"type":"imageGeneration","id":"item-1","result":"","status":"completed"}"#,
            #"{"type":"enteredReviewMode","id":"item-1","review":""}"#,
            #"{"type":"exitedReviewMode","id":"item-1","review":""}"#,
            #"{"type":"contextCompaction","id":"item-1"}"#,
        ]

        for item in items {
            let params = Data(#"{"threadId":"thread-review","turnId":"turn-review","completedAtMs":2,"item":\#(item)}"#.utf8)
            guard case .review = CurrentV2ReviewNotificationDecoder.decode(.init(
                method: "item/completed",
                params: params
            )) else {
                Issue.record("Expected schema-valid ThreadItem: \(item)")
                continue
            }
        }
    }

    @Test func currentV2ThreadItemRequiredFieldsAndEnumsRejectMalformedPayloads() {
        let malformedItems = [
            #"{"type":"userMessage","id":"item-1"}"#,
            #"{"type":"hookPrompt","id":"item-1"}"#,
            #"{"type":"agentMessage","id":"item-1"}"#,
            #"{"type":"plan","id":"item-1"}"#,
            #"{"type":"commandExecution","id":"item-1","command":"","commandActions":[],"status":"completed"}"#,
            #"{"type":"commandExecution","id":"item-1","command":"","commandActions":[],"cwd":"","status":"future"}"#,
            #"{"type":"fileChange","id":"item-1","status":"completed"}"#,
            #"{"type":"mcpToolCall","id":"item-1","server":"","status":"completed","tool":""}"#,
            #"{"type":"dynamicToolCall","id":"item-1","arguments":{},"status":"future","tool":""}"#,
            #"{"type":"collabAgentToolCall","id":"item-1","agentsStates":{},"receiverThreadIds":[],"senderThreadId":"","status":"completed","tool":"future"}"#,
            #"{"type":"subAgentActivity","id":"item-1","agentPath":"worker","agentThreadId":"thread-worker","kind":"future"}"#,
            #"{"type":"webSearch","id":"item-1"}"#,
            #"{"type":"imageView","id":"item-1"}"#,
            #"{"type":"sleep","id":"item-1"}"#,
            #"{"type":"imageGeneration","id":"item-1","status":"completed"}"#,
            #"{"type":"exitedReviewMode","id":"item-1"}"#,
        ]

        for item in malformedItems {
            let params = Data(#"{"threadId":"thread-review","turnId":"turn-review","completedAtMs":2,"item":\#(item)}"#.utf8)
            guard case .failure(let failure) = CurrentV2ReviewNotificationDecoder.decode(.init(
                method: "item/completed",
                params: params
            )) else {
                Issue.record("Expected malformed ThreadItem rejection: \(item)")
                continue
            }
            #expect(failure.routedThreadID == "thread-review")
            #expect(failure.routedTurnID == "turn-review")
        }
    }

    @Test func currentV2RequiredPayloadMatrixRejectsMissingOrInvalidFields() {
        let pair = #"{"threadId":"thread-review","turnId":"turn-review"}"#
        let malformed: [(String, String)] = [
            ("warning", #"{}"#),
            ("guardianWarning", #"{"threadId":"thread-review"}"#),
            ("deprecationNotice", #"{}"#),
            ("configWarning", #"{}"#),
            ("error", #"{"threadId":"thread-review","turnId":"turn-review","error":{"message":"failed"}}"#),
            ("thread/status/changed", #"{"threadId":"thread-review","status":{}}"#),
            ("turn/started", #"{"threadId":"thread-review","turn":{"id":"turn-review","items":[]}}"#),
            ("turn/completed", #"{"threadId":"thread-review","turn":{"id":"turn-review","status":"completed"}}"#),
            ("turn/diff/updated", pair),
            ("turn/plan/updated", #"{"threadId":"thread-review","turnId":"turn-review","plan":[{"step":"inspect"}]}"#),
            ("item/started", #"{"threadId":"thread-review","turnId":"turn-review","item":{"type":"contextCompaction","id":"item-1"}}"#),
            ("item/completed", #"{"threadId":"thread-review","turnId":"turn-review","item":{"type":"contextCompaction","id":"item-1"}}"#),
            ("item/autoApprovalReview/started", #"{"threadId":"thread-review","turnId":"turn-review","startedAtMs":1,"review":{"status":"inProgress"},"action":{"type":"applyPatch","cwd":"/tmp","files":[]}}"#),
            ("item/autoApprovalReview/completed", #"{"threadId":"thread-review","turnId":"turn-review","startedAtMs":1,"completedAtMs":2,"reviewId":"review-1","decisionSource":"future","review":{"status":"approved"},"action":{"type":"applyPatch","cwd":"/tmp","files":[]}}"#),
            ("item/agentMessage/delta", #"{"threadId":"thread-review","turnId":"turn-review","delta":"text"}"#),
            ("item/plan/delta", #"{"threadId":"thread-review","turnId":"turn-review","delta":"text"}"#),
            ("item/reasoning/summaryTextDelta", #"{"threadId":"thread-review","turnId":"turn-review","itemId":"item-1","delta":"text"}"#),
            ("item/reasoning/summaryPartAdded", #"{"threadId":"thread-review","turnId":"turn-review","itemId":"item-1"}"#),
            ("item/reasoning/textDelta", #"{"threadId":"thread-review","turnId":"turn-review","itemId":"item-1","delta":"text"}"#),
            ("item/commandExecution/outputDelta", #"{"threadId":"thread-review","turnId":"turn-review","delta":"text"}"#),
            ("item/commandExecution/terminalInteraction", #"{"threadId":"thread-review","turnId":"turn-review","itemId":"item-1","stdin":"input"}"#),
            ("item/fileChange/outputDelta", #"{"threadId":"thread-review","turnId":"turn-review","delta":"text"}"#),
            ("item/fileChange/patchUpdated", #"{"threadId":"thread-review","turnId":"turn-review","itemId":"item-1"}"#),
            ("item/mcpToolCall/progress", #"{"threadId":"thread-review","turnId":"turn-review","itemId":"item-1"}"#),
            ("model/rerouted", #"{"threadId":"thread-review","turnId":"turn-review","fromModel":"a","toModel":"b","reason":"future"}"#),
            ("model/verification", #"{"threadId":"thread-review","turnId":"turn-review","verifications":["future"]}"#),
        ]

        for (method, params) in malformed {
            guard case .failure(let failure) = CurrentV2ReviewNotificationDecoder.decode(.init(
                method: method,
                params: Data(params.utf8)
            )) else {
                Issue.record("Expected required payload rejection for \(method)")
                continue
            }
            guard case .malformedKnownEvent = failure.error else {
                Issue.record("Expected malformed-known-event classification for \(method)")
                continue
            }
        }
    }

    @Test func malformedKnownPayloadRetainsItsSelectableAttemptIdentity() throws {
        let malformed = JSONRPC.Notification(
            method: "item/completed",
            params: Data(#"{"threadId":"thread-review","turnId":"turn-review","completedAtMs":2,"item":{"type":"exitedReviewMode","review":"missing id"}}"#.utf8)
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

    @Test func unsupportedClosedUnionItemIsAttemptClassified() throws {
        let unsupported = JSONRPC.Notification(
            method: "item/completed",
            params: Data(#"{"threadId":"thread-review","turnId":"turn-review","completedAtMs":2,"item":{"type":"futureItem","id":"item-1"}}"#.utf8)
        )

        guard case .failure(let failure) = CurrentV2ReviewNotificationDecoder.decode(unsupported) else {
            Issue.record("Expected a typed unsupported-item failure")
            return
        }
        #expect(failure.routedThreadID == "thread-review")
        #expect(failure.routedTurnID == "turn-review")
        #expect(failure.error == .unsupportedItemType(
            method: "item/completed",
            type: "futureItem"
        ))
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

    private func expectConnectionIdentityFailure(
        method: String,
        params: [String: Any]
    ) throws {
        let result = CurrentV2ReviewNotificationDecoder.decode(.init(
            method: method,
            params: try JSONSerialization.data(withJSONObject: params)
        ))
        guard case .failure(let failure) = result else {
            Issue.record("Expected missing routing identity for \(method)")
            return
        }
        #expect(failure.error == .missingRoutingIdentity(method: method))
        #expect(failure.requiresConnectionContainment)
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

    private func notificationData(method: String, params: String) throws -> Data {
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(params.utf8)) as? [String: Any]
        )
        if method == "item/started" {
            object["startedAtMs"] = 1
        } else if method == "item/completed" {
            object["completedAtMs"] = 2
        }
        return try outerNotificationData(method: method, params: object)
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

    private func autoApprovalData(
        method: String,
        reviewID: String,
        reviewStatus: String
    ) throws -> Data {
        var params = try autoApprovalParams(
            reviewID: reviewID,
            reviewStatus: reviewStatus
        )
        if method == "item/autoApprovalReview/completed" {
            params["completedAtMs"] = 2
            params["decisionSource"] = "agent"
        }
        return try outerNotificationData(method: method, params: params)
    }

    private func autoApprovalParams(
        reviewID: String,
        reviewStatus: String
    ) throws -> [String: Any] {
        [
            "threadId": "thread-review",
            "turnId": "turn-review",
            "startedAtMs": 1,
            "reviewId": reviewID,
            "review": ["status": reviewStatus],
            "action": [
                "type": "applyPatch",
                "cwd": "/tmp",
                "files": [],
            ] as [String: Any],
        ]
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

private enum V2IdentityFixture: Equatable {
    case unscoped
    case optionalThread
    case thread
    case threadAndTurn
}

@Suite("current-v2 review routing integration")
struct CurrentV2ReviewRoutingIntegrationTests {
    @Test func canonicalStartIsEmittedOnlyOnceAcrossNonterminalEvents() async throws {
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let attempt = await backend.reviewAttemptForTesting(.init(
            attemptID: "attempt-1",
            threadID: "thread-review",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        ))

        try await transport.emitServerNotification(
            method: "turn/started",
            params: V2TurnNotification(
                threadID: "thread-review",
                turn: .init(
                    id: "turn-review",
                    items: [],
                    itemsView: "full",
                    status: "inProgress",
                    error: nil
                )
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: V2ItemNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(type: "agentMessage", id: "message-1", text: "Progress")
            )
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
                turn: .init(
                    id: "turn-review",
                    items: [
                        .init(type: "agentMessage", id: "message-1", text: "Progress"),
                    ],
                    itemsView: "summary",
                    status: "completed",
                    error: nil
                )
            )
        )

        let events = try await collectEvents(from: attempt.events)
        let startCount = events.reduce(into: 0) { count, event in
            if case .started = event {
                count += 1
            }
        }
        #expect(startCount == 1)
        #expect(events.last == .completed(summary: "Succeeded.", result: "No findings."))
    }

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

        await #expect(throws: ReviewAttemptStreamFailure.protocolViolation(.init(
            message: "Malformed app-server notification item/completed: id must be a nonempty string"
        ))) {
            _ = try await failedAttempt.events.next()
        }
        #expect(try await collectEvents(from: healthyAttempt.events).last == .completed(
            summary: "Succeeded.",
            result: "Healthy review"
        ))
        #expect(await backend.notificationRouterMetricsForTesting().attemptFailures == 1)
        #expect(await transport.isClosedForTesting() == false)
    }

    @Test func unsupportedItemFailsOnlyItsSelectedAttempt() async throws {
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
            params: V2ItemNotification(
                threadID: "thread-1",
                turnID: "turn-1",
                item: .init(type: "futureItem", id: "item-1")
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

        await #expect(throws: ReviewAttemptStreamFailure.protocolViolation(.init(
            message: "Unsupported app-server item type futureItem in item/completed."
        ))) {
            _ = try await failedAttempt.events.next()
        }
        #expect(try await collectEvents(from: healthyAttempt.events).last == .completed(
            summary: "Succeeded.",
            result: "Healthy review"
        ))
        #expect(await backend.notificationRouterMetricsForTesting().attemptFailures == 1)
        #expect(await transport.isClosedForTesting() == false)
    }

    @Test func unscopedOptionalThreadWarningLogsAndConnectionContinues() async throws {
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let attempt = await backend.reviewAttemptForTesting(.init(
            attemptID: "attempt-1",
            threadID: "thread-review",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        ))

        try await transport.emitServerNotification(
            method: "warning",
            params: V2WarningNotification(message: "Connection warning")
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

        #expect(try await collectEvents(from: attempt.events) == [
            .logEntry(
                kind: .diagnostic,
                text: "Connection warning",
                groupID: nil,
                replacesGroup: false
            ),
            .started(
                turnID: "turn-review",
                reviewThreadID: "thread-review",
                model: nil
            ),
            .logEntry(
                kind: .agentMessage,
                text: "No findings.",
                groupID: "result",
                replacesGroup: true,
                metadata: .init(sourceType: "exitedReviewMode")
            ),
            .completed(summary: "Succeeded.", result: "No findings."),
        ])
        #expect(await transport.isClosedForTesting() == false)
    }

    @Test func malformedUnscopedDiagnosticIsBoundedAndConnectionContinues() async throws {
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let attempt = await backend.reviewAttemptForTesting(.init(
            attemptID: "attempt-1",
            threadID: "thread-review",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        ))

        try await transport.emitServerNotification(
            method: "configWarning",
            params: V2WarningNotification(message: "wrong field for configWarning")
        )
        try await emitCompletedReview(
            transport: transport,
            review: "No findings."
        )

        #expect(try await collectEvents(from: attempt.events).last == .completed(
            summary: "Succeeded.",
            result: "No findings."
        ))
        #expect(await backend.notificationRouterMetricsForTesting().ignored == 1)
        #expect(await transport.isClosedForTesting() == false)
    }

    @Test func subAgentActivityAndSleepAreValidCurrentV2LifecycleItems() async throws {
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let attempt = await backend.reviewAttemptForTesting(.init(
            attemptID: "attempt-1",
            threadID: "thread-review",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        ))

        try await transport.emitServerNotification(
            method: "item/started",
            params: V2ItemNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(
                    type: "subAgentActivity",
                    id: "subagent-1",
                    activityKind: "started",
                    agentThreadID: "thread-worker",
                    agentPath: "workers/reviewer"
                )
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: V2ItemNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(
                    type: "subAgentActivity",
                    id: "subagent-1",
                    activityKind: "interacted",
                    agentThreadID: "thread-worker",
                    agentPath: "workers/reviewer"
                )
            )
        )
        try await transport.emitServerNotification(
            method: "item/started",
            params: V2ItemNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(type: "sleep", id: "sleep-1", durationMs: 250)
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: V2ItemNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(type: "sleep", id: "sleep-1", durationMs: 250)
            )
        )
        try await emitCompletedReview(transport: transport, review: "No findings.")

        let events = try await collectEvents(from: attempt.events)
        #expect(events.contains(.logEntry(
            kind: .event,
            text: "Subagent workers/reviewer: started.",
            groupID: "subagent-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "subAgentActivity",
                status: "started",
                detail: "thread-worker"
            )
        )))
        #expect(events.contains(.logEntry(
            kind: .event,
            text: "Subagent workers/reviewer: interacted.",
            groupID: "subagent-1",
            replacesGroup: true,
            metadata: .init(
                sourceType: "subAgentActivity",
                status: "interacted",
                detail: "thread-worker"
            )
        )))
        #expect(events.contains(.logEntry(
            kind: .event,
            text: "Sleeping for 250 ms.",
            groupID: "sleep-1",
            replacesGroup: true,
            metadata: .init(sourceType: "sleep", status: "inProgress", durationMs: 250)
        )))
        #expect(events.contains(.logEntry(
            kind: .event,
            text: "Slept for 250 ms.",
            groupID: "sleep-1",
            replacesGroup: true,
            metadata: .init(sourceType: "sleep", status: "completed", durationMs: 250)
        )))
        #expect(events.last == .completed(summary: "Succeeded.", result: "No findings."))
    }

    @Test func rawUserMessageContentDecodesAtTheBackendBoundary() async throws {
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let attempt = await backend.reviewAttemptForTesting(.init(
            attemptID: "attempt-1",
            threadID: "thread-review",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        ))

        try await transport.emitServerNotification(
            method: "item/completed",
            params: V2UserMessageNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                completedAtMs: 2,
                item: .init(
                    type: "userMessage",
                    id: "user-1",
                    content: [.init(
                        type: "text",
                        text: "Please review this change",
                        textElements: []
                    )]
                )
            )
        )
        try await emitCompletedReview(transport: transport, review: "No findings.")

        #expect(try await collectEvents(from: attempt.events).last == .completed(
            summary: "Succeeded.",
            result: "No findings."
        ))
        #expect(await backend.notificationRouterMetricsForTesting().attemptFailures == 0)
    }

    @Test func threadLifecycleNotificationsCannotCommitAheadOfTurnCompleted() async throws {
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let attempt = await backend.reviewAttemptForTesting(.init(
            attemptID: "attempt-1",
            threadID: "thread-review",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        ))

        try await transport.emitServerNotification(
            method: "thread/status/changed",
            params: V2ThreadStatusNotification(
                threadID: "thread-review",
                status: .init(type: "notLoaded")
            )
        )
        try await transport.emitServerNotification(
            method: "thread/closed",
            params: V2ThreadClosedNotification(threadID: "thread-review")
        )
        try await emitCompletedReview(transport: transport, review: "Completed review")

        let events = try await collectEvents(from: attempt.events)
        #expect(events.prefix(2) == [
            .logEntry(
                kind: .diagnostic,
                text: "Review thread is no longer loaded.",
                groupID: "thread-review",
                replacesGroup: false
            ),
            .logEntry(
                kind: .diagnostic,
                text: "Review thread closed.",
                groupID: "thread-review",
                replacesGroup: false
            ),
        ])
        #expect(events.last == .completed(summary: "Succeeded.", result: "Completed review"))
    }

    @Test func emptyDiffAndPlanReplaceTheirPriorProjection() async throws {
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let attempt = await backend.reviewAttemptForTesting(.init(
            attemptID: "attempt-1",
            threadID: "thread-review",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        ))

        try await transport.emitServerNotification(
            method: "turn/diff/updated",
            params: V2DiffNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                diff: "diff --git"
            )
        )
        try await transport.emitServerNotification(
            method: "turn/diff/updated",
            params: V2DiffNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                diff: ""
            )
        )
        try await transport.emitServerNotification(
            method: "turn/plan/updated",
            params: V2PlanNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                plan: [.init(step: "Inspect", status: "inProgress")]
            )
        )
        try await transport.emitServerNotification(
            method: "turn/plan/updated",
            params: V2PlanNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                plan: []
            )
        )
        try await emitCompletedReview(transport: transport, review: "No findings.")

        let events = try await collectEvents(from: attempt.events)
        let replacements = events.compactMap { event -> (ReviewLogEntry.Kind, String, String?, Bool)? in
            guard case .logEntry(let kind, let text, let groupID, let replacesGroup, _) = event,
                  kind == .event || kind == .todoList else {
                return nil
            }
            return (kind, text, groupID, replacesGroup)
        }
        #expect(replacements.map(\.0) == [.event, .event, .todoList, .todoList])
        #expect(replacements.map(\.1) == ["diff --git", "", "[inProgress] Inspect", ""])
        #expect(replacements.allSatisfy { $0.2 == "turn-review" && $0.3 })
    }

    @Test func scalarKnownNotificationParamsCloseTheUnroutableConnection() async throws {
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let attempt = await backend.reviewAttemptForTesting(.init(
            attemptID: "attempt-1",
            threadID: "thread-review",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        ))

        try await transport.emitServerNotification(method: "item/completed", params: 1)

        await expectProtocolViolation(from: attempt.events)
        #expect(await backend.notificationRouterMetricsForTesting().connectionFailures == 1)
        #expect(await transport.isClosedForTesting())
    }

    @Test func missingGuardianWarningThreadClosesConnectionWithoutReviewMutation() async throws {
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let attempt = await backend.reviewAttemptForTesting(.init(
            attemptID: "attempt-1",
            threadID: "thread-review",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        ))

        try await transport.emitServerNotification(
            method: "guardianWarning",
            params: V2WarningNotification(message: "Guardian warning")
        )

        await expectProtocolViolation(from: attempt.events)
        #expect(await backend.notificationRouterMetricsForTesting().connectionFailures == 1)
        #expect(await transport.isClosedForTesting())
    }

    @Test func missingContextCompactedTurnClosesConnectionWithoutReviewMutation() async throws {
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let attempt = await backend.reviewAttemptForTesting(.init(
            attemptID: "attempt-1",
            threadID: "thread-review",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        ))

        try await transport.emitServerNotification(
            method: "thread/compacted",
            params: V2ContextCompactedNotification(threadID: "thread-review")
        )

        await expectProtocolViolation(from: attempt.events)
        #expect(await backend.notificationRouterMetricsForTesting().connectionFailures == 1)
        #expect(await transport.isClosedForTesting())
    }

    @MainActor
    @Test func rawFullDeliveryCommitsOneCanonicalFinalRowEndToEnd() async throws {
        let transport = FakeJSONRPCTransport()
        let backend = AppServerCodexReviewBackend(client: .init(transport: transport))
        let attempt = await backend.reviewAttemptForTesting(.init(
            attemptID: "attempt-1",
            threadID: "thread-review",
            turnID: "turn-review",
            reviewThreadID: "thread-review"
        ))

        try await transport.emitServerNotification(
            method: "item/started",
            params: V2ItemNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(type: "agentMessage", id: "non-final", text: "")
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: V2ItemNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(type: "agentMessage", id: "non-final", text: "Non-final message")
            )
        )
        try await transport.emitServerNotification(
            method: "item/started",
            params: V2ItemNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(type: "agentMessage", id: "final", text: "Partial final")
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: V2ItemNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(type: "agentMessage", id: "final", text: "Complete final")
            )
        )
        try await transport.emitServerNotification(
            method: "item/completed",
            params: V2ItemNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(type: "exitedReviewMode", id: "review-result", review: "Canonical review")
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: V2TurnNotification(
                threadID: "thread-review",
                turn: .init(
                    id: "turn-review",
                    items: [.init(type: "agentMessage", id: "final", text: "Complete final")],
                    itemsView: "summary",
                    status: "completed"
                )
            )
        )
        let normalizedEvents = try await collectEvents(from: attempt.events)
        #expect(normalizedEvents.contains { event in
            guard case .logEntry(let kind, _, let groupID, let replacesGroup, let metadata) = event else {
                return false
            }
            return kind == .agentMessage
                && groupID == "review-result"
                && replacesGroup
                && metadata?.sourceType == "exitedReviewMode"
        })

        let storeReviewBackend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: storeReviewBackend),
            idGenerator: .init(next: { "job-1" })
        )
        async let started = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await storeReviewBackend.waitForStartReview()
        for event in normalizedEvents {
            await storeReviewBackend.yield(event)
        }
        let result = try await started

        let visibleAgentRows = result.logs.filter { $0.kind == .agentMessage }
        #expect(visibleAgentRows.map(\.groupID) == ["non-final", "review-result"])
        #expect(visibleAgentRows.map(\.text) == ["Non-final message", "Canonical review"])
        #expect(visibleAgentRows.contains { $0.groupID == "final" } == false)
        #expect(result.core.lifecycle.terminal == .completed)
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

        await expectProtocolViolation(from: first.events)
        await expectProtocolViolation(from: second.events)
        #expect(await backend.notificationRouterMetricsForTesting().connectionFailures == 1)
        #expect(await transport.isClosedForTesting())
    }

    @Test func retiredAndUnknownMethodsCannotBypassReducerTerminal() async throws {
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
        for method in ["turn/failed", "turn/cancelled", "agent/message", "log"] {
            try await transport.emitServerNotification(
                method: method,
                params: [
                    "threadId": "thread-review",
                    "turnId": "turn-review",
                    "message": "legacy terminal bypass",
                ]
            )
        }
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

        #expect(try await collectEvents(from: attempt.events) == [
            .started(
                turnID: "turn-review",
                reviewThreadID: "thread-review",
                model: nil
            ),
            .logEntry(
                kind: .agentMessage,
                text: "No findings.",
                groupID: "result",
                replacesGroup: true,
                metadata: .init(sourceType: "exitedReviewMode")
            ),
            .completed(summary: "Succeeded.", result: "No findings."),
        ])
        let metrics = await backend.notificationRouterMetricsForTesting()
        #expect(metrics.diagnostics == 5)
        #expect(metrics.ignored == 6)
        #expect(await transport.isClosedForTesting() == false)
    }

    private func emitCompletedReview(
        transport: FakeJSONRPCTransport,
        review: String
    ) async throws {
        try await transport.emitServerNotification(
            method: "item/completed",
            params: V2ItemNotification(
                threadID: "thread-review",
                turnID: "turn-review",
                item: .init(type: "exitedReviewMode", id: "result", review: review)
            )
        )
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: V2TurnNotification(
                threadID: "thread-review",
                turn: .init(
                    id: "turn-review",
                    items: [],
                    itemsView: "notLoaded",
                    status: "completed"
                )
            )
        )
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

    private func expectProtocolViolation(
        from mailbox: BackendReviewEventMailbox
    ) async {
        do {
            _ = try await mailbox.next()
            Issue.record("Expected a typed protocol violation.")
        } catch let failure as ReviewAttemptStreamFailure {
            guard case .protocolViolation = failure else {
                Issue.record("Expected protocolViolation, received \(failure).")
                return
            }
        } catch {
            Issue.record("Expected ReviewAttemptStreamFailure, received \(error).")
        }
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

private struct V2WarningNotification: Encodable, Sendable {
    var threadID: String?
    var message: String

    init(threadID: String? = nil, message: String) {
        self.threadID = threadID
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case message
    }
}

private struct V2ThreadStatusNotification: Encodable, Sendable {
    struct Status: Encodable, Sendable {
        var type: String
    }

    var threadID: String
    var status: Status

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case status
    }
}

private struct V2ThreadClosedNotification: Encodable, Sendable {
    var threadID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

private struct V2DiffNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var diff: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case diff
    }
}

private struct V2PlanNotification: Encodable, Sendable {
    struct Step: Encodable, Sendable {
        var step: String
        var status: String
    }

    var threadID: String
    var turnID: String
    var plan: [Step]

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case plan
    }
}

private struct V2UserMessageNotification: Encodable, Sendable {
    struct Item: Encodable, Sendable {
        struct Content: Encodable, Sendable {
            var type: String
            var text: String
            var textElements: [String]

            enum CodingKeys: String, CodingKey {
                case type
                case text
                case textElements = "text_elements"
            }
        }

        var type: String
        var id: String
        var content: [Content]
    }

    var threadID: String
    var turnID: String
    var completedAtMs: Int64
    var item: Item

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case completedAtMs
        case item
    }
}

private struct V2ContextCompactedNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String?

    init(threadID: String, turnID: String? = nil) {
        self.threadID = threadID
        self.turnID = turnID
    }

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
    }
}

private struct V2ItemNotification: Encodable, Sendable {
    var threadID: String
    var turnID: String
    var item: V2Item
    var startedAtMs: Int64 = 1
    var completedAtMs: Int64 = 2

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case item
        case startedAtMs
        case completedAtMs
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
    var completedAtMs: Int64 = 2

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case item
        case completedAtMs
    }
}

private struct V2Item: Encodable, Sendable {
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
    var delivery: String?
    var activityKind: String?
    var agentThreadID: String?
    var agentPath: String?
    var durationMs: Int?

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
        delivery: String? = nil,
        activityKind: String? = nil,
        agentThreadID: String? = nil,
        agentPath: String? = nil,
        durationMs: Int? = nil
    ) {
        self.type = type
        self.id = id
        self.text = text
        self.review = review
        self.command = command
        self.cwd = cwd ?? (type == "commandExecution" ? "/tmp" : nil)
        self.source = type == "commandExecution" ? "agent" : nil
        self.status = status ?? (type == "commandExecution" ? "completed" : nil)
        self.commandActions = type == "commandExecution" ? [] : nil
        self.aggregatedOutput = aggregatedOutput
        self.exitCode = exitCode
        self.delivery = delivery
        self.activityKind = activityKind
        self.agentThreadID = agentThreadID
        self.agentPath = agentPath
        self.durationMs = durationMs
    }

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case text
        case review
        case command
        case cwd
        case source
        case status
        case commandActions
        case aggregatedOutput
        case exitCode
        case delivery
        case activityKind = "kind"
        case agentThreadID = "agentThreadId"
        case agentPath
        case durationMs
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
