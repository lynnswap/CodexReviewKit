import Foundation
import Testing
@testable import CodexReviewAppServer

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
