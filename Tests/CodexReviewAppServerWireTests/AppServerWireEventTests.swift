import Foundation
import Testing
@testable import CodexReviewAppServerWire
import CodexReviewDomain

@Suite("app-server wire events")
struct AppServerWireEventTests {
    @Test func preservesUnknownNotificationRawPayloadAndEmitsUnknownContent() throws {
        let notification = try decodeNotification("""
        {
          "method": "future/event",
          "params": {
            "turnId": "turn-1",
            "itemId": "future-1",
            "nested": {
              "answer": 42
            },
            "items": [true, "raw"]
          }
        }
        """)

        #expect(notification.rawMethod == "future/event")
        #expect(notification.method.rawValue == "future/event")
        #expect(notification.rawPayload?.objectValue?["nested"] == .object(["answer": .int(42)]))
        #expect(notification.payload.rawFields["items"] == .array([.bool(true), .string("raw")]))

        let events = notification.domainEvents()
        guard case .itemUpdated(let seed) = try #require(events.first) else {
            Issue.record("expected unknown item update")
            return
        }
        #expect(seed.id.rawValue == "future-1")
        #expect(seed.kind.rawValue == "future/event")
        #expect(seed.family == .unknown)
        if case .unknown(let unknown) = seed.content {
            #expect(unknown.title == "future/event")
            #expect(unknown.detail?.contains("\"answer\":42") == true)
        } else {
            Issue.record("expected unknown content")
        }
    }

    @Test func preservesUnknownItemKindRawValueAndRawFields() throws {
        let notification = try decodeNotification("""
        {
          "method": "item/started",
          "params": {
            "item": {
              "id": "future-1",
              "type": "futureTool",
              "futureFlag": true
            }
          }
        }
        """)

        #expect(notification.payload.item?.rawType == "futureTool")
        #expect(notification.payload.item?.rawFields["futureFlag"] == .bool(true))

        let events = notification.domainEvents()
        guard case .itemStarted(let seed) = try #require(events.first) else {
            Issue.record("expected started item")
            return
        }
        #expect(seed.kind.rawValue == "futureTool")
        #expect(seed.id.rawValue == "future-1")
        if case .unknown(let unknown) = seed.content {
            #expect(unknown.title == "futureTool")
            #expect(unknown.detail?.contains("\"futureFlag\":true") == true)
        } else {
            Issue.record("expected unknown content for future item")
        }
    }

    @Test func mapsOfficialItemNotificationsToStructuredContentWithoutDisplayText() throws {
        let commandStarted = try decodeNotification("""
        {
          "method": "item/started",
          "params": {
            "startedAtMs": 1000,
            "item": {
              "id": "cmd-1",
              "type": "commandExecution",
              "command": "swift test",
              "cwd": "/tmp/project"
            }
          }
        }
        """)

        guard case .itemStarted(let commandSeed) = try #require(commandStarted.domainEvents().first) else {
            Issue.record("expected command item start")
            return
        }
        #expect(commandSeed.family == .command)
        #expect(commandSeed.phase == .running)
        #expect(commandSeed.startedAt == Date(timeIntervalSince1970: 1))
        if case .command(let command) = commandSeed.content {
            #expect(command.command == "swift test")
            #expect(command.command.hasPrefix("$") == false)
            #expect(command.cwd == "/tmp/project")
            #expect(command.output.isEmpty)
        } else {
            Issue.record("expected command content")
        }

        let commandCompleted = try decodeNotification("""
        {
          "method": "item/completed",
          "params": {
            "completedAtMs": 2000,
            "item": {
              "id": "cmd-1",
              "type": "commandExecution",
              "command": "swift test",
              "aggregatedOutput": "ok",
              "exitCode": 0,
              "durationMs": 1000
            }
          }
        }
        """)

        guard case .itemCompleted(let completedSeed) = try #require(commandCompleted.domainEvents().first) else {
            Issue.record("expected command item completion")
            return
        }
        #expect(completedSeed.phase == .completed)
        #expect(completedSeed.completedAt == Date(timeIntervalSince1970: 2))
        #expect(completedSeed.durationMs == 1000)
        if case .command(let command) = completedSeed.content {
            #expect(command.command == "swift test")
            #expect(command.output == "ok")
            #expect(command.exitCode == 0)
        } else {
            Issue.record("expected completed command content")
        }

        let searchStarted = try decodeNotification("""
        {
          "method": "item/started",
          "params": {
            "item": {
              "id": "search-1",
              "type": "webSearch",
              "query": "Swift Testing"
            }
          }
        }
        """)

        guard case .itemStarted(let searchSeed) = try #require(searchStarted.domainEvents().first) else {
            Issue.record("expected search item start")
            return
        }
        #expect(searchSeed.family == .search)
        if case .search(let search) = searchSeed.content {
            #expect(search.query == "Swift Testing")
            #expect(search.query != "Search")
        } else {
            Issue.record("expected search content")
        }

        let toolCompleted = try decodeNotification("""
        {
          "method": "item/completed",
          "params": {
            "item": {
              "id": "tool-1",
              "type": "mcpToolCall",
              "server": "codex_review",
              "tool": "review_read",
              "result": {
                "ok": true
              }
            }
          }
        }
        """)

        guard case .itemCompleted(let toolSeed) = try #require(toolCompleted.domainEvents().first) else {
            Issue.record("expected tool item completion")
            return
        }
        #expect(toolSeed.family == .tool)
        if case .toolCall(let tool) = toolSeed.content {
            #expect(tool.server == "codex_review")
            #expect(tool.tool == "review_read")
            #expect(tool.result == "{\"ok\":true}")
        } else {
            Issue.record("expected tool content")
        }

        let approvalCompleted = try decodeNotification("""
        {
          "method": "item/completed",
          "params": {
            "item": {
              "id": "approval-1",
              "type": "hookPrompt",
              "prompt": "Allow command?"
            }
          }
        }
        """)

        guard case .itemCompleted(let approvalSeed) = try #require(approvalCompleted.domainEvents().first) else {
            Issue.record("expected approval item completion")
            return
        }
        #expect(approvalSeed.family == .approval)
        if case .approval(let approval) = approvalSeed.content {
            #expect(approval.title == "Allow command?")
            #expect(approval.title != "Hook prompt completed.")
        } else {
            Issue.record("expected approval content")
        }
    }

    @Test func decodesCommandOutputAggregationEntryPointsWithoutDisplayText() throws {
        let encoded = Data("Build complete\n".utf8).base64EncodedString()
        for method in ["item/commandExecution/outputDelta", "command/exec/outputDelta", "process/outputDelta"] {
            let deltaField = method == "item/commandExecution/outputDelta"
                ? #""delta": "Build complete\n""#
                : #""deltaBase64": "\#(encoded)""#
            let notification = try decodeNotification("""
            {
              "method": "\(method)",
              "params": {
                "itemId": "cmd-1",
                \(deltaField)
              }
            }
            """)

            let events = notification.domainEvents()
            guard case .textDelta(let itemID, let kind, let family, let content, let delta) = try #require(events.first) else {
                Issue.record("expected text delta for \(method)")
                return
            }
            #expect(itemID.rawValue == "cmd-1")
            #expect(kind == .commandExecution)
            #expect(family == .command)
            #expect(delta == "Build complete\n")
            if case .command(let command) = content {
                #expect(command.command.isEmpty)
                #expect(command.output.isEmpty)
            } else {
                Issue.record("expected command content")
            }
        }
    }

    @Test func mapsTerminalAndDiagnosticNotificationsWithoutFallbackDisplayText() throws {
        let completed = try decodeNotification("""
        {
          "method": "turn/completed",
          "params": {
            "turn": {
              "id": "turn-1",
              "status": "completed"
            }
          }
        }
        """)

        guard case .reviewCompleted(let summary, let result) = try #require(completed.domainEvents().first) else {
            Issue.record("expected review completion")
            return
        }
        #expect(summary.isEmpty)
        #expect(result == nil)

        let failed = try decodeNotification("""
        {
          "method": "turn/failed",
          "params": {
            "turnId": "turn-2"
          }
        }
        """)

        guard case .reviewFailed(let failureMessage) = try #require(failed.domainEvents().first) else {
            Issue.record("expected review failure")
            return
        }
        #expect(failureMessage.isEmpty)

        let aborted = try decodeNotification("""
        {
          "method": "turn/aborted",
          "params": {
            "turnId": "turn-3"
          }
        }
        """)

        guard case .reviewCancelled(let cancellationMessage) = try #require(aborted.domainEvents().first) else {
            Issue.record("expected review cancellation")
            return
        }
        #expect(cancellationMessage.isEmpty)

        let retrying = try decodeNotification("""
        {
          "method": "error",
          "params": {
            "turnId": "turn-4",
            "message": "Retrying request",
            "willRetry": true
          }
        }
        """)

        #expect(retrying.payload.rawFields["willRetry"] == .bool(true))
        guard case .itemUpdated(let retrySeed) = try #require(retrying.domainEvents().first) else {
            Issue.record("expected retry diagnostic update")
            return
        }
        #expect(retrySeed.kind.rawValue == "error")
        #expect(retrySeed.family == .diagnostic)
        #expect(retrySeed.phase == .running)
        if case .diagnostic(let diagnostic) = retrySeed.content {
            #expect(diagnostic.message == "Retrying request")
        } else {
            Issue.record("expected diagnostic content")
        }
    }
}

private func decodeNotification(_ json: String) throws -> AppServerWireReviewNotification {
    try JSONDecoder().decode(AppServerWireReviewNotification.self, from: Data(json.utf8))
}
